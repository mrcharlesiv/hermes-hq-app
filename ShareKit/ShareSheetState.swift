// [share] The sheet's decisions, pure (docs/spec/3x-share.md §7.2, §7.10): the order of the bots, which one starts
// chosen, when Send is allowed, and the words of the progress card and of a bot's second line.
// Port of build 240's ShareModel.swift:39-68 and ShareView.swift:146-171, :214-220.

import Foundation

nonisolated enum ShareSheetState {
    /// Most recently active first: the chat a share most likely belongs in is the one in use. Ties, and bots without a
    /// time, keep the roster's own order.
    static func ordered(_ bots: [ShareBot]) -> [ShareBot] {
        bots.enumerated().sorted { a, b in
            let left = a.element.lastActive ?? 0, right = b.element.lastActive ?? 0
            return left == right ? a.offset < b.offset : left > right
        }.map(\.element)
    }

    /// The bot a sheet opens with (spec D6): the remembered one by exact key, else the one on the same profile (a
    /// choice build 240 remembered as `legacy::ivy`), and only while it can receive; else the first that can.
    static func selection(bots: [ShareBot], remembered: String?) -> String? {
        let able = bots.filter(\.canReceive)
        if let remembered, !remembered.isEmpty {
            if let exact = able.first(where: { $0.key == remembered }) { return exact.key }
            let profile = ShareRules.profile(ofKey: remembered)
            if let same = able.first(where: { $0.profile == profile }) { return same.key }
        }
        return able.first?.key
    }

    /// Send needs: the items read, a bot that can receive, something to send, nothing over the limit.
    static func canSend(ready: Bool, selected: ShareBot?, hasContent: Bool, oversized: Int) -> Bool {
        guard ready, let selected, selected.canReceive, hasContent, oversized == 0 else { return false }
        return true
    }

    /// Whether a message or any readable item is there to send.
    static func hasContent(message: String, items: Int) -> Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || items > 0
    }

    static let preparing = "Preparing…"
    static let noBots = "Open Hermes HQ once so your bots appear here."
    static let noChat = "Open this bot in Hermes HQ first"
    static let botChat = "Bot Chat"
    static let photoPrivacy = "Sent without location or camera details"
    static let blockedTitle = "Can’t Share Yet"
    static let tryAgain = "Try Again"
    static let title = "Hermes HQ"
    static let placeholder = "Add a message"
    static let sendTo = "Send to"

    /// The message box's placeholder. Photos alone are sent with the composer's question when the box stays empty, so
    /// the box shows that question greyed (UX study 2026-10-21 #148); anything else, "Add a message".
    static func messagePlaceholder(imagesOnly: Bool) -> String { imagesOnly ? ShareRules.defaultQuestion : placeholder }

    /// The bots section's header: "Send to", and the gateway's name when the roster names one (several saved).
    static func botsHeader(gateway: String?) -> String {
        guard let name = gateway?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return sendTo }
        return "\(sendTo) · \(name.prefix(60))"
    }

    static func label(_ step: ShareStep) -> String {
        switch step {
        case .connecting: return "Connecting…"
        case .uploading(let index, let count): return count == 1 ? "Uploading…" : "Uploading \(index) of \(count)…"
        case .sending: return "Sending…"
        }
    }

    static func sent(to name: String) -> String { "Sent to \(name)" }

    static func unreadable(_ name: String) -> String { ShareFailure.unreadable(name).message }

    /// More photos or files than one share takes: which were kept. Nil when nothing was left out.
    static func overCap(_ skipped: ShareSkipped) -> String? {
        let photos = "\(ShareRules.maxImages) photos", files = "\(ShareRules.maxFiles) files"
        switch (skipped.photos > 0, skipped.files > 0) {
        case (true, true): return "Only the first \(photos) and \(files) are sent."
        case (true, false): return "Only the first \(photos) are sent."
        case (false, true): return "Only the first \(files) are sent."
        case (false, false): return nil
        }
    }

    static func oversized(_ name: String, limit: Int) -> String {
        "“\(name)” is larger than \(ShareRules.megabytes(limit)), your attachment limit."
    }

    /// Under an oversized item: what to do next (UX study 2026-10-19 #88; it said only why Send was off).
    static let oversizedHint = "Remove it, or cancel and share again."
    static let remove = "Remove"

    /// A bot's second line: why it cannot be chosen, when its chat was last active, or just what a share goes to.
    static func subtitle(_ bot: ShareBot, now: Date = Date(), locale: Locale = .current) -> String {
        guard bot.canReceive else { return noChat }
        guard let active = bot.lastActive, active > 0 else { return botChat }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = locale
        // A chat stamped a little ahead of this phone's clock is "now", never "in 3 sec.".
        let then = min(Date(timeIntervalSince1970: active), now)
        return "Active " + formatter.localizedString(for: then, relativeTo: now)
    }

    /// What VoiceOver reads for a bot row: "<name>, <second line>".
    static func spoken(_ bot: ShareBot, now: Date = Date()) -> String { bot.name + ", " + subtitle(bot, now: now) }
}
