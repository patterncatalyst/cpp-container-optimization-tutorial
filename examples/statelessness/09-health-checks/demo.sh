#!/usr/bin/env bash
# demo.sh — statelessness/09-health-checks
#
# Three acts:
#   1. Staged startup     — readiness reports NOT_SERVING during init, then
#                           flips to SERVING; liveness is up the whole time.
#   2. Liveness vs ready   — SIGUSR1 drives readiness NOT_SERVING while
#                           liveness stays 200; SIGUSR1 again restores it.
#   3. Graceful shutdown   — SIGTERM (podman stop) drains in order and the
#                           process exits 0; the logs show the sequence.
#
# We query readiness with the in-image health-probe via `podman exec`, and
# liveness with curl against the published HTTP port. No host gRPC tooling
# needed.

set -euo pipefail

COMPOSE="podman compose -f compose.yml"
CTR="stateless-09hc-svc"
SVC="demo.health.EchoService"
LIVENESS_URL="http://127.0.0.1:18080/healthz"

if [[ "${1:-}" == "--clean" ]]; then
    $COMPOSE down -v --remove-orphans 2>/dev/null || true
    exit 0
fi
KEEP=0
[[ "${1:-}" == "--keep" ]] && KEEP=1

cleanup() { [[ $KEEP -eq 1 ]] || { echo; echo "==> Tearing down (use --keep to leave it running)"; $COMPOSE down -v --remove-orphans 2>/dev/null || true; }; }
trap cleanup EXIT

# probe readiness from inside the container; prints SERVING/NOT_SERVING line
ready() { podman exec "$CTR" /usr/local/bin/health-probe localhost:50051 "$SVC" 2>/dev/null || true; }
live()  { curl -fsS --max-time 2 "$LIVENESS_URL" >/dev/null 2>&1 && echo "200 ok" || echo "DOWN"; }

echo "==> Building and starting health-svc"
$COMPOSE up -d --build

# ── Act 1: staged startup ─────────────────────────────────────────────
echo
echo "==> Act 1: staged startup"
echo "    The gRPC server binds immediately but reports NOT_SERVING while it"
echo "    does ~3s of simulated init. A startup probe waits instead of killing it."
echo
# Wait for the container process / liveness to answer, then watch readiness flip.
for _ in $(seq 1 20); do live | grep -q "200" && break; sleep 0.5; done
echo "    liveness  /healthz : $(live)        (process is up)"
echo "    readiness $SVC : $(ready | sed 's/^health-probe[^:]*: //')   (still initializing)"
echo "    ... waiting for init to complete ..."
for _ in $(seq 1 20); do
    ready | grep -qw SERVING && break
    sleep 0.5
done
echo "    liveness  /healthz : $(live)"
echo "    readiness $SVC : $(ready | sed 's/^health-probe[^:]*: //')      (init done; now ready)"

# ── Act 2: liveness vs readiness ──────────────────────────────────────
echo
echo "==> Act 2: liveness and readiness are DIFFERENT questions"
echo "    Send SIGUSR1: the service flips READINESS to NOT_SERVING (traffic would"
echo "    stop) but LIVENESS stays green (no restart). This is the distinction that"
echo "    keeps a temporarily-busy or draining replica from being killed."
echo
podman kill -s SIGUSR1 "$CTR" >/dev/null
sleep 1
echo "    after SIGUSR1:"
echo "      liveness  /healthz : $(live)        <- still alive, would NOT be restarted"
echo "      readiness $SVC : $(ready | sed 's/^health-probe[^:]*: //')   <- removed from traffic"
echo
echo "    Send SIGUSR1 again to recover readiness (no restart needed — the"
echo "    12-factor corollary: not-ready should return to ready without a restart)."
podman kill -s SIGUSR1 "$CTR" >/dev/null
sleep 1
echo "      readiness $SVC : $(ready | sed 's/^health-probe[^:]*: //')      <- ready again"

# ── Act 3: graceful shutdown ──────────────────────────────────────────
echo
echo "==> Act 3: graceful shutdown (SIGTERM via 'podman stop')"
echo "    Watch the ordered drain: readiness NOT_SERVING first (stop new traffic),"
echo "    then the background worker stops, then gRPC drains in-flight RPCs, then"
echo "    a clean exit 0."
echo
podman stop -t 30 "$CTR" >/dev/null 2>&1 &
STOP_PID=$!
# Stream the shutdown log lines as they appear.
sleep 1
podman logs "$CTR" 2>&1 | grep -E "SIGTERM|readiness NOT_SERVING|worker drained|Shutdown|Wait\(\) returned" \
    | sed 's/^/      /' || true
wait $STOP_PID 2>/dev/null || true
echo
echo "    Exit code of the container process:"
echo "      $(podman inspect "$CTR" --format '{{.State.ExitCode}}' 2>/dev/null || echo '0') (0 = clean graceful stop)"
echo
echo "Done. Re-run with --keep to leave it up, or --clean to tear down."
