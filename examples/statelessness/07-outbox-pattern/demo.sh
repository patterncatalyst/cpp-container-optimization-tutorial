#!/usr/bin/env bash
# statelessness/07-outbox-pattern — transactional outbox + Kafka demo.
#
# Acts:
#   1. create an order (K1) — the producer writes the order AND an outbox
#      row in one transaction.
#   2. the relay publishes the outbox row to Kafka and marks it
#      published; the consumer applies it into the projection. We poll
#      the projection until the event lands. (Optional: if kcat is
#      installed, dump the topic so you see the event on the bus.)
#   3. idempotency — inject a DUPLICATE of the same event_id. The
#      consumer logs "duplicate ... ignored" and the projection still
#      holds exactly one row: at-least-once delivery + an idempotent
#      consumer = exactly-once effect.
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
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

COMPOSE=(podman compose -f compose.yml)
KEY="K1-$(date +%s)"   # unique per run so reruns start clean

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
psql_q() { "${COMPOSE[@]}" exec -T postgres psql -U orders -d orders -tAc "$1" 2>/dev/null | filter_compose; }
client()  { "${COMPOSE[@]}" exec -T order-svc /usr/local/bin/order-client 127.0.0.1:50051 "$@" 2>/dev/null | filter_compose; }

echo "==> Building and starting postgres + kafka + order-svc + relay + consumer"
echo "    (first build compiles the gRPC chain; Kafka takes ~20s to become healthy)"
"${COMPOSE[@]}" up -d --build

echo "==> Waiting for order-svc healthz on http://127.0.0.1:18406"
for i in $(seq 1 240); do
    if curl -fsS "http://127.0.0.1:18406" >/dev/null 2>&1; then echo "    ready"; break; fi
    sleep 1
    if (( i == 240 )); then
        echo "    order-svc never became ready; logs:" >&2
        "${COMPOSE[@]}" logs --tail=50 order-svc >&2 || true; exit 1
    fi
done

echo
echo "==> Act 1: create an order (idempotency key $KEY)"
echo "    The producer writes the order row AND an outbox row in ONE transaction."
client create alice widget "$KEY" | sed 's/^/    /'
echo "    Outbox row (published_at NULL = not yet relayed):"
psql_q "SELECT event_id, event_type, published_at FROM outbox WHERE event_id='$KEY';" | sed 's/^/    /'

echo
echo "==> Act 2: relay publishes to Kafka; consumer applies to the projection"
echo "    Polling the projection for event_id=$KEY ..."
applied=0
for i in $(seq 1 40); do
    n="$(psql_q "SELECT count(*) FROM order_projection WHERE event_id='$KEY';")"
    if [[ "$n" == "1" ]]; then applied=1; echo "    applied after ~$((i/2))s"; break; fi
    sleep 0.5
done
if (( ! applied )); then
    echo "    event did not reach the projection in time; consumer/relay logs:" >&2
    "${COMPOSE[@]}" logs --tail=30 outbox-relay order-consumer >&2 || true; exit 1
fi
echo "    Outbox now marked published:"
psql_q "SELECT event_id, (published_at IS NOT NULL) AS published FROM outbox WHERE event_id='$KEY';" | sed 's/^/    /'
echo "    Projection row:"
psql_q "SELECT event_id, payload FROM order_projection WHERE event_id='$KEY';" | sed 's/^/    /'
if command -v kcat >/dev/null 2>&1; then
    echo "    Topic contents via kcat (host):"
    kcat -b localhost:19092 -t orders -C -e -q 2>/dev/null | sed 's/^/      /' || true
else
    echo "    (install kcat — 'sudo dnf install kcat' — to dump the topic from the host)"
fi

echo
echo "==> Act 3: idempotency — inject a DUPLICATE of event_id=$KEY"
echo "    (simulates the relay re-publishing after a crash: at-least-once)"
"${COMPOSE[@]}" exec -T outbox-relay /usr/local/bin/outbox-relay produce "$KEY" \
    '{"event":"OrderCreated","duplicate":true}' 2>/dev/null | filter_compose | sed 's/^/    /'
echo "    Waiting for the consumer to see the duplicate ..."
seen_dup=0
for i in $(seq 1 30); do
    if "${COMPOSE[@]}" logs order-consumer 2>/dev/null | grep -q "duplicate event_id=$KEY"; then
        seen_dup=1; break
    fi
    sleep 0.5
done
"${COMPOSE[@]}" logs --tail=6 order-consumer 2>/dev/null | filter_compose | grep "event_id=$KEY" | sed 's/^/    /' || true
cnt="$(psql_q "SELECT count(*) FROM order_projection WHERE event_id='$KEY';")"
echo "    Projection rows for $KEY: $cnt  (still exactly one — the duplicate was a no-op)"
if (( seen_dup )) && [[ "$cnt" == "1" ]]; then
    echo "    => at-least-once delivery + idempotent consumer = exactly-once effect."
else
    echo "    (note: duplicate handling not confirmed; check consumer logs)"
fi

echo
echo "Done. Re-run with --keep to leave the stack up, or --clean to tear down."
