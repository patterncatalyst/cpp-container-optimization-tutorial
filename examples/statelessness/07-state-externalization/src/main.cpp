// main.cpp — statelessness/07-state-externalization server.
//
// Authoritative order state lives in PostgreSQL. The process holds only
// process-scoped infrastructure: a PgPool, built in main()'s
// composition root (Doc 04) and injected into the handler by reference.
// Each request checks out a connection via ScopedConnection (RAII, Doc
// 02) and returns it on scope exit.
//
// CreateOrder is idempotent on idempotency_key. The database is the
// authoritative dedup point: INSERT ... ON CONFLICT (idempotency_key)
// DO NOTHING RETURNING is race-free — concurrent retries with the same
// key cannot both insert. A conflict (no row returned) means the key
// was seen before, so we read the original order back and flag the
// response as a replay.
//
// The inbound gRPC deadline propagates to the database: the handler
// reads ctx->deadline() and issues SET LOCAL statement_timeout from the
// time remaining, so a slow query cannot outlive the client's patience.
//
// PostgreSQL is reached through libpq (the C client). See pg_pool.hpp
// for why the runnable example uses libpq directly rather than libpqxx.

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <grpcpp/grpcpp.h>
#include <grpcpp/health_check_service_interface.h>

#include <libpq-fe.h>

#include "order.grpc.pb.h"
#include "pg_pool.hpp"

namespace statelessextern {
namespace {
std::mutex g_log_mu;
}

void log_line(const std::string& msg) {
    std::lock_guard<std::mutex> lk(g_log_mu);
    std::cout << "[order-svc] " << msg << std::endl;
}

namespace {

// RAII for a libpq result.
struct PgResultDeleter {
    void operator()(PGresult* r) const noexcept {
        if (r) PQclear(r);
    }
};
using PgResultPtr = std::unique_ptr<PGresult, PgResultDeleter>;

[[noreturn]] void pg_throw(PGconn* c, const std::string& what) {
    throw std::runtime_error(what + ": " + PQerrorMessage(c));
}

// Run a no-result command (BEGIN/COMMIT/ROLLBACK/SET/DDL), checking it.
void exec_cmd(PGconn* c, const char* sql) {
    PgResultPtr r(PQexec(c, sql));
    if (!r || PQresultStatus(r.get()) != PGRES_COMMAND_OK) {
        pg_throw(c, std::string("command failed: ") + sql);
    }
}

// Milliseconds until the gRPC deadline, or 0 if effectively none.
long deadline_ms_remaining(grpc::CallbackServerContext* ctx) {
    const auto deadline = ctx->deadline();
    const auto now = std::chrono::system_clock::now();
    const auto ms =
        std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now)
            .count();
    if (ms <= 0) return 0;
    if (ms > 24L * 3600L * 1000L) return 0;  // "no deadline" sentinel
    return static_cast<long>(ms);
}

class OrderServiceImpl final : public OrderService::CallbackService {
public:
    explicit OrderServiceImpl(PgPool& pool) : pool_(pool) {
        log_line("+service (pool injected by reference)");
    }
    ~OrderServiceImpl() override { log_line("-service"); }

