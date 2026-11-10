# Terminal

A shell on the Hermes computer, typed into from the app, with copy and paste both ways. Asked for by a tester on
Discord (2026-11-01): "access to the agent host's terminal from the HQ app" and "copy paste from / to terminal".

## Where it opens

- **More › Workspace › Terminal** (`MorePages` id `terminal`), so it can be a tab (`TabChoice.pageIDs`, last) or a
  place in the Mac's sidebar.
- **Bot Info › Computer › Terminal** (`BotComputerHooks.terminalRow`), shown over Bot Info with a ✕ (`PaneViewer`).

Every bot on a gateway shares the computer, so both entries open the same shells.
Each phone and Mac names its own sessions (`hq.terminal.sessions.<account>`, one per tab; a device from before tabs had
one under `hq.terminal.session.<account>`, which becomes the first tab), so two devices never take each other's shell.

## Tabs

A tester (Discord, 2026-11-04): "Adding multiple shells would be neat (tabs etc.)".

- **+** in the page's bar, ⋯ › New Tab or ⌘T opens another shell, up to 8 (the add-on's limit per computer, across
  every device). Each tab has its own screen, socket and session; all of them stay connected while the page is open.
- A strip of tabs shows over the screens once there are two: "1 zsh", "2 vim" (the number, then the program's title or
  the shell). Tap one to bring it in front; ⇧⌘] and ⇧⌘[ step through them.
- Close a tab with ✕ on the one in front, by holding any tab, or ⋯ › Close Tab. A running shell asks first ("Close This
  Tab?"), since its shell ends. The last tab isn't closed; End Shell is.
- a tester again (2026-11-05): "possibility to name tabs" and "to reorder tabs". Hold a tab for **Rename…** (⋯ › Rename
  Tab… for the one in front), **Move Left** and **Move Right**. A named tab shows its name alone; left empty, it goes
  back to "2 zsh". Names are kept by position beside the sessions (`hq.terminal.names.<account>`), so a name stays
  with its tab through New Shell. VoiceOver has Rename, Move Left and Move Right as actions on each tab. No drag to
  move a tab: a drag only starts from a context menu interaction's hold, and that one puts the keyboard away while
  it's up (iOS deactivates the keyboard under it); the hold is the button's own menu, which leaves the keyboard be.
- The question, Face ID and the add-on check are asked once for the page, not per tab. New Shell and End Shell act on
  the tab in front. The tab in front is kept (`hq.terminal.tab.<account>`).

## Opening

1. The first time for a computer, a question: "Open a Terminal on …?" Not Now leaves it off (`hq.terminal.allowed.<account>`).
2. Face ID or the passcode each time (`TerminalUnlock`; ⋯ › Require Face ID turns it off). No passcode set counts as unlocked.
   Turning Require Face ID off asks for Face ID first (audit 09-1: at the locked page, cancel Face ID, untick it, Unlock
   opened a shell); turning it on asks nothing. A device that can't check at all may still turn it off.

## Away (audit 09-2)

- While the app isn't in front (Control Centre, the app switcher, a call, Face ID's own sheet) a plain panel covers the
  page, tabs and all (`cover`), so the app switcher never shows a shell, as the Screen hides its picture.
- With the lock on, the app going to the background locks the page again: the shells stay connected underneath, Select
  Text's sheet goes, and coming back asks Face ID before anything shows. Cancelled, it shows Terminal Locked with
  Unlock; the ⋯ menu has only Text Size and the lock until then, and no keys reach the shell.
- [mac] Neither: a Mac app leaves the front each time another window is clicked, and there is no app switcher picture.
3. The add-on's status (`GET /api/plugins/hermes-hq-push/status`): `terminal` / `terminalOff` (0.9.25+). Missing keys
   or a 404 show Update the Add-On (`PushSetupOffer`), so an old add-on never gets an endless reconnect.
4. The socket (`TerminalConnection`).

## Wire (hermes-hq-push 0.9.25, `terminal.py`)

`/api/plugins/hermes-hq-push/terminal?ticket=…&session=<32 hex>&cols=&rows=&since=`

- Computer to app: binary is what the shell printed. Text is JSON: `ready` {session, offset, shell, resumed} first,
  `exit` {code}, and `ping` after 20 s of quiet.
- App to computer: binary is keys and pastes. Text is `resize` {cols, rows}, `end`, and `ping`.
- The shell outlives its socket by 15 minutes. A dial with `since` gets what was printed after that byte. If the
  `offset` differs from what the page has shown, the page clears its screen first (`onReset`).
- Closes:

  | Code | Meaning | What the page shows |
  |---|---|---|
  | 1000 | the shell ended | Shell Ended (its exit code, or "You ended this shell." after End Shell), New Shell |
  | 4409 | the same session opened on another socket | Open in Another Window, Open Here |
  | 4403 | `terminal.off` | Turned Off on … |
  | 4501 | unsupported (Windows without pywinpty) | No Terminal Here, with how to repair Hermes on Windows |
  | 4429 | 8 shells open | Too Many Shells Open |
  | 4400 / 4500 | refused | Couldn't Open a Shell |
  | HTTP 404 on the upgrade (no close frame) | a relay on the way only passes the sockets it knows: the Hermes HQ edge before 2026-11-02 answered `ws-path-blocked` | Terminal Blocked on the Way, run the connect command again |

  Anything else dials again with backoff: 0.5 s doubling to 8 s, or at once when the app comes back to the front. A
  first open that fails 8 dials in a row (about 30 s) stops on Can't Reach the Shell with Try Again; a shell that was
  live keeps dialling, since the computer holds it 15 minutes. Each ending is logged as `socket ended: close 4409 →
  replaced` / `HTTP 404 → blocked` (never the reason text).

## Windows

- **Hermes in WSL:** that is Linux, so it gets the Linux shell like any other.
- **Hermes installed on Windows:** the shell is PowerShell 7 (`pwsh`) if it's installed, otherwise Windows PowerShell,
  otherwise cmd. It runs in Windows' pseudo-console (ConPTY), through pywinpty, which Hermes installs on Windows for its
  own dashboard (`WinSession` in `terminal.py`). Its environment is a fresh login's from Windows, not the server's,
  which holds Hermes's keys. The wire and the page are the same.
- Without pywinpty, the status says `terminal: false` and the page says how to repair Hermes (`hermes pm repair`).
- The add-on's tests run the Windows runner against a stand-in pseudo-console on the Mac. As of 2026-11-01 it has not
  run on a real Windows computer.

## Copy and paste

- **Copy:** long-press (SwiftTerm's Select, Select All, Copy), ⌘C on the Mac, ⋯ › Copy All (screen and scrollback as
  plain text), ⋯ › Select Text… (a sheet of plain text to select any part), and OSC 52 from programs (tmux, vim). A
  program's copy says "Copied by the Shell" (audit 09-20: it replaces the clipboard, which may go on to a Mac).
- **Paste:** a hold of the screen (iOS's edit menu, so no "Allow Paste" question), ⋯ › Paste, ⌘V, and a text drop. All
  go through `HQTerminalView.onPaste`. (The key bar's own paste button left with layout A, below.)
  - Several lines ask first ("Paste N Lines?") unless the shell has bracketed paste on. zsh has it; macOS's bash 3.2
    does not, and there each line would run as it lands.

## Keys

- **The keyboard only when asked for** (a tester, 2026-11-05: "see the terminal fullscreen without keyboard i.e. open
  keyboard only on demand from a button"). The page opens full screen. ⌨ (glass in the iOS look, a grey key in the
  Desktop Look, bottom right over the screen) brings up the keyboard and key bar; a drag of the screen down puts them
  away and ⌨ comes back. A tap on the screen doesn't open it. The screen keeps typing focus all along behind an empty
  input view (`HQTerminalView.showsKeyboard`), so a hardware keyboard, a hold's Paste and ⌘V work without it. A sheet or
  question over the page, or another tab coming in front, keeps the keyboard as it was.
- **No squeeze** (a tester: the "shrink" animation each time the keyboard opened). The screens used to stop at
  `keyboardLayoutGuide`, which animates their height along with the keyboard, and SwiftTerm's text stretched as it went.
  They stop at `textBottom`, a guide moved at once on `keyboardWillChangeFrame`, so the screen takes its new height in
  one step and the keyboard slides over the panel's grey.
- **Backspace** (a tester): a held delete keeps repeating. SwiftTerm knows only what was typed since the line was last
  sent, not what the shell has on it (a command brought back with ↑, a paste, a completion). iOS reads the text before
  the caret to decide whether to repeat, read nothing, and stopped after one backspace. `HQTerminalView` answers
  `hasText` true and turns on `reportsTextBeforeInput`, a local change to the vendored SwiftTerm that puts a space at
  offset -1 of the input document, so every repeat sends a backspace and the shell decides when the line is empty.
- **iPhone and iPad:** a key bar over the keyboard (`TerminalKeyBar`), layout A (owner, 2026-11-04): esc, ctrl
  (sticky for one key) and tab at the left, the arrows at the right, nothing between. Each key is a key cap of the iOS
  keyboard under it (its grey, corners and 40 pt face); the Desktop Look draws its outlined boxes.
  - The arrows (`TerminalArrowPad`) are a laptop's: ← and → whole keys, ↑ over ↓ in half keys between. Press an arrow,
    or slide to another without lifting; it repeats every 80 ms after 400 ms held. VoiceOver and UI tests see four
    buttons (`terminal.key.left` …).
  - What left the bar: `| ~ / -` are on the keyboard's 123 page; Paste is on a hold of the screen (iOS's edit menu, no
    "Allow Paste?") and in ⋯; the keyboard hides with a drag of the screen down into it (`keyboardDismissMode`
    interactive), or the bar's VoiceOver action Hide Keyboard.
  - History: build 784 had a scrolling row of glass keys plus paste and hide (a tester: → off the edge, the row
    scrolled only from its gaps). The owner called it "an awful UI UX", then turned down a full row of key caps ("I
    don't want all of that in one row"), and picked A of three mockups.
- **The Mac:** no key bar. Escape goes to the shell while it is typed into, not the app's Escape ladder. View › Make
  Text Bigger / Actual Size / Make Text Smaller size the terminal's text while it is in front, as in Terminal.app.
- **Text size:** 8 to 32 pt. The default is 12 on iPhone, 13 on iPad, and 16 on the Mac, where the 77% scale makes it
  read as 12.
- **Font** (a tester: "Hack nerd font (or option to choose a font)"): ⋯ › Font picks SF Mono (the default), Menlo or Hack
  Nerd Font, for every tab (`hq.terminal.font`). Hack Nerd Font Mono ships in the app (`App/Resources/Fonts`, regular
  and bold, 2.8 MB each, Nerd Fonts 3.5.1), registered the first time it's chosen, so Powerline and Nerd Font prompts
  (starship, oh-my-posh, powerlevel10k) draw their symbols. Its notice is in Open-Source Licenses.

## Look

A dark panel (rgb 0.075 / 0.078 / 0.09, text white 0.9) in every look, under the page's own bar.
Don't set `backgroundColor` on the `TerminalView`. It is a scroll view, and setting it clears the layer colour SwiftTerm
paints empty cells with and marks the view opaque, so the screen drew black (`TerminalViewTests.drawsOnThePanelColour`).

Once the shell is live, the notice over the panel is emptied, not just hidden. A hidden "Opening a shell…" spinner went
on turning (it started again after any alert), so the page never sat still: a little battery, and UI test steps that
waited two minutes each for the app to idle. `-HQDebugAnimationWatch YES` (App/Debug/AnimationWatch.swift) logs what is
animating every 3 s, which is how it was found.


## Tests

- **Unit:** `Tests/Terminal/TerminalTests.swift` covers the wire, the connection loop over a stand-in socket, the
  add-on status and the panel colour.
- **End to end:** `scripts/e2e-terminal.sh <SIM>` runs against `scripts/fixtures/terminal-gateway.py`, which runs the
  add-on's real `terminal.py` with a scratch HOME on 127.0.0.1:9817. The tests are:
  1. type, paste (zsh and bash), the Up key, Copy All, leave and come back, End Shell and New Shell;
  2. screenshots of every look;
  3. the Bot Info row;
  4. what the page says when it can't open a shell;
  5. the blocked card in every look;
  6. the key bar (arrows in reach, a swipe from a key), a held delete on a recalled line, the keyboard only from ⌨,
     tabs (two shells, each its own screen, Rename…, Move Left, Move Right, ✕ closes one) and Hack Nerd Font.
- **Add-on:** `test_terminal.py` in hermes-hq-push.
