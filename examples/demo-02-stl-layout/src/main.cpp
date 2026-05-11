// Demo-02: STL & layout benchmark.
//
// Compares four key-value containers on two operations across four
// sizes, to demonstrate how memory layout determines cache locality
// — the §6 (STL & C++20/23 Containers) lesson made concrete.
//
//   Containers:
//     - std::unordered_map<K,V>    hash, node-based, one alloc per insert
//     - std::map<K,V>              RB tree, node-based, one alloc per insert
//     - boost::container::flat_map sorted vector, contiguous storage
//     - std::vector<pair<K,V>>     contiguous + linear scan (worst case
//                                  asymptotically but cache-friendly)
//
//   Operations:
//     - BM_Lookup_Hit    1000 lookups for keys that exist in the container
//     - BM_IterateAndSum walk every entry, sum a payload field
//
// Run the same binary twice — once unconstrained, once under a
// cgroup memory cap — and compare. Node-based containers fault and
// thrash under pressure; contiguous layouts stay cache-hot. The
// containing demo.sh orchestrates both phases.
//
// What this benchmark deliberately doesn't measure:
//   - Insert throughput (allocator-dominated; a different story).
//   - Cache-cold lookup latency (needs cache-flush primitives).
//   - Mixed workload patterns (real apps look different).
// Pick one lesson per demo; this one is "contiguous wins for
// iterate, and is competitive for lookup at small-to-medium sizes."

#include <algorithm>
#include <cstdint>
#include <map>
#include <random>
#include <unordered_map>
#include <utility>
#include <vector>

#include <benchmark/benchmark.h>
#include <boost/container/flat_map.hpp>

namespace bc = boost::container;

// 128-byte payload — large enough that node-based allocations
// don't get coalesced by malloc's small-allocator paths, small
// enough that big-N benchmarks fit in a 128M cgroup. Aligned for
// reproducibility across runs.
struct alignas(16) Payload {
    std::uint64_t a;
    std::uint64_t b;
    char          padding[128 - 2 * sizeof(std::uint64_t)];
};

// Deterministic key set: random shuffle of [0, N), same seed
// everywhere so benchmarks are comparable across runs and
// across containers.
namespace {

std::vector<int> make_keys(int n) {
    std::vector<int> keys(static_cast<std::size_t>(n));
    for (int i = 0; i < n; ++i) keys[static_cast<std::size_t>(i)] = i;
    std::mt19937 rng(0xC0FFEEu);
    std::shuffle(keys.begin(), keys.end(), rng);
    return keys;
}

Payload make_payload(int i) {
    return Payload{
        .a = static_cast<std::uint64_t>(i),
        .b = static_cast<std::uint64_t>(i) * 0x9E3779B97F4A7C15ULL,
        .padding = {}
    };
}

// Populate any associative container that supports operator[].
template <class Map>
void fill_map(Map& m, const std::vector<int>& keys) {
    for (int k : keys) m[k] = make_payload(k);
}

// Populate a vector of pairs by appending in key order then sorting
// (mirrors how you'd build one in real code).
void fill_vec(std::vector<std::pair<int, Payload>>& v,
              const std::vector<int>& keys) {
    v.reserve(keys.size());
    for (int k : keys) v.emplace_back(k, make_payload(k));
    std::sort(v.begin(), v.end(),
              [](const auto& l, const auto& r) { return l.first < r.first; });
}

// 1000 keys to look up per iteration. Picked from the populated
// key set so every lookup hits.
std::vector<int> make_query_keys(const std::vector<int>& keys, int q) {
    std::mt19937 rng(0xCAFEBABEu);
    std::vector<int> queries;
    queries.reserve(static_cast<std::size_t>(q));
    std::uniform_int_distribution<std::size_t> dist(0, keys.size() - 1);
    for (int i = 0; i < q; ++i) queries.push_back(keys[dist(rng)]);
    return queries;
}

constexpr int kQueries = 1000;

}  // namespace

// ────────────────────────────────────────────────────────────────
//  Lookup benchmarks — 1000 lookups per iteration; key always
//  exists. Reports ns/iteration which divides into per-lookup
//  cost on the order of 100-2000 ns depending on N and container.
// ────────────────────────────────────────────────────────────────

static void BM_Lookup_UnorderedMap(benchmark::State& state) {
    const int n = static_cast<int>(state.range(0));
    auto keys = make_keys(n);
    std::unordered_map<int, Payload> m;
    m.reserve(static_cast<std::size_t>(n));
    fill_map(m, keys);
    auto queries = make_query_keys(keys, kQueries);
    for (auto _ : state) {
        std::uint64_t sink = 0;
        for (int k : queries) sink += m.find(k)->second.a;
        benchmark::DoNotOptimize(sink);
    }
    state.SetItemsProcessed(state.iterations() * kQueries);
}

static void BM_Lookup_Map(benchmark::State& state) {
    const int n = static_cast<int>(state.range(0));
    auto keys = make_keys(n);
    std::map<int, Payload> m;
    fill_map(m, keys);
    auto queries = make_query_keys(keys, kQueries);
    for (auto _ : state) {
        std::uint64_t sink = 0;
        for (int k : queries) sink += m.find(k)->second.a;
        benchmark::DoNotOptimize(sink);
    }
    state.SetItemsProcessed(state.iterations() * kQueries);
}

static void BM_Lookup_FlatMap(benchmark::State& state) {
    const int n = static_cast<int>(state.range(0));
    auto keys = make_keys(n);
    bc::flat_map<int, Payload> m;
    m.reserve(static_cast<std::size_t>(n));
    fill_map(m, keys);
    auto queries = make_query_keys(keys, kQueries);
    for (auto _ : state) {
        std::uint64_t sink = 0;
        for (int k : queries) sink += m.find(k)->second.a;
        benchmark::DoNotOptimize(sink);
    }
    state.SetItemsProcessed(state.iterations() * kQueries);
}

