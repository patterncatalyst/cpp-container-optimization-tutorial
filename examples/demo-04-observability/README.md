# Demo 4 — Observability stack with OpenTelemetry

Tutorial section: §9 (Observability and profiling)

## What this demo shows

A small C++ HTTP service instrumented with OpenTelemetry (logs, metrics,
traces) running alongside the full Grafana stack from `observability/`:

- **Prometheus** — scrapes the service's `/metrics`
- **Mimir** — long-term metric storage (Prometheus remote-write target)
- **Tempo** — OTLP trace receiver
- **Loki** — OTLP log receiver
- **Grafana** — pre-provisioned datasources and one starter dashboard

Plus a `bpftrace` script you can run on the host to see kernel-level
events (sched switches, futex waits) during the workload, demonstrating
the fourth observability dimension that lives outside the container.

## Run it

```bash
./demo.sh                   # bring up everything, run a workload, leave it running
./demo.sh --workload-only   # assume the stack is up; just generate load
./demo.sh --bpftrace        # also run the bpftrace probes (needs sudo)
./demo.sh --clean           # tear it all down
```

After it's up, open Grafana at `http://127.0.0.1:3000` (anonymous viewer
enabled by the provisioning config) and look at the "Demo overview"
dashboard.

## Wiring

The stack lives at the repo root in `observability/`. This demo's
`compose.yml` includes that compose file via `extends:` so the same stack
is reusable from elsewhere if you want it.

## Caveats

- The OpenTelemetry C++ SDK is heavyweight; the build adds ~2-3 minutes.
  If you only want to see the dashboards, you can use
  `./demo.sh --workload-only` after bringing up the stack manually.
- bpftrace requires CAP_SYS_ADMIN (or root). The demo script runs the
  probes via `sudo bpftrace` and asks first.
- Mimir, Tempo, and Loki are all in single-binary mode for the demo;
  not a production deployment topology.
