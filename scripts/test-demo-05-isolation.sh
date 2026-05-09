#!/usr/bin/env bash
# Verify demo-05 builds both tenants and tenant-a answers /healthz under
# the unisolated scenario (the simplest one to exercise).

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/_helpers.sh
source "$REPO_ROOT/scripts/lib/_helpers.sh"

PORT=18905
CTR_A="test-demo-05-a"
CTR_B="test-demo-05-b"

require podman curl
register_cleanup "$CTR_A" "$CTR_B"

DEMO="$REPO_ROOT/examples/demo-05-isolation"
cd "$DEMO"

log_step "test-demo-05: build both tenants"
podman build --target tenant-a -t cpp-tut/demo-05:test-a .
podman build --target tenant-b -t cpp-tut/demo-05:test-b .

log_step "test-demo-05: run both, probe tenant-a"
podman run --rm -d --name "$CTR_A" -p "${PORT}:8080" cpp-tut/demo-05:test-a >/dev/null
podman run --rm -d --name "$CTR_B" cpp-tut/demo-05:test-b >/dev/null

if wait_for_http "http://127.0.0.1:${PORT}/healthz" 20; then
    log_ok "test-demo-05 PASS"
    exit 0
fi
log_err "test-demo-05 FAIL"
exit 1
