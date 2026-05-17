---
title: "Networking & Kernel Parameters"
order: 9
description: What a veth pair actually costs, when `--network=host` is the right escape hatch, the small set of sysctls that move tail latency for C++ services, and the eBPF tooling for diagnosing network plumbing itself — bcc-tools, bpftrace, and bpftool.
duration: "15 minutes"
---

## Learning objectives

By the end of this section you can:

- Trace a packet from `clientA → clientA's veth → bridge →
  serverB's veth → serverB` and explain where the latency
  difference comes from compared to host networking.
- Decide when `--network=host` is worth the namespace
  simplification, when `slirp4netns` is hurting you, and when
  `pasta` is the upgrade path.
- Apply the small handful of sysctls that actually move tail
  latency for typical request/response services
  (`net.core.somaxconn`, `net.core.netdev_max_backlog`,
  `net.ipv4.tcp_tw_reuse`, `net.ipv4.tcp_no_metrics_save`).
- Tell which sysctls apply per-namespace and which apply only
  on the host — so you don't waste time setting a sysctl in
  the container that takes effect on the host.
- Use `bcc-tools` (`tcpconnect`, `tcpretrans`, `tcptop`,
  `tcpaccept`), `bpftrace`, and `bpftool` to see what's
  actually happening on the wire and in the kernel.

## Diagram

{% include excalidraw.html name="09-networking-veth-vs-host" caption="Packet path: veth+bridge vs slirp4netns vs --network=host." %}

## Where container networking latency actually comes from

The same TCP echo request, against the same server binary, on
the same host, with three different container networking modes:

| Mode | Per-request latency (rough) | Throughput cap |
|---|---|---|
| `--network=host` | ≈ bare-metal (0 ns added) | line-rate |
| `--network=bridge` (rootful default, veth+bridge) | +5-15 µs | ~30 Gbps |
| `--network=slirp4netns` (rootless default) | +100-1000 µs | ~1 Gbps |
| `--network=pasta` (rootless faster default) | +20-50 µs | ~10 Gbps |

The veth+bridge cost is real but small — tens of microseconds of
per-packet overhead from the in-kernel software switch and the
namespace-traversal bookkeeping. **The slirp4netns cost is two
orders of magnitude worse** because of an architectural choice:
slirp4netns runs a userspace TCP/IP stack that re-encapsulates
every packet, so every byte traverses two TCP/IP stacks.

This section is about understanding which mode you're paying
for, deciding when to escape it, and using the sysctls that
move the floor down further once you've picked one.

## The packet path under rootless networking — slirp4netns vs pasta

When you `podman run` without `--network`, **rootless containers
get a userspace networking stack by default**. Historically that
was `slirp4netns`; modern Podman (4.7+) ships `pasta` as a
faster alternative. Both exist because rootless containers can't
just `ip link add veth0` — that requires `CAP_NET_ADMIN` on the
host, which rootless processes don't have.

The slirp4netns path for an outbound packet:

```
your C++ code
  ↓ send() syscall
container netns: eth0 (a TAP device)
  ↓ packet copied to userspace via tap fd
slirp4netns process: userspace TCP/IP stack
  ↓ re-encapsulates, applies NAT, picks outbound interface
host kernel TCP/IP stack
  ↓ normal egress
network interface
```

Every packet pays the userspace TCP/IP round-trip. For
high-throughput services, slirp4netns adds milliseconds to p99
and caps throughput at gigabit speeds even on 10/25/100 GbE
hardware. **If you're seeing latency floors of "a few hundred
microseconds" you can't explain, check whether slirp4netns is
the network mode.**

`pasta` (from the passt project) is the same shape but built
around a more efficient packet-handling loop, dropping the
overhead from "hundreds of µs" to "tens of µs". It's the
right rootless default for Podman 4.7+ — if you have a recent
Podman, prefer `--network=pasta` over the slirp4netns default.

## veth + bridge — the kernel-level path

Rootful containers (or rootless containers with
`network_cmd=netavark` configured) use **veth pairs into a
software bridge**:

