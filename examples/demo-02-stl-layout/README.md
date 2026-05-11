# Demo 02 — STL & Layout Under Memory Pressure

Compares four key-value container designs on two operations, run once
unconstrained and once under a cgroup memory cap, to demonstrate how
data layout determines cache behavior — the lesson §6 (STL & C++20/23
Containers) develops.

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

Sizes: `64`, `1024`, `16384`, `262144`. The last size is where
the 128M cgroup memory cap in the pressured run starts to bite for
node-based containers.

## Run it

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

## What to look for

At `N=262144` in the iterate-and-sum benchmarks:

- `BM_Iterate_FlatMap` and `BM_Iterate_VectorLinear` should
  finish in roughly the same time — both are contiguous; the
  prefetcher feeds them at memory bandwidth.
- `BM_Iterate_UnorderedMap` is much slower — every node is a
  separate cache miss.
- `BM_Iterate_Map` is the slowest — RB-tree traversal is both
  node-based and branch-y.

Under pressure, the **ratio** column tells the story. Pressured
ratio close to 1.0× means the container's layout is friendly to
the cgroup; ratios of 2-10× or more mean the kernel is evicting
pages the container then has to fault back in.

## Reading the JSON output yourself

Each benchmark function reports `real_time` (wall clock) and
`cpu_time` (busy CPU). With `--benchmark_repetitions=3` (set in
the Containerfile), Google Benchmark adds aggregate entries with
`aggregate_name` set to `mean`, `median`, `stddev`. The demo
script reads only the `median` rows.

```bash
jq '.benchmarks[] | select(.aggregate_name == "median")' \
   results-baseline.json
```

## Where the lesson lives in the tutorial

- §3 (RAII): the per-element allocation count for node-based
  containers is a real cost paid at insert time and unwound at
  destruction time. Owning a million `std::map` entries costs
  a million destructor calls.
- §6 (STL & Layout): this demo. Cache locality > algorithmic
  complexity at the scales where most applications operate.
- §7 (Memory management): allocator choice matters; even a
  custom allocator can't beat layout. Use both.
- §11 (Noisy neighbors): cgroup memory pressure isn't theoretical
  on a shared host — your noisy neighbor's working set is what
  causes the kernel to evict your pages.
