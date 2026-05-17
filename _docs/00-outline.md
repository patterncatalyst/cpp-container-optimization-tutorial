---
title: "Outline & reading order"
order: 0
description: How this tutorial is organised, what each section covers, the 3-hour presentation budget, and what's deliberately out of scope.
duration: "10 minutes"
---

This page is the map. Read it once before you start, and come back
whenever you lose your place. Every section ends with a prev/next bar
that links you here through §1, but if you want a bird's-eye view of
where any one section sits in the whole, this is the page.

## How the tutorial is organised

The tutorial is split into **sixteen numbered sections** plus an
appendix under
[`_docs/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/_docs).
The sections are designed to be **read and executed in order** —
each one builds on the state your machine is in when you finish the
previous one. There is no separate lab environment: your Fedora 44
workstation is the lab from start to finish.

Seven **runnable demos** under
[`examples/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples)
are pulled in by name from the sections that need them. Each demo is
a self-contained Podman project with its own `./demo.sh`, its own
Containerfile(s), and the CMake / Conan plumbing to build hermetically.
You can run the demos as you read, run them all in a final pass, or
skip them entirely on a first read and come back later. Each demo
also has a Jekyll-rendered page at
[`/examples/`]({{ '/examples/' | relative_url }}) with cross-references
back to the tutorial sections it deepens.

