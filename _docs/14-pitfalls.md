---
title: "Pitfalls"
order: 14
description: AVX-512 mismatches that SIGILL on production, abstraction overhead invisible in the type system, container builds that take seven minutes for thirty seconds of compile, and the EPERM/EACCES rubric that tells you which security layer is denying you.
duration: 12 minutes
---

## Learning objectives

By the end of this section you can:

- Explain why a binary built with `-march=native` on the build
  farm SIGILLs on a smaller production host, and pick a
  portable micro-architecture target (`x86-64-v3` or function
  multi-versioning) instead.
- Identify abstraction-induced overhead — `std::function` on a
  hot loop, `std::shared_ptr` refcount churn, virtual dispatch
  behind a "polymorphic" interface — by reading flame graphs.
- Diagnose why a container build takes 7 minutes when the
  bare-metal build takes 30 seconds, and apply BuildKit-style
  cache mounts to fix it.
- Use the EPERM/EACCES rubric to tell which container security
  layer (capabilities, seccomp, SELinux/AppArmor, sysctl)
  denied a syscall — because the fix is layer-specific.
- Recognize the tutorial-default security pattern
  (`seccomp=unconfined`, `label=disable`) and **not ship it**
  to production by accident.

## Diagram

{% include excalidraw.html name="14-pitfalls-avx512-mismatch" caption="The AVX-512 mismatch trap: build host has it, runtime host doesn't, kernel sends SIGILL" %}

## The shape of a pitfall

Pitfalls aren't bugs. A bug is a piece of code that's
syntactically wrong, or that misbehaves on some inputs you
forgot about. A pitfall is **code that looks correct on every
machine you built and tested on, but fails on a different
machine, or under different load, or under different security
policy**. The four pitfalls below all have this shape: they
pass code review, they pass CI, they fail in production.

