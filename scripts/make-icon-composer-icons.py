#!/usr/bin/env python3
"""[app-icons] Build Icon Composer (.icon) bundles for every icon option in AppIconChoice.all
and its pinned -Light / -Dark variants (all 42 icon sets).

Every .icon bundle provides shared iOS/iPadOS/macOS Light, Dark, Clear (Light & Dark), and
Tinted (Light & Dark) Liquid Glass rendering when compiled by Xcode's actool:
  - Primary icon stays at App/Resources/AppIcon.icon (Halo, automatic).
  - All 41 alternate sets live in App/Resources/AppIcons/<Name>.icon.
  - Existing Assets.xcassets/*.appiconset files are left untouched (keeping scripts/default-app-icon.lock
    and legacy fallbacks intact).

Usage (from repo root):
  python3 scripts/make-icon-composer-icons.py [--artifacts PATH]
"""
from __future__ import annotations

import argparse
import collections
import json
import math
import re
import shutil
from pathlib import Path
from PIL import Image, ImageFilter

SIDE = 1024

WARM_PAPER = {"solid": "srgb:0.96863,0.96078,0.94118,1.00000"}        # #F7F5F0
COOL_MIST = {"solid": "srgb:0.90588,0.92941,0.95686,1.00000"}         # #E7EDF4
COOL_SLATE = {"solid": "srgb:0.06275,0.08235,0.11765,1.00000"}        # #10151E
SWOOP_CREAM = {"solid": "srgb:1.00000,0.95294,0.83922,1.00000"}       # #FFF3D6
SWOOP_DARK = {"solid": "srgb:0.12941,0.12157,0.14118,1.00000"}        # #211F24
SYSTEM_DARK = "system-dark"


def smoothstep(a: float, b: float, x: float) -> float:
    if b == a:
        return 0.0 if x < a else 1.0
    t = max(0.0, min(1.0, (x - a) / (b - a)))
    return t * t * (3.0 - 2.0 * t)


def paper_row_rgb(y: int) -> tuple[float, float, float]:
    """AppIconArt.ground(.light): FCFBF8 -> F7F5F0 (0.45) -> EDEAE3, top to bottom."""
    t = y / (SIDE - 1)
    if t <= 0.45:
        u = t / 0.45
        return (
            0xFC + (0xF7 - 0xFC) * u,
            0xFB + (0xF5 - 0xFB) * u,
            0xF8 + (0xF0 - 0xF8) * u,
        )
    u = (t - 0.45) / 0.55
    return (
        0xF7 + (0xED - 0xF7) * u,
        0xF5 + (0xEA - 0xF5) * u,
        0xF0 + (0xE3 - 0xF0) * u,
    )


def dark_tile_rgb(x: int, y: int) -> tuple[float, float, float]:
    """AppIconArt.ground(.dark): radial from (512, 122.88) r=1024: 2B2B33 -> 121216 (0.6) -> 08080A."""
    dx = x - SIDE * 0.5
    dy = y - SIDE * 0.12
    d = min(1.0, math.hypot(dx, dy) / SIDE)
    if d <= 0.6:
        u = d / 0.6
        return (
            0x2B + (0x12 - 0x2B) * u,
            0x2B + (0x12 - 0x2B) * u,
            0x33 + (0x16 - 0x33) * u,
        )
    u = (d - 0.6) / 0.4
    return (
        0x12 + (0x08 - 0x12) * u,
        0x12 + (0x08 - 0x12) * u,
        0x16 + (0x0A - 0x16) * u,
    )


def build_icon_json(
    name: str,
    light_fill,
    dark_fill,
    light_asset: str,
    dark_asset: str,
    tinted_asset: str,
    pin: str | None = None,
    glass_on_tinted: bool = True,
    translucency_on_tinted: float = 0.35,
    shadow_on_tinted: float = 0.4,
) -> dict:
    """Create icon.json for automatic (pin=None), pinned 'Light', or pinned 'Dark'."""
    if pin == "Light":
        fills = [
            {"value": light_fill},
            {"appearance": "dark", "value": light_fill},
        ]
        images = [
            {"value": light_asset},
            {"appearance": "dark", "value": light_asset},
            {"appearance": "tinted", "value": tinted_asset},
        ]
    elif pin == "Dark":
        fills = [
            {"value": dark_fill},
            {"appearance": "dark", "value": dark_fill},
        ]
        images = [
            {"value": dark_asset},
            {"appearance": "dark", "value": dark_asset},
            {"appearance": "tinted", "value": tinted_asset},
        ]
    else:
        fills = [
            {"value": light_fill},
            {"appearance": "dark", "value": dark_fill},
        ]
        images = [
            {"value": light_asset},
            {"appearance": "dark", "value": dark_asset},
            {"appearance": "tinted", "value": tinted_asset},
        ]

    layer: dict = {
        "image-name-specializations": images,
        "name": name,
    }
    group: dict = {"layers": [layer]}

    if glass_on_tinted:
        layer["glass-specializations"] = [
            {"value": False},
            {"appearance": "tinted", "value": True},
        ]
        group["shadow-specializations"] = [
            {"value": {"kind": "none", "opacity": 0.0}},
            {"appearance": "tinted", "value": {"kind": "neutral", "opacity": shadow_on_tinted}},
        ]
        group["translucency-specializations"] = [
            {"value": {"enabled": False, "value": 0.0}},
            {"appearance": "tinted", "value": {"enabled": True, "value": translucency_on_tinted}},
        ]
    else:
        layer["glass"] = False
        group["shadow"] = {"kind": "none", "opacity": 0.0}
        group["translucency"] = {"enabled": False, "value": 0.0}

    return {
        "fill-specializations": fills,
        "groups": [group],
        "supported-platforms": {"squares": "shared"},
    }


