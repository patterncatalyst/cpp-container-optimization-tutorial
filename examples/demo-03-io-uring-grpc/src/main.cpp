// Demo-03 — async gRPC + io_uring echo (direct + Asio backend).
//
// Three servers in one process:
//   1. gRPC Echo service on :50051  (callback API: ServerUnaryReactor)
//   2. io_uring TCP echo on :9000    (direct liburing)
//   3. Asio TCP echo on :9001        (Asio io_uring backend)
//
// All three are instrumented with OpenTelemetry (traces + metrics +
// logs), exported via OTLP/gRPC to the LGTM stack on the shared
// `tutorial-obs` network — same observability shape as demo-04.
//
// The §9 lesson made concrete: io_uring's submission-queue /
// completion-queue model amortizes the system-call cost of network
// I/O across many operations. The direct-liburing server and the
// Asio-io_uring server both demonstrate this; the comparison shows
// how much the abstraction costs.
//
// Layout in this file:
//   1. OTel init        — same shape as demo-04/src/main.cpp
//   2. gRPC Echo service — callback API (ServerUnaryReactor)
//   3. io_uring echo     — direct liburing accept/read/write loop
//   4. Asio io_uring echo — Asio io_context with io_uring backend
//   5. main()           — wire it all up, run, handle SIGTERM

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <memory>
#include <mutex>
#include <string>
#include <string_view>
#include <thread>

#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <signal.h>
#include <sys/socket.h>
#include <unistd.h>

#include <liburing.h>

// Asio (standalone, not boost::asio). ASIO_HAS_IO_URING is set
// via CMake target_compile_definitions to switch the backend.
#include <asio.hpp>

#include <grpcpp/grpcpp.h>
#include <grpcpp/server.h>
#include <grpcpp/server_builder.h>
#include <grpcpp/security/server_credentials.h>

#include "echo.grpc.pb.h"

// OpenTelemetry — full include set per demo-04's hard-won G-29
// fix (incomplete-type unique_ptr destruction needs the full
// processor.h, not just the factory header).
#include "opentelemetry/exporters/otlp/otlp_grpc_exporter_factory.h"
#include "opentelemetry/exporters/otlp/otlp_grpc_log_record_exporter_factory.h"
#include "opentelemetry/exporters/otlp/otlp_grpc_metric_exporter_factory.h"
#include "opentelemetry/logs/provider.h"
#include "opentelemetry/metrics/provider.h"
#include "opentelemetry/sdk/logs/logger_provider_factory.h"
#include "opentelemetry/sdk/logs/processor.h"
#include "opentelemetry/sdk/logs/simple_log_record_processor_factory.h"
#include "opentelemetry/sdk/metrics/export/periodic_exporting_metric_reader_factory.h"
#include "opentelemetry/sdk/metrics/meter_provider.h"
#include "opentelemetry/sdk/resource/resource.h"
#include "opentelemetry/sdk/trace/processor.h"
#include "opentelemetry/sdk/trace/simple_processor_factory.h"
#include "opentelemetry/sdk/trace/tracer_provider_factory.h"
#include "opentelemetry/trace/provider.h"

namespace api  = opentelemetry::v1;
namespace sdk_t = opentelemetry::v1::sdk::trace;
namespace sdk_m = opentelemetry::v1::sdk::metrics;
namespace sdk_l = opentelemetry::v1::sdk::logs;
namespace otlp  = opentelemetry::v1::exporter::otlp;
namespace nostd = opentelemetry::v1::nostd;

using demo03::EchoRequest;
using demo03::EchoResponse;
using demo03::Echo;

// ────────────────────────────────────────────────────────────────
//  1. OTel init — same shape as demo-04/src/main.cpp
// ────────────────────────────────────────────────────────────────

