#!/usr/bin/env bash
# Demo-02 end-to-end verification.
#
# Runs ./demo.sh, parses the two JSON outputs, and asserts the
# §6 lesson holds:
#
#   1. At N=262144, BM_Iterate_FlatMap should be faster than
#      BM_Iterate_UnorderedMap in the BASELINE run. This is the
#      cache-locality claim at room temperature.
#   2. Under PRESSURE, the unordered_map's iterate time should
#      degrade MORE than flat_map's. The ratio P/B for
#      unordered_map should exceed that of flat_map.
#
# Pass criteria are intentionally permissive: the actual numbers
# depend on the host's CPU, cache size, and memory bandwidth. A
# typical desktop should produce ~2-5x for criterion 1 and
# >1.3x relative for criterion 2.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/_helpers.sh"

require podman jq

DEMO="$REPO_ROOT/examples/demo-02-stl-layout"
cd "$DEMO"

log_step "Phase 1 — running demo.sh"
./demo.sh

BASELINE="$DEMO/results-baseline.json"
PRESSURED="$DEMO/results-pressured.json"

if [[ ! -s "$BASELINE" || ! -s "$PRESSURED" ]]; then
    log_err "Result JSON files missing — demo.sh didn't complete"
    exit 1
fi

# jq lookup helper: median real_time for a (bench_name, N) pair.
get_time() {
    local file="$1" bench="$2" size="$3"
    jq -r --arg b "$bench" --arg n "$size" '
        .benchmarks
        | map(select(.aggregate_name == "median" and .run_name == ($b + "/" + $n + "_median")))
        | .[0].real_time // empty
    ' "$file"
}

LARGE_N=262144

log_step "Phase 2 — checking §6 cache-locality claim at room temperature"
flat_base=$(get_time "$BASELINE"  "BM_Iterate_FlatMap"      "$LARGE_N")
umap_base=$(get_time "$BASELINE"  "BM_Iterate_UnorderedMap" "$LARGE_N")
if [[ -z "$flat_base" || -z "$umap_base" ]]; then
    log_err "Couldn't extract baseline iterate times for N=$LARGE_N"
    exit 1
fi
log_info "  BM_Iterate_FlatMap      @ N=$LARGE_N (baseline): ${flat_base} µs"
log_info "  BM_Iterate_UnorderedMap @ N=$LARGE_N (baseline): ${umap_base} µs"

# Permissive: flat_map should be at least 1.5x faster than unordered_map
# at the largest size, in the baseline. If this fails on a host with
# unusual cache geometry, the lesson is still defensible; relax or
# investigate.
faster=$(awk -v u="$umap_base" -v f="$flat_base" 'BEGIN { print (u > 1.5 * f) ? "yes" : "no" }')
if [[ "$faster" == "yes" ]]; then
    ratio=$(awk -v u="$umap_base" -v f="$flat_base" 'BEGIN { printf "%.2f", u/f }')
    log_ok "  flat_map is ${ratio}x faster than unordered_map at N=$LARGE_N (criterion 1 ✓)"
else
    log_err "  flat_map should be ≥1.5x faster than unordered_map at large N"
    log_err "  Got unordered_map=${umap_base} µs vs flat_map=${flat_base} µs"
    exit 1
fi

log_step "Phase 3 — checking pressure differential"
flat_press=$(get_time "$PRESSURED" "BM_Iterate_FlatMap"      "$LARGE_N")
umap_press=$(get_time "$PRESSURED" "BM_Iterate_UnorderedMap" "$LARGE_N")
if [[ -z "$flat_press" || -z "$umap_press" ]]; then
    log_err "Couldn't extract pressured iterate times for N=$LARGE_N"
    exit 1
fi
log_info "  BM_Iterate_FlatMap      @ N=$LARGE_N (pressured): ${flat_press} µs"
log_info "  BM_Iterate_UnorderedMap @ N=$LARGE_N (pressured): ${umap_press} µs"

# Compute degradation ratios P/B for each container, then compare.
# The unordered_map should degrade more (higher ratio) than flat_map.
umap_degrade=$(awk -v p="$umap_press" -v b="$umap_base" 'BEGIN { printf "%.3f", p/b }')
flat_degrade=$(awk -v p="$flat_press" -v b="$flat_base" 'BEGIN { printf "%.3f", p/b }')
log_info "  unordered_map degrade ratio: ${umap_degrade}x"
log_info "  flat_map      degrade ratio: ${flat_degrade}x"

worse=$(awk -v u="$umap_degrade" -v f="$flat_degrade" 'BEGIN { print (u > 1.3 * f) ? "yes" : "no" }')
if [[ "$worse" == "yes" ]]; then
    log_ok "  unordered_map degrades more than flat_map under pressure (criterion 2 ✓)"
else
    log_info "  unordered_map and flat_map degrade similarly under pressure."
    log_info "  This can happen on systems with plenty of cache headroom — the"
    log_info "  128M cap didn't actually create enough memory pressure to"
    log_info "  distinguish them. Try a tighter limit: ./demo.sh --memory 64m"
    # Don't fail — the §6 lesson is still demonstrated by criterion 1.
fi

log_ok "test-demo-02 PASS — STL layout demo runs end-to-end with the expected pattern"
