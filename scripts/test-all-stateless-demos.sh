#!/usr/bin/env bash
# Aggregator for the statelessness compendium examples. Runs every
# test-stateless-demo-*.sh script in order and prints a summary. Does
# NOT fail-fast — a failure in one example doesn't skip the rest. Exit
# status is non-zero if any test failed.
#
# Kept separate from test-all-demos.sh (which runs the main tutorial's
# seven demos) so the two collections' verification runs stay
# independent. A future scripts/test-everything.sh could call both.

set -uo pipefail
# Note: NOT -e — we want to keep going on individual test failure.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/_helpers.sh
source "$REPO_ROOT/scripts/lib/_helpers.sh"

declare -a names
declare -a statuses
declare -a durations

shopt -s nullglob
scripts=("$REPO_ROOT/scripts"/test-stateless-demo-*.sh)
shopt -u nullglob

if [[ ${#scripts[@]} -eq 0 ]]; then
    log_warn "no test-stateless-demo-*.sh scripts found yet"
    exit 0
fi

overall=0
for s in "${scripts[@]}"; do
    [[ -f "$s" ]] || continue
    name=$(basename "$s")
    log_step "Running $name"
    t0=$(date +%s)
    if bash "$s"; then
        rc=0
    else
        rc=$?
        overall=1
    fi
    t1=$(date +%s)
    names+=("$name")
    statuses+=("$rc")
    durations+=("$((t1 - t0))")
done

log_step "Summary — statelessness compendium examples"
printf '%-50s  %-8s  %s\n' "test" "result" "duration"
printf -- '-%.0s' {1..72}; echo
for i in "${!names[@]}"; do
    rc=${statuses[$i]}
    if [[ "$rc" -eq 0 ]]; then
        result="${C_GREEN}PASS${C_RESET}"
    else
        result="${C_RED}FAIL${C_RESET}"
    fi
    printf '%-50s  %b  %ss\n' "${names[$i]}" "$result" "${durations[$i]}"
done

exit "$overall"
