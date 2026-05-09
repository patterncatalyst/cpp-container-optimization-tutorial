#!/usr/bin/env bash
# Demo 2 — STL containers and allocator choice on a fixed workload.
#
# Run from this directory:
#   ./demo.sh
#   ./demo.sh --quick
#   ./demo.sh --clean

set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DEMO_DIR"

# shellcheck source=../../scripts/lib/_helpers.sh
source "$(cd ../../scripts/lib && pwd)/_helpers.sh"

IMG="cpp-tut/demo-02:latest"
CTR="demo02-bench"
RESULTS="results"

case "${1:-}" in
  --clean)
    podman rm -f "$CTR" >/dev/null 2>&1 || true
    podman rmi -f "$IMG" >/dev/null 2>&1 || true
    rm -rf "$RESULTS"
    log_ok "Cleaned."
    exit 0
    ;;
esac

ITERS=2000000
[[ "${1:-}" == "--quick" ]] && ITERS=200000

require podman jq
mkdir -p "$RESULTS"
register_cleanup "$CTR"

log_step "Building image"
podman build -t "$IMG" .

# A tiny shim so each invocation gets its own container name and we
# capture its stdout (a single CSV row) into the rollup.
run_bench() {
  local label="$1"; shift
  local workload="$1"; shift
  local extra_args=("$@")
  podman run --rm --name "$CTR" \
    "${extra_args[@]}" \
    "$IMG" "$workload" "$ITERS" "$label"
}

ROLLUP="$RESULTS/results.csv"
echo "workload,label,iterations,microseconds" > "$ROLLUP"

log_step "Container vs flat container lookup"
run_bench "std_set"      set       >> "$ROLLUP"
run_bench "flat_set"     flat_set  >> "$ROLLUP"

log_step "Allocator: default vs mimalloc (LD_PRELOAD) vs PMR arena"
run_bench "default_new"  alloc_default  >> "$ROLLUP"
run_bench "mimalloc"     alloc_default  -e LD_PRELOAD=/usr/local/lib/libmimalloc.so >> "$ROLLUP"
run_bench "pmr_arena"    alloc_pmr      >> "$ROLLUP"

log_step "Random access (THP host setting reported but not toggled)"
THP="$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo 'unknown')"
log_info "host THP setting: $THP"
run_bench "random_baseline"   random_access >> "$ROLLUP"

log_step "Random access under tight cgroup memory.high"
# Try to set memory.high; fall through cleanly if rootless cgroups don't allow it.
if run_bench "random_memhigh" random_access \
    --memory=128m --memory-swap=128m >> "$ROLLUP" 2>/dev/null; then
  log_ok "memory.high run captured"
else
  log_warn "rootless cgroup didn't allow memory limit; skipping that comparison"
  echo "random_memhigh,skipped,$ITERS,-1" >> "$ROLLUP"
fi

log_step "Results"
column -t -s, "$ROLLUP"

log_ok "CSV: $ROLLUP"
