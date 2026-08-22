#!/usr/bin/env bash
# ============================================================================
# Demo 07 — Quality pipeline: a containerized C++ quality gate
#
# One small C++ library (libdemo07_channel.so) and its service (demo07-svc),
# run through the six tools that between them catch most of what goes wrong
# in production C++ — static analysis (cppcheck + clang-tidy), unit tests
# (GoogleTest), sanitizers (ASan + UBSan), ABI compatibility (abidiff),
# hermetic/reproducible builds (Conan lockfile), and a gdbserver debug
# sidecar. Every stage is a Containerfile target, run exactly as a CI job
# would run it, with its report pulled back to reports/ for gating.
#
# KEY INSIGHT — read this before presenting:
#
#   This is a pre-merge quality GATE expressed as container build stages.
#   Each Containerfile target — analyzer, tests, asan, abi, coverage-gcc,
#   abi-diff, svc, gdbserver — is one CI job. A stage that FAILS to build
#   is the gate doing its job: the analyzer target exits non-zero when it
#   finds something, the abi target exits non-zero when the ABI changed.
#   Nothing here is aspirational tooling bolted on later; the gate IS the
#   build. The lockfile is checked in, the ABI reference is checked in, the
#   sanitizer build is one target and one flag.
#
#   THE ON-STAGE MOMENTS are the deliberately-broken demos:
#     --demo-findings  makes the analyzers fire (bad code, captured, restored)
#     --abi-break-demo makes abidiff catch a struct-layout change
#   Both patch source on disk, show what the tool caught, then restore it —
#   the repo is never modified.
#
# This script is a talk-through: it stops between stages (Press Enter) so you
# can narrate. Piped / non-interactive runs skip the pauses automatically
# (or pass --no-pause).
#
# Usage:
#   ./demo.sh                 full pipeline (analyzer + tests + asan + abi)
#   ./demo.sh --analyze-only  only cppcheck + clang-tidy (analyzer target)
#   ./demo.sh --test-only     only build + run GoogleTest (tests target)
#   ./demo.sh --asan-only     only build + run tests under ASan + UBSan
#   ./demo.sh --abi-only      only run abidiff against abi-reference/
#   ./demo.sh --coverage-gcc  gcov-instrumented build + tests → lcov HTML
#   ./demo.sh --abi-bless     promote reports/current.abi to abi-reference/
#                             (run --abi-only first to produce it)
#   ./demo.sh --abi-break-demo
#                             temporarily patch channel.hpp to break ABI;
#                             rebuild + run abidiff; show the report; restore.
#                             Requires a committed abi-reference/ baseline.
#   ./demo.sh --demo-findings
#                             temporarily append deliberately bad code to
#                             channel.cpp; run analyzers WITHOUT gating; show
#                             what cppcheck + clang-tidy catch; restore.
#                             Pedagogical only — does NOT modify the repo.
#   ./demo.sh --hermetic-check
#                             build demo07-svc twice from clean state (forces
#                             cache invalidation via HERMETIC_NONCE arg);
#                             extract demo07-svc + libdemo07_channel.so from
#                             both builds; SHA-256 compare. Pass = reproducible.
#   ./demo.sh --debug         also spin up the gdbserver sidecar
#   ./demo.sh --no-pause      never stop for Enter (unattended)
#   ./demo.sh --clean         tear down and remove images + reports
# ============================================================================

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
DO_HERMETIC_CHECK=0
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
    --hermetic-check)  DO_HERMETIC_CHECK=1;  shift;;
    --debug)           DO_DEBUG=1;           shift;;
    --no-pause)        export DEMO_NO_PAUSE=1; shift;;
    --clean)           DO_CLEAN=1;           shift;;
    -h|--help)         sed -n '2,60p' "$0"; exit 0;;
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
    cpp-tut/demo-07:findings-demo \
    cpp-tut/demo-07:hermetic-1 \
    cpp-tut/demo-07:hermetic-2 2>/dev/null || true
  rm -rf reports
  log_ok "Cleaned."
  exit 0
fi

banner \
  "DEMO 07 — Quality pipeline: a containerized C++ quality gate" \
  "Analyzers · sanitizers · ABI · coverage · hermetic builds — as CI stages"

callout \
  "Library:   libdemo07_channel.so   (the ABI-bearing shared object)" \
  "Service:   demo07-svc             (links the library)" \
  "Stages:    analyzer → tests → asan → abi   (Containerfile targets)" \
  "Reports:   reports/               (pulled from each image, for CI gating)"

