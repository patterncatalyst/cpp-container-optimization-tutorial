# Demo 7 — Quality pipeline: static analysis, tests, sanitizers, ABI, debugging

Tutorial sections:
[§12 Static Analysis & Debugging in Containers](/docs/12-analysis-debugging/) +
[§13 Reproducibility & ABI](/docs/13-reproducibility-abi/)

A complete pre-merge quality pipeline for a small C++ library and
its service, all running inside containers. Static analysis, unit
tests, sanitizers, ABI checks, hermetic builds, and a gdbserver
sidecar — the six tools that, between them, catch most of what
goes wrong in production C++.

## Why this matters

Most C++ production incidents fall into a small number of
recognizable patterns: memory corruption that the tests didn't
exercise, a use-after-free under specific timing, an ABI break
shipped quietly when a header's struct member was added, or a
build that worked on someone's laptop and didn't reproduce in CI.
Each pattern has a well-understood tool that catches it — but
those tools only catch it when they're actually wired into the
pipeline.

This demo is the engineering practice that makes those tools
default rather than aspirational. The whole pipeline runs in
containers; the lockfile is checked in; the ABI reference is
checked in; the sanitizer build is one CI job and one build
flag. Each piece is small; their composition is what catches
bugs before they ship.

§12 covers the analysis and debugging toolkit; §13 covers
reproducibility and ABI. This demo wires both into one
shell script.

## What this demo shows

Six tools running in sequence in a CI-shaped pipeline:

1. **Static analysis** — `cppcheck` and `clang-tidy` runs over
   the source, each producing a parseable report. Warnings fail
   the build with a non-zero exit so CI can gate on them.
2. **Unit tests** — GoogleTest + gmock. The library has a
   deliberate abstraction-cost example (a `Channel` interface
   vs a templated CRTP form) and a microbenchmark unit-test
   that prints both timings.
3. **Sanitizers** — an ASan + UBSan instrumented variant built
   in a separate stage; runs the same test suite under sanitizer
   instrumentation. Leaks, OOB reads/writes, and undefined
   behavior surface as a non-zero exit with a stack trace.
