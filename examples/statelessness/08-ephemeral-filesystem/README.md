# statelessness/08-ephemeral-filesystem — the read-only rootfs

Compendium reference:
[Doc 08 — The ephemeral filesystem trap](../../../reference/statelessness/08-ephemeral-filesystem/)

The runnable companion to Doc 08. A container's filesystem is ephemeral:
anything written outside an explicitly-mounted volume disappears on
restart, and the kernel does not warn you — the writes succeed, the data
is simply gone next start. The forcing function is to make the rootfs
**read-only**, so accidental writes fail loudly with `EROFS` during
testing instead of vanishing silently in production.

This example builds one small binary (`app`, using spdlog) and runs it
under different `podman run` flags to show what that means for a C++
service.

## What it demonstrates

**The spdlog file-sink trap** ([`src/app.cpp`](src/app.cpp), `log-file`).
spdlog's `basic_logger_mt("name", "path")` opens the file in its
constructor. Under a read-only rootfs the open fails with `EROFS` and
spdlog throws `spdlog_ex` — the service crashes at startup. This is the
single most common C++ container filesystem bug.

**The fix: log to stdout** (`log-stdout`). A `stdout_color_sink_mt` with
a structured pattern, exactly as Doc 08 prescribes. The binary writes
nothing to disk, so the read-only rootfs is no obstacle; the runtime
captures stdout and ships it to the log aggregator (Loki). No file path,
no rotation, no log directory.

**Ephemerality** (`log-file` on a writable rootfs, then `check-file`).
On a writable rootfs the file write "works" — but a fresh container's
`check-file` shows it did not survive. Each container starts with a clean
overlay layer.

**Scratch belongs on a tmpfs** (`scratch`). A scratch write under a
read-only rootfs fails unless a tmpfs is mounted at the target. With
`--tmpfs /tmp` it succeeds; the data is RAM-backed and recycled on
restart.

## Running it

```console
./demo.sh           # build, then the four acts
./demo.sh --clean   # remove the built image
```

The build is a quick compile of one binary (spdlog + fmt via Conan).
There is no long-running service and no ports — the demo runs the binary
under several `podman run` configurations and shows the contrast.

The host-level test:

```console
../../../scripts/test-stateless-demo-08-ephemeral-filesystem.sh
```

## A note on `--read-only-tmpfs`

Podman's `--read-only-tmpfs` (default **true**) auto-mounts a tmpfs on
`/tmp`, `/run`, and `/var/tmp` when `--read-only` is set. The demo
disables it (`--read-only-tmpfs=false`) in the scratch act to show the
bare read-only behavior, then mounts a tmpfs explicitly. In production
you either rely on that default or — better, because it is explicit and
portable — mount the tmpfs yourself (compose `tmpfs:` / Kubernetes
`emptyDir` with `medium: Memory`). Paths *not* covered by the auto-mount,
like `/var/log` and `/var/cache`, are always read-only under
`--read-only`, which is why the file-logger act fails reliably.

## How this relates to the other examples

The gRPC examples in this set (02, 03, 04, 07) already run with
`read_only: true` and an explicit `tmpfs: [/tmp]` in their compose files
— they are the services that got the audit right. This example is the
*why*: it shows the failure those settings prevent. Persistence that
must survive a restart goes to a backing store (Doc 07), never the
container layer.

## Layout

```
08-ephemeral-filesystem/
├── src/app.cpp        log-stdout / log-file / check-file / scratch modes
├── CMakeLists.txt     one binary, spdlog
├── conanfile.py       spdlog/1.14.1 (pulls fmt; both static)
├── Containerfile      UBI 10 builder; ubi-minimal runtime + libstdc++
└── demo.sh            podman run under --read-only / --tmpfs
```
