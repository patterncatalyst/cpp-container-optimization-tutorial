#!/usr/bin/env bash
# ============================================================================
# Demo 05 — Isolation: noisy-neighbor interference through cgroup v2 controls
#
# Two C++ HTTP services share one host. tenant-a is the "good citizen" whose
# p99 latency we measure; tenant-b is the "noisy neighbor" that pegs the CPU
# in a tight loop. We run tenant-a under four scenarios — alone, next to an
# untuned neighbor, next to a weight-limited neighbor, and pinned to its own
# CPUs — and watch what the neighbor does to tenant-a's tail latency.
#
# KEY INSIGHT — read this before presenting:
#
#   The dominant cost on a busy multi-tenant host is NOT the work each
#   service does — it's the INTERFERENCE between services. A perfectly
#   tuned service can have its p99 wrecked by a neighbor saturating the
#   shared CPU, cache, and memory bandwidth.
#
#   cgroups v2 is the kernel's arbitration model, and two knobs bound the
#   damage:
#     • cpu.weight  — the noisy neighbor still runs, but the scheduler
#                     preferentially gives tenant-a time. Bounds interference
#                     WITHOUT capping throughput when the CPU is idle.
#     • cpuset.cpus — hand each tenant its own CPUs. Eliminates cross-tenant
#                     cache eviction entirely; pinned can beat baseline
#                     because the scheduler stops migrating tenant-a.
#
#   THE ON-STAGE MOMENT is the summary table: 'unisolated' shows ~10× p99
#   degradation (the cost of doing nothing), 'weighted' recovers most of it,
#   and 'pinned' can drop BELOW the single-tenant baseline.
#
# This script is a talk-through: it stops between steps (Press Enter) so you
# can narrate. Piped / non-interactive runs skip the pauses automatically
# (or pass --no-pause).
#
# Usage:
#   ./demo.sh                                       run all four scenarios
#   ./demo.sh --scenario baseline|unisolated|weighted|pinned   one scenario
#   ./demo.sh --no-pause                            never stop for Enter
#   ./demo.sh --clean                               tear down + remove images
# ============================================================================

set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DEMO_DIR"

# shellcheck source=../../scripts/lib/_helpers.sh
source "$(cd ../../scripts/lib && pwd)/_helpers.sh"

IMG_A="cpp-tut/demo-05:tenant-a"
IMG_B="cpp-tut/demo-05:tenant-b"
PORT=18501

SCENARIO=all
DO_CLEAN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --scenario) SCENARIO="$2"; shift 2;;
    --no-pause) export DEMO_NO_PAUSE=1; shift;;
    --clean)    DO_CLEAN=1;    shift;;
    -h|--help)  sed -n '2,35p' "$0"; exit 0;;
    *) log_err "unknown arg: $1"; exit 2;;
  esac
done

if [[ $DO_CLEAN -eq 1 ]]; then
  podman rm -f demo05-a demo05-b 2>/dev/null || true
  podman rmi -f "$IMG_A" "$IMG_B" 2>/dev/null || true
  rm -rf results
  log_ok "Cleaned."
  exit 0
fi

require podman hey awk
register_cleanup demo05-a demo05-b
mkdir -p results

banner \
  "DEMO 05 — Isolation: noisy-neighbor interference via cgroup v2" \
  "Two C++ services, one host. What does a bad neighbor cost tenant-a?"

callout \
  "tenant-a:   http://127.0.0.1:${PORT}   the 'good citizen' we measure" \
  "tenant-b:   the 'noisy neighbor' — pegs CPU in a tight loop, no limits" \
  "Images:     $IMG_A · $IMG_B" \
  "Knobs:      cpu.weight (bound interference) · cpuset.cpus (dedicate CPUs)"
callout "" "Both tenants are the SAME binary — behaviour differs only by cgroup:"
code_ref "src/main.cpp" 84 "the request-path CPU work + tuned httplib thread pool (twin source)"

# ── Step 1: Check the host — cgroup v2 controller delegation ─────────────
demo_step "Check the host: cgroup v2 controller delegation"
callout "The 'weighted' and 'pinned' scenarios need rootless podman to apply" \
        "the cgroup v2 'cpu' and 'cpuset' controllers. Most distros only" \
        "delegate 'memory pids' to the user slice by default — cpu/cpuset" \
        "need an explicit systemd opt-in. We detect that up front so missing" \
        "controllers skip cleanly instead of crashing mid-run."
