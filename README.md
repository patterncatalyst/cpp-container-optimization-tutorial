# Optimizing Modern C++ with Containers

A 1.5-3 hour technical presentation, paired Jekyll site, and six
runnable Podman demos that teach modern-C++ performance work under
realistic container constraints — on Fedora 44, end-to-end,
rootless.

This repository is the source for both the published Jekyll site
and the PPTX presentation. The tutorial is structured so it can be
delivered live in 1.5 hours (high-level pass, pre-recorded demos)
or in 3 hours (every demo run live in front of the audience).

> **Quick start:** see [GETTING-STARTED.md](GETTING-STARTED.md)
> for the step-by-step setup. This README explains what's here and
> why.

## What's in scope

- Compile-time wins: LTO, PGO, `constexpr`
- C++20/23 data structures: `flat_map`, `flat_set`, PMR allocators
- Memory: huge pages, cgroups v2 `memory.high`, mimalloc/jemalloc
- I/O: `io_uring`, async gRPC, `SO_REUSEPORT`
- Container strategy: UBI vs scratch, multi-stage, ABI labels
- Observability: Grafana + Prometheus + Tempo + Loki + Mimir, all
  via one `podman compose up`
- Profiling: `perf`, `bcc`, `bpftrace`, all against running pods
- Isolation: cgroup weights, CPU pinning, NUMA, veth latency
- Reproducibility: Conan 2 lockfiles, CMake presets, `abidiff`
- Common traps: AVX-512 mismatch, abstraction overhead, build-time
  delays inside containers

## What's not in scope

- C++ language fundamentals (assumed prerequisite)
- Podman / OCI fundamentals (assumed prerequisite)
- Docker, vcpkg, Bazel comparisons
- Kubernetes (cgroups v2 + Podman pods is the deployment model)
- Windows or non-Linux hosts as primary platforms

See [PRD.md](PRD.md) §3 for the complete non-goals list.

## Repository layout

```
.
├── PRD.md                   ← the project's source-of-intent
├── _plans/
│   └── reconciliation-plan.md  ← what's verified vs. claimed
├── _docs/                   ← tutorial sections (00 … 14)
├── _layouts/                ← Jekyll wrappers (default, tutorial, plan)
├── _includes/               ← header, footer, excalidraw embed
├── assets/
│   ├── css/                 ← site styles (one file)
│   ├── diagrams/            ← paired .svg + .excalidraw per section
│   └── images/              ← screenshots, hero
├── examples/                ← runnable demos (excluded from site build)
│   ├── demo-01-image-strategy/
│   ├── demo-02-memory-and-stl/
│   ├── demo-03-io-uring-grpc/
│   ├── demo-04-observability/
│   ├── demo-05-isolation/
│   └── demo-06-quality-pipeline/
├── observability/           ← compose stack: Grafana/Prom/Tempo/Loki/Mimir
├── scripts/                 ← test-template + per-demo + aggregator
└── .github/workflows/       ← Pages build + demo CI
```

## The six demos

Every demo is self-contained and runs via a single `./demo.sh` from
its directory. Each has a corresponding `scripts/test-demo-NN-*.sh`
that the aggregator `scripts/test-all-demos.sh` runs in CI.

| # | Demo                                                           | Topics                                                                  |
|---|----------------------------------------------------------------|-------------------------------------------------------------------------|
| 1 | [`demo-01-image-strategy`](examples/demo-01-image-strategy/)   | UBI vs scratch, multi-stage, LTO, PGO, ABI labels                       |
| 2 | [`demo-02-memory-and-stl`](examples/demo-02-memory-and-stl/)   | C++23 `flat_set`, PMR allocator, huge pages, cgroup memory limits       |
| 3 | [`demo-03-io-uring-grpc`](examples/demo-03-io-uring-grpc/)     | `io_uring` echo + async gRPC + `SO_REUSEPORT`, `hey` load gen           |
| 4 | [`demo-04-observability`](examples/demo-04-observability/)     | The full Grafana stack + OTel-instrumented C++ + `bpftrace` probes      |
| 5 | [`demo-05-isolation`](examples/demo-05-isolation/)             | Two-tenant noisy neighbor: cpu.weight, io.weight, cpuset, NUMA          |
| 6 | [`demo-06-quality-pipeline`](examples/demo-06-quality-pipeline/) | cppcheck + clang-tidy + gtest + abidiff + gdbserver sidecar             |

## Reference materials

The tutorial points readers at, but does not summarize or
displace, three reference works:

- Andrist & Sehr, *C++ High Performance, 2nd Edition*
- Iglberger, *C++ Software Design*
- Enberg, *Latency: Reduce delay in software systems*

Each section ends with a "for deeper coverage" pointer to specific
chapters. The tutorial is a runnable companion, not a replacement.

## License

Apache 2.0 — see [LICENSE](LICENSE).

## Acknowledgements

Scaffolded from
[`patterncatalyst/skeleton-tutorial`](https://github.com/patterncatalyst/skeleton-tutorial).
The conventions around `_docs/`, `_plans/`, paired diagrams, and
the test-script aggregator come from there directly.
