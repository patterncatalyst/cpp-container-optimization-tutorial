// main.cpp — statelessness/04-process-scoped-state server.
//
// The composition root. main() constructs every piece of process-scoped
// state by name, in dependency order, and injects it into the service
// by reference. There are no Meyers singletons and no hidden
// construction order. Because dependencies are built before the things
// that use them, RAII tears everything down in the exact reverse order
// at process exit — which is also the correct shutdown order: the server
// stops first (no new RPCs), then the state it relied on.
//
// The handler uses only injected references (config_, metrics_, cache_);
// it never reaches for a global. A Lookup hits the bounded cache or, on
// a miss, "computes" the value (standing in for an external fetch — the
// third column of the State Architecture Table; the real external call
// is Doc 07's subject) and inserts it, possibly evicting the LRU entry.

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

#include "state.grpc.pb.h"
#include "composition.hpp"

namespace statelessstate {
namespace {
std::mutex g_log_mu;
}

void wire_log(const char* event, const std::string& detail) {
    std::lock_guard<std::mutex> lk(g_log_mu);
    std::cout << "[wire] " << event;
    if (!detail.empty()) std::cout << ' ' << detail;
    std::cout << std::endl;
}

namespace {

// Stand-in for an external fetch (DB/Redis/HTTP). In a real service this
// is where the request crosses into the "external" column of the State
// Architecture Table; here it's a pure function so the example needs no
// backing store. See Doc 07 for the real externalization.
std::string compute_value(const std::string& key) {
    return "value-for-" + key;
}

// The service receives its dependencies by reference — dependency
// injection, not global lookup. It owns none of them; main() does.
class StateServiceImpl final : public StateService::CallbackService {
public:
    StateServiceImpl(const ServiceConfig& config, MetricsRegistry& metrics,
                     BoundedCache& cache)
        : config_(config), metrics_(metrics), cache_(cache) {
        wire_log("+service", "");
    }
    ~StateServiceImpl() override { wire_log("-service", ""); }

    grpc::ServerUnaryReactor* Lookup(grpc::CallbackServerContext* ctx,
                                     const LookupRequest* req,
                                     LookupResponse* resp) override {
        auto* reactor = ctx->DefaultReactor();
        metrics_.record_lookup();

        const std::string& key = req->key();
        bool hit = false;
        std::string value;
        if (auto cached = cache_.get(key)) {
            hit = true;
            value = std::move(*cached);
            metrics_.record_hit();
        } else {
            metrics_.record_miss();
            value = compute_value(key);  // "external" fetch
            if (cache_.put(key, value)) {
                metrics_.record_eviction();
            }
        }

        resp->set_key(key);
        resp->set_value(value);
        resp->set_cache_hit(hit);
        resp->set_cache_size(static_cast<std::int64_t>(cache_.size()));
        resp->set_cache_capacity(static_cast<std::int64_t>(config_.cache_capacity()));
        reactor->Finish(grpc::Status::OK);
        return reactor;
    }

    grpc::ServerUnaryReactor* Stats(grpc::CallbackServerContext* ctx,
                                    const StatsRequest* /*req*/,
                                    StatsResponse* resp) override {
        auto* reactor = ctx->DefaultReactor();
        resp->set_lookups(metrics_.lookups());
        resp->set_hits(metrics_.hits());
        resp->set_misses(metrics_.misses());
        resp->set_evictions(metrics_.evictions());
        resp->set_cache_size(static_cast<std::int64_t>(cache_.size()));
        resp->set_cache_capacity(static_cast<std::int64_t>(config_.cache_capacity()));
        reactor->Finish(grpc::Status::OK);
        return reactor;
    }

private:
    const ServiceConfig& config_;
    MetricsRegistry& metrics_;
    BoundedCache& cache_;
};

// ── Minimal HTTP healthz on :8080 (same pattern as 02/03) ────────────
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
        "HTTP/1.1 200 OK\r\nContent-Length: 3\r\nContent-Type: text/plain\r\n\r\nok\n";
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
    if (g_server) g_server->Shutdown();
}

}  // namespace
}  // namespace statelessstate

int main() {
    using namespace statelessstate;
    std::signal(SIGINT, on_signal);
    std::signal(SIGTERM, on_signal);

    std::thread health_thread(run_healthz, 8080);

    // ── Composition root: construct process-scoped state by name, in
    //    dependency order. Each ctor logs; teardown is the reverse. ──
    wire_log("compose", "constructing process-scoped state (composition root)");
    ServiceConfig config = ServiceConfig::from_env();
    MetricsRegistry metrics;
    BoundedCache cache(config.cache_capacity());
    StateServiceImpl service(config, metrics, cache);  // injected by reference

    const std::string addr = "0.0.0.0:50051";
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
    wire_log("+server", addr);
    std::cout << "statelessness/04-process-scoped-state listening on " << addr
              << " (healthz :8080)" << std::endl;

    g_server->Wait();

    // ── Teardown. The server is held in a global so the signal handler
    //    can reach it; reset it explicitly here so "-server" is logged
    //    before the local process-scoped state unwinds. Then main()
    //    returns and service → cache → metrics → config destruct in
    //    reverse construction order, each logging as it goes. ──
    wire_log("compose", "shutting down (reverse-order teardown)");
    g_server.reset();
    wire_log("-server", "");

    g_shutting_down.store(true, std::memory_order_relaxed);
    int hfd = g_health_fd.load(std::memory_order_relaxed);
    if (hfd >= 0) ::shutdown(hfd, SHUT_RDWR);
    if (health_thread.joinable()) health_thread.join();
    return 0;
}