#
# G-40 (r98): cgroup v2 controller delegation detection.
#
# Rootless podman's `--cpu-weight` and `--cpuset-cpus` flags need their
# respective cgroup v2 controllers (cpu, cpuset) delegated to the
# user slice. Default systemd configurations on most distros only
# delegate `memory pids` — cpu/cpuset/io require an explicit opt-in
# via a systemd drop-in. See README's "Cgroup v2 controller
# delegation" section for the fix.
#
# We detect available controllers up front and set flags so each
# scenario can skip cleanly with a clear message rather than crash
# with an opaque OCI runtime error mid-test.
HAS_CPU_DELEGATED=0
HAS_CPUSET_DELEGATED=0
DELEGATE_PATH="/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.subtree_control"
if [[ -r "$DELEGATE_PATH" ]]; then
  DELEGATE_CONTENT="$(<"$DELEGATE_PATH")"
  [[ "$DELEGATE_CONTENT" == *cpu* ]]    && HAS_CPU_DELEGATED=1
  [[ "$DELEGATE_CONTENT" == *cpuset* ]] && HAS_CPUSET_DELEGATED=1
else
  DELEGATE_CONTENT=""
fi

if (( ! HAS_CPU_DELEGATED )) || (( ! HAS_CPUSET_DELEGATED )); then
  log_warn "cgroup v2 controller delegation incomplete:"
  log_warn "  current: ${DELEGATE_CONTENT:-(empty or unreadable)}"
  log_warn "  cpu:    $((HAS_CPU_DELEGATED))  (needed for the 'weighted' scenario)"
  log_warn "  cpuset: $((HAS_CPUSET_DELEGATED))  (needed for the 'pinned' scenario)"
  log_warn "Scenarios that need missing controllers will be skipped cleanly."
  log_warn "Fix: run \$REPO/scripts/cgroup-delegation.sh enable  (then re-login)"
  log_warn "     or see this demo's README for details."
else
  log_ok "cpu and cpuset controllers delegated — all scenarios will run"
fi
pause

# ── Step 2: Build both tenants ───────────────────────────────────────────
demo_step "Build both tenants"
callout "tenant-a is the HTTP service we probe; tenant-b is the CPU/memory" \
        "hog. First run adds a Conan + Containerfile build (~2-3 min)."
if ! podman build --target tenant-a -t "$IMG_A" .; then
  log_err "tenant-a build failed — cannot measure anything without it."
  exit 1
fi
if ! podman build --target tenant-b -t "$IMG_B" .; then
  log_err "tenant-b build failed — cannot run the noisy-neighbor scenarios."
  exit 1
fi

# Detect NUMA topology so we can decide whether the 'pinned' scenario
# is even meaningful.
NODES=$(ls -1 /sys/devices/system/node 2>/dev/null | grep -c '^node[0-9]\+$' || echo 1)
log_info "Detected $NODES NUMA node(s)"
pause

start_a()    { podman run --rm --replace -d --name demo05-a -p "${PORT}:8080" "$IMG_A" >/dev/null; }
start_b()    { podman run --rm --replace -d --name demo05-b "$@" "$IMG_B" >/dev/null; }
# G-41 (r100): `podman run --rm` schedules cleanup AFTER container exit,
# but cleanup runs asynchronously — `podman stop` returns before it
# completes. The next scenario's `start_a` can then race the cleanup
# and hit "container name already in use" even with sleep 0.5 between
# scenarios. `--replace` makes the run idempotent: if a container with
# that name still exists (running or stopped), stop and remove it
# first. Works on any podman 4.0+.
stop_both()  { podman stop demo05-a demo05-b >/dev/null 2>&1 || true; sleep 0.5; }

# Wait for tenant-a's HTTP server to be accepting connections. Replaces
# a fixed 'sleep 1' which would silently race against the container's
# startup time, especially under rootless slirp4netns.
wait_for_a() {
  local i
  for i in $(seq 1 50); do
    if curl -sf --max-time 1 "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  log_err "tenant-a did not become ready within 5s"
  podman logs demo05-a 2>&1 | tail -20
  return 1
}

