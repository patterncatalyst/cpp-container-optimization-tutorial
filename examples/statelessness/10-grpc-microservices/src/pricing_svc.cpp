// pricing_svc.cpp — the order-pricing capstone (Doc 10).
//
// This is the integration example: it composes every prior pattern into one
// realistic gRPC service.
//
//   - Config (Doc 06)               parsed once in main(), passed by const&
//   - process-scoped state (Doc 04) PgPool + ChannelCache, owned by main(),
//                                   constructed once, shared across threads
//   - RequestContext (Doc 02/03)    per-request RAII bundle with a PMR arena
//   - the handler                   deadline checks, helpers that throw
//                                   grpc::Status, RAII cleanup, error
//                                   translation at the boundary
//   - backing services (Doc 07)     PostgreSQL via libpq with deadline-based
//                                   statement_timeout; an outbound gRPC tax
//                                   call via the channel cache with deadline
//                                   propagation
//   - health + shutdown (Doc 09)    staged startup (NOT_SERVING -> warm ->
//                                   SERVING), signal-safe graceful drain
//
// DIVERGENCES FROM Doc 10 (all to stay on this tutorial's verified stack;
// see the README):
//   - PostgreSQL via libpq, not libpqxx (gotcha G-67: libpqxx's bundled
//     CMake breaks this toolchain). The pool is 07's verified pg_pool.hpp.
//   - No Redis: the doc caches prices in Redis with a PG fallback; here the
//     price lookup goes straight to PostgreSQL. The cache-aside SHAPE is
//     noted where it would slot in.
//   - No OpenTelemetry: the RequestContext span/scope is a documented seam
//     (see request_context.hpp), not a built dependency.
//   - sync gRPC API (grpc::Status methods), not the callback API the doc
//     sketches. The composition is identical; the callback migration is
//     mechanical (Doc 05). Sync is what 07 and 09 verified on host.

#include <grpcpp/grpcpp.h>
#include <grpcpp/health_check_service_interface.h>
#include <grpcpp/ext/health_check_service_server_builder_option.h>

#include <libpq-fe.h>

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <memory_resource>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#include "channel_cache.hpp"
#include "config.hpp"
#include "pg_pool.hpp"
#include "request_context.hpp"

#include "pricing.grpc.pb.h"
#include "tax.grpc.pb.h"

namespace pricing {
namespace {

constexpr char kServiceName[] = "pricing.v1.Pricing";

void log_line(const std::string& msg) {
    static std::mutex m;
    std::lock_guard<std::mutex> lk(m);
    std::cout << "[pricing-svc] " << msg << std::endl;
}

struct PgResultDeleter {
    void operator()(PGresult* r) const noexcept { if (r) PQclear(r); }
};
using PgResultPtr = std::unique_ptr<PGresult, PgResultDeleter>;

// Value types returned by the helpers — owned by the caller, lifetime
// independent of any connection.
struct Customer {
    std::string id;
    std::string country;
    bool        tax_exempt = false;
};
struct PricedItem {
    std::int64_t unit_price_cents = 0;
    std::int32_t quantity = 0;
};

// Milliseconds left on the request budget; throws DEADLINE_EXCEEDED if none.
long long remaining_ms(RequestContext& rc) {
    const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                        rc.deadline() - std::chrono::system_clock::now())
                        .count();
    if (ms <= 0) {
        throw grpc::Status(grpc::StatusCode::DEADLINE_EXCEEDED,
                           "deadline exceeded");
    }
    return ms;
}

}  // namespace

// ── The service ───────────────────────────────────────────────────────
class PricingService final : public pricing::v1::Pricing::Service {
public:
    PricingService(const Config& cfg, PgPool& pg, ChannelCache& channels)
        : cfg_(cfg), pg_(pg), channels_(channels) {}

