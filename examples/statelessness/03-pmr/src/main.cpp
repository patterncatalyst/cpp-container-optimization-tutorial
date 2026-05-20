// main.cpp — statelessness/03-pmr server.
//
// A gRPC callback-API server demonstrating the request arena from
// compendium Doc 03. Two modes, chosen by the request's `mode` field:
//
//   "arena" → allocate per-request scratch (pmr::vector<pmr::string>,
//             pmr::unordered_map) from a layered RequestArena, process
//             the payload, return. All scratch is released in bulk when
//             the arena leaves scope — no per-object deallocation.
//
//   "bench" → time the asymmetry Doc 03 describes: allocating and
//             releasing N objects through a monotonic arena (bulk O(1)
//             release) versus N individual new/delete pairs (O(N)
//             release). Returns both timings so the caller sees the
//             ratio.
//
// The lifetime trap that Doc 03 warns about is demonstrated separately
// in pmr_trap.cpp (a standalone ASan binary) — you cannot safely host a
// use-after-free inside a long-lived service.
//
// A minimal HTTP healthz on :8080 lets the harness wait for readiness.

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstring>
#include <iostream>
#include <memory>
#include <memory_resource>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <grpcpp/grpcpp.h>
#include <grpcpp/health_check_service_interface.h>

#include "processor.grpc.pb.h"
#include "request_arena.hpp"

