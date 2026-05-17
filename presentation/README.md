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

## How the deck gets built

The deck is driven programmatically from a content data model so it
stays in sync with the rest of the tutorial:

```
tools/sections.py       # human-edited content: section/slide data + speaker scripts
tools/build-pptx.py     # the renderer: design tokens + slide builders + dispatcher
diagrams/*.svg          # source diagrams (also rendered on the site)
/tmp/diagrams-png/*.jpg # PNG conversions for PPTX embedding
```

To rebuild from scratch:

```bash
# 1. Convert SVGs to JPGs (one-time; the JPGs cache in /tmp)
mkdir -p /tmp/diagrams-png
for svg in diagrams/*.svg; do
  cp "$svg" /tmp/diagrams-png/
  soffice --headless --convert-to pdf:"draw_pdf_Export" \
          --outdir /tmp/diagrams-png/ "/tmp/diagrams-png/$(basename "$svg")"
  name=$(basename "$svg" .svg)
  pdftoppm -jpeg -r 160 -singlefile \
           "/tmp/diagrams-png/$name.pdf" "/tmp/diagrams-png/$name"
  rm -f "/tmp/diagrams-png/$(basename "$svg")" "/tmp/diagrams-png/$name.pdf"
done

# 2. Run the build
python3 tools/build-pptx.py

# Output → presentation/cpp-container-tutorial.pptx
```

Requires `python-pptx` and `Pillow`.

## Visual-QA workflow

Convert to PDF and check the rendered output:

```bash
soffice --headless --convert-to pdf --outdir /tmp \
        presentation/cpp-container-tutorial.pptx
pdftoppm -jpeg -r 100 /tmp/cpp-container-tutorial.pdf /tmp/qa-slide
# Then view /tmp/qa-slide-NN.jpg in any image viewer
```

## Slide kinds

The build script supports six slide kinds, each with its own layout:

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
