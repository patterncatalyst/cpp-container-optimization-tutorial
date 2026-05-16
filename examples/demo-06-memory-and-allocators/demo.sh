#!/usr/bin/env bash
# Demo-06 — memory management & allocator comparison.
#
# r75 v1 3-way: build the 3-variant image, run all three binaries in
# sequence inside one container, parse the JSON output, print a
# comparison table. No HTTP, no OTel, no cgroup pressure yet —
# those land in r72-r74.
#
# Usage:
#   ./demo.sh                         # default: 200 iterations per variant
#   ./demo.sh --iterations 1000       # custom iteration count
#   ./demo.sh --depth 8 --branch 5    # bigger trees
#   ./demo.sh --clean                 # remove image, exit

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

ITERATIONS=200
DEPTH=6
BRANCH=4
VALUES=8
CLEAN_ONLY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --iterations)  ITERATIONS="$2"; shift 2 ;;
        --depth)       DEPTH="$2";      shift 2 ;;
        --branch)      BRANCH="$2";     shift 2 ;;
        --values)      VALUES="$2";     shift 2 ;;
        --clean)       CLEAN_ONLY=1;    shift ;;
        -h|--help)     sed -n '2,16p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

IMAGE="cpp-tut/demo-06:latest"

if (( CLEAN_ONLY )); then
    podman image rm "$IMAGE" 2>/dev/null || true
    exit 0
fi

# ── Build ─────────────────────────────────────────────────────────────

echo "==> Building $IMAGE (first run: ~10-15 min on a clean cache)"
podman build -t "$IMAGE" -f Containerfile .

# ── Run all three variants ────────────────────────────────────────────

echo
echo "==> Running 3 variants × $ITERATIONS iterations"
echo "    depth=$DEPTH branch=$BRANCH values=$VALUES"
echo

# Capture stdout. stderr goes to terminal so the [demo06] init lines
# are visible (helpful when something goes wrong).
results_json=$(podman run --rm \
    -e ITERATIONS="$ITERATIONS" \
    -e DEPTH="$DEPTH" \
    -e BRANCH="$BRANCH" \
    -e VALUES="$VALUES" \
    "$IMAGE")

# ── Parse + tabulate ──────────────────────────────────────────────────

if ! command -v jq >/dev/null 2>&1; then
    echo "==> jq not installed; raw output:"
    echo "$results_json"
    exit 0
fi

echo
echo "==> Comparison table"
echo
printf "%-32s %10s %10s %10s %10s %15s   %s\n" \
       "Variant" "min µs" "p50 µs" "p99 µs" "max µs" "throughput/s" "result_hash"
printf -- "%-32s %10s %10s %10s %10s %15s   %s\n" \
       "────────────────────────────────" \
       "──────────" "──────────" "──────────" "──────────" \
       "───────────────" "──────────────────"

# Walk each JSON line.
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    variant=$(echo "$line" | jq -r .variant)
    printf "%-32s %10.2f %10.2f %10.2f %10.2f %15.1f   %s\n" \
        "$variant" \
        "$(echo "$line" | jq .min_us)" \
        "$(echo "$line" | jq .p50_us)" \
        "$(echo "$line" | jq .p99_us)" \
        "$(echo "$line" | jq .max_us)" \
        "$(echo "$line" | jq .throughput_per_sec)" \
        "$(echo "$line" | jq -r .result_hash)"
done <<< "$results_json"

# ── Sanity: all variants should produce the same hash ─────────────────
# Allocator choice is supposed to be invisible to results; if any
# variant produces a different hash, that's a correctness bug somewhere
# (most likely in our build_tree code mishandling PMR types).

unique_hashes=$(echo "$results_json" | jq -r .result_hash | sort -u)
hash_count=$(echo "$unique_hashes" | wc -l)
echo
if (( hash_count == 1 )); then
    echo "==> Sanity: all variants produced the same hash ($unique_hashes)"
else
    echo "==> WARNING: variants produced different hashes:"
    echo "$unique_hashes" | sed 's/^/    /'
    echo "    Allocator differences are supposed to be invisible at this layer."
    echo "    Investigate workload.cpp's PMR path."
fi
