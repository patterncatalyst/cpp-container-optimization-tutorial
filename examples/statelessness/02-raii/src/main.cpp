// main.cpp — statelessness/02-raii server.
//
// A gRPC callback-API server whose Process handler builds a
// RequestContext (RAII) on entry and then takes one of three exit
// paths chosen by the request's `mode`:
//
//   "ok"     normal return
//   "reject" early return (validation failure)
//   "throw"  throws mid-handler
//
// In all three cases the RequestContext destructor runs — releasing the
// lease and reporting the duration — which is the whole point. The
// LeasePool's outstanding-lease counter returns to zero after each
// request, the machine-checkable proof that cleanup happened on every
// path.
//
// A tiny HTTP healthz on :8080 lets the test harness wait for readiness
// with wait_for_http (matching the other demos' convention).

#include <atomic>
#include <csignal>
#include <cstring>
#include <iostream>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <grpcpp/grpcpp.h>
#include <grpcpp/health_check_service_interface.h>

#include "processor.grpc.pb.h"
#include "request_context.hpp"

namespace statelessraii {

// ── Logging hook declared in request_context.hpp ─────────────────────
//
// Single mutex so interleaved handler logs stay readable. Format is
// greppable: "[rc] <event> id=<id> <detail>". The demo and test grep
// for "acquire" / "release" pairs.
namespace {
std::mutex g_log_mu;
}

void rc_log(const std::string& request_id, const char* event,
            const std::string& detail) {
    std::lock_guard<std::mutex> lk(g_log_mu);
    std::cout << "[rc] " << event << " id=" << request_id;
    if (!detail.empty()) {
        std::cout << ' ' << detail;
    }
    std::cout << std::endl;
}

namespace {

// Process-scoped lease pool. Constructed once, lives for the process,
// shared across all request handlers. This is process-scoped state in
// the State Architecture Table sense (see compendium Doc 04).
LeasePool g_pool;

// Monotonic request-id source. Process-scoped, atomic.
std::atomic<std::uint64_t> g_req_seq{1};

std::string mint_request_id() {
    return "req-" + std::to_string(g_req_seq.fetch_add(1, std::memory_order_relaxed));
}

// ── The service implementation (gRPC callback API) ───────────────────

class RequestProcessorImpl final
    : public RequestProcessor::CallbackService {
public:
    grpc::ServerUnaryReactor* Process(
        grpc::CallbackServerContext* ctx,
        const ProcessRequest* req,
        ProcessResponse* resp) override {

        auto* reactor = ctx->DefaultReactor();

        // The handler boundary. Everything request-scoped is built
        // below this line and destroyed when `handle` returns — on
        // every path. The try/catch is the one place the handler
        // converts a thrown exception into a grpc::Status; RAII has
        // already guaranteed cleanup by the time we get here.
        grpc::Status status = handle(req, resp);
        reactor->Finish(status);
        return reactor;
    }

private:
    grpc::Status handle(const ProcessRequest* req, ProcessResponse* resp) {
        // === RequestContext constructed here: acquisition ===
        RequestContext rc(g_pool, mint_request_id());
        resp->set_request_id(rc.id());

        try {
            const std::string& mode = req->mode();

            // Path 2: early return on validation failure. The
            // RequestContext destructor still runs as `rc` leaves
            // scope — no manual cleanup, no leaked lease.
            if (mode == "reject") {
                rc_log(rc.id(), "work", "validation rejected, early return");
                resp->set_result("rejected");
                resp->set_handler_duration_micros(rc.elapsed_micros());
                return grpc::Status(grpc::StatusCode::INVALID_ARGUMENT,
                                    "payload rejected by validation");
            }

            // Path 3: throw mid-handler. The RequestContext destructor
            // runs during stack unwinding before the catch below sees
            // the exception. This is why the destructor must be
            // noexcept.
            if (mode == "throw") {
                rc_log(rc.id(), "work", "about to throw");
                throw std::runtime_error("simulated mid-handler failure");
            }

            // Path 1: normal processing. Use the per-request arena for
            // scratch (a pmr::string built from the arena, freed in
            // bulk when rc is destroyed).
            std::pmr::string scratch(&rc.arena());
            scratch.assign("processed:");
            scratch.append(req->payload());
            rc_log(rc.id(), "work", "ok, arena_used");

            resp->set_result(std::string(scratch));
            resp->set_handler_duration_micros(rc.elapsed_micros());
            return grpc::Status::OK;
        } catch (const std::exception& e) {
            // The exception already unwound past `rc`'s scope exit on
            // the throw path — wait, no: `rc` is still in scope here,
            // because the try block is *inside* rc's scope. rc is
            // destroyed when `handle` returns, after this catch fills
            // in the status. Either way the destructor runs exactly
            // once. We report duration from the still-live rc.
            rc_log(rc.id(), "catch", std::string("mapped exception: ") + e.what());
            resp->set_result("error");
            resp->set_handler_duration_micros(rc.elapsed_micros());
            return grpc::Status(grpc::StatusCode::INTERNAL, e.what());
        }
        // === RequestContext destroyed here on every path: release ===
    }
};

// ── Minimal HTTP healthz on :8080 ────────────────────────────────────
//
// Responds 200 to any request. Just enough for wait_for_http in the
// test harness. Runs on its own thread; closed on shutdown via the
// listen fd.

std::atomic<int> g_health_fd{-1};
std::atomic<bool> g_shutting_down{false};

void run_healthz(std::uint16_t port) {
    int fd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return;
    int one = 1;
    ::setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(port);
    if (::bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
        ::close(fd);
        return;
    }
    ::listen(fd, 16);
    g_health_fd.store(fd, std::memory_order_relaxed);

    const char* resp =
        "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n"
        "Content-Type: text/plain\r\n\r\nok\n";

    while (!g_shutting_down.load(std::memory_order_relaxed)) {
        int c = ::accept(fd, nullptr, nullptr);
        if (c < 0) break;
        char buf[512];
        (void)::recv(c, buf, sizeof(buf), 0);
        (void)::send(c, resp, std::strlen(resp), 0);
        ::close(c);
    }
    ::close(fd);
}

std::unique_ptr<grpc::Server> g_server;

void on_signal(int) {
    g_shutting_down.store(true, std::memory_order_relaxed);
    int hfd = g_health_fd.load(std::memory_order_relaxed);
    if (hfd >= 0) ::shutdown(hfd, SHUT_RDWR);
    if (g_server) {
        // Graceful: stop accepting, let in-flight RPCs drain.
        g_server->Shutdown();
    }
}

}  // namespace
}  // namespace statelessraii

