---
title: "Onboarding"
permalink: /onboarding/
description: "Setup, repo workflow, and Claude-as-co-author workflow — everything needed to get from a fresh clone to a running demo."
---

# Onboarding

This folder collects the docs you read once when setting up the
project, then rarely again. The main [`README.md`](../README.md)
covers what's in the repository; these docs cover how to use it.

## Start here

1. [`GETTING-STARTED.md`](GETTING-STARTED.md) — Fedora 44 setup,
   Podman 5.x rootless, building the Jekyll site locally, running
   the first demo end-to-end. The fastest path from clone to a
   working `./demo.sh` invocation.

2. [`PUSHING-TO-GITHUB.md`](PUSHING-TO-GITHUB.md) — workflow for
   contributors who want their fork published as a GitHub Pages
   site. Covers the `_config.yml` overrides, the
   `.github/workflows/pages.yml` build, and the `gh-pages` branch
   semantics if you're not on Actions.

3. [`STARTING-WITH-CLAUDE.md`](STARTING-WITH-CLAUDE.md) — the
   meta-doc on how this tutorial was scaffolded with Claude as a
   collaborator. Useful if you're adapting the same approach for a
   different topic or want to understand the iteration cadence
   captured in `_plans/reconciliation-plan.md`.

## When to come back

- After a long break from the repo: re-skim
  [`GETTING-STARTED.md`](GETTING-STARTED.md)'s prerequisites
  section to confirm versions haven't drifted.
- Before opening a PR: skim [`PUSHING-TO-GITHUB.md`](PUSHING-TO-GITHUB.md)
  to check the Pages-build conventions.
- When evolving the tutorial: revisit
  [`STARTING-WITH-CLAUDE.md`](STARTING-WITH-CLAUDE.md) for the
  cadence that produced the existing material.
