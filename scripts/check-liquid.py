#!/usr/bin/env python3
"""Static analyzer for Liquid build hazards in the Jekyll source.

Catches the four classes of bug that crashed the Pages build in r134
through r134.4 before they reach CI:

    1. {{ var, other }}    — comma without a preceding filter pipe.
                              Valid Liquid is {{ var | filter: a, b }}
                              (comma is a filter-argument separator).
                              Bare commas are invalid and Jekyll errors
                              out.

    2. {{ site.github.* }} — plugin-dependent reference that fails in
                              the GitHub Actions Pages build when the
                              jekyll-github-metadata plugin can't
                              autodetect the repo. Use
                              {{ site.github_username }} /
                              {{ site.github_repo }} instead — those
                              are set explicitly in _config.yml and
                              always resolve.

    3. {% endraw %} inside  — added in r134.3. If a raw block contains
       a wrapping {% raw %}    a literal {% endraw %} mention anywhere
       block                   in its source (e.g., in prose discussing
                              the syntax), Liquid sees the FIRST literal
                              endraw and exits raw mode early. The real
                              closer becomes orphan; build fails with
                              'Unknown tag endraw'.

    4. Lone `{%` in prose   — added in r134.4. Liquid scans for the
       (no matching `%}`)     literal two-char sequence `{%` regardless
                              of backticks, code fences, or any markdown
                              context. If found, it expects `%}` to
                              close the tag. Multi-line tags exist for
                              {% include %} etc., but lone `{%` in
                              prose (e.g. an inline code span like
                              `{%` discussing what Liquid matches)
                              makes the parser consume content
                              indefinitely until it finds `%}`,
                              eventually erroring with 'Tag {% was not
                              properly terminated'.

                              Prose that needs to show the literal
                              tag syntax should use HTML entities:
                              &#123;% raw %&#125; / &#123;% endraw %&#125;.

The analyzer is context-aware:

    - Lines inside ``` fenced code blocks are skipped
    - Inline {% raw %}...{% endraw %} pairs are recognized and their
      contents excluded from hazard detection
    - {% raw %} / {% endraw %} mentions inside `inline code spans`
      (single-line backticks) are not treated as real tags during
      block-state tracking
    - Files outside the Jekyll source are not analyzed

Run before pushing:

    ./scripts/check-liquid.py

Exit 0 if clean, 1 if hazards. Useful in pre-push hook.
"""
import re
import sys
from pathlib import Path


RAW_TAG = re.compile(r'\{%\s*raw\s*%\}')
ENDRAW_TAG = re.compile(r'\{%\s*endraw\s*%\}')
INLINE_RAW_BLOCK = re.compile(r'\{%\s*raw\s*%\}.*?\{%\s*endraw\s*%\}', re.DOTALL)


def strip_inline_code(line: str) -> str:
    """Strip `...` and ``...`` inline-code spans from a markdown line."""
    line = re.sub(r'``[^`]*``', '', line)
    line = re.sub(r'`[^`]*`', '', line)
    return line


def strip_inline_raw(line: str) -> str:
    """Strip {% raw %}...{% endraw %} inline-block contents from a line."""
    return INLINE_RAW_BLOCK.sub('', line)


