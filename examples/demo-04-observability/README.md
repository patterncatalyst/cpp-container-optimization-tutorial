# Demo 4 — Observability stack with OpenTelemetry

Tutorial section: §9 (Observability and profiling)

## What this demo shows

A small C++ HTTP service instrumented with OpenTelemetry (logs, metrics,
traces) running alongside the **`grafana/otel-lgtm`** all-in-one
observability container from `observability/`. That single image
bundles the receiving end of all three OTLP signals:

- **Tempo** — accepts OTLP traces from the service
- **Loki** — accepts OTLP logs from the service
- **Prometheus** — accepts OTLP metrics from the service
- **Grafana** — pre-configured datasources for the three above; one
  starter dashboard is mounted into Grafana's provisioning directory

A `bpftrace` script you can run on the host complements the
application metrics with kernel-level events (sched switches,
futex waits) — the fourth observability dimension that lives
outside the container.

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
- `grafana/otel-lgtm` runs every component in a single container —
  perfect for a tutorial, not a production deployment topology.
  §9's prose covers what a production split looks like.
