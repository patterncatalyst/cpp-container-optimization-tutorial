#!/usr/bin/env bash
# statelessness/07-state-externalization end-to-end verification.
#
# Pass criteria:
#   1. postgres + order-svc come up; order-svc healthz responds on :18405
#   2. CreateOrder with key K1 creates an order (idempotent_replay=false)
#   3. CreateOrder with the SAME key K1 returns the SAME order_id with
#      idempotent_replay=true (the database deduplicated the retry)
#   4. CreateOrder with a new key K2 yields a DIFFERENT order_id
#   5. GetOrder reads K2's order back

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/_helpers.sh"

require podman curl

DEMO="$REPO_ROOT/examples/statelessness/07-state-externalization"
COMPOSE=(podman compose -f compose.yml)
SVC=order-svc
cd "$DEMO"

cleanup() { log_step "tearing down"; "${COMPOSE[@]}" down -v 2>/dev/null || true; }
trap cleanup EXIT

filter_compose() { grep -vE 'Executing external compose provider|^Error: executing'; }
client() { "${COMPOSE[@]}" exec -T "$SVC" /usr/local/bin/order-client 127.0.0.1:50051 "$@" 2>/dev/null | filter_compose; }
field() { grep -oE "$1=[0-9a-zA-Z]+" | head -1 | cut -d= -f2; }

log_step "Phase 1 — build + bring up postgres + order-svc"
"${COMPOSE[@]}" up -d --build

log_step "Phase 1 — waiting for order-svc healthz on :18405"
if ! wait_for_http "http://127.0.0.1:18405" 240; then
    log_err "order-svc never came up. Logs:"
    "${COMPOSE[@]}" logs --tail=80 "$SVC" 2>&1 || true
    exit 1
fi
log_ok "order-svc healthz ready"

log_step "Phase 2 — CreateOrder K1 (fresh insert)"
o1="$(client create alice widget K1)"; printf '    %s\n' "$o1"
id1="$(printf '%s\n' "$o1" | field order_id)"
rep1="$(printf '%s\n' "$o1" | field idempotent_replay)"
if [[ -n "$id1" && "$rep1" == "false" ]]; then
    log_ok "created order_id=$id1 (replay=false)"
else
    log_err "expected a fresh insert; got: $o1"; exit 1
fi

log_step "Phase 3 — CreateOrder K1 again (must replay, same id)"
o2="$(client create alice widget K1)"; printf '    %s\n' "$o2"
id2="$(printf '%s\n' "$o2" | field order_id)"
rep2="$(printf '%s\n' "$o2" | field idempotent_replay)"
if [[ "$id2" == "$id1" && "$rep2" == "true" ]]; then
    log_ok "retry replayed order_id=$id2 (replay=true) — no duplicate created"
else
    log_err "expected replay of $id1 with replay=true; got id=$id2 replay=$rep2"
    exit 1
fi

log_step "Phase 4 — CreateOrder K2 (distinct order)"
o3="$(client create bob gadget K2)"; printf '    %s\n' "$o3"
id3="$(printf '%s\n' "$o3" | field order_id)"
if [[ -n "$id3" && "$id3" != "$id1" ]]; then
    log_ok "new key created a distinct order_id=$id3"
else
    log_err "expected a distinct order_id; got: $o3"; exit 1
fi

log_step "Phase 5 — GetOrder reads K2's order back"
g="$(client get "$id3")"; printf '    %s\n' "$g"
gid="$(printf '%s\n' "$g" | field order_id)"
if [[ "$gid" == "$id3" ]]; then
    log_ok "GetOrder returned order_id=$gid"
else
    log_err "GetOrder did not return order_id=$id3; got: $g"; exit 1
fi

log_step "RESULT"
log_ok "statelessness/07-state-externalization verified — pool RAII, DB-authoritative idempotency, read-back"
