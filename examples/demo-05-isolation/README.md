# Demo 5 — Noisy neighbor isolation

Tutorial section: [§11 Noisy Neighbor Isolation](/docs/11-noisy-neighbors/)

Two services running side-by-side on the same host, with a load
generator hammering one of them. The demo measures what happens to
the well-behaved tenant's p99 under three isolation strategies,
plus a baseline.

## Why this matters

The dominant production cost on a busy multi-tenant host is **not**
the CPU work each service performs — it's the **interference**
between services. A tenant that's perfectly tuned in isolation may
have its p99 latency dominated by a neighbor that's saturating the
shared CPU, the shared memory bandwidth, the shared L3 cache, or
the shared I/O queue.

Most C++ engineers don't know what their host's defaults actually
do. cgroups v2 ships every major Linux distribution with a clear
model: every process belongs to a cgroup, every cgroup has weight
on every resource, the kernel arbitrates. The interesting questions
become:

- **How much does the default arbitration cost the latency-sensitive
  tenant?** (Spoiler: a lot more than most engineers expect.)
- **What does `cpu.weight=10` for the noisy neighbor actually do?**
  (It bounds the damage without limiting throughput when the
  CPU is otherwise idle.)
- **What does `cpuset.cpus` pinning do that weighting doesn't?**
  (It eliminates cross-tenant cache eviction entirely, at the cost
  of capping each tenant's maximum CPU.)

§11 covers the underlying cgroup model; this demo measures the
trade-offs.

## What this demo shows

Two C++ HTTP services running side-by-side in containers:

- **`tenant-a`** — the "good citizen": handles HTTP traffic,
  exposes latency metrics. This is the service whose p99 we
  measure.
- **`tenant-b`** — the "noisy neighbor": runs CPU- and
  memory-bound background work in a tight loop, no rate limiting.
  Simulates a co-located service that doesn't respect its
  neighbors.

Four scenarios run sequentially, each measuring `tenant-a`'s p99
under load:

1. **Baseline** — `tenant-a` alone, no neighbor at all
2. **Unisolated** — both running, no cgroup tuning, default
   scheduler
3. **Weighted** — `cpu.weight=10` for `tenant-b`, default
   (`cpu.weight=100`) for `tenant-a`
4. **Pinned** — `tenant-a` and `tenant-b` get distinct
   `cpuset.cpus` and the same `numactl --membind` policy where
   possible

## How to run

```bash
./demo.sh                       # run all four scenarios
./demo.sh --scenario weighted   # only one scenario
./demo.sh --clean               # tear it all down
```

Expected runtime: ~3-5 minutes including warmup and the four
scenario windows. Cold cache adds a Conan + Containerfile build
phase of ~2-3 minutes.

## What you'll see

A table on stdout with p50/p95/p99 for `tenant-a` under each
scenario, plus the raw `hey` output in `results/`. Representative
output on a Fedora 44 host with 8 cores:

```
Scenario        tenant-a p50    p95       p99      vs baseline
baseline           1.90 ms     2.20 ms    2.30 ms    —
unisolated        12.30 ms    21.40 ms   24.70 ms    10.7×
weighted           4.80 ms     8.20 ms    9.00 ms     3.9×
pinned             1.50 ms     1.70 ms    1.80 ms     0.8×
```

## How to read the output

The headline numbers — what to look for first:

- **The `unisolated` row is the cost of doing nothing.** ~10× p99
  degradation is typical for this kind of synthetic neighbor.
  Real production neighbors are usually less bad than this
  microbenchmark suggests (their CPU work isn't 100% pegged), but
  the direction is the same.
- **`weighted` recovers most of the baseline.** ~4× degradation
  is roughly the asymptotic case: the noisy neighbor still gets
  scheduled, but the kernel preferentially gives `tenant-a` more
  time. p99 stays bounded.
- **`pinned` can be *faster* than baseline.** The 0.8× number
  isn't a typo — when `tenant-a` gets dedicated CPUs, the kernel
  scheduler doesn't migrate it, cache stays hot, and the p99
  drops below the single-tenant baseline. This is a real result;
  it's why latency-sensitive production services often pin.

What different output would mean:

- **If `unisolated` is similar to `baseline`**, the noisy neighbor
  isn't actually saturating CPU. Either the host has more cores
  than the neighbor can use, or `tenant-b` isn't running. Check
  `podman ps` and `top` while the scenario runs.
- **If `weighted` shows no improvement over `unisolated`**, cgroup
  cpu controller isn't delegated to your user slice — see the
  setup section below.
- **If `pinned` is *slower* than `unisolated`**, you've pinned
  both tenants to the same CPU set (check the `cpuset.cpus`
  values). Pinning helps only when the two tenants get
  non-overlapping CPU lists.

## Cgroup v2 controller delegation (host setup, may be required)

The `weighted` and `pinned` scenarios need rootless podman to be
able to apply cgroup v2 `cpu` and `cpuset` controllers
respectively. By default, most distros — including Fedora 44 in
many install configurations — only delegate `memory` and `pids`
to user slices. You may need a one-time host opt-in to delegate
`cpu` and `cpuset`.

A helper script handles the check, enable, and disable for you:

```bash
# From the repo root:
./scripts/cgroup-delegation.sh check     # show current state (default)
./scripts/cgroup-delegation.sh enable    # install systemd drop-in
./scripts/cgroup-delegation.sh disable   # remove the drop-in
./scripts/cgroup-delegation.sh verify    # terse pass/fail (for CI)
./scripts/cgroup-delegation.sh help
```

### Quick path

```bash
./scripts/cgroup-delegation.sh check
# If it reports "missing controllers":
./scripts/cgroup-delegation.sh enable
# Log out and back in (or reboot), then:
./scripts/cgroup-delegation.sh check
# Should now report "fully configured."
```

### What the script does (if you want to do it by hand)

`enable` creates this file:

```ini
# /etc/systemd/system/user@.service.d/delegate.conf
[Service]
Delegate=cpu cpuset io memory pids
```

…then runs `systemctl daemon-reload`. The new delegation activates
on your next login (the script does NOT automatically log you out
— you're invited to do that yourself or reboot at a convenient
time).

`disable` removes that file and runs `daemon-reload`. The script
refuses to touch the file if it's been hand-customized; it only
manages its own canonical form.

`check` reads `/sys/fs/cgroup/.../cgroup.subtree_control` to see
which controllers are currently live in your user slice, reads
the drop-in file to see what's configured, and reports any
inconsistency (e.g., "drop-in installed but not yet applied —
you need to re-login").

### Why this is needed

Rootless podman containers run inside cgroups parented to your
systemd user slice. For podman to apply CPU/memory/IO limits to
those child cgroups, the user slice itself must have the
respective controllers delegated — meaning they're listed in the
slice's `cgroup.subtree_control`. Default systemd configurations
delegate only `memory` and `pids` to user slices, which is fine
for most containers but insufficient for
`--cgroup-conf=cpu.weight=N`, `--cpus`, `--cpuset-cpus`, and
similar resource flags. This script just flips the systemd switch
that makes those flags work.

If your current state shows missing controllers, `demo.sh`
detects this up front and skips the affected scenarios cleanly
with a warning — you'll see baseline and unisolated rows, with
`weighted: skipped` and `pinned: skipped` in the summary.

## Caveats and gotchas

- **NUMA pinning requires more than one NUMA node.** The demo
  detects single-node hosts (most laptops) and skips the NUMA
  portion of `pinned`. On a single-NUMA host, `pinned` still uses
  `cpuset.cpus` to split CPU cores between tenants — that part
  works.
- **`--cpus` flag in podman is a wrapper around `cpu.max`.** We
  use `--cgroup-conf=cpu.weight=N` (which writes directly to
  `cpu.weight` in cgroups v2) for the weighted scenario because
  that's the more interesting knob: weight bounds interference
  without capping throughput when the CPU is otherwise idle.
- **`--cpu-weight` is NOT a podman flag.** It's intuitively close
  to the cgroup file `cpu.weight` it would write to, but no
  podman version has shipped it. The correct invocations are
  `--cgroup-conf=cpu.weight=N` (writes the v2 file directly;
  requires podman 4.0+) or `--cpu-shares=N` (legacy cgroup v1
  flag, auto-translated to v2 weight via a formula — the value
  you pass is not the weight you get). The demo uses
  `--cgroup-conf=cpu.weight=10`.
- **Rootless cpuset requires controller delegation** specifically.
  Earlier guides incorrectly suggested cpuset worked without
  delegation; it doesn't. See the setup section above.
- **The synthetic neighbor saturates 100% of available CPU.**
  Real noisy neighbors are usually less aggressive than this
  microbenchmark; treat the unisolated number as upper-bound for
  damage rather than typical.

## Source materials

This demo deepens material from the project's
[**bibliography**](/bibliography/):

- **Enberg, *Latency*, ch. 7** — scheduler-induced latency and
  the priority-inheritance argument; what cgroup weighting
  actually does to scheduler decisions
- **Ghosh, *Building Low Latency Applications with C++*, ch. 11**
  — CPU pinning and NUMA-aware design at the architectural level
- **Andrist & Sehr, *C++ High Performance* 2e, ch. 11** — the
  concurrency chapter touches on scheduler interactions and the
  CFS model

## Linked tutorial sections

- [**§11 Noisy Neighbor Isolation**](/docs/11-noisy-neighbors/) —
  this demo is §11's worked example. The §11 prose develops the
  cgroup v2 model, `cpu.weight` semantics, `cpuset.cpus`
  semantics, and the NUMA story; this demo measures them.
- [**§7 Memory Management**](/docs/07-memory-management/) — the
  `memory.high` / `memory.max` knobs in §7 are the memory-side
  complement to this demo's CPU work. Together they cover the
  two most important cgroup controllers for C++ services.
- [**§9 Networking & Kernel Parameters**](/docs/09-networking-kernel/)
  — `io.weight` for storage-side noisy-neighbor isolation works
  analogously to `cpu.weight` here; §9 covers it.
- [**§10 Observability & Profiling**](/docs/10-observability-profiling/)
  — demo-04's bpftrace sched-switch probes are how you confirm
  what cgroup weighting is doing in production. Sched-switch
  spikes coinciding with p99 spikes are a textbook signal.
