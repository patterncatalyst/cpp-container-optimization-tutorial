"""
diagramgen.py — generate paired <name>.svg + <name>.excalidraw diagrams in the
project's house style (warm paper bg, grid, blue/brown/gold/green/red bands,
red accent for the load-bearing idea).

One element list emits BOTH formats so the rendered SVG and the editable
Excalidraw source never drift. The SVG is what the site embeds; the
.excalidraw is the editable source offered for download.

Used by tools/build-new-diagrams.py. Matches the style of the existing
hand-authored diagrams (e.g. diagrams/08-io-uring-rings.svg).
"""
from __future__ import annotations
import json
import random
from html import escape
from pathlib import Path

# ---- palette / variants ----------------------------------------------------
# band variant -> (fill, stroke, stroke_width)
BANDS = {
    "blue":    ("#e8f0fb", "#4a73b8", 1.5),
    "brown":   ("#ecdfd8", "#b86742", 1.5),
    "gold":    ("#f0e8d8", "#b89540", 1.5),
    "green":   ("#d8e8df", "#5a8870", 1.5),
    "purple":  ("#ece4f0", "#8a5fb0", 1.5),
    "red":     ("#fdfbf7", "#c0392b", 2.0),   # the accent / load-bearing box
    "neutral": ("#fdfbf7", "#9a9183", 1.2),
    "paper":   ("#fdfbf7", "#cdbfa6", 1.2),
}
# text class -> (size_px, weight, fill, italic, mono)
TEXTS = {
    "ttl-big":  (16, 700, "#1a1a1a", False, False),
    "ttl":      (14, 700, "#1a1a1a", False, False),
    "ttl-sub":  (13, 700, "#1a1a1a", False, False),
    "lbl":      (12, 600, "#1a1a1a", False, False),
    "mono":     (11, 400, "#1a1a1a", False, True),
    "mono-sm":  (10, 400, "#444444", False, True),
    "sec":      (11, 400, "#555555", True,  False),
    "accent-t": (12, 700, "#c0392b", False, False),
    "accent-l": (11, 700, "#c0392b", True,  False),
}
ARROWS = {
    "arrow":   ("#2d2d2d", 1.4),
    "arrow-r": ("#c0392b", 2.0),
    "arrow-g": ("#5a8870", 1.6),
}
SANS = "-apple-system, system-ui, 'Segoe UI', sans-serif"
MONO = "ui-monospace, 'SF Mono', Menlo, Consolas, monospace"


def _rid(n=8):
    return "".join(random.choice("abcdefghijklmnopqrstuvwxyz0123456789") for _ in range(n))


