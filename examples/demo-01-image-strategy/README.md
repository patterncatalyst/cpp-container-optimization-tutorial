# Demo 1 — Image Strategy: UBI, ubi-micro, multi-stage, LTO, PGO

## What this demo shows

Builds the same trivial C++23 HTTP service three different ways
and compares the results:

1. **`ubi-multistage`** — UBI builder + UBI-minimal
   runtime, multi-stage, LTO on
2. **`ubi-micro`** — UBI builder, runtime is
   `ubi9/ubi-micro` (~30 MB) with libstdc++ statically linked into the binary
3. **`single-stage-naive`** — A single-stage build that ships
   the toolchain in the runtime image, no LTO, no
   multi-stage. The "what not to do" baseline.

It also runs a Profile-Guided Optimization pass against the
LTO build and shows the additional delta.

## How to run

```bash
./demo.sh
```

Expected runtime: 5-10 minutes on a fresh cache, ~1 minute on a
warm cache.

The script prints a small comparison table: image size, build
time, and a `hey` benchmark for each build.

## Topics covered

- §3 Container Strategy (UBI vs ubi-micro, multi-stage)
- §4 Compile-Time Wins (LTO, PGO)
- §12 Reproducibility & ABI (image labels)

## Files

- `Containerfile.ubi-multistage` — preferred default
- `Containerfile.ubi-micro` — minimal-image variant (UBI-micro runtime, static libstdc++)
- `Containerfile.single-stage-naive` — anti-pattern baseline
- `Containerfile.pgo` — instrumented build for PGO step 1
- `CMakePresets.json` — the three release configurations
- `conanfile.txt` — pinned deps (httplib for the HTTP side)
- `src/main.cpp` — the trivial service
- `demo.sh` — orchestration; runs all three builds + PGO + `hey`
