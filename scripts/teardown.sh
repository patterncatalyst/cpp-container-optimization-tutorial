#!/usr/bin/env bash
# Fully revert everything this tutorial may have placed on your host.
#
# Use this when you're done with the tutorial and want to return your
# laptop to its pre-tutorial state, or if anything got into a weird
# state mid-tutorial and you want a clean slate to start from.
#
# What this removes:
#   - All running demo containers (demo-02, demo-03, demo-04, observability)
#   - All built demo images (cpp-tut/*)
#   - Auxiliary images we pulled (otel-lgtm, ghz)
#   - The tutorial-obs podman network
#   - The demo03_iouring SELinux module (if installed)
#   - Generated security artifacts (seccomp-iouring.json,
#     demo03_iouring.pp, .mod, tmp/)
#   - Podman build cache (optional, with --prune-cache)
#
# What this does NOT touch:
#   - The repo files themselves (delete the dir manually if you want)
#   - System packages (selinux-policy-devel, conan, etc.; remove with dnf if you want)
#   - Your shell history, dot files, anything outside containers
#   - Other podman containers/images/networks not from this tutorial
#   - Host SELinux state, kernel sysctls, firewall rules — never touched
#
# Usage:
#   ./scripts/teardown.sh              # interactive (prompts before each step)
#   ./scripts/teardown.sh --yes        # non-interactive (assumes yes to everything)
#   ./scripts/teardown.sh --dry-run    # print what would be done, do nothing
#   ./scripts/teardown.sh --prune-cache  # also clear podman build cache (frees several GB)
#
# Idempotent: safe to run multiple times. Anything already absent is skipped.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ASSUME_YES=0
DRY_RUN=0
PRUNE_CACHE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes|-y)       ASSUME_YES=1; shift ;;
        --dry-run|-n)   DRY_RUN=1; shift ;;
        --prune-cache)  PRUNE_CACHE=1; shift ;;
        -h|--help)      sed -n '2,32p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

# ── Helpers ───────────────────────────────────────────────────────────

