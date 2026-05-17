---
title: "Noisy Neighbor Isolation: cgroups, CPU pinning, NUMA"
order: 11
description: A noisy neighbor turns a 2 ms p99 into a 25 ms p99 with no malice and no bug. cgroup v2 `cpu.weight` recovers most of that; `cpuset.cpus` recovers all of it, then beats baseline. Real numbers from demo-05, plus the mechanism for each result.
duration: "10 minutes"
---

## Learning objectives

By the end of this section you can:

- Reproduce a four-scenario isolation comparison with two
  containerized tenants and a load generator, measuring how
  default scheduler behavior turns a healthy service into a tail-
  latency disaster when a neighbor shows up.
- Apply cgroup v2 `cpu.weight` to give one tenant relative
  priority, and explain mechanistically why it recovers most but
  not all of the lost latency.
- Pin CPUs with `--cpuset-cpus`, explain when the rigidity is
  worth it, and recognize the cache-locality bonus that makes
  pinned configurations sometimes faster than running alone.
- Run the production-diagnostic sequence — *"my service was
  fast yesterday; what changed?"* — for tail-latency problems on
  shared hosts.

## Diagram

{% include excalidraw.html name="11-isolation-cgroup-tree" caption="Two-tenant cgroup hierarchy with delegated controllers." %}

## The setup

Demo-05 runs two single-purpose containers on one host. `tenant-a`
is a tiny C++ HTTP server (the kind of latency-sensitive service
you might actually care about): one endpoint, returns `"ok"`,
configured with the same production-load httplib knobs used in
demo-06 (large keep-alive limit, ThreadPool sized above the test
concurrency — see the demo-05 README for the rationale).
`tenant-b` is a steady CPU-bound batch workload — same image
shape, also written in C++, but it does sustained integer work
in a tight loop on every available thread. Neither container is
malicious. Neither has a bug. Both are using their CPU budget
as the kernel scheduler permits.

We run `tenant-a` under a load generator (`hey -n 5000 -c 25
http://127.0.0.1:8501/`) and measure its p50, p95, and p99
latency in four scenarios:

