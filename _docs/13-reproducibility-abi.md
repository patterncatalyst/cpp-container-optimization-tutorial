---
title: "Reproducibility & ABI: Conan, CMake Presets, Hermetic Builds, Coverage"
order: 13
description: Conan lockfiles + CMake presets + ABI labels + abidiff give you binary-identical builds across time and machines; Konflux and Cachi2 give you those builds without network access at build time; gcov/lcov and clang source-based coverage give you the test-quality signal that hermetic builds preserve across regenerations.
duration: 15 minutes
---

## Learning objectives

By the end of this section you can:

- Create a Conan 2.x lockfile pinning every transitive
  dependency (name, version, **and recipe revision**) and
  explain what's pinned vs. what isn't (compiler, OS, build
  environment).
- Write a `CMakePresets.json` with the four configurations
  this kind of project actually uses (debug, release-LTO,
  release-PGO, release-PGO-instrumented).
- Build the same binary in two different containers and
  produce identical SHA-256 digests — what "hermetic"
  actually requires and where it usually leaks.
- Describe what Konflux and Cachi2 add to the hermetic story
  (CI without network access at build time, prefetch-then-
  build phasing) and when to invest in that setup.
- Measure test coverage with gcov/lcov for GCC builds and
  clang's source-based coverage (llvm-profdata + llvm-cov)
  for LLVM builds, and write the coverage check into CI.
- Use `abidiff` (libabigail) to detect ABI breaks between two
  builds of the same library, and add the check to CI.

## Diagram

{% include excalidraw.html name="13-reproducibility-conan-flow" caption="Hermetic build flow: Conan inputs → conan install → conan_toolchain.cmake + conan.lock → cmake/ninja → reproducible binary" %}

## What reproducibility actually means

A reproducible build produces a byte-identical artifact given
the same inputs. *Same inputs*, in practice, means:

1. **Same source tree** (a git SHA pins this).
2. **Same toolchain** (compiler version, glibc version,
   linker, archiver — pins via the build base image, see [§4](04-image-strategy.md)).
3. **Same dependency graph** (Conan lockfile pins every
   transitive package with its revision hash — see below).
4. **Same build environment** (no network reads during build,
   no clock-dependent metadata, no parallel-build
   non-determinism — see "Hermetic CI" below).
5. **Same build flags** (CMake presets pin compiler flags,
   sanitizer choice, LTO/PGO state).

Each of those leak points causes builds to drift apart. The
techniques in this section close each one in turn.

## When Conan from-source meets a minimal distro

A practical hazard worth knowing about before this section's
worked examples: if your build host is UBI 9 / RHEL 9 /
Rocky 9 / Alma 9 and you're using Conan to manage C++ deps,
autotools-based packages (libcurl, openssl, c-ares, nghttp2,
…) will fall over during their from-source build because
UBI's minimal Perl doesn't ship the modules `aclocal` and
`automake` need.

**[Appendix A — Conan, autotools, and UBI 9's minimal
Perl](appendix-a-conan-ubi9-perl.html)** has the full
perl-module shopping list and the alternatives (skip the
dep, use the system package, drop cppstd to hit pre-builts)
so you can pick the right trade-off instead of chasing
missing modules one round at a time the way demo-04 did.

## What a version pin doesn't pin

Demo-04's `conanfile.py` has this requires block:

```python
def requirements(self):
    self.requires("opentelemetry-cpp/1.14.2")
    self.requires("grpc/1.54.3",       override=True)
    self.requires("protobuf/3.21.12",  override=True)
    self.requires("abseil/20230125.3", override=True)
```

Four explicit version pins. As reproducibility statements go,
this looks airtight. It isn't.

A Conan package is addressed by **three** identifiers:
`name`, `version`, **and `recipe revision`**. The version is
what the recipe author publishes; the recipe revision is a
hash of the recipe contents. Recipe maintainers occasionally
update a published version's recipe — to bump a sub-dep, fix
a build-script bug, regenerate the recipe from a newer
template — and when they do, **the version stays the same
but the revision changes**. New pre-built binaries are
published for the new revision; old revision binaries may
stick around for a while or get garbage-collected.

