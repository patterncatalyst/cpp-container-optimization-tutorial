#!/usr/bin/env bash
# Demo 4 — observability stack: spin up Grafana/Tempo/Loki/Mimir/Prom +
# the OTel-instrumented service, generate load, optionally run bpftrace.
#
#   ./demo.sh
#   ./demo.sh --workload-only
#   ./demo.sh --bpftrace
#   ./demo.sh --clean

set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DEMO_DIR"

# shellcheck source=../../scripts/lib/_helpers.sh
source "$(cd ../../scripts/lib && pwd)/_helpers.sh"

OBS_COMPOSE="$(cd ../../observability && pwd)/compose.yml"
COMPOSE=(podman compose -f compose.yml -f "$OBS_COMPOSE")

WORKLOAD_ONLY=0
DO_BPFTRACE=0
DO_CLEAN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --workload-only) WORKLOAD_ONLY=1; shift;;
    --bpftrace)      DO_BPFTRACE=1;   shift;;
    --clean)         DO_CLEAN=1;      shift;;
    *) log_err "unknown arg: $1"; exit 2;;
  esac
done

if [[ $DO_CLEAN -eq 1 ]]; then
  "${COMPOSE[@]}" down -v 2>/dev/null || true
  podman rmi -f cpp-tut/demo-04:latest 2>/dev/null || true
  log_ok "Cleaned."
  exit 0
fi

require podman hey

if [[ $WORKLOAD_ONLY -eq 0 ]]; then
  log_step "Bringing up the observability stack + service"
  "${COMPOSE[@]}" up -d --build
fi

log_step "Waiting for Grafana"
wait_for_http "http://127.0.0.1:3000/api/health" 60

log_step "Waiting for the demo service"
wait_for_http "http://127.0.0.1:18401/healthz" 30

log_step "Generating workload (60s of steady traffic)"
hey -z 60s -c 25 "http://127.0.0.1:18401/" > /tmp/demo04-hey.out 2>&1 || true
tail -n 20 /tmp/demo04-hey.out

if [[ $DO_BPFTRACE -eq 1 ]]; then
  if ! command -v bpftrace >/dev/null 2>&1; then
    log_warn "bpftrace not found; install it with 'sudo dnf install bpftrace'"
  else
    log_step "Running bpftrace probes (10s; needs sudo)"
    sudo timeout 10 bpftrace ./bpftrace/sched_switch.bt || true
  fi
fi

log_ok "Stack is up:"
log_info "  Grafana:    http://127.0.0.1:3000  (anonymous viewer)"
log_info "  Prometheus: http://127.0.0.1:9090"
log_info "  Tempo API:  http://127.0.0.1:3200"
log_info "  Loki API:   http://127.0.0.1:3100"
log_info "  Mimir API:  http://127.0.0.1:9009"
log_info "  Service:    http://127.0.0.1:18401"
log_info "Tear down with: ./demo.sh --clean"
