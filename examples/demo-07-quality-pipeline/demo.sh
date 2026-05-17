#!/usr/bin/env bash
# Demo 7 — quality pipeline: cppcheck, clang-tidy, gtest, ASan+UBSan, abidiff, gdbserver.
#
#   ./demo.sh                # everything (analyze + test + asan + abi)
#   ./demo.sh --analyze-only
#   ./demo.sh --test-only
#   ./demo.sh --asan-only
#   ./demo.sh --abi-only
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
while [[ $# -gt 0 ]]; do
  case "$1" in
    --analyze-only) PHASES=(analyzer);    shift;;
    --test-only)    PHASES=(tests);       shift;;
    --asan-only)    PHASES=(asan);        shift;;
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
    cpp-tut/demo-07:asan \
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
#
# G-44 (r115): we explicitly DON'T use `conan profile detect --force` here
# because it auto-picks the host compiler version, which may be newer than
# conan 2.x's settings.yml knows about (e.g., gcc 16 on Fedora 44 isn't
# in conan's compiler.version list as of conan 2.x). Instead, we pin
# explicit settings that match the Containerfile's gcc-toolset-14.
# If the explicit-settings regeneration still fails (no conan on host,
# no network access, etc.), we delete the placeholder lockfile and let
# the in-container conan resolve fresh.
if grep -q '%1700000000.0' conan.lock 2>/dev/null; then
  log_warn "conan.lock contains placeholder revisions; regenerating"
  if command -v conan >/dev/null 2>&1; then
    if ! conan lock create . \
        --lockfile-out=conan.lock \
        -s build_type=RelWithDebInfo \
        -s compiler=gcc \
        -s compiler.version=14 \
        -s compiler.libcxx=libstdc++11 \
        -s compiler.cppstd=23 \
        -s arch=x86_64 \
        -s os=Linux 2>&1; then
      log_warn "host-side lockfile regen failed; removing placeholder lockfile"
      log_warn "the build container will resolve dependencies fresh on first run"
      rm -f conan.lock
    fi
  else
    log_warn "conan not on host; removing placeholder lockfile"
    log_warn "the build container will resolve dependencies fresh on first run"
    rm -f conan.lock
  fi
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
