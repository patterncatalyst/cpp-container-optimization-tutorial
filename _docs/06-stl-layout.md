---
title: "STL, Layout, and C++20/23 Containers"
order: 6
description: Why `boost::container::flat_map` is 2.5× faster than `std::unordered_map` and 35× faster than `std::map` on a real iterate workload, where the gap comes from, and the silent-overhead choices that betray "obvious" container picks.
duration: "15 minutes"
---

## Learning objectives

By the end of this section you can:

- Predict the cache behaviour of `std::vector`, `std::deque`,
  `std::list`, `std::map`, and `std::unordered_map` on a hot
  iterate-and-sum loop, and explain *why* the prediction holds.
- Pick between `std::map`, `std::unordered_map`,
  `boost::container::flat_map` (today; C++23 `std::flat_map`
  once compilers ship it), and a sorted `std::vector` of pairs
  based on insert pattern, lookup pattern, and N.
- Identify "silent overhead" — `std::function`, `std::shared_ptr`
  refcounts, `std::any`, virtual dispatch on a hot path — and
  decide whether each is worth what it costs you.
- Use `std::span` (C++20) and `std::mdspan` (C++23) to pass views
  without sharing ownership and without copying.
- Measure cache effects in a container with `perf stat` and
  decide whether the layout you have is the layout you need.

## Diagram

{% include excalidraw.html name="06-stl-layout-flat-vs-node" caption="Memory layout: contiguous vector vs node-based containers." %}

## The 2.5× hidden in your container choice

On the same `N=262144` workload, with the same payload struct,
on the same kernel — demo-02 measures these iterate-and-sum
median times:

| Container | Median iterate time | Relative |
|---|---|---|
| `boost::container::flat_map<K,V>` | **911 µs** | 1.0× (baseline) |
| `std::vector<pair<K,V>>` + linear scan | **~920 µs** | 1.0× |
| `std::unordered_map<K,V>` | **2,309 µs** | **2.5× slower** |
| `std::map<K,V>` | **~32 ms** | **~35× slower** |

The first two are contiguous. The third is a hash table with
nodes scattered across the heap. The fourth is a red-black tree
with both scattered nodes *and* a branch-heavy traversal.

The 2.5× gap between `flat_map` and `unordered_map` isn't about
algorithmic complexity. All four containers do roughly N work
to iterate. The gap is **about how many cache lines the CPU has
to fetch to do that work**.

A contiguous container packs ~16 `int` values into each 64-byte
cache line. The hardware prefetcher reads ahead 2-3 cache lines.
The CPU is reading from L1 most of the time, occasionally L2,
rarely main memory. Each value costs roughly 1 nanosecond.

A node-based container puts each value in its own heap
allocation, somewhere in the heap. The prefetcher can't help —
it has no way to know where the next node lives until the
current node's `next` pointer is dereferenced. Every node is a
fresh cache miss back to L2 or main memory. Each value costs
roughly 15-40 ns, sometimes 100+ ns under pressure.

**The data structure didn't change between contiguous and
scattered — the layout did.** This section is about making
that layout decision deliberately, before it shows up as a 2.5×
gap on the dashboard.

## Why contiguous wins — a cache-line view

The diagram above shows the two memory layouts side by side, but
the numeric mechanism is worth one paragraph more.

Modern x86-64 has 64-byte L1 cache lines. An `int` is 4 bytes,
so 16 ints fit in one line. A `std::vector<int>` stores them
back-to-back: line 1 holds elements 0-15, line 2 holds 16-31,
and so on. Iterating 1,000 elements touches ~63 cache lines —
and the L1 hardware prefetcher recognizes the linear stride and
fetches lines 2, 3, 4 *ahead of* line 1's load arriving in the
register file. By the time the CPU asks for element 16, the
line containing it is already in L1.

A `std::list<int>` stores each `int` in a 24-byte node (or
larger; depends on stdlib): 4 bytes for the data, 8 for `prev`,
8 for `next`, 4 for alignment padding. Each node is its own
heap allocation; the allocator places them wherever it has
space, which for a steady-state heap is essentially "anywhere in
the working set." The prefetcher sees no pattern. Each node
access stalls the pipeline waiting for the next cache line to
arrive.

The 2.5× number above is conservative; on workloads with
larger payloads (16-byte values, 64-byte values), the gap
widens further because the contiguous version still packs many
values per line while the node-based version is paying the
miss cost regardless of payload size.

