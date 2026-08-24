---
title: "Statelessness 04 — Process-scoped state"
description: "The runnable companion to compendium Doc 04: the composition root in main(), dependency injection by reference, a bounded LRU cache sized against the cgroup budget, and correct reverse-order teardown for free from RAII."
order: 204
card_eyebrow: "Compendium · <strong>Doc 04</strong>"
card_title: "Process-scoped state"
card_blurb: "The composition root in main(), dependency injection by reference, a bounded LRU cache sized against the cgroup budget, and correct reverse-order teardown for free from RAII."
layout: example
sectionid: examples
permalink: /examples/statelessness-04-process-scoped-state/
demo_dir: statelessness/04-process-scoped-state
github_path: examples/statelessness/04-process-scoped-state
---

> The full source for this example lives in [`examples/statelessness/04-process-scoped-state/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/statelessness/04-process-scoped-state) — clone the repo, `cd` in, and `./demo.sh`.

Compendium reference:
[Doc 04 — Process-scoped state and the State Architecture Table]({{ '/reference/statelessness/04-process-scoped-state/' | relative_url }})

Tutorial sections:
[§3 RAII & Container Resource Discipline]({{ '/docs/03-raii-discipline/' | relative_url }}) +
[§7 Memory Management]({{ '/docs/07-memory-management/' | relative_url }})

Not all state is request-scoped. A service holds a parsed config, a metrics
registry, a connection pool, an in-process cache — built once and shared
across every request. Doc 04 calls this *process-scoped* state and argues
for wiring it in `main()` rather than reaching for singletons. This example
makes that wiring, and the correct-teardown property that falls out of it,
visible.

## Why this matters

Process-scoped state is legitimate — pools and caches and parsed config
*should* live for the process. The question is how you own it, and under
containers the wrong answer is expensive:

- **Singletons hide ownership and the OOM.** A Meyers singleton works on a
  dedicated box; under a memory cgroup it becomes an unbounded growth you
  can't see in `main()` and can't size against the limit. The composition
  root makes the entire process-scoped footprint legible in one place.
- **Bounded-by-construction is the difference between an eviction and an
  OOMKill.** An unbounded `unordered_map` keyed on request input is the
  classic "works in test, killed in prod" bug. A cache sized against the
  cgroup budget evicts predictably instead of growing into the limit.
- **Teardown order matters and should be free.** A service that tears down
  its connection pool before the server that's still using it crashes on
  shutdown. Constructing dependencies before their users means RAII
  destroys them in the correct reverse order automatically — no shutdown
  choreography to get wrong.

## What this demo shows

**The composition root** (`src/main.cpp`). `main()` constructs every piece
of process-scoped state by name, in dependency order, and injects it into
the service by reference:

```
config → metrics → cache → service → server
```

Each object logs on construction, so the startup output shows the build
order. No Meyers singletons, no hidden construction order.

**Dependency injection, not global lookup.** The service receives
`const ServiceConfig&`, `MetricsRegistry&`, and `BoundedCache&` as
constructor parameters. `main()` owns them; the service borrows them.

**Correct teardown for free.** Dependencies are constructed before their
users, so RAII destroys them in the exact reverse order at exit —
`server → service → cache → metrics → config` — which is also the correct
shutdown order (server stops first, then the state it relied on). No manual
choreography; each destructor logs, so the order is visible when you stop
the container.

**Bounded state.** The cache is an LRU with a hard capacity
(`CACHE_CAPACITY`, default 4). Look up more distinct keys than it holds and
it evicts the least-recently-used entry rather than growing — the sizing
discipline Doc 04 stresses.

**Thread-safe shared state** (foreshadows the threading section): the
shared cache takes a mutex, the metrics are atomic, the immutable config
needs neither.

## How to run

```bash
cd examples/statelessness/04-process-scoped-state
./demo.sh            # composition root + eviction + teardown
./demo.sh --keep     # leave the service running afterward
./demo.sh --clean    # tear down
```

Reuses the same gRPC chain as the other compendium examples, so a warm
Conan cache on the host makes the build fast. No AddressSanitizer here, so
it's lighter than the PMR example.

CI verification: `scripts/test-stateless-demo-04-process-scoped-state.sh`.

## What you'll see

Representative output on a Fedora 44 host with GCC 14 and Podman
5.x — the build order at startup, an eviction under a capacity of 4, then
the reverse-order teardown on stop:

```
==> startup (composition root, construction order)
[ctor] ServiceConfig    (cache_capacity=4)
[ctor] MetricsRegistry
[ctor] BoundedCache      (capacity=4)
[ctor] StateServiceImpl  (deps injected by reference)
[ctor] gRPC server       listening on 0.0.0.0:50051

==> lookups (cache capacity = 4)
    lookup a -> miss, computed, cached     (size=1)
    lookup b -> miss, computed, cached     (size=2)
    lookup c -> miss, computed, cached     (size=3)
    lookup d -> miss, computed, cached     (size=4)
    lookup e -> miss, computed, cached     (size=4, evicted LRU 'a')
    lookup a -> miss again (was evicted)   (size=4, evicted LRU 'b')

==> stats
    lookups=6  hits=0  misses=6  evictions=2  cache_size=4

==> teardown (SIGTERM -> reverse-order destruction)
[dtor] gRPC server       (stopped; no new RPCs)
[dtor] StateServiceImpl
[dtor] BoundedCache       (4 entries dropped)
[dtor] MetricsRegistry
[dtor] ServiceConfig
    exit 0
```

## How to read the output

- **Construction order top-down, destruction order bottom-up.** The `[ctor]`
  block and the `[dtor]` block are exact mirrors. That mirroring is the
  whole point: you wrote the order *once*, in `main()`, and RAII gave you
  the correct teardown for free.
- **The cache size never exceeds 4.** Once full, every new distinct key
  evicts the least-recently-used one. The `size=4` that holds steady while
  `evictions` climbs is the bounded-by-construction property — under a
  memory cgroup that's the line between a predictable eviction and an
  OOMKill.
- **`a` misses again after eviction.** It was the least-recently-used when
  `e` arrived, so it's gone; looking it up again is a fresh miss. That's the
  LRU policy doing its job, not a bug.
- **The server destructs first.** On the teardown side the server stops
  before the cache and config it depended on — so no in-flight RPC can touch
  freed state. Reverse-order destruction makes that ordering automatic.

## Files

- `src/composition.hpp` — `ServiceConfig`, `MetricsRegistry`, and the LRU
  `BoundedCache` (the process-scoped types)
- `src/main.cpp` — the composition root, the DI service, and a healthz
- `src/client.cpp` — one-shot client (`lookup` | `stats`)
- `proto/state.proto` — `StateService`: `Lookup` + `Stats`
- `CMakeLists.txt` — svc + client
- `conanfile.py` — gRPC + protobuf + abseil (no OTel)
- `Containerfile` — multi-stage UBI 10 → ubi-minimal
- `compose.yml` — single service; read-only rootfs + tmpfs
- `demo.sh` — build, bring up, drive lookups + stats, show teardown

## Caveats and gotchas

- **Construct dependencies before their users — always.** The reverse-order
  teardown property only holds if construction order is dependency order. If
  you construct the server before the cache it uses, the cache destructs
  first and the server's shutdown touches freed memory.
- **The cache capacity is a stand-in for cgroup-derived sizing.** Default 4
  is small so eviction is visible in the demo. In a real service, size
  process-scoped caches against `memory.max` (the reader is in the
  [build-tooling example]({{ '/examples/statelessness-11-build-tooling/' | relative_url }})),
  not against host RAM.
- **Shared mutable state needs synchronisation.** gRPC dispatches handlers
  on a thread pool, so the cache takes a mutex and the metrics are atomic.
  Immutable config needs neither — which is a reason to prefer immutable
  process-scoped state where you can.
- **Don't reach for the singleton "just this once."** The moment one
  collaborator is a global, the composition root stops being the single
  source of truth for the lifetime graph, and the teardown guarantee
  weakens. Inject by reference.

## Source materials

This example deepens material from the project's
[**bibliography**]({{ '/bibliography/' | relative_url }}):

- **Iglberger, *C++ Software Design*, ch. 3-4** — dependency injection and
  the case against singletons; the composition-root pattern is this
  section's chapter applied
- **Andrist & Sehr, *C++ High Performance* 2e, ch. 3** — object lifetime and
  the reverse-order destruction guarantee the teardown relies on
- **Enberg, *Latency*, ch. 5** — why bounded, predictable resource use beats
  unbounded caching when latency under a hard memory limit is the goal

## Linked tutorial sections

- [**§3 RAII & Container Resource Discipline**]({{ '/docs/03-raii-discipline/' | relative_url }}) —
  the reverse-order destruction that gives this example correct teardown for
  free is the same RAII discipline the section develops, applied at process
  scope rather than request scope.
- [**§7 Memory Management**]({{ '/docs/07-memory-management/' | relative_url }}) —
  bounding process-scoped state against the cgroup memory limit; the LRU
  cache here is the "bounded by construction" rule from that section.

## The State Architecture Table, made concrete

| Column | In this example |
|--------|-----------------|
| Process-scoped | `ServiceConfig`, `MetricsRegistry`, `BoundedCache` — built in `main()` |
| Request-scoped | per-`Lookup` locals (see [02-raii]({{ '/examples/statelessness-02-raii/' | relative_url }}) and [03-pmr]({{ '/examples/statelessness-03-pmr/' | relative_url }})) |
| External | the cache-miss path stands in for a DB/Redis fetch — the real thing is [Doc 07]({{ '/reference/statelessness/07-state-externalization/' | relative_url }}) |

## Where it sits in the compendium

The composition root owns the lease pool that
[Doc 02]({{ '/examples/statelessness-02-raii/' | relative_url }}) leases
from, holds the request-scoped work from
[Doc 03]({{ '/examples/statelessness-03-pmr/' | relative_url }}) at arm's
length, and is where the real connection pool and channel cache from
[Doc 07]({{ '/reference/statelessness/07-state-externalization/' | relative_url }})
get constructed. The capstone
([Doc 10]({{ '/reference/statelessness/10-grpc-microservices/' | relative_url }}))
is one big composition root.
