---
title: "Observability & Profiling: OTel, Grafana Stack, perf, eBPF"
order: 10
description: The single biggest performance knob in OpenTelemetry-cpp is the choice between SimpleSpanProcessor and BatchSpanProcessor — verified 8.5× throughput collapse with the wrong one. Plus the LGTM stack, perf and eBPF against containerized processes.
duration: "15 minutes"
---

## Learning objectives

By the end of this section you can:

- Pick the right OpenTelemetry SDK processor for your workload
  and explain mechanistically why the default-in-most-tutorials
  is wrong for production.
- Bring up Grafana + Prometheus + Tempo + Loki + Mimir with one
  compose file and explain what each piece owns.
- Instrument a C++ service with OTel such that metrics, traces,
  and logs all flow into the right backend without per-component
  glue code, and without paying a 10× per-request tax for the
  privilege.
- Run `perf record` against a process running inside a Podman
  container, and resolve symbols correctly across the namespace
  boundary.
- Write a `bpftrace` probe that fires when a specific syscall
  exceeds a latency threshold, and read its output as a
  histogram.
- Diagnose the production case: *"I added observability and my
  service got 10× slower — what happened?"*

## Diagram

{% include excalidraw.html name="10-observability-otel-stack" caption="OTel pipeline: C++ → OTel SDK → OTLP → Grafana stack." %}

## The single biggest knob

Most OpenTelemetry-cpp tutorials start with code that looks like
this:

```cpp
auto exporter = otlp::OtlpGrpcSpanExporterFactory::Create(options);
auto processor = sdk_t::SimpleSpanProcessorFactory::Create(std::move(exporter));
auto provider  = sdk_t::TracerProviderFactory::Create(std::move(processor));
```

Three lines. Looks fine. Works in the hello-world. **Will collapse
your throughput by an order of magnitude in production.**

We measured this directly in demo-06. The service is the same
across all rows of the table below — a tiny C++ HTTP server that
allocates a small data structure, sums some integers, and
returns. The only thing that changes is the OpenTelemetry
configuration:

| Config | Throughput | p50 | p99 |
|---|---|---|---|
| No OTel | 18,469 req/s | 200 µs | 400 µs |
| OTel `SimpleSpanProcessor` + `SimpleLogRecordProcessor` | **2,170 req/s** | **2.7 ms** | **25.9 ms** |
| OTel `BatchSpanProcessor` + `BatchLogRecordProcessor` | ~28,000 req/s | 200 µs | 1.8 ms |

The Simple processors caused an **8.5× throughput collapse** and
a **13× latency increase**. The Batch processors recovered fully
— and in fact slightly exceeded the no-OTel baseline within
run-to-run variance, because the workload is too small to make
batch-export overhead visible at all.

This is the single most consequential decision in OpenTelemetry-
cpp instrumentation, and the documentation buries it. Most
tutorials lead with Simple processors because they're easier to
demonstrate — spans show up in the backend in milliseconds, not
five seconds, which makes for satisfying screenshots. Almost
every production-quality service should use Batch.

## How the two processors actually differ

OpenTelemetry's processor abstraction sits between the API-level
calls (`span->End()`, `logger->EmitLogRecord()`) and the wire-
format exporters (OTLP/gRPC, Jaeger, Zipkin). The processor
decides *when* data crosses from the in-process buffer to the
network.

**SimpleSpanProcessor / SimpleLogRecordProcessor** is synchronous
and one-at-a-time. Every `span->End()` call blocks until the
exporter has serialized the span, opened (or reused) a gRPC
channel, written the OTLP request, and read the response. Same
for every `EmitLogRecord` call. Your request handler's hot path
becomes serialized network I/O.

The per-span cost is roughly:

1. Serialization to OTLP protobuf (~5-10 µs for a typical span)
2. gRPC frame construction (~10-20 µs)
3. Write to socket (~5 µs if the connection is established)
4. Wait for response acknowledgment (~50-150 µs round-trip
   inside the host)
5. Deserialize response (~5 µs)

Total: 75-200 µs per span. If your request emits 3 spans (an
inbound HTTP span, a downstream RPC span, a span for the
business logic), you've added 225-600 µs of *blocking work* to
every single request. On a workload whose actual work takes 200
µs, that's a 2-4× p50 increase. On a workload whose p99 was
already on a knife edge, that's the difference between healthy
and on-call.

**BatchSpanProcessor / BatchLogRecordProcessor** is asynchronous
and queue-and-batch. Every `span->End()` call enqueues the span
into a fixed-size in-memory queue (a lock-free MPSC ring in
practice). A background thread drains the queue every 5 seconds
(default) OR when it fills past 512 entries (default), exporting
whatever it finds as one gRPC call covering the whole batch.

