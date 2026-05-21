# statelessness/04-process-scoped-state — the composition root

Compendium reference:
[Doc 04 — Process-scoped state and the State Architecture Table](../../../reference/statelessness/04-process-scoped-state/)

The runnable companion to compendium Doc 04. Not all state is
request-scoped: a service holds a parsed config, a metrics registry, a
connection pool, an in-process cache — things built once and shared
across every request. Doc 04 calls this *process-scoped* state and
argues for wiring it in `main()` (a composition root) rather than
reaching for singletons. This example makes that wiring, and the
correct-teardown property that falls out of it, visible.

## What it demonstrates

**The composition root** ([`src/main.cpp`](src/main.cpp)). `main()`
constructs every piece of process-scoped state by name, in dependency
order, and injects it into the service by reference:

```
config → metrics → cache → service → server
```

Each object logs on construction, so the startup output literally shows
the build order. There are no Meyers singletons and no hidden
construction order.

**Dependency injection, not global lookup.** `StateServiceImpl` receives
`const ServiceConfig&`, `MetricsRegistry&`, and `BoundedCache&` as
constructor parameters and reaches them through members. `main()` owns
them; the service borrows them.

**Correct teardown for free.** Because dependencies are constructed
before the things that use them, RAII destroys them in the exact reverse
order at process exit — `server → service → cache → metrics → config` —
which is *also* the correct shutdown order: the server stops first (so
no new RPCs arrive), then the state it relied on. No manual shutdown
choreography. Each destructor logs, so the teardown order is visible
when you stop the container.

**Bounded state** ([`src/composition.hpp`](src/composition.hpp)). The
cache is an LRU with a hard capacity (`CACHE_CAPACITY`, default 4). Look
up more distinct keys than it holds and it evicts the least-recently-used
entry rather than growing. This is the sizing discipline Doc 04 stresses:
process-scoped memory must be bounded against the container's cgroup
limit. An unbounded `std::unordered_map` keyed on request input is the
classic "works in test, OOM-killed in prod" bug.

**Thread-safe shared state** (foreshadows Doc 05). gRPC runs handlers on
a thread pool, so the shared mutable cache takes a mutex and the metrics
are atomic. The immutable config needs neither.

## Running it

```bash
./demo.sh            # build + composition root + eviction + teardown
./demo.sh --keep     # leave the service running
./demo.sh --clean    # tear down
```

CI verification: `../../../scripts/test-stateless-demo-04-process-scoped-state.sh`.

Reuses the same gRPC chain as the other compendium examples, so a warm
Conan cache on the host makes the build fast. No AddressSanitizer here,
so it's lighter than 03-pmr.

## Layout

```
04-process-scoped-state/
├── proto/state.proto       StateService: Lookup + Stats
├── src/composition.hpp     ServiceConfig, MetricsRegistry, BoundedCache (LRU)
├── src/main.cpp            the composition root + DI service + healthz
├── src/client.cpp          one-shot client (lookup | stats)
├── CMakeLists.txt          svc + client
├── conanfile.py            gRPC + protobuf + abseil (no OTel)
├── conan.lock              empty placeholder
├── Containerfile           multi-stage UBI 9 → ubi-minimal
├── compose.yml             single service; read-only rootfs + tmpfs
└── demo.sh                 the driver
```

## The State Architecture Table, made concrete

| Column | In this example |
|--------|-----------------|
| Process-scoped | `ServiceConfig`, `MetricsRegistry`, `BoundedCache` — built in `main()` |
| Request-scoped | per-`Lookup` locals (see [02-raii](../02-raii/) and [03-pmr](../03-pmr/)) |
| External | the cache-miss "compute" path stands in for a DB/Redis fetch — the real thing is [07-state-externalization](../07-state-externalization/) |
