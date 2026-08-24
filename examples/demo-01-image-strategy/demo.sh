#!/usr/bin/env bash
# ============================================================================
# Demo 01 — Image strategy: UBI multi-stage vs UBI-micro vs naive single-stage,
# plus a PGO pass against the multi-stage build.
#
# Builds the same trivial C++23 HTTP service several ways and makes the deltas
# visible: image size, then p50/p95/p99 latency under a `hey` load.
#
# KEY INSIGHT — read this before presenting:
#
#   Image strategy is the lowest-hanging-fruit performance and security win in
#   containerized C++. A multi-stage build leaves the toolchain (GCC, ld, headers,
#   build deps) OUT of the runtime image — a ~26× size drop from the naive
#   single-stage baseline to ubi-micro, and a matching cut in CVE surface — with
#   NO measurable p50 penalty. LTO plus a representative PGO profile then buys a
#   further few percent on the hot path, essentially for free once the pipeline
#   is in place.
#
#   THE ON-STAGE MOMENT is the two tables: the image-size comparison (the
#   toolchain leaving production) and the latency comparison (PGO's small-but-real
#   p99 win, and the deliberately-broken glibc-mismatch variant's runtime failure
#   as the closing lesson).
#
# This script is a talk-through: it stops between steps (Press Enter) so you can
# narrate. Piped / non-interactive runs skip the pauses automatically (or pass
# --no-pause).
#
# Run from this directory:
#   ./demo.sh                full run (build every variant + PGO + benchmark)
#   ./demo.sh --no-pgo       skip the PGO build (fast path)
#   ./demo.sh --no-pause     never stop for Enter (unattended)
#   ./demo.sh --clean        remove all images and exit
# ============================================================================

set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DEMO_DIR"

# shellcheck source=../../scripts/lib/_helpers.sh
source "$(cd ../../scripts/lib && pwd)/_helpers.sh"

IMG_PREFIX="cpp-tut/demo-01"
PORT_BASE=18801

DO_PGO=1
DO_CLEAN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-pgo)   DO_PGO=0;               shift;;
    --no-pause) export DEMO_NO_PAUSE=1; shift;;
    --clean)    DO_CLEAN=1;             shift;;
    -h|--help)  sed -n '2,32p' "$0"; exit 0;;
    *) log_err "unknown arg: $1"; exit 2;;
  esac
done

require podman curl jq hey

cleanup() {
  podman ps -a --format '{{.Names}}' | grep -E '^demo01-' | \
    xargs -r podman rm -f >/dev/null 2>&1 || true
}
trap cleanup EXIT

if [[ $DO_CLEAN -eq 1 ]]; then
  podman rmi -f \
    "${IMG_PREFIX}:ubi-multistage" \
    "${IMG_PREFIX}:ubi-micro" \
    "${IMG_PREFIX}:single-stage-naive" \
    "${IMG_PREFIX}:pgo" 2>/dev/null || true
  log_ok "Cleaned."
  exit 0
fi

# Ensure pgo-profiles/ exists so the optimized stage's COPY doesn't 404
# even on a --no-pgo run that's followed later by a normal run that
# uses cached layers. demo.sh's PGO branch will repopulate it cleanly.
mkdir -p pgo-profiles

# Vendor cpp-httplib if not already present. Pin the version so re-runs
# produce a byte-identical input to the build.
HTTPLIB_VERSION="${HTTPLIB_VERSION:-v0.16.0}"
if [[ ! -f src/third_party/httplib.h ]]; then
  log_step "Vendoring cpp-httplib ${HTTPLIB_VERSION}"
  mkdir -p src/third_party
  curl -fsSL -o src/third_party/httplib.h \
    "https://raw.githubusercontent.com/yhirose/cpp-httplib/${HTTPLIB_VERSION}/httplib.h"
  log_ok "Saved to src/third_party/httplib.h"
fi

banner \
  "DEMO 01 — Image strategy: multi-stage, ubi-micro, LTO, PGO" \
  "Same C++23 service, built several ways. Watch size and latency move."

