# Product Requirements Document — Optimizing Modern C++ with Containers

> Source brief: a 1.5-3 hour technical presentation + companion
> tutorial site teaching modern-C++ performance work inside
> rootless OCI containers, end-to-end on Fedora 44 with Podman.

---

## 1. Summary

**One sentence:** A 1.5–3 hour PPTX presentation, an untimed companion
Jekyll tutorial site, and six runnable Podman demos that teach
intermediate C++ engineers how to reason about and measure C++20/23
performance under realistic container constraints.

**Two delivery targets — calibrate the work to the right one.**

| Target            | Time budget                            | Source of truth                                | What lands here                                                            |
|-------------------|-----------------------------------------|-------------------------------------------------|-----------------------------------------------------------------------------|
| **PPTX deck**     | 1.5–3 hours when delivered live         | Generated from the section content + diagrams   | Pre-recorded demo videos, screenshots from a real run, the diagrams as slides |
| **Jekyll site**   | As long as it needs to be (no cap)      | The `_docs/` collection, written for self-paced reading | Full prose, every code listing, every command, the reconciliation plan       |
| **Demos**         | Each is a standalone runnable example   | `examples/demo-XX-*/`                           | Live during the talk *or* skipped in favor of pre-recorded video; always available for the reader to run themselves |

The relationship: the site is the comprehensive reference; the deck is
a curated path through it; the demos are examples used in both. Per-
section "duration" fields in `_docs/` are the **reading time** estimate
for the site, not the talking time for the deck. The deck's pacing is
its own concern — see §3's "Two delivery paths" subsection for how the
1.5h and 3h cuts relate.

**One paragraph:** C++ performance advice is plentiful but almost
always assumes a bare-metal mental model — a single tuned host, a
single workload, the kernel doing what you expect. In production
that workload is one of dozens sharing a host, the toolchain comes
from an OCI image, the binary may be built for an instruction set
the host doesn't have, and the kernel parameters that decide your
tail latency live three layers of abstraction away in cgroups v2.
This tutorial closes that gap. It walks through compile-time
choices (LTO, PGO, `constexpr`), data-structure choices (C++23
`flat_map`, PMR allocators, huge pages), I/O choices (`io_uring`,
async gRPC, `SO_REUSEPORT`), and isolation choices (cgroups, CPU
pinning, NUMA, veth) — each tied to a runnable demo that the reader
can reproduce on their own laptop with Podman, and each measured
with the same Grafana + Prometheus + Tempo + Loki + Mimir stack
they'd use in production.

---

## 2. Problem statement

### Who is the reader?

A working C++ engineer (mid-level or senior) who already knows the
language well enough to write idiomatic C++17 and is comfortable on
the Linux command line. They've heard of LTO, `io_uring`, and
cgroups v2, but they've never sat down and measured the difference
the way the tutorial walks them through. They have a Fedora 44
laptop or workstation, Podman installed, and ideally an x86_64
machine with at least 8 cores so the noisy-neighbor demo has
something to neighbor. They are not container experts — they may
have written a `Containerfile` once, but the difference between
`scratch` and a UBI base, or what cgroups v2 actually does, is a
fuzzy region for them. They're picking up this tutorial because
they were asked to make a service faster, or they're preparing for
a perf-focused interview, or they're allergic to advice they can't
reproduce on their own machine.

### What's their pain today?

The good C++ performance and low-latency books (Andrist & Sehr,
Iglberger, Enberg, Ghosh)
are excellent on the language and on system-level latency, but they
predate or set aside the container reality most production C++ now
runs in. The good container books are language-agnostic and rarely
go deeper than "use a small base image." The result is engineers
who copy a `Containerfile` from a blog post, set CPU limits because
the platform team told them to, and then wonder why their p99
latency doubled in production. They lack a coherent, runnable
mental model that connects compile-time decisions to image layout
to runtime cgroup configuration to observed tail latency.

