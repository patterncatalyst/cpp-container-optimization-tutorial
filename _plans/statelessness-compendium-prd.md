# Statelessness Compendium — sub-project PRD

**Status:** drafted 2026-05-17, post-r145 review
**Sub-project of:** [main PRD](../PRD.md)
**Reconciliation:** rounds tracked in [reconciliation-plan.md](reconciliation-plan.md)

---

## 1. Summary

The **statelessness compendium** is the auxiliary reference under
`_reference/statelessness/` covering opinionated, in-depth treatment
of stateless C++ service design for containerized deployment. It
exists in parallel to the main tutorial: same toolchain, same audience,
but reference-style depth where the main tutorial is walking-tutorial
breadth.

The compendium ships today as 13 reader documents (~52,000 words)
plus 11 paired SVG + Excalidraw diagrams, with proper Jekyll
collection wiring at `/reference/statelessness/`. The body of work
is sound. What's missing is **discoverability, terminology
consistency, and runnable examples**.

This sub-project PRD covers three workstreams:

1. **Integration & discoverability fixes** from the r145 review
   (recommendations R1–R5)
2. **Terminology normalization** to "compendium" throughout
3. **A new examples set** under `examples/statelessness/` mapping
   runnable Podman projects to the compendium's central patterns
   (target: 8 examples, parallel structure to the main tutorial's
   7 demos)

When complete, the compendium will sit alongside the main tutorial
as a peer deliverable rather than an under-discovered side track,
with bidirectional cross-references and matching empirical anchors
(every architectural claim has a runnable example).

## 2. Problem statement

The r145 review identified four issues with the compendium as it
currently ships:

**2.1 Zero discoverability from `_docs/`.** Not a single tutorial
section in `_docs/` links to `_reference/statelessness/`. A reader
of `_docs/03-raii-discipline.md` learns the 20-line `unique_fd` and
moves on — they don't know there's a 24,000-word RAII treatment
one collection over.

**2.2 Topical overlap is uncalled out.** The compendium goes deeper
on RAII (`02-raii.md`), PMR (`03-pmr.md`), CFS quotas
(`05-threading.md`), and Conan/CMake build tooling
(`11-build-tooling.md`) than the main tutorial does. Without
"go deeper here" pointers, readers re-derive what's already
written.

**2.3 No runnable examples paired with the compendium.** The main
tutorial has 7 demos backing every measurement; the compendium has
zero. Readers learn the patterns by reading; they can't run them.

**2.4 Terminology is inconsistent.** The compendium calls itself
a "document set" once, a "compendium" twice, "reference collection"
elsewhere. The URL says "reference"; the user prefers "compendium".
Normalize.

**2.5 `research-notes.md` is published but contains
author-facing content.** 9,329 words of working notes live at
`/reference/statelessness/research-notes/` with sections like
"Remaining open per-doc questions" — appropriate for an extender
but disorienting for a reader who lands there from search.

## 3. Goals and non-goals

### Goals

- Apply the r145 review recommendations R1–R5
- Normalize terminology: "compendium" used consistently in
  reader-facing prose
- Add 8 runnable examples under `examples/statelessness/` matching
  the conventions of the main tutorial's 7 demos
- Establish bidirectional cross-references between main tutorial
  and compendium
- Preserve the compendium's existing voice (formal third-person,
  opinionated callouts) — don't merge it into the main tutorial's
  direct-address style

### Non-goals

- **Rewriting the existing 13 compendium documents.** Content is
  solid; only minor terminology + cross-reference edits needed.
- **Restructuring the `_reference/` Jekyll collection.** Wiring is
  correct and the URL scheme is settled.
- **Building examples that duplicate the main tutorial demos.** The
  main tutorial's Demo 6 covers PMR allocators with batch + serve
  benchmarks; the compendium's PMR example should focus on the
  *lifetime patterns* (request arena, the lifetime trap) rather
  than allocator performance.
