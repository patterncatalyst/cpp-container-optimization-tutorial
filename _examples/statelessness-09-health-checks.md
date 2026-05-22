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

Tutorial sections:
[§9 Networking & Kernel Parameters]({{ '/docs/09-networking-kernel/' | relative_url }}) +
[§8 I/O Latency: io_uring, Async gRPC]({{ '/docs/08-io-latency/' | relative_url }})

A health check is the orchestrator's API into your service. It decides
whether to route traffic to a replica, whether to restart a sick one, and
whether a newly-started one has finished initializing. Those are **three
different questions** — and conflating them produces failure modes that look
correct in development and fail in production. This example answers each
distinctly, with one small gRPC service you can drive by hand.

## Why this matters

Health checks are the interface between your service and the orchestrator's
control loop, and getting them wrong causes the outages they were meant to
prevent:

- **The three questions are not interchangeable.** "Has it started?", "Is it
  wedged?", and "Should it get traffic?" demand different answers with
  different consequences. Answer them with one boolean and you get either
  restart storms or traffic sent to a replica that isn't ready.
- **A bad liveness probe amplifies outages.** The classic failure: a liveness
  probe that checks a downstream dependency. A transient database blip then
  trips liveness on *every* replica at once, and the orchestrator restarts the
  whole fleet simultaneously — turning a blip into an outage. Liveness must
  fail only for what a restart fixes.
- **Graceful shutdown is a feature under orchestration.** Replicas are killed
  routinely — scaling down, rolling deploys, node drains. A service that
  drops in-flight requests on `SIGTERM` loses work every deploy. The ordered
  drain is what makes a kill safe.

## What this demo shows

**Staged startup.** The gRPC server binds its port immediately but reports
`NOT_SERVING` while it does ~3 seconds of simulated expensive initialization,
then flips to `SERVING`. A startup probe hitting `NOT_SERVING` gives the
service time to come up instead of killing it during cold start.

**Liveness vs readiness, on two ports.** Liveness is a tiny HTTP endpoint on
`:8080` (`GET /healthz` → `200 ok`) — cheap, binary, and it survives gRPC
overload, so a merely-busy replica is not restarted. Readiness is the gRPC
standard `grpc.health.v1.Health` service on `:50051`, reporting per-service
status. This hybrid split is the recommended production shape: liveness needs
to survive overload; readiness reports the richer service-level status.

**Driving readiness at runtime.** `SIGUSR1` toggles readiness between
`SERVING` and `NOT_SERVING` *without* touching the server-wide status, so you
can watch readiness drop — traffic would stop — while liveness stays green and
the replica is never restarted. The recovery (toggle back to ready, no
restart) is the corollary: a not-ready replica should be able to return to
ready on its own.

