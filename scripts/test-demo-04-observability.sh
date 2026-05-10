#!/usr/bin/env bash
# Demo-04 end-to-end verification — option B kickoff (round r28).
#
# Verifies the full data path:
#   service emits signals via OTLP/gRPC
#       → grafana/otel-lgtm's bundled OTel collector
#           → Tempo (traces) / Mimir (metrics) / Loki (logs)
#               → query API returns the data this script just generated
#
# Earlier shape of this script was a smoke test that only verified
# Grafana /api/health + the service /healthz. That's necessary but
# not sufficient: the stack can be "up" while signals silently
# disappear (mis-routed exporter, bad metric name, label drop). This
# version closes that gap.
#
# Usage:
#   ./scripts/test-demo-04-observability.sh                  # full run
#   ./scripts/test-demo-04-observability.sh --keep           # don't tear down
#   ./scripts/test-demo-04-observability.sh --probe-only     # skip up/load,
#                                                            # just probe
#                                                            # an already-running stack
#
# The first run takes 10-20 minutes because the Containerfile builds
# opentelemetry-cpp from source. Subsequent runs hit the podman layer
# cache and complete in 2-3 minutes.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/_helpers.sh
source "$REPO_ROOT/scripts/lib/_helpers.sh"

# ── arg parsing ─────────────────────────────────────────────────────────

KEEP_UP=0
PROBE_ONLY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep)        KEEP_UP=1; shift ;;
        --probe-only)  PROBE_ONLY=1; KEEP_UP=1; shift ;;
        -h|--help)
            sed -n '2,30p' "$0"
            exit 0
            ;;
        *)
            log_err "unknown arg: $1"
            exit 2
            ;;
    esac
done

require podman curl jq

DEMO="$REPO_ROOT/examples/demo-04-observability"
OBS="$REPO_ROOT/observability/compose.yml"
COMPOSE=(podman compose -f compose.yml -f "$OBS")
cd "$DEMO"

# ── cleanup ──────────────────────────────────────────────────────────────

cleanup() {
    local rc=$?
    if (( KEEP_UP == 0 )); then
        log_step "tearing down"
        "${COMPOSE[@]}" down -v 2>/dev/null || true
    else
        log_info "stack left running. Tear down with:"
        log_info "  cd $DEMO && ${COMPOSE[*]} down -v"
    fi
    return "$rc"
}
trap cleanup EXIT

# ── Phase 1: bring up ─────────────────────────────────────────────────────

if (( PROBE_ONLY == 0 )); then
    log_step "Phase 1 — bringing up stack + service (--build; first run is slow)"
    "${COMPOSE[@]}" up -d --build

    log_step "Phase 1 — waiting for Grafana /api/health"
    if ! wait_for_http "http://127.0.0.1:3000/api/health" 120; then
        log_err "Grafana never came up. Logs:"
        "${COMPOSE[@]}" logs --tail=40 lgtm 2>&1 || true
        exit 1
    fi
    log_ok "Grafana ready"

    log_step "Phase 1 — waiting for demo-04-svc /healthz"
    if ! wait_for_http "http://127.0.0.1:18401/healthz" 60; then
        log_err "demo-04-svc never came up. Logs:"
        "${COMPOSE[@]}" logs --tail=40 demo-04-svc 2>&1 || true
        exit 1
    fi
    log_ok "demo-04-svc ready"
fi

# ── Phase 2: each LGTM backend's API is reachable ─────────────────────────

log_step "Phase 2 — confirming each LGTM backend is ready"
declare -A BACKENDS=(
    [tempo]="http://127.0.0.1:3200/ready"
    [loki]="http://127.0.0.1:3100/ready"
    [mimir]="http://127.0.0.1:9090/-/ready"
)
backend_errors=0
for name in tempo loki mimir; do
    url="${BACKENDS[$name]}"
    if curl -sf --max-time 3 "$url" >/dev/null 2>&1; then
        log_ok "  $name: ready ($url)"
    else
        log_err "  $name: NOT ready at $url"
        backend_errors=$((backend_errors + 1))
    fi
done
if (( backend_errors > 0 )); then
    log_err "$backend_errors/3 backends not ready; aborting"
    exit 1
fi

# ── Phase 3: generate workload ────────────────────────────────────────────

if (( PROBE_ONLY == 0 )); then
    if command -v hey >/dev/null 2>&1; then
        log_step "Phase 3 — 30 s of workload via hey"
        hey -z 30s -c 10 -q 50 "http://127.0.0.1:18401/" \
            > /tmp/demo04-hey.out 2>&1 || true
        awk '/Total:|Average:|Slowest:|Fastest:|Requests\/sec:/' \
            /tmp/demo04-hey.out | head -5
    else
        log_warn "hey not installed; using a 200-iteration curl loop instead"
        for _ in $(seq 1 200); do
            curl -s --max-time 1 "http://127.0.0.1:18401/" >/dev/null 2>&1 || true
        done
    fi

    # Metric reader exports every 5 s; SimpleSpanProcessor is sync but
    # the collector still has its own batching window; logs use Simple too.
    # 15 s is comfortably past every flush interval in the pipeline.
    log_step "Phase 3 — sleeping 15 s for the export pipeline to drain"
    sleep 15