def write_icon_bundle(
    dest: Path,
    layer_name: str,
    light_fill,
    dark_fill,
    assets: dict[str, bytes],
    light_key: str,
    dark_key: str,
    tinted_key: str,
    pin: str | None = None,
    glass_on_tinted: bool = True,
    translucency_on_tinted: float = 0.35,
    shadow_on_tinted: float = 0.4,
) -> None:
    if dest.exists():
        shutil.rmtree(dest)
    assets_dir = dest / "Assets"
    assets_dir.mkdir(parents=True)

    # Copy only the assets referenced by this bundle so pinned sets stay lean.
    if pin == "Light":
        needed = {light_key, tinted_key}
    elif pin == "Dark":
        needed = {dark_key, tinted_key}
    else:
        needed = {light_key, dark_key, tinted_key}

    for fname in sorted(needed):
        (assets_dir / fname).write_bytes(assets[fname])

    doc = build_icon_json(
        name=layer_name,
        light_fill=light_fill,
        dark_fill=dark_fill,
        light_asset=light_key,
        dark_asset=dark_key,
        tinted_asset=tinted_key,
        pin=pin,
        glass_on_tinted=glass_on_tinted,
        translucency_on_tinted=translucency_on_tinted,
        shadow_on_tinted=shadow_on_tinted,
    )
    (dest / "icon.json").write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")


def png_bytes(img: Image.Image) -> bytes:
    import io
    buf = io.BytesIO()
    img.save(buf, format="PNG", optimize=True)
    return buf.getvalue()


# ---------------------------------------------------------------------------
# Vector SVG builders (transparent background, true mask/evenodd cutouts)
# ---------------------------------------------------------------------------

def make_halo_assets(repo: Path, artifacts: Path | None) -> dict[str, bytes]:
    existing = repo / "App/Resources/AppIcon.icon/Assets"
    if (existing / "halo-light.svg").exists() and (existing / "halo-dark.svg").exists():
        return {
            "halo-light.svg": (existing / "halo-light.svg").read_bytes(),
            "halo-dark.svg": (existing / "halo-dark.svg").read_bytes(),
        }
    assert artifacts is not None
    raw = (artifacts / "hq-icons-finalists/out/HQ-feather-48.svg").read_text(encoding="utf-8")
    no_bg = re.sub(r"<rect [^>]*/>", "", raw, count=1)
    return {
        "halo-light.svg": no_bg.replace('fill="#ffffff"', 'fill="#141417"').encode("utf-8"),
        "halo-dark.svg": no_bg.encode("utf-8"),
    }


def make_silhouette_assets(repo: Path, artifacts: Path | None) -> dict[str, bytes]:
    existing = repo / "App/Resources/AppIcons/AppIcon-Silhouette.icon/Assets"
    if artifacts and (artifacts / "hq-icons-finalists/out/HQ-feather-02.svg").exists():
        raw = (artifacts / "hq-icons-finalists/out/HQ-feather-02.svg").read_text(encoding="utf-8")
        no_bg = re.sub(r"<rect [^>]*/>", "", raw, count=1)
        return {
            "silhouette-light.svg": no_bg.replace('fill="#ffffff"', 'fill="#141417"').encode("utf-8"),
            "silhouette-dark.svg": no_bg.encode("utf-8"),
        }
    return {
        "silhouette-light.svg": (existing / "silhouette-light.svg").read_bytes(),
        "silhouette-dark.svg": (existing / "silhouette-dark.svg").read_bytes(),
    }


def make_swoop_assets() -> dict[str, bytes]:
    # Combine feather silhouette + rachis vein using fill-rule="evenodd" so the vein is truly transparent.
    outer = (
        "M18 82 Q22 73 27 65 C19 40 42 25 83 15 Q81 30 70 42 "
        "L58 46 L68 46 Q64 54 54 59 L44 60 L51 62 Q43 69 31 69 L21 84 Q18 86 18 82Z"
    )
    vein = "M25 74 Q40 47 71 28 Q45 49 29 74Z"
    def svg(fill: str) -> bytes:
        return (
            f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 100 100">'
            f'<path fill="{fill}" fill-rule="evenodd" d="{outer} {vein}"/>'
            f'</svg>\n'
        ).encode("utf-8")
    return {
        "swoop-light.svg": svg("#211f24"),
        "swoop-dark.svg": svg("#fff3d6"),
        "swoop-tinted.svg": svg("#ffffff"),
    }


def make_flux_assets(repo: Path, artifacts: Path | None) -> dict[str, bytes]:
    existing = repo / "App/Resources/AppIcons/AppIcon-Flux.icon/Assets"
    if artifacts and (artifacts / "operator-proofs/shortlist-cut/04-Flux.svg").exists():
        raw = (artifacts / "operator-proofs/shortlist-cut/04-Flux.svg").read_text(encoding="utf-8")
        # Extract clipPath and circles cleanly, remove bg rect and opaque eye rects, replace with transparent mask.
        clip_m = re.search(r"<defs>(.*?)</defs>", raw, re.S)
        dots_m = re.search(r'<g clip-path="url\(#a\)">(.*?)</g>', raw, re.S)
        assert clip_m and dots_m
        clip_defs = clip_m.group(1)
        dots = dots_m.group(1)

        def build(color: str) -> bytes:
            colored_dots = dots.replace('fill="#548eff"', f'fill="{color}"')
            return (
                '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
                '<defs>'
                f'{clip_defs}'
                '<mask id="eyes">'
                '<rect width="1024" height="1024" fill="white"/>'
                '<g transform="scale(10.24)"><g transform="translate(58 48) rotate(-13) skewX(6)">'
                '<rect x="-9" y="-4" width="5.4" height="9" rx="2.7" fill="black"/>'
                '<rect x="3" y="-4" width="5.4" height="9" rx="2.7" fill="black"/>'
                '</g></g>'
                '</mask>'
                '</defs>'
                f'<g mask="url(#eyes)"><g transform="scale(10.24)"><g clip-path="url(#a)">{colored_dots}</g></g></g>'
                '</svg>\n'
            ).encode("utf-8")

        return {
            "flux-light.svg": build("#2159c2"),
            "flux-dark.svg": build("#548eff"),
            "flux-tinted.svg": build("#ffffff"),
        }
    return {
        "flux-light.svg": (existing / "flux-light.svg").read_bytes(),
        "flux-dark.svg": (existing / "flux-dark.svg").read_bytes(),
        "flux-tinted.svg": (existing / "flux-tinted.svg").read_bytes(),
    }


