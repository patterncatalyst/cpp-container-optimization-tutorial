---
title: Reconciliation Plan
order: 1
description: Audit trail tracking what's verified versus what's claimed. The honest source of truth for the project's state.
---

# Reconciliation Plan

This document tracks the verification state of every claim made in
the tutorial. It is the **honest source of truth** for what's been
tested versus what's still drafted but unverified.

The skeleton's convention is followed: every row is one of
`verified`, `verified (Fedora 44)`, `in flight`, `unverified`, or
`out of scope`. Promote `unverified` → `verified` only after a
deliberate test run produces the documented behaviour. This is
especially important when AI assistance was used to draft the
section: AI is excellent at producing plausible-looking technical
claims, and this is where those claims get either promoted or
flagged.

---

## At-a-glance status

```
G.1 Sections drafted:             15 / 15  (stub level — outlines only)
G.2 Sections verified:             0 / 15  ← the one to watch
G.3 Demos scaffolded:              6 / 6   (build files + sources + Containerfiles)
G.4 Demos passing test scripts:    0 / 6   (test scripts exist; not run yet)
G.5 Diagrams paired (SVG+JSON):    0 / 13  (placeholders only; not drawn yet)
G.6 PPTX export validated:        no
```

**Note on stub vs verified:** every section has a Jekyll page with
front-matter, learning objectives, planned content outline, demo
pointer, and book references. None has been **walked through** end-to-end
on a clean Fedora 44 host; that's what the verification pass turns
"drafted" into "verified."

---

## G.2 — Section verification matrix

| §  | Title                                                              | Drafted | Verified state              | Verifier notes                                       |
|----|--------------------------------------------------------------------|---------|-----------------------------|------------------------------------------------------|
| 0  | Outline                                                            | [x]     | unverified                  | —                                                    |
| 1  | Prerequisites                                                      | [x]     | unverified                  | Test on fresh Fedora 44 VM and Silverblue toolbox    |
| 2  | Introduction & Mental Model                                        | [x]     | unverified                  | —                                                    |
| 3  | Container Strategy: UBI, scratch, multi-stage builds               | [x]     | unverified                  | Tied to Demo 1                                       |
| 4  | Compile-Time Wins: LTO, PGO, constexpr                             | [x]     | unverified                  | Tied to Demo 1; PGO instrumentation step needs test  |
| 5  | STL, Layout, and C++20/23 Containers                               | [x]     | unverified                  | Tied to Demo 2; verify GCC 14 supports `flat_set`    |
| 6  | Memory Management: Allocators, Huge Pages, cgroups v2, OOM         | [x]     | unverified                  | Expanded 2026-05-09 with cgroup memory.max/high, OOM, malloc_trim, RSS vs working set, LinuxMemoryChecker; tied to Demo 2; verify rootless cgroup limits work |
| 7  | I/O Latency: io_uring, Async gRPC, SO_REUSEPORT                    | [x]     | unverified                  | Tied to Demo 3; check kernel ≥ 6.0                   |
| 8  | Networking & Kernel Parameters                                     | [x]     | unverified                  | Tied to Demo 3; veth vs host comparison              |
| 9  | Observability & Profiling: Grafana Stack, perf, eBPF               | [x]     | unverified                  | Tied to Demo 4; full stack must come up clean        |
| 10 | Noisy Neighbor Isolation: cgroups, CPU pinning, NUMA               | [x]     | unverified                  | Tied to Demo 5; needs ≥ 8 cores ideally              |
| 11 | Static Analysis & Debugging in Containers                          | [x]     | unverified                  | Expanded 2026-05-09 with ASan/UBSan/MSan/TSan in containers, Valgrind tradeoffs, Meta Object Introspection; tied to Demo 6; gdbserver attach pattern |
| 12 | Reproducibility & ABI: Conan, CMake Presets, Hermetic Builds       | [x]     | unverified                  | Tied to Demo 6; verify abidiff catches a real break  |
| 13 | Pitfalls: AVX-512 mismatch, abstraction overhead, build delays     | [x]     | unverified                  | AVX-512 demo crash recovery needs hardware variance  |
| 14 | Where to Go Next                                                   | [x]     | unverified                  | —                                                    |

---

## G.3 / G.4 — Demo build & test matrix

