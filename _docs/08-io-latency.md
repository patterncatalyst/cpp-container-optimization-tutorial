---
title: "I/O Latency: io_uring, Async gRPC, SO_REUSEPORT"
order: 8
description: Why direct liburing achieves 274K req/s at 181µs p99 while the same workload through sync gRPC manages 4.85K RPS at 30.92ms p99 — a 60× throughput gap from where syscalls happen. Plus the container-security gates that block io_uring by default.
duration: "15 minutes"
---

## Learning objectives

By the end of this section you can:

- Explain where syscall overhead lives on a modern kernel
  (KPTI page-table flushes, spectre mitigations, per-syscall
  bookkeeping) and why `epoll_wait` + `read` + `write` is
  two-to-three syscalls per request.
- Reason about the submission-queue / completion-queue model
  in `io_uring` and explain why it's not just "epoll with a
  different name."
- Write a minimal `io_uring` TCP echo server in idiomatic C++
  (RAII over `io_uring*` lifetimes, exception-safe SQE/CQE
  handling, proper return-value handling).
- Build an async gRPC service using the callback API and explain
  the common pitfalls (one CQ per service, blocking inside a
  tag handler, RPCs leaking on shutdown).
- Diagnose the two independent container-security gates
  (`seccomp` + SELinux) that block `io_uring` by default and
  decide whether `SO_REUSEPORT` is the right answer for your
  fan-in shape.

## Diagram

{% include excalidraw.html name="08-io-uring-rings" caption="io_uring SQ/CQ rings in shared memory." %}

## The 60× throughput gap

Demo-03 runs three TCP echo servers in the *same binary*, on the
same kernel, against the same load generator:

| Server | API | Throughput | p99 latency |
|---|---|---|---|
| gRPC callback API (`:50051`) | sync-ish, one syscall per send/recv | **4,850 req/s** | **30.92 ms** |
| Direct `liburing` (`:9000`) | submit batch → reap batch | **274,000 req/s** | **181 µs** |
| Asio io_uring backend (`:9001`) | `io_uring` under Asio's API | **349,000 req/s** | **110 µs** |

Same kernel. Same machine. Same code path through the network
stack. The throughput gap between gRPC and Asio io_uring is
**~72×**. The p99 gap is **281× lower**.

The reason isn't that gRPC is "slow" — gRPC is doing protobuf
serialization, HTTP/2 framing, and TLS that the raw TCP servers
aren't. But the *I/O syscall pattern* is the dominant cost when
you measure the gap between two TCP echo servers (`:9000`
direct, `:9001` Asio) that do *exactly the same network work* and
still differ by ~20% throughput. The kernel work is identical;
the userland bookkeeping per request is what differs.

**This section is about the syscall layer underneath.** Once you
understand where the cost lives, the `io_uring` design becomes
obvious — and the gRPC overhead becomes a deliberate trade-off
between developer time and request latency, not an accident.

## Where syscall overhead lives in 2026

A traditional epoll-based server does this per request:

```
1. epoll_wait()           — wait for socket readiness
2. read(fd, buf, n)        — read the request
3. (do the work)
4. write(fd, buf, n)       — write the response
```

Three to four syscalls per request, where each syscall pays:

- **Mode-switch cost**: ~50-100 ns just for `syscall` instruction
  + IRET.
- **KPTI page-table flush** (Kernel Page Table Isolation, the
  Meltdown mitigation): the CPU drops the user TLB entries on
  every syscall enter and reload them on syscall exit. Adds
  ~50-100 ns per syscall.
- **Spectre v2 mitigations**: `RETBleed`, indirect-branch
  prediction barriers depending on kernel config. ~10-50 ns
  per syscall in worst cases.
- **Syscall dispatch bookkeeping**: capabilities check, audit
  logging, seccomp filter evaluation, ptrace check, scheduler
  state update. ~100-200 ns per syscall.

Total: rough order-of-magnitude **200-500 nanoseconds per
syscall** on modern hardware, *before* the syscall actually
does its work.

