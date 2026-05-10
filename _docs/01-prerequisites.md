---
title: "Prerequisites"
order: 1
description: Fedora 44, Podman 5.x rootless, the C++ toolchain (GCC 14 / Clang 18, Conan 2, CMake, Ninja), supporting tools (hey, jq, libabigail, bpftrace), and the host-check script that confirms everything is wired correctly before you touch the demos.
duration: "30–45 minute read; 15–25 minutes to install"
---

This section is the gate. None of the demos will run cleanly if your
host isn't set up correctly, and the failure modes when something is
missing are the kind that swallow an hour of debugging time before
you realize the problem is your environment.

The good news: **on a fresh Fedora 44 install, the entire prerequisite
list is one `dnf install` and one `gh` configuration step.** This
section walks you through it deliberately, says what each piece is
for, and ends with a host-check script that verifies everything works
before you commit to running a demo.

## Diagram

{% include excalidraw.html name="01-prerequisites-toolchain"
   caption="What gets installed where: Fedora packages, gcc-toolset-14, Conan caches, Podman storage, and what reaches across each boundary." %}

## Why Fedora 44

Three reasons we picked it as the baseline, in decreasing order of
importance:

1. **Kernel ≥ 6.8 with `io_uring` multishot accept and recv enabled
   by default.** Demo 3 uses these primitives directly; older kernels
   either don't have them or require kernel module loading we'd
   rather not document.
2. **Podman 5.x in the default repo, rootless out of the box, with
   cgroups v2 delegation on by default.** Demos 2, 5, and 6 all rely
   on rootless cgroup writability for `memory.high`, `cpu.weight`,
   and `cpuset.cpus`. Some hardened distros disable this and require
   a manual `systemctl --user` setup.
3. **`gcc-toolset-14` and `clang` 18 are both available and current.**
   We use both — GCC for the UBI-based demos (matches what Red Hat
   ships in `gcc-toolset-14`), Clang for the PGO and static-musl
   builds (better profile-data tooling, cleaner `-stdlib=libc++`).

> **No subscription needed.** Every UBI 9 image we use comes from
> `registry.access.redhat.com/ubi9/...` and is freely pullable and
> redistributable. You don't need a Red Hat subscription for any
> of the demos. Subscription-only images like `ubi9/toolbox` are not
> in use.

Other distros that should work with minor adjustments:

| Distro                | Verdict                                                                                |
|-----------------------|----------------------------------------------------------------------------------------|
| RHEL 9 / CentOS Stream 9 | Most demos work. Kernel may lag on `io_uring` multishot — check `uname -r` ≥ 5.19. |
| Ubuntu 24.04 LTS      | Most demos work; package names differ throughout. The host-check script flags these.    |
| Arch / openSUSE Tumbleweed | Should work. We don't test against them, but kernel and toolchain are recent enough.|
| **macOS (any)**       | Container parts work via `podman machine`. **Kernel-feature demos (2, 3, 5) won't.**    |
| **WSL2 (any)**        | Container parts work. Cgroup v2 delegation is unreliable; demo 5 in particular flakes. |

If you're on a distro not listed, the host-check script at the bottom
of this section will tell you what's missing.

## What you need installed

The full list, with what each piece is for. Installation commands come
right after.

### Container runtime and supporting tools

- **`podman`** (≥ 5.0) — the OCI runtime. Rootless by default.
- **`podman-compose`** — for the multi-service stacks in demos 3 and 4.
- **`buildah`** — sometimes needed when `podman build` hits its
  limits; we don't use it directly but the demos shell out to it
  in one place.
- **`skopeo`** — only needed if you want to inspect remote image
  manifests. Not strictly required, but very useful.

### C++ toolchain

