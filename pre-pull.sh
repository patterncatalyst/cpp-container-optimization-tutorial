#!/usr/bin/env bash
# Pre-pull every image referenced by the project so the demos start
# instantly and your network surprises happen here, not in front of an
# audience.
#
#   ./pre-pull.sh           # pull everything
#   ./pre-pull.sh --prune   # pull, then `podman image prune` (recover space)
#
# If you're in an air-gapped environment, run this on a reachable host,
# then `podman save` each image, transfer, and `podman load` on the
# target. See _docs/01-prerequisites.md for the workflow.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/_helpers.sh
source "$REPO_ROOT/scripts/lib/_helpers.sh"

DO_PRUNE=0
[[ "${1:-}" == "--prune" ]] && DO_PRUNE=1

require podman

# ── Image inventory ─────────────────────────────────────────────────────
# Sourced by hand from every Containerfile and every compose.yml in the
# project, with versions pinned. Update this list whenever a Containerfile
# adds or changes a base image.

UBI_VERSION=9.4

IMAGES=(
    # UBI bases — used by every demo's build/runtime stages
    "registry.access.redhat.com/ubi9/ubi:${UBI_VERSION}"
    "registry.access.redhat.com/ubi9/ubi-minimal:${UBI_VERSION}"

    # Documented non-UBI exceptions (see CONTRIBUTING.md → Container image policy)
    "docker.io/alpine:3.20"                  # demo-01 musl-static build stage
    "docker.io/grafana/otel-lgtm:0.8.1"      # observability/ all-in-one stack

    # Image we route through Quay even when the upstream also publishes
    # to docker.io — saves a Docker Hub round-trip on every cold start
    "quay.io/prometheus/prometheus:v2.55.0"
)

# ── Pull loop ───────────────────────────────────────────────────────────
log_step "Pulling ${#IMAGES[@]} image(s)"

failed=0
for image in "${IMAGES[@]}"; do
    log_info "  → $image"
    if podman pull -q "$image" >/dev/null; then
        log_ok "    pulled"
    else
        log_err "    failed"
        failed=$((failed + 1))
    fi
done

if (( failed > 0 )); then
    log_err "$failed image(s) failed to pull. Check network and registry access."
    log_warn "If docker.io is blocked, see §1 Prerequisites for fallbacks."
    exit 1
fi

if (( DO_PRUNE == 1 )); then
    log_step "Pruning untagged image layers"
    podman image prune -f >/dev/null
    log_ok "Pruned."
fi

log_step "Done"
log_ok "All ${#IMAGES[@]} images cached locally. Demos will start without network."
