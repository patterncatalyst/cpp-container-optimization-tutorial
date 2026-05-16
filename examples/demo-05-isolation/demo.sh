#!/usr/bin/env bash
# Demo 5 — noisy-neighbor isolation through cgroup v2 controls.
#
#   ./demo.sh
#   ./demo.sh --scenario baseline|unisolated|weighted|pinned
#   ./demo.sh --clean

set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DEMO_DIR"

# shellcheck source=../../scripts/lib/_helpers.sh
source "$(cd ../../scripts/lib && pwd)/_helpers.sh"

IMG_A="cpp-tut/demo-05:tenant-a"
IMG_B="cpp-tut/demo-05:tenant-b"
PORT=18501

SCENARIO=all
DO_CLEAN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --scenario) SCENARIO="$2"; shift 2;;
    --clean)    DO_CLEAN=1;    shift;;
    *) log_err "unknown arg: $1"; exit 2;;
  esac
done

if [[ $DO_CLEAN -eq 1 ]]; then
  podman rm -f demo05-a demo05-b 2>/dev/null || true
  podman rmi -f "$IMG_A" "$IMG_B" 2>/dev/null || true
  rm -rf results
  log_ok "Cleaned."
  exit 0
fi

require podman hey awk
register_cleanup demo05-a demo05-b
mkdir -p results

# ── G-40 (r98): cgroup v2 controller delegation detection ────────────
#
# Rootless podman's `--cpu-weight` and `--cpuset-cpus` flags need their
# respective cgroup v2 controllers (cpu, cpuset) delegated to the
# user slice. Default systemd configurations on most distros only
# delegate `memory pids` — cpu/cpuset/io require an explicit opt-in
# via a systemd drop-in. See README's "Cgroup v2 controller
# delegation" section for the fix.
#
# We detect available controllers up front and set flags so each
# scenario can skip cleanly with a clear message rather than crash
# with an opaque OCI runtime error mid-test.
HAS_CPU_DELEGATED=0
HAS_CPUSET_DELEGATED=0
DELEGATE_PATH="/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.subtree_control"
if [[ -r "$DELEGATE_PATH" ]]; then
  DELEGATE_CONTENT="$(<"$DELEGATE_PATH")"
  [[ "$DELEGATE_CONTENT" == *cpu* ]]    && HAS_CPU_DELEGATED=1
  [[ "$DELEGATE_CONTENT" == *cpuset* ]] && HAS_CPUSET_DELEGATED=1
else
  DELEGATE_CONTENT=""
fi

if (( ! HAS_CPU_DELEGATED )) || (( ! HAS_CPUSET_DELEGATED )); then
  log_warn "cgroup v2 controller delegation incomplete:"
  log_warn "  current: ${DELEGATE_CONTENT:-(empty or unreadable)}"
  log_warn "  cpu:    $((HAS_CPU_DELEGATED))  (needed for the 'weighted' scenario)"
  log_warn "  cpuset: $((HAS_CPUSET_DELEGATED))  (needed for the 'pinned' scenario)"
  log_warn "Scenarios that need missing controllers will be skipped cleanly."
  log_warn "See README's 'Cgroup v2 controller delegation' section for the fix."
fi

log_step "Building both tenants"
podman build --target tenant-a -t "$IMG_A" .
podman build --target tenant-b -t "$IMG_B" .

# Detect NUMA topology so we can decide whether the 'pinned' scenario
# is even meaningful.
NODES=$(ls -1 /sys/devices/system/node 2>/dev/null | grep -c '^node[0-9]\+$' || echo 1)
log_info "Detected $NODES NUMA node(s)"

start_a()    { podman run --rm -d --name demo05-a -p "${PORT}:8080" "$IMG_A" >/dev/null; }
start_b()    { podman run --rm -d --name demo05-b "$@" "$IMG_B" >/dev/null; }
stop_both()  { podman stop demo05-a demo05-b >/dev/null 2>&1 || true; sleep 0.5; }

# Wait for tenant-a's HTTP server to be accepting connections. Replaces
# a fixed 'sleep 1' which would silently race against the container's
# startup time, especially under rootless slirp4netns.
wait_for_a() {
  local i
  for i in $(seq 1 50); do
    if curl -sf --max-time 1 "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  log_err "tenant-a did not become ready within 5s"
  podman logs demo05-a 2>&1 | tail -20
  return 1
}

