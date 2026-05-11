#!/usr/bin/env bash
# Demo-02 — STL & layout benchmark, baseline vs cgroup memory pressure.
#
# Builds the bench image and runs it twice:
#   1. Unconstrained — full memory available; reveals the "what's
#      fast at room temperature" picture.
#   2. Pressured — cgroup memory.max = 128M, no swap; reveals how
#      each container degrades when the kernel has to evict pages
#      to fit the working set. Node-based containers (unordered_map,
#      map) take the hardest hit because their per-node allocations
#      scatter across pages.
#
# Output: JSON files in the current dir + a side-by-side comparison
# table printed to stdout.
#
# Usage:
#   ./demo.sh                                  # full run
#   ./demo.sh --baseline-only                  # just the unconstrained run
#   ./demo.sh --pressured-only                 # just the constrained run
#   ./demo.sh --memory 64m                     # override the memory cap

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

IMAGE="cpp-tut/demo-02:latest"
MEMORY_LIMIT="128m"
BASELINE_OUT="$DIR/results-baseline.json"
PRESSURED_OUT="$DIR/results-pressured.json"

RUN_BASELINE=1
RUN_PRESSURED=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --baseline-only)  RUN_PRESSURED=0; shift ;;
        --pressured-only) RUN_BASELINE=0;  shift ;;
        --memory)         MEMORY_LIMIT="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,22p' "$0"
            exit 0
            ;;
        *)
            echo "unknown arg: $1" >&2
            exit 2
            ;;
    esac
done

# ── Build the image once ──────────────────────────────────────────────────

echo "==> Building $IMAGE (first build ~3-5 min; subsequent runs cached)"
podman build -f Containerfile -t "$IMAGE" .

# ── Phase 1: baseline ──────────────────────────────────────────────────────
#
# No memory limit. Full system memory available. The
# benchmark binary's repetitions=3 + Google Benchmark's
# built-in warm-up keep variance reasonable for a desktop run.

if (( RUN_BASELINE )); then
    echo
    echo "==> Phase 1 — baseline (no memory limit)"
    podman run --rm \
        --name demo-02-baseline \
        "$IMAGE" \
        > "$BASELINE_OUT"
    echo "    wrote $BASELINE_OUT"
fi

# ── Phase 2: pressured ────────────────────────────────────────────────────
#
# --memory caps memory.max. --memory-swap equal to --memory means
# no swap (the cgroup must fit its working set in real memory or
# the kernel evicts file-backed pages aggressively).
# --cgroup-conf is the rootless-friendly way to set additional
# cgroup parameters if needed; for now memory.max + no-swap is
# enough to make the lesson visible.

if (( RUN_PRESSURED )); then
    echo
    echo "==> Phase 2 — pressured (memory.max=$MEMORY_LIMIT, no swap)"
    podman run --rm \
        --name demo-02-pressured \
        --memory="$MEMORY_LIMIT" \
        --memory-swap="$MEMORY_LIMIT" \
        "$IMAGE" \
        > "$PRESSURED_OUT"
    echo "    wrote $PRESSURED_OUT"
fi

# ── Summary table ────────────────────────────────────────────────────────
#
# Parse both JSON files with jq, print a side-by-side comparison of
# real_time (ns) for each (benchmark_name, size) pair. The story to
# look for in the output:
#
#   - At small N (64, 1024), all containers are roughly equivalent;
#     they all fit in L1/L2.
#   - At N=16384, flat_map and vector start to pull ahead on iterate;
#     lookup is still mostly equivalent.
#   - At N=262144 (largest size), iterate-and-sum shows a clear
#     ordering: vector ≈ flat_map ≪ unordered_map ≪ map.
#   - Under pressure, the gap WIDENS: node-based containers fault
#     and thrash; contiguous layouts ride the prefetcher.

if [[ -s "$BASELINE_OUT" && -s "$PRESSURED_OUT" ]]; then
    echo
    echo "==> Summary — baseline vs pressured (median real_time across reps)"
    echo
    if ! command -v jq >/dev/null; then
        echo "jq not installed; raw JSON in $BASELINE_OUT and $PRESSURED_OUT"
        exit 0
    fi
    # Median across repetitions is benchmark_name suffixed with "_median".
    # We extract (clean_name, size_arg, real_time) from each file and join.
    printf "%-38s %10s %12s %12s   %s\n" \
           "Benchmark" "N" "Baseline µs" "Pressured µs" "Ratio"
    printf -- "%-38s %10s %12s %12s   %s\n" \
           "$(printf '%0.s─' {1..38})" \
           "──────────" "────────────" "────────────" \
           "─────"
    jq -r '
        .benchmarks
        | map(select(.aggregate_name == "median"))
        | .[]
        | "\(.run_name)|\(.real_time)"
    ' "$BASELINE_OUT" | sort > /tmp/demo-02-baseline.tsv
    jq -r '
        .benchmarks
        | map(select(.aggregate_name == "median"))
        | .[]
        | "\(.run_name)|\(.real_time)"
    ' "$PRESSURED_OUT" | sort > /tmp/demo-02-pressured.tsv
    join -t'|' /tmp/demo-02-baseline.tsv /tmp/demo-02-pressured.tsv | \
        while IFS='|' read -r name base press; do
            # run_name is e.g. "BM_Lookup_FlatMap/1024_median"; split on /
            bench="${name%/*}"
            size="${name#*/}"
            size="${size%_median}"
            ratio=$(awk -v b="$base" -v p="$press" 'BEGIN { if (b > 0) printf "%.2fx", p/b; else print "n/a" }')
            printf "%-38s %10s %12.1f %12.1f   %s\n" \
                   "$bench" "$size" "$base" "$press" "$ratio"
        done
    rm -f /tmp/demo-02-baseline.tsv /tmp/demo-02-pressured.tsv
fi
