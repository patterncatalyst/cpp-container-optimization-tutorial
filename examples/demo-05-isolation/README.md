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

## Cgroup v2 controller delegation (host setup, may be required)

The `weighted` and `pinned` scenarios need rootless podman to be able
to apply cgroup v2 `cpu` and `cpuset` controllers respectively. By
default, most distros — including Fedora 44 in many install
configurations — only delegate `memory` and `pids` to user slices.
You may need a one-time host opt-in to delegate `cpu` and `cpuset`.

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

### What the script does (in case you want to do it by hand)

`enable` creates this file:

```ini
# /etc/systemd/system/user@.service.d/delegate.conf
[Service]
Delegate=cpu cpuset io memory pids
```

…then runs `systemctl daemon-reload`. The new delegation activates on
your next login (the script does NOT automatically log you out —
you're invited to do that yourself or reboot at a convenient time).

`disable` removes that file and runs `daemon-reload`. The script
refuses to touch the file if it's been hand-customized; it only
manages its own canonical form.

`check` reads `/sys/fs/cgroup/.../cgroup.subtree_control` to see
which controllers are currently live in your user slice, reads the
drop-in file to see what's configured, and reports any inconsistency
(e.g., "drop-in installed but not yet applied — you need to re-login").

### Why this is needed

Rootless podman containers run inside cgroups parented to your
systemd user slice. For podman to apply CPU/memory/IO limits to
those child cgroups, the user slice itself must have the respective
controllers delegated — meaning they're listed in the slice's
`cgroup.subtree_control`. Default systemd configurations delegate
only `memory` and `pids` to user slices, which is fine for most
containers but insufficient for `--cpu-weight`, `--cpus`,
`--cpuset-cpus`, and similar resource flags. This script just
flips the systemd switch that makes those flags work.

If your current state shows missing controllers, `demo.sh` detects
this up front and skips the affected scenarios cleanly with a
warning — you'll see baseline and unisolated rows, with
`weighted: skipped` and `pinned: skipped` in the summary.

## Caveats

- NUMA pinning requires more than one NUMA node; the demo detects
  single-node hosts and skips the NUMA portion of `pinned`. On a
  single-NUMA-node host (most laptops), `pinned` still uses
  `cpuset.cpus` to split CPU cores between tenants — that part works.
- `--cpus` flag in podman is a wrapper around `cpu.max`; we use
  `--cpu-weight` (which maps to `cpu.weight` in cgroups v2) for the
  weighted scenario because that's the more interesting knob.
- G-40 captured during r97/r98: rootless podman + `cpuset.cpus`
  needs the cpuset controller delegated to the user slice, not just
  available on the host. Earlier documentation incorrectly suggested
  cpuset worked without delegation; it doesn't.
