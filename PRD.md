# Product Requirements Document — Optimizing Modern C++ with Containers

> Source brief: a 1.5-3 hour technical presentation + companion
> tutorial site teaching modern-C++ performance work inside
> rootless OCI containers, end-to-end on Fedora 44 with Podman.

---

## 1. Summary

**One sentence:** A 3-hour PPTX presentation, an untimed companion
Jekyll tutorial site, and seven runnable Podman demos that teach
intermediate C++ engineers how to reason about and measure C++20/23
performance under realistic container constraints.

**Three delivery targets — calibrate the work to the right one.**

| Target            | Time budget                            | Source of truth                                | What lands here                                                            |
|-------------------|-----------------------------------------|-------------------------------------------------|-----------------------------------------------------------------------------|
| **PPTX deck**     | 3 hours when delivered live             | Generated from the section content + diagrams   | Pre-recorded demo videos, screenshots from a real run, the diagrams as slides |
| **Jekyll site**   | As long as it needs to be (no cap)      | The `_docs/` collection, written for self-paced reading | Full prose, every code listing, every command, the reconciliation plan       |
| **Demos**         | Each is a standalone runnable example   | `examples/demo-XX-*/`                           | Live during the talk *or* skipped in favor of pre-recorded video; always available for the reader to run themselves |

The relationship: the site is the comprehensive reference; the deck is
a curated path through it; the demos are examples used in both. Per-
section "duration" fields in `_docs/` are the **reading time** estimate
for the site, not the talking time for the deck. The deck's pacing is
its own concern — the section table in §5 columns out the talk-time
budget per section.

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
- All seven demos run end-to-end via `./demo.sh` on Fedora 44 with
  Podman 5.x, rootless, no manual fixups.
- Every section has a paired Excalidraw diagram (SVG + JSON) that
  is consistent across the Jekyll site and the PPTX deck.
- The PPTX deck delivers in 3 hours with every demo run live and a
  full Q&A allowance. The Jekyll site is the comprehensive long-form
  reference and is not constrained by talk time.

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

**PPTX total estimated talk time: ~2h 36m** (the full 3-hour cut with
every demo run live, leaving ~25 minutes for Q&A and live-demo
overrun).

**Jekyll site total**: ~3h 45m reading time across the 17 sections.
Untimed in practice — read top-to-bottom or sample by section; every
section is self-contained enough to enter cold.

### Sections

| §  | Title                                                                  | Purpose                                                                                                | PPTX talk | Demo |
|----|------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------|-----------|------|
| 0  | Outline & reading order                                                | Reader's map: what to expect, what's out of scope, the four reading paths                              | 2 min     | —    |
| 1  | Prerequisites                                                          | Fedora 44, Podman 5.x, the toolchain (GCC 14 / Clang 18, Conan 2, CMake, Ninja), cgroup v2 delegation  | 8 min     | —    |
| 2  | Introduction & Mental Model                                            | Why container constraints change C++ perf reasoning; the four-layer model                              | 10 min    | —    |
| 3  | RAII & Container Resource Discipline                                   | RAII as the discipline that holds across process lifecycle, request lifecycle, and cgroup constraints  | 8 min     | —    |
| 4  | Container Strategy: UBI, ubi-micro, multi-stage                        | When to use which base; layer caching; the toolchain-in-runtime anti-pattern                           | 10 min    | 1    |
| 5  | Compile-Time Wins: LTO, PGO, constexpr                                 | What each does, when each is worth the build-time tax, instrumentation runs                            | 10 min    | 1    |
| 6  | STL, Layout, and C++20/23 Containers                                   | `unordered_map` vs `map` vs `flat_map` vs `vector` linear scan; cache locality at scale                | 12 min    | 2    |
| 7  | Memory Management: Allocators, Huge Pages, cgroups v2, OOM             | PMR, mimalloc, jemalloc design, `madvise(MADV_HUGEPAGE)`, `memory.max`, OOM killer, RSS vs working set | 12 min    | 6    |
| 8  | I/O Latency: io_uring, Async gRPC, SO_REUSEPORT                        | Where syscall overhead actually lives; multishot accept, provided-buffer rings, async gRPC             | 12 min    | 3    |
| 9  | Networking & Kernel Parameters                                         | veth pairs vs host networking, sysctl tuning, when to use `--network=host`                             | 10 min    | 3    |
| 10 | Observability & Profiling: OTel, Grafana Stack, perf, eBPF             | OTel from C++ (Simple vs Batch processors); Tempo/Loki/Mimir; `perf`, `bcc`, `bpftrace` against containers | 12 min  | 4    |
| 11 | Noisy Neighbor Isolation: cgroups, CPU pinning, NUMA                   | Two-tenant scenario; cpuset, cpu.weight, io.weight, `numactl --membind`                                | 10 min    | 5    |
| 12 | Static Analysis & Debugging in Containers                              | cppcheck + clang-tidy pipeline; sanitizers in containers; gdbserver sidecar; abidiff in CI             | 15 min    | 7    |
| 13 | Reproducibility & ABI: Conan, CMake Presets, Hermetic Builds, Coverage | Conan lockfiles, CMake presets, ABI tracking with `abidiff`, hermetic CI, coverage instrumentation     | 12 min    | 7    |
| 14 | Pitfalls                                                               | AVX-512 mismatch, abstraction overhead, build delays, instruction-set traps, the things people miss    | 10 min    | —    |
| 15 | Where to Go Next                                                       | Pointers to deeper resources; bibliography page; the four reference books                              | 3 min     | —    |
| 16 | Appendix A — Conan, autotools, and UBI 9's minimal perl                | Reference appendix: how the perl-modules dependency cascade landed; not presented in the deck          | (ref only) | — |

