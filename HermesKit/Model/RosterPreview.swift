// What a Bots row's second line says: the cleaned last-message preview (spec 02 §6.3–6.4). Ported from
// `S/fe-lists-r6.ts` (rowPreview, rosterPreview), `S/ui-bots/bot-preview.ts` (stripMarkdown, cleanPreviewText,
// sourcePreview, botPreview), `HB/row-helpers.ts` (previewKind) and the cron title helpers. Pure.

import Foundation

/// A JS-flavoured regular expression (ICU through NSRegularExpression): `test`, `replace` (first match, like a JS
/// regex without `g`) and `replaceAll` (with `g`), `$1` templates.
nonisolated struct JSRegex: @unchecked Sendable {
    let regex: NSRegularExpression

    init(_ pattern: String, _ flags: String = "") {
        var options: NSRegularExpression.Options = []
        if flags.contains("i") { options.insert(.caseInsensitive) }
        if flags.contains("m") { options.insert(.anchorsMatchLines) }
        regex = try! NSRegularExpression(pattern: pattern, options: options)
    }

    func test(_ s: String) -> Bool {
        regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    func replaceAll(_ s: String, _ template: String) -> String {
        regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    func replace(_ s: String, _ template: String) -> String {
        let ns = s as NSString
        guard let m = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return s }
        let replacement = regex.replacementString(for: m, in: s, offset: 0, template: template)
        return ns.replacingCharacters(in: m.range, with: replacement)
    }

    /// Capture groups of the first match ("" for a group that did not take part); nil when there is no match.
    func exec(_ s: String) -> (range: NSRange, groups: [String])? {
        let ns = s as NSString
        guard let m = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var groups: [String] = []
        for i in 0..<m.numberOfRanges {
            let r = m.range(at: i)
            groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
        }
        return (m.range, groups)
    }
}

nonisolated enum RosterPreview {
    // MARK: rowPreview (S/fe-lists-r6.ts:5-46)

    private static let modelSwitch = JSRegex(#"^\s*\[System: The active model for this chat has changed to\b\s*(\S*)"#, "i")
    private static let modelSwitchCut = JSRegex(#"^\s*\[System: The active model for this chat\b"#, "i")
    private static let machineNote = JSRegex(#"^\s*\[(?:System note|Runtime note):\s*|^\s*\[SYSTEM\]\s*"#, "i")
    private static let kanbanDispatch = JSRegex(#"^\s*work kanban task t_[0-9a-z]+\s*$"#, "i")
    private static let machineTag = JSRegex(#"^\s*<[a-z][\w-]*>"#, "i")
    private static let machineTagPair = JSRegex(#"<([a-z][\w-]*)>[\s\S]*?(?:</\1>|\z)"#, "i")
    private static let viaFollows = JSRegex(#"^\s+via\b"#, "i")
    private static let closingBracket = JSRegex(#"\]\s*$"#)
    private static let leadingAt = JSRegex(#"^@"#)

    /// What a row shows for a preview that is a machine note: "Model changed to <label>" ("Model changed" when the
    /// preview was cut inside the id), a note's own words without its tag, "Kanban task" for a worker's dispatch
    /// prompt, no leading machine tags. Any other preview comes back as it is.
    static func rowPreview(_ text: String?, model: (String) -> String = { $0 }) -> String {
        let value = text ?? ""
        let ns = value as NSString
        if let m = modelSwitch.exec(value) {
            let rest = ns.substring(from: m.range.location + m.range.length)
            let raw = m.groups[1]
            var id = raw
            // The note's own "." and closing "]" go; an id's own brackets ("claude-opus-5-5[1m]") stay.
            while id.hasSuffix("]"), id.filter({ $0 == "]" }).count > id.filter({ $0 == "[" }).count { id.removeLast() }
            while id.hasSuffix(".") { id.removeLast() }
            let viaFollows = Self.viaFollows.test(rest)
            let cutShort = raw.hasSuffix("...") || raw.hasSuffix("…")
            let whole = !id.isEmpty && (viaFollows || (!cutShort && (raw.hasSuffix(".") || raw.hasSuffix("]"))))
            return whole ? "Model changed to \(model(id))" : "Model changed"
        }
        if modelSwitchCut.test(value) { return "Model changed" }
        if machineNote.test(value) {
            let stripped = closingBracket.replace(machineNote.replace(value, ""), "")
            return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if kanbanDispatch.test(value) { return "Kanban task" }
        if machineTag.test(value) {
            return machineTagPair.replaceAll(value, "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    // MARK: stripMarkdown / cleanPreviewText (S/ui-bots/bot-preview.ts:24-63)

    private static let markdownSteps: [(JSRegex, String)] = [
        (JSRegex(#"```[\s\S]*?(?:```|\z)"#), " "),
        (JSRegex(#"`([^`\n]*)`"#), "$1"),
        (JSRegex(#"!\[([^\]]*)\]\([^)]*\)"#), "$1"),
        (JSRegex(#"\[([^\]]*)\]\([^)]*\)"#), "$1"),
        (JSRegex(#"(\*\*|__)(.*?)\1"#), "$2"),
        (JSRegex(#"(^|\s)[*_](\S(?:.*?\S)?)[*_](?=\s|\z|[.,;:!?])"#), "$1$2"),
        (JSRegex(#"~~(.*?)~~"#), "$1"),
        // The gateway cuts previews at 80 characters, often inside a pair: the opening half stays behind.
        (JSRegex(#"\*\*|__|~~|`+"#), ""),
        (JSRegex(#"^\s{0,3}#{1,6}\s+"#, "m"), ""),
        (JSRegex(#"^\s{0,3}>\s?"#, "m"), ""),
        (JSRegex(#"^\s{0,3}[-*+]\s+"#, "m"), ""),
        (JSRegex(#"^\s{0,3}\|?(?:\s*:?-{3,}:?\s*\|)+\s*$"#, "m"), " "),
        (JSRegex(#"\s*\|\s*"#), " · "),
        (JSRegex(#"\s+"#), " "),
        (JSRegex(#"(?:\s*·\s*){2,}"#), " · "),
        (JSRegex(#"^(?:\s*·\s*)+|(?:\s*·\s*)+\z"#), ""),
    ]

    static func stripMarkdown(_ text: String) -> String {
        var out = text
        for (regex, template) in markdownSteps { out = regex.replaceAll(out, template) }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let note = JSRegex(#"\[\s*(?:system(?: note)?|runtime note|note to self|context|internal)\s*:[^\]]*(?:\]|\z)"#, "i")
    private static let sentinel = JSRegex(#"\[\s*(?:SILENT|CRON_FAILURE|NO_REPLY|SYSTEM)\s*\]"#, "i")
    private static let scheduler = JSRegex(#"\n?#{1,3}\s*Run Context[\s\S]*\z"#, "i")
    private static let silentOnly = JSRegex(#"^\s*\[\s*SILENT\s*\]\s*\z"#, "i")

    /// The machine-free text of a preview ("" when nothing human is left); a model switch reads as the chat's marker.
    /// A bare [SILENT] is "" too (UX study #210): the chat hides that line unless it answers your own message, so the
    /// list no longer says "Nothing to report" for it; a bot row shows its role line instead (`botPreview`).
    static func cleanPreviewText(_ raw: String?, model: (String) -> String = { $0 }) -> String {
        let value = raw ?? ""
        if Hydration.isSilenceMarker(value) { return "" }   // a bare NO_REPLY, as the chat hides it
        if modelSwitchCut.test(value) { return rowPreview(value, model: model).trimmingCharacters(in: .whitespacesAndNewlines) }
        return stripMarkdown(sentinel.replaceAll(note.replaceAll(scheduler.replace(value, ""), " "), " "))
    }

    /// [botsaid] A message another bot delivered ("Message from agent 'ivy': …").
    static func isDelivery(_ text: String) -> Bool { delivery.test(text) }

    /// [botsaid] A machine note rather than words: a model switch, a "[System note: …]", a leading machine tag.
    static func isMachineNote(_ text: String) -> Bool {
        modelSwitchCut.test(text) || machineNote.test(text) || kanbanDispatch.test(text) || machineTag.test(text)
    }

    /// The preview is a bare [SILENT] reply (UX study #210).
    static func isSilentOnly(_ raw: String?) -> Bool { silentOnly.test(raw ?? "") || Hydration.isSilentWords(raw ?? "") }

    /// The gateway's own words behind a shown preview (`sourcePreview`): when the row was handed rowPreview's reading
    /// of a session's preview, the raw preview; anything else stays as given.
    static func sourcePreview(_ profile: RosterProfile, shown: String) -> String {
        let want = shown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !want.isEmpty else {
            // UX study #210: a silent reply reads as nothing; the raw [SILENT] goes on so the row knows the bot spoke.
            if let canonical = profile.canonicalSession, RosterRules.holdsMessages(canonical) {
                return isSilentOnly(canonical.preview) ? canonical.preview ?? shown : shown
            }
            return shown
        }
        let raw = profile.canonicalSession?.preview ?? ""
        if !raw.isEmpty, raw != shown, rowPreview(raw).trimmingCharacters(in: .whitespacesAndNewlines) == want { return raw }
        return shown
    }

    // MARK: Delivery sender and prefix

    private static let a2a = JSRegex(#"^Message from (?:agent '([^']+)'|🤖\s*([^\s(@]+))"#, "i")
    private static let delivery = JSRegex(#"^\s*(?:\[\s*)?Message from (?:agent '[^']+'|🤖[^:\]]+)\]?:?\s*"#, "i")

    /// The sender handle of a bot-to-bot delivery preview (`previewKind`, `HB/row-helpers.ts:19-55`); `default` → `hermes`.
    static func deliveryHandle(_ preview: String?) -> String? {
        let text = (preview ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let m = a2a.exec(text) else { return nil }
        let sender = (m.groups[1].isEmpty ? m.groups[2] : m.groups[1]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return sender.isEmpty ? nil : RosterRules.handle(forProfile: sender)
    }

    nonisolated struct Parts: Sendable, Hashable {
        /// "From Inbox:" or "Draft:", drawn ahead of the text in the label colour; nil for none.
        var prefix: String?
        var text: String
        /// The preview had nothing human left: `text` is the role line or "No messages yet".
        var isFallback: Bool
        /// One line for VoiceOver and search.
        var line: String { prefix.map { "\($0) \(text)" } ?? text }
    }

    /// [botslist] The lead of a row whose last send may never have arrived (drawn red; `row-pending.ts`).
    static let notDeliveredPrefix = "Not Delivered:"

    /// `botPreview` (`S/ui-bots/bot-preview.ts:79-90`). The phone never passes `fromYou`, so rows never say "You:".
    static func botPreview(text: String?, fromBot: String?, draft: Bool = false, role: String?, bot: String = "",
                           model: (String) -> String = { $0 }) -> Parts {
        let raw = text ?? ""
        // [botslist] A cron run reads as its job and report ("Inbox watch: 1 new inbound email"), never the wrapper;
        // "Inbox watch ran" when the gateway's cut left no report (owner, 2026-10-23).
        if !draft, let run = CronDeliveries.preview(raw) {
            if let body = run.body, isSilentOnly(body) { return Parts(prefix: nil, text: RosterText.nonBlank(role) ?? "", isFallback: true) }
            let name = CronDeliveries.jobName(run.job, bot: bot)
            let words = run.body.map { cleanPreviewText(CronDeliveries.withoutJobLead($0, job: run.job), model: model) } ?? ""
            return words.isEmpty ? Parts(prefix: nil, text: "\(name) ran", isFallback: false)
                                 : Parts(prefix: "\(name):", text: words, isFallback: false)
        }
        let delivered = delivery.test(raw)
        let body = cleanPreviewText(delivery.replace(raw, ""), model: model)
        let sender = fromBot.map { leadingAt.replace($0.trimmingCharacters(in: .whitespacesAndNewlines), "") }
        if draft { return Parts(prefix: "Draft:", text: body, isFallback: false) }
        if !body.isEmpty {
            if delivered || !(fromBot ?? "").isEmpty, let sender, !sender.isEmpty { return Parts(prefix: "From \(sender):", text: body, isFallback: false) }
            return Parts(prefix: nil, text: body, isFallback: false)
        }
        // UX study #210: the newest message is a silent reply (the roster holds no older one): the role line, never
        // "No messages yet" (the bot has spoken) nor "Nothing to report" (the chat hides it).
        if isSilentOnly(delivery.replace(raw, "")) { return Parts(prefix: nil, text: RosterText.nonBlank(role) ?? "", isFallback: true) }
        return Parts(prefix: nil, text: RosterText.nonBlank(role) ?? "No messages yet", isFallback: true)
    }

    // MARK: Cron run titles (S/fe-lists-r5.ts:170-177, S/audit-c-format.ts:481-506)

    private static let runStamp = JSRegex(
        #"\s+[·•-]\s+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\.?\s+\d{1,2}(?:,?\s+\d{4})?(?:,?\s+\d{1,2}:\d{2}(?::\d{2})?(?:\s*[AP]M)?)?$"#, "i")
    private static let slugName = JSRegex(#"^[a-z0-9]+(?:[-_][a-z0-9]+)+$"#)
    private static let acronyms: Set<String> = ["ai", "api", "ap", "ci", "cpu", "crm", "csv", "dm", "dns", "gpu", "http", "id", "ios",
        "json", "kpi", "llm", "mcp", "os", "pdf", "pr", "qa", "rss", "seo", "sms", "sql", "ssh", "tts", "ui", "url", "ux"]
    private static let iosWords = ["ios": "iOS", "macos": "macOS", "iphone": "iPhone", "ipad": "iPad"]

    /// "northwind-shipstation-check · Sep 27 17:00" → "northwind-shipstation-check" for a cron run.
    static func recentRunTitle(_ title: String, source: String?) -> String {
        guard source?.lowercased() == "cron" else { return title }
        let cut = runStamp.replace(title, "").trimmingCharacters(in: .whitespacesAndNewlines)
        return cut.isEmpty ? title : cut
    }

    /// "morning-inbox-triage" → "Morning inbox triage"; a name that is already words stays.
    static func humanJobTitle(_ name: String) -> String {
        let text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard slugName.test(text) else { return name }
        let words = text.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        return words.enumerated().map { index, word in
            if let known = iosWords[word] { return known }
            if acronyms.contains(word) { return word.uppercased() }
            return index == 0 ? word.prefix(1).uppercased() + word.dropFirst() : word
        }.joined(separator: " ")
    }
}
