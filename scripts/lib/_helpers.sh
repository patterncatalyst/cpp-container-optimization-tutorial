# Shared helpers for tutorial scripts.
# Source this file; do not execute it directly.
#
#   set -euo pipefail
#   source "$(dirname "$0")/lib/_helpers.sh"

# Colors. Honor NO_COLOR if set or if stdout is not a tty.
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_DIM=$'\033[2m'
    C_BOLD=$'\033[1m'
    C_RESET=$'\033[0m'
else
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    C_BLUE=""
    C_DIM=""
    C_BOLD=""
    C_RESET=""
fi

log_info()  { printf '%s[info]%s  %s\n'  "$C_BLUE"   "$C_RESET" "$*"; }
log_ok()    { printf '%s[ ok ]%s  %s\n'  "$C_GREEN"  "$C_RESET" "$*"; }
log_warn()  { printf '%s[warn]%s  %s\n'  "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_err()   { printf '%s[fail]%s  %s\n'  "$C_RED"    "$C_RESET" "$*" >&2; }
log_step()  { printf '\n%s==>%s %s%s%s\n' "$C_BLUE" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; }

# Resolve the repo root by walking up from this file.
repo_root() {
    local d
    d="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    printf '%s' "$d"
}

# require <cmd> [<cmd> ...] — fail fast if any aren't on PATH.
require() {
    local missing=()
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    if (( ${#missing[@]} > 0 )); then
        log_err "missing required command(s): ${missing[*]}"
        log_err "see GETTING-STARTED.md for installation"
        return 1
    fi
}

# wait_for_http <url> [timeout_seconds]
# Polls until the URL returns any 2xx/3xx, or the timeout elapses.
wait_for_http() {
    local url="$1"
    local timeout="${2:-30}"
    local start
    start=$(date +%s)
    while :; do
        if curl -fsS --max-time 2 "$url" >/dev/null 2>&1; then
            return 0
        fi
        if (( $(date +%s) - start >= timeout )); then
            log_err "timed out after ${timeout}s waiting for $url"
            return 1
        fi
        sleep 0.5
    done
}

# Container cleanup. Set CLEANUP_CONTAINERS to a space-separated list
# of names; the trap below will remove them.
CLEANUP_CONTAINERS="${CLEANUP_CONTAINERS:-}"
cleanup_containers() {
    local rc=$?
    if [[ -n "$CLEANUP_CONTAINERS" ]]; then
        for c in $CLEANUP_CONTAINERS; do
            podman rm -f "$c" >/dev/null 2>&1 || true
        done
    fi
    return $rc
}

# Register a name to be cleaned up on EXIT. Safe to call multiple times.
register_cleanup() {
    CLEANUP_CONTAINERS="$CLEANUP_CONTAINERS $*"
    # shellcheck disable=SC2064
    trap cleanup_containers EXIT
}

# Pretty section header.
section() {
    printf '\n%s%s%s\n%s%s%s\n' \
        "$C_BOLD" "$*" "$C_RESET" \
        "$C_DIM" "$(printf '%.0s-' $(seq 1 ${#1}))" "$C_RESET"
}

# ── Presentation helpers ────────────────────────────────────────────────
# Used by the demo.sh scripts to give a live, talk-through-able shape:
# numbered stops, presenter pauses, on-stage framing, and callouts.
# (Verification scripts under scripts/test-*.sh do NOT use these — they
# stay non-interactive.)

# Full-width horizontal rules. Width follows COLUMNS when known, capped
# at 66 so the output looks the same on a projector as in a terminal.
_hr_width() { local w="${COLUMNS:-66}"; (( w > 66 )) && w=66; printf '%s' "$w"; }
hr()      { printf '%s' "$C_DIM"; printf '─%.0s' $(seq 1 "$(_hr_width)"); printf '%s\n' "$C_RESET"; }
hr_thin() { printf '%s' "$C_DIM"; printf '·%.0s' $(seq 1 "$(_hr_width)"); printf '%s\n' "$C_RESET"; }

# banner "LINE 1" ["LINE 2" ...] — the demo's opening title card.
banner() {
    printf '\n%s%s\n' "$C_BOLD$C_BLUE" "$(hr)"
    local line
    for line in "$@"; do printf '%s  %s%s\n' "$C_BOLD$C_BLUE" "$line" "$C_RESET"; done
    printf '%s%s\n' "$C_BOLD$C_BLUE" "$(hr)"
    printf '%s' "$C_RESET"
}

# A monotonically-increasing step counter so scripts don't hard-code
# numbers (renumbering when a step is inserted is a common source of drift).
DEMO_STEP_NUM=0
# demo_step "Title" — numbered, rule-wrapped stop header.
demo_step() {
    DEMO_STEP_NUM=$((DEMO_STEP_NUM + 1))
    printf '\n'; hr
    printf '%sStep %d: %s%s\n' "$C_BOLD$C_YELLOW" "$DEMO_STEP_NUM" "$*" "$C_RESET"
    hr
}

# callout "line" ["line" ...] — an indented, dimmed on-stage framing block
# ("here's what to say / what to look at while this runs").
callout() {
    local line
    for line in "$@"; do printf '  %s%s%s\n' "$C_DIM" "$line" "$C_RESET"; done
}

# grafana_callout <url> "Dashboard name" "panel/thing to look at" ...
# The recurring "now switch to Grafana and look at X" moment.
grafana_callout() {
    local url="$1" dash="$2"; shift 2
    printf '  %s▸ Open Grafana:%s  %s%s%s\n' "$C_BOLD$C_GREEN" "$C_RESET" "$C_GREEN" "$url" "$C_RESET"
    printf '    %sDashboard:%s %s\n' "$C_BOLD" "$C_RESET" "$dash"
    local thing
    for thing in "$@"; do printf '      • %s\n' "$thing"; done
}

# pause ["prompt"] — presenter stop. Skipped automatically when stdin is
# not a TTY or DEMO_NO_PAUSE=1 (CI, piped runs, --no-pause), so the same
# script is both a live demo and a hands-off run.
pause() {
    local prompt="${1:-Press Enter to continue…}"
    if [[ "${DEMO_NO_PAUSE:-0}" == "1" ]] || [[ ! -t 0 ]]; then
        printf '  %s(%s)%s\n' "$C_DIM" "$prompt" "$C_RESET"
        return 0
    fi
    printf '\n  %s⏎ %s%s ' "$C_BOLD$C_BLUE" "$prompt" "$C_RESET"
    read -r _
}

# Format bytes as KB/MB/GB. Used for image-size comparison tables.
human_bytes() {
    local b="$1"
    if (( b < 1024 )); then printf '%dB' "$b"
    elif (( b < 1048576 )); then printf '%.1fKB' "$(echo "$b/1024" | bc -l)"
    elif (( b < 1073741824 )); then printf '%.1fMB' "$(echo "$b/1048576" | bc -l)"
    else printf '%.2fGB' "$(echo "$b/1073741824" | bc -l)"
    fi
}
