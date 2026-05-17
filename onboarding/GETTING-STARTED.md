# Getting started

This document walks you through what you need to install, where
to start reading, and how to run the demos and the site locally.

If you only want to *read* the published tutorial, you don't need
any of this — open the GitHub Pages URL listed in `_config.yml`'s
`url` setting (set after first deploy).

---

## 1. Host

The primary supported host is **Fedora 44 x86_64**. Fedora 43 is
best-effort. Other Linux distros and macOS via `podman machine`
will work for some sections, but the cgroup, NUMA, and `io_uring`
demos assume a real Linux kernel ≥ 6.0.

Confirm the basics:

```bash
cat /etc/fedora-release
uname -r          # need ≥ 6.0 for io_uring features used in demo 3
lscpu | grep -E 'Model name|Architecture|^Flags'
```

Note your CPU flags — the AVX-512 demo in §13 expects either
`avx2` or `avx512` to be present.

---

## 2. Toolchain

Install the C++ side:

```bash
sudo dnf install -y \
  gcc gcc-c++ \
  clang clang-tools-extra \
  cmake ninja-build \
  cppcheck \
  perf \
  bcc-tools bpftrace \
  libabigail \
  python3-pip
pip install --user 'conan>=2.0,<3'
```

Install the container side:

```bash
sudo dnf install -y podman podman-compose
```

Verify rootless works:

```bash
podman info | grep -E 'rootless|cgroupVersion|graphDriverName'
```

You want `rootless: true` and `cgroupVersion: v2`.

Install load + JSON tooling:

```bash
sudo dnf install -y jq
# `hey` — fetch latest release for your arch, e.g.:
curl -sSL -o ~/.local/bin/hey \
  https://hey-release.s3.us-east-2.amazonaws.com/hey_linux_amd64
chmod +x ~/.local/bin/hey
hey -version
```

---

## 3. Site (Jekyll)

Install the Ruby side:

```bash
sudo dnf install -y ruby ruby-devel rubygem-bundler @development-tools
bundle config set --local path vendor/bundle
bundle install
```

Run the site locally:

```bash
bundle exec jekyll serve --baseurl ""
# then open http://127.0.0.1:4000/
```

The `--baseurl ""` override matters when you're developing
locally, because `_config.yml` carries the project-Pages baseurl
that GitHub serves under in production.

---

## 4. Run a single demo

```bash
cd examples/demo-01-image-strategy
./demo.sh
```

Each demo is self-contained. Read the `README.md` in each demo
directory for what it does, what flags you can pass, and what
output to expect.

---

## 5. Run the full demo suite

```bash
./scripts/test-all-demos.sh
```

This runs every demo's test script in sequence and prints a
pass/fail summary. It does **not** fail-fast (per the skeleton
convention) — if you want to see all the failures after a
refactor, this is the script.

---

## 6. Bring up the observability stack alone

Demo 4 brings up the stack alongside an instrumented service. If
you want just the stack to point a different service at:

```bash
cd observability
podman compose up -d
# Grafana on http://127.0.0.1:3000  (admin / admin first login)
# Prometheus on http://127.0.0.1:9090
# Tempo on http://127.0.0.1:3200
# Loki on http://127.0.0.1:3100
# Mimir on http://127.0.0.1:9009
```

Tear down:

```bash
podman compose down -v
```

---

## 7. What to read first

1. [`PRD.md`](PRD.md) — what we're building and why
2. [`_plans/reconciliation-plan.md`](_plans/reconciliation-plan.md)
   — what's verified versus what's drafted
3. [`_docs/00-outline.md`](_docs/00-outline.md) — the section map
4. [`_docs/01-prerequisites.md`](_docs/01-prerequisites.md) — the
   reader-facing version of this document, for the published
   tutorial

If you're picking the project up mid-stream, the reconciliation
plan tells you the truthful state of things faster than reading
the prose.