- **Adding new compendium documents.** The 13-doc set is the
  scope; new material goes into the existing docs as amendments.

## 4. Audience

Same as the existing compendium:

- Seasoned C++ developer or architect knowing the language well
  (RAII, move semantics, templates, the standard library)
- Building or operating services that deploy to Podman or
  Kubernetes
- Familiar with gRPC, OpenTelemetry, and Grafana-stack (Loki,
  Tempo, Mimir) observability
- Toolchain: GCC/Clang, Conan, CMake, Ninja; C++20 baseline with
  C++23 features called out

**New audience this sub-project addresses:** readers of the main
tutorial who want to go deeper on RAII / PMR / threading / build
tooling after finishing the tutorial sections. The "go deeper"
callouts (R1) are the on-ramp.

## 5. Scope and section outline

### Phase 1 — Integration & discoverability (one round, ~1-2 hours)

Apply the r145 review recommendations:

- **R1**: Four "go deeper" callouts from `_docs/` into the
  compendium, in the "For deeper coverage" sections of:
  - `_docs/03-raii-discipline.md` → `02-raii.md`
  - `_docs/07-memory-management.md` → `03-pmr.md`
  - `_docs/11-noisy-neighbors.md` → `05-threading.md`
  - `_docs/13-reproducibility-abi.md` → `11-build-tooling.md`
  Plus one paragraph in `_docs/15-where-to-go-next.md` introducing
  the compendium as a follow-on reference.

- **R2**: Reframe `research-notes.md`:
  - Rename "Research notes (working drafts)" → "Authoring notes
    for compendium extenders"
  - Remove the "Remaining open per-doc questions" section (move
    any still-relevant items to GitHub issues if desired)
  - Add a stronger "this is for extenders, not first-time readers"
    banner at the top
  - Front matter: keep `order: 99`

- **R3**: Add a 2-3 sentence reading-style note to
  `00-index.md` signaling the compendium's third-person voice and
  `> **Opinion.**` callouts, distinct from the main tutorial's
  direct-address style.

- **R4**: Bibliography page preamble link. The bibliography
  already has the per-book coverage table for statelessness
  (`bibliography.html` lines 234-241); add an inbound link from
  the preamble to `_reference/statelessness/00-index.md` so the
  discovery path is symmetric.

- **R5**: Terminology normalization. Replace "document set",
  "reference collection", and stray "reference" mentions in
  reader-facing prose with **"compendium"**. Specifically:
  - `_reference/statelessness/00-index.md` (~3 occurrences to
    normalize)
  - Section headings and prose where the compendium refers to
    itself
  - Keep `_reference/` as the directory name (URL semantics) but
    refer to the body of work as the "statelessness compendium"

- **R6 deferred**: Low-value diagram-for-the-index suggestion;
  skip unless it surfaces naturally.

### Phase 2 — Examples set (multi-round, 8 examples)

Eight new runnable examples under `examples/statelessness/`, each a
self-contained Podman project with its own `./demo.sh`, matching
the conventions of the main tutorial's 7 demos.

Examples are numbered independently of the main demos so it's clear
which collection an example belongs to (no `demo-08-*` numbering).
Slug names match the compendium doc topic, not its number.

