// DEBUG hooks for Siri, Shortcuts and the quick actions (docs/spec/3x-intents.md §12.3). The simulator has no Action
// Button and Siri there is not dependable, so these run the REAL intent types and the real quick-action path, and
// write what happened where a test can read it. Compiled out of Release.
//
// Launch arguments (cold launch; each also works as the last part of `<scheme>://debug-intent/<word>` on a running app,
// e.g. `xcrun simctl openurl <udid> "hermeshq-native://debug-intent/voice-note:ivy"`):
// - `-HQDebugIntent voice-note:<profile>`           perform `RecordVoiceNoteIntent` with an entity MADE for that profile
//                                                   (its own catalog lookup is what runs)
// - `-HQDebugIntent legacy-memo:<profile>`          `DispatchMemoIntent`, entity id `epoch + ":bot:" + key`
//   `legacy-memo-stale:<profile>`                   the same with an epoch from an earlier sign-in
// - `-HQDebugIntent open-bot:<profile>`             `DispatchOpenBotIntent`
// - `-HQDebugIntent voice-note-foreign:<profile>`   a request whose account is "http://other.invalid\nsomeone"
// - `-HQDebugIntent voice-note-request:<profile>`   a request for the signed-in account without consulting the catalog
// - `-HQDebugQuickAction memo | open:<0|1> | search | stale`   the matching current Home Screen item through
//                                                   `QuickActions.perform` (`stale`: the first item, wrong epoch);
//                                                   URL form `quick:<word>`
// - `-HQDebugVoiceNote seed-pending:<profile>`      a 4 s synthetic WAV under Application Support/HermesAttachments and
//   `seed-pending-foreign:` / `seed-pending-missing:`  a matching saved older-build note (another account / no file)
// - `-HQDebugContinueChat <stored id>`              `continueConversation(id)`; URL form `continue:<id>`
// - URL only: `local-alert:<profile>`               the real `NotificationHub.post` for that bot's chat (the donation)
// - URL only: `sign-out`                            `AppModel.signOut()`, as the Account screen's button
// - URL only: `look:dark | light | system`          every window in that appearance now (screenshots; no event)
// - URL only: `burst:<count>:<gap ms>:<word>[,<word>…]`   the words in turn, `count` runs in all, `gap` apart: a
//                                                   shortcut pressed over and over (ends with the event "burst done")
// - `-HQDebugResetIntents YES`                      clear the six stored values and the Home Screen items before launch
// - `-HQDebugQuietShortcutParameters YES`           count parameter refreshes ("parameters refreshed") without calling
//                                                   the system, which rations them (read in `IntentsCatalogSync`)
// - `-HQDebugIntentsOut <folder>`                   rewrite `<folder>/intents-state.json` on every change (`events`
//                                                   in order, `times` beside them in ms since 1970)

#if DEBUG
import AppIntents
import UIKit

@MainActor enum IntentsDebugHooks {
    private static var defaults: UserDefaults { .standard }
    private static var folder: String? { defaults.string(forKey: "HQDebugIntentsOut").flatMap { $0.isEmpty ? nil : $0 } }
    private static var events: [String] = []
    /// When each event was recorded (ms since 1970), in step with `events`: the tests time a flow by them.
    private static var times: [Double] = []
    private static var donations: [[String: String]] = []
    private static var parameterRefreshes = 0
    private static var writeQueued = false
    private static var timer: Timer?
    private static weak var model: AppModel?

    private static func argument(_ name: String) -> String? { defaults.string(forKey: name).flatMap { $0.isEmpty ? nil : $0 } }

    /// A launch that was asked to open something through a hook does not reopen the last chat over it.
    static var claimsLaunch: Bool {
        ["HQDebugIntent", "HQDebugQuickAction", "HQDebugVoiceNote", "HQDebugContinueChat"].contains { argument($0) != nil }
    }

    /// What `persist-hooks` keeps for a launch without arguments.
    private static let persisted = ["HQDebugIntentsOut", "HQDebugMemoFixture", "HQDebugQuietShortcutParameters"]

