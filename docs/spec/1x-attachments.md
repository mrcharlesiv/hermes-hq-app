# 1x — Attachments: photos and files

Spec for the HQ Native "attachments" stream (milestone 2/3, branch `m2/attachments`). It covers sending photos and
files from the composer and showing images and files in a chat: your own sends, history, and what a bot sends back
(`MEDIA:` links, markdown images and file links, generated images). It is written from the web app at
release-build238, the Hermes gateway source, the owner's memory files and the M1 native code, and it is meant to be
built from without re-reading them.

**Citation roots** (every `file:line` is relative to one of these):

| Prefix | Path |
|---|---|
| `R:` | `/Users/me/Projects/hermes-hq-native-ref238` (web app, release-build238, read-only) |
| `V:` | `R:vendor/hermes/apps/desktop/src` (the pinned Hermes desktop renderer the web app runs) |
| `H:` | `/Users/me/.hermes/hermes-agent` (Hermes gateway source, commit `d94b70f675`, READ ONLY, never run or imported) |
| `N:` | `/Users/me/Projects/hermes-hq-native` (this repo; M1 code at `89035a2`) |
| `M:` | `/Users/me/.claude/projects/-Users-me-Projects-hermes-ios/memory` (owner memory) |
| spec NN | `N:docs/spec/NN-*.md` |

"(captured)" marks an answer recorded from the stock performance fixture on 127.0.0.1:9723 on 2026-10-10 (started for
this spec and stopped afterwards; invented credentials, never printed).

---

## 0. TL;DR

1. **Pick.** The composer gets a **+** glass circle (spec 06 §4.3 order `[☰][+][field][primary]`) whose native
   `UIMenu` opens with an inline row of three: **Camera · Photos · Files**, then **Paste Image** when the pasteboard
   holds an image (`R:src/ui-chat/plus-menu.ts:15-39`). Photos = `PHPickerViewController` (images + videos, ≤ 8 per
   pick); Camera = `UIImagePickerController`; Files = `UIDocumentPickerViewController(forOpeningContentTypes: [.item],
   asCopy: true)`. Other menu items (Voice Memo, Talk, Link…, Folder…, Prompt Snippets…) belong to other streams;
   this stream exposes the menu so they can add them (§4.1).
2. **Prepare on the phone, off the main thread.** Every photo (library, camera, paste, and image files from Files)
   becomes a JPEG of at most 3072 px on its long side, orientation applied, **no metadata** (no GPS), via ImageIO
   (`R:ios/App/App/PickedFiles.swift:188-205`). PNG with real transparency stays PNG; animated GIF passes through.
   Videos are copied and re-muxed without location (`PickedFiles.swift:207-233`). Limit **32 MB per item**
   (`PickedFiles.swift:30`), **16 items per message** (§3.9).
3. **Upload at once (eager), by REST.** `GET /api/files?profile=P` → root; then one multipart
   `POST /api/files/upload-stream?profile=P` per item to `<root>/.dispatch-attachments/<UUID>/<name>`
   (`R:ios/App/App/HermesNative.swift:2794-2849`, `R:ios/App/Shared/HermesTransportShared.swift:264,279-306`). Bytes
   never go over the socket (never `image.attach_bytes`, never `data_url`).
4. **Attach at send, by JSON-RPC, then submit.** Right before `prompt.submit`: `image.attach {session_id, path, profile}`
   per photo and `file.attach {session_id, path, name, profile}` per file, in tray order
   (`R:ios/App/Shared/DispatchShareKit.swift:487-512`). The prompt text is the files' `ref_text` lines, a blank line,
   then your words; photos alone send `"What do you see in this image?"` (`DispatchShareKit.swift:156-163`). A file
   whose gateway kept its own copy has its staging folder deleted (`DELETE /api/files`, r1-09).
5. **Your bubble shows the photos and files at once**, from the phone's own copies, with an upload ring; when the stored
   row arrives the same pictures stay (the media cache is seeded from the local copy, no flash).
6. **History:** `@image:` refs, inline `data:` image parts, leading `@file:` refs, `MEDIA:` links, markdown images and
   file links and `image_generate` results all render as images or file rows. Images load lazily over
   `GET /api/fs/download` with auth, decode off the main thread, never enter the transcript cache as bytes
   (spec 03 §6.6, refined in §7 below).
7. **Tap a photo:** a full-screen viewer with the system zoom transition (swipe down or pinch in to dismiss), pinch to
   5×, double-tap 2.5×, paging across the message's photos, **Share** and **Save**. **Tap a file:** download with
   progress, then Quick Look (or the share sheet for types Quick Look can't show).
8. **Leave the chat mid-send and it still goes to its own chat** (owner, `M:voice-memo-bugs.md`,
   `M:send-lost-on-leave.md`).

---

## 1. Decisions (native vs the web)

| # | Decision | Web today | Why |
|---|---|---|---|
| A1 | Upload by REST multipart to the staging folder, attach by **path** | Same: the WKWebView's `image.attach_bytes`/`file.attach{data_url}` frames are rewritten by native code into an upload + path attach (`HermesNative.swift:2794-2849`) | No base64 on the socket (the attach handlers run inline on the socket reader, `H:tui_gateway/server.py:181-200` does not list them; `H:tui_gateway/server.py:1253-1262`) |
| A2 | **Eager upload** of photos *and* files as soon as the tile is ready | Files eager once a session exists, images at send (`V:app/session/hooks/use-prompt-actions/index.ts:430-494`) | The web skipped eager images only because of a second full read in JS (`index.ts:435-439`); natively the upload is free to start, and Send then needs only the fast attach RPCs |
| A3 | An **image picked from Files goes the photo path** (normalised, `image.attach`) | Files always become `@file:` refs (`V:app/chat/session-tile.tsx:346` → `pickContextPaths('file')`, `V:app/chat/hooks/use-composer-actions.ts:459-484`) | An `@file:` image only reaches the model as "binary file, not inlined as text" (`H:agent/context_references.py:320-323,659-664`); a photo is what the person means |
| A4 | Photo-only send text = `"What do you see in this image?"` (parity), and **your bubble hides exactly that text** when the message has ≥ 1 image | Web optimistic bubble shows no text, then the reloaded row shows the question | One look before and after the reload; Telegram shows a captionless photo |
| A5 | After a `4001`/`4007` on `prompt.submit`, **re-attach the photos** to the new runtime before resubmitting | Web's submit recovery resumes and resubmits; the images queued on the dead runtime are lost (`V:…/submit.ts:915-952`) | `attached_images` lives on the runtime record (`H:tui_gateway/prompt_attachments.py:137-159`) |
| A6 | `image.detach` every photo already attached when a send is withdrawn (Stop, refusal) before `prompt.submit` | Web detaches only when you remove a chip (`use-composer-actions.ts:832-850`) | Otherwise the next prompt in that chat carries them (`H:tui_gateway/prompt_turn.py:147-149`) |
| A7 | **Telegram media bubble**: photos inside your bubble at its top, caption under them; a photo-only message is the photo itself, shaped like a bubble | Thumbnail row *under* the bubble (`V:components/assistant-ui/thread/user-message.tsx:405-418`) | Spec 06 §12: "Keep Telegram's *shapes and sizes* only"; Hermes colours, no wallpaper, no checks |
| A8 | History images over `/api/fs/download` (raw bytes); `session_id` only for **relative** paths | `read-data-url` (base64 JSON, 16 MiB cap) | Spec 03 §6.6 chose download; passing `session_id` makes Hermes look the session up and 404 when it can't (`H:hermes_cli/web_routers/files.py:891-904`) |
| A9 | Viewer = native zoom transition + `UIScrollView` zoom; files = Quick Look | Web lightbox + preview pane / share sheet | Native conventions (`M:ios-native-ux-goal.md`: "long-press menus") |
| A10 | `@file:` rows in your bubble open the file (download + Quick Look) | Inert chips (`V:components/assistant-ui/directive-text.tsx:580-623`; `DIRECTIVE_ACTIONS` has only `session` and `url`, `:514-526`) | A file row that does nothing reads as broken |
| A11 | At most **16** attachments per message | No cap | Hermes expands at most 16 `@`-references per message (`H:agent/context_references.py:102,217-223`) |
| A12 | 32 MB per item, fixed this round | Settings › Chat lets 1–32 MB (`R:ios/App/App/HermesPlatform.swift:1334-1337`) | The Settings stream may add the switch; the store reads one constant |
| A13 | Keep the staging folder name `.dispatch-attachments` | Same (`HermesTransportShared.swift:264`) | The owner's gateway already has it; one place to clean |
| A14 | Drafts (text + attachments) persist per chat, newest 50 chats | Same (`R:src/attachment-drafts.ts:54-69`) | A tray that forgets its photos on relaunch looks like loss |
| A15 | Images at `https:` URLs (generated images, markdown) are fetched with no cookies, public internet only | Same rule (r1-10, `R:ios/App/App/HermesPicker.swift:256-262`) | A reply (which a prompt injection can write) must not make the phone fetch LAN/Tailscale addresses |

---

## 2. Scope

### 2.1 In this round

- `+` menu: Camera, Photos, Files, Paste Image; paste of an image into the field (edit-menu Paste, ⌘V).
- Attachment tray above the composer: thumbnails / file tiles, remove, upload progress, failure + retry, preview.
- Draft persistence and local file retention; gateway staging cleanup.
- Send with text, the local queue with attachments, Stop, leaving the chat, refusal (draft returned with its
  attachments), delivery-unconfirmed (unchanged M1 path).
- History: user rows with `@image:` / `@file:` / `[Image attached at: …]` / inline `data:` parts / non-voice `MEDIA:`
  lines; assistant `MEDIA:` / `#media:` links, markdown images, file-path links; `image_generate` card (live and
  settled); remote https images.
- Full-screen image viewer (zoom, swipe to dismiss, paging, Share, Save); long-press menus on images and files.
- File preview (download with progress, Quick Look, share fallback, cache).
- `GatewayClient` upload/download primitives.

### 2.2 Left out of this round, and why

| Left out | Why |
|---|---|
| Voice Memo, Talk with <bot>, transcribing picked audio | Voice stream. Voice-memo user rows keep M1's `VoiceMemo` bubble (`N:App/Chat/VoiceMemo.swift`); audio *files* in history show as file rows that open in Quick Look (which plays audio); picked audio files hand off to the voice stream at Send (§13.4) |
| Link…, Folder… ("From your computer"), Prompt Snippets…, More (attachment providers) | Menus stream / later; their slots in the + menu are reserved (§4.1). `@folder:` refs in history draw a non-tappable folder row (§7.4) |
| Inline audio/video players | Quick Look plays both; a player is the voice stream's |
| `pdf.attach` (pages as images), `clipboard.paste` RPC, `input.detect_drop` | The web never uses them on the phone; PDFs go as files |
| Share extension | Later batch (parity list) |
| Background `URLSession` uploads | Needs a background session with its own auth handling; an upload interrupted by suspension restarts on return (§6.6) |
| Attachment size setting (Settings › Chat) | Settings stream (A12) |
| Editing a sent message's attachments, drag & drop into the chat, iPad layout | No message edit or iPad layout in native yet |
| Chat-wide media gallery in the viewer | The viewer pages only the tapped message's photos |
| Hermes performance plugin thumbnails (`/api/plugins/hermes-hq-performance/media/thumbnail`) | Optional speed-up (spec 03 §6.6); `download` + ImageIO thumbnailing is enough at 3072 px sources |
| Artifacts page | Its own parity item |
| SVG rendering | No native SVG renderer; `.svg` shows as a file row (Quick Look may still show it) |
| Live Photos as Live Photos | Sent as stills (`loadFileRepresentation(UTType.image)`) |

---

## 3. Wire calls (exact)

All REST goes through the account's `HTTPTransport` with the same decoration as `rest` (password: cookies from the
jar; Nous: `Authorization: Bearer <access>`, `httpShouldHandleCookies = false`, applied at send time;
`N:HermesKit/Net/GatewayAuth.swift:66-122`; spec 01 §6.2: "Every gateway request (REST, uploads, downloads, media
ranges…)" gets it). A 401 on an `/api/` route refreshes once (single flight) and retries once (`GatewayAuth.swift:85-90`).
Redirects are never followed (`N:HermesKit/Net/HTTPTransport.swift:159-162`).

### 3.1 The send sequence

```
pick → prepare locally (§5) ───────────────────────────────────── tile: preparing
     → GET  /api/files?profile=P                (once per account+profile per app run, §3.2)
     → POST /api/files/upload-stream?profile=P  (one per item, serial, §3.3) ───── tile: uploading → uploaded
Send → (turn busy? wait in the local queue, §6.4)
     → session.resume (only if no runtime id; M1's one param set, spec 03 §3.1)
     → image.attach × photos, file.attach × files, in tray order (§3.4, §3.5)
     → prompt.submit {session_id, text, profile[, queued]} (§3.7)
     → DELETE /api/files?profile=P {path:<file staging folder>, recursive:true} for files the gateway copied (§3.6)
```

### 3.2 `GET /api/files` — the upload root

Request: `GET /api/files?profile=<owner profile>` (the web sends `profile`, `HermesNative.swift:2812-2817`; Hermes
ignores it for managed files: `H:hermes_cli/web_routers/files.py:507-508` has no `profile` parameter).

Hermes answer (`files.py:507-530`; policy `H:hermes_cli/web_server_files.py:144-158,161-193`): the managed root —
`HERMES_DASHBOARD_FILES_ROOT` if set, `/opt/data` on hosted installs, else the gateway user's **home**:

```json
{"path":"/Users/ivy","parent":"/Users","entries":[…],"root":null,"locked_root":null,"can_change_path":true}
```

Stand-in (captured): `200 {"path": "/fixture/uploads"}`.

- Read only `path` (non-empty string). Cache it per `(account, profile)` for the app run; drop the cache on any upload
  answering 403/404 and read it again once.
