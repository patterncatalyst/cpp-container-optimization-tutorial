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

{% include excalidraw.html name="12-reproducibility-conan-flow" caption="The hermetic build flow: Conan lockfile + CMake preset + multi-stage Containerfile → labeled image" %}

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
