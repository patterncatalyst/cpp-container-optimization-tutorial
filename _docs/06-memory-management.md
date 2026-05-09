---
title: "Memory Management: Allocators, Huge Pages, cgroups v2"
order: 6
description: Where allocation cost actually lives, what PMR buys you, when transparent huge pages help, and how cgroups v2 `memory.high` changes everything above it.
duration: 12 minutes
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

## Diagram

{% include excalidraw.html name="06-allocator-stack" caption="The allocator stack: app → PMR resource → upstream → cgroup memory.high" %}

## Planned content

- Where allocation cost actually lives: not in `malloc()` but in
  the page faults that follow it. Resident-set growth as a
  latency signal.
- C++17 PMR (polymorphic memory resources) and C++20 additions:
  `monotonic_buffer_resource` for request-scoped arenas,
  `unsynchronized_pool_resource` for fixed-size object pools,
  composing them with upstream resources.
- jemalloc vs mimalloc vs glibc malloc: thread caching,
  fragmentation behaviour, ease of swapping in via
  `LD_PRELOAD`.
- Transparent huge pages: when they help (long-lived, large
  contiguous regions), when they hurt (short-lived, fork-heavy,
  high allocation churn).
- cgroups v2 memory: the difference between `memory.max` (hard
  ceiling, OOM killer fires) and `memory.high` (throttle, kernel
  reclaims). How to discover what you have:
  `cat /sys/fs/cgroup/$(cat /proc/self/cgroup | cut -d: -f3)/memory.max`.

## Demo

[`examples/demo-02-memory-and-stl/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/demo-02-memory-and-stl)
runs the same workload with default allocator, a PMR monotonic
arena, and mimalloc; with and without huge pages; under a tight
`memory.high`. The output is a small Grafana dashboard showing
RSS, latency, and major page faults for each combination.

## For deeper coverage

- Andrist & Sehr, *C++ High Performance*, ch. 7 (memory
  management, custom allocators)
- Enberg, *Latency*, ch. 4 (memory and the page cache)

## What's next

§7 leaves memory and goes to the network: `io_uring` and async
gRPC.
