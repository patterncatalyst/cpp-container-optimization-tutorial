#!/usr/bin/env bash
# build-statelessness-deck.sh — rebuild the STATELESSNESS COMPENDIUM PPTX.
#
# Companion to build-deck.sh (the main deck). Same two phases:
#   1. SVG → JPG conversion for diagrams/statelessness/*.svg
#   2. Python build via tools/build-statelessness-pptx.py
#
# The main deck build (build-deck.sh) is untouched; both write into the same
# /tmp/diagrams-png cache (filenames don't collide).
#
# Run from the project root:
#   ./tools/build-statelessness-deck.sh           # incremental
#   ./tools/build-statelessness-deck.sh --force   # re-convert all SVGs
#
# Prerequisites: python3 + python-pptx + Pillow, soffice (LibreOffice),
# pdftoppm (poppler-utils).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DIAGRAMS_SRC="$ROOT/diagrams/statelessness"
DIAGRAMS_OUT="/tmp/diagrams-png"
OUT_PPTX="$ROOT/presentation/cpp-statelessness-compendium.pptx"

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

echo "==> Phase 1: SVG → JPG conversion (statelessness diagrams)"

for tool in soffice pdftoppm; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "  ERROR: '$tool' not found on PATH" >&2
        echo "  Install: dnf install libreoffice-impress poppler-utils (Fedora)" >&2
        exit 1
    fi
done

mkdir -p "$DIAGRAMS_OUT"
converted=0
skipped=0
for svg in "$DIAGRAMS_SRC"/*.svg; do
    name="$(basename "$svg" .svg)"
    jpg="$DIAGRAMS_OUT/$name.jpg"
    if [[ $FORCE -eq 0 && -f "$jpg" && "$jpg" -nt "$svg" ]]; then
        skipped=$((skipped + 1)); continue
    fi
    cp "$svg" "$DIAGRAMS_OUT/"
    soffice --headless --convert-to pdf:"draw_pdf_Export" \
            --outdir "$DIAGRAMS_OUT/" "$DIAGRAMS_OUT/$name.svg" >/dev/null 2>&1
    pdftoppm -jpeg -r 160 -singlefile \
             "$DIAGRAMS_OUT/$name.pdf" "$DIAGRAMS_OUT/$name" >/dev/null 2>&1
    rm -f "$DIAGRAMS_OUT/$name.svg" "$DIAGRAMS_OUT/$name.pdf"
    echo "    converted: $name"
    converted=$((converted + 1))
done
echo "    ($converted converted, $skipped reused from cache)"

echo "==> Phase 2: building PPTX"
for mod in pptx PIL; do
    python3 -c "import $mod" 2>/dev/null || {
        echo "  ERROR: python module '$mod' not installed" >&2
        echo "  Install: pip install python-pptx Pillow" >&2
        exit 1
    }
done

python3 "$ROOT/tools/build-statelessness-pptx.py"

echo
echo "==> Done."
echo "    Output: $OUT_PPTX"
echo "    Size:   $(du -h "$OUT_PPTX" | cut -f1)"
echo
echo "Visual QA — render the deck to JPGs for inspection:"
echo "  soffice --headless --convert-to pdf --outdir /tmp \"$OUT_PPTX\""
echo "  pdftoppm -jpeg -r 100 /tmp/cpp-statelessness-compendium.pdf /tmp/qa-slide"