# Robust hey-output parser.
#
# G-38: hey's percentile lines can have either '50%' or '50%%' depending
# on the installation (some builds don't expand the %%-escape in the
# format string). Pattern uses %+ to match one or more percent signs.
#
# Also validates that percentile lines were found at all; if not,
# the output is unparseable and we bail with a clear error rather than
# silently printing all-zero percentiles.
bench_a() {
  local label="$1"
  if ! wait_for_a; then
    return 1
  fi
  hey -n 5000 -c 25 "http://127.0.0.1:${PORT}/" > "results/$label.txt" 2>&1
  if ! grep -qE '^[[:space:]]+50%+ in' "results/$label.txt"; then
    log_err "hey produced no percentile data for $label"
    log_err "first 30 lines of results/$label.txt:"
    head -30 "results/$label.txt" | sed 's/^/    /' >&2
    log_err "tenant-a container logs (tail):"
    podman logs demo05-a 2>&1 | tail -10 | sed 's/^/    /' >&2
    return 1
  fi
  awk -v lbl="$label" '
    /^[[:space:]]+50%+ in/ {p50=$3*1000}
    /^[[:space:]]+95%+ in/ {p95=$3*1000}
    /^[[:space:]]+99%+ in/ {p99=$3*1000}
    END     {printf "%-12s p50=%8.2fms  p95=%8.2fms  p99=%8.2fms\n", lbl, p50, p95, p99}
  ' "results/$label.txt"
}

run_baseline() {
  demo_step "Scenario: baseline (tenant-a alone)"
  callout "No neighbor at all. This is tenant-a's best case — the number" \
          "every other scenario is measured against."
  start_a
  bench_a baseline
  callout "" "That p99 is the floor. Nothing on this host is competing for CPU."
  stop_both
  pause
}

run_unisolated() {
  demo_step "Scenario: unisolated (both running, no tuning)"
  callout "Start the noisy neighbor with zero cgroup tuning — the default" \
          "scheduler arbitrates. Watch what happens to tenant-a's tail."
  start_a
  start_b
  bench_a unisolated
  callout "" "This is the cost of doing nothing: the neighbor's load leaks" \
          "straight into tenant-a's p99 (~10× baseline is typical here)." \
          "One tenant's load absolutely affects the other."
  stop_both
  pause
}

run_weighted() {
  demo_step "Scenario: weighted (tenant-b cpu.weight=10)"
  callout "Same two tenants, but the neighbor gets cpu.weight=10 vs tenant-a's" \
          "default 100. The neighbor still runs — it's just deprioritized when" \
          "they contend. Interference should be bounded, not eliminated."
  if (( ! HAS_CPU_DELEGATED )); then
    log_warn "skipping: cgroup v2 'cpu' controller not delegated to user slice"
    echo "weighted: skipped (cgroup v2 cpu controller not delegated; see README)" \
      > results/weighted.txt
    pause
    return
  fi
  start_a
  # G-42 (r101): `--cpu-weight` is NOT a podman flag (confusingly close
  # to the cgroup v2 file name `cpu.weight` it would set). The right
  # invocation for cgroup v2 weight is `--cgroup-conf=cpu.weight=N`,
  # which writes directly to the container's cpu.weight in its cgroup.
  # Alternative: `--cpu-shares=N` (cgroup v1 flag; podman auto-translates
  # to v2 weight via a formula, but the input value is not the resulting
  # weight). We use --cgroup-conf because the value passed IS the cgroup
  # v2 weight, matching the conceptual description.
  #
  # Capture stderr to a tempfile so the actual error surfaces if podman
  # rejects the flag — the prior `2>/dev/null` hid the original typo
  # (--cpu-weight) and produced a misleading "rootless cgroup didn't
  # allow it" message that was never the real cause.
  local err
  err=$(mktemp)
  if start_b --cgroup-conf=cpu.weight=10 2>"$err"; then
    bench_a weighted
    callout "" "cpu.weight recovers most of the baseline: the neighbor is still" \
            "scheduled, but the kernel gives tenant-a more time. p99 stays bounded."
    rm -f "$err"
  else
    log_warn "podman rejected --cgroup-conf=cpu.weight=10; actual error:"
    sed 's/^/    /' "$err" >&2
    {
      echo "weighted: skipped"
      echo "podman error was:"
      cat "$err"
    } > results/weighted.txt
    rm -f "$err"
  fi
  stop_both
  pause
}

