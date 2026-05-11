#!/usr/bin/env bash
# Demo-03 — async gRPC + io_uring driver.
#
# Builds the demo-03-svc image, brings up the stack with the shared
# LGTM observability backend, then drives three load tests:
#   1. gRPC Echo on :50051 via ghz (run in a container so no
#      install step is required)
#   2. io_uring TCP echo on :9000 via tcp-loadgen (built into the
#      demo-03 image; runs as a separate exec)
#   3. Asio TCP echo on :9001 via tcp-loadgen (same binary)
#
# Prints a side-by-side summary of TCP latencies for the two echo
# backends. The gRPC numbers (which include framing + protobuf
# encode + decode) show up in Grafana via the demo3.grpc.latency
# histogram.
#
# Usage:
#   ./demo.sh                  full bring-up + load + summary
#   ./demo.sh --keep           don't tear down at end
#   ./demo.sh --clean          tear down only (run after --keep)

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DIR/../.." && pwd)"
cd "$DIR"

KEEP_UP=0
CLEAN_ONLY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep)  KEEP_UP=1; shift ;;
        --clean) CLEAN_ONLY=1; shift ;;
        -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

OBS="$REPO_ROOT/observability/compose.yml"
COMPOSE=(podman compose -f compose.yml -f "$OBS")

if (( CLEAN_ONLY )); then
    "${COMPOSE[@]}" down -v 2>/dev/null || true
    exit 0
fi

cleanup() {
    # Always capture demo-03-svc logs before tearing down, regardless
    # of exit status. If the container crashed early, this is the only
    # way to see WHY. Logs go to stderr so they appear in the failed
    # build output above the "tearing down" line.
    echo
    echo "==> Capturing demo-03-svc logs (last 100 lines) before teardown:"
    podman logs --tail=100 demo03-svc 2>&1 | sed 's/^/    /' || true
    echo

    if (( KEEP_UP == 0 )); then
        echo "==> tearing down"
        "${COMPOSE[@]}" down -v 2>/dev/null || true
    else
        echo "==> stack left running. Tear down with:"
        echo "    ./demo.sh --clean"
    fi
}
trap cleanup EXIT

# ── Bring up stack ────────────────────────────────────────────────────

echo "==> Bringing up stack + service (--build; first run ~30-45 min)"
"${COMPOSE[@]}" up -d --build

echo "==> Waiting for demo-03-svc healthz to return 200"
ready=0
for i in {1..120}; do
    if curl -fsS --max-time 2 "http://127.0.0.1:18403" >/dev/null 2>&1; then
        echo "    demo-03-svc ready"
        ready=1
        break
    fi
    # If the container has already exited, no point waiting 120s
    if ! podman ps --filter name=demo03-svc --filter status=running -q | grep -q .; then
        echo "    demo-03-svc container is NOT running — early exit"
        break
    fi
    sleep 1
done

if (( ready == 0 )); then
    echo
    echo "==> Healthz never responded. Container state:"
    podman ps -a --filter name=demo03-svc --format '    {{.Names}} {{.Status}}'
    echo "==> Aborting load phases — see logs from cleanup trap below"
    exit 1
fi

# ── Phase 1: gRPC load via ghz ────────────────────────────────────────
#
# ghz is the canonical gRPC load generator. We run it in a container
# (ghcr.io/bojand/ghz) joined to the same network as demo-03-svc so it
# can reach the service by container name. The proto file is mounted
# read-only into the ghz container so it knows the service definition.

echo
echo "==> Phase 1 — gRPC Echo load via ghz (10s, 50 concurrent)"
podman run --rm --network tutorial-obs \
    -v "$DIR/proto:/proto:ro,Z" \
    ghcr.io/bojand/ghz:0.120.0 \
        --insecure \
        --proto /proto/echo.proto \
        --call demo03.Echo.Echo \
        -d '{"payload":"aGVsbG8=","client_send_unix_nanos":0}' \
        -c 50 -z 10s \
        demo03-svc:50051 \
    || echo "ghz returned non-zero (often expected on stop signal)"

# ── Phase 2 & 3: TCP echo load via tcp-loadgen ────────────────────────
#
# Run the loadgen binary that we built into the demo-03 image. Use
# `podman exec` to invoke it inside the running container, which is
# both simpler than mounting a binary in and ensures we hit the
# server over the loopback inside its own network namespace (the
# inter-container hop is ~the same as host-to-container in our
# setup, but loopback avoids any kube-proxy-style detours that may
# affect timing).

echo
echo "==> Phase 2 — io_uring direct echo (:9000) load"
io_uring_json=$(podman exec demo03-svc \
    /usr/local/bin/tcp-loadgen 127.0.0.1 9000 32 200 256)
echo "    $io_uring_json"

echo
echo "==> Phase 3 — Asio io_uring echo (:9001) load"
asio_json=$(podman exec demo03-svc \
    /usr/local/bin/tcp-loadgen 127.0.0.1 9001 32 200 256)
echo "    $asio_json"

# ── Summary table ─────────────────────────────────────────────────────

if command -v jq >/dev/null 2>&1; then
    echo
    echo "==> Summary — TCP echo latency comparison (32 conns × 200 reqs × 256 B)"
    echo
    printf "%-22s %10s %10s %10s %10s %15s\n" \
           "Backend" "min µs" "p50 µs" "p99 µs" "max µs" "throughput/s"
    printf -- "%-22s %10s %10s %10s %10s %15s\n" \
           "──────────────────────" "──────────" "──────────" "──────────" "──────────" "───────────────"
    for label in "io_uring direct:$io_uring_json" "Asio io_uring:$asio_json"; do
        name="${label%%:*}"
        json="${label#*:}"
        printf "%-22s %10d %10d %10d %10d %15.1f\n" \
            "$name" \
            "$(echo "$json" | jq .min_us)" \
            "$(echo "$json" | jq .p50_us)" \
            "$(echo "$json" | jq .p99_us)" \
            "$(echo "$json" | jq .max_us)" \
            "$(echo "$json" | jq .throughput_per_sec)"
    done
fi

echo
echo "==> Open Grafana at http://127.0.0.1:3000 to see"
echo "    - demo3.grpc.latency (histogram)"
echo "    - demo3.grpc.requests (counter)"
echo "    - demo3.tcp.iouring.connections / demo3.tcp.asio.connections"
