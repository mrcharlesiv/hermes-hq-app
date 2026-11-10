#!/usr/bin/env python3
"""[app-icons] Light versions of the app icons drawn as artwork (Hermes, Feather, Original, Black & White).

Their art is light-on-black, so each set's "-Dark" file keeps it and this writes the set's own (light) file and the
picker's "-Preview" image sets (both looks) and the light "LaunchIcon" from it: dark ink on the warm paper of the drawn icons' light look (AppIconArt.ground).
Needs numpy, pillow and scipy. Run from the repo root: `python3 scripts/make-light-icons.py`.
"""
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage as nd

CATALOG = Path("App/Resources/Assets.xcassets")
SIDE = 1024


def paper():
    """AppIconArt.ground(.light): FCFBF8 → F7F5F0 (0.45) → EDEAE3, top to bottom."""
    stops = [(0, (0xFC, 0xFB, 0xF8)), (0.45, (0xF7, 0xF5, 0xF0)), (1, (0xED, 0xEA, 0xE3))]
    t = np.linspace(0, 1, SIDE)
    out = np.zeros((SIDE, SIDE, 3))
    for c in range(3):
        out[:, :, c] = np.interp(t, [s[0] for s in stops], [s[1][c] for s in stops])[:, None]
    return out


def disk(r):
    y, x = np.ogrid[-r:r + 1, -r:r + 1]
    return x * x + y * y <= r * r


def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


INK = np.array([0x14, 0x14, 0x17], dtype=float)


def hermes(src):
    """The engraving keeps its own tones (turned over, his face would be a negative); only the black around him becomes
    paper. His outline is the bright parts closed up, holes filled, and grown a little so a band of the old black stays
    round him as an ink line. He runs off the bottom edge as the dark one does: there the dark art dims his neck towards
    black, so the outline takes dimmer parts near the bottom, is closed along the edge, and takes in the shirt under the
    chin; then his light parts are lifted back up so the neck stays light down to the edge."""
    lum = src.mean(2) / 255
    y = np.linspace(0, 1, SIDE)[:, None]
    bright = nd.binary_closing(lum > 0.4 - 0.28 * smoothstep(0.82, 1.0, y), structure=disk(18))
    closed = np.zeros((SIDE + 1, SIDE + 2), bool)
    closed[:-1, 1:-1] = bright
    closed[-1, :] = True
    figure = nd.binary_fill_holes(closed)[:-1, 1:-1]
    for r in range(int(0.86 * SIDE), SIDE):
        xs = np.flatnonzero(figure[r])
        if xs.size:
            figure[r, xs[0]:xs[-1] + 1] = True
    figure = nd.binary_dilation(figure, structure=disk(6))
    figure[SIDE - 24:] = figure[SIDE - 24]   # the closing and growing pull back from the edge; carry him down to it
    m = nd.gaussian_filter(figure.astype(float), 1.2)[:, :, None]
    top = int(0.8 * SIDE)
    level = np.array([np.percentile(lum[r][figure[r] & (lum[r] > 0.15)], 80) if r >= top else 0 for r in range(SIDE)])
    level[top:] = nd.gaussian_filter1d(level[top:], 8, mode="nearest")
    lift = np.ones(SIDE)
    lift[top:] = np.maximum(1, level[top] / level[top:])
    return src * lift[:, None, None] * m + paper() * (1 - m)


def ink_from_light(src):
    """Line art: how bright a pixel is becomes how much ink it gets (Feather, Black & White)."""
    lum = src.mean(2) / 255
    floor = np.percentile(lum, 5)   # the black ground, which may carry a faint fall of light
    ink = smoothstep(floor + 0.02, 0.92, lum)[:, :, None]
    return paper() * (1 - ink) + INK * ink


def onyx(src):
    """Original: the three pearl blades become dark onyx ones, lit from the top as the dark tile is (2B2B33 → 08080A).
    Only what is clearly the feather counts, so the rounded square drawn into the old artwork goes."""
    lum = src.mean(2) / 255
    feather = smoothstep(0.3, 0.6, lum)[:, :, None]
    y = np.linspace(0, 1, SIDE)[:, None, None]
    stone = np.array([0x3A, 0x3A, 0x42]) * (1 - y) + np.array([0x0C, 0x0C, 0x0F]) * y
    return paper() * (1 - feather) + stone * feather


ICONS = {
    "AppIcon": ("AppIcon-Dark-512@2x.png", "AppIcon-512@2x.png", hermes),
    "AppIcon-Feather": ("AppIcon-Feather-Dark.png", "AppIcon-Feather.png", ink_from_light),
    "AppIcon-Pearl": ("AppIcon-Pearl-Dark.png", "AppIcon-Pearl.png", onyx),
    "AppIcon-BlackWhite": ("AppIcon-BlackWhite-Dark.png", "AppIcon-BlackWhite.png", ink_from_light),
}

PREVIEW = 512   # the Mac Dock draws the chosen one 824 px across


def preview_contents(name):
    return f"""{{
  "images" : [
    {{
      "filename" : "{name}-Preview.png",
      "idiom" : "universal"
    }},
    {{
      "appearances" : [ {{ "appearance" : "luminosity", "value" : "dark" }} ],
      "filename" : "{name}-Preview-Dark.png",
      "idiom" : "universal"
    }}
  ],
  "info" : {{
    "author" : "xcode",
    "version" : 1
  }}
}}
"""


def launch_icon(light):
    """"LaunchIcon" (the app's own icon inside the app) is the icon cut to its shape: the light one takes the cut of
    the dark one beside it."""
    folder = CATALOG / "LaunchIcon.imageset"
    for scale in (1, 2, 3):
        cut = Image.open(folder / f"launch-icon-dark@{scale}x.png").convert("RGBA")
        picture = light.resize(cut.size, Image.LANCZOS).convert("RGBA")
        picture.putalpha(cut.getchannel("A"))
        picture.save(folder / f"launch-icon@{scale}x.png", optimize=True)


def main():
    for name, (dark_file, light_file, make) in ICONS.items():
        folder = CATALOG / f"{name}.appiconset"
        dark = Image.open(folder / dark_file).convert("RGB")
        light = Image.fromarray(make(np.asarray(dark).astype(float)).clip(0, 255).round().astype(np.uint8))
        light.save(folder / light_file, optimize=True)
        # The picker's own pictures (iOS keeps an icon's renditions to itself), both looks.
        previews = CATALOG / f"{name}-Preview.imageset"
        previews.mkdir(exist_ok=True)
        light.resize((PREVIEW, PREVIEW), Image.LANCZOS).save(previews / f"{name}-Preview.png", optimize=True)
        dark.resize((PREVIEW, PREVIEW), Image.LANCZOS).save(previews / f"{name}-Preview-Dark.png", optimize=True)
        (previews / "Contents.json").write_text(preview_contents(name))
        if name == "AppIcon":
            launch_icon(light)
        print(name)


if __name__ == "__main__":
    main()
