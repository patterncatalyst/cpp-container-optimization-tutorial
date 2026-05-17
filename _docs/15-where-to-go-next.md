---
title: Where to Go Next
order: 15
description: What to read next, and the broader ecosystem this tutorial only scratched.
duration: "3 minutes"
---

## You've finished

You can build, ship, observe, and tune a C++23 service in a
rootless Podman container, on a Linux host, and reason about the
levers from compile time to runtime cgroup. That's a lot.

## The four reference books

If you want one to read next, in order of how directly each
extends what we did:

- **Andrist & Sehr, *C++ High Performance, 2nd Edition*** —
  the closest analogue to this tutorial in book form, with
  more language depth and less container context. Particularly
  ch. 6 (CPU/micro-arch), ch. 7 (memory), ch. 11 (concurrency).
- **Enberg, *Latency: Reduce delay in software systems*** — the
  systems-side complement. Where this tutorial said "use
  `io_uring`," Enberg explains *why* the syscall model has been
  the bottleneck and what alternatives have looked like.
- **Ghosh, *Building Low Latency Applications with C++*** — a
  full worked example: a complete low-latency trading ecosystem
  built from scratch in modern C++. The trading domain is
  incidental; the value is seeing every pattern this tutorial
  introduced (memory pools, lock-free queues, busy-spin, NUMA
  placement, kernel bypass) composed into one running system. Read
  it after this if you want to see the patterns at full scale,
  before it if you want a worked example to compare ours against.
- **Iglberger, *C++ Software Design*** — what to do once your
  service is fast. The architectural patterns that survive scale
  and that don't paint you into ABI corners.

For the full annotated bibliography — extended treatment of each
book, suggested reading orders depending on where you're starting
from, and a section-by-section cross-reference of which book this
tutorial points at where — see the
[**Bibliography page**]({{ '/bibliography/' | relative_url }}).

## Topics deliberately skipped

- **Coroutines (C++20).** Worth a tutorial of their own; the
  async-gRPC story in §7 used callbacks and completion queues
  rather than coroutines for clarity.
- **GPU offload.** Out of scope; the deltas in this tutorial all
  live on the CPU side.
- **Kubernetes.** cgroups v2 and Podman pods are your mental
  model; the translation to k8s is mostly mechanical, but it has
  its own footguns (`requests` vs `limits`, the OOM killer
  semantics in QoS classes).
- **Distributed tracing across services.** §9 instruments one
  service. Tempo + OTel propagators do the cross-service part;
  the patterns are the same, the wiring is more.

## Final pointer

The reconciliation plan in [`_plans/`](../../plans/reconciliation-plan/)
is the truthful state of this tutorial — what's verified versus
what's drafted. If you found a claim that doesn't match what
your machine does, please open an issue with the section and
your `uname -r` and `lscpu` output.