They all reward the same defense: *measure on something close
to the real deployment target*. The remaining sections of this
tutorial — particularly [§10's observability stack](10-observability-profiling.md)
and [§11's noisy-neighbor isolation](11-noisy-neighbors.md) —
are what makes that measurement practical.

## AVX-512 / `-march=native` mismatch

The diagram at the top of this section is the failure mode in
one picture. Concretely:

```bash
# On the build host (Intel Sapphire Rapids — has AVX-512):
gcc -O3 -march=native -o myservice myservice.cpp

# The compiler emits AVX-512 instructions everywhere it can:
objdump -d myservice | grep -c 'vmovdqa64\|zmm[0-9]\+'
# → 47

# Build the container:
podman build -t myservice:1.0 .

# Deploy to a runtime host (AMD Zen 3, or older Xeon, or
# a c5.large EC2 instance) that does NOT have AVX-512:
podman run myservice:1.0
# → Illegal instruction (core dumped)
```

The kernel sends `SIGILL` (signal 4, "illegal instruction") the
moment the CPU sees an AVX-512 opcode it can't decode. The
container starts, the dynamic linker loads, control jumps to
your code, the first hot path that the compiler vectorized
fires, and the process dies. **Smoke test on the build host
passes; production deploy fails on first request**.

The fix is to **stop using `-march=native` for container
builds**. The portable alternatives:

**Option 1 — x86-64 micro-architecture levels (recommended for
most workloads):**

| Level | Required CPU features | Hardware era |
|---|---|---|
| `x86-64` | baseline (SSE2) | any x86_64 CPU since 2003 |
| `x86-64-v2` | SSE3-SSE4.2, popcnt | Nehalem+ (2008+) |
| `x86-64-v3` | + AVX, AVX2, BMI1/2, FMA | Haswell+ (2013+) |
| `x86-64-v4` | + AVX-512 | Skylake-X+, Sapphire Rapids+ |

For most cloud and on-prem deployments in 2026, **`x86-64-v3`
is the sane default** — it covers everything Haswell-or-newer
on the Intel side and Zen-2-or-newer on the AMD side, while
giving the compiler access to AVX2 and FMA (which between them
explain ~80% of the speedup `-march=native` would have
delivered).

```cmake
# CMake — set the baseline micro-architecture for the whole project
add_compile_options(-march=x86-64-v3)
add_link_options(-march=x86-64-v3)
```

**Option 2 — function multi-versioning:** compile *multiple*
versions of hot functions and have glibc's `ifunc` resolver
pick at runtime:

```cpp
__attribute__((target_clones("avx512f", "avx2", "default")))
double sum_of_squares(std::span<const double> xs) {
    double acc = 0;
    for (double x : xs) acc += x * x;
    return acc;
}
```

The compiler emits three versions; the dynamic loader inspects
`/proc/cpuinfo` and picks the best match at first call. Useful
when you really do want AVX-512 on hosts that have it, without
exploding on hosts that don't. The cost is binary size (~3× for
multi-versioned functions) and a one-time resolver dispatch.

Write the chosen `-march` into the image as a `LABEL` (per
[§4's image strategy](04-image-strategy.md)) so future-you can
inspect what was baked in without disassembling:

```dockerfile
LABEL ai.cpp-tutorial.march="x86-64-v3"
LABEL ai.cpp-tutorial.multi-versioned-funcs="sum_of_squares,fft_radix2"
```

## Silent abstraction overhead

The three abstractions that look free in the type system but
cost real bytes and cycles on a hot path — already introduced
in [§6's "over-abstraction trap" section](06-stl-layout.md) —
deserve a second pass here because they're the most common
*pitfall* category, not just a category of choice.

**`std::function` on a hot loop**:

```cpp
// Looks fine. Type-erased, flexible, idiomatic.
std::vector<std::function<int(int)>> handlers;
for (auto& h : handlers) total += h(input);
```

Each call goes through:
1. SBO check (is the captured state ≤ 16 bytes?)
2. Indirect call through the type-erased dispatch
3. Possibly a cache miss on the captured state if it's heap-allocated

For 100k iterations, the overhead is ~200-500 ns/call × 100k =
~20-50 ms of pure overhead. Flame graphs show it as time
spent in `std::function::operator()` — *not* in the function
you intended to time.

The fix: **template the callable** if you can know it at compile
time, or use a typed function pointer if you can't:

```cpp
template <typename F>
int sum_handlers(std::span<const F> handlers, int input) {
    int total = 0;
    for (auto& h : handlers) total += h(input);
    return total;
}
```

**`std::shared_ptr` refcount churn**:

```cpp
// Looks fine. Shared ownership, RAII.
void process(std::shared_ptr<Request> r);
```

Each `shared_ptr` copy is two atomic operations (refcount inc,
weak-count check). Atomic ops cost ~10-30 ns on contended
cores. A hot path that passes `shared_ptr` by value pays this
cost on every call frame:

```cpp
// 100k req/s, three shared_ptr copies per request = 600k atomic
// ops/sec. At 20 ns each, that's 12 ms/sec of pure refcount
// overhead on one core.
```

The fix: **pass by reference if you don't need shared
ownership** (you usually don't):

```cpp
void process(const Request& r);  // No refcount touch
```

When you genuinely do need shared ownership (the most common
example: a callback that outlives its caller), still pass by
`const shared_ptr<T>&` to functions that aren't taking
ownership — they don't need to increment the count.

**Virtual dispatch in a hot loop**:

```cpp
class Shape { public: virtual double area() const = 0; };
std::vector<std::unique_ptr<Shape>> shapes;
for (auto& s : shapes) total += s->area();
```

Each iteration: one pointer chase to the Shape object (cache
miss likely, see [§6](06-stl-layout.md)), one indirect call
through the vtable (another small cost), and the vtable lookup
itself loads from cold cache the first time. On 1M iterations,
the overhead compounds to ~30-50 ms vs. a non-polymorphic
version.

The fix when the variant set is closed: `std::variant<Circle,
Square, Triangle>` + `std::visit`. The objects are stored in
the vector itself (one cache line, no indirection), and
`visit` dispatches without an indirect call.

```cpp
std::vector<std::variant<Circle, Square, Triangle>> shapes;
for (auto& s : shapes) {
    total += std::visit([](auto& shape) { return shape.area(); }, s);
}
```

Iglberger's *C++ Software Design* chapter 4 (the abstraction
tax) and chapter 9 (type erasure trade-offs) walk through this
conversion in detail. **Flame graphs are the diagnostic
weapon**: each of these patterns shows up as time spent in a
function you didn't intend to be visible (`std::function::operator()`,
`__atomic_fetch_add`, `Shape::~Shape()`). Once you know what to
look for, the gap closes quickly.

## Container build slowness

"The CI build takes 7 minutes and the bare-metal build takes
30 seconds. Why?" — three common causes, in roughly the order
they bite:

**Layer cache invalidation by source change**: every change to
`src/*.cpp` invalidates the layer that ran `dnf install` if
the `COPY . /src` line is *above* the `RUN dnf install`. [§4
covers the ordering rule](04-image-strategy.md); the short
version is dependency installs go above source `COPY` lines.
Symptom: every build re-downloads `gcc-toolset-14`. Easy 5-10
minute fix per build, recurring.

**Missing build-cache mounts**: Conan, ccache, vcpkg, npm
each have a per-user cache directory that survives across
builds. A naïve Containerfile re-downloads dependencies every
build because the cache directory inside the build container
doesn't persist. BuildKit-style cache mounts (which Podman
supports via the `--mount=type=cache` syntax inside `RUN`) fix
this:

```dockerfile
FROM ubi9:latest AS build
RUN dnf install -y gcc-toolset-14 cmake ninja-build python3-pip
RUN pip3 install conan

# Mount a persistent cache directory for Conan
RUN --mount=type=cache,target=/root/.conan2,sharing=locked \
    conan install . --lockfile=conan.lock --build=missing

# Same trick for ccache
RUN --mount=type=cache,target=/root/.ccache,sharing=locked \
    cmake --preset conan-release && \
    cmake --build --preset conan-release
```

The cache mount is **not** a layer in the resulting image —
the cache survives across builds in `~/.local/share/containers/cache/`
on the host but doesn't ship in the image. Conan dependency
resolution drops from "fetch and rebuild" (1-3 minutes) to
"link against cached binary" (~5 seconds) on subsequent builds.

**Network-pulled dependencies on every build**: if your build
talks to a non-cached package registry on every build, network
latency dominates wall-clock time. The lockfile pattern from
[§13](13-reproducibility-abi.md) plus a mounted cache directory
addresses this: Conan downloads each package once, hashes it
into the cache, and reuses across builds.

Demo-01's `Containerfile.ubi-multistage` uses the cache-mount
pattern explicitly; demo-04's hermetic-build setup uses
lockfile-driven resolution. Compare the wall-clock times in
demo-01's `./demo.sh` between a clean build and a re-build
after a `.cpp` change — the difference is usually 5-10×.

## Container security layers and the EPERM/EACCES rubric

When a syscall fails inside a container with a permission
error, **which error code you get tells you which security
layer denied you**. This matters because the fix is layer-
specific — blindly bypassing one layer when a different layer
is the actual denier wastes time, or worse, opens the wrong
security hole.

The four primary layers, what each returns on deny, and what
relaxes them:

| Layer | Returns | Relax option |
|---|---|---|
| **Linux capabilities (DAC)** | `EPERM` (1) | `--cap-add=...` for the specific capability |
| **seccomp filter** | `EPERM` (1) | custom profile that allows the specific syscalls |
| **SELinux / AppArmor (MAC)** | `EACCES` (13) | custom policy module for the specific class |
| **`kernel.io_uring_disabled` sysctl** | `EPERM` (1) | host-side sysctl change + `io_uring_group` membership |

The **`EPERM` ambiguity** (three of the four layers return it)
means EPERM debugging is "check each layer in turn". But
**`EACCES` is unambiguous**: SELinux or AppArmor is denying
you. On Fedora/RHEL with SELinux enforcing, that means the
`container_t` policy doesn't permit the operation.

A worked example, from demo-03's development history (gotcha
G-32 from r66):

1. Initial run of the `io_uring` echo server failed with `EPERM`
   on `io_uring_setup`. Suspected seccomp; verified with
   `strace`. Added `security_opt: seccomp=unconfined` to the
   compose file.
2. Re-run — failed with a *different* errno, `EACCES`, on the
   same syscall. The fact that the errno changed proved
   seccomp had been the first gate and SELinux was a separate
   one. Added `security_opt: label=disable`.
3. Re-run — io_uring worked.

The general principle: **don't blanket-disable a security
layer to make one feature work**. Find the specific
permission, capability, or syscall the feature needs and grant
exactly that. The rest of the layer's enforcement stays in
place; an attacker who later compromises the process still
hits the boundaries that weren't touched.

Demo-03 ships `compose.production.yml` as the audit-grade
alternative: a custom seccomp profile that adds exactly
`io_uring_setup`, `io_uring_enter`, and `io_uring_register` to
the docker-default allowlist, plus a custom SELinux policy
module that grants the `io_uring` permission class to a
dedicated container type. The development `compose.yml` uses
the blanket-disable for first-run convenience; **don't deploy
the development compose to production**.

The rubric also applies to other deny scenarios — `mount`
returning `EPERM` is usually capabilities (no `CAP_SYS_ADMIN`);
`bind()` to a low port returning `EACCES` is usually SELinux;
opening `/proc/PID/mem` returning `EACCES` is SELinux blocking
ptrace. The layer-by-layer mental model is the same regardless
of which feature you're trying to enable. [§8's io_uring
security gates section](08-io-latency.md) covers the specific
io_uring case in more depth, including the liburing
return-value convention that makes the diagnosis trickier than
it should be.

