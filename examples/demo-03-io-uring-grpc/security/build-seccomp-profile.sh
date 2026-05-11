#!/usr/bin/env bash
# Generate seccomp-iouring.json from your local podman's default
# seccomp profile, with io_uring syscalls added to the allow list.
#
# Why regenerate locally instead of shipping a static JSON:
#
# Podman's default profile is updated as new kernel syscalls are added
# and as security baselines evolve. A static snapshot of the profile
# committed to the repo would go stale; this script always produces a
# profile that matches your current podman + kernel + container-selinux
# baseline, with our three io_uring additions overlaid on top.
#
# The base default profile lives at one of these paths on Fedora/RHEL:
#   /usr/share/containers/seccomp.json     (containers-common package)
#   /etc/containers/seccomp.json           (if site-customized)
#
# Requires:
#   - jq (for JSON manipulation)
#   - containers-common package (for the base profile)
#
# Output:
#   ./seccomp-iouring.json — drop in as `--security-opt seccomp=...`
#
# Idempotent: re-run whenever your podman or containers-common updates.

set -euo pipefail

SECURITY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT="$SECURITY_DIR/seccomp-iouring.json"

# Locate the base profile.
BASE_PROFILE=""
for candidate in \
    /etc/containers/seccomp.json \
    /usr/share/containers/seccomp.json \
; do
    if [[ -f "$candidate" ]]; then
        BASE_PROFILE="$candidate"
        break
    fi
done

if [[ -z "$BASE_PROFILE" ]]; then
    echo "==> ERROR: could not find podman's default seccomp profile."
    echo "    Searched:"
    echo "      /etc/containers/seccomp.json"
    echo "      /usr/share/containers/seccomp.json"
    echo "    Install containers-common:  sudo dnf install containers-common"
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "==> ERROR: jq not found."
    echo "    Install:  sudo dnf install jq"
    exit 1
fi

echo "==> Base profile: $BASE_PROFILE"
echo "==> Overlay: add io_uring_setup / io_uring_enter / io_uring_register"
echo "==> Output:   $OUTPUT"

# Build the io_uring overlay as a single syscall entry:
#   { "names": ["io_uring_setup", ...], "action": "SCMP_ACT_ALLOW" }
# Append to the .syscalls array of the base profile.
#
# Using jq's . | .syscalls += [...] keeps the rest of the profile
# (defaultAction, defaultErrnoRet, architectures, syscalls[]) intact.

iouring_overlay='[{
    "names": ["io_uring_setup", "io_uring_enter", "io_uring_register"],
    "action": "SCMP_ACT_ALLOW",
    "args": [],
    "comment": "Added by demo-03 build-seccomp-profile.sh; required for io_uring",
    "includes": {},
    "excludes": {}
}]'

# Some podman versions ship the profile gzipped; detect and decompress.
TMP_BASE=$(mktemp)
trap 'rm -f "$TMP_BASE"' EXIT
if file "$BASE_PROFILE" 2>/dev/null | grep -qi gzip; then
    gunzip -c "$BASE_PROFILE" > "$TMP_BASE"
else
    cp "$BASE_PROFILE" "$TMP_BASE"
fi

# Sanity-check that the base profile parses as JSON and has the
# expected shape.
if ! jq -e '.defaultAction and (.syscalls | type == "array")' "$TMP_BASE" >/dev/null 2>&1; then
    echo "==> ERROR: base profile $BASE_PROFILE doesn't look like a valid"
    echo "    seccomp profile (missing defaultAction or syscalls array)."
    exit 1
fi

# Apply the overlay.
jq --argjson overlay "$iouring_overlay" '.syscalls += $overlay' \
    "$TMP_BASE" > "$OUTPUT"

# Verify the result.
if ! jq -e '.defaultAction and (.syscalls | length > 0)' "$OUTPUT" >/dev/null 2>&1; then
    echo "==> ERROR: produced output isn't valid JSON or is missing fields"
    exit 1
fi

# Confirm our overlay actually landed.
if ! jq -e '.syscalls[] | select(.names[]? == "io_uring_setup") | .action == "SCMP_ACT_ALLOW"' \
        "$OUTPUT" >/dev/null 2>&1; then
    echo "==> WARNING: io_uring_setup is NOT in the allow list of the output"
    echo "    This is likely a jq bug or unexpected profile shape."
    exit 1
fi

base_syscall_count=$(jq '.syscalls | length' "$TMP_BASE")
out_syscall_count=$(jq '.syscalls | length' "$OUTPUT")
echo
echo "==> Profile built successfully:"
echo "    base profile:   $base_syscall_count syscall entries"
echo "    output profile: $out_syscall_count syscall entries"
echo "    (+1 entry for the io_uring overlay)"
echo
echo "==> Use with:"
echo "    podman run --security-opt seccomp=$OUTPUT ..."
echo
echo "    Or via compose.production.yml which already references it."
