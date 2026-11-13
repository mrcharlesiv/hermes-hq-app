# 3x — Share extension ("Hermes HQ" in other apps' share sheets)

Spec for the m9 stream `share` (branch `m9/share`, worktree `/Users/me/Projects/hermes-hq-native-wt/m9-share`).
It covers all 11 rows of `docs/parity-240.md` §13: the Share-sheet target, its sheet, the send it performs by itself,
the Keychain sign-in it borrows, the roster the app leaves for it in the App Group, the photo/video/file rules, the
prompt wording, the failures, Sign in with Nous accounts, bots without a Bot Chat, and the app opening that chat
afterwards. It is written from the web app at build 240, the Hermes contracts, the owner's memory notes and the native
code at `beee9f7`, and is meant to be built from without re-reading them.

**Citation roots** (every `file:line` is relative to one of these):

| Prefix | Path |
|---|---|
| `W:` | `/Users/me/Projects/hermes-hq-native-ref240` (web app, build 240, read-only) |
| `R8:` | `/Users/me/Projects/hermes-hq-native-ref238` (web app, build 238, read-only; the fixtures the native ones load) |
| `H:` | `/Users/me/.hermes/hermes-agent` (Hermes gateway source, READ ONLY, never run or imported) |
| `N:` | this repo (`m9/share` at `beee9f7`) |
| `M:` | `/Users/me/.claude/projects/-Users-me-Projects-hermes-ios/memory` (owner memory) |
| spec NN | `N:docs/spec/NN-*.md` |

Stream facts: builders use ports **9910–9914** and the simulator **"HQN-m9-share"**; the stress tester uses ports
**9915–9919** and **"HQN-m9-share-s"**. Nothing else on this Mac may be touched (hard rules in the stream brief).

---

## 0. TL;DR

1. Build 240's Share extension is **already native Swift** (`W:ios/App/ShareExtension/`, `W:ios/App/Shared/DispatchShareKit.swift`).
   This stream **ports it**, it does not redesign it: same sheet, same wording, same wire calls, same files on disk.
2. New target **`HermesHQShare`** (app-extension, bundle id `$(HQ_APP_BUNDLE_ID).share` = `com.charlesmcdowell.dispatch.share`
   in the shipped identity), embedded only in the original identity, compiled in both.
3. New folder **`ShareKit/`** compiled into the app **and** the extension: the App Group store, the roster model, the
   rules, the Keychain item's JSON editing, the sender and its small JSON-RPC socket. Foundation, Security, CryptoKit,
   ImageIO, AVFoundation, UniformTypeIdentifiers only. No UIKit, no HermesKit.
4. The **app** writes `roster.json` and 120 px faces into the App Group whenever its bots change (signed-in account
   only), clears them on sign-out and on a gateway switch, and opens the chat a share went to the next time it comes
   forward (`last-sent.json`, 5 minutes, same account).
5. The **extension** sends by itself on a throwaway `URLSession`: `GET /api/auth/me` → `GET /api/files` →
   `POST /api/files/upload-stream` per file → `POST /api/auth/ws-ticket` → `/api/ws` → `client.capabilities` →
   `session.resume` → `image.attach` / `file.attach` → `prompt.submit` with `queued: true`. The app is never launched.
6. It signs requests with the **app's own Keychain item** (service `ai.hermes.ios.gateway`, account `primary`): cookies
   for a password account, the bearer pair for a Sign in with Nous account. A renewed session is written back with a
   compare-and-swap, so an app that renewed or signed out meanwhile always wins.
7. Photos leave as 3072 px JPEGs with no metadata, videos are re-muxed without location or not sent, a file over
   32 MB disables Send and says why.
8. Failures are plain sentences, taken verbatim from build 240. "Try Again" appears only for failures worth retrying.
   Nothing is ever queued to send later.
9. No relay, plugin or real-gateway change is needed. The App Group, the `.share` App ID and its App Store profile
   already exist (§15).
10. New stand-in gateway `scripts/fixtures/share-gateway.py`, a test-only host app `HQShareProbe` that opens the system
    share sheet with known items, and `scripts/e2e-share.sh` (§10).

---

## 1. Decisions

Every choice the reference or the owner's notes did not settle is marked **DECISION** here and where it applies.

| # | DECISION | Why |
|---|---|---|
| DECISION D1 | **Port the reference Swift, keep its structure.** `ShareSender` talks to the gateway with its own ephemeral `URLSession` and its own tiny socket, never through the app's `GatewayClient`. | The extension is a different process with ~120 MB of memory; the app's client brings stores, reconnect loops and caches it must not start. The reference design shipped in builds 94–240. |
| DECISION D2 | **`ShareKit/` is self-contained and does not compile HermesKit.** Where HermesKit has the same rule (`GatewayAddress.accountKey`, `AttachmentStaging.safeName`, `MultipartBody`, `AttachmentSender.promptText`, `SavedCookie` JSON keys, `NousTokens.needsRenewal`, the tailnet rule), ShareKit carries its own copy and a **parity unit test** asserts both give the same answer (§11.1). | HermesKit files depend on each other (`PhotoNormalizer` → `AttachmentStaging` → `DraftAttachment` …) and on typed `GatewayFailure`; pulling them into the extension drags most of the kit in. Parity tests keep the two from drifting. |
| DECISION D3 | **The Share target ships only in the original identity** (`HQ_IDENTITY=original`, the Hermes HQ record). In the native identity it compiles for the unit tests and is not embedded; the app writes no roster there (`AppIdentity.current.appGroup == nil`). | Only the original record has the App Group and the `.share` App ID (`N:project.yml:44-46`, §15). Same pattern as `HermesHQNotifications` (`N:project.yml:77-93`, `N:project-original.yml:7-10`). |
| DECISION D4 | **Row L594 is out of date; Sign in with Nous accounts can share.** "Can’t Share Yet" is the title of every blocked state, not a Nous rule. | Build 214 fixed exactly this and it is in build 240 (`W:ios/App/Shared/DispatchShareKit.swift:441`, `:554-561`, `:604-629`); the owner reported the old behaviour as a bug (§9, `M:share-nous-accounts.md`). |
| DECISION D5 | **Attachment limit is 32 MiB**, written by the app into `roster.json` as `limitBytes` (`AttachmentStaging.maxItemBytes`, `N:HermesKit/Attachments/AttachmentStaging.swift:13`). The sheet uses the roster's number, 32 MiB when absent. | The native app has no "attachment limit" setting (the web's 1–32 MB, `W:ios/App/App/PickedFiles.swift:30`). A roster written by build 240 with a lower limit is honoured until the native app rewrites it. |
| DECISION D6 | **Roster key is `ios-direct::<profile>`** (spec 02 §1.1). A remembered choice matches by exact key, else by the profile after the last `::`. | The web's keys (`botRosterKey`) are `ios-direct::ivy` or `legacy::ivy`; matching by profile keeps "the last one used" across the update from build 240. |
| DECISION D7 | **Faces are the bot's head, drawn by the app** (`HeadImageCache`, 120 px, light, PNG), the same picture the push extension gets (`N:App/Notifications/AppModel+Notifications.swift:149-151`). One function, `ShareRosterWriter.face(for:)`, so the `photoheads` stream can return a chosen photo there later. | Native has no photo heads yet. Original robot heads only, no hats, no Character theme. |
| DECISION D8 | **Wording is build 240's, verbatim, with the literal name "Hermes HQ".** | The extension exists only in the Hermes HQ record. The word "Dispatch" appears in no string a person can see or hear. Amendment (UX study 2026-10-21 #149): a gateway error no longer shows its HTTP status, which means nothing to most people; it reads "Your gateway had a problem with this share. Try again in a minute." |
| DECISION D9 | **Every shared image becomes a JPEG** (`<stem>.jpg`), transparent pixels flattened onto white (`kCGImageDestinationBackgroundColor`), an animated GIF becomes its first frame. | The row and the reference say JPEG (`W:ios/App/ShareExtension/ShareItems.swift:126-144`). White instead of ImageIO's black for transparency is the one change; the composer's PNG/GIF rules are not copied here. |
| DECISION D10 | **Storage names stay as build 240 wrote them**: App Group folder `Library/Application Support/Dispatch Share/`, gateway staging folder `.dispatch-attachments`, temporary folders `dispatch-share-<UUID>`. | They are storage keys nobody sees; the same names mean a roster, choice or last-sent note written by build 240 is read by the native build after the update. |
| DECISION D11 | **JSON-RPC ids are `hq-share-<n>`** (strings). | Opaque to Hermes; the reference used `dispatch-share-<n>` (`W:…/DispatchShareKit.swift:811`). |
| DECISION D12 | **A Nous pair is renewed by the app's own rule** (`NousTokens.needsRenewal`, `N:HermesKit/Net/SavedAccounts.swift:64-69`) and a rotated pair is written with `obtainedAt` = now. Pairs are compared by access token, refresh token and user id (`samePair`). | One rule on the phone; the app's D6 margin needs `obtainedAt`. |
| DECISION D13 | **UI tests drive a test-only host app, `HQShareProbe`**, which presents the real system share sheet with items a test names; tests read and write the App Group folder through its simulator path. Three opt-in tests still go through Safari, Photos and Files. | Driving Apple's apps is slow and flaky on a shared Mac; the probe gives the same `NSItemProvider` hand-off deterministically, with the app in the background as in real use. |
| DECISION D14 | **DEBUG builds only:** a file `debug.json` in the App Group folder can force a blocked state or a failure row, for screenshots of states the simulator cannot reach (needs-update, Keychain locked/unreadable, Tailscale off). Compiled out of Release. | Wording and layout of those states still need to be looked at; their logic is unit-tested. |
| DECISION D15 | **While sending, the sheet cannot be swiped away** (`isModalInPresentation = true` on `ShareViewController`, plus `.interactiveDismissDisabled`); a sheet that goes away any other way cancels cleanly (`viewDidDisappear` → `model.abandon()`). The send runs inside `ProcessInfo.performExpiringActivity` so a share in flight survives the person leaving the host app for a few seconds. | The reference only had the SwiftUI modifier; a remote sheet honours the UIKit flag. |
| DECISION D16 | **VoiceOver hears failures too** (`UIAccessibility.post(.announcement, failure.message)`), not only "Sent to <name>". | The failure row appears below the fold; a VoiceOver user would otherwise hear nothing. |
| DECISION D17 | **The extension never asks the gateway who the bots are, never creates a Bot Chat, never signs in, never stores a share to send later.** | As the reference (`W:docs/share-extension.md:85-91`); a failed share stays on screen for Try Again or is dropped. |
| DECISION D18 | **No row is web-shell-only.** All 11 are real native behaviour. | — |
| DECISION D19 | **Nothing goes to the owner for relay/plugin/gateway changes.** `docs/owner-todo/share.md` lists only what a real iPhone must confirm. | The portal work was done for build 94 (§15). |

---

## 2. Rows and where they are specified

| Row | Parity line | What | Section |
|---|---|---|---|
| R1 | L586 | Share-sheet target for text, one link, ≤10 photos, ≤10 videos, ≤10 files | §7.1 |
| R2 | L587 | The sheet: what is shared, message, bots, Send | §7.2 |
| R3 | L588 | Sends by itself, no app launch; approvals left for the app | §7.3 |
| R4 | L589 | Keychain sign-in, compare-and-swap write-back | §7.4 |
| R5 | L590 | Roster and faces in the App Group, cleared on sign-out/switch | §7.5 |
| R6 | L591 | Photo, video and file rules | §7.6 |
| R7 | L592 | Prompt text | §7.7 |
| R8 | L593 | Plain-words failures, Try Again, never sent later | §7.8 |
| R9 | L594 | Sign in with Nous accounts | §7.9 |
| R10 | L595 | Bot without a Bot Chat | §7.10 |
| R11 | L596 | App opens that chat afterwards | §7.11 |

`N:docs/briefs/m9/share-rows.md` holds the rows verbatim with their outcomes.

---

## 3. How build 240 does it

* **Target.** `W:ios/App/ShareExtension/Info.plist:33-57`: extension point `com.apple.share-services`, principal class
  `ShareViewController`, activation rule text + 1 web URL + 10 images + 10 movies + 10 files. Display name "Hermes HQ"
  (`:7-8`). ATS open as the app's (`:26-30`), local-network sentence (`:31-32`).
* **Sheet.** `ShareViewController` hosts a SwiftUI `ShareView` (`W:ios/App/ShareExtension/ShareViewController.swift:6-28`).
  `ShareView.swift:10-32` is a `NavigationStack` with an inline title, Cancel, Send; `:37-62` either a
  `ContentUnavailableView` "Can’t Share Yet" or an inset-grouped list (items, message field, "Send to" bots, failure).
  `ShareModel.swift:5-132` holds the phase (`loading`, `ready`, `sending(step)`, `sent(name)`, `blocked(failure)`).
* **Items.** `ShareItems.swift:41-209` reads the item providers one at a time: image → 3072 px JPEG + 160 px
  thumbnail, movie → copy then location removal, http(s) URL → link, file → copy (measured, not copied, when over the
  limit), plain text → text (a lone URL becomes a link).
* **Send.** `DispatchShareKit.swift:447-522`, on an ephemeral session (`:413-424`) that follows no redirect (`:690-693`).
* **Sign-in.** The app's Keychain item, read through `keychain-access-groups`
  (`W:ios/App/ShareExtension/ShareExtension.entitlements`, `DispatchShareKit.swift:193-212`), edited as JSON so unknown
  fields survive (`:254-328`).
* **Roster.** The web page hands native its bots (`W:src/share-roster.ts:45-70`, debounced 800 ms `:74-113`); native
  writes `roster.json` and faces (`W:ios/App/App/DispatchShare.swift:19-43`); cleared on sign-out
  (`W:ios/App/App/HermesNative.swift:2215`) and on a gateway switch (`:2260`).
* **Afterwards.** `last-sent.json` is taken once when the scene becomes active
  (`W:ios/App/App/HermesViewController.swift:685-689`, `DispatchShare.swift:59-66`, `DispatchShareKit.swift:122-127`).

---

## 4. Native layout

### 4.1 Files