    grpc::Status PriceOrder(grpc::ServerContext* ctx,
                            const pricing::v1::PriceOrderRequest* req,
                            pricing::v1::PriceOrderResponse* resp) override {
        try {
            RequestContext rc(*ctx, req->correlation_id());

            if (req->idempotency_key().empty()) {
                return grpc::Status(grpc::StatusCode::INVALID_ARGUMENT,
                                    "idempotency_key required");
            }

            // Idempotency check (Doc 07): a replayed key returns the stored
            // result without recomputing.
            if (auto cached = check_idempotency(rc, req->idempotency_key())) {
                *resp = std::move(*cached);
                log_line("idempotent replay key=" + req->idempotency_key());
                return grpc::Status::OK;
            }

            // Customer (PostgreSQL, deadline-propagated).
            const Customer customer = fetch_customer(rc, req->customer_id());

            // Price each line item. Allocated from the per-request PMR arena
            // (Doc 03): these pmr::vector elements live in rc's arena buffer
            // and are reclaimed wholesale when rc destructs.
            std::pmr::vector<PricedItem> priced(rc.arena());
            priced.reserve(static_cast<std::size_t>(req->line_items_size()));
            for (const auto& item : req->line_items()) {
                priced.push_back(fetch_price(rc, item));
            }

            std::int64_t subtotal = 0;
            for (const auto& p : priced) {
                subtotal += p.unit_price_cents * p.quantity;
            }

            // Outbound gRPC to the tax service (channel cache + deadline).
            const std::int64_t tax = compute_tax(rc, customer, subtotal);

            resp->set_order_id(generate_order_id(rc.correlation_id()));
            resp->set_subtotal_cents(subtotal);
            resp->set_tax_cents(tax);
            resp->set_total_cents(subtotal + tax);

            store_idempotency(rc, req->idempotency_key(), *resp);
            return grpc::Status::OK;
        } catch (const grpc::Status& s) {
            // Protocol-level error already shaped by a helper.
            return s;
        } catch (const std::exception& e) {
            return grpc::Status(grpc::StatusCode::INTERNAL, e.what());
        }
    }

private:
    // Customer lookup with deadline-based statement_timeout (Doc 07).
    Customer fetch_customer(RequestContext& rc, const std::string& customer_id) {
        ScopedConnection conn = pg_.acquire(std::chrono::milliseconds(50));
        PGconn* c = conn.get();
        const long long budget = remaining_ms(rc);
        try {
            set_statement_timeout(c, budget);
            const char* p[1] = {customer_id.c_str()};
            PgResultPtr r(PQexecParams(
                c,
                "SELECT id, country, tax_exempt FROM customers WHERE id = $1",
                1, nullptr, p, nullptr, nullptr, 0));
            if (!r || PQresultStatus(r.get()) != PGRES_TUPLES_OK) {
                throw db_status(c);
            }
            if (PQntuples(r.get()) == 0) {
                throw grpc::Status(grpc::StatusCode::NOT_FOUND,
                                   "customer not found");
            }
            Customer cust;
            cust.id         = PQgetvalue(r.get(), 0, 0);
            cust.country    = PQgetvalue(r.get(), 0, 1);
            cust.tax_exempt = std::string(PQgetvalue(r.get(), 0, 2)) == "t";
            return cust;
        } catch (const grpc::Status&) {
            if (PQstatus(c) != CONNECTION_OK) conn.invalidate();
            throw;
        }
    }

    // Price for one line item. Doc 10 reads Redis first with a PG fallback;
    // here we go straight to PostgreSQL. CACHE-ASIDE SEAM: a Redis GET on
    // product_id would slot in before this query, with this query as the
    // miss path that then populates the cache.
    PricedItem fetch_price(RequestContext& rc,
                           const pricing::v1::LineItem& item) {
        ScopedConnection conn = pg_.acquire(std::chrono::milliseconds(50));
        PGconn* c = conn.get();
        const long long budget = remaining_ms(rc);
        try {
            set_statement_timeout(c, budget);
            const char* p[1] = {item.product_id().c_str()};
            PgResultPtr r(PQexecParams(
                c,
                "SELECT unit_price_cents FROM products WHERE id = $1",
                1, nullptr, p, nullptr, nullptr, 0));
            if (!r || PQresultStatus(r.get()) != PGRES_TUPLES_OK) {
                throw db_status(c);
            }
            if (PQntuples(r.get()) == 0) {
                throw grpc::Status(grpc::StatusCode::NOT_FOUND,
                                   "product not found: " + item.product_id());
            }
            PricedItem pi;
            pi.unit_price_cents =
                std::strtoll(PQgetvalue(r.get(), 0, 0), nullptr, 10);
            pi.quantity = item.quantity();
            return pi;
        } catch (const grpc::Status&) {
            if (PQstatus(c) != CONNECTION_OK) conn.invalidate();
            throw;
        }
    }

    // Outbound gRPC to the tax service: channel from the process-scoped
    // cache, deadline propagated from the request (Doc 04, Doc 07, Doc 10).
    std::int64_t compute_tax(RequestContext& rc, const Customer& customer,
                             std::int64_t subtotal) {
        if (customer.tax_exempt) return 0;

        auto channel = channels_.get_channel(cfg_.tax_service_addr);
        auto stub = tax::v1::TaxService::NewStub(channel);

        grpc::ClientContext client_ctx;
        client_ctx.set_deadline(rc.deadline());  // SAME deadline downstream
        // OTEL SEAM: a real impl injects W3C trace-context headers here so
        // the tax service links its span to ours.

        tax::v1::CalculateTaxRequest treq;
        treq.set_country(customer.country);
        treq.set_subtotal_cents(subtotal);

        tax::v1::CalculateTaxResponse tresp;
        const grpc::Status s = stub->CalculateTax(&client_ctx, treq, &tresp);
        if (!s.ok()) {
            throw grpc::Status(s.error_code(),
                               "tax service: " + s.error_message());
        }
        return tresp.tax_cents();
    }

