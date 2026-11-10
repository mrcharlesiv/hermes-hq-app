# 1x — Voice memos (record, send, play)

Status: implementation spec for the **voice** stream of milestone 2 (branch `m2/voice`). Scope: record a voice memo
from the composer's mic (hold to send, tap for hands-free), the live recorder, cancel by sliding, lock, review, send
(upload + transcription + `prompt.submit`), the memo bubble in history (play/pause, scrubbable waveform, length,
speed, transcript), drafts, and audio-session handling. **Out:** live voice conversation (Talk) and the Action Button /
Siri voice-note intent. Both get a seam (§2.4).

## 0. Sources, notation, ground rules

| Prefix | Path | What |
| --- | --- | --- |
| `W:` | `/Users/me/Projects/hermes-hq-native-ref238/` | Reference web app, release-build238, and its Swift shell. Read only. |
| `V:` | `W:vendor/hermes/apps/desktop/src/` | The vendored Hermes desktop renderer the phone runs, patched by the `W:build/*-gates.ts` string gates. |
| `HA:` | `/Users/me/.hermes/hermes-agent/` | The Hermes server, checkout `d94b70f` (2026-10-08). Read only. Never run it or import it. |
| `NAT:` | `/Users/me/Projects/hermes-hq-native/` | HQ Native (this repo). |
| `MEM:` | `~/.claude/projects/-Users-me-Projects-hermes-ios/memory/` | Owner history and taste. |
| `HO:` | `~/Projects/dispatch-handoff/` | Design docs (`design/DESIGN.md`, `design/OWNER-DECISIONS.md`). |

Write `file:N` or `file:N-M` for line citations. Where code and design docs disagree, this spec follows the **shipped
code** (build 238), except where a `DECISION` row in §0.1 says otherwise and gives the reason.
`NAT:docs/ARCHITECTURE.md` rules apply throughout:

- Swift 6 with default MainActor isolation.
- Network types are `nonisolated` and `Sendable`.
- Exact cached row heights; nothing animates height inside the transcript.
- Only system glass.
- No App Store–risky API.

### 0.1 Decisions for this round

| # | Question | Decision | Why / source |
|---|---|---|---|
| V1 | How do the memo's bytes reach the gateway? | Use the web shell's **managed-files staging**. `GET /api/files` finds the files root, `POST /api/files/upload-stream` sends the file as multipart, then `file.attach {path}`, then `DELETE` the staging folder. **Never** send `data_url` over the socket. | This is what build 238 ships (`W:ios/App/App/HermesNative.swift:2794-2849`). A 10-minute memo would be a multi-MB WebSocket frame. The server reads frames in order, so the 45 s heartbeat silence check (`NAT:HermesKit/Net/GatewayConnection.swift:23-24`) could trip mid-upload. |
| V2 | Recording format | AAC mono, 24 kHz, 48 kbps `.m4a` via `AVAudioRecorder`. Levels at 15 Hz. | Same as the web (`W:ios/App/App/HermesVoice.swift:323-326`). About 6 KB/s, so 600 s is about 3.6 MB. |
| V3 | Audio session | Activate only while recording or playing. Recording: `.playAndRecord`, mode `.default`, options `[.allowBluetoothHFP, .defaultToSpeaker]`, plus `setAllowHapticsAndSystemSoundsDuringRecording(true)`. Playback: `.playback`, mode `.spokenAudio`, no options. Always deactivate with `.notifyOthersOnDeactivation`. `setCategory`/`setActive` and every `AVAudioRecorder` call run on one serial `.userInteractive` queue (`AudioWork`), never on the main thread (A-P1). | The web shell's recorder (`HermesVoice.swift:320-321,334,479`). The haptics flag is **new**: iOS mutes haptics while recording, and the owner-approved gesture feedback (§3.8) would be silent without it. The `.playback` category matches the web's transcript-media type and plays with the silent switch on (`W:src/audio-session.ts:6-11`; `W:docs/voice-device-checklist.md:199`). History: `MEM:ios-native-ux-goal.md` records "Voice is paused" from an app session held too long. Never hold one. |
| V4 | Player | `AVAudioPlayer` (AVFAudio), always on a **local file**, with `enableRate = true`. A gateway memo is downloaded whole through the authenticated REST client into a cache first. | Injecting auth headers into an `AVURLAsset` needs an undocumented key. The owner refused anything App Store–risky (`MEM:native-composer.md`: "We can't do something that could stop apple from approving us."). Memos are small. AVFAudio is lighter at launch than AVFoundation (§9 A-P2). |
| V5 | Where the mic sits | A 44 pt control **inside the field's trailing end**, shown only when the field and tray are empty. The primary slot is unchanged: disabled Send when idle, Stop while a turn runs. Talk goes in the primary slot later. | `W:src/phone-ui-chat.css:418-424`; `NAT:docs/spec/06-native-feel-and-design.md:558-575`. |
| V6 | Recorder visuals | The field's glass stays and its contents swap to the recorder row. The 64 pt circle is a solid red control. The lock capsule is a native glass capsule. | The web draws CSS over a solid bar. Native shapes must be system glass (`MEM:liquid-glass.md`; spec 06 §0 rule 5). |
| V7 | Memo notices | A persistent glass card above the composer with Close, an action and Copy Details. **Not** the 3 s title toast. | The web says "never a toast" (`W:src/ui-voice/voice-extras.tsx:1-5`). The owner: "I get an error but I can't read what it is. The unreadable error display is itself a bug" (`MEM:finish-everything-push.md:16`). |
| V8 | Tips | A small UIKit popover (`UIPopoverPresentationController`, adaptive `.none`) anchored at the mic. **Not** TipKit. | It does the same job with no extra framework at launch (`NAT:docs/ARCHITECTURE.md` "Keep heavy frameworks out of launch"). |
| V9 | After the gateway accepts a memo | The local file **moves into the playback cache** under its gateway path. Your own memos never download again. | New. The web streams it again. This saves data and makes playback instant. |
| V10 | Waveform bar count in a bubble | Draw `min(48, floor((waveWidth + 2) / 4))` bars resampled from the 48 peaks, so the shape is never clipped. | The web draws 48 and clips its overflow (`W:src/phone-ui-voice.css:163-165`). At the bubble's minimum width that hides the end of the memo and its progress. |
| V11 | Microphone-permission copy | Use the bundle's display name ("HQ Native", which is what iOS Settings lists). Drop "and talk with <Bot>" until Talk ships. | The web says "Hermes HQ … to record memos and talk with Ivy" (`W:src/ui-voice/memo-live.ts:303`). The words must match what the owner sees in Settings. |
| V12 | Settings keys | `hq.voice.sendOnRelease` (Bool, default **true**) and `hq.voice.memoSpeed` (1, 1.5 or 2, default 1), both in `UserDefaults.standard`. The switch UI belongs to the settings stream. | `W:src/ui-voice/flags.ts:10-18`; `W:src/ui-voice/memo-player.ts:8-22`. |
| V13 | Memo while a reply runs | It goes into the existing local queue as a memo item and drains with `queued:true`. It never steers or redirects. | Attachments always queue (`NAT:docs/spec/04-send-stream-stop.md:789-809`). |
| V14 | Background playback | Not this round. No `UIBackgroundModes audio`. Playback pauses when the app leaves the screen. | The web has none (`W:ios/App/App/Info.plist:69-72`). Adding it later needs Now Playing and its own review. |

## 1. What the owner approved (quote these, never contradict them)

- **Send on release.** "**Voice memo: send on release.** Hold the mic, talk, let go and it sends (DESIGN Q1 default;
  the critique's safeguards stay: a hold under 1 s locks instead of sending, slide left cancels, red shows only once
  recording is confirmed)." (`HO:design/OWNER-DECISIONS.md:3`; recorded in `MEM:finish-everything-push.md:44-45`:
  "memo sends on release".)
- **Memo speed.** "D3: memo speed 1/1.5/2×, remembered." (`MEM:round9-ui-improvements.md:27`;
  `HO:design/OWNER-DECISIONS.md:17`: "memo playback speed 1×/1.5×/2×, remembered app-wide".)
- **Fewer taps.** The owner asked for "voice memos in fewer taps" (`MEM:finish-everything-push.md:36`). The target
  is "**1 gesture:** hold the mic, talk, let go" (`HO:design/DESIGN.md:1185`).
- **Slide to cancel must work, and a memo must never land in another bot.** The owner reported both in build 41:
  "slide to cancel doesn't work; a sent memo was missing after visiting another bot" (`MEM:voice-memo-bugs.md:11`).
  Rules that follow:
  - the target is frozen at touch-down;
  - a take left behind becomes a draft in **its own** chat;
  - a send in flight finishes into its own chat.
  The test lesson: "test memo gestures with the Simulator tool's `touch_path` or XCUITest … never dispatched
  PointerEvents" (`MEM:voice-memo-bugs.md:20`). Natively this means XCUITest `press(forDuration:)` and
  `press(forDuration:thenDragTo:)`.
- **Readable errors.** "Voice on device: 'I get an error but I can't read what it is'. The unreadable error display is
  itself a bug." (`MEM:finish-everything-push.md:16`.) Every failure therefore says what happened, in words, until the
  owner closes it (§3.7).
- **Bubbles.** "Keep the Hermes app's message design language and colors … with the shape of a bubble like telegram"
  (`HO:design/OWNER-DECISIONS.md:4-6`). The Telegram *colours* were abandoned: "abandon the telegram chat themes… i
  don't like them" (`MEM:telegram-look-hold.md:16`). The memo bubble is your normal tint bubble.
- **Your sent message stays at the bottom**, as in Telegram (`MEM:thread-top-anchor.md:31`).
- **Glass.** "never ship CSS imitation glass; native glass controls/sheets" (`MEM:MEMORY.md`, Liquid glass). Rows
  that wrap get 12–14 pt of vertical padding (`MEM:row-padding-feedback.md`). This applies to the notice card.
- **Hermes is not ours.** "We can't make any changes to hermes agent code since we don't control it."
  (`MEM:hermes-code-not-ours.md:8`.) Everything here is phone-side.
- **Haptics.** Send is silent (`MEM:taptic-feedback-gaps.md:14`; spec 06 §9).

## 2. Architecture

### 2.1 Files (new unless marked)

