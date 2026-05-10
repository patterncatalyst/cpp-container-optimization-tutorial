#!/usr/bin/env bash
# Smoke-test every podman-compose stack in the project. Brings each
# stack up briefly, waits for its health endpoint to respond, then
# brings it back down. Catches "this broke since last week" before
# you run a demo in front of an audience.
#
# Run this after pre-pull.sh and after any change to a compose file.
#
#   ./verify-stacks.sh             # test all stacks
#   ./verify-stacks.sh --quick     # skip the observability stack (slow)
#
# Each stack passes if it can `up`, respond to its smoke-test URL,
# and `down` cleanly. Any failure is reported with the stack's logs
# captured to /tmp/.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/_helpers.sh
source "$REPO_ROOT/scripts/lib/_helpers.sh"

QUICK=0
[[ "${1:-}" == "--quick" ]] && QUICK=1

require podman curl

# Stack inventory: name, compose file, health URL, timeout seconds.
# A stack here is anything brought up via `podman compose up`.
declare -a STACKS=(
    "observability:$REPO_ROOT/observability/compose.yml:http://127.0.0.1:3000/api/health:90"
    "demo-03:$REPO_ROOT/examples/demo-03-io-uring-grpc/compose.yml::15"
    "demo-04:$REPO_ROOT/examples/demo-04-observability/compose.yml:http://127.0.0.1:18401/healthz:60"
    "demo-06:$REPO_ROOT/examples/demo-06-quality-pipeline/compose.debug.yml::15"
)

PASS=0; FAIL=0
RESULTS=()

verify_stack() {
    local name="$1" compose="$2" url="$3" timeout="$4"
    local logfile="/tmp/verify-${name}.log"

    log_step "Verifying $name"

    if [[ ! -f "$compose" ]]; then
        log_err "compose file not found: $compose"
        FAIL=$((FAIL + 1))
        RESULTS+=("FAIL  $name  compose-missing")
        return
    fi

    # Bring up
    if ! podman compose -f "$compose" up -d --build > "$logfile" 2>&1; then
        log_err "  up failed; logs in $logfile"
        FAIL=$((FAIL + 1))
        RESULTS+=("FAIL  $name  up-failed")
        return
    fi

    # Health probe (only if a URL is given)
    local healthy=1
    if [[ -n "$url" ]]; then
        if wait_for_http "$url" "$timeout"; then
            healthy=0
        else
            log_err "  $url never returned 2xx"
            podman compose -f "$compose" logs >> "$logfile" 2>&1 || true
        fi
    else
        healthy=0   # no URL = trust the up
    fi

    # Bring down regardless
    podman compose -f "$compose" down -v >> "$logfile" 2>&1 || true

    if [[ $healthy -eq 0 ]]; then
        log_ok "  $name OK"
        PASS=$((PASS + 1))
        RESULTS+=("PASS  $name")
    else
        FAIL=$((FAIL + 1))
        RESULTS+=("FAIL  $name  health-timeout")
    fi
}

for entry in "${STACKS[@]}"; do
    IFS=':' read -r name compose url timeout <<< "$entry"
    if [[ "$name" == "observability" && $QUICK -eq 1 ]]; then
        log_warn "Skipping observability (slow); --quick was set"
        continue
    fi
    verify_stack "$name" "$compose" "$url" "$timeout"
done

# ── Summary ─────────────────────────────────────────────────────────────
echo
log_step "Summary"
printf '%s\n' "${RESULTS[@]}"
echo
TOTAL=$((PASS + FAIL))
if (( FAIL == 0 )); then
    log_ok "All ${TOTAL} stacks verified."
    exit 0
else
    log_err "${FAIL} of ${TOTAL} stacks failed. Logs in /tmp/verify-*.log."
    exit 1
fi
