#!/usr/bin/env bash
# scripts/cgroup-delegation.sh — manage cgroup v2 controller delegation
# for rootless podman.
#
# Background (see _docs/01-prerequisites.md and demo-05's README):
#
# Rootless podman containers run inside cgroups parented to the user's
# systemd slice (user@$UID.service). For podman to apply CPU/memory/io
# resource limits to those child cgroups, the user slice itself must
# have the respective controllers delegated to it — meaning the
# controllers are listed in the slice's cgroup.subtree_control.
#
# Default systemd configurations delegate only `memory` and `pids` to
# user slices, which is enough for most containers but insufficient
# for podman's --cpu-weight, --cpus, --cpuset-cpus, --device-read-bps
# and similar flags. demo-05's weighted and pinned scenarios both
# require this delegation; without it they skip with N/A.
#
# This script provides four subcommands:
#
#   check    Show current delegation state (no changes; default)
#   enable   Install systemd drop-in to enable cpu/cpuset/io/memory/pids
#   disable  Remove the drop-in installed by `enable`
#   verify   Quick pass/fail check for use in tests and CI
#
# The `enable` and `disable` actions touch /etc/systemd/system/ and
# require root; the script uses sudo internally for just those calls.
# `check` and `verify` are read-only and run as the invoking user.
#
# After `enable` you must re-login (or reboot) for the controllers to
# be applied to your user slice. The script does NOT automatically run
# `loginctl terminate-user` because that kills all your sessions
# without warning. Instructions are printed instead.

set -euo pipefail

# ── Helpers ──────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/_helpers.sh"

# ── Constants ────────────────────────────────────────────────────────
readonly DROP_IN_DIR="/etc/systemd/system/user@.service.d"
readonly DROP_IN_FILE="$DROP_IN_DIR/delegate.conf"
readonly WANTED_DELEGATE="cpu cpuset io memory pids"
readonly SUBTREE_PATH="/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.subtree_control"

# The canonical content we write/expect. Whitespace is significant
# when we compare file contents; keep this and the heredoc in sync.
readonly DROP_IN_CONTENT="[Service]
Delegate=cpu cpuset io memory pids
"

# ── Sanity ───────────────────────────────────────────────────────────
ensure_systemd() {
    if ! command -v systemctl >/dev/null 2>&1; then
        log_err "systemctl not found — this script only supports systemd-based hosts."
        exit 2
    fi
    if [[ ! -d /run/systemd/system ]]; then
        log_err "/run/systemd/system not present — systemd not running as PID 1."
        exit 2
    fi
    if ! systemctl --user --no-pager is-system-running >/dev/null 2>&1 \
       && ! systemctl --user --no-pager show-environment >/dev/null 2>&1; then
        log_warn "user systemd manager doesn't appear to be running."
        log_warn "this may be expected for sudo'd or non-interactive sessions; continuing."
    fi
}

# Re-invokes the named command via sudo, preserving the argv we
# received. Used by `enable` and `disable` when not running as root.
need_root_or_reexec() {
    if (( EUID == 0 )); then
        return 0
    fi
    if ! command -v sudo >/dev/null 2>&1; then
        log_err "this action needs root, and sudo is not available."
        log_err "re-run as root: $0 $*"
        exit 3
    fi
    log_info "this action needs root; re-running with sudo..."
    exec sudo --preserve-env=HOME,LOGNAME,USER -- "$0" "$@"
}

# Read the current subtree_control file. Echoes empty if unreadable.
read_subtree() {
    if [[ -r "$SUBTREE_PATH" ]]; then
        cat "$SUBTREE_PATH"
    else
        echo ""
    fi
}

# Returns 0 if all controllers in $WANTED_DELEGATE are present in
# subtree_control; 1 otherwise.
has_all_controllers() {
    local subtree
    subtree="$(read_subtree)"
    for c in $WANTED_DELEGATE; do
        if [[ "$subtree" != *"$c"* ]]; then
            return 1
        fi
    done
    return 0
}

# Returns 0 if the drop-in file exists with our exact canonical content.
# Returns 1 if the file is missing.
# Returns 2 if the file exists but has different content (manual customization).
drop_in_state() {
    if [[ ! -f "$DROP_IN_FILE" ]]; then
        return 1
    fi
    local current
    current="$(cat "$DROP_IN_FILE")"
    # Normalize: both sides have trailing newline handling
    if [[ "$current" == "${DROP_IN_CONTENT%$'\n'}" ]] || [[ "$current"$'\n' == "$DROP_IN_CONTENT" ]]; then
        return 0
    fi
    # Looser match: any [Service] section with a Delegate= line listing our controllers
    if grep -qE '^\[Service\]' "$DROP_IN_FILE" \
        && grep -qE '^Delegate=.*cpu.*cpuset.*io.*memory.*pids' "$DROP_IN_FILE"; then
        # Custom but functionally equivalent
        return 3
    fi
    return 2
}

