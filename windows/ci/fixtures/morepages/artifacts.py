"""Artifacts for the morepages stream: a chat that names the same file and link several times (the "×N" badge, §2)
and notes that link to each other (§3).

Knobs: none. The notes are served for sessions s-notes and s-notes-2 only; `missing.md` answers 404.
"""
HOME = ctx.pages.HOME
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
SESSIONS = ('s-notes', 's-notes-2')


def seed():
    base = ctx.pages.minute(ctx.pages.local(ctx.pages.T0)).timestamp()
    ctx.pages.add_session('s-notes', 'research', 'Project notes', [
        {'role': 'user', 'content': 'Write up the project notes.'},
        {'role': 'assistant', 'content': f'I wrote {NOTES_DIR}/index.md and {NOTES_DIR}/plan.md. Background: https://example.com/a'},
        {'role': 'user', 'content': 'Tighten the plan.'},
        {'role': 'assistant', 'content': f'Updated {NOTES_DIR}/plan.md with the dates. See https://example.com/a again.'},
        {'role': 'user', 'content': 'Once more.'},
        {'role': 'assistant', 'content': f'Done: {NOTES_DIR}/plan.md is final.'},
    ], base - 120)
    ctx.pages.add_session('s-notes-2', 'research', 'Plan follow-up', [
        {'role': 'user', 'content': 'Where is the plan?'},
        {'role': 'assistant', 'content': f'It is in {NOTES_DIR}/plan.md.'},
    ], base - 240)


def rest(method, path, query, body, handler):
    if method != 'GET' or path != '/api/fs/download': return None
    if ctx.one(query, 'session_id') not in SESSIONS: return None
    asked = ctx.one(query, 'path')
    if asked in NOTES: return 200, ('text/markdown', NOTES[asked].encode())
    if asked.endswith('.md'): return 404, {'detail': 'File not found'}
    return None
