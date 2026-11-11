// Tool Call Style and Tool Calls After Reply (docs/spec/1x-activity.md §10.1): device-local, in UserDefaults
// (`hq.chat.toolCallStyle` absent = At the Bottom, `hq.chat.toolCallsAfterReply` absent = keep). Launch arguments such as
// `-hq.chat.toolCallStyle bubbles` work for tests (the argument domain). Changes post `ToolCallSettings.didChange`.
// Fewer Timestamps (`hq.chat.fewerTimestamps`, absent = on) lives here too: it changes the same rows and posts the
// same notification. All of it is drawing only: what Hermes sends and stores is untouched.

import Foundation

nonisolated enum ToolCallStyle: String, CaseIterable, Hashable, Sendable {
    /// `line`: One Line, a reply's thoughts and steps as one "Worked for 42s · 5 steps" line above its words.
    /// `bottom`: At the Bottom (owner, 2026-10-28): One Line once the reply is done, but while it runs no line above
    /// it; the thinking row at the bottom names each step as it goes ("Hermes is running npm test…").
    case rows, line, bottom, bubbles, header

    var title: String {
        switch self {
        case .rows: return "Rows"
        case .line: return "One Line"
        case .bottom: return "At the Bottom"
        case .bubbles: return "Bubbles"
        case .header: return "In Header"
        }
    }

    /// The line under the option on Settings › Tool Calls (UX study 2026-10-21 #111: each option says what it does,
    /// instead of one paragraph for all four).
    var detail: String {
        switch self {
        case .rows: return "Each run of steps is a quiet line you \(DeviceWord.tap) to open."
        // [mac] Stress test 2026-10-28 round 6: no-break spaces keep "42s ·" and "5 steps”." together, so a line never
        // starts with "· 5 steps”." (it did in the Mac sheet).
        case .line: return "A reply’s steps fold into one line above its words, such as “Worked for 42s\u{00A0}· 5\u{00A0}steps”."
        case .bottom: return "While the bot works, the line under the typing dots names each step as it runs. Then they fold into one line."
        case .bubbles: return "Each step in its own bubble, commands in a code block, as Hermes posts them in Telegram."
        case .header: return "Steps stay out of the chat. The line under the bot’s name shows the step it’s on."
        }
    }
}

nonisolated enum ToolCallsAfterReply: String, CaseIterable, Hashable, Sendable {
    case keep, hide

    var title: String { self == .keep ? "Keep" : "Hide" }
}

nonisolated enum ToolCallSettings {
    static let styleKey = "hq.chat.toolCallStyle"
    static let afterReplyKey = "hq.chat.toolCallsAfterReply"
    static let fewerTimestampsKey = "hq.chat.fewerTimestamps"
    static let fileChangesKey = "hq.chat.showFileChanges"
    static let didChange = Notification.Name("hq.chat.toolCallSettingsDidChange")

    static var style: ToolCallStyle {
        // At the Bottom is the default since 2026-10-28 (owner; One Line was, from 2026-10-19): a stored "rows" keeps Rows.
        get { UserDefaults.standard.string(forKey: styleKey).flatMap(ToolCallStyle.init(rawValue:)) ?? .bottom }
        set {
            if newValue == .bottom { UserDefaults.standard.removeObject(forKey: styleKey) }
            else { UserDefaults.standard.set(newValue.rawValue, forKey: styleKey) }
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    static var afterReply: ToolCallsAfterReply {
        get { UserDefaults.standard.string(forKey: afterReplyKey).flatMap(ToolCallsAfterReply.init(rawValue:)) ?? .keep }
        set {
            if newValue == .keep { UserDefaults.standard.removeObject(forKey: afterReplyKey) }
            else { UserDefaults.standard.set(newValue.rawValue, forKey: afterReplyKey) }
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    /// Fewer Timestamps: a day line only when the date changes (not after every 30-minute gap), and a time only under
    /// the bot's replies, not under yours.
    static var fewerTimestamps: Bool {
        // On by default since 2026-10-19 (owner): only "off" is stored.
        get { UserDefaults.standard.object(forKey: fewerTimestampsKey) as? Bool ?? true }
        set {
            if newValue { UserDefaults.standard.removeObject(forKey: fewerTimestampsKey) }
            else { UserDefaults.standard.set(false, forKey: fewerTimestampsKey) }
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    /// Show File Changes: the "N files changed" card under a reply that edited files (and the folded one in a run of
    /// idle updates). Off hides only the card; the chat’s ⋯ › Changes still lists them (owner 2026-11-10).
    static var showFileChanges: Bool {
        // On by default: only "off" is stored.
        get { UserDefaults.standard.object(forKey: fileChangesKey) as? Bool ?? true }
        set {
            if newValue { UserDefaults.standard.removeObject(forKey: fileChangesKey) }
            else { UserDefaults.standard.set(false, forKey: fileChangesKey) }
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    /// One Line and At the Bottom fold a reply's steps into one line (they differ only while it runs).
    static func folds(_ style: ToolCallStyle) -> Bool { style == .line || style == .bottom }

    /// After Reply applies only outside In Header (R:src/tool-calls-row.tsx:24).
    static var hidesSteps: Bool { style != .header && afterReply == .hide }

    /// The Settings row's value: the style alone, e.g. "At the Bottom" (UX study #110: was "Rows · Keep"; 2026-11-02 dropped ", hidden after reply").
    static var summary: String { SettingsWords.toolCallsSummary(style: style.title, hidesAfterReply: hidesSteps) }
}