# ── Subcommands ──────────────────────────────────────────────────────

cmd_check() {
    section "cgroup v2 controller delegation — current state"

    log_info "user id:          $(id -u) ($(id -un))"
    log_info "subtree path:     $SUBTREE_PATH"
    log_info "drop-in location: $DROP_IN_FILE"
    echo

    # Live state from /sys
    log_step "live state (from /sys)"
    local subtree
    subtree="$(read_subtree)"
    if [[ -z "$subtree" ]]; then
        log_warn "could not read $SUBTREE_PATH"
        log_warn "is this a systemd user session? are you logged in normally?"
    else
        printf '  current subtree_control: %s\n' "$subtree"
        echo
        printf '  per-controller status:\n'
        local missing=0
        for c in $WANTED_DELEGATE; do
            if [[ "$subtree" == *"$c"* ]]; then
                printf '    %s✓%s %s\n' "${C_GREEN}" "${C_RESET}" "$c"
            else
                printf '    %s✗%s %s  (missing)\n' "${C_RED}" "${C_RESET}" "$c"
                missing=1
            fi
        done
        echo
        if (( missing == 0 )); then
            log_ok "all wanted controllers are live in your user slice."
        else
            log_warn "some controllers are not live; you'll need 'enable' + re-login."
        fi
    fi
    echo

    # Drop-in file state
    log_step "drop-in file state"
    set +e
    drop_in_state
    local di_state=$?
    set -e
    case $di_state in
        0)
            log_ok "drop-in present with canonical content."
            printf '  %s%s%s\n' "$C_DIM" "$DROP_IN_FILE" "$C_RESET"
            ;;
        1)
            log_warn "no drop-in installed at $DROP_IN_FILE"
            log_warn "run '$0 enable' to install it."
            ;;
        2)
            log_warn "drop-in exists but has unexpected content:"
            sed 's/^/    /' "$DROP_IN_FILE"
            log_warn "this may be intentional manual customization."
            log_warn "this script will not overwrite without --force."
            ;;
        3)
            log_ok "drop-in present with functionally equivalent content (custom format)."
            printf '  %s%s%s\n' "$C_DIM" "$DROP_IN_FILE" "$C_RESET"
            ;;
    esac
    echo

    # Consistency between drop-in and live state
    log_step "consistency"
    if (( di_state == 0 || di_state == 3 )); then
        if has_all_controllers; then
            log_ok "drop-in is installed AND live — fully active."
        else
            log_warn "drop-in is installed but not yet applied to your user slice."
            log_warn "you need to re-login (or reboot) to activate it."
            log_warn "until then, weighted/pinned scenarios will skip."
        fi
    else
        if has_all_controllers; then
            log_info "controllers are live without our drop-in — likely set by another mechanism."
        else
            log_info "neither drop-in nor live delegation present."
        fi
    fi

    echo
    # Exit code reflects whether action is needed:
    #   0 = fully configured
    #   1 = action needed (run enable + re-login)
    if has_all_controllers && (( di_state == 0 || di_state == 3 )); then
        return 0
    else
        return 1
    fi
}

cmd_enable() {
    section "cgroup v2 controller delegation — enable"

    set +e
    drop_in_state
    local di_state=$?
    set -e

    case $di_state in
        0|3)
            log_ok "drop-in already installed with $([ $di_state -eq 0 ] && echo canonical || echo "functionally equivalent") content."
            log_info "no file changes needed."
            if ! has_all_controllers; then
                echo
                log_warn "however, controllers are NOT yet live in your user slice."
                log_warn "you need to re-login for the existing drop-in to take effect."
                printf '  options:\n'
                printf '    1. log out of GUI and back in\n'
                printf '    2. reboot\n'
                printf '    3. (aggressive) sudo loginctl terminate-user %s\n' "$USER"
            else
                log_ok "controllers are also live — fully configured."
            fi
            return 0
            ;;
        2)
            log_warn "$DROP_IN_FILE already exists with non-canonical content:"
            sed 's/^/    /' "$DROP_IN_FILE"
            echo
            log_err "refusing to overwrite a hand-customized drop-in."
            log_err "remove it manually if you want to proceed, or accept its current state."
            return 4
            ;;
        1)
            # Not installed — fall through to install path
            ;;
    esac

    need_root_or_reexec enable

    log_info "creating $DROP_IN_DIR (if needed)..."
    mkdir -p "$DROP_IN_DIR"

    log_info "writing $DROP_IN_FILE..."
    printf '%s' "$DROP_IN_CONTENT" > "$DROP_IN_FILE"

    log_info "reloading systemd..."
    systemctl daemon-reload

    echo
    log_ok "drop-in installed. Contents:"
    sed 's/^/    /' "$DROP_IN_FILE"
    echo

    log_step "to activate"
    cat <<EOF
