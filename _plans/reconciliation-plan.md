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
G.5 Diagram pairs in place:       13 / 13  (placeholders; not drawn yet)
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
| 0  | Outline                                                            | [x]     | drafted (r03)               | Full prose, sidebar dropped, dual-target sizing called out  |
| 1  | Prerequisites                                                      | [x]     | drafted (r04)               | r04: 3 script bugs found and fixed via real-host run; user reports all packages install cleanly. Awaiting clean check-host.sh PASS line on a fresh Fedora 44 VM to flip to "verified". |
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

Two state columns: **placeholder** (the auto-generated SVG/.excalidraw
stub committed to the repo so the site renders cleanly on day one) and
**drawn** (a real diagram has replaced the stub). Promotion only after
the SVG actually communicates the section's idea — placeholders that
just look "filled in" don't count.

| Diagram (basename)                    | placeholder | drawn  | Embedded in §  | Notes                                              |
|---------------------------------------|-------------|--------|----------------|----------------------------------------------------|
| 01-prerequisites-toolchain            | [x]         | [ ]    | §1 (gallery)   | Toolchain → Conan cache → Podman storage           |
| 02-introduction-four-layers           | [x]         | [ ]    | §2             | Compile time → image → kernel → runtime            |
| 03-image-strategy-multistage          | [x]         | [ ]    | §3             | Trade-off matrix: size, debug, attack surface       |
| 04-compile-time-pgo-flow              | [x]         | [ ]    | §4             | Instrumented build → workload → optimized build    |
| 05-stl-layout-flat-vs-node            | [x]         | [ ]    | §5             | Cache-line footprint: set / flat_set / vector       |
| 06-allocator-stack                    | [x]         | [ ]    | §6             | App → PMR → glibc/jemalloc/mimalloc → cgroup        |
| 07-io-uring-rings                     | [x]         | [ ]    | §7             | SQ/CQ mental model + multishot recv                 |
| 08-networking-veth-vs-host            | [x]         | [ ]    | §8             | Packet path under each networking mode              |
| 09-observability-otel-stack           | [x]         | [ ]    | §9             | OTel collector fan-out to Prom/Mimir/Tempo/Loki     |
| 10-isolation-cgroup-tree              | [x]         | [ ]    | §10            | cgroup hierarchy: weight + cpuset + NUMA            |
| 11-debug-sidecar-pattern              | [x]         | [ ]    | §11            | Ephemeral sidecar sharing PID namespace             |
| 12-reproducibility-conan-flow         | [x]         | [ ]    | §12            | Conan lockfile + preset → image with ABI labels     |
| 13-pitfalls-avx512-mismatch           | [x]         | [ ]    | §13            | The SIGILL trap visualized                          |

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

### 2026-05-09 — Site refactored to hummingbird-tutorial conventions; Excalidraw folder seeded; PRD dual-target sizing

- Adopted `patterncatalyst/hummingbird-tutorial` Jekyll conventions for
  CSS, layouts, includes, and top-level listing pages so the
  `patterncatalyst` family of tutorial sites shares a visual language.
  - Rewrote `assets/css/site.css` (~480 lines) around the same class
    system (`hero`, `hero--compact`, `card`, `chip`, `btn--primary`,
    `gallery-card`, `modal__*`, `tutorial__*`, `doc-card`) with a
    C++-flavored deep-red accent (`#c0392b`) and proper
    `prefers-color-scheme: dark` tokens (later removed in r02 per
    user request — site now stays light always).
  - Replaced `_layouts/{default,tutorial,plan}.html`,
    `_includes/{header,footer,excalidraw}.html`, and `index.html`.
  - Added `_includes/diagram-card.html` partial used by the gallery.
  - Added top-level pages `diagrams.html` (fullscreen-modal gallery,
    JS verbatim from hummingbird so future patches apply to both)
    and `examples.html` (cards listing the six demos).
  - Updated `_config.yml` to match: `permalink: /:path/:basename/`,
    `jekyll-redirect-from` plugin, `sectionid` defaults, the
    "trailing slash on `examples/`" exclude pattern. Added
    `jekyll-redirect-from` to the Gemfile.

- Seeded `assets/diagrams/` with 13 placeholder pairs (`.svg` and
  `.excalidraw`) so every inline include and gallery card resolves to
  *something* on first build. Each placeholder is a labelled gray box
  that says "diagram pending"; the `.excalidraw` stub opens cleanly on
  excalidraw.com so the editor doesn't have to hand-craft the JSON
  envelope. Conventions written up in `assets/diagrams/README.md`.

- Renamed every inline diagram reference in `_docs/*.md` to the
  canonical basenames used by the gallery (`02-introduction-four-layers`,
  `06-allocator-stack`, `12-reproducibility-conan-flow`, etc.) so
  inline embeds and the gallery resolve to the same SVG file.

