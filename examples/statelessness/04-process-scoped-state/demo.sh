#!/usr/bin/env bash
# statelessness/04-process-scoped-state — composition-root demo driver.
#
# Three acts:
#   1. composition root — the startup logs show process-scoped state
#      constructed in dependency order (config → metrics → cache →
#      service → server).
#   2. bounded cache — look up more distinct keys than the cache holds;
#      it evicts the least-recently-used entry instead of growing, and
#      the stats show the eviction count climbing while size stays at
#      the cap. (An unbounded map would grow until the cgroup OOM-kills
#      the process.)
#   3. reverse-order teardown — a graceful stop tears the state down in
#      the exact reverse of construction (server → service → cache →
#      metrics → config), which is also the correct shutdown order, for
#      free from RAII.
#
# Usage:
#   ./demo.sh           build + bring up + all three acts
#   ./demo.sh --keep    leave the service running
#   ./demo.sh --clean   tear down

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

KEEP_UP=0; CLEAN_ONLY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep)  KEEP_UP=1; shift ;;
        --clean) CLEAN_ONLY=1; shift ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

COMPOSE=(podman compose -f compose.yml)
SVC=state-svc

if (( CLEAN_ONLY )); then
    echo "==> Tearing down"; "${COMPOSE[@]}" down -v 2>/dev/null || true; exit 0
fi

cleanup() {
    if (( ! KEEP_UP )); then
        echo "==> Tearing down (use --keep to leave it running)"
        "${COMPOSE[@]}" down -v 2>/dev/null || true
    fi
}
trap cleanup EXIT

filter_compose() { grep -vE 'Executing external compose provider|^Error: executing'; }

echo "==> Building and starting state-svc (first build pulls the gRPC chain)"
"${COMPOSE[@]}" up -d --build

echo "==> Waiting for healthz on http://127.0.0.1:18404"
for i in $(seq 1 120); do
    if curl -fsS "http://127.0.0.1:18404" >/dev/null 2>&1; then echo "    ready"; break; fi
    sleep 1
    if (( i == 120 )); then
        echo "    service never became ready; logs:" >&2
        "${COMPOSE[@]}" logs --tail=40 "$SVC" >&2 || true; exit 1
    fi
done

echo
echo "==> Act 1: composition root — process-scoped state built in main(),"
echo "    in dependency order. No singletons; each object is held by name."
echo "    ------------------------------------------------------------"
"${COMPOSE[@]}" logs "$SVC" 2>/dev/null | filter_compose | grep -E '\[wire\] (compose|\+)' | sed 's/^/    /' || true
echo "    ------------------------------------------------------------"

echo
echo "==> Act 2: bounded cache — look up 8 distinct keys with capacity 4."
echo "    The cache evicts the LRU entry rather than growing past the cap."
for k in k1 k2 k3 k4 k5 k6 k7 k8; do
    "${COMPOSE[@]}" exec -T "$SVC" /usr/local/bin/state-client 127.0.0.1:50051 lookup "$k" 2>/dev/null | filter_compose | sed 's/^/    /'
done
echo "    Look it up again — k8 is still warm (recently inserted):"
"${COMPOSE[@]}" exec -T "$SVC" /usr/local/bin/state-client 127.0.0.1:50051 lookup k8 2>/dev/null | filter_compose | sed 's/^/    /'
echo "    Stats:"
"${COMPOSE[@]}" exec -T "$SVC" /usr/local/bin/state-client 127.0.0.1:50051 stats 2>/dev/null | filter_compose | sed 's/^/    /'
echo "    (cache_size stays at the cap; evictions climb. An unbounded map"
echo "     would instead grow with every distinct key until the cgroup"
echo "     memory limit triggers the OOM killer.)"

echo
echo "==> Act 3: reverse-order teardown — graceful stop. Watch the state"
echo "    unwind in the exact reverse of construction order:"
echo "    ------------------------------------------------------------"
"${COMPOSE[@]}" stop -t 10 "$SVC" >/dev/null 2>&1 || true
sleep 1
"${COMPOSE[@]}" logs --tail=20 "$SVC" 2>/dev/null | filter_compose | grep -E '\[wire\] (compose|-)' | sed 's/^/    /' || true
echo "    ------------------------------------------------------------"
echo "    server → service → cache → metrics → config: the reverse of"
echo "    construction, and the correct shutdown order, for free from RAII."

echo
echo "Done. Re-run with --keep to leave the service up, or --clean to tear down."
