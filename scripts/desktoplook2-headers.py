#!/usr/bin/env python3
"""desktoplook2: SwiftUI section headers take the desktop's label in the Desktop Look (tracked capitals,
phone-ui-desktop.css:149-151). Mechanical and idempotent, like scripts/desktoplook-migrate.py:

  Section("Words") { … }          ->  Section { … } header: { HQSectionLabel { Text("Words") } }
  } header: { … }                 ->  } header: { HQSectionLabel { … } }

`HQSectionLabel` (App/Theme/DesktopLayout.swift) returns its content unchanged with the look off.
  python3 scripts/desktoplook2-headers.py           rewrite App/
  python3 scripts/desktoplook2-headers.py --check   exit 1 if anything is left to rewrite
"""
import pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent / 'App'
SKIP = {'DesktopLayout.swift'}


def match_brace(s, i):
    """Index of the brace closing the one at s[i] (skips string literals)."""
    depth, j, n = 0, i, len(s)
    while j < n:
        c = s[j]
        if c == '"':
            if s.startswith('"""', j):
                k = s.find('"""', j + 3)
                j = k + 3
                continue
            j += 1
            while j < n and s[j] != '"':
                if s[j] == '\\':
                    if s[j + 1] == '(':      # interpolation: skip to its close paren
                        d, j = 1, j + 2
                        while d and j < n:
                            d += {'(': 1, ')': -1}.get(s[j], 0)
                            j += 1
                        continue
                    j += 2
                    continue
                j += 1
            j += 1
            continue
        if s.startswith('//', j):
            j = s.find('\n', j)
            continue
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                return j
        j += 1
    return -1


SECTION = re.compile(r'Section\(("(?:[^"\\]|\\.)*")\) \{')
HEADER = re.compile(r'\} header: \{(?! HQSectionLabel)')


def rewrite(s):
    changed = 0
    while True:
        m = SECTION.search(s)
        if not m:
            break
        open_at = m.end() - 1
        close = match_brace(s, open_at)
        if close < 0:
            break
        title = m.group(1)
        s = s[:close + 1] + f' header: {{ HQSectionLabel {{ Text({title}) }} }}' + s[close + 1:]
        s = s[:m.start()] + 'Section {' + s[m.end():]
        changed += 1
    pos = 0
    while True:
        m = HEADER.search(s, pos)
        if not m:
            break
        open_at = m.end() - 1
        close = match_brace(s, open_at)
        if close < 0:
            pos = m.end()
            continue
        s = s[:close] + '}' + (' ' if s[close - 1] != '\n' else '') + s[close:]
        s = s[:m.end()] + ' HQSectionLabel {' + s[m.end():]
        changed += 1
        pos = m.end()
    return s, changed


def main():
    check = '--check' in sys.argv
    total = 0
    for path in sorted(ROOT.rglob('*.swift')):
        if path.name in SKIP:
            continue
        text = path.read_text()
        new, n = rewrite(text)
        if n:
            total += n
            print(f'{path.relative_to(ROOT.parent)}: {n}')
            if not check:
                path.write_text(new)
    if check and total:
        sys.exit(1)
    print(f'{total} header(s) {"to rewrite" if check else "rewritten"}')


if __name__ == '__main__':
    main()