def analyze() -> list[str]:
    errors: list[str] = []

    files = (
        list(Path("_docs").glob("*.md"))
        + list(Path("_plans").glob("*.md"))
        + list(Path("_reference").rglob("*.md"))
        + list(Path("_examples").glob("*.md"))
        + [Path("index.html"), Path("examples.html"), Path("diagrams.html")]
        + [Path("bibliography.html")]
        + [Path("reference/statelessness.html")]
    )

    for f in files:
        if not f.exists():
            continue
        text = f.read_text()
        lines = text.split("\n")

        # First, find all multi-line {% raw %} ... {% endraw %} block bounds.
        # For each line that starts a raw block (first {% raw %} not yet
        # paired) we track until the next {% endraw %}. A multi-line raw
        # block CONTAINING a literal {% endraw %} in its prose (i.e., not
        # the actual closer) is a r134.3-class bug.
        in_raw_block = False
        raw_block_start_line = None
        raw_block_content: list[tuple[int, str]] = []
        in_fence = False

        for i, line in enumerate(lines, 1):
            # Toggle fenced-code-block state
            if re.match(r'^```', line):
                in_fence = not in_fence
                continue

            # Strip inline-raw blocks from the line for block-tracking
            line_for_blocks = strip_inline_raw(line)

            # ALSO strip inline code spans for block-tracking — `{% raw %}`
            # in inline code is a tag mention in prose, not a real tag
            line_for_blocks = strip_inline_code(line_for_blocks)

            if not in_raw_block:
                if RAW_TAG.search(line_for_blocks):
                    in_raw_block = True
                    raw_block_start_line = i
                    raw_block_content = [(i, line)]
                    # Check if it closes on the same line — already
                    # stripped by INLINE_RAW_BLOCK above, so we shouldn't
                    # see it here. If we do, it's a real multi-line.
            else:
                raw_block_content.append((i, line))
                if ENDRAW_TAG.search(line_for_blocks):
                    # Block closes properly here. Check if the content
                    # between start and here contained any literal
                    # {% endraw %} in prose (not in code/backticks) —
                    # which would have closed it early.
                    # Note: we already stripped backticks above, so if we
                    # see an endraw on an interior line, that's a bug.
                    interior_lines = raw_block_content[1:-1]  # exclude start & end
                    for il, lcontent in interior_lines:
                        # Strip backticks and code-fence content from the
                        # interior line; what remains and contains endraw
                        # is a hazard.
                        # Note this is approximate — fenced blocks within
                        # the raw block would need fence-state tracking
                        # nested. For our use, prose mentions are the
                        # common case.
                        ic = strip_inline_code(lcontent)
                        if ENDRAW_TAG.search(ic):
                            errors.append(
                                f"{f}:{il}: literal {{% endraw %}} inside "
                                f"wrapping raw block (started line "
                                f"{raw_block_start_line}); will close it "
                                f"early. Use HTML entities &#123;% endraw %&#125;"
                            )
                    in_raw_block = False
                    raw_block_start_line = None
                    raw_block_content = []

        if in_raw_block:
            errors.append(
                f"{f}:{raw_block_start_line}: unclosed raw block"
            )

        # Second pass: hazard detection. For each line, exclude:
        #   - lines fully inside a multi-line raw block
        #   - inline {% raw %}...{% endraw %} content
        #   - fenced code blocks
        in_raw_block = False
        in_fence = False
        for i, line in enumerate(lines, 1):
            if re.match(r'^```', line):
                in_fence = not in_fence
                continue

            line_for_blocks = strip_inline_code(strip_inline_raw(line))

            if not in_raw_block:
                if RAW_TAG.search(line_for_blocks):
                    in_raw_block = True
                    # Check if it also closes on same line
                    # (Already stripped inline; if {% raw %} appears w/o
                    # matching close, the block continues to next line.)
                    if ENDRAW_TAG.search(line_for_blocks):
                        in_raw_block = False
            else:
                if ENDRAW_TAG.search(line_for_blocks):
                    in_raw_block = False
                continue

            if in_raw_block or in_fence:
                continue

            # For hazard detection: strip inline raw + inline code
            inspect = strip_inline_raw(line)

            # Pattern 1: {{ ... , ... }} without filter pipe
            for m in re.finditer(r'\{\{([^|}]*),[^|}]*\}\}', inspect):
                if '|' not in m.group(1):
                    errors.append(
                        f"{f}:{i}: comma without filter pipe in {{{{...}}}}: "
                        f"{m.group(0)[:80]}"
                    )

            # Pattern 2: {{ site.github.* }} plugin-dependent reference
            # (must be in non-raw, non-code context)
            for m in re.finditer(r'\{\{\s*site\.github\.[a-zA-Z_]', inspect):
                errors.append(
                    f"{f}:{i}: site.github.* is plugin-dependent: "
                    f"{line.strip()[:80]}"
                )

            # Pattern 4 (r134.4): lone {% without matching %} on same line.
            # Liquid scans for literal `{%` regardless of backticks/code.
            # If it finds one, it expects the tag to terminate with `%}`.
            # Multi-line tags exist for `{% include %}` etc., but lone
            # `{%` in prose (e.g. discussing what Liquid matches) will
            # make the parser consume content indefinitely until it finds
            # `%}` somewhere — usually erroring with "Tag '{%' was not
            # properly terminated".
            #
            # We look at the line AFTER stripping inline raw (so legitimate
            # raw escapes don't count). Any remaining `{%` should be
            # followed by a matching `%}` on the same line OR be a known
            # multi-line tag opener like `{% include ... ` that's clearly
            # mid-tag.
            for m in re.finditer(r'\{%', inspect):
                rest_of_line = inspect[m.start():]
                if '%}' in rest_of_line:
                    continue  # tag terminates on same line — fine
                # Check if it's a known multi-line tag start (the tag
                # continues to the next line). The valid Liquid grammar
                # after `{%` should start with whitespace + a tag word.
                tag_word = re.match(r'\{%-?\s*(\w+)', rest_of_line)
                if tag_word and tag_word.group(1) in {
                    'include', 'include_relative', 'capture', 'for',
                    'if', 'unless', 'case', 'assign'
                }:
                    continue  # multi-line tag — usually fine
                # Otherwise: lonely {% in prose, parser will choke
                errors.append(
                    f"{f}:{i}: lone {{% with no matching %}} on same "
                    f"line (escape with &#123;%): {line.strip()[:80]}"
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
