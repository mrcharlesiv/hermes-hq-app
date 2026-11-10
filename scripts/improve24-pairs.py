#!/usr/bin/env python3
"""improve-24: put each item's before and after pictures side by side.

Usage: scripts/improve24-pairs.py <before dir> <after dir>[,<after dir>…] <out dir>
Pairs files by name (NN-short-name.png); writes <out dir>/NN-short-name.png, phone screens scaled to 900 px tall.
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

before_dir, after_dirs, out_dir = sys.argv[1], sys.argv[2].split(","), sys.argv[3]
os.makedirs(out_dir, exist_ok=True)
H, GAP, LABEL = 900, 24, 44
try:
    font = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 30)
except OSError:
    font = ImageFont.load_default()

for name in sorted(os.listdir(before_dir)):
    if not name.endswith(".png"):
        continue
    after = next((os.path.join(d, name) for d in after_dirs if os.path.exists(os.path.join(d, name))), None)
    if not after:
        continue
    pics = []
    for path in (os.path.join(before_dir, name), after):
        im = Image.open(path).convert("RGB")
        pics.append(im.resize((round(im.width * H / im.height), H), Image.LANCZOS))
    w = pics[0].width + pics[1].width + GAP * 3
    canvas = Image.new("RGB", (w, H + LABEL + GAP * 2), (235, 235, 240))
    draw = ImageDraw.Draw(canvas)
    x = GAP
    for title, im in zip(("Before", "After"), pics):
        draw.text((x, GAP // 2), title, fill=(40, 40, 45), font=font)
        canvas.paste(im, (x, LABEL + GAP))
        x += im.width + GAP
    canvas.save(os.path.join(out_dir, name), optimize=True)
    print(name)
