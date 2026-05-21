#!/usr/bin/env bash
# statelessness/07-outbox-pattern end-to-end verification.
#
# Pass criteria:
#   1. postgres + kafka + order-svc + relay + consumer come up;
#      order-svc healthz responds on :18406
#   2. CreateOrder K1 writes an order AND an outbox row in one txn
#   3. the relay publishes the event and the consumer applies it into
#      order_projection (poll until it lands); outbox row is marked
#      published
#   4. injecting a DUPLICATE of the same event_id (via the relay's
#      one-shot produce mode) is deduped by the consumer: the projection
#      still holds exactly one row and the consumer logs "duplicate"
#
# Idempotency is exercised without kcat — the relay's produce mode
# injects the duplicate directly, so CI needs only podman + curl.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/_helpers.sh"

require podman curl

DEMO="$REPO_ROOT/examples/statelessness/07-outbox-pattern"
COMPOSE=(podman compose -f compose.yml)
KEY="K1-$(date +%s)"
cd "$DEMO"

cleanup() { log_step "tearing down"; "${COMPOSE[@]}" down -v 2>/dev/null || true; }
trap cleanup EXIT

filter_compose() { grep -vE 'Executing external compose provider|^Error: executing'; }
psql_q() { "${COMPOSE[@]}" exec -T postgres psql -U orders -d orders -tAc "$1" 2>/dev/null | filter_compose; }
client() { "${COMPOSE[@]}" exec -T order-svc /usr/local/bin/order-client 127.0.0.1:50051 "$@" 2>/dev/null | filter_compose; }
field() { grep -oE "$1=[0-9a-zA-Z-]+" | head -1 | cut -d= -f2; }

log_step "Phase 1 — build + bring up postgres + kafka + order-svc + relay + consumer"
"${COMPOSE[@]}" up -d --build

log_step "Phase 1 — waiting for order-svc healthz on :18406"
if ! wait_for_http "http://127.0.0.1:18406" 300; then
    log_err "order-svc never came up. Logs:"
    "${COMPOSE[@]}" logs --tail=80 order-svc 2>&1 || true
    exit 1
fi
log_ok "order-svc healthz ready"

log_step "Phase 2 — CreateOrder $KEY writes order + outbox in one transaction"
o1="$(client create alice widget "$KEY")"; printf '    %s\n' "$o1"
id1="$(printf '%s\n' "$o1" | field order_id)"
rep1="$(printf '%s\n' "$o1" | field idempotent_replay)"
if [[ -z "$id1" || "$rep1" != "false" ]]; then
    log_err "expected a fresh insert; got: $o1"; exit 1
fi
ob="$(psql_q "SELECT count(*) FROM outbox WHERE event_id='$KEY';")"
if [[ "$ob" == "1" ]]; then
    log_ok "order_id=$id1 created and outbox row written atomically"
else
    log_err "expected exactly one outbox row for $KEY; got: $ob"; exit 1
fi

log_step "Phase 3 — relay publishes; consumer applies into the projection"
applied=0
for i in $(seq 1 60); do
    n="$(psql_q "SELECT count(*) FROM order_projection WHERE event_id='$KEY';")"
    if [[ "$n" == "1" ]]; then applied=1; break; fi
    sleep 0.5
done
if (( ! applied )); then
    log_err "event never reached the projection. relay/consumer logs:"
    "${COMPOSE[@]}" logs --tail=40 outbox-relay order-consumer 2>&1 || true
    exit 1
fi
pub="$(psql_q "SELECT (published_at IS NOT NULL) FROM outbox WHERE event_id='$KEY';")"
if [[ "$pub" == "t" ]]; then
    log_ok "consumer applied event; outbox row marked published"
else
    log_err "outbox row not marked published; got: $pub"; exit 1
fi

log_step "Phase 4 — inject a DUPLICATE event_id=$KEY (at-least-once redelivery)"
"${COMPOSE[@]}" exec -T outbox-relay /usr/local/bin/outbox-relay produce "$KEY" \
    '{"event":"OrderCreated","duplicate":true}' 2>/dev/null | filter_compose | sed 's/^/    /'
seen_dup=0
for i in $(seq 1 40); do
    if "${COMPOSE[@]}" logs order-consumer 2>/dev/null | grep -q "duplicate event_id=$KEY"; then
        seen_dup=1; break
    fi
    sleep 0.5
done
cnt="$(psql_q "SELECT count(*) FROM order_projection WHERE event_id='$KEY';")"
if (( seen_dup )) && [[ "$cnt" == "1" ]]; then
    log_ok "duplicate deduped — projection still holds exactly one row"
else
    log_err "idempotency failed: seen_dup=$seen_dup projection_count=$cnt"
    "${COMPOSE[@]}" logs --tail=40 order-consumer 2>&1 || true
    exit 1
fi

log_step "RESULT"
log_ok "statelessness/07-outbox-pattern verified — atomic order+outbox write, relay publish, idempotent consumer (exactly-once effect)"
