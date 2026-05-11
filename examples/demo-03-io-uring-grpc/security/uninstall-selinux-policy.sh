#!/usr/bin/env bash
# Uninstall the demo03_iouring SELinux policy module.
#
# Reverses install-selinux-policy.sh. After running this, container_t
# loses the io_uring class permissions and io_uring_setup() from a
# container will again be denied with -EACCES.
#
# Requires root (semodule -r is privileged).

set -euo pipefail

MODULE_NAME="demo03_iouring"
SECURITY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $EUID -ne 0 ]]; then
    echo "==> ERROR: must run as root (semodule -r is privileged)"
    echo "    Rerun with: sudo $0"
    exit 1
fi

if ! semodule -l | grep -q "^$MODULE_NAME"; then
    echo "==> $MODULE_NAME is not currently installed; nothing to do."
    exit 0
fi

echo "==> Removing $MODULE_NAME policy module..."
semodule -r "$MODULE_NAME"

echo "==> Cleaning compiled artifacts..."
rm -f "$SECURITY_DIR/$MODULE_NAME.pp" \
      "$SECURITY_DIR/$MODULE_NAME.mod" \
      "$SECURITY_DIR/$MODULE_NAME.mod.fc" \
      "$SECURITY_DIR/tmp" 2>/dev/null || true
rm -rf "$SECURITY_DIR/tmp/" 2>/dev/null || true

echo "==> $MODULE_NAME removed."
echo
echo "After this, container_t cannot use io_uring. To run the production"
echo "compose (which uses demo03_iouring_t), reinstall with:"
echo "  sudo ./security/install-selinux-policy.sh"
echo
echo "The tutorial compose (compose.yml with label=disable) still works"
echo "without this module."
