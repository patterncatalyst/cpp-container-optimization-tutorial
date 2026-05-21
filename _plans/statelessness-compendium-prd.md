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

Example directories **match the compendium doc number and section
name** (resolved Q3): the example for Doc 02 (`02-raii.md`) lives at
`examples/statelessness/02-raii/`, and so on. This makes the
example↔doc mapping unambiguous from the directory name alone. Doc 07
has two examples (state externalization + the Outbox pattern); the
second is differentiated by pattern name (`07-outbox-pattern`) since
two directories can't share `07-state-externalization`.

| Example dir                       | Compendium doc | What it demonstrates                                                                                                 |
|-----------------------------------|----------------|----------------------------------------------------------------------------------------------------------------------|
| `02-raii`                         | Doc 02         | The `RequestContext` RAII pattern; gRPC callback API as the request boundary; common-mistakes catalog with runtime diagnostics |
| `03-pmr`                          | Doc 03         | Per-request `monotonic_buffer_resource` arena; layered monotonic + `sync_pool` recipe; lifetime-trap counterexample with sanitizer output |
| `04-process-scoped-state`         | Doc 04         | `main()`-owned wiring of `TracerProvider` + gRPC channels + connection pools + parsed config; State Architecture Table walkthrough in code |
| `05-threading`                    | Doc 05         | CFS quota detection via `cgroup_helper`; thread pool sized to `cpu.max`; gRPC `ResourceQuota` configuration; cooperative cancellation via `stop_token` |
| `07-state-externalization`        | Doc 07         | Connection pool as process-scoped + per-handler `ScopedConnection` RAII checkout with `invalidate()`; idempotency keys; deadline propagation        |
| `07-outbox-pattern`               | Doc 07         | The Outbox pattern as a real multi-service setup (resolved Q4): producer service + relay + idempotent consumer; DB write + event emission atomic; full path observable via OTel |
| `08-ephemeral-filesystem`         | Doc 08         | Container with `--read-only=true`; spdlog default file write fails; fix via stdout output; `tmpfs` for scratch; PVC for what persists                |
| `09-health-checks`                | Doc 09         | Three probes (startup/liveness/readiness); gRPC health service; graceful shutdown sequence tying `stop_token` → pool drain → reverse-order destruction |

**Documents without a dedicated example** (deliberate):
- **Doc 01** (deployment posture) is vocabulary; no demonstrable
  pattern.
- **Doc 06** (12-Factor) is woven through every other example; no
  dedicated one.
- **Doc 10** (gRPC capstone) is *itself* the integration; the
  example would duplicate Doc 10's code listing.
- **Doc 11** (build tooling) is referenced by every example's
  `CMakePresets.json` + Containerfile; no dedicated example.

**PostgreSQL client (resolved Q5).** Examples that touch PostgreSQL
(`07-state-externalization`, `07-outbox-pattern`) use **libpqxx**
for connections and transactions — it's mature, in Conan Center, and
provides RAII transactions out of the box; there's no demo value in
hand-rolling the libpq wire protocol. The one hand-rolled piece is
the `ScopedConnection` pool-checkout wrapper *around* `pqxx::connection`
— and that's required regardless, because libpqxx has no built-in
connection pool, and the checkout / RAII-return / `invalidate()`-on-
broken-connection flow **is** the teaching point of Doc 07. So the
demo advantage (the pattern is fully visible, ~40 lines) is preserved
without hand-rolling anything that has no teaching value.

### Phase 3 — Bidirectional cross-references

Each example's `README.md` links to its corresponding compendium
doc.

Each compendium doc gets a "Run this pattern" callout near the
relevant section, linking to its example.

Tutorial sections in `_docs/` that link to a compendium doc (from
R1) also mention the corresponding example.

### Phase 4 — Test orchestration (resolved Q1)

- Each example has its own test entry point — a `demo.sh` inside
  the example dir (the run script) plus a corresponding
  `scripts/test-stateless-demo-NN-<name>.sh` (the CI test script),
  matching the main tutorial's `examples/demo-NN/demo.sh` +
  `scripts/test-demo-NN-*.sh` split.
- A dedicated aggregator `scripts/test-all-stateless-demos.sh` runs
  every statelessness example test in sequence and prints a summary;
  does NOT fail-fast (same contract as `test-all-demos.sh`).
- The two aggregators stay separate. If a single "run everything"
  entry point is wanted later, a thin `scripts/test-everything.sh`
  can call both, but that's not required for Phase 4.


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
    ├── 02-raii/                             (Doc 02 — RequestContext RAII)
    ├── 03-pmr/                              (Doc 03 — monotonic arena)
    ├── 04-process-scoped-state/             (Doc 04 — main()-owned wiring)
    ├── 05-threading/                        (Doc 05 — cgroup thread sizing)
    ├── 07-state-externalization/            (Doc 07 — scoped connection pool)
    ├── 07-outbox-pattern/                   (Doc 07 — outbox, multi-service)
    ├── 08-ephemeral-filesystem/             (Doc 08 — ephemeral FS traps)
    └── 09-health-checks/                    (Doc 09 — health + shutdown)
