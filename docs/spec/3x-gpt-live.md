# 3x — GPT-Live voice engine

Status: built on branch `feat/gpt-live` (2026-10-26), not merged, not in a build. Research and the decision to build it:
`docs/briefs/gpt-live-report.md`. Upstream reference: Hermes v0.22.5, commit f923faa0b8 (2026-09-11), the desktop app's
`apps/desktop/src/lib/voice-live.ts` and `.../composer/hooks/use-voice-live-conversation.ts`.

## 1. What it is

A second engine for Talk. Instead of take → speech to text → turn → text to speech, OpenAI's full-duplex `gpt-live-1`
model holds the conversation and hands every real request ("delegation") to Hermes as an ordinary turn in the chat. The
reply's words go back to the voice, which says them.

- Audio goes from the phone straight to OpenAI over WebRTC. It never passes through the gateway, and the phone does not
  need to be on the gateway's network for it (only the two REST calls and the chat do).
- The OpenAI key stays on the gateway. The gateway trades the phone's SDP offer for OpenAI's answer.
- Cost: about $0.05 a minute, idle time included. A long silence ends the session (§4).

## 2. Choosing the engine

At each start, `TalkController` reads the bot's voice settings (`voice.voice_chat_mode`) and, when GPT-Live could be
wanted, `GET /api/audio/voice-live/status`.

| Device choice (`hq.voice.engine`, Settings › Voice › Voice Conversation › Voice Model) | Gateway mode | Status `available` | Engine |
|---|---|---|---|
| any | any | false or no answer | Standard |
| none | `gpt-live` | true | GPT-Live |
| none | `chained` | true | Standard |
| Standard | any | true | Standard |
| GPT-Live | any | true | GPT-Live |

The choice is a Voice Model setting on this device (Settings › Voice › Voice Conversation: Standard / GPT-Live), as
the desktop app keeps it in its voice settings; until it is set, the page shows the gateway's mode. The long-press
voice options menu does not offer it. The status is prefetched when a chat opens and kept a minute, like the voice
settings. An older gateway (no route) answers 404 and the standard engine runs.

## 3. Wire

### 3.1 Gateway (REST)

- `GET /api/audio/voice-live/status?profile=` → `{ok, mode, available, reason?, model, voice}`. Never contacts OpenAI.
- `POST /api/audio/voice-live/session?profile=` with `{sdp, history?}` → `{ok, session:{id}, transport:{type:"webrtc", sdp}}`.
  The offer is sent byte for byte. 400 empty SDP, 503 no key, 502 OpenAI refused; the gateway's `detail` is shown in
  the stopped notice. Timeout 45 s.
- `history`: the chat's text turns, newest kept, at most 40 messages and 12,000 characters (1,500 per turn). The
  desktop sends 24 / 6,000 / 1,200; that was about five shortened replies of a working chat (owner, 2026-11-16: the
  voice "doesn't have the full context"). No limit is published, so a session that fails with the wide seed is asked
  for once more with the desktop's. The start waits for the chat to finish opening (at most 3 s; Talk from a bot's menu
  used to start on an empty chat), and when the chat goes further back than the page on screen and the seed has room,
  one read of 120 rows (at most 2 s, beside the microphone and peer setup) fills it (`LiveChatSession.spokenSeed`).

### 3.2 Data channel `oai-events` (in)

`session.started` (listening), `session.input_transcript.delta` / `session.output_transcript.delta` (the live
transcript), `session.delegation.created` (carries only an id), `error` (`context_injection_incomplete` is ignored),
`session.closed` (`reason`, `usage.seconds`).

### 3.3 Data channel (out)

`session.commentary.append` (reply text to say, ≤1,400 characters each, cut on sentence ends),
`session.thinking.append` (tool progress, "no spoken result"), `session.instructions.append` (Send Now, Interrupt),
`session.input_audio.mute` / `unmute`, `session.close`.

### 3.4 The delegated turn

`prompt.submit` with the usual fields plus `surface: "voice-live"` and `voice_context` (the spoken exchange of the last
five minutes, at most 80 fragments; the last 6,000 characters are sent). The bubble and the stored row are everything
the person said since the last delegation, joined across the voice's backchannels ("mm-hmm" mid-sentence used to leave
only the piece after it); an answer from the voice (10 words or more) in between starts it afresh. Leading punctuation
is dropped. The context goes to the model input only.

## 4. The loop (`LiveTalkLoop`)

A pure reducer beside `TalkLoop`, sharing `TalkLoopState` so the dock, the pill and the notices are unchanged.

- Status: Starting until `session.started`; Speaking while the voice's audio plays; Thinking while a delegation waits;
  else Listening.