static void BM_Lookup_VectorLinear(benchmark::State& state) {
    const int n = static_cast<int>(state.range(0));
    auto keys = make_keys(n);
    std::vector<std::pair<int, Payload>> v;
    fill_vec(v, keys);
    auto queries = make_query_keys(keys, kQueries);
    for (auto _ : state) {
        std::uint64_t sink = 0;
        for (int k : queries) {
            // Linear scan. O(N) per lookup — included as the
            // "trivial implementation" benchmark to show where
            // cache locality stops being enough.
            for (const auto& entry : v) {
                if (entry.first == k) { sink += entry.second.a; break; }
            }
        }
        benchmark::DoNotOptimize(sink);
    }
    state.SetItemsProcessed(state.iterations() * kQueries);
}

// ────────────────────────────────────────────────────────────────
//  Iterate-and-sum benchmarks — walk every entry once per
//  iteration, sum a payload field. Cache locality dominates;
//  contiguous layouts should beat node-based by significant
//  margins at large N.
// ────────────────────────────────────────────────────────────────

static void BM_Iterate_UnorderedMap(benchmark::State& state) {
    const int n = static_cast<int>(state.range(0));
    auto keys = make_keys(n);
    std::unordered_map<int, Payload> m;
    m.reserve(static_cast<std::size_t>(n));
    fill_map(m, keys);
    for (auto _ : state) {
        std::uint64_t sink = 0;
        for (const auto& [k, v] : m) sink += v.a;
        benchmark::DoNotOptimize(sink);
    }
    state.SetItemsProcessed(state.iterations() * n);
}

static void BM_Iterate_Map(benchmark::State& state) {
    const int n = static_cast<int>(state.range(0));
    auto keys = make_keys(n);
    std::map<int, Payload> m;
    fill_map(m, keys);
    for (auto _ : state) {
        std::uint64_t sink = 0;
        for (const auto& [k, v] : m) sink += v.a;
        benchmark::DoNotOptimize(sink);
    }
    state.SetItemsProcessed(state.iterations() * n);
}

static void BM_Iterate_FlatMap(benchmark::State& state) {
    const int n = static_cast<int>(state.range(0));
    auto keys = make_keys(n);
    bc::flat_map<int, Payload> m;
    m.reserve(static_cast<std::size_t>(n));
    fill_map(m, keys);
    for (auto _ : state) {
        std::uint64_t sink = 0;
        for (const auto& [k, v] : m) sink += v.a;
        benchmark::DoNotOptimize(sink);
    }
    state.SetItemsProcessed(state.iterations() * n);
}

static void BM_Iterate_VectorLinear(benchmark::State& state) {
    const int n = static_cast<int>(state.range(0));
    auto keys = make_keys(n);
    std::vector<std::pair<int, Payload>> v;
    fill_vec(v, keys);
    for (auto _ : state) {
        std::uint64_t sink = 0;
        for (const auto& [k, p] : v) sink += p.a;
        benchmark::DoNotOptimize(sink);
    }
    state.SetItemsProcessed(state.iterations() * n);
}

// ────────────────────────────────────────────────────────────────
//  Registration — four sizes spanning small (fits L2) through
//  large (overflows L3 on a typical desktop, makes the cgroup
//  pressure phase meaningful).
//
//  BM_Lookup_VectorLinear gets asymmetric registration: it's
//  capped at N≤16384 because its inner loop is O(N) per lookup,
//  giving the benchmark O(N²) total work (1000 queries × N
//  entries scanned each). At N=262144 that's 262M comparisons
//  per Google Benchmark `state` iteration, and the framework
//  auto-iterates until ~0.5s of CPU time accumulates — easily
//  10+ minutes for that one case. The iterate-and-sum on the
//  same vector is still O(N) per iteration and runs at full
//  size cheaply.
//
//  The lesson the missing N=262144 lookup row teaches is itself
//  worth something: "this is where linear scan stops being a
//  realistic option." That's the §6 message in compressed form.
// ────────────────────────────────────────────────────────────────

static constexpr int kSizes[] = {64, 1024, 16384, 262144};

#define REGISTER_BENCH_ALL_SIZES(fn)                               \
    BENCHMARK(fn)                                                  \
        ->Arg(kSizes[0])->Arg(kSizes[1])                           \
        ->Arg(kSizes[2])->Arg(kSizes[3])                           \
        ->Unit(benchmark::kMicrosecond)

#define REGISTER_BENCH_SMALL_SIZES(fn)                             \
    BENCHMARK(fn)                                                  \
        ->Arg(kSizes[0])->Arg(kSizes[1])                           \
        ->Arg(kSizes[2])                                           \
        ->Unit(benchmark::kMicrosecond)

REGISTER_BENCH_ALL_SIZES(BM_Lookup_UnorderedMap);
REGISTER_BENCH_ALL_SIZES(BM_Lookup_Map);
REGISTER_BENCH_ALL_SIZES(BM_Lookup_FlatMap);
REGISTER_BENCH_SMALL_SIZES(BM_Lookup_VectorLinear);  // O(N²); skip 262144
REGISTER_BENCH_ALL_SIZES(BM_Iterate_UnorderedMap);
REGISTER_BENCH_ALL_SIZES(BM_Iterate_Map);
REGISTER_BENCH_ALL_SIZES(BM_Iterate_FlatMap);
REGISTER_BENCH_ALL_SIZES(BM_Iterate_VectorLinear);

BENCHMARK_MAIN();
