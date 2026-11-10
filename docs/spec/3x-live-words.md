# 3x — Live Words: words as you speak, in voice memos and Talk

Branch `feat/live-speech-text`, worktree `/Users/me/Projects/hermes-hq-native-wt/live-stt`. Builds on voice memos
(`1x-voice.md`), Talk (`3x-talk.md`) and GPT-Live (`3x-gpt-live.md`).

## 0. What the owner asked for

> "I'd like to try to pull off live speech to text. Voice memos, and I forgot what the feature is called, where like you
> can basically talk with your agent, but for both." (2026-11-01; "talk with your agent" is Talk.)

The owner hands design calls over ("make the best decision you can", `MEM:owner-delegates-design-calls.md`). The calls
made here are listed in §8.

## 1. What it does

- While a voice memo records (held, locked, ending) and while it waits in review, the words show as they are said
  where typed words go: the composer grows to the two rows it has for typing, the words on top and the recorder's row
  under them (§4).
- While Talk listens (a take, or speech that cuts into a reply), the Talk bar grows the same top row above its
  controls.
- The words shown when it settles are the words that go:
  - A memo carries them, and the send uses them as its transcript. The gateway's `POST /api/audio/transcribe` (paid,
    seconds long) is never called.
  - A Talk turn is sent with them at once. The "Transcribing…" wait and its gateway call are gone.
- GPT-Live already streams its own transcript of what the person says. Those deltas show in the same row; nothing on
  this device listens then.

## 2. The engine

Apple's on-device speech engine (iOS 26+):

- `SpeechAnalyzer` runs the `SpeechTranscriber` module (preset options `[.volatileResults, .fastResults]`).
- Where the device or language doesn't offer that, it falls back to `DictationTranscriber` with
  `.progressiveLongDictation`.
- The language is `Locale.current`, then the first four preferred languages, matched with
  `supportedLocale(equivalentTo:)`.
- The model is downloaded once through `AssetInventory`: `reserve(locale:)`, then the installation request. A chat
  that opens with voice available starts the check (`LiveWords.prepare()`), so the model is usually there before the
  first word.
- Results:
  - A final result's words join the **settled** text.
  - A volatile result replaces the **pending** text.
  - `SpeechTranscriber` can keep a whole sentence volatile until the speaker pauses (on the Mac test below, an
    11-second memo stayed volatile to its end). So the words row draws only the newest two words lighter, not all pending
    text.
- Ending a take closes the input and waits for `finalizeAndFinishThroughEndOfInput`. On a Mac that takes about 85 ms.
  The wait is capped at `LiveWords.settleLimit` (1.5 s); past it the words so far go.
- Audio: every listener is fed 16 kHz mono Int16, converted to the analyzer's best format with `AVAudioConverter`.
  - Talk: `TalkCaptureCore` already makes exactly these samples. It feeds the take's listener after it lets go of its
    lock.
  - Memos: `AVAudioRecorder` keeps recording the file untouched. A second tap (`LiveWordsMic`, an `AVAudioEngine`
    input tap without voice processing) feeds the listener. If the tap can't start, the memo still records, and the
    gateway transcribes it as before.

`HermesKit/Voice/LiveWords.swift` holds the engine, the listener, the memo tap and the DEBUG stand-ins.

### 2.1 The tidy pass (`LiveWordsTidy`)

> "Now that you should have some pretty good logs on me using the sending a voice memo and it live streaming my words,
> how can we improve it?" (owner, 2026-11-02; "Yes build all." to the five fixes below)

