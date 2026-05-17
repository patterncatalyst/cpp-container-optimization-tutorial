---
title: "Demo 7 — Quality pipeline: static analysis, tests, sanitizers, ABI, debugging"
description: "A complete pre-merge quality pipeline for a small C++ library and its service, all running inside containers:"
order: 7
layout: example
sectionid: examples
permalink: /examples/demo-07-quality-pipeline/
demo_dir: demo-07-quality-pipeline
github_path: examples/demo-07-quality-pipeline
---

> The full source for this demo lives in [`examples/demo-07-quality-pipeline/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/demo-07-quality-pipeline) — clone the repo, `cd` in, and `./demo.sh`.


Tutorial sections: §12 (Static Analysis & Debugging in Containers),
§13 (Reproducibility & ABI).

## What this demo shows

A complete pre-merge quality pipeline for a small C++ library and its
service, all running inside containers:

1. **Static analysis** — `cppcheck` and `clang-tidy` runs over the source,
   each producing a parseable report. Warnings fail the build with a
   non-zero exit so CI can gate on them.
2. **Unit tests** — GoogleTest + gmock. The library has a deliberate
   abstraction-cost example (a `Channel` interface vs a templated CRTP
   form) and a microbenchmark unit-test that prints both timings.
3. **Sanitizers** — an ASan + UBSan instrumented variant built in a
   separate stage; runs the same test suite under sanitizer
   instrumentation. Leaks, OOB reads/writes, and undefined behavior
   surface as a non-zero exit with a stack trace.
4. **ABI compatibility** — `libabigail`'s `abidiff` compares the current
   build's library against a stored "v1.0" reference symbol set. A
   meaningful change to a public header (e.g. adding a member to a struct
   that's part of the ABI) makes `abidiff` fail loudly with the diff.
5. **Hermetic build** — Conan 2 lockfile + CMake presets for full
   reproducibility. The lockfile is checked in; `conan install` consumes
   it rather than re-resolving.
6. **gdbserver sidecar** — a separate Containerfile target that ships a
   debug build with `gdbserver` listening, plus `compose.debug.yml` to
   bring it up next to the main service. Connect from the host with
   `gdb -ex 'target remote 127.0.0.1:1234'`.

## Run it

```bash
./demo.sh                 # full pipeline (analyze + test + asan + abi)
./demo.sh --analyze-only  # only run cppcheck + clang-tidy
./demo.sh --test-only     # only build and run gtest (release)
./demo.sh --asan-only     # only build and run gtest under ASan + UBSan
./demo.sh --abi-only      # only run abidiff against the reference
./demo.sh --debug         # also bring up the gdbserver sidecar
./demo.sh --clean
```

## Output

Each phase prints a clear pass/fail line. Reports are written under
`reports/` (cppcheck XML, clang-tidy txt, gtest XML, ASan stderr, abidiff
txt) so a CI job can pick them up. The final stdout summary mirrors the
section §12 / §13 slide structure so the audience can see the link.

## Caveats

- `abidiff` requires DWARF info; the library is built with `-g` for the
  abi-only step, then re-built without for the runtime image.
- `clang-tidy` needs `compile_commands.json`; CMake generates it via
  `CMAKE_EXPORT_COMPILE_COMMANDS=ON` in our preset.
- `gdbserver` over rootless networking works fine, but the kernel must
  allow ptrace on the target (Fedora's default `kernel.yama.ptrace_scope=0`
  is fine; some hardened distros set it higher).
- ASan's shadow-memory mapping interacts with seccomp; the ASan stage
  runs with `--security-opt=seccomp=unconfined` and may also need
  `vm.mmap_min_addr=4096` on hosts where the default is higher. See
  §12's "Runtime sanitizers in containers" for the diagnosis path if
  ASan fails to start.

## Core dumps from the containerized service

When the service crashes, you want a core file. `ulimit -c unlimited`
inside the container is *not enough* on its own — the kernel's
`core_pattern` lives on the host, so the path you set has to be
reachable from the container's mount namespace.

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

After a crash, `/var/cores/core.demo07-svc.<PID>.<timestamp>` appears on
the host. Open it with the debug sidecar pattern:

```bash
podman run --rm -it \
    --volume /var/cores:/cores:ro \
    --volume "$(pwd)/build/release-debuginfo":/symbols:ro \
    --entrypoint=gdb \
    cpp-tut/demo-07:gdbserver \
    /symbols/demo07-svc /cores/core.demo07-svc.<PID>.<timestamp>
```

The debug sidecar has gdb; the production `svc` image (built on
`ubi-minimal`) does not. This is the [§12 debug-sidecar
pattern](../../_docs/12-analysis-debugging.md) in miniature.

## Where the lesson lives in the tutorial

- §12 — every tool above is one of the analysis-and-debugging
  responses §12 walks through (static analysis = build-time
  prevention, sanitizers = CI-time prevention, debugger + core
  dumps = incident-time diagnosis).
- §13 — the Conan lockfile, CMakePresets, and `abidiff` invocation
  here are the minimum-viable version of the §13 "Reproducibility
  & ABI" toolkit. The §13 prose covers Konflux + Cachi2 for
  full hermetic CI, gcov/lcov + clang source-based coverage, and
  the abidiff CI integration — those further integrations are
  documented in §13 but not exercised in this demo's scripts.
