# Tutorial Backlog

Things we want to add eventually but aren't in the current option-1
plan. The reconciliation plan is round-by-round history; this file
is "let's not forget about this." When a backlog item gets pulled
into a real round, move it into reconciliation-plan.md and remove
it here.

---

## Optional segment: C++ and statelessness for services

**Status:** Logged 2026-05-11 (mid-r71) per user request.
**Updated 2026-05-16 (r90):** the deep-research reference material
(twelve documents, ~42,000 words) was integrated into the site as
`/reference/statelessness/` collection. The remaining open question
is whether to *also* fold the material into the tutorial body
proper — as a §3.5 sidebar, a §11 expansion, or its own §-numbered
optional section — vs. leave it as a self-contained reference set
that the tutorial body cross-references. The tutorial-body
integration is still in this backlog item; the
reference-collection landing is shipped.

**Why this belongs in the tutorial:** statelessness is one of the
load-bearing assumptions of modern container orchestration (Kubernetes
scaling, blue-green deploys, autoscaling-by-load), but it doesn't get
treated explicitly in any of the four source books because they're
focused on the C++ side, not the operational side. The C++ angle —
how the language's RAII discipline, exception-safety guarantees, and
the recent additions in C++17/20/23 interact with the
"forget-on-restart" model — is worth a deliberate segment.

The topic cuts across §3 (RAII), §4 (containers), §7 (memory), §9
(networking), and §11 (isolation) without sitting cleanly in any one
of them. That argues for a dedicated optional segment (a §3.5
sidebar, or an §X bonus chapter the speaker can include or skip
based on audience interest).

**Subtopics with enough material for prose:**

1. **Stateless vs stateful as a deployment posture, not a code
   property.** The C++ language doesn't impose either. The same
   binary can be "stateless" (replicas behind a load balancer,
   restart-tolerant) or "stateful" (singleton with in-memory cache,
   restart-painful). The decision lives in operational assumptions,
   not in the language. C++ devs coming from monolith backgrounds
   often miss this — they expect the binary to be one or the other.

2. **RAII as the foundation for safe stateful work inside a
   "stateless" service.** Even a stateless service has state during
   request processing (per-request buffers, parsed objects,
   connection-pool checkouts). RAII discipline draws the boundary
   between request-scoped state (dies with the request) and
   process-scoped state (dies with the process, which the
   orchestrator can recreate freely). The discipline is what makes
   "stateless service" practical to build.

3. **PMR's monotonic_buffer_resource as the architectural embodiment
   of request-scoped stateless allocation.** Direct callback to
   demo-06: each request brings its own arena, all allocations
   release together, no persistent state crosses request boundaries.
   The "stateless" property is enforced *by construction* in the
   memory model. This is the right pedagogical moment to introduce
   the PMR pattern as more than a performance optimization.

4. **Process-scoped state that's still stateless from the
   orchestrator's view.** Connection pools, DNS caches, the gRPC
   channel manager, the OTel provider singletons. These live for the
   process lifetime, are absolutely shared mutable state from a C++
   perspective, but are *not* state the orchestrator has to preserve
   across restarts — the new process recreates them in O(seconds).
   The distinction between "state that needs replicated/persisted"
   and "state that's just expensive to rebuild" matters.

5. **The 12-factor app principles as adapted to C++.** Most of the
   12-factor advice is language-neutral (config via env vars,
   stateless processes, treat-logs-as-streams, etc.) but a few items
   collide with C++ realities:
   - **III. Config via env.** C++'s `std::getenv` is fine, but C++
     idioms favor compile-time config (constexpr / templates). The
     12-factor philosophy is fundamentally runtime-config-first;
     reconciling that with C++'s compile-time optimization story
     takes some care.
   - **VI. Stateless processes.** The OTel provider singleton, the
     gRPC channel cache, mimalloc's internal arena state — all
     "process-level state" the C++ runtime maintains. Compatible
     with 12-factor because the orchestrator doesn't need to know
     about them, but the C++ dev needs to NOT rely on them
     surviving restarts.
   - **IX. Disposability** (fast startup + graceful shutdown).
     C++ excels at fast startup if you avoid global-constructor
     pile-ups (a known pitfall — heavy initialization at process
     start delays the first request and complicates orchestration's
     health checks). Graceful shutdown via SIGTERM is what demo-03's
     main() demonstrates.

6. **State externalization patterns in C++.** When the service
   genuinely has state that must survive restart, the standard
   pattern is to externalize: Redis, PostgreSQL, S3, Kafka.
   The C++ angle is the connection-pool RAII pattern, the
   "fail-fast vs retry-with-backoff" decision on connection loss,
   and the exception-safety implications of state-mutating
   operations across a network boundary.

7. **The ephemeral filesystem trap.** Container root filesystems
   are ephemeral by default; writes to `/var`, `/tmp`, or `/log`
   disappear on restart. C++ devs coming from monolithic
   deployments where "just write a log file" was correct need to
   internalize that the same code in a container produces data
   that's invisible to the operator. Demo-03's production compose
   (`compose.production.yml`) uses `read_only: true` precisely to
   make this trap fail loudly instead of silently.

