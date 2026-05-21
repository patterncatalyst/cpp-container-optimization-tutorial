// pool_bench.cpp — run a fixed CPU-bound workload across a thread pool
// of a given size and report throughput and the per-task latency
// distribution.
//
// The point (Doc 05): under a CFS quota, oversubscribing the pool does
// NOT buy throughput — the quota is a fixed slice of CPU time per period
// regardless of thread count — and it makes tail latency worse, because
// when the container hits its quota mid-period the kernel throttles all
// of its threads until the next period boundary (up to ~100 ms with the
// default period). Spread that pause across more threads and more tasks
// stall. So a pool sized to the quota gives the same throughput with a
// far tighter p99/max than a pool sized to hardware_concurrency().
//
// Usage:
//   pool-bench <pool_size> [num_tasks] [iters_per_task]
//
// Each task runs `iters_per_task` xorshift iterations (CPU-bound, not
// optimizable away) and records its own wall-clock duration. Tasks are
// pulled from a shared atomic counter, so the pool stays busy.

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <thread>
#include <vector>

namespace {

using clock_type = std::chrono::steady_clock;

// CPU-bound, side-effecting so the optimizer can't elide it.
std::uint64_t busy(std::uint64_t iters) {
    std::uint64_t x = 0x9e3779b97f4a7c15ULL;
    for (std::uint64_t i = 0; i < iters; ++i) {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        x += 0x2545f4914f6cdd1dULL;
    }
    return x;
}

long pctile(const std::vector<long>& sorted, double p) {
    if (sorted.empty()) return 0;
    const std::size_t idx = static_cast<std::size_t>(
        p / 100.0 * static_cast<double>(sorted.size() - 1));
    return sorted[idx];
}

}  // namespace

int main(int argc, char** argv) {
    if (argc < 2) {
        std::fprintf(stderr,
                     "usage: %s <pool_size> [num_tasks] [iters_per_task]\n",
                     argv[0]);
        return 2;
    }
    const unsigned pool_size = static_cast<unsigned>(std::strtoul(argv[1], nullptr, 10));
    const int num_tasks = (argc > 2) ? std::atoi(argv[2]) : 2000;
    const std::uint64_t iters = (argc > 3)
        ? std::strtoull(argv[3], nullptr, 10)
        : 400000ULL;  // ~a couple ms/task on a typical core
    if (pool_size == 0 || num_tasks <= 0) {
        std::fprintf(stderr, "pool_size and num_tasks must be positive\n");
        return 2;
    }

    std::atomic<int> next_task{0};
    std::atomic<std::uint64_t> sink{0};
    std::vector<std::vector<long>> per_thread_us(pool_size);

    const auto wall_start = clock_type::now();

    std::vector<std::thread> pool;
    pool.reserve(pool_size);
    for (unsigned t = 0; t < pool_size; ++t) {
        pool.emplace_back([&, t] {
            auto& mine = per_thread_us[t];
            mine.reserve(static_cast<std::size_t>(num_tasks) / pool_size + 1);
            for (;;) {
                const int task = next_task.fetch_add(1, std::memory_order_relaxed);
                if (task >= num_tasks) break;
                const auto t0 = clock_type::now();
                const std::uint64_t r = busy(iters);
                const auto t1 = clock_type::now();
                sink.fetch_add(r, std::memory_order_relaxed);
                mine.push_back(
                    std::chrono::duration_cast<std::chrono::microseconds>(t1 - t0)
                        .count());
            }
        });
    }
    for (auto& th : pool) th.join();

    const auto wall_end = clock_type::now();
    const double wall_ms =
        std::chrono::duration<double, std::milli>(wall_end - wall_start).count();

    std::vector<long> all;
    all.reserve(static_cast<std::size_t>(num_tasks));
    for (auto& v : per_thread_us) all.insert(all.end(), v.begin(), v.end());
    std::sort(all.begin(), all.end());

    const double throughput =
        wall_ms > 0 ? (static_cast<double>(num_tasks) * 1000.0 / wall_ms) : 0.0;

    // Single-line, greppable result.
    std::printf("pool=%u tasks=%d wall_ms=%.1f throughput=%.0f/s "
                "task_us_p50=%ld p99=%ld max=%ld sink=%llu\n",
                pool_size, num_tasks, wall_ms, throughput,
                pctile(all, 50.0), pctile(all, 99.0),
                all.empty() ? 0 : all.back(),
                static_cast<unsigned long long>(sink.load()));
    return 0;
}
