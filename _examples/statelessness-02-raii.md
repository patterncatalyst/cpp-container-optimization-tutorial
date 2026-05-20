---
title: "Statelessness 02 — RequestContext RAII"
description: "The runnable companion to compendium Doc 02: a small gRPC service whose handler builds a RequestContext (RAII) on entry and takes one of three exit paths — normal return, early return, and throw — proving the destructor fires on all three."
order: 202
layout: example
sectionid: examples
permalink: /examples/statelessness-02-raii/
demo_dir: statelessness/02-raii
github_path: examples/statelessness/02-raii
---

> The full source for this example lives in [`examples/statelessness/02-raii/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/statelessness/02-raii) — clone the repo, `cd` in, and `./demo.sh`.

Compendium reference:
[Doc 02 — RAII as the foundation for safe stateful work]({{ '/reference/statelessness/02-raii/' | relative_url }})

A deliberately small gRPC service whose only job is to make the
**RequestContext** lifecycle visible. Where compendium Doc 02 explains
*why* per-request state belongs in one RAII type bound to the handler's
scope, this example lets you watch it happen.

## What it demonstrates

A stateless service still holds plenty of state *inside* a request — a
request id, a span/timer, a deadline, a per-request memory arena, a
leased resource (a stand-in for a pooled DB connection). None of it
should outlive the request. `RequestContext` bundles all of it into one
move-only RAII type whose lifetime is exactly the handler's scope:

- **Constructor acquires** — mints the id, starts the timer, reserves
  an 8 KiB `std::pmr::monotonic_buffer_resource` arena, leases a
  resource from a process-scoped pool. Logs `[rc] acquire`.
- **Destructor releases** — returns the lease, reports the duration.
  It is `noexcept`, because a destructor that throws during stack
  unwinding calls `std::terminate`. Logs `[rc] release`.
- **Move-only, `noexcept` moves** — copy deleted; moves `noexcept` (the
  guarantee `std::vector` relies on). After a move the source is inert,
  so the lease releases exactly once.

The handler takes one of three exit paths, chosen by the request's
`mode` field:

| `mode`   | Path                       | gRPC status        |
|----------|----------------------------|--------------------|
| `ok`     | normal processing + return | `OK`               |
| `reject` | early return on validation | `INVALID_ARGUMENT` |
| `throw`  | throws mid-handler         | `INTERNAL`         |

The point: **the destructor runs on all three.** The service logs one
`acquire` and one matching `release` per request, and its
outstanding-lease counter returns to zero at shutdown. That balance is
the machine-checkable proof that RAII cleaned up — no manual cleanup,
no leaked lease, on the happy path, the early-return path, and the
exception path alike.

## Running it

```bash
cd examples/statelessness/02-raii
./demo.sh            # build + bring up + drive all three modes + summary
./demo.sh --keep     # leave the service running afterward
./demo.sh --clean    # tear down
```

The first build compiles the gRPC chain from source under the UBI 9
builder — several minutes on a cold Conan cache, faster than the
observability demos because there's no OpenTelemetry in the graph.
Cached builds are 2-3 minutes.

CI verification: `scripts/test-stateless-demo-02-raii.sh`.

## Where it sits in the compendium

RAII request scope is the foundation the other compendium examples
build on — process-scoped wiring
([Doc 04]({{ '/reference/statelessness/04-process-scoped-state/' | relative_url }})),
the PMR arena
([Doc 03]({{ '/reference/statelessness/03-pmr/' | relative_url }})),
the connection-pool checkout
([Doc 07]({{ '/reference/statelessness/07-state-externalization/' | relative_url }})),
and graceful shutdown
([Doc 09]({{ '/reference/statelessness/09-health-checks/' | relative_url }}))
all assume this discipline is in place.
