---
title: "Static Analysis & Debugging in Containers"
order: 12
description: A static-analysis pipeline that catches bugs at build time, runtime sanitizers (ASan, UBSan, MSan) and Valgrind in containers, Object Introspection for understanding actual memory footprints, and an ephemeral gdb sidecar pattern for the bugs that escape anyway.
duration: 15 minutes
---

## Learning objectives

By the end of this section you can:

- Run cppcheck and clang-tidy as part of a CI build inside a
  container, with a curated check set that doesn't drown the
  developer in low-signal warnings.
- Write googletest / gmock unit tests that build and run inside
  the same builder image, with no test-side toolchain leak into
  the runtime image.
- Build a debug variant of your service with AddressSanitizer
  (and friends) baked in, and run it under load in a container
  to catch leaks and use-after-frees that don't show up in
  ordinary tests.
- Use Valgrind selectively (it's slow; ~10–50× slowdown is
  typical) for problems sanitizers don't catch.
- Use Meta's Object Introspection to answer "what does this data
  structure actually cost in RAM" for a running service —
  including the silent overhead of STL containers covered in §5.
- Attach `gdb` to a running C++ service in a Podman container
  using an ephemeral sidecar pattern (no `gdb` in the runtime
  image; the sidecar joins the same PID namespace).
- Use `gdbserver` for the same purpose when joining the PID
  namespace isn't possible.

## Diagram

{% include excalidraw.html name="12-debug-sidecar-pattern" caption="Ephemeral gdb sidecar attaching to a running container's PID namespace; ASan-instrumented variant alongside" %}

## Planned content

### Static analysis: cppcheck and clang-tidy

cppcheck for the "obvious" bugs (uninitialized reads, array bounds,
shadowed variables); clang-tidy for modernization and stylistic lint.
The curated check set in `.clang-tidy` (see demo 6) signals without
spamming. Both run as a build stage, both can fail the build, both
emit machine-readable reports for CI.

### Tests: googletest + gmock

The build target shape, where the tests live, and why the *test*
binary should not end up in the runtime image. Demo 6 builds tests
in a stage that's discarded for the runtime — same source tree,
different output image.

### Sanitizers in a container

The three to know:

| Sanitizer | Catches                                              | Slowdown      | When it's the right tool                |
|-----------|------------------------------------------------------|---------------|------------------------------------------|
| ASan      | OOB, use-after-free, use-after-return, leaks         | 2–3×          | Always-on for CI test runs               |
| UBSan     | Signed overflow, alignment, null-deref, etc.         | <1.5×         | Pair with ASan; effectively free         |
| MSan      | Use of uninitialized memory                          | 3×            | Hard to use in practice (needs full instrumented stdlib); reach for it when ASan/UBSan aren't enough |
| TSan      | Data races on shared memory                          | 5–15×         | Pre-merge for any concurrent code        |

Building an ASan variant of a service is one CMake build type:

```bash
cmake --preset asan
# or, in the preset file:
#   CMAKE_BUILD_TYPE=Debug
#   CMAKE_CXX_FLAGS="-fsanitize=address,undefined -fno-omit-frame-pointer -g"
#   CMAKE_EXE_LINKER_FLAGS="-fsanitize=address,undefined"
```

Run that variant in a separate container, point your normal load
generator at it, and watch for the ASan report on stderr. A
leak will materialize in `LeakSanitizer:` output at exit; an
out-of-bounds read materializes immediately with a stack trace.

The point of doing this in a container (vs. on bare metal): you
get the same runtime environment as production — same kernel
namespaces, same cgroup memory limits, same allocator, same
container-induced fork-exec patterns. ASan's findings will be
representative of what production would hit.

### Valgrind: when it's worth the slowdown

Valgrind catches things sanitizers can't: complex leak patterns
with custom allocators that confuse ASan, cache-miss hot spots
(`cachegrind`), call-graph profiling (`callgrind`). Cost is high —
10× to 50× slower depending on tool and workload — so it's not a
build-pipeline check. It's an investigation tool you reach for when
you have a specific question.

In a container: `podman run` your service under valgrind, accept
the slowdown, and use a *much* smaller load profile than you'd use
for production. For leak hunting, `valgrind --tool=memcheck
--leak-check=full --track-origins=yes` against a single test
invocation is usually faster than reproducing the leak with ASan.

### Object Introspection: what does this thing actually cost

Meta's open-source [Object Introspection](https://github.com/facebookexperimental/object-introspection)
tool answers a question that's surprisingly hard otherwise: "this
running C++ process has a `std::unordered_map<std::string,
MyStruct>` somewhere in its working set — exactly how much memory
does it occupy, including all the indirected strings and bucket
overhead?"

You point OI at a running PID, name the symbol you want
introspected, and OI walks the structure using DWARF debug info
and a per-type code generator to produce an exact size breakdown:
heap allocations, shared pages, alignment slack. It's the right
tool for diagnosing the silent-memory-overhead pitfalls covered in
§5 and §13 — particularly when the data structure is deep enough
that `sizeof()` lies by orders of magnitude.

OI is heavy to set up (needs DWARF, needs codegen). Worth it when
you've narrowed a memory mystery to a specific data structure and
want the receipts.

### Debugging a running container: ephemeral gdb sidecar

The sidecar pattern: `podman run --pid=container:<service>`
shares the service's PID namespace. The sidecar carries gdb,
the service does not. Cleanup is automatic when the sidecar
exits. Demo 6's `compose.debug.yml` ships a working example.

`gdbserver` is the alternative for when the PID-namespace approach
isn't enough — different host, security policy that disallows the
share, or rootless setups where namespace joining hits a wall.
The demo includes a `gdbserver` target so you can compare both.

### Producing useful core dumps from a container

`ulimit -c unlimited` inside the container is not enough on its
own; `/proc/sys/kernel/core_pattern` lives on the host, which
means the path you set has to be reachable from the container's
mount namespace. The usual move: bind-mount a writable host
directory at `/var/cores`, and set `core_pattern` to something
like `/var/cores/core.%e.%p.%t`. Document this in your runbook;
it's the kind of thing nobody remembers in the middle of an
incident.

## Demo

[`examples/demo-06-quality-pipeline/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/demo-06-quality-pipeline)
runs cppcheck and clang-tidy as part of the build, runs the
googletest suite, builds an ASan-instrumented variant for the
sanitizer pass, and (optionally) starts the service and attaches a
gdb sidecar that demonstrates a breakpoint without mutating the
running image.

## For deeper coverage

- Iglberger, *C++ Software Design*, ch. 3 — testability as a
  design property; the right shape of the seam between code and tests.
- Ghosh, *Building Low Latency Applications with C++*, ch. 11 —
  testing and debugging a low-latency C++ service end-to-end;
  emphasises sanitizers and `perf` as the right pairing for
  production code paths.
- The clang-tidy check list and rationale per check, upstream
  ([clang.llvm.org docs](https://clang.llvm.org/extra/clang-tidy/)).
- Meta's [Object Introspection talk](https://www.youtube.com/watch?v=6IlTs8YRne0)
  for the design rationale, and the tool's repo for getting it running.

## What's next

§12 stays in the build pipeline but turns to the longer-lived
question: how do you build the same binary again next month?