The per-span cost on the hot path is roughly:

1. Atomic enqueue into ring (~1-2 µs)
2. That's it.

Total: a few microseconds per span. The 200 µs of OTLP
serialization, gRPC framing, and network I/O still happens — but
not on your request handler's call stack. It happens in the
background thread, amortized over hundreds of spans per export
cycle.

## When to use which

| Mode | When | Why |
|---|---|---|
| **Batch** | Production services (almost always) | Hot path stays fast; observability backend gets data within 5 seconds; throughput-neutral |
| Simple | Development, testing, debugging | Need spans to appear in Grafana within milliseconds, not seconds, while you're staring at it |
| Simple + 1% sample | Incident response | Some real-time visibility into the running service while paying ~1% of the Simple overhead |
| Batch with small queue | Memory-constrained workloads | Bounded queue size prevents OOM if export falls behind |

The default option of the OTel-cpp SDK is configurable; the
default in most *example code* is Simple. Always look. Always
override.

## Metrics are different

There is no `SimpleMetricReader` analog because metrics don't
need one. The `PeriodicExportingMetricReader` exports the
accumulated metric state every 5 seconds (default), regardless
of how many `counter->Add()` or `histogram->Record()` calls
happened in that window. **Metrics fundamentally aggregate, and
aggregation makes per-call export nonsensical.**

This is why demo-06's metrics didn't suffer the throughput
collapse — only spans and logs did. If you're instrumenting and
your dashboards rely entirely on metrics (counters, gauges,
histograms), you can sleep easier. If you're shipping traces and
logs to a backend, the Batch decision is non-negotiable.

The takeaway is that "the cost of observability" is not a single
number — it depends sharply on which signals you emit and how
their processors are wired. One signal in your pipeline can
dominate; the other two can be invisible. Diagnose with the
chain in mind, not the abstraction.

## The fix

```cpp
// SPANS — replace this:
auto processor = sdk_t::SimpleSpanProcessorFactory::Create(std::move(exporter));
// with this:
sdk_t::BatchSpanProcessorOptions span_opts;     // defaults are fine
auto processor = sdk_t::BatchSpanProcessorFactory::Create(
    std::move(exporter), span_opts);

// LOGS — replace this:
auto log_processor = sdk_l::SimpleLogRecordProcessorFactory::Create(std::move(log_exporter));
// with this:
sdk_l::BatchLogRecordProcessorOptions log_opts; // defaults are fine
auto log_processor = sdk_l::BatchLogRecordProcessorFactory::Create(
    std::move(log_exporter), log_opts);
```

Default `BatchSpanProcessorOptions`: 2048-entry queue, 5-second
schedule, 512-span batches. Default `BatchLogRecordProcessorOptions`
is similar. These are reasonable starting points; tune only if
you have specific latency or memory constraints worth
characterizing.

## The stack: Prometheus, Tempo, Loki, Mimir, Grafana

The observability stack used in demo-04 and demo-06 follows
Grafana Labs' open-source layout. Each component owns one signal
type and exposes one query language. Grafana stitches them
together.

| Component | Signal | Owns | Why this not that |
|---|---|---|---|
| **Prometheus** | Metrics | Short-term (~15d) time-series, PromQL queries | The reference open-source TSDB; broad collector ecosystem |
| **Tempo** | Traces | Trace store + lookup by trace ID, TraceQL queries | Cheaper than Jaeger at scale because traces are stored as blobs, not indexed events |
| **Loki** | Logs | Log store + label-based filter, LogQL queries | "Prometheus for logs" — labels are indexed, log bodies are not, which keeps storage and query costs predictable |
| **Mimir** | Metrics (long-term) | Cloud-native long-term Prometheus-compatible store | Used when you want metrics retention measured in months, not days |
| **Grafana** | UI / correlation | Multi-source dashboards; click a metric anomaly → jump to the trace → jump to the logs | The user-facing layer that makes the signal-by-signal split useful |

This is one of several possible stacks (the OTel docs cover
Jaeger, Zipkin, SigNoz, etc.). We use LGTM because Grafana is
the de facto open-source dashboarding standard, and the four
backends share authentication, tenancy, and operator patterns —
fewer per-component decisions when you're standing up the first
deployment.

The whole stack comes up with `podman compose up -f compose-lgtm.yml`
in demo-04. The compose file uses Grafana's `otel-lgtm` image,
which packages all five components in a single container — not
the right shape for production (you want each as a separate
service with its own storage and scaling), but exactly the right
shape for a tutorial demo and for local development.

## Instrumenting a C++ service with OpenTelemetry

