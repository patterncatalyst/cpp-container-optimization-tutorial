# Demo 03 — Container Security Posture

This document is the answer to: **"would the tutorial compose pass a
security audit?"**

The short answer is **no, the tutorial `compose.yml` would not pass
a security audit.** It uses `seccomp=unconfined` and `label=disable`
for simplicity. That works fine for a demo on a developer laptop;
it would not be acceptable for production deployment.

This directory contains a parallel **`compose.production.yml`** and
the supporting seccomp profile and SELinux policy module that *would*
pass a security audit, demonstrating how to enable io_uring in a
container while preserving the rest of the default container security
posture.

The C++ source in `src/main.cpp` does not change between the two
deployments — the demo binary doesn't care which compose launched
it. Only the surrounding security configuration changes.

## What the tutorial setup actually removes

The `compose.yml` for the easy path applies two `security_opt`
directives:

```yaml
security_opt:
  - "seccomp=unconfined"
  - "label=disable"
```

These are two of the four primary container isolation layers
podman/docker provide. Disabling both is a real reduction in security
posture, not a paperwork formality.

### `seccomp=unconfined` removes the syscall filter

Podman's default seccomp profile blocks roughly 50+ syscalls that
have either been historical CVE sources or are unnecessary for typical
container workloads. Examples of what `unconfined` re-exposes:

| Syscall | Why it's filtered by default |
|---|---|
| `kexec_load`, `kexec_file_load` | Load and execute a new kernel |
| `reboot` | Reboot the host (requires capabilities too, but defense in depth) |
| `mount`, `umount2` | Manipulate the mount namespace |
| `ptrace` | Attach to other processes |
| `userfaultfd` | Userspace page-fault handling — classic kernel-exploit primitive |
| `bpf` | Load eBPF programs (very powerful; major sandbox-escape vector) |
| `io_uring_setup/enter/register` | The io_uring family — what we actually wanted |

In normal operation a process inside the container doesn't call these.
The point of seccomp is to stop **an attacker who has already
compromised the process** from using these syscalls as escape
primitives. Real CVEs that the default profile would have blocked:

- **CVE-2022-0185** — filesystem context use-after-free, exploited via `fsopen`
- **CVE-2022-29581** — io_uring use-after-free (which is *exactly* why io_uring is filtered)
- **CVE-2023-32233** — netfilter use-after-free, exploited via `nft` syscalls

### `label=disable` removes SELinux MAC enforcement

By default a container runs as the SELinux type `container_t`, with
two unique MCS categories (e.g. `s0:c123,c456`) that make every
container's files mutually inaccessible — even if a process escaped
its user namespace. `label=disable` runs the container as `spc_t`
(super-privileged container) instead, which is the same SELinux type
used by host-management tools.

The container's processes can then access any file labeled for normal
container interaction, and SELinux stops being a useful boundary
against a compromised container.

**CVE-2019-5736** (the runc breakout) was contained on
SELinux-enforcing systems specifically because `container_t` couldn't
write to the runc binary on the host. On `label=disable`, it could
have.

### What the tutorial setup is **not**

The combination is **not** equivalent to `--privileged`, because:
- User namespaces stay active (rootless podman maps container root to your host user)
- Cgroups stay active
- Network, PID, and mount namespaces stay active
- Capabilities aren't broadened

But it's a meaningful step down from podman's default posture and
shouldn't be deployed beyond a developer laptop.

## What the production setup does instead

The `compose.production.yml` shows the audit-grade alternative:

```yaml
security_opt:
  - "seccomp=./security/seccomp-iouring.json"
  - "label=type:demo03_iouring_t"
cap_drop:
  - ALL
read_only: true
tmpfs:
  - /tmp
mem_limit: 512m
pids_limit: 200
```

Plus a custom **seccomp profile** that's docker's default + exactly
three additional allowed syscalls (`io_uring_setup`, `io_uring_enter`,
`io_uring_register`), and a custom **SELinux policy module** that
grants the new `demo03_iouring_t` type the `io_uring` permission
class. Everything else stays restricted.

Each layer protects against a different threat model:

| Hardening | Threat model |
|---|---|
| Custom seccomp profile (not unconfined) | Compromised process trying to escape via syscalls other than what the app legitimately uses |
| Custom SELinux type (not label=disable) | Compromised process trying to access host files via paths beyond what the app legitimately reads/writes |
| `cap_drop: ALL` | Compromised process trying to use elevated privileges (capabilities aren't actually needed for this app's workload) |
| `read_only: true` + tmpfs for /tmp | Compromised process trying to write modified binaries or persistence files |
| `mem_limit`, `pids_limit` | Compromised process trying to DoS the host |

## How to use the production setup

There's a one-time setup of the host policy, then `podman compose`
works normally.

### 1. Generate the seccomp profile (one time)

