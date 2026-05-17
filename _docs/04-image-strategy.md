---
title: "Container Strategy: UBI, ubi-micro, multi-stage"
order: 4
description: How a multi-stage Containerfile drops the same C++ service from 689 MB to 26.4 MB without sacrificing the toolchain you needed at compile time, and how to pick between UBI's runtime tiers (ubi, ubi-minimal, ubi-micro).
duration: 12 minutes
---

## Learning objectives

By the end of this section you can:

- Explain why a naïve single-stage build produces a 689 MB image
  even when the binary is 4 MB, and what each of the other 685 MB
  is doing in there.
- Write a multi-stage `Containerfile` that uses one base for
  building (full toolchain) and a different one for running
  (no compiler, no `dnf`), and explain what `COPY --from=build`
  does at the layer level.
- Choose between `ubi`, `ubi-minimal`, and `ubi-micro` for a
  runtime base — and predict what you give up at each tier
  (no shell, no `ldd`, no `strace` to attach).
- Order `COPY` and `RUN` lines so dependency installs survive a
  source-only change and the build cache stays useful.
- Write `LABEL` lines that tell future-you (and future
  CVE-triagers) what libc, libstdc++, micro-architecture, and
  PGO state the binary inside was built against.

## Diagram

{% include excalidraw.html name="04-image-strategy-multistage" caption="Single-stage vs multi-stage Containerfile, with what's actually inside each image" %}

## The 689 MB problem

A first-pass Containerfile for a C++ service usually looks like
this:

```dockerfile
FROM registry.access.redhat.com/ubi9:latest
RUN dnf install -y gcc-toolset-14 cmake ninja-build python3-pip && \
    pip3 install conan
COPY . /src
WORKDIR /src
RUN conan install . --build=missing && \
    cmake --preset conan-release && \
    cmake --build --preset conan-release
ENTRYPOINT ["/src/build/Release/myservice"]
```

