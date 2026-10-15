"""The exploration: every concept as a 1024 pt master SVG, written to ../concepts/."""
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
from shapes import CREAM, INDIGO, PENCIL, nib_stroke, svg  # noqa: E402

OUT = os.path.join(os.path.dirname(__file__), "..", "concepts")

# The menu-bar glyph's five bars (heights out of 24, from care.js): 6 12 18 10 4.
GLYPH = [6, 12, 18, 10, 4]


def bar(cx, top, bottom, w, fill, extra=""):
    return f'<rect x="{cx - w / 2:.1f}" y="{top:.1f}" width="{w:.1f}" height="{bottom - top:.1f}" rx="{w / 2:.1f}" fill="{fill}"{extra}/>'


# 1. Ink, then pencil: a handwritten ink line, and under it WorkScribe's smaller, lighter line.
def ink_then_pencil():
    xs = np.linspace(282, 742, 240)
    t = (xs - 282) / 460
    ys = 430 - 26 * np.sin(t * math.pi * 1.6 + 0.3) * (1 - 0.4 * t)
    ink = nib_stroke(xs, ys, 92, 52, nib_deg=-55, taper=lambda v: 0.75 + 0.25 * math.sin(min(v * 1.4, 1) * math.pi / 2))
    return svg(
        f'<path d="{ink}" fill="{CREAM}"/>'
        f'<path d="M296 600 L640 600" stroke="{PENCIL}" stroke-width="40" stroke-linecap="round"/>'
    )


# 2. A waveform drawn by a nib: the line is wet ink at the nib and dries to pencil behind it.
def nib_waveform():
    xs = np.linspace(236, 600, 260)
    t = (xs - 236) / 364
    env = np.interp(t, [0, .2, .45, .7, .9, 1], [10, 60, 120, 80, 30, 0])
    ys = 640 - env * np.sin(t * math.pi * 6)
    trail = nib_stroke(xs, ys, 34, 18, nib_deg=40)
    nib = (
        "M0 -250 C 92 -250 132 -170 120 -80 C 104 30 40 150 0 250 "
        "C -40 150 -104 30 -120 -80 C -132 -170 -92 -250 0 -250 Z"
    )
    return svg(
        f"""<defs><linearGradient id="dry" x1="236" x2="600" y1="0" y2="0" gradientUnits="userSpaceOnUse">
<stop offset="0" stop-color="{PENCIL}"/><stop offset=".55" stop-color="{PENCIL}"/><stop offset="1" stop-color="{CREAM}"/></linearGradient></defs>
<path d="{trail}" fill="url(#dry)"/>
<g transform="translate(676 448) rotate(35) scale(.86)">
  <path d="{nib}" fill="{CREAM}"/>
  <circle cx="0" cy="-40" r="30" fill="{INDIGO}"/>
  <path d="M0 -10 L0 250" stroke="{INDIGO}" stroke-width="14"/>
</g>"""
    )


# 3. A page whose second line fades: ink lines with pencil under them; the last pencil line is going.
def fading_page():
    page = '<rect x="282" y="236" width="460" height="560" rx="44" fill="{c}"/>'.format(c=CREAM)
    lines = []
    rows = [(330, 640, 1.0), (500, 600, 0.55), (670, 520, 0.22)]
    for i, (y, x2, fade) in enumerate(rows):
        ink_x2 = [610, 680, 560][i]
        lines.append(f'<path d="M346 {y} L{ink_x2} {y}" stroke="{INDIGO}" stroke-width="40" stroke-linecap="round"/>')
        lines.append(f'<path d="M346 {y + 58} L{x2} {y + 58}" stroke="#93a6bb" stroke-width="26" stroke-linecap="round" opacity="{fade}"/>')
    return svg(
        '<path d="M282 280 a44 44 0 0 1 44 -44 h416 v516 a44 44 0 0 1 -44 44 h-372 a44 44 0 0 1 -44 -44 Z" fill="#000" opacity=".18" transform="translate(0 14)"/>'
        + page + "".join(lines)
    )


