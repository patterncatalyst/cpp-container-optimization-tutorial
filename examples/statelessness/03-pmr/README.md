# statelessness/03-pmr — the PMR request arena

Compendium reference:
[Doc 03 — PMR and the request arena](../../../reference/statelessness/03-pmr/)

The runnable companion to compendium Doc 03. Where 02-raii showed a
`RequestContext` carrying a small arena, this example goes deep on the
arena itself: the layered `monotonic_buffer_resource` +
`unsynchronized_pool_resource` recipe, the per-request allocation
pattern, the O(1)-bulk-release-vs-O(N)-per-object asymmetry, and — the
part with teeth — the **lifetime trap** that catches everyone the first
time.

## What it demonstrates

**1. The layered request arena** ([`src/request_arena.hpp`](src/request_arena.hpp)).
A `monotonic_buffer_resource` for O(1) bump allocation, layered over an
`unsynchronized_pool_resource` that recycles size-classed blocks for the
monotonic resource's refills, over `new_delete_resource`. The whole
arena is released together when it leaves scope — no per-object
destructor walk for trivially-destructible scratch. The type is
deliberately **non-movable**: the monotonic resource holds a pointer
into the arena's own buffer, so moving it would dangle that pointer.

**2. `mode=arena`** — the handler splits the payload into
arena-allocated tokens (`std::pmr::vector<std::pmr::string>`) and counts
them in a `std::pmr::unordered_map`, then returns. Every allocation is
freed in bulk when the arena leaves scope.

**3. `mode=bench`** — times allocating + releasing N objects through the
arena versus N individual `new`/`delete` pairs, and returns both
numbers. **Read them as context, not a scoreboard.** Doc 03 is explicit:
PMR's reliable win is bounded, predictable per-request memory and
shrunken tail-latency variance — *not* mean throughput. glibc's
allocator is fast, so at modest N the heap can match or beat the arena's
wall clock. The architectural reason (request-scope memory tied to
request-scope lifetime) is the point; the numbers are confirmation, when
they confirm.

**4. The lifetime trap** ([`src/pmr_trap.cpp`](src/pmr_trap.cpp), a
standalone AddressSanitizer binary). It stores a `std::string_view` into
arena memory in a process-scoped cache, lets the arena die, then reads
the cache. ASan reports `heap-use-after-free`. The nonzero exit is the
*point* — without ASan the bug is silent until the freed memory is
reused, which is exactly the kind of "random" production failure that's
miserable to chase. The trap lives in its own binary because you cannot
safely host a use-after-free inside a long-lived service. The fix
(a cache that owns its entries) is in
[Doc 07](../../../reference/statelessness/07-state-externalization/).

## Running it

```bash
./demo.sh            # build + bring up + arena + bench + the ASan trap
./demo.sh --keep     # leave the service running
./demo.sh --clean    # tear down
```

CI verification: `../../../scripts/test-stateless-demo-03-pmr.sh`.

The first build reuses the same gRPC chain as 02-raii, so a warm Conan
cache on the host makes it fast.

## A note on AddressSanitizer in containers

On newer kernels (6.x), ASan can fail to map its shadow memory because
of high ASLR entropy — the symptom is `Shadow memory range interleaves`
or `failed to allocate` at startup, *before* the bug is reached. The
demo and test run `pmr-trap` via `setarch -R` (reduced ASLR) to
sidestep it, and `util-linux` is in the runtime image to provide
`setarch`. If you still hit it, set `vm.mmap_rnd_bits` lower on the
host:

```bash
sudo sysctl vm.mmap_rnd_bits=28
```

This is an ASan-in-container environment issue, not a problem with the
trap itself — the bug is real regardless.

## Layout

```
03-pmr/
├── proto/processor.proto    MemoryProcessor; mode = arena | bench
├── src/request_arena.hpp    the layered monotonic+pool arena (non-movable)
├── src/main.cpp             gRPC server: arena work + bench + healthz
├── src/client.cpp           one-shot client
├── src/pmr_trap.cpp         standalone ASan lifetime-trap demo
├── CMakeLists.txt           svc + client + pmr-trap (ASan, static libasan)
├── conanfile.py             gRPC + protobuf + abseil (no OTel)
├── conan.lock               empty placeholder
├── Containerfile            multi-stage UBI 9 → ubi-minimal + util-linux
├── compose.yml              single service; read-only rootfs + tmpfs
└── demo.sh                  the driver
```

## What this example deliberately leaves out

- **The connection-pool / cache fix** for the lifetime trap — that's
  [`07-state-externalization`](../07-state-externalization/) (Doc 07).
- **Threading rules** for why the arena is `unsynchronized` — see
  [`05-threading`](../05-threading/) (Doc 05).
