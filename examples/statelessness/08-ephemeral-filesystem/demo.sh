#!/usr/bin/env bash
# statelessness/08-ephemeral-filesystem — read-only rootfs demo.
#
# Builds a tiny image (one binary, spdlog) and runs it under different
# `podman run` flags to show four things:
#
#   1. The trap. `app log-file /var/log/app.log` under `--read-only`:
#      spdlog's basic_logger_mt opens the file in its constructor and the
#      write fails with EROFS. The container exits non-zero.
#
#   2. The fix. `app log-stdout` under `--read-only`: logs stream to
#      stdout (the orchestrator captures them). Writes nothing to disk,
#      so the read-only rootfs is no obstacle.
#
#   3. Ephemerality. `app log-file` on a WRITABLE rootfs "works" — then a
#      fresh container's `check-file` shows the write did not survive.
#
#   4. Scratch needs a tmpfs. `app scratch /tmp` under `--read-only`
#      fails; the same under `--read-only --tmpfs /tmp` succeeds.
#
# Uses `podman run` directly (like demo-05) rather than compose, because
# the lesson is about per-container runtime flags.
#
# Usage:
#   ./demo.sh           build + the four acts
#   ./demo.sh --clean   remove the built image

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

IMG=cpp-tut/stateless-08-ephemeral-filesystem:latest

if [[ "${1:-}" == "--clean" ]]; then
    echo "==> Removing image $IMG"
    podman rmi -f "$IMG" 2>/dev/null || true
    exit 0
fi
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    sed -n '2,24p' "$0"; exit 0
fi

echo "==> Building $IMG"
podman build -t "$IMG" -f Containerfile . >/dev/null
echo "    built"

run() { podman run --rm "$@"; }

echo
echo "==> Act 1: the trap — a file logger under a read-only rootfs"
echo "    \$ podman run --read-only IMG app log-file /var/log/app.log"
if run --read-only "$IMG" app log-file /var/log/app.log; then
    echo "    (unexpected: the write succeeded)"
else
    echo "    => exited non-zero: spdlog could not open the file (EROFS). Expected."
fi

echo
echo "==> Act 2: the fix — log to stdout under the same read-only rootfs"
echo "    \$ podman run --read-only IMG app log-stdout"
run --read-only "$IMG" app log-stdout | sed 's/^/    /'
echo "    => stdout is captured by the runtime; nothing is written to disk."

echo
echo "==> Act 3: ephemerality — a writable-rootfs write does not survive a restart"
echo "    \$ podman run IMG app log-file /var/log/app.log     (writable rootfs)"
run "$IMG" app log-file /var/log/app.log 2>&1 | sed 's/^/    /' || true
echo "    \$ podman run IMG app check-file /var/log/app.log   (fresh container)"
if run "$IMG" app check-file /var/log/app.log | sed 's/^/    /'; then
    echo "    (unexpected: the file persisted)"
else
    echo "    => gone: each container starts with a fresh ephemeral layer."
fi

echo
echo "==> Act 4: scratch needs an explicitly-mounted tmpfs"
echo "    \$ podman run --read-only --read-only-tmpfs=false IMG app scratch /tmp"
if run --read-only --read-only-tmpfs=false "$IMG" app scratch /tmp; then
    echo "    (note: /tmp was writable — your podman auto-mounted a tmpfs)"
else
    echo "    => failed: /tmp is on the read-only rootfs with no tmpfs mounted."
fi
echo "    \$ podman run --read-only --tmpfs /tmp:rw,size=16m IMG app scratch /tmp"
run --read-only --tmpfs /tmp:rw,size=16m "$IMG" app scratch /tmp | sed 's/^/    /'
echo "    => succeeded: scratch belongs on a tmpfs, sized and recycled by the runtime."

echo
echo "Persistence that must survive a restart goes to a backing store"
echo "(Doc 07 — PostgreSQL/Redis) or a named volume, never the container layer."
echo
echo "Done. Re-run with --clean to remove the image."
