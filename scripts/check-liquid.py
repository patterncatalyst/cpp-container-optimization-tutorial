#!/usr/bin/env python3
"""Static analyzer for Liquid build hazards in the Jekyll source.

Catches the two classes of bug that crashed the Pages build in r134 / r134.1
/ r134.2 before they reach CI:

    1. {{ var, other }}    — comma without a preceding filter pipe.
                              Valid Liquid is {{ var | filter: a, b }} (comma
                              is a filter-argument separator). Bare commas
                              are invalid and Jekyll errors out.

    2. {{ site.github.* }} — plugin-dependent reference that fails in the
                              GitHub Actions Pages build when the
                              jekyll-github-metadata plugin can't autodetect
                              the repo. Use {{ site.github_username }} /
                              {{ site.github_repo }} instead — those are
                              set explicitly in _config.yml and always
                              resolve.

The analyzer is context-aware:

    - Lines inside ``` fenced code blocks are skipped (the raw escape
      problem is handled by {% raw %}, not by this analyzer)
    - Mentions of {% raw %} or {% endraw %} inside `inline code spans` are
      NOT treated as actual raw markers (so prose discussing the tags
      doesn't fool the analyzer into thinking content is wrapped)
    - Files outside the Jekyll source (e.g., examples/*/README.md, which
      is in the build's exclude list) are not analyzed

Run before pushing to catch issues without waiting for the Pages build:

    ./scripts/check-liquid.py

Exits 0 if clean, 1 if any errors found. Useful in a pre-push hook.
"""
import re
import sys
from pathlib import Path


def strip_inline_code(line: str) -> str:
    """Strip `...` and ``...`` inline-code spans from a markdown line."""
    line = re.sub(r'``[^`]*``', '', line)
    line = re.sub(r'`[^`]*`', '', line)
    return line


def analyze() -> list[str]:
    errors: list[str] = []

    files = (
        list(Path("_docs").glob("*.md"))
        + list(Path("_plans").glob("*.md"))
        + list(Path("_reference").rglob("*.md"))
        + list(Path("_examples").glob("*.md"))
        + [Path("index.html"), Path("examples.html"), Path("diagrams.html")]
        + [Path("reference/statelessness.html")]
    )

    for f in files:
        if not f.exists():
            continue
        text = f.read_text()
        lines = text.split("\n")

        in_raw = False
        in_fence = False

        for i, line in enumerate(lines, 1):
            # Toggle fenced-code-block state
            if re.match(r'^```', line):
                in_fence = not in_fence
                continue

            cleaned = strip_inline_code(line)

            for m in re.finditer(r'\{%\s*(raw|endraw)\s*%\}', cleaned):
                in_raw = m.group(1) == 'raw'

            if in_raw or in_fence:
                continue

            # Pattern 1: {{ ... , ... }} without a filter pipe before the comma
            for m in re.finditer(r'\{\{([^|}]*),[^|}]*\}\}', line):
                if '|' not in m.group(1):
                    errors.append(
                        f"{f}:{i}: comma without filter pipe in {{{{...}}}}: "
                        f"{m.group(0)[:80]}"
                    )

            # Pattern 2: {{ site.github.X }} (plugin-dependent reference)
            if re.search(r'\{\{\s*site\.github\.', cleaned):
                errors.append(
                    f"{f}:{i}: site.github.* is plugin-dependent: "
                    f"{line.strip()[:80]}"
                )

    return errors


if __name__ == "__main__":
    errs = analyze()
    if errs:
        print(f"Liquid hazards — {len(errs)} found:")
        for e in errs:
            print(f"  {e}")
        sys.exit(1)
    print("Liquid hazards — none. Build should pass.")
    sys.exit(0)