```
ShareKit/                       NEW · app + Share extension · every declaration `nonisolated`
  ShareIdentity.swift           App Group id, Keychain service, read from Info.plist (HQAppGroup, HQKeychainService)
  ShareModels.swift             ShareBot, ShareRoster, ShareSent
  ShareStore.swift              the App Group folder: roster.json, avatars/, last-sent.json, choice.json
  ShareRules.swift              ids, caps, promptText, fits, megabytes, accountKey, safeName, staging names
  ShareKeychain.swift           ShareKeychainStore, SystemShareKeychain, ShareAccount, ShareNous, ShareAccounts
  ShareFailure.swift            the failures, their sentences, retryable / blocking
  ShareReach.swift              the tailnet rule (interfaces), transport failure sentences
  ShareMultipart.swift          the upload body, streamed to a temporary file
  ShareMedia.swift              photo → JPEG, thumbnail, video location removal
  ShareItems.swift              SharedItem, ShareItemLoader (NSItemProvider reading; thumbnails as CGImage)
  ShareSheetState.swift         pure sheet logic: bot order, selection, canSend, step labels
  ShareSender.swift             one share, start to finish
  ShareSocket.swift             JSON-RPC over URLSessionWebSocketTask for a handful of calls
ShareExtension/                 NEW · the HermesHQShare target only
  Info.plist  ShareExtension.entitlements  PrivacyInfo.xcprivacy
  ShareViewController.swift     @objc(ShareViewController), hosts ShareView
  ShareView.swift               the SwiftUI sheet
  ShareModel.swift              @MainActor @Observable; owns the tasks, calls ShareSender
App/Share/                      NEW · app only
  ShareRosterRows.swift         pure: [Bot] → [ShareBot] drafts
  ShareRosterWriter.swift       debounce, faces, write-when-changed, clear
  AppModel+Share.swift          the three hooks (§4.4)
TestSupport/ShareProbe/         NEW · test-only host app (§10.3)
Tests/Share/                    NEW · unit and fixture tests (§11.1, §11.2)
UITests/share/                  NEW · ShareEndToEndTests.swift (§11.3)
scripts/fixtures/share-gateway.py, scripts/fixtures/make-share-media.swift, scripts/e2e-share.sh,
scripts/check-share-target.sh   NEW (§10)
```

Type names must not collide with the app's (ShareKit is compiled into it): the socket is `ShareSocket`, never
`RPCSocket`; the multipart builder is `ShareMultipart`.

**Concurrency.** The project default is `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. Every ShareKit declaration is
written `nonisolated` (as `N:Shared/BotMutes.swift` does), so it means the same in both targets. `ShareSender` and
`ShareSocket` are `final class … @unchecked Sendable` guarded by a lock, as the reference. The extension target keeps
the project default (its own three files are UI).

### 4.2 `project.yml`

Add `ShareKit` to the app's sources, the target, the probe, and the scheme entries:

```yaml
targets:
  HermesHQNative:
    sources: [App, HermesKit, Shared, ShareKit]
  # "Hermes HQ" in other apps' share sheets (docs/spec/3x-share.md). Embedded only in the original identity
  # (project-original.yml): only that record has the App Group and the .share App ID. Built for the tests in both.
  HermesHQShare:
    type: app-extension
    platform: iOS
    sources: [ShareExtension, ShareKit]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: $(HQ_APP_BUNDLE_ID).share
        PRODUCT_NAME: HermesHQShare
        INFOPLIST_FILE: ShareExtension/Info.plist
        GENERATE_INFOPLIST_FILE: NO
        CODE_SIGN_ENTITLEMENTS: ShareExtension/ShareExtension.entitlements
        TARGETED_DEVICE_FAMILY: "1"
        APPLICATION_EXTENSION_API_ONLY: YES
        SKIP_INSTALL: YES
  # Test-only host for the Share UI tests: presents the system share sheet. Never embedded, never archived.
  HQShareProbe:
    type: application
    platform: iOS
    sources: [TestSupport/ShareProbe]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.charlesmcdowell.hqshareprobe
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_KEY_UILaunchScreen_Generation: YES
        INFOPLIST_KEY_CFBundleDisplayName: Share Probe
        TARGETED_DEVICE_FAMILY: "1"
        SKIP_INSTALL: YES
schemes:
  HermesHQNative:
    build:
      targets: {HermesHQNative: all, HermesHQNotifications: [test], HermesHQShare: [test], HermesHQNativeTests: [test]}
  HermesHQNativeUI:
    build:
      targets: {HermesHQNative: all, HermesHQShare: [test], HQShareProbe: [test], HermesHQNativeUITests: [test]}
```

`project-original.yml`: add `- target: HermesHQShare` under the app's dependencies and replace the comment "there is
no Share target yet" with one line saying the Share extension is embedded here.

**Both identities must keep building**: `scripts/build.sh build <UDID>` and `HQ_IDENTITY=original scripts/build.sh
build <UDID>`, and both `test` runs.

### 4.3 The extension's plist, entitlements, privacy manifest

`ShareExtension/Info.plist` is `W:ios/App/ShareExtension/Info.plist` with these values:

| Key | Value |
|---|---|
| `CFBundleDisplayName` | `$(HQ_DISPLAY_NAME)` ("Hermes HQ" in the shipped identity) |
| `CFBundleShortVersionString` / `CFBundleVersion` | `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)` (the App Store requires them to equal the app's) |
| `NSAppTransportSecurity` | `NSAllowsArbitraryLoads = true` (as `N:App/Info.plist:35`; the address already passed the app's own check) |
| `NSLocalNetworkUsageDescription` | `$(HQ_DISPLAY_NAME) connects to the Hermes gateway on your local network or Tailscale.` (as `N:App/Info.plist:38`) |
| `HQKeychainService` | `$(HQ_KEYCHAIN_SERVICE)` |
| `HQAppGroup` | `$(HQ_APP_GROUP)` |
| `NSExtension.NSExtensionPointIdentifier` | `com.apple.share-services` |
| `NSExtension.NSExtensionPrincipalClass` | `ShareViewController` |
| `NSExtensionActivationRule` | dictionary: `NSExtensionActivationSupportsText = true`, `…SupportsWebURLWithMaxCount = 1`, `…SupportsImageWithMaxCount = 10`, `…SupportsMovieWithMaxCount = 10`, `…SupportsFileWithMaxCount = 10` |

`ShareExtension/ShareExtension.entitlements`:

```xml
<key>com.apple.security.application-groups</key>
<array><string>group.com.charlesmcdowell.dispatch</string></array>
<key>keychain-access-groups</key>
<array><string>$(AppIdentifierPrefix)$(HQ_APP_BUNDLE_ID)</string></array>
```

The app's own entitlements do not change (`N:App/Identity/HermesHQ-original.entitlements` already lists the group and
keeps the default Keychain group), so an update cannot sign anyone out.

`ShareExtension/PrivacyInfo.xcprivacy`: no tracking, nothing collected, one accessed-API entry
`NSPrivacyAccessedAPICategoryFileTimestamp` reason `C617.1` (the stale-copy sweep reads modification dates). No
UserDefaults entry: ShareKit reads none (the reference's came from `PickedFiles`).

`scripts/ship.py`: add the third profile to the original identity's map. Builders edit the line and **never run an
export or upload**:

```python
profiles = {'com.charlesmcdowell.dispatch': profile_uuid(SIGNING / 'Dispatch.mobileprovision'),
            'com.charlesmcdowell.dispatch.notifications': profile_uuid(SIGNING / 'DispatchNotifications.mobileprovision'),
            'com.charlesmcdowell.dispatch.share': profile_uuid(SIGNING / 'DispatchShare.mobileprovision')}
```

`scripts/check-share-target.sh <path to HermesHQNative.app>` (new, read-only) prints and checks, for an original-identity
build: `PlugIns/HermesHQShare.appex` exists; its bundle id is `com.charlesmcdowell.dispatch.share`; its two version
strings equal the app's; its activation rule has exactly the five keys above; its signed entitlements name the group
and one Keychain group ending `.com.charlesmcdowell.dispatch`; and (Release builds) the binary holds no `debug.json`
string. Exit 1 on any mismatch.

### 4.4 App hooks (`App/Share/AppModel+Share.swift`)

| Hook | Called from | Does |
|---|---|---|
| `shareRosterChanged()` | `AppModel.botsChanged()` (`N:App/AppModel.swift:396-403`), one line marked `// [share]` | `ShareRosterWriter.shared.schedule(bots:account:)` (debounced 0.8 s) |
| `shareLeaving()` | `finishSignOut()` (`:192-217`), `activateSwitched(_:)` (`:311-314`) before `activate`, the forget-current-gateway path in `N:App/Settings/AppModel+Settings.swift`, and launch with nobody signed in | `ShareRosterWriter.shared.clear()` |
| `shareActivated(_:)` | end of `activate(_:)` (`:221-…`) | clears a roster that belongs to another account, then `openSharedChatIfAny()` |
| `openSharedChatIfAny()` | `appDidBecomeActive()` (`:359-372`) and `shareActivated` | §7.11 |

All four are no-ops when `ShareStore()` is nil (no App Group: the native identity, or a build without the
entitlement).

---

## 5. What lives where

### 5.1 The App Group folder

`<container of group.com.charlesmcdowell.dispatch>/Library/Application Support/Dispatch Share/` (D10). Every file is
written atomically with `.completeFileProtectionUntilFirstUserAuthentication`.

**`roster.json`** (written by the app only):

```json
{"version":1,"account":"http://127.0.0.1:9910\nshare-fixture","url":"http://127.0.0.1:9910","username":"share-fixture",
 "limitBytes":33554432,"savedAt":1791763200.5,
 "bots":[{"key":"ios-direct::default","name":"Hermes","profile":"default","session":"20260929_120000_aabbcc01",
          "color":"","avatar":"3f1c9a0b7d2e4f6a8b1c2d3e4f5a6b7c.png","lastActive":1790686800},
         {"key":"ios-direct::ivy","name":"Ivy","profile":"ivy","session":"","color":"","avatar":"…png"}]}
```

* `account` = `StoredAccount.key` = `ShareRules.accountKey(url:username:)`: the address with scheme and host
  lowercased and no trailing slash, a newline, the username (for a Nous account the stored username, `nous:<id>`).
* `gateway` (optional) = the gateway's name as Settings › Gateways shows it, written only while more than one gateway is
  saved; the sheet's header then reads "Send to · <name>". A roster without it (older builds) reads as before.
* `session` = the Bot Chat's stored id (the lineage tip, `Bot.canonicalSessionId`), or `""` when the bot has none.
* `avatar` = a file in `avatars/`, named `hex(first 16 bytes of SHA-256(account + "\n" + profile + "\n" + imageKey)) + ".png"`.
* At most 200 bots; `name` at most 80 characters; `color` `""` or `#rrggbb` lowercase.

**`avatars/<32 hex>.png`**: 120×120 px PNG faces. Files no bot names are removed on every save.

**`last-sent.json`** (written by the extension, taken once by the app):

```json
{"id":"7C0F…","account":"http://127.0.0.1:9910\nshare-fixture","session":"20260929_120000_aabbcc02","profile":"ivy",
 "botName":"Ivy","at":1791763260.1}
```

**`choice.json`** (written by the extension): `{"<account key>": "ios-direct::ivy"}`, one entry.

**`debug.json`** (DEBUG builds only, D14): `{"blocked":"needsApp"}` or `{"failure":"tailscaleOff"}`; names are the
`ShareFailure` cases without payload.

Validation on read (`ShareRules`): session `^[A-Za-z0-9_-]+$` ≤ 160; profile `^[A-Za-z0-9_.-]+$` ≤ 128; avatar name
`^[a-f0-9]{16,64}\.(png|jpg)$`. A file that does not decode reads as absent (never a crash).

### 5.2 The Keychain item

Generic password, service `ai.hermes.ios.gateway`, account `primary`, the app's default access group,
`WhenUnlockedThisDeviceOnly` (`N:HermesKit/Net/Keychain.swift:1-33`, `:215`). JSON (`N:HermesKit/Net/SavedAccounts.swift`, spec 01 §4):

```json
{"current":"http://127.0.0.1:9910\nshare-fixture",
 "accounts":[{"url":"http://127.0.0.1:9910","username":"share-fixture","provider":"fake","label":"127.0.0.1",
              "cookies":[{"name":"hermes_session_at","value":"…","domain":"127.0.0.1","path":"/","expires":1791806400,
                          "secure":false,"httpOnly":true,"sameSite":"lax"},
                         {"name":"hermes_session_rt","value":"…","domain":"127.0.0.1","path":"/","httpOnly":true}]},
             {"url":"https://hq.example","username":"nous:user_1","provider":"nous",
              "nous":{"accessToken":"…","refreshToken":"…","expiresAt":1791766800,"userId":"user_1","obtainedAt":1791763200}}]}
```

The extension reads it without naming an access group, **only ever `SecItemUpdate`s that one item's value**, never
adds an item, never deletes one, and edits the JSON as a dictionary so every field it does not know survives
(`W:…/DispatchShareKit.swift:184-212`, `:254-304`). It never reads or sends a password (a build-89 single-account item
that still holds one reads as "needs update", `:440`).

---

## 6. Wire calls (exact)

Hermes rejects any unknown param key with `4000` (`H:tui_gateway/contracts/base.py:16,35`). Every key below was
checked against the contracts: `SessionParams` (`common.py:224`: `session_id`, `profile`), `PromptSubmitParams`
(`prompt_voice.py:26-35`: `text`, `queued`), `ImageAttachParams` (`:113`: `path`), `FileAttachParams` (`:165`: `path`,
`name`, `data_url`), `SessionResumeParams` (`sessions.py:183`: `source`, `omit_messages`, …),
`ClientCapabilitiesParams` (`liveness.py:29`: `server_requests`). **Send exactly these keys and no others.**

### 6.1 Rules for every request

* One `URLSessionConfiguration.ephemeral` session per share: `timeoutIntervalForRequest = 30`,
  `timeoutIntervalForResource = 900`, `urlCache = nil`, cookies accepted and set. Invalidated when the share ends.
* **No redirect is followed** (the delegate answers `nil`): cookies never reach another host.
* Every URL is the Keychain account's `url` + a path; the host and port must equal the account's and the URL must
  carry no user or password, else the share stops as "signed out".
* **Tailnet rule before every request**: a plain-`http` gateway at a `100.64.0.0/10` or `fd7a:115c:a1e0::/48` address
  or a `*.ts.net` name is contacted only while a `utun*` interface holds a tailnet address; otherwise nothing is sent
  (`W:ios/App/Shared/HermesTransportShared.swift:166-183`, the same rule as `N:HermesKit/Net/GatewayAddress.swift:124-140`).