# ── --abi-bless: promote reports/current.abi to abi-reference/ ──────────────
# This is the operational counterpart to --abi-only. After running --abi-only
# at least once to produce reports/current.abi, run --abi-bless to copy it
# into abi-reference/ as the new baseline. Future --abi-only runs will then
# diff against this baseline instead of just recording it.
#
# The committed baseline is what `abidiff` compares to inside the abi stage
# of the Containerfile. The workflow is:
#
#   1. ./demo.sh --abi-only       (produces reports/current.abi)
#   2. inspect reports/current.abi if you want to
#   3. ./demo.sh --abi-bless      (promotes it to abi-reference/)
#   4. git add abi-reference/ && git commit -m "abi: bless v1.0 baseline"
#
# After step 4, any header change that breaks ABI causes the abi stage to
# exit non-zero with abidiff's report.
if [[ $DO_ABI_BLESS -eq 1 ]]; then
  demo_step "Bless the current ABI as the new baseline"
  callout "Promotes reports/current.abi → abi-reference/. This is the manual" \
          "'we intend this to be the frozen interface' step. From here on, the" \
          "abi target diffs against this file and fails on any drift."
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

# ── --abi-break-demo: patch a public header, rebuild, show what abidiff catches
# Temporarily patches src/include/demo07/channel.hpp to add a field to
# Greeting, rebuilds the library, runs abidiff against the committed baseline,
# and shows the audience what abidiff catches. The source is restored on exit
# via the trap.
#
# This deliberately uses the abi-diff target (not abi) so that even though the
# diff is non-empty, the build COMPLETES and the reports are extractable to
# the host. In production, the abi target would fail with exit 2 here — which
# is the whole point of having the gate.
if [[ $DO_ABI_BREAK_DEMO -eq 1 ]]; then
  demo_step "ABI break demo — patch channel.hpp, rebuild, run abidiff"
  callout "We add a data member to a struct that crosses the .so boundary." \
          "That changes Greeting's size and layout — a textbook ABI break." \
          "The abi-diff target captures the diff WITHOUT gating so we can read it."
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

  log_step "Patching $hpp"
  # Add a uint64_t timestamp field to Greeting AFTER the text member. This
  # changes the struct size and adds a data member at a new offset — both
  # are textbook ABI breaks for a type that crosses the .so boundary.
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
  pause "Header patched (5 lines). Press Enter to rebuild through abi-diff"

  demo_step "Rebuilding through abi-diff target (captures diff without gating)"
  mkdir -p reports
  if ! podman build --target abi-diff -t cpp-tut/demo-07:abi-diff .; then
    log_err "abi-diff build failed — this target is expected to succeed even"
    log_err "with a non-empty diff (it does not gate). Investigate the build."
    exit 1
  fi

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
    callout "What this MEANS for a pipeline: this diff is exactly what the abi" \
            "gate blocks on. In production, --abi-only would have exited 2 here," \
            "stopping the merge. Without abidiff in the pipeline, this 5-line" \
            "header change ships silently and breaks every downstream binary" \
            "that compiled against the OLD layout of Greeting."
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

# ── --demo-findings: append bad code, run analyzers WITHOUT gating ──────────
# Temporarily append deliberately bad code to channel.cpp, build through the
# analyzer-soft target (captures findings, never gates), show what cppcheck +
# clang-tidy report, then restore channel.cpp on exit.
#
# This exists so readers can SEE what the analyzers catch. Without bad code
# the analyzer reports are empty (clean repo), which is correct production
# behavior but uninformative pedagogically. The bad code lives only on disk
# during this script's runtime; an EXIT trap guarantees restoration.
if [[ $DO_DEMO_FINDINGS -eq 1 ]]; then
  demo_step "Findings demo — append bad code, run analyzers WITHOUT gating"
  callout "On a clean repo the analyzer reports are empty (correct, but boring)." \
          "So we append one deliberately awful function, build the analyzer-soft" \
          "target (captures findings but never gates), and read what fired." \
          "channel.cpp is restored on exit — the repo is never modified."
  cpp="src/lib/channel.cpp"
  if [[ ! -f "$cpp" ]]; then
    log_err "$cpp not found"
    exit 1
  fi

  backup="$(mktemp -t channel.cpp.XXXXXX)"
  # shellcheck disable=SC2064
  trap "mv -f '$backup' '$cpp' && log_info 'channel.cpp restored to original'" EXIT
  cp "$cpp" "$backup"

  log_step "Appending deliberately bad code to $cpp"
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
  pause "Bad code in place. Press Enter to build through analyzer-soft"

  demo_step "Building through analyzer-soft (captures findings, never gates)"
  mkdir -p reports
  if ! podman build --target analyzer-soft -t cpp-tut/demo-07:findings-demo .; then
    log_err "analyzer-soft build failed — this target is expected to succeed"
    log_err "(it captures findings but does not gate). Investigate the build."
    exit 1
  fi

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
  callout "What this MEANS for a pipeline: cppcheck flags the structural bugs" \
          "(uninitialized read, null deref, leak); clang-tidy flags the modern-C++" \
          "issues (NULL vs nullptr, owning raw pointer). In production the" \
          "analyzer target would have exited 1 on the first finding, blocking" \
          "the merge. analyzer-soft captured the same evidence without gating."
  log_info "In production, --analyze-only would have exited 1 at this point,"
  log_info "blocking the build. With --demo-findings, the analyzer-soft target"
  log_info "captures the same evidence but skips the gating step so you can"
  log_info "read it. channel.cpp will now be restored to its committed state."

  exit 0