The 2026-11-02 study read the owner's memo words in Hermes's `state.db` (the app's logs never hold words). Apple's
engine heard every memo fast, but wrote names the gateway had got right as other words: "clawed code" (Claude Code),
"Kua" (CUA), "from mountain" (for Robin), "Jack Skeleton", "test flight", and kept every "uh" and "um".
`AnalysisContext.contextualStrings` exists in the iOS 27 SDK, but fed those names it changed nothing on the owner's own
recordings: `SpeechTranscriber` ignores it, and `.alternativeTranscriptions` offered nothing better.

So every listening's words go through `LiveWordsTidy` after the engine, as shown and when they settle
(`LiveWords.listen` wraps the listener in `TidiedLiveWords`; memos, Dictate and Talk alike):

1. **"uh" and "um" are left out** (uh, uhh, um, umm, uhm, erm). The sentence still reads: a comma left dangling goes,
   a sentence that started with one starts with the next word capitalised, and one that ended with one keeps its full
   stop ("I think, um." → "I think.").
2. **The person's fixes** (§5, `WordFixes`) are written, longest first, case-insensitively, whole words only.
3. **Names are written as names**: the built-in list (Hermes, Hermes HQ, Claude Code, Codex, Composio, TestFlight,
   Nous Research, Home Assistant, GitHub, OpenAI, ChatGPT, Tailscale, Telegram, iPhone, iPad, macOS, Kanban) and the
   signed-in account's bot names (`LiveWordsVocabulary.botNames`, set by the app model).
   - Spelt apart or together: "test flight", "testflight" → TestFlight; "chat gpt" → ChatGPT.
   - A name with its own casing is cased: "iphone" → iPhone. A one-word name without it ("Home", "Ivy") is left alone,
     so "go home" stays.
   - A name of two words or more also matches by sound, word for word (a Metaphone key where a W or Y after a vowel is
     silent): "clawed code" and "cloud code" → Claude Code. One-word names never match by sound: "her mess" stays.
   - A match never reaches across a comma or a sentence's end, keeps the punctuation around it, and a name that starts a
     sentence keeps its capital.

`HermesKit/Voice/LiveWordsTidy.swift` holds the pass, `Phonetic`, `WordFixes`, `LiveWordsVocabulary` and
`TidiedLiveWords`.

## 3. Where the words go

### 3.1 Voice memos (`MemoController`)

- The listener starts once the recorder has started.
- **Send, review, draft:** the listener finishes, and its words go into `MemoFile.words`. Older drafts decode with
  `words == nil`.
- **Cancel:** the listener is cancelled, and nothing is kept.
- **A system stop** (call, route loss) that leaves a draft settles the words into the draft before it is saved.
- **Review** shows the settled words in the composer's top row until the memo is sent or thrown away. They can be
  fixed there (§3.1.1).
- `MemoUploader.stage`:
  - A memo with words sends `Voice memo transcript: <words>` and skips the gateway's speech-to-text check.
  - A memo with no words (nil or blank) goes the old way.

#### 3.1.1 Fixing the words in review

- In review a tap (a click on the Mac) on the words opens them for editing where they are: a text view in the same
  italics, the caret where the tap landed, the keyboard up. VoiceOver: "Double-tap to fix a word." Nothing leads the
  words (no pencil): the owner turned down a glyph before them (§4.1).
- Each change goes to `MemoController.reviseWords`: the memo's `words` become the edited words (none when cleared: the
  gateway transcribes it then). The row grows with them, up to its four lines, then scrolls.
- Return or a tap elsewhere ends the editing; the words stay as edited. Send sends them; the trash throws them away with
  the memo.
- **Learning:** a memo sent with fixed words teaches `WordFixes.learn(from: heard, to: sent)`. The two are compared word
  by word (longest common run); each stretch of one to three heard words replaced by one to four others is kept as a
  fix when at least one heard word isn't an everyday word ("Kua" → "CUA", "from mountain" → "for Robin"). Everyday
  rewording ("you" → "we") is an edit of one memo, not a fix for every memo; a casing fix counts ("kua" → "CUA"), a word
  made lowercase (two sentences joined) doesn't.
- While recording the words stay read-only: they still change, and a finger on them would fight the mic.

### 3.1.2 Queued behind a reply

A memo sent while the bot is still answering waits in the chat's queue (1x-voice §4.4). Leaving the chat no longer
hands it back as a draft: it rides the queue like typed words, so the chat keeps listening off screen and sends it when
the reply ends, and a queue left behind (parked by Stop or a refusal, or the app killed) is written with its memos and
shows again, paused, when the chat opens. Read back, a memo's path is rebuilt under today's container
(`MemoPaths.rebase`), one whose recording is gone is dropped, and the daily memo sweep keeps the recordings a stored
queue holds. Only a chat that keeps no queue (tests, previews) still hands its memos back as drafts. Build 573 put a
memo queued behind a reply back in drafts when the owner left the chat; it sat there 19 minutes (2026-11-01).

### 3.2 Talk (`TalkController`)

- `.beginTake` makes a listener per take and hands it to the capture, which attaches it to the `TalkTake` it emits.
- A barge-in gets its listener when `.bargeSpeech` fires. `hearUtterance` feeds it the backlog of that utterance (its
  pre-roll on), so its first words aren't lost.
