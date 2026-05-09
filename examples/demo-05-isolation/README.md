# Demo 5 — Noisy neighbor isolation

Tutorial section: §10 (Noisy neighbors and isolation)

## What this demo shows

Two services running side-by-side on the same host, with a load generator
hammering one of them:

- **`tenant-a`** — the "good citizen": handles HTTP traffic, exposes
  latency metrics
- **`tenant-b`** — the "noisy neighbor": runs CPU- and memory-bound
  background work in a tight loop, no rate limiting

The demo runs four scenarios and prints a comparison of `tenant-a`'s
p99 latency under each:

1. **Baseline** — `tenant-a` alone, no neighbor
2. **Unisolated** — both running, no cgroup tuning, default scheduler
3. **Weighted** — `cpu.weight=10` for `tenant-b`, default for `tenant-a`
4. **Pinned** — `tenant-a` and `tenant-b` get distinct `cpuset.cpus` and
   the same `numactl --membind` policy where possible

## Run it

```bash
./demo.sh
./demo.sh --scenario weighted   # only one scenario
./demo.sh --clean
```

## Output

A table on stdout with p50/p95/p99 for `tenant-a` under each scenario,
plus the raw `hey` output in `results/`.

## Caveats

- Rootless cgroups v2 must allow `cpu.weight` and `cpuset.cpus` delegation.
  On Fedora 44 this works out of the box. On other distros you may need to
  enable controllers in `/sys/fs/cgroup/<your-slice>/cgroup.subtree_control`.
- NUMA pinning requires more than one NUMA node; the demo detects and
  skips that scenario on single-node hosts.
- `--cpus` flag in podman is a wrapper around `cpu.max`; we use
  `--cpu-weight` (which maps to `cpu.weight` in cgroups v2) for the
  weighted scenario because that's the more interesting knob.
