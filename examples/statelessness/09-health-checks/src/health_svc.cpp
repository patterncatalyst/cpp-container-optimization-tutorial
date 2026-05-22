// health_svc.cpp — health checks as the public API of statelessness.
//
// This is the worked example for Doc 09. It demonstrates, end to end:
//
//   1. STAGED STARTUP. The gRPC server binds its port immediately but
//      reports NOT_SERVING while it does ~3s of simulated expensive
//      initialization, then flips to SERVING. A startup probe hitting
//      NOT_SERVING gives the service time to come up instead of killing
//      it (the cold-start trap from Doc 06).
//
//   2. LIVENESS vs READINESS as DISTINCT questions, on DIFFERENT PORTS
//      (the hybrid pattern from Doc 09's "separate-port vs same-port"):
//        - Liveness  : a tiny HTTP server on :8080 answering GET /healthz
//          with 200 "ok". Cheap, binary, and crucially it SURVIVES gRPC
//          overload — if the gRPC server is saturated, liveness still
//          answers, so the orchestrator does not restart a merely-busy
//          replica.
//        - Readiness : the gRPC standard health service on :50051,
//          reporting per-service status for "demo.health.EchoService".
//          This is what controls traffic routing.
//
//   3. DRIVING READINESS at runtime. SIGUSR1 toggles the EchoService
//      readiness between SERVING and NOT_SERVING WITHOUT touching the
//      server-wide status — so you can watch readiness go NOT_SERVING
//      (traffic would stop) while liveness stays green (no restart).
//      `podman kill -s SIGUSR1 <ctr>` drives it; see demo.sh act 2.
//
//   4. GRACEFUL SHUTDOWN. SIGTERM runs the staged-shutdown sequence from
//      Doc 09: flip readiness NOT_SERVING (stop new traffic) -> request
//      cooperative stop of the background worker (Doc 05 stop_token) ->
//      server->Shutdown(deadline) to drain in-flight RPCs -> reverse-order
//      teardown (Doc 04). `podman stop` sends SIGTERM; act 3 shows it.
//
// SIGNAL SAFETY. Doc 09 shows SetServingStatus()/Shutdown() called from
// inside the signal handler with statics; that is illustrative but not
// strictly async-signal-safe (signal-safety(7)). Here the handlers do the
// ONLY thing that is unambiguously safe — set a volatile sig_atomic_t flag
// — and a dedicated control thread does the real work. This is the
// signal-safe refinement of the doc's pattern, and it ties to §14's
// signal-safety note.

#include <grpcpp/grpcpp.h>
#include <grpcpp/health_check_service_interface.h>
#include <grpcpp/ext/health_check_service_server_builder_option.h>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <memory>
#include <mutex>
#include <stop_token>
#include <string>
#include <thread>

#include "echo.grpc.pb.h"

namespace demo {
namespace {

constexpr char kServiceName[] = "demo.health.EchoService";

void log_line(const std::string& msg) {
    static std::mutex m;
    std::lock_guard<std::mutex> lk(m);
    std::cout << "[health-svc] " << msg << std::endl;
}

// Signal handlers set only these. Everything else happens on the control
// thread, which polls them. volatile sig_atomic_t is the one type the
// standard guarantees safe to touch from a handler.
volatile std::sig_atomic_t g_sigterm = 0;
volatile std::sig_atomic_t g_sigusr1 = 0;

void on_signal(int sig) {
    if (sig == SIGTERM || sig == SIGINT) g_sigterm = 1;
    if (sig == SIGUSR1) g_sigusr1 = 1;
}

// ── The trivial application service ───────────────────────────────────
class EchoServiceImpl final : public demo::health::EchoService::Service {
public:
    grpc::Status Echo(grpc::ServerContext*,
                      const demo::health::EchoRequest* req,
                      demo::health::EchoReply* reply) override {
        reply->set_message(req->message());
        return grpc::Status::OK;
    }
};

// ── Minimal HTTP/1.1 liveness endpoint ────────────────────────────────
// Hand-rolled on a raw socket so liveness pulls in zero extra dependencies
// and stays dirt cheap. It answers any request with 200 "ok": the question
// liveness asks is only "is this process responsive at all?", and a process
// wedged badly enough to matter cannot accept() and reply here anyway —
// which is exactly the signal we want. Runs on its own jthread; the
// stop_token closes the listener at shutdown.
void run_liveness_http(std::stop_token st, int port) {
    int fd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { log_line("liveness: socket() failed"); return; }
    int one = 1;
    ::setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(static_cast<uint16_t>(port));
    if (::bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0) {
        log_line("liveness: bind() failed on :" + std::to_string(port));
        ::close(fd);
        return;
    }
    ::listen(fd, 16);
    // Non-blocking accept loop so we can observe the stop_token promptly.
    log_line("liveness HTTP on :" + std::to_string(port) + " /healthz");

    std::stop_callback cb(st, [fd] { ::shutdown(fd, SHUT_RDWR); ::close(fd); });

    static constexpr char kResponse[] =
        "HTTP/1.1 200 OK\r\n"
        "Content-Type: text/plain\r\n"
        "Content-Length: 3\r\n"
        "Connection: close\r\n"
        "\r\n"
        "ok\n";

    while (!st.stop_requested()) {
        int conn = ::accept(fd, nullptr, nullptr);
        if (conn < 0) {
            if (st.stop_requested()) break;
            continue;
        }
        char buf[1024];
        ::recv(conn, buf, sizeof(buf), 0);  // drain request; content ignored
        ::send(conn, kResponse, sizeof(kResponse) - 1, 0);
        ::close(conn);
    }
    log_line("liveness HTTP stopped");
}

// ── A background worker (stands in for Doc 07's outbox poller) ─────────
// Cooperatively cancellable via std::jthread's stop_token. The graceful-
// shutdown sequence calls request_stop() so this exits its current
// iteration cleanly before the process tears down.
void run_worker(std::stop_token st) {
    log_line("background worker started");
    int tick = 0;
    while (!st.stop_requested()) {
        std::this_thread::sleep_for(std::chrono::seconds(1));
        if (st.stop_requested()) break;
        if (++tick % 5 == 0) log_line("worker tick " + std::to_string(tick));
    }
    log_line("background worker drained and stopped");
}

}  // namespace
}  // namespace demo