# 4. A listening ear made of two strokes: the helix in ink, the inner fold in pencil.
def ear():
    helix = "M392 392 C392 270 470 222 540 222 C650 222 712 300 712 392 C712 478 652 512 620 560 C590 606 600 670 548 730 C512 772 448 772 420 736"
    inner = "M470 410 C470 350 512 318 556 318 C608 318 636 356 636 400 C636 446 596 456 578 486"
    return svg(
        f'<path d="{helix}" fill="none" stroke="{CREAM}" stroke-width="66" stroke-linecap="round" stroke-linejoin="round"/>'
        f'<path d="{inner}" fill="none" stroke="{PENCIL}" stroke-width="44" stroke-linecap="round"/>'
    )


# 5. The waveform and its pencil line: the menu-bar glyph in ink, echoed beneath in pencil.
def waveform_echo():
    pitch, base = 104, 548
    out = []
    for i, h in enumerate(GLYPH):
        cx = 512 + (i - 2) * pitch
        hi = 300 * h / 18
        out.append(bar(cx, base - hi, base, 60, CREAM))
        lo = 0.5 * hi
        out.append(bar(cx, base + 34, base + 34 + max(lo, 44), 42, PENCIL))
    return svg("".join(out))


# 6. One stroke that is a waveform: written in ink, it thins and dries into pencil.
def written_wave():
    xs = np.linspace(250, 774, 600)
    t = (xs - 250) / 524
    env = np.interp(t, [0, .08, .3, .5, .7, .9, 1], [0, 60, 170, 230, 140, 50, 0])
    ys = 512 - env * np.sin(t * math.pi * 5)
    d = nib_stroke(xs, ys, 76, 26, nib_deg=30, taper=lambda v: 1.0 - 0.55 * v)
    return svg(
        f"""<defs><linearGradient id="dry" x1="250" x2="774" y1="0" y2="0" gradientUnits="userSpaceOnUse">
<stop offset="0" stop-color="{CREAM}"/><stop offset=".45" stop-color="{CREAM}"/><stop offset=".85" stop-color="{PENCIL}"/></linearGradient></defs>
<path d="{d}" fill="url(#dry)"/>"""
    )


# 7. Something unexpected: a drop of ink, its rings spreading like sound, drying to pencil as they go.
def ripple():
    return svg(
        f'<circle cx="512" cy="512" r="250" fill="none" stroke="{PENCIL}" stroke-width="22" opacity=".55"/>'
        f'<circle cx="512" cy="512" r="168" fill="none" stroke="{PENCIL}" stroke-width="34"/>'
        f'<circle cx="512" cy="512" r="82" fill="{CREAM}"/>'
    )


def nib_bar(cx, top, bottom, w, fill, cut=0.58, soft=14):
    """A vertical stroke as a broad nib leaves it: both ends cut at the nib's angle, corners softened."""
    k = w * cut / 2  # half the rise across the stroke
    hw = (w - soft) / 2
    top, bottom = top + soft / 2 + k, bottom - soft / 2 - k
    pts = [(cx - hw, top + k), (cx + hw, top - k), (cx + hw, bottom - k), (cx - hw, bottom + k)]
    d = "M" + " L".join(f"{x:.1f} {y:.1f}" for x, y in pts) + "Z"
    return f'<path d="{d}" fill="{fill}" stroke="{fill}" stroke-width="{soft}" stroke-linejoin="round"/>'


# 5b. The echo, with the ink bars cut by a broad nib.
def waveform_echo_nib():
    pitch, base = 104, 548
    out = []
    for i, h in enumerate(GLYPH):
        cx = 512 + (i - 2) * pitch
        hi = 300 * h / 18
        out.append(nib_bar(cx, base - max(hi, 90), base, 64, CREAM))
        out.append(bar(cx, base + 40, base + 40 + max(0.45 * hi, 42), 40, PENCIL))
    return svg("".join(out))


