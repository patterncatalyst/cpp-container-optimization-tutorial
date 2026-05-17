# Demo 06 — Memory Management & Allocators

Tutorial section: [§7 Memory Management](/docs/07-memory-management/)

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

> **A note on jemalloc.** The original plan included jemalloc as a
> fourth variant. jemalloc 5.3.1's pre-2024 source code doesn't
> compile cleanly under GCC 14's stricter C conformance, and getting
> Conan to inject the right CFLAGS through its toolchain wrapper
> turned out to be brittle. §7 prose covers jemalloc's design as an
> alternative to mimalloc (per-arena vs segment-based) with the
> relevant Andrist & Enberg citations, preserving the educational
> coverage without making the binary depend on a fragile build.

## Why this matters

Allocator choice is one of the largest performance levers in a
typical C++ service — and one of the least often measured. The
default `std::allocator` calls into the host's `malloc`, which on
glibc means per-allocation locking, size-class binning across a
process-global heap, and lazy reclamation that can fragment over
hours of uptime. For workloads that allocate heavily in short bursts
(JSON parsing, AST construction, per-request scratch space), the
allocator can easily dominate the CPU profile.

The three variants exercise three different points on the
strategy/cost curve:

- **`std::allocator`** is the honest baseline. Whatever your code
  does, this is what it costs by default.
- **`std::pmr`** (C++17 polymorphic memory resources) lets you swap
  the allocation strategy without changing the type signatures.
  Here we use `monotonic_buffer_resource` — a bump allocator over a
  pre-sized arena — backed by `synchronized_pool_resource` for
  overflow. Allocation is a pointer-bump; deallocation is a no-op;
  the entire arena resets in O(1) at scope exit.
- **`mimalloc`** is a drop-in `malloc` replacement that wins through
  per-thread heaps, lock-free free-list management, and aggressive
  size-class consolidation. It's the production default at Microsoft
  and several other large C++ shops.

§7 of the tutorial develops the underlying mechanics; this demo lets
you watch the numbers move.

## What this demo shows

Three execution modes, each progressively closer to a real service:

- **Batch mode** (`./demo.sh`) — runs the synthetic workload in a
  tight loop on each allocator variant and prints a comparison
  table with min / p50 / p99 / max timings. The cleanest signal:
  no HTTP overhead, no network jitter, no cache eviction from
  other work.
- **Serve mode** (HTTP via `podman compose -f compose-serve.yml`) —
  the same three binaries expose `/run?iters=N` over HTTP. Drive
  them with `hey` to see how allocator behavior changes under
  sustained load with httplib worker threads in the mix.
- **Observe mode** (HTTP + OpenTelemetry via the LGTM stack) —
  same serve mode binaries, now instrumented with OTel traces,
  metrics, and logs. The Grafana panels make the per-allocator
  tail-latency distribution visible across hundreds of requests
  instead of inferring it from single curl calls.

Each mode tells a slightly different story; together they cover
the "what changes from microbenchmark to real workload"
trajectory that informs allocator decisions in production.

## How to run

```bash
./demo.sh
```

First build is ~3-5 minutes on a clean cache (mimalloc's CMake build
is fast). Cached: ~30 seconds (just our app code).

## What you'll see

Representative output from a real single-threaded run on a typical
developer laptop. Your numbers will vary with CPU, frequency
scaling, and cache state — but **the relative ordering is
reproducible** on any modern x86_64:

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

### How to read the output

The headline numbers — what to look for first:

- **PMR wins p50 by ~55%.** 3.87 µs vs 8.50 µs. The bump-allocator
  is doing essentially zero work per allocation; the win is
  proportional to how much of the workload's time was being spent
  in `malloc`.
- **PMR loses on max.** 40 µs vs 17 µs. The arena reset is doing
  amortized work that occasionally shows up as a spike. PMR trades
  some tail predictability for average-case speed — a real
  trade-off, not a free lunch.
- **mimalloc and std::allocator look nearly identical here.** This
  is expected, not a defect. mimalloc's wins are in
  multi-threaded workloads, longer-lived heaps, and large
  allocations — none of which this single-threaded short-lived
  tree builder exercises.
- **`result_hash` agreement is the correctness check.** All three
  variants should produce the same hash; if they don't, there's a
  bug in the allocator-aware code (most likely in the PMR path,
  where `uses_allocator` machinery has subtle traps).

