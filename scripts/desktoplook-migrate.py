#!/usr/bin/env python3
"""desktoplook: routes every font call in App/ through the theme's font factory (HQFont / Font.hq) and adds the theme
trait to the views that recolour by hand. Mechanical and idempotent: run it again after merging another stream
(python3 scripts/desktoplook-migrate.py), then build. With the Desktop Look off every rewritten call returns the very
font it replaced (App/Theme/ThemeFonts.swift), so nothing changes for the standard look.

  --check   change nothing; list the files that still hold a raw call and exit 1 (Tests/Theme/ThemeLintTests runs the
            same patterns).
  --colors  change nothing; list the lines that still draw in system ink instead of the theme's (see SYSTEM_INK) and
            exit 1 if any is left (--check and ThemeLintTests fail on them too, UX study #159).
"""
import os, re, sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "App")
SKIP = ("App/Theme/", "App/Kit/Accessibility/HQFont.swift")   # the font factory and its accessibility half
STYLES = "largeTitle|title3|title2|title|headline|subheadline|body|callout|footnote|caption2|caption"
RULES = [
    (re.compile(r"UIFont\.preferredFont\(forTextStyle:\s*"), "HQFont.preferred("),
    (re.compile(r"(?<![\w.)])\.preferredFont\(forTextStyle:\s*"), "HQFont.preferred("),
    (re.compile(r"(?<![\w.])UIFont\.systemFont\(ofSize:"), "HQFont.system(ofSize:"),
    (re.compile(r"(?<![\w.])UIFont\.monospacedSystemFont\(ofSize:"), "HQFont.mono(ofSize:"),
    (re.compile(r"(?<![\w.])UIFont\.monospacedDigitSystemFont\(ofSize:"), "HQFont.monoDigit(ofSize:"),
    (re.compile(r"(?<![\w.)])\.systemFont\(ofSize:"), "HQFont.system(ofSize:"),
    (re.compile(r"(?<![\w.)])\.monospacedSystemFont\(ofSize:"), "HQFont.mono(ofSize:"),
    (re.compile(r"(?<![\w.)])\.monospacedDigitSystemFont\(ofSize:"), "HQFont.monoDigit(ofSize:"),
    (re.compile(r"(?<!\w)\.font\(\.(%s)\b(?!\()" % STYLES), r".font(Font.hq(.\1)"),
    (re.compile(r"(?<!\w)\.font\(\.system\(size:"), ".font(Font.hqSystem(size:"),
    (re.compile(r"(?<!\w)\.font\(\.system\(\.(%s)\b" % STYLES), r".font(Font.hqSystem(.\1"),
    (re.compile(r"registerForTraitChanges\(\[UITraitUserInterfaceStyle\.self(?!, ThemeGenerationTrait\.self)"),
     "registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self"),
    # The page behind grouped lists follows the skin (HQPalette.groupedPage is the system colour in the standard look).
    (re.compile(r"Color\(uiColor:\s*\.systemGroupedBackground\)"), "Color.hqGroupedPage"),
    (re.compile(r"(?<![\w.])UIColor\.systemGroupedBackground\b"), "HQPalette.groupedPage"),
    (re.compile(r"(?<![\w.)])\.systemGroupedBackground\b"), "HQPalette.groupedPage"),
]

# A SwiftUI List / Form: `.hqGroupedPage()` goes right after its closing brace, unless the modifiers that follow
# already carry it (directly or through `.settingsList()`).
LIST_OPEN = re.compile(r"^(\s*)(?:return\s+)?(?:List|Form)\b(\([^{]*\))?\s*\{")
GROUPED = ".hqGroupedPage()"


def strip_code(line):
    """The line without string literals and a trailing comment, for brace counting."""
    line = re.sub(r'"(?:\\.|[^"\\])*"', '""', line)
    return line.split("//")[0]


