---
title: "Static Analysis & Debugging in Containers"
order: 12
description: A static-analysis pipeline that catches bugs at build time, runtime sanitizers (ASan, UBSan, MSan, TSan) in containers, Valgrind for what sanitizers can't catch, Meta's Object Introspection for memory mysteries, and the ephemeral gdb sidecar pattern for the bugs that escape anyway.
duration: 15 minutes
---

## Learning objectives

By the end of this section you can:

- Run cppcheck and clang-tidy as part of a CI build inside a
  container, with a curated check set that signals without
  drowning developers in low-signal warnings.
- Write GoogleTest / gmock unit tests that build inside the
  same builder image, in a stage that's discarded for the
  runtime image (no test-side toolchain leak).
- Build a debug variant of your service with AddressSanitizer
  (and friends) baked in, and run it under load in a container
  to catch leaks and use-after-frees that ordinary tests miss.
- Use Valgrind selectively (~10-50× slowdown) for the problems
  sanitizers can't catch — complex custom allocators, cache-miss
  hot spots, call-graph profiling.
- Use Meta's Object Introspection to answer "what does this
  data structure actually cost in RAM" for a running service.
- Attach `gdb` to a running C++ service in a Podman container
  using the ephemeral-sidecar pattern (no `gdb` in the runtime
  image; the sidecar joins the same PID namespace).
- Use `gdbserver` for the same purpose when joining the PID
  namespace isn't possible (different host, security policy,
  rootless-namespace edge cases).
- Produce useful core dumps from a containerized service.

## Diagram

{% include excalidraw.html name="12-debug-sidecar-pattern" caption="Ephemeral gdb sidecar attaching to a running container's PID namespace; the ASan-instrumented variant runs alongside as a separate container" %}

## Why analysis-and-debugging is one section

Three responses to the same underlying problem of "C++ code can
do anything at runtime, and I'd like to find out what before
it does it in production":

| Response | Where it lives | Catches what |
|---|---|---|
| **Static analysis** | build pipeline | bugs visible in the source code without running it |
| **Sanitizers + tests** | CI test runs | bugs that only show up when code actually executes with realistic inputs |
| **Debugger + introspection** | the 3am incident | bugs that survived everything above |

The first two are *prevention*; the third is *diagnosis*. A
healthy C++ service invests in all three. **This section
walks through the toolchain for each, with the container
context that changes how they're invoked.**

## Static analysis — cppcheck + clang-tidy

Two tools, complementary:

- **cppcheck** finds "obvious" bugs — uninitialized reads,
  array bounds, shadowed variables, leaks in straight-line
  code. Fast (~2-5 seconds per 100 KLOC). Reasonable
  false-positive rate (~5% with default checks).
- **clang-tidy** is the C++ linter for modernization,
  stylistic conventions, and a much wider set of checks.
  Slower (~30 seconds per 100 KLOC on a single core,
  parallelizable). Higher false-positive rate by default
  — the curated check set is what keeps it useful.

A `.clang-tidy` file in the project root pins which checks
fire. The pattern that holds up at scale:

```yaml
# .clang-tidy
---
Checks: >
  bugprone-*,
  clang-analyzer-*,
  cppcoreguidelines-*,
  modernize-use-nullptr,
  modernize-use-override,
  modernize-use-auto,
  modernize-use-emplace,
  performance-*,
  readability-identifier-naming,
  readability-redundant-*,
  -bugprone-easily-swappable-parameters,
  -cppcoreguidelines-pro-bounds-array-to-pointer-decay,
  -cppcoreguidelines-pro-type-vararg
WarningsAsErrors: 'bugprone-*,clang-analyzer-*,performance-*'
```

The principle: **enable broad check categories, then
selectively disable individual checks that produce noise** —
not the other way around. The negation lines turn off the
specific checks that are common false positives in C++
codebases without disabling the whole category.

Both tools fit cleanly as a build stage inside a multi-stage
Containerfile:

```dockerfile
FROM ubi9:latest AS analysis
COPY --from=build /src /src
WORKDIR /src
RUN dnf install -y cppcheck clang-tools-extra
RUN cppcheck --enable=all --error-exitcode=1 --suppressions-list=cppcheck.suppress src/
RUN clang-tidy -p build/compile_commands.json --warnings-as-errors='*' src/*.cpp
```

