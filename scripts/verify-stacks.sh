#!/usr/bin/env bash
# Smoke-test the shared observability stack (and any other stacks
# we've explicitly verified end-to-end). Brings each up briefly,
# probes its health endpoint, brings it down. Catches "broke since
# last week" before you run a demo in front of an audience.
#
#   ./scripts/verify-stacks.sh             # verify all listed stacks
#   ./scripts/verify-stacks.sh --quick     # skip slow stacks (e.g. observability)
#
# Per-demo end-to-end verification lives in scripts/test-demo-NN-*.sh,
# not here. This script is for SHARED infrastructure that demos depend
# on. Add a stack to STACK_NAMES below only after you've personally
# verified it cleans up properly.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/_helpers.sh
source "$SCRIPT_DIR/lib/_helpers.sh"

QUICK=0
[[ "${1:-}" == "--quick" ]] && QUICK=1

require podman curl

# ── Stack inventory ──────────────────────────────────────────────────────
# Parallel arrays so URLs containing colons don't break field-splitting.
# Each index corresponds to one stack: name, compose path, health URL,
# timeout in seconds, and a boolean "slow" flag (skipped under --quick).
#
# Add a new stack only after running `podman compose -f <file> up -d`
# manually and watching it come up green. This script is downstream of
# that work, not a substitute for it.

STACK_NAMES=(  "observability" )
STACK_FILES=(  "$REPO_ROOT/observability/compose.yml" )
STACK_URLS=(   "http://127.0.0.1:3000/api/health" )
STACK_TIMEOUTS=( 90 )
STACK_SLOW=(   1 )

PASS=0; FAIL=0; SKIP=0
RESULTS=()

verify_stack() {
    local name="$1" compose="$2" url="$3" timeout="$4"
    local logfile="/tmp/verify-${name}.log"

    log_step "Verifying $name"

    if [[ ! -f "$compose" ]]; then
        log_err "  compose file not found: $compose"
        FAIL=$((FAIL + 1))
        RESULTS+=("FAIL  $name  compose-missing")
        return
    fi

    if ! podman compose -f "$compose" up -d > "$logfile" 2>&1; then
        log_err "  up failed; see $logfile"
        FAIL=$((FAIL + 1))
        RESULTS+=("FAIL  $name  up-failed")
        return
    fi

    local healthy=1
    if [[ -n "$url" ]]; then
        if wait_for_http "$url" "$timeout"; then
            healthy=0
            log_ok "  health probe OK"
        else
            log_err "  health probe failed; appending logs to $logfile"
            podman compose -f "$compose" logs >> "$logfile" 2>&1 || true
        fi
    else
        healthy=0
    fi

    podman compose -f "$compose" down -v >> "$logfile" 2>&1 || true

    if [[ $healthy -eq 0 ]]; then
        PASS=$((PASS + 1))
        RESULTS+=("PASS  $name")
    else
        FAIL=$((FAIL + 1))
        RESULTS+=("FAIL  $name  health-timeout")
    fi
}

# ── Run loop ─────────────────────────────────────────────────────────────
for i in "${!STACK_NAMES[@]}"; do
    name="${STACK_NAMES[$i]}"
    compose="${STACK_FILES[$i]}"
    url="${STACK_URLS[$i]}"
    timeout="${STACK_TIMEOUTS[$i]}"
    slow="${STACK_SLOW[$i]}"

    if [[ "$slow" == "1" && $QUICK -eq 1 ]]; then
        log_warn "Skipping $name (slow); --quick was set"
        SKIP=$((SKIP + 1))
        RESULTS+=("SKIP  $name  --quick")
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
if (( SKIP > 0 )); then
    log_info "${SKIP} stack(s) skipped under --quick"
fi
if (( FAIL == 0 && TOTAL > 0 )); then
    log_ok "All ${TOTAL} verified stack(s) passed."
    log_info "Per-demo verification: scripts/test-demo-NN-*.sh"
    exit 0
elif (( TOTAL == 0 )); then
    log_warn "Nothing was verified (everything skipped)."
    exit 0
else
    log_err "${FAIL} of ${TOTAL} stack(s) failed. Logs in /tmp/verify-*.log."
    exit 1
fi
