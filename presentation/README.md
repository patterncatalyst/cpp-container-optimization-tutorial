# Presentation

This directory will hold the PPTX deliverable when round 11 of the
build-out lands. Until then it's a placeholder so the folder exists
in git for the build pipeline to target.

## Planned contents

```
presentation/
├── cpp-container-tutorial.pptx       # the deck itself
├── speaker-notes.md                  # slide-by-slide commentary
├── 1.5h-cut.md                       # which slides to skip for the short cut
├── 3h-cut.md                         # the full talk-through
├── pre-recorded-demo-videos/         # MP4 captures for the 1.5h cut
└── README.md                         # this file
```

## How the deck gets built

The plan (round 11) is to drive the deck programmatically from the
tutorial content under `_docs/` so the slides and the site stay in
sync:

1. A Python script (`tools/build-pptx.py`) reads each `_docs/<NN>-*.md`,
   pulls the `title`, `description`, and section diagram, and lays
   them out as one slide per major H2 heading.
2. SVGs from `diagrams/<name>.svg` are embedded into the deck (not
   linked) so the .pptx is self-contained.
3. Speaker notes are generated from the prose body, paragraph by
   paragraph, into the slide notes pane.
4. The two cuts (1.5h and 3h) are produced by a flag on the build
   script that includes/excludes specific sections per `PRD.md`.

This approach is borrowed from
[`patterncatalyst/otel-observability-demos`](https://github.com/patterncatalyst/otel-observability-demos),
which uses `tools/build-diagrams.py` for a similar
"single-source-of-truth → multiple deliverables" workflow.

## Why PPTX not reveal.js / Slidev / Marp

Per the project brief: PPTX is the deliverable. Easier to hand off
to colleagues, easier to embed in conference platforms, easier to
edit by anyone with PowerPoint or Keynote. The site is the
long-form reference; the deck is the talk-time companion.

## Status

**Not yet built.** Round 11 produces this. See
[`_plans/reconciliation-plan.md`](../_plans/reconciliation-plan.md)
for the full round table.
