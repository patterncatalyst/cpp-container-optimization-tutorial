#!/usr/bin/env bash
# ============================================================================
# Demo 04 — Observability: an OTel-instrumented C++ service → Grafana LGTM
#
# One C++ service, instrumented once with the OpenTelemetry C++ SDK, emits
# all THREE signals — traces, metrics, logs — over OTLP/gRPC to the
# all-in-one grafana/otel-lgtm bundle (Grafana + Tempo + Loki +
# Prometheus/Mimir + OTel Collector). Then we watch them land in Grafana.
#
# KEY INSIGHT — read this before presenting:
#
#   The instrumentation API is the SAME as Java/Go/Python. A tracer, a
#   meter, a logger; spans, counters, histograms. C++ is not a
#   second-class citizen in observability — the same OTLP wire protocol,
#   the same collector, the same dashboards. What differs is the build
#   (opentelemetry-cpp compiled from source in the image), not the code.
#
#   THE ON-STAGE MOMENT is Step 4: open the "Demo overview" dashboard,
#   start the load, and watch the request-rate, latency, log, and trace
#   panels light up from a plain httplib C++ service.
#
# This script is a talk-through: it stops between steps (Press Enter) so
# you can narrate. Piped / non-interactive runs skip the pauses
# automatically (or pass --no-pause).
#
# Usage:
#   ./demo.sh                 full run (build, bring up, load, verify)
#   ./demo.sh --workload-only skip build/bring-up; drive an already-up stack
#   ./demo.sh --bpftrace      also run the kernel-level bpftrace view (sudo)
#   ./demo.sh --no-pause      never stop for Enter (unattended)
#   ./demo.sh --clean         tear the stack down and remove the image
# ============================================================================

set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DEMO_DIR"

# shellcheck source=../../scripts/lib/_helpers.sh
source "$(cd ../../scripts/lib && pwd)/_helpers.sh"

OBS_COMPOSE="$(cd ../../observability && pwd)/compose.yml"
COMPOSE=(podman compose -f compose.yml -f "$OBS_COMPOSE")

GRAFANA_URL="http://127.0.0.1:3000"
SVC_URL="http://127.0.0.1:18401"

WORKLOAD_ONLY=0
DO_BPFTRACE=0
DO_CLEAN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --workload-only) WORKLOAD_ONLY=1; shift;;
    --bpftrace)      DO_BPFTRACE=1;   shift;;
    --no-pause)      export DEMO_NO_PAUSE=1; shift;;
    --clean)         DO_CLEAN=1;      shift;;
    -h|--help)       sed -n '2,33p' "$0"; exit 0;;
    *) log_err "unknown arg: $1"; exit 2;;
  esac
done

if [[ $DO_CLEAN -eq 1 ]]; then
  "${COMPOSE[@]}" down -v 2>/dev/null || true
  podman rmi -f cpp-tut/demo-04:latest 2>/dev/null || true
  log_ok "Cleaned."
  exit 0
fi

require podman
HAVE_HEY=1; command -v hey >/dev/null 2>&1 || HAVE_HEY=0
HAVE_JQ=1;  command -v jq  >/dev/null 2>&1 || HAVE_JQ=0

banner \
  "DEMO 04 — Observability: OTel-instrumented C++ → Grafana LGTM" \
  "One C++ service. Three signals. Same OTLP wire as Java/Go."

callout \
  "Service:    $SVC_URL            (httplib, OTel C++ SDK)" \
  "Grafana:    $GRAFANA_URL              (anonymous viewer)" \
  "Signals:    traces → Tempo · metrics → Prometheus/Mimir · logs → Loki" \
  "Exporter:   OTLP/gRPC → lgtm:4317 (the bundled OTel Collector)"

