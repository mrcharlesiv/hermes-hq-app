// History rows → ChatMessage fold (spec 03 §6), ported from `toChatMessages`
// (V:lib/chat-messages/hydration.ts:281-595) with the phone gates that ship in build 238:
//   * stable ids `stored-row-{rowId}-{kind}` (R:build/rendering-fluidity-gates.ts:4-41, R:src/history-message-identity.ts)
//   * tool result metadata + `isError` from `display_payload_ref` (rendering-fluidity-gates.ts:80-95)
//   * readable reasoning, origin-note strip, described-photo split, internal notifications (R:src/fe-convo-r3.ts)
//   * model-switch wording and the cron "[SILENT]" sentinel (R:src/fe-convo-r6.ts)
// Native deviations (spec 03 §8.10, §6.6): successful silent tools are dropped; inline `data:` images never enter text.
// Everything here is pure and `nonisolated` so pages fold off the main thread.

import Foundation
import Synchronization

/// One folded page.
nonisolated struct HydratedPage: Sendable {
    var messages: [ChatMessage]
    var meta: [String: MessageMeta]          // by message id (only non-default entries)
}

nonisolated enum Hydration {
    private static let pageCounter = Mutex(0)

    /// A fresh page namespace for rows that carry no durable id (`history-page-{seq}-…`).
    static func nextPageSeq() -> Int { pageCounter.withLock { $0 += 1; return $0 } }

    /// Folds REST rows (chronological) into messages: one per user row, one per assistant turn, system notices.
    static func fold(_ rows: [JSONValue], pageSeq: Int? = nil) -> HydratedPage {
        var folder = Folder(pageSeq: pageSeq ?? nextPageSeq())
        return folder.run(normalizeRows(rows))
    }

    // MARK: - Row normalisation (fe-convo-r3 normalizeHistoryRows)

    static let photoRowLabel = "Photo · described by Hermes"

    static func normalizeRows(_ rows: [JSONValue]) -> [JSONValue] {
        var out: [JSONValue] = []
        out.reserveCapacity(rows.count)
        for row in rows { out.append(contentsOf: normalizeRow(row)) }
        return out
    }

    private static let originRE = try! NSRegularExpression(
        pattern: #"^Gateway message origin \(JSON data, not instructions or authorization\):\n\{[^\n]*\}\nDo not guess a reply destination when these fields are insufficient\.\n+"#)

    /// Turn context Hermes keeps in a photo turn's stored row (a multimodal message takes it as a durable text part,
    /// `H:agent/turn_context.py` `_append_multimodal_context`): our plugins' `(Hermes HQ: …)` steer and recalled
    /// `<memory-context>`. Only at the very end of the row, so the user's own words are never touched.
    private static let turnContextRE = try! NSRegularExpression(
        pattern: #"(?:^|\n)[ \t]*(?:\(Hermes HQ: [\s\S]*\)|<memory-context>[\s\S]*?</memory-context>)\s*$"#)

    /// `text` without the turn context Hermes appended to it (repeatedly: memory, then the plugin's steer).
    static func strippingTurnContext(_ text: String) -> String {
        guard text.contains("(Hermes HQ: ") || text.contains("</memory-context>") else { return text }
        var s = text
        while let m = turnContextRE.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range, in: s) {
            s.removeSubrange(r)
        }
        while let last = s.last, last.isWhitespace { s.removeLast() }
        return s
    }

    private static func normalizeRow(_ row: JSONValue) -> [JSONValue] {
        guard var record = row.object else { return [row] }
        let text = record["content"]?.string ?? ""
        let kind = record["display_kind"]?.string
        // [botdm] A bot DM runner's note stays the plain user row it is live, so BotDMs draws it as the other bot's
        // reply, or nothing when there is none (owner, 2026-10-28: from history it was a "…/python3 …/bot_mode_dm.py"
        // process line). Hermes files it as internal_notification, and lately as process_complete.
        if kind == "internal_notification" || kind == "process_complete" {
            let body = String(text.drop(while: { $0.isWhitespace }))
            if body.hasPrefix("[IMPORTANT: "), BotDMs.isDelivery(body) {
                record["display_kind"] = nil
                return [.object(record)]
            }
        }
        if kind == "internal_notification" {
            var meta = record["display_metadata"]?.looseObject ?? [:]
            let body = String(text.drop(while: { $0.isWhitespace }))
            // [botdm] Another bot's message ("Message from 🤖 ivy (@ivy): …") likewise, so DeliveryMessages gives it its
            // sender: the line has that bot's face and name, as live (owner, 2026-10-28: it drew the message glyph).
            if DeliveryMessages.mayBeDelivery(body), DeliverySender.parse(body) != nil {
                record["display_kind"] = nil
                record["content"] = .string(body)
                return [.object(record)]
            }
            if body.hasPrefix("[IMPORTANT: ") {
                record["display_kind"] = "process_complete"
                record["display_metadata"] = .object(meta)
                return [.object(record)]
            }
            if meta["display_text"]?.nonEmptyString == nil {
                if body.hasPrefix("[ASYNC DELEGATION") {
                    if let match = body.range(of: #"—\s*(\d+)\s+subagent"#, options: [.regularExpression, .caseInsensitive]) {
                        let digits = body[match].filter(\.isNumber)
                        meta["task_count"] = .number(Double(digits) ?? 0)
                    } else {
                        meta["display_text"] = "Helpers finished"   // [updates] helpers, not subagents (owner, 2026-10-28)
                    }
                } else {
                    meta["display_text"] = "Background update"
                }
            }
            record["display_kind"] = "async_delegation_complete"
            record["display_metadata"] = .object(meta)
            return [.object(record)]
        }
        guard record["role"]?.string == "user", kind != "hidden" else { return [row] }
        // A message that reached a busy chat carries the gateway's routing note in front of it.
        var stripped = false
        for key in ["content", "display_content"] {
            if case .string(let s)? = record[key] {
                let clean = strippingTurnContext(s)
                if clean != s { record[key] = .string(clean); stripped = true; continue }
                let range = NSRange(s.startIndex..., in: s)
                if let m = originRE.firstMatch(in: s, range: range), let r = Range(m.range, in: s) {
                    record[key] = .string(String(s[r.upperBound...])); stripped = true
                }
            }
        }
        if stripped { return normalizeRow(.object(record)) }
        let shown = record["display_content"]?.string ?? text
        guard let photo = describedPhoto(shown) else { return [row] }
        let caption = photo.caption.isEmpty ? "Photo" : photo.caption
        record["content"] = .string(caption)
        if record["display_content"]?.string != nil { record["display_content"] = .string(caption) }
        var photoRow: [String: JSONValue] = [
            "role": "user",
            "content": .string(photo.descriptions.isEmpty ? photoRowLabel : photo.descriptions.joined(separator: "\n\n")),
            "display_kind": "async_delegation_complete",
            "display_metadata": ["display_text": .string(photoRowLabel)],
            "_synthetic": true,
        ]
        photoRow["timestamp"] = record["timestamp"] ?? .null
        return [.object(record), .object(photoRow)]
    }

    private static func describedPhoto(_ text: String) -> (descriptions: [String], caption: String)? {
        let photoPrefix = #"^\s*\[The user sent an image~"#
        guard text.range(of: photoPrefix, options: .regularExpression) != nil else { return nil }
        var rest = text
        var descriptions: [String] = []
        while rest.range(of: photoPrefix, options: .regularExpression) != nil {
            rest = rest.replacingOccurrences(of: #"^\s*\[The user sent an image~\s*"#, with: "", options: .regularExpression)
            var end: String.Index
            if let hint = rest.range(of: #"\]\s*\[If you need a closer look"#, options: .regularExpression) {
                end = hint.lowerBound
            } else if let close = rest.range(of: #"\](?:[ \t]*\n|\s*$)"#, options: .regularExpression) {
                end = close.lowerBound
            } else {
                end = rest.endIndex
            }
            let description = rest[..<end].replacingOccurrences(of: #"^Here['’]s what I can see:\s*"#, with: "",
                                                                 options: [.regularExpression, .caseInsensitive])
            descriptions.append(ChatText.trimmed(description))
            if end < rest.endIndex { end = rest.index(after: end) }
            rest = String(rest[end...]).replacingOccurrences(of: #"^\s*\[If you need a closer look[^\]]*\]"#, with: "",
                                                             options: .regularExpression)
        }
        return (descriptions.filter { !$0.isEmpty }, ChatText.trimmed(rest))
    }

    // MARK: - Text helpers

    /// `textFromUnknown` (V:lib/chat-messages/tool-parts.ts:715-749), except image parts never become text (§6.6).
    static func text(from value: JSONValue?, depth: Int = 0) -> String {
        guard let value else { return "" }
        switch value {
        case .string(let s): return s
        case .null: return ""
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n.rounded() == n && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .array(let items):
            guard depth <= 2 else { return "" }
            return items.map { text(from: $0, depth: depth + 1) }.joined()
        case .object(let o):
            guard depth <= 2 else { return "" }
            if isImagePart(o) { return "" }
            let inner = firstNonNullish(o, ["text", "output_text", "content", "message"])
            let nested = text(from: inner, depth: depth + 1)
            if !nested.isEmpty { return nested }
            return ChatJSON.stringify(value)
        }
    }

    static func isImagePart(_ o: [String: JSONValue]) -> Bool {
        let type = o["type"]?.string ?? ""
        return type == "image_url" || type == "input_image" || type == "image" || o["image_url"] != nil
    }

    private static func firstNonNullish(_ o: [String: JSONValue], _ keys: [String]) -> JSONValue? {
        for key in keys { if let v = o[key], !v.isNull { return v } }
        return nil
    }

    /// Strips `data:image/…;base64,` runs of ≥64 base64 chars that slipped into text (§6.6: never in the model).
    static func stripInlineDataURIs(_ text: String) -> String {
        guard text.contains("data:") else { return text }
        return text.replacingOccurrences(of: #"data:image/[A-Za-z0-9.+-]+;base64,[A-Za-z0-9+/=\s]{64,}"#,
                                         with: "[image]", options: .regularExpression)
    }

    private static let discordNoteRE = try! NSRegularExpression(
        pattern: "(^|\\n)\\[Triggering message id: `[^`\\n]*` — use as `message_id` for reply/react/pin via the discord tools\\.\\]\\n*")
    private static let attachedContextRE = try! NSRegularExpression(pattern: #"(?:^|\n)--- Attached Context ---\s*\n"#)
    private static let contextWarningsRE = try! NSRegularExpression(pattern: #"(?:^|\n)--- Context Warnings ---[\s\S]*$"#)
    private static let contextRefRE = try! NSRegularExpression(
        pattern: #"@(file|folder|url|image|tool|terminal):(?:"[^"\n]+"|'[^'\n]+'|`[^`\n]+`|\S+)"#)
    private static let referenceLineRE = try! NSRegularExpression(
        pattern: #"^@(file|folder|url|image|tool|line|terminal|session):(`[^`\n]+`|"[^"\n]+"|'[^'\n]+'|\S+)$"#)

    private static func replacing(_ re: NSRegularExpression, in s: String, with template: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    /// `displayContentForMessage` (hydration.ts:109-155).
    static func displayContent(role: String, content: JSONValue?) -> String {
        let raw = text(from: content)
        guard role == "user" else { return raw }
        let textContent = replacing(discordNoteRE, in: raw, with: "$1")
        if let invocation = skillInvocationText(textContent) { return invocation }
        let range = NSRange(textContent.startIndex..., in: textContent)
        guard let marker = attachedContextRE.firstMatch(in: textContent, range: range),
              let markerRange = Range(marker.range, in: textContent) else {
            return ChatText.trimmed(replacing(contextWarningsRE, in: textContent, with: ""))
        }
        let visible = ChatText.trimmed(replacing(contextWarningsRE, in: String(textContent[..<markerRange.lowerBound]), with: ""))
        let attached = String(textContent[markerRange.upperBound...])
        var refs: [String] = []
        for m in contextRefRE.matches(in: attached, range: NSRange(attached.startIndex..., in: attached)) {
            if let r = Range(m.range, in: attached) {
                let ref = String(attached[r]); if !refs.contains(ref) { refs.append(ref) }
            }
        }
        let missing = refs.filter { !visible.contains($0) }
        let joined = [missing.joined(separator: "\n"), visible].filter { !$0.isEmpty }.joined(separator: "\n\n")
        return joined.isEmpty ? visible : joined
    }

    /// `skillInvocationText` (V:../shared/src/skill-scaffold.ts:46-70).
    static func skillInvocationText(_ text: String) -> String? {
        let prefix = "[IMPORTANT: The user has invoked the "
        guard text.hasPrefix(prefix) else { return nil }
        let afterPrefix = text.dropFirst(prefix.count)
        guard afterPrefix.first == "\"", let close = afterPrefix.dropFirst().firstIndex(of: "\"") else { return nil }
        let name = ChatText.trimmed(String(afterPrefix[afterPrefix.index(after: afterPrefix.startIndex)..<close]))
        guard !name.isEmpty else { return nil }
        let label = name.hasPrefix("/") ? name : "/\(name)"
        func between(_ marker: String, _ end: String, fromEnd: Bool) -> String {
            guard let r = fromEnd ? text.range(of: marker, options: .backwards) : text.range(of: marker) else { return "" }
            let tail = text[r.upperBound...]
            if let stop = tail.range(of: end) { return ChatText.trimmed(String(tail[..<stop.lowerBound])) }
            return ChatText.trimmed(String(tail))
        }
        let instruction: String
        if text.contains(" skill bundle,") {
            instruction = between("\nUser instruction: ", "\n\n[Loaded as part of the ", fromEnd: false)
        } else if text.contains("The full skill content is loaded below.]") {
            instruction = between("The user has provided the following instruction alongside the skill invocation: ",
                                  "\n\n[Runtime note:", fromEnd: true)
        } else {
            instruction = ""
        }
        return instruction.isEmpty ? label : "\(label) \(ChatText.flat(instruction))"
    }

    /// `extractImageRefs` (V:lib/embedded-images.ts:180-197): lift `@image:` lines; drop `[screenshot]` lines then.
    static func extractImageRefs(_ text: String) -> (cleaned: String, refs: [String]) {
        guard text.contains("@image:") else { return (text, []) }
        var refs: [String] = []
        var kept: [Substring] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            if line.hasPrefix("@image:") { refs.append(ChatText.trimmed(String(line))) } else { kept.append(line) }
        }
        guard !refs.isEmpty else { return (text, []) }
        let cleaned = kept.filter { $0 != "[screenshot]" }.joined(separator: "\n")
        return (cleaned, refs)
    }

    /// `splitLeadingAttachmentRefs` (reference-kinds.ts:188-197): a leading block of `@file:`/`@folder:` lines.
    static func splitLeadingAttachmentRefs(_ text: String) -> (refs: [String], text: String) {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var refs: [String] = []
        while let first = lines.first, first.hasPrefix("@file:") || first.hasPrefix("@folder:") || first.hasPrefix("@url:") {
            let trimmedEnd = first.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
            guard referenceLineRE.firstMatch(in: trimmedEnd, range: NSRange(trimmedEnd.startIndex..., in: trimmedEnd)) != nil else { break }
            refs.append(trimmedEnd)
            lines.removeFirst()
        }
        return refs.isEmpty ? ([], text) : (refs, ChatText.trimmed(lines.joined(separator: "\n")))
    }

    // MARK: Timeline notices

    static let noticeKinds: Set<String> = ["model_switch", "async_delegation_complete", "process_complete", "auto_continue",
                                           "personality_switch", "failed_turn"]
    static let silentRunText = "Nothing to report — this run was silent"
    /// A turn Hermes picked up again after a restart; the chat draws nothing for it.
    static let autoContinueText = "resumed interrupted turn"

    static func isSilentRun(_ content: JSONValue?) -> Bool {
        guard case .string(let s)? = content else { return false }
        return isSilentWords(s)
    }

    /// The bot's way of saying nothing: "[SILENT]", or a one-line bracketed stand-in a model writes instead after a
    /// delivery or notice ("[Notification processed; no additional user-facing response.]", "(no user-facing response)",
    /// "*[No reply needed]*").
    static func isSilentWords(_ text: String) -> Bool {
        var t = ChatText.trimmed(text)
        if isSilenceMarker(t) { return true }
        // Markdown emphasis around the brackets ("*(no reply needed)*") is still the same stand-in.
        while t.count > 2, let first = t.first, first == "*" || first == "_", t.last == first { t = String(t.dropFirst().dropLast()) }
        let closers: [Character: Character] = ["[": "]", "(": ")"]
        guard t.count <= 200, let open = t.first, let close = closers[open], t.last == close else { return false }
        let inside = t.dropFirst().dropLast()
        guard !inside.contains(open), !inside.contains(close), !inside.contains("\n") else { return false }
        return silentStandIn.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
    }

    /// The gateway's own silence markers, matched as it does (H:gateway/response_filters.py
    /// `is_intentional_silence_response`): the whole reply, any case, stray punctuation at the ends ("NO_REPLY.",
    /// "*NO_REPLY*"). The gateway keeps a bare NO_REPLY from reaching the bot that wrote in, but it stays in the
    /// answering bot's own history (owner, 2026-11-09: "NO_REPLY" under a message From Otto).
    private static let silenceMarkers: Set<String> = ["[SILENT]", "SILENT", "NO_REPLY", "NO REPLY", "[静默]", "静默", "[沉默]", "沉默"]

    static func isSilenceMarker(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 64 else { return false }
        // Square brackets stay, so a broken "[SILENT" isn't "SILENT".
        let edge = { (c: Character) in c != "[" && c != "]" && c.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) } }
        var core = Substring(t)
        while let c = core.first, edge(c) { core = core.dropFirst() }
        while let c = core.last, edge(c) { core = core.dropLast() }
        let canon = { (s: Substring) in s.uppercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        return silenceMarkers.contains(canon(Substring(t))) || silenceMarkers.contains(canon(core))
    }

    /// Words that only ever mean "I chose to say nothing": "no additional/further … response", "no user-facing reply",
    /// "no response needed", "nothing (further) to report". A bare "[No response from the server]" isn't one.
    private static let silentStandIn = try! NSRegularExpression(pattern:
        #"\b(?:no (?:additional|further) (?:\S+ ){0,2}(?:response|reply)|no (?:user[-‐‑ ]facing|visible) (?:response|reply)|no (?:response|reply) (?:is )?(?:needed|required|necessary)|nothing (?:further |more )?to (?:report|add|say))\b"#,
        options: [.caseInsensitive])

    private static func modelSwitchLabel(_ content: String) -> String {
        let t = ChatText.trimmed(content)
        let pattern = #"^\[System: The active model for this chat has changed to (\S+?)(?: via provider (\S+?))?\. From this point"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
              let r = Range(m.range(at: 1), in: t) else { return "Model changed" }
        // The model's name, as the switch toast and the web's timeline row read it ("Model changed to Opus 5.5",
        // R:src/fe-convo-r6.ts modelSwitchLabel); its id when it has no name.
        let id = String(t[r])
        let name = ModelNames.displayModelName(id).trimmingCharacters(in: .whitespacesAndNewlines)
        return "Model changed to \(name.isEmpty ? id : name)"
    }

    static func timelineContent(kind: String?, role: String, content: String, rawContent: JSONValue?,
                                metadata: [String: JSONValue]?) -> String {
        switch kind {
        case "model_switch": return modelSwitchLabel(content)
        case "auto_continue": return autoContinueText
        case "personality_switch": return "personality changed"
        case "async_delegation_complete":
            if let t = metadata?["display_text"]?.nonEmptyString { return t }
            // [updates] "1 helper finished", as the reply's work line says "1 helper" (owner, 2026-10-28).
            if let count = metadata?["task_count"]?.int { return "\(count) helper\(count == 1 ? "" : "s") finished" }
            return "Helpers finished"
        case "process_complete":
            // The gateway's title is the command with its whole path, cut at 80 characters ("Background Process
            // Finished: /Users/…/bin/pytho..."); the note's own words give the short one, as live (owner, 2026-10-28).
            if let words = CronDeliveries.processNote(content), let split = TimelineNotes.processHeadline(words) {
                return split.headline
            }
            return metadata?["display_text"]?.nonEmptyString ?? "background process finished"
        case "failed_turn":
            return failedTurnWords(content, metadata: metadata)
        default:
            if role == "assistant", kind != "hidden", isSilentRun(rawContent) { return silentRunText }
            return content
        }
    }

    /// A failed turn's note with its reason. The row's text is always Hermes's fixed sentence; why it failed rides
    /// `display_metadata` (`error`, `error_surface`), which the live error card showed and a reopened chat lost: the
    /// Mac's two sends at 1:47 PM read only "Your request was not processed" (log study 2026-10-28). The plain notice
    /// keeps its first sentence (the reason replaces "send it again"); the partial one keeps its warning whole.
    static func failedTurnWords(_ content: String, metadata: [String: JSONValue]?) -> String {
        let surface = metadata?["error_surface"]?.looseObject
        guard var reason = surface?["message"]?.nonEmptyString ?? metadata?["error"]?.nonEmptyString else { return content }
        reason = ChatText.trimmed(reason.replacingOccurrences(of: #"^HTTP \d{3}:\s*"#, with: "", options: .regularExpression))
        if reason.count > 300 { reason = String(reason.prefix(299)) + "…" }
        let who = surface?["provider_label"]?.nonEmptyString ?? surface?["provider"]?.nonEmptyString
        let text = ChatText.trimmed(content)
        let lead = text.hasPrefix("Your request was not processed.") ? "Your request was not processed." : text
        return "\(lead) \(who.map { "\($0) said: " } ?? "")\(reason)"
    }

    /// `asyncResultBody` (hydration.ts:216-248).
    static func asyncResultBody(_ content: String) -> String? {
        var bodies = [content]
        if content.hasPrefix("[IMPORTANT: ") {
            bodies = content.components(separatedBy: "\n\n[IMPORTANT: ").enumerated().map { i, block in
                var b = i == 0 ? block : "[IMPORTANT: " + block
                b = b.replacingOccurrences(of: #"^\[IMPORTANT:\s*"#, with: "", options: .regularExpression)
                if b.hasSuffix("]") { b.removeLast() }
                return b
            }.filter { $0.range(of: #"^\d+ background processes completed\."#, options: .regularExpression) == nil }
        } else if content.hasPrefix("[ASYNC DELEGATION") {
            if let r = content.range(of: #"(?m)^--- (?:RESULT|ERROR) ---\r?\n"#, options: .regularExpression) {
                bodies = [String(content[r.upperBound...])]
            } else if content.hasPrefix("[ASYNC DELEGATION BATCH COMPLETE") {
                let re = try! NSRegularExpression(pattern: #"^--- [✓✗⚠] TASK \d+/\d+(?:: [\s\S]*?)? {2}\(status=[^\n]*\) ---\r?\n"#,
                                                  options: [.anchorsMatchLines])
                let ns = content as NSString
                var pieces: [String] = []
                var last = 0
                for m in re.matches(in: content, range: NSRange(location: 0, length: ns.length)) {
                    pieces.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
                    last = m.range.location + m.range.length
                }
                pieces.append(ns.substring(from: last))
                bodies = Array(pieces.dropFirst())
            } else {
                bodies = []
            }
        }
        let cleaned = bodies.map { body -> String in
            var result = body
            if body.hasPrefix("Cron job "), let r = body.range(of: #"(?m)^--- JOB OUTPUT ---\r?\n"#, options: .regularExpression) {
                result = String(body[r.upperBound...])
            }
            result = result.replacingOccurrences(of: #"\nFull live transcript \(complete tool/assistant trace\): [^\n]*\n*$"#,
                                                 with: "", options: .regularExpression)
            return ChatText.trimmed(result)
        }.filter { !$0.isEmpty }
        return cleaned.isEmpty ? nil : cleaned.joined(separator: "\n\n")
    }

    // MARK: Reasoning (fe-convo-r3 readableReasoning)

    static func readableReasoning(_ details: JSONValue?) -> String {
        guard let details else { return "" }
        switch details {
        case .string(let s):
            let t = ChatText.trimmed(s)
            guard t.hasPrefix("{") || t.hasPrefix("["), let parsed = ChatJSON.parse(string: t) else { return s }
            var out: [String] = []
            thinkingTexts(parsed, &out, inside: false, depth: 0)
            return out.joined(separator: "\n\n")
        case .object, .array:
            var out: [String] = []
            thinkingTexts(details, &out, inside: false, depth: 0)
            return out.joined(separator: "\n\n")
        default: return ""
        }
    }

    private static let notProse: Set<String> = ["signature", "data", "encrypted_content", "id", "projection", "tool_calls", "usage",
                                                 "input", "caller", "container", "diagnostics", "context_management", "stop_reason",
                                                 "stop_sequence", "stop_details", "model", "metadata"]

    private static func thinkingTexts(_ value: JSONValue, _ out: inout [String], inside: Bool, depth: Int) {
        guard depth <= 8 else { return }
        switch value {
        case .array(let items): for item in items { thinkingTexts(item, &out, inside: inside, depth: depth + 1) }
        case .object(let record):
            let type = record["type"]?.string ?? ""
            if type.range(of: "redacted|encrypted", options: [.regularExpression, .caseInsensitive]) != nil { return }
            if inside || type.range(of: "thinking|reasoning|summary", options: [.regularExpression, .caseInsensitive]) != nil {
                for key in ["thinking", "text", "summary", "content"] {
                    guard let field = record[key] else { continue }
                    if case .string(let s) = field { let t = ChatText.trimmed(s); if !t.isEmpty { out.append(t) } }
                    else { thinkingTexts(field, &out, inside: true, depth: depth + 1) }
                }
                return
            }
            for key in record.keys.sorted() where !notProse.contains(key) {
                thinkingTexts(record[key]!, &out, inside: false, depth: depth + 1)
            }
        default: return
        }
    }

    // MARK: Tool parts

    /// `parseStoredToolResult`.
    static func parseStoredToolResult(_ content: JSONValue?) -> JSONValue {
        guard let content else { return .string("") }
        switch content {
        case .null: return .null
        case .object, .array: return content
        default:
            let t = text(from: content)
            if ChatText.trimmed(t).isEmpty { return .string("") }
            let lead = t.drop(while: { $0.isWhitespace }).first
            if lead == "{" || lead == "[" || lead == "\"" || lead.map({ $0.isNumber || $0 == "-" || $0 == "t" || $0 == "f" || $0 == "n" }) == true,
               let parsed = ChatJSON.parse(string: t) {
                return parsed
            }
            return .string(t)
        }
    }

    static func parseMaybeJSONObject(_ value: JSONValue?) -> [String: JSONValue] {
        guard let value else { return [:] }
        return value.looseObject ?? [:]
    }

    static func firstNonEmptyObject(_ values: [JSONValue?]) -> [String: JSONValue] {
        for v in values {
            let o = parseMaybeJSONObject(v)
            if !o.isEmpty { return o }
        }
        return [:]
    }

    /// `toolContentRef` (R:src/tool-content.ts:10-18).
    static func toolContentRef(_ value: JSONValue?) -> JSONValue? {
        guard let o = value?.object, o["schema"]?.string == "tool.content.v1", let rowId = o["row_id"]?.positiveInt,
              let profile = o["profile"]?.nonEmptyString, profile.count <= 256,
              let sid = o["session_id"]?.nonEmptyString, sid.count <= 512,
              case .number(let bytes)? = o["bytes"], bytes >= 0, bytes.rounded() == bytes else { return nil }
        return .object(["schema": "tool.content.v1", "row_id": .number(Double(rowId)), "profile": .string(profile),
                        "session_id": .string(sid), "bytes": .number(bytes)])
    }
}

// MARK: - The fold

nonisolated private struct HTool {
    var id: String
    var name: String
    var args: [String: JSONValue]
    var argsText: String
    var result: JSONValue?
    var completedAt: Double?
    var isError = false
    var inlineDiff: String?
    var payloadRef: JSONValue?
    var unpaired = false
}

nonisolated private enum HPartKind { case text(String), reasoning(String), tool(HTool) }

nonisolated private struct HPart {
    var kind: HPartKind
    var timestamp: Double?
    var sourceRowId: Int?
    var isText: Bool { if case .text = kind { return true } else { return false } }
    var isTool: Bool { if case .tool = kind { return true } else { return false } }
}

nonisolated private struct HMessage {
    var id: String
    var role: ChatMessage.Role
    var parts: [HPart]
    var timestamp: Double?
    var rowId: Int?
    var serverRowSpan: Int?
    var durableComplete: Bool?
    var systemNotice = false
    var asyncResult: String?
    var attachmentRefs: [String] = []
    var firstRowId: Int?
    var attachments: [MessageAttachment] = []   // [attachments]
    /// Tapbacks from every row folded in; the row holding the words (where a new reaction goes).
    var reactions: [MessageReaction] = []
    var reactionRow: Int?
    /// The row that holds your reaction, when one does: a change to it goes there.
    var mineReactionRow: Int?
    /// Highest backend row folded in (a turn's final row sits under its first text row).
    var lastRowId: Int?
}

nonisolated private struct Folder {
    let pageSeq: Int
    var result: [HMessage] = []
    var pendingToolParts: [HPart] = []
    var pendingToolTimestamp: Double?
    var pendingToolSource: JSONValue?
    var pendingToolRows = 0
    var pendingMinRow: Int?
    var pendingMaxRow: Int?
    var activeAssistantIndex: Int?
    var nearestAssistant: [String: JSONValue]?

    init(pageSeq: Int) { self.pageSeq = pageSeq }

    static func durableRowId(_ row: [String: JSONValue]) -> Int? {
        row["row_id"]?.positiveInt ?? row["id"]?.positiveInt
    }

    func identity(_ row: JSONValue?, _ kind: String, _ index: Int) -> String {
        if let r = row?.object, let physical = Folder.durableRowId(r) { return "stored-row-\(physical)-\(kind)" }
        return "history-page-\(pageSeq)-\(index)-\(kind)"
    }

    static func earliest(_ values: [Double?]) -> Double? { values.compactMap { $0 }.min() }

    static func minRow(_ a: Int?, _ b: Int?) -> Int? {
        switch (a, b) { case let (x?, y?): return min(x, y); case let (x?, nil): return x; case let (nil, y?): return y; default: return nil }
    }

    static func maxRow(_ a: Int?, _ b: Int?) -> Int? {
        switch (a, b) { case let (x?, y?): return max(x, y); case let (x?, nil): return x; case let (nil, y?): return y; default: return nil }
    }

    mutating func clearPending() {
        pendingToolParts = []; pendingToolTimestamp = nil; pendingToolRows = 0; pendingToolSource = nil; pendingMinRow = nil; pendingMaxRow = nil
    }

    mutating func appendToActive(_ parts: [HPart], timestamp: Double?) -> Bool {
        guard let index = activeAssistantIndex else { return false }
        guard result.indices.contains(index), result[index].role == .assistant else { activeAssistantIndex = nil; return false }
        result[index].parts += parts
        result[index].durableComplete = false
        result[index].timestamp = Folder.earliest([result[index].timestamp, timestamp] + parts.map(\.timestamp))
        if pendingToolRows > 0 { result[index].serverRowSpan = (result[index].serverRowSpan ?? 1) + pendingToolRows }
        result[index].firstRowId = Folder.minRow(result[index].firstRowId, pendingMinRow)
        result[index].lastRowId = Folder.maxRow(result[index].lastRowId, pendingMaxRow)
        return true
    }

    mutating func flushPendingTools(_ index: Int) {
        guard !pendingToolParts.isEmpty else { return }
        if !appendToActive(pendingToolParts, timestamp: pendingToolTimestamp) {
            result.append(HMessage(id: identity(pendingToolSource, "tools", index), role: .assistant, parts: pendingToolParts,
                                   timestamp: pendingToolTimestamp, rowId: nil,
                                   serverRowSpan: pendingToolRows > 1 ? pendingToolRows : nil, durableComplete: false,
                                   firstRowId: pendingMinRow))
            result[result.count - 1].lastRowId = pendingMaxRow
            activeAssistantIndex = result.count - 1
        }
        clearPending()
    }

    func timestamp(_ row: [String: JSONValue]) -> Double? { row["timestamp"]?.double }

    static func toolPart(fromStoredCall call: JSONValue, index: Int, timestamp: Double?, labels: [String: JSONValue]?) -> HPart {
        let row = call.object ?? [:]
        let fn = row["function"]?.object
        let idValue = [row["id"], row["tool_call_id"]].compactMap { $0 }.first(where: { $0.isTruthy })
        let id = idValue.map { Hydration.text(from: $0) } ?? "stored-tool-\(index)"
        let nameValue = [row["name"], row["tool_name"], fn?["name"], row["input"]?.object?["name"]].compactMap { $0 }.first(where: { $0.isTruthy })
        var name = nameValue.map { Hydration.text(from: $0) } ?? "tool"
        var args = Hydration.firstNonEmptyObject([fn?["arguments"], row["arguments"], row["args"], row["input"]])
        // The deferred-tool bridge's `tool_call` holding one call is that call: its result row is stored under the inner
        // name, and a picture made through it is still an `image_generate` card (2026-10-31: twenty icons drew while their
        // call was a page away, then vanished once the older page paired them with a call named "tool_call").
        let unwrapped = ToolNow.unwrap(name, args: args)
        if let unwrapped { name = unwrapped.name; args = unwrapped.args }
        if case .array(let l)? = labels?[id], !l.isEmpty { args["hermes_tool_labels"] = .array(l) }
        let argsText: String
        if args.isEmpty { argsText = "" }
        else if unwrapped == nil, labels?[id] == nil, case .string(let raw)? = fn?["arguments"], raw.utf8.count <= 4096,
                ChatText.trimmed(raw).hasPrefix("{") {
            argsText = raw                    // what the model wrote; equal content, original key order
        } else {
            // The labels ride in `args` for the row's words; a step's Input shows what the bot sent, never them
            // (tester 2026-11-07: `{"hermes_tool_labels": [...]}` in a step's page on the Mac).
            argsText = ChatJSON.stringify(.object(args.filter { $0.key != "hermes_tool_labels" }))
        }
        return HPart(kind: .tool(HTool(id: id, name: name, args: args, argsText: argsText)), timestamp: timestamp)
    }

    static func resultMetadata(_ row: [String: JSONValue]) -> (inlineDiff: String?, error: JSONValue?, ref: JSONValue?) {
        let display = Hydration.parseMaybeJSONObject(row["display_metadata"])
        let metadata = Hydration.parseMaybeJSONObject(display["tool_result_metadata"])
        let error: JSONValue?
        switch metadata["error"] { case .string?, .bool?: error = metadata["error"]; default: error = nil }
        return (metadata["inline_diff"]?.string, error, Hydration.toolContentRef(row["display_payload_ref"]))
    }

    static func contentOf(toolRow row: [String: JSONValue]) -> JSONValue? {
        if let c = row["content"] { return c }
        return row["text"] ?? row["context"] ?? row["name"]
    }

    /// `applyStoredToolResultToParts`: only an unresolved part may take a stored result.
    static func apply(toolRow row: [String: JSONValue], to parts: inout [HPart]) -> Bool {
        let callId = row["tool_call_id"]?.nonEmptyString
        let toolName = row["tool_name"]?.nonEmptyString ?? row["name"]?.nonEmptyString ?? "tool"
        guard let index = parts.firstIndex(where: { part in
            guard case .tool(let t) = part.kind, t.result == nil else { return false }
            return callId != nil ? t.id == callId : t.name == toolName
        }), case .tool(var tool) = parts[index].kind else { return false }
        let meta = resultMetadata(row)
        tool.completedAt = row["timestamp"]?.double
        tool.result = Hydration.parseStoredToolResult(contentOf(toolRow: row))
        tool.inlineDiff = meta.inlineDiff
        tool.payloadRef = meta.ref
        tool.isError = meta.ref != nil && (meta.error?.isTruthy ?? false)
        parts[index].kind = .tool(tool)
        return true
    }

    /// `storedToolMessagePart`: an orphan tool row.
    static func orphanPart(_ row: [String: JSONValue], index: Int) -> HPart {
        let name = row["tool_name"]?.nonEmptyString ?? row["name"]?.nonEmptyString ?? "tool"
        let contextSource = [row["context"], row["text"], row["content"]].compactMap { $0 }.first(where: { $0.isTruthy })
        let context = ChatText.clip(Hydration.text(from: contextSource), max: 200)
        var args = Hydration.parseMaybeJSONObject(row["args"])
        if !context.isEmpty { args["context"] = .string(context) }
        if case .array(let l)? = row["labels"], !l.isEmpty { args["hermes_tool_labels"] = .array(l) }
        let shown = args.filter { $0.key != "hermes_tool_labels" }   // a step's Input, as above
        let meta = resultMetadata(row)
        let result: JSONValue = row["content"] != nil ? Hydration.parseStoredToolResult(row["content"])
            : (context.isEmpty ? .object([:]) : .object(["context": .string(context)]))
        let ts = row["timestamp"]?.double
        let tool = HTool(id: row["tool_call_id"]?.nonEmptyString ?? "stored-tool-message-\(index)", name: name, args: args,
                         argsText: shown.isEmpty ? "" : ChatJSON.stringify(.object(shown)), result: result, completedAt: ts,
                         isError: meta.ref != nil && (meta.error?.isTruthy ?? false), inlineDiff: meta.inlineDiff,
                         payloadRef: meta.ref, unpaired: true)
        return HPart(kind: .tool(tool), timestamp: ts)
    }

    func pairedTodoResult(_ row: [String: JSONValue]) -> Bool {
        guard let id = row["tool_call_id"]?.nonEmptyString, case .array(let calls)? = nearestAssistant?["tool_calls"] else { return false }
        for (i, call) in calls.enumerated() {
            guard case .tool(let t) = Folder.toolPart(fromStoredCall: call, index: i, timestamp: nil, labels: nil).kind,
                  t.id == id else { continue }
            if ToolPresentation.isTodo(t.name) { return true }
            if t.name == "tool_call", case .array(let inner)? = t.args["calls"],
               inner.contains(where: { ToolPresentation.isTodo($0.object?["name"]?.string) }) { return true }
        }
        return false
    }

    /// Public commentary + final-answer fallback from Responses sidecars (hydration.ts:46-107).
    static func codexText(_ row: [String: JSONValue]) -> (commentary: [String], reply: String) {
        var commentary: [String] = []
        if case .array(let items)? = row["display_commentary"] {
            commentary = items.compactMap { $0.nonEmptyString }
        }
        var itemsValue = row["codex_message_items"]
        if case .string(let s)? = itemsValue { itemsValue = ChatJSON.parse(string: s) }
        guard case .array(let items)? = itemsValue else { return (commentary, "") }
        var replies: [String] = []
        for item in items {
            guard let record = item.object, record["type"]?.string == "message", record["role"]?.string == "assistant" else { continue }
            let phase = ChatText.trimmed(record["phase"]?.string ?? "").lowercased()
            guard phase != "analysis", phase != "commentary", case .array(let content)? = record["content"] else { continue }
            let chunk = content.compactMap { part -> String? in
                guard let p = part.object, p["type"]?.string == "output_text" || p["type"]?.string == "text" else { return nil }
                return p["text"]?.string
            }.joined()
            if !chunk.isEmpty { replies.append(chunk) }
        }
        return (commentary, replies.joined())
    }

    mutating func run(_ rows: [JSONValue]) -> HydratedPage {
        for (index, rowValue) in rows.enumerated() {
            guard let row = rowValue.object else { continue }
            let role = row["role"]?.string ?? "assistant"
            let rowId = Folder.durableRowId(row)
            if role == "assistant" { nearestAssistant = row } else if role == "user" || role == "system" { nearestAssistant = nil }

            if role == "tool" {
                if ToolPresentation.isTodo(row["tool_name"]?.string), !pairedTodoResult(row) {
                    if pendingToolSource == nil { pendingToolSource = rowValue }
                    pendingToolParts.append(Folder.orphanPart(row, index: index))
                    if pendingToolTimestamp == nil { pendingToolTimestamp = timestamp(row) }
                    pendingToolRows += 1; pendingMinRow = Folder.minRow(pendingMinRow, rowId); pendingMaxRow = Folder.maxRow(pendingMaxRow, rowId)
                    continue
                }
                if Folder.apply(toolRow: row, to: &pendingToolParts) {
                    pendingToolRows += 1; pendingMinRow = Folder.minRow(pendingMinRow, rowId); pendingMaxRow = Folder.maxRow(pendingMaxRow, rowId)
                    continue
                }
                var applied = false
                for i in result.indices.reversed() where result[i].role == .assistant {
                    if Folder.apply(toolRow: row, to: &result[i].parts) {
                        result[i].serverRowSpan = (result[i].serverRowSpan ?? 1) + 1
                        result[i].firstRowId = Folder.minRow(result[i].firstRowId, rowId)
                        result[i].lastRowId = Folder.maxRow(result[i].lastRowId, rowId)
                        applied = true
                        break
                    }
                }
                if applied { continue }
                if pendingToolSource == nil { pendingToolSource = rowValue }
                pendingToolParts.append(Folder.orphanPart(row, index: index))
                if pendingToolTimestamp == nil { pendingToolTimestamp = timestamp(row) }
                pendingToolRows += 1; pendingMinRow = Folder.minRow(pendingMinRow, rowId); pendingMaxRow = Folder.maxRow(pendingMaxRow, rowId)
                continue
            }

            let kind = row["display_kind"]?.string
            let metadata = row["display_metadata"]?.looseObject
            let content: JSONValue?
            if let dc = row["display_content"] { content = dc }
            else {
                content = [row["content"], row["text"], row["context"], row["name"]].compactMap { $0 }.first(where: { $0.isTruthy })
            }
            let shown = Hydration.timelineContent(kind: kind, role: role,
                                                  content: Hydration.displayContent(role: role, content: content),
                                                  rawContent: content, metadata: metadata)
            var rawDisplay: String? = shown
            if kind == "hidden" { rawDisplay = nil }
            else if role == "user", ChatText.trimmed(shown).range(of: #"^\[Background process \S+ heartbeat #\d+ "#,
                                                                  options: .regularExpression) != nil { rawDisplay = nil }
            let isNotice = kind.map { Hydration.noticeKinds.contains($0) } ?? false
            let displayRole: ChatMessage.Role
            if isNotice || (role == "assistant" && kind != "hidden" && Hydration.isSilentRun(content)) { displayRole = .system }
            else { displayRole = ChatMessage.Role(rawValue: role) ?? .assistant }

            var displayText = rawDisplay
            var refs: [String] = []
            var attachments: [MessageAttachment] = []
            if displayRole == .user, let raw = rawDisplay, !raw.isEmpty || AttachmentHydration.imageParts(row["content"]).count > 0 {
                // [attachments] image refs, files, MEDIA lines and image parts (docs/spec/1x-attachments.md §7.1).
                let lifted = AttachmentHydration.liftUser(raw, content: row["content"])
                displayText = lifted.text
                refs = lifted.refs
                attachments = lifted.attachments
            }
            // [attachments] a reply's `![alt](data:image/…)` → decoded here, off the main thread (spec §7.5)
            if displayRole == .assistant, let t = displayText { displayText = AttachmentHydration.inlineMarkdownImages(t) }
            if let t = displayText { displayText = Hydration.stripInlineDataURIs(t) }

            var parts: [HPart] = []
            let ts = timestamp(row)
            let sourceHasTools: Bool = { if case .array(let a)? = row["tool_calls"] { return !a.isEmpty }; return false }()
            let durableComplete: Bool? = sourceHasTools ? false : (rowId != nil ? true : nil)
            let codex: (commentary: [String], reply: String) = (displayRole == .assistant && kind != "hidden") ? Folder.codexText(row) : ([], "")

            let rawReasoning: String = {
                if let r = row["reasoning"], r.isTruthy { return Hydration.text(from: r) }
                if let r = row["reasoning_content"], r.isTruthy { return Hydration.text(from: r) }
                return Hydration.readableReasoning(row["reasoning_details"])
            }()
            let reasoning = row["display_reasoning"].map { Hydration.text(from: $0) } ?? rawReasoning
            if !reasoning.isEmpty, role == "assistant" { parts.append(HPart(kind: .reasoning(reasoning), timestamp: ts)) }

            let reply: String? = row["display_content"] != nil ? displayText
                : ((displayText?.isEmpty == false) ? displayText : (codex.reply.isEmpty ? displayText : codex.reply))
            let commentaryIsReply: Bool = {
                guard let reply, !reply.isEmpty, !codex.commentary.isEmpty else { return false }
                return ChatText.flat(codex.commentary.joined(separator: "\n\n")) == ChatText.flat(reply)
            }()
            if !commentaryIsReply { parts += codex.commentary.map { HPart(kind: .text($0), timestamp: ts) } }
            if let reply, !reply.isEmpty { parts.append(HPart(kind: .text(reply), timestamp: ts)) }
            if role == "assistant", case .array(let calls)? = row["tool_calls"] {
                let labels = row["tool_call_labels"]?.object
                for (i, call) in calls.enumerated() {
                    parts.append(Folder.toolPart(fromStoredCall: call, index: i, timestamp: ts, labels: labels))
                }
            }
            if let rowId { for i in parts.indices where parts[i].isText { parts[i].sourceRowId = rowId } }

            if parts.isEmpty && refs.isEmpty && attachments.isEmpty {
                if role != "assistant" { flushPendingTools(index); activeAssistantIndex = nil }
                continue
            }
            if role == "assistant", !parts.isEmpty, parts.allSatisfy(\.isTool) {
                if pendingToolSource == nil { pendingToolSource = rowValue }
                pendingToolParts += parts
                if pendingToolTimestamp == nil { pendingToolTimestamp = ts }
                pendingToolRows += 1; pendingMinRow = Folder.minRow(pendingMinRow, rowId); pendingMaxRow = Folder.maxRow(pendingMaxRow, rowId)
                continue
            }

            var pendingAbsorbedRows = 0
            var absorbedMinRow: Int?
            var absorbedMaxRow: Int?
            if role == "assistant" && displayRole == .assistant {
                if !pendingToolParts.isEmpty {
                    if !appendToActive(pendingToolParts, timestamp: ts ?? pendingToolTimestamp) {
                        parts = pendingToolParts + parts
                        pendingAbsorbedRows = pendingToolRows
                        absorbedMinRow = pendingMinRow
                        absorbedMaxRow = pendingMaxRow
                    }
                    clearPending()
                }
                if let ai = activeAssistantIndex, result.indices.contains(ai), result[ai].role == .assistant {
                    let currentHasTool = parts.contains(where: \.isTool)
                    let activeHasTool = result[ai].parts.contains(where: \.isTool)
                    if currentHasTool || activeHasTool {
                        result[ai].parts += parts
                        let rowReactions = MessageReactions.fromRow(row)
                        result[ai].reactions = MessageReactions.merge(result[ai].reactions, rowReactions)
                        if let rowId, parts.contains(where: \.isText) { result[ai].reactionRow = rowId }
                        if let rowId, rowReactions.contains(where: \.isMine) { result[ai].mineReactionRow = rowId }
                        result[ai].durableComplete = durableComplete
                        result[ai].timestamp = Folder.earliest([result[ai].timestamp, ts] + parts.map(\.timestamp))
                        result[ai].serverRowSpan = (result[ai].serverRowSpan ?? 1) + 1
                        result[ai].firstRowId = Folder.minRow(Folder.minRow(result[ai].firstRowId, rowId), absorbedMinRow)
                        result[ai].lastRowId = Folder.maxRow(Folder.maxRow(result[ai].lastRowId, rowId), absorbedMaxRow)
                        continue
                    }
                }
            } else {
                flushPendingTools(index)
            }

            var message = HMessage(id: identity(rowValue, displayRole.rawValue, index), role: displayRole, parts: parts,
                                   timestamp: Folder.earliest([ts] + parts.map(\.timestamp)), rowId: rowId,
                                   serverRowSpan: pendingAbsorbedRows > 0 ? pendingAbsorbedRows + 1 : nil,
                                   durableComplete: role == "assistant" ? durableComplete : nil,
                                   systemNotice: isNotice, attachmentRefs: refs,
                                   firstRowId: Folder.minRow(rowId, absorbedMinRow), attachments: attachments)
            message.lastRowId = Folder.maxRow(rowId, absorbedMaxRow)
            message.reactions = MessageReactions.fromRow(row)
            if let rowId, parts.contains(where: \.isText) { message.reactionRow = rowId }
            if let rowId, message.reactions.contains(where: \.isMine) { message.mineReactionRow = rowId }
            if kind == "async_delegation_complete" || kind == "process_complete" {
                let body = Hydration.displayContent(role: role, content: row["content"].flatMap { $0.isTruthy ? $0 : nil } ?? content)
                message.asyncResult = Hydration.asyncResultBody(body)
            }
            if row["_synthetic"] == .bool(true) { message.serverRowSpan = 0 }
            result.append(message)
            activeAssistantIndex = role == "assistant" ? result.count - 1 : nil
        }
        flushPendingTools(rows.count)
        return finish()
    }

    /// Post-pass: repeated-text dedupe, silent-tool drop, empty filter, unique tool ids, conversion.
    func finish() -> HydratedPage {
        var messages: [ChatMessage] = []
        var metas: [String: MessageMeta] = [:]
        messages.reserveCapacity(result.count)
        var skippedEmpty = 0      // [diagnostics]
        for h in result {
            var parts = h.parts
            if h.role == .assistant { parts = Folder.dedupeRepeatedText(parts) }
            // Native M1 (§8.10): successful silent calls neither draw nor count; failed ones stay.
            parts.removeAll { part in
                guard case .tool(let t) = part.kind, ToolPresentation.isSilent(t.name) else { return false }
                return !ToolPresentation.callFailed(isError: t.isError, result: t.result)
            }
            let text = parts.compactMap { if case .text(let t) = $0.kind { return t } else { return nil } }.joined()
            guard !ChatText.trimmed(text).isEmpty || parts.contains(where: { !$0.isText }) || !h.attachmentRefs.isEmpty
                    || !h.attachments.isEmpty else { skippedEmpty += 1; continue }

            var meta = MessageMeta()
            meta.serverRowSpan = h.serverRowSpan ?? 1
            meta.attachmentRefs = h.attachmentRefs
            meta.systemNotice = h.systemNotice
            meta.durableComplete = h.durableComplete
            meta.asyncResult = h.asyncResult
            meta.firstRowId = h.firstRowId ?? h.rowId
            meta.lastRowId = h.lastRowId ?? h.rowId
            meta.attachments = h.attachments                 // [attachments]
            if h.role == .system, parts.count == 1, case .text(let t) = parts[0].kind, t == Hydration.photoRowLabel { meta.serverRowSpan = 0 }

            var seen = Set<String>()
            var chatParts: [ChatPart] = []
            chatParts.reserveCapacity(parts.count)
            for (index, part) in parts.enumerated() {
                switch part.kind {
                case .text(let t): chatParts.append(.text(t))
                case .reasoning(let t): chatParts.append(.reasoning(t))
                case .tool(var tool):
                    if tool.id.isEmpty { tool.id = "\(h.id)-tool-\(index)" }
                    if seen.contains(tool.id) { tool.id = "\(tool.id)-\(h.id)-\(index)" }
                    seen.insert(tool.id)
                    let (call, detail) = Folder.makeToolCall(tool)
                    chatParts.append(.tool(call))
                    meta.tools[call.id] = detail
                }
            }
            var message = ChatMessage(id: h.id, role: h.role, parts: chatParts,
                                      timestamp: h.timestamp.map { Date(timeIntervalSince1970: $0) }, rowId: h.rowId)
            message.reactions = h.reactions
            if let row = h.mineReactionRow ?? h.reactionRow, row != h.rowId { message.reactionRow = row }
            messages.append(message)
            if !meta.isDefault { metas[h.id] = meta }
        }
        AppLog.trace("history", "fold: \(result.count) folded → \(messages.count) messages (\(messages.filter { $0.role == .user }.count) prompts), \(skippedEmpty) empty dropped")
        return HydratedPage(messages: messages, meta: metas)
    }

    static func makeToolCall(_ tool: HTool) -> (ToolCall, ToolDetail) {
        let hasResult = tool.result != nil
        var detail = ToolPresentation.detail(args: tool.args, argsText: tool.argsText.isEmpty ? nil : tool.argsText,
                                             result: tool.result, isError: tool.isError, inlineDiff: tool.inlineDiff,
                                             payloadRef: tool.payloadRef)
        if !hasResult { detail.failed = false }
        if tool.name == "image_generate" {                   // [attachments] the generated-image card (spec §7.7)
            detail.generatedImage = GeneratedImageInfo.from(args: tool.args, result: tool.result, running: false)
        }
        if ToolScreenshots.isScreenshotTool(tool.name) {     // [screen] the stored step's screenshot (spec 3x §5.3)
            detail.screenshot = ToolScreenshots.stepScreenshot(result: tool.result, resultText: nil, summary: nil, at: tool.completedAt)
        }
        let failed = detail.failed
        let call = ToolPresentation.Call(name: tool.name, args: tool.args, pending: !hasResult && tool.completedAt == nil,
                                         failed: failed, hasResult: hasResult)
        let title = ToolPresentation.title(for: call, live: false)
        var summary = hasResult ? ToolPresentation.shortSummary(payloadSummary: nil, detail: detail) : nil
        // [questions] A settled clarify carries its Q&A rows (spec 1x §4.4).
        if hasResult { summary = ClarifySettled.summary(name: tool.name, result: tool.result, fallback: summary) }
        var toolCall = ToolCall(id: tool.id, name: tool.name, title: title.isEmpty ? tool.name : title,
                                argsText: DraftCards.wholeArgsText(name: tool.name, args: tool.args)   // [drafts]
                                    ?? (tool.argsText.isEmpty ? nil : ToolArgs.boundedText(tool.args, raw: tool.argsText)),   // [activity]
                                summary: summary, state: failed ? .failed : .done, durationSeconds: nil)
        if !failed { toolCall.card = ToolCards.card(name: tool.name, args: tool.args, result: tool.result) }   // [activity] §11.1
        if hasResult { toolCall.note = ToolWords.rowNote(name: tool.name, stdout: detail.stdout, stderr: detail.stderr, detail: detail.detail,
                                                         bytes: detail.payloadRef?["bytes"]?.double ?? ToolWords.resultBytes(tool.result), failed: failed) }   // [transcript] §5.1
        return (toolCall, detail)
    }

    /// `dedupeRepeatedTextInParts` (parts.ts:279-343).
    static func dedupeRepeatedText(_ parts: [HPart]) -> [HPart] {
        func key(_ p: HPart) -> String? {
            guard case .text(let t) = p.kind, let row = p.sourceRowId else { return nil }
            return "\(row):\(ChatText.flat(t))"
        }
        var last: [String: Int] = [:]
        for (i, p) in parts.enumerated() { if let k = key(p) { last[k] = i } }
        var deduped = parts.enumerated().filter { i, p in key(p).map { last[$0] == i } ?? true }.map(\.element)
        let texts = deduped.enumerated().filter { $0.element.isText }
        guard texts.count >= 2 else { return deduped }
        let previous = texts[texts.count - 2], lastText = texts[texts.count - 1]
        if deduped[(lastText.offset + 1)...].contains(where: \.isTool) { return deduped }
        guard case .text(let a) = lastText.element.kind, case .text(let b) = previous.element.kind else { return deduped }
        let k = ChatText.flat(a)
        guard !k.isEmpty, k == ChatText.flat(b),
              deduped[(previous.offset + 1)..<lastText.offset].contains(where: \.isTool) else { return deduped }
        deduped.remove(at: previous.offset)
        return deduped
    }
}
