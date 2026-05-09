---
title: "Static Analysis & Debugging in Containers"
order: 11
description: A static-analysis pipeline that catches the bugs you don't want to debug, and a debugging pattern (ephemeral gdb sidecar) for the ones that escape anyway.
duration: 12 minutes
---

## Learning objectives

By the end of this section you can:

- Run cppcheck and clang-tidy as part of a CI build inside a
  container, with a curated check set that doesn't drown the
  developer in low-signal warnings.
- Write googletest / gmock unit tests that build and run inside
  the same builder image, with no test-side toolchain leak into
  the runtime image.
- Attach `gdb` to a running C++ service in a Podman container
  using an ephemeral sidecar pattern (no `gdb` in the runtime
  image; the sidecar joins the same PID namespace).
- Use `gdbserver` for the same purpose when joining the PID
  namespace isn't possible.

## Diagram

{% include excalidraw.html name="11-debug-sidecar-pattern" caption="Ephemeral gdb sidecar attaching to a running container's PID namespace" %}

## Planned content

- The static-analysis pipeline: cppcheck for the "obvious" bugs
  (uninitialized reads, array bounds, shadowed variables);
  clang-tidy for modernisation and stylistic lint; the curated
  check set that signals without spamming.
- googletest + gmock: the build target shape, where the tests
  live, why the *test* binary should not end up in the runtime
  image.
- The ephemeral sidecar: `podman run --pid=container:<service>`
  to share the PID namespace; the sidecar carries gdb, the
  service does not. Cleanup is automatic when the sidecar exits.
- gdbserver: when the PID-namespace approach isn't enough
  (different host, security policy disallows the share), what
  the trade-off is.
- Producing useful core dumps from a container: `ulimit -c
  unlimited`, `/proc/sys/kernel/core_pattern` lives on the host,
  which means the path you set has to be reachable from the
  container's mount namespace.

## Demo

[`examples/demo-06-quality-pipeline/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/demo-06-quality-pipeline)
runs cppcheck and clang-tidy as part of the build, runs the
googletest suite, and (optionally) starts the service and
attaches a gdb sidecar that demonstrates a breakpoint without
mutating the running image.

## For deeper coverage

- Iglberger, *C++ Software Design*, ch. 3 (testability as a
  design property)
- The clang-tidy check list and rationale per check, upstream

## What's next

§12 stays in the build pipeline but turns to the longer-lived
question: how do you build the same binary again next month?
