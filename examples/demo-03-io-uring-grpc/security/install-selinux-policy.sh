#!/usr/bin/env bash
# Install the demo03_iouring SELinux policy module.
#
# This grants the standard `container_t` SELinux type the io_uring
# permission class needed for io_uring_setup() to succeed from
# container processes. Without it, the kernel SELinux LSM hook
# denies io_uring_setup with -EACCES — the second of the two gates
# (the first being seccomp).
#
# Requires root (semodule -i is privileged) and selinux-policy-devel
# package for the make / m4 / checkmodule toolchain.
#
# Idempotent: re-running upgrades the module if the .te file has
# changed since the last install. No effect if already at current
# version.

set -euo pipefail

SECURITY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_NAME="demo03_iouring"
TE_FILE="$SECURITY_DIR/${MODULE_NAME}.te"

# ── Preflight ─────────────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
    echo "==> ERROR: must run as root (semodule -i is privileged)"
    echo "    Rerun with: sudo $0"
    exit 1
fi

if [[ ! -f "$TE_FILE" ]]; then
    echo "==> ERROR: $TE_FILE not found"
    exit 1
fi

# Check SELinux is actually enabled
if ! command -v getenforce >/dev/null 2>&1; then
    echo "==> ERROR: getenforce not found — is SELinux installed?"
    echo "    Install with: dnf install policycoreutils"
    exit 1
fi

selinux_state=$(getenforce 2>/dev/null || echo "Unknown")
case "$selinux_state" in
    Enforcing)
        echo "==> SELinux is Enforcing — module will be effective"
        ;;
    Permissive)
        echo "==> SELinux is Permissive — module loads but won't enforce"
        echo "    Run: sudo setenforce 1   (to enforce)"
        ;;
    Disabled)
        echo "==> WARNING: SELinux is Disabled. There's no reason to install"
        echo "    this module on this system; io_uring isn't being denied by"
        echo "    SELinux because SELinux isn't running. Continuing for"
        echo "    when you re-enable SELinux later."
        ;;
    *)
        echo "==> WARNING: SELinux state is '$selinux_state' — unexpected"
        ;;
esac

# Check the policy devel toolchain
DEVEL_MAKEFILE=/usr/share/selinux/devel/Makefile
if [[ ! -f "$DEVEL_MAKEFILE" ]]; then
    echo "==> ERROR: $DEVEL_MAKEFILE not found"
    echo "    Install the SELinux policy development tools:"
    echo "      dnf install selinux-policy-devel"
    exit 1
fi

# Check the io_uring class exists in the policy (Linux 6.7+ / Fedora 39+).
# If not, the module compile will fail; pre-check gives a clearer message.
if ! seinfo -c 2>/dev/null | grep -qw io_uring; then
    echo "==> ERROR: SELinux policy on this system does not define the"
    echo "    'io_uring' class. This requires:"
    echo "      - Linux kernel 6.7+ (for the io_uring LSM class)"
    echo "      - selinux-policy 38+ (Fedora 39+, RHEL 9.4+)"
    echo "    Current kernel: $(uname -r)"
    echo "    Current selinux-policy version:"
    rpm -q selinux-policy 2>/dev/null || echo "      (not installed via rpm)"
    exit 1
fi

# ── Compile ───────────────────────────────────────────────────────────

echo "==> Compiling $MODULE_NAME.te into a policy package..."
cd "$SECURITY_DIR"
make -f "$DEVEL_MAKEFILE" "$MODULE_NAME.pp"

if [[ ! -f "$MODULE_NAME.pp" ]]; then
    echo "==> ERROR: $MODULE_NAME.pp was not produced; check make output above"
    exit 1
fi

# ── Install ───────────────────────────────────────────────────────────

echo "==> Installing $MODULE_NAME policy module..."
semodule -i "$MODULE_NAME.pp"

echo "==> Verifying installation..."
if ! semodule -l | grep -q "^$MODULE_NAME"; then
    echo "==> ERROR: $MODULE_NAME not listed by 'semodule -l'"
    exit 1
fi

echo
echo "==> $MODULE_NAME installed successfully."
echo
echo "What this added:"
echo "  - Grants container_t the io_uring class permissions:"
echo "      create, override_creds, sqpoll"
echo "  - All other container_t restrictions remain unchanged"
echo
echo "To verify the policy is active:"
echo "  sudo sesearch --allow -s container_t -t container_t -c io_uring"
echo
echo "To remove later:"
echo "  sudo ./security/uninstall-selinux-policy.sh"
echo "  (or directly: sudo semodule -r $MODULE_NAME)"
