// config.hpp — env-time configuration parsed once in main() (Doc 06).
//
// The doc's Config carries Redis, OTLP, and jemalloc fields too; this
// buildable capstone keeps the fields the proven stack actually uses
// (Postgres via libpq, the tax upstream, deadline, pool sizes) and notes
// the rest in the README. The discipline is the point: parse env ONCE,
// here, into an immutable struct; pass it by const reference; no getenv
// anywhere else.

#pragma once

#include <chrono>
#include <cstdlib>
#include <stdexcept>
#include <string>

namespace pricing {

struct Config {
    std::string               listen_addr;       // LISTEN_ADDR
    std::string               pg_conninfo;        // PG_CONNINFO
    std::size_t               pg_pool_size;       // PG_POOL_SIZE
    std::string               tax_service_addr;   // TAX_SERVICE_ADDR
    std::chrono::milliseconds default_deadline;   // DEFAULT_DEADLINE_MS
    std::string               service_version;    // SERVICE_VERSION
};

inline std::string env_or(const char* key, const char* fallback) {
    const char* v = std::getenv(key);
    return v ? std::string(v) : std::string(fallback);
}

inline std::size_t env_size(const char* key, std::size_t fallback) {
    const char* v = std::getenv(key);
    if (!v || !*v) return fallback;
    return static_cast<std::size_t>(std::strtoul(v, nullptr, 10));
}

inline Config parse_config() {
    Config c;
    c.listen_addr      = env_or("LISTEN_ADDR", "0.0.0.0:50051");
    c.pg_conninfo      = env_or("PG_CONNINFO",
                                "postgresql://pricing:pricing@postgres:5432/pricing");
    c.pg_pool_size     = env_size("PG_POOL_SIZE", 8);
    c.tax_service_addr = env_or("TAX_SERVICE_ADDR", "tax:50052");
    c.default_deadline =
        std::chrono::milliseconds(env_size("DEFAULT_DEADLINE_MS", 2000));
    c.service_version  = env_or("SERVICE_VERSION", "dev");
    return c;
}

}  // namespace pricing
