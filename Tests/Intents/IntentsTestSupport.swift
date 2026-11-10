// Stand-ins for the Siri, Shortcuts and quick-actions tests (docs/spec/3x-intents.md §13): a private UserDefaults
// suite per test, and the app as the runtime sees it (`IntentsHost`), with a clock the test moves.

import Foundation
@testable import HermesHQNative

/// A UserDefaults suite of this test's own, removed when the box goes.
nonisolated final class IntentsDefaults {
    let name = "hqn.intents.tests." + UUID().uuidString
    let defaults: UserDefaults

    init() { defaults = UserDefaults(suiteName: name) ?? .standard }
    deinit { defaults.removePersistentDomain(forName: name) }
}

enum IntentsFixture {
    static let url = "https://fixture.invalid"
    static let username = "qa"
    static let account = VoiceBotCatalog.account(url: url, username: username)

    static func bot(_ id: String, name: String? = nil, chat: String? = nil, active: Double? = nil, hidden: Bool = false) -> Bot {
        Bot(id: id, name: name ?? (id == "default" ? "Hermes" : id.capitalized), role: nil, preview: nil,
            lastActive: active.map { Date(timeIntervalSince1970: $0) }, isWorking: false, unread: false, pinned: false, pinOrder: nil,
            sectionName: nil, hidden: hidden, canonicalSessionId: chat, head: nil)
    }

    static func session(_ id: String, title: String = "Notes", active: Double? = nil, archived: Bool = false) -> SessionSummary {
        var row = SessionSummary(id: id, profile: "default", title: title, preview: nil, lastActive: active.map { Date(timeIntervalSince1970: $0) },
                                 source: nil, unread: false, isRunning: false)
        row.archived = archived
        return row
    }

    static func record(_ profile: String, name: String? = nil, account: String = IntentsFixture.account) -> VoiceBotRecord {
        let key = VoiceBotCatalog.key(profile: profile)
        return VoiceBotRecord(id: VoiceBotCatalog.id(account: account, key: key), name: name ?? profile.capitalized, key: key, account: account)
    }

    /// A folder of this test's own, laid out like an app container's `Library`.
    static func container() -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "hqn-intents-" + UUID().uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath()
    }
}

@MainActor final class FakeIntentsChat: IntentsChat {
    var botKey: String?
    var isTop = true
    /// The composer is ready once the host's clock reaches this (ms); nil: never.
    var readyAt: Double? = 0
    var scope: String
    private(set) var memos = 0
    unowned let host: FakeIntentsHost

    init(key: String?, host: FakeIntentsHost) {
        botKey = key
        scope = "scope:" + (key ?? "none")
        self.host = host
    }

    var composerReady: Bool { readyAt.map { host.clock >= $0 } ?? false }

    func beginHandsFreeMemo() {
        memos += 1
        host.take = (botKey, true)
        host.log.append("memo " + (botKey ?? "none"))
    }
}

@MainActor final class FakeIntentsHost: IntentsHost {
    var account: String? = IntentsFixture.account
    var isActive = true
    /// nil: in front exactly when active.
    var foreground: Bool?
    var isForeground: Bool { foreground ?? isActive }
    var restoreCancels = 0
    func cancelLaunchRestore() { restoreCancels += 1 }
    var isReady = true
    var rosterLoaded = true
    var roster: [Bot] = [IntentsFixture.bot("default"), IntentsFixture.bot("ivy")]
    /// What a roster read brings (nil: the read fails and the roster stays).
    var refreshed: [Bot]?
    var take: (key: String?, active: Bool) = (nil, false)
    var clock: Double = 1_000_000
    /// How long opening a bot's chat takes (ms of this host's clock).
    var openDelay = 0
    /// The chat that comes on top when `openBotChat` is asked for a bot, when it is not that bot's own.
    var opensKey: [String: String] = [:]
    /// A chat's composer is ready this long after it opened (ms); nil: never.
    var readyAfter: Double? = 0
    var failOpen = false
    /// A sheet holding unsaved edits is up and the owner keeps it when asked (UX study #263).
    var keepSheet = false
    /// Run when a chat open begins (a test replaces the request or moves away here).
    var onOpen: (() -> Void)?
    var onSleep: (() -> Void)?
    /// Run as a roster read begins (a test signs out here).
    var onRefresh: (() -> Void)?
    var chats: [FakeIntentsChat] = []
    var log: [String] = []
    var notices: [IntentsNoticeContent] = []
    var showing: IntentsNoticeContent?
    var refreshes = 0
    var catalogSyncs = 0

    // The saved note.
    var files: [String: URL] = [:]
    var importResult: MemoFile? = MemoFile(path: "/memo/imported.wav", seconds: 4, peaks: [], mime: "audio/wav")
    var drafts: [String: MemoFile] = [:]
    var draftFails = false
    var discarded: [MemoFile] = []
    var deleted: [URL] = []
    var onImport: (() -> Void)?

