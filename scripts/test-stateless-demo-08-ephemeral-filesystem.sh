#!/usr/bin/env bash
# statelessness/08-ephemeral-filesystem end-to-end verification.
#
# Pass criteria:
#   1. image builds
#   2. THE TRAP: `app log-file /var/log/app.log` under --read-only exits
#      non-zero (spdlog cannot open the file: EROFS)
#   3. THE FIX: `app log-stdout` under --read-only exits 0 and emits logs
#   4. EPHEMERALITY: `app check-file` in a fresh container reports absent
#   5. SCRATCH: `app scratch /tmp` under --read-only --tmpfs /tmp exits 0
#   (a soft check confirms scratch fails when no tmpfs is mounted; this
#    depends on podman's --read-only-tmpfs default, so it never fails CI)

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/_helpers.sh"

require podman

DEMO="$REPO_ROOT/examples/statelessness/08-ephemeral-filesystem"
IMG=cpp-tut/stateless-08-ephemeral-filesystem:latest
cd "$DEMO"

cleanup() { log_step "removing image"; podman rmi -f "$IMG" 2>/dev/null || true; }
trap cleanup EXIT

run() { podman run --rm "$@"; }

log_step "Phase 1 — build the image"
podman build -t "$IMG" -f Containerfile . >/dev/null
log_ok "image built"

log_step "Phase 2 — the trap: file logger under --read-only must fail (EROFS)"
if run --read-only "$IMG" app log-file /var/log/app.log >/dev/null 2>&1; then
    log_err "expected a non-zero exit (EROFS); the write unexpectedly succeeded"
    exit 1
fi
log_ok "file logger failed under read-only rootfs, as it should"

log_step "Phase 3 — the fix: stdout logging under --read-only must succeed"
out="$(run --read-only "$IMG" app log-stdout 2>&1)" || {
    log_err "stdout logging exited non-zero under read-only rootfs"
    printf '%s\n' "$out"; exit 1
}
if printf '%s\n' "$out" | grep -q "service ready"; then
    log_ok "stdout logging ran and emitted logs under read-only rootfs"
else
    log_err "expected log output containing 'service ready'; got:"
    printf '%s\n' "$out"; exit 1
fi

log_step "Phase 4 — ephemerality: a fresh container has no prior write"
if run "$IMG" app check-file /var/log/app.log >/dev/null 2>&1; then
    log_err "expected check-file to report absent in a fresh container"
    exit 1
fi
log_ok "fresh container starts with a clean ephemeral layer"

log_step "Phase 5 — scratch on an explicitly-mounted tmpfs must succeed"
out="$(run --read-only --tmpfs /tmp:rw,size=16m "$IMG" app scratch /tmp 2>&1)" || {
    log_err "scratch failed even with a tmpfs mounted at /tmp"
    printf '%s\n' "$out"; exit 1
}
if printf '%s\n' "$out" | grep -q "wrote and read back"; then
    log_ok "scratch wrote and read back from the tmpfs"
else
    log_err "expected 'wrote and read back'; got:"
    printf '%s\n' "$out"; exit 1
fi

log_step "Phase 5 (soft) — scratch without a tmpfs should fail"
if run --read-only --read-only-tmpfs=false "$IMG" app scratch /tmp >/dev/null 2>&1; then
    log_warn "scratch /tmp succeeded without an explicit tmpfs — your podman"
    log_warn "auto-mounted one (--read-only-tmpfs). Not a failure; just noting."
else
    log_ok "scratch correctly failed with no tmpfs mounted"
fi

log_step "RESULT"
log_ok "statelessness/08-ephemeral-filesystem verified — read-only trap, stdout fix, ephemerality, tmpfs scratch"