4. **ABI compatibility** — `libabigail`'s `abidiff` compares
   the current build's library against a stored "v1.0"
   reference symbol set. A meaningful change to a public header
   (e.g. adding a member to a struct that's part of the ABI)
   makes `abidiff` fail loudly with the diff.
5. **Hermetic build** — Conan 2 lockfile + CMake presets for
   full reproducibility. The lockfile is checked in;
   `conan install` consumes it rather than re-resolving.
6. **gdbserver sidecar** — a separate Containerfile target that
   ships a debug build with `gdbserver` listening, plus
   `compose.debug.yml` to bring it up next to the main service.

## How to run

```bash
./demo.sh                 # full pipeline (analyze + test + asan + abi)
./demo.sh --analyze-only  # only run cppcheck + clang-tidy
./demo.sh --test-only     # only build and run gtest (release)
./demo.sh --asan-only     # only build and run gtest under ASan + UBSan
./demo.sh --abi-only      # only run abidiff against the reference
./demo.sh --debug         # also bring up the gdbserver sidecar
./demo.sh --clean
```

Expected runtime: ~5-7 minutes for the full pipeline on a cold
cache, ~1-2 minutes on a warm Conan cache.

## What you'll see

Each phase prints a clear pass/fail line and writes reports under
`reports/` for CI consumption (cppcheck XML, clang-tidy txt,
gtest XML, ASan stderr, abidiff txt). A representative successful
run:

```
==> cppcheck: PASS (0 warnings, 0 errors)
==> clang-tidy: PASS (0 warnings on changed files)
==> gtest release: PASS (47 tests, 1.2 s)
==> gtest ASan+UBSan: PASS (47 tests, 4.8 s, no leaks)
==> abidiff vs v1.0 reference: PASS (no ABI changes)
==> Pipeline result: PASS
```

A run with an intentional ABI break introduced (add a member to a
public struct in `include/lib/`) produces:

```
==> abidiff vs v1.0 reference: FAIL
    1 function with some indirect sub-type change:
      [C] 'function void Foo::bar()' has some indirect sub-type changes:
        parameter 1 of type 'Foo&' has sub-type changes:
          'struct Foo' changed:
            type size hasn't changed
            1 data member insertion:
              'int Foo::new_field', at offset 32 (in bits) at lib.h:14:1
```

## How to read the output

Each tool surfaces a different class of bug:

- **cppcheck flags structural issues** — uninitialized variables,
  null dereferences, scope confusion, leaks in linear control
  flow. Fast (seconds), high signal, no false positives in the
  common case.
- **clang-tidy flags style and modern-C++ issues** — missing
  `override`, non-`const` member functions that could be,
  pre-C++17 idioms, performance anti-patterns. Slower (depends
  on enabled checks), more opinionated.
- **gtest failures are correctness regressions** — straightforward
  to interpret; failing test names point at the regression.
- **ASan failures are memory-safety bugs** — heap-buffer-overflow,
  use-after-free, leaks. The stack trace usually points directly
  at the offending line. These were always there; ASan made
  them visible.
- **UBSan failures are undefined-behavior bugs** — signed integer
  overflow, null deref, alignment violations. Often subtler than
  ASan output; sometimes you have to consult the standard to
  understand what the compiler was about to optimize away.
- **abidiff failures mean a downstream rebuild is required** —
  the library's binary interface has changed in a way that breaks
  ABI compatibility. The diff tells you which struct, which
  function, which symbol changed. Either revert the change, bump
  the SONAME, or accept the rebuild burden on consumers.

## Core dumps from the containerized service

When the service crashes, you want a core file. `ulimit -c
unlimited` inside the container is *not enough* on its own — the
kernel's `core_pattern` lives on the host, so the path you set
has to be reachable from the container's mount namespace.

The recipe:

```bash
# On the host: prepare a writable core-dump directory
sudo mkdir -p /var/cores && sudo chmod 1777 /var/cores

# Point core_pattern at the host directory (lives on the host kernel)
echo '/var/cores/core.%e.%p.%t' | sudo tee /proc/sys/kernel/core_pattern

# Bring up the service with unlimited core size + the host dir bind-mounted
podman run --rm \
    --ulimit core=-1 \
    --volume /var/cores:/var/cores \
    --name demo07-svc \
    cpp-tut/demo-07:svc
```

After a crash, `/var/cores/core.demo07-svc.<PID>.<timestamp>`
appears on the host. Open it with the debug sidecar pattern:

```bash
podman run --rm -it \
    --volume /var/cores:/cores:ro \
    --volume "$(pwd)/build/release-debuginfo":/symbols:ro \
    --entrypoint=gdb \
    cpp-tut/demo-07:gdbserver \
    /symbols/demo07-svc /cores/core.demo07-svc.<PID>.<timestamp>
```

The debug sidecar has gdb; the production `svc` image (built on
`ubi-minimal`) does not. This is §12's debug-sidecar pattern in
miniature.

## Caveats and gotchas

- **`abidiff` requires DWARF info.** The library is built with
  `-g` for the abi-only step, then re-built without for the
  runtime image.
- **`clang-tidy` needs `compile_commands.json`.** CMake generates
  it via `CMAKE_EXPORT_COMPILE_COMMANDS=ON` in our preset.
- **`gdbserver` over rootless networking works**, but the kernel
  must allow ptrace on the target (Fedora's default
  `kernel.yama.ptrace_scope=0` is fine; some hardened distros
  set it higher).
- **ASan's shadow-memory mapping interacts with seccomp.** The
  ASan stage runs with `--security-opt=seccomp=unconfined` and
  may also need `vm.mmap_min_addr=4096` on hosts where the
  default is higher. See §12's "Runtime sanitizers in
  containers" for the diagnosis path if ASan fails to start.
- **The ABI reference is a snapshot.** It captures the library's
  ABI at a known-good commit. Updating the reference (when a
  legitimate SONAME bump happens) is a manual step; the demo
  doesn't try to be clever about when to do it automatically.

## Source materials

This demo deepens material from the project's
[**bibliography**](/bibliography/):

- **Iglberger, *C++ Software Design*, ch. 3-5** — the design
  principles that static analysis can detect violations of;
  loose coupling, value semantics, the ABI-stability argument
- **Ghosh, *Building Low Latency Applications with C++*, ch. 14** —
  what an "all sanitizers, all the time" CI looks like for
  latency-sensitive code; the trade-off between coverage and CI
  duration
- **libabigail manual** — the canonical reference for `abidiff`'s
  semantics and exit codes when integrating into CI gates

## Linked tutorial sections

- [**§12 Static Analysis & Debugging in Containers**](/docs/12-analysis-debugging/)
  — every tool above is one of the analysis-and-debugging
  responses §12 walks through (static analysis = build-time
  prevention, sanitizers = CI-time prevention, debugger + core
  dumps = incident-time diagnosis).
- [**§13 Reproducibility & ABI**](/docs/13-reproducibility-abi/)
  — the Conan lockfile, CMakePresets, and `abidiff` invocation
  here are the minimum-viable version of the §13 "Reproducibility
  & ABI" toolkit. The §13 prose covers Konflux + Cachi2 for full
  hermetic CI, gcov/lcov + clang source-based coverage, and the
  abidiff CI integration — those further integrations are
  documented in §13 but not exercised in this demo's scripts.
- [**§14 Pitfalls**](/docs/14-pitfalls/) — the abstraction-cost
  microbenchmark unit-test in this demo's library is §14's
  worked example: the Channel interface vs the templated CRTP
  form, with measured numbers showing the cost.