* Password account: the saved cookies are installed in the session's jar. Nous account: every HTTP request carries
  `Authorization: Bearer <accessToken>` and `httpShouldHandleCookies = false`; the WebSocket upgrade carries only the
  ticket (spec 01 §6.2, §10).
* Nothing is logged that holds a cookie, a token, a ticket or shared content.

### 6.2 The sequence

| # | Call | Timeout | Needs | On failure |
|---|---|---|---|---|
| 0 | Local checks: bot can receive; ≤ 10 photos and ≤ 10 files; something to send; each file > 0 bytes and ≤ limit; Keychain account matches the roster; tailnet rule | — | — | `noChat` · `refused("Share at most 10 photos and 10 files at a time.")` · `nothingToSend` · `unreadable(name)` · `tooLarge(name)` · the blocked failures of §7.8 · `tailscaleOff` |
| 0n | Nous only, when the pair needs renewal: `POST /auth/native/refresh` (§7.9) | 15 s | 200 + rotated pair | `sessionEnded` for 200/400/401/403 without a usable pair, else `gateway(status)` |
| | **[kept-session]** In every row here a 400/401/403 counts as a refusal only when Hermes wrote it (`GatewayRefusal.isHermes`, spec 01 §14); otherwise it is `gateway(status)` and nothing is renewed against it. | | | |
| 1 | `GET /api/auth/me` | 15 s | 2xx | 401/403: one retry (cookies: with the Keychain's copy if it differs; Nous: after one forced renewal), then `sessionEnded`. Other status → `gateway(status)` |
| 2 | `GET /api/files?profile=<p>` (only with attachments) | 30 s | `path` non-empty | `refused("Your gateway has no folder for uploads.")` |
| 3 | per attachment: `POST /api/files/upload-stream?profile=<p>` | 120 s | 2xx + `path` | 401/403 `sessionEnded` · 413 `tooLarge(name)` · other `gateway(status)` · no `path` → `refused("Your gateway didn’t store “<name>”.")` |
| 4 | `POST /api/auth/ws-ticket`, body `{}` | 30 s | `ticket` | `refused("Your gateway didn’t open a connection.")` |
| 5 | `GET ws(s)://…/api/ws?ticket=<t>`; wait ≤ 5 s for the `gateway.ready` event, then carry on regardless | 5 s | open socket | transport failure |
| 6 | `client.capabilities`, sent without waiting for its answer (`session.resume` follows on the same socket at once, in order) | — | — | **ignored** (older gateways) |
| 7 | `session.resume` | 60 s | `result.session_id` (the runtime id) | RPC error → §7.8 RPC wording · empty → `refused("Your gateway couldn’t open this bot’s chat.")` |
| 8 | per photo: `image.attach` | 60 s | `attached == true` | `refused(result.message ?? "Your gateway didn’t accept “<name>”.")` |
| 9 | per file: `file.attach` | 60 s | `attached != false` and `ref_text` non-empty | same as 8 |
| 9d | after a file whose copy the gateway kept elsewhere (`uploaded == true` and `path` outside the staging folder): `DELETE /api/files?profile=<p>` | 30 s | — | **ignored** |
| 10 | `prompt.submit` with `queued: true` | 60 s | any result | timeout or a dropped socket → **`unconfirmed`** (never retried by itself) |
| 11 | Write a renewed cookie session back (§7.4), record `last-sent.json`, remember the choice | — | — | — |

The socket is closed after step 10. Cancel is checked before every step; a step in flight ends with its task
(`ShareFailure.cancelled`, shown to nobody: the sheet is closing).

**A share that fails after an upload removes what it uploaded** (m9 review). When any of steps 3 to 9 fails, each
folder a finished upload left on the gateway (`<root>/.dispatch-attachments/<UUID>`) is removed with the same call as
9d (`DELETE /api/files?profile=<p>`, `{"path": …, "recursive": true}`, 5 s each) before the failure is shown, so Try
Again does not leave a second copy beside the first. Best effort: a refusal (404: already gone) is skipped, and the
first call that gets no answer ends the clean-up. Never after `prompt.submit` was written (the bot may be reading the
file: `unconfirmed` and a refused prompt keep their uploads), never for a folder 9d already removed, and never after
Cancel, Tailscale off, a session that ended or a sign-out (nothing more is sent then).

**A cancelled request is the person's Cancel only when this share's task was cancelled.** The system reports its own
cancellations with the same code (`NSURLErrorCancelled`, -999: the network changed, the socket was torn down). Those
are transport failures (“The connection changed before your gateway answered. Try again.”, with Try Again), and
during step 10 they are `unconfirmed` like any other dropped answer. `ShareSocket.close()` fails its waiters with
`cancelled` itself before the system can.

### 6.3 Payloads

`GET /api/auth/me` → `200 {"username":"share-fixture"}` (a Nous session answers `user_id`, `provider`, `expires_at`).

`GET /api/files?profile=ivy` → `200 {"path":"/fixture/uploads","parent":"/fixture","entries":[],…}`.

`POST /api/files/upload-stream?profile=ivy`, `Content-Type: multipart/form-data; boundary=hermes-<UUID>`, body streamed
from a temporary file (never held in memory):

```
--hermes-<UUID>\r\n
Content-Disposition: form-data; name="path"\r\n\r\n
/fixture/uploads/.dispatch-attachments/<UUID>/photo-gps.jpg\r\n
--hermes-<UUID>\r\n
Content-Disposition: form-data; name="overwrite"\r\n\r\n
false\r\n
--hermes-<UUID>\r\n
Content-Disposition: form-data; name="file"; filename="photo-gps.jpg"\r\n
Content-Type: application/octet-stream\r\n\r\n
<bytes>\r\n
--hermes-<UUID>--\r\n
```

→ `200 {"path":"/fixture/uploads/.dispatch-attachments/<UUID>/photo-gps.jpg", …}`. Each attachment gets its own
`<root>/.dispatch-attachments/<new UUID>/` folder.

`POST /api/auth/ws-ticket` body `{}` → `200 {"ticket":"…","ttl_seconds":30}` (single use, spec 01 §9).

Socket frames (each a text frame):

```json
→ {"jsonrpc":"2.0","id":"hq-share-1","method":"client.capabilities","params":{"server_requests":true}}
← {"jsonrpc":"2.0","id":"hq-share-1","result":{"server_requests":["approval.request","clarify.request"],"declines_not_shown":true}}
→ {"jsonrpc":"2.0","id":"hq-share-2","method":"session.resume",
   "params":{"session_id":"20260929_120000_aabbcc02","source":"desktop","omit_messages":true,"profile":"ivy"}}
← {"jsonrpc":"2.0","id":"hq-share-2","result":{"session_id":"bf611b3e","resumed":"20260929_120000_aabbcc02","messages":[],"messages_omitted":true,…}}
→ {"jsonrpc":"2.0","id":"hq-share-3","method":"image.attach",
   "params":{"session_id":"bf611b3e","path":"/fixture/uploads/.dispatch-attachments/<UUID>/photo-gps.jpg","profile":"ivy"}}
← {"jsonrpc":"2.0","id":"hq-share-3","result":{"attached":true,"path":"…","count":1,"name":"photo-gps.jpg"}}
→ {"jsonrpc":"2.0","id":"hq-share-4","method":"file.attach",
   "params":{"session_id":"bf611b3e","path":"/fixture/uploads/.dispatch-attachments/<UUID>/note.txt","name":"note.txt","profile":"ivy"}}
← {"jsonrpc":"2.0","id":"hq-share-4","result":{"attached":true,"name":"note.txt","path":"/fixture-home/attachments/note.txt",
   "ref_path":"/fixture-home/attachments/note.txt","ref_text":"@file:/fixture-home/attachments/note.txt","uploaded":true}}
→ DELETE /api/files?profile=ivy   {"path":"/fixture/uploads/.dispatch-attachments/<UUID>","recursive":true}
→ {"jsonrpc":"2.0","id":"hq-share-5","method":"prompt.submit",
   "params":{"session_id":"bf611b3e","text":"@file:/fixture-home/attachments/note.txt\n\nFrom Files","profile":"ivy","queued":true}}
← {"jsonrpc":"2.0","id":"hq-share-5","result":{"status":"streaming","user_row_id":3002}}
```

`session.resume` takes the **stored** id from the roster; everything after it uses the **runtime** id it answers.
`queued: true` means a bot in the middle of a turn holds the share for its next turn and is never redirected by it
(`H:tui_gateway/contracts/prompt_voice.py:35`, spec 04 §"queued"). Any result status (`streaming`, `queued`, `steered`,
`redirected`) counts as sent.

Frames the socket receives and does not answer: every `event`, and every **server request** (a frame with both
`method` and `id`, such as `approval.request`). They are read and dropped; Hermes re-delivers an open request to the
app when it resumes the chat (`W:…/DispatchShareKit.swift:696-697`, `:756`).

`POST /auth/native/refresh` (Nous): body `{"refresh_token":"<spent>","provider":"nous"}`, no bearer, no cookies →
`200 {"access_token":"…","refresh_token":"…","token_type":"Bearer","expires_at":1791766800,"provider":"nous","user_id":"user_1"}`.

---

## 7. The rows

Each row: what build 240 does, the native design, the wire calls, the states and words, what the owner approved,
the stand-in gateway and its exact start command, and the checks that make it "done". Fixture commands F1–F4 are
defined once in §10.2 and repeated here by name and port.

### 7.1 R1 · L586 — Share-sheet target "Hermes HQ"

**Web.** `W:ios/App/ShareExtension/Info.plist:39-56`: the activation rule offers the extension for text, one web URL,
up to 10 images, 10 movies, 10 files. `:7-8` names it "Hermes HQ".

**Native.** The `HermesHQShare` target of §4.2–4.3, with the same rule. iOS itself hides the target when a share has
more items of a kind than the rule allows (11 photos); the sheet's own caps (§7.6) are the second line of defence for
shares the rule lets through with mixed types.

**Wire.** None.

**UI.** In another app's share sheet, an app icon labelled **Hermes HQ** (the app's icon). Nothing else.

**Owner.** `M:optimization-batch-oct2.md`: "Apple portal: App Group group.com.charlesmcdowell.dispatch registered and
on both App IDs (com.charlesmcdowell.dispatch, .dispatch.share)". `M:hermes-hq-native.md`: never "Dispatch" in
anything user-facing.

**Fixture.** F1 on 9910 (`python3 scripts/fixtures/share-gateway.py --port 9910 --credentials build/fixtures/share.json
--files build/fixtures/share-files --log build/fixtures/share.jsonl`); the target itself needs none.

**Acceptance.**
1. `scripts/check-share-target.sh` passes on an original-identity simulator build.
2. Both identities build and their unit tests compile the extension.
3. On "HQN-m9-share", from `HQShareProbe`: a text share, a link share, a 1-photo share, a 10-photo share, a video
   share and a file share each show **Hermes HQ** in the system share sheet (screenshot looked at).
4. An 11-photo share does not offer Hermes HQ.
5. The label reads "Hermes HQ"; no string in the built `.appex` shown to a person contains "Dispatch"
   (`strings` over `Info.plist` values and the sheet's text, checked by a unit test over `ShareFailure` and the view's
   string table).

### 7.2 R2 · L587 — The sheet

**Web.** `W:ios/App/ShareExtension/ShareView.swift:10-222`, `ShareModel.swift:30-77`: inline title "Hermes HQ", Cancel,
Send; what is shared; "Add a message"; "Send to" with bots most recently active first (`ShareModel.swift:53-58`), the
remembered one chosen, else the first that can receive (`:39-42`).

**Native.** `ShareView` (SwiftUI `NavigationStack` + `List(.insetGrouped)`, system bars) over `ShareModel`, whose
decisions live in `ShareSheetState` (pure, unit-tested):

```swift
nonisolated enum ShareSheetState {
    static func ordered(_ bots: [ShareBot]) -> [ShareBot]            // lastActive desc; ties and nil keep roster order
    static func selection(bots: [ShareBot], remembered: String?) -> String?   // D6
    static func canSend(ready: Bool, selected: ShareBot?, hasContent: Bool, oversized: Int) -> Bool
    static func label(_ step: ShareStep) -> String
    static func subtitle(_ bot: ShareBot, now: Date) -> String
}
```

