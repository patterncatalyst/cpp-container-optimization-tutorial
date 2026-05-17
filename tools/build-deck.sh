#!/usr/bin/env bash
# build-deck.sh — rebuild the presentation PPTX from source.
#
# Two phases:
#   1. SVG → JPG conversion (idempotent; reuses cached JPGs if present)
#   2. Python build via tools/build-pptx.py
#
# Run from the project root:
#   ./tools/build-deck.sh           # incremental (reuses cached JPGs)
#   ./tools/build-deck.sh --force   # re-convert all SVGs
#
# Prerequisites:
#   - python3 with python-pptx and Pillow installed
#   - soffice (LibreOffice) on PATH
#   - pdftoppm (poppler-utils) on PATH

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DIAGRAMS_SRC="$ROOT/diagrams"
DIAGRAMS_OUT="/tmp/diagrams-png"
OUT_PPTX="$ROOT/presentation/cpp-container-tutorial.pptx"

FORCE=0
if [[ "${1:-}" == "--force" ]]; then
    FORCE=1
fi

# ---------------------------------------------------------------------------
# Phase 1 — SVG → JPG conversion
# ---------------------------------------------------------------------------

echo "==> Phase 1: SVG → JPG conversion"

if ! command -v soffice >/dev/null 2>&1; then
    echo "  ERROR: 'soffice' (LibreOffice) not found on PATH" >&2
    echo "  Install with: dnf install libreoffice-impress (Fedora)" >&2
    echo "             or: apt install libreoffice-impress (Debian/Ubuntu)" >&2
    exit 1
fi

if ! command -v pdftoppm >/dev/null 2>&1; then
    echo "  ERROR: 'pdftoppm' (poppler-utils) not found on PATH" >&2
    echo "  Install with: dnf install poppler-utils (Fedora)" >&2
    echo "             or: apt install poppler-utils (Debian/Ubuntu)" >&2
    exit 1
fi

mkdir -p "$DIAGRAMS_OUT"

converted=0
skipped=0
for svg in "$DIAGRAMS_SRC"/*.svg; do
    name="$(basename "$svg" .svg)"
    jpg="$DIAGRAMS_OUT/$name.jpg"

    # Skip if cached JPG is newer than the SVG (and not forced)
    if [[ $FORCE -eq 0 && -f "$jpg" && "$jpg" -nt "$svg" ]]; then
        skipped=$((skipped + 1))
        continue
    fi

    cp "$svg" "$DIAGRAMS_OUT/"
    soffice --headless --convert-to pdf:"draw_pdf_Export" \
            --outdir "$DIAGRAMS_OUT/" \
            "$DIAGRAMS_OUT/$(basename "$svg")" \
            >/dev/null 2>&1

    pdftoppm -jpeg -r 160 -singlefile \
             "$DIAGRAMS_OUT/$name.pdf" \
             "$DIAGRAMS_OUT/$name" \
             >/dev/null 2>&1

    rm -f "$DIAGRAMS_OUT/$(basename "$svg")" "$DIAGRAMS_OUT/$name.pdf"
    echo "    converted: $name"
    converted=$((converted + 1))
done

echo "    ($converted converted, $skipped reused from cache)"

# ---------------------------------------------------------------------------
# Phase 2 — Python build
# ---------------------------------------------------------------------------

echo "==> Phase 2: building PPTX"

if ! python3 -c "import pptx" 2>/dev/null; then
    echo "  ERROR: python-pptx not installed" >&2
    echo "  Install with: pip install python-pptx" >&2
    exit 1
fi

if ! python3 -c "from PIL import Image" 2>/dev/null; then
    echo "  ERROR: Pillow not installed" >&2
    echo "  Install with: pip install Pillow" >&2
    exit 1
fi

python3 "$ROOT/tools/build-pptx.py"

echo
echo "==> Done."
echo "    Output: $OUT_PPTX"
echo "    Size:   $(du -h "$OUT_PPTX" | cut -f1)"
echo
echo "Visual QA — render the deck to JPGs for inspection:"
echo "  soffice --headless --convert-to pdf --outdir /tmp \"$OUT_PPTX\""
echo "  pdftoppm -jpeg -r 100 /tmp/cpp-container-tutorial.pdf /tmp/qa-slide"
echo "  # then view /tmp/qa-slide-NN.jpg"
