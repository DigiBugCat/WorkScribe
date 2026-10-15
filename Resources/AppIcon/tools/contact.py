"""Contact sheet: each icon at 1024, 128, 32 and 16 px, on light and dark, with the small sizes magnified.

Every image is shown at its true pixel size (the sheet is rendered at 1x), so
the 16 and 32 px columns are what a non-Retina Finder list would show.
"""
import html as H
import os

from render import sheet

LIGHT, DARK = "#e8e8ec", "#1d1d20"
CELL_W, CELL_H = 1024 + 40 + 470, 1024 + 27


def _cell(name, caption, png, chosen):
    u = {k: "file://" + os.path.abspath(v) for k, v in png.items()}

    def dock(bg, fg):
        return f"""<div class="dock" style="background:{bg};color:{fg}">
        <figure><img src="{u[128]}" width="128" height="128"><figcaption>128</figcaption></figure>
        <figure><img src="{u[32]}" width="32" height="32"><figcaption>32</figcaption></figure>
        <figure><img src="{u[16]}" width="16" height="16"><figcaption>16</figcaption></figure></div>"""

    def zoom(bg, fg):
        return f"""<div class="zoom" style="background:{bg};color:{fg}">
        <figure><img class="px" src="{u[32]}" width="160" height="160"><figcaption>32 &times;5</figcaption></figure>
        <figure><img class="px" src="{u[16]}" width="160" height="160"><figcaption>16 &times;10</figcaption></figure></div>"""

    return f"""<section class="{'chosen' if chosen else ''}">
    <div class="big"><img src="{u[1024]}" width="1024" height="1024"></div>
    <div class="side">
      {'<span class="tag">Chosen</span>' if chosen else ''}
      <h2>{H.escape(name)}</h2>
      <p>{H.escape(caption)}</p>
      {dock(LIGHT, '#555')}{dock(DARK, '#999')}
      <div class="zooms">{zoom(LIGHT, '#555')}{zoom(DARK, '#999')}</div>
    </div></section>"""


def build(entries, out_png, title, note="", cols=2):
    """entries: list of (name, caption, {1024|128|32|16: png}, chosen)."""
    rows = -(-len(entries) // cols)
    w = 48 * 2 + cols * CELL_W + (cols - 1) * 48
    h = 150 + rows * (CELL_H + 32) + 16
    page = f"""<!doctype html><html><head><meta charset="utf-8"><style>
  body {{ margin:0; background:#f4f1ea; font:16px/1.45 -apple-system, "SF Pro Text", sans-serif; color:#23456b; }}
  header {{ padding:40px 48px 16px; }}
  header h1 {{ font:600 34px/1.2 "New York", "Iowan Old Style", Georgia, serif; margin:0 0 6px; }}
  header p {{ margin:0; color:#5d6b7a; max-width:120ch; }}
  main {{ display:grid; grid-template-columns:repeat({cols}, {CELL_W}px); gap:32px 48px; padding:16px 48px 48px; }}
  section {{ display:flex; gap:40px; padding-top:24px; border-top:1px solid #e0d9ca; }}
  section.chosen {{ border-top:3px solid #23456b; }}
  .big {{ width:1024px; height:1024px; flex:none; background:linear-gradient(135deg, {LIGHT} 0 50%, {DARK} 50% 100%); }}
  img {{ display:block; }}
  .side {{ width:470px; }}
  .tag {{ display:inline-block; font:600 12px/1 ui-monospace, "SF Mono", monospace; letter-spacing:.08em; text-transform:uppercase;
          background:#23456b; color:#f4f1ea; padding:6px 9px; border-radius:6px; margin:6px 0 4px; }}
  h2 {{ font:600 24px/1.2 "New York", Georgia, serif; margin:8px 0 8px; }}
  .side p {{ margin:0 0 22px; color:#4a5867; }}
  .dock {{ display:flex; align-items:flex-end; gap:28px; padding:20px 24px 12px; border-radius:18px; margin-bottom:14px; }}
  figure {{ margin:0; display:flex; flex-direction:column; align-items:center; gap:6px; }}
  figcaption {{ font:11px/1 ui-monospace, "SF Mono", monospace; }}
  .zooms {{ display:flex; gap:14px; }}
  .zoom {{ display:flex; gap:14px; flex-direction:column; padding:16px 20px; border-radius:18px; flex:1; align-items:center; }}
  .px {{ image-rendering:pixelated; }}
</style></head><body>
  <header><h1>{H.escape(title)}</h1><p>{H.escape(note)}</p></header>
  <main>{''.join(_cell(*e) for e in entries)}</main>
</body></html>"""
    sheet(page, out_png, w, h)
    return w, h
