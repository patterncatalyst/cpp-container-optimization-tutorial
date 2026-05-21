// pg_pool.hpp — a small connection pool with RAII checkout (Doc 07).
//
// libpqxx ships pqxx::connection (one connection) but no pool, so this
// is the one piece the compendium hand-rolls. It is process-scoped
// infrastructure: constructed once in main()'s composition root (Doc
// 04) and shared across handler threads.
//
//   PgPool            owns N connections; hands them out and reclaims
//   ScopedConnection  the per-request RAII checkout — returns the
//                     connection to the pool on scope exit, exactly the
//                     RAII discipline of Doc 02 applied to a real
//                     network resource
//
// Exception safety is the point (Doc 07 §"ScopedConnection and
// exception safety"). A query that timed out or hit a connection reset
// leaves the connection in an indeterminate state — it may or may not
// have committed. The handler calls invalidate() on such a connection;
// the pool then discards it on release instead of handing a poisoned
// connection to the next request. Crucially, release() never throws and
// never opens a new connection (that would risk throwing from a
// destructor); a discarded connection is replaced lazily on the next
// acquire().

#pragma once

#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include <pqxx/pqxx>

namespace statelessextern {

class PgPool;

// Per-request RAII handle. Move-only. Returns its connection to the
// pool when it goes out of scope.
class ScopedConnection {
public:
    ScopedConnection(ScopedConnection&& other) noexcept
        : pool_(other.pool_),
          conn_(std::move(other.conn_)),
          valid_(other.valid_) {
        other.pool_ = nullptr;
        other.valid_ = false;
    }
    ScopedConnection& operator=(ScopedConnection&&) = delete;
    ScopedConnection(const ScopedConnection&) = delete;
    ScopedConnection& operator=(const ScopedConnection&) = delete;

    ~ScopedConnection();  // returns conn_ to the pool (defined below)

    pqxx::connection& get() { return *conn_; }

    // Mark the connection unusable (e.g. after a reset or a timed-out
    // query whose commit state is unknown). The pool discards it on
    // release rather than returning it to the free list.
    void invalidate() noexcept { valid_ = false; }

private:
    friend class PgPool;
    ScopedConnection(PgPool* pool, std::unique_ptr<pqxx::connection> conn)
        : pool_(pool), conn_(std::move(conn)), valid_(true) {}

    PgPool* pool_;
    std::unique_ptr<pqxx::connection> conn_;
    bool valid_;
};

class PgPool {
public:
    // Eagerly opens `size` connections so the first requests don't pay
    // connection-setup latency. Throws if the database is unreachable —
    // which is what we want at startup (fail fast, let the orchestrator
    // restart once the DB is ready).
    PgPool(std::string conninfo, std::size_t size)
        : conninfo_(std::move(conninfo)), size_(size) {
        free_.reserve(size_);
        for (std::size_t i = 0; i < size_; ++i) {
            free_.push_back(std::make_unique<pqxx::connection>(conninfo_));
            ++live_;
        }
    }

    PgPool(const PgPool&) = delete;
    PgPool& operator=(const PgPool&) = delete;

    // Check out a connection, waiting up to `timeout` for one to become
    // free. Throws std::runtime_error on timeout. May open a fresh
    // connection here (not in a destructor) to replace one previously
    // discarded, so this is where connection-setup exceptions surface —
    // the handler maps them to an error status.
    ScopedConnection acquire(std::chrono::milliseconds timeout) {
        std::unique_lock<std::mutex> lk(mu_);
        const bool ready = cv_.wait_for(lk, timeout, [this] {
            return !free_.empty() || live_ < size_;
        });
        if (!ready) {
            throw std::runtime_error("PgPool: checkout timed out");
        }
        if (!free_.empty()) {
            auto conn = std::move(free_.back());
            free_.pop_back();
            return ScopedConnection(this, std::move(conn));
        }
        // free list empty but we're below capacity: a connection was
        // discarded earlier; open a replacement now.
        ++live_;
        lk.unlock();
        std::unique_ptr<pqxx::connection> conn;
        try {
            conn = std::make_unique<pqxx::connection>(conninfo_);
        } catch (...) {
            std::lock_guard<std::mutex> relk(mu_);
            --live_;            // creation failed; give the slot back
            cv_.notify_one();
            throw;
        }
        return ScopedConnection(this, std::move(conn));
    }

    std::size_t size() const noexcept { return size_; }

private:
    friend class ScopedConnection;

    // Called only from ~ScopedConnection. noexcept: never opens a
    // connection, never throws.
    void release(std::unique_ptr<pqxx::connection> conn, bool valid) noexcept {
        std::lock_guard<std::mutex> lk(mu_);
        if (valid && conn) {
            free_.push_back(std::move(conn));
        } else {
            --live_;  // discard the poisoned connection; replaced lazily
        }
        cv_.notify_one();
    }

    std::string conninfo_;
    std::size_t size_;
    std::mutex mu_;
    std::condition_variable cv_;
    std::vector<std::unique_ptr<pqxx::connection>> free_;
    std::size_t live_ = 0;  // open connections (free + checked out)
};

inline ScopedConnection::~ScopedConnection() {
    if (pool_ && conn_) {
        pool_->release(std::move(conn_), valid_);
    }
}

}  // namespace statelessextern
