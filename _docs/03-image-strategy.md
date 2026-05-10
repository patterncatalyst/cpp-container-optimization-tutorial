---
title: "Container Strategy: UBI, ubi-micro, multi-stage"
order: 3
description: When to choose between UBI's runtime tiers (ubi, ubi-minimal, ubi-micro), and how multi-stage builds cut image size without sacrificing the toolchain you needed at compile time.
duration: 12 minutes
---

## Learning objectives

By the end of this section you can:

- Explain why `ubi-micro` produces a small image and what its trade-offs are
  you (no shell, no `ldd`, no `strace` to attach).
- Explain why a UBI-minimal base is bigger and what it gives you
  (consistent libc, security update channel, debug stories).
- Write a multi-stage `Containerfile` that uses one base for
  building and a different one for running, with no toolchain in
  the runtime image.
- Predict which AVX-512 binaries will fault on which hosts.

## Diagram

{% include excalidraw.html name="03-image-strategy-multistage" caption="UBI runtime tiers (ubi, ubi-minimal, ubi-micro) trade-off matrix" %}

## Planned content

- The decision tree: when ubi-micro is right (small footprint, glibc-
  linked binary, no syscalls outside libc), when UBI-minimal is
  right (default), when distroless or Wolfi might be considered
  (out of scope for this tutorial).
- Multi-stage builder pattern: a builder image with the full
  toolchain, copy the artefact into a runtime image with neither
  the compiler nor `apt`/`dnf`.
- Layer caching: order your `COPY` and `RUN` lines so dependency
  installs don't re-run when source changes.
- ABI labels: writing the libc, libstdc++, march/mtune, and PGO
  status into the image as `LABEL` lines so anyone running it
  later knows what they have.

## Demo

[`examples/demo-01-image-strategy/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/demo-01-image-strategy)
builds the same C++ service three ways — UBI-minimal multi-stage,
ubi-micro with static libstdc++, and a deliberately-naive single-
stage — and compares image sizes, build times, and what's
possible to debug inside each.

## For deeper coverage

- Andrist & Sehr, *C++ High Performance*, ch. 3 (build pipeline)
- Iglberger, *C++ Software Design*, ch. 1 (the cost of decisions
  made early)

## What's next

§4 turns the toolchain knob: you've decided where the binary will
run; now decide what it gets compiled into.