## Tutorial-default security vs production security

The tutorial compose files use `security_opt: seccomp=unconfined`
and `security_opt: label=disable` for io_uring services because
the alternative (custom seccomp profile + custom SELinux module
+ `sudo semodule -i ...` to install) is a heavy first-run
hurdle. **This is a deliberate pedagogical choice for tutorial
demos.**

The pitfall: it's easy to copy the tutorial compose pattern
into a service that's about to deploy somewhere real. *Don't*.

Demo-03's directory ships two compose files side by side:

- `compose.yml` — tutorial-friendly; first-run works without
  sudo; security boundaries dropped wholesale.
- `compose.production.yml` — audit-grade; ships a custom
  seccomp profile + a custom SELinux policy module that
  surgically grants exactly the `io_uring` syscalls and
  policy class; passes a security audit.

The structure mirrors how production hardening actually
happens: get something working with relaxed security, identify
exactly which restrictions need to relax, craft a minimal
exception, then deploy. The pitfall is shipping step 1 instead
of step 3.

For non-io_uring services, the tutorial default of `ubi9-micro`
+ no security-opt overrides is already production-appropriate.
[§4's runtime base selection](04-image-strategy.md) and
[§12's debug-sidecar pattern](12-analysis-debugging.md) compose
into "the prod image is minimal + locked-down; the diagnostic
tooling lives in a separate ephemeral sidecar."

## Profiling perf inside containers — the symbol resolution trap

`perf record` inside a container appears to work but the
flame graphs you generate are missing function names — all the
samples resolve to `[unknown]` or to hex addresses. The cause:
`perf` needs access to the binary's debug symbols, which live
on the host where the binary was built, not inside the
stripped runtime image.

The fixes, in order of preference:

```bash
# Option 1: capture inside the container, resolve symbols outside
podman exec myservice perf record -F 99 -g -p 1 -o /tmp/perf.data sleep 30
podman cp myservice:/tmp/perf.data ./perf.data
perf report -i ./perf.data --symfs=/path/to/build/binary

# Option 2: use the debug-sidecar pattern (see §12)
podman run --rm \
    --pid=container:myservice-prod \
    --cap-add=SYS_PTRACE \
    --cap-add=SYS_ADMIN \
    debug-tools:latest \
    perf record -F 99 -g -p 1 sleep 30

# Option 3: ship the binary with debug symbols stripped to
# a separate .debug file (see §12); the debug image has the
# .debug file and can resolve symbols even when the prod
# image is stripped.
```

[§10 develops the perf workflow further](10-observability-profiling.md);
[§12 covers the debug-sidecar pattern in full](12-analysis-debugging.md).
The pitfall is shipping a stripped-binary prod image without
the corresponding debug-symbol artifact archived somewhere
recoverable — when an incident demands a flame graph, the
symbols need to exist somewhere.

## Why these are pitfalls and not bugs

Every pattern in this section *works* on the developer's
machine, *passes* CI, *deploys* successfully — and then fails
under conditions the development environment didn't cover.
That's the shape of a pitfall:

- AVX-512 / `-march=native` works on the build host because
  the build host has AVX-512.
- `std::function` in a hot loop works in benchmarks that test
  a single handler because the benchmark doesn't stress the
  type-erasure cost.
- Container builds are fast in a clean repo because there's no
  cache to invalidate.
- Tutorial-default security works in development because there's
  no policy enforcement.

The defense against each is **measure on something closer to
the deployment target**. Run benchmarks on hardware that
matches production's micro-architecture, not the build farm's.
Run flame graphs against load that matches production's
concurrency, not single-handler smoke tests. Rebuild containers
incrementally to test cache-mount effectiveness, not from
scratch every time. Deploy to a staging environment with the
production security policy at least once before deploying to
production.

The first half of this tutorial built the optimization toolkit;
the second half is the discipline to know when each tool
applies. Pitfalls are where discipline matters more than
toolkit.

## Demo

This section is **recap, not a new demo**. Each pitfall is
illustrated by a demo elsewhere in the tutorial:

| Pitfall | Demo it shows up in |
|---|---|
| AVX-512 / `-march=native` | demo-01 (the `ubi-micro-glibc-mismatch` variant has the same cross-host story for glibc) |
| `std::function` / `shared_ptr` / virtual dispatch overhead | demo-02 (over-abstraction sub-tests) |
| Container build slowness | demo-01 (cache-mount vs not) |
| EPERM/EACCES security rubric | demo-03 (the io_uring + container security story) |
| Tutorial vs production security | demo-03's `compose.production.yml` |
| perf symbol resolution | demo-04 + demo-06 (perf record against containerized processes) |

## For deeper coverage

- Andrist & Sehr, *C++ High Performance*, ch. 6 (CPU and
  micro-architecture awareness)
- Iglberger, *C++ Software Design*, ch. 4 (the abstraction
  tax), ch. 9 (type erasure trade-offs)
- [GCC x86 Function-multiversioning
  documentation](https://gcc.gnu.org/onlinedocs/gcc/x86-Function-Attributes.html)
- [Podman BuildKit-style cache mounts
  reference](https://docs.podman.io/en/latest/markdown/podman-build.1.html#mount)
- [Red Hat — Container security: the bigger
  picture](https://www.redhat.com/en/topics/security/container-security)

## What's next

[§15 closes the loop](15-where-to-go-next.md) and points at
the books, papers, and resources you'll want once you've
finished this tutorial — Enberg, Andrist & Sehr, Iglberger,
the Brendan Gregg performance books, and the smaller set of
"if you have time for one more thing" reads.
