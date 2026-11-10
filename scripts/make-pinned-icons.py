#!/usr/bin/env python3
"""[icon-look] The pinned icons: for every icon set "<id>", a "<id>-Light" and a "<id>-Dark" set that wear one look on
every Home Screen (Settings › App Icon › Look, owner 2026-11-02: "pin one of the options so that it doesn't change").

A pinned set's own picture fills both its any and its dark slot, so iOS never swaps it; the tinted slot keeps the icon's
tinted picture. Run from the repo root after any icon changes (scripts/make-light-icons.py, or the drawn icons'
TEST_RUNNER_HQ_WRITE_APP_ICONS=1): `python3 scripts/make-pinned-icons.py`. AppIconTests checks the copies match.
"""
import json
import shutil
from pathlib import Path

CATALOG = Path("App/Resources/Assets.xcassets")
PINS = {"Light": None, "Dark": "dark"}   # the pinned set's suffix → the automatic set's slot it copies


def slot(image):
    return (image.get("appearances") or [{}])[0].get("value")


def entry(filename, look):
    image = {"filename": filename, "idiom": "universal", "platform": "ios", "size": "1024x1024"}
    if look:
        image = {"appearances": [{"appearance": "luminosity", "value": look}], **image}
    return image


def main():
    automatic = sorted(p for p in CATALOG.glob("AppIcon*.appiconset")
                       if not any(p.stem.endswith("-" + pin) for pin in PINS))
    for folder in automatic:
        images = json.loads((folder / "Contents.json").read_text())["images"]
        files = {slot(image): folder / image["filename"] for image in images}
        for pin, source in PINS.items():
            name = f"{folder.stem}-{pin}"
            pinned = CATALOG / f"{name}.appiconset"
            if pinned.exists():
                shutil.rmtree(pinned)
            pinned.mkdir()
            shutil.copyfile(files[source], pinned / f"{name}.png")
            shutil.copyfile(files["tinted"], pinned / f"{name}-Tinted.png")
            contents = {"images": [entry(f"{name}.png", None), entry(f"{name}.png", "dark"),
                                   entry(f"{name}-Tinted.png", "tinted")],
                        "info": {"author": "xcode", "version": 1}}
            (pinned / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")
            print(name)


if __name__ == "__main__":
    main()
