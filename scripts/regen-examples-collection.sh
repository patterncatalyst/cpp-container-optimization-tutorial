#!/usr/bin/env bash
# Regenerate _examples/ Jekyll collection from each demo's README.md.
#
# The READMEs in examples/demo-NN-name/ are the source of truth for the
# demo's documentation (intended for terminal/GitHub readers). The Jekyll
# site renders the same content at /examples/demo-NN-name/ for browser
# readers. This script keeps the two in sync.
#
# Re-run whenever you edit a demo's README:
#
#   ./scripts/regen-examples-collection.sh
#
# RULE (from r134.1 hotfix): when emitting Liquid references into the
# generated frontmatter or body, use ONLY config values that are
# guaranteed to exist regardless of build environment — e.g.
# {{ site.github_username }} and {{ site.github_repo }}, which are set
# explicitly in _config.yml. Avoid plugin-dependent values like
# {{ site.github.repository_url }}: the jekyll-github-metadata plugin
# needs PAGES_REPO_NWO, repository: in config, or an origin remote to
# resolve, and the GitHub Actions Pages build doesn't always provide
# any of those where the plugin looks. Using config values keeps the
# pages building everywhere — local, Actions, mirror builds — without
# environment plumbing.
#
# The script:
#   - reads each examples/demo-NN-name/README.md
#   - extracts the first H1 as the page title
#   - extracts a one-line description (first non-heading paragraph)
#   - prepends Jekyll frontmatter
#   - writes to _examples/demo-NN-name.md
#
# Diff the result and commit. The _examples/ collection is regenerated
# content, but it's checked into the repo so Jekyll can build the site
# from the source tree without running this script as part of the build.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EXAMPLES_DIR="$REPO_ROOT/examples"
OUT_DIR="$REPO_ROOT/_examples"

mkdir -p "$OUT_DIR"

count=0
for demo_dir in "$EXAMPLES_DIR"/demo-*; do
    [ -d "$demo_dir" ] || continue
    demo_name="$(basename "$demo_dir")"
    readme="$demo_dir/README.md"

    if [ ! -f "$readme" ]; then
        echo "  SKIP $demo_name: no README.md"
        continue
    fi

    # The demo number for the Jekyll `order` field, e.g. demo-01-... -> 1
    order="$(echo "$demo_name" | sed -E 's/^demo-0*([0-9]+).*/\1/')"

    # Title: the H1 of the README, with the leading "# " stripped
    title="$(grep -m1 '^# ' "$readme" | sed -E 's/^# //')"

    # Description: the first real prose paragraph in the body, joined
    # into a single line. Skips:
    #   - the H1 itself
    #   - subheadings
    #   - code fences
    #   - "Tutorial section:" / "Tutorial sections:" cross-reference preamble
    description="$(awk '
        BEGIN { in_body = 0; in_para = 0; in_skip_para = 0 }
        /^# /  { in_body = 1; next }
        in_body && /^#/ { next }       # subheadings
        in_body && /^```/ { next }     # code fences
        in_body && /^$/ {
            if (in_para) exit          # end of first real paragraph
            in_skip_para = 0
            next
        }
        # Detect Tutorial section preamble — single para, skip it whole
        in_body && /^Tutorial section[s]?:/ {
            in_skip_para = 1
            next
        }
        in_body && in_skip_para { next }
        in_body {
            in_para = 1
            gsub(/^[ \t]+|[ \t]+$/, "", $0)
            printf "%s ", $0
        }
    ' "$readme")"

    # Trim trailing space, escape double-quotes for YAML, truncate at
    # ~240 chars at a word boundary.
    description="$(echo "$description" \
        | sed 's/[ \t]*$//' \
        | sed 's/"/\\"/g' \
        | awk '{
            if (length($0) <= 240) { print; exit }
            # Cut at last space within 240 chars, append ellipsis
            s = substr($0, 1, 240)
            cut = match(s, / [^ ]*$/)
            if (cut > 200) s = substr(s, 1, cut - 1)
            print s "…"
        }')"

    # Strip leading "# Demo N — Foo" from the README body when copying
    # (Jekyll renders title from frontmatter; the H1 would duplicate).
    body="$(awk '
        BEGIN { skipped_h1 = 0 }
        /^# / && !skipped_h1 { skipped_h1 = 1; next }
        { print }
    ' "$readme")"

    out_file="$OUT_DIR/$demo_name.md"
    {
        echo "---"
        echo "title: \"$title\""
        echo "description: \"$description\""
        echo "order: $order"
        echo "layout: example"
        echo "sectionid: examples"
        echo "permalink: /examples/$demo_name/"
        echo "demo_dir: $demo_name"
        echo "github_path: examples/$demo_name"
        echo "---"
        echo ""
        echo "> The full source for this demo lives in [\`examples/$demo_name/\`](https://github.com/{{ site.github_username }}/{{ site.github_repo }}/tree/main/examples/$demo_name) — clone the repo, \`cd\` in, and \`./demo.sh\`."
        echo ""
        echo "$body"
    } > "$out_file"

    count=$((count + 1))
    echo "  OK   $demo_name -> $(basename "$out_file") ($(wc -w < "$out_file") words)"
done

echo ""
echo "Regenerated $count example pages in $OUT_DIR"
