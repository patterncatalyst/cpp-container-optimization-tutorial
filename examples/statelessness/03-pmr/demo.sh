#!/usr/bin/env bash
# statelessness/03-pmr — PMR request arena demo driver.
#
# Three acts:
#   1. arena mode — the handler allocates per-request scratch from a
#      layered monotonic+pool arena, released in bulk at scope end.
#   2. bench mode — times arena bulk-release vs per-object new/delete,
#      showing the O(1)-vs-O(N) asymmetry from compendium Doc 03.
#   3. the lifetime trap — runs the standalone ASan binary pmr-trap,
#      which stores a view into arena memory in a process-scoped cache
#      and reads it after the arena dies. ASan catches the
#      heap-use-after-free. The nonzero exit is the POINT, not a
#      failure.
#
# Usage:
#   ./demo.sh           build + bring up + all three acts
#   ./demo.sh --keep    leave the service running
#   ./demo.sh --clean   tear down

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

KEEP_UP=0; CLEAN_ONLY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep)  KEEP_UP=1; shift ;;
        --clean) CLEAN_ONLY=1; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

COMPOSE=(podman compose -f compose.yml)

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

echo "==> Building and starting pmr-svc (first build pulls the gRPC chain)"
"${COMPOSE[@]}" up -d --build

echo "==> Waiting for healthz on http://127.0.0.1:18403"
for i in $(seq 1 120); do
    if curl -fsS "http://127.0.0.1:18403" >/dev/null 2>&1; then echo "    ready"; break; fi
    sleep 1
    if (( i == 120 )); then
        echo "    service never became ready; logs:" >&2
        "${COMPOSE[@]}" logs --tail=40 pmr-svc >&2 || true; exit 1
    fi
done

echo
echo "==> Act 1: arena mode — per-request scratch from a layered arena"
"${COMPOSE[@]}" exec -T pmr-svc \
    /usr/local/bin/pmr-client 127.0.0.1:50051 arena "alpha-beta-alpha-gamma-beta-alpha"

echo
echo "==> Act 2: bench mode — arena bulk release vs per-object new/delete"
"${COMPOSE[@]}" exec -T pmr-svc \
    /usr/local/bin/pmr-client 127.0.0.1:50051 bench 50000
echo "    Both timings are reported; don't read this as a scoreboard. Doc 03"
echo "    is explicit that PMR's reliable win is bounded, predictable per-"
echo "    request memory and shrunken tail-latency variance — not mean"
echo "    throughput. glibc's allocator is fast, so at modest N the heap can"
echo "    match or beat the arena's wall clock. The architectural reason"
echo "    (request-scope memory tied to request-scope lifetime) is the point."

echo
echo "==> Act 3: the lifetime trap — AddressSanitizer catches a dangling"
echo "    arena view stored in process-scoped state. A nonzero exit and a"
echo "    heap-use-after-free report are the EXPECTED, educational result."
echo "    ------------------------------------------------------------"
# Run the ASan binary directly. On most kernels ASan maps its shadow
# memory fine and catches the bug (the nonzero exit IS the success
# signal). We filter the compose provider's own status chatter — the
# "Executing external compose provider" notice and its "Error:
# executing ... exit status 134" line (134 = the deliberate ASan abort)
# — so the ASan report reads cleanly.
trap_out="$(
    "${COMPOSE[@]}" exec -T \
        -e ASAN_OPTIONS=abort_on_error=1:detect_leaks=0 \
        pmr-svc /usr/local/bin/pmr-trap 2>&1 || true
)"
printf '%s\n' "$trap_out" \
    | grep -vE 'Executing external compose provider|^Error: executing|set personality' \
    | sed 's/^/    /'
echo "    ------------------------------------------------------------"
if printf '%s\n' "$trap_out" | grep -q 'heap-use-after-free'; then
    echo "==> ASan caught the lifetime trap (heap-use-after-free) — as designed."
elif printf '%s\n' "$trap_out" | grep -qiE 'shadow memory|failed to allocate'; then
    echo "==> NOTE: ASan could not map its shadow memory at startup — this"
    echo "    kernel's ASLR entropy clashes with ASan's shadow region. The"
    echo "    in-container ASLR fix is itself blocked (the personality"
    echo "    syscall is filtered by seccomp), so apply a host-side"
    echo "    mitigation and re-run:"
    echo "      sudo sysctl vm.mmap_rnd_bits=28"
    echo "    or run the container with --security-opt seccomp=unconfined."
    echo "    See docs §12. The trap itself is real; this is an"
    echo "    ASan-in-container environment issue, not a code problem."
else
    echo "==> NOTE: did not observe the expected ASan report; see output above."
fi

echo
echo "Done. Re-run with --keep to leave the service up, or --clean to tear down."