The build fails if either tool reports a warning marked as
error. Demo-07's `Containerfile` runs this exact pattern, and
its `./demo.sh` deliberately ships one finding each tool catches
so you can see the failure mode.

## Tests — GoogleTest + gmock

The C++ test framework most C++ projects converge to.
GoogleTest for unit tests, gmock for mocking, both consumed
via Conan (`gtest/1.14.0` on Conan Center).

The build-target shape that doesn't leak the test binary into
the runtime image:

```cmake
# CMakeLists.txt
add_executable(myservice src/main.cpp)
target_link_libraries(myservice PRIVATE mylib)

if (BUILD_TESTING)
    enable_testing()
    add_executable(mylib_tests test/mylib_test.cpp)
    target_link_libraries(mylib_tests PRIVATE
        mylib
        GTest::gtest_main
        GTest::gmock)
    gtest_discover_tests(mylib_tests)
endif()
```

The Containerfile builds the test target in the *build* stage,
runs it, but doesn't `COPY --from=build` the test binary into
the runtime image:

```dockerfile
FROM ubi9:latest AS build
# (toolchain + dependencies as before)
COPY . /src
WORKDIR /src
RUN cmake -B build -DBUILD_TESTING=ON --preset conan-release && \
    cmake --build build && \
    ctest --test-dir build --output-on-failure

FROM ubi9-micro:latest
COPY --from=build /usr/local/bin/myservice /
ENTRYPOINT ["/myservice"]
```

If `ctest` returns nonzero, the build fails. The test binary
never reaches the runtime image. Test discovery is automatic
via `gtest_discover_tests` — adding a `TEST(MyFixture, ...)`
makes it run on the next CMake configure.

[§13 covers the coverage measurement workflow](13-reproducibility-abi.md)
that pairs with GoogleTest — gcov/lcov for GCC builds and
clang source-based coverage for LLVM builds.

## Understanding the `reports/` directory

After a successful `./demo.sh` run, the demo's `reports/` directory
holds the evidence each phase produced. The file extensions don't
always tell you which schema they're in. Here's the legend:

