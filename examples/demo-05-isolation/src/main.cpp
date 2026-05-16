// Demo 5 — twin source for both tenants.
//
// Built twice with two different defines:
//   -DTENANT_A : an HTTP service with a small latency-sensitive handler
//   -DTENANT_B : a tight CPU/memory loop, no HTTP, just churns
//
// Single source so the comparison is on tenancy/isolation, not codebases.

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdint>
#include <cstdlib>
#include <print>
#include <random>
#include <thread>
#include <vector>

#if defined(TENANT_A)
  #include <httplib.h>
  #include <netinet/tcp.h>  // TCP_NODELAY
  #include <sys/socket.h>   // setsockopt, SOL_SOCKET, SO_REUSEADDR
#endif

namespace {
std::atomic<bool> g_stop{false};
void on_sig(int) { g_stop = true; }
}  // namespace

#if defined(TENANT_A)
int main() {
    std::signal(SIGTERM, on_sig);
    std::signal(SIGINT,  on_sig);

    httplib::Server svr;

    // ── r84 httplib config (carried over from demo-06) ──
    //
    // The library defaults are tuned for low-volume HTTP, not load
    // testing. Three knobs matter for stable percentiles under hey:
    //
    //   keep_alive_max_count:   5     → conn retires after 5 reqs
    //   keep_alive_timeout_sec: 5     → idle conn dies in 5s
    //   ThreadPool size:        ~cpu  → too small for 50+ hey workers
    //
    // Without these, hey reports >270ms averages and 10s tail
    // latencies — and the isolation comparisons we're trying to
    // make are drowned in connection-setup overhead.
    //
    // ── G-39 (r97): ThreadPool size vs hey concurrency ──
    //
    // With keep_alive enabled, each accepted TCP connection occupies
    // one ThreadPool worker for its ENTIRE lifetime (not per request).
    // If hey's -c exceeds the pool size, the excess connections sit
    // in the accept queue with no worker to service them, and time
    // out at hey's default 20-sec per-request timeout.
    //
    // demo-05 default test is `hey -c 25`; pool=16 produced exactly
    // 25-16=9 stuck connections (r95 observation). Pool=64 covers
    // both -c 25 and -c 50 (demo-06's pattern) with headroom.
    svr.set_keep_alive_max_count(1000);
    svr.set_keep_alive_timeout(60);
    svr.new_task_queue = [] { return new httplib::ThreadPool(64); };

    // ── G-36: TCP_NODELAY (Nagle + delayed-ACK trap) ──
    //
    // httplib writes the HTTP response in multiple small write()s.
    // Nagle's algorithm holds the second packet until ACK for the
    // first; the client does delayed-ACK (waits up to 40ms hoping
    // to piggyback). Net effect: 40ms minimum response time even
    // when server work is 200µs.
    //
    // TCP_NODELAY disables Nagle on accepted sockets. SO_REUSEADDR
    // restored here because set_socket_options REPLACES httplib's
    // default callback (which would otherwise set it).
    svr.set_socket_options([](auto sock) {
        int yes = 1;
        setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    });

    svr.Get("/", [](const httplib::Request&, httplib::Response& res) {
        // Latency-sensitive: small CPU burst + a touch of memory access.
        thread_local std::vector<std::uint64_t> buf(4096);
        std::mt19937_64 rng(static_cast<std::uint64_t>(
            std::chrono::steady_clock::now().time_since_epoch().count()));
        std::uint64_t acc = 0;
        for (int i = 0; i < 2000; ++i) acc ^= buf[rng() % buf.size()] + i;
        res.set_content("ok\n", "text/plain");
        if (acc == 42) res.set_content("?\n", "text/plain");  // prevent DCE
    });
    svr.Get("/healthz", [](const httplib::Request&, httplib::Response& res) {
        res.set_content("ok", "text/plain");
    });
    std::print("tenant-a listening on :8080\n");
    std::thread t([&] { svr.listen("0.0.0.0", 8080); });
    while (!g_stop.load(std::memory_order_relaxed))
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    svr.stop();
    t.join();
    return 0;
}
#elif defined(TENANT_B)
int main() {
    std::signal(SIGTERM, on_sig);
    std::signal(SIGINT,  on_sig);
    // Match the host CPU count so we maximize contention pressure.
    const unsigned n = std::max(1u, std::thread::hardware_concurrency());
    std::print("tenant-b churning on {} cores\n", n);
    std::vector<std::jthread> ts;
    for (unsigned i = 0; i < n; ++i) {
        ts.emplace_back([&] {
            std::vector<std::uint64_t> buf(1u << 22);  // ~32 MB per worker
            std::mt19937_64 rng(0xBADu);
            std::uint64_t acc = 0;
            while (!g_stop.load(std::memory_order_relaxed)) {
                for (int k = 0; k < 200000; ++k) {
                    acc ^= buf[rng() % buf.size()] + k;
                }
            }
            if (acc == 0) std::print(".");
        });
    }
    while (!g_stop.load(std::memory_order_relaxed))
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    return 0;
}
#else
  #error "Define TENANT_A or TENANT_B"
#endif
