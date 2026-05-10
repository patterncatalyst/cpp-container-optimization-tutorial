---
title: Introduction & Mental Model
order: 2
description: Why container constraints change C++ performance reasoning, the four-layer model the rest of the tutorial hangs off, and the cross-cutting concepts (LTO, PGO, PIE/ASLR, threading models) every later section references.
duration: 18 minutes
---

## Why this isn't just C++ tuning

Performance advice in the C++ canon is excellent and almost
entirely written for a single-tenant host. You pick your compiler
flags, you pick your data structures, you measure on a quiet
machine, and the answer you get is the answer you keep.

That model breaks under containers. Your binary was built once,
on a build farm, against a toolchain you didn't pick, for an
instruction set you can only hope matches the host. It runs in a
cgroup that may revoke memory or CPU you thought you owned. It
shares a kernel with neighbours that don't share your latency
goals. The network packet your benchmark assumed was free now
traverses a veth pair before it gets near your process. None of
these are catastrophic — but each one nudges your tail latency
and silently invalidates a measurement.

Demo-01 already showed one full instance of this in miniature:
the same `main.cpp` produced binaries ranging from 689 MB to 26 MB
with identical p50 latency *and* one variant that wouldn't even
start because the build host's glibc had a symbol the runtime
host's didn't. Source unchanged; observed behaviour wildly
different. The four-layer model is how we'll keep that kind of
story straight.

## The four-layer model

This tutorial is structured around four layers, in the order the
photons hit them:

{% include excalidraw.html name="02-introduction-four-layers" caption="The four-layer model: toolchain, image, kernel, runtime — and which sections live in each" %}

1. **Toolchain.** Compiler, linker, optimization passes, profile
   data. LTO and PGO live here. So does PIE (the compiler-side
   half of ASLR). {% include section.html n=5 %} and {% include section.html n=13 %} own this layer.
2. **Image.** What you packaged. Base image, multi-stage strip,
   library linkage decisions, ABI labels. The choice between
   `ubi-multistage` and `ubi-micro` from demo-01 is an image-layer
   choice. {% include section.html n=4 %} owns this layer.
3. **Kernel.** The host kernel your container shares. `io_uring`,
   sysctls, scheduling policy, cgroup controllers, NUMA topology.
   Threading models hit this layer hardest because every
   `std::thread` you create is a kernel-visible task. {% include section.html n=8 %}, {% include section.html n=9 %}, {% include section.html n=11 %}
   own this layer.
4. **Runtime.** What's running right now. The cgroup the runtime
   put you in, the CPUs it pinned you to, the memory ceiling, the
   network namespace. ASLR (the runtime-side half of PIE) and the
   debugging toolkit you can attach live here. {% include section.html n=7 %}, {% include section.html n=10 %}, {% include section.html n=11 %}, {% include section.html n=12 %}
   own this layer.

