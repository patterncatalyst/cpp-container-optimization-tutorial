---
title: Outline
order: 0
description: The reader's map. What's ahead, in what order, and how to use this tutorial in either 90 minutes or 3 hours.
duration: 2 minutes
---

## What this tutorial is

Performance tuning for modern C++ services running in OCI
containers, on a Linux host. Every claim is paired with a runnable
demo so you can reproduce it on your own laptop.

## Two ways to use it

- **The 90-minute path.** Read every section in order; skip
  running demos 3, 4, and 5 (long compose stacks); rely on the
  pre-recorded screenshots in those sections. Best for a first
  pass to get the shape of things.
- **The 3-hour path.** Read every section in order; run every
  demo. Best when you have a Fedora 44 host in front of you and
  want to feel each tuning knob in your hands.

Either path covers the same material. Demos compress to "show me
the result"; you can always come back later and run them.

## The sections

| §  | Title                                                              | Duration |
|----|--------------------------------------------------------------------|----------|
| 0  | Outline (this page)                                                | 2 min    |
| 1  | [Prerequisites](../01-prerequisites/)                              | 10 min   |
| 2  | [Introduction & Mental Model](../02-introduction/)                 | 8 min    |
| 3  | [Container Strategy: UBI, scratch, multi-stage](../03-image-strategy/) | 12 min   |
| 4  | [Compile-Time Wins: LTO, PGO, constexpr](../04-compile-time-wins/)  | 12 min   |
| 5  | [STL, Layout, and C++20/23 Containers](../05-stl-layout/)           | 15 min   |
| 6  | [Memory Management](../06-memory-management/)                       | 12 min   |
| 7  | [I/O Latency](../07-io-latency/)                                    | 15 min   |
| 8  | [Networking & Kernel Parameters](../08-networking-kernel/)          | 10 min   |
| 9  | [Observability & Profiling](../09-observability-profiling/)         | 15 min   |
| 10 | [Noisy Neighbor Isolation](../10-noisy-neighbors/)                  | 12 min   |
| 11 | [Static Analysis & Debugging](../11-analysis-debugging/)            | 12 min   |
| 12 | [Reproducibility & ABI](../12-reproducibility-abi/)                 | 12 min   |
| 13 | [Pitfalls](../13-pitfalls/)                                         | 10 min   |
| 14 | [Where to Go Next](../14-where-to-go-next/)                         | 3 min    |

**Total:** ~2 hours 40 minutes with demos.

## What's not covered

C++ language fundamentals; Podman / OCI fundamentals; Docker /
vcpkg / Bazel comparisons; Kubernetes; Windows hosts. See
[`PRD.md`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/blob/main/PRD.md) §3 for the
full non-goals list.

## Reference materials

The tutorial points at, but does not summarize, three reference
books. Each section's "for deeper coverage" pointer names the
relevant chapter:

- Andrist & Sehr, *C++ High Performance, 2nd Edition*
- Iglberger, *C++ Software Design*
- Enberg, *Latency: Reduce delay in software systems*
