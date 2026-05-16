# Demo 06 — Memory Management & Allocators

Three allocator variants of the same C++23 binary, side-by-side on a
synthetic JSON-shaped allocator-stress workload:

| Variant | Allocator | How it's hooked up |
|---|---|---|
| `demo06-svc-std` | default glibc malloc | `std::allocator<T>` |
| `demo06-svc-pmr` | `std::pmr::monotonic_buffer_resource` + sync_pool fallback | `std::pmr::polymorphic_allocator<T>` |
| `demo06-svc-mimalloc` | mimalloc 2.x | static-linked, global new/delete replacement |

The workload is **synthetic** — it allocates the way a JSON parser
would (many small strings, mixed-size nested vectors, request-scoped
lifetime) without depending on any actual JSON library. This keeps
the comparison about allocator behavior rather than parser
optimization.

> **About jemalloc:** the original plan included jemalloc as a
> fourth variant. After four rounds (r71-r74) of attempted
> toolchain integration, we judged the cost/benefit had shifted
> away from including it: GCC 14's stricter C conformance vs
> jemalloc 5.3.1's pre-2024 source code, combined with multiple
> Conan recipe issues, didn't yield to either workarounds or
> proper fixes within reasonable round-budget. §7 prose discusses
> jemalloc's design as an alternative to mimalloc (per-arena vs
> segment-based) with appropriate book citations, preserving the
> educational coverage without requiring the binary to build. See
> r71-r74 round entries + G-33 and G-34 in `_plans/reconciliation-plan.md`
> for the full story.

## Run it

```bash
./demo.sh
```

First build is ~3-5 minutes on a clean cache (mimalloc's CMake
build is fast). Cached: ~30 seconds (just our app code).

Output: a comparison table. The numbers below are from a real
single-threaded run on a typical developer laptop (your numbers
will vary with CPU, frequency scaling, and the cache state, but
the *relative ordering* is reproducible):

```
==> Running 3 variants × 200 iterations
    depth=6 branch=4 values=8

==> Comparison table
Variant                            min µs    p50 µs    p99 µs    max µs    throughput/s   result_hash
────────────────────────────────  ──────────  ──────────  ──────────  ──────────  ───────────────   ──────────────────
std::allocator                       8.33      8.50     13.55     17.19        115,835   0xac09f54afe8c6152
std::pmr (monotonic+sync_pool)       3.81      3.87     16.06     40.43        169,620   0xac09f54afe8c6152
mimalloc                             8.46      8.50     25.35     26.96        114,013   0xac09f54afe8c6152

==> Sanity: all variants produced the same hash (0xac09f54afe8c6152)
```

The `result_hash` agreement is the correctness check: the workload
is supposed to produce identical output regardless of which
allocator is used. Allocator choice should be invisible at the
application layer; if hashes diverge, there's a bug in the PMR
path (the most likely place for type subtleties to creep in).

## Serve mode (r81+)

The same three binaries also support an HTTP-server mode for
load-testing with `hey`, `wrk`, or curl, and as the foundation for
r82's OpenTelemetry instrumentation. Activate it via:

- the `--serve` argv flag: `./demo06-svc-std --serve`
- or the env var: `DEMO06_MODE=serve ./demo06-svc-std`

Endpoints (all GET, all on port 8080):

- **`/healthz`** — liveness probe, returns `ok` as text/plain
- **`/info`** — variant name + workload defaults as JSON
- **`/run?iters=N`** — runs N iterations (default 1, max 10000),
  returns single-line JSON identical to batch mode's output

The server warms up with 50 iterations at startup so the first
`/run` doesn't carry cold-allocator overhead.

Bring up all three variants via the included compose file:

```bash
podman compose -f compose-serve.yml up --build
```

Then in another terminal:

```bash
# Check each variant's defaults
curl http://127.0.0.1:18601/info     # std::allocator
curl http://127.0.0.1:18602/info     # pmr
curl http://127.0.0.1:18603/info     # mimalloc

# Run 100 iters per variant
curl 'http://127.0.0.1:18601/run?iters=100'
curl 'http://127.0.0.1:18602/run?iters=100'
curl 'http://127.0.0.1:18603/run?iters=100'

# Sustained load with hey. r82 tunes httplib's keep-alive limits
# and thread pool to handle this gracefully; before r82 the defaults
# produced 10-second tail latencies under hey's default 50 workers.
hey -z 5s http://127.0.0.1:18601/run
hey -z 5s http://127.0.0.1:18602/run
hey -z 5s http://127.0.0.1:18603/run
```

Ports `18601/02/03` follow the convention `186XX` (with the demo
number `06` in the middle) to avoid collision with other demos'
host ports.

### Why serve-mode numbers may differ from batch-mode numbers

When you compare `./demo.sh` (batch) against `curl /run?iters=N`
(serve), PMR's relative advantage often shrinks. This isn't a
bug; it's a teaching point worth flagging in §7 prose:

**PMR's wins are sensitive to working-set residency.** The 1 MB
`static thread_local` arena buffer needs to stay hot in cache for
the bump-allocator advantage to materialize. Batch mode runs the
workload in a tight loop on the main thread; the buffer stays in
L2 for the entire 200-iter run. Serve mode runs each `/run` on an
httplib worker thread that's also handling HTTP parsing, JSON
formatting, and signal dispatch between requests — the buffer can
be partially evicted, and the first iter of each request pays
cold-cache costs.

Real services don't always look like batch microbenchmarks. The
allocator that wins in a tight loop may not win the same way under
realistic request handling patterns. r83's OpenTelemetry histograms
will let you see this distribution across hundreds of requests.

## What the numbers say

Reading the table above as a teaching artifact for §7 prose:

**PMR wins decisively on the common case.** 45% faster p50, ~47%
more throughput. Bump allocation in a monotonic buffer is
unbeatable for this access pattern: many small allocations within
a tight time window, all freed together via arena reset. Instead
of N individual frees on iteration exit, the entire arena resets
in O(1).

**PMR's tail is worse.** p99 16µs vs std's 13.55µs, max 40µs vs
17µs. The arena reset is doing batch work that occasionally
spikes — a classic latency-vs-throughput tradeoff. **PMR isn't a
free win**; you trade some predictability for substantial average-
case speed. Honest teaching material: don't promise audiences
that PMR is universally faster.

**mimalloc is essentially indistinguishable from std::allocator
here.** Not a defect; expected behaviour. mimalloc shines on
multi-threaded workloads (per-thread heaps, lock-free
free-list management), larger allocations (better huge-page
handling), and longer-lived heaps (better fragmentation
resistance). For our single-threaded short-lived tree builder,
the malloc geometry is comparable to glibc's. If you're going to
switch your service from glibc to mimalloc, profile YOUR workload
first.

## Workload design

Per iteration:

1. Seed a deterministic PRNG (same seed each run → same tree shape)
2. Recursively build a tree:
   - Each node has a 12–28 character label
   - 0–8 ints in a `values` vector
   - 0–4 child nodes (tapering with depth)
   - Max recursion depth: 6
3. Walk the tree, accumulate an FNV-1a hash over all labels + values
4. Tree drops on scope exit (RAII)

Why this shape:

- **Many small allocations** (≈30 bytes per string) is where the
  per-call overhead of glibc malloc shows up
- **Nested vectors** produce mixed-size allocations, exercising
  size-class binning
- **Recursive structure** produces realistic working-set sizes
  (kilobytes per request, not bytes)
- **Strictly request-scoped** lifetime is where PMR's
  monotonic_buffer_resource arena pattern wins — instead of N+1
  individual frees, the entire arena resets in O(1) at scope exit

## Scope per round

This demo is being built incrementally. Round A (the toolchain
proof, r71-r79) is complete. Round B (HTTP + OTel observability)
is in progress; r81 (this round) ships HTTP, r82 will add OTel.
Round C (cgroups, huge pages, threads toggles) is planned.

