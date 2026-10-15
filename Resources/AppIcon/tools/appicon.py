"""The chosen icon, "Heard, then written": master and pixel-fitted small variants.

The master is drawn on Apple's 1024 pt canvas. The 16 and 32 px variants are
the same drawing re-fitted to whole pixels (bars and the pencil line land on
pixel edges), because a waveform of 1.3 px bars just turns into grey fog.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from shapes import CREAM, PENCIL, svg  # noqa: E402

# The tally glyph's bar heights (6 12 18 10 4 of 18), eased so the shortest
# bar stays a pill rather than a dot at icon scale.
RATIOS = [0.34, 0.67, 1.0, 0.57, 0.27]

FG_DEFS = f"""
  <defs>
    <linearGradient id="ink" x1="0" y1="260" x2="0" y2="640" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#f8f6f0"/>
      <stop offset="1" stop-color="{CREAM}"/>
    </linearGradient>
    <filter id="lift" x="-30%" y="-30%" width="160%" height="160%">
      <feDropShadow dx="0" dy="{{dy}}" stdDeviation="{{blur}}" flood-color="#0b1a2c" flood-opacity=".32"/>
    </filter>
  </defs>"""


def capsule(x, y, w, h, fill, extra="", r=None):
    r = min(w, h) / 2 if r is None else min(r, min(w, h) / 2)
    return f'<rect x="{x:g}" y="{y:g}" width="{w:g}" height="{h:g}" rx="{r:g}" fill="{fill}"{extra}/>'


def foreground(bars, words, unit=1.0, shadow=True, radius=None):
    """bars: [(x, y, w, h)], words: [(x, y, w, h, opacity)] in 1024 pt space.

    radius caps the corner radius: at 16 and 32 px a full round cap only adds a
    row of half-grey pixels to each end, so the fitted variants use a small one.
    """
    defs = FG_DEFS.replace("{dy}", f"{max(6, 1.0 * unit):g}").replace("{blur}", f"{max(8, 0.6 * unit):g}")
    lift = ' filter="url(#lift)"' if shadow else ""
    ink = "".join(capsule(*b, "url(#ink)", r=radius) for b in bars)
    pencil = "".join(capsule(x, y, w, h, PENCIL, f' opacity="{o:g}"' if o < 1 else "", r=radius) for x, y, w, h, o in words)
    return defs, f'\n  <g id="ink"{lift}>{ink}</g>\n  <g id="pencil">{pencil}</g>'


def master_geometry():
    pitch, w, tall, mid = 104, 66, 340, 452
    bars = []
    for i, r in enumerate(RATIOS):
        cx = 512 + (i - 2) * pitch
        h = max(tall * r, w * 1.25)
        bars.append((cx - w / 2, mid - h / 2, w, h))
    left = bars[0][0]
    y, t = 702, 40
    # The pencil line is aligned to the ink, not centred under it, the way the
    # AI line aligns to your text. The second word is still drying.
    words = [(left, y - t / 2, 250, t, 1.0), (left + 250 + 44, y - t / 2, 128, t, 0.7)]
    return bars, words


def pixel_geometry(px):
    """Whole-pixel geometry for a px-sized icon, returned in 1024 pt units."""
    u = 1024 / px
    if px == 16:
        # Three bars, 2 px wide with 1 px gaps, centred on the canvas; a 1 px pencil line.
        bars = [(4, 5, 2, 3), (7, 3, 2, 7), (10, 4, 2, 5)]
        words = [(4, 11, 4, 1, 1.0), (9, 11, 2, 1, 0.75)]
    elif px == 32:
        # Five 2 px bars with 1 px gaps (14 px wide, like the master's 15).
        xs, hs = [9, 12, 15, 18, 21], [4, 8, 12, 6, 4]
        bars = [(x, 14 - h / 2, 2, h) for x, h in zip(xs, hs)]
        words = [(9, 22, 8, 2, 1.0), (18, 22, 4, 2, 0.75)]
    else:
        raise ValueError(px)
    scale = lambda r: tuple(v * u for v in r[:4]) + tuple(r[4:])
    return [scale(b) for b in bars], [scale(w) for w in words], u


def master_svg():
    bars, words = master_geometry()
    defs, fg = foreground(bars, words)
    return svg(fg, defs)


def small_svg(px):
    bars, words, u = pixel_geometry(px)
    defs, fg = foreground(bars, words, unit=u, shadow=False, radius=(0.5 if px == 16 else 0.75) * u)
    return svg(fg, defs)


def layer_svgs():
    """Ink and pencil as separate full-bleed layers for an Icon Composer `.icon`.

    Icon Composer's 1024 pt canvas is the icon shape itself (the system adds
    the margin and shadow), so the master's 824 pt body is scaled up to fill it.
    """
    from shapes import BODY, BODY_X, CANVAS

    s = CANVAS / BODY
    bars, words = master_geometry()
    head = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{CANVAS}" height="{CANVAS}" viewBox="0 0 {CANVAS} {CANVAS}">'
            f'<g transform="matrix({s:.6f} 0 0 {s:.6f} {-BODY_X * s:.4f} {-BODY_X * s:.4f})">')
    ink = head + "".join(capsule(*b, CREAM) for b in bars) + "</g></svg>\n"
    pencil = head + "".join(capsule(x, y, w, h, PENCIL, f' opacity="{o:g}"' if o < 1 else "") for x, y, w, h, o in words) + "</g></svg>\n"
    return {"ink": ink, "pencil": pencil}
