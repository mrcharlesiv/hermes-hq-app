// Where a chat came from (its `source`): the name, mark and colour the Sessions list draws for it. The desktop app's
// own maps (`V/lib/session-source.ts:3-86`, `V/app/messaging/platform-icon.tsx:54-73`): one folder per messaging
// platform under the dated list, and a small mark on a row that came from one (or was handed off from one).

import Foundation

nonisolated enum ChatSource {
    /// How a platform's mark is drawn: a brand glyph from the asset catalog ("Platforms/<id>"), an SF Symbol, or a
    /// letter on the platform's colour.
    enum Mark: Hashable, Sendable {
        case brand(String)
        case symbol(String)
        case letter(String)
    }

    /// `SOURCE_LABELS`; anything else reads in Title Case with `_`/`-` as spaces.
    private static let labels: [String: String] = [
        "acp": "ACP", "api_server": "API", "bluebubbles": "iMessage", "cli": "CLI", "codex": "Codex",
        "desktop": "Desktop", "discord": "Discord", "email": "Email", "gateway": "Gateway", "kanban": "Kanban",
        "local": "Local", "matrix": "Matrix", "mattermost": "Mattermost", "oneshot": "One-shot", "photon": "Photon",
        "qqbot": "QQ", "signal": "Signal", "slack": "Slack", "sms": "SMS", "telegram": "Telegram", "tui": "TUI",
        "webhook": "Webhook", "weixin": "WeChat", "whatsapp": "WhatsApp", "yuanbao": "Yuanbao",
        "homeassistant": "Home Assistant", "wecom": "WeCom", "dingtalk": "DingTalk", "feishu": "Feishu",
    ]

    /// `MESSAGING_SESSION_SOURCE_IDS`: the platforms that get a folder.
    static let messaging: Set<String> = ["telegram", "discord", "slack", "mattermost", "matrix", "signal", "whatsapp",
        "bluebubbles", "photon", "homeassistant", "email", "sms", "webhook", "api_server", "weixin", "wecom", "qqbot",
        "yuanbao", "dingtalk", "feishu"]

    /// `LOCAL_SESSION_SOURCE_IDS`: a handoff to one of these is not an origin worth a mark.
    static let local: Set<String> = ["acp", "cli", "codex", "desktop", "gateway", "kanban", "local", "oneshot", "tui"]

    /// `PLATFORM_ICONS`: (mark, colour as 0xRRGGBB).
    private static let marks: [String: (Mark, UInt32)] = [
        "telegram": (.brand("telegram"), 0x26A5E4), "discord": (.brand("discord"), 0x5865F2),
        "slack": (.letter("S"), 0x4A154B),           // no brand glyph (removed from Simple Icons at Salesforce's request)
        "mattermost": (.brand("mattermost"), 0x0058CC), "matrix": (.brand("matrix"), 0x000000),
        "signal": (.brand("signal"), 0x3A76F0), "whatsapp": (.brand("whatsapp"), 0x25D366),
        "bluebubbles": (.brand("bluebubbles"), 0x0BD318), "photon": (.letter("P"), 0x6366F1),
        "homeassistant": (.brand("homeassistant"), 0x18BCF2), "email": (.brand("email"), 0xEA4335),
        "sms": (.symbol("message.fill"), 0xF43F5E), "webhook": (.symbol("link"), 0x71717A),
        "api_server": (.symbol("globe"), 0x64748B), "oneshot": (.symbol("bolt.fill"), 0x71717A),
        "cron": (.symbol("clock.fill"), 0x71717A), "weixin": (.brand("weixin"), 0x07C160),
        "qqbot": (.brand("qqbot"), 0xEB1923), "yuanbao": (.brand("yuanbao"), 0xFB7299),
    ]

    static func id(_ source: String?) -> String {
        (source ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func label(_ source: String?) -> String {
        let key = id(source)
        if let known = labels[key] { return known }
        return key.split(whereSeparator: { $0 == "_" || $0 == "-" }).map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    static func isMessaging(_ source: String?) -> Bool { messaging.contains(id(source)) }

    /// One-off runs (`hermes -z`, `chat -q`, a script's "Reply with exactly OK" probe): not a platform, but the HQ web
    /// app gave them a "One-off Runs" folder beside the platforms' (`B/stress-c-gates.ts:79-93`), shown with
    /// Show › Background Runs. The desktop and the dashboard's default list leave them out.
    static let oneOff = "oneshot"

    /// Scheduled job runs (`source = "cron"`, one session per run). The desktop gives them a "Cron jobs" sidebar section
    /// and the dashboard files them under Automation; here they are a "Scheduled Runs" section beside the one-off runs,
    /// shown with Show › Background Runs (docs/spec/3x-sessions.md, DECISION F1). The Jobs page opens each job's runs too.
    static let scheduled = "cron"

    /// A source with its own section on the Other Apps page: a messaging platform, the one-off runs, the scheduled runs.
    static func hasFolder(_ source: String?) -> Bool { isMessaging(source) || id(source) == oneOff || id(source) == scheduled }

    /// A section's name on the Other Apps page and its row: the platform's name, "One-off Runs" and "Scheduled Runs"
    /// for the runs.
    static func folderLabel(_ source: String?) -> String {
        switch id(source) {
        case oneOff: "One-off Runs"
        case scheduled: "Scheduled Runs"
        default: label(source)
        }
    }

    /// The mark and colour; an unknown platform gets its first letter on a grey.
    static func mark(_ source: String?) -> (mark: Mark, color: UInt32) {
        let key = id(source)
        if let known = marks[key] { return known }
        return (.letter(String(label(key).prefix(1)).uppercased()), 0x71717A)
    }

    /// The platform a row came from, when it is worth a mark: a messaging chat's own source, else the platform a
    /// finished handoff started on (`handoffOriginSource`, `session-source.ts:107-122`).
    static func origin(source: String?, handoffPlatform: String?, handoffState: String?) -> String? {
        if isMessaging(source) { return id(source) }
        guard id(handoffState) == "completed", let platform = handoffPlatform, !id(platform).isEmpty,
              !local.contains(id(platform)) else { return nil }
        return id(platform)
    }
}
