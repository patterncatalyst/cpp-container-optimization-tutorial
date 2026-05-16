# Teaching points captured during build-out

A running collection of diagnostic patterns, mini-essays, and content
nuggets that emerged during demo development and should be promoted
into the appropriate `_drafts/` prose sections during the section
buildout phase.

Each entry has a **suggested home** (which section's prose it belongs
in eventually), a **trigger** (the round where it surfaced), and the
content itself in roughly-publication-ready form. When the section
prose is being written, these can be pulled in mostly verbatim,
adapted for tone and cross-references.

This file is forward-looking content, not a record of past rounds —
that's `reconciliation-plan.md`. Items here haven't been folded into
prose yet.

---

## Tail-latency causes in an otherwise-fast HTTP server

**Suggested home:** §10 (Observability & Profiling) prose, with
cross-references from §11 (Noisy Neighbors) and §13 (Networking).

**Trigger:** Demo-06 r84 verification, where TCP_NODELAY fixed the
p50 (200µs) but a small tail remained — 35 timeouts and 4 outliers
near 1.5s out of 461,438 total requests (~0.0076% error rate).

**Context for the prose:** even after fixing the obvious HTTP
defaults (keep-alive, thread pool, Nagle), real services show tail
latency from sources you can't see in single-metric summaries. Five
plausible mechanisms, none distinguishable from hey output alone —
which is exactly why §10's observability story exists.

### The mini-essay (publishable as-is)

When you run a microbenchmark and the average looks great but the
tail looks suspicious, the question shifts from "is this fast?" to
"what is making this *occasionally* slow?" Five common causes, in
rough order of how often they show up in practice:

**1. Allocator deferred work.** mimalloc has lazy free-list
reclamation; glibc's `malloc` has arena rebalancing across threads;
jemalloc has periodic decay-purging. When a particular request
happens to trigger one of these housekeeping operations, that
request pays for cleanup that benefited the previous N requests.
The bookkeeping isn't free, it's just deferred. Variants of the
same workload using different allocators will have different tail
signatures here — which is itself one of the things demo-06's
side-by-side comparison is designed to expose.

**2. Kernel CFS scheduler.** With 50 hey clients, 16 httplib
workers, the operating system, your IDE, your browser, and a
display compositor all competing for CPU time, the Linux Completely
Fair Scheduler occasionally has to make someone wait. Usually this
is single-digit milliseconds, but a particularly unlucky multi-
process pile-up can produce hundreds-of-millisecond gaps. CFS is
fair on average, not bounded in the worst case. `sched-stat` and
`perf sched record` are the diagnostic tools.

**3. TCP-level retransmits.** Even with `TCP_NODELAY` disabling
Nagle, occasional packet loss or kernel buffer pressure causes the
RTO (retransmission timeout) machinery to kick in. The first
retransmit happens around 200ms after the lost packet; subsequent
retransmits use exponential backoff (400ms, 800ms, 1.6s...). A
single retransmit per request can dominate latency for the
unlucky few. `ss -tin` (with `-i` for the internal congestion-
control info) shows retransmit counters per connection.

**4. Page faults and minor page reclaim.** Linux's page cache
isn't free — the kernel occasionally reclaims pages that haven't
been touched recently, even within an active process's working
set. If a worker thread's stack, the allocator's arena, or a
piece of the httplib state machine gets paged out and faulted
back in at an unlucky moment, the request stalls long enough to
be visible in the tail. `perf trace -e 'pf:*'` captures the
events; `/proc/[pid]/status` exposes the running counters.

**5. Container runtime overhead.** Rootless podman accumulates
small overheads that mostly compound silently: cgroup v2 batches
accounting operations occasionally; SELinux audit decisions add
microseconds per syscall that compound under tight scheduling;
the rootless slirp4netns network stack does TCP in userspace,
adding a context switch per packet. None of these is
individually large, but during a coincidence of two or three the
result can be a 200-500ms blip. `podman stats` and
`bpftrace -e 'kprobe:cgroup_*'` are useful diagnostics.

**6. Synchronous OTel SDK exporters.** *(Added during r88
analysis.)* If the service uses OpenTelemetry's `Simple*`
processors for spans or logs, each `span->End()` or
`EmitLogRecord` blocks on a gRPC export round-trip — typically
~100 µs on localhost, much more if the collector is overloaded
or the network has retransmits. Under sustained load the export
queue itself backs up, producing visible tail latencies of
hundreds of milliseconds to multiple seconds. The fix is to use
`Batch*` processors, which decouple export from the request path.
See the separate "OpenTelemetry SDK processor choice" entry in
this file for the full story.

**Why this matters for a tutorial:** you can't distinguish these
five causes from hey output alone. Hey shows you that requests
took longer than expected. It doesn't show *why*. That's exactly
what the observability layer is for — per-cause histograms in
Tempo, per-system metric drilldowns in Mimir, structured logs in
Loki. Different mechanisms have different signatures in the
telemetry, and the talk's §10 covers reading those signatures.