### Why now?

C++23 is shipping in mainline toolchains; Fedora 44 ships GCC 14
and a recent Clang, and Conan 2.x has stabilized lockfiles and
CMake presets enough to teach hermetic builds without footnotes.
`io_uring` is no longer experimental. cgroups v2 is the default on
Fedora and on most container runtimes. The pieces that used to be
separate manuals fit together now, and the tutorial captures that
moment.

---

## 3. Goals and non-goals

### Goals

- A reader who finishes the tutorial can build a C++23 service
  image with LTO and PGO enabled, run it under Podman with
  appropriate cgroup limits, instrument it with the bundled
  Grafana stack, and explain why each tuning knob exists.
- A reader who finishes can reproduce every measurement in the
  tutorial on their own Fedora 44 host without consulting other
  resources.
- All six demos run end-to-end via `./demo.sh` on Fedora 44 with
  Podman 5.x, rootless, no manual fixups.
- Every section has a paired Excalidraw diagram (SVG + JSON) that
  is consistent across the Jekyll site and the PPTX deck.
- The PPTX deck can be delivered in 1.5 hours (high-level pass,
  pre-recorded demo videos, no live demos) or in 3 hours (every
  demo run live, full Q&A allowance). The Jekyll site is the
  comprehensive long-form reference and is not constrained by talk
  time.

### Non-goals

- This tutorial does NOT teach C++. It assumes idiomatic C++17 and
  a working knowledge of templates, RAII, move semantics, and the
  STL.
- This tutorial does NOT teach Podman from scratch. It assumes the
  reader can run `podman run` and write a basic `Containerfile`.
- This tutorial does NOT compare Podman with Docker, GCC with
  Clang, or Conan with vcpkg. Tooling choices are stated and
  defended in §1; readers wanting comparisons can do them
  themselves.
- This tutorial does NOT cover Kubernetes. cgroups v2 and Podman
  pods are the deployment mental model. Translating to k8s is
  mentioned only in passing.
- This tutorial does NOT cover Windows or macOS hosts as primary
  platforms. macOS via `podman machine` is acknowledged but not
  exercised; AArch64 is acknowledged but x86_64 is the demo
  baseline (especially for the AVX-512 pitfall section).

---

## 4. Audience details

### Primary audience

Mid-level to senior C++ engineers on Linux who ship services in
containers and want a coherent mental model spanning compile time,
image layout, kernel, and runtime isolation. Comfortable with
`gdb`, `perf`, basic kernel tuning, and writing a `Containerfile`.
Wants to measure things, not be told.

### Secondary audience

Platform/SRE engineers who own the container runtime and want to
understand what the C++ teams they support are asking for, and
why. Most of the section content lands; the deeper language
sections (allocators, `constexpr`, `flat_map`) can be skimmed
without losing the operational thread.

### Audience NOT served

- C++ beginners — a separate prerequisite
- Engineers without a Linux host — Fedora 44 is the baseline; WSL
  works for the language sections but breaks the cgroup, NUMA,
  and `io_uring` demos
- Engineers looking for a Kubernetes performance tuning guide

---

## 5. Scope and section outline

The duration column below is **PPTX talk-time per section** — what it
takes to walk an audience through the section in the live deck. The
Jekyll site has its own per-section reading time in the front-matter
of each `_docs/*.md` file (often longer; reading is more thorough than
talking).

**PPTX total estimated talk time: 2h 46m** (the 3-hour cut, with every
demo run live).

**1.5-hour PPTX cut**: keep §0–2, §3 + Demo 1 video, §6, §7 + Demo 3
video, §9 + Demo 4 video, §13 highlights, §14. Skip §4 (PGO can be
mentioned in passing), §5 (link to site), §8, §10–§12 (link to site
and the demos for self-paced runs).

**Jekyll site total**: untimed. Read top-to-bottom or sample by
section; every section is self-contained enough to enter cold.