A `[requires]` block resolves to "the latest revision of this
version, whatever that is right now." Two consequences:

1. **Different transitive constraints over time.** The recipe
   revision that made `opentelemetry-cpp/1.14.2` happily pair
   with `protobuf/3.21.12` last month may today require
   `protobuf/5.27.0` instead. Same version pin, different
   graph.
2. **Different package binaries over time.** Even if the
   graph stays stable, the pre-built artefacts published
   against the new revision were compiled with a different
   set of transitive deps. Your "same" pinned version is
   actually linking different object code than it did last
   month.

This is one of the gotchas demo-04 surfaced concretely; the
other is **Conan Center yanking versions entirely**, which
no pin can prevent. The `grpc/1.62.0` referenced in this
tutorial's earliest drafts was simply removed from the
remote between Feb and May 2026.

## The lockfile guarantees what versions can't

A `conan.lock` file pins (name, version, **revision**) for
every node in the resolved dep graph. Generate it once
against a working build:

```bash
./scripts/regenerate-demo-04-lockfile.sh
```

That writes `examples/demo-04-observability/conan.lock` —
JSON with every package's exact revision recorded. Commit
the file. The Containerfile picks it up:

```dockerfile
RUN if [ -s conan.lock ]; then \
        conan install . --output-folder=build/conan \
                        --lockfile=conan.lock \
                        --build=missing ; \
    else \
        conan install . --output-folder=build/conan \
                        --build=missing ; \
    fi
```

With the lockfile in place, **subsequent builds resolve the
graph against the recipe revisions you tested with**, not
against whatever's current. If a recipe is updated after you
locked, your build is unaffected.

### What the lockfile still can't fix

The lockfile pins identifiers; it can't conjure absent
packages. If Conan Center yanks a recipe entirely — which is
not hypothetical; it's how `grpc/1.62.0` disappeared while
demo-04 was being shaken down — even a lockfile that names
the exact revision will fail with `Unable to find` because
the package isn't in the remote anymore.

The durable fix is to **mirror packages to your own remote**.
JFrog Artifactory, a self-hosted Conan server, or even a
flat HTTP file server can hold copies of every package your
lockfile references. Configure that as an additional Conan
remote ahead of `conancenter`:

```bash
conan remote add mycompany-mirror https://conan.mycompany.internal/artifactory/conan-local --index=0
conan remote add conancenter https://center2.conan.io --index=1
```

The `--index=0` puts your mirror first; Conan resolves there
before falling back to upstream. With this in place, your
builds become independent of Conan Center's curation policy.

For a tutorial demo we accept the residual brittleness and
document it. For a production pipeline, treat mirroring as
part of the build infrastructure.

### When to regenerate

Run `scripts/regenerate-demo-04-lockfile.sh` when:

- You intentionally update an override version in
  `conanfile.py` (e.g., bumping opentelemetry-cpp).
- You want to refresh against current recipe revisions
  because a security fix landed in one of your transitive
  deps.
- A teammate reports a build failure on a fresh checkout
  and the diagnosis is "their resolver picked a newer
  revision than yours."

Otherwise, leave the lockfile alone. The whole point is that
it doesn't move.

## CMake presets — the four useful configurations

A `CMakePresets.json` file declares named build
configurations. The four that consistently earn their keep
for a C++ service:

