# Excalidraw diagrams

Each diagram is stored as a paired
`<file>.svg` (rendered, embedded inline and in the gallery)
and `<file>.excalidraw` (the editable JSON source).

The site references diagrams two ways:

1. **Inline in a tutorial section** — via
   `{% include excalidraw.html name="06-allocator-stack" caption="..." %}`.
   The include resolves to `diagrams/06-allocator-stack.svg`.
2. **Gallery view** at `/diagrams/` — every diagram referenced in
   `diagrams.html` shows up as a fullscreen-clickable card.

## Naming convention

`<section>-<topic>-<thing>.{svg,excalidraw}`

Examples that already have placeholders pointed at them:

| File basename                         | Section | Topic / thing                          |
|---------------------------------------|---------|----------------------------------------|
| `01-prerequisites-toolchain`          | §1      | toolchain layout                       |
| `02-introduction-four-layers`         | §2      | the four-layer mental model            |
| `02-threading-models`                 | §2      | C++ threading models — stack vs scheduler |
| `03-image-strategy-multistage`        | §3      | multi-stage image strategy             |
| `04-compile-time-pgo-flow`            | §4      | LTO / PGO build flow                   |
| `05-stl-layout-flat-vs-node`          | §5      | flat vs node containers                |
| `06-allocator-stack`                  | §6      | the allocator stack                    |
| `07-io-uring-rings`                   | §7      | io_uring SQ/CQ rings                   |
| `08-networking-veth-vs-host`          | §8      | container networking modes             |
| `09-observability-otel-stack`         | §9      | observability stack                    |
| `10-isolation-cgroup-tree`            | §10     | cgroup v2 weight & cpuset              |
| `11-debug-sidecar-pattern`            | §11     | ephemeral gdb sidecar                  |
| `12-reproducibility-conan-flow`       | §12     | hermetic build pipeline                |
| `13-pitfalls-avx512-mismatch`         | §13     | AVX-512 mismatch trap                  |

## Editing a diagram

```bash
# Open the source on excalidraw.com:
xdg-open https://excalidraw.com   # then drag the .excalidraw file in

# Or use the desktop app:
flatpak install flathub com.excalidraw.Excalidraw
flatpak run com.excalidraw.Excalidraw diagrams/06-allocator-stack.excalidraw
```

After editing:

1. **Save** the modified `.excalidraw` JSON over the old one.
2. **Export to SVG** at the same basename — File → Export → SVG, then
   rename to match (e.g. `06-allocator-stack.svg`). On the desktop app
   the Export dialog has a "Save as" path; on the web app, save and
   move into place.
3. Both files commit together. The gallery and inline embeds will
   pick up the change on the next Pages build.

## Style guidelines

- **One canvas, one idea.** If you need a second diagram, give it its
  own basename — don't pile concepts onto one canvas.
- **Excalidraw's "Hand-drawn" sketchy mode is the house style.** The
  visual contrast between the playful diagrams and the precise prose
  is part of what makes the tutorial scannable.
- **Label arrows.** "Why" the arrow exists matters more than the
  arrow itself; an unlabeled arrow is a missed teaching moment.
- **Use the accent color sparingly.** The C++ red `#c0392b` is for
  the *one* element you most want the reader to notice; using it on
  three things diffuses attention.

## Placeholder state

Until each diagram is drawn, this directory contains a placeholder
SVG and a minimal `.excalidraw` stub for every basename above. The
placeholders render as a gray box with the basename and a "draw me"
prompt — enough to verify the include and gallery wiring works
without making the page look broken.

Replace each placeholder pair as the diagrams are drawn. The
reconciliation plan's G.5 row tracks progress.