Layout rules (owner's): system list and bars; the only custom surface is the progress card, real Liquid Glass
(`.glassEffect(.regular, in: .rect(cornerRadius: 24))`), never blur plus tint. Item rows have 12 pt vertical padding,
bot rows 13 pt; text wraps instead of truncating at large type sizes, except file names (middle truncation, 1 line) and
link hosts (1 line). Faces are 36 pt rounded squares (corner radius 22.37 %), drawn from the roster's PNG, with the
initial on the tint colour when a picture is missing. Each face is decoded once per sheet.

**Wire.** None until Send (§6).

**UI states and words.** Full table in §8. The parts specific to this row:

| Element | Words / behaviour | Identifier |
|---|---|---|
| Title | **Hermes HQ** (inline) | — |
| Leading button | **Cancel** (always enabled, also while sending) | `share.cancel` |
| Trailing button | **Send** (semibold); hidden when blocked; disabled unless: items finished loading, the chosen bot can receive, there is a message or at least one item, nothing is oversized | `share.send` |
| While items load | spinner + **Preparing…** | — |
| Photos | a row of 64 pt thumbnails (corner 10), below it **Sent without location or camera details** with `location.slash` | `share.photo-privacy` |
| Link | `link` glyph, host on the first line, the full address under it (2 lines) | — |
| Text | `text.quote` glyph, the text (4 lines at default size) | — |
| File / video | `doc` glyph, name, size (`ByteCountFormatter`, file style) | — |
| Message | placeholder **Add a message**, or, when only photos are shared, the question they are sent with (**What do you see in this image?**, greyed), 1–6 lines | `share.message` |
| Section header | **Send to**; with more than one gateway saved, **Send to · <gateway name>** (the roster's optional `gateway`) | — |
| Bot row | face, name, second line **Active <relative time, short>** (for example "Active 5 min. ago"), or **Bot Chat** when the roster has no time; a checkmark on the chosen one | `share.bot.<profile>` |
| No bots in the roster | **Open Hermes HQ once so your bots appear here.** | — |

VoiceOver: a bot row is one element, "<name>, <second line>", with the selected trait on the chosen one and the
dimmed trait on one that cannot receive; thumbnails are labelled with their file names; faces are hidden.

**Owner.** `M:MEMORY.md` index: "wrapping cells need 12–14pt vertical padding"; "never ship CSS imitation glass;
native glass controls/sheets". Both hold here.

**Fixture.** F1 on 9910 (command in §7.1).

**Acceptance.**
1. With Hermes last active before Ivy, Ivy is listed first; after one share to Hermes, the next sheet opens with
   Hermes chosen (checkmark) while the order still follows activity.
2. A choice remembered as `legacy::ivy` (written into `choice.json` by the test) selects Ivy (D6).
3. Send is disabled with no message and no readable item, and enabled the moment one character is typed.
4. Screenshots looked at: a link share, a text share, a 3-photo share, a mixed share, each in light and dark, and one
   at the largest accessibility text size (no clipped or overlapping text, Send and Cancel reachable).
5. `ShareSheetStateTests` pass (order, ties, selection fallbacks, canSend table, labels).

### 7.3 R3 · L588 — The extension sends by itself

**Web.** `W:ios/App/Shared/DispatchShareKit.swift:447-522` (the sequence), `:413-424` (own session), `:696-697`, `:756`
(server requests left for the app), `W:docs/share-extension.md:5-29`.

**Native.** `ShareSender` (port of the reference, D1):

```swift
nonisolated final class ShareSender: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    init(keychain: ShareKeychainStore = SystemShareKeychain(),
         interfaces: @escaping @Sendable () -> [ShareReach.Interface] = ShareReach.systemInterfaces,
         protocols: [AnyClass] = [],                       // tests: URLProtocol stubs
         progress: @escaping @Sendable (ShareStep) -> Void = { _ in })
    static func account(keychain: ShareKeychainStore, roster: ShareRoster?) throws -> ShareAccount
    func send(_ request: ShareRequest, roster: ShareRoster?) async throws -> ShareResult
}
nonisolated enum ShareStep: Equatable, Sendable { case connecting, uploading(Int, Int), sending }
```

The app is not launched, not woken and not messaged. The extension never opens the app's URL scheme.

**Wire.** §6 in full.

**UI.** The progress card over the dimmed list: **Connecting…** (steps 0–2), **Uploading…** for one attachment or
**Uploading 2 of 5…** for several (step 3), **Sending…** (steps 4–10); then a green checkmark and **Sent to Ivy**
(`share.sent`), a success haptic, the VoiceOver announcement "Sent to Ivy", and the sheet closes after 0.9 s.

**Approvals.** If the bot asks for approval because of the share, the request arrives on the extension's socket and is
ignored; the app shows it when it next opens that chat (the questions stream's cards). The extension never answers one.

**Owner.** `M:optimization-batch-oct2.md` lists the Share extension among the items the owner picked ("you do it
ALL"), shipped in build 94, and "Still for owner: gateway checks on phone (… Share …)".

**Fixture.** F1 on 9910 for the UI run; F2 on 9911 for the sender's fixture tests
(`python3 scripts/fixtures/share-gateway.py --port 9911 --redirect-port 9913 --credentials
build/fixtures/share-it.json --files build/fixtures/share-it-files --log build/fixtures/share-it.jsonl`).

**Acceptance.**
1. Fixture test: a share of one photo, one file and a message to Ivy produces, in the fixture's ledger and in this
   order: `GET /api/auth/me`, `GET /api/files`, two uploads, `POST /api/auth/ws-ticket`, the upgrade,
   `client.capabilities`, `session.resume` (stored id), `image.attach`, `file.attach` (both with the runtime id),
   `DELETE /api/files`, `prompt.submit`. The key set of every call's params equals §6.3 exactly, and the fixture
   recorded no `4000`.
2. Exactly one prompt reached Ivy's chat, with `queued == true`.
3. UI test: with the app **terminated**, a share from `HQShareProbe` shows "Sent to Ivy"; afterwards the app's process
   is still not running and every request in the fixture's log during the share carries the extension's user agent
   (`HermesHQShare/…`), none the app's.
4. Fixture test: the fixture sends an `approval.request` server request on the share's socket before answering
   `prompt.submit`; the extension sends no reply frame (`serverRequestReplies == 0`) and the share still succeeds.
5. A redirect (302 to another port) on `/api/auth/me` is not followed: the other port receives no request and the
   sheet says "Your gateway had a problem with this share. Try again in a minute."
6. Cancel during an upload: no `prompt.submit` reaches the fixture, the sheet closes, the temporary folder is gone.

### 7.4 R4 · L589 — The app's Keychain sign-in, renewed cookies written back

**Web.** `W:…/DispatchShareKit.swift:184-212` (read and update one item), `:436-445` (which account), `:536-553`
(`install`, `jar`, `persistRenewed`), `:278-294` (`replacingCookies`), `:582-599` (`verifySession`),
`W:docs/share-extension.md:31-35`.

**Native.** `ShareKeychain.swift`:

```swift
nonisolated protocol ShareKeychainStore: Sendable { func read() throws -> Data?; func update(_ data: Data) throws }
nonisolated struct SystemShareKeychain: ShareKeychainStore   // service from ShareIdentity, account "primary"
nonisolated enum ShareAccounts {
    static func current(in data: Data) -> ShareAccount?
    static func replacingCookies(in data: Data, account: String, expected: [[String: Any]], renewed: [[String: Any]]) -> Data?
    static func replacingNous(in data: Data, account: String, expected: ShareNous, renewed: ShareNous) -> Data?
    static func sameCookies(_ a: [[String: Any]], _ b: [[String: Any]]) -> Bool        // same name=value set
    static func encode(_ cookie: HTTPCookie) -> [String: Any]; static func decode(_ entry: [String: Any]) -> HTTPCookie?
}
```

Rules, all from the reference:

* `read()`: `errSecItemNotFound` → nil (signed out); `errSecInteractionNotAllowed` → `locked`; any other status →
  `keychain(status)`.
* **Write-back happens only when all of these hold**: the jar's cookies for the gateway differ from the ones the share
  started with; the Keychain item, re-read at that moment, still has this account as `current`; that account still
  holds exactly the cookies the share started with (by name and value). Then the account's `cookies` are replaced and
  nothing else in the JSON changes. Otherwise nothing is written: an app that renewed, signed out or switched
  meanwhile wins. A build-89 item (it holds a password) is never written.
* It is attempted after any response that carries `Set-Cookie`, and once more after `prompt.submit`.
* **A refused session (401/403 on `/api/auth/me`)**: if the Keychain now holds different cookies for the same account
  (the app renewed), install those and ask once more; still refused → `sessionEnded`. Never more than this one retry,
  never a sign-in.
* Cookie JSON keys are `SavedCookie`'s: `name`, `value`, `domain`, `path`, `expires` (seconds), `secure`, `httpOnly`,
  `sameSite`.

The app's side already exists: a refused app session tries the Keychain's copy once
(`N:HermesKit/Net/GatewayAuth.swift:155-169`) and its own write-back is a compare-and-swap
(`N:HermesKit/Net/Keychain.swift:92-103`), so it never overwrites the extension's renewal with an older jar.

**Wire.** Steps 1 and 11 of §6.2; `Set-Cookie` on any response.

**UI.** None when it works. When the Keychain cannot be used: the blocked screen (§7.8) with "Unlock your iPhone to
share." or "Hermes HQ couldn’t read your sign-in. Open Hermes HQ, then share again."

**Owner.** `M:optimization-batch-oct2.md`: "Still for owner: gateway checks on phone (push alerts, Approve from lock
screen, Share, staying signed in after update)". Staying signed in is the point of the compare-and-swap.

**Fixture.** F2 on 9911 for the sender tests; F1 on 9910 for the simulator run. Both issue Hermes' rotating
`hermes_session_at` / `hermes_session_rt` cookies; `POST /__fixture/expire-access` lapses the access cookie so the next
request is answered with a fresh pair.

**Acceptance.**
1. Unit: `replacingCookies` writes when expected matches; writes nothing when the account is no longer current, when
   its cookies differ from `expected`, when `renewed` is empty or equal, and for a build-89 item; a second account,
   `provider`, `label` and an invented unknown key all survive a write byte-for-value.
2. Unit: cookie JSON written by ShareKit decodes with the app's `SavedCookie` and back (parity).
3. Fixture test: sign in once (one attempt), put the cookies in an in-memory Keychain, `expire-access`, send a text
   share → the in-memory item now holds the renewed pair and `ShareResult.renewedCookies == true`.
4. Fixture test: same, but the in-memory Keychain changes its cookies (as the app would) between the share's read and
   its write → `update` is never called.
5. Fixture test: the share starts with stale cookies while the Keychain holds fresh ones → one 401, one retry, sent.
6. Simulator (the real shared Keychain item): sign in through the app's form, background it, `expire-access`, share
   from the probe → "Sent to Ivy"; bring the app forward → it is still signed in (Bots list, no sign-in form), and
   `/__fixture/auth` counts no new password sign-in.
7. The extension process never calls `SecItemAdd` or `SecItemDelete` (grep of `ShareKit/`, asserted by a source test).

### 7.5 R5 · L590 — Roster and faces in the App Group

**Web.** `W:src/share-roster.ts:38-70` (which rows: own gateway only, no ghost, no remote, no hidden; session =
`canonical_session.resolved_id || id`; last active from the canonical, else the last session), `:74-113` (debounce
800 ms, only when changed), `W:ios/App/App/DispatchShare.swift:19-43` (≤ 200 rows, name ≤ 80, valid profile, face file
name, write only when changed), `W:…/HermesNative.swift:2215`, `:2260` (cleared on sign-out and switch),
`W:…/DispatchShareKit.swift:72-132` (the store).

**Native.** `ShareRosterRows.rows(_ bots: [Bot]) -> [ShareRosterRows.Draft]` (pure):

* in the Bots list's own order; skip `bot.hidden`; skip a profile that fails `ShareRules.validProfile`; skip an empty
  name; stop at 200;
* `key = "ios-direct::" + bot.id`, `profile = bot.id`, `name` = trimmed, first 80 characters;
* `session = bot.canonicalSessionId` when `ShareRules.validSession`, else `""`;
* `lastActive = bot.lastActive` as Unix seconds when > 0; `color = ""`;
* `imageKey = "head:" + hex(SHA-256(sorted-keys JSON of bot.head, or "default:" + profile))` (stable across launches;
  `Hasher` is not).

Ghost and remote rows do not exist in the native roster (one gateway's `profiles.list`); if a later stream adds
remote bots to `Bot`, they must be skipped here.

`ShareRosterWriter` (main actor): `schedule` restarts a 0.8 s timer; when it fires, it reads the **current stored
account** (`AccountVault.app.peek()`), draws the faces whose file is missing (`HeadImageCache.shared.image(for:
Head.resolve(bot.head, profile: bot.id), side: 120, scale: 1, dark: false)` → PNG), and hands the rest to a utility
queue: build `ShareRoster(account: stored.key, url: stored.url, username: stored.username, limitBytes: 33554432,
bots:, savedAt:)`; if the roster on disk has the same account, bots and limit and there are no new pictures, write
nothing; else `ShareStore.save(roster, pictures:)`. Writes for an account that is no longer current when the queue
runs are dropped.

`clear()` removes `roster.json`, `last-sent.json`, `choice.json` and `avatars/`.

**Wire.** None (the app already has the roster).

**UI.** None in the app. In the sheet: the bots and faces of §7.2.

**Owner.** `M:hermes-hq-native.md` line 83 records the identity the native app moved into: "com.charlesmcdowell.dispatch
(+ .share/.notifications), App Group group.com.charlesmcdowell.dispatch, Keychain service …". Original robot heads
only (no hats, no Character theme: owner removed them).

**Fixture.** F1 on 9910; `POST /__fixture/share-roster {"hidden":["ivy"]}` hides a bot, `{"noChat":["ivy"]}` takes its
Bot Chat away, `{"extra":250}` adds 250 invented bots (§10.1). F4 on 9914 is the second gateway for the switch
(`python3 scripts/fixtures/share-gateway.py --port 9914 --credentials build/fixtures/share-b.json --files
build/fixtures/share-b-files --log build/fixtures/share-b.jsonl`).

**Acceptance.**
1. Unit (`ShareRosterRowsTests`, `ShareRosterWriterTests`, `ShareStoreTests`): hidden left out; a bot without a Bot
   Chat kept with `session == ""`; 250 bots → 200; an 81-character name → 80; invalid profile dropped; unchanged input
   writes nothing (file modification date unchanged); a changed head writes a new face and removes the old file;
   `clear()` leaves the folder empty; a roster for account A is not written once account B is current.
2. Simulator: after signing in to F1, within 3 s `roster.json` exists in the group folder with `account` =
   `<url>\n<username>`, `limitBytes == 33554432`, both bots, and each `avatar` file is a 120×120 PNG.
3. `share-roster {"hidden":["ivy"]}` then pull to refresh in Bots → Ivy disappears from `roster.json` and from the
   sheet.
4. Sign Out → the group folder holds no `roster.json`, no `avatars/`, no `choice.json`, no `last-sent.json`; the sheet
   says "Can’t Share Yet · Open Hermes HQ and sign in to your gateway, then share again."
5. Switch to the F4 gateway (Settings › gateways) → the old roster is gone at once; within 3 s the new gateway's
   roster is there with F4's account key.
6. The roster holds no message text, no preview, no cookie, no token (unit test over the encoded JSON keys).

### 7.6 R6 · L591 — Photos, videos, files

**Web.** `W:ios/App/ShareExtension/ShareItems.swift:46-77` (one provider at a time; caps before reading; duplicates),
`:91-124` (kinds), `:126-144` (photo), `:96-103` (video), `:146-170` (file; over the limit: measured, not copied),
`:184-200` (text cap), `W:ios/App/App/PickedFiles.swift:193-205` (3072 px JPEG, quality 0.85, pixels only), `:215-233`
(passthrough re-mux with `.forSharing()`), `:131-149` (safe names), `ShareView.swift:99-106` (the two warning rows),
`ShareModel.swift:59-68` (limit, oversized, canSend).

**Native.** `ShareItemLoader.load(_ inputs: [NSExtensionItem], into folder: URL, limit: Int) async -> (items:
[SharedItem], failures: [String])` and `ShareMedia`:

| Shared thing | What happens | Sent as |
|---|---|---|
| Image (any format ImageIO reads: HEIC, JPEG, PNG, GIF, RAW) | `loadFileRepresentation`; inside the callback, `ShareMedia.jpeg(at:maxPixel: 3072, quality: 0.85)`: ImageIO thumbnail with transform (the full bitmap is never decoded), orientation baked into the pixels, **no metadata written**, transparency onto white (D9). A 160 px thumbnail for the strip. | `<stem>.jpg`, `image.attach` |
| Movie | copied into the share's temporary folder, then `ShareMedia.removeLocation(fromMovieAt:)`: `AVAssetExportSession` passthrough (streams copied, never re-encoded) with `metadataItemFilter = .forSharing()`, replacing the copy. If that fails the video is **not sent**: it appears as "Hermes HQ couldn’t read “<name>”." | original container, `file.attach` |
| http/https URL | kept as a link | text in the prompt |
| Any other file | copied as it is, under `ShareRules.safeName` (no path, no control characters, none of `" \ / :`, ≤ 180 bytes keeping the extension; a name without an extension takes the provider file's) | `file.attach` |
| Plain text | trimmed; at most 262 144 characters (a text file is read only that far); a lone http(s) URL without spaces becomes a link | text in the prompt |
| A caption without attachments (`attributedContentText`) | kept as text | text in the prompt |

Caps: the 11th photo and the 11th file are **not read at all** (no decode, no copy). The same text or link twice is
kept once. A file or video over the limit is measured and named, never copied or re-muxed.

Limit: `roster.limitBytes`, else 33 554 432 (D5). `fits` = `0 < bytes ≤ limit`. `megabytes(limit)` = `"32 MB"`.

Memory: providers are read strictly one after another inside `autoreleasepool`; thumbnails are made from the staged
JPEG by ImageIO; nothing keeps a full-size bitmap.

Temporary files: `tmp/dispatch-share-<UUID>/<UUID>/<name>`, removed when the sheet closes (sent, cancelled or
abandoned); folders older than an hour left by a sheet the system ended are swept when the next sheet opens.

**Wire.** Steps 2, 3, 8, 9, 9d of §6.2.

**UI.**

| State | Words |
|---|---|
| Photos present | **Sent without location or camera details** |
| An item could not be read (unknown type, failed copy, video whose location could not be removed) | **Hermes HQ couldn’t read “<name>”.** (grey, warning triangle; the rest of the share can still go) |
| A file or video over the limit | **“<name>” is larger than 32 MB, your attachment limit.** (red; **Send is disabled** until it is removed with the row's ✕ or a swipe, or the share is cancelled), then **Remove it, or cancel and share again.** (UX study 2026-10-19 #88) |
| Gateway answers 413 to an upload | failure row **“<name>” is larger than your attachment limit.** |
| Zero-byte or vanished file at send time | failure row **Hermes HQ couldn’t read “<name>”.** |

**Owner.** No memory note changes the build-240 rules; the composer's photo privacy rule (no location to the gateway)
is the same one the attachments stream shipped (spec 1x-attachments §5).

**Fixture.** F1 on 9910. It records each upload's bytes, SHA-256, whether it is a JPEG, whether it carries GPS or
camera tags, and for a movie whether it still holds a location atom; the stored files stay under
`build/fixtures/share-files/uploads/` for a test to open.

**Acceptance.**
1. Unit (`ShareMediaTests`): a 4032×3024 HEIC with orientation 6, GPS, camera make/model
   (`N:UITests/Fixtures/attachments/photo-gps.heic`) → a JPEG whose long side is 3072, shown upright, with no GPS,
   TIFF or EXIF dictionary; a 48 MP JPEG is converted with a memory-footprint growth under 60 MB; a transparent PNG
   becomes a JPEG with a white background; a 3-frame GIF becomes one still.
2. Unit: a generated `.mov` with an ISO 6709 location loses it and still plays (duration unchanged ± 0.1 s); a file
   of text bytes named `.mov` throws, and the loader reports its name as unreadable.
3. Unit (`ShareItemLoaderTests`, real `NSItemProvider`s): 12 images → 10 items and the last two providers were never
   asked to load; the same link twice → one; 300 000 characters → 262 144; a 33 MB file → an item with `bytes` 33 MB
   and no copy on disk; `safeName` table equals `AttachmentStaging.safeName` for 40 names (parity).
4. Simulator: share `photo-gps.heic` → the stored upload is a JPEG ≤ 3072 px with no GPS and no camera tags (opened by
   the test with ImageIO), the sheet showed the privacy line, the prompt was "What do you see in this image?".
5. Simulator: share `clip-gps.mov` → the stored upload has no location (`AVURLAsset` metadata); share `broken.mov`
   plus a note → the sheet shows "Hermes HQ couldn’t read “broken.mov”." and Send still sends the note alone.
6. Simulator: share a 33 MB file → the red line, Send disabled, and the fixture recorded no upload. A file of exactly
   33 554 432 bytes is sent.

### 7.7 R7 · L592 — What the prompt says

**Web.** `W:…/DispatchShareKit.swift:158-164` (`promptText`), `:452`, `:513` (used before and after attaching).

**Native.** `ShareRules.promptText(message:shared:fileRefs:hasImages:)`, a character-for-character port:

1. trim the message and each shared text or link; drop empties; drop repeats (first wins); join with a blank line →
   *body* (the person's own words first);
2. join the non-empty `ref_text`s of the attached files with single newlines → *refs*;
3. the prompt is *refs*, a blank line, *body* (whichever exist);
4. if that is empty and there is at least one photo: **`What do you see in this image?`**

| Message | Shared | Files | Photos | Prompt |
|---|---|---|---|---|
| `From Safari` | `https://example.com/a` | — | — | `From Safari\n\nhttps://example.com/a` |
| — | — | — | 1 | `What do you see in this image?` |
| `Look` | — | — | 2 | `Look` |
| `From Files` | — | `@file:/x/note.txt` | — | `@file:/x/note.txt\n\nFrom Files` |
| — | — | two files | 1 | `@file:/x/a.txt\n@file:/x/b.txt` |
| `Same` | `Same`, `Same` | — | — | `Same` |

**Wire.** `prompt.submit.params.text` (§6.3).

**UI.** None (the words are the bot's input). The app shows them as the person's own message when the chat opens.

**Owner.** None beyond build 240's behaviour; "What do you see in this image?" is the composer's own question
(`N:HermesKit/Attachments/AttachmentSender.swift`, `defaultQuestion`). The sheet shows it greyed as the message box's placeholder
when only photos are shared (UX study 2026-10-21 #148).

**Fixture.** F2 on 9911 (sender tests read `prompts[].text` from `/__fixture/state`); F1 on 9910 for the UI run.

**Acceptance.**
1. Unit (`ShareRulesTests`): the table above, plus whitespace-only inputs, and parity with
   `AttachmentSender.promptText(typed:fileRefs:hasImages:)` for every row with nothing shared.
2. Fixture test: each of the six shares reaches the fixture with exactly that `text`.
3. Simulator: the chat the app opens afterwards (§7.11) shows the same words as the person's bubble.

### 7.8 R8 · L593 — Plain-words failures, Try Again, never sent later

**Web.** `W:…/DispatchShareKit.swift:332-368` (the cases, their sentences, `retryable`), `:436-445` (the checks when
the sheet opens), `:769-777` (gateway refusals), `W:ios/App/Shared/HermesTransportShared.swift:248-262` (transport
sentences), `ShareModel.swift:36-38`, `:98-110` (blocked versus failure row), `ShareView.swift:39-45`, `:180-189`.

**Native.** `ShareFailure` (`Error, Equatable, Sendable`) with `message`, `retryable`, and `blocksSheet`.

Checked **when the sheet opens**, in this order (any of them replaces the whole sheet):

| Check | Failure | Sentence under **Can’t Share Yet** |
|---|---|---|
| Keychain has no item, the JSON has no current account, or the account has neither cookies nor a Nous pair | `signedOut` | **Open Hermes HQ and sign in to your gateway, then share again.** |
| Keychain says the phone is locked | `locked` | **Unlock your iPhone to share.** ("iPad" on an iPad, "Mac" on the Mac: `ShareFailure.device`, audit 09-24) |
| Keychain answers any other error | `keychain` | **Hermes HQ couldn’t read your sign-in. Open Hermes HQ, then share again.** |
| A build-89 item (single account with a password, no `accounts`) | `needsApp` | **Open Hermes HQ once to finish updating, then share again.** |
| No `roster.json` (or no App Group) | `noRoster` | **Open Hermes HQ once so your bots appear here, then share again.** |
| The roster's account is not the Keychain's current account | `otherAccount` | **Hermes HQ switched gateways. Open Hermes HQ so your bots appear here, then share again.** |

The blocked screen is a `ContentUnavailableView` with the symbol `person.crop.circle.badge.exclamationmark`
(`share.blocked`), Cancel only, no Send.

**After Send**, a failure is either blocking (`signedOut`, `needsApp`, `noRoster`, `sessionEnded`, `otherAccount` →
the same blocked screen) or a red row at the end of the list (`share.failure`), with **Try Again** only when
`retryable`; the share stays exactly as it was:

| Failure | Sentence | Try Again |
|---|---|---|
| `sessionEnded` (blocking) | **Your gateway ended this iPhone’s session. Open Hermes HQ to sign in again.** (the device's word, as for `locked`) | — |
| `tailscaleOff` | **Turn on Tailscale to reach the computer running Hermes.** | yes |
| `locked` | **Unlock your iPhone to share.** | yes |
| `keychain` | **Hermes HQ couldn’t read your sign-in. Open Hermes HQ, then share again.** | no |
| `timedOut`, transport −1001 | **Your gateway took too long to answer. It may be busy — try again.** | yes |
| transport −1003, −1004, −1005, −1009 | **Can’t reach the computer running Hermes. Check that you’re online and that Tailscale or your VPN is on, then try again.** | yes |
| transport −999 from the system | **The connection changed before your gateway answered. Try again.** | yes |
| TLS trust failures | **This device doesn’t trust your gateway’s HTTPS certificate.** | yes |
| ATS refusal of plain http | **This gateway address needs https://.** | yes |
| other URL errors | **Can’t reach the computer running Hermes right now. Try again.** | yes |
| not a URL error | **Your gateway couldn’t complete that request. Try again.** | yes |
| `gateway(429)` | **Your gateway is busy. Try again in a minute.** | yes |
| `gateway(status)` | **Your gateway had a problem with this share. Try again in a minute.** (D8 amendment: no HTTP status) | yes |
| `noChat` | **Open this bot in Hermes HQ once, then share to it.** | no |
| `tooLarge(name)` | **“<name>” is larger than your attachment limit.** | no |
| `unreadable(name)` | **Hermes HQ couldn’t read “<name>”.** | no |
| `nothingToSend` | **There’s nothing to send.** | no |
| `refused("")` | **Your gateway didn’t accept this share.** | no |
| `refused(detail)` | the detail: **Share at most 10 photos and 10 files at a time.** · **Your gateway has no folder for uploads.** · **Your gateway refused a file this large.** · **Your gateway didn’t store “<name>”.** · **Your gateway didn’t open a connection.** · **Your gateway couldn’t open this bot’s chat.** · **Your gateway didn’t accept “<name>”.** · **Your gateway answered in a way Hermes HQ doesn’t understand.** | no |
| RPC error 4001 | **Your gateway couldn’t find this bot’s chat. Open it in Hermes HQ, then share again.** | no |
| RPC error 4009 | **This bot is busy. Try again in a moment.** | no |
| other RPC error | **Your gateway said: <first line of its message>** when that line is 1–160 characters, else **Your gateway didn’t accept this share.** | no |
| `unconfirmed` | **Hermes HQ couldn’t confirm the share arrived. Check the chat before sending again.** | no |
| `cancelled` | (never shown: **Sending was cancelled.**) | — |

The transport classes are the app's (`N:HermesKit/Net/GatewayFailure.swift`); ShareKit's own table is pinned to the
reference's sentences by a unit test.

**Never sent later.** A failed share is not stored anywhere. Try Again runs the whole sequence again from step 0
with the same items; closing the sheet drops it. `unconfirmed` has no Try Again on purpose: the bot may already have
the share (Hermes has no idempotency key), so the sheet leaves a `last-sent.json` note and the app opens that chat
next, to look before sending again. Send itself stays available.

Each failure fires an error haptic and (D16) a VoiceOver announcement of its sentence.

**Wire.** The status and error mapping of §6.2.

**Owner.** `M:share-nous-accounts.md` shows what a wrong "Can’t Share Yet" costs: "Owner reported on 2026-10-08 that
sharing to Hermes HQ showed "Can't Share Yet. Open Hermes HQ and sign in…" while they were signed in." Every blocked
state must be true. `M:hermes-hq-native.md`: plain language, the web app's own wording.

**Fixture.** F1 on 9910 and F2 on 9911, with `POST /__fixture/share-fail`, `POST /__fixture/share-hold` and
`POST /__fixture/revoke` (§10.1).

**Acceptance.**
1. Unit (`ShareFailureTests`): every sentence above, character for character (curly apostrophes and quotes, the em
   dash, the ellipses); the retryable set is exactly `tailscaleOff`, `gateway`, `transport`, `timedOut`, `locked`; the
   blocking set is exactly the five named; no sentence contains "Dispatch".
2. Unit (`ShareSenderTests`, stubbed transport): with a tailnet-only address and no `utun` tailnet interface, **zero
   requests** are made and the failure is `tailscaleOff`; each opening check returns its failure in the order above.
3. Fixture tests: `share-fail` 429 on the upload → "busy" + retryable; 500 on `/api/files` → "(HTTP 500)"; 4001 and
   4009 on `session.resume` → their sentences; `image.attach` answering `attached:false` with a message → that
   message; `revoke` → `sessionEnded`.
4. Fixture test: `share-hold {"method":"prompt.submit","drop":true}` → `unconfirmed`; the fixture holds exactly one
   prompt; a second `send` is not made by itself.
5. Simulator, real states: signed out; roster deleted (the test removes `roster.json`) → no-roster; roster for another
   account (the test edits `account`) → switched-gateways; `revoke` then Send → session-ended; 429 → failure row with
   Try Again, and Try Again after clearing the fault sends once. Screenshots looked at for each.
6. Simulator, forced through `debug.json` (D14) for the screenshot only: needs-update, locked, Keychain unreadable,
   Tailscale off.
7. After any failure followed by Cancel, relaunching the app or reopening the sheet sends nothing (the fixture's
   prompt count does not change).

### 7.9 R9 · L594 — Sign in with Nous accounts

**Web (build 240).** A Nous account **shares**: `W:…/DispatchShareKit.swift:441` accepts an account with a Nous pair,
`:554-561` sends its bearer and no cookies, `:468` renews a lapsing pair before the first request, `:587-592` renews
once on a refusal, `:604-629` adopts a newer Keychain pair or rotates and writes the rotated pair back
(`:297-304`). The parity row describes the state before build 214 (D4).

**Native.**

```swift
nonisolated struct ShareNous: Equatable, Sendable {
    var accessToken, refreshToken: String; var expiresAt: Double; var userId: String; var obtainedAt: Double?
    func samePair(_ other: ShareNous) -> Bool            // access, refresh, user id
    func needsRenewal(now: Double) -> Bool               // the app's rule, D12
    static func renewed(status: Int, body: Data, userId: String, now: Double) -> ShareNous?
}
```

`renewNous(force:)`, once per share at most:

1. Re-read the Keychain. If the same account holds a **different pair for the same user**, adopt it (the app rotated
   meanwhile); if that one needs no renewal, stop.
2. Otherwise, unless forced, stop when the pair needs no renewal.
3. `POST /auth/native/refresh` with the pair's refresh token (15 s).
4. A 200 naming provider `nous`, both tokens and the **same** `user_id` gives the rotated pair (`expiresAt` from
   `expires_at`, `obtainedAt` = now). Anything else: 200/400/401/403 → `sessionEnded`; other statuses →
   `gateway(status)`.
5. Write the rotated pair to the Keychain **at once**, only while that account still holds the pair just spent
   (`replacingNous`, compared with `samePair`); one more attempt 200 ms later if the write itself fails. Then carry on
   with the new pair either way (it is already the only live one).

The app's half exists: before renewing, it adopts a pair rotated elsewhere (`N:HermesKit/Net/GatewayAuth.swift:171-180`,
spec 01 §7.3 rule 6), so it never replays the refresh token the extension spent.

**Wire.** §6.1 (bearer, no cookies), step 0n and step 1 of §6.2, the refresh payload of §6.3.

**UI.** The same sheet as any account. The blocked screen appears for a Nous account only for the real reasons of
§7.8; after a refused renewal: **Your gateway ended this iPhone’s session. Open Hermes HQ to sign in again.**

**Owner.** `M:share-nous-accounts.md`: "**Cause:** ShareSender.account … required session cookies. A Sign in with Nous
account stores `nous` (a bearer plus a rotating refresh token) and no cookies, so it always read as `.signedOut`."
"**Release:** SHIPPED and PUBLIC on 2026-10-08 (the owner said "make it public once it's in TestFlight")."
"**Remaining risk:** the app and the extension renewing at the same moment (only possible with the app in the
foreground, e.g. iPad split view) could still replay a refresh token."

**Fixture.** F2 on 9911: `POST /__fixture/nous/issue {"ttl": 3600}` hands out a bearer pair, `POST /auth/native/refresh`
rotates it and revokes the family on a replay, `GET /__fixture/nous` counts refreshes and replays. F3 for the real
Keychain on the simulator, text shares only (`python3 /Users/me/Projects/hermes-hq-native-ref238/scripts/nous-fixture-gateway.py
--port 9912 --portal-port 9913 --public-url http://127.0.0.1:9912 --access-ttl 30`), signed in to through its fake
Portal page as `N:UITests/settings/SettingsEndToEndTests.swift:836-866` does.

**Acceptance.**
1. Unit: `needsRenewal` equals `NousTokens.needsRenewal` for a table of (expiresAt, obtainedAt, now) (parity);
   `replacingNous` writes only while the spent pair is still there and keeps every other field; `renewed` refuses
   another user's id, a missing token, a non-`nous` provider.
2. Fixture test: a Nous account with a live pair shares a photo and a note → sent; every HTTP request carried the
   bearer and no `Cookie` header; `/__fixture/nous` counts 0 refreshes.
3. Fixture test: a pair issued with `ttl` 1, after 2 s → exactly one refresh, the in-memory Keychain holds the
   rotated pair with `obtainedAt`, the share is sent, `replayed == 0`.
4. Fixture test: the Keychain already holds a newer pair than the one the share read → 0 refreshes, the newer pair is
   used.
5. Fixture test: `nous/revoke` → `sessionEnded`, one refresh attempt, no second.
6. Simulator with F3: sign in with Nous through the Portal page, background the app, wait 31 s, share a text from the
   probe → "Sent to Hermes"; bring the app forward → still signed in; `/__fixture/nous` shows `replayed == 0`.
7. The sheet for a signed-in Nous account never shows "Can’t Share Yet" (the regression the owner reported).

### 7.10 R10 · L595 — A bot without a Bot Chat

**Web.** `W:…/DispatchShareKit.swift:35-36`, `:45` (`canReceive` needs a valid stored session), `ShareView.swift:146-151`,
`:162-163` (the row is disabled and says why), `ShareModel.swift:39-42` (never preselected), `:65-68` (Send needs a bot
that can receive), `:449` (`noChat` if it gets that far), `W:docs/share-extension.md:86` (the extension never creates a
chat).

**Native.** The roster carries `session: ""` for such a bot (§7.5). `ShareBot.canReceive` = valid session and valid
profile. The row is a disabled button; it cannot be chosen; a remembered choice that can no longer receive falls back
to the first bot that can. Opening the bot once in the app gives it a Bot Chat; the next roster write (within ~1 s of
the Bots list updating) makes the row usable.

**Wire.** None (nothing is sent for it).

**UI.** The bot's row with its name in the secondary colour and the second line **Open this bot in Hermes HQ first**;
VoiceOver reads "<name>, Open this bot in Hermes HQ first, dimmed". If every bot is like this, no row is chosen and
Send is disabled. If the state changes under the sheet and Send still reaches the sender: **Open this bot in Hermes
HQ once, then share to it.**

**Owner.** No note beyond build 240's behaviour.

**Fixture.** F1 on 9910 with `POST /__fixture/share-roster {"noChat":["ivy"]}`.

**Acceptance.**
1. Unit: `canReceive` false for `""`, for an id with a slash, for 161 characters; `selection` skips such a bot even
   when it is the remembered one.
2. Simulator: with Ivy's Bot Chat removed, the sheet shows Ivy disabled with the sentence, Hermes chosen; tapping Ivy
   changes nothing; a share goes to Hermes. Screenshot looked at.
3. Simulator: with both bots' chats removed, Send is disabled and no request reaches the fixture.

### 7.11 R11 · L596 — The app opens that chat afterwards

**Web.** `W:ios/App/ShareExtension/ShareModel.swift:90-92` (recorded on success), `:103-106` (also when unconfirmed),
`W:…/DispatchShareKit.swift:119-127` (`takeSent`: once, same account, at most 300 s old, not more than 5 s in the
future, valid session), `W:ios/App/App/DispatchShare.swift:59-66`, `W:ios/App/App/HermesViewController.swift:685-689`
(taken when the scene becomes active, routed like a notification tap).

**Native.** `AppModel.openSharedChatIfAny()`:

```swift
guard let store = ShareStore(), store.lastSent != nil,
      let key = AccountVault.app.peek()?.key,                 // signed in: the note stays for later otherwise
      let sent = store.takeSent(account: key) else { return } // removes the file whatever it holds
openNotifiedChat(stored: sent.session, profile: sent.profile)
```

`openNotifiedChat` (`N:App/Notifications/AppModel+Notifications.swift:238-…`) already does the rest: it waits for the
tabs and the lists on a cold launch, does nothing if that chat is on screen, opens the bot's own chat from Bots. It is
called from `appDidBecomeActive()` and again at the end of `activate(_:)` (a cold launch can become active before the
account is restored; the note is taken only once). A launch that would otherwise restore the last chat on show ends
on the shared chat.

The chat then shows the shared message and the bot's reply through the app's normal open path (fresh history and
event catch-up); nothing is copied from the extension.

**It gives way twice** (m9 review; `ShareInbox.step`, `N:App/Share/AppModel+Share.swift`). `openNotifiedChat`
dismisses whatever is presented, which is right for a chat the person tapped and wrong for one they did not ask for:

* **A sheet is up** (a New Bot form, a Settings editor, a file's share sheet): the share's chat is not opened, so
  nothing typed is thrown away. The note is taken all the same: the chat is offered once, never later.
* **The person asked for a chat themselves** (a tapped alert, the peek, a `hermes://` link) in the 10 seconds before
  the note was taken or since: theirs is shown and the share's is dropped. 10 s is as long as `openNotifiedChat` may
  still be waiting for the lists on a cold launch, so the two can never land one after the other.

The share's open runs one main-queue turn after the note is taken (a tap delivered in the same turn is heard first)
and does its own waiting for the tabs and the lists (40 looks, 0.25 s apart) before it hands over.

**Wire.** None of its own.

**UI.** Bringing Hermes HQ forward within 5 minutes of a share shows that bot's chat, with the shared message as the
person's bubble. After 5 minutes, for another account, or signed out: the app opens where it was.

**Owner.** `M:optimization-batch-oct2.md`, findings: "after a share the chat's VoiceOver label can say Reconnecting".
The native chat must not be left saying that once it has caught up (checked in §12.6).

**Fixture.** F1 on 9910 (its chat stores the shared prompt and streams a short reply, so the opened chat has something
to show).

**Acceptance.**
1. Unit (`ShareStoreTests`): `takeSent` returns the note at 0 s, 299 s and −4 s; nil at 301 s, −6 s, another account,
   an invalid session; the file is gone after every call.
2. Simulator: share to Ivy from the probe with the app in the background on the Hermes chat → activate the app → Ivy's
   chat is on screen within 3 s and shows the shared words and then the reply, without pulling to refresh.
3. Simulator: same with the app terminated (cold launch) → Ivy's chat.
4. Simulator: a note written by the test 301 s in the past, and one for another account → the app stays where it was
   and the file is gone.
5. Simulator: after an `unconfirmed` share (`share-hold` with `drop`), the app opens that chat and the shared message
   is there exactly once.

---

## 8. Every UI state (summary)

| # | State | What is on screen | Words |
|---|---|---|---|
| 1 | Opening, items still loading | list with a spinner row, message field, bots; Send disabled | **Preparing…** |
| 2 | Ready | items, message field, bots, Send enabled when allowed | §7.2 |
| 3 | Nothing readable and no message | item rows say what could not be read; Send disabled | **Hermes HQ couldn’t read “<name>”.** |
| 4 | Oversized item | red row with a ✕ (and a trailing Remove swipe); Send disabled until it is removed | **“<name>” is larger than 32 MB, your attachment limit.** |
| 5 | No bots in the roster | one grey row under "Send to"; Send disabled | **Open Hermes HQ once so your bots appear here.** |
| 6 | Bot without a Bot Chat | disabled row | **Open this bot in Hermes HQ first** |
| 7 | Blocked | `ContentUnavailableView`, Cancel only | **Can’t Share Yet** + one sentence of §7.8 |
| 8 | Sending | glass card over the disabled list; Cancel still works; the sheet cannot be swiped away | **Connecting…** · **Uploading…** · **Uploading 2 of 5…** · **Sending…** |
| 9 | Sent | glass card, green checkmark, closes after 0.9 s | **Sent to <name>** |
| 10 | Failed, worth retrying | red row at the end of the list + button | sentence + **Try Again** |
| 11 | Failed, not worth retrying | red row | sentence |
| 12 | Not confirmed | red row, no Try Again | **Hermes HQ couldn’t confirm the share arrived. Check the chat before sending again.** |

Bars: **Hermes HQ** (title), **Cancel**, **Send**. Placeholder: **Add a message**. Header: **Send to**. Photo line:
**Sent without location or camera details**. Bot second lines: **Active <time>** · **Bot Chat**.

Every control does something: Send is hidden when blocked and disabled with a visible reason otherwise; Try Again
appears only where retrying can help.

---

## 9. What the owner approved (memory)

* `M:optimization-batch-oct2.md` (2026-10-02): the owner picked the Share extension from the optimization list and
  said "you do it ALL"; it shipped in build 94 with the App Group. "Apple portal: App Group
  group.com.charlesmcdowell.dispatch registered and on both App IDs (com.charlesmcdowell.dispatch, .dispatch.share)".
  Release gotchas: "App Groups can't be created by API-key automatic signing (archive fails "profile doesn't match
  application-groups")". Open finding: "after a share the chat's VoiceOver label can say Reconnecting."
* `M:share-nous-accounts.md` (2026-10-08): the "Can’t Share Yet" report, the bearer and rotation hand-off fix, public
  as build 214, and the remaining risk of both processes renewing at once (quoted in §7.9).
* `M:hermes-hq-native.md`: the native app lives in the Hermes HQ record ("com.charlesmcdowell.dispatch (+
  .share/.notifications), App Group group.com.charlesmcdowell.dispatch"); "Share ext + widgets (need App Group portal
  step)" was the open item this stream closes; one feature at a time.
* `M:MEMORY.md` index: "wrapping cells need 12–14pt vertical padding"; "never ship CSS imitation glass; native glass
  controls/sheets"; the product is named Hermes HQ everywhere a person looks.

---

## 10. Stand-in gateways and test tools

### 10.1 New: `scripts/fixtures/share-gateway.py`

Loopback only, **ports 9910–9919 only** (it refuses any other), stdlib only, invented data, never forwards anything.
It loads `N:scripts/fixtures/attachments-gateway.py` by path (which loads `R8:scripts/performance-fixture-gateway.py`
read-only) and so inherits: password sign-in, the socket and streaming engine, bots "Hermes" (`default`, Bot Chat
`20260929_120000_aabbcc01`, runtime `5cc537d1`) and "Ivy" (`ivy`, `20260929_120000_aabbcc02`, runtime `bf611b3e`),
`GET /api/files`, `POST /api/files/upload-stream` (with GPS/camera detection), `DELETE /api/files`, strict
`image.attach` / `file.attach` / `prompt.submit` (4000 on an unknown key, 4001 for a wrong runtime id), stored user
rows and a short streamed reply. On top it adds what a share needs (ported from `W:scripts/share-fixture-gateway.py`):

| Addition | Detail |
|---|---|
| Hermes cookies | the gateway is built in Hermes mode: `hermes_session_at` (`--access-ttl`, default 43200 s) + `hermes_session_rt`; a lapsed access cookie with a valid refresh cookie is served and answered with a fresh pair; inherited controls `POST /__fixture/expire-access`, `POST /__fixture/revoke`, `GET /__fixture/auth` |
| Session gate | every `/api/*` route and the ws-ticket need the cookie session or a live bearer; else `401 {"detail":"Unauthorized"}` |
| Strict params | also on `session.resume` (allowed: `session_id`, `profile`, `cols`, `source`, `lazy`, `defer_history`, `omit_messages`, `eager_build`, `close_on_disconnect`, `inline_images`) and `client.capabilities` (`server_requests`) → `{"code":4000,"message":"invalid params"}` |
| `client.capabilities` | answers `{"server_requests":["approval.request","clarify.request"],"declines_not_shown":true}` |
| Nous | `POST /__fixture/nous/issue {"ttl"}` → a bearer pair (no Portal); a live bearer is a session; `POST /auth/native/refresh` rotates and revokes the family on a replay; `GET /__fixture/nous` → `{"counts":{"refresh","replayed","bearerOk","bearerRejected"}}`; `POST /__fixture/nous/revoke` |
| Movie check | an upload ending `.mov`/`.mp4`/`.m4v` records `location: true` when its bytes hold an ISO 6709 location string |
| `POST /__fixture/share-roster` | `{"hidden":[profiles], "noChat":[profiles], "extra": N}` reshapes the roster answer: hidden sets `ui_meta["hermes-bots"].hidden`, noChat removes the canonical session, extra appends N invented bots `load-001…` with valid Bot Chat ids and staggered `last_active` |
| `POST /__fixture/share-fail` | `{"target": "me"\|"files"\|"upload"\|"ticket"\|"delete"\|"<rpc method>", "status": 401\|403\|413\|429\|500\|302 (REST) or "code": N, "message": "…" (RPC) or "result": {…} (RPC, e.g. `{"attached":false,"message":"…"}`), "times": 1}`; a 302 points at `--redirect-port` |
| `POST /__fixture/share-hold` | `{"target": …, "seconds": S, "drop": bool}`: the next such call waits S seconds; with `drop`, an RPC is taken (a prompt is stored) and the socket closed without an answer |
| `POST /__fixture/share-server-request` | `{"before":"prompt.submit"}`: sends an `approval.request` server request on that socket first and counts any reply frame in `serverRequestReplies` |
| `POST /__fixture/share-reset` | everything back to the start (records, faults, holds, roster shape, Nous tables, transcripts) |
| `GET /__fixture/state` | adds `shareLedger` (every HTTP request, upgrade and RPC in order: `n`, `t`, `kind`, `method`, `path` or `rpc`, `keys`, `status` or `error`, `ua`, `auth`: `cookie`\|`bearer`\|`none`, `socket`), `prompts` (`session`, `profile`, `text`, `queued`), `uploads`, `deletes`, `held`, `serverRequestReplies`, `redirected` (requests the redirect port received) |
| `--log FILE` | the ledger as JSON lines (never a cookie, a token or a ticket: values are replaced by their lengths) |
| `GET /__fixture/page` | a page with one sentence in a text field, for the opt-in Safari text test |

Arguments: `--port` (required range), `--credentials FILE` (written 0600, never printed: `{"username","password","url"}`),
`--files DIR` (uploads and media, 0700), `--log FILE`, `--access-ttl S`, `--redirect-port P` (optional second listener
in 9910–9919 that only counts requests), `--keep-credentials`.

### 10.2 Start commands (this stream's ports)

| Name | Port(s) | Command | Used for |
|---|---|---|---|
| **F1** | 9910 | `python3 scripts/fixtures/share-gateway.py --port 9910 --credentials build/fixtures/share.json --files build/fixtures/share-files --log build/fixtures/share.jsonl` | the simulator run (`scripts/e2e-share.sh` starts and stops it) |
| **F2** | 9911 (+9913 redirect) | `python3 scripts/fixtures/share-gateway.py --port 9911 --redirect-port 9913 --credentials build/fixtures/share-it.json --files build/fixtures/share-it-files --log build/fixtures/share-it.jsonl` | `Tests/Share/ShareFixtureTests.swift` |
| **F3** | 9912 + 9913 | `python3 /Users/me/Projects/hermes-hq-native-ref238/scripts/nous-fixture-gateway.py --port 9912 --portal-port 9913 --public-url http://127.0.0.1:9912 --access-ttl 30` | Sign in with Nous through the real Keychain (text shares) |
| **F4** | 9914 | `python3 scripts/fixtures/share-gateway.py --port 9914 --credentials build/fixtures/share-b.json --files build/fixtures/share-b-files --log build/fixtures/share-b.jsonl` | the second gateway for the switch |

F2 and F3 both use 9913 and are never run at the same time. The stress tester runs the same commands on 9915 (F1),
9916 + 9918 (F2), 9917 + 9918 (F3), 9919 (F4), with file names ending `-s`.

Rules: check the port is free first (`lsof -nP -iTCP:<port> -sTCP:LISTEN`); stop only the process you started (its
pid); never start anything outside 9910–9919; one sign-in attempt per test, never a loop.

### 10.3 `HQShareProbe` (test-only host app)

`TestSupport/ShareProbe/ProbeApp.swift`, about 80 lines of SwiftUI. It reads the environment variable
`HQ_PROBE_ITEMS`, a JSON array, and shows one button **Share** (`probe.share`) that presents a
`UIActivityViewController` with those items:

```json
[{"text":"A sentence to share"}, {"url":"https://example.com/a"},
 {"file":"/Users/…/build/fixtures/share-media/photo-gps.heic"}, {"file":"/Users/…/clip-gps.mov"}]
```

`text` → `String`, `url` → `URL`, `file` → a file `URL` (the Simulator reads the Mac's paths). The UI test launches
the probe, taps `probe.share`, finds **Hermes HQ** among the app icons (scrolling the row, or through More: the
reference's `chooseDispatch`, `W:ios/App/AppUITests/ShareUITests.swift:53-66`), and from there addresses the
extension's elements through the probe's own element tree (`share.bot.ivy`, `share.message`, `share.send`,
`share.sent`, `share.failure`, `share.blocked`, `share.cancel`, `share.photo-privacy`).

### 10.4 `scripts/fixtures/make-share-media.swift` and `scripts/e2e-share.sh`

`swift scripts/fixtures/make-share-media.swift build/fixtures/share-media` writes invented media: `clip-gps.mov`
(1 s, 320×240, H.264, with `com.apple.quicktime.location.ISO6709` = `+37.3349-122.0090+010.000/`), `broken.mov` (text
bytes), `note.txt`, `p01.jpg` … `p12.jpg` (small photos with GPS), `big.bin` (33 MiB), `exact.bin` (exactly
33 554 432 bytes), `huge.jpg` (8064×6048). The script also copies `UITests/Fixtures/attachments/*`.

`scripts/e2e-share.sh SIM_UDID [RUNS]` (zsh, in the shape of `N:scripts/e2e-push.sh`):

1. forces `HQ_IDENTITY=original` (`export HQ_ORIGINAL=YES`; the extension is only embedded there), port
   `${HQN_SHARE_PORT:-9910}`, refuses a port outside 9910–9919 or a busy one;
2. makes the media, starts F1 (and F4 on `${HQN_SHARE_PORT_B:-9914}`), waits for the credentials files;
3. `xcodegen generate -q`, then `xcodebuild build-for-testing` on scheme `HermesHQNativeUI`, destination the given
   simulator, derived data `${HQN_DD:-build/dd}`;
4. `scripts/check-share-target.sh` on the built app; `xcrun simctl install` the app and `HQShareProbe.app` on that
   simulator; reads the group folder with
   `xcrun simctl get_app_container <UDID> com.charlesmcdowell.dispatch group.com.charlesmcdowell.dispatch`;
5. `xcodebuild test-without-building -only-testing:HermesHQNativeUITests/ShareEndToEndTests` with
   `TEST_RUNNER_HQN_UI_CREDENTIALS`, `TEST_RUNNER_HQN_SHARE_B`, `TEST_RUNNER_HQN_UI_FIXTURE_URL`,
   `TEST_RUNNER_HQN_SHARE_MEDIA`, `TEST_RUNNER_HQN_SHARE_GROUP` (the group folder), `TEST_RUNNER_HQN_SHARE_FILES`
   (the fixture's `--files` folder), `TEST_RUNNER_HQN_UI_SHOTS`; `HQN_SHARE_ONLY="testS03_…,…"` narrows it;
   `HQN_SHARE_NOUS=1` also starts F3 and runs the Nous test; `HQN_SHARE_REAL_HOSTS=1` runs the Safari/Photos/Files tests;
6. prints the summary (`scripts/e2e-summary.py`), stops only the fixtures it started.

Simulator (builders): `xcrun simctl create "HQN-m9-share" "iPhone 17 Pro" com.apple.CoreSimulator.SimRuntime.iOS-27-0`
(reuse it when it exists); shut it down when the stage ends. Never the scripts' default simulator.

---

## 11. Tests

### 11.1 Unit tests (`Tests/Share/`, in the app's test bundle; they need no gateway)

| File | Covers |
|---|---|
| `ShareRulesTests` | ids, caps, `fits`, `megabytes`, the prompt table of §7.7, `accountKey` (and parity with `GatewayAddress.accountKey` for 20 addresses), `safeName` (parity with `AttachmentStaging.safeName`) |
| `ShareStoreTests` | roster round trip, face files kept and pruned, `clear`, `takeSent` windows, `choice`, undecodable files read as absent, file protection attribute |
| `ShareKeychainTests` | `current(in:)` for the list shape, the build-89 shape, a Nous entry; `replacingCookies` / `replacingNous` compare-and-swap; unknown fields kept; cookie JSON parity with `SavedCookie`; `needsRenewal` parity with `NousTokens` |
| `ShareFailureTests` | every sentence of §7.8, the retryable and blocking sets, RPC wording, no "Dispatch" |
| `ShareReachTests` | tailnet-only addresses, `utun` versus cellular CGNAT, parity with `GatewayAddress.tailnetOnly` / `tailscaleUp`; the transport sentence table |
| `ShareMultipartTests` | bytes equal `MultipartBody.build` for the same input and boundary; the limit; cancellation |
| `ShareMediaTests` | §7.6 checks 1–2 |
| `ShareItemLoaderTests` | §7.6 check 3 |
| `ShareSheetStateTests` | §7.2 check 5, §7.10 check 1 |
| `ShareSenderTests` | a `URLProtocol` stub and a stub socket: call order, exact param keys, opening checks, Tailscale off sends nothing, no redirect, Cancel before each step, one retry on 401, `unconfirmed` on a timeout and on a dropped socket |
| `ShareRosterRowsTests`, `ShareRosterWriterTests` | §7.5 check 1 and 6 |
| `ShareInboxTests` | `openSharedChatIfAny` with a temporary store and a fake opener: opens once, never for another account, never when signed out (and then keeps the note) |

Run: `scripts/build.sh test <UDID of HQN-m9-share>` and `HQ_IDENTITY=original scripts/build.sh test <UDID>`.

### 11.2 Fixture tests (`Tests/Share/ShareFixtureTests.swift`)

Swift Testing suite, `.serialized`, in the shape of `N:Tests/NetIntegrationTests.swift` (`Fixtures` in
`N:Tests/NetTestSupport.swift`). It takes the gateway's address from the `url` field of the credentials file
`build/fixtures/share-it.json` (a stress run names its own with `TEST_RUNNER_HQN_SHARE_IT=share-it-s.json`), refuses a
port outside 9910–9919, and is enabled only when that file exists **and** its port answers (so it can only be a
fixture this stream started; otherwise every test in it is skipped, never failed). One password sign-in per test at
most. Covers §7.3 checks 1, 2, 4, 5, 6; §7.4 checks 3–5; §7.7 check 2; §7.8 checks 3–4; §7.9 checks 2–5.

### 11.3 UI tests (`UITests/share/ShareEndToEndTests.swift`, through `scripts/e2e-share.sh`)

| Test | Proves |
|---|---|
| `testS01_TargetIsOffered` | §7.1 checks 3–4 |
| `testS02_LinkAndMessageToSam` | §7.2 check 4 (shots), §7.3, §7.7 |
| `testS03_PhotoLosesItsLocation` | §7.6 check 4 |
| `testS04_VideoAndBrokenVideo` | §7.6 check 5 |
| `testS05_FileOverTheLimit` | §7.6 check 6 |
| `testS06_BotOrderChoiceAndNoChat` | §7.2 checks 1–3, §7.10 checks 2–3 |
| `testS07_SendsWithoutTheAppThenAppOpensTheChat` | §7.3 check 3, §7.11 checks 2–3 |
| `testS08_RosterFollowsTheApp` | §7.5 checks 2–5 |
| `testS09_BlockedScreens` | §7.8 checks 5–6 |
| `testS10_FailuresAndTryAgain` | §7.8 check 5 (429, Try Again), check 7, §7.11 check 5 |
| `testS11_SessionRenewedByTheShare` | §7.4 check 6 |
| `testS12_OldAndForeignNotes` | §7.11 check 4 |
| `testS13_LargeTypeAndDark` | §7.2 check 4 at `accessibility-extra-extra-extra-large` and in dark |
| `testS14_NousAccountShares` (needs `HQN_SHARE_NOUS=1`) | §7.9 checks 6–7 |
| `testH1_LinkFromSafari`, `testH2_PhotoFromPhotos`, `testH3_FileFromFiles` (need `HQN_SHARE_REAL_HOSTS=1`) | the real apps' hand-off shapes, ported from `W:ios/App/AppUITests/ShareUITests.swift:91-178` |

Every test starts from a clean phone (`-HQDebugResetAccounts YES`) and signs in through the form once. A failed UI
test is rerun once before it is called a failure; no assertion is loosened to make it pass. A row is recorded "done"
only when its checks passed and the screenshots were looked at.

---

## 12. STRESS PLAN

For the stress tester: simulator **"HQN-m9-share-s"**
(`xcrun simctl create "HQN-m9-share-s" "iPhone 17 Pro" com.apple.CoreSimulator.SimRuntime.iOS-27-0`), ports
**9915–9919**, its own derived data. Fixtures as §10.2 on those ports
(`HQN_SHARE_PORT=9915 HQN_SHARE_PORT_B=9919 scripts/e2e-share.sh <UDID>` and the F2/F3 commands on 9916–9918). Record
every number measured; a budget missed twice in a row on a quiet machine is a finding, on a loaded one a note.

### 12.1 Load

| Case | How | Pass |
|---|---|---|
| 10 photos + 10 files in one share | probe with `p01…p10.jpg` and ten 1 MB files | all 20 uploads, 10 `image.attach`, 10 `file.attach`, one prompt with 10 refs; "Uploading 1 of 20…" counts up; no crash |
| 12 photos / 12 files through a mixed share the rule lets through | probe | the sheet shows 10; the 11th and 12th were never read (loader counters) |
| 10 × 48 MP photos | `huge.jpg` ×10 | the extension's footprint stays under 100 MB the whole time (`footprint` on its pid, found through `xcrun simctl spawn <UDID> launchctl list`), "Preparing…" ends |
| One file of exactly 32 MiB, one of 32 MiB + 1 | `exact.bin`, `big.bin` | first is sent, second disables Send; nothing uploaded for the second |
| 262 144 characters of text, and 1 000 000 | probe | the first is sent whole; the second is cut to 262 144; the sheet stays responsive (typing in the message field does not stall) |
| 200-bot roster | `share-roster {"extra":250}` | the app writes 200 rows in under 2 s without blocking scrolling in Bots; the sheet opens and scrolls smoothly; each face decoded once |
| 50 shares in a row | a loop in the UI test | 50 prompts, no leftover folder in the extension's `tmp`, no growth in the group folder beyond the four files |

### 12.2 Speed (budgets on this Mac; rerun before failing)

| Measure | Budget |
|---|---|
| Tap on "Hermes HQ" → the sheet's Send button exists (text share) | ≤ 1.5 s |
| "Preparing…" for 10 phone photos (4032×3024 HEIC) | ≤ 8 s |
| Send → "Sent to …" for a text share on loopback | ≤ 2 s |
| Send → "Sent to …" for 10 photos + 10 small files on loopback | ≤ 20 s |
| App: bots change → `roster.json` on disk | ≤ 1.5 s (0.8 s of it is the debounce) |
| App: `openSharedChatIfAny` on foreground with no note | < 2 ms on the main thread |
| App: roster write of 200 bots, main-thread time (faces already on disk) | < 8 ms |

### 12.3 Bad network (faults from `share-fail` / `share-hold`, or by stopping the tester's own fixture)

| Fault | Expect |
|---|---|
| `/api/auth/me` held 20 s | after 15 s: "Your gateway took too long to answer. It may be busy — try again." + Try Again |
| Fixture stopped before Send | "Can’t reach the computer running Hermes. Check that you’re online and that Tailscale or your VPN is on, then try again." + Try Again; after restarting it with `--keep-credentials`, Try Again ends in the session-ended screen (its sessions died with it) |
| Fixture stopped in the middle of the 5th of 10 uploads | a failure row, no prompt; Try Again after a restart uploads all 10 again into new folders |
| Upload held 130 s | times out at 120 s with the "too long" sentence |
| 401 on upload · 403 on ws-ticket | session-ended screen |
| 413 on upload | "“<name>” is larger than your attachment limit." |
| 429 on `/api/files` · 500 on upload · 503 on ws-ticket | "busy" · "(HTTP 500)" · "(HTTP 503)", each with Try Again |
| 302 on `/api/auth/me` | not followed; the redirect port saw nothing |
| Socket never sends `gateway.ready` | the share goes on after 5 s and succeeds |
| Socket closed right after the upgrade | a transport sentence + Try Again; nothing sent |
| `session.resume` → 4001 · 4009 · −32000 with a 3-line message · with a 500-character line | their sentences; only the first line of a short message is shown |
| `image.attach` → `attached:false` without a message | "Your gateway didn’t accept “<name>”." |
| `file.attach` → no `ref_text` | the same |
| `prompt.submit` taken, socket dropped | not-confirmed row; exactly one prompt on the gateway; the app opens that chat |
| `prompt.submit` held 70 s | not-confirmed at 60 s; the fixture's late answer changes nothing; exactly one prompt |
| Tailnet-only address with Tailscale off | unit level only (no real tailnet host is ever contacted): zero requests, "Turn on Tailscale to reach the computer running Hermes." |

Across all of these: the extension never makes a password sign-in, never more than one retry of `/api/auth/me`, never
more than one token refresh per share (`/__fixture/auth`, `/__fixture/nous` counts).

### 12.4 Bad data

| Data | Expect |
|---|---|
| `roster.json` truncated, empty, `{}`, an array, 5 MB of junk | no crash; the no-roster screen |
| Roster with invalid profiles, 1 000 bots, 10 000-character names, a `session` holding `../`, an `avatar` of `../../x.png` | bad rows cannot receive or are not drawn; no file outside `avatars/` is read; the sheet shows at most what is valid |
| An avatar file that is not an image, or 0 bytes | the initial on the tint colour |
| `choice.json` naming a bot that is gone | the first bot that can receive is chosen |
| `last-sent.json` truncated · with a session `../../etc` · dated tomorrow · dated last week | the app opens nothing and removes the file |
| Keychain JSON: not JSON · `current` naming no account · cookies of the wrong type · a Nous entry missing `userId` · the build-89 shape with a password | signed-out · signed-out · signed-out · signed-out · needs-update (unit tests with the in-memory Keychain) |
| Gateway answers: `/api/files` without `path` · upload without `path` · ws-ticket without `ticket` · HTML instead of JSON | their "refused" sentences; never a crash |
| Shared items: a 0-byte file · a file deleted between the sheet opening and Send · a provider that errors · a HEIC that is really text · a `.mov` that is text · a name of 400 emoji · a name `../../x` · a name with a newline | unreadable rows or a safe name; the rest of the share still sends; nothing is written outside the share's temporary folder |
| A `data:` or `file:` or `javascript:` URL shared as a link | not treated as a link (only http/https); a file URL is a file |
| Text containing `@file:/etc/passwd` or a fake attachment line | sent as plain text, exactly as typed (it is the person's own message) |

### 12.5 Interruption

| Moment | Expect |
|---|---|
| Cancel while "Preparing…" | the loader stops before the next item; the temporary folder is gone |
| Cancel during Connecting / the 3rd upload / Sending | nothing after that step reaches the gateway (no `prompt.submit` unless it had already gone); the sheet closes at once |
| Swipe down while sending | not possible (D15); while idle the sheet closes and cleans up |
| Home, or switching apps, during an upload | the share finishes within the system's grace (D15) or ends; if the prompt had gone the note is written and the app opens that chat; never a duplicate |
| The host app is terminated under the sheet | the extension dies; no prompt unless already sent; its folder is swept by the next sheet after an hour (test with a back-dated folder) |
| The app is terminated during a share | no effect on the share (it never used the app) |
| The app signs out while the sheet is open, then Send | signed-out screen; nothing sent |
| The app switches gateway while the sheet is open, then Send | switched-gateways screen; nothing is sent to either gateway |
| The fixture restarts between "Preparing…" and Send | session-ended (or reach failure), no crash |
| Phone locks with the sheet open (unit: Keychain answers `errSecInteractionNotAllowed`) | "Unlock your iPhone to share." + Try Again |

### 12.6 Relaunch and coming back

| Case | Expect |
|---|---|
| Share, then open the app within 5 min (warm and cold) | that chat, the shared message once, the reply; the chat's status and its VoiceOver label do not stay on "Reconnecting" after catch-up (the old finding) |
| Share to a bot that is mid-reply in the app's last-open chat | the running reply finishes; the share is taken as the next turn (`queued`); no missing or doubled rows after returning |
| Two shares to two bots, then open the app | the second bot's chat (one note, last wins) |
| Share, wait 6 min, open the app | the app is where it was; `last-sent.json` is gone |
| Share on gateway A, switch to B in the app within 5 min | no chat opens for the old share; the note is gone (cleared with the roster) |
| Sign out, sign in again as the same account | the group folder was empty in between; the roster returns within 3 s of the Bots list loading; the remembered choice is gone (expected) |
| Reinstall the app over itself (same build) | the Keychain item, the roster and the sheet still work |
| Update path: a `roster.json` and `choice.json` in build 240's shape (keys `legacy::ivy`, `limitBytes` 8 MB) | read; the choice selects Ivy; the 8 MB limit applies until the app rewrites the roster |

### 12.7 Two processes at once

| Case | Expect |
|---|---|
| App in the foreground refreshing its session while a share renews cookies (fixture test with two clients on one in-memory Keychain, 100 rounds) | the Keychain always holds a pair the gateway accepts; neither side is signed out |
| App and share both renewing a Nous pair (same, 100 rounds, random order) | `replayed` stays 0 when the share reads the Keychain first; where both truly fire at once, record how often a replay happens (the owner's known remaining risk) and that the result is the session-ended screen, never a crash or a loop |
| The share's `session.resume` while the app's socket has that chat live | the app catches up on return (event replay); recorded as a known limit if rows arrive late |

### 12.8 Accessibility and appearance

Run the sheet (states 1–12 of §8) at `xcrun simctl ui <UDID> content_size extra-small`, `large` and
`accessibility-extra-extra-extra-large`, in light and dark (`xcrun simctl ui <UDID> appearance dark`), and with
Increase Contrast and Reduce Transparency on. Pass: no clipped or overlapping text; every row keeps 12–14 pt of
vertical padding; the bot's second line wraps instead of truncating; Cancel and Send stay reachable; the progress
card's text wraps inside it; the blocked sentence is fully readable. VoiceOver pass (by element tree and labels in the
UI test): every control has a label; the chosen bot has the selected trait; a disabled bot reads its reason; "Sent to
<name>" and every failure sentence are announced; faces and decorative glyphs are hidden. Reduce Motion: the card
only fades. Restore every simulator setting afterwards.

### 12.9 Clean-up

Stop every fixture started (by pid), shut down "HQN-m9-share-s", leave no listener on 9915–9919, restore the
simulator's content size and appearance.

---

## 13. Build order (one feature at a time)

1. **Spike, before anything else:** an original-identity simulator build with an empty `HermesHQShare` that (a) reads
   the app's Keychain item and (b) reads a file the app wrote in the App Group folder. If the Simulator refuses the
   Keychain read with these entitlements, add `CODE_SIGN_ENTITLEMENTS[sdk=iphonesimulator*]` variants for the app and
   the extension that both name one explicit simulator-only Keychain group (the reference's `ShareSimulator.entitlements`
   approach, `W:docs/share-extension.md:33`); **device entitlements stay exactly as §4.3**, and
   `check-share-target.sh` asserts it.
2. ShareKit models, store, rules, failures + unit tests.
3. App side: roster rows, writer, clear hooks (R5) + tests; then `openSharedChatIfAny` (R11).
4. Keychain reading and compare-and-swap (R4) + tests.
5. The fixture; `ShareSender` and `ShareSocket` (R3, R7, R8, R9) + fixture tests.
6. `ShareMedia`, `ShareItemLoader` (R6) + tests.
7. The extension target, the sheet (R1, R2, R10), the probe, `e2e-share.sh`, the UI tests.
8. `ship.py` profile line, `check-share-target.sh`, `docs/ARCHITECTURE.md` section "Share extension (m9/share)".

Never edit `docs/parity-240.md` or `docs/parity.md`; record outcomes in `docs/briefs/m9/share-rows.md`.

---

## 14. Known limits and risks

* **Simulator Keychain sharing** between an ad-hoc-signed app and extension is unproven here (step 1 of §13).
* **Archive signing.** Automatic signing must find or make a development profile for `.share` with the App Group;
  the group and App ID exist, but the owner's note says API-key signing cannot *create* groups. The export needs the
  `DispatchShare` App Store profile (UUID `<PROFILE_UUID>`, expires 2027-09-25), which `ship.py`
  installs where Xcode looks. A Ship agent's concern; builders never run it.
* **Both processes renewing a Nous pair at the same instant** could replay a refresh token (§7.9, §12.7).
  **DECISION (n20 B16, ported 2026-10-31):** a renewal takes a lease first — a small file in the App Group made with
  `O_EXCL` (`ShareKit/NousRenewalLease.swift`; no file lock is held, so a suspended app is never ended for holding
  one). The other process waits (at most 16 s) for the holder's rotated pair to reach the Keychain and uses it
  instead of sending its own refresh token; a lease older than 20 s (its holder died mid-renewal) is taken over
  rather than waited on forever. If Portal still refuses the share's renewal (400/401/403), the share re-reads the
  Keychain and uses the app's newer pair when there is one, instead of failing the share. A renewal the app holds off
  because the phone is locked (§22 of spec 01) never takes or waits on the lease, so the share can renew in the
  meantime; once unlocked, the app waits for the share's lease as usual. Checks: unit `NousRenewalLeaseTests`,
  `ShareRenewalRaceTests`, `LockedRenewalWithShareTests`, `theAppWaitsForTheShareExtensionsRenewal`
  (`NetConcurrencyTests.swift`). Two real processes racing on a phone are not tried here — see the share owner-todo.
* **A chat streaming in the app** when the share resumes the same session may miss events until it catches up
  (`W:docs/share-extension.md:90`).
* **The system share sheet in UI tests** is Apple's UI: element names can change between iOS versions, and a freshly
  installed extension sometimes appears only under More.
* **Extension memory** (~120 MB): held down by reading one provider at a time; 10 very large photos are the test.
* **Things only a real iPhone proves**: the Keychain group under real signing, Tailscale off, sharing from Photos,
  Safari and Files (`docs/owner-todo/share.md`).
* Only this gateway's own bots are offered; a bot needs its Bot Chat first; a failed share is never queued (D17).

---

## 15. Owner todo

Nothing on the push relay, the plugins or the real gateway. The portal work is done: the profile in the signing
folder (read only, decoded for this spec) is "Dispatch Share Internal TestFlight 2026-10-03", application identifier
`2Y6UGK7GET.com.charlesmcdowell.dispatch.share`, App Group `group.com.charlesmcdowell.dispatch`, Keychain groups
`2Y6UGK7GET.*`. `docs/owner-todo/share.md` lists the short phone check for the first TestFlight build that carries the
extension.
