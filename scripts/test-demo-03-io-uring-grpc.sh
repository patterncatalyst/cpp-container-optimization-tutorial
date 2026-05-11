#!/usr/bin/env bash
# Demo-03 end-to-end verification.
#
# Mirrors test-demo-04-observability.sh in shape: brings up the stack,
# waits for everything to be ready, drives load, queries the backends
# for signals.
#
# Pass criteria:
#   1. Healthz responds 200 on :18403
#   2. gRPC Echo round-trip works (ghz reports >0 successful requests)
#   3. io_uring echo on :9000 round-trip works (tcp-loadgen reports
#      successful throughput)
#   4. Asio io_uring echo on :9001 round-trip works
#   5. demo3.grpc.requests metric is present in Mimir
#   6. demo3.tcp.iouring.connections metric is present in Mimir
#   7. demo3.tcp.asio.connections metric is present in Mimir
#   8. At least one trace named "grpc.Echo" is present in Tempo

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/_helpers.sh"

require podman curl jq

DEMO="$REPO_ROOT/examples/demo-03-io-uring-grpc"
OBS="$REPO_ROOT/observability/compose.yml"
COMPOSE=(podman compose -f compose.yml -f "$OBS")
cd "$DEMO"

cleanup() {
    log_step "tearing down"
    "${COMPOSE[@]}" down -v 2>/dev/null || true
}
trap cleanup EXIT

# ── Phase 1: bring up ────────────────────────────────────────────────

log_step "Phase 1 — bringing up demo-03 + LGTM (first run is slow)"
"${COMPOSE[@]}" up -d --build

log_step "Phase 1 — waiting for healthz on :18403"
if ! wait_for_http "http://127.0.0.1:18403" 120; then
    log_err "demo-03-svc never came up. Logs:"
    "${COMPOSE[@]}" logs --tail=60 demo-03-svc 2>&1 || true
    exit 1
fi
log_ok "demo-03-svc healthz ready"

log_step "Phase 1 — waiting for Grafana and LGTM backends"
for backend_name in grafana tempo loki mimir; do
    case "$backend_name" in
        grafana) url="http://127.0.0.1:3000/api/health" ;;
        tempo)   url="http://127.0.0.1:3200/ready"      ;;
        loki)    url="http://127.0.0.1:3100/ready"      ;;
        mimir)   url="http://127.0.0.1:9090/-/ready"    ;;
    esac
    if wait_for_http "$url" 90; then
        log_ok "  $backend_name: ready"
    else
        log_err "  $backend_name: NOT ready at $url"
        exit 1
    fi
done

# ── Phase 2: drive load ───────────────────────────────────────────────

log_step "Phase 2 — 10s gRPC load via ghz"
podman run --rm --network tutorial-obs \
    -v "$DEMO/proto:/proto:ro,Z" \
    ghcr.io/bojand/ghz:0.120.0 \
        --insecure --proto /proto/echo.proto \
        --call demo03.Echo.Echo \
        -d '{"payload":"aGVsbG8=","client_send_unix_nanos":0}' \
        -c 50 -z 10s \
        demo03-svc:50051 || true

log_step "Phase 2 — io_uring TCP echo load"
iouring_json=$(podman exec demo03-svc \
    /usr/local/bin/tcp-loadgen 127.0.0.1 9000 32 200 256)
log_info "  $iouring_json"

log_step "Phase 2 — Asio TCP echo load"
asio_json=$(podman exec demo03-svc \
    /usr/local/bin/tcp-loadgen 127.0.0.1 9001 32 200 256)
log_info "  $asio_json"

# Validate the loadgen JSON actually got back data:
for who in "iouring:$iouring_json" "asio:$asio_json"; do
    label="${who%%:*}"
    json="${who#*:}"
    n=$(echo "$json" | jq .reqs)
    if [[ "$n" == "null" || "$n" -lt 100 ]]; then
        log_err "$label load: expected ≥100 requests, got $n"
        exit 1
    fi
    log_ok "  $label: $n requests completed"
done

# ── Phase 3: drain interval, then probe backends ──────────────────────

log_step "Phase 3 — sleeping 15 s for export pipeline to drain"
sleep 15

log_step "Phase 4 — probing each backend for our signals"

# Mimir metric checks. Counters get a _total suffix by Mimir's PromQL,
# so we query for the suffixed names.
for metric in demo3_grpc_requests_total \
              demo3_tcp_iouring_connections_total \
              demo3_tcp_asio_connections_total; do
    url="http://127.0.0.1:9090/api/v1/query?query=${metric}"
    body=$(curl -fsS --max-time 5 "$url" 2>/dev/null || echo '{}')
    count=$(echo "$body" | jq '.data.result | length' 2>/dev/null || echo 0)
    if (( count > 0 )); then
        log_ok "  metric $metric present in Mimir"
    else
        log_err "  metric $metric NOT found in Mimir"
        log_err "    response: ${body:0:200}"
        exit 1
    fi
done

# Tempo trace check
trace_url="http://127.0.0.1:3200/api/search?tags=service.name%3Ddemo-03-svc&limit=5"
body=$(curl -fsS --max-time 5 "$trace_url" 2>/dev/null || echo '{}')
n=$(echo "$body" | jq '.traces | length' 2>/dev/null || echo 0)
if (( n > 0 )); then
    log_ok "  traces for service.name=demo-03-svc present in Tempo ($n)"
else
    log_err "  no traces found in Tempo for demo-03-svc"
    log_err "    response: ${body:0:200}"
    exit 1
fi

log_ok "test-demo-03 PASS — all signals reached the LGTM stack"
