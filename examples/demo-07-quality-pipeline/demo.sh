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
#   ./demo.sh --abi-break-demo
#                            # temporarily patch channel.hpp to break ABI;
#                            # rebuild + run abidiff; show the report; restore.
#                            # Requires a committed abi-reference/ baseline.
#   ./demo.sh --demo-findings
#                            # temporarily append deliberately bad code to
#                            # channel.cpp; run analyzers WITHOUT gating;
#                            # show what cppcheck + clang-tidy catch; restore.
#                            # Pedagogical only — does NOT modify the repo.
#   ./demo.sh --coverage-gcc # build with gcov instrumentation, run tests,
#                            # generate lcov HTML report at
#                            # reports/coverage-gcc/index.html
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
DO_ABI_BREAK_DEMO=0
DO_DEMO_FINDINGS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --analyze-only)    PHASES=(analyzer);    shift;;
    --test-only)       PHASES=(tests);       shift;;
    --asan-only)       PHASES=(asan);        shift;;
    --abi-only)        PHASES=(abi);         shift;;
    --coverage-gcc)    PHASES=(coverage-gcc); shift;;
    --abi-bless)       DO_ABI_BLESS=1;       shift;;
    --abi-break-demo)  DO_ABI_BREAK_DEMO=1;  shift;;
    --demo-findings)   DO_DEMO_FINDINGS=1;   shift;;
    --debug)           DO_DEBUG=1;           shift;;
    --clean)           DO_CLEAN=1;           shift;;
    *) log_err "unknown arg: $1"; exit 2;;
  esac
done

if [[ $DO_CLEAN -eq 1 ]]; then
  podman compose -f compose.debug.yml down -v 2>/dev/null || true
  podman rmi -f \
    cpp-tut/demo-07:analyzer \
    cpp-tut/demo-07:tests \
    cpp-tut/demo-07:asan \
    cpp-tut/demo-07:coverage-gcc \
    cpp-tut/demo-07:abi-diff \
    cpp-tut/demo-07:abi \
    cpp-tut/demo-07:svc \
    cpp-tut/demo-07:gdbserver \
    cpp-tut/demo-07:findings-demo 2>/dev/null || true
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

# --abi-break-demo: temporarily patches src/include/demo07/channel.hpp to add
# a field to Greeting, rebuilds the library, runs abidiff against the
# committed baseline, and shows the audience what abidiff catches. The
# source is restored on exit via the trap.
#
# This deliberately uses the abi-diff target (not abi) so that even
# though the diff is non-empty, the build completes and the reports
# are extractable to the host. In production, the abi target would
# fail with exit 2 here — which is the whole point of having the gate.
if [[ $DO_ABI_BREAK_DEMO -eq 1 ]]; then
  if [[ ! -f abi-reference/libdemo07_channel.so.1.abi ]]; then
    log_err "No baseline at abi-reference/libdemo07_channel.so.1.abi."
    log_info "Bootstrap one first:"
    log_info "  ./demo.sh --abi-only"
    log_info "  ./demo.sh --abi-bless"
    log_info "  git add abi-reference/ && git commit -m 'abi: bless baseline'"
    exit 1
  fi

  hpp="src/include/demo07/channel.hpp"
  if [[ ! -f "$hpp" ]]; then
    log_err "Cannot find $hpp"
    exit 1
  fi

  backup="$(mktemp -t channel.hpp.XXXXXX)"
  # shellcheck disable=SC2064
  trap "mv -f '$backup' '$hpp' && log_info 'channel.hpp restored to original'" EXIT
  cp "$hpp" "$backup"

  log_step "ABI break demo: patching $hpp"
  # Add a uint64_t timestamp field to Greeting AFTER the text member.
  # This changes the struct size and adds a data member at a new offset —
  # both are textbook ABI breaks for a type that crosses the .so boundary.
  if ! sed -i '/std::array<char, 64> text/a\    std::uint64_t timestamp_ns{0};  // ABI BREAK DEMO: changes Greeting size+layout' "$hpp"; then
    log_err "sed patch failed"
    exit 1
  fi
  if ! grep -q 'timestamp_ns' "$hpp"; then
    log_err "Patch verification failed (sed didn't insert the field)"
    exit 1
  fi

  log_info "Diff of the change:"
  diff -u "$backup" "$hpp" || true
  echo

  log_step "Rebuilding through abi-diff target (captures diff without gating)"
  mkdir -p reports
  podman build --target abi-diff -t cpp-tut/demo-07:abi-diff .

  # Extract reports from the abi-diff image
  cid="$(podman create cpp-tut/demo-07:abi-diff)"
  podman cp "$cid:/src/reports/." reports/ 2>/dev/null || true
  podman rm -f "$cid" >/dev/null

  echo
  if [[ -s reports/abidiff.txt ]]; then
    log_ok "abidiff caught the ABI break:"
    echo
    echo "----- reports/abidiff.txt -----"
    cat reports/abidiff.txt
    echo "-------------------------------"
    echo
    log_info "In production, --abi-only would have exited 2 at this point,"
    log_info "blocking the build. Without abidiff in the pipeline, this"
    log_info "5-line change would ship silently and break every downstream"
    log_info "binary that compiled against the OLD layout of Greeting."
  else
    log_warn "abidiff did NOT detect a break — investigate."
    log_warn "(reports/abidiff.txt is missing or empty.)"
  fi

  exit 0
