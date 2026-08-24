---
title: "Statelessness 07 — State externalization"
description: "The runnable companion to compendium Doc 07: authoritative order state in PostgreSQL, a hand-rolled connection pool with ScopedConnection RAII checkout, DB-authoritative idempotency via ON CONFLICT, and gRPC deadline propagation to the database."
order: 207
card_eyebrow: "Compendium · <strong>Doc 07</strong>"
card_title: "State externalization"
card_blurb: "Authoritative order state in PostgreSQL: a hand-rolled connection pool with ScopedConnection RAII checkout, DB-authoritative idempotency via ON CONFLICT, and gRPC deadline propagation to the database."
layout: example
sectionid: examples
permalink: /examples/statelessness-07-state-externalization/
demo_dir: statelessness/07-state-externalization
github_path: examples/statelessness/07-state-externalization
---

> The full source for this example lives in [`examples/statelessness/07-state-externalization/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/statelessness/07-state-externalization) — clone the repo, `cd` in, and `./demo.sh`.

Compendium reference:
[Doc 07 — State externalization]({{ '/reference/statelessness/07-state-externalization/' | relative_url }})

Tutorial sections:
[§8 I/O Latency: io_uring, Async gRPC]({{ '/docs/08-io-latency/' | relative_url }}) +
[§9 Networking & Kernel Parameters]({{ '/docs/09-networking-kernel/' | relative_url }})

The first compendium example with a real backing store. A stateless service
cannot hold authoritative state in any one replica — the orchestrator can
kill it at any moment — so the orders live in PostgreSQL. The service process
holds only process-scoped infrastructure (a connection pool) and reaches the
database through an RAII checkout per request.

## Why this matters

Statelessness is not "hold no state"; it's "hold no *authoritative* state in
process." The moment a service has data that must survive a replica being
killed, that data has to live outside the process — and reaching external
state correctly is its own discipline:

- **Any replica can die at any instant.** If the authoritative order lived in
  one replica's memory, a routine restart would lose it. Putting it in
  PostgreSQL means any replica can serve any request, and killing one loses
  nothing — the property the orchestrator relies on.
- **Retries are normal, and double-writes are silent corruption.** Networks
  drop responses; clients retry. Without a dedup point, a retry creates a
  second order. The fix has to be *authoritative* — a database UNIQUE
  constraint, not an in-process check that wouldn't survive a replica swap.
- **A slow dependency must not outlive the client's patience.** Under load a
  query that hangs ties up a pooled connection and a request thread. The
  request deadline has to propagate into the database, or a slow query
  becomes a pile-up.

## What this demo shows

**A connection pool with RAII checkout.** libpq gives one connection at a
time (`PGconn*`) and no pool, so `PgPool` is the one piece the compendium
hand-rolls. It is process-scoped — built once in `main()`'s composition root
(process scope) — and hands out a `ScopedConnection` per request that returns
the connection on scope exit (the RAII discipline against a real network
resource). `invalidate()` marks a connection poisoned after a reset or
timed-out query; the pool discards it on release rather than reusing it, and
`release()` never throws or opens a connection (no work in a destructor) — a
discarded connection is replaced lazily on the next `acquire()`.

**DB-authoritative idempotency.** `CreateOrder` carries an `idempotency_key`;
a retry must not create a second order. The handler inserts with `ON CONFLICT
(idempotency_key) DO NOTHING RETURNING`, which is race-free — two concurrent
retries with the same key cannot both insert. A returned row means a fresh
order; an empty result means the key already existed, so the original is read
back and flagged `idempotent_replay=true`. The UNIQUE constraint is the
authoritative dedup point, not an in-process check.

**Deadline propagation.** The handler reads the inbound gRPC deadline and
sets the transaction's `statement_timeout` from the time remaining, so a slow
query can't outlive the client's patience.

**Closing the PMR lifetime trap.** Authoritative state is the external table,
and results are copied into owned `std::string`s — the handler never lets a
cache borrow from a per-request arena, which is the fix for the
counterexample the [PMR example]({{ '/examples/statelessness-03-pmr/' | relative_url }})
demonstrated.

## How to run

```bash
cd examples/statelessness/07-state-externalization
./demo.sh            # postgres + order-svc + create / replay / get
./demo.sh --keep     # leave the stack running
./demo.sh --clean    # tear down
```

Two services come up via compose: `postgres` (the CentOS Stream 9 SCLorg
image) and `order-svc`. The service waits for the database to be healthy and
retries the connection at startup, so it tolerates the database still coming
up.

CI verification: `scripts/test-stateless-demo-07-state-externalization.sh`.

## What you'll see

Representative output on a Fedora 44 host with Podman 5.x — create an order,
replay the same idempotency key, then read it back:

```
==> act 1: CreateOrder  key=ord-abc-001  (fresh)
    order_id           : 1
    idempotent_replay  : false
    status: OK

==> act 2: CreateOrder  key=ord-abc-001  (retry, same key)
    order_id           : 1                <- SAME id, no second order
    idempotent_replay  : true             <- ON CONFLICT caught it
    status: OK

==> act 3: GetOrder  order_id=1
    customer  : alice
    amount    : 4999
    state     : CONFIRMED
    status: OK

    rows in orders table : 1   <- one create + one replay = one row
```

## How to read the output

- **Act 2 returns the same `order_id` as act 1.** That's the idempotency
  proof. The retry hit the UNIQUE constraint, `ON CONFLICT DO NOTHING`
  suppressed the insert, and the handler read the original back rather than
  creating a second order.
- **`idempotent_replay` flips `false` → `true`.** The flag tells the client
  "this is the stored result, not a fresh write" — useful for clients that
  need to distinguish, and proof to you that the dedup path ran.
- **The table holds exactly one row after two creates.** One row for two
  `CreateOrder` calls with the same key is the machine-checkable evidence
  that dedup is authoritative — it's enforced by the database, so it would
  hold even if the two retries had hit two different replicas.
- **If you see two rows**, the dedup isn't authoritative — someone added an
  in-process check instead of the UNIQUE constraint, and it didn't survive
  concurrent retries. The constraint is the point.

## Files

- `proto/order.proto` — `OrderService`: `CreateOrder` + `GetOrder`
- `src/pg_pool.hpp` — `PgPool` + `ScopedConnection`, the hand-rolled pool
- `src/main.cpp` — composition root, migration, idempotent handler,
  deadline propagation
- `src/client.cpp` — the create / get driver
- `CMakeLists.txt` — svc + client; links gRPC + system libpq
- `conanfile.py` — gRPC + protobuf + abseil (libpq is a system package)
- `Containerfile` — UBI 10 builder → `ubi-minimal` (+ libstdc++, libpq)
- `compose.yml` — postgres + order-svc
- `demo.sh` — the driver

## Caveats and gotchas

- **PostgreSQL via libpq, not libpqxx.** Doc 07's prose sketches the pool
  around libpqxx (the C++ wrapper), but libpqxx's Conan recipe doesn't build
  under this toolchain: its bundled `cmake/config.cmake` calls the removed
  `cmake_determine_compile_features`, which fails to configure across versions
  (gotcha G-67). Using libpq directly avoids that, sidesteps an OpenSSL/zlib
  resolution conflict with gRPC's Conan chain, and — being a C ABI — removes
  the libstdc++-mixing concern. The pool, idempotency, and deadline patterns
  are identical; only the connection type changes (`PGconn*` rather than
  `pqxx::connection`).
- **`release()` does no work that can fail.** The destructor path returns the
  connection to the pool without opening a socket or throwing — a discarded
  (invalidated) connection is replaced lazily on the next `acquire()`. A
  destructor that opened a connection could throw during unwinding; this
  avoids that entirely.
- **`statement_timeout` is per-transaction, set from the budget.** It is
  recomputed from the *remaining* deadline at the start of each transaction,
  not a fixed value — so a request that's already spent most of its budget
  upstream gives the database only what's left.
- **The pool is single-process.** It bounds *this* replica's connections; it
  does not bound database-side connections across all replicas. That's what
  PgBouncer is for — see the production note.

## Source materials

This example deepens material from the project's
[**bibliography**]({{ '/bibliography/' | relative_url }}):

- **Enberg, *Latency*, ch. 5** — backing-service latency and deadline
  budgets; why the request deadline must propagate to the database
- **Iglberger, *C++ Software Design*, ch. 2** — dependency injection and the
  composition root; why the pool is owned in `main()` and injected, not a
  global
- **Andrist & Sehr, *C++ High Performance* 2e, ch. 9** — handling resources
  and the RAII checkout pattern applied to a real network resource

## Linked tutorial sections

- [**§8 I/O Latency: io_uring, Async gRPC**]({{ '/docs/08-io-latency/' | relative_url }}) —
  the I/O cost model behind connection pooling and deadline propagation; a
  blocked backing-service call is the latency this section is about.
- [**§9 Networking & Kernel Parameters**]({{ '/docs/09-networking-kernel/' | relative_url }}) —
  connection reuse, timeouts, and the kernel-level settings that affect how a
  pooled database connection behaves under load.

## Production note

Doc 07 recommends PgBouncer (or pgcat) in front of the database *and* a small
in-process pool inside the service: the external pooler handles database-side
connection limits and transaction-mode pooling; the in-process pool gives you
RAII checkout, exception safety, and deadline propagation in C++.

## Where it sits in the compendium

The connection pool here is the process-scoped infrastructure that
[process-scoped state]({{ '/reference/statelessness/04-process-scoped-state/' | relative_url }})
owns in `main()`; the RAII checkout is the
[RAII discipline]({{ '/examples/statelessness-02-raii/' | relative_url }})
applied to a network resource; and the owned-result pattern is the fix for
the [PMR lifetime trap]({{ '/examples/statelessness-03-pmr/' | relative_url }}).
The [outbox example]({{ '/examples/statelessness-07-outbox-pattern/' | relative_url }})
extends this with atomic event emission, and the capstone
([Doc 10]({{ '/reference/statelessness/10-grpc-microservices/' | relative_url }}))
reuses this exact `pg_pool.hpp`.
