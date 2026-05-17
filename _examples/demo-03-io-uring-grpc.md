---
title: "Demo 03 — Async gRPC + io_uring (direct + Asio backend)"
description: "Three servers in one binary, all wired into the LGTM observability stack. Two of the three speak the same protocol — raw TCP echo — which lets you drive them with the same load generator and compare the cost of going through Asio's…"
order: 3
layout: example
sectionid: examples
permalink: /examples/demo-03-io-uring-grpc/
demo_dir: demo-03-io-uring-grpc
github_path: examples/demo-03-io-uring-grpc
---

> The full source for this demo lives in [`examples/demo-03-io-uring-grpc/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/demo-03-io-uring-grpc) — clone the repo, `cd` in, and `./demo.sh`.


Tutorial sections:
[§8 I/O Latency](/docs/08-io-latency/) +
[§9 Networking & Kernel Parameters](/docs/09-networking-kernel/)

Three servers in one binary, all wired into the LGTM observability
stack. Two of the three speak the same protocol — raw TCP echo —
which lets you drive them with the same load generator and compare
the cost of going through Asio's executor model against using
liburing directly.

## Why this matters

`io_uring` is the most consequential Linux I/O change of the past
decade — the first kernel API since `aio` that fundamentally rethinks
how userspace describes I/O to the kernel. Where epoll asks "is this
fd ready?", io_uring lets you batch submissions, get completions
back asynchronously, and avoid the per-call syscall cost that
dominates traditional async patterns.

But "use io_uring" is too coarse. The interesting questions are:

- **Direct or wrapped?** liburing gives you the raw submission /
  completion ring. Asio's io_uring backend hides the ring behind
  its executor abstraction — same kernel calls, friendlier API,
  measurably more userland overhead.
- **What about gRPC?** The standard gRPC C++ async API uses
  completion queues, not io_uring. It has its own latency
  characteristics independent of the I/O backend. Production
  C++ services often mix all three patterns.
- **What does it cost to run inside a container?** io_uring needs
  syscalls that seccomp denies by default. Getting a working
  configuration that's also production-safe is non-trivial.

§8 covers the I/O latency model; §9 covers the networking-side
kernel parameters; this demo is the worked example for both.

## What this demo shows

Three servers, all running inside one container, each driven by
a workload appropriate to its protocol:

| Port | Server | What it demonstrates |
|---|---|---|
| `:50051` | gRPC Echo (callback API) | Async gRPC's completion-queue model + OTel instrumentation |
| `:9000` | io_uring TCP echo (direct liburing) | The bare submission/completion ring without abstraction overhead |
| `:9001` | TCP echo (Asio io_uring backend) | Same kernel calls under a high-level executor model — the cost of abstraction |

The two TCP echo servers speak the same protocol, so the
side-by-side comparison isolates the userland cost: same syscalls,
different bookkeeping.

## How to run

```bash
./demo.sh
```

First build is ~30-45 minutes (the OTel/gRPC chain rebuilds from
source under the override profile). Subsequent runs are 2-3 minutes.

The script:

1. Brings up the LGTM stack + demo-03-svc
2. Waits for `:18403` healthz
3. Drives gRPC Echo for 10 seconds via `ghz` (run in a container —
   no local install required)
4. Drives the io_uring direct echo on `:9000` via `tcp-loadgen`
   (built into the demo image)
5. Drives the Asio io_uring echo on `:9001` via `tcp-loadgen`
6. Prints a side-by-side summary table

Then open `http://127.0.0.1:3000` to inspect the gRPC histogram and
counters in Grafana.

## What you'll see

Representative summary table from a single-NUMA-node x86_64 host
(numbers vary with CPU model and kernel version):

```
Server                   conns   req/s        p50      p95      p99      max
gRPC Echo (callback)        50    4,847       9.84 ms 20.10 ms 30.92 ms 80 ms
io_uring direct            500  274,109     108 µs    142 µs   181 µs   3.2 ms
io_uring via Asio          500  349,012      59 µs    101 µs   110 µs   2.7 ms
```

In Grafana, the gRPC histogram panel shows the per-method latency
distribution, the request counter rolls up by status code, and the
trace view drills into individual RPCs.

## How to read the output

The headline comparisons:

- **gRPC is two orders of magnitude slower on throughput than the
  raw TCP servers.** That's the cost of framing, length-prefixing,
  HPACK header coding, deadline tracking, and the completion-queue
  trampoline. gRPC isn't slow — TCP echo with no semantics is just
  the floor.
- **Asio io_uring beats direct liburing in this benchmark.** That
  result surprises people, but it makes sense: Asio batches
  submissions more aggressively than the demo's hand-rolled
  state machine, and the kernel-side work is identical. The
  takeaway isn't "Asio always wins"; it's "the userland strategy
  matters more than direct-vs-wrapped framing".
- **p99 / max divergence on all three** reflects scheduler tail
  events more than I/O work. The kernel's CFS scheduler decides
  to preempt at quantum boundaries; that's where the millisecond
  outliers come from.

What different output would mean:

- **If io_uring direct is much faster than Asio**, your Asio
  workload is small enough that the wrapper overhead dominates.
  The cross-over happens around 50K req/s on typical hardware.
- **If gRPC throughput is below ~3K req/s**, check that the
  callback API is wired up (vs the synchronous API). Synchronous
  gRPC pins one thread per active RPC.
- **If io_uring shows 0 throughput**, seccomp is likely blocking
  the io_uring syscalls — see the security section below.

## Direct liburing vs Asio io_uring — the userland cost

Both servers use io_uring under the hood. The expected latency
difference is small (low single-digit microseconds at most)
because the kernel-side work is identical. What differs is the
userland-side bookkeeping:

- **Direct liburing**: one syscall (`io_uring_enter`) submits
  and collects many operations at once. The state machine —
  accept → read → write → read — lives in our code, in plain
  C-style switch statements.
- **Asio**: same kernel calls underneath, but the completion
  handling goes through callbacks, shared_ptr lifetime
  management, allocator hooks (`asio::associated_allocator`),
  and executor dispatch. Each layer is small; their sum is
  measurable.

For most production code, Asio's ergonomic wins are worth the
microsecond overhead. The tutorial point is to know the price.

## Three §8/§9 lessons in one demo

- **The submission / completion model** — direct liburing makes
  this literal: you build SQEs, submit them, wait for CQEs.
  Compare to epoll's "is the fd ready?" model. §8 develops the
  contrast.
- **`SO_REUSEPORT` for parallel listeners** — both TCP servers
  set this on the listen socket. To demonstrate multiple
  processes sharing the same port, run the demo's container
  twice with different `--name` flags pointing at the same
  port. §9 covers the kernel-side semantics.
- **The cost of abstraction** — the Asio echo is half the code,
  but pays a measurable runtime tax. §14 (Pitfalls) generalizes
  this pattern.

## Security posture — tutorial vs production

The `compose.yml` shipped with this demo uses `seccomp=unconfined`
and `label=disable` to make io_uring work in the container. **That
configuration would not pass a security audit.** It's the easy
path for a demo on a developer laptop.

A parallel **`compose.production.yml`** in this directory shows
the audit-grade alternative: a custom seccomp profile that's
podman's default plus exactly the three io_uring syscalls, plus a
custom SELinux policy module that grants `container_t` the
`io_uring` permission class. Plus capabilities dropped, read-only
root filesystem, and resource limits.

The C++ source doesn't change between the two; only the
surrounding container security configuration does.

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

See `security/README.md` in this directory for the full audit
story: what the tutorial setup actually removes, what CVEs the
default profile catches, why a custom seccomp profile is better
than unconfined, what the SELinux module adds vs label=disable,
and what production gaps the demo still doesn't cover (image
signing, network policy, runtime security monitoring, etc.).