- Errors: `401` (after the one refresh) → the session ended (M1 sign-out path); `403`/`500` (e.g. `"Managed files root
  is unavailable: …"`, `web_server_files.py:81-91`) or no `path` → the upload fails with **"Your gateway has no folder
  for uploads."** (`DispatchShareKit.swift:475`).
- The listing body can be large (it lists the home folder): read it under the normal 32 MiB REST ceiling
  (`N:HermesKit/Net/GatewayAddress.swift:185-189`) and parse only `path`.

### 3.3 `POST /api/files/upload-stream` — one file

```
POST /api/files/upload-stream?profile=<owner profile>
Content-Type: multipart/form-data; boundary=hermes-<UUID>
```

Body, built **on disk** in the account's temporary directory (never in memory; file protection `.completeUnlessOpen`, so
an upload keeps reading it after the phone locks), field
order and bytes exactly as `R:ios/App/Shared/HermesTransportShared.swift:279-306`:

```
--hermes-<UUID>\r\n
Content-Disposition: form-data; name="path"\r\n
\r\n
<root>/.dispatch-attachments/<FOLDER-UUID>/<name>\r\n
--hermes-<UUID>\r\n
Content-Disposition: form-data; name="overwrite"\r\n
\r\n
false\r\n
--hermes-<UUID>\r\n
Content-Disposition: form-data; name="file"; filename="<name>"\r\n
Content-Type: application/octet-stream\r\n
\r\n
<file bytes, streamed in 64 KiB reads, stop with "too large" past 32 MB>\r\n
--hermes-<UUID>--\r\n
```

- `<FOLDER-UUID>` is `UUID().uuidString` (upper case, as the web); the draft attachment keeps it to delete the folder.
- `<name>` is the safe name (§5.5): no `"`, `\`, `/`, `:`, control characters; ≤ 180 UTF-8 bytes. Refuse to build a
  body whose name contains CR, LF, `"` or `\` (`R:src/bridge/upload.ts:4`).
- Root and folder are joined with `/` even on a Windows gateway (the web does the same; Hermes accepts the mix).
- Send it with `uploadTask(with:fromFile:)` on the **bulk** pool, request timeout 60 s (idle), task priority 0.5,
  raised to `URLSessionTask.highPriority` when a Send is waiting for it. Progress = `didSendBodyData`.

Hermes (`files.py:700-718`, `628-643`, `656-697`): resolves the path under the managed policy, `mkdir -p` the parent,
streams to a temp file in 1 MiB chunks (`H:hermes_cli/web_server.py:895`), enforces **100 MB**
(`web_server.py:891`), renames into place. Answer `200`:

```json
{"ok":true,"entry":{"name":"photo.jpg","path":"/Users/ivy/.dispatch-attachments/2B1F…/photo.jpg","is_directory":false,"size":812345,"mtime":…,"mime_type":"image/jpeg"},
 "path":"/Users/ivy/.dispatch-attachments/2B1F…/photo.jpg","root":null,"locked_root":null,"can_change_path":true}
```

Stand-in (captured): `200 {"path": "/fixture/uploads/.dispatch-attachments/E25C6FF2-F7FA-4719-A7A2-E37EF90730E9/report.pdf"}`.

Take **`path`** from the answer (the resolved display path) as the gateway path; refuse an answer without it:
**"Your gateway didn’t store “<name>”."** (`DispatchShareKit.swift:666-668`).

| Status | Hermes detail | Native |
|---|---|---|
| 400 | `"Path must be absolute"`, `"Path cannot contain '..'"`, `"Invalid path"` (`web_server_files.py:161-193`) | failed, not retryable: "Your gateway refused this file's name." |
| 401 | — | refresh once, re-send from the same body file (M1 rule); a second 401 → session ended |
| 403 | `"Path outside managed files root"` / `"File is not writable"` | drop the cached root, read it again, retry once; then failed: "Your gateway has no folder for uploads." |
| 409 | `"File already exists"` (overwrite=false) | cannot happen with a fresh UUID; retry once with a new folder UUID |
| 413 | `"File is too large"` (100 MB, or a proxy limit) | failed, not retryable: "“<name>” is too big for your gateway." (`DispatchShareKit.swift:663`) |
| 5xx, timeout, connection lost | — | retryable: one automatic retry after 2 s, then failed (§6.3 wording) |
| offline / Tailscale off (`GatewayFailure.tailscaleOff`) | — | **waiting**: starts by itself when the connection is ready again |

### 3.4 `image.attach` — queue a staged photo for the next prompt

Contract `ImageAttachParams(SessionParams)` = `session_id`, `profile`, `path` (`H:tui_gateway/contracts/prompt_voice.py:113-118`;
`SessionParams` `H:tui_gateway/contracts/common.py:224-228`). **Unknown keys answer `4000`**
(`H:tui_gateway/contracts/base.py:16,32-35`; `H:tui_gateway/rpc_dispatch.py:25-31`). Never send `filename`,
`content_base64`, `data`, `ext`.

```json
{"jsonrpc":"2.0","id":31,"method":"image.attach","params":{"session_id":"5cc537d1","path":"/Users/ivy/.dispatch-attachments/2B1F…/photo.jpg","profile":"default"}}
```

Handler `H:tui_gateway/methods_prompt.py:859-884`: `path` is resolved as a dropped path first (so an absolute path with
spaces works unquoted, `H:hermes_cli/cli_terminal_input.py:145-180`), must exist and have an image extension from
`.png .jpg .jpeg .gif .webp .bmp .tiff .tif .svg .ico` (`cli_terminal_input.py:33-36`), and is **appended to the
runtime's `attached_images`** (not copied). Result `AttachedImageResult` (`prompt_voice.py:84-103`;
`methods_prompt.py:1223-1227`; `H:tui_gateway/server.py:869-878`):

```json
{"attached":true,"path":"/Users/ivy/.dispatch-attachments/2B1F…/photo.jpg","count":1,"remainder":"",
 "text":"[User attached image: photo.jpg]","name":"photo.jpg","width":3024,"height":4032,"token_estimate":680}
```

- Success = `attached == true`. Anything else → failure with `result.message` if present, else
  **"Your gateway didn’t accept “<name>”."** (`DispatchShareKit.swift:497-499`). (Stock fixtures answer `{}` — that
  is this failure, captured.)
- Keep `width`/`height` when present (they become the attachment's pixel size if the phone didn't know it).
- Errors: `4001 "session not found"` (stale runtime, `server.py:1229-1243`) → §6.5; `4015 "path required"`;
  `4016 "image not found: …"` / `"unsupported image: …"`; `5027 <exception>`; `4000` (a param bug — never retry).