### Sections

| §  | Title                                                              | Purpose                                                                            | PPTX talk | Demo |
|----|--------------------------------------------------------------------|------------------------------------------------------------------------------------|-----------|------|
| 0  | Outline                                                            | Reader's map; what to expect, what's out of scope                                  | 2 min     | —    |
| 1  | Prerequisites                                                      | Fedora 44, Podman 5.x, the toolchain (GCC 14 / Clang 18, Conan 2, CMake, Ninja)    | 10 min    | —    |
| 2  | Introduction & Mental Model                                        | Why container constraints change C++ perf reasoning; the four-layer model          | 8 min     | —    |
| 3  | Container Strategy: UBI, ubi-micro, multi-stage builds               | When to use which base; layer caching; the AVX-512 mismatch trap                   | 12 min    | 1    |
| 4  | Compile-Time Wins: LTO, PGO, constexpr                             | What each does, when each is worth the build-time tax, instrumentation runs        | 12 min    | 1    |
| 5  | STL, Layout, and C++20/23 Containers                               | `std::vector` vs `std::deque`, C++23 `flat_map`/`flat_set`, silent overhead        | 15 min    | 2    |
| 6  | Memory Management: Allocators, Huge Pages, cgroups v2, OOM        | PMR, `madvise(MADV_HUGEPAGE)`, mimalloc/jemalloc, `memory.max`, `malloc_trim()`, OOM killer, RSS vs working set, the LinuxMemoryChecker pattern | 15 min    | 2    |
| 7  | I/O Latency: io_uring, Async gRPC, SO_REUSEPORT                    | Where syscall overhead actually lives; building blocks for low-tail-latency I/O    | 15 min    | 3    |
| 8  | Networking & Kernel Parameters                                     | veth pairs vs host networking, sysctl tuning, when to use `--network=host`         | 10 min    | 3    |
| 9  | Observability & Profiling: Grafana Stack, perf, eBPF               | The compose stack; OTel from C++; `perf`, `bcc`, `bpftrace` against containers     | 15 min    | 4    |
| 10 | Noisy Neighbor Isolation: cgroups, CPU pinning, NUMA               | Two-tenant scenario; cpuset, cpu.weight, io.weight, `numactl --membind`            | 12 min    | 5    |
| 11 | Static Analysis & Debugging in Containers                          | cppcheck + clang-tidy pipeline; AddressSanitizer/Valgrind in containers; Meta's Object Introspection; ephemeral gdb sidecar; gdbserver | 15 min    | 6    |
| 12 | Reproducibility & ABI: Conan, CMake Presets, Hermetic Builds       | Conan lockfiles, CMake presets, ABI tracking with `abidiff`, hermetic CI           | 12 min    | 6    |
| 13 | Pitfalls: AVX-512 mismatch, abstraction overhead, build delays     | The traps people fall into and how each one shows up in the metrics                | 10 min    | —    |
| 14 | Where to Go Next                                                   | Pointers to deeper resources; the four reference books                             | 3 min     | —    |

**PPTX 3-hour cut total: 2h 46m talk time** (excluding Q&A, room reset, and live-demo overrun).

### Optional appendices

- A: A short PMR allocator cookbook
- B: kernel parameter cheat-sheet for low-latency C++ services
- C: a worked example of catching an ABI break with `abidiff` in CI

---

## 6. Runnable examples

### Will this tutorial have runnable code examples?

Yes — six demos, each self-contained under `examples/<demo>/` with a
single entry point `./demo.sh` plus a corresponding test script
under `scripts/test-<demo>.sh` for CI verification.

### The six demos