At 100k req/s, that's 300k syscalls/sec × 300 ns ≈ **90 ms/sec
of pure mode-switching overhead** — almost 10% of one CPU
gone before any actual I/O happens.

The fix has to be: *do fewer syscalls per request*. `io_uring`
is the kernel API designed around that constraint.

## `io_uring` — SQ/CQ rings explained

The diagram above shows the structure. Two ring buffers, both
mapped into shared memory between the application and the
kernel:

- **Submission Queue (SQ)**: the app writes Submission Queue
  Entries (SQEs) here. Each SQE describes one I/O operation
  to perform (READ, WRITE, ACCEPT, RECV, SEND, etc.) plus the
  fd, buffer, and user-data tag.
- **Completion Queue (CQ)**: the kernel writes Completion
  Queue Entries (CQEs) here when operations finish. Each CQE
  carries the result (bytes transferred, or `-errno`) plus the
  user-data tag from the SQE.

The basic loop in C++ wrapping liburing:

```cpp
#include <liburing.h>
#include <system_error>

class IoUring {
    io_uring ring_;  // RAII-managed
public:
    explicit IoUring(unsigned queue_depth) {
        if (int ret = io_uring_queue_init(queue_depth, &ring_, 0); ret < 0) {
            throw std::system_error(-ret, std::system_category(),
                                    "io_uring_queue_init");
        }
    }
    ~IoUring() { io_uring_queue_exit(&ring_); }

    IoUring(const IoUring&) = delete;
    IoUring& operator=(const IoUring&) = delete;

    void submit_read(int fd, void* buf, size_t n, uint64_t tag) {
        auto* sqe = io_uring_get_sqe(&ring_);
        io_uring_prep_read(sqe, fd, buf, n, 0);
        io_uring_sqe_set_data64(sqe, tag);
    }

    int wait_completion(io_uring_cqe** cqe) {
        return io_uring_wait_cqe(&ring_, cqe);
    }

    void seen(io_uring_cqe* cqe) { io_uring_cqe_seen(&ring_, cqe); }
    int submit() { return io_uring_submit(&ring_); }
};
```

The key shape: **one syscall (`io_uring_enter`, wrapped by
`io_uring_submit`) submits N operations at once and reaps
their completions**. At 100k req/s with batches of 32 SQEs,
that's ~3,100 syscalls/sec instead of 300k — a 100× reduction
in mode-switching overhead.

`io_uring` was designed by Jens Axboe specifically to attack
this overhead; the kernel-side machinery is a fixed-cost
worker thread per ring that consumes SQEs and produces CQEs.
The userland API became the bottleneck, not the kernel I/O.

## SQPOLL — the zero-syscall path

For the absolute hot path, `io_uring` offers `IORING_SETUP_SQPOLL`:
the kernel runs a dedicated thread that polls the SQ on its own,
**consuming submitted SQEs without an `io_uring_enter` syscall
at all**. The app writes an SQE and a memory fence; the kernel
sees it and processes it.