    // Idempotency store, keyed by the client's idempotency_key (Doc 07).
    std::optional<pricing::v1::PriceOrderResponse> check_idempotency(
        RequestContext& rc, const std::string& key) {
        ScopedConnection conn = pg_.acquire(std::chrono::milliseconds(50));
        PGconn* c = conn.get();
        const long long budget = remaining_ms(rc);
        try {
            set_statement_timeout(c, budget);
            const char* p[1] = {key.c_str()};
            PgResultPtr r(PQexecParams(
                c,
                "SELECT order_id, subtotal_cents, tax_cents, total_cents "
                "FROM idempotency WHERE key = $1",
                1, nullptr, p, nullptr, nullptr, 0));
            if (!r || PQresultStatus(r.get()) != PGRES_TUPLES_OK) {
                throw db_status(c);
            }
            if (PQntuples(r.get()) == 0) return std::nullopt;
            pricing::v1::PriceOrderResponse out;
            out.set_order_id(PQgetvalue(r.get(), 0, 0));
            out.set_subtotal_cents(std::strtoll(PQgetvalue(r.get(), 0, 1), nullptr, 10));
            out.set_tax_cents(std::strtoll(PQgetvalue(r.get(), 0, 2), nullptr, 10));
            out.set_total_cents(std::strtoll(PQgetvalue(r.get(), 0, 3), nullptr, 10));
            return out;
        } catch (const grpc::Status&) {
            if (PQstatus(c) != CONNECTION_OK) conn.invalidate();
            throw;
        }
    }

    void store_idempotency(RequestContext& rc, const std::string& key,
                           const pricing::v1::PriceOrderResponse& resp) {
        ScopedConnection conn = pg_.acquire(std::chrono::milliseconds(50));
        PGconn* c = conn.get();
        const long long budget = remaining_ms(rc);
        const std::string order_id = resp.order_id();
        const std::string sub = std::to_string(resp.subtotal_cents());
        const std::string tax = std::to_string(resp.tax_cents());
        const std::string tot = std::to_string(resp.total_cents());
        try {
            set_statement_timeout(c, budget);
            const char* p[5] = {key.c_str(), order_id.c_str(), sub.c_str(),
                                tax.c_str(), tot.c_str()};
            PgResultPtr r(PQexecParams(
                c,
                "INSERT INTO idempotency "
                "(key, order_id, subtotal_cents, tax_cents, total_cents) "
                "VALUES ($1, $2, $3, $4, $5) ON CONFLICT (key) DO NOTHING",
                5, nullptr, p, nullptr, nullptr, 0));
            if (!r || PQresultStatus(r.get()) != PGRES_COMMAND_OK) {
                throw db_status(c);
            }
        } catch (const grpc::Status&) {
            if (PQstatus(c) != CONNECTION_OK) conn.invalidate();
            throw;
        }
    }

    static void set_statement_timeout(PGconn* c, long long ms) {
        const std::string sql =
            "SET statement_timeout = " + std::to_string(ms);
        PgResultPtr r(PQexec(c, sql.c_str()));
        // best-effort; the real query will surface any connection problem
    }

    static grpc::Status db_status(PGconn* c) {
        if (PQstatus(c) != CONNECTION_OK) {
            return grpc::Status(grpc::StatusCode::UNAVAILABLE, "db unavailable");
        }
        return grpc::Status(grpc::StatusCode::INTERNAL, PQerrorMessage(c));
    }

    std::string generate_order_id(const std::string& correlation_id) {
        // Deterministic-ish id from correlation + a process counter.
        static std::atomic<std::uint64_t> seq{0};
        return "ord-" + (correlation_id.empty() ? "anon" : correlation_id) +
               "-" + std::to_string(seq.fetch_add(1, std::memory_order_relaxed));
    }

    const Config& cfg_;
    PgPool&       pg_;
    ChannelCache& channels_;
};