fi

# ── --hermetic-check: build demo07-svc twice, SHA-256 compare ───────────────
# Build demo07-svc twice from clean state (forcing the build stage to re-run
# via the HERMETIC_NONCE ARG), extract demo07-svc and libdemo07_channel.so
# from both builds, and SHA-256 compare. Pass means the build is reproducible
# — identical inputs produce identical bytes. Fail prints a diagnostic ladder
# pointing at the usual suspects.
#
# The HERMETIC_NONCE trick (in the Containerfile build stage): a no-op RUN
# that echoes the nonce. Different values create different layer cache keys,
# forcing a rebuild of everything from that line down. The nonce has zero
# effect on the resulting binary — it only invalidates the cache. This is how
# we get "two independent builds" without nuking the whole image cache.
if [[ $DO_HERMETIC_CHECK -eq 1 ]]; then
  require podman
  mkdir -p reports/hermetic
  rm -f reports/hermetic/build*

  demo_step "Hermetic build check — build demo07-svc twice with cache invalidation"
  callout "Reproducibility means identical inputs → byte-identical outputs." \
          "Both builds use identical source; the HERMETIC_NONCE ARG forces the" \
          "build stage to re-execute so we get two genuinely independent compiles."
  echo

  # Use timestamps as nonces so each invocation of --hermetic-check creates
  # fresh cache misses (don't accidentally reuse a prior build's cache).
  nonce1="$(date +%s%N)"
  sleep 1
  nonce2="$(date +%s%N)"

  log_info "Build 1/2 (HERMETIC_NONCE=$nonce1) ..."
  if ! podman build --build-arg HERMETIC_NONCE="$nonce1" \
               --target svc \
               -t cpp-tut/demo-07:hermetic-1 .; then
    log_err "Build 1/2 failed — cannot compare. Investigate the build."
    exit 1
  fi

  log_info "Build 2/2 (HERMETIC_NONCE=$nonce2) ..."
  if ! podman build --build-arg HERMETIC_NONCE="$nonce2" \
               --target svc \
               -t cpp-tut/demo-07:hermetic-2 .; then
    log_err "Build 2/2 failed — cannot compare. Investigate the build."
    exit 1
  fi

  echo
  log_step "Extracting binaries from both builds"
  cid1="$(podman create cpp-tut/demo-07:hermetic-1)"
  podman cp "$cid1:/app/demo07-svc" reports/hermetic/build1-demo07-svc
  podman cp "$cid1:/usr/local/lib/libdemo07_channel.so.1.0.0" reports/hermetic/build1-libchannel.so
  podman rm "$cid1" >/dev/null

  cid2="$(podman create cpp-tut/demo-07:hermetic-2)"
  podman cp "$cid2:/app/demo07-svc" reports/hermetic/build2-demo07-svc
  podman cp "$cid2:/usr/local/lib/libdemo07_channel.so.1.0.0" reports/hermetic/build2-libchannel.so
  podman rm "$cid2" >/dev/null

  echo
  log_step "Comparing SHA-256 hashes"
  echo

  all_match=1
  for artifact in demo07-svc libchannel.so; do
    f1="reports/hermetic/build1-$artifact"
    f2="reports/hermetic/build2-$artifact"

    if [[ ! -f "$f1" || ! -f "$f2" ]]; then
      log_err "  $artifact: one or both files missing — extraction failed"
      all_match=0
      continue
    fi

    size="$(stat -c %s "$f1")"
    h1="$(sha256sum "$f1" | awk '{print $1}')"
    h2="$(sha256sum "$f2" | awk '{print $1}')"

    printf "  %-15s  size %d bytes\n" "$artifact" "$size"
    printf "    build 1: %s\n" "$h1"
    printf "    build 2: %s\n" "$h2"

    if [[ "$h1" == "$h2" ]]; then
      log_ok "    -> BYTE-IDENTICAL"
    else
      log_err "    -> DIFFER"
      all_match=0
      log_info "    First 20 differing byte offsets (offset:b1:b2):"
      cmp -l "$f1" "$f2" 2>/dev/null | head -20 | sed 's/^/      /'
    fi
    echo
  done

  if [[ $all_match -eq 1 ]]; then
    log_ok "Hermetic build: VERIFIED"
    callout "What this MEANS for a pipeline: byte-identical rebuilds are the" \
            "property that lets you cache, mirror, verify, and TRUST images" \
            "across a fleet — provenance you can check, not take on faith."
    log_info "Both independent rebuilds produced byte-identical binaries."
    log_info "This is the property that lets you cache, mirror, verify, and"
    log_info "trust container images across a fleet. See _docs/13-reproducibility-abi.md"
    log_info "for the broader Konflux + Cachi2 picture."
    exit 0
  else
    log_warn "Hermetic build: FAILED"
    log_warn "The binaries differ, which means something in the build is"
    log_warn "non-deterministic. Common culprits in decreasing frequency:"
    log_warn "  1. __DATE__ / __TIME__ macros in source"
    log_warn "     (grep -r '__DATE__\\|__TIME__' src/)"
    log_warn "  2. Embedded build paths in debug info"
    log_warn "     (compile with -ffile-prefix-map=/src=.)"
    log_warn "  3. Random PRNG seeds in code generation"
    log_warn "     (compile with -frandom-seed=...)"
    log_warn "  4. Non-deterministic build-id (.note.gnu.build-id)"
    log_warn "     (readelf -n reports/hermetic/build1-demo07-svc | grep 'Build ID')"
    log_warn "  5. Parallel build races producing different .o ordering"
    log_warn ""
    log_warn "Deeper diagnostic — disassembly diff (often pinpoints the source):"
    log_warn "  diff <(objdump -d reports/hermetic/build1-demo07-svc) \\"
    log_warn "       <(objdump -d reports/hermetic/build2-demo07-svc) | head -60"
    exit 1
  fi