- **`gcc-c++`** — Fedora 44 ships GCC 14.x as the default `g++`,
  which has full C++23 support; that's all you need on the host.
  (UBI-based container builds use `gcc-toolset-14` separately, but
  that's installed *inside* the container Image, not on your host.)
- **`clang`, `clang-tools-extra`, `lld`, `llvm`** — the gating Clang.
  Used for PGO instrumentation, the static-musl variant, and
  `clang-tidy` in demo 6.
- **`cmake`** (≥ 3.25) — needed for CMake presets v6.
- **`ninja-build`** — the build driver of choice; faster and cleaner
  than `make` for our build sizes.
- **`python3-pip`** — for installing Conan 2.
- **`conan`** (≥ 2.0, ≤ 3.0) — installed via pip, not dnf.

### Quality / debugging tools

- **`gdb`, `gdb-gdbserver`** — for the demo 6 debug sidecar.
- **`cppcheck`** — first-pass static analysis.
- **`libabigail`** — provides `abidiff` for the demo 6 ABI check.
- **`bpftrace`, `bcc-tools`** — for the §9 profiling layer.
- **`perf`** (`linux-tools` on some distros) — CPU sampling.

### Load generation and convenience

- **`hey`** — HTTP load generator. Not in dnf; we install via Go or
  a binary download.
- **`ghz`** — gRPC load generator. Optional; demo 3 falls back to
  `hey` if `ghz` isn't on PATH.
- **`jq`** — JSON parsing in shell scripts. Universal.
- **`curl`** — every script uses it.
- **`bc`** — needed by one helper for byte-formatting.

## Installation, one command at a time

### 1. Update the system

```bash
sudo dnf update -y
```

### 2. Install everything via dnf in one batch

```bash
sudo dnf install -y \
    podman podman-compose buildah skopeo \
    gcc-c++ \
    clang clang-tools-extra lld llvm \
    cmake ninja-build \
    python3-pip golang \
    gdb gdb-gdbserver \
    cppcheck \
    libabigail \
    bpftrace bcc-tools \
    perf \
    jq curl bc \
    git
```

This pulls roughly 800 MB of packages, mostly toolchain. Coffee break.

`golang` is included because we use `go install` to fetch `hey` and
(optionally) `ghz` — see step 4 below. If you already have a Go
toolchain, the `dnf install` will no-op on it.

### 3. Install Conan 2 via pip

We pin Conan to the 2.x line because Conan 1 and Conan 2 have
incompatible CLIs and our lockfiles target 2.x:

```bash
pip install --user 'conan>=2.0,<3.0'
```

Verify:

```bash
~/.local/bin/conan --version    # should print "Conan version 2.x.y"
```

If `~/.local/bin` isn't on your `PATH`, add it:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

Initialize a default Conan profile so the demos have something to
build against:

```bash
conan profile detect --force
```

This writes `~/.conan2/profiles/default` with sensible defaults
inferred from your toolchain. You can edit it later; for now the
detected profile is fine.

### 4. Install `hey`

`hey` is a small Go program; the canonical install is via `go
install`. The previous AWS S3 binary distribution is no longer
publicly readable (returns HTTP 403), so don't follow tutorials
that point at it.

```bash
go install github.com/rakyll/hey@latest
```

Make sure Go's bin directory is on your `PATH`:

```bash
# bash:
echo 'export PATH="$(go env GOPATH)/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc

# zsh:
echo 'export PATH="$(go env GOPATH)/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc

# verify
hash -r
which hey                  # → /home/<you>/go/bin/hey
hey -h | head -3           # → "Usage: hey [options...] <url>"
```

If `go install` is slow or unreachable, the from-source build is
the fallback:

```bash
mkdir -p /tmp/hey-build && cd /tmp/hey-build
git clone --depth 1 https://github.com/rakyll/hey.git .
go build -o hey .
sudo install -m 0755 hey /usr/local/bin/hey
cd && rm -rf /tmp/hey-build
hey -h | head -3
```

### 5. (Optional) Install `ghz` for gRPC load testing

Demo 3 uses `ghz` if it's available and skips the gRPC bench
otherwise. If you want full demo 3 output:

```bash
go install github.com/bojand/ghz/cmd/ghz@latest
```

### 6. Enable `lingering` if running rootless on a server

If your Fedora 44 host is a server you don't sit at a console for,
podman's rootless cgroup delegation only works while you're logged
in. Enable lingering so it works whether or not you're at a TTY:

```bash
loginctl enable-linger "$USER"
```

### 7. Verify rootless cgroup v2 delegation

The crucial check that distinguishes "this will work" from "you'll
debug obscure errors for two hours":

```bash
cat /sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.subtree_control
```

You should see `cpu io memory pids` (or a superset). If you see
nothing, or only some of those, the delegation isn't enabled.
Fix on Fedora 44:

```bash
sudo mkdir -p /etc/systemd/system/user@.service.d
cat <<'EOF' | sudo tee /etc/systemd/system/user@.service.d/delegate.conf
[Service]
Delegate=cpu cpuset io memory pids
EOF
sudo systemctl daemon-reexec
# log out and back in, or reboot for the user manager to pick this up
```

Re-run the `cat` command to verify.

## Verify your kernel has what the demos need

Demo 3's `io_uring` work uses `IORING_OP_RECV_MULTISHOT`, which landed
in kernel 5.19. Demo 5's `cpuset.cpus` writability needs cgroup v2.
Check both:

```bash
echo "Kernel:  $(uname -r)"
echo "Cgroups: $(stat -fc %T /sys/fs/cgroup)"   # should print "cgroup2fs"
```

The kernel version should be ≥ 5.19; on Fedora 44 you'll see
something like `6.8.x` or `6.10.x`, well past the requirement.

## Set your `gh` (GitHub CLI) authentication

Several demos use the `gh` CLI for repo and Pages operations, and
the deployment workflow does too:

```bash
sudo dnf install -y gh
gh auth login                # follow the interactive prompts
gh auth status               # confirm scopes include repo, workflow
```

If your token doesn't have the `workflow` scope, add it now —
the deploy workflow won't push to `gh-pages` without it:

```bash
gh auth refresh -h github.com -s repo,workflow,admin:repo_hook
```

## Configure registry access

The UBI-based images pull from `registry.access.redhat.com`. Anonymous
pull works for `ubi9/ubi` and `ubi9/ubi-minimal`, but if you hit a
rate limit (you might, on a cold network), authenticate:

```bash
podman login registry.redhat.io
# enter the credentials from access.redhat.com → Service Accounts
```

The Grafana / Prometheus / Mimir / Tempo / Loki images come from
Docker Hub. Anonymous pull works there too, but you may want to
authenticate to bypass anonymous rate limits:

```bash
podman login docker.io
```

### When `docker.io` is unreachable

A minority of corporate networks (and a few home setups with
ad-blocking DNS) block `docker.io` outright. The host-check script
will flag this with a `[fail] docker.io (hub) unreachable` line.

By project policy (see
[`CONTRIBUTING.md`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/blob/main/CONTRIBUTING.md#container-image-policy))
all *our* container images come from Red Hat UBI, and Prometheus
routes through Quay (`quay.io/prometheus/prometheus`). Demos 1, 2,
3, 5, and 6 will run fine without Docker Hub reachability.

The one image affected is `docker.io/grafana/otel-lgtm`, which our
observability stack uses for demo 4. **If Docker Hub is blocked,
demo 4 won't run** unless you mirror the image.

The `podman save | podman load` air-gap workaround:

```bash
# On a reachable jump host:
podman pull docker.io/grafana/otel-lgtm:0.8.1
podman save docker.io/grafana/otel-lgtm:0.8.1 -o lgtm.tar

# Transfer lgtm.tar to your build host (scp, USB, whatever), then:
podman load -i lgtm.tar
```

If a mirror isn't viable, demo 4 simply won't run — but everything
else will.

## Clone this repo

```bash
mkdir -p ~/Dev
cd ~/Dev
git clone https://github.com/{{ site.github_username }}/{{ site.github_repo }}.git
cd {{ site.github_repo }}
```

The repo lays out as:

```
{{ site.github_repo }}/
├── _docs/                     # this tutorial's prose
├── _plans/                    # reconciliation plan
├── examples/                  # six runnable demos
│   ├── demo-01-image-strategy/
│   ├── demo-02-memory-and-stl/
│   └── ...
├── observability/             # Grafana/Prom/Mimir/Tempo/Loki stack
├── scripts/                   # helpers + per-demo test scripts
└── assets/diagrams/           # paired SVG + .excalidraw files
```

## Run the host-check script

A short script that exercises every prerequisite and prints a clear
PASS / FAIL line for each. **Run this before you touch any demo.**

```bash
./scripts/check-host.sh
```

Expected output on a correctly-set-up Fedora 44 box:

```
[ ok ]  fedora baseline                  Fedora Linux 44 (Workstation Edition)
[ ok ]  kernel >= 5.19                   6.10.7-200.fc44.x86_64
[ ok ]  cgroup v2                        cgroup2fs
[ ok ]  rootless cgroup delegation       cpu io memory pids
[ ok ]  podman >= 5.0                    5.2.1
[ ok ]  cmake >= 3.25                    3.28.2
[ ok ]  podman-compose                   /usr/bin/podman-compose
[ ok ]  buildah                          /usr/bin/buildah
[ ok ]  skopeo                           /usr/bin/skopeo
[ ok ]  ninja                            /usr/bin/ninja
[ ok ]  jq                               /usr/bin/jq
[ ok ]  curl                             /usr/bin/curl
[ ok ]  bc                               /usr/bin/bc
[ ok ]  git                              /usr/bin/git
[ ok ]  gh                               /usr/bin/gh
[ ok ]  hey                              /home/<you>/go/bin/hey
[ ok ]  g++ >= 14                        14.2.1
[ ok ]  clang >= 18                      18.1.6
[ ok ]  conan 2.x                        2.5.0
[ ok ]  cppcheck                         2.13.0
[ ok ]  abidiff                          2.4.0
[ ok ]  bpftrace                         0.21.0
[ ok ]  gdb                              14.2
[ ok ]  registry.access.redhat.com       reachable
[ ok ]  quay.io                          reachable
[ ok ]  docker.io (hub)                  reachable

All 26 checks passed.
```

If any line says `FAIL`, scroll up — the script prints the exact
remediation command for each failure.

> **Note:** the host-check script is added in this section's commit;
> if you cloned an older revision and the file isn't there yet, the
> bash version is short enough to inline below. We're keeping it in
> `scripts/` so it stays runnable outside the tutorial flow.

## Pre-pull and verify-stacks

Two convenience scripts at the repo root that save you debugging time:

```bash
./pre-pull.sh                 # pulls every image referenced by the project
./verify-stacks.sh            # smoke-tests every podman-compose stack
./verify-stacks.sh --quick    # skip the observability stack (slow)
```

**Run `./pre-pull.sh` once after first clone** — it warms the local
image cache so subsequent demo runs start in seconds instead of
minutes. Especially important if you'll be presenting; you want
the network surprises to happen now, not in front of an audience.

**Run `./verify-stacks.sh` whenever you think something might have
broken** — after a system update, after pulling fresh images, or
before walking on stage. Each stack passes if it can `up`, respond
to a health endpoint, and `down` cleanly.

If any pull fails, the message will say which image and why — usually
either Docker Hub being throttled (re-run later) or a network /
firewall blocking the registry (see "When `docker.io` is unreachable"
above for the workaround).

## Common things that go wrong

A short list, with fixes:

**`podman build` fails with `error creating overlay mount: permission denied`.**
Your `~/.local/share/containers/storage` is on a filesystem (often
NFS) that doesn't support overlayfs. Move storage to a local disk:

```bash
mkdir -p /var/tmp/containers-$(id -u)
podman system reset --force
cat <<EOF > ~/.config/containers/storage.conf
[storage]
driver = "overlay"
graphroot = "/var/tmp/containers-$(id -u)"
EOF
```

**`hey` reports `Get "...": dial tcp: lookup ...: i/o timeout`.**
Your container is listening on the wrong interface. Demos pin
listeners to `0.0.0.0` and bind via `-p 127.0.0.1:PORT:8080`; if
yours doesn't, you'll see this. The demo source pins to `0.0.0.0`
intentionally; if you've modified it, check your edit.

**`cmake --preset release` says "preset not found".**
You're on CMake < 3.25. Our presets use schema v6, which requires
3.25 or newer. Check `cmake --version` and upgrade.

**`abidiff` not found despite `dnf install libabigail`.**
On Fedora 44 the binary is in `/usr/bin/abidiff`; if your `PATH`
is unusual, point at it explicitly. The demo's `run-clang-tidy`
wrapper handles this; if it doesn't, file an issue.

**Rootless cgroup write returns `Permission denied`.**
Re-run step 7 above — delegation didn't stick. After re-applying,
**you must log out and back in** (or reboot) for the user manager
to pick it up.

## What's next

You have a working environment. Open
[§2 — Introduction & mental model](../02-introduction/) to read the
**why** of this tutorial: what about containers actually changes
how C++ performance work plays out, and the four-layer model that
frames the rest of the sections.

If you'd rather skip ahead and confirm the toolchain works by
running something concrete first, jump to
[§3 — Container strategy](../03-image-strategy/) and run Demo 1.
You can come back for §2 once the cmake/podman pipeline has stopped
feeling like a black box.
