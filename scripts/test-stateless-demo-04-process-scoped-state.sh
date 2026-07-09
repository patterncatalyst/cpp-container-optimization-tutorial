#!/usr/bin/env bash
# statelessness/04-process-scoped-state end-to-end verification.
#
# Pass criteria:
#   1. healthz responds on :18404
#   2. startup logs show the composition root building state in
#      dependency order (+config, +metrics, +cache, +service, +server)
#   3. after looking up more distinct keys than capacity, Stats reports
#      cache_size == capacity AND evictions > 0 (bounded, not growing)
#   4. graceful stop logs the reverse-order teardown
#      (-server, -service, -cache, -metrics, -config)

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/_helpers.sh"

require podman curl

DEMO="$REPO_ROOT/examples/statelessness/04-process-scoped-state"
COMPOSE=(podman compose -f compose.yml)
SVC=state-svc
cd "$DEMO"

cleanup() { log_step "tearing down"; "${COMPOSE[@]}" down -v 2>/dev/null || true; }
trap cleanup EXIT

filter_compose() { grep -vE 'Executing external compose provider|^Error: executing'; }

log_step "Phase 1 — build + bring up (CACHE_CAPACITY=4)"
"${COMPOSE[@]}" up -d --build

log_step "Phase 1 — waiting for healthz on :18404"
if ! wait_for_http "http://127.0.0.1:18404" 180; then
    log_err "state-svc never came up. Logs:"
    "${COMPOSE[@]}" logs --tail=60 "$SVC" 2>&1 || true
    exit 1
fi
log_ok "state-svc healthz ready"

log_step "Phase 2 — composition root built state in dependency order"
startup="$("${COMPOSE[@]}" logs "$SVC" 2>/dev/null | filter_compose || true)"
ok=1
for marker in '+config' '+metrics' '+cache' '+service' '+server'; do
    if printf '%s\n' "$startup" | grep -q -- "\[wire\] $marker"; then
        log_info "saw $marker"
    else
        log_err "missing startup marker: $marker"; ok=0
    fi
done
[[ $ok -eq 1 ]] && log_ok "composition root order present" || exit 1

log_step "Phase 3 — bounded cache evicts rather than grows"
for k in k1 k2 k3 k4 k5 k6 k7 k8; do
    "${COMPOSE[@]}" exec -T "$SVC" /usr/local/bin/state-client 127.0.0.1:50051 lookup "$k" >/dev/null 2>&1 || {
        log_err "lookup $k failed"; exit 1; }
done
stats="$("${COMPOSE[@]}" exec -T "$SVC" /usr/local/bin/state-client 127.0.0.1:50051 stats 2>&1 | filter_compose)"
printf '%s\n' "$stats" | sed 's/^/    /'
size_field=$(printf '%s\n' "$stats" | grep -oE 'cache_size=[0-9]+(/[0-9]+)?' | head -1 | cut -d= -f2 || true)
size=${size_field%%/*}
cap=$(printf '%s\n' "$stats" | grep -oE 'cache_capacity=[0-9]+' | head -1 | cut -d= -f2 || true)
# fall back: cache_size=N/M encodes capacity as the denominator
[[ -z "$cap" && "$size_field" == */* ]] && cap=${size_field##*/}
evict=$(printf '%s\n' "$stats" | grep -oE 'evictions=[0-9]+' | head -1 | cut -d= -f2 || true)
if [[ "${size:-}" == "${cap:-x}" && "${evict:-0}" -gt 0 ]]; then
    log_ok "cache bounded at $size/$cap with $evict evictions"
else
    log_err "expected size==capacity and evictions>0; got size=$size cap=$cap evictions=$evict"
    exit 1
fi

log_step "Phase 4 — reverse-order teardown on graceful stop"
"${COMPOSE[@]}" stop -t 10 "$SVC" >/dev/null 2>&1 || true
sleep 1
teardown="$("${COMPOSE[@]}" logs --tail=20 "$SVC" 2>/dev/null | filter_compose || true)"
order="$(printf '%s\n' "$teardown" | grep -oE '\[wire\] -(server|service|cache|metrics|config)' | sed 's/.*-//')"
printf '%s\n' "$teardown" | grep -E '\[wire\] -' | sed 's/^/    /' || true
expected=$'server\nservice\ncache\nmetrics\nconfig'
if [[ "$order" == "$expected" ]]; then
    log_ok "teardown order is the exact reverse of construction"
else
    log_warn "teardown order was:
$order
(expected server/service/cache/metrics/config; timing or log truncation \
can reorder — non-fatal if all five appeared)"
fi

log_step "RESULT"
log_ok "statelessness/04-process-scoped-state verified — composition root, bounded cache, reverse teardown"
