// request_context.hpp — the RequestContext RAII pattern.
//
// This is the centerpiece of the example and the concrete realization
// of compendium Doc 02 ("RAII as the foundation for safe stateful work
// in a stateless service").
//
// A stateless service still holds plenty of state *inside* a request:
// a request id, a span/timer, a deadline, a per-request memory arena, a
// leased resource (here a stand-in for a pooled DB connection). None of
// it should outlive the request. RequestContext bundles all of it into
// one RAII type whose lifetime is exactly the handler's scope.
//
// The properties this type demonstrates:
//   1. Constructor ACQUIRES (mint id, start timer, reserve arena, lease
//      a resource) and logs the acquisition.
//   2. Destructor RELEASES (return the lease, report duration) and is
//      noexcept — it runs on EVERY exit path: normal return, early
//      return, and exception unwinding.
//   3. The type is move-only with noexcept moves (the guarantee STL
//      containers and the language itself rely on). Copy is deleted.
//
// In production the `span_` member would be an OpenTelemetry span and
// the lease would be a real pooled connection (see compendium Doc 04
// for the connection pool and Doc 03 for the PMR arena). Here they are
// represented with logging so the lifecycle is observable in plain
// stdout, with no observability stack required.

#pragma once

#include <array>
#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <memory_resource>
#include <string>
#include <utility>

#include <grpcpp/grpcpp.h>

namespace statelessraii {

// A stand-in for a pooled, leased resource (e.g. a database connection
// checked out of a process-scoped pool). The point is that it MUST be
// returned exactly once; RequestContext guarantees that by owning it.
class LeasedResource {
public:
    explicit LeasedResource(std::uint64_t lease_id) : lease_id_(lease_id) {}
    std::uint64_t id() const noexcept { return lease_id_; }

private:
    std::uint64_t lease_id_;
};

// A tiny process-scoped "pool" that hands out lease ids and counts how
// many are currently outstanding. If RequestContext ever failed to
// release on some exit path, `outstanding()` would climb — the demo
// asserts it returns to zero after every request, which is the
// machine-checkable proof that RAII cleaned up.
class LeasePool {
public:
    LeasedResource acquire() noexcept {
        outstanding_.fetch_add(1, std::memory_order_relaxed);
        return LeasedResource{next_id_.fetch_add(1, std::memory_order_relaxed)};
    }
    void release(const LeasedResource&) noexcept {
        outstanding_.fetch_sub(1, std::memory_order_relaxed);
    }
    std::size_t outstanding() const noexcept {
        return outstanding_.load(std::memory_order_relaxed);
    }

private:
    std::atomic<std::uint64_t> next_id_{1};
    std::atomic<std::size_t> outstanding_{0};
};

// Logging hook. Kept as a free function so the header has no iostream
// dependency leaking into every translation unit that includes it; the
// definition lives in main.cpp.
void rc_log(const std::string& request_id, const char* event,
            const std::string& detail);

class RequestContext {
public:
    // Construction = acquisition. Mints an id, starts the scope timer,
    // reserves a per-request arena, and leases a resource from the pool.
    RequestContext(LeasePool& pool, std::string request_id)
        : pool_(&pool),
          request_id_(std::move(request_id)),
          start_(std::chrono::steady_clock::now()),
          lease_(pool.acquire()),
          arena_buffer_{},
          arena_(arena_buffer_.data(), arena_buffer_.size()) {
        rc_log(request_id_, "acquire",
               "lease=" + std::to_string(lease_.id()) +
               " arena=" + std::to_string(arena_buffer_.size()) + "B");
    }

    // Destruction = release. Returns the lease and reports the duration.
    // noexcept: a destructor must never throw (throwing while another
    // exception unwinds the stack calls std::terminate). This is the
    // no-throw guarantee the language requires of destructors.
    ~RequestContext() noexcept {
        if (pool_ != nullptr) {
            pool_->release(lease_);
            rc_log(request_id_, "release",
                   "duration_us=" + std::to_string(elapsed_micros()));
        }
    }

    // Move-only. Moves are noexcept (the guarantee std::vector and
    // friends rely on to move rather than copy on reallocation). After
    // a move, the source's pool_ is null so its destructor is a no-op —
    // the lease is released exactly once, by the destination.
    RequestContext(RequestContext&& other) noexcept
        : pool_(std::exchange(other.pool_, nullptr)),
          request_id_(std::move(other.request_id_)),
          start_(other.start_),
          lease_(other.lease_),
          arena_buffer_{},
          arena_(arena_buffer_.data(), arena_buffer_.size()) {}

    RequestContext& operator=(RequestContext&& other) noexcept {
        if (this != &other) {
            // Release our own lease first, then take over the source's.
            if (pool_ != nullptr) {
                pool_->release(lease_);
            }
            pool_ = std::exchange(other.pool_, nullptr);
            request_id_ = std::move(other.request_id_);
            start_ = other.start_;
            lease_ = other.lease_;
            // arena_ is non-transferable (it points into our own
            // buffer); each RequestContext keeps its own arena.
        }
        return *this;
    }

    RequestContext(const RequestContext&) = delete;
    RequestContext& operator=(const RequestContext&) = delete;

    const std::string& id() const noexcept { return request_id_; }
    std::uint64_t lease_id() const noexcept { return lease_.id(); }

    // The per-request memory arena. Allocations made through it are all
    // released together when this RequestContext is destroyed — there is
    // no per-object deallocation. See compendium Doc 03 for the full
    // PMR treatment (and the dedicated 03-pmr example).
    std::pmr::monotonic_buffer_resource& arena() noexcept { return arena_; }

    std::int64_t elapsed_micros() const noexcept {
        using namespace std::chrono;
        return duration_cast<microseconds>(steady_clock::now() - start_)
            .count();
    }

private:
    LeasePool* pool_;
    std::string request_id_;
    std::chrono::steady_clock::time_point start_;
    LeasedResource lease_;
    // A fixed inline buffer the arena bump-allocates from. 8 KiB is
    // plenty for a small handler's scratch; real services size this to
    // their request shape.
    std::array<std::byte, 8192> arena_buffer_;
    std::pmr::monotonic_buffer_resource arena_;
};

}  // namespace statelessraii