class Diagram:
    def __init__(self, name: str, width: int, height: int, title: str, aria: str):
        self.name = name
        self.w = width
        self.h = height
        self.title = title
        self.aria = aria
        self._svg: list[str] = []
        self._ex: list[dict] = []
        # title (centered)
        self.text(width / 2, 30, title, "ttl-big", "middle")

    # ---- primitives ---------------------------------------------------------
    def band(self, x, y, w, h, variant="neutral", title=None, sub=None,
             lines=None, title_cls="ttl", anchor="middle"):
        fill, stroke, sw = BANDS[variant]
        self._svg.append(
            f'  <rect x="{x}" y="{y}" width="{w}" height="{h}" rx="6" ry="6" '
            f'fill="{fill}" stroke="{stroke}" stroke-width="{sw}"/>')
        self._ex.append(self._ex_rect(x, y, w, h, fill, stroke, sw))
        cx = x + w / 2 if anchor == "middle" else x + 12
        ty = y + 20
        if title:
            self.text(cx, ty, title, title_cls, anchor); ty += 18
        if sub:
            self.text(cx, ty, sub, "sec", anchor); ty += 16
        for ln in (lines or []):
            cls = ln[1] if isinstance(ln, tuple) else "mono-sm"
            txt = ln[0] if isinstance(ln, tuple) else ln
            self.text(cx, ty, txt, cls, anchor); ty += 14

    def text(self, x, y, s, cls="lbl", anchor="start"):
        size, weight, fill, italic, mono = TEXTS[cls]
        fam = MONO if mono else SANS
        style = (f'font: {"italic " if italic else ""}{weight} {size}px {fam};'
                 f' fill: {fill};')
        self._svg.append(
            f'  <text x="{x:g}" y="{y:g}" text-anchor="{anchor}" '
            f'style="{style}">{escape(str(s))}</text>')
        self._ex.append(self._ex_text(x, y, s, size, fill, anchor, italic))

    def arrow(self, x1, y1, x2, y2, variant="arrow", dashed=False, label=None,
              label_cls="mono-sm", label_dx=0, label_dy=-4):
        color, sw = ARROWS[variant]
        dash = ' stroke-dasharray="5 4"' if dashed else ""
        marker = "arrowhead-r" if variant == "arrow-r" else (
            "arrowhead-g" if variant == "arrow-g" else "arrowhead")
        self._svg.append(
            f'  <line x1="{x1:g}" y1="{y1:g}" x2="{x2:g}" y2="{y2:g}" '
            f'stroke="{color}" stroke-width="{sw}" fill="none"{dash} '
            f'marker-end="url(#{marker})"/>')
        self._ex.append(self._ex_arrow(x1, y1, x2, y2, color, sw, dashed))
        if label:
            mx, my = (x1 + x2) / 2 + label_dx, (y1 + y2) / 2 + label_dy
            self.text(mx, my, label, label_cls, "middle")

    def line(self, x1, y1, x2, y2, color="#9a9183", sw=1.0, dashed=False):
        dash = ' stroke-dasharray="4 4"' if dashed else ""
        self._svg.append(
            f'  <line x1="{x1:g}" y1="{y1:g}" x2="{x2:g}" y2="{y2:g}" '
            f'stroke="{color}" stroke-width="{sw}"{dash}/>')
        self._ex.append(self._ex_line(x1, y1, x2, y2, color, sw, dashed))

    def rect(self, x, y, w, h, fill="#fdfbf7", stroke="#9a9183", sw=1.0,
             rx=4, dashed=False):
        dash = ' stroke-dasharray="4 3"' if dashed else ""
        self._svg.append(
            f'  <rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" ry="{rx}" '
            f'fill="{fill}" stroke="{stroke}" stroke-width="{sw}"{dash}/>')
        self._ex.append(self._ex_rect(x, y, w, h, fill, stroke, sw))

    # ---- excalidraw element builders ---------------------------------------
    def _ex_base(self, t, x, y, w, h, stroke, bg, sw):
        return {
            "type": t, "version": 1, "versionNonce": random.randint(1, 2**31),
            "id": _rid(), "x": float(x), "y": float(y),
            "width": float(w), "height": float(h), "angle": 0,
            "strokeColor": stroke, "backgroundColor": bg, "fillStyle": "solid",
            "strokeWidth": sw, "strokeStyle": "solid", "roughness": 0,
            "opacity": 100, "groupIds": [], "frameId": None,
            "roundness": {"type": 3}, "seed": random.randint(1, 2**31),
            "boundElements": [], "updated": 1, "link": None, "locked": False,
        }

    def _ex_rect(self, x, y, w, h, fill, stroke, sw):
        return self._ex_base("rectangle", x, y, w, h, stroke, fill, sw)

    def _ex_text(self, x, y, s, size, fill, anchor, italic):
        exsize = {16: 20, 14: 16, 13: 16, 12: 14, 11: 13, 10: 11}.get(size, 14)
        approx_w = len(str(s)) * exsize * 0.55
        tx = x - (approx_w / 2 if anchor == "middle" else
                  approx_w if anchor == "end" else 0)
        e = self._ex_base("text", tx, y - exsize, approx_w, exsize * 1.25,
                          fill, "transparent", 1)
        e.update({
            "fontSize": exsize, "fontFamily": 2,
            "text": str(s), "textAlign": anchor if anchor != "start" else "left",
            "verticalAlign": "top", "baseline": int(exsize * 0.8),
            "containerId": None, "originalText": str(s),
            "lineHeight": 1.25, "autoResize": True, "roundness": None,
        })
        return e

    def _ex_arrow(self, x1, y1, x2, y2, color, sw, dashed):
        e = self._ex_base("arrow", x1, y1, x2 - x1, y2 - y1, color,
                          "transparent", sw)
        e.update({
            "points": [[0, 0], [float(x2 - x1), float(y2 - y1)]],
            "lastCommittedPoint": None, "startBinding": None, "endBinding": None,
            "startArrowhead": None, "endArrowhead": "arrow",
            "strokeStyle": "dashed" if dashed else "solid", "roundness": None,
        })
        return e

    def _ex_line(self, x1, y1, x2, y2, color, sw, dashed):
        e = self._ex_base("line", x1, y1, x2 - x1, y2 - y1, color,
                          "transparent", sw)
        e.update({
            "points": [[0, 0], [float(x2 - x1), float(y2 - y1)]],
            "lastCommittedPoint": None, "startBinding": None, "endBinding": None,
            "startArrowhead": None, "endArrowhead": None,
            "strokeStyle": "dashed" if dashed else "solid", "roundness": None,
        })
        return e

    # ---- emit ---------------------------------------------------------------
    def to_svg(self) -> str:
        head = (
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {self.w} {self.h}" '
            f'role="img" aria-label="{escape(self.aria)}">\n'
            '  <defs>\n'
            '    <pattern id="grid" width="20" height="20" patternUnits="userSpaceOnUse">\n'
            '      <path d="M 20 0 L 0 0 0 20" fill="none" stroke="#e8e1d3" stroke-width="0.5"/>\n'
            '    </pattern>\n'
            '    <marker id="arrowhead" markerWidth="10" markerHeight="10" refX="8" refY="5" orient="auto">\n'
            '      <path d="M 0 0 L 10 5 L 0 10 z" fill="#2d2d2d"/>\n'
            '    </marker>\n'
            '    <marker id="arrowhead-r" markerWidth="10" markerHeight="10" refX="8" refY="5" orient="auto">\n'
            '      <path d="M 0 0 L 10 5 L 0 10 z" fill="#c0392b"/>\n'
            '    </marker>\n'
            '    <marker id="arrowhead-g" markerWidth="10" markerHeight="10" refX="8" refY="5" orient="auto">\n'
            '      <path d="M 0 0 L 10 5 L 0 10 z" fill="#5a8870"/>\n'
            '    </marker>\n'
            '  </defs>\n'
            f'  <rect width="{self.w}" height="{self.h}" fill="#fdfbf7"/>\n'
            f'  <rect width="{self.w}" height="{self.h}" fill="url(#grid)" opacity="0.4"/>\n')
        return head + "\n".join(self._svg) + "\n</svg>\n"

    def to_excalidraw(self) -> dict:
        return {
            "type": "excalidraw", "version": 2, "source": "https://excalidraw.com",
            "elements": self._ex,
            "appState": {"viewBackgroundColor": "#fdfbf7", "gridSize": None},
            "files": {},
        }

    def write(self, diagrams_dir: str | Path):
        base = Path(diagrams_dir) / self.name
        base.parent.mkdir(parents=True, exist_ok=True)
        base.with_suffix(".svg").write_text(self.to_svg())
        base.with_suffix(".excalidraw").write_text(
            json.dumps(self.to_excalidraw(), indent=2))
        return base
