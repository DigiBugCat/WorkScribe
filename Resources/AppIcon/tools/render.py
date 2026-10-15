"""Rasterise SVGs with headless Chrome (the only SVG renderer on a stock Mac) and build contact sheets."""
import concurrent.futures as cf
import os
import shutil
import subprocess
import tempfile

CHROME = os.environ.get("CHROME", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")


def _shot(html, out_png, w, h, scale=1, attempts=3):
    """Screenshot an HTML page. Headless Chrome occasionally writes the PNG and then
    fails to exit, so a timeout with a fresh PNG on disk counts as success."""
    out_png = os.path.abspath(out_png)
    for attempt in range(attempts):
        tmp = tempfile.mkdtemp(prefix="wsicon-")
        try:
            page = os.path.join(tmp, "p.html")
            with open(page, "w") as f:
                f.write(html)
            if os.path.exists(out_png):
                os.remove(out_png)
            try:
                subprocess.run(
                    [CHROME, "--headless", "--disable-gpu", "--hide-scrollbars", "--no-first-run",
                     f"--user-data-dir={tmp}/profile", "--default-background-color=00000000",
                     f"--force-device-scale-factor={scale}", f"--window-size={w},{h}",
                     f"--screenshot={out_png}", "file://" + page],
                    check=True, capture_output=True, timeout=45,
                )
            except subprocess.TimeoutExpired:
                pass
            if os.path.exists(out_png) and os.path.getsize(out_png) > 0:
                return
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    raise RuntimeError(f"Chrome could not render {out_png}")


def render(svg_path, size, out_png):
    """Rasterise one SVG at exactly size x size pixels, with transparency."""
    src = "file://" + os.path.abspath(svg_path)
    html = (f'<!doctype html><html><body style="margin:0;background:transparent">'
            f'<img src="{src}" width="{size}" height="{size}" style="display:block"></body></html>')
    _shot(html, out_png, size, size)


def render_many(jobs, workers=6):
    """jobs: iterable of (svg_path, size, out_png)."""
    with cf.ThreadPoolExecutor(workers) as ex:
        for fut in [ex.submit(render, *j) for j in jobs]:
            fut.result()


def sheet(html, out_png, w, h, scale=1):
    _shot(html, out_png, w, h, scale)
