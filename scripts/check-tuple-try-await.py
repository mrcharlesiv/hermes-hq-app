#!/usr/bin/env python3
"""Fails when app code builds a tuple around a `try await` that follows a comma, e.g.

    do { return (key, .success(try await load(row))) } catch { return (key, .failure(error)) }

Swift 6.4 at -O can lose the tuple's earlier parts there (garbage, or the whole answer reads as nil); Debug builds
are fine, so tests don't catch it. Build 569's Artifacts index kept one chat per pass and read all 369 again on every
visit; Spawn Tree lost every bot's answer. Bind first instead:

    let outcome = await Result.of { try await load(row) }   // HermesKit/Net/ChildTasks.swift
    return (key, outcome)

Usage: scripts/check-tuple-try-await.py [files…]   (default: every tracked .swift outside Tests/ and UITests/)
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
KEYWORDS = {'return', 'in', 'try', 'await', 'case', 'yield', 'throw', 'let', 'var', 'else'}


def code_only(src):
    """`src` with comments and string contents blanked (same length, newlines kept)."""
    out, i, n = list(src), 0, len(src)
    def blank(a, b):
        for k in range(a, b):
            if out[k] != '\n': out[k] = ' '
    while i < n:
        if src.startswith('//', i):
            j = src.find('\n', i); j = n if j < 0 else j
            blank(i, j); i = j
        elif src.startswith('/*', i):
            j = src.find('*/', i + 2); j = n if j < 0 else j + 2
            blank(i, j); i = j
        elif src.startswith('"""', i):
            j = src.find('"""', i + 3); j = n if j < 0 else j + 3
            blank(i + 3, j - 3); i = j
        elif src[i] == '"':
            j = i + 1
            while j < n and src[j] not in '"\n':
                j += 2 if src[j] == '\\' else 1
            blank(i + 1, j); i = j + 1
        else:
            i += 1
    return ''.join(out)


def sites(path):
    src = code_only(path.read_text())
    for m in re.finditer(r'\btry\s+await\b', src):
        j = m.start() - 1
        while True:
            depth, comma = 0, False
            while j >= 0:
                c = src[j]
                if c in ')]}': depth += 1
                elif c in '([{':
                    if depth == 0: break
                    depth -= 1
                elif c == ',' and depth == 0: comma = True
                j -= 1
            if j < 0 or src[j] != '(':
                break
            k = j - 1
            while k >= 0 and src[k] in ' \t\n': k -= 1
            word = re.search(r'([A-Za-z_][A-Za-z0-9_]*)\s*$', src[:k + 1])
            call = k >= 0 and re.match(r'[A-Za-z0-9_)\]?!>]', src[k]) and not (word and word.group(1) in KEYWORDS)
            if not call and comma:
                yield src.count('\n', 0, m.start()) + 1
                break
            j -= 1


def main():
    if len(sys.argv) > 1:
        files = [Path(f) for f in sys.argv[1:]]
    else:
        listed = subprocess.run(['git', 'ls-files', '*.swift'], cwd=ROOT, capture_output=True, text=True, check=True).stdout
        files = [ROOT / f for f in listed.split() if not f.startswith(('Tests/', 'UITests/'))]
    found = [(f, line) for f in files for line in sites(f)]
    for f, line in found:
        text = f.read_text().splitlines()[line - 1].strip()
        name = f.relative_to(ROOT) if f.is_relative_to(ROOT) else f
        print(f"{name}:{line}: tuple around `try await` after a comma: {text[:120]}")
    if found:
        print(f"{len(found)} site(s): bind the outcome first (`let outcome = await Result.of {{ … }}`), then return the tuple.")
    return 1 if found else 0


if __name__ == '__main__':
    sys.exit(main())
