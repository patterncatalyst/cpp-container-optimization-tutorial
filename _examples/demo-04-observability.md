---
title: "Demo 4 — Observability stack with OpenTelemetry"
description: "A small C++ HTTP service instrumented with OpenTelemetry (logs, metrics, traces) running alongside the **`grafana/otel-lgtm`** all-in-one observability container from `observability/`. That single image bundles the receiving end of all…"
order: 4
layout: example
sectionid: examples
permalink: /examples/demo-04-observability/
demo_dir: demo-04-observability
github_path: examples/demo-04-observability
---

> The full source for this demo lives in [`examples/demo-04-observability/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/demo-04-observability) — clone the repo, `cd` in, and `./demo.sh`.


Tutorial section: §10 (Observability & profiling)

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

## Why this matters

Production debugging without telemetry is guesswork. The three OTLP
signals — traces, metrics, logs — answer three different questions:

- **Traces** answer "what happened in this one request?". Spans
  capture the call tree from gRPC handler → DB query → outbound RPC
  with timing on each edge.
- **Metrics** answer "what's happening across all requests?". Counters,
  histograms, and gauges roll up into dashboards and alert thresholds.
- **Logs** answer "what does the service have to say about this?".
  Structured log lines with trace IDs link back to specific spans.

The C++ instrumentation has its own subtleties this demo surfaces:
the OTel C++ SDK is not the easiest to build, the BatchSpanProcessor
has a meaningful runtime cost (see demo-06 for the measurements),
and the OTLP exporter needs deadline-aware configuration so a slow
collector doesn't back-pressure the service. The bpftrace probes
illustrate where kernel-side visibility complements application
instrumentation — sched-switch counts and futex wait times don't
show up in any OTel signal but matter for tail-latency debugging.

§10 of the tutorial develops the underlying patterns; this demo
gets you to a running Grafana dashboard so the prose stops being
abstract.

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

## What you'll see in Grafana

Three things, one per signal type:

- **Traces (Tempo).** Click any span in the "Traces" tab. The waterfall
  shows the gRPC handler at the top with child spans for the work
  inside — DB queries, outbound HTTP calls. Span attributes include
  `service.name`, `http.method`, `http.status_code`, and a
  `correlation_id` that ties this trace back to log entries.
- **Metrics (Prometheus via the OTLP receiver).** The "Demo overview"
  dashboard panel shows RPS, p50/p95/p99 latency, error rate. Under
  load the histograms fill in; idle, they're flat.
- **Logs (Loki).** Log lines emitted by the service show up with the
  same `correlation_id` field, letting you pivot from "this slow span"
  to "what did the service log during it?".

With `--bpftrace`, a fourth window: sched-switch counts per CPU and
futex wait histograms. These complement OTel because they capture
events the C++ runtime can't see (kernel-side context switches,
mutex contention).

## How to interpret the output

- A flat trace waterfall (just the parent span, no children) means
  instrumentation is missing — you should see sub-spans for any
  external call. If you don't, the SDK's auto-instrumentation isn't
  wired up.
- Span IDs not matching across services means context propagation
  is broken — the W3C trace-context header isn't being forwarded.
  Check the gRPC client interceptor.
- p99 spikes coinciding with sched-switch spikes (bpftrace) usually
  means CFS throttling — see demo-05 for the isolation knobs that
  fix it.

## Wiring

The stack lives at the repo root in `observability/`. This demo's
`compose.yml` includes that compose file via `extends:` so the same
stack is reusable from elsewhere if you want it.

## Caveats

- The OpenTelemetry C++ SDK is heavyweight; the build adds ~2-3 minutes.
  If you only want to see the dashboards, you can use
  `./demo.sh --workload-only` after bringing up the stack manually.
- bpftrace requires CAP_SYS_ADMIN (or root). The demo script runs the
  probes via `sudo bpftrace` and asks first.
- `grafana/otel-lgtm` runs every component in a single container —
  perfect for a tutorial, not a production deployment topology.
  §10's prose covers what a production split looks like.
