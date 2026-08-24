# statelessness/02-raii — the RequestContext RAII pattern

Compendium reference:
[Doc 02 — RAII as the foundation for safe stateful work](../../../reference/statelessness/02-raii/)

A deliberately small gRPC service whose only job is to make the
**RequestContext** lifecycle visible. It is the runnable companion to
compendium Doc 02: where the document explains *why* per-request state
belongs in one RAII type bound to the handler's scope, this example
lets you watch it happen.

## What it demonstrates

A stateless service still holds plenty of state *inside* a request — a
request id, a span/timer, a deadline, a per-request memory arena, a
leased resource (here a stand-in for a pooled DB connection). None of
it should outlive the request. `RequestContext` (in
[`src/request_context.hpp`](src/request_context.hpp)) bundles all of it
into one move-only RAII type whose lifetime is exactly the handler's
scope:

- **Constructor acquires** — mints the id, starts the timer, reserves
  an 8 KiB `std::pmr::monotonic_buffer_resource` arena, and leases a
  resource from a process-scoped pool. It logs `[rc] acquire id=…`.
- **Destructor releases** — returns the lease and reports the
  duration, logging `[rc] release id=…`. It is `noexcept`, because a
  destructor that throws during stack unwinding calls
  `std::terminate`.
- **Move-only, `noexcept` moves** — copy is deleted; moves are
  `noexcept` (the guarantee `std::vector` relies on). After a move the
  source is inert, so the lease is released exactly once.

The handler in [`src/main.cpp`](src/main.cpp) takes one of three exit
paths, chosen by the request's `mode` field:

| `mode`   | Path                          | gRPC status        |
|----------|-------------------------------|--------------------|
| `ok`     | normal processing + return    | `OK`               |
| `reject` | early return on validation    | `INVALID_ARGUMENT` |
| `throw`  | throws mid-handler            | `INTERNAL`         |

The point: **the `RequestContext` destructor runs on all three.** The
service logs one `acquire` and one matching `release` per request, and
its outstanding-lease counter returns to zero at shutdown. That balance
is the machine-checkable proof that RAII cleaned up — no manual
cleanup, no leaked lease, on the happy path, the early-return path, and
the exception path alike.

## Why this is the first compendium example

RAII request scope is the foundation the other patterns build on:
process-scoped wiring ([Doc 04](../../../reference/statelessness/04-process-scoped-state/)),
the PMR arena ([Doc 03](../../../reference/statelessness/03-pmr/)), the
connection pool checkout
([Doc 07](../../../reference/statelessness/07-state-externalization/)),
and the graceful-shutdown sequence
([Doc 09](../../../reference/statelessness/09-health-checks/)) all
assume this discipline is in place.

## Running it

```bash
./demo.sh            # build + bring up + drive all three modes + summary
./demo.sh --keep     # leave the service running afterward
./demo.sh --clean    # tear down (after --keep)
```

The first build pulls and compiles the gRPC chain from source under the
UBI 10 builder; expect several minutes on a cold Conan cache (faster than
the observability demos because there's no OpenTelemetry in the graph).
Cached builds are 2-3 minutes.

CI verification:

```bash
../../../scripts/test-stateless-demo-02-raii.sh
```

## Layout

```
02-raii/
├── proto/processor.proto    RequestProcessor service; mode drives the exit path
├── src/request_context.hpp  the RAII type — the centerpiece
├── src/main.cpp             gRPC callback server + the 3-path handler + healthz
├── src/client.cpp           one-shot client; exit code encodes predicted status
├── CMakeLists.txt           gRPC codegen + server + client
├── conanfile.py             gRPC + protobuf + abseil (no OTel)
├── conan.lock               empty placeholder; resolves fresh on first build
├── Containerfile            multi-stage UBI 10 → ubi-minimal
├── compose.yml              single service; read-only rootfs + tmpfs
└── demo.sh                  the driver
```

## What this example deliberately leaves out

- **Observability.** The lifecycle is visible in plain stdout; no LGTM
  stack. In production the `span_` would be an OpenTelemetry span — see
  [§10](../../../docs/10-observability-profiling/) and demo-04.
- **A real connection pool.** The `LeasePool` is a counter, not a
  database client. The dedicated
  [`07-state-externalization`](../07-state-externalization/) example
  (Doc 07) builds the real `ScopedConnection` checkout against
  PostgreSQL.
- **The PMR deep dive.** The arena here is one fixed buffer; the
  [`03-pmr`](../03-pmr/) example (Doc 03) covers the layered
  monotonic + pool recipe and the lifetime trap.
