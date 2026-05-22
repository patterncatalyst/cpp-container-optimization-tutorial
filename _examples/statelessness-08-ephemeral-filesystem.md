---
title: "Statelessness 08 — Ephemeral filesystem"
description: "The runnable companion to compendium Doc 08: a read-only container rootfs as the forcing function, spdlog's basic_logger_mt EROFS trap and the stdout-sink fix, ephemerality across container restarts, and why scratch belongs on an explicitly-mounted tmpfs."
order: 209
card_eyebrow: "Compendium · <strong>Doc 08</strong>"
card_title: "Ephemeral filesystem"
card_blurb: "The read-only rootfs as a forcing function: spdlog's basic_logger_mt EROFS trap and the stdout-sink fix, ephemerality across restarts, and why scratch belongs on an explicitly-mounted tmpfs."
layout: example
sectionid: examples
permalink: /examples/statelessness-08-ephemeral-filesystem/
demo_dir: statelessness/08-ephemeral-filesystem
github_path: examples/statelessness/08-ephemeral-filesystem
---

> The full source for this example lives in [`examples/statelessness/08-ephemeral-filesystem/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/statelessness/08-ephemeral-filesystem) — clone the repo, `cd` in, and `./demo.sh`.

Compendium reference:
[Doc 08 — The ephemeral filesystem trap]({{ '/reference/statelessness/08-ephemeral-filesystem/' | relative_url }})

Tutorial sections:
[§4 Container Strategy: UBI, ubi-micro, multi-stage]({{ '/docs/04-image-strategy/' | relative_url }})

A container's filesystem is ephemeral: anything written outside an
explicitly-mounted volume disappears on restart, and the kernel does not
warn you. The forcing function is a **read-only rootfs**, so accidental
writes fail loudly with `EROFS` in testing instead of vanishing silently in
production. This example builds one small spdlog binary and runs it under
different `podman run` flags to show what that means in C++.

## Why this matters

The ephemeral filesystem is the constraint people forget until it bites in
production, and statelessness depends on respecting it:

- **Silent data loss is the worst kind.** A write to the container rootfs
  *succeeds* — the bytes land on the writable overlay layer — and then
  vanish on the next restart, with no error to point at. By the time you
  notice missing data, the evidence is gone.
- **A read-only rootfs converts silence into a loud failure.** With
  `read_only: true`, the same accidental write fails immediately with
  `EROFS` in testing, where you can see and fix it, instead of disappearing
  in production. It's a forcing function, not a restriction.
- **Statelessness *requires* that nothing authoritative lives on disk.** A
  replica that keeps state on its local filesystem can't be killed and
  rescheduled freely — the orchestrator's core assumption. Persistence goes
  to a backing store (state externalization); scratch goes to an explicit
  tmpfs; logs go to
  stdout.

## What this demo shows

**The spdlog file-sink trap.** `basic_logger_mt("name", "path")` opens the
file in its constructor; under a read-only rootfs the open fails with
`EROFS` and spdlog throws, crashing the service at startup. It is the most
common C++ container filesystem bug.

**The fix: log to stdout.** A `stdout_color_sink_mt` with a structured
pattern, as Doc 08 prescribes. The binary writes nothing to disk, so the
read-only rootfs is no obstacle; the runtime captures stdout and ships it to
Loki — no file path, no rotation, no log directory.

**Ephemerality.** On a writable rootfs a file write "works," but a fresh
container's `check-file` shows it did not survive: each container starts with
a clean overlay layer.

**Scratch belongs on a tmpfs.** A scratch write under a read-only rootfs
fails unless a tmpfs is mounted at the target; with `--tmpfs /tmp` it
succeeds, RAM-backed and recycled on restart.

## How to run

```bash
cd examples/statelessness/08-ephemeral-filesystem
./demo.sh            # build, then the four acts
./demo.sh --clean    # remove the built image
```

The build is a quick compile of one binary (spdlog + fmt via Conan). There
is no long-running service and no ports — the demo runs the binary under
several `podman run` configurations and shows the contrast.

CI verification: `scripts/test-stateless-demo-08-ephemeral-filesystem.sh`.

## What you'll see

Representative output on a Fedora 44 host with Podman 5.x — the file logger
crashing on a read-only rootfs, the stdout fix working, ephemerality across
a restart, and scratch needing an explicit tmpfs:

```
==> act 1: log-file under --read-only   (the trap)
    [spdlog] Failed opening file /var/log/app.log for writing: Read-only file system
    terminate called after throwing an instance of 'spdlog::spdlog_ex'
    exit code: 134   <- crashes at startup, loudly (this is the lesson)

==> act 2: log-stdout under --read-only   (the fix)
    [2026-05-22 14:03:11.412] [app] [info] service starting (version=1.0.0)
    [2026-05-22 14:03:11.412] [app] [info] ready; logging to stdout
    exit code: 0     <- writes nothing to disk; read-only is no obstacle

==> act 3: ephemerality   (writable rootfs, then a fresh container)
    container A: wrote /data/marker.txt  ("hello")
    container B (fresh): check-file /data/marker.txt -> NOT FOUND
    -> the write 'worked' but did not survive the restart

==> act 4: scratch
    under --read-only (no tmpfs): write /tmp/scratch -> EROFS (fails)
    under --read-only --tmpfs /tmp: write /tmp/scratch -> OK (RAM-backed)
```

## How to read the output

- **Act 1 is *supposed* to crash.** The `EROFS` + `spdlog_ex` + exit 134 is
  the trap firing exactly as intended. On a writable rootfs this would have
  "worked" and then silently lost the logs on restart — which is worse.
- **Act 2 exits clean because it touches no disk.** Logging to stdout means
  the read-only rootfs is irrelevant; the platform's collector owns
  persistence. That's also what 12-factor's Logs factor wants.
- **Act 3 is the silent-loss demonstration.** The write to `/data` succeeds
  in container A, but container B — a fresh start — can't find it. Nothing
  errored; the data simply never persisted past the overlay layer.
- **Act 4 shows scratch needs an explicit home.** A read-only rootfs blocks
  `/tmp` writes until you mount a tmpfs there. `--tmpfs /tmp` makes scratch
  work, RAM-backed and recycled — the correct place for transient files.

## Files

- `src/app.cpp` — the `log-stdout` / `log-file` / `check-file` / `scratch`
  modes
- `CMakeLists.txt` — one binary, spdlog
- `conanfile.py` — spdlog/1.14.1 (pulls fmt; both static)
- `Containerfile` — UBI 9 builder; ubi-minimal runtime + libstdc++
- `demo.sh` — runs the binary under `--read-only` / `--tmpfs`

## Caveats and gotchas

- **`basic_logger_mt` opens the file in its constructor.** The throw happens
  at logger construction, before your service does any work — which is why
  it crashes at startup rather than at first log line. Prefer the stdout
  sink in a container, always.
- **`--read-only-tmpfs` defaults to true and hides the trap.** Podman
  auto-mounts a tmpfs on `/tmp`, `/run`, and `/var/tmp` under `--read-only`.
  The demo disables it (`--read-only-tmpfs=false`) in the scratch act to show
  the bare behaviour. Paths *not* covered — `/var/log`, `/var/cache` — are
  always read-only, which is why the file-logger act fails reliably.
- **Mount scratch tmpfs explicitly in production.** Relying on the auto-mount
  is fragile; an explicit compose `tmpfs:` / Kubernetes `emptyDir` with
  `medium: Memory` is portable and visible. And size it — a tmpfs counts
  against the memory cgroup.
- **A "successful" write on a writable rootfs is the dangerous case.** If
  your rootfs is writable, accidental writes succeed and then vanish on
  restart with no error. That's exactly why `read_only: true` is the
  recommended default — it turns the silent failure into a loud one.

## Source materials

This example deepens material from the project's
[**bibliography**]({{ '/bibliography/' | relative_url }}):

- **Andrist & Sehr, *C++ High Performance* 2e, ch. 2** — RAII over file
  handles and why resource acquisition (here, opening a log file) happens in
  a constructor that can fail
- **Iglberger, *C++ Software Design*, ch. 2** — the sink abstraction in
  spdlog as a strategy; swapping a file sink for a stdout sink without
  touching call sites
- **Enberg, *Latency*, ch. 2** — why disk I/O on the request path (file
  logging, rotation) is a latency source a stateless service should avoid

## Linked tutorial sections

- [**§4 Container Strategy: UBI, ubi-micro, multi-stage**]({{ '/docs/04-image-strategy/' | relative_url }}) —
  the image-and-runtime section: read-only rootfs, tmpfs for scratch,
  volumes for what must persist, and why the runtime image carries no log
  directory. This example is the filesystem-discipline half of that section.

## How it relates to the rest

The gRPC examples in this set
([02]({{ '/examples/statelessness-02-raii/' | relative_url }}),
[03]({{ '/examples/statelessness-03-pmr/' | relative_url }}),
[04]({{ '/examples/statelessness-04-process-scoped-state/' | relative_url }}),
[07]({{ '/examples/statelessness-07-state-externalization/' | relative_url }}))
already run with `read_only: true` and an explicit `tmpfs: [/tmp]` — they
are the services that got the audit right. This example is the *why*: it
shows the failure those settings prevent. Persistence that must survive a
restart goes to a backing store — see [state externalization]({{ '/examples/statelessness-07-state-externalization/' | relative_url }}) — never the container layer.
