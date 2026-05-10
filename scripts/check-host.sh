#!/usr/bin/env bash
# Verify the host has every prerequisite the demos need. Prints a
# table of PASS / FAIL lines and exits non-zero if anything fails.
#
# Run this once after following §1's installation steps, and re-run
# any time you change toolchains.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/_helpers.sh
source "$REPO_ROOT/scripts/lib/_helpers.sh"

# ── Status table accumulator ─────────────────────────────────────────────
PASS=0; FAIL=0
TABLE=()

record() {
    local status="$1"; shift
    local label="$1"; shift
    local detail="$1"; shift
    local hint="${1:-}"
    if [[ "$status" == ok ]]; then
        PASS=$((PASS + 1))
        TABLE+=("$(printf '%s[ ok ]%s  %-32s  %s' "$C_GREEN" "$C_RESET" "$label" "$detail")")
    else
        FAIL=$((FAIL + 1))
        TABLE+=("$(printf '%s[fail]%s  %-32s  %s' "$C_RED" "$C_RESET" "$label" "$detail")")
        if [[ -n "$hint" ]]; then
            TABLE+=("        ↳ $hint")
        fi
    fi
}

# ── Distro & kernel ──────────────────────────────────────────────────────
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" == fedora ]]; then
        record ok "fedora baseline"  "$PRETTY_NAME"
    else
        record fail "fedora baseline" \
            "$PRETTY_NAME" \
            "Other distros may work; expect package-name differences."
    fi
fi

# Kernel >= 5.19 for io_uring multishot (demo 3); >= 6.0 for newer cgroup features.
KVER="$(uname -r)"
KMAJ="${KVER%%.*}"
KMIN="${KVER#*.}"; KMIN="${KMIN%%.*}"
if (( KMAJ > 5 )) || { (( KMAJ == 5 )) && (( KMIN >= 19 )); }; then
    record ok "kernel >= 5.19" "$KVER"
else
    record fail "kernel >= 5.19" \
        "$KVER" \
        "Demo 3 needs io_uring multishot; upgrade your kernel."
fi

