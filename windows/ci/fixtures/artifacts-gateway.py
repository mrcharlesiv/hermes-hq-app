#!/usr/bin/env python3
"""Stand-in gateway for the Windows Artifacts page (windows/PARITY.md, Pages › Artifacts).

Stdlib only, 127.0.0.1 only, invented data only. It loads pages-fixture-gateway.py from this folder (a copy of
scripts/pages-fixture-gateway.py: sign-in, /api/ws, the sessions listing, transcripts, /api/fs/download and
/api/fs/read-data-url, the chats of docs/spec/1x-pages.md §9.3) and adds what scripts/fixtures/morepages/artifacts.py
adds for the More pages stream: a chat that names the same file and link several times (the "×N" badge) and Markdown
notes that link to each other (linked notes, 3x-morepages §3).

  python3 windows/ci/fixtures/artifacts-gateway.py --port 9820 --credentials build/fixtures/e2e-artifacts.json \
      --files build/fixtures/artifacts-files --tick-seconds 0

Ports are 9820-9829. The notes are served for sessions s-notes and s-notes-2 only; `missing.md` answers 404.
"""
import importlib.util, pathlib, sys
from urllib.parse import urlparse, parse_qs

HERE = pathlib.Path(__file__).resolve().parent

def asked(name):
    for index, word in enumerate(sys.argv):
        if word == name and index + 1 < len(sys.argv): return sys.argv[index + 1]
        if word.startswith(name + '='): return word.split('=', 1)[1]
    return None

if not asked('--port') or not 9820 <= int(asked('--port')) <= 9829:
    sys.exit('usage: artifacts-gateway.py --port <9820-9829> --credentials <file> --files <folder> [--tick-seconds 0]')

_spec = importlib.util.spec_from_file_location('hqw_artifacts_pages', HERE / 'pages-fixture-gateway.py')
pages = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(pages)

HOME = pages.HOME
NOTES_DIR = f'{HOME}/app/notes'
FILLER = '\n\n'.join(f'Paragraph {n}. The plan is reviewed every Monday and the notes below are kept short on purpose.' for n in range(1, 31))
NOTES = {
    f'{NOTES_DIR}/index.md': f"""# Project Notes

Start with [the plan](plan.md). There is a [README](../README.md) and [an absolute note](/home/hermes/abs.md).

Jump to [Usage](#usage). Here is [a missing note](missing.md) and [the site](https://example.com).

{FILLER}

## Usage

Read the plan first, then the README.
""",
    f'{NOTES_DIR}/plan.md': """# Plan

1. Draft the release notes.
2. Ship on Friday.

Back to [the index](index.md). See [how to use it](index.md#usage).
""",
    f'{HOME}/app/README.md': '# README\n\nThis folder holds the app. A note with a long name: [a very long note name](notes/a-very-long-note-name.md).\n',
    f'{NOTES_DIR}/a-very-long-note-name.md': '# A Long Name\n\nBack reads plain Back here. Go to [the plan](plan.md).\n',
    f'{HOME}/abs.md': '# Absolute\n\nReached by an absolute path.\n',
}
NOTE_SESSIONS = ('s-notes', 's-notes-2')


def seed_notes():
    base = pages.minute(pages.local(pages.T0)).timestamp()
    pages.add_session('s-notes', 'research', 'Project notes', [
        {'role': 'user', 'content': 'Write up the project notes.'},
        {'role': 'assistant', 'content': f'I wrote {NOTES_DIR}/index.md and {NOTES_DIR}/plan.md. Background: https://example.com/a'},
        {'role': 'user', 'content': 'Tighten the plan.'},
        {'role': 'assistant', 'content': f'Updated {NOTES_DIR}/plan.md with the dates. See https://example.com/a again.'},
        {'role': 'user', 'content': 'Once more.'},
        {'role': 'assistant', 'content': f'Done: {NOTES_DIR}/plan.md is final.'},
    ], base - 120)
    pages.add_session('s-notes-2', 'research', 'Plan follow-up', [
        {'role': 'user', 'content': 'Where is the plan?'},
        {'role': 'assistant', 'content': f'It is in {NOTES_DIR}/plan.md.'},
    ], base - 240)


_handler = pages.fx.handler
def handler(gateway):
    Base = _handler(gateway)
    class Handler(Base):
        def route(self, method, body):
            url = urlparse(self.path); query = parse_qs(url.query)
            one = lambda key: (query.get(key) or [''])[0]
            if method == 'GET' and url.path == '/api/fs/download' and one('session_id') in NOTE_SESSIONS:
                path = one('path')
                with pages.lock: pages.state['rest'].append({'method': method, 'path': url.path, 'query': {k: v[0] for k, v in query.items()}, 'body': None})
                if path in NOTES: return 200, ('text/markdown', NOTES[path].encode())
                if path.endswith('.md'): return 404, {'detail': 'File not found'}
            return super().route(method, body)
    return Handler
pages.fx.handler = handler

_reseed = pages.reseed
def reseed():
    _reseed()
    with pages.lock: seed_notes()
pages.reseed = reseed

if __name__ == '__main__':
    print('Artifacts fixture (pages fixture + linked notes)', flush=True)
    pages.main()
