---
title: "Pitfalls"
order: 14
description: AVX-512 mismatches, abstraction overhead that doesn't show in the type system, and why your container build takes seven minutes when the bare-metal build takes thirty seconds.
duration: 10 minutes
---

## Learning objectives

By the end of this section you can:

- Explain why a binary built with `-march=native` on the build
  farm SIGILLs on a smaller production host, and how to avoid
  it.
- Identify abstraction-induced overhead (`std::function` on a hot
  loop, `std::shared_ptr` refcount churn, virtual dispatch
  hidden behind a "polymorphic" interface) by reading flame
  graphs.
- Diagnose why a container build is much slower than a bare-
  metal build: layer cache invalidation, missing build-cache
  mounts, network-pulled dependencies on every build.

## Diagram

{% include excalidraw.html name="14-pitfalls-avx512-mismatch" caption="The AVX-512 mismatch trap: build host has it, runtime host doesn't, kernel sends SIGILL" %}

## Planned content

- AVX-512 / `-march=native` mismatch:
  - `-march=native` bakes the build host's instruction-set
    extensions into the binary
  - Production hosts may be older / different generation
  - The kernel responds with `SIGILL` on the unsupported
    instruction; demo intentionally produces this
  - Fixes: `-march=x86-64-v3` (AVX2 baseline) or
    `-march=x86-64-v4` (AVX-512 baseline); function multi-
    versioning with `__attribute__((target_clones(...)))`
- Silent abstraction overhead:
  - `std::function`: type erasure costs an indirect call and
    a heap allocation if the captured state exceeds SBO
  - `std::shared_ptr` refcount: atomic op per copy/destroy
  - Virtual dispatch on a hot path
  - Three small case studies; each shows up in a flame graph
    after we know to look.
- Container build slowness:
  - Layer cache invalidation: source change touches a layer
    that ran `dnf install`, which now reruns
  - Missing `RUN --mount=type=cache,target=/root/.cache/...`
    for Conan, ccache, etc.
  - Pulling dependencies on every build instead of layering
    them
  - Solutions: lockfile-driven dependency layer, ccache mount,
    BuildKit-style cache mounts (Podman supports these).
- Container security layers and the EPERM/EACCES rubric:
  - When a syscall fails inside a container with a permission
    error, *which error code you get tells you which layer
    denied you*. This matters because the fix is layer-specific;
    blindly bypassing one layer when a different layer is the
    actual denier wastes time (or worse, opens the wrong
    security hole).
  - The four primary layers, what they return on deny, and
    what relaxes them:

    | Layer | Returns | Relax option |
    |---|---|---|
    | Capabilities (DAC) | EPERM (1) | `cap_add: ...` for the specific capability |
    | seccomp | EPERM (1) | custom profile that allows the specific syscalls |
    | SELinux / AppArmor (MAC) | EACCES (13) | custom policy module for the specific class |
    | `kernel.io_uring_disabled` sysctl | EPERM (1) | host-side sysctl change + io_uring_group membership |

  - The `EPERM` ambiguity (three of the four layers return it)
    means EPERM debugging is "check each one in turn." But
    `EACCES` is unambiguous: SELinux or AppArmor is denying you.
    On Fedora/RHEL with SELinux enforcing, that means the
    container_t policy doesn't permit the operation.
  - Concrete worked example: demo-03's io_uring loop initially
    failed with EPERM (seccomp blocking io_uring_setup). After
    `seccomp=unconfined` it failed with a *different* errno —
    EACCES — proving SELinux was a separate gate. Both had to
    be addressed. See demo-03's `security/README.md` and
    `compose.production.yml` for the audit-grade alternative
    that surgically opens each layer for io_uring rather than
    bypassing them wholesale.
  - The general principle for production: **don't blanket-
    disable a security layer to make one feature work**. Find
    the specific permission, capability, or syscall the feature
    needs and grant exactly that. The rest of the layer's
    enforcement stays in place; an attacker who later
    compromises the process still hits the boundaries that
    weren't touched.
- Tutorial-default security vs production security:
  - The tutorial compose files use `seccomp=unconfined` and
    `label=disable` for io_uring because the alternative
    (custom seccomp profile + custom SELinux module + sudo to
    install) is a heavy first-run hurdle. This is a deliberate
    pedagogical choice.
  - The pitfall: it's easy to copy the tutorial compose pattern
    into a service that's about to deploy somewhere real. *Don't*.
  - Demo-03 ships both the tutorial compose and a parallel
    `compose.production.yml` that demonstrates the production-
    grade alternative. The latter passes a security audit; the
    former does not. The structure mirrors how production
    hardening actually happens: get something working with
    relaxed security, identify exactly which restrictions need
    to relax, craft a minimal exception, then deploy.

## Demo

This section is recap, not a new demo. Each pitfall is
illustrated with a snippet that already runs as part of the
demo it relates to; the section table walks through which demo
shows which pitfall.

## For deeper coverage

- Andrist & Sehr, *C++ High Performance*, ch. 6 (CPU and
  micro-architecture awareness)
- Iglberger, *C++ Software Design*, ch. 4 and 9 (the abstraction
  tax)

## What's next

§14 closes the loop and points at the books and resources you'll
want once you've finished this tutorial.
