# 3x — Bot Screen (m9 stream `screen`)

Bot Screen is the whole-computer screen viewer: watch the computer a bot works on, take control of its pointer and
keyboard, hand it back; and, where a gateway has no live screen, the bot's latest screenshots instead. The web app drew
it with noVNC inside the WebView. HQ Native has no WebView: this spec replaces noVNC with a small native RFB client and
rebuilds the phone adapters natively. 15 rows of `docs/parity-240.md` (all ❌), listed verbatim in
`docs/briefs/m9/screen-rows.md`.

Everything below was read from source on 2026-10-11. Nothing was run against a real gateway.

| Abbrev | Path |
|---|---|
| `S` | `/Users/me/Projects/hermes-hq-native-ref240/src` (web app at public build 240, read only) |
| `B` | `/Users/me/Projects/hermes-hq-native-ref240/build` (its patches to the vendor renderer) |
| `V` | `/Users/me/Projects/hermes-hq-native-ref240/vendor/hermes/apps/desktop/src/plugins/hermes-bots` |
| `P` | `/Users/me/Projects/hermes-hq-native-ref240/gateway-plugin/hermes-hq-screen` (the Mac screen plugin) |
| `M` | `/Users/me/Projects/hermes-hq-native-ref240/macos/DispatchScreen/Sources` (the Mac helper, "Hermes HQ Screen.app") |
| `HA` | `/Users/me/.hermes/hermes-agent` (real Hermes, read only, never run or imported) |
| `MEM` | `/Users/me/.claude/projects/-Users-me-Projects-hermes-ios/memory` (owner notes) |
| `NAT` | this worktree |

Stream facts: branch `m9/screen`; builder ports **9940–9944**, stress ports **9945–9949**; simulators `HQN-m9-screen`
(builders) and `HQN-m9-screen-s` (stress), created with
`xcrun simctl create "HQN-m9-screen" "iPhone 17 Pro" com.apple.CoreSimulator.SimRuntime.iOS-27-0` when missing.

---

## 0. What the owner asked for

* `MEM/finish-everything-push.md` (2026-09-26): make every feature work, including "watching a bot's computer (Bot
  Screen)". Decision line: "**Bot Screen on the macOS gateway:** "watch and take control". Build the helper and plugin,
  but don't install them."
* `MEM/bot-screen-harness.md`: "As of 2026-09-26 no gateway the owner runs supports Bot Desktop: the main gateway is
  macOS (display.status supported:false for all 9 profiles)". "Known gateway-side limit: after the 20 s background grace
  the phone loses control authority, because viewer ids are bound per /api/ws connection." "H.264 is opt-in: with it the
  Simulator Screen stayed black (noVNC waits for paint, WebKit decoder held frame 1); Tight-JPEG is the default."
* `MEM/hermes-hq-rename.md`: "**Mac helper:** "Hermes HQ Screen.app" 1.1.0 notarized … old Dispatch Screen.app is
  refused".
* `MEM/browser-takeover-rebuild.md` (build 169): "owner asked for Screen-style control: one finger moves a drawn pointer
  (relative), tap clicks at pointer, hold+drag drags, two fingers scroll with fling". The Screen's relative trackpad is
  the control model the owner likes; keep it exactly.
* `MEM/ui-hunt-oct6.md`: "Bot Screen toasts under toolbar": notices must not sit under the top bar.
* `MEM/hermes-code-not-ours.md`: "We can't make any changes to hermes agent code since we don't control it." Hermes
  limits are worked around on the phone. "the dispatch-screen plugin patches Hermes display functions in memory at load.
  Flag that dependency; don't hide it."
* `MEM/stress-audit-159.md`: installing the Mac plugin is an owner step, never an agent's.
* `MEM/hermes-hq-native.md`: parity top-10 item 9, "Bot Screen. The noVNC Mac screen viewer, key bar, control handover
  and setup card. No native code yet." Owner rules: "SO MUCH smoother", never the word "Dispatch" on screen, no private
  API, `withChildTasks` (never `withTaskGroup`).
* `MEM/row-padding-feedback.md`: "Any cell whose text can wrap gets explicit vertical padding: about 12–14pt top and
  bottom".

What this means for the build: the phone side is complete and proven against a stand-in gateway. The owner's own Mac has
neither the plugin nor the helper installed, so on the owner's gateway the first thing the owner sees is the **latest
screenshots view with the setup card**; the live viewer becomes reachable after the owner taps "Set up with Hermes" and
approves two macOS permissions (see `docs/owner-todo/screen.md`).

---

## 1. How Bot Screen works (the model)

1. **Status.** JSON-RPC `display.status {profile}` on the account's `/api/ws` says whether the bot has a screen:
   `supported`, `installed`, `running`, `display`, `geometry`, `blocker`, and the control **lease**
   (`holder: "agent" | "human"`, `viewer_hash`, `epoch`). Older Hermes has no such method (error `-32601`).
2. **Observe.** `display.observe {profile, viewer_id?}` mints a **viewer id** bound to this `/api/ws` connection and a
   single-use, 30-second **ticket**.
3. **Stream.** A second WebSocket, `/api/display/ws?display_ticket=<ticket>`, carries raw **RFB 3.8** (VNC) bytes in
   binary frames. The gateway bridges it to the bot's screen: Xvnc on Linux hosts, the "Hermes HQ Screen" helper on a
   Mac (`display == "This Mac"`: the Mac's own console, shared by every bot on it).
4. **Control.** Everyone may watch. Only the viewer whose id holds the lease may send keys, pointer events and
   clipboard; the gateway drops other viewers' input (`HA/hermes_cli/web_routers/display.py`, `RfbClientFilter`).
   `display.lease.acquire {profile, viewer_id}` takes control (last writer wins), `display.lease.release` hands it back.
5. **Leaving.** A viewer that closes its stream with code 1000 or 1001 hands the lease back; any other end (a dropped
   link, a killed app) keeps it (`display.py:37`, `:193-194`, `:236-238`).
6. **No live screen.** When the gateway cannot share a screen (not supported, blocked, older Hermes), the Screen shows
   the newest screenshot the bot took with `computer_use` or a `browser_*` tool, updating while it works.

Web layering, for orientation: the vendor desktop pane `V/screen-pane.tsx` (noVNC) is patched for the phone by
`B/bot-screen-gates.ts` and `B/fe-screen-gates.ts`, with the phone adapters in `S/bot-screen-*.ts(x)`,
`S/bot-activity*.ts(x)`, `S/tool-screenshots.ts`, `S/image-zoom.ts` and `S/mac-screen-health.ts`.

---

## 2. Wire

Hermes rejects unknown params with error **4000**. Send only the keys listed here.

### 2.1 JSON-RPC on `/api/ws` (`HA/tui_gateway/contracts/display.py`)

All calls go through `GatewayClient.call(_:_:timeout:)` (`NAT/HermesKit/Contracts.swift:127`). Display failures use
error code **5300** (`data.code == "viewer_mismatch"` for a foreign viewer id and for "a human holds it" refusals).

| Method | Params (exactly) | Result | Timeout | Used for |
|---|---|---|---|---|
| `display.status` | `{profile}` | DisplayStatus | 20 s | every open, Retry, after lease changes, setup check |
| `display.start` | `{profile}` | DisplayStatus | 30 s | "Start screen" |
| `display.observe` | `{profile}` or `{profile, viewer_id}` | DisplayStatus + `ticket`, `path`, `viewer_id` | 15 s | every attach |
| `display.lease.acquire` | `{profile, viewer_id}` | `{lease}` | 10 s | Take Control, Resume Control, reclaim |
| `display.lease.release` | `{profile, viewer_id}` · `{profile, viewer_id, force: true}` · `{profile, force: true}` | `{lease}` | 10 s | Give Back · give back a hold this phone lost track of · End Their Control of another viewer |

Not called by the phone: `display.stop`, `display.thumbnail`, `display.install`, `display.switchSandboxImage`
(desktop-only surfaces; see §11).

DisplayStatus (all fields optional on read; parse defensively):

```json
{"profile":"default","profile_key":"default","supported":true,"installed":true,"missing":[],"running":true,
 "pid":4242,"display":"This Mac","socket":"/Users/x/.hermes/bot-desktop/rfb.sock","geometry":"1920x1080",
 "install_command":null,"browser":null,"blocker":null,"placement":"gateway","image_switch":null,
 "lease":{"holder":"agent","viewer_id":null,"viewer_hash":null,"since":1791700000.0,"epoch":3,"reason":""}}
```

`display.observe` answer adds `"ticket":"<opaque>","path":"/api/display/ws","viewer_id":"<opaque>"`. A `viewer_id`
sent in the params is honoured only on the `/api/ws` connection that minted it; on any other connection Hermes mints a
fresh one. Errors: 5300 "this profile's Bot Desktop is not running; call display.start first".

`display.lease.acquire` errors: 5300 "viewer_id required", 5300 "viewer_id was not minted for this connection; call
display.observe first".

`display.lease.release`: with `viewer_id` + `force: true` Hermes skips the "minted on this connection" check but
releases only while that id still holds, so someone who took control meanwhile keeps it (`S/bot-screen-phone.tsx:466-468`).
A bare release while a human holds is refused (5300 `viewer_mismatch`) unless `force`.

Events on `/api/ws` (`GatewayClient.events()`): `display.status` (a DisplayStatus) and `display.lease`
(`{"profile_key":"default","lease":{…}}`).

Rules ported from `V/screen-state.ts` and `V/screen-connection.ts`:

* **Unavailable** = an RPC error with code `-32601`, or a message containing "method not found" or "unknown method"
  (case-insensitive). Remember it per bot until the next successful status.
* **Generation tokens**: each `display.status` request takes a number; an answer older than the newest applied one is
  dropped.
* **Lease ordering**: a lease whose `epoch` is lower than the one held is ignored (`isOlderLease`).
* **Viewer hash** = first 12 hex characters of SHA-256 of the viewer id (UTF-8) (`VIEWER_HASH_HEX = 12`;
  `HA/tools/bot_desktop/lease.py` `public_view`). "I hold the lease" = `lease.holder == "human" &&
  lease.viewer_hash == hash(my viewer id)`.

### 2.2 The display socket

`ws(s)://<gateway host><path prefix>/api/display/ws?display_ticket=<ticket>` — the gateway's own scheme (wss iff
https), its path prefix kept, **no** `ticket=`/`token=` and no other query item: "the ticket is the sole credential
that route accepts" (web shell, `ios/App/App/HermesNative.swift:2591-2597`). The `path` in the observe answer must equal
`/api/display/ws`; anything else is refused without dialling. Frames are binary; RFB messages do not line up with
WebSocket frames (the bridge forwards 64 KiB chunks), so the client parses a byte stream.

Close codes (`HA/hermes_cli/web_routers/display.py`):

| Code | Meaning | Phone |
|---|---|---|
| 4000 `control-taken` | this viewer held control and another person took it | caption "Another viewer took control. Watching only.", re-attach watching (§5.8) |
| 4001 | "Bot Desktop is not running" | re-read status (shows "Screen Is Off") |
| 4401 | ticket missing, expired or used | observe again once, then "Screen Stopped" |
| 4403 | host/origin/client not allowed (before accept) | "Screen Stopped" |
| 1003 | protocol (a text frame, or a client message the filter does not know) | "Screen Stopped"; `AppLog.note("screen", "protocol close")` |
| 1000/1001 from us | **hands the lease back** | used only for Close and Hand-back-on-leave |
| anything else / no close frame | a dropped link; the lease is kept | re-attach rules §5.11 |

**How the phone closes.** Leaving the Screen while holding control: `task.cancel(with: .normalClosure, reason: nil)`.
Pausing (out of view, background, re-attach): plain `task.cancel()` — no close frame, which the gateway treats as a
dropped link and so keeps the lease. `BrowserSocket` (`NAT/HermesKit/Browser/BrowserService.swift:16-63`) sends 1001
from `deinit`; the Screen must **not** reuse it: its own `ScreenSocket` never sends 1000/1001 except on purpose.

### 2.3 The RFB client (replaces noVNC)

What the gateway lets a viewer send (`RfbClientFilter`; the Mac helper parses the same set, `M/ScreenCore/RFBServer.swift:446-500`):
message types 0 SetPixelFormat (20 bytes), 2 SetEncodings, 3 FramebufferUpdateRequest (10), 4 KeyEvent (8),
5 PointerEvent (6), 6 ClientCutText (≤ 256 KiB, else the stream is closed), 150, 248, 251, 255. **Any other type closes
the stream with 1003.** Types 4, 5, 6, 251, 255 are dropped unless this viewer holds the lease. The native client sends
only **0, 2, 3, 4, 5, 6**.

Handshake (client side):

1. Read 12 bytes `RFB 003.00x\n`; x ≥ 3 required. Reply `RFB 003.008\n` (or echo 3.3/3.7 when the server is older).
2. 3.7+: read the count N and N security types. N == 0 → read `u32` length + reason, fail. Type 1 (None) must be
   offered → send `[1]`; 3.8: read the 4-byte SecurityResult, non-zero → read reason, fail. 3.3: read `u32` type, must
   be 1. Any password scheme → fail (Hermes serves None on a private socket).
3. Send ClientInit `[1]` (shared; noVNC uses `shared: true`, `V/screen-pane.tsx`).
4. Read ServerInit: `u16 width, u16 height, 16-byte pixel format, u32 name length, name`.
5. Send SetPixelFormat: 32 bits per pixel, depth 24, little-endian, true colour, max 255/255/255, shifts R 16, G 8, B 0
   (BGRX in memory: the helper's native format, `M/ScreenCore/Encoders.swift:15-17`, and
   `CGImageAlphaInfo.noneSkipFirst | CGBitmapInfo.byteOrder32Little` on iOS, so no per-pixel conversion).
6. Send SetEncodings, in this order: `7` Tight, `1` CopyRect, `0` Raw, `-25` (quality level 7, noVNC's value,
   `V/screen-pane.tsx:240`; the helper maps it to JPEG quality 86), `-254` (compression level 2), `-224` LastRect,
   `-223` DesktopSize, `-308` ExtendedDesktopSize.
   **Never** send `-239` Cursor (DECISION D4), `-316` ExtendedMouseButtons, `-309`, `-313` ContinuousUpdates, `-312`
   Fence, XVP, or `50` H.264 (`M/ScreenCore/Encoders.swift:72-75` says why each breaks the gateway's framing or the pull
   model).
7. Send FramebufferUpdateRequest (incremental 0, full frame).

Server messages handled: 0 FramebufferUpdate, 1 SetColourMapEntries (skipped: `6 + 6·n` bytes), 2 Bell (ignored),
3 ServerCutText (`8 + length` bytes skipped; the phone never copies the remote clipboard). Any other type → the stream
is ended as a protocol error (re-attach once, §5.11).

Rectangle encodings decoded:

| Encoding | Notes |
|---|---|
| 0 Raw | `w·h·4` bytes BGRX, copied row by row |
| 1 CopyRect | `u16 srcX, u16 srcY`; `memmove` within the framebuffer (overlap-safe) |
| 7 Tight | control byte: bits 0–3 reset zlib streams 0–3; high nibble: `0x8` **Fill** (3-byte RGB), `0x9` **JPEG** (compact length, then a JPEG decoded with ImageIO and drawn into the framebuffer), `0x0–0x7` **Basic**: stream id in bits 4–5, bit 6 = explicit filter (0 Copy, 1 Palette with 1-bit or 8-bit indices, 2 Gradient); data under 12 bytes is raw, else compact length + zlib data inflated on that stream. Pixels are 3-byte RGB ("TPIXEL") with the format of step 5. |
| -223 DesktopSize, -308 ExtendedDesktopSize | new framebuffer size (`w`,`h` of the rect); -308 carries `4 + 16·screens` extra bytes. The framebuffer is reallocated (black) and a full update is requested. |
| -224 LastRect | ends the update early |

The Mac helper sends only Tight Fill, Tight JPEG and Raw (`M/ScreenCore/RFBServer.swift:583-600`,
`Encoders.swift:147-167`): JPEG tiles of 64-px blocks aligned to 16, and only when the client asked for the next frame.
Linux Xvnc (TigerVNC) also sends Tight Basic and CopyRect, which is why both are decoded. zlib: `import zlib` (the SDK
module autolinks `libz`; public API). Four `z_stream`s live for the whole connection.

**Pull model.** After a FramebufferUpdate has been decoded *and handed to the main thread*, the client sends the next
FramebufferUpdateRequest (incremental 1, full frame). Never more than one request outstanding. That is the
backpressure: a slow phone or link gets fewer frames, never a queue.

Limits (bad data never crashes or grows without bound): framebuffer ≤ 8192 × 8192 and ≤ 64 MB; a rect must lie inside
the framebuffer; Tight compact length ≤ 4 MiB; JPEG that fails to decode leaves the rect as it was and counts a failure
(3 in a row → protocol error); the parse buffer is capped at 16 MiB; `maximumMessageSize` 4 MiB.

Client input messages:

* KeyEvent `[4, down, 0, 0, keysym(u32 BE)]`.
* PointerEvent `[5, mask, x(u16 BE), y(u16 BE)]`; mask bit 0 left, 1 middle, 2 right, 3 wheel up, 4 wheel down.
* ClientCutText `[6, 0, 0, 0, length(u32 BE), latin-1 bytes]`, length ≤ 262,144 (`MAX_PASTE_CUT_TEXT`,
  `V/screen-pane.tsx`); longer text is typed instead.

Input is sent only while this phone holds the lease (the gateway would drop it anyway; not sending keeps the wire
quiet and the UI honest).

### 2.4 Mac screen health (REST)

`GET /api/plugins/hermes-hq-screen/health`, legacy `GET /api/plugins/dispatch-screen/health`
(`S/mac-screen-health.ts:7-8`; answer built at `P/dashboard/plugin_api.py:86-94`):

```json
{"ok":true,"installed":true,"platform":"darwin","drift":[],"enabled":true,"control":true,"profiles":null,
 "blocker":null,
 "helper":{"ok":true,"running":true,"tcc":{"screen":true,"events":true},"locked":false,"secure_input":false,
           "paused":false,"capture_error":null},
 "legacy_plugin_loaded":false,"legacy_app":false}
```

`parseMacHealth` (`S/bot-screen-mac.ts:9-13`): nil unless `installed === true`; else
`control = health.control === true`, `inputReady = control && helper.tcc.events === true`,
`locked = helper.locked === true`, `secureInput = helper.secure_input === true`.

### 2.5 Latest screenshots (REST + events)

* `GET /api/profiles/sessions?limit=3&offset=0&min_messages=1&archived=exclude&order=recent&profile=<p>` →
  `{sessions:[{id,last_active,cwd}]}` (`S/bot-activity.tsx:36-37`).
* `GET /api/sessions/<id>/messages?limit=40&order=latest&profile=<p>` (8 once a screenshot was found) →
  `{messages:[row]}`; build the request with `HistoryRequest` (`NAT/HermesKit/Chat/HistoryAPI.swift:70`).
* `GET /api/fs/download?path=<path>&profile=<p>` for the picture (`ActivityMedia.loadImage`,
  `NAT/App/Chat/Activity/ActivityCells.swift:485-507`, which integration points at `MediaLoader`).
* `GET /api/fs/list?path=<dir>` → `{entries:[{name}]}` for the expiry check (`S/tool-screenshots.ts:72-78`).
* Events `tool.start` / `tool.complete` for sessions this app has open.

### 2.6 Setup request