int main() {
    using namespace demo;
    using grpc::HealthCheckServiceInterface;

    std::signal(SIGTERM, on_signal);
    std::signal(SIGINT, on_signal);
    std::signal(SIGUSR1, on_signal);

    const char* grpc_addr_env = std::getenv("GRPC_ADDR");
    const std::string grpc_addr = grpc_addr_env ? grpc_addr_env : "0.0.0.0:50051";
    const char* health_port_env = std::getenv("HEALTH_HTTP_PORT");
    const int health_port = health_port_env ? std::atoi(health_port_env) : 8080;

    // 1. Stand up the gRPC server. EnableDefaultHealthCheckService must be
    //    called BEFORE the ServerBuilder so the default grpc.health.v1
    //    service is registered automatically.
    grpc::EnableDefaultHealthCheckService(true);

    EchoServiceImpl echo;
    grpc::ServerBuilder builder;
    builder.AddListeningPort(grpc_addr, grpc::InsecureServerCredentials());
    builder.RegisterService(&echo);
    std::unique_ptr<grpc::Server> server = builder.BuildAndStart();
    if (!server) { log_line("failed to start gRPC server"); return 1; }
    log_line("gRPC server listening on " + grpc_addr);

    HealthCheckServiceInterface* health = server->GetHealthCheckService();

    // 2. Staged startup: report NOT_SERVING while we initialize. NOTE: the
    //    public HealthCheckServiceInterface uses a BOOL overload
    //    (serving = true/false) — not the grpc::health::v1 enum that Doc 09
    //    sketches. The bool form is the documented interface and needs no
    //    generated health.pb.h on the server side; we verified this against
    //    grpc 1.54. true => SERVING, false => NOT_SERVING.
    health->SetServingStatus("", false);             // server-wide
    health->SetServingStatus(kServiceName, false);   // the app service
    log_line("status NOT_SERVING; doing expensive init ...");

    // 3. Simulate the expensive init a real service does here (Doc 04
    //    process-scoped state, Doc 07 pools, channel caches, config parse).
    std::this_thread::sleep_for(std::chrono::seconds(3));

    // 4. Flip to SERVING. Startup probe now succeeds; readiness goes green.
    health->SetServingStatus("", true);
    health->SetServingStatus(kServiceName, true);
    log_line("init complete; status SERVING (live + ready)");

    // 5. Start the liveness HTTP endpoint and the background worker. Both
    //    are jthreads: their stop_token is requested during shutdown.
    std::jthread liveness(run_liveness_http, health_port);
    std::jthread worker(run_worker);

    // 6. Control thread: react to signals OFF the handler. server->Wait()
    //    blocks the main thread, so Shutdown() must come from here.
    std::atomic<bool> ready{true};
    std::jthread control([&] {
        while (true) {
            if (g_sigusr1) {
                g_sigusr1 = 0;
                ready = !ready;
                health->SetServingStatus(kServiceName, ready.load());
                log_line(std::string("SIGUSR1: readiness -> ") +
                         (ready ? "SERVING" : "NOT_SERVING") +
                         " (liveness unchanged)");
            }
            if (g_sigterm) {
                log_line("SIGTERM: beginning graceful shutdown");
                // a) stop new traffic: readiness NOT_SERVING. Keep the
                //    server-wide ("") status SERVING so liveness does not
                //    fail mid-drain and trigger a restart.
                health->SetServingStatus(kServiceName, false);
                log_line("  readiness NOT_SERVING (draining; liveness still SERVING)");
                // b) cancel background workers cooperatively (Doc 05).
                worker.request_stop();
                // c) drain in-flight RPCs up to a deadline, then stop.
                const auto deadline = std::chrono::system_clock::now() +
                                      std::chrono::seconds(25);
                log_line("  server->Shutdown(deadline=25s): draining in-flight RPCs");
                server->Shutdown(deadline);
                liveness.request_stop();
                break;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
    });

    // 7. Block until Shutdown() (called from the control thread) completes.
    server->Wait();
    log_line("server->Wait() returned; tearing down");

    // 8. Reverse-order teardown happens as the jthreads join here (control,
    //    worker, liveness destructors run in reverse declaration order),
    //    each having already been asked to stop. A real service would also
    //    flush its tracer provider and close pools here, in reverse of
    //    construction (Doc 04). Process exits 0 — a clean stop the
    //    orchestrator can proceed from.
    return 0;
}
