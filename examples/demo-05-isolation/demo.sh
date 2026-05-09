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

bench_a() {
  local label="$1"
  sleep 1
  hey -n 5000 -c 25 "http://127.0.0.1:${PORT}/" > "results/$label.txt" 2>&1
  awk -v lbl="$label" '
    /50% in/ {p50=$3*1000}
    /95% in/ {p95=$3*1000}
    /99% in/ {p99=$3*1000}
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
  if [[ "$NODES" -lt 1 ]]; then
    log_warn "no NUMA info; skipping pinned"
    return
  fi
  local total
  total=$(nproc)
  if (( total < 4 )); then
    log_warn "need at least 4 CPUs to pin; have $total — skipping pinned"
    return
  fi
  local half=$(( total / 2 ))
  local a_cpus="0-$((half - 1))"
  local b_cpus="$half-$((total - 1))"
  log_info "pinning tenant-a to $a_cpus, tenant-b to $b_cpus"
  podman run --rm -d --name demo05-a --cpuset-cpus="$a_cpus" \
    -p "${PORT}:8080" "$IMG_A" >/dev/null
  podman run --rm -d --name demo05-b --cpuset-cpus="$b_cpus" "$IMG_B" >/dev/null
  bench_a pinned
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
    awk -v lbl="$s" '
      /50% in/ {p50=$3*1000}
      /95% in/ {p95=$3*1000}
      /99% in/ {p99=$3*1000}
      END     {printf "%-12s p50=%8.2fms  p95=%8.2fms  p99=%8.2fms\n", lbl, p50, p95, p99}
    ' "results/$s.txt"
  fi
done