`file.attach {session_id, profile, name: "hermes-hq-screen-setup.zip", data_url: "data:application/zip;base64,…"}`
(`HA/tui_gateway/contracts/prompt_voice.py:165-184`: "`path` when the file is gateway-visible, else `data_url` carries
the bytes") → `{attached, name, path, ref_path, ref_text, uploaded}`; then a normal queued send (`prompt.submit` through
`LiveChatSession.send(_:display:attachments:)`).

---

## 3. Native design

Fits `docs/ARCHITECTURE.md`: non-UI in `HermesKit/Screen/`, UI in `App/Screen/`; the Watch Browser viewer
(`App/Browser/`, ARCHITECTURE "Watch Browser (m5/browser)") is the pattern: frames decoded off the main thread, a
`CALayer` shows them, native glass buttons ride `keyboardLayoutGuide`, hidden text field for typing, content-free
`AppLog.note("screen", …)` breadcrumbs. Nothing here is web content, so no row is proposed as web-shell-only.

### 3.1 Files

`HermesKit/Screen/` (pure or `nonisolated` unless noted):

| File | Holds |
|---|---|
| `ScreenWire.swift` | `ScreenStatus`, `ScreenLease` (parsers from `JSONValue`), strict param builders for the five calls, `ScreenWire.isUnavailable(_ error:)`, `viewerHash(_:)` (CryptoKit), `ScreenTone` and `ScreenKind` rules, `screenLabel`, `displaySocketURL(base:path:ticket:)`, close codes |
| `RFBProtocol.swift` | `RFBParser`: an incremental parser over a growing byte buffer (handshake states, ServerInit, server messages); client message encoders |
| `RFBDecoders.swift` | `ScreenFramebuffer` (BGRX bytes + `makeImage()`), Raw / CopyRect / Tight (Fill, JPEG, Basic) / size pseudo-rects, the four zlib streams |
| `ScreenSocket.swift` | wraps `URLSessionWebSocketTask`: detached receive loop, binary send, `close(handBack:)`, ping |
| `ScreenStream.swift` | one attach's stream: socket → parser → decoders → `onFrame(CGImage, size, serial)` on the main actor; the pull model; pacing stats (`frames`, `rects`, `mainThreadDecodes` = 0, p50/p95) like `BrowserPacing` |
| `ScreenSession.swift` | `@MainActor`. The state machine of one open Screen (§4): status, observe, dial, lease, eviction, reclaim, pause/resume, timeouts |
| `ScreenService.swift` | `@MainActor`, one per account (like `BrowserService`): cached status per bot, the `display.status` / `display.lease` event pump, `kind(for:)`, open sessions (weak) for sign-out, Mac health reader |
| `ScreenHolds.swift` | this run's holds (`sessionHolds`) and the saved hold per bot (`{id, hash, at}`, 24 h), `shouldReclaim`, `heldBefore`; the remembered kind per gateway; the rotate-hint flag |
| `ScreenKeys.swift` | keysyms, `keysymFor`, modifier order, chord and text → key events, the Latin-1 paste rule |
| `ScreenViewMath.swift` | `clampView`, `zoomAbout`, `clampToDesktop`, `fillZoom`, `compactTyping`, `fillWidthView`, `keepVisible`, pointer move/clamp, wheel steps |
| `MacScreenHealth.swift` | the two routes with route memory, `MacScreen` parse, `MacScreenReadiness` messages |
| `ScreenshotFeed.swift` | the latest-screenshots model: poller, `latestShot`, `liveShot`, `shotCaption`, `shotAge`, `hostKind` |
| `ToolScreenshots.swift` | `storedScreenshot`, `multimodalToolImage`, `savedScreenshot`, the expiry checker with its listing cache |
| `ScreenSetup.swift` | the setup prompt, the bundled installer loader (SHA-256 checked), the request flow and its de-duplication |

`App/Screen/`:

| File | Holds |
|---|---|
| `ScreenViewerController.swift` | the full-screen viewer and its states; presents once (`static weak var current`) |
| `ScreenStageView.swift` | the picture layer, zoom/pan, watch and control touches |
| `ScreenControlBar.swift` | the bottom glass bar: who is in control, Take Control / Give Back, Fit, keyboard, special keys, modifiers, Paste |
| `ScreenKeyField.swift` | the hidden text field that turns the iOS keyboard and a hardware keyboard into key events |
| `ScreenNotesView.swift` | the notes under the top bar and the error line with Dismiss |
| `ScreenSetupCard.swift` | the Mac setup card |
| `LatestScreenshotsView.swift` | the fallback view |
| `StepScreenshotBlock.swift` | the screenshot inside a tool step's sheet (row L345) |
| `AppModel+Screen.swift` | wiring: the service per account, the row menu item, the Bot Info tile and Computer row, the orientation gate |

Also: `App/Resources/Screen/HermesHQScreenSetup.zip` (§5.13), `scripts/fixtures/screen-gateway.py`,
`scripts/fixtures/make-screen-frames.swift`, `scripts/fixtures/extract-screen-setup.py`, `scripts/e2e-screen.sh`,
`Tests/Screen/`, `Tests/Fixtures/screen/`, `UITests/screen/ScreenEndToEndTests.swift`.

Edits to existing files (small, each marked `// [screen]`):

* `HermesKit/Net/LiveGatewayClient.swift`: `func displaySocket(path:ticket:) async throws -> URLSessionWebSocketTask`
  next to `pluginSocket` (`:166-177`): same closed/reachable checks, **no** `auth.mintTicket`, URL from
  `ScreenWire.displaySocketURL`, `maximumMessageSize = 4 MiB`, request timeout 15 s. New protocol
  `GatewayDisplaySockets` beside `GatewayPluginSockets` so fakes keep compiling.
* `App/AppModel.swift`: `private(set) var screen: ScreenService?` created and shut down exactly where `browser` is
  (`:232-233`, `:330-331`); `registerScreenMenu()`.
* `App/AppDelegate.swift`: `application(_:supportedInterfaceOrientationsFor:)` (§5.7).
* `App/BotInfo/BotInfoSheet.swift`: the Screen tile in `BotInfoTiles` (`:449-462`) and `BotInfoModel.screen()`.
* `App/Chat/Activity/StepSheets.swift`: the screenshot block in `StepDetailViewController.build()` (`:159`).
* `HermesKit/Chat/ChatMeta.swift`, `LiveChatSession+Events.swift`, `Hydration.swift`, `Store/TranscriptCoding.swift`:
  `ToolDetail.screenshot` (§5.3).
* `HermesKit/Chat/LiveChatSession+ScreenSetup.swift` (new extension file): the setup attach + queue (§5.13).

`project.yml` and `project-original.yml` need no change: both list `App` and `HermesKit` as source folders, so new
Swift files and the zip resource are picked up in both identities. Build both (`scripts/build.sh` and
`HQ_IDENTITY=original scripts/build.sh`).

### 3.2 Threads

* The socket's receive loop, the parser, zlib and JPEG decoding and `makeImage()` run on one detached task per stream
  (`.userInitiated`). Only the finished `CGImage` crosses to the main actor (`CALayer.contents`), then the next update
  request goes out. `mainThreadDecodes` must stay 0 (asserted in tests, as Watch Browser does).
* `ScreenFramebuffer` belongs to that task; `makeImage()` hands out an immutable copy-on-write `CGImage`
  (`CGContext.makeImage()` over the BGRX buffer), so the main thread never reads bytes the decoder is writing.
* No `withTaskGroup`: use `withChildTasks` (`MEM/hermes-hq-native.md`).
* Logs: `AppLog.note("screen", "attach")`, `"live 1920x1080"`, `"close 4000"`, `"lease mine"` … never keysyms, text,
  tickets, viewer ids, paths or screenshots.

### 3.3 Storage keys (UserDefaults; ids only, never content)

| Key | Value | Web key it replaces |
|---|---|---|
| `hq.screen.held.<accountId>.<profile>` | `{"id","hash","at"}` (viewer id of a hold; dropped after 24 h) | `dispatch.botScreen.held.<key>` (`S/bot-screen-phone.tsx:504-505`) |
| `hq.screen.kind.<accountId>` | `"live"` or `"screenshots"` | `dispatch.botScreen.kind:<gateway>` (`:729`) |
| `hq.screen.rotateHintSeen` | `true` | `dispatch.botScreen.rotateHintSeen` (`S/bot-screen-controls.tsx:118`) |

DECISION D1: native keeps its own keys and does not read the web app's (they lived in the WebView's localStorage,
which HQ Native cannot read). A viewer id is an opaque handle that can only release its own hold; it is not a
credential, so UserDefaults (not Keychain) matches the web's localStorage.

---

## 4. The viewer and its states

**Presentation.** `ScreenViewerController` inside `ScreenNavigationController`, `modalPresentationStyle = .fullScreen`
(as `BrowserViewerController.present`, `NAT/App/Browser/BrowserViewerController.swift:51-61`). Top bar: system Close
(`UIBarButtonItem(systemItem: .close)`, id `screen.close`) leading; small inline title `<Bot>’s Screen`
(the web's `B/bot-screen-gates.ts` says `${displayName} · Screen`; native uses the Browser viewer's pattern, UX study #94); `navigationItem.subtitle` = `screenLabel(status)` (e.g.
"This Mac · 1920×1080"; empty hides it). The page under the bar is the system background; the stage is black.
DECISION D2: Close (✕), not the web's "Done", to match the native Watch Browser viewer.

Layout top to bottom: top bar · notes (`ScreenNotesView`, only when there is one) · stage (fills) · control bar
(glass, pinned to `view.keyboardLayoutGuide.topAnchor`). The bar sits **below** the picture and shrinks it rather than
covering it (`S/bot-screen-controls.tsx` header comment).

**Tone and kind** (`V/screen-portal.tsx` `portalTone`, `S/ui-bots/bot-row.tsx:70-78`,
`S/bot-screen-phone.tsx:745-750`):

```
tone(state):  unavailable flag → .unavailable      no status yet → .unknown
              !supported → .unsupported            !installed → .missing        !running → .off
              lease.holder == human → (mine ? .human : .other)                   else → .live
kind(tone, accountId):
              .unsupported, .unavailable → .screenshots   (and remember "screenshots" for the gateway)
              .unknown → remembered kind for the gateway, else .unknown
              anything else → .live                       (and remember "live")
```

**States.** One state at a time; each names its test id.

