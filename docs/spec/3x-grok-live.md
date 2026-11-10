# 3x — Grok Live voice engine

Status: built on branch `feat/grok-live` (2026-11-02), not merged, not in a build. Needs the hermes-hq-push add-on
0.9.26 (its two routes below). A sibling of GPT-Live (`3x-gpt-live.md`): same loop, same dock, pill and notices.

## 1. What it is

A third engine for Talk. xAI's realtime Grok voice holds the conversation over a WebSocket; every real request comes
back as a call to its one tool, `ask_agent`, and becomes an ordinary turn in the chat. When the turn ends, the reply goes
back to Grok as the tool's output, and Grok says it.

- Audio goes from the phone straight to xAI. It never passes through the gateway (only the two REST calls and the chat do).
- The xAI login (SuperGrok / X Premium+ on the computer) or API key stays with the add-on. The phone gets a short-lived
  client secret for one session.

## 2. Choosing the engine

Settings › Voice › Voice Conversation › Voice Model: Standard / GPT-Live / Grok Live (`hq.voice.engine` = `grok-live`).
Grok Live runs only when this device chose it **and** the add-on's status says `available`; otherwise Standard. No
gateway mode names Grok (`voice.voice_chat_mode` never selects it), and a device that chose Grok never runs GPT-Live.

| Device choice | Grok status `available` | Engine |
|---|---|---|
| Grok Live | true | Grok Live |
| Grok Live | false, 404 (older add-on) or no answer | Standard |
| anything else | — | as `3x-gpt-live.md` §2 |

The status is prefetched when a chat opens (only on a device that chose Grok) and kept a minute, like the voice settings.

## 3. Wire

### 3.1 Add-on (REST, under `/api/plugins/hermes-hq-push`)

- `GET /voice/grok-live/status?profile=` → `{ok, available, auth: "subscription"|"api_key"|null, model, voice, reason?}`.
- `POST /voice/grok-live/session?profile=` with `{}` → `{ok, client_secret, expires_at, auth, url, model, voice, instructions}`.
  503 `{detail: "no_credentials"}`, 502 `{detail}`: the detail is shown in the fallback note, as GPT-Live's. Timeout 30 s.

### 3.2 Socket

`url` with the subprotocol `xai-client-secret.<client_secret>`. After `session.created` the phone sends `session.update`
(voice and instructions from the add-on, `server_vad`, PCM 24 kHz in and out, the `ask_agent` tool) and the chat's seed as
`conversation.item.create` messages (GPT-Live's limits: 24 messages, 6,000 characters).

In: `session.updated` (listening), `conversation.item.input_audio_transcription.delta|updated|completed` (the person's
words; a `completed` adds only what the deltas didn't), `response.output_audio_transcript.delta`, `response.output_audio.delta`
(played), `input_audio_buffer.speech_started` (barge-in), `response.created` / `response.done`,
`response.function_call_arguments.done` (`ask_agent`: the delegation), `error`. Anything else is ignored.

Out: `input_audio_buffer.append` (PCM16 mono 24 kHz, ~100 ms pieces; none while muted), `conversation.item.create`
(function outputs, news), `response.create`, `response.cancel`.

### 3.3 The delegated turn

The bubble is the tool's `request` argument (the person's words when it is empty); `surface` and `voice_context` as
GPT-Live. When the turn ends: `function_call_output` `{"answer": reply ≤ 4,000 characters, cleaned for speech}` +
`response.create`. No words: `{"answer":"","note":"The agent finished without a reply."}`. Refused send: a note that it
didn't go through. A newer call closes the open one with a "replaced" note (no response).

## 4. The loop

`LiveTalkLoop` unchanged but for two generalised inputs: `.askAgent(id, request)` (a delegation that carries its own
request) and `LiveTalkState.engine` (Grok takes the reply whole once the turn is over, not sentence by sentence). The
transport turns the loop's effects into xAI events (`GrokLiveCalls`):

- `.speak` for an open call → its function output; with no call (a bot's message, a finished job, a schedule; `[SILENT]`
  says nothing) → a user message "(Not from the person — your agent says:) … Tell the person this briefly." + `response.create`.
- `.think`: only "ended without words" is sent; progress notes are not (Grok does not narrate them).
- Send Now → `response.create` with the instruction; Interrupt → local flush + `response.cancel`. The GPT-Live persona
  note is not sent (the add-on's instructions carry it).
- Barge-in: `speech_started` flushes local playback at once (player stopped, queue dropped) and cancels a response in flight.
- Status: Starting until `session.updated`; Speaking while voice audio is queued (+0.3 s); Thinking while a delegation
  waits; else Listening. Levels from the microphone pieces' RMS and the played pieces' RMS.
- Mute, question card, other audio, stop phrases, silence timeout: as GPT-Live.
- Fallback as GPT-Live: the session refused, the socket not answering in 15 s, an `error` before `session.updated`, or the
  socket dropping without the person ending it → the same conversation carries on with Standard. A denied or missing
  microphone stops it.

## 5. Transport (`GrokLiveVoice`)

`URLSessionWebSocketTask` and one `AVAudioEngine` with voice processing on its input (the system's echo cancellation):
the tap is converted to PCM16 24 kHz with `AVAudioConverter`; the voice plays through an `AVAudioPlayerNode` on the same
engine. `AudioSessionCoordinator` stays the only owner of the audio session (`.conversation`, mode `.voiceChat`). Closing
just closes the socket and stops the engine.

## 6. Tests

`Tests/Talk/GrokLiveTests.swift`: the wire (status, session, outgoing and incoming events), `GrokLiveCalls` (call →
delegation → output, no words, refused, superseded, unknown tool, barge-in flush/cancel, news, transcripts), the loop in
Grok's mode, and the controller with `FixtureGrokLiveVoice` (delegation and answer, mute, barge-in, news, no credentials,
refused session, dropped socket, denied microphone). The fixture gateway answers the status with `available: false`
(control `grokAvailable`) and the session with 503, so the Talk UI tests keep running Standard.

Not yet covered: a real session on a device (audio, echo cancellation, Bluetooth, barge-in feel), the Mac app's audio,
and whether xAI accepts the seed's assistant items (`output_text`).

## 7. Before an external build

xAI receives the person's voice when Grok Live is used. The privacy policy, the App Store privacy label and the review
notes must name xAI as a recipient before any external build carries this.
