---
title: "Compile-Time Wins: LTO, PGO, constexpr"
order: 5
description: Three compiler-side levers that move runtime performance — link-time optimization, profile-guided optimization, and constexpr — what each costs in build time, and a worked PGO pipeline that doesn't skip the workload step.
duration: "10 minutes"
---

## Learning objectives

By the end of this section you can:

- Explain what LTO does that `-O3` alone can't, and why thin
  LTO is usually the right default.
- Run a three-pass PGO pipeline (instrumented build → recorded
  representative workload → optimized build) and show the build-
  time, image-size, and perf delta the workload produced.
- Identify code paths where `constexpr` (and C++20/23
  `consteval` / `constinit`) actually move runtime cost,
  versus paths where it produces no measurable change.
- Predict the build-time cost of each technique on a moderately-
  sized service, and decide which to invest in.
- Read a binary back at incident time and tell whether LTO and
  PGO actually fired.

## Diagram

{% include excalidraw.html name="05-compile-time-pgo-flow" caption="Three-pass PGO: instrument → profile → optimize." %}

## What -O3 leaves on the table

`gcc -O3` is good. It vectorizes, inlines aggressively within a
translation unit, unrolls loops, eliminates dead code. What it
*can't* do — by design — is optimize across translation-unit
boundaries. Each `.cpp` file is compiled in isolation, gets its
own `.o`, and the linker stitches the object files together at
the end without re-running the optimizer.

That leaves two large pieces of performance on the floor:

1. **Cross-TU inlining.** A small accessor defined in one `.cpp`
   and called a million times from another is *not* inlined by
   `-O3` alone. The linker doesn't inline; the compiler can't
   see across files. The call survives to the binary as a real
   `call` instruction.
2. **Branch and layout decisions made on guesses.** Without
   knowing which `if` branch is hot, `-O3` lays out code as if
   either side is equally likely. Without knowing which functions
   are co-called, `-O3` lays out the binary alphabetically by
   default. Both are guesses, and both cost instruction-cache
   misses on real workloads.

LTO addresses the first. PGO addresses the second. They're
complementary — using both is normal. Demo-01 builds variants
with each combination so you can see the size and speed delta.

## LTO — the link-time inliner

**Link-Time Optimization** moves optimization past the
per-`.cpp` boundary. Instead of emitting object code, the
compiler emits an intermediate representation (LLVM IR for
clang, GIMPLE for gcc). The linker then runs the optimizer
*again*, this time with visibility across every translation
unit in the binary.

The result: small accessor functions get inlined across files.
A `constexpr` template instantiated in three places gets folded
into one symbol. Functions that are never reachable from `main`
get dropped. Vtables for never-overridden classes get
devirtualized.

Two flavors:

| Mode | Flag | What it does | Wall-clock cost |
|---|---|---|---|
| **Thin LTO** | `-flto=thin` | parallelizable across the linker invocation; per-file summary indexes | small (10-20% link time) |
| **Full LTO** | `-flto` | whole-program optimization; serial in the linker | large (2-5× link time) |

**Thin LTO is the default to reach for.** It parallelizes
well on modern build machines, the link-step cost is small
relative to the build-step cost, and you get most of the
inlining benefit. Full LTO is worth the extra link time only
when you've measured the gap and the binary is going through
millions of cold-cache executions where every byte of `.text`
matters.

A CMake project enables thin LTO with one line:

```cmake
set(CMAKE_INTERPROCEDURAL_OPTIMIZATION TRUE)
# or per-target:
# set_target_properties(myservice PROPERTIES INTERPROCEDURAL_OPTIMIZATION TRUE)
```

CMake translates that to `-flto=thin` for clang and `-flto=auto`
for gcc.

## PGO — three passes, one feedback loop

**Profile-Guided Optimization** is the lever for layout and
branch decisions. The idea is simple: instead of guessing which
branches are hot and which functions are co-called, *measure
it on a representative workload*, then re-compile with that
data in hand.

The pipeline is three passes (see the diagram above):

```bash
# Pass 1: build with instrumentation
cmake -DCMAKE_CXX_FLAGS="-fprofile-generate=$PWD/profdata" \
      -DCMAKE_EXE_LINKER_FLAGS="-fprofile-generate=$PWD/profdata" \
      --preset conan-release
cmake --build --preset conan-release

# Pass 2: run a *representative* workload against the instrumented binary
./build/Release/myservice &
hey -z 60s -c 50 http://localhost:8080/realistic-mix-of-endpoints
wait

# Pass 3: merge the raw profile data, rebuild with it
llvm-profdata merge -output=myservice.profdata profdata/
cmake -DCMAKE_CXX_FLAGS="-fprofile-use=$PWD/myservice.profdata" \
      -DCMAKE_EXE_LINKER_FLAGS="-fprofile-use=$PWD/myservice.profdata" \
      --preset conan-release
cmake --build --preset conan-release
```

Demo-01 wraps all three in a `./demo-pgo.sh` script. The
instrumented binary in pass 1 is roughly **10% slower** than the
baseline and **~10 MB bigger** on disk (it carries counter
arrays for every branch and call site); demo-01's
`pgo-instrumented` image is 124 MB vs the `pgo` final image at
114 MB. That's not a deployment artifact — it exists for the
duration of pass 2.

