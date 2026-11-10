// Contracts added by the menus stream (spec docs/spec/1x-menus.md §13.3): the open chat's model state, the slash
// dispatcher, and the ⋯ menu's Rename and Share. Kept apart from Contracts.swift so parallel streams merge cleanly; the
// integrator may fold them in. Default isolation is MainActor; value types are `nonisolated`.

import Foundation

/// The open chat's model, reasoning and Fast as the gateway last reported them, with this phone's optimistic picks
/// applied (spec 1x §2.1). "" = unknown.
nonisolated struct ChatModelState: Hashable, Sendable {
    var model = ""               // model id ("claude-sonnet-5")
    var provider = ""            // provider slug ("anthropic")
    var reasoningEffort = ""     // "" provider default · "none" off · level
    var fast = false
    var yolo = false
    /// The bot's `approvals.mode` (every chat with it): "manual" · "smart" · "off"; "" not reported (an older Hermes).
    var approvalMode = ""
}

/// Model, Reasoning and Fast for the open chat (spec 1x §4.6, §5). The live session adopts it.
protocol ChatModelControlling: AnyObject {
    var modelState: ChatModelState { get set }
    var runtimeSessionId: String? { get }
    var profileParam: String? { get }
    var client: any GatewayClient { get }
    var connection: ConnectionState { get }
    /// The account the chat belongs to (favourites, recents and presets are kept per account, spec 1x §2.3).
    var account: GatewayAccount { get }
    /// A session-scoped RPC under the stream's ground rules (spec 1x §0): `params` gets the runtime id and returns the
    /// method's own keys; `session_id` (when there is one) and `profile` are added. `4001` resumes once and resends
    /// once; `4064` reports the stale roster.
    func sessionCall(_ method: String, timeout: Duration, runtime: SessionCallRuntime,
                     params: @escaping (_ runtimeId: String?) -> [String: JSONValue]) async throws -> JSONValue
}

/// What a session-scoped call does without a runtime id.
nonisolated enum SessionCallRuntime: Sendable {
    /// Resume the chat first (the slash dispatcher, §8.1).
    case resumeFirst
    /// Fail with "This chat is still loading. Try again when it is ready." (model writes, §5 step 1).
    case required
    /// Send without `session_id` (`model.options`, §3.1).
    case optional
}

/// What the slash dispatcher asks of the chat screen (spec 1x §8): set by the screen when it shows the chat.
struct ChatSlashHooks {
    /// A `prefill` directive's text for the composer (replaces the draft, focuses the field).
    var prefill: ((String) -> Void)?
    /// `/model [query]`: the Models sheet, its search field filled.
    var openModels: ((String?) -> Void)?
    /// `/help`: the Commands sheet.
    var openCommands: (() -> Void)?
    /// A failure the web shows as an alert ("YOLO" / "Could not toggle YOLO").
    var alert: ((_ title: String, _ message: String) -> Void)?
    /// The title changed by `/title <name>` (the Sessions row follows).
    var titleApplied: ((String) -> Void)?
    /// `/new` (`/reset`, `/clear`): a new chat with this chat's bot opens in this one's place, the words after the
    /// command in its field (docs/spec/3x-composer.md §8.2). False: nothing could open it.
    var newChat: ((_ draft: String) -> Bool)?
}

/// Runs a sent "/command" through the slash dispatcher instead of prompt.submit (spec 1x §8).
protocol ChatSlashRunning: AnyObject {
    func runSlash(_ text: String)
    var slashHooks: ChatSlashHooks { get set }
}

/// Rename and Share for the ⋯ (spec 1x §4.4–4.5).
protocol ChatSessionActions: AnyObject {
    /// A bot's own chat ("Bot Chat") never offers Rename, Archive or Delete (spec 1x §4.1).
    var isBotChat: Bool { get }
    /// Optimistic rename: the title changes at once; on failure it rolls back and throws. Returns the stored title.
    @discardableResult func rename(to title: String) async throws -> String
    /// The whole chat as text (spec 1x §4.4), fetching every page when only part of it is loaded.
    func transcriptText() async throws -> String
}

/// A slash output row (spec 1x §8.4): a local system message, never cached, never shared.
nonisolated enum SlashOutputRow {
    static let idPrefix = "local-slash-"
    /// The web's `slashStatusText`: "slash:/<name>\n<output>".
    static func text(command: String?, output: String) -> String {
        guard let command, !command.isEmpty else { return output }
        return ["slash:\(command)", output.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// The command and output of a slash row's text ("slash:/status\nSession …"); nil for plain text.
    static func parse(_ text: String) -> (command: String, output: String)? {
        guard text.hasPrefix("slash:/") else { return nil }
        let body = text.dropFirst("slash:".count)
        if let newline = body.firstIndex(of: "\n") {
            return (String(body[..<newline]), String(body[body.index(after: newline)...]))
        }
        return (String(body), "")
    }

    static func isSlashRow(_ message: ChatMessage) -> Bool {
        message.role == .system && message.id.hasPrefix(idPrefix)
    }
}
