---
title: Prerequisites
order: 1
description: The hardware, the host, the toolchain, and the assumptions you need to work through this tutorial.
duration: 10 minutes
---

## What this section does

Gets your machine into a state where every command in the rest of
the tutorial just works. It will not be exhaustive — Linux
configuration is its own art — but it will be enough.

## Hardware assumptions

- **Architecture:** x86_64 is the demo baseline. The §13 AVX-512
  pitfall demo specifically depends on x86 instruction sets.
  AArch64 mostly works for the language sections; the I/O and
  isolation demos assume x86.
- **Cores:** ≥ 4 for any demo; ≥ 8 makes the §10 noisy-neighbor
  demo more illustrative.
- **Memory:** ≥ 8 GB is enough.
- **Kernel:** ≥ 6.0 for the `io_uring` features used in §7.

Confirm:

```bash
lscpu | grep -E '^(Architecture|Model name|CPU\(s\))'
free -h
uname -r
```

## Operating system

**Fedora 44** is the primary supported host. Fedora 43 is
best-effort. Other Linux distros work for most sections — anything
with cgroups v2 enabled by default and a kernel ≥ 6.0 will get you
through nine of the ten operational demos. macOS via
`podman machine` works for the language sections (3, 4, 5, 6, 13)
but does not produce useful results for cgroup, NUMA, or
`io_uring` demos.

```bash
cat /etc/fedora-release
```

## Software you need

Install the C++ side:

```bash
sudo dnf install -y \
  gcc gcc-c++ \
  clang clang-tools-extra \
  cmake ninja-build \
  cppcheck \
  perf \
  bcc-tools bpftrace \
  libabigail \
  python3-pip jq

pip install --user 'conan>=2.0,<3'
```

Install the container side:

```bash
sudo dnf install -y podman podman-compose
podman info | grep -E 'rootless|cgroupVersion|graphDriverName'
```

You want `rootless: true` and `cgroupVersion: v2`. If your
`graphDriverName` is `vfs` rather than `overlay`, demo build times
will be dramatically slower; see the
[Podman storage docs](https://docs.podman.io/en/latest/markdown/podman.1.html#storage)
for fixing it.

Install `hey` for load generation:

```bash
mkdir -p ~/.local/bin
curl -sSL -o ~/.local/bin/hey \
  https://hey-release.s3.us-east-2.amazonaws.com/hey_linux_amd64
chmod +x ~/.local/bin/hey
hey -version
```

## Subuid / subgid for rootless

Podman in rootless mode uses user-namespace mapping. If you got
Fedora installed normally these are already set up. To confirm:

```bash
grep $(whoami) /etc/subuid /etc/subgid
```

You should see two non-empty lines. If not:

```bash
sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $(whoami)
podman system migrate
```

## Assumptions about you

You can write idiomatic C++17, you've shipped at least one C++
service in production, and you've run `podman build` and
`podman run` before. The tutorial does not re-derive RAII or
explain what a layer is.

## What's next

Section 2 builds the mental model that the rest of the tutorial
hangs off. If you skim no other section, skim that one.