- A delegation becomes a turn. A newer delegation stops a running turn first.
- Words spoken over a running reply (either engine) stop it and are the next turn: the chat stops the reply, holds the
  words until the stopped turn ends (at most the stop hold), then sends them without `queued`, so the gateway's busy
  mode (`display.busy_input_mode: interrupt`) takes them even if the stop is slow. They never wait in the queue as a
  pending message. Typed messages still queue.
- The reply is passed on in whole sentences while it streams, the rest when the turn ends. A reply that was already
  there when the delegation went out is never spoken. A turn that ends without words says so (thinking note).
- On `session.started` the voice is told: no backchannels, at most one short line while Hermes works, no progress
  narration (owner, build 407: too much filler). A seeded session is also told that what it was given is only the
  chat's latest part, that the backend has the whole chat and its memory, and to delegate anything earlier instead of
  asking the person to explain it or guessing (`LiveVoiceWire.chatNote`).
- GPT-Live and Grok Live play a local connected chime once when the live session is ready, instead of a spoken hello.
  The reducer emits `.connectedChime` on the first `sessionReady`; the controller plays it locally. A failed start
  does not chime, and the standard engine does not chime. The sound creates no model turn, fake history item, greeting
  prompt or remembered greeting; real chat history is still seeded normally.
- Nothing reaches the bot before the person has been heard: a GPT-Live delegation with no words from the person yet
  is answered with a note and not run; a Grok `ask_agent` call before xAI's speech start or the person's words is
  answered "nobody asked" with tools off. This protection remains even though startup no longer asks for a greeting.
- Progress notes are rare: the newest tool's title goes to the voice 20 s into a turn at the earliest, then at most every
  45 s, phrased so the voice need not say it.
- A turn the voice did not ask for (a bot's message, a finished background job, a schedule) is treated as one: its reply
  is spoken (no delegation id; `[SILENT]` says nothing), and the wait is Thinking, not silence.
- A refused send makes the voice say the request didn't go through.
- Nothing the app tells the voice, or makes it say, names a bot: Talk runs in every bot's chat, and "Hermes is still
  working" in Otto's chat sounds like a hand-off to Hermes (owner, 2026-10-27). The gateway's persona names the chat's
  own bot (Hermes `tools/voice_live.py`, branch `hq/handoff-notes`): "You are Otto", "Otto's agent".
- A bare stop phrase ends the chat once the person's words settle (1.5 s), so "stop the container" is still a request.
- Send Now asks the voice to answer now. Interrupt stops the turn and tells the voice to stop talking.
- The bot's questions are spoken (owner, 2026-11-16, app closed and a voice chat going: a question card nobody could
  tap). Every delegation's `voice_context` opens with a note that the person is on voice and not looking at the screen:
  no question card or clarify tool, ask in the spoken reply or choose and say so (`LiveVoiceWire.spokenOnlyNote`). If a
  clarify question still comes (`ChatVoiceTurns.openQuestion`, checked on every chat change and tick), the voice is
  given it to ask, with its choices; the microphone stays open; what the person says next answers it in the running
  turn (`answerQuestion`: the choice they named, by its words or "the first one", else their words) instead of becoming
  a request. Approval and sign-in cards still mute the microphone until answered; other audio mutes it. Not yet tried
  on a real session; the standard engine still shows the card.
