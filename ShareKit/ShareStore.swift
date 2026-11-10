// [share] The App Group folder: roster.json, avatars/, last-sent.json, choice.json (docs/spec/3x-share.md §5.1).
// Files are written atomically and readable after the first unlock (the app refreshes the roster in the background
// too). A file that does not decode reads as absent, never a crash.

import Foundation

nonisolated struct ShareStore: Sendable {
    let folder: URL

    init(folder: URL) { self.folder = folder }
    /// Nil when this build has no App Group (the native identity).
    init?(manager: FileManager = .default) {
        guard let folder = ShareIdentity.folder(manager) else { return nil }
        self.folder = folder
    }

    var avatars: URL { folder.appendingPathComponent("avatars", isDirectory: true) }
    var rosterFile: URL { folder.appendingPathComponent("roster.json") }
    var sentFile: URL { folder.appendingPathComponent("last-sent.json") }
    var choiceFile: URL { folder.appendingPathComponent("choice.json") }
    #if DEBUG
    /// DEBUG builds only (spec D14): forces a blocked state or a failure row for a screenshot. Compiled out of Release.
    var debugFile: URL { folder.appendingPathComponent("debug.json") }
    /// What the file asks for: `{"blocked":"needsApp"}` or `{"failure":"tailscaleOff"}` (case names of `ShareFailure`).
    var debugForced: (blocked: ShareFailure?, failure: ShareFailure?) {
        let asked = read([String: String].self, from: debugFile) ?? [:]
        return (asked["blocked"].flatMap(ShareFailure.named), asked["failure"].flatMap(ShareFailure.named))
    }
    #endif

    /// A roster larger than this is not one this app wrote (200 bots are well under 100 KB): read as absent.
    static let maxFileBytes = 2 * 1024 * 1024
    static let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]

    private func write<T: Encodable>(_ value: T, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: file, options: Self.writeOptions)
    }
    private func read<T: Decodable>(_ type: T.Type, from file: URL) -> T? {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, size <= Self.maxFileBytes, let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    // MARK: Roster and faces (written by the app only)

    var roster: ShareRoster? { read(ShareRoster.self, from: rosterFile) }

    /// Saves the roster and the pictures it names (written by key: an unchanged picture keeps its file). Pictures no
    /// bot names any more go.
    func save(_ roster: ShareRoster, pictures: [String: Data] = [:]) throws {
        try FileManager.default.createDirectory(at: avatars, withIntermediateDirectories: true)
        for (name, data) in pictures where ShareRules.validAvatarName(name) {
            try data.write(to: avatars.appendingPathComponent(name), options: Self.writeOptions)
        }
        try write(roster, to: rosterFile)
        let kept = Set(roster.bots.compactMap(\.avatar))
        for name in (try? FileManager.default.contentsOfDirectory(atPath: avatars.path)) ?? [] where !kept.contains(name) {
            try? FileManager.default.removeItem(at: avatars.appendingPathComponent(name))
        }
    }

    func hasPicture(_ name: String) -> Bool {
        ShareRules.validAvatarName(name) && FileManager.default.fileExists(atPath: avatars.appendingPathComponent(name).path)
    }

    /// The picture's file, only for a valid name inside `avatars/` (a roster naming `../../x.png` reads nothing).
    func picture(_ name: String?) -> URL? {
        guard let name, hasPicture(name) else { return nil }
        return avatars.appendingPathComponent(name)
    }

    /// Sign-out, an account switch: the sheet offers nobody until the app has a signed-in roster again.
    func clear() {
        for file in [rosterFile, sentFile, choiceFile, avatars] { try? FileManager.default.removeItem(at: file) }
    }

    // MARK: The chat a share went to (written by the extension, taken once by the app)

    var lastSent: ShareSent? { read(ShareSent.self, from: sentFile) }
    /// True while a note file is there at all, readable or not (the app removes an unreadable one too).
    var hasSentNote: Bool { FileManager.default.fileExists(atPath: sentFile.path) }
    func record(_ sent: ShareSent) { try? write(sent, to: sentFile) }

    /// The chat a share just went to, once: for this account, at most `window` seconds old, not more than 5 s in the
    /// future. The file goes whatever it holds.
    func takeSent(account: String, now: Double = Date().timeIntervalSince1970, window: Double = 300) -> ShareSent? {
        let sent = lastSent
        try? FileManager.default.removeItem(at: sentFile)
        guard let sent, sent.account == account, now - sent.at >= -5, now - sent.at <= window,
              ShareRules.validSession(sent.session) else { return nil }
        return sent
    }

    // MARK: The bot last shared to (written by the extension)

    func lastChoice(account: String) -> String? { read([String: String].self, from: choiceFile)?[account] }
    func remember(choice key: String, account: String) { try? write([account: key], to: choiceFile) }
}
