#!/usr/bin/env bash
# ============================================================================
# Demo 03 — Async gRPC + io_uring: three servers in one binary
#
# One container runs three servers so you can compare I/O strategies head to
# head, all wired into the shared LGTM observability backend:
#   :50051  gRPC Echo (callback / completion-queue API)  → OTel histogram
#   :9000   io_uring TCP echo (direct liburing)          → the raw ring
#   :9001   TCP echo (Asio io_uring backend)             → same ring, wrapped
# The two TCP servers speak the SAME protocol, so one load generator drives
# both and the difference is purely the userland cost of the abstraction.
#
# KEY INSIGHT — read this before presenting:
#
#   epoll asks the kernel "is this fd ready?" — one syscall per readiness
#   check, then another to actually read. io_uring inverts that: you batch
#   SUBMISSIONS onto a ring and collect COMPLETIONS asynchronously, so a
#   single io_uring_enter() can carry many operations and you stop paying
#   the per-call syscall tax that dominates epoll-style async at high RPS.
#
#   This demo makes that concrete three ways: raw liburing (:9000) is the
#   submission/completion model with nothing hiding it; Asio (:9001) makes
#   the SAME kernel calls behind an executor/callback API — friendlier, and
#   measurably more userland overhead; gRPC (:50051) uses its OWN completion
#   queues (NOT io_uring) and pays for framing, HPACK, protobuf, and
#   deadline tracking on top. Real C++ services mix all three.
#
#   THE ON-STAGE MOMENT is the summary table: gRPC is ~two orders of
#   magnitude slower on throughput than raw TCP echo (that's the cost of
#   semantics, not slow code), and Asio-vs-direct isolates abstraction cost.
#
# This script is a talk-through: it stops between steps (Press Enter) so you
# can narrate. Piped / non-interactive runs skip the pauses automatically
# (or pass --no-pause).
#
# Usage:
#   ./demo.sh                  full bring-up + load + summary
#   ./demo.sh --keep           don't tear down at end
#   ./demo.sh --clean          tear down only (run after --keep)
#   ./demo.sh --production     use compose.production.yml (custom seccomp +
#                              SELinux module + dropped caps + read-only fs).
#                              Requires one-time host setup; see
#                              security/README.md.
#   ./demo.sh --no-pause       never stop for Enter (unattended)
# ============================================================================

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DIR/../.." && pwd)"
cd "$DIR"

# shellcheck source=../../scripts/lib/_helpers.sh
source "$(cd ../../scripts/lib && pwd)/_helpers.sh"

GRAFANA_URL="http://127.0.0.1:3000"
HEALTHZ_URL="http://127.0.0.1:18403"

KEEP_UP=0
CLEAN_ONLY=0
USE_PRODUCTION=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep)       KEEP_UP=1; shift ;;
        --clean)      CLEAN_ONLY=1; shift ;;
        --production) USE_PRODUCTION=1; shift ;;
        --no-pause)   export DEMO_NO_PAUSE=1; shift ;;
        -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
        *) log_err "unknown arg: $1"; exit 2 ;;
    esac
done

require podman

OBS="$REPO_ROOT/observability/compose.yml"

if (( USE_PRODUCTION )); then
    # Verify the one-time host setup is in place before bringing up.
    # Each check is short; failures point at the corresponding
    # security/ script.
    log_step "Production mode: verifying host setup"

    SECCOMP_PROFILE="$DIR/security/seccomp-iouring.json"
    if [[ ! -f "$SECCOMP_PROFILE" ]]; then
        log_err "$SECCOMP_PROFILE not found."
        log_err "Generate it from your local podman default:"
        log_err "  ./security/build-seccomp-profile.sh"
        exit 1
    fi
    log_ok "seccomp profile present: $SECCOMP_PROFILE"

    if command -v semodule >/dev/null 2>&1; then
        if semodule -l 2>/dev/null | grep -q '^demo03_iouring'; then
            log_ok "SELinux module demo03_iouring loaded"
        else
            log_err "SELinux module demo03_iouring NOT loaded."
            log_err "Install (requires root):"
            log_err "  sudo ./security/install-selinux-policy.sh"
            log_err ""
            log_err "If your system has SELinux Disabled (getenforce reports"
            log_err "'Disabled'), you can skip the module install — io_uring"
            log_err "won't be denied at the MAC layer. But then there's no"
            log_err "reason to use --production over compose.yml. Run the"
            log_err "tutorial path instead."
            exit 1
        fi
    else
        log_warn "semodule not found; skipping SELinux check"
        log_warn "(your system may not have SELinux installed)"
    fi

    export SECCOMP_PROFILE_PATH="$SECCOMP_PROFILE"
    COMPOSE=(podman compose -f compose.production.yml -f "$OBS")
    log_info "Using compose.production.yml"
else
    COMPOSE=(podman compose -f compose.yml -f "$OBS")
fi

if (( CLEAN_ONLY )); then
    "${COMPOSE[@]}" down -v 2>/dev/null || true
    log_ok "Cleaned."
    exit 0
