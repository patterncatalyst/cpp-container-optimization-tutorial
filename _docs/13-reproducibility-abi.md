---
title: "Reproducibility & ABI: Conan, CMake Presets, Hermetic Builds"
order: 13
description: Lockfiles, presets, ABI labels, and `abidiff` — the discipline that means a binary you build today still builds, byte-for-byte, three months from now.
duration: 12 minutes
---

## Learning objectives

By the end of this section you can:

- Create a Conan 2.x lockfile pinning every transitive
  dependency, and explain what's pinned (versions, options,
  settings).
- Write a `CMakePresets.json` with the build configurations the
  project actually uses (debug, release-LTO, release-PGO,
  release-PGO-instrumented).
- Build the same binary in two different containers and produce
  identical SHA-256 digests — what "hermetic" actually requires
  and where it usually leaks.
- Use `abidiff` (libabigail) to detect ABI breaks between two
  builds of the same library, and write that check into CI.

## Diagram

{% include excalidraw.html name="13-reproducibility-conan-flow" caption="The hermetic build flow: Conan lockfile + CMake preset + multi-stage Containerfile → labeled image" %}

## Planned content

- Conan 2.x lockfiles: what they pin, what they don't (compiler
  version, OS), how to regenerate, how to use one in CI.
- CMake presets: the file format, the four useful presets for
  this kind of project, how presets compose.
- The Konflux-style hermetic build: build inputs are a fixed set
  of artefacts; build environment is itself an immutable image;
  output is reproducible. The bits that leak in practice
  (timestamps, build-id GUIDs, parallel-build non-determinism).
- ABI labels in image metadata: encoding compiler version, libc,
  `march`/`mtune`, PGO status into `LABEL` lines so the image
  carries its own provenance.
- `abidiff` in CI: comparing the about-to-merge build's
  shared-library against the previous tag's. What kinds of
  changes it flags (added symbols, removed symbols, vtable
  reorderings, function-signature changes).

## When Conan from-source meets a minimal distro

A practical hazard worth knowing about before §13's worked
examples: if your build host is UBI 9 / RHEL 9 / Rocky 9 / Alma 9
and you're using Conan to manage C++ deps, autotools-based
packages (libcurl, openssl, c-ares, nghttp2, …) will fall over
during their from-source build because UBI's minimal perl
doesn't ship the modules `aclocal` and `automake` need.
**[Appendix A — Conan, autotools, and UBI 9's minimal
perl](appendix-a-conan-ubi9-perl.html)** has the full perl-module
shopping list and the alternatives (skip the dep, use the system
package, drop cppstd to hit pre-builts) so you can pick the right
trade-off instead of chasing missing modules one round at a time
the way demo-04 did.

## What a version pin doesn't pin

Demo-04's `conanfile.py` has this requires block:

```python
def requirements(self):
    self.requires("opentelemetry-cpp/1.14.2")
    self.requires("grpc/1.54.3",       override=True)
    self.requires("protobuf/3.21.12",  override=True)
    self.requires("abseil/20230125.3", override=True)
```

Four explicit version pins. As reproducibility statements go,
this looks airtight. It isn't.

A Conan package is addressed by **three** identifiers:
`name`, `version`, **and `recipe revision`**. The version is
what the recipe author publishes; the recipe revision is a hash
of the recipe contents. Recipe maintainers occasionally update
a published version's recipe — to bump a sub-dep, fix a
build-script bug, regenerate the recipe from a newer template
— and when they do, **the version stays the same but the
revision changes**. New pre-built binaries are published for
the new revision; old revision binaries may stick around for a
while or get garbage-collected.

A `[requires]` block resolves to "the latest revision of this
version, whatever that is right now." Two consequences:

1. Different transitive constraints over time. The recipe
   revision that made `opentelemetry-cpp/1.14.2` happily pair
   with `protobuf/3.21.12` last month may today require
   `protobuf/5.27.0` instead. Same version pin, different
   graph.
2. Different package binaries over time. Even if the graph
   stays stable, the pre-built artefacts published against
   the new revision were compiled with a different set of
   transitive deps. Your "same" pinned version is actually
   linking different object code than it did last month.

This is one of the gotchas demo-04 surfaced concretely; the
other is **Conan Center yanking versions entirely**, which
no pin can prevent. The `grpc/1.62.0` referenced in this
tutorial's earliest drafts was simply removed from the
remote between Feb and May 2026.

### The lockfile guarantees what versions can't

A `conan.lock` file pins (name, version, **revision**) for
every node in the resolved dep graph. Generate it once
against a working build:

```bash
./scripts/regenerate-demo-04-lockfile.sh
```

That writes `examples/demo-04-observability/conan.lock` —
JSON with every package's exact revision recorded. Commit
the file. The Containerfile picks it up:

```dockerfile
RUN if [ -s conan.lock ]; then \
        conan install . --output-folder=build/conan \
                        --lockfile=conan.lock \
                        --build=missing ; \
    else \
        conan install . --output-folder=build/conan \
                        --build=missing ; \
    fi
```

With the lockfile in place, **subsequent builds resolve the
graph against the recipe revisions you tested with**, not
against whatever's current. If a recipe is updated after you
locked, your build is unaffected.

### What the lockfile still can't fix

The lockfile pins identifiers; it can't conjure absent
packages. If Conan Center yanks a recipe entirely — which is
not hypothetical; it's how `grpc/1.62.0` disappeared while
demo-04 was being shaken down — even a lockfile that names
the exact revision will fail with `Unable to find` because
the package isn't in the remote anymore.

The durable fix is to **mirror packages to your own remote**.
JFrog Artifactory, a self-hosted Conan server, or even a
flat HTTP file server can hold copies of every package your
lockfile references. Configure that as an additional Conan
remote ahead of `conancenter`, and your builds become
independent of Conan Center's curation policy.

For a tutorial demo we accept the residual brittleness and
document it. For a production pipeline, treat mirroring as
part of the build infrastructure.

### When to regenerate

Run `scripts/regenerate-demo-04-lockfile.sh` when:

- You intentionally update an override version in
  `conanfile.py` (e.g., bumping opentelemetry-cpp).
- You want to refresh against current recipe revisions
  because a security fix landed in one of your transitive
  deps.
- A teammate reports a build failure on a fresh checkout
  and the diagnosis is "their resolver picked a newer
  revision than yours."

Otherwise, leave the lockfile alone. The whole point is that
it doesn't move.

## Demo

[`examples/demo-06-quality-pipeline/`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/demo-06-quality-pipeline)
includes a hermetic build path: builds a library twice in
identical builder containers and asserts the artefacts are
byte-identical, then deliberately introduces an ABI break and
shows `abidiff` catching it.

## For deeper coverage

- Iglberger, *C++ Software Design*, ch. 1 (architectural decisions
  that survive contact with reality), ch. 5 (the ABI cost of
  template choices)
- The libabigail manual

## What's next

§13 collects the most common things that go wrong, in one place,
with the diagnosis for each.