run_pinned() {
  demo_step "Scenario: pinned (cpuset.cpus split)"
  callout "Hand each tenant its own CPUs via cpuset.cpus. No shared cores means" \
          "no cross-tenant cache eviction — pinned can beat baseline because the" \
          "scheduler stops migrating tenant-a and its cache stays hot."
  if (( ! HAS_CPUSET_DELEGATED )); then
    log_warn "skipping: cgroup v2 'cpuset' controller not delegated to user slice"
    echo "pinned: skipped (cgroup v2 cpuset controller not delegated; see README)" \
      > results/pinned.txt
    pause
    return
  fi
  if [[ "$NODES" -lt 1 ]]; then
    log_warn "no NUMA info; skipping pinned"
    echo "pinned: skipped (no NUMA info)" > results/pinned.txt
    pause
    return
  fi
  local total
  total=$(nproc)
  if (( total < 4 )); then
    log_warn "need at least 4 CPUs to pin; have $total — skipping pinned"
    echo "pinned: skipped (only $total CPUs, need >= 4)" > results/pinned.txt
    pause
    return
  fi
  local half=$(( total / 2 ))
  local a_cpus="0-$((half - 1))"
  local b_cpus="$half-$((total - 1))"
  log_info "pinning tenant-a to $a_cpus, tenant-b to $b_cpus"
  # Wrap both podman starts in error handling — if the cpuset controller
  # is partly delegated but the specific cpuset constraint fails, we
  # surface a clean N/A rather than letting `set -e` kill the run.
  # G-41 (r100): --replace handles async --rm cleanup races, same as start_a.
  if podman run --rm --replace -d --name demo05-a --cpuset-cpus="$a_cpus" \
        -p "${PORT}:8080" "$IMG_A" >/dev/null 2>&1 \
     && podman run --rm --replace -d --name demo05-b --cpuset-cpus="$b_cpus" \
        "$IMG_B" >/dev/null 2>&1; then
    bench_a pinned
    callout "" "Dedicated CPUs eliminate interference entirely. The neighbor's" \
            "load can no longer touch tenant-a — p99 can even beat baseline."
  else
    log_warn "podman rejected --cpuset-cpus; recording N/A"
    log_warn "to see the underlying error, run:"
    log_warn "  podman run --rm --cpuset-cpus=$a_cpus $IMG_A"
    echo "pinned: skipped (podman --cpuset-cpus failed; rerun manually for the error)" \
      > results/pinned.txt
  fi
  stop_both
  pause
}

case "$SCENARIO" in
  baseline)    run_baseline ;;
  unisolated)  run_unisolated ;;
  weighted)    run_weighted ;;
  pinned)      run_pinned ;;
  all)         run_baseline; run_unisolated; run_weighted; run_pinned ;;
  *) log_err "unknown scenario: $SCENARIO"; exit 2 ;;
esac

# ── Summary ──────────────────────────────────────────────────────────────
demo_step "Summary — what the neighbor cost tenant-a"
for s in baseline unisolated weighted pinned; do
  if [[ -f "results/$s.txt" ]]; then
    if grep -qE '^[[:space:]]+50%+ in' "results/$s.txt"; then
      awk -v lbl="$s" '
        /^[[:space:]]+50%+ in/ {p50=$3*1000}
        /^[[:space:]]+95%+ in/ {p95=$3*1000}
        /^[[:space:]]+99%+ in/ {p99=$3*1000}
        END     {printf "%-12s p50=%8.2fms  p95=%8.2fms  p99=%8.2fms\n", lbl, p50, p95, p99}
      ' "results/$s.txt"
    else
      printf "%-12s (no percentile data — see results/%s.txt)\n" "$s" "$s"
    fi
  fi
done
callout "" \
  "Read the p99 column top to bottom:" \
  "  baseline    — tenant-a's floor, no competition" \
  "  unisolated  — the cost of doing nothing (neighbor wrecks the tail)" \
  "  weighted    — cpu.weight bounds the damage; most of baseline recovered" \
  "  pinned      — dedicated CPUs; interference gone, can beat baseline" \
  "The lesson: on a shared host, isolation policy — not per-service tuning —" \
  "decides your tail latency. Raw hey output is in results/."

log_ok "Demo 05 complete. (Containers were stopped after each scenario.)"
