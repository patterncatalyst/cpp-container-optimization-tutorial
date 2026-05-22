# statelessness/10-grpc-microservices — the gRPC capstone

Compendium reference:
[Doc 10 — Microservices with gRPC and C++](../../../reference/statelessness/10-grpc-microservices/)

The integration example. The previous examples each established one pattern
in isolation; this one composes them into a single realistic gRPC service —
an **order-pricing service** — so the way the pieces fit together is
visible end to end.

`PriceOrder` takes a customer and line items, looks the customer up in
PostgreSQL, prices each item, calls a **separate tax service over gRPC**,
and returns a fully-priced order. It is idempotent on a client-supplied
key, and it propagates the request deadline through every downstream call.

## What it composes

**`Config` parsed once** ([`src/config.hpp`](src/config.hpp), Doc 06). Env
read once in `main()` into an immutable struct, passed by `const&`. No
`getenv` anywhere else.

**Process-scoped state owned by `main()`** ([`src/pricing_svc.cpp`](src/pricing_svc.cpp),
Doc 04). The `PgPool` (07's verified libpq pool) and the `ChannelCache`
([`src/channel_cache.hpp`](src/channel_cache.hpp)) are constructed once and
shared across request threads. gRPC channels are expensive to build and
cheap to reuse — classic process scope.

**A per-request RAII bundle** ([`src/request_context.hpp`](src/request_context.hpp),
Doc 02/03). `RequestContext` carries a real PMR arena (the verified 03
pattern), the request deadline, and the correlation id. Per-request
`pmr::vector`s allocate from the arena; the whole arena is reclaimed at
once when the context destructs.

**A handler that throws `grpc::Status`, cleans up via RAII**
(Doc 02). Helpers throw `grpc::Status` for protocol errors (deadline
exceeded, unavailable, not found) and `std::exception` for bugs; the
handler boundary translates both to the wire status. No manual cleanup —
the connection returns to the pool through `ScopedConnection`'s destructor
regardless of path.

**Backing services with deadline propagation** (Doc 07). `fetch_customer`
and `fetch_price` check out a pooled libpq connection and set
`statement_timeout` from the remaining request budget; `compute_tax` calls
the tax service over gRPC with the *same* deadline, through the channel
cache. A blown deadline anywhere surfaces as `DEADLINE_EXCEEDED`.

**Staged startup + graceful shutdown** (Doc 09). The server comes up
`NOT_SERVING`, runs migrations, then flips to `SERVING`. SIGTERM flips
readiness `NOT_SERVING`, then `server->Shutdown(deadline)` drains in-flight
RPCs, then reverse-order teardown, exit 0 — the signal-safe sequence from
09 (handler sets a flag; a control thread does the work).

## Divergences from Doc 10 (to stay on the verified stack)

The doc's literal feature set pulls in several dependencies this tutorial
has either rejected or never built. To keep the *capstone* buildable and
green, each is represented structurally rather than wired, and called out
here — the architecture and composition are identical, only the realized
backends differ:

- **PostgreSQL via libpq, not libpqxx.** libpqxx's bundled CMake breaks
  this toolchain (gotcha G-67); 07 already pivoted to libpq, and this reuses
  that verified `pg_pool.hpp`. The doc's `pqxx::work` becomes `PQexecParams`.
- **No Redis.** The doc caches prices in Redis with a PG fallback; here the
  price lookup goes straight to PostgreSQL. The cache-aside *seam* is marked
  in `fetch_price` where a Redis GET would slot in.
- **No OpenTelemetry.** Every example in this tutorial deliberately stays on
  the verified gRPC trio. The `RequestContext`'s span/scope is a documented
  seam (see [`request_context.hpp`](src/request_context.hpp)), not a built
  dependency. The RAII shape is identical; adding a real `TracerProvider` is
  mechanical.
- **sync gRPC API, not the callback API.** The doc sketches the callback
  API (`CallbackServerContext`, `ServerUnaryReactor`); this uses the sync
  API verified in 07 and 09. The composition is identical; the callback (and
  coroutine) migration is mechanical (Doc 05).
- **No jemalloc arena tuning.** The doc sets `MALLOC_CONF` from the CPU
  budget; omitted here as orthogonal to the composition story.

## Run it

```bash
podman compose -f compose.yml up --build   # or: ./demo.sh
./demo.sh                                   # the three acts
./demo.sh --keep                            # leave the stack up
./demo.sh --clean                           # tear down
```

The first build compiles the gRPC chain (~5 min cold); a warm Conan cache
is far faster. The demo drives `PriceOrder` with the in-image
`pricing-client` via `podman exec` — no host gRPC tooling needed.

## The three acts

1. **Price an order** for `alice` (US, taxable): the handler reads alice +
   product prices from PostgreSQL, then calls the tax service over gRPC for
   the tax. Returns subtotal, tax, total.
2. **Tax-exempt path** for `carol` (US, `tax_exempt`): the handler returns
   `tax=0` *without* calling the tax service — a branch in `compute_tax`,
   showing the outbound call is conditional.
3. **Idempotent replay**: re-sending act 1's key returns the stored result
   (same `order_id`) without recomputing — the idempotency store from Doc 07.

## Files

| Path | Role |
|---|---|
| [`proto/pricing.proto`](proto/pricing.proto) | the capstone API (`pricing.v1.Pricing`) |
| [`proto/tax.proto`](proto/tax.proto) | the outbound upstream (`tax.v1.TaxService`) |
| [`proto/health.proto`](proto/health.proto) | standard `grpc.health.v1` (for the probe) |
| [`src/config.hpp`](src/config.hpp) | env-time `Config` (Doc 06) |
| [`src/channel_cache.hpp`](src/channel_cache.hpp) | process-scoped gRPC channel cache (Doc 04) |
| [`src/request_context.hpp`](src/request_context.hpp) | per-request RAII + PMR arena (Doc 02/03) |
| [`src/pg_pool.hpp`](src/pg_pool.hpp) | 07's verified libpq pool (Doc 07) |
| [`src/pricing_svc.cpp`](src/pricing_svc.cpp) | the capstone: handler, helpers, `main()` |
| [`src/tax_svc.cpp`](src/tax_svc.cpp) | the outbound tax upstream |
| [`src/pricing_client.cpp`](src/pricing_client.cpp) | drives `PriceOrder` for the demo |
| [`src/health_probe.cpp`](src/health_probe.cpp) | our minimal `grpc_health_probe` |
| [`CMakeLists.txt`](CMakeLists.txt) | codegen 3 protos; build 4 binaries |
| [`conanfile.py`](conanfile.py) | the gRPC trio (libpq is system) |
| [`Containerfile`](Containerfile) | gRPC-trio + libpq builder; `ubi-minimal` + libpq runtime |
| [`compose.yml`](compose.yml) | postgres + tax-svc + pricing-svc |
| [`demo.sh`](demo.sh) | the three acts |
