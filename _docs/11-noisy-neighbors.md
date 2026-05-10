---
title: "Noisy Neighbor Isolation: cgroups, CPU pinning, NUMA"
order: 11
description: Two tenants, one host, the noisy one is yours. cgroup v2 `cpu.weight`, `io.weight`, `--cpuset-cpus`, and `numactl` are the levers; this section runs them.
duration: 12 minutes
---

## Learning objectives

By the end of this section you can:

- Set up a two-tenant Podman compose where one tenant
  deliberately misbehaves, and show how p99 latency on the other
  tenant degrades without isolation.
- Apply cgroup v2 `cpu.weight` and `io.weight` to give one
  tenant priority and show the latency recovery.
- Pin CPUs with `--cpuset-cpus` and explain when that's better
  than weights.
- Use `numactl --membind` and `--cpunodebind` on a NUMA host to
  keep memory allocations and CPU affinities on the same node.

## Diagram

{% include excalidraw.html name="10-isolation-cgroup-tree" caption="cgroup hierarchy: two tenants and a load generator under a parent slice" %}

## Planned content

- The setup: tenant A is a latency-sensitive C++ service from
  §7; tenant B is a CPU-greedy batch workload (a deliberately
  unbounded `for` loop with `madvise(MADV_RANDOM)` to thrash the
  page cache).
- Round 1: no isolation. Tenant A's p99 doubles. The metrics
  from §9 make it visible.
- Round 2: `cpu.weight` (default 100; raise A to 1000, lower B to
  10). What happens, and why "weight" is not "limit."
- Round 3: `--cpuset-cpus` to pin tenant A to a dedicated set.
- Round 4 (NUMA-only): bind A's memory and CPUs to one node, B's
  to the other. Best when the host has one.
- Closing: when each lever is the right one, and the cost (and
  the rare time you regret pinning).

## Demo

[`examples/demo-05-isolation/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/demo-05-isolation)
walks through the four rounds and prints a small comparison
table. The Grafana dashboards from §9 are the pretty version of
the same data.

## For deeper coverage

- Enberg, *Latency*, ch. 5-6 (CPU scheduling and isolation under
  contention)
- Ghosh, *Building Low Latency Applications with C++*, ch. 7 —
  CPU pinning, NUMA placement, and busy-spin vs blocking-wait
  trade-offs from a low-latency trading angle. The container
  framing is ours; the underlying patterns are his.

## What's next

§11 zooms back in to a single binary: how do you debug it inside
a container, and how do you know it's any good before it ships?