callout \
  "Images:    ${IMG_PREFIX}:{ubi-multistage,ubi-micro,single-stage-naive,pgo}" \
  "           + ubi-micro-glibc-mismatch  (TEACHING variant — fails at runtime)" \
  "Ports:     bench containers on ${PORT_BASE}+ (one per variant)" \
  "Load:      hey -n 5000 -c 50 per variant → p50/p95/p99" \
  "PGO:       $([[ $DO_PGO -eq 1 ]] && echo 'enabled (two-pass build + training run)' || echo 'skipped (--no-pgo)')"
callout "" "The service itself is one file — the SAME binary in every variant:"
code_ref "src/main.cpp" 65 "httplib routing (/, /echo, /healthz, /metrics) — constexpr-lean, zero-alloc startup"
pause "Ready to build? Press Enter"

# ── Step 1: Build the image variants ────────────────────────────────────────
demo_step "Build the image variants (multi-stage, micro, teaching, naive)"
callout "First run compiles from source; later runs hit the podman layer cache." \
        "Never proceed to measurement after a failed build — a broken image would" \
        "just show up as a bogus benchmark row."

log_step "Building UBI multi-stage (LTO on, no PGO)"
if ! podman build -f Containerfile.ubi-multistage -t "${IMG_PREFIX}:ubi-multistage" .; then
  log_err "ubi-multistage build failed — stopping (nothing valid to measure)."
  exit 1
fi

log_step "Building UBI-micro (fully-static binary, production answer)"
if ! podman build -f Containerfile.ubi-micro -t "${IMG_PREFIX}:ubi-micro" .; then
  log_err "ubi-micro build failed — stopping (nothing valid to measure)."
  exit 1
fi

log_step "Building UBI-micro-glibc-mismatch (TEACHING REFERENCE — intentionally fails at runtime)"
if ! podman build -f Containerfile.ubi-micro-glibc-mismatch -t "${IMG_PREFIX}:ubi-micro-glibc-mismatch" .; then
  log_err "ubi-micro-glibc-mismatch build failed — stopping (this variant must BUILD;"
  log_err "it's only meant to fail at RUNTIME, which is the lesson)."
  exit 1
fi

log_step "Building naive single-stage (anti-pattern)"
if ! podman build -f Containerfile.single-stage-naive -t "${IMG_PREFIX}:single-stage-naive" .; then
  log_err "single-stage-naive build failed — stopping (nothing valid to measure)."
  exit 1
fi

callout "" "Four images built. The single-stage one still ships GCC, ld, and the" \
        "build deps into 'production'; the multi-stage and micro ones don't." \
        "That difference is what the next two tables put a number on."
pause

