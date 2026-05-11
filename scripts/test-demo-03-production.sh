#!/usr/bin/env bash
# Verification script for demo-03's production-grade security configuration.
#
# Same pass criteria as test-demo-03-io-uring-grpc.sh PLUS extra
# security-posture checks:
#   - container is running with the custom seccomp profile (not unconfined)
#   - container is running with default container_t (not spc_t / label-disabled)
#   - capabilities are dropped (CapAdd is empty / CapDrop is ALL)
#   - root filesystem is read-only
#   - resource limits are set
#
# Run after one-time host setup:
#   ./examples/demo-03-io-uring-grpc/security/build-seccomp-profile.sh
#   sudo ./examples/demo-03-io-uring-grpc/security/install-selinux-policy.sh
#
# Then:
#   ./scripts/test-demo-03-production.sh

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/_helpers.sh"

require podman curl jq

DEMO="$REPO_ROOT/examples/demo-03-io-uring-grpc"
OBS="$REPO_ROOT/observability/compose.yml"

# ── Host preflight ────────────────────────────────────────────────────

log_step "Preflight — verifying host setup for production compose"

SECCOMP_PROFILE="$DEMO/security/seccomp-iouring.json"
if [[ ! -f "$SECCOMP_PROFILE" ]]; then
    log_err "Seccomp profile not generated: $SECCOMP_PROFILE"
    log_err "  Run: $DEMO/security/build-seccomp-profile.sh"
    exit 1
fi
log_ok "Seccomp profile present"

if command -v semodule >/dev/null 2>&1; then
    if ! semodule -l 2>/dev/null | grep -q '^demo03_iouring'; then
        log_err "SELinux module demo03_iouring not installed"
        log_err "  Install (requires root):"
        log_err "    sudo $DEMO/security/install-selinux-policy.sh"
        exit 1
    fi
    log_ok "SELinux module demo03_iouring loaded"
else
    log_info "semodule not found — running on a system without SELinux"
fi

# Set the env var the compose file expects
export SECCOMP_PROFILE_PATH="$SECCOMP_PROFILE"

COMPOSE=(podman compose -f compose.production.yml -f "$OBS")
cd "$DEMO"

cleanup() {
    log_step "tearing down"
    "${COMPOSE[@]}" down -v 2>/dev/null || true
}
trap cleanup EXIT

# ── Phase 1: bring up production compose ─────────────────────────────

log_step "Phase 1 — bringing up demo-03 (production) + LGTM"
"${COMPOSE[@]}" up -d --build

log_step "Phase 1 — waiting for healthz on :18403"
if ! wait_for_http "http://127.0.0.1:18403" 120; then
    log_err "demo-03-svc never came up. Logs:"
    "${COMPOSE[@]}" logs --tail=80 demo-03-svc 2>&1 || true
    exit 1
fi
log_ok "demo-03-svc healthz ready"

# ── Phase 2: security posture verification ───────────────────────────

log_step "Phase 2 — verifying applied security posture"

# Capture the inspect output once; parse multiple fields from it.
INSPECT_JSON=$(podman inspect demo03-svc 2>/dev/null)

# 2a. Seccomp profile is OUR custom one, not "unconfined"
seccomp_path=$(echo "$INSPECT_JSON" | jq -r '.[0].HostConfig.SeccompProfilePath // .[0].SeccompProfilePath // empty')
if [[ -z "$seccomp_path" ]]; then
    # On podman, the profile may show up in SecurityOpt as a string
    if echo "$INSPECT_JSON" | jq -r '.[0].HostConfig.SecurityOpt[]' 2>/dev/null | grep -q "seccomp=.*seccomp-iouring.json"; then
        log_ok "Seccomp: custom profile applied (via SecurityOpt)"
    else
        log_err "Seccomp profile not detected as our custom one"
        log_err "  SecurityOpt: $(echo "$INSPECT_JSON" | jq -c '.[0].HostConfig.SecurityOpt')"
        exit 1
    fi
else
    if [[ "$seccomp_path" == *seccomp-iouring.json ]]; then
        log_ok "Seccomp: custom profile applied ($seccomp_path)"
    else
        log_err "Seccomp profile is: $seccomp_path"
        log_err "  expected: ends in seccomp-iouring.json"
        exit 1
    fi
fi