The minimum viable C++ OTel setup (using the Conan-packaged SDK)
looks like:

```cpp
#include <opentelemetry/sdk/trace/batch_span_processor_factory.h>
#include <opentelemetry/sdk/trace/tracer_provider_factory.h>
#include <opentelemetry/exporters/otlp/otlp_grpc_exporter_factory.h>

namespace sdk_t = opentelemetry::sdk::trace;
namespace otlp  = opentelemetry::exporter::otlp;

void init_tracing() {
  otlp::OtlpGrpcExporterOptions exporter_options;
  exporter_options.endpoint = "http://otel-collector:4317";

  auto exporter  = otlp::OtlpGrpcSpanExporterFactory::Create(exporter_options);
  auto processor = sdk_t::BatchSpanProcessorFactory::Create(
      std::move(exporter), sdk_t::BatchSpanProcessorOptions{});
  auto provider  = sdk_t::TracerProviderFactory::Create(std::move(processor));
  opentelemetry::trace::Provider::SetTracerProvider(provider);
}
```

The same pattern with `_l::` namespaces for logs and the
`PeriodicExportingMetricReader` for metrics. All three signals
share the OTLP/gRPC transport and the same backend endpoint;
collector-side routing fans them out to Tempo, Loki, and
Prometheus respectively.

The thing demo-04 and demo-06 both demonstrate is that **the
hard part is not the SDK setup; it's choosing the right
processor**. With Batch processors and reasonable defaults,
adding OTel to a C++ service costs almost nothing. With Simple
processors, you've added 200 µs per signal to every request.
Look at the processor before you tune anything else.

## `perf record` against containerized processes

`perf` works against any process whose PID is visible from the
host. For a rootless Podman container, the PID is visible — the
container is just a tree of processes under the user's session,
with its own user namespace and mount namespace but sharing the
host kernel.

The two issues that bite are **symbol resolution** and
**privileges**.

Symbol resolution is harder because the binary in the
container's mount namespace isn't at the same path the host
sees. `perf record -p <pid>` captures samples by virtual address
but resolves symbols from the *host's* view of the filesystem,
which doesn't contain the container's `/usr/local/bin/myservice`.

The workaround is to use the container's filesystem image when
analyzing:

```bash
# Capture inside the container (binary is at the path perf finds):
podman exec my-service perf record -F 99 -p 1 -- sleep 30
podman cp my-service:/tmp/perf.data ./
perf report --no-children -i ./perf.data
```

Or — for ad-hoc sampling from outside — provide the path-prefix
hint:

```bash
# Outside the container, knowing the binary path inside:
perf record -F 99 -p <pid> -- sleep 30
perf report --symfs $(podman mount my-service)
```

Privileges: the `perf_event_paranoid` sysctl controls what's
allowed. The default on Fedora is 2, which means non-root
processes can only profile their own threads. For cross-process
profiling you need either root or `CAP_PERFMON` (and
`CAP_SYS_PTRACE` for the kernel call-graph). Setting
`/proc/sys/kernel/perf_event_paranoid` to 1 system-wide allows
unprivileged profiling at the cost of a small information-
disclosure risk.

In demo-04 the perf invocation is wrapped in a sidecar
container that has `CAP_PERFMON` and shares the PID namespace
with the target service. The perf data lands in a bind-mounted
volume that the analysis script reads from outside.

## eBPF: `bpftrace` and `bcc-tools`

eBPF is the modern alternative to `perf` for many use cases.
Where `perf record` samples a running process at a fixed
frequency and processes the samples afterward, eBPF programs
attach to kernel events (syscalls, network packets,
scheduler decisions) and run **inside the kernel** at the
event boundary. They produce data continuously, with no
sampling artifacts, and at a fraction of `perf`'s overhead for
many workloads.

`bpftrace` is the awk-of-eBPF — short one-liners for ad-hoc
investigations. Example: histogram of `read()` syscall latencies
across the system, broken down by PID:

```bash
sudo bpftrace -e '
  tracepoint:syscalls:sys_enter_read { @start[tid] = nsecs; }
  tracepoint:syscalls:sys_exit_read /@start[tid]/ {
    @latency[pid] = hist(nsecs - @start[tid]);
    delete(@start[tid]);
  }
'
```

`bcc-tools` is the same machinery packaged as pre-written
investigations: `runqlat` (scheduler runqueue latency
histogram), `opensnoop` (every `open()` syscall with arguments),
`tcpconnlat` (TCP connection establishment latency), etc.
Production diagnosis often starts with `runqlat` to see whether
threads are queueing for CPU (the `cpu.weight` symptom from §11)
or `tcpconnlat` to see whether downstream RPCs are slow at the
connection layer (the gRPC tuning angle from §9).

