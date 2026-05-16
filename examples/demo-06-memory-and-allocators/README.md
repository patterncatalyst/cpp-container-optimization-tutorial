# Demo 06 — Memory Management & Allocators

Four allocator variants of the same C++23 binary, side-by-side on a
synthetic JSON-shaped allocator-stress workload:

| Variant | Allocator | How it's hooked up |
|---|---|---|
| `demo06-svc-std` | default glibc malloc | `std::allocator<T>` |
| `demo06-svc-pmr` | `std::pmr::monotonic_buffer_resource` + sync_pool fallback | `std::pmr::polymorphic_allocator<T>` |
| `demo06-svc-mimalloc` | mimalloc 2.x | static-linked, global new/delete replacement |
| `demo06-svc-jemalloc` | jemalloc 5.x | static-linked, global new/delete replacement |

The workload is **synthetic** — it allocates the way a JSON parser
would (many small strings, mixed-size nested vectors, request-scoped
lifetime) without depending on any actual JSON library. This keeps
the comparison about allocator behavior rather than parser
optimization.

## Run it

```bash
./demo.sh
```

First build is ~10-15 minutes on a clean cache (mimalloc and
jemalloc both rebuild from source under our gcc-toolset-14 profile).
Cached: ~30 seconds (just our app code).

Output: a comparison table.

```
==> Comparison table

Variant                            min µs     p50 µs     p99 µs     max µs    throughput/s   result_hash
────────────────────────────────  ──────────  ──────────  ──────────  ──────────  ───────────────   ──────────────────
std::allocator                     ... µs     ... µs     ... µs     ... µs        ...K     0x...
std::pmr (monotonic+sync_pool)     ... µs     ... µs     ... µs     ... µs        ...K     0x...
mimalloc                           ... µs     ... µs     ... µs     ... µs        ...K     0x...
jemalloc                           ... µs     ... µs     ... µs     ... µs        ...K     0x...

==> Sanity: all variants produced the same hash (0x...)
```

The `result_hash` agreement is the correctness check: the workload
is supposed to produce identical output regardless of which allocator
is used. Allocator choice should be invisible at the application
layer; if hashes diverge, there's a bug in the PMR path (the most
likely place for type subtleties to creep in).

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

This demo is being built incrementally. r71 is the toolchain proof;
the full LGTM-wired, multi-layered version lands across r72-r74.

| Round | What's in | Status |
|---|---|---|
| **r71** | 4-way binary build, workload, demo.sh comparison | shipped (current) |
| r72 | HTTP server entry point + OTel traces/metrics/logs → LGTM | planned |
| r73 | Layer toggles: `HUGE_PAGES`, cgroup `memory.high`, `THREADS` | planned |
| r74+ | Verify all 4×3 combinations; document findings in §7 prose | planned |

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
