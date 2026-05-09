#!/usr/bin/env bash
# Verify demo-03's gRPC server target builds and accepts a TCP connection.
# We don't run a gRPC RPC in the test (would need ghz / grpcurl); we
# just probe the listening port.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/_helpers.sh
source "$REPO_ROOT/scripts/lib/_helpers.sh"

PORT=18903
CTR="test-demo-03"

require podman bash
register_cleanup "$CTR"

DEMO="$REPO_ROOT/examples/demo-03-io-uring-grpc"
cd "$DEMO"

log_step "test-demo-03: build grpc-async target"
podman build --target grpc-async -t cpp-tut/demo-03:test .

log_step "test-demo-03: run + check port"
podman run --rm -d --name "$CTR" -p "${PORT}:50051" cpp-tut/demo-03:test >/dev/null

# Wait for the port to be open (exec runs inside this shell).
deadline=$(( $(date +%s) + 20 ))
while (( $(date +%s) < deadline )); do
    # /dev/tcp test using bash builtin; works without nc/curl.
    if (echo > /dev/tcp/127.0.0.1/$PORT) >/dev/null 2>&1; then
        log_ok "test-demo-03 PASS (port $PORT open)"
        exit 0
    fi
    sleep 0.5
done

log_err "test-demo-03 FAIL: port $PORT did not open within 20s"
exit 1