def make_afterimage_assets() -> dict[str, bytes]:
    head_d = "M17 57C16 41 33 24 51 20C67 17 78 26 82 43C86 61 75 74 59 78C39 83 19 75 17 57Z"
    eyes_g = (
        '<g transform="translate(58 49) rotate(-13) skewX(6)">'
        '<rect x="-9" y="-4" width="5.4" height="9" rx="2.7" fill="black"/>'
        '<rect x="3" y="-4" width="5.4" height="9" rx="2.7" fill="black"/>'
        '</g>'
    )

    def build(echo_fill: str, echo_opacity: float, head_fill: str, dot_fill: str, dot_opacity: float) -> bytes:
        # Use 1024x1024 viewBox so CoreSVG rasterizes SVG <mask> at full 1024 resolution.
        return (
            '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
            '<defs>'
            '<mask id="echo-cut">'
            '<rect width="1024" height="1024" fill="white"/>'
            f'<g transform="scale(10.24)"><path d="{head_d}" fill="black"/></g>'
            '</mask>'
            '<mask id="head-eyes">'
            '<rect width="1024" height="1024" fill="white"/>'
            f'<g transform="scale(10.24)">{eyes_g}</g>'
            '</mask>'
            '</defs>'
            f'<g mask="url(#echo-cut)"><g transform="scale(10.24)"><g transform="translate(-7 5)">'
            f'<path d="{head_d}" fill="{echo_fill}" opacity="{echo_opacity}"/></g></g></g>'
            f'<g mask="url(#head-eyes)"><g transform="scale(10.24)"><path d="{head_d}" fill="{head_fill}"/></g></g>'
            f'<g transform="scale(10.24)"><circle cx="81" cy="22" r="4.7" fill="{dot_fill}" opacity="{dot_opacity}"/></g>'
            '</svg>\n'
        ).encode("utf-8")

    return {
        "afterimage-light.svg": build("#a3b7ce", 1.0, "#10151e", "#548eff", 1.0),
        "afterimage-dark.svg": build("#465977", 1.0, "#c6d8ef", "#548eff", 1.0),
        "afterimage-tinted.svg": build("#ffffff", 0.38, "#ffffff", "#ffffff", 0.72),
    }


def make_replycut_assets() -> dict[str, bytes]:
    back_d = "M17 22H58Q61 22 61 25V53H36L22 65V53H17Q14 53 14 50V25Q14 22 17 22Z"
    cut_d = "M34 36Q34 32 38 32H80Q86 32 86 38V70Q86 74 82 74H76V86L58 74H38Q34 74 34 70Z"
    front_d = "M39 40Q39 37 42 37H80Q82 37 82 40V66Q82 69 79 69H71V77L59 69H42Q39 69 39 66Z"
    eyes_g = (
        '<g transform="translate(60 52) rotate(-13) skewX(6)">'
        '<rect x="-9" y="-4" width="5.4" height="9" rx="2.7" fill="black"/>'
        '<rect x="3" y="-4" width="5.4" height="9" rx="2.7" fill="black"/>'
        '</g>'
    )

    def build(back_fill: str, front_fill: str, front_opacity: float) -> bytes:
        return (
            '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
            '<defs>'
            '<mask id="back-cut">'
            '<rect width="1024" height="1024" fill="white"/>'
            f'<g transform="scale(10.24)"><path d="{cut_d}" fill="black"/></g>'
            '</mask>'
            '<mask id="front-eyes">'
            '<rect width="1024" height="1024" fill="white"/>'
            f'<g transform="scale(10.24)">{eyes_g}</g>'
            '</mask>'
            '</defs>'
            f'<g mask="url(#back-cut)"><g transform="scale(10.24)"><path d="{back_d}" fill="{back_fill}"/></g></g>'
            f'<g mask="url(#front-eyes)"><g transform="scale(10.24)"><path d="{front_d}" fill="{front_fill}" opacity="{front_opacity}"/></g></g>'
            '</svg>\n'
        ).encode("utf-8")

    return {
        "replycut-light.svg": build("#20314b", "#5189ee", 1.0),
        "replycut-dark.svg": build("#c6d8ef", "#548eff", 1.0),
        "replycut-tinted.svg": build("#ffffff", "#ffffff", 0.62),
    }


def make_turntaking_assets() -> dict[str, bytes]:
    back_d = "M15 36Q15 23 28 23H53Q66 23 66 36V44Q66 54 54 54H36L20 67L23 53Q15 51 15 44Z"
    cut_d = "M35 49Q35 37 48 37H71Q86 37 86 51V61Q86 75 74 75L78 85L59 75H48Q35 75 35 62Z"
    front_d = "M39 51Q39 41 50 41H70Q82 41 82 52V60Q82 71 70 71H68L72 79L58 71H50Q39 71 39 61Z"
    eyes_g = (
        '<g transform="translate(61 55) rotate(-13) skewX(6)">'
        '<rect x="-9" y="-4" width="5.4" height="9" rx="2.7" fill="black"/>'
        '<rect x="3" y="-4" width="5.4" height="9" rx="2.7" fill="black"/>'
        '</g>'
    )

    def build(back_fill: str, front_fill: str, front_opacity: float) -> bytes:
        return (
            '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
            '<defs>'
            '<mask id="back-cut">'
            '<rect width="1024" height="1024" fill="white"/>'
            '<g transform="scale(10.24)">'
            '<rect x="25" y="32" width="20" height="4" rx="2" fill="black"/>'
            f'<path d="{cut_d}" fill="black"/>'
            '</g>'
            '</mask>'
            '<mask id="front-eyes">'
            '<rect width="1024" height="1024" fill="white"/>'
            f'<g transform="scale(10.24)">{eyes_g}</g>'
            '</mask>'
            '</defs>'
            f'<g mask="url(#back-cut)"><g transform="scale(10.24)"><path d="{back_d}" fill="{back_fill}"/></g></g>'
            f'<g mask="url(#front-eyes)"><g transform="scale(10.24)"><path d="{front_d}" fill="{front_fill}" opacity="{front_opacity}"/></g></g>'
            '</svg>\n'
        ).encode("utf-8")

    return {
        "turntaking-light.svg": build("#10151e", "#548eff", 1.0),
        "turntaking-dark.svg": build("#c6d8ef", "#548eff", 1.0),
        "turntaking-tinted.svg": build("#ffffff", "#ffffff", 0.62),
    }


