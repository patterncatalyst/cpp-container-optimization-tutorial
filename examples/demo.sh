#!/usr/bin/env bash
# ============================================================================
# Presentation driver — run all seven demos from one terminal.
#
# Lives in examples/ and drives the per-demo scripts beside it. This is the
# on-stage cockpit. It does NOT reimplement any demo; it runs each demo's own
# examples/demo-0X-*/demo.sh with the TTY inherited, so every per-demo pause /
# callout / code_ref still works exactly as when run standalone. The seven
# scripts remain fully usable on their own.
#
# Run from the examples/ directory:  ./demo.sh  (or examples/demo.sh)
#
# Order follows the DECK, not the directory numbers:
#   Demo 1 → 2 → 6 → 3 → 4 → 5 → 7
# (Demos 3 and 4 each bring up the shared LGTM stack on http://127.0.0.1:3000.)
#
# Usage:
#   ./demo.sh                 interactive menu (pick a demo, or run all)
#   ./demo.sh --all           run every demo in deck order, pausing between
#   ./demo.sh --no-pause      never stop for Enter (unattended / auto-test)
#   ./demo.sh --ide=clion     open every code_ref in CLion as it's cued
#   ./demo.sh --clean         run each demo's own --clean, then exit
#   ./demo.sh -h              this help
#
# Env:
#   DEMO_IDE=clion            same as --ide=clion (code_ref opens in CLion)
# ============================================================================

set -euo pipefail

# This script lives in examples/ and drives the per-demo demo.sh scripts that
# sit beside it (examples/demo-0X-*/demo.sh). Paths below are relative to here.
EXAMPLES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$EXAMPLES_DIR"

# shellcheck source=../scripts/lib/_helpers.sh
source "$EXAMPLES_DIR/../scripts/lib/_helpers.sh"

# Listed in DECK order; the selector you type is the canonical Demo number
# (so "Demo 4 — OTel" in the deck is what you press), which is field 1.
# Fields: num | dir | short name | tagline | needs-LGTM-stack(1/0)
DEMOS=(
  "1|demo-01-image-strategy|Image Strategy|UBI vs ubi-micro vs scratch + multi-stage + PGO|0"
  "2|demo-02-stl-layout|STL Layout Under Pressure|data-structure layout & cache behaviour|0"
  "6|demo-06-memory-and-allocators|Memory Management & Allocators|PMR, huge pages, cgroups v2, OOM|0"
  "3|demo-03-io-uring-grpc|io_uring + Async gRPC|async I/O + gRPC on the LGTM stack|1"
  "4|demo-04-observability|OTel Observability Stack|one C++ binary → traces/metrics/logs|1"
  "5|demo-05-isolation|Noisy-Neighbor Isolation|cgroup cpu.weight, the noisy neighbour|0"
  "7|demo-07-quality-pipeline|Quality Pipeline|analyzer, ASan, ABI, coverage gates|0"
)

DO_ALL=0
DO_CLEAN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)       DO_ALL=1;                shift;;
    --no-pause)  export DEMO_NO_PAUSE=1;  shift;;
    --ide=*)     export DEMO_IDE="${1#*=}"; shift;;
    --ide)       export DEMO_IDE="$2";    shift 2;;
    --clean)     DO_CLEAN=1;              shift;;
    -h|--help)   sed -n '2,24p' "$0"; exit 0;;
    *) log_err "unknown arg: $1"; exit 2;;
  esac
done

require podman
for c in hey jq curl; do
  command -v "$c" >/dev/null 2>&1 || log_warn "'$c' not on PATH — some demos degrade without it"
done

# Look up a demo row by its canonical Demo number; echoes the pipe-row or fails.
demo_row_by_num() {
  local want="$1" row
  for row in "${DEMOS[@]}"; do
    [[ "${row%%|*}" == "$want" ]] && { printf '%s' "$row"; return 0; }
  done
  return 1
}