The cache mechanism is the same one [§7 develops for the
allocator stack](../07-memory-management/): malloc costs are
small; the *first write to the page* that allocated memory
points to is what costs the time. STL container choice
determines both how many writes happen and how spatially
clustered they are.

## The four containers in question

Demo-02 benchmarks these four, deliberately:

```cpp
// 1. Hash table — O(1) lookup, scattered storage
std::unordered_map<int, Payload> u;

// 2. Red-black tree — O(log N) lookup, scattered storage,
//    branchy traversal
std::map<int, Payload> m;

// 3. Sorted vector adapter — O(log N) lookup (binary search),
//    contiguous storage, O(N) insert in the middle
boost::container::flat_map<int, Payload> f;

// 4. Unsorted vector — O(N) lookup (linear scan), contiguous
//    storage, O(1) amortized append
std::vector<std::pair<int, Payload>> v;
```

`boost::container::flat_map` is the shipping-today version of
C++23's `std::flat_map` (the standard version exists on paper
but library implementations are still catching up). It's a
header-only Boost component; including it doesn't pull the rest
of Boost. It implements the C++23 `flat_map` semantics — a
sorted vector of `pair<K,V>` under the hood, with a `map`-shaped
interface on top.

The trade-off shape is:

| Container | Lookup | Insert at end | Insert in middle | Iterate | Memory overhead per element |
|---|---|---|---|---|---|
| `unordered_map` | **O(1) avg** | O(1) amortized | O(1) amortized | slow (scattered) | bucket pointer + node header ≈ 24-48 bytes |
| `map` | O(log N) | O(log N) | O(log N) | slowest (RB-tree traversal) | 3 pointers + color flag ≈ 32-48 bytes |
| `flat_map` | O(log N) | O(1) amortized | **O(N)** | **fast (contiguous)** | ~0 — just the pair |
| `vector<pair>` linear | O(N) | O(1) amortized | O(N) | **fast (contiguous)** | ~0 — just the pair |

The choice is workload-shaped:

- **Read-heavy, mostly built once**: `flat_map`. Sort once at
  setup, then enjoy contiguous lookups and iterations forever.
- **Insert-heavy with random-position writes**: `unordered_map`,
  reluctantly. The O(N) middle-insert on `flat_map` will dominate.
- **Tiny N (under ~100)**: `vector<pair>` linear. The constant
  factors dwarf the O(N) cost; the CPU does linear scans in a
  few nanoseconds.
- **Need ordered iteration AND insert-heavy**: `map`. It's the
  worst on cache locality but the only one that gives you
  ordered traversal with O(log N) insert.

## Memory pressure makes the gap wider

Demo-02 runs the same benchmarks twice: once unconstrained, once
under `podman run --memory=128m --memory-swap=128m`. The
memory.high pressure forces the kernel to reclaim pages
aggressively (the [§7 cgroup memory.high mechanism](../07-memory-management/)
in action).

Under pressure, **node-based containers degrade faster than
contiguous ones**. Why: every reclaimed node-page triggers a
page fault on the next access; contiguous containers fault
once per N elements, scattered ones fault closer to once per
element. The "pressure ratio" column in demo-02's output
makes this concrete — `flat_map` typically shows a 1.0-1.2×
slowdown under pressure; `unordered_map` shows 2-5×; `map`
can be 10-50× worse depending on N.

This is the same mechanism that makes [§11's noisy-neighbor
scenario costly](../11-noisy-neighbors/) — once the system is
reclaiming pages, latency-sensitive containers with scattered
working sets pay the most.

## The default-to-vector rule

Reach for `std::vector` first. The four cases where it's wrong:

1. **You need stable iterators across insertions.** Vector
   invalidates iterators on resize; `std::deque` invalidates on
   push_front / push_back at the wrong end; `std::list` and
   `std::map` keep iterators valid. If you're holding an
   iterator across an insertion, vector fails.
2. **You insert in the middle frequently.** Vector's middle
   insert is O(N) — every element after the insertion shifts.
   Above a few hundred elements with frequent middle-inserts,
   `std::deque` or `std::list` wins.
3. **You need O(1) lookup by key, not by index.** Vector
   doesn't index by key; you need either a sorted vector +
   binary search (use `flat_map` instead) or a hash table.
4. **The element type is enormous and the container is tiny.**
   A `std::vector<std::array<char, 4096>>` of 3 elements is
   probably better as `std::array<std::array<char, 4096>, 3>`
   — the heap allocation is overhead.

