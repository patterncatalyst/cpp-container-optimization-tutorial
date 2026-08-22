#!/usr/bin/env bash
# ============================================================================
# Demo 06 — Memory Management & Allocators (batch mode comparison)
#
# One C++23 binary, built three ways — std::allocator, std::pmr
# (monotonic_buffer_resource + sync_pool fallback), and mimalloc — run
# back-to-back on the SAME synthetic allocator-stress workload inside one
# container. We parse the per-variant JSON and print a min/p50/p99/max
# comparison table.
#
# KEY INSIGHT — read this before presenting:
#
#   Allocator choice is one of the largest — and least-measured —
#   performance levers in a C++ service. But "performance" is not a
#   scalar. Batch mode (this script) is the cleanest possible signal:
#   a tight loop, no HTTP, no threads, arena hot in cache. PMR's
#   bump-allocator can win p50 by ~50% here. Serve mode (compose-serve.yml)
#   and observe mode (compose-observe.yml) tell a DIFFERENT story — under
#   sustained request handling the arena gets evicted and PMR's advantage
#   shrinks. Same allocators, different verdict. That gap IS the lesson.
#
#   THE CORRECTNESS ANCHOR: all three variants must produce the SAME
#   result_hash. Allocator choice is supposed to be invisible to results —
#   only the timings move. If the hashes disagree, the numbers are
#   meaningless and there's a bug (almost always in the PMR path).
#
# This script is a talk-through: it stops between steps (Press Enter) so
# you can narrate. Piped / non-interactive runs skip the pauses
# automatically (or pass --no-pause).
#
# Usage:
#   ./demo.sh                         full run (build + 200 iters/variant)
#   ./demo.sh --iterations 1000       custom iteration count
#   ./demo.sh --depth 8 --branch 5    bigger trees
#   ./demo.sh --values 12             more ints per node
#   ./demo.sh --no-pause              never stop for Enter (unattended)
#   ./demo.sh --clean                 remove the image and exit
# ============================================================================

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

# shellcheck source=../../scripts/lib/_helpers.sh
source "$(cd ../../scripts/lib && pwd)/_helpers.sh"

IMAGE="cpp-tut/demo-06:latest"

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
        --no-pause)    export DEMO_NO_PAUSE=1; shift ;;
        --clean)       CLEAN_ONLY=1;    shift ;;
        -h|--help)     sed -n '2,35p' "$0"; exit 0 ;;
        *) log_err "unknown arg: $1"; exit 2 ;;
    esac
done

if (( CLEAN_ONLY )); then
    podman image rm "$IMAGE" 2>/dev/null || true
    log_ok "Cleaned."
    exit 0
fi

require podman
HAVE_JQ=1; command -v jq >/dev/null 2>&1 || HAVE_JQ=0

banner \
  "DEMO 06 — Memory Management & Allocators (batch mode)" \
  "One workload, three allocators. Same result, different cost."

callout \
  "Image:      $IMAGE" \
  "Variants:   std::allocator · std::pmr (monotonic+sync_pool) · mimalloc" \
  "Workload:   synthetic JSON-shaped tree builder (many small allocs)" \
  "Config:     iterations=$ITERATIONS depth=$DEPTH branch=$BRANCH values=$VALUES"

# ── Step 1: Build the 3-variant image ───────────────────────────────────────
demo_step "Build the 3-variant image"
callout "First run compiles all three variants (~3-5 min on a clean cache)." \
        "mimalloc's CMake build is fast; cached rebuilds are ~30s (app only)."
if ! podman build -t "$IMAGE" -f Containerfile .; then
    log_err "podman build failed — nothing to compare. Stopping here."
    exit 1
fi
log_ok "Image built: $IMAGE"
pause

# ── Step 2: Run all three variants back-to-back ─────────────────────────────
demo_step "Run all three variants (batch mode, in one container)"
callout "All three binaries run in sequence in ONE container, on the SAME" \
        "deterministic workload. Batch mode is the cleanest signal: a tight" \
        "loop, no HTTP overhead, no network jitter, arena hot in cache." \
        "" \
        "stderr ([demo06] init lines) stays on the terminal so you can see" \
        "each variant announce itself; stdout (the JSON) is what we parse."