| # | When | What shows (exact words) | Controls |
|---|---|---|---|
| S0 | no status yet | spinner, "Connecting to the screen…" (`screen.connecting`) | Close |
| S1 | no status after 20 s, or the status call failed | title "Couldn’t Reach <Bot>’s Screen"; body `<error without its trailing period>.` or "The screen’s status never arrived." followed by " Check that the computer that runs Hermes is on and reachable, then try again." (`screen.no-answer`) | "Try Again" (`screen.retry`) |
| S2 | tone unavailable / unsupported, or `!running && blocker` | the latest screenshots view (§5.2, §5.14) with the matching heading, then the setup card (§5.13) | per §5.14 / §5.13 |
| S3 | tone missing (`supported && !installed`) | title "Screen Add-on Missing"; body "The computer that runs Hermes needs a desktop add-on before <Bot> can have a screen. Whoever looks after it can run this there:" then `install_command` in a monospaced, selectable block (omitted when absent) | "Copy" (copies the command; shown only with a command), "Check Again" (re-reads status) |
| S4 | tone off (`!running`, no blocker) | title "Screen Is Off"; body "Start this bot’s desktop to watch what it does and take over when it needs you." | "Start Screen" (`screen.start`; spinner while `display.start` runs; an error shows in the notes' error line) |
| S5 | running, attaching | the last picture if any (dimmed 40 %), else black; spinner and "Connecting to the screen…" | Close |
| S6 | live | the picture; control bar per §5.5 and §5.6; notes per §5.9 | per row sections |
| S7 | stream ended and not recovered | title "Screen Stopped" (or the eviction text when that was the cause) | "Reconnect" (`screen.reconnect`) |

The placement line `Screen runs inside the <backend> sandbox, with the terminal.` shows as a footnote under S4's body
when `placement` starts with `terminal:` (backend = the part after the colon).

Wording sources: `V/i18n.ts:799-855` (`attaching`, `stoppedTitle`, `stoppedBody`, `start`, `streamLost`, `reconnect`,
`notInstalledTitle`, `notInstalledBody`, `placementSandbox`, `takeOver`, `handBack`, `handBackForce`, `youControl`,
`otherControls`, `agentControls`, `controlTaken`), `S/bot-screen-phone.tsx:657-700` (S0/S1).

DECISION D3: S3 has no "Install on host" button and there is no sandbox image switch card. Both are the desktop
pane's Linux-host flows (`display.install` with its `display.install.sudo` password request, `display.switchSandboxImage`),
no assigned row names them, and the owner's gateway is a Mac. The view says exactly what to run; nothing on it is a
dead control. "Check Again" is native wording for a status re-read (the web re-reads on its own when the install event
arrives). Revisited 2026-10-19 (UX study #83): the words became plain (no package names), and D3 stands. An "Ask Hermes
to Install It" button, like Watch Browser's, waits until it is confirmed the bot can run the install (it needs sudo).

**Session state machine** (`ScreenSession`, from `V/screen-pane.tsx` plus the phone gates):
`idle → attaching → live → (idle | error)`.

```
open():           status = display.status          (20 s; generation token)          → S0/S1/S2/S3/S4, or attach()
attach():         guard visible && app active && gateway .ready
                  conn = attaching
                  observe = display.observe {profile, viewer_id: prior?.id}          (prior = this session's last viewer)
                  minted = {id: observe.viewer_id, hash: viewerHash(id)}
                  lease  = reclaim(prior, minted, observe.lease)                      (§5.8)
                  socket = displaySocket(path: observe.path, ticket: observe.ticket)
                  RFB handshake → first frame → conn = live
close(code):      4000 or reason "control-taken" → eviction path (§5.8)
                  we closed it (pause, leave)   → idle
                  else                          → re-attach rules (§5.11), else error "Screen Stopped"
                  then refresh display.status
takeOver():       display.lease.acquire {profile, viewer_id: minted.id}  → lease; clear the error line
handBack():       display.lease.release {profile, viewer_id: minted.id}  → lease; clear the error line
forceHandBack():  display.lease.release {profile, force: true}           → lease
leave():          §5.8 "Leaving"
```

Events: `display.status` for this bot replaces the status (subject to generation and epoch rules); `display.lease`
replaces the lease when its `profile_key` is this bot's and its epoch is not older.

---

## 5. The rows

Every row is exercised by one stand-in gateway, the new `scripts/fixtures/screen-gateway.py` (§7). Builders start it
on this stream's ports:

```
swift scripts/fixtures/make-screen-frames.swift build/fixtures/screen-frames          # once
python3 scripts/fixtures/screen-gateway.py --port 9940 \
  --credentials build/fixtures/e2e-screen.json --frames build/fixtures/screen-frames
```

and steer it with `POST http://127.0.0.1:9940/__fixture/screen` (called **CTL** below; body shown as JSON) and read
what it saw with `GET /__fixture/screen` (**LEDGER**). `scripts/e2e-screen.sh <udid>` does all of that for the UI tests.
The stress tester uses the same commands on **9945**.

### 5.1 L166 — Row menu: Watch Screen / View Screen / Latest Screenshots

**Web.** `S/ui-bots/bot-menu.ts:16-17, :43`: the row menu's open section is Bot Info, New Chat, then the Screen entry:
`row.screen === 'screenshots'` → "Latest Screenshots" (symbol `photo.on.rectangle`); `'live'` → "Watch Screen";
otherwise "View Screen" (symbol `display`). `row.screen` is `rowScreenKind(bot)` (`S/ui-bots/bot-row.tsx:70-78`): the
kind rule of §4 over the cached `display.status`. The web asks for a status only when a Screen opens
(`V/screen-pane.tsx:113`); rows never poll.

**Native.** The slot already exists: `BotMenuHooks.Slot.screen`, placed after Bot Info and New Chat
(`NAT/App/Bots/BotsOrganizer.swift:10, :75-77`). `AppModel.registerScreenMenu()` sets
`BotMenuHooks.providers[.screen]` to `.action(title, symbol) { openScreen(bot, from: host) }` with

| `ScreenService.kind(for: bot.id)` | Title | Symbol |
|---|---|---|
| `.screenshots` | Latest Screenshots | `photo.on.rectangle` |
| `.live` | Watch Screen | `display` |
| `.unknown` | View Screen | `display` |

The menu is built when it opens (`BotsOrganizer.swift:127-132`), so the label cannot change under the finger. The provider
returns nil only when there is no account (no dead item). `AppModel.openScreen(_ bot: Bot, from:)` presents the viewer;
`openScreen(profile:name:from:)` is the same entry for other streams (presence's "Watch" notices, groups' "View
<name>'s Screen").

**Wire.** None when the menu opens. The label reads `ScreenService`'s cache, fed by statuses of Screens opened this run
and by `display.status` / `display.lease` events, plus `hq.screen.kind.<accountId>`.

**States.** The three titles above. A bot on a gateway never opened: "View Screen".

**Owner.** `MEM/hermes-hq-native.md` parity item 9 (Bot Screen "No native code yet"). Wording is the web's.

**Fixture.** `CTL {"mode":"mac"}`, `{"mode":"unsupported"}`.

**Acceptance.**
1. Fresh install, sign in, long-press a bot: the item reads "View Screen".
2. `mode: mac`: open the Screen, close it, long-press: "Watch Screen". Another bot never opened also reads "Watch
   Screen" (the gateway's remembered kind).
3. `mode: unsupported`: open, close: "Latest Screenshots" with the photo symbol; relaunch the app: still "Latest
   Screenshots".
4. LEDGER shows no `display.status` caused by opening the menu.

### 5.2 L212 — Bot Screen fallback: newest computer_use or browser screenshot, updated live

**Web.** `S/bot-activity.tsx:56-82`: while the view is on screen, poll every 3 s (`POLL_MS`):
`GET /api/profiles/sessions?limit=3&offset=0&min_messages=1&archived=exclude&order=recent&profile=<p>`; take the
session with the newest `last_active`; fetch its messages only when `"<id>:<last_active>"` changed
(`S/bot-activity-model.ts:94-124`: limit 40 until a screenshot was found, then 8; a failed read is retried next tick;
two failures in a row → "unreachable"). `latestShot` (`:45-57`): scanning the page from its end (a page is chronological, oldest of its rows first, so the
newest is last; corrected by the builder after the UI test showed the oldest of three), the first row with
`role == "tool"`, tool name (`tool_name || name`) matching `^(computer_use|browser_)`, and a screenshot in its
content (`storedScreenshot`, §5.3). Its id is `tool_call_id` or `"<tool>-<timestamp>"`; its caption comes from
`shotCaption(tool, args)` with args from the row or from the assistant row's `tool_calls[].function.arguments` of the
same id. Live (`S/bot-activity.tsx:88-100`): `tool.complete` of this bot's sessions → `liveShot` (`:60-65`): the inline
`data:image/…` of `result.content[].image_url.url`, else `result.meta.screenshot_path`, `result.screenshot_path`, any
string field matching the saved-path pattern, else `result_text` / `summary`; `tool.start` of a screenshot tool sets
the working caption `"<caption>…"`, cleared by the next `tool.complete`. A newer capture replaces the shown one; the
same id never does (`:54`). Whose session an event belongs to comes from the session, "never from event.profile".

Captions (`S/bot-activity-model.ts:13-33`): `computer_use*` by `args.action`: capture/screenshot "Looked at the
screen", click/left_click "Clicked", double_click "Double-clicked", right_click "Right-clicked", middle_click
"Clicked", type "Typed", key/hotkey/press_key "Pressed keys", scroll "Scrolled", drag "Dragged", move/mouse_move
"Moved the pointer", zoom "Zoomed in", wait "Waited", anything else "Used the computer"; plus " in <app>" when
`args.app` is a non-empty string. `browser_navigate`: "Opened <host>" or "Opened a page". browser_vision /
browser_screenshot "Looked at the page", browser_click "Clicked in the browser", browser_type "Typed in the browser",
browser_scroll "Scrolled the page", browser_snapshot "Read the page", browser_back "Went back", anything else "Used the
browser".

**Native.** `HermesKit/Screen/ScreenshotFeed.swift`: `@MainActor final class ScreenshotFeed` (one per open fallback
view) with `shot: Shot?`, `state: .searching | .none | .unreachable | .loading | .expired | .shown`, `working: String`.
A `Task` ticks every 3 s (6 s in Low Power Mode or when `ProcessInfo.thermalState >= .serious`: DECISION D9, the
web's `powerInterval`) only while the view is visible and the app active; one tick at a time. Pure, unit-tested
functions `latestShot(rows:)`, `liveShot(payload:now:)`, `shotCaption(tool:args:)`, `shotAge(at:now:)`,
`hostKind(paths:)` ported one for one. Live: one `for await event in client.events()` loop; an event counts when its
`sessionId` is the runtime id of a chat of this bot that this run opened (`AppModel.screenOwnsSession`: the chat on
screen, a chat still sending its queue off screen, a chat whose reply is still running, and every runtime session a
chat of the bot settled on in this run, the web's `sessionOwner`; corrected by the builder: a bot whose chat was left
keeps working, and that is exactly when this page is watched) or its stored id is one of the sessions the last poll
listed. The picture loads through
`ActivityMedia.loadFull` (gateway path) or is decoded from the `data:` URL off the main thread; the previous picture
stays up while the next loads; a failed load → `.expired`.

**Wire.** §2.5. Example stored row the feed reads:

```json
{"role":"tool","tool_name":"computer_use","tool_call_id":"call_7","timestamp":1791700123,
 "content":"Clicked Save. Shareable screenshot saved to /Users/x/.hermes/screenshots/shot-0007.png"}
```

Live payload: `{"type":"tool.complete","session_id":"ab12cd34","payload":{"tool_id":"call_8","name":"computer_use",
"args":{"action":"click","app":"Safari"},"result":{"content":[{"type":"image_url","image_url":{"url":"data:image/png;base64,…"}}],
"meta":{"screenshot_path":"/Users/x/.hermes/screenshots/shot-0008.png"}}}}`.

**States and wording.** In §5.14 (the view). The model's states map to its empty lines.

**Owner.** `MEM/bot-screen-harness.md`: no gateway the owner runs has a live screen today, so this is what the owner
sees first. `MEM/finish-everything-push.md`: "watching a bot's computer".

**Fixture.** `CTL {"mode":"unsupported","shots":{"seed":3}}` seeds a session with three screenshot rows;
`CTL {"shots":{"live":{"tool":"computer_use","action":"click","app":"Safari"}}}` emits `tool.start` then, 400 ms
later, `tool.complete` with an inline image; `{"shots":{"stored":1}}` appends a stored row and bumps `last_active`
without any event (a run from Telegram or cron).

**Acceptance.**
1. Three seeded shots: the view shows the newest with its caption and age within 4 s of opening.
2. `live`: the caption turns to "Clicked in Safari…" then the new picture replaces the old one without a blank gap.
3. `stored: 1`: the new picture arrives within two polls (≤ 7 s) with no event.
4. LEDGER: while nothing changes, only the sessions list is polled (no messages fetch); with the app in the background
   for 10 s, no request at all.
5. Fixture stopped: "Can’t reach the gateway to look for screenshots. Trying again…" after the second failed poll, and
   the picture returns by itself once the fixture is back.
6. Unit tests port `S/bot-activity-model.test.ts` cases for all five pure functions.

### 5.3 L345 — Tool screenshots (computer_use / browser) shown in cards; expired captures marked as gone

**Web.** A `computer_use` result is a multimodal envelope the vendor tool card did not read; a reloaded transcript
keeps only its text summary. `S/image-zoom.ts:9-25` `multimodalToolImage(result)`: first
`content[].image_url.url` (string or `{url}`) starting `data:image/`; else `meta.screenshot_path`; else
`screenshot_path`; else any string field matching `/screenshot (?:saved to|path:)\s*(\S+\.(?:png|jpe?g|webp))/i`
(`:27-28`). `storedScreenshot(result)` (`:33-39`): a string is parsed as JSON when it is an object, else matched with
the same pattern. `B/fe-screen-gates.ts:35-43`: the tool card of a `^(computer_use|browser_)` tool shows that image;
tapping opens the lightbox, which zooms (`attachImageZoom`, `S/image-zoom.ts:45-107`: pinch to 5×, pan, double-tap
2.5×/fit). Expiry (`S/tool-screenshots.ts:39-71`): the gateway keeps only its 20 newest captures, so once per tool
call the card lists the file's folder (`GET /api/fs/list?path=<dir>`); a listing is cached 60 s per folder
(`LISTING_TTL_MS`), fetched again when it predates the capture by less than a second, and an unreadable or empty
listing proves nothing (ask again at most every 30 s, `RETRY_MS`); `data:`, `blob:` and `http(s):` sources are never
checked; caps: 64 listings, 2,000 settled calls. A file that is gone: no image, and the card's detail starts with
"This screenshot has expired: the gateway keeps only its 20 most recent screenshots." followed by a blank line and the
stored summary; the card stays closed.

**Native.** Tool calls draw as steps; a step's detail is `StepDetailViewController`
(`NAT/App/Chat/Activity/StepSheets.swift:88-240`). DECISION D10: the screenshot shows in the step's sheet (the native
home of a tool card's detail), not as an inline frame in the transcript; `image_generate` keeps the only inline frame.

* `HermesKit/Chat/ChatMeta.swift`: `ToolDetail.screenshot: ToolScreenshot?` where
  `ToolScreenshot { source: String /* gateway path or data: URL */; expired: Bool }`. Set where `generatedImage` is
  set today, for tools matching `ToolScreenshots.isScreenshotTool(name)`: live in
  `LiveChatSession+Events.swift:321-324` from `ToolScreenshots.liveSource(result:resultText:summary:)`, stored in
  `Hydration.swift:838-846` from `ToolScreenshots.storedScreenshot(tool.result)`. A `data:` source is kept only in
  memory and never written to the transcript cache (`slimmedForCache` drops it; `TranscriptCoding` writes the path
  form only), so the cache stays bounded.
* `HermesKit/Screen/ToolScreenshots.swift`: the three parsers, and `actor ScreenshotExpiry` (one per account) with the
  web's rules and numbers (60 s listing reuse, +1 s capture rule, 30 s retry, caps 64 / 2,000; stored timestamps are
  seconds, live ones milliseconds). `check(toolCallId:path:completedAt:) async -> Bool` (true = expired).
* `App/Screen/StepScreenshotBlock.swift`: a block added to `StepDetailViewController.build()` right under the subtitle
  for a step with `detail.screenshot`: label "Screenshot", the picture (aspect-fit, max height 260 pt, corner radius
  12, loaded with `ActivityMedia.loadImage`, shimmer while loading), tap → the app's media viewer
  (`ActivityMedia.present`, which integration points at `MediaViewer`: pinch, pan, double-tap). When the sheet opens it
  asks `ScreenshotExpiry`; expired → the picture is replaced by the note, and the Output section starts with the note,
  a blank line, then the stored summary. A picture that fails to load while the listing says nothing shows
  "Open image: <file name>" as the generated-image card does (`ActivityCells.swift:413`), which retries.

**Wire.** `GET /api/fs/list?path=/Users/x/.hermes/screenshots` →
`{"entries":[{"name":"shot-0007.png"},{"name":"shot-0008.png"}]}`; `GET /api/fs/download?path=…&profile=…`.

**States and wording.** Loading (shimmer) · picture (VoiceOver "Screenshot", trait image, hint "Double tap to view
larger") · expired: "This screenshot has expired: the gateway keeps only its 20 most recent screenshots."
(`S/tool-screenshots.ts:15`) · load failed: "Open image: shot-0007.png".

**Owner.** `MEM/bot-screen-harness.md` (macOS gateway, no live screen): screenshots are how the owner sees what a bot
did on the Mac today.

**Fixture.** `CTL {"shots":{"seed":3,"chat":true}}` puts the three tool rows in the bot's own chat transcript;
`{"shots":{"expire":["shot-0001.png"]}}` removes a file from the listing and from downloads;
`{"shots":{"listing":"fail"}}` makes `/api/fs/list` answer 500.

**Acceptance.**
1. Open the bot's chat, open a `computer_use` step: the screenshot shows; tap it: the viewer opens and zooms.
2. Leave and reopen the chat (stored rows): the same step still shows its screenshot (the path form).
3. `expire`: that step shows the expired note, no broken picture, and its Output starts with the note.
4. `listing: fail`: the picture still loads when the file exists; LEDGER shows at most one `fs/list` per 30 s for that
   step however often the sheet is reopened.
5. LEDGER `fs_list_hits` is 1 after opening three steps of the same folder within 60 s.
6. Unit tests port `S/tool-screenshots.test.ts` and the `storedScreenshot` cases of `S/image-zoom.test.ts`.

### 5.4 L508 — Bot menu Screen entry labelled by status ("View screen" / "View latest screenshots")

**Web.** `S/bot-screen-menu.tsx:29-37` (`BotScreenMenuItem`) and `S/bot-screen-phone.tsx:729-750`
(`screenMenuLabel(tone, label, gateway)`): tone unsupported or unavailable → "View latest screenshots" and the
gateway is remembered as `screenshots`; tone unknown → the gateway's remembered kind, else the neutral "View screen";
any other tone → the live label, remembered as `live`. The label is computed once per menu opening; the icon is
`file-media` for screenshots, else `device-desktop`. This was the vendor context menu's entry; the phone's own Bots
list (L166) calls the same function (`S/ui-bots/bot-row.tsx:77`).

**Native.** DECISION D5: one menu, one entry. HQ Native has a single bot menu (the Bots row menu of §5.1), so this
row's rule — label by status, remembered per gateway, fixed while the menu is open — is implemented by
`ScreenService.kind(for:)` and the wording is §5.1's (the phone list's "Watch Screen / View Screen / Latest
Screenshots"; the lower-case strings belonged to the vendor menu the phone list replaced). The same `kind` labels the
Bot Info tile and Computer row (§6).

`ScreenService.kind(for profile:)`:

```swift
switch tone(for: profile) {                      // §4
case .unsupported, .unavailable: holds.rememberKind(.screenshots, account); return .screenshots
case .unknown:                   return holds.rememberedKind(account) ?? .unknown
default:                         holds.rememberKind(.live, account); return .live
}
```

**Wire.** None of its own. **States.** As §5.1. **Owner.** As §5.1.

**Fixture.** `CTL {"mode":"unavailable"}` (every `display.*` answers `-32601`), `{"mode":"off"}`, `{"mode":"mac"}`.

**Acceptance.**
1. `mode: unavailable`: open and close a Screen → "Latest Screenshots".
2. `mode: off` (supported, not running): open and close → "Watch Screen" (any known tone but the two fallbacks is
   live).
3. With the menu open, `CTL {"mode":"unsupported"}` plus a `display.status` event: the open menu's label does not
   change; the next opening shows the new label.
4. Unit: `ScreenToneTests` covers every branch of tone and kind, including the remembered kind.

### 5.5 L509 — Bot Screen on phone: zoom, pan, double-tap, tap, drag, right click, remote scroll

**Web.** `S/bot-screen-phone.tsx`. Constants (`:20-28`): `TAP_SLOP = 10` pt, `LONG_PRESS_MS = 550`,
`DOUBLE_TAP_MS = 320`, `MAX_ZOOM = 5`, `DOUBLE_TAP_ZOOM = 2.5`, `WHEEL_TRAVEL_PX = 24`, `WHEEL_STEP = 50`.

*Watching (`client.viewOnly`)*: two fingers pinch to zoom the local view up to 5× and pan it; one finger pans a
zoomed view; a double tap (two taps within 320 ms and 30 pt, `:372-377`) toggles between fit and `fillZoom` — the
level at which the fitted desktop fills the viewport (width in landscape, height in portrait), or 2.5× when it
already nearly fills it (`fill ≤ 1.15`, `:75-79`).

*In control* (`:220-390`): the picture is a **relative trackpad**. The pointer is kept as fractions of the desktop,
starts at the centre (0.5, 0.5: "the stream has no cursor-position messages"), and is clamped to
`[0, 1 − 1/width] × [0, 1 − 1/height]`.
* One finger moving (past 10 pt): the pointer moves by the finger's travel divided by the drawn desktop's size, no
  button pressed.
* Tap: move to the pointer, press and release the left button there.
* Hold still 550 ms, then lift without moving: right click (button 2) at the pointer.
* Hold still 550 ms, then move: left button down at the pointer, then moves (a drag); lifting releases.
* A second finger landing ends a drag where it is.
* Two fingers: `|scale − 1| > 0.08` → local zoom; otherwise, at fit size, a steady vertical move past 10 pt → remote
  scroll: one wheel step per 24 pt of travel, fingers up = wheel down (content follows the fingers, `:303-309`).
* A cancelled touch ends a drag without clicking (`:381-389`).
* A pinch commits its view when the fingers lift; rotation and keyboard changes re-clamp it.

View math (`:44-103`): `clampView`, `zoomAbout`, `clampToDesktop(view, width, height, aspect)` (pan never reaches the
letterbox bands; a desktop smaller than the view stays centred), `fillZoom`.

The toolbar (`V/screen-pane.tsx` live view, `B/bot-screen-gates.ts`): who is in control ("Bot is in control" / "You
are in control" / "Another viewer is in control"), "Take Control", "Give Back", "End Their Control"; Take Control is
disabled on a Mac whose input is not ready (`platform === 'darwin' && mac?.inputReady !== true`); a successful Take
over or Give Back clears an earlier error. The gesture line while in control and not typing
(`S/bot-screen-controls.tsx:172`): "Drag anywhere to move · Tap to click at the cursor · Hold then move to drag ·
Hold to right-click". Native (audit 09-22) adds "· Two fingers scroll · Pinch to zoom", which work and which the Browser's
hint names.

**Native.**

`ScreenStageView` (a `UIView`, `isMultipleTouchEnabled`, black):
* `pictureLayer` (`CALayer`): `contents` = the stream's newest `CGImage`; its frame is the drawn desktop
  (`ScreenViewMath.drawn(stage:aspect:view:)`), set inside `CATransaction.setDisableActions(true)`. `aspect` =
  framebuffer width ÷ height. `minificationFilter = .trilinear`, `magnificationFilter = .linear`.
* Touches by `touchesBegan/Moved/Ended/Cancelled`, a direct port of the web handlers with the constants above, in
  `ScreenViewMath` (pure) plus a small `ScreenGesture` state struct so every rule is unit-tested without a view.
* Pointer → wire: `x = min(fbWidth − 1, Int((pointer.x × fbWidth).rounded()))`, same for y. Sends:
  move `PointerEvent(mask: held, x, y)`; tap `move, mask 1, mask 0`; right click `move, mask 4, mask 0`; drag
  `move, mask 1 … mask 0`; wheel step `mask | 16` then `mask` (down) or `mask | 8` then `mask` (up) at the pointer.
  Moves are coalesced to at most one per display frame; the last position is always sent before a button changes.
* DECISION D4: the client does not ask for the Cursor pseudo-encoding, so both backends paint the pointer into the
  picture (the Mac helper captures with `showsCursor = true`, `M/DispatchScreen/ScreenCapture.swift:65`; Xvnc renders
  it for clients without cursor support). No client-side cursor shape code.
* DECISION D6: while a finger is down in control mode a small ring (14 pt, white with a dark hairline) marks the
  pointer's position at once and fades 0.3 s after the finger lifts, so movement feels immediate even when the
  picture is a frame behind. It is feedback only; with Reduce Motion it does not fade, it disappears.
* Haptics: a selection tick when a hold arms (550 ms), a light impact when Take Control succeeds, a warning when control
  is taken away.

`ScreenControlBar`, control row (always visible in S6):

| Lease | Caption (`screen.caption`) | Buttons |
|---|---|---|
| agent | <Bot> is in control (“The bot is in control” with no name) | "Take Control" (`screen.take`, prominent glass) |
| mine | You are in control | "Give Back" (`screen.give`) |
| another person | Another viewer is in control | "Take Control", "End Their Control" (`screen.force`) |
| a hold this phone lost track of (§5.8) | You were in control (orange) | "Resume Control" (`screen.take`), "Give Back" (`screen.give`) |

Buttons are `UIButton.Configuration.glass()` / `.prominentGlass()` (system Liquid Glass; no painted bar behind them,
as the Watch Browser bar). While a lease call runs its button shows a spinner and both are disabled. On a Mac with
`inputReady != true` "Take Control" / "Resume Control" is disabled and the note of §5.9 says why. Each time control starts,
a pill above the bar shows the gesture line for 8 s (DECISION D7: a timed pill like Watch Browser's hint, not a
permanent line, so a landscape phone keeps its height; VoiceOver reads it once as an announcement).

**Wire.** `display.lease.acquire {"profile":"default","viewer_id":"v_9f…"}` →
`{"lease":{"holder":"human","viewer_hash":"3c1a0b9d2e7f","since":…,"epoch":4,"reason":""}}`;
`display.lease.release {"profile":"default","viewer_id":"v_9f…"}` → `{"lease":{"holder":"agent",…,"epoch":5}}`;
`display.lease.release {"profile":"default","force":true}`; RFB PointerEvents (§2.3).

**States.** Attaching / live watching / live in control / another viewer in control / held; lease call failing (the
error's own message in the notes' error line with "Dismiss").

**Owner.** `MEM/finish-everything-push.md`: "watch and take control". `MEM/browser-takeover-rebuild.md`: "one finger
moves a drawn pointer (relative), tap clicks at pointer, hold+drag drags, two fingers scroll".

**Fixture.** `CTL {"mode":"mac"}` (1280×800 test desktop, Tight-JPEG like the helper), `{"mode":"linux"}` (display
":7", Tight Basic + CopyRect + Raw), `{"other_takes":true}`, `{"agent_takes":true}`. The fixture paints its own
pointer and a marker at each click (red = left, purple = right) so a person can see where input landed; LEDGER lists
every key, pointer and clipboard message it accepted and counts those it dropped.

**Acceptance.**
1. `mode: mac`: the picture appears within 3 s; the stage's debug value shows frames rising and `mainDecodes=0`.
2. Watching: pinch out zooms (≤ 5×), one finger pans, double tap fills, double tap again fits; LEDGER has **no**
   pointer or key message (`inputs == []`, `dropped_inputs == 0`).
3. Take Control → "You are in control"; LEDGER `lease.holder == "human"` with this viewer's hash.
4. Swipe: LEDGER pointer moves with mask 0, starting from the desktop's centre; tap: one press/release of mask 1 at
   the same point; hold 0.7 s and lift: press/release of mask 4; hold then move: mask 1 down, moves, mask 0 on lift.
5. Two-finger vertical swipe of 96 pt at fit size: 4 wheel steps (mask 16 pairs) in the right direction; a pinch
   instead zooms and sends no wheel.
6. Give Back → "<Bot> is in control"; further touches send nothing.
7. `other_takes` while watching: caption "Another viewer is in control", "End Their Control" → LEDGER lease agent.
8. `mode: linux`: the same checks pass against Tight Basic / CopyRect / Raw frames, and the stage's probe value equals
   the fixture's expected pixels (lossless encodings).
9. Unit: `ScreenViewMathTests` and `ScreenGestureTests` port `S/bot-screen-phone.test.ts` (clamp, zoom-about,
   clamp-to-desktop, fill zoom, pointer clamps, tap / hold / drag / wheel / cancel sequences).

### 5.6 L510 — Key bar: Fit, keyboard toggle, Esc/Tab/arrows, modifiers, Paste

**Web.** `S/bot-screen-controls.tsx:118-190`. Under the picture: "Fit" (aria "Fit screen"), only while zoomed;
⌨︎ (aria "Show Keyboard" / "Hide Keyboard", pressed state), only while in control and live. While typing, a toolbar
"Special keys": Esc, Tab, ←, ↑, ↓, → (spoken "Escape", "Tab", "Left arrow", "Up arrow", "Down arrow", "Right arrow");
modifiers "Ctrl" (spoken "Control") and, on a Mac host only, "⌥" ("Option") and "⌘" ("Command"): sticky, used by the
next key, then cleared; "Paste". A hidden field (aria "Type on the bot's screen"; autocapitalise, autocorrect and
spellcheck off) feeds `remoteKeyboard`: typed text → one key press per character under the held modifiers
(`sendText`, `S/bot-screen-phone.tsx:127-129`); Enter → Return; delete backward → BackSpace; an IME composition is
sent once, when committed; a hardware keyboard's Ctrl/⌥/⌘ combinations (and Shift with named keys) are sent as chords.
Keysyms (`:106-111`): Latin-1 (0x20–0x7E, 0xA0–0xFF) maps to itself, anything else is `0x01000000 + code point`;
BackSpace 0xff08, Tab 0xff09, Return 0xff0d, Escape 0xff1b, Delete 0xffff, Left 0xff51, Up 0xff52, Right 0xff53,
Down 0xff54, Shift 0xffe1, Control 0xffe3, Alt 0xffe9, Super 0xffeb (⌘ is Super_L, ⌥ is Alt_L, "as the Mac helper maps
them"). `sendChord` (`:119-124`): modifiers down in the order shift, ctrl, alt, meta; the key pressed and released;
modifiers up in reverse. Paste (`S/bot-screen-controls.tsx:55-67`): empty clipboard → note "The clipboard is empty" (native: "There’s no text to paste.")
(3 s); a Mac host and text entirely within U+0000–U+00FF → ClientCutText then ⌘V; anything else is typed.

**Native.** `ScreenControlBar`, tools row, glass buttons with the web's faces and spoken names:

* `Fit` (`screen.fit`, label "Fit screen"): shown while zoom > 1, in control or not. Animates to fit (no animation
  with Reduce Motion).
* Keyboard (`screen.keyboard.toggle`, SF Symbol `keyboard` / `keyboard.chevron.compact.down`, label "Show Keyboard" /
  "Hide Keyboard"): shown while this phone is in control and the stream is live.
* While the keyboard is up: `Esc` `Tab` `←` `↑` `↓` `→`, then `Ctrl` (+ `⌥` `⌘` when `display == "This Mac"`), then
  `Paste` (ids `screen.key.esc` … `screen.mod.ctrl` … `screen.paste`). Portrait: two rows (keys, then modifiers +
  Paste); landscape: one row that scrolls sideways if it must. An armed modifier is drawn selected and carries the
  selected trait; it clears after the next key, text or paste.
* `ScreenKeyField` (pattern: `NAT/App/Browser/BrowserKeyField.swift`): a 1 × 1 pt `UITextField`, alpha 0.02, no
  caret, autocorrection, capitalisation, spell check, smart quotes/dashes and inline prediction off, default keyboard
  (emoji and other scripts are allowed: they are typed by code point), label "Type on the bot’s screen", id
  `screen.keyboard`. Text changes → `ScreenKeys.events(for: text, mods:)`; nothing is sent while
  `markedTextRange != nil`; `deleteBackward` → BackSpace; Return → Return. `keyCommands` for arrows, Escape and Tab
  with `wantsPriorityOverSystemBehavior`; `pressesBegan` turns a hardware key with Control / Option / Command (and
  Shift with a named key) into a chord. Losing control, a stream end or Close resigns the field.
* Paste: `UIPasteboard.general.hasStrings == false` or an empty string → pill "There’s no text to paste." for 3 s.
  Otherwise Mac host, every scalar ≤ U+00FF and ≤ 262,144 bytes → `ClientCutText` + chord (Super, `v`); else typed.
  Typed text goes out in slices of 500 characters per run-loop turn so the app never stalls; handing back, losing
  control or closing drops the rest. iOS may show its own "Allow Paste" prompt; a refusal reads as an empty clipboard.

**Wire.** `Ctrl` then `c`: KeyEvents `(0xffe3 down) (0x63 down) (0x63 up) (0xffe3 up)`. "é" → 0xe9; "€" →
0x010020AC. Paste "Hello" on a Mac: `[6,0,0,0, 0,0,0,5, 48 65 6c 6c 6f]` then `(0xffeb down)(0x76 down)(0x76 up)(0xffeb up)`.

**States.** Not in control: no keyboard button (Fit only when zoomed). In control: keyboard down / keyboard up with
keys / a modifier armed. Notes of §5.9 explain when typing is ignored (Mac locked, password field).

**Owner.** "watch and take control" (`MEM/finish-everything-push.md`); the keyboard and paste pattern the owner uses in
Watch Browser (`MEM/browser-takeover-rebuild.md`).

**Fixture.** `mode: mac` (⌥ and ⌘ present, clipboard path) and `mode: linux` (Ctrl only, paste is typed). LEDGER keeps
key events (keysym + down) and clipboard messages (length and text; fixture values are invented).

**Acceptance.**
1. In control, tap the keyboard button: the iOS keyboard rises, the bar rides it, the picture shrinks, nothing covers
   it.
2. Type `Hi é€`: LEDGER shows press/release pairs for 0x48, 0x69, 0x20, 0xe9, 0x20, 0x010020AC in order.
3. Return, delete, Esc, Tab and the four arrows each produce their keysym.
4. Tap `Ctrl`, then type `c`: the chord above; `Ctrl` is no longer selected.
5. `mode: mac`: `⌥` and `⌘` are present; `mode: linux`: they are absent.
6. Copy "Hello" on the phone, tap Paste on `mac`: one ClientCutText of 5 bytes and the ⌘V chord. Copy "héllo 👋":
   typed key by key instead. On `linux`: typed. Empty clipboard: the pill "There’s no text to paste.".
7. Give Back while the keyboard is up: the keyboard falls and the keys disappear.
8. Unit: `ScreenKeysTests` (keysyms, chord order, text under modifiers, Latin-1 rule, 256 KiB limit, IME commit).

### 5.7 L511 — "Turn your iPhone sideways" hint; compact typing view

**Web.** `S/bot-screen-controls.tsx:118-150` and `S/bot-screen-phone.tsx:764-766`: once ever
(`dispatch.botScreen.rotateHintSeen`), on a touch phone in portrait (width < 768, short side < 600; never an iPad),
the hint "Turn your iPhone sideways for a larger screen" (`DeviceWord.name`, UX study #179) shows for 6 s. Compact typing (`:83-96`, `:248-256`): with
the keyboard up and the visible area short and wide (`height < 500 && width > height`), the desktop is zoomed to fill
the width with the last tapped point's row in the middle (`fillWidthView`); the earlier view comes back when typing
ends, unless the person pinched or tapped Fit meanwhile. When the layout changes, a zoomed view pans so the last
tapped point stays 40 pt (`KEEP_CLEAR_PX`) inside the visible edges (`keepVisible`, `:99-103`). The shared-Mac note
hides during compact typing.

**Native.**
* **Landscape.** The app is portrait-only (`NAT/App/Info.plist:51`). DECISION D8: the Screen viewer alone rotates.
  `AppDelegate.application(_:supportedInterfaceOrientationsFor:)` returns `.allButUpsideDown` while a
  `ScreenViewerController` is presented and `.portrait` otherwise; `ScreenNavigationController` overrides
  `supportedInterfaceOrientations` to `.allButUpsideDown`; on Close the presenter calls
  `setNeedsUpdateOfSupportedInterfaceOrientations()` so the app returns to portrait. `Info.plist` stays portrait, so
  launch is unchanged. If the builder finds the delegate mask alone does not rotate on this SDK, add the two landscape
  values to `UISupportedInterfaceOrientations` and keep the delegate mask as the gate (it then decides at run time);
  record which was needed in the report.
* **Hint.** The first time a live picture shows in portrait and `hq.screen.rotateHintSeen` is unset: set the flag and
  show the pill "Turn your iPhone sideways for a larger screen" above the bar for 6 s (id `screen.hint.rotate`).
* **Compact typing.** `ScreenViewMath.compactTyping(typing:visible:)` with `visible` = the stage's bounds (already
  above the keyboard and bar). Entering: remember the view, apply `fillWidthView(width, height, aspect, tapped?.fy)`
  when it is not nil. Leaving: restore unless touched. `keepVisible` on every stage size change while zoomed and a
  tap is remembered. In compact typing the top bar hides its subtitle and the shared-Mac note hides.

**Wire.** None.

**States.** Portrait first run (hint) · portrait later (no hint) · landscape · landscape typing (compact) · back.

**Owner.** No note names this hint; it ships as the web has it. A desktop on a portrait phone is small, which is why
the owner-approved web build tells people to turn the phone.

**Fixture.** `mode: mac`; `CTL {"stream":{"size":[1920,1080]}}` for a wide desktop.

**Acceptance.**
1. Fresh install, portrait, open a live Screen: the hint shows once for about 6 s; close and reopen: no hint.
2. Rotate (`XCUIDevice.shared.orientation = .landscapeLeft`): the viewer rotates and the desktop grows; close the
   viewer: the app is portrait again and the Bots list never rotates.
3. Landscape, take over, tap near the bottom of the desktop, open the keyboard: the desktop fills the width and the
   tapped row is visible above the bar; close the keyboard: the earlier view returns.
4. Same, but pinch while typing: closing the keyboard keeps the pinched view.
5. Unit: `compactTyping`, `fillWidthView`, `keepVisible` and the rotate-hint predicate, ported from the web tests.

### 5.8 L512 — Control survives a socket swap or relaunch; "You were in control…"; force hand-back

**Web.** `S/bot-screen-phone.tsx:461-556`. Hermes honours a viewer id only on the `/api/ws` connection that minted it,
and the lease names its holder by hash. So:
* **This run** (`sessionHolds`, `shouldReclaim`, `reclaimScreenLease`, `:477-500`): after a re-observe mints a new id,
  if the lease is a human's, is not the new id's, and its hash is the previous id's of this pane or of another attach
  this app made, the new id takes the lease: read `display.status` again first (a lease that no longer names our
  earlier hold is left alone), then `display.lease.acquire {viewer_id: <new id>}`. A superseded attach does not
  acquire. A failed recheck acquires nothing.
* **Across relaunches** (`:502-539`): while this phone holds, `{id, hash, at}` is saved; it is forgotten when the
  lease is known to be someone else's or after 24 h. `heldBefore(saved, lease, viewer)`: the lease still names the
  saved hash and the current attach does not hold it → the Screen shows the "You were in control" badge, the note "You
  were in control of this screen. Resume Control, or give it back to the bot.", "Take Control" reads "Resume Control",
  and "Give Back" calls `display.lease.release {viewer_id: <saved id>, force: true}` (`handBackHeldScreen`, `:544-546`).
* **Leaving** (`leaveBotScreen`, `:549-556`): holding with the stream open → the stream's close 1000 hands back;
  holding with the stream down → release by id with `force`; not holding but a saved hold exists → release that id
  with `force`; then forget the saved hold. Offline: nothing is forgotten, the next launch offers it again.
* **Another viewer** holds: note "Another viewer has control. End Their Control gives it back to the bot." and "Give Back
  (force)" → `display.lease.release {force: true}`.
* **Eviction** (`V/screen-pane.tsx`): close 4000 or reason `control-taken` → "Another viewer took control. Watching
  only." and a re-attach in watch mode; more than `MAX_RAPID_EVICTIONS = 3` within `EVICTION_LOOP_WINDOW_MS = 10 s` →
  the error state with that text.
* If the pane closed while a reclaim's acquire was in flight, the new id is released with `force`
  (`B/fe-screen-gates.ts`).

**Native.** `HermesKit/Screen/ScreenHolds.swift` (pure rules + storage) and `ScreenSession`:

```swift
func shouldReclaim(prior: Viewer?, minted: Viewer, lease: ScreenLease?, own: Viewer?) -> Bool {
    guard let lease, lease.holder == .human, let hash = lease.viewerHash, hash != minted.hash else { return false }
    return hash == prior?.hash || hash == own?.hash
}
func heldBefore(saved: SavedHold?, lease: ScreenLease?, viewer: Viewer?) -> SavedHold? {
    guard let saved, lease?.holder == .human, lease?.viewerHash == saved.hash else { return nil }
    return viewer?.hash == saved.hash ? nil : saved
}
```

* `ScreenHolds.session[accountId|profile]` is this run's newest hold; `saved(account, profile)` reads
  `hq.screen.held.<accountId>.<profile>` (nil when malformed or older than 24 h).
* In `attach()`, after `display.observe`: if `shouldReclaim` → `display.status` (fresh lease) → check again →
  `display.lease.acquire {profile, viewer_id: minted.id}`; an attach superseded meanwhile (its generation is stale)
  skips the acquire; if the viewer was closed while the acquire ran, `display.lease.release {profile, viewer_id:
  minted.id, force: true}`.
* Whenever `lease` or `viewer` changes: holding → `session[key] = viewer`, save `{id, hash, now}` when the hash
  differs from the saved one; lease known to be someone else's → delete the saved hold.
* A relaunch starts with an empty `session` map, so nothing is reclaimed silently: the badge and the two buttons of
  §5.5 ask.
* Leaving (Close, sign-out, account switch, `ScreenService.shutdown()`): exactly the web's three cases. Close never
  waits on the network: the release runs in a task that outlives the viewer (bounded 10 s) and the viewer dismisses
  at once.
* Eviction: on close 4000 → pill "Another viewer took control. Watching only." (warning haptic), resign the keyboard,
  re-attach with `prior = nil` semantics for control (the new id does not reclaim: the lease is the other person's).
  A fourth eviction inside 10 s → S7 with that text and "Reconnect".
* The hard limit stays (`MEM/bot-screen-harness.md`): "after the 20 s background grace the phone loses control
  authority, because viewer ids are bound per /api/ws connection." The reclaim above is the phone-side answer the web
  shipped; nothing in Hermes changes (`MEM/hermes-code-not-ours.md`).

**Wire.**

```
→ display.observe {"profile":"default","viewer_id":"v_old"}          (new /api/ws connection)
← {…,"viewer_id":"v_new","ticket":"t2","path":"/api/display/ws","lease":{"holder":"human","viewer_hash":"<hash(v_old)>","epoch":7}}
→ display.status {"profile":"default"}                               (recheck)
→ display.lease.acquire {"profile":"default","viewer_id":"v_new"}
← {"lease":{"holder":"human","viewer_hash":"<hash(v_new)>","epoch":8}}
…
→ display.lease.release {"profile":"default","viewer_id":"v_old","force":true}     ("Give Back" of a held screen)
→ display.lease.release {"profile":"default","force":true}                         ("End Their Control")
```

**States and wording.** Badge "You were in control"; note "You were in control of this screen. Resume Control, or
give it back to the bot."; buttons "Resume Control", "Give Back"; note "Another viewer has control. End Their Control
gives it back to the bot."; button "End Their Control"; pill "Another viewer took control. Watching only."

**Owner.** `MEM/bot-screen-harness.md` (the per-connection limit, quoted above); `MEM/finish-everything-push.md`
("watch and take control").

**Fixture.** Faithful lease rules (§7): ids minted per `/api/ws` connection, hash, epoch, 5300 refusals, force
release, hand-back only on close 1000/1001. `CTL {"drop_ws":true}` closes the app's `/api/ws` (the app reconnects on
a new connection); `{"stream":{"drop":true}}` cuts the display socket without a close frame; `{"other_takes":true}`
evicts with 4000; `{"other_takes":3,"every_ms":1500}` does it repeatedly.

**Acceptance.**
1. In control, `drop_ws`: within a few seconds the Screen is live again and still "You are in control"; LEDGER shows
   observe (new id), status, acquire with the new id, and the lease's hash changed from the old id's to the new one's
   with no agent epoch in between.
2. In control, terminate the app (`XCUIApplication.terminate()`), relaunch, open the Screen: badge "You were in
   control", the note, "Resume Control" and "Give Back". "Give Back" → LEDGER release `{viewer_id: <old>, force:
   true}`, lease agent, badge gone. Repeat and tap "Resume Control" → "You are in control" and input works.
3. In control, Close: LEDGER shows the display socket closed with 1000 and the lease back with the agent; the saved
   hold is gone (relaunch shows no badge).
4. In control, `stream.drop`, then Close before it reconnects: LEDGER shows release `{viewer_id, force: true}`.
5. `other_takes` while in control: the pill, watch mode, keyboard down, no input sent afterwards.
6. `other_takes: 3` + one more within 10 s: "Another viewer took control. Watching only." with "Reconnect".
7. A saved hold older than 24 h (test seam sets `at`): no badge.
8. Unit: `ScreenHoldsTests` port the `shouldReclaim` / `reclaimScreenLease` / `heldBefore` / `leaveBotScreen` cases of
   `S/bot-screen-phone.test.ts`, including "another viewer took control between observe and acquire" (no acquire).

### 5.9 L513 — Screen notes

**Web.** `S/bot-screen-phone.tsx:563-580` (`ScreenNotes`), under the toolbar, in this order, each only when true:

| When | Line |
|---|---|
| a hold this phone lost track of (§5.8) | You were in control of this screen. Resume Control, or give it back to the bot. |
| another person holds the lease | Another viewer has control. End Their Control gives it back to the bot. |
| Mac host (`display == "This Mac"`) | This is the Mac’s own screen, shared by all bots on this Mac. |
| Mac health known and `control == false` | Control needs setup on this Mac before taps and typing can work. |
| `locked` | The Mac is locked: taps and typing are ignored until it is unlocked at the Mac. |
| `secureInput` | A password field has focus on the Mac, so macOS blocks typed text. |

Above them an error block (the failed call's message) with "Dismiss". The shared-Mac line is context only and hides
during compact typing. `B/bot-screen-gates.ts`: when the Mac's input is not ready the control-only setup card ("Enable
screen control", §5.13) shows too.

**Native.** `ScreenNotesView`: a vertical stack under the top bar (never under it: `MEM/ui-hunt-oct6.md`), each line
a wrapping footnote label with 12 pt above and below (`MEM/row-padding-feedback.md`), secondary colour; the
"control needs setup", "locked" and "password field" lines carry an orange `exclamationmark.triangle.fill`. The error
line is red with a trailing "Dismiss" button (`screen.error.dismiss`) and is posted to VoiceOver as an announcement.
More than three lines, or accessibility text sizes: the stack scrolls inside a height cap of 40 % of the screen so the
picture always keeps room. When the Mac's input is not ready, a one-line row "Enable Screen Control" with a chevron
opens the control-only setup card as a sheet (`ChatSheet.wrap` bar), so the card does not cover the picture.

**Wire.** The Mac lines read §2.4's health (polled by §5.10); the lease lines read the lease.

**States.** Zero to six lines plus the error line.

**Owner.** `MEM/finish-everything-push.md` ("watch and take control" on the macOS gateway): these lines are how a
person learns why control does not work yet on a Mac.

**Fixture.** `CTL {"health":{"control":false}}`, `{"health":{"locked":true}}`, `{"health":{"secure_input":true}}`,
`{"health":{"tcc_events":false}}`, `{"fail":{"display.lease.acquire":"Lease store is busy"}}`.

**Acceptance.**
1. `mode: mac`: the shared-Mac line shows; `mode: linux`: it does not.
2. `control: false`: "Control needs setup on this Mac before taps and typing can work.", Take Control disabled, the
   "Enable Screen Control" row present.
3. `locked: true` (takes effect at the next 15 s poll, or at once after `CTL {"health_now":true}` emits a
   `display.status` event): the locked line appears without reopening.
4. `secure_input: true`: the password-field line.
5. A failing acquire: the error line with the gateway's words; "Dismiss" removes it; a later successful Take Control
   removes it too.
6. Largest accessibility size: every line is readable in full (scrolls), and the picture is still visible.

### 5.10 L514 — Mac screen health poll every 15 s

**Web.** `S/mac-screen-health.ts:7-30` and `S/bot-screen-mac.ts:9-40`. Read
`/api/plugins/hermes-hq-screen/health`; on HTTP 404 read `/api/plugins/dispatch-screen/health`; remember whichever
answered (per connection) and ask it first next time; forget when both are 404. Polled only for a Mac screen, every
15 s on a power-aware interval and only while visible; an identical answer keeps the same object (no re-render).

**Native.** `HermesKit/Screen/MacScreenHealth.swift`:
`MacScreenHealthReader` (owned by `ScreenService`, one per account) with `read() async throws -> JSONValue?` (nil =
both 404) and the route memory; `MacScreen.parse(_:) -> MacScreen?` (§2.4; `Equatable`). `ScreenSession` starts a
poll task when `status.display == "This Mac"`: first read at once, then every 15 s (30 s in Low Power Mode or under
thermal pressure, D9), only while the viewer is visible and the app active; it stops on pause and Close. A failed read
keeps the last value. Request timeout 8 s. The legacy route name appears only in code, never on screen.

**Wire.** `GET /api/plugins/hermes-hq-screen/health` → §2.4; 404 → `GET /api/plugins/dispatch-screen/health`.

**States.** No UI of its own; feeds §5.5 (Take Control enabled), §5.9 (notes), §5.13 (card).

**Owner.** `MEM/hermes-hq-rename.md` (the plugin and helper were renamed; an older install still answers under the old
name) and `MEM/stress-audit-159.md` (the owner's Mac may still carry the old plugin).

**Fixture.** `CTL {"health":{"plugin":"new"}}` (default), `{"health":{"plugin":"legacy"}}` (only the old route
answers), `{"health":{"plugin":"none"}}`. LEDGER `health_hits: {"new": n, "legacy": n}` with timestamps.

**Acceptance.**
1. `plugin: new`, Screen open 40 s: 3 or 4 hits on the new route, none on the legacy one.
2. `plugin: legacy`: first a 404 on the new route, then only legacy hits (the route is remembered).
3. `plugin: none`: both tried once per poll at most; no Mac lines; Take Control disabled (input readiness unknown on a
   Mac), and the control-only setup row offered.
4. App in the background for 40 s: no hits; back in front: one hit at once.
5. `mode: linux`: no health request at all.
6. Unit: `MacScreenTests` (parse table from `S/bot-screen-mac.test.ts`, route memory, 404 handling).

### 5.11 L515 — Stream pauses when the Screen is out of view; resumes

**Web.** `S/bot-screen-phone.tsx:584-656` and `B/fe-screen-gates.ts` (r5-49): out of view (app hidden, another page
over the Screen) the pane closes its stream **without** code 1000 — "which is not a hand-back: a person's control
survives it like a dropped link" — and sets the connection idle; hidden applies at once, a look elsewhere after
`SCREEN_PAUSE_DELAY_MS = 1000`; back on view it attaches again at once (in control, via §5.8). `onScreenResume`
(`:584-596`): the app coming to the front, the network returning, and the gateway socket reopening each re-attach a
stream that is not live ("the pane ignores signals while a stream is live"). The stuck-frame watchdog
(`FLUSH_DEADLINE_MS = 8 s`, `:769-789`): a frame that cannot finish drawing for 8 s while visible ends the stream so a
fresh one attaches.

**Native.** `ScreenSession.setOnView(_:)`, driven by `ScreenViewerController`:

| Signal | Action |
|---|---|
| `UIScene.didEnterBackgroundNotification` | pause now |
| `UIApplication.willResignActiveNotification` (Control Centre, app switcher, a call banner), or a sheet/alert presented over the viewer | pause after 1 s if still away |
| `didBecomeActive`, the covering sheet dismissed | resume now |
| `NWPathMonitor` going from unsatisfied to satisfied | resume if not live |
| `client.connectionStates()` reaching `.ready` after any other state | re-attach (the viewer id belonged to the old connection) |

*Pause* = `socket.close(handBack: false)` (plain cancel, no close frame), decoder dropped, last picture kept on
screen dimmed, state idle, health poll and timers stopped. *Resume* = `attach()` with `prior` = the last viewer, so
control comes back through the reclaim. A stream that ends by itself while on view (not 4000, not 4001): one automatic
re-attach after 1 s when the gateway connection is `.ready` (DECISION D11: the web waits for a resume signal or a tap;
a single quiet retry spares a tap on a blip); if that attach fails or the stream ends again within 10 s → S7 "Screen
stream ended" with "Reconnect". Close code 4401 → observe again once. Stuck stream (DECISION D12, the native
form of the web's 8 s watchdog): while on view, an update that has begun and then receives **no byte for 8 s**, or a
decode that does not return within 8 s → end the stream and re-attach (counted as a failure for the 10 s rule). A slow
link that keeps delivering bytes is not stuck, however long the frame takes; time out of view does not count. A WebSocket ping every 20 s while live; no pong within 10 s → treated as a
dropped link. The device's idle timer is disabled while a live picture is on view (`isIdleTimerDisabled`), and
restored on pause and Close.

**Wire.** `display.observe` + a new display socket per resume; no `display.lease.release`.

**States.** Paused (invisible to the person: they are elsewhere) · resuming (S5 over the kept picture) · live · S7.

**Owner.** `MEM/bot-screen-harness.md`: the background limit. `MEM/hermes-hq-native.md`: "SO MUCH smoother" — a
paused Screen must not burn data or battery, and coming back must not need a tap.

**Fixture.** `CTL {"stream":{"drop":true}}` (TCP cut), `{"stream":{"stall_after":5}}` (stops mid-update after five
frames), `{"stream":{"close_code":4401}}`, `{"drop_ws":true}`. LEDGER `sockets[]` records each display socket's open
time, close code as seen by the gateway (1000, or `null` for no close frame) and frames sent.

**Acceptance.**
1. Live, press Home (`XCUIDevice.shared.press(.home)`), wait 5 s: LEDGER shows the socket ended with no close frame
   and no frames sent afterwards; the lease unchanged.
2. Reactivate the app: live again within 3 s without a tap; when it was in control it is in control again (§5.8).
3. In control, present Control Centre for under 1 s and dismiss: the socket was not closed (LEDGER still one socket).
4. `stream.drop`: one silent re-attach; `drop` again within 10 s: "Screen Stopped" + "Reconnect", which works.
5. `stall_after: 5`: within about 9 s the app opens a new socket by itself.
6. `drop_ws`: after the gateway connection is back the Screen re-attaches (new viewer id in LEDGER).
7. Simulator network off/on is not available per-app; the network-restored path is covered by a unit test of
   `ScreenSession` with a fake path monitor.

### 5.12 L516 — "Couldn’t Reach <Bot>’s Screen" with Retry

**Web.** `S/bot-screen-phone.tsx:655-685` (r2-36). Before a bot's first `display.status` answers the Screen shows
"Connecting to the screen…" with a spinner, "never the default "Bot is in control" over a black canvas and a dead Take
over". After `SCREEN_STATUS_WAIT_MS = 20 s`, or when the request failed: title "The gateway didn’t answer"; body
`<error without its trailing period>.` or "The screen’s status never arrived.", then " Check that the gateway computer
is on and reachable, then try again."; button "Retry". The app coming to the front, the network returning and the
gateway socket reopening retry by themselves.

**Native.** States S0 and S1 of §4. `ScreenSession.open()` starts the status request (20 s timeout) and a 20 s timer;
whichever ends first decides. "Try Again" (`screen.retry`) and the three resume signals of §5.11 call `open()` again
(new generation; the late answer of an older request is ignored). An "unavailable" error (`-32601`) is not a failure:
it leads to S2. A status that arrives after S1 is shown replaces it at once.

**Wire.** `display.status {"profile":"default"}`.

**States and wording.** As the web (curly apostrophes), except the title names the bot, "Couldn’t Reach <Bot>’s Screen", and the body says "the computer that runs Hermes", as Watch Browser does (UX study 2026-10-21 #141).

**Owner.** No note of its own; it is the web's fix for a silent gateway, kept so the owner never faces a dead screen.

**Fixture.** `CTL {"mode":"no-answer"}` (the status call is never answered), `{"fail":{"display.status":"Bot Desktop
state is unreadable."}}`, `{"status_delay_ms":3000}`.

**Acceptance.**
1. `no-answer`: spinner and "Connecting to the screen…" for 20 s, then the title and "The screen’s status never
   arrived. Check that the computer that runs Hermes is on and reachable, then try again."
2. `CTL {"mode":"mac"}` then "Retry": the live Screen appears.
3. `fail`: at once "Couldn’t Reach <Bot>’s Screen" with "Bot Desktop state is unreadable. Check that the computer that runs Hermes
   is on and reachable, then try again." (one period, not two).
4. `no-answer`, then background and foreground the app at second 5: a new request is made (LEDGER) and the 20 s start
   over.
5. `status_delay_ms: 3000`: no failure text at any time.

### 5.13 L517 — Mac Screen setup card

**Web.** `S/bot-screen-setup-view.tsx` (card) and `S/bot-screen-setup.ts` (flow). The card sits under the latest
screenshots view (reasons `unsupported`, `unavailable`, `blocked`) and, as "control only", on a live Mac Screen whose
input is not ready.

Card copy (exact):
* heading "Set Up Viewing and Control" — or "Enable Screen Control" when control-only;
* "Hermes will install the helper, enable viewing and control, and check both permissions in one setup. Follow its
  progress in your bot’s chat.";
* "This shares your Mac’s entire screen and enables pointer and keyboard control for people with Screen access on your
  gateway. Approve Screen Recording to view, and Accessibility to click and type, on the Mac when prompted.";
* primary button: "Set up with Hermes"; after a request "Continue with Hermes"; control-only "Enable control with
  Hermes"; while it works "Opening setup…";
* second button "Check setup"; while it works "Checking…";
* reason `unavailable` adds "Hermes will also check whether your gateway needs an update.";
* after a request: "Setup was requested in your bot’s chat. Hermes will report any permissions or requirements that
  still need attention.";
* a Windows gateway (`hostKind == windows`): only "Live screen sharing isn’t available on Windows yet. Your bot’s
  latest screenshots will appear here.", no buttons;
* the Screen re-reads its status every 5 s while the card is visible (not on Windows), so the live Screen opens by
  itself when setup finishes.

"Check setup" (`checkMacScreenSetup`, `S/bot-screen-setup.ts:142-158`) reads the health route (404 tolerated) and
`display.status` together and shows the first matching line of `macScreenReadiness` (`:116-139`):

| # | Condition | Message |
|---|---|---|
| 1 | `health.installed !== true` | The Mac screen plugin is not loaded in this gateway yet. |
| 2 | `health.platform !== "darwin"` | Live Mac screen sharing needs a Mac gateway. |
| 3 | `health.ok !== true`, or `drift` missing or non-empty | The screen plugin could not verify compatibility with this Hermes version. |
| 4 | `health.enabled !== true` | Screen sharing is not enabled on the Mac yet. |
| 5 | `health.blocker` or `status.blocker` (trimmed, non-empty) | that text |
| 6 | `status.supported !== true` | This bot does not have access to the Mac’s screen. |
| 7 | `status.installed !== true`, `missing` non-empty, or `display !== "This Mac"` | This gateway has not finished loading the Mac screen setup. |
| 8 | `health.helper` empty | The Mac screen helper has not answered yet. Open Screen to start it. |
| 9 | `helper.ok !== true` | The Mac screen helper has not reported a healthy status yet. |
| 10 | `helper.tcc.screen !== true` | Allow Screen Recording for Hermes HQ Screen on the Mac. |
| 11 | `health.control !== true` | Viewing is ready. Finish setup with Hermes to enable pointer, clicks, and typing. |
| 12 | `helper.tcc.events !== true` | Allow Accessibility for Hermes HQ Screen on the Mac to use control. |
| 13 | `helper.paused === true` | Resume sharing from Hermes HQ Screen’s menu on the Mac. |
| 14 | `helper.capture_error` non-empty | that text |
| 15 | `status.running !== true` | The Mac screen helper is ready. Open Screen to start sharing. |
| 16 | otherwise | Viewing and control are ready. Open Screen, then tap Take Control to use the pointer and keyboard. |

The request (`requestMacScreenSetup`, `:48-106`): one at a time per bot; leave the Screen; open the bot's own chat;
if the setup prompt is already queued there, or was already submitted this run and this is not a "continue", stop
("already requested"); wait up to 4 s for the chat's runtime; `file.attach {session_id, name, data_url}` with the
installer bundle; build the prompt = `MAC_SCREEN_SETUP_PROMPT` + `"\n\nInstaller source: <ref_text>\nSHA-256:
<sha256>"` + `"\nSigned helper inside the bundle: <helperAppPath>"`; queue it in that chat with the display text "Set
up live screen sharing on my Mac and verify it." (it starts when the running turn ends, or at once when idle).
Failures (exact): "This bot’s gateway is no longer connected." · "Hermes could not open this bot’s chat. Try again." ·
"The selected chat changed before setup could start." · "This bot’s chat did not become ready for setup. Try again." ·
"The chat connection changed while preparing setup. Try again." · the gateway's own message, or "Hermes could not
receive the Mac screen installer. Try again." · "The chat connection changed before setup could start. Try again." ·
"Hermes could not queue the setup request in this chat. Try again." A failure after the Screen has closed shows as an
alert titled "Couldn’t Start Screen Setup".

**Native.**

*The installer.* The exact bytes public build 240 shipped: `hermes-hq-screen-setup.zip`, 550,200 bytes, SHA-256
`71ff241d0a3e803b8a457a9df5f91c14df48c1f227893d785974837af0c8de09`, 37 entries under `hermes-hq-screen-setup/`
(`SETUP.md`, `scripts/setup-screen-helper.py`, the plugin sources, the helper sources, and the notarized
`Hermes HQ Screen.app`), helper path `hermes-hq-screen-setup/Hermes HQ Screen.app`. It sits base64-encoded in
`/Users/me/Projects/hermes-hq-native-ref240-archive/Dispatch.xcarchive/Products/Applications/App.app/public/assets/_virtual_dispatch-screen-setup-bundle-C2TxeFb_.js`
(verified while writing this spec: decoded size and hash match the file's own `sha256` field).
`scripts/fixtures/extract-screen-setup.py <that .js> App/Resources/Screen/HermesHQScreenSetup.zip` (stdlib; refuses to
write unless the hash matches) produces the resource, which is committed. `ScreenSetupBundle.load()` reads it from the
main bundle, checks the SHA-256 (CryptoKit) against the constant, and returns
`(filename: "hermes-hq-screen-setup.zip", dataURL, sha256, helperAppPath)`; a missing or altered resource throws and
the card says "Hermes could not receive the Mac screen installer. Try again." (never a silent send without it).
The app never unpacks or runs the zip; it is opaque data handed to the owner's own gateway, as the web app did.

*The prompt.* `ScreenSetupPrompt.text` is `S/bot-screen-setup.ts:18-26` (3,971 UTF-8 bytes, SHA-256
`7d777b31738f2f4db8abefd3458f2ab1624bde37311f06cabafa5668d675675a`) with **one sentence reworded** (DECISION D26).
The web's third paragraph names the pre-rename plugin and helper by their old product name. The full prompt is what
the gateway stores as the message, so it can be read in the chat when the conversation is loaded again, and the
owner's rule is that that name never appears on screen. Replace exactly

> If this Mac still has the older dispatch-screen plugin or Dispatch Screen.app from before the rename, the installer
> carries their settings over and removes them so only one helper runs (macOS keeps the existing permissions); if it
> reports it could not remove the old plugin, run hermes plugins remove dispatch-screen yourself.

with

> If this Mac still has the older screen plugin or helper app from before the rename, the installer carries their
> settings over and removes them so only one helper runs (macOS keeps the existing permissions); if it reports it
> could not remove the old plugin, run the removal command it reports yourself.

Nothing is lost: the installer itself removes the old install and, when it cannot, reports the exact command
(`…ref240/scripts/setup-screen-helper.py:559-564`, the same script that is inside the bundle). Every other byte is the
web's. The native prompt is 3,946 UTF-8 bytes, SHA-256
`dc7593732ba47693e6aa0f149ec71fde82e97a485718e559ba60ad022ec4bcb8` (computed while writing this spec); unit tests check
that hash and that the text does not contain the old name in any letter case. The queue title is "Set up live screen
sharing on my Mac and verify it.".

*The flow.* `ScreenSetup.request(bot:resume:)` in `App/Screen/AppModel+Screen.swift` +
`HermesKit/Chat/LiveChatSession+ScreenSetup.swift`:
1. One in flight per `accountId|profile`; a second tap joins the first.
2. No account or a signed-out client → "This bot’s gateway is no longer connected."
3. Dismiss the Screen viewer; select the Bots tab; `bots.open(bot.id)` (the bot's own chat; the pattern of
   `AppModel.askMainBot`, `NAT/App/Browser/AppModel+Browser.swift:70-88`); wait up to 4 s (80 × 50 ms) for a
   `ChatViewController` on top whose session is that bot's `LiveChatSession`, else "Hermes could not open this bot’s
   chat. Try again."
4. Already there? `session.queuedMessages` has a text starting with the prompt, or this bot was submitted this run
   and `resume == false` → done, "already requested".
5. `session.attachScreenSetup(name:dataURL:)`: `if runtimeSessionId == nil { try await resumeNow() }` (4 s cap, else
   "This bot’s chat did not become ready for setup. Try again."), then
   `client.call("file.attach", {session_id, profile, name, data_url}, timeout: 120 s)`; a stale runtime (code 4001)
   resumes once and attaches again (as `memoAttach`, `NAT/HermesKit/Chat/LiveChatSession+Memo.swift:143-162`).
   While this runs the chat shows the app's HUD capsule with the web's busy words, "Opening setup…"
   (`MenusHUD.show("Opening setup…", symbol: nil, in: chat.view, seconds: nil)`,
   `NAT/App/Chat/Menus/MenusSheets.swift:120-125`), taken down when the request is queued or fails.
   `attached != true` or an empty `ref_text` → the answer's `message`, or "Hermes could not receive the Mac screen
   installer. Try again."
6. The same chat must still be on top with the same runtime id, else "The chat connection changed before setup could
   start. Try again."
7. `session.send(prompt, display: "Set up live screen sharing on my Mac and verify it.")`
   (`NAT/HermesKit/Chat/LiveChatSession.swift:664-681`: queued behind a running reply, sent at once when idle, drafts
   untouched). If the message is in neither the transcript nor the queue afterwards → "Hermes could not queue the
   setup request in this chat. Try again."
8. Remember the bot as submitted for this run. Failures after step 3 show as a system alert on the chat, title
   "Couldn’t Start Screen Setup", the reason as its message, one "OK" button.

*The card.* `ScreenSetupCard` (SwiftUI in a grouped inset card, or a `ChatSheet.wrap` sheet for the control-only
entry of §5.9): heading (headline), the two paragraphs (subheadline, secondary, wrapping, 12–14 pt vertical padding),
a prominent glass primary button and a glass second button, each full width at accessibility sizes; then the optional
update line, the status message and the error (red). Buttons disable while either works. While the card is visible
(not Windows) the Screen calls `open()` every 5 s (10 s under D9's power rule); when the status turns live the
fallback is replaced by the live Screen without a tap. "Check setup" = health (404 → nil) and `display.status` in
parallel through `withChildTasks`, then `MacScreenReadiness.message(health:status:)`.

**Wire.**

```
→ file.attach {"session_id":"ab12cd34","profile":"default","name":"hermes-hq-screen-setup.zip",
               "data_url":"data:application/zip;base64,UEsDB…"}                      (≈ 734 KB frame)
← {"attached":true,"name":"hermes-hq-screen-setup.zip","path":"/…/hermes-hq-screen-setup.zip",
   "ref_path":"…","ref_text":"@file:/…/hermes-hq-screen-setup.zip","uploaded":true}
→ prompt.submit  (the chat's normal send; text = prompt + "\n\nInstaller source: @file:/…\nSHA-256: 71ff241d…\n
                  Signed helper inside the bundle: hermes-hq-screen-setup/Hermes HQ Screen.app")
```

**States.** Card idle · "Opening setup…" · requested ("Continue with Hermes" + the requested line) · "Checking…" ·
a readiness message · an error · Windows note · control-only variant.

**Owner.** `MEM/finish-everything-push.md`: "Build the helper and plugin, but don't install them." The card is how the
owner installs them: one tap, then macOS permission prompts on the Mac. `MEM/owner-runs-no-terminal.md`: "I can't do
that in terminal." Setup therefore goes through the bot's chat, never through a command the owner must type.

**Fixture.** `file.attach` with `data_url` is accepted and recorded (`attach: [{name, bytes, sha256}]`); submitted
prompts are recorded (`prompts[]`, text and display text). `CTL {"mode":"unsupported"}`,
`{"mode":"blocked"}`, `{"mode":"unavailable"}`, the `health` fields of §5.9/§5.10, `{"host":"windows"}` (session
`cwd` and screenshot paths become `C:\Users\…`), `{"fail":{"file.attach":"No space left on the gateway"}}`,
`{"finish_setup_after_ms":8000}` (the mode turns to `mac` by itself, as when the bot finishes installing).

**Acceptance.**
1. `mode: unsupported`: the card shows under the screenshots with "Set up with Hermes" and "Check setup".
2. Tap "Set up with Hermes": the Screen closes, the bot's chat opens, a bubble "Set up live screen sharing on my Mac
   and verify it." appears. LEDGER: one `file.attach` named `hermes-hq-screen-setup.zip`, 550,200 bytes, SHA-256
   `71ff241d…de09`; one prompt whose text starts with the setup prompt and ends with the three installer lines.
3. While the bot is mid-reply (`CTL {"busy":true}`): the request waits in the chat's queue and goes out after the
   reply; the composer's draft is untouched.
4. Reopen the Screen: the button reads "Continue with Hermes" and the requested line shows; tapping again does not
   attach a second copy while the first is still queued.
5. "Check setup" in each fixture state shows the matching row of the table (unit tests cover all 16; UI tests cover
   rows 1, 4, 10, 11, 12 and 16).
6. `finish_setup_after_ms`: with the card on screen, the live Screen replaces it within 5–10 s, untouched.
   (Corrected by the builder: `test14` makes the same change itself, `{"mode":"mac"}`, once the card's picture
   is taken. A timer started at the request raced the test's own steps on a loaded Mac.)
7. `host: windows`: only the Windows sentence, no buttons.
8. `fail file.attach`: an alert "Couldn’t Start Screen Setup" with "No space left on the gateway"; nothing queued.
9. `mode: mac` + `health.control: false`: the control-only card ("Enable Screen Control", "Enable control with
   Hermes").
10. Unit: the resource is present in the built app and its hash matches; the prompt hash matches (D26) and the
    prompt, the card and every failure message are free of the old product name.

### 5.14 L518 — Fallback "latest screenshots" view

**Web.** `S/bot-activity.tsx:131-155`. Shown in place of the live Screen for three reasons
(`B/bot-screen-gates.ts`): `unavailable` (older Hermes), `unsupported` (`supported == false`), `blocked`
(`!running && status.blocker`). Heading and sub-line:

| Reason | Heading | Sub-line |
|---|---|---|
| unsupported | Screen sharing isn’t set up on the computer running Hermes — or, on Windows, Live screen sharing isn’t available on the computer running Hermes | Instead, `<name>`’s latest screenshot shows here and updates while the bot works. |
| blocked | Screen sharing needs attention | `<blocker without its trailing period>`. Meanwhile, `<name>`’s latest screenshot shows here. |
| unavailable | Screen needs a newer Hermes | Update Hermes on the computer running Hermes to watch live. Meanwhile, `<name>`’s latest screenshot shows here. |

Picture area: the screenshot (alt "`<name>`’s latest screenshot", zoomable: pinch to 5×, pan, double tap 2.5× / fit,
`S/image-zoom.ts:45-107`), or one of: "Looking for screenshots…" · "No screenshots yet. When `<name>` uses its computer
or browser, the newest one appears here." · "Can’t reach the gateway to look for screenshots. Trying again…" ·
"Loading the screenshot…" · "This screenshot has expired: the gateway keeps only its 20 most recent screenshots."
Caption under it: `<caption> · <age>`, or `<working>…` in place of the caption while a tool runs
(`:144`). Age (`S/bot-activity-model.ts:68-76`): "just now" (< 10 s), "N s ago", "N min ago", "N h ago", else a short
date; it ticks every 5 s only while on screen. Then the setup card (§5.13). The gateway's kind (Mac / Windows) is
guessed from the screenshot's path or a session's folder (`hostKind`, `:81-88`).

**Native.** `LatestScreenshotsView` (a `UIScrollView` page inside the viewer, state S2): heading (title3, semibold)
and sub-line (subheadline, secondary), both wrapping; the picture in a 16:10 rounded frame that takes the
screenshot's own aspect once known, inside a zooming scroll view (max 5×; double tap toggles 2.5× about the tap and
fit) — the same zoom rules as the web lightbox; when there is no picture the frame holds the status line (with a
spinner for "Looking for screenshots…" and "Loading the screenshot…"); caption (footnote, secondary, id
`screenshots.caption`); then `ScreenSetupCard`. Model: `ScreenshotFeed` (§5.2); the age label refreshes on a 5 s timer
that runs only while visible. VoiceOver: the picture's label is "`<name>`’s latest screenshot" with the caption as its
value; a changed caption is not announced on every tick (only a new screenshot posts "New screenshot").
The top bar title is still `<Bot>’s Screen`, without a subtitle.

**Wire.** §2.5.

**States.** Three headings × six picture states × card states. Wording exactly as above.

**Owner.** `MEM/bot-screen-harness.md`: on the owner's gateway today "display.status supported:false for all 9
profiles", so this view is the owner's Screen until setup is done.

**Fixture.** `CTL {"mode":"unsupported"}`, `{"mode":"blocked"}` (blocker "Screen sharing is off on this Mac. Choose
Set up with Hermes to enable it", the plugin's own words, `P/helper.py:56`), `{"mode":"unavailable"}`,
`{"shots":{"seed":N}}`, `{"shots":{"expire":"latest"}}`, `{"host":"windows"}`.

**Acceptance.**
1. Each mode shows its heading and sub-line with the bot's name; `blocked` shows the blocker with exactly one period.
2. No sessions: "No screenshots yet. When Hermes uses its computer or browser, the newest one appears here." (fixture
   bot name).
3. Seeded: picture, caption "Looked at the screen · 12 s ago" style; the age advances while watching.
4. Pinch zooms to at most 5×; double tap zooms and fits.
5. `expire: latest`: the expired sentence instead of a broken picture.
6. Largest accessibility size: heading, sub-line, caption and card are all readable by scrolling; nothing is clipped.
7. With the view open and nothing changing for 30 s, LEDGER shows about 10 session polls and no message fetches.

### 5.15 L520 — Gateway Mac screen plugin and helper

**Web.** `P/` (the `hermes-hq-screen` gateway plugin: adapter, helper control, watch loop, health route) and `M/` (the
"Hermes HQ Screen.app" helper: ScreenCaptureKit capture, RFB 3.8 server, input injection, menu-bar Stop sharing),
described in `…ref240/docs/bot-screen-mac.md`. They run on the gateway Mac, not on the phone.

**Native.** Client side only (planner note). What HQ Native owes this row:
1. It speaks what the helper serves: RFB 3.8, security None, Tight Fill + Tight JPEG + Raw, DesktopSize /
   ExtendedDesktopSize, pull-model updates, 6-byte pointer events, Latin-1 ClientCutText (§2.3).
2. It reads the plugin's health route under both names (§5.10) and explains each state (§5.9, §5.13).
3. It carries the installer and the "Set up with Hermes" request (§5.13), so the owner can install both with one tap.
4. Without the plugin it degrades to the latest screenshots view with the setup card (§5.14) and says so in plain
   words.

Nothing is installed, deployed or changed on the owner's Mac or in any plugin repository by this stream. The exact
owner step is in `docs/owner-todo/screen.md`. The row's outcome is recorded as **client done, live proof waiting on the
owner** once the phone side is on the train and seen working against the fixture; it becomes done only after the
owner's Mac has the helper and a real frame was seen in the app.

**Wire.** §2.1–§2.4. **States.** Those of §5.9, §5.13, §5.14.

**Owner.** `MEM/finish-everything-push.md`: "Build the helper and plugin, but don't install them."
`MEM/hermes-code-not-ours.md`: "the dispatch-screen plugin patches Hermes display functions in memory at load. Flag
that dependency; don't hide it."

**Fixture.** The fixture's `mac` mode answers `display.*` and the health route with the shapes read from `P/` and
streams what `M/` streams (same encodings, same client-message framing, same refusals). It is a stand-in, not the
helper: capture quality, real input injection, macOS permission prompts and the plugin's patching of Hermes are not
exercised (risk R2).

**Acceptance.**
1. Every acceptance check of §5.5–§5.13 passes in `mode: mac`.
2. `Tests/Screen/RFBHelperConformanceTests`: byte streams built by the fixture's encoder for each thing the helper
   sends (ServerInit named "This Mac", a Tight Fill rect, a Tight JPEG rect with 1-, 2- and 3-byte compact lengths,
   a Raw rect, a resize by -308 and by -223) decode to the expected pixels.
3. LEDGER `client_messages` contains only types 0, 2, 3, 4, 5, 6, and the SetEncodings list is exactly §2.3 step 6.
4. `docs/owner-todo/screen.md` exists and states the owner's step.

---

## 6. Cross-cutting design

### 6.1 Hooks for other streams

**Screen tile (talk's row L214: "Bot Info tiles: Talk, Memo, Screen, Mute").** Web
`S/ui-bots/info-state.ts:131-136`: `{id: 'screen', label: 'Screen', symbol: screenshots ? 'photo.on.rectangle' :
'display'}`; unlike Talk and Memo it is **not** disabled offline (the Screen explains itself). Native
(`NAT/App/BotInfo/BotInfoSheet.swift:449-473`): in `BotInfoTiles`, between Memo and Mute,

```swift
if model.screenAvailable {
    tile("Screen", model.screenSymbol, id: "bot-info.tile.screen") { model.screen() }
}
```

with, in `BotInfoModel` (the pattern of `memo()`, `:200-206`):

```swift
var screenAvailable: Bool { BotMenuHooks.providers[.screen] != nil }
var screenSymbol: String { ScreenHooks.kind(bot) == .screenshots ? "photo.on.rectangle" : "display" }
func screen() {
    let bot = self.bot
    closeThen { list in
        guard let node = BotMenuHooks.item(.screen, bot, list), case .action(let run) = node.kind else { return }
        run()
    }
}
```

The strip's `.frame(maxWidth: 260)` becomes `maxWidth: 86 × tile count` so three or four tiles keep today's tile
size. Tile order is fixed (Talk, Memo, Screen, Mute), so the merge with talk's Talk tile is one line each.
`ScreenHooks` (`App/Screen/AppModel+Screen.swift`) is the stream's public seam:

```swift
@MainActor enum ScreenHooks {
    static var kind: (Bot) -> ScreenKind = { _ in .unknown }          // set by registerScreenMenu()
    static var isLive: (Bot) -> Bool = { _ in false }                  // tone == .live (the bot is in control, running)
    static var open: (Bot, UIViewController) -> Void = { _, _ in }     // AppModel.openScreen
    static var ownsComputerGroup = true                                // presence turns this off (below)
    static func row(_ bot: Bot, host: UIViewController) -> AnyView     // the Computer group's Screen row
}
```

**Screen row (presence's row L216: "Bot Info Computer group: Screen, Watch Browser, Alert When It Uses Its
Computer").** Web `S/ui-bots/info-state.ts:78, :98-102`: first row of the group, title "Latest Screenshots" / "Watch
Screen" / "View Screen" by kind, value "Live" when the tone is live, a chevron, never disabled. Native:
`ScreenHooks.row(bot, host:)` returns that row (a `Button` row with `LabeledContent`, id `bot-info.screen`, 12–14 pt
vertical padding, which closes Bot Info and opens the Screen). Until presence's group is on the train, this stream
shows the row in its own `BotInfoHooks.sections` entry, a `Section("Computer")` holding only that row, guarded by
`ScreenHooks.ownsComputerGroup`. Presence's group calls `ScreenHooks.row` as its first row and sets
`ownsComputerGroup = false`, so there is never a second "Computer" group. DECISION D13: this seam (rather than
waiting for presence) lets the row be seen working in this stream's own UI test.

**Open from elsewhere** (presence's "Watch" notices, L506; groups' room message menu "View <name>'s Screen",
`S/ui-chat/message-menu.ts:36`): `AppModel.openScreen(profile: String, name: String, from: UIViewController)`;
`ScreenHooks.open` for code that holds a `Bot`. `ScreenViewerController.current` (weak) tells presence whether a Screen
is already being watched and for which profile (`current?.profile`).

### 6.2 One place to leave

Any dismissal must run the leaving rules of §5.8: Close, a notification tap that dismisses whatever is presented
(`NAT/App/Notifications/AppModel+Notifications.swift:260`), sign-out and account switch (`ScreenService.shutdown()`,
called where `browser?.shutdown()` is, `NAT/App/AppModel.swift:330`). So `leave()` runs from
`ScreenNavigationController.viewDidDisappear` when `isBeingDismissed`, and from `shutdown()`, and is idempotent.

**No stuck buttons or keys** (DECISION D14). Before any deliberate close (pause, leave, hand back) and when control is
lost, the session sends button-up for a held pointer button and key-up for any key or modifier it holds down, and
waits for that send to complete (at most 250 ms) before cancelling the socket. After an attach that ends in control
(reclaim, Resume Control), the first input message is `PointerEvent(mask: 0)` at the pointer, which clears a button
that a dropped link left down.

### 6.3 Accessibility and text sizes

* **Stage.** Watching: one element, trait image, label "`<Bot>`’s screen", value `screenLabel` ("This Mac ·
  1920×1080"), custom actions "Zoom in", "Zoom out", "Fit screen". In control: trait `.allowsDirectInteraction` (the
  trackpad works under VoiceOver) plus custom actions "Click", "Right-click", "Scroll up", "Scroll down" acting at the
  pointer, so control does not depend on timed gestures (DECISION D15).
* **Bar.** Every button has a spoken name (§5.5, §5.6); armed modifiers carry `.selected`; the caption is a static
  text that posts an announcement when control changes ("You are in control", "<Bot> is in control", "Another viewer
  took control. Watching only.").
* **Dynamic Type.** Text in states S0–S4 and S7, the notes, the fallback view and the setup card scales without a cap
  and scrolls. The control row stacks (caption above the buttons, buttons full width) at accessibility sizes. The key
  row is capped at `.accessibilityMedium` (`maximumContentSizeCategory`) and adopts
  `UILargeContentViewerInteraction`, the system pattern for bars. The stage keeps at least 120 pt of height in
  portrait at every size; the notes scroll rather than squeeze it (§5.9).
* **Reduce Motion**: no zoom animation, no pointer-ring fade, pills cross-fade. **Reduce Transparency / Increase
  Contrast**: system glass handles both; no custom blur anywhere.
* **Touch targets** ≥ 44 pt for every bar button, including the six special keys (spacing 6 pt).
* **Colour** is never the only signal: warnings carry a symbol, "You were in control" is a labelled badge.

### 6.4 Glass, motion, haptics

Native Liquid Glass only (`docs/spec/06-native-feel-and-design.md` §8): the top bar is the system navigation bar; bar
buttons are `UIButton.Configuration.glass()` / `.prominentGlass()` as in
`NAT/App/Browser/BrowserViewerController.swift:537-585`; pills are `UIVisualEffectView(effect: UIGlassEffect(style:
.regular))` capsules (the `BrowserPill` pattern, `:770`); the setup card is a grouped inset card; sheets are system
sheets. No painted "glass", no gradient strip behind the bar. Pills float above the control bar, never under the top
bar (`MEM/ui-hunt-oct6.md`). Haptics: selection tick when a hold arms, light impact on Take Control, warning on eviction;
nothing on ordinary taps (DECISION D16).

### 6.5 Privacy

Nothing from the remote screen is stored: frames live in memory only, no screenshot of the stream is written, no
keysym, pasted text, ticket, viewer id or path is logged. The viewer id saved for a held lease is an opaque handle.
The app-switcher snapshot shows the viewer with the picture hidden: on `willResignActive` the stage layer is covered
by the black stage background (DECISION D17: another computer's screen should not sit in the iOS app switcher).
Pasteboard is read only when the person taps Paste. `App/Resources/PrivacyInfo.xcprivacy` needs no change
(UserDefaults is already declared; no new required-reason API).

### 6.6 Old names in text the gateway sends

The Screen shows some text the gateway wrote: `blocker`, `capture_error`, and the messages of failed `display.*`
calls. A Mac that still runs the pre-rename plugin words these with the old product name. DECISION D27: every such
string passes through `ScreenWire.plain(_:)` before it is shown or spoken, which replaces the old helper name with
"Hermes HQ Screen" and the old plugin id with "hermes-hq-screen" (case-insensitive) and trims it. The web showed the
text as sent; the owner's rule that the old name never appears on screen wins. Fixture:
`CTL {"mode":"blocked","blocker":"Allow Screen Recording for Dispatch Screen on the Mac"}` must read "Allow Screen
Recording for Hermes HQ Screen on the Mac" in the heading's sub-line and in "Check setup".

---

## 7. The stand-in gateway

### 7.1 `scripts/fixtures/screen-gateway.py` (new)

Python stdlib only, loopback only, every value invented, nothing forwarded. Built like
`scripts/fixtures/browser-gateway.py:22-26`: it loads
`/Users/me/Projects/hermes-hq-native-ref238/scripts/performance-fixture-gateway.py` with `importlib` for
sign-in, roster, sessions, messages and `/api/ws`, and adds or overrides the routes below. Docstring at the top lists
every route and control key, as the other fixtures do.

```
python3 scripts/fixtures/screen-gateway.py --port <port> --credentials <json out> --frames <dir>
        [--emit-vectors Tests/Fixtures/screen]      # write decoder test vectors and exit
```

It refuses a port outside 9940–9949 unless `--any-port` is given, and never binds anything but 127.0.0.1.

| Port | Use | Start command |
|---|---|---|
| 9940 | builders' UI tests (`scripts/e2e-screen.sh`, `HQN_SCREEN_PORT`) | `python3 scripts/fixtures/screen-gateway.py --port 9940 --credentials build/fixtures/e2e-screen.json --frames build/fixtures/screen-frames` |
| 9941 | builders' live-wire unit tests (`ScreenLiveWireTests`, skipped unless `TEST_RUNNER_HQN_SCREEN_FIXTURE` is set) | same with `--port 9941 --credentials build/fixtures/wire-screen.json` |
| 9942 | builders' manual runs in the simulator | same with `--port 9942 --credentials build/fixtures/manual-screen.json` |
| 9943–9944 | spare | |
| 9945 | stress: main | `python3 scripts/fixtures/screen-gateway.py --port 9945 --credentials build/fixtures/stress-screen.json --frames build/fixtures/screen-frames` |
| 9946 | stress: bad network and bad data | same with `--port 9946 --credentials build/fixtures/stress-screen-net.json` |
| 9947 | stress: soak | same with `--port 9947 --credentials build/fixtures/stress-screen-soak.json` |
| 9948–9949 | spare | |

Before starting, check the port is free (`lsof -nP -iTCP:<port> -sTCP:LISTEN`); never connect to a port this stream
did not start. Stop the fixture (kill the pid you started) when the stage ends.

**JSON-RPC on `/api/ws`** (strict: a key outside the set → error 4000 `unknown params`, recorded in
`unknown_params`):

| Method | Allowed keys | Behaviour |
|---|---|---|
| `display.status` | `profile` | DisplayStatus for the mode; honours `status_delay_ms`, `mode: no-answer` (never answers), `fail` |
| `display.start` | `profile` | `off` → running; `not-installed` → 5300 "Bot Desktop packages are missing" |
| `display.observe` | `profile`, `viewer_id` | mints `viewer_id` (kept only when it was minted on **this** connection), a single-use ticket (`tickets.ttl_s`, default 30), `path: "/api/display/ws"`; 5300 when not running |
| `display.lease.acquire` | `profile`, `viewer_id` | 5300 without an id or with one from another connection; else human lease, epoch + 1; evicts a previous human holder's stream with close 4000 `control-taken` |
| `display.lease.release` | `profile`, `viewer_id`, `force` | Hermes' rules: by id (own connection); by id + `force` (any connection, only while that id holds); bare + `force`; bare without force while a human holds → 5300 `viewer_mismatch` |
| `display.stop`, `display.thumbnail`, `display.install`, `display.switchSandboxImage` | — | answered, and counted in `forbidden_calls` (must stay 0) |
| `file.attach` | `session_id`, `profile`, `name`, `path`, `data_url` | records `{name, bytes, sha256}`; answers `{attached: true, ref_text: "@file:/tmp/fixture/<name>", …}` |

Events it pushes: `display.status` and `display.lease` on every change; `tool.start` / `tool.complete` for `shots.live`.
`mode: unavailable` answers every `display.*` with `-32601 Method not found`.

**`/api/display/ws`**: checks `display_ticket` (missing, used or expired → close 4401; any other query item → 4403),
4001 when the mode is not running; then speaks RFB 3.8 as a server: version, security `[1]`, SecurityResult 0,
ServerInit (name = the mode's display), then frames **only in answer to a FramebufferUpdateRequest** (pull model),
with the encoding of `stream.encoding` restricted to what the client's SetEncodings listed. Client bytes are parsed
with the gateway's own framing (`RfbClientFilter`): an unknown type closes 1003; types 4, 5, 6 from a viewer that
does not hold the lease are dropped and counted. A text frame closes 1003. A close 1000/1001 from the client hands a
held lease back; any other end keeps it. It draws a pointer (white arrow, Tight Fill rects) where PointerEvents say and
a marker per click (red left, purple right, blue wheel tick), and types received keys into a text band, so a person
watching can see input land.

**REST added:** `GET /api/plugins/hermes-hq-screen/health`, `GET /api/plugins/dispatch-screen/health` (per
`health.plugin`), `GET /api/fs/list`, `GET /api/fs/download`, and screenshot rows mixed into the base fixture's
`/api/profiles/sessions` and `/api/sessions/<id>/messages`.

**Control** `POST /__fixture/screen` (any subset; unknown key → 400 with the list of known keys):

| Key | Values | Effect |
|---|---|---|
| `mode` | `mac` (default: "This Mac", 1280×800, Tight JPEG + Fill + Raw) · `linux` (":7", 1280×800, Tight Basic + CopyRect + Raw) · `off` · `not-installed` · `unsupported` · `unavailable` · `blocked` · `no-answer` | the status every bot reports |
| `status_delay_ms`, `rpc_delay_ms` | ms | slow answers (status only / every RPC) |
| `fail` | `{method: message}` (null clears) | that method answers 5300 with the message |
| `blocker` | text | the `blocker` of `mode: blocked` (default: the plugin's "Screen sharing is off on this Mac. Choose Set up with Hermes to enable it") |
| `health` | `{plugin: new / legacy / none, ok, platform, drift, enabled, control, blocker, helper: true / false, helper_ok, tcc_screen, tcc_events, locked, secure_input, paused, capture_error, status: 200 / 500, delay_ms}` | the health route's answer |
| `health_now` | true | push a `display.status` event (the app re-reads health) |
| `stream` | `{encoding: tight-jpeg / tight-basic / raw / copyrect / mixed, fps, size: [w, h], chunk: 1…65536, delay_ms, throttle_kbps, stall_after: n, drop: true, drop_after_ms, close_code, rects_per_update, garbage: <name>}` | how frames are sent; `size` resizes mid-stream (-308 then -223 on the next attach; a size with no prepared frames is filled with generated colour bands as Tight Fill and Raw); `garbage` names a bad-data case (§9.4) |
| `tickets` | `{ttl_s, reject: true}` | ticket lifetime; `reject` closes 4401 |
| `other_takes` | true or a count, with `every_ms` | another person acquires (evicting the phone when it held) |
| `agent_takes` | true | the lease returns to the agent (as when the bot's tool takes it) |
| `drop_ws` | true | closes the app's `/api/ws` connections |
| `shots` | `{seed: n, chat: true, live: {tool, action, app}, stored: n, expire: [names] or "latest", listing: "fail" / "empty" / "ok", sessions: n, messages: n}` | screenshots in stored sessions, live tool events, expiry |
| `host` | `mac` · `windows` · `linux` | session `cwd` and screenshot paths (`/Users/…`, `C:\Users\…`, `/home/…`) |
| `busy` | true/false | the bot is mid-reply (sends queue) |
| `finish_setup_after_ms` | ms | the mode becomes `mac` after the next setup prompt, as when the bot finishes installing |

`GET /__fixture/screen` (LEDGER): `mode`, `lease`, `lease_log[]`, `status_calls`, `observes[]`, `unknown_params[]`,
`forbidden_calls`, `sockets[]` (`opened_at`, `closed_at`, `close_code` or null, `frames_sent`, `bytes_sent`),
`open_sockets`, `max_open_sockets`, `max_outstanding_requests`, `client_messages` (count per type), `set_encodings`,
`pixel_format`, `inputs[]` (`t`, `kind`, `keysym`/`down` or `mask`/`x`/`y` or `length`/`text`), `dropped_inputs`,
`health_hits`, `fs_list_hits`, `sessions_polls`, `messages_fetches`, `attach[]`, `prompts[]`, `viewers`.
`POST /__fixture/screen/reset` restores defaults and clears the ledger. `GET /__fixture/screen/expect` returns the
fixture's own framebuffer at five sample points ((¼,¼), (¾,¼), (½,½), (¼,¾), (¾,¾)) as hex BGR, exact for the
lossless encodings.

The app side of that check is DEBUG-only, as Watch Browser's pacing value is: `stage.accessibilityValue =
"frames=<n> rects=<n> size=<w>x<h> mainDecodes=0 p50=<ms> p95=<ms> serial=<n> probe=<hex of the same five points>"`.
Release builds set no such value.

### 7.2 `scripts/fixtures/make-screen-frames.swift` (new)

Like `make-browser-frames.swift`: draws 30 frames of a made-up desktop (menu bar, two windows, a counter band that
changes every frame, a coordinate grid, text) at 1280×800 and 1920×1080 with CoreGraphics and writes, per size:
`frame-NN.bgrx` (raw pixels, for Raw / Tight Basic / CopyRect), and for Tight JPEG the changed 64-px-aligned tiles of
each frame as `frame-NN/tile-<x>-<y>-<w>x<h>.jpg` (quality 86) plus `manifest.json` (rects per frame). Python has no
JPEG encoder in its standard library, which is why tiles are made here. Output goes to
`build/fixtures/screen-frames` (not committed).

### 7.3 `scripts/fixtures/extract-screen-setup.py` (new)

`python3 scripts/fixtures/extract-screen-setup.py <bundle .js> App/Resources/Screen/HermesHQScreenSetup.zip`: finds
``filename:`…`,dataUrl:`data:application/zip;base64,…`,sha256:`…` `` in the web build's bundle module, decodes it in
memory, refuses to write unless size is 550,200 and SHA-256 is `71ff241d…de09`, never unpacks it. Run once; the zip is
committed.

### 7.4 `scripts/e2e-screen.sh` (new)

A copy of `scripts/e2e-browser.sh` for this fixture with one difference: the simulator UDID is **required**
(`SIM=${1:?pass your simulator UDID}`), so the shared default simulator can never be used.

```
UDID=$(xcrun simctl list devices | awk -F '[()]' '/HQN-m9-screen \(/{print $2; exit}')
scripts/e2e-screen.sh "$UDID"                               # all ScreenEndToEndTests on port 9940
HQN_SCREEN_ONLY="test04_takeOverPointerClicks" scripts/e2e-screen.sh "$UDID"
```

Environment it passes: `TEST_RUNNER_HQN_UI_CREDENTIALS=$PWD/build/fixtures/e2e-screen.json`,
`TEST_RUNNER_HQN_UI_SCREEN=1`; derived data `${HQN_DD:-build/dd}` (inside the worktree); summary through
`scripts/e2e-summary.py`. Tests steer the fixture with `FixtureAccount.control("/__fixture/screen", …)`
(`NAT/UITests/EndToEndTests.swift:9-31`).

---

## 8. Tests

### 8.1 Unit tests (`Tests/Screen/`, run with `scripts/build.sh test <UDID>`)

| File | Covers | Web tests ported |
|---|---|---|
| `ScreenWireTests` | `plain(_:)` (D27); status and lease parsing (missing fields, wrong types), exact param key sets of the five calls, `isUnavailable`, `viewerHash` (known vector), socket URL (wss for https, path prefix kept, only `display_ticket`), a `path` other than `/api/display/ws` refused | `V/screen-state` rules |
| `ScreenToneTests` | tone, kind, remembered kind, `screenLabel` | `S/bot-screen-labels.test.ts`, `S/bot-screen-menu.test.ts` |
| `RFBParserTests` | handshake 3.8 / 3.7 / 3.3, security failure with reason, ServerInit, colour map / bell / cut text skipped, unknown type → error, **feeding one byte at a time gives the same result as one buffer**, limits | — |
| `RFBDecoderTests` | Raw; CopyRect with overlap; Tight Fill; Tight JPEG with 1-, 2-, 3-byte lengths; Tight Basic: copy filter (< 12 bytes raw and zlib), palette with 2 colours (1 bit per pixel, rows padded) and with up to 256, gradient, stream reset bits, zlib state carried across rects; DesktopSize; ExtendedDesktopSize; LastRect | vectors from `--emit-vectors` |
| `RFBBadDataTests` | every case of §9.4: no crash, bounded memory, a typed error | — |
| `RFBHelperConformanceTests` | §5.15 acceptance 2 | `M/…/Tests/ScreenCoreTests/RFBTests.swift` shapes |
| `ScreenStreamTests` | pull model (one request outstanding; the next only after the frame reached main), `mainThreadDecodes == 0`, stuck rule (D12) with an injected clock | `S/bot-screen-flush.test.ts` |
| `ScreenSessionTests` | S0–S7 with a fake `GatewayClient` and fake socket: 20 s timeout, generation tokens, epoch ordering, reclaim, eviction loop, pause without a close frame, close 1000 on leave, re-attach on `.ready`, single automatic retry, 4401 re-observe once, 4001 → status, Close during every await | `S/bot-screen-phone.test.ts` |
| `ScreenHoldsTests` | `shouldReclaim`, `heldBefore`, 24 h, malformed store, leave cases | `S/bot-screen-phone.test.ts` |
| `ScreenKeysTests` | keysyms, chord order, text under modifiers, Latin-1 rule, 256 KiB limit, IME commit, paced typing cancel | `S/bot-screen-phone.test.ts` |
| `ScreenViewMathTests`, `ScreenGestureTests` | every function of §5.5 and §5.7; tap / hold / drag / wheel / pinch / cancel sequences as point streams; D14 releases | `S/bot-screen-phone.test.ts` |
| `MacScreenTests`, `MacScreenReadinessTests` | parse, route memory, 404s; all 16 readiness rows in order | `S/bot-screen-setup.test.ts` |
| `ScreenshotFeedTests` | `latestShot`, `liveShot`, captions, ages, host kind, poll marks, two-failure rule | `S/bot-activity-model.test.ts` |
| `ToolScreenshotsTests` | the three parsers; expiry rules and caps with an injected clock | `S/tool-screenshots.test.ts`, `S/image-zoom.test.ts` |
| `ScreenSetupTests` | prompt hash and old-name check (D26), bundle present + hash, request text, each failure message with a fake session, de-duplication, "already requested" | `S/bot-screen-setup.test.ts`, `S/bot-screen-setup-view.test.ts` |
| `ScreenLiveWireTests` (optional, port 9941) | the real `ScreenStream` against the fixture over loopback: all encodings, `probe` equals `expect`, strict params (`unknown_params == []`), `forbidden_calls == 0` | — |

### 8.2 UI tests (`UITests/screen/ScreenEndToEndTests.swift`, `scripts/e2e-screen.sh`)

| Test | Rows |
|---|---|
| `test01_menuLabelFollowsStatus` | L166, L508 |
| `test02_noAnswerThenRetry` | L516 |
| `test03_liveWatchZoomPanDoubleTap` | L509 |
| `test04_takeOverPointerClicks` (swipe, tap, hold = right click, hold-move = drag, hand back) | L509 |
| `test05_keyboardKeysAndModifiers` | L510 |
| `test06_pasteClipboardAndTyped` | L510 |
| `test07_rotateHintLandscapeCompactTyping` | L511 |
| `test08_controlSurvivesSocketSwap` | L512 |
| `test09_relaunchHeldResumeAndHandBack` | L512 |
| `test10_otherViewerForceHandBackAndEviction` | L512 |
| `test11_notes` | L513 |
| `test12_healthPollAndLegacyRoute` | L514 |
| `test13_pauseInBackgroundAndResume` | L515 |
| `test14_setupCardRequestCheckAndAutoOpen` | L517 |
| `test15_latestScreenshotsLiveStoredExpired` | L212, L518 |
| `test16_toolScreenshotInStepSheet` | L345 |
| `test17_linuxEncodingsPixelExact` | L509, L520 |
| `test18_botInfoTileAndComputerRow` | hooks (§6.1) |
| `test19_screenOffStartAndPackagesMissing` | states S3, S4 |
| `test20_largestTextSize` (launch argument `-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityXXXL`) | all |

Limits of the tools, stated so nobody fakes a pass: XCUITest has `pinch` but **no two-finger drag**, so the remote
scroll is proven by `ScreenGestureTests` plus one manual run with the simulator tool's two-finger path, recorded in
the builder's report with the LEDGER's wheel count. The simulator cannot switch Low Power Mode, thermal state or
per-app network; those paths have unit tests with injected signals. iOS may show its own "Allow Paste" alert when
`test06` taps Paste; the test accepts it through SpringBoard's alert. A UI test that fails is rerun once before it is
called a failure (shared Mac), and an assertion is never loosened to make it pass.

Both identities build: `scripts/build.sh build <UDID>` and `HQ_IDENTITY=original scripts/build.sh build <UDID>`.

---

## 9. STRESS PLAN

For the stress tester. Simulator `HQN-m9-screen-s` (create when missing:
`xcrun simctl create "HQN-m9-screen-s" "iPhone 17 Pro" com.apple.CoreSimulator.SimRuntime.iOS-27-0`); ports
9945–9949 only; fixture commands in §7.1. Bad network is simulated **inside the fixture** (`stream.chunk`,
`delay_ms`, `throttle_kbps`, `drop`, `rpc_delay_ms`); never use Network Link Conditioner, `pfctl` or `dnctl` (they
change the whole shared Mac). Each item: do it, read the LEDGER, record the numbers. A finding is a bug only after a
rerun shows it again.

### 9.1 Load

| # | Do | Pass |
|---|---|---|
| L1 | Soak: `stream {encoding: tight-jpeg, fps: 30, size: [1920,1080]}`, watch 30 min, in control for the last 10 with a slow continuous swipe | frames keep rising; `mainDecodes=0`; `max_outstanding_requests == 1`; the app process's memory after minute 1 grows < 30 MB by minute 30; no hang > 250 ms (Close answers at once at the end) |
| L2 | Sizes: 640×480, 1280×800, 1920×1080, 3840×2160, 5120×2880 (59 MB, allowed), then 6016×3384 and 8192×8192 (over 64 MB, refused) | allowed sizes show and zoom; refused sizes end in "Screen Stopped" with no crash and no memory spike over 150 MB |
| L3 | `rects_per_update: 2000` (64×64 tiles) at 30 fps for 2 min | p95 hand-off < 50 ms; bar buttons answer within 300 ms |
| L4 | In control: 60 s of continuous dragging while pasting 5,000 typed characters (`mode: linux`) | LEDGER has all 10,000 key events in order; pointer events ≤ 120 per second; app stays responsive; handing back mid-paste stops the rest within one slice |
| L5 | `shots {sessions: 50, messages: 2000, seed: 300, chat: true}`; open the fallback for 10 min, then scroll the chat and open 30 screenshot steps | one sessions request per 3 s, no message fetch while nothing changes; memory flat; `fs_list_hits` ≤ 1 per folder per 60 s; the transcript cache on disk holds no `data:` image |
| L6 | Open and close the Screen 100 times (every third time take over first) | `open_sockets == 0`, `viewers == 0`; lease with the agent; memory within 10 MB of the start |
| L7 | Mid-stream resize 20 times between 1280×800 and 1920×1080 | picture follows each time; pointer stays inside the desktop; no stale-size frame drawn |

### 9.2 Speed

| # | Measure | Budget (simulator, loopback) |
|---|---|---|
| S1 | tap on the menu item → first picture (`frames ≥ 1`) | ≤ 1.5 s |
| S2 | Take Control tap → "You are in control" | ≤ 300 ms |
| S3 | finger move → pointer ring moves | same display frame |
| S4 | finger move → PointerEvent at the fixture (`inputs[].t`) | ≤ 50 ms median |
| S5 | fixture at 30 fps, 1280×800 Tight JPEG | ≥ 25 frames per second shown (frames delta over 10 s ≥ 250) |
| S6 | fixture at 60 fps | no backlog: `serial` lags the fixture's by ≤ 2; `max_outstanding_requests == 1` |
| S7 | decode p95 of a full 1280×800 JPEG frame | < 12 ms, off the main thread |
| S8 | app launch with this code present | zero `display.*` calls and zero plugin requests before a Screen is opened (LEDGER); launch time within noise of the train |
| S9 | Bots list scrolling with remembered kinds for 200 bots | no hitch attributable to the menu provider (it is a dictionary read) |
| S10 | Close while live and in control | the viewer is gone in one animation; the release needs no wait |

### 9.3 Bad network (port 9946)

| # | Do | Pass |
|---|---|---|
| N1 | `stream {chunk: 1}` (one byte per WebSocket frame), then `chunk: 7`, then `chunk: 65536` | identical picture each time (`probe` equals `expect` in `mode: linux`) |
| N2 | `stream {throttle_kbps: 64, delay_ms: 300}` | first picture arrives (slowly) with "Connecting to the screen…" meanwhile; **no** stuck-stream restart while bytes keep coming (D12); Close is instant |
| N3 | `stream {stall_after: 5}` | a new socket by itself within about 9 s; a second stall within 10 s → "Screen Stopped" + "Reconnect" |
| N4 | `stream {drop: true}` once; then twice within 10 s | one silent re-attach; then the error state; "Reconnect" works |
| N5 | `drop_ws` every 5 s for 2 min while in control | after each reconnect: one observe, at most one acquire, control kept; `max_open_sockets == 1`; never a release of someone else's lease |
| N6 | `tickets {ttl_s: 0}` and `tickets {reject: true}` | one re-observe, then the error state; ≤ 2 observes per attempt (no loop) |
| N7 | `rpc_delay_ms: 16000` (observe times out at 15 s); `fail {"display.observe": "…"}` | error state with the reason in the error line; no socket dialled |
| N8 | `health {status: 500}`, `health {delay_ms: 30000}` | notes keep the last value; never more than one health request in flight |
| N9 | fixture stopped before opening the Screen; started again after 30 s | "Couldn’t Reach <Bot>’s Screen" at 20 s or sooner; "Retry" (or foregrounding) recovers |
| N10 | fallback view with every REST answer delayed 5 s, then failing | one poll at a time; "Can’t reach the gateway…" after two failures; recovers alone |
| N11 | setup request with `rpc_delay_ms: 8000` | the HUD "Opening setup…" stays up; one attach; the request is queued once |
| N12 | fixture killed while in control, restarted (all gateway state lost) | S1 or "Screen Stopped", then recovery; no badge for a hold the gateway no longer has |

### 9.4 Bad data (port 9946, `stream {garbage: <name>}`; each also a unit test in `RFBBadDataTests`)

`bad-version` ("HTTP/1.1 400…" instead of `RFB 003.008\n`) · `security-none-missing` (only type 2 offered) ·
`security-failed` (result 1 + reason) · `zero-size` (0×0) · `huge-size` (65535×65535) · `rect-outside` ·
`unknown-encoding` (16 ZRLE, never requested) · `unknown-message` (type 9) · `tight-length-overflow` (compact length
of 4 GiB) · `zlib-garbage` · `zlib-truncated` · `jpeg-garbage` ×1 and ×3 · `palette-zero` (0 colours) ·
`copyrect-outside` · `cut-text-huge` (ServerCutText of 512 MiB declared) · `colour-map-huge` · `text-frame` ·
`trailing-bytes` after a valid update · `never-ending-update` (65,535 rects of 1×1).

Pass for all: no crash, no hang, memory bounded (< 100 MB over baseline), the viewer ends in "Screen Stopped"
with "Reconnect" (or keeps streaming for the recoverable ones: single `jpeg-garbage`, `trailing-bytes`,
`never-ending-update`), and one content-free log line names the case.

Status and REST shapes: `display.status` answering `null`, `[]`, a string, `{"lease": "x"}`, `{"geometry": 7}`,
`{"supported": "yes"}`; a lease with a negative epoch; `display.observe` without `ticket`, with `path: "/api/ws"`,
with `path: "//evil.example/api/display/ws"` (must be refused without dialling); health answering HTML, `{}`,
`{"helper": 5}`; sessions with `last_active` as a string; messages whose `content` is a 5 MB string, a number, or JSON
with a 2 MB `data:` URL; a screenshot path with `..`, a 4,000-character path, an empty path; `/api/fs/list` answering
`{"entries": "x"}`; a `tool.complete` with `result` 3 MB of base64 that is not an image; `file.attach` answering
`{"attached": true}` without `ref_text`. Pass: the matching plain state of §5 (never a blank screen, never a crash),
and a path that is not exactly `/api/display/ws` is never dialled.

### 9.5 Interruption

| # | Do | Pass |
|---|---|---|
| I1 | Home, app switcher, and lock during each of: S0, attaching, live watching, in control, mid-drag, keyboard up, setup attach in flight | per §5.11: socket ended without a close frame, lease kept, no input after; mid-drag: a button-up was sent first (D14); back in front it resumes without a tap |
| I2 | Control Centre or Notification Centre for < 1 s, then for 5 s | no pause the first time (`sockets` count unchanged); pause and resume the second |
| I3 | Rotate during a pinch, during a drag, with the keyboard up, in compact typing, in the fallback view | no crash; view re-clamped; pointer unchanged; Close returns the app to portrait every time |
| I4 | Close during every await: status, observe, dial, handshake, first frame, acquire, release, start, health, setup attach | the viewer is gone at once; no late alert or pill on another screen; `open_sockets == 0`; an acquire that lands after Close is followed by a forced release |
| I5 | A notification tap (push fixture not needed: `xcrun simctl push` with the app's own payload) or a Home Screen quick action while the Screen is open and in control | the Screen is dismissed and its leaving rules ran (lease back with the agent) |
| I6 | Sign out and switch gateway while the Screen is open | viewer closes, `ScreenService` shut down, no socket left; the other account's remembered kind is its own |
| I7 | Hardware keyboard connected in the simulator: type, arrows, ⌃C, ⌘V, Esc | key events as §5.6; the on-screen keyboard button still toggles; no doubled characters |
| I8 | A phone call banner / Siri over the viewer (simulator: trigger Siri) | as I2 |
| I9 | `other_takes` and `agent_takes` fired at random every 1–3 s for 2 min while tapping Take Control | no crash, no stuck spinner on a button; the caption always matches LEDGER `lease` within 1 s; eviction loop guard shows after the fourth in 10 s |
| I10 | Memory warning (unit test calls the handler; the paused picture is dropped) | no crash; resumes with a fresh frame |

### 9.6 Relaunch

| # | Do | Pass |
|---|---|---|
| R1 | Terminate while in control; relaunch; open the Screen | "You were in control" badge, the note, "Resume Control" and "Give Back" both work (two runs) |
| R2 | Terminate while watching; relaunch | the Screen is not reopened by itself; the lease is still the agent's; no badge |
| R3 | Terminate while the setup attach is in flight; relaunch | nothing half-queued; the card offers "Set up with Hermes"; a second request works |
| R4 | Terminate with the setup request queued behind a busy reply; relaunch | the chat's queue still holds it once; the card reads "Continue with Hermes"; no second attach |
| R5 | 20 launches in a row after kinds were remembered | labels stable from the first frame; `hq.screen.*` keys stay at one per account or bot |
| R6 | Corrupt the stores on the tester's own simulator (`xcrun simctl spawn <udid> defaults write <bundle id> hq.screen.held.<account>.default garbage`) | ignored and overwritten; no crash; no badge |
| R7 | Shut down and boot `HQN-m9-screen-s` with a hold saved | as R1 |
| R8 | Install the train's previous build, sign in, then install this build over it | no migration needed; first open reads "View Screen" |
| R9 | A hold saved 25 h ago (launch argument `-HQScreenHoldAge 90000`, DEBUG only) | no badge; the stale record is removed |

### 9.7 Accessibility sizes

Run `test20_largestTextSize` and then by hand at Dynamic Type xSmall, Large (default), xxxLarge and AX5, in portrait
and landscape, with Bold Text and with Button Shapes:

* every string of S0–S4, S7, the notes, the fallback headings, the caption and the setup card is readable in full
  (scrolling allowed, truncation not);
* the control row's buttons never overlap or leave the screen; at accessibility sizes they stack;
* the key row keeps 44 pt targets and shows the large-content viewer on a long press;
* the stage keeps ≥ 120 pt in portrait, including with six notes and the keyboard up;
* VoiceOver: every control is reachable in a sensible order (Close, title, notes, stage, caption, buttons, keys);
  state changes are announced once; in control, the trackpad works with direct interaction and the four custom
  actions click and scroll; the latest screenshot is described by its caption;
* Reduce Motion, Increase Contrast, Reduce Transparency, Smart Invert and Dark / Light: nothing unreadable, no
  custom-drawn glass, the picture itself is never inverted (`accessibilityIgnoresInvertColors = true` on the stage
  and on screenshots);
* Voice Control: "Tap Take Control", "Tap Paste", "Tap Escape" work (names match labels);
* Switch Control and Full Keyboard Access can reach Close, Take Control, Give Back and Retry.

---

## 10. DECISIONS

| # | Decision | Why |
|---|---|---|
| D1 | Own storage keys in UserDefaults; the web app's are not read (§3.3) | they lived in the WebView; a viewer id is a handle, not a credential |
| D2 | Close (✕) in the top bar, not "Done" (§4) | matches the native Watch Browser viewer |
| D3 | No "Install on host", no sandbox image switch card (§4) | desktop Linux-host flows no assigned row names; nothing dead on screen |
| D4 | Never ask for the Cursor pseudo-encoding (§2.3, §5.5) | both backends then paint the pointer into the picture; no cursor-shape code |
| D5 | L166 and L508 are one native menu entry with the phone list's wording (§5.4) | HQ Native has one bot menu |
| D6 | A local pointer ring while a finger is down in control mode (§5.5) | instant feedback when the picture is a frame behind; may be dropped in review |
| D7 | The gesture line is a pill shown 8 s when control starts, not a permanent line (§5.5) | keeps the picture's height in landscape; same pattern as Watch Browser |
| D8 | Only the Screen viewer rotates, through the app delegate's orientation mask (§5.7) | the app is portrait; a desktop needs landscape |
| D9 | Polls double their interval in Low Power Mode or under thermal pressure (§5.2, §5.10, §5.13) | the web's power-aware interval |
| D10 | A tool screenshot shows in the step's sheet, not inline in the transcript (§5.3) | steps are the native home of tool cards |
| D11 | One automatic re-attach 1 s after an unexpected stream end (§5.11) | spares a tap on a blip; a second failure shows "Reconnect" |
| D12 | "Stuck" means no bytes for 8 s mid-update, or a decode over 8 s (§5.11) | a slow but moving link must not be restarted in a loop |
| D13 | The Computer-group seam `ScreenHooks.ownsComputerGroup` (§6.1) | the Screen row is seen working before presence lands |
| D14 | Buttons and keys are released before any deliberate close and after a reclaim (§6.2) | a remote button must never stay held down |
| D15 | VoiceOver: direct interaction plus Click / Right-click / Scroll custom actions (§6.3) | control without timed gestures |
| D16 | Haptics on hold-armed, take over, eviction only (§6.4) | signals a person cannot see under the finger; no buzz on every tap |
| D17 | The picture is hidden in the app-switcher snapshot (§6.5) | another computer's screen is private |
| D18 | Paste reads `UIPasteboard.general` on tap; typed paste goes out 500 characters per turn of the run loop and stops on hand-back (§5.6) | Watch Browser's pattern; never stalls the app on a long paste |
| D19 | The installer ships as an opaque, hash-checked resource with the same bytes as public build 240 (§5.13) | the owner-approved setup, unchanged; the phone never unpacks or runs it |
| D20 | The setup request is attached with `file.attach {data_url}` and sent with the chat's own queue; "Opening setup…" shows as the HUD while it uploads (§5.13) | same wire as the web; a slow link is not silent |
| D21 | The control-only setup card opens as a sheet from an "Enable Screen Control" row (§5.9) | the card would cover the picture on a phone |
| D22 | A WebSocket ping every 20 s while live; the idle timer is off while a live picture is on view (§5.11) | a dead link is noticed on an idle desktop; the phone does not sleep mid-watch |
| D23 | Limits: framebuffer ≤ 8192 a side and ≤ 64 MB, Tight length ≤ 4 MiB, 3 bad JPEGs end the stream (§2.3) | bad data cannot exhaust memory; the Mac helper sends at most 1920 px across by default (`M/DispatchScreen/main.swift:26`) |
| D24 | The viewer is not restored after a relaunch (§9.6 R2) | the web does not either; the held-control badge covers the one case that matters |
| D25 | L520 is recorded as client done, live proof waiting on the owner (§5.15) | nothing may be installed on the owner's Mac by an agent |
| D26 | The setup prompt is the web's with one sentence reworded so the pre-rename product name is not in it (§5.13) | the stored message can be read in the chat later; the installer reports the removal command itself, so nothing is lost |
| D27 | Gateway-written Screen text is shown through `ScreenWire.plain`, which swaps the pre-rename names for the current ones (§6.6) | an old install on the Mac must not put the old name on screen |
| D28 | The service files what events say under the bot's NAME: a `display.lease` event carries only `profile_key`, which on Hermes is the profile's home path. The name comes from a pairing an open Screen taught, else the status's own `profile` (never "custom"), else a home under `…/profiles/<name>`, else a key that is not a path; an event nobody can name is dropped (§5.1, §5.4; added after review) | the menu and Bot Info ask by name; filed under a path the label never moved on a real gateway |
| D29 | Sign-out and a gateway switch first call `ScreenService.handBackBeforeLeaving()` (at most 2 s, no wait when no Screen is open): the button-up and the close frame go out in order, then `display.lease.release {viewer_id, force}` is awaited and only its answer forgets the saved hold. A plain Close no longer forgets the hold on faith either: the gateway's `display.lease` event (or the next status) does (§5.8, §6.2; added after review) | ending the client cancels every socket on its session, close frame included; a hand-back nobody confirmed must be offered again ("You were in control"), not lost |
| D30 | The first picture has its own wait: after the handshake, 20 s without a byte ends as "The Mac hasn’t sent a picture yet" with the helper's reason (paused, capture error, Screen Recording, locked, else "Its display may be asleep…") and Reconnect; no retry by itself. A first picture that began and stalled is still stuck at 8 s (§5.11; added after review) | the Mac helper writes a frame only when it has one; the web's viewer had no such limit and sat under its notes |
| D31 | Sideways with the keyboard up, Give Back is a 44 pt glass icon (`hand.raised.slash`, named "Give Back" for VoiceOver and the large content viewer) and the keys' side insets are 8 pt; a key row that still overflows shows the system scroll indicator and flashes it. No fade mask (§5.7; added after review) | every key whole on an iPhone 17 Pro; a mask over system glass buttons risks flattening the glass |
| D32 | A screenshot whose download fails is "Can’t load the screenshot. Trying again…" and is fetched again after each of the next 5 polls, then every tenth; only HTTP 404/410 is "expired" (§5.14; added after review; the web called every failure expired) | for the newest capture "expired" is almost always false |
| D33 | A hardware keyboard's named keys (arrows, Tab, Esc, Delete) are registered with all 16 combinations of Shift, Control, Option, Command (§5.6; added after review) | ⌘⇧←, ⌥⇧→, Ctrl+Shift+Tab reached nothing; the web forwarded every held modifier |
| D33a | Audit 09-18: a hardware keyboard's Home (0xff50), End (0xff57), Page Up (0xff55), Page Down (0xff56) and F1–F12 (0xffbe–0xffc9) are named keys too, with the same 16 combinations, on iPad and Mac | the web's list stopped at the arrows, so they never reached the computer |

---

## 11. Not built, and why

* `display.stop`, `display.thumbnail`, `display.install` (+ `display.install.sudo`), `display.switchSandboxImage`: the
  desktop pane's controls; no assigned row; never called (the fixture counts them).
* H.264 (encoding 50): opt-in on the helper and black in the web's own simulator runs (`MEM/bot-screen-harness.md`);
  Tight JPEG is the default the owner used.
* Copying the remote clipboard to the phone (ServerCutText): the web phone build does not do it.
* Presence rows (L211, L216's other rows, L480, L506, L507) and the room message menu entry: other streams; hooks in
  §6.1.
* iPad layouts: the app is iPhone-only (`TARGETED_DEVICE_FAMILY: "1"`).
* Anything installed on the gateway Mac: `docs/owner-todo/screen.md`.

---

## 12. Build order and risks

Suggested slices, each ending in something seen working against the fixture:

1. Fixture + frames + vectors (`screen-gateway.py`, `make-screen-frames.swift`, `--emit-vectors`).
2. `ScreenWire`, `RFBProtocol`, `RFBDecoders` with their unit tests (no UI).
3. `ScreenSocket`, `ScreenStream`, `displaySocket`; `ScreenLiveWireTests` on 9941.
4. `ScreenSession`, `ScreenService`, the viewer with S0–S7, the menu item (L166, L508, L516).
5. Stage gestures, control bar, lease (L509), keys and paste (L510), rotation and compact typing (L511).
6. Holds, reclaim, eviction, leaving (L512); pause and resume (L515).
7. Mac health, notes (L513, L514).
8. `ToolScreenshots`, step sheet block (L345); `ScreenshotFeed`, fallback view (L212, L518).
9. Setup resource, prompt, flow, card (L517); owner note (L520).
10. Bot Info tile and row (§6.1); accessibility pass; both identities build; `scripts/e2e-screen.sh`.

Risks:

* **R1 — a native RFB client is new code.** Tight Basic with zlib and CopyRect are decoded from the specification
  and tested only against the fixture's own encoder, never against a real Xvnc. Mitigation: vectors, byte-at-a-time
  parsing tests, strict limits; the owner's gateway is a Mac, whose helper sends only Fill, JPEG and Raw.
* **R2 — no proof against the real Mac helper** until the owner installs it. The fixture copies its shapes from
  source; capture, permissions and the plugin's in-memory patching of Hermes are not exercised.
* **R3 — control across reconnects** depends on Hermes binding viewer ids to a connection; the reclaim is the web's
  workaround and can lose a race with another viewer (then the phone watches; it never steals).
* **R4 — rotation in a portrait-only app** through the delegate mask may need the two landscape keys in
  `Info.plist`; that must not let any other screen rotate.
* **R5 — a 734 KB `file.attach` frame** on `/api/ws`: fine for Hermes (the web sent the same), slow on a weak link;
  120 s timeout and the HUD cover it.
* **R6 — a zip holding a Mac app inside the iOS bundle.** It is inert data (never unpacked or run on the phone) and
  the web build shipped the same bytes as base64 inside its JavaScript; App Store processing of a nested signed
  `.app` inside a zip resource is untested on the native record. Fallback if upload validation objects: ship the same
  bytes base64-encoded in a `.bin` text resource (as the web did) with the same hash check.
* **R7 — merges**: `BotInfoTiles` (talk), the Computer group (presence), `ToolDetail` (activity code) and
  `AppDelegate` are shared files; edits are small and marked `// [screen]`.
* **R8 — simulator limits**: no two-finger drag in XCUITest, the "Allow Paste" alert, no Low Power or thermal
  switch, a shared and slow Mac. §8.2 says what is proven how.
* **R9 — latency**: the pointer drawn in the picture is as late as the stream; the local ring (D6) is the only
  instant feedback.

---

## 13. Owner to-do

`docs/owner-todo/screen.md`: what the owner must do on the Mac for a live Screen (one tap in the app, two approvals
at the Mac), what the app shows until then, and the dependency worth knowing about (the plugin patches Hermes in
memory at load). Nothing in it is done by an agent.