It works. It also produces, in [demo-01](#demo), an image of
**689 MB**, of which the binary itself is roughly 4 MB. The
remaining 685 MB is doing one of four things, none of which need
to be present at runtime:

| What | How much | Why it's in there |
|---|---|---|
| `gcc-toolset-14` (compiler, headers, linker) | ~400 MB | needed to compile, not to run |
| Conan cache (sources + variants + binary cache) | ~200 MB | needed to resolve dependencies, not to use them |
| CMake configure cache, `.o` files, `.a` archives | ~80 MB | intermediates from the build step |
| Source tree (`/src`) | ~5 MB | needed to be compiled, not to be executed |

The container has to pull all 685 MB from the registry every time
the image is pulled. The container has to surface all 685 MB in
its attack surface — every dnf-installed package, every Conan-
cached transitive dependency, every CVE-scannable component
travels with the binary forever. The container has to walk all
685 MB of overlay layers on cold start. The actual program is
0.6% of the image.

**The fix isn't to shrink the toolchain. The fix is to leave the
toolchain behind.**

## Multi-stage builds — the mechanism

A multi-stage `Containerfile` declares two (or more) `FROM`
lines. Each `FROM` starts a new image; you give it an alias with
`AS`; only the final stage is what `podman build` tags. The
intermediate stages exist long enough to compile, then they're
discarded:

```dockerfile
# Stage 1 — heavy: compile here
FROM registry.access.redhat.com/ubi9:latest AS build
RUN dnf install -y gcc-toolset-14 cmake ninja-build python3-pip && \
    pip3 install conan
COPY . /src
WORKDIR /src
RUN conan install . --build=missing && \
    cmake --preset conan-release && \
    cmake --build --preset conan-release && \
    cp build/Release/myservice /usr/local/bin/myservice

# Stage 2 — lean: only the binary travels
FROM registry.access.redhat.com/ubi9-micro:latest
COPY --from=build /usr/local/bin/myservice /usr/local/bin/myservice
ENTRYPOINT ["/usr/local/bin/myservice"]
```

The `COPY --from=build` line is the entire trick. It says: "from
the image we just finished building under the alias `build`,
copy this one file into our new image." None of stage 1's other
contents — not the compiler, not the Conan cache, not the
intermediate `.o` files, not the source tree — make it into the
final image. They die with stage 1.

Demo-01's `Containerfile.ubi-multistage` produces a **114 MB**
image with this pattern (UBI 9 base + your binary + dynamic
libs). Switching the runtime base from `ubi9` to `ubi9-micro`
(see the next section) gets it to **26.4 MB**.

The build *time* is roughly the same as the single-stage version
— you're still compiling the same code. What changes is what
ships.

## Choosing your runtime base

Red Hat's UBI ("Universal Base Image") ships in three runtime
tiers, with very different trade-offs:

| Tier | Size | Shell | Package manager | When to pick it |
|---|---|---|---|---|
| `ubi9` | ~210 MB | `bash` | `dnf` | development bases, debug images |
| `ubi9-minimal` | ~100 MB | `bash` | `microdnf` | most production C++ services |
| `ubi9-micro` | ~14 MB | none | none | static-ish C++ services, security-sensitive |

`ubi9` is what you build *with*. It has the full
`gcc-toolset-14`, `dnf`, every utility your build script might
need. You almost never want this as your *runtime* base.

`ubi9-minimal` is the comfortable default for C++ runtime. You
get a working `bash` (so `podman exec -it ... bash` works for
diagnosis), a working `microdnf` (so you can install missing
runtime libraries if you must), and a consistent `glibc` /
`libstdc++` from the UBI release stream (so security updates
flow). The trade-off is ~85 MB extra over `ubi9-micro` for
that comfort.

`ubi9-micro` is what you ship when you've measured everything.
Roughly 14 MB on disk before you copy your binary in. No shell.
No `dnf`. No `ldd`, no `strace`, no `bash` — you can't even
`podman exec -it ... bash` into it because there's no `bash` to
exec. Your binary plus its dynamic libraries plus a working
`glibc` is what's there. If your binary needs `libssl` or
`libstdc++` you have to either statically link them or
explicitly `COPY` them from the build stage.

**The decision is about your incident-response posture, not
about the binary.** If the on-call playbook for "service is
misbehaving" starts with `podman exec -it ... bash`, ship
`ubi9-minimal`. If the playbook is "start an ephemeral
[debug sidecar](12-analysis-debugging.md) with `--pid=container:main`
that has gdb and the debug tools", ship `ubi9-micro`. The
sidecar approach is what production deployments converge to and
it's what [§12](12-analysis-debugging.md) walks through.

Distroless (Google) and Wolfi (Chainguard) are out of scope for
this tutorial but exist in the same space as `ubi9-micro`: very
small bases that assume you've moved diagnosis into a separate
sidecar.

## Layer caching — order COPY and RUN deliberately

`podman build` caches each Containerfile instruction. A cached
instruction is reused if its inputs (the previous layer plus the
files this instruction touches) haven't changed. The
implication: **put the things that change rarely above the
things that change often.**

A bad ordering forces a full rebuild on every source change:

```dockerfile
# BAD: source change invalidates conan install
FROM ubi9:latest AS build
COPY . /src                              # ← changes every commit
WORKDIR /src
RUN dnf install -y gcc-toolset-14 ...    # ← re-runs every commit
RUN pip3 install conan                   # ← re-runs every commit
RUN conan install . --build=missing      # ← re-runs every commit
RUN cmake --preset conan-release && cmake --build --preset conan-release
```

A good ordering keeps the expensive dependency steps cached:

```dockerfile
# GOOD: source change only invalidates the cmake build
FROM ubi9:latest AS build
RUN dnf install -y gcc-toolset-14 cmake ninja-build python3-pip
RUN pip3 install conan
COPY conanfile.txt conan.lock /src/      # ← changes when deps change
WORKDIR /src
RUN conan install . --lockfile=conan.lock --build=missing
COPY CMakeLists.txt CMakePresets.json /src/  # ← changes when build config changes
COPY src/ /src/src/                      # ← changes every commit
COPY include/ /src/include/
RUN cmake --preset conan-release && cmake --build --preset conan-release
```

The second form rebuilds in ~5 seconds when only a `.cpp` file
changed. The first rebuilds in ~3-5 minutes every time. On a
busy team this is the difference between fast feedback and the
team turning the build cache off because it "doesn't help".

The Conan lockfile reference ties into [§13's reproducibility
story](13-reproducibility-abi.md) — pinning the lockfile is what
makes the cached `conan install` layer trustworthy across CI runs.

## ABI labels — tell future-you what's inside

A small `ubi9-micro` image is opaque. You can't `dnf list
installed`. You can't `ldd` your binary. Six months from now,
when a CVE drops against `libstdc++` in some version range,
nobody can easily tell whether your shipped image is affected.

The fix is to write the answer into the image metadata at build
time:

```dockerfile
FROM ubi9-micro:latest
COPY --from=build /usr/local/bin/myservice /usr/local/bin/myservice
COPY --from=build /usr/lib64/libstdc++.so.6 /usr/lib64/
LABEL org.opencontainers.image.title="myservice"
LABEL org.opencontainers.image.version="1.4.2"
LABEL org.opencontainers.image.revision="a3f29b1"
LABEL ai.cpp-tutorial.libc="glibc-2.34-100.el9_4"
LABEL ai.cpp-tutorial.libstdcxx="libstdc++.so.6.0.32"
LABEL ai.cpp-tutorial.march="x86-64-v3"
LABEL ai.cpp-tutorial.pgo="enabled"
LABEL ai.cpp-tutorial.lto="thin"
LABEL ai.cpp-tutorial.sanitizers="none"
ENTRYPOINT ["/usr/local/bin/myservice"]
```

`podman inspect myservice:1.4.2 | jq '.[0].Labels'` reads them
all back at incident time. The `org.opencontainers.image.*`
labels are the standard set; the `ai.cpp-tutorial.*` labels are
ours and you should adapt the prefix to your org. **The point is
that a 26 MB image is too small to hold "the toolchain that
built me" — so write the toolchain identity in as metadata
instead.**

## The glibc-mismatch story

`ubi9-micro` is glibc-2.34 in current releases. If you build
your binary against a *different* glibc — say, by using a
`fedora:41` build base instead of `ubi9` — your binary may
reference symbols (`memcpy@GLIBC_2.39`, etc.) that don't exist
in the runtime image. The container will start, the dynamic
linker will fail, and you'll see this:

```
./myservice: /lib64/libc.so.6: version `GLIBC_2.39' not found
```

This isn't a `ubi9-micro` problem — it's a build/runtime base
mismatch problem. **Use the same UBI release for the build
stage and the runtime stage.** Demo-01 ships a deliberately-
broken `ubi-micro-glibc-mismatch` variant (a 25.2 MB image built
against newer glibc) so you can see this exact failure
firsthand. The general "build host vs runtime host CPU"
version of this problem — AVX-512 in the binary, an older CPU
in production — is what [§14](14-pitfalls.md) covers; the
toolchain mismatch story is its sibling.

## Production diagnostic — what's actually inside this image?

When triage starts with "what version of `libstdc++` is in
that image?" — here's the recipe:

```bash
# 1. inspect labels you wrote at build time
podman inspect myservice:1.4.2 | jq '.[0].Config.Labels'

# 2. enumerate the layers (sizes tell you where bloat lives)
podman history myservice:1.4.2

# 3. list files in the image without running it
podman create --name tmp myservice:1.4.2
podman export tmp | tar -tvf - | sort -k3 -n | tail -50
podman rm tmp

# 4. for ubi-minimal: dynamic library check
podman run --rm --entrypoint=/usr/bin/ldd myservice:1.4.2 \
    /usr/local/bin/myservice

# 5. for ubi-micro: do the ldd in a sidecar
podman run --rm \
    --pid=container:myservice-prod \
    --entrypoint=ldd ubi9:latest /proc/1/root/usr/local/bin/myservice
```

Steps 1-2 work on any image and are usually enough. Step 4 only
works if you have a shell + `ldd` in the runtime base (so
`ubi9-minimal` yes, `ubi9-micro` no). Step 5 is the
[debug-sidecar pattern in miniature](12-analysis-debugging.md):
join the prod container's PID namespace so you can see its
filesystem at `/proc/1/root`, and run `ldd` from a heavier image
that has the tool.

## Why this is a C++ concern

JVMs and Go runtimes carry their runtime *in the binary*. A
Go binary statically linked is the entire dependency tree; an
Uberjar contains the JVM's class libraries. C++ doesn't work
that way: a typical C++ binary depends on a specific
`libstdc++.so.6`, a specific `libc.so.6`, often a specific
`libssl.so.3` and `libcrypto.so.3`. **These dependencies are
implicit until they aren't.** The image strategy you choose
is, at heart, a decision about which dynamic libraries
travel with the binary and which ones are assumed to be at
the runtime end.

The micro-architecture decision is the same shape. C++ binaries
are not portable across CPU feature sets: a binary built with
`-march=native` on a build host with AVX-512 will SIGILL on a
runtime host without it. The labels above (`ai.cpp-tutorial.march`)
make that decision visible. [§14 walks through the AVX-512
pitfall in detail](14-pitfalls.md) — it's where this section's
"build base vs runtime base" theme meets "build host CPU vs
runtime host CPU".

## Demo

[`examples/demo-01-image-strategy/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/demo-01-image-strategy)
builds the same C++ service three ways and prints the
verified sizes:

| Variant | Size | What's gone |
|---|---|---|
| `single-stage-naive` | 689 MB | (baseline) |
| `ubi-multistage` | 114 MB | toolchain, Conan cache, intermediates, source |
| `ubi-micro` | 26.4 MB | + bash, dnf, every utility |
| `ubi-micro-glibc-mismatch` | 25.2 MB | broken — dies on `GLIBC_2.39` not found |

Run `./demo.sh` to build and tag all four; `./demo.sh inspect`
walks through the diagnostic recipe above on each variant.

## For deeper coverage

- Andrist & Sehr, *C++ High Performance*, ch. 3 (build pipeline)
- Iglberger, *C++ Software Design*, ch. 1 (the cost of decisions
  made early)
- Red Hat, ["Universal Base Images" (UBI)
  documentation](https://catalog.redhat.com/software/base-images)
- OpenContainers, [image-spec
  annotations](https://github.com/opencontainers/image-spec/blob/main/annotations.md)

## What's next

[§5 turns the next knob over](05-compile-time-wins.md): now that
you've decided what runtime base ships, decide what compiler
output goes into it. LTO and PGO are the two big build-time
levers; both produce smaller, faster binaries; both add
non-trivial build time. The PGO pipeline has a specific
workload-collection step that's where most attempts go wrong.