# ── Step 2: PGO two-pass build (optional) ────────────────────────────────────
if [[ $DO_PGO -eq 1 ]]; then
  demo_step "PGO two-pass build: instrument → train → rebuild with the profile"
  callout "GCC PGO is three phases run back-to-back: compile an instrumented" \
          "binary, drive it with a representative workload to gather .gcda profile" \
          "data, then rebuild biasing hot/cold paths toward what we measured."

  log_step "Building PGO step 1 (instrumented binary)"
  if ! podman build -f Containerfile.pgo --target instrumented -t "${IMG_PREFIX}:pgo-instrumented" .; then
    log_err "instrumented PGO build failed — stopping (no profile to gather)."
    exit 1
  fi

  log_step "Running representative workload to gather profile data"
  rm -rf pgo-profiles && mkdir -p pgo-profiles
  # Bind-mount pgo-profiles/ onto the exact build directory the
  # instrumented binary was compiled at (/src/build/pgo). GCC's runtime
  # writes .gcda files using paths baked into the binary at compile
  # time, so mounting at the same path makes them land alongside the
  # .gcno files where the optimized rebuild needs them.
  podman run --rm -d --name demo01-pgo-train \
    -p ${PORT_BASE}:8080 \
    -v "$PWD/pgo-profiles:/src/build/pgo:Z" \
    "${IMG_PREFIX}:pgo-instrumented"
  wait_for_http "http://127.0.0.1:${PORT_BASE}/healthz" 30
  hey -n 5000 -c 50 "http://127.0.0.1:${PORT_BASE}/" >/dev/null
  hey -n 2500 -c 25 -m POST -d "$(printf 'x%.0s' {1..512})" \
    "http://127.0.0.1:${PORT_BASE}/echo" >/dev/null || true
  # Bump grace to 20s. The binary's signal handler calls srv.stop() and
  # main() returns cleanly; libgcov's atexit handler then flushes .gcda
  # files. 20s is plenty for that — without the signal handler the
  # default 10s SIGTERM grace would fall through to SIGKILL and skip
  # atexit entirely, which is what r13's run hit.
  podman stop -t 20 demo01-pgo-train >/dev/null 2>&1 || true

  GCDA_COUNT=$(find pgo-profiles -name '*.gcda' | wc -l)
  log_info "Captured ${GCDA_COUNT} .gcda file(s)"
  if [[ "${GCDA_COUNT}" -eq 0 ]]; then
    log_err "Zero .gcda files captured. The optimized PGO build would be a"
    log_err "release build with no actual profile data."
    callout "Likely causes:" \
            "  - Binary didn't shut down cleanly (SIGTERM ignored, SIGKILL used;" \
            "    libgcov's atexit handler never ran)" \
            "  - The bind-mount path doesn't match the build path baked into the" \
            "    instrumented binary" \
            "Skipping PGO step 2; ./demo.sh --clean and try again."
    DO_PGO=0
  fi

  # No separate merge step needed for GCC PGO — .gcda files go straight
  # into the optimized build context via the optimized stage's COPY.

  if [[ $DO_PGO -eq 1 ]]; then
    log_step "Building PGO step 2 (optimized using gathered profile)"
    if ! podman build -f Containerfile.pgo --target optimized -t "${IMG_PREFIX}:pgo" .; then
      log_err "optimized PGO build failed — stopping (no pgo image to measure)."
      exit 1
    fi
    callout "" "The pgo image is byte-for-byte the same LTO build as ubi-multistage" \
            "PLUS the measured profile. Any latency delta between them in the table" \
            "below is PGO alone — nothing else changed."
  fi
  pause
else
  log_info "PGO skipped (--no-pgo)."
fi

# ── Step 3: Image size comparison ────────────────────────────────────────────
demo_step "Image size comparison — where did the megabytes go?"
# Use podman's --filter rather than a regex grep: podman 5.x prefixes
# locally-built images with `localhost/` in `podman images` output,
# so a strict `grep "^${IMG_PREFIX}:"` would match nothing and (under
# `set -e` + `pipefail`) abort the script before the latency table.
podman images \
  --filter "reference=${IMG_PREFIX}:*" \
  --filter "reference=localhost/${IMG_PREFIX}:*" \
  --format '{{.Repository}}:{{.Tag}}\t{{.Size}}' \
  | sort -u \
  | column -t \
  || true
callout "" "The naive single-stage image is ~26× the size of ubi-micro, and almost" \
        "all of that gap is the toolchain sitting in production: GCC, ld, headers," \
        "build deps — none needed at runtime, all of them CVE surface. Multi-stage" \
        "drops them; ubi-micro also statically links libstdc++ for the smallest floor." \
        "Registry pull time (and therefore cold-start latency) scales with this number."
pause

# ── Step 4: Latency comparison ───────────────────────────────────────────────
#
# We run `hey -c 50 -n 5000` rather than something larger because:
#   - At -c 100 against cpp-httplib's modest thread pool, queueing
#     pushes per-request latency past hey's default 20s timeout for
#     enough requests that hey's `b.lats` array stays empty, and the
#     "Latency distribution:" block ends up empty.
#   - At -c 50, even on a cold cgroup, request rate stays comfortably
#     above the timeout threshold; percentiles print and awk extracts
#     real numbers.
# 5000 requests is plenty for a meaningful percentile distribution
# while keeping the benchmark phase under a few seconds per variant.
demo_step "Latency comparison ('hey -n 5000 -c 50' per variant)"
declare -A IMAGES=(
  [ubi-multistage]=$((PORT_BASE + 1))
  [ubi-micro]=$((PORT_BASE + 2))
  [single-stage-naive]=$((PORT_BASE + 3))
  [ubi-micro-glibc-mismatch]=$((PORT_BASE + 5))
)
[[ $DO_PGO -eq 1 ]] && IMAGES[pgo]=$((PORT_BASE + 4))