def make_blackwhite_assets(repo: Path, artifacts: Path | None) -> dict[str, bytes]:
    existing = repo / "App/Resources/AppIcons/AppIcon-BlackWhite.icon/Assets"
    if artifacts and (artifacts / "manga-feather/D.svg").exists():
        raw = (artifacts / "manga-feather/D.svg").read_text(encoding="utf-8")
        # Dark SVG: drop the bg gradient rect so the feather sits transparently over system-dark!
        dark_svg = re.sub(r'<rect width="1024" height="1024" fill="url\(#bg\)"/>', "", raw, count=1)

        # Extract the inner <g transform=...> body from D.svg for Light and Tinted variants.
        g_m = re.search(r'(<g transform="translate\(512 520\).*</g>)</svg>', dark_svg, re.S)
        assert g_m
        g_body = g_m.group(1)

        # Light SVG: matches make-light-icons.py ink_from_light — dark #141417 outline/barbs/left vane,
        # transparent right vane cavity so warm paper shows through cleanly!
        # Let's build crisp vector Light and Tinted SVGs:
        # In D.svg:
        #  - outer silhouette stroke=#fff width=22 -> gives the crisp rim
        #  - stem stroke=#fff width=28
        #  - right vane fill=#060607 (dark cavity)
        #  - left vane fill=url(#pale) (bright half)
        #  - 3 barb highlights inside clip-path=#R fill=#fff
        #  - central rachis stroke=#fff width=9
        # For Tinted/Clear: mask out the right-vane cavity (#060607) so Clear glass shines RIGHT THROUGH it,
        # while keeping the white rim, pale left vane, white barbs, stem, and central rachis crisp white!
        feather_d = (
            "M258 872C270 686 368 325 723 176C659 273 591 338 524 413"
            "C605 358 678 328 748 313C679 414 600 480 525 535"
            "C602 496 666 476 719 463C649 594 497 693 362 751"
            "C322 778 290 824 272 877Z"
        )
        barbs_m = re.search(r'<g clip-path="url\(#R\)">(.*?)</g>', g_body, re.S)
        assert barbs_m
        barbs = barbs_m.group(1)

        def build_cutout(ink: str, left_fill: str, left_opacity: float) -> bytes:
            # Draw outer silhouette stroke-only (no interior fill on right side!), left vane filled,
            # barbs filled, stem & rachis stroked — completely transparent right vane!
            colored_barbs = barbs.replace('fill="#fff"', f'fill="{ink}"')
            return (
                '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
                '<defs>'
                '<linearGradient id="pale" gradientUnits="userSpaceOnUse" x1="260" y1="870" x2="720" y2="180">'
                '<stop offset="0" stop-color="#D2D5DC"/><stop offset=".55" stop-color="#ECEEF2"/><stop offset="1" stop-color="#FFFFFF"/>'
                '</linearGradient>'
                '<clipPath id="L"><path d="M266 875C330 680 470 420 723 176L723 0L0 0L0 1024L266 1024Z"/></clipPath>'
                '<clipPath id="R"><path d="M266 875C330 680 470 420 723 176L723 0L1024 0L1024 1024L266 1024Z"/></clipPath>'
                '</defs>'
                '<g transform="translate(512 520) scale(1.16) translate(-500 -526)">'
                f'<path d="{feather_d}" fill="{left_fill}" opacity="{left_opacity}" clip-path="url(#L)"/>'
                f'<path d="{feather_d}" fill="none" stroke="{ink}" stroke-width="22" stroke-linejoin="round"/>'
                f'<path d="M266 875L246 960" stroke="{ink}" stroke-width="28" stroke-linecap="round"/>'
                f'<g clip-path="url(#R)">{colored_barbs}</g>'
                f'<path d="M266 875C330 680 470 420 723 176" fill="none" stroke="{ink}" stroke-width="9" stroke-linecap="round"/>'
                '</g>'
                '</svg>\n'
            ).encode("utf-8")

        return {
            "blackwhite-light.svg": build_cutout("#141417", "#141417", 0.92),
            "blackwhite-dark.svg": dark_svg.encode("utf-8"),
            "blackwhite-tinted.svg": build_cutout("#ffffff", "#ffffff", 0.85),
        }
    return {
        "blackwhite-light.svg": (existing / "blackwhite-light.svg").read_bytes(),
        "blackwhite-dark.svg": (existing / "blackwhite-dark.svg").read_bytes(),
        "blackwhite-tinted.svg": (existing / "blackwhite-tinted.svg").read_bytes(),
    }


# ---------------------------------------------------------------------------
# Raster-to-transparent-RGBA builders (pure Pillow, lossless alpha recovery)
# ---------------------------------------------------------------------------