fi

# --demo-findings: temporarily append deliberately bad code to channel.cpp,
# build through the analyzer-soft target (captures findings, never gates),
# show what cppcheck + clang-tidy report, then restore channel.cpp on exit.
#
# This exists so readers can SEE what the analyzers catch. Without bad code
# the analyzer reports are empty (clean repo), which is correct production
# behavior but uninformative pedagogically. The bad code lives only on disk
# during this script's runtime; an EXIT trap guarantees restoration.
if [[ $DO_DEMO_FINDINGS -eq 1 ]]; then
  cpp="src/lib/channel.cpp"
  if [[ ! -f "$cpp" ]]; then
    log_err "$cpp not found"
    exit 1
  fi

  backup="$(mktemp -t channel.cpp.XXXXXX)"
  # shellcheck disable=SC2064
  trap "mv -f '$backup' '$cpp' && log_info 'channel.cpp restored to original'" EXIT
  cp "$cpp" "$backup"

  log_step "Findings demo: appending deliberately bad code to $cpp"
  # The bad function exists ONLY so cppcheck and clang-tidy fire findings
  # readers can see. Each line below is engineered to trigger a specific
  # diagnostic. See _docs/12-analysis-debugging.md for the full mapping.
  cat >> "$cpp" <<'EOF'

// === --demo-findings: deliberately bad code (r128) ===
// DO NOT use these patterns in production. This block exists only so
// cppcheck and clang-tidy report findings readers can see.
namespace demo07 {

[[maybe_unused]] int demo07_findings_example(int input) {
    int uninit_var;                              // uninitialized variable
    int* maybe_null = NULL;                      // C-style NULL, should be nullptr
    char* leaked_buffer = new char[16];          // owning raw pointer, leaks
    leaked_buffer[0] = static_cast<char>(input); // ...and used once
    if (input > 0) {
        return uninit_var;                       // returns the uninit value
    }
    return *maybe_null;                          // dereferences NULL
}

}  // namespace demo07
EOF

  if ! grep -q 'demo07_findings_example' "$cpp"; then
    log_err "append verification failed"
    exit 1
  fi

  log_info "Bad code appended (will be restored on exit):"
  echo
  echo "----- tail of channel.cpp -----"
  tail -20 "$cpp"
  echo "-------------------------------"
  echo

  log_step "Building through analyzer-soft (captures findings, never gates)"
  mkdir -p reports
  podman build --target analyzer-soft -t cpp-tut/demo-07:findings-demo .

  # Extract reports from the analyzer-soft image
  cid="$(podman create cpp-tut/demo-07:findings-demo)"
  podman cp "$cid:/src/reports/cppcheck.xml" reports/cppcheck.xml 2>/dev/null || true
  podman cp "$cid:/src/reports/clang-tidy.txt" reports/clang-tidy.txt 2>/dev/null || true
  podman rm -f "$cid" >/dev/null

  echo
  log_ok "Analyzers fired. Here's what they caught:"
  echo

  if [[ -s reports/cppcheck.xml ]] && grep -q '<error ' reports/cppcheck.xml; then
    echo "----- reports/cppcheck.xml (cppcheck findings) -----"
    cat reports/cppcheck.xml
    echo "----------------------------------------------------"
  else
    log_warn "No cppcheck findings — reports/cppcheck.xml is empty or clean."
    log_warn "(That would mean the bad code didn't trigger cppcheck.)"
  fi
  echo

  if [[ -s reports/clang-tidy.txt ]] && \
     grep -qE ':[0-9]+:[0-9]+: (warning|error):' reports/clang-tidy.txt; then
    echo "----- reports/clang-tidy.txt (clang-tidy findings) -----"
    cat reports/clang-tidy.txt
    echo "--------------------------------------------------------"
  else
    log_warn "No clang-tidy findings — reports/clang-tidy.txt is empty or clean."
    log_warn "(That would mean the bad code didn't trigger clang-tidy.)"
  fi

  echo
  log_info "In production, --analyze-only would have exited 1 at this point,"
  log_info "blocking the build. With --demo-findings, the analyzer-soft target"
  log_info "captures the same evidence but skips the gating step so you can"
  log_info "read it. channel.cpp will now be restored to its committed state."

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

# Coverage-specific summary if --coverage-gcc was the phase
if [[ " ${PHASES[*]} " == *" coverage-gcc "* ]]; then
  echo
  log_step "Coverage summary"
  if [[ -f reports/coverage-summary.txt ]]; then
    cat reports/coverage-summary.txt
    echo
  fi
  if [[ -f reports/coverage-gcc/index.html ]]; then
    log_ok "HTML report: $(pwd)/reports/coverage-gcc/index.html"
    log_info "Open it in a browser:"
    log_info "  xdg-open reports/coverage-gcc/index.html"
  else
    log_warn "Expected reports/coverage-gcc/index.html not found."
  fi
fi

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