```json
{
  "version": 6,
  "cmakeMinimumRequired": { "major": 3, "minor": 25, "patch": 0 },
  "configurePresets": [
    {
      "name": "conan-debug",
      "displayName": "Debug",
      "binaryDir": "build/debug",
      "toolchainFile": "build/conan/conan_toolchain.cmake",
      "cacheVariables": {
        "CMAKE_BUILD_TYPE": "Debug",
        "CMAKE_CXX_FLAGS": "-O0 -g -fno-omit-frame-pointer"
      }
    },
    {
      "name": "conan-release",
      "displayName": "Release + thin LTO",
      "inherits": "conan-debug",
      "binaryDir": "build/release",
      "cacheVariables": {
        "CMAKE_BUILD_TYPE": "Release",
        "CMAKE_INTERPROCEDURAL_OPTIMIZATION": "TRUE",
        "CMAKE_CXX_FLAGS": "-O3 -march=x86-64-v3"
      }
    },
    {
      "name": "conan-pgo-generate",
      "displayName": "PGO instrumented build",
      "inherits": "conan-release",
      "binaryDir": "build/pgo-generate",
      "cacheVariables": {
        "CMAKE_CXX_FLAGS": "-O3 -march=x86-64-v3 -fprofile-generate=$env{PWD}/profdata",
        "CMAKE_EXE_LINKER_FLAGS": "-fprofile-generate=$env{PWD}/profdata"
      }
    },
    {
      "name": "conan-pgo-use",
      "displayName": "PGO optimized build (uses pgo-generate's profile)",
      "inherits": "conan-release",
      "binaryDir": "build/pgo-use",
      "cacheVariables": {
        "CMAKE_CXX_FLAGS": "-O3 -march=x86-64-v3 -fprofile-use=$env{PWD}/myservice.profdata",
        "CMAKE_EXE_LINKER_FLAGS": "-fprofile-use=$env{PWD}/myservice.profdata"
      }
    }
  ]
}
```

Build each with `cmake --preset <name> && cmake --build
--preset <name>`. The presets inherit from each other so
shared settings live in one place (`conan-debug` carries the
toolchain file; `conan-release` adds the LTO + release flags
on top; the PGO presets inherit `conan-release` and override
just the profile flags).

A fifth preset for sanitizer builds (`conan-asan`) was shown
in [§12](12-analysis-debugging.md). Other presets you might
add: `conan-coverage` (covered below), `conan-arm64` for
cross-compiling, `conan-release-musl` for the static-ish
variant of the release build. Keep the set small enough that
developers can name them all from memory.

The `march=x86-64-v3` choice is from [§14's portable
micro-architecture discussion](14-pitfalls.md) — pinning a
portable baseline that runs on Haswell+ Intel and Zen 2+ AMD,
not the build host's `-march=native`.

## Hermetic CI — Konflux and Cachi2

Lockfiles pin the dep graph; presets pin the build flags. The
*environment* is the third leak point. A build that fetches
deps from the internet during `RUN` lines is at the mercy of
the internet — DNS hiccup, registry outage, a transient 502
from npm, all break the build. Worse, a malicious upstream
mid-build can substitute a different package than the one
you tested with.

**Hermetic CI** closes that gap: the build container has *no
network access* during the build, and every input is staged
in advance. Two Red Hat tools that implement this pattern:

**Konflux** — an open-source CI/CD platform from Red Hat that
treats every build as a Tekton pipeline with hermetic build
phases. Builds run in containers with `network_mode: none`
on the build steps; the prefetch step before each build
gathers all dependencies, verifies signatures, and stages
them locally so the build step needs nothing external. The
build artifacts include attestation metadata (signed
provenance, SBOM, the exact dependency hashes used) so
downstream consumers can verify the supply chain.

**Cachi2** — the prefetch tool that pairs with Konflux (and
works standalone). Cachi2 reads your `conan.lock` (or
`package-lock.json`, `Pipfile.lock`, `go.sum`, etc.), fetches
every referenced package over the network *before* the build,
deposits them into a local on-disk cache, and produces a
manifest. The hermetic build step then runs with that cache
mounted and the network disabled:

```bash
# Phase 1: prefetch (network allowed)
cachi2 fetch-deps --source=. --output=./cachi2-output \
    conan
# Reads conan.lock, downloads every package to ./cachi2-output/

# Phase 2: build (network disabled)
podman build --network=none \
    --volume ./cachi2-output:/cachi2:ro \
    -t myservice:hermetic .
# The Containerfile points CONAN_HOME=/cachi2 so conan install
# resolves entirely from the prefetched cache.
```