int main(int /*argc*/, char** /*argv*/) {
    using namespace statelessraii;

    std::signal(SIGINT, on_signal);
    std::signal(SIGTERM, on_signal);

    std::thread health_thread(run_healthz, 8080);

    const std::string addr = "0.0.0.0:50051";
    RequestProcessorImpl service;

    grpc::EnableDefaultHealthCheckService(true);
    grpc::ServerBuilder builder;
    builder.AddListeningPort(addr, grpc::InsecureServerCredentials());
    builder.RegisterService(&service);

    g_server = builder.BuildAndStart();
    if (!g_server) {
        std::cerr << "failed to start gRPC server on " << addr << std::endl;
        g_shutting_down.store(true, std::memory_order_relaxed);
        if (health_thread.joinable()) health_thread.join();
        return 1;
    }
    std::cout << "statelessness/02-raii server listening on " << addr
              << " (healthz :8080)" << std::endl;

    g_server->Wait();

    // Graceful shutdown path: signal handler set g_shutting_down and
    // called Shutdown(); join the health thread before exit so its
    // socket is closed cleanly (reverse-order teardown, compendium
    // Doc 09).
    g_shutting_down.store(true, std::memory_order_relaxed);
    int hfd = g_health_fd.load(std::memory_order_relaxed);
    if (hfd >= 0) ::shutdown(hfd, SHUT_RDWR);
    if (health_thread.joinable()) health_thread.join();

    std::cout << "shutdown complete; outstanding leases="
              << g_pool.outstanding() << std::endl;
    return 0;
}