| # | Example slug                  | Compendium doc | What it demonstrates                                                                                                 |
|---|-------------------------------|----------------|----------------------------------------------------------------------------------------------------------------------|
| 1 | `request-context-raii`        | Doc 02         | The `RequestContext` RAII pattern; gRPC callback API as the request boundary; common-mistakes catalog with runtime diagnostics |
| 2 | `pmr-monotonic-arena`         | Doc 03         | Per-request `monotonic_buffer_resource` arena; layered monotonic + `sync_pool` recipe; lifetime-trap counterexample with sanitizer output |
| 3 | `process-scoped-wiring`       | Doc 04         | `main()`-owned wiring of `TracerProvider` + gRPC channels + connection pools + parsed config; State Architecture Table walkthrough in code |
| 4 | `cgroup-thread-sizing`        | Doc 05         | CFS quota detection via `cgroup_helper`; thread pool sized to `cpu.max`; gRPC `ResourceQuota` configuration; cooperative cancellation via `stop_token` |
| 5 | `scoped-connection-pool`      | Doc 07         | Connection pool as process-scoped + per-handler `ScopedConnection` RAII checkout with `invalidate()`; idempotency keys; deadline propagation        |
| 6 | `ephemeral-fs-traps`          | Doc 08         | Container with `--read-only=true`; spdlog default file write fails; fix via stdout output; `tmpfs` for scratch; PVC for what persists                |
| 7 | `grpc-health-shutdown`        | Doc 09         | Three probes (startup/liveness/readiness); gRPC health service; graceful shutdown sequence tying `stop_token` → pool drain → reverse-order destruction |
| 8 | `outbox-pattern`              | Doc 07         | The Outbox pattern: DB write + event emission atomic; outbox-relay sidecar; idempotent consumer; full path observable via OTel                       |

**Documents without a dedicated example** (deliberate):
- **Doc 01** (deployment posture) is vocabulary; no demonstrable
  pattern.
- **Doc 06** (12-Factor) is woven through every other example; no
  dedicated one.
- **Doc 10** (gRPC capstone) is *itself* the integration; the
  example would duplicate Doc 10's code listing.
- **Doc 11** (build tooling) is referenced by every example's
  `CMakePresets.json` + Containerfile; no dedicated example.

### Phase 3 — Bidirectional cross-references

Each example's `README.md` links to its corresponding compendium
doc.

Each compendium doc gets a "Run this pattern" callout near the
relevant section, linking to its example.

Tutorial sections in `_docs/` that link to a compendium doc (from
R1) also mention the corresponding example.

### Phase 4 — Test orchestration

Either:
- **(a)** Extend `scripts/test-all-demos.sh` to also run the
  statelessness examples, or
- **(b)** Add `scripts/test-all-statelessness-examples.sh` as a
  separate aggregator, with `scripts/test-everything.sh` calling
  both

Decision deferred to first example landing (Phase 2.1).

## 6. Examples directory layout

```
examples/
├── demo-01-image-strategy/                 ← main tutorial demo
├── demo-02-stl-layout/                     ← main tutorial demo
├── demo-03-io-uring-grpc/
├── demo-04-observability/
├── demo-05-isolation/
├── demo-06-memory-and-allocators/
├── demo-07-quality-pipeline/
│
└── statelessness/                          ← NEW: compendium examples
    ├── 01-request-context-raii/
    ├── 02-pmr-monotonic-arena/
    ├── 03-process-scoped-wiring/
    ├── 04-cgroup-thread-sizing/
    ├── 05-scoped-connection-pool/
    ├── 06-ephemeral-fs-traps/
    ├── 07-grpc-health-shutdown/
    └── 08-outbox-pattern/
```

Each statelessness example follows the main demo conventions:

```
examples/statelessness/NN-name/
├── README.md                  ← what it demonstrates + how to run
├── demo.sh                    ← single command entry point
├── Containerfile              ← multi-stage UBI 9 build
├── compose.yml                ← podman compose orchestration
├── src/                       ← C++ source (proto + handler)
├── CMakeLists.txt
├── CMakePresets.json
└── conanfile.py + conan.lock  ← pinned deps
```