In every other case — and this is most cases — `std::vector` is
the default that wins on cache locality, allocator simplicity,
and code readability all at once.

## C++23 `std::flat_map` (or `boost::container::flat_map` today)

C++23 added `std::flat_map`, `std::flat_set`, `std::flat_multimap`,
and `std::flat_multiset` as sorted-vector-of-pair adapters with
`map`-shaped interfaces. The promise is the same as the
`flat_map` row above: O(log N) lookup with contiguous storage,
at the cost of O(N) middle inserts.

Library support is still catching up:

| Library | Status |
|---|---|
| `<flat_map>` in libstdc++ | partial (gcc 15+) |
| `<flat_map>` in libc++ | shipping (LLVM 18+) |
| `boost::container::flat_map` | shipping (Boost 1.48+, header-only) |

For the tutorial demos in 2026, **`boost::container::flat_map`
is the portable choice** — it ships in `boost-headers-only` on
UBI's package channels, doesn't pull the rest of Boost, and
has the same API as the standard version. Migrating to
`std::flat_map` when libstdc++ catches up is a header change
and a namespace change.

The "vector + linear scan" alternative is *fine* for very small
N — under ~100, the constant-factor wins of a linear scan in
contiguous memory beat the O(log N) of binary search. Above ~100,
move to `flat_map`.

## The over-abstraction trap

Three abstractions that look free in the type system but cost
real bytes and cycles:

**`std::function<R(Args...)>`** — type-erased callable. Internally
holds a small-buffer-optimized storage (typically 16-32 bytes) and
a virtual function pointer for dispatch. Each call goes through
indirect call instruction. A `std::function` member adds ~48 bytes
to your class size and turns every invocation into a likely
cache miss on the captured state. For hot-path callbacks, prefer
a typed function pointer or a template parameter.

**`std::shared_ptr<T>`** — reference-counted ownership. The
shared_ptr itself is 2 pointers (16 bytes on x86-64), and the
referenced control block is another 24-32 bytes for the
refcount, weak count, and deleter. Every copy is two atomic
increments; every destruction is a possible atomic decrement
and a possible deallocation. If you don't *need* shared
ownership — and most code that uses `shared_ptr` doesn't — use
`unique_ptr` or pass-by-reference.

**`std::any`** — type-erased storage. Holds a `void*` plus a
type-info pointer plus a small-buffer-optimization region.
Every `any_cast` is a `typeid` comparison. Every modification
may reallocate. `std::any` is "I don't want to be in the type
system" — sometimes the right call (config parsers, plugin
boundaries), often not.

