// More › Bot Profiles (docs/spec/3x-morepages.md §10): the wire (`AG/hermes_cli/web_routers/profiles.py`), the name
// rule, the SOUL.md draft kept in Caches while an edit is open, and the pure rules of the editor (what the bar shows,
// whether a kept draft is offered back, whether the file changed on the gateway).

import CryptoKit
import Foundation

// MARK: - Wire

/// One row of `GET /api/profiles`. Decoded leniently: every key optional, a number may come as a string.
nonisolated struct ProfileRow: Identifiable, Hashable, Sendable {
    var name: String
    var path: String?
    var isDefault: Bool
    var model: String?
    var provider: String?
    var skillCount: Int
    /// `display_name`, else `bot_title` (the roster's title wins on screen when the bot is listed).
    var displayName: String?

    var id: String { name }

    /// nil for a row without a usable name (skipped).
    init?(_ json: JSONValue) {
        guard json.object != nil, let raw = json["name"]?.string else { return nil }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        self.name = name
        path = Self.text(json["path"])
        isDefault = json["is_default"]?.bool ?? (name == "default")
        if name == "default" { isDefault = true }
        model = Self.text(json["model"])
        provider = Self.text(json["provider"])
        skillCount = max(0, json["skill_count"]?.int ?? 0)
        displayName = Self.text(json["display_name"]) ?? Self.text(json["bot_title"])
    }

    init(name: String, path: String? = nil, isDefault: Bool = false, model: String? = nil, provider: String? = nil,
         skillCount: Int = 0, displayName: String? = nil) {
        self.name = name; self.path = path; self.isDefault = isDefault; self.model = model; self.provider = provider
        self.skillCount = skillCount; self.displayName = displayName
    }

    private static func text(_ value: JSONValue?) -> String? {
        guard let text = value?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// `{"profiles":[…]}` (or a bare array): bad rows skipped, a repeated name kept once, the default profile first,
    /// the gateway's order otherwise.
    static func rows(from json: JSONValue) -> [ProfileRow] {
        let list = json["profiles"]?.array ?? json.array ?? []
        var seen = Set<String>()
        let rows = list.compactMap(ProfileRow.init).filter { seen.insert($0.name).inserted }
        return rows.filter(\.isDefault) + rows.filter { !$0.isDefault }
    }
}

/// `GET /api/profiles/<name>/soul`.
nonisolated struct SoulDocument: Equatable, Sendable {
    var content: String
    var exists: Bool

    init(content: String, exists: Bool) { self.content = content; self.exists = exists }

    init(_ json: JSONValue) {
        content = json["content"]?.string ?? ""
        exists = json["exists"]?.bool ?? !content.isEmpty
    }
}

nonisolated struct ProfileRenamed: Equatable, Sendable {
    var name: String
    var path: String?
}

nonisolated struct ProfilesAPI: Sendable {
    let client: any GatewayClient

    static func path(_ name: String) -> String { "/api/profiles/" + PagesREST.segment(name) }

    func list() async throws -> [ProfileRow] {
        let rows = try await Self.decodeRows(PagesREST.json(client, "GET", "/api/profiles"))
        AppLog.trace("pages", "profiles list: \(rows.count)")
        return rows
    }

    @concurrent
    private static func decodeRows(_ json: JSONValue) async throws -> [ProfileRow] {
        guard json["profiles"]?.array != nil || json.array != nil else { throw ProfilesFailure.unreadable }
        return ProfileRow.rows(from: json)
    }

    func soul(_ name: String) async throws -> SoulDocument {
        let json = try await PagesREST.json(client, "GET", Self.path(name) + "/soul")
        guard json.object != nil else { throw ProfilesFailure.unreadable }
        return SoulDocument(json)
    }

    /// `PUT …/soul {"content"}`. A large file may take a while on a slow link: two minutes.
    func saveSoul(_ name: String, content: String) async throws {
        let start = ContinuousClock.now
        do {
            _ = try await PagesREST.send(client, "PUT", Self.path(name) + "/soul", json: ["content": .string(content)], timeout: 120)
            AppLog.trace("config", "soul save \(AppLog.tag(name)) ok in \(AppLog.ms(since: start)) ms, \(content.utf8.count) bytes")
        } catch {
            AppLog.note("config", "soul save \(AppLog.tag(name)) failed after \(AppLog.ms(since: start)) ms: \(PagesREST.reason(error))")
            throw error
        }
    }

    /// `PATCH /api/profiles/<name> {"new_name"}`. Hermes stops the profile's gateway first (up to 10 s): a minute.
    func rename(_ name: String, to newName: String) async throws -> ProfileRenamed {
        let start = ContinuousClock.now
        do {
            let json = try await PagesREST.json(client, "PATCH", Self.path(name), json: ["new_name": .string(newName)], timeout: 60)
            let answered = json["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            AppLog.trace("config", "profile rename \(AppLog.tag(name)) ok in \(AppLog.ms(since: start)) ms")
            return ProfileRenamed(name: answered.isEmpty ? newName : answered, path: json["path"]?.string)
        } catch {
            AppLog.note("config", "profile rename \(AppLog.tag(name)) failed after \(AppLog.ms(since: start)) ms: \(PagesREST.reason(error))")
            throw error
        }
    }
}

nonisolated enum ProfilesFailure: Error, LocalizedError {
    case unreadable
    var errorDescription: String? { "Your gateway’s answer couldn’t be read." }
}

// MARK: - Names

nonisolated enum ProfileName {
    /// `V/i18n/en.ts` profiles.nameHint.
    static let hint = "Lowercase letters, digits, hyphens, and underscores. Must start with a letter or digit."
    static let taken = "A profile with that name already exists."
    static let maxLength = 64

    /// `^[a-z0-9][a-z0-9_-]*$` (ASCII only: "é" and "١" are not letters or digits here).
    static func isValid(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.count <= maxLength else { return false }
        func lead(_ s: Unicode.Scalar) -> Bool { (s >= "a" && s <= "z") || (s >= "0" && s <= "9") }
        return lead(first) && name.unicodeScalars.allSatisfy { lead($0) || $0 == "_" || $0 == "-" }
    }

    enum Check: Equatable { case ok, unchanged, invalid, taken }

    /// What the Rename prompt makes of the typed name (not trimmed: a space is an invalid character, as on the web).
    static func check(_ typed: String, current: String, existing: [String]) -> Check {
        if typed == current { return .unchanged }
        guard isValid(typed), typed != "default" else { return .invalid }
        return existing.contains(typed) ? .taken : .ok
    }

    /// "Couldn’t Rename"'s reason: the gateway's own words, else the taken-name sentence for a 400 / 409.
    static func renameReason(_ error: Error) -> String {
        if let http = error as? HTTPError {
            if let detail = PagesREST.detail(http) { return detail }
            if http.status == 409 || http.status == 400 { return taken }
        }
        return PagesREST.reason(error)
    }

    /// "1 profile" / "N profiles" (`V/i18n/en.ts` profiles.count).
    static func count(_ n: Int) -> String { n == 1 ? "1 profile" : "\(n) profiles" }
}

// MARK: - The SOUL.md draft

/// What was being typed when the app went away: kept in `Caches/pages/soul-draft-<account>-<profile>.txt`, written on
/// every pause in typing, removed on Save and on Discard. The text never goes to the log, UserDefaults or a URL.
nonisolated struct SoulDraft: Equatable, Sendable {
    /// The typed text.
    var text: String
    /// A hash of the gateway's text the edit started from (never the text itself, which the gateway has).
    var baseHash: String

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated struct SoulDraftStore: Sendable {
    let directory: URL

    /// `Caches/pages`.
    static var standard: SoulDraftStore {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return SoulDraftStore(directory: caches.appending(path: "pages", directoryHint: .isDirectory))
    }

    /// The account and the profile as file-name-safe words (an account id is a URL; a profile may hold anything).
    static func fileName(account: String, profile: String) -> String {
        func short(_ text: String) -> String { String(SoulDraft.hash(text).prefix(16)) }
        let safe = profile.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
            && !profile.isEmpty && profile.count <= 64
        return "soul-draft-\(short(account))-\(safe ? profile : short(profile)).txt"
    }

    func url(account: String, profile: String) -> URL {
        directory.appending(path: Self.fileName(account: account, profile: profile), directoryHint: .notDirectory)
    }

    private static let header = "hq-soul-draft base="

    /// Line one names the base; the rest is the text exactly as typed.
    static func encode(_ draft: SoulDraft) -> Data { Data((header + draft.baseHash + "\n" + draft.text).utf8) }

    static func decode(_ data: Data) -> SoulDraft? {
        guard let whole = String(data: data, encoding: .utf8), whole.hasPrefix(header),
              let end = whole.firstIndex(of: "\n") else { return nil }
        let base = String(whole[whole.index(whole.startIndex, offsetBy: header.count)..<end])
        guard base.count == 64, base.allSatisfy(\.isHexDigit) else { return nil }
        return SoulDraft(text: String(whole[whole.index(after: end)...]), baseHash: base)
    }

    func write(_ draft: SoulDraft, account: String, profile: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.encode(draft).write(to: url(account: account, profile: profile),
                                         options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // A draft that can't be kept is not worth an alert: the text is still in the editor.
        }
    }

    func read(account: String, profile: String) -> SoulDraft? {
        guard let data = try? Data(contentsOf: url(account: account, profile: profile)) else { return nil }
        return Self.decode(data)
    }

    func remove(account: String, profile: String) {
        try? FileManager.default.removeItem(at: url(account: account, profile: profile))
    }

    /// Sign-out: every draft of this account goes.
    func removeAll(account: String) {
        let prefix = "soul-draft-" + String(SoulDraft.hash(account).prefix(16)) + "-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: directory.appending(path: name, directoryHint: .notDirectory))
        }
    }
}

// MARK: - The editor's rules

nonisolated enum SoulRules {
    /// What to do with a kept draft when the editor opens with the gateway's text.
    enum DraftOffer: Equatable {
        /// No draft, or it says what the gateway says: nothing to ask (a matching draft is removed).
        case none
        /// "Restore Unsaved Changes?"
        case offer
    }

    static func draftOffer(_ draft: SoulDraft?, server: String) -> DraftOffer {
        guard let draft, draft.text != server else { return .none }
        return .offer
    }

    /// The file changed on the gateway since the edit's base was read (asked on Save, after a fresh read).
    static func changedOnGateway(baseHash: String, baseExists: Bool, now: SoulDocument) -> Bool {
        // A file that did not exist and still does not is unchanged, whatever its (empty) text.
        if !baseExists && !now.exists { return false }
        return baseExists != now.exists || SoulDraft.hash(now.content) != baseHash
    }

    /// The edit bar (`S/phone-nav-edit-bar.tsx`): Save is grey until something changed; while saving it reads
    /// "Saving…" and both buttons are off.
    struct Bar: Equatable {
        var cancelEnabled: Bool
        var saveEnabled: Bool
        var saveTitle: String
    }

    static func bar(dirty: Bool, saving: Bool, savingLabel: String = "Saving…") -> Bar {
        Bar(cancelEnabled: !saving, saveEnabled: dirty && !saving, saveTitle: saving ? savingLabel : "Save")
    }

    /// The Discard question (the web's own for SOUL.md, `B/fe-pages-gates.ts` `discardSoul`); shown to users as
    /// "Instructions".
    static let discardTitle = "Discard Changes?"
    static let discardMessage = "Your Instructions edits have not been saved."
    static let discardConfirm = "Discard Changes"
    static let discardCancel = "Keep Editing"

    static let placeholder = "This bot has no instructions yet. What you write here tells the bot who it is."

    /// "Couldn’t Save Instructions"'s reason.
    static func saveReason(_ error: Error) -> String { PagesREST.reason(error) }
}