    // Quick actions.
    var sessions: [String: String] = [:]
    var sessionOpens: [String] = []
    var sessionOpen = IntentsSessionOpen.opened
    var searches = 0

    func bot(forKey key: String) -> Bot? {
        guard let profile = VoiceBotCatalog.profile(key: key) else { return nil }
        return roster.first { $0.id == profile }
    }

    func refreshRoster() async {
        refreshes += 1
        onRefresh?()
        if let refreshed { roster = refreshed }
        rosterLoaded = true
    }

    func syncCatalog() { catalogSyncs += 1 }

    func openBotChat(_ bot: Bot) async throws -> (any IntentsChat)? {
        log.append("open " + bot.id)
        if keepSheet { throw IntentsKept() }
        onOpen?()
        // In steps, as a real open takes many turns of the main thread.
        for _ in 0..<(openDelay / 100) { await sleep(ms: 100) }
        if failOpen { return nil }
        let own = VoiceBotCatalog.key(profile: bot.id)
        let chat = FakeIntentsChat(key: opensKey[bot.id] ?? own, host: self)
        chat.readyAt = readyAfter.map { clock + $0 }
        for other in chats { other.isTop = false }
        chats.append(chat)
        return chat
    }

    var takeInProgress: (key: String?, active: Bool) { take }
    func now() -> Double { clock }

    func sleep(ms: Int) async {
        clock += Double(ms)
        onSleep?()
        await Task.yield()
    }

    func show(_ notice: IntentsNoticeContent) {
        notices.append(notice)
        showing = notice
    }

    func dismissNotice() { showing = nil }
    func isShowing(_ notice: IntentsNoticeContent) -> Bool { showing == notice }

    func noteFile(_ path: String) -> URL? { files[path] }

    func importNote(_ file: URL) async -> MemoFile? {
        onImport?()
        return importResult
    }

    func setDraft(_ memo: MemoFile, scope: String) -> Bool {
        if draftFails { return false }
        drafts[scope] = memo
        return true
    }

    func discard(_ memo: MemoFile) { discarded.append(memo) }
    func delete(_ file: URL) { deleted.append(file) }

    func sessionProfile(_ stored: String) -> String? { sessions[stored] }

    func openSessionChat(stored: String, profile: String) async -> IntentsSessionOpen {
        sessionOpens.append(stored)
        return sessionOpen
    }

    /// Group chats this gateway has, by room key, and the ones a quick action opened.
    var rooms: Set<String> = []
    var roomOpens: [String] = []

    func openRoom(_ key: String) async -> IntentsSessionOpen {
        guard rooms.contains(key) else { return .gone }
        if keepSheet { return .kept }
        roomOpens.append(key)
        return .opened
    }

    func openSearch() { searches += 1 }

    /// Every memo started, by bot key.
    var memos: [String] { log.filter { $0.hasPrefix("memo ") }.map { String($0.dropFirst(5)) } }
    var opens: [String] { log.filter { $0.hasPrefix("open ") }.map { String($0.dropFirst(5)) } }
    var messages: [String] { notices.map { $0.message ?? $0.title } }
}

/// A runtime over a fake host and a private store, with what it reported.
@MainActor final class IntentsRig {
    let box = IntentsDefaults()
    let host = FakeIntentsHost()
    let store: VoiceNoteRequestStore
    let runtime: IntentsRuntime
    var events: [String] = []

    init() {
        let host = host
        store = VoiceNoteRequestStore(defaults: box.defaults, now: { host.clock })
        runtime = IntentsRuntime(store: store, defaults: box.defaults, host: host)
        runtime.onEvent = { [weak self] in self?.events.append($0) }
    }

    var defaults: UserDefaults { box.defaults }

    @discardableResult func request(_ profile: String, account: String = IntentsFixture.account, name: String? = nil) -> VoiceNoteRequest {
        store.enqueue(account: account, key: VoiceBotCatalog.key(profile: profile), name: name ?? profile.capitalized)
    }

    /// Stores a saved older-build note for `profile` whose recording the host can find at `file`.
    @discardableResult func saveNote(_ profile: String, account: String = IntentsFixture.account, file: URL? = URL(fileURLWithPath: "/notes/a.wav")) -> PendingVoiceNote {
        let path = "/old/Library/Application Support/HermesAttachments/A/Voice note.wav"
        let note = PendingVoiceNote(id: UUID().uuidString, bot: IntentsFixture.record(profile, account: account), path: path)
        defaults.set(try? JSONEncoder().encode(note), forKey: VoiceBotCatalog.pendingKey)
        if let file { host.files[path] = file }
        return note
    }

    /// Lets queued follow-up tasks (a second delivery, a tapped button) run to the end.
    func settle() async {
        var idle = 0
        for _ in 0..<5000 where idle < 25 {
            await Task.yield()
            if runtime.busy {
                idle = 0
            } else {
                idle += 1
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
    }
}
