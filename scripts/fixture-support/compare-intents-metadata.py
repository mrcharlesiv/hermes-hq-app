#!/usr/bin/env python3
"""Compares a built app's App Intents metadata with build 240's (docs/spec/3x-intents.md §13 A1–A3).

A shortcut the owner made with build 240 names its action, its parameter and its entity by identifier; the system
finds them in `<App>.app/Metadata.appintents/extract.actionsdata`. This reads that file from a built app and from the
reference archive and fails on any difference that is not one of these, which do not change what a saved shortcut
resolves to:

  module name            the Swift module in `fullyQualifiedTypeName`, `fullyQualifiedIdentifier` and
                         `defaultQueryIdentifier` ("App." in build 240)
  mangled type names     `mangledTypeName*`, `autoShortcutProviderMangledName` (they carry the module and provider name)
  generator              the Xcode build that wrote the file
  opens-the-app fields   `openAppWhenRun`, `supportedModes` (two spellings of "the app comes forward")
  added phrases          this app may add App Shortcut phrases; every phrase of build 240 must still be there
  added actions          an action build 240 did not have, and its App Shortcut (DECISION I17: Open Bot Chat); every
                         action and App Shortcut of build 240 must still be there, unchanged

It also fails when the word "Dispatch" shows in anything the owner can see or hear (titles, descriptions, phrases,
type names shown in the Shortcuts app). Identifiers may keep it.

  python3 scripts/fixture-support/compare-intents-metadata.py build/dd/Build/Products/Debug-iphonesimulator/HermesHQNative.app
      [--ref /Users/me/Projects/hermes-hq-native-ref240-archive/Dispatch.xcarchive/Products/Applications/App.app]
Reads two files; contacts nothing. Exit 0 when they match.
"""
import argparse, json, pathlib, sys

REFERENCE = '/Users/me/Projects/hermes-hq-native-ref240-archive/Dispatch.xcarchive/Products/Applications/App.app'
MODULE_KEYS = {'fullyQualifiedTypeName', 'fullyQualifiedIdentifier', 'defaultQueryIdentifier'}
IGNORED = {'mangledTypeName', 'mangledTypeNameV2', 'mangledTypeNameByBundleIdentifier', 'mangledTypeNameByBundleIdentifierV2',
           'autoShortcutProviderMangledName', 'generator'}
OPENS = {'openAppWhenRun', 'supportedModes'}
# Where the owner reads or hears the text (the `key` of a localized string under one of these).
SHOWN = {'title', 'descriptionText', 'shortTitle', 'phraseTemplates', 'displayTypeName', 'numericFormatTypeName', 'actionSummary',
         'summaryString', 'parameterSummary', 'searchKeywords', 'categoryName', 'resultValueName', 'requestValueDialog'}


def load(path):
    path = pathlib.Path(path)
    if path.is_dir(): path = path / 'Metadata.appintents' / 'extract.actionsdata'
    if not path.is_file(): sys.exit(f'no App Intents metadata at {path}')
    return json.loads(path.read_text()), path


def without_module(value):
    return value.split('.', 1)[1] if isinstance(value, str) and '.' in value else value


def strings(node, shown=False):
    """Every string the owner can see: a `key` (or a plain string) anywhere under a SHOWN field."""
    if isinstance(node, dict):
        for key, value in node.items():
            if key == 'key' and shown and isinstance(value, str): yield value
            else: yield from strings(value, shown or key in SHOWN)
    elif isinstance(node, list):
        for value in node: yield from strings(value, shown)
    elif isinstance(node, str) and shown:
        yield node