# 8. The pair: a waveform written in ink, and under it one pencil line, the way WorkScribe writes under yours.
def pair_bars():
    pitch, base = 100, 540
    out = []
    for i, h in enumerate(GLYPH):
        cx = 512 + (i - 2) * pitch
        hi = 330 * h / 18
        mid = base - 165
        out.append(nib_bar(cx, mid - max(hi, 96) / 2, mid + max(hi, 96) / 2, 64, CREAM))
    out.append(f'<path d="M300 {base + 128} L660 {base + 128}" stroke="{PENCIL}" stroke-width="40" stroke-linecap="round"/>')
    return svg("".join(out))


# 9. The pair, written: one calligraphic stroke that is a waveform, and a pencil line under it.
def pair_written():
    xs = np.linspace(268, 756, 700)
    t = (xs - 268) / 488
    env = np.interp(t, [0, .12, .32, .5, .68, .88, 1], [0, 70, 150, 190, 120, 50, 0])
    ys = 420 - env * np.sin(t * math.pi * 5)
    d = nib_stroke(xs, ys, 74, 24, nib_deg=28, taper=lambda v: min(1, 0.35 + v * 4) * min(1, 0.35 + (1 - v) * 4))
    return svg(
        f'<path d="{d}" fill="{CREAM}"/>'
        f'<path d="M292 676 L652 676" stroke="{PENCIL}" stroke-width="40" stroke-linecap="round"/>'
    )


def pencil_words(x, y, segs, w, fill=PENCIL, gap=None):
    """A pencil line drawn as words: segments of the given lengths, round-capped."""
    gap = gap if gap is not None else w * 1.1
    out, cx = [], x + w / 2
    for i, (length, op) in enumerate(segs):
        x2 = cx + length - w
        out.append(f'<path d="M{cx:.1f} {y} L{x2:.1f} {y}" stroke="{fill}" stroke-width="{w}" stroke-linecap="round" opacity="{op}"/>')
        cx = x2 + w + gap
    return "".join(out)


# 10. Heard, then written: the tally's waveform in ink, and WorkScribe's pencil line beneath it, still being written.
def heard_and_written():
    ratios = [0.36, 0.68, 1.0, 0.58, 0.28]
    pitch, w, tall, mid = 104, 66, 340, 420
    out = []
    for i, r in enumerate(ratios):
        cx = 512 + (i - 2) * pitch
        h = max(tall * r, w)
        out.append(bar(cx, mid - h / 2, mid + h / 2, w, CREAM))
    left = 512 - 2 * pitch - w / 2
    out.append(pencil_words(left, 690, [(250, 1), (128, 0.62)], 40))
    return svg("".join(out))


# 9b. The written wave with a lead-in and a trail, like a pen that started a line and heard something.
def written_line():
    xs = np.linspace(262, 762, 900)
    t = np.clip((xs - 330) / 370, 0, 1)
    env = np.interp(t, [0, .15, .4, .6, .85, 1], [0, 90, 190, 150, 50, 0])
    ys = 470 - env * np.sin(t * math.pi * 5)
    d = nib_stroke(xs, ys, 70, 30, nib_deg=30, taper=lambda v: min(1, 0.6 + v * 6) * min(1, 0.6 + (1 - v) * 6))
    return svg(
        f'<path d="{d}" fill="{CREAM}"/>'
        + pencil_words(262, 700, [(250, 1), (128, 0.62)], 40)
    )


CONCEPTS = {
    "01-ink-then-pencil": ink_then_pencil,
    "02-nib-waveform": nib_waveform,
    "03-fading-page": fading_page,
    "04-ear": ear,
    "05-waveform-echo": waveform_echo,
    "05b-waveform-echo-nib": waveform_echo_nib,
    "06-written-wave": written_wave,
    "07-ripple": ripple,
    "08-pair-bars": pair_bars,
    "09-pair-written": pair_written,
    "09b-written-line": written_line,
    "10-heard-and-written": heard_and_written,
}

if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for name, fn in CONCEPTS.items():
        with open(os.path.join(OUT, name + ".svg"), "w") as f:
            f.write(fn())
    print("\n".join(CONCEPTS))