- `.transcribe(file)` asks the take's listener first ("words from this device in N ms"). If it heard nothing, the
  gateway transcribes ("this device heard no words: the gateway transcribes").
- Discarded, cancelled and orphaned takes cancel their listeners. Ending Talk cancels all of them.
- The Talk bar's words are per conversation (`words(in:)`, `wordsChanged`). They clear when the turn is submitted or
  the take is cancelled.

### 3.3 Dictate (`DictationController`)

> "I added a picture to the text box to send to an agent, and then did the voice transcription to send it a voice
> memo, and it did not show my words, but then when I clicked send, it only sent the picture." (owner, 2026-11-01)

With a picture in the tray (or words in the field) the mic is Dictate, which first got no Live Words.

- Dictate listens like a memo: once its recorder records, a listener and its `LiveWordsMic` tap start. The
  `AVAudioRecorder` take is still written, for the gateway fallback.
- The words show in the composer's top row above the dictation row (§4.2 with the dictation row in the recorder's
  place). *Listening…* holds their place until the first word.
- Stop / Done / the limit stops the tap, and the words settle while the file closes. Words heard here are typed into
  the field at the cursor (spec 3x-talk §8 step 4), and `POST /api/audio/transcribe` is never called. With no words, the
  gateway transcribes the take as before.
- Cancel cancels the listener, and nothing is typed.
- While Dictate runs, the composer's circle is Stop Dictation (✓) whatever is in the field or the tray (3x-talk §5.1).
  The words aren't in the field until it stops, so a Send then would go without them. A hardware Return does what the
  circle does only when it is Send, so it sends nothing while Dictate runs.

### 3.4 GPT-Live

- `LiveTranscriptFragment(speaker: .user)` appends to the settled words.
- An assistant fragment clears them: the bot is answering.

## 4. Where the words are drawn (`LiveWordsView`)

> "When it's doing this I want the chat bubble to turn in to the 2x height that it does when you start typing on it
> and I want the voice transcription to come through where you would normally be typing but somehow displayed a little
> different than typed words to showcase that it's not something the user typed." (owner, 2026-11-01, after the first
> build drew the words in a glass card over the chat)

### 4.1 Heard, not typed

- `LiveWordsView` draws the words. It is read-only: no caret, no keyboard, no selection.
- The words are in italics of the composer's own face (the same size typed words have): heard, not typed. That is a
  cue beyond colour (a colour alone fails for colour-blind people, and the obvious colours already mean something:
  blue a link, grey a placeholder, a red underline a typo). The recorder's row right under them says the rest.
- Nothing leads the words. The first build put a `waveform` symbol in the tint before them; the owner didn't like it
  ("I don't like the voice icon before the text. The font itself is fine.", 2026-11-01).
- The newest two words are `ChatPalette.label2`: the engine may still change them. Everything before them is
  `ChatPalette.label`.
- Before the first word, *Listening…* (`label3`) holds their place.
- The newest words sit at the end. Past the line limit the oldest give way behind "… ".
- The words are measured by a label like the one that draws them, never `boundingRect`. In the Desktop Look's 15 pt
  type `boundingRect` came out 2.5 pt short for two lines, and the label dropped the second.
- Accessibility: id `voice.words`, label "What You Said", value the words (or "Listening"); traits static text and
  updates frequently.

### 4.2 Memos: the composer's two rows (`ComposerView.heard`)

- With the recorder on the bar and Live Words listening, the bar grows to two rows as it does for typing:
  - the words on the top row, where typed words start (16 pt in from the bar's edge and top in the iOS look; the
    field's own padding and one-line inset in the Desktop Look's box);
  - the recorder's row (held: timer and "Slide to cancel"; locked: trash, waveform, stop; review: play, waveform)
    under them, in its usual 44 pt, with the circle at its end.
- The recorder's row keeps its height and its place. The bar grows upward, so nothing moves under a finger holding
  the mic, and Send stays where it was.
  - The recorder's circle is placed from the row's own bottom (`micCenter`), not the field's last frame: the screen
    asks while the bar is growing, and the circle drew 22 pt above its row.
- The row opens as recording starts (*Listening…*), when this device listens (`MemoController.hearsWords`). With Live
  Words off or unavailable the recorder keeps one row, as before.