| # | Name                | Topic mapping                                                                                                                  | Runs via                                |
|---|---------------------|--------------------------------------------------------------------------------------------------------------------------------|-----------------------------------------|
| 1 | image-strategy      | UBI vs UBI-micro, multi-stage, LTO, PGO, ABI labels — §3, §4, §12                                                                | `podman build` + `podman run`           |
| 2 | stl-layout          | `std::vector` vs `boost::container::flat_map` vs `std::unordered_map` cache-locality benchmark with cgroup memory pressure — §6 (PMR/huge pages/mimalloc moved to §7 prose since demo-02's scope tightened to STL-only — see _plans/reconciliation-plan.md r55) | `podman run` with cgroup limits         |
| 3 | io-uring-grpc       | io_uring TCP echo + async gRPC service with `SO_REUSEPORT`; `hey` for load — §7, §8                                            | `podman compose up` (2 services)        |
| 4 | observability       | The full stack: Grafana + Prometheus + Tempo + Loki + Mimir; OTel-instrumented C++ service; `perf record` + `bpftrace` probes  | `podman compose up` (full stack)        |
| 5 | isolation           | Noisy neighbor: two C++ services contending for CPU + memory + I/O; `--cpuset-cpus`, `cpu.weight`, NUMA pinning, veth latency  | `podman compose up` (2 tenants + load)  |
| 6 | quality-pipeline    | cppcheck + clang-tidy + googletest/gmock + abidiff + hermetic Conan/CMake build + gdbserver sidecar — §11, §12                 | `podman build` + `podman run` (CI-shaped) |

### Languages and tools

- **C++23** as the primary language target; C++20 features called
  out where C++23 isn't yet stable
- **GCC 14** (default on Fedora 44) and **Clang 18** (alternate);
  per-demo specifies
- **CMake 3.28+** with presets, **Ninja** as the generator
- **Conan 2.x** for dependencies, lockfiles for reproducibility
- **googletest** and **gmock** for tests
- **gRPC** (C++) for the network demo; auto-generated stubs via
  Conan
- **Podman 5.x** + **Podman Compose** as the runtime; rootless
- Load gen with **`hey`**; JSON munging with **`jq`**
- Observability: **Grafana**, **Prometheus**, **Tempo**, **Loki**,
  **Mimir** — all official upstream images via `podman compose`

### Test strategy

- [x] Per-demo test scripts under `scripts/test-demo-NN-*.sh`
  following the skeleton's pattern (source `lib/_helpers.sh`,
  `set -euo pipefail`, EXIT trap for cleanup, distinct ports)
- [x] Aggregator script `scripts/test-all-demos.sh` that runs each
  test in sequence and prints a summary; does NOT fail-fast
- [ ] CI integration via GitHub Actions in `.github/workflows/`
  using a self-hosted runner or a Fedora 44 container, since the
  cgroup and `io_uring` demos need a real Linux host
- [x] Manual verification on at least one fresh Fedora 44 VM
  before any section is marked verified in the reconciliation plan

---

## 7. Diagrams

Yes — paired SVG + Excalidraw JSON, embedded in both the Jekyll
site and the PPTX deck.

Naming convention: `<section-number>-<topic>-<thing>.svg` and the
matching `.excalidraw`. Both files live under `diagrams/`.
The Jekyll `excalidraw.html` include from the skeleton renders the
SVG inline and offers a "Download Excalidraw source" link.

### Anticipated diagrams (one per section minimum)

- `02-mental-model-four-layers.svg` — the four-layer model
  (toolchain, image, kernel, runtime)
- `03-image-strategy-multistage.svg` — base image trade-off
  matrix
- `04-compile-pgo-flow.svg` — instrumented build → workload →
  optimized build pipeline
- `05-stl-layout-cache-lines.svg` — `vector<T>` vs `flat_set<T>`
  vs `unordered_map<T>` cache footprint
- `06-allocator-stack.svg` — application → PMR resource → upstream
  → cgroup memory.high
- `07-io-uring-submission.svg` — submission queue / completion
  queue mental model
