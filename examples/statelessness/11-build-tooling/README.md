# statelessness/11-build-tooling — vendored helpers, made runnable

Compendium reference:
[Doc 11 — Build tooling appendix](../../../reference/statelessness/11-build-tooling/)

Doc 11 is a build-tooling *reference*: Conan profiles, the library/version
inventory, the C++23 toolchain matrix, the multi-stage Containerfile
pattern, and full source for three small **vendored helpers** that earlier
docs referenced but never shipped runnable. This example takes the two
self-contained helpers — `cgroup_helper` (Doc 05's cgroup limit reader) and
`psi_reader` (Doc 05's PSI parser) — and makes them real: built as static
libraries, unit-tested with GoogleTest, and exercised by a binary you run
under different cgroup caps to watch the readings track them.

(The third helper, `otel_propagator`, needs opentelemetry-cpp, which this
tutorial deliberately doesn't pull in — see the note below. The reference
material from Doc 11 lives on the compendium page; this example is the
runnable slice of it.)

## What it demonstrates

**The cgroup CPU/memory reader** ([`vendor/cgroup_helper/`](vendor/cgroup_helper/)).
`cpu_limit_cores()` reads cgroup v2 `cpu.max` (falling back to v1, then to
scheduler affinity); `memory_limit_bytes()` reads `memory.max`. This is the
helper Doc 05 uses to size thread pools against the container's budget
instead of `hardware_concurrency()` — which, under a `--cpus` cap, lies.

**The PSI parser** ([`vendor/psi_reader/`](vendor/psi_reader/)). Parses the
`some`/`full` pressure lines from `/proc/pressure/*` (or a cgroup's
`*.pressure`). Best-effort at runtime — PSI requires `CONFIG_PSI=y` and the
files to be exposed to the container.

**Testable parsers + live readers.** Each helper splits the *parsing* from
the *file I/O*: `parse_cpu_max`, `parse_mem_max`, `parse_line` are pure
functions tested deterministically against fixture strings
([`tests/test_helpers.cpp`](tests/test_helpers.cpp)), while the live
readers wrap them around the real `/sys/fs/cgroup` and `/proc/pressure`
files. So the gtest suite needs no live cgroup, and the demo binary proves
the live path under real caps.

**The cap sweep.** `./demo.sh` runs the same image under no caps,
`--cpus=1.5`, and `--cpus=0.5 --memory=256m`, and you watch
`cpu_limit_cores()` report `1.5`, then `0.5`, while `hardware_concurrency()`
keeps reporting the full host count — the exact gap a container-aware
service must close.

## Build / test wiring (the Doc 11 angle)

This is also a small worked example of the build setup Doc 11 documents:
the helpers are Conan-free static libraries; GoogleTest comes via Conan as a
test-only dependency ([`conanfile.py`](conanfile.py)); the
[`Containerfile`](Containerfile) is multi-stage (gcc-toolset-14 builder,
`ubi-minimal` runtime) and **runs the gtest suite as a build gate** — a
failing parser test fails the image build. The full Conan profile / library
inventory / toolchain matrix from Doc 11 is reference prose on the
compendium page.

## Run it

```bash
podman compose -f compose.yml build   # build + run the gtest gate
./demo.sh                              # tests + the cap sweep
./demo.sh --clean                      # remove the image
```

The first build compiles GoogleTest (~30s); the helpers and demo are tiny.

> **A note on `in_container()`.** Under rootless podman you'll likely see
> `in_container() : false` *even inside the container* — its
> `/proc/1/cgroup` reads `0::/` with none of the docker/libpod/`.scope`
> markers the heuristic sniffs for. That's a known limitation of
> cgroup-path detection under rootless user namespaces, not a bug here. It
> does **not** affect the limit readers: `cpu_limit_cores()` and
> `memory_limit_bytes()` read `cpu.max` / `memory.max` directly and track
> the caps exactly (as the sweep shows). Treat `in_container()` as a
> best-effort hint, not an authority.

## Files

| Path | Role |
|---|---|
| [`vendor/cgroup_helper/`](vendor/cgroup_helper/) | cgroup v2/v1 cpu + memory limit reader (Doc 05) |
| [`vendor/psi_reader/`](vendor/psi_reader/) | PSI `some`/`full` parser (Doc 05) |
| [`src/main.cpp`](src/main.cpp) | prints the live readings |
| [`tests/test_helpers.cpp`](tests/test_helpers.cpp) | gtest over the pure parsers |
| [`CMakeLists.txt`](CMakeLists.txt) | two static libs + demo + test suite |
| [`conanfile.py`](conanfile.py) | GoogleTest (test-only) |
| [`Containerfile`](Containerfile) | builder runs the test gate; `ubi-minimal` runtime |
| [`compose.yml`](compose.yml) | build + default unconstrained run |
| [`demo.sh`](demo.sh) | tests + the cgroup-cap sweep |