The build *cannot* drift because it physically can't reach
the upstream registries. Combined with [§4's
image-strategy](04-image-strategy.md), [§5's compile-time
labels](05-compile-time-wins.md), and a Conan lockfile, this
produces a build that's reproducible across CI runs, across
contributor machines, and across time.

**When to invest in this setup:**

- Regulated environments (FedRAMP, HIPAA, FIPS) where the
  audit trail demands "every dependency was these exact
  hashes."
- Long-tail support obligations (LTS distributions where the
  same binary needs to be rebuildable 5 years later).
- Air-gapped deployment targets where the network-during-build
  assumption was never valid.

**When it's overkill:**

- Solo / small-team projects where the dependency graph
  changes weekly and you have other supply-chain signals
  (Dependabot, OSS scorecard, internal security review).
- Demos and tutorials (this tutorial uses a Conan lockfile +
  multi-stage builds, but not full Cachi2 prefetch — the
  lockfile is the 80% that matters; Cachi2 closes the
  remaining 20%).

Konflux ships as the SaaS offering at https://console.redhat.com/application-pipeline
and as the self-hostable open-source project; Cachi2 is at
https://github.com/containerbuildsystem/cachi2.

## Testing hermeticity locally — `./demo.sh --hermetic-check`

Konflux + Cachi2 is the production answer. For local verification —
"is my build actually reproducible right now, on my laptop?" — the
simpler test is: build twice, compare bytes.

Demo-07 ships this as a flag:

```bash
./demo.sh --hermetic-check
```

The script:

1. Invokes `podman build --target svc` **twice**, each time passing a
   different value to the `HERMETIC_NONCE` build-arg
2. `podman cp`'s `demo07-svc` and `libdemo07_channel.so.1.0.0` out of
   both resulting images into `reports/hermetic/build{1,2}-*`
3. Computes SHA-256 of each artifact
4. Reports byte-identical or differing, with diagnostic hints for the
   failure case

**The `HERMETIC_NONCE` trick.** Podman's layer cache is content-addressable:
the cache key for a layer is a hash of the instruction plus the inputs.
Same inputs → cache hit. To force a re-build without changing actual
inputs, we add a no-op `ARG` + `RUN` pair that consumes the arg:

```dockerfile
FROM toolchain AS build
WORKDIR /src
ARG HERMETIC_NONCE=0
RUN echo "hermetic nonce: ${HERMETIC_NONCE}" > /tmp/.hermetic-nonce
COPY src/ ./src/
# ... rest of build
```

Different `--build-arg HERMETIC_NONCE=...` values produce different
cache keys at that line, forcing every layer downstream (the actual
`cmake --build`) to re-execute. The arg itself has zero effect on the
compiled binary — it only changes a string in `/tmp/`. The toolchain
layers (UBI, EPEL, gcc-toolset-14, libabigail) stay cached because
they're upstream of the `ARG` line.

**What "pass" looks like.**

```
==> Comparing SHA-256 hashes

  demo07-svc       size 47216 bytes
    build 1: 8a3c4d... (full hash)
    build 2: 8a3c4d... (full hash)
[ ok ]     -> BYTE-IDENTICAL

  libchannel.so    size 24648 bytes
    build 1: f2e1a9... (full hash)
    build 2: f2e1a9... (full hash)
[ ok ]     -> BYTE-IDENTICAL

[ ok ]  Hermetic build: VERIFIED
```

This isn't a partial signal — byte-identical means *byte-identical*.
Build IDs match. Debug info matches. Constant pools match. Symbol
ordering matches. The compiled binaries are interchangeable.

**Why containers make this work.** Three properties of the
containerized build do most of the work:

| Property | What it eliminates |
|---|---|
| `/src` is the constant WORKDIR | Path-dependent debug info |
| Compiler binary identity is pinned | Toolchain version drift |
| Environment is reset per build | Stray env-var leakage |

Outside containers, you'd typically need `-ffile-prefix-map=/path/to/src=.`
and `SOURCE_DATE_EPOCH=...` exported to get this same property. Inside
a container with constant `/src`, those flags become redundant.

**When it fails.** Section "Production diagnostic — when a build isn't
reproducible" below covers the ladder. The flag's failure output
points there directly. The five suspects in decreasing frequency are:
`__DATE__`/`__TIME__` macros, embedded paths in debug info, PRNG seeds
in codegen, non-deterministic build-id, and parallel-build races.

**This complements Konflux, not replaces it.** Konflux + Cachi2
guarantees hermeticity by *closing off* sources of non-determinism
(no network, no environment leakage). `--hermetic-check` *verifies*
hermeticity by independent rebuild + comparison. You want both: the
first prevents drift, the second catches it when prevention fails.

## Tests as a build-stage quality gate — GoogleTest in hermetic CI

GoogleTest was introduced in [§12](12-analysis-debugging.md);
the relevant Konflux/hermetic-build wrinkle is that the test
run is a build-stage gate — the build fails if `ctest`
returns nonzero, and the failing test output is in the build
logs the same way a compile error would be.

```dockerfile
FROM ubi9:latest AS build
# (toolchain, prefetched deps)
COPY --from=cachi2 /cachi2 /cachi2
ENV CONAN_HOME=/cachi2
COPY . /src
WORKDIR /src
RUN conan install . --lockfile=conan.lock && \
    cmake --preset conan-release -DBUILD_TESTING=ON && \
    cmake --build --preset conan-release && \
    ctest --test-dir build/release --output-on-failure
```

In Konflux's hermetic phase, that whole build (including
`ctest`) runs in a container with `--network=none`. If the
test suite needs network access for, say, an integration
test against an external service, the test fails — which is
the correct behavior. Integration tests against external
services have to either (a) provision their own dependency
as a build-stage sidecar that the hermetic container can
reach internally, or (b) run as a *post-build* stage outside
the hermetic boundary.

GoogleBenchmark for performance regression testing fits the
same pattern: a separate `bench` target, run as a build
stage, comparing against a baseline; the build fails if
performance regresses past a threshold. This is the same
pattern demo-02 uses for the flat_map / unordered_map
comparison from [§6](06-stl-layout.md), but turned into a
gate.

## Coverage — gcov/lcov for GCC builds

Test coverage measurement on GCC works via the `--coverage`
compile flag, which inserts instrumentation that emits
`.gcno` files at compile time and `.gcda` files at run time:

```bash
# Compile with coverage instrumentation
cmake --preset conan-debug -DCMAKE_CXX_FLAGS="--coverage -O0 -g"
cmake --build --preset conan-debug

# Run the tests — .gcda files appear next to the .gcno files
ctest --test-dir build/debug

# Generate human-readable coverage
gcov src/*.cpp -o build/debug/

# Or LCOV for HTML reports
lcov --capture --directory build/debug --output-file coverage.info
lcov --remove coverage.info '/usr/*' '*/test/*' --output-file coverage-filtered.info
genhtml coverage-filtered.info --output-directory coverage-html/

# Or generate Cobertura XML for CI consumption
lcov --extract coverage.info '*/src/*' --output-file coverage-src-only.info
lcov_cobertura coverage-src-only.info --output coverage.xml
```

The CMake preset for coverage:

```json
{
  "name": "conan-coverage",
  "inherits": "conan-debug",
  "binaryDir": "build/coverage",
  "cacheVariables": {
    "CMAKE_CXX_FLAGS": "--coverage -O0 -g",
    "CMAKE_EXE_LINKER_FLAGS": "--coverage"
  }
}
```

Pros of gcov/lcov:

- Universal — GCC has shipped this since ~2003; it's the
  baseline.
