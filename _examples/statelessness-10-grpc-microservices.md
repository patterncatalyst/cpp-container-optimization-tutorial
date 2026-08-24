---
title: "Statelessness 10 — gRPC microservices (capstone)"
description: "The runnable companion to compendium Doc 10: an order-pricing gRPC service that composes every prior pattern — Config parsed once, process-scoped PgPool and channel cache, a per-request RAII bundle with a PMR arena, deadline-propagating PostgreSQL and outbound-gRPC helpers, idempotency, and the staged health/graceful-shutdown sequence — calling a second tax service over gRPC end to end."
order: 211
card_eyebrow: "Compendium · <strong>Doc 10</strong>"
card_title: "gRPC microservices (capstone)"
card_blurb: "The integration example: an order-pricing service composing every prior pattern — Config, process-scoped pools and a channel cache, a per-request PMR arena, deadline-propagated PostgreSQL and an outbound gRPC tax call, idempotency, and the staged health/shutdown sequence."
layout: example
sectionid: examples
permalink: /examples/statelessness-10-grpc-microservices/
demo_dir: statelessness/10-grpc-microservices
github_path: examples/statelessness/10-grpc-microservices
---

> The full source for this example lives in [`examples/statelessness/10-grpc-microservices/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/statelessness/10-grpc-microservices) — clone the repo, `cd` in, and `./demo.sh`.

Compendium reference:
[Doc 10 — Microservices with gRPC and C++]({{ '/reference/statelessness/10-grpc-microservices/' | relative_url }})

Tutorial sections:
[§8 I/O Latency]({{ '/docs/08-io-latency/' | relative_url }}) +
[§9 Networking & Kernel Parameters]({{ '/docs/09-networking-kernel/' | relative_url }})

This is the integration example. The earlier examples each established one
pattern in isolation; this one composes them into a single realistic gRPC
service — an order-pricing service — so the way the pieces fit together is
visible end to end. `PriceOrder` looks a customer up in PostgreSQL, prices
each line item, calls a **separate tax service over gRPC**, and returns a
fully-priced order, idempotent on a client key and with the request deadline
propagated through every downstream call.

## Why this matters

Each prior example proved a pattern alone. The real question — the one a team
actually faces — is whether those patterns *compose* without fighting each
other, and this capstone answers it:

- **Composition is where abstractions leak.** RAII request scope, a PMR
  arena, process-scoped pools, deadline propagation, idempotency, and
  graceful shutdown each work in isolation; the value here is showing they
  stack into one `main()` and one handler without friction.
- **A second service makes the deadline story real.** An outbound gRPC call
  to a tax service is what turns "propagate the deadline" from a slogan into
  a visible budget that flows from the client through PostgreSQL and out to
  another service.
- **This is the shape every service in the stack takes.** The twelve-step
  `main()` and the throw-and-translate handler are reusable; new services
  swap the business logic and keep the wiring. The capstone is the template.

## What it composes

Every block maps back to an earlier document:

- **`Config` parsed once** in `main()`, passed by `const&` (the 12-factor
  config pattern).
- **Process-scoped state** — the `PgPool` and a `ChannelCache` — constructed
  once in `main()` and shared across request threads (process scope). gRPC
  channels are expensive to build and cheap to reuse, so they live for the
  process.
- **A per-request RAII bundle**, `RequestContext`, carrying a real PMR arena
  (RAII + PMR). Per-request allocations come from the arena and are reclaimed
  wholesale when the context destructs.
- **A handler that throws `grpc::Status`** for protocol errors and relies on
  RAII for all cleanup; the boundary translates errors to the wire status.
- **Deadline-propagating backing-service calls** (state externalization):
  PostgreSQL via a pooled libpq connection with `statement_timeout` set from
  the remaining budget, and an outbound gRPC tax call carrying the same
  deadline through the channel cache.
- **Staged startup and graceful shutdown** (health & shutdown): up
  `NOT_SERVING`, migrate, flip to `SERVING`; on SIGTERM, readiness
  `NOT_SERVING` → `Shutdown(deadline)` → reverse-order teardown → exit 0.

## How to run

```bash
cd examples/statelessness/10-grpc-microservices
podman compose -f compose.yml up --build   # or: ./demo.sh
./demo.sh                                   # the three acts
./demo.sh --keep                            # leave the stack up afterward
./demo.sh --clean                           # tear down
```

The demo brings up three services — `postgres`, `tax-svc`, and `pricing-svc`
(the last two share one image). The first build compiles the gRPC chain
(~5 min cold); a warm Conan cache is far faster. `PriceOrder` is driven by an
in-image `pricing-client` via `podman exec`, so no host gRPC tooling is
needed.

CI verification: `scripts/test-stateless-demo-10-grpc-microservices.sh`.

## What you'll see

Actual output from a host run on Fedora 44 (GCC 14, Podman 5.x) —
the three acts, with the real figures from the seeded data:

```
==> stack up: postgres healthy, tax-svc SERVING, pricing-svc SERVING

==> act 1: PriceOrder  customer=alice (US, taxable)  key=k-001
    [pricing-svc] PG: customer alice; products widget x2, gadget x1
    [pricing-svc] -> tax-svc CalculateTax(country=US, subtotal=8948)
    order_id          : ord-...-0
    subtotal_cents    : 8948
    tax_cents         : 626       <- from the outbound gRPC tax call
    total_cents       : 9574

==> act 2: PriceOrder  customer=carol (US, tax_exempt)  key=k-002
    [pricing-svc] carol tax_exempt -> compute_tax short-circuits
    subtotal_cents    : 8948
    tax_cents         : 0         <- NO outbound call made
    total_cents       : 8948

==> act 3: PriceOrder  key=k-001 again  (idempotent replay)
    order_id          : ord-...-0   <- IDENTICAL to act 1
    (stored result returned; nothing recomputed, tax-svc not called)
```

## How to read the output

- **Act 1 exercises the whole path.** A taxable order for alice: PostgreSQL
  customer + product lookups, the subtotal computed from seeded prices
  (`8948`), then the outbound gRPC call to `tax-svc` returning `626`, totalling
  `9574`. Every hop carried the request deadline.
- **Act 2 short-circuits the outbound call.** carol is `tax_exempt`, so
  `compute_tax` returns `0` *without* calling the tax service — the
  conditional-downstream-call point. `tax_cents: 0` with no `-> tax-svc` log
  line is the proof the outbound call was skipped.
- **Act 3 proves idempotency at the store.** Replaying act 1's key returns the
  *identical* `order_id` — the handler found the stored result and returned it
  without recomputing or calling the tax service. That identical id is the
  whole idempotency guarantee, surviving across what could be a different
  replica.
- **`SERVING` only after migrate.** The startup line shows both services
  reach `SERVING` after their staged warm-up — the health sequence from the
  health-checks example, running in the capstone's `main()`.

## Files

- `src/pricing_svc.cpp` — the capstone: the handler, the deadline-propagating
  helpers, and the twelve-step `main()`
- `src/tax_svc.cpp` — the outbound tax upstream (the second service)
- `src/request_context.hpp` — per-request RAII bundle + real PMR arena (the
  OTel span/scope is a documented seam)
- `src/channel_cache.hpp` — process-scoped gRPC channel cache
- `src/pg_pool.hpp` — the verified libpq pool, reused from 07
- `src/config.hpp` — env-time `Config`
- `src/pricing_client.cpp` — drives `PriceOrder` for the demo
- `src/health_probe.cpp` — the minimal hermetic `grpc_health_probe`
- `proto/{pricing,tax,health}.proto` — the capstone API, the upstream, and
  the standard health protocol
- `CMakeLists.txt` — codegen 3 protos; build 4 binaries
- `conanfile.py` — the gRPC trio (libpq is system)
- `Containerfile` — gRPC-trio + libpq builder; `ubi-minimal` + libpq runtime
- `compose.yml` — postgres + tax-svc + pricing-svc
- `demo.sh` — the three acts

## Caveats and gotchas

- **Faithful in architecture, lean in dependencies.** Doc 10's literal
  feature set reaches for libpqxx, Redis, OpenTelemetry, and jemalloc tuning.
  This example keeps the architecture and composition exactly but realizes it
  on the verified stack — libpq (not libpqxx, gotcha G-67), PostgreSQL-direct
  price lookup (Redis cache-aside marked as a seam), the request span as a
  documented OpenTelemetry seam, and the sync gRPC API. Each divergence is
  called out in the README.
- **It emits no spans — nothing reaches Tempo.** The OpenTelemetry pipeline is
  a documented seam, not a built dependency. "Host-verified green" means the
  *business* path (PostgreSQL + outbound gRPC + idempotency) was verified, not
  tracing. Don't expect a trace in Grafana from this example as shipped.
- **The tax call is conditional.** `compute_tax` returns early for
  `tax_exempt` customers, so the outbound gRPC call only happens on the
  taxable path. That's intentional (act 2 demonstrates it), not a missing
  call.
- **`statement_timeout` is set per query from the remaining budget.** A
  pooled connection is reused across requests with different deadlines, so the
  timeout is computed each time from `rc.deadline() - now()`, not once.

## Source materials

This example deepens material from the project's
[**bibliography**]({{ '/bibliography/' | relative_url }}):

- **Enberg, *Latency*, ch. 6-7** — end-to-end deadline propagation and
  failure handling across service hops; the budget that flows through every
  call here
- **Iglberger, *C++ Software Design*, ch. 3-4** — dependency injection and
  the composition root; the twelve-step `main()` is that pattern at full scale
- **Andrist & Sehr, *C++ High Performance* 2e, ch. 10-11** — networking,
  channel reuse, and the concurrency model behind the gRPC server and the
  channel cache

## Linked tutorial sections

- [**§8 I/O Latency**]({{ '/docs/08-io-latency/' | relative_url }}) —
  async gRPC, the cost of each I/O hop, and the deadline budget the capstone
  propagates from client to database to the tax service.
- [**§9 Networking & Kernel Parameters**]({{ '/docs/09-networking-kernel/' | relative_url }}) —
  the multi-service gRPC topology, channel reuse, and the inter-service
  networking the capstone exercises across the compose network.

## Where it sits in the compendium

This is the integration point for the whole arc: it carries the
`RequestContext` and PMR arena from
[02]({{ '/examples/statelessness-02-raii/' | relative_url }}) and
[03]({{ '/examples/statelessness-03-pmr/' | relative_url }}), the composition
root from [04]({{ '/examples/statelessness-04-process-scoped-state/' | relative_url }}),
the pooling and deadline propagation from
[07]({{ '/examples/statelessness-07-state-externalization/' | relative_url }}),
and the staged health and shutdown sequence from
[09]({{ '/examples/statelessness-09-health-checks/' | relative_url }}). The
build that produces it is the subject of the
[build-tooling example]({{ '/examples/statelessness-11-build-tooling/' | relative_url }}).
