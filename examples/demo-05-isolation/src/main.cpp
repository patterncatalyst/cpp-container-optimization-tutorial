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