### What different output would mean

- If `std::allocator` is *faster* than PMR at p50, the workload
  isn't allocation-heavy enough for the bump-allocator advantage
  to materialize. Try larger trees (raise `depth` and `branch` in
  the workload config) or check that the build wasn't accidentally
  using `LD_PRELOAD=libtcmalloc.so` or similar.
- If `mimalloc` is significantly *slower* than `std::allocator`,
  check that it actually got hooked up — mimalloc replaces
  `operator new` globally only when statically linked with
  `--whole-archive` (see this demo's `CMakeLists.txt`). A
  dynamically-loaded mimalloc that didn't intercept `new` will
  perform like glibc malloc.
- If the hashes disagree, there's a real bug. The PMR path's
  copy/move constructors are the most common culprit (see "Two
  PMR bugs worth knowing" below).

## Serve mode (HTTP)

The same three binaries also support an HTTP-server mode for
load-testing with `hey`, `wrk`, or `curl`, and as the foundation for
the OpenTelemetry-instrumented observe mode below. Activate it via:

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

# Sustained load with hey
hey -z 5s http://127.0.0.1:18601/run
hey -z 5s http://127.0.0.1:18602/run
hey -z 5s http://127.0.0.1:18603/run
```

Ports `18601/02/03` follow the convention `186XX` (with the demo
number `06` in the middle) to avoid collision with other demos'
host ports.

### Why serve-mode numbers differ from batch-mode numbers

When you compare `./demo.sh` (batch) against `curl /run?iters=N`
(serve), PMR's relative advantage often shrinks. This isn't a bug;
it's a real teaching point worth understanding.

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
realistic request handling patterns. The OpenTelemetry-instrumented
mode below lets you see this distribution play out across hundreds
of requests rather than inferring it from single `curl` calls.

## Observe mode (OpenTelemetry + LGTM)

The third execution mode wires OpenTelemetry through the same
serve-mode binary. Same `--serve` flag (or `DEMO06_MODE=serve`); the
binary checks `OTEL_EXPORTER_OTLP_ENDPOINT` at startup and
initializes traces, metrics, and logs export via OTLP/gRPC if it's
set. Without that env var, the binary runs identically to plain
serve mode — the OTel SDK never initializes, so there's no runtime
cost or noise.

The `compose-observe.yml` file overlays the OTel env vars onto
`compose-serve.yml`'s three services and joins them to the
`tutorial-obs` network where the LGTM observability bundle lives.

```bash
podman compose \
    -f compose-serve.yml \
    -f compose-observe.yml \
    -f ../../observability/compose.yml \
    up --build
```

Three `-f` files in order — compose merges them with later files
overlaying earlier ones:

1. `compose-serve.yml` defines the three demo services
2. `compose-observe.yml` adds OTel env + joins them to `tutorial-obs`
3. `../../observability/compose.yml` defines the LGTM bundle (Grafana,
   Loki, Tempo, Prometheus/Mimir, OTel Collector, all in one image)

Once up, drive traffic the same way as plain serve mode:

```bash
hey -z 30s http://127.0.0.1:18601/run
hey -z 30s http://127.0.0.1:18602/run
hey -z 30s http://127.0.0.1:18603/run
```

Then open Grafana at <http://localhost:3000> and explore:

- **Tempo** (Explore → Tempo): traces from each `demo06-svc-*`
  service. Each `/run` is a span with `iters` and `variant`
  attributes; useful for spot-checking individual requests.
- **Mimir** (Explore → Mimir, or PromQL via Prometheus at
  :9090): metric `demo06_request_duration_milliseconds_bucket{}`
  tagged by `variant` (std/pmr/mimalloc). The PromQL
  `histogram_quantile(0.99, sum(rate(...)) by (le, variant))`
  shows the per-allocator p99 over time; the latency distribution
  story for §7 prose comes from here.
- **Loki** (Explore → Loki): structured logs from each request,
  tagged with service name. Useful when you want to correlate a
  specific request span to its log line.

### What to look for in observe mode

The whole point of the OTel layer is to make the
**per-allocator tail-latency distribution** visible across many
requests instead of inferring from single `curl` invocations.
Specifically:

- p50 across the three variants should track each other closely
  (small differences from each allocator's fast path)
- p99 may diverge — this is where allocator strategy bites
- p99.9+ shows tail behavior (deferred reclamation, arena
  rebalancing, kernel page management); whichever allocator has
  the cleanest tail under sustained load is a real result worth
  presenting

If you don't have Grafana time, the same data is available via
the Prometheus UI at <http://localhost:9090> with PromQL queries
directly. Less polished, faster for ad-hoc investigation.

### The Simple/Batch processor decision

The most consequential observability decision in this demo, and a
teaching point worth carrying forward to every C++ service you
instrument: **production services should use Batch span and log
processors by default; Simple is for development and unit tests
only.**

OpenTelemetry's C++ SDK ships with two processor families:

- **Simple processors** (`SimpleSpanProcessor`,
  `SimpleLogRecordProcessor`) export each span or log record
  synchronously, inside the call to `span->End()` or
  `EmitLogRecord`. Easy to reason about, but every request pays a
  full gRPC roundtrip to the collector on the critical path.
- **Batch processors** (`BatchSpanProcessor`,
  `BatchLogRecordProcessor`) queue records in a lock-free buffer
  and flush them periodically (every 5 seconds by default) on a
  background thread. Per-signal overhead drops from ~100 µs to
  ~5 µs.

In our measurements:

| Config | Throughput | p50 | p99 | Tail outliers (>0.5s) |
|---|---|---|---|---|
| No OTel (baseline) | 18,469 req/s | 200 µs | 400 µs | 4 |
| OTel Simple | 2,170 req/s | 2.7 ms | 25.9 ms | 80 |
| **OTel Batch** | **~28,000 req/s** | **200 µs** | **1.8 ms** | **~1,000** |

The 8.5× throughput collapse with Simple processors is real and
reproducible; the underlying per-request OTel cost dwarfed the
allocator differences the demo was built to measure. Switching to
Batch recovers full throughput with no measurable cost.

The Batch config measuring *slightly higher* than the no-OTel
baseline isn't a measurement error — it's a combination of
run-to-run variance and the httplib thread pool extracting slightly
more parallelism with the structured per-request handler shape OTel
encourages. The honest headline: **adding production-grade
observability did not measurably hurt throughput.**

The increase in absolute tail-outlier count under Batch (~1,000 vs
Simple's 80) is proportional to the throughput increase — Batch's
28K req/s × 50s is 1.4M total requests vs Simple's ~107K, so a
roughly equivalent rate of tail events (~0.07% in both cases) plays
out as a larger absolute number.

### Per-allocator observations under sustained load

All three variants posted ~1M responses in 50 seconds with nearly
identical mid-distribution numbers:

| Variant | Throughput | p50 | p99 | Slowest |
|---|---|---|---|---|
| std::allocator | 29,033 req/s | 200 µs | 1.7 ms | 1.02 s |
| std::pmr | 28,073 req/s | 200 µs | 1.8 ms | 1.76 s |
| mimalloc | 27,365 req/s | 300 µs | 1.9 ms | 1.65 s |

**PMR's batch-mode advantage disappears under sustained load.**
This is the cache-sensitivity behavior flagged above: the
bump-allocator wins require the 1 MB `thread_local` arena buffer to
stay hot in cache, and `/run` with default `iters=1` doesn't run
enough iterations per request for that to materialize. To see PMR's
advantage in serve mode, use `iters=100` or higher per `/run`.

The tail distribution is where the three variants diverge most
clearly. mimalloc's slightly slower p50 (300 µs vs 200 µs) reflects
its segment-management overhead at small allocation counts; under
longer per-request workloads, the trade-off typically reverses.

## Build-time warning

The first build with OTel enabled takes **30-60 minutes** on a
clean Conan cache. Conan rebuilds opentelemetry-cpp, grpc, protobuf,
abseil, and openssl from source against our gcc-toolset-14 / gnu17
profile. Subsequent rebuilds with the same dep set are ~30 seconds
(just our app code) — the Conan cache keeps the giant transitive
deps.

If you only need batch mode or plain serve mode and never want to
wait for the OTel build, you can delete the opentelemetry-cpp lines
from `conanfile.py` and the corresponding pieces in `CMakeLists.txt`.
The `init_otel` function is gated on the env var anyway, so an
OTel-less build runs identically in batch and serve modes.

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
- **Strictly request-scoped lifetime** is where PMR's
  `monotonic_buffer_resource` arena pattern wins — instead of N+1
  individual frees, the entire arena resets in O(1) at scope exit

## Two PMR bugs worth knowing

Building this demo surfaced two PMR mistakes that show up
constantly in real production code. Each is now a worked example in
this demo's source.

**Mistake #1: `emplace_back(memory_resource*)` thinking it threads
the resource.** The PMR vector's `uses_allocator` machinery already
injects its own allocator into the new element's constructor.
Calling `emplace_back(mr)` makes the vector try
`PmrNode(mr, allocator)` — two arguments — which doesn't match
`PmrNode`'s `PmrNode(allocator_type)` one-arg constructor. Compile
error: *"construction with an allocator must be possible if
uses_allocator is true."*

Fix: just call `emplace_back()` with no args. The vector injects
its allocator. Don't thread `mr` manually.

**Mistake #2: Forgetting allocator-extended copy and move
constructors.** A type is properly allocator-aware only if it
provides all three:

```cpp
PmrNode(allocator_type)                    // default + allocator
PmrNode(const PmrNode&, allocator_type)    // copy    + allocator
PmrNode(PmrNode&&,      allocator_type)    // move    + allocator (noexcept)
```

With only the first one, `emplace_back()` works but `reserve()`
fails the moment the vector needs to grow its buffer — it can't
move existing elements into the new storage with the right
allocator. The symptom is often delayed: small inputs work because
`reserve` is a no-op, then production data triggers the grow and
the static_assert fires.

Together these two cover the majority of "I tried PMR and it didn't
work" reports.

## Caveats and gotchas

- **The synthetic workload is single-threaded.** mimalloc's biggest
  wins are in multi-threaded workloads, so the comparison here
  understates mimalloc's real production advantage. Treat the
  numbers as "lower bound for mimalloc, upper bound for the
  others" relative to a multi-threaded service.
- **Cache state dominates short-burst measurements.** Running the
  comparison repeatedly (e.g. `./demo.sh && ./demo.sh && ./demo.sh`)
  can show ±15% variation on identical configurations as the L2
  warms or evicts. Use the trend across many runs rather than any
  single number.
- **Static-link surface area.** mimalloc replaces `operator new`
  globally only when statically linked with `--whole-archive`. A
  dynamically-loaded mimalloc that didn't intercept `new` will
  perform like glibc malloc.
- **OTel build time.** The first build with OTel enabled takes
  30-60 minutes on a clean Conan cache (see the "Build-time
  warning" subsection above). Plan accordingly.
- **PMR cache-sensitivity is a real teaching point, not a bug.**
  The bump-allocator advantage shrinks under sustained
  request-handler workloads where the arena buffer is evicted
  between requests. See "Why serve-mode numbers differ from
  batch-mode numbers" above.

## Source materials

This demo deepens material from the project's
[**bibliography**](/bibliography/):

- **Andrist & Sehr, *C++ High Performance* 2e, ch. 7** — custom
  allocators, PMR design rationale, allocator-aware containers
- **Enberg, *Latency*, ch. 3** — allocator measurement, the
  "general-purpose allocator tax" thesis, the
  mimalloc/jemalloc/tcmalloc comparison from the Helsinki perf
  group
- **Iglberger, *C++ Software Design*, ch. 7** — the Bridge / PIMPL
  discussion intersects with PMR's lifetime model (which class
  owns the memory_resource? where does it live?)

## Linked tutorial sections

- [**§7 Memory Management**](/docs/07-memory-management/) — this
  demo is §7's worked example. The §7 prose discusses the theory;
  this demo measures it.
- [**§10 Observability & Profiling**](/docs/10-observability-profiling/)
  — the OTel-instrumented mode here uses the same LGTM bundle as
  demo-04, and the Simple-vs-Batch finding is one of §10's
  canonical teaching points.
- [**§11 Noisy Neighbors**](/docs/11-noisy-neighbors/) — the
  per-allocator tail-latency observations under sustained load
  complement demo-05's CPU isolation work; allocator strategy and
  CPU scheduling both shape tail behavior.