def make_feather_assets(catalog: Path) -> dict[str, bytes]:
    """Feather is crisp white-on-black ink line art: smoothstep luminance -> pure alpha."""
    src = Image.open(catalog / "AppIcon-Feather.appiconset/AppIcon-Feather-Dark.png").convert("RGB")
    px = src.load()
    # Floor of dark background (~12/255)
    lums = [((px[x, y][0] + px[x, y][1] + px[x, y][2]) / 765.0) for y in range(0, SIDE, 8) for x in range(0, SIDE, 8)]
    lums.sort()
    floor = lums[int(len(lums) * 0.05)]

    light = Image.new("RGBA", (SIDE, SIDE))
    dark = Image.new("RGBA", (SIDE, SIDE))
    lp, dp = light.load(), dark.load()
    for y in range(SIDE):
        for x in range(SIDE):
            r, g, b = px[x, y]
            lum = (r + g + b) / 765.0
            a = int(round(smoothstep(floor + 0.02, 0.92, lum) * 255))
            if a == 0:
                lp[x, y] = (0, 0, 0, 0)
                dp[x, y] = (0, 0, 0, 0)
            else:
                lp[x, y] = (0x14, 0x14, 0x17, a)
                dp[x, y] = (255, 255, 255, a)
    return {
        "feather-light.png": png_bytes(light),
        "feather-dark.png": png_bytes(dark),
    }


def make_pearl_assets(catalog: Path) -> dict[str, bytes]:
    """Original (Pearl): isolate the 3 feather blades cleanly, dropping the baked rounded border."""
    src = Image.open(catalog / "AppIcon-Pearl.appiconset/AppIcon-Pearl-Dark.png").convert("RGB")
    px = src.load()
    light = Image.new("RGBA", (SIDE, SIDE))
    dark = Image.new("RGBA", (SIDE, SIDE))
    tinted = Image.new("RGBA", (SIDE, SIDE))
    lp, dp, tp = light.load(), dark.load(), tinted.load()

    for y in range(SIDE):
        t = y / (SIDE - 1)
        sr = int(round(0x3A + (0x0C - 0x3A) * t))
        sg = int(round(0x3A + (0x0C - 0x3A) * t))
        sb = int(round(0x42 + (0x0F - 0x42) * t))
        for x in range(SIDE):
            r, g, b = px[x, y]
            lum = (r + g + b) / 765.0
            f = smoothstep(0.30, 0.60, lum)
            a = int(round(f * 255))
            if a == 0:
                lp[x, y] = dp[x, y] = tp[x, y] = (0, 0, 0, 0)
            else:
                lp[x, y] = (sr, sg, sb, a)
                # Preserve pearlescent shading for dark; pure white for tinted/clear.
                dp[x, y] = (min(255, int(round(r / max(f, 0.35)))),
                            min(255, int(round(g / max(f, 0.35)))),
                            min(255, int(round(b / max(f, 0.35)))), a)
                tp[x, y] = (255, 255, 255, a)

    return {
        "pearl-light.png": png_bytes(light),
        "pearl-dark.png": png_bytes(dark),
        "pearl-tinted.png": png_bytes(tinted),
    }


def flood_exterior_mask(
    img: Image.Image,
    bg_fn,
    tol: float,
    extra_seed_rows: list[int] | None = None,
) -> Image.Image:
    """BFS flood-fill from image border where pixel is within `tol` of analytical bg_fn(x, y).
    Returns an 'L' mask: 0 = exterior background, 255 = foreground figure.
    """
    px = img.load()
    visited = bytearray(SIDE * SIDE)
    q = collections.deque()

    def matches_bg(x: int, y: int) -> bool:
        r, g, b = px[x, y]
        br, bg_, bb = bg_fn(x, y)
        return abs(r - br) + abs(g - bg_) + abs(b - bb) <= tol

    # Seed all border pixels that match background
    for x in range(SIDE):
        for y in (0, SIDE - 1):
            if matches_bg(x, y):
                idx = y * SIDE + x
                if not visited[idx]:
                    visited[idx] = 1
                    q.append((x, y))
    for y in range(SIDE):
        for x in (0, SIDE - 1):
            if matches_bg(x, y):
                idx = y * SIDE + x
                if not visited[idx]:
                    visited[idx] = 1
                    q.append((x, y))

    while q:
        x, y = q.popleft()
        if x > 0:
            idx = y * SIDE + (x - 1)
            if not visited[idx] and matches_bg(x - 1, y):
                visited[idx] = 1
                q.append((x - 1, y))
        if x + 1 < SIDE:
            idx = y * SIDE + (x + 1)
            if not visited[idx] and matches_bg(x + 1, y):
                visited[idx] = 1
                q.append((x + 1, y))
        if y > 0:
            idx = (y - 1) * SIDE + x
            if not visited[idx] and matches_bg(x, y - 1):
                visited[idx] = 1
                q.append((x, y - 1))
        if y + 1 < SIDE:
            idx = (y + 1) * SIDE + x
            if not visited[idx] and matches_bg(x, y + 1):
                visited[idx] = 1
                q.append((x, y + 1))

    # Build L mask (255 = foreground, 0 = exterior)
    mask_bytes = bytes(0 if v else 255 for v in visited)
    return Image.frombytes("L", (SIDE, SIDE), mask_bytes)