**The bigger principle:** tail latency is a separate concern from
average latency. p50 (median) and p99.99 (deep tail) often tell
completely different stories about the same service. Some
workloads care about both. Some care only about throughput, which
is governed by average. Some care only about predictability,
which is governed by tail. The talk's framing throughout is that
performance is not a scalar.

### Cross-references for the eventual prose

- **§7 (Memory Management):** allocator-deferred-work mechanism →
  reference demo-06's side-by-side comparison as the worked example
- **§9 (gRPC / I/O):** TCP retransmit mechanism → reference any
  io_uring or async-grpc demo's tail in §10
- **§11 (Noisy Neighbors):** CFS scheduler mechanism → reference
  cgroup isolation as the mitigation
- **§13 (Networking):** rootless podman networking overhead →
  reference veth-pair / virtual-bridge discussion as background
- **Latency book ch.3 (Enberg):** the "general-purpose allocator
  tax" thesis pairs with #1 in the list above
- **C++ High Performance 2e ch.7 (Andrist & Sehr):** allocator-
  aware containers discussion pairs with #1
- **Stuart Cheshire, "It's the Latency, Stupid":** referenced
  separately in G-36 (Nagle), but the broader argument about why
  tail latency matters applies here too

### Diagnostic signature table

| Cause | Typical magnitude | First-look diagnostic | Confirmation |
|---|---|---|---|
| Allocator deferred work | 100µs – 50ms | `perf record -p $pid` shows time in allocator internals | `MALLOC_CONF=stats_print:true` (jemalloc), `MIMALLOC_VERBOSE=1`, glibc's `MALLOC_CHECK_=3` |
| CFS scheduler | 1ms – 500ms | `dstat -t --proc-count --cpu` shows the steal | `/proc/$pid/sched`, `perf sched record` |
| TCP retransmit | 200ms – 3s | `ss -tin` retransmit counter | `tcpdump` for the connection |
| Page faults | 100µs – 50ms | `/proc/$pid/status` major/minor counters | `perf trace -e 'pf:*'` |
| Container runtime | 100µs – 200ms | `podman stats` and event-loop pauses | `bpftrace` on cgroup/audit kprobes |
| OTel Simple* processor | 100µs – 10s (queue backup) | Throughput drop on instrumentation; `perf record` shows time in `grpc::CompletionQueue::Next` | Switch to Batch* processor and measure |

---

## OpenTelemetry SDK processor choice: Simple vs Batch

**Suggested home:** §10 (Observability & Profiling) prose, very early —
this may be the single most consequential production-instrumentation
decision the talk covers, and deserves a dedicated subsection before
any Tempo/Mimir/Loki coverage.

**Trigger:** Demo-06 r87 verification — switching from `--serve` mode
(no telemetry) to `--serve` + OTel instrumentation collapsed
throughput from **18,469 req/s to 2,170 req/s** (8.5× drop), with p50
jumping from **200 µs to 2.7 ms** (13× increase). The same allocator
differences demo-06 was built to measure became invisible under the
per-request OTel cost: all three variants posted identical numbers
because the workload's 10 µs of allocator work was buried under
~250 µs of synchronous gRPC export per request.

r88 switched both SpanProcessor and LogRecordProcessor from Simple
to Batch variants and recovered most of the throughput. The contrast
makes this one of the cleanest "instrumentation is not free"
demonstrations available.

### The mini-essay (publishable as-is)

OpenTelemetry's processor abstraction sits between the API-level
calls (`span->End()`, `logger->EmitLogRecord()`, `counter->Add()`)
and the wire-format exporters (OTLP/gRPC, Jaeger, Zipkin, etc.).
The processor decides *when* data crosses from the in-process
buffer to the network exporter. OpenTelemetry-cpp ships two
implementations of this decision for spans and for logs:

**SimpleSpanProcessor / SimpleLogRecordProcessor**: synchronous,
one-at-a-time export. Every `span->End()` call blocks until the
exporter finishes serializing the span, opening a gRPC channel
(or reusing one), writing the request, and reading the response.
Same for every `EmitLogRecord` call. The hot path becomes
serialized network I/O.

**BatchSpanProcessor / BatchLogRecordProcessor**: asynchronous,
queue-and-batch export. Every `span->End()` enqueues the span
into a fixed-size in-memory queue (typically a lock-free MPSC
ring). A background thread drains the queue every N milliseconds
OR when it fills past a high-water mark, exporting whatever it
finds as one gRPC call. The hot path becomes a queue insertion
plus an atomic counter.

The naming suggests the choice doesn't matter much. The reality
is that this is the single biggest performance knob in OTel-cpp
instrumentation.

**Demo-06's numbers, side by side:**

| Config | Throughput | p50 | p99 | Notes |
|---|---|---|---|---|
| No OTel (r84) | 18,469 req/s | 200 µs | 400 µs | baseline |
| OTel Simple* (r87) | 2,170 req/s | 2.7 ms | 25.9 ms | 8.5× drop |
| OTel Batch* (r88) | ~10–15k req/s (TBD) | ~300–500 µs (TBD) | ~1–3 ms (TBD) | recovers most |