```bash
./security/build-seccomp-profile.sh
```

This runs against your local podman/containers tooling to extract
the current default seccomp profile and overlays the three io_uring
syscalls. The result lands at `security/seccomp-iouring.json`. The
script is idempotent — re-run any time your podman updates to refresh
against the new default profile.

A pre-built version of the profile is committed to the repo as a
reference snapshot (generated against podman 5.8 / Fedora 44 in
May 2026). The build script regenerates against your local install.

### 2. Install the SELinux policy module (one time, needs root)

```bash
sudo ./security/install-selinux-policy.sh
```

This compiles `demo03_iouring.te` into a policy package and installs
it with `semodule -i`. After this:
- A new SELinux type `demo03_iouring_t` exists
- It's a domain transition from `container_t`
- It has the `io_uring:create` permission added; nothing else changes

You can verify with:

```bash
sudo semodule -l | grep demo03_iouring     # should print the module
sudo seinfo -t | grep demo03                # should show demo03_iouring_t
```

### 3. Run the production compose

```bash
./demo.sh --production
```

(or equivalently `podman compose -f compose.production.yml -f ../../observability/compose.yml up -d --build`)

The same demo.sh load phases run; only the container security
configuration differs. The tcp-loadgen numbers should be within
~5% of the tutorial setup — security overhead is real but small for
this workload.

### Verifying that security is actually applied

After bring-up, run from the host:

```bash
# Confirm container is running with the demo03_iouring_t SELinux type
podman inspect demo03-svc --format '{{.HostConfig.SecurityOpt}}'

# Confirm seccomp profile is loaded (not unconfined)
podman inspect demo03-svc --format '{{.SeccompProfilePath}}'

# Confirm capabilities are dropped
podman inspect demo03-svc --format '{{.HostConfig.CapAdd}} / {{.HostConfig.CapDrop}}'

# Verify io_uring works WITHOUT the bypass flags
podman logs demo03-svc | grep iouring
# should show "[iouring] listening on :9000 (direct liburing)"
# NOT "[iouring] io_uring_queue_init failed: Permission denied"
```

If io_uring fails to initialize after the production setup, the
SELinux module didn't install correctly (most common cause) or the
seccomp profile didn't pick up the overlay (second most common).
The `audit2allow` workflow on the host audit log will show which
permission is missing:

```bash
sudo ausearch -m AVC -ts recent | audit2allow -M demo03_iouring_extra
# review the generated .te file before installing
sudo semodule -i demo03_iouring_extra.pp
```

## Production gaps the demo doesn't cover

Even the production compose isn't audit-complete. Real production
hardening also includes:

- **Non-root user inside the container** — our container still runs
  as UID 0 (rootless-mapped). Add `user: 1000:1000` to compose and
  add the user to the Containerfile.
- **Image signing** — sign the container image (`cosign sign`) and
  enforce signature verification at runtime (`podman pull --signature-policy`).
- **Network policy** — the `tutorial-obs` network is unrestricted
  inside the compose. Production would use a NetworkPolicy (k8s) or
  equivalent to restrict who can talk to demo-03-svc.
- **Secrets management** — we don't have secrets here, but if we
  did, they'd come from a vault, not environment variables.
- **Observability of security events** — falco, auditd, eBPF-based
  monitoring of syscall patterns.
- **Runtime image scanning** — trivy/grype/snyk against the built
  image, gating CI on critical CVEs.

The tutorial scopes are deliberately narrower: demonstrate that the
specific seccomp + SELinux layers we relaxed *can* be selectively
re-enabled rather than wholesale bypassed.

## Why the tutorial default isn't the production default

The tutorial uses `seccomp=unconfined` and `label=disable` rather
than the production setup because:

1. **The production setup requires root on the host** (to install the
   SELinux module). A tutorial that demos io_uring shouldn't require
   sudo to run.
2. **The production setup requires `selinux-policy-devel`** to compile
   the policy. Adds a build dependency the reader may not want.
3. **The pedagogy is clearer with the bypass shown first**: here's
   the cheap path, here's why it's wrong, here's the right path.

The structure mirrors how production hardening actually happens: you
get something working with relaxed security, identify exactly which
restrictions need to relax, and then craft a minimal exception
instead of the blanket bypass. Pretending the right answer was
obvious from the start would be educational malpractice.

## §15 prose cross-reference

The container security topic is covered in detail in **§15 Common
Pitfalls** of the tutorial site, including:

- The EPERM-vs-EACCES debugging rubric
- Why error codes encode the security layer that denied you
- The four-layer container security model (DAC + capabilities +
  seccomp + MAC) and how to debug across them
- Specific production patterns for io_uring, eBPF, and other
  syscalls commonly needed by performance-sensitive C++ workloads

This README is the demo-03-specific worked example for that section.