namespace {

// Why nostd::unique_ptr not std::shared_ptr:
// `meter->CreateUInt64Counter()` and `CreateDoubleHistogram()`
// return `nostd::unique_ptr<...>`, not `std::unique_ptr` or
// `std::shared_ptr`. OTel-cpp ships its own pointer family
// (`nostd::`) in the api/v1 namespace to keep ABI stable across
// stdlib versions and -D_GLIBCXX_USE_CXX11_ABI variants. A
// `std::shared_ptr` can't accept the `nostd::unique_ptr` directly
// (no implicit conversion path). We're storing these as globals
// written once at init and read concurrently from server threads;
// that's fine with `nostd::unique_ptr` since the underlying
// Counter/Histogram are documented thread-safe for concurrent
// Add()/Record() calls.
nostd::unique_ptr<api::metrics::Counter<std::uint64_t>>     g_grpc_requests;
nostd::unique_ptr<api::metrics::Counter<std::uint64_t>>     g_tcp_iouring_conns;
nostd::unique_ptr<api::metrics::Counter<std::uint64_t>>     g_tcp_asio_conns;
nostd::unique_ptr<api::metrics::Histogram<double>>          g_grpc_latency_ms;

void init_otel_traces(const std::string& otlp_endpoint) {
    otlp::OtlpGrpcExporterOptions opts;
    opts.endpoint = otlp_endpoint;
    auto exporter = otlp::OtlpGrpcExporterFactory::Create(opts);
    auto processor = sdk_t::SimpleSpanProcessorFactory::Create(std::move(exporter));
    auto resource  = opentelemetry::v1::sdk::resource::Resource::Create({
        {"service.name", "demo-03-svc"},
        {"deployment.environment", "tutorial"}
    });
    auto provider = sdk_t::TracerProviderFactory::Create(std::move(processor), resource);
    api::trace::Provider::SetTracerProvider(
        nostd::shared_ptr<api::trace::TracerProvider>(std::move(provider)));
}

void init_otel_metrics(const std::string& otlp_endpoint) {
    otlp::OtlpGrpcMetricExporterOptions opts;
    opts.endpoint = otlp_endpoint;
    auto exporter = otlp::OtlpGrpcMetricExporterFactory::Create(opts);
    sdk_m::PeriodicExportingMetricReaderOptions reader_opts{};
    reader_opts.export_interval_millis = std::chrono::milliseconds(5000);
    reader_opts.export_timeout_millis  = std::chrono::milliseconds(2000);
    auto reader = sdk_m::PeriodicExportingMetricReaderFactory::Create(
        std::move(exporter), reader_opts);
    auto resource = opentelemetry::v1::sdk::resource::Resource::Create({
        {"service.name", "demo-03-svc"}
    });
    auto provider = std::shared_ptr<api::metrics::MeterProvider>(
        new sdk_m::MeterProvider(
            std::make_unique<sdk_m::ViewRegistry>(),
            resource));
    static_cast<sdk_m::MeterProvider*>(provider.get())
        ->AddMetricReader(std::move(reader));
    api::metrics::Provider::SetMeterProvider(provider);

    auto meter = provider->GetMeter("demo-03-svc");
    g_grpc_requests = meter->CreateUInt64Counter(
        "demo3.grpc.requests", "Total gRPC Echo requests handled");
    g_tcp_iouring_conns = meter->CreateUInt64Counter(
        "demo3.tcp.iouring.connections", "Total connections handled by io_uring echo");
    g_tcp_asio_conns = meter->CreateUInt64Counter(
        "demo3.tcp.asio.connections", "Total connections handled by Asio echo");
    g_grpc_latency_ms = meter->CreateDoubleHistogram(
        "demo3.grpc.latency", "gRPC Echo end-to-end latency in milliseconds", "ms");
}

void init_otel_logs(const std::string& otlp_endpoint) {
    otlp::OtlpGrpcLogRecordExporterOptions opts;
    opts.endpoint = otlp_endpoint;
    auto exporter = otlp::OtlpGrpcLogRecordExporterFactory::Create(opts);
    auto processor = sdk_l::SimpleLogRecordProcessorFactory::Create(std::move(exporter));
    auto resource = opentelemetry::v1::sdk::resource::Resource::Create({
        {"service.name", "demo-03-svc"}
    });
    auto provider = sdk_l::LoggerProviderFactory::Create(std::move(processor), resource);
    api::logs::Provider::SetLoggerProvider(
        nostd::shared_ptr<api::logs::LoggerProvider>(std::move(provider)));
}

void init_otel(const std::string& otlp_endpoint) {
    init_otel_traces(otlp_endpoint);
    init_otel_metrics(otlp_endpoint);
    init_otel_logs(otlp_endpoint);
}

std::int64_t unix_nanos_now() {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
               std::chrono::system_clock::now().time_since_epoch())
        .count();
}

}  // namespace

// ────────────────────────────────────────────────────────────────
//  2. gRPC Echo service — callback API (ServerUnaryReactor)
// ────────────────────────────────────────────────────────────────
//
// The callback API is gRPC's modern async pattern: replaces the older
// CompletionQueue-driven async with a reactor model. The server
// implements grpc::ServerUnaryReactor for each RPC type; gRPC's
// internal thread pool drives the reactor through the request
// lifecycle. We don't manage threads or queues ourselves.

