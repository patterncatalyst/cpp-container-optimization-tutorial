---
title: "Statelessness 11 — Build tooling (vendored helpers)"
description: "The runnable slice of compendium Doc 11's build-tooling appendix: the cgroup_helper and psi_reader helpers built as static libraries, unit-tested with GoogleTest over their pure parsers, and exercised by a binary you run under different cgroup caps to watch cpu_limit_cores() track --cpus while hardware_concurrency() does not."
order: 212
card_eyebrow: "Compendium · <strong>Doc 11</strong>"
card_title: "Build tooling (vendored helpers)"
card_blurb: "The vendored helpers made runnable: cgroup_helper + psi_reader as static libs, a GoogleTest suite over their pure parsers, and a binary swept under --cpus/--memory caps so cpu_limit_cores() is shown tracking the cgroup while hardware_concurrency() does not."
layout: example
sectionid: examples
permalink: /examples/statelessness-11-build-tooling/
demo_dir: statelessness/11-build-tooling
github_path: examples/statelessness/11-build-tooling
---

> The full source for this example lives in [`examples/statelessness/11-build-tooling/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/statelessness/11-build-tooling) — clone the repo, `cd` in, and `./demo.sh`.

Compendium reference:
[Doc 11 — Build tooling appendix]({{ '/reference/statelessness/11-build-tooling/' | relative_url }})

Tutorial sections:
[§13 Reproducibility & ABI]({{ '/docs/13-reproducibility-abi/' | relative_url }}) +
[§12 Static Analysis & Debugging]({{ '/docs/12-analysis-debugging/' | relative_url }})

Doc 11 is a build-tooling reference — Conan profiles, the library/version
inventory, the C++23 toolchain matrix, the multi-stage Containerfile pattern,
and full source for three small vendored helpers that earlier docs referenced
but never shipped runnable. This example is the runnable slice: it takes the
two self-contained helpers — `cgroup_helper` (the cgroup limit reader) and
`psi_reader` (the PSI parser) — and makes them real, built as static
libraries, unit-tested with GoogleTest, and exercised under real cgroup caps.

## Why this matters

The build is the part of a service that's easy to treat as an afterthought,
until an unreproducible build or a wrong runtime reading costs a day:

- **The cgroup helper is the punchline of the whole threading story.** The
  threading section showed that `hardware_concurrency()` lies under a `--cpus`
  cap; this is the ~30-line helper that reads the *truth* from `cpu.max`.
  Seeing it track the cap while `hardware_concurrency()` doesn't is the
  concrete payoff of every "size to the cgroup" claim in the compendium.
- **A test gate in the build keeps the helpers honest.** Parsing `cpu.max`,
  `memory.max`, and PSI strings has edge cases (unconstrained sentinels,
  trailing newlines, the `full` line that CPU pressure omits). Wiring the
  GoogleTest suite as a *build gate* means a regression in those parsers fails
  the image, not production.
- **Reproducibility is a build-tooling discipline.** Pinned Conan versions, a
  lockfile, dev/release profiles, and a multi-stage Containerfile are what
  make "it built on my machine" mean "it builds anywhere." This example is a
  small, complete instance of that setup.

## What this demo shows

**The cgroup reader** (`vendor/cgroup_helper/`). `cpu_limit_cores()` reads
cgroup v2 `cpu.max` (falling back to v1, then to scheduler affinity);
`memory_limit_bytes()` reads `memory.max`. This is the helper the threading
section uses to size thread pools against the container budget instead of
`hardware_concurrency()`, which lies under a `--cpus` cap.

**The PSI parser** (`vendor/psi_reader/`). Parses the `some`/`full` pressure
lines from `/proc/pressure/*` or a cgroup's `*.pressure`. Best-effort at
runtime, since PSI must be enabled in the kernel (`CONFIG_PSI=y`) and exposed
to the container.

**Testable parsers, live readers.** Each helper separates parsing from file
I/O: `parse_cpu_max`, `parse_mem_max`, and `parse_line` are pure functions
tested deterministically against fixture strings, while the live readers wrap
them around the real `/sys/fs/cgroup` and `/proc/pressure` files. The gtest
suite needs no live cgroup; the demo binary proves the live path under real
caps.

**The cap sweep.** The demo runs the same image with no caps, then
`--cpus=1.5`, then `--cpus=0.5 --memory=256m`, and you watch
`cpu_limit_cores()` report each limit while `hardware_concurrency()` keeps
reporting the full host count — the gap a container-aware service closes.

## How to run

```bash
cd examples/statelessness/11-build-tooling
podman compose -f compose.yml build   # build + run the gtest gate
./demo.sh                              # tests + the cap sweep
./demo.sh --clean                      # remove the image
```

The first build compiles GoogleTest (~30 s); the helpers and demo are tiny.
GoogleTest is the only Conan dependency, and it's test-only.

## What you'll see

Actual output from a host run on Fedora 44 (GCC 14, 22 logical cores,
Podman 5.x) — the gtest gate, then the same binary under three cap settings:

```
==> Act 1: unit tests (gtest over the pure parsers, in-container)
    [==========] Running 15 tests from 4 test suites.
    [  PASSED  ] 15 tests.

==> Act 2: unconstrained (no caps)
    in_container()        : false
    cpu_limit_cores()     : 22 cores       (host nproc fallback)
    hardware_concurrency(): 22
    memory_limit_bytes()  : unbounded

==> Act 3: podman run --cpus=1.5
    cpu_limit_cores()     : 1.5 cores       <- read from cpu.max "150000 100000"
    hardware_concurrency(): 22              (still the host count)

==> Act 4: podman run --cpus=0.5 --memory=256m
    cpu_limit_cores()     : 0.5 cores
    hardware_concurrency(): 22              (the gap a naive pool would oversubscribe)
    memory_limit_bytes()  : 268435456 bytes (256.0 MiB)
```

## How to read the output

- **Act 1's 15/15 is a build gate, not just a demo step.** The same suite
  runs at image-build time; a failing parser test fails the build. Seeing it
  green in-container is the gate confirming the parsers are correct on this
  toolchain.
- **`cpu_limit_cores()` tracks the cap; `hardware_concurrency()` never moves.**
  This is the entire lesson in two numbers. Under `--cpus=1.5` the helper reads
  `1.5`; under `--cpus=0.5` it reads `0.5`; `hardware_concurrency()` reports
  `22` the whole time. A pool sized to the latter would oversubscribe 44:1
  against half a core.
- **`memory_limit_bytes()` reads the exact cap.** `268435456` is precisely
  256 MiB — the helper read `memory.max` directly, so a cache sized from it
  respects the cgroup rather than the host's RAM.
- **`in_container()` reading `false` is expected under rootless podman.** See
  the caveat below — it's a known limitation of cgroup-path sniffing, not a
  defect, and it does *not* affect the limit readers, which are the
  load-bearing path.

## Files

- `vendor/cgroup_helper/` — cgroup v2/v1 CPU + memory limit reader (the
  threading section's helper), split into pure parsers + live readers
- `vendor/psi_reader/` — PSI `some`/`full` parser, same parser/reader split
- `src/main.cpp` — prints the live readings (the demo binary)
- `tests/test_helpers.cpp` — the GoogleTest suite over the pure parsers
- `CMakeLists.txt` — two static libs + demo + test suite
- `conanfile.py` — GoogleTest (test-only, the single Conan dependency)
- `Containerfile` — builder runs the test gate; `ubi-minimal` runtime
- `compose.yml` — build + default unconstrained run
- `demo.sh` — the gtest gate + the cgroup-cap sweep

## Caveats and gotchas

- **`in_container()` reads `false` under rootless podman — and that's not a
  bug.** A rootless container's `/proc/1/cgroup` often reads `0::/` with none
  of the docker/libpod/`.scope` markers the heuristic sniffs for, so the
  detection underreports. It does **not** affect the limit readers:
  `cpu_limit_cores()` and `memory_limit_bytes()` read `cpu.max` / `memory.max`
  directly and track the caps exactly (as the sweep shows). Treat
  `in_container()` as a best-effort hint, not an authority.
- **PSI is best-effort.** It requires `CONFIG_PSI=y` in the kernel and the
  pressure files to be exposed to the container. The reader degrades
  gracefully when they're absent — don't treat a missing PSI reading as a
  failure.
- **The parsers are pure on purpose.** Parsing is separated from file I/O so
  the tests need no live cgroup. When you extend a parser, add a fixture-string
  test alongside it; that's what keeps the build gate meaningful.
- **The third helper, `otel_propagator`, is omitted.** Doc 11 lists three
  vendored helpers; the OpenTelemetry propagator needs opentelemetry-cpp, which
  this tutorial deliberately doesn't pull in. The full Conan profile, library
  inventory, and toolchain matrix from Doc 11 stay as reference prose on the
  compendium page.

## Source materials

This example deepens material from the project's
[**bibliography**]({{ '/bibliography/' | relative_url }}):

- **Andrist & Sehr, *C++ High Performance* 2e, ch. 1** — the build, the
  toolchain, and measuring against the real environment; the cgroup reading is
  the "measure reality" discipline applied to resource limits
- **Iglberger, *C++ Software Design*, ch. 2** — separating the pure parser from
  the I/O-bound reader as a testability and single-responsibility design
- **Enberg, *Latency*, ch. 3** — why the cgroup CPU budget (not the host count)
  is the number that governs scheduling latency, the reason this helper exists

## Linked tutorial sections

- [**§13 Reproducibility & ABI**]({{ '/docs/13-reproducibility-abi/' | relative_url }}) —
  Conan lockfiles, CMake presets, hermetic builds, and the multi-stage image;
  this example is a small complete instance of that build discipline, with the
  gtest gate baked into the build.
- [**§12 Static Analysis & Debugging**]({{ '/docs/12-analysis-debugging/' | relative_url }}) —
  the dev/release profile split and the build-as-quality-gate idea; running the
  test suite as a build stage is the same principle as the static-analysis
  pipeline there.

## The build-tooling angle

The example doubles as a small worked instance of Doc 11's build setup: the
helpers are Conan-free static libraries, GoogleTest comes via Conan as a
test-only dependency, and the multi-stage Containerfile runs the gtest suite
as a build gate so a failing parser test fails the image. The third helper the
doc lists, `otel_propagator`, needs opentelemetry-cpp, which this tutorial
deliberately doesn't pull in; the full Conan/CMake/toolchain reference material
stays as prose on the compendium page.

## Where it sits in the compendium

This is the build that produces every other example in the arc. The
`cgroup_helper` here is the helper the
[threading example]({{ '/examples/statelessness-05-threading/' | relative_url }})
relies on to size pools, and the one the capstone
([Doc 10]({{ '/reference/statelessness/10-grpc-microservices/' | relative_url }}))
uses to size its gRPC server thread pool from the CPU budget. The multi-stage,
pinned, test-gated build shown here is the pattern every runnable example in
the compendium is built with.