- Timeout **60 s** (the share kit's; the handler opens the image with PIL inline).

### 3.5 `file.attach` — stage a file into the session

Contract `FileAttachParams(SessionParams)` = `session_id`, `profile`, `path`, `data_url`, `name`
(`prompt_voice.py:165-185`). Native sends **`session_id`, `path`, `name`, `profile`** only (never `data_url`).

```json
{"jsonrpc":"2.0","id":32,"method":"file.attach","params":{"session_id":"5cc537d1","path":"/Users/ivy/.dispatch-attachments/77AC…/report.pdf","name":"report.pdf","profile":"default"}}
```

Handler `methods_prompt.py:976-996`, staging `H:tui_gateway/prompt_attachments.py:187-248`: a path inside the
session's workspace is used **in place** (`uploaded:false`); otherwise the bytes are copied into
`<profile home>/attachments/<name>` (`-2`, `-3`… on clashes) or the workspace's `.hermes/attachments` when
`attachments.storage: workspace` (`prompt_attachments.py:82-95`), `uploaded:true`. The ref is workspace-relative when
it can be, else absolute, quoted when it holds spaces or brackets (`prompt_attachments.py:162-178`):

```json
{"attached":true,"name":"report.pdf","path":"/Users/ivy/.hermes/attachments/report.pdf",
 "ref_path":"/Users/ivy/.hermes/attachments/report.pdf","ref_text":"@file:/Users/ivy/.hermes/attachments/report.pdf","uploaded":true}
```

- Success = `attached != false` **and** a non-empty `ref_text` (`DispatchShareKit.swift:501-504`). Keep `ref_text`
  exactly as given; it goes into the prompt text verbatim.
- Errors: `4001`; `4015 "path or data_url required"`; `5028 <exception>` (e.g. `"file not found on gateway and no
  data_url provided"`); `4000`.
- Timeout 60 s (the handler copies the whole file inline).
- Stock fixture answer (captured): `{"attached": true, "path": "/fixture/voice-memo.wav", "ref_text": "@file:/fixture/voice-memo.wav"}`.

### 3.6 Staging cleanup — `DELETE /api/files`

When `file.attach` answered and `HermesTransportPolicy.stagedCopyReleased(uploaded:storedPath:folder:)` is true —
`uploaded == true` and the stored `path` is neither the staging folder nor inside it
(`HermesTransportShared.swift:265-270`) — delete the staging folder, best effort, once:

```
DELETE /api/files?profile=<owner profile>
Content-Type: application/json

{"path":"<root>/.dispatch-attachments/<FOLDER-UUID>","recursive":true}
```

Hermes `files.py:731-759` (`ManagedFileDelete {path, recursive=false}`, `H:hermes_cli/web_models.py:101-103`):
`{"ok":true,"path":…,"root":…}`; 404 when gone; 400 for the root itself. Ignore every failure (no retry loop).
Also delete the staging folder of a **draft attachment removed after it was uploaded but before it was sent**.

**Never delete a photo's staging folder after it was attached**: `image.attach` queues the path in place, the stored
user row then says `@image:<that path>` (`H:tui_gateway/session_history.py:51-60`), and history loads the photo from
it (the web never deletes them either: `HermesNative.swift:2836-2848` registers only `file.attach` folders).

### 3.7 `prompt.submit` with attachments

Params: M1's set unchanged — `session_id`, `text`, `profile`, and `queued:true` only for queue drains
(spec 04 §2.2; `N:HermesKit/Chat/LiveChatSession.swift:634-636`). Text composition, exactly
(`DispatchShareKit.swift:156-163`; `V:app/session/hooks/use-prompt-actions/submit.ts:196-210`):

```swift
static func promptText(typed: String, fileRefs: [String], hasImages: Bool) -> String {
    let body = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    let refs = fileRefs.filter { !$0.isEmpty }.joined(separator: "\n")
    let text = [refs, body].filter { !$0.isEmpty }.joined(separator: "\n\n")
    return text.isEmpty && hasImages ? "What do you see in this image?" : text
}
```

| You typed | Attached | `text` sent |
|---|---|---|
| `hello` | 2 photos | `hello` |
| (nothing) | 1 photo | `What do you see in this image?` |
| `summarise` | report.pdf | `@file:/Users/ivy/.hermes/attachments/report.pdf\n\nsummarise` |
| (nothing) | report.pdf, `My Notes.md` | ``@file:/Users/ivy/.hermes/attachments/report.pdf\n@file:`/Users/ivy/.hermes/attachments/My Notes.md` `` |
| `look` | 1 photo + report.pdf | `@file:/Users/ivy/.hermes/attachments/report.pdf\n\nlook` |

What Hermes stores as your row (`session_history.py:51-60`): the text, then one `@image:<path>` line per photo that
still exists (`format_reference_value` quoting, `H:agent/context_references.py:141-148`):
`look\n@image:/Users/ivy/.dispatch-attachments/2B1F…/photo.jpg`. The model gets the photos either as native image
parts (`H:agent/image_routing.py:533-567`) or as a `vision_analyze` hint (`session_history.py:30-48`); the default
question is used when the text is empty in both paths, so the phone's default is only for parity.

Busy turn: a submit that finds the session running with images queued claims them and queues the prompt
(`H:tui_gateway/session_auto_continue.py:404-458`), but native never gets there: a send while a reply runs waits in the
**local** queue and attaches only when the turn has ended (§6.4; spec 04 §6.2 M1).

### 3.8 `image.detach`

`ImageDetachParams(SessionParams)` = `session_id`, `profile`, `path` (`prompt_voice.py:187-197`); handler
`methods_prompt.py:999-1011` → `{"detached":bool,"count":int}`. Sent for each photo attached in this send when the
send is withdrawn before `prompt.submit` went out (§6.5). Errors ignored.

### 3.9 Limits

| Limit | Value | Source |
|---|---|---|
| Per item on the phone (after preparation) | 32 MB | `PickedFiles.swift:30,152,171` |
| Per pick | 8 (Photos `selectionLimit`, Files first 8 URLs) | `HermesPicker.swift:122`; `HermesPlatform.swift:1043-1048,1064-1066` |
| Per message | 16 (native) | A11 |
| Photo long side / quality | 3072 px, JPEG 0.85 | `PickedFiles.swift:193-205`; camera `HermesPlatform.swift:1094-1101` |
| Gateway upload cap | 100 MB | `H:hermes_cli/web_server.py:891` |
| `image.attach_bytes` cap (not used) | 25 MB | `H:tui_gateway/prompt_attachments.py:16` |
| History image download (inline display + viewer) | 32 MB | web media limit `PickedFiles.shared.limit` (`HermesNative.swift:2933`) |
| File preview / share download | 512 MB | `R:ios/App/App/HermesNativeExtras.swift:97` |
| Inline `data:` image part decoded | 32 MB decoded each | the page itself is capped at 32 MiB (`GatewayAddress.swift:185-189`) |
| Remote https image | 32 MB, ≤ 100 MP, ≤ 5 redirects, image/* only | `HermesPicker.swift:238-322` |

---

## 4. The + menu and the pickers

### 4.1 The + button and its menu

- A 40 pt **glass circle** in the composer's `UIGlassContainerEffect` (spacing 6), untinted, interactive, between ☰
  (menus stream; absent until it lands) and the field (spec 06 §4.3, §8). Glyph: SF Symbol `plus`, 18 pt, medium,
  label-2 (matches spec 06's `M12 5v14M5 12h14` stroke 2.2). Accessibility label **"Attach"**, identifier
  `composer.plus`. It is a `UIButton` with `menu` and `showsMenuAsPrimaryAction = true` (no custom menu; a long press is
  the same menu).
- Menu, top to bottom (`R:src/ui-chat/plus-menu.ts:15-39`):

  | Item | Native element | Notes |
  |---|---|---|
  | **Camera · Photos · Files** | one `UIMenu(options: .displayInline, preferredElementSize: .medium)` of three `UIAction`s: `camera`, `photo.on.rectangle`, `doc` | Camera disabled with subtitle **"Unavailable"** when `UIImagePickerController.isSourceTypeAvailable(.camera)` is false (Simulator); all three disabled with subtitle **"Limit reached"** at 16 attachments |
  | Voice Memo, Talk with <bot> | reserved (voice stream) | |
  | **Paste Image** (`doc.on.clipboard`) | `UIDeferredMenuElement.uncached`: present only when `UIPasteboard.general.hasImages` (no paste prompt for that check) | Reading may show iOS's "Allow Paste" prompt, as the web's does |
  | Link…, Folder…, Prompt Snippets… / More | reserved (menus stream) | |

  Expose it as `ComposerPlusMenu` with ordered slots (`pickers 0, memo 10, talk 20, paste 30, link 40, folder 50,
  snippets 60, more 70`) that other streams register into; this stream fills `pickers` and `paste`.
- Haptics: none on open (a menu is silent, spec 06 §9).
- A picker failure shows a system alert titled **"Couldn't Attach"** with the reason and OK (the web's
  "Couldn't Open Attachment" alert, `plus-menu.ts:69-72`, worded for the action).

### 4.2 Photos

`PHPickerConfiguration()`; `selectionLimit = min(8, 16 − count)`; `filter = .any(of: [.images, .videos])`;
`preferredAssetRepresentationMode = .current` (`HermesPicker.swift:121-127`). No photo-library permission is needed.
On finish: dismiss, then insert one **preparing** tile per result at once (pick order), and import each provider off
the main thread (`HermesPicker.swift:151-188`):

- has `UTType.movie` → `loadFileRepresentation(.movie)` → size check (32 MB, before copying) → copy into staging
  (§5.4) → strip location (§5.3). Becomes a **file** attachment (`R:build/fe-convo-gates.ts:105-110`: "A video from the
  library attaches as a file").
- else `loadFileRepresentation(.image)` → normalise (§5.1) → `photo.jpg` (or `photo.png`, `photo.gif`).
- The provider's file exists only inside its callback: do the read/copy there. Show the `Progress` of an iCloud
  download on the tile ring. Removing the tile cancels the `Progress`.

### 4.3 Camera

`UIImagePickerController`, `sourceType = .camera`, `mediaTypes = [UTType.image.identifier]`, full screen.
`NSCameraUsageDescription` = **"Take a photo to attach to your chat."** (web: `R:ios/App/App/Info.plist:26`).
Denied access → alert "Allow camera access for HQ Native in Settings." with **Open Settings** and Cancel. On finish:
`info[.originalImage]`, scaled to ≤ 3072 px long side (`preparingThumbnail(of:)`), JPEG 0.85, name `camera.jpg`
(`HermesPlatform.swift:1088-1103`). The `UIImage` carries no location; never write `info[.mediaMetadata]`.

### 4.4 Files

`UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)`, `allowsMultipleSelection = true`,
first `min(8, 16 − count)` URLs (`HermesPicker.swift:128-133`; `HermesPlatform.swift:1064-1085`). For each URL,
inside `startAccessingSecurityScopedResource()`:

- size > 32 MB → refused before copying;
- conforms to `UTType.image` and ImageIO opens it → the photo path (A3), named `<original stem>.jpg` (or `.png`/`.gif`);
- else copy into staging under its safe name. Kind **file**.

### 4.5 Paste

- **+ › Paste Image**: `UIPasteboard.general.itemProviders` that conform to `UTType.image` → each through the
  normaliser, named `clipboard.jpg` / `clipboard.png` (`HermesPlatform.swift:1202-1222`).
- **In the field**: the composer's `UITextView` subclass sets
  `pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.image.identifier, UTType.plainText.identifier])`
  and overrides `paste(itemProviders:)`: image providers become attachments, text goes to `super`. Edit-menu Paste is
  user-initiated, so iOS shows no paste prompt.

### 4.6 Pick errors (alert "Couldn't Attach", OK)

| Case | Reason text |
|---|---|
| Item over 32 MB | **"“clip.mov” is larger than 32 MB, the most HQ Native can send."** |
| Photo or video unreadable | **"Couldn’t read the selected photo or video."** (`HermesPlatform.swift:1056-1058`) |
| File unreadable | **"Couldn’t read the selected file."** (`HermesPlatform.swift:1078-1080`) |
| Video location couldn't be removed | **"Couldn’t remove this video’s location, so it wasn’t attached."** (`PickedFiles.swift:207-209`) |
| Camera image couldn't be saved | **"Couldn’t save the camera photo."** (`HermesPlatform.swift:1090,1101`) |
| More than fits (16) | **"You can attach up to 16 items to one message."** (the rest of that pick is dropped; the first ones stay) |

Every failed item's partial copy is deleted at once (`PickedFiles.swift:235-240`).

---

## 5. Preparing files on the phone

All of §5 runs off the main thread (`nonisolated` types, `Task.detached(priority: .userInitiated)`), cancellable.

### 5.1 Photo normaliser

```
source = CGImageSourceCreateWithURL(url, [kCGImageSourceShouldCache: false])
type   = CGImageSourceGetType(source); frames = CGImageSourceGetCount(source)
if type == public.gif && frames > 1 && size ≤ 32 MB → copy unchanged (keeps animation), name <stem>.gif
image  = CGImageSourceCreateThumbnailAtIndex(source, 0, [
           kCGImageSourceCreateThumbnailFromImageAlways: true,
           kCGImageSourceCreateThumbnailWithTransform: true,     // orientation into the pixels
           kCGImageSourceThumbnailMaxPixelSize: 3072,
           kCGImageSourceShouldCacheImmediately: true])
alpha  = image.alphaInfo ∉ {.none, .noneSkipFirst, .noneSkipLast}
         && the image has a pixel with alpha < 255 (sample a 64×64 downscale)
dest   = CGImageDestinationCreateWithData(data, alpha ? png : jpeg, 1, nil)
CGImageDestinationAddImage(dest, image, alpha ? nil : [kCGImageDestinationLossyCompressionQuality: 0.85])
```

No properties dictionary is passed, so **no EXIF, GPS, TIFF or maker data** reaches the gateway (r4-101,
`PickedFiles.swift:188-192`). HEIC/HEIF/TIFF/BMP/RAW all come out JPEG (Hermes would refuse `.heic` in
`image.attach`, `cli_terminal_input.py:33-36`). The full-resolution bitmap is never decoded. Record `pixelWidth`,
`pixelHeight` of the output.

### 5.2 Thumbnail for the tile

From the prepared file, `CGImageSourceCreateThumbnailAtIndex` with max pixel `64 pt × screen scale` (128 or 192),
kept in memory only (the drafts store never holds thumbnails; a restored draft makes it again, one at a time:
`R:src/attachment-preview.ts:5-21`).

### 5.3 Video location removal

`AVAssetExportSession(asset:, presetName: AVAssetExportPresetPassthrough)`, `metadataItemFilter = .forSharing()`,
`export(to:as:)` to a sibling `.sharing-<UUID>.<ext>` (`.mp4`/`.m4v`/`.mov` by extension), then `replaceItemAt`.
Failure → the attachment is refused (§4.6) and its folder deleted (`PickedFiles.swift:211-233`, r5-87).

### 5.4 Local staging

- Root: `Application Support/HQNAttachments/<account key hash>/`, excluded from backup; each attachment in its own
  `<UUID>/` folder (the UUID is the draft attachment's `id`); files written with `.completeUnlessOpen`
  (uploads keep running while the phone locks; the web used `.complete`, `PickedFiles.swift:159,179`).
- A file path is only ever resolved inside this root with a UUID folder name (`PickedFiles.swift:43-73`).

### 5.5 Safe names (`PickedFiles.safeName`, `PickedFiles.swift:131-149`)

Last path component; drop control characters and `" \ / :`; empty, `.` or `..` → `attachment`; ≤ 180 UTF-8 bytes,
keeping an extension of ≤ 32 bytes; cut at whole Unicode scalars. Names: `photo.jpg` (Photos), `camera.jpg`,
`clipboard.jpg|png`, `<stem>.jpg|png|gif` (images from Files), the original name otherwise.

---

## 6. Drafts, upload and send

### 6.1 Model

```swift
nonisolated struct DraftAttachment: Identifiable, Hashable, Sendable, Codable {
    enum Kind: String, Codable, Sendable { case image, file }
    enum Upload: Hashable, Sendable, Codable {
        case preparing(fraction: Double?)          // being imported / normalised
        case waiting                               // ready; upload not started (offline, or behind another)
        case uploading(sent: Int64, total: Int64)
        case uploaded(path: String, folder: String) // gateway path + staging folder
        case failed(reason: String, retryable: Bool)
    }
    let id: String                 // UUID; also the local staging folder name
    var kind: Kind
    var name: String               // safe name, as uploaded
    var localFile: String          // "<id>/<name>", relative to the account's staging root
    var byteSize: Int64
    var pixelWidth: Int?, pixelHeight: Int?
    var typeIdentifier: String     // UTType of the prepared file
    var upload: Upload
}
```

A chat's draft = `{text, attachments: [DraftAttachment]}`, keyed by the chat's scope
`"<account id>|<profile>|<stored session id>"` (the `layoutScope`, `N:HermesKit/Contracts.swift:238-241`).

### 6.2 Tray (above the composer row)

- Sits inside the composer view, above the row, so it moves with the keyboard (it is part of what
  `keyboardLayoutGuide` carries); the table's bottom inset follows through the existing `onHeightChange`
  (`N:App/Chat/ComposerView.swift:14-15`) in the same animation. Height 64 pt tiles + 8 pt gap above the row. A
  horizontal scroll view; leading inset = the field's leading edge; 8 pt between tiles. Insert/remove animate with the
  system spring (0.35 s).
- **Opaque**, painted in the chat's page colour (`ChatPalette.page`), never glass or see-through: the owner saw the
  transcript "read straight through the tile and its name" on the floating composer (`R:src/phone-ui-chat.css:401-405`,
  owner 2026-10-06).
- **Photo tile:** 64×64 pt, radius 10 (control), aspect-fill thumbnail, 0.5 pt separator stroke.
- **File tile:** 64 pt tall, width fits 160…240 pt, radius 14 (card), separator stroke; a 40 pt rounded square
  (radius 10, Fill 3) with the kind glyph (§7.6) at 12 pt from the leading edge; name in Subheadline 15 semibold,
  label, one line, middle-truncated; detail in Caption 1 label-2: **"PDF · 2.4 MB"** (type from `UTType.localizedDescription`
  short form or the upper-cased extension, size `ByteCountFormatter .file`). 12 pt top/bottom padding
  (`M:row-padding-feedback.md`: "about 12–14pt top and bottom").
- **Remove:** a 22 pt `xmark.circle.fill` (hierarchical, label-2 on the page colour) at the tile's top-trailing corner,
  offset (−6, −6), 44×44 hit area, label **"Remove <name>"**, identifier `composer.tray.remove.<index>`. Removing
  cancels its preparation/upload, deletes the local folder, deletes the gateway staging folder if uploaded (§3.6).
- **States drawn on the tile:**

  | State | Look | VoiceOver value |
  |---|---|---|
  | preparing | Fill 3 tile, 20 pt `UIActivityIndicatorView` (a ring with the fraction when known) | "Preparing" |
  | waiting | the thumbnail at 60 % opacity, no ring | "Waiting for connection" |
  | uploading | thumbnail with a 30 % black scrim and a 24 pt determinate ring (white, 2.5 pt) | "Uploading, 40 percent" |
  | uploaded | plain | — |
  | failed | thumbnail with a red `exclamationmark.circle.fill` (`ChatPalette.alertRed`) centred; tap → menu titled with the reason: **Try Again** (left out for a final refusal other than "no folder for uploads": it would fail the same way), **Remove** | "Couldn’t upload" |

- **Tap** (not failed): photo → the viewer (§9) on the local file; file → Quick Look (§10) on the local copy.
  Identifier `composer.tray.tile.<index>`; label "Photo, photo.jpg" / "File, report.pdf".
- **Send button:** enabled when (trimmed text non-empty **or** ≥ 1 attachment) **and** no attachment is `preparing`
  **and** M1's connection rule allows sending (`N:App/Chat/ChatViewController.swift:897`). Failed attachments don't
  disable Send: the send retries their upload once (§6.3).

### 6.3 Upload queue

- One `AttachmentUploader` actor per account; **one upload at a time**, oldest first; starts when a tile becomes
  `waiting` and the account's connection is `ready` — except picked audio files, which wait for Send (§13.4). A chat being off screen doesn't pause its drafts' uploads.
- Retry: one automatic retry 2 s after a retryable failure; then `failed(retryable: true)`. The next Send of that draft
  retries once more before refusing.
- Failure reasons (tile menu title and the send refusal card):
  - network/timeout: **"Couldn’t upload “photo.jpg”. Check your connection and try again."**
  - 413: **"“clip.mov” is too big for your gateway."**
  - no root: **"Your gateway has no folder for uploads."**
  - other: **"Couldn’t upload “photo.jpg” (gateway error 500)."**
- Cancelled uploads leave no partial file on the gateway (Hermes removes its temp file on any non-success,
  `files.py:663-697`).

### 6.4 Send pipeline

`ChatViewController.send` hands `(text, attachments)` to the session (§13.1). The pipeline, per message, in order:

1. **Busy?** If a reply runs (or the queue isn't empty and not parked), the message waits in the local queue with its
   attachments, as M1's text sends do (no bubble yet; `QueuedMessage` gains `attachments`, §13.1). The queue card shows
   the text or, without text, **"Photo"**, **"2 Photos"**, **"report.pdf"**, **"3 Attachments"**, with a 28 pt
   thumbnail of the first photo. Uploads keep going while it waits. Remove from the queue returns text **and**
   attachments to the composer. Either way the composer clears text **and tray** in the same frame as Send.
2. **Optimistic bubble** (spec 06 §5.2) when the message goes out (at once when idle, or when the queue drains it): a
   local user message whose text part is the typed text (or the default question when empty with photos, A4) and whose
   attachments are the draft's (`MessageAttachment.Source.local`). The send lift runs from the union of the tray and
   the field's text box; skip the lift when the new bubble is taller than 60 % of the screen.
3. **Await uploads** (raised priority; the bubble shows each photo's ring). A failed retryable upload is retried once;
   still failing → **refuse** (step 8).
4. **Runtime:** M1's pre-send resume when no runtime id (`LiveChatSession.swift:620-626`).
5. **Attach**, in tray order: photos `image.attach`, files `file.attach` (§3.4, §3.5). On `4001`/`4007 "…no longer
   live…"` → resume once and restart step 5 from the first attachment. Any other failure → `image.detach` the photos
   already attached in this send, then refuse with the gateway's message.
6. **Submit** `prompt.submit` with `promptText(...)` (§3.7), M1's loop unchanged (busy retry, delivery-unconfirmed on
   timeout/connection loss, never resend) **plus**: on `4001`/`4007` → resume once → **re-run `image.attach` for the
   photos only** (file refs stay valid: the copy or the in-place path still exists) → submit once more (A5).
7. **After the ack:** seed the media cache with each photo's local file under its gateway path (§8.1), delete
   released file staging folders (§3.6), release the local staging folders (§6.6).
8. **Refusal** (M1 `refuseSend`, `LiveChatSession.swift:773-786`): remove the bubble, add the error card, and return the
   draft — text **and** attachments with their upload state (uploaded ones stay uploaded, so a resend skips the upload) —
   to the composer through `onDraftReturned`. If the composer already holds a new draft, the returned attachments go
   in front of its tray (dedupe by `id`), and the text follows M1's rule. Haptic `notification.error`.
9. **Stop** while steps 3–5 run (`stopEpoch` changed): `image.detach` what was attached, then M1's
   `withdrawStoppedSend` (`LiveChatSession.swift:700-712`) with the attachments returned, reason "Stopped before
   sending".
10. **Leaving the chat** (back, opening another chat, the app going to the background) never cancels steps 1–7: the
    pipeline belongs to the chat's `LiveChatSession`, which keeps it alive until it ends, and every call names that
    chat's runtime and profile. The owner "sent a message to a bot, left the page, found it was never sent" — twice
    (`M:send-lost-on-leave.md`), and the web had to stop its drift guard dropping "a send whose attachments were still
    uploading when another chat opened" (`M:voice-memo-bugs.md`; `R:build/ui-chat-send-gates.ts:127-136`).

### 6.5 What must never happen

- A photo attached to runtime R and the prompt submitted to R' (fixed by A5).
- Photos left in `attached_images` after a withdrawn send (fixed by A6).
- Any attach RPC while the chat's turn is running (the queue guarantees it).
- A resend after an unconfirmed `prompt.submit` (M1 rule, spec 04 §2.5).
- Param keys other than §3.4/§3.5/§3.7/§3.8's.

### 6.6 Retention (local files) and background

- A local staging folder is kept while any owner references it (`R:src/attachment-retention.ts:8-62`): a draft (any
  chat), a queued message, a send in the pipeline (a lease), a preview or share sheet showing it, or an optimistic
  message not yet seeded into the media cache. When the last owner lets go, delete it after 1 s
  (`PickedFiles.swift:122-129`).
- Launch sweep (utility queue, after first paint): delete folders under the account roots that no owner references
  and that are older than 600 s (`PickedFiles.swift:92-111`; FileTimestamp reason `C617.1` is already in
  `N:App/Resources/PrivacyInfo.xcprivacy`).
- Drafts store: `Application Support/drafts/<account key hash>.json`, `{"v":1,"chats":{scope:{text,attachments,updatedAt}}}`,
  newest 50 chats (`R:src/attachment-drafts.ts:54-69`), written atomically 0.5 s after the last change (off main),
  read synchronously when a chat opens (small). On restore: `preparing`/`uploading` → `waiting`; `uploaded` kept;
  an attachment whose local file is gone is dropped. **Text drafts persist with them** (M1 keeps none; if another
  stream adds text drafts, merge into this store).
- Sign-out / account removal: cancel uploads and pipelines, delete the account's staging root, drafts file and media
  cache. Gateway staging folders of unsent drafts stay (unreachable after sign-out).
- Background: wrap each running pipeline and the current upload in `UIApplication.beginBackgroundTask`. If iOS
  expires it, cancel the upload; the message stays **Sending…** and its pipeline restarts at step 3 on the next
  foreground (nothing was submitted, so nothing can double). A `prompt.submit` already sent follows M1's
  unconfirmed path.

---

## 7. History: what rows carry and how they draw

### 7.1 Hydration changes (`N:HermesKit/Chat/Hydration.swift`)

User rows (today: `extractImageRefs` keeps whole lines, `splitLeadingAttachmentRefs` lifts leading `@file:`/`@folder:`
lines, image parts become `""`, stray data URIs become `[image]`: `Hydration.swift:149-164,230-255,682-688`):

1. **Image refs:** a line (trailing whitespace trimmed) matching
   ``^@image:(`[^`\n]+`|"[^"\n]+"|'[^'\n]+'|\S+)$`` (Hermes' own form, `H:tui_gateway/session_history.py:133`) is an
   image; strip one pair of surrounding quotes from the value. Keep the raw line in `attachmentRefs` (cache
   compatibility) **and** a parsed `MessageAttachment` (§7.2).
2. **Older native-vision hints:** a line exactly `[Image attached at: <path>]` (`session_history.py:131`) is an image
   too (native improvement; the web shows the line as text).
3. Drop `[screenshot]` and `[image]` lines only when the row has ≥ 1 image (they describe the same pictures:
   `session_history.py:136-148`; `inline_images=false` renders parts as `[image]`, `session_history.py:111-128`).
4. Leading `@file:`/`@folder:` lines → file attachments (today's rule, `Hydration.swift:244-255`), quotes stripped.
5. **Non-voice `MEDIA:` lines in your rows** (`MEDIA:<path>` or `MEDIA:"<path>"` on its own line): image extension →
   image attachment, else file attachment — after `VoiceMemo.parse` had its chance (voice memos stay voice bubbles).
6. **Content arrays:** for each part with `type ∈ {image_url, input_image, image}` or an `image_url` key
   (`Hydration.swift:149-152`), take `image_url.url` (object or string) or `url`:
   - `data:image/<t>;base64,…` → decode **during the off-main fold** (`HistoryAPI.fetchAndFold` and
     `LiveChatSession.foldOffMain` are already off main: `N:HermesKit/Chat/HistoryAPI.swift:180-189`,
     `N:HermesKit/Chat/LiveChatSession+Sync.swift:315-316`) into the media store (§8.1) under
     `(account, profile, stored id, row id, part index)`; read pixel size from the image header; the part's string is
     dropped and never reaches text, the transcript cache or markdown (spec 03 §6.6). Decoded > 32 MB → a
     "Photo too large to load" attachment.
   - `https:` → remote source (§8.4); an absolute path → gateway source.
   - **Pairing:** when the row's text holds N image refs and the array holds exactly N image parts (Hermes' native-vision
     persisted form, `session_history.py:63-75,150-200`), attachment *i* = ref *i*'s path **with** part *i*'s decoded
     bytes (shown once, named from the path, no download). Otherwise: the refs first, then the extra parts.
7. **Display text key** (fixes a duplicate-bubble bug once files exist): add `Hydration.userDisplayKey(_ text:) =
   ChatText.flat(` of the text after rules 1–5 `)`, and use it in place of
   `ChatText.flat(Hydration.extractImageRefs(x).cleaned)` at `LiveChatSession+Sync.swift:105,300,307,552-553` and in
   the queued-prompt check at `:540-541`. The resume snapshot's `inflight.user` is the *submitted* text (leading
   `@file:` lines, no `@image:` lines), the stored row has both, the local bubble has neither; all three must give the
   same key.
8. **Default question (A4):** a user message whose display text equals `What do you see in this image?` and that has
   ≥ 1 image attachment draws no text (the bubble is media only). Its key stays the question (so matching works).

Assistant rows: unchanged in hydration (media lives in the markdown, §7.5). Tool details gain the `image_generate`
result (§7.7).

### 7.2 `MessageAttachment` and the cache

```swift
nonisolated struct MessageAttachment: Hashable, Sendable {
    enum Kind: UInt8, Sendable { case image, file, folder }
    enum Source: Hashable, Sendable {
        case gateway(path: String)          // @image:/@file:/MEDIA path (absolute or session-relative)
        case inline(mediaKey: String)       // decoded data: part, bytes in the media store
        case local(draftId: String)         // your send from this phone, before the media cache is seeded
        case remote(URL)                    // https image
        case tooLarge                       // known image, no bytes we can show
    }
    var kind: Kind
    var source: Source
    var name: String                        // last path component; "Photo" when none
    var pixelWidth: Int?, pixelHeight: Int?
    var byteSize: Int64?
}
```

- `MessageMeta` gains `attachments: [MessageAttachment]` (`N:HermesKit/Chat/ChatMeta.swift:49-66`).
- Transcript cache: bump the magic to **`HQT2`** (`N:HermesKit/Store/TranscriptCoding.swift:119`); after
  `attachmentRefs` write the attachments (kind byte, source tag + string, name, optional dims, optional size) and the
  `image_generate` result of each tool detail (§7.7). An `HQT1` entry must read as a **miss** (fresh read), never a
  crash. No image bytes, no data URIs, no local file paths survive into the cache: `.local` is written as the gateway
  path it was uploaded to (known from the draft), or skipped if the upload never finished.
- Pixel sizes learnt by loading an image (§8.3) are written back into the message's attachment, so the next cache paint
  has exact heights.

### 7.3 Your bubble with attachments (Telegram shape, A7)

Spec 06 §2 applies (fill, radius 18, run corners 6, tail, one time per run, max width `min(80 %, 320 pt)`):

- **Order inside the bubble:** the photo (or the photo stack) at the top, edge to edge (no padding), clipped to the
  bubble's outline;
  then file rows; then the caption text with the normal 6/12 padding (6 pt above it after media); the time sits in the
  caption's last line as today.
- **Photo-only message** (no files, no shown text): no fill; the photo(s) clipped to the bubble outline including run
  corners; **no tail**; the run's time, when this bubble ends the run, is a capsule at the bottom-trailing corner
  (6 pt inset; Caption 2 white on black 45 %, 4/7 pt padding). This capsule is a plain dim shape, not glass.
- **Files-only message** (the web's "chip-only turn", `user-message.tsx:365,398-402`): file rows only, time in the last
  row's trailing bottom.
- **Single photo frame** (`maxW` = the bubble's max width): `w = min(maxW, 260)`; `h = w × ph / pw`; if `h > 320`:
  `h = 320`, `w = max(150, min(maxW, 320 × pw / ph))`; if `h < 100`: `h = 100`. Draw aspect-fill inside `(w, h)`.
  Unknown size: `(min(maxW, 260), 195)`.
- **Photo stacks** (2 or more photos; owner 2026-10-30, replacing the album grid in bubbles): the photos sit on top of
  each other as cards you swipe through (`N:App/Chat/Attachments/PhotoStackView.swift`).
  - **One box** for the stack (`MediaLayout.stack`), so the row never changes height while you flip: the single
    photo frame above for the photos' middle shape (the median aspect; an even count takes the two middle ones'
    geometric mean); unknown sizes give the 4:3 `min(maxW, 260) × 195` box. **Each card is its own photo's shape**
    fitted in the box and centred on whole points (`PhotoStackView.cardSize`), so mixed shapes pile up like prints,
    never letterboxed; a card is never under half the box either way, and a photo narrower than that shows whole
    (aspect-fit) on a blurred fill of itself. The photo-only time capsule and the Mac's ‹ › sit on the top card (they
    move to the next one's corner while faded out mid-flip).
  - **The fan:** the two cards under the top one turn a few degrees either way, sized from the box so their corners
    stay within 10 pt (`stackPadY`) above and below and ~10 pt beside. In a bubble with a caption or file rows the stack
    keeps that room inside the bubble; a photo-only stack has no fill and the room is the row's.
  - **Swipe left:** the top card follows the finger, tilting from where it was held (up to 12° over a card's width),
    flies off and tucks in at the back. **Swipe right:** the bottom card slides out and lands on top. A flip needs 28 %
    of the card's width or a 450 pt/s flick; less springs back. It goes round (after the last photo, the first). One
    selection tick per flip.
  - **Each card** shows **"2/5"** (11 pt semibold digits white on a black 45 % capsule, top-trailing, 6 pt in and further past
    a round corner). The photo-only time
    capsule sits on the top card and fades while a card is mid-flip.
  - **Tap** opens the viewer on the top photo; closing the viewer on another photo leaves that one on top, so the zoom
    lands on it. The top photo is remembered per message while the app runs (scroll away and back keeps it).
  - **Hold menu, drag out, upload rings and failure tiles** are the top card's (each card is a normal tile).
  - **Mac:** a trackpad's two-finger swipe flips (a click-drag still drags the photo out); hovering shows ‹ › buttons
    at the top card's sides.
  - **VoiceOver:** one adjustable element, **"5 photos"**, value **"2 of 5, Photo, <name>"**; swipe up/down flips; activate opens the viewer.
  - **Reduce Motion:** the photos cross-fade instead of flying.
  - `MediaLayout.frames` still lays out the old album grid (2 → two squares; 3 → one `w × w/2` over two; 4 → 2 × 2;
    ≥ 5 → rows of 3), now used only for single photos.
- **File row:** 40 pt circle (your bubble: white 22 % fill, white glyph; bot bubble: tint 15 % fill, tint glyph) with
  the kind glyph (§7.6); name Subheadline 15 semibold in the bubble's text colour, up to 2 lines, middle-truncated;
  detail Caption 1 in the bubble's secondary colour (`ChatPalette.meTime` on yours, label-2 on a bot's):
  **"PDF · 2.4 MB"**, **"PDF"** when the size is unknown, **"Downloading… 40 %"** while it downloads; 12 pt
  top/bottom padding (`M:row-padding-feedback.md`), 12 pt leading, 10 pt between circle and text, 4 pt between rows.
  `@folder:` rows use the `folder` glyph and are not tappable (long-press: Copy Path).
- **Upload ring** on each photo of a sending message: as the tray's (§6.2), centred on the cell.
- **Sending…** / **Delivery Unconfirmed · Check** under the bubble: unchanged (spec 06 §5.6.4).
- Accessibility: one element per photo, label **"Photo, <name>"** (`R:src/fe-convo-r3.ts:542-546` gives "Photo" when
  there is no name), hint "Opens the photo"; file rows "File, report.pdf, PDF, 2.4 MB"; the caption keeps "You said:".
  Identifiers `chat.media.<message id>.<index>`, `chat.file.<message id>.<index>`.

### 7.4 Loading, failure and retry for an image in a bubble

- **Placeholder:** the cell's exact frame in Fill 3; after 0.6 s a 16 pt activity indicator.
- **Failure tile** (same frame, `R:src/fe-convo-r2-ui.tsx:14-40`, `R:src/phone-fe-convo.css:311-314`): 1 pt dashed
  separator border, radius 14, 5 % label fill, `arrow.clockwise` 22 pt, **"Couldn't load photo"** (Subheadline 14
  medium, label), **"Tap to try again"** (Footnote 13, tint), the file name (Caption 1 12, label-3, one line); below 120 pt
  height only the glyph. VoiceOver **"Couldn't load <name>. Tap to try again."**
- **Automatic retry, once per trigger** (r2-12): the gateway reconnects (`gateway.ready`), the app returns to the
  foreground, or the tile scrolls back into view after leaving it. A tap retries any time.
- **Too large** (`.tooLarge`, or the download passes 32 MB): **"Photo too large to load"** (spec 03 §6.6's words) /
  **"Tap to open"** — the
  tap downloads it as a file (512 MB cap) and opens Quick Look.

### 7.5 Bot replies: media inside markdown

`MarkdownPreprocess` already turns `MEDIA:/path` into `[Kind: name](#media:<percent-encoded path>)`
(`N:App/Chat/Render/MarkdownRenderer.swift:633-690`; spec 03 §9.4). The renderer changes:

- A **paragraph whose only content is media** — `#media:` links, images `![alt](src)`, file-path links (`/…`, `~/…`,
  `file://…`, `C:\…`, `V:components/assistant-ui/markdown-text.tsx:320-341`), separated by whitespace or line breaks —
  becomes a new `MarkdownBlock.media([MediaRef])`: images → photos (single/stack rules of §7.3 with
  `maxW = min(bubble content width, 280)`, radius 12, inset like code blocks) and everything else → file rows.
  Media blocks next to each other (pictures listed one per paragraph or list item) join into one block, so a reply's
  pictures make one stack. Reply pictures arrive without pixel sizes: the first load reports each one's size
  (`ChatMediaSnapshot.replySizes`, keyed by `MessageAttachment.sizeKey`), and the next layout takes its real shape
  (the row changes height once, as history photos do).
  A reply part whose blocks are **only** images draws like a photo-only bubble (no fill).
- **Inline** media in a sentence stays a link (link colour) with a leading 13 pt SF Symbol (`photo` / `doc`);
  tap → the viewer or file preview. Today it is a dead link (`N:App/Chat/ChatViewController.swift:1847-1850` opens
  only http/https/mailto/tel) and images show as "🖼 alt" (`MarkdownRenderer.swift:535-539`).
- Kind by extension (`V:lib/media.ts:19-48`, with ImageIO's extras): image `png jpg jpeg gif webp bmp heic heif tif
  tiff`; video `mp4 mov m4v webm mkv avi`; audio `mp3 m4a wav ogg opus flac aac`; `svg` and everything else → file.
  `MarkdownPreprocess.mediaKind` (`MarkdownRenderer.swift:697-703`) must use this table (today it calls `.svg` an image).
- `![alt](https://…)` → remote (§8.4); `![alt](/path)` → gateway; `![alt](data:image/…)` → decoded off main (≤ 8 MB).
  `alt` is the VoiceOver label.
- Markdown documents (`.md`) are file rows ("Open preview" in the web, `markdown-text.tsx:284-305`): Quick Look shows
  them as text.

**DECISION (2026-10-26, tester ivy: "when the agent sends an image it just appears as a path"; brief
`docs/briefs/agent-images-markdown.md`).**

- *Cause.* HQ's `session.create` sent no `source`, so Hermes ran every chat HQ started as the terminal UI
  (`H:tui_gateway/agent_factory.py` `_resolve_session_platform`), whose system prompt says `MEDIA:` tags are not
  intercepted and to "deliver a file by stating its absolute path in plain text" (`H:agent/prompt_builder.py`
  PLATFORM_HINTS["tui"]). The web sends `source: "desktop"` (`V:app/session/hooks/use-session-actions/index.ts:364-366`).
  **`SessionCreate.params` now always sends `source: "desktop"`** (a caller's own `source` stays). Chats made before
  this keep their old prompt, so the renderer also handles what they write (next two points).
- *`MEDIA:` tags at web parity* (`HermesKit/Chat/Transcript/MediaTags.swift`, a port of `V:lib/chat-messages/parts.ts`
  `renderMediaTags`): quoted values (`"…"`, `'…'`, `` `…` ``), unquoted paths with spaces up to a known delivery
  extension, `C:\…` paths, relative paths (read with the session, A8), `https:` URLs, trailing sentence punctuation left
  outside, a bare word stays prose. Before, a quoted path with a space split into a broken link.
- *Bare picture paths (beyond the web, A16).* Outside code fences, an absolute path (`/…`, `~/…`, `C:\…`) ending in a
  picture extension (`png jpg jpeg gif webp bmp heic heif tif tiff`): alone on its line (or alone in one code span)
  it is the picture; inside a sentence it becomes a tappable name with a photo glyph and the picture follows the line
  as its own paragraph (not in a list item, quote, table row or heading, which a following paragraph would break).
  URLs, link targets, relative paths, code spans holding more than the path, and non-picture files stay text. The web
  draws these as text; the agent was told to write them, so HQ shows them.
- *A picture the gateway refuses* (`/api/fs/download` 404, or 403 for a private file) becomes a file row named by the
  file, detail **"Image · not on your gateway"** / **"Image · your gateway keeps this file private"**, never the path
  (`MediaTileView` → `noteMediaUnavailable` → `ChatMediaSnapshot.unavailable` → `AttachmentBubbleLayout.mediaBlock`).
  Other failures keep the retry tile. VoiceOver reads a reply's files by name (`MediaTags.forSpeech`).
- *Safety unchanged (A15):* gateway paths load only through the gateway connection (`/api/fs/download` with the
  account's auth); `https:` pictures through `RemoteImageFetcher` (public internet only). Nothing in the text makes the
  phone fetch an arbitrary LAN or Tailscale address.
- Tests: `Tests/Chat/AgentImagesMarkdownTests.swift`; e2e `test17_AgentImagesAndYourMarkdown` on
  `/__fixture/agent-images-history`; screenshots `docs/briefs/refs/{before,after}-ai{1,2}-agent-images-*-{light,dark}.png`.

### 7.6 Kind glyphs

`photo` (image), `film` (video), `waveform` (audio), `doc.richtext` (pdf), `doc.text` (txt, md, csv, json, code),
`tablecells` (xls, xlsx, numbers, csv), `archivebox` (zip, tar, gz, 7z), `folder` (`@folder:`), `doc` otherwise.

### 7.7 `image_generate` card

Today the tool is a stand-alone generic step (`N:App/Chat/ChatRow.swift:393`;
`N:HermesKit/Chat/ToolPresentation.swift:13-14`). This stream builds the card of spec 03 §8.9
(`V:components/chat/generated-image-result.tsx`; `V:lib/generated-images.ts:51-80`):

- New row kind `.generatedImage(GeneratedImageRow)` in place of the generic step, not in a bubble, leading-aligned.
- **Frame:** `w = min(column, 320)`; aspect from `args.aspect_ratio`: `landscape` 16:9 (default), `square` 1:1,
  `portrait` 9:16; if `h > 400`: `h = 400`, `w = 400 × aspect`. When the result has `pixel_size "WxH"`, use that
  aspect instead. Radius 18.
- **Live** (turn running, no result): Fill 3 with a slow shimmer (static under Reduce Motion), centred `photo` glyph
  label-3; VoiceOver **"Rendering image"**.
- **Settled success** (`result` an object, or a JSON string of one, with `success != false` and `host_image ?? image`
  a string, `V:lib/generated-images.ts:60-71`; `H:tools/image_generation_tool.py:330-361`): load it — a path through
  §8.3, an `https:` URL through §8.4 — fade in over 0.2 s; tap → the viewer; long-press → §9.6.
- **Load failure of a good result:** collapse to a link row **"Open image: <name>"**; `https:` opens in Safari
  (`UIApplication.open`), a path opens the file preview (§10) (`R:build/fe-convo-gates.ts:94-96`).
- **Failed generation** (`success == false`, or the call failed) and **settled without a result** → the existing failed
  / generic step, unchanged.
- Data: `ToolDetail` gains `generatedImage: GeneratedImageInfo?` `{source: path or URL, pixelWidth?, pixelHeight?,
  aspectHint, success}` filled from the stored tool row (hydration) and from `tool.complete`'s `result` (live), kept in
  the slimmed cache copy (it is small).
- Echoes: when a reply part repeats the generated image's path/URL (`host_image`, `image`, `agent_visible_image`),
  drop that media from the prose (`V:lib/generated-images.ts:87-125`), so it shows once.

### 7.8 Rows, heights and updates (native architecture rules)

- `BubbleRow` gains `media: [MediaItem]` and `files: [FileItem]` (built in `ChatRowBuilder` from
  `Input.attachments[messageId]`, a value snapshot taken with the messages; `N:App/Chat/ChatRow.swift:152-167,276-320`).
  `MediaItem = {key, source, name, pixel size?}`; `FileItem = {key, kind, name, detail, path?}`.
- Every height is exact and known **before** any pixel loads (`N:docs/ARCHITECTURE.md`: "every height comes from
  `TextLayout`"): the frames come from §7.3/§7.5/§7.7 and the stored dims. `TextLayout` gets a pure
  `MediaLayout.frames(items:maxWidth:)` (unit-tested).
- A row whose size was unknown and whose real size is learnt (§8.3) is re-laid out **while it is more than one screen
  away** when possible (loads start one screen ahead). If it is on screen, its height changes without animation; the
  inverted table keeps everything below it still (it grows upward).
- Fingerprints include sources, names, dims and kinds — **not** progress. Upload/download progress reaches the cell
  directly through a `TransferProgressCenter` (keyed by draft id or download key) that the visible cell observes; it
  never rebuilds rows or calls `performBatchUpdates`.
- The local → stored switch of your sent message keeps its row id (M1 keeps local ids for turns sent here,
  `N:docs/ARCHITECTURE.md` "Unread" note); its attachments switch from `.local` to `.gateway(path)` only after the
  media cache holds the seeded file, so the cell finds the same picture synchronously and never shows a placeholder.

---

## 8. Media store and loaders

### 8.1 Media store

- Disk: `Caches/HQNMedia/<account key hash>/` with `originals/<sha256(key)>.<ext>` and `files/<sha256(key)>/<name>`,
  LRU by bytes, **256 MiB** total (spec 03 §6.6), files > 64 MB are not kept after their preview closes. Purged with
  the transcript cache on sign-out and gateway removal.
- Memory: `NSCache` of decoded `UIImage` thumbnails, total cost 64 MB (bytes), emptied on memory warnings.
- Keys: gateway `"g|<account>|<profile>|<path>"`; inline `"i|<account>|<profile>|<stored id>|<row id>|<part>"`; remote
  `"r|<url>"`. Thumbnails per key and pixel bucket (256, 512, 1024, 2048).
- `seed(gatewayPath:profile:fromLocal:)` moves your prepared file in as the original and puts its tile thumbnail into
  memory under the gateway key (§6.4 step 7).

### 8.2 Gateway download

```
GET /api/fs/download?path=<path>&profile=<owner profile>[&session_id=<stored session id>]
```

- `session_id` **only** when the path is relative (doesn't start with `/`, `~`, `file:` or a drive letter): Hermes then
  resolves it against the session's cwd; with an absolute path it still looks the session up and answers
  `404 "Session not found"` if it can't (`H:hermes_cli/web_routers/files.py:891-904`). (Refines spec 03 §6.6, A8.)
- Hermes (`files.py:933-961`): a profile with a remote backend streams from that backend; else a `FileResponse` with
  `Content-Disposition: attachment`, Range supported. Errors: `404 "File not found"`, `400 "Path points to a
  directory"`, `403 "Access to sensitive files is not allowed"` (`.env`, `auth.json`, `config.yaml`…,
  `files.py:62-107`), `409` (a live database), `401`.
- `GatewayClient.download(…)` (§13.1) writes to a file on the bulk pool with a byte ceiling (32 MB for images, 512 MB
  for file previews), returns the `HTTPURLResponse` (MIME type); never buffers the body in memory.
- Priority and concurrency: at most **3** downloads per account at once; the queue is ordered by distance to the
  viewport; a load is started when its row is within one screen and cancelled when it is more than two screens away
  (a cancelled partial file is deleted). Task priority low for prefetch, high for on-screen.
- Decoding: ImageIO thumbnail at `display points × screen scale` (bucketed) on a detached task; never
  `UIImage(contentsOfFile:)` on main. Images over 100 MP are refused (`HermesPicker.swift:299-303`).

### 8.3 Learning dimensions

`CGImageSourceCopyPropertiesAtIndex(… 0 …)` on the downloaded original (pixel width/height + orientation) before
decoding; write back to the message attachment (§7.2).

### 8.4 Remote https images

Own ephemeral `URLSession`: no cookies, no credentials, no cache, timeouts 20 s request / 60 s resource, ≤ 4
connections per host, `Accept: image/*` (`HermesPicker.swift:238-254`). Allowed only when the URL is `https` and its
host resolves only to public addresses (refuse loopback, RFC 1918, link-local, CGNAT 100.64/10 — Tailscale —,
`fc00::/7`, `::1`, `fd7a:115c:a1e0::/48`, `.local`, `.ts.net`, IP literals of those) — before the request and on every
redirect (≤ 5, each re-checked; `HermesPicker.swift:256-279`). The answer must be `image/*`, ≤ 32 MB, ≤ 100 MP;
`image/svg+xml` is refused (shown as a link). Never send the gateway's cookies or bearer to these hosts.

---

## 9. Image viewer

### 9.1 Presentation

- `MediaViewerController` presented full screen with `preferredTransition = .zoom(sourceViewProvider:)` (public API,
  iOS 18+) from the tapped cell's image view. The system gives the interactive dismissal (swipe down, pinch in) and the
  zoom back into the cell. Allow interactive dismissal only at the minimum zoom scale
  (`zoomOptions.interactiveDismissShouldBegin`).
- Background black; status bar hidden while the chrome is hidden.
- Pages: a `UIPageViewController` (horizontal, 12 pt spacing) over the **tapped message's** photos (or the reply
  part's), starting at the tapped one. The title reads **"2 of 3"** when there is more than one.

### 9.2 Zoom and gestures

Per page a `UIScrollView` (`minimumZoomScale` = aspect-fit, `maximumZoomScale` = 5 × fit, `bouncesZoom`), image
centred while smaller than the screen. Double-tap toggles between fit and **2.5×** centred on the tap point; a single
tap (after the double-tap window, 320 ms) toggles the chrome (`R:src/image-zoom.ts:41-108`). The chat itself never
pinch-zooms (the owner kept page pinch-zoom off, `M:finish-everything-push.md`).

### 9.3 Chrome (system bars, glass by the system)

- Navigation bar: leading **close** (`UIBarButtonItem(systemItem: .close)`, label "Close", id `viewer.close`); title.
- Bottom toolbar: **Share** (`square.and.arrow.up`, id `viewer.share`) leading; **Save** (`square.and.arrow.down`,
  label "Save", id `viewer.save`) trailing. The web's viewer bar has Share and Done (`R:build/fe-convo-gates.ts:754-756`;
  `R:build/audit-b-gates.ts:44-46`).
- Image quality: shows the cell's thumbnail at once, then the original decoded to at most `screen pixels × 3`
  (≤ 4096 px), loading it if needed (32 MB cap); an indicator only if that takes > 0.6 s.

### 9.4 Save

`PHPhotoLibrary.requestAuthorization(for: .addOnly)`; `PHAssetCreationRequest.forAsset().addResource(with: .photo,
fileURL: original, options: nil)` (original bytes; the web's `HermesUIPages.swift:42-65`). Success: the button swaps to
`checkmark` with label **"Saved"** for 1.8 s (`R:src/fe-convo-r2-ui.tsx:42-53`) and plays `notification.success`.
Denied: alert **"Allow HQ Native to add photos in Settings, then try again."** with Open Settings
(`HermesUIPages.swift:55`). `NSPhotoLibraryAddUsageDescription` = **"Save images from your chats to Photos."**
(`R:ios/App/App/Info.plist:28`).

### 9.5 Share

`UIActivityViewController` with a temporary copy named after the image (`R:src/image-names.ts:5-30`: the gateway file's
name, extension matching the bytes; `image.<ext>` when unknown), kept until the sheet closes. The sheet's own "Save
Image" also works.

### 9.6 Long-press on an image in the chat

`UIContextMenuInteraction` with the image as preview: **Save to Photos**, **Share…**, **Copy** (image data with its
type on `UIPasteboard`). Haptic as spec 06 §9 (the menu's own). Your sent photos carry no Save badge
(`R:src/phone-fe-convo.css:397-399`: "the viewer and a long press save it").

---

## 10. File preview

- Tap a file row (history, a bot's file link, a tray tile) → if the media store holds the file, present
  `QLPreviewController` at once; else download (§8.2, ceiling **512 MB**) with the row's detail reading
  **"Downloading… 40 %"**; a second tap cancels (**"Cancelled"** for 1.5 s, then the normal detail).
- When downloaded: `QLPreviewController.canPreview(url)` → present it (its own share button stays); else the share
  sheet on the same copy (`R:ios/App/App/HermesPreview.swift:20-50`). The copy is named after the gateway path
  (`R:ios/App/App/HermesNativeExtras.swift:105-118`: an extension from the MIME type when the name has none).
- Errors → alert **"Couldn't Open File"** with:
  - over the cap: **"This file is larger than 512 MB, the most HQ Native can open."** (`HermesNative.swift:2934-2937`);
  - 404: **"This file isn’t on your gateway anymore."**;
  - 403: **"Your gateway keeps this file private."**;
  - network: **"Couldn’t reach your gateway. Try again."**
- Long-press a file row: **Open**, **Share…**, **Copy Path** (the gateway path or ref, so it can be pasted into a message).
- Local tray files preview from the phone's copy (no download).

---

## 11. Every UI state (summary)

| Where | State | What shows |
|---|---|---|
| + menu | normal / Simulator / 16 attached | 3 pickers + Paste Image when the pasteboard has an image / Camera "Unavailable" / pickers "Limit reached" |
| Tray tile | preparing · waiting · uploading · uploaded · failed | §6.2 table |
| Send button | text or attachments, none preparing, connected | enabled; else disabled (M1 look) |
| Your new bubble | uploading | photos with rings, file rows "Uploading… 40 %" detail ("Waiting to upload" before it starts), caption |
| Your new bubble | waiting in queue | queue card row (text or "2 Photos"), no bubble yet (M1 queue rule) |
| Your new bubble | sent, not acknowledged > 2 s | "Sending…" (spec 06 §5.6.4) |
| Your new bubble | refused | bubble gone, error card with the reason, draft back in the composer |
| Your new bubble | delivery unconfirmed | "Delivery Unconfirmed · Check" (M1) |
| History photo | loading · loaded · failed · too large | placeholder (+ indicator after 0.6 s) · picture · retry tile · "Photo too large to load / Tap to open" |
| History file row | idle · downloading · cancelled | "PDF · 2.4 MB" · "Downloading… 40 %" · "Cancelled" |
| Generated image | live · loaded · load failed · generation failed | shimmer frame "Rendering image" · picture · "Open image: <name>" · failed step |
| Viewer | loading original · saved · save denied | thumbnail + indicator after 0.6 s · "Saved" 1.8 s · Settings alert |
| File preview | not previewable | share sheet |

---

## 12. The owner's approved behaviour (from memory)

- **Bubbles, Telegram shapes, Hermes colours.** "I'm used to using Telegram and I love how the chat bubbles look
  there." (`M:chat-bubbles-telegram.md`). But "abandon the telegram chat themes… i don't like them" and "Never bring
  back the Telegram colour theme." (`M:telegram-look-hold.md`) — so A7 copies Telegram's *media bubble shape* only: no
  wallpaper, no green bubble, no ✓✓.
- **File card.** The agreed chat refinement was a "file card collapsed, with copy in the header and no duplicate
  "files changed" card" (`M:chat-bubbles-telegram.md`). That line is about the file-edit (changed files) card; this
  stream applies its principle to attachments: one compact row per file, no second "Download"/"Open preview" button
  pair like the desktop card (`V:components/chat/preview-attachment.tsx:247-301`), and long-press for the rest.
- **Leaving the chat never loses a send.** "Owner (2026-10-07, twice): sent a message to a bot, left the page, found it
  was never sent." (`M:send-lost-on-leave.md`); "the renderer's drift guard … dropped a send whose attachments were
  still uploading when another chat opened. Gates … let it finish to its pinned chat." (`M:voice-memo-bugs.md`). §6.4
  step 10.
- **Native glass only.** "It isn't Liquid Glass. So much of this is wrong." … "do not ship CSS imitations of it
  again" (`M:liquid-glass.md`). The + is a system glass circle; tray tiles, file rows and the failure tile are opaque;
  the viewer uses system bars.
- **Opaque attachment tiles.** The web's tile "was half see-through and let the transcript read straight through the
  tile and its name (owner, 2026-10-06)" (`R:src/phone-ui-chat.css:401-405`).
- **Padding.** "Any cell whose text can wrap gets explicit vertical padding: about 12–14pt top and bottom" and "Keep a
  trailing action visually separate from wrapping text" (`M:row-padding-feedback.md`) — file rows and file tiles.
- **iOS conventions.** "Prefer iOS conventions (full-screen lists, back buttons, large titles, long-press menus, no
  hover-only controls, no touch drags)" (`M:ios-native-ux-goal.md`) — context menus on photos and files, Quick Look,
  the system zoom transition.
- **Hermes is not ours.** "We can't make any changes to hermes agent code since we don't control it."
  (`M:hermes-code-not-ours.md`) — every limit here (photos left in the staging folder, the 16-reference expansion cap)
  is handled phone-side.

---

## 13. Code map (what to add and change)

### 13.1 Contracts (`N:HermesKit/Contracts.swift`; integration-owned — keep defaults so other streams' fakes compile)

```swift
nonisolated protocol GatewayClient {
    …
    /// POST a body file (multipart built on disk) with this account's auth; 401 → refresh once → re-send the file.
    /// Throws HTTPError for non-2xx (body ≤ 64 KiB), GatewayFailure for transport/session failures.
    func upload(_ path: String, query: [URLQueryItem], contentType: String, bodyFile: URL,
                progress: (@Sendable (_ sent: Int64, _ total: Int64) -> Void)?) async throws -> Data
    /// GET into `file` (never into memory), past `ceiling` bytes → GatewayFailure.responseTooLarge (partial file removed).
    func download(_ path: String, query: [URLQueryItem], to file: URL, ceiling: Int, priority: Float,
                  progress: (@Sendable (_ received: Int64, _ expected: Int64) -> Void)?) async throws -> HTTPURLResponse
}
extension GatewayClient {   // fakes
    nonisolated func upload(…) async throws -> Data { throw HTTPError(status: 501, body: "upload not supported") }
    nonisolated func download(…) async throws -> HTTPURLResponse { throw HTTPError(status: 501, body: "download not supported") }
}
```

`LiveGatewayClient` implements both through `GatewayAuth` (same decoration and single-flight refresh as `send`,
`GatewayAuth.swift:66-122`) and `HTTPTransport` (an `uploadTask(with:fromFile:)` and a data task streaming into a
`FileHandle` with the collector's ceiling; both registered with `TransportDelegate`,
`N:HermesKit/Net/HTTPTransport.swift:124-197`, which gains `didSendBodyData`).

Chat-side protocols (adopted by `LiveChatSession`, the fakes and the demo):

```swift
protocol ChatAttachmentSending: AnyObject {
    func send(_ text: String, attachments: [DraftAttachment])
    func attachments(for messageId: String) -> [MessageAttachment]
}
// onDraftReturned gains attachments: ((_ text: String, _ attachments: [DraftAttachment], _ reason: String) -> Void)?
// QueuedMessage gains `attachments: [DraftAttachment]`; removeQueued returns (text, attachments).
```

### 13.2 New files

| File | What |
|---|---|
| `HermesKit/Attachments/AttachmentModels.swift` | `DraftAttachment`, `MessageAttachment`, `MediaRef`, `GeneratedImageInfo` |
| `HermesKit/Attachments/PhotoNormalizer.swift` | §5.1, §5.2 |
| `HermesKit/Attachments/VideoSanitizer.swift` | §5.3 |
| `HermesKit/Attachments/AttachmentStaging.swift` | §5.4–§5.5, owners/leases, sweep (§6.6) |
| `HermesKit/Attachments/MultipartBody.swift` | §3.3 body on disk |
| `HermesKit/Attachments/AttachmentUploader.swift` | per-account actor: root cache, serial uploads, retries, DELETE cleanup |
| `HermesKit/Attachments/AttachmentSender.swift` | attach RPCs, `promptText`, detach (§3.4–§3.8, §6.4 steps 5–7) |
| `HermesKit/Attachments/DraftStore.swift` | §6.6 drafts file |
| `HermesKit/Media/MediaStore.swift`, `MediaLoader.swift`, `RemoteImageFetcher.swift`, `TransferProgressCenter.swift` | §8 |
| `App/Chat/Attachments/ComposerPlusMenu.swift`, `AttachmentPickerCoordinator.swift`, `AttachmentTrayView.swift` | §4, §6.2 |
| `App/Chat/Attachments/MediaGridView.swift`, `FileRowView.swift`, `GeneratedImageCell.swift`, `PhotoRetryTile.swift` | §7 |
| `App/Chat/Viewer/MediaViewerController.swift`, `FilePreviewPresenter.swift` | §9, §10 |

### 13.3 Changed files

`Hydration.swift` (§7.1), `ChatMeta.swift` (§7.2), `TranscriptCoding.swift` (HQT2), `LiveChatSession.swift`
(send/queue/refuse/withdraw with attachments; the pipeline survives `stopObserving`), `LiveChatSession+Sync.swift`
(display key, §7.1 rule 7), `LiveChatSession+Events.swift` (`image_generate` `tool.complete` result),
`ChatRow.swift` / `ChatRowModel.swift` / `TextLayout.swift` / `ChatCells.swift` (media, files, generated image),
`MarkdownRenderer.swift` (§7.5), `ComposerView.swift` (+ and tray, paste), `ChatViewController.swift` (send with
attachments, taps, context menus, `chatCellOpen` for `#media:` and file links), `ChatQueueCard.swift` (attachment
summary), `AppModel.swift:363` (`onDraftReturned` with attachments), `App/Debug/DebugHooks.swift` (§15.3),
`App/Info.plist` (`NSCameraUsageDescription`, `NSPhotoLibraryAddUsageDescription`; no `NSPhotoLibraryUsageDescription` —
PHPicker needs none).

### 13.4 Cross-stream seams (agree at `m2/integrate`)

| Seam | Other stream's spec | Rule |
|---|---|---|
| Managed-files staging (root read, multipart upload, `DELETE`) | Voice (`1x-voice.md` §2.2 "⚑ Cross-stream", §4.2: `GatewayTransfers` + `AttachmentStager`) | **One** implementation: `AttachmentStager` in `HermesKit/Attachments/` with `stage(file: URL, name: String, profile: String, progress:) async throws -> StagedFile {path, folder}` and `release(folder:profile:)`, built on `GatewayClient.upload` (§13.1, file-streamed, progress). Voice's `MemoUploader` calls it; a Data-body `rest(contentType:)` variant is then unnecessary. Whichever stream lands first writes it; the other adapts. |
| Picked **audio** files | Voice (`1x-voice.md` §7: "The attachments stream owns picked files. It should call this stream's `MemoUploader` transcription step") | An audio file (`m4a mp3 wav aac ogg opus flac aiff caf`) from Files is **not** eager-uploaded (the web waits for Send so the paid speech-to-text runs once: `R:src/eager-upload.ts:12-18`); at Send it goes through `MemoUploader` (stage + `file.attach` + transcription) and its prompt reference becomes `MEDIA:"<path>"\n\nVoice memo transcript: …` instead of the `@file:` line (`R:src/voice-memo.ts:171-200`). Until the voice stream lands, audio files go as plain files. |
| Memo chip vs the tray | Voice (`1x-voice.md`: "the attachments stream will add a tray above the field") | The tray (§6.2) hosts the memo chip as its first tile when both exist. |
| Media loading for transcript cards | Activity (`1x-activity.md` §3.3) | Provide exactly `MediaLoader.image(path: String, profile: String, sessionId: String?, maxPixel: Int) async throws -> UIImage` (§8.2 rules: `sessionId` used only for relative paths) and the viewer entry `MediaViewer.present(from: UIView, items: [MediaRef], index: Int)`. |
| + menu items | Menus / voice | `ComposerPlusMenu` slots (§4.1). |
| `onDraftReturned`, `QueuedMessage` | Voice adds `memo: MemoFile?` to `QueuedMessage` (`1x-voice.md` §2.2) | Both fields coexist; `removeQueued` returns text, attachments and memo. |

---

## 14. Stand-in gateways

### 14.1 What the existing fixtures cover (and don't)

| Piece | Stock fixture | Status |
|---|---|---|
| `GET /api/files`, `POST /api/files/upload-stream`, `DELETE /api/files` | action-voice and everything built on it (`R:scripts/action-voice-fixture-gateway.py:144,171-187`) | **works** (captured §3.2–§3.3); upload accepts only `/fixture/uploads/…`; answers `{"path"}` without Hermes' other fields |
| `file.attach` | action-voice `:50` | fixed answer `/fixture/voice-memo.wav` whatever you send, no `uploaded` |
| `image.attach`, `image.detach` | none | answer `{}` (the catch-all, `:83`) → native's "didn't accept" path |
| `GET /api/fs/download` | `native-startup/fake-gateway.py:190-237` serves `--media-dir` with Range, **but** action-voice's `do_GET` never reaches it (`:130-166`) | answers `200 {}` (captured) — no history images on any stock chat fixture |
| Strict params (`4000`) | none | every stock fixture accepts unknown keys |
| Slow upload / failing attach | build47 `uploadDelay`, `attachFailures` (file.attach only) (`R:scripts/build47-fixture-gateway.py:69-75,194-204`) | partial |
| Images in history, `MEDIA:`, `image_generate` | none (replay has one PNG but needs a recorded store, spec 05 §A7) | — |
| Nous bearer on uploads | `nous-fixture-gateway.py` (build47 + bearer, REST gated) | upload/attach as action-voice; image.attach `{}` |

So this stream adds **one fixture** to this repo (the builder writes it; it imports the reference fixtures by path,
read-only, as they import each other):

### 14.2 New: `N:scripts/fixtures/attachments-gateway.py`

Loads `R:scripts/performance-fixture-gateway.py` as a module (`importlib`, like `performance` loads `build47`,
`R:scripts/performance-fixture-gateway.py:13-16`), keeps its sign-in, socket, streaming engine, plans, paging, Stop
and `/__fixture/history`, and adds the Hermes-shaped attachment surface. Loopback only; refuses ports outside
9700–9799; stdlib only; invented data; `--files DIR` (0700) holds uploads and generated media; credentials file 0600
as the others (`{"username","password","url"}`), never printed.

REST (all `/api/*` need the session cookie, as Hermes; 401 otherwise):

| Route | Behaviour |
|---|---|
| `GET /api/files` | `{"path":"/fixture/uploads","parent":"/fixture","entries":[],"root":null,"locked_root":null,"can_change_path":true}` |
| `POST /api/files/upload-stream` | parse the multipart (as `R:scripts/share-fixture-gateway.py:158-172`); `path` must start with `/fixture/uploads/` else 403 `{"detail":"Path outside managed files root"}`; exists + `overwrite` false → 409; > `maxBytes` (default 100 MB) → 413 `{"detail":"File is too large"}`; store under `--files`; answer Hermes' shape (§3.3) with `entry`; record `{path, filename, bytes, sha256, jpeg, png, gps, camera}` (`gps`: a TIFF/Exif tag `0x8825` (GPS IFD) present; `camera`: any of tags `0x010F` Make, `0x0110` Model, `0x9003` DateTimeOriginal present) |
| `DELETE /api/files` | body `{path, recursive}`; delete that folder under uploads; 404 when missing; record |
| `GET /api/fs/download?path=&profile=&session_id=` | serve uploads, attachment copies and seeded media with `Content-Type` by extension, `Content-Disposition: attachment`, Range (copy `fake-gateway.py:200-237`); 404 `{"detail":"File not found"}`; `session_id` given and not a known stored id → 404 `{"detail":"Session not found"}`; relative path + known session → resolved against `/fixture`; record `{path, range, status}` |

JSON-RPC (in addition to performance's):

| Method | Behaviour |
|---|---|
| any of `image.attach`, `file.attach`, `image.detach`, `prompt.submit` | **strict params**: keys outside the contract (§3.4/§3.5/§3.8, and `PromptSubmitParams`) → error `{"code":4000,"message":"invalid params for <method>: <key>: Extra inputs are not permitted …"}` |
| `image.attach` | `session_id` must be the bot's current runtime id (else `4001 "session not found"`); `path` must exist under uploads (`4016 "image not found: <path>"`) with an image extension (`4016 "unsupported image: <name>"`); append to that bot's `ATTACHED` list; answer §3.4's shape with `width`/`height` read from PNG/JPEG headers |
| `file.attach` | path must exist under uploads (`5028 "file not found on gateway and no data_url provided"`); mode `copy` (default): copy to `/fixture-home/attachments/<name>` (`-2`… on clash), answer `uploaded:true`, `ref_text` with Hermes quoting (backticks when the path has spaces); mode `inplace`: answer the staging path, `uploaded:false` |
| `image.detach` | remove from `ATTACHED`; `{"detached":bool,"count":n}` |
| `prompt.submit` | it never reaches `rpc()` (`R:scripts/build47-fixture-gateway.py:163-164`), so wrap `Client.prompt`; before the original runs: take and clear the bot's `ATTACHED` list; store the user row as Hermes does (text, then one `@image:<path>` line per image, quoted when needed; refs only when text is empty); record `{profile, text, queued, images}` in `attachLedger`; when no plan is queued the reply is **"Received N image(s) and M file(s)."** |

Controls:

- `POST /__fixture/attach-control` with any of: `uploadDelay` (s), `uploadFailures` (n × 500), `maxBytes`,
  `imageAttach` (`ok` | `empty` → `{}` | `error` → `5027 "synthetic attach failure"` | `stale-once` → one `4001`),
  `fileAttach` (`copy` | `inplace` | `error`), `submitStaleOnce` (one `4001` on the next `prompt.submit` before it is
  admitted), `downloadDelay` (s), `downloadFailures` (n × 500).
- `POST /__fixture/attachments-history {"profile":"default"}` replaces that bot's transcript with rows covering every
  history shape (row ids ascending, timestamps "now"):
  1. user `"Here is the chart\n@image:/fixture/media/chart.png"` (1200×800 PNG);
  2. assistant `"Got it."`;
  3. user ``"@image:`/fixture/media/two words.png`\n[screenshot]"`` (quoted path with a space; photo-only);
  4. user content array `[{"type":"text","text":"what is this?"},{"type":"image_url","image_url":{"url":"data:image/png;base64,<240×180>"}}]`;
  5. user native-vision form `[{"type":"text","text":"compare these\n@image:/fixture/media/a.png\n@image:/fixture/media/b.png"},{image_url a},{image_url b}]`;
  6. user `"@file:/fixture-home/attachments/report.pdf\n\nPlease summarise this"`;
  7. user ``"@file:/fixture-home/attachments/report.pdf\n@file:`/fixture-home/attachments/My Notes.md`"`` (files only);
  8. user `"What do you see in this image?\n@image:/fixture/media/chart.png"` (default question → photo-only bubble);
  9. user `"[Image attached at: /fixture/media/a.png]"`;
  10. assistant `"Here you go:\nMEDIA:/fixture/media/result.png\nAnd the data: MEDIA:/fixture/media/data.csv"`;
  11. assistant `"![diagram](/fixture/media/diagram.png)\n\nSee [the notes](/fixture/media/notes.md) and the archive MEDIA:/fixture/media/bundle.zip"`;
  12. assistant with `tool_calls` `image_generate {"prompt":"a red fox","aspect_ratio":"square"}`, its tool row
      `{"success":true,"image":"/fixture/media/fox.png","pixel_size":"1024x1024"}`, then `"Here's the fox."`;
  13. same with `{"success":false,"error":"No image backend configured"}`;
  14. user `"@image:/fixture/media/missing.png"` (404 → retry tile);
  15. user `"@image:/fixture/media/huge.png"` (3000×2000 PNG, banded so it compresses);
  16. assistant `"MEDIA:/fixture/media/clip.mov"` (a few bytes that are not a movie: Quick Look's failure → share sheet).
  Media are generated at start with stdlib zlib PNG (as `R:scripts/gateway-replay.py:339-345`), a minimal valid PDF,
  CSV, Markdown and ZIP (`zipfile`).
- Plan keys for live turns (`POST /__fixture/plan`, as build47): `mediaReply: "<path>"` streams
  `"Here it is:\nMEDIA:<path>"` in chunks; `imageGenerate: {"aspect_ratio","image","pixel_size","delay","fail"}` emits
  `tool.start {name:"image_generate", tool_id, args}`, waits `delay`, then `tool.complete {name, tool_id, args, result}`,
  stores the rows like performance does (`performance-fixture-gateway.py:30-42`), then the final text.
- `GET /__fixture/state` adds `uploads`, `deletes`, `attached` (per bot), `attachLedger` (every attach/detach call with
  its params), `prompts` (text, queued, images), `downloads`.

### 14.3 Ports and commands (this stream: 9723–9725 only)

| Port | What |
|---|---|
| 9723 | `attachments-gateway.py` (password sign-in) |
| 9724 | stock Nous fixture gateway (bearer uploads; `image.attach` answers `{}`) |
| 9725 | its fake Nous Portal |

```sh
NAT=/Users/me/Projects/hermes-hq-native; REF=/Users/me/Projects/hermes-hq-native-ref238
FIX=$NAT/build/fixtures; mkdir -p $FIX && chmod 700 $FIX
for p in 9723 9724 9725; do lsof -nP -iTCP:$p -sTCP:LISTEN >/dev/null && { echo "port $p busy: pick another in 9723-9725 or stop"; exit 1; }; done
python3 $NAT/scripts/fixtures/attachments-gateway.py --port 9723 --credentials $FIX/attach.json --files $FIX/attach-files \
  > $FIX/attach.log 2>&1 & echo $! > $FIX/attach.pid
python3 $REF/scripts/nous-fixture-gateway.py --port 9724 --portal-port 9725 --public-url http://127.0.0.1:9724 \
  > $FIX/nous.log 2>&1 & echo $! > $FIX/nous.pid
# seed history on the attachments fixture (no auth needed for /__fixture/*)
curl -s -X POST http://127.0.0.1:9723/__fixture/attachments-history -d '{"profile":"default"}'
# stop only what you started
kill $(cat $FIX/attach.pid) $(cat $FIX/nous.pid)
```

`scripts/e2e-attachments.sh [SIM] [RUNS]` mirrors `N:scripts/e2e.sh:1-45` (starts the fixture on
`HQN_ATTACH_PORT`, default 9723, refuses a busy port, passes `TEST_RUNNER_HQN_UI_CREDENTIALS` and
`TEST_RUNNER_HQN_UI_FIXTURE_URL`, stops what it started) and runs `AttachmentsEndToEndTests`.

Simulator: one device **"HQN-attachments"** (iPhone 17 Pro, iOS 26 runtime; create if missing, shut down when done —
the Mac has hit its process limit with many sims, `M:voice-memo-bugs.md`). Before Save checks:
`xcrun simctl privacy <udid> grant photos-add com.charlesmcdowell.hermeshq.native`. For a real-picker check:
`xcrun simctl addmedia <udid> <a .heic and a .jpg with GPS>` (§15.2 makes them).

Never point anything at the owner's gateway (100.101.102.104, `*.ts.net`); never run `hermes`.

---

## 15. Acceptance checks

### 15.1 Unit (Swift Testing, `scripts/build.sh test <udid>`)

1. **Multipart:** the body file for `{root:"/r", folder:"F", name:"a.pdf", bytes:"xyz", boundary:"hermes-B"}` equals the
   §3.3 bytes exactly; names with CR, LF, `"` or `\` are refused; a 33 MB source stops with "too large" and leaves no
   body file.
2. **Normaliser:** a 4032×3024 HEIC with orientation 6 and GPS (made in-test with `CGImageDestination` +
   `kCGImagePropertyGPSDictionary`) → JPEG, long side 3072, portrait pixels (orientation applied), and
   `CGImageSourceCopyPropertiesAtIndex` has **no** `{GPS}` dictionary, no TIFF Make/Model, no Exif DateTimeOriginal,
   and orientation 1 (or none); a PNG with real
   transparency → PNG; an opaque PNG → JPEG; a 3-frame GIF → byte-identical copy.
3. **Safe names** match `PickedFiles.safeName` on: `../x`, `a"b.pdf`, `con:trol`, a 300-byte emoji name, `.` and the empty name.
4. **`promptText`**: every row of §3.7's table, plus whitespace-only typed text.
5. **Hydration:** each §14.2 history row 1–16 folds to the expected text and attachments (paths unquoted; `[screenshot]`
   and `[image]` dropped only with images; row 5 → two attachments, not four; row 8 → no shown text); no message text,
   part or cache entry contains `data:image`.
6. **Display key:** local `{text:"look", attachments:[photo, report.pdf]}`, inflight `"@file:/x/report.pdf\n\nlook"` and
   stored `"@file:/x/report.pdf\n\nlook\n@image:/u/photo.jpg"` give one key; a refresh after the send leaves exactly one
   user bubble.
7. **Cache:** HQT2 round-trips attachments, dims and `generatedImage`; an HQT1 file reads as a miss; no `.local`
   source is written.
8. **Uploader (fake client):** eager start; one at a time; removal cancels and issues `DELETE` for an uploaded folder;
   500 → retry after 2 s → failed; 401 → one refresh → the same body file re-sent; 403 → root re-read once; offline →
   waiting → starts on `ready`.
9. **Pipeline (fake client):** call order `[image.attach…, file.attach…, prompt.submit]`, every param set ⊆ §3.4/§3.5/
   §3.7's keys; `4001` on submit → `session.resume` → `image.attach` again (no `file.attach`) → `prompt.submit` once;
   `4001` on an attach → resume → attaches restart; Stop during attaches → `image.detach` for each attached photo, draft
   returned with attachments; refusal returns uploaded attachments still `uploaded`; `stopObserving()` mid-pipeline
   doesn't cancel it; `stagedCopyReleased` table (`uploaded` true/false × inside/outside folder).
10. **Retention:** sweep deletes unreferenced folders > 600 s old and keeps drafts', queued, leased and showing ones.
11. **Remote policy:** refused: `http:`, `https://10.0.0.1`, `192.168.1.2`, `172.20.0.1`, `100.100.1.1`, `127.0.0.1`,
    `[::1]`, `[fd7a:115c:a1e0::1]`, `x.local`, `box.tail1234.ts.net`, a redirect to any of them, the 6th redirect;
    allowed: a public https host.
12. **Layout:** `MediaLayout.frames` for 1–16 items at max widths 260/320 matches §7.3 (single tall/wide/unknown,
    albums 2, 3, 4, 5, 7, 16); `MediaLayout.stack` takes the middle shape (`PhotoStackTests`); file rows grow by 12/12
    padding with 2-line names; heights never depend on loaded pixels.
13. **Markdown:** `MEDIA:` alone in a paragraph → `.media` block; inline → link with glyph; `![a](https://…)`,
    `![a](/p.png)`, `[n](/x/notes.md)`; `.svg` → file row.

### 15.2 End to end (XCUITest via `scripts/e2e-attachments.sh`, fixture :9723)

Attachments are injected with the DEBUG hook `-HQDebugAttach "<abs path>,<abs path>"` (runs the same import code as
the pickers: images through the photo path, others as files; documented in `N:App/Debug/DebugHooks.swift`'s header;
compiled out of Release). Test media live in `N:UITests/Fixtures/attachments/` (a HEIC with GPS, a PNG, a PDF, a
33 MB file made at test time).

1. **Send photos + file:** attach HEIC + PNG + PDF → three tiles reach "uploaded" (fixture `uploads` = 3 under
   `/fixture/uploads/.dispatch-attachments/<UUID>/`, the HEIC arrived as `photo.jpg` with `jpeg:true, gps:false,
   camera:false`) → type "hello", Send → `attachLedger` = `image.attach`, `image.attach`, `file.attach` with exactly the
   §3.4/§3.5 keys; `prompts[-1].text == "@file:/fixture-home/attachments/report.pdf\n\nhello"`, `images` = 2; one
   `DELETE` for the PDF's folder and none for the photos'; the bubble shows a 2-photo stack, a file row and "hello"; after the
   history refresh the bubble count is unchanged and the stack's frame (screenshot rect) is identical.
2. **Photo only:** text sent is `What do you see in this image?`; the bubble shows the photo and no text, before and
   after reopening the chat.
3. **Remove while uploading** (`uploadDelay: 3`): remove the 2nd tile → its upload never completes or its folder is
   `DELETE`d; the send carries one photo.
4. **Upload failure** (`uploadFailures: 3`): tile ends failed with "Couldn’t upload “photo.jpg”…"; Send → refused card,
   draft back with the failed tile; `uploadFailures: 0`, Try Again → uploaded; Send → delivered once.
5. **Busy:** start a reply with `{"replyText": null}`; send a photo → queue card "Photo"; no `image.attach` in the
   ledger yet; `/__fixture/finish` → ledger shows `image.attach` after the first prompt and the second
   `prompt.submit` has `queued:true`.
6. **Leave mid-send** (`uploadDelay: 3`): Send, go back, open Ivy → the prompt lands in **default**'s chat with its
   image; nothing in Ivy's.
7. **Stale runtime** (`submitStaleOnce`): ledger shows `image.attach`, `prompt.submit`(4001), `session.resume`,
   `image.attach`, `prompt.submit`; one user row stored.
8. **Strict params:** run 1–7 with the fixture's 4000 check on; no 4000 answer in the log.
9. **History shapes:** seed §14.2 → every row renders as §15.1-5 expects (screenshots light + dark); row 14 shows the
   retry tile words; `downloadFailures: 1` → a photo shows the tile → tap → loads; reopen the chat: every image row's
   frame equals the first open's (cache dims).
10. **Viewer:** tap row 5's second photo → viewer "2 of 2"; double-tap → zoomed; swipe down does nothing while zoomed;
    double-tap back, swipe down → back in the chat at the cell; Save → "Saved" (photos-add granted); Share → the share
    sheet; long-press a photo → Save to Photos / Share… / Copy.
11. **Files:** tap row 6's report.pdf → "Downloading…" → Quick Look titled `report.pdf`; tap row 16's `clip.mov` →
    share sheet; tap row 11's `bundle.zip` → share sheet; `downloads` shows no `session_id` on absolute paths.
12. **Live media:** plan `imageGenerate {aspect_ratio:"portrait", delay:1.5, image:"/fixture/media/fox.png",
    pixel_size:"1024x1792"}` → the card frame appears 9:16 with "Rendering image", then the fox fades in with the
    frame unchanged; plan `mediaReply` → an image block inside the bot bubble.
13. **Limits:** the 33 MB file → alert "… larger than 32 MB …", no tile; 17 attachments → "You can attach up to 16
    items to one message." and 16 tiles; + menu shows "Limit reached".
14. **Nous** (9724/9725, sign in with Nous through the fake Portal): attach a PDF → the root read is answered on the
    bearer (`/__fixture/nous` `bearerOk` rises; the stock fixture doesn't gate the upload POST itself, so unit check 8
    proves the upload carries the same decoration) → upload and `file.attach` succeed → Send delivers; attach a photo → `image.attach` answers `{}` →
    refused card **"Your gateway didn't accept “photo.jpg”."**, draft returned.
15. **Camera on the Simulator:** + menu shows Camera disabled with "Unavailable".
16. **Real picker (manual on the sim, screenshots):** `simctl addmedia` a HEIC with GPS → + › Photos → pick → tile →
    send → fixture records `gps:false, camera:false`.

### 15.3 Feel and performance

- A chat with 40 history photos scrolls at 120 Hz on the Simulator with no frame over 16 ms caused by image work:
  no `UIImage` decode, `Data(contentsOf:)` or base64 decode on the main thread (os_signpost intervals around
  decode/load prove it; check with the perf probe `N:App/Chat/Debug/ChatPerfProbe.swift`).
- Opening a cached chat with photos paints the first frame with exact image frames (no row height change when the
  pictures arrive).
- Upload progress (100 updates/s) causes no table updates (count `performBatchUpdates` calls: 0 while only progress
  changes).
- Memory after opening and scrolling the seeded history: decoded image memory stays under the 64 MB cache cost.

### 15.4 Device checklist (owner's phone, for the release notes)

Real camera; an iCloud-only photo (the tile shows the download ring); a Live Photo (sent as a still); a 4K video
under 32 MB (location stripped); Save to Photos permission prompt; a PDF from Files; airplane mode during an upload
(tile waits, resumes); locking the phone mid-upload.

---

## 16. Flags, disagreements, unknowns

- **F1 — Staging photos stay on the gateway forever.** `image.attach` uses the staging path in place and the stored row
  points at it; nothing deletes `~/.dispatch-attachments/<UUID>/photo.jpg`. Same as the web. Not ours to change
  (`M:hermes-code-not-ours.md`).
- **F2 — Container/ssh terminal backends.** With native vision the gateway reads the path itself
  (`H:agent/image_routing.py:533-567`), which works for any gateway path; the text route's `vision_analyze` hint may
  name a path a container can't see (`H:tui_gateway/prompt_attachments.py:82-95` comment). Same as the web.
- **F3 — `session_id` on downloads** differs from spec 03 §6.6 (which always sent it): absolute paths now go without it
  (A8). Update spec 03 when this lands.
- **F4 — Images from Files as photos** (A3) and **photos inside the bubble** (A7) are deliberate deviations; both
  need the owner's eye on the first build. If the owner wants the web's thumbnail row under the bubble instead, only
  §7.3's layout changes.
- **F5 — Eager photo uploads** (A2) upload photos that may never be sent; removal deletes them, an abandoned draft's
  stay until the draft is cleared (then `DELETE`).
- **F6 — `[Image attached at: …]` and user `MEDIA:` lines** are rendered as images natively; the web shows them as
  text. Low risk.
- **F7 — Transcript cache bump** (HQT2) makes every cached chat read fresh once after the update (no instant paint on
  the first open of each chat). Acceptable once; say so in the build notes.
- **U1 — Hermes `image.attach` result fields** were read from source; no live answer was captured (no real gateway may
  be contacted). The fixture copies the source shape.
- **U2 — Quick Look and `.md`/`.svg`:** Quick Look on iOS 26 shows Markdown as text and SVG as an image in practice;
  if not, the share-sheet fallback applies. Check on the Simulator (check 11).
- **U3 — `UIDeferredMenuElement.uncached` inside a menu with `preferredElementSize: .medium` siblings:** if iOS draws
  the paste item oddly, rebuild the whole menu in `UIButton.menu` on touch-down instead (still a system menu).

### 16.1 Review round (built)

- **R1 — Preparing sends.** While a send uploads and attaches (`TurnState.preparingSendId`), the 45 s silence watchdog,
  a `session.info running:false`, `session.reclaimed` and a stray `error` frame never settle its turn; the watch and
  the 15 s pre-start rule start when its `prompt.submit` goes out (`endPreparing`).
- **R2 — Stop during uploads** wakes the waiting send at once (`AttachmentCenter.interruptWaits`); the attachments
  return to the draft still uploading.
- **R3 — Draft scope.** A chat opened before its stored id is known keeps its draft under `"<account>|<profile>|"`;
  when the id resolves the draft and its observers move to the real scope (`AttachmentCenter.moveDraft`), and the
  tray reads `draftScope` each time.
- **R4 — Echoes** (§7.7): beyond the web (which strips every markdown image and `#media:` link once a generation
  succeeded), native also strips `MEDIA:` directives naming the result's `host_image`/`image`/`agent_visible_image`,
  never other `MEDIA:` files.
- **R5 — Inline reply images** (§7.5) are decoded in the off-main fold into `Caches/HQNMedia/<account>/inline/` and
  rewritten to `#media-inline:<key>`; the renderer never decodes a `data:` URI (a live reply shows the alt text until
  its turn-end read).
- **R6 — Tray top room** is 17 pt (was 8) so the ✕'s 44 pt target lies inside the clipped, opaque tray.
