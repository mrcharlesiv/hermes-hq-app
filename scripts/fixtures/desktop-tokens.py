#!/usr/bin/env python3
"""desktoplook: reads the web app's skin palettes (read only) and writes HermesKit/Theme/SkinSeeds.generated.swift.

Usage: python3 scripts/fixtures/desktop-tokens.py [--ref /Users/me/Projects/hermes-hq-native-ref240] [--check]
  --check  writes nothing; exits 1 when the committed Swift file differs from what the reference gives (a typo guard).
Sources: vendor/hermes/apps/shared/src/theme-presets.ts (11 desktop skins), src/ui-kit/ios-theme.ts (iOS System) and
APP_ONLY below (skins the desktop doesn't have).
"""
import argparse, os, re, sys

KEYS = ["background", "foreground", "card", "muted", "mutedForeground", "popover", "primary", "secondary", "accent",
        "border", "input", "ring", "midground", "composerRing", "destructive", "sidebarBackground", "sidebarBorder",
        "userBubble", "userBubbleBorder"]
ORDER = ["nous", "paper", "github", "catppuccin", "everforest", "solarized", "rose-pine", "nous-alt",
         "codex", "notion", "vercel",
         "midnight", "ember", "mono", "slate", "cyberpunk", "night-owl", "lobster", "ios"]
CONSTS = {"NOUS_ALT_BLUE": "#0053FD", "NOUS_ALT_NAVY": "#1540B1", "NOUS_ALT_CREAM": "#FFE6CB"}