fi

require podman
mkdir -p reports

# Generate a real conan lockfile if the checked-in stub still has the
# placeholder revision. This keeps first-run friction low while still pinning
# everything once the lockfile is regenerated.
#
# G-48 (r118): the checked-in conan.lock is a placeholder stub. On first run
# we truncate it to zero bytes so:
#   (a) the Containerfile's `COPY conan.lock` still finds a file to copy
#       (deletion would break that step), and
#   (b) the container's `[ -s conan.lock ]` test routes to the fresh-resolve
#       branch.
# G-50 (r120) handles the in-container companion: rm the empty file before
# `conan install` so conan's auto-discovery doesn't trip on it.
#
# We deliberately do NOT try to regenerate the lockfile on the host — the
# host's conan profile is unreliable (gcc version drift, stale profiles from
# prior `conan profile detect` runs, etc.). The container is the source of
# truth for the build environment, so let IT decide what versions to pin.
# After a successful build, the user can extract the real lockfile from the
# container layer and commit it.
if grep -q '%1700000000.0' conan.lock 2>/dev/null; then
  log_warn "conan.lock is a placeholder; container will resolve dependencies fresh"
  > conan.lock
fi

# Per-stage framing shown BEFORE the build runs.
phase_intro() {
  case "$1" in
    analyzer)     callout "cppcheck + clang-tidy over the source. Findings fail the build" \
                          "with a non-zero exit — the cheapest place to catch a bug, before" \
                          "anything is compiled for real.";;
    tests)        callout "Build the library + service and run the GoogleTest suite (release)," \
                          "including the abstraction-cost microbench (interface vs CRTP).";;
    asan)         callout "Same suite, rebuilt under AddressSanitizer + UBSan. Leaks," \
                          "out-of-bounds, and undefined behavior surface as a non-zero exit.";;
    abi)          callout "Extract the current library ABI and abidiff it against the" \
                          "committed abi-reference/ baseline.";;
    coverage-gcc) callout "gcov-instrumented build, run tests, generate an lcov HTML report" \
                          "at reports/coverage-gcc/index.html.";;
  esac
}

