# Contributing to Hermes HQ

Thanks for helping. Bug reports, ideas and code are all welcome.

## Reporting a bug or asking for something

Open an issue. Say what you did, what you expected and what happened, and which device, app build and Hermes
version you're on. Screenshots help. Never paste passwords, tokens or your gateway's address.

## Pull requests

1. **Sign the CLA once.** The first time you open a pull request, a bot asks you to agree to the
   [Contributor License Agreement](CLA.md) by leaving a comment. You keep the copyright in your work; the CLA lets the
   project ship it, including in the official App Store app.
2. **Keep it focused.** One fix or feature per pull request. For anything big, open an issue first so we can agree on
   the approach before you spend time on it.
3. **Test it.** Run the unit tests on a freshly created simulator:
   ```sh
   scripts/build.sh test <simulator-id>
   ```
   Add tests for what you change. The stand-in gateways in `scripts/fixtures/` let the end-to-end tests run without a
   real Hermes.
4. **Follow the code around you.** Swift 6 with main-actor isolation by default; non-UI code goes in `HermesKit/`, UI
   in `App/`. `docs/ARCHITECTURE.md` explains the layout, and `docs/spec/` describes how the app talks to the gateway.
5. **Write for people.** The app's wording is short, plain and specific. Match it in anything a user will see.

## Privacy

This repository is public, so nothing personal goes into it: no real names, email addresses, phone numbers, chat
text, hosts or keys, in code, tests, comments, screenshots or commit messages. Use made-up stand-ins (`example.com`,
`/Users/me`, `tail1234`, 555-01xx numbers). A check runs on every pull request; run it yourself with
`python3 .github/scripts/leak_check.py`. If you spot personal information already here, report it privately (see
Security below) instead of quoting it in an issue.

## Security

If you find a security problem, don't open a public issue. Use GitHub's
[private vulnerability reporting](../../security/advisories/new) for this repository instead.

## Name and icons

Forks are welcome under the license, but a fork you publish must use its own name and icon.
See [TRADEMARKS.md](TRADEMARKS.md).
