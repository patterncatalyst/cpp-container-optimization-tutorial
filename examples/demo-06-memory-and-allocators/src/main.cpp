// Demo-06 — main entry point (r81 — two modes: batch + serve).
//
// One main.cpp, three binaries. The ALLOC_TYPE_* compile-time
// define selects which variant this binary is. For mimalloc, the
// allocator replacement happens via the linker (CMakeLists.txt's
// --whole-archive trick); the source code is identical to
// ALLOC_TYPE_STD because the global new/delete substitution is
// invisible at the language level.
//
// For PMR, the source code is genuinely different: it threads a
// std::pmr::polymorphic_allocator through the workload via the
// PmrNode constructor. The arena is a monotonic_buffer_resource
// backed by a stack buffer, falling back to a synchronized
// pool_resource backed by the global allocator.
//
// (r71-r74 attempted to add jemalloc as a fourth variant; see
// those plan entries for the build-toolchain incompatibility
// story. §7 prose describes jemalloc as an alternative to mimalloc
// without requiring the binary to build.)
//
// ── Execution modes ───────────────────────────────────────────────
//
// **Batch mode** (default, since r75): run N iterations of the
// workload and print one line of JSON stats to stdout. Used by
// demo.sh to build the comparison table. Argv positional args:
//
//     ./demo06-svc-XXX [iters [depth [branch [values]]]]
//
// **Serve mode** (added r81): start an HTTP server on :8080 with
// the same workload runnable per request. Endpoints:
//
//     GET /healthz         — liveness probe, returns "ok"
//     GET /info            — variant + workload defaults, JSON
//     GET /run?iters=N     — runs N iters (default 1), returns
//                            single-line JSON identical to batch
//                            mode's output
//
// Mode is selected by:
//   1. argv contains `--serve` (anywhere), OR
//   2. env var DEMO06_MODE=serve
//
// In serve mode, depth/branch/values argv are still parsed for the
// workload's defaults; `iters` becomes irrelevant (each /run
// request specifies its own count).
//
// Serve mode is the foundation for r82's OTel instrumentation —
// each /run will become a span, latency a histogram metric, etc.

#include "workload.hpp"

#include <httplib.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <memory_resource>
#include <string>
#include <thread>
#include <vector>

namespace {

// ── Compile-time variant label ────────────────────────────────────────
#if defined(ALLOC_TYPE_STD)
    constexpr const char* kVariantName = "std::allocator";
    constexpr const char* kVariantSlug = "std";
#elif defined(ALLOC_TYPE_PMR)
    constexpr const char* kVariantName = "std::pmr (monotonic+sync_pool)";
    constexpr const char* kVariantSlug = "pmr";
#elif defined(ALLOC_TYPE_MIMALLOC)
    constexpr const char* kVariantName = "mimalloc";
    constexpr const char* kVariantSlug = "mimalloc";
#else
    #error "demo-06 main.cpp must be compiled with one of ALLOC_TYPE_*"
#endif

// ── Args ──────────────────────────────────────────────────────────────
struct Args {
    int iterations = 200;
    int max_depth  = 6;
    int branch     = 4;
    int values     = 8;
    bool serve     = false;
};

Args parse_args(int argc, char** argv) {
    Args a;
    // Walk argv once: --serve sets the mode flag, anything else is
    // treated as a positional argument in original order.
    std::vector<const char*> positional;
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--serve") == 0) {
            a.serve = true;
        } else {
            positional.push_back(argv[i]);
        }
    }
    if (positional.size() >= 1) a.iterations = std::atoi(positional[0]);
    if (positional.size() >= 2) a.max_depth  = std::atoi(positional[1]);
    if (positional.size() >= 3) a.branch     = std::atoi(positional[2]);
    if (positional.size() >= 4) a.values     = std::atoi(positional[3]);

    // Env override for mode selection (matches demo-04's pattern).
    if (!a.serve) {
        if (const char* mode = std::getenv("DEMO06_MODE")) {
            if (std::strcmp(mode, "serve") == 0) a.serve = true;
        }
    }
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

#else  // ALLOC_TYPE_STD / MIMALLOC — both use std types

std::uint64_t run_iteration(const demo06::WorkloadParams& p) {
    auto root = demo06::build_tree(p);
    return demo06::walk_tree(root);
}

#endif

// ── Iteration loop + stats ────────────────────────────────────────────
// Factored out of main() in r81 so that both batch and serve modes
// can call it. Batch mode calls once with args.iterations; serve
// mode calls once per /run request with the request's iters count.

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

demo06::RunStats run_iterations(int n, const demo06::WorkloadParams& params) {
    std::vector<double> latencies_us;
    latencies_us.reserve(static_cast<std::size_t>(n));

    std::uint64_t last_hash = 0;
    auto t_start = std::chrono::steady_clock::now();
    for (int i = 0; i < n; ++i) {
        auto t0 = std::chrono::steady_clock::now();
        last_hash = run_iteration(params);
        auto t1 = std::chrono::steady_clock::now();
        latencies_us.push_back(
            std::chrono::duration<double, std::micro>(t1 - t0).count());
    }
    auto t_end = std::chrono::steady_clock::now();
    double total_seconds = std::chrono::duration<double>(t_end - t_start).count();
    return summarize(latencies_us, total_seconds, last_hash);
}

// ── JSON formatting ───────────────────────────────────────────────────
// Shared between batch and serve modes. Output is single-line, no
// surrounding whitespace, so it pipes cleanly to jq.

