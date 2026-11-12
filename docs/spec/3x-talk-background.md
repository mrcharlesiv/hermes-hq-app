# 3x Talk in the background (Live Activity)

2026-10-27. The owner: "Also need for the voice chat to continue working when the app is closed. Make it live in a
live notification." This replaces 3x-talk.md T29 ("Leaving the app pauses it with a notice. No `UIBackgroundModes
audio`") for a **live conversation** only. Dictation and Read Aloud still stop when the app leaves the screen.

## 1. What changes

| Before (3x-talk.md §10.1) | Now |
|---|---|
| Home, lock or the app switcher → `pausedNotice(.background)`, "Voice stops when Hermes HQ leaves the screen." | The conversation goes on: it listens, sends, thinks and speaks with the app away. Event "conversation goes on with the app away". No notice. |
| The gateway socket closes 25 s after the app leaves the screen (`GatewayConnection` background grace) | While a conversation runs, the socket is **held**: no grace, no close. Ending the conversation away from the app starts the normal 25 s grace. |
| Nothing on the Lock Screen | A Live Activity on the Lock Screen and in the Dynamic Island (§3). |

Swiping the app away in the app switcher still ends everything (iOS kills the process; the activity is cleared at
the next launch). A call or Siri still pauses it (`pausedNotice(.interrupted)`), and so do two minutes of silence.

## 2. How it stays alive

- `App/Info.plist`: `UIBackgroundModes` = `audio`, `remote-notification`; `NSSupportsLiveActivities` = true. The
  active `AVAudioSession` (play and record) keeps the process running while the microphone is open.
- `TalkController.start()` calls `GatewayClient.holdThroughBackground(true)`; `tearDown()` calls it with false.
- `GatewayConnection`: `.holdOpen` cancels a running grace and ends its background task; `.releaseHold(granted:)`
  starts the grace if the app is away. `enteredBackground` does nothing while held.
- The screen-awake hold (`KeepAwake`) is unchanged: it only matters on screen.

## 3. The Live Activity

- Attributes (`TalkActivityKit/TalkActivityAttributes.swift`, built into the app and the widget extension): the bot's
  name, `startedAt` (the running clock is drawn by the system with `Text(timerInterval:)`, so there is no update per
  second) and a link `<scheme>://session/<stored id>` that opens the chat.
- Content state: the dock's phase (`listening`, `thinking`, `speaking`, …), its short title (`TalkDockState.shortTitle`:
  "Listening", "Thinking…", "Speaking"; the name is the card's heading) and muted. `TalkController.publish` passes it
  on; an unchanged state sends nothing.
- Lock Screen: phase symbol, name, title · clock, Mute and End buttons. The card is Liquid Glass with white words
  (`lockScreenGlass()`, TalkActivityWidget/LockScreenGlass.swift: system background cleared, regular glass behind the
  words, a 22 % black wash, `.colorScheme(.dark)`), the same as a reply's card (3x-presence.md §17.7). Build 404 drew the
  default black words on the Lock Screen's black, a blank card; until 2026-10-31 it was a dark card of its own (owner:
  "needs to be Liquid Glass not black"). The clock's range ends 24 h after the start, not at
  `distantFuture` (a timer's text is as wide as its longest value: since 2026-11-11 it ends at the next digit,
  `LiveTimerSpan`, 3x-presence.md §17, and shrinks rather than be cut), and sits leading, 64 pt at most. Dynamic Island: expanded (name, clock, title,
  buttons), compact (symbol, clock), minimal (symbol). Green while listening, the accent while speaking, grey while
  waiting, red when muted.
- The buttons are `LiveActivityIntent`s (`TalkMuteIntent`, `TalkEndIntent`, not shown in Shortcuts). They run in the
  app's process and reach the controller through `TalkActivityActions.handler`, set at launch.
- Started with the conversation (the app is on screen then, as ActivityKit requires), ended at once
  (`dismissalPolicy: .immediate`) when it ends. A launch ends any activity a killed run left behind.
- 2026-11-06 (audit): a conversation that pauses or stops **by itself while the app is away** (two minutes of
  silence, a headset gone, a call, a failure) leaves its card up for 15 minutes, ended, with a short reason in place of
  the phase title ("Paused after 2 minutes of silence", "Voice Paused", the failure's title) and its clock stopped at
  the end (`endedAt`); no buttons. It had vanished at once with no sound and no word. Coming back to the app, or a new
  conversation, takes it away. Ending it yourself (End, the Lock Screen's End) still clears it at once.
- Each update carries a stale date 10 minutes on, and a live conversation sends the card again every 4 minutes even
  when nothing changed; a card that goes stale (the app was killed and can't end it) draws as **Ended**, no clock, no
  buttons, instead of "Listening" with its clock running for hours.
- The content state carries the chat's link too: a conversation begun in a brand-new chat has no stored id when the
  attributes are fixed, so the card's tap opens the chat once its first message gave it one.
- The accent (Speaking's colour) is the app theme's tint, passed in the attributes (`accent`, resolved dark): the
  extension has no theme, and `.accentColor` drew system blue. The reply cards (3x-presence.md §17) carry it too.
- The Talk chat's own turn gets no reply card when the app is left (`LiveActivityPlanner.leaving(talking:)`): the
  conversation's card already shows it, and a second one stayed behind as "Done".
- Off under unit tests (`XCTestConfigurationFilePath`), and on Mac Catalyst (`#if !targetEnvironment(macCatalyst)`;
  the extension is iOS only, `platformFilter: ios`).
- Target `HermesHQTalkActivity`, bundle id `$(HQ_APP_BUNDLE_ID).talk`. Shipping needs that App ID and an App Store
  profile for it.

## 4. Tests

- Unit: `TalkControllerTests` `aConversationHoldsTheSocketAndShowsOnTheLockScreen`, `theLockScreenButtonsMuteAndEnd`,
  and the background step of the lifecycle test (the conversation stays live). `ConnectionLifecycleTests`
  `heldThroughTheBackgroundKeepsTheSocket`, `releasingTheHoldAwayStartsTheGrace`, `holdingInsideTheGraceCallsItOff`.
- UI: `TalkEndToEndTests.testE09a` goes Home for 33 s (past the 25 s grace), comes back still Listening with one
  conversation and the activity showing, then End clears the activity. The debug probe's `activity` field is the
  shown phase ("" for none). The extension is embedded in the original identity only (like Share and
  Notifications), so run it as `HQ_ORIGINAL=YES HQ_IDENTITY=original scripts/e2e-talk.sh …` to see the Dynamic
  Island in the `E09-away-home-screen` shot; the probe checks pass either way.
- UI: `testE09c` locks the simulator, wakes it, answers the system's Live Activities questions and finds the bot's name
  on the Lock Screen (`E09-lock-screen` shot). Needs the original identity, as above.
- On a phone: start Talk, lock the phone, talk to the bot, hear the reply; Mute and End from the Lock Screen and the
  Dynamic Island; tap the activity to open the chat.