def compare(ref, mine, path, problems, allowed):
    key = path[-1] if path else ''
    where = '/'.join(str(part) for part in path)
    if key in IGNORED: return
    if key in OPENS:
        if ref != mine: allowed.append(f'{where}: {ref!r} in build 240, {mine!r} here')
        return
    if key in MODULE_KEYS:
        if without_module(ref) != without_module(mine): problems.append(f'{where}: {ref!r} in build 240, {mine!r} here')
        elif ref != mine: allowed.append(f'{where}: module {str(ref).split(".")[0]!r} in build 240, {str(mine).split(".")[0]!r} here')
        return
    if key == 'phraseTemplates' and isinstance(ref, list) and isinstance(mine, list):
        theirs, ours = [p.get('key') for p in ref], [p.get('key') for p in mine]
        for phrase in theirs:
            if phrase not in ours: problems.append(f'{where}: the phrase {phrase!r} of build 240 is missing')
        for phrase in ours:
            if phrase not in theirs: allowed.append(f'{where}: added phrase {phrase!r}')
        return
    if key == 'autoShortcuts' and isinstance(ref, list) and isinstance(mine, list):
        # Matched by the action each one runs: build 240's must all be there; one for an added action is allowed.
        ours = {s.get('actionIdentifier'): s for s in mine}
        for index, shortcut in enumerate(ref):
            match = ours.pop(shortcut.get('actionIdentifier'), None)
            if match is None: problems.append(f"{where}: the App Shortcut for {shortcut.get('actionIdentifier')!r} of build 240 is missing")
            else: compare(shortcut, match, path + [index], problems, allowed)
        for name in ours: allowed.append(f'{where}: added App Shortcut for {name!r}')
        return
    if isinstance(ref, dict) and isinstance(mine, dict):
        for name in sorted(set(ref) | set(mine)):
            if name in IGNORED: continue
            if name not in mine:
                if name in OPENS: allowed.append(f'{where}/{name}: {ref[name]!r} in build 240, absent here')
                else: problems.append(f'{where}/{name}: in build 240 ({json.dumps(ref[name])[:120]}), missing here')
            elif name not in ref:
                if name in OPENS: allowed.append(f'{where}/{name}: absent in build 240, {mine[name]!r} here')
                elif path == ['actions']: allowed.append(f'{where}/{name}: added action')
                else: problems.append(f'{where}/{name}: not in build 240, here {json.dumps(mine[name])[:120]}')
            else:
                compare(ref[name], mine[name], path + [name], problems, allowed)
        return
    if isinstance(ref, list) and isinstance(mine, list):
        if len(ref) != len(mine):
            problems.append(f'{where}: {len(ref)} in build 240, {len(mine)} here')
            return
        for index, (a, b) in enumerate(zip(ref, mine)): compare(a, b, path + [index], problems, allowed)
        return
    if ref != mine: problems.append(f'{where}: {ref!r} in build 240, {mine!r} here')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('app', help='a built .app, or its extract.actionsdata')
    parser.add_argument('--ref', default=REFERENCE, help="build 240's .app, or its extract.actionsdata")
    parser.add_argument('--quiet', action='store_true', help='print only problems')
    args = parser.parse_args()
    ref, ref_path = load(args.ref)
    mine, mine_path = load(args.app)
    problems, allowed = [], []
    compare(ref, mine, [], problems, allowed)
    shown = sorted(set(strings(mine)))
    for text in shown:
        if 'dispatch' in text.lower(): problems.append(f'the owner would read "Dispatch" in {text!r}')
    if not args.quiet:
        print(f'build 240: {ref_path}')
        print(f'this app:  {mine_path}')
        actions = mine.get('actions', {})
        for name in sorted(actions):
            action = actions[name]
            parameters = ', '.join(f"{p.get('name')} ({(p.get('title') or {}).get('key')})" for p in action.get('parameters', []))
            listed = 'listed' if action.get('isDiscoverable') else 'hidden'
            print(f"  action {name}: “{(action.get('title') or {}).get('key')}”, {listed}, parameters: {parameters}")
        for name, entity in sorted(mine.get('entities', {}).items()):
            print(f"  entity {name}: “{(entity.get('displayTypeName') or {}).get('key')}”, query {without_module(entity.get('defaultQueryIdentifier'))}")
        for shortcut in mine.get('autoShortcuts', []):
            phrases = [p.get('key') for p in shortcut.get('phraseTemplates', [])]
            print(f"  App Shortcut for {shortcut.get('actionIdentifier')}: “{(shortcut.get('shortTitle') or {}).get('key')}”, "
                  f"{shortcut.get('systemImageName')}, phrases {phrases}")
        print(f'  what the owner can read: {shown}')
        print(f'allowed differences ({len(allowed)}):')
        for line in allowed: print('  ' + line)
    if problems:
        print(f'DIFFERENT from build 240 ({len(problems)}):')
        for line in problems: print('  ' + line)
        sys.exit(1)
    print('same as build 240 (apart from the allowed differences)')


if __name__ == '__main__':
    main()