def make_hermes_assets(catalog: Path) -> dict[str, bytes]:
    """Hermes engraving: recover exact silhouette mask from Light (which already has the clean
    outline on warm paper) and produce crisp transparent-background Light, Dark, and Tinted/Clear
    engraving layers!
    """
    light_src = Image.open(catalog / "AppIcon-Hermes.appiconset/AppIcon-Hermes.png").convert("RGB")
    dark_src = Image.open(catalog / "AppIcon-Hermes.appiconset/AppIcon-Hermes-Dark.png").convert("RGB")

    # In AppIcon-Hermes.png, exterior pixels match paper_row_rgb(y) almost identically; Hermes has a dark ink rim.
    # Flood-fill exterior where pixel matches paper_row_rgb(y) within tolerance 18.
    mask = flood_exterior_mask(light_src, lambda x, y: paper_row_rgb(y), tol=18.0)
    # Soften boundary by 1px for anti-aliased Light edge
    soft_mask = mask.filter(ImageFilter.GaussianBlur(radius=1.0))
    # Eroded interior mask (8px inset) so dark-mode outer ink rim blends seamlessly into system-dark
    inner_mask = mask.filter(ImageFilter.MinFilter(17)).filter(ImageFilter.GaussianBlur(radius=4.0))

    lp_src = light_src.load()
    dp_src = dark_src.load()
    mp = soft_mask.load()
    raw_mp = mask.load()
    imp = inner_mask.load()

    light_out = Image.new("RGBA", (SIDE, SIDE))
    dark_out = Image.new("RGBA", (SIDE, SIDE))
    tinted_out = Image.new("RGBA", (SIDE, SIDE))
    lo, do_, to = light_out.load(), dark_out.load(), tinted_out.load()

    for y in range(SIDE):
        for x in range(SIDE):
            a = mp[x, y]
            if a == 0:
                lo[x, y] = do_[x, y] = to[x, y] = (0, 0, 0, 0)
                continue

            # Light layer: un-premultiply edge fringe against warm paper so no pale halo shows on edges
            lr, lg, lb = lp_src[x, y]
            if raw_mp[x, y] == 0 and a < 255:
                lo[x, y] = (0x14, 0x14, 0x17, a)
            else:
                lo[x, y] = (lr, lg, lb, a)

            # Dark layer: Hermes engraving on transparent so system-dark shows cleanly behind him.
            # Near the outer silhouette rim (where inner_mask < 255), very dark surround pixels fade
            # cleanly to transparent instead of leaving a darker-than-system-dark black halo.
            dr, dg, db = dp_src[x, y]
            lum = (dr + dg + db) / 765.0
            rim_fade = max(imp[x, y] / 255.0, smoothstep(0.04, 0.16, lum))
            da = int(round((a / 255.0) * rim_fade * 255))
            do_[x, y] = (dr, dg, db, da) if da > 0 else (0, 0, 0, 0)

            # Tinted / Clear layer: pure white engraving with luminance mapped to alpha!
            # Bright highlights (face, cheek, wing feathers, curls) are crisp white, while dark
            # engraved shadows become translucent so Clear & Tinted glass shines through cleanly.
            eng_lum = smoothstep(0.035, 0.92, lum)
            t_alpha = int(round((a / 255.0) * eng_lum * 255))
            to[x, y] = (255, 255, 255, t_alpha)

    return {
        "hermes-light.png": png_bytes(light_out),
        "hermes-dark.png": png_bytes(dark_out),
        "hermes-tinted.png": png_bytes(tinted_out),
    }