- Long silence (the standard engine's pause window) ends the session: idle time is billed.
- Falls back, never strands the person: if GPT-Live can't start (the gateway or OpenAI refuses, WebRTC fails), or
  `session.closed` / a dropped connection arrives without the person ending it, the same conversation carries on with
  the standard engine (a fresh loop, its own microphone and leases). Only a denied or missing microphone stops it,
  since the standard engine needs the microphone too.

### 4.1 The conversation's words are kept with the chat (`VoiceChatRecord`, owner 2026-11-17)

The live voice's words and the person's were held in memory only: the bot learned what was delegated (and the last
five minutes with it, model input only), and nobody could read the conversation back. Owner: "the bot should have the
transcript. I mean you were literally talking to the bot."

- The controller gathers every transcript fragment of the live session, both speakers, in `Conversation.record`
  (not in the loop's bounded `transcript`). It outlives a fall back to the standard engine.
- When the conversation ends (any ending but a chat that went away), and the person said something other than the
  stop phrase, the chat is sent one message (`ChatVoiceTurns.sendVoiceRecord`): the line
  `[Voice chat transcript · m:ss]`, a bracketed note for the bot, a blank line, then `User: …` / `Voice assistant: …`
  lines. The newest 24,000 characters are kept. The gateway has no way to add words to a chat without a turn, so it
  is an ordinary turn: the note asks the bot not to act and to reply `NO_REPLY`, which the chat already hides.
- It is queued behind whatever the chat is doing, as an ordinary message: never typed into a running reply, which
  its "do not answer" note would have silenced, and never a hidden one (`display_kind: "hidden"` rows reach the bot
  but are not drawn: build 1073 sent it that way, and the chat showed no line). In the queue it reads "Voice Chat ·
  4:12", and taken out of the queue its words never fill the message box.
- Checked against real bots (2026-11-17, a GPT bot and an Opus bot, three runs): each answered `NO_REPLY`, acted on
  nothing in the transcript, and recalled a word from it when asked afterwards.
- The chat draws the message as one line, "Voice Chat · 4:12" with a waveform, that opens on the words ("You: …",
  "Voice: …"); the note is never shown. It is a row of its own, never folded into a run of updates. The Bots row's
  preview passes over it, and the next live session's seed gets its words without the note (and skips the folded
  delegated turns so the call is not seeded twice).
- **No duplicate bubbles above the Voice Chat card (owner 2026-11-27, Grok Bot model):** During an active live voice
  call, plain delegated user prompts and their plain replies/lookup tool steps stay folded out of the main chat
  stream rather than appearing both as chat bubbles and again inside the trailing Voice Chat pill. When the call ends,
  `ChatVoiceTurns.finishLiveVoice` decides atomically per turn: only completed turns whose non-empty replies were
  actually **heard** (`LiveTalkState.heardReplyIds`, after playback ends — never merely handed to the voice, cut off by
  barge-in/stop/connection drop, or interrupted; and never when a long transcript had to be truncated past `maxChars`)
  fold into the card. Their stable content-hash turn tokens (`[folded: u:<hex8>+a:<hex8>]`, or `[folded: none]` when
  nothing folded or the transcript was truncated) ride inside the hidden app note before the `NO_REPLY` instruction,
  surviving SQLite row-id renumbering on rewind/edit/regenerate and working identically across devices without running
  legacy text matching on new records. Fold holds are cleared once the record is acknowledged and rolled back
  immediately if the record is refused, stopped, removed from the queue, routed to a thread, or delivery-unconfirmed. Any turn still running or unheard unhides
  immediately on hang-up or fallback to Standard Talk; typed messages and typed steers stay visible; visual deliverables
  and interactive items (HTML page cards, media/attachments, bare image paths, Markdown images, code blocks, tables,
  clickable links, generated images, inline diff previews, draft/shopping/travel/ask/clarify/approval cards, task/file
  cards, bot DMs, errors, reactions, threads) remain visible in chat and searchable in Find. The live waiting capsule
  still shows while a folded delegated turn is thinking or running tools (so Steps remain reachable mid-call), retires
  once plain spoken text starts writing, and is suppressed while answering `VoiceChatRecord` (`NO_REPLY`). Consecutive
  same-speaker sentences insert clean spacing on sentence boundaries without splitting decimals, initials, domains, or
  jittery subword chunks.
- Cost: one short bot turn per live voice chat. The standard engine needs none of this: its turns are messages.

## 5. Transport (`WebRTCLiveVoice`)

- WebRTC is `stasel/WebRTC` 154.0.0 (binary framework: iOS, simulator, Mac Catalyst).
- `AudioSessionCoordinator` stays the only owner of the audio session: owner `.conversation`, mode `.voiceChat` (the
  system's echo cancellation). WebRTC runs on manual audio and is told when the session is active.
- ICE gathering waits at most 1.5 s, and only 0.3 s once the first candidate is in (build 410; was 10 s, and a start right after a wake waited ~8 s); the start logs each step's time ("gpt-live start steps"). Closing sends `session.close` and waits up to 15 s for `session.closed`.
- Levels come from WebRTC's stats five times a second, put on the web meter's scale.

## 6. Tests

`Tests/Talk/GPTLiveTests.swift`: the wire, the reducer, and the controller with `FixtureLiveVoice` (scripted events,
invented answer). `GPTLiveWebRTCTests` runs the real WebRTC peer in the simulator against a loopback stand-in for
OpenAI (set `HQN_FAKE_LIVE_URL`). The fixture gateway (`scripts/fixtures/voice-gateway.py`) answers the status route
with `available: false` (control `liveAvailable`) and the session route with 503, so the Talk UI tests keep running the
standard engine.

Not yet covered: a real device session (WebRTC audio, echo cancellation, Bluetooth), the Mac app, and a free
end-to-end run against a fake OpenAI server through `voice.gpt_live.base_url`.

## 7. Before an external build

Privacy policy, the App Store privacy label and the review notes must name OpenAI as a recipient of the person's voice
when GPT-Live is used.
