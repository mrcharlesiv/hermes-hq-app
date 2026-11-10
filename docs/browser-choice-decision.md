# Each bot's browser: what we decided (Oct 11)

Owner asked: every bot keeps a browser of its own, can use one of your own Chrome profiles if you want, works the way
desktop Hermes does, and gets fewer "are you human?" walls.

## What you get

In the app, **Bot Info › Browser** for each bot:

- **Profile**
  - **Its Own** (default, today's behaviour): the bot's own Chrome profile. It is signed in to whatever the bot signed
    in to. Nothing changes for bots you don't touch.
  - **Copy of My Chrome Profile** › pick one of your Chrome profiles (Personal, Work…). The bot's Chrome gets a copy of
    that profile: your sign-ins, cookies, history and settings, so sites open already signed in and the browser looks
    like a real person's. **Refresh Sign-ins from My Chrome** copies it again later (say, after you signed in to a new
    site on your Mac). Switching back to **Its Own** puts the bot's own profile back and deletes the copy.
- **Show as Normal Chrome** (off by default): the bot's Chrome runs as an ordinary Chrome window on the Mac instead of a
  hidden ("headless") one.

## Why a copy, not your real profile

- Chrome (since version 136) refuses to be remote-controlled on your everyday profile folder, and two Chromes can't
  open the same profile at once. So a bot can't drive your real profile while you use it. A copy can: your Chrome is
  never opened or changed.
- Desktop Hermes does the same thing ("Use My Real Browser Profile", `browser.use_real_profile`): it copies your
  default browser's profile. We use the same idea but keep the copy in the bot's own browser, because Hermes' version
  only works with your *default* browser, runs hidden, closes at the end of every reply (nothing to watch or take over
  between replies), and is overridden by the per-bot browser our plugin gives each bot.
- Two bots can use the same Chrome profile: each gets its own copy, so they never fight over it.

What to expect from a copy:

- **Carries over:** cookies (most sign-ins), history, bookmarks, site settings. On a Mac the copy stays readable
  because it's the same Chrome app run by the same Mac user (Chrome's "Safe Storage" key in your Keychain).
- **Never copied:** your saved passwords, payment cards and addresses (the bot's Chrome keeps its password manager
  off; bots sign in through Hermes' vault), and your extensions and their data (the copy runs with extensions off).
- **Doesn't carry over or may need redoing:** passkeys (they live in iCloud Keychain / your phone, not the profile),
  sites that tie a sign-in to one device may ask again, and Chrome Sync is off in the bot's copy (otherwise the bot's
  browsing would show up in your Google account's history and tabs).
- **If Chrome is busy:** Chrome keeps some of its files locked while it runs; the copy then falls back to a raw copy
  that SQLite repairs. If your sign-ins still can't be copied, nothing changes and the phone says to quit Chrome on
  the Mac and try again. A copy that fails never touches the bot's own profile.
- **It's a snapshot:** sign-ins you do later on the Mac reach the bot only after **Refresh Sign-ins**. Things the bot
  signs in to stay in the bot's copy; they never come back to your Chrome.
- **It's you:** a bot on a copy of your profile is signed in as you (email, shopping, banking if you're signed in
  there). Only pick a profile you're happy for that bot to act in.

## Fewer "are you human?" walls

The main cause is not the profile alone: it is the **hidden (headless) Chrome** plus a **brand-new, empty profile**.
Headless Chrome announces itself (its "HeadlessChrome" browser brand in what it sends sites, no real window, no
graphics card), which is exactly what Cloudflare-style checks look for.

- **Show as Normal Chrome** removes that: it's a plain Chrome window, nothing faked, no "automation" flags. It is
  the bot's own Chrome instance (links you click in other apps still open in your own Chrome) and keeps drawing while
  covered, so you can still watch it from the phone. The cost: each such bot has a Chrome window (and a Chrome icon in
  the Dock) on the Mac, and macOS may bring that window to the front once when it starts (not checked on your Mac
  yet).
- **Copy of My Chrome Profile** removes the empty-profile part (history, cookies, a signed-in Google account).
- We don't use stealth tricks, fake fingerprints or CAPTCHA solvers. When a check still appears, the bot asks you
  (the "needs you in its browser" card) and you solve it on the phone with Take Control.

**Recommendation:** turn on **Show as Normal Chrome** for the bots that browse a lot, and use a profile copy only for
bots that need your sign-ins. If it works well for you we can make Normal Chrome the default for new bots later.

## What installing it on the Mac changes (needs your OK)

The phone side is ready; the Mac side is a new version of the browser plugin, **hermes-hq-browser 3.6.0**, written but
**not installed**. Patch: `docs/browser-plugin/hermes-hq-browser-3.6.0.patch` (full copy beside it, tests in
`tests/test_choice.py`). Installing it:

- adds three routes to the plugin (list your Chrome profiles, read and change a bot's choice);
- lets the plugin copy a Chrome profile into a bot's own browser folder when you pick one (`<bot>/chrome-debug`; the
  bot's own profile is moved to `<bot>/chrome-debug-own` until you switch back);
- can start a bot's Chrome as a normal window when you turn that on.

It does **not** change any bot until you pick something on the phone, never opens or edits your own Chrome profile
(it reads it to copy it), and leaves bots set up by hand alone. Install: `docs/browser-plugin/install-3.6.0.sh` backs
up the installed plugin (main and every bot profile) to `~/.hermes/plugin-backups/`, copies 3.6.0 in, and prints
the restart step (the dashboard's supervisor then copies it to every bot). Until it's installed the app simply
doesn't show the choice.

Still to check on the Mac once installed (can't be tested here without touching your Chrome): that a Normal Chrome
window really opens without stealing focus, and how a copied profile behaves on the sites you use.