    /// Before the scene builds anything.
    static func applyBeforeLaunch() {
        if defaults.bool(forKey: "HQDebugResetIntents") {
            for key in persisted { UserDefaults.standard.removeObject(forKey: key) }   // (an argument still applies)
            for key in [VoiceBotCatalog.botsKey, VoiceNoteRequestStore.storageKey, VoiceBotCatalog.pendingKey, ShortcutPolicy.catalogKey,
                        ShortcutPolicy.accountKey, ShortcutPolicy.epochKey, IntentsRuntime.foreignNoteSaidKey] { defaults.removeObject(forKey: key) }
            UIApplication.shared.shortcutItems = []
        }
        guard folder != nil else { return }
        IntentsEvents.sink = { record($0) }
        IntentsRuntime.shared.onEvent = { record($0) }
        // What changes without an event (a request's minute passing) still reaches the file.
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in Task { @MainActor in write() } }
        write()
    }

    /// As the scene connects (before the saved sign-in is restored).
    static func sceneConnected(model: AppModel) {
        self.model = model
        if let word = argument("HQDebugVoiceNote") { run(word) }
        if let word = argument("HQDebugIntent") { run(word) }
        if let word = argument("HQDebugQuickAction") { run("quick:" + word) }
        if let id = argument("HQDebugContinueChat") { run("continue:" + id) }
        // The order a real cold launch can take: the system performs the intent after the scene connected, so nothing
        // told the scene (this argument does not claim the launch). `-HQDebugLateIntentDelay <seconds>` (default 0:
        // the next turn of the main thread, before the saved sign-in is back).
        if let word = argument("HQDebugLateIntent") {
            let delay = Double(argument("HQDebugLateIntentDelay") ?? "") ?? 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { run(word) }
        }
    }

    /// `<scheme>://debug-intent/<word>` on a running app.
    static func handle(_ url: URL, model: AppModel?) -> Bool {
        guard url.scheme?.lowercased() == AppIdentity.current.urlScheme, url.host() == "debug-intent" else { return false }
        if let model { self.model = model }
        let word = String(url.path(percentEncoded: false).drop(while: { $0 == "/" }))
        if !word.isEmpty { run(word) }
        return true
    }

    // MARK: Words

    private static func run(_ word: String) {
        let parts = word.split(separator: ":", maxSplits: 1).map(String.init)
        let name = parts.first ?? "", value = parts.count > 1 ? parts[1] : ""
        if name == "look" {
            // Screenshots: every window in dark or light now, whatever the simulator's setting. Leaves no event.
            for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                for window in scene.windows {
                    window.overrideUserInterfaceStyle = Theme.shared.style(for: value == "dark" ? .dark : value == "light" ? .light : AppearanceSetting.current.style)
                }
            }
            return
        }
        if name == "persist-hooks" {
            // A launch the system makes itself (the App Shortcut tapped in the Shortcuts app with the app not running)
            // carries no arguments: the state file's folder and the fixture recorder are kept for it. Leaves no event.
            for key in persisted { UserDefaults.standard.set(defaults.string(forKey: key), forKey: key) }
            return
        }
        record("hook " + word)
        switch name {
        case "voice-note":
            let account = knownAccount ?? ""
            let key = VoiceBotCatalog.key(profile: value)
            let intent = RecordVoiceNoteIntent()
            intent.bot = VoiceNoteBot(id: VoiceBotCatalog.id(account: account, key: key), name: value, key: key, account: account)
            Task { do { _ = try await intent.perform() } catch { record("error " + describe(error)) } }
        case "legacy-memo", "legacy-memo-stale", "open-bot":
            let epoch = name == "legacy-memo-stale" ? "an-earlier-sign-in" : (ShortcutPolicy.epoch() ?? "")
            let entity = DispatchBotEntity(id: epoch + ":bot:" + VoiceBotCatalog.key(profile: value), name: value)
            if name == "open-bot" {
                let intent = DispatchOpenBotIntent()
                intent.bot = entity
                Task { do { _ = try await intent.perform() } catch { record("error " + describe(error)) } }
            } else {
                let intent = DispatchMemoIntent()
                intent.bot = entity
                Task { do { _ = try await intent.perform() } catch { record("error " + describe(error)) } }
            }
        case "voice-note-foreign":
            VoiceNoteRequestStore(defaults: .standard).enqueue(account: "http://other.invalid\nsomeone", key: VoiceBotCatalog.key(profile: value),
                                                               name: displayName(value))
            IntentsRuntime.shared.kick()
        case "voice-note-request":
            VoiceNoteRequestStore(defaults: .standard).enqueue(account: knownAccount ?? "", key: VoiceBotCatalog.key(profile: value),
                                                               name: displayName(value))
            IntentsRuntime.shared.kick()
        case "quick":
            quickAction(value)
        case "seed-pending", "seed-pending-foreign", "seed-pending-missing":
            seed(profile: value, foreign: name == "seed-pending-foreign", missing: name == "seed-pending-missing")
        case "continue":
            model?.continueConversation(value)
            if !NotificationRules.valid(value) { record("continue refused") }
        case "local-alert":
            guard let model, let bot = model.bots.first(where: { $0.id == value }), let stored = bot.canonicalSessionId else {
                record("error no chat for " + value)
                return
            }
            Task {
                let posted = await NotificationHub.shared.post(kind: "message.complete", session: stored, text: "Synthetic reply")
                record("local alert " + (posted ? "posted" : "not posted"))
            }
        case "sign-out":
            model?.signOut()
        case "burst":
            let parts = value.split(separator: ":", maxSplits: 2).map(String.init)
            let words = parts.count == 3 ? parts[2].split(separator: ",").map(String.init) : []
            guard parts.count == 3, let count = Int(parts[0]), let gap = Int(parts[1]), (1...200).contains(count), gap >= 0, !words.isEmpty,
                  !words.contains(where: { $0.hasPrefix("burst") }) else {
                record("error bad burst " + value)
                return
            }
            Task {
                for index in 0..<count {
                    run(words[index % words.count])
                    try? await Task.sleep(for: .milliseconds(gap))
                }
                record("burst done")
            }
        default:
            record("error unknown hook " + word)
        }
    }

    /// The account the hooks make ids for: the signed-in one, else the one the stored catalog belongs to, else the one
    /// this launch signs in with (`HQN_SIGNIN_*`).
    private static var knownAccount: String? {
        if let account = model?.intentsAccount { return account }
        if let account = VoiceBotCatalog.bots().first?.account { return account }
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HQN_SIGNIN_URL"], let username = env["HQN_SIGNIN_USERNAME"] else { return nil }
        return VoiceBotCatalog.account(url: (try? GatewayAddress.validated(url).absoluteString) ?? url, username: username)
    }

    private static func displayName(_ profile: String) -> String {
        VoiceBotCatalog.bots().first { $0.key == VoiceBotCatalog.key(profile: profile) }?.name
            ?? (profile == "default" ? "Hermes" : profile.prefix(1).uppercased() + profile.dropFirst())
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    private static func quickAction(_ word: String) {
        let items = UIApplication.shared.shortcutItems ?? []
        let item: UIApplicationShortcutItem?
        switch word {
        case "memo": item = items.first { $0.type == "dispatch.memo" }
        case "search": item = items.first { $0.type == "dispatch.search" }
        case "open:0", "open:1":
            let opens = items.filter { $0.type == "dispatch.open" }
            let index = word == "open:0" ? 0 : 1
            item = index < opens.count ? opens[index] : nil
        case "stale":
            item = items.first.map { first in
                UIApplicationShortcutItem(type: first.type, localizedTitle: first.localizedTitle, localizedSubtitle: nil, icon: nil,
                                          userInfo: ["id": (first.userInfo?["id"] as? String ?? "") as NSString,
                                                     "epoch": "an-earlier-sign-in" as NSString])
            }
        default: item = nil
        }
        guard let item else {
            record("quick action missing " + word)
            return
        }
        record("quick action result " + (QuickActions.perform(item) ? "true" : "false"))
    }

    // MARK: A saved older-build note

    private static func seed(profile: String, foreign: Bool, missing: Bool) {
        let account = foreign ? "http://other.invalid\nsomeone" : (knownAccount ?? "")
        let key = VoiceBotCatalog.key(profile: profile)
        let folder = LegacyNoteFile.roots[0].appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let file = folder.appending(path: "Voice note.wav")
        if !missing {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? syntheticWAV(seconds: 4).write(to: file)
        }
        let note = PendingVoiceNote(id: UUID().uuidString,
                                    bot: VoiceBotRecord(id: VoiceBotCatalog.id(account: account, key: key), name: displayName(profile),
                                                        key: key, account: account),
                                    path: file.path)
        defaults.set(try? JSONEncoder().encode(note), forKey: VoiceBotCatalog.pendingKey)
        record("seeded " + file.path)
        IntentsRuntime.shared.kick()
    }

    /// 16-bit mono PCM at 16 kHz: a tone that swells and fades, so the waveform has a shape.
    private static func syntheticWAV(seconds: Double) -> Data {
        let rate = 16_000, frames = Int(seconds * Double(rate))
        var samples = Data(capacity: frames * 2)
        for frame in 0..<frames {
            let t = Double(frame) / Double(rate)
            let envelope = 0.15 + 0.75 * abs(sin(t * 2.1))
            let value = Int16(max(-1, min(1, sin(t * 2 * .pi * 330) * envelope)) * 30_000)
            withUnsafeBytes(of: value.littleEndian) { samples.append(contentsOf: $0) }
        }
        var data = Data()
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append32(UInt32(36 + samples.count)); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append32(16); append16(1); append16(1); append32(UInt32(rate))
        append32(UInt32(rate * 2)); append16(2); append16(16)
        data.append(contentsOf: Array("data".utf8)); append32(UInt32(samples.count)); data.append(samples)
        return data
    }

    // MARK: The state file

    private static func record(_ event: String) {
        var event = event
        // Which bots, in which order, each write stored (a test can tell a rename from a reorder).
        if event.hasPrefix("catalog ") { event += ": " + VoiceBotCatalog.bots(defaults).map(\.name).joined(separator: ", ") }
        if event == "parameters refreshed" { parameterRefreshes += 1 }
        if event == "signed out" { donations = [] }
        if event.hasPrefix("donation ") {
            let parts = event.split(separator: " ").map(String.init)
            if parts.count >= 3 { donations.append(["conversation": parts[1], "result": parts[2...].joined(separator: " ")]) }
        }
        events.append(event)
        times.append((Date().timeIntervalSince1970 * 1000).rounded())
        if events.count > 1500 {
            times.removeFirst(events.count - 1500)
            events.removeFirst(events.count - 1500)
        }
        guard folder != nil, !writeQueued else { return }
        writeQueued = true
        DispatchQueue.main.async {
            writeQueued = false
            write()
        }
    }

    private static var lastWritten: Data?

    private static func write() {
        guard let folder else { return }
        let request = VoiceNoteRequestStore(defaults: .standard).pending
        var state: [String: Any] = [
            "catalog": VoiceBotCatalog.bots().map { ["id": $0.id, "name": $0.name, "key": $0.key] },
            "request": request.map { ["id": $0.id, "account": $0.account, "key": $0.key, "name": $0.name, "expiresAt": $0.expiresAt] as [String: Any] } ?? NSNull(),
            "pendingNote": defaults.object(forKey: VoiceBotCatalog.pendingKey) != nil,
            "epoch": ShortcutPolicy.epoch() ?? "",
            "quickActions": (UIApplication.shared.shortcutItems ?? []).map { item in
                ["type": item.type, "title": item.localizedTitle,
                 "symbol": QuickActions.shown.first { $0.type == item.type && $0.title == item.localizedTitle }?.symbol ?? ""]
            },
            "targets": ShortcutPolicy.targets().map { ["id": $0.id, "name": $0.name, "kind": $0.kind] },
            "parameterRefreshes": parameterRefreshes,
            "donations": donations,
            "events": events,
            "times": times,
            "busy": IntentsRuntime.shared.busy,
            "account": model?.intentsAccount ?? ""
        ]
        if let pending = VoiceBotCatalog.pendingNote() { state["pendingNotePath"] = pending.path }
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]), data != lastWritten else { return }
        lastWritten = data
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: folder).appending(path: "intents-state.json"), options: .atomic)
    }
}
#endif
