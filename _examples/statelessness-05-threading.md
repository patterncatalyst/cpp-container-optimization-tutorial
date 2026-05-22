---
title: "Statelessness 05 — Threading & CPU budget"
description: "The runnable companion to compendium Doc 05: hardware_concurrency() lies under a cgroup CPU quota. A cgroup-aware probe and a pool-size sweep under --cpus=2 show that oversubscription buys no throughput and wrecks tail latency through CFS throttling."
order: 205
card_eyebrow: "Compendium · <strong>Doc 05</strong>"
card_title: "Threading &amp; CPU budget"
card_blurb: "hardware_concurrency() lies under a cgroup quota. A cgroup-aware probe and a pool-size sweep under --cpus=2 show oversubscription buys no throughput and wrecks tail latency via CFS throttling."
layout: example
sectionid: examples
permalink: /examples/statelessness-05-threading/
demo_dir: statelessness/05-threading
github_path: examples/statelessness/05-threading
---

> The full source for this example lives in [`examples/statelessness/05-threading/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/statelessness/05-threading) — clone the repo, `cd` in, and `./demo.sh`.

Compendium reference:
[Doc 05 — Threading under container limits]({{ '/reference/statelessness/05-threading/' | relative_url }})

Tutorial sections:
[§11 Noisy Neighbor Isolation]({{ '/docs/11-noisy-neighbors/' | relative_url }}) +
[§8 I/O Latency: io_uring, Async gRPC]({{ '/docs/08-io-latency/' | relative_url }})

The one-line takeaway: **`std::thread::hardware_concurrency()` lies under a
cgroup CPU limit** — it reports the host's core count, not your container's
quota. Size a pool from it on a quota-limited container and you oversubscribe
the CPU: more threads fighting over the same fixed slice of CFS quota, with
throttling pauses spread across more threads — worse tail latency, no extra
throughput. This is the first compendium example with **no gRPC and no
Conan** — two small standard-library binaries that build in seconds.

## Why this matters

The number of threads a service should run is one of the few performance
knobs that is *easy to get wrong by default* under containers, because the
obvious source of truth is the wrong one:

- **The default is the host, not your budget.** A pool sized to
  `hardware_concurrency()` on a 64-core host that the orchestrator has
  capped at `--cpus=2` spins up 64 worker threads against a 2-core quota.
  They don't run faster; they take turns, and the turn-taking is enforced by
  the kernel in a way that hurts.
- **CFS throttling is a tail-latency event, not a throughput one.** When the
  cgroup exhausts its CPU quota mid-period, the scheduler throttles *every*
  thread in the cgroup until the next period boundary — up to ~100 ms with
  the default period. Average throughput barely moves; p99 and max latency
  spike. Tail latency is the SLO that breaks first.
- **It's the same lie everywhere.** The host-probe default isn't unique to
  your thread pool — gRPC's sync server, glibc/jemalloc malloc arenas,
  OpenMP, TBB, and the C++ parallel algorithms all size themselves from the
  host by default. Get the cgroup reading right once and you can fix all of
  them.

## What this demo shows

**`cpu-probe`** reads the truth from `/sys/fs/cgroup/cpu.max` (cgroup v2,
with a v1 fallback) and prints it next to `hardware_concurrency()` and the
pool size you should actually use. Inside `--cpus=2`, the host probe is
unchanged but the cgroup quota — and the recommendation — drops to 2.

**`pool-bench`** runs a fixed CPU-bound workload across a pool of a given
size and reports throughput and per-task latency percentiles. The demo runs
it at pool sizes 1, 2 (the quota), 4, and 8, all under `--cpus=2`.
Throughput stops improving past the quota; p99 and max climb as the pool
oversubscribes, because hitting the quota mid-period throttles every thread
until the next period boundary. A pool sized to the cgroup gives the same
throughput with far tighter tails.

## How to run

```bash
cd examples/statelessness/05-threading
./demo.sh            # cpu-probe + the pool-size sweep under --cpus=2
./demo.sh --clean    # remove the image
```

No Conan, no gRPC — two standard-library binaries that build in seconds.

CI verification: `scripts/test-stateless-demo-05-threading.sh`.

Rootless `--cpus` only enforces a real CFS quota if the cgroup v2 `cpu`
controller is delegated to your user slice; the demo detects this and points
you at `scripts/cgroup-delegation.sh enable` if it's missing (the same
delegation the isolation demo uses).

## What you'll see

Representative output on a Fedora 44 host (22 logical cores) with
gcc-toolset-14 and Podman 5.x, running the container under `--cpus=2`:

```
==> cpu-probe   (inside --cpus=2)
    hardware_concurrency() : 22          <- the host's cores, the lie
    cgroup cpu.max         : 200000 100000  (= 2.0 cores)
    recommended pool size  : 2           <- size to THIS, not 22

==> pool-bench sweep   (fixed CPU-bound workload, under --cpus=2)
    pool=1   throughput=  9,820 tasks/s   p99=0.12 ms   max= 0.4 ms
    pool=2   throughput= 19,440 tasks/s   p99=0.13 ms   max= 0.6 ms   <- matches the quota
    pool=4   throughput= 19,110 tasks/s   p99=4.8  ms   max=38   ms
    pool=8   throughput= 18,700 tasks/s   p99=22   ms   max=104  ms
```

## How to read the output

- **The two numbers in `cpu-probe` disagree, and the cgroup one wins.**
  `hardware_concurrency()` reports 22; the cgroup quota is 2. A pool sized to
  22 is an 11× oversubscription against the real budget.
- **Throughput plateaus at the quota (pool=2).** Going from 1 to 2 threads
  roughly doubles throughput — you're using both cores in your budget. Going
  from 2 to 4 to 8 buys *nothing*: there are still only 2 cores' worth of
  quota to spend.
- **p99 and max explode past the quota.** That's the whole lesson. At pool=8,
  max latency hits ~104 ms — almost exactly the default CFS period — because
  a task can be throttled for a full period when the cgroup runs out of quota
  mid-window. The mean barely moved; the tail fell off a cliff.
- **If the tails *don't* climb past pool=2**, your `--cpus` isn't being
  enforced — see the delegation caveat below. Muted throttling means the
  cgroup `cpu` controller isn't delegated to your rootless user slice.

## Files

- `src/cgroup_cpu.hpp` — reads `cpu.max` (v2) / `cfs_quota_us` (v1) and
  recommends a pool size from the quota
- `src/cpu_probe.cpp` — prints `hardware_concurrency()` next to the cgroup
  quota and the recommendation
- `src/pool_bench.cpp` — a CPU-bound workload across a sized pool, with
  latency percentiles
- `CMakeLists.txt` — two binaries; no external dependencies
- `Containerfile` — UBI 9 (gcc-toolset-14 + cmake) → `ubi-minimal`; no
  Conan, no gRPC
- `demo.sh` — the driver (`podman run --cpus`, like the isolation demo)

## Caveats and gotchas

- **Rootless `--cpus` needs cgroup delegation to bite.** `--cpus` only
  enforces a real CFS quota rootless if the cgroup v2 `cpu` controller is
  delegated to your user slice. Without it, the flag is accepted but not
  enforced and the throttling effect is muted — the tails won't climb. Enable
  it with `scripts/cgroup-delegation.sh enable`, then re-login. This is the
  same delegation the [isolation example]({{ '/examples/statelessness-05-threading/' | relative_url }})
  in the main track relies on.
- **The throttle window is the CFS period (~100 ms).** The max-latency
  number tracks the default `cpu.cfs_period_us`. Shortening the period
  reduces individual stalls but raises scheduling overhead; it's rarely the
  right fix — sizing the pool is.
- **The bench is CPU-bound on purpose.** For an I/O-bound handler the math is
  different: threads blocked on I/O don't consume quota, so a larger pool can
  help. The lesson is "size from the cgroup," not "always use exactly the
  core count" — match the pool to the workload *and* the budget.
- **The same lie reaches pools you didn't write.** See "Beyond your own
  pools" below; sizing your own pool correctly is necessary but not
  sufficient.

## Source materials

This example deepens material from the project's
[**bibliography**]({{ '/bibliography/' | relative_url }}):

- **Andrist & Sehr, *C++ High Performance* 2e, ch. 11** — concurrency and
  parallelism in C++; thread pools, oversubscription, and the cost model
  behind the sweep
- **Enberg, *Latency*, ch. 3** — scheduling and the tail; why throttling
  shows up as p99/max spikes rather than lower mean throughput
- **Iglberger, *C++ Software Design*, ch. 2** — the case for owning the pool
  in the composition root and injecting it, rather than reaching for a global
  thread pool sized at static-init time

## Linked tutorial sections

- [**§11 Noisy Neighbor Isolation**]({{ '/docs/11-noisy-neighbors/' | relative_url }}) —
  cgroups, CPU pinning, NUMA, and CFS quota enforcement; this example is the
  thread-pool-sizing half of that section, and the isolation demo there shows
  the multi-tenant version of the same throttling.
- [**§8 I/O Latency: io_uring, Async gRPC**]({{ '/docs/08-io-latency/' | relative_url }}) —
  where the I/O-bound side of pool sizing lives: async gRPC and io_uring let
  a small pool serve many concurrent requests without one-thread-per-request
  oversubscription.

## Beyond your own pools

The same lie reaches pools you didn't write — gRPC's sync server
(`ResourceQuota::SetMaxThreads`), glibc malloc arenas (`MALLOC_ARENA_MAX`,
whose default is `8 × NPROCS` from the host probe — catastrophic on a big
host with a small quota), jemalloc (`MALLOC_CONF=narenas:…`, or
`narenas:auto` on recent versions which reads the cgroup), OpenMP, TBB, and
the C++ parallel algorithms all probe the host by default. Size them from the
cgroup, as the compendium
[threading reference]({{ '/reference/statelessness/05-threading/' | relative_url }})
details.

## Where it sits in the compendium

The `unsynchronized` choice in the
[PMR arena]({{ '/examples/statelessness-03-pmr/' | relative_url }}) is
justified by the threading model here — one thread per request arena. The
cgroup-aware pool sizing this example demonstrates is exactly what
[process-scoped state]({{ '/reference/statelessness/04-process-scoped-state/' | relative_url }})
uses to size its pools, and what the capstone
([Doc 10]({{ '/reference/statelessness/10-grpc-microservices/' | relative_url }}))
applies when it sizes the gRPC server's thread pool from the CPU budget.
