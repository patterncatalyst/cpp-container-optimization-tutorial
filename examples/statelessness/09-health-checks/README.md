# statelessness/09-health-checks — health as the orchestrator's API

Compendium reference:
[Doc 09 — Health checks](../../../reference/statelessness/09-health-checks/)

The runnable companion to Doc 09. A health check is the orchestrator's
API into your service: it decides whether to route traffic to a replica,
whether to restart a sick one, and whether a newly-started one has
finished initializing. Those are **three different questions**, and
conflating them produces failures that look fine in development and bite
in production. This example answers each one distinctly, with a single
small gRPC service you can drive from the command line.

## What it demonstrates

**Staged startup** ([`src/health_svc.cpp`](src/health_svc.cpp)). The gRPC
server binds its port immediately but reports `NOT_SERVING` while it does
~3 seconds of simulated expensive initialization (the process-scoped
state of Doc 04, the pools of Doc 07). Then it flips to `SERVING`. A
startup probe hitting `NOT_SERVING` waits instead of killing the service
during cold start — the trap from Doc 06.

**Liveness vs readiness, on two ports** (the hybrid pattern from Doc 09).
Liveness is a tiny hand-rolled HTTP endpoint on `:8080` answering
`GET /healthz` with `200 ok` — cheap, binary, and it *survives gRPC
overload*, so a merely-busy replica is not restarted. Readiness is the
gRPC standard `grpc.health.v1.Health` service on `:50051`, reporting
per-service status for `demo.health.EchoService` — this is what controls
traffic routing.

**Driving readiness at runtime.** `SIGUSR1` toggles the service's
readiness between `SERVING` and `NOT_SERVING` *without* touching the
server-wide status, so you can watch readiness drop (traffic would stop)
while liveness stays green (no restart). `podman kill -s SIGUSR1` drives
it — symmetric with the `SIGTERM` handler.

**Graceful shutdown** (the sequence from Doc 09). `SIGTERM` runs: flip
readiness `NOT_SERVING` (stop new traffic) → `request_stop()` the
background worker (Doc 05's `std::stop_token`) → `server->Shutdown(deadline)`
to drain in-flight RPCs → reverse-order teardown (Doc 04) → exit 0.
`podman stop` sends `SIGTERM`; you see the ordered drain in the logs.

**A hermetic `health-probe`** ([`src/health_probe.cpp`](src/health_probe.cpp)).
Rather than download the upstream `grpc_health_probe` binary, the example
builds its own minimal one from [`proto/health.proto`](proto/health.proto)
— no build-time network dependency (§14), and the `Check` RPC is visible
in the source instead of hidden in a prebuilt tool.

## Two corrections worth flagging vs the compendium prose

The doc is a faithful guide, but writing the runnable version surfaced two
details:

- **`SetServingStatus` uses a `bool` overload, not the enum.** Doc 09
  sketches `health->SetServingStatus("", grpc::health::v1::HealthCheckResponse::SERVING)`.
  The public `grpc::HealthCheckServiceInterface` actually exposes
  `SetServingStatus(const std::string&, bool)` — `true`/`false` for
  serving/not — which needs no generated `health.pb.h` on the server.
  That bool form is what this example uses (verified against gRPC 1.54).

- **Signal handlers set a flag; a control thread does the work.** Doc 09
  shows `SetServingStatus`/`Shutdown` called from inside the signal
  handler. That is illustrative, but those calls are not
  async-signal-safe (`signal-safety(7)`). Here the handler sets only a
  `volatile sig_atomic_t`, and a dedicated control thread reacts —
  the signal-safe refinement of the same sequence.

## Run it

```bash
podman compose -f compose.yml up --build   # or: ./demo.sh
./demo.sh                                   # the three acts
./demo.sh --keep                            # leave the stack up afterward
./demo.sh --clean                           # tear down
```

The first build compiles the gRPC chain (~5 min cold); a warm Conan cache
is far faster. The demo queries readiness with the in-image `health-probe`
via `podman exec`, and liveness with `curl` against the published HTTP
port — no host gRPC tooling needed.

## Files

| Path | Role |
|---|---|
| [`proto/echo.proto`](proto/echo.proto) | the trivial app service (`demo.health.EchoService`) |
| [`proto/health.proto`](proto/health.proto) | the standard `grpc.health.v1` protocol (for our probe) |
| [`src/health_svc.cpp`](src/health_svc.cpp) | the server: staged startup, liveness, readiness, shutdown |
| [`src/health_probe.cpp`](src/health_probe.cpp) | our minimal `grpc_health_probe` |
| [`CMakeLists.txt`](CMakeLists.txt) | codegen both protos; build both binaries |
| [`conanfile.py`](conanfile.py) | the gRPC trio (no other deps) |
| [`Containerfile`](Containerfile) | gRPC-trio builder; `ubi-minimal` + `curl` runtime |
| [`compose.yml`](compose.yml) | one hardened service; liveness as the healthcheck |
| [`demo.sh`](demo.sh) | the three acts |

## What "alive" and "ready" must NOT include

Liveness should fail only for conditions a restart actually fixes —
deadlocks, process-internal corruption. **Not** downstream-dependency
health: a liveness probe that fails when a database is unreachable causes
restart-storms across the fleet. Dependency trouble belongs in *readiness*
(stop taking traffic, keep the replica) or in metrics-driven alerts. And
keep probes *cheap* — a no-op, not a real query — or the probe traffic
itself becomes load. Those are the anti-patterns Doc 09 names; this
example is built to avoid them.
