// Demo 1 — a minimal C++23 HTTP service representative enough that the
// build differences (UBI vs UBI-micro, LTO, PGO) produce measurable deltas
// under `hey` load. Uses cpp-httplib (header-only) for minimal deps.

#include <httplib.h>

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdint>
#include <cstdlib>
#include <print>      // C++23 std::print
#include <string>
#include <string_view>
#include <thread>

namespace {

// Some honest CPU work: a tight checksum over a buffer the request size.
// Exists so LTO and PGO have something to inline through.
std::uint64_t checksum(std::string_view body) {
  std::uint64_t h = 14695981039346656037ull;  // FNV-1a 64
  for (unsigned char c : body) {
    h ^= c;
    h *= 1099511628211ull;
  }
  return h;
}

// File-scope server pointer so the signal handler can call srv.stop().
// Without this, SIGTERM is ignored, the server runs forever, podman
// SIGKILLs after 10s, and (for the PGO instrumented build) libgcov's
// atexit handler never runs — so no .gcda files get flushed and PGO
// training silently produces an empty profile.
httplib::Server* g_srv = nullptr;

void handle_signal(int) {
  if (g_srv) {
    g_srv->stop();
  }
}

}  // namespace

int main() {
  const auto bind_addr = std::getenv("BIND_ADDR") ? std::getenv("BIND_ADDR") : "0.0.0.0";
  const auto bind_port = std::getenv("BIND_PORT") ? std::atoi(std::getenv("BIND_PORT")) : 8080;

  httplib::Server srv;
  g_srv = &srv;

  // Graceful-shutdown handlers so atexit (and therefore libgcov's
  // .gcda writer for PGO instrumented builds) gets to run.
  std::signal(SIGTERM, handle_signal);
  std::signal(SIGINT, handle_signal);

  // cpp-httplib's default task queue is `std::thread::hardware_concurrency()`,
  // which is fine for steady-state but starves under benchmark loads
  // (hey -c 100). Bump to 64 so the latency table shows real numbers
  // instead of "?" because every request timed out.
  srv.new_task_queue = []() { return new httplib::ThreadPool(64); };

  std::atomic<std::uint64_t> req_count{0};

  srv.Get("/", [&](const httplib::Request& req, httplib::Response& res) {
    req_count.fetch_add(1, std::memory_order_relaxed);
    const auto h = checksum(req.target);
    res.set_content(std::format("hello cksum={:016x}\n", h), "text/plain");
  });

  // POST /echo — exercises body-handling and a different code path
  // than GET /, giving PGO training something with real variety to
  // profile through.
  srv.Post("/echo", [&](const httplib::Request& req, httplib::Response& res) {
    req_count.fetch_add(1, std::memory_order_relaxed);
    const auto h = checksum(req.body);
    res.set_content(
        std::format("len={} cksum={:016x}\n", req.body.size(), h),
        "text/plain");
  });

  srv.Get("/healthz", [](const httplib::Request&, httplib::Response& res) {
    res.set_content("ok\n", "text/plain");
  });

  srv.Get("/metrics", [&](const httplib::Request&, httplib::Response& res) {
    res.set_content(std::format("requests_total {}\n", req_count.load()),
                    "text/plain");
  });

  std::println("demo-01 listening on {}:{}", bind_addr, bind_port);
  if (!srv.listen(bind_addr, bind_port)) {
    std::println(stderr, "listen failed");
    return 1;
  }
  // srv.listen returns when srv.stop() is called from the signal handler.
  // main returning lets atexit handlers run cleanly, which is what
  // flushes .gcda files when this binary was compiled with -fprofile-generate.
  std::println("demo-01 stopped cleanly");
  return 0;
}
