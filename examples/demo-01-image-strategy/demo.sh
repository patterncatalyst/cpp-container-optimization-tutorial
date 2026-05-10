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

header "Building UBI-micro (small UBI runtime, static libstdc++)"
podman build -f Containerfile.ubi-micro -t "${IMG_PREFIX}:ubi-micro" .

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
  podman stop demo01-pgo-train >/dev/null
  note "Captured $(find pgo-profiles -name '*.gcda' | wc -l) .gcda file(s)"

  # No separate merge step needed for GCC PGO — .gcda files go straight
  # into the optimized build context via the optimized stage's COPY.

  header "Building PGO step 2 (optimized using gathered profile)"
  podman build -f Containerfile.pgo --target optimized -t "${IMG_PREFIX}:pgo" .
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
header "Latency comparison ('hey -n 10000 -c 100')"
declare -A IMAGES=(
  [ubi-multistage]=$((PORT_BASE + 1))
  [ubi-micro]=$((PORT_BASE + 2))
  [single-stage-naive]=$((PORT_BASE + 3))
)
[[ $DO_PGO -eq 1 ]] && IMAGES[pgo]=$((PORT_BASE + 4))

printf '\n%-22s  %-10s  %-10s  %-10s\n' "image" "p50 (ms)" "p95 (ms)" "p99 (ms)"
printf -- '-%.0s' {1..62}; echo
for tag in "${!IMAGES[@]}"; do
  port="${IMAGES[$tag]}"
  podman run --rm -d --name "demo01-bench-${tag}" -p "${port}:8080" "${IMG_PREFIX}:${tag}" >/dev/null
  if wait_for_http "http://127.0.0.1:${port}/healthz" 20; then
    out=$(hey -n 10000 -c 100 "http://127.0.0.1:${port}/" 2>/dev/null || true)
    p50=$(awk '/50% in/ {print $3 * 1000}' <<<"$out")
    p95=$(awk '/95% in/ {print $3 * 1000}' <<<"$out")
    p99=$(awk '/99% in/ {print $3 * 1000}' <<<"$out")
    printf '%-22s  %-10s  %-10s  %-10s\n' "$tag" "${p50:-?}" "${p95:-?}" "${p99:-?}"
  else
    printf '%-22s  %-10s  %-10s  %-10s\n' "$tag" "NORUN" "NORUN" "NORUN"
  fi
  podman stop "demo01-bench-${tag}" >/dev/null 2>&1 || true
done

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