class EchoServiceImpl final : public Echo::CallbackService {
public:
    grpc::ServerUnaryReactor* Echo(grpc::CallbackServerContext* ctx,
                                   const EchoRequest*           request,
                                   EchoResponse*                response) override {
        const auto start_ns = unix_nanos_now();
        auto tracer = api::trace::Provider::GetTracerProvider()
                          ->GetTracer("demo-03-svc");
        auto span = tracer->StartSpan("grpc.Echo");
        auto scope = tracer->WithActiveSpan(span);

        // Echo: copy payload, stamp receive time, no other work.
        response->set_payload(request->payload());
        response->set_server_receive_unix_nanos(start_ns);

        if (g_grpc_requests)    g_grpc_requests->Add(1);
        if (g_grpc_latency_ms) {
            const auto end_ns = unix_nanos_now();
            const double ms = (end_ns - start_ns) / 1e6;
            g_grpc_latency_ms->Record(ms, {}, {});
        }

        auto* reactor = ctx->DefaultReactor();
        reactor->Finish(grpc::Status::OK);
        span->End();
        return reactor;
    }
};

void run_grpc_server(const std::string&         listen_address,
                     std::atomic<bool>&         shutdown,
                     std::unique_ptr<grpc::Server>& out_server) {
    EchoServiceImpl service;
    grpc::ServerBuilder builder;
    builder.AddListeningPort(listen_address, grpc::InsecureServerCredentials());
    builder.RegisterService(&service);
    out_server = builder.BuildAndStart();
    std::cerr << "[grpc]    listening on " << listen_address << "\n";
    out_server->Wait();
    (void)shutdown;
}

// ────────────────────────────────────────────────────────────────
//  3. io_uring direct TCP echo on :9000
// ────────────────────────────────────────────────────────────────
//
// Single-threaded reactor pattern using direct liburing calls:
//   - One ring with QUEUE_DEPTH slots
//   - On startup: submit one MULTISHOT accept SQE
//   - On each accept completion: submit a read SQE for the new fd
//   - On each read completion: submit a write SQE with the same bytes
//   - On each write completion: submit another read SQE (or close on
//     short write)
//
// The §9 takeaway: this loop never calls epoll_wait, never calls
// recvfrom in a busy-wait, never spawns a thread per connection.
// Each operation is a single syscall (io_uring_enter) batching many
// I/O ops at once. For a tutorial we keep it single-threaded so the
// state machine is obvious.

