# Optimizing Modern C++ with Containers

A 1.5-3 hour technical presentation, paired Jekyll site, and seven
runnable Podman demos that teach modern-C++ performance work under
realistic container constraints — on Fedora 44, end-to-end,
rootless.

This repository is the source for both the published Jekyll site
and the PPTX presentation. The tutorial is structured so it can be
delivered live in 1.5 hours (high-level pass, pre-recorded demos)
or in 3 hours (every demo run live in front of the audience).

> **Quick start:** see [onboarding/GETTING-STARTED.md](onboarding/GETTING-STARTED.md)
> for the step-by-step setup. This README explains what's here and
> why. For more onboarding material (pushing the site to GitHub
> Pages, working with Claude on the project), see the
> [`onboarding/`](onboarding/) folder.

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
├── README.md                    ← this file
├── PRD.md                       ← the project's source-of-intent
├── LESSONS-LEARNED.md           ← project retrospective (for the next similar project)
├── CONTRIBUTING.md              ← contribution + iteration conventions
├── LICENSE                      ← Apache 2.0
├── Gemfile                      ← Jekyll deps
├── _config.yml                  ← Jekyll site config
│
├── index.html                   ← Jekyll homepage
├── examples.html                ← demos gallery page
├── diagrams.html                ← diagrams gallery page
├── bibliography.html            ← annotated reference books page
│
├── onboarding/                  ← read-once setup + workflow docs
│   ├── GETTING-STARTED.md
│   ├── PUSHING-TO-GITHUB.md
│   └── STARTING-WITH-CLAUDE.md
│
├── _docs/                       ← tutorial sections (00 outline, 01-15, 16 appendix)
├── _examples/                   ← per-demo Jekyll pages, generated from READMEs
├── _reference/                  ← reference docs
│   └── statelessness/           ← Statelessness companion (00 index + 01-11 docs)
├── _plans/
│   └── reconciliation-plan.md   ← what's verified vs. claimed (~22k lines, append-only)
│
├── _layouts/                    ← Jekyll wrappers (default, tutorial, plan)
├── _includes/                   ← shared HTML partials (header, footer, embed)
├── assets/
│   ├── css/                     ← site styles
│   └── images/                  ← screenshots, hero
├── diagrams/                    ← paired .svg + .excalidraw per section
│
├── examples/                    ← runnable demos (excluded from site build)
│   ├── demo-01-image-strategy/
│   ├── demo-02-stl-layout/
│   ├── demo-03-io-uring-grpc/
│   ├── demo-04-observability/
│   ├── demo-05-isolation/
│   ├── demo-06-memory-and-allocators/
│   └── demo-07-quality-pipeline/
│
├── observability/               ← shared compose stack: grafana/otel-lgtm
├── presentation/                ← PPTX deck + build notes
│   ├── cpp-container-tutorial.pptx
│   └── README.md                ← deck rebuild + editing instructions
├── tools/                       ← deck build tools (build-pptx.py + sections.py + build-deck.sh)
├── scripts/                     ← test-template + per-demo + aggregator + utilities
└── .github/workflows/           ← Pages build + demo CI
```

## The seven demos

Every demo is self-contained and runs via a single `./demo.sh` from
its directory. Each has a corresponding `scripts/test-demo-NN-*.sh`
that the aggregator `scripts/test-all-demos.sh` runs in CI.

| # | Demo                                                           | Topics                                                                  |
|---|----------------------------------------------------------------|-------------------------------------------------------------------------|
| 1 | [`demo-01-image-strategy`](examples/demo-01-image-strategy/)   | UBI vs scratch, multi-stage, LTO, PGO, ABI labels                       |
| 2 | [`demo-02-stl-layout`](examples/demo-02-stl-layout/)   | `flat_map` vs `unordered_map` vs `std::vector` linear scan; Google Benchmark; cgroup memory pressure |
| 3 | [`demo-03-io-uring-grpc`](examples/demo-03-io-uring-grpc/)     | `io_uring` echo + async gRPC + `SO_REUSEPORT`, `hey` load gen           |
| 4 | [`demo-04-observability`](examples/demo-04-observability/)     | The full Grafana stack + OTel-instrumented C++ + `bpftrace` probes      |
| 5 | [`demo-05-isolation`](examples/demo-05-isolation/)             | Two-tenant noisy neighbor: cpu.weight, io.weight, cpuset, NUMA          |
| 6 | [`demo-06-memory-and-allocators`](examples/demo-06-memory-and-allocators/) | `std::allocator` vs `std::pmr` vs mimalloc, MAP_HUGETLB, cgroup memory.high |
| 7 | [`demo-07-quality-pipeline`](examples/demo-07-quality-pipeline/) | cppcheck + clang-tidy + gtest + abidiff + gdbserver sidecar             |

## Reference materials

The tutorial points readers at, but does not summarize or
displace, four reference works:

- Andrist & Sehr, *C++ High Performance, 2nd Edition*
- Iglberger, *C++ Software Design*
- Enberg, *Latency: Reduce delay in software systems*
- Ghosh, *Building Low Latency Applications with C++*

Each section ends with a "for deeper coverage" pointer to specific
chapters. The tutorial is a runnable companion, not a replacement.

## License

Apache 2.0 — see [LICENSE](LICENSE).

## Acknowledgements

Scaffolded from
[`patterncatalyst/skeleton-tutorial`](https://github.com/patterncatalyst/skeleton-tutorial).
The conventions around `_docs/`, `_plans/`, paired diagrams, and
the test-script aggregator come from there directly.