```
HermesKit/Voice/
  MemoTypes.swift        MemoFile, MemoEndAction, MemoTranscript, MemoCaptureEvent, MemoBeginError (§2.2)
  MemoGesture.swift      pure reducer, a line-for-line port of W:src/ui-voice/memo-gesture.ts (§3.2)
  MemoPolicy.swift       finish(reason:elapsed:), level(power:), peaks(_:count:), limitSeconds (§3.3)
  MemoText.swift         MEDIA directive build/parse, gatewayMemoPath, transcript wording (§4.1); replaces
                         NAT:App/Chat/VoiceMemo.swift (move it; keep its API for ChatRow/ChatSheets)
  AudioSessionCoordinator.swift   the one owner of AVAudioSession (§3.4, §6.4)
  MemoRecorder.swift     AVAudioRecorder capture (§3.3) + FixtureMemoRecorder (DEBUG && simulator, §8.3)
  MemoFiles.swift        directories, MemoDraftStore, MemoShapeStore, MemoPlaybackCache, purge on sign-out (§3.6, §6.2)
  MemoUploader.swift     the wire pipeline of §4.2 against GatewayClient (nonisolated)
  MemoWaveform.swift     peaks from a file (AVAudioFile, bounded) and from the performance plugin (§6.3)
  MemoPlayer.swift       one AVAudioPlayer app-wide, speed, progress, interruptions (§6.4)
HermesKit/Chat/LiveChatSession+Memo.swift   sendMemo / queue items / draft hand-back (§4.5)
App/Chat/Voice/
  MemoController.swift   runs the reducer's effects against the recorder; one active take app-wide (§3.2)
  MemoMicControl.swift   the mic in the field (§3.1)
  MemoRecorderViews.swift hold row, big circle + halo + lock capsule overlay, locked row, review row (§3.5)
  MemoDraftChip.swift    the composer's memo chip (§3.6)
  MemoNoticeCard.swift   the dock's notice card (§3.7)
  MemoTips.swift         the two tips (§3.7)
  MemoBubbleContent.swift the audio message inside your bubble (§5)
```

The builder edits these existing files:

- `NAT:App/Chat/ComposerView.swift`: mic slot, recorder host, chip slot.
- `NAT:App/Chat/ChatViewController.swift`: dock stack, leave hooks, notices.
- `NAT:App/Chat/ChatRow.swift:270-291` and `NAT:App/Chat/Render/TextLayout.swift:446-475`: the memo row.
- `NAT:HermesKit/Chat/LiveChatSession.swift:41-44`: `QueuedMessage`.
- `NAT:App/Chat/ChatQueueCard.swift`: memo items.
- `NAT:App/AppModel.swift`: purge on sign-out, scene phase.
- `NAT:HermesKit/Chat/HistoryAPI.swift:94-116`: the `mediaWaveform` flag.
- `NAT:App/Info.plist`.
- `NAT:App/Debug/DebugHooks.swift`.

### 2.2 Contract additions (integration owns `HermesKit/Contracts.swift`; propose these)

```swift
/// A finished recording on this phone. `path` is absolute, under Application Support/memos/<account>/…
nonisolated struct MemoFile: Codable, Hashable, Sendable {
    var path: String
    var seconds: Double          // two decimals
    var peaks: [Double]          // 48 values in 0…1, three decimals (MemoPolicy.peaks)
    var mime: String             // "audio/x-m4a" (recorder) or "audio/wav" (fixture recorder)
}

/// A chat that can send voice memos and keep one memo draft (adopted by LiveChatSession).
protocol ChatVoiceMemos: AnyObject {
    /// Sends `memo` (with `text` typed beside it, possibly "") through §4.2; queues while a reply runs (V13).
    func sendMemo(_ memo: MemoFile, text: String)
    /// The memo waiting in this chat's composer (a draft chip), persisted per chat (§3.6).
    var memoDraft: MemoFile? { get }
    func setMemoDraft(_ memo: MemoFile?)
}

// QueuedMessage (LiveChatSession.swift:41-44) gains:  let memo: MemoFile?   (nil for text)

// LiveGatewayClient (not the protocol) gains, for §4.2 (b) and (f):
//   func rest(_ method: String, _ path: String, query: [URLQueryItem], body: Data?,
//             contentType: String, timeout: TimeInterval) async throws -> Data   // clamp 1…600 s (today 1…120, LiveGatewayClient.swift:84-85)
// and a ChatSessionModel-side accessor to it via a new nonisolated protocol `GatewayTransfers: GatewayClient`
// so fakes can implement it.
```

**⚑ Cross-stream:** the attachments stream needs the same multipart upload and staging (§4.2 a–d). Whichever lands
first owns `GatewayTransfers` and an `AttachmentStager`. The other stream calls it. Integration must leave one
implementation (risk R1).

### 2.3 Ownership and lifetime

- `MemoController.shared` is a MainActor singleton. **One take at a time app-wide.** It holds:
  - the reducer state;
  - the capture;
  - the `MemoTarget`, frozen at touch-down: the chat's `layoutScope` (`"<account>|<profile>|<stored session id>"`,
    `NAT:HermesKit/Contracts.swift:238-241`), a weak `ChatViewController`, a weak `ChatVoiceMemos` session, and the
    bot's name.
- The `ChatViewController` whose screen is the target hosts the recorder views. Every other chat's mic works
  normally: a touch there while a take is running in another chat is ignored (§3.2, input `down`).
- `MemoPlayer.shared` is a MainActor singleton. One memo plays at a time. Starting a recording stops playback.
- The memo send pipeline runs inside `LiveChatSession`. It **captures `self` strongly** until `prompt.submit` answers
  or the send is refused. A chat left mid-send still finishes into its own chat, never the chat on screen
  (`MEM:send-lost-on-leave.md`, `MEM:voice-memo-bugs.md:16`). Today's text submit captures `self` weakly
  (`LiveChatSession.swift:601`); the memo path must not.

### 2.4 Seams for later work (build these hooks, nothing behind them)

- **Talk / live conversation.**
  - `ComposerView.Primary` reserves a `.talk` case (unused). Today it has `send`, `stop`, `disabled`
    (`ComposerView.swift:8`).
  - `AudioSessionCoordinator.Owner` reserves `.conversation`, which will outrank memo playback.
  - The composer's dock stack accepts a view that replaces the row (the future voice dock). The recorder already
    uses that mechanism.
- **Action Button / Siri / + menu "Voice Memo" / Bots "hold › Memo".**
  - `ChatViewController.beginMemo(handsFree: Bool)` calls `MemoController.memoDown(target, width, a11y: handsFree)`.
    It is exactly the web's `startMemoIn` → `memoDown(…, {a11y:true})` (`W:src/ui-voice/voice-controls.tsx:140-153`).
  - The **set-aside rule** for entry points that can start with text in the field: the memo sends on its own, and
    the typed text and attachments go back into the field afterwards (`W:src/ui-voice/memo-live.ts:194-241`).
  - This round the mic only shows on an empty composer, so set-aside is not reachable. Document it in code and leave
    it unimplemented.
  - `VoiceNoteIntent` (`W:ios/App/App/VoiceNoteIntent.swift`) and its durable 60 s request queue
    (`W:docs/action-button-voice-notes.md:44`) come later.

## 3. Recording

### 3.1 The mic in the composer

- **Placement** (`W:src/phone-ui-chat.css:418-424`; spec 06 §4.3):
  - A 44×44 pt control inside the field's trailing end, bottom-aligned with the field. Its centre is 2 pt in from
    the field's trailing edge.
  - The text view's trailing inset grows by 44 pt while the mic shows.
  - Glyph: SF Symbol `mic`, 20 pt, regular weight, label-2.
- **Visible when** the field is empty, there is no memo draft or attachment, no take is running in this chat, and the
  composer exists. This matches the web's `micShown = !hasComposerPayload && voiceStatus === 'idle'`
  (`W:src/ui-voice/voice-controls.tsx:184`).
  - It **stays visible while a reply runs**, so a memo can queue (`HO:design/DESIGN.md:677`; spec 06 §5.6.4).
  - Typing hides it, and Send takes over (`W:src/phone-ui-chat.css:423`).
- **Disabled** (alpha 0.4, no touches) when `ComposerView.isEnabled == false`: Reconnecting, Offline or Signed Out
  (`W:src/phone-ui-voice.css:16`; `NAT:App/Chat/ChatViewController.swift:894-911`).
- **Pressed look** (phase `pressing`, from touch-down until the recorder confirms): a Fill 3 circle (inset 4 pt in
  the 44 box), glyph in label colour (`W:src/phone-ui-voice.css:15`). Never red before recording is confirmed.
- **Touch handling.** `MemoMicControl` is a `UIControl`. It uses the window's touch coordinates:
  - `beginTracking`: `memoDown(target, width: composer width)`.
  - `continueTracking`: `move(dx, dy)` relative to the touch-down point.
  - `endTracking`: `up`.
  - `cancelTracking`: `pointer-cancel`.
  - No ancestor gesture may take the touch: return `false` from `gestureRecognizerShouldBegin` for recognizers that
    are not the control's own.
  - A touch on the mic never focuses the field (`composerMayFocus` is not consulted). It never scrolls the
    transcript.
  - The web needed window-level listeners because of a WebKit capture bug (`W:src/ui-voice/memo-touch.ts:1-5`).
    UIKit control tracking does not have that bug. Prove it with E-3 (§9).
- **Accessibility:**
  - label "Record Voice Memo";
  - hint "Hold to record, let go to send. Or tap to record hands-free."
    (`W:src/ui-voice/voice-controls.tsx:232-233`);
  - `accessibilityActivate()` → `memoDown(…, a11y: true)`, which opens the locked recorder and never a hold
    (`memo-gesture.ts:92-95`).

### 3.2 The gesture reducer (port exactly)

`MemoGesture.reduce(state, input, sendOnRelease:) -> (state, effects)` is a pure function. It is a line-for-line port
of `W:src/ui-voice/memo-gesture.ts:80-166`. `MemoController` runs the effects, as `W:src/ui-voice/memo-live.ts:79-118`
does.

Constants (`memo-gesture.ts:15-21`):

| Constant | Value |
|---|---|
| `HOLD_SEND` | 1.0 s, counted from **when recording started**, not from the touch |
| `TAP_SLOP` | 12 pt |
| `LOCK_DY` | −72 pt |
| `LOCK_NEAR_DY` | −40 pt |
| `DELETE_CONFIRM` | 10 s |
| `cancelLine(width)` | `−min(120, max(1, width) × 0.35)` |

Phases: `idle → pressing → holding | locked → ending → idle | review`.

| Input | Result (effects in brackets) |
|---|---|
| `down(at, width)` while idle | `pressing` [`begin`]. A `down` in any other phase is ignored. If the take's chat screen is gone, it first sends `leave` (`memo-live.ts:68-77`). |
| `a11y-open` while idle | `pressing` with `released = true` [`begin`]. The first `started` then locks. |
| `move(dx, dy)` while pressing or holding | Sets `cancelArmed = dx ≤ cancelLine`, `lockNear = dy ≤ −40`. While holding: `dy ≤ −72` and not armed → `locked` [haptic lock, focus-status]. First crossing into armed while holding → [haptic cancel-armed]. |
| `up(at)` while pressing | `released = true`; it records, then locks on `started` |
| `up(at)` while holding | armed → end `cancel`. `at − startedAt < 1.0 s` → `locked` (`tapLocked = moved < 12 pt`). Otherwise end `send` if `sendOnRelease`, else end `review`. |
| `pointer-cancel` | pressing → `canceled = true`. Holding → end `draft`. |
| `started(at)` while pressing | canceled, or released while armed → end `cancel`. Released → `locked`. `dy ≤ −72` and not armed → `locked`. Otherwise `holding` [haptic recording]. |
| `begin-failed(code, granted?)` | `permission-pending` → idle [tip `now-hold` if granted, else failed `permission-denied`]. `busy` or `canceled` → idle. Anything else → idle [failed code]. |
| `tick(seconds)` while recording | Updates `seconds` |
| `stop` while locked | end `review` |
| `send` | locked → end `send`. Review → idle [`send-reviewed`]. |
| `delete` while locked or review | `seconds ≥ 10` → [`confirm-delete`]. Otherwise locked → end `cancel`; review → idle [`discard-reviewed`]. |
| `delete-confirmed` / `delete-kept` | As delete / clears `confirmingDelete` |
| `limit(seconds)` | Holding → armed ? end `cancel` : end `send`/`review` by setting. Locked → end `review`. |
| `native-stopped` | Recording or pressing → idle. The draft belongs to native (§3.4). |
| `leave` | pressing → `canceled`. Recording → end `draft`. Review → idle [`draft-reviewed`]. |
| `ended(action, seconds?)` while ending | `review` → `review` (with seconds). Anything else → idle. |