confirm() {
    local prompt="$1"
    if (( ASSUME_YES )); then return 0; fi
    read -r -p "$prompt [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

run() {
    if (( DRY_RUN )); then
        echo "  [dry-run] $*"
        return 0
    else
        echo "  → $*"
        # We don't want one failing command (e.g. an image already
        # absent) to halt the teardown. The whole point is to be
        # forgiving and idempotent.
        eval "$@" 2>&1 | sed 's/^/    /' || true
    fi
}

section() { echo; echo "── $1 ──"; }

# ── 1. Stop and remove demo containers ────────────────────────────────

section "1. Demo containers"

# Find all compose files that might be running.
COMPOSE_FILES=(
    "examples/demo-02-stl-layout/compose.yml"
    "examples/demo-03-io-uring-grpc/compose.yml"
    "examples/demo-03-io-uring-grpc/compose.production.yml"
    "examples/demo-04-observability/compose.yml"
    "observability/compose.yml"
)

if confirm "Stop + remove containers and volumes from all demos?"; then
    cd "$REPO_ROOT"
    for cf in "${COMPOSE_FILES[@]}"; do
        if [[ -f "$cf" ]]; then
            echo "  Bringing down: $cf"
            run podman compose -f "$cf" down -v
        fi
    done

    # Belt and suspenders: stop anything matching demo container names
    # in case a previous run was started with a different compose
    # variant.
    for name in demo02-svc demo03-svc demo04-svc tutorial-lgtm; do
        if podman ps -a --format '{{.Names}}' | grep -qx "$name"; then
            run podman stop "$name"
            run podman rm -f "$name"
        fi
    done
fi

# ── 2. Remove demo images ─────────────────────────────────────────────

section "2. Demo images"

if confirm "Remove built demo images (cpp-tut/*) and auxiliary pulled images?"; then
    # Our built images
    for img in cpp-tut/demo-02:latest cpp-tut/demo-03:latest cpp-tut/demo-04:latest; do
        if podman image exists "$img" 2>/dev/null; then
            run podman image rm "$img"
        fi
    done

    # Auxiliary images we pulled from external registries
    for img in \
        docker.io/grafana/otel-lgtm:0.8.1 \
        ghcr.io/bojand/ghz:0.120.0 \
    ; do
        if podman image exists "$img" 2>/dev/null; then
            run podman image rm "$img"
        fi
    done

    # The intermediate UBI base images stay; you may want them for
    # other work. Pass --prune-cache to remove them too.
fi

# ── 3. Remove podman network ──────────────────────────────────────────

section "3. Tutorial network"

if confirm "Remove the tutorial-obs podman network?"; then
    if podman network exists tutorial-obs 2>/dev/null; then
        run podman network rm tutorial-obs
    else
        echo "  tutorial-obs network not present"
    fi
fi

# ── 4. Remove SELinux module ──────────────────────────────────────────

section "4. SELinux module"

if command -v semodule >/dev/null 2>&1 && \
   sudo -n semodule -l 2>/dev/null | grep -q '^demo03_iouring' || \
   sudo semodule -l 2>/dev/null | grep -q '^demo03_iouring'; then
    if confirm "Remove the demo03_iouring SELinux module (requires sudo)?"; then
        if [[ -x "$REPO_ROOT/examples/demo-03-io-uring-grpc/security/uninstall-selinux-policy.sh" ]]; then
            if (( DRY_RUN )); then
                echo "  [dry-run] sudo $REPO_ROOT/examples/demo-03-io-uring-grpc/security/uninstall-selinux-policy.sh"
            else
                sudo "$REPO_ROOT/examples/demo-03-io-uring-grpc/security/uninstall-selinux-policy.sh"
            fi
        else
            run sudo semodule -r demo03_iouring
        fi
    fi
else
    echo "  demo03_iouring SELinux module not installed (or SELinux not active); skipping"
fi

# ── 5. Remove generated security artifacts ────────────────────────────

section "5. Generated security artifacts"

SEC_DIR="$REPO_ROOT/examples/demo-03-io-uring-grpc/security"
ARTIFACTS=(
    "$SEC_DIR/seccomp-iouring.json"  # generated by build-seccomp-profile.sh
    "$SEC_DIR/demo03_iouring.pp"     # compiled SELinux package
    "$SEC_DIR/demo03_iouring.mod"    # SELinux intermediate
    "$SEC_DIR/demo03_iouring.mod.fc"
    "$SEC_DIR/tmp"                    # selinux build tempdir
)
# Note: we do NOT delete seccomp-iouring.json if it's the committed
# reference snapshot (would show up as a modified file in git).
# Check via `git ls-files` to be safe.
echo "  Note: leaving committed reference seccomp-iouring.json in place;"
echo "        only removes if you regenerated it locally."
if confirm "Remove generated security artifacts?"; then
    for f in "${ARTIFACTS[@]}"; do
        if [[ -e "$f" ]]; then
            # Don't delete tracked files (the reference seccomp-iouring.json)
            if (cd "$REPO_ROOT" && git ls-files --error-unmatch "$f" >/dev/null 2>&1); then
                echo "  preserving tracked file: $f"
            else
                run rm -rf "$f"
            fi
        fi
    done
fi

# ── 6. Optional: prune podman build cache ─────────────────────────────

if (( PRUNE_CACHE )); then
    section "6. Podman build cache (--prune-cache requested)"
    if confirm "Prune ALL unused podman images, containers, and build cache? (frees several GB)"; then
        run podman system prune -af
    fi
fi

# ── 7. Summary ────────────────────────────────────────────────────────

section "Summary"

echo "  podman containers:"
podman ps -a --format '    {{.Names}}\t{{.Status}}' 2>/dev/null | head -20 || true

echo "  podman images (cpp-tut, otel-lgtm, ghz):"
podman images --format '    {{.Repository}}:{{.Tag}}' 2>/dev/null \
    | grep -E '(cpp-tut|otel-lgtm|ghz)' || echo "    (none)"

echo "  podman networks:"
podman network ls --format '    {{.Name}}' 2>/dev/null | grep tutorial-obs \
    || echo "    (no tutorial-obs)"

echo "  SELinux modules (demo03):"
sudo -n semodule -l 2>/dev/null | grep demo03 \
    || sudo semodule -l 2>/dev/null | grep demo03 \
    || echo "    (none)"

echo
if (( DRY_RUN )); then
    echo "Dry run complete. Re-run without --dry-run to actually remove."
else
    echo "Teardown complete. Your laptop is back to pre-tutorial state."
    echo
    echo "If you also want to remove the repo and the host packages:"
    echo "  rm -rf $REPO_ROOT"
    echo "  sudo dnf remove selinux-policy-devel  # if you installed it"
    echo "  pipx uninstall conan                  # if you installed conan via pipx"
fi
