# Presentation

The PPTX deliverable for the C++ container optimization tutorial.

## Contents

```
presentation/
├── cpp-container-tutorial.pptx       # the deck (71 slides, ~2.0 MB)
├── build-notes.md                    # generation log (auto-written)
└── README.md                         # this file
```

## The deck

**Title:** *C++20/23 Performance Under Container Constraints*

**Format:** 16:9, 71 slides, ~2.0 MB. Designed for a 3-hour live talk
(approximately 2h 36m talk-time plus Q&A and demo-run buffer).

**Sections:** Sixteen numbered sections plus an appendix — the same
structure as the [companion site](https://patterncatalyst.github.io/cpp-container-optimization-tutorial/).
Section dividers, content slides, diagrams, code listings, and demo
cues for each of the seven runnable demos.

**Speaker notes:** Every slide has a full talking script in the notes
pane. Notes are written as spoken-language paragraphs, not bullet
expansions, so they read naturally during rehearsal and during the
talk itself.

**Visual style:** Dark navy + cyan accent palette borrowed from
[`patterncatalyst/quarkus-optimization`](https://github.com/patterncatalyst/quarkus-optimization)
for visual continuity with the author's other talks. Calibri for body
copy, Consolas for code blocks.

## Rebuilding the deck locally

One command, from the project root:

```bash
./tools/build-deck.sh
```

This handles both phases:

1. **SVG → JPG conversion** of the diagrams under `diagrams/` via
   `soffice` + `pdftoppm`. Cached in `/tmp/diagrams-png/` so
   subsequent rebuilds skip unchanged SVGs.

2. **PPTX assembly** via `python3 tools/build-pptx.py`, which reads
   slide content from `tools/sections.py` and writes the deck to
   `presentation/cpp-container-tutorial.pptx`.

Force a full re-conversion of the diagrams (e.g. after editing an SVG):

```bash
./tools/build-deck.sh --force
```

### Prerequisites

| Dependency | Why | Install on Fedora 44 |
|---|---|---|
| `python3` ≥ 3.10 | runs the build script | (preinstalled) |
| `python-pptx` | writes PPTX format | `pip install python-pptx` |
| `Pillow` | reads PNG dimensions for aspect-ratio sizing | `pip install Pillow` |
| `soffice` (LibreOffice) | SVG → PDF conversion | `dnf install libreoffice-impress` |
| `pdftoppm` (poppler-utils) | PDF → JPG conversion | `dnf install poppler-utils` |

The wrapper script checks each one and prints an install hint if
anything is missing.

### Visual QA

After rebuilding, render every slide to a JPG and eyeball the
output:

```bash
soffice --headless --convert-to pdf --outdir /tmp \
        presentation/cpp-container-tutorial.pptx
pdftoppm -jpeg -r 100 /tmp/cpp-container-tutorial.pdf /tmp/qa-slide
# then open /tmp/qa-slide-*.jpg in any image viewer
```

The most common defects after content edits are (a) code blocks
overflowing their dark background box and (b) diagrams extending
past the slide bottom. Both have auto-shrink logic in
`build-pptx.py`, but new content can still hit edge cases.

## Editing the deck

There are two files to edit, with a clear separation of concerns:

| File | What lives here |
|---|---|
| `tools/sections.py` | Slide content + speaker scripts. Edit this to change what's said. |
| `tools/build-pptx.py` | Design tokens (colors, fonts, layouts) + slide builders. Edit this to change how things look. |

`sections.py` is structured as a list of section dicts, each
containing a list of slide dicts. A slide dict has a `kind` field
that picks the builder, plus the content fields that builder needs:

```python
{
    "num": 4,
    "label": "Section 04",
    "title": "Container strategy",
    "tagline": "UBI vs ubi-micro vs scratch + multi-stage builds = Demo 1",
    "divider_notes": "Speaker script for the section opener...",
    "slides": [
        dict(kind="diagram",
             title="Multi-stage build: separate builder from runtime",
             diagram=f"{DG}/04-image-strategy-multistage.jpg",
             caption="One Containerfile, two stages...",
             notes="Speaker script for this slide..."),
        # ... more slides
    ],
}
```

After editing, run `./tools/build-deck.sh` and the PPTX updates in
place.

## Slide kinds

The build script supports nine slide kinds, each with its own layout:

| Kind          | Use                                  | Example  |
|---------------|--------------------------------------|----------|
| `title`       | Title slide (once)                   | Slide 1  |
| `agenda`      | Agenda grid (once)                   | Slide 2  |
| `divider`     | Section opener — big §-number        | Slide 4  |
| `content`     | Standard 2-column body + image/card  | Slide 5  |
| `content-code`| Body left, code block right          | Slide 13 |
| `stat-row`    | 4 big-number callouts in a row       | Slide 8  |
| `diagram`     | Full-width diagram, caption below    | Slide 9  |
| `demo-cue`    | Dark slide with DEMO N badge + cmd   | Slide 18 |
| `closing`     | Thank-you + three reference panels   | Slide 71 |

## Why programmatic generation (not a hand-edited PPTX)

The deck is driven from `tools/sections.py` rather than edited
directly so it stays in sync with the rest of the tutorial:

- **Content updates flow through one place.** Fix a stat in
  `sections.py`, rebuild, and every slide that quoted that stat
  updates together.

- **Design tokens are centralized.** All colors, fonts, and slide
  dimensions live in the `C`, `F`, and `FontFam` classes at the top
  of `build-pptx.py`. Changing the accent color is one line.

- **Reviewable diffs.** Git diff on a slide content change shows
  exactly what text was edited. Diff on a hand-edited `.pptx` shows
  binary noise.

- **Reproducible.** Same input commit → byte-identical output PPTX,
  on any host with the dependencies installed.

## Why PPTX, not reveal.js / Slidev / Marp

Per the project brief: PPTX is the deliverable. Easier to hand off
to colleagues, easier to embed in conference platforms, easier to
edit by anyone with PowerPoint, Keynote, or LibreOffice Impress. The
site is the long-form reference; the deck is the talk-time
companion.

## Status

**Built.** The deck renders cleanly from `tools/build-pptx.py` plus
`tools/sections.py`. Future polish rounds may add slide density
(currently 71 slides; we have headroom toward the 100-slide range)
and additional visual variety. See
[`_plans/reconciliation-plan.md`](../_plans/reconciliation-plan.md)
for the rounds-history.
