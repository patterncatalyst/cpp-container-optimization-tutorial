# Demo 6 — Quality pipeline: static analysis, tests, ABI, debugging

Tutorial sections: §11 (Static analysis and debugging), §12 (Reproducibility and ABI)

## What this demo shows

A complete pre-merge quality pipeline for a small C++ library and its
service, all running inside containers:

1. **Static analysis** — `cppcheck` and `clang-tidy` runs over the source,
   each producing a parseable report. Warnings fail the build with a
   non-zero exit so CI can gate on them.
2. **Unit tests** — googletest + googlemock. The library has a deliberate
   abstraction-cost example (a `Channel` interface vs a templated CRTP
   form) and a benchmark unit-test that prints both timings.
3. **ABI compatibility** — `libabigail`'s `abidiff` compares the current
   build's library against a stored "v1.0" reference symbol set. A
   meaningful change to a public header (e.g. adding a member to a struct
   that's part of the ABI) makes `abidiff` fail loudly with the diff.
4. **Hermetic build** — Conan 2 lockfile + CMake presets for full
   reproducibility. The lockfile is checked in; `conan install` consumes
   it rather than re-resolving.
5. **gdbserver sidecar** — a separate Containerfile target that ships a
   debug build with `gdbserver` listening, plus `compose.debug.yml` to
   bring it up next to the main service. Connect from the host with
   `gdb -ex 'target remote 127.0.0.1:1234'`.

## Run it

```bash
./demo.sh                 # full pipeline
./demo.sh --analyze-only  # only run cppcheck + clang-tidy
./demo.sh --test-only     # only build and run gtest
./demo.sh --abi-only      # only run abidiff against the reference
./demo.sh --debug         # also bring up the gdbserver sidecar
./demo.sh --clean
```

## Output

Each phase prints a clear pass/fail line. Reports are written under
`reports/` (cppcheck XML, clang-tidy txt, gtest XML, abidiff txt) so a CI
job can pick them up. The final stdout summary is the same shape as the
section §11 slide so the audience sees the link.

## Caveats

- `abidiff` requires DWARF info; the library is built with `-g` for the
  abi-only step, then re-built without for the runtime image.
- `clang-tidy` needs `compile_commands.json`; CMake generates it via
  `CMAKE_EXPORT_COMPILE_COMMANDS=ON` in our preset.
- `gdbserver` over rootless networking works fine, but the kernel must
  allow ptrace on the target (Fedora's default `kernel.yama.ptrace_scope=0`
  is fine; some hardened distros set it higher).
