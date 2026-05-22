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

Diagrams currently in the set:

| File basename                         | Section | Topic / thing                          |
|---------------------------------------|---------|----------------------------------------|
| `01-prerequisites-toolchain`          | §1      | toolchain layout                       |
| `02-introduction-four-layers`         | §2      | the four-layer mental model            |
| `02-threading-models`                 | §2      | C++ threading models — stack vs scheduler |
| `03-raii-discipline`                  | §3      | RAII vs manual cleanup leak paths      |
| `04-image-strategy-multistage`        | §4      | multi-stage image strategy             |
| `05-compile-time-pgo-flow`            | §5      | LTO / PGO build flow                   |
| `06-stl-layout-flat-vs-node`          | §6      | flat vs node containers                |
| `07-allocator-stack`                  | §7      | the allocator stack                    |
| `08-io-uring-rings`                   | §8      | io_uring SQ/CQ rings                   |
| `09-networking-veth-vs-host`          | §9      | container networking modes             |
| `10-observability-otel-stack`         | §10     | observability stack                    |
| `11-isolation-cgroup-tree`            | §11     | cgroup v2 weight & cpuset              |
| `12-debug-sidecar-pattern`            | §12     | ephemeral gdb sidecar                  |
| `13-reproducibility-conan-flow`       | §13     | hermetic build pipeline                |
| `14-pitfalls-avx512-mismatch`         | §14     | AVX-512 mismatch trap                  |
| `08-deadline-budget-flow`             | §8      | deadline budget propagation across hops |
| `11-cfs-throttling-timeline`          | §11     | CFS quota throttling vs tail latency   |
| `11-numa-local-remote`                | §11     | NUMA local vs remote access latency    |
| `13-abi-break-taxonomy`               | §13     | ABI-safe vs ABI-breaking changes       |

The last four are supplementary concept diagrams (a second figure for a
section) added to visualize a temporal or comparison concept the
section's primary diagram doesn't show.

### Statelessness compendium diagrams

The statelessness companion's diagrams live in
[`diagrams/statelessness/`](statelessness/), one per compendium doc,
named `NN-<topic>` to match Docs 01-11:

| File basename                  | Doc   | Topic / thing                          |
|--------------------------------|-------|----------------------------------------|
| `01-deployment-posture`        | Doc 01 | three scopes of state; stateless vs stateful |
| `02-raii`                      | Doc 02 | the `RequestContext` lifecycle         |
| `03-pmr`                       | Doc 03 | the layered monotonic + pool arena     |
| `04-process-scoped-state`      | Doc 04 | the composition root in `main()`       |
| `05-threading`                 | Doc 05 | the CPU quota vs `hardware_concurrency()` |
| `06-twelve-factor`             | Doc 06 | config binding times                   |
| `07-state-externalization`     | Doc 07 | the pool + RAII checkout + outbox      |
| `08-ephemeral-filesystem`      | Doc 08 | read-only rootfs; where writes go      |
| `09-health-checks`             | Doc 09 | startup/liveness/readiness + shutdown  |
| `10-grpc-microservices`        | Doc 10 | the capstone composition               |
| `11-build-tooling`             | Doc 11 | the build stack + the cgroup helper    |
| `07-outbox-sequence`           | Doc 07 | outbox: atomic write → relay → idempotent consumer |
| `09-probe-states-shutdown`     | Doc 09 | health state machine + ordered shutdown sequence |

The last two are supplementary sequence diagrams for the outbox example
and the graceful-shutdown flow, alongside each doc's primary diagram.

These are embedded inline in the compendium docs and in the companion
deck (`presentation/cpp-statelessness-compendium.pptx`).

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

## Status

The diagrams are drawn — both the main-track set (above) and the
statelessness compendium set are real hand-style Excalidraw diagrams,
embedded inline and rendered into their respective decks. When adding a new
diagram, follow the naming convention and style guidelines above, and
commit the `.svg` and `.excalidraw` pair together. The reconciliation
plan tracks diagram history.