namespace {

volatile std::sig_atomic_t g_sigterm = 0;
void on_signal(int sig) {
    if (sig == SIGTERM || sig == SIGINT) g_sigterm = 1;
}

// Schema + a little seed data, created at startup so the demo is self-
// contained. The pricing service owns its read model here.
void migrate(PgPool& pg) {
    ScopedConnection conn = pg.acquire(std::chrono::milliseconds(2000));
    PGconn* c = conn.get();
    auto run = [&](const char* sql) {
        PgResultPtr r(PQexec(c, sql));
        if (!r || PQresultStatus(r.get()) != PGRES_COMMAND_OK) {
            throw std::runtime_error(std::string("migrate failed: ") +
                                     PQerrorMessage(c));
        }
    };
    run("CREATE TABLE IF NOT EXISTS customers ("
        " id TEXT PRIMARY KEY, country TEXT NOT NULL,"
        " tax_exempt BOOLEAN NOT NULL DEFAULT false)");
    run("CREATE TABLE IF NOT EXISTS products ("
        " id TEXT PRIMARY KEY, unit_price_cents BIGINT NOT NULL)");
    run("CREATE TABLE IF NOT EXISTS idempotency ("
        " key TEXT PRIMARY KEY, order_id TEXT NOT NULL,"
        " subtotal_cents BIGINT NOT NULL, tax_cents BIGINT NOT NULL,"
        " total_cents BIGINT NOT NULL)");
    run("INSERT INTO customers (id, country, tax_exempt) VALUES"
        " ('alice','US',false),('bob','DE',false),('carol','US',true)"
        " ON CONFLICT (id) DO NOTHING");
    run("INSERT INTO products (id, unit_price_cents) VALUES"
        " ('widget',1999),('gadget',4950),('gizmo',799)"
        " ON CONFLICT (id) DO NOTHING");
    log_line("schema ready (customers, products, idempotency) + seed data");
}

}  // namespace
}  // namespace pricing

int main() {
    using namespace pricing;
    using grpc::HealthCheckServiceInterface;

    std::signal(SIGTERM, on_signal);
    std::signal(SIGINT, on_signal);

    // 1. Config parsed once (Doc 06).
    const Config config = parse_config();

    // 2. Process-scoped state, owned here (Doc 04). Retry the PG connect so
    //    the service tolerates Postgres still coming up.
    std::unique_ptr<PgPool> pg;
    for (int attempt = 1; attempt <= 30 && !g_sigterm; ++attempt) {
        try { pg = std::make_unique<PgPool>(config.pg_conninfo, config.pg_pool_size); break; }
        catch (const std::exception& e) {
            log_line("pg connect attempt " + std::to_string(attempt) +
                     " failed: " + e.what() + " — retrying");
            std::this_thread::sleep_for(std::chrono::seconds(1));
        }
    }
    if (!pg) { log_line("could not connect to PostgreSQL; giving up"); return 1; }

    ChannelCache channels;

    // 3. Build the gRPC server with health initially NOT_SERVING (Doc 09).
    grpc::EnableDefaultHealthCheckService(true);
    PricingService service(config, *pg, channels);
    grpc::ServerBuilder builder;
    builder.AddListeningPort(config.listen_addr, grpc::InsecureServerCredentials());
    builder.RegisterService(&service);
    std::unique_ptr<grpc::Server> server = builder.BuildAndStart();
    if (!server) { log_line("failed to start gRPC server"); return 1; }

    HealthCheckServiceInterface* health = server->GetHealthCheckService();
    health->SetServingStatus("", false);
    health->SetServingStatus(kServiceName, false);
    log_line("listening on " + config.listen_addr + "; warming up (NOT_SERVING)");

    // 4. Warm-up: run migrations / open the pool before flipping to SERVING.
    //    (The doc also warms Redis and resolves the tax channel here.)
    try {
        migrate(*pg);
    } catch (const std::exception& e) {
        log_line(std::string("migrate error: ") + e.what());
        return 1;
    }

    // 5. Ready.
    health->SetServingStatus("", true);
    health->SetServingStatus(kServiceName, true);
    log_line("pricing service ready (SERVING) version=" + config.service_version);

    // 6. Graceful shutdown (Doc 09): control thread reacts to the signal
    //    flag off-handler.
    std::jthread control([&] {
        while (true) {
            if (g_sigterm) {
                log_line("SIGTERM: beginning graceful shutdown");
                health->SetServingStatus(kServiceName, false);
                log_line("  readiness NOT_SERVING (draining)");
                server->Shutdown(std::chrono::system_clock::now() +
                                 std::chrono::seconds(25));
                break;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
    });

    server->Wait();
    log_line("server->Wait() returned; tearing down");

    // 7. Reverse-order teardown: control joins, then service, channels, pg
    //    destruct in reverse construction order (Doc 04). Exit 0.
    return 0;
}
