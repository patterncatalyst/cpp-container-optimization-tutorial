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

The one-line takeaway: **`std::thread::hardware_concurrency()` lies
under a cgroup CPU limit** — it reports the host's core count, not your
container's quota. Size a pool from it on a quota-limited container and
you oversubscribe the CPU: more threads fighting over the same fixed
slice of CFS quota, throttling pauses spread across more threads — worse
tail latency, no extra throughput.

This is the first compendium example with **no gRPC and no Conan** — two
small standard-library binaries that build in seconds.

## What it demonstrates

**`cpu-probe`** reads the truth from `/sys/fs/cgroup/cpu.max` (cgroup
v2, with a v1 fallback) and prints it next to `hardware_concurrency()`
and the pool size you should use. Inside `--cpus=2`, the host probe is
unchanged but the cgroup quota — and the recommendation — drops to 2.

**`pool-bench`** runs a fixed CPU-bound workload across a pool of a given
size and reports throughput and per-task latency percentiles. The demo
runs it at pool sizes 1, 2 (the quota), 4, and 8, all under `--cpus=2`:

```
pool=1  throughput=…  p99=…    max=…
pool=2  throughput=…  p99=…    max=…    <- matches the --cpus=2 quota
pool=4  throughput=≈   p99=↑    max=↑
pool=8  throughput=≈   p99=↑↑   max=↑↑
```

Throughput stops improving past the quota; p99 and max climb as the
pool oversubscribes, because hitting the quota mid-period throttles
every thread until the next period boundary (up to ~100 ms with the
default period). A pool sized to the cgroup gives the same throughput
with far tighter tails.

## Running it

```bash
cd examples/statelessness/05-threading
./demo.sh            # cpu-probe + the pool-size sweep under --cpus=2
./demo.sh --clean    # remove the image
```

CI verification: `scripts/test-stateless-demo-05-threading.sh`.

Rootless `--cpus` only enforces a real CFS quota if the cgroup v2 `cpu`
controller is delegated to your user slice; the demo detects this and
points you at `scripts/cgroup-delegation.sh enable` if it's missing
(the same delegation demo-05 uses).

## Beyond your own pools

The same lie reaches pools you didn't write — gRPC's sync server
(`ResourceQuota::SetMaxThreads`), glibc malloc arenas
(`MALLOC_ARENA_MAX`), jemalloc (`MALLOC_CONF=narenas:…`), OpenMP, TBB,
and the C++ parallel algorithms all probe the host by default. Size
them from the cgroup, as
[Doc 05]({{ '/reference/statelessness/05-threading/' | relative_url }})
details.
