#!/usr/bin/env bash
# statelessness/07-state-externalization — idempotency demo driver.
#
# Three acts:
#   1. create an order with idempotency key K1 — a fresh insert.
#   2. retry with the SAME key K1 — the database dedups; the response
#      replays the original order_id with idempotent_replay=true.
#   3. create with a NEW key K2 — a distinct order; then read it back
#      with GetOrder.
#
# Authoritative state lives in PostgreSQL; the service holds only the
# connection pool. order-svc waits for Postgres to be healthy and also
# retries the connection at startup.
#
# Usage:
#   ./demo.sh           build + bring up + the three acts
#   ./demo.sh --keep    leave the stack running
#   ./demo.sh --clean   tear down

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

KEEP_UP=0; CLEAN_ONLY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep)  KEEP_UP=1; shift ;;
        --clean) CLEAN_ONLY=1; shift ;;
        -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

COMPOSE=(podman compose -f compose.yml)
SVC=order-svc

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

# Run order-client inside the order-svc container.
client() { "${COMPOSE[@]}" exec -T "$SVC" /usr/local/bin/order-client 127.0.0.1:50051 "$@" 2>/dev/null | filter_compose; }

echo "==> Building and starting postgres + order-svc"
echo "    (first build compiles the gRPC chain; warm cache is faster)"
"${COMPOSE[@]}" up -d --build

echo "==> Waiting for order-svc healthz on http://127.0.0.1:18405"
for i in $(seq 1 180); do
    if curl -fsS "http://127.0.0.1:18405" >/dev/null 2>&1; then echo "    ready"; break; fi
    sleep 1
    if (( i == 180 )); then
        echo "    order-svc never became ready; logs:" >&2
        "${COMPOSE[@]}" logs --tail=50 "$SVC" >&2 || true; exit 1
    fi
done

echo
echo "==> Act 1: create an order with idempotency key K1 (fresh insert)"
a1="$(client create alice widget K1)"; printf '    %s\n' "$a1"

echo
echo "==> Act 2: retry with the SAME key K1 — the database dedups"
a2="$(client create alice widget K1)"; printf '    %s\n' "$a2"
echo "    (same order_id, idempotent_replay=true — the retry did NOT create"
echo "     a second order. The UNIQUE constraint on idempotency_key is the"
echo "     authoritative dedup point, enforced race-free by ON CONFLICT.)"

echo
echo "==> Act 3: a NEW key K2 makes a distinct order; then read it back"
a3="$(client create bob gadget K2)"; printf '    %s\n' "$a3"
oid="$(printf '%s\n' "$a3" | grep -oE 'order_id=[0-9]+' | head -1 | cut -d= -f2)"
if [[ -n "$oid" ]]; then
    g="$(client get "$oid")"; printf '    %s\n' "$g"
fi

echo
echo "Done. State persists in PostgreSQL independent of the service process."
echo "Re-run with --keep to leave the stack up, or --clean to tear down."