run_one() {  # run_one <canonical Demo number>
  local row
  row="$(demo_row_by_num "$1")" || { log_warn "no Demo #$1"; return 1; }
  local num dir name tag stack
  IFS='|' read -r num dir name tag stack <<<"$row"

  hr
  printf '%s▶ Demo %s: %s%s\n' "$C_BOLD$C_YELLOW" "$num" "$name" "$C_RESET"
  callout "$tag" "path: examples/$dir/"
  if [[ "$stack" == "1" ]]; then
    callout "" "This demo brings up the shared LGTM stack:" \
            "  Grafana http://127.0.0.1:3000 · Tempo :3200 · Prometheus :9090 · Loki :3100"
  fi
  hr

  if [[ ! -x "$dir/demo.sh" ]]; then
    log_err "$dir/demo.sh not found or not executable — skipping."
    return 1
  fi

  # Run in a subshell so a demo's `cd`/traps/`set -e` can't leak back here.
  # TTY is inherited, so the demo's own pause/callout/code_ref work as usual.
  # A non-zero exit is reported but does NOT abort the whole session.
  ( cd "$dir" && ./demo.sh ) || log_warn "Demo '$name' exited non-zero (rc=$?) — continuing."
}

clean_all() {
  local row num dir name
  for row in "${DEMOS[@]}"; do
    IFS='|' read -r num dir name _ _ <<<"$row"
    log_step "Cleaning Demo $num — $name"
    ( cd "$dir" && ./demo.sh --clean ) || log_warn "clean of '$name' returned non-zero — continuing."
  done
  log_ok "All demos cleaned."
}

run_all() {
  banner \
    "C++20/23 Performance Under Container Constraints — full demo run" \
    "Seven demos, deck order (Demo 1 → 2 → 6 → 3 → 4 → 5 → 7)."
  local i num
  for i in "${!DEMOS[@]}"; do
    num="${DEMOS[$i]%%|*}"
    run_one "$num"
    if (( i < ${#DEMOS[@]} - 1 )); then
      pause "Demo done. Press Enter for the next one"
    fi
  done
  log_ok "All seven demos complete."
}

menu() {
  while :; do
    banner \
      "C++ Container Optimization — presentation cockpit" \
      "Pick a demo to run, or 'a' for all in deck order."
    local row num name tag stack marker
    for row in "${DEMOS[@]}"; do
      IFS='|' read -r num _ name tag stack <<<"$row"
      marker=""; [[ "$stack" == "1" ]] && marker=" ${C_DIM}[LGTM stack]${C_RESET}"
      printf '  %sDemo %s%s) %-32s %s%s%s%b\n' \
        "$C_BOLD$C_GREEN" "$num" "$C_RESET" "$name" "$C_DIM" "$tag" "$C_RESET" "$marker"
    done
    printf '  %sa%s) run ALL in deck order\n' "$C_BOLD$C_GREEN" "$C_RESET"
    printf '  %sc%s) clean every demo (images/stacks)\n' "$C_BOLD$C_GREEN" "$C_RESET"
    printf '  %sq%s) quit\n' "$C_BOLD$C_GREEN" "$C_RESET"
    [[ -n "${DEMO_IDE:-}" ]] && callout "" "DEMO_IDE=$DEMO_IDE — code_ref callouts will open in the IDE."
    printf '\n  %s⏎ choice:%s ' "$C_BOLD$C_BLUE" "$C_RESET"
    local choice; read -r choice || { echo; break; }
    case "$choice" in
      [1-7])
        if demo_row_by_num "$choice" >/dev/null; then
          run_one "$choice"; pause "Back to the menu — press Enter"
        else
          log_warn "no Demo #$choice"
        fi;;
      a|A) run_all; pause "Back to the menu — press Enter";;
      c|C) clean_all; pause "Back to the menu — press Enter";;
      q|Q|"") break;;
      *) log_warn "unrecognised choice: $choice";;
    esac
  done
  log_ok "Bye."
}

if [[ $DO_CLEAN -eq 1 ]]; then
  clean_all
elif [[ $DO_ALL -eq 1 ]]; then
  run_all
else
  menu
fi