    grpc::ServerUnaryReactor* CreateOrder(grpc::CallbackServerContext* ctx,
                                          const CreateOrderRequest* req,
                                          OrderResponse* resp) override {
        auto* reactor = ctx->DefaultReactor();

        if (req->idempotency_key().empty()) {
            reactor->Finish(grpc::Status(grpc::StatusCode::INVALID_ARGUMENT,
                                         "idempotency_key required"));
            return reactor;
        }

        // Checkout can time out under pool pressure; guard it so the
        // failure becomes a clean RPC status, not an uncaught throw.
        std::optional<ScopedConnection> conn;
        try {
            conn.emplace(pool_.acquire(std::chrono::milliseconds(50)));
        } catch (const std::exception& e) {
            reactor->Finish(grpc::Status(grpc::StatusCode::RESOURCE_EXHAUSTED,
                                         std::string("pool checkout failed: ") +
                                             e.what()));
            return reactor;
        }

        PGconn* c = conn->get();
        try {
            exec_cmd(c, "BEGIN");

            // Propagate the inbound deadline to the database.
            if (const long ms = deadline_ms_remaining(ctx); ms > 0) {
                exec_cmd(c, ("SET LOCAL statement_timeout = " +
                             std::to_string(ms)).c_str());
            }

            // Race-free idempotent insert. A returned row means we
            // created the order; no row means the key already existed.
            const char* ins_params[3] = {req->customer_id().c_str(),
                                         req->item().c_str(),
                                         req->idempotency_key().c_str()};
            PgResultPtr ins(PQexecParams(
                c,
                "INSERT INTO orders (customer_id, item, idempotency_key) "
                "VALUES ($1, $2, $3) "
                "ON CONFLICT (idempotency_key) DO NOTHING "
                "RETURNING order_id",
                3, nullptr, ins_params, nullptr, nullptr, 0));
            if (!ins || PQresultStatus(ins.get()) != PGRES_TUPLES_OK) {
                pg_throw(c, "insert failed");
            }

            long order_id = 0;
            const bool replay = (PQntuples(ins.get()) == 0);
            if (replay) {
                const char* sel_params[1] = {req->idempotency_key().c_str()};
                PgResultPtr sel(PQexecParams(
                    c, "SELECT order_id FROM orders WHERE idempotency_key = $1",
                    1, nullptr, sel_params, nullptr, nullptr, 0));
                if (!sel || PQresultStatus(sel.get()) != PGRES_TUPLES_OK ||
                    PQntuples(sel.get()) == 0) {
                    pg_throw(c, "replay lookup failed");
                }
                order_id = std::strtol(PQgetvalue(sel.get(), 0, 0), nullptr, 10);
            } else {
                order_id = std::strtol(PQgetvalue(ins.get(), 0, 0), nullptr, 10);
            }

            exec_cmd(c, "COMMIT");

            resp->set_order_id(order_id);
            resp->set_customer_id(req->customer_id());
            resp->set_item(req->item());
            resp->set_idempotent_replay(replay);
            log_line("CreateOrder key=" + req->idempotency_key() +
                     " order_id=" + std::to_string(order_id) +
                     (replay ? " (idempotent replay)" : " (created)"));
            reactor->Finish(grpc::Status::OK);
        } catch (const std::exception& e) {
            // Best-effort rollback; then decide whether the connection
            // itself is poisoned and must be dropped from the pool.
            { PgResultPtr rb(PQexec(c, "ROLLBACK")); }
            if (PQstatus(c) != CONNECTION_OK) {
                conn->invalidate();
                reactor->Finish(grpc::Status(grpc::StatusCode::UNAVAILABLE,
                                             e.what()));
            } else {
                reactor->Finish(grpc::Status(grpc::StatusCode::INTERNAL,
                                             e.what()));
            }
        }
        return reactor;
    }

    grpc::ServerUnaryReactor* GetOrder(grpc::CallbackServerContext* ctx,
                                       const GetOrderRequest* req,
                                       OrderResponse* resp) override {
        auto* reactor = ctx->DefaultReactor();
        std::optional<ScopedConnection> conn;
        try {
            conn.emplace(pool_.acquire(std::chrono::milliseconds(50)));
        } catch (const std::exception& e) {
            reactor->Finish(grpc::Status(grpc::StatusCode::RESOURCE_EXHAUSTED,
                                         std::string("pool checkout failed: ") +
                                             e.what()));
            return reactor;
        }

        PGconn* c = conn->get();
        try {
            const std::string id = std::to_string(req->order_id());
            const char* params[1] = {id.c_str()};
            PgResultPtr r(PQexecParams(
                c,
                "SELECT order_id, customer_id, item FROM orders WHERE order_id = $1",
                1, nullptr, params, nullptr, nullptr, 0));
            if (!r || PQresultStatus(r.get()) != PGRES_TUPLES_OK) {
                pg_throw(c, "select failed");
            }
            if (PQntuples(r.get()) == 0) {
                reactor->Finish(grpc::Status(grpc::StatusCode::NOT_FOUND,
                                             "no such order"));
                return reactor;
            }
            resp->set_order_id(std::strtol(PQgetvalue(r.get(), 0, 0), nullptr, 10));
            resp->set_customer_id(PQgetvalue(r.get(), 0, 1));
            resp->set_item(PQgetvalue(r.get(), 0, 2));
            resp->set_idempotent_replay(false);
            reactor->Finish(grpc::Status::OK);
        } catch (const std::exception& e) {
            if (PQstatus(c) != CONNECTION_OK) {
                conn->invalidate();
                reactor->Finish(grpc::Status(grpc::StatusCode::UNAVAILABLE,
                                             e.what()));
            } else {
                reactor->Finish(grpc::Status(grpc::StatusCode::INTERNAL,
                                             e.what()));
            }
        }
        return reactor;
    }

private:
    PgPool& pool_;
};

// ── schema migration at startup ──────────────────────────────────────
void migrate(PgPool& pool) {
    ScopedConnection conn = pool.acquire(std::chrono::milliseconds(2000));
    exec_cmd(conn.get(),
             "CREATE TABLE IF NOT EXISTS orders ("
             "  order_id        BIGSERIAL PRIMARY KEY,"
             "  customer_id     TEXT        NOT NULL,"
             "  item            TEXT        NOT NULL,"
             "  idempotency_key TEXT        NOT NULL UNIQUE,"
             "  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()"
             ")");
    log_line("schema ready (orders table; UNIQUE idempotency_key)");
}

// ── healthz on :8080 (same pattern as the other examples) ────────────
std::atomic<int> g_health_fd{-1};
std::atomic<bool> g_shutting_down{false};

void run_healthz(std::uint16_t port) {
    int fd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return;
    int one = 1;
    ::setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(port);
    if (::bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
        ::close(fd);
        return;
    }
    ::listen(fd, 16);
    g_health_fd.store(fd, std::memory_order_relaxed);
    const char* resp =
        "HTTP/1.1 200 OK\r\nContent-Length: 3\r\nContent-Type: text/plain\r\n\r\nok\n";
    while (!g_shutting_down.load(std::memory_order_relaxed)) {
        int cfd = ::accept(fd, nullptr, nullptr);
        if (cfd < 0) break;
        char buf[512];
        (void)::recv(cfd, buf, sizeof(buf), 0);
        (void)::send(cfd, resp, std::strlen(resp), 0);
        ::close(cfd);
    }
    ::close(fd);
}

std::unique_ptr<grpc::Server> g_server;
void on_signal(int) {
    g_shutting_down.store(true, std::memory_order_relaxed);
    int hfd = g_health_fd.load(std::memory_order_relaxed);
    if (hfd >= 0) ::shutdown(hfd, SHUT_RDWR);
    if (g_server) g_server->Shutdown();
}

}  // namespace
}  // namespace statelessextern

