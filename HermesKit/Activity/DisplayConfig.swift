// The two display flags of a bot's Hermes config the activity stream obeys (docs/spec/1x-activity.md §2.3):
// `display.show_reasoning` (reasoning rows, §9.4) and `display.tool_progress` (the run tools' rows, §10.6). Read from
// `GET /api/config?profile=<p>` when a chat opens and the copy is older than a minute (one read in flight per profile;
// the gateway loads its whole config under a process-wide lock, so a chat open must not pay for it every time); the
// last answer shows at once meanwhile. App return marks every copy stale (a flag changed on the computer shows on the
// next open). DECISION: 60 s instead of the spec's 5 minutes, so a changed flag shows soon after (§16 check 19). Until a
// first answer arrives both are on.

import Foundation

nonisolated struct DisplayFlags: Hashable, Sendable {
    var showReasoning = true
    /// `tool_progress` is off: run tools that neither failed nor are cards draw nothing.
    var toolProgressOff = false

    /// `show_reasoning` absent ⇒ on; `false`, `"false"`, `0` ⇒ off. `tool_progress` off only for `false` or `"off"`
    /// (case-insensitive) (V:store/reasoning-disclosure.ts:22-29, V:store/tool-activity.ts:1-20).
    init(config: JSONValue?) {
        let display = config?["display"]
        switch display?["show_reasoning"] {
        case .bool(false)?: showReasoning = false
        case .string(let s)? where s.trimmingCharacters(in: .whitespaces).lowercased() == "false": showReasoning = false
        case .number(0)?: showReasoning = false
        default: showReasoning = true
        }
        switch display?["tool_progress"] {
        case .bool(false)?: toolProgressOff = true
        case .string(let s)? where s.trimmingCharacters(in: .whitespaces).lowercased() == "off": toolProgressOff = true
        default: toolProgressOff = false
        }
    }

    init() {}
}

@MainActor final class DisplayConfigCache {
    private let client: any GatewayClient
    private var entries: [String: (flags: DisplayFlags, at: Date)] = [:]
    private var inFlight: [String: Task<DisplayFlags?, Never>] = [:]
    var lifetime: TimeInterval = 60

    init(client: any GatewayClient) { self.client = client }

    /// The flags known for `profile` (defaults when never read).
    func flags(profile: String) -> DisplayFlags { entries[profile]?.flags ?? DisplayFlags() }

    /// Reads the config when the cached copy is older than `lifetime`; `changed` runs when the flags moved.
    func refresh(profile: String, changed: @escaping @MainActor (DisplayFlags) -> Void) {
        if let entry = entries[profile], Date().timeIntervalSince(entry.at) < lifetime { return }
        guard inFlight[profile] == nil else { return }
        let client = self.client
        let task = Task { await Self.read(client, profile: profile) }
        inFlight[profile] = task
        Task { [weak self] in
            let flags = await task.value
            guard let self else { return }
            self.inFlight[profile] = nil
            guard let flags else { return }
            let before = self.entries[profile]?.flags ?? DisplayFlags()
            self.entries[profile] = (flags, Date())
            if flags != before { changed(flags) }
        }
    }

    /// The read and the parse of the whole config, off the main actor.
    @concurrent private static func read(_ client: any GatewayClient, profile: String) async -> DisplayFlags? {
        let query = profile.isEmpty ? [] : [URLQueryItem(name: "profile", value: profile)]
        guard let data = try? await client.configData(query),   // [load-cache] shared with the other readers
              let json = try? JSONValue.parse(data) else { return nil }
        return DisplayFlags(config: json)
    }

    /// Every copy is read again on its next refresh (app return).
    func markStale() {
        for key in entries.keys { entries[key]?.at = .distantPast }
    }

    func forget() {
        entries = [:]
        inFlight.values.forEach { $0.cancel() }
        inFlight = [:]
    }
}
