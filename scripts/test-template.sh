#!/usr/bin/env bash
# Template for per-demo verification scripts.
#
# Copy this to scripts/test-demo-XX-thing.sh, change PORT and DEMO_DIR,
# and customize the assertion. Each test script must:
#   - source _helpers.sh
#   - set -euo pipefail
#   - use a port distinct from every other test (we use 18900-18999 for
#     test-only ports, leaving 18800-18899 for the demos themselves)
#   - clean up its containers via register_cleanup
#   - exit 0 on success, non-zero on failure with a clear message

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/_helpers.sh
source "$REPO_ROOT/scripts/lib/_helpers.sh"

# ---- customize per test ----
PORT=18999            # distinct per script
CTR="test-template"
IMAGE="cpp-tut/demo-XX:tag"
HEALTH="http://127.0.0.1:${PORT}/healthz"
# ---------------------------

require podman curl
register_cleanup "$CTR"

log_step "test-template starting"
podman run --rm -d --name "$CTR" -p "${PORT}:8080" "$IMAGE" >/dev/null

if wait_for_http "$HEALTH" 30; then
    log_ok "test-template OK"
    exit 0
else
    log_err "test-template FAILED: $HEALTH did not come up"
    exit 1
fi
