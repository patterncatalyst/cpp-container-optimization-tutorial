#!/usr/bin/env bash
# Verify demo-02 builds and the bench harness produces well-formed CSV
# rows for each of the supported workloads.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/_helpers.sh
source "$REPO_ROOT/scripts/lib/_helpers.sh"

require podman

DEMO="$REPO_ROOT/examples/demo-02-memory-and-stl"
cd "$DEMO"

log_step "test-demo-02: build"
podman build -t cpp-tut/demo-02:test .

log_step "test-demo-02: run each workload once"
ITERS=10000
fail=0
for w in set flat_set alloc_default alloc_pmr random_access; do
  out=$(podman run --rm cpp-tut/demo-02:test "$w" "$ITERS" "test-$w" || true)
  if [[ "$out" =~ ^${w}, ]]; then
    log_ok "  $w -> $out"
  else
    log_err "  $w -> unexpected output: $out"
    fail=1
  fi
done

if [[ $fail -eq 0 ]]; then
    log_ok "test-demo-02 PASS"
    exit 0
fi
log_err "test-demo-02 FAIL"
exit 1
