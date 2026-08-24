# Contributing

Short version: this project uses **Conventional Commits** with a small
fixed set of types listed below. PRs should match the convention; CI
doesn't enforce it (yet) but reviewers will ask you to amend if not.

## Commit-message format

```
<type>(<scope>): <short summary>

<optional body, wrap at 72 chars>

<optional trailers, e.g. Fixes: #123>
```

- `<type>` from the table below.
- `<scope>` is **optional** but expected on `demo:`, `docs:`, `obs:`,
  and any change scoped to one section. Use `demo-01` ... `demo-07`
  for demo work, `§3` ... `§14` for section work, or omit when the
  change spans many areas.
- `<short summary>` is one line, **imperative mood**, ≤ 72 chars,
  no trailing period.
- The body is optional but encouraged for anything beyond a typo fix.
  Wrap at 72 chars.

### Types

| Type        | When to use                                                                          |
|-------------|--------------------------------------------------------------------------------------|
| `docs:`     | Tutorial prose under `_docs/`, README, PRD, plan updates                              |
| `site:`     | Jekyll layouts, includes, CSS, page structure under `_layouts/` `_includes/` `assets/`|
| `demo:`     | Anything inside `examples/demo-XX-*/` (sources, Containerfiles, demo.sh)              |
| `obs:`      | Anything under `observability/` (Grafana, Prom, Mimir, Tempo, Loki, OTel collector)   |
| `build:`    | CMake, Conan, Ninja config; cross-cutting toolchain changes                           |
| `ci:`       | `.github/workflows/`, test scripts under `scripts/`                                   |
| `chore:`    | Routine maintenance (dependency bumps, `.gitignore`, file moves, archive housekeeping)|
| `fix:`      | Bug fix in any of the above; **always** pair with the scope of the bug                |
| `feat:`     | New capability; **always** pair with the scope where it lands                         |
| `refactor:` | Reorganization without behaviour change                                               |
| `style:`    | Formatting only, no logic change                                                      |

### Examples

```
docs(§6): expand memory mgmt with cgroups v2, OOM, malloc_trim, LinuxMemoryChecker
```

```
fix(demo-01): pre-flight bugs blocking the verification pass

- CMakePresets pgo-use: hardcoded /pgo/default.profdata; ${} subst
  doesn't expand in preset cache vars.
- Containerfile.scratch-static: added libstdc++-dev to apk.
- demo.sh: source _helpers.sh, require podman curl jq hey,
  replace sleep 1 with wait_for_http, mkdir -p pgo-profiles always.
```

```
site: drop tutorial-page sidebar; cards-only homepage
```

```
chore: archive r03 — round 3 prose for §0 and §1
```

```
feat(obs): provision Grafana dashboard for demo-04 latency overview
```

### Subject-line cheat sheet

- "Add", "Drop", "Rename", "Move" — imperative verbs are right.
- "Added", "Dropped" — past tense is wrong; reword.
- "Updates docs" — vague; say *what* about the docs.
- "WIP" — fine on a feature branch, but squash before merge.

## When to split a commit

Each commit should leave the tree in a working state. If a single
change touches **multiple types** (e.g. you fixed a demo bug *and*
expanded the prose around it), prefer two commits:

```
fix(demo-02): pmr arena was 64 KiB instead of 1 MiB
docs(§5): explain why arena size matters for the comparison
```

over a single mixed-type commit. The exception: when the doc change
*explains* the fix and they share rationale; then bundle them and
say so in the body.

## Container image policy

**All container images we build use Red Hat UBI 10 as the base.**

- **Builder stage**: `registry.access.redhat.com/ubi10/ubi`
- **Runtime stage**: `registry.access.redhat.com/ubi10/ubi-minimal` (or
  `ubi10/ubi-micro` when even microdnf is overkill)

This is non-negotiable for any new Containerfile in `examples/`. UBI
gives us:

- a stable, supported base with predictable security patching
- consistent package availability across builder and runtime stages
  via `dnf` / `microdnf`