# Skins the desktop doesn't ship, in its slots. Rosé Pine (owner 2026-11-01): Dawn light, Main dark, from
# rosepinetheme.com/en/palette and its usage notes: base for the page and sidebars, surface for cards, popups and
# fields, overlay for hovered rows, highlight low/med/high for row tints, selection and borders, subtle for secondary
# text, love for errors. Iris is the accent and your message's box a soft iris (the owner's mockup, 2026-11-02),
# with the theme's own text on it; the iOS look's paint is HermesKit/Theme/SkinOwnLooks.swift.
APP_ONLY = {
    "rose-pine": (
        {"background": "#faf4ed", "foreground": "#464261", "card": "#fffaf3", "muted": "#f4ede8",
         "mutedForeground": "#797593", "popover": "#fffaf3", "primary": "#907aa9", "secondary": "#dfdad9",
         "accent": "#f2e9e1", "border": "#cecacd", "input": "#fffaf3", "ring": "#907aa9", "midground": "#907aa9",
         "composerRing": "#907aa9", "destructive": "#b4637a", "sidebarBackground": "#faf4ed",
         "sidebarBorder": "#cecacd", "userBubble": "#eadcef", "userBubbleBorder": "#cecacd"},
        {"background": "#191724", "foreground": "#e0def4", "card": "#1f1d2e", "muted": "#21202e",
         "mutedForeground": "#908caa", "popover": "#1f1d2e", "primary": "#c4a7e7", "secondary": "#403d52",
         "accent": "#26233a", "border": "#524f67", "input": "#1f1d2e", "ring": "#c4a7e7", "midground": "#c4a7e7",
         "composerRing": "#c4a7e7", "destructive": "#eb6f92", "sidebarBackground": "#191724",
         "sidebarBorder": "#524f67", "userBubble": "#4d3357", "userBubbleBorder": "#524f67"},
    ),
    # Paper (owner 2026-11-16, "Claude Code uses a very light background color"): Claude's warm ivory page (#F8F9F3,
    # sampled from the owner's screenshots, drawer #F2F3EE, selected row #E4E5DD); in dark, black with warm greys (owner's pick over Claude's #262624).
    # No colour anywhere (owner 2026-11-16, "you can really improve that"): Claude's near-black #222 pill is the accent
    # (its ivory in dark), its warm near-black text (#0A0B06 measured) and warm grey #494947 secondary words. The iOS
    # look's paint is HermesKit/Theme/SkinOwnLooks.swift.
    "paper": (
        {"background": "#f8f9f3", "foreground": "#141410", "card": "#fdfdfa", "muted": "#f2f3ee",
         "mutedForeground": "#4a4a47", "popover": "#fdfdfa", "primary": "#22221f", "secondary": "#e4e5dd",
         "accent": "#ecede6", "border": "#dcddd3", "input": "#fdfdfa", "ring": "#22221f", "midground": "#22221f",
         "composerRing": "#22221f", "destructive": "#cf222e", "sidebarBackground": "#f2f3ee",
         "sidebarBorder": "#dcddd3", "userBubble": "#e9eae2", "userBubbleBorder": "#dcddd3"},
        {"background": "#000000", "foreground": "#f5f4ee", "card": "#161615", "muted": "#121211",
         "mutedForeground": "#b7b5ac", "popover": "#161615", "primary": "#edece6", "secondary": "#1e1e1c",
         "accent": "#1a1a19", "border": "#2e2e2b", "input": "#0e0e0d", "ring": "#edece6", "midground": "#edece6",
         "composerRing": "#edece6", "destructive": "#f85149", "sidebarBackground": "#0e0e0d",
         "sidebarBorder": "#2e2e2b", "userBubble": "#242422", "userBubbleBorder": "#33332f"},
    ),
    # Synara-sourced app-only themes (owner 2026-11-26): Codex, Notion, Vercel (Adaptive) + Night Owl, Lobster (Dark Only).
    "codex": (
        {"background": "#ffffff", "foreground": "#0d0d0d", "card": "#f7f7f8", "muted": "#f3f3f5",
         "mutedForeground": "#636369", "popover": "#ffffff", "primary": "#0169cc", "secondary": "#e3effb",
         "accent": "#e9f2fc", "border": "#e2e2e6", "input": "#ffffff", "ring": "#0169cc", "midground": "#0169cc",
         "composerRing": "#0169cc", "destructive": "#e02e2a", "sidebarBackground": "#f5f5f7",
         "sidebarBorder": "#e2e2e6", "userBubble": "#dcebfa", "userBubbleBorder": "#c4ddf7"},
        {"background": "#111111", "foreground": "#fcfcfc", "card": "#191919", "muted": "#1e1e20",
         "mutedForeground": "#8e8e93", "popover": "#1c1c1e", "primary": "#0169cc", "secondary": "#152940",
         "accent": "#132438", "border": "#2e2e32", "input": "#141416", "ring": "#0169cc", "midground": "#0169cc",
         "composerRing": "#0169cc", "destructive": "#e02e2a", "sidebarBackground": "#0b0b0c",
         "sidebarBorder": "#2a2a2e", "userBubble": "#10243b", "userBubbleBorder": "#234266"},
    ),
    "notion": (
        {"background": "#ffffff", "foreground": "#37352f", "card": "#f7f6f3", "muted": "#f1f0ec",
         "mutedForeground": "#787774", "popover": "#ffffff", "primary": "#3183d8", "secondary": "#e7f1fb",
         "accent": "#edf4fc", "border": "#e3e2df", "input": "#ffffff", "ring": "#3183d8", "midground": "#3183d8",
         "composerRing": "#3183d8", "destructive": "#a31515", "sidebarBackground": "#f7f6f3",
         "sidebarBorder": "#e3e2df", "userBubble": "#e5f0fa", "userBubbleBorder": "#c9dfee"},
        {"background": "#191919", "foreground": "#d9d9d8", "card": "#202020", "muted": "#262626",
         "mutedForeground": "#9b9a97", "popover": "#252525", "primary": "#3183d8", "secondary": "#1e3247",
         "accent": "#1b2c3d", "border": "#333333", "input": "#1e1e1e", "ring": "#3183d8", "midground": "#3183d8",
         "composerRing": "#3183d8", "destructive": "#fa423e", "sidebarBackground": "#202020",
         "sidebarBorder": "#2f2f2f", "userBubble": "#1d3044", "userBubbleBorder": "#2e4b69"},
    ),
    "vercel": (
        {"background": "#ffffff", "foreground": "#171717", "card": "#f4f4f5", "muted": "#f5f5f5",
         "mutedForeground": "#666666", "popover": "#ffffff", "primary": "#006aff", "secondary": "#e6f0ff",
         "accent": "#edf4ff", "border": "#eaeaea", "input": "#ffffff", "ring": "#006aff", "midground": "#006aff",
         "composerRing": "#006aff", "destructive": "#eb001d", "sidebarBackground": "#f5f5f6",
         "sidebarBorder": "#eaeaea", "userBubble": "#e5f0ff", "userBubbleBorder": "#bfd8ff"},
        {"background": "#000000", "foreground": "#ededed", "card": "#141414", "muted": "#161616",
         "mutedForeground": "#888888", "popover": "#111111", "primary": "#006efe", "secondary": "#0f2340",
         "accent": "#0d1e38", "border": "#262626", "input": "#0a0a0a", "ring": "#006efe", "midground": "#006efe",
         "composerRing": "#006efe", "destructive": "#f13342", "sidebarBackground": "#0a0a0a",
         "sidebarBorder": "#222222", "userBubble": "#0b1f3a", "userBubbleBorder": "#1d3e6e"},
    ),
    "night-owl": (
        {"background": "#011627", "foreground": "#d6deeb", "card": "#0b253a", "muted": "#0d2940",
         "mutedForeground": "#7e97ac", "popover": "#0b253a", "primary": "#d6deeb", "secondary": "#15344e",
         "accent": "#122d45", "border": "#1d3b53", "input": "#0b253a", "ring": "#44596b", "midground": "#44596b",
         "destructive": "#ef5350", "sidebarBackground": "#01111d", "sidebarBorder": "#163047",
         "userBubble": "#13314a", "userBubbleBorder": "#234968"},
        None,
    ),
    "lobster": (
        {"background": "#111827", "foreground": "#e4e4e7", "card": "#1a2336", "muted": "#1f293d",
         "mutedForeground": "#94a3b8", "popover": "#1d273b", "primary": "#e4e4e7", "secondary": "#28354e",
         "accent": "#222f47", "border": "#2d3b55", "input": "#1a2336", "ring": "#ff5c5c", "midground": "#ff5c5c",
         "destructive": "#ff5c5c", "sidebarBackground": "#0b101b", "sidebarBorder": "#233048",
         "userBubble": "#2a1e2b", "userBubbleBorder": "#5c2b36"},
        None,
    ),
}