The compiler uses the recorded data in pass 3 for several
specific decisions:

- **Function layout.** Hot functions cluster together so they
  fit in fewer pages of the instruction cache; cold functions
  (error paths, slow paths, startup-only code) get pushed to
  the end of `.text`.
- **Inlining heuristics.** A function called from a hot site
  gets inlined even if it's slightly larger than the `-O3`
  inline threshold; a function called only from a cold site
  doesn't get inlined even if it'd fit.
- **Branch reordering.** `if (likely)` paths fall through
  (no branch taken); `if (unlikely)` paths get the jump. This
  is implicit `__builtin_expect` for the whole binary.
- **Register allocation.** Variables hot in the recorded
  profile get registers; variables cold in the profile go to
  the stack.

Typical PGO impact on a CPU-bound C++ service is **5-25%
throughput improvement**, but the variance is huge — read the
caveat in the next section. Combined with thin LTO, **15-30%
is realistic** for workloads that aren't already I/O-bound.

## The representative-workload trap

The middle step of the PGO pipeline is where most attempts go
wrong. The compiler optimizes for *what the recorded workload
did*, which is what you want only if the recorded workload
matches production.

A few patterns to avoid:

- **Microbenchmark profiles.** Running a tight loop against
  one endpoint teaches the compiler that one endpoint is the
  whole program. Function layout favors that endpoint; cold
  paths (error handling, secondary endpoints) get pessimized.
  In production, the *real* endpoint mix runs slower than the
  pre-PGO build.
- **Single-tenant profiles.** Recording with a single client
  hitting a service teaches the compiler that there's no
  contention — every branch in the connection-pool code looks
  monomorphic. Production with 200 concurrent clients hits
  branches PGO marked "cold".
- **Profiles from staging hardware that doesn't match prod.**
  Branch frequencies don't change much across hardware, but
  cache layout decisions do — function clustering is tuned to
  the recorded I-cache size.

**The fix is to record from a real workload, or from a load
generator that emits a real workload mix.** Demo-01's
`./demo-pgo.sh` uses `hey` with a mix of endpoints and
concurrencies derived from a published trace; adapt yours to
your service's actual traffic. If you can't generate
realistic load offline, record a profile from a canary
deployment carrying live traffic instead.

## `constexpr`, `consteval`, `constinit` — move work to compile time

LTO and PGO are about the compiler making smarter decisions
with the code you wrote. `constexpr` and its C++20 cousins
let *you* decide that work doesn't need to happen at runtime
at all.

| Keyword | Meaning | Use it for |
|---|---|---|
| `constexpr` | "may be computed at compile time *if all inputs are constant expressions*" | math helpers, type-trait predicates, small lookup tables |
| `consteval` | "must be computed at compile time; error if it isn't" | force compile-time evaluation; reject runtime callers |
| `constinit` | "initialized at compile time; ordinary writability afterward" | static variables with non-trivial init (avoid the static init order fiasco) |
| `if consteval` (C++23) | "branch at compile time based on whether evaluation context is constant" | one body for constant evaluation, another for runtime |

Where `constexpr` actually moves runtime cost:

- **Lookup tables.** A 256-entry sin/cos table, a CRC-32
  polynomial table, an HTTP-status-code-to-message map. Built
  at compile time, the table is in `.rodata` and the lookup is
  one cache-line load.
- **Configuration parsing.** A version number, a feature-flag
  string, a build-info JSON — parse it `consteval` and the
  parsed result is a compile-time constant.
- **Small DSLs.** A `printf`-format-string validator, a regex
  pattern compiler, a SQL-query parser. Where the input is
  known at build time, the parser runs at build time and the
  binary holds only the parsed AST.

Where `constexpr` produces no measurable change:

- **Functions called once at startup with runtime inputs.**
  `constexpr` qualifiers on `parse_config_file(argv[1])` do
  nothing useful — the input isn't a constant expression, so
  the function runs at runtime regardless.
- **Functions where the body still calls runtime functions.**
  `constexpr` doesn't make `malloc` or `iostream` operations
  constant-evaluatable. Functions that internally allocate (a
  `std::string` growing past SSO, for instance) can't run at
  compile time.

C++20 expanded what's permissible inside `constexpr` functions
considerably — `std::vector`, much of `<algorithm>`, parts of
`<string>` became constexpr. C++23 extended this further with
`if consteval` for branch-on-context patterns and more
`<numeric>` / `<bit>` constexpr coverage.

The data structure consequences of constexpr-heavy designs
(constant-time vs cache-friendly trade-offs) are
[where §6 picks up](../06-stl-layout/).

## Decision frame — which lever to pull when