std::string stats_to_json(const demo06::RunStats& s) {
    char buf[512];
    int n = std::snprintf(buf, sizeof(buf),
        "{\"variant\":\"%s\","
        "\"iterations\":%llu,"
        "\"total_seconds\":%.4f,"
        "\"min_us\":%.2f,"
        "\"p50_us\":%.2f,"
        "\"p99_us\":%.2f,"
        "\"max_us\":%.2f,"
        "\"throughput_per_sec\":%.1f,"
        "\"result_hash\":\"0x%016llx\"}",
        kVariantName,
        static_cast<unsigned long long>(s.iterations),
        s.total_seconds,
        s.min_us, s.p50_us, s.p99_us, s.max_us,
        s.total_seconds > 0
            ? static_cast<double>(s.iterations) / s.total_seconds
            : 0.0,
        static_cast<unsigned long long>(s.result_hash));
    return std::string(buf, static_cast<std::size_t>(n));
}

// ── Mode: batch ───────────────────────────────────────────────────────
// Original demo-06 behavior preserved as default. Print one line of
// JSON to stdout; demo.sh consumes via jq.

int run_batch_mode(const Args& args, const demo06::WorkloadParams& params) {
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

    auto s = run_iterations(args.iterations, params);
    std::printf("%s\n", stats_to_json(s).c_str());
    return 0;
}

// ── Mode: serve ───────────────────────────────────────────────────────
// HTTP server with /healthz, /info, /run endpoints. Warmup runs once
// at startup so subsequent /run requests measure hot-path behavior.
// Listens on :8080. r82 will wire OpenTelemetry through the
// handlers (spans around each /run, request counter, latency
// histogram, structured access logs).

std::atomic<bool> g_stop{false};
void on_signal(int) { g_stop = true; }

int run_serve_mode(const Args& /*args*/, const demo06::WorkloadParams& params) {
    std::cerr << "[demo06] variant=" << kVariantName
              << " mode=serve"
              << " depth=" << params.max_depth
              << " branch=" << params.branch_factor_max
              << " values=" << params.values_max << "\n";

    // Warmup at startup so first /run isn't penalized for cold
    // allocator state. 50 iters here vs 10 in batch mode: a real
    // service is up for hours, so we err on the side of a fuller
    // warmup at the cost of slightly slower startup.
    std::cerr << "[demo06] warming up (50 iters)...\n";
    for (int i = 0; i < 50; ++i) (void)run_iteration(params);

    std::signal(SIGTERM, on_signal);
    std::signal(SIGINT,  on_signal);

    httplib::Server svr;

    // ── httplib config knobs — r82 ───────────────────────────────
    //
    // cpp-httplib's defaults are tuned for low-concurrency embedded
    // use; under any meaningful load they produce surprising
    // backpressure. The defaults that hurt us:
    //
    //   keep_alive_max_count:   5       — each connection retired
    //                                     after 5 requests, forcing
    //                                     new TCP setup constantly
    //   keep_alive_timeout_sec: 5       — idle conns die in 5s,
    //                                     same churn problem
    //   ThreadPool size:        hw_concurrency (typically 4-8)
    //                                   — too small for 50+ hey
    //                                     workers
    //
    // r81's hey output showed the cost: 274ms average response
    // time for 10µs of actual work, 10-second tail latencies, all
    // because the listen backlog filled with reopen-storms and TCP
    // retransmits kicked in.
    //
    // The bumps below are conservative — still way under what a
    // production HTTP server would set, but enough that hey's
    // default 50 concurrent workers don't trigger pathological
    // queue thrashing. With these settings, hey -z 5s should
    // produce throughput numbers that reflect the workload, not
    // the connection-management overhead.
    svr.set_keep_alive_max_count(1000);
    svr.set_keep_alive_timeout(60);
    svr.new_task_queue = [] { return new httplib::ThreadPool(16); };

    svr.Get("/healthz", [](const httplib::Request&, httplib::Response& res) {
        res.set_content("ok", "text/plain");
    });

    svr.Get("/info", [&params](const httplib::Request&, httplib::Response& res) {
        char buf[256];
        std::snprintf(buf, sizeof(buf),
            "{\"variant\":\"%s\",\"slug\":\"%s\","
            "\"depth\":%d,\"branch\":%d,\"values\":%d}",
            kVariantName, kVariantSlug,
            params.max_depth, params.branch_factor_max, params.values_max);
        res.set_content(buf, "application/json");
    });

    svr.Get("/run", [&params](const httplib::Request& req, httplib::Response& res) {
        int iters = 1;
        if (req.has_param("iters")) {
            iters = std::atoi(req.get_param_value("iters").c_str());
        }
        // Bounded for safety — a misconfigured load generator with
        // iters=10000000 would tie up the server.
        if (iters < 1)     iters = 1;
        if (iters > 10000) iters = 10000;

        auto s = run_iterations(iters, params);
        res.set_content(stats_to_json(s), "application/json");
    });

    std::cerr << "[demo06] listening on :8080 (variant=" << kVariantSlug << ")\n";

    // Run server in a detached thread so we can block on the stop
    // signal in main. svr.stop() unblocks the listener cleanly.
    std::thread listener([&svr] { svr.listen("0.0.0.0", 8080); });

    while (!g_stop.load(std::memory_order_relaxed)) {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    std::cerr << "[demo06] stopping...\n";
    svr.stop();
    listener.join();
    return 0;
}

}  // namespace

int main(int argc, char** argv) {
    auto args = parse_args(argc, argv);
    demo06::WorkloadParams params;
    params.max_depth         = args.max_depth;
    params.branch_factor_max = args.branch;
    params.values_max        = args.values;

    return args.serve
        ? run_serve_mode(args, params)
        : run_batch_mode(args, params);
}
