# statelessness/05-threading — sizing the pool to the cgroup, not the host

Compendium reference:
[Doc 05 — Threading under container limits](../../../reference/statelessness/05-threading/)

The runnable companion to compendium Doc 05. The one-line takeaway:
**`std::thread::hardware_concurrency()` lies under a cgroup CPU limit** —
it reports the host machine's core count, not your container's quota.
Size a thread pool (or an allocator's arena count, or gRPC's internal
pool) from that number on a quota-limited container and you
oversubscribe the CPU: more threads fighting over the same fixed slice
of CFS quota, more context switches, and throttling pauses spread across
more threads — worse tail latency, and *no* extra throughput.

This is the first compendium example with **no gRPC and no Conan** — two
small standard-library binaries, so it builds in seconds.

## What it demonstrates

**`cpu-probe`** ([`src/cpu_probe.cpp`](src/cpu_probe.cpp),
[`src/cgroup_cpu.hpp`](src/cgroup_cpu.hpp)) reads the truth from
`/sys/fs/cgroup/cpu.max` (cgroup v2, with a v1 fallback) and prints it
next to `hardware_concurrency()` and the pool size you should actually
use. Run inside `--cpus=2`, the host probe is unchanged but the cgroup
quota — and the recommendation — drops to 2.

**`pool-bench`** ([`src/pool_bench.cpp`](src/pool_bench.cpp)) runs a
fixed CPU-bound workload across a pool of a given size and reports
throughput and the per-task latency distribution. The demo runs it at
pool sizes 1, 2 (the quota), 4, and 8 — all under `--cpus=2` — so you
can read the effect straight off the table:

```
pool=1  throughput=…  p99=…    max=…
pool=2  throughput=…  p99=…    max=…    <- matches the --cpus=2 quota
pool=4  throughput=≈   p99=↑    max=↑
pool=8  throughput=≈   p99=↑↑   max=↑↑
```

Throughput stops improving past the quota (the quota is a fixed
CPU-time budget per period regardless of thread count), while p99 and
max latency climb sharply as the pool oversubscribes — when the
container hits its quota mid-period, the kernel throttles every thread
until the next period boundary (up to ~100 ms with the default period).

Even on an unconstrained host this shows up if the machine has fewer
real cores than the largest pool: the single-core case is the same
phenomenon in miniature.

## Running it

```bash
./demo.sh            # build + cpu-probe + the pool-size sweep
./demo.sh --clean    # remove the image
```

CI verification: `../../../scripts/test-stateless-demo-05-threading.sh`.

### Rootless CFS-quota enforcement

`--cpus` only enforces a real CFS quota rootless if the cgroup v2 `cpu`
controller is delegated to your user slice. The demo detects this and
warns if it's missing; without it, `--cpus` is accepted but not
enforced, so the throttling effect is muted. Enable delegation with the
repo helper, then re-login:

```bash
../../../scripts/cgroup-delegation.sh enable
```

This is the same delegation that demo-05 (isolation) relies on.

## Layout

```
05-threading/
├── src/cgroup_cpu.hpp   reads cpu.max (v2) / cfs_quota_us (v1); recommends pool size
├── src/cpu_probe.cpp    prints hardware_concurrency() vs the cgroup quota
├── src/pool_bench.cpp   CPU-bound workload across a sized pool; latency percentiles
├── CMakeLists.txt       two binaries; no external deps
├── Containerfile        UBI 9 (gcc-toolset-14 + cmake) → ubi-minimal; no Conan/gRPC
└── demo.sh              the driver (podman run --cpus, like demo-05)
```

## Beyond your own pools

The same lie reaches pools you didn't write. Size them from the cgroup
too:

- **gRPC sync server** — `grpc::ResourceQuota{}.SetMaxThreads(n)` on the
  `ServerBuilder` (Doc 05 has the snippet).
- **glibc malloc arenas** — `MALLOC_ARENA_MAX=4`; the default is
  `8 × NPROCS` from the host probe, catastrophic on a big host with a
  small quota.
- **jemalloc** — `MALLOC_CONF=narenas:N` (or `narenas:auto` on recent
  versions, which reads the cgroup).
- **OpenMP / TBB / std parallel algorithms** — all probe the host by
  default.
