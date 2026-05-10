// Demo 1 — a minimal C++23 HTTP service representative enough that the
// build differences (UBI vs UBI-micro, LTO, PGO) produce measurable deltas
// under `hey` load. Uses cpp-httplib (header-only) for minimal deps.

#include <httplib.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <print>      // C++23 std::print
#include <string>
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

}  // namespace

int main() {
  const auto bind_addr = std::getenv("BIND_ADDR") ? std::getenv("BIND_ADDR") : "0.0.0.0";
  const auto bind_port = std::getenv("BIND_PORT") ? std::atoi(std::getenv("BIND_PORT")) : 8080;

  httplib::Server srv;

  std::atomic<std::uint64_t> req_count{0};

  srv.Get("/", [&](const httplib::Request& req, httplib::Response& res) {
    req_count.fetch_add(1, std::memory_order_relaxed);
    const auto h = checksum(req.target);
    res.set_content(std::format("hello cksum={:016x}\n", h), "text/plain");
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
  return 0;
}
