---
title: "I/O Latency: io_uring, Async gRPC, SO_REUSEPORT"
order: 8
description: Where syscall overhead hides on a modern kernel, what `io_uring` actually saves you, and how async gRPC plus `SO_REUSEPORT` get you a level shoulder under load.
duration: 15 minutes
---

## Learning objectives

By the end of this section you can:

- Explain the submission-queue / completion-queue mental model
  and why it's not just "epoll with a different name."
- Write a minimal `io_uring`-based TCP echo server in idiomatic
  C++ (RAII over `io_uring*` lifetimes, exception-safe SQE/CQE
  handling).
- Build an async gRPC service that uses the C++ async API
  (completion queue per CPU) and explain when sync gRPC is
  actually fine.
- Use `SO_REUSEPORT` to spread incoming connections across
  multiple listening sockets without an in-process load balancer.

## Diagram

{% include excalidraw.html name="07-io-uring-rings" caption="`io_uring` submission and completion queues, with the kernel-side submission thread" %}

## Planned content

- Where syscall overhead lives in 2026: KPTI page-table flushes,
  spectre mitigations, the per-syscall cost of context-switch
  bookkeeping. Why `epoll_wait` + `read` + `write` is two or
  three syscalls per request.
- `io_uring`: SQ/CQ rings, SQPOLL mode (kernel-side submission
  thread), registered buffers and registered fds.
- The C++-shaped wrapper: RAII over the ring, type-safe
  completion handling, zero-cost cancellation.
- Async gRPC: how the completion queue model maps onto your
  thread pool; common pitfalls (one CQ per service, blocking
  inside a tag handler, RPCs leaking on shutdown).
- `SO_REUSEPORT`: kernel-side load-balanced accept; what it
  buys for high-fan-in services; why you still need to think
  about connection affinity.

## Demo

[`examples/demo-03-io-uring-grpc/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/demo-03-io-uring-grpc)
brings up two services in `podman compose`: a tiny `io_uring`
echo server and an async gRPC service with `SO_REUSEPORT`. `hey`
generates load; the demo prints latency percentiles before and
after each tuning toggle.

## For deeper coverage

- Enberg, *Latency*, ch. 6-7 (the operating-system layer, `io_uring`
  in particular)
- Andrist & Sehr, *C++ High Performance*, ch. 11 (concurrency
  patterns)
- Ghosh, *Building Low Latency Applications with C++*, ch. 8-9 —
  network programming and a worked async I/O ecosystem; concrete
  end-to-end pairing of TCP/UDP code with the kernel-side knobs §8
  covers.

## What's next

§8 stays in the network but moves down the stack: kernel
parameters and the cost of veth pairs.
