---
title: "Statelessness 08 — Ephemeral filesystem"
description: "The runnable companion to compendium Doc 08: a read-only container rootfs as the forcing function, spdlog's basic_logger_mt EROFS trap and the stdout-sink fix, ephemerality across container restarts, and why scratch belongs on an explicitly-mounted tmpfs."
order: 209
layout: example
sectionid: examples
permalink: /examples/statelessness-08-ephemeral-filesystem/
demo_dir: statelessness/08-ephemeral-filesystem
github_path: examples/statelessness/08-ephemeral-filesystem
---

> The full source for this example lives in [`examples/statelessness/08-ephemeral-filesystem/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/statelessness/08-ephemeral-filesystem) — clone the repo, `cd` in, and `./demo.sh`.

Compendium reference:
[Doc 08 — The ephemeral filesystem trap]({{ '/reference/statelessness/08-ephemeral-filesystem/' | relative_url }})

A container's filesystem is ephemeral: anything written outside an
explicitly-mounted volume disappears on restart, and the kernel does not
warn you. The forcing function is a **read-only rootfs**, so accidental
writes fail loudly with `EROFS` in testing instead of vanishing silently
in production. This example builds one small spdlog binary and runs it
under different `podman run` flags to show what that means in C++.

## What it demonstrates

**The spdlog file-sink trap.** `basic_logger_mt("name", "path")` opens
the file in its constructor; under a read-only rootfs the open fails with
`EROFS` and spdlog throws, crashing the service at startup. It is the
most common C++ container filesystem bug.

**The fix: log to stdout.** A `stdout_color_sink_mt` with a structured
pattern, as Doc 08 prescribes. The binary writes nothing to disk, so the
read-only rootfs is no obstacle; the runtime captures stdout and ships it
to Loki — no file path, no rotation, no log directory.

**Ephemerality.** On a writable rootfs a file write "works," but a fresh
container's `check-file` shows it did not survive: each container starts
with a clean overlay layer.

**Scratch belongs on a tmpfs.** A scratch write under a read-only rootfs
fails unless a tmpfs is mounted at the target; with `--tmpfs /tmp` it
succeeds, RAM-backed and recycled on restart.

## Running it

```bash
cd examples/statelessness/08-ephemeral-filesystem
./demo.sh            # build, then the four acts
./demo.sh --clean    # remove the built image
```

CI verification: `scripts/test-stateless-demo-08-ephemeral-filesystem.sh`.

The build is a quick compile of one binary (spdlog + fmt via Conan).
There is no long-running service and no ports — the demo runs the binary
under several `podman run` configurations and shows the contrast.

## How it relates to the rest

The gRPC examples in this set
([02]({{ '/examples/statelessness-02-raii/' | relative_url }}),
[03]({{ '/examples/statelessness-03-pmr/' | relative_url }}),
[04]({{ '/examples/statelessness-04-process-scoped-state/' | relative_url }}),
[07]({{ '/examples/statelessness-07-state-externalization/' | relative_url }}))
already run with `read_only: true` and an explicit `tmpfs: [/tmp]` — they
are the services that got the audit right. This example is the *why*: it
shows the failure those settings prevent. Persistence that must survive a
restart goes to a backing store (Doc 07), never the container layer.