def make_shapes_assets(catalog: Path) -> dict[str, bytes]:
    """Shapes: crisp pure-vector SVG measured directly from AppIcon-Shapes-Tinted.png (exact round
    head and slit eyes) with white eyes on Light and truly transparent cutout eyes on Dark & Tinted/Clear.
    """
    tinted = Image.open(catalog / "AppIcon-Shapes.appiconset/AppIcon-Shapes-Tinted.png").convert("L")
    tp = tinted.load()

    # Measure head circle bounds (bright pixels > 128)
    h_xs, h_ys = [], []
    for y in range(SIDE):
        for x in range(SIDE):
            if tp[x, y] > 128:
                h_xs.append(x)
                h_ys.append(y)
    cx = (min(h_xs) + max(h_xs)) / 2.0 + 0.5
    cy = (min(h_ys) + max(h_ys)) / 2.0 + 0.5
    rx = (max(h_xs) - min(h_xs) + 1) / 2.0
    ry = (max(h_ys) - min(h_ys) + 1) / 2.0
    r = (rx + ry) / 2.0

    # Measure left and right slit eyes (dark pixels < 128 inside central head box)
    def measure_eye(x0: int, x1: int) -> tuple[float, float, float, float]:
        xs, ys = [], []
        for y in range(380, 644):
            for x in range(x0, x1):
                if tp[x, y] < 128:
                    xs.append(x)
                    ys.append(y)
        ex, ey = float(min(xs)), float(min(ys))
        ew, eh = float(max(xs) - min(xs) + 1), float(max(ys) - min(ys) + 1)
        return ex, ey, ew, eh

    lx, ly, lw, lh = measure_eye(340, 512)
    rx_, ry_, rw, rh = measure_eye(512, 684)
    er = min(lw, rw) / 2.0

    def svg_cut(fill: str) -> bytes:
        return (
            '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
            '<defs><mask id="eyes">'
            '<rect width="1024" height="1024" fill="white"/>'
            f'<rect x="{lx:.1f}" y="{ly:.1f}" width="{lw:.1f}" height="{lh:.1f}" rx="{er:.1f}" fill="black"/>'
            f'<rect x="{rx_:.1f}" y="{ry_:.1f}" width="{rw:.1f}" height="{rh:.1f}" rx="{er:.1f}" fill="black"/>'
            '</mask></defs>'
            f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{r:.1f}" fill="{fill}" mask="url(#eyes)"/>'
            '</svg>\n'
        ).encode("utf-8")

    light_svg = (
        '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
        f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{r:.1f}" fill="#22bcd8"/>'
        f'<rect x="{lx:.1f}" y="{ly:.1f}" width="{lw:.1f}" height="{lh:.1f}" rx="{er:.1f}" fill="#ffffff"/>'
        f'<rect x="{rx_:.1f}" y="{ry_:.1f}" width="{rw:.1f}" height="{rh:.1f}" rx="{er:.1f}" fill="#ffffff"/>'
        '</svg>\n'
    ).encode("utf-8")

    return {
        "shapes-light.svg": light_svg,
        "shapes-dark.svg": svg_cut("#22bcd8"),
        "shapes-tinted.svg": svg_cut("#ffffff"),
    }


def make_matrix_assets(catalog: Path) -> dict[str, bytes]:
    """Matrix: 15x15 dot-matrix head.
    - Tinted/Clear: crisp white LEDs with transparent background and transparent eye gaps.
    - Dark: bright glowing teal LEDs with transparent background and transparent eye gaps.
    - Light: rich deep teal (#009EBA) LEDs + dark eye LEDs matching AppIcon-Matrix.png on transparent.
    """
    light_src = Image.open(catalog / "AppIcon-Matrix.appiconset/AppIcon-Matrix.png").convert("RGB")
    dark_src = Image.open(catalog / "AppIcon-Matrix.appiconset/AppIcon-Matrix-Dark.png").convert("RGB")
    tinted_src = Image.open(catalog / "AppIcon-Matrix.appiconset/AppIcon-Matrix-Tinted.png").convert("RGB")

    lp = light_src.load()
    dp = dark_src.load()
    tp = tinted_src.load()

    light_out = Image.new("RGBA", (SIDE, SIDE))
    dark_out = Image.new("RGBA", (SIDE, SIDE))
    tinted_out = Image.new("RGBA", (SIDE, SIDE))
    lo, do_, to = light_out.load(), dark_out.load(), tinted_out.load()

    # Exact Matrix Light LED color from AppIcon-Matrix.png (deep teal #009EBA)
    lt_r, lt_g, lt_b = 0x00, 0x9E, 0xBA

    for y in range(SIDE):
        pr, pg, pb = paper_row_rgb(y)
        for x in range(SIDE):
            # Tinted: pure greyscale 0..251 -> alpha
            tv = tp[x, y][0]
            ta = min(255, int(round(tv * 255.0 / 251.0)))
            to[x, y] = (255, 255, 255, ta) if ta > 0 else (0, 0, 0, 0)

            # Dark: recover glowing LEDs relative to dark_tile_rgb(x, y)
            dr, dg, db = dp[x, y]
            br, bg_, bb = dark_tile_rgb(x, y)
            diff_d = max(dr - br, dg - bg_, db - bb, 0.0)
            if ta > 10:
                do_[x, y] = (dr, dg, db, max(ta, min(255, int(round(diff_d * 1.4)))))
            elif diff_d > 3.0:
                ga = min(255, int(round(diff_d * 2.2)))
                do_[x, y] = (0x22, 0xBC, 0xD8, ga)
            else:
                do_[x, y] = (0, 0, 0, 0)

            # Light: deep teal LEDs (#009EBA) + dark eye LEDs (#141417) separated cleanly from paper
            lr, lg, lb = lp[x, y]
            d_r = pr - lr
            d_g = pg - lg
            d_b = pb - lb
            dist = max(abs(d_r), abs(d_g), abs(d_b))
            if dist <= 3.0:
                lo[x, y] = (0, 0, 0, 0)
            elif (lb - lr) < 35 and lr < 180 and lg < 180 and lb < 180:
                # Neutral dark eye LED (in Light mode eyes are dark ink dots, not teal)
                a = min(255, int(round((d_r + d_g + d_b) / (3.0 * max(pr - 0x14, 1)) * 255)))
                lo[x, y] = (0x14, 0x14, 0x17, a) if a > 4 else (0, 0, 0, 0)
            elif ta > 0:
                # Lit teal LED: use exact #009EBA color with crisp alpha from tinted/paper-diff
                a = max(ta, min(255, int(round(d_r / max(pr - lt_r, 1) * 255))))
                lo[x, y] = (lt_r, lt_g, lt_b, a)
            else:
                # Soft edge of dark eye dot
                a = min(255, int(round((d_r + d_g + d_b) / (3.0 * max(pr - 0x14, 1)) * 255)))
                lo[x, y] = (0x14, 0x14, 0x17, a) if a > 4 else (0, 0, 0, 0)

    return {
        "matrix-light.png": png_bytes(light_out),
        "matrix-dark.png": png_bytes(dark_out),
        "matrix-tinted.png": png_bytes(tinted_out),
    }


def make_robot_assets(catalog: Path) -> dict[str, bytes]:
    """Robot bust: exact silhouette recovered from Light vs analytical paper gradient!"""
    light_src = Image.open(catalog / "AppIcon-Robot.appiconset/AppIcon-Robot.png").convert("RGB")
    dark_src = Image.open(catalog / "AppIcon-Robot.appiconset/AppIcon-Robot-Dark.png").convert("RGB")
    tinted_src = Image.open(catalog / "AppIcon-Robot.appiconset/AppIcon-Robot-Tinted.png").convert("RGB")

    # Flood-fill exterior matching paper_row_rgb(y) -> 255 = inside robot bust, 0 = outside!
    hard_mask = flood_exterior_mask(light_src, lambda x, y: paper_row_rgb(y), tol=14.0)
    # Dilate by 1px for anti-aliased edge recovery
    edge_mask = hard_mask.filter(ImageFilter.MaxFilter(3))
    # Soft rim zone right around the robot bust (14px) for crisp Dark rim highlight without dark-black surround
    rim_zone = hard_mask.filter(ImageFilter.MaxFilter(19))

    lp = light_src.load()
    dp = dark_src.load()
    tp = tinted_src.load()
    hm = hard_mask.load()
    em = edge_mask.load()
    rz = rim_zone.load()

    light_out = Image.new("RGBA", (SIDE, SIDE))
    dark_out = Image.new("RGBA", (SIDE, SIDE))
    tinted_out = Image.new("RGBA", (SIDE, SIDE))
    lo, do_, to = light_out.load(), dark_out.load(), tinted_out.load()

    for y in range(SIDE):
        pr, pg, pb = paper_row_rgb(y)
        for x in range(SIDE):
            # Light robot
            if hm[x, y] == 255:
                lo[x, y] = (*lp[x, y], 255)
            elif em[x, y] == 255:
                lr, lg, lb = lp[x, y]
                dist = (abs(pr - lr) + abs(pg - lg) + abs(pb - lb)) / 3.0
                a = min(255, int(round(dist * 2.4)))
                lo[x, y] = (0x14, 0x14, 0x17, a) if a > 0 else (0, 0, 0, 0)
            else:
                lo[x, y] = (0, 0, 0, 0)

            # Dark robot: keep robot silhouette + its crisp bright rim highlight right around the figure
            # (only within rim_zone, never darker-than-ground pixels) so system-dark shines seamlessly!
            dr, dg, db = dp[x, y]
            br, bg_, bb = dark_tile_rgb(x, y)
            if hm[x, y] == 255:
                do_[x, y] = (dr, dg, db, 255)
            elif rz[x, y] == 255:
                glow = max(dr - br, dg - bg_, db - bb, 0.0)
                if glow > 16.0:
                    ga = min(255, int(round((glow - 16.0) * 2.4)))
                    do_[x, y] = (220, 228, 240, ga)
                else:
                    do_[x, y] = (0, 0, 0, 0)
            else:
                do_[x, y] = (0, 0, 0, 0)

            # Tinted / Clear robot: white-shell inverted robot!
            tv = tp[x, y][0]
            if hm[x, y] == 255 or em[x, y] == 255:
                ta = int(round(smoothstep(0.04, 0.96, tv / 255.0) * 255))
                to[x, y] = (255, 255, 255, ta) if ta > 0 else (0, 0, 0, 0)
            else:
                to[x, y] = (0, 0, 0, 0)

    return {
        "robot-light.png": png_bytes(light_out),
        "robot-dark.png": png_bytes(dark_out),
        "robot-tinted.png": png_bytes(tinted_out),
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--artifacts", type=Path, default=None, help="Path to artifacts folder (optional)")
    args = ap.parse_args()

    repo = Path(__file__).resolve().parents[1]
    catalog = repo / "App/Resources/Assets.xcassets"
    alt_dir = repo / "App/Resources/AppIcons"
    alt_dir.mkdir(parents=True, exist_ok=True)

    artifacts = args.artifacts
    if artifacts is None and (repo / "artifacts").exists():
        artifacts = repo / "artifacts"

    # Every icon option in AppIconChoice.all:
    # (id, layer_name, light_fill, dark_fill, assets, light_key, dark_key, tinted_key, glass_on_tinted)
    specs = [
        (
            "AppIcon", "Halo", WARM_PAPER, SYSTEM_DARK,
            make_halo_assets(repo, artifacts),
            "halo-light.svg", "halo-dark.svg", "halo-dark.svg", True,
        ),
        (
            "AppIcon-Hermes", "Hermes", WARM_PAPER, SYSTEM_DARK,
            make_hermes_assets(catalog),
            "hermes-light.png", "hermes-dark.png", "hermes-tinted.png", False,
        ),
        (
            "AppIcon-Feather", "Feather", WARM_PAPER, SYSTEM_DARK,
            make_feather_assets(catalog),
            "feather-light.png", "feather-dark.png", "feather-dark.png", True,
        ),
        (
            "AppIcon-Pearl", "Original", WARM_PAPER, SYSTEM_DARK,
            make_pearl_assets(catalog),
            "pearl-light.png", "pearl-dark.png", "pearl-tinted.png", True,
        ),
        (
            "AppIcon-BlackWhite", "BlackWhite", WARM_PAPER, SYSTEM_DARK,
            make_blackwhite_assets(repo, artifacts),
            "blackwhite-light.svg", "blackwhite-dark.svg", "blackwhite-tinted.svg", True,
        ),
        (
            "AppIcon-Shapes", "Shapes", WARM_PAPER, SYSTEM_DARK,
            make_shapes_assets(catalog),
            "shapes-light.svg", "shapes-dark.svg", "shapes-tinted.svg", True,
        ),
        (
            "AppIcon-Matrix", "Matrix", WARM_PAPER, SYSTEM_DARK,
            make_matrix_assets(catalog),
            "matrix-light.png", "matrix-dark.png", "matrix-tinted.png", False,
        ),
        (
            "AppIcon-Robot", "Robot", WARM_PAPER, SYSTEM_DARK,
            make_robot_assets(catalog),
            "robot-light.png", "robot-dark.png", "robot-tinted.png", False,
        ),
        (
            "AppIcon-Flux", "Flux", COOL_MIST, COOL_SLATE,
            make_flux_assets(repo, artifacts),
            "flux-light.svg", "flux-dark.svg", "flux-tinted.svg", True,
        ),
        (
            "AppIcon-Afterimage", "Afterimage", COOL_MIST, COOL_SLATE,
            make_afterimage_assets(),
            "afterimage-light.svg", "afterimage-dark.svg", "afterimage-tinted.svg", True,
        ),
        (
            "AppIcon-ReplyCut", "ReplyCut", COOL_MIST, COOL_SLATE,
            make_replycut_assets(),
            "replycut-light.svg", "replycut-dark.svg", "replycut-tinted.svg", True,
        ),
        (
            "AppIcon-Turntaking", "Turntaking", COOL_MIST, COOL_SLATE,
            make_turntaking_assets(),
            "turntaking-light.svg", "turntaking-dark.svg", "turntaking-tinted.svg", True,
        ),
        (
            "AppIcon-Swoop", "Swoop", SWOOP_CREAM, SWOOP_DARK,
            make_swoop_assets(),
            "swoop-light.svg", "swoop-dark.svg", "swoop-tinted.svg", True,
        ),
        (
            "AppIcon-Silhouette", "Silhouette", WARM_PAPER, SYSTEM_DARK,
            make_silhouette_assets(repo, artifacts),
            "silhouette-light.svg", "silhouette-dark.svg", "silhouette-dark.svg", True,
        ),
    ]

    count = 0
    for icon_id, layer_name, lf, df, assets, lk, dk, tk, glass_tinted in specs:
        # 1. Automatic (System) bundle
        dest = (repo / "App/Resources/AppIcon.icon") if icon_id == "AppIcon" else (alt_dir / f"{icon_id}.icon")
        write_icon_bundle(dest, layer_name, lf, df, assets, lk, dk, tk, pin=None, glass_on_tinted=glass_tinted)
        count += 1
        # 2. Pinned Light & Dark bundles
        for pin in ("Light", "Dark"):
            pin_dest = alt_dir / f"{icon_id}-{pin}.icon"
            write_icon_bundle(pin_dest, layer_name, lf, df, assets, lk, dk, tk, pin=pin, glass_on_tinted=glass_tinted)
            count += 1
        print(f"ok: {icon_id} (+ Light, Dark)")

    print(f"Wrote {count} Icon Composer .icon bundles.")


if __name__ == "__main__":
    main()
