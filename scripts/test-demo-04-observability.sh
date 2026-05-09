#!/usr/bin/env bash
# Verify demo-04 brings up the observability stack and the demo service
# answers /healthz.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/_helpers.sh
source "$REPO_ROOT/scripts/lib/_helpers.sh"

require podman curl

DEMO="$REPO_ROOT/examples/demo-04-observability"
OBS="$REPO_ROOT/observability/compose.yml"
cd "$DEMO"

# Bring up only what we need: the stack + the service. Tear down on EXIT.
cleanup() {
  podman compose -f compose.yml -f "$OBS" down -v 2>/dev/null || true
}
trap cleanup EXIT

log_step "test-demo-04: bring up stack + service"
podman compose -f compose.yml -f "$OBS" up -d --build

log_step "test-demo-04: wait for Grafana"
if ! wait_for_http "http://127.0.0.1:3000/api/health" 90; then
    log_err "test-demo-04 FAIL: Grafana never became healthy"
    exit 1
fi

log_step "test-demo-04: wait for service"
if ! wait_for_http "http://127.0.0.1:18401/healthz" 60; then
    log_err "test-demo-04 FAIL: demo service never became healthy"
    exit 1
fi

log_ok "test-demo-04 PASS"
exit 0