| File | Schema | Producer | Notes |
|---|---|---|---|
| `gtest.xml` | JUnit XML | `ctest --output-junit` (release-debuginfo run) | One `<testcase>` per CTest test |
| `asan.xml` | JUnit XML | `ctest --output-junit` (ASan+UBSan run) | Same schema as gtest.xml, but the underlying tests ran instrumented |
| `asan.txt` | plain text | `tee` of the ASan ctest stdout | Human-readable; includes any ASan/UBSan stack traces if a sanitizer fires |
| `cppcheck.xml` | cppcheck XML | `cppcheck --xml --xml-version=2` | Different schema — `<results>` → `<errors>` → `<error>` |
| `clang-tidy.txt` | plain text | `run-clang-tidy` | One human-readable section per check that fired (empty when clean) |
| `current.abi` | libabigail XML | `abidw` | Symbolic representation of every public ABI surface for `libdemo07_channel.so.1` |
| `abidiff.txt` | plain text | `abidiff` | The semantic diff between `current.abi` and `abi-reference/`; empty file means no ABI changes |
| `coverage-gcc.xml` | JUnit XML | `ctest --output-junit` (coverage-instrumented run) | Test results from the coverage build (different binary than `gtest.xml`'s — instrumented with `--coverage`) |
| `coverage.json` | gcovr JSON | `gcovr --json` | Machine-readable coverage data; per-file line and branch hit counts |
| `coverage-cobertura.xml` | Cobertura XML | `gcovr --cobertura` | Industry-standard coverage format (originally from Java's Cobertura); Jenkins/GitLab/Azure DevOps ingest this natively into coverage dashboards |
| `coverage-summary.txt` | plain text | `gcovr --txt` | Per-file table with line and branch coverage percentages |
| `coverage-gcc/index.html` | HTML | `gcovr --html-details` | Source-browseable HTML — click into files to see per-line hit counts colored green (hit) / red (miss) |

The two files worth a longer note: `gtest.xml` and `asan.xml`.

### "JUnit XML" is a schema, not a framework

The "JUnit" label is the schema's name, not a statement about which
test framework produced the file. JUnit's XML format — defined for
Apache Ant's `<junit>` task in the early 2000s — became the industry
standard for test reporting. Nearly every language's test runner can
emit it now: pytest, RSpec, mocha, ctest, googletest, JUnit (Java),
NUnit, xUnit, you name it.

The `--output-junit` flag in our Containerfile:

```dockerfile
ctest --preset release-debuginfo --output-on-failure \
      --output-junit /src/reports/gtest.xml
```

is CMake 3.21+'s built-in JUnit emitter. The output looks like:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="release-debuginfo" tests="5" failures="0" errors="0" ...>
  <testcase name="MemoryChannelTest.SendThenRecvRoundTrips"
            classname="..." time="0.00"/>
  <testcase name="MemoryChannelTest.RespectsCapacity" .../>
  ...
</testsuite>
```

Why this matters operationally: every CI system in common use —
Jenkins, GitLab CI, GitHub Actions test-reporter, CircleCI, Azure
DevOps, Bamboo, Buildkite — ingests JUnit XML natively. Drop
`gtest.xml` into a Jenkins job's "Publish JUnit results" step and you
get test-by-test charts with zero extra plumbing. The same XML you
extracted from a podman build powers the dashboard.

### Two layers of JUnit emission you could pick

There are actually two levels of granularity available, and we picked
the outer one:

| Mechanism | Granularity | When to use |
|---|---|---|
| `ctest --output-junit path.xml` (what we use) | One `<testcase>` per `add_test()` / `gtest_discover_tests()` test | Standard choice — works for any test framework CTest can run |
| `./demo07_tests --gtest_output=xml:path.xml` | One `<testcase>` per individual `TEST_F`/`TEST_P`/`TEST` in the C++ source | Use when you don't have CTest in the loop, or when you want finer reporting |

In our demo they produce similar output because `gtest_discover_tests()`
in CMakeLists.txt creates one CTest test per gtest test case (5 gtest
tests → 5 CTest tests → 5 `<testcase>` entries). If we'd used the
older `add_test(NAME tests COMMAND demo07_tests)` style, CTest would
have seen just one logical test, and we'd have had to use gtest's own
`--gtest_output=xml` to get per-test granularity.

Either path lands at JUnit XML, which is why the label still fits.

### cppcheck has its own schema

`cppcheck.xml` is **not** JUnit — cppcheck uses a custom schema:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<results version="2">
    <cppcheck version="2.9"/>
    <errors>
        <error id="useStlAlgorithm" severity="style" ...>
            <location file="src/svc/main.cpp" line="58"/>
        </error>
    </errors>
</results>
```

When teams want cppcheck findings in test dashboards, they convert it
to either JUnit (so it shows up in test panels) or to SARIF (for
GitHub-style code-scanning panels). Tools like `cppcheck-junit` (PyPI)
and `cppcheck-codequality` (GitLab) do the conversion. Our demo keeps
the raw cppcheck XML because the demo's job is to show what each tool
natively produces; CI integration is the next layer up.

### libabigail's XML is its own thing too

`current.abi` is a libabigail-specific XML format describing every
exported symbol, type, function signature, and inheritance relationship
in the .so. It's not meant to be human-friendly (the file from our
demo is ~98 KB for a tiny library), but it diffs reliably. abidiff
compares two .abi files semantically — it knows that re-ordering
struct fields is meaningful but re-ordering function definitions in
the source isn't.

### Reading coverage output: numbers ≠ quality

When the demo's coverage stage finishes, you'll see something like:

```
File                                       Lines     Exec  Cover   Missing
src/include/demo07/channel.hpp                 7        6    85%   34
src/lib/channel.cpp                           23       21    91%   48,51
src/svc/main.cpp                              31        0     0%   31,41,44-45,...
TOTAL                                         61       27    44%
```

That 44% total looks bad, but it's misleading without context. Three
things to internalize before reading any coverage report:

**1. Coverage % depends entirely on what you measure.** The demo's
gcovr invocation includes everything under `src/` — both the library
(`channel.hpp` + `channel.cpp`) and the service entrypoint
(`svc/main.cpp`). The unit tests exercise the **library**; nothing
runs `main.cpp` during `ctest`. So `main.cpp` shows 0%, which drags
the project-level number from "great" (90%+ on the library) to
"mediocre" (44% overall).

In a real project you'd usually want two coverage reports:

- **Library coverage** — `--filter src/include/` `--filter src/lib/`
  to focus on the testable units. This is the number that goes on
  the team dashboard.
- **Full-tree coverage** — what we ship in the demo. Useful for
  spotting "I forgot to test this entire subdirectory" but bad as a
  KPI.

Choose your filter based on what question the number is trying to
answer: "is the library well-tested?" or "what fraction of all source
lines was exercised?"

**2. Branch coverage is almost always much lower than line coverage.**
The demo reports `branches: 5.3% (2/38)` which sounds catastrophic —
until you realize where those branches come from. gcc emits branch
information for:

- Every C++ exception edge (`try`/`catch`, RAII destruction order)
- Every `std::optional<T>::value()` unwrap
- Every `std::span` bounds check the compiler can't eliminate
- Every inlined std::ranges iterator advance check
- Every `if constexpr` inlined-stdlib path that didn't get
  instantiated in the test build

Most of those branches are exception-handling paths that
unit tests don't typically exercise (you don't usually test "what
happens if the heap is exhausted at this point"). Branch coverage
is a useful **diagnostic** ("are my error paths tested?") but a poor
**KPI**.

If your team genuinely wants meaningful branch coverage numbers,
filter for branches in your own code only — `gcovr` has
`--exclude-throw-branches` and `--exclude-unreachable-branches` for
exactly this purpose. We don't enable them in the demo because seeing
the raw numbers first makes the lesson land.

**3. Per-file trends matter more than project-level absolutes.** A
project moving from 70% → 73% on the library files this sprint is a
better signal than the absolute number. Track the diff, not the
threshold.

If you need a gate (CI fails when coverage drops), gate **per-file**
not per-project: `gcovr --fail-under-line=80` against the library-
only filter. A new feature that ships at 0% coverage is a quality
issue regardless of what the project-level number says.

The take-away for the reports/ directory as a whole: **every file is
designed to be machine-consumable by something**. The XML ones plug
into CI. The .abi file plugs into abidiff. The .txt files are the
human fallback. None of them is the "primary" output — they're
parallel evidence streams that different audiences (CI, developer,
ABI tooling) consume independently.

## Runtime sanitizers in containers

The four to know:

| Sanitizer | Catches | Slowdown | When to use |
|---|---|---|---|
| **ASan** | OOB reads/writes, use-after-free, use-after-return, leaks | 2-3× | Always-on for CI test runs |
| **UBSan** | Signed overflow, alignment, null-deref, type confusion, etc. | <1.5× | Pair with ASan — effectively free |
| **MSan** | Use of uninitialized memory | 3× | Hard to use (needs full instrumented stdlib); reach when ASan/UBSan aren't enough |
| **TSan** | Data races on shared memory | 5-15× | Pre-merge for any concurrent code |

ASan + UBSan can be enabled together with no extra cost.
TSan is *mutually exclusive* with ASan — the instrumentation
patterns conflict; pick one or the other for any given build.
MSan needs an instrumented C++ standard library, which Conan
doesn't ship pre-built; it's the most painful to set up and
the one to reach for only when the symptom is "we're reading
memory we never wrote and ASan isn't seeing it."

Building an ASan + UBSan variant of a service is one CMake
preset:

```json
// CMakePresets.json — the asan preset
{
    "name": "asan",
    "inherits": "conan-debug",
    "cacheVariables": {
        "CMAKE_BUILD_TYPE": "Debug",
        "CMAKE_CXX_FLAGS": "-fsanitize=address,undefined -fno-omit-frame-pointer -g -O1",
        "CMAKE_EXE_LINKER_FLAGS": "-fsanitize=address,undefined"
    }
}
```

```bash
cmake --preset asan && cmake --build --preset asan
```

Run that variant in a separate container, point your normal
load generator at it, watch the ASan report:

```bash
podman build -t myservice:asan --target asan .
podman run --rm -it -p 8080:8080 \
    -e ASAN_OPTIONS="halt_on_error=0:detect_leaks=1:print_stacktrace=1" \
    myservice:asan

# In another terminal:
hey -z 30s -c 10 http://localhost:8080/
```

A leak materializes in `LeakSanitizer:` output at exit; an
out-of-bounds read materializes immediately with a stack
trace. The `ASAN_OPTIONS=halt_on_error=0` keeps the service
running through findings rather than crashing on the first
one — useful for collecting *all* the issues a load run
exposes, not just the first.

**Running ASan in a container is the right pattern, not bare
metal**: you get the same runtime environment as production
(same kernel namespaces, same cgroup memory limits, same
allocator, same fork-exec patterns). ASan findings are
representative of what production would hit.

A subtle gotcha: ASan's shadow memory mapping requires a
contiguous virtual address space, and some kernel hardening
features (specifically `vm.mmap_min_addr` and SELinux's
`mmap_zero` boolean) can interfere. If ASan startup fails
with `==<PID>==Shadow memory range interleaves with an
existing memory mapping`, the fix is usually one of:

```bash
# Option 1: relax the kernel config (host-side)
sudo sysctl vm.mmap_min_addr=4096

# Option 2: run with a less aggressive ASan mapping
podman run -e ASAN_OPTIONS="abort_on_error=1:disable_coredump=1" ...

# Option 3: run with --security-opt=seccomp=unconfined
# (helps when seccomp is blocking ASan's mprotect patterns)
podman run --security-opt=seccomp=unconfined ...
```

## Valgrind — when it's worth the slowdown

Valgrind catches things sanitizers can't:

- **Complex leak patterns with custom allocators** that
  confuse ASan's heap tracking. Valgrind's `memcheck` walks
  every allocation regardless of allocator hooks.
- **Cache-miss hot spots** — `cachegrind` simulates the cache
  hierarchy and shows per-line cache miss counts.
- **Call-graph profiling** — `callgrind` produces a complete
  call graph with cost-per-function-call metrics that
  `perf record` doesn't.

The cost: 10-50× slowdown depending on tool and workload.
That puts Valgrind firmly in "investigation tool" rather than
"build pipeline check" territory. Use it when you have a
specific question:

```bash
# Leak hunting against a single test invocation
podman run --rm \
    --entrypoint=/usr/bin/valgrind \
    myservice:debug \
    --tool=memcheck \
    --leak-check=full \
    --show-leak-kinds=definite,possible \
    --track-origins=yes \
    /myservice --test-mode

# Cache-miss profiling
podman run --rm \
    --entrypoint=/usr/bin/valgrind \
    myservice:debug \
    --tool=cachegrind \
    --cache-sim=yes \
    /myservice --benchmark
# Then: callgrind_annotate cachegrind.out.<PID>
```

The slowdown means you use a *much* smaller load profile than
production. For leak hunting, one test invocation is usually
faster than reproducing the leak with ASan; for cache
profiling, the simulated cost model is good enough to find
hot spots even when the absolute numbers are slow.

## Object Introspection — what does this thing actually cost in RAM

Meta's open-source [Object Introspection](https://github.com/facebookexperimental/object-introspection)
tool answers a question that's surprisingly hard otherwise:
"this running C++ process has a `std::unordered_map<std::string,
MyStruct>` somewhere in its working set — exactly how much
memory does it occupy, including all the indirected strings,
bucket overhead, and alignment slack?"

You point OI at a running PID, name the symbol you want
introspected, and OI walks the structure using DWARF debug
info and a per-type code generator to produce an exact size
breakdown:

```bash
# OI requires DWARF debug info and a code-generated probe
oi --pid $(pgrep myservice) \
   --probe RequestRouter::route_table_ \
   --output-json route-table-size.json

# Then read it back
jq '.types_by_size | sort_by(-.bytes) | .[:10]' route-table-size.json
```

The output tells you exactly how many bytes each member
field's heap allocations consume, separated from inline storage.
For deep data structures (an unordered_map of vectors of small
strings), `sizeof()` lies by orders of magnitude because the
size of indirected storage doesn't appear in the type size.
OI gives you the receipts.

OI is heavy to set up — DWARF needed on the running binary,
per-type code generation, a host setup that supports running
the probe. Worth it when:

- You've narrowed a memory mystery to a specific data
  structure.
- The structure is deep enough that `sizeof()` doesn't tell
  you anything useful (any container of strings, any
  container of containers).
- You need to compare two related runtimes (different load
  shapes, different versions).

[§7 covers the allocator-side of the same investigation](07-memory-management.md);
OI is the tool for the data-structure side.

## The debug sidecar pattern — gdb without rebuilding the image

The single most useful pattern for debugging a containerized
C++ service. The runtime image stays small (`ubi9-micro` from
[§4](04-image-strategy.md), no gdb, no debug symbols). When
diagnosis demands gdb, spawn an *ephemeral sidecar container*
that:

1. Joins the running service's PID namespace
   (`--pid=container:<service>`).
2. Has `CAP_SYS_PTRACE` to attach to processes
   (`--cap-add=SYS_PTRACE`).
3. Carries the heavy tooling — gdb, eu-stack, strace, perf,
   and the matching debug symbols.

```bash
# Step 1: production container is running normally
podman run -d --name myservice-prod myservice:1.4.2

# Step 2: spawn the debug sidecar
podman run -it --rm \
    --pid=container:myservice-prod \
    --cap-add=SYS_PTRACE \
    --volume /home/me/symbols:/symbols:ro \
    debug-tools:latest

# Inside the sidecar:
gdb -p 1 -ex "set sysroot /proc/1/root" \
       -ex "set solib-search-path /symbols"
```

The sidecar sees PID 1 (the service's PID 1) because they
share the namespace. `set sysroot /proc/1/root` tells gdb
where to find the service's libraries (`/proc/1/root` is the
service's filesystem from the sidecar's view). The
`--volume /home/me/symbols:/symbols:ro` mounts a host
directory containing the unstripped debug symbols, which the
small runtime image deliberately left out.

When the sidecar exits, the production container is untouched.
No `gdb` binary leaked into the runtime image; no process state
changes that survive past the debug session.

Demo-07's `compose.debug.yml` ships a working version of this
pattern. The same pattern surfaces in [§4's image-strategy
production diagnostic](04-image-strategy.md) (running `ldd`
from a sidecar against a stripped runtime image) and [§14's
profiling-perf-in-containers discussion](14-pitfalls.md) (the
symbol-resolution trap).

## `gdbserver` — the alternative when sidecar isn't enough

When the PID-namespace approach hits a wall — different host,
security policy that disallows the share, rootless setups
where namespace-joining fails — `gdbserver` is the alternative.

The production container exposes `gdbserver` on a port (only
when debug mode is requested); the developer's gdb connects
remotely:

```bash
# In the production container — only spawn gdbserver when needed
gdbserver --attach :2159 $(pidof myservice)

# Locally
gdb /usr/local/bin/myservice
(gdb) target remote 192.168.0.42:2159
(gdb) ...
```

The pattern's trade-offs vs. the sidecar:

| Aspect | Debug sidecar | gdbserver |
|---|---|---|
| Network exposure | none | TCP port (2159 by default) |
| Symbol resolution | filesystem access via /proc/1/root | symbols local to the developer |
| Setup | needs PID-namespace sharing | needs port reachable + auth |
| Cleanup | automatic on sidecar exit | manual; kill gdbserver |

Sidecar is the better default when you can join PID namespaces;
gdbserver is the better fallback when you can't.

## Core dumps from containers

`ulimit -c unlimited` inside the container is *not enough* on
its own. The kernel's core_pattern lives on the host, which
means the path you set has to be reachable from the
container's mount namespace.

The usual move: bind-mount a writable host directory at
`/var/cores`, configure core_pattern on the host to write
there, and document the recipe:

```bash
# On the host:
sudo mkdir -p /var/cores && sudo chmod 1777 /var/cores
echo '/var/cores/core.%e.%p.%t' | sudo tee /proc/sys/kernel/core_pattern

# In the container's compose.yml:
services:
  myservice:
    image: myservice:1.4.2
    ulimits:
      core: -1   # unlimited
    volumes:
      - /var/cores:/var/cores
```

Now a SIGSEGV in the container produces
`/var/cores/core.myservice.<PID>.<timestamp>` on the host.
The debug sidecar pattern works on that core file:

```bash
podman run --rm -it \
    --volume /var/cores:/cores:ro \
    --volume /home/me/symbols:/symbols:ro \
    debug-tools:latest \
    gdb /symbols/myservice /cores/core.myservice.12345.1700000000
```

Document this in your runbook; it's the kind of thing nobody
remembers in the middle of an incident. Demo-07's README
includes the full ulimit + core_pattern recipe.

## Production diagnostic — when to reach for which tool

When something's wrong, the right tool depends on what you
know:

```
"the code looks wrong"
    → static analysis (cppcheck, clang-tidy) — at build time

"the tests are passing but a bug is hiding"
    → ASan + UBSan + a stress test
    → MSan if uninitialized-memory is suspected
    → TSan if concurrency is suspected

"memory usage is higher than I expected"
    → Object Introspection — point at the suspect structure
    → Valgrind massif — for steady-state working set

"there's a leak ASan didn't catch"
    → Valgrind memcheck — under reduced load

"the service is stuck"
    → debug sidecar + gdb attach
    → look at thread state with 'info threads' + 'thread N bt'

"the service crashed"
    → core dump + debug sidecar + gdb
    → look at the crashing frame and the local vars

"the service is fine but slow"
    → perf record + flamegraph (see §10)
    → bpftrace runqlat (see §10)
```

[§10 covers the perf and bpftrace tools](10-observability-profiling.md)
that pair with this section's analysis pipeline; the diagnostic
ladder goes from "I have static suspicion" through "I have
runtime evidence" to "I have a specific question and need a
debugger."

## Why this is a C++ concern

Go has a race detector built into `go test -race`. Rust catches
most memory-safety bugs at compile time. Java's JVM detects
many forms of corruption automatically and the GC eliminates
most "use-after-free" patterns. **C++ has none of these as
defaults** — the language gives you the freedom that creates
the bugs in the first place.

The compensating discipline is the toolchain in this section:
static analyzers find what code review missed; sanitizers
find what tests didn't exercise; OI finds what `sizeof()`
hides; the debug sidecar finds what crashed at 3am. Each one
is optional in any given build, but a production C++ service
that ships *without* any of them is shipping with no safety
net.

The container context changes the *invocation* of each tool —
sanitized variant lives in a separate image, gdb lives in an
ephemeral sidecar, core_pattern needs a host bind-mount — but
the tools themselves are the same ones a bare-metal C++
service uses. **The discipline is portable; the recipes are
container-specific.**

## Demo

[`examples/demo-07-quality-pipeline/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/demo-07-quality-pipeline)
runs the full pipeline:

- cppcheck and clang-tidy as build stages (each ships one
  deliberate finding to demonstrate the failure mode).
- GoogleTest suite (with both passing and one deliberately
  failing case behind a feature flag).
- ASan + UBSan instrumented variant built in a separate stage.
- `compose.debug.yml` for the debug-sidecar pattern.
- The full ulimit + core_pattern setup recipe in the README.

Demo-07 is the §12-companion demo; running it walks through
every tool above against a sample C++ service that's already
been wired up with each.

## For deeper coverage

- Iglberger, *C++ Software Design*, ch. 3 — testability as a
  design property; the right shape of the seam between code
  and tests.
- Ghosh, *Building Low Latency Applications with C++*, ch. 11
  — testing and debugging a low-latency C++ service
  end-to-end; pairs sanitizers and `perf` as the right tools
  for production code paths.
- The clang-tidy [check list and rationale per
  check](https://clang.llvm.org/extra/clang-tidy/) (upstream).
- Meta's [Object Introspection
  talk](https://www.youtube.com/watch?v=6IlTs8YRne0) for the
  design rationale, and the tool's repo for getting it running.
- The [Valgrind manual](https://valgrind.org/docs/manual/manual.html)
  for cachegrind/callgrind invocation details.

## What's next

[§13 turns to the longer-lived question](13-reproducibility-abi.md):
how do you build the same binary again next month? Lockfiles,
hermetic builds with Konflux and Cachi2, coverage measurement
with gcov/lcov (GCC) and clang's source-based coverage (LLVM),
ABI labels in image metadata, and `abidiff` in CI.
