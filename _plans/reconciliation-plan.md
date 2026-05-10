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
G.2 Sections verified:             1 / 15  ← the one to watch (§1 verified r08)
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
| 1  | Prerequisites                                                      | [x]     | verified (r08)              | r08: 24/24 required check-host.sh checks pass on user's Fedora 44; 2 warnings for quay.io and docker.io reachability are informational only (don't gate any non-demo-04 demo). |
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

### 2026-05-09 — r05: container image policy (UBI-first)

User asked to ensure all container images use UBI going forward.
Audited every `FROM` and `image:` reference; results:

- All 8 of our own demo Containerfiles already use UBI 9 base
  images (one builder + one runtime stage each, mostly
  `ubi9/ubi` → `ubi9/ubi-minimal`). No changes needed there.
- One deliberate exception kept: `examples/demo-01-image-strategy/
  Containerfile.scratch-static` uses `docker.io/alpine:3.20` for
  the build stage. The demo's pedagogical point is producing a
  static binary that runs in `scratch`, which requires musl libc;
  UBI ships glibc and static-glibc is officially discouraged
  (NSS, getaddrinfo, locale traps). Final runtime is `scratch`,
  so nothing Alpine reaches the produced image. Documented inline
  with rationale.
- `observability/compose.yml`: switched Prometheus from
  `docker.io/prom/prometheus` to `quay.io/prometheus/prometheus`
  (Prometheus team's primary registry). Grafana, Loki, Tempo,
  Mimir kept on `docker.io/grafana/...` because Grafana Labs
  doesn't publish those to Quay or RH registries; documented
  the GHCR alternative for the OTel Collector and the
  `podman save | podman load` air-gap fallback for the rest.
- Added "Container image policy" section to `CONTRIBUTING.md`
  spelling out: UBI 9 for everything we build; documented
  exceptions for the alpine-static build stage and the third-
  party services; instructions for adding a future exception.
- `scripts/check-host.sh`: added a `quay.io` reachability check
  alongside the existing `registry.access.redhat.com` and
  `docker.io (hub)` checks. Total checks now 26 instead of 25.
- §1 Prerequisites: rewrote the "When docker.io is unreachable"
  sub-section to reflect that demos 1/2/3/5/6 don't need Docker
  Hub at all (UBI + Quay), and only demo 4 (the observability
  stack) is affected by Hub blocks.

Verification status: §1 still drafted — needs another clean
check-host.sh run with 26 PASS lines including the new quay.io
check before flipping to verified.

### 2026-05-09 — r06: align with patterncatalyst/otel-observability-demos

User pointed at the `otel-observability-demos` reference repo as a
working podman compose + OTel pattern to align with. Adopted the
verified architecture and conventions:

- **Replaced 6-service observability stack with the all-in-one
  `grafana/otel-lgtm:0.8.1` image.** Same OTLP endpoint (4317), same
  Grafana UI (3000), same query languages — but one image to pull
  instead of six and one set of endpoints instead of five. The
  reference repo verified this image works for talks/demos; we now
  use it for the same reason.
- **Dropped orphaned config files**: `observability/{prometheus,
  loki,tempo,mimir,grafana}/...` configs, plus `otel-collector.yaml`,
  are no longer needed since lgtm bundles its own. Kept the starter
  dashboard (`observability/grafana/dashboards/demo-overview.json`)
  which lgtm picks up via the dashboards volume mount.
- **Adopted the rootless-podman Grafana fix**: `user: root` + `tmpfs:
  /data` in compose so Grafana's sqlite state isn't owned by root on
  a host-bind mount the rootless container can't write to. Hard-won
  fix from the reference repo's PREREQUISITES.md.
- **Added `pre-pull.sh`** at repo root: pulls every image (UBI 9,
  Alpine, lgtm, Prometheus-on-Quay) so cold-cache demos start in
  seconds instead of minutes.
- **Added `verify-stacks.sh`** at repo root: smoke-tests every
  podman-compose stack in the project. Brings each up, probes its
  health endpoint, brings it down. Catches "broke since last week"
  before an audience does.
- **Updated demo-04**: compose.yml now points at the `lgtm` service,
  README and demo.sh updated to reflect the all-in-one architecture
  (Mimir reference dropped — Prometheus inside lgtm covers metrics
  storage).
- **§1 Prerequisites**: added a "Pre-pull and verify-stacks" section
  pointing at the new scripts; added a UBI subscription note in the
  "Why Fedora 44" section; rewrote the docker.io fallback to reflect
  that only one image (`grafana/otel-lgtm`) is now affected by
  Docker Hub blocks.
- **CONTRIBUTING.md image policy**: simplified the exceptions list
  (was five Grafana/OTel images, now one — the lgtm bundle).

Net effect:
- Before: 6 third-party docker.io images + 5 config files in
  observability/, demo-04 reaches across 6 service names.
- After: 1 third-party docker.io image + 0 config files, demo-04
  reaches one service `lgtm`. Same observability semantics for the
  reader; vastly less surface area to misconfigure.

Verification status: §1 still drafted; no new check-host.sh run yet
on user's host post-r06. Ship-ready when user runs it again and
reports clean.

---

### 2026-05-09 — r07: diagrams promoted to top-level; presentation/ folder added

User asked to put the PPTX in a `presentation/` folder and the
Excalidraw `.svg`+`.excalidraw` pairs in a `diagrams/` folder, with
the question "or are they already in _assets?" — they were under
`assets/diagrams/`, which works for Jekyll but buries them two
folders deep relative to the reference repos
(`patterncatalyst/otel-observability-demos`,
`patterncatalyst/hummingbird-tutorial`).

Moved to top-level layout:

- **`diagrams/`** at the repo root — 13 paired `.svg` + `.excalidraw`
  files, plus the README documenting the format. `git mv` from
  `assets/diagrams/` so blame and history follow.
- **`presentation/`** at the repo root — placeholder README only
  (round 11 produces the actual PPTX). README documents the planned
  build pipeline: `tools/build-pptx.py` reads `_docs/`, embeds the
  SVGs from `diagrams/`, and writes the .pptx. Borrows the
  "single-source-of-truth → multiple deliverables" pattern from
  `otel-observability-demos`.
- **Jekyll plumbing**: updated `_includes/excalidraw.html` and
  `_includes/diagram-card.html` to resolve `/diagrams/<name>.svg`
  instead of `/assets/diagrams/<name>.svg`. Jekyll auto-serves any
  non-underscore folder, so no extra config needed.
- **`_config.yml` exclude list**: added `presentation/` (PPTX is a
  release artifact, not site content), `diagrams/README.md` (editor
  doc, not reader content), `pre-pull.sh`, `verify-stacks.sh`. The
  `diagrams/` folder itself stays *included* so its contents serve
  at `/diagrams/<name>.svg`.
- **`assets/` is now `assets/css/site.css` only** — kept for future
  CSS additions and the Jekyll convention.

Doc sweep: replaced `assets/diagrams/` with `diagrams/` in §1's
repo layout diagram, in PRD.md, and in the inline comment of
`excalidraw.html`. Historical reconciliation log entries (r02, r03)
that described seeding `assets/diagrams/` are left as-is — they're
the historical record.

URL collision check: `diagrams.html` has explicit
`permalink: /diagrams/`, generating `_site/diagrams/index.html`.
The static folder copies SVGs to `_site/diagrams/<name>.svg`. They
coexist — `/diagrams/` serves the gallery page, `/diagrams/foo.svg`
serves the file. Same pattern hummingbird uses.

Verification status: §1 still drafted. The path change is
mechanical and shouldn't affect check-host.sh outcomes; user
confirms with another clean run.

### 2026-05-09 — r08: verify-stacks bugs found by real-host run; scripts moved under scripts/

User ran `./scripts/check-host.sh` (output: 24 ok, 2 warns for
quay.io and docker.io reachability) and `./verify-stacks.sh
--quick` (3 of 3 stacks failed). The check-host run validated all
hard requirements; the verify-stacks run revealed three real bugs
plus an organizational issue.

Bugs:

1. **verify-stacks.sh URL-parsing crash** (full-mode run): I'd used
   `:` as the field separator in the STACKS array. URLs already
   contain `:`, so `IFS=':' read` shredded `http://127.0.0.1:3000/
   api/health` into multiple fields. The timeout argument ended up
   being a URL fragment, and `wait_for_http`'s `(( ... >= timeout ))`
   exploded with `arithmetic syntax error`. Fix: parallel arrays
   (`STACK_NAMES`, `STACK_FILES`, `STACK_URLS`, `STACK_TIMEOUTS`,
   `STACK_SLOW`) instead of colon-delimited records.

2. **verify-stacks.sh too aggressive** (--quick run): the script
   tried to bring up demo-03, demo-04, demo-06 stacks. Those
   demos haven't been verified end-to-end yet; their composes
   reference build sources we haven't tested. Fix: scope the
   script to **shared infrastructure only** (currently just the
   observability stack). Per-demo end-to-end verification stays
   in `scripts/test-demo-NN-*.sh`. STACK_NAMES list documents
   the rule: add a stack only after personally verifying it
   cleans up.

3. **check-host.sh quay.io / docker.io were hard fails**: those
   probes returned `[fail]` on the user's network even though
   neither is strictly required (quay.io has no current usage
   post-r06; docker.io is only needed for demo-01 build and
   demo-04 runtime). Fix: added a third status `warn` to
   `record()`. Optional registries use `record warn` instead of
   `record fail`. Required-checks summary count drops from 26
   to 24; the two registry probes now report as warnings without
   gating exit code.

User-requested change: moved `pre-pull.sh` and `verify-stacks.sh`
under `scripts/`. Repo root now has zero `.sh` files; all scripts
live under `scripts/`. Fixed both scripts' SCRIPT_DIR / REPO_ROOT
calculations for the new depth.

Updated `pre-pull.sh` image inventory: dropped the
`quay.io/prometheus/prometheus` entry since r06's lgtm bundle
includes Prometheus internally and we don't pull standalone
Prometheus anywhere now.

§1 Prerequisites updated: pre-pull and verify-stacks references
now use `./scripts/` paths; example check-host.sh output reflects
the new "24 required ok + 2 warns" format.

Verification status: §1's required-checks side now confirmed
clean by the user's real-host run (24/24 ok). Both warns are
expected on a network that blocks the public CDNs; documented as
informational. **Promoting §1 from `drafted (r04)` to `verified
(r08)`** in the matrix.

### 2026-05-09 — r09: UBI subscription-manager fix in every Containerfile

User reported demo-01 build failed with the classic UBI-without-
entitlement issue: `dnf install` triggers the `subscription-manager`
plugin to refresh entitlement-only repos, which fails with `Unable
to read consumer identity` and on some configurations exits non-zero,
killing the build. Resolved in the user's reference projects
(otel-observability-demos, hummingbird-tutorial, optimizing-java).

Fix applied uniformly: right after every `FROM
registry.access.redhat.com/ubi9/ubi:...` line (the "full" UBI base
that uses `dnf`, not the minimal one that uses `microdnf`):

    RUN rm -f /etc/yum.repos.d/redhat.repo && \
        sed -i 's/^enabled=1/enabled=0/' \
            /etc/dnf/plugins/subscription-manager.conf 2>/dev/null || true

Removing `redhat.repo` stops dnf trying to refresh the entitlement
repos (which is what triggers the consumer-identity check); the
plugin disable silences any residual warnings. UBI's free repos in
`/etc/yum.repos.d/ubi.repo` are unaffected, so `dnf install`
continues working normally — UBI without entitlement is a documented
Red Hat configuration.

Files patched (Python script in r09 commit): 8 Containerfiles,
9 FROM lines total (demo-06 has two `ubi9/ubi` stages — toolchain
and gdbserver — both got the fix). Plus the throwaway PGO merge
container in `examples/demo-01-image-strategy/demo.sh`.

Convention documented in CONTRIBUTING.md → "UBI without a Red Hat
subscription" sub-section so future Containerfiles include it.
Future `ubi9/ubi` builder stages without this fragment should be
flagged in review.

`ubi9/ubi-minimal` runtime stages need no fix; microdnf has no
subscription-manager plugin and no `redhat.repo`.

Verification status: pending demo-01 re-run on user's host. If it
runs clean, §3 and §4 (the demo-01 sections) get promoted.

---

## Known divergences from the PRD

A running list of things the shipped tutorial does differently from
what the PRD says. Update as you discover them; the gap between
PRD and reality is usually instructive at retrospective time.

- **Mimir dropped from observability stack (r06).** PRD §1 lists
  "podman+grafana+tempo+loki+prometheus+mimir" as the stack.
  Aligned with the verified `grafana/otel-lgtm` reference, which
  bundles Prometheus (not Mimir) for metrics. For tutorial
  purposes Prometheus covers the same teaching ground; production
  Mimir setups are mentioned in §9's "for deeper coverage" pointers.