fi

cleanup() {
    # Always capture demo-03-svc logs before tearing down, regardless
    # of exit status. If the container crashed early, this is the only
    # way to see WHY. Logs go to stderr so they appear in the failed
    # build output above the "tearing down" line.
    echo
    log_step "Capturing demo-03-svc logs (last 100 lines) before teardown"
    podman logs --tail=100 demo03-svc 2>&1 | sed 's/^/    /' || true
    echo

    if (( KEEP_UP == 0 )); then
        log_step "Tearing down"
        "${COMPOSE[@]}" down -v 2>/dev/null || true
    else
        log_ok "Stack left running. Tear down with:"
        log_info "    ./demo.sh --clean"
    fi
}
trap cleanup EXIT

banner \
  "DEMO 03 — Async gRPC + io_uring: three servers, one binary" \
  "epoll asks 'is it ready?'. io_uring batches submit/complete."

callout \
  "gRPC Echo:        :50051   (callback API · OTLP/gRPC → LGTM)" \
  "io_uring direct:  :9000    (raw liburing submission/completion ring)" \
  "Asio io_uring:    :9001    (same kernel calls, executor abstraction)" \
  "Grafana:          $GRAFANA_URL          (anonymous viewer)"
callout "" "Three server heads, three source files worth opening:"
code_ref "src/grpc_async_server.cpp" 67 "async gRPC completion-queue worker loop (Proceed() state machine)"
code_ref "src/echo_uring.cpp" 1 "raw liburing submission/completion ring (multishot on kernels ≥6.0)"
code_ref "proto/echo.proto" 1 "the Echo service contract"

# ── Step 1: Build and bring up ─────────────────────────────────────────
demo_step "Build the demo image and bring up the stack + LGTM backend"
callout "First build is ~30-45 min (OTel + gRPC + asio compiled from source" \
        "under the override profile). Warm rebuilds are ~2-3 min."
BUILD_FLAG="--build"
if [[ "${DEMO_NO_BUILD:-0}" == "1" ]] && image_exists "cpp-tut/demo-03:latest"; then
    log_info "Reusing cpp-tut/demo-03:latest (DEMO_NO_BUILD=1) — starting without --build"
    BUILD_FLAG=""
fi
if ! "${COMPOSE[@]}" up -d ${BUILD_FLAG}; then
    log_err "compose up failed — not going any further (nothing to load)."
    "${COMPOSE[@]}" logs --tail=40 demo-03-svc 2>&1 || true
    exit 1
fi

log_step "Waiting for demo-03-svc healthz to return 200"
ready=0
for i in {1..120}; do
    if curl -fsS --max-time 2 "$HEALTHZ_URL" >/dev/null 2>&1; then
        log_ok "demo-03-svc ready"
        ready=1
        break
    fi
    # If the container has already exited, no point waiting 120s
    if ! podman ps --filter name=demo03-svc --filter status=running -q | grep -q .; then
        log_err "demo-03-svc container is NOT running — early exit"
        break
    fi
    sleep 1
done

if (( ready == 0 )); then
    echo
    log_err "Healthz never responded. Container state:"
    podman ps -a --filter name=demo03-svc --format '    {{.Names}} {{.Status}}'
    log_err "Aborting load phases — see logs from cleanup trap below"
    exit 1
fi
pause

# ── Step 2: gRPC load via ghz ──────────────────────────────────────────
#
# ghz is the canonical gRPC load generator. We run it in a container
# (ghcr.io/bojand/ghz) joined to the same network as demo-03-svc so it
# can reach the service by container name. The proto file is mounted
# read-only into the ghz container so it knows the service definition.
demo_step "Phase 1 — gRPC Echo load via ghz (10s, 50 concurrent)"
callout "gRPC uses completion QUEUES, not io_uring. Every RPC pays for HTTP/2" \
        "framing, HPACK headers, protobuf encode/decode, and deadline tracking" \
        "on top of the socket work. This is the fully-semantic end of the scale."
podman run --rm --network tutorial-obs \
    -v "$DIR/proto:/proto:ro,Z" \
    ghcr.io/bojand/ghz:0.120.0 \
        --insecure \
        --proto /proto/echo.proto \
        --call demo03.Echo.Echo \
        -d '{"payload":"aGVsbG8=","client_send_unix_nanos":0}' \
        -c 50 -z 10s \
        demo03-svc:50051 \
    || log_warn "ghz returned non-zero (often expected on stop signal)"
callout "" "Those per-RPC latencies also land in Grafana as the" \
        "demo3.grpc.latency histogram (we open Grafana at the end)."
pause

# ── Phase 2 & 3: TCP echo load via tcp-loadgen ─────────────────────────
#
# Run the loadgen binary that we built into the demo-03 image. Use
# `podman exec` to invoke it inside the running container, which is
# both simpler than mounting a binary in and ensures we hit the
# server over the loopback inside its own network namespace (the
# inter-container hop is ~the same as host-to-container in our
# setup, but loopback avoids any kube-proxy-style detours that may
# affect timing).
demo_step "Phase 2 — io_uring direct echo (:9000) load"
callout "Raw liburing: our own accept→read→write→read state machine drives" \
        "the submission/completion ring directly. No abstraction between us" \
        "and io_uring_enter(). 32 conns × 200 reqs × 256 B."