- Tooling ecosystem — every CI integration (Codecov,
  Coveralls, SonarQube) reads lcov or gcov output.
- Simple — one flag to compile, one tool to summarize.

Cons:

- **Inaccurate under optimization**. gcov instruments at the
  machine-code level after the compiler has optimized, so
  inlining, code motion, and dead-code elimination can confuse
  the line-coverage report. Lines that "should" be covered
  sometimes show 0 hits because the optimizer fused them with
  adjacent lines.
- **Slow at scale** — coverage rebuilds are noticeably slower
  than non-coverage builds, and the `.gcda` files have to be
  serialized at exit.

For most projects gcov + lcov is the sensible default. For
projects on clang/LLVM where coverage accuracy matters,
read on.

## Coverage — Clang source-based coverage (llvm-profdata + llvm-cov)

Clang's source-based coverage instruments at the AST level
*before* the compiler optimizes, so the line/branch counts
reflect what the source actually looks like rather than what
optimization produced. The full reference is at
[clang.llvm.org/docs/SourceBasedCodeCoverage.html](https://clang.llvm.org/docs/SourceBasedCodeCoverage.html).

The flow looks similar to PGO from [§5](05-compile-time-wins.md)
because it uses the same `.profraw` / `llvm-profdata`
machinery:

```bash
# Compile with source-based coverage instrumentation
clang++ -fprofile-instr-generate -fcoverage-mapping \
    -O0 -g -o myservice src/main.cpp

# Or via CMake preset
cmake --preset conan-coverage-llvm
cmake --build --preset conan-coverage-llvm

# Run the tests; LLVM_PROFILE_FILE controls the .profraw path
LLVM_PROFILE_FILE="coverage-%p-%m.profraw" \
    ctest --test-dir build/coverage-llvm

# Merge the raw profile data
llvm-profdata merge -sparse coverage-*.profraw -o myservice.profdata

# Generate text report
llvm-cov report ./build/coverage-llvm/myservice \
    -instr-profile=myservice.profdata

# Generate HTML report
llvm-cov show ./build/coverage-llvm/myservice \
    -instr-profile=myservice.profdata \
    -format=html -output-dir=coverage-html/ \
    src/

# Or export JSON for CI consumption
llvm-cov export ./build/coverage-llvm/myservice \
    -instr-profile=myservice.profdata \
    -format=lcov > coverage.lcov
```

The CMake preset:

```json
{
  "name": "conan-coverage-llvm",
  "inherits": "conan-debug",
  "binaryDir": "build/coverage-llvm",
  "cacheVariables": {
    "CMAKE_CXX_COMPILER": "clang++",
    "CMAKE_CXX_FLAGS": "-fprofile-instr-generate -fcoverage-mapping -O0 -g",
    "CMAKE_EXE_LINKER_FLAGS": "-fprofile-instr-generate"
  }
}
```

Pros of clang source-based coverage:

- **Accurate under optimization** — source-level instrumentation
  isn't fooled by inlining or code motion.
- **Branch coverage** is reliable (gcov's branch coverage is
  notoriously unreliable on optimized code).
- **`-format=lcov` export** means CI integrations that read
  lcov format work without modification.
- **Region coverage** — clang tracks coverage of sub-line
  regions (each branch of a ternary, each `case` of a switch),
  which gcov can't.

Cons:

- Requires clang as the compiler. If your release builds are
  GCC, you'd use clang only for the coverage build (which is
  fine — coverage doesn't affect what you ship).
- Tooling has a small learning curve; the LLVM docs are the
  authoritative reference.

For projects that already build with clang, source-based
coverage is the better choice. For projects that need to
work with GCC, gcov/lcov stays as the primary mechanism.

Both approaches plug into the same CI integrations and the
same code-review tooling.

## ABI labels in image metadata

Reproducibility produces a binary that's bit-identical given
the same inputs. The *next* question — "what toolchain was
this binary built with?" — is the one [§4 covered with the
`LABEL` pattern](04-image-strategy.md). The labels worth
encoding for a hermetic build:

```dockerfile
LABEL org.opencontainers.image.title="myservice"
LABEL org.opencontainers.image.version="1.4.2"
LABEL org.opencontainers.image.revision="a3f29b1"
LABEL ai.cpp-tutorial.libc="glibc-2.34-100.el9_4"
LABEL ai.cpp-tutorial.libstdcxx="libstdc++.so.6.0.32"
LABEL ai.cpp-tutorial.compiler="gcc-14.2.1-1.el9"
LABEL ai.cpp-tutorial.march="x86-64-v3"
LABEL ai.cpp-tutorial.lto="thin"
LABEL ai.cpp-tutorial.pgo="enabled"
LABEL ai.cpp-tutorial.sanitizers="none"
LABEL ai.cpp-tutorial.conan-lockfile-hash="sha256:abcd..."
LABEL ai.cpp-tutorial.build-id="$BUILD_ID"
```

At incident time `podman inspect myservice:1.4.2 | jq
'.[0].Config.Labels'` answers "what toolchain produced this
binary" in one command, without needing the build host to
still exist.

In a Konflux-style hermetic build, attestation metadata
covers the same information at the supply-chain level, but
the labels remain useful as the "embedded in the image"
version of the same answer.

## `abidiff` in CI — catching ABI breaks before merge

For C++ shared libraries (and increasingly for CLI binaries
that other services depend on), an ABI change without a
SONAME bump silently breaks downstream consumers. `abidiff`
from the libabigail project compares two builds of the same
library and reports the ABI delta:

```bash
abidiff \
    --no-show-locs \
    libfoo-old.so libfoo-new.so

# Sample output:
# Functions changes summary: 1 Removed, 2 Added functions
# Variables changes summary: 0 Removed, 0 Added variables
# 1 function with some sub-type change:
#    [C] 'function void process(Request&) at request.cpp:42'
#       parameter 1 of type 'Request&':
#         in pointed-to type 'class Request':
#           1 data member insertion:
#             'unsigned long timestamp_us', at offset 16 (in bits)
```

The CI integration:

```yaml
# CI step: compare against the previous tag's library
- name: ABI compatibility check
  run: |
    git fetch --tags
    PREV_TAG=$(git describe --tags --abbrev=0 HEAD^)
    git checkout $PREV_TAG -- libfoo
    cmake --build build-prev --target libfoo
    cp build-prev/libfoo.so libfoo-prev.so
    git checkout HEAD -- libfoo
    cmake --build build-new --target libfoo
    abidiff --no-show-locs libfoo-prev.so build-new/libfoo.so
```

Demo-07's CI pipeline includes this step, comparing the
library against the version on the previous git tag.

`abidiff`'s findings categories that matter:

- **Removed functions / removed variables** — always a break
  unless the symbol was internal.