The Simple→Batch transition is the difference between "your service
runs ten times slower because you turned on observability" and "your
service runs the same speed with full traces, metrics, and logs."
The Simple processor was *never* meant for production. The OTel-cpp
docs and many tutorials present it first because it's easier to
demonstrate (spans show up immediately in the backend), and because
at hello-world traffic volumes (1 req/s, 10 req/s) the overhead is
invisible. At 1,000+ req/s, it dominates.

**Why the Simple* processors exist at all:**

They're for development and testing. When you want every span
visible in Grafana within milliseconds (not 5 seconds), the Simple
processor delivers that. For trace debugging, for the first 30
seconds of a new service rollout, for unit tests that assert spans
were emitted — Simple is the right tool. For anything user-facing,
Batch is the default.

**Caveat: metrics are different and don't have this problem.**

`PeriodicExportingMetricReader` is *already* a batch-like
implementation by design. It exports the accumulated metric state
every 5 seconds (default), regardless of how many `counter->Add()`
or `histogram->Record()` calls happened in that window. There is
no "Simple" metric reader analog because metrics fundamentally
aggregate, and aggregation makes per-call export nonsensical.

Demo-06's metrics didn't suffer the throughput collapse spans and
logs caused. That's a useful detail to call out: not every signal
in your telemetry pipeline carries the same per-call cost. Logs
and spans are point events (each one must be transmitted); metrics
are accumulators (one transmission covers thousands of operations).

**The fix is mechanically simple:**

```cpp
// FROM (synchronous, ~100µs per span):
auto processor = sdk_t::SimpleSpanProcessorFactory::Create(std::move(exporter));

// TO (asynchronous, ~5µs per span):
sdk_t::BatchSpanProcessorOptions opts;  // defaults are fine
auto processor = sdk_t::BatchSpanProcessorFactory::Create(
    std::move(exporter), opts);
```

Same shape for `BatchLogRecordProcessor`. The default options
(2048-entry queue, 5-second schedule, 512-span batches) are sensible
for most workloads; tune if you have specific latency or memory
constraints.

**The bigger principle:**

Instrumentation is not free, and "off-by-default" is meaningless if
the default-when-on is the wrong choice. The decision between Simple
and Batch is a deliberate trade-off between *visibility latency*
(milliseconds vs. 5 seconds — how fast a new event shows up in
Grafana) and *request-path overhead* (~100 µs vs. ~5 µs per
signal). Almost every production service should choose Batch.
Almost every tutorial uses Simple.

This is itself the §10 hook: instrumentation isn't a checkbox.
Every signal you emit, every processor you wire up, every exporter
you configure is a performance decision. The talk's framing
throughout is "performance is not a scalar" — and here, the same
phrase applies to the *cost of observing* performance. The act of
measurement perturbs the measurement.

### Cross-references for the eventual prose

- **§10's own coverage:** lead with this decision before any specific
  Tempo/Mimir/Loki UI walkthrough; people need to know why the
  defaults will hurt them
- **§7 (Memory):** demo-06's r87 vs r88 contrast — allocator
  differences were *masked* by Simple processor overhead; once OTel
  was buried under 250 µs of synchronous network work, the actual
  workload differences became invisible. Same lesson as the
  cache-sensitivity story: measurement infrastructure can dominate
  the thing it's trying to measure
- **§9 (gRPC):** the OTel exporter uses gRPC internally; the same
  per-call overhead story applies to any user-code gRPC client that
  doesn't batch its requests
- **§14 (kernel parameters):** Batch processor queue sizing is the
  same conceptual decision as TCP listen backlog sizing — large
  enough for expected bursts, small enough to bound memory, with
  policy for what happens at overflow
- **Tail-latency causes (other entry in this file):** when OTel
  Simple processors are involved, the export queue becomes a 6th
  cause of tail-latency stalls

### Diagnostic for "is my Simple processor killing my server?"

If your service has OTel instrumentation and shows:

- p50 in the millisecond range when the workload itself is microseconds
- Throughput an order of magnitude below expected
- `perf record` shows time in `grpc::CompletionQueue::Next` or
  `WriteAndCommit` paths
- CPU profile shows ~20–40% of time in gRPC export

You're hitting Simple processor overhead. Switching to Batch is
nearly always the right answer. It's a one-line change per signal
type.

```cpp
// Spans:
sdk_t::BatchSpanProcessorOptions opts;
auto processor = sdk_t::BatchSpanProcessorFactory::Create(std::move(exporter), opts);

// Logs:
sdk_l::BatchLogRecordProcessorOptions opts;
auto processor = sdk_l::BatchLogRecordProcessorFactory::Create(std::move(exporter), opts);
```

---

## (Future teaching-points entries go here.)

When a new diagnostic pattern or content nugget surfaces during
build-out, add it here as another `## ...` section following the
same structure: suggested home, trigger, mini-essay, cross-
references. Keep each entry self-contained so it can be promoted
to prose independently.