def add_grouped_page(text):
    lines = text.split("\n")
    out, i = [], 0
    while i < len(lines):
        match = LIST_OPEN.match(lines[i])
        if not match or lines[i].lstrip().startswith("//"):
            out.append(lines[i]); i += 1
            continue
        depth, j = 0, i
        while j < len(lines):
            code = strip_code(lines[j])
            depth += code.count("{") - code.count("}")
            if depth <= 0:
                break
            j += 1
        if j >= len(lines):                      # unbalanced: leave the file alone
            out.extend(lines[i:]); break
        # the modifier chain after the closing brace
        k, chain = j + 1, strip_code(lines[j]).rsplit("}", 1)[-1]
        while k < len(lines) and (lines[k].strip().startswith(".") or lines[k].strip().startswith("//") or lines[k].strip().startswith("#")):
            chain += lines[k]; k += 1
        out.append(lines[i])
        inner = add_grouped_page("\n".join(lines[i + 1:j])) if j > i + 1 else None
        if inner is not None:
            out.extend(inner.split("\n"))
        if j > i:
            out.append(lines[j])
        if GROUPED not in chain and ".settingsList()" not in chain:
            out.append("%s%s   // [desktoplook] the page follows the skin" % (match.group(1), GROUPED))
        i = j + 1
    return "\n".join(out)



# --colors: system ink (.label, .secondaryLabel, .tertiaryLabel, SwiftUI .secondary) that stays iOS grey under a skin
# and in the Desktop Look; HQPalette / Color.hq* follow the theme and are the system values in the standard look. Not
# rewritten (each site wants a look: label-3 is for glyphs, words take label-2), only listed. A line that keeps system
# ink on purpose (UIKit text on system glass, which wants the vibrant colour) says so with "system-ink-ok".
SYSTEM_INK = re.compile(r"\.secondary\)|secondaryLabel|tertiaryLabel|= \.label\b")
SYSTEM_INK_OK = "system-ink-ok"
# A tuple handing back a tone (`return ("Active now", .secondary)`, BotListModel.Tone) is not a colour.
TONE = re.compile(r"return \(.*, \.secondary\)")


def system_ink():
    found = []
    for folder, _, names in os.walk(ROOT):
        for name in sorted(names):
            if not name.endswith(".swift"):
                continue
            path = os.path.join(folder, name)
            rel = os.path.relpath(path, os.path.join(ROOT, "..")).replace(os.sep, "/")
            if rel.startswith(SKIP):
                continue
            for number, line in enumerate(open(path).read().split("\n"), 1):
                code = line.split("//")[0]
                if SYSTEM_INK.search(code) and SYSTEM_INK_OK not in line and not TONE.search(code):
                    found.append("%s:%d: %s" % (rel, number, line.strip()))
    return sorted(found)


def list_system_ink():
    found = system_ink()
    for site in found:
        print("system ink:", site)
    print("%d sites" % len(found))
    sys.exit(1 if found else 0)


def main():
    if "--colors" in sys.argv:
        list_system_ink()
    check = "--check" in sys.argv
    left, changed = [], 0
    for folder, _, names in os.walk(ROOT):
        for name in names:
            if not name.endswith(".swift"):
                continue
            path = os.path.join(folder, name)
            rel = os.path.relpath(path, os.path.join(ROOT, "..")).replace(os.sep, "/")
            if rel.startswith(SKIP):
                continue
            text = open(path).read()
            new = text
            for pattern, replacement in RULES:
                new = pattern.sub(replacement, new)
            new = add_grouped_page(new)
            if new != text:
                if check:
                    left.append(rel)
                else:
                    open(path, "w").write(new)
                    changed += 1
    if check:
        for rel in sorted(left):
            print("raw font or trait call left in", rel)
        ink = system_ink()   # UX study #159: theme ink, or a "system-ink-ok" marker saying why not
        for site in ink:
            print("system ink:", site)
        sys.exit(1 if left or ink else 0)
    print("rewrote %d files" % changed)


if __name__ == "__main__":
    main()
