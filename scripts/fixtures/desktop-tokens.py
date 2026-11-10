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
ORDER = ["nous", "github", "catppuccin", "everforest", "solarized", "rose-pine", "nous-alt", "midnight", "ember", "mono",
         "slate", "cyberpunk", "ios"]
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
            skins[name] = ({k: hexrgba(v) for k, v in light.items()}, {k: hexrgba(v) for k, v in dark.items()})
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
