---
title: "Observability & Profiling: Grafana Stack, perf, eBPF"
order: 10
description: A single `podman compose up` brings up Prometheus, Tempo, Loki, Mimir, and Grafana. Once your service is wired up, profiling shifts from a question to an answer.
duration: 15 minutes
---

## Learning objectives

By the end of this section you can:

- Bring up Grafana + Prometheus + Tempo + Loki + Mimir with one
  compose file and explain what each piece does.
- Instrument a C++ service with OpenTelemetry (metrics, traces,
  and logs) such that all three flow into the right backend
  without per-component glue code.
- Run `perf record` and `perf report` against a process running
  inside a Podman container.
- Write a `bpftrace` probe that fires when a specific syscall
  exceeds a latency threshold, and read its output as a
  histogram.

## Diagram

{% include excalidraw.html name="10-observability-otel-stack" caption="The Grafana observability stack: Prometheus + Tempo + Loki + Mimir + Grafana, in one compose graph" %}

## Planned content

- Why this combination: each tool owns one signal type
  (Prometheus = metrics, Tempo = traces, Loki = logs, Mimir =
  long-term metrics), Grafana stitches them together. Single
  vendor's open-source stack, single auth model.
- The compose file walked top to bottom; what each service is
  for; the data-flow diagram.
- C++ OpenTelemetry: SDK setup, exporter selection (OTLP/gRPC for
  metrics + traces, file or `stdout` for logs picked up by
  Promtail/Loki).
- `perf record` against a containerized process: needs the host
  kernel symbols; `--privileged` or the `CAP_PERFMON` capability;
  the right path to the binary inside the namespace.
- eBPF tooling: `bpftrace` for ad-hoc, `bcc-tools` for
  pre-built probes (`opensnoop`, `runqlat`, `tcpconnlat`).
  Running them against a rootless Podman process: what's
  required (host root or `CAP_BPF`), what works.

## Demo

[`examples/demo-04-observability/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/demo-04-observability)
brings up the full stack alongside an OTel-instrumented C++
service from §7. Pre-provisioned Grafana dashboards show metrics,
traces, and logs from the running service. A second script runs
`bpftrace` probes against the container and writes the histograms
into Loki for cross-correlation.

## For deeper coverage

- Enberg, *Latency*, ch. 8 (measurement and observability)
- The `bpftrace` reference guide; `bcc-tools` `iovisor/bcc`
  README

## What's next

§10 turns the workload up: now there are *two* tenants on the
host. What happens?
