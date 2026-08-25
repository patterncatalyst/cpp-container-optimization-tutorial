#!/usr/bin/env bash
# ============================================================================
# Demo 02 — STL & layout under memory pressure: layout beats big-O at scale
#
# Builds one bench image and runs it twice against four key-value container
# designs (unordered_map, map, boost flat_map, vector+linear scan) at four
# sizes, on two operations (point lookup, full iteration):
#   1. Unconstrained — full memory available; the "room temperature" picture.
#   2. Pressured — cgroup memory.max = 128M, no swap; how each layout
#      degrades when the kernel must evict pages to fit the working set.
#
# KEY INSIGHT — read this before presenting:
#
#   Data LAYOUT, not algorithmic complexity, determines cache behavior —
#   and at production scale cache locality usually beats big-O. A hash
#   table's "O(1) average" hides a per-node heap allocation, a pointer
#   chase, and a cache miss on every access; its nodes are scattered
#   across pages. A contiguous container (flat_map, vector) rides the
#   hardware prefetcher at memory bandwidth. A cache line is ~64 bytes:
#   contiguous data brings its neighbors along for free; node-based data
#   pays a fresh miss each hop.
#
#   THE ON-STAGE MOMENT is the summary table's N=262144 iterate rows:
#   vector ≈ flat_map ≪ unordered_map ≪ map. Then the Ratio column —
#   under the cgroup cap the node-based containers fault their scattered
#   pages back in and thrash, while contiguous layouts stay flat (~1.0x).
#   Every cache miss becomes a page fault; every page fault, a syscall.
#
# This script is a talk-through: it stops between steps (Press Enter) so
# you can narrate. Piped / non-interactive runs skip the pauses
# automatically (or pass --no-pause).
#
# Usage:
#   ./demo.sh                    full run (build, baseline, pressured, table)
#   ./demo.sh --baseline-only    just the unconstrained run
#   ./demo.sh --pressured-only   just the constrained run
#   ./demo.sh --memory 64m       override the cgroup memory cap
#   ./demo.sh --no-pause         never stop for Enter (unattended)
#   ./demo.sh --clean            remove the built image and result JSON
# ============================================================================

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

# shellcheck source=../../scripts/lib/_helpers.sh
source "$(cd ../../scripts/lib && pwd)/_helpers.sh"

IMAGE="cpp-tut/demo-02:latest"
MEMORY_LIMIT="128m"
BASELINE_OUT="$DIR/results-baseline.json"
PRESSURED_OUT="$DIR/results-pressured.json"

RUN_BASELINE=1
RUN_PRESSURED=1
DO_CLEAN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --baseline-only)  RUN_PRESSURED=0; shift ;;
        --pressured-only) RUN_BASELINE=0;  shift ;;
        --memory)         MEMORY_LIMIT="$2"; shift 2 ;;
        --no-pause)       export DEMO_NO_PAUSE=1; shift ;;
        --clean)          DO_CLEAN=1; shift ;;
        -h|--help)        sed -n '2,40p' "$0"; exit 0 ;;
        *)                log_err "unknown arg: $1"; exit 2 ;;
    esac
done

if [[ $DO_CLEAN -eq 1 ]]; then
    podman rmi -f "$IMAGE" 2>/dev/null || true
    rm -f "$BASELINE_OUT" "$PRESSURED_OUT"
    log_ok "Cleaned."
    exit 0
fi

require podman

banner \
    "DEMO 02 — STL & layout under memory pressure" \
    "Four container designs. Two operations. Layout beats big-O at scale."

callout \
    "Image:      $IMAGE" \
    "Containers: std::unordered_map · std::map · boost flat_map · vector+scan" \
    "Sizes:      64 · 1024 · 16384 · 262144   Ops: point lookup · iterate-sum" \
    "Pressure:   cgroup memory.max=$MEMORY_LIMIT, no swap" \
    "Outputs:    results-baseline.json · results-pressured.json + table"
callout "" "The four containers and both benchmarks live in one file:"
code_ref "src/main.cpp" 39 "container choices + BM_Lookup_Hit / BM_IterateAndSum (Google Benchmark)"

# ── Step 1: Build the bench image ───────────────────────────────────────────
demo_step "Build the benchmark image"
callout "First build ~3-5 min (Conan pulls boost + Google Benchmark)." \
        "Subsequent runs hit the podman layer cache (~30s for both phases)."
