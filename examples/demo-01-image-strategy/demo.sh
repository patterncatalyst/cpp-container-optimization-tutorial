#!/usr/bin/env bash
# Demo 1 — image strategy: UBI multi-stage vs UBI-micro vs naive single-stage,
# plus a PGO pass against the multi-stage build.
#
# Run from this directory:
#   ./demo.sh [--no-pgo]  # skip the PGO build (fast path)
#   ./demo.sh --clean     # remove all images and exit

set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DEMO_DIR"

# shellcheck source=../../scripts/lib/_helpers.sh
source "$(cd ../../scripts/lib && pwd)/_helpers.sh"

require podman curl jq hey

IMG_PREFIX="cpp-tut/demo-01"
PORT_BASE=18801

# Local color/header/note kept for backwards-compat with the script's
# original output style; helpers are used for the new functionality
# (require, wait_for_http) only.
color() { printf '\033[%sm%s\033[0m' "$1" "$2"; }
header() { echo; echo "$(color '1;34' "==> $*")"; }
note() { echo "    $*"; }

cleanup() {
  podman ps -a --format '{{.Names}}' | grep -E '^demo01-' | \
    xargs -r podman rm -f >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Ensure pgo-profiles/ exists so the optimized stage's COPY doesn't 404
# even on a --no-pgo run that's followed later by a normal run that
# uses cached layers. demo.sh's PGO branch will repopulate it cleanly.
mkdir -p pgo-profiles

# Vendor cpp-httplib if not already present. Pin the version so re-runs
# produce a byte-identical input to the build.
HTTPLIB_VERSION="${HTTPLIB_VERSION:-v0.16.0}"
if [[ ! -f src/third_party/httplib.h ]]; then
  header "Vendoring cpp-httplib ${HTTPLIB_VERSION}"
  mkdir -p src/third_party
  curl -fsSL -o src/third_party/httplib.h \
    "https://raw.githubusercontent.com/yhirose/cpp-httplib/${HTTPLIB_VERSION}/httplib.h"
  note "Saved to src/third_party/httplib.h"
fi

case "${1:-}" in
  --clean)
    podman rmi -f \
      "${IMG_PREFIX}:ubi-multistage" \
      "${IMG_PREFIX}:ubi-micro" \
      "${IMG_PREFIX}:single-stage-naive" \
      "${IMG_PREFIX}:pgo" 2>/dev/null || true
    echo "Cleaned."
    exit 0
    ;;
esac

DO_PGO=1
[[ "${1:-}" == "--no-pgo" ]] && DO_PGO=0

# ---------------------------------------------------------------------
header "Building UBI multi-stage (LTO on, no PGO)"
podman build -f Containerfile.ubi-multistage -t "${IMG_PREFIX}:ubi-multistage" .

header "Building UBI-micro (fully-static binary, production answer)"
podman build -f Containerfile.ubi-micro -t "${IMG_PREFIX}:ubi-micro" .

header "Building UBI-micro-glibc-mismatch (TEACHING REFERENCE — intentionally fails at runtime)"
podman build -f Containerfile.ubi-micro-glibc-mismatch -t "${IMG_PREFIX}:ubi-micro-glibc-mismatch" .

header "Building naive single-stage (anti-pattern)"
podman build -f Containerfile.single-stage-naive -t "${IMG_PREFIX}:single-stage-naive" .

if [[ $DO_PGO -eq 1 ]]; then
  header "Building PGO step 1 (instrumented binary)"
  podman build -f Containerfile.pgo --target instrumented -t "${IMG_PREFIX}:pgo-instrumented" .

  header "Running representative workload to gather profile data"
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
  note "Captured ${GCDA_COUNT} .gcda file(s)"
  if [[ "${GCDA_COUNT}" -eq 0 ]]; then
    echo
    echo "$(color '1;31' "ERROR")  Zero .gcda files captured. The optimized PGO build"
    echo "       would be a release build with no actual profile data."
    echo "       Likely causes:"
    echo "       - Binary didn't shut down cleanly (SIGTERM ignored, SIGKILL"
    echo "         used; libgcov's atexit handler never ran)"
    echo "       - The bind-mount path doesn't match the build path baked"
    echo "         into the instrumented binary"
    echo "       Skipping PGO step 2; ./demo.sh --clean and try again."
    DO_PGO=0
  fi

  # No separate merge step needed for GCC PGO — .gcda files go straight
  # into the optimized build context via the optimized stage's COPY.

  if [[ $DO_PGO -eq 1 ]]; then
    header "Building PGO step 2 (optimized using gathered profile)"
    podman build -f Containerfile.pgo --target optimized -t "${IMG_PREFIX}:pgo" .
  fi
fi

# ---------------------------------------------------------------------
header "Image size comparison"
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

# ---------------------------------------------------------------------
# Latency benchmark
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
header "Latency comparison ('hey -n 5000 -c 50')"
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
  # The teaching variant is EXPECTED to fail wait_for_http; suppress
  # wait_for_http's "[fail] timed out..." stderr line for that one
  # variant so it doesn't read as an unexpected error in the output.
  # Other variants keep the normal error path so real failures show.
  if [[ "${tag}" == "ubi-micro-glibc-mismatch" ]]; then
    wait_for_http "http://127.0.0.1:${port}/healthz" 30 2>/dev/null
  else
    wait_for_http "http://127.0.0.1:${port}/healthz" 30
  fi
  if [[ $? -eq 0 ]]; then
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
  note "Re-running '${failtag}' to capture hey's full output for diagnosis:"
  podman run --rm -d --name "demo01-bench-diag" -p "${failport}:8080" \
    "${IMG_PREFIX}:${failtag}" >/dev/null 2>&1 || true
  if wait_for_http "http://127.0.0.1:${failport}/healthz" 30; then
    # head -60 (was -25) so the "Latency distribution:" block is captured;
    # hey's full output for this size workload is roughly 35-40 lines.
    hey -n 1000 -c 50 "http://127.0.0.1:${failport}/" 2>&1 | head -60 | sed 's/^/    | /'
  fi
  podman stop -t 5 "demo01-bench-diag" >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------
header "Image labels (provenance for each build)"
for tag in "${!IMAGES[@]}"; do
  echo
  echo "[$tag]"
  podman inspect --format='{{json .Config.Labels}}' "${IMG_PREFIX}:${tag}" 2>/dev/null \
    | jq -r 'to_entries[] | "  \(.key)=\(.value)"' 2>/dev/null \
    || echo "  (no labels)"
done

echo
header "Done"
note "Tear down with: ./demo.sh --clean"