# Robust hey-output parser.
#
# G-38: hey's percentile lines can have either '50%' or '50%%' depending
# on the installation (some builds don't expand the %%-escape in the
# format string). Pattern uses %+ to match one or more percent signs.
#
# Also validates that percentile lines were found at all; if not,
# the output is unparseable and we bail with a clear error rather than
# silently printing all-zero percentiles.
bench_a() {
  local label="$1"
  if ! wait_for_a; then
    return 1
  fi
  hey -n 5000 -c 25 "http://127.0.0.1:${PORT}/" > "results/$label.txt" 2>&1
  if ! grep -qE '^[[:space:]]+50%+ in' "results/$label.txt"; then
    log_err "hey produced no percentile data for $label"
    log_err "first 30 lines of results/$label.txt:"
    head -30 "results/$label.txt" | sed 's/^/    /' >&2
    log_err "tenant-a container logs (tail):"
    podman logs demo05-a 2>&1 | tail -10 | sed 's/^/    /' >&2
    return 1
  fi
  awk -v lbl="$label" '
    /^[[:space:]]+50%+ in/ {p50=$3*1000}
    /^[[:space:]]+95%+ in/ {p95=$3*1000}
    /^[[:space:]]+99%+ in/ {p99=$3*1000}
    END     {printf "%-12s p50=%8.2fms  p95=%8.2fms  p99=%8.2fms\n", lbl, p50, p95, p99}
  ' "results/$label.txt"
}

run_baseline() {
  log_step "Scenario: baseline (tenant-a alone)"
  start_a
  bench_a baseline
  stop_both
}

run_unisolated() {
  log_step "Scenario: unisolated (both running, no tuning)"
  start_a
  start_b
  bench_a unisolated
  stop_both
}

run_weighted() {
  log_step "Scenario: weighted (tenant-b cpu.weight=10)"
  if (( ! HAS_CPU_DELEGATED )); then
    log_warn "skipping: cgroup v2 'cpu' controller not delegated to user slice"
    echo "weighted: skipped (cgroup v2 cpu controller not delegated; see README)" \
      > results/weighted.txt
    return
  fi
  start_a
  if start_b --cpu-weight=10 2>/dev/null; then
    bench_a weighted
  else
    log_warn "rootless cgroup did not accept --cpu-weight; recording N/A"
    echo "weighted: skipped (rootless cgroup didn't allow cpu.weight)" \
      > results/weighted.txt
  fi
  stop_both
}

run_pinned() {
  log_step "Scenario: pinned (cpuset.cpus split)"
  if (( ! HAS_CPUSET_DELEGATED )); then
    log_warn "skipping: cgroup v2 'cpuset' controller not delegated to user slice"
    echo "pinned: skipped (cgroup v2 cpuset controller not delegated; see README)" \
      > results/pinned.txt
    return
  fi
  if [[ "$NODES" -lt 1 ]]; then
    log_warn "no NUMA info; skipping pinned"
    echo "pinned: skipped (no NUMA info)" > results/pinned.txt
    return
  fi
  local total
  total=$(nproc)
  if (( total < 4 )); then
    log_warn "need at least 4 CPUs to pin; have $total — skipping pinned"
    echo "pinned: skipped (only $total CPUs, need >= 4)" > results/pinned.txt
    return
  fi
  local half=$(( total / 2 ))
  local a_cpus="0-$((half - 1))"
  local b_cpus="$half-$((total - 1))"
  log_info "pinning tenant-a to $a_cpus, tenant-b to $b_cpus"
  # Wrap both podman starts in error handling — if the cpuset controller
  # is partly delegated but the specific cpuset constraint fails, we
  # surface a clean N/A rather than letting `set -e` kill the run.
  if podman run --rm -d --name demo05-a --cpuset-cpus="$a_cpus" \
        -p "${PORT}:8080" "$IMG_A" >/dev/null 2>&1 \
     && podman run --rm -d --name demo05-b --cpuset-cpus="$b_cpus" \
        "$IMG_B" >/dev/null 2>&1; then
    bench_a pinned
  else
    log_warn "podman rejected --cpuset-cpus; recording N/A"
    log_warn "to see the underlying error, run:"
    log_warn "  podman run --rm --cpuset-cpus=$a_cpus $IMG_A"
    echo "pinned: skipped (podman --cpuset-cpus failed; rerun manually for the error)" \
      > results/pinned.txt
  fi
  stop_both
}

case "$SCENARIO" in
  baseline)    run_baseline ;;
  unisolated)  run_unisolated ;;
  weighted)    run_weighted ;;
  pinned)      run_pinned ;;
  all)         run_baseline; run_unisolated; run_weighted; run_pinned ;;
  *) log_err "unknown scenario: $SCENARIO"; exit 2 ;;
esac

log_step "Summary"
for s in baseline unisolated weighted pinned; do
  if [[ -f "results/$s.txt" ]]; then
    if grep -qE '^[[:space:]]+50%+ in' "results/$s.txt"; then
      awk -v lbl="$s" '
        /^[[:space:]]+50%+ in/ {p50=$3*1000}
        /^[[:space:]]+95%+ in/ {p95=$3*1000}
        /^[[:space:]]+99%+ in/ {p99=$3*1000}
        END     {printf "%-12s p50=%8.2fms  p95=%8.2fms  p99=%8.2fms\n", lbl, p50, p95, p99}
      ' "results/$s.txt"
    else
      printf "%-12s (no percentile data — see results/%s.txt)\n" "$s" "$s"
    fi
  fi
done
