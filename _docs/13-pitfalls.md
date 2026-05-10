---
title: "Pitfalls"
order: 13
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

{% include excalidraw.html name="13-pitfalls-avx512-mismatch" caption="The AVX-512 mismatch trap: build host has it, runtime host doesn't, kernel sends SIGILL" %}

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
