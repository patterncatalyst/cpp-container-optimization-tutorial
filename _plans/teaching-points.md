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

---

## (Future teaching-points entries go here.)

When a new diagnostic pattern or content nugget surfaces during
build-out, add it here as another `## ...` section following the
same structure: suggested home, trigger, mini-essay, cross-
references. Keep each entry self-contained so it can be promoted
to prose independently.
