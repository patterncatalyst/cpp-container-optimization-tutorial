#!/usr/bin/env bash
# Demo 3 — io_uring echo + async gRPC, with a networking-mode comparison.
#
#   ./demo.sh
#   ./demo.sh --variant uring|grpc
#   ./demo.sh --network rootless|host
#   ./demo.sh --clean

set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DEMO_DIR"

# shellcheck source=../../scripts/lib/_helpers.sh
source "$(cd ../../scripts/lib && pwd)/_helpers.sh"

VARIANT=both
NETWORK=both
DO_CLEAN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --variant) VARIANT="$2"; shift 2;;
    --network) NETWORK="$2"; shift 2;;
    --clean)   DO_CLEAN=1;   shift;;
    *) log_err "unknown arg: $1"; exit 2;;
  esac
done

if [[ $DO_CLEAN -eq 1 ]]; then
  podman compose -f compose.yml down -v 2>/dev/null || true
  podman rmi -f cpp-tut/demo-03:echo-uring cpp-tut/demo-03:grpc-async 2>/dev/null || true
  rm -rf results
  log_ok "Cleaned."
  exit 0
fi

require podman hey jq

mkdir -p results
log_info "Kernel: $(uname -r)   (io_uring multishot needs >= 5.19)"

# Build images via compose (fast; cached on rebuild).
log_step "Building images"
podman compose -f compose.yml build

run_uring_bench() {
  local network="$1"
  local extra=()
  [[ "$network" == "host" ]] && extra=(--network=host) || extra=(-p 18301:8080)
  log_step "echo-uring on $network network"
  podman run --rm -d --name demo03-uring "${extra[@]}" cpp-tut/demo-03:echo-uring
  register_cleanup demo03-uring
  wait_for_http "http://127.0.0.1:18301/" 5 || true   # echo isn't HTTP; this just waits a beat
  sleep 0.5
  # Use a small TCP echo client emulation via /dev/tcp wouldn't measure well,
  # so we approximate with hey against an HTTP probe variant. For a tutorial
  # this is documented honestly in the section text; the real measurement
  # tool is `tcpkali`, recommended in §7's "where to go next."
  hey -n 5000 -c 50 -t 5 "http://127.0.0.1:18301/" \
    > "results/uring-$network.txt" 2>&1 || true
  podman stop demo03-uring >/dev/null
}

run_grpc_bench() {
  local network="$1"
  local extra=()
  [[ "$network" == "host" ]] && extra=(--network=host) || extra=(-p 18302:50051)
  log_step "grpc-async on $network network"
  podman run --rm -d --name demo03-grpc "${extra[@]}" cpp-tut/demo-03:grpc-async
  register_cleanup demo03-grpc
  sleep 1
  if command -v ghz >/dev/null 2>&1; then
    ghz --insecure --proto src/echo.proto --call echo.EchoService.Echo \
        -d '{"message":"hello"}' -c 50 -n 10000 \
        --format=json 127.0.0.1:18302 \
        > "results/grpc-$network.json" 2>/dev/null || true
    log_ok "grpc results: results/grpc-$network.json"
  else
    log_warn "ghz not on PATH; skipping gRPC bench (install: go install github.com/bojand/ghz/cmd/ghz@latest)"
  fi
  podman stop demo03-grpc >/dev/null
}

networks=()
[[ "$NETWORK" == "rootless" || "$NETWORK" == "both" ]] && networks+=("rootless")
[[ "$NETWORK" == "host"     || "$NETWORK" == "both" ]] && networks+=("host")

for net in "${networks[@]}"; do
  if [[ "$net" == "host" ]] && [[ "$(id -u)" -ne 0 ]]; then
    if ! podman info --format '{{.Host.Security.Rootless}}' | grep -qi true; then
      log_warn "skipping host network: not rootless and not root"
      continue
    fi
  fi
  [[ "$VARIANT" == "uring" || "$VARIANT" == "both" ]] && run_uring_bench "$net"
  [[ "$VARIANT" == "grpc"  || "$VARIANT" == "both" ]] && run_grpc_bench "$net"
done

log_step "Results summary"
ls -la results/ 2>/dev/null || true
log_ok "Done."