- PRD dual-target sizing made explicit:
  - **PPTX deck**: 1.5–3 hours when delivered live.
  - **Jekyll site**: untimed; written for self-paced reading.
  - **Demos**: standalone runnable examples used in both targets;
    live during the talk *or* swapped for pre-recorded video.
  - Per-section "duration" fields in `_docs/` are reading time for
    the site; PPTX talk-time for the deck is in PRD §5.
  - Section table now labels its time column "PPTX talk" rather than
    a generic "duration", and PRD §5 spells out which sections are
    in the 1.5h cut vs. the 3h cut.

- Verification state unchanged: nothing has been walked through on
  Fedora 44 yet.

### 2026-05-09 — r02: CSS light-only; demo-01 pre-flight fixes

- Removed the dark-mode media query from `assets/css/site.css` so
  the site stays light always (matches hummingbird). Added
  `color-scheme: light` on `:root`. Kept the dark-mode block as
  commented-out reference at the bottom of the file for opt-in.
- demo-01 fixes that would have blocked the verification pass:
  - `CMakePresets.json` `pgo-use` preset: hardcoded
    `/pgo/default.profdata`. The original `${PGO_PROFILE_PATH}`
    cache-var reference doesn't expand inside preset cacheVariables.
  - `Containerfile.scratch-static`: added `libstdc++-dev` to apk so
    the static archive is present at link time.
  - `Containerfile.pgo`: dropped unneeded `compiler-rt` from the
    instrumented runtime image (profile runtime is statically linked).
  - `demo.sh`: source `_helpers.sh`, `require podman curl jq hey`,
    replaced both `sleep 1` calls with `wait_for_http`, added
    unconditional `mkdir -p pgo-profiles`.

### 2026-05-09 — r03: Round 1 prose (§0, §1); sidebar drop; CONTRIBUTING.md

- §0 Outline rewritten as full long-form prose. Documents how the
  tutorial is organised, the two delivery targets (PPTX 1.5–3h vs
  untimed site), the 1.5h vs 3h PPTX cuts, what each section covers,
  what's deliberately out of scope, and the realistic 7–10h end-to-end
  reading + running estimate.
- §1 Prerequisites rewritten as a working install guide: dnf install
  list, Conan 2 via pip, hey installation, rootless cgroup delegation
  drop-in, kernel-feature checks, registry auth, repo clone, and a
  "common things that go wrong" runbook.
- Added `scripts/check-host.sh` that exercises every prerequisite
  and prints a PASS/FAIL table with remediation hints. References
  the Fedora baseline but degrades gracefully on other distros.
- Site change (per user request): dropped the per-tutorial-page
  sidebar entirely; the layout is now single-column with prev/next
  pager, matching hummingbird-tutorial's behaviour. CSS for
  `.tutorial__sidebar` excised; `.tutorial` no longer a grid.
- Added `CONTRIBUTING.md` documenting the Conventional-Commits
  format and the type list (`docs:`, `site:`, `demo:`, `obs:`,
  `build:`, `ci:`, `chore:`, `fix:`, `feat:`, `refactor:`, `style:`).
- Verification status: §0 and §1 are **drafted** but not yet
  walked through on a fresh Fedora 44 host. The check-host.sh
  output in §1 is illustrative; the script itself runs cleanly
  in syntax check but needs an end-to-end pass to validate every
  remediation hint.

### 2026-05-09 — r04: §1 fixes from real-host check-host.sh run

User ran `./scripts/check-host.sh` on Fedora 44 Workstation
(kernel 6.19.14-300.fc44, podman 5.8.2, clang 22.1.4, conan 2.25.2).
Output revealed three script bugs and one stale §1 instruction:

- **Script bug**: cgroup-delegation predicate required `cpuset` but
  user's cpuset wasn't delegated; demos 2/5/6 don't actually need
  user-slice cpuset delegation (--cpuset-cpus on podman run is
  per-container). Relaxed the predicate to require `cpu memory io`.
- **Script bug**: `gcc-toolset-14` check fails on stock Fedora
  because the package is in the RHEL/UBI repo flow, not Fedora's
  default repos. Replaced with a host `g++ >= 14` check that
  reads from the default `g++` (Fedora 44 ships GCC 14 by default,
  so this passes out of the box).
- **Script bug**: `docker.io` probe used `https://registry-1.docker.io/v2/`
  which returns 401 to anonymous HEAD; `curl -fsS` treats 401 as
  failure. Switched to `https://hub.docker.com/v2/` which is reliably
  200 anonymous.