8. **Health checks as the public-API of statelessness.** A truly
   stateless service can answer "are you alive?" without any
   external dependencies — same answer every time. A
   pretending-stateless service might answer "yes" based on
   internal cache state that's not what the orchestrator expects.
   The C++ angle: where do you put the health check endpoint?
   Demo-03 puts it inside the same binary on a separate port;
   demo-04 puts it on the same HTTP server as the workload.
   Both work; the trade-off (separate-port = isolation,
   same-port = simplicity) is worth discussing.

**Source material that already covers adjacent ground:**

- Andrist & Sehr, *C++ High Performance* 2e, Ch. 12 (concurrency)
  — touches on process-shared state without using the word
  "stateless"
- Iglberger, *C++ Software Design*, Ch. 6 (the Strategy pattern
  discussion intersects "swappable backend" which is the C++
  realization of state externalization)
- Enberg, *Latency*, throughout — implicitly assumes statelessness
  for replicas; doesn't address it explicitly
- Ghosh, *Building Low Latency Applications with C++*, ch. 2 (the
  market-data publisher and order gateway components are concrete
  examples of stateless-by-design message processors) and ch. 10
  (the client-side gateway is stateful by necessity — the contrast
  is instructive)

**No external sources are 12-factor-for-C++ specifically.** Most
12-factor writing assumes Go/Python/Ruby. There's an opening for
the tutorial to be the first careful treatment of how the 12-factor
principles interact with C++'s compile-time vs runtime configuration
duality, RAII discipline, and the specific singletons C++ libraries
tend to create (OTel providers, gRPC channel caches, allocator
state).

**Pedagogical structure when we eventually write this:**

A 30-45 minute optional segment in the deck, or a 1500-2000 word
prose section. Either way, the structure should be:

1. Open with the operational definition of stateless (forget-on-
   restart, scale-by-replica, no-cross-request-memory). Make the
   point that this is an operational property, not a language one.
2. Show what RAII discipline contributes to making "stateless"
   buildable. Cite Iglberger Ch. 3 on scoped resource management.
3. Walk through the 12-factor principles with C++ asterisks where
   they apply.
4. Demo connection: point at PMR's monotonic_buffer_resource (demo-
   06) as the in-language architectural support for request-scoped
   statelessness.
5. Production gotchas: ephemeral filesystem, global-constructor
   pile-up, hidden state in singletons.
6. Health-check patterns and what "alive" actually means.

**Cross-reference status:** none of the current §3, §4, §7, §9, §11
prose mentions statelessness explicitly. When this gets pulled in,
cross-references should be added bidirectionally (each affected §
points to the optional segment; the segment points back at each §'s
relevant subsection).

**Effort estimate:** 2-3 rounds. Less than a demo build-out. Could
fit between Round D and Round E of the option-1 plan if the user
wants it included, or be a standalone post-PPTX round.

---

## Cleanup: retrofit subscription-manager disable to demo-04's runtime stage

**Status:** Logged 2026-05-16 in r82. Small, mechanical, no behavior
impact, but worth doing for consistency.

Demo-04's Containerfile applies the subscription-manager DNF plugin
disable in its BUILDER stage (lines 8-12) but not its RUNTIME stage
(lines 130+). So `microdnf install libstdc++` during the runtime
image build still emits `librhsm-WARNING **: Found 0 entitlement
certificates` — same as demo-06 did before r82.

Demo-06's r82 fixed this in both stages cleanly. Demo-04 needs the
same one-line addition in its runtime stage.

**Effort estimate:** single-file edit, single commit, ~5 minutes.
No build difference (the warning is cosmetic), so no verification
needed beyond "image still builds clean."

**Pull-in trigger:** any future demo-04 round, or batched with
demo-01/02/03 audit when those reach the dnf/microdnf usage point.

See G-35 in `_plans/reconciliation-plan.md` for the full mechanism
discussion.

---

## Audit: same subscription-manager pattern in demos 01/02/03/05/07

**Status:** Logged 2026-05-16 in r82. Companion to the demo-04
cleanup above.

When demos 01/02/03/05/07 are built out (some are stubs, some are
shipped earlier rounds), their Containerfiles should be audited for
the same subscription-manager plugin disable pattern. Apply to BOTH
builder and runtime stages.

Current state by demo:
- demo-01: shipped, status unknown — audit when next touched
- demo-02: shipped, status unknown — audit when next touched
- demo-03: shipped, status unknown — audit when next touched
- demo-04: shipped, builder-only fix (see cleanup above)
- demo-05: stub, will get the fix when built out
- demo-06: shipped, both stages fixed in r82 ✓
- demo-07: stub, will get the fix when built out

**Effort estimate:** lumps naturally with each demo's next touch;
no dedicated round needed.

---

## Cleanup: demo.sh + verification scripts should short-circuit on `compose up` build failure

**Status:** Logged 2026-05-16 in r84. Minor UX cleanup.

When `compose up --build` fails (e.g. due to a compile error in
src/), the rest of the shell script keeps running. If the script
then invokes `hey` against ports where no containers ended up
listening, we get nonsense output like:

```
Requests/sec: 305945.7232
Error distribution:
  [1530012]  dial tcp 127.0.0.1:18601: connect: connection refused
```

Those numbers are TCP-RST throughput, not workload throughput.
Confusing if the user isn't reading carefully. Found during r83 →
r84 sequence when r83's main.cpp had a typo.

Fix: any script that runs `compose up` should `set -e` (or check
$? explicitly) and exit before any downstream load testing if
the build/start step fails.

Applies to:
- `examples/demo-06-memory-and-allocators/compose-serve.yml`'s
  documented usage (in README, currently a copy-paste sequence;
  worth making into a wrapper script that bails on build error)
- Any future verification scripts that combine compose + load
- The pattern for `demo.sh` in each demo

**Effort estimate:** small, ~30 minutes per script when next
touched. Not worth a dedicated round.

---

## Cleanup: demo-06's `./demo.sh` (batch mode) hasn't been verified since r88

**Status:** Logged 2026-05-16 during r90 planning. User noted that
the entire r80-r88 work on demo-06 has been driven via `podman
compose` commands directly; the original `./demo.sh` (batch-mode
comparison via `run-all.sh` inside a single container) was last
touched in r82 (subscription-manager fix) and never re-run after
the OTel work landed.

The batch-mode path should still work — it doesn't go through the
HTTP server, doesn't initialize OTel (env var unset), and only
exercises the 3 binaries' stdout-JSON output mode. But "should
still work" isn't "verified to still work."

**To verify:**

```bash
cd examples/demo-06-memory-and-allocators/
./demo.sh                        # default: 200 iters per variant
./demo.sh --iterations 1000      # bigger sample
./demo.sh --clean                # rebuild path
```

Expected: comparison table printed, identical hash across variants
(matching r79's verified `0xac09f54afe8c6152`), no librhsm
warnings (r82 fix), no errors.

**Effort estimate:** 5 minutes (image is already cached; just runs
the binaries). Roll into the next demo-06 touch.

---

## Cleanup: cross-doc linking in statelessness body docs

**Status:** Logged 2026-05-16 (r91). r91 added hot-links to all 82
"Doc NN" references on the 00-index landing page; the other 11 body
docs have ~265 cross-references in their prose ("see Doc 04",
"covered in Doc 05's threading section", etc.) that remain plain
text.

Per-doc reference counts (from `grep -oE 'Doc [0-9]+' | wc -l`):

```
01-deployment-posture.md     32 refs
02-raii.md                   14 refs
03-pmr.md                    14 refs
04-process-scoped-state.md   25 refs
05-threading.md              15 refs
06-twelve-factor.md          24 refs
07-state-externalization.md  21 refs
08-ephemeral-filesystem.md    9 refs
09-health-checks.md          23 refs
10-grpc-microservices.md     53 refs
11-build-tooling.md          36 refs
```

The `/tmp/link-index-refs.py` script used in r91 generalizes
cleanly — point it at any of these files and it will do the same
substitution with the same regex handling for "Doc NN–NN" range
patterns.

**Effort estimate:** 5-10 minutes plus a careful review. The same
script + a wrapper to apply it to each file. Cross-references in
the body docs use the same "Doc NN" convention consistently
throughout.

**Why deferred:** Not blocking anything; the 00-index page is the
primary navigation entry into the collection and that's where the
linking matters most for usability. Body-doc readers tend to
read sequentially or jump back to the index between docs.

---



**Status:** Logged 2026-05-16 during r90 planning per user observation.
A few markdown files at the project root look like leftovers from the
initial skeleton generation that have outlived their usefulness.

Audit results (from `ls -la` of project root):

**`PUSHING-TO-GITHUB.md`** — clearly a leftover. Describes the
first-time push of a freshly-scaffolded project to GitHub. The repo
is well past that point. Two options:
1. Move to `_docs/` under a "Project history / scaffold" section if
   we want to preserve the procedural record
2. Delete outright — git history preserves it

**`STARTING-WITH-CLAUDE.md`** — borderline. Describes what to put
in front of the AI assistant when working on the project. It IS
project-specific and useful (PRD.md → reconciliation-plan.md →
relevant section, etc.), but the file format is "first-time onboard
to using Claude with this project," which suggests it could live
under `_docs/contributing/` or similar. Currently excluded from
Jekyll build via `_config.yml`. Possibly keep at root since it's
meta about the development process.

**`GETTING-STARTED.md`** — keep at root. Genuine user-facing entry
point (host setup, run instructions, etc.). Currently excluded from
Jekyll build. Reasonable cleanup: link to it from `README.md` and
`index.html` if not already.

**User's observations that turned out NOT to need cleanup** (logged
for completeness, no action needed):
- "We have a `docs/` folder still" — searched; only `_docs/` exists.
  Likely confused with the underscored Jekyll collection name.
- "`verify-stacks.sh` and `pre-pull.sh` in main project" — already in
  `/scripts/`, not at root.

**Effort estimate:** 10-30 minutes depending on which path is chosen
for `PUSHING-TO-GITHUB.md` (delete vs preserve). Not blocking
anything.

---


(Other backlog items go here as they come up.)
