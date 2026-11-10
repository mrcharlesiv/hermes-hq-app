#!/usr/bin/env python3
"""Fails when a change adds something that looks private: keys, real email addresses, home folders, tailnet names,
or phone numbers outside the 555-01xx range.

  python3 .github/scripts/leak_check.py [BASE_REF]

With BASE_REF only the lines a change adds are read; without it, every tracked file. Stdlib only.
To keep a line that is a deliberate example, add `leak-check: ok` to it.
"""
import re, subprocess, sys

PATTERNS = {
    'API key or token': re.compile(r'\b(?:sk-(?:ant-|proj-)?[A-Za-z0-9_-]{32,}|gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{40,}|'
                                   r'AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|xox[abprs]-[A-Za-z0-9-]{20,}|tskey-[A-Za-z0-9-]{20,})'),
    'private key': re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----\n[A-Za-z0-9+/]{60,}'),
    'email address': re.compile(r'\b[A-Za-z0-9._%+-]+@(?!example\.|[a-z0-9.-]*\.(?:test|invalid|example)\b|users\.noreply\.github\.com)'
                                r'(?:gmail|icloud|me|mac|outlook|hotmail|yahoo|proton(?:mail)?)\.(?:com|me)\b', re.I),
    'home folder': re.compile(r'/Users/(?!(?:me|you|x|a|demo|fixture|owner|someone|example|ivy|sam|bots|runner|Shared)\b)[a-z][a-z0-9._-]{2,}/'),
    'tailnet name': re.compile(r'\.tail(?!1234\b)[0-9a-f]{4,}\.ts\.net', re.I),
    'phone number': re.compile(r'(?<!\d)\(?\d{3}\)?[ .-](?!555[ .-]01\d\d)\d{3}[ .-]\d{4}(?!\d)'),
}
OK = 'leak-check: ok'
SKIP = re.compile(r'^(Vendor/|App/Resources/Licenses/|App/Resources/PluginHost/tailwind|.*\.(png|jpg|heic|gif|pdf|zip|m4a|ttf|rfb|bgrx|svg)$)')
FAKE = re.compile(r'0123456789|abcdef|FAKE|EXAMPLE|sk-learn')


def added_lines(base):
    diff = subprocess.run(['git', 'diff', '--unified=0', f'{base}...HEAD'], capture_output=True, text=True, check=True).stdout
    path, line = None, 0
    for row in diff.splitlines():
        if row.startswith('+++ '): path = row[6:] if row.startswith('+++ b/') else None
        elif row.startswith('@@'): line = int(re.search(r'\+(\d+)', row).group(1))
        elif row.startswith('+') and path:
            yield path, line, row[1:]; line += 1


def all_lines():
    for path in subprocess.run(['git', 'ls-files'], capture_output=True, text=True, check=True).stdout.splitlines():
        try: text = open(path, encoding='utf-8').read()
        except (UnicodeDecodeError, OSError): continue
        for n, row in enumerate(text.splitlines(), 1): yield path, n, row


def main():
    rows = added_lines(sys.argv[1]) if len(sys.argv) > 1 else all_lines()
    found = []
    for path, n, row in rows:
        if SKIP.match(path) or OK in row: continue
        for what, pattern in PATTERNS.items():
            if what == 'API key or token' and FAKE.search(row): continue
            if pattern.search(row): found.append(f'{path}:{n}: {what}: {row.strip()[:140]}')
    if found:
        print(f'{len(found)} line(s) look private. Use a made-up stand-in (example.com, /Users/me, tail1234, 555-01xx),',
              f'or add "{OK}" to a line that is a deliberate example:', *found, sep='\n  ')
        sys.exit(1)
    print('No private-looking lines.')


if __name__ == '__main__':
    main()