int main() {
    using namespace statelessextern;
    std::signal(SIGINT, on_signal);
    std::signal(SIGTERM, on_signal);

    const char* conninfo_env = std::getenv("PG_CONNINFO");
    const std::string conninfo =
        conninfo_env ? conninfo_env
                     : "postgresql://orders:orders@postgres:5432/orders";
    std::size_t pool_size = 4;
    if (const char* p = std::getenv("PG_POOL_SIZE")) {
        const long v = std::strtol(p, nullptr, 10);
        if (v > 0) pool_size = static_cast<std::size_t>(v);
    }

    std::thread health_thread(run_healthz, 8080);

    // ── composition root ──
    log_line("connecting pool (size=" + std::to_string(pool_size) + ")");
    std::unique_ptr<PgPool> pool;
    for (int attempt = 1; attempt <= 30; ++attempt) {
        try {
            pool = std::make_unique<PgPool>(conninfo, pool_size);
            break;
        } catch (const std::exception& e) {
            log_line("pool connect attempt " + std::to_string(attempt) +
                     " failed: " + e.what() + " — retrying");
            std::this_thread::sleep_for(std::chrono::seconds(1));
        }
    }
    if (!pool) {
        log_line("could not connect to PostgreSQL; giving up");
        g_shutting_down.store(true, std::memory_order_relaxed);
        if (health_thread.joinable()) health_thread.join();
        return 1;
    }
    log_line("+pool connected");

    try {
        migrate(*pool);
    } catch (const std::exception& e) {
        log_line(std::string("migration failed: ") + e.what());
        g_shutting_down.store(true, std::memory_order_relaxed);
        if (health_thread.joinable()) health_thread.join();
        return 1;
    }

    OrderServiceImpl service(*pool);

    const std::string addr = "0.0.0.0:50051";
    grpc::EnableDefaultHealthCheckService(true);
    grpc::ServerBuilder builder;
    builder.AddListeningPort(addr, grpc::InsecureServerCredentials());
    builder.RegisterService(&service);

    g_server = builder.BuildAndStart();
    if (!g_server) {
        log_line("failed to start gRPC server");
        g_shutting_down.store(true, std::memory_order_relaxed);
        if (health_thread.joinable()) health_thread.join();
        return 1;
    }
    log_line("+server listening on " + addr + " (healthz :8080)");

    g_server->Wait();

    log_line("shutting down");
    g_server.reset();
    g_shutting_down.store(true, std::memory_order_relaxed);
    int hfd = g_health_fd.load(std::memory_order_relaxed);
    if (hfd >= 0) ::shutdown(hfd, SHUT_RDWR);
    if (health_thread.joinable()) health_thread.join();
    return 0;
}