def hexrgba(h):
    h = h.lstrip("#")
    if len(h) == 3:
        h = "".join(c * 2 for c in h)
    return [int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16), 1.0]


def value(raw):
    raw = raw.strip().rstrip(",").strip()
    if raw in CONSTS:
        return hexrgba(CONSTS[raw])
    m = re.match(r"nousAltTint\((\d+)\)", raw)
    if m:  # color-mix(in srgb, BLUE p%, #FFFFFF)
        p = int(m.group(1)) / 100
        b = hexrgba(CONSTS["NOUS_ALT_BLUE"])
        return [b[i] * p + 255 * (1 - p) for i in range(3)] + [1.0]
    m = re.match(r"nousAltTintTransparent\((\d+)\)", raw)
    if m:  # color-mix(in srgb, BLUE p%, transparent) = BLUE at p alpha
        return hexrgba(CONSTS["NOUS_ALT_BLUE"])[:3] + [int(m.group(1)) / 100]
    m = re.match(r"['\"](#[0-9a-fA-F]{3,6})['\"]", raw)
    if m:
        return hexrgba(m.group(1))
    raise SystemExit(f"cannot read colour value: {raw!r}")


def block(text, start):
    """The {...} body that opens at or after `start`."""
    i = text.index("{", start)
    depth, j = 0, i
    while True:
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[i + 1:j], j
        j += 1


def colours(body):
    out = {}
    for m in re.finditer(r"(\w+):\s*([^,\n]+(?:\([^)]*\))?)", body):
        if m.group(1) in KEYS:
            out[m.group(1)] = value(m.group(2))
    return out


def read(ref):
    presets = open(os.path.join(ref, "vendor/hermes/apps/shared/src/theme-presets.ts")).read()
    table = presets[presets.index("THEME_PRESET_PALETTES"):]
    skins = {}
    for name in ORDER[:-1]:
        if name in APP_ONLY:
            light, dark = APP_ONLY[name]
            skins[name] = ({k: hexrgba(v) for k, v in light.items()}, {k: hexrgba(v) for k, v in dark.items()} if dark else None)
            continue
        m = re.search(r"\n  '?%s'?: \{" % re.escape(name), table)
        body, _ = block(table, m.start())
        light, end = block(body, body.index("colors:"))
        dark = None
        if "darkColors:" in body:
            dark, _ = block(body, body.index("darkColors:"))
        skins[name] = (colours(light), colours(dark) if dark else None)
    ios = open(os.path.join(ref, "src/ui-kit/ios-theme.ts")).read()
    light, _ = block(ios, ios.index("  colors:"))
    dark, _ = block(ios, ios.index("  darkColors:"))
    skins["ios"] = (colours(light), colours(dark))
    return skins


def swift(c):
    def one(k):
        v = c.get(k)
        if v is None:
            return "nil"
        return "RGBA(%s, %s, %s, %s)" % (fmt(v[0]), fmt(v[1]), fmt(v[2]), fmt(v[3]))
    return "SkinSeeds(" + ", ".join("%s: %s" % (k, one(k)) for k in KEYS) + ")"


def fmt(x):
    s = ("%.4f" % x).rstrip("0").rstrip(".")
    return s


def render(skins):
    lines = ["// GENERATED by scripts/fixtures/desktop-tokens.py from the web app's theme-presets.ts and ios-theme.ts, and the",
             "// script's own table of skins the desktop doesn't have (Rosé Pine).",
             "// Do not edit by hand: change the script or the reference and run it again.", "",
             "nonisolated extension SkinCatalog {",
             "    /// (light or only palette, hand-tuned dark palette) by skin id. Channels 0…255, alpha 0…1.",
             "    static let seeds: [String: (light: SkinSeeds, dark: SkinSeeds?)] = ["]
    for name in ORDER:
        light, dark = skins[name]
        lines.append('        "%s": (' % name)
        lines.append("            light: %s," % swift(light))
        lines.append("            dark: %s" % (swift(dark) if dark else "nil"))
        lines.append("        ),")
    lines += ["    ]", "}", ""]
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ref", default="/Users/me/Projects/hermes-hq-native-ref240")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    out = os.path.join(os.path.dirname(__file__), "../../HermesKit/Theme/SkinSeeds.generated.swift")
    text = render(read(a.ref))
    if a.check:
        same = os.path.exists(out) and open(out).read() == text
        print("seeds match the reference" if same else "seeds DIFFER from the reference")
        sys.exit(0 if same else 1)
    open(out, "w").write(text)
    print("wrote", os.path.normpath(out))


if __name__ == "__main__":
    main()