# Per-stage interpretation shown AFTER a stage passes.
phase_interpret() {
  case "$1" in
    analyzer)     callout "What this MEANS: a clean pass = no gating findings. In CI a finding" \
                          "here blocks the merge before real compilation. (Try --demo-findings" \
                          "to see the analyzers actually fire.)";;
    tests)        callout "What this MEANS: green here is your correctness baseline; the" \
                          "microbench also printed the interface-vs-CRTP timings for §14.";;
    asan)         callout "What this MEANS: no ASan/UBSan report = memory-safety and UB clean." \
                          "A failure here is a REAL bug ASan simply made visible.";;
    abi)          callout "What this MEANS: no ABI changes = downstream binaries built against" \
                          "the old headers still link. A diff would demand a SONAME bump or a" \
                          "downstream rebuild. (Try --abi-break-demo to see abidiff fail.)";;
    coverage-gcc) callout "What this MEANS: coverage tells you which lines the tests actually" \
                          "exercised — the gap is where bugs hide untested.";;
  esac
}

run_phase() {
  local phase="$1"
  demo_step "Stage: $phase"
  phase_intro "$phase"
  # ASan's shadow-memory mapping can clash with the default build-time seccomp
  # profile on some hosts. Relax seccomp specifically for the ASan stage so
  # the in-stage `ctest` invocation can fire ASan's mprotect/mmap pattern.
  # See §12 "Runtime sanitizers in containers".
  local sec_opts=()
  if [[ "$phase" == "asan" ]]; then
    sec_opts+=(--security-opt seccomp=unconfined)
    callout "ASan stage runs with --security-opt seccomp=unconfined so its" \
            "shadow-memory mmap/mprotect pattern isn't blocked."
  fi
  # A failing build here is the GATE doing its job (the analyzer/abi targets
  # exit non-zero on a finding). We surface it clearly and stop the pipeline.
  if ! podman build "${sec_opts[@]}" --target "$phase" -t "cpp-tut/demo-07:$phase" .; then
    log_err "$phase stage failed."
    log_err "In a real pipeline this non-zero exit IS the gate: it blocks the"
    log_err "merge. Read reports/ (and the build log above) for the finding."
    exit 1
  fi
  # Pull the reports out of the image so the host sees them.
  local cid
  cid=$(podman create "cpp-tut/demo-07:$phase")
  podman cp "$cid:/src/reports/." reports/ 2>/dev/null || true
  podman rm -f "$cid" >/dev/null
  log_ok "$phase passed; reports under reports/"
  phase_interpret "$phase"
  pause
}

for p in "${PHASES[@]}"; do
  run_phase "$p"
done

# Coverage-specific summary if --coverage-gcc was the phase
if [[ " ${PHASES[*]} " == *" coverage-gcc "* ]]; then
  echo
  demo_step "Coverage summary"
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
  callout "What this MEANS: a coverage % without context is vanity; use it to" \
          "find the UNtested branches, then decide whether they need a test."
fi

if [[ $DO_DEBUG -eq 1 ]]; then
  demo_step "Bringing up the gdbserver debug sidecar"
  callout "A separate Containerfile target ships a debug build with gdbserver" \
          "listening, alongside the production svc image (which has no gdb)." \
          "This is §12's debug-sidecar pattern in miniature."
  if ! podman compose -f compose.debug.yml up -d --build; then
    log_err "compose up failed — the gdbserver sidecar did not start."
    podman compose -f compose.debug.yml logs --tail=40 2>&1 || true
    exit 1
  fi
  log_ok "gdbserver listening on 127.0.0.1:1234"
  log_info "  Connect with:"
  log_info "    podman cp demo07-svc:/app/demo07-svc /tmp/demo07-svc"
  log_info "    gdb -ex 'target remote 127.0.0.1:1234' /tmp/demo07-svc"
fi

demo_step "Reports"
ls -la reports/ 2>/dev/null || true

echo
if [[ $DO_DEBUG -eq 1 ]]; then
  log_ok "Pipeline complete — gdbserver sidecar is still up for debugging."
  pause "Press Enter to tear down the gdbserver sidecar (or Ctrl-C to leave it up)"
  podman compose -f compose.debug.yml down -v 2>/dev/null || true
  log_ok "Demo 07 complete."
else
  log_ok "Demo 07 complete. (No containers left running; images cached for next run.)"
fi