```

Directory names match the compendium doc number + section name
(resolved Q3). The two Doc-07 examples share the `07-` prefix; the
Outbox one is differentiated by pattern name.

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

Per-example Jekyll wrapper pages are generated under
`_examples/statelessness-NN-name.md` (resolved Q2 — yes, same
format as the top-level project demo pages) so the examples appear
in the `/examples/` gallery alongside the main demos. The wrapper
filename carries the `statelessness-` prefix plus the doc-matched
number and name (e.g. `_examples/statelessness-02-raii.md`).

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
| 1 | Integration & discoverability (R1-R5) | 1-2 hours, one round | [x]   |
| 2 | `02-raii` example | 4-6 hours | [x] (host-verified r149 — 3/3 paths, lease balance clean, first-try build) |
| 2 | `03-pmr` example | 4-6 hours | [x] (host-verified r150.3 — arena+bench+ASan trap all pass; static-libasan + direct-run) |
| 2 | `04-process-scoped-state` example | 6-8 hours | [x] (host-verified r151.1 — composition order, LRU 8→cap4 w/ 4 evictions, reverse teardown all clean) |
| 2 | `05-threading` example | 6-8 hours | [x] (host-verified r152.2 — 22-core host vs 2.0 quota; pool=2 best throughput+p99, pool=8 p99 72x worse) |
| 2 | `07-state-externalization` example | 8-10 hours | [ ] |
| 2 | `07-outbox-pattern` example (multi-service) | 12-16 hours | [ ] |
| 2 | `08-ephemeral-filesystem` example | 4-6 hours | [ ] |
| 2 | `09-health-checks` example | 6-8 hours | [ ] |
| 3 | Bidirectional cross-references | Folded into Phase 2 | [ ] |
| 4 | `test-all-stateless-demos.sh` aggregator + per-demo test scripts | 2-3 hours | [ ] |

**Estimated total effort:** Phase 1 + Phase 2 + Phase 4 ≈ 55-75
hours of part-time work. The `07-outbox-pattern` example is the
single biggest item now that it's scoped as a real multi-service
producer + relay + consumer setup (resolved Q4).

## 12. Open questions

All five initial open questions were resolved on 2026-05-17; kept
here with their resolutions for the record.

- **Q1 (resolved).** Test runner — separate aggregator
  `scripts/test-all-stateless-demos.sh` plus per-example test
  scripts `scripts/test-stateless-demo-NN-<name>.sh`, mirroring the
  main tutorial's split. The two aggregators stay separate; a
  `test-everything.sh` umbrella is optional and not required.
- **Q2 (resolved).** Yes — each example gets a generated Jekyll
  page under `_examples/statelessness-NN-name.md`, same format as
  the top-level project demo pages, so they appear in the
  `/examples/` gallery.
- **Q3 (resolved).** Example directories match the compendium doc
  number + section name (`02-raii`, `03-pmr`, …). The two Doc-07
  examples share the `07-` prefix; the Outbox one uses the pattern
  name (`07-outbox-pattern`) as the differentiator.
- **Q4 (resolved).** The `07-outbox-pattern` example is a real
  multi-service setup — producer service + outbox relay + idempotent
  consumer — reflecting what the Outbox pattern actually does in
  production, rather than a single service polling its own outbox
  table in-process.
- **Q5 (resolved).** PostgreSQL client is **libpqxx** everywhere
  (mature, Conan Center, RAII transactions). The only hand-rolled
  piece is the `ScopedConnection` pool-checkout wrapper around
  `pqxx::connection` — required because libpqxx has no built-in
  pool, and the checkout / RAII-return / `invalidate()` flow is the
  teaching point of Doc 07. No hand-rolling of anything without
  demo value (i.e. not the libpq wire protocol).

No open questions remain. New questions that surface during Phase 2
get appended here.

## 13. Decision log

| Date       | Decision                                                                                       | Rationale |
|------------|------------------------------------------------------------------------------------------------|-----------|
| 2026-05-17 | Sub-project PRD created at `_plans/statelessness-compendium-prd.md`                            | Parallel structure to `_plans/reconciliation-plan.md`; lives alongside other planning artifacts |
| 2026-05-17 | "Compendium" as the normalized term for the `_reference/statelessness/` body of work           | User preference; signals the opinionated reference-work nature better than "document set" or "reference collection" |
| 2026-05-17 | 8 examples scoped, not 11 (one per compendium doc)                                             | Docs 01, 06, 10, 11 don't have demonstrable patterns of their own; constraint prevents scope creep |
| 2026-05-17 | Examples live under `examples/statelessness/NN-slug/`, not flat with the main demos            | Visual grouping; prevents demo numbering conflict; supports per-collection test orchestration |
| 2026-05-17 | `research-notes.md` reframed (option B), not deleted (option A)                                | The authoring narrative has value for extenders; the fix is reframing it as such, not hiding it |
| 2026-05-17 | Q1: separate `test-all-stateless-demos.sh` aggregator + per-example test scripts               | Mirrors the main tutorial's `test-all-demos.sh` + `test-demo-NN-*.sh` split; keeps the two collections' test runs independent |
| 2026-05-17 | Q2: per-example Jekyll pages under `_examples/statelessness-NN-name.md`                         | Same format as top-level demo pages; examples appear in the `/examples/` gallery |
| 2026-05-17 | Q3: example dirs match compendium doc number + section name                                    | Unambiguous example↔doc mapping from the directory name; two Doc-07 examples differentiated by pattern name |
| 2026-05-17 | Q4: `07-outbox-pattern` is a real multi-service setup (producer + relay + consumer)            | Reflects what the Outbox pattern actually does in production; a single-service in-process poller would misrepresent it |
| 2026-05-17 | Q5: libpqxx everywhere; only the `ScopedConnection` pool-checkout wrapper is hand-rolled       | libpqxx has no built-in pool, and the checkout/RAII-return/invalidate flow is Doc 07's teaching point; no demo value in hand-rolling the libpq wire protocol |

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