- Once recording stops (ending, review) only words keep the row: with none heard, the bar folds back to one row.
- Held, the words stop 64 pt short of the recorder's circle (`heardLimitX`), clear of its halo and the lock above it.
  Locked or in review they have the bar's width.
- At most four lines (three at accessibility sizes).
- The words fade in over 0.2 s as the bar grows, and out over 0.12 s; Reduce Motion: at once.

### 4.3 Talk: the bar's top row (`TalkBarView.showWords`)

- With words, the Talk bar's box grows a row above its controls: the words on it at 16 pt from the box's edge (the
  field's padding in the Desktop Look), at most three lines, in body type capped at `.accessibilityMedium`.
- The controls keep their row and End its padding at the bottom; the box keeps its one-row corner radius, so its
  corners stay concentric with End's.
- The row goes when the words clear (the turn submitted, the take cancelled).

## 5. The setting

- It lives at Settings › Voice › Voice Conversation › **Live Words** › "Words as You Speak", and is on unless turned off
  (`hq.voice.liveWords`).
- Under it, **Word Fixes** (its count as the value) opens the fixes this device writes:
  - each row the written words, with "Heard as “…”" under them, newest first; a swipe, a right-click or the Mac's red
    minus deletes one;
  - **Add Word Fix…**: "Heard as" and "Write it as", Save;
  - **Remove All Word Fixes…**, confirmed.
  - The footer says where fixes come from (words fixed in a memo before sending), that bot names, Hermes and Claude
    Code are always spelt right, and that "uh" and "um" are left out. Empty, it says how to fix a word.
  - Kept on this device in `hq.voice.wordFixes`, newest 200.
- Its footer says what happens on this device now, and only that:
  - On and ready: "This iPhone turns your speech into text as you talk, so memos, Dictate and Talk skip the speech to
    text on Hermes."
  - Downloading: "This iPhone is getting its speech model ready. Until then, Hermes turns your speech into text after
    you stop."
  - Can't (language not offered, or the device): "This iPhone can’t show your words as you speak, so Hermes turns your
    speech into text after you stop."
  - Off: "Off: Hermes turns your speech into text after you stop."
- With it off, no words row shows, and every memo and take goes to the gateway as before.

## 6. Failures and diagnostics

- Any failure leaves the old path. That covers a language not offered, an unsupported device, a download still running,
  no audio format, an analyzer error, and a tap that won't start.
- Nothing shows a notice for it, because the voice still works.
- Errors are noted in VoiceEvents with domain and code only. Readiness changes go to AppLog. **The words themselves are
  never logged.**
- Each memo take writes one line about its words (Detailed Logging, category `talk`), never the words:
  - "memo #tag words: N from this device in Ss, first after N ms, settled in N ms" (and "(hit the limit)" at 1.5 s);
  - "memo #tag words: none heard in Ss, settled in N ms; the gateway transcribes";
  - "memo #tag words: this device didn't listen (<diagnostics line>); the gateway transcribes".
- A cancelled take says so: "memo #tag ended (cancel): Ss, nothing kept", or "… before recording started".
- A memo sent with fixed words: "memo #tag words fixed in review: N word fixes kept".
- The chat's send line for a memo reads "memo Ss, words N chars from this device | no words (the gateway transcribes),
  typed N chars". It used to give the send's text length, which for a memo is its placeholder (its file path): 187
  every time, and it read like the transcript's length.
- Voice Diagnostics gains an eleventh row, **Words as You Speak** (report name "Live words"). It reads "on this device
  (en_US)", "on this device (en_US, dictation model)", "downloading the speech model", "gateway (device not supported)"
  or "off".

## 7. How it is tested

- Apple's engine doesn't run in iOS simulators ("not supported"). Unit tests use stand-in listeners:
  - `CountingListener` counts what it's fed.
  - `ScriptedLiveWords` reveals a script a word at a time, with the newest two pending.
- `Tests/Voice/LiveWordsTests.swift` covers:
  - Joining words, and the settle deadline.
  - The capture feeding a take's and a barge-in's listener, and cancelling it.
  - Talk sending the words without the gateway, and falling back to the gateway when nothing was heard.
  - A memo carrying its words, and a cancelled memo letting its listener go.
  - The upload using the words as the transcript, and older drafts decoding.
  - The words view: whole lines drawn, the newest words kept, only the newest two lighter, italics and nothing before them,
    *Listening…*.
  - The composer's two rows: *Listening…* opens the row, more words grow it (four lines at most), a held memo's words
    wrap sooner, the recorder's row keeps its height at the bottom, and the bar folds back with the recorder.
  - The Talk bar's words row (both looks): above the controls, End's padding kept, nothing outside the bar.
- `Tests/Voice/LiveWordsTidyTests.swift` covers the tidy pass on the owner's own misheard memos (fillers, names by
  spelling and by sound, fixes, everyday words left alone), the sound keys, what a fix teaches and what it doesn't,
  the kept list, the tidied listener, the memo's log line holding no words, and fixing words in review (sent with the
  fixed words, the fix learned; cleared words leave the memo to the gateway).