### Reference companion: the Statelessness section

In addition to the linear §0–§16 tutorial body, the site hosts a
12-document **Statelessness reference** at
[`/reference/statelessness/`](/reference/statelessness/). This is
the depth track: the conceptual material that the main tutorial
sections gesture at but don't have room to develop. Each doc
stands alone (1500-4000 words) with its own diagram. The
collection covers the deployment-posture / RAII / PMR / process-
scoped state / threading / 12-factor C++ / state externalization /
ephemeral filesystem / health-checks / gRPC microservices /
build-tooling spectrum. The §3 prose links to it as the canonical
deep dive; readers who want only the linear path can skip it
entirely.

### Optional appendices

- **A** (shipped): Conan, autotools, and UBI 9's minimal perl —
  the worked example of how to bridge a from-source build against
  a minimal-distro target.

The original PRD anticipated additional appendices (B: kernel
parameter cheat-sheet, C: ABI break worked example); their
material landed inline in §9 and §13 respectively rather than
needing dedicated appendices.

---

## 6. Runnable examples

### Will this tutorial have runnable code examples?

Yes — seven demos, each self-contained under `examples/demo-NN-*/` with
a single entry point `./demo.sh` plus a corresponding test script
under `scripts/test-<demo>.sh` for CI verification.

### The seven demos

| # | Name                  | Topic mapping                                                                                                                          | Runs via                                |
|---|-----------------------|----------------------------------------------------------------------------------------------------------------------------------------|-----------------------------------------|
| 1 | image-strategy        | UBI vs UBI-micro, multi-stage, LTO, PGO, ABI labels — §4, §5, §13                                                                       | `podman build` + `podman run`           |
| 2 | stl-layout            | `unordered_map` vs `map` vs `boost::container::flat_map` vs `vector` linear scan; cache-locality benchmark with cgroup memory pressure — §6 | `podman run` with cgroup limits         |
| 3 | io-uring-grpc         | Direct liburing, Asio io_uring executor, async gRPC server — all three in one binary, wired into the LGTM stack — §8, §9              | `podman compose up` (svc + LGTM)        |
| 4 | observability         | C++ HTTP service instrumented with OpenTelemetry traces/metrics/logs; `grafana/otel-lgtm` all-in-one bundle; optional bpftrace probes — §10 | `podman compose up` (full stack)        |
| 5 | isolation             | Noisy-neighbor twin-tenant scenario; baseline, unisolated, `cpu.weight`, `cpuset.cpus` pinning compared — §11                          | `podman compose up` (2 tenants + load)  |
| 6 | memory-and-allocators | `std::allocator` vs `std::pmr` (monotonic + sync_pool) vs `mimalloc`; batch, HTTP-serve, and OTel-instrumented observe modes — §7      | `./demo.sh` batch + `podman compose up` |
| 7 | quality-pipeline      | cppcheck + clang-tidy + googletest/gmock + abidiff + hermetic Conan/CMake build + gdbserver sidecar — §12, §13                         | `podman build` + `podman run` (CI-shaped) |

