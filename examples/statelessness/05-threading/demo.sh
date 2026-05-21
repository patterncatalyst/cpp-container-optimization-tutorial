#!/usr/bin/env bash
# statelessness/05-threading — CPU-budget detection + pool-sizing demo.
#
# Builds a tiny image (two standalone binaries, no gRPC) and runs it
# under a `--cpus=2` CFS quota to show two things:
#
#   1. cpu-probe — std::thread::hardware_concurrency() reports the HOST's
#      core count, but the cgroup quota inside `--cpus=2` is 2 cores.
#      Sizing a pool from the host probe oversubscribes the CPU.
#
#   2. pool-bench — the same fixed CPU-bound workload run with pool sizes
#      1, 2 (= the quota), 4, and 8, all under `--cpus=2`. Throughput
#      plateaus at the quota; tail latency (p99/max) gets dramatically
#      worse as the pool oversubscribes, because hitting the quota
#      mid-period throttles every thread until the next period boundary.
#
# Uses `podman run --cpus` directly (like demo-05) rather than compose,
# because rootless CFS-quota enforcement needs the cgroup v2 `cpu`
# controller delegated to your user slice — which the script detects.
#
# Usage:
#   ./demo.sh           build + probe + pool-size sweep
#   ./demo.sh --clean   remove the built image

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
REPO_ROOT="$(cd "$DIR/../../.." && pwd)"

IMG=cpp-tut/stateless-05-threading:latest
CPUS=2
TASKS=2000
ITERS=400000

if [[ "${1:-}" == "--clean" ]]; then
    echo "==> Removing image $IMG"
    podman rmi -f "$IMG" 2>/dev/null || true
    exit 0
fi
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    sed -n '2,28p' "$0"; exit 0
fi

# ── cgroup v2 'cpu' controller delegation detection (G-40) ───────────
# Rootless podman's --cpus needs the cpu controller delegated to the
# user slice. Without it, --cpus is accepted but the CFS quota is not
# enforced, so the throttling effect won't show. Detect and warn.
HAS_CPU_DELEGATED=0
DELEGATE_PATH="/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.subtree_control"
if [[ -r "$DELEGATE_PATH" ]]; then
    [[ "$(<"$DELEGATE_PATH")" == *cpu* ]] && HAS_CPU_DELEGATED=1
fi
if (( ! HAS_CPU_DELEGATED )); then
    echo "WARNING: cgroup v2 'cpu' controller is not delegated to your user slice."
    echo "  --cpus=$CPUS will be accepted but the CFS quota may not be enforced,"
    echo "  so the throttling effect below may be muted (results will reflect the"
    echo "  host's cores). To enable real enforcement:"
    echo "    $REPO_ROOT/scripts/cgroup-delegation.sh enable   # then re-login"
    echo
fi

echo "==> Building $IMG (no gRPC/Conan — this is quick)"
podman build -t "$IMG" -f Containerfile . >/dev/null
echo "    built"

echo
echo "==> Act 1: cpu-probe inside --cpus=$CPUS"
echo "    hardware_concurrency() reports the host; the cgroup quota is the"
echo "    truth the pool should be sized from."
echo "    ------------------------------------------------------------"
podman run --rm --cpus="$CPUS" "$IMG" /usr/local/bin/cpu-probe | sed 's/^/    /'
echo "    ------------------------------------------------------------"

echo
echo "==> Act 2: pool-bench under --cpus=$CPUS — same workload, varied pool size"
echo "    ($TASKS tasks; pool=2 matches the quota)"
echo "    ------------------------------------------------------------"
for p in 1 2 4 8; do
    label=""
    [[ "$p" == "$CPUS" ]] && label="   <- matches the --cpus=$CPUS quota"
    out="$(podman run --rm --cpus="$CPUS" "$IMG" /usr/local/bin/pool-bench "$p" "$TASKS" "$ITERS")"
    printf '    %s%s\n' "$out" "$label"
done
echo "    ------------------------------------------------------------"
echo "    Read across: throughput stops improving past pool=$CPUS (the quota"
echo "    is a fixed CPU-time slice regardless of thread count), while p99"
echo "    and max latency climb sharply as the pool oversubscribes and CFS"
echo "    throttling pauses spread across more threads. A pool sized to the"
echo "    cgroup quota gives the same throughput with far tighter tails."

echo
echo "Done. Re-run with --clean to remove the image."