The cost: one extra kernel thread per ring (and one extra CPU
spinning at low priority when there's no work). The benefit: the
syscall overhead per submission goes to *zero*.

SQPOLL is rarely the right default — most services don't have
enough sustained I/O pressure to justify the kernel thread — but
for high-fan-in network proxies or storage workloads at >500k
req/s it can shave another 30-50% off the latency floor. The
SQPOLL kernel thread shows up as `[io_uring-sq]` in `ps`;
[§11's cpuset isolation patterns](../11-noisy-neighbors/) apply
to it the same way they apply to your service's worker threads
— pin the SQPOLL thread to a dedicated core if you want to
keep its work from contending with anything else.

## Container security gates for `io_uring` — G-32

`io_uring` is powerful, and that power makes it a security
concern. In Fedora 41+ and RHEL 9.4+, two independent container
security gates block `io_uring` syscalls by default for
unprivileged containers:

| Gate | What it blocks | Symptom | Fix |
|---|---|---|---|
| seccomp default profile | `io_uring_setup`, `io_uring_enter`, `io_uring_register` | `-EPERM` (errno 1) | `security_opt: seccomp=unconfined`, or a custom profile that whitelists those three syscalls |
| SELinux `container_t` policy | the `io_uring` operation class | `-EACCES` (errno 13) | `security_opt: label=disable`, or a custom SELinux module that grants the `io_uring` permission to your container type |

(A third layer, the `kernel.io_uring_disabled` sysctl introduced
in 6.6, can additionally block `io_uring` at the host level. Most
distros leave it at the default value `0` — io_uring allowed —
but containers running on a host where it's `1` will see
`io_uring_setup` fail regardless of seccomp/SELinux config.)

The two-gate problem is what cost a half-dozen rounds in this
tutorial's development, captured as **gotcha G-32**. The
diagnosis pattern:

```cpp
// Hit -EPERM (errno 1)?   → seccomp blocked it
// Hit -EACCES (errno 13)? → SELinux blocked it
if (int ret = io_uring_queue_init(queue_depth, &ring_, 0); ret < 0) {
    std::cerr << "io_uring_queue_init failed: ret=" << ret
              << " errno=" << -ret
              << " (" << strerror(-ret) << ")\n";
    throw std::system_error(-ret, std::system_category(),
                            "io_uring_queue_init");
}
```

**Important nuance**: liburing's `io_uring_queue_init` returns
`-errno` directly (negative ints) rather than `-1`-and-set-errno.
The `perror()`-style error handling that's universal in POSIX
gives misleading output here ("Success") because the errno
variable hasn't been set; you have to negate the return value
yourself.

Demo-03 ships `compose.production.yml` with a custom seccomp
profile + a custom SELinux module that demonstrates the
correct production configuration. The development
`compose.yml` uses `seccomp=unconfined` and `label=disable`
for simplicity, but **don't ship that to production**.

## Async gRPC — completion queue per CPU

Modern gRPC C++ supports two APIs:

- **Sync API**: one thread per concurrent RPC. Simple to reason
  about, scales poorly past a few thousand concurrent clients.
  Demo-03's gRPC server uses the **callback API** (a sync-ish
  but more efficient variant) at port `:50051`.
- **Async API** (`grpc::CompletionQueue`): event-loop pattern
  with completion-queue tags. Higher throughput, harder to use
  correctly.

The completion-queue model maps cleanly onto a thread-per-core
design:

```cpp
// One completion queue per worker thread, one thread per core
std::vector<std::unique_ptr<grpc::ServerCompletionQueue>> cqs;
std::vector<std::thread> workers;

for (int i = 0; i < num_cores; ++i) {
    cqs.push_back(builder.AddCompletionQueue());
}

auto server = builder.BuildAndStart();

for (int i = 0; i < num_cores; ++i) {
    workers.emplace_back([cq = cqs[i].get()] {
        void* tag;
        bool ok;
        while (cq->Next(&tag, &ok)) {
            static_cast<RpcHandler*>(tag)->Proceed(ok);
        }
    });
}
```

Three common pitfalls:

1. **One completion queue serving all gRPC services.** The CQ
   becomes a contention point at high QPS. Use one CQ per
   core, or at least one per service.
2. **Blocking inside a tag handler.** Each worker thread is the
   only consumer of its CQ; if `Proceed(ok)` does a synchronous
   database call, every tag queued behind it waits. Offload
   blocking work to a dedicated thread pool with another CQ
   to signal completion.
3. **RPCs leaking on shutdown.** `CompletionQueue::Shutdown`
   drains the queue, but in-flight tags must each call
   `Finish()` and be `delete`d. The common pattern is a
   `state` member in `RpcHandler` so `Proceed(ok=false)`
   (the "this stream is shutting down" signal) can clean up.

When sync gRPC is *fine*: a service with <500 concurrent RPCs
and stable latency requirements. The sync API's clarity is
worth the throughput trade-off for most internal services.

## `SO_REUSEPORT` — kernel-side load-balanced accept

When a service has multiple processes (or threads with their
own listening sockets) for the same port, `SO_REUSEPORT` tells
the kernel to spread incoming connections across them:

```cpp
int sock = ::socket(AF_INET, SOCK_STREAM, 0);
int opt = 1;
::setsockopt(sock, SOL_SOCKET, SO_REUSEPORT, &opt, sizeof(opt));
::bind(sock, ...);
::listen(sock, ...);
// Repeat in N processes / threads with the same address+port
```

The kernel hashes connection 5-tuples (src ip, src port, dst ip,
dst port, protocol) to pick which listener gets each new
connection. The result: even-ish load distribution without an
in-process load balancer.

This is the right tool when:

- Your service has more incoming connection arrivals than one
  accept thread can handle (>~100k accepts/sec).
- You want kernel-level affinity (the same 5-tuple goes to the
  same listener every time, useful for cache reuse on
  per-connection state).
- You can't put a sidecar load balancer (envoy, nginx) in front.

It's the wrong tool when:

- Connection arrival rate is moderate (a single accept thread
  handles 50k accepts/sec on modern hardware).
- You want graceful drains; with `SO_REUSEPORT`, removing one
  listener while the others stay up requires deliberate
  shutdown-coordination logic.

## Direct `liburing` vs Asio io_uring vs gRPC — what the gap means

The demo-03 numbers shown at the top deserve a moment of
unpacking. Three servers, three latency profiles, **the same
kernel I/O underneath**:

| Server | Userland-side bookkeeping per request |
|---|---|
| Direct `liburing` (274K req/s) | hand-rolled state machine; no allocations on hot path; one io_uring_submit per batch |
| Asio io_uring (349K req/s) | Asio's `awaitable` machinery; one `std::coroutine_handle` per outstanding op; `io_context` event loop |
| gRPC callback API (4.85K req/s) | full HTTP/2 framing, protobuf serialization, TLS, gRPC's own thread-pool dispatch |

The Asio version is *faster* than direct liburing here, which
looks counterintuitive — shouldn't the hand-rolled code be
fastest? Two reasons:

1. **Asio's io_uring backend uses fixed registered buffers and
   registered file descriptors**, which avoid a per-call
   buffer/fd lookup in the kernel. Registered buffers are a
   data-layout decision — you allocate the buffer pool *once*
   at setup and reuse it for every operation, which is the
   same arena pattern [§6's `flat_map` discussion](../06-stl-layout/)
   and [§7's PMR `monotonic_buffer_resource`](../07-memory-management/)
   apply to general-purpose data. The direct liburing version
   in demo-03 doesn't (yet) use these features.
2. **Asio's coroutine machinery batches submissions more
   aggressively** than the hand-rolled version's loop.

The lesson isn't "Asio always wins" — the lesson is **bulk
submission and registered resources beat per-call setup**,
regardless of which API you choose. The direct liburing
version is faster than the gRPC callback by 56×, which is the
gap that comes from doing less work per request. Adding
register-buffer support would close most of the remaining
gap to Asio.

## Production diagnostic — is `io_uring` firing in my container?

When you've added `io_uring` and the throughput didn't move,
or moved less than expected, the diagnosis path:

```bash
# 1. Are the syscalls reaching the kernel?
podman exec myservice strace -c -e io_uring_setup,io_uring_enter \
    -p <PID-of-server> 2>&1 | head -20
# If io_uring_setup shows 0 calls but io_uring_enter shows
# millions, the ring was created elsewhere and we're using it.
# If io_uring_setup shows -EPERM or -EACCES, see G-32 above.

# 2. Is SQPOLL actually polling?
ps -eLf | grep io_uring-sq
# Should show an [io_uring-sq] kthread per ring when SQPOLL is on.

# 3. Are there pending submissions in the SQ?
cat /proc/<PID>/io_uring/sqe   # kernel 6.10+
# Non-zero queued count means the kernel isn't keeping up;
# usually a sign of SQPOLL not yielding the CPU it needs.

# 4. Is anything actually using io_uring?
sudo bpftrace -e 'kprobe:io_uring_enter { @[comm] = count(); }' -c "sleep 10"
# Distribution of which processes are issuing io_uring_enter
# in a 10-second window. Yours should be there.
```

For richer eBPF-based introspection of the kernel I/O paths
(syscall histograms, request-latency distributions per fd, retransmits),
see [§9's bcc-tools + bpftrace coverage](../09-networking-kernel/) —
this is exactly the territory those tools were built for.

## Why this is a C++ concern

Go and Rust have async runtimes that abstract away the I/O
syscall pattern entirely; you write `async/await` and the
runtime picks epoll, kqueue, or io_uring based on what the
kernel supports. You don't see the SQE/CQE distinction.

C++ has had `<coroutine>` since C++20 but no standard async I/O
runtime — Asio (or Boost.Asio), libcoro, and stdexec are the
candidates, each with different opinions. **That means the io_uring
choice is *yours*, not the runtime's.** You decide whether
buffer registration is worth the bookkeeping; you decide whether
SQPOLL is worth a kernel thread; you decide between direct
liburing and Asio's wrapping.

The RAII patterns matter more here than in most code: an
`io_uring*` ring left unclosed is a kernel-thread leak; a
registered buffer not unregistered is a pinned page that the
kernel can't reclaim; a CQE not `cqe_seen`'d is a ring slot
permanently consumed. The C++-shaped wrapper that pairs each
of these with `unique_ptr`-style ownership semantics is what
makes the code production-grade — the same pattern
[§3 develops for resource discipline more broadly](../03-raii-discipline/),
applied here to kernel-side resources where the leak symptoms
are even harder to spot than the file-descriptor leaks §3
walks through.

## Demo

[`examples/demo-03-io-uring-grpc/`]({{ '/examples/demo-03-io-uring-grpc/' | relative_url }})
brings up three servers in one binary in `podman compose`:

- gRPC callback API at `:50051`, driven by `ghz`
- Direct `liburing` echo at `:9000`, driven by `tcp-loadgen`
- Asio io_uring echo at `:9001`, driven by `tcp-loadgen`

Run `./demo.sh` to bring everything up + drive load + print a
side-by-side summary. The verified numbers at the top of
this section are from that run. Open
`http://127.0.0.1:3000` to inspect the gRPC histograms and
counters in Grafana ([§10's observability stack](../10-observability-profiling/)).

The `compose.production.yml` variant shows the custom seccomp
+ SELinux configuration that demo-03 actually requires in
production (rather than the development-friendly
`seccomp=unconfined` + `label=disable`).

## For deeper coverage

- Enberg, *Latency*, ch. 6-7 (the operating-system layer,
  `io_uring` in particular) — this section's primary reference
- Andrist & Sehr, *C++ High Performance*, ch. 11 (concurrency
  patterns)
- Ghosh, *Building Low Latency Applications with C++*, ch. 8-9
  (network programming and a worked async I/O ecosystem)
- [`io_uring(7)` man page](https://man7.org/linux/man-pages/man7/io_uring.7.html)
  (the canonical API reference)
- Jens Axboe, [Efficient IO with
  io_uring](https://kernel.dk/io_uring.pdf) (the original
  design document)
- gRPC C++, ["Async API Best
  Practices"](https://grpc.io/docs/languages/cpp/basics/)

## What's next

[§9 moves down the stack to the kernel
parameters](../09-networking-kernel/) that affect the data
paths this section's I/O patterns ride on: TCP buffer sizes,
`net.core.somaxconn`, the cost of `veth` pairs and bridges,
and the eBPF tools (`bcc-tools`, `bpftrace`, `bpftool`) for
diagnosing the network plumbing itself.