The rootless container caveat: eBPF programs need `CAP_BPF` and
typically the host's tracefs at `/sys/kernel/debug/tracing/`.
That means either running the eBPF tool with sudo on the host
(simplest), or running a privileged sidecar container with the
right capabilities (production-friendly but more setup). Demo-04
shows the sidecar pattern; for ad-hoc investigation, sudo on
the host is fine.

## Production diagnostic: is your instrumentation killing you?

The Simple-vs-Batch story has a clean diagnostic signature.
Three signs that point at the SpanProcessor or
LogRecordProcessor as the dominant cost:

1. **p50 is in the millisecond range when the workload itself
   is microseconds.** If your service does ~200 µs of work and
   your p50 is 2-3 ms, something on the request path is adding
   ~2.5 ms per request. OTel Simple is a strong suspect.

2. **Throughput is roughly constant across workload size.** If
   `iters=1` and `iters=100` produce the same req/s, then
   per-request overhead is dominating workload time. Tells you
   the instrumentation cost is the constant, not the workload.

3. **`perf record` against the server shows time in
   `grpc::CompletionQueue::Next` and `OtlpGrpcExporter::Export`
   *in the request handler's call stack*.** These should be in
   the background batch-export thread, not in the handler. If
   they're in the handler, you're synchronous-exporting.

The fix is always the same: switch to Batch processors. The
question is whether you can afford 5 seconds of visibility
latency on individual signals — for production observability,
yes. For debugging an active incident, sometimes no (use Simple
with a 1% sample rate during the debugging window).

## Why this is a C++ concern

OpenTelemetry has SDKs in every major language; the
Simple-vs-Batch distinction exists in all of them. But two
reasons make it especially sharp for C++:

First, **C++ workloads are often the ones where the OTel cost
matters**. A Python service whose handlers each take 50 ms of
synchronous work won't notice 200 µs of OTel export per request
— it's a 0.4% overhead. A C++ service whose handlers take 200 µs
will see that same 200 µs as a **2× p50 increase**. The
relative cost of OTel scales inversely with the speed of your
application; the faster your code, the more your instrumentation
choices matter.

Second, **the gRPC stack OTel uses is the same one your
application probably uses for its own RPCs**. The lessons about
async vs. sync gRPC calls from §9 apply here: any time you have
a synchronous gRPC call on your request path, you're paying for
network I/O on the hot path. The OTel exporter is just a
particularly stealthy instance of the same problem, because the
gRPC call is hidden inside the SDK and most developers never
notice it's there.

## Demo

[`examples/demo-04-observability/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/demo-04-observability)
brings up the full Grafana LGTM stack alongside an OTel-
instrumented C++ service. Pre-provisioned Grafana dashboards
show metrics, traces, and logs from the running service, all
correlated via trace ID. Three Containerfile targets demonstrate
the cost difference: a Simple-processor variant (the "before"),
a Batch-processor variant (the "after"), and a no-OTel control.
The same demo also runs `bpftrace` probes against the service
container and writes the syscall-latency histograms into Loki
for cross-correlation against the application traces.

[`examples/demo-06-memory-and-allocators/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/demo-06-memory-and-allocators)
in serve mode shows the same lesson with a different workload —
the verified r88 numbers cited above are from that demo's
post-fix run. Both demos are independent demonstrations of the
same OTel processor decision; pick either, the conclusion is
the same.

## For deeper coverage

- Enberg, *Latency*, ch. 8 (measurement and observability; the
  Heisenberg-uncertainty framing that "measuring perturbs the
  measurement" applies very literally to OTel processors)
- Andrist & Sehr, *C++ High Performance*, ch. 3 — the
  performance-measurement chapter, complementary to this
  section's "OTel as instrumentation cost" angle
- [The `bpftrace` reference guide](https://github.com/iovisor/bpftrace)
  and [`bcc-tools` README](https://github.com/iovisor/bcc) for
  the syntax and the ready-made investigations
- [OpenTelemetry-cpp documentation](https://opentelemetry.io/docs/languages/cpp/)
  for SDK structure and Conan packaging; the official examples
  default to Simple processors, so always override
- [Grafana Tempo](https://grafana.com/oss/tempo/),
  [Loki](https://grafana.com/oss/loki/), and
  [Mimir](https://grafana.com/oss/mimir/) project pages for the
  data-flow and scaling models

## What's next

§11 takes the workload up: there are now *two* tenants on the
host, both running C++ services, both well-behaved. Neither is
buggy. The kernel scheduler does exactly what it's supposed to.
And the latency-sensitive one's tail goes from 2 ms to 25 ms.
What happened, and what to do about it.