if should_build "$IMAGE"; then
    if ! podman build -f Containerfile -t "$IMAGE" .; then
        log_err "podman build failed — nothing to benchmark. Stopping here."
        exit 1
    fi
    log_ok "Image built: $IMAGE"
fi
pause

# ── Step 2: Phase 1 — baseline (no memory limit) ────────────────────────────
#
# No memory limit. Full system memory available. The benchmark binary's
# repetitions=3 + Google Benchmark's built-in warm-up keep variance
# reasonable for a desktop run.
if (( RUN_BASELINE )); then
    demo_step "Phase 1 — baseline (no memory limit)"
    callout "Full memory available: the 'what's fast at room temperature'" \
            "picture. Watch how small-N results cluster (everything fits" \
            "in L1/L2) and only diverge as N grows past the caches."
    if ! podman run --rm \
        --name demo-02-baseline \
        "$IMAGE" \
        > "$BASELINE_OUT"; then
        log_err "baseline run failed — see output above."
        exit 1
    fi
    log_ok "wrote $BASELINE_OUT"
    pause
fi

# ── Step 3: Phase 2 — pressured (cgroup memory cap) ─────────────────────────
#
# --memory caps memory.max. --memory-swap equal to --memory means no swap
# (the cgroup must fit its working set in real memory or the kernel evicts
# file-backed pages aggressively). memory.max + no-swap is enough to make
# the lesson visible.
if (( RUN_PRESSURED )); then
    demo_step "Phase 2 — pressured (memory.max=$MEMORY_LIMIT, no swap)"
    callout "Same binary, now under a hard cgroup cap with swap disabled." \
            "The kernel must evict pages the container had warm. Node-based" \
            "layouts fault their scattered pages back in; contiguous ones" \
            "stream sequentially and barely notice."
    if ! podman run --rm \
        --name demo-02-pressured \
        --memory="$MEMORY_LIMIT" \
        --memory-swap="$MEMORY_LIMIT" \
        "$IMAGE" \
        > "$PRESSURED_OUT"; then
        log_err "pressured run failed — see output above."
        exit 1
    fi
    log_ok "wrote $PRESSURED_OUT"
    pause
fi

# ── Step 4: Summary table + interpretation ──────────────────────────────────
#
# Parse both JSON files with jq, print a side-by-side comparison of
# real_time (ns) for each (benchmark_name, size) pair.
if [[ -s "$BASELINE_OUT" && -s "$PRESSURED_OUT" ]]; then
    demo_step "Summary — baseline vs pressured (median real_time across reps)"
    if ! command -v jq >/dev/null; then
        log_warn "jq not installed; raw JSON in $BASELINE_OUT and $PRESSURED_OUT"
        exit 0
    fi
    echo
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
            # run_name examples:
            #   "BM_Lookup_FlatMap/1024_median"                       (no modifiers)
            #   "BM_Lookup_FlatMap/1024/min_time:0.050_median"        (with in-code MinTime)
            # Extract benchmark name (before first /) and size
            # (after first /, stripped of everything from any
            # subsequent / and the trailing _median).
            bench="${name%%/*}"
            rest="${name#*/}"
            size=$(echo "$rest" | sed -E 's|/.*||; s|_median$||')
            ratio=$(awk -v b="$base" -v p="$press" 'BEGIN { if (b > 0) printf "%.2fx", p/b; else print "n/a" }')
            printf "%-38s %10s %12.1f %12.1f   %s\n" \
                   "$bench" "$size" "$base" "$press" "$ratio"
        done
    rm -f /tmp/demo-02-baseline.tsv /tmp/demo-02-pressured.tsv
    echo
    callout "What the numbers MEAN:" \
            "  • At small N everything fits in L1/L2 — layout is invisible." \
            "  • At N=262144 iterate: vector ≈ flat_map ≪ unordered_map ≪ map." \
            "    Contiguous data feeds the prefetcher one cache line (~64B) at" \
            "    a time; node-based data pays a cache miss per pointer hop." \
            "  • The Ratio column is the pressure tax. ~1.0x = contiguous pages" \
            "    stream back cleanly. 2-10x = the kernel evicts scattered nodes" \
            "    the container must fault back in — a cache miss becomes a page" \
            "    fault becomes a syscall. Layout decides who survives the cap."
    pause
fi

log_ok "Demo 02 complete — layout beats big-O at scale, and the gap widens under pressure."
if (( RUN_BASELINE )); then log_info "  baseline:  $BASELINE_OUT"; fi
if (( RUN_PRESSURED )); then log_info "  pressured: $PRESSURED_OUT"; fi
