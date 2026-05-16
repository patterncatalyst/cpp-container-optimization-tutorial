#!/usr/bin/env bash
# Verify demo-07's test target builds and the gtest suite passes.
# The analyzer and abi targets are exercised by the demo's own demo.sh;
# the test script keeps things narrow.
# (Moved from scripts/test-demo-06-quality-pipeline.sh in r70.)

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/_helpers.sh
source "$REPO_ROOT/scripts/lib/_helpers.sh"

require podman

DEMO="$REPO_ROOT/examples/demo-07-quality-pipeline"
cd "$DEMO"

# Fresh lockfile if the placeholder is still in place.
if grep -q '%1700000000.0' conan.lock 2>/dev/null; then
  if command -v conan >/dev/null 2>&1; then
    conan profile detect --force >/dev/null 2>&1 || true
    conan lock create . --lockfile-out=conan.lock -s build_type=RelWithDebInfo \
        >/dev/null 2>&1 || true
  fi
fi

log_step "test-demo-07: build the tests target"
if podman build --target tests -t cpp-tut/demo-07:test .; then
    log_ok "test-demo-07 PASS (gtest suite green)"
    exit 0
fi
log_err "test-demo-07 FAIL: tests stage broke"
exit 1
