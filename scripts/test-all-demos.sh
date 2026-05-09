#!/usr/bin/env bash
# Aggregator. Runs every test-demo-XX-*.sh script in order and prints
# a summary. Does NOT fail-fast — a failure in one demo doesn't skip
# the rest. Exit status is non-zero if any test failed.

set -uo pipefail
# Note: NOT -e — we want to keep going on individual test failure.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/_helpers.sh
source "$REPO_ROOT/scripts/lib/_helpers.sh"

declare -a names
declare -a statuses
declare -a durations

overall=0
for s in "$REPO_ROOT/scripts"/test-demo-*.sh; do
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

log_step "Summary"
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