io_uring_json=$(podman exec demo03-svc \
    /usr/local/bin/tcp-loadgen 127.0.0.1 9000 32 200 256)
echo "    $io_uring_json"
pause

demo_step "Phase 3 — Asio io_uring echo (:9001) load"
callout "Same kernel calls as Phase 2, but the completion handling goes through" \
        "Asio's callbacks, shared_ptr lifetimes, allocator hooks, and executor" \
        "dispatch. Same protocol and load, so the delta is pure userland cost."
asio_json=$(podman exec demo03-svc \
    /usr/local/bin/tcp-loadgen 127.0.0.1 9001 32 200 256)
echo "    $asio_json"
pause

# ── Step 4: Summary table ──────────────────────────────────────────────
demo_step "Summary — TCP echo latency comparison"
if command -v jq >/dev/null 2>&1; then
    echo
    echo "==> 32 conns × 200 reqs × 256 B"
    echo
    printf "%-22s %10s %10s %10s %10s %15s\n" \
           "Backend" "min µs" "p50 µs" "p99 µs" "max µs" "throughput/s"
    printf -- "%-22s %10s %10s %10s %10s %15s\n" \
           "──────────────────────" "──────────" "──────────" "──────────" "──────────" "───────────────"
    for label in "io_uring direct:$io_uring_json" "Asio io_uring:$asio_json"; do
        name="${label%%:*}"
        json="${label#*:}"
        printf "%-22s %10d %10d %10d %10d %15.1f\n" \
            "$name" \
            "$(echo "$json" | jq .min_us)" \
            "$(echo "$json" | jq .p50_us)" \
            "$(echo "$json" | jq .p99_us)" \
            "$(echo "$json" | jq .max_us)" \
            "$(echo "$json" | jq .throughput_per_sec)"
    done
    echo
else
    log_warn "jq not installed — skipping the formatted summary table."
    log_info "Install jq to see the side-by-side comparison."
fi
callout "How to read these numbers:" \
        "  • Both go through io_uring, so the p50 gap is small — a few µs at" \
        "    most — because the KERNEL-side work is identical." \
        "  • Whichever wins, the takeaway is that the userland STRATEGY (how" \
        "    aggressively you batch submissions) matters more than direct-vs-" \
        "    wrapped. Asio often edges ahead by batching harder." \
        "  • p99/max divergence is scheduler tail (CFS preemption at quantum" \
        "    boundaries), not I/O work — that's where the ms outliers come from."
pause

# ── Step 5: Grafana — the gRPC instrumentation ─────────────────────────
demo_step "Inspect the gRPC instrumentation in Grafana"
grafana_callout "$GRAFANA_URL" \
  "'Demo 03 — io_uring + async gRPC' — Tutorial folder (Dashboards → Browse)" \
  "gRPC request rate      (stat)        — demo3_grpc_requests_total" \
  "gRPC latency p50/95/99 (timeseries)  — demo3_grpc_latency_milliseconds histogram" \
  "TCP conns/s            (timeseries)  — io_uring direct vs Asio" \
  "Recent gRPC traces     (table)       — Tempo, click a row for the span tree" \
  "Service logs           (logs)        — Loki"
callout "" "Prefer Explore? Paste these into a Prometheus Explore query:" \
        "  sum(rate(demo3_grpc_requests_total[1m]))" \
        "  histogram_quantile(0.99, sum(rate(demo3_grpc_latency_milliseconds_bucket[1m])) by (le))" \
        "  sum(rate(demo3_tcp_iouring_connections_total[1m]))" \
        "  sum(rate(demo3_tcp_asio_connections_total[1m]))" \
        "…and in a Tempo Explore, TraceQL: { resource.service.name=\"demo-03-svc\" }"
callout "The TCP echo servers are deliberately un-instrumented (they're the" \
        "'floor'); only the gRPC path carries OTel, so you can see what the" \
        "semantics cost — in latency AND in observable surface area."
pause

# ── Teardown ────────────────────────────────────────────────────────────
echo
if (( KEEP_UP == 0 )); then
    # Under the presentation cockpit, DON'T invite Ctrl-C here — a Ctrl-C at
    # this prompt would SIGINT the whole orchestrated run. Tear down quietly
    # (the EXIT trap does the actual work) and let the cockpit move on.
    if [[ "${DEMO_ORCHESTRATED:-0}" == "1" ]]; then
        log_info "Orchestrated run — tearing down demo-03 stack and continuing."
    else
        pause "Explore Grafana now if you like, then press Enter to tear down the stack"
    fi
else
    log_ok "Demo 03 complete — stack left up (--keep)."
fi
# The EXIT trap captures logs and performs the actual teardown.