Each demo has its own page on the site at `/examples/demo-NN-name/`
that renders the demo's README with cross-references back to the
tutorial sections it deepens.

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
- Load gen with **`hey`** (HTTP) and **`ghz`** (gRPC); JSON munging with **`jq`**
- Observability: **Grafana**, **Prometheus**, **Tempo**, **Loki**,
  **Mimir** via the `grafana/otel-lgtm` all-in-one bundle

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

### Shipped diagrams (15 main + companions)

The deck and the site share these 15 diagram pairs. Section
mapping matches the §-numbers in the filenames; some sections
share a diagram with another and some have an additional
companion (e.g. §2 has both the four-layer-model and a threading-
model diagram).

- `01-prerequisites-toolchain.svg` — toolchain at a glance,
  build-time / runtime / host layers (§1)
- `02-introduction-four-layers.svg` — the four-layer model:
  toolchain → image → kernel → runtime (§2)
- `02-threading-models.svg` — companion for §2's threading
  treatment in the deeper site prose
- `03-raii-discipline.svg` — RAII tying resource lifetime to scope;
  manual cleanup leaks vs RAII destructor (§3)
- `04-image-strategy-multistage.svg` — single-stage vs
  ubi-multistage vs ubi-micro with Demo-01 verified result (§4)
- `05-compile-time-pgo-flow.svg` — instrument → train → optimize
  PGO pipeline (§5)
- `06-stl-layout-flat-vs-node.svg` — cache footprint comparison
  of flat_map vs unordered_map vs std::map (§6)
- `07-allocator-stack.svg` — application → PMR → allocator →
  kernel → cgroup memory.high/.max (§7)
- `08-io-uring-rings.svg` — submission queue / completion queue
  mental model (§8)
- `09-networking-veth-vs-host.svg` — packet path difference
  between rootless veth and `--network=host` (§9)
- `10-observability-otel-stack.svg` — OTel C++ SDK → otel-lgtm
  → Tempo / Mimir / Loki / Grafana, with the Simple-vs-Batch
  processor decision highlighted (§10)
- `11-isolation-cgroup-tree.svg` — cgroup v2 hierarchy with two
  tenants under demo-05 (§11)
- `12-debug-sidecar-pattern.svg` — ephemeral gdbserver sidecar
  attaching to a running pod (§12)
- `13-reproducibility-conan-flow.svg` — Conan lockfile + CMake
  preset + Containerfile → labeled deterministic image (§13)
- `14-pitfalls-avx512-mismatch.svg` — the SIGILL trap visualized,
  build host vs runtime host (§14)

The depth-track reference collection at
`/reference/statelessness/` has its own diagram set (one per
doc, ~12 additional SVGs) not enumerated here.

### How diagrams reach the PPTX deck

The deck-build pipeline (see `tools/build-deck.sh`) converts each
SVG to a high-resolution JPG via `soffice --convert-to pdf` then
`pdftoppm`, then embeds the JPG via `python-pptx`. The
conversion is idempotent and cached in `/tmp/diagrams-png/`. The
build script `tools/build-pptx.py` reads slide content from
`tools/sections.py` and assembles the deck; full details in
[`presentation/README.md`](presentation/README.md).

---

## 8. Success metrics

### Verification metrics

- All seven demos pass `scripts/test-all-demos.sh` on Fedora 44 with
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

The site's [**Bibliography page**](/bibliography/) consolidates the
four books with extended annotations, a section-by-section
cross-reference of which book deepens which section, and suggested
reading orders depending on where the reader is starting from.

Ghosh's book complements Enberg's: where Enberg covers latency as a
general-systems problem, Ghosh walks through a concrete low-latency
C++ ecosystem (trading-system framing, but the patterns —
lock-free queues, custom memory pools, busy-spin vs futex, NIC
configuration — generalize). It's the natural pointer for §7
(memory pools), §8 (I/O latency), and §11 (CPU pinning, NUMA) for
readers who want a full worked example outside the container
framing.

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

### Anticipated risks (assessed at the start of the project)

