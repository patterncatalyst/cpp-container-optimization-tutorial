// relay.cpp — the outbox relay (statelessness/07-outbox-pattern).
//
// Two modes:
//
//   outbox-relay run
//       The poller. In a loop: read unpublished outbox rows with
//       FOR UPDATE SKIP LOCKED (so multiple relay replicas never publish
//       the same row), produce each to Kafka, flush to confirm the
//       broker acked, then mark them published and commit. A crash
//       between the Kafka ack and the COMMIT leaves the rows unpublished,
//       so they are re-published on the next pass: AT-LEAST-ONCE
//       delivery, which is exactly why the consumer must be idempotent.
//
//   outbox-relay produce <event_id> <payload>
//       One-shot: publish a single message and exit. Used by the demo
//       to inject a DUPLICATE event so you can watch the consumer dedup
//       it — the at-least-once redelivery made deterministic.

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <string>
#include <thread>

#include <libpq-fe.h>

#include "kafka.hpp"
#include "pg_pool.hpp"

namespace statelessoutbox {
namespace {

void log_line(const std::string& msg) {
    static std::mutex m;
    std::lock_guard<std::mutex> lk(m);
    std::cout << "[relay] " << msg << std::endl;
}

struct PgResultDeleter {
    void operator()(PGresult* r) const noexcept { if (r) PQclear(r); }
};
using PgResultPtr = std::unique_ptr<PGresult, PgResultDeleter>;

void exec_cmd(PGconn* c, const char* sql) {
    PgResultPtr r(PQexec(c, sql));
    if (!r || PQresultStatus(r.get()) != PGRES_COMMAND_OK) {
        throw std::runtime_error(std::string("command failed: ") + sql + ": " +
                                 PQerrorMessage(c));
    }
}

std::atomic<bool> g_stop{false};
void on_signal(int) { g_stop.store(true, std::memory_order_relaxed); }

const char* topic() {
    const char* t = std::getenv("KAFKA_TOPIC");
    return t ? t : "orders";
}

// One pass of the poller. Returns the number of events published.
int publish_batch(PgPool& pool, KafkaProducer& producer) {
    ScopedConnection conn = pool.acquire(std::chrono::milliseconds(1000));
    PGconn* c = conn.get();
    exec_cmd(c, "BEGIN");
    try {
        PgResultPtr rows(PQexec(
            c,
            "SELECT id, event_id, payload FROM outbox "
            "WHERE published_at IS NULL "
            "ORDER BY created_at LIMIT 100 FOR UPDATE SKIP LOCKED"));
        if (!rows || PQresultStatus(rows.get()) != PGRES_TUPLES_OK) {
            throw std::runtime_error(std::string("outbox select failed: ") +
                                     PQerrorMessage(c));
        }
        const int n = PQntuples(rows.get());
        if (n == 0) {
            exec_cmd(c, "COMMIT");
            return 0;
        }
        for (int i = 0; i < n; ++i) {
            const std::string event_id = PQgetvalue(rows.get(), i, 1);
            const std::string payload = PQgetvalue(rows.get(), i, 2);
            producer.produce(topic(), event_id, payload);
        }
        // Confirm the broker acked everything BEFORE marking published.
        producer.flush(5000);
        for (int i = 0; i < n; ++i) {
            const char* id = PQgetvalue(rows.get(), i, 0);
            const char* p[1] = {id};
            PgResultPtr upd(PQexecParams(
                c, "UPDATE outbox SET published_at = now() WHERE id = $1", 1,
                nullptr, p, nullptr, nullptr, 0));
            if (!upd || PQresultStatus(upd.get()) != PGRES_COMMAND_OK) {
                throw std::runtime_error(std::string("outbox mark failed: ") +
                                         PQerrorMessage(c));
            }
        }
        exec_cmd(c, "COMMIT");
        return n;
    } catch (...) {
        { PgResultPtr rb(PQexec(c, "ROLLBACK")); }
        if (PQstatus(c) != CONNECTION_OK) conn.invalidate();
        throw;
    }
}

int run_poller() {
    std::signal(SIGINT, on_signal);
    std::signal(SIGTERM, on_signal);

    const char* conninfo_env = std::getenv("PG_CONNINFO");
    const std::string conninfo =
        conninfo_env ? conninfo_env
                     : "postgresql://orders:orders@postgres:5432/orders";
    const char* brokers_env = std::getenv("KAFKA_BROKERS");
    const std::string brokers = brokers_env ? brokers_env : "kafka:9092";

    std::unique_ptr<PgPool> pool;
    for (int attempt = 1; attempt <= 30 && !g_stop; ++attempt) {
        try { pool = std::make_unique<PgPool>(conninfo, 2); break; }
        catch (const std::exception& e) {
            log_line("pool connect attempt " + std::to_string(attempt) +
                     " failed: " + e.what() + " — retrying");
            std::this_thread::sleep_for(std::chrono::seconds(1));
        }
    }
    if (!pool) { log_line("could not connect to PostgreSQL; giving up"); return 1; }
    log_line("connected; publishing topic=" + std::string(topic()) +
             " brokers=" + brokers);

    KafkaProducer producer(brokers);

    while (!g_stop.load(std::memory_order_relaxed)) {
        try {
            const int n = publish_batch(*pool, producer);
            if (n > 0) log_line("published " + std::to_string(n) + " event(s)");
            std::this_thread::sleep_for(std::chrono::milliseconds(n > 0 ? 50 : 200));
        } catch (const std::exception& e) {
            log_line(std::string("batch error (will retry): ") + e.what());
            std::this_thread::sleep_for(std::chrono::milliseconds(500));
        }
    }
    log_line("stopped");
    return 0;
}

int run_produce(const std::string& event_id, const std::string& payload) {
    const char* brokers_env = std::getenv("KAFKA_BROKERS");
    const std::string brokers = brokers_env ? brokers_env : "kafka:9092";
    KafkaProducer producer(brokers);
    producer.produce(topic(), event_id, payload);
    producer.flush(5000);
    log_line("produced event_id=" + event_id + " to topic=" + topic());
    return 0;
}

}  // namespace
}  // namespace statelessoutbox

int main(int argc, char** argv) {
    using namespace statelessoutbox;
    const std::string mode = (argc > 1) ? argv[1] : "run";
    if (mode == "run") {
        return run_poller();
    }
    if (mode == "produce") {
        if (argc < 4) {
            std::cerr << "usage: outbox-relay produce <event_id> <payload>\n";
            return 2;
        }
        try {
            return run_produce(argv[2], argv[3]);
        } catch (const std::exception& e) {
            std::cerr << "produce failed: " << e.what() << "\n";
            return 1;
        }
    }
    std::cerr << "usage: outbox-relay <run | produce <event_id> <payload>>\n";
    return 2;
}
