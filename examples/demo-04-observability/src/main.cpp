// Demo 4 — small HTTP service instrumented with OpenTelemetry.
//
// Emits:
//   - traces: each request creates a span; downstream "work" wrapped in a child span
//   - metrics: a request counter and a latency histogram
//   - logs: structured access log via OTel logs API
//
// Exporters: OTLP/gRPC for all three signals, pointing at the observability
// stack's OTel collector / Tempo / Loki / Mimir. Endpoints are read from
// OTEL_EXPORTER_OTLP_ENDPOINT in the environment.

#include <httplib.h>

#include "opentelemetry/exporters/otlp/otlp_grpc_exporter_factory.h"
#include "opentelemetry/exporters/otlp/otlp_grpc_log_record_exporter_factory.h"
#include "opentelemetry/exporters/otlp/otlp_grpc_metric_exporter_factory.h"
#include "opentelemetry/logs/provider.h"
#include "opentelemetry/metrics/provider.h"
#include "opentelemetry/sdk/logs/logger_provider_factory.h"
#include "opentelemetry/sdk/logs/simple_log_record_processor_factory.h"
#include "opentelemetry/sdk/metrics/export/periodic_exporting_metric_reader_factory.h"
#include "opentelemetry/sdk/metrics/meter_provider.h"
#include "opentelemetry/sdk/metrics/view/view_registry.h"
#include "opentelemetry/sdk/resource/resource.h"
#include "opentelemetry/sdk/trace/simple_processor_factory.h"
#include "opentelemetry/sdk/trace/tracer_provider_factory.h"
#include "opentelemetry/trace/provider.h"

#include <atomic>
#include <chrono>
#include <csignal>
#include <memory>
#include <print>
#include <string>
#include <thread>

namespace otel = opentelemetry;
namespace otlp = otel::exporter::otlp;
namespace sdk_t = otel::sdk::trace;
namespace sdk_m = otel::sdk::metrics;
namespace sdk_l = otel::sdk::logs;

namespace {

std::atomic<bool> g_stop{false};
void on_sigterm(int) { g_stop = true; }

void init_otel(const std::string& service_name) {
    auto resource = otel::sdk::resource::Resource::Create({
        {"service.name", service_name},
        {"service.version", "0.1.0"},
        {"deployment.environment", "tutorial-demo-04"}
    });

    namespace nostd = otel::nostd;

    // ---- Tracing ----
    // Why nostd::shared_ptr (not std::shared_ptr) and the explicit .release():
    // OTel-cpp 1.16.0 changed factory return types from api::T to sdk::T
    // (CHANGELOG: "these methods return an SDK level object ... instead of
    // an API object"). Code that worked in 1.16+ (assigning factory result
    // to std::shared_ptr<api::T> with implicit conversion) won't work in
    // 1.14.x where the factory already returns api::T as unique_ptr.
    //
    // The compatible pattern: take .release() from the unique_ptr (which
    // returns either api::T* in 1.14.x or sdk::T* in 1.16+), and construct
    // a nostd::shared_ptr<api::T> from the raw pointer. Both work because
    // sdk::T derives from api::T. SetTracerProvider takes nostd::shared_ptr
    // natively in every version.
    {
        otlp::OtlpGrpcExporterOptions opts;
        auto exporter  = otlp::OtlpGrpcExporterFactory::Create(opts);
        auto processor = sdk_t::SimpleSpanProcessorFactory::Create(std::move(exporter));
        auto provider_unique =
            sdk_t::TracerProviderFactory::Create(std::move(processor), resource);
        nostd::shared_ptr<otel::trace::TracerProvider> provider(provider_unique.release());
        otel::trace::Provider::SetTracerProvider(provider);
    }

    // ---- Metrics ----
    // MeterProviderFactory is awkward across versions — its convenience
    // overload returns the API base which doesn't expose AddMetricReader.
    // Construct the SDK MeterProvider directly via std::shared_ptr<sdk::T>
    // so we have a typed handle to call AddMetricReader on, then upcast
    // to nostd::shared_ptr<api::T> for the global registry. The
    // sdk::MeterProvider(views, resource) constructor signature is stable
    // across 1.14 and 1.16+ (only the deeper MeterContext-owning ctor
    // changed in #2218; the convenience overload kept its shape).
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

        // Upcast to nostd::shared_ptr<api::MeterProvider> via aliasing.
        // The .get() returns the same raw pointer; the nostd::shared_ptr
        // takes a non-owning view of the std::shared_ptr-managed memory
        // because sdk_provider stays alive for the duration of the
        // process anyway (held in this scope's automatic storage until
        // scope exit, but the global Provider keeps its own reference).
        nostd::shared_ptr<otel::metrics::MeterProvider> api_provider(
            static_cast<otel::metrics::MeterProvider*>(sdk_provider.get()));
        // Manually keep sdk_provider alive: leak it to a static so the
        // memory the nostd::shared_ptr now references doesn't disappear
        // when this scope exits. Acceptable for an init-once pattern.
        static auto leak [[maybe_unused]] = sdk_provider;
        otel::metrics::Provider::SetMeterProvider(api_provider);
    }

