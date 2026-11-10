// [presence] The rules behind "Using its computer" on a Bots row and the "<bot> is using its browser / screen" notice
// (spec 3x-presence §3.2). Pure values: no UIKit, no clock of their own (every call is handed `now`), so they are tested
// without waiting. Ports of the web app's src/ui-bots/computer-activity.ts and the checks in src/bot-screen-menu.tsx
// (startPhoneScreenNudges) and src/bot-screen-phone.tsx (shouldNudge).

import Foundation

/// Screen tools: names that start with "computer_use" or "browser_" (the desktop's screen-autoraise rule).
nonisolated enum ScreenTools {
    static let prefixes = ["computer_use", "browser_"]

    /// Case-sensitive, as on the web; nil and "" are not screen tools.
    static func isScreenTool(_ name: String?) -> Bool {
        guard let name, !name.isEmpty else { return false }
        return prefixes.contains { name.hasPrefix($0) }
    }

    static func isBrowserTool(_ name: String?) -> Bool { name?.hasPrefix("browser_") ?? false }

    /// A row says "Using its computer" this long after the bot's last screen tool (COMPUTER_QUIET_MS).
    static let quiet: Duration = .seconds(90)
    /// One notice per bot in this long (NUDGE_COOLDOWN_MS).
    static let noticeCooldown: Duration = .seconds(30)
    /// A notice left alone leaves after this long.
    static let noticeSeconds: TimeInterval = 8
}

/// Profile → when it last started a screen tool.
nonisolated struct ComputerActivity: Sendable {
    private(set) var lastAt: [String: ContinuousClock.Instant] = [:]

    mutating func toolStarted(_ profile: String, at now: ContinuousClock.Instant) {
        guard !profile.isEmpty else { return }
        lastAt[profile] = now
    }

    /// `message.complete`: true when the profile was active (the caller republishes).
    @discardableResult mutating func replyFinished(_ profile: String) -> Bool {
        lastAt.removeValue(forKey: profile) != nil
    }

    /// Profiles with `now - lastAt < 90 s`. Also drops the expired ones.
    mutating func active(at now: ContinuousClock.Instant) -> Set<String> {
        lastAt = lastAt.filter { now - $0.value < ScreenTools.quiet }
        return Set(lastAt.keys)
    }

    /// The earliest moment a profile's window ends, or nil when none is kept.
    func nextExpiry() -> ContinuousClock.Instant? {
        lastAt.values.min().map { $0 + ScreenTools.quiet }
    }

    mutating func reset() { lastAt = [:] }
}

/// Whether a `tool.start` raises a notice, and which. `decide` runs the web's checks in the web's order; the reason a
/// notice is not shown is a log word, never shown to the person.
nonisolated struct NoticeGate: Sendable {
    struct Input: Sendable {
        var replayed: Bool
        var toolName: String?
        /// nil: no bot owns the session.
        var profile: String?
        /// The bot's switch ("Alert When It Uses Its Computer").
        var noticeOn: Bool
        /// The bot of the chat on screen, nil when no chat is on screen.
        var visibleChatProfile: String?
        /// A Bot Screen viewer is showing (any bot).
        var screenViewerOpen: Bool
        /// A Watch Browser viewer for this bot is showing.
        var watchingThisBrowser: Bool
        /// The screen stream's viewer exists (`BotComputerHooks.openScreen != nil`).
        var canWatchScreen: Bool
    }

    enum Outcome: Equatable, Sendable { case none(String), browser, screen }

    private(set) var last: [String: ContinuousClock.Instant] = [:]

    mutating func decide(_ input: Input, now: ContinuousClock.Instant) -> Outcome {
        if input.replayed { return .none("replayed") }
        guard ScreenTools.isScreenTool(input.toolName) else { return .none("not a screen tool") }
        guard let profile = input.profile, !profile.isEmpty else { return .none("no owner") }
        guard input.noticeOn else { return .none("off for this bot") }
        let browser = ScreenTools.isBrowserTool(input.toolName)
        // The chat's own browser card already says it there, with its own Watch.
        if browser, input.visibleChatProfile == profile { return .none("its chat is on screen") }
        // Native only (DECISION D6): a Watch that opens nothing is never offered. Nothing is stamped.
        if !browser, !input.canWatchScreen { return .none("no screen viewer") }
        if input.screenViewerOpen { return .none("screen viewer open") }
        if let before = last[profile], now - before < ScreenTools.noticeCooldown { return .none("cooldown") }
        last[profile] = now
        // As on the web, the cooldown is stamped before this check.
        if browser, input.watchingThisBrowser { return .none("already watching") }
        return browser ? .browser : .screen
    }

    mutating func reset() { last = [:] }
}

/// The switch's failure in plain words (spec §7, D4). A write the gateway never answered arrives with the client's own
/// log line as its reason ("request timed out after 30s: profiles.configure"); the alert says what happened and the log
/// line stays behind Show Details.
nonisolated enum NoticeWriteWords {
    static let noAnswer = "\(HostWord.sentence) didn’t answer in time."   // UX study #24
    static let dropped = "The connection dropped before \(HostWord.phrase) answered."

    static func plain(_ failure: BotWriteError) -> BotWriteError {
        let words: String
        if failure.reason.hasPrefix("request timed out") { words = noAnswer }
        else if failure.reason.hasPrefix("connection closed before") { words = dropped }
        else { return failure }
        let detail = [failure.reason, failure.detail].compactMap { $0 }.filter { !$0.isEmpty && $0 != words }
        return BotWriteError(title: failure.title, reason: words, detail: detail.isEmpty ? nil : detail.joined(separator: "\n\n"))
    }
}
