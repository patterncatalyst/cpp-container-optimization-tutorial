---
title: "Outline & reading order"
order: 0
description: How this tutorial is organised, what each section covers, the 1.5h vs 3h presentation cuts, and what's deliberately out of scope.
duration: "10 minutes"
---

This page is the map. Read it once before you start, and come back
whenever you lose your place. Every section ends with a prev/next bar
that links you here through §1, but if you want a bird's-eye view of
where any one section sits in the whole, this is the page.

## How the tutorial is organised

The tutorial is split into **fifteen numbered sections** under
[`_docs/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/_docs).
The sections are designed to be **read and executed in order** —
each one builds on the state your machine is in when you finish the
previous one. There is no separate lab environment: your Fedora 44
workstation is the lab from start to finish.

Six **runnable demos** under
[`examples/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples)
are pulled in by name from the sections that need them. Each demo is
a self-contained Podman project with its own `./demo.sh`, its own
Containerfile(s), and the CMake / Conan plumbing to build hermetically.
You can run the demos as you read, run them all in a final pass, or
skip them entirely on a first read and come back later.

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

## Two delivery targets

This material exists in two parallel forms, and the difference matters
for how you read:

| Target          | Time budget                | What it is                                                                                       |
|-----------------|----------------------------|--------------------------------------------------------------------------------------------------|
| **PPTX deck**   | 1.5–3 hours, live          | A guided tour of the most important sections, with pre-recorded demo videos in the 1.5h cut and live demo runs in the 3h cut. |
| **This site**   | Untimed                    | The comprehensive long-form reference. Every code listing, every command, the full reconciliation plan. Read at your own pace. |
| **The demos**   | Each runs in 30s–8 minutes | Self-contained Podman projects you can run independently of either delivery target.              |

Per-section "duration" fields here are **reading time** for the site,
not talking time for the deck. The deck's pacing is documented in
[the PRD](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/blob/main/PRD.md#5-scope-and-section-outline).

### The 1.5-hour PPTX cut

A pragmatic short version that hits the highest-leverage material
and uses pre-recorded video for everything else:

- §0 Outline — 2 min
- §1 Prerequisites — 5 min (skip the demo; show host-check video)
- §2 Introduction & mental model — 8 min
- §4 Container strategy + Demo 1 video — 12 min
- §7 Memory management — 15 min
- §8 I/O latency + Demo 3 video — 15 min
- §10 Observability + Demo 4 video — 15 min
- §14 Pitfalls highlights — 10 min
- §15 Where to go next — 3 min
- Q&A buffer — 5 min

Topics linked to but not visited live: §5 (LTO/PGO theory mentioned in
§4), §6 (STL silent overhead — link to site), §9 (kernel parameters),
§11 (noisy neighbors), §12 (analysis), §13 (ABI).

### The 3-hour PPTX cut

Every section walked through, every demo run live. Talk-time totals
**2h 46m**; the rest is Q&A, room reset, and slack for live-demo
overruns.

## The fifteen sections

### §0 — Outline (this page)

The map. Don't skip it on your first read.

### [§1 — Prerequisites](../01-prerequisites/)

Set up Fedora 44, Podman 5.x rootless, GCC 14 / Clang 18 toolchain,
Conan 2, CMake, Ninja, and the supporting tools (`hey`, `jq`, `curl`,
`bpftrace`, `libabigail`). Configure rootless cgroups v2 delegation,
verify your kernel has io_uring multishot, and run the host-check
script that confirms everything's wired correctly before you touch
the demos.

If you're on a different distro, this is the section that tells you
what won't work. (Spoiler: macOS via `podman machine` works for the
container parts and breaks for the kernel-feature parts.)

### [§2 — Introduction & mental model](../02-introduction/)

Why container constraints change C++ performance reasoning. The
**four-layer model** that frames the rest of the tutorial:
**compile time → image layout → kernel boundary → runtime isolation.**
Where each performance lever lives. Why advice that's correct on
bare metal can be actively wrong inside a container.

### [§3 — RAII & container resource discipline](../03-raii-discipline/)

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

### [§4 — Container strategy: UBI, ubi-micro, multi-stage builds](../04-image-strategy/)

Demo 1 territory. When to use UBI vs UBI-micro, why
multi-stage builds matter for both image size and supply chain,
and the **AVX-512 mismatch trap** that bites builds promoted from
a builder host with newer silicon to a runtime host without it.

### [§5 — Compile-time wins: LTO, PGO, constexpr](../05-compile-time-wins/)

Still Demo 1. What LTO actually does, why thin LTO is usually the
right default, when PGO is worth the extra build phase, and what
`constexpr` buys you that ordinary `inline` doesn't. Includes the
full PGO instrumentation flow: build instrumented → run training
workload → merge profiles → rebuild optimized.

### [§6 — STL, layout, and C++20/23 containers](../06-stl-layout/)

Demo 2 territory. `std::vector` vs `std::deque` cache behaviour;
when C++23's `flat_map` and `flat_set` win and when they lose;
the **silent memory overhead** of node-based containers; the
allocator-aware refactoring story for hot data structures.

### [§7 — Memory management: allocators, huge pages, cgroups v2, OOM](../07-memory-management/)