**Virtual dispatch in containers.** A `std::vector<Shape*>` of
polymorphic pointers loses every cache-locality advantage in
the previous section: each `Shape*` is a pointer chase to wherever
that derived object was heap-allocated, and each virtual method
call is an indirect jump through the vtable. The
[`std::variant<Circle, Square, Triangle>` alternative](https://en.cppreference.com/w/cpp/utility/variant)
keeps the data in the vector itself (one allocation), and `std::visit`
dispatches without an indirect call. Iglberger's *C++ Software Design*
chapter 4 walks through this conversion in detail; the runtime gap
is typically 3-10× on iterate-heavy workloads.

## `std::span` and `std::mdspan` — views, not copies, not pointers

C++20 `std::span<T>` is a non-owning view: a pointer + a length.
It's the right return type for "I want to read your contiguous
sequence without copying it and without taking ownership":

```cpp
// Before: function couples to vector specifically
double sum_of_squares(const std::vector<double>& xs);

// After: function works on any contiguous range
double sum_of_squares(std::span<const double> xs);

// Now callable with:
sum_of_squares(my_vector);           // vector → span conversion
sum_of_squares(my_array);            // array → span conversion
sum_of_squares({raw_ptr, length});   // raw memory → span
```

This is API hygiene as much as performance — `span` doesn't
constrain the caller's storage choice, which lets the *caller*
pick the right container without the API forcing one. Iglberger's
*C++ Software Design* chapter 9 on type erasure trade-offs
develops this further.

C++23 `std::mdspan<T, Extents>` is the same idea for
multi-dimensional layouts. A 2D image, a 3D voxel grid, a
matrix — instead of passing a `std::vector<std::vector<float>>`
(two indirections per access, terrible cache locality) you
pass a `std::mdspan<float, extents<dynamic_extent, dynamic_extent>>`
that views a single contiguous buffer. Strides are computed
at the view level; the underlying storage stays flat.

**Use `mdspan` when**:
- You're computing on a multi-dimensional array of values.
- The array is large enough that cache locality matters
  (above ~1KB).
- The API needs to be storage-agnostic (numeric library,
  reusable kernels).

**Don't use `mdspan` when**:
- A 1D `span` plus `i * cols + j` indexing is clearer.
- The "matrix" is 3×3 and lives in a single cache line anyway.

## Production diagnostic — measure cache effects

When a service's hot loop is slower than the algorithm should
predict, the data layout is suspect. Three commands to look at:

```bash
# 1. Count cache misses during a representative run
perf stat -e cache-misses,cache-references,L1-dcache-load-misses \
    ./myservice --benchmark-mode

# A "good" ratio: cache-misses / cache-references under 5%
# An L1-dcache-miss ratio under 2% on a memory-bound loop
# is typical for contiguous workloads.

# 2. Capture a flamegraph (see §10) and look for high samples
# in copy / construct / destroy operations — those are the
# allocator paying for node-based container construction.
perf record -F 99 -g -- ./myservice
perf script | stackcollapse-perf.pl | flamegraph.pl > out.svg

# 3. If you suspect a specific container, measure it in isolation
# with Google Benchmark, the way demo-02 does:
./bench --benchmark_filter='BM_Iterate_.*' --benchmark_repetitions=5
```

[§10 develops the perf + flamegraph workflow further](../10-observability-profiling/);
[§7 covers the allocator-side numbers](../07-memory-management/)
the container choice influences.

## Why this is a C++ concern

In Python, `dict` is a hash table and that's the only option
unless you reach for `collections.OrderedDict` or `numpy`. In
Java, `HashMap` and `TreeMap` are the two reach-for-it
defaults; both are node-based and the JIT papers over some of
the cache cost. In Go, `map` is a hash table; if you want
ordered iteration you sort a slice. The language
opinions are narrow, and the cache cost of those opinions is
baked in.

C++ gives you the full spectrum — hash, tree, sorted-vector,
unsorted-vector, custom layouts — and the cache cost of each
is yours to measure. **That freedom is the lever**, but it also
means the wrong choice silently costs 2.5× on iterations and
35× on tree traversals. The standard library default isn't
always the right answer; the right answer is the one that
matches your access pattern, and you have to measure to know.

The interaction with [§7's allocator stack](../07-memory-management/)
is direct: `flat_map`'s contiguous storage benefits from
`std::pmr::monotonic_buffer_resource` (bump-allocate from a
hot arena); `unordered_map`'s scattered nodes benefit much
less because the wins of arena allocation are masked by the
cache misses of pointer chasing.

## Demo

[`examples/demo-02-stl-layout/`]({{ '/examples/demo-02-stl-layout/' | relative_url }})
benchmarks all four containers at four sizes (`64`, `1024`,
`16384`, `262144`), twice: unconstrained and under
`--memory=128m`. Output is JSON consumable by `jq`; the
`scripts/test-demo-02-*.sh` validates that:

- `BM_Iterate_FlatMap` ≥ 1.5× faster than `BM_Iterate_UnorderedMap`
  at `N=262144` (cache locality at scale).
- `BM_Iterate_UnorderedMap` pressure ratio is > 1.3× more than
  `BM_Iterate_FlatMap`'s (the page-reclaim cost falls hardest
  on scattered storage).

The verified numbers above (2.5× at N=262K, 35× vs std::map)
are from this demo's instrumented run.

## For deeper coverage

- Andrist & Sehr, *C++ High Performance*, ch. 4 (containers and
  iterators), ch. 5 (algorithms with cache-awareness)
- Iglberger, *C++ Software Design*, ch. 4 (the abstraction tax),
  ch. 9 (type erasure trade-offs)
- [cppreference.com — `std::flat_map`](https://en.cppreference.com/w/cpp/container/flat_map)
  (C++23, status of library implementations)
- [Boost.Container's `flat_map`
  documentation](https://www.boost.org/doc/libs/release/doc/html/boost/container/flat_map.html)
  (the available-today version)

## What's next

[§7 keeps the workload but changes the allocator under
it](../07-memory-management/): now that the data layout is
decided, the next lever is where the memory those structures
sit on comes from. `std::pmr::monotonic_buffer_resource` and
`std::pmr::unsynchronized_pool_resource` are the two arenas
that move the number — and the cost actually lives in page
faults, not malloc.