| Risk                                                                           | Impact | Likelihood | Mitigation                                                                                       |
|--------------------------------------------------------------------------------|--------|------------|--------------------------------------------------------------------------------------------------|
| Podman 5.x compose syntax drifts during the writing window                     | Med    | Med        | Pin Podman version in §1; reconciliation plan tracks the version that verified each demo         |
| Fedora 44 ships a GCC version that breaks one of the C++23 examples            | Med    | Low        | Each demo specifies its compiler in `CMakePresets.json`; fallback to Clang 18 documented         |
| io_uring demo behaves differently on older kernels (5.4 vs 6.x)                | Med    | Low        | §7 prereq pins kernel feature flags; demo refuses to run if `/proc/version` < 6.0                |
| AVX-512 demo SIGILLs on the presenter's machine                                | Low    | Med        | Demo intentionally produces this; `--cpu-set` flag or `-march=` override documented              |
| Reader is on macOS via `podman machine` and the cgroup demos don't behave      | Med    | High       | §1 explicitly warns; §10 (noisy neighbor) marked "Linux host required"                           |
| Reference books cited too closely, drifting toward displacement summary        | High   | Low        | Editorial pass: every cite is a pointer ("see Iglberger ch. 4 for the full pattern"), never a substitute |
| Tutorial too long; readers don't finish                                        | High   | Med        | Sectioned so partial reads work; outline calls out the suggested reading paths in §0           |
| Tutorial too compressed; misses the "why"                                      | Med    | Med        | Each section opens with a "why this matters" and closes with a measurable claim                  |
| AVX-512 vs AVX2 vs `-march=native` confuses readers without recent CPUs        | Med    | Med        | §13 includes `lscpu \| grep avx` as the first step and a tested fallback flag set                |
| The grpc + io_uring demo build time exceeds reasonable patience in a live demo | Med    | High       | Pre-built layer published; demo.sh detects and pulls instead of rebuilding                       |

### Risks encountered during development (and how they actually resolved)

