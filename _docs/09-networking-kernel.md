---
title: "Networking & Kernel Parameters"
order: 9
description: What a veth pair actually costs, when `--network=host` is the right escape hatch, and the small set of sysctls that move tail latency for C++ services.
duration: 10 minutes
---

## Learning objectives

By the end of this section you can:

- Trace a packet from `clientA → clientA's veth → bridge → serverB's veth → serverB`
  and identify where the additional latency comes from compared to host
  networking.
- Decide when `--network=host` is worth the namespace simplification
  and when it isn't (security, port collisions).
- Apply the small handful of sysctls that actually move tail
  latency for typical request/response services
  (`net.core.somaxconn`, `net.ipv4.tcp_tw_reuse`,
  `net.core.netdev_max_backlog`, `net.ipv4.tcp_no_metrics_save`).
- Configure these knobs on a Podman pod where applicable, and
  recognise which of them must be set on the host.

## Diagram

{% include excalidraw.html name="09-networking-veth-vs-host" caption="Packet path under default veth+bridge versus `--network=host`" %}

## Planned content

- The default Podman networking stack: rootless uses `pasta` or
  `slirp4netns` depending on version; the cost model differs.
- veth + bridge: predictable cost, predictable namespace
  isolation, ~2-15µs per packet of overhead under load.
- `--network=host`: throws away the namespace, pays nothing,
  loses port-collision protection.
- The sysctls worth knowing: what each does, when changing it
  helps, when it just makes you feel productive.
- Where the sysctl applies: host vs container namespace. Some are
  per-namespace; many are not.

## Demo

The networking comparison is folded into
[`examples/demo-03-io-uring-grpc/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/demo-03-io-uring-grpc):
the same `hey` workload runs against the gRPC service first under
default networking and then with `--network=host`, and the demo
prints the p50/p99 delta.

**Note on container security**: io_uring in a container needs both
seccomp and SELinux configuration. The tutorial compose uses
`seccomp=unconfined` + `label=disable` for simplicity; the parallel
`compose.production.yml` shows the audit-grade alternative (custom
seccomp profile with exactly the three io_uring syscalls added, plus
a custom SELinux policy module). See
[`security/README.md`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/demo-03-io-uring-grpc/security)
in the demo directory for the full audit story, and §14 for the
EPERM/EACCES error-code rubric that guides which security layer is
denying any given syscall.

## For deeper coverage

- Enberg, *Latency*, ch. 5 (the network stack)

## What's next

§9 turns the lights on: with the workload running, how do you see
what it's doing?
