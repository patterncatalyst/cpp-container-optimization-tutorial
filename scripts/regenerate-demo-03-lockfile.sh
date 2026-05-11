#!/usr/bin/env bash
# Regenerate demo-03's Conan lockfile.
#
# Same pattern as scripts/regenerate-demo-04-lockfile.sh — see that
# script's header comment for the long version of why this exists
# (recipe revision drift, G-25/G-26 in the plan).
#
# Demo-03 has a slight twist: it shares the OTel/gRPC override chain
# with demo-04. The recommended seeding workflow is:
#
#   1. Copy demo-04's lockfile to demo-03's:
#      cp examples/demo-04-observability/conan.lock \
#         examples/demo-03-io-uring-grpc/conan.lock
#   2. Build demo-03 — the Containerfile uses --lockfile-partial so
#      asio (the new dep) resolves fresh while the shared chain stays
#      locked.
#   3. Optional: run THIS script to materialize a full lockfile that
#      includes asio's pin. That gives demo-03 its own complete
#      lockfile independent of demo-04.
#
# Run this:
#   - After step 2 above succeeds, to upgrade from a partial inherit
#     to a full lock.
#   - When the override versions in conanfile.py intentionally change.
#   - When you want to refresh against the latest still-hosted
#     recipe revisions.
#
# Usage:
#   ./scripts/regenerate-demo-03-lockfile.sh

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/_helpers.sh"

require podman

DEMO_DIR="$REPO_ROOT/examples/demo-03-io-uring-grpc"

if [[ ! -f "$DEMO_DIR/conanfile.py" ]]; then
    log_err "conanfile.py not found at $DEMO_DIR/conanfile.py"
    exit 1
fi

# Same defensive guard as demo-04's regenerate script (G-31):
# refuse to proceed if a stale conanfile.txt is sitting next to
# conanfile.py — tar-overlay leftovers cause this.
if [[ -f "$DEMO_DIR/conanfile.txt" ]]; then
    log_err "Both conanfile.py and conanfile.txt exist in $DEMO_DIR"
    log_err "  Remove the stale conanfile.txt:"
    log_err "    git rm examples/demo-03-io-uring-grpc/conanfile.txt"
    log_err "    git commit -m 'chore(demo-03): drop stale conanfile.txt'"
    exit 1
fi

log_step "Spinning up build-context container to resolve the dep graph"

podman run --rm \
    -v "$DEMO_DIR:/src:Z" \
    -w /src \
    registry.access.redhat.com/ubi9/ubi:9.5 \
    bash -euo pipefail -c '
        dnf install -y --quiet \
            gcc-toolset-14 \
            cmake ninja-build git python3-pip \
            liburing-devel \
            perl-FindBin perl-IPC-Cmd perl-Data-Dumper perl-Pod-Html \
            perl-Pod-Usage perl-File-Compare perl-File-Copy perl-File-Path \
            perl-Time-Piece perl-Getopt-Long perl-Digest-SHA \
            perl-threads perl-threads-shared perl-Thread-Queue \
            perl-Term-ANSIColor \
            >/dev/null

        source /opt/rh/gcc-toolset-14/enable
        pip install --quiet "conan~=2.0"

        conan profile detect --force >/dev/null
        sed -i "s|^compiler.cppstd=.*|compiler.cppstd=gnu17|" \
            /root/.conan2/profiles/default

        echo "==> Generating conan.lock against the current overrides..."
        conan lock create . \
            --lockfile-out=/src/conan.lock \
            -s build_type=Release

        echo "==> conan.lock written. Pinned requires:"
        python3 -c "
import json
with open(\"/src/conan.lock\") as f:
    lock = json.load(f)
for req in lock.get(\"requires\", []):
    print(\"  \", req)
"
    '

if [[ ! -f "$DEMO_DIR/conan.lock" ]]; then
    log_err "conan.lock was not produced — check the container output above"
    exit 1
fi

log_ok "conan.lock regenerated at $DEMO_DIR/conan.lock"
log_info "Review the diff, then commit:"
log_info "  git add examples/demo-03-io-uring-grpc/conan.lock"
log_info "  git commit -m 'chore(demo-03): refresh Conan lockfile'"
