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
- `history`: the chat's text turns, newest kept, at most 24 messages and 6,000 characters (1,200 per turn).

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
  narration (owner, build 407: too much filler).
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
- A question card mutes the microphone and un-mutes it after; other audio mutes it.
- Long silence (the standard engine's pause window) ends the session: idle time is billed.
- Falls back, never strands the person: if GPT-Live can't start (the gateway or OpenAI refuses, WebRTC fails), or
  `session.closed` / a dropped connection arrives without the person ending it, the same conversation carries on with
  the standard engine (a fresh loop, its own microphone and leases). Only a denied or missing microphone stops it,
  since the standard engine needs the microphone too.

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
