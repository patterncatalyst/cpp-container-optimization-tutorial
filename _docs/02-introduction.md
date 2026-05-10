---
title: Introduction & Mental Model
order: 2
description: Why container constraints change C++ performance reasoning, and the four-layer model the rest of the tutorial hangs off.
duration: 8 minutes
---

## Why this isn't just C++ tuning

Performance advice in the C++ canon is excellent and almost
entirely written for a single-tenant host. You pick your compiler
flags, you pick your data structures, you measure on a quiet
machine, and the answer you get is the answer you keep.

That model breaks under containers. Your binary was built once,
on a build farm, against a toolchain you didn't pick, for an
instruction set you can only hope matches the host. It runs in a
cgroup that may revoke memory or CPU you thought you owned. It
shares a kernel with neighbours that don't share your latency
goals. The network packet your benchmark assumed was free now
traverses a veth pair before it gets near your process. None of
these are catastrophic — but each one nudges your tail latency
and silently invalidates a measurement.

This tutorial is structured around four layers, in the order the
photons hit them:

{% include excalidraw.html name="02-introduction-four-layers" caption="The four-layer model: toolchain, image, kernel, runtime" %}

1. **Toolchain.** Compiler, linker, optimization passes, profile
   data. Sections 4 and 12 live here.
2. **Image.** What you packaged. Base image, layers, ABI labels,
   the libraries inside. Section 3 lives here.
3. **Kernel.** The host kernel your container shares. `io_uring`,
   sysctls, cgroup controllers, NUMA. Sections 7, 8, 10 live here.
4. **Runtime.** What's running right now. The cgroup the runtime
   put you in, the CPUs it pinned you to, the memory ceiling, the
   network namespace. Sections 6, 9, 10, 11 live here.

Each tuning knob in the rest of the tutorial sits at exactly one
of these layers. Most production tail-latency stories I've seen
come from a knob at one layer being measured against a workload
shaped by a different layer.

## What "fast" means here

Three different things, frequently conflated:

- **Throughput.** Requests per second a container can sustain at
  saturation. The number leadership cares about.
- **Latency.** Time from request to response. p50, p99, p99.9.
  The number on-call cares about.
- **Cost.** Cycles per request, bytes per request, joules per
  request. The number FinOps cares about.

Improving one almost always means trading the others. The
observability stack in §9 exists to keep you honest about which
one you're moving.

## Reference pointers

For deeper grounding before you continue:

- Enberg, *Latency*, ch. 1-2 — the language for talking about
  latency budgets at all.
- Andrist & Sehr, *C++ High Performance*, ch. 1-3 — the
  measurement discipline this tutorial assumes you have.

## What's next

§3 starts at the image layer. Pick a base; everything else
follows.
