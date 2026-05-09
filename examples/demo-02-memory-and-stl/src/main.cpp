// Demo 2 — memory and STL microbench.
//
// Single-binary harness that runs three workloads and prints CSV-friendly
// rows. The driver script (demo.sh) runs this binary multiple times under
// different allocator/cgroup configurations and aggregates the rows.
//
// Usage: demo-bench <workload> <iterations> <label>
//   workload: set | flat_set | alloc_default | alloc_pmr | random_access
//
// We deliberately avoid pulling in google-benchmark; the harness is small
// enough to read in one sitting, and rolling our own keeps the build
// hermetic.

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <memory_resource>
#include <print>
#include <random>
#include <set>
#include <span>
#include <string_view>
#include <vector>

#if __has_include(<flat_set>)
  #include <flat_set>
  #define HAS_FLAT_SET 1
#else
  #define HAS_FLAT_SET 0
#endif

namespace {

using clk = std::chrono::steady_clock;

template <typename F>
auto time_us(F&& f) {
  auto t0 = clk::now();
  f();
  auto t1 = clk::now();
  return std::chrono::duration_cast<std::chrono::microseconds>(t1 - t0).count();
}

// Deterministic key generation so runs are comparable.
std::vector<int> make_keys(std::size_t n, std::uint64_t seed = 0xC0FFEE) {
  std::mt19937_64 rng(seed);
  std::vector<int> v(n);
  for (auto& k : v) k = static_cast<int>(rng() & 0x7FFFFFFF);
  return v;
}

long long bench_set(std::size_t n) {
  auto keys = make_keys(n);
  std::set<int> s(keys.begin(), keys.end());
  volatile std::size_t hits = 0;
  return time_us([&] {
    for (int k : keys) hits += s.contains(k);
  });
}

long long bench_flat_set(std::size_t n) {
#if HAS_FLAT_SET
  auto keys = make_keys(n);
  std::flat_set<int> s(keys.begin(), keys.end());
  volatile std::size_t hits = 0;
  return time_us([&] {
    for (int k : keys) hits += s.contains(k);
  });
#else
  // Without C++23 <flat_set>, simulate the layout: sorted vector + binary search.
  // The point is the contiguous-storage lookup pattern; this gives a comparable
  // number even on stdlibs that haven't shipped flat_set yet.
  auto keys = make_keys(n);
  std::vector<int> s = keys;
  std::sort(s.begin(), s.end());
  s.erase(std::unique(s.begin(), s.end()), s.end());
  volatile std::size_t hits = 0;
  return time_us([&] {
    for (int k : keys) hits += std::binary_search(s.begin(), s.end(), k);
  });
#endif
}

long long bench_alloc_default(std::size_t n) {
  // Many short-lived small allocations, the classic allocator stress test.
  return time_us([&] {
    std::vector<std::unique_ptr<std::array<int, 16>>> pool;
    pool.reserve(n);
    for (std::size_t i = 0; i < n; ++i) {
      pool.push_back(std::make_unique<std::array<int, 16>>());
      (*pool.back())[0] = static_cast<int>(i);
    }
  });
}

long long bench_alloc_pmr(std::size_t n) {
  // Same pattern, but with a per-iteration monotonic buffer arena.
  return time_us([&] {
    std::array<std::byte, 1 << 20> buf;  // 1 MiB stack arena
    std::pmr::monotonic_buffer_resource arena(buf.data(), buf.size());
    std::pmr::vector<std::pmr::vector<int>> pool(&arena);
    pool.reserve(n);
    for (std::size_t i = 0; i < n; ++i) {
      pool.emplace_back(16, 0, &arena);
      pool.back()[0] = static_cast<int>(i);
    }
  });
}

long long bench_random_access(std::size_t n) {
  // Force page faults by striding through a buffer larger than L3.
  std::vector<std::uint64_t> buf(n / sizeof(std::uint64_t));
  std::mt19937_64 rng(0xBEEF);
  std::uint64_t acc = 0;
  return time_us([&] {
    for (std::size_t i = 0; i < buf.size(); ++i) {
      acc += buf[rng() % buf.size()];
    }
    if (acc == 42) std::print("\n");  // prevent DCE
  });
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 4) {
    std::print(stderr,
               "usage: {} <set|flat_set|alloc_default|alloc_pmr|random_access> "
               "<iterations> <label>\n",
               argv[0]);
    return 2;
  }
  std::string_view workload{argv[1]};
  std::size_t n = static_cast<std::size_t>(std::strtoull(argv[2], nullptr, 10));
  std::string_view label{argv[3]};

  long long us = -1;
  if      (workload == "set")            us = bench_set(n);
  else if (workload == "flat_set")       us = bench_flat_set(n);
  else if (workload == "alloc_default")  us = bench_alloc_default(n);
  else if (workload == "alloc_pmr")      us = bench_alloc_pmr(n);
  else if (workload == "random_access")  us = bench_random_access(n);
  else {
    std::print(stderr, "unknown workload: {}\n", workload);
    return 2;
  }

  // CSV row: workload,label,iterations,microseconds
  std::print("{},{},{},{}\n", workload, label, n, us);
  return 0;
}
