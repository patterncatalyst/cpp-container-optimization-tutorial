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

Doc 11 is a build-tooling reference — Conan profiles, the library/version
inventory, the C++23 toolchain matrix, the multi-stage Containerfile
pattern, and full source for three small vendored helpers that earlier docs
referenced but never shipped runnable. This example is the runnable slice:
it takes the two self-contained helpers — `cgroup_helper` (Doc 05's cgroup
limit reader) and `psi_reader` (Doc 05's PSI parser) — and makes them real,
built as static libraries, unit-tested with GoogleTest, and exercised under
real cgroup caps.

## What it demonstrates

**The cgroup reader.** `cpu_limit_cores()` reads cgroup v2 `cpu.max` (with a
v1 and a scheduler-affinity fallback) and `memory_limit_bytes()` reads
`memory.max`. This is the helper Doc 05 uses to size thread pools against
the container budget rather than `hardware_concurrency()`, which lies under
a `--cpus` cap.

**The PSI parser.** Parses the `some`/`full` pressure lines from
`/proc/pressure/*` or a cgroup's `*.pressure`. Best-effort at runtime, since
PSI must be enabled in the kernel and exposed to the container.

**Testable parsers, live readers.** Each helper separates parsing from file
I/O: the parsers are pure functions tested deterministically against
fixture strings, while the live readers wrap them around the real
`/sys/fs/cgroup` and `/proc/pressure` files. The gtest suite needs no live
cgroup; the demo binary proves the live path.

**The cap sweep.** The demo runs the same image with no caps, then
`--cpus=1.5`, then `--cpus=0.5 --memory=256m`, and you watch
`cpu_limit_cores()` report each limit while `hardware_concurrency()` keeps
reporting the full host count — the gap a container-aware service closes.

## The build-tooling angle

The example doubles as a small worked instance of Doc 11's build setup: the
helpers are Conan-free static libraries, GoogleTest comes via Conan as a
test-only dependency, and the multi-stage Containerfile runs the gtest suite
as a build gate so a failing parser test fails the image. The third helper
the doc lists, `otel_propagator`, needs opentelemetry-cpp, which this
tutorial deliberately doesn't pull in; the full Conan/CMake/toolchain
reference material stays as prose on the compendium page.
