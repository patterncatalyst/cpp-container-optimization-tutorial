---
title: "Statelessness 09 — Health checks"
description: "The runnable companion to compendium Doc 09: a single gRPC service that demonstrates the three probes (startup, liveness, readiness), the gRPC standard health protocol, liveness and readiness on separate ports, a SIGUSR1-driven readiness toggle, and the graceful-shutdown sequence — SIGTERM to drained, ordered teardown, clean exit."
order: 210
card_eyebrow: "Compendium · <strong>Doc 09</strong>"
card_title: "Health checks"
card_blurb: "The three probes (startup, liveness, readiness) via the gRPC standard health protocol: HTTP liveness on a separate port, gRPC readiness, a SIGUSR1 readiness toggle, and the signal-safe graceful-shutdown sequence to a clean exit."
layout: example
sectionid: examples
permalink: /examples/statelessness-09-health-checks/
demo_dir: statelessness/09-health-checks
github_path: examples/statelessness/09-health-checks
---

> The full source for this example lives in [`examples/statelessness/09-health-checks/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/statelessness/09-health-checks) — clone the repo, `cd` in, and `./demo.sh`.

Compendium reference:
[Doc 09 — Health checks]({{ '/reference/statelessness/09-health-checks/' | relative_url }})

A health check is the orchestrator's API into your service. It decides
whether to route traffic to a replica, whether to restart a sick one, and
whether a newly-started one has finished initializing. Those are **three
different questions** — and conflating them produces failure modes that
look correct in development and fail in production. This example answers
each distinctly, with one small gRPC service you can drive by hand.

## What it demonstrates

**Staged startup.** The gRPC server binds its port immediately but reports
`NOT_SERVING` while it does ~3 seconds of simulated expensive
initialization, then flips to `SERVING`. A startup probe hitting
`NOT_SERVING` gives the service time to come up instead of killing it
during cold start — the trap from
[Doc 06]({{ '/reference/statelessness/06-twelve-factor/' | relative_url }}).

**Liveness vs readiness, on two ports.** Liveness is a tiny HTTP endpoint
on `:8080` (`GET /healthz` → `200 ok`) — cheap, binary, and it survives
gRPC overload, so a merely-busy replica is not restarted. Readiness is the
gRPC standard `grpc.health.v1.Health` service on `:50051`, reporting
per-service status for `demo.health.EchoService`. This hybrid split is
Doc 09's recommended production shape: liveness needs to survive overload;
readiness reports the richer service-level status.

**Driving readiness at runtime.** `SIGUSR1` toggles readiness between
`SERVING` and `NOT_SERVING` *without* touching the server-wide status, so
you can watch readiness drop — traffic would stop — while liveness stays
green and the replica is never restarted. `podman kill -s SIGUSR1` drives
it, symmetric with the `SIGTERM` shutdown handler. The recovery (toggle
back to ready, no restart) is the 12-factor corollary: a not-ready replica
should be able to return to ready on its own.

**Graceful shutdown.** `SIGTERM` runs the staged-shutdown sequence:
flip readiness `NOT_SERVING` (stop new traffic) → `request_stop()` the
background worker ([Doc 05]({{ '/reference/statelessness/05-threading/' | relative_url }})'s
`std::stop_token`) → `server->Shutdown(deadline)` to drain in-flight RPCs →
reverse-order teardown
([Doc 04]({{ '/reference/statelessness/04-process-scoped-state/' | relative_url }})) →
exit 0. `podman stop` sends `SIGTERM`; the demo streams the ordered drain
straight from the logs.

## A hermetic probe, and two corrections

Rather than fetch the upstream `grpc_health_probe` binary, the example
builds its own minimal one from the standard `health.proto` — no
build-time network dependency, and the `Check` RPC stays visible in the
source. Writing the runnable version also surfaced two details the
compendium prose glosses: the public `HealthCheckServiceInterface` uses a
`bool` overload of `SetServingStatus` (not the `grpc::health::v1` enum the
doc sketches), and a correct signal handler sets only a
`volatile sig_atomic_t` flag while a control thread does the actual
`SetServingStatus`/`Shutdown` work — the async-signal-safe refinement of
the doc's in-handler illustration.

## The anti-patterns it is built to avoid

Liveness fails only for what a restart fixes — deadlocks, internal
corruption — never downstream-dependency health (that path is how a single
database blip becomes a fleet-wide restart storm). Probes stay cheap, so
the probe traffic itself never becomes load. Readiness, not liveness, is
where transient unhealthiness and graceful drain live. Those distinctions
are the whole point of treating health as a designed API rather than a
single "is it up?" boolean.