echo
# Capture stdout. stderr goes to terminal so the [demo06] init lines
# are visible (helpful when something goes wrong).
if ! results_json=$(podman run --rm \
        -e ITERATIONS="$ITERATIONS" \
        -e DEPTH="$DEPTH" \
        -e BRANCH="$BRANCH" \
        -e VALUES="$VALUES" \
        "$IMAGE"); then
    log_err "podman run failed — the workload did not complete."
    exit 1
fi
log_ok "All three variants completed"
pause

# ── Step 3: Parse + tabulate the comparison ─────────────────────────────────
demo_step "Compare: min / p50 / p99 / max / throughput"

if [[ $HAVE_JQ -eq 0 ]]; then
    log_warn "jq not installed — showing raw JSON (install jq for the table)."
    echo "$results_json"
    log_ok "Demo 06 complete (raw output shown)."
    exit 0
fi

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

# ── Step 4: Interpret the numbers + the correctness anchor ──────────────────
demo_step "What the deltas MEAN (and the hash that proves it's fair)"

# Sanity: all variants should produce the same hash. Allocator choice is
# supposed to be invisible to results; a differing hash is a correctness
# bug (most likely in build_tree's PMR path).
unique_hashes=$(echo "$results_json" | jq -r .result_hash | sort -u)
hash_count=$(echo "$unique_hashes" | wc -l)
echo
if (( hash_count == 1 )); then
    log_ok "All three variants produced the SAME hash ($unique_hashes)"
    callout \
      "That single matching hash is the whole point: every variant did" \
      "byte-for-byte identical work. Only the allocator — and therefore" \
      "only the timings — changed. The comparison is fair." \
      "" \
      "Reading the timings:" \
      "  • PMR usually wins p50 — its bump allocator does ~zero work per" \
      "    alloc; the win scales with how much time was spent in malloc." \
      "  • PMR often LOSES on max/p99 — the arena reset is amortized work" \
      "    that shows up as an occasional spike. Not a free lunch." \
      "  • mimalloc ≈ std::allocator here — expected. Its wins are in" \
      "    multi-threaded, long-lived, large-allocation workloads, none of" \
      "    which this single-threaded short-lived tree builder exercises." \
      "" \
      "Performance is not a scalar: p50 and p99 can disagree on a winner."
else
    log_err "Variants produced DIFFERENT hashes — the comparison is invalid:"
    echo "$unique_hashes" | sed 's/^/    /'
    callout \
      "Allocator differences are supposed to be invisible at this layer." \
      "A differing hash means a real bug — investigate workload.cpp's PMR" \
      "path (allocator-extended copy/move constructors are the usual culprit)."
fi
pause

# ── Step 5: Where to go next ─────────────────────────────────────────────────
demo_step "Next: the same binaries under real load"
callout \
  "Batch mode is one story. The same three binaries also serve HTTP, so" \
  "you can see how the verdict changes under sustained request handling:" \
  "" \
  "  Serve mode (load-test with hey/wrk/curl on ports 18601/02/03):" \
  "    podman compose -f compose-serve.yml up --build" \
  "" \
  "  Observe mode (serve + OpenTelemetry → Grafana LGTM):" \
  "    podman compose \\" \
  "      -f compose-serve.yml \\" \
  "      -f compose-observe.yml \\" \
  "      -f ../../observability/compose.yml \\" \
  "      up --build" \
  "" \
  "PMR's batch-mode p50 advantage typically SHRINKS in serve mode — the" \
  "1 MB thread_local arena gets evicted between requests. Same allocator," \
  "different verdict. See the README for the full walkthrough."

echo
log_ok "Demo 06 complete — batch comparison done, image left in place."
log_info "  Re-run with different sizes: ./demo.sh --iterations 1000 --depth 8"
log_info "  Remove the image:           ./demo.sh --clean"