- `08-veth-vs-host-networking.svg` — packet path difference
- `09-observability-stack.svg` — the Grafana + Prometheus + Tempo +
  Loki + Mimir compose graph
- `10-noisy-neighbor-cgroup-tree.svg` — cgroup hierarchy with two
  tenants and the load generator
- `11-debug-sidecar-pattern.svg` — ephemeral gdbserver sidecar
  attaching to a running pod
- `12-hermetic-build-flow.svg` — Conan lockfile + CMake preset +
  multi-stage build → labeled image
- `13-avx512-mismatch.svg` — the SIGILL trap visualized

For the PPTX deck, the same SVGs are dropped onto each section's
title slide via the `pptx` skill flow.

---

## 8. Success metrics

### Verification metrics

- All six demos pass `scripts/test-all-demos.sh` on Fedora 44 with
  Podman 5.x rootless
- Reconciliation plan shows every section row as `verified`
- §1 prerequisites instructions tested on a fresh Fedora 44 VM and
  on Fedora 44 Silverblue (toolbox)
- The PPTX export builds cleanly from the Jekyll site content
  without manual edits to slide layout
- Every section has a paired diagram in `diagrams/`

### Adoption metrics (slow signals)

- Tutorial linked from at least one C++ community resource
  (cppreference talk page, isocpp.org, /r/cpp)
- At least one independent reader posts a successful end-to-end
  run without filing an issue

---

## 9. Constraints and dependencies

### Technical constraints

- Fedora 44 is the **only** primary platform; Fedora 43 is best-
  effort. Other distros are out of scope.
- Podman 5.x rootless is the **only** runtime path; Docker is not
  exercised. The compose file uses Podman Compose syntax.
- All examples must run rootless. Anything requiring root is
  flagged in the section and an unprivileged alternative is given.
- No example may require paid services, hosted accounts, or
  registries behind a paywall.
- x86_64 is the demo baseline. AArch64 is acknowledged in §3 and
  §13 (instruction set mismatch) but not exercised end-to-end.
- The observability stack must come up cleanly with
  `podman compose up` from a single `compose.yml` and no manual
  curl-the-Grafana-API steps.

### Editorial constraints

- Vendor-neutral language. No comparisons to specific competitor
  products (Docker, vcpkg, Bazel) — readers can compare for
  themselves.
- Code examples are copy-pasteable without modification.
- No "we" voice; reader is "you", everything else is third-person
  or passive.
- Diagrams are SVG, not PNG, with the editable `.excalidraw`
  source paired alongside.
- All example commands run as a non-root user.
- All claims about kernel behavior, syscall costs, or compiler
  flags are reproducible by the reader from the runnable demos —
  no hand-waving "this is faster, trust me."

### Reference materials cited (must be honored, not paraphrased into
displacement)

- Andrist & Sehr, *C++ High Performance, 2nd Edition*
- Iglberger, *C++ Software Design*
- Enberg, *Latency: Reduce delay in software systems*
- Ghosh, *Building Low Latency Applications with C++: Develop a complete low latency trading ecosystem from scratch using modern C++* (Packt, 2023)

The tutorial points readers to specific chapters of these books for
deeper coverage of any topic the tutorial only introduces. The
tutorial is positioned as a runnable companion, not a replacement.

Ghosh's book complements Enberg's: where Enberg covers latency as a
general-systems problem, Ghosh walks through a concrete low-latency
C++ ecosystem (trading-system framing, but the patterns —
lock-free queues, custom memory pools, busy-spin vs futex, NIC
configuration — generalize). It's the natural pointer for §6 (memory
pools), §7 (I/O latency), and §10 (CPU pinning, NUMA) for readers who
want a full worked example outside the container framing.

### Dependencies

- Fedora 44 RPM availability of: `gcc-14`, `clang`, `cmake`,
  `ninja-build`, `conan`, `podman`, `podman-compose`, `perf`,
  `bcc-tools`, `bpftrace`, `libabigail` (for `abidiff`)
