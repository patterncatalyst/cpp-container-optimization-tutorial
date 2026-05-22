#!/usr/bin/env bash
# demo.sh — statelessness/11-build-tooling (vendored-helpers demo)
#
# The vendored helpers from Doc 11's appendix, made runnable and verifiable.
#
# Acts:
#   1. Unit tests    — the gtest suite over the helpers' pure parsers, run
#                      inside the container. Deterministic; no live cgroup.
#   2. Unconstrained — helper-demo with no caps: cpu falls back to the host
#                      core count, memory unbounded.
#   3. --cpus=1.5    — cpu_limit_cores() now reads 1.5 from cgroup v2 cpu.max.
#   4. --cpus=0.5
#      --memory=256m — cpu 0.5, memory ~256 MiB; a cgroup-aware pool would
#                      size to 1 thread, where hardware_concurrency() still
#                      reports the full host count (the Doc 05 trap).
#
# The point: the SAME binary reads whatever cap the orchestrator imposed.
# That is why a container-aware service sizes pools from the cgroup, not
# from hardware_concurrency().

set -euo pipefail

IMAGE="cpp-tut/stateless-11-build-tooling:latest"
COMPOSE="podman compose -f compose.yml"

if [[ "${1:-}" == "--clean" ]]; then
    $COMPOSE down --remove-orphans 2>/dev/null || true
    podman rmi "$IMAGE" 2>/dev/null || true
    exit 0
fi

echo "==> Building the image (compiles GoogleTest + runs the gtest gate)"
$COMPOSE build

run() { podman run --rm "$@" "$IMAGE"; }            # cap flags BEFORE image (default CMD = helper-demo)
run_cmd() { podman run --rm "$IMAGE" "$@"; }          # command AFTER image

# ── Act 1: unit tests ─────────────────────────────────────────────────
echo
echo "==> Act 1: unit tests (gtest over the pure parsers, in-container)"
echo "    These pin the parsing logic deterministically — cpu.max / memory.max"
echo "    / PSI strings — without needing a live cgroup filesystem."
echo
run_cmd /usr/local/bin/helper-tests 2>&1 | sed 's/^/    /'

# ── Act 2: unconstrained ──────────────────────────────────────────────
echo
echo "==> Act 2: unconstrained (no caps)"
echo "    cpu_limit_cores() finds no cpu.max quota and falls back to the host"
echo "    core count; memory is unbounded."
echo
run 2>&1 | sed 's/^/    /'

# ── Act 3: --cpus=1.5 ─────────────────────────────────────────────────
echo
echo "==> Act 3: podman run --cpus=1.5"
echo "    podman writes '150000 100000' to the container's cgroup cpu.max;"
echo "    cpu_limit_cores() reads it back as 1.5 cores."
echo
run --cpus=1.5 2>&1 | sed 's/^/    /'

# ── Act 4: --cpus=0.5 --memory=256m ───────────────────────────────────
echo
echo "==> Act 4: podman run --cpus=0.5 --memory=256m"
echo "    Both caps detected. Note hardware_concurrency() still reports the"
echo "    full host count — the Doc 05 trap a cgroup-aware pool avoids."
echo
run --cpus=0.5 --memory=256m 2>&1 | sed 's/^/    /'

echo
echo "Done. (--clean removes the image.)"
