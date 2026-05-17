# Demo 02 — STL & Layout Under Memory Pressure

Tutorial section: [§6 STL, Layout, and C++20/23 Containers](/docs/06-stl-layout/)

Compares four key-value container designs on two operations, run
once unconstrained and once under a cgroup memory cap. The takeaway:
data layout determines cache behavior, and at production scales
cache locality usually beats algorithmic complexity.

## Why this matters

Most C++ services use `std::unordered_map` by default — its O(1)
average is the rule-of-thumb most engineers reach for. But "O(1)
average" hides the per-element node allocation, the pointer
indirection on every lookup, and the cache miss that happens because
the nodes are scattered across the heap. At small N, this doesn't
matter; the working set fits in L1. At large N, the node-based
container is paying constant cache-miss costs that the contiguous
alternatives don't.

C++20 added `std::flat_map` and `std::flat_set` to the standard
specifically because this lesson has been learned over and over in
production: when N is large enough to overflow L2, a sorted vector
with binary search outperforms a hash table even though the
theoretical complexity is worse. The constant factor for cache
locality is roughly 10-100×, which buys a lot of `log(N)`.

Add memory pressure — a cgroup `memory.max` that forces the kernel
to evict pages your container had warm — and the gap widens
dramatically. Node-based containers fault their scattered pages
back in repeatedly; contiguous containers stream from disk
sequentially and stay fast.

§6 of the tutorial develops the layout story; this demo measures
it.

## What this demo shows

Four container designs benchmarked at four sizes (64, 1024, 16384,
262144) on two operations (point lookup, full iteration), run twice
— once unconstrained, once under a 128 MB cgroup memory cap:

| Container | Layout | Per-element allocation |
|---|---|---|
| `std::unordered_map<K,V>` | hash table | one allocation per insert |
| `std::map<K,V>` | red-black tree | one allocation per insert |
| `boost::container::flat_map<K,V>` | sorted vector | bulk reallocation on growth |
| `std::vector<pair<K,V>>` + linear scan | contiguous unsorted | bulk reallocation on growth |

Operations:

- **Lookup**: 1,000 hits per iteration. Even node-based containers
  do well at small N because the working set fits in L1/L2.
- **Iterate-and-sum**: walk every entry and accumulate a payload
  field. Cache locality dominates; this is where contiguous
  layouts pull dramatically ahead at large N.

The 262144 size is where the 128 MB cgroup cap in the pressured
run starts to bite for node-based containers — that's the test
case the demo is built around.

## How to run

```bash
./demo.sh
```

First build is ~3-5 minutes (Conan pulls boost + Google Benchmark
from Conan Center, both pre-built for our profile in the common
case). Subsequent runs hit the podman layer cache and complete in
~30 seconds for both phases.

Outputs:

- `results-baseline.json` — unconstrained run
- `results-pressured.json` — `podman run --memory=128m --memory-swap=128m` run
- A side-by-side table on stdout, comparing median real_time per
  (benchmark, size) pair, with a pressure-ratio column

## What you'll see

Representative output at N=262144 on the iterate benchmarks
(microseconds per iteration, median of 3 runs):

```
Container                        baseline    pressured    ratio
boost::container::flat_map         911 µs       940 µs      1.03×
std::vector<pair> (linear scan)    920 µs       948 µs      1.03×
std::unordered_map               2,309 µs     5,840 µs      2.53×
std::map (RB tree)              32,000 µs   210,000 µs      6.56×
```

## How to read the output

At N=262144 on iterate-and-sum:

- **`flat_map` and `vector` linear-scan finish in roughly the same
  time**. Both are contiguous; the hardware prefetcher feeds them
  at memory bandwidth.
- **`unordered_map` is roughly 2.5× slower than the contiguous
  options**. Every node is a separate cache miss.
- **`std::map` is an order of magnitude slower**. RB-tree
  traversal is both node-based and branch-heavy; the branch
  predictor can't help.

Under pressure, the **ratio** column tells the story:

- **Ratio close to 1.0×** means the container's layout is friendly
  to the cgroup — contiguous pages stream back in cleanly.
- **Ratios of 2-10×** mean the kernel is evicting pages the
  container then has to fault back in. Every cache miss becomes a
  page fault, every page fault becomes a syscall, and the whole
  operation slows by orders of magnitude.

You can read the JSON output directly:

```bash
jq '.benchmarks[] | select(.aggregate_name == "median")' \
   results-baseline.json
```

Each benchmark function reports `real_time` (wall clock) and
`cpu_time` (busy CPU). With `--benchmark_repetitions=3` (set in
the Containerfile), Google Benchmark adds aggregate entries with
`aggregate_name` set to `mean`, `median`, `stddev`.

## Caveats and gotchas

- **Hash function matters.** `std::unordered_map` with a poor hash
  can be much slower than these numbers suggest — and a great
  hash can mask some of the cache-miss cost. The benchmark uses
  `std::hash<int>` which is identity on most platforms; if your
  keys are strings, the picture changes.
- **Insert order matters for `flat_map`.** Inserting in sorted
  order is O(N); inserting in random order is O(N²) because
  every insert shifts a tail. The demo inserts in sorted order;
  if your workload doesn't, measure separately.
- **`memory.max` vs `memory.high`.** The demo uses `--memory=128m`
  which sets `memory.max` (hard limit). Setting `memory.high`
  instead would soften the kernel's response — pages get reclaimed
  proactively but the process doesn't OOM. See §11 for the
  difference.
- **The benchmark is synthetic.** Real workloads mix container
  operations with other work; the working-set residency calculus
  changes. Treat the relative ordering as reliable; treat the
  absolute numbers as upper-bound for your real workload.

## Source materials

This demo deepens material from the project's
[**bibliography**](/bibliography/):

- **Andrist & Sehr, *C++ High Performance* 2e, ch. 6** — CPU and
  memory architecture; the cache-locality argument in detail
- **Iglberger, *C++ Software Design*, ch. 7** — Bridge / PIMPL
  and value-based containers; the design-level case for
  contiguous layouts
- **Enberg, *Latency*, ch. 4** — the cache-miss-as-syscall framing
  that motivates this whole demo

## Linked tutorial sections

- [**§3 RAII & Container Resource Discipline**](/docs/03-raii-discipline/)
  — the per-element allocation count for node-based containers is
  a real cost paid at insert time and unwound at destruction time.
  Owning a million `std::map` entries means a million destructor
  calls.
- [**§6 STL, Layout, and C++20/23 Containers**](/docs/06-stl-layout/)
  — this demo. Cache locality > algorithmic complexity at the
  scales where most applications operate.
- [**§7 Memory Management**](/docs/07-memory-management/) —
  allocator choice matters; even a custom allocator can't beat
  layout. Use both.
- [**§11 Noisy Neighbor Isolation**](/docs/11-noisy-neighbors/) —
  cgroup memory pressure isn't theoretical on a shared host — your
  noisy neighbor's working set is what causes the kernel to evict
  your pages.