**Graceful shutdown.** `SIGTERM` runs the staged-shutdown sequence: flip
readiness `NOT_SERVING` (stop new traffic) → `request_stop()` the background
worker (the threading section's `std::stop_token`) → `server->Shutdown(deadline)`
to drain in-flight RPCs → reverse-order teardown (process scope) → exit 0.

## How to run

```bash
cd examples/statelessness/09-health-checks
./demo.sh            # staged startup + liveness/readiness + toggle + shutdown
./demo.sh --keep     # leave the stack up afterward
./demo.sh --clean    # tear down
```

The first build compiles the gRPC chain (~5 min cold); a warm Conan cache is
far faster. The demo queries readiness with the in-image `health-probe` via
`podman exec`, and liveness with `curl` against the published HTTP port — no
host gRPC tooling needed.

## What you'll see

Representative output on a Fedora 44 host with Podman 5.x — staged startup,
the liveness/readiness split, a SIGUSR1 readiness toggle, then graceful
shutdown:

```
==> act 1: staged startup
    t+0.0s  liveness  GET /healthz       -> 200 ok      (port bound immediately)
    t+0.0s  readiness grpc.health Check  -> NOT_SERVING  (still initializing)
    t+3.1s  readiness grpc.health Check  -> SERVING       (init complete)
    -> liveness was green throughout; readiness gated traffic until ready

==> act 2: readiness toggle   (podman kill -s SIGUSR1)
    readiness Check -> NOT_SERVING   (drained from rotation)
    liveness  /healthz -> 200 ok      (still alive — NOT restarted)
    [SIGUSR1 again]
    readiness Check -> SERVING        (returned to ready on its own)

==> act 3: graceful shutdown   (podman stop -> SIGTERM)
    [sig] SIGTERM received (flag set)
    [ctl] readiness -> NOT_SERVING  (stop new traffic)
    [ctl] request_stop() background worker
    [ctl] server->Shutdown(deadline)  (draining in-flight RPCs)
    [ctl] reverse-order teardown
    exit code: 0
```

## How to read the output

- **Liveness is green from t+0; readiness lags to t+3.1s.** That's the staged
  startup working: the port binds and liveness answers immediately, but
  readiness withholds traffic until initialization finishes. A startup/readiness
  probe respects that gap; a naive liveness probe that fired during it would
  restart the service mid-init.
- **The SIGUSR1 toggle drops readiness while liveness stays 200.** This is the
  whole liveness-vs-readiness distinction in one act: traffic stops (readiness
  `NOT_SERVING`) but the replica is *not* restarted (liveness still green).
  Then it returns to ready on its own — no external intervention.
- **The shutdown sequence is ordered, and the order matters.** Readiness drops
  *first* (so the load balancer stops sending new requests), *then* in-flight
  RPCs drain, *then* teardown. Reverse that and you'd either kill live requests
  or keep accepting new ones while shutting down.
- **Exit code 0 is the success condition for act 3.** A clean exit means the
  drain completed within the deadline. A non-zero exit or a hang would mean
  the shutdown sequence didn't complete — work was dropped.

## Files

- `proto/echo.proto` — the trivial app service (`demo.health.EchoService`)
- `proto/health.proto` — the standard `grpc.health.v1` protocol (for the probe)
- `src/health_svc.cpp` — the server: staged startup, liveness, readiness,
  shutdown
- `src/health_probe.cpp` — the minimal `grpc_health_probe`, built from source
- `CMakeLists.txt` — codegen both protos; build both binaries
- `conanfile.py` — the gRPC trio (no other deps)
- `Containerfile` — gRPC-trio builder; `ubi-minimal` + `curl` runtime
- `compose.yml` — one hardened service; liveness as the healthcheck
- `demo.sh` — the three acts

## Caveats and gotchas

- **Two corrections vs the compendium prose.** Building the runnable version
  surfaced two details Doc 09's prose glosses: the public
  `HealthCheckServiceInterface` uses a `bool` overload of `SetServingStatus`
  (not the `grpc::health::v1` enum the doc sketches), and a correct signal
  handler sets only a `volatile sig_atomic_t` flag while a control thread does
  the actual `SetServingStatus`/`Shutdown` work.
- **The signal handler must be async-signal-safe.** It does nothing but set a
  flag — it cannot call into gRPC, take a lock, or allocate, because almost
  nothing is async-signal-safe. A dedicated control thread watches the flag and
  performs the real work off the handler. Doing the work *in* the handler is the
  subtle bug the demo is built to avoid.
- **Liveness must NOT check dependencies.** Liveness fails only for what a
  restart fixes — deadlocks, internal corruption — never downstream-dependency
  health. A liveness probe that fails when the database is unreachable is how a
  single blip becomes a fleet-wide restart storm. Dependency trouble belongs in
  readiness (drain, don't kill).
- **Keep probes cheap.** A no-op, not a real query. A probe heavier than a real
  request makes the probe traffic itself the load — and at high replica counts
  that's significant.
- **The probe is built hermetically.** Rather than fetch the upstream
  `grpc_health_probe` binary, the example builds its own from the standard
  `health.proto` — no build-time network dependency, and the `Check` RPC stays
  visible in the source.

## Source materials

This example deepens material from the project's
[**bibliography**]({{ '/bibliography/' | relative_url }}):

- **Enberg, *Latency*, ch. 6** — graceful degradation and shedding load; why
  readiness (drain) beats liveness (kill) for transient unhealthiness
- **Iglberger, *C++ Software Design*, ch. 2** — the control-thread / signal-flag
  separation as a single-responsibility design; the handler signals, the
  controller acts
- **Andrist & Sehr, *C++ High Performance* 2e, ch. 11** — `std::stop_token` and
  `std::jthread` for the cooperative cancellation the shutdown sequence uses

## Linked tutorial sections

- [**§9 Networking & Kernel Parameters**]({{ '/docs/09-networking-kernel/' | relative_url }}) —
  port binding, the separate liveness/readiness ports, and the network-level
  behavior of draining connections on shutdown.
- [**§8 I/O Latency: io_uring, Async gRPC**]({{ '/docs/08-io-latency/' | relative_url }}) —
  the in-flight-RPC draining on shutdown is an I/O-completion concern; this is
  where the async-server lifecycle lives.

## The anti-patterns it is built to avoid

Liveness fails only for what a restart fixes — deadlocks, internal corruption
— never downstream-dependency health (that path is how a single database blip
becomes a fleet-wide restart storm). Probes stay cheap, so the probe traffic
itself never becomes load. Readiness, not liveness, is where transient
unhealthiness and graceful drain live. Those distinctions are the whole point
of treating health as a designed API rather than a single "is it up?" boolean.

## Where it sits in the compendium

The shutdown sequence composes the threading section's
[`std::stop_token`]({{ '/examples/statelessness-05-threading/' | relative_url }})
cancellation and the
[process-scope]({{ '/reference/statelessness/04-process-scoped-state/' | relative_url }})
reverse-order teardown. The staged-startup gate is the answer to the cold-start
trap from
[12-factor]({{ '/reference/statelessness/06-twelve-factor/' | relative_url }}).
The capstone
([Doc 10]({{ '/reference/statelessness/10-grpc-microservices/' | relative_url }}))
reuses this exact health/shutdown sequence and the `health-probe` binary.