| Risk encountered                                                                | Severity   | Resolution                                                                                            |
|---------------------------------------------------------------------------------|------------|-------------------------------------------------------------------------------------------------------|
| OTel C++ SDK build time inside Demo 3 + Demo 4 + Demo 6 made first builds 30-60m | Slow CI    | Documented as expected; pre-built layer cached in registry; recommended `--prebuilt` flag for live demos |
| Conan from-source dep builds (libcurl/openssl/nghttp2) fail on UBI 9 minimal perl | Hard block | Appendix A (§16) shipped with the 15-perl-module fix; multiple simplifying alternatives documented   |
| jemalloc 5.3.1 + GCC 14 stricter conformance: build failure in repeated attempts | Build-time | Dropped jemalloc from demo-06's variants; §7 prose retains the design discussion as alternative reading |
| GitHub Pages `configure-pages@v5` can return empty `base_path` mid-workflow      | Build-time | Workflow guard added (`if: env.BASE != ''`); G-64 in gotcha catalog                                   |
| Absolute `/path/` links in markdown bypass Jekyll `baseurl` filter on Pages      | Linkrot    | r138 internalization pass: every site-internal link uses `{{ '/path/' \| relative_url }}` filter      |
| Jekyll Liquid renders any literal `{%` or `{{` in prose, including in code fences | Templating | `scripts/check-liquid.py` static analyzer added as pre-push hook (r131); documents must escape with `{% raw %}` |
| Round annotations (r##) leaked into reader-facing content across many cycles    | Editorial  | Three cleanup passes (r135 / r141 / r142); also caught annotations embedded in 4 SVG diagrams         |
| Section renumbering created stale demo references (§7→Demo 6, §12-13→Demo 7)    | Reference  | r141 outline-page rewrite reconciled all demo↔section mappings; spot-checks in r142                  |
| PPTX template-editing flow (54 → 80+ slides via XML duplication) was unwieldy   | Build-time | Programmatic generation via `python-pptx` with design tokens extracted from a reference deck         |
| SVG → PNG conversion: no `rsvg-convert`/`cairosvg`/`inkscape` in build env      | Build-time | Two-hop pipeline via `soffice --convert-to pdf` then `pdftoppm`; works on Fedora 44 with default packages |
| Code blocks and diagrams routinely overflowed slide bounds on first render      | Build-time | `build-pptx.py` added aspect-ratio-aware diagram sizing (via PIL) + auto-shrink for long code blocks |

---

## 11. Timeline and milestones

| Milestone                                                       | Est. effort      | Done? |
|-----------------------------------------------------------------|------------------|-------|
| PRD reviewed and approved                                       | 1-2 hours        | [x]   |
| Skeleton scaffolded; \_config.yml, layouts, includes branded    | 2-3 hours        | [x]   |
| §1 prerequisites drafted and verified on fresh Fedora 44        | 3-4 hours        | [x]   |
| Demo 1 (image-strategy) working end-to-end                      | 6-8 hours        | [x]   |
| Demo 2 (stl-layout) working end-to-end                          | 8-10 hours       | [x]   |
| Demo 3 (io-uring-grpc) working end-to-end                       | 10-14 hours      | [x]   |
| Demo 4 (observability) compose stack up + OTel C++ wired        | 12-16 hours      | [x]   |
| Demo 5 (isolation) two-tenant scenario reproducible             | 8-10 hours       | [x]   |
| Demo 6 (memory-and-allocators) PMR + huge pages + mimalloc       | 10-14 hours      | [x]   |
| Demo 7 (quality-pipeline) including abidiff and gdbserver       | 10-12 hours      | [x]   |
| All §3-§14 sections drafted (zero-draft)                        | 30-40 hours      | [x]   |
| 15 Excalidraw diagrams drafted, paired SVG exported             | 8-12 hours       | [x]   |
| All demo test scripts pass under `test-all-demos.sh`            | 4-6 hours        | [x]   |
| Cross-platform note: Fedora 43 best-effort verification         | 2-4 hours        | [ ]   |
| Editorial pass for tone, voice, vendor-neutrality               | 6-10 hours       | [x]   |
| Annotated bibliography page consolidating the four books        | 2-3 hours        | [x]   |
| PPTX deck built programmatically from `_docs/` + diagrams       | 4-6 hours        | [x]   |
| Reconciliation plan reflects shipped state                      | 1-2 hours        | [x]   |
| PRD reconciled with shipped reality (this update)               | 1-2 hours        | [x]   |
| LESSONS-LEARNED.md captures the multi-round retrospective       | 2-3 hours        | [ ]   |
| Public announce                                                 | -                | [ ]   |

**Hard deadline:** TBD by author.
**Realistic launch target:** The substance is shipped — site,
demos, deck, bibliography, appendix. Remaining items (cross-distro
verification, LESSONS-LEARNED.md, announce) are polish-and-launch
work, not core delivery.

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
| 2026-05-09 | The four reference books are pointed-at, not summarized                    | Both honest about what this tutorial *is* (a runnable companion) and respects authors' work |
| 2026-05-09 | One Excalidraw diagram per section minimum, paired SVG + JSON              | Source-available, scales for the PPTX, editable without proprietary tooling                |
| 2026-05-12 | Seventh demo (quality-pipeline) — split out of original demo 6              | demo-06 became the memory/allocator deep dive; the cppcheck/abidiff/gdbserver material has its own surface area worth a dedicated demo |
| 2026-05-13 | RAII section (§3) added between Introduction and Container Strategy        | The discipline that holds across process / request / cgroup lifecycle deserves its own treatment before the layer-specific sections build on it |
| 2026-05-14 | Statelessness reference collection added at `/reference/statelessness/`    | The conceptual depth track around process- vs request-scoped state needed more room than §3 prose could carry; 12 docs, each linked to a tutorial section |
| 2026-05-15 | PPTX deliverable is 3-hour only — drop the 1.5-hour cut                    | The 3-hour cut is the design target; a 1.5-hour cut was a maintenance burden producing a strictly inferior experience |
| 2026-05-15 | Per-demo Jekyll wrapper pages at `/examples/demo-NN-*/`                    | The READMEs are the source of truth for terminal users; the wrapper pages render the same content with cross-references for browser readers, generated via `scripts/regen-examples-collection.sh` |
| 2026-05-16 | jemalloc dropped from demo-06's variants                                   | GCC 14's stricter C conformance vs jemalloc 5.3.1's pre-2024 source didn't yield to either Conan recipe tweaks or env-CFLAGS injection within reasonable build-time budget; §7 prose covers jemalloc's design as an alternative without requiring the binary to build it |
| 2026-05-17 | Annotated bibliography page at `/bibliography/`                            | Inline citations are pointers, not annotations; readers asking "which book should I read next" deserve a single page that consolidates the four reference books with their angle, when-to-reach-for, and section-by-section cross-reference |
| 2026-05-17 | `scripts/check-liquid.py` static analyzer as a pre-push hook               | Jekyll's Liquid templating treats every literal `{%` and `{{` as parser-visible; documenting the syntax in prose creates recursion bugs unless authors are disciplined. The analyzer enforces the discipline mechanically |
| 2026-05-17 | Editorial pass to strip authoring artifacts from reader-facing content     | Round annotations (`(r##)`) and "scope per round" sections add noise without value for the reader; the reconciliation plan retains the full history |
| 2026-05-17 | Internalize demo cross-references in tutorial sections (Tier 1 strategy)   | Tutorial sections at `/docs/NN-*/` link to demo pages at `/examples/demo-NN-*/` for in-site navigation (Tier 1); demo-page READMEs link out to GitHub source for code download (Tier 2). This keeps the reading flow self-contained without redirecting readers off-site mid-section |
| 2026-05-17 | Programmatic PPTX generation via `python-pptx`, not template editing        | The Quarkus reference deck has 54 slides; our target is 80-120. Editing raw XML at that scale is unwieldy. A two-file split (`tools/sections.py` for content, `tools/build-pptx.py` for renderer) keeps the deck in sync with the tutorial and makes design tokens / slide kinds re-usable |
| 2026-05-17 | Borrow design tokens from `patterncatalyst/quarkus-optimization` deck       | The author's other talks share a visual vocabulary; matching the Quarkus palette (dark navy + cyan accent, Calibri/Consolas, navy header bar) gives audiences continuity. Tokens extracted from the reference PPTX's XML and re-applied via `python-pptx` rather than reusing the actual template machinery |
| 2026-05-17 | SVG → PDF → JPG conversion pipeline for PPTX diagram embedding              | No `rsvg-convert`/`cairosvg`/`inkscape` available in the build environment. `soffice --convert-to pdf` then `pdftoppm -jpeg` produces high-quality JPGs and ships with Fedora 44's default packages. Wrapped in `tools/build-deck.sh` with idempotent caching in `/tmp/diagrams-png/` |
| 2026-05-17 | Speaker notes as full talking scripts, not bullet expansions                | The user requested rehearsal-quality speaker notes ("not just repeating what you have written"). Each slide's notes pane contains multi-paragraph spoken-language prose (~350 words per slide, ~25,000 words total) drawn from the `_docs/` source but rewritten for delivery — first person, contractions, natural flow |
| 2026-05-17 | Pinned `tools/requirements.txt` with `python-pptx` and `Pillow`            | The two Python dependencies for the deck build pinned with version ranges. Documented install paths cover virtualenv (recommended), system-wide with PEP 668 escape hatch, and direct package install. The wrapper script `tools/build-deck.sh` surfaces these as the install hint when a dep is missing |

---

## 14. Stakeholders

### Project stakeholders

| Name           | Role             | What they need                                              |
|----------------|------------------|-------------------------------------------------------------|
| Tutorial author | Author + presenter | The PRD on hand each session; reconciliation plan up to date; the deck script for rehearsal |
| Reviewer (TBD) | Technical reviewer | A complete zero-draft + a working `test-all-demos.sh` before review |

### Audience (the people the deliverables exist for)

| Audience                   | What they get                                                                                                                              | Where they find it                                              |
|----------------------------|--------------------------------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------|
| **Talk attendees**         | 3-hour live PPTX walk-through with live demo runs and rehearsal-quality speaker notes the presenter follows                                | The PPTX deck under `presentation/`                             |
| **Self-paced site readers**| Untimed long-form reference covering every code listing, every measurement, every Liquid-safe code fence                                   | The Jekyll site at `patterncatalyst.github.io/cpp-container-optimization-tutorial/` |
| **Demo runners**           | Seven self-contained Podman demos each with `./demo.sh`; runnable on Fedora 44 with no external services                                   | The `examples/demo-NN-*/` directories on the repo               |
| **Tutorial extenders**     | Source-available diagrams (paired SVG + Excalidraw JSON); a build script for the deck that takes content as data; a documented architecture | `diagrams/`, `tools/`, `presentation/README.md`                 |
| **Operators copying patterns** | The Conan + UBI 9 + autotools survival appendix; the AVX-512 mismatch runbook entry; the cgroup-v2-delegation script                       | `_docs/16-appendix-a-conan-ubi9-perl.md`, §14 pitfalls, `scripts/cgroup-delegation.sh` |

The deck and the site are two presentations of the same material
for different consumption modes; they share content via the
`_docs/` source. The demos are the empirical anchor — every
measurement on the site or in the deck has a corresponding
runnable example. The appendix and pitfalls are the rescue
section: not central to the tutorial, but very useful when the
specific trap they cover bites.

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