Most production tail-latency stories I've seen come from a knob
at one layer being measured against a workload shaped by a
different layer. Image-layer decisions ("we shrank the image by
40%") get credit for runtime-layer wins ("we removed a
busybox-call shell-out we didn't notice"). Kernel-layer changes
("we enabled THP") get blamed for toolchain-layer regressions
("the new libstdc++ stopped using madvise the way the old one
did"). Naming the layer is half the work.

## What "fast" means here

Three different things, frequently conflated:

- **Throughput.** Requests per second a container can sustain at
  saturation. The number leadership cares about.
- **Latency.** Time from request to response. p50, p99, p99.9.
  The number on-call cares about.
- **Cost.** Cycles per request, bytes per request, joules per
  request. The number FinOps cares about.

Improving one almost always means trading the others. The
observability stack in {% include section.html n=10 %} exists to keep you honest about which
one you're moving. Demo-01's surprise — same p50 across all
four working variants — is a clean example: the toolchain
changes were real, but at that load the latency budget was
spent on queueing, not on CPU work. CPU profiles would have
showed a delta; wall-clock latency hid it.

## Compile-time foundations: LTO, PGO, PIE

These three concepts sit at the toolchain layer and surface
in every later section. {% include section.html n=5 %} verifies them with real numbers;
§2 introduces what they are and why they matter.

### LTO (Link-Time Optimization)

LTO defers a portion of the compiler's optimization work to
link time, when it can see the whole program at once.

A traditional build compiles each `.cpp` to a `.o` file in
isolation. The compiler can inline within a translation unit
but not across them, can't propagate constants across `.o`
boundaries, and can't dead-code-eliminate functions another
TU might still call. The linker's job is just to resolve
symbols and lay out the binary.

With LTO, each `.o` carries an intermediate representation
of the source rather than (or in addition to) machine code.
At link time the linker hands all of those IR blobs back to
the compiler, which can now inline across TU boundaries,
fold constants, eliminate functions nothing actually calls,
and devirtualize calls whose target is now visible.

Two flavors:

- **Full LTO.** Whole-program IR resolution at link time.
  Maximum quality; high RAM use; serial bottleneck.
- **Thin LTO.** IR shipped per-TU but with a summary that
  lets the linker do parallel, incremental cross-TU
  optimization. Most of the win, fraction of the cost.
  This is what demo-01 uses (`CMAKE_INTERPROCEDURAL_OPTIMIZATION=ON`
  with GCC 14 / clang).

LTO costs are real. Build time goes up; debug-info quality
can degrade; LTO + `-static` has historically been fragile
(and we hit a flavor of that in demo-01 r18 with
`-static-pie` segfaulting at startup). For most services the
trade is worth it. For a tiny CLI tool, often not.

### PGO (Profile-Guided Optimization)

PGO is a two-stage build where the second stage is informed
by measured runtime behaviour from the first.

Stage one compiles an *instrumented* binary with
`-fprofile-generate`. Every basic block, every branch, every
indirect-call site gains a counter. You run a representative
workload against it; the counters land on disk as `.gcda`
files (GCC) or `.profraw` (clang).

Stage two compiles again, this time with `-fprofile-use`
pointing at the gathered profile. The compiler now knows
which branches are taken 99% of the time, which functions
are hot, which indirect-call sites resolve to the same
target every time. It re-orders code so hot paths are
fall-through, inlines the hot callees aggressively, and
sometimes specialises the hot indirect-call sites with
inline guards.

The dependency on a *representative* workload is everything.
A profile gathered on a synthetic benchmark optimizes for
the synthetic workload. A profile gathered on a single
endpoint of a multi-endpoint service makes the other
endpoints worse. PGO is an excellent technique for systems
with stable traffic shapes; a poor fit for systems whose
traffic shifts seasonally.

Demo-01 captures one `.gcda` file (one TU, one source file)
and rebuilds with `-fprofile-correction` to handle the case
where the profile and the new source don't perfectly line
up. The wall-clock latency delta in our demo was zero — the
work each request does is too small for code reordering to
matter at this load. CPU profiles would tell a different
story. That mismatch is itself worth internalising.

### PIE (Position-Independent Executable)

A PIE is an executable whose code can be loaded at any base
address without modification. The compiler emits
position-independent code (no absolute references to its own
addresses); the linker emits a binary that the loader is
free to slide.

PIE is a compile-time flag pair: `-fPIE` for compilation,
`-pie` for linking. (The lower-cased `-fpie` is for "PIE
but assume small binary"; `-fPIE` is the usual.) Most modern
distros default to PIE for system binaries.

PIE's reason to exist is **ASLR (Address Space Layout
Randomization)**, which is the runtime-layer half of the
story.

## ASLR — the runtime half of PIE

ASLR is the kernel deciding, at every process start, where
in the address space to place the program text, the heap,
the stack, and shared libraries. An attacker who manages to
hijack control flow can no longer rely on hard-coded
addresses for `system()` or anything else; they have to leak
addresses first. Every modern Linux ships ASLR enabled by
default for shared libraries, the heap, and the stack — but
to randomise the *program text*, the program has to be a
PIE.

A non-PIE binary loads at its hard-coded base. ASLR can
randomise everything around it but not the binary itself,
which is the largest contiguous code region in the process.
A return-oriented programming chain that targets gadgets
inside the program text gets the same addresses on every
run.

Three layers come together here:

- **Toolchain:** compiled with `-fPIE`, linked with `-pie`.
- **Kernel:** has ASLR enabled (`/proc/sys/kernel/randomize_va_space`
  set to `2`).
- **Runtime:** the kernel actually slides the binary at
  `execve()` time.

Demo-01's `ubi-micro` variant uses plain `-static` (non-PIE)
because `-static-pie` plus LTO plus aggressive `strip` was
producing SIGSEGV at startup. We took the security trade to
get correctness; the binary doesn't get text randomization
but everything else around it still does. In a single-process
container that has nothing else loaded, the practical loss is
modest. In a long-lived service exposed to the internet, you
want PIE.

## Threading: a choice that crosses layers

The threading model you pick is a Source-layer decision (which
API you write), but it lands as a Kernel-layer cost (real or
synthetic threads), and it's *measured* at the Runtime layer
(cgroup pids, scheduling delay, memory budget). Getting it wrong
costs more inside a container than it does on bare metal because
the cgroup is a smaller, harder ceiling than the host.

{% include excalidraw.html name="02-threading-models" caption="Threading models laid out across the stackful/stackless axis and the kernel-visible/invisible axis, with where each fits the I/O-bound vs CPU-bound continuum" %}

### The lineup

There are roughly six threading approaches a modern C++
service in a container will reach for:

- **`std::thread` (C++11).** A 1:1 thread: one C++ thread maps
  to exactly one kernel task. Default stack on Linux glibc is
  8 MB *committed virtually*; physical RSS grows on touch.
  Each is independently schedulable, kernel-visible, and
  counts against `pids.max` in the cgroup. The default tool;
  the right tool for a small number of long-lived workers.

- **`std::jthread` (C++20).** Same kernel cost as
  `std::thread`. Two improvements: it joins on destruction
  (no `terminate()` if you forget) and it carries a
  `std::stop_token` so cooperative cancellation is in the
  language rather than ad-hoc. If you'd otherwise use
  `std::thread`, use `jthread`.

- **C++20 coroutines.** Stackless. Each coroutine is a
  compiler-generated state machine that fits inside a heap
  allocation roughly the size of its locals. They're
  *invisible* to the kernel — to the OS, the thread that's
  running coroutines is just one thread doing many small
  things. C++20 ships the language facility but no runtime;
  pair with cppcoro, libfork, or a hand-rolled scheduler.
  Suspension is cheap (no stack switch), throughput is high,
  but you carry the scheduler complexity.

- **Boost.Fibers.** M:N stackful. Many fibers cooperatively
  share a small pool of kernel threads. Each fiber has its
  own stack (configurable; ~64 KB default). Switching is a
  user-space stack swap (microseconds, not microseconds-and-
  then-a-syscall). The advantage over coroutines: you can
  use ordinary blocking-style code; the library makes the
  blocks cooperative. The disadvantage: stack memory adds
  up.

- **Boost.Context.** The low-level primitive Boost.Fibers is
  built on. Provides `make_fcontext` / `jump_fcontext` —
  raw, allocation-free stack switching. You almost never
  use this directly; you use it when building your own
  scheduler.

- **Library thread pools.** cpp-httplib's `ThreadPool`,
  Asio's executors, gRPC's completion-queue workers. Almost
  always 1:1 under the hood — N pre-spawned `std::thread`s
  pulling work off a queue. The library hides the
  scheduling but the kernel cost is the same as N
  `std::thread`s.

### I/O bound vs CPU bound

The single dimension that decides which model fits.

**CPU-bound** workloads spend most of their wall-clock time
running instructions. Compression, decryption, ML inference,
JSON serialisation in tight loops. Adding a thread when all
cores are already pegged just adds context-switch overhead
and cache thrash. Right answer: a pool sized to the number
of cores you actually have (not the host's; the cgroup's),
plus maybe one extra to keep the pipeline full during brief
idle moments. Coroutines and fibers don't help here —
there's no I/O to overlap.

**I/O-bound** workloads spend most of their wall-clock time
waiting. RPC fan-out to other services, database queries,
disk reads, network responses. Each request blocks for
milliseconds while another service computes. Adding more
threads gets you more concurrent waits — up to the point
where your scheduling and stack memory cost more than the
extra concurrency wins. For modest fan-out (tens of in-
flight requests), `std::thread` and library pools are fine.
For huge fan-out (10k+ in-flight per process), the kernel
cost of 10k threads becomes prohibitive and coroutines or
fibers — or a coroutine-aware I/O API like `io_uring`, {% include section.html n=8 %} —
become the default.

The mistake to avoid: picking coroutines for a CPU-bound
workload because "they're modern." All you do is move
context-switch cost from the kernel to your scheduler. The
mistake on the other side: trying to handle 10k concurrent
gRPC streams with `std::thread`-per-stream. Your stacks alone
will exceed the cgroup memory limit.

### The container interaction: requests, limits, and what `nproc` lies about

A container's "CPU" isn't a clean count. The cgroup's
`cpu.max` is a *bandwidth* knob (e.g. "300000 µs every 100000
µs" = "3 cores' worth on average"). The kernel still schedules
your threads onto whatever physical CPUs are free; it just
throttles you when you've used too much.

Three traps live here.

**Trap 1: `std::thread::hardware_concurrency()` returns the
HOST core count, not your cgroup's.** The C++ standard
predates cgroups; the function reads `/proc/cpuinfo` or
`sched_getaffinity()`. On a 64-core host with a 2-core
cgroup limit, you'll spawn a 64-thread pool, every one of
them eligible to run, then watch the kernel throttle the
group hard. Modern glibc reports the cgroup's effective
quota for `sysconf(_SC_NPROCESSORS_ONLN)` *if* the cgroup
v2 controllers are visible — but `hardware_concurrency()`
isn't required to use that source.

The mitigation: read `/sys/fs/cgroup/cpu.max` yourself and
size pools off that. cpp-httplib's pool defaulting to
`hardware_concurrency()` is what bit demo-01 originally; we
hard-coded 128 to make the demo robust, but the production
answer is "read your actual quota."

**Trap 2: requests are not limits.** Kubernetes-style
*requests* tell the scheduler "give me at least this much"
— it's a placement and priority knob. *Limits* tell the
kernel "throttle me past this." A pod with `requests: 1`
and `limits: 4` schedules cheaply and gets up to 4 cores
when they're idle, but gets kicked back to ~1 core
whenever a noisy neighbour wakes up. Sizing your thread
pool to the *limit* will give you tail latency that
oscillates with neighbour load. Sizing to the *request*
gives you steady, modest performance with idle slack
unused.

**Trap 3: limits aren't policed at thread creation.** A
1:1 model with thousands of threads doesn't fail at
`std::thread::thread()`. It fails at first run when the
kernel schedules them and your bandwidth ceiling kicks in,
or it fails at heap exhaustion when their stacks finally
touch RSS. Both modes look exactly like "the service got
slow" rather than "the service rejected work it couldn't
handle." Coroutines and fibers, with their per-task memory
footprint dominated by *locals* rather than *stacks*,
degrade more gracefully because the same memory budget
buys 100× more in-flight work.

### Mitigations

- **Read your real CPU quota.** `/sys/fs/cgroup/cpu.max`
  is two numbers (`quota period`); divide them, fall back
  to `hardware_concurrency()` if the file says `max max`.
  Size thread pools off that.
- **Pin thread pools to the request, not the limit.** Burst
  capacity is for the kernel, not for your application
  to count on.
- **For I/O-bound services with high fan-out, prefer
  coroutines or `io_uring` ({% include section.html n=8 %}) over more threads.** The
  cgroup `pids.max` and per-thread RSS will both thank you.
- **Set explicit stack sizes for `std::thread`.** A 64-KB
  stack via `pthread_attr_setstacksize()` is plenty for
  request-handler workloads and saves real memory.
- **Measure thread count with `cat
  /sys/fs/cgroup/pids.current`** during load tests, not
  just at peak. Drift here is invisible from the inside.

{% include section.html n=7 %} covers the memory-budget side of these decisions. {% include section.html n=11 %}
covers the cgroup CPU-share side. Demo-05 will show the
cost of getting it wrong with twin tenants on the same
host.

## The toolkit

Four classes of tools, each useful at a different layer and
a different scale. {% include section.html n=12 %} owns the deep dive; §2 introduces them.

- **Static analysis.** `cppcheck`, `clang-tidy`, `clang-analyzer`,
  ABI-diff via `abidiff`. Runs at build time; finds bugs
  the compiler doesn't. Cheap to add to CI; expensive to
  retrofit on a legacy code base. {% include section.html n=12 %} + demo-06.
- **Process-attach debuggers.** `gdb`, `gdbserver`. Attach to
  a running process, set a breakpoint, inspect state. In a
  container, `gdb` from a sidecar pod with `SYS_PTRACE`
  granted is the modern pattern; baking gdb into the
  service image is the *anti*-pattern. {% include section.html n=12 %} covers
  ephemeral debug sidecars.
- **Dynamic analyzers.** Valgrind (Memcheck for memory,
  Callgrind for cache, Helgrind for races); the sanitizers
  (`-fsanitize=address|undefined|thread|memory`). Slow,
  thorough, definitive — Valgrind in particular runs the
  binary on a synthetic CPU, and the slowdown is real
  (typically 10-50×). Use for finding bugs in CI on a
  representative workload, not in production. {% include section.html n=12 %} covers
  running them under cgroup memory limits without
  triggering OOM. *(macOS aside: Valgrind support has
  degraded badly there — broken on Apple Silicon since
  ~2020, and increasingly unmaintained. The native
  substitutes are Instruments — part of Xcode — for
  profiling and allocation tracking, the `leaks`
  command-line tool for memory-leak snapshots,
  `MallocStackLogging=1` plus `malloc_history` for
  allocation backtraces, and the sanitizers themselves,
  which work fine on Apple clang. The discussion here
  assumes a Linux container; the macOS workflow is
  different but the conceptual taxonomy stays.)*
- **Live-system tracers.** `perf` for sampled CPU profiles
  and tracepoints; eBPF tools (`bcc`, `bpftrace`,
  `bpftool`) for kernel-side observability without a
  recompile. These are the right answer for "the service
  is slow *right now*" — no sidecar, no slowdown, no
  rebuild. They need elevated privileges (`CAP_BPF` or
  full root) and a kernel new enough to have BPF Type
  Format (BTF). {% include section.html n=10 %} + demo-04.

The relationship to layers: static analysis is toolchain-
layer (catches bugs at build); gdb and Valgrind are
runtime-layer (attach to a running process); perf and eBPF
are kernel-layer (read kernel-side metrics about your
process and its peers).

The reason to know all four: each one answers a question
the others can't. Static analysis can't tell you why
production p99 spiked at 03:00. eBPF can't tell you that
your iterator-invalidation bug is on line 412 of
`request_handler.cpp`. Reach for whichever one matches the
question you're asking, not whichever one is loaded into
your editor.

## Reference pointers

For deeper grounding before you continue:

- Enberg, *Latency*, ch. 1-2 — the language for talking
  about latency budgets at all.
- Andrist & Sehr, *C++ High Performance*, ch. 1-3 — the
  measurement discipline this tutorial assumes you have.
- Iglberger, *C++ Software Design*, ch. 1-2 — how design
  decisions become performance decisions.

## What's next

{% include section.html n=4 %} starts at the image layer — pick a base; everything else
follows. {% include section.html n=5 %} covers the toolchain-layer optimizations (LTO and
PGO with real numbers). The threading deep-dive that §2 sketched
is split across {% include section.html n=7 %} (memory side) and {% include section.html n=11 %} (CPU side); demo-02
shows the memory side, demo-05 shows the CPU side.