# Cgroup v2
if [[ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null)" == cgroup2fs ]]; then
    record ok "cgroup v2"  "cgroup2fs"
else
    record fail "cgroup v2" \
        "not cgroup v2" \
        "Demos 2, 5, 6 need cgroup v2. Switch via systemd.unified_cgroup_hierarchy=1."
fi

# Rootless cgroup delegation
DELEGATE_PATH="/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.subtree_control"
if [[ -r "$DELEGATE_PATH" ]]; then
    DELEGATE="$(<"$DELEGATE_PATH")"
    if [[ "$DELEGATE" == *cpu* && "$DELEGATE" == *memory* && "$DELEGATE" == *cpuset* ]]; then
        record ok "rootless cgroup delegation" "$DELEGATE"
    else
        record fail "rootless cgroup delegation" \
            "${DELEGATE:-empty}" \
            "See §1 step 7 for the systemd Delegate= drop-in."
    fi
else
    record fail "rootless cgroup delegation" \
        "$DELEGATE_PATH not readable" \
        "May indicate you're not running as a regular user with a systemd user manager."
fi

# ── Container runtime ────────────────────────────────────────────────────
check_version() {
    local label="$1" cmd="$2" version_arg="$3" min_major="$4" min_minor="$5"
    local found
    if ! command -v "$cmd" >/dev/null 2>&1; then
        record fail "$label" "not installed" "sudo dnf install -y $cmd"
        return
    fi
    found="$($cmd $version_arg 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"
    if [[ -z "$found" ]]; then
        record fail "$label" "unknown version" "verify with: $cmd $version_arg"
        return
    fi
    local fmaj="${found%%.*}"
    local fmin="${found#*.}"; fmin="${fmin%%.*}"
    if (( fmaj > min_major )) || { (( fmaj == min_major )) && (( fmin >= min_minor )); }; then
        record ok "$label" "$found"
    else
        record fail "$label" "$found" "Need >= $min_major.$min_minor; upgrade $cmd."
    fi
}

check_version "podman >= 5.0"        podman          --version 5 0
check_version "cmake >= 3.25"        cmake           --version 3 25

# Things we just need present, version-irrelevant or hard to extract:
for tool in podman-compose buildah skopeo ninja jq curl bc git gh; do
    if command -v "$tool" >/dev/null 2>&1; then
        record ok "$tool" "$(command -v "$tool")"
    else
        record fail "$tool" "not installed" "sudo dnf install -y $tool"
    fi
done

# hey: not in dnf, so installed elsewhere
if command -v hey >/dev/null 2>&1; then
    record ok "hey" "$(command -v hey)"
else
    record fail "hey" "not installed" \
        "curl + install from hey-release.s3.us-east-2.amazonaws.com — see §1."
fi

# ── Toolchain ────────────────────────────────────────────────────────────
# gcc-toolset-14: enabled via /opt/rh/gcc-toolset-14/enable
GCC_TS_BIN="/opt/rh/gcc-toolset-14/root/usr/bin/g++"
if [[ -x "$GCC_TS_BIN" ]]; then
    GCC_TS_VER="$("$GCC_TS_BIN" --version | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    record ok "gcc-toolset-14" "${GCC_TS_VER:-installed}"
else
    record fail "gcc-toolset-14" \
        "$GCC_TS_BIN missing" \
        "sudo dnf install -y gcc-toolset-14"
fi

# Clang
if command -v clang >/dev/null 2>&1; then
    CLANG_VER="$(clang --version | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    CLANG_MAJ="${CLANG_VER%%.*}"
    if (( CLANG_MAJ >= 18 )); then
        record ok "clang >= 18" "$CLANG_VER"
    else
        record fail "clang >= 18" "$CLANG_VER" "sudo dnf upgrade clang"
    fi
else
    record fail "clang >= 18" "not installed" "sudo dnf install -y clang"
fi

# Conan 2.x (installed via pip)
if command -v conan >/dev/null 2>&1; then
    CONAN_VER="$(conan --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    CONAN_MAJ="${CONAN_VER%%.*}"
    if [[ "$CONAN_MAJ" == "2" ]]; then
        record ok "conan 2.x" "$CONAN_VER"
    else
        record fail "conan 2.x" \
            "$CONAN_VER (need 2.x)" \
            "pip install --user 'conan>=2.0,<3.0' && rehash"
    fi
else
    record fail "conan 2.x" "not installed" \
        "pip install --user 'conan>=2.0,<3.0'"
fi

# ── Quality / debugging ──────────────────────────────────────────────────
for pair in cppcheck:cppcheck abidiff:libabigail bpftrace:bpftrace gdb:gdb; do
    cmd="${pair%%:*}"; pkg="${pair##*:}"
    if command -v "$cmd" >/dev/null 2>&1; then
        ver="$($cmd --version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"
        record ok "$cmd" "${ver:-installed}"
    else
        record fail "$cmd" "not installed" "sudo dnf install -y $pkg"
    fi
done

# ── Network reachability ─────────────────────────────────────────────────
check_url() {
    local label="$1" url="$2"
    if curl -fsS --max-time 5 --head "$url" >/dev/null 2>&1; then
        record ok "$label" "reachable"
    else
        record fail "$label" "unreachable" "Check network/firewall."
    fi
}
check_url "registry.access.redhat.com" "https://registry.access.redhat.com/v2/"
check_url "docker.io"                  "https://registry-1.docker.io/v2/"

# ── Print the table ──────────────────────────────────────────────────────
echo
printf '%s\n' "${TABLE[@]}"
echo
TOTAL=$((PASS + FAIL))
if (( FAIL == 0 )); then
    log_ok "All ${TOTAL} checks passed."
    exit 0
else
    log_err "${FAIL} of ${TOTAL} checks failed. See messages above."
    exit 1
fi
