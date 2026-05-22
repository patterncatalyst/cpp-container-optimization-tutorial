---
title: "Statelessness 02 — RequestContext RAII"
description: "The runnable companion to compendium Doc 02: a small gRPC service whose handler builds a RequestContext (RAII) on entry and takes one of three exit paths — normal return, early return, and throw — proving the destructor fires on all three."
order: 202
card_eyebrow: "Compendium · <strong>Doc 02</strong>"
card_title: "RequestContext RAII"
card_blurb: "A gRPC handler builds a RequestContext on entry and takes one of three exit paths — normal return, early return, and throw — proving the destructor fires on all three. RAII cleanup made visible."
layout: example
sectionid: examples
permalink: /examples/statelessness-02-raii/
demo_dir: statelessness/02-raii
github_path: examples/statelessness/02-raii
---

> The full source for this example lives in [`examples/statelessness/02-raii/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/statelessness/02-raii) — clone the repo, `cd` in, and `./demo.sh`.

Compendium reference:
[Doc 02 — RAII as the foundation for safe stateful work]({{ '/reference/statelessness/02-raii/' | relative_url }})

Tutorial sections:
[§3 RAII & Container Resource Discipline]({{ '/docs/03-raii-discipline/' | relative_url }}) +
[§7 Memory Management]({{ '/docs/07-memory-management/' | relative_url }})

A deliberately small gRPC service whose only job is to make the
**RequestContext** lifecycle visible. Where compendium Doc 02 explains
*why* per-request state belongs in one RAII type bound to the handler's
scope, this example lets you watch it happen — one `acquire` and one
matching `release` per request, on every exit path.

## Why this matters

A stateless service is not a service with no state. It is a service that
holds no *authoritative* state in process — but it still holds plenty of
state *inside* a request: a request id, a span/timer, a deadline, a
per-request memory arena, a leased resource standing in for a pooled DB
connection. That state must be acquired at the start of the request and
released at the end, on every path, or the service leaks.

RAII is the C++ mechanism that makes "on every path" automatic. Tie a
resource's lifetime to an object's lifetime, and the destructor runs at
scope exit whether the handler returns normally, returns early, or throws.
This matters under containers specifically because:

- **Restarts are routine, leaks compound fast.** Under an orchestrator a
  replica handles a high request rate; a per-request leak that would take
  days to matter on a long-lived monolith exhausts a cgroup memory limit in
  minutes and triggers an OOMKill.
- **The exception path is not exceptional.** A downstream timeout, a
  cancelled RPC, a validation failure — these happen continuously at scale.
  Manual cleanup that only covers the happy path is a leak under load.
- **The destructor is the contract.** Once cleanup lives in destructors,
  the handler body carries no cleanup code at all; its `try`/`catch` is for
  translating errors to gRPC status, not for releasing resources.

This is the foundation every other compendium example builds on, which is
why it is the first one.

## What this demo shows

`RequestContext` bundles all per-request state into one move-only RAII type
whose lifetime is exactly the handler's scope:

- **Constructor acquires** — mints the id, starts the timer, reserves an
  8 KiB `std::pmr::monotonic_buffer_resource` arena, leases a resource from
  a process-scoped pool. Logs `[rc] acquire`.
- **Destructor releases** — returns the lease, reports the duration. It is
  `noexcept`, because a destructor that throws during stack unwinding calls
  `std::terminate`. Logs `[rc] release`.
- **Move-only, `noexcept` moves** — copy deleted; moves `noexcept` (the
  guarantee `std::vector` relies on). After a move the source is inert, so
  the lease releases exactly once.

The handler takes one of three exit paths, chosen by the request's `mode`
field:

| `mode`   | Path                       | gRPC status        |
|----------|----------------------------|--------------------|
| `ok`     | normal processing + return | `OK`               |
| `reject` | early return on validation | `INVALID_ARGUMENT` |
| `throw`  | throws mid-handler         | `INTERNAL`         |

The point: **the destructor runs on all three.** The service logs one
`acquire` and one matching `release` per request, and its
outstanding-lease counter returns to zero at shutdown. That balance is the
machine-checkable proof that RAII cleaned up — no manual cleanup, no leaked
lease, on the happy path, the early-return path, and the exception path
alike.

## How to run

```bash
cd examples/statelessness/02-raii
./demo.sh            # build + bring up + drive all three modes + summary
./demo.sh --keep     # leave the service running afterward
./demo.sh --clean    # tear down
```

The first build compiles the gRPC chain from source under the UBI 9
builder — several minutes on a cold Conan cache, faster than the
observability demos because there's no OpenTelemetry in the graph. Cached
builds are 2-3 minutes.

CI verification: `scripts/test-stateless-demo-02-raii.sh`.

## What you'll see

Representative output on a Fedora 44 host with gcc-toolset-14 and Podman
5.x — the three modes driven in sequence, with the acquire/release balance
summarised at the end:

```
==> mode=ok       (normal processing + return)
[rc] acquire  id=req-0001  arena=8KiB  lease=#1  (outstanding=1)
[rc] release  id=req-0001  dur=0.41ms             (outstanding=0)
    status: OK

==> mode=reject   (early return on validation)
[rc] acquire  id=req-0002  arena=8KiB  lease=#2  (outstanding=1)
[rc] release  id=req-0002  dur=0.06ms             (outstanding=0)
    status: INVALID_ARGUMENT  ("missing payload")

==> mode=throw    (throws mid-handler)
[rc] acquire  id=req-0003  arena=8KiB  lease=#3  (outstanding=1)
[rc] release  id=req-0003  dur=0.09ms             (outstanding=0)
    status: INTERNAL  ("synthetic failure")

==> summary
    requests handled : 3
    acquires         : 3
    releases         : 3
    outstanding leases at shutdown : 0   <-- the proof
```

## How to read the output

- **Three `acquire` lines, three `release` lines.** One pair per request.
  The early-return path (`reject`) and the throw path (`throw`) each still
  produce a `release` — that is the whole demonstration.
- **`outstanding=0` after every request, and `0` at shutdown.** The lease
  counter is incremented in the constructor and decremented in the
  destructor. It returning to zero is the machine-checkable evidence that
  the destructor ran on every path; if any path leaked, the shutdown line
  would read a non-zero count.
- **The `throw` path still returns a clean gRPC status.** The handler's
  `catch` translates the exception to `INTERNAL` — but note it does *no*
  resource cleanup. The lease was already released by `~RequestContext`
  during stack unwinding, before the `catch` block ran.
- **If you ever see fewer releases than acquires**, something escaped RAII —
  a raw owning pointer, a resource acquired outside the `RequestContext`,
  or a swallowed exception bypassing a destructor. That asymmetry is exactly
  what the counter is there to catch.

## Files

- `src/request_context.hpp` — the move-only RAII bundle: id, timer, PMR
  arena, pooled lease; `noexcept` destructor and moves
- `src/service.cpp` — the gRPC handler with the three `mode` paths and the
  error-to-status translation at the boundary
- `src/main.cpp` — process-scoped wiring: the lease pool, the server, the
  outstanding-lease counter, clean shutdown
- `proto/raii_demo.proto` — the trivial `Process(mode)` RPC
- `CMakeLists.txt` / `conanfile.py` — the gRPC trio, pinned; no OTel
- `Containerfile` — UBI 9 builder, `ubi-minimal` runtime
- `compose.yml` — the single service
- `demo.sh` — build, bring up, drive all three modes, print the summary

## Caveats and gotchas

- **The destructor must be `noexcept`.** A `RequestContext` whose destructor
  could throw would call `std::terminate` if it threw during unwinding from
  another exception (the `throw` mode path). This is why the release logic
  never propagates errors — it logs and swallows, which is the correct
  discipline for a destructor.
- **Move, don't copy.** The type is move-only on purpose. A copy would
  double-release the lease. The moves are `noexcept` so that storing a
  `RequestContext` in a standard container wouldn't silently fall back to
  copies — not needed here, but the right default.
- **The lease is a stand-in.** It models a pooled DB connection (the real
  thing arrives in Doc 07) so the acquire/release balance is observable
  without a database. Don't read it as a connection pool implementation;
  read it as "any resource whose lifetime must match the request."
- **`--keep` leaves the port bound.** If you re-run after `--keep` without
  `--clean`, the compose bring-up will fail on the already-bound port. Run
  `./demo.sh --clean` between keep-runs.

## Source materials

This example deepens material from the project's
[**bibliography**]({{ '/bibliography/' | relative_url }}):

- **Andrist & Sehr, *C++ High Performance* 2e, ch. 2-3** — resource
  management, move semantics, and the `noexcept` move guarantee the
  `RequestContext` relies on
- **Iglberger, *C++ Software Design*, ch. 1** — RAII and ownership as a
  design discipline; the case for binding lifetime to scope rather than
  managing it by hand
- **Enberg, *Latency*, ch. 2** — why per-request work must be bounded and
  released promptly under load, the latency framing behind request scope

## Linked tutorial sections

- [**§3 RAII & Container Resource Discipline**]({{ '/docs/03-raii-discipline/' | relative_url }}) —
  the tutorial section this example is the worked companion to: RAII as the
  enforcement mechanism for request scope, exception safety, and why
  destructors are the cleanup contract under containers.
- [**§7 Memory Management**]({{ '/docs/07-memory-management/' | relative_url }}) —
  the `RequestContext`'s PMR arena member is sized and reasoned about here;
  the per-request arena is developed in full in the
  [PMR companion]({{ '/examples/statelessness-03-pmr/' | relative_url }}).

## Where it sits in the compendium

RAII request scope is the foundation the other compendium examples build
on. The process-scoped wiring
([Doc 04]({{ '/reference/statelessness/04-process-scoped-state/' | relative_url }}))
owns the lease pool this example leases from; the PMR arena
([Doc 03]({{ '/reference/statelessness/03-pmr/' | relative_url }}))
is the `RequestContext` member shown here, in full; the connection-pool
checkout
([Doc 07]({{ '/reference/statelessness/07-state-externalization/' | relative_url }}))
is the real resource the lease stands in for; and graceful shutdown
([Doc 09]({{ '/reference/statelessness/09-health-checks/' | relative_url }}))
relies on the same reverse-order destruction. The capstone
([Doc 10]({{ '/reference/statelessness/10-grpc-microservices/' | relative_url }}))
composes all of them in one service.
