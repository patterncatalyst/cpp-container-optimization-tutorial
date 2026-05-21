// composition.hpp — the process-scoped state types (compendium Doc 04).
//
// Three pieces of process-scoped state, each a plain type constructed by
// name in main()'s composition root and injected into the service by
// reference — no Meyers singletons, no hidden construction order:
//
//   ServiceConfig    parsed once at startup; immutable thereafter
//   MetricsRegistry  process-wide counters (atomic)
//   BoundedCache     an LRU cache with a hard capacity
//
// Each type logs on construction and destruction via wire_log(), so the
// demo can show that main() builds them in dependency order
// (config → metrics → cache → service → server) and that RAII tears
// them down in the exact reverse order — which is also the *correct*
// shutdown order: the server stops first (no new RPCs), then the state
// it depended on. You get correct teardown for free, with no manual
// shutdown choreography, precisely because dependencies are constructed
// before the things that use them.
//
// Thread-safety note (foreshadows Doc 05): gRPC runs handlers on a pool
// of threads, so process-scoped *mutable* state shared across requests
// must be synchronized. The cache takes a mutex; the metrics are atomic;
// the config is immutable after construction and so needs neither.

#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <list>
#include <mutex>
#include <optional>
#include <string>
#include <unordered_map>
#include <utility>

namespace statelessstate {

// Logging hook, defined in main.cpp (keeps iostream out of the header).
void wire_log(const char* event, const std::string& detail);

// ── Process-scoped, immutable: parsed configuration ──────────────────
class ServiceConfig {
public:
    static ServiceConfig from_env() {
        std::size_t cap = 4;  // small default so the demo evicts visibly
        if (const char* c = std::getenv("CACHE_CAPACITY")) {
            char* end = nullptr;
            unsigned long v = std::strtoul(c, &end, 10);
            if (end != c && v > 0) cap = static_cast<std::size_t>(v);
        }
        return ServiceConfig(cap);
    }

    explicit ServiceConfig(std::size_t cache_capacity)
        : cache_capacity_(cache_capacity) {
        wire_log("+config", "cache_capacity=" + std::to_string(cache_capacity_));
    }
    ~ServiceConfig() { wire_log("-config", ""); }

    ServiceConfig(const ServiceConfig&) = delete;
    ServiceConfig& operator=(const ServiceConfig&) = delete;

    std::size_t cache_capacity() const noexcept { return cache_capacity_; }

private:
    std::size_t cache_capacity_;
};

// ── Process-scoped, mutable: atomic counters ─────────────────────────
class MetricsRegistry {
public:
    MetricsRegistry() { wire_log("+metrics", ""); }
    ~MetricsRegistry() { wire_log("-metrics", ""); }

    MetricsRegistry(const MetricsRegistry&) = delete;
    MetricsRegistry& operator=(const MetricsRegistry&) = delete;

    void record_lookup() noexcept { lookups_.fetch_add(1, std::memory_order_relaxed); }
    void record_hit() noexcept { hits_.fetch_add(1, std::memory_order_relaxed); }
    void record_miss() noexcept { misses_.fetch_add(1, std::memory_order_relaxed); }
    void record_eviction() noexcept { evictions_.fetch_add(1, std::memory_order_relaxed); }

    std::int64_t lookups() const noexcept { return lookups_.load(std::memory_order_relaxed); }
    std::int64_t hits() const noexcept { return hits_.load(std::memory_order_relaxed); }
    std::int64_t misses() const noexcept { return misses_.load(std::memory_order_relaxed); }
    std::int64_t evictions() const noexcept { return evictions_.load(std::memory_order_relaxed); }

private:
    std::atomic<std::int64_t> lookups_{0};
    std::atomic<std::int64_t> hits_{0};
    std::atomic<std::int64_t> misses_{0};
    std::atomic<std::int64_t> evictions_{0};
};

// ── Process-scoped, mutable, BOUNDED: an LRU cache ───────────────────
// The bound is the point. An unbounded map keyed on request input grows
// with the distinct-key count until it trips the cgroup memory limit and
// the OOM killer ends the process — the classic "works in test, dies in
// prod under real traffic" failure. A capacity-bounded LRU keeps
// process-scoped memory flat: insertions past capacity evict the
// least-recently-used entry instead of growing the footprint.
class BoundedCache {
public:
    explicit BoundedCache(std::size_t capacity) : capacity_(capacity) {
        wire_log("+cache", "capacity=" + std::to_string(capacity_));
    }
    ~BoundedCache() { wire_log("-cache", ""); }

    BoundedCache(const BoundedCache&) = delete;
    BoundedCache& operator=(const BoundedCache&) = delete;

    // Returns the value and promotes it to most-recently-used, or
    // nullopt on a miss.
    std::optional<std::string> get(const std::string& key) {
        std::lock_guard<std::mutex> lk(mu_);
        auto it = index_.find(key);
        if (it == index_.end()) return std::nullopt;
        order_.splice(order_.begin(), order_, it->second);  // promote to MRU
        return it->second->second;
    }

    // Inserts (or updates) key→value. Returns true if inserting evicted
    // the least-recently-used entry to stay within capacity.
    bool put(const std::string& key, std::string value) {
        std::lock_guard<std::mutex> lk(mu_);
        auto it = index_.find(key);
        if (it != index_.end()) {
            it->second->second = std::move(value);
            order_.splice(order_.begin(), order_, it->second);
            return false;
        }
        order_.emplace_front(key, std::move(value));
        index_[key] = order_.begin();
        if (index_.size() > capacity_) {
            const std::string evict_key = order_.back().first;
            index_.erase(evict_key);
            order_.pop_back();
            return true;
        }
        return false;
    }

    std::size_t size() const {
        std::lock_guard<std::mutex> lk(mu_);
        return index_.size();
    }
    std::size_t capacity() const noexcept { return capacity_; }

private:
    mutable std::mutex mu_;
    std::size_t capacity_;
    // front = most-recently-used, back = least-recently-used
    std::list<std::pair<std::string, std::string>> order_;
    std::unordered_map<std::string,
                       std::list<std::pair<std::string, std::string>>::iterator>
        index_;
};

}  // namespace statelessstate
