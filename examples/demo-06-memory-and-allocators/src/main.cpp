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

#include <netinet/tcp.h>  // TCP_NODELAY constant
#include <sys/socket.h>   // setsockopt, SOL_SOCKET, SO_REUSEADDR

// ── OTel includes (r85) ────────────────────────────────────────────────
//
// Conditional gating happens at runtime via the
// OTEL_EXPORTER_OTLP_ENDPOINT env var check in run_serve_mode.
// The headers themselves are always pulled in because the binary
// is linked against opentelemetry-cpp unconditionally — the static
// link means there's no runtime cost beyond a few KB of code.
// Mode selection: with no env var set, init_otel() is never
// called and the global providers stay as no-op stubs.
//
// Why the explicit processor.h includes (G-29): factory Create()
// methods return std::unique_ptr<T> where T is forward-declared in
// the factory header but not fully defined there. The unique_ptr
// destructor needs the complete type at the call site.
#include "opentelemetry/exporters/otlp/otlp_grpc_exporter_factory.h"
#include "opentelemetry/exporters/otlp/otlp_grpc_log_record_exporter_factory.h"
#include "opentelemetry/exporters/otlp/otlp_grpc_metric_exporter_factory.h"
#include "opentelemetry/logs/provider.h"
#include "opentelemetry/metrics/provider.h"
#include "opentelemetry/sdk/logs/logger_provider_factory.h"
#include "opentelemetry/sdk/logs/processor.h"
#include "opentelemetry/sdk/logs/batch_log_record_processor_factory.h"
#include "opentelemetry/sdk/logs/batch_log_record_processor_options.h"
#include "opentelemetry/sdk/metrics/export/periodic_exporting_metric_reader_factory.h"
#include "opentelemetry/sdk/metrics/meter_provider.h"
#include "opentelemetry/sdk/metrics/view/view_registry.h"
#include "opentelemetry/sdk/resource/resource.h"
#include "opentelemetry/sdk/trace/processor.h"
#include "opentelemetry/sdk/trace/batch_span_processor_factory.h"
#include "opentelemetry/sdk/trace/batch_span_processor_options.h"
#include "opentelemetry/sdk/trace/tracer_provider_factory.h"
#include "opentelemetry/trace/provider.h"

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
#include <memory>
#include <memory_resource>
#include <string>
#include <thread>
#include <vector>

namespace otel  = opentelemetry;
namespace otlp  = otel::exporter::otlp;
namespace sdk_t = otel::sdk::trace;
namespace sdk_m = otel::sdk::metrics;
namespace sdk_l = otel::sdk::logs;

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

