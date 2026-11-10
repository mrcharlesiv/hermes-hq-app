# 3x — Talk: live voice, Read Aloud, dictation and voice settings (m9 stream `talk`)

Scope: the 32 parity rows assigned to stream `talk` in `docs/briefs/m9/assignment.md` (copied verbatim in
`docs/briefs/m9/talk-rows.md`). It builds on the voice-memo work of milestone 2 (`docs/spec/1x-voice.md`), which left
seams for exactly this (`1x-voice.md` §2.4).

Every fact about the web app was read from source at build 240. Every fact about Hermes was read from the checkout
at `d94b70f` (read only, never run, never imported). Nothing here was tested against the owner's gateway.

Path abbreviations:

| Abbrev | Path |
|---|---|
| `W:` | `/Users/me/Projects/hermes-hq-native-ref240/` (web app, build 240, read only) |
| `V:` | `W:vendor/hermes/apps/desktop/src/` (the Hermes desktop renderer the web app wraps) |
| `HA:` | `/Users/me/.hermes/hermes-agent/` (real Hermes, read only) |
| `NAT:` | this repository |
| `MEM:` | `/Users/me/.claude/projects/-Users-me-Projects-hermes-ios/memory/` (the owner's notes) |
| `REF238` | `/Users/me/Projects/hermes-hq-native-ref238` (fixtures the voice gateway loads) |

Stream resources: builder ports **9900–9904**, stress-tester ports **9905–9909**, simulators `HQN-m9-talk` (builders)
and `HQN-m9-talk-s` (stress tester), worktree `/Users/me/Projects/hermes-hq-native-wt/m9-talk`, branch `m9/talk`.

---

## 0. What the owner asked for

These quotes decide every close call below.

- `MEM:finish-everything-push.md`: the owner asked "to make every Dispatch feature work: voice memos, voice chat,
  watching a bot's computer…" and wants "live voice chat that's understandable; voice memos in fewer taps".
- Same note: "They also asked to remove the 'Hey Hermes' wake word ('won't work on iPhone')."
- Same note: "**Voice on device:** 'I get an error but I can't read what it is'. The unreadable error display is
  itself a bug." Every voice failure in this spec is a card that stays, shows the whole reason, and can be copied.
- `MEM:ios-native-ux-goal.md`: "Voice bug 2026-09-26: voice memos and GPT live failed on device with 'Voice is
  paused'". The fix that shipped: "an explicit start from the visible app clear stale pauses… and puts the cause in
  errors". Native keeps both rules: a tap always starts fresh, and every pause names its cause.
- `MEM:liquid-glass.md`: "It isn't Liquid Glass. So much of this is wrong." Only system glass is allowed.
- `MEM:liquid-glass-more.md`: the web left the voice dock off glass because of a WebView limit ("animated waveform
  can't be mirrored; glass-under would freeze the transcript"). The same note records that a tab-bar accessory
  bubble was rejected: "covered the list and its tap didn't open the chat on the real phone… Don't re-add an
  accessory without asking".
- `MEM:native-composer.md`: "We can't do something that could stop apple from approving us." No private API.
- `MEM:hermes-code-not-ours.md`: "We can't make any changes to hermes agent code since we don't control it."
- `MEM:row-padding-feedback.md`: wrapping rows get 12–14 pt of vertical padding.
- `MEM:hermes-hq-native.md`: "it is 'Hermes HQ', never 'Dispatch' in anything user-facing". Talk is first on the
  remaining top-10.

The app's name in every sentence below is written "Hermes HQ". In code it is the bundle's display name
(`MemoNotice.appName`, `1x-voice.md` V11), so the native identity reads "HQ Native" and the shipped one "Hermes HQ".

---

## 1. Decisions

Each line is a **DECISION** taken without the owner (asleep). The reason and the source are beside it.

| # | Question | **DECISION** | Why |
|---|---|---|---|
| T1 | Which voice engine? | The "chained" engine: microphone take → gateway speech-to-text → `prompt.submit` → gateway text-to-speech. The wake word is never built and never shown. **Amended 2026-10-26 (owner chose to build GPT-Live):** GPT-Live is a second engine, docs/spec/3x-gpt-live.md. | `W:build/voice-gates.ts` sets `LIVE_VERIFIED = false` and returns early from every wake-word function. The owner removed the wake word. |
| T2 | What goes on the wire for a spoken turn? | Exactly what build 240 sends: `prompt.submit {session_id, text}` plus `interrupted: true` after a barge-in. **Never** `voice_turn`. `surface: "voice-live"` and `voice_context` only on a GPT-Live delegation (3x-gpt-live §3.4). | `V:app/session/hooks/use-prompt-actions/submit.ts:257,879-899`. `voice_turn` would move the turn to another model (`HA:tui_gateway/contracts/prompt_voice.py`: "runs on auxiliary.voice_chat"). `surface` is GPT-Live only. |
| T3 | Client-direct voice (the phone calls the provider itself)? | No. The phone never calls `GET /api/audio/voice-config`. All audio goes through the gateway. | That endpoint returns provider API keys (`HA:hermes_cli/web_routers/audio.py`). Keys stay on the gateway computer. |
| T4 | How is the microphone captured? | One `AVAudioEngine` with voice processing on its input (`inputNode.setVoiceProcessingEnabled(true)`), so the bot's own voice is cancelled. A take is written as **16 kHz mono 16-bit WAV** and sent with `POST /api/audio/transcribe`. The streaming `WS /api/audio/transcribe-stream` is not used. | Public API. WAV needs no encoder and the fixture can measure it. A 6 s take is 192 KB. Build 240 does not use the streaming endpoint either (no reference to it in `V:` or `W:src`). |
| T5 | How is the reply spoken? | `WS /api/audio/speak-stream`: raw 16-bit PCM into an `AVAudioPlayerNode` on the same engine. If the socket answers `fallback` or never produces audio, speak sentence by sentence with `POST /api/audio/speak` and `AVAudioPlayer`. A container iOS cannot decode (Ogg) is a plain failure, not silence. | `V:lib/voice-playback.ts:359-540,670-760`. |
| T6 | Where does Read Replies Aloud live? | On this iPhone: `hq.voice.readRepliesAloud` in `UserDefaults.standard`. **Until the person has switched it once** (the bar's Speak Replies, the voice options menu, ⋯, Settings › Voice), it follows the gateway's `voice.auto_tts` as last read (kept in `hq.voice.readRepliesAloud.gateway`; read whenever a bot's voice settings are loaded: a chat showing, a conversation starting); nothing known is off. After the first switch the local choice wins and the gateway is no longer consulted. (Build 305 and earlier: plain default off.) | The desktop: `V:store/voice-prefs.ts` `applyAutoSpeakFromConfig` seeds `$autoSpeakReplies` from `voice.auto_tts` until the user has chosen. With it off, a voice conversation is speech-to-text only (`use-voice-conversation.ts`), which the owner read as "it wasn't reading the responses out loud" (build 305). |
| T7 | Where is Talk? | In the composer's primary circle, when the field and tray are empty, no reply is running, and no memo or dictation is active. While the chat cannot send (reconnecting), the circle stays the disabled Send it is today. | `W:src/ui-voice/voice-controls.tsx:187`. `1x-voice.md` V5 reserved the slot. A Talk that could not start would be a control that does nothing. |
| T8 | How long is the hold for voice options? | The system's own menu hold (`UIControl` context menu, about half a second), not a hand-made 500 ms timer. | The web's 500 ms copies the system. The native control gets the system's timing, haptic and animation for free. |
| T9 | Dock material | **Revised after build 305** (the card ran to the screen's edges and its bottom was cut off): the live conversation is the desktop's conversation controls in the composer's row (§6.1), at the composer's own insets, with native glass (default look) or the composer's one bordered box (Desktop Look). The paused / stopped notice stays one Liquid Glass card, placed at the same insets. | The owner: "make sure this mimics how the desktop app works" (`V:app/chat/composer/controls.tsx` `ConversationPill`). |
| T10 | Audio route picker | A real `AVRoutePickerView` is the control the finger touches. No fake tap is sent to its inner button, so the web's "The audio picker didn’t open" hint is not needed. AVKit is loaded only when the first dock appears. | The web walks the picker's subviews and sends `.touchUpInside` (`W:ios/App/App/HermesVoice.swift:603-641`): fragile. `NAT:docs/ARCHITECTURE.md` "Keep heavy frameworks out of launch". |
| T11 | Where is the away pill? | A floating glass capsule 8 pt above the bottom chrome of whatever screen is showing. **Not** `UITabBarController.bottomAccessory`. | The owner rejected a tab-bar accessory and said not to re-add one without asking (§0). He cannot be asked tonight. |
| T12 | A question or approval arrives during a conversation | The question dock wins the composer's place. The conversation mutes itself while the question waits and un-mutes when it is answered. | Speech must not be sent as a new turn while an approval is pending. |
| T13 | Other audio during a live conversation (a memo's play button, Read Aloud) | It plays through the conversation's audio session and the conversation mutes itself. The dock says "Muted"; Mute brings the microphone back. | One microphone, one session, no surprise sends of the bot hearing a memo. Uses a state and wording the dock already has. |
| T14 | Do paused / stopped notices survive a relaunch? | No. They are kept per chat in memory while the app runs, as on the web. | `W:src/ui-voice/voice-dock-notice.ts`. |
| T15 | Transcription keeps failing | After **3 failures in a row** the conversation stops with a "Voice Transcription Failed" notice that carries the last reason. | The web re-arms for ever. A loop of error haptics while the phone lies on a desk is worse than stopping. |
| T16 | Barge-in while the bot is still working | Stop the turn, wait up to 5 s for it to end, then send the new words with `interrupted: true`. If it has not ended, the words join the chat's normal queue. | `V:…/use-voice-conversation.ts` (`INTERRUPT_SETTLE_TIMEOUT_MS = 5_000`). The queue already exists (`NAT:docs/spec/04-send-stream-stop.md` §6). |
| T17 | Where is the dictation row? | Inside the field's glass, the same slot the memo recorder uses. The primary circle becomes Stop, drawn as a tick (UX study 2026-10-19 #47: a square read as discard, which is ✕'s job). "Done" hides at accessibility text sizes (Stop does the same thing). | Dictation can only start from the Talk menu, which exists only on an empty field (T7), so nothing typed is hidden. |
| T18 | Voice Diagnostics rows | Native facts replace the web's WebKit rows (§9.4). | The web reports WebKit's audio session. Native has one `AVAudioSession`. |
| T19 | Microphone permission sentence | `$(HQ_DISPLAY_NAME) uses the microphone for voice memos, dictation and voice conversations you start.` | The web's own sentence (`W:ios/App/App/Info.plist:25`). `1x-voice.md` V11 dropped the Talk part "until Talk ships". |
| T20 | Fixture | Extend `scripts/fixtures/voice-gateway.py` in place. Every addition is a new path or a new control, so the memo tests keep passing. Ports 9900–9909 are accepted without the override variable. | The task names this fixture. A second file would have to copy its sign-in, upload and prompt code. |
| T21 | Gateway voice settings | Three pages, titled as the web's phone build titles them: **Voice Conversation**, **Speech to Text**, **Text to Speech**. The curated keys are the web's (§9.2). Hidden keys stay hidden. | `V:app/settings/constants.ts` SECTIONS `voice`; `W:build/fe-platform-gates.ts:355`; `W:build/voice-gates.ts` `voiceFieldVisible`. |
| T22 | Keep awake | One reference-counted `KeepAwake` in the app. The memo recorder stops writing `isIdleTimerDisabled` itself and takes a hold. | `W:src/voice-keep-awake.ts`. Two writers of one flag would fight. |
| T23 | The "Say "stop" to end the voice chat." hint | Not shown. Saying a stop phrase still ends the conversation. | The web shows it as a toast (`V:…/use-composer-voice.ts`). The phone has no toasts (`W:src/ui-chat/composer.tsx:29`), and End is always on the dock. |
| T24 | Audio file in the composer tray | Its own small sheet with the app's player, not Quick Look. | Quick Look plays with its own audio session, outside `AudioSessionCoordinator`. |
| T25 | Group rooms | No Talk in a room: no primary Talk, no "Talk with" in +, no voice options. | `W:src/ui-voice/entry-live.ts`: "Rooms have no live voice (C3)". Native has no rooms yet; the hook is `ChatVoiceTurns.allowsTalk`. |
| T26 | Wording when Speech to Text is off | Title "Voice Unavailable". Message "Speech to Text is off on your gateway. Turn it on in Settings › Voice › Speech to Text, then try again." Action "Voice Settings…". | The web shows the desktop's untouched "Configure speech-to-text to use voice mode." The web's own phone wording for the same state is "Speech to Text is off" (`W:src/ui-voice/voice-menu.ts:57`). |
| T27 | Thinking sound | Optional polish, built last and only if every row is done: a quiet blip every 1.6 s while the dock says "Thinking…", off when `voice.thinking_sound` is `false`. Not a parity row. | `V:…/use-voice-conversation.ts`. |
| T28 | Intro sheet | Offered until the person taps Start Talking once (`hq.voice.introSeen`); Not Now does not retire it. A sheet that cannot be shown never blocks voice. | `W:src/ui-voice/voice-menu.ts:18-30`. |
| T29 | Off its chat, in the background | A conversation keeps running anywhere **inside the app** (the pill follows it). ~~Leaving the app pauses it with a notice. No `UIBackgroundModes audio`.~~ **2026-10-27: a conversation goes on with the app away, with a Live Activity (3x-talk-background.md).** Dictation and Read Aloud still stop. | `W:build/fe-voice-gates.ts` FE-007; `W:src/ui-voice/dock-state.ts:82-90` ("Voice stops when Hermes HQ leaves the screen."); `1x-voice.md` V14. |
| T30 | Read Aloud while something else is being read | The new one replaces the old one. | The web throws "Something is already being read aloud." Replacing is what Messages and Telegram do with voice notes. |
| T31 | Stopping Read Aloud | A small glass strip above the composer ("Reading aloud" · Stop) while any reply is read, and "Stop Reading" in that reply's hold menu. | The web's `VoicePlaybackActivity` strip (`V:app/chat/composer/voice-activity.tsx:205-252`). An older reply has no action row to stop it from. |
| T32 | How is dictation recorded? | With an `AVAudioRecorder` set up like the memo recorder (AAC, mono, 24 kHz), not the conversation's engine; sent with the memo's own transcribe call. | §8. Small uploads at the 10-minute limit; settings that already work against this endpoint. |

---

## 2. Architecture

### 2.1 Shape

```
                       ┌──────────────── App (MainActor) ────────────────┐
 ChatViewController ── ChatVoiceHost ──┬─ MemoController (exists)         │
   composer / dock     (per screen)    ├─ TalkController   (one app-wide) ├── TalkAwayPill (window overlay)
                                       ├─ DictationController (one)       │
                                       └─ ReadAloudCenter  (one)          │
                       └────────────────────────┬────────────────────────┘
                                                │ effects / events
                       ┌────────────── HermesKit/Voice ──────────────────┐
                       │ TalkLoop (pure reducer)   TalkDockState (pure)   │
                       │ TalkVAD · TalkStopWord · TalkEcho · SpeechText   │
                       │ TalkCapturing  ← TalkEngineCapture | Fixture     │
                       │ TalkSpeaking   ← TalkEngineSpeaker | Fixture     │
                       │ VoiceGateway (REST + speak-stream socket)        │
                       │ AudioSessionCoordinator (exists, extended)       │
                       └─────────────────────────────────────────────────┘
```

Rules that come from `NAT:docs/ARCHITECTURE.md`:

- Everything is `@MainActor` by default. Every blocking audio call (`AVAudioSession`, engine start and stop, file
  writes) runs on `AudioWork.queue` (`NAT:HermesKit/Voice/AudioSessionCoordinator.swift`), never on the main thread.
- `AudioSessionCoordinator` stays the only owner of `AVAudioSession`.
- AVFAudio only at launch. AVKit (the route picker) loads when the first dock appears.
- Glass is `UIGlassEffect` / `UIButton.Configuration.glass()` / system sheets and menus. Nothing else.
- The conversation logic is a pure reducer with a table of tests, as `MemoGesture` is.

### 2.2 New files

`HermesKit/Voice/` (no UIKit, unit-tested):

| File | Holds |
|---|---|
| `TalkTypes.swift` | `TalkStatus` (`idle, listening, transcribing, thinking, speaking`), `TalkPauseCause` (`interrupted, background, silence, routeLost`), `TalkNotice`, `TalkConfig` (values read from the gateway config, §4.1). |
| `TalkDockState.swift` | Port of `W:src/ui-voice/dock-state.ts`: `TalkDockState.view(...)`, `formatElapsed`, `SilenceClock`, `pausedNotice`, `stoppedNotice`, `noticeText`. All wording of §6 lives here. |
| `TalkLoop.swift` | The conversation reducer (§4.2). |
| `TalkVAD.swift` | Level maths, end-of-speech detection, barge-in trigger (§4.3, §4.5). |
| `TalkStopWord.swift` | Port of `V:lib/voice-stop-word.ts`. |
| `TalkEcho.swift` | Port of `V:lib/voice-tts-echo.ts` (`isTtsEcho`, the SequenceMatcher ratio). |
| `SpeechText.swift` | Port of `V:lib/speech-text.ts`: `sanitizeForSpeech`, `cutSentences`, `SentenceBuffer`. |
| `TalkCapture.swift` | `protocol TalkCapturing`, `TalkEngineCapture` (real), `FixtureTalkCapture` (tests and UI tests). |
| `TalkSpeaker.swift` | `protocol TalkSpeaking`, `TalkEngineSpeaker` (stream + fallback), `FixtureTalkSpeaker`. |
| `VoiceGateway.swift` | The REST calls of §3 and the speak-stream socket, over `GatewayTransfers` and `pluginSocket`. |
| `VoiceEvents.swift` | The last 30 audio events (`W:src/voice-events.ts`) and the diagnostics report (`W:src/voice-report.ts`). |
| `KeepAwake.swift` | Reference-counted idle-timer holds (§10.2). The one `@MainActor` file here that touches `UIApplication`. |

`App/Chat/Voice/`:

| File | Holds |
|---|---|
| `TalkController.swift` | One conversation app-wide: start, end, mute, the elapsed clock, notices per chat, `didChange` notification. |
| `TalkDockView.swift` | The live dock and the paused / stopped dock (§6.1–§6.4). |
| `TalkVisualView.swift` | The five bars, three dots and muted glyph. |
| `TalkRouteButton.swift` | The route label over an `AVRoutePickerView` (§6.5). |
| `TalkAwayPill.swift` | The away pill and its window host (§6.6). |
| `TalkIntroSheet.swift` | "Talk with <Bot>" and "How Voice Works" (§5.3). |
| `TalkMenus.swift` | The voice options menu, the + menu items, the bot row and Bot Info tiles, the intro capsules. |
| `DictationController.swift`, `DictationRow.swift` | Dictation (§8). Its recorder, `DictationRecorder.swift`, lives in `HermesKit/Voice/`. |
| `ReadAloudCenter.swift`, `ReadAloudStrip.swift` | Read Aloud and Read Replies Aloud (§7). |
| `AudioPreviewSheet.swift` | The composer tray's audio preview (§11). |

`App/Settings/Voice/`: `VoiceSettingsPages.swift` (§9.1–§9.3), `VoiceDiagnosticsView.swift` (§9.4).

`App/Integration/TalkWiring.swift`: `TalkWiring.install(model:)`, called on the line after `M2Wiring.install(model:)`.
It registers every hook of §2.5 and nothing else, so other streams' files are not edited beyond the lines listed there.

`App/Debug/TalkDebugHooks.swift` (DEBUG only): the launch arguments of §14.3.

### 2.3 Contracts added (`HermesKit/Contracts+talk.swift`)

`HermesKit/Contracts.swift` is not edited. The integrator may fold these in later.

```swift
/// A chat that can hold a live voice conversation (adopted by LiveChatSession).
protocol ChatVoiceTurns: AnyObject {
    /// False in a group room (T25) and for a chat that cannot send.
    var allowsTalk: Bool { get }
    /// "<account id>|<profile>|<stored session id>" — the same scope the memo stores use.
    var memoScope: String { get }
    var isRunning: Bool { get }
    var connection: ConnectionState { get }
    /// An ordinary send whose prompt.submit carries `interrupted: true` when asked (T2). Shows the usual bubble.
    func sendSpoken(_ text: String, interrupted: Bool)
    func stop()
    /// The assistant words of the newest turn, text parts only, in order. `pending` while it still streams.
    var newestReply: SpokenReply? { get }
    /// Fired after every change, on screen or off (a second listener beside `onChange`).
    var onVoiceChange: (() -> Void)? { get set }
    /// True while a conversation lives here: the chat keeps listening after its screen leaves (§2.4).
    var voiceHold: Bool { get set }
    /// What the away pill needs to reopen this chat.
    var storedSessionId: String? { get }
    var profile: String { get }
}

nonisolated struct SpokenReply: Equatable, Sendable {
    var messageId: String      // the assistant message's id (the highlight and "already spoken" key)
    var text: String           // Markdown, not yet cleaned for speech
    var pending: Bool
}
```

`LiveChatSession` adopts it in a new file `HermesKit/Chat/LiveChatSession+Talk.swift`. Three small edits to existing
session code are needed and are the only ones:

1. `LiveChatSession.beginSend(...)` takes `interrupted: Bool = false` and adds `params["interrupted"] = true` beside
   the `queued` line (`LiveChatSession.swift:~790`). Nothing else about the send path changes: the same optimistic
   bubble, the same 4009 retry window, the same resume-once, the same refusal card.
2. `stopObserving()` treats `voiceHold` like `drainingAway`: it does not call `stopListening()`
   (`LiveChatSession.swift:400-411`).
3. Where `onChange` is delivered, `onVoiceChange?()` is called too.

`AppModel` keeps a chat whose `voiceHold` is true in `awayChats` (the mechanism that already keeps a chat whose queue
is still draining, `App/AppModel.swift:46,93-120,534`), so reopening the bot or session returns the same object with
its conversation.

### 2.4 Who owns what

- **One conversation app-wide** (`TalkController.shared`). Starting one in another chat ends the previous one first
  (`W:src/voice-conversation.ts:15`: "never two live microphones").
- **One microphone app-wide.** Starting a conversation cancels a dictation and turns a memo take in progress into
  its draft chip (`MemoController.screenLeft` already does this). Dictation and the memo mic are refused while a
  conversation is live (`W:src/voice-conversation.ts:31-35`); the composer is covered by the dock then, so neither
  control is on screen in that chat. In another chat the mic control stays, and using it ends the conversation first.
- **One speaker app-wide** for speech: a conversation's reply, Read Aloud and Read Replies Aloud share
  `TalkSpeaking`; starting one stops the other. Memo playback keeps `MemoPlayer`.
- `ChatVoiceHost` (one per chat screen) stays the only thing that touches the composer for voice. It now also shows
  and hides the dock, the dictation row, the Read Aloud strip and Talk in the primary circle.

### 2.5 Hooks into other streams' code, and hooks left for them

Edits this stream makes outside its own files (each is one registration or a few lines):

| Where | Edit |
|---|---|
| `App/Chat/ComposerView.swift` | `Primary.talk` becomes real: `talkAvailable`, `onTalk`, `talkMenu`, the five-bar glyph, the Stop Dictation label (§5.1, §8). |
| `App/Chat/ChatViewController.swift` | A dock arbiter (`setDock(_:for:)`, §6.1) around the existing `showPromptDock`; `beginTalk()` beside `beginMemo(handsFree:)`. |
| `App/Chat/ChatPlaceholderView.swift` | Role, description and the two capsules in the empty intro (§5.6). |
| `App/Chat/Cells/ChatCells.swift` (`ChatActionsCell`) | Read Aloud between Copy and Regenerate (§7.1). |
| `HermesKit/Chat/ChatActionsModel.swift` | `MessageMenuItemID.readAloud`; a Read Aloud tile on a reply (§7.2). |
| `App/Chat/Menus/ChatMenus.swift` | `slotItems[.readAloud]` (the slot already exists) (§7.3). |
| `App/Chat/Attachments/ComposerPlusMenu.swift` | `register(.memo)` and `register(.talk)` (slots already exist) (§5.4). |
| `App/Bots/BotsOrganizer.swift` | `BotMenuHooks.providers[.talk]` (slot already exists) (§5.5). |
| `App/BotInfo/BotInfoSheet.swift` (`BotInfoTiles`, `BotInfoModel`) | Talk tile first; room and a marked place for the screen stream's tile (§5.5). |
| `App/Settings/SettingsRootView.swift`, `HermesKit/Settings/ConfigSchema.swift`, `ConfigCopy.swift`, `SettingsSearch.swift` | The Voice section and its search entries (§9). |
| `App/Chat/Attachments/ChatAttachmentsController.swift` | `trayOpen` sends an audio tile to `AudioPreviewSheet` (§11). |
| `HermesKit/Voice/AudioSessionCoordinator.swift`, `MemoRecorder.swift` | New owners; keep-awake through `KeepAwake` (§10). |
| `App/Info.plist` | The microphone sentence (T19). Shared by both identities. |

Hooks this stream leaves for others (named in the assignment's "Also for this stream"):

| For | Hook |
|---|---|
| botslist (Undo pill, row L237) | `TalkAwayPill.isShowing: Bool` (static, MainActor) and `Notification.Name("hq.talk.pill.changed")`. The Undo pill yields while it is true. The pill's frame is `TalkAwayPill.frameInWindow`. |
| screen (Bot Info Screen tile, row L214) | The screen stream's own spec (`docs/spec/3x-screen.md` §6.1, on branch `m9/screen`) adds `if model.screenAvailable { tile("Screen", …, id: "bot-info.tile.screen") { model.screen() } }` between Memo and Mute, gated on `BotMenuHooks.providers[.screen]`. This stream follows the same pattern for Talk (`model.talkAvailable`, `model.talk()`), marks the place between Memo and Mute with a comment, and makes the row lay out for four tiles, so the two edits merge as neighbouring lines. |
| settings (React…, row L365) | Nothing to add: `MessageMenuModel` keeps its order and Read Aloud is a tile, so React… goes in as a row after Select Text as on the web (`W:src/ui-chat/message-menu.ts:22`). |
| composer (Link…, Folder…, Prompt Snippets…, More, row L389) | `ComposerPlusMenu.Slot` already orders them (`link 40, folder 50, snippets 60, more 70`). This stream fills only `memo 10` and `talk 20`. |
| groups (rooms) | `ChatVoiceTurns.allowsTalk` returns false for a room. |

---

## 3. Wire

Hermes rejects unknown parameters with error 4000. Every body below lists every key the app sends.

### 3.1 Read the voice settings a conversation needs

`GET /api/config?profile=<profile>` (already used by memos for `stt.enabled`). Read once when a conversation or a
dictation starts, cached for 60 s per profile. Forgotten on every `PUT /api/config` the app makes
(`GatewaySettingsAPI.saveConfig`), and a kept "Speech to Text is off" is never answered from memory (the card tells the
person to turn it on and try again).

```json
{ "stt": { "enabled": true, "provider": "openai" },
  "tts": { "provider": "edge" },
  "voice": { "silence_duration": 3.0, "stop_phrases": ["stop"], "barge_in": true,
             "barge_in_threshold_multiplier": 3, "thinking_sound": true, "max_recording_seconds": 120 } }
```

Missing keys take the defaults of §4.1. A read that fails does not block Talk: defaults are used and
`stt.enabled` is assumed true (the first transcription will say what is wrong).

### 3.2 Speech to text

`POST /api/audio/transcribe?profile=<profile>` — `Content-Type: application/json`, timeout 45 s
(`GatewayTransfers.transfer`).

```json
{ "data_url": "data:audio/wav;base64,UklGRiQAAABXQVZF…", "mime_type": "audio/wav" }
```

Answer: `200 {"ok": true, "provider": "openai", "transcript": "what's on my calendar"}`. An empty take answers
`{"ok": true, "transcript": ""}`. Failures are `400 {"detail": "<reason>"}` (for example "Audio recording is empty",
"Payload must be an audio recording") or `413 {"detail": "Audio recording is too large"}` over 25 MB
(`HA:hermes_cli/web_routers/audio.py:83-143`). The `detail` is shown word for word in the notice.

Dictation (§8) sends the same two keys with its AAC file: `"data_url": "data:audio/x-m4a;base64,…"`,
`"mime_type": "audio/x-m4a"`, exactly as a voice memo's transcription does today.

### 3.3 Text to speech, streamed

`WS /api/audio/speak-stream?profile=<profile>&ticket=<ticket>` opened with `LiveGatewayClient.pluginSocket(path:query:)`
(a fresh single-use ticket per socket, `NAT:HermesKit/Net/LiveGatewayClient.swift:166`). Close codes 4401 and 4403 mean
the ticket was refused.

```
client → {"text": "Sure. Your first meeting "}          incremental reply text, as it streams
client → {"text": "is at nine."}
client → {"done": true}                                   the reply is complete
client → {"stop": true}                                   barge-in or End (then close)
server → {"type": "start", "sample_rate": 24000, "channels": 1}
server → <binary>                                         little-endian int16 PCM frames
server → {"type": "end"}                                  all audio sent
server → {"type": "fallback"}                             no audio could be made: use §3.4
```

The server cuts sentences and strips Markdown itself (`_strip_markdown_for_tts` on each sentence), so a reply that is
still being written is sent **as written**: only the new suffix of the raw reply, counted in Unicode scalars
(`SpeechFeed`). Cleaning on the phone is not stable while Markdown arrives (a link or a code span rewrites the earlier
text when it closes), so a cleaned suffix would lose letters; the web says the same ("Raw deltas — the server strips
markdown/emoji per sentence", `V:lib/voice-playback.ts:514`). A reply that is already whole when it is first sent (Read
Aloud) is cleaned whole with `SpeechText.sanitizeForSpeech`, as the web's `startSpeechText` does. New text is sent at
most every 150 ms. The outcome is `fallback` when the socket closes before `start`, on a `fallback` frame, or
(**DECISION**, m9 review) when 10 s pass after `done` with neither `start` nor `end`: the web has no such timer, but
without one a conversation would sit on "Thinking…" for ever behind a socket that never answers; 10 s is long enough
for a whole first sentence from a cold voice and shorter than Read Aloud's own 15 s answer (§7.6), so the clips still
get their turn. PCM frames are not sample-aligned (the gateway forwards its provider's chunks): the bytes of a split
sample wait for the next frame (`PCMCarry`), never dropped (`V:lib/voice-playback.ts:424`).
(`V:lib/voice-playback.ts:359-540`).

### 3.4 Text to speech, one clip

`POST /api/audio/speak?profile=<profile>` body `{"text": "Your first meeting is at nine."}`, timeout 60 s.

Answer: `200 {"ok": true, "data_url": "data:audio/mpeg;base64,…", "mime_type": "audio/mpeg", "provider": "edge"}`.
`400 {"detail": "Text is required"}` for empty text. The app decodes the data URL to a temporary file and plays it
with `AVAudioPlayer`. `audio/mpeg`, `audio/wav`, `audio/x-wav`, `audio/flac`, `audio/mp4`, `audio/aac` play; anything
else fails with "Your gateway’s voice uses a format iPhone can’t play (<mime>). Pick another Text to Speech provider
in Settings › Voice." (title "Voice Playback Failed").

### 3.5 Warm-up leases (best effort)

`POST /api/audio/tts-lease?profile=<profile>` and `POST /api/audio/stt-lease?profile=<profile>` (the bot's profile, as
the web's `profileScoped()`: the gateway warms that profile's voice; one line of calls per gateway and kind, so a hold
and its release arrive in the order asked), body `{"active": true, "lease": "<name>"}` to hold,
`{"active": false, "lease": "<name>"}` to release, timeout 180 s. Fired and forgotten: a failure is logged to
`VoiceEvents` and never shown.

| Lease name | Held while |
|---|---|
| `hqnative:conversation:<install id>` (tts and stt) | a conversation is live |
| `hqnative:read-aloud:<install id>` (tts) | Read Replies Aloud is on and a chat is on screen |
| `hqnative:voice-input:<install id>` (stt) | a dictation records or transcribes |

`<install id>` is a random UUID stored once in `UserDefaults` (`hq.voice.installId`).

### 3.6 The spoken turn

```json
{"jsonrpc":"2.0","id":41,"method":"prompt.submit","params":{"session_id":"rt_8c1…","text":"what's on my calendar"}}
{"jsonrpc":"2.0","id":57,"method":"prompt.submit","params":{"session_id":"rt_8c1…","text":"no, tomorrow","interrupted":true}}
```

`profile` is added exactly when `LiveChatSession` adds it today. Stop and Interrupt are the chat's existing
`session.interrupt`. The reply arrives as the usual streaming events; nothing voice-specific is read from them.

### 3.7 Voice settings

`GET /api/config`, `GET /api/config/schema`, `GET /api/config/defaults`, `PUT /api/config {"config": {…sparse patch…}}`
through the existing `GatewayConfigStore` (`NAT:HermesKit/Settings/GatewaySettingsAPI.swift`). One more read for the
ElevenLabs voice list: `GET /api/audio/elevenlabs/voices` →
`{"available": true, "voices": [{"label": "Rachel", "name": "Rachel", "voice_id": "21m00Tcm4TlvDq8ikWAM"}]}`.

### 3.8 Never called

`GET /api/audio/voice-config`, `WS /api/audio/transcribe-stream`, and the RPC methods `voice.toggle`, `voice.record`,
`voice.tts`, `wake.*`. `scripts/check-talk-guards.sh` greps the app's sources for these strings and fails if one appears
(row L546). The GPT-Live routes (`/api/audio/voice-live/*`) were here until 2026-10-26; they are now named only in
`HermesKit/Voice/LiveVoiceWire.swift` (docs/spec/3x-gpt-live.md).

---

## 4. The conversation engine

### 4.1 Constants

| Name | Value | Source |
|---|---|---|
| Speech level | `0.075` (level = `min(1, rms × 128 / 42)` of the float samples, about −32 dBFS) | `W:src/ui-voice/dock-state.ts` `SPEECH_LEVEL`; `V:…/use-mic-recorder.ts:189-190` |
| End of speech | 1.25 s of quiet after speech was heard. If `voice.silence_duration` differs from Hermes' default (3.0), that value × 1000. | `V:store/voice-prefs.ts` `DESKTOP_SILENCE_MS_DEFAULT = 1_250` |
| Idle take | a take with no speech for 12 s ends and a new one starts | `V:…/use-voice-conversation.ts` `idleSilenceMs: 12_000` |
| Longest take | 60 s, then it is sent as it is | same file, `setTimeout(handleTurn, 60_000)` |
| Still Listening | after 30 s without speech | `STILL_LISTENING_MS = 30_000` |
| Silence pause | after 120 s without speech | `SILENCE_PAUSE_MS = 120_000` |
| Barge-in | on unless `voice.barge_in` is `false` | `V:store/voice-prefs.ts` |
| Barge trigger | quiet floor × 3.5, never below 0.075; while the bot speaks at least 0.14 and at most 0.37; 300 ms window with ≥ 80 % above the trigger; 400 ms calibration; 500 ms grace after speech starts playing. Scaled by `voice.barge_in_threshold_multiplier / 3`. | `V:lib/voice-barge-in.ts:28-48,80-90` |
| Barge utterance cap | 30 s | same file, `UTTERANCE_MAX_MS` |
| Echo guard | similarity ≥ 0.6; fragments shorter than 10 characters are never treated as echo | `V:lib/voice-tts-echo.ts` |
| Stop phrases | `voice.stop_phrases` when customised; the built-in English list otherwise; `[]` turns it off | `V:lib/voice-stop-word.ts:25-45` |
| Shortest metered take | a take under 750 ms whose meter failed is dropped; 2 meter failures in a row stop the conversation | `METER_FAILURE_MIN_CLIP_MS`, `METER_FAILURE_LIMIT` |
| Interrupted flag lifetime | 120 s | `V:lib/voice-playback.ts` `INTERRUPT_TTL_MS` |
| Speech feed | new reply text every 150 ms | `V:…/use-voice-conversation.ts` |
| Stream stall | after `done` was sent: no audio and no `end` for 15 s ends the reply. Never before `done`: the socket is quiet for as long as a tool runs | `PLAYBACK_STALL_MS = 15_000` (the web guards only a clip's player) |

### 4.2 The loop (`TalkLoop`)

A pure reducer: `(TalkLoopState, TalkLoopInput) -> (TalkLoopState, [TalkLoopEffect])`. `TalkController` feeds it
inputs and performs the effects.

States (the `TalkStatus` the dock draws, plus flags):

```
starting ──mic ready──▶ listening ──take ended, speech heard──▶ transcribing ──words──▶ thinking ──first audio──▶ speaking
   ▲                       │  ▲                                    │  │                    │                        │
   │                       │  └──── no speech / empty / echo ──────┘  │                    │                        │
   │                       │  ◀───────────── reply fully spoken, or no speakable reply ────┴────────────────────────┘
   │                       └── stop phrase ──▶ ended
   └── Resume / Try Again ── paused(cause) / stopped(reason)
```

Inputs: `start`, `micReady`, `micFailed(reason)`, `level(Double)`, `takeEnded(file, heardSpeech, meterFailed, ms)`,
`transcript(String)`, `transcribeFailed(reason)`, `turnRunning(Bool)`, `reply(SpokenReply?)`, `speechStarted`,
`speechFinished(fallback: Bool)`, `speechFailed(reason)`, `bargeSpeech`, `bargeUtterance(file?)`,
`muteToggled`, `sendNow`, `stopOrInterrupt`, `end`, `connection(open: Bool)`, `tick(now)`,
`interrupted(cause)`, `questionWaiting(Bool)`, `otherAudio(Bool)`.

Effects: `beginTake`, `finishTake`, `cancelTake`, `transcribe(file)`, `submit(text, interrupted)`, `stopTurn`,
`openSpeech(messageId)`, `feedSpeech(text)`, `finishSpeech`, `stopSpeech`, `speakClip(text)`, `armBarge`,
`disarmBarge`, `haptic(kind)`, `notice(TalkNotice)`, `ended(TalkEnd)`.

Rules, in the web's own order (`V:app/chat/composer/hooks/use-voice-conversation.ts`):

1. **Start.** Reads the config (§3.1). `stt.enabled == false` → end with the pre-conversation notice of T26. Asks for
   the microphone if iOS has not been asked. Denied → end with the microphone notice (§5.7). Then `beginTake`.
2. **Listening.** `takeEnded` with no speech heard → `beginTake` again (still Listening). A take under 750 ms whose
   meter failed is dropped the same way; the second such failure in a row ends with "Voice Stopped" /
   "The microphone isn’t giving a level, so Hermes HQ can’t tell when you stop talking."
3. **Transcribing.** `transcribe(file)`. Empty words → `beginTake`. A stop phrase (the whole utterance, optionally
   after "hey hermes", "hermes", "ok", "okay", "hey") → `ended(.said)`. Otherwise `submit(text, interrupted)` and
   Thinking. `transcribeFailed` → an inline notice on the dock ("Voice Transcription Failed" and the reason), then
   `beginTake`; the third failure in a row ends the conversation (T15).
4. **Lost speech.** If the gateway connection was not open at any moment between `beginTake` and `takeEnded`, the take
   is thrown away: no transcription, no send. The dock's next Listening hint says so (§6.2). The flag clears when the
   next take reaches Transcribing (`W:src/ui-voice/conversation-guard.ts`).
5. **Thinking.** While the turn runs and before any audio: `armBarge`. As reply text arrives it is fed to the speech
   session (opened when the first speakable text exists). `sendNow` is not offered; the centre button is Stop.
6. **Speaking.** From the first audio. Centre button Interrupt. When the reply is complete and its audio has
   finished → `disarmBarge`, `beginTake`. A turn that ends with nothing speakable → `beginTake`.
7. **Speak Replies off.** The conversation is speech-to-text only: the reply stays text, and the microphone
   re-arms when the turn ends (`V:…/use-voice-conversation.ts`, "STT-only"). Barge-in still stops a running turn.
   **Amended 2026-11-08 (tester: "STT works but response is not read back"):** a conversation follows its own
   Speak Replies (`hq.voice.conversationSpeaks`, the dock's Audio menu), **on** until switched off, not Read Replies
   Aloud (which stays the chat-on-screen switch, T6). Also §7.7: a speech stream that ends (or stalls) without a sound
   for a reply with words in it is read by the iPhone's voice; a clean end with no audio is remembered like an error.
8. **Barge-in** (Thinking or Speaking, barge-in on). `bargeSpeech` → `stopSpeech`, mark interrupted, `stopTurn` if the
   turn still runs, status Listening. `bargeUtterance(file)` → transcribe it. If its words are an echo of what was
   being spoken (`TalkEcho.isEcho`), drop them and `beginTake`. Otherwise wait for the turn to end (≤ 5 s, T16) and
   `submit(text, interrupted: true)`. `bargeUtterance(nil)` → `beginTake`.
9. **Buttons.** Send Now (Listening, speech heard or not) → `finishTake` and transcribe whatever was said, even if the
   meter heard nothing. Stop (Thinking) → `stopTurn`, then `beginTake`. Interrupt (Speaking) → `stopSpeech`, mark
   interrupted, `stopTurn` if still running, `beginTake`. Mute → `cancelTake` and `disarmBarge`; un-mute → `beginTake`
   (or `armBarge` when the bot is working or speaking). End → everything stops, `ended(.user)`.
10. **Reconnecting.** While `connection(open: false)`: the dock shows Reconnecting…; a take keeps recording (so the
    lost-speech rule can see it) but nothing is sent. Back open → Listening.
11. **Silence.** `SilenceClock` counts time while Listening, idle or Transcribing and not muted; it resets on mute,
    Thinking, Speaking or any level ≥ 0.075. At 30 s the dock says Still Listening. At 120 s the conversation ends
    with `pausedNotice(.silence)`.
12. **Interruptions** (§10.1): a call or Siri → `pausedNotice(.interrupted)`; ~~the app leaves the screen →
    `pausedNotice(.background)`~~ (leaving the app never pauses now, 3x-talk-background.md); the microphone's route disappears with no other input → `pausedNotice(.routeLost)`.
    Each ends the conversation; nothing restarts by itself.
13. **A question waits** (T12) or **other audio plays** (T13): the loop mutes itself (`autoMuted = true`). When the
    question is answered it un-mutes itself; after other audio it stays muted until the person taps Mute.

`ended` always: stops speech, cancels the take, releases the audio session, the keep-awake hold and both leases,
clears `voiceHold`, and posts "Voice chat ended · m:ss" (§6.7) when the cause was the user or a stop phrase.

### 4.3 Capture (`TalkCapturing`)

```swift
@MainActor protocol TalkCapturing: AnyObject {
    var onLevel: ((Double) -> Void)? { get set }                 // ~30 Hz, 0…1
    var onTakeEnded: ((TalkTake) -> Void)? { get set }           // end of speech, idle, 60 s cap or finishTake()
    var onBargeSpeech: (() -> Void)? { get set }
    var onBargeUtterance: ((TalkTake?) -> Void)? { get set }
    var onInterrupted: ((TalkPauseCause, String) -> Void)? { get set }   // cause and a detail for the notice
    func prepare() async throws                                   // permission, session, engine
    func beginTake(silenceMs: Int)
    func finishTake()                                             // Send Now
    func cancelTake()
    func armBarge(isPlaying: @escaping () -> Bool, multiplier: Double?)
    func disarmBarge()
    func shutDown() async
}
nonisolated struct TalkTake: Sendable { var url: URL; var ms: Int; var heardSpeech: Bool; var meterFailed: Bool }
```

`TalkEngineCapture`:

- `prepare()`: `AudioSessionCoordinator.acquire(.conversation)`, then on `AudioWork.queue`: voice processing on,
  a tap on the input node (buffer 1024 frames), a converter to 16 kHz mono Int16, `engine.prepare()`, `engine.start()`.
  Time from tap to first level is a signpost (`talk.start`).
- A take appends converted frames to a WAV file in `Caches/talk/<uuid>.wav`. A 1 s ring of the newest frames is kept
  always, so a barge-in utterance starts from its first syllable (the web's "pre-roll").
- Files are deleted when their transcription answers or the take is cancelled, and the folder is emptied at launch.
- Voice processing that cannot be enabled (throws) is not fatal: the engine runs without it, the event is logged,
  and the playback clamp of §4.1 still guards against the bot hearing itself.

`FixtureTalkCapture` takes a script (§14.3) and produces levels and takes on timers with `MemoRecorder.fixtureWave`.

### 4.4 Speech (`TalkSpeaking`)

```swift
@MainActor protocol TalkSpeaking: AnyObject {
    var state: SpeechState { get }                                // idle, preparing, speaking(messageId)
    var level: Double { get }                                     // for the dock's bars
    var onChange: (() -> Void)? { get set }
    func open(messageId: String, profile: String, client: any GatewayClient, owner: SpeechOwner) -> SpeechSession
    func speak(_ text: String, messageId: String, profile: String, client: any GatewayClient, owner: SpeechOwner) async throws -> Bool
    func stop()
    var isAudible: Bool { get }                                   // audio is leaving the speaker right now
}
@MainActor protocol SpeechSession: AnyObject {
    func append(_ fullTextSoFar: String)     // sends only the new, cleaned suffix
    func finish()
    var outcome: SpeechOutcome { get async }                      // done, fallback, stopped, failed(String)
}
```

`TalkEngineSpeaker` schedules PCM on an `AVAudioPlayerNode` (format from the `start` frame; Int16 → Float32). During a
conversation the node is attached to the conversation's engine so voice processing cancels it. For Read Aloud outside
a conversation it runs its own engine under the `.speech` session owner (§10.1). On `fallback`: `SentenceBuffer`
cuts the text and each sentence is fetched with §3.4 and played in order; the next sentence is fetched while the
current one plays.

### 4.5 Speed targets

| Moment | Target |
|---|---|
| Tap Talk (intro already seen) → dock on screen | next frame; the dock shows "Starting…" at once |
| Tap Talk → "Listening" with a moving level | ≤ 400 ms warm, ≤ 900 ms on the first start after launch |
| End of speech → "Transcribing…" | ≤ 50 ms after the quiet window |
| Words back → bubble in the chat and "Thinking…" | same frame as the answer |
| First PCM frame → sound | ≤ 120 ms |
| Barge-in: speech → bot silent | ≤ 350 ms (300 ms window + one buffer) |
| Tap End → microphone indicator off | ≤ 300 ms |
| Main thread | no hitch over 16 ms from any audio call (all on `AudioWork.queue`) |

Each is a signpost in `MemoRecorder.signposts`' subsystem, category `talk`, so the stress tester can read them.

---

## 5. Ways in

A conversation can only start in the chat that is on screen (`W:src/ui-voice/entry-live.ts`: "Never a background
send: nothing records or talks until that chat is the one on screen"). Every entry below ends in the same call:
`ChatViewController.beginTalk()` → `ChatVoiceHost.beginTalk()` → `TalkMenus.startTalking(name:)` (the intro, once)
→ `TalkController.shared.start(in:name:head:)`.

### 5.1 Talk in the composer's primary circle (rows L530, L389 context, T7)

Web: `talkShown = !room && !busy && !hasComposerPayload && voiceStatus === 'idle'`
(`W:src/ui-voice/voice-controls.tsx:187`); label `Talk with ${name}`; glyph five bars 6, 11, 16, 11, 6.

Native, in `ComposerView.updatePrimary(animated:)`, the order becomes:

| Condition (first match wins) | Circle | Label | Identifier |
|---|---|---|---|
| a memo take wants Send | Send / disabled (today) | Send | `composer.send` |
| a dictation records or transcribes | ✓ tick | **Stop Dictation** | `composer.stop-dictation` |
| composer not enabled, or attachments preparing | disabled Send (today) | Send | `composer.send` |
| text, attachments or a memo chip | Send | Send | `composer.send` |
| a reply is running | Stop | Stop | `composer.stop` |
| `talkAvailable` | **Talk**: the tinted circle of Send with five white rounded bars, 3 pt wide, 3 pt apart, 6 / 11 / 16 / 11 / 6 pt tall | **Talk with <name>** | `composer.talk` |
| otherwise | disabled Send (today) | Send | `composer.send` |

`talkAvailable` is set by `ChatVoiceHost`: the chat's `allowsTalk`, no memo take, no dictation, and no conversation
or paused / stopped notice in this chat (then the dock is in the composer's place anyway).

A dictation is above text and attachments (2026-11-01). The table had it below them, so Dictate started with a picture in
the tray left the circle as Send, and Send took the picture alone. The owner: "when I clicked send, it only sent the
picture. It did not send words with it." The dictated words reach the field only when it stops; Send is back then.

- **Tap**: light impact (`W:src/ui-voice/voice-menu.ts:27`), then §5.3 once, then the conversation starts.
- **Touch and hold**: the voice options menu (§5.2) through the control's own context-menu interaction, anchored to
  the circle with a circular preview so no rectangle flashes. **DECISION T8**.
- **VoiceOver**: one element, trait button, custom action "Voice options" (the web's hidden button's name,
  `voice-controls.tsx`), which opens the same menu.
- A conversation live in **another** chat does not hide Talk here. Tapping it ends that one and starts here (§6.8).
- Speech to Text off on the gateway: Talk still shows. Tapping it shows the notice of T26 above the field.

**Tip.** A third tip beside the two memo tips (`NAT:App/Chat/Voice/MemoTips.swift`): `MemoTip.talk`, key
`hq.voice.tip.talk`, glyph `waveform`, title "Talk with <name>", message "Tap the waveform button to talk out loud
with <name>. Hold the mic to send a voice memo." (the web's "Tap to have a spoken conversation." named no control;
UX study 2026-10-19). At accessibility text sizes the glyph and Close share the top line and the words run full width
under them; the title is capped at 26 pt and the message at 24 pt, the card at about a third of the chat (a longer
message ends with "…") and never under the top bar. VoiceOver hears it once per app run; Close reads "Close Talk tip". Shown once, 700 ms after the chat settles, only while
Talk is the circle, no memo tip is waiting and the jump-to-latest button is hidden. It never times out. Closing it, or
tapping Talk, retires it. Off when Settings › Chat › In-App Tips is off.

**DECISION (builder, after the voice memo UI suite failed five tests).** The Talk tip is a glass card in the chat's
own view (`App/Chat/Voice/TalkTipBubble.swift`), not the popover the two memo tips use. A popover that shows by itself
takes the next touch outside it (Back, a memo's play disc, a notice's Close did nothing at the first tap) and makes the
screen refuse every sheet while it is up; the web's tip takes nothing (`W:src/ui-kit/tip.tsx`). The card sits above
the composer at the trailing edge, the transcript's end makes room for it (`makeRoomForTip` in
`W:src/ui-voice/voice-extras.tsx`), the Read Aloud strip sits above it, it steps aside while the circle is not Talk
or the jump-to-latest button shows (the web's `yieldTo`), and a memo tip that is earned replaces it for that visit.
Proof: `testE01b_TheTalkTipTakesNoTouch`, and the voice memo suite passing again.
Because the transcript's end moves up by the card's height (about 110 pt) shortly after a chat opens on a fresh
install, the activity suite, which measures that end to the point, launches with the tip marked seen
(`-hq.voice.tip.talk YES`, a marked line in `UITests/activity/ActivityEndToEndTests.swift`); with the tip on, its
`test18b` and `test31` measured the card's 110 pt. The other suites run with the tip showing.

**After a card leaves the composer's place (repair after stress round 1).** End on the dock, Done on a notice and an
answered question all hand the screen back to the composer, whose mic and circle land under the finger that just
tapped (End sits over the mic). For 0.8 s after any such card leaves, a touch that begins on the mic or on the circle is
taken by the composer and does nothing: no memo, no conversation, no send (`ComposerView.quietActions`, measured against
the touch's own timestamp, so a slow main thread cannot let the second tap through). The field, ☰ and + are not
affected, and VoiceOver's activation is not either. **DECISION**: 0.8 s, longer than a double tap (about 0.35 s between
taps) and short enough that the mic never feels dead; a tap on the mic a second or more after End is a tap on a mic the
person can see, and records hands-free as designed. The circle's accessibility frame is its 44 pt touch box, not the
40 pt drawing.

### 5.2 Voice options menu (row L531)

Web: `W:src/ui-voice/voice-menu.ts:51-64`. Native: a `UIMenu` built by `TalkMenus.options(for:)`.

Title: **Voice with <name>**

| Group | Item | Symbol | Behaviour |
|---|---|---|---|
| 1 | Start Voice Conversation | `waveform` | same as tapping Talk |
| 2 (inline) | Read Replies Aloud | `speaker.wave.2` | checkmark when on; the menu stays open (`.keepsMenuPresented`); toggles `hq.voice.readRepliesAloud` |
| 2 (inline) | Dictate with Hermes | `mic` | starts dictation (§8). When the gateway's Speech to Text is off: disabled, subtitle **Speech to Text is off** |
| 3 (inline) | How Voice Works | `info.circle` | the intro sheet in its info form (§5.3) |
| 3 (inline) | Voice Settings… | `gearshape` | Settings opens as its usual sheet (`SettingsScreens.presentSettings(from:services:then:)`) already on the Voice section |

Identifiers: `voice.options.start`, `.read-replies`, `.dictate`, `.how`, `.settings`.

"Speech to Text is off" is known from the config cached for the profile (§3.1, the lookup `MemoUploader.sttEnabled`
already makes). Unknown counts as on.

### 5.3 The one-time intro sheet (rows L530, L1011)

Web: `W:src/ui-voice/voice-menu.ts:18-30` and `W:ios/App/App/HermesVoice.swift:658-799`.

`TalkIntroSheet` is a page sheet with a grabber. Detents: one that fits its content, and large; only large at
accessibility text sizes, where the content scrolls. The system gives the sheet its glass.

Title (Title 2, bold): **Talk with <name>**

| Symbol | Title (Headline) | Body (Subheadline, secondary) |
|---|---|---|
| `waveform` | Just talk | Pause when you’re done, and <name> answers out loud. |
| `hand.raised.fill` | Interrupt anytime | Start talking or tap Interrupt to cut in. |
| `text.bubble` | It’s all in the chat | What you say and what <name> answers appear in the chat as messages. |
| `iphone` (`ipad`; `laptopcomputer` on the Mac) | Keeps going in the background | Lock your iPhone or switch apps and the conversation carries on. Quitting Hermes HQ ends it. (2026-10-28, Mac stress round 2 #42: was "Keep Hermes HQ open: The conversation stops if you lock your iPhone or switch apps", untrue since 3x-talk-background.md.) |

Info form only (How Voice Works), two more rows:

| Symbol | Title | Body |
|---|---|---|
| `mic` | Voice memos | Send Memo on Release on: "Hold the mic and talk, then let go to send. A quick tap records hands-free; tap Send when you’re done." Off: "Hold the mic and talk; letting go stops it, so you can play it back before you send. A quick tap records hands-free." |
| `pause.circle` | If a conversation pauses | A call, Siri or 2 minutes of silence pauses the conversation. Tap Resume in the message field; Copy Details shows what went wrong. (Leaving Hermes HQ no longer pauses it: 3x-talk-background.md.) |

(UX study 2026-10-19 #177: beside Voice memos, "voice" in these two rows read as either feature; they name the
conversation. The page, menu and button names, T21, T28 and §5.2, are unchanged.)

Buttons: **Start Talking** (prominent, full width, 50 pt) and **Not Now** (plain). Info form: one **Done**.
Pulling the sheet down is Not Now. Each row is one VoiceOver element reading "title. body". Rows have 12 pt of
vertical padding.

Rules:

- Shown when Talk is tapped and `hq.voice.introSeen` is not set. **Start Talking** sets the key and starts. **Not
  Now**, or pulling the sheet down, starts nothing and does **not** set the key, so the sheet is offered again on
  the next tap (`voice-menu.ts:22-25`: "Start Talking starts; Not Now or pulling it down doesn't").
- If the sheet cannot be presented (no window, another presentation in flight after one retry), voice starts anyway
  and the key is not set.
- From Settings the name is the bot the Settings page is scoped to ("Hermes" for the default profile).

### 5.4 The + menu: Voice Memo and Talk with <Bot> (row L389)

Web: `W:src/ui-chat/plus-menu.ts`: after the pickers come `Voice Memo` (`mic`) and `Talk with ${botName}`
(`waveform`, never in a room), then Paste Image, Link…, Folder…, Prompt Snippets…, More.

Native: `ComposerPlusMenu.register(.memo) { … }` and `ComposerPlusMenu.register(.talk) { … }` in `TalkWiring`.

| Item | Identifier | Does |
|---|---|---|
| Voice Memo | `composer.plus.memo` | `ChatViewController.beginMemo(handsFree: true)`: the locked, hands-free recorder (the web's `dispatch:memo-locked`) |
| Talk with <name> | `composer.plus.talk` | `beginTalk()` |

Both are left out (not disabled) when they could not work: Voice Memo when the composer's mic is not available;
Talk when `allowsTalk` is false. The chat is already on screen here, so the web's routing failures ("That chat
didn’t open.") cannot happen; a start that fails for a voice reason says so above the field (§5.7).

### 5.5 Bot row tile, Bot Info tile (rows L163, L214, L538)

Web: `W:src/ui-bots/bot-menu.ts` (tiles Talk · Memo · Pin; Talk and Memo disabled with the subtitle "Can’t reach this
bot" when the bot is unreachable) and `W:src/ui-bots/info-state.ts:138-143` (tiles Talk · Memo · Screen · Mute).
`W:src/ui-voice/entry-live.ts`: open the bot's chat, wait for its composer (retry every 100 ms up to 2.5 s), start.

Native:

```swift
BotMenuHooks.providers[.talk] = { bot, list in
    .action("Talk", "waveform", disabled: !reachable, subtitle: reachable ? nil : "Can’t reach this bot") {
        guard let bots = list as? BotsViewController else { return }
        bots.open(bot.id)
        M2Wiring.whenChatSettles(on: bots.navigationController, attempts: 30) { $0.beginTalk() }   // 100 ms × 30
    }
}
```

- `M2Wiring.whenChatSettles` is the helper the Memo tile already uses (`NAT:App/Integration/M2Wiring.swift:73`); it
  loses its `private`.
- The row menu already asks `.talk` first for its tiles (`NAT:App/Bots/BotsOrganizer.swift:71`), so the tile order
  becomes Talk · Memo · Pin as on the web.
- Unreachable bot (the gateway connection is not open; the condition `BotInfoModel.online` already uses): the tile
  is disabled with the subtitle "Can’t reach this bot". `BotMenuNode` (`NAT:App/Bots/BotListSections.swift:35`) gains
  `subtitle: String?`, drawn as the `UIAction`'s subtitle. The native Memo tile has no such state today; it gets the
  same rule in the same edit, because the two tiles sit side by side and the web disables both.
- Bot Info: `BotInfoTiles` gains **Talk** first (`bot-info.tile.talk`, `waveform`, disabled when `!model.online`),
  calling `BotInfoModel.talk()`, a copy of `memo()` with the `.talk` slot: the sheet closes, then the chat opens,
  then Talk starts. Shown when `model.talkAvailable` (`BotMenuHooks.providers[.talk] != nil`), the pattern of
  `memoAvailable`. The tiles keep their 10 pt spacing; the row's maximum width becomes 86 pt per tile (260 for three,
  344 for four), so the screen stream's tile between Memo and Mute fits without another layout change (§2.5).
- If the chat has not settled after 3 s, nothing starts and an alert says why, in the web's words
  (`W:src/ui-bots/bot-actions.ts:81`, `bot-actions.test.ts:66`): title **Couldn’t Start Talking**, message "<name>’s
  chat didn’t open.", button OK. A tile that silently did nothing would break the owner's rule about controls. If the
  person left the chat before it settled, nothing starts and nothing is shown.

### 5.6 Empty chat: the Talk and Bot Info capsules (row L209)

Web: `W:src/ui-bots/bot-intro.tsx`: 80 pt face, name, role (only when it differs from the name), description, then two
tinted capsules, **Talk** (`waveform`) and **Bot Info** (`info.circle`).

Native: `ChatPlaceholderView.Mode.empty` gains `role: String?`, `about: String?` and two actions.

- Under the name: the role (Subheadline, secondary) when it differs from the name; the description (Footnote,
  secondary, centred, up to 4 lines). "No messages yet. Say hello." stays as the last line when there is no
  description.
- Under the text, 16 pt lower: two capsules side by side, 10 pt apart, `UIButton.Configuration.tinted()` with a
  capsule corner style, 17 pt symbols, at least 44 pt tall: **Talk** (`chat.intro.talk`, VoiceOver "Talk with <name>")
  and **Bot Info** (`chat.intro.info`).
- Talk is left out when `allowsTalk` is false. Bot Info is left out for a chat that has no bot (a Sessions-tab
  chat of the default profile still has Hermes; a chat whose bot record is unknown has none).
- `hitTest` passes touches to the two capsules as it does to Retry today; everything else still falls through to
  the list.
- At accessibility sizes the capsules stack vertically.
- Bot Info opens the existing Bot Info sheet (`BotInfoSheet.present`).

### 5.7 Failures before a conversation exists

Shown in the existing glass notice card above the field (`MemoNoticeCard`, posted with
`MemoController.post(_:scope:)`), never an alert and never a toast (`W:src/ui-voice/voice-extras.tsx`: "above the
field… never as a toast"). Closing the card, or leaving the chat, dismisses it.

| Cause | Tone | Title | Message | Action |
|---|---|---|---|---|
| Microphone not allowed | warning | Microphone Access Is Off | Turn on Microphone for Hermes HQ in Settings to talk with <name>. | Open Settings |
| Speech to Text off (T26) | warning | Voice Unavailable | Speech to Text is off on your gateway. Turn it on in Settings › Voice › Speech to Text, then try again. | Voice Settings… |
| The engine did not start | error | Voice Didn’t Start | Couldn’t start microphone recording. (then iOS's own reason as the detail) | Try Again |
| No microphone at all | error | Voice Didn’t Start | No microphone was found. | — |
| App not on screen | info | Voice Didn’t Start | Talk starts while Hermes HQ is on screen, then keeps going when you leave. Tap Talk to start again. | — |

2026-11-06: these were headed "Voice Stopped" (nothing had started) and the last one read "Voice works while Hermes HQ
is on screen. Tap voice to start again.", untrue since a conversation goes on with the app away (3x-talk-background.md),
and no control is called "voice".

`MemoNotice.Action` gains `.voiceSettings` ("Voice Settings…"). The vendor strings are `V:i18n/en.ts:628-652`.

---

## 6. The dock, its notices and the away pill

### 6.1 The dock (rows L532, L533)

Web: `W:src/ui-voice/dock.tsx`, `W:src/ui-voice/dock-state.ts`. Desktop: `V:app/chat/composer/controls.tsx`
(`ConversationPill`, `ConversationIndicator`), `voice-activity.tsx`, `voice-fan.tsx`. The bar takes the composer's
place; the draft underneath is kept.

**Placement.** `ChatViewController` has a small arbiter around its one dock slot:

```swift
enum DockOwner: Int { case voice = 0, question = 1 }          // higher wins
func setDock(_ view: UIView?, for owner: DockOwner, animated: Bool)
```

It stores one view per owner and calls the existing `showPromptDock(_:animated:)` with the winner. **DECISION T12**.
A dock that is a `ComposerRowDock` (the conversation bar and the paused / stopped notice) is pinned **exactly where the
composer's row is**: 26 pt sides (plus the readable column's margin), 29 pt above the screen's bottom with the keyboard
down, 8 pt above the keys with it up; the cards docked above (queue card, memo notice) share those sides. The question
dock keeps its own 8 pt card place. The keyboard is dismissed when a dock appears. **Revised after build 305**: the
old card used the question dock's 8 pt place and in Desktop Look its bottom edge read as cut off by the screen.

**Look (revised after build 308: one row, the desktop's `ConversationPill`).** The owner looked at 308 on a phone
(Desktop Look, listening) and asked whether this was the best it could look: End stuck out past the box's right
border with round ends against the box's square corners, two stacked boxes were heavy, the slashed speaker (Speak
Replies off) read as "muted" beside the mic, the level showed twice, "Speaker" took room and the hint wrapped. The
approved design is one row. **Revised after build 404** (owner: "a lot of it is too long to show completely";
"the speaker icon isn't turning on the speaker"): the status is a word or two with the bot's name and the time on a
smaller line under it, and Speak Replies' place is now a real speaker button:

```
╭──────────────────────────────────────────────────────────────╮
│ ▂▅█▅▂ Speaking                 🔊   🎙   ✋  ╭─────╮    │   level · status          Speaker · Mute · Stop · End
│       Ivy · 0:03                            │ End │    │         name · time
╰─────────────────────────────────────────────╰─────╯────╯
```

- **One box** at the composer's own place (26 pt sides, 29 pt above the bottom, 8 pt above the keys): the composer's
  glass capsule in the default look (44 pt tall), the composer's one bordered box on the editor surface in the
  Desktop Look (the bar's row is 40 pt, its box 4 pt wider each side and 3 pt taller top and bottom, exactly as the
  composer's, 4 pt corners). Frames are set by hand from one measured plan (`TalkBarView.plan(width:)`), never by a
  stack view's required sizes: 308's overflow came from a horizontal stack whose controls all had required
  compression resistance and whose box was drawn from the row's frame, so wider controls (End with its indicator
  inset) ran past the box.
- **Left**: the state visual once (28 × 24, the five bars of the microphone's level while listening and the speaker's
  while the bot speaks; dots while thinking; the spinner while transcribing; flat and faint while muted), then two
  lines: the status (Subheadline, one line, the label colour; `TalkDockState.shortTitle`, so "Speaking", not "Ivy is
  speaking") and under it the bot's name (Footnote, secondary) then `· m:ss` (Footnote, monospaced digits,
  secondary). A long name is cut at its tail and gives way entirely under 24 pt; the time always shows. The box
  grows taller only if the two lines need more than End's height plus 8 pt (large text sizes). Every state's words
  show whole at 375, 402 and 440 pt in both looks (`TalkBarLayoutTests.theWordsShowWhole`).
- **The hint** "Go ahead. It sends when you pause." is the status for the **first listening turn of the first
  conversation ever** (`TalkListenHint`, key `hq.talk.listenHintSeen`, set once that turn ends or the bar leaves), in
  Footnote secondary on up to two lines inside the row, the time left out meanwhile; afterwards plain "Listening".
  Every state's hint (§6.2) is the status's VoiceOver hint; the status's VoiceOver label is always the state's title.
- **Right**, inside the box with its inner padding (4 pt default, 6 pt Desktop Look) on the top, bottom and trailing
  side: **Speaker** · **Mute** · **Stop** · **End**. The icon
  buttons are 34 pt (32 pt Desktop Look) with no gap, each answering in at least 44 × 44 pt (the nearer one wins
  where two meet). Stop's place is kept while Stop is hidden, so Mute never moves under a finger.
  - Speaker: on the phone's own route, `speaker.wave.2.fill` in the accent while the loudspeaker plays (every
    conversation starts there), `speaker.wave.2` in the label colour for the earpiece; a tap switches
    (`AudioSessionCoordinator.setLoudspeaker`). VoiceOver "Speaker", value On / Off, toggle-button trait. With
    headphones, Bluetooth, CarPlay or AirPlay it shows that route's glyph (`airpods`, `airpods.pro`, `airpods.max`,
    `headphones`, `car.fill`, `airplayaudio`), VoiceOver "Audio Output" with the route's name, and a tap opens the
    system's route picker (§6.5). No filled background: that is Mute's look when muted.
  - Speak Replies left the row (build 405); it is the first item of the long-press menu and in Settings › Voice. The
    status also has a VoiceOver action "Speak Replies".
  - Mute: `mic` (label colour); muted `mic.slash` on a tinted background, selected trait.
  - Stop: 308's rules: listening → `stop.fill` "Stop Listening and Send"; thinking → `stop.fill` "Stop"; speaking →
    `hand.raised.fill` "Interrupt"; left out while starting, transcribing, muted or reconnecting.
  - End: a tinted (accent) button with only the word "End" (Subheadline semibold), 36 pt (34 pt Desktop Look) tall.
    Its corners are concentric with the box's: a capsule inside the capsule (box radius = End's radius + padding); in
    the Desktop Look the box's 4 pt less the 6 pt padding is nothing, so End and a muted Mute take the desktop's
    smallest corner, 2 pt.
- **The line above** (the old strip) appears **only for a problem**: one turn's failure (label colour behind a small orange
  `exclamationmark.triangle.fill`: orange words on light glass were about 2.2:1; §6.4) with Copy Details (`doc.on.doc`), or the speech dropped while reconnecting (§6.2 row 6, secondary). Same look as the
  box (glass, radius 16; Desktop Look the outlined box), 8 pt above it. Paused and stopped notices (§6.3) are the
  separate notice dock, unchanged.
- **The loudspeaker** (`AudioSessionCoordinator`): a conversation plays on the loudspeaker unless something is
  plugged in or paired. After the session is activated, and on every route change while a conversation holds it, the
  coordinator sets `.defaultToSpeaker` to match the choice and overrides the output to the speaker if the route is
  still the receiver (or back to the receiver for the earpiece); any other output (headphones, Bluetooth, CarPlay,
  AirPlay) is left alone (`speakerOverride(outputs:loudspeaker:)`). GPT-Live's WebRTC sets the category again when its
  audio starts, so its configuration (`RTCAudioSessionConfiguration.setWebRTC`) also asks for `.defaultToSpeaker`;
  without both its replies came out of the earpiece. Each new conversation starts on the loudspeaker again.
- **The audio route** has no glyph of its own in the row (the speaker button takes its place). A long press on the
  bar (not on a button) opens a menu "Audio": Speak Replies (ticked when on), then the routes the session offers (`availableInputs`: the built-in one as "Speaker", then Bluetooth, a headset, CarPlay by
  name), the current one ticked, choosing one sets it as the preferred input; then "Other Outputs…", which presents
  the system's route picker (AirPlay, a speaker with no microphone). The status has a VoiceOver action "Audio
  Output" that opens the picker.
- **Accessibility sizes, or a row too narrow** (less than 44 pt left for the status: a 320 pt screen): the status
  wraps over the full width with the time under it, and the controls sit in a row under them, End at the box's
  bottom trailing corner with the same padding (the default box's radius becomes End's radius + padding). Buttons
  stop growing at AX Medium. Nothing is clipped (unit tests `TalkBarLayoutTests`).
- The bar is one accessibility container labelled "Voice conversation with <name>". Title and hint are **not** a live
  region; a VoiceOver announcement is posted only when the title changes, and never while the bot is speaking.

**Buttons.**

| Button | Glyph | Label | Haptic | Identifier |
|---|---|---|---|---|
| Mute | `mic` / `mic.slash` (tinted) | "Mute Microphone" / "Unmute Microphone", selected trait when muted | selection | `talk.dock.mute` |
| Stop | `stop.fill` / `hand.raised.fill` | "Stop Listening and Send" / "Stop" / "Interrupt" | listening: light impact; others: rigid | `talk.dock.center` |
| End | "End" | "End Voice Conversation" | medium impact | `talk.dock.end` |
| Speaker | `speaker.wave.2.fill` / `speaker.wave.2`, or the external route's glyph | "Speaker", value On / Off, toggle button; external: "Audio Output", value the route's name | selection | `talk.dock.speaker` |
| Copy Details | `doc.on.doc` | "Copy Details" | selection | `talk.dock.copy` |

Other identifiers: `talk.dock` (the bar), `talk.dock.title` (its label is the state's title even while the hint
shows), `talk.dock.elapsed`, `talk.dock.problem` (the line above). The probe (`talk.debug`) reports the state's hint
as `hint`.

**State visual** (`TalkVisualView`, drawn with five `CALayer` bars, no per-frame layout):

| State | Visual |
|---|---|
| Listening | five bars, weights 0.55, 0.85, 1, 0.85, 0.55; each height = `(0.25 + min(0.75, level × 1.4 × weight)) × 28 pt`; tint colour |
| Speaking | the same bars driven by the speaker's level: `(0.35 + 0.65 × weight × level) × 28 pt` |
| Thinking, Reconnecting, Starting | three dots that pulse in turn (still under Reduce Motion) |
| Transcribing | the system spinner |
| Muted | `mic.slash`, 24 pt, secondary colour |

Bars animate with a 90 ms ease so 30 level updates a second look smooth. Under Reduce Motion they still follow the
level (they are information, not decoration) but without the ease.

**Elapsed** counts from the moment the conversation started, across turns: `0:07`, `2:14`, `1:02:03`
(`formatElapsed`). Label "Elapsed 2:14". It ticks once a second from one timer in `TalkController`.

### 6.2 Every dock state and its words (row L533, L534)

`TalkDockState.view(status:muted:reconnecting:lostSpeech:silence:listened:name:)`, ported line for line from
`W:src/ui-voice/dock-state.ts:22-52`. First match wins.

| # | When | Title | Hint | Centre button |
|---|---|---|---|---|
| 1 | muted | **Muted** | <name> can’t hear you. Tap Mute to talk again. | Send Now, disabled |
| 2 | the gateway connection is not open | **Reconnecting…** | Waiting for your gateway. | Send Now, disabled |
| 3 | status transcribing | **Transcribing…** | Turning your words into text. | spinner, "Transcribing", disabled |
| 4 | status thinking | **Thinking…** | <name> is working on it. Talking now interrupts. | `stop.fill`, **Stop** |
| 5 | status speaking | **<name> is speaking** | Start talking or tap Interrupt to cut in. | `hand.raised.fill`, **Interrupt** |
| 6 | listening, and the last take was dropped while reconnecting | **Listening** | Didn’t send what you said while reconnecting. Say it again. | `arrow.up`, **Send Now** |
| 7 | listening, 30 s without speech | **Still Listening** | Talk when you’re ready, or tap End. | `arrow.up`, **Send Now** |
| 8 | listening | **Listening** | Go ahead. It sends when you pause. | `arrow.up`, **Send Now** |
| 9 | idle between takes, after the first take | **Listening** | Go ahead. It sends when you pause. | Send Now, disabled |
| 10 | idle before the first take | **Starting…** | Getting the microphone ready. | Send Now, disabled |

With barge-in off (`voice.barge_in: false`) the hints of rows 4 and 5 drop the part that is no longer true:
"<name> is working on it." and "Tap Interrupt to cut in." **DECISION** (the web keeps the full sentence; a hint
that promises something that will not happen is a bug).

**Row L534, word for word.** A take that began or ended while the gateway connection was not open is never
transcribed and never sent (§4.2 rule 4; `W:src/ui-voice/conversation-guard.ts`). The dock shows row 2 while the
connection is down and row 6 the next time it listens. Row 6 clears when the next take reaches Transcribing.

### 6.3 Paused and stopped (row L535)

Web: `W:src/ui-voice/dock.tsx:171-214`, `dock-state.ts:74-95`, `W:src/ui-voice/voice-dock-notice.ts`.

When a conversation ends for a reason the person did not choose, the dock is replaced **in the same place** by a
notice dock (`talk.notice`). It stays until the person acts. It is kept for its chat while the app runs: leave the
chat and come back and it is still there (T14). Starting a conversation anywhere clears it.

```
┌──────────────────────────────────────────────────────────────┐
│ ⏸  Voice Paused                                          ⧉   │
│    Paused after 2 minutes of silence. Your chat with Ivy     │
│    is saved.                                                 │
│    <detail, when there is one: Footnote, selectable>         │
│  [        Resume        ]      [         Done         ]      │
└──────────────────────────────────────────────────────────────┘
```

- Icon: `pause.circle.fill` in orange for paused, `exclamationmark.triangle.fill` in red for stopped.
- Title (Headline), message (Subheadline), detail (Footnote, secondary, a selectable text view that scrolls inside
  itself once it passes 120 pt, so nothing is ever cut off: the owner's "I can't read what it is").
- Buttons: the primary one (prominent glass) is **Resume**, **Try Again** or **Open Settings**, then **Done**, in
  two equal columns; they stack vertically at accessibility sizes or when a title would be cut. **Copy Details** is a
  44 pt `doc.on.doc` icon beside the title (label "Copy Details"; a tick labelled **Copied** for 2 s), on every
  notice: a diagnostic, not a third pill as heavy as Resume (UX study 2026-10-19 #44: three pills stacked at the
  default size).
- Haptic when it appears: warning for paused, error for stopped. VoiceOver reads the title and message once.
- Identifiers: `talk.notice.title`, `.message`, `.detail`, `.primary`, `.copy`, `.done`.

| Button | Does |
|---|---|
| Resume, Try Again | clears the notice and starts a new conversation in this chat (an explicit start always clears a stale pause: `MEM:ios-native-ux-goal.md`) |
| Open Settings | opens the app's page in iOS Settings; the notice stays |
| Copy Details | copies title, message and detail, one per line (`noticeText`) |
| Done | clears the notice; the composer returns |

### 6.4 Every pause and stop, with its words

`pausedNotice(cause, name, detail)`: title **Voice Paused**, message "<why> Your chat with <name> is saved.", action
Resume.

| Cause | <why> | Raised when |
|---|---|---|
| interrupted | A call or Siri took the microphone. | `AVAudioSession.interruptionNotification` began; media services were reset (detail "iOS reset its audio services") |
| background | Voice stops when Hermes HQ leaves the screen. | ~~the scene left the foreground (lock, Home, app switcher)~~ no longer raised (3x-talk-background.md); only the `paused-background` screenshot state shows it |
| silence | Paused after 2 minutes of silence. | `SilenceClock` reached 120 s |
| route lost | The headset or microphone disconnected. | a route change removed the input and no input is left; or the engine's configuration changed and it could not restart |

~~Losing the microphone within 3 s of leaving the screen counts as "background", not a call
(`W:src/audio-lifecycle.ts`).~~ 2026-11-06: a call or Siri keeps its own notice even when the app leaves the screen
right after (a full-screen incoming call does that); "Voice stops when Hermes HQ leaves the screen" is no longer true. A headset that disconnects while the built-in microphone is still there does not
pause: the engine restarts on the new route and the route button shows the new name.

`stoppedNotice(title, message, detail)`: the title is the failure's own (**Voice Transcription Failed**, **Voice
Playback Failed**, …) or **Voice Stopped** when there is none; the message only explains, so a message that starts with
the title has that prefix taken off (UX study 2026-10-19 #51: the title was said twice). Action **Open Settings** when the text is about the microphone being
denied, otherwise **Try Again**.

| Cause | Message | Detail |
|---|---|---|
| microphone permission taken away mid-conversation | Hermes HQ can’t use the microphone. Allow Microphone for Hermes HQ in iOS Settings. | — |
| the engine failed mid-conversation | Microphone failed. Could not start microphone recording. | the system error, code included |
| microphone busy | Microphone failed. Microphone is already in use by another app. | — |
| the meter failed twice (§4.2 rule 2) | The microphone isn’t giving a level, so Hermes HQ can’t tell when you stop talking. | — |
| transcription failed 3 times running (T15) | (title Voice Transcription Failed) <the gateway's last reason> | status code and body |
| the chat cannot send any more (session gone, signed out) | (title Voice Transcription Failed) This chat can’t send right now. | the refusal's text |
| speech could not be played at all (unplayable format, §3.4) | (title Voice Playback Failed) Your gateway’s voice uses a format iPhone can’t play (<mime>). Pick another Text to Speech provider in Settings › Voice. | — |

A single transcription failure or a single speech failure does **not** stop the conversation. The strip shows the
reason for that turn ("Voice Transcription Failed. <reason>" / "Voice Playback Failed. <reason>") in the warning
colour until the next state change, an error haptic plays, the reply stays in the chat as text, and the loop carries
on. **Revised after build 305** (a provider's raw error, its `wss://` address and tokens, filled 15 orange lines and
pushed the controls down): the reason is shown only when it reads as a sentence (one line, no address or key, at most
160 characters, `TalkDockState.shortReason`); otherwise the line is just "Voice Playback Failed." / "Voice
transcription failed." (the desktop's own headline, `voice.playbackFailed`), at most two lines either way. The whole
reason, scrubbed of addresses and keys (`VoiceReport.scrub`), is under the strip's Copy Details, followed by the
recent voice events. A stopped notice whose reason is raw takes the plain message "The computer running Hermes couldn’t
make the reply’s speech." / "The computer running Hermes couldn’t turn speech into text." (`HostWord`, the chat's
name for that machine) and carries the scrubbed reason as its detail.
Every notice's Copy Details also appends the recent voice events, so one with no detail of its own (the meter
failure) still copies what led to it.

### 6.5 The audio route (rows L539, L1011)

Web: the route's name under the elapsed time, refreshed every 4 s; a tap opens the system picker through a hidden
`AVRoutePickerView` (`W:ios/App/App/HermesVoice.swift:576-641`).

Native: `TalkRouteButton` shows the glyph `airplayaudio` (11 pt) and the route's name (Caption 1, tint) on the Read
Aloud strip, or (`compact`, the conversation bar, external routes only, §6.1) the route's own glyph, and has a
real `AVRoutePickerView` laid over it at the same size (its own glyph hidden with clear tint colours), so the
finger touches the system control and the system presents its picker. **DECISION T10**. The view is at least
44 × 44 pt in touch area.

Name (the web's mapping):

| Output port | Shown |
|---|---|
| built-in receiver | iPhone (the device's model name: "iPhone" or "iPad") |
| built-in speaker | Speaker |
| wired headphones | Headphones |
| Bluetooth (A2DP, HFP, LE), CarPlay, AirPlay | the port's own name ("Alex’s AirPods Pro") |
| anything else | the port's own name |

It refreshes on `AVAudioSession.routeChangeNotification` (no polling). VoiceOver: "Audio route: <name>. Choose
another". The same button is on the Read Aloud strip (§7.4) only when the route is not the built-in speaker.

### 6.6 The away pill (row L536)

Web: `W:src/ui-voice/away-pill.tsx`. A 44 pt capsule shown only while the conversation's chat (or the chat holding
a paused / stopped notice) is **not** the screen in front.

Native: `TalkAwayPill`, a glass capsule (`UIGlassEffect`, capsule corners) hosted in a pass-through overlay view on
the window's root controller, so sheets cover it and every pushed screen keeps it. **DECISION T11**: it floats; it is
not the tab bar's accessory.

- Position: centred, 44 pt tall, at most the screen's width minus 32 pt, its bottom 8 pt above the screen's bottom
  chrome. A screen reports that edge through `protocol TalkPillAnchoring { var talkPillBottomInWindow: CGFloat { get } }`:
  tab roots answer the tab bar's top; `ChatViewController` answers the top of everything above its composer (queue
  card, notice, shelf, question chip); anything else falls back to the safe area's bottom. While it floats over a
  chat, that chat's list gets 52 pt more bottom inset so the newest message is never under it.
- It slides and fades in 250 ms after the chat leaves the screen (so a quick back-and-forth does not flash it) and
  leaves the same way. Reduce Motion: fade only.

Live conversation:

| Part | Content |
|---|---|
| Leading | a green dot (system green, 8 pt). If a turn failed since the person left: `exclamationmark.triangle.fill`, 15 pt, orange, instead of the dot |
| Label | `<name> · <status> · <elapsed>`, for example **Ivy · Listening · 2:14**. Status words: Listening, Transcribing, Thinking, Speaking, Muted (idle reads Listening) |
| Tap | selection haptic; opens that chat (below) |
| Trailing | **End** (plain button inside the capsule, 44 pt tall): medium impact, ends the conversation. Label "End Voice Conversation" |
| VoiceOver (capsule) | "<label>. Return to the conversation" or "<label>. Voice had a problem. Return to the conversation" |

Paused or stopped notice waiting in a chat that is off screen:

| Kind | Leading | Label | Colour | VoiceOver |
|---|---|---|---|---|
| paused | `pause.circle.fill`, 17 pt | **<name> · Voice Paused · Tap for details** | orange glyph, label-colour text | "<name> · Voice Paused · Tap for details. Opens the chat" |
| stopped | `exclamationmark.triangle.fill`, 17 pt | **<name> · Voice Stopped · Tap for details** | red glyph, label-colour text | "<name> · Voice Stopped · Tap for details. Opens the chat" |

No End button on these; the chat’s notice dock has Done. The bot’s name leads, as on the live pill (UX study 2026-10-19 #52), and the text is label colour so it reads in dark (#53); the glyph alone carries orange or red.

Opening the chat: `NotificationHub.open(_ stored:profile:)` (the path a notification tap takes: it switches tab,
pops and pushes as needed, and does nothing when that chat is already in front). For a bot's chat that has no saved
id yet, `BotsViewController.open(bot.id)`; both return the same chat object because it is held in
`AppModel.awayChats`. **DECISION**: a conversation in a brand-new Sessions-tab chat that has no saved id yet ends
when that screen is left ("Voice chat ended"), because nothing could lead back to it.

For botslist: `TalkAwayPill.isShowing`, `TalkAwayPill.frameInWindow` and the notification
`hq.talk.pill.changed` (§2.5). Identifiers: `talk.pill`, `talk.pill.end`.

### 6.7 When a conversation ends

- The dock leaves, the composer returns with whatever was in it.
- When the person ended it (End, a stop phrase, a typed bare "stop", starting elsewhere): a centred caption above
  the composer, **Voice chat ended · 2:14** (Caption 1, secondary; `W:src/ui-voice/voice-extras.tsx`,
  `phone-ui-voice.css:223`). It is cleared when the chat leaves the screen, when a message is sent or when a new
  conversation starts. It is posted to VoiceOver once. Identifier `talk.ended`.
- A typed stop: while a conversation is live in this chat the composer is covered, so typing is impossible; the
  rule matters for a conversation in another chat and is kept for hardware keyboards: a bare stop phrase sent with
  no attachments while a conversation is live ends it and is not sent (`interceptsTypedVoiceStop`).

### 6.8 One microphone (row L537)

Web: `W:src/voice-conversation.ts:15`; `W:build/fe-voice-gates.ts` FE-012.

`TalkController.start(in:)` when a conversation is live elsewhere: ends it first (its chat shows nothing; its
"Voice chat ended" caption is not posted because that chat is off screen), clears any paused / stopped notice left
in any chat, then starts here. There is never a moment with two engines: the new capture is prepared only after the
old one's `shutDown()` returned.

Other microphone users:

| While a conversation is live | Result |
|---|---|
| the memo mic in another chat is pressed | the conversation ends first, then the memo records |
| a memo's play button or Read Aloud is tapped | T13: it plays, the conversation mutes itself. Read Aloud plays through the conversation's engine; while the conversation's own voice is playing it is refused with "The voice chat is speaking. Try again when it finishes." (2026-11-06: before, the tap did nothing at all) |
| Dictate with Hermes in another chat | the conversation ends first, then dictation starts |
| a memo is being recorded when Talk is tapped (possible from the + menu only when the recorder is not open) | the take becomes its draft chip, then Talk starts |
| the completion sound | already silent while voice holds the session (`NAT:App/Audio/CompletionCue.swift`) |

---

## 7. Read Aloud and Read Replies Aloud (rows L364, L365, L435, L540, L760)

`ReadAloudCenter.shared` owns all speech outside a conversation. It uses the same `TalkSpeaking` as the
conversation (stream first, clips as the fallback), under the `.speech` audio owner (§10.1): the `.playback`
category, so the silent switch does not mute it (`W:docs/voice-device-checklist.md`).

State: `idle`, `preparing(messageId)`, `speaking(messageId)`. `ReadAloudCenter.didChange` is posted on every change.

What is spoken: the reply's text parts in order, cleaned by `SpeechText.sanitizeForSpeech` (tables become their
headers, code blocks and URLs are dropped, links keep their words, emoji and Markdown marks are removed). Tool
steps, thinking and attachments are not read. A reply with nothing left to say: the button does nothing visible
except a failure alert "Couldn’t Read Aloud" / "There’s nothing to read in this reply."

### 7.1 The action row under the latest reply (row L364)

Web: Copy · Read Aloud · Regenerate · More, 44 pt icons, no labels (`W:src/ui-chat/composer.tsx`);
`V:…/assistant-message.tsx:1102-1161` for the button's three states.

Native: `ChatActionsCell` gains a second button; Regenerate and More move one 48 pt step to the right
(`RowLayout.actions` reserves four slots; when Regenerate is not offered, More takes its place as today).

| State | Glyph | Label | Tap |
|---|---|---|---|
| idle | `speaker.wave.2` (17 pt, secondary, like its neighbours) | Read Aloud | starts reading this reply |
| preparing (this reply) | the system spinner | Preparing audio | stops |
| speaking (this reply) | `stop.fill` in the tint colour, pulsing to 55 % opacity over 1.4 s (no pulse under Reduce Motion) | Stop reading | stops |
| another reply is being read | idle look | Read Aloud | switches to this reply (T30) |

Identifier `chat.read-reply`. Not shown while the reply still streams (the row itself is not shown then).

### 7.2 The message hold menu (row L365)

Web: reply tiles are Copy · **Read Aloud** (`speaker.wave.2`) · Share (`W:src/ui-chat/message-menu.ts`); while the
reply streams everything but Copy and Select Text is disabled with the subtitle "Still Replying".

Native: `MessageMenuItemID.readAloud`, a tile between Copy and Share on every assistant message (any reply, not only
the latest). Title **Read Aloud**; **Stop Reading** (`stop.fill`) while that reply is being read. Disabled with
"Still Replying" while it streams. Action identifier `message.readAloud`. Not on your own bubbles.

Row L365's other gap, React…, is the settings stream's; the title stays sender · time.

### 7.3 Read Replies Aloud in the chat's ⋯ menu (row L435)

Web: `W:src/phone-chat-menu-model.ts:48`: after Rename…, `Read Replies Aloud`, `speaker.wave.2`, on / off state, the
menu stays open.

Native: `ChatMenus.slotItems[.readAloud]` returns one `UIAction`: title **Read Replies Aloud**, image
`speaker.wave.2`, state `.on` / `.off`, attribute `.keepsMenuPresented`, identifier `chat.menu.read-replies`. It
toggles `hq.voice.readRepliesAloud`. Hidden in a group room.

### 7.4 Read Replies Aloud, the behaviour (rows L540, L760)

Web: `V:app/chat/composer/hooks/use-auto-speak-replies.ts`; `W:build/fe-voice-gates.ts` FE-019 ("only for the chat
on screen").

- Default **off** (`hq.voice.readRepliesAloud`, T6). One switch for the whole app, in three places that always
  agree: the ⋯ menu, the voice options menu, Settings › Voice › Text to Speech.
- When it is on, `ChatVoiceHost` watches the chat on screen. A reply that **completes while this chat is on screen**
  is read once. The reply that is already the latest when the switch is turned on, or when a chat is opened, is
  marked as heard and never read.
- A reply that completes in a chat that is not on screen is marked as heard and never read later.
- Several replies finishing while one is being read: only the newest is read next.
- Not during a conversation (the conversation speaks its own replies), not while a memo records, not while a
  dictation runs (the reply is read when the dictation ends if it is still the newest).
- Leaving the chat stops the reading. So does sending a new message, tapping Stop on the strip, or locking the phone.
- A failure shows the alert **Couldn’t Read Aloud** with the reason and does not turn the switch off.
- The warm-up lease `hqnative:read-aloud:<install id>` is held while the switch is on and a chat is on screen (§3.5).

### 7.5 The strip, and the highlight (row L540, T31)

While anything is read aloud in the chat on screen, a compact glass strip sits in the stack above the composer
(under the queue card and the memo notice):

| State | Content |
|---|---|
| preparing | spinner · **Preparing audio** · [Stop] |
| reading | small waveform (three bars following the level) · **Reading aloud** · route button when not on the built-in speaker · [Stop] |

Identifiers `read.strip`, `read.strip.stop`. Stop has a 44 pt touch area. The strip never appears during a
conversation (the dock says "<name> is speaking").

**Highlight.** The reply being spoken is marked in the list for Read Aloud, Read Replies Aloud and a conversation's
spoken reply alike (the web: `$speakingMessageId`, class `ios-speaking-reply`): a 3 pt tint bar at the reply's
leading edge that pulses with the same 1.4 s rhythm (steady under Reduce Motion), plus the tinted Stop glyph in its
action row when it has one. VoiceOver: the reply's label gains ", being read aloud". The bar is a decoration view on
the cell; it does not change the cell's height, so nothing in the list moves.

### 7.6 Failure wording

Alert title **Couldn’t Read Aloud**; message is the reason; buttons **OK** and, when there is raw detail, **Show
Details** (the web's failure alert, `W:src/ui-chat/composer.tsx`).

| Cause | Message |
|---|---|
| gateway unreachable | The computer running Hermes isn’t reachable right now. Try again when it reconnects. |
| the gateway answered an error | the gateway's `detail`, word for word |
| unplayable format | Your gateway’s voice uses a format iPhone can’t play (<mime>). Pick another Text to Speech provider in Settings › Voice. |
| no speech arrived for 15 s | The voice didn’t answer in time. Try again. |
| nothing to read | There’s nothing to read in this reply. |

---

**A reply to a paused conversation (repair after stress round 1).** While a "Voice Paused" or "Voice Stopped" notice
stands in the composer's place, a reply that completes in that chat is not read out by Read Replies Aloud (S-I2: no
audio after return); it counts as heard. Read Aloud on the reply still reads it. **DECISION**: the web has no such case
written down; reading a reply out beside "Voice stops when Hermes HQ leaves the screen" contradicts the notice.

### 7.7 Reading aloud always works: the iPhone's voice (owner, build 305)

Owner, on a real iPhone: Read Aloud and a conversation's spoken replies stopped with "Voice playback failed. TTS chunk 1
failed (edge): … 403 …" because the bot's profile had no `tts:` section, Hermes fell back to Edge and Microsoft refused.
"You've gotta get this to work where it's easy for people using the app." Hermes is not changed; the phone fixes it.

- **The computer's voice is always tried first** (the gateway's `tts.provider`, §3.3 then §3.4), unless the person chose
  iPhone Voice or the computer's voice failed for this gateway and profile in the last 30 minutes.
- **When it fails** the same speech session goes on with the iPhone's own voice (`TalkPhoneVoice.swift`,
  `AVSpeechSynthesizer.write(_:toBufferCallback:)`, public API) from the sentence that failed (a clip that failed and the
  one fetched behind it are read first; a stream that broke after audio skips about what was heard, 13 characters per
  second of audio, whole sentences only), or from the start when nothing played. Its PCM goes to the same
  `SpeechOutput` as the gateway's: inside the conversation's engine (voice processing cancels it, barge-in works) and on
  the level meter. A failure is: an error answer from either speech route (provider error, 4xx/5xx, unplayable audio),
  or **no audio at all 20 s after the reply is complete** (`VoiceWire.phoneVoiceAfter`, the one constant: Hermes makes a
  whole first sentence before any audio and a cold local voice can take 10–15 s; Read Aloud's own "didn't answer" waits
  10 s longer so the iPhone's voice always gets its turn). A connection that drops mid-reply also continues on the
  iPhone's voice, without a notice.
- **Remembered**: an error answer is remembered per gateway and profile for 30 minutes (`PhoneVoiceFallback`); later
  replies start on the iPhone's voice with no failing round trip, then the computer is asked again. A slow computer
  (the 20 s wait) is never remembered. Any save of the gateway's settings forgets it at once.
- **Told once**, per gateway and profile while the app runs, in the chat on screen: the one-line notice under the title
  (8 s) "Using the iPhone’s voice. <Bot>’s voice on your computer isn’t working." with **Fix…**, which opens Settings ›
  Voice › Text to Speech for that bot (its own profile's settings, `?profile=`) with Text to Speech Provider on top. No
  provider error text on screen; the scrubbed error (no address, query string or token) is in Voice Diagnostics' events.
- **Which voice**: the reply's language (NaturalLanguage; the person's own language for short text), then the best
  quality installed (premium, enhanced, default), then the person's region; novelty and Personal Voice never.
- **The explicit choice**: Settings › Voice › Text to Speech, under Read Replies Aloud, section **Voice**: Computer’s
  Voice (default) / iPhone Voice (`hq.voice.replyVoice`: `computer` / `iphone`, this device only, never written to the
  gateway). Footer: "Computer’s Voice uses the Text to Speech provider below, and the iPhone’s own voice when it isn’t
  working. iPhone Voice always reads on this device. Set on this device only." When only default-quality voices speak
  the person's language, a second line: "For a more natural voice, download an Enhanced voice in Settings ›
  Accessibility › Spoken Content › Voices." Search finds "iPhone Voice".
- Voice Diagnostics never uses the iPhone's voice (it tests the computer's).
- If the iPhone's voice fails too, the reading ends with the computer's reason (§7.6), as before.

## 8. Dictation (row L541)

Web: `V:app/chat/composer/hooks/use-voice-recorder.ts`, `V:app/chat/composer/voice-activity.tsx`,
`W:build/fe-voice-gates.ts` FE-009 and r1-22 ("trigger becomes Stop; × cancels"), and the phone's "Done" button.

Started only from the voice options menu ("Dictate with Hermes"), under the `.dictation` audio owner (§10.1).

**DECISION T32.** Dictation does not use the conversation's engine. `DictationRecorder` (`HermesKit/Voice/`) is an
`AVAudioRecorder` with the memo recorder's proven settings (AAC, mono, 24 kHz, metering on), behind a four-method
protocol `DictationCapturing` (`begin`, `finish`, `cancel`, `level`) with a fixture twin for tests. It needs no
voice processing and no end-of-speech detection, and a take at the 600 s limit is about 2.5 MB instead of 19 MB of
WAV. The file is sent with the call memos already use, `MemoUploader.transcribe(_:mime:profile:)`
(`NAT:HermesKit/Voice/MemoUploader.swift:260`), as `audio/x-m4a`.

**What the person sees.** The dictation row takes the field's place inside the field's own glass
(`ComposerView.recorderContent`, the slot the memo recorder uses), so ☰ and + hide as they do for a memo:

```
( ✕ )   ● Dictating  0:07   ▂▅█▅▂                [ Done ]    (■)
```

| Part | Detail |
|---|---|
| ✕ | 44 pt, label **Cancel dictation**: stops and throws the audio away. Nothing is typed. `dictation.cancel` |
| Glyph and title | `mic.fill` in tint and **Dictating**; while the words are fetched, a spinner and **Transcribing** |
| Elapsed | `0:07`, monospaced digits, updated 4 times a second |
| Level | five bars, weights 0.5, 0.78, 1, 0.78, 0.5, driven by the recorder's meter (the mapping the memo waveform uses) |
| Done | tint text button, at least 44 pt: stops and transcribes. Hidden at accessibility text sizes (the circle does the same). `dictation.done` |
| Primary circle | a tick (✓, not the square Stop a reply uses: UX study 2026-10-19 #47), label **Stop Dictation**: stops and transcribes. Tappable even while the chat is reconnecting. `composer.stop-dictation` |

The row is one status element for VoiceOver ("Dictating, 0:07"); it is not a live region.

**Flow.**

1. Start: permission (the same prompt and denial card as §5.7, with "to dictate" in place of "to talk with <name>"),
   `stt.enabled` check (off → the T26 card; the menu item is already disabled when the app knows), the lease of
   §3.5, `KeepAwake` hold `dictation`, selection haptic. 2026-11-06: a start still going after 0.4 s (the voice
   settings read from a slow gateway with nothing saved) shows the row with a spinner and **Starting…** ("Starting
   dictation" for VoiceOver); ✕ and the circle cancel it. A quick start never shows it.
2. The limit is `voice.max_recording_seconds` from the config, cut to whole seconds and clamped to 1…600
   (`use-voice-recorder.ts`: `max(1, min(trunc(n), 600))`); 120 when the key is missing. At the limit it stops and
   transcribes by itself. 2026-11-06: ten seconds before it (half of a shorter limit) the clock turns orange, as the
   memo recorder's does, a warning haptic is felt once and VoiceOver says "N seconds left" (it had stopped with no
   warning).
3. Stop / Done / limit: the row shows Transcribing; `POST /api/audio/transcribe` (§3.2).
4. Words back: trimmed and inserted into the field at the cursor (a space is added when the text before it does not
   end in white space). The field becomes first responder with the keyboard up. Success haptic.
5. Empty words: card **No Speech Detected** / "Try recording again." (warning, Try Again starts a new dictation; no Copy Details, there is nothing to copy), field unchanged.
6. Failure: card **Voice Transcription Failed** / the gateway's reason (error, Try Again starts a new dictation).
   A recording that could not start: **Voice Recording Failed** / the reason.
7. Always at the end: lease released, keep-awake released, audio session released, the take's file deleted.

**Interactions.** Dictation is cancelled (audio thrown away, no card) when: the chat leaves the screen, the app
leaves the foreground, a conversation starts anywhere, a question dock takes the composer's place, a call
interrupts. 2026-11-06: once Done was tapped (Transcribing) the microphone is finished with, so a call, Siri or the app
leaving no longer throws the words away: they land in the field when they come back. A reply arriving during dictation changes nothing (the circle stays Stop Dictation; the reply's own Stop
is back when dictation ends).

---

## 9. Settings › Voice and Voice Diagnostics (rows L410, L542, L543, L760, L761, L762, L773)

### 9.1 Where it is

Web: Settings section `voice` ("Voice", icon Mic) between Memory and Advanced
(`V:app/settings/constants.ts:761`), with three pages (`V:app/settings/config-subpages.ts:71-80`) that the phone
build titles **Voice Conversation**, **Speech to Text**, **Text to Speech** (`W:build/fe-platform-gates.ts:355`).

Native:

- `ConfigCatalog.sections` gains `ConfigSection(id: "voice", title: "Voice", symbol: "mic", keys: <§9.2>, pages: […])`
  between `memory` and `advanced`, so the row appears in Settings' **Hermes** list in the web's order
  (`settings.config.voice`), and Settings search indexes its pages and fields with no further code.
- Its three pages are custom pages (`ConfigCatalog.customPages` gains `voice.conversation`, `voice.transcription`,
  `voice.speech`; `ConfigScreens.makePage` returns the views of `VoiceSettingsPages.swift`).
- **DECISION**: when the app has no gateway settings to show (`model.configStore == nil`: signed out, or the first
  read has not answered), the Voice row still appears, alone in its own group, and opens the same three pages. The
  rows that belong to this iPhone work; the gateway's rows show the store's usual loading or failure state. The
  web cannot do this (its whole Voice page needs the gateway); this iPhone's own switches should not depend on a
  connection.
- Rows follow the house rule: 12–14 pt of vertical padding on anything that wraps, the control at the trailing edge
  with a 16 pt gap (`MEM:row-padding-feedback.md`).

### 9.2 What each page holds

**Voice Conversation** (`voice.conversation`). On a phone the gateway has no setting on this page (its three keys are
hidden, below), so it holds the phone's own rows, in the web's order (`W:src/voice-settings.tsx`):

| Row | Kind | Words |
|---|---|---|
| Note (top footer text) | text | To talk with a bot, tap Talk, the round button next to the message field. |
| How Voice Works | row with chevron | hint: "Talking with a bot, voice memos, and what to do when a conversation pauses." Opens §5.3 in its info form. `voice.settings.how` |
| Send Memo on Release | switch, default **on** | "When this is off, letting go stops the recording so you can play it back before sending." Writes `hq.voice.sendOnRelease` (the key the memo code already reads). `voice.settings.send-on-release` |
| Memo note | text | on: "Voice memos: hold the mic to record, let go to send. Tap it to record hands-free. Type by voice with the keyboard’s mic." off: "Voice memos: hold the mic to record, let go to play it back before you send. Tap it to record hands-free. Type by voice with the keyboard’s mic." |
| Voice Diagnostics | row with chevron | hint: "Test the microphone, playback and transcription, and copy what iOS reports about audio." Opens §9.4. `voice.settings.diagnostics` |

**Speech to Text** (`voice.transcription`), gateway fields through `GatewayConfigStore`:

| Key | Label | Control |
|---|---|---|
| `stt.enabled` | Speech to Text | switch. "Turns voice messages and dictation into text." |
| `stt.provider` | Speech to Text Provider | picker: local, groq, openai, mistral, xai, elevenlabs (shown in their makers' names, below) |
| `stt.local.model`, `stt.local.language` | Local Transcription Model, Transcription Language | only when the provider is local. Models: tiny, base, small, medium, large-v3 |
| `stt.openai.model` | OpenAI STT Model | only for openai: whisper-1, gpt-4o-mini-transcribe, gpt-4o-transcribe, gpt-transcribe |
| `stt.groq.model` | Groq STT Model | only for groq (free text) |
| `stt.mistral.model` | Mistral STT Model | only for mistral: voxtral-mini-latest, voxtral-mini-2602 |
| `stt.elevenlabs.model_id`, `.language_code`, `.tag_audio_events`, `.diarize` | ElevenLabs STT Model, ElevenLabs Language, Tag Audio Events, Speaker Diarization | only for elevenlabs. Models scribe_v2, scribe_v1. Language: "Optional ISO-639-3 language code. Blank lets ElevenLabs auto-detect." |
| `stt.echo_transcripts` | Echo Transcripts | switch. "Post the transcript of each voice message back to the chat." |
| `voice.max_recording_seconds` | **Max Dictation Length** | number, 1…600. "Dictation stops and transcribes after this many seconds (up to 600)." |

**Text to Speech** (`voice.speech`):

| Key | Label | Control |
|---|---|---|
| (this iPhone) | **Read Replies Aloud** | switch, default **off**, first row. "Speaks each new reply in the chat on screen with the voice below. Set on this device only." `voice.settings.read-replies` |
| `tts.provider` | Text to Speech Provider | picker: edge, elevenlabs, openai, xai, minimax, mistral, gemini, neutts, kittentts, piper (and deepinfra when the schema lists it) |
| `tts.edge.voice` | Edge Voice | only for edge |
| `tts.openai.model`, `tts.openai.voice` | OpenAI TTS Model, OpenAI Voice | only for openai |
| `tts.elevenlabs.voice_id`, `.model_id` | ElevenLabs Voice, ElevenLabs Model | only for elevenlabs. The voice picker is filled from `GET /api/audio/elevenlabs/voices` (labels shown, ids stored); a free text field when that answers `available: false` or fails |
| `tts.xai.voice_id`, `.language`, `.speed`, `.auto_speech_tags`, `.optimize_streaming_latency`, `.sample_rate`, `.bit_rate` | xAI (Grok) Voice, xAI Language, xAI Playback Speed, xAI Auto Speech Tags, xAI Streaming Latency Optimization, xAI Sample Rate, xAI Bit Rate | only for xai |
| `tts.minimax.model`, `.voice_id` | MiniMax TTS Model, MiniMax Voice | only for minimax |
| `tts.mistral.model`, `.voice_id` | Mistral TTS Model, Mistral Voice | only for mistral |
| `tts.gemini.model`, `.voice` | Gemini TTS Model, Gemini Voice | only for gemini |
| `tts.neutts.model`, `.device` | NeuTTS Model, NeuTTS Device | only for neutts. Device: "Local inference device for NeuTTS." |
| `tts.kittentts.model`, `.voice` | KittenTTS Model, KittenTTS Voice | only for kittentts |
| `tts.piper.voice` | Piper Voice | only for piper |
| `tts.deepinfra.model`, `.voice` | DeepInfra TTS Model, DeepInfra Voice | only for deepinfra |
| `voice.auto_tts` | **Voice Replies on Messaging Apps** | switch, last row. "Messaging apps (Telegram, Discord…) answer voice messages with a spoken reply. To hear replies in Hermes HQ, turn on Read Replies Aloud above." |

Rules:

- Labels, descriptions and option lists are the vendor's (`V:app/settings/constants.ts` and `V:i18n/en.ts`) with the
  phone build's rewrites, added to `ConfigCopy.labels`, `.descriptions`, `.enumOptions`. Every voice and model key
  is also in `ConfigCopy.freeInputKeys`, so a value the lists do not know is shown and kept, never replaced.
- **Makers' names** (`W:src/voice-settings.tsx` `VOICE_PROVIDER_LABELS`), added to `ConfigCopy.optionLabels` for
  `stt.provider` and `tts.provider`: xAI, OpenAI, ElevenLabs, Groq, Mistral, **Local (Your Computer)**,
  Microsoft Edge, Google Gemini, MiniMax, NeuTTS, KittenTTS, Piper, DeepInfra.
- A field shows only when the schema or the saved record has it, as on every other config page. Provider fields
  show only for the provider that is selected now (`V:app/settings/voice-provider-fields.tsx`); changing the
  provider swaps them with the list's own row animation.
- Saving is the store's existing debounced `PUT /api/config {"config": {…}}`, with its existing failure banner and
  Retry.
- **Never shown** (`W:build/voice-gates.ts` `voiceFieldVisible`): any key whose name matches `wake` or `stop_word`
  (any case), `voice.client_direct`, `voice.voice_chat_mode`, `voice.gpt_live.voice`, `voice.gpt_live.instructions`,
  and any other `voice.gpt_live.*`. They are filtered in `ConfigCatalog` (not only left out of the curated list), so
  search cannot find them either. This is row L546.
- Search (`SettingsSearch.appRows`): "Read Replies Aloud" (context "Text to Speech"), "Voice Diagnostics" (context
  "Voice Conversation") as on the web, plus "Send Memo on Release" and "How Voice Works" (context "Voice
  Conversation"). Each opens its page.

### 9.3 Switch behaviour

| Switch | Key | Effect, at once |
|---|---|---|
| Send Memo on Release | `hq.voice.sendOnRelease` (default true) | the next held memo sends on release, or stops into review (`MemoController.sendOnRelease`). The memo note under it and the intro's memo row change with it |
| Read Replies Aloud | `hq.voice.readRepliesAloud` (default false) | §7.4. The ⋯ menu and the voice options menu show the same state. Turning it off stops a reading in progress |

Both post a `UserDefaults` change that `ChatVoiceHost` observes; no relaunch is needed.

### 9.4 Voice Diagnostics (rows L543, L762)

Web: `W:src/voice-diagnostics.tsx`, `W:src/voice-events.ts`, `W:src/voice-report.ts`.

A pushed page titled **Voice Diagnostics** (small title on the bar row). Leaving it ends a test in progress.

Intro: "Record a short test and play it back. If voice misbehaves, copy the report at the end of this page."

Three glass buttons in a row (stacked at accessibility sizes):

| Button | While running | Enabled when |
|---|---|---|
| **Record 3 s** | **Recording…** | nothing else is using the microphone |
| **Play** | **Playing…** | a test take exists |
| **Transcribe** | **Transcribing…** | a test take exists and the gateway is connected |

Status line under them (one line of Subheadline, wraps):

| When | Text |
|---|---|
| start | Transcribe sends the test recording to your Speech to Text provider. |
| recording | Recording 3 seconds… |
| recorded | Recorded 94 KB (audio/wav) from “iPhone Microphone”. |
| record failed | Recording failed: <reason> |
| microphone not allowed | Allow the microphone in Settings (with an **Open Settings** button beside it) |
| microphone busy | Voice is in use. End the conversation, memo or dictation to run a test. |
| played | Played 3.0 s. |
| play failed | Playback failed: <reason> |
| transcribed | Transcribed: “hello testing one two” |
| transcribed, nothing heard | Transcribed: (no speech detected) |
| transcribe failed | Transcription failed on the gateway. / Transcription failed: <reason> |

Section **Right Now**, refreshed once a second while the page is on screen (**DECISION T18**: native facts). The
page shows each row by its Title Case name (`VoiceAudioFacts.displayNames`) and starts each value with a capital
("Not Active", "Yes (2 holds)"); the copied report keeps the original names and values below.

| Row (report) | On the page | Values |
|---|---|---|
| Microphone permission | Microphone Access | allowed · not asked · denied |
| Audio session | Audio Session | not active · "playAndRecord, default" · "playback, spokenAudio" |
| Audio in use by | Audio In Use By | nothing · voice memo · memo playback · conversation · dictation · read aloud · diagnostics |
| Microphone running | Microphone On | yes · no |
| Voice processing | Echo Cancellation | on · off · unavailable |
| Voice paused | Voice Paused | no · the cause of a notice that is waiting ("silence", "interrupted", "background", "route lost") |
| Input route | Input | the input port's name, or "none" |
| Output route | Output | the route name of §6.5 |
| Screen kept awake | Screen Kept Awake | no · "yes (1 hold)" · "yes (2 holds)" |
| Voice memo recording | Recording a Memo | yes · no |

Section **Recent Audio Events**: the last 30, newest first, `HH:mm:ss  event`; "None yet." when empty. Logged by
`VoiceEvents.note(_:)`: session taken and released (with the owner), interruption began and ended (with iOS's
reason), route changes (reason, new route), media services reset, engine started, stopped and reconfigured, take
began and ended (length, speech heard or not), transcription answered or failed (milliseconds), speech started,
ended and fell back, barge-in, pause and stop causes, keep-awake holds, lease failures. Never the words that were
said, never a gateway address, never a token.

Footer button **Copy Report** → **Copied** for 2 s. The report is plain text:

```
Hermes HQ voice diagnostics
Time: 2026-10-11T03:12:45Z
App: Hermes HQ 1.0 (251) · iPhone17,1 · iOS 27.0
Microphone permission: allowed
Audio session: not active
…one line per row above…
Test: Recorded 94 KB (audio/wav) from “iPhone Microphone”.
Recent audio events:
  03:12:41 session taken by diagnostics
  03:12:44 take ended 3000 ms
```

The first line uses the bundle's display name. Identifiers: `voice.diag.record`, `.play`, `.transcribe`,
`.status`, `.copy`, `voice.diag.row.<n>`.

The test take is recorded with `TalkCapturing` (so it tests the engine a conversation uses), played with
`AVAudioPlayer` under the `.speech` owner, and transcribed with §3.2.

---

## 10. Audio session and keep awake (rows L544, L1010, L1012)

### 10.1 Audio session (row L1010)

Web: `W:ios/App/App/HermesPlatform.swift:930` (the conversation's category) and `W:src/audio-session.ts`,
`audio-lifecycle.ts`, `voice-runtime.ts` (pause reasons).

`AudioSessionCoordinator.Owner` becomes `memoRecording, memoPlayback, conversation, dictation, speech, diagnostics`.

| Owner | Category, mode, options | Notes |
|---|---|---|
| `conversation` | `.playAndRecord`, `.default`, `[.allowBluetoothHFP, .defaultToSpeaker]` | as the web. Voice processing is on the engine, not the session mode. If device testing shows echo or low volume, the one place to change is `TalkEngineCapture.sessionMode` (to `.voiceChat`); see §17 |
| `dictation`, `diagnostics`, `memoRecording` | the same as today's `memoRecording` | |
| `speech`, `memoPlayback` | `.playback`, `.spokenAudio` | plays with the silent switch on |

Rules added to `acquire(_:)`:

1. `conversation` pre-empts every other owner (their `onPlaybackPreempted` / cancel paths run first).
2. While `conversation` holds the session, `acquire(.memoPlayback)` and `acquire(.speech)` succeed **without
   changing the category** ("borrowed"); releasing a borrower leaves the session alone. `TalkController` is told and
   mutes itself (T13).
3. `memoRecording` or `dictation` requested while `conversation` holds: `TalkController.end(.replaced)` first.
4. Every acquire, release and failure is a `VoiceEvents` line.
5. (m9 review) Any other owner that takes the session from `memoRecording`, `dictation` or `diagnostics` ends that
   recording first through `onRecordingPreempted`, a player too (Read Aloud tapped during a hands-free memo or a
   dictation): the memo becomes its draft chip, the dictation is thrown away, the diagnostics take ends. Without it
   the category changed to `.playback` under a running recorder, which went on "recording" dead air. **DECISION**:
   the tap wins, as a conversation does in rule 1; refusing the tap would be a button that does nothing.

System events, observed once in `TalkController`:

| Event | Result |
|---|---|
| `AVAudioSession.interruptionNotification`, began | the conversation ends with `pausedNotice(.interrupted)`; detail "interruption began" and iOS's reason. ~~If the scene enters the background within 3 s, the cause is rewritten to `.background`~~ (not since background Talk) |
| interruption ended | nothing restarts. The notice's Resume does |
| `UIScene.didEnterBackgroundNotification` | ~~ends with `pausedNotice(.background)`~~ a live conversation goes on (3x-talk-background.md). Dictation is cancelled, Read Aloud stops. **DECISION**: not `willResignActive`, because Control Centre, a notification banner pulled down and the route picker all resign active without leaving the app |
| `routeChangeNotification`, old device unavailable | input still present → restart the engine on the new route (one retry), keep talking. No input left → `pausedNotice(.routeLost)` |
| `AVAudioEngineConfigurationChange` | restart the engine (one retry); failing that `pausedNotice(.routeLost)` with the error as detail |
| `mediaServicesWereResetNotification` | `AudioSessionCoordinator.reset()`, then `pausedNotice(.interrupted)` with detail "iOS reset its audio services" |
| returning to the foreground | nothing restarts by itself. A start always begins clean: there is no stored "paused" flag that could block it (`MEM:ios-native-ux-goal.md`) |

~~No `UIBackgroundModes audio` (T29).~~ 2026-10-27: `audio` is on so a live conversation goes on with the app away; the scene event above no longer ends it (3x-talk-background.md).

### 10.2 Keep awake (rows L544, L1012)

Web: `W:src/voice-keep-awake.ts`; `W:build/fe-voice-gates.ts` FE-008; `W:ios/App/App/HermesPlatform.swift:771`.

```swift
@MainActor enum KeepAwake {
    enum Owner: Hashable { case memo(String), dictation, conversation, turn(String), diagnostics }   // String = chat scope
    static func hold(_ owner: Owner, cap: TimeInterval? = nil)
    static func release(_ owner: Owner)
    static func appLeftScreen()          // releases capped holds; uncapped ones end with their feature
    static var count: Int { get }
}
```

`UIApplication.isIdleTimerDisabled` is written only when the number of holds crosses zero.

| Owner | Held | Released |
|---|---|---|
| `memo(scope)` | while that composer records a memo (replaces the two direct writes in `MemoRecorder.swift:214-215,363`) | take ended, cancelled or interrupted |
| `dictation` | from start to the transcript | always, in the `defer` of the flow |
| `conversation` | from `start` to `ended`, wherever the person is in the app | `ended`, including every pause and stop |
| `turn(scope)` | while a reply is running **and that chat is on screen**, capped at **10 minutes** | the turn ends; the chat leaves the screen; the app leaves the screen; the cap. Taken again (with a fresh cap) when the chat comes back and the turn still runs |
| `diagnostics` | during the 3 s test | test ended |

`ChatViewController` takes and drops `turn(scope)` from `viewDidAppear`, `viewDidDisappear` and its existing
running-state change. `appLeftScreen()` is called on `didEnterBackground`.

---

## 11. Audio in the composer tray plays in a preview sheet (row L411)

Web: `W:src/phone-audio-preview.tsx`: a tapped audio chip opens the preview sheet with a glyph (Mic for a memo,
AudioLines otherwise), the title ("Voice memo · 0:04" or the file's name) and a player. Statuses "Loading…" and
"Couldn’t load this recording." Local recordings are read from the phone; gateway ones stream.

Native today: `ChatAttachmentsController.trayOpen` sends every non-image file to Quick Look.

Change: an attachment whose type conforms to `UTType.audio` (and the memo draft chip's "open" action) presents
`AudioPreviewSheet`. **DECISION T24**.

- A page sheet with a grabber and one detent that fits its content; title bar with **Done**.
- Centre: the glyph (`mic` for a memo, `waveform` otherwise; 34 pt, tint), the title (Headline; "Voice memo · 0:04"
  uses the memo code's existing title; any other file shows its name, middle-truncated), the size and kind
  underneath (Footnote, secondary: "128 KB · M4A audio").
- Player row: a 44 pt play / pause button, a scrubber, elapsed and total time in monospaced digits. It drives
  `MemoPlayer.shared` (`play(_:from:resolve:)`, `toggle`, `seek`), so it is the one player in the app: starting it
  stops a memo bubble that is playing and the other way round, and T13 applies during a conversation.
- States: **Loading…** (spinner) until the player is ready; **Couldn’t load this recording.** when `MemoPlayer`
  reports `failed` (with the reason underneath in Footnote).
- Closing the sheet stops the playback it started.
- Source: `.local(URL)` today. `.gateway(path:profile:)` is accepted too and resolved with the resolver memo bubbles
  use (`/api/fs/download`), ready for the composer stream's Folder… picks.
- Identifiers: `audio.preview`, `audio.preview.play`, `audio.preview.scrubber`, `audio.preview.status`.

---

## 12. The stand-in gateway

### 12.1 What is added to `scripts/fixtures/voice-gateway.py` (T20)

Stdlib only, as today. Nothing existing changes shape, so `scripts/e2e-voice.sh` keeps passing (it is rerun as part
of this stream's acceptance).

Port guard becomes: allowed without the override are 9726–9728 (memo stream) **and 9900–9909** (this stream).

| Route | Behaviour | Controls (`POST /__fixture/voice`) | Ledger (`GET /__fixture/voice-state`) |
|---|---|---|---|
| `POST /api/audio/transcribe` (exists) | as today | new: `transcripts: ["…", "…"]` (a queue, one per call, then falls back to `transcript`), `transcribeFailTimes: n` (fail the next n calls with `transcribeFail`'s status and detail) | each call gains `seconds` (measured from the WAV), `sampleRate`, `channels`, `keys` (the body's keys), `at` |
| `POST /api/audio/speak` | answers `{ok, data_url, mime_type: "audio/wav", provider: "fixture"}`: a 440 Hz tone, `0.06 s × characters` long (at least 0.4 s). `400 {"detail": "Text is required"}` for empty text | `speakDelay` (s), `speakFail: {status, detail}`, `speakMime` (for example `"audio/ogg"`: the body is then labelled so and is not playable) | `speaks: [{profile, text, keys, at}]` |
| `WS /api/audio/speak-stream` | its own upgrade and frame code (text **and** binary frames; the base helper only handles text on `/api/ws`). Accepts any `ticket` the sign-in minted. On the first `{"text"}`: `{"type":"start","sample_rate":24000,"channels":1}`. Each text chunk becomes a tone of `0.06 s × characters`, sent as 100 ms binary frames in real time. `{"done":true}` → the rest, then `{"type":"end"}`. `{"stop":true}` → stops at once and closes | `streamMode`: `"ok"` (default), `"fallback"` (answers `{"type":"fallback"}`), `"refuse"` (closes 4401 before anything), `"drop"` (closes without a close frame after `streamDropAfterMs` of audio), `"silent"` (accepts and never answers); `streamStartDelay` (s); `streamPace` (1 = real time, 0 = as fast as possible) | `streams: [{profile, texts: […], done, stopped, bytes, closedBy, at}]` |
| `POST /api/audio/tts-lease`, `POST /api/audio/stt-lease` | `{ok: true, lease, active, leases: […]}`; `400 {"detail": "lease is required"}` | `leaseFail: true` (answers 500) | `leases: {tts: […held now…], stt: […]}`, `leaseCalls: […]` |
| `GET /api/audio/elevenlabs/voices` | `{available: true, voices: [{label: "Rachel", name: "Rachel", voice_id: "21m00Tcm4TlvDq8ikWAM"}, {label: "Adam", name: "Adam", voice_id: "pNInz6obpgDQGcFmaJgB"}]}` | `elevenVoices`: `"ok"`, `"unavailable"`, `"fail"` | `voiceLists` (count) |
| `GET /api/config` (exists) | now also returns the voice keys: `stt.provider`, `stt.*`, `tts.provider`, `tts.*`, `voice.max_recording_seconds`, `voice.auto_tts`, `voice.silence_duration`, `voice.barge_in`, `voice.barge_in_threshold_multiplier`, `voice.stop_phrases`, `voice.thinking_sound`, **and** the keys that must stay hidden (`voice.voice_chat_mode`, `voice.client_direct`, `voice.gpt_live.voice`, `voice.wake_word`) so a test can prove they never show. The old `stt` control still decides `stt.enabled` per profile | `voiceConfig: {…}` (deep-merged over the defaults) | `configReads` (exists) |
| `GET /api/config/schema`, `GET /api/config/defaults` | the voice keys in the shape `scripts/fixtures/settings_config_data.py` uses (the fixture imports that module and adds a `VOICE_SCHEMA`) | — | — |
| `PUT /api/config` | body must be exactly `{"config": {…}}` (anything else → 400); deep-merged into the stored config | `configPutFail: {status, detail}` | `configPuts: [patch, …]` |
| never-called routes: `GET /api/audio/voice-config`, `/api/audio/voice-live/*`, `WS /api/audio/transcribe-stream` | answer 404 | — | `forbidden: [path, …]` (tests assert it stays empty) |
| `prompt.submit` (exists, strict) | unchanged: unknown params → 4000 | — | each prompt gains `interrupted` |
| socket | `POST /__fixture/voice {"dropSocket": true}` closes every `/api/ws` client once (the app reconnects); `{"refuseSocketFor": seconds}` then refuses new sockets that long | | `socketDrops` |

The shape of a reply (how long the bot "thinks", what it says, how fast) uses the plans the base fixture already
has: `POST /__fixture/plan {"plans": [{"replyDelay": 3, "chunks": ["Sure. ", "Your first meeting ", "is at nine."], "chunkDelay": 0.3}]}`
(`REF238/scripts/build47-fixture-gateway.py:54-67`). `session.interrupt` already cancels a running reply.

### 12.2 Start commands on this stream's ports

Builders (9900 for hand runs, 9901 for the script, 9902–9904 spare):

```sh
cd /Users/me/Projects/hermes-hq-native-wt/m9-talk
python3 scripts/fixtures/voice-gateway.py --port 9900 \
  --credentials build/fixtures/talk-dev.json --media-dir build/fixtures/talk-media-9900 \
  --ref /Users/me/Projects/hermes-hq-native-ref238
```

Until the port guard is widened (the first commit of the fixture work), prefix it with `HQN_VOICE_ANY_PORT=1`.
The script refuses a port something else is listening on (`lsof -nP -iTCP:9900 -sTCP:LISTEN`), and it is stopped by
the PID it printed, never by name.

```sh
scripts/e2e-talk.sh <SIM_UDID> [RUNS]          # port ${HQN_TALK_PORT:-9901}; modelled on scripts/e2e-voice.sh
```

`e2e-talk.sh` starts the fixture, writes the invented credentials to `build/fixtures/talk-e2e.json` (mode 0600, never
printed), passes the path as `TEST_RUNNER_HQN_UI_CREDENTIALS`, runs
`-only-testing:HermesHQNativeUITests/TalkEndToEndTests` (narrowed by `HQN_TALK_ONLY`), exports screenshots to
`.build/shots/e2e/`, and stops the fixture it started (`trap … EXIT`). Derived data stays inside the worktree
(`build/dd`).

Simulators: builders create and use `HQN-m9-talk`; the stress tester `HQN-m9-talk-s`
(`xcrun simctl create "HQN-m9-talk" "iPhone 17 Pro" com.apple.CoreSimulator.SimRuntime.iOS-27-0`). The UDID is
always passed to the scripts; the default simulator in them is never used.

Stress tester: the same command on 9905 (hand runs) and `HQN_TALK_PORT=9906 scripts/e2e-talk.sh <UDID of HQN-m9-talk-s>`;
9907–9909 for the parallel and soak runs of §15.

Regression suites this stream reruns because it edits their screens, one after the other, each on this stream's
ports and simulator (their default ports belong to other streams):

```sh
HQN_VOICE_PORT=9902 HQN_VOICE_ANY_PORT=1 scripts/e2e-voice.sh <UDID>                    # memos (composer, session)
HQN_MENUS_PORT=9902 HQN_MENUS_OLD_PORT=9903 HQN_ANY_PORT=1 scripts/e2e-menus.sh <UDID>  # action row, hold menu, ⋯ menu
HQN_ATTACH_PORT=9902 HQN_ANY_PORT=1 scripts/e2e-attachments.sh <UDID>                   # + menu, tray
HQN_SETTINGS_PORTS="9902 9903 9904" scripts/e2e-settings.sh <UDID>                      # Settings root and config pages
HQN_E2E_FIXTURE=questions HQN_E2E_PORT=9902 scripts/e2e.sh <UDID>                       # the dock slot
```

### 12.3 Controls for bad data (used by §15)

| Control | Effect |
|---|---|
| `transcribeRaw: {status, body}` | the next transcribe answers this status and this exact body text (not JSON, `{"ok": false}`, a 20,000-character transcript, …) |
| `speakRaw: {status, body}` | the same for `POST /api/audio/speak` (bad base64, an empty clip, a 5 MB clip) |
| `streamScript: [ … ]` | the next speak-stream sends exactly these frames: `{"json": {…}}`, `{"toneMs": 200}`, `{"bytes": 3}` (an odd-length binary frame), `{"big": 10485760}`, `{"wait": 2.0}`, `{"close": 4401}`, `{"abort": true}` |
| `streamRate`, `streamChannels` | the `start` frame's `sample_rate` (0, 8000, 16000, 24000, 48000) and `channels` (1, 2) |
| `voiceConfig` with wrong types | `{"voice": {"max_recording_seconds": "abc", "stop_phrases": "stop", "silence_duration": 0, "barge_in": "no"}}` |
| `schemaVoice: false` | the schema and the record have no `stt`, `tts` or `voice` keys at all |

Events of other features (an approval, a clarifying question) are pushed with the base fixture's
`POST /__fixture/event {"profile": "ivy", "type": "…", "payload": {…}}`; a long history with
`POST /__fixture/history`.

---

## 13. Every assigned row

Format: what the web does (source), what native builds (section), the wire, the fixture, the owner's word, and the
checks that must be **seen** passing before the row is called done (test names are in §14).

Every row is exercised by the same stand-in gateway, started on this stream's port with

```sh
python3 scripts/fixtures/voice-gateway.py --port 9900 --credentials build/fixtures/talk-dev.json \
  --media-dir build/fixtures/talk-media-9900 --ref /Users/me/Projects/hermes-hq-native-ref238
```

(or by `scripts/e2e-talk.sh <UDID>` on 9901, §12.2). Where a row needs a control, it is named and set with
`curl -s -X POST http://127.0.0.1:9900/__fixture/voice -d '{…}'`.

Where a row quotes no note of its own, no note of the owner's speaks to it directly and the general ones of §0
decide: every feature must work, voice must be understandable, an error must be readable, glass must be the
system's, rows get their padding, and the app is "Hermes HQ".

Sections 3 and 5 rows (bots and chat entries):

**L163 · Row menu tile: Talk (opens the chat and starts live voice).**
Web `W:src/ui-bots/bot-menu.ts` (tiles Talk · Memo · Pin; disabled with "Can’t reach this bot").
Native §5.5: `BotMenuHooks.providers[.talk]`. Wire: none of its own; then §3 as any conversation.
Owner: "make every … feature work: voice memos, voice chat" (§0). Fixture: default controls.
Accept: `E12a` hold a bot row → tiles read Talk, Memo, Pin in that order → Talk → the chat opens and the dock says
Listening (screenshot looked at); `E12b` an unreachable bot shows Talk disabled with "Can’t reach this bot"; unit: a
chat that never settles gives the alert "Couldn’t Start Talking" / "Ivy’s chat didn’t open.".

**L209 · Empty-chat bot intro (what is left: the Talk and Bot Info capsules).**
Web `W:src/ui-bots/bot-intro.tsx`. Native §5.6. Wire: none. Fixture: a bot with no messages (the fixture's fresh
profile). Owner: Liquid Glass and padding rules (§0).
Accept: `E12c` empty chat shows head, name, role, description, the two capsules; Talk starts a conversation; Bot
Info opens the Bot Info sheet; at AX3 the capsules stack (screenshots light and dark).

**L214 · Bot Info tiles: Talk, Memo, Screen, Mute (this stream: Talk, and a hook for Screen).**
Web `W:src/ui-bots/info-state.ts:138-143`. Native §5.5; the Screen tile's place and layout room (§2.5). Wire: none.
Accept: `E12d` Bot Info shows Talk · Memo · Mute, evenly spaced; Talk is disabled when the bot cannot be reached;
Talk closes the sheet, opens the chat, starts (screenshot looked at); a layout test draws four tiles (a stub in the
Screen place) at the default size and at AX3 without clipping. The row is done for this stream when Talk is seen
working; the parity row closes when the screen stream's tile is on the train too.

**L364 · Action row under the latest reply: Copy · Read Aloud · Regenerate · More.**
Web `W:src/ui-chat/composer.tsx`, `V:…/assistant-message.tsx:1102-1161`. Native §7.1. Wire §3.3, §3.4.
Fixture: default; `streamMode: "fallback"` for the clip path; `speakFail` for the alert.
Accept: `E15a` four buttons in that order, each 44 pt; Read Aloud goes idle → Preparing audio → Stop reading →
idle; the fixture's `streams` ledger has the reply's cleaned text; `E15d` failure shows the alert "Couldn’t Read
Aloud" with the gateway's reason; `MenusTests` still pass.

**L365 · Message hold menu (this stream: Read Aloud).**
Web `W:src/ui-chat/message-menu.ts`. Native §7.2. Wire as L364.
Accept: `E15b` hold a reply → tiles Copy · Read Aloud · Share; it reads; hold again → Stop Reading; a streaming
reply shows Read Aloud disabled with "Still Replying"; your own bubble has no Read Aloud; the message-menu order
cases in `Tests/Menus/ChatActionsTests.swift` are updated and pass.

**L389 · + menu (this stream: Voice Memo and Talk with <Bot>).**
Web `W:src/ui-chat/plus-menu.ts`. Native §5.4. Wire: none of its own.
Accept: `E12e` + shows Camera, Photos, Files, then Voice Memo, then "Talk with Ivy", then Paste Image (when there
is one); Voice Memo opens the locked recorder; Talk with Ivy starts a conversation; `AttachmentsEndToEndTests` still
pass. The parity row closes when the composer stream's four items are on the train.

**L410 and L761 · Send Memo on Release setting (default on).**
Web `W:src/ui-voice/flags.ts`, `W:src/voice-settings.tsx`. Native §9.2, §9.3. Wire: none (this iPhone only).
Owner: "memo sends on release" (`MEM:finish-everything-push.md`).
Accept: `E17b` the switch is on after a reset; a held memo sends on release; switch off → the memo note changes
to "…let go to play it back before you send…", a held memo stops into review; relaunch keeps the choice.

**L411 · Audio composer chip preview plays in the preview sheet.**
Web `W:src/phone-audio-preview.tsx`. Native §11. Wire: none for a local file.
Accept: `E22` an audio file in the tray (seeded with `-HQDebugTrayAudio`) → tap → the sheet with its name, Loading…
then the player; Play shows the pause glyph and the time moves; Done stops it; a corrupt file shows "Couldn’t load
this recording."; an image tile still opens the media viewer.

**L435 · Chat ⋯ menu: Read Replies Aloud.**
Web `W:src/phone-chat-menu-model.ts:48`, `phone-chat-menu.tsx:262`. Native §7.3.
Accept: `E16a` ⋯ shows Read Replies Aloud after Rename… with no checkmark; tapping it leaves the menu open and
shows the checkmark; Settings › Voice › Text to Speech shows the switch on.

Section 11 rows (voice):

**L530 · Talk with <Bot>: tap starts a live conversation after a one-time intro sheet.**
Web `W:src/ui-voice/voice-menu.ts:18-30`, `HermesVoice.swift:658-799`. Native §5.1, §5.3, §4. Wire §3.1–§3.6.
Owner: "live voice chat that's understandable" (§0).
Accept: `E01` first tap shows the sheet with the four rows word for word → Start Talking → dock; second launch:
tap goes straight to the dock; Not Now starts nothing and the sheet is offered again on the next tap; `E02` one full spoken turn
(ledger: one transcribe of 16 kHz mono WAV, one `prompt.submit` with keys exactly `session_id, text` (plus `profile`
when the chat sends it), one stream with `done`), the bubbles are in the chat.

**L531 · Voice options menu (hold on Talk).**
Web `W:src/ui-voice/voice-menu.ts:51-64`. Native §5.2.
Accept: `E13` hold → title "Voice with Ivy" and the five items in order; Read Replies Aloud toggles with the menu
open; with control `stt: {"default": false}` Dictate with Hermes is disabled with "Speech to Text is off"; How Voice
Works shows six rows and Done; Voice Settings… lands on Settings › Voice; VoiceOver action "Voice options" opens it.

**L532 · Voice dock in the composer's place.**
Web `W:src/ui-voice/dock.tsx`. Native §6.1, §6.5.
Accept: `E02`/`E05` the dock replaces the composer, a draft typed before is back after End; visual, title, hint,
elapsed (counts up), route name, Mute, centre, End are all there and each button does what §6.1 says; glass is the
system's (screenshot looked at in light and dark over a busy transcript); `E23` at AX3 and AX5 nothing is cut off.

**L533 · Dock states.**
Web `W:src/ui-voice/dock-state.ts`. Native §6.2.
Accept: unit `TalkDockStateTests` asserts all ten rows word for word; `E02`–`E08` see Starting…, Listening,
Transcribing…, Thinking…, "Ivy is speaking", Muted, Reconnecting…, Still Listening on screen; `talk-shots.sh` has a
screenshot of each, looked at.

**L534 · Speech heard while reconnecting is dropped, never sent late, and the dock says so.**
Web `W:src/ui-voice/conversation-guard.ts`. Native §4.2 rule 4, §6.2 row 6. Fixture: `{"dropSocket": true}` in the
middle of a `say:3` take.
Accept: `E07` Reconnecting… shows; after the reconnect the dock reads "Didn’t send what you said while
reconnecting. Say it again."; the ledger has **no** transcribe and **no** prompt for that take, also after waiting
10 s more; the next take is sent normally and the hint clears. Unit `TalkLoopTests.lostSpeech*`.

**L535 · Paused / stopped notice kept in its chat.**
Web `W:src/ui-voice/voice-dock-notice.ts`, `dock.tsx:171-214`. Native §6.3, §6.4.
Owner: "I get an error but I can't read what it is" (§0).
Accept: `E08` silence pause → "Voice Paused" / "Paused after 2 minutes of silence. Your chat with Ivy is saved." →
leave the chat, return: still there → Copy Details puts title, message and detail on the pasteboard and the button
reads Copied → Resume starts a conversation; `E09` interrupted, background and route-lost wording; `E19c` three
failed transcriptions → "Voice Stopped" with the gateway's whole reason visible and Try Again; `E19b` a denied
microphone offers Open Settings; Done brings the composer back; a 600-character detail scrolls and is fully readable
at AX5.

**L536 · Away pill.**
Web `W:src/ui-voice/away-pill.tsx`. Native §6.6.
Owner: the rejected tab-bar accessory (§0, T11).
Accept: `E10` start, go back to the list → within a second the pill reads "Ivy · Listening · 0:0N" with a green dot
and End; it is above the tab bar and covers no row's controls; open another bot's chat → it sits above that
composer; tap → back in Ivy's chat with the dock, pill gone; End on the pill ends it; a paused notice gives the
orange-glyph "Ivy · Voice Paused · Tap for details", a stopped one the red form; `TalkAwayPill.isShowing` flips with it (unit).

**L537 · One microphone app-wide.**
Web `W:src/voice-conversation.ts`, FE-012. Native §2.4, §6.8.
Accept: `E11` Talk in Ivy, then Talk in Riley → Ivy's conversation is over (no pill for Ivy, the probe shows one
conversation, the fixture's lease list holds one name), Riley's dock is live; the memo mic in Riley's chat during
Ivy's conversation ends it first; unit `TalkControllerTests.startElsewhereEndsPrevious`.

**L538 · Voice entry from a bot row's Talk tile: opens the chat, then starts.**
Web `W:src/ui-voice/entry-live.ts`, `entry.ts`. Native §5.5. Same checks as L163 plus: `E12f` nothing is recorded
before the chat is on screen (the fixture capture's first take begins after `viewDidAppear`, asserted through the
probe's event order), and leaving during the open starts nothing.

**L539 · Audio route picker.**
Web `HermesVoice.swift:576-641`. Native §6.5.
Accept: `E02` no route in the bar's row for the Simulator's built-in speaker, `E05` the bar's long-press menu lists
"Speaker" and "Other Outputs…" (after build 308, §6.1); unit `TalkRouteNameTests` covers the mapping table;
the control under the label is an `AVRoutePickerView` (view-hierarchy assertion) and has a 44 pt touch area.
**Device-only**: the system picker's contents and switching to AirPods or AirPlay (§16).

**L540 · Read Replies Aloud (only for the chat on screen) and Read Aloud on a message, with highlight.**
Web `W:src/media-audio.ts`, `W:src/ui-voice/entry.ts`, FE-019. Native §7.4, §7.5.
Accept: `E16b` with the switch on, a reply that completes on screen is read (stream ledger) and marked with the
bar; the reply that was already there is not read; `E16c` a reply completing in another chat (pushed while the list
is on screen) is never read, also not after opening that chat; leaving the chat stops the reading (stream
`stopped`); `E15c` the strip shows "Reading aloud" and Stop works; unit `ReadAloudCenterTests`.

**L541 · Dictation (trigger becomes Stop; × cancels).**
Web FE-009, r1-22, `V:…/use-voice-recorder.ts`. Native §8. Wire §3.2, §3.5.
Accept: `E14a` Dictate with Hermes → the row "Dictating 0:0N" and the circle labelled Stop Dictation → Stop →
"Transcribing" → the words are in the field with the keyboard up, nothing was sent (the ledger has one transcribe
with mime `audio/x-m4a` and no prompt); `E14b` × leaves the field as it
was and the ledger has no transcribe; `E14c` Done does what Stop does; `E14d` with
`voiceConfig: {"voice": {"max_recording_seconds": 2}}` it stops by itself at 2 s; `E14e` `transcribeEmpty` → "No
Speech Detected" / "Try recording again." and Try Again; `E14f` `transcribeFail` → "Voice Transcription Failed" and the reason.

**L542 and L773 · Voice settings page; Voice: Conversation, Speech to Text, Text to Speech.**
Web `W:src/voice-settings.tsx`, `V:app/settings/constants.ts`, `voice-provider-fields.tsx`. Native §9.1–§9.3.
Wire §3.7.
Accept: `E17a` Settings › Voice lists Voice Conversation, Speech to Text, Text to Speech; every row of §9.2 that the
fixture's schema has is there with its label; the provider pickers read "OpenAI", "ElevenLabs", "Local (on the
gateway computer)" and so on; choosing ElevenLabs for Text to Speech swaps in ElevenLabs Voice (filled from the
fixture's two voices) and ElevenLabs Model, and the ledger's `configPuts` has `{"tts": {"provider": "elevenlabs"}}`;
Max Dictation Length refuses 0 and 601; a failed save shows the store's banner; unit `VoiceSettingsCatalogTests`.

**L543 and L762 · Voice diagnostics.**
Web `W:src/voice-diagnostics.tsx`, `voice-events.ts`, `voice-report.ts`. Native §9.4. Wire §3.2 for Transcribe.
Owner: build 14 "adds Settings > Voice > Voice conversation > Voice diagnostics > Copy report" (§0).
Accept: `E18` Record 3 s → "Recording 3 seconds…" → "Recorded N KB (audio/wav) from “…”." → Play → "Played 3.0 s."
→ Transcribe → `Transcribed: “…”`; Right Now lists the ten rows; Recent Audio Events lists what just happened;
Copy Report → the pasteboard's first line is "<app name> voice diagnostics" and it has every row and the test
line; unit `VoiceReportTests` (30-event ring, format, nothing secret).

**L544 and L1012 · Keep awake.**
Web `W:src/voice-keep-awake.ts`, FE-008, `HermesPlatform.swift:771`. Native §10.2.
Accept: unit `KeepAwakeTests` (zero crossings, cap, `appLeftScreen`); `E21` the probe's hold count is 1 during a
conversation (also on the Bots list), 1 while a reply runs with its chat on screen and 0 after leaving that chat, 1
during dictation and during a memo take, 0 after each ends and after the app comes back from the Home screen with
nothing running; Diagnostics shows "Screen kept awake: yes (1 hold)".

**L546 · GPT-Live engine gate and wake word kept hidden.**
Web `W:build/voice-gates.ts`. Native T1, §3.8, §9.2 "Never shown". Owner: "remove the 'Hey Hermes' wake word" (§0).
Nothing to show. Accept: `E25` with the fixture's config and schema holding `voice.voice_chat_mode`,
`voice.client_direct`, `voice.gpt_live.voice` and `voice.wake_word`, none appears on any Voice page or in Settings
search; no screen of this stream contains "GPT", "Live voice", "wake" or "Hey Hermes" (accessibility dump);
the fixture's `forbidden` ledger is empty after the whole suite; `scripts/check-talk-guards.sh` finds none of §3.8's
paths in `App/` or `HermesKit/`.

Section 19 rows (settings list):

**L760 · Read Replies Aloud — default: Off.** Web `W:src/voice-settings.tsx`, `V:store/voice-prefs.ts`. Native T6,
§7.4, §9.2. Accept: `E16a` after `-HQDebugResetVoice YES` the switch is off in all three places; on, then relaunch:
still on; unit default test.

**L761** with L410 above. **L762** with L543 above. **L773** with L542 above.

Section 27 rows (platform):

**L1010 · Audio session coordination (conversation mode).**
Web `HermesPlatform.swift:930,1309`, `W:src/audio-session.ts`. Native §10.1.
Accept: unit `AudioSessionCoordinatorTests` (conversation pre-empts, borrowing leaves the category alone, events
logged); `E09` each system event of §10.1's table, raised through the debug hook, ends in the right notice;
Diagnostics shows "Audio in use by: conversation" and "playAndRecord, default" during one. **Device-only**: real
calls, Siri, AirPods, echo cancellation (§16).

**L1011 · Voice output route and voice intro (voiceRoute, voiceRoutePicker, voiceIntro).**
The three bridge calls have no native counterpart to build: their features are L539 (route) and L530 (intro).
Accept: the checks of L539 and L530.

**L1012** with L544 above.

---

## 14. Tests and debug hooks

### 14.1 Unit tests (`Tests/Talk/`, Swift Testing; run with `scripts/build.sh test <UDID>`)

| Suite | Covers |
|---|---|
| `TalkDockStateTests` | §6.2's ten rows word for word, the barge-in-off variants, `formatElapsed` (0:07, 2:14, 1:02:03), `SilenceClock` (30 s, 120 s, what resets it), the four paused notices, `stoppedNotice`'s choice of action, `noticeText` |
| `TalkLoopTests` | a table of input sequences against expected effects: every rule of §4.2, and that every ending releases everything exactly once |
| `TalkStopWordTests` | defaults, address prefixes, punctuation and case, a custom list, `[]`, and that "stop the deploy" is sent |
| `TalkEchoTests`, `SpeechTextTests` | the vendor's own vectors (`V:lib/voice-tts-echo.test.ts`, `V:lib/speech-text.test.ts` where present), ported |
| `TalkVADTests` | level maths (silence 0, a full-scale sine near 1), end of speech at 1.25 s, idle at 12 s, the 60 s cap, the barge trigger (calibration, 300 ms and 80 %, the 0.14–0.37 clamp while playing, grace, multiplier), pre-roll |
| `KeepAwakeTests`, `VoiceReportTests`, `TalkRouteNameTests` | §10.2, §9.4, §6.5 |
| `ReadAloudCenterTests` | with `FixtureTalkSpeaker`: §7.4's rules, replacing (T30), failure leaves the switch on |
| `TalkControllerTests` | with fixture capture and speaker and a fake chat: one conversation app-wide, notices per chat, start clears stale notices, auto-mute for questions and other audio |
| `VoiceSettingsCatalogTests` | section order, hidden keys absent from pages and search, makers' names, provider-only fields |
| `ComposerPrimaryTests` | §5.1's order table (the choice is a pure function) |
| `VoiceGatewayLiveTests` | against the running fixture, enabled only with `TEST_RUNNER_HQ_TALK_FIXTURE="http://127.0.0.1:9900\|$PWD/build/fixtures/talk-dev.json"` (the pattern of `Tests/Voice/VoiceLiveFixtureTests.swift`; one sign-in per test, never in a loop): exact request bodies of §3.2–§3.6, stream modes ok, fallback, refuse, drop, silent, and an empty `forbidden` ledger |

### 14.2 End-to-end UI tests (`UITests/talk/TalkEndToEndTests.swift`, run with `scripts/e2e-talk.sh <UDID>`)

`E01` intro · `E02` a full turn · `E03` barge-in while speaking (`interrupted: true` on the second prompt, the
stream `stopped`) · `E04` Stop while thinking, Interrupt while speaking · `E05` Mute, Unmute, Send Now · `E06` End,
the ended caption, the kept draft, saying "stop" · `E07` reconnecting · `E08` silence pause and the notice's
buttons · `E09` interruptions and background · `E10` pill · `E11` one microphone · `E12a–f` entries · `E13` options
menu · `E14a–f` dictation · `E15a–d` Read Aloud · `E16a–c` Read Replies Aloud · `E17a–b` settings · `E18`
diagnostics · `E19a–d` failures (Speech to Text off, denied, three failed transcriptions, unplayable voice) · `E20`
a question during a conversation (question dock wins, conversation muted, back to Listening after the answer) ·
`E21` keep awake · `E22` audio preview · `E23` accessibility sizes · `E24` relaunch · `E25` hidden engine and wake
word.

Every test signs in once with the fixture's invented credentials, uses launch arguments from §14.3, attaches a
screenshot at each named state, and reads the fixture's ledger over `http://127.0.0.1:<port>/__fixture/voice-state`.
A test never loosens an assertion to pass under load; a flaky run is rerun and both results are reported.

`scripts/talk-shots.sh <UDID>` (modelled on `scripts/voice-shots.sh`) takes every state of `-HQDebugTalkShot` in
light, dark and AX3 into `.build/shots/talk/` for a person (or an agent) to look at.

`scripts/check-talk-guards.sh`: greps `App/` and `HermesKit/` for the never-called paths of §3.8 and for the word
"Dispatch" inside string literals of this stream's files; non-zero exit on a hit. `e2e-talk.sh` runs it first.

### 14.3 DEBUG launch arguments (`App/Debug/TalkDebugHooks.swift`; compiled out of Release)

| Argument | Effect |
|---|---|
| `-HQDebugTalkFixture granted\|undetermined\|denied` | use `FixtureTalkCapture` with that permission (Simulator only) |
| `-HQDebugTalkScript "say:2;quiet;barge:1.5;hold;meterfail"` | what the fixture capture "hears", one step per take or per armed barge-in: `say:<s>` speech then quiet; `quiet` no speech; `barge:<s>` speech while the bot works or speaks; `hold` speech that only Send Now or the 60 s cap ends; `meterfail`; `fail` the engine does not start |
| `-HQDebugTalkSpeaker silent\|fixture\|audible` | `silent`: the real speaker with the mixer's volume at 0. It is the **default for every DEBUG build running in the Simulator**, so no test and no agent makes a sound on this shared Mac. `fixture`: no audio objects at all, timing taken from the stream's byte count. `audible`: real sound, for a person at the Mac only |
| `-HQDebugPhoneVoice fails` | the iPhone's voice (§7.7) fails too, so a failing computer voice ends the reading as in §7.6 (E15d, E19d) |
| `-HQDebugTalkClock <factor>` | divides the 30 s, 120 s, 12 s and 60 s windows (20 makes the silence pause 6 s) |
| `-HQDebugTalkInterruptAfter <s>`, `-HQDebugTalkInterruptReason interrupted\|route-lost\|reset\|config` | raises that system event after the conversation starts |
| `-HQDebugTalkIntroSeen YES\|NO`, `-HQDebugReadRepliesAloud YES\|NO` | preset the two keys for this launch |
| `-HQDebugResetVoice YES` (exists) | also forgets `hq.voice.introSeen`, `hq.voice.readRepliesAloud`, `hq.voice.tip.talk` |
| `-HQDebugTalkProbe YES` | an element `talk.debug` whose value is JSON: status, muted, conversations, keep-awake holds, session owner, speech state, AVKit loaded, take files on disk, the order of the last events |
| `-HQDebugTrayAudio YES` | puts one small audio file in the composer tray of the chat that opens |
| `-HQDebugMemoryWarningAfter <s>` | posts a memory warning |
| `-HQDebugTalkShot <state>` | opens the debug bot's chat and shows one state for screenshots: `starting, listening, still, muted, reconnecting, transcribing, thinking, speaking, lost, paused-silence, paused-interrupted, paused-background, paused-route, stopped, stopped-denied, problem, problem-raw, pill, pill-problem, pill-paused, pill-stopped, intro, info, dictating, dictation-transcribing, reading, ended, diagnostics, preview` |

### 14.4 Order of work for the builders

One feature at a time (`MEM:feedback-one-feature-at-a-time.md`), each ending in a commit with its tests green and
**both** identities building (`scripts/build.sh build <UDID>` and `HQ_IDENTITY=original scripts/build.sh build <UDID>`):

1. Fixture additions and `VoiceGatewayLiveTests`. `e2e-voice.sh` still green.
2. The pure pieces of `HermesKit/Voice/` with their unit tests.
3. Capture, speaker, `TalkController`, the dock, Talk in the circle, the intro: rows L530, L532, L533, L534, L539,
   L1010, L1011.
4. Notices and the pill, one microphone: L535, L536, L537.
5. The other ways in: L163, L209, L214, L389, L531, L538.
6. Read Aloud and Read Replies Aloud: L364, L365, L435, L540, L760.
7. Dictation: L541.
8. Settings and diagnostics: L410, L542, L543, L761, L762, L773, L546.
9. Keep awake and the audio preview: L411, L544, L1012.
10. Accessibility sizes, dark, Reduce Motion, the screenshot sweep, the regression suites of §12.2.

---

## 15. STRESS PLAN

For the stress tester: simulator `HQN-m9-talk-s`, ports 9905–9909, its own worktree and derived data. Every number
below is measured on that simulator with the stand-in gateway; nothing is run against a real gateway. Results go
in the stream's report (`docs/briefs/m9/talk-report.md`) with the command, the numbers and the screenshots looked
at. A finding is a failure when it is a crash, a hang over 2 s, a wrong or missing word, a state that cannot be
left, a second live microphone, audio that keeps playing after End, a kept-awake screen with nothing running, a
message sent twice or sent late, or a leaked file.

Shared-Mac notes: no test may make a sound (`-HQDebugTalkSpeaker silent`). "Critical process HermesHQNative crashed"
can be another stream's app on another simulator (see the note in `scripts/e2e-menus.sh`); check how the app exited
before blaming it, and rerun. Sign in once per launch; never loop sign-ins, also not when the fixture was restarted.

### 15.1 Load

| # | Do | Pass |
|---|---|---|
| S-L1 | 200 turns in one conversation: `-HQDebugTalkScript` of 200 `say:1` steps, `transcripts` queue of 200 lines, `streamPace: 0` | 200 prompts and 200 finished streams in the ledger, in order, none twice; memory after turn 200 within 30 MB of turn 10; `Caches/talk` empty (probe); elapsed correct; no hitch over 50 ms in the signpost log |
| S-L2 | one 4,000-word reply (plan with 400 chunks, `chunkDelay: 0.05`) spoken while it streams; barge in at about chunk 200 | text is fed at most every 150 ms; scrolling the transcript by hand stays smooth; barge-in silences the bot within 350 ms; the second prompt carries `interrupted: true` |
| S-L3 | a conversation in a chat with 2,000 messages (`/__fixture/history`) | dock in and out and a fling of the list drop no frames beyond the same chat without voice |
| S-L4 | Talk → End 50 times as fast as taps land; Mute 100 times; Read Aloud on 20 different replies in 10 s; ⋯ Read Replies Aloud toggled 50 times | no crash; exactly zero conversations, session owner "nothing", zero holds and empty lease lists at the end; never two streams open at once (ledger timestamps) |
| S-L5 | `hold` script: a take that runs into the 60 s cap | it is sent at 60 s (1.9 MB WAV), transcribed, and the loop carries on |
| S-L6 | a one-hour conversation at `-HQDebugTalkClock 60` with speech every 100 scaled seconds | never pauses; elapsed reads `1:00:0N` in the dock and the pill |
| S-L7 | Talk started in 10 different chats one after another without ending | always exactly one live; nine "ended" states leave no notice, no pill, no hold |
| S-L8 | dictation at the 600 s limit (`voice.max_recording_seconds: 600`; run once in real time, the rest with the clock scaled) | stops by itself; the upload is AAC and under 3 MB; the field gets the words; the keyboard and the list stay responsive while it uploads |
| S-L9 | Settings › Text to Speech with a schema of every provider and 500 ElevenLabs voices | the picker opens and scrolls smoothly; search finds a voice |

### 15.2 Speed

Thirty runs each; report median and 95th percentile from the `talk` signposts (`scripts/hqn-logs.py`).

| # | Measure | Target |
|---|---|---|
| S-S1 | tap Talk → dock visible | next frame (≤ 34 ms) |
| S-S2 | tap Talk → Listening with a moving level | ≤ 400 ms warm, ≤ 900 ms first after launch |
| S-S3 | end of speech → Transcribing… | ≤ 50 ms after the quiet window |
| S-S4 | transcript answer → bubble and Thinking… | same frame |
| S-S5 | first PCM frame → sound scheduled | ≤ 120 ms |
| S-S6 | barge-in → bot silent | ≤ 350 ms |
| S-S7 | End → microphone released (session owner "nothing") | ≤ 300 ms |
| S-S8 | cold launch to first frame, before and after this stream's code | no measurable change (within run-to-run noise); the probe shows AVKit not loaded until the first dock |
| S-S9 | typing in the composer and scrolling the list while Read Aloud plays and the strip animates | no hitch over 16 ms attributable to voice |
| S-S10 | main-thread time inside any audio call | none: Time Profiler shows `AVAudioSession` and engine calls only on `AudioWork.queue` |

### 15.3 Bad network

The Simulator has no per-device link conditioner, so delay and loss come from the fixture.

| # | Do | Pass |
|---|---|---|
| S-N1 | `transcribeDelay: 40` | Transcribing… stays, End works at once, at 45 s a single readable failure, the loop re-arms |
| S-N2 | `dropSocket` during Starting…, Listening, Transcribing…, Thinking…, speaking, muted, dictation, Read Aloud | each recovers or stops with words; a take that overlapped the drop is never sent (L534); nothing is sent twice after the reconnect |
| S-N3 | `refuseSocketFor: 150` during Listening | Reconnecting… then, with no speech possible, the 2-minute silence pause with its notice; Resume works when the socket is back |
| S-N4 | `streamMode: "drop"` at 500 ms, `"silent"`, `"refuse"`, `"fallback"` | drop: the rest of the reply is spoken by clips or the turn's hint says playback failed, never a stuck "is speaking"; silent: the 15 s guard ends it; refuse and fallback: clips play |
| S-N5 | `speakDelay: 30` in fallback mode, then End | End is instant; no clip plays after End |
| S-N6 | plan `holdAck` and `ackDelay: 20` on the spoken prompt | the bubble shows as sending; Thinking… holds; Stop works; no duplicate after the ack |
| S-N7 | stop the fixture process (the PID this tester started) mid-conversation, wait 3 minutes, start it again on the same port | no crash, no spinner for ever; the app says what happened in words; **one** sign-in at most, by hand, never a loop |
| S-N8 | `configPutFail` and a slow `PUT /api/config` while flipping providers quickly | the store's banner and Retry; the page never shows a value the gateway refused as saved |
| S-N9 | `leaseFail: true` | nothing visible changes; one event line per failure in Diagnostics |
| S-N10 | airplane-like: `refuseSocketFor: 600` then tap Read Aloud, Dictate, Transcribe in Diagnostics | each fails once with a readable reason; none hangs |

### 15.4 Bad data

| # | Do | Pass |
|---|---|---|
| S-D1 | `transcribeRaw`: not JSON; `{"ok": false}`; no `transcript`; `transcript: 123`; 20,000 characters; only spaces; emoji and right-to-left text; "Stop."; "stop the deploy" | a readable failure for the malformed ones (third in a row stops, T15); long text is sent whole and the bubble lays out; spaces count as nothing heard; "Stop." ends the conversation; "stop the deploy" is sent |
| S-D2 | `speakRaw`: bad base64; empty clip; 5 MB clip; `speakMime: "audio/ogg"`; `mime_type` missing | each fails in words (the Ogg wording of §3.4), the reply stays as text, the loop carries on |
| S-D3 | `streamScript`: binary before `start`; odd-length frame; `{"json": {"type": "surprise"}}`; a 10 MB frame; no `end` ever; `start` twice | no crash, no noise burst (the bytes of a split sample are carried into the next frame, so every sample stays where the gateway put it: `framesThatSplitASampleAreJoinedNotShifted`, mono and stereo, frames of 1001 bytes); unknown types ignored; once `done` was sent the stall guard ends a stream with no `end` (`aStreamThatNeverEndsIsEndedAfterTheReplyIsComplete`), and a quiet socket before `done` ends nothing (`aQuietGatewayMidTurnIsNotTheEndOfTheReply`) |
| S-D4 | `streamRate` 0, 8000, 16000, 48000; `streamChannels: 2` | 0 → fallback to clips; the others play at the right speed (the tone's length matches the ledger within 10 %) |
| S-D5 | `voiceConfig` with wrong types (§12.3) and extremes (`max_recording_seconds` −5, 0, 99999; `silence_duration` 0 and 600; `barge_in_threshold_multiplier` 0 and 1000; `stop_phrases` of 500 entries) | defaults are used for anything unreadable; limits clamp; Settings shows the raw value and lets it be fixed |
| S-D6 | `schemaVoice: false` | the three pages show this iPhone's rows only, with no empty groups and no error |
| S-D7 | `elevenVoices: "unavailable"`, `"fail"`, and a list with missing ids | the voice field becomes free text; nothing crashes |
| S-D8 | replies that are only a code block, only a table, only emoji, only a URL, 50 code blocks, a `MEDIA:` line | nothing unspeakable is spoken; a reply with nothing to say re-arms the microphone at once; Read Aloud on it says "There’s nothing to read in this reply." |
| S-D9 | `submitRefuse: 1` on a spoken turn; an unknown-params answer forced by a plan (`reject`, code 4000) | the chat's usual refusal card; the conversation keeps listening; nothing is retried in a loop |
| S-D10 | a bot name of 40 characters, one of emoji only, one in Arabic | dock title, hint, pill, intro and menu titles wrap or truncate in the middle of the name, never cutting the state word or the time |
| S-D11 | a corrupt, an empty and a 200 MB audio file in the tray preview | "Couldn’t load this recording." for the first two; the third plays without loading it whole into memory |

### 15.5 Interruption

Raised with `-HQDebugTalkInterruptAfter` and by hand where the Simulator can do the real thing (Home, app switcher,
a pushed notification with `xcrun simctl push`, Siri through `XCUIDevice.shared.siriService` if the runtime allows).

| # | Do | Pass |
|---|---|---|
| S-I1 | each of `interrupted`, `route-lost`, `reset`, `config` during each of Starting…, Listening, Transcribing…, Thinking…, speaking, muted | the right notice of §6.4 every time; nothing restarts by itself; microphone released; zero holds |
| S-I2 | Home and back after 1 s, 10 s, 5 min, during every state, during dictation, Read Aloud, a Diagnostics recording, the intro sheet, the options menu | "Voice stops when Hermes HQ leaves the screen." with Resume; dictation cancelled silently; Read Aloud stopped; no audio after return; Resume works every time (the owner's "Voice is paused" bug, §0) |
| S-I3 | app switcher peek without leaving; Control Centre; a notification banner; the route picker open and closed | the conversation is **not** paused |
| S-I4 | a question or approval arrives during Listening, Thinking… and speaking; answer it; let another arrive at once | question dock in front, conversation muted, nothing said is sent meanwhile; Listening after the answer; a manual mute before the question stays muted after it |
| S-I5 | tap a push notification for another chat during a conversation; open Settings as a sheet; open Bot Info; start a memo in another chat; play a memo bubble; open the media viewer | pill rules, T13 and §6.8 hold; nothing leaves two audio users alive |
| S-I6 | change text size, dark / light, Reduce Motion and Bold Text from the Simulator's settings mid-conversation | the dock re-lays out at once, no restart of audio |
| S-I7 | `-HQDebugMemoryWarningAfter 5` during speaking | no crash; audio continues or stops with a notice, never a silent dead dock |
| S-I8 | delete the chat, archive it, or sign out in Settings while its conversation is live | the conversation ends cleanly, no pill left pointing nowhere, no notice for a chat that is gone |
| S-I9 | the bot is renamed or its head changed while the dock and the pill show | the new name appears in title, hint and pill without restarting |

### 15.6 Relaunch

| # | Do | Pass |
|---|---|---|
| S-R1 | terminate the app (`xcrun simctl terminate <UDID of HQN-m9-talk-s> <bundle id>`) during each state, relaunch | no dock, no pill, no notice (T14), zero holds, Talk is the circle again; the chat reopens when Reopen Last Chat on Launch is on, without starting voice |
| S-R2 | terminate between the transcript's answer and the prompt's acknowledgement | after relaunch the message is in the chat **once** or not at all, never twice; nothing is sent after the relaunch |
| S-R3 | terminate during dictation and during a Diagnostics recording | `Caches/talk` is emptied at launch; the field's earlier draft is as the composer's own draft rules leave it |
| S-R4 | switches: Send Memo on Release off, Read Replies Aloud on, intro seen; terminate; relaunch; also after a reinstall of the same build over itself | all three kept; the intro does not return |
| S-R5 | 20 launch–Talk–terminate cycles | launch time does not creep; no orphan files; the fixture's lease list is empty after each (a lease the kill left behind is released by the next launch's first call) |
| S-R6 | background for 30 minutes (scaled by suspending the app with the Home screen), return | notice with Resume; Resume works; elapsed starts from 0:00 for the new conversation |

### 15.7 Accessibility sizes

Sizes XS, L, XXXL, AX1, AX3, AX5, each in light and dark; plus one pass each with Reduce Motion, Reduce
Transparency, Increase Contrast, Bold Text, and right-to-left (`-AppleLanguages "(ar)" -NSForceRightToLeftWritingDirection YES`).

Screens: Talk in the circle; the options menu; the intro sheet (start and info); the dock in all ten states; the
notice dock (paused; stopped with a 600-character detail); the pill (live, problem, paused, stopped; long name);
the ended caption; the dictation row; the Read Aloud strip and action row; the empty-chat capsules; Bot Info tiles;
the three Settings pages; Voice Diagnostics; the audio preview.

Pass: every word of the spec's tables is fully visible (wrapping, never an ellipsis in a title, hint, message or
detail); every control is at least 44 × 44 pt; nothing sits under the home indicator, the jump button or the
keyboard; the pill never covers the newest message or a row's trailing control; `performAccessibilityAudit()` is
clean on each screen; VoiceOver reads the labels of §5–§9 in a sensible order and announces a state change once
(not on every level tick); with Reduce Motion nothing pulses or slides; with Reduce Transparency and Increase
Contrast the glass stays readable (system behaviour, looked at); a dump of every accessibility label on every
screen contains no "Dispatch", "GPT", "wake" or "undefined".

---

## 16. What is not built, what waits on the owner, what only a device can prove

**Proposed as web-shell-only: none of the 32 rows.** Details inside rows that exist only because the old app is a
WebView and are not carried over:

| Web detail | Why it is not needed |
|---|---|
| the hint "The audio picker didn’t open" (`W:src/ui-voice/dock.tsx`) | it covers the failure of a fake tap sent into a hidden picker; native shows the real picker (T10) |
| Diagnostics rows "WebKit audio session", "WebKit microphone", "Live microphone tracks" | there is no WebKit; replaced by the native rows of §9.4 (T18) |
| the three bridge calls of L1011 as calls | no bridge; their features are built (L530, L539) |
| the 4 s route poll, the 100 ms composer retries of `entry-live.ts`, the stale-pause clearing of `audio-lifecycle.ts` | native has notifications, a settled-screen callback and no stored pause flag |
| the stop-phrase hint toast (T23) | the phone has no toasts, and End is always on the dock |
| "The message field isn’t ready, so voice didn’t start…" and "You left the chat, so … didn’t start." (`W:src/ui-voice/entry-live.ts`) | they report races of the web's router and composer mounting; native starts from the settled screen's own callback, and "<name>’s chat didn’t open." covers the one case left (§5.5) |

**Waiting on the owner: nothing.** No row needs a change to the push relay, a plugin or Hermes itself: every
endpoint used (§3) already exists in the Hermes checkout that was read. `docs/owner-todo/talk.md` is therefore not
created. What the owner's gateway must have for voice to do anything is configuration, not a change, and the app
says so itself: Speech to Text on (T26) and a Text to Speech provider whose audio an iPhone can play (§3.4).

**Only a real iPhone can prove these.** The Simulator has no call, no Siri take-over worth trusting, no AirPods, no
silent switch and no acoustic path from speaker to microphone. Per the honesty rule these parts are reported as
*not verified on a device*, and the list goes into the stream's report for the owner (it is the web's own
`W:docs/voice-device-checklist.md`, adapted):

1. Talk with the phone on a table at normal volume: the bot does not hear itself (echo cancellation), and speaking
   over it interrupts within a moment.
2. A phone call and Siri during a conversation: "Voice paused · A call or Siri took the microphone." and Resume works.
3. Lock the phone and switch apps: "Voice stops when Hermes HQ leaves the screen." and Resume works.
4. AirPods in, then taken out mid-conversation: the route label follows; the conversation continues on the phone.
5. The route button opens the system picker and switching works.
6. Read Aloud plays with the silent switch on.
7. Saying "stop" ends it.
8. The microphone prompt reads "Hermes HQ uses the microphone for voice memos, dictation and voice conversations
   you start."
9. How it feels: time from the end of a sentence to the first spoken word with the owner's real providers.

---

## 17. Risks

1. **Voice processing on a real device.** `setVoiceProcessingEnabled` changes input format, lowers other audio and
   behaves differently per route; with the `.default` session mode the echo cancellation may be weaker than with
   `.voiceChat`. Guard: one switch point (`TalkEngineCapture.sessionMode`), the playback clamp (0.14) and the echo
   guard on the transcript as second and third lines of defence, and device check 1.
2. **Barge-in thresholds are the desktop's.** They were tuned for laptop microphones through WebKit's meter. The
   level maths is ported exactly, but an iPhone's processed input may sit lower or higher. Guard:
   `voice.barge_in_threshold_multiplier` already scales it per gateway; `voice.barge_in: false` turns it off and the
   dock's words follow.
3. **Text to Speech output the phone cannot decode** (Ogg/Opus from some providers on the clip path). The stream
   path is PCM and is not affected. Guard: the plain failure of §3.4 naming the fix.
4. **A take is uploaded as base64 JSON.** A conversation take is WAV: a normal sentence is 100–200 KB, the 60 s
   cap is 1.9 MB (2.6 MB on the wire), which is seconds on a weak link. Guard: the 45 s timeout with words; if it
   hurts in use, writing takes as AAC is a local change inside `TalkEngineCapture` (the gateway accepts it, and
   dictation already does it, T32).
5. **Two docks, one slot.** The question dock and the voice dock share `showPromptDock`; the arbiter (T12) is a
   small change in a file the questions stream owns. Integration must keep both streams' tests green together (E20
   and `QuestionsEndToEndTests`).
6. **A chat kept alive off screen.** `voiceHold` reuses the away-chat mechanism and adds a second listener beside
   the single-owner `onChange`. A mistake here shows as a reply spoken twice or a chat that never stops listening.
   Guard: `TalkControllerTests`, S-L7, S-I8.
7. **The pill's place.** It floats above the bottom chrome because the tab-bar accessory was rejected by the owner.
   If he prefers the system accessory after seeing it, the change is contained in `TalkAwayPill`'s host. The Undo
   pill (botslist) must yield through `TalkAwayPill.isShowing`; both streams land separately.
8. **Shared files.** `ComposerView`, `ChatViewController`, `ChatCells` (the action row), `ChatMenus`,
   `ChatPlaceholderView`, `BotInfoSheet`, `SettingsRootView` and `ConfigSchema` are edited by other m9 streams
   too (composer, settings, screen, botslist). Edits are kept to the lines of §2.5 and registrations live in
   `TalkWiring.swift` to keep merges small.
9. **The Simulator proves the logic, not the audio.** Every acoustic claim (echo, routes, interruptions by the
   system) rests on device checks 1–9; until the owner runs them, those parts of L530, L539, L1010 and L1011 are
   "seen in the Simulator only".
10. **Sound on a shared Mac.** A test that forgot `-HQDebugTalkSpeaker silent` would play tones on the owner's
    speakers at night. Guard: in a DEBUG build running in the Simulator the speaker is silent unless
    `-HQDebugTalkSpeaker audible` is passed (§14.3); the same default covers Read Aloud and the Diagnostics Play
    button. Memo playback is the memo stream's and is not changed here.
