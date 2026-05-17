---
title: "Demo 1 — Image Strategy: UBI, ubi-micro, multi-stage, LTO, PGO"
description: "Builds the same trivial C++23 HTTP service three different ways and compares the results. Adds a Profile-Guided Optimization pass on top of the best variant and measures the additional delta. Every optimization is something you'd actually…"
order: 1
layout: example
sectionid: examples
permalink: /examples/demo-01-image-strategy/
demo_dir: demo-01-image-strategy
github_path: examples/demo-01-image-strategy
---

> The full source for this demo lives in [`examples/demo-01-image-strategy/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/demo-01-image-strategy) — clone the repo, `cd` in, and `./demo.sh`.


Tutorial sections:
[§4 Container Strategy]({{ '/docs/04-image-strategy/' | relative_url }}) +
[§5 Compile-Time Wins]({{ '/docs/05-compile-time-wins/' | relative_url }})

Builds the same trivial C++23 HTTP service three different ways and
compares the results. Adds a Profile-Guided Optimization pass on top
of the best variant and measures the additional delta. Every
optimization is something you'd actually do in production; the
demo just makes the deltas visible.

## Why this matters

Image strategy is the lowest-hanging-fruit performance and security
win in containerized C++. Every choice — base image, multi-stage
boundary, LTO, PGO — compounds across three real concerns the
production team cares about:

- **Registry pull time.** A 689 MB image takes ~5× longer to pull
  on a cold node than a 26 MB one, which directly extends
  cold-start latency every time the orchestrator schedules a new
  replica.
- **Security surface.** The single-stage image ships GCC, ld, the
  C library headers, and dozens of build dependencies into
  production. None of those are needed at runtime; all of them
  are CVE vectors. Multi-stage drops them entirely.
- **Runtime performance.** LTO inlines across translation units
  that the per-TU compiler can't see; PGO biases hot/cold paths
  toward measured reality. On request-handler hot paths, the
  combined gain is typically 4-7% for this kind of code — small,
  real, and free once the build pipeline is in place.

§4 and §5 of the tutorial develop the underlying mechanics; this
demo makes the numbers visible.

## What this demo shows

Three Containerfile strategies for the same C++23 source, plus a
PGO pass:

1. **`ubi-multistage`** — UBI builder + UBI-minimal runtime,
   multi-stage, LTO on. The recommended production default.
2. **`ubi-micro`** — UBI builder, runtime is `ubi9/ubi-micro`
   (~30 MB) with libstdc++ statically linked into the binary. The
   minimum surface area for a typical C++ service.
3. **`single-stage-naive`** — A single-stage build that ships the
   toolchain in the runtime image, no LTO, no multi-stage. The
   "what not to do" baseline.
4. **`ubi-multistage + PGO`** — Two-pass build: instrument the
   multi-stage variant, run a synthetic training workload to
   collect a profile, rebuild with the profile applied. Shows what
   PGO buys on top of LTO.

Each variant is built and timed; each is then driven with `hey` to
collect p50/p95/p99 latency under load.

## How to run

```bash
./demo.sh
```

Expected runtime: 5-10 minutes on a fresh cache, ~1 minute on a
warm cache. The script prints a small comparison table: image
size, build time, and a `hey` benchmark for each build.

## What you'll see

Representative output on a Fedora 44 host with gcc-toolset-14 and
Podman 5.x:

```
                          size      build      p50/p95/p99 (ms)
single-stage-naive        689 MB     14 s       0.81 / 1.91 / 4.20
ubi-multistage            114 MB     38 s       0.79 / 1.85 / 4.08
ubi-multistage + PGO      114 MB     78 s       0.74 / 1.71 / 3.78
ubi-micro                  26 MB     45 s       0.79 / 1.86 / 4.06
```

## How to read the output

The headline numbers — what to look for first:

- **26× size drop** from naive single-stage to ubi-micro. Almost
  all of that is "the toolchain leaving production".
- **~4-5% p99 improvement** from PGO on top of LTO. Modest in
  absolute terms but real; on a service taking 10K rps in
  production, it's a meaningful shift.
- **No measurable p50 difference** between ubi-multistage and
  ubi-micro. The runtime cost of static-vs-dynamic libstdc++ is
  invisible at this scale.

A few rules of thumb when you're reading the table:

- **If `single-stage-naive` is faster than the multi-stage builds**,
  something's wrong with the multi-stage LTO config — investigate
  the build flags rather than declaring multi-stage useless.
- **If PGO is slower than the un-PGO'd LTO build**, the training
  workload was unrepresentative. PGO with a wrong profile is worse
  than no PGO because it actively pessimizes the real hot path.
- **ubi-micro is the right default for production** *unless* you
  need glibc features the static-libstdc++ build doesn't pick up
  (NSS modules, dlopen of glibc-dependent libraries). For a typical
  C++ service: use it.

## Files

- `Containerfile.ubi-multistage` — preferred default
- `Containerfile.ubi-micro` — minimal-image variant
  (UBI-micro runtime, static libstdc++)
- `Containerfile.single-stage-naive` — anti-pattern baseline
- `Containerfile.pgo` — instrumented build for PGO step 1
- `CMakePresets.json` — the three release configurations
- `conanfile.txt` — pinned deps (httplib for the HTTP side)
- `src/main.cpp` — the trivial service
- `demo.sh` — orchestration; runs all three builds + PGO + `hey`

## Caveats and gotchas

- **PGO training workload matters.** The training run uses a
  synthetic `hey` pattern that may not match your real workload.
  In production, capture an actual traffic profile (e.g. via tcpreplay
  or a recorded sample of production traffic) and feed THAT to the
  instrumented binary.
- **ubi-micro lacks a package manager.** If your application calls
  into NSS, glibc locale data, or anything else that expects the
  full glibc runtime, the static-libstdc++ ubi-micro build may
  surprise you at runtime. Test against your real workload before
  switching.
- **Image size measurements include layers.** The numbers here are
  `podman images --format "{{.Size}}"` output, which counts all
  layers. Squashing layers (`podman build --squash`) reduces the
  numbers but loses caching benefits.
- **PGO build time roughly doubles.** The instrumented build, the
  training run, and the rebuilt-with-profile build all happen
  sequentially. If your CI budget can't absorb that, do PGO only
  on release branches.

## Source materials

This demo deepens material from the project's
[**bibliography**]({{ '/bibliography/' | relative_url }}):

- **Andrist & Sehr, *C++ High Performance* 2e, ch. 5** — compile-
  and link-time optimizations, the LTO / PGO mechanics
- **Iglberger, *C++ Software Design*, ch. 1** — the case for
  measurable performance work as a design discipline, not a
  last-mile activity

## Linked tutorial sections

- [**§4 Container Strategy**]({{ '/docs/04-image-strategy/' | relative_url }}) — base
  image choice (UBI vs ubi-micro vs scratch) and the multi-stage
  build pattern. This demo's three Containerfiles are §4's worked
  example.
- [**§5 Compile-Time Wins**]({{ '/docs/05-compile-time-wins/' | relative_url }}) — what
  LTO actually does, when PGO is worth the build-time tax,
  `constexpr` and the related compile-time tools. The PGO step
  in this demo is §5's measurable claim.
- [**§13 Reproducibility & ABI**]({{ '/docs/13-reproducibility-abi/' | relative_url }}) —
  image labels and reproducible-image discipline. This demo's
  Containerfiles use the labeling pattern §13 develops.
