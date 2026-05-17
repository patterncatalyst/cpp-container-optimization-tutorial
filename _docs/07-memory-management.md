---
title: "Memory Management: Allocators, Huge Pages, cgroups v2, OOM"
order: 7
description: Where allocation cost actually lives, what PMR buys you, when transparent huge pages help, why standard allocators don't return memory to the OS, and how cgroups v2 + the OOM killer change everything above them.
duration: "10 minutes"
---

## Learning objectives

By the end of this section you can:

- Replace the default allocator with `std::pmr::monotonic_buffer_resource`
  on a request-scoped path and explain the cost model.
- Decide when to swap glibc malloc for jemalloc or mimalloc, and
  what changes in the resident set when you do.
- Apply `madvise(MADV_HUGEPAGE)` to a long-lived large allocation
  and show the TLB miss reduction.
- Set cgroup v2 `memory.max` and `memory.high` on a Podman pod
  and explain why `memory.high` is usually the better knob for
  graceful degradation.
- Read the running container's own cgroup memory file to learn
  its limit at runtime, and use that limit to drive an
  application-side check that pre-empts the OOM killer.
- Distinguish RSS, working set, and the cgroup's `memory.current`,
  and explain why a "fine" heap can still get OOM-killed.

## Diagram

{% include excalidraw.html name="07-allocator-stack" caption="Allocator stack: app → PMR → malloc → page cache → cgroups → host." %}

## Where the cost lives

Allocation cost isn't `malloc()`. It's the page fault that follows
the first write to a page glibc just handed out. Resident-set growth
is the latency signal worth watching; allocation rate is mostly a
distraction.

## PMR, and where its advantage actually lives

`std::pmr::monotonic_buffer_resource` is the high-leverage tool
in this section. The conceptual model: a fixed buffer (often
`thread_local`, often inline-allocated as a `std::array`) backs
all allocations within a scope; "freeing" inside that scope is a
no-op; the entire buffer resets when the scope ends. Allocation
becomes a pointer bump. Deallocation becomes free. The trade-off
is generality — you can't free individual objects independently
— for raw speed.

Composed with `std::pmr::unsynchronized_pool_resource` as the
upstream, you get an arena that bump-allocates small objects
from a cache-warm buffer and falls back to a slab-allocated
upstream when the buffer overflows. For request-scoped C++ code
with many short-lived allocations, this is close to ideal.

**But the advantage isn't unconditional.**

Demo-06 measures three allocator strategies — `std::allocator`,
`std::pmr` (monotonic + sync_pool), and `mimalloc` — on the same
workload, twice. The first measurement is batch mode: each
variant runs as a CLI tool that does 200 iterations of the
workload per invocation and prints percentile statistics. The
second is serve mode: each variant runs as an HTTP server, and a
load generator (`hey -z 50s -c 50`) calls a `/run` endpoint that
does ONE iteration per request. Same C++ code in the body of the
workload. Same allocator decisions. Different measurement
frames.

The verified numbers tell two completely different stories.

**Batch mode** (200 iterations per invocation, hot arena across
iterations):

| Variant | p50 µs | p99 µs | Throughput |
|---|---|---|---|
| `std::allocator` | 8.66 | 15.29 | 128,924/s |
| **`std::pmr` (mono + sync_pool)** | **4.08** | **5.61** | **239,090/s** |
| `mimalloc` | 9.77 | 17.20 | 101,821/s |

PMR is **2.12× faster than `std::allocator`** at p50 and **2.7×
tighter at p99**. Throughput nearly doubles. This is the result
that gets quoted in the PMR talks.

**Serve mode** (1 iteration per `/run` request, arena resets
between requests):

| Variant | p50 ms | p99 ms | Throughput |
|---|---|---|---|
| `std::allocator` | 0.20 | 1.7 | 29,033/s |
| `std::pmr` (mono + sync_pool) | 0.20 | 1.8 | 28,073/s |
| `mimalloc` | 0.30 | 1.9 | 27,365/s |

PMR is **indistinguishable from `std::allocator`** at p50 and
**within run-to-run variance** at p99. The 2.12× advantage from
batch mode is *invisible*.

This isn't a contradiction. It's the cache-sensitivity story
playing out exactly as the mechanism predicts.