| Technique | Build time cost | Runtime impact | When to invest |
|---|---|---|---|
| `-O3` (baseline) | (free) | required floor | always |
| Thin LTO | +10-20% link time | 5-15% throughput, smaller binary | always for release builds |
| Full LTO | +2-5× link time | marginally better than thin | only with measured gap |
| PGO instrumented build | +1× build | (intermediate, throw away) | preparation step |
| PGO workload collection | +60-300s | (data collection) | once per release-candidate |
| PGO optimized build | +1× build | another 5-25% on CPU-bound | when CPU-bound and traffic mix is stable |
| `constexpr` of hot lookup | (build slows by ms) | removes a runtime computation entirely | always where applicable |
| `consteval` for input validation | (build slows by ms) | guarantees no runtime overhead | when validators have constant inputs |

The rough hierarchy: **always enable thin LTO**, **adopt
`constexpr` aggressively where inputs are static**, **invest
in PGO when the service is CPU-bound and traffic patterns are
stable enough to record a useful profile**. Full LTO is the
last knob to turn and rarely worth it.

## Production diagnostic — did the optimizations actually fire?

A binary built by someone else (or by yesterday-you) — how do
you tell what optimizations are in it?

```bash
# 1. did LTO run? linker section names give it away
readelf -S /usr/local/bin/myservice | grep -E '\.gnu\.lto|\.llvm\.lto'
# Empty output → LTO did NOT run. Output → LTO ran.

# 2. did PGO run? look for the profile-feedback section
readelf -p .note.gnu.build-id /usr/local/bin/myservice
objdump -h /usr/local/bin/myservice | grep -E 'gcov|llvm_prf'

# 3. what -march did the compiler pick? CPU-feature usage tells you
objdump -d /usr/local/bin/myservice | \
    grep -oE 'vpaddq|vbroadcastss|vmovdqa64|vpternlogq' | \
    sort | uniq -c
# vmovdqa64 / vpternlogq → AVX-512 (build host had it)
# vpaddq / vbroadcastss → AVX-2 (Haswell+)
# (none of those) → SSE-only, portable everywhere x86-64

# 4. inspect the labels you wrote at build time (see §4)
podman inspect myservice:1.4.2 | jq '.[0].Config.Labels'
# expects: ai.cpp-tutorial.lto, ai.cpp-tutorial.pgo, ai.cpp-tutorial.march
```

The fourth check is the most reliable one if you remembered to
write the labels in [§4's pattern](../04-image-strategy/). The
binary-inspection commands tell you what *actually* happened
even if the labels lie.

## Why this is a C++ concern

C++ is one of the few languages where build-time decisions move
runtime performance by more than a constant factor. A Python
program built with `-O3` runs at the same speed as one built
without. A JVM program's hot loops are JIT-compiled at runtime
regardless of how the `.class` files were produced. A Go binary
already has cross-package inlining as a default.

C++ has neither a JIT nor cross-TU inlining as a default. The
gap between "ship the `-O3` build" and "ship the
LTO + PGO + tuned `-march` build" can be a factor of two on the
right workload. That gap is unique to ahead-of-time-compiled
systems languages, and C++ is where it shows up most often.

The build-time toolchain decisions also feed every other
section forward:

- The `-march` choice surfaces as the [AVX-512 SIGILL
  pitfall in §14](../14-pitfalls/) when build host and runtime
  host disagree.
- The `constexpr` choice interacts with [data-structure layout
  in §6](../06-stl-layout/) — a compile-time-built lookup table
  has different cache properties than a runtime-built one.
- The PGO workload-collection step is itself an
  [observability-and-load-test workflow](../10-observability-profiling/)
  — you need a load generator that matches production.

## Demo

[`examples/demo-01-image-strategy/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/demo-01-image-strategy)
also exercises this section. The `./demo-pgo.sh` script:

1. Builds an `ubi-multistage` baseline (no LTO, no PGO) — **114 MB**.
2. Builds a `pgo-instrumented` variant — **124 MB**, ~10% slower
   under load.
3. Runs `hey` against the instrumented binary for 60 seconds.
4. Merges `.profraw` files with `llvm-profdata`.
5. Builds the `pgo` final variant — **114 MB**, the recorded
   workload's optimized layout.
6. Runs `hey` against the baseline and `pgo` binaries side by
   side and prints the throughput delta.

The variant images survive (`podman images | grep cpp-tut/demo-01`)
so you can inspect each with the production-diagnostic recipe above.

## For deeper coverage

- Andrist & Sehr, *C++ High Performance*, ch. 3 (compiler
  optimizations) and ch. 9 (`constexpr` patterns)
- Iglberger, *C++ Software Design*, ch. 6 (the cost model behind
  `constexpr`-heavy designs)
- LLVM, ["Source-Based Code
  Coverage"](https://clang.llvm.org/docs/SourceBasedCodeCoverage.html)
  (related instrumentation pipeline; same `.profraw` →
  `llvm-profdata` shape as PGO)
- GCC, ["Optimize
  Options"](https://gcc.gnu.org/onlinedocs/gcc/Optimize-Options.html)
  (the canonical reference for `-flto` and `-fprofile-*` flags)

## What's next

[§6 turns to the data structures the optimized binary operates
on](../06-stl-layout/): once the compiler is doing its best,
the next big runtime lever is whether your data is laid out so
the CPU's cache hierarchy can help. Flat vs node, AoS vs SoA,
and where `std::pmr` actually moves the number — that's the
next section.