- **Function-signature changes** — break unless backward-
  compatible (e.g., parameter type change is a break; new
  default-argument-value isn't).
- **Data-member insertions or reorderings in classes with
  inheritance** — break vtable layouts and offsets, *even
  if the inserted member is `private`*.
- **vtable changes** (new virtual function, reordered virtual
  functions) — always a break.

The libabigail project's documentation walks through each
category in more detail; the short version is "abidiff
deciding 'no ABI break' means downstream consumers don't
need to recompile, and that judgement is reliable enough to
gate merges on."

## Production diagnostic — when a build isn't reproducible

When CI produces two builds with different SHA-256 hashes from
what should be identical inputs, the common culprits in
roughly decreasing frequency:

```bash
# 1. Time-dependent metadata in the binary
# - __DATE__ / __TIME__ macros (search the source)
# - debug info with build timestamps (compile with
#   -ffile-prefix-map and -fdebug-prefix-map)
strings myservice | grep -E '[0-9]{4}-[0-9]{2}-[0-9]{2}'

# 2. Non-deterministic build ordering (parallel build races)
# - Hash the .o files, not just the final binary; if they
#   differ even though sources are identical, the parallel
#   build is the suspect
sha256sum build/**/*.o

# 3. Path-dependent debug info
# - Compile with -ffile-prefix-map=/full/path/to/src=src
# Or with --reproducible flag in newer toolchains

# 4. Random GUIDs in debug sections
readelf -n myservice | grep 'Build ID'
# Should be deterministic if all inputs are deterministic.

# 5. Time-dependent random-number-seeded code generation
# (rare but happens with some LTO settings; -fno-fat-lto-objects helps)
```

The diagnostic ladder: compare disassembly with `diff <(objdump
-d build-a/myservice) <(objdump -d build-b/myservice)` and
identify the diverging section, then trace back to the
source.

## Why this is a C++ concern

A Go program's binary is statically linked; the dependency
graph is closed inside the binary; reproducibility is
essentially built-in given a fixed go.sum. A Java program's
JAR file embeds class files that are mostly compiler-output-
stable. **C++ has multiple sources of build non-determinism
that don't apply to either**:

- **Template instantiation order** affects function ordering
  in `.text`, which affects build IDs.
- **ABI choices baked into headers** propagate transitively;
  changing one boost version can change downstream object
  files in nonobvious ways.
- **Allocator and runtime decisions** (different
  `_GLIBCXX_USE_CXX11_ABI` settings between TUs cause silent
  link-time ABI mismatches that abidiff catches and code
  review doesn't).
- **Toolchain version drift** in C++ has a longer tail than
  in other languages — a single line of code that depends on
  C++20 features fails on gcc-11 with cryptic errors but
  works fine on gcc-14.

The discipline in this section — lockfiles, presets,
hermetic builds, labels, abidiff — is heavier than equivalent
practices in other ecosystems because the C++ failure modes
are heavier. **Each technique is optional individually, but
the cumulative discipline is what makes a C++ binary that
shipped last year still rebuildable today.**

## Demo

[`examples/demo-07-quality-pipeline/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/demo-07-quality-pipeline)
includes a hermetic build path: builds the library twice in
identical builder containers and asserts the artifacts are
byte-identical, deliberately introduces an ABI break and
shows `abidiff` catching it, and runs both gcov/lcov and
clang source-based coverage as separate build presets.

[`examples/demo-04-observability/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/demo-04-observability)
demonstrates the Conan lockfile pattern at scale (gRPC +
OpenTelemetry's transitive graph is heavy enough that the
recipe-revision drift is concretely visible).

## For deeper coverage

- Iglberger, *C++ Software Design*, ch. 1 (architectural
  decisions that survive contact with reality), ch. 5 (the
  ABI cost of template choices).
- The [libabigail
  manual](https://sourceware.org/libabigail/manual/abigail-user-guide.html)
  — the authoritative reference on `abidiff` semantics.
- Clang, [Source-Based Code
  Coverage](https://clang.llvm.org/docs/SourceBasedCodeCoverage.html)
  — the canonical reference for the LLVM coverage pipeline.
- GCC, [gcov
  documentation](https://gcc.gnu.org/onlinedocs/gcc/Gcov-Intro.html)
  — the GCC-side equivalent.
- [Konflux](https://konflux-ci.dev/) — the open-source CI/CD
  platform; the documentation walks through hermetic build
  pipelines end-to-end.
- [Cachi2](https://github.com/containerbuildsystem/cachi2)
  — the prefetch tool; supports Conan, npm, pip, go modules,
  and more.
- [Conan 2.x lockfile
  reference](https://docs.conan.io/2/tutorial/versioning/lockfiles.html).

## What's next

[§14 collects the most common things that go wrong](14-pitfalls.md),
in one place, with the diagnosis for each. AVX-512 mismatches
that SIGILL on production hosts, abstraction overhead invisible
in the type system, container builds that take seven minutes
when bare-metal builds take thirty seconds, and the
EPERM/EACCES rubric that tells you which security layer is
denying you.