Per-example Jekyll wrapper pages will be generated under
`_examples/statelessness-NN-name.md` (same pattern as the main
demos' `_examples/demo-NN-*.md`) so the examples appear in the
`/examples/` gallery alongside the main demos.

## 7. Diagrams

The existing 11 compendium diagrams are kept as-is. New examples
may add 1-2 example-specific diagrams each, paired SVG +
Excalidraw, under `diagrams/statelessness/<example-name>-*.svg`.

Not every example needs a new diagram; the existing compendium
diagram for that doc is often sufficient.

## 8. Success metrics

- All 5 main-tutorial → compendium cross-refs land and use
  `relative_url` filter
- `research-notes.md` reframed; no remaining author-facing TODO
  sections in publishable content
- Terminology normalized: zero "document set" / "reference
  collection" in reader-facing prose; "compendium" used
  consistently
- 8 example projects shipped, each with passing `./demo.sh`
- Test orchestration extended (Phase 4 decision applied)
- Bidirectional cross-references in place: each example links to
  its doc, each doc that has an example links to it
- `bibliography.html` preamble links to the compendium index

## 9. Constraints and dependencies

- **Toolchain**: same as main tutorial — Fedora 44, Podman 5,
  GCC 14 / Clang 18, Conan 2, CMake, Ninja
- **Base images**: UBI 9 (builder) + ubi-micro or ubi9-minimal
  (runtime), matching the main tutorial's image strategy
- **Observability**: reuse the shared `observability/` compose
  stack (`grafana/otel-lgtm` all-in-one)
- **gRPC required** for examples 1, 3, 4, 5, 7, 8
- **PostgreSQL required** for examples 5, 8 (use the standard
  `postgres:16` image as a sidecar)
- **Each example** must run end-to-end with one `./demo.sh`
  invocation, no external services beyond what its `compose.yml`
  brings up

## 10. Risks and mitigations

| Risk | Severity | Mitigation |
|---|---|---|
| Examples duplicate main tutorial demos (e.g. PMR example vs Demo 6) | High | Each example scoped to a SINGLE compendium pattern; explicit "does this duplicate Demo N?" check during scoping |
| gRPC + OTel build time dominates per-example | Med | Pre-built builder layer cached; examples 1, 3, 4, 5, 7, 8 share the same gRPC+OTel base image |
| Scope creep — "while we're here, add X" tendency | Med | Phase 2 is locked at 8 examples; new examples require an explicit PRD amendment |
| The compendium and tutorial drift apart again over time | Med | A pre-publish lint (the LESSONS-LEARNED §1 candidate) catches missing cross-references for matching topics |
| Examples become out-of-date as compendium evolves | Low | Each example pins its compendium doc reference by docID + section heading; CI lint flags broken back-refs |

## 11. Timeline and milestones

| Phase | Milestone | Est. effort | Done? |
|---|---|---|---|
| 1 | Integration & discoverability (R1-R5) | 1-2 hours, one round | [ ] |
| 2 | Example 1: `request-context-raii` | 4-6 hours | [ ] |
| 2 | Example 2: `pmr-monotonic-arena` | 4-6 hours | [ ] |
| 2 | Example 3: `process-scoped-wiring` | 6-8 hours | [ ] |
| 2 | Example 4: `cgroup-thread-sizing` | 6-8 hours | [ ] |
| 2 | Example 5: `scoped-connection-pool` | 8-10 hours | [ ] |
| 2 | Example 6: `ephemeral-fs-traps` | 4-6 hours | [ ] |
| 2 | Example 7: `grpc-health-shutdown` | 6-8 hours | [ ] |
| 2 | Example 8: `outbox-pattern` | 10-12 hours | [ ] |
| 3 | Bidirectional cross-references | Folded into Phase 2 | [ ] |
| 4 | Test-aggregator orchestration | 2-3 hours | [ ] |

**Estimated total effort:** Phase 1 + Phase 2 + Phase 4 ≈ 50-70
hours of part-time work, comparable to one of the main tutorial's
larger demos × 8.

## 12. Open questions

- **Q1**: Should statelessness examples be picked up by the main
  `test-all-demos.sh`, or have their own
  `test-all-statelessness-examples.sh`? *Deferred to Phase 2.1*
- **Q2**: Should each example get a generated Jekyll page under
  `_examples/`, or only the main demos? *Preferred answer: yes,
  same pattern as main demos*
- **Q3**: Numbering for example slugs — match compendium doc
  numbers (e.g. example 2 = `02-pmr-monotonic-arena` since Doc 03
  is "03-pmr")? *Open — current proposed layout uses example-local
  numbering 01-08 with topic-matching slugs*
- **Q4**: Should the `outbox-pattern` example (example 8) be split
  into a producer + consumer + relay multi-service setup, or kept
  as a single service with the outbox table polled in-process?
  *Open — multi-service is more realistic but more complex*
- **Q5**: PostgreSQL client library — `libpqxx` (matches
  Doc 07's examples) or the official `libpq` C API with hand-rolled
  RAII wrappers? *Preferred: `libpqxx` for the realistic case, hand-
  rolled RAII for the `scoped-connection-pool` example specifically
  to make the pattern visible*

## 13. Decision log

| Date       | Decision                                                                                       | Rationale |
|------------|------------------------------------------------------------------------------------------------|-----------|
| 2026-05-17 | Sub-project PRD created at `_plans/statelessness-compendium-prd.md`                            | Parallel structure to `_plans/reconciliation-plan.md`; lives alongside other planning artifacts |
| 2026-05-17 | "Compendium" as the normalized term for the `_reference/statelessness/` body of work           | User preference; signals the opinionated reference-work nature better than "document set" or "reference collection" |
| 2026-05-17 | 8 examples scoped, not 11 (one per compendium doc)                                             | Docs 01, 06, 10, 11 don't have demonstrable patterns of their own; constraint prevents scope creep |
| 2026-05-17 | Examples live under `examples/statelessness/NN-slug/`, not flat with the main demos            | Visual grouping; prevents demo numbering conflict; supports per-collection test orchestration |
| 2026-05-17 | `research-notes.md` reframed (option B), not deleted (option A)                                | The authoring narrative has value for extenders; the fix is reframing it as such, not hiding it |

## 14. Stakeholders

| Name           | Role                          | What they get from this sub-project                                                                                |
|----------------|-------------------------------|--------------------------------------------------------------------------------------------------------------------|
| Tutorial author | Author + presenter           | Discoverable compendium that pairs naturally with the main tutorial; examples that can be cited in the talk        |
| Main tutorial readers | Reader                 | "Go deeper" callouts that lead from main tutorial sections into the compendium; can stop at any depth              |
| Compendium readers | Reader + practitioner      | Runnable examples backing every architectural claim; same one-command run experience as the main tutorial demos    |
| Compendium extenders | Contributor              | Reframed `research-notes.md` documents the framing decisions and open questions for anyone proposing edits/additions |

## 15. How this PRD relates to the main project PRD

The main [`PRD.md`](../PRD.md) covers the tutorial-plus-7-demos-plus-
PPTX-plus-bibliography body of work. The statelessness compendium is
mentioned there in §7 (Diagrams — `_reference/statelessness/`
appears in the directory layout) and §14 (Stakeholders — under
"Tutorial extenders").

This sub-project PRD extends that coverage with:
- The integration story (how compendium plugs into main tutorial)
- The examples roadmap (8 new runnable projects)
- The terminology normalization
- The reframe of `research-notes.md`

When this sub-project's Phase 1-4 are complete, the main `PRD.md`
will be updated to reflect the compendium as a peer deliverable
(not an under-discovered side track) and to add the 8 examples to
the §6 runnable examples list.

## 16. References

- [r145 review of the compendium](reconciliation-plan.md) — the
  triggering review that surfaced R1-R5
- [Main `PRD.md`](../PRD.md) — parent project PRD
- [`_reference/statelessness/00-index.md`](../_reference/statelessness/00-index.md)
  — the compendium's own reading guide
- [`LESSONS-LEARNED.md` §1.4](../LESSONS-LEARNED.md) — the
  "demo cross-references should stay internal" lesson, applicable
  here too
