# statelessness/07-state-externalization — authoritative state in PostgreSQL

Compendium reference:
[Doc 07 — State externalization](../../../reference/statelessness/07-state-externalization/)

The runnable companion to compendium Doc 07, and the first compendium
example with a real backing store. A stateless service cannot hold
authoritative state in any one replica — the orchestrator can kill it at
any moment. So the orders live in PostgreSQL; the service process holds
only *process-scoped infrastructure* (a connection pool) and reaches the
database through an RAII checkout per request.

## What it demonstrates

**A connection pool with RAII checkout**
([`src/pg_pool.hpp`](src/pg_pool.hpp)). libpq gives one connection at a
time (`PGconn*`) and no pool, so `PgPool` is the one piece the compendium hand-rolls. It
is process-scoped — built once in `main()`'s composition root (Doc 04) —
and hands out a `ScopedConnection` per request that returns the
connection to the pool on scope exit (the RAII discipline of Doc 02,
now against a real network resource). `ScopedConnection::invalidate()`
marks a connection poisoned after a reset or a timed-out query whose
commit state is unknown; the pool discards it on release rather than
handing it to the next request, and `release()` never throws and never
opens a connection (no work in a destructor) — a discarded connection
is replaced lazily on the next `acquire()`.

**DB-authoritative idempotency** ([`src/main.cpp`](src/main.cpp)).
`CreateOrder` carries an `idempotency_key`. A client retry must not
create a second order. The handler uses

```sql
INSERT INTO orders (customer_id, item, idempotency_key)
VALUES ($1, $2, $3)
ON CONFLICT (idempotency_key) DO NOTHING
RETURNING order_id
```

which is race-free: two concurrent retries with the same key cannot both
insert. A returned row means we created the order; an empty result means
the key already existed, so we read the original back and flag the
response `idempotent_replay=true`. The UNIQUE constraint in the schema
is the authoritative dedup point — not an in-process check, which would
not survive a replica swap.

**Deadline propagation to the database.** The handler reads the inbound
gRPC deadline (`ctx->deadline()`) and sets the transaction's
`statement_timeout` from the time remaining, so a slow query cannot
outlive the client's patience.

**Closing the 03-pmr lifetime trap.** The authoritative state is the
external `orders` table, and the handler copies query results into owned
`std::string`s in the response — it never lets a cache borrow from a
per-request arena. That is the fix for the counterexample
[03-pmr](../03-pmr/) demonstrated: process-scoped or externalized state
must *own* its data, never alias request-scoped memory.

## Running it

```bash
./demo.sh            # build + bring up postgres + order-svc + the 3 acts
./demo.sh --keep     # leave the stack running
./demo.sh --clean    # tear down
```

CI verification:
`../../../scripts/test-stateless-demo-07-state-externalization.sh`.

Two services come up via compose: `postgres` (the CentOS Stream 9 SCLorg
image) and `order-svc`. The service waits for Postgres to be healthy and
also retries the connection at startup, so it tolerates the database
still coming up.

## Layout

```
07-state-externalization/
├── proto/order.proto    OrderService: CreateOrder + GetOrder
├── src/pg_pool.hpp      PgPool + ScopedConnection (the hand-rolled pool)
├── src/main.cpp         composition root, migration, idempotent handler
├── src/client.cpp       create / get driver
├── CMakeLists.txt       svc + client; links gRPC + system libpq
├── conanfile.py         gRPC + protobuf + abseil (libpq is a system pkg)
├── conan.lock           empty placeholder
├── Containerfile        UBI 9 builder → ubi-minimal (+ libstdc++, libpq)
├── compose.yml          postgres + order-svc
└── demo.sh              the driver
```

## A note on the build

PostgreSQL is reached through **libpq**, the C client, installed from
UBI's own AppStream (`libpq-devel` at build, `libpq` at runtime) — not
through Conan. Doc 07's prose sketches the pool around **libpqxx** (the
C++ wrapper), but libpqxx's Conan recipe doesn't build under the CMake
in this toolchain: its bundled `cmake/config.cmake` calls the removed
internal command `cmake_determine_compile_features`, which fails to
configure across libpqxx versions (gotcha G-67). Using libpq directly
avoids that, sidesteps any OpenSSL/zlib resolution conflict between
gRPC's Conan chain and libpq, and — being a C ABI — removes the
libstdc++ mixing concern a system C++ library would raise. The
connection-pool, idempotency, and deadline patterns are identical either
way; only the connection type changes (`PGconn*` rather than
`pqxx::connection`). The pool's checkout/timeout/invalidate logic is
unit-tested separately; the SQL is verified by the demo against a live
PostgreSQL.

## Production note

For real deployments, Doc 07 recommends PgBouncer (or pgcat) in front of
the database *and* a small in-process pool inside the service: the
external pooler handles database-side connection limits and
transaction-mode pooling; the in-process pool gives you RAII checkout,
exception safety, and deadline propagation in C++.