The PMR variant uses a 1 MB `thread_local` inline buffer backing
a `monotonic_buffer_resource`. When this buffer is hot in L1/L2
cache, every `pmr::vector::push_back` is a pointer bump and a
small mark-as-used update — no syscalls, no free-list walk, no
contention. With 200 iterations per invocation, you do enough
allocations against the same arena that the entire data
structure stays cache-resident; the bump allocator wins.

In serve mode, each `/run` request does ONE iteration. Between
requests, the request scope ends and the arena's `release()` is
called — which doesn't return memory to the OS, but does reset
the bump pointer and discard cached metadata. The next request
arrives at a "warm but reset" arena that has to re-fault the
same pages and re-build the same small free lists. By the time
the data structure is hot enough for PMR's bump-allocation to
dominate, the request is done.

**The teaching point is this**: PMR is not a free win. It's a
specific trade-off — give up generality, get a cache-locality
bonus. The bonus materializes only when you do enough
allocations per arena to amortize the reset cost. If your
service handles short-lived requests with light allocation per
request, PMR will not show up in your headline numbers. If your
service does bulk batch work with sustained allocation against
the same arena, PMR can be transformative.

**The architecture-level implication is sharper**: where you
measure matters as much as what you measure. A microbenchmark
loop tells you PMR is 2× faster. A production HTTP service load
test tells you PMR doesn't help. Both measurements are correct;
both are about the same code; the difference is the measurement
frame. This is the same shape of argument we'll see in §10
(OpenTelemetry processor choice can dominate the workload it's
measuring) and §11 (default CFS scheduler defaults can dominate
your latency budget). **Performance is not a scalar, and the
right question is always "in what frame?"**

When to reach for PMR:

- Batch processing pipelines where one invocation does sustained
  allocation against a stable arena
- Inner loops of analytical workloads (parsing, indexing,
  aggregation) where the per-call cost amortizes across many
  small allocations
- Anywhere you'd otherwise consider a custom pool allocator —
  PMR is the standard-library version of that pattern

When PMR won't help:

- Request-per-call services where each request is a few hundred
  allocations against a fresh arena
- Workloads where the dominant cost is something else
  (instrumentation, network I/O, system calls)
- Code where allocation rate is already low because you've
  optimized data structures upstream

## Allocators: what changes when you swap

| Allocator    | Thread caching                      | Returns to OS quickly | Drop-in via `LD_PRELOAD` |
|--------------|-------------------------------------|-----------------------|--------------------------|
| glibc malloc | per-arena, modest                   | rarely (see below)    | n/a (default)            |
| jemalloc     | yes, configurable via `MALLOC_CONF` | yes, tunable          | yes                      |
| mimalloc     | yes, low-overhead                   | yes                   | yes                      |
| tcmalloc     | yes, page-heap based                | yes                   | yes                      |

The "returns to OS" column is the column that matters in a container.

## Why allocators hold onto memory (and why that's a container problem)

Standard `malloc` implementations don't immediately `munmap()` freed
regions. They keep them on a free list because the next allocation
is statistically likely to be the same size, and a syscall round-trip
to the kernel for every free is expensive.

On a host with plenty of RAM, this is correct. In a container with a
hard `memory.max`, it can be the difference between a healthy service
and one that gets OOM-killed even though its actual live working set
is well below the limit.

Three escape hatches, in order of preference:

1. **Use an allocator that releases more aggressively.** mimalloc and
   jemalloc both do; glibc, less so without tuning.
2. **Tune glibc.** `MALLOC_TRIM_THRESHOLD_=131072` lowers the bar for
   automatic `malloc_trim`. `MALLOC_ARENA_MAX=2` drops the per-thread
   arena count, which reduces fragmentation on many-thread services.
3. **Call `malloc_trim(0)` explicitly** at quiescent points (e.g. after
   draining a request batch). Coarse, but reliable when you know the
   shape of your workload.

## cgroups v2: `memory.max`, `memory.high`, and the difference

```text
memory.max   — hard ceiling. Going over invokes the OOM killer.
memory.high  — throttle. Kernel reclaims aggressively above this;
               your process keeps running but tail latency degrades.
memory.low   — protection floor. Won't be reclaimed if other cgroups
               can be reclaimed instead.
memory.swap.max — and equivalents for swap; usually 0 in containers.
```