1. **baseline** — `tenant-a` runs alone
2. **unisolated** — both containers run with no resource hints
3. **weighted** — `tenant-b` runs with `cpu.weight=10`
   (against `tenant-a`'s default `cpu.weight=100`)
4. **pinned** — `cpuset.cpus` splits the host's CPUs in half;
   `tenant-a` gets the lower half, `tenant-b` the upper

On the 22-CPU host the verified numbers landed at:

| Scenario | p50 ms | p95 ms | p99 ms | p99 vs baseline |
|---|---|---|---|---|
| baseline | 0.40 | 1.50 | 2.30 | 1.0× |
| unisolated | 1.80 | 10.30 | 24.70 | **10.7×** |
| weighted | 1.10 | 3.90 | 9.00 | **3.9×** |
| pinned | 0.50 | 1.40 | 1.80 | **0.78×** |

Three numbers worth pausing on: **10.7×, 3.9×, 0.78×**. Default
behavior costs you 10.7× at the tail. `cpu.weight` brings it
back to 3.9× — better but still hurting. `cpuset.cpus` brings
it to 0.78× — *below* baseline. The rest of this section
explains what each mechanism actually does, why one is partial
and the others are complete, and how to pick.

## What default fairness costs you

The unisolated scenario is the dangerous one because nothing
went wrong. Both containers are running standard images. Neither
declared resource limits. The kernel's Completely Fair Scheduler
(CFS) does exactly what it advertises: it shares CPU time
between the two cgroups in proportion to their `cpu.weight`,
which defaults to 100 each. Both tenants get a roughly equal
share of every CPU.

Equal share is the wrong answer for `tenant-a`. Its workload is
spiky — a request comes in, ~200 µs of work happens, then idle
until the next request. `tenant-b`'s workload is steady — every
thread is always runnable. When CFS hands `tenant-a` a CPU,
`tenant-b` is the next-in-line process on the same runqueue.
When `tenant-a` finishes its request, that CPU goes immediately
to `tenant-b`. When `tenant-a`'s next request arrives, it has
to wait for `tenant-b` to be preempted off — which happens, but
not for a few hundred microseconds, because CFS rewards
already-running processes with a minimum runtime quantum.

That waiting is the entire cost. A 24.7 ms p99 isn't because
`tenant-a` got slow at its work; the work is still ~200 µs.
The 24 milliseconds are accumulated scheduling latency: time
spent runnable-but-not-running, waiting for a CPU that some
other tenant has temporarily.

This is the part of the lesson most worth internalizing: **on a
shared host with no isolation hints, your latency tail is set by
your neighbors' workload pattern, not by your own.** A neighbor
doing steady CPU work — backup encryption, a batch job, a
sibling service that happens to spin on a queue — will push
your p99 up by an order of magnitude with nothing you can fix in
your own code.

## `cpu.weight`: relative priority, not a hard barrier

The weighted scenario tells `tenant-b` to run with `cpu.weight=10`,
down from its default of 100. The cgroup file lives at
`/sys/fs/cgroup/.../cpu.weight`; the value is on a scale of 1
to 10000 with a default of 100. CFS allocates CPU time in
proportion to the weights of cgroups that are *actively
contending* — so when `tenant-a` and `tenant-b` are both
runnable on the same CPU, `tenant-a`'s share is `100 / (100 + 10) ≈ 91%`
and `tenant-b`'s is `9%`.

In podman 5.x this is set with `--cgroup-conf=cpu.weight=10`
(not `--cpu-weight`, which is not a podman flag despite the
intuitive name — see the demo-05 README's Caveats section for
the full G-42 gotcha capture).
The path through to the cgroup file requires the cgroup v2 `cpu`
controller to be delegated to your user slice if you're running
rootless; see §1 prerequisites for the systemd drop-in.

The result is a 3.9× tail degradation against baseline. That's
**62% of the contention damage recovered**, not 100%. The
mechanism is exactly why:

`cpu.weight` is *relative* and applies only during contention.
When `tenant-a` is briefly idle between requests, `tenant-b`
legally consumes the available CPU — it's not capped, it's just
deprioritized when both compete. When `tenant-a`'s next request
arrives, `tenant-b` has to be preempted off the CPU it's been
using. CFS does preempt it, but only at the end of the next
scheduling tick (typically 1-4 ms on most kernels), and only
after the CPU runs the cache lines for `tenant-a`'s working set
back into L1.

So `cpu.weight` doesn't eliminate the cost of context switching
between tenants — it just reduces how much CPU time `tenant-b`
gets while it's there. Tail latency depends on the *latency* of
scheduling decisions, not just their *share*. Weight tunes the
share; it doesn't tune the latency.

When is `cpu.weight` the right answer?

- When tenants share a goal and the operator is willing to trade
  some latency for elasticity (one tenant can burst into the
  other's unused share)
- When the workloads are similar enough that the cost of
  preemption is small relative to the work being preempted
- For most "general production" workloads where 4× tail
  degradation is acceptable and full pinning would be wasteful

When isn't it?

- When latency budgets are hard
- When the noisy neighbor is fundamentally different in workload
  shape (CPU-bound batch + latency-sensitive RPC is the classic
  bad combination, and is exactly what we measured)

## `cpuset.cpus`: physical isolation, with a cache bonus

The pinned scenario splits the host's CPUs into disjoint sets.
With a 22-CPU host, `tenant-a` gets CPUs 0-10, `tenant-b` gets
CPUs 11-21. Set via podman's `--cpuset-cpus="0-10"`, which writes
to `/sys/fs/cgroup/.../cpuset.cpus`. The kernel scheduler can no
longer place `tenant-b`'s threads on CPUs 0-10 at all. There is
no contention. There are no scheduling decisions to make.

p99 lands at 1.80 ms — **below baseline's 2.30 ms**. That's not a
measurement artifact. It's a real effect with a physical cause.

In the baseline scenario, `tenant-a` runs alone, but the CFS is
still free to migrate its threads across any of the 22 CPUs.
Each migration costs a cold-cache penalty: the new CPU's L1 and
L2 caches don't have the working set yet, and the first few
thousand cycles after migration are spent re-faulting cache
lines from L3 or DRAM. On a tight latency budget that 1-3 µs
adds up, especially when it lands on the request that already
got unlucky with everything else.

In the pinned scenario, `tenant-a`'s threads can only run on
its 11 CPUs. The kernel still migrates within that set, but the
working set warms across those 11 caches and stays warm. Cache
line reuse is much higher; cold-cache stalls are much rarer.

This is the same mechanism that drives high-frequency trading
firms, market-making systems, and other ultra-low-latency
applications to pin threads even when they have entire hosts to
themselves. **Pinning is not just an anti-contention tool. It's
a cache-locality tool that happens to also eliminate contention.**

The cost of `cpuset.cpus` is rigidity. When `tenant-a` is idle,
its 11 CPUs sit idle too; `tenant-b` cannot use them even though
nothing else is running. On a steady workload this is the right
trade: predictable utilization, predictable latency. On a bursty
or batch workload it's wasteful. Pick based on the actual usage
pattern, not based on intuitions about modern infrastructure.

### NUMA, briefly

Larger hosts have multiple NUMA nodes — typically one per socket
on a multi-socket server. Memory accesses to the local node are
faster than to remote nodes (typically 30-100% latency
difference). The pinning above only pinned CPUs; on a NUMA host
you also want to pin memory.

`numactl --cpunodebind=0 --membind=0` runs a process with CPU
and memory both bound to NUMA node 0. The podman equivalents
are `--cpuset-cpus` (for the CPU half) and `--cpuset-mems` (for
the memory half). On the verified 22-CPU host shown above,
`/sys/devices/system/node` reported a single node, so the NUMA
half of the pinning wasn't exercised; the cache-locality result
came from CPU pinning alone. On a multi-socket host the result
would be more dramatic because the memory penalty for cross-
node access compounds with the cache-line penalty for thread
migration.

## Pick your primitive

The four scenarios map onto a small decision tree:

| Workload shape | What's appropriate | Why |
|---|---|---|
| Single tenant, batch | No isolation | The default is correct |
| Multiple tenants, similar workloads, latency tolerant | `cpu.weight` priority | Trade some tail for elasticity |
| Mixed batch + latency-sensitive | `cpu.weight` or `cpuset.cpus` depending on budget | Weight if 4× is OK; pin if not |
| Hard latency budgets (HFT, real-time) | `cpuset.cpus` + `numactl` if NUMA | Predictable scheduling, warm caches |
| Single tenant, latency-sensitive, host to yourself | `cpuset.cpus` anyway | Cache locality from non-migration |

The last row is the surprising one to most people: pinning helps
even with no neighbor. The 0.78× pinned-vs-baseline ratio on our
verified data is the empirical evidence.

## Production diagnostic

If you're seeing tail-latency problems on a shared host and your
own service profiles fast in isolation, run this diagnostic
sequence:

1. **Are you on shared CPUs?**
   ```bash
   cat /sys/fs/cgroup/$(cat /proc/self/cgroup | cut -d: -f3)/cpuset.cpus.effective
   ```
   If this lists the same CPUs as your neighbor's cgroup,
   you're contending.

2. **What's your `cpu.weight`, and what is your neighbor's?**
   ```bash
   cat /sys/fs/cgroup/$(cat /proc/self/cgroup | cut -d: -f3)/cpu.weight
   ```
   If yours is 100 and a heavy neighbor's is 100, default
   fairness is your enemy.

3. **Are you migrating between cores under load?**
   ```bash
   sudo perf stat -e migrations -p <pid> sleep 10
   ```
   A high migration count plus a healthy per-thread CPU profile
   plus a poor latency tail is the classic "needs pinning"
   signature.

4. **For NUMA hosts, are you cross-node?**
   ```bash
   numastat -p <pid>
   ```
   `other_node` numbers higher than ~10% of `local_node` mean
   memory traffic is crossing the interconnect; bind it.

The fix follows directly from the diagnosis. Shared CPUs with
equal weights → pick `cpu.weight` or `cpuset.cpus`. High
migrations → pin. Cross-node memory → bind with `--cpuset-mems`
or `numactl --membind`.

## Why this is a C++ concern

cgroups, CFS, and cpusets are Linux mechanisms; the lesson is
the same for a Python or Go service. But the *consequence* is
particularly sharp for C++ for two reasons.

First, C++ services are often the ones with hard latency
budgets — the trading systems, the search front-ends, the
high-throughput RPCs whose p99 actually matters at five-digit
QPS. Languages with garbage collection have larger and more
variable baseline tails that drown the scheduler effects.

Second, the cache-locality bonus from pinning compounds with
the cache-locality work you do in C++ specifically: the
struct-of-arrays layouts from §6, the PMR arena reuse from §7,
the careful working-set sizing. Those gains depend on the cache
staying warm between accesses. A scheduler that migrates your
threads off the cache that knows your data costs you the C++
optimizations you already paid for. Pinning preserves them.

## Demo

The four-row table above came from
[`examples/demo-05-isolation/`]({{ '/examples/demo-05-isolation/' | relative_url }}),
which builds `tenant-a` and `tenant-b` from a single multi-stage
Containerfile, then runs all four scenarios end-to-end with one
`./demo.sh`. The Grafana dashboards from §10 are the pretty
version of the same numbers, with the histograms instead of
percentile points.

Some configurations require the cgroup v2 `cpu` and `cpuset`
controllers to be delegated to your user's systemd slice (see
§1 prerequisites and `scripts/cgroup-delegation.sh`). On a fresh
Fedora 44 install only `memory` and `pids` are delegated by
default, which means the weighted and pinned scenarios silently
skip with a clear message in the demo summary. Enable
delegation once, re-login, and all four scenarios run.

## For deeper coverage

- Enberg, *Latency*, ch. 5-6 (CPU scheduling and isolation under
  contention; the queueing-theory framing for the numbers above)
- Ghosh, *Building Low Latency Applications with C++*, ch. 7 —
  CPU pinning, NUMA placement, and busy-spin vs blocking-wait
  trade-offs from a low-latency trading angle. The container
  framing is ours; the underlying patterns are his.
- Andrist & Sehr, *C++ High Performance*, ch. 14 — the
  concurrency story, complementary to the scheduling-and-
  isolation story above
- [cgroups v2 admin guide](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html)
  for the full surface area of the `cpu` and `cpuset`
  controllers and the unified hierarchy semantics

## What's next

§12 zooms back in to a single binary: how do you debug it
inside a container, how do you reason about its quality before
it ships, and what does the analysis pipeline look like when
the build is hermetic and the runtime is ephemeral.
