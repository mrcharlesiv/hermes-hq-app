# 3x — Photo heads

Implementation spec for the "photoheads" stream of HQ Native's m9 run: a bot can wear a photo instead of its head.
It covers the single-photo picker, the Move and Scale framer, the rule that decides whether a bot shows a photo or
its head, the picture picker inside Edit Bot (Head tab and Upload tab), and the photo-library permission string.
Five parity rows, listed in §1 and copied verbatim in `docs/briefs/m9/photoheads-rows.md`.

Read first: `docs/ARCHITECTURE.md`, `docs/spec/1x-settings.md` §6 (Edit Bot) and §7 (Edit Head, the desktop mirror),
`docs/spec/06-native-feel-and-design.md` §0. Where this spec and the web app disagree, the web app wins unless a
line here is marked **DECISION** (each one says why; §13 lists them all). The owner was asleep for this run: every
open question was decided here, none was left as a question.

---

## 0. Conventions

### 0.1 Citation key

| Prefix | Path |
| --- | --- |
| `S/` | `/Users/me/Projects/hermes-hq-native-ref240/src/` (Hermes HQ phone code, build 240) |
| `B/` | `/Users/me/Projects/hermes-hq-native-ref240/build/` (gates: exact-string patches of the vendored renderer, i.e. what the phone actually runs) |
| `V/` | `/Users/me/Projects/hermes-hq-native-ref240/vendor/hermes/apps/desktop/src/` |
| `HB/` | `V/plugins/hermes-bots/` |
| `IOS/` | `/Users/me/Projects/hermes-hq-native-ref240/ios/App/` (the web app's native shell) |
| `AG/` | `/Users/me/.hermes/hermes-agent/` (gateway source, read only) |
| `C/` | `AG/tui_gateway/contracts/` |
| `NAT/` | this worktree (`/Users/me/Projects/hermes-hq-native-wt/m9-photoheads/`) |
| `MEM/` | `/Users/me/.claude/projects/-Users-me-Projects-hermes-ios/memory/` (owner history) |

`file:N` is a line, `file:N-M` a range. **[gate]** marks behaviour that exists only because a `B/` gate rewrote
vendored code.

### 0.2 Wire rules that bite here

1. **Params are strict.** Every JSON-RPC params model is `extra="forbid"`; an unknown key answers error **4000**.
   `profiles.set_asset` takes exactly `name`, `asset`, `data`, `clear` (plus the optional routing `profile`);
   `profiles.get_asset` takes exactly `name`, `asset` (plus `profile`) (`C/profiles_vault_complete_foreign_subagents.py:317-352`).
   Send nothing else. Native does not send `profile` on `profiles.*` calls (the target is `name`).
2. **There is no version number for the avatar.** `profiles.list` only says whether a profile has one
   (`has_avatar`, `AG/tui_gateway/methods_profiles.py:278`). The only way to learn *which* picture is to fetch it
   (§4.3).
3. **One avatar file per profile.** A `set_asset` replaces whatever was there (photo or head mirror); `clear` removes
   it (`AG/tui_gateway/methods_profiles.py:411-461`). The avatar is shared by every phone and by desktop Hermes.
4. **Limits the gateway enforces:** PNG, JPEG or WebP only (sniffed from the bytes, not the label), at most
   2,000,000 decoded bytes. Native always uploads a 256 × 256 PNG (at most about 262 KB of pixels), so neither limit
   can be hit by this app's own uploads.

### 0.3 Words

"Head" = the drawn robot head (`ui_meta["dispatch-head"]`, or the default head for the profile name). "Photo" = a
picture someone chose for the bot, stored as the profile's avatar asset. "Mirror" = the 288 × 288 PNG of a saved head
that the app stores as the avatar so desktop Hermes shows the same bot (`S/ui-heads/mirror.ts:1-9`). "Backfill" = the
160 × 160 PNG desktop Hermes stores of its own vector face (`HB/avatar-image.ts:136-138`). A mirror and a backfill
are not photos.

---

## 1. Rows and where each is specified

| Row (parity-240 line) | What it asks for | Sections |
| --- | --- | --- |
| L228 Photo picker: single native photo, 1024 px | one photo, picked on a tap, read at 1024 px | §6 |
| L229 Photo head framer (Move and Scale) | pinch or slider, drag, app-icon frame, blurred gap fill | §7 |
| L819 Photo heads: a chosen photo wins; the 288 px copy isn't a photo | the photo rule, everywhere a face is drawn | §4 |
| L820 Avatar picker Head tab with Edit Head ("Head saved" note) | the tabbed Picture picker in Edit Bot | §5, §8 |
| L1027 Permission strings: native lacks NSPhotoLibraryUsageDescription | the Info.plist string | §9 |

No row is proposed as web-shell-only. No row needs a relay, plugin or real-gateway change, so there is no
`docs/owner-todo/photoheads.md` (§14).

---

## 2. What the web app does

### 2.1 The picker (L228)

- Upload's button calls `pickImageFromDevice`, which on the phone is rerouted to `pickBotPhoto` **[gate]**
  (`B/stress-a-gates.ts:142-146`).
- `pickBotPhoto` shows a native menu growing from the tapped button with two items: **Photo Library**
  (`photo.on.rectangle`) and **Choose File** (`folder`) (`S/ui-bots/photo-pick.ts:14-17`). No camera item.
- It asks the shell for exactly one path (`selectPaths({ multiple: false, source })`, `S/ui-bots/photo-pick.ts:19`)
  and reads it at 1024 px: "a head is drawn at a few hundred points; 1024 px leaves the Move and Scale framer room to
  zoom" (`S/ui-bots/photo-pick.ts:20-21`).
- Why it exists: "WebKit's file input opened the library in multi-select, where a tap only ticked the photo"
  (`S/ui-bots/photo-pick.ts:1-2`).
- The shell's library picker is `PHPickerViewController` with `selectionLimit = 1`, images and videos, no library
  permission (`IOS/App/HermesPicker.swift:121-125`); the file picker is a `UIDocumentPickerViewController` for any
  item, as a copy. The read clamps `maxPixels` to 64…8192 and answers a PNG or JPEG data URL; a file it can't read
  fails with "Selected file unavailable or exceeds 32 MB limit" (`IOS/App/HermesPlatform.swift:1105-1124`), which the
  web app does not show (the pick just does nothing).
- Cancelling the menu or a picker does nothing.

### 2.2 The framer (L229)

- A picked photo opens **Move and Scale** instead of being centre-cropped **[gate]** (`B/photo-framer-gates.ts:16-19`).
- Full-screen black cover (`data-ios-presentation="cover"`, `S/ui-bots/photo-framer.tsx:36`;
  `S/ui-bots/photo-framer.css:3-4`). Title "Move and Scale" (`:37`, `:112`). Screen-reader description: "Pinch or use
  the zoom slider to size the photo, and drag it to place it in the frame." (`:38`).
- Frame side = `min(stage width − 32, stage height − 32, 420)` (`:58`).
- One finger drags; two fingers pinch about their midpoint and drag by the midpoint's movement (`:78-92`); a wheel or
  trackpad pinch zooms about the pointer (`:95-99`); a double click resets to the start (`:114`).
- Zoom slider labelled "Zoom", from "whole photo fits" to 5×, disabled until the photo has loaded (`:126-131`), with
  a small picture glyph on the left and a large one on the right (`:125`, `:132`).
- Bar: **Cancel** (left) and **Choose** (right, semibold, disabled until the photo has loaded and while rendering)
  (`:134-137`).
- The window is the app-icon shape: corner radius 22.37 % of the side, a 1 px white line at 55 %, everything outside
  dimmed with 60 % black (`S/ui-bots/photo-framer.css:14-17`).
- Zoomed out past filling the frame, the gaps show a blurred copy of the photo (the photo at "fill" size × 1.15,
  blurred by 5 % of the frame side), in the preview and in the saved picture alike
  (`S/ui-bots/photo-framer.tsx:11-30`, `:116-118`).
- Choose renders a **256 × 256 PNG** (`PHOTO_EDGE`, `:11`, `:15-30`) and hands it to the picker as the pending image.
- The placement math is `S/ui-bots/photo-frame-model.ts` (50 lines; ported in §7.2).

### 2.3 The photo rule (L819)

- `headWins(image) = headsOn() && (!image || isHeadMirror(image))` (`S/ui-heads/renderer-hooks.tsx:31`). The face
  component draws the head when `headWins`, else the picture **[gate]** (`B/ui-heads-gates.ts:14`).
- `isHeadMirror`: a PNG data URL whose IHDR width and height are both 288 (`S/ui-heads/mirror.ts:9-28`).
- The phone's list identity also refuses the backfill: `photo = Boolean(image && !isBackfilledFacePng(image))`
  (`S/ui-bots/identity.ts:20`); a backfill is a PNG exactly 160 × 160 (`HB/avatar-image.ts:136-150`).
- The kit avatar draws the photo with `object-fit: cover` and `border-radius: 22.37%`
  (`S/ui-kit/bot-avatar.tsx:53-58`, `S/ui-kit/bot-avatar.css:7`), and un-inverts it under Smart Invert (`:19`).
- Notification pictures follow the same rule (`S/notification-avatar.ts:12-15`), as does the Share extension's roster
  (`S/share-roster.ts:40-65`).
- Where the picture comes from: a device fetches `profiles.get_asset` **once** when a row says `has_avatar` and it
  holds no picture, then keeps it (`HB/profile-ops.ts:167-216`).
- Saving a head stores its mirror as the avatar (`S/ui-heads/sync.ts:94-96`, `S/ui-heads/mirror.ts:58-70`), replacing
  a photo on the gateway. Resetting a head removes the avatar only if it is the mirror ("a photo someone chose is
  left alone", `S/ui-heads/mirror.ts:55-57`).

### 2.4 The picker tabs (L820)

- The avatar picker has four tabs (`HB/avatar-picker.tsx:128-131`); the first is relabelled **Head** **[gate]**
  (`B/ui-heads-gates.ts:18-19`); the others are Generate, Upload, Pet. It always opens on Head (`:61`).
- Head tab (`S/ui-heads/renderer-hooks.tsx:50-73`): an **Edit Head** button (`:61`); under it either
  "Make it a robot, a character, an orb, anything. Every phone on this gateway and desktop Hermes show the same
  picture." (`:64`) or, once a head was saved from here, "Head saved. It’s on every device on this gateway." (`:63`).
  For a bot that doesn't exist yet: "The bot gets a shape from its name. You can change it once the bot is created."
  (`:57`). "The Generate, Upload and Pet photo tabs are unchanged, and a photo still wins." (header comment).
- Upload tab: one button, "Choose an image…" with a camera glyph (`HB/avatar-picker.tsx:278-283`).
- A **Remove Picture** button (phone wording, `B/stress-a-gates.ts:94`) shows when a picture is set, but not for a
  mirror **[gate]** (`B/ui-heads-gates.ts:22`: "A saved head's desktop copy is not a photo to remove").
- Nothing is saved until Edit Bot's Save: it writes `ui_meta["hermes-bots"]` with `imageKind: image ? 'photo' : 'shape'`
  and `custom: true` (`HB/edit-profile-dialog.tsx:96-110`), then, only when the picture changed, sends
  `profiles.set_asset` with the data or `clear: true`, not awaited (`HB/data.ts:314-410`).

### 2.5 The permission string (L1027)

`NSPhotoLibraryUsageDescription` = "Select photos to attach to your Hermes HQ chat." (`IOS/App/Info.plist:27`).
Native's `App/Info.plist` has the camera, microphone, local-network and photo-add strings (`NAT/App/Info.plist:36-39`)
and no photo-library string.

---

## 3. Native design in one page

```
profiles.list (has_avatar, ui_meta_revisions)
        │
        ▼
BotPhotoStore (HermesKit/Store)  ── profiles.get_asset ──▶ classify ──▶ disk (≤256 px PNG + index)
        │  verdict per profile: none | mirror | backfill | photo | unreadable
        ▼
BotFaces (App/Heads)  ── decoded photos in memory, one registry every face asks
        │
        ├─ HeadView.configure(raw:profile:working:)   UIKit faces (chat title, cells that host a HeadView)
        ├─ HeadImage(raw:profile:size:working:)       SwiftUI faces (rows, tiles, sheets)
        └─ BotFaces.faceImage(...)                    pictures handed out (notifications, reply peek, share roster)

Edit Bot ▸ Picture ▸ [ Head | Upload ]
        Upload ▸ "Choose an image…" ▸ menu ▸ PHPicker / document picker ▸ read at 1024 px
              ▸ Move and Scale (full-screen) ▸ 256×256 PNG staged in Edit Bot
        Save ▸ profiles.set_asset ▸ profiles.configure(ui_meta.hermes-bots.imageKind)
```

**Why a registry and not a field on `Bot`.** Every face in the app is drawn through `HeadView.configure(raw:profile:working:)`
(`NAT/App/Heads/HeadView.swift:58`) or `HeadImage(raw:profile:size:working:)` (`:424`). About a dozen call sites in
files other m9 streams are editing use them (`App/Bots/BotRowViews.swift`, `App/AppModel.swift:590`,
`App/Chat/ChatSheets.swift`, `App/Chat/ChatPlaceholderView.swift`, `App/BotInfo/BotInfoSheet.swift`,
`App/Sessions/*`, `App/Capabilities/*`, Kanban). Putting the photo behind those two entry points changes one file,
gives every present and future call site the rule for free, and honours the owner's instruction: "any new place that
draws a bot picture must go through `BotFace` or check `isHeadMirror`" (`MEM/head-save-ux.md`). Callers that pass a
`Head` directly (`configure(head:)`, `HeadImage(head:)`: Edit Head's preview, New Bot) never show a photo, which is
right: they show the head being edited.

### 3.1 Files

New:

| File | What |
| --- | --- |
| `HermesKit/Store/BotPhotoStore.swift` | verdicts, fetching, disk cache, purge (§4) |
| `HermesKit/Model/BotPicture.swift` | pure classification: mirror / backfill / photo / unreadable; fingerprint (§4.1) |
| `HermesKit/Model/PhotoFrame.swift` | the framer math, a line-for-line port of `photo-frame-model.ts` (§7.2) |
| `App/Heads/BotFaces.swift` | the registry: decoded photos, view registration, `faceImage`, `faceKey` (§4.5, §4.6) |
| `App/BotInfo/BotPhotoPicker.swift` | the menu, PHPicker, document picker, the 1024 px read (§6) |
| `App/BotInfo/PhotoFramerController.swift` | Move and Scale (§7) |
| `App/BotInfo/PhotoFramerRenderer.swift` | the 256 px PNG and the blurred backdrop (§7.5) |
| `App/Notifications/PushFaceSaver.swift` | added after review: the faces kept for pushed alerts, photos decoded off the main actor (§4.6, B28) |
| `scripts/fixtures/photoheads-gateway.py`, `scripts/fixtures/make-photoheads-media.swift`, `scripts/e2e-photoheads.sh` | stand-in gateway, test pictures, the run script (§10) |
| `Tests/PhotoHeads/*.swift`, `UITests/photoheads/*.swift` | §11 |

Changed (keep each change small; other streams are in these files):

| File | Change |
| --- | --- |
| `App/Heads/HeadView.swift` | photo layer in `HeadView`; photo branch in `HeadImage` (§4.5) |
| `App/BotInfo/EditBotController.swift` | the Picture section becomes the tabbed picker; staged picture; Save (§5, §8) |
| `HermesKit/Store/BotStore.swift`, `BotStore+Editing.swift` | owns a `BotPhotoStore`; feeds it roster rows; `saveEdit` gains `picture:`; `mirrorHead` tells the store (§4.3, §8) |
| `App/AppModel.swift` | `BotFaces.shared.use(bots?.photos)` wherever the active `BotStore` is set or cleared |
| `App/Notifications/AppModel+Notifications.swift`, `NotificationHub.swift`, `ReplyPeek.swift` | faces through `BotFaces.readyFace`; signature from `faceKey` (§4.6) |
| `App/Debug/DebugHooks.swift` | `-HQDebugBotPhoto`, `-HQDebugBotPhotoDelay`, `-HQDebugUploadTimeout` (§10.4) |
| `App/Info.plist` | `NSPhotoLibraryUsageDescription` (§9) |

`App/Info.plist` is the one plist for both identities (`project.yml:72`; `project-original.yml` only overrides
settings), so no XcodeGen change is needed for §9. New Swift files are picked up by the folder sources; run
`xcodegen generate` and build **both** `HQ_IDENTITY=native` and `HQ_IDENTITY=original`.

---

## 4. The photo rule and the picture store (L819)

### 4.1 Classification (pure, unit tested)

`BotPicture.classify(found: Bool, dataURL: String?) -> Verdict`, in this order:

| # | Input | Verdict | Face |
| --- | --- | --- | --- |
| 1 | `found` is not `true`, or `data` is missing/empty | `none` | head |
| 2 | `data:image/png;base64,` and IHDR is 288 × 288 (`HeadRecord.isHeadMirror`, already in `NAT/App/Heads/HeadRecord.swift:325-337`) | `mirror` | head |
| 3 | `data:image/png;base64,` and IHDR is 160 × 160 | `backfill` | head |
| 4 | the bytes decode with ImageIO to an image at least 1 × 1 | `photo` | **photo** |
| 5 | anything else (bad base64, truncated file, a type ImageIO can't read) | `unreadable` | head |

- The fingerprint of a photo is the first 16 hex characters of the SHA-256 of its decoded bytes.
- Rule 3 is the phone's rule (`S/ui-bots/identity.ts:20`). **DECISION:** a 160 × 160 PNG is never a photo on native,
  even when `ui_meta["hermes-bots"].imageKind` is `"photo"` (desktop lets that flag override,
  `HB/profile-ops.ts:198`). Why: the phone already ignores the flag, and a wrong guess here kills a live head.
- A photo may be any shape (a desktop "Pet" is 96 × 104, a desktop upload may be a JPEG). It is drawn aspect-fill,
  centred (`object-fit: cover`).
- Known limit, same as the web: a real photo that happens to be a 288 × 288 or 160 × 160 PNG reads as a mirror or a
  backfill. Native's own uploads are always 256 × 256.

### 4.2 Wire

Read (30 s timeout, never blocks UI):

```json
{"method":"profiles.get_asset","params":{"name":"ivy","asset":"avatar"}}
```

```json
{"result":{"found":true,"mime":"image/png","size":148213,"data":"data:image/png;base64,iVBORw0KGgo…"}}
{"result":{"found":false}}
```

Errors: `5066` (uncaught on the gateway), a method-not-found answer on a gateway older than the asset store, a
timeout, a closed socket. All are silent: the verdict stays what it was (unknown at first, so the head shows), and
the fetch is retried after 30 s, then 2 min, then 10 min; the ladder restarts on reconnect. Never an alert.

### 4.3 When a picture is fetched

The web fetches once per device and never again, which is how the owner came to see a stale picture
(`MEM/head-save-ux.md`: "phone pulls a server avatar once and caches it"). **DECISION:** native treats the gateway's
avatar as the truth and refetches on these signals. Why: "owner judges by what the phone shows".

For each roster row, on every roster apply (`BotStore` calls `photos.rowsArrived(rows, order:)`):

| Row state | Action |
| --- | --- |
| `has_avatar` key absent from every row | gateway has no asset store: do nothing, ever (§5.6) |
| `has_avatar == false` | verdict `none` at once; delete the cached file; no call |
| `has_avatar == true`, no verdict yet | fetch |
| `has_avatar == true`, and `ui_meta_revisions["hermes-bots"]` or `["dispatch-head"]` differs from the pair recorded with the verdict | fetch, 2 s after the row arrived (the other device's upload is not awaited there, so give it time); if that answer has the same fingerprint as before, fetch once more 10 s later, then record the pair |
| otherwise | nothing |

Also:

- **Bot Info opens** for a bot: `photos.refresh(profile)` (skipped if that profile was checked in the last 60 s).
- **Pull to refresh** on Bots: `refresh` for every bot with `has_avatar` (same 60 s guard).
- **This phone's own writes** never cause a fetch: a photo save, a removal and a head mirror call
  `photos.adopt(profile, dataURL:)` with the bytes just sent; a `profiles.configure` this phone made records the new
  revision with `photos.noteMetaWrite(profile, key:, revision:)`.

Queue: one fetch at a time, 250 ms apart, utility priority, only while the socket is connected and the app is
active; the open chat's bot first, then list order. A first launch on the owner's gateway fetches one mirror per
bot with a saved head, classifies it `mirror`, stores the verdict and no bytes; later launches fetch nothing.

### 4.4 Disk and memory

- Folder `<cacheDirectory>/botphotos-<accountKey>/` (same `cacheDirectory` and `RosterDisk.accountKey` as the roster
  cache, `NAT/HermesKit/Model/RosterDisk.swift`): `index.json` and one `<first 16 hex of SHA-256(profile)>.png` per
  photo.
- Index entry: `{"verdict":"photo","fingerprint":"9f2c…","bots":8,"head":2,"at":1791676800,"w":256,"h":256}`.
- Only photos keep bytes, and never the original: the stored file is the picture downsampled to at most 256 px on
  its long side (ImageIO thumbnail with the transform applied, then PNG), made off the main actor. A 2 MB JPEG from
  another client costs the phone at most a 256 px PNG.
- Writes are atomic; a corrupt or missing index means "no verdicts" (refetch), never a crash.
- `BotStore.removeCachedData()` also removes the folder (sign-out, gateway removal: `NAT/App/AppModel.swift:198`),
  and `-HQDebugResetAccounts` clears it with the other caches. Wherever account caches are pruned for accounts that
  no longer exist, prune this folder too.
- Memory (`BotFaces`): an `NSCache` of decoded images, cost = bytes, limit 24 MB; a miss decodes off-main and then
  notifies. On a memory warning the cache empties and faces fall back to the head until redecoded.
- First paint: when `BotFaces.use(store)` is called, the photos of the first 12 bots in the last known list order
  are decoded synchronously, stopping once 30 ms have been spent, so the list does not flash heads before photos.

### 4.5 Drawing

`BotFaces` (`@MainActor @Observable`, `static let shared`):

```swift
static let cornerShare: CGFloat = 0.2237
func use(_ store: BotPhotoStore?)            // AppModel: sign-in, gateway switch, sign-out (nil)
func photo(for profile: String) -> UIImage?  // nil when the head wins or the picture isn't decoded yet
func register(_ view: HeadView)              // weak; told when its profile's face changes
private(set) var version: Int                // SwiftUI reads this to re-render
```

`HeadView`:

- `configure(raw:profile:working:)` remembers `profile`, registers with `BotFaces`, then shows the photo if
  `BotFaces.shared.photo(for: profile)` is non-nil. A caller that uses `configure(head:…)` directly never gets a
  photo: that entry point clears `profile` (the raw entry point sets it again after delegating).
- The photo is a `UIImageView` over the head's stage: `contentMode = .scaleAspectFill`, `clipsToBounds = true`,
  `layer.cornerRadius = bounds.width × 0.2237`, `layer.cornerCurve = .continuous`,
  `accessibilityIgnoresInvertColors = true`. While it shows, the head's stage is hidden and the view leaves
  `HeadIdleMotion` (a photo does not blink, glance or bob; the working badge beside it still shows).
- When the photo goes away (removed, replaced by a mirror, gateway switch) the head is redrawn and rejoins the
  motion clock. No cross-fade.

`HeadImage(raw:profile:size:working:)`: reads `BotFaces.shared.version`; with a photo, draws
`Image(uiImage:).resizable().aspectRatio(contentMode: .fill)` in a `size × size` frame clipped by
`RoundedRectangle(cornerRadius: size × 0.2237, style: .continuous)` with `.accessibilityIgnoresInvertColors()`;
otherwise exactly what it draws today.

The corner is a share of the box's **width**, never 50 %. Owner, 2026-10-02: "owner saw a photo head drawn as a
circle in the native glass chat title pill, while vector heads use the app-icon shape"
(`MEM/photo-head-chat-bar-corners.md`). At the chat title's 34 pt that is a 7.6 pt corner.

Sizes in use today, all covered by the two entry points: 24, 32, 34, 40, 44, 56, 64, 72, 80 pt.

### 4.6 Faces handed out as pictures

```swift
enum FaceShape { case appIcon, square }
func faceImage(profile: String, raw: JSONValue?, side: CGFloat, scale: CGFloat, dark: Bool, shape: FaceShape) -> UIImage
func faceKey(profile: String, raw: JSONValue?) -> String   // "photo:<fingerprint>" or "head:<digest of raw>" (B26)
func readyFace(profile: String, raw: JSONValue?, side: CGFloat, scale: CGFloat, dark: Bool, shape: FaceShape) -> Face?
struct Face { let image: UIImage; let isPhoto: Bool }      // nil: the bot wears a photo that cannot be drawn yet (B27)
```

`faceImage` always answers with something to draw (the head while a photo is not ready). A caller that keeps the
picture under `faceKey`, or shapes it by what it is, asks `readyFace` instead, so a head is never kept or cut as if
it were the photo.

- **Notification pictures** (`NAT/App/Notifications/PushFaceSaver.swift`, called from
  `AppModel+Notifications.swift`): the kept face is the photo as a 120 px square, else the head; the `saveFace`
  signature comes from `faceKey`, so a new photo replaces the stored face. A photo that is not in memory is read and
  decoded off the main actor, one bot at a time, and saved when it is ready; until then nothing is saved under the
  photo's key (B27, B28). iOS draws a message sender's picture as a circle; that is the system's shape, not ours. **DECISION:**
  the photo is stored at native's existing 120 px (the web uses 192, `S/notification-avatar.ts:9`). Why: the Keychain
  copy is capped at 256 KB (`NAT/Shared/PushFaces.swift`) and 120 px covers the sender picture at 3×.
- **Reply peek** (`NAT/App/Notifications/ReplyPeek.swift:149-152`): today the 40 pt face has `cornerRadius = 20`.
  Use `readyFace(…, side: 40, shape: .appIcon)` and no extra corner, so a photo is an app-icon tile (8.9 pt corner),
  not a circle. A photo that cannot be drawn at that moment comes as the head, cut round like every head (B27).
- **Share extension roster** (the `share` stream's row L590): it must take each bot's 120 px face from
  `faceImage(…, side: 120, shape: .appIcon)` and its change key from `faceKey` (`S/share-roster.ts:40-65`). This
  stream ships the two functions; the `share` stream calls them.
- **Group pictures** (the `groups` stream, "Name & Photo", L233): reuse `BotPhotoPicker` (§6) and
  `PhotoFramerController` (§7); both return a 256 × 256 PNG data URL and know nothing about bots.

### 4.7 States a face can be in

| State | What shows |
| --- | --- |
| No verdict yet (first launch, fetch pending or failing) | head |
| `none`, `mirror`, `backfill`, `unreadable` | head |
| `photo`, decoded | photo, app-icon corners |
| `photo`, not decoded yet (cache miss) | head for at most a frame or two, then photo |
| Offline, verdict cached | whatever the cache says (photo files are on disk) |
| Gateway switched | the new account's verdicts; nothing from the old one, even for the same profile name |

There is no placeholder, spinner or error mark on a face. A bot always has a head to fall back on.

---

## 5. The Picture picker in Edit Bot (L820)

Edit Bot is a page inside Bot Info's one sheet (owner: no "pop up on top of a pop up", `MEM/sheet-pages.md`). Its
Picture section (`NAT/App/BotInfo/EditBotController.swift:145-160`) becomes:

```
PICTURE
┌───────────────────────────────────────────────┐
│                  [ face, 72 pt ]              │   edit-bot.face
│        ┌───────────────┬───────────────┐      │
│        │     Head      │    Upload     │      │   edit-bot.picture-tabs (system segmented control)
│        └───────────────┴───────────────┘      │
│   Head tab:    [ Edit Head ]  + note          │   edit-bot.edit-head, edit-bot.head-note
│   Upload tab:  [ Choose an image… ]           │   edit-bot.choose-image
├───────────────────────────────────────────────┤
│   Remove Picture                              │   edit-bot.remove-picture (only with a photo)
└───────────────────────────────────────────────┘
```

Rows that wrap keep 12–14 pt of vertical padding. The segmented control and the buttons are system controls (no
drawn glass).

### 5.1 The staged picture

`EditBotModel` gains `picture: PictureDraft` = `.unchanged` | `.photo(image: UIImage, dataURL: String)` | `.removed`,
and `hasChanges` includes `picture != .unchanged`. Nothing touches the gateway until Save (as on the web, §2.4).

The 72 pt face shows: `.photo` → that image with app-icon corners; `.removed` → the head
(`HeadImage(head: Head.resolve(bot.head, profile: bot.id), size: 72)`, the head-only initialiser, so the registry's
photo is not drawn); `.unchanged` → `HeadImage(raw: bot.head, profile: bot.id, size: 72)`.

"The face shows a photo" below means: `.photo`, or `.unchanged` with a `photo` verdict.

### 5.2 Tabs

Labels **Head** and **Upload** (`B/ui-heads-gates.ts:18-19`, `HB/avatar-picker.tsx:128-131`). The page always opens
on Head (`HB/avatar-picker.tsx:61`). The choice is not remembered.

**DECISION:** no Generate tab and no Pet tab. Why: parity-240 has no row for either and no m9 stream owns them;
Generate needs an image model on the gateway and Pet needs the petdex catalogue. A picture another device set with
either still shows here as a photo and can be removed. The 1x-settings decision that left "Photo pictures (Upload,
Generate, Pet, Move and Scale framer)" out is replaced by this spec for Upload and the framer only.

### 5.3 Head tab

Button **Edit Head** (`.bordered`), pushes the existing Edit Head page. The note under it:

| When | Note | Colour |
| --- | --- | --- |
| a head was saved from this page | "Head saved. It’s on every device on this gateway." | tint |
| a head was reset from this page | "Head reset. Every device on this gateway shows its default head." | tint |
| the face shows a photo | "This bot shows a photo. Saving a head replaces it." | secondary |
| otherwise | "Your other devices and desktop Hermes show the same picture." | secondary |

The first, second and fourth are today's strings (`NAT/App/BotInfo/EditBotController.swift:151`, `:180-186`; web
`S/ui-heads/renderer-hooks.tsx:63-64`). The third is new. **DECISION:** when a head is saved from this page, the
photo is dropped on this phone at once: the staged picture goes back to `.unchanged`, the face becomes the head,
Remove Picture disappears and the first note shows. Why: on the web the gateway's photo is replaced by the mirror
but this phone keeps drawing its cached photo, so "Head saved" has no visible result, which is the owner's exact
complaint ("never noticed a place to click save"; "a save with no visible result reads as 'no save'",
`MEM/head-save-ux.md`). The third note says so before the tap.

### 5.4 Upload tab

One button, **Choose an image…** with the `camera` symbol (`HB/avatar-picker.tsx:278-283`), `.bordered`, full
width. It is a menu button (`Menu` with `.menuOrder(.fixed)`, or `UIButton.showsMenuAsPrimaryAction`):

| Item | Symbol | Does |
| --- | --- | --- |
| Photo Library | `photo.on.rectangle` | §6.1 |
| Choose File | `folder` | §6.2 |

(`S/ui-bots/photo-pick.ts:15-16`.) No camera item, as on the web. After Choose in the framer the page shows the new
face, stays on the Upload tab, and Save becomes available.

### 5.5 Remove Picture

Shown (on either tab) only when the face shows a photo; never for a mirror or a backfill ("A saved head's desktop
copy is not a photo to remove", `B/ui-heads-gates.ts:22`; owner: "gate hides Remove image for the mirror",
`MEM/head-save-ux.md`). A plain button in the destructive colour, label **Remove Picture**
(`B/stress-a-gates.ts:94`). Tapping it: a staged photo is discarded (`.unchanged` if the bot had no saved photo,
else `.removed`); the face becomes the head; no confirmation (the web has none; nothing is written until Save, and
leaving with a change asks through the existing `EditingGuard`). **DECISION:** always "Remove Picture" (the web says
"Remove Pet" on its Pet tab, which native does not have).

### 5.6 Gateways without pictures, read-only gateways

- **DECISION:** when no roster row carries a `has_avatar` key (a gateway older than the asset store), the Picture
  section is exactly today's (the face, Edit Head and its note; no tabs, no Upload). Why: never show a control that
  does nothing.
- On a read-only gateway (`BotStore.readOnlyGateway`) Save fails the way it does today, with
  `BotWriteError.readOnlyReason`.

### 5.7 New Bot

Unchanged: New Bot shows the default head and "The bot gets a shape from its name. You can change it once the bot is
created." (`NAT/App/Bots/NewBotViewController.swift:146-147`; `S/ui-heads/renderer-hooks.tsx:57`). No tabs there.

---

## 6. The photo picker (L228)

`BotPhotoPicker.present(from: UIViewController, source: .library | .file, completion: (Result<PickedPhoto, PickError>?) -> Void)`;
`nil` = cancelled. `PickedPhoto` = a `CGImage` at most 1024 px on its long side, upright, plus its pixel size.

### 6.1 Photo Library

`PHPickerViewController` with `PHPickerConfiguration()` (no photo library object, so **no permission prompt**),
`selectionLimit = 1`, `filter = .images`, `preferredAssetRepresentationMode = .current`. With a limit of one, a tap
picks and closes; there is no Add button (the reason the web left WebKit's picker, `S/ui-bots/photo-pick.ts:1-2`).
**DECISION:** images only (the shell's shared picker also lists videos, `IOS/App/HermesPicker.swift:123`). Why: a
video cannot be a face.

On a pick: load the file representation for `UTType.image`, copy it into the app's temporary folder inside the load
callback, and read it (§6.3). The copy is deleted as soon as it has been read (B31).

### 6.2 Choose File

`UIDocumentPickerViewController(forOpeningContentTypes: [.image], asCopy: true)`, one file. **DECISION:** images
only (the shell opens any item, `IOS/App/HermesPicker.swift`). Why: the Files browser greys out what can't be a
picture instead of failing afterwards. The copy iOS makes is moved into the same `tmp/bot-photo-picks` folder as the
photo picker's copies and goes the same way; Move and Scale opens once the browser's own closing has finished (B31, B33).

### 6.3 The read

`PhotoNormalizer.thumbnail(url, maxPixel: 1024)` (`NAT/HermesKit/Attachments/PhotoNormalizer.swift:97`): an ImageIO
thumbnail with the EXIF transform applied, never a full-size decode, off the main actor. Location and camera details
never leave the phone: only pixels reach the framer, and the upload is a fresh PNG. A file over 32 MB is refused
before decoding (the shell's limit, `IOS/App/HermesPlatform.swift:1124`). An animated GIF or WebP gives its first
frame. A photo smaller than 1024 px is used as it is (never enlarged here).

### 6.4 States and wording

| State | What the user sees |
| --- | --- |
| Menu, picker or Files cancelled | back on Edit Bot, nothing changed, nothing said |
| Picked, still loading (iCloud download, big file) | the framer opens at once with a white spinner in the frame (VoiceOver: "Loading photo"); slider and Choose disabled; Cancel works and stops the load |
| Loaded | the framer shows the photo (§7) |
| File over 32 MB | framer closes; alert **Couldn’t Use That Picture**: "That picture is too big. Choose one under 32 MB." — OK |
| Not a readable picture (corrupt, wrong type, download failed) | framer closes; alert **Couldn’t Use That Picture**: "That file isn’t a picture this app can read. Choose a photo or an image file." — OK |

**DECISION:** the two alerts are native's (the web says nothing when a read fails). Why: a tap with no result reads
as broken; this was a real bug on the web ("first pick after launch silently did nothing",
`MEM/photo-head-chat-bar-corners.md`).

---

## 7. Move and Scale (L229)

Owner asked for this on 2026-10-02: "pinch, drag, slider, wheel; zoom from fit-whole-photo to 5×; gaps filled with a
blurred copy; output 256px PNG like the renderer's uploads", then "ship it as the next build"
(`MEM/photo-head-chat-bar-corners.md`).

### 7.1 Presentation

`PhotoFramerController` inside a `UINavigationController`, `modalPresentationStyle = .fullScreen`,
`overrideUserInterfaceStyle = .dark`, black background, presented from the Bot Info sheet's navigation controller
once the picker has gone. **DECISION:** it stays a full-screen cover over the sheet. Why: the web's is
(`data-ios-presentation="cover"`), iOS's own Move and Scale is, and a page inside the sheet would fight the sheet's
swipe-down and the back swipe for every drag. The owner's "no pop up on top of a pop up" rule is about sheets on
sheets.

- Navigation title **Move and Scale** (small title, no back button, no close button).
- Bottom toolbar: **Cancel** (plain) — flexible space — **Choose** (`.prominent`, disabled through
  `setProminentEnabled(false)` until the photo has loaded and while rendering). **DECISION:** the bars are system
  bars (Liquid Glass on iOS 26+), not the web's bare text on black, and Choose is the one filled button ("Save the
  only filled button", `MEM/head-save-ux.md`).
- Layout top to bottom: stage (all remaining height, edge to edge), zoom row, toolbar. Zoom row: width
  `min(view width − 32, 420)`, centred, 14 pt above, 4 pt below: `photo` symbol at 16 pt, a `UISlider` (at least
  44 pt tall), `photo` symbol at 24 pt; glyphs white at 75 %.
- Frame side = `min(stage width − 32, stage height − 32, 420)`; recomputed on every layout (rotation, iPad
  resize); the placement is in frame units, so it survives a resize untouched.
- Supports every orientation the app supports. Status bar light.
- Swipe-to-dismiss is not available (full screen); Cancel is the way out. The hardware Escape key and the
  accessibility escape gesture both mean Cancel.

### 7.2 The placement model (pure, unit tested)

`HermesKit/Model/PhotoFrame.swift`, a line-for-line port of `S/ui-bots/photo-frame-model.ts`. Lengths are in frame
sides (1 = the frame's width); x and y are the photo centre's offset from the frame centre.

```swift
nonisolated struct PhotoFrame: Equatable, Sendable {
    var zoom: Double, x: Double, y: Double
    static let maxZoom = 5.0
    static let start = PhotoFrame(zoom: 1, x: 0, y: 0)

    static func minZoom(_ p: CGSize) -> Double            // min(w,h) / max(w,h); 1 when that is 0
    static func drawnSize(_ p: CGSize, zoom: Double) -> CGSize   // (w/short·zoom, h/short·zoom); short = min(w,h), 1 when 0
    func clamped(_ p: CGSize) -> PhotoFrame               // zoom into [minZoom, 5]; |x| ≤ |drawn.w − 1|/2; |y| ≤ |drawn.h − 1|/2
    func panned(_ p: CGSize, dx: Double, dy: Double) -> PhotoFrame   // (x+dx, y+dy).clamped
    func zoomed(_ p: CGSize, ratio: Double, focusX: Double = 0, focusY: Double = 0) -> PhotoFrame
        // z' = clamp(zoom·ratio); a = z'/zoom; x' = focusX + (x − focusX)·a; y' likewise; then clamped
    func rect(_ p: CGSize, edge: Double) -> CGRect         // w = drawn.w·edge; x = edge/2 + self.x·edge − w/2 (same for y)
    func leavesGaps(_ p: CGSize) -> Bool                   // drawn.w < 1 − 1e-6 || drawn.h < 1 − 1e-6
}
```

Zoom 1 fills the frame with the photo's short side. A photo larger than the frame always covers it; a smaller one
stays inside it (`:22-27`). Port the web's test vectors unchanged (`S/photo-framer.test.ts:15-41`), e.g. a 200 × 100
photo: `rect(start, edge: 100) == (−50, 0, 200, 100)`, `minZoom == 0.5`, `start.panned(dx: 3, dy: 3) == (1, 0.5, 0)`,
and a pinch `zoomed(ratio: 2, focusX: 0.25, focusY: 0.25)` from start `== (2, −0.25, −0.25)`.

### 7.3 Stage and gestures

Views, back to front, inside a `side × side` space centred in the stage: the blurred backdrop (only while
`leavesGaps`), the photo (`frame = view.rect(photo, edge: side)`), the window overlay.

- **Window:** a full-stage overlay with 60 % black everywhere except an app-icon-shaped hole of the frame
  (`cornerRadius = side × 0.2237`, continuous, even-odd fill), and a 1 px white line at 55 % round the hole. Not
  interactive. What stays bright is what the bot will wear.
- **Backdrop:** clipped to the frame shape; the image from §7.5 drawn at the "fill" rect × 1.15, centred.
- **Drag:** `UIPanGestureRecognizer` (1–2 touches) → `panned(dx: Δx / side, dy: Δy / side)` per change.
- **Pinch:** `UIPinchGestureRecognizer`, recognised together with the pan → `zoomed(ratio: scale, focusX:, focusY:)`
  with the focus = the pinch location relative to the frame centre, in frame sides; reset `scale` to 1 after each
  change. Two fingers moving together also pan (the pan recogniser reports the centroid), which is the web's
  midpoint drag.
- **Slider:** min `minZoom(photo)`, max 5, linear, continuous → `zoomed(ratio: value / zoom)` about the centre
  (`S/ui-bots/photo-framer.tsx:126-131`). It follows pinches. For a square photo it runs from 1 to 5.
- **Double tap:** back to `start` (`:114`), animated over 0.2 s, or at once with Reduce Motion.
- A trackpad pinch on iPad arrives through the pinch recogniser. **DECISION:** no separate mouse-wheel handler (the
  web has one, `:95-99`). Why: an iPhone has no wheel; the slider covers a mouse on iPad.
- Every change is applied in the same frame, without animation or rubber-banding (the model clamps).
- A light selection haptic when zoom hits either end. Nothing else.

### 7.4 Accessibility

- The stage is one element: label "Photo", hint "Pinch or use the zoom slider to size the photo, and drag it to place
  it in the frame." (`S/ui-bots/photo-framer.tsx:38`).
- The slider: label "Zoom" (`:126`), value "N percent" (zoom × 100, rounded), adjustable in steps of a tenth of its
  range.
- **DECISION:** the stage also offers custom actions "Move Left", "Move Right", "Move Up", "Move Down" (0.05 of a
  frame side each; each announces "Moved" or "At the edge") and "Reset". Why: a VoiceOver or Switch Control user
  cannot drag; the web gives them the slider only.
- Cancel and Choose are ordinary bar buttons. The title and the bar are system bars: they cap their own text growth
  and offer the Large Content Viewer, and the zoom row has a fixed height, so text size does not shrink the frame.
  On iPhone 17 Pro the frame is at least 160 pt in both orientations at every text size.
- The photo and backdrop ignore Smart Invert.

### 7.5 Choose: the picture that is stored

`PhotoFramerRenderer.png(photo: CGImage, view: PhotoFrame) -> Data`, off the main actor:

1. A 256 × 256 pixel bitmap (`UIGraphicsImageRendererFormat`: `scale = 1`, `opaque = true`,
   `preferredRange = .standard`, so sRGB 8-bit; a wide-colour photo does not become a 16-bit PNG).
2. If `view.leavesGaps(photo)`: draw the backdrop — the photo at `PhotoFrame.start.rect(photo, edge: 256)` grown
   1.15× about the centre, Gaussian-blurred with sigma `256 × 0.05` = 12.8 px (`S/ui-bots/photo-framer.tsx:21-26`).
   **DECISION:** the blur input is edge-clamped, so the stored picture is fully opaque (the web's canvas blur fades
   to clear at the very edge). Why: a see-through rim shows as a dark line on a light list.
3. Draw the photo at `view.clamped(photo).rect(photo, edge: 256)`, high interpolation.
4. PNG → `data:image/png;base64,…`.

The result is always exactly 256 × 256 (`PHOTO_EDGE`, `:11`), so it can never be mistaken for a mirror (288) or a
backfill (160), and is far under the gateway's 2 MB. The stored picture is square; corners are applied when it is
drawn. The same backdrop image (rendered once at 256 px when the photo loads) feeds the live preview.

Choose shows "Choose" disabled for the few milliseconds the render takes, then the cover closes and Edit Bot has
`picture = .photo(image, dataURL)`. Cancel closes the cover and changes nothing.

### 7.6 States

| State | Stage | Slider | Choose |
| --- | --- | --- | --- |
| Loading | spinner in the frame, window drawn | disabled | disabled |
| Ready | photo at `start` | enabled | enabled |
| Rendering | unchanged | disabled | disabled |
| Load failed | cover closes, alert from §6.4 | – | – |
| App goes to the background and returns | unchanged, same placement | – | – |
| Memory warning | keeps the 1024 px photo (about 4 MB); drops the backdrop and rebuilds it when next needed | – | – |

---

## 8. Saving and removing (wire)

Nothing is written until Edit Bot's **Save** (bar button, `edit-bot.save`, "Save" → "Saving…", as today).

`BotStore.saveEdit(name:title:description:picture:)`; `picture` is `nil`, `.photo(dataURL)` or
`.remove(mirror: String?)` (the App layer passes the 288 px mirror of the bot's saved head from
`EditHeadView.mirrorPNG`, or `nil` when the bot has no saved head record). `EditOutcome` gains
`pictureApplied: Bool?`. All of it runs inside the existing per-bot serial queue (`editing.serial(name)`), so it can
never interleave with a head save or a pin.

### 8.1 A new photo

1. Upload, awaited, 30 s:

   ```json
   {"method":"profiles.set_asset","params":{"name":"ivy","asset":"avatar","data":"data:image/png;base64,iVBORw0KGgo…"}}
   ```
   ```json
   {"result":{"ok":true,"asset":"avatar","size":148213}}
   ```

2. On `ok == true`: `photos.adopt("ivy", dataURL:)` (every face on this phone changes now), patch the cached roster
   row `has_avatar = true`.
3. One `profiles.configure`, carrying the picture flags and any Title / Description change together:

   ```json
   {"method":"profiles.configure","params":{"name":"ivy","ui_meta":{"hermes-bots":{"sectionId":"sec-work","sectionName":"Work","created":1790000000001,"imageKind":"photo","custom":true}}}}
   ```
   ```json
   {"result":{"ok":true,"applied":{"ui_meta":true,"ui_meta_revisions":{"hermes-bots":2}}}}
   ```

   The `hermes-bots` object is the whole object, built the way `writeBotMeta` builds it (fresh slim read, merge,
   `sendable` strips `image` and `pet`); only `imageKind` and `custom` are added (`HB/edit-profile-dialog.tsx:96-110`).
   The returned revision goes to `photos.noteMetaWrite`.

**DECISION:** the upload goes first and is awaited (the web configures first and fires the upload without waiting,
`HB/data.ts:314-410`). Why: (a) a failed upload must be told ("a save with no visible result reads as 'no save'");
(b) other phones refetch when the `hermes-bots` revision moves (§4.3), so the picture must already be there.
If the upload fails, the flags are not written; Title and Description still are.

### 8.2 Removing a photo

1. `.remove(mirror: png)` for a bot with a saved head: `profiles.set_asset {"name":"ivy","asset":"avatar","data":"<288 px mirror>"}`.
   `.remove(mirror: nil)`: `profiles.set_asset {"name":"ivy","asset":"avatar","clear":true}` →
   `{"ok":true,"asset":"avatar","size":0,"removed":1}`. Success is `ok == true`; read nothing else from the answer.
2. `photos.adopt` with the mirror (or `nil`), patch `has_avatar`.
3. `profiles.configure` with `"imageKind":"shape","custom":true` in `hermes-bots`.

**DECISION:** a bot with a saved head gets its mirror back instead of an empty avatar (the web just clears). Why:
the Head tab promises "Every phone on this gateway and desktop Hermes show the same picture"; with an empty avatar
desktop draws its own face until the next head save.

### 8.3 Saving or resetting a head while a photo is set

`saveHead` is unchanged. Right after it persists, `photos.headSaved(name)` drops the photo locally (verdict
`mirror`), then the existing `mirrorHead(name:png:)` uploads the 288 px PNG and `adopt`s it. If that upload fails
and a photo was replaced, retry after 2 s and 8 s; after that the next refetch signal decides (the gateway is the
truth, so the photo can come back; listed in §15). Reset Head: unchanged (`get_asset`, clear only a mirror); the
answer is `adopt`ed, so a photo stays a photo.

### 8.4 Outcomes and wording

| Outcome | What the user sees |
| --- | --- |
| Everything applied | success haptic, back to Bot Info; its 80 pt face, the list row and the chat title already show the new picture |
| Upload refused or failed | page stays, staged picture kept; alert **Couldn’t Save the Picture** + reason; **Try Again** / OK (the existing `FailureAlert`, with Show Details) |
| Title or Description refused | today's alerts ("Couldn’t Save Changes", "Couldn’t Save the Description"); a picture that did apply is not sent again on Try Again |
| Leaving with a staged picture | the existing `EditingGuard` question |
| App killed mid-save | nothing staged survives; the gateway has either the old or the new picture, never half (§12.6) |

Reasons for **Couldn’t Save the Picture**:

| Cause | Reason text |
| --- | --- |
| timeout, socket closed, offline | "The gateway didn’t answer. Check the connection and try again." (today's wording, `NAT/HermesKit/Store/BotStore+Editing.swift:625`) |
| method not found / 4000 on an older gateway | "This gateway can’t store bot pictures yet. Update Hermes on the computer, then try again." |
| 4069 (over 2 MB) | "The picture is too big for the gateway. Choose another one." |
| 4070 (format) | "The gateway didn’t accept that picture. Choose another one." |
| read-only gateway | `BotWriteError.readOnlyReason` |
| anything else | the gateway's own message |

**DECISION:** these are native's words (the web shows a toast, "Saved look locally; remote persistence failed",
only when the configure fails, and nothing when the upload fails). Why: plain language, and the owner's save rule.

---

## 9. The permission string (L1027)

Add to `NAT/App/Info.plist`, next to the camera string:

```xml
<key>NSPhotoLibraryUsageDescription</key><string>Choose photos to attach to your chat or to use as a bot’s picture.</string>
```

- **DECISION:** this wording, not the web's "Select photos to attach to your Hermes HQ chat." Why: the same plist
  serves both identities ("HQ Native" and "Hermes HQ"), native's camera string already dropped the app name
  ("Take a photo to attach to your chat."), and the string now also has to cover bot pictures.
- The system never shows it today: both pickers run out of process and need no permission. It is there so that a
  later feature that does ask for the library has a string and the row is closed. Do not add
  `PHPhotoLibrary.requestAuthorization` anywhere.
- No `PrivacyInfo.xcprivacy` change (no new required-reason API).
- Check: `plutil -p` on both built apps shows the key; `grep -ri dispatch` on the string finds nothing.

---

## 10. Stand-in gateway, pictures and the run script

Never the owner's gateway, never a port this stream did not start. Builder ports **9950–9954**, stress tester
**9955–9959**. Builder simulator `HQN-m9-photoheads`, stress simulator `HQN-m9-photoheads-s`
(`xcrun simctl create "<name>" "iPhone 17 Pro" com.apple.CoreSimulator.SimRuntime.iOS-27-0`, reused if it exists;
always pass its UDID; shut it down at the end of the stage). Derived data: `HQN_DD=build/dd-photoheads`.

### 10.1 `scripts/fixtures/photoheads-gateway.py` (new)

The settings fixture already speaks `profiles.set_asset` / `get_asset` / `has_avatar` with the contract's key
checks (unknown key → 4000) and the gateway's error codes (`NAT/scripts/fixtures/settings-gateway.py:51-52`,
`:340-372`), but seeds every avatar empty (`:113`) and cannot fail `get_asset`. The new fixture **loads that file by
path** (`importlib.util`, the way it loads the voice fixture) and adds to it without editing it (the `settings`
stream is working in it):

- **Seed** (same six bots, plus three):

  | Bot | Head record | Avatar | Expected face |
  | --- | --- | --- | --- |
  | `default` (Hermes) | saved | 288 × 288 PNG (mirror) | head |
  | `ivy` | none | 256 × 256 PNG, "photo A" | photo |
  | `research` | saved | 640 × 480 JPEG | photo, centre-cropped |
  | `inbox` | none | 160 × 160 PNG (backfill) | default head |
  | `deploys` (hidden) | none | 96 × 104 PNG (pet-like) | photo, centre-cropped |
  | `notes` | none | none (`has_avatar` false) | default head |
  | `webp` | none | WebP | photo |
  | `broken` | none | PNG header, truncated body | default head |
  | `huge` | saved | 1.9 MB JPEG, 4000 × 3000 | photo |

  PNGs are written by the fixture itself (zlib + struct; flat colours with a clear mark so a screenshot can tell
  photo A from photo B). JPEGs come from `--media` (§10.2). The WebP is a constant in the fixture; the builder must
  confirm ImageIO decodes it (a unit test) before relying on it, and must not download one.
- **Options:** `--port` (default 9950), `--credentials <file>` (0600, never printed), `--hermes-cookies`,
  `--label <name>` (second gateway: same profile names, different pictures), `--media <folder>`,
  `--bots N` (N extra bots `load-001…`, each with its own 256 px PNG), `--no-assets` (an older gateway: rows carry
  no `has_avatar`; both asset methods answer method-not-found).
- **Controls** (same sign-in as the app's, like `/__settings/*`):

  | Call | Does |
  | --- | --- |
  | `GET /__photoheads/state` | per bot: `has_avatar`, `avatar_mime`, `avatar_size`, `avatar_png` ([w, h] or null), `avatar_sha`, `image_kind`, `revisions`, `get_asset_calls`, `set_asset_calls`; and the write log (data as lengths only) |
  | `POST /__photoheads/other-device {profile, avatar, bump}` | another device changes the picture: `avatar` ∈ `photo-b`, `mirror`, `backfill`, `jpeg`, `webp`, `pet`, `broken`, `clear`; `bump` ∈ `hermes-bots`, `dispatch-head`, `null` (no revision change) |
  | `POST /__photoheads/fail {method, mode, count, seconds}` | `error` (5065 / 5066 "disk full"), `unknown-method`, `too-large` (4069), `bad-format` (4070), `slow` (default 35 s), `drop` (close the socket instead of answering), `found-no-data` (`{"found":true}`), `garbage` (`data` is not base64) |
  | `POST /__photoheads/net {mode, ms}` | `down` (close every socket, refuse new ones), `up`, `lag` (every answer waits `ms`) |
  | `POST /__photoheads/reset` | back to the seed |

### 10.2 `scripts/fixtures/make-photoheads-media.swift` (new)

`swift scripts/fixtures/make-photoheads-media.swift build/fixtures/photoheads-media` writes the pictures the tests
pick and the JPEG seeds, all drawn in code (no downloads, no real photos): `portrait.jpg` (3024 × 4032, EXIF
orientation 6, a coloured quadrant pattern so orientation and placement can be read from a screenshot), `wide.png`
(2000 × 500), `tall.png` (100 × 4000), `square.heic`, `tiny.png` (16 × 16), `alpha.png` (half transparent),
`anim.gif` (3 frames), `p3.png` (Display P3, 16-bit), `cmyk.jpg`, `corrupt.jpg` (a JPEG cut in half), `text.png`
(a text file with a `.png` name), `landscape.jpg` (640 × 480), `huge.jpg` (4000 × 3000, about 1.9 MB), and
`big.bin.jpg` (33 MB of noise with a JPEG header).

### 10.3 Start commands

Builders:

```sh
swift scripts/fixtures/make-photoheads-media.swift build/fixtures/photoheads-media
python3 scripts/fixtures/photoheads-gateway.py --port 9950 --hermes-cookies --credentials build/fixtures/photoheads-a.json --media build/fixtures/photoheads-media
python3 scripts/fixtures/photoheads-gateway.py --port 9951 --label Beta --credentials build/fixtures/photoheads-b.json --media build/fixtures/photoheads-media
python3 scripts/fixtures/photoheads-gateway.py --port 9952 --no-assets --credentials build/fixtures/photoheads-old.json
```

Stress tester: the same three on **9955**, **9956**, **9957**, with `--bots 200` on 9955; 9958 and 9959 are spare
(a second copy of A for the relaunch checks).

### 10.4 `scripts/e2e-photoheads.sh [SIM_UDID]` (new)

The shape of `scripts/e2e-settings.sh`: refuses busy ports, starts the fixtures above on
`HQN_PHOTOHEADS_PORTS` (default `"9950 9951 9952"`), stops only what it started, passes
`TEST_RUNNER_HQN_PHOTOHEADS_A/_B/_OLD`, `TEST_RUNNER_HQN_PHOTOHEADS_MEDIA` and `TEST_RUNNER_HQN_SHOTS`, runs
`-only-testing:HermesHQNativeUITests/PhotoHeadsEndToEndTests` on the given simulator with
`-derivedDataPath ${HQN_DD:-build/dd-photoheads}`, and prints `scripts/e2e-summary.py`. `HQN_E2E_ONLY` picks tests.
The simulator UDID is required when `HQ_SIM` is unset (no default simulator in this script).

DEBUG-only launch hooks (documented in `App/Debug/DebugHooks.swift`, compiled out of Release):

- `-HQDebugBotPhoto "<abs path>"`: the Upload menu's **Photo Library** item skips the system picker and feeds that
  file through the same import code (§6.3). The simulator's photo picker drops taps ("tap with duration 0.2 and
  re-screenshot", `MEM/photo-head-chat-bar-corners.md`), so the suite uses the hook and **one** test drives the real
  picker (pictures added with `xcrun simctl addmedia <UDID> build/fixtures/photoheads-media/portrait.jpg`).
- `-HQDebugBotPhotoDelay <seconds>`: that read waits first (the iCloud-download state).
- `-HQDebugUploadTimeout <seconds>` (added after review, B32): the upload's wait, 30 s without it.

---

## 11. Tests and acceptance checks

A row is done only when it is built **and seen working**: each check below names what must be observed, and each
UI check leaves a screenshot in `.build/shots/photoheads/` (light and dark for the ones marked ◐).

### 11.1 Unit tests (`Tests/PhotoHeads/`)

1. `PhotoFrameTests`: the web's vectors (`S/photo-framer.test.ts:15-41`) and: square photo `minZoom == 1`; 1 × 1000
   photo; zero-size photo does not divide by zero; `zoomed` at the limits returns a clamped view; `rect` round-trips
   through a resize of `edge`.
2. `BotPictureTests`: each row of §4.1, including a 288 × 288 **JPEG** (photo), a 288 × 289 PNG (photo), a
   160 × 160 PNG with `imageKind: "photo"` (still backfill), bad base64, a PNG header with no body, WebP, a data URL
   with a wrong mime label.
3. `PhotoFramerRendererTests`: output is a PNG, IHDR 256 × 256, opaque at all four corners with and without gaps;
   an orientation-6 source comes out upright; a P3 16-bit source gives an 8-bit PNG under 400 KB.
4. `BotPhotoStoreTests` (fake `GatewayClient`): every row of the §4.3 table; one fetch at a time; the 2 s + 10 s
   follow-up; `adopt` and `noteMetaWrite` cause no call; the retry ladder; `removeCachedData` empties the folder;
   two accounts with the same profile name do not share a verdict; a corrupt `index.json` loads as empty.
5. `BotStoreEditingTests` additions: §8.1–8.3 call order and exact params (no extra keys); a failed upload sends no
   `imageKind`; `.remove(mirror:)` sends the mirror, `.remove(nil)` sends `clear`.
6. Added after review. `BotFacesTests`: faces are told only when the picture can be drawn; a head's key is the same
   on every launch (literal digests); a photo that cannot be drawn yet is never handed out, kept or cut as a photo;
   the face kept for pushed alerts decodes to the photo, then to the head once the photo is removed, and is not kept
   for an account that is no longer signed in. `BotPhotoStoreTests`: `supportsAssets` survives a relaunch and tells
   the registry when it is learned; a file that can never be kept is fetched three times in all, not for ever; the
   upload's wait is 30 s. `PhotoPickFilesTests` (new suite): a pick's file goes when its holder does, when the load
   finishes, is cancelled or is let go; leftovers older than a given time are removed; a file the pick did not make
   is left alone.

### 11.2 UI tests (`UITests/photoheads/PhotoHeadsEndToEndTests.swift`, fixture A unless said)

| # | Row | Check |
| --- | --- | --- |
| P1 ◐ | L819 | Bots list after sign-in: `ivy`, `research`, `webp`, `huge` show photos with app-icon corners; `default`, `inbox`, `notes`, `broken` show heads. Fixture state: exactly one `get_asset` per bot with `has_avatar`, none for `notes`. |
| P2 ◐ | L819 | Open `ivy`'s chat: the 34 pt title face is the photo with a corner near 7.6 pt (not a circle); Bot Info's 80 pt face is the same photo. |
| P3 | L819 | Relaunch offline (`net down` before launch): the same photos, no `get_asset` calls after `net up` within 5 s. |
| P4 | L819 | `other-device {ivy, photo-b, bump: hermes-bots}`: the list row changes to photo B without a relaunch. `other-device {ivy, mirror, bump: dispatch-head}`: it becomes the head. `other-device {ivy, clear}`: head on the next roster poll. |
| P5 | L819 | Switch to gateway B (Beta): `ivy` shows B's picture; switch back: A's. Remove gateway B: its `botphotos-…` folder is gone. |
| P6 ◐ | L820 | Edit Bot for `notes`: Picture shows the face, **Head** / **Upload**, Head selected, **Edit Head**, the default note, no Remove Picture. Save is disabled. |
| P7 | L820 | Head tab → Edit Head → change colour → Save: back on Edit Bot the note reads "Head saved. It’s on every device on this gateway."; fixture avatar is a 288 × 288 PNG. |
| P8 | L820, L819 | Edit Bot for `ivy` (has photo A): note "This bot shows a photo. Saving a head replaces it."; Remove Picture is there. Edit Head → Save: the face is now the head on Edit Bot, Bot Info and the list; Remove Picture is gone; fixture avatar is the mirror. |
| P9 | L820 | Edit Bot for `default` (mirror): no Remove Picture on either tab. |
| P10 ◐ | L228 | Upload tab → **Choose an image…**: a menu with **Photo Library** and **Choose File**, in that order; dismissing it changes nothing. |
| P11 | L228 | Real picker (one photo added with `simctl addmedia`): one tap on a photo closes the picker and opens Move and Scale; there is no Add button and no permission prompt. |
| P11b | L228 | Real Files browser (added after review; `scripts/e2e-photoheads.sh` copies `photoheads-pick.jpg` into the simulator's On My iPhone): Choose File → the file → Move and Scale opens with the turned portrait upright; Choose stages it; nothing of the pick is left in the app's `tmp`; cancelling the browser changes nothing. |
| P12 | L228 | Hook with `portrait.jpg`: Move and Scale shows it upright (the quadrant colours are in the right corners). Hook with `corrupt.jpg`, `text.png`, `big.bin.jpg`: the alerts of §6.4, word for word; Edit Bot unchanged. |
| P13 ◐ | L229 | Move and Scale: title, app-icon window with the dimmed surround, slider, Cancel, Choose. `-HQDebugBotPhotoDelay 3`: spinner, slider and Choose disabled, Cancel works. |
| P14 | L229 | Drag: the photo follows and stops at the frame edge (no gap can be dragged in). Pinch out (`pinch(withScale:)`): zoom grows, the slider follows, stops at the right end. Slider to the left end with `wide.png`: the whole photo is inside the frame and the gaps are blurred (not black). Double tap: back to the start. |
| P15 | L229, L820 | Choose: back on Edit Bot, the 72 pt face is the framed photo, Save is enabled, the fixture has **no** `set_asset` yet. Cancel in the framer instead: nothing changed, Save disabled. |
| P16 | L820, L819 | Save: fixture shows one `set_asset` (PNG 256 × 256) **then** one `profiles.configure` whose `hermes-bots` has `imageKind: "photo"`, `custom: true` and every key it had before; Bot Info, the list row and the chat title show the photo. |
| P17 | L820 | Remove Picture → Save on `research` (saved head): fixture avatar is a 288 × 288 PNG, `imageKind: "shape"`; face is the head. On `ivy` (no saved head): avatar cleared, `has_avatar` false. |
| P18 | L820 | `fail {profiles.set_asset, error}` then Save: **Couldn’t Save the Picture**, page and staged photo kept; Try Again succeeds. `fail {…, unknown-method}`: the "can’t store bot pictures yet" reason. |
| P19 | L820 | Gateway `old` (`--no-assets`): Edit Bot's Picture has no tabs and no Upload; Edit Head still works; no `get_asset` call was ever made. |
| P20 | L820 | Leave Edit Bot with a staged photo: the discard question; Keep Editing keeps the photo. |
| P21 | L819 | With `ivy` wearing a photo, a pushed reply from `ivy` (the push fixture pattern, or a local notification through `NotificationHub`) shows the photo as the sender picture; the reply peek's face is an app-icon tile, not a circle. |
| P21b | L819 | Added after review: with `ivy` wearing a photo and `reply-delay` set, send to `ivy`, go back to Bots, press Home: the reply alerts on the Home Screen as from Ivy. In the original record's build (`HQ_IDENTITY=original`, the one with the Communication Notifications entitlement) the sender's picture is photo A; the other build shows the app's icon. A pushed alert itself cannot be seen on a simulator (`simctl push` never runs the notification extension); what the extension would read is unit tested (`thePushedAlertFaceIsThePhotoThenTheHead`). |
| P22 | L1027 | `plutil -p` of the built app's Info.plist for both identities shows `NSPhotoLibraryUsageDescription` with §9's string. |

Rerun a failing UI test once before calling it a failure; never loosen an assertion to pass.

---

## 12. STRESS PLAN

For the stress tester, on simulator `HQN-m9-photoheads-s`, ports 9955–9959, own derived data. Each item says what
to do and what must hold. Screenshots to `.build/shots/photoheads-stress/`. A finding is a bug unless this spec
says the behaviour is intended.

### 12.1 Load

1. `--bots 200` (every bot has a photo), fresh install: sign in, leave the list alone. Must hold: the list is usable
   at once; fetches run one at a time (fixture `get_asset_calls` rises steadily, never two in flight); all 200 show
   photos eventually; memory stays under the app's normal footprint + 30 MB; no hang over 250 ms in the log.
2. Fling the 200-bot list top to bottom five times: no dropped-frame run longer than 100 ms; no head left on a row
   whose bot has a photo once scrolling stops.
3. `huge` (1.9 MB JPEG): its cached file is a 256 px PNG; nothing on disk for this bot is over 400 KB.
4. Total `botphotos-…` folder for 200 bots under 40 MB.
5. `other-device` on 50 bots in a loop (photo B, bump): every row ends on photo B; the queue drains; no duplicate
   fetch storms (at most 3 `get_asset` per bot per change).
6. Save a photo 30 times in a row on one bot (alternate two pictures): 30 `set_asset`, in order; the face always
   ends on the last one; no growth in the folder.

### 12.2 Speed

1. Tap on a photo in the picker → Move and Scale visible: under 0.7 s for a 12 MP photo on the simulator.
2. Drag and pinch a 1024 px photo for 20 s (Instruments or the app's own frame log): no frame over 16.7 ms attributed
   to the framer on the main thread; the backdrop is never re-blurred per frame.
3. Choose → cover gone: under 0.3 s. Save → back on Bot Info with the new face: under 1 s on the local fixture.
4. Cold launch with 12 cached photos visible: the first frame of the Bots list already shows photos (screen
   recording, frame by frame); launch time within 30 ms of a launch with no photos.
5. No image decode on the main thread except the bounded first-paint decode of §4.4 (check with the main-thread
   checker / signposts).

### 12.3 Bad network

1. `net down` at launch with nothing cached: heads everywhere, no alert, no spinner; `net up`: photos arrive.
2. `fail {profiles.get_asset, slow}` (35 s): the fetch times out silently, the queue moves on to the next bot, the
   slow one is retried later.
3. `fail {profiles.get_asset, drop}` mid-queue: the app reconnects, the queue resumes, no bot is skipped forever.
4. `net down` while on Edit Bot with a staged photo, then Save: **Couldn’t Save the Picture** with the "didn’t
   answer" reason within 31 s; the staged photo is still there; `net up` + Try Again succeeds with exactly one
   `set_asset` stored.
5. `fail {profiles.set_asset, slow}` then Save: "Saving…" holds, Cancel is disabled, the page cannot be dismissed
   (a pull down on the sheet does nothing and asks nothing while a Save is on its way: `EditingPage.isSaving`,
   repair round 1; a discard question already up when a Save starts is taken down);
   after the timeout the alert shows. If the slow answer was in fact applied on the gateway, the next refetch
   signal shows the gateway's picture (no ghost state).
6. `lag 3000`: everything still works; the list never blocks on a picture.
7. Upload succeeds but `profiles.configure` fails (`/__settings/fail`): the photo shows everywhere (the picture is
   saved); the alert is the existing "Couldn’t Save Changes"; Try Again sends only the configure.
8. Sign-in expires during a fetch (short `--access-ttl`): no sign-in loop, no retry storm; the photos come after the
   normal re-sign-in.

### 12.4 Bad data

1. `broken`, `garbage`, `found-no-data`: head shows, no crash, verdict `unreadable` / `none`, not refetched every
   poll.
2. Each file from §10.2 through the hook: `tiny.png` (framer works, blurry is fine), `tall.png` and `wide.png`
   (minimum zoom shows the whole photo with blurred gaps; the slider is usable at both ends), `alpha.png` (the
   stored PNG is opaque; transparent areas come out black or blurred, never garbage), `anim.gif` (first frame),
   `p3.png`, `cmyk.jpg`, `square.heic` (correct colours, upright), `corrupt.jpg` / `text.png` / `big.bin.jpg`
   (the right alert).
3. All eight EXIF orientations of one picture: upright in the framer and in the stored PNG.
4. `other-device {…, pet}` (96 × 104) and `jpeg` (640 × 480): centre-cropped, not stretched, at every face size.
5. A gateway that answers `get_asset` with a `mime` that does not match the bytes: classified by the bytes.
6. A roster where `has_avatar` flips true/false on alternate polls: no flicker loop, at most one fetch per flip.
7. `ui_meta["hermes-bots"]` holding unknown keys, a huge object, or `image` / `pet` keys from an old client: Save
   keeps the unknown keys, never sends `image` or `pet`, and adds only `imageKind` and `custom`.
8. A profile name with spaces, emoji or 200 characters: cache file names stay valid (hashed), faces still resolve.
9. Send-side strictness: capture every `profiles.set_asset` / `get_asset` the app sends during the whole stress run;
   the fixture must have answered **zero** 4000s.

### 12.5 Interruption

1. Background the app with the framer open for 60 s, return: same photo, same placement, Choose works.
2. Background with the system photo picker open; return; pick: the framer opens.
3. Rotate to landscape and back in the framer (mid-drag too): the placement is unchanged, the frame resizes, no
   jump.
4. Incoming notification banner / Control Centre pull over the framer mid-pinch: the gesture ends cleanly, no stuck
   zoom.
5. Memory warning (`simctl spawn … notifyutil` / Debug menu) in the framer and on the Bots list: no crash; faces
   come back.
6. The Bot Info sheet is dismissed by a gateway switch or sign-out while the picker or framer is up: everything
   closes, nothing is written, no crash, no orphan cover.
7. Switch gateways while 100 fetches are queued: the queue stops; nothing from A is ever shown under B.
8. Another phone changes the same bot's picture while this phone has a staged photo: this phone's Save wins (last
   writer); no alert; all faces agree with the fixture afterwards.
9. While a photo Save shows "Saving…", the whole page is disabled: confirm Edit Head, the tabs and Remove Picture
   cannot be tapped, so a head save cannot race it on this phone. Then race it from another device
   (`other-device mirror` during a `slow` Save): the final face matches the fixture's final avatar within 15 s.
10. The bot is deleted on another device while Edit Bot is open with a staged photo, then Save: the existing
    "bot is gone" handling, no crash.
11. Double-tap Choose, double-tap Save, tap Cancel and Choose together: one render, one upload, no double pop.
12. A phone call / Siri over the document picker: returns intact.

### 12.6 Relaunch

1. Kill the app with a staged photo (before Save): after relaunch the bot has its old picture; the gateway saw no
   `set_asset`; no temporary file is left in the app's temp folder after the next launch.
2. Kill during "Saving…" (`fail slow`): after relaunch the face equals the fixture's avatar (old or new), reached
   through the normal refetch, and `imageKind` may lag behind harmlessly; a second Save fixes it.
3. Kill during the fetch queue: the next launch continues with the bots that have no verdict; none fetched twice.
4. Cold launch offline: every cached photo shows.
5. Delete and reinstall, sign in: photos come back from the gateway.
6. Sign out: the `botphotos-…` folder is gone; the Keychain push faces for that account are gone (existing
   behaviour); sign back in: refetched.
7. Truncate `index.json` or a `.png` by hand between launches: no crash; that bot is refetched.
8. Upgrade path: install the previous train build, sign in, install this build over it: no migration needed,
   photos appear after the first roster.

### 12.7 Accessibility sizes and settings

1. Dynamic Type at each of xSmall, Large (default), AX1, AX3, AX5: Edit Bot's Picture section (both tabs, all four
   notes, Remove Picture) wraps without clipping, rows keep 12–14 pt of vertical padding, the segmented control
   stays readable; Edit Head and Choose an image… stay at least 44 pt tall (repair round 1: a 30 pt minimum on the
   bordered button's label); Move and Scale keeps a frame of at least 160 pt in portrait and landscape, the slider's
   row stays at least 44 pt tall, and Cancel and Choose are the system bar's own buttons (at least 44 pt wide, 38 pt
   tall as iOS draws every bar button: DECISION B24) and on screen; every alert of §6.4 and §8.4 fits.
2. VoiceOver, whole flow without sight: Edit Bot → Picture → Upload → Choose an image… → Photo Library (hook) →
   Move and Scale (stage label and hint, Zoom slider adjustable, Move actions, Reset) → Choose → Save. Every control
   has a spoken name; no bare image is focusable; the face previews are hidden from VoiceOver as heads are today;
   the "Head saved" note is announced when it appears.
3. Smart Invert and Classic Invert: photos are not inverted under Smart Invert (list, title, Edit Bot, framer).
4. Reduce Motion: double-tap reset does not animate; nothing else in this feature animates on its own.
5. Increase Contrast and Bold Text: the window line and the dim are still visible; text does not truncate.
6. Reduce Transparency: bars fall back to the system's opaque style; nothing custom to break.
7. Switch Control / Full Keyboard Access: every control reachable; Escape cancels the framer; the stage's actions
   are in the actions menu.
8. Right-to-left (`-AppleLanguages (ar)` pseudo-run): Cancel and Choose swap sides with the system; dragging right
   still moves the photo right.
9. Dark and light: every screenshot of §11.2 marked ◐; the framer is dark in both.
10. Largest text + landscape + VoiceOver on together in the framer: still operable.

---

## 13. DECISION list

| # | Decision | Where |
| --- | --- | --- |
| D1 | No Generate tab, no Pet tab; such pictures still show and can be removed | §5.2 |
| D2 | A 160 × 160 PNG is never a photo, whatever `imageKind` says | §4.1 |
| D3 | The avatar is refetched on signals (web: once per device) | §4.3 |
| D4 | Saving a head drops the photo on this phone at once; the Head tab says so beforehand | §5.3, §8.3 |
| D5 | "Remove Picture" wording only | §5.5 |
| D6 | No tabs and no Upload on a gateway without the asset store | §5.6 |
| D7 | Library picker and file picker list images only | §6.1, §6.2 |
| D8 | Alerts when a picked file can't be used | §6.4 |
| D9 | The framer stays a full-screen cover over the sheet | §7.1 |
| D10 | System bars with a prominent Choose | §7.1 |
| D11 | No mouse-wheel handler | §7.3 |
| D12 | VoiceOver Move / Reset actions on the stage | §7.4 |
| D13 | The stored picture is fully opaque (edge-clamped blur) | §7.5 |
| D14 | Upload first, awaited, failure told; flags only after it succeeds | §8.1 |
| D15 | Removing a photo puts a saved head's mirror back | §8.2 |
| D16 | Native wording for save failures | §8.4 |
| D17 | Permission string wording | §9 |
| D18 | Notification photo stored at 120 px | §4.6 |

### 13.1 DECISIONs made while building (the owner was asleep; each is also in `docs/briefs/m9/photoheads-report.md`)

| # | DECISION | Why |
| --- | --- | --- |
| B1 | A stored picture is judged by its bytes, whatever mime label the gateway gives it | §12.4.5; a wrong label must not hide a photo |
| B2 | A file must pass its own format's end mark (PNG `IEND`, JPEG `FF D9`, GIF trailer, WebP RIFF size, HEIC boxes) before ImageIO is trusted: `BotPicture.isWhole` | ImageIO reports a cut file as complete and draws half of it; the seeded `broken` picture and `corrupt.jpg` showed as photos without this |
| B3 | The fixture's `/__photoheads/*` controls are loopback with no sign-in, like `/__settings/*` (§10.1 said "same sign-in as the app's") | the settings fixture this one loads works that way, and the UI test runner holds no session |
| B4 | The run script's derived data is `${HQN_DD:-build/dd}` (not `build/dd-photoheads`) and its screenshots go to `build/shots` (not `.build/shots/photoheads`) | one build per worktree on a shared Mac; the builder's brief names `build/shots` |
| B5 | A bot whose row says `has_avatar: false` keeps no verdict and no file | nothing to remember; a later `true` is a new picture |
| B6 | An answer older than this phone's last own write for that bot is dropped (a write fence by issue time) | a slow `get_asset` must not put the old picture back after a save |
| B7 | This phone's own `profiles.configure` moves the remembered revision only when it is exactly the next one | a jump means another device wrote in between, and its picture must be read |
| B8 | Pull to refresh re-checks the pictures at the pull site (`BotsViewController`), Bot Info's check runs only for a bot with `has_avatar` | the two "look again" signals of §4.3 without a call per poll |
| B9 | At most three other accounts' photo folders are kept on the phone | a bound on disk for someone who signs in to many gateways |
| B10 | The picker's entry point is `BotPhotoPicker.pickAndFrame(from:source:completion:)` with a `PhotoLoad`, so Move and Scale opens at once and shows the loading state (§6.5 sketched `present(...)`) | the spinner state of §7 needs the framer before the file is read |
| B11 | `-HQDebugBotPhoto` takes a comma-separated list; each pick takes the next file | one launch can try every kind of file |
| B12 | `BotPictureChange.kindOnly`: when the picture landed but `profiles.configure` was refused, Try Again sends the kind alone; the alert is "Couldn’t Save Changes" | the picture must not be uploaded twice (§12.3.7) |
| B13 | A read-only gateway with a staged picture fails under "Couldn’t Save the Picture" with the read-only reason | the same words every other write uses there |
| B14 | After Reset Head with a photo still on the gateway the note is the photo note; staging or removing a photo clears the "Head saved" note | the note must describe the face that shows |
| B15 | The reply peek keeps its 20 pt circle for a head and uses the app-icon tile only for a photo | heads look as they did; §4.6 asks only that a photo is not a circle |
| B16 | The stage speaks its placement ("120 percent, moved 10 percent left") as its value | VoiceOver needs to know where the photo is; UI tests read the same value |
| B17 | `mirrorHead` records pictures (`adopt`, `has_avatar`) only on a gateway with the asset store | an older gateway answers "method not found" and must stay untouched |
| B18 | Pushed-alert faces are redrawn through `BotFaces.onFacesChanged` (300 ms, coalesced) | a photo that arrives after the roster must reach the notification extension too |
| B19 | The media script also writes `orient-1.jpg` … `orient-8.jpg` | §12.4.3 as a repeatable test |
| B20 | The fixture also has `POST /__photoheads/reply-delay {seconds}` and per-method call counts in its state | P21 needs a reply that lands while another chat is open; P3 needs to know the app reached the gateway again |
| B21 | §12.5.3 (turning the phone in the framer) is not testable: the app is portrait only (`UISupportedInterfaceOrientations`). The framer lays out from its stage size, so it follows any size the `ipad` stream gives it | nothing to rotate on iPhone |
| B22 | (Replaced by B32.) The UI test for §12.3.4 (S2) allowed 36 s on its own clock, not 31 s. The app's wait is the 30 s constant `BotPhotoTiming.uploadTimeout`; the unit test `aNewPhotoGoesUpFirstThenItsKindInOneConfigure` pins that the upload is sent with that timing | the runner's clock starts before the tap and counts its idle wait and its one-second polls: 33.3 s was measured once on the loaded Mac, under 33 s on another run |
| B23 | The fixture's state also reports `prompts` (messages the app sent) | P21's send tap can be swallowed by the keyboard's suggestion bar; the test taps again only when no message reached the gateway (as the chat and push suites do) |
| B24 | Move and Scale's Cancel and Choose are the system bar's own buttons; the UI tests ask 44 pt of width and at least 36 pt of height (iOS reports 38 pt for a bar button), and 44 pt for the slider's row | a custom, taller button would not be the system's Liquid Glass bar button |
| B25 | Leaving Edit Bot with a staged photo uses the page's existing discard question. iOS 26 anchors it to the X button and shows only **Discard Changes**; Keep Editing is a tap outside | the system's own shape for a question asked from a bar button; the same as every other unsaved change on that page |
| B26 | After review. A head's `faceKey` is a digest that is the same on every launch: `"head:" + BotPicture.fingerprint(` the head record as JSON with its keys in order `)`, and `"head:none"` when the bot has no record (`BotFaces.headKey`) | whoever keeps a face between launches (the Share sheet's roster, L590) compares this key with the one it stored; Swift's `Hasher` is seeded per launch, so every head would have been drawn and sent again on every launch |
| B27 | After review. Faces are told (`BotFaces.version`, `onFacesChanged`) when a photo has been decoded and can be drawn, not when its verdict arrives. `BotFaces.readyFace` answers nil for a bot whose photo cannot be drawn yet; the reply peek then shows the head, cut round | a notice that came before the picture let the pushed-alert face be saved as the head under the photo's key, and never saved again; the peek drew a head with square corners |
| B28 | After review. `PushFaceSaver`: a pushed-alert face that is a photo not already in memory is read and decoded off the main actor, one bot at a time, and is not kept in memory for that. It is saved only if the photo is still the same one and the account is still the signed-in one | the roster refresh at launch decoded every bot's photo on the main actor (a 200-bot gateway is 200 decodes in one run-loop turn) and filled the cache with pictures no list was showing |
| B29 | After review. Whether the gateway stores pictures (`BotPhotoStore.supportsAssets`) is kept in the account's `index.json` (`assets`), read when the store is made, and observable (`onSupportChange` moves `BotFaces.version`; `EditBotModel.supportsPictures` reads it) | Edit Bot opened between the socket coming up and the first roster showed Edit Head alone on a gateway this phone has known for weeks, and stayed that way until the page was reopened |
| B30 | After review. A kept photo that cannot be drawn (a damaged file) is forgotten and fetched again at most twice a run for one bot (`BotPhotoStore.discardLimit`); after that the bot wears its head until the socket reconnects, Bot Info opens or the list is pulled | a phone that cannot keep the file at all (no storage left) fetched the same picture for ever |
| B31 | After review. Every file a pick makes for itself is in `tmp/bot-photo-picks` (the Files browser's copy is moved there) and is owned by a `PickedFile` object that removes it when it is let go, however the pick ends. The folder is also cleared at the start of every pick and once at launch (off the main thread, only files older than the launch). Move and Scale taken down from outside ends the pick as Cancel | a pick the app was closed under left up to 32 MB in `tmp` until iOS cleared it, and a framer dismissed by something else left the pick open for ever |
| B32 | After review. `-HQDebugUploadTimeout <seconds>` (Debug builds only) shortens the upload's wait; the UI test for §12.3.4 (S2) runs with 5 and holds the alert to "not before 5 s, at most 9 s after the tap". This replaces B22's 36 s. The 30 s itself is pinned by the unit test `theUploadWaitIsThirtySeconds` | a 36 s limit on a 30 s wait proves little; a short wait can be held to a narrow window on a loaded Mac |
| B33 | After review. Move and Scale goes up when the Files browser's own closing has finished (its transition coordinator; a dismissal of our own when it has not started one) | a cover presented while another is still leaving is dropped by UIKit; seen working with the real browser in `testP11b_…` |
| B34 | After review. L819's alert half is checked with the alert the app posts itself for a reply that lands while it is away (`testP21b_…`), not with a pushed one. The sender's picture is asserted only in the original record's build (`HQ_IDENTITY=original`); in the other build the test asserts there is none | a simulator gets no push from a gateway and `simctl push` never runs the notification extension; only the original record's build has the Communication Notifications entitlement, so only there does iOS draw a sender's picture. The pushed alert reads the face file `PushFaceSaver` keeps, through the same `PushFaces.message`; that file is unit tested (`thePushedAlertFaceIsThePhotoThenTheHead`). Still not seen: a push through Apple on a real phone |
| B35 | After review. No UI test for "the Picture tabs are right before the first roster answer": Edit Bot's Edit button is off until the gateway is connected, so the page cannot be opened in that moment from a test | B29's fact is kept in `index.json` and read when the store is made (two unit tests), and `testS6_…` reads `assets: true` from the phone's file |

---

## 14. Owner to-do and other streams

- **Owner to-do: none.** Everything here uses gateway methods that already exist (`profiles.get_asset`,
  `profiles.set_asset`, `profiles.configure`); no relay, plugin or real-gateway change. No
  `docs/owner-todo/photoheads.md` is written.
- **Not seen by this run, to say plainly in the build notes:** a real phone, a real gateway, a real iCloud-only
  photo. The web's own note for this feature lists the same gaps (`MEM/photo-head-chat-bar-corners.md`: "Not seen:
  phone, iPad/Mac widths, VoiceOver, Generate/Pet results (they skip the framer), Save to a real gateway").
- **`share` stream (L590):** call `BotFaces.faceImage(…, side: 120, shape: .appIcon)` and `faceKey` (§4.6).
- **`groups` stream (L233):** reuse `BotPhotoPicker` and `PhotoFramerController`; draw group member faces through
  `HeadImage(raw:profile:…)` so members with photos show them.
- **`settings` stream:** owns `scripts/fixtures/settings-gateway.py`; this stream only loads it.
- **`ipad` / `a11y` streams:** the framer's layout rule (§7.1) and actions (§7.4) are theirs to check, not to
  rebuild.
- **Ship agents:** rows L228, L229, L819, L820, L1027 in `docs/parity-240.md`; this stream does not edit that file.

---

## 15. Risks

1. **No avatar version on the wire.** A picture changed by another device without any `ui_meta` revision moving
   (possible only for a client that calls `set_asset` alone) shows here after Bot Info is opened, a pull to refresh,
   or `has_avatar` flipping; not instantly.
2. **A failed mirror upload after a head save over a photo** leaves the photo on the gateway; this phone shows the
   head until the next refetch, then the photo again. Retried twice (§8.3); not alerted (the web calls the mirror
   "best effort").
3. **Sentinel sizes.** A real 288 × 288 or 160 × 160 PNG reads as "not a photo" (same on the web).
4. **The simulator's photo picker drops taps**; the real-picker test (P11) may need its one rerun.
5. **Shared files.** `HeadView.swift`, `EditBotController.swift`, `BotStore+Editing.swift`, `AppModel.swift` and the
   notification files are touched by other m9 streams; keep the diffs small and rebase on `m9/train` before handing
   over.
6. **WebP seed.** The fixture's WebP constant must be proven decodable before tests lean on it (§10.1).
7. **Notification sender pictures are circles** (the system's shape); a photo framed for the app-icon shape loses
   its corners there.
8. **Web and native phones on one gateway:** the web app still caches a picture forever, so a web phone can keep
   showing a photo this app replaced. Not fixable from native.

---

## 16. Build order

1. `PhotoFrame`, `BotPicture`, `PhotoFramerRenderer` with their unit tests (no UI).
2. `BotPhotoStore` + `BotFaces` + the `HeadView` / `HeadImage` photo branch; fixture and media script; P1–P5.
3. The Picture tabs in Edit Bot (Head tab, notes, Remove Picture); §8.2, §8.3; P6–P9, P17.
4. `BotPhotoPicker` and the debug hook; P10–P12.
5. `PhotoFramerController`; P13–P15.
6. Save (§8.1), failures; P16, P18–P20.
7. Notification face, reply peek, the Info.plist string; P21, P22.
8. Both identities build; `scripts/e2e-photoheads.sh` green twice in a row; hand the stress tester §12.
