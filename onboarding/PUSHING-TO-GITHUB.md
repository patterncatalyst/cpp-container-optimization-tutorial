# Pushing this scaffold to GitHub

This is a brand-new project tree generated outside any git context.
Below is the exact sequence to land it in a fresh GitHub repo.

## 1. Edit the placeholder fields

Before the first commit, replace these placeholders so the deployed
site links resolve correctly:

| File                         | Field                       | Replace with                         |
|------------------------------|-----------------------------|--------------------------------------|
| `_config.yml`                | `github_username:`          | your GitHub username or org          |
| `_config.yml`                | `baseurl:`                  | `/<repo-name>` if not the default    |
| `LICENSE`                    | year, name                  | the actual year and copyright holder |
| `README.md`                  | repo URL in the header      | the canonical repo URL               |

## 2. Create the empty repo on GitHub

Either through the web UI or with the GitHub CLI:

```bash
gh repo create <username>/cpp-container-optimization-tutorial --public --source=. --remote=origin --push=false
```

If you used the web UI, take note of the SSH URL
(`git@github.com:<username>/cpp-container-optimization-tutorial.git`).

## 3. Initialize and push

From the project root:

```bash
git init
git branch -M main

git add -A
git commit -m "Initial scaffold: PRD, plan, Jekyll skeleton, six demos, observability stack"

# If you didn't use `gh repo create`, add the remote manually:
git remote add origin git@github.com:<username>/cpp-container-optimization-tutorial.git

git push -u origin main
```

## 4. Enable GitHub Pages

In the repo settings, under **Pages**:

- **Source:** GitHub Actions
- The `pages` workflow at `.github/workflows/pages.yml` will run on the
  next push to `main` and deploy the Jekyll site automatically.

The first deploy takes ~3 minutes. The site will be at
`https://<username>.github.io/cpp-container-optimization-tutorial/`.

## 5. (Optional) Enable the demos workflow

`.github/workflows/demos.yml` runs the demos that don't need
Fedora 44-specific kernel features on every PR. The full suite (gated
by the `run-full-suite` PR label) targets a self-hosted runner labeled
`fedora-44`. To set one up:

1. On a Fedora 44 box, install Podman and the actions runner.
2. Register it with your repo, adding the labels `self-hosted, fedora-44`.
3. Apply the `run-full-suite` label to a PR; the `full-suite` job will
   pick it up.

## 6. Verify the scaffold builds

A quick local check before pushing:

```bash
# Site
bundle install
bundle exec jekyll build
bundle exec jekyll serve  # http://127.0.0.1:4000

# Scripts (syntax only — doesn't run podman)
find . -name '*.sh' -exec bash -n {} \;
```

For deeper local verification, run the demos themselves with
`./examples/demo-XX-*/demo.sh` or `./scripts/test-all-demos.sh`.

## What's left after the first push

See `_plans/reconciliation-plan.md` for the running tally. The short
version: every section is drafted at outline level, every demo is
scaffolded and syntax-checked, and nothing has yet been **verified**
on a real Fedora 44 host. The reconciliation plan tracks the journey
from drafted → verified.
