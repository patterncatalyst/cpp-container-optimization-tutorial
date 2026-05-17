---
title: "Demo 03 — Async gRPC + io_uring (direct + Asio backend)"
description: "Three servers in one binary, all wired into the LGTM observability stack:"
order: 3
layout: example
sectionid: examples
permalink: /examples/demo-03-io-uring-grpc/
demo_dir: demo-03-io-uring-grpc
github_path: examples/demo-03-io-uring-grpc
---

> The full source for this demo lives in [`examples/demo-03-io-uring-grpc/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/demo-03-io-uring-grpc) — clone the repo, `cd` in, and `./demo.sh`.


Three servers in one binary, all wired into the LGTM observability stack:

| Port | Server | Lesson |
|---|---|---|
| `:50051` | gRPC Echo (callback API) | §9 (Async gRPC), §10 (Observability) |
| `:9000` | io_uring TCP echo (direct liburing) | §9 (io_uring submission/completion model) |
| `:9001` | TCP echo (Asio io_uring backend) | §9 + §14 (cost of abstraction) |

The `:9000` and `:9001` servers speak the same protocol — raw TCP echo —
so you can drive them with the same load generator and compare latencies
directly. The §9 takeaway: **io_uring's win is real for both backends,
but the direct-liburing version pays less per call.**

## Run it

```bash
./demo.sh
```

First build is ~30-45 minutes (the OTel/gRPC chain rebuilds from source
under the override profile — see G-22..G-30 in the reconciliation plan).
Subsequent runs are 2-3 minutes.

The script:
1. Brings up the LGTM stack + demo-03-svc
2. Waits for `:18403` healthz
3. Drives gRPC Echo for 10 seconds via `ghz` (run in a container — no
   local install required)
4. Drives the io_uring direct echo on `:9000` via `tcp-loadgen` (built
   into the demo image)
5. Drives the Asio io_uring echo on `:9001` via `tcp-loadgen`
6. Prints a side-by-side summary table

Then open `http://127.0.0.1:3000` to inspect the gRPC histogram and
counters in Grafana.

## Why standalone `asio` not `boost::asio`

The user-facing answer to the Q1 design question was "Boost.Asio io_uring
backend", but the Conan build is dramatically simpler with **standalone
asio** (`asio/1.32.0` on Conan Center) — same library, no `boost::system`
/ `boost::thread` / `boost::date_time` baggage. The io_uring switch
becomes `ASIO_HAS_IO_URING` instead of `BOOST_ASIO_HAS_IO_URING`. Same
code, same behavior, smaller dep surface.

If you want the explicit Boost.Asio version instead, you'd flip
`conanfile.py` to `boost/1.86.0` and add `BOOST_ASIO_HAS_IO_URING` to
the CMakeLists target_compile_definitions. The C++ source stays
identical except for `boost::asio` → `asio` namespace.

## Why `--lockfile-partial` for demo-03

Demo-03 inherits demo-04's OTel/gRPC override chain, but adds `asio`
which isn't in demo-04's lockfile. Conan's `--lockfile-partial` flag
allows the locked deps (gRPC, protobuf, abseil, OTel-cpp + their
transitives) to resolve to demo-04's pinned revisions while new deps
(asio) resolve fresh. To seed demo-03 from demo-04's verified lockfile:

```bash
cp examples/demo-04-observability/conan.lock \
   examples/demo-03-io-uring-grpc/conan.lock
git add examples/demo-03-io-uring-grpc/conan.lock
git commit -m "chore(demo-03): inherit demo-04 lockfile"
```

The Containerfile picks this up automatically — it tests
`[ -s conan.lock ]` and switches between locked and fresh resolution.

## Direct liburing vs Asio io_uring — what the comparison shows

Both servers use io_uring under the hood. The expected latency
difference is small (low single-digit microseconds at most) because
the kernel-side work is identical. What differs is the userland-side
bookkeeping:

- **Direct liburing**: one syscall (`io_uring_enter`) submits and
  collects many operations at once. The state machine — accept→read→
  write→read — lives in our code, in plain C-style switch statements.
- **Asio**: same kernel calls underneath, but the completion handling
  goes through callbacks, shared_ptr lifetime management, allocator
  hooks (`asio::associated_allocator`), and executor dispatch. Each
  layer is small; their sum is measurable.

For most production code, Asio's ergonomic wins are worth the
microsecond overhead. The tutorial point is to know the price.

## Three §9 lessons in one demo

- **The submission/completion model** — direct liburing makes this
  literal: you build SQEs, submit them, wait for CQEs. Compare to
  epoll's "is the fd ready?" model.
- **`SO_REUSEPORT` for parallel listeners** — both servers set this
  on the listen socket. To demonstrate multiple processes sharing
  the same port, run the demo's container twice with different
  `--name` flags pointing at the same port.
- **The cost of abstraction** — the Asio echo is half the code, but
  pays a measurable runtime tax.

## Security posture — tutorial vs production

The compose.yml shipped with this demo uses `seccomp=unconfined` and
`label=disable` to make io_uring work in the container. **That
configuration would not pass a security audit.** It's the easy path
for a demo on a developer laptop.

A parallel **`compose.production.yml`** in this directory shows the
audit-grade alternative: a custom seccomp profile that's docker's
default + exactly the three io_uring syscalls, plus a custom SELinux
policy module that grants `container_t` the `io_uring` permission
class. Plus capabilities dropped, read-only root filesystem, and
resource limits.

The C++ source doesn't change between the two; only the surrounding
container security configuration does.

To run the production variant:

```bash
# One-time host setup (the seccomp profile uses YOUR local podman default
# as the base; the SELinux module needs root to install).
./security/build-seccomp-profile.sh
sudo ./security/install-selinux-policy.sh

# Then run normally — same load phases, audit-grade security:
./demo.sh --production

# Or with formal pass/fail criteria + security posture verification:
../../scripts/test-demo-03-production.sh
```

See **`security/README.md`** in this directory for the full audit
story: what the tutorial setup actually removes, what CVEs the
default profile catches, why a custom seccomp profile is better than
unconfined, what the SELinux module adds vs label=disable, and what
production gaps the demo still doesn't cover (image signing, network
policy, runtime security monitoring, etc.).

## Linked tutorial sections

- §9 (I/O & Networking): this demo is §9's worked example.
- §10 (Observability): traces and metrics emitted exactly like demo-04.
- §13 (Reproducibility): the lockfile-inheritance pattern this demo
  uses (`cp` from demo-04, then `--lockfile-partial`) is a §13 sidebar
  about "lockfiles compose across related builds."
- §14 (Common Pitfalls): the abstraction-cost angle.
