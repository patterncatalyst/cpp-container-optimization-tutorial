#!/usr/bin/env bash
# Demo 7 — quality pipeline: cppcheck, clang-tidy, gtest, ASan+UBSan, abidiff, gdbserver.
#
#   ./demo.sh                # everything (analyze + test + asan + abi)
#   ./demo.sh --analyze-only
#   ./demo.sh --test-only
#   ./demo.sh --asan-only
#   ./demo.sh --abi-only
#   ./demo.sh --abi-bless    # promote reports/current.abi to abi-reference/
#                            #   (run --abi-only first to produce it)
#   ./demo.sh --debug        # spin up gdbserver sidecar
#   ./demo.sh --clean

set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DEMO_DIR"

# shellcheck source=../../scripts/lib/_helpers.sh
source "$(cd ../../scripts/lib && pwd)/_helpers.sh"

PHASES=(analyzer tests asan abi)
DO_DEBUG=0
DO_CLEAN=0
DO_ABI_BLESS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --analyze-only) PHASES=(analyzer);    shift;;
    --test-only)    PHASES=(tests);       shift;;
    --asan-only)    PHASES=(asan);        shift;;
    --abi-only)     PHASES=(abi);         shift;;
    --abi-bless)    DO_ABI_BLESS=1;       shift;;
    --debug)        DO_DEBUG=1;           shift;;
    --clean)        DO_CLEAN=1;           shift;;
    *) log_err "unknown arg: $1"; exit 2;;
  esac
done

if [[ $DO_CLEAN -eq 1 ]]; then
  podman compose -f compose.debug.yml down -v 2>/dev/null || true
  podman rmi -f \
    cpp-tut/demo-07:analyzer \
    cpp-tut/demo-07:tests \
    cpp-tut/demo-07:asan \
    cpp-tut/demo-07:abi \
    cpp-tut/demo-07:svc \
    cpp-tut/demo-07:gdbserver 2>/dev/null || true
  rm -rf reports
  log_ok "Cleaned."
  exit 0
fi

# --abi-bless: promote reports/current.abi to abi-reference/. This is the
# operational counterpart to --abi-only. After running --abi-only at least
# once to produce reports/current.abi, run --abi-bless to copy it into
# abi-reference/ as the new baseline. Future --abi-only runs will then
# diff against this baseline instead of just recording it.
#
# The committed baseline is what `abidiff` compares to inside the abi
# stage of the Containerfile. The workflow is:
#
#   1. ./demo.sh --abi-only       (produces reports/current.abi)
#   2. inspect reports/current.abi if you want to
#   3. ./demo.sh --abi-bless      (promotes it to abi-reference/)
#   4. git add abi-reference/ && git commit -m "abi: bless v1.0 baseline"
#
# After step 4, any header change that breaks ABI causes the abi stage
# to exit non-zero with abidiff's report.
if [[ $DO_ABI_BLESS -eq 1 ]]; then
  if [[ ! -f reports/current.abi ]]; then
    log_err "No reports/current.abi found. Run './demo.sh --abi-only' first."
    exit 1
  fi
  mkdir -p abi-reference
  cp -v reports/current.abi abi-reference/libdemo07_channel.so.1.abi
  log_ok "ABI reference updated."
  log_info "Next steps:"
  log_info "  git diff abi-reference/      # review what you're freezing"
  log_info "  git add  abi-reference/"
  log_info "  git commit -m \"abi: bless v1.0 baseline\""
  exit 0
fi

require podman
mkdir -p reports

# Generate a real conan lockfile if the checked-in stub still has the
# placeholder revision. This keeps first-run friction low while still
# pinning everything once the lockfile is regenerated.
#
# G-48 (r118): the checked-in conan.lock is a placeholder stub. On first
# run we truncate it to zero bytes so:
#   (a) the Containerfile's `COPY conan.lock` still finds a file to copy
#       (deletion would break that step), and
#   (b) the container's `[ -s conan.lock ]` test routes to the
#       fresh-resolve branch.
# G-50 (r120) handles the in-container companion: rm the empty file
# before `conan install` so conan's auto-discovery doesn't trip on it.
#
# We deliberately do NOT try to regenerate the lockfile on the host —
# the host's conan profile is unreliable (gcc version drift, stale
# profiles from prior `conan profile detect` runs, etc.). The container
# is the source of truth for the build environment, so let IT decide
# what versions to pin. After a successful build, the user can extract
# the real lockfile from the container layer and commit it.
if grep -q '%1700000000.0' conan.lock 2>/dev/null; then
  log_warn "conan.lock is a placeholder; container will resolve dependencies fresh"
  > conan.lock
fi

run_phase() {
  local phase="$1"
  log_step "Phase: $phase"
  # ASan's shadow-memory mapping can clash with the default build-time
  # seccomp profile on some hosts. Relax seccomp specifically for the
  # ASan stage so the in-stage `ctest` invocation can fire ASan's
  # mprotect/mmap pattern. See §12 "Runtime sanitizers in containers".
  local sec_opts=()
  if [[ "$phase" == "asan" ]]; then
    sec_opts+=(--security-opt seccomp=unconfined)
  fi
  podman build "${sec_opts[@]}" --target "$phase" -t "cpp-tut/demo-07:$phase" .
  # Pull the reports out of the image so the host sees them.
  local cid
  cid=$(podman create "cpp-tut/demo-07:$phase")
  podman cp "$cid:/src/reports/." reports/ 2>/dev/null || true
  podman rm -f "$cid" >/dev/null
  log_ok "$phase passed; reports under reports/"
}

for p in "${PHASES[@]}"; do
  run_phase "$p"
done

if [[ $DO_DEBUG -eq 1 ]]; then
  log_step "Bringing up gdbserver sidecar"
  podman compose -f compose.debug.yml up -d --build
  log_ok "gdbserver listening on 127.0.0.1:1234"
  log_info "  Connect with:"
  log_info "    podman cp demo07-svc:/app/demo07-svc /tmp/demo07-svc"
  log_info "    gdb -ex 'target remote 127.0.0.1:1234' /tmp/demo07-svc"
  log_info "  Tear down with:  ./demo.sh --clean"
fi

log_step "Reports"
ls -la reports/ 2>/dev/null || true