Still Demo 2. PMR allocators, transparent huge pages, mimalloc
and jemalloc as `LD_PRELOAD` swaps, **cgroups v2 `memory.max` vs
`memory.high`**, why glibc holds onto memory and how `malloc_trim`
reclaims it, the **RSS / working set / `memory.current` distinction**,
and the **LinuxMemoryChecker pattern** for keeping your service a
safe distance below the OOM ceiling.

### [§8 — I/O latency: io_uring, async gRPC, SO_REUSEPORT](../08-io-latency/)

Demo 3 territory. The submission queue / completion queue model,
multishot accept and multishot recv, provided buffer rings, async
gRPC's completion-queue API, and `SO_REUSEPORT` for letting the
kernel distribute connections across worker processes.

### [§9 — Networking & kernel parameters](../09-networking-kernel/)

Still Demo 3. The cost of **veth pairs vs `--network=host`** in
rootless Podman, the sysctls that matter for low-latency C++
services (`net.core.somaxconn`, TCP timestamps and SACK,
`net.ipv4.tcp_rmem` / `tcp_wmem`), and where the comparison
between rootless and rootful networking actually lives.

### [§10 — Observability & profiling: Grafana stack, perf, eBPF](../10-observability-profiling/)

Demo 4 territory. The full Grafana / Prometheus / Mimir / Tempo /
Loki stack via `podman compose`, OTLP/gRPC instrumentation from C++,
and three host-side observability layers that complement application
metrics: `perf` for CPU sampling, `bcc-tools` for off-CPU and syscall
analysis, and `bpftrace` for ad-hoc kernel probes.

### [§11 — Noisy neighbor isolation: cgroups, CPU pinning, NUMA](../11-noisy-neighbors/)

Demo 5 territory. The two-tenant scenario: a latency-sensitive
service next to a CPU/memory-bound noisy neighbor. **`cpu.weight`,
`io.weight`, `cpuset.cpus`**, `numactl --membind`, and what each
knob actually controls under contention.

### [§12 — Static analysis & debugging in containers](../12-analysis-debugging/)

Demo 6 territory. cppcheck and clang-tidy as build stages, gtest
+ gmock as a separate build target, **AddressSanitizer / UBSan /
MSan / TSan** with a slowdown comparison table, **Valgrind**
trade-offs, **Meta's Object Introspection** for the silent-overhead
pitfalls from §6, and the **ephemeral gdb sidecar** pattern for
attaching to a running container without putting `gdb` into the
runtime image.

### [§13 — Reproducibility & ABI: Conan, CMake presets, hermetic builds](../13-reproducibility-abi/)

Still Demo 6. Conan 2 lockfiles for fully-pinned dependencies,
CMake presets for build-environment portability, and **`abidiff`
from libabigail** for catching silent ABI breaks before they reach
production. The mental model: every binary you ship should be
rebuildable byte-for-byte from a commit and a lockfile.

### [§14 — Pitfalls](../14-pitfalls/)

The traps that catch experienced people: AVX-512 instruction-set
mismatch between builder and runtime host, abstraction overhead
from misjudged virtual interfaces, build-time delays from
unbounded layer cache miss patterns, and a few smaller ones.
Each pitfall is presented as **symptom → root cause → fix**, in
the runbook style §12's "distroless gotchas" page in the
hummingbird-tutorial popularised.

### [§15 — Where to go next](../15-where-to-go-next/)

Pointers to the four reference books we draw on, what each is
strongest at, and what topics this tutorial deliberately doesn't
cover (coroutines, Kubernetes, distributed tracing, GPU offload).

## What this tutorial deliberately does not cover

A few things are out of scope on purpose:

- **C++ language tutorials.** We assume idiomatic C++17 and a
  working knowledge of templates, RAII, move semantics, and the STL.
  If you're newer to C++, [cppreference.com](https://en.cppreference.com)
  and [Andrist & Sehr's *C++ High Performance, 2e*](#) are the right
  starting points.
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

- **45 minutes to 1.5 hours** for §0–§2 (the prerequisites and the
  mental model)
- **2 to 3 hours** for §4–§7 (Demo 1 and Demo 2; the bulk of the
  compile-time and memory material)
- **1.5 to 2.5 hours** for §8–§10 (Demo 3 and Demo 4; I/O, networking,
  and the full observability stack)
- **2 to 3 hours** for §11–§14 (Demos 5 and 6, plus the pitfalls
  reference)
- **15 minutes** for §15

Total reading + running time: **roughly 7–10 hours**, spread over
however many sittings you want. The first three rows are the
recommended first pass; the rest can wait until you have a real
reason to reach for them.

## Appendices

- **Appendix A — Conan, autotools, and UBI 9's minimal perl.** The
  operational survival guide for a hazard that bit demo-04 hard
  during development: when Conan from-source-builds a dep that
  uses autotools (libcurl, c-ares, openssl, nghttp2, …) on UBI 9,
  the build fails on missing perl modules. The appendix has the
  complete fifteen-module shopping list, three simplifying
  alternatives, and a worked libcurl example. Read this one before
  attempting your own Conan + UBI 9 + autotools-using-dep build;
  save yourself the rounds.

