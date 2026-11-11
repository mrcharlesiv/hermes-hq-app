# Hermes HQ: rules for AI coding agents

This repository is public. `AGENTS.md` points here.

## No personal information, ever

Nothing that identifies a real person, account or machine goes into code, tests, fixtures, comments, docs, commit
messages, issues or pull requests.

- No real names, email addresses, phone numbers, street or place names, employers or clients.
- No text copied from a real chat, memo, inbox, calendar, log or screenshot. Reword it and invent the details.
- No real hosts, IP addresses, tailnet names, session ids, bot or profile names.
- No keys, tokens or passwords, including expired ones.
- Credit requests as "a tester" or "the maintainer", never by name or handle.

Use stand-ins: `example.com`, `/Users/me`, `tail1234`, 555-01xx phone numbers, and the demo bots already in the
fixtures (Otto, Herald, Ivy, Wren, Juno). Screenshots show demo data only. Check new images, audio and PDFs by eye,
including their metadata: the automatic check reads text only.

Before you commit, run:

```sh
python3 .github/scripts/leak_check.py
```

It also runs on every push and pull request. If a line is a deliberate made-up example that the check flags, add
`leak-check: ok` to it. Never use that marker to wave through something real.

If you find personal information already in the repository, don't quote it in a public issue. Report it through
GitHub's private vulnerability reporting.

## Code

See `CONTRIBUTING.md` and `docs/ARCHITECTURE.md`.
