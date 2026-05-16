#!/usr/bin/env bash
# Demo 6 — quality pipeline: cppcheck, clang-tidy, gtest, abidiff, gdbserver.
#
#   ./demo.sh                # everything
#   ./demo.sh --analyze-only
#   ./demo.sh --test-only
#   ./demo.sh --abi-only
#   ./demo.sh --debug        # spin up gdbserver sidecar
#   ./demo.sh --clean

set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DEMO_DIR"

# shellcheck source=../../scripts/lib/_helpers.sh
source "$(cd ../../scripts/lib && pwd)/_helpers.sh"

PHASES=(analyze test abi)
DO_DEBUG=0
DO_CLEAN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --analyze-only) PHASES=(analyze);     shift;;
    --test-only)    PHASES=(test);        shift;;
    --abi-only)     PHASES=(abi);         shift;;
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
    cpp-tut/demo-07:abi \
    cpp-tut/demo-07:svc \
    cpp-tut/demo-07:gdbserver 2>/dev/null || true
  rm -rf reports
  log_ok "Cleaned."
  exit 0
fi

require podman
mkdir -p reports

# Generate a real conan lockfile if the checked-in stub still has the
# placeholder revision. This keeps first-run friction low while still
# pinning everything once the lockfile is regenerated.
if grep -q '%1700000000.0' conan.lock 2>/dev/null; then
  log_warn "conan.lock contains placeholder revisions; regenerating"
  if command -v conan >/dev/null 2>&1; then
    conan profile detect --force >/dev/null 2>&1 || true
    conan lock create . --lockfile-out=conan.lock -s build_type=RelWithDebInfo
  else
    log_warn "conan not on host; the build container will install it"
  fi
fi

run_phase() {
  local phase="$1"
  log_step "Phase: $phase"
  podman build --target "$phase" -t "cpp-tut/demo-07:$phase" .
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
  log_info "    podman cp demo06-svc:/app/demo06-svc /tmp/demo06-svc"
  log_info "    gdb -ex 'target remote 127.0.0.1:1234' /tmp/demo06-svc"
  log_info "  Tear down with:  ./demo.sh --clean"
fi

log_step "Reports"
ls -la reports/ 2>/dev/null || true