# ── Step 1: Build and start ────────────────────────────────────────────────
if [[ $WORKLOAD_ONLY -eq 0 ]]; then
  demo_step "Build the service and bring up the LGTM stack"
  callout "First run compiles opentelemetry-cpp from source (~10-20 min)." \
          "Later runs hit the podman layer cache (~2-3 min)."
  if ! "${COMPOSE[@]}" up -d --build; then
    log_err "compose up failed — not going any further (nothing to observe)."
    "${COMPOSE[@]}" logs --tail=40 demo-04-svc 2>&1 || true
    exit 1
  fi

  log_step "Waiting for Grafana"
  if ! wait_for_http "$GRAFANA_URL/api/health" 120; then
    log_err "Grafana never came up. Recent lgtm logs:"
    "${COMPOSE[@]}" logs --tail=40 lgtm 2>&1 || true
    exit 1
  fi
  log_ok "Grafana ready"

  log_step "Waiting for the demo service"
  if ! wait_for_http "$SVC_URL/healthz" 60; then
    log_err "demo-04-svc never came up. Recent logs:"
    "${COMPOSE[@]}" logs --tail=40 demo-04-svc 2>&1 || true
    exit 1
  fi
  log_ok "demo-04-svc ready"
else
  demo_step "Using the already-running stack (--workload-only)"
  if ! wait_for_http "$SVC_URL/healthz" 10; then
    log_err "No service at $SVC_URL. Bring the stack up first (drop --workload-only)."
    exit 1
  fi
  log_ok "Service reachable"
fi

# ── Step 2: Show the service emitting all three signals ─────────────────────
demo_step "Confirm the C++ service is emitting all three signals"
callout "Every GET / does three things in ~40 lines of C++:" \
        "  • starts a span 'handle_request' with a child span 'compute'  (TRACE)" \
        "  • increments demo.requests and records demo.request.duration  (METRICS)" \
        "  • emits a 'request handled' log record                        (LOGS)"
code_ref "src/main.cpp" 162 "the GET / handler — StartSpan, counter->Add, hist->Record, EmitLogRecord"
code_ref "src/main.cpp" 153 "provider wiring — GetTracer/GetMeter/GetLogger, same as Java/Go"
echo
printf '  Priming a few requests: '
for _ in 1 2 3 4 5; do curl -sf "$SVC_URL/" >/dev/null 2>&1 && printf '.'; done
printf ' %sdone%s\n' "$C_GREEN" "$C_RESET"
callout "That's it. No agent, no sidecar — the SDK links into the binary" \
        "and speaks OTLP straight to the collector. Same three primitives" \
        "you'd use in Java or Go."
pause

# ── Step 3: Open Grafana BEFORE the load, so it populates live ──────────────
demo_step "Open the dashboard (before the load, so you watch it fill)"
grafana_callout "$GRAFANA_URL" \
  "'Demo overview' — Tutorial folder (Dashboards → Browse)" \
  "Request rate            (stat)        — Prometheus" \
  "Request latency p50/p95/p99 (ms)      — Prometheus histogram" \
  "Service logs            (logs panel)  — Loki" \
  "Recent traces           (table)       — Tempo, click a row for the span tree"
callout "Set the time range to 'Last 15 minutes' and auto-refresh to 5s."
pause "Grafana open on the Demo overview dashboard? Press Enter to start load"

# ── Step 4: Generate workload — the panels light up ─────────────────────────
demo_step "Generate workload — watch the panels move"
if [[ $HAVE_HEY -eq 1 ]]; then
  callout "60s of steady traffic (hey -c 25). Watch request-rate climb and" \
          "the p99 line settle. Logs stream in; traces accumulate."
  hey -z 60s -c 25 "$SVC_URL/" > /tmp/demo04-hey.out 2>&1 || true
  echo
  awk '/Total:|Slowest:|Fastest:|Average:|Requests\/sec:/' /tmp/demo04-hey.out | sed 's/^/  /'
else
  log_warn "hey not installed — driving a 600-iteration curl loop instead."
  callout "Install hey for a proper load profile: https://github.com/rakyll/hey"
  for _ in $(seq 1 600); do curl -s --max-time 1 "$SVC_URL/" >/dev/null 2>&1 || true; done
  printf '  %s600 requests sent%s\n' "$C_GREEN" "$C_RESET"
fi
callout "" "Everything on that dashboard came from one instrumented C++ binary."
pause

# ── Step 5: Prove the signals arrived end-to-end (the honest check) ─────────
demo_step "Prove it end-to-end: query each backend for our data"
callout "The dashboard is convincing, but let's confirm each signal actually" \
        "reached its store — and see how OTel names get translated on the way."
echo
# Let the export pipeline drain (metric reader ~5s, collector batch window).
sleep 8

