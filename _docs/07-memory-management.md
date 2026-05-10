---
title: "Memory Management: Allocators, Huge Pages, cgroups v2, OOM"
order: 7
description: Where allocation cost actually lives, what PMR buys you, when transparent huge pages help, why standard allocators don't return memory to the OS, and how cgroups v2 + the OOM killer change everything above them.
duration: 15 minutes
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

{% include excalidraw.html name="07-allocator-stack" caption="The allocator stack: app → PMR resource → glibc malloc / jemalloc / mimalloc → page cache → cgroup memory.high → cgroup memory.max → host" %}

## Planned content

### Where the cost lives

Allocation cost isn't `malloc()`. It's the page fault that follows
the first write to a page glibc just handed out. Resident-set growth
is the latency signal worth watching; allocation rate is mostly a
distraction.

### C++17/20 PMR, briefly

`std::pmr::monotonic_buffer_resource` for request-scoped arenas,
`unsynchronized_pool_resource` for fixed-size object pools, and how
to compose them with upstream resources. PMR doesn't replace your
allocator; it lets you switch allocator on a per-call-site basis,
which is the point.

### Allocators: what changes when you swap

| Allocator    | Thread caching                      | Returns to OS quickly | Drop-in via `LD_PRELOAD` |
|--------------|-------------------------------------|-----------------------|--------------------------|
| glibc malloc | per-arena, modest                   | rarely (see below)    | n/a (default)            |
| jemalloc     | yes, configurable via `MALLOC_CONF` | yes, tunable          | yes                      |
| mimalloc     | yes, low-overhead                   | yes                   | yes                      |
| tcmalloc     | yes, page-heap based                | yes                   | yes                      |

The "returns to OS" column is the column that matters in a container.

### Why allocators hold onto memory (and why that's a container problem)

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

### cgroups v2: `memory.max`, `memory.high`, and the difference

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

### RSS, working set, and `memory.current`

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

### The LinuxMemoryChecker pattern

The C++ Presto team published a useful pattern: a periodic in-process
check that compares `memory.current` to `memory.max` and starts shedding
load (or calling `malloc_trim`) when they get close. They aim to keep
usage roughly 10% below the cgroup limit, which gives the kernel breathing
room and prevents reclaim storms from showing up as p99 spikes.

This is what `examples/demo-02-memory-and-stl/` exercises in its
`random_memhigh` workload: a tight `memory.high` and a workload that
would otherwise grow past it, with and without an in-process check.
The point isn't to copy Presto's exact code (their repo has it for
the curious); it's to see that the OOM killer becomes an
application-level concern in a container, not a "things went wrong"
concern.

References worth following:

- *Safeguarding Presto C++ memory usage with LinuxMemoryChecker* —
  the Presto blog post that introduced the pattern; concrete code,
  concrete numbers.

## Demo

[`examples/demo-02-memory-and-stl/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/demo-02-memory-and-stl)
runs the same workload with default allocator, a PMR monotonic
arena, and mimalloc; with and without huge pages; under a tight
`memory.high`. The output is a small Grafana dashboard showing
RSS, `memory.current`, latency, and major page faults for each
combination.

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

§7 leaves memory and goes to the network: `io_uring` and async
gRPC, where the ratio of useful CPU to syscall overhead is the
fight.