- Quay.io / RedHat registry for the UBI base images
  (`registry.access.redhat.com/ubi9-minimal`, `ubi9-micro`)
- Docker Hub / quay.io for upstream images: `grafana/grafana`,
  `grafana/tempo`, `grafana/loki`, `grafana/mimir`,
  `prom/prometheus`
- `hey` available as a Fedora package or as a binary the demo
  fetches

If the UBI registry becomes unavailable mid-tutorial, the demos
fall back to Fedora minimal images and the section notes the
substitution.

---

## 10. Risks and mitigations

| Risk                                                                           | Impact | Likelihood | Mitigation                                                                                       |
|--------------------------------------------------------------------------------|--------|------------|--------------------------------------------------------------------------------------------------|
| Podman 5.x compose syntax drifts during the writing window                     | Med    | Med        | Pin Podman version in §1; reconciliation plan tracks the version that verified each demo         |
| Fedora 44 ships a GCC version that breaks one of the C++23 examples            | Med    | Low        | Each demo specifies its compiler in `CMakePresets.json`; fallback to Clang 18 documented         |
| io_uring demo behaves differently on older kernels (5.4 vs 6.x)                | Med    | Low        | §7 prereq pins kernel feature flags; demo refuses to run if `/proc/version` < 6.0                |
| AVX-512 demo SIGILLs on the presenter's machine                                | Low    | Med        | Demo intentionally produces this; `--cpu-set` flag or `-march=` override documented              |
| Reader is on macOS via `podman machine` and the cgroup demos don't behave      | Med    | High       | §1 explicitly warns; §10 (noisy neighbor) marked "Linux host required"                           |
| Reference books cited too closely, drifting toward displacement summary        | High   | Low        | Editorial pass: every cite is a pointer ("see Iglberger ch. 4 for the full pattern"), never a substitute |
| Tutorial too long; readers don't finish                                        | High   | Med        | Sectioned so partial reads work; outline calls out the 1.5h vs 3h paths                          |
| Tutorial too compressed; misses the "why"                                      | Med    | Med        | Each section opens with a "why this matters" and closes with a measurable claim                  |
| AVX-512 vs AVX2 vs `-march=native` confuses readers without recent CPUs        | Med    | Med        | §13 includes `lscpu | grep avx` as the first step and a tested fallback flag set                 |
| The grpc + io_uring demo build time exceeds reasonable patience in a live demo | Med    | High       | Pre-built layer published; demo.sh detects and pulls instead of rebuilding                       |

---

## 11. Timeline and milestones

| Milestone                                                       | Est. effort      | Done? |
|-----------------------------------------------------------------|------------------|-------|
| PRD reviewed and approved                                       | 1-2 hours        | [x]   |
| Skeleton scaffolded; \_config.yml, layouts, includes branded    | 2-3 hours        | [ ]   |
| §1 prerequisites drafted and verified on fresh Fedora 44        | 3-4 hours        | [ ]   |
| Demo 1 (image-strategy) working end-to-end                      | 6-8 hours        | [ ]   |
| Demo 2 (stl-layout) working end-to-end                          | 8-10 hours       | [x]   |
| Demo 3 (io-uring-grpc) working end-to-end                       | 10-14 hours      | [x]   |
| Demo 4 (observability) compose stack up + OTel C++ wired        | 12-16 hours      | [x]   |
| Demo 5 (isolation) two-tenant scenario reproducible             | 8-10 hours       | [ ]   |
| Demo 6 (quality-pipeline) including abidiff and gdbserver       | 10-12 hours      | [ ]   |
| All §3-§14 sections drafted (zero-draft)                        | 30-40 hours      | [ ]   |
| 13 Excalidraw diagrams drafted, paired SVG exported             | 8-12 hours       | [ ]   |
| All demo test scripts pass under `test-all-demos.sh`            | 4-6 hours        | [ ]   |
| Cross-platform note: Fedora 43 best-effort verification         | 2-4 hours        | [ ]   |
| Editorial pass for tone, voice, vendor-neutrality               | 6-10 hours       | [ ]   |
| PPTX deck exported from the Jekyll content                      | 4-6 hours        | [ ]   |
| Reconciliation plan reflects shipped state                      | 1-2 hours        | [ ]   |
| Public announce                                                 | -                | [ ]   |