For most production C++ services in containers, `memory.high` is the
knob you want. `memory.max` should sit comfortably above it as an
emergency brake, not as the ceiling you're targeting.

Reading your own limits from inside the container:

```cpp
// Works in cgroups v2; one-line files in /sys/fs/cgroup
auto read_cgroup_long(std::string_view path) -> std::optional<std::int64_t> {
    std::ifstream in{std::string{path}};
    std::int64_t v = -1;
    if (!(in >> v)) return std::nullopt;
    return v;
}
auto memory_max     = read_cgroup_long("/sys/fs/cgroup/memory.max");
auto memory_current = read_cgroup_long("/sys/fs/cgroup/memory.current");
```

(`memory.max` reads as the literal string `max` when unset; handle that.)

## RSS, working set, and `memory.current`

These are not the same number:

- **RSS** (`/proc/self/status` `VmRSS`): pages your process currently has
  resident. Does not include shared library pages used by other processes
  in your namespace.
- **`memory.current`**: total memory charged to your cgroup, including
  page cache for files your container has read. A C++ service that
  caches large files in memory can hit `memory.max` even when its heap
  is small.
- **Working set** (kubectl-style): `memory.current` minus inactive file
  cache. The number Kubernetes uses for OOM scoring.

When the OOM killer fires, it does so on `memory.current`, not on RSS.

## The LinuxMemoryChecker pattern

The C++ Presto team published a useful pattern: a periodic in-process
check that compares `memory.current` to `memory.max` and starts shedding
load (or calling `malloc_trim`) when they get close. They aim to keep
usage roughly 10% below the cgroup limit, which gives the kernel breathing
room and prevents reclaim storms from showing up as p99 spikes.

This is what [`examples/demo-02-stl-layout/`]({{ '/examples/demo-02-stl-layout/' | relative_url }})
exercises in its `random_memhigh` workload: a tight `memory.high` and
a workload that would otherwise grow past it, with and without an
in-process check.
The point isn't to copy Presto's exact code (their repo has it for
the curious); it's to see that the OOM killer becomes an
application-level concern in a container, not a "things went wrong"
concern.

References worth following:

- *Safeguarding Presto C++ memory usage with LinuxMemoryChecker* —
  the Presto blog post that introduced the pattern; concrete code,
  concrete numbers.

## Demo

Two demos exercise this section's material from different
angles.

[`examples/demo-06-memory-and-allocators/`]({{ '/examples/demo-06-memory-and-allocators/' | relative_url }})
is the canonical PMR vs. `std::allocator` vs. `mimalloc`
comparison cited above. Three Containerfile targets build the
same workload against the three allocators; a single
`./demo.sh` runs the batch-mode comparison (the 2.12× PMR win).
A separate `compose-serve.yml` brings up all three as HTTP
servers under the LGTM observability stack from §10, and a
`./bench-serve.sh` runs `hey` against each (the serve-mode
indistinguishability). Both measurement frames in one demo.

[`examples/demo-02-stl-layout/`]({{ '/examples/demo-02-stl-layout/' | relative_url }})
runs a complementary workload focused on data-structure layout,
with and without huge pages, under a tight `memory.high`. The
output is a small Grafana dashboard showing RSS,
`memory.current`, latency, and major page faults for each
combination — useful for seeing how the *layout* decisions from
§6 interact with the *allocator* decisions from §7 under
*memory pressure* from cgroup limits.

## For deeper coverage

- Andrist & Sehr, *C++ High Performance*, ch. 7 — memory
  management, custom allocators, the page-fault cost model.
- Enberg, *Latency*, ch. 4 — memory and the page cache as a
  latency layer.
- Ghosh, *Building Low Latency Applications with C++*, ch. 5–6 —
  custom memory pools and allocator design from a low-latency
  trading perspective; the patterns generalize beyond HFT.
- The cgroups v2 admin guide
  ([kernel.org docs](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html))
  for the full memory controller surface area; everything above is
  a tour of the bits that bite C++ services.

## What's next

[§8 leaves memory and goes to the network](../08-io-latency/):
`io_uring` and async gRPC, where the ratio of useful CPU to
syscall overhead is the fight.
