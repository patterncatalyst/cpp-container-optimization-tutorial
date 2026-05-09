#!/usr/bin/env bash
# Verify demo-01 produces an image that responds on /healthz.
# Builds the cheapest variant only (ubi-multistage) for speed.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/_helpers.sh
source "$REPO_ROOT/scripts/lib/_helpers.sh"

PORT=18901
CTR="test-demo-01"

require podman curl
register_cleanup "$CTR"

DEMO="$REPO_ROOT/examples/demo-01-image-strategy"
cd "$DEMO"

log_step "test-demo-01: build ubi-multistage variant"
HTTPLIB_VERSION=v0.16.0
[[ -f src/third_party/httplib.h ]] || \
    curl -fsSL -o src/third_party/httplib.h \
        "https://raw.githubusercontent.com/yhirose/cpp-httplib/${HTTPLIB_VERSION}/httplib.h"
podman build -f Containerfile.ubi-multistage -t cpp-tut/demo-01:test-mst .

log_step "test-demo-01: run + probe"
podman run --rm -d --name "$CTR" -p "${PORT}:8080" cpp-tut/demo-01:test-mst >/dev/null

if wait_for_http "http://127.0.0.1:${PORT}/healthz" 20; then
    log_ok "test-demo-01 PASS"
    exit 0
fi
log_err "test-demo-01 FAIL: service did not come up"
exit 1
