// Row-building rules for the Bots list (spec 02 §6) and the list-time words shared with Sessions. Pure.

import Foundation

nonisolated enum RosterRules {
    static let botChatTitle = "Bot Chat"
    static let pinnedSectionId = "hermes-hq-pinned"
    static let pinnedSectionName = "Pinned"
    /// The first six pinned rows become tiles (spec 02 §7.3).
    static let maxTiles = 6

    // MARK: Identity (§1.1, §6.1, §6.2)

    /// @handle: `default` is `hermes` (`HB/data.ts:1011-1017`); other profiles their lowercased name.
    static func handle(forProfile name: String) -> String {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return key.isEmpty || key == "default" ? "hermes" : key
    }

    private static let separatorRun = JSRegex(#"[-_]+"#)

    /// `research-buddy` → `Research Buddy` (`S/ui-kit/bot-identity.ts:56` titleCase: `-`/`_` runs → one space, then
    /// every word character after a non-word character upper-cased).
    static func titleCase(_ raw: String) -> String {
        let spaced = separatorRun.replaceAll(raw, " ").trimmingCharacters(in: .whitespacesAndNewlines)
        var out = ""
        var previousIsWord = false
        for ch in spaced {
            let isWord = ch.isLetter || ch.isNumber || ch == "_"
            out += (isWord && !previousIsWord) ? ch.uppercased() : String(ch)
            previousIsWord = isWord
        }
        return out
    }

    /// The display name (§6.1): meta title, display_name, "Hermes" for `default`, else Title Case of the name.
    static func displayName(_ profile: RosterProfile, meta: BotMeta) -> String {
        if let title = meta.title { return title }
        if let shown = profile.displayName { return shown }
        if profile.name == "default", profile.title == nil { return "Hermes" }
        return titleCase(profile.title ?? profile.name)
    }

    /// The role line (§6.2): meta description, row description, or the row title when it differs from the name.
    static func roleLine(_ profile: RosterProfile, meta: BotMeta, name: String) -> String? {
        if let d = meta.description { return d }
        if let d = profile.description { return d }
        if let t = profile.title, t != name { return t }
        return nil
    }

    // MARK: Which session the row previews, and its time (§6.3)

    /// A Bot Chat with something in it: `message_count > 0` when it is a number, else a non-blank preview.
    static func holdsMessages(_ session: RosterSessionRef?) -> Bool {
        guard let session else { return false }
        if let count = session.messageCount { return count > 0 }
        return RosterText.nonBlank(session.preview) != nil
    }

    nonisolated struct PreviewSource: Sendable, Hashable {
        /// The session the row previews (nil: nothing to preview).
        var session: RosterSessionRef?
        /// Seconds since the epoch; 0 for a bot with nothing said yet.
        var time: Double
        /// rowPreview's reading of that session's preview, a cron run's "Cron · …", or the session title.
        var preview: String
    }

    /// `rosterPreview` (`S/fe-lists-r6.ts:48-81`), phone rule: the Bot Chat when it holds messages, else nothing. The
    /// web fell back to the bot's latest session, so a new bot only used through sessions showed each session turn as
    /// its own (tester, 2026-11-05); a side chat speaks on its Sessions row, like "Working…" does.
    static func rosterPreview(_ profile: RosterProfile, model: (String) -> String = { $0 }) -> PreviewSource {
        if let canonical = profile.canonicalSession, holdsMessages(canonical) {
            return PreviewSource(session: canonical, time: canonical.lastActive ?? 0,
                                 preview: RosterPreview.rowPreview(canonical.preview, model: model))
        }
        return PreviewSource(session: nil, time: 0, preview: "")
    }

    /// `rosterTime`: the §6.3 time without building the preview.
    static func rosterTime(_ profile: RosterProfile) -> Double {
        if let canonical = profile.canonicalSession, holdsMessages(canonical) { return canonical.lastActive ?? 0 }
        return 0
    }

    /// Sort key (§7.2), milliseconds: the row's time, else the bot's creation time.
    static func sortTime(_ profile: RosterProfile, meta: BotMeta) -> Double {
        let t = rosterTime(profile) * 1000
        if t != 0 { return t }
        return meta.created ?? 0
    }

    // MARK: Second line (§6.5)

    nonisolated struct SecondLine: Sendable, Hashable {
        nonisolated enum Tone: Sendable, Hashable { case secondary, tint, orange }
        nonisolated enum Kind: Sendable, Hashable { case idle, working, waking }
        var kind: Kind
        var prefix: String?
        var text: String
        var tone: Tone
        /// One line for VoiceOver: prefix and text.
        var line: String { prefix.map { "\($0) \(text)" } ?? text }
    }

    /// The parts of §6.5 the M1 data can know: "Waking up…" while an open has taken over a second (the UI's grace),
    /// "Working…" (or its step, "Reading package.json…") while the bot's chat runs a turn, else the cleaned preview with
    /// its prefix (or role / "No messages yet").
    static func secondLine(isWorking: Bool, step: String? = nil, opening: Bool = false, preview: RosterPreview.Parts) -> SecondLine {
        if opening { return SecondLine(kind: .waking, prefix: nil, text: "Waking up…", tone: .secondary) }
        if isWorking { return SecondLine(kind: .working, prefix: nil, text: step.map(LiveSteps.line) ?? "Working…", tone: .tint) }
        return SecondLine(kind: .idle, prefix: preview.prefix, text: preview.text, tone: .secondary)
    }

    // MARK: Search (§7.1)

    /// Search matches display name, profile, handle, role and preview (`HB/data.ts:1464-1491`), case-insensitively.
    static func matches(_ bot: Bot, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        let fields = [bot.name, bot.id, handle(forProfile: bot.id), "@" + handle(forProfile: bot.id), bot.role ?? "", bot.preview ?? ""]
        return fields.contains { $0.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    // MARK: Errors (S/list-helpers.ts:73-82)

    /// The words of an error as the web's regexes see them.
    static func errorText(_ error: Error) -> String {
        if let rpc = error as? RPCError { return rpc.message }
        if let http = error as? HTTPError { return "HTTP \(http.status) \(http.body ?? "")" }
        if let url = error as? URLError, url.code == .timedOut { return "request timed out" }
        return "\(error.localizedDescription) \(String(describing: error))"
    }

    private static let busy = JSRegex(#"timed?\s*out|timeout|overloaded|too many requests|\b429\b|\b503\b|pool (?:is )?(?:full|exhausted)|busy"#, "i")
    private static let notConnected = JSRegex(#"gateway unavailable|not connected|connection closed|connection reset|ECONNRESET"#, "i")

    /// A request the gateway did not answer in time (or refused while overloaded): Retry can fix it.
    static func isGatewayBusy(_ error: Error) -> Bool {
        if let http = error as? HTTPError, http.status == 429 || http.status == 503 { return true }
        return busy.test(errorText(error))
    }

    /// The socket to Hermes is not open (yet).
    static func isGatewayNotConnected(_ error: Error) -> Bool { notConnected.test(errorText(error)) }
}

// List time (S/list-time.ts:29-40) lives in App/Root/ListTime.swift (one implementation, en-US like the web).