    // ---- Logs ----
    // Same .release() / nostd::shared_ptr pattern as Tracing.
    {
        otlp::OtlpGrpcLogRecordExporterOptions opts;
        auto exporter  = otlp::OtlpGrpcLogRecordExporterFactory::Create(opts);
        auto processor = sdk_l::SimpleLogRecordProcessorFactory::Create(std::move(exporter));
        auto provider_unique =
            sdk_l::LoggerProviderFactory::Create(std::move(processor), resource);
        nostd::shared_ptr<otel::logs::LoggerProvider> provider(provider_unique.release());
        otel::logs::Provider::SetLoggerProvider(provider);
    }
}

}  // namespace

int main() {
    std::signal(SIGTERM, on_sigterm);
    std::signal(SIGINT,  on_sigterm);

    init_otel("demo-04-svc");

    auto tracer = otel::trace::Provider::GetTracerProvider()->GetTracer("demo-04");
    auto meter  = otel::metrics::Provider::GetMeterProvider()->GetMeter("demo-04");
    auto logger = otel::logs::Provider::GetLoggerProvider()->GetLogger("demo-04");

    auto request_counter = meter->CreateUInt64Counter("demo.requests", "Request count");
    auto latency_hist    = meter->CreateDoubleHistogram(
        "demo.request.duration", "Request latency", "ms");

    httplib::Server svr;
    svr.Get("/", [&](const httplib::Request& /*req*/, httplib::Response& res) {
        auto t0 = std::chrono::steady_clock::now();
        auto root = tracer->StartSpan("handle_request");
        otel::trace::Scope sc(root);

        // Simulate downstream work in a child span.
        {
            auto child = tracer->StartSpan("compute");
            otel::trace::Scope csc(child);
            // 50us-2ms of work; not contrived enough to be useless, not heavy enough to skew.
            volatile std::uint64_t acc = 0;
            for (int i = 0; i < 50000; ++i) acc ^= static_cast<std::uint64_t>(i) * 1469598103934665603ull;
            child->End();
        }

        res.set_content("ok\n", "text/plain");

        request_counter->Add(1, {{"route", "/"}});
        auto t1 = std::chrono::steady_clock::now();
        double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
        latency_hist->Record(ms, {{"route", "/"}}, otel::context::Context{});

        logger->EmitLogRecord(otel::logs::Severity::kInfo, "request handled");
        root->End();
    });

    svr.Get("/healthz", [](const httplib::Request&, httplib::Response& res) {
        res.set_content("ok", "text/plain");
    });

    std::print("demo-04-svc listening on :8080 (otel endpoint: {})\n",
               std::getenv("OTEL_EXPORTER_OTLP_ENDPOINT") ? std::getenv("OTEL_EXPORTER_OTLP_ENDPOINT") : "(unset)");
    std::thread([&] { svr.listen("0.0.0.0", 8080); }).detach();

    while (!g_stop.load(std::memory_order_relaxed))
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    svr.stop();
    return 0;
}
