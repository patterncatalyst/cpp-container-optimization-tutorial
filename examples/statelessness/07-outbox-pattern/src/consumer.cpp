// consumer.cpp — the idempotent consumer (statelessness/07-outbox-pattern).
//
// Reads events from Kafka and applies each into a projection table with
// INSERT ... ON CONFLICT (event_id) DO NOTHING. Because delivery is
// at-least-once (the relay may re-publish after a crash, and Kafka may
// redeliver on a consumer restart before the offset was committed), the
// consumer MUST be idempotent: a duplicate event_id is a no-op. The
// offset is committed only AFTER the DB apply, so a crash re-delivers
// rather than silently drops.
//
// At-least-once delivery + an idempotent consumer = exactly-once EFFECT,
// which is the achievable guarantee (true exactly-once delivery is not).

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
    std::cout << "[consumer] " << msg << std::endl;
}

struct PgResultDeleter {
    void operator()(PGresult* r) const noexcept { if (r) PQclear(r); }
};
using PgResultPtr = std::unique_ptr<PGresult, PgResultDeleter>;

std::atomic<bool> g_stop{false};
void on_signal(int) { g_stop.store(true, std::memory_order_relaxed); }

// Apply one event idempotently. Returns true if newly applied, false if
// it was a duplicate (already present).
bool apply_event(PgPool& pool, const std::string& event_id,
                 const std::string& payload) {
    ScopedConnection conn = pool.acquire(std::chrono::milliseconds(1000));
    PGconn* c = conn.get();
    try {
        const char* p[2] = {event_id.c_str(), payload.c_str()};
        PgResultPtr r(PQexecParams(
            c,
            "INSERT INTO order_projection (event_id, payload) "
            "VALUES ($1, $2) ON CONFLICT (event_id) DO NOTHING",
            2, nullptr, p, nullptr, nullptr, 0));
        if (!r || PQresultStatus(r.get()) != PGRES_COMMAND_OK) {
            throw std::runtime_error(std::string("projection insert failed: ") +
                                     PQerrorMessage(c));
        }
        // PQcmdTuples is "1" if a row was inserted, "0" on conflict.
        const char* affected = PQcmdTuples(r.get());
        return affected && affected[0] == '1';
    } catch (...) {
        if (PQstatus(c) != CONNECTION_OK) conn.invalidate();
        throw;
    }
}

}  // namespace
}  // namespace statelessoutbox

int main() {
    using namespace statelessoutbox;
    std::signal(SIGINT, on_signal);
    std::signal(SIGTERM, on_signal);

    const char* conninfo_env = std::getenv("PG_CONNINFO");
    const std::string conninfo =
        conninfo_env ? conninfo_env
                     : "postgresql://orders:orders@postgres:5432/orders";
    const char* brokers_env = std::getenv("KAFKA_BROKERS");
    const std::string brokers = brokers_env ? brokers_env : "kafka:9092";
    const char* topic_env = std::getenv("KAFKA_TOPIC");
    const std::string topic = topic_env ? topic_env : "orders";

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

    std::unique_ptr<KafkaConsumer> consumer;
    for (int attempt = 1; attempt <= 30 && !g_stop; ++attempt) {
        try {
            consumer = std::make_unique<KafkaConsumer>(brokers, "order-consumer", topic);
            break;
        } catch (const std::exception& e) {
            log_line("kafka connect attempt " + std::to_string(attempt) +
                     " failed: " + e.what() + " — retrying");
            std::this_thread::sleep_for(std::chrono::seconds(1));
        }
    }
    if (!consumer) { log_line("could not create Kafka consumer; giving up"); return 1; }
    log_line("consuming topic=" + topic + " brokers=" + brokers);

    while (!g_stop.load(std::memory_order_relaxed)) {
        rd_kafka_message_t* msg = consumer->poll(500);
        if (!msg) continue;
        if (msg->err) {
            // RD_KAFKA_RESP_ERR__PARTITION_EOF and transient errors are
            // normal; log anything unexpected.
            if (msg->err != RD_KAFKA_RESP_ERR__PARTITION_EOF) {
                log_line(std::string("consume error: ") +
                         rd_kafka_message_errstr(msg));
            }
            rd_kafka_message_destroy(msg);
            continue;
        }
        const std::string event_id =
            msg->key ? std::string(static_cast<const char*>(msg->key), msg->key_len)
                     : std::string();
        const std::string payload =
            msg->payload
                ? std::string(static_cast<const char*>(msg->payload), msg->len)
                : std::string();
        try {
            const bool applied = apply_event(*pool, event_id, payload);
            if (applied) {
                log_line("applied event_id=" + event_id);
            } else {
                log_line("duplicate event_id=" + event_id +
                         " ignored (idempotent)");
            }
            // Commit the offset only after the DB apply (at-least-once).
            consumer->commit(msg);
        } catch (const std::exception& e) {
            // Do NOT commit: the message will be redelivered and retried.
            log_line(std::string("apply failed (will retry): ") + e.what());
            std::this_thread::sleep_for(std::chrono::milliseconds(500));
        }
        rd_kafka_message_destroy(msg);
    }
    log_line("stopped");
    return 0;
}