- `MemoUploaderTests.leavingAnAppChatKeepsAQueuedMemoInTheQueue` and the stash's disk test cover §3.1.2.
- DEBUG launch arguments:
  - `-HQDebugLiveWords "<words>"` makes every listener a `ScriptedLiveWords`. Use it for simulator screenshots of the
    words row.
  - `-HQDebugLiveWordsFile <wav>` feeds a memo's listener from a WAV in real time instead of the microphone. On a Mac
    (Catalyst), where the engine runs, this checks the real engine end to end without a microphone. The feed is driven
    by the clock (each tick feeds what is due): a fixed chunk per tick fed half speed on a busy machine, and cut
    the memo's second sentence.
- The real engine, run on this Mac (macOS 27, en_US) by compiling `LiveWords.swift` into a command-line harness with
  the file feed (2026-11-01). It played an 11 s `say -v Samantha` recording of two sentences:
  - First words after 1.2 s, then new words about every second.
  - Final words 0.1–0.25 s after the input ended, every word right ("3 o'clock", "Priya").
  - `DictationTranscriber` updated a little more often but heard "Hey Hermes" as "Play Hermes". `SpeechTranscriber`
    stays first.
- **Proven on the owner's iPhone** (log study, 2026-11-02): `AVAudioEngine` and `AVAudioRecorder` share the microphone
  during a memo. Memo to bot went from about 6 s (median; 5–45 s while the gateway transcribed) to about 0.15 s, and no
  `/api/audio/transcribe` calls were made since build 573.
- The tidy pass was first run on the owner's memos as the engine heard them, in a command-line harness, before it went
  into the app (the cases in `LiveWordsTidyTests`).

## 8. Decisions made for the owner

1. **The words are where typed words go** (owner, §4). The first build's floating card is gone: the composer grows to
   its two typing rows, as the owner asked, and the chat above moves up as it does for typing.
2. **The words seen are the words sent.** The alternative, showing the words but still sending audio to the gateway,
   would pay for a second transcription and could send different words from the ones the person watched appear.
3. **The gateway stays the fallback.** Unsupported languages and devices behave exactly as before.
4. **The memo file is still uploaded.** The bot can still listen to it. Only the transcript comes from the phone.
5. **On by default, with a switch** in Voice settings for anyone who prefers the gateway's transcription (its model may
   know their vocabulary better).
6. **Four lines at most in the composer, three in the Talk bar.** More would cover the chat while recording a long
   memo; Talk's turns are short. The newest words always show.
7. **Heard words: italics, the newest two words lighter.** A cue beyond colour. The waveform before them is gone (owner,
   §4.1). Considered and left: the tint colour for the words (reads as a link), grey (reads as a placeholder, and a whole memo in grey read
   as disabled), an underline (reads as a spelling mark), a tinted highlight (reads as selected text).
8. **The recorder's row never moves.** The bar grows upward from it; the words row opens at once with *Listening…*
   rather than jumping open a second later with the first words.
9. **Read-only while recording; editable in review** (§3.1.1). A tap on the words is the way in, with no pencil or hint
   before them (the owner turned down a glyph there); VoiceOver says how. While recording they still change.
10. **Fix names after the engine, not in it.** `contextualStrings` did nothing on the owner's recordings; a pass over the
    words is the same on every device and can be tested (§2.1). Sound matching only for names of two words or more, so
    everyday words that sound like a one-word name are never changed.
11. **Fixes are learned, not asked for.** Fixing a word before sending is the one lesson; nothing pops up to confirm it.
    Settings › Word Fixes shows and removes them. Everyday rewording isn't learned.
12. **Fillers go in every listening** (memos, Dictate, Talk): nobody wants "uh" sent to a bot.
13. **A queued memo behaves like a queued message** (§3.1.2): it goes when the reply ends, wherever the person is.