// ── OTel SDK init (r85 + r88) ──────────────────────────────────────────
//
// Lifted from demo-04's init_otel (~75 lines) with the
// service_name parameterized so all three variants share one
// function. Long-term: should be hoisted to a shared
// `examples/common/otel_setup.hpp` so demo-04 and demo-06 (and
// any future OTel-using demo) share one source of truth. For r85
// we inline-copy; the lift-to-shared-header is a follow-up round.
//
// The function is a no-op if OTEL_EXPORTER_OTLP_ENDPOINT is unset.
// run_serve_mode below checks that env var before calling init_otel,
// so we don't pay any OTel init cost (or get spammed with retry
// warnings) when running compose-serve.yml without LGTM.
//
// r88: switched both SpanProcessor and LogRecordProcessor from
// Simple* to Batch*. r87 measured the cost of Simple* (synchronous
// gRPC export on every span->End() and EmitLogRecord call): 8.5x
// throughput drop, 13x p50 increase. Batch processors queue spans
// and logs for periodic export by a background thread, keeping
// the hot path near-free. See _plans/teaching-points.md for the
// full "Simple vs Batch" mini-essay (a candidate §10 prose nugget).
//
// Metrics are *unchanged* from r85 — PeriodicExportingMetricReader
// is already batch-like by design, exporting accumulated metric
// state every 5 seconds regardless of how many counter->Add or
// histogram->Record calls happened. There is no "Simple" analog
// for metrics in OTel-cpp; the metric pipeline is naturally
// cheap-per-call by design.
//
// Why nostd::shared_ptr and .release() patterns (G-19, G-20):
// OTel-cpp's API/SDK split means factory return types differ by
// version. The pattern below works across 1.14.x and 1.16+. See
// the inline comments and demo-04's main.cpp for the full
// version-compat archaeology.
void init_otel(const std::string& service_name) {
    auto resource = otel::sdk::resource::Resource::Create({
        {"service.name",         service_name},
        {"service.version",      "0.1.0"},
        {"deployment.environment", "tutorial-demo-06"}
    });

    namespace nostd = otel::nostd;

    // ── Tracing ────────────────────────────────────────────────
    // r88: BatchSpanProcessor (not Simple). The Simple processor
    // exports each span synchronously inside span->End(), turning
    // every instrumented request into a gRPC round-trip on the
    // hot path. Demo-06 r87 measured the cost: 18,469 req/s →
    // 2,170 req/s, p50 200µs → 2.7ms. Batch processor queues
    // spans for periodic export by a background thread, keeping
    // the hot path near-free (~5µs per span instead of ~100µs).
    //
    // Default options (set 2024 in OTel-cpp 1.14.x):
    //   max_queue_size:           2048
    //   schedule_delay_millis:    5000 (matches metric export tick)
    //   max_export_batch_size:    512
    //
    // We use defaults for clarity. Tutorial value is in the
    // Simple-vs-Batch contrast; tuning further is a separate
    // exercise.
    //
    // Trade-off: spans show up in Tempo 5 seconds later than they
    // would with Simple. For production this is fine; for
    // debugging a specific request mid-development, Simple is
    // briefly preferable. The talk's §10 prose covers this
    // decision in depth — see _plans/teaching-points.md.
    {
        otlp::OtlpGrpcExporterOptions opts;
        auto exporter  = otlp::OtlpGrpcExporterFactory::Create(opts);

        sdk_t::BatchSpanProcessorOptions batch_opts;
        auto processor = sdk_t::BatchSpanProcessorFactory::Create(
            std::move(exporter), batch_opts);

        auto provider_unique =
            sdk_t::TracerProviderFactory::Create(std::move(processor), resource);
        nostd::shared_ptr<otel::trace::TracerProvider> provider(provider_unique.release());
        otel::trace::Provider::SetTracerProvider(provider);
    }

    // ── Metrics ────────────────────────────────────────────────
    // 5-second export interval is the OTel-cpp default for the
    // periodic exporter. Tutorial-friendly: short enough to see
    // hey-driven traffic show up in Grafana within ~10 seconds.
    {
        otlp::OtlpGrpcMetricExporterOptions opts;
        auto exporter = otlp::OtlpGrpcMetricExporterFactory::Create(opts);

        sdk_m::PeriodicExportingMetricReaderOptions reader_opts;
        reader_opts.export_interval_millis = std::chrono::milliseconds(5000);
        auto reader = sdk_m::PeriodicExportingMetricReaderFactory::Create(
            std::move(exporter), reader_opts);

        auto views = std::unique_ptr<sdk_m::ViewRegistry>(new sdk_m::ViewRegistry());
        auto sdk_provider = std::shared_ptr<sdk_m::MeterProvider>(
            new sdk_m::MeterProvider(std::move(views), resource));
        sdk_provider->AddMetricReader(
            std::shared_ptr<sdk_m::MetricReader>(std::move(reader)));

        nostd::shared_ptr<otel::metrics::MeterProvider> api_provider(
            static_cast<otel::metrics::MeterProvider*>(sdk_provider.get()));
        // Leak to static so the std::shared_ptr-owned sdk_provider
        // stays alive for process lifetime. The nostd::shared_ptr
        // doesn't own; this is the init-once pattern from demo-04.
        static auto leak [[maybe_unused]] = sdk_provider;
        otel::metrics::Provider::SetMeterProvider(api_provider);
    }

    // ── Logs ────────────────────────────────────────────────
    // Same Batch-vs-Simple decision as Tracing above. Logs are
    // even more bursty than spans in many services (multi-line
    // structured logs per request), so the per-call cost of
    // synchronous export hits even harder. Batch defaults match
    // the span processor.
    {
        otlp::OtlpGrpcLogRecordExporterOptions opts;
        auto exporter  = otlp::OtlpGrpcLogRecordExporterFactory::Create(opts);

        sdk_l::BatchLogRecordProcessorOptions batch_opts;
        auto processor = sdk_l::BatchLogRecordProcessorFactory::Create(
            std::move(exporter), batch_opts);

        auto provider_unique =
            sdk_l::LoggerProviderFactory::Create(std::move(processor), resource);
        nostd::shared_ptr<otel::logs::LoggerProvider> provider(provider_unique.release());
        otel::logs::Provider::SetLoggerProvider(provider);
    }
}

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

    // ── OTel init (r85) ──────────────────────────────────────────
    //
    // Gate on OTEL_EXPORTER_OTLP_ENDPOINT being present. Without
    // it, the OTel SDK is never initialized — the global providers
    // stay as no-op stubs and the /run handler's telemetry calls
    // are cheap (each call hits a static no-op TracerProvider /
    // MeterProvider / LoggerProvider). This is the same gating
    // pattern that lets compose-serve.yml run without LGTM and
    // compose-observe.yml run with LGTM, off the same binary.
    const char* otel_endpoint = std::getenv("OTEL_EXPORTER_OTLP_ENDPOINT");
    const bool otel_enabled = (otel_endpoint != nullptr && otel_endpoint[0] != '\0');
    if (otel_enabled) {
        std::string svc = "demo06-svc-";
        svc += kVariantSlug;
        std::cerr << "[demo06] OTel enabled (endpoint=" << otel_endpoint
                  << ", service=" << svc << ")\n";
        init_otel(svc);
    } else {
        std::cerr << "[demo06] OTel disabled "
                     "(OTEL_EXPORTER_OTLP_ENDPOINT unset)\n";
    }

    std::signal(SIGTERM, on_signal);
    std::signal(SIGINT,  on_signal);

    httplib::Server svr;

    // ── httplib config knobs — r82 + r83 ─────────────────────────
    //
    // cpp-httplib's defaults are tuned for low-concurrency embedded
    // use; under any meaningful load they produce surprising
    // backpressure. r82 fixed the connection-cycling pathology
    // (keep-alive too short + thread pool too small). r83 added
    // the per-packet fix (Nagle's algorithm).
    //
    // ── r82: connection-level defaults ──────────────────────────
    //
    // The defaults that hurt:
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
    // r81's hey output: 274ms average, 10-second tail latencies.
    //
    // ── r83: TCP_NODELAY (per-packet) ───────────────────────────
    //
    // r82 fixed the connection layer; r82's hey output then showed
    // every request bunched at exactly 42ms, with server work
    // taking 200µs but client reads taking 40ms. Smoking gun: the
    // 40ms Linux delayed-ACK timeout.
    //
    // What's happening: httplib writes the HTTP response in
    // multiple small write() calls (status, headers, body).
    // Nagle's algorithm (on by default) holds the second packet
    // until ACK for the first arrives. The client's TCP stack
    // does delayed-ACK — waits up to 40ms hoping to piggyback the
    // ACK on outgoing data. Since the client just sent a request
    // and has nothing else to send, the 40ms timer fires before
    // the ACK goes back. Server's second packet waited the whole
    // 40ms.
    //
    // TCP_NODELAY disables Nagle on accepted sockets; small writes
    // go out immediately. Trade-off: more packets on the wire for
    // chatty protocols. For HTTP-style request/response, NODELAY
    // is the right answer — minimum-RTT response is more valuable
    // than minimum-packet-count.
    //
    // Note re SO_REUSEADDR: httplib's default callback sets it.
    // Calling set_socket_options REPLACES the default callback,
    // so we must re-set SO_REUSEADDR ourselves or rapid start/stop
    // cycles will fail with EADDRINUSE.
    svr.set_keep_alive_max_count(1000);
    svr.set_keep_alive_timeout(60);
    svr.new_task_queue = [] { return new httplib::ThreadPool(16); };
    // Generic lambda (auto sock) avoids the question of where
    // `socket_t` lives in any given cpp-httplib version. In v0.16.0
    // it's declared at global scope (not `httplib::socket_t`); r83's
    // first attempt got the qualifier wrong. With `auto`, the lambda
    // becomes a function template and the compiler deduces the
    // parameter type from httplib's std::function<void(socket_t)>
    // signature when set_socket_options stores the callback.
    svr.set_socket_options([](auto sock) {
        int yes = 1;
        setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    });

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

    // ── OTel handles for the /run instrumentation ────────────────
    //
    // When otel_enabled is false, the global providers return
    // no-op tracer/meter/logger handles and the per-request calls
    // below are cheap. When true, they emit spans / counter
    // increments / histogram records / log records to OTLP/gRPC.
    auto tracer = otel::trace::Provider::GetTracerProvider()
                      ->GetTracer("demo06");
    auto meter  = otel::metrics::Provider::GetMeterProvider()
                      ->GetMeter("demo06");
    auto logger = otel::logs::Provider::GetLoggerProvider()
                      ->GetLogger("demo06");
    auto request_counter = meter->CreateUInt64Counter(
        "demo06.requests", "Number of /run requests handled");
    auto latency_hist = meter->CreateDoubleHistogram(
        "demo06.request.duration", "Request latency", "ms");

    svr.Get("/run",
        // Capture rules here matter for OTel-cpp:
        // - `tracer`, `meter`, `logger` are nostd::shared_ptr<T> — copyable,
        //   captured by value (each lambda copy bumps the shared_ptr's
        //   refcount; underlying provider stays alive via the global registry).
        // - `request_counter`, `latency_hist` are nostd::unique_ptr<T>
        //   (Meter::CreateUInt64Counter and CreateDoubleHistogram return
        //   move-only handles, one owner per metric). Lambdas can't copy
        //   them, so we capture by reference. The references stay valid
        //   for the lambda's lifetime because both objects live in
        //   run_serve_mode's stack frame, which is kept alive by the
        //   blocking signal-wait loop below.
        // - `params` is a const& parameter; capture by reference matches its
        //   incoming binding.
        //
        // r86 originally captured request_counter and latency_hist by value,
        // which hit "use of deleted function" on the unique_ptr copy
        // constructor. Fixed in r87.
        [&params, tracer, meter, logger, &request_counter, &latency_hist]
        (const httplib::Request& req, httplib::Response& res) {
            auto t0 = std::chrono::steady_clock::now();
            auto span = tracer->StartSpan("run");
            otel::trace::Scope scope(span);

            int iters = 1;
            if (req.has_param("iters")) {
                iters = std::atoi(req.get_param_value("iters").c_str());
            }
            // Bounded for safety — a misconfigured load generator
            // with iters=10000000 would tie up the server.
            if (iters < 1)     iters = 1;
            if (iters > 10000) iters = 10000;

            span->SetAttribute("iters",   iters);
            span->SetAttribute("variant", kVariantSlug);

            auto s = run_iterations(iters, params);
            res.set_content(stats_to_json(s), "application/json");

            auto t1 = std::chrono::steady_clock::now();
            double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();

            // Metrics — both counter and histogram tagged with the
            // variant slug so Mimir/Prometheus can split by allocator.
            request_counter->Add(1, {
                {"variant", kVariantSlug},
                {"route",   "/run"}
            });
            latency_hist->Record(ms,
                {{"variant", kVariantSlug}},
                otel::context::Context{});

            logger->EmitLogRecord(
                otel::logs::Severity::kInfo,
                "/run handled");

            span->End();
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
