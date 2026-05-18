# Lessons Learned

A retrospective on building the C++ Container Optimization tutorial:
PRD + Jekyll site + seven runnable Podman demos + Excalidraw
diagrams + bibliography + PPTX deck, end-to-end over ~140 rounds of
iterative reconciliation.

**Audience for this doc:** the author, on their next similar
project. Cross-team readers welcome, but the framing assumes
someone about to build a long-form technical artifact with multiple
deliverables.

**What this doc is not:** a per-round changelog. The
[reconciliation plan](_plans/reconciliation-plan.md) is that, and
it has 21,000+ lines. This doc is the synthesis — the lessons that
generalize beyond this project.

Each lesson follows the same shape:

> **Symptom** — how the problem first appeared
> **Root cause** — what was actually broken
> **Resolution** — how we fixed it (with the round number if it
> matters)
> **Next time** — what to do differently from day one

---

## 1. Site engineering (Jekyll on GitHub Pages)

### 1.1 Liquid renders prose literally — every `{%` and `{{` is a hazard

**Symptom.** Random "Liquid syntax error" build failures, sometimes
minutes after content was merged. Failures were often the second or
third occurrence of a literal `{%` somewhere deep in prose.

**Root cause.** Jekyll's Liquid parser sees every `{%` and `{{` in
the source markdown, regardless of whether it's inside a code fence,
because Liquid runs *before* Markdown processing. Documenting Liquid
syntax in prose, or pasting code that contains a templating language
sample, is a guaranteed bug.

**Resolution.** `scripts/check-liquid.py` as a pre-push hook (r131).
The analyzer finds lone `{%` and `{{` that don't have matching
closers on the same line, and points at them with file:line. Authors
escape with `&#123;%` or wrap blocks in `{% raw %}...{% endraw %}`.

**Next time.** Install the analyzer on day one of any Jekyll
project. The cost is a few minutes; the cost of not having it is
unbounded — each escape is found at build time, not write time,
and the failure is always confusing because the literal you typed
looks correct.

### 1.2 Absolute `/path/` links bypass `baseurl` on Pages project URLs

**Symptom.** Links worked on `localhost:4000`, 404'd on
`patterncatalyst.github.io/cpp-container-optimization-tutorial/`.
Especially common with hand-typed cross-references in markdown.

**Root cause.** GitHub Pages project URLs serve the site under
`/<repo-name>/`. A markdown link to `/docs/foo/` becomes
`https://patterncatalyst.github.io/docs/foo/` — without the
`/cpp-container-optimization-tutorial/` prefix — and 404s.
(Gotcha G-63.)

**Resolution.** r138 internalization pass: every site-internal
link uses Liquid's `relative_url` filter:

```liquid
[the §10 observability stack]({{ '/docs/10-observability-profiling/' | relative_url }})
```

**Next time.** Enforce the `relative_url` filter via lint, not by
author convention. A regex pre-push hook against any markdown link
matching `^\[.+\]\(/.+\)` catches absolute links before they ship.

### 1.3 `configure-pages@v5` can return an empty `base_path`

**Symptom.** Workflow ran clean, site published, every single link
404'd. Build logs showed `--baseurl ""` being passed to Jekyll.

**Root cause.** GitHub's `configure-pages@v5` action sometimes
returns an empty string for `base_path` when it can't determine the
deployment path. The build step was passing that through as
`--baseurl "$BASE"` — overriding `_config.yml`'s correct setting
with an empty string. (Gotcha G-64.)

**Resolution.** r139 workflow guard:

```yaml
- name: Build with Jekyll
  run: |
    if [ -n "$BASE" ]; then
      bundle exec jekyll build --baseurl "$BASE"
    else
      bundle exec jekyll build
    fi
```

**Next time.** Never pass `--baseurl` explicitly on the command
line if `_config.yml` is correct. The CLI flag overrides the config
file, including when the CLI value is the empty string. If you must
pass it from CI, guard against empty.