fi

# ── Phase 4: signal-arrival probes (with retry) ────────────────────────────
#
# Each probe polls up to 10× over ~30 s. The pipeline normally settles
# in 5-10 s; the extra cushion accommodates a slow first ingest after
# the stack has just come up.

poll_signal() {
    local name="$1" url="$2" matcher="$3"
    local body=""
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        body=$(curl -sf --max-time 5 -G "$url" 2>/dev/null || true)
        if [[ -n "$body" ]] && echo "$body" | jq -e "$matcher" >/dev/null 2>&1; then
            log_ok "  $name: present (attempt $attempt)"
            return 0
        fi
        sleep 3
    done
    log_err "  $name: NOT FOUND after 10 attempts (~30 s)"
    if [[ -n "$body" ]]; then
        log_err "  last response (truncated): $(echo "$body" | head -c 300)"
    else
        log_err "  last response: <empty>"
    fi
    return 1
}

log_step "Phase 4 — probing each backend for our signals"

signal_errors=0

# Traces — Tempo's search API takes the OTLP attribute names as-is
# (service.name with the dot). Most builds also accept the URL-encoded
# form. We use the newer tags= form; if your Tempo version uses the
# older singular tag= form, the matcher will fail and the error block
# below will surface it.
log_info "  → Tempo: trace search for service.name=demo-04-svc"
TEMPO_URL="http://127.0.0.1:3200/api/search?tags=service.name%3Ddemo-04-svc&limit=5"
poll_signal "trace" "$TEMPO_URL" '.traces | length > 0' \
    || signal_errors=$((signal_errors + 1))

# Metrics — counter "demo.requests" → Prometheus name
# "demo_requests_total" via OTLP → Prom translation. (Counters get the
# `_total` suffix; dots become underscores.) A non-zero result with
# any value is enough; we already generated workload.
log_info "  → Mimir: query demo_requests_total"
MIMIR_URL="http://127.0.0.1:9090/api/v1/query?query=demo_requests_total"
poll_signal "metric" "$MIMIR_URL" '.data.result | length > 0' \
    || signal_errors=$((signal_errors + 1))

# Logs — Loki labels can't contain dots, so OTel's resource attribute
# service.name="demo-04-svc" lands as label service_name="demo-04-svc".
# Time window: Loki rejects queries without start/end, so set them to
# the last 5 minutes (in nanoseconds, the format Loki wants).
log_info '  → Loki: query {service_name="demo-04-svc"}'
LOKI_START=$(( $(date -u +%s) - 300 ))000000000
LOKI_END=$(date -u +%s)000000000
LOKI_URL="http://127.0.0.1:3100/loki/api/v1/query_range"
LOKI_FULL="${LOKI_URL}?query=%7Bservice_name%3D%22demo-04-svc%22%7D"
LOKI_FULL="${LOKI_FULL}&start=${LOKI_START}&end=${LOKI_END}&limit=5"
poll_signal "log" "$LOKI_FULL" '.data.result | length > 0' \
    || signal_errors=$((signal_errors + 1))

# ── Phase 5: result ───────────────────────────────────────────────────────

if (( signal_errors == 0 )); then
    log_step "test-demo-04 PASS — 3/3 signals reached the LGTM stack end-to-end"
    log_info "Open Grafana to inspect manually:  http://127.0.0.1:3000"
    log_info "  Tempo search:  service.name=demo-04-svc"
    log_info "  Mimir query:   demo_requests_total"
    log_info '  Loki query:    {service_name="demo-04-svc"}'
    log_info "  Dashboard:     'Demo overview' under the 'Tutorial' folder"
    exit 0
else
    log_err "test-demo-04 FAIL — $signal_errors/3 signals missing"
    log_err "Common causes (G-NN entries in plan if you hit one):"
    log_err "  - Metric name mismatch: try 'demo_requests' instead of"
    log_err "    'demo_requests_total' if Mimir's translator differs."
    log_err "  - Loki label drop: confirm with curl-direct probe at"
    log_err "    http://127.0.0.1:3100/loki/api/v1/labels"
    log_err "  - Trace API drift: try /api/search?tag=service.name= (no s)"
    log_err "  - Pipeline still draining: rerun with --probe-only after"
    log_err "    another 10 s; if it then passes the issue is the wait."
    exit 1
fi