**Hard deadline:** TBD by author.
**Realistic launch target:** ~3-4 weeks of part-time work, dominated by demos 3 and 4.

---

## 12. Open questions

- Should the io_uring demo use raw `liburing` or wrap it in
  `boost::asio` (which now has io_uring support)? Raw is
  pedagogically clearer; asio is what readers will reach for in
  practice. Currently planning raw + a sidebar pointing to asio.
- Does the noisy-neighbor demo need NUMA to be visible, or is a
  single-socket workstation enough? If single-socket, the NUMA
  section is theoretical-only; if dual, the demo is sharper but
  fewer readers can reproduce.
- Conan 2 vs Conan 1 pinning: stick with Conan 2 since Fedora 44
  ships it and the lockfile story is cleaner, but verify the
  gRPC recipe's status before committing.
- PGO demo: synthetic load (the `hey` benchmark) or recorded
  production-shaped trace? Synthetic is reproducible; recorded is
  more honest. Currently planning synthetic with a "in production
  you'd record real traffic" callout.
- Should the AVX-512 mismatch demo intentionally crash, or
  intentionally not crash and show a 30% perf delta when run on a
  CPU without the feature? Crash is more memorable; perf-delta is
  more realistic. Leaning crash-with-recovery.

---

## 13. Decision log

| Date       | Decision                                                                  | Rationale                                                                                  |
|------------|---------------------------------------------------------------------------|--------------------------------------------------------------------------------------------|
| 2026-05-09 | Podman 5.x rootless as the only runtime                                   | Default on Fedora 44; rootless covers the production model most readers will deploy under  |
| 2026-05-09 | Fedora 44 as the only primary platform                                    | Removes a class of distro-version footnotes; Fedora ships modern toolchain + cgroups v2     |
| 2026-05-09 | Six demos rather than twelve smaller ones                                  | Each demo has enough surface area to teach; twelve becomes a navigation problem            |
| 2026-05-09 | C++23 as the language target with C++20 fallbacks called out               | Aligns with the "now" in §2's "why now"; GCC 14 supports the relevant features             |
| 2026-05-09 | Grafana stack (Prometheus + Tempo + Loki + Mimir) for observability        | Single vendor's open-source stack; one compose file; one auth model; readers learn it once |
| 2026-05-09 | The three reference books are pointed-at, not summarized                   | Both honest about what this tutorial *is* (a runnable companion) and respects authors' work |
| 2026-05-09 | One Excalidraw diagram per section minimum, paired SVG + JSON              | Source-available, scales for the PPTX, editable without proprietary tooling                |

---

## 14. Stakeholders

| Name           | Role             | What they need                                              |
|----------------|------------------|-------------------------------------------------------------|
| Tutorial author | Author + presenter | The PRD on hand each session; reconciliation plan up to date |
| Reviewer (TBD) | Technical reviewer | A complete zero-draft + a working `test-all-demos.sh` before review |

---

## How to use this PRD

The skeleton's guidance applies. In particular:

- Read this top-to-bottom at the start of each work session to
  recenter on what's in scope.
- When a new idea wants to be added, check §3 ("non-goals") and §5
  (section table) before saying yes.
- Update §13 (decision log) whenever a meaningful trade-off is
  resolved — future-you will want the audit trail.
- The reconciliation plan in `_plans/` is the truth source for
  "what's verified vs. what's claimed." This PRD is "what we
  intended"; the gap is instructive.