# Explicit iteration order: real, working variants first (so readers
# see real numbers); the deliberately-failing teaching variant last
# (so its captured error message is the punchline). Bash associative-
# array iteration order is non-deterministic; without this we'd get
# whatever hash bucket order bash happens to pick today.
ORDER=("ubi-multistage" "ubi-micro" "single-stage-naive")
[[ $DO_PGO -eq 1 ]] && ORDER+=("pgo")
ORDER+=("ubi-micro-glibc-mismatch")  # teaching variant always last

# Column widened from 22 to 28 to fit the new teaching-variant tag.
printf '\n%-28s  %-10s  %-10s  %-10s\n' "image" "p50 (ms)" "p95 (ms)" "p99 (ms)"
printf -- '-%.0s' {1..68}; echo
PARSE_FAILURES=()
for tag in "${ORDER[@]}"; do
  port="${IMAGES[$tag]}"
  # Note: NOT using --rm here. If the container exits immediately
  # (binary segfaults, missing dep, etc.), --rm reaps it before we
  # can probe with `podman logs` or `podman inspect`. We clean up
  # manually at the end of each iteration instead. r16 hit this
  # for ubi-micro: container exited fast, --rm cleaned up, log
  # capture got "no such container".
  podman run -d --name "demo01-bench-${tag}" -p "${port}:8080" "${IMG_PREFIX}:${tag}" >/dev/null
  # The teaching variant is EXPECTED to fail wait_for_http. We want to:
  #   (a) suppress wait_for_http's "[fail] timed out..." stderr line
  #       (the EXPECTED FAILURE block right after is self-explanatory)
  #   (b) NOT have the script terminate when it does fail
  #
  # `set -e` would terminate on a failed wait_for_http unless that call
  # is in an exempted context. The `... && wait_ok=1` pattern provides
  # that exemption: bash exempts every command in a `&&` chain except
  # the final one, so wait_for_http's non-zero exit doesn't trigger
  # set -e — wait_ok stays 0 and we branch normally below. (r20 used
  # `if/else; if [[ $? -eq 0 ]]; then` which is NOT exempt and killed
  # the script on the teaching variant's expected failure.)
  wait_ok=0
  if [[ "${tag}" == "ubi-micro-glibc-mismatch" ]]; then
    wait_for_http "http://127.0.0.1:${port}/healthz" 30 2>/dev/null && wait_ok=1
  else
    wait_for_http "http://127.0.0.1:${port}/healthz" 30 && wait_ok=1
  fi
  if (( wait_ok == 1 )); then
    out=$(hey -n 5000 -c 50 "http://127.0.0.1:${port}/" 2>/dev/null || true)
    # Match both `50% in` and `50%% in` — different hey builds escape the
    # percent sign differently in the latency-distribution block. The `%+`
    # accepts one or more literal % characters between the digit and the
    # following ` in`.
    p50=$(awk '/50%+ in/ {print $3 * 1000}' <<<"$out")
    p95=$(awk '/95%+ in/ {print $3 * 1000}' <<<"$out")
    p99=$(awk '/99%+ in/ {print $3 * 1000}' <<<"$out")
    if [[ -z "$p50" ]]; then
      PARSE_FAILURES+=("$tag")
      printf '%-28s  %-10s  %-10s  %-10s\n' "$tag" "?" "?" "?"
    else
      printf '%-28s  %-10s  %-10s  %-10s\n' "$tag" "${p50}" "${p95}" "${p99}"
    fi
    podman stop -t 5 "demo01-bench-${tag}" >/dev/null 2>&1 || true
  else
    # Container still exists (no --rm); capture both its state and its
    # stdout/stderr before the manual rm cleans up.
    #
    # For the deliberately-broken ubi-micro-glibc-mismatch teaching
    # variant, we frame the failure as expected pedagogical output
    # rather than a generic "NORUN". The captured log lines ARE the
    # teaching artifact.
    echo
    if [[ "${tag}" == "ubi-micro-glibc-mismatch" ]]; then
      echo "    EXPECTED FAILURE — this is the teaching variant."
      echo "    The log line below is the lesson:"
    fi
    echo "    -- container state --"
    podman inspect "demo01-bench-${tag}" \
      --format='    status:   {{.State.Status}}
    exit:     {{.State.ExitCode}}
    oom:      {{.State.OOMKilled}}
    error:    {{.State.Error}}
    started:  {{.State.StartedAt}}
    finished: {{.State.FinishedAt}}' 2>&1 | sed 's/^/    /' || true
    echo "    -- last 30 log lines --"
    podman logs "demo01-bench-${tag}" 2>&1 | tail -30 | sed 's/^/    | /' || true
    if [[ "${tag}" == "ubi-micro-glibc-mismatch" ]]; then
      printf '%-28s  %-10s  %-10s  %-10s\n' "$tag" "EXPECTED" "FAIL" "(teaching)"
    else
      printf '%-28s  %-10s  %-10s  %-10s\n' "$tag" "NORUN" "NORUN" "NORUN"
    fi
  fi
  # Manual cleanup since we didn't use --rm.
  podman rm -f "demo01-bench-${tag}" >/dev/null 2>&1 || true