- **§1 fix**: dropped `gcc-toolset-14` from the host install list
  (it's container-side only); added `gcc-c++` instead. Added
  `golang` to the dnf one-liner since hey is now installed via
  go install.
- **§1 fix**: replaced the stale AWS S3 `hey` binary URL (now 403
  forbidden) with `go install github.com/rakyll/hey@latest` as
  the canonical install path. Kept the from-source build as a
  documented fallback.
- **§1 addition**: new "When `docker.io` is unreachable" sub-section
  covering the Quay.io mirror path and the `podman save | podman load`
  air-gap fallback for demo 4 reachability problems.

Other findings from the user's run that didn't need code changes:
- `cppcheck`, `libabigail`, `bpftrace`, `gdb` were missing on user's
  host; legitimate "install these" rather than script bugs.
- `hey` had been installed via snap; user removed snap and reinstalled
  via go. After the reinstall, user reported "they all worked".

Verification status: §1 advanced from "drafted" toward "verified" —
the user has run check-host.sh end-to-end and the script accurately
diagnoses and remediates real failure modes. Still want a clean
green run on a fresh Fedora 44 VM before flipping to "verified".

- §0 Outline rewritten as full long-form prose. Documents how the
  tutorial is organised, the two delivery targets (PPTX 1.5–3h vs
  untimed site), the 1.5h vs 3h PPTX cuts, what each section covers,
  what's deliberately out of scope, and the realistic 7–10h end-to-end
  reading + running estimate.
- §1 Prerequisites rewritten as a working install guide: dnf install
  list, Conan 2 via pip, hey installation, rootless cgroup delegation
  drop-in, kernel-feature checks, registry auth, repo clone, and a
  "common things that go wrong" runbook.
- Added `scripts/check-host.sh` that exercises every prerequisite
  and prints a PASS/FAIL table with remediation hints. References
  the Fedora baseline but degrades gracefully on other distros.
- Site change (per user request): dropped the per-tutorial-page
  sidebar entirely; the layout is now single-column with prev/next
  pager, matching hummingbird-tutorial's behaviour. CSS for
  `.tutorial__sidebar` excised; `.tutorial` no longer a grid.
- Added `CONTRIBUTING.md` documenting the Conventional-Commits
  format and the type list (`docs:`, `site:`, `demo:`, `obs:`,
  `build:`, `ci:`, `chore:`, `fix:`, `feat:`, `refactor:`, `style:`).
- Verification status: §0 and §1 are **drafted** but not yet
  walked through on a fresh Fedora 44 host. The check-host.sh
  output in §1 is illustrative; the script itself runs cleanly
  in syntax check but needs an end-to-end pass to validate every
  remediation hint.

- Adopted `patterncatalyst/hummingbird-tutorial` Jekyll conventions for
  CSS, layouts, includes, and top-level listing pages so the
  `patterncatalyst` family of tutorial sites shares a visual language.
  - Rewrote `assets/css/site.css` (~480 lines) around the same class
    system (`hero`, `hero--compact`, `card`, `chip`, `btn--primary`,
    `gallery-card`, `modal__*`, `tutorial__*`, `doc-card`) with a
    C++-flavored deep-red accent (`#c0392b`) and proper
    `prefers-color-scheme: dark` tokens.
  - Replaced `_layouts/{default,tutorial,plan}.html`,
    `_includes/{header,footer,excalidraw}.html`, and `index.html`.
  - Added `_includes/diagram-card.html` partial used by the gallery.
  - Added top-level pages `diagrams.html` (fullscreen-modal gallery,
    JS verbatim from hummingbird so future patches apply to both)
    and `examples.html` (cards listing the six demos).
  - Updated `_config.yml` to match: `permalink: /:path/:basename/`,
    `jekyll-redirect-from` plugin, `sectionid` defaults, the
    "trailing slash on `examples/`" exclude pattern. Added
    `jekyll-redirect-from` to the Gemfile.

- Seeded `assets/diagrams/` with 13 placeholder pairs (`.svg` and
  `.excalidraw`) so every inline include and gallery card resolves to
  *something* on first build. Each placeholder is a labelled gray box
  that says "diagram pending"; the `.excalidraw` stub opens cleanly on
  excalidraw.com so the editor doesn't have to hand-craft the JSON
  envelope. Conventions written up in `assets/diagrams/README.md`.

- Renamed every inline diagram reference in `_docs/*.md` to the
  canonical basenames used by the gallery (`02-introduction-four-layers`,
  `06-allocator-stack`, `12-reproducibility-conan-flow`, etc.) so
  inline embeds and the gallery resolve to the same SVG file.

- PRD dual-target sizing made explicit:
  - **PPTX deck**: 1.5–3 hours when delivered live.
  - **Jekyll site**: untimed; written for self-paced reading.
  - **Demos**: standalone runnable examples used in both targets;
    live during the talk *or* swapped for pre-recorded video.
  - Per-section "duration" fields in `_docs/` are reading time for
    the site; PPTX talk-time for the deck is in PRD §5.
  - Section table now labels its time column "PPTX talk" rather than
    a generic "duration", and PRD §5 spells out which sections are
    in the 1.5h cut vs. the 3h cut.

- Verification state unchanged: nothing has been walked through on
  Fedora 44 yet.

---

## Known divergences from the PRD

A running list of things the shipped tutorial does differently from
what the PRD says. Update as you discover them; the gap between
PRD and reality is usually instructive at retrospective time.

- (none yet)