Effect handling (`memo-live.ts:87-118`):

- `begin`: stop `MemoPlayer`, then `recorder.begin()`. Discard the answer if the generation changed.
- `end(action)`: `recorder.end(id, action)`.
  - `cancel` deletes the file.
  - `review` keeps the file in the view state.
  - `send` → `deliver(send)`.
  - `draft` → `deliver(draft)`.
- `deliver(send)` calls `session.sendMemo(file, text: "")` only while the target's screen is still on screen.
  Otherwise the memo becomes the target chat's draft, with the notice "Memo Saved as a Draft" (§3.7;
  `memo-live.ts:171-178`).
- `discard-reviewed` deletes the file now (`memo-live.ts:95-98`).
- `confirm-delete` shows the alert (§3.5.5).
- `tip` and `failed` show the tip or notice (§3.7).
- `haptic`: §3.8.
- `focus-status` resigns the field and moves VoiceOver to the status (§3.8).

Lessons (`memo-live.ts:274-284`):

- A memo sent by **holding** marks both tips done.
- A memo locked by a **tap** (`tapLocked`) shows "Hold to Record" once, unless that tip is already done.
- `cancel` and `draft` teach nothing.

### 3.3 The recorder (`MemoRecorder`)

Port `W:ios/App/App/HermesVoice.swift:282-551`. The differences are noted inline.

