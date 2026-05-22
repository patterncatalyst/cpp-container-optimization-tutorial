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

This is the integration example. The earlier examples each established one
pattern in isolation; this one composes them into a single realistic gRPC
service — an order-pricing service — so the way the pieces fit together is
visible end to end. `PriceOrder` looks a customer up in PostgreSQL, prices
each line item, calls a **separate tax service over gRPC**, and returns a
fully-priced order, idempotent on a client key and with the request deadline
propagated through every downstream call.

## What it composes

Every block maps back to an earlier document:

- **`Config` parsed once** in `main()`, passed by `const&` (Doc 06).
- **Process-scoped state** — the `PgPool` and a `ChannelCache` — constructed
  once in `main()` and shared across request threads (Doc 04). gRPC channels
  are expensive to build and cheap to reuse, so they live for the process.
- **A per-request RAII bundle**, `RequestContext`, carrying a real PMR arena
  (Doc 02/03). Per-request allocations come from the arena and are reclaimed
  wholesale when the context destructs.
- **A handler that throws `grpc::Status`** for protocol errors and relies on
  RAII for all cleanup (Doc 02); the boundary translates errors to the wire
  status.
- **Deadline-propagating backing-service calls** (Doc 07): PostgreSQL via a
  pooled libpq connection with `statement_timeout` set from the remaining
  budget, and an outbound gRPC tax call carrying the same deadline through
  the channel cache.
- **Staged startup and graceful shutdown** (Doc 09): up `NOT_SERVING`,
  migrate, flip to `SERVING`; on SIGTERM, readiness `NOT_SERVING` →
  `Shutdown(deadline)` → reverse-order teardown → exit 0.

## A buildable capstone

Doc 10's literal feature set reaches for libpqxx, Redis, OpenTelemetry, and
jemalloc tuning. This example keeps the doc's architecture and composition
exactly but realizes it on the stack the rest of this tutorial has verified:
PostgreSQL via libpq (not libpqxx — gotcha G-67), the price lookup straight
to PostgreSQL (the Redis cache-aside marked as a seam), the request span as
a documented OpenTelemetry seam rather than a built dependency, and the sync
gRPC API rather than the callback API. Each divergence is called out in the
README; the teaching point — how request-, process-, and external-scope
state compose in one service — is unchanged.

## The three acts

The demo drives `PriceOrder` via an in-image client. Act 1 prices a taxable
order for `alice`, exercising the full path: PostgreSQL customer + product
lookups, then the outbound gRPC tax call. Act 2 prices an order for the
tax-exempt `carol`, where the handler short-circuits the outbound call and
returns `tax=0`. Act 3 replays act 1's idempotency key and gets the stored
result back — same `order_id`, no recomputation — demonstrating the
idempotency store from Doc 07.
