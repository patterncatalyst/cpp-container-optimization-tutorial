#!/usr/bin/env bash
# Demo-06 end-to-end verification (r71 v1: toolchain proof only).
#
# Pass criteria:
#   1. Image builds successfully
#   2. All 4 binaries exist in the image at /usr/local/bin/
#   3. Each binary runs and produces valid JSON output
#   4. All 4 variants produce the same result_hash (allocator
#      correctness — alloc choice supposed to be invisible to results)
#   5. Iteration count matches the requested value
#
# This script doesn't check absolute performance numbers because
# they're hardware-dependent. r72+ will add LGTM signal-flow
# verification when OTel is wired in.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/_helpers.sh"

require podman jq

DEMO="$REPO_ROOT/examples/demo-06-memory-and-allocators"
IMAGE="cpp-tut/demo-06:latest"

log_step "Phase 1 — building $IMAGE"
cd "$DEMO"
podman build -t "$IMAGE" -f Containerfile .

log_step "Phase 2 — verifying all 4 binaries exist"
for v in std pmr mimalloc jemalloc; do
    if ! podman run --rm --entrypoint /bin/sh "$IMAGE" \
            -c "test -x /usr/local/bin/demo06-svc-$v" 2>/dev/null; then
        log_err "demo06-svc-$v missing or not executable in image"
        exit 1
    fi
    log_ok "  demo06-svc-$v present and executable"
done

log_step "Phase 3 — running each variant (small workload for speed)"
ITERATIONS=50

results=()
for v in std pmr mimalloc jemalloc; do
    json=$(podman run --rm --entrypoint "/usr/local/bin/demo06-svc-$v" \
        "$IMAGE" "$ITERATIONS" 5 3 6)
    if ! echo "$json" | jq -e '.variant and .iterations and .result_hash' >/dev/null 2>&1; then
        log_err "Variant $v produced invalid JSON:"
        log_err "  $json"
        exit 1
    fi
    n=$(echo "$json" | jq .iterations)
    if [[ "$n" != "$ITERATIONS" ]]; then
        log_err "Variant $v: expected $ITERATIONS iterations, got $n"
        exit 1
    fi
    log_ok "  $v ran $n iterations cleanly"
    results+=("$json")
done

log_step "Phase 4 — cross-variant hash agreement"
hashes=$(printf '%s\n' "${results[@]}" | jq -r .result_hash | sort -u)
hash_count=$(echo "$hashes" | wc -l)
if (( hash_count == 1 )); then
    log_ok "All 4 variants produced hash $hashes"
else
    log_err "Variants disagreed on result hash (should be invisible to alloc choice):"
    echo "$hashes" | sed 's/^/    /' >&2
    exit 1
fi

log_ok "test-demo-06 PASS — 4-way toolchain proof verified"
