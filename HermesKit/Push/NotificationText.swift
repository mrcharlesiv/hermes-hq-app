// Alert words (port of the web app's DispatchPlatformPolicy notification rules, HermesPlatformExtras.swift, build 240;
// cases shared with the web app and the plugin: Tests/Fixtures/notification-preview-cases.json). Who an alert is from,
// what it says (a reply's first words, a question, the command awaiting approval, why a reply failed), with secrets
// masked, and the app icon's badge. Pure Foundation.

import Foundation

/// Who an alert is from (the app's notification directory: AppModel+Notifications): the bot's display name,
/// the chat's own title, its group room, and whether it is a bot's chat (a plain chat is titled by its title).
nonisolated struct NotificationWho: Equatable, Sendable {
    var sender = "", chat = "", group = "", bot = false
}
nonisolated struct NotificationCopy: Equatable, Sendable {
    var title: String, subtitle = "", body: String
}
/// The app icon's badge: the lists' unread markers (Bots tab + Sessions tab, so the icon never says more than the tabs),
/// plus, while the app is away, chats whose reply or failure it alerted, until it is back on screen and the lists are
/// the whole truth again.
nonisolated struct NotificationBadge: Equatable, Sendable {
    var unread = Set<String>(), alerted = Set<String>()
    var count: Int { unread.union(alerted).count }
    /// The lists' markers: on screen the whole truth; away, added to what was alerted (a chat that finished while the
    /// app could still update must not wipe the one the user left).
    mutating func markers(_ ids: [String], enabled: Bool, active: Bool) {
        unread = enabled ? Set(ids.filter { !$0.isEmpty }.prefix(999)) : []
        if active || !enabled { alerted.removeAll() }
    }
    /// Whether an alert counts its chat: only a reply or a failure, only while away. An approval or a question is
    /// not an unread reply, and one shown on screen is read where it is.
    mutating func alert(kind: String, chat: String, active: Bool) -> Bool {
        guard !active, !chat.isEmpty, ["message.complete", "turnDone", "turnError"].contains(kind) else { return false }
        alerted.insert(chat)
        return true
    }
    mutating func becameActive() { alerted.removeAll() }
}
nonisolated enum NotificationText {
    /// A local alert's userInfo: the chat a tap opens, the request an Approve/Deny answers and (D22) the bot's profile
    /// (its avatar key, as the renderer names it), so the answer goes to that bot's own profile.
    static func localInfo(session: String, stored: String, request: String, kind: String, profile: String) -> [String: String] {
        ["session": session, "stored": stored, "request": request, "kind": kind, "profile": profile]
    }
    /// D22: the profile an Approve/Deny on a local alert names: "" for an alert from before build 161 (the renderer
    /// answers on the chat's own profile then), or for anything that isn't a plain name.
    static func actionProfile(_ info: [AnyHashable: Any]) -> String {
        guard let profile = info["profile"] as? String, profile.count <= 128,
              profile.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0) }) else { return "" }
        return profile
    }
    /// Codex N11: a reply observed under one sign-in (`observed`, the notification epoch as its frame arrived) posts only
    /// while that sign-in is still the current one: never after a sign-out or a gateway switch.
    static func mayPost(observed: Int, current: Int) -> Bool { observed == current }
    static func authorization(_ raw: Int) -> String {
        let names = ["notDetermined", "denied", "authorized", "provisional", "ephemeral"]
        return names.indices.contains(raw) ? names[raw] : "unknown"
    }
    /// Alert copy per kind (docs/notifications.md). Build 14 kept every alert content-free ("Bot Chat" / "Your
    /// reply is ready."). Since build 17 alerts read like Messages: the title says who (the bot's name, "Ivy ·
    /// Room" in a group room, a plain chat's own title), the subtitle which chat, and the body what: the reply's
    /// first words, the question, the command awaiting approval, or why a reply failed. Text is plain, clipped
    /// and masked where it holds a secret (preview, redact). With Settings › Notifications › Show Previews off an
    /// alert only says who needs you; iOS's own Show Previews still hides everything on a locked phone. The
    /// Settings test, plugin and credits alerts keep their own words (app or system text), masked; with Show Previews
    /// off a plugin's or credits notice keeps only its title. A sender nobody could name (a chat whose rows and owner
    /// haven't loaded) is never guessed: the alert says what happened without saying who.
    static func notification(kind: String, who: NotificationWho?, text: String?, title: String? = nil, body: String? = nil, previews: Bool = true) -> NotificationCopy {
        let passed = { (value: String?, fallback: String) in value.map { String(redact(oneLine($0)).prefix(240)) }.flatMap { $0.isEmpty ? nil : $0 } ?? fallback }
        switch kind {
        case "test": return NotificationCopy(title: passed(title, "Hermes HQ"), body: passed(body, "Notifications are working."))
        case "plugin": return NotificationCopy(title: passed(title, "Hermes HQ"), body: previews ? passed(body, "Notifications are working.") : "Open Hermes HQ to see what’s new")
        case "credits": return NotificationCopy(title: passed(title, "Credits"), body: previews ? passed(body, "Your credit balance changed.") : "Your credit balance changed")
        default: break
        }
        let named = sanitized(who ?? NotificationWho())
        let sender = named.sender, group = named.group
        let chat = genericChat(named.chat) || named.chat == sender ? "" : named.chat
        let bot = who?.bot == true || !group.isEmpty
        let name = !group.isEmpty ? (sender.isEmpty ? group : "\(sender) · \(group)") : bot || chat.isEmpty ? sender : chat
        let approval = kind == "approval.request" || kind == "approval", reply = kind == "message.complete" || kind == "turnDone"
        guard previews else {
            let from = sender.isEmpty ? group : group.isEmpty ? sender : "\(sender) in \(group)"
            let line = approval ? (from.isEmpty ? "A request needs your approval" : "\(from) needs your approval")
                : kind == "input" ? (from.isEmpty ? "A question is waiting for your answer" : "\(from) is waiting for your answer")
                : reply ? (from.isEmpty ? "New reply" : "New reply from \(from)")
                : kind == "turnError" ? (from.isEmpty ? "A reply couldn’t finish" : "\(from) couldn’t finish a reply")
                : kind == "backgroundDone" ? "A background task finished" : "Open Hermes HQ to see what’s new"
            return NotificationCopy(title: "", body: line)
        }
        let fallback = approval ? "Approval needed" : kind == "input" ? "Question" : reply ? "New reply" : kind == "turnError" ? "Reply failed"
            : kind == "backgroundDone" ? "Background task" : "Hermes HQ"
        let heading = name.isEmpty ? fallback : name
        let subtitle = group.isEmpty && chat != heading ? chat : ""
        let shown = preview(text ?? "")
        let line: String
        switch kind {
        case "approval.request", "approval":
            let command = commandSummary(text ?? ""), about = preview(body ?? "")
            line = !command.isEmpty ? "Wants to run: \(command)" : about.isEmpty ? "Needs your approval" : about
        case "input": line = shown.isEmpty ? "Waiting for your answer" : shown
        case "message.complete", "turnDone": line = shown.isEmpty ? "New reply" : shown
        case "turnError": line = shown.isEmpty ? "Couldn’t finish this reply" : "Couldn’t finish: \(errorSentence(preview(text ?? "", max: 150)))"
        case "backgroundDone": line = shown.isEmpty ? "A background task finished" : shown
        default: line = shown.isEmpty ? "Open Hermes HQ to see what’s new" : shown
        }
        return NotificationCopy(title: heading, subtitle: subtitle, body: line)
    }
    /// Who, as an alert may show it anywhere (its copy and the Communication Notifications sender and conversation):
    /// one line, masked, bounded.
    static func sanitized(_ who: NotificationWho) -> NotificationWho {
        let named = { (value: String, max: Int) in clip(redact(oneLine(value)), max: max) }
        return NotificationWho(sender: named(who.sender, 60), chat: named(who.chat, 80), group: named(who.group, 60), bot: who.bot)
    }
    /// What a gateway frame's alert says: a reply's text or why the turn failed; an approval's command, its
    /// description and the request id its Approve/Deny answers.
    static func alert(type: String, payload: [String: Any], now: Date = Date()) -> (kind: String, text: String, about: String, request: String) {
        let string = { (key: String) in (payload[key] as? String).map { String($0.prefix(4000)) } ?? "" }
        if type == "approval.request" { return ("approval.request", string("command"), string("description"), string("request_id")) }
        guard payload["status"] as? String == "error" else { return ("message.complete", string("text").isEmpty ? string("rendered") : string("text"), "", "") }
        let surface = payload["error_surface"] as? [String: Any] ?? [:]
        let error = string("error").isEmpty ? string("text") : string("error")
        let provider = (surface["provider_label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? surface["provider"] as? String
        return ("turnError", NotificationText.errorReason(error, code: surface["code"] as? String, provider: provider, resetsAt: surface["resets_at"] as? Double, now: now), "", "")
    }
    /// Titles the gateway or the app give a chat nobody named: the alert says the bot's name instead.
    static func genericChat(_ title: String) -> Bool {
        ["", "bot chat", "new chat", "new session", "new conversation", "untitled", "untitled chat", "untitled session", "chat"].contains(title.lowercased())
    }
    /// How much of an alert's lines each part stays within (sources: notification-preview.ts PREVIEW_MAX).
    static let previewMax = 180
    static func oneLine(_ text: String) -> String {
        replace(text, "\\s+") { _ in " " }.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// A reply, question or result as its alert shows it: plain text, secrets masked, one line, clipped
    /// (notification-preview.ts notificationPreview; src/notification-preview-cases.json).
    static func preview(_ markdown: String, max: Int = previewMax) -> String {
        clip(oneLine(redact(plainText(redact(markdown)))), max: max)
    }
    /// At most `max` characters, cut at a word when one ends in the last 40%, with an ellipsis.
    static func clip(_ text: String, max: Int = previewMax) -> String {
        guard text.count > max else { return text }
        var cut = String(text.prefix(max - 1))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) >= Int(Double(max) * 0.6) { cut = String(cut[..<space]) }
        return replace(cut, "[\\s,.;:!?\\-–—]+$") { _ in "" } + "…"
    }
    /// What a value request's alert says (its sheet's words, shortened): only a secret request carries a `prompt`, so the
    /// others name what they want instead of all reading "A password or secret is needed".
    static func valueRequestLine(_ kind: PromptKind, params: JSONValue) -> String {
        func value(_ key: String) -> String? {
            params[key]?.string.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        switch kind {
        case .sudo:
            return "Your administrator password is needed"
        case .vaultUnlock:
            return "Unlock \(value("display_name") ?? value("backend") ?? "your password manager") to continue"
        case .vaultSaveLogin:
            return (value("site") ?? value("origin")).map { "Save your \($0) login?" } ?? "Save a login?"
        case .vaultCode:
            return value("site").map { "A verification code for \($0) is needed" } ?? "A verification code is needed"
        case .secret, .approval, .clarify:
            return value("prompt") ?? "A password or secret is needed"
        }
    }
    /// A command awaiting approval: its first line, masked and clipped ("…" when more lines follow).
    static func commandSummary(_ command: String, max: Int = 120) -> String {
        let lines = command.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = lines.first else { return "" }
        let line = clip(replace(redact(first), "\\s+") { _ in " " }, max: max)
        return lines.count > 1 && !line.hasSuffix("…") ? line + " …" : line
    }
    /// Whether an alert showing this command summary may offer Approve: the whole command is on it (no "…": one
    /// line, not clipped). Otherwise the alert only opens the chat, where the whole command is shown.
    /// None of it masked either: a masked value can hide more of the command ("API_KEY=abc;curl … | sh" → "API_KEY=•••• …").
    static func approvable(_ summary: String) -> Bool { !summary.isEmpty && !summary.hasSuffix("…") && !summary.contains(redacted) }
    /// The command an approval alert showed ("Wants to run: <command>"), short enough to quote in a follow-up alert
    /// (UX study #260); "" when the alert showed none (previews off, a description instead).
    static func shownCommand(_ body: String, max: Int = 60) -> String {
        let prefix = "Wants to run: "
        guard body.hasPrefix(prefix) else { return "" }
        return commandSummary(String(body.dropFirst(prefix.count)), max: max)
    }
    /// "Couldn’t finish: <reason>" reads as one sentence: a leading common word loses its capital.
    static func errorSentence(_ reason: String) -> String {
        let text = replace(reason.trimmingCharacters(in: .whitespacesAndNewlines), "\\.+$") { _ in "" }
        let word = text.prefix { $0.isASCII && $0.isLetter }.lowercased()
        return ["usage", "this", "the", "your", "that", "a", "an", "it", "there"].contains(word) ? text.prefix(1).lowercased() + text.dropFirst() : text
    }
    /// Why a turn failed, in a few words (phone-notices.ts turnErrorCopy's words for the ones it knows): a usage
    /// limit and when it lifts, a chat open elsewhere, a known error code, else the gateway's first sentence.
    static func errorReason(_ error: String, code: String? = nil, provider: String? = nil, resetsAt: Double? = nil, now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let limit = "\\b429\\b|usage[_ ]limit|rate[_ ]?limit|quota (?:is )?(?:exhausted|exceeded)|too many requests"
        if code == "rate_limit" || code == "upstream_rate_limit" || matches(error, limit, .caseInsensitive) {
            var at = resetsAt
            if at == nil, let stamp = first(error, "resets?_at[\"'\\s:=]+(\\d{10})\\b", .caseInsensitive) { at = Double(stamp) }
            if at == nil { for wait in ["retry after\\s+(\\d+(?:\\.\\d+)?)\\s*s", "resets?_in_seconds[\"'\\s:=]+(\\d+)", "retry-after[\"'\\s:=]+(\\d+)", "resets? in\\s+(\\d+)\\s*s(?:ec(?:ond)?s?)?\\b"] {
                if let seconds = first(error, wait, .caseInsensitive).flatMap(Double.init) { at = now.timeIntervalSince1970 + seconds; break }
            } }
            let who = provider.flatMap { $0.isEmpty ? nil : $0.prefix(1).uppercased() + $0.dropFirst() + " usage limit" } ?? "Usage limit"
            guard let at, at > now.timeIntervalSince1970 else { return errorSentence("\(who) reached") }
            let when = Date(timeIntervalSince1970: at), format = DateFormatter()
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
            format.locale = locale; format.timeZone = timeZone
            format.setLocalizedDateFormatFromTemplate(calendar.isDate(when, inSameDayAs: now) ? "jmm" : "EEEMMMdjmm")
            return errorSentence("\(who) reached until \(format.string(from: when))")
        }
        if code == "SESSION_NOT_OWNED" || matches(error, "open in another Hermes window|another live owner|SESSION_NOT_OWNED|session has another", .caseInsensitive) {
            return "this chat is open somewhere else"
        }
        let known = ["auth": "the AI service rejected the sign-in", "auth_permanent": "the AI service rejected the sign-in", "billing": "out of credits",
                     "context_overflow": "this conversation is too long", "payload_too_large": "this message is too large", "timeout": "the reply timed out",
                     "stream_drop": "the reply was cut off", "overloaded": "the AI service is overloaded", "server_error": "the AI service had a problem",
                     "model_not_found": "this model isn’t available", "content_policy_blocked": "the AI service declined this request",
                     "disk_full": "the disk on \(HostWord.phrase) is full", "loop_error": "Hermes got stuck in a loop"]
        if let code, let words = known[code] { return words }
        let plain = preview(error, max: 150)
        return errorSentence(first(plain, "^(.{12,}?[.!?])\\s") ?? plain)
    }

    // Markdown as plain text (notification-preview.ts plainText): code blocks are "[code]", images "[image]",
    // links their words; a heading ends with ":" and a list item or table row with "." when more follows.
    static func plainText(_ markdown: String) -> String {
        var lines: [(text: String, end: String)] = []
        var fence = ""
        let source = String(markdown.prefix(4000)).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for raw in source.components(separatedBy: "\n") {
            let open = first(raw, "^\\s*(`{3,}|~{3,})")
            if !fence.isEmpty {
                if let open, open.first == fence.first, open.count >= fence.count, raw.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst(open.count).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fence = "" }
                continue
            }
            if let open { fence = open; lines.append(("[code]", "")); continue }
            var line = raw.trimmingCharacters(in: .whitespacesAndNewlines), end = ""
            if line.isEmpty || matches(line, "^([-*_]\\s*){3,}$") || matches(line, "^\\|?\\s*:?-{3,}:?\\s*(\\|\\s*:?-{3,}:?\\s*)*\\|?$") { continue }
            line = replace(line, "^(>\\s?)+") { _ in "" }
            if matches(line, "^#{1,6}\\s+") { line = replace(line, "^#{1,6}\\s+") { _ in "" }; end = ":" }
            else if matches(line, "^([-*+]|\\d{1,3}[.)])\\s+") { line = replace(replace(line, "^([-*+]|\\d{1,3}[.)])\\s+") { _ in "" }, "^\\[[ xX]\\]\\s+") { _ in "" }; end = "." }
            else if line.hasPrefix("|") { line = replace(replace(line, "^\\||\\|$") { _ in "" }.trimmingCharacters(in: .whitespacesAndNewlines), "\\s*\\|\\s*") { _ in " · " }; end = "." }
            lines.append((line, end))
        }
        var text = lines.enumerated().map { index, line in
            index < lines.count - 1 && !line.end.isEmpty && !matches(line.text, "[.!?:;,…]$") ? line.text + line.end : line.text
        }.joined(separator: "\n")
        text = replace(text, "!\\[[^\\]]*\\]\\([^)]*\\)") { _ in "[image]" }
        text = replace(text, "<img\\b[^>]*>", .caseInsensitive) { _ in "[image]" }
        text = replace(text, "\\[([^\\]]+)\\]\\([^)]*\\)") { $0[1] }
        text = replace(text, "<(https?://[^>\\s]+)>") { $0[1] }
        // Emphasis and tags outside inline code: `__init__` in backticks stays as written.
        var out = "", rest = text[...]
        while let span = rest.range(of: "`[^`\\n]+`", options: .regularExpression) {
            out += inline(String(rest[..<span.lowerBound])) + rest[span].dropFirst().dropLast()
            rest = rest[span.upperBound...]
        }
        return out + inline(String(rest))
    }
    private static func inline(_ text: String) -> String {
        var text = replace(text, "</?(?:br|p|div|li|ul|ol|tr|table|h[1-6]|blockquote|details|summary|pre)\\b[^>]*>", .caseInsensitive) { _ in " " }
        text = replace(text, "</?(?:a|b|i|u|s|em|strong|span|sup|sub|small|code|kbd|mark|del|ins|thead|tbody|td|th)\\b[^>]*>", .caseInsensitive) { _ in "" }
        text = replace(text, "(\\*\\*|__)(?=\\S)([^\\n]+?)(?<=\\S)\\1") { $0[2] }
        text = replace(text, "(?<![A-Za-z0-9_*])\\*(?=\\S)([^*\\n]+?)(?<=\\S)\\*(?![A-Za-z0-9_*])") { $0[1] }
        text = replace(text, "(?<![A-Za-z0-9_])_(?=\\S)([^_\\n]+?)(?<=\\S)_(?![A-Za-z0-9_])") { $0[1] }
        return replace(text, "~~(?=\\S)([^~\\n]+?)(?<=\\S)~~") { $0[1] }
    }

    static let redacted = "••••"
    /// A random-looking run (letters and digits together, 16+ in a row): a vendor prefix alone ("sk-learn-…")
    /// isn't a key. The shapes are fe-platform-policy.ts privateText's (the clipboard's own secret check).
    private static func random(_ text: String) -> Bool {
        matches(text, "\\d") && matches(text, "[A-Za-z]") && matches(text, "[A-Za-z0-9]{16,}")
    }
    // fe-platform-policy.ts redactPrivate, rule for rule and in the same order (alert_copy.py mirrors it too);
    // src/notification-preview-cases.json holds the cases all three agree on.
    // A value: quoted (any length, across lines; a quote never closed runs to the end) or one run up to whitespace.
    // A bare run is judged up to the punctuation that ends a value, but a password or other credential is masked to
    // the whitespace; what a kept value holds is scanned again.
    private static let value = #"(?:"([^"]+)("?)|'([^']+)('?)|([^\s"'`<>]+))"#
    private static let key = #"(?<![A-Za-z0-9_.-])([A-Za-z0-9_.-]{0,40}?(?:pass|pw|secret|token|key|auth|credential|sig)[A-Za-z0-9_.-]{0,40})"#
    private static let argument = #"("[^"]*"?|'[^']*'?|[^\s"']+)"#
    private static let strongKeys: Set<String> = ["password", "passwd", "passphrase", "passcode", "secret", "secrets", "credential", "credentials", "apikey", "accesskey",
                                                  "privatekey", "secretkey", "authtoken", "accesstoken", "refreshtoken", "idtoken", "sessiontoken", "clientsecret", "bearertoken"]
    private static let passwordKeys: Set<String> = ["password", "passwd", "passphrase", "passcode"]
    private static let weakKeys: Set<String> = ["token", "tokens", "key", "keys", "auth", "authorization", "bearer", "signature", "sig"]
    private static let proseWords: Set<String> = ["the", "a", "an", "i", "we", "you", "your", "my", "our", "their", "his", "her", "its", "it", "this", "that", "these", "those",
                                                 "same", "not", "no", "none", "null", "nil", "true", "false", "yes", "required", "optional", "hidden", "redacted", "empty",
                                                 "blank", "unset", "unchanged", "provided", "needed", "missing", "see", "use", "is", "was", "are", "be", "will", "should",
                                                 "must", "can", "set", "reset", "changed", "stored", "saved", "sent", "and", "or", "in", "on", "at", "for", "from", "with",
                                                 "of", "to", "if", "when", "only", "also", "still", "just", "now", "here", "there", "below", "above", "as", "by", "via"]
    /// What a key names: "password" (any literal value is masked, paths too), "strong" (masked unless a path),
    /// "weak" (a token or key: masked only when the value looks opaque), or "".
    static func secretKeyKind(_ key: String) -> String {
        let caps = !matches(key, "[a-z]")
        let split = replace(replace(key, "([a-z0-9])([A-Z])") { "\($0[1])_\($0[2])" }, "([A-Z]+)([A-Z][a-z])") { "\($0[1])_\($0[2])" }.lowercased()
        let parts = replace(split, "[^a-z0-9]+") { _ in " " }.split(separator: " ").map(String.init)
        let pairs = zip(parts, parts.dropFirst()).map { $0 + $1 }
        let last = parts.last ?? ""
        if parts.contains(where: passwordKeys.contains) || last == "pass" || last == "pw" || (last == "pwd" && parts.count > 1)
            || (caps && parts.contains { $0.hasSuffix("password") || $0.hasSuffix("passwd") }) { return "password" }
        if (parts + pairs).contains(where: strongKeys.contains) || (caps && parts.contains { $0.hasSuffix("secret") }) { return "strong" }
        return parts.contains(where: weakKeys.contains) || (caps && parts.contains { $0.hasSuffix("token") }) ? "weak" : ""
    }
    private static func opaque(_ value: String) -> Bool {
        random(value) || (value.count >= 16 && matches(value, "^[A-Fa-f0-9]+$")) || (value.count >= 20 && matches(value, "^[A-Za-z0-9_./+=-]+$"))
            || (value.count >= 12 && ["[a-z]", "[A-Z]", "[0-9]"].filter { matches(value, $0) }.count >= 2)
    }
    /// A variable or lookup names where the secret is ($DB_PASS, ${TOKEN}, process.env.X), not the secret itself.
    private static func reference(_ value: String) -> Bool {
        matches(value, #"^(?:\$\{?[A-Za-z_][A-Za-z0-9_]*\}?$|\$\(|\$\{\{|process\.env\.|os\.(?:getenv|environ))"#)
    }
    private static func filePath(_ value: String) -> Bool {
        matches(value, #"^(?:~|\.{1,2})?/[A-Za-z0-9._/-]*$"#) && !value.split(separator: "/").contains { random(String($0)) }
    }
    private static func maskValue(_ kind: String, _ value: String, quoted: Bool) -> String {
        var core = value
        if !quoted { while let end = core.last, ".,;:)]}".contains(end) { core.removeLast() } }
        guard !kind.isEmpty, matches(core, "[A-Za-z0-9]"), !reference(core) else { return value }
        let keep = kind == "weak" ? !opaque(core) || filePath(core) : (!quoted && proseWords.contains(core.lowercased())) || (kind == "strong" && filePath(core))
        return keep ? value : redacted + value.dropFirst(core.count)
    }
    /// A `value` match (groups 3–7 of `groups`: double-quoted and its close, single-quoted and its close, bare)
    /// rebuilt: masked, or kept and scanned again (a kept run can hold the next key=value).
    private static func valued(_ kind: String, _ groups: [String]) -> String {
        let quoted = { (quote: String, content: String, end: String) -> String in
            let shown = maskValue(kind, content, quoted: true)
            return quote + (shown == content ? assignments(content) : shown) + end
        }
        if !groups[3].isEmpty { return quoted("\"", groups[3], groups[4]) }
        if !groups[5].isEmpty { return quoted("'", groups[5], groups[6]) }
        let value = groups[7], head = String(value.prefix { !",;&".contains($0) })
        if kind == "password" || kind == "strong" {
            // A reference, path, word or mask before the punctuation is kept (the rest is its own text); a credential runs on.
            if !head.isEmpty, maskValue(kind, head, quoted: false) == head { return head + assignments(String(value.dropFirst(head.count))) }
            return maskValue(kind, value, quoted: false)
        }
        return maskValue(kind, head, quoted: false) + assignments(String(value.dropFirst(head.count)))
    }
    private static func assignments(_ text: String) -> String {
        replace(text, key + #"(["']?\s*[:=]\s*)"# + value, .caseInsensitive) { $0[1] + $0[2] + valued(secretKeyKind($0[1]), $0) }
    }
    /// Where a password written as words ends (in characters): two or more words, none reading as prose ("and", "the",
    /// "(…"), up to one that ends a clause. 0 when it is one word (the assignment rule's) or none.
    static func phrase(_ value: String) -> Int {
        var end = 0, words = 0
        for match in regex("\\S+")?.matches(in: value, range: NSRange(value.startIndex..., in: value)) ?? [] {
            guard let range = Range(match.range, in: value) else { break }
            let word = String(value[range])
            var core = word
            while let last = core.last, ".,;:!?)]}".contains(last) { core.removeLast() }
            if !matches(core, "[A-Za-z0-9]") || proseWords.contains(core.lowercased()) || "([{".contains(word.first!) { break }
            words += 1; end = value.distance(from: value.startIndex, to: range.lowerBound) + core.count
            if core != word { break }
        }
        return words >= 2 ? end : 0
    }
    /// A quoted or bare argument masked in place ("-p pw", "--password \"a b\""), or nil when it names no secret.
    private static func maskedArgument(_ value: String) -> String? {
        let quote = value.first.map(String.init).flatMap { $0 == "\"" || $0 == "'" ? $0 : nil } ?? ""
        let closed = !quote.isEmpty && value.count > 1 && value.hasSuffix(quote)
        let content = quote.isEmpty ? value : String(value.dropFirst().dropLast(closed ? 1 : 0))
        guard matches(content, "[A-Za-z0-9]"), !content.hasPrefix("-"), !reference(content) else { return nil }
        return quote.isEmpty ? redacted : quote + redacted + (closed ? quote : "")
    }
    private static func masking(_ groups: [String], head: String, value: String) -> String {
        guard let shown = maskedArgument(value) else { return groups[0] }
        return head + shown
    }
    /// Keys, tokens and passwords masked in place (fe-platform-policy.ts redactPrivate): vendor keys, Telegram/Discord/
    /// npm/SendGrid tokens, JWTs, private keys, Authorization headers and bearer tokens, `-u user:pass`, `--password …`,
    /// `mysql -p…` and `htpasswd -b`, passwords and tokens in URLs, credential query values, "the API key is …", a password
    /// written as words, and every key: value naming a credential.
    static func redact(_ text: String) -> String {
        let mask = { (groups: [String]) in random(groups[0]) ? redacted : groups[0] }
        var out = replace(text, #"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----[\s\S]*?(?:-----END (?:[A-Z0-9]+ )*PRIVATE KEY-----|\z)"#) { _ in redacted }
        out = replace(out, "eyJ[A-Za-z0-9_-]{10,}\\.eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]*") { _ in redacted }
        out = replace(out, #"(?<![0-9])[0-9]{8,10}:[A-Za-z0-9_-]{30,}"#) { _ in redacted }
        out = replace(out, #"(?<![A-Za-z0-9])SG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}"#) { _ in redacted }
        out = replace(out, #"(?<![A-Za-z0-9_-])[MNO][A-Za-z0-9_-]{23,27}\.[A-Za-z0-9_-]{6,7}\.[A-Za-z0-9_-]{27,40}"#, transform: mask)
        for token in ["(?<![A-Za-z0-9])sk-[A-Za-z0-9_-]{20,}", "(?<![A-Za-z0-9])[rs]k_(?:live|test)_[A-Za-z0-9]{20,}", "(?<![A-Za-z0-9])(?:xai-|gsk_|pplx-|r8_|hf_)[A-Za-z0-9]{20,}",
                      "(?<![A-Za-z0-9])(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|glpat-[A-Za-z0-9_-]{20,})", "(?<![A-Za-z0-9])xox[abprs]-[A-Za-z0-9-]{10,}",
                      "(?<![A-Za-z0-9])AIza[0-9A-Za-z_-]{35}", "(?<![A-Za-z0-9])(?:AKIA|ASIA)[0-9A-Z]{16}(?![A-Za-z0-9])", "(?<![A-Za-z0-9])npm_[A-Za-z0-9]{30,}"] { out = replace(out, token, transform: mask) }
        out = replace(out, #"(authorization["']?\s*[:=]\s*["']?(?:basic|bearer|token|digest|negotiate|ntlm|apikey|key)\s+)([^\s"'`,;]+)"#, .caseInsensitive) { matches($0[2], "[A-Za-z0-9]") ? $0[1] + redacted : $0[0] }
        out = replace(out, #"(?<![A-Za-z0-9_])(bearer\s+)([A-Za-z0-9._~+/-]{20,}=*)"#, .caseInsensitive) { $0[1] + redacted }
        // `-u user:pass`, quoted too (the whole quoted password, to the end when never closed).
        out = replace(out, #"(?<!\S)(-u|--user)(\s+|=)(?:"([^\s:"]+):([^"]*)("?)|'([^\s:']+):([^']*)('?)|([^\s:"']+):([^\s"']+))"#) { groups in
            groups[1] + groups[2] + (!groups[3].isEmpty ? "\"\(groups[3]):\(redacted)\(groups[5])" : !groups[6].isEmpty ? "'\(groups[6]):\(redacted)\(groups[8])" : "\(groups[9]):\(redacted)")
        }
        out = replace(out, #"(?<!\S)(--(?:password|passwd|pass|passphrase|token|api-key|apikey|secret|client-secret|auth-token|access-token))(=|\s+)"# + argument) { masking($0, head: $0[1] + $0[2], value: $0[3]) }
        // The short flag whose value is the password: mysql -pS3cret (and its kin), mongo/sshpass/registry logins' -p, redis-cli -a.
        out = replace(out, #"(?<![A-Za-z0-9_.-])((?:mysql[A-Za-z0-9_-]*|mariadb[A-Za-z0-9_-]*|mongo(?:sh|dump|restore|import|export)?|sshpass|(?:docker|podman|nerdctl|buildah|skopeo|oras)\s+login|helm\s+registry\s+login)\b[^\n|;&]{0,200}?\s-p|redis-cli\b[^\n|;&]{0,200}?\s-a)([ \t]*)"# + argument) { masking($0, head: $0[1] + $0[2], value: $0[3]) }
        // htpasswd -b (batch mode): the password is the command's last argument.
        out = replace(out, #"(?<![A-Za-z0-9_.-])(htpasswd\b[^\n|;&]{0,200}?\s-[A-Za-z]*b[A-Za-z]*\b[^\n|;&]{0,300}\s)("[^"]*"?|'[^']*'?|[^\s"'|;&]+)(?=[ \t]*(?:[|;&\n]|\z))"#) { masking($0, head: $0[1], value: $0[2]) }
        out = replace(out, #"(?<![A-Za-z0-9+.-])([a-z][a-z0-9+.-]*://[^\s/:@?#]*):([^\s/?#]*)@"#, .caseInsensitive) { $0[2].isEmpty ? $0[0] : "\($0[1]):\(redacted)@" }
        out = replace(out, #"(?<![A-Za-z0-9+.-])([a-z][a-z0-9+.-]*://)([^\s/:@?#]{8,})@"#, .caseInsensitive) { opaque($0[2]) ? "\($0[1])\(redacted)@" : $0[0] }
        out = replace(out, #"([?&#](?:access_token|refresh_token|id_token|auth_token|session_token|token|api_key|apikey|key|secret|client_secret|password|passwd|pass|pwd|auth|jwt|code|sig|signature|x-amz-signature|x-amz-credential|x-amz-security-token)=)[^&\s#]+"#, .caseInsensitive) { $0[1] + redacted }
        // Prose is only masked where the value can't be a word: quoted, opaque, or a password with a digit or symbol.
        out = replace(out, #"(?<![A-Za-z0-9_])(api[ _-]?key|access[ _-]?key|secret[ _-]?key|access[ _-]?token|auth[ _-]?token|password|passwd|passcode|passphrase|token|secret)(\s+(?:is|was)\s*:?\s+)"# + value, .caseInsensitive) { groups in
            let quoted = groups[7].isEmpty
            var core = quoted ? groups[3] + groups[5] : groups[7]
            if !quoted { while let end = core.last, ".,;:)]}".contains(end) { core.removeLast() } }
            let hide = quoted || opaque(core) || (matches(groups[1], "pass", .caseInsensitive) && matches(core, "[^A-Za-z]") && core.count >= 4)
            return hide ? groups[1] + groups[2] + valued("password", groups) : groups[0]
        }
        // "password = correct horse battery staple": after `:` or a spaced `=`, a password written as words.
        out = replace(out, key + #"(["']?(?:[ \t]*:[ \t]*|[ \t]+=[ \t]*|=[ \t]+))([^\s"'`<>][^\n<`]*)"#, .caseInsensitive) { groups in
            let end = secretKeyKind(groups[1]) == "password" ? phrase(groups[3]) : 0
            return end > 0 ? groups[1] + groups[2] + redacted + String(groups[3].dropFirst(end)) : groups[0]
        }
        return assignments(out)
    }
    /// Compiled once: an alert's text goes through every rule twice, and building a pattern costs more than running it.
    private final class Patterns: @unchecked Sendable {
        let lock = NSLock()
        var compiled: [String: NSRegularExpression] = [:]
    }
    private static let patterns = Patterns()
    static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        let key = "\(options.rawValue):\(pattern)"
        patterns.lock.lock(); defer { patterns.lock.unlock() }
        if let known = patterns.compiled[key] { return known }
        guard let made = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        patterns.compiled[key] = made
        return made
    }
    static func matches(_ text: String, _ pattern: String, _ options: NSRegularExpression.Options = []) -> Bool {
        regex(pattern, options)?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
    /// The first capture group of the first match.
    static func first(_ text: String, _ pattern: String, _ options: NSRegularExpression.Options = []) -> String? {
        guard let regex = regex(pattern, options),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
    /// Every match replaced by `transform(groups)` (group 0 is the whole match; an unmatched group is "").
    static func replace(_ text: String, _ pattern: String, _ options: NSRegularExpression.Options = [], transform: ([String]) -> String) -> String {
        guard let regex = regex(pattern, options) else { return text }
        var out = "", last = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text) else { continue }
            let groups = (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
            out += text[last..<whole.lowerBound] + transform(groups)
            last = whole.upperBound
        }
        return out + text[last...]
    }
}