1. **Begin** (`begin() async throws(MemoBeginError) -> (id, limitSeconds)`). It **resolves only once
   `record(forDuration:)` returned true**. The UI never shows red before that (`HermesVoice.swift:16-19`).
   1. Already recording → `busy`.
   2. App not `.active` → `background`.
   3. `AVAudioApplication.shared.recordPermission`:
      - `.undetermined` → call `AVAudioApplication.requestRecordPermission()`, then throw
        `permissionPending(granted:)`. **The touch that raised the prompt records nothing** (`:291-295`).
      - `.denied` → `permissionDenied`.
   4. `limit = MemoPolicy.limitSeconds = min(600, floor(limitBytes × 0.95 / 6000))`
      (`W:ios/App/App/HermesPlatform.swift:784-786`). `limitBytes` is the attachment limit: 32 MB until a Settings
      value exists (`W:ios/App/App/PickedFiles.swift:30`). Under 10 s → `tooSmall` (`:297-299`).
   5. `await AudioSessionCoordinator.acquire(.memoRecording)` (V3). This stops memo playback first. The activation
      runs on the audio queue; steps 6–7 too (the recorder object is only ever touched there).
   6. Create `tmp/<uuid>.m4a`. Build `AVAudioRecorder(url:settings:)` with `AVFormatIDKey: kAudioFormatMPEG4AAC`,
      `AVSampleRateKey: 24000`, `AVNumberOfChannelsKey: 1`, `AVEncoderBitRateKey: 48000`. Set
      `isMeteringEnabled = true` and `delegate = self`.
   7. `record(forDuration: limit)`. If it returns false (an input another capture just released):
      `setActive(false, .notifyOthersOnDeactivation)`, wait **150 ms on a timer (never a sleep on main)**, then
      retry once. Retry only if it is the same take, it has not stopped, the app is still active, and it did not go
      to the background meanwhile (`MemoPolicy.mayRetry`, `HermesVoice.swift:241-244,335-354`). A second failure →
      `startFailed("the microphone did not start recording")`.
   8. Started: set `isIdleTimerDisabled = true` (the web's keep-awake, `memo-live.ts:135-136`), start the 15 Hz
      clock, install observers (§3.4), log `startLatencyMs` (DEBUG and os_signpost).
2. **Clock** (`:443-470`). A 1/15 s `Timer` in `.common` mode.
   - `level = clamp((averagePower(forChannel: 0) + 50) / 50, 0, 1)` (`:245-246`).
   - Keep a window max. Append one sample per 100 ms of elapsed time, capped at 6,000 samples.
   - Publish `.level(level, seconds)` where `seconds = min(limit, now − started)`.
3. **End** (`end(id, action) async throws -> MemoFile?`) (`:369-380`).
   - Stop recording (idempotent; it remembers `elapsedAtStop`). Tear down the clock and observers. Release the
     session with `.notifyOthersOnDeactivation`. Restore the idle timer.
   - `cancel` → delete the temp file, return nil.
   - Otherwise save **off the main thread**: `@concurrent` work or `Task.detached(priority: .userInitiated)`.
     1. Check the temp file is non-empty, else `saveFailed("the recording is empty")`.
     2. Move it to `Application Support/memos/<account key>/<uuid>/voice-memo.m4a`, with file protection
        `.completeUntilFirstUserAuthentication` and `isExcludedFromBackup = true`.
     3. Return `MemoFile(path, seconds (2 dp), peaks = MemoPolicy.peaks(samples, 48), mime)`.
   - `MemoPolicy.peaks` takes the window max per bin and rounds to 3 dp (`:249-255`).
   - The file name must be exactly `voice-memo.<ext>`. The gateway keeps the name (with a collision counter), and
     clients recognise a memo by it (`W:src/voice-memo.ts:12`).
4. **Native stop** (`nativeStop(reason)`, `:387-414`) for `interrupted`, `route-lost`, `reset`, `background`,
   `error` and `limit`. Decide with `MemoPolicy.finish` (`:232-237`):
   - `limit` → `.await`. Publish `.stopped(limit, seconds)` and let the reducer's `limit` rule run.
   - `cancel` → `.discard`.
   - Anything else → `.draft` if `elapsed ≥ 1 s`, else `.discard`.
   - Draft: save, then publish `.stopped(reason, seconds, disposition: draft, file)`, or `failed` with the error.
5. **The account key** is `SHA-256(account.id)`, hex, first 16 characters. Sign-out purges
   `memos/<key>/` and `Caches/memos/<key>/` (the web's sign-out policy, `W:docs/action-button-voice-notes.md:40-41`).

### 3.4 Interruptions and lifecycle while recording

The recorder observes these (`W:ios/App/App/HermesVoice.swift:526-551`):

| Event | Reason | Outcome |
|---|---|---|
| `AVAudioSession.interruptionNotification`, type `.began` | `interrupted` | ≥ 1 s: draft chip + notice "Recording Stopped". < 1 s: discarded. Never sent. |
| `routeChangeNotification`, reason `.oldDeviceUnavailable` | `route-lost` | Same |
| `mediaServicesWereResetNotification` | `reset` | Same. Rebuild the recorder on the next touch. |
| `UIApplication.didEnterBackgroundNotification` | `background` | Same |
| `audioRecorderDidFinishRecording(successfully: true)` | `limit` | Reducer `limit` rule |
| `…successfully: false` or `audioRecorderEncodeErrorDidOccur` | `error` | Draft or discard as above |
| The chat screen leaves: `viewDidDisappear`, its tab hidden, or the screen deallocated | reducer `leave` | Draft chip in **that** chat (C3, `memo-live.ts:139-140`) |
| Sign-out or account switch | — | `end(cancel)`, then purge |

The policy says a memo the system stopped is **never** sent: "Never a send: only the person's release or Send
sends" (`HermesVoice.swift:228-231`).

### 3.5 Recorder UI (the composer's height never changes)

The recorder replaces the composer row's contents in place. The field's glass shape stays and its `textView` and
placeholder go to alpha 0. Keep the text view in the hierarchy, and keep it first responder if it was. The primary
button changes as listed below. The row height stays at the field's height (40 pt at one line). Text sizes cap so the
row stays one line at every size: the timer at 22 pt and the slide label at 20 pt (`W:src/phone-ui-voice.css:40-42`).
Nothing changes behind the row while a recorder phase shows: no solid dock (spec 06 §4.3; owner 2026-11-01, the
solid band read as a white box over the whole bottom of the chat).

#### 3.5.1 `pressing`
The mic's pressed look only (§3.1). Nothing else changes.

#### 3.5.2 `holding` (`W:src/ui-voice/memo-recorder.tsx:48-76`; `W:src/phone-ui-voice.css:42-64`)
- **Field contents**, leading to trailing, vertically centred:
  - a 10 pt red dot, 16 pt from the field's leading edge. It pulses opacity 1 → 0.35 over 1 s, ease-in-out,
    autoreversing. No pulse under Reduce Motion.
  - 8 pt gap.
  - The timer `m:ss` (whole seconds rounded down, `W:src/voice-memo.ts:40-43`): Headline 17 semibold, tabular
    digits, capped at 22 pt, label colour. It turns orange-text when `limit − seconds ≤ 10`.
  - 8 pt gap.
  - The slide label, centred in the remaining space. That space ends 12 pt before the leftmost point the big circle
    can reach (`phone-ui-voice.css:46-48`).
    - Not armed: SF `chevron.left` 13 pt + "Slide to cancel", Subheadline 15 (cap 20), label-2, offset
      `x = max(−56, min(0, dx) × 0.5)`.
    - Armed: "Release to Cancel", semibold, red-text, offset 0. The colour changes over 0.15 s.
- **Primary:** alpha 0. The big circle covers the trailing end.
- **Big circle:** in an overlay on `ChatViewController.view` so it is never clipped. Its rest position is centred on
  the mic. Re-measure every layout pass so it rides the keyboard (`W:src/ui-voice/memo-position.ts:3-22`).
  - 64 pt red circle with white `mic.fill` at 26 pt.
  - Shadow 0/4/12 in red at 35 %.
  - It appears by growing 44 → 64 pt over 0.28 s with an overshoot: spring damping 0.62, or
    `cubic-bezier(.34,1.56,.64,1)`. Under Reduce Motion it appears at 64 with no spring.
  - Offset `x = max(−travel, min(0, dx) × 0.3)`, `y = lift = max(−72, min(0, dy))`. `travel` is 40 pt, or 20 at
    accessibility sizes (`memo-recorder.tsx:42-43,70`).
  - **Glow:** a 120 pt radial gradient behind it (red at 50 % in the middle, 24 % halfway, 8 % at three quarters,
    clear at the edge), scaled `1 + voice × 0.6` with a 90 ms linear animation per level update. `voice` is
    `MemoLiveWave.shape(level)`: `((level − 0.18) / 0.68)` clamped to 0…1, to the power 0.8, so the room's hush stays
    still and a voice fills it.
  - **Ripples** (owner 2026-10-30: "make the entire, that whole thing a spectacle"): while `voice > 0.2`, a 2 pt red
    ring leaves the circle every `0.42 − 0.24 × voice` s (at most 8 at once). Over 0.95 s it grows to
    `1.7 + 1.1 × voice` times the circle, thins from `2 + 2 × voice` pt to 0.5 pt, and fades in to
    `0.35 + 0.5 × voice` then out. They stop when the circle hides.
  - No glow animation and no ripples under Reduce Motion.
- **Lock capsule:** 36×80 pt, a native glass capsule (`UIGlassEffect(style: .regular)`, not tinted).
  - Its centre x is the mic's. Its top is `micCentreY − 32 − 12 − 80`. It is offset `y = lift × 0.35`.
  - Contents, stacked with 6 pt between: `lock.open` 15 pt over `chevron.up` 11 pt, label-2.
  - When `lockNear` (dy ≤ −40): `lock.fill`, tint.
- The whole holding UI is hidden from VoiceOver. The finger owns it.

#### 3.5.3 `locked` and `ending` (`memo-recorder.tsx:85-106`; `phone-ui-voice.css:65-74`)
- **Field contents:**
  - **Trash** (44 pt, SF `trash` 20 pt, red; "Delete Voice Memo").
  - **Pill:** flexible width, **no fill** (the owner, 2026-10-30: the Fill 3 capsule read as "a gray background …
    behind that animation"; the sound sits on the field's glass), 12 pt leading padding, 8 pt gaps. Inside:
    - an 8 pt red dot, pulsing, with a 4 pt red glow;
    - the timer, Subheadline semibold, tabular (cap 20);
    - the **live waveform**, flexible, `min(34, field height − 6)` pt tall (at least 24), ending 6 pt before the
      pill's end: 3 pt round bars on a 5 pt pitch, mirrored about the middle, the newest at the trailing end.
      Height `3 + voice × (wave height − 3)` (`voice` as in §3.5.2). Colour: a horizontal gradient, clear at the
      leading end (the old bars fade out by the timer), red from 15 %, hot pink at 75 %, ember orange at the newest
      bar. The newest 10 bars glow pink (shadow radius `4 + 6 × voice`, opacity `0.25 + 0.6 × voice`).
    - Motion on: a 60–120 Hz display link (only while the take records and the row is on screen) scrolls the bars
      smoothly, 5 pt per 100 ms. The newest bar slides in from the trailing edge and follows the live level, rising
      in ~35 ms and falling in ~140 ms; every 100 ms it is left behind as a bar. It starts from the take's own
      per-100 ms levels, so locking from a hold shows what was already said.
    - Reduce Motion (or `ending`): no display link; the bars step once per 100 ms from the controller's levels.
  - No ring round the field: build 504 had a turning colour ring inside the field's edge; the owner (2026-10-30) found
    it sat a hair inside the oval and called it "overkill", so it was removed.
  - **Stop** (44 pt, SF `stop.fill` 18 pt, red; "Stop Recording").
- **Primary:** Send (tint, enabled; "Send Voice Memo").
- **`ending`** (the save is running): every button is disabled at alpha 0.4.
- The keyboard is dismissed on lock (the `focus-status` effect).

#### 3.5.4 `review` (`memo-recorder.tsx:108-136`)
- **Field contents:**
  - Trash.
  - The pill (no fill, as in §3.5.3) with no leading padding, containing:
    - **Play/Pause:** a 32 pt tint disc in a 44 pt box with a white `play.fill`/`pause.fill` at 14 pt;
    - **40 bars** from the file's peaks (§6.3): played bars in tint, the rest label-2 at 55 %;
    - the time, which counts down while playing.
- **Primary:** Send.
- Review plays the local file through `MemoPlayer` (§6.4).
- Playback failure shows the inline notice "Couldn't Play the Memo" / "This iPhone couldn't play the recording back.
  You can still send it, or delete it and record again." (`memo-recorder.tsx:132-134`).

#### 3.5.5 Delete confirmation (`memo-live.ts:102-106`)
- A take of 10 s or more asks first, in a `UIAlertController(.alert)`:
  - Title: "Delete this 0:45 voice memo?"
  - Buttons: **Delete** (destructive) and **Keep Recording** (locked) or **Keep** (review).
- Shorter takes delete at once.

### 3.6 Memo drafts (the composer chip)

- **Created by:** `deliver(draft)` (leave, pointer-cancel, native stop ≥ 1 s), a failed send (§4.3), a send Stop
  withdrew, or Remove on a queued memo.
- **Stored in** `MemoDraftStore`, a JSON file at `Application Support/memos/<account key>/drafts.json`:
  `{"<layoutScope>": [MemoDraft]}`, newest first (`MemoDraft = {memo, text?}`). The chip shows the newest. **Never
  loses audio** (review round 1, a deviation from the web's one-draft rule): a memo handed back goes in front and
  deletes nothing; a recording leaves the phone only when it is sent or its chip's Remove is tapped. It survives
  relaunch (paths are rebased if iOS moved the app's container). Its chat's composer shows it whenever that chat opens
  (`W:src/voice-memo-record.ts:41-48`). A queued memo handed back (by Remove, or when a chat that keeps no queue is
  left) brings its typed words: they go into the field when it is empty.
- **Chip** (`W:src/ui-voice/memo-draft-player.tsx:8-24`; `W:src/phone-ui-voice.css:226-231`):
  - Sits above the composer row in the dock, leading-aligned with the field and as wide as its content.
  - A glass capsule 44 pt tall. Contents:
    - **Play/Pause** (44 pt box, tint glyph 16 pt);
    - "**Voice Memo 0:20**", Subheadline, label. Under it, a status line in Caption 1 label-2, shown only when
      non-empty: "Loading…" or "Couldn't load audio";
    - **Remove** (44 pt box; an `xmark` in a 32 pt Fill 2 circle; "Remove voice memo"). Remove deletes the file.
  - The play button's accessibility label is "Play Voice Memo", "Pause Voice Memo" or "Try voice memo again" (2026-11-06: the
    same words as the bubble and the review, which had said "Play voice memo" here and a bare "Pause" there).
- **Effect on the composer:**
  - With a draft, the mic is hidden and the primary shows **Send**.
  - Send calls `sendMemo(draft, text: field text)`, clears the chip and the field, and the draft leaves the store.
    The typed text becomes the **next bubble** (`W:src/voice-memo.ts:258-271`, `rest`).
- **⚑ Cross-stream:** the attachments stream will add a tray above the field. At integration the chip moves into
  that tray. Until then voice owns a one-item slot in the same place (risk R4).

### 3.7 Notices and tips

**Notice card (V7).**
- A glass card (`UIGlassEffect(style: .regular)`, radius 20, the queue card's look,
  `NAT:App/Chat/ChatQueueCard.swift:11-15`) at the top of the dock stack, above the queue card and the chip.
- Padding 12 pt vertical and 14 pt horizontal.
- Contents:
  - a tone glyph, 15 pt: warning `exclamationmark.triangle.fill` orange, error `xmark.octagon.fill` red, info
    `info.circle.fill` tint;
  - the title, 15 pt semibold;
  - the message, 13 pt label-2, up to 4 lines, selectable;
  - an optional detail line in Caption 1 monospace;
  - an optional action button (tint, semibold, 44 pt target);
  - **Copy Details**: title + message + detail to the pasteboard, with `notification.success`; shown only when there is a detail or the card is an error (a tip such as "Microphone Access Is Off" has nothing to copy);
  - **Close** (`xmark`, 44 pt).
- It stays until closed, acted on, or its chat is left.
- While it shows, the transcript's bottom inset grows by its height, so it never covers the newest row
  (`W:src/ui-voice/voice-extras.tsx:59-65`).

Copy (exact; `<App>` = `CFBundleDisplayName`, `<Bot>` = the chat's bot name, `0:12` = `m:ss`):

| When | Tone | Title | Message | Action | Source |
|---|---|---|---|---|---|
| Permission denied (touch, or Don't Allow at the prompt) | warning | Microphone Access Is Off | Turn on Microphone for `<App>` in Settings to record voice memos. | **Open Settings** (`UIApplication.openSettingsURLString`) | `memo-live.ts:302-303` + V11 |
| Begin failed: background | info | Couldn’t Record | Voice memos record while `<App>` is on screen. | — | `memo-live.ts:304` |
| Begin failed: other | error | Couldn’t Record | the error's words, else "The microphone didn’t start. Try again." | **Try Again**: locked recorder, same chat (`voice-extras.tsx:92-97`) | `memo-live.ts:305` |
| Save failed | error | Couldn’t Save the Memo | the error, else "The recording couldn’t be saved on this iPhone." | — | `memo-live.ts:165` |
| System stopped, kept | info | Recording Stopped | `<WHY>` Your 0:12 memo is waiting in the message field. | — | `memo-live.ts:336-341` |
| System stopped, save failed | error | Couldn’t Save the Memo | `<WHY>` The 0:12 recording couldn’t be saved: `<error>`. | — | `memo-live.ts:334-335` |
| Send couldn't start (composer off screen or disabled) | warning | Memo Saved as a Draft | It didn’t send. It’s waiting in the message field of your chat with `<Bot>`. | — | `memo-live.ts:174-177` |
| Transcription failed (memo still sent) | warning | No Transcript for This Voice Memo | Transcription failed. The memo is still attached and plays in the chat; `<Bot>` gets it without the text. Detail = the gateway's reason. | — | `W:src/voice-memo.ts:135-140` |

`<WHY>` (`memo-live.ts:294-300`):

| Reason | Text |
|---|---|
| `interrupted` | "A call or Siri took the microphone." |
| `background` | "`<App>` left the screen." |
| `route-lost` | "The headset or microphone disconnected." |
| `reset` | "iOS reset its audio." |
| `error` | "The recording stopped unexpectedly." |

**Tips (V8)** (`W:src/ui-voice/voice-extras.tsx:111-114`):
- The Talk tip's card (`TalkTipBubble`, docs/spec/3x-talk.md §5.1) above the composer, not a popover: a popover took
  the next tap anywhere on the screen and refused sheets while it was up (UX study 2026-10-19). Contents: a `mic`
  glyph, the title (semibold), the message, and Close ("Close tip").
- **"Now Hold to Record"** / "Hold the mic and talk, then let go to send." shows after the permission prompt
  answered Allow.
- **"Hold to Record"** / "Next time, hold the mic and let go to send." shows once after the first tap-locked memo.
- Rules:
  - Show only when the mic is visible, nothing is recording, the chat has settled (0.7 s after it appears), and the
    jump button is not showing (`voice-extras.tsx:40-41,70-78`).
  - Never time out.
  - Done for good when closed or when the lesson is done (§3.2). A recording starting (or the mic hiding) only takes
    it away: it shows again at the next settle. Done flags:
    `UserDefaults hq.voice.tip.nowHold` and `hq.voice.tip.holdToRecord`.

### 3.8 Haptics, keyboard, VoiceOver

**Haptics.** Follow the code, not DESIGN's table (`memo-live.ts:111-112`; `memo-gesture.ts:85,101,121`). Prepare the
generators on touch-down.
- `impact(.light)` when recording is confirmed while holding.
- `impact(.light)` on lock.
- `impact(.rigid)` when crossing **into** cancel-armed while holding. Not on the way back.
- Sending a memo is silent.

**Keyboard** (`memo-live.ts:113-116,245-263`; `W:docs/voice-device-checklist.md:122-124`):
- Never dismissed during a hold.
- Dismissed on lock.
- After a memo sends:
  - If the keyboard was up at touch-down, it stays up.
  - If it was down, nothing raises it: programmatic focus (`ChatViewController.focusComposer`) waits 1.5 s. A tap on
    the field always focuses it.

**VoiceOver** (C11, `memo-recorder.tsx:90-102`; `W:docs/voice-device-checklist.md:180-183`):
- Locking posts `.layoutChanged` to the pill's status element. Its label is computed when read ("Recording, 0:04").
  **Do not** use `.updatesFrequently` and post no announcements: a spoken time would end up in the memo.
- The next element is Stop. Focus never lands on Send by itself.
- Groups:
  - locked: "Voice memo";
  - review: "Voice memo to review".
- Review play button: "Play Voice Memo" / "Pause Voice Memo".

## 4. Sending (wire)

### 4.1 Message text (the only memo "format" on the wire)

The gateway sees a normal user turn. Hermes has no notion of memos: "Voice memo transcript" appears nowhere in `HA:`.
The convention is client-side (`W:src/voice-memo.ts:171-212,229-234`):

```
reference      = MEDIA:"<gateway path>"\n\nVoice memo transcript: <said>
said           = transcript.trimmed, or "(No speech detected)" when the gateway returned ""   (voice-memo.ts:200)
               | "(unavailable: speech-to-text is off on the gateway)"                            (STT off, :209)
               | "(unavailable)"                                                                   (call failed, :209)
prompt text    = [reference, typedText].filter(nonEmpty).joined("\n\n")                          (V:…/submit.ts:200-209)
optimistic     = MEDIA:"<local path>"  (+ "\n\n" + typedText)  before the upload                  (voice-memo.ts:223-234)
```

- `gatewayMemoPath(path)` (`voice-memo.ts:162-166`):
  - No `"`, CR or LF, and an audio extension (`m4a mp3 wav aac ogg opus flac aiff caf`).
  - Then: POSIX absolute with no backslash, **or** a Windows drive path `C:\…` / `C:/…`.
  - When the gateway's stored path fails this, send `ref_text` instead of the reference, with no transcript and no
    STT call (`voice-memo.ts:176-178`).
- Example stored row, as history returns it:
  `MEDIA:"/Users/owner/.hermes/profiles/ivy/attachments/voice-memo-2.m4a"\n\nVoice memo transcript: Pick up milk on
  the way home.`
- Parsing is `VoiceMemo.parse` as it already exists (`NAT:App/Chat/VoiceMemo.swift:56-77`, which matches
  `memoParts`, `voice-memo.ts:263-271`). Move it to `MemoText` and keep the behaviour.

### 4.2 Pipeline (`LiveChatSession.sendMemo` → `MemoUploader`)

The order and parameters are exact. Every session-scoped RPC names `profile`. REST adds `?profile=<p>`
(spec 04 §1.4). `p` is the chat's own profile, captured at the start, never the app's current one
(`W:src/voice-memo.ts:89-100`). `P` = the bot's profile name, `rid` = the live runtime id, `sid` = the stored id.

**0. Optimistic bubble, in the same frame the recorder closes.**
- Append a user message (`local-user-…`, `isPending = true`) with the optimistic text.
- `turn.busy = true` and `awaitingResponse = true`, so the composer shows Stop and further sends queue.
- **Do not arm the silence watchdog yet.** Arm it when step (g) is sent. `armWatchdog()`
  (`NAT:HermesKit/Chat/LiveChatSession+Sync.swift:725-745`) would otherwise read `session.active_list`, find nothing
  running during a long upload, and settle the turn.
- No send lift: there is no draft text to lift from.

**(e) STT lookup, in parallel with (a).**
- `GET /api/config?profile=P` → read `stt.enabled`. `!== false` means on.
- Any failure counts as **on** (`voice-memo.ts:101-120`). Concurrent lookups for one profile share one request.
  Nothing is cached across sends.
- Handler: `HA:hermes_cli/web_routers/config_env.py:80-91`. Default `stt.enabled: True`
  (`HA:hermes_cli/config_defaults.py:1156-1157`).

**(a) Files root.**
- `GET /api/files?profile=P` → `{"path":"/Users/owner","parent":…,"entries":[…], …}`. Use only `path`
  (`HA:hermes_cli/web_routers/files.py:507-529`; `W:ios/App/App/HermesNative.swift:2818-2820`).
- Cache it per (account, P) for the app session. Drop the cache on any upload error.

**(b) Upload.**
- `POST /api/files/upload-stream?profile=P`, `Content-Type: multipart/form-data; boundary=hermes-<UUID>`. The body
  is byte-exact to `W:ios/App/Shared/HermesTransportShared.swift:281-299`:
  ```
  --hermes-<UUID>\r\nContent-Disposition: form-data; name="path"\r\n\r\n<root>/.dispatch-attachments/<UUID2>/voice-memo.m4a\r\n
  --hermes-<UUID>\r\nContent-Disposition: form-data; name="overwrite"\r\n\r\nfalse\r\n
  --hermes-<UUID>\r\nContent-Disposition: form-data; name="file"; filename="voice-memo.m4a"\r\nContent-Type: application/octet-stream\r\n\r\n<bytes>\r\n
  --hermes-<UUID>--\r\n
  ```
- Build the body off the main thread (≤ 32 MB; a memo is ≤ 3.6 MB). Timeout 120 s.
- The staging folder name is `.dispatch-attachments` (`HermesTransportShared.swift:264`). Keep it, so the web and
  native staging look the same on the gateway computer.
- Answer: `{"ok":true,"entry":{…},"path":"<root>/.dispatch-attachments/<UUID2>/voice-memo.m4a", …}`
  (`HA:…/files.py:637-643,700-718`).
- Errors: 403 not writable, 409 exists, 413 too large, 500.

**(c) Attach.**
- First make sure a runtime id exists: `resumeNow()` if `runtimeSessionId == nil`.
- RPC:
  ```json
  {"jsonrpc":"2.0","id":51,"method":"file.attach","params":{"session_id":"5cc537d1","profile":"ivy",
    "name":"voice-memo.m4a","path":"/Users/owner/.dispatch-attachments/2F…/voice-memo.m4a"}}
  ```
- Allowed keys: exactly `session_id`, `profile`, `path`, `data_url`, `name`
  (`HA:tui_gateway/contracts/prompt_voice.py:165-184`; `contracts/common.py:224-228`). Any other key answers
  **4000** (`HA:tui_gateway/contracts/base.py:16-17`; `HA:tui_gateway/rpc_dispatch.py:25-31`).
- Never send `data_url` (V1).
- Result:
  ```json
  {"attached":true,"name":"voice-memo-2.m4a","path":"/Users/owner/.hermes/profiles/ivy/attachments/voice-memo-2.m4a",
   "ref_path":"…","ref_text":"@file:…","uploaded":true}
  ```
  The gateway copies a file that sits outside the session workspace into `<profile home>/attachments/`, with a
  `-2`, `-3` … collision counter (`HA:tui_gateway/prompt_attachments.py:82-95,187-248`; handler
  `HA:tui_gateway/methods_prompt.py:976-996`).
- Errors:
  - `4001 session not found`: stale runtime id (`HA:tui_gateway/server.py:1229-1245`). Resume once and retry
    attach once with the same uploaded path, no re-upload (`V:app/session/hooks/use-prompt-actions/index.ts:196-215`).
  - `4015 path or data_url required`.
  - `5028 <reason>`: staging failed.
  - `4064`: unknown profile. Signal that the roster is stale.
- Timeout 30 s.

**(d) Cleanup.** Fire-and-forget; log failures.
- Only when `uploaded == true` **and** the stored `path` is not the staging folder or inside it
  (`HermesTransportShared.swift:266-271`).
- `DELETE /api/files?profile=P`, body `{"path":"<root>/.dispatch-attachments/<UUID2>","recursive":true}`
  (`HA:…/files.py:731-751`; model `HA:hermes_cli/web_models.py:101-103`).

**(f) Transcribe.** Only when STT is on and the path passed `gatewayMemoPath`.
- `POST /api/audio/transcribe?profile=P` with JSON `{"data_url":"data:audio/x-m4a;base64,<…>","mime_type":"audio/x-m4a"}`.
  - The mime is `UTType(filenameExtension:)?.preferredMIMEType`, as the web reads it
    (`W:ios/App/App/PickedFiles.swift:252`). Fall back to `audio/mp4`. The gateway accepts `audio/x-m4a`,
    `audio/mp4` and `audio/wav` (`HA:hermes_cli/web_routers/audio.py:42-47`).
  - Base64-encode off the main thread.
  - Timeout `clamp(dataURL.count × 0.1 ms, 180 s, 600 s)` (`V:api/system.ts:32-48`). This needs the raised clamp
    from §2.2.
- Answer: `{"ok":true,"transcript":"Pick up milk on the way home.","provider":"openai"}`. Empty speech gives
  `{"ok":true,"transcript":""}`. Errors: 400 `{"detail":…}`, 413 over 25 MB, 500 `{"detail":"Transcription failed"}`
  (`audio.py:83-145`).
- `ok == false` or any error → `(unavailable)` + the transcription notice (§3.7). The memo still goes.
- **One paid call per recording.** The transcript is kept by memo file. A retry or re-stage reuses it.
  A missing or failed transcript is not kept, so a later send can try again (`voice-memo.ts:142-156`;
  `W:src/eager-upload.ts:20-40`).

**Rewrite before submit.**
- Replace the optimistic bubble's text with the final prompt text. The bubble then shows the transcript at once
  (`V:…/submit.ts:829-830` `rewriteOptimistic`).
- Alias the gateway path to the local file in `MemoPlaybackCache` and `MemoShapeStore`, so the bubble keeps playing
  the same file and the same waveform (`W:src/ui-voice/memo-peaks.ts:32-37`).

**(g) Submit.**
- The existing `submit` path (`NAT:HermesKit/Chat/LiveChatSession.swift:604-686`), with
  `{"session_id":rid,"profile":P,"text":<prompt text>}` (+ `"queued":true` from the queue). Arm the watchdog now.
- Every existing branch applies: 4009 retry window, 4001/4007 resume-once, refusal, unconfirmed.
- On ack: move the local file into the playback cache under the gateway path (V9), and drop the draft-store entry
  if this send came from a chip.

### 4.3 Failures and what the owner sees

| Where | What happens |
|---|---|
| Steps (a)–(c) fail, or not connected, before (g) | Remove the bubble. Add the error card with the reason (as `refuseSend`, `LiveChatSession.swift:773-785`). The **memo returns as this chat's draft chip** and any typed text returns to the empty field. Park the queue. The file stays on the phone (C2). Nothing was submitted. |
| (e) fails | STT counts as on |
| (f) fails | Send with `(unavailable)`, plus the "No Transcript for This Voice Memo" notice |
| (g) refused | As today's `refuseSend`, plus the memo back as a draft chip. Keep the attach result (gateway path + reference) keyed by (memo file, stored session id) in memory, up to 8. A retry into the same chat skips (a)–(f) unless the transcript was missing (`W:src/eager-upload.ts:20-40`). |
| (g) timeout or connection lost | "Delivery unconfirmed" (spec 04 §2.5). Never resend. The file goes to the cache under its gateway path. |
| Stop before (g) | At once: the staging task is cancelled (no more upload, attach or paid transcription), `withdrawStoppedSend` behaviour (`LiveChatSession.swift:700-714`) with the memo back as a draft chip. When the turn was the memo's own it settles with no interrupt (nothing reached the gateway) |
| The chat screen left during (a)–(g) | Nothing changes. The pipeline finishes into its own chat (§2.3). |

### 4.4 While a reply runs (V13)

- A memo sent while `turn.busy` (or with the queue non-empty and not parked) becomes
  `QueuedMessage(id, text: typed, memo: file)`.
- The queue card row reads "**Voice Memo 0:12**", plus " · " and the first line of the typed text if any, with a
  leading `mic` glyph.
- Send Now and Remove work as today. Remove returns the memo as the draft chip and the text to the empty field.
- A drain runs the whole §4.2 pipeline with `queued:true` on (g).
- The chat is left with memos still queued: they ride the queue like the text, photo and goal items beside them
  (verify round 3, `LiveChatSession+Away.swift`). The chat keeps listening off screen and sends them when the reply
  ends; a queue left behind (parked, or the app killed) is kept with its memos for the next open (spec 3x-live-words
  §3.1.2). Only a chat that keeps no queue (tests, previews) hands each memo back as its draft (oldest first, with its
  words), with the notice "Memo Saved as a Draft" when the chat opens next. (Until 2026-11-02 every app chat did that.)

### 4.5 Bubble states of an outgoing memo

1. **Pending (steps 0–f):** the audio message (§5) plays the local file. The transcript slot reads "Transcribing…".
   The send caption "Sending…" appears after 2 s (spec 06 §5.6.4).
2. **After the rewrite:** the transcript shows (or "No transcript", or the off wording).
3. **Refused:** gone, with an error card and the draft chip.
4. **Unconfirmed:** the caption "Delivery Unconfirmed · Check".
5. A pending memo whose send failed is never "Transcribing…". It reads "Transcription unavailable. Check the memo’s
   delivery status." (`W:src/voice-audio-message.tsx:131`).

## 5. The memo bubble in history (your bubble)

**Parsing.** A user message whose text parses as a memo (§4.1) builds one memo row plus, if `rest` is non-empty, a
second plain bubble (as `ChatRow.swift:270-291` does today). Assistant `MEDIA:` audio stays the spec 03 §9.4 file
chip; that belongs to the attachments stream.

**Layout.** Exact heights are computed in `TextLayout` and cached by (scope, message id, revision, width, Dynamic
Type, `transcriptOpen`, `loadFailed`). Playing, progress and speed **never change the height**. Measurements from
`W:src/phone-ui-voice.css:146-183` and `W:src/voice-audio-message.tsx:81-139`:

| Part | Spec |
|---|---|
| Bubble | Your tint bubble, as spec 06 §2.1–2.3: padding 6/12, radius 18, tail, time inside the bottom-trailing corner. **Width** = `max(min(236, 0.62 × screen width), natural transcript width + 24)`, capped at your bubble's max width. |
| Card | (Native, 2026-10-29, owner: "more elevated".) The player sits on a card inset 6 pt from the bubble's edges: the bubble's text colour at 15 % (6 % where that text is dark, as the Desktop Look's), radius = the bubble's − 6 (at least 8), continuous corners. Height = max(disc, waveform + 2 + its text line) + 2 × 8. |
| Play | A **40 pt disc in the bubble's text colour** 8 pt inside the card, with a soft shadow (black 22 %, radius 3, 1.5 pt down), in a 44 pt target. Glyph `play.fill`/`pause.fill` 16 pt bold in the **bubble's fill colour** (made solid over the page where the fill is see-through); the play triangle sits 1.5 pt right of centre so it looks centred. Loading: a spinner in place of the glyph. |
| Waveform | 10 pt after the disc, as wide as the card allows (12 pt from its end), 24 pt tall. **Bars 3 pt wide, 2 pt gaps, round ends.** Count per V10 (n bars need 5n − 2 pt, at most 48). `barHeights`: each bar takes the loudest of the peaks it covers, measured from the memo's quiet level (0.8 × its 10th-percentile bar; 0 when the memo is one level throughout) up to its loudest bar, raised to the power 0.75 so quiet words show; clamped 0.12…1; height `3 + h × 21` pt. Unplayed bars: text colour at 42 %. Played: text colour at 100 %, filled up to the exact playback fraction (a bar fills part way). Unknown peaks: a flat track at 0.18. |
| Time | **Under the waveform**, at its leading edge, 2 pt below the bars. Footnote, medium, tabular (at most 18 pt), text colour at 85 %. Shows the remaining time while playing or paused partway (rounded down), else the total **rounded to the nearest second** (`MemoPolicy.total`, as Telegram: a 2.0 s hold reads 0:02). The chip, the queue card, notices and review use the rounded total too; the live timer rounds down. Unknown: "–:––" (`voice-audio-message.tsx:68,100`). |
| Speed | Shown while playing or when speed ≠ 1. "1×", "1.5×" or "2×" in Caption 1 semibold, tabular (at most 16 pt), in an 18 pt capsule (the text colour at 22 %, 10 % where it's dark) on the time's line, ending where the bars end. Its 44 pt target starts under the bars, so a tap on the bars seeks. Tap cycles 1 → 1.5 → 2 → 1 and saves app-wide at once (`memo-player.ts:8-22`). It sits inside the card, so the height never moves. |
| Load failure | Its own line, 4 pt under the card: "Couldn’t load audio" (Footnote, bubble text) + **Retry** (semibold, 44 pt target) (`voice-audio-message.tsx:106-108`) |
| Transcript | 7 pt under the card (no hairline: the card's edge divides them). Subheadline 15, bubble text, wrapping anywhere. **Clamped to 3 lines.** "More"/"Less" (Footnote semibold, bubble text, 44 pt target, net 30 pt line) below it when clamped or open. State lines use Footnote: "Transcribing…" (local pending), "No transcript" (failed, or pending in history), "No transcript: speech-to-text is off on your gateway." (off), and the failed-send line from §4.5 (`voice-audio-message.tsx:113-139`). |
| Time reserve | The bubble time's reserve applies to the last laid-out line: the transcript's last visible line, or the More/Less line (spec 06 §2.3) |

**Accessibility** (`voice-audio-message.tsx:83-103`):
- Play: "Play Voice Memo" / "Pause Voice Memo".
- Waveform: an adjustable element "Voice memo position", value "0:04 of 0:12" (or "of unknown length").
  Increment and decrement move ±5 s.
- Speed: "Playback speed 1×. Change".
- The transcript is plain text, read after "You said:".

**Scrubbing (native addition).**
- A tap or horizontal pan on the waveform seeks to `fraction × duration`. Only that pan is gated (its own delegate:
  horizontal drags only); a vertical drag that starts on a memo scrolls the chat (E-18).
- During a pan, the played bars and time follow the finger, and the seek applies on release.
- If the file is not loaded yet, the gesture loads it and starts playback at the fraction. The web only seeks a
  loaded memo (`memo-player.ts:130-135`), but Telegram's bubbles scrub at any time.

## 6. Playback

### 6.1 What a path means
- A path under the app's `memos/<account key>/` is a local file.
- Anything else is a gateway path, resolved through §6.2.

### 6.2 Getting the file (`MemoPlaybackCache`)
Resolve in this order:
1. The local file.
2. A cache hit: `Library/Caches/memos/<account key>/<SHA-256(path) hex>.<ext>`.
3. A download, `GET /api/fs/download?path=<enc>&profile=<p>` (`W:src/bridge/platform.ts:41-46`; handler
   `HA:hermes_cli/web_routers/files.py:891-904,933-960`).
   - Through `GatewayClient.rest` (32 MB ceiling, `NAT:HermesKit/Net/GatewayAddress.swift:186-189`).
   - Write the file off the main thread.
   - Concurrent requests for one path share one flight.

Cache rules:
- LRU by last use: 64 files or 128 MB.
- Purged on sign-out.
- An account switch fences in-flight work.

### 6.3 Waveforms (`MemoShapeStore`, `MemoWaveform`)
**Store.** `{path: {peaks[48], seconds, at}}`, keeping the newest 64, in `Application Support/memos/<account
key>/shapes.json` (`W:src/ui-voice/memo-peaks.ts:4-37`).
- Your own memos are stored at save, by local path.
- At the §4.2 rewrite they are linked to the gateway path.

**When a history memo bubble becomes visible and the store has no shape** (web order:
`W:src/voice-audio-message.tsx:51-66`, `W:src/bridge/platform.ts:80-89`):
1. If `gateway.ready.performance` has `history_path` and `media_waveform == 1` (add `mediaWaveform` to
   `PerformanceFeatures`): `GET /api/plugins/<route>/media/waveform?path=<p>&profile=<P>`.
   - Accept only `{"schema":"media.waveform.v1","peaks":[48 finite numbers in 0…1],"seconds":>0}`
     (`W:src/media-metadata.ts:22-32`).
   - HTTP 405, 501, or 404 "Not Found" turns the route off for the account until the next `replay_epoch`.
2. Otherwise fetch the file into the cache (§6.2) and compute off the main thread, as
   `W:ios/App/App/HermesVoice.swift:806-837` does:
   - `AVAudioFile` read in 4,096-frame chunks;
   - the peak absolute sample per bin, 48 bins;
   - refuse audio over 660 s;
   - normalise to the maximum;
   - `seconds = length / sampleRate`;
   - honour cancellation.

Queueing:
- One computation at a time (`W:src/memo-waveform-queue.ts:1-31`).
- Cancel it when the bubble scrolls away.
- Never re-request a memo whose computation failed this launch.

### 6.4 The player (`MemoPlayer.shared`, V3/V4)

**Play.**
1. Resolve the file (§6.2).
2. `AudioSessionCoordinator.acquire(.memoPlayback)`.
3. Create the player: `AVAudioPlayer(contentsOf:)`, `enableRate = true`, `rate = speed`, `prepareToPlay()`,
   `play()`.
4. Progress runs on a `CADisplayLink` only while playing and while that bubble is on screen. It updates the played
   bars and the time. With nothing visible, nothing ticks.

**Rules.**
- **One at a time.** Starting a memo pauses the one playing (`memo-player.ts:24-26,55-56`).
- **Ended.** Reset to 0, not playing, no progress (`memo-player.ts:148`). Release the session.
- **Pause and release the session** with `.notifyOthersOnDeactivation` on any of:
  - pause;
  - the chat screen disappearing;
  - the app leaving the screen (V14);
  - recording starting;
  - sign-out.

**System events.**
- Interruption `.began` → pause. Do **not** auto-resume on `.ended`.
- Route change `.oldDeviceUnavailable` (headphones out) → pause, per Apple's guidance.
- `mediaServicesWereReset` → drop the player and coordinator state, and show paused.

**Other apps' audio.** Nothing touches the session until Play. Playing pauses other audio (`.playback` without
mix/duck). Pausing or finishing gives it back via `.notifyOthersOnDeactivation`. Nothing ducks other apps, and
nothing holds the session idle.

The silent switch does not mute memos (`.playback`), matching the web.

## 7. Left out this round, and why

| Out | Why | Seam |
|---|---|---|
| Talk / live voice dock, away pill, route picker, intro sheet, voice options menu, Dictate with Hermes (`voice.record`, `/api/audio/transcribe-stream`), Read Aloud / TTS (`/api/audio/speak*`) | Task scope. Each needs its own session ownership and a device check. | §2.4 |
| Action Button / Siri `VoiceNoteIntent`, Home Screen quick action | Task scope. Needs App Intents and a durable request queue (`W:docs/action-button-voice-notes.md:44`). | `beginMemo(handsFree:)` |
| + menu "Voice Memo" and Bots "hold › Memo" | Their menus belong to the menus stream. Their set-aside rule is documented (§2.4). | `beginMemo(handsFree: true)` |
| Settings › Voice switch "Send Memo on Release" and its footer (`HO:design/DESIGN.md:934-936`) | The settings stream owns the page. This stream reads and honours the key (V12). | `hq.voice.sendOnRelease` |
| Background playback, Now Playing, lock-screen controls | Needs `UIBackgroundModes audio` and a review story (V14) | — |
| Raise-to-ear (proximity) playback, Telegram's | Not in the web app | — |
| Transcribing picked audio files (the web runs `voiceMemoReference` on **any** audio attachment, `voice-memo.ts:176`) | The attachments stream owns picked files. It should call this stream's `MemoUploader` transcription step for audio. | `MemoUploader.transcribe` |
| Memo wording in list previews (Bots/Sessions rows may show the raw `MEDIA:"…"` of a memo-last chat; neither the web nor M1 cleans it) | Lists code belongs to other streams. A follow-up should use `VoiceMemo.transcriptLine`. | — |
| iPad memo sheet, group rooms | iPad is deferred; rooms are not in native | — |
| The 25 MB transcription cap and multi-part STT | Hermes limit (`audio.py:49,107-108`); a 600 s memo is about 3.6 MB | — |

## 8. Stand-in gateway, launch hooks, commands

### 8.1 `NAT:scripts/fixtures/voice-gateway.py` (the builder writes it; stdlib only)

Base it on the REF performance fixture, which brings in build47 (streaming, plans, Stop) and action-voice (login):

```python
spec = importlib.util.spec_from_file_location('perf', REF / 'scripts/performance-fixture-gateway.py')
perf = importlib.util.module_from_spec(spec); spec.loader.exec_module(perf)
base = perf.base                 # build47 module; base.voice = action-voice; base.voice.auth = fake-gateway
```

Patch `base.rpc` (build47's socket loop calls **its own** `rpc`: `MEM:stuck-working-row.md:17`) and wrap
`base.handler`. Write a `main()` that builds `base.voice.auth.Gateway(username, password, True, None, media_dir)`, so
`self.media()` serves `/api/fs/download` with Range (`W:scripts/native-startup/fake-gateway.py:190-237`). Gate every
new REST route on `self.session()`. The "gateway filesystem" is `--media-dir`:

- files root `<media>/home`;
- attachments `<media>/home/.hermes/attachments` (default) and `<media>/home/.hermes/profiles/ivy/attachments`.

| Route / method | Behaviour |
|---|---|
| `GET /api/files?profile=` | `{"path":"<media>/home","parent":null,"entries":[]}`. Control `filesStatus` answers that status instead. |
| `POST /api/files/upload-stream?profile=` | Parse the multipart (`path`, `overwrite`, `file`). The path must be under `<media>/home/.dispatch-attachments/`. Write the bytes. Answer `{"ok":true,"path":path,"entry":{"name":…,"size":n}}`. Controls: `uploadStatus`, `uploadDelay`. Record `{path, bytes, sha256}`. |
| `DELETE /api/files?profile=` | Body `{path, recursive}`. Remove a staging folder under the root, else 404. Record it. |
| `file.attach` | **Strict keys** `{session_id, profile, path, data_url, name}`, otherwise error **4000**. Unknown session id → **4001** `session not found`; control `attachStale:n` forces it n times. Neither path nor data_url → 4015. Copy the file into the profile's attachments with Hermes' `-2`, `-3` … counter. Answer the full Hermes shape (§4.2 c) with `uploaded:true`. Control `attachFail` → **5028**. Record params, without the data_url bytes. |
| `prompt.submit` | Strict keys = `PromptSubmitParams` (`HA:…/contracts/prompt_voice.py:26-52`), otherwise **4000**. Control `submitRefuse:n` refuses the next n well-formed submits with 5000 (ledger `refused:true`). Then build47's plan behaviour. |
| `GET /api/config?profile=` | Performance's answer plus `"stt":{"enabled":STT[p]}` (default true). Control `stt: {"default":bool,"ivy":bool}`. |
| `POST /api/audio/transcribe?profile=` | Validate as Hermes does (`audio.py:86-106`): data URL, base64, audio mime, not empty, ≤ 25 MB. Default answer: `{"ok":true,"transcript":"Synthetic transcript of a <s> s voice memo.","provider":"fixture"}`, with seconds from the WAV/M4A header. Controls: `transcript`, `transcribeDelay`, `transcribeFail:{status,detail}`, `transcribeEmpty`. Record `{profile, mime, bytes}`. |
| `GET /api/fs/download?path=&profile=` | `self.media()` (Range, 206, 416). Gated. |
| `POST /__fixture/voice` | Set any of the controls above; `{"reset":true}` clears them and the ledger |
| `GET /__fixture/voice-state` | `{"filesReads":n,"uploads":[…],"attaches":[…],"deletes":[…],"configReads":[…],"transcribes":[…],"prompts":[ledger entries]}`. This is the exactly-once proof. |
| `POST /__fixture/memo-history` | `{"profile":"default","memos":[{"seconds":6,"transcript":"…"},{"seconds":3,"off":true},{"seconds":4,"missing":true}],"reply":"Got it."}`. Write WAVs with the web fixture's formula (`W:ios/App/App/HermesVoice.swift:553-572`), then append `MEDIA:"<path>"\n\nVoice memo transcript: …` user rows plus a reply row to `base.MESSAGES[profile]`. `missing` writes no file. |

Codes other than −32001 need a small shim. Raise `Coded(ValueError)` with the message `"<code>|<text>"`, and patch
`base.Client.send` to rewrite an error answer whose message starts with `"<digits>|"` into that code. The same
applies to `prompt.submit` errors sent from `Client.prompt`.

### 8.2 Ports and commands (this stream only: 9726–9728)

| Port | Use | Credentials (0600, in `build/fixtures/`, a 0700 folder) |
|---|---|---|
| 9726 | Manual / Simulator development | `voice-dev.json` |
| 9727 | XCUITest e2e (`scripts/e2e-voice.sh`) | `voice-e2e.json` |
| 9728 | Live unit-test suite (`Fixtures.voicePort`, `TEST_RUNNER_HQ_VOICE_FIXTURE`) | `voice.json` |

```sh
cd /Users/me/Projects/hermes-hq-native
mkdir -p build/fixtures && chmod 700 build/fixtures
lsof -nP -iTCP:9726 -sTCP:LISTEN && echo "9726 busy: stop here" || \
python3 scripts/fixtures/voice-gateway.py --port 9726 --credentials build/fixtures/voice-dev.json \
  --media-dir build/fixtures/voice-media-9726 --ref /Users/me/Projects/hermes-hq-native-ref238 \
  > build/fixtures/voice-9726.log 2>&1 &
echo $! > build/fixtures/voice-9726.pid
curl -s -X POST http://127.0.0.1:9726/__fixture/memo-history -H 'Content-Type: application/json' \
  -d '{"profile":"default","memos":[{"seconds":6,"transcript":"Pick up milk on the way home."},{"seconds":3,"off":true},{"seconds":4,"missing":true}]}'
curl -s -X POST http://127.0.0.1:9726/__fixture/voice -H 'Content-Type: application/json' -d '{"transcriptDelay":2}'
curl -s http://127.0.0.1:9726/__fixture/voice-state | python3 -m json.tool
kill "$(cat build/fixtures/voice-9726.pid)"        # stop only what you started

# live unit tests (MemoUploader against the fixture)
python3 scripts/fixtures/voice-gateway.py --port 9728 --credentials build/fixtures/voice.json --media-dir build/fixtures/voice-media-9728 --ref … &
TEST_RUNNER_HQ_VOICE_FIXTURE="http://127.0.0.1:9728|$PWD/build/fixtures/voice.json" scripts/build.sh test <HQN-voice udid>

# e2e (the script starts and stops its own fixture on 9727, like scripts/e2e.sh)
HQN_VOICE_PORT=9727 scripts/e2e-voice.sh <HQN-voice udid> [runs]
```

Rules:
- Use your own simulator, **`HQN-voice`**. Create it if it is missing:
  `xcrun simctl create HQN-voice "iPhone 17 Pro"`. Never use `HQ Native`, `HQN-*` of other streams, or any web
  app sim.
- Never log in in a loop: one sign-in per test (`NAT:docs/ARCHITECTURE.md`; spec 01 §0 rule 4).
- Never contact 100.101.102.104 or `*.ts.net`.

### 8.3 DEBUG launch hooks (add to `NAT:App/Debug/DebugHooks.swift`, compiled out of Release)

The Simulator's microphone is not reliable. The web found "voice memo recording (mic never starts)" there
(`MEM:chat-visibility-alignment.md:26`). Port its fixture recorder instead (`HermesVoice.swift:270-315,456-458`):

| Argument | Effect |
|---|---|
| `-HQDebugMemoFixture granted\|undetermined\|denied` | Use `FixtureMemoRecorder` (simulator only). The permission state is simulated; `undetermined` becomes granted 0.3 s after the "prompt". It writes a 16 kHz mono WAV `voice-memo.wav` (`audio/wav`). Levels follow `max(0.04, 0.42 + 0.3·sin(4.1t)·sin(0.9t+1) + 0.12·sin(17t))`. |
| `-HQDebugMemoStartDelay <s>` | Time before `begin` resolves (default 0.08) |
| `-HQDebugMemoLimit <s>` | Overrides the limit (fixture only) |
| `-HQDebugMemoInterruptAfter <s>` + `-HQDebugMemoInterruptReason interrupted\|route-lost\|reset` | Calls `nativeStop(reason)` that long after recording starts |
| `-HQDebugSendOnRelease NO` | Sets `hq.voice.sendOnRelease = false` for this launch |
| `-HQDebugResetVoice YES` | Clears speed, tips, drafts, shapes and the cache |
| `-HQDebugMemoProbe YES` | Exposes the locked recorder's live waveform to UI tests (`memo.live`, value `bars=<n>;distinct=<k>`) |

Add `NSMicrophoneUsageDescription` to `NAT:App/Info.plist` (it is missing today, and recording would crash):
"HQ Native uses the microphone to record voice memos you send to your bots."

## 9. Acceptance checks (all must pass before the stream is "done")

**Unit tests** (Swift Testing, `scripts/build.sh test <HQN-voice>`):

- **A-U1** — Reducer: port every case of `W:src/ui-voice/memo-gesture.test.ts:21-178` (17 cases). Include:
  - the 1.0 s rule counted from `started`, not touch-down;
  - lift-before-confirm locks;
  - the cancel line at `min(120, 35 %)`;
  - −72 locks;
  - pointer-cancel → draft;
  - limit while held and while locked;
  - leave → draft;
  - a11y-open → locked;
  - a second touch ignored.
- **A-U2** — `MemoPolicy`:
  - the `finish` table;
  - `level(−50) = 0`, `level(0) = 1`;
  - `peaks` of 3 samples into 48 bins;
  - `limitSeconds(32 MB) = 600`, `limitSeconds(512 KB) < 10` → too small.
- **A-U3** — `MemoText`:
  - the build/parse round trip for stored, optimistic, failed-send, off, failed, empty → "(No speech detected)", and
    memo + typed text (`rest`);
  - `gatewayMemoPath` accepts `/a/voice-memo.m4a` and `C:\x\voice-memo.wav`;
  - it rejects a quote, a newline, a relative path, a backslash in a POSIX path, and `.txt`.
- **A-U4** — `MemoUploader` against a recording fake client:
  - the exact call order `config ∥ files → upload → file.attach → delete → transcribe → prompt.submit`;
  - `file.attach` params are exactly `{session_id, profile, name, path}`;
  - the multipart body is byte-exact to §4.2 (b);
  - no delete when `uploaded == false` or the path is inside staging;
  - STT off → no transcribe call and the off wording;
  - transcribe error → `(unavailable)` + one notice;
  - an unquotable path → `ref_text` sent with no transcribe;
  - attach 4001 → one resume + one attach with no second upload;
  - a (g) refusal followed by a retry into the same chat → 1 upload, 1 attach, 1 transcribe in total;
  - into another chat → uploaded again.
- **A-U5** — Stores:
  - `MemoShapeStore` keeps 64 and links local → gateway;
  - `MemoDraftStore` round-trips, newest first, never deletes a recording it didn't Remove, keeps a queued memo's words,
    and follows a moved container;
  - sign-in excludes memos/ and memos/<key>/ from backup and sweeps recordings no draft refers to once a day old;
  - `MemoPlaybackCache` LRU and purge;
  - speed cycles 1 → 1.5 → 2 → 1 and persists.
- **A-U6** — Layout:
  - a drawn cell's memo parts sit inside the measured bubble (above its bottom padding, no blank band) at Large and
    AX5, with and without a transcript, clamped and open;
  - playing a real file and changing the speed move no part and change no height;
  - the bar count follows V10.
- **A-U7** — `MemoWaveform.compute` on the fixture WAV gives 48 values in 0…1, max 1, and seconds within 0.02 of the
  length. It refuses a 700 s file.

**Live fixture tests** (port 9728, `.enabled(if: Fixtures.voiceAvailable)`):

- **A-L1** — Send a fixture memo end to end. `voice-state` shows exactly one of each of: files read, upload, attach,
  delete, transcribe, prompt. The prompt text equals §4.1 with the fixture transcript. The history read back parses
  as a memo with that transcript.
- **A-L2** — Download a seeded memo through `/api/fs/download`. It plays (`AVAudioPlayer` duration within 0.05 s)
  and its peaks compute. A missing memo → `HTTPError 404` → the load-failed state.
- **A-L3** — With control `stt.default=false`: no transcribe call, and the off wording is stored.

**End-to-end** (XCUITest `UITests/VoiceMemoEndToEndTests.swift`, run by `scripts/e2e-voice.sh` on port 9727, launched
with `-HQDebugResetAccounts YES -HQDebugMemoFixture granted -HQDebugResetVoice YES`). Use real touches only
(`press(forDuration:)`, `press(forDuration:thenDragTo:)`).

| # | Steps | Pass when |
|---|---|---|
| E-1 | Open Hermes's chat. Hold the mic 2.0 s and release. | One prompt in `voice-state`. Your bubble shows play, "0:02" (its waveform's value "… of 0:02") and then the transcript. The keyboard did not come up. |
| E-2 | Tap the mic (0.3 s). | The locked row shows (trash, red waveform, Stop, Send). After 3 s it is still recording and nothing was sent. Stop → review. Play → the time counts down. Send → one prompt. The "Hold to Record" tip shows once afterwards. |
| E-3 | Hold, wait 1.5 s, release **without moving**. | It sends (the native counterpart of `testStillHoldAndReleaseIsHeard`, `MEM:voice-memo-bugs.md:15,20`). |
| E-4 | Hold and drag left 150 pt. | "Release to Cancel" shows. On release: no upload, no prompt, no draft. |
| E-5 | Hold and drag up 100 pt. | Locked. Release keeps it recording. |
| E-6 | Locked for 12 s, then trash. | The alert reads "Delete this 0:12 voice memo?". Keep Recording continues; trash → Delete → idle, nothing sent. |
| E-7 | `-HQDebugMemoFixture undetermined`. Touch the mic. | Nothing records (no red, no upload). The tip "Now Hold to Record" shows. The next hold records. |
| E-8 | `-HQDebugMemoFixture denied`. Touch the mic. | The card "Microphone Access Is Off" with Open Settings and Close (no Copy Details: nothing to copy). It stays until closed. |
| E-9 | Lock a memo in Hermes, go Back, open Ivy, then open Hermes. | Ivy's composer has no chip. Hermes's has "Voice Memo 0:0x". Its Send → one prompt in Hermes's chat only. |
| E-10 | `-HQDebugMemoInterruptAfter 2` while holding. | The card "Recording Stopped — A call or Siri took the microphone. Your 0:02 memo is waiting in the message field." The chip appears and nothing is sent. |
| E-11 | Control `stt.default=false`. Send a memo. | The bubble reads "No transcript: speech-to-text is off on your gateway." Transcribes = 0. |
| E-12 | Control `transcribeFail {status:500}`. Send. | The memo is still sent with `(unavailable)`. The bubble reads "No transcript". The card reads "No Transcript for This Voice Memo". |
| E-13 | Control `filesStatus 500`. Send. Then `submitRefuse 1`, Send on the chip. Then Send again. | First: no prompt, an error card, the chip back. Second: the submit is refused (error card, chip back) after one upload and one paid transcription. Third: one prompt, and in all 1 upload, 1 attach, 1 transcription. |
| E-14 | Plan a slow reply, send text, then hold-send a memo while it streams. | The queue card shows "Voice Memo 0:02". After the reply ends it sends with `queued:true`. |
| E-15 | Seeded history (3 memos). Play the first. Tap 1×. Relaunch. | It plays and the bars fill. The speed goes 1.5× → 2× → 1×, and 1.5× is still set after the relaunch. Starting memo 2 pauses memo 1. The missing memo shows "Couldn’t load audio · Retry". |
| E-16 | `-HQDebugMemoLimit 12`. Hold through 12 s; then a second take, locked through 12 s. | The held take sends at the limit. The locked take goes to review. The timer is orange from 0:02. |
| E-17 | During a 4 s upload delay, tap Back to Bots. | The prompt still lands in that chat (ledger), not another. |
| E-18 | Seed 10 memos. Drag 260 pt down starting on a memo's waveform. | The chat scrolls with the finger (the bubble moves > 120 pt); nothing plays. |
| E-19 | `-HQDebugMemoProbe YES`. Tap-lock a take, wait 0:20 and 1:16. | The live waveform still has varied bars at 1:16 (`memo.live` value), not a flat or solid block. |
| E-20 | Plan a slow reply, send text, hold-send a memo (queued), go Back, wait, reopen. | The memo goes out off screen once the reply ends (uploaded, a second prompt). Reopened: no chip, no "Memo Saved as a Draft". |

**Performance and launch:**

- **A-P1** — Start latency. `startLatencyMs` (touch-down to red) is ≤ 150 ms on a device and ≤ 120 ms on the
  simulator fixture (delay 0.08; this proves the fixture path only). No main-thread work over 4 ms during a hold
  (Instruments or signposts). On a device, read the os_signpost intervals "memo start" (touch-down → recording) and
  "memo send" (release → optimistic bubble), subsystem `com.charlesmcdowell.hermeshq.native`, category `memo`.
- **A-P2** — Launch. `-HQLaunchTime` `didFinishLaunching` grows by **≤ 15 ms** against main on the integration sim
  after linking AVFAudio. If it grows more, move the voice code into an embedded framework that is `dlopen`ed on the
  first mic touch or the first memo bubble shown. That is public API and the same idea as the AuthenticationServices
  fix (`NAT:docs/ARCHITECTURE.md`, verification round 2).
- **A-P3** — A chat with 50 seeded memos scrolls at the M1 baseline frame rate. Waveform computation and file I/O
  never run on the main thread. Only visible bubbles compute.

**Device checks for the owner's TestFlight notes** (the simulator cannot prove these; `W:docs/voice-device-checklist.md:120-147`):

- The first word is kept.
- AirPods record over HFP and play back.
- A call or Siri mid-memo leaves a draft.
- Music pauses on play and **resumes** after.
- The silent switch on still plays.
- Unplugging headphones pauses.
- The lock and cancel haptics are felt and do not show in the recording.
- Locking the phone mid-memo leaves a draft.

## 10. Risks and UNKNOWNs

- **R1** — The attachments stream builds the same staging upload. Two `GatewayTransfers`/stagers would collide at
  integration. Agree on one owner early (§2.2).
- **R2** — The managed-files API can be unavailable or locked on some gateways (hosted roots,
  `_managed_write_target` refusals, `HA:…/files.py:628-634`). Then memos cannot send, exactly as on the web. There
  is no `data_url` fallback (V1). The draft keeps the audio.
- **R3** — `setAllowHapticsAndSystemSoundsDuringRecording(true)` is a deviation from the web. A haptic could be faintly
  audible in the memo. Check it on a device. If it is, drop the flag and accept silent lock and cancel.
- **R4** — Composer layout conflicts. This stream adds the mic, chip slot, recorder host and notice card. The
  attachments (+, tray) and menus (☰) streams edit the same `ComposerView` and dock.
- **R5** — LiveGatewayClient's REST timeout clamp (120 s today) must rise to 600 s for transcription. It is a shared
  file.
- **R6** — The watchdog-arming change and the strong `self` capture touch M1's send path. A wrong edit regresses the
  text send. Run `scripts/e2e.sh` (M1 e2e) as well.
- **R7** — `AVAudioRecorder` start latency on older devices with Bluetooth HFP can exceed 150 ms. The reducer already
  counts the 1 s from `started`, so nothing sends a stub (`W:src/ui-voice/memo-gesture.test.ts:56-64`).
- **R8** — The fixture's strict-params shim imitates Hermes' 4000 but is not Hermes. Real validation comes from the
  owner's gateway at release.
- **U1** — On some hosted setups `GET /api/files` may answer a display path the gateway cannot resolve for
  `file.attach` (`HA:…/files.py:507-529` returns `display_path`). This is unverified on Windows and hosted gateways.
- **U2** — Whether `AVAudioPlayer` keeps the pitch at 1.5× and 2× well enough for speech. Check it on a device. If
  not, switch to `AVAudioEngine` with `AVAudioUnitTimePitch` (still AVFAudio).