probe() {  # probe <label> <url> <jq-matcher> <curl-flags...>
  local label="$1" url="$2" matcher="$3"; shift 3
  local body; body=$(curl -sf --max-time 5 "$@" "$url" 2>/dev/null || true)
  if [[ $HAVE_JQ -eq 1 ]]; then
    if [[ -n "$body" ]] && echo "$body" | jq -e "$matcher" >/dev/null 2>&1; then
      log_ok "  $label — present"; return 0
    fi
    log_warn "  $label — not found yet (pipeline may still be draining)"; return 1
  fi
  [[ -n "$body" ]] && log_ok "  $label — response received (install jq for a strict check)" \
                   || log_warn "  $label — no response"
}

log_info "TRACES  → Tempo: search service.name=demo-04-svc"
probe "trace " \
  "http://127.0.0.1:3200/api/search?tags=service.name%3Ddemo-04-svc&limit=5" \
  '.traces | length > 0' || true

log_info "METRICS → Prometheus: demo.requests becomes demo_requests_total"
callout "  OTel→Prom translation: dots→underscores, counters get _total."
probe "metric" \
  "http://127.0.0.1:9090/api/v1/query?query=demo_requests_total" \
  '.data.result | length > 0' || true

log_info 'LOGS    → Loki: {service_name="demo-04-svc"}'
callout '  Loki labels can'\''t hold dots: service.name → service_name.'
LOKI_START=$(( $(date -u +%s) - 300 ))000000000
LOKI_END=$(date -u +%s)000000000
probe "log   " \
  "http://127.0.0.1:3100/loki/api/v1/query_range?query=%7Bservice_name%3D%22demo-04-svc%22%7D&start=${LOKI_START}&end=${LOKI_END}&limit=5" \
  '.data.result | length > 0' || true
callout "" "In Grafana, a trace links to its logs (derived field TraceID) and" \
        "to its metrics (exemplars) — one click across all three pillars."
pause

# ── Step 6: bpftrace — the kernel's view (optional) ─────────────────────────
if [[ $DO_BPFTRACE -eq 1 ]]; then
  demo_step "Kernel-level view: bpftrace scheduler probe (needs sudo)"
  if ! command -v bpftrace >/dev/null 2>&1; then
    log_warn "bpftrace not found; install with 'sudo dnf install bpftrace'"
  else
    callout "OTel tells you WHAT your service did. bpftrace tells you what the" \
            "KERNEL did underneath — off-CPU time, scheduler switches. 10s:"
    sudo timeout 10 bpftrace ./bpftrace/sched_switch.bt || true
  fi
  pause
fi

# ── Step 7: Production tuning reference ──────────────────────────────────────
demo_step "Production tuning reference"
cat <<'FLAGS'
  # 1. Sample traces — 100% is fine in a demo, ruinous in production:
  OTEL_TRACES_SAMPLER=parentbased_traceidratio
  OTEL_TRACES_SAMPLER_ARG=0.05          # 5% head sampling

  # 2. Batch, don't send-per-span — SimpleSpanProcessor (this demo) is
  #    synchronous and blocks the request thread. In production use the
  #    BatchSpanProcessor (async, bounded queue) in the C++ SDK.

  # 3. Control metric cardinality — every distinct label VALUE is a
  #    time series. Never put request IDs / user IDs in metric labels;
  #    keep them on spans and logs.

  # 4. Set resource attributes once, at startup (env, not per-signal):
  OTEL_RESOURCE_ATTRIBUTES=service.namespace=shop,deployment.environment=prod
  OTEL_SERVICE_NAME=demo-04-svc

  # 5. Point the exporter at your real collector (not the app):
  OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317
FLAGS
echo

log_ok "Stack is up:"
log_info "  Grafana:    $GRAFANA_URL  (anonymous viewer)"
log_info "  Prometheus: http://127.0.0.1:9090"
log_info "  Tempo API:  http://127.0.0.1:3200"
log_info "  Loki API:   http://127.0.0.1:3100"
log_info "  Service:    $SVC_URL"

# ── Teardown ────────────────────────────────────────────────────────────────
echo
pause "Press Enter to tear down the stack (or Ctrl-C to leave it running)"
"${COMPOSE[@]}" down -v 2>/dev/null || true
log_ok "Demo 04 complete."