```
your C++ code
  ↓ send() syscall
container netns: eth0
  ↓ veth pair (in-kernel virtual link)
host netns: br0 (software bridge / Linux bridge)
  ↓ kernel bridge code looks up forwarding entry
  ↓ packet exits via host's outbound interface
network interface
```

The packet stays in the kernel the entire time. The veth pair
is "two ends of a kernel-internal virtual ethernet"; data
written to one end immediately appears at the other end's
receive queue. The bridge is a software switch implementing
802.1d forwarding entirely in the kernel.

Overhead: ~5-15 µs per packet from the extra namespace
traversal and the bridge forwarding lookup. For most C++
services that's well below the application-level cost of
handling a request; for ultra-low-latency workloads (high-
frequency trading, distributed consensus protocols) it can
be the dominant cost — at which point `--network=host` is the
right escape.

The kernel does this without copying packet data. The packet
buffer (`sk_buff`) is passed by reference through veth and
bridge code paths.

## `--network=host` — the escape hatch

`podman run --network=host` skips the network namespace
entirely: the container's processes share the host's network
stack. No veth pairs, no bridge, no slirp4netns.

| What you get | What you give up |
|---|---|
| Zero added per-packet overhead | port-collision isolation between containers |
| No NAT bookkeeping | network-policy isolation (containers see each other's connections in `/proc/net/tcp`) |
| Direct host MTU + offloads | port binding requires no port conflicts on the host |

When to reach for `--network=host`:

- High-throughput services where the 5-15 µs of veth+bridge
  overhead matters and you control the host's port allocation.
- Latency-sensitive measurement (benchmarks, load generators)
  where you want to remove network mode from the variable
  list.
- Single-tenant hosts where namespace isolation doesn't add
  security value.

When to not:

- Multi-tenant hosts (the whole point of namespaces is
  collision-free port allocation between tenants).
- Services that bind to wildcard addresses on default ports —
  the next container that does the same fails to start.
- Production unless you've measured the gap and decided the
  isolation cost is worth saving.

Demo-03 runs its gRPC service first under default networking,
then with `--network=host`, and prints the delta. On most
laptops the gap is in single-digit microseconds for p99 — real
but small.

## The sysctls that move tail latency

The Linux kernel exposes ~700 network-related sysctls. The
following four move tail latency on typical C++ request/response
services; most of the others move nothing observable:

**`net.core.somaxconn` (default 4096 on modern kernels, was
128 historically)**: maximum length of the listen-queue
backlog. `listen(fd, backlog)` is clamped to this value. On
high-fan-in services that get bursts of accepts, a small
somaxconn causes `connection refused` errors before the
application's accept loop ever sees them.

```bash
# Inspect
sysctl net.core.somaxconn
# Raise (host-level)
sudo sysctl -w net.core.somaxconn=65535
```

This is a **host-level** sysctl on modern kernels — setting it
inside the container has no effect. Set it on the host.

**`net.core.netdev_max_backlog` (default 1000)**: per-CPU
queue length for incoming packets between the NIC's softirq
and the kernel network stack. Under bursty incoming traffic
(short SYN floods, RPC fan-in), packets drop here before
reaching any TCP code path. Symptoms: TCP retransmits without
obvious explanation, p99 spikes during traffic bursts.

```bash
# Raise to 100k for high-fan-in workloads
sudo sysctl -w net.core.netdev_max_backlog=100000
```

Host-level. Verify with `cat /proc/net/softnet_stat` (3rd column
non-zero = drops).

**`net.ipv4.tcp_tw_reuse` (default 2)**: allow reuse of
sockets in `TIME_WAIT` state for new outbound connections.
Helps services that open many short-lived outbound connections
(an HTTP client hammering an upstream) avoid running out of
local source ports.

```bash
# Already enabled by default on modern kernels (value 2);
# value 1 enables it more aggressively
sysctl net.ipv4.tcp_tw_reuse
```

This sysctl is **per-network-namespace** — setting it inside
the container actually takes effect inside the container.
Different from `somaxconn`.

**`net.ipv4.tcp_no_metrics_save` (default 0)**: disable
caching of connection metrics in the route cache. Default 0
(metrics-saving enabled) speeds repeated connections to the
same peer; setting to 1 prevents the cache from latching
onto pessimistic estimates that took one bad packet to
develop. Rarely worth changing in steady-state services;
worth knowing for "TCP performance got worse after one
network blip and never recovered" diagnoses.

```bash
# Disable metrics caching (per-namespace)
sysctl -w net.ipv4.tcp_no_metrics_save=1
```

Two more worth knowing — `net.core.rmem_max` and
`net.core.wmem_max` control the maximum socket buffer sizes a
process can `setsockopt(SO_RCVBUF, SO_SNDBUF)` to. Defaults
on modern kernels (4 MiB) are usually fine; only worth
adjusting for services that explicitly request larger buffers
to handle high-bandwidth-delay-product paths.

**The sysctls that look productive but rarely move anything**:
`net.ipv4.tcp_congestion_control` (default `bbr` or `cubic`
depending on distro — both are fine for steady-state),
`net.core.busy_poll` / `net.core.busy_read` (useful only
for sub-microsecond latency workloads on dedicated cores),
`net.ipv4.tcp_low_latency` (deprecated; was a no-op for years
before removal).

## Per-namespace vs host-only sysctls

A common source of frustration: setting a sysctl inside a
container and seeing no effect because the sysctl is actually
host-scoped. The rule of thumb:

| Sysctl prefix | Scope |
|---|---|
| `net.ipv4.tcp_*` | per-namespace (settable inside containers) |
| `net.ipv4.ip_*` | mostly per-namespace |
| `net.core.*` | mixed — many are host-only |
| `net.netfilter.*` | host-only |

To check authoritatively which side has effect, run
`sysctl <name>` inside the container and on the host. If they
show *different* values, it's per-namespace. If they're always
equal regardless of what you set inside, it's host-only.

For a rootless Podman container, sysctl writes inside the
container also require `--sysctl net.foo.bar=value` on the
`podman run` line — direct `sysctl -w` inside fails because
sysctl files in `/proc/sys/` are read-only inside unprivileged
namespaces:

```bash
podman run --rm \
    --sysctl net.ipv4.tcp_tw_reuse=2 \
    --sysctl net.ipv4.tcp_keepalive_time=60 \
    myservice:latest
```

## `bcc-tools` — network diagnostics suite

[BCC](https://github.com/iovisor/bcc) (BPF Compiler Collection)
ships a directory of ready-to-run eBPF programs in
`/usr/share/bcc/tools/`. The network-diagnostic subset is
what makes "the packet got lost somewhere" tractable:

| Tool | What it shows |
|---|---|
| `tcpconnect` | every `connect()` call: PID, IP, port, latency, success |
| `tcpaccept` | every accepted TCP connection |
| `tcpretrans` | TCP retransmissions in real time |
| `tcptop` | top processes by TCP throughput, like `top` for network |
| `tcplife` | every TCP session: open, close, bytes transferred, duration |
| `tcptracer` | trace every TCP state change |
| `tcpdrop` | every dropped TCP packet + the stack trace where it dropped |

Examples — these run on the host but show container traffic
too (BCC programs are kernel-side, not namespace-bound):

```bash
# Watch every TCP connect attempt while you reproduce a bug
sudo /usr/share/bcc/tools/tcpconnect -t
# Output: timestamps + PID + COMM + source/dest IPs + ports

# Watch TCP retransmissions — these are usually invisible
sudo /usr/share/bcc/tools/tcpretrans -l
# Adding -l shows the local stack trace where the retransmit
# was scheduled, which often pins down the root cause.

# Watch dropped packets (where in the kernel did this happen?)
sudo /usr/share/bcc/tools/tcpdrop
# Tells you the function name in the kernel that dropped the
# packet; common culprits include tcp_rcv_state_process and
# tcp_v4_rcv when receive queue is full.
```

For container-specific runs, filter by cgroup or netns:

```bash
# Get the netns of a running container
podman inspect myservice | jq -r '.[0].NetworkSettings.SandboxKey'
# → /var/run/netns/podman-...

# tcptop runs per-cgroup if you tell it which
sudo /usr/share/bcc/tools/tcptop --cgroupmap /sys/fs/cgroup/user.slice/...
```

The bcc-tools binaries are dnf-installable on Fedora:
`sudo dnf install bcc-tools`. They live in
`/usr/share/bcc/tools/` rather than `$PATH` because there are
~150 of them and most aren't network-focused; the network
subset is what this section covers.

## `bpftrace` — ad-hoc kernel queries

[bpftrace](https://bpftrace.org/) is the eBPF awk: short
programs that attach to kprobes, uprobes, tracepoints, or perf
events and run for as long as you want. Great for ad-hoc
queries that the bcc-tools set doesn't already cover.

A few network-focused one-liners worth knowing:

```bash
# How many TCP connections did each process open in the last minute?
sudo bpftrace -e 'kprobe:tcp_v4_connect { @[comm] = count(); }' -c "sleep 60"

# Histogram of TCP retransmission latency (microseconds)
sudo bpftrace -e 'kprobe:tcp_retransmit_skb { @ns = hist(nsecs - @start[arg0]); }
                  kprobe:tcp_v4_connect { @start[arg0] = nsecs; }'

# How big are the bursts hitting net.core.netdev_max_backlog?
sudo bpftrace -e 'kprobe:netif_receive_skb { @[cpu] = count(); }
                  interval:s:10 { print(@); clear(@); }'

# Latency distribution: time from socket recv to user-space read
sudo bpftrace -e 'kprobe:tcp_recvmsg { @start[arg0] = nsecs; }
                  kretprobe:tcp_recvmsg /@start[arg0]/ {
                    @lat_us = hist((nsecs - @start[arg0]) / 1000);
                    delete(@start[arg0]);
                  }'
```

The full reference manual is at
[bpftrace.org/docs](https://bpftrace.org/docs/) — the language
is small enough to learn in an evening. **Where bpftrace shines
relative to bcc-tools**: when you need a one-off query that
combines multiple probes in a way no shipping bcc tool covers.

## `bpftool` — introspecting BPF programs

`bpftool` is the kernel-level inspection utility for **what
BPF programs are currently loaded, where, and what they're
doing**. Useful for two situations:

1. **Diagnosing performance regressions** that turn out to be a
   loaded BPF program (cilium, falco, observability sidecars)
   eating CPU on every packet.
2. **Verifying that the BPF programs you expect are loaded**
   (e.g., your service ships an XDP filter; is it actually
   attached after a node restart?).

```bash
# List every BPF program loaded on the system
sudo bpftool prog show

# What's attached to network interfaces?
sudo bpftool net show

# Detailed look at one program (the ID came from `prog show`)
sudo bpftool prog show id 42 --pretty

# Counter stats for that program — how many packets is it
# touching, and at what cost?
sudo bpftool prog show id 42 --pretty
# Look for "run_time_ns" and "run_cnt" fields.
```

`bpftool` is part of the `bpftool` package on Fedora:
`sudo dnf install bpftool`. It's small and worth having
installed even when you're not actively debugging.

## Production diagnostic — combining the layer

When "the network feels slow" — here's a roughly-ordered
diagnostic recipe:

```bash
# 1. What network mode is the container in?
podman inspect myservice | jq -r '.[0].HostConfig.NetworkMode'
# bridge, host, slirp4netns, pasta, container:<other>

# 2. Are TCP retransmissions happening?
ss -ti  | grep retrans
# Per-socket retransmit counts; non-zero is interesting.

# 3. Run tcpretrans for 30 seconds during repro
sudo /usr/share/bcc/tools/tcpretrans -l -c 30

# 4. Are we dropping packets at the receive queue?
cat /proc/net/softnet_stat
# 3rd column is per-CPU drop count. Non-zero = netdev_max_backlog too small.

# 5. What's the per-connection latency look like?
sudo /usr/share/bcc/tools/tcplife -L 8080  # filter on local port

# 6. Any unexpected BPF programs eating cycles?
sudo bpftool prog show | grep -E 'run_cnt|run_time'
```

The same eBPF tooling is what [§10 uses for service
profiling](../10-observability-profiling/) — the difference is
focus: §10's `runqlat` is about CPU scheduling latency
*inside* your service; §9's `tcptracer` and `tcpretrans` are
about kernel network state *underneath* your service. Both
matter, and you'll often reach for both during the same
incident.

## Why this is a C++ concern

A Go program's net stack is the standard library's. A Java
program's net stack is the JVM's. Both papering over the kernel
details with `Conn.Read` / `SocketChannel.read`. **C++ is
typically writing to sockets directly via `<sys/socket.h>` or
through a thin wrapper (Asio, gRPC).** That means C++ programs
notice kernel-side network problems *first* — there's no
runtime smoothing layer that retries silently.

The good news: that proximity makes C++ services excellent
canaries for kernel-network-tuning regressions. The bad news:
when something IS misbehaving at the kernel level, the C++
service is where you'll see the symptoms, often as p99 spikes
or apparently-random connection errors. The bcc-tools / bpftrace
/ bpftool kit closes the diagnostic loop — you can move from
"my service has weird latency" to "the kernel is dropping
packets on CPU 7 because netdev_max_backlog is too small for
this burst pattern" in a few minutes.

RAII patterns for socket file descriptors (the `unique_fd`
wrapping pattern, e.g., [`folly::File`](https://github.com/facebook/folly/blob/main/folly/File.h)
or hand-rolled) protect against the version of this problem
that's C++-specific: a connection leak under exception leaves
the kernel with stranded sockets in `CLOSE_WAIT`. The pattern
in [§3 (RAII discipline)](../03-raii-discipline/) is the same
shape applied to network resources.

## Demo

The networking comparison is folded into
[`examples/demo-03-io-uring-grpc/`]({{ '/examples/demo-03-io-uring-grpc/' | relative_url }}):
the same workload runs first under default networking and
then with `--network=host`, and the demo prints the p50/p99
delta. The `compose.production.yml` variant in that demo also
shows the custom seccomp + SELinux configuration needed for
io_uring under non-default network namespacing — see
[§14 for the EPERM/EACCES rubric](../14-pitfalls/) that explains
which security layer denied which syscall.

**Optional `demo-08-ebpf-analysis`** — a future addition that
runs `tcptracer`, `tcpretrans`, `tcptop`, and a couple of
bpftrace one-liners against a containerized service while
under load, capturing the diagnostic output. Not shipped yet;
intended as an appendix-style demo after the core tutorial
demos (01-07) stabilize.

## For deeper coverage

- Enberg, *Latency*, ch. 5 (the network stack)
- [BCC tutorial on GitHub](https://github.com/iovisor/bcc/blob/master/docs/tutorial.md)
  — the canonical reference for the bcc-tools commands
- [bpftrace one-liner
  tutorial](https://github.com/bpftrace/bpftrace/blob/master/docs/tutorial_one_liners.md)
  — Brendan Gregg's introduction; ~20 minutes to read
- Brendan Gregg, [*BPF Performance
  Tools*](https://www.brendangregg.com/bpf-performance-tools-book.html)
  (2020) — the deep treatment of the bcc / bpftrace / bpftool
  ecosystem; chapter 10 specifically on networking
- `bpftool(8)` man page

## What's next

[§10 turns the lights on](../10-observability-profiling/):
with the network plumbing measurable, see what your service
is doing on top of it. Tracing, metrics, logs, and the
OpenTelemetry SDK choice that costs an 8.5× throughput
collapse if you pick the wrong span processor.
