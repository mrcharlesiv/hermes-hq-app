// [settings] Default Project Folder (docs/spec/3x-settings.md §5; the web phone's `settings.getDefaultProjectDir`,
// `renderer-host.ts` keeps it per bot on the phone). The folder new chats start in, per gateway and bot, kept on this
// iPhone. Every `session.create` for a chat the person starts goes through `SessionCreate`.

import Foundation

nonisolated enum DefaultProjectFolder {
    static func key(account: String, profile: String) -> String { "hqn.defaultProjectFolder.\(account).\(profile)" }

    static func path(account: String, profile: String = "default") -> String? {
        let value = UserDefaults.standard.string(forKey: key(account: account, profile: profile))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    static func set(_ path: String?, account: String, profile: String = "default") {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: key(account: account, profile: profile))
        } else {
            UserDefaults.standard.set(trimmed, forKey: key(account: account, profile: profile))
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var active: String?

    /// The signed-in gateway (the app model sets it on sign-in and sign-out).
    static var activeAccount: String? {
        get { lock.withLock { active } }
        set { lock.withLock { active = newValue } }
    }

    /// The folder for `profile` on the signed-in gateway, if one is set.
    static func current(profile: String) -> String? {
        guard let account = activeAccount else { return nil }
        // DECISION 5.4: Settings has no per-bot view, so the folder set there is stored under "default" and applies to
        // every bot; one stored for a particular bot (none today) wins.
        return path(account: account, profile: profile) ?? path(account: account, profile: "default")
    }

    /// The gateway's answer to `GET /api/fs/list` is a folder when it has an `entries` array and no `error`.
    static func isFolder(_ body: JSONValue) -> Bool {
        body["error"]?.nonEmptyString == nil && body["entries"]?.array != nil
    }
}

/// `session.create` for a chat the person starts: with the default folder when one is set (`cwd` and
/// `cwd_explicit`, so it wins over the profile's own `terminal.cwd`), and with neither key otherwise.
/// Always `source: "desktop"` like the web (`V:app/session/hooks/use-session-actions/index.ts:364-366`): without it
/// Hermes resolves the chat as the terminal UI, whose system prompt tells the agent `MEDIA:` tags don't work and to
/// state a file's plain path instead (`H:agent/prompt_builder.py` PLATFORM_HINTS["tui"]), so pictures came as paths.
nonisolated enum SessionCreate {
    static func params(_ base: [String: JSONValue], profile: String, folder: String? = nil) -> JSONValue {
        var params = base
        if params["source"] == nil { params["source"] = "desktop" }
        if let folder = folder ?? DefaultProjectFolder.current(profile: profile) {
            params["cwd"] = .string(folder)
            params["cwd_explicit"] = .bool(true)
        }
        return .object(params)
    }

    /// Calls it; when the gateway refuses the default folder (it is gone), once more without it, so the chat still
    /// starts. A project's chat passes its `folder`: that one is never dropped, or the chat would start outside it.
    static func call(_ client: any GatewayClient, profile: String, _ base: [String: JSONValue], folder: String? = nil,
                     timeout: Duration) async throws -> JSONValue {
        let withFolder = params(base, profile: profile, folder: folder)
        if folder != nil { return try await client.call("session.create", withFolder, timeout: timeout) }
        do {
            return try await client.call("session.create", withFolder, timeout: timeout)
        } catch let error where withFolder["cwd"] != nil && !(error is CancellationError) {
            AppLog.note("settings", "session.create with the default folder failed; retrying without it")
            return try await client.call("session.create", .object(base), timeout: timeout)
        }
    }
}