### 1.4 Demo cross-references should stay internal to the site

**Symptom.** A reader following the tutorial's §6 prose clicks
"see Demo 2 for the measurement" and gets bounced from the site to
the GitHub source tree. Reader loses their place.

**Root cause.** Original architecture (r70-r135) had demo READMEs
as the source of truth. The site's section prose linked directly
to `github.com/.../examples/demo-NN-*/`. Reader experience: the
section opens a link, the link goes off-site, they have to find
their way back manually.

**Resolution.** r140 Tier 1 / Tier 2 link strategy:

- **Tier 1** — site-internal demo pages at `/examples/demo-NN-*/`,
  generated from the same READMEs. Tutorial sections link here.
- **Tier 2** — those demo pages link out to GitHub source for
  readers who want to clone or download.

**Next time.** Design the link topology *before* building either
set of artifacts. Identify which transitions stay on-site (most)
and which go off-site (few — clone, fork, download).

---

## 2. Content engineering (writing, editing, restructuring)

### 2.1 Round annotations are sticky — never write them in publishable content

**Symptom.** r135 stripped round annotations from `_docs/`. r141
found six more inside sentences. r142 found four more embedded in
SVG `<text>` elements and `aria-label` attributes.

**Root cause.** Round annotations like "r96 verified" or "Round B
results" get written during a round, intending to capture
verification provenance. They escape into:

- Inline prose: "the verified r96 numbers above"
- Section captions: "Demo-01 verified result (r20)"
- SVG text labels: `<text>PMR result (r96)</text>`
- SVG aria-labels (where the cleanup pass usually doesn't look)

**Resolution.** Three cleanup passes (r135, r141, r142). r142 also
added SVG-aware grep to catch annotations inside `<text>` and
`aria-label`. The reconciliation plan retains the full provenance;
reader-facing content does not need it.

**Next time.** Either:

1. Never write `r##` into anything that will be published. Use git
   commit messages, the reconciliation plan, or a separate
   `.notes` file. Or,
2. Adopt a literal annotation prefix (e.g. `(★r96★)`) that lints
   strip mechanically before publish.

Option 2 is more forgiving; option 1 is cleaner if you can
discipline the team.

### 2.2 Reading times drift as content grows

**Symptom.** r141 audit: section front matter declared
`duration: "15 minutes"`. Actual word count: 3,265 words → ~21
minutes at 150 wpm.

**Root cause.** Front matter `duration` is hand-set early in the
section's life. Content keeps growing through subsequent rounds.
The duration field doesn't auto-update.

**Resolution.** r141 walked every section, computed `words /
150 wpm`, updated five sections where drift exceeded 5 minutes.

**Next time.** Regenerate reading times from word counts as part
of a pre-publish lint. The reading time is derivative data; treat
it like a generated artifact, not authored content.

### 2.3 Demo renumbering cascades silently through prose

**Symptom.** §7 prose said "Still Demo 2" when describing the
allocator workload. Demo 2 was the STL-layout demo; the
memory-and-allocator workload had been split into Demo 6 at r70.

**Root cause.** Demo numbers were embedded directly in prose:
"Demo 2 territory", "Still Demo 2", "see Demo 5 for...". When
the demo set was restructured, prose updates required search-and-
replace across many files. Misses were inevitable.

**Resolution.** r141 outline rewrite reconciled all 17
section→demo mappings explicitly. r142 verification pass caught
the last few inside individual section bodies.

**Next time.** Refer to demos by descriptive name in prose ("the
allocator workload", "the noisy-neighbor demo"), and by number
only in tables and reference indexes. Lookup happens once, in the
table; prose references are stable across renumberings.

### 2.4 Editorial debt compounds; schedule it explicitly

**Symptom.** Every editorial cleanup round (r135, r141, r142) found
debt that had accumulated since the previous pass. Each pass took
2-3 hours of focused work.

**Root cause.** Content keeps changing. Tone, voice, and consistency
lints are scheduled (per-pass), not continuous (per-PR). New
material that doesn't match shipped material accumulates between
passes.

**Resolution.** Three editorial passes, each with a clear "remove
authoring artifacts" / "consistency" / "polish" focus. Reconciled
in the plan with file lists.

**Next time.** Editorial-debt lints in CI catch this incrementally:

- Round annotations: `grep -rE '\br[0-9]+\b' _docs/`
- Inconsistent voice: `vale` or `proselint` for "we" vs "you"
- Reading-time drift: regenerated from word counts
- Cross-reference rot: every `§N` is followed by a link or a number
  in a known set

Adding these on day one beats three explicit cleanup rounds at the
end.

---

## 3. Deck engineering (PPTX from a content data model)

### 3.1 Programmatic generation beats template editing above ~30 slides

**Symptom.** Reference Quarkus deck was 54 slides; our target was
80-120. Template-editing path required slide duplication via raw
XML, then per-slide edits. Estimate: 2-3 days of work plus
fragility on every content change.

**Root cause.** PPTX template editing scales O(n) in slides — each
slide is a separate XML file with its own placeholder text, its own
shape positions, its own font settings. Updates require touching
the same shapes across many slides.

**Resolution.** Programmatic generation via `python-pptx`:

- `tools/sections.py` — content as Python data (slide dicts with
  `kind`, `title`, `body`, `notes` fields)
- `tools/build-pptx.py` — renderer with design tokens + per-kind
  slide builders + dispatcher

Same content data drives any number of slides. Adding a new slide
kind takes ~30 lines of Python. Total deck build time: 4-6 hours
including QA iterations.

**Next time.** Above ~30 slides, default to programmatic
generation. Below ~30 slides, template editing is fine. The
break-even is roughly where you'd want to refactor your slides into
a consistent layout system anyway.

### 3.2 Design tokens transfer cheaply via extraction

**Symptom.** User wanted visual continuity with their existing
talks. Approach options: (a) literal template copy with content
overwrite, (b) build from scratch and try to match by eye, (c)
extract design tokens and re-apply.

**Root cause.** PPTX templates encode three things together —
design tokens (colors, fonts, dimensions), layouts (shape positions
and sizes), and content (text, images). Only the tokens are
reusable across talks; layouts and content are talk-specific.

**Resolution.** ~30 minutes of `grep -ohE` over the reference
deck's slide XML produced the actual color frequency table:

```
857  ECF0F1  pale gray  (body text on dark)
436  90A4AE  muted slate
409  00BCD4  cyan accent
345  FFFFFF  white
321  A8D8EA  soft blue (cards)
...
```

Top-15 colors became `C` class constants in `build-pptx.py`. Fonts
similarly. Visual continuity without coupling to the template
itself.

**Next time.** Do the extraction in 30 minutes. Three lines of
shell get you the most-frequent colors; three more get you the
fonts. You'll know more about the reference deck's design system
than the original author did.

### 3.3 The SVG pipeline depends on what's actually installed

**Symptom.** Standard SVG-to-PNG paths (`rsvg-convert`, `cairosvg`,
`inkscape`) all unavailable in the build environment. Default
ImageMagick `convert` fell through to `rsvg-convert` and also
failed.

**Root cause.** The "obvious" SVG conversion tools assume a desktop
Linux install. Build environments and minimal containers don't have
them. `pip install cairosvg` requires C build deps that also aren't
present.

**Resolution.** Two-hop pipeline:

```bash
soffice --headless --convert-to pdf:"draw_pdf_Export" <svg>
pdftoppm -jpeg -r 160 -singlefile <pdf> <out>
```

Both tools are on Fedora 44 by default (LibreOffice for soffice,
poppler-utils for pdftoppm). Quality is excellent for diagrams. The
wrapper script caches conversions in `/tmp/diagrams-png/` so
repeated rebuilds skip unchanged SVGs.

**Next time.** Try `soffice + pdftoppm` first. It's installed
wherever LibreOffice is, which is most Linux dev environments. The
"proper" SVG converters aren't worth the install fight when the
fallback works.

### 3.4 Aspect-ratio sizing + auto-shrink prevent ~80% of slide overflow

**Symptom.** Every other render had a defect: diagram extending
past the slide bottom, code block spilling out of its dark
background box, footer text colliding with the diagram caption.

**Root cause.** First-pass slide builders use fixed-width image
insertion (`width=Inches(11.3)`) and fixed font sizes. Tall diagrams
overflow vertically. Long code blocks overflow the container shape.

**Resolution.** Two specific fixes:

```python
# Aspect-ratio sizing for diagrams
from PIL import Image
with Image.open(diagram_path) as img:
    px_w, px_h = img.size
aspect = px_w / px_h
if aspect >= avail_w / avail_h:
    draw_w, draw_h = avail_w, avail_w / aspect
else:
    draw_h, draw_w = avail_h, avail_h * aspect

# Auto-shrink for long code blocks
if n_lines > 28 or max_line > 70:
    font_size = Pt(10)
elif n_lines > 22 or max_line > 60:
    font_size = Pt(11)
else:
    font_size = Pt(12)
```

**Next time.** Implement aspect-ratio sizing in the *first* version
of any image-bearing slide builder. Same for code blocks: every
code-bearing slide builder should have an auto-shrink threshold
from day one. The cost is ~20 lines per builder; the cost of
fixing it after the fact is multiple QA rounds.

### 3.5 Speaker scripts ≠ bullet expansions

**Symptom.** First-pass speaker notes were bullet text repeated
into the notes pane. Useless for rehearsal: the presenter already
sees the bullets on screen.

**Root cause.** The easy default for "generate speaker notes" is to
flatten the visible bullet list into prose. The reader's brain does
that automatically when looking at the slide.

**Resolution.** Speaker notes are spoken-language prose, ~350 words
per slide, first-person, contractions. They cover what the
presenter *says*, not what the slide *shows*. The slide is the
visual aid; the notes are the script.

```python
set_notes(slide,
    "We covered seventeen sections, seven demos, the bibliography, "
    "and the reproducibility story. Three places to go from here: "
    "..."
)
```

**Next time.** Write the speaker script in the same authoring pass
as the slide content, not afterward. The slide content suggests the
talking points; the script captures them at delivery cadence. Doing
them together forces consistency between visual and verbal.

---

## 4. Process lessons (project shape, decisions, retrospectives)

### 4.1 Some dependencies should be dropped, not worked around

**Symptom.** jemalloc 5.3.1 + GCC 14: build kept failing on
conformance issues in jemalloc's pre-2024 C source. Four cycles of
"one more Conan recipe tweak" / "one more env-CFLAGS injection"
didn't converge.

**Root cause.** Sunk cost. Each cycle felt close to a solution; in
aggregate, the four cycles consumed enough time to question whether
the dep was essential or aesthetic.

**Resolution.** r136 dropped jemalloc from demo-06's variants. The
section prose retains the design discussion for readers who want to
compare designs; only the binary variant was removed. mimalloc
stayed (static-linked, no glibc dependency, didn't fight the
toolchain).

**Next time.** Set a fix-attempt budget on every dependency
problem. 2-3 rounds is typical; after that, the question stops
being "how do I fix this" and starts being "is this dep essential
or aesthetic?" Aesthetic deps that fight the toolchain get dropped.

### 4.2 The reconciliation plan was the right artifact

**Symptom.** This project has 140+ rounds. Without a per-round
audit trail, "what we did vs. what we said we'd do" would be
unreconcilable. The PRD says one thing; reality is different;
without the plan, you can't tell what's drift vs. design.

**Root cause.** PRD is "what we intend"; reality drifts as
constraints land. The PRD update at end-of-project (r143) was only
possible because the plan captured each drift event as it
happened.

**Resolution.** Append-only reconciliation plan. Every round gets
an entry with trigger, approach, findings, fixes, verification,
files changed. ~21,000 lines total. Not for reader consumption; for
provenance.

**Next time.** Create the plan template before the first round.
The reconciliation plan is the second file in any long project,
right after the README. It's append-only and never edited (only
amended via new entries).

### 4.3 PRD reconciliation belongs at end-of-project, not mid-flight

**Symptom.** PRD §10 listed 10 anticipated risks. None of the 11
risks that *actually* bit during development appeared on that list.
Updating the PRD as each new risk was discovered would have meant
constant PRD churn and a confusing audit trail.

**Root cause.** Anticipated risks are necessarily impressionistic.
They reflect the author's mental model at PRD-time. Encountered
risks reflect reality.

**Resolution.** r143 added an "Encountered risks" table alongside
the "Anticipated risks" table. Both kept. The PRD now records both
the model and the reality, and the gap is the project's most
interesting takeaway.

**Next time.** Leave a placeholder section in the PRD for an
"Encountered risks" table from the start. Populate it with one
round of writing at end-of-project. Don't churn the PRD mid-flight.

### 4.4 Multi-round work needs structural separation between draft and shipped

**Symptom.** r135, r141, r142 each found round annotations because
each round wrote some. Three cleanup passes; the third still found
SVG-embedded annotations.

**Root cause.** Round annotations are useful during a round
("this is the r96 measurement") and useless after. Writing them
into the same file as the published content guarantees they'll
sometimes ship.

**Resolution.** Three cleanup passes against three different
embedding sites (markdown headers, inline prose, SVG metadata).
Plus the lint suggestion from §2.4.

**Next time.** Separate draft state from published state at the
file-system level if you can. `_drafts/` vs `_docs/` is the
Jekyll convention but most teams skip it for solo work. Reconsider
that skip. The cost of keeping the boundary is small; the cost of
not having it is unbounded.

### 4.5 Build wrappers earn their complexity instantly

**Symptom.** Rebuild instructions were a multi-step shell snippet
buried in `presentation/README.md`. Following them once was fine.
Following them on every content change would be friction.

**Root cause.** Documented procedures are bad UX for procedures
you run repeatedly. The friction compounds.

**Resolution.** r142.1 added `tools/build-deck.sh` — one command,
idempotent caching, prereq checks with install hints. README
points at the wrapper; the multi-step shell snippet is gone.

**Next time.** Any procedure you run more than three times
deserves a wrapper script. Wrapper benefits compound: it's
self-documenting, it's testable, it surfaces missing prereqs
clearly, and it can grow flags without complicating the docs.

---

## What earned its complexity (keep doing)

1. **The reconciliation plan.** Append-only, every round, full
   context. Cost: ~20 minutes per round to write. Benefit:
   ability to reconcile PRD with reality at end-of-project.

2. **Per-section reading times in front matter.** Cost: trivial
   (one front-matter field). Benefit: readers know what they're
   signing up for; CI lint catches drift.

3. **Programmatic deck generation.** Cost: ~1,000 lines of Python.
   Benefit: deck stays in sync with `_docs/`; content edits flow
   through one place; reviewable diffs.

4. **Annotated bibliography.** Cost: one page (~250 lines of
   markdown). Benefit: readers asking "which book next" get a
   single, opinionated answer with cross-references.

5. **Gotcha catalog with G-numbers.** Cost: minimal per entry.
   Benefit: cross-reference between rounds; section prose can
   point at a known ID.

6. **Per-demo Jekyll wrapper pages.** Cost: one generator script
   (`regen-examples-collection.sh`) + a layout. Benefit:
   site-internal demo navigation; READMEs remain authoritative
   for terminal users.

## What didn't earn its complexity (would skip or restructure)

1. **The 1.5h PPTX cut.** Planned at PRD time; dropped at r136 as
   a maintenance burden producing a strictly inferior experience.
   Should never have been on the roadmap. Lesson: pick one cut and
   commit.

2. **Hand-edited demo numbering in prose.** Section prose
   referenced demos by number directly ("Demo 2 territory"). Each
   demo renumbering cascaded into search-and-replace bugs. Lesson:
   refer to demos by descriptive name in prose; tables hold the
   number↔name mapping.

3. **Round annotations in content.** Useful during a round,
   harmful afterward. Lesson: separate draft and shipped state at
   the file-system level; commit messages and the reconciliation
   plan hold the provenance.

4. **`r##.N` sub-round numbering for small follow-ups.** r142.1
   and r142.2 were trying to signal "this is a small polish".
   Reader of the plan doesn't care; just call them r143 and r144.
   Lesson: rounds are monotonic integers, full stop.

5. **Initial template-editing approach for the PPTX.** Briefly
   considered before pivoting to programmatic. Should have gone
   programmatic from the start at this slide count. Lesson: above
   ~30 slides, the templating choice is forced.

---

## Day-1 setup checklist for a similar project

If you're starting a long-form multi-deliverable technical project
tomorrow, copy this and tick as you go:

- [ ] **PRD outline** with these sections: problem, audience,
      scope, success metrics, anticipated risks, **encountered
      risks (empty placeholder)**, decision log
- [ ] **Reconciliation plan template** — append-only, first entry
      is "r0: scaffold initialized"
- [ ] **Repo structure** with separate directories for content
      (`_docs/`), code (`examples/` or `src/`), deliverables
      (`presentation/`, dist), and tooling (`tools/`, `scripts/`)
- [ ] **`.gitignore`** for build artifacts, `__pycache__`,
      `_site/`, `node_modules/`
- [ ] **Pre-push lints in CI** with these checks at minimum:
      - Liquid hazards (if Jekyll)
      - `relative_url` filter on internal links (if GitHub Pages)
      - Round annotations (`grep -rE '\br[0-9]+\b'`)
      - Reading-time drift (front-matter vs word count)
      - Dead cross-references
- [ ] **Gotcha catalog template** — append-only, one ID per
      gotcha, with symptom / cause / resolution / next-time
- [ ] **Decision log section** in PRD with first entry on the day
      you commit the PRD
- [ ] **Build wrapper script(s)** with prereq checks and install
      hints for every deliverable that takes more than two steps
      to produce
- [ ] **One paragraph in README** explaining the multi-deliverable
      shape so a fresh reader can navigate

The setup cost is ~2 hours. The cost of skipping it is paid in
cleanup rounds and PRD reconciliation work at the end. The
break-even is around round 20.

---

## Project numbers (for calibration on the next project)

- Rounds completed: 144 (r0 through r143; r142 had two follow-ups)
- Total reconciliation plan length: ~22,000 lines
- Gotcha catalog size: 64 entries (G-01 through G-64)
- `_docs/` size: 17 markdown files, ~46,000 words
- Demos: 7, each with its own Containerfile + compose + docs
- Diagrams: 15 main (paired SVG + Excalidraw JSON) + ~12 reference
- PPTX deck: 71 slides, 16:9, ~25,000 words of speaker notes
- Bibliography page: 4 annotated books + suggested reading orders
- Editorial passes: 3 (r135, r141, r142) — each found ~10
  authoring-artifact instances missed by the previous pass
- Largest single content delivery: r142 (~33,000 lines added)
- Hardest dependency to fight: jemalloc 5.3.1 + GCC 14 (dropped
  after 4 cycles)
- Most-rewarded discipline: writing the reconciliation plan entry
  *before* committing each round's code

The total wall-clock time is hard to estimate from this side of it;
the rough order-of-magnitude is "several intense weeks of part-time
work, spread over multiple months." On the next project, expecting
roughly the same shape — most of the rounds in the middle 80%, the
first 10% setup and the last 10% reconciliation and polish — is a
reasonable planning prior.
