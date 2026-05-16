# Starting with Claude

This document is the entry point for AI-assisted work on this
tutorial. It tells the assistant — and, more importantly, you — what
to read in what order so the assistant has the context it needs and
doesn't go off-script.

The skeleton's `STARTING-WITH-CLAUDE.md` describes the general
pattern. This document is the project-specific overlay.

---

## What to put in front of the assistant first

In this exact order:

1. [`PRD.md`](PRD.md) — the source-of-intent. The first thing the
   assistant reads at the start of every session. Skip this and
   the assistant will helpfully drift into related-but-out-of-scope
   territory, especially around Kubernetes and Docker comparisons.

2. [`_plans/reconciliation-plan.md`](_plans/reconciliation-plan.md)
   — the truthful state. The assistant should treat anything marked
   `unverified` as a draft to be tested, not a fact to be cited.
   When the assistant produces new prose with technical claims,
   add a row here in the verification log; do **not** mark it
   `verified` until something has actually been run.

3. The specific section's `_docs/NN-*.md` file you're working on.

4. The matching `examples/demo-NN-*/` directory if the section has
   a demo tied to it (most do — see PRD §5 for the mapping).

---

## What kinds of work suit AI assistance well here

- **Drafting** any of the §3-§14 sections from the PRD outline.
  The PRD says what each section needs to cover; the assistant
  can produce a zero-draft.
- **Stub-completing** demo `Containerfile`s, `compose.yml`s, and
  `demo.sh` runners from a clear specification.
- **Diagram first-cuts** in Excalidraw JSON from a prose
  description. (You'll redraw, but the JSON skeleton saves time.)
- **Test-script generation** following the existing
  `scripts/test-template.sh` shape.
- **Editorial passes**: tone consistency, vendor-neutrality,
  flagging "we" voice, catching displacive paraphrase of the
  reference books.

## What does NOT suit AI assistance well here

- **Performance claims**. Anything quantitative — "X is 2.3× faster
  than Y", "p99 drops from 8ms to 1.2ms" — must be measured on a
  real host, never written first and verified later. The
  reconciliation plan exists because of exactly this failure mode.
- **Kernel parameter recommendations** without a citation. There
  are a lot of cargo-culted sysctl lists on the internet; the
  assistant has read all of them. Each one used in this tutorial
  must be reproducible from the demos and traceable to the
  observed effect.
- **Reference-book content**. The four reference books (Andrist
  & Sehr, Iglberger, Enberg, Ghosh) are pointed-at, not summarized.
  If the assistant produces a "summary" of a chapter, treat it as a
  warning sign and rewrite as a pointer.

---

## Working session checklist

At the start of a session:

- [ ] Read `PRD.md` (3-min scan)
- [ ] Read the reconciliation plan's at-a-glance status
- [ ] Identify which section / demo you're working on
- [ ] Pull the matching `_docs/` and `examples/` files into context

At the end of a session:

- [ ] Update the reconciliation plan with what changed
- [ ] If anything was *verified* (actually run end-to-end), promote
  it from `unverified` → `verified (Fedora 44)` with a date
- [ ] If anything was added that diverges from the PRD, log it
  under "Known divergences from the PRD"
- [ ] Commit with a message that says what changed and what was
  verified

---

## Common pitfalls

- **Confidently-wrong build commands**: Conan 2.x syntax differs
  meaningfully from Conan 1.x. The assistant may produce Conan 1
  flags. Verify against `conan --version` output.
- **kernel feature drift**: `io_uring` features and behaviour
  differ between 5.x, 6.0, and 6.6+. Pin the kernel range in any
  io_uring discussion.
- **rootless cgroup limits**: not every cgroup controller is
  available rootless. `cpu`, `memory`, `pids`, `io` (when
  delegated) are; some are not. Anything claiming a controller
  works rootless without a `systemd-cgls` or
  `cat /sys/fs/cgroup/user.slice/.../cgroup.controllers` proof
  should be treated as unverified.
- **PGO instrumentation runs**: the assistant may produce a PGO
  flow that omits the workload step. There are three steps:
  instrumented build → run representative workload → final build
  with the resulting `.profdata`. Skipping step 2 produces a
  technically-correct-looking pipeline that gives no perf benefit.