| #  | Demo name           | `demo.sh` builds | `test-demo-NN.sh` passes | Last verified on             | Notes                                                   |
|----|---------------------|------------------|--------------------------|------------------------------|---------------------------------------------------------|
| 1  | image-strategy      | [ ]              | [ ]                      | —                            | Multi-stage; UBI vs scratch; LTO/PGO flags              |
| 2  | memory-and-stl      | [ ]              | [ ]                      | —                            | PMR allocator + cgroup memory.high + huge pages         |
| 3  | io-uring-grpc       | [ ]              | [ ]                      | —                            | 2-service compose; `hey` load gen                       |
| 4  | observability       | [ ]              | [ ]                      | —                            | Full Grafana+Prom+Tempo+Loki+Mimir stack                |
| 5  | isolation           | [ ]              | [ ]                      | —                            | 2-tenant noisy neighbor; cgroup weights                 |
| 6  | quality-pipeline    | [ ]              | [ ]                      | —                            | cppcheck + clang-tidy + gtest + abidiff + gdbserver     |

`scripts/test-all-demos.sh` aggregates the six per-demo test
scripts; it does **not** fail-fast (per skeleton convention),
prints a pass/fail summary at the end.

---

## G.5 — Diagrams matrix

| Diagram (basename)                         | `.svg` | `.excalidraw` | Embedded in §  | Notes                                              |
|--------------------------------------------|--------|---------------|----------------|----------------------------------------------------|
| 02-mental-model-four-layers                | [ ]    | [ ]           | §2             | Toolchain → image → kernel → runtime               |
| 03-image-strategy-ubi-vs-scratch           | [ ]    | [ ]           | §3             | Trade-off matrix with rows: size, debug, attack    |
| 04-compile-pgo-flow                        | [ ]    | [ ]           | §4             | Instrumented build → workload → optimized build    |
| 05-stl-layout-cache-lines                  | [ ]    | [ ]           | §5             | Cache-line footprint: vector / flat_set / map      |
| 06-allocator-stack                         | [ ]    | [ ]           | §6             | App → PMR resource → upstream → cgroup memory.high |
| 07-io-uring-submission                     | [ ]    | [ ]           | §7             | SQ/CQ mental model with kernel submission thread   |
| 08-veth-vs-host-networking                 | [ ]    | [ ]           | §8             | Packet path under each mode                        |
| 09-observability-stack                     | [ ]    | [ ]           | §9             | The compose graph + data flow                      |
| 10-noisy-neighbor-cgroup-tree              | [ ]    | [ ]           | §10            | cgroup hierarchy with tenants + load gen           |
| 11-debug-sidecar-pattern                   | [ ]    | [ ]           | §11            | Ephemeral sidecar attaching to running pod         |
| 12-hermetic-build-flow                     | [ ]    | [ ]           | §12            | Conan lockfile + preset → image with ABI labels    |
| 13-avx512-mismatch                         | [ ]    | [ ]           | §13            | The SIGILL trap visualized                         |
| 14-where-to-go-next                        | [ ]    | [ ]           | §14            | Map of related topics for further reading          |

---

## Verification log

Append-only entries documenting verification runs. Each entry
should specify the host (Fedora 44 build, kernel version, CPU,
memory), what was tested, what passed, what surprised the verifier.

### YYYY-MM-DD — Initial scaffold

- Repo scaffolded from `patterncatalyst/skeleton-tutorial`
- All sections marked unverified per the matrix above
- Verification work has not yet begun

### 2026-05-09 — §6 / §11 expansion, Ghosh book added

- Added Ghosh, *Building Low Latency Applications with C++* to the
  PRD reference list and to §7, §10, §14's "deeper coverage" pointers.
- Expanded §6 (Memory Management): added cgroups v2 `memory.max` /
  `memory.high` distinction, OOM killer behaviour, glibc
  `malloc_trim` / `MALLOC_TRIM_THRESHOLD_` / `MALLOC_ARENA_MAX`
  tuning, RSS vs working set vs `memory.current`, the Presto
  `LinuxMemoryChecker` pattern. Reframed the section as "the
  application-level concern, not the things-went-wrong concern."
- Expanded §11 (Static Analysis & Debugging): added a sanitizer
  comparison table (ASan/UBSan/MSan/TSan with slowdowns), Valgrind
  trade-offs, Meta's Object Introspection for diagnosing the silent
  STL overhead from §5/§13.
- Bumped §6 from 12 → 15 minutes, §11 from 12 → 15 minutes; total
  duration 2h 40m → 2h 46m.
- Both sections still **unverified** — content drafted from sources
  the user provided; not walked through on a Fedora 44 host.

---

## Known divergences from the PRD

A running list of things the shipped tutorial does differently from
what the PRD says. Update as you discover them; the gap between
PRD and reality is usually instructive at retrospective time.

- (none yet)