namespace statelesspmr {
namespace {

std::mutex g_log_mu;
void log_line(const std::string& s) {
    std::lock_guard<std::mutex> lk(g_log_mu);
    std::cout << s << std::endl;
}

std::atomic<std::uint64_t> g_req_seq{1};
std::string mint_request_id() {
    return "req-" + std::to_string(g_req_seq.fetch_add(1, std::memory_order_relaxed));
}

using clock_type = std::chrono::steady_clock;
std::int64_t micros_since(clock_type::time_point t0) {
    return std::chrono::duration_cast<std::chrono::microseconds>(
               clock_type::now() - t0)
        .count();
}

// ── arena mode: per-request scratch from the layered arena ───────────
void do_arena_work(const std::string& request_id, const std::string& payload,
                   ProcessResponse* resp) {
    // The request arena lives exactly for this scope. Everything
    // allocated through it is released in bulk when it's destroyed.
    RequestArena arena;

    // Node-based and contiguous containers alike draw from the arena.
    std::pmr::vector<std::pmr::string> tokens(arena.resource());
    std::pmr::unordered_map<std::pmr::string, int> counts(arena.resource());

    // Trivial "work": split the payload on '-' into arena-allocated
    // tokens and count occurrences. None of this touches the global
    // heap after the arena's initial buffer is allocated.
    std::pmr::string current(arena.resource());
    auto flush = [&]() {
        if (!current.empty()) {
            tokens.push_back(current);
            counts[current] += 1;
            current.clear();
        }
    };
    for (char c : payload) {
        if (c == '-') {
            flush();
        } else {
            current.push_back(c);
        }
    }
    flush();

    log_line("[pmr] arena id=" + request_id +
             " tokens=" + std::to_string(tokens.size()) +
             " distinct=" + std::to_string(counts.size()) +
             " (all freed in bulk at scope end)");

    resp->set_result("tokens=" + std::to_string(tokens.size()) +
                     " distinct=" + std::to_string(counts.size()));
}  // arena destroyed here → O(1) bulk release of every token + node

// ── bench mode: arena bulk release vs per-object new/delete ──────────
void do_bench(const std::string& request_id, int iterations,
              ProcessResponse* resp) {
    if (iterations <= 0) iterations = 10000;
    const std::string sample = "pricing-context-token";

    // Arena side: allocate `iterations` arena strings, then release the
    // whole arena at once. The cost of freeing is O(1) — a handful of
    // upstream block frees — regardless of how many objects were made.
    auto t0 = clock_type::now();
    {
        RequestArena arena(static_cast<std::size_t>(iterations) * 64 + 4096);
        std::pmr::vector<std::pmr::string> v(arena.resource());
        v.reserve(static_cast<std::size_t>(iterations));
        for (int i = 0; i < iterations; ++i) {
            // The vector was constructed with the arena resource, so it
            // propagates that allocator to each element via uses-
            // allocator construction. Do NOT pass the resource again
            // here — that double-specifies the allocator and fails the
            // uses_allocator static assertion.
            v.emplace_back(sample.c_str());
        }
    }  // bulk release
    std::int64_t arena_us = micros_since(t0);

    // Per-object side: `iterations` individual heap allocations, then
    // `iterations` individual frees. The free loop is O(N).
    auto t1 = clock_type::now();
    {
        std::vector<std::string*> ptrs;
        ptrs.reserve(static_cast<std::size_t>(iterations));
        for (int i = 0; i < iterations; ++i) {
            ptrs.push_back(new std::string(sample));
        }
        for (auto* p : ptrs) {
            delete p;
        }
    }
    std::int64_t perobj_us = micros_since(t1);

    log_line("[pmr] bench id=" + request_id +
             " iterations=" + std::to_string(iterations) +
             " arena_us=" + std::to_string(arena_us) +
             " perobject_us=" + std::to_string(perobj_us));

    resp->set_arena_micros(arena_us);
    resp->set_perobject_micros(perobj_us);
    // Deliberately NOT claiming "arena is faster". Doc 03's honest
    // position: PMR's reliable win is bounded, predictable per-request
    // memory and shrunken tail-latency variance, not mean throughput —
    // glibc's allocator is fast, so at modest N the two can be within
    // noise or the heap can even win. The architectural reason (request-
    // scope memory tied to request-scope lifetime) is the point; the
    // numbers are context, not a scoreboard.
    resp->set_result("compare arena_micros vs perobject_micros; PMR's "
                     "headline win is tail-latency predictability, not "
                     "mean throughput (see Doc 03)");
}

class MemoryProcessorImpl final : public MemoryProcessor::CallbackService {
public:
    grpc::ServerUnaryReactor* Process(grpc::CallbackServerContext* ctx,
                                      const ProcessRequest* req,
                                      ProcessResponse* resp) override {
        auto* reactor = ctx->DefaultReactor();
        reactor->Finish(handle(req, resp));
        return reactor;
    }

private:
    grpc::Status handle(const ProcessRequest* req, ProcessResponse* resp) {
        const std::string request_id = mint_request_id();
        resp->set_request_id(request_id);
        auto t0 = clock_type::now();

        const std::string& mode = req->mode();
        if (mode == "bench") {
            do_bench(request_id, req->iterations(), resp);
        } else if (mode.empty() || mode == "arena") {
            do_arena_work(request_id, req->payload(), resp);
        } else {
            return grpc::Status(grpc::StatusCode::INVALID_ARGUMENT,
                                "mode must be 'arena' or 'bench'");
        }

        resp->set_handler_duration_micros(micros_since(t0));
        return grpc::Status::OK;
    }
};

// ── Minimal HTTP healthz on :8080 (same as 02-raii) ──────────────────
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
}  // namespace statelesspmr

int main() {
    using namespace statelesspmr;
    std::signal(SIGINT, on_signal);
    std::signal(SIGTERM, on_signal);

    std::thread health_thread(run_healthz, 8080);

    const std::string addr = "0.0.0.0:50051";
    MemoryProcessorImpl service;
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
    std::cout << "statelessness/03-pmr server listening on " << addr
              << " (healthz :8080)" << std::endl;

    g_server->Wait();

    g_shutting_down.store(true, std::memory_order_relaxed);
    int hfd = g_health_fd.load(std::memory_order_relaxed);
    if (hfd >= 0) ::shutdown(hfd, SHUT_RDWR);
    if (health_thread.joinable()) health_thread.join();
    std::cout << "shutdown complete" << std::endl;
    return 0;
}