## Why standalone `asio` not `boost::asio`

The user-facing answer to the Q1 design question was "Boost.Asio
io_uring backend", but the Conan build is dramatically simpler
with **standalone asio** (`asio/1.32.0` on Conan Center) — same
library, no `boost::system` / `boost::thread` / `boost::date_time`
baggage. The io_uring switch becomes `ASIO_HAS_IO_URING` instead
of `BOOST_ASIO_HAS_IO_URING`. Same code, same behavior, smaller
dep surface.

If you want the explicit Boost.Asio version instead, flip
`conanfile.py` to `boost/1.86.0` and add `BOOST_ASIO_HAS_IO_URING`
to the CMakeLists target_compile_definitions. The C++ source
stays identical except for `boost::asio` → `asio` namespace.

## Lockfile inheritance from demo-04

Demo-03 inherits demo-04's OTel/gRPC override chain, but adds
`asio` which isn't in demo-04's lockfile. Conan's
`--lockfile-partial` flag allows the locked deps (gRPC, protobuf,
abseil, OTel-cpp + their transitives) to resolve to demo-04's
pinned revisions while new deps (asio) resolve fresh. To seed
demo-03 from demo-04's verified lockfile:

```bash
cp examples/demo-04-observability/conan.lock \
   examples/demo-03-io-uring-grpc/conan.lock
git add examples/demo-03-io-uring-grpc/conan.lock
git commit -m "chore(demo-03): inherit demo-04 lockfile"
```