- no Docker Hub anonymous rate limit (UBI pulls from Red Hat's CDN)
- license clarity for redistribution

### Documented exceptions

One and only one:

1. **`observability/compose.yml`** pulls
   `docker.io/grafana/otel-lgtm:0.8.1` — the all-in-one Grafana Labs
   image bundling Grafana, Loki, Tempo, Prometheus, and an OTel
   Collector. Grafana Labs publishes the bundle only to Docker Hub.
   We chose the all-in-one image (instead of running each component
   separately) because the tutorial's focus is C++ optimization, not
   observability operations; one image instead of six is faster to
   pull and harder to misconfigure.

We also route Prometheus through Quay (`quay.io/prometheus/prometheus`)
where applicable; that's a registry-preference improvement, not an
exception.

### UBI without a Red Hat subscription

Every Containerfile that uses `registry.access.redhat.com/ubi10/ubi:` as
a build stage (the "full" UBI base, which uses `dnf` rather than
`microdnf`) must include this fragment **right after the `FROM` line**:

```dockerfile
# UBI w/o entitlement: silence subscription-manager.
# Free UBI repos in ubi.repo are unaffected — dnf install works normally.
RUN rm -f /etc/yum.repos.d/redhat.repo && \
    sed -i 's/^enabled=1/enabled=0/' \
        /etc/dnf/plugins/subscription-manager.conf 2>/dev/null || true
```

**Why**: UBI ships with `/etc/yum.repos.d/redhat.repo` configured to
fetch entitlement-only RHEL repos. Without a Red Hat subscription
registered inside the container (which we don't, and shouldn't), every
`dnf install` triggers the `subscription-manager` plugin to refresh
those repos. The refresh fails with `Unable to read consumer identity`
and on some configurations exits non-zero, killing the build. The
`redhat.repo` removal stops the refresh attempt; the plugin disable
silences any residual warnings.

**Free UBI content is unaffected** — the open `ubi-*-rpms` repos in
`/etc/yum.repos.d/ubi.repo` work without entitlement and provide
everything the demos need. UBI without subscription is a documented,
supported Red Hat configuration; we just need this one-line opt-out
of the entitlement plumbing that's also installed by default.

This applies only to **`ubi10/ubi`** stages. **`ubi10/ubi-minimal`**
uses `microdnf`, which has no subscription-manager plugin and no
`redhat.repo`; runtime stages on `ubi-minimal` need no fix.

### Adding a new exception

Don't, unless:

- you've checked Quay.io and the project's GHCR namespace and confirmed
  the upstream image isn't there, AND
- the exception is documented inline (a `# Note:` comment above the
  `FROM` or `image:` line stating *why* this image isn't UBI), AND
- the rationale is added to the list above in this section.

If a third-party image *does* publish to Quay or to a Red Hat registry,
prefer that path even if the docker.io path also works. The goal is
to minimize Docker Hub dependency, not just to satisfy a checkbox.

## AI-assisted authoring (optional MCP servers)

The repo ships a project-scoped [`.mcp.json`](./.mcp.json) with two **optional**
MCP servers for contributors who use Claude Code. They are author-time aids only
— **not** a prerequisite for building or running the demos (for that, see the
per-demo READMEs). Claude Code will ask you to approve project servers the first
time you open the repo; decline if you don't want them.

### `cpp` — semantic C++ navigation ([mcp-cpp](https://github.com/mpsm/mcp-cpp))

Wraps **clangd** + `compile_commands.json` to give symbol search, definitions,
usages, and call/inheritance graphs across the demo sources — far better than
`grep`/`cat` for C++ navigation.

```bash
# Install the server (the --locked flag avoids a dependency-resolution bug in
# the published 0.2.2 release; without it the build fails on rust-mcp-sdk):
cargo install mcp-cpp-server --locked

# Prereqs: Rust >= 1.85, clangd >= 11 (20+ recommended), and a
# compile_commands.json per demo you want indexed. Generate one with:
cd examples/demo-01-image-strategy && cmake --preset release   # pure-CMake demos
# Conan-based demos (most of examples/): configure with export on, e.g.
#   conan install . --output-folder=build/conan -s build_type=Release --build=missing
#   cmake -B build -DCMAKE_TOOLCHAIN_FILE=build/conan/conan_toolchain.cmake \
#         -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
```

`compile_commands.json` and `build/` are git-ignored (they're machine-specific),
so each contributor generates their own. The server's `--root` defaults to the
repo root, and `clangd` is found on `PATH` (or via `CLANGD_PATH`), so no paths
are hard-coded in `.mcp.json`.

### `context7` — up-to-date library docs ([Context7](https://github.com/upstash/context7))

Injects current, version-specific docs for the libraries the demos use (CMake,
Conan, gRPC, protobuf, abseil, OpenTelemetry-cpp, liburing) so generated code and
prose don't drift to a stale API (the Conan 1→2 and gRPC version traps in
particular). Registered **anonymously** (rate-limited, no secret in the repo).
For higher limits, add your own key at **user** scope — never commit it:

```bash
claude mcp add --scope user --transport http \
  --header "CONTEXT7_API_KEY: <your-key>" \
  context7 https://mcp.context7.com/mcp
```

### Not included: semgrep

Deliberately omitted. Its C/C++ analysis is largely redundant with demo-07's
existing quality pipeline (cppcheck + clang-tidy + ASan/UBSan + abidiff), and its
stronger niche (IaC/shell/YAML scanning) isn't core to this tutorial. Add it
per-user if you want ad-hoc scanning of Containerfiles.

## Reconciliation plan

Every substantive change should leave a corresponding entry in
[`_plans/reconciliation-plan.md`](./_plans/reconciliation-plan.md).
This is **not** a changelog — it tracks verification state, not the
list of commits. The rule of thumb:

- A code or docs change that you've personally walked through on
  Fedora 44 → flip the matrix row from `unverified` to `verified`,
  add a dated entry to the verification log.
- A code or docs change you haven't run end-to-end → leave the row
  as `unverified` and **say so** in the verification log if the
  surface area changed.

The reconciliation plan is the honest source of truth for what's
real vs. what's drafted-but-untested. Keep it honest.

## Branching and PRs

- Default branch: `main`.
- Branches: `feat/<thing>`, `fix/<thing>`, `docs/<scope>`. Anything
  short-lived.
- One commit per logical change is preferred; squash-merge is fine
  if review surfaced fixups.
- Force-pushing your own feature branch is fine; force-pushing
  `main` is not.
