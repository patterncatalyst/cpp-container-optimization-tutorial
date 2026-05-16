// Demo-06 — main entry point (r71 v1: no HTTP, no OTel, no layers).
//
// One main.cpp, four binaries. The ALLOC_TYPE_* compile-time
// define selects which variant this binary is. For mimalloc and
// jemalloc, the allocator replacement happens via the linker
// (CMakeLists.txt's --whole-archive trick); the source code is
// identical to ALLOC_TYPE_STD because the global new/delete
// substitution is invisible at the language level.
//
// For PMR, the source code is genuinely different: it threads a
// std::pmr::polymorphic_allocator through the workload via the
// PmrNode constructor. The arena is a monotonic_buffer_resource
// backed by a stack buffer, falling back to a synchronized
// pool_resource backed by the global allocator.
//
// Output: a single line of JSON to stdout per invocation. demo.sh
// captures these from each of the four binaries and prints a
// comparison table.

#include "workload.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <iostream>
#include <memory_resource>
#include <string>
#include <vector>

namespace {

// ── Compile-time variant label ────────────────────────────────────────
#if defined(ALLOC_TYPE_STD)
    constexpr const char* kVariantName = "std::allocator";
#elif defined(ALLOC_TYPE_PMR)
    constexpr const char* kVariantName = "std::pmr (monotonic+sync_pool)";
#elif defined(ALLOC_TYPE_MIMALLOC)
    constexpr const char* kVariantName = "mimalloc";
#elif defined(ALLOC_TYPE_JEMALLOC)
    constexpr const char* kVariantName = "jemalloc";
#else
    #error "demo-06 main.cpp must be compiled with one of ALLOC_TYPE_*"
#endif

// ── Args ──────────────────────────────────────────────────────────────
struct Args {
    int iterations = 200;
    int max_depth  = 6;
    int branch     = 4;
    int values     = 8;
};

Args parse_args(int argc, char** argv) {
    Args a;
    if (argc >= 2) a.iterations = std::atoi(argv[1]);
    if (argc >= 3) a.max_depth  = std::atoi(argv[2]);
    if (argc >= 4) a.branch     = std::atoi(argv[3]);
    if (argc >= 5) a.values     = std::atoi(argv[4]);
    return a;
}

// ── Per-iteration runner ──────────────────────────────────────────────
// The work done by ONE iteration: build a tree, walk it (anti-DCE
// hash), drop the tree on scope exit. Each variant has its own
// implementation because PMR is type-different from the std::-types
// version. Returns the hash result (must match across variants for
// the same seed).

#if defined(ALLOC_TYPE_PMR)

// PMR: use a monotonic_buffer_resource backed by a generous stack
// buffer. When the buffer is exhausted, the buffer resource falls
// back to its upstream (we use the default new/delete-based resource).
// On scope exit, ALL per-request allocations are released in a single
// arena-reset. This is the canonical "request-scoped arena" PMR
// pattern from Andrist & Sehr Ch. 7.
std::uint64_t run_iteration(const demo06::WorkloadParams& p) {
    // 1 MB stack arena. Sized to fit ~95% of typical tree workloads
    // before falling back to upstream; we deliberately allow some
    // upstream calls so the comparison sees mixed behavior.
    alignas(std::max_align_t) static thread_local std::array<std::byte, 1 << 20> buf;
    std::pmr::monotonic_buffer_resource arena(
        buf.data(), buf.size(),
        std::pmr::new_delete_resource());

    auto root = demo06::build_tree_pmr(p, &arena);
    return demo06::walk_tree_pmr(root);
    // arena destructor releases everything in one swoop. The tree's
    // destructors run (they're virtual-free for trivially-destructible
    // types; PMR types are NOT trivially destructible because they
    // hold an allocator, but the destructors don't free the underlying
    // memory — that's the arena's job).
}

#else  // ALLOC_TYPE_STD / MIMALLOC / JEMALLOC — all use std types

std::uint64_t run_iteration(const demo06::WorkloadParams& p) {
    auto root = demo06::build_tree(p);
    return demo06::walk_tree(root);
}

#endif

// ── Summary stats from iteration latencies ────────────────────────────

demo06::RunStats summarize(std::vector<double>& latencies_us,
                           double total_seconds,
                           std::uint64_t last_hash) {
    demo06::RunStats s{};
    s.total_seconds = total_seconds;
    s.iterations    = latencies_us.size();
    s.result_hash   = last_hash;
    std::sort(latencies_us.begin(), latencies_us.end());
    auto n = latencies_us.size();
    auto p = [&](double q) {
        auto i = std::min(static_cast<std::size_t>(q * static_cast<double>(n)), n - 1);
        return latencies_us[i];
    };
    s.min_us = latencies_us.front();
    s.p50_us = p(0.50);
    s.p99_us = p(0.99);
    s.max_us = latencies_us.back();
    return s;
}

}  // namespace

int main(int argc, char** argv) {
    auto args = parse_args(argc, argv);
    demo06::WorkloadParams params;
    params.max_depth         = args.max_depth;
    params.branch_factor_max = args.branch;
    params.values_max        = args.values;

    std::cerr << "[demo06] variant=" << kVariantName
              << " iterations=" << args.iterations
              << " depth=" << params.max_depth
              << " branch=" << params.branch_factor_max
              << " values=" << params.values_max << "\n";

    // Warmup — 10 iterations not counted. Allocators all have
    // first-use overheads (lazy initialization, internal arena
    // creation) that we don't want to charge against the first
    // measured iteration.
    for (int i = 0; i < 10; ++i) (void)run_iteration(params);

    std::vector<double> latencies_us;
    latencies_us.reserve(static_cast<std::size_t>(args.iterations));

    std::uint64_t last_hash = 0;
    auto t_start = std::chrono::steady_clock::now();
    for (int i = 0; i < args.iterations; ++i) {
        auto t0 = std::chrono::steady_clock::now();
        last_hash = run_iteration(params);
        auto t1 = std::chrono::steady_clock::now();
        latencies_us.push_back(
            std::chrono::duration<double, std::micro>(t1 - t0).count());
    }
    auto t_end = std::chrono::steady_clock::now();
    double total_seconds = std::chrono::duration<double>(t_end - t_start).count();

    auto s = summarize(latencies_us, total_seconds, last_hash);

    // Single-line JSON for jq parsing in demo.sh.
    std::printf(
        "{\"variant\":\"%s\","
        "\"iterations\":%llu,"
        "\"total_seconds\":%.4f,"
        "\"min_us\":%.2f,"
        "\"p50_us\":%.2f,"
        "\"p99_us\":%.2f,"
        "\"max_us\":%.2f,"
        "\"throughput_per_sec\":%.1f,"
        "\"result_hash\":\"0x%016llx\"}\n",
        kVariantName,
        static_cast<unsigned long long>(s.iterations),
        s.total_seconds,
        s.min_us, s.p50_us, s.p99_us, s.max_us,
        static_cast<double>(s.iterations) / s.total_seconds,
        static_cast<unsigned long long>(s.result_hash));
    return 0;
}