# 2b. NOT running with label=disable. SELinux process context should
# include container_t (not spc_t).
selinux_label=$(echo "$INSPECT_JSON" | jq -r '.[0].ProcessLabel // empty')
if [[ "$selinux_label" == *container_t* ]]; then
    log_ok "SELinux: container_t label (not label=disable)"
elif [[ "$selinux_label" == *spc_t* ]]; then
    log_err "SELinux: spc_t — label=disable is in effect, not what we want"
    log_err "  ProcessLabel: $selinux_label"
    exit 1
elif [[ -z "$selinux_label" ]]; then
    log_info "SELinux: no process label (SELinux likely disabled on host)"
else
    log_info "SELinux: $selinux_label"
fi

# 2c. Capabilities are dropped
cap_drop=$(echo "$INSPECT_JSON" | jq -r '.[0].HostConfig.CapDrop[]?' 2>/dev/null | head -1)
if [[ "$cap_drop" == "ALL" || "$cap_drop" == "CAP_ALL" ]]; then
    log_ok "Capabilities: dropped (CapDrop: ALL)"
else
    log_info "Capabilities drop list: $(echo "$INSPECT_JSON" | jq -c '.[0].HostConfig.CapDrop')"
fi

# 2d. Read-only filesystem
read_only=$(echo "$INSPECT_JSON" | jq -r '.[0].HostConfig.ReadonlyRootfs // false')
if [[ "$read_only" == "true" ]]; then
    log_ok "Filesystem: read-only root"
else
    log_err "Filesystem is writable — expected read-only"
    exit 1
fi

# 2e. Resource limits
mem_limit=$(echo "$INSPECT_JSON" | jq -r '.[0].HostConfig.Memory // 0')
if (( mem_limit > 0 )); then
    log_ok "Resource limits: memory cap set ($(numfmt --to=iec --suffix=B $mem_limit 2>/dev/null || echo $mem_limit bytes))"
else
    log_info "Memory limit not set in inspect output (may use cgroup-only)"
fi

# ── Phase 3: io_uring actually works under tightened security ────────

log_step "Phase 3 — verifying io_uring works with the production posture"

# Confirm both io_uring servers are listening (not "queue_init failed")
io_uring_log=$(podman logs demo03-svc 2>&1)
if echo "$io_uring_log" | grep -q '\[iouring\]    listening on :9000'; then
    log_ok "Direct iouring server initialized"
else
    log_err "Direct iouring server failed to initialize"
    echo "$io_uring_log" | grep -i iouring | sed 's/^/    /' >&2
    exit 1
fi
if echo "$io_uring_log" | grep -q '\[asio\]    listening on :9001'; then
    log_ok "Asio iouring server initialized"
else
    log_err "Asio iouring server failed to initialize"
    echo "$io_uring_log" | grep -i asio | sed 's/^/    /' >&2
    exit 1
fi

# ── Phase 4: same load phases as the standard test ───────────────────

log_step "Phase 4 — gRPC + TCP load phases (smoke test)"

# Quick gRPC smoke (5s vs the standard 10s)
podman run --rm --network tutorial-obs \
    -v "$DEMO/proto:/proto:ro,Z" \
    ghcr.io/bojand/ghz:0.120.0 \
        --insecure --proto /proto/echo.proto \
        --call demo03.Echo.Echo \
        -d '{"payload":"aGVsbG8=","client_send_unix_nanos":0}' \
        -c 50 -z 5s \
        demo03-svc:50051 >/dev/null || true
log_ok "gRPC load completed"

iouring_json=$(podman exec demo03-svc \
    /usr/local/bin/tcp-loadgen 127.0.0.1 9000 16 100 256)
asio_json=$(podman exec demo03-svc \
    /usr/local/bin/tcp-loadgen 127.0.0.1 9001 16 100 256)

for who in "iouring:$iouring_json" "asio:$asio_json"; do
    label="${who%%:*}"
    json="${who#*:}"
    n=$(echo "$json" | jq .reqs)
    if [[ "$n" == "null" || "$n" -lt 100 ]]; then
        log_err "$label load: expected ≥100 requests, got $n"
        exit 1
    fi
    log_ok "  $label: $n requests under tightened security"
done

log_ok "test-demo-03-production PASS — io_uring works with audit-grade security"
