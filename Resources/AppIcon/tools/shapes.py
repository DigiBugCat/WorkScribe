"""Shared geometry for the WorkScribe icon: the macOS squircle, the body, and a broad-nib stroke.

Everything is drawn on Apple's 1024 pt macOS canvas. The body is the 824 pt
continuous-corner rounded square at (100, 100); the margin holds the shadow.
"""
import math

import numpy as np

INDIGO = "#23456b"
CREAM = "#f4f1ea"
# Pencil: cream laid over indigo at ~58%, then nudged cool, like graphite on blue paper.
PENCIL = "#9aabbd"

CANVAS = 1024
BODY_X, BODY_Y, BODY = 100, 100, 824
# Corner radius for the continuous-corner curve. 0.2237 x side is the
# iOS/macOS squircle ratio; the curve itself reaches 1.528 r along each edge.
BODY_R = BODY * 0.2237


def squircle(x=BODY_X, y=BODY_Y, s=BODY, r=BODY_R):
    """Continuous-corner rounded square (the macOS icon 'squircle').

    One corner is described in units of r, measured inwards from the corner,
    then mirrored to the other three, so all four are identical. Curvature
    ramps up gradually from the straight edge, unlike a circular arc.
    """
    # (along-edge, into-corner) pairs for the top-right corner, from the top edge to the right edge.
    corner = [
        ("C", (1.08849, 0), (0.86840, 0), (0.66993, 0.06549)),
        ("L", (0.63149, 0.07491)),
        ("C", (0.37282, 0.16906), (0.16906, 0.37282), (0.07491, 0.63149)),
        ("L", (0.06549, 0.66993)),
        ("C", (0, 0.86840), (0, 1.08849), (0, 1.52866)),
    ]
    L, T, R, B = x, y, x + s, y + s
    # Map (a, b) in corner units to absolute points for each corner, walking clockwise.
    maps = [
        lambda a, b: (R - a * r, T + b * r),  # top-right: a along top (leftwards), b down
        lambda a, b: (R - b * r, B - a * r),  # bottom-right
        lambda a, b: (L + a * r, B - b * r),  # bottom-left
        lambda a, b: (L + b * r, T + a * r),  # top-left
    ]
    fmt = lambda p: f"{p[0]:.2f} {p[1]:.2f}"
    d = "M" + fmt(maps[3](0, 1.52866))
    for m in maps:
        d += " L" + fmt(m(1.52866, 0))
        for seg in corner:
            d += " " + seg[0] + " ".join(fmt(m(*pt)) for pt in seg[1:])
    return d + " Z"


def body_defs(shadow=True):
    sq = squircle()
    return f"""
  <defs>
    <linearGradient id="wash" x1="0" y1="{BODY_Y}" x2="0" y2="{BODY_Y + BODY}" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#2b5281"/>
      <stop offset=".55" stop-color="{INDIGO}"/>
      <stop offset="1" stop-color="#1c3858"/>
    </linearGradient>
    <radialGradient id="sheen" cx="512" cy="120" r="620" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#fff" stop-opacity=".10"/>
      <stop offset="1" stop-color="#fff" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="rim" x1="0" y1="{BODY_Y}" x2="0" y2="{BODY_Y + BODY}" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#fff" stop-opacity=".22"/>
      <stop offset=".5" stop-color="#fff" stop-opacity=".06"/>
      <stop offset="1" stop-color="#fff" stop-opacity=".10"/>
    </linearGradient>
    <clipPath id="body"><path d="{sq}"/></clipPath>
    <filter id="drop" x="-10%" y="-10%" width="120%" height="125%">
      <feGaussianBlur in="SourceAlpha" stdDeviation="10"/>
      <feOffset dy="10"/>
      <feComponentTransfer><feFuncA type="linear" slope=".30"/></feComponentTransfer>
      <feMerge><feMergeNode/></feMerge>
    </filter>
  </defs>
  {'<path d="' + sq + '" fill="#000" filter="url(#drop)"/>' if shadow else ''}
  <path d="{sq}" fill="url(#wash)"/>
  <path d="{sq}" fill="url(#sheen)"/>
  <path d="{sq}" fill="none" stroke="url(#rim)" stroke-width="5" clip-path="url(#body)"/>"""


def svg(content, defs_extra="", shadow=True, size=CANVAS):
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 {CANVAS} {CANVAS}">'
        f"{body_defs(shadow)}{defs_extra}{content}\n</svg>\n"
    )


def nib_stroke(xs, ys, w_max, w_min, nib_deg=35.0, taper=None, round_ends=True):
    """Outline of a broad-nib stroke along a sampled centreline, as an SVG path.

    Width follows the angle between the stroke direction and a fixed nib, the
    way a fountain-pen nib lays down thick downstrokes and thin cross-strokes.
    `taper(t)` scales width along the stroke (t in 0..1).
    """
    xs, ys = np.asarray(xs, float), np.asarray(ys, float)
    dx, dy = np.gradient(xs), np.gradient(ys)
    ang = np.arctan2(dy, dx)
    nib = math.radians(nib_deg)
    w = w_min + (w_max - w_min) * np.abs(np.sin(ang - nib))
    if taper is not None:
        t = np.linspace(0, 1, len(xs))
        w = w * np.array([taper(v) for v in t])
    n = np.hypot(dx, dy)
    nx, ny = -dy / n, dx / n
    lx, ly = xs + nx * w / 2, ys + ny * w / 2
    rx, ry = xs - nx * w / 2, ys - ny * w / 2
    pts = [f"{x:.1f} {y:.1f}" for x, y in zip(lx, ly)]
    back = [f"{x:.1f} {y:.1f}" for x, y in zip(rx[::-1], ry[::-1])]
    d = "M" + " L".join(pts)
    if round_ends:
        d += f" A{w[-1] / 2:.1f} {w[-1] / 2:.1f} 0 0 1 {back[0]}"
    d += " L" + " L".join(back)
    if round_ends:
        d += f" A{w[0] / 2:.1f} {w[0] / 2:.1f} 0 0 1 {pts[0]}"
    return d + "Z"