| Round | What's in | Status |
|---|---|---|
| r71 | 4-way binary build first attempt | superseded |
| r72 | jemalloc chmod-retry workaround (G-33) | partial — got past configure but make failed |
| r73 | jemalloc GCC 14 ENV CFLAGS attempt (G-34) | failed — env shadowed by Conan toolchain |
| r74 | jemalloc GCC 14 conf-mechanism attempt | failed — same compile errors |
| r75 | 3-way drop jemalloc, ship std + PMR + mimalloc | `conan install` clean |
| r76 | mimalloc CMake target name `mimalloc-static` not `mimalloc::*` | works |
| r77 | `--whole-archive` inline in target_link_libraries; mimalloc-static is INTERFACE not STATIC | works |
| r78 | First real C++ bug: `emplace_back(memory_resource*)` PMR misuse | works |
| r79 | Second real C++ bug: PmrNode missing allocator-extended copy + move ctors for `reserve()` | **Round A complete** |
| r80 | Docs lock-in (this README's actual numbers + rounds table) | shipped |
| r81 | HTTP server mode (`--serve`); cpp-httplib vendored; compose-serve.yml | shipped |
| r82 | 3 polish fixes: subscription-manager warning, httplib keep-alive + thread pool, cache-sensitivity README note | shipped |
| **r83** | **TCP_NODELAY (Nagle's algorithm fix) — unmasked by r82's keep-alive fix; 40ms-per-request was Linux delayed-ACK timeout** | **shipped** |
| r84 | OTel traces/metrics/logs export to LGTM; compose-observe.yml | planned |
| r85+ | Layer toggles: `HUGE_PAGES`, cgroup `memory.high`, `THREADS` | planned |

## The two PMR bugs worth promoting to §7 prose

Demo-06's debugging journey (r78 + r79) surfaced two PMR mistakes
that show up constantly in production code:

**Mistake #1: `emplace_back(memory_resource*)` thinking it threads
the resource** (r78). The PMR vector's `uses_allocator` machinery
already injects its own allocator into the new element's
constructor. Calling `emplace_back(mr)` makes the vector try
`PmrNode(mr, allocator)` — two arguments — which doesn't match
PmrNode's `PmrNode(allocator_type)` one-arg constructor. Compile
error: *"construction with an allocator must be possible if
uses_allocator is true."*

Fix: just call `emplace_back()` with no args. The vector injects
its allocator. Don't thread `mr` manually.

**Mistake #2: Forgetting allocator-extended copy and move
constructors** (r79). A type is properly allocator-aware only if
it provides all three:

```cpp
PmrNode(allocator_type)                    // default + allocator
PmrNode(const PmrNode&, allocator_type)    // copy    + allocator
PmrNode(PmrNode&&,      allocator_type)    // move    + allocator (noexcept)
```

With only the first one, `emplace_back()` works but `reserve()`
fails the moment the vector needs to grow its buffer — it can't
move existing elements into the new storage with the right
allocator. The symptom is often delayed: small inputs work
because reserve is a no-op, then production data triggers the
grow and the static_assert fires.

Together these two cover the majority of "I tried PMR and it
didn't work" reports. Each is now a worked example in this
demo's source.

## Source materials this demo deepens

- **Andrist & Sehr, *C++ High Performance* 2e, Ch. 7** — custom
  allocators, PMR design rationale, allocator-aware containers
- **Enberg, *Latency*, Ch. 3** — allocator measurement, the
  "general-purpose allocator tax" thesis, mimalloc/jemalloc/tcmalloc
  comparison from the Helsinki perf group
- **Iglberger, *C++ Software Design*, Ch. 7** — the Bridge / PIMPL
  discussion intersects with PMR's lifetime model (which class owns
  the memory_resource? where does it live?)

## Linked tutorial sections

- §7 (Memory Management): this demo is §7's worked example. The
  §7 prose discusses the theory; this demo measures it.
- §11 (Noisy Neighbors): demo-06's cgroup `memory.high` layer (r73)
  demonstrates the "what happens under memory pressure" angle that
  §11 covers more broadly with cpu.weight / cpuset.
- §10 (Observability): when r72 wires in OTel, the latency
  histograms reach Grafana like demo-04's do.
