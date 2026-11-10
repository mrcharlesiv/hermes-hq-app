#!/usr/bin/env python3
"""Writes App/Resources/Licenses/licenses.json: the notices of everything that ships inside the app
(docs/spec/3x-morepages.md §7), so Settings › About › Open-Source Licenses cannot fall behind.

  python3 scripts/licenses.py            regenerate (needs the Swift packages checked out: build once first)
  python3 scripts/licenses.py --check    exit 1 when the committed JSON does not match Package.resolved

Sources:
  HermesHQNative.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved   every resolved Swift package
  build/dd/SourcePackages/checkouts/<package>/{LICENSE*,COPYING*,NOTICE*}              its own notice files, joined
  App/Resources/Licenses/extra.json   {"packages": {"<identity>": {"license": "<SPDX>"}},
                                       "extra": [{"name", "version", "license", "text"}]}   what ships another way
Output: [{"name","version","license","text"}], Hermes first, then by name. A package whose checkout is missing keeps
the text already in licenses.json when its version is unchanged; otherwise the script stops.
"""
import json, pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
RESOLVED = ROOT / 'HermesHQNative.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
FOLDER = ROOT / 'App/Resources/Licenses'
OUT = FOLDER / 'licenses.json'
EXTRA = FOLDER / 'extra.json'
CHECKOUTS = [ROOT / 'build/dd/SourcePackages/checkouts']
FIRST = 'Hermes Agent (Nous Research)'
NOTICE = re.compile(r'^(LICEN[CS]E|COPYING|NOTICE)([.\-_].*)?$', re.I)


def guess(text):
    head = text[:4000]
    if 'Apache License' in head: return 'Apache-2.0'
    if 'MIT License' in head or 'Permission is hereby granted, free of charge' in head: return 'MIT'
    if 'ISC License' in head: return 'ISC'
    if 'Redistribution and use in source and binary forms' in head: return 'BSD'
    return ''


def notice_text(identity):
    for base in CHECKOUTS:
        folder = base / identity
        if not folder.is_dir(): continue
        files = sorted(p for p in folder.iterdir() if p.is_file() and NOTICE.match(p.name))
        if files: return '\n\n'.join(p.read_text(errors='replace').strip() for p in files)
    return None


def pins():
    return [(p['identity'], p['state'].get('version') or p['state'].get('revision', '')[:12]) for p in json.loads(RESOLVED.read_text())['pins']]


def build():
    extra = json.loads(EXTRA.read_text())
    kept = {e['name']: e for e in json.loads(OUT.read_text())} if OUT.exists() else {}
    entries = []
    for identity, version in pins():
        text = notice_text(identity)
        if text is None:
            old = kept.get(identity)
            if not old or old.get('version') != version:
                sys.exit(f'{identity} {version}: no checkout under build/dd/SourcePackages/checkouts (build the app once, then run again)')
            text = old['text']
        license_name = extra.get('packages', {}).get(identity, {}).get('license') or guess(text)
        entries.append({'name': identity, 'version': version, 'license': license_name, 'text': text})
    for item in extra.get('extra', []):
        entries.append({'name': item['name'], 'version': item.get('version', ''), 'license': item.get('license', ''), 'text': item['text'].strip()})
    entries.sort(key=lambda e: (e['name'] != FIRST, e['name'].lower()))
    return entries


def check():
    have = {e['name']: e for e in json.loads(OUT.read_text())}
    bad = [f'{identity} {version}' for identity, version in pins() if have.get(identity, {}).get('version') != version]
    bad += [e['name'] + ' (no text)' for e in have.values() if not e.get('text', '').strip()]
    if bad: sys.exit('licenses.json is out of date: ' + ', '.join(bad) + ' (run scripts/licenses.py)')
    print(f'licenses.json: {len(have)} entries, in step with Package.resolved')


if __name__ == '__main__':
    if '--check' in sys.argv: check()
    else:
        entries = build()
        OUT.write_text(json.dumps(entries, indent=1, ensure_ascii=False) + '\n')
        print(f'wrote {OUT.relative_to(ROOT)}: ' + ', '.join(f"{e['name']} {e['version']}".strip() for e in entries))
