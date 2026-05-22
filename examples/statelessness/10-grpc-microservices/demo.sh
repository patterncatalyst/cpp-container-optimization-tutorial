#!/usr/bin/env bash
# demo.sh — statelessness/10-grpc-microservices (the gRPC capstone)
#
# Drives the order-pricing service end to end. Each PriceOrder call composes:
#   - a customer lookup in PostgreSQL (libpq pool, deadline-propagated)
#   - a product-price lookup per line item (PostgreSQL)
#   - an OUTBOUND gRPC call to the tax service (channel cache, same deadline)
#   - an idempotency store keyed on the client's idempotency_key
#
# Acts:
#   1. Price an order        — alice (US, 7%): subtotal from products, tax
#                              from the tax service, total returned.
#   2. Tax-exempt path       — carol (US, tax_exempt): the handler short-
#                              circuits the outbound tax call, tax=0.
#   3. Idempotent replay      — re-send act 1's key: the stored result comes
#                              back without recomputing (Doc 07).
#
# Calls go through the in-image pricing-client via `podman exec` — no host
# gRPC tooling needed.

set -euo pipefail

COMPOSE="podman compose -f compose.yml"
PRICING="stateless-10-pricing"

if [[ "${1:-}" == "--clean" ]]; then
    $COMPOSE down -v --remove-orphans 2>/dev/null || true
    exit 0
fi
KEEP=0
[[ "${1:-}" == "--keep" ]] && KEEP=1

cleanup() { [[ $KEEP -eq 1 ]] || { echo; echo "==> Tearing down (use --keep to leave it running)"; $COMPOSE down -v --remove-orphans 2>/dev/null || true; }; }
trap cleanup EXIT

# pricing-client <addr> <idem_key> <customer> <product:qty>...
price() { podman exec "$PRICING" /usr/local/bin/pricing-client localhost:50051 "$@"; }

echo "==> Building and starting postgres + tax-svc + pricing-svc"
$COMPOSE up -d --build

echo "    waiting for pricing-svc to report ready ..."
for _ in $(seq 1 40); do
    podman exec "$PRICING" /usr/local/bin/health-probe localhost:50051 pricing.v1.Pricing 2>/dev/null | grep -q "SERVING" && break
    sleep 0.5
done
echo "    ready"

KEY1="K1-$(date +%s)"

# ── Act 1: price an order (composes PG + outbound tax gRPC) ───────────
echo
echo "==> Act 1: price an order for alice (US, taxable)"
echo "    2x widget (1999) + 1x gadget (4950) = subtotal 8948; US tax 7%."
echo "    The handler reads alice + the product prices from PostgreSQL, then"
echo "    calls the tax service over gRPC (deadline propagated) for the tax."
echo
echo "    $(price "$KEY1" alice widget:2 gadget:1)"

# ── Act 2: tax-exempt path (short-circuits the outbound call) ─────────
echo
echo "==> Act 2: price an order for carol (US, tax_exempt)"
echo "    Same items, but carol is tax-exempt — the handler returns tax=0"
echo "    WITHOUT calling the tax service at all (a branch in compute_tax)."
echo
echo "    $(price "K2-$(date +%s)" carol widget:2 gadget:1)"

# ── Act 3: idempotent replay ──────────────────────────────────────────
echo
echo "==> Act 3: replay act 1's idempotency key ($KEY1)"
echo "    The service finds the stored result and returns it unchanged,"
echo "    without re-reading prices or re-calling the tax service (Doc 07)."
echo "    Note the IDENTICAL order_id — proof it was the stored row, not a"
echo "    fresh computation (a new call would mint a new order_id)."
echo
echo "    first call order_id was embedded above; replay returns:"
echo "    $(price "$KEY1" alice widget:2 gadget:1)"

echo
echo "Done. Re-run with --keep to leave it up, or --clean to tear down."