The Containerfile picks this up automatically — it tests
`[ -s conan.lock ]` and switches between locked and fresh
resolution.

## Caveats and gotchas

- **io_uring features depend on kernel version.** Multishot
  accept needs ≥ 5.19; provided-buffer rings need ≥ 5.19; some
  optimizations need ≥ 6.0. The demo gates on `uname -r` and
  refuses to start on older kernels.
- **rootless io_uring has further restrictions.** Some operations
  that work in privileged containers fail rootless. The demo
  works around the common ones; production audits should verify
  on the actual deployment target.
- **gRPC numbers are sensitive to message size.** The demo uses
  tiny echo messages; real gRPC at 1 KB+ messages has different
  latency characteristics.
- **First build is long.** The OTel + gRPC dependency chain pulls
  ~30 large packages from Conan and compiles them from source
  under the override profile. Subsequent builds use the Conan
  cache. If you're iterating on the C++ source only, the warm
  rebuild is fast.

## Source materials

This demo deepens material from the project's
[**bibliography**](/bibliography/):

- **Enberg, *Latency*, ch. 5-6** — the syscall-cost model that
  motivates io_uring; the case for batched submissions
- **Ghosh, *Building Low Latency Applications with C++*, ch. 8** —
  kernel-bypass alternatives to io_uring and where each fits
- **Andrist & Sehr, *C++ High Performance* 2e, ch. 11** — async
  patterns in modern C++; coroutines and executor models that
  Asio implements
- **liburing manpages** — `io_uring_setup(2)`, `io_uring_enter(2)`,
  `io_uring_register(2)` are the canonical references

## Linked tutorial sections

- [**§8 I/O Latency**](/docs/08-io-latency/) — this demo is §8's
  worked example. The §8 prose develops the syscall-cost model
  and the io_uring submission/completion machinery; this demo
  measures both.
- [**§9 Networking & Kernel Parameters**](/docs/09-networking-kernel/)
  — `SO_REUSEPORT`, the rootless vs host-networking trade-off,
  and the seccomp/SELinux story around io_uring. §9 covers each;
  this demo exercises all of them.
- [**§10 Observability & Profiling**](/docs/10-observability-profiling/)
  — traces and metrics emitted exactly like demo-04. The gRPC
  panel in the Grafana dashboard is from this demo's
  instrumentation.
- [**§13 Reproducibility & ABI**](/docs/13-reproducibility-abi/) —
  the lockfile-inheritance pattern this demo uses (`cp` from
  demo-04, then `--lockfile-partial`) is a §13 worked example of
  how lockfiles compose across related builds.
- [**§14 Pitfalls**](/docs/14-pitfalls/) — the abstraction-cost
  angle: Asio's executor model is friendlier and costs more.
  §14 generalizes the pattern.