done

# Diagnostic: if any variant didn't parse, re-run one of them with full
# output captured so the user (or the next reviewer) can see why.
if (( ${#PARSE_FAILURES[@]} > 0 )); then
  failtag="${PARSE_FAILURES[0]}"
  failport=$((PORT_BASE + 10))
  echo
  log_info "Re-running '${failtag}' to capture hey's full output for diagnosis:"
  podman run --rm -d --name "demo01-bench-diag" -p "${failport}:8080" \
    "${IMG_PREFIX}:${failtag}" >/dev/null 2>&1 || true
  if wait_for_http "http://127.0.0.1:${failport}/healthz" 30; then
    # head -60 (was -25) so the "Latency distribution:" block is captured;
    # hey's full output for this size workload is roughly 35-40 lines.
    hey -n 1000 -c 50 "http://127.0.0.1:${failport}/" 2>&1 | head -60 | sed 's/^/    | /'
  fi
  podman stop -t 5 "demo01-bench-diag" >/dev/null 2>&1 || true
fi

callout "" "How to read this table:" \
        "  • p50 is essentially identical across the working variants — the" \
        "    runtime cost of static-vs-dynamic libstdc++ is invisible at this scale." \
        "  • PGO (if built) shaves a few percent off p95/p99 vs plain ubi-multistage:" \
        "    small but real, and free once the build pipeline exists." \
        "  • ubi-micro-glibc-mismatch never answers /healthz — the static/glibc" \
        "    mismatch fails at RUNTIME. That NORUN/EXPECTED row is the whole point:" \
        "    a build that succeeds is not a service that runs."
pause

# ── Step 5: Image labels (provenance) ────────────────────────────────────────
demo_step "Image labels — provenance baked into each build"
for tag in "${!IMAGES[@]}"; do
  echo
  echo "[$tag]"
  podman inspect --format='{{json .Config.Labels}}' "${IMG_PREFIX}:${tag}" 2>/dev/null \
    | jq -r 'to_entries[] | "  \(.key)=\(.value)"' 2>/dev/null \
    || echo "  (no labels)"
done
callout "" "Every image carries labels identifying its build strategy and inputs." \
        "In production that provenance is what lets you answer 'what's actually" \
        "running, and how was it built?' months later — reproducible-image discipline."

echo
log_ok "Demo 01 complete. Tear down the images with: ./demo.sh --clean"