A small Grafana / Prometheus / Mimir / Tempo / Loki stack lives under
[`observability/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/observability).
Demo 4 brings it up; later demos optionally point at it. You can also
run the stack standalone — useful as a sandbox for your own services.

Within each section, the structure is consistent:

1. **Learning objectives** — what you should be able to do after.
2. **Diagram** — an Excalidraw figure showing the moving parts.
3. **Planned content** — the substance of the section.
4. **Demo** — pointer to the matching `examples/demo-XX-*` directory.
5. **For deeper coverage** — pointers into the four reference books.
6. **What's next** — explicit handoff to the next section.

## Three delivery targets

This material exists in three parallel forms, and the difference
matters for how you read:

| Target          | Time budget                | What it is                                                                                                                       |
|-----------------|----------------------------|----------------------------------------------------------------------------------------------------------------------------------|
| **This site**   | Untimed                    | The comprehensive long-form reference. Every code listing, every command, the full reconciliation plan. Read at your own pace.   |
| **PPTX deck**   | 3 hours, live              | A guided tour through every section with live demo runs. Talk-time totals ~2h 36m; the rest is Q&A, room reset, and slack for live-demo overruns. |
| **The demos**   | Each runs in 30s–8 minutes | Self-contained Podman projects you can run independently of either delivery target.                                              |

Per-section "duration" fields here are **reading time** for the
site, not talking time for the deck. The deck's pacing is documented
in [the PRD](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/blob/main/PRD.md#5-scope-and-section-outline).

## The sections

### §0 — Outline (this page)

The map. Don't skip it on your first read.

### [§1 — Prerequisites]({{ '/docs/01-prerequisites/' | relative_url }})

Set up Fedora 44, Podman 5.x rootless, GCC 14 / Clang 18 toolchain,
Conan 2, CMake, Ninja, and the supporting tools (`hey`, `jq`, `curl`,
`bpftrace`, `libabigail`). Configure rootless cgroups v2 delegation,
verify your kernel has io_uring multishot, and run the host-check
script that confirms everything's wired correctly before you touch
the demos.

If you're on a different distro, this is the section that tells you
what won't work. (Spoiler: macOS via `podman machine` works for the
container parts and breaks for the kernel-feature parts.)

### [§2 — Introduction & mental model]({{ '/docs/02-introduction/' | relative_url }})

Why container constraints change C++ performance reasoning. The
**four-layer model** that frames the rest of the tutorial:
**compile time → image layout → kernel boundary → runtime isolation.**
Where each performance lever lives. Why advice that's correct on
bare metal can be actively wrong inside a container.

### [§3 — RAII & container resource discipline]({{ '/docs/03-raii-discipline/' | relative_url }})

The C++ idiom that the rest of the tutorial assumes. **RAII —
Resource Acquisition Is Initialization** — binds resource
lifetime to object lifetime so cleanup happens on every exit
path: normal returns, early returns, exceptions. Outside a
container, leaking a few file descriptors is cosmetic; inside
a 256 MB cgroup with `nofile=1024` and a service expected to
stay up for weeks, leaks compound into outages. This section
introduces the mechanic, the four resource classes you'll meet
(memory / fds / locks / sockets), the canonical 20-line
`unique_fd` wrapper, and what RAII honestly does *not* save
you from.

### [§4 — Container strategy: UBI, ubi-micro, multi-stage builds]({{ '/docs/04-image-strategy/' | relative_url }})

Demo 1 territory. When to use UBI vs UBI-micro, why
multi-stage builds matter for both image size and supply chain,
and the **AVX-512 mismatch trap** that bites builds promoted from
a builder host with newer silicon to a runtime host without it.

### [§5 — Compile-time wins: LTO, PGO, constexpr]({{ '/docs/05-compile-time-wins/' | relative_url }})

Still Demo 1. What LTO actually does, why thin LTO is usually the
right default, when PGO is worth the extra build phase, and what
`constexpr` buys you that ordinary `inline` doesn't. Includes the
full PGO instrumentation flow: build instrumented → run training
workload → merge profiles → rebuild optimized.

### [§6 — STL, layout, and C++20/23 containers]({{ '/docs/06-stl-layout/' | relative_url }})

Demo 2 territory. `std::vector` vs `std::deque` cache behaviour;
when C++23's `flat_map` and `flat_set` win and when they lose;
the **silent memory overhead** of node-based containers; the
allocator-aware refactoring story for hot data structures.

### [§7 — Memory management: allocators, huge pages, cgroups v2, OOM]({{ '/docs/07-memory-management/' | relative_url }})

Demo 6 territory. PMR allocators, transparent huge pages, mimalloc
as a static-linked `operator new` replacement, **cgroups v2 `memory.max`
vs `memory.high`**, why glibc holds onto memory and how
`malloc_trim` reclaims it, the **RSS / working set / `memory.current`
distinction**, and the **LinuxMemoryChecker pattern** for keeping
your service a safe distance below the OOM ceiling.

### [§8 — I/O latency: io_uring, async gRPC, SO_REUSEPORT]({{ '/docs/08-io-latency/' | relative_url }})

Demo 3 territory. The submission queue / completion queue model,
multishot accept and multishot recv, provided buffer rings, async
gRPC's completion-queue API, and `SO_REUSEPORT` for letting the
kernel distribute connections across worker processes.

### [§9 — Networking & kernel parameters]({{ '/docs/09-networking-kernel/' | relative_url }})

Still Demo 3. The cost of **veth pairs vs `--network=host`** in
rootless Podman, the sysctls that matter for low-latency C++
services (`net.core.somaxconn`, TCP timestamps and SACK,
`net.ipv4.tcp_rmem` / `tcp_wmem`), and where the comparison
between rootless and rootful networking actually lives.

### [§10 — Observability & profiling: Grafana stack, perf, eBPF]({{ '/docs/10-observability-profiling/' | relative_url }})

Demo 4 territory. The Grafana / Prometheus / Mimir / Tempo /
Loki stack via the `grafana/otel-lgtm` all-in-one image, OTLP
instrumentation from C++ (traces, metrics, logs), and three
host-side observability layers that complement application
metrics: `perf` for CPU sampling, `bcc-tools` for off-CPU and
syscall analysis, and `bpftrace` for ad-hoc kernel probes.

### [§11 — Noisy neighbor isolation: cgroups, CPU pinning, NUMA]({{ '/docs/11-noisy-neighbors/' | relative_url }})

Demo 5 territory. The two-tenant scenario: a latency-sensitive
service next to a CPU/memory-bound noisy neighbor. **`cpu.weight`,
`io.weight`, `cpuset.cpus`**, `numactl --membind`, and what each
knob actually controls under contention.

### [§12 — Static analysis & debugging in containers]({{ '/docs/12-analysis-debugging/' | relative_url }})

Demo 7 territory. cppcheck and clang-tidy as build stages, gtest
+ gmock as a separate build target, **AddressSanitizer / UBSan /
MSan / TSan** with a slowdown comparison table, **Valgrind**
trade-offs, **Meta's Object Introspection** for the silent-overhead
pitfalls from §6, and the **ephemeral gdb sidecar** pattern for
attaching to a running container without putting `gdb` into the
runtime image.

### [§13 — Reproducibility & ABI: Conan, CMake presets, hermetic builds]({{ '/docs/13-reproducibility-abi/' | relative_url }})

Still Demo 7. Conan 2 lockfiles for fully-pinned dependencies,
CMake presets for build-environment portability, and **`abidiff`
from libabigail** for catching silent ABI breaks before they reach
production. The mental model: every binary you ship should be
rebuildable byte-for-byte from a commit and a lockfile.

### [§14 — Pitfalls]({{ '/docs/14-pitfalls/' | relative_url }})

The traps that catch experienced people: AVX-512 instruction-set
mismatch between builder and runtime host, abstraction overhead
from misjudged virtual interfaces, build-time delays from
unbounded layer cache miss patterns, and a few smaller ones.
Each pitfall is presented as **symptom → root cause → fix**.

### [§15 — Where to go next]({{ '/docs/15-where-to-go-next/' | relative_url }})

Pointers to the four reference books we draw on (full annotated
treatment at the
[**Bibliography page**]({{ '/bibliography/' | relative_url }})),
and the topics this tutorial deliberately doesn't cover
(coroutines, Kubernetes, distributed tracing, GPU offload).

### [§16 — Appendix A: Conan, autotools, and UBI 9's minimal perl]({{ '/docs/16-appendix-a-conan-ubi9-perl/' | relative_url }})

Reference appendix. The operational survival guide for a hazard
that bit demo-04 hard during development: when Conan from-source-
builds a dep that uses autotools (libcurl, c-ares, openssl,
nghttp2, …) on UBI 9, the build fails on missing perl modules. The
complete fifteen-module shopping list, three simplifying
alternatives, and a worked libcurl example.

## What this tutorial deliberately does not cover

A few things are out of scope on purpose:

- **C++ language tutorials.** We assume idiomatic C++17 and a
  working knowledge of templates, RAII, move semantics, and the STL.
  If you're newer to C++, [cppreference.com](https://en.cppreference.com)
  and [Andrist & Sehr's *C++ High Performance, 2e*]({{ '/bibliography/' | relative_url }})
  are the right starting points.
- **Podman fundamentals.** We assume you can run `podman run` and
  write a basic `Containerfile`. The
  [hummingbird-tutorial](https://patterncatalyst.github.io/hummingbird-tutorial/)
  is an excellent companion if you need that grounding first.
- **Kubernetes.** Cgroups v2 and Podman pods are the deployment
  mental model. Translating to k8s is mostly mechanical (the
  `requests` / `limits` semantics map directly to the cgroup
  controllers we tune), but k8s-specific work is a separate tutorial.
- **macOS as a primary platform.** macOS via `podman machine` works
  for the container parts but breaks the kernel-feature demos
  (cgroups v2, NUMA, `io_uring` multishot). We acknowledge it,
  but Fedora 44 is the demo baseline.
- **Comparisons to other tooling.** Podman vs Docker, GCC vs Clang,
  Conan vs vcpkg — choices are stated and defended in §1; readers
  wanting comparisons can do them themselves.

The [reconciliation plan](../../plans/reconciliation-plan/) tracks
which of these may be added in future iterations and which are
firmly out of scope.

## Estimated time, end-to-end

If you read every section and run every demo, expect:

- **45 minutes to 1.5 hours** for §0–§3 (the prerequisites, mental
  model, and RAII grounding — no demos)
- **1.5 to 2 hours** for §4–§5 (Demo 1; image strategy and
  compile-time wins)
- **1 to 1.5 hours** for §6 (Demo 2; STL and layout)
- **1 to 1.5 hours** for §7 (Demo 6; memory management and
  allocators)
- **1.5 to 2.5 hours** for §8–§10 (Demo 3 and Demo 4; I/O,
  networking, and the full observability stack)
- **1.5 to 2 hours** for §11 (Demo 5; noisy neighbor isolation)
- **2 to 2.5 hours** for §12–§13 (Demo 7; static analysis,
  sanitizers, reproducibility, and ABI)
- **45 minutes** for §14–§15 (pitfalls reference + reading
  pointers)
- **30 minutes** for §16 (appendix, only if you'll be building
  Conan from-source dependencies on UBI 9)

Total reading + running time: **roughly 10–14 hours**, spread over
however many sittings you want. The §1–§3 prereq+mental-model block
plus §4–§5 (Demo 1) is the recommended first pass; the rest can wait
until you have a real reason to reach for them.

