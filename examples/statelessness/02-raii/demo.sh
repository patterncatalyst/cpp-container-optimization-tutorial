#!/usr/bin/env bash
# statelessness/02-raii — RequestContext RAII demo driver.
#
# Builds the service image, brings it up, then drives the Process RPC
# through all three exit paths (ok / reject / throw). The point of the
# demo is in the server logs: every request prints exactly one
# "acquire" and one matching "release" for its RequestContext — proving
# the destructor fires on the normal-return, early-return, AND
# exception paths. The server's outstanding-lease counter returns to
# zero at shutdown, the machine-checkable confirmation.
#
# Usage:
#   ./demo.sh           full build + bring-up + drive + summary
#   ./demo.sh --keep    leave the service running at the end
#   ./demo.sh --clean   tear down only (after --keep)

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

KEEP_UP=0
CLEAN_ONLY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep)  KEEP_UP=1; shift ;;
        --clean) CLEAN_ONLY=1; shift ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

COMPOSE=(podman compose -f compose.yml)

if (( CLEAN_ONLY )); then
    echo "==> Tearing down"
    "${COMPOSE[@]}" down -v 2>/dev/null || true
    exit 0
fi

cleanup() {
    if (( ! KEEP_UP )); then
        echo "==> Tearing down (use --keep to leave it running)"
        "${COMPOSE[@]}" down -v 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo "==> Building and starting raii-svc (first build pulls the gRPC chain)"
"${COMPOSE[@]}" up -d --build

echo "==> Waiting for healthz on http://127.0.0.1:18402"
for i in $(seq 1 120); do
    if curl -fsS "http://127.0.0.1:18402" >/dev/null 2>&1; then
        echo "    ready"
        break
    fi
    sleep 1
    if (( i == 120 )); then
        echo "    service never became ready; logs:" >&2
        "${COMPOSE[@]}" logs --tail=40 raii-svc >&2 || true
        exit 1
    fi
done

# Drive each mode via the client baked into the image (runs as a
# one-shot exec inside the running container, so no host gRPC needed).
drive() {
    local mode="$1"
    echo
    echo "==> Process(mode=$mode)"
    "${COMPOSE[@]}" exec -T raii-svc \
        /usr/local/bin/raii-client 127.0.0.1:50051 "$mode" "demo-payload" \
        || echo "    (client exit code $? — expected for non-ok modes if it mismatched)"
}

drive ok
drive reject
drive throw

echo
echo "==> Server log — RequestContext lifecycle (acquire/release pairs)"
echo "    Every request shows one acquire and one release, on all three"
echo "    paths. That's RAII cleaning up on normal return, early return,"
echo "    and exception unwinding alike."
echo "    ------------------------------------------------------------"
"${COMPOSE[@]}" logs --tail=40 raii-svc 2>/dev/null \
    | grep -E '\[rc\] (acquire|work|catch|release)' || true
echo "    ------------------------------------------------------------"

# Count acquire/release to show they balance.
logs="$("${COMPOSE[@]}" logs raii-svc 2>/dev/null || true)"
acq=$(printf '%s\n' "$logs" | grep -c '\[rc\] acquire' || true)
rel=$(printf '%s\n' "$logs" | grep -c '\[rc\] release' || true)
echo
echo "==> Lifecycle balance: ${acq} acquire / ${rel} release"
if [[ "$acq" == "$rel" && "$acq" -ge 3 ]]; then
    echo "    BALANCED — the destructor ran on every exit path."
else
    echo "    WARNING: acquire/release counts differ — investigate." >&2
fi

echo
echo "Done. Re-run with --keep to leave the service up, or --clean to tear down."