The new delegation is now configured, but won't take effect until the
user manager (user@$(id -u).service) restarts. systemd does NOT
automatically restart it when the config changes; you need to log out
and back in. Three options:

    1. Log out of your GUI session and log back in (safest).
    2. Reboot (also safe; same outcome).
    3. Run: sudo loginctl terminate-user $USER
       (aggressive — kills ALL your sessions including SSH/terminals)

After re-login, verify with:
    $0 check

Persistence: this configuration survives reboots; you only need to
run 'enable' once per host.
EOF
}

cmd_disable() {
    section "cgroup v2 controller delegation — disable"

    set +e
    drop_in_state
    local di_state=$?
    set -e

    case $di_state in
        1)
            log_ok "no drop-in installed at $DROP_IN_FILE."
            log_info "nothing to remove."
            return 0
            ;;
        2)
            log_warn "$DROP_IN_FILE exists with non-canonical content:"
            sed 's/^/    /' "$DROP_IN_FILE"
            echo
            log_err "refusing to remove a hand-customized drop-in."
            log_err "remove it manually with: sudo rm $DROP_IN_FILE"
            return 4
            ;;
        0|3)
            # Our file, OK to remove
            ;;
    esac

    log_warn "this will remove controller delegation for rootless podman."
    log_warn "after re-login, demo-05's weighted/pinned scenarios will skip with N/A."
    log_warn "other tooling depending on rootless cgroup features may also stop working."

    need_root_or_reexec disable

    log_info "removing $DROP_IN_FILE..."
    rm -f "$DROP_IN_FILE"

    # Remove the dir only if empty (don't clobber other drop-ins).
    if [[ -d "$DROP_IN_DIR" ]] && [[ -z "$(ls -A "$DROP_IN_DIR")" ]]; then
        log_info "removing empty directory $DROP_IN_DIR..."
        rmdir "$DROP_IN_DIR"
    fi

    log_info "reloading systemd..."
    systemctl daemon-reload

    echo
    log_ok "drop-in removed."
    echo

    log_step "to fully revert"
    cat <<EOF
The drop-in is gone, but the controllers may still be live in your
current session (the kernel doesn't retract them mid-flight). To
return to the default delegation:

    1. Log out and back in, OR
    2. Reboot

Either way, your next session will use the systemd default
delegation (typically just 'memory pids').
EOF
}

cmd_verify() {
    # Terse pass/fail for tests/CI.
    if has_all_controllers; then
        local di
        set +e
        drop_in_state
        di=$?
        set -e
        if (( di == 0 || di == 3 )); then
            log_ok "cgroup v2 delegation: configured and live."
            return 0
        else
            log_ok "cgroup v2 delegation: live (no drop-in; set externally)."
            return 0
        fi
    else
        log_err "cgroup v2 delegation: missing controllers."
        return 1
    fi
}

cmd_help() {
    cat <<EOF
$(basename "$0") — manage cgroup v2 controller delegation for rootless podman

Usage:
    $(basename "$0") [SUBCOMMAND]

Subcommands:
    check       Show current delegation state in detail (default).
                Read-only; runs as the invoking user.

    enable      Install the systemd drop-in that delegates
                cpu, cpuset, io, memory, pids to user slices.
                Requires root (auto-elevates via sudo).
                Idempotent; safe to re-run.

    disable     Remove the drop-in installed by 'enable'.
                Requires root (auto-elevates via sudo).
                Will not remove a hand-customized drop-in.

    verify      Terse pass/fail check (for use in tests/CI).
                Read-only.

    help        Print this message.

Files:
    drop-in:    $DROP_IN_FILE
    live state: $SUBTREE_PATH

For more detail see:
    - examples/demo-05-isolation/README.md (§"Cgroup v2 controller delegation")
    - _docs/01-prerequisites.md (§1.7 rootless cgroup delegation)
EOF
}

# ── Dispatch ─────────────────────────────────────────────────────────
main() {
    local cmd="${1:-check}"
    case "$cmd" in
        check)   ensure_systemd; cmd_check ;;
        enable)  ensure_systemd; cmd_enable ;;
        disable) ensure_systemd; cmd_disable ;;
        verify)  ensure_systemd; cmd_verify ;;
        help|-h|--help) cmd_help ;;
        *)
            log_err "unknown subcommand: $cmd"
            echo
            cmd_help
            exit 2
            ;;
    esac
}

main "$@"
