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

### Check your current state

```bash
cat /sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.subtree_control
```

You want this to contain at least `cpu cpuset memory io`. If it shows
just `memory pids` (or similar), the `weighted` and `pinned` scenarios
will skip cleanly with a warning, and you'll only see the
`baseline` and `unisolated` numbers.

### Enable full delegation (one-time, persists across reboots)

```bash
sudo mkdir -p /etc/systemd/system/user@.service.d/
sudo tee /etc/systemd/system/user@.service.d/delegate.conf <<'EOF'
[Service]
Delegate=cpu cpuset io memory pids
EOF
sudo systemctl daemon-reload

# Then log out and back in, or:
sudo loginctl terminate-user "$USER"
```

After re-login, verify with the check command above. The
`weighted` and `pinned` scenarios will work on the next `./demo.sh`
run.

The demo's `./demo.sh` detects the delegation state up front and
prints a clear message if the controllers aren't available; scenarios
that need missing controllers are skipped cleanly rather than crashing.

## Caveats

- NUMA pinning requires more than one NUMA node; the demo detects
  single-node hosts and skips the NUMA portion of `pinned`. On a
  single-NUMA-node host (most laptops), `pinned` still uses
  `cpuset.cpus` to split CPU cores between tenants — that part works.
- `--cpus` flag in podman is a wrapper around `cpu.max`; we use
  `--cpu-weight` (which maps to `cpu.weight` in cgroups v2) for the
  weighted scenario because that's the more interesting knob.
- G-40 captured during r97/r98: rootless podman + cpuset.cpus needs
  cpuset controller delegated to the user slice, not just available
  on the host. Earlier documentation incorrectly suggested cpuset
  worked without delegation; it doesn't.
