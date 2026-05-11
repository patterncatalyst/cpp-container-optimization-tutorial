#!/usr/bin/env bash
# Regenerate demo-04's Conan lockfile.
#
# Why this script exists: the OneUptime-derived override combo in
# examples/demo-04-observability/conanfile.py pins specific versions
# of gRPC, protobuf, and abseil that we know work together (see G-22,
# G-24, G-26, G-28 in the reconciliation plan). But Conan's *recipe
# revisions* for those versions can be updated post-publication —
# meaning the same `opentelemetry-cpp/1.14.2` version can transitively
# require different protobuf/abseil/grpc subsets over time (G-25).
#
# A `conan.lock` file pins not just (package, version) but
# (package, version, **recipe revision**) for every node in the
# dependency graph. Committing the lockfile means subsequent builds
# are bit-for-bit reproducible against the same dep graph we shook
# down through r28-r52 — independent of what Conan Center does to
# the recipes afterward.
#
# Caveat (still applies despite the lockfile): if Conan Center
# *yanks* a version entirely (G-26), the lockfile can't conjure
# missing remote packages. The durable fix is to mirror packages
# to your own remote; for a tutorial demo we accept the residual
# brittleness and document it.
#
# Run this:
#   - Once after the override versions in conanfile.py change.
#   - Once if you bump opentelemetry-cpp.
#   - Whenever you intentionally want to refresh the lockfile
#     against the latest still-hosted recipe revisions.
#
# Commit the resulting `conan.lock` to the repo. The Containerfile
# uses `--lockfile=conan.lock` automatically when the file exists.
#
# Usage:
#   ./scripts/regenerate-demo-04-lockfile.sh

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/_helpers.sh"

require podman

DEMO_DIR="$REPO_ROOT/examples/demo-04-observability"

if [[ ! -f "$DEMO_DIR/conanfile.py" ]]; then
    log_err "conanfile.py not found at $DEMO_DIR/conanfile.py"
    exit 1
fi

# Defensive cleanup: if conanfile.txt is sitting next to conanfile.py
# (likely a tar-overlay leftover from an earlier round — G-31), Conan
# refuses to proceed with "Ambiguous command, both conanfile.py and
# conanfile.txt exist." We treat this as a user-config problem and
# tell them how to fix it permanently, rather than silently deleting
# the file they may not know they have.
if [[ -f "$DEMO_DIR/conanfile.txt" ]]; then
    log_err "Both conanfile.py and conanfile.txt exist in $DEMO_DIR"
    log_err "  Conan would refuse to operate. The conanfile.txt is a"
    log_err "  leftover from an earlier tar overlay (see G-31 in the"
    log_err "  reconciliation plan). Remove it permanently:"
    log_err ""
    log_err "    git rm examples/demo-04-observability/conanfile.txt"
    log_err "    git commit -m 'chore(demo-04): drop stale conanfile.txt'"
    log_err ""
    log_err "  Then rerun this script."
    exit 1
fi

# The image we use here must match the Containerfile's first stage
# closely enough that the resolved graph is the same one production
# builds will see. Mirror UBI 9 + gcc-toolset-14 + Conan 2 + the
# same profile cppstd=gnu17 setting (G-27).
log_step "Spinning up build-context container to resolve the dep graph"

# This is a one-shot derivation; we don't need to keep the image
# around. Just inline the setup steps that mirror the Containerfile's
# pre-install state, then `conan lock create`.
podman run --rm \
    -v "$DEMO_DIR:/src:Z" \
    -w /src \
    registry.access.redhat.com/ubi9/ubi:9.5 \
    bash -euo pipefail -c '
        # Mirror the Containerfile dnf install set (G-13..G-17 in the
        # plan have the long-form rationale).
        dnf install -y --quiet \
            gcc-toolset-14 \
            cmake ninja-build git python3-pip \
            perl-FindBin perl-IPC-Cmd perl-Data-Dumper perl-Pod-Html \
            perl-Pod-Usage perl-File-Compare perl-File-Copy perl-File-Path \
            perl-Time-Piece perl-Getopt-Long perl-Digest-SHA \
            perl-threads perl-threads-shared perl-Thread-Queue \
            perl-Term-ANSIColor \
            >/dev/null

        # Activate gcc-toolset-14 so conan profile detect picks it up.
        source /opt/rh/gcc-toolset-14/enable

        # Conan 2.x. Same as Containerfile.
        pip install --quiet "conan~=2.0"

        # Profile detection + cppstd=gnu17 (G-27).
        conan profile detect --force >/dev/null
        sed -i "s|^compiler.cppstd=.*|compiler.cppstd=gnu17|" \
            /root/.conan2/profiles/default

        echo "==> Generating conan.lock against the current overrides..."
        # `conan lock create` resolves the full transitive graph
        # against the current recipe revisions on conan center and
        # writes the result to ./conan.lock by default.
        conan lock create . \
            --lockfile-out=/src/conan.lock \
            -s build_type=Release

        echo "==> conan.lock written. Summary of pinned versions:"
        # Just show the requires section so the user can eyeball it.
        python3 -c "
import json, sys
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
log_info "  git add examples/demo-04-observability/conan.lock"
log_info "  git commit -m 'chore(demo-04): refresh Conan lockfile'"