namespace iouring_echo {

constexpr int   QUEUE_DEPTH    = 256;
constexpr int   READ_BUF_SIZE  = 4096;
constexpr int   BACKLOG        = 512;

// op_type encoded in user_data low bits; fd in high bits.
enum OpType : std::uintptr_t {
    OP_ACCEPT = 0,
    OP_READ   = 1,
    OP_WRITE  = 2,
};

inline std::uintptr_t make_ud(OpType op, int fd) {
    return (static_cast<std::uintptr_t>(fd) << 8) | static_cast<std::uintptr_t>(op);
}
inline OpType ud_op(std::uintptr_t ud)   { return static_cast<OpType>(ud & 0xff); }
inline int    ud_fd(std::uintptr_t ud)   { return static_cast<int>(ud >> 8); }

// Per-connection read buffer (kept alive via a simple map fd→buf).
// A real production server would use registered buffers and a pool.
// We keep it simple for clarity.
struct ConnBuf {
    char data[READ_BUF_SIZE];
    int  bytes_in_flight{0};
};

void submit_accept(io_uring& ring, int listen_fd) {
    auto* sqe = io_uring_get_sqe(&ring);
    io_uring_prep_accept(sqe, listen_fd, nullptr, nullptr, 0);
    io_uring_sqe_set_data(sqe, reinterpret_cast<void*>(make_ud(OP_ACCEPT, listen_fd)));
}

void submit_read(io_uring& ring, int fd, ConnBuf* buf) {
    auto* sqe = io_uring_get_sqe(&ring);
    io_uring_prep_read(sqe, fd, buf->data, READ_BUF_SIZE, 0);
    io_uring_sqe_set_data(sqe, reinterpret_cast<void*>(make_ud(OP_READ, fd)));
}

void submit_write(io_uring& ring, int fd, ConnBuf* buf, int n) {
    auto* sqe = io_uring_get_sqe(&ring);
    io_uring_prep_write(sqe, fd, buf->data, static_cast<unsigned>(n), 0);
    io_uring_sqe_set_data(sqe, reinterpret_cast<void*>(make_ud(OP_WRITE, fd)));
}

void run(std::uint16_t port, std::atomic<bool>& shutdown) {
    int listen_fd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (listen_fd < 0) { perror("[iouring] socket"); return; }
    int one = 1;
    setsockopt(listen_fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    setsockopt(listen_fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof(one));

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(port);
    if (::bind(listen_fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0) {
        perror("[iouring] bind"); ::close(listen_fd); return;
    }
    if (::listen(listen_fd, BACKLOG) < 0) {
        perror("[iouring] listen"); ::close(listen_fd); return;
    }

    io_uring ring;
    if (io_uring_queue_init(QUEUE_DEPTH, &ring, 0) < 0) {
        perror("[iouring] io_uring_queue_init"); ::close(listen_fd); return;
    }

    std::cerr << "[iouring] listening on :" << port << " (direct liburing)\n";

    // Buffer pool — one per active fd. A real server would use
    // a fixed-size pool with registered buffers (IORING_REGISTER_BUFFERS)
    // for zero-copy. This tutorial demo allocates per-connection
    // to keep the example readable.
    std::unordered_map<int, std::unique_ptr<ConnBuf>> conns;

    submit_accept(ring, listen_fd);
    io_uring_submit(&ring);

    while (!shutdown.load(std::memory_order_acquire)) {
        io_uring_cqe* cqe = nullptr;
        // wait_cqe blocks until a completion arrives; for graceful
        // shutdown, a real server would use io_uring_wait_cqe_timeout
        // and check the flag periodically.
        int ret = io_uring_wait_cqe(&ring, &cqe);
        if (ret < 0) {
            if (ret == -EINTR) continue;
            std::cerr << "[iouring] wait_cqe: " << ret << "\n";
            break;
        }

        auto ud = reinterpret_cast<std::uintptr_t>(io_uring_cqe_get_data(cqe));
        auto op = ud_op(ud);
        int  fd = ud_fd(ud);
        int  res = cqe->res;
        io_uring_cqe_seen(&ring, cqe);

        switch (op) {
        case OP_ACCEPT: {
            if (res >= 0) {
                int conn_fd = res;
                auto buf = std::make_unique<ConnBuf>();
                submit_read(ring, conn_fd, buf.get());
                conns[conn_fd] = std::move(buf);
                if (g_tcp_iouring_conns) g_tcp_iouring_conns->Add(1);
            }
            // Re-submit accept SQE for the next incoming.
            submit_accept(ring, listen_fd);
            io_uring_submit(&ring);
            break;
        }
        case OP_READ: {
            auto it = conns.find(fd);
            if (it == conns.end()) break;
            if (res <= 0) { ::close(fd); conns.erase(it); break; }
            it->second->bytes_in_flight = res;
            submit_write(ring, fd, it->second.get(), res);
            io_uring_submit(&ring);
            break;
        }
        case OP_WRITE: {
            auto it = conns.find(fd);
            if (it == conns.end()) break;
            if (res <= 0) { ::close(fd); conns.erase(it); break; }
            // Echo done; loop back to read for next message.
            submit_read(ring, fd, it->second.get());
            io_uring_submit(&ring);
            break;
        }
        }
    }

    io_uring_queue_exit(&ring);
    ::close(listen_fd);
    std::cerr << "[iouring] shutdown\n";
}

}  // namespace iouring_echo

// ────────────────────────────────────────────────────────────────
//  4. Asio io_uring TCP echo on :9001
// ────────────────────────────────────────────────────────────────
//
// Same protocol, same semantics, but expressed via Asio's high-level
// async API. The io_context is backed by io_uring (ASIO_HAS_IO_URING
// set at compile time); Asio handles the SQE/CQE bookkeeping.
//
// Compare line-by-line with the direct-liburing version above. The
// Asio code is much shorter — the cost is one extra layer of
// abstraction the kernel/userland boundary doesn't see.

namespace asio_echo {

class Session : public std::enable_shared_from_this<Session> {
public:
    explicit Session(asio::ip::tcp::socket sock) : socket_(std::move(sock)) {}
    void start() { do_read(); }

private:
    void do_read() {
        auto self = shared_from_this();
        socket_.async_read_some(
            asio::buffer(buf_),
            [this, self](std::error_code ec, std::size_t n) {
                if (!ec && n > 0) do_write(n);
            });
    }

    void do_write(std::size_t n) {
        auto self = shared_from_this();
        asio::async_write(
            socket_,
            asio::buffer(buf_.data(), n),
            [this, self](std::error_code ec, std::size_t /*bytes_written*/) {
                if (!ec) do_read();
            });
    }

    asio::ip::tcp::socket  socket_;
    std::array<char, 4096> buf_{};
};

void run(std::uint16_t port, std::atomic<bool>& shutdown) {
    asio::io_context ctx;
    asio::ip::tcp::acceptor acceptor(
        ctx, asio::ip::tcp::endpoint(asio::ip::tcp::v4(), port));
    acceptor.set_option(asio::ip::tcp::no_delay(true));
    acceptor.set_option(asio::socket_base::reuse_address(true));

    std::cerr << "[asio]    listening on :" << port << " (Asio io_uring backend)\n";

    std::function<void()> accept;
    accept = [&]() {
        acceptor.async_accept(
            [&](std::error_code ec, asio::ip::tcp::socket sock) {
                if (!ec) {
                    if (g_tcp_asio_conns) g_tcp_asio_conns->Add(1);
                    std::make_shared<Session>(std::move(sock))->start();
                }
                if (!shutdown.load(std::memory_order_acquire)) accept();
            });
    };
    accept();

    // Run until shutdown; periodically check the flag by posting a
    // no-op work item every 250ms via a steady_timer.
    asio::steady_timer ticker(ctx);
    std::function<void()> tick;
    tick = [&]() {
        ticker.expires_after(std::chrono::milliseconds(250));
        ticker.async_wait([&](std::error_code) {
            if (shutdown.load(std::memory_order_acquire)) {
                ctx.stop();
            } else {
                tick();
            }
        });
    };
    tick();

    ctx.run();
    std::cerr << "[asio]    shutdown\n";
}

}  // namespace asio_echo

// ────────────────────────────────────────────────────────────────
//  5. main — wire everything up + SIGTERM handling
// ────────────────────────────────────────────────────────────────

namespace {

std::atomic<bool>             g_shutdown{false};
std::unique_ptr<grpc::Server> g_grpc_server;

void on_signal(int) {
    g_shutdown.store(true, std::memory_order_release);
    if (g_grpc_server) g_grpc_server->Shutdown();
}

const char* getenv_default(const char* key, const char* fallback) {
    const char* v = std::getenv(key);
    return (v && *v) ? v : fallback;
}

void serve_healthz() {
    // Tiny synchronous TCP health endpoint on :8080. Returns
    // "ok\n" to any connection that gets through. The test
    // script uses this to know the binary is up.
    int fd = ::socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_port = htons(8080);
    a.sin_addr.s_addr = INADDR_ANY;
    if (::bind(fd, reinterpret_cast<sockaddr*>(&a), sizeof(a)) < 0) { perror("healthz bind"); return; }
    ::listen(fd, 16);
    std::cerr << "[health]  listening on :8080\n";
    while (!g_shutdown.load(std::memory_order_acquire)) {
        int c = ::accept(fd, nullptr, nullptr);
        if (c < 0) { if (errno == EINTR) continue; break; }
        const char ok[] = "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nok\n";
        ::write(c, ok, sizeof(ok) - 1);
        ::close(c);
    }
    ::close(fd);
}

}  // namespace

int main() {
    std::signal(SIGTERM, on_signal);
    std::signal(SIGINT,  on_signal);

    const std::string otlp_endpoint =
        getenv_default("OTEL_EXPORTER_OTLP_ENDPOINT", "http://lgtm:4317");
    std::cerr << "[init]    OTLP endpoint: " << otlp_endpoint << "\n";

    init_otel(otlp_endpoint);
    std::cerr << "[init]    OTel initialized\n";

    // Each server gets its own thread. gRPC's Wait() blocks; the
    // io_uring loop blocks in wait_cqe; Asio's run() blocks until
    // ctx.stop(). Threads are joined at shutdown via SIGTERM handler.
    std::thread t_grpc([&]() {
        run_grpc_server("0.0.0.0:50051", g_shutdown, g_grpc_server);
    });
    std::thread t_iouring([&]() {
        iouring_echo::run(9000, g_shutdown);
    });
    std::thread t_asio([&]() {
        asio_echo::run(9001, g_shutdown);
    });
    std::thread t_health(serve_healthz);

    t_grpc.join();
    g_shutdown.store(true, std::memory_order_release);
    t_iouring.join();
    t_asio.join();
    t_health.join();

    // Reset metric globals BEFORE main returns so Counter/Histogram
    // destruct while the OTel provider singletons are still valid.
    // Globals destruct in reverse construction order *after* main
    // returns, and the SDK Provider singletons are managed via
    // internal SDK statics with their own atexit-driven teardown;
    // ordering between the two destruction phases is not guaranteed.
    // Resetting here puts the Counter/Histogram destructors inside
    // main()'s scope where the provider is guaranteed to still
    // exist.
    g_grpc_requests.reset();
    g_tcp_iouring_conns.reset();
    g_tcp_asio_conns.reset();
    g_grpc_latency_ms.reset();

    std::cerr << "[main]    clean shutdown\n";
    return 0;
}
