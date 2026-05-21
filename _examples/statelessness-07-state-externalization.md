---
title: "Statelessness 07 — State externalization"
description: "The runnable companion to compendium Doc 07: authoritative order state in PostgreSQL, a hand-rolled connection pool with ScopedConnection RAII checkout, DB-authoritative idempotency via ON CONFLICT, and gRPC deadline propagation to the database."
order: 207
layout: example
sectionid: examples
permalink: /examples/statelessness-07-state-externalization/
demo_dir: statelessness/07-state-externalization
github_path: examples/statelessness/07-state-externalization
---

> The full source for this example lives in [`examples/statelessness/07-state-externalization/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/statelessness/07-state-externalization) — clone the repo, `cd` in, and `./demo.sh`.

Compendium reference:
[Doc 07 — State externalization]({{ '/reference/statelessness/07-state-externalization/' | relative_url }})

The first compendium example with a real backing store. A stateless
service cannot hold authoritative state in any one replica — the
orchestrator can kill it at any moment — so the orders live in
PostgreSQL. The service process holds only process-scoped infrastructure
(a connection pool) and reaches the database through an RAII checkout per
request.

## What it demonstrates

**A connection pool with RAII checkout.** libpq gives one connection at
a time (`PGconn*`) and no pool, so `PgPool` is the one piece the
compendium
hand-rolls. It is process-scoped — built once in `main()`'s composition
root (Doc 04) — and hands out a `ScopedConnection` per request that
returns the connection on scope exit (the RAII discipline of Doc 02
against a real network resource). `invalidate()` marks a connection
poisoned after a reset or timed-out query; the pool discards it on
release rather than reusing it, and `release()` never throws or opens a
connection (no work in a destructor) — a discarded connection is
replaced lazily on the next `acquire()`.

**DB-authoritative idempotency.** `CreateOrder` carries an
`idempotency_key`; a retry must not create a second order. The handler
inserts with `ON CONFLICT (idempotency_key) DO NOTHING RETURNING`, which
is race-free — two concurrent retries with the same key cannot both
insert. A returned row means a fresh order; an empty result means the
key already existed, so the original is read back and flagged
`idempotent_replay=true`. The UNIQUE constraint is the authoritative
dedup point, not an in-process check (which wouldn't survive a replica
swap).

**Deadline propagation.** The handler reads the inbound gRPC deadline
and sets the transaction's `statement_timeout` from the time remaining,
so a slow query can't outlive the client's patience.

**Closing the 03-pmr lifetime trap.** Authoritative state is the
external table, and results are copied into owned `std::string`s — the
handler never lets a cache borrow from a per-request arena, which is the
fix for the counterexample
[03-pmr]({{ '/examples/statelessness-03-pmr/' | relative_url }})
demonstrated.

## Running it

```bash
cd examples/statelessness/07-state-externalization
./demo.sh            # postgres + order-svc + create/replay/get
./demo.sh --clean    # tear down
```

CI verification: `scripts/test-stateless-demo-07-state-externalization.sh`.

The demo brings up two services (the CentOS Stream 9 SCLorg Postgres
image and the order service); the service waits for the database to be
healthy and retries at startup.

## Production note

Doc 07 recommends PgBouncer in front of the database *and* a small
in-process pool inside the service: the external pooler handles
database-side connection limits; the in-process pool gives RAII
checkout, exception safety, and deadline propagation in C++.
