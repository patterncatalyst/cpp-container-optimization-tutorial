---
title: "Statelessness 03 — PMR request arena"
description: "The runnable companion to compendium Doc 03: the layered monotonic + pool arena, per-request allocation, the bulk-release-vs-per-object asymmetry, and the lifetime trap caught by AddressSanitizer."
order: 203
card_eyebrow: "Compendium · <strong>Doc 03</strong>"
card_title: "PMR request arena"
card_blurb: "The layered monotonic + pool arena, per-request allocation freed in bulk, the release-cost asymmetry, and the lifetime trap caught live by AddressSanitizer."
layout: example
sectionid: examples
permalink: /examples/statelessness-03-pmr/
demo_dir: statelessness/03-pmr
github_path: examples/statelessness/03-pmr
---

> The full source for this example lives in [`examples/statelessness/03-pmr/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/statelessness/03-pmr) — clone the repo, `cd` in, and `./demo.sh`.

Compendium reference:
[Doc 03 — PMR and the request arena]({{ '/reference/statelessness/03-pmr/' | relative_url }})

Tutorial sections:
[§7 Memory Management]({{ '/docs/07-memory-management/' | relative_url }}) +
[§6 STL, Layout & C++20/23 Containers]({{ '/docs/06-stl-layout/' | relative_url }})

Where [02-raii]({{ '/examples/statelessness-02-raii/' | relative_url }})
showed a `RequestContext` carrying a small arena, this example goes deep on
the arena itself: the layered resource recipe, per-request allocation, the
release-cost asymmetry, and the lifetime trap that catches everyone the
first time.

## Why this matters

Per-request work allocates: tokens parsed out of a payload, intermediate
maps, scratch strings. On the default global allocator, every one of those
allocations is a separate `malloc`, every release a separate `free`, and
the cost is both the per-call overhead and the *variance* — the tail of a
latency distribution is where allocator contention and fragmentation show
up. Under a container this matters twice over:

- **Per-request memory must be bounded and predictable.** A handler that
  allocates an unbounded amount of scratch on the global heap makes the
  whole process's memory footprint a function of request shape — exactly
  what a memory cgroup punishes with an OOMKill.
- **Tail latency is the SLO that breaks first.** PMR's reliable win is not
  mean throughput; it is *shrunken tail-latency variance* and bounded
  per-request memory. A monotonic arena turns N scattered frees into a
  single pointer reset, removing a class of tail spikes.
- **Request-scope memory should have request-scope lifetime.** The arena
  is born with the request and dies with it. That is the same discipline
  as RAII, expressed in the allocator — and it makes the lifetime trap
  below the one thing you have to get right.

## What this demo shows

**The layered request arena** (`src/request_arena.hpp`). A
`monotonic_buffer_resource` for O(1) bump allocation, layered over an
`unsynchronized_pool_resource` that recycles size-classed blocks, over
`new_delete_resource`. The whole arena releases together when it leaves
scope — no per-object destructor walk for trivially-destructible scratch.
The type is deliberately **non-movable**: the monotonic resource holds a
pointer into the arena's own buffer, so moving it would dangle that
pointer.

**`mode=arena`** splits the payload into arena-allocated tokens
(`std::pmr::vector<std::pmr::string>`) and counts them in a
`std::pmr::unordered_map`, all freed in bulk at scope end.

**`mode=bench`** times allocating + releasing N objects through the arena
versus N individual `new`/`delete` pairs, returning both numbers. Read them
as context, not a scoreboard: the reliable win is bounded, predictable
per-request memory and shrunken tail-latency variance — *not* mean
throughput. glibc's allocator is fast, so at modest N the heap can match or
beat the arena's wall clock. The architectural reason is the point; the
numbers are confirmation when they confirm.

**The lifetime trap** is a standalone AddressSanitizer binary, `pmr-trap`.
It stores a `std::string_view` into arena memory in a process-scoped cache,
lets the arena die, then reads the cache — ASan reports
`heap-use-after-free`. The nonzero exit is the point: without ASan the bug
is silent until the freed memory is reused, the kind of "random" production
failure that's miserable to chase. It lives in its own binary because you
cannot safely host a use-after-free inside a long-lived service.

## How to run

```bash
cd examples/statelessness/03-pmr
./demo.sh            # build + arena + bench + the ASan trap
./demo.sh --keep     # leave the service running afterward
./demo.sh --clean    # tear down
```

The first build reuses the same gRPC chain as 02-raii, so a warm Conan
cache on the host makes it fast.

CI verification: `scripts/test-stateless-demo-03-pmr.sh`.

## What you'll see

Representative output on a Fedora 44 host with GCC 14 and Podman
5.x — the arena path, the benchmark, then the deliberate ASan trap firing:

```
==> mode=arena   (split payload, count tokens, free in bulk)
    tokens parsed   : 64
    distinct tokens : 41
    arena high-water: 7.8 KiB   (single bulk release at scope end)
    status: OK

==> mode=bench   (arena vs new/delete, N=100000)
    arena   alloc+release : 0.83 ms
    new/del alloc+release : 1.10 ms
    (context, not a scoreboard — the win is variance + bounded memory)

==> lifetime trap   (pmr-trap, AddressSanitizer)
=================================================================
==1==ERROR: AddressSanitizer: heap-use-after-free on address 0x...
READ of size 1 at 0x... thread T0
    #0 ... StringView::operator[]
    #1 ... main pmr_trap.cpp:NN
  freed by thread T0 here:
    #0 ... operator delete
    #1 ... RequestArena::~RequestArena
==1==ABORTING
    pmr-trap exit code: 1   <-- the point: the bug is caught, loudly
```

## How to read the output

- **`mode=arena` frees everything in one bulk release.** The "arena
  high-water" is the peak the request used; it all comes back with a single
  pointer reset when the arena leaves scope, not 41 individual frees.
- **The bench numbers are confirmation, not the headline.** If the arena is
  faster, good; if the heap matches it at small N, that's expected — glibc's
  allocator is fast. The durable win is the *tail*: under contention and at
  larger N the arena's variance is far lower. Don't treat a close wall-clock
  race as a failure of PMR.
- **The ASan trap exits nonzero on purpose.** The `heap-use-after-free`
  report with a nonzero exit code is the success condition for that step.
  A clean exit there would mean the trap *didn't* fire — which under ASan
  would itself be the surprise.
- **The freed-by frame names `~RequestArena`.** That is ASan telling you
  exactly which destructor released the memory the dangling `string_view`
  still points at — the lifetime lesson made concrete.

## Files

- `src/request_arena.hpp` — the layered monotonic + pool arena
  (non-movable; pointer into its own buffer)
- `src/main.cpp` — gRPC server: the `arena` work path, the `bench` path,
  and a healthz
- `src/client.cpp` — one-shot client that drives the two modes
- `src/pmr_trap.cpp` — standalone AddressSanitizer lifetime-trap demo
- `proto/processor.proto` — `MemoryProcessor`; `mode = arena | bench`
- `CMakeLists.txt` — svc + client + pmr-trap (ASan, static libasan)
- `conanfile.py` — gRPC + protobuf + abseil (no OTel)
- `Containerfile` — multi-stage UBI 10 → ubi-minimal + libstdc++; base
  gcc 14 has no 64-bit `libasan.a`, so `pmr-trap`'s `-static-libasan`
  link borrows one from `gcc-toolset-15-libasan-devel`
- `compose.yml` — single service; read-only rootfs + tmpfs
- `demo.sh` — build, bring up, run arena + bench + the trap

## Caveats and gotchas

- **The arena is non-movable on purpose.** The monotonic resource holds a
  pointer into the arena object's own buffer; a move would leave that
  pointer dangling. Don't add move operations to make it fit in a container
  — keep it pinned where it lives (in the `RequestContext`, on the stack).
- **`unsynchronized` means one thread.** The pool resource is the
  `unsynchronized` variant, which is correct because a request arena is
  touched by exactly one thread for the request's lifetime. Sharing it
  across threads is undefined behaviour; the threading rules are in the
  [threading example]({{ '/examples/statelessness-05-threading/' | relative_url }}).
- **ASan shadow memory in containers.** The demo runs `pmr-trap` directly
  and on most kernels ASan maps its shadow memory fine. If you hit `Shadow
  memory range interleaves` at startup (high ASLR entropy on newer
  kernels), the in-container `setarch -R` fix doesn't apply — the
  `personality` syscall it needs is blocked by seccomp — so apply a
  host-side mitigation: `sudo sysctl vm.mmap_rnd_bits=28` or run with
  `--security-opt seccomp=unconfined`. The trap itself is real either way.
  For what shadow memory is and the full set of failure modes, see
  [§12 Analysis & debugging]({{ '/docs/12-analysis-debugging/' | relative_url }}).
- **The bench is a wall-clock micro-measurement.** It is not a substitute
  for measuring your real handler under real load. Treat it as a sanity
  check on the asymmetry, not a production benchmark.

## Source materials

This example deepens material from the project's
[**bibliography**]({{ '/bibliography/' | relative_url }}):

- **Andrist & Sehr, *C++ High Performance* 2e, ch. 7** — custom memory
  management and `std::pmr`; the monotonic + pool layering recipe in detail
- **Iglberger, *C++ Software Design*, ch. 7** — value semantics and
  ownership; why the arena owns its memory and hands out non-owning views
- **Enberg, *Latency*, ch. 4** — the variance-and-tail framing that explains
  why the arena's reliable win is the tail, not the mean

## Linked tutorial sections

- [**§7 Memory Management**]({{ '/docs/07-memory-management/' | relative_url }}) —
  allocators, huge pages, and cgroup memory limits; this example is the
  request-scope half of that section's allocator story (the process-scope
  half is the allocator demo in the main track).
- [**§6 STL, Layout & C++20/23 Containers**]({{ '/docs/06-stl-layout/' | relative_url }}) —
  the `std::pmr` container variants (`pmr::vector`, `pmr::string`,
  `pmr::unordered_map`) used here, and the layout reasons they pay off.
- [**§12 Analysis & Debugging**]({{ '/docs/12-analysis-debugging/' | relative_url }}) —
  AddressSanitizer, shadow memory, and the container failure modes the
  lifetime trap exercises.

## Where it sits in the compendium

PMR builds directly on the RAII request scope from
[Doc 02]({{ '/examples/statelessness-02-raii/' | relative_url }}); the
threading rules behind the `unsynchronized` choice are in
[Doc 05]({{ '/reference/statelessness/05-threading/' | relative_url }}),
and the cache fix for the lifetime trap — a cache that *owns* its entries —
is in
[Doc 07]({{ '/reference/statelessness/07-state-externalization/' | relative_url }}).
The capstone
([Doc 10]({{ '/reference/statelessness/10-grpc-microservices/' | relative_url }}))
carries this exact arena as a `RequestContext` member.
