---
title: "Compile-Time Wins: LTO, PGO, constexpr"
order: 4
description: Three compiler-side levers that move runtime performance, what each costs in build time, and a worked PGO pipeline that doesn't skip the workload step.
duration: 12 minutes
---

## Learning objectives

By the end of this section you can:

- Explain what LTO does that `-O3` alone doesn't, and why thin
  LTO is usually the right default.
- Run a three-step PGO pipeline (instrumented build → recorded
  workload → optimized build) and show the binary size + perf
  delta the workload produced.
- Identify code paths where `constexpr` (and C++23 `consteval` /
  `constinit`) actually move runtime cost, versus paths where it
  produces no measurable change.
- Predict the build-time cost of each technique on a 200KLOC
  service.

## Diagram

{% include excalidraw.html name="04-compile-time-pgo-flow" caption="The three-step PGO pipeline: instrumented build → workload run → optimized build" %}

## Planned content

- LTO: what cross-translation-unit inlining and dead code
  elimination buys you. Thin LTO vs full LTO; when full LTO is
  worth the wall-clock cost.
- PGO with Clang's instrumentation profiler:
  `-fprofile-generate` → run a *representative* workload → merge
  with `llvm-profdata` → `-fprofile-use`. The middle step is
  where most attempts go wrong.
- The synthetic-workload trap: PGO data from a benchmark that
  doesn't look like production traffic teaches the compiler the
  wrong things.
- `constexpr`: the difference between "computed at compile time
  if possible" (`constexpr`) and "must be computed at compile
  time" (`consteval`), and what that buys for static lookup
  tables, configuration parsing, and small DSLs.
- C++23 additions: `if consteval`, expanded standard-library
  `constexpr` (more of `<algorithm>`, `<vector>`, `<string>` is
  now constexpr).

## Demo

[`examples/demo-01-image-strategy/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/demo-01-image-strategy)
also exercises this section: the `demo.sh` builds a non-LTO
baseline, an LTO build, and a PGO build, runs each with `hey`,
and prints the wall-clock and image-size deltas.

## For deeper coverage

- Andrist & Sehr, *C++ High Performance*, ch. 3 (compiler
  optimizations) and ch. 9 (`constexpr` patterns)
- Iglberger, *C++ Software Design*, ch. 6 (the cost model behind
  `constexpr`-heavy designs)

## What's next

§5 turns the next knob: with the toolchain settled, what data
structures should the binary be made of?
