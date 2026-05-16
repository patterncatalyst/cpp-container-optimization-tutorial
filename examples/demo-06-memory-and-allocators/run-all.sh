#!/bin/bash
# Demo-06 container ENTRYPOINT.
#
# Runs the workload binary(ies) and prints one JSON line per variant
# to stdout. The host-side demo.sh captures these via `podman run`
# and assembles the comparison table.
#
# Selection logic:
#   ALLOC=std        → run demo06-svc-std only
#   ALLOC=pmr        → run demo06-svc-pmr only
#   ALLOC=mimalloc   → run demo06-svc-mimalloc only
#   ALLOC=jemalloc   → run demo06-svc-jemalloc only
#   ALLOC unset      → run all four in sequence
#
# Iteration count + workload params come via $ITERATIONS, $DEPTH,
# $BRANCH, $VALUES env vars (with sensible defaults).

set -euo pipefail

ITERATIONS="${ITERATIONS:-200}"
DEPTH="${DEPTH:-6}"
BRANCH="${BRANCH:-4}"
VALUES="${VALUES:-8}"

run_one() {
    local variant="$1"
    local bin="/usr/local/bin/demo06-svc-$variant"
    if [[ ! -x "$bin" ]]; then
        echo "==> ERROR: $bin not found or not executable" >&2
        return 1
    fi
    "$bin" "$ITERATIONS" "$DEPTH" "$BRANCH" "$VALUES"
}

if [[ -n "${ALLOC:-}" ]]; then
    run_one "$ALLOC"
else
    for v in std pmr mimalloc jemalloc; do
        run_one "$v"
    done
fi
