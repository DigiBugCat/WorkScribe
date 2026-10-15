#!/usr/bin/env python3
"""Build every WorkScribe app icon asset from source.

    python3 Resources/AppIcon/tools/build.py

Writes, next to this folder:
  AppIcon.svg, AppIcon-16.svg, AppIcon-32.svg   master and pixel-fitted variants
  AppIcon.iconset/                              every size, @1x and @2x
  AppIcon.icns                                  iconutil -c icns AppIcon.iconset
  AppIcon.icon/                                 the same drawing as an Icon Composer document (macOS 26 Liquid Glass)
  Assets.car                                    AppIcon.icon compiled by actool (needs Xcode 26; skipped without it)
  concepts/*.svg                                the exploration
  contact-sheet.png                             every concept and the final icon at 1024/128/32/16

Needs Google Chrome (the SVG rasteriser), numpy and iconutil; Xcode 26 for Assets.car.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import appicon  # noqa: E402
import concepts  # noqa: E402
import contact  # noqa: E402
import render  # noqa: E402

ROOT = os.path.dirname(HERE)

# (iconset file, pixel size, source): 16 and 32 px use the pixel-fitted drawings.
ICONSET = [
    ("icon_16x16.png", 16, "AppIcon-16.svg"),
    ("icon_16x16@2x.png", 32, "AppIcon-32.svg"),
    ("icon_32x32.png", 32, "AppIcon-32.svg"),
    ("icon_32x32@2x.png", 64, "AppIcon.svg"),
    ("icon_128x128.png", 128, "AppIcon.svg"),
    ("icon_128x128@2x.png", 256, "AppIcon.svg"),
    ("icon_256x256.png", 256, "AppIcon.svg"),
    ("icon_256x256@2x.png", 512, "AppIcon.svg"),
    ("icon_512x512.png", 512, "AppIcon.svg"),
    ("icon_512x512@2x.png", 1024, "AppIcon.svg"),
]

CAPTIONS = {
    "01-ink-then-pencil": "A handwritten ink line and, under it, a shorter pencil line. The product in one gesture, but at Dock size it is an equals sign.",
    "02-nib-waveform": "A nib drawing the waveform; the line is wet near the nib and dries to pencil behind it. Charming at 1024, a smudge by 32.",
    "03-fading-page": "A page of ink lines, each with a pencil line under it, the last one fading. Reads at every size, but it is every notes app.",
    "04-ear": "A listening ear in two strokes. Reads as a question mark, and an ear is not what WorkScribe is for.",
    "05-waveform-echo": "The tally's waveform in ink, echoed beneath in pencil. Strong family tie; the echo looks like a music visualiser's reflection.",
    "05b-waveform-echo-nib": "The echo with broad-nib cut ends. The cut turns the waveform into a bar chart.",
    "06-written-wave": "One calligraphic stroke that is a waveform, drying from ink to pencil. Lively, but the drying is lost below 128.",
    "07-ripple": "A drop of ink with rings spreading like sound. Clean at 16 px, but it reads as a record button or a target.",
    "08-pair-bars": "Nib-cut ink bars over a pencil line: the first version of the pair. The cut ends feel like confetti.",
    "09-pair-written": "A written waveform over a pencil line. Most personal, least calm; the stroke ends fray.",
    "09b-written-line": "The written line with a lead-in and trail, like a heartbeat. Busier still.",
    "10-heard-and-written": "The tally's waveform in ink, and WorkScribe's pencil line beneath it, still being written. The idea that won.",
}
FINAL_CAPTION = (
    "10, refined. Ink bars lifted off the wash by a soft shadow; the pencil line aligned to the ink like the AI "
    "line aligns to your text, its second word still drying. 16 and 32 px are redrawn on whole pixels: three bars at 16."
)


# Icon Composer document. Ink is glass (wet ink is glossy); pencil is matte and
# sits flat on the page. Neither is translucent: ink and graphite are opaque.
ICON_COMPOSER = {
    "fill": {"linear-gradient": ["srgb:0.16863,0.32157,0.50588,1.00000", "srgb:0.10980,0.21961,0.34510,1.00000"]},
    "groups": [
        {
            "layers": [{"image-name": "ink.svg", "name": "ink"}],
            "shadow": {"kind": "neutral", "opacity": 0.5},
            "specular": True,
            "translucency": {"enabled": False, "value": 0},
        },
        {
            "layers": [{"image-name": "pencil.svg", "name": "pencil", "glass": False}],
            "shadow": {"kind": "neutral", "opacity": 0.2},
            "translucency": {"enabled": False, "value": 0},
        },
    ],
    "supported-platforms": {"squares": "shared"},
}


def compile_asset_catalog():
    """Compile AppIcon.icon to Assets.car, so macOS 26 draws the icon with Liquid Glass.

    With only an .icns, macOS 26 shrinks the icon onto a grey tile at 32 px and
    below (Obsidian and Zed show the same thing). Assets.car plus
    CFBundleIconName avoids that; AppIcon.icns stays as CFBundleIconFile.
    """
    try:
        subprocess.run(["xcrun", "--find", "actool"], check=True, capture_output=True)
    except (subprocess.CalledProcessError, FileNotFoundError):
        print("Skipping Assets.car: actool (Xcode 26) not found.", file=sys.stderr)
        return
    out = tempfile.mkdtemp(prefix="wsicon-car-")
    try:
        subprocess.run(
            ["xcrun", "actool", f"{ROOT}/AppIcon.icon", "--compile", out, "--platform", "macosx",
             "--minimum-deployment-target", "26.0", "--app-icon", "AppIcon",
             "--output-partial-info-plist", f"{out}/partial.plist", "--errors", "--warnings"],
            check=True, capture_output=True,
        )
        shutil.copy(f"{out}/Assets.car", f"{ROOT}/Assets.car")
    finally:
        shutil.rmtree(out, ignore_errors=True)


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def main():
    # Sources
    write(f"{ROOT}/AppIcon.svg", appicon.master_svg())
    write(f"{ROOT}/AppIcon-16.svg", appicon.small_svg(16))
    write(f"{ROOT}/AppIcon-32.svg", appicon.small_svg(32))
    shutil.rmtree(f"{ROOT}/AppIcon.icon", ignore_errors=True)
    for name, text in appicon.layer_svgs().items():
        write(f"{ROOT}/AppIcon.icon/Assets/{name}.svg", text)
    write(f"{ROOT}/AppIcon.icon/icon.json", json.dumps(ICON_COMPOSER, indent=2) + "\n")
    for name, fn in concepts.CONCEPTS.items():
        write(f"{ROOT}/concepts/{name}.svg", fn())

    # Iconset and icns
    iconset = f"{ROOT}/AppIcon.iconset"
    shutil.rmtree(iconset, ignore_errors=True)
    os.makedirs(iconset)
    render.render_many([(f"{ROOT}/{src}", px, f"{iconset}/{fname}") for fname, px, src in ICONSET])
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", f"{ROOT}/AppIcon.icns"], check=True)
    compile_asset_catalog()

    # Contact sheet: the final icon first, then every concept.
    tmp = tempfile.mkdtemp(prefix="wsicon-sheet-")
    try:
        sizes = (1024, 128, 32, 16)
        render.render_many([(f"{ROOT}/concepts/{n}.svg", s, f"{tmp}/{n}-{s}.png") for n in concepts.CONCEPTS for s in sizes])
        final = {1024: f"{iconset}/icon_512x512@2x.png", 128: f"{iconset}/icon_128x128.png",
                 32: f"{iconset}/icon_32x32.png", 16: f"{iconset}/icon_16x16.png"}
        entries = [("Heard, then written", FINAL_CAPTION, final, True)]
        entries += [(n, CAPTIONS.get(n, ""), {s: f"{tmp}/{n}-{s}.png" for s in sizes}, False) for n in concepts.CONCEPTS]
        contact.build(
            entries, f"{ROOT}/contact-sheet.png", "WorkScribe app icon",
            "Every concept at 1024, 128, 32 and 16 px, shown at true pixel size on a light and a dark Dock, "
            "with 32 and 16 px magnified. Indigo Wash: indigo #23456b, cream #f4f1ea, pencil #9aabbd.",
        )
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print(f"Built {ROOT}/AppIcon.icns and contact-sheet.png")


if __name__ == "__main__":
    main()
