// What was said in a live voice chat (GPT-Live, Grok Live), kept with the chat. The live voice's words and the person's
// were held in memory only and gone when the conversation ended: the bot learned only what was delegated to it, and
// nobody could read the conversation back (owner, 2026-11-17: "the bot should have the transcript. I mean you were
// literally talking to the bot"). The gateway has no way to add words to a chat without a turn, so when the conversation
// ends the app sends one message: a marked first line, a note for the bot, then the exchange. Hermes has no notion of
// it; the convention is client-side, as a voice memo's is (`VoiceMemo`). The chat draws it as one line, "Voice Chat ·
// 4:12", that opens on the words, and folds the call's delegated heard turns into it (Grok Bot style) so the same
// exchange never appears both as chat bubbles and again in the pill below.

import Foundation

nonisolated enum VoiceChatRecord {
    struct Turn: Equatable, Sendable {
        var user: Bool
        var text: String
    }

    /// One folded delegated turn identified by stable content-hash tags (`u:<hex8>` / `a:<hex8>`), surviving SQLite
    /// row-id renumbering on rewind/edit/regenerate and working identically across devices.
    struct FoldedTurn: Equatable, Sendable {
        var userTags: [String]
        var assistantTags: [String]

        var token: String { (userTags + assistantTags).joined(separator: "+") }

        init(userTags: [String], assistantTags: [String]) {
            self.userTags = userTags
            self.assistantTags = assistantTags
        }

        init?(token: String) {
            var users: [String] = []
            var assistants: [String] = []
            for raw in token.split(separator: "+") {
                let part = raw.trimmingCharacters(in: .whitespaces)
                if part.hasPrefix("u:"), part.count == 10 {
                    users.append(part)
                } else if part.hasPrefix("a:"), part.count == 10 {
                    assistants.append(part)
                }
            }
            guard !users.isEmpty else { return nil }
            self.userTags = users
            self.assistantTags = assistants
        }
    }

    /// How the message opens: what `parse` looks for.
    static let markLead = "[Voice chat transcript"
    /// Rides the message, for the bot. It names no bot (see `LiveVoiceWire.toolNote`).
    static let notePrefix = "(From the app, not typed by the user: this is what was said in the voice chat that just ended, "
        + "kept here so you have it. \"Voice assistant\" is the voice that spoke with the user for you. Everything they "
        + "asked for in it was already passed to you as it was said."
    static let noteSuffix = " Do not act on this message and do not answer it: reply with exactly NO_REPLY.)"
    static let note = notePrefix + noteSuffix
    /// The newest of a long conversation is what is kept.
    static let maxChars = 24_000
    static let cutNote = "(The earlier part of a long voice chat is left out.)"
    /// Maximum messages before a Voice Chat record scanned when folding delegated turns.
    static let maxFoldLookback = 200
    /// Retrospective lookback for historical records written before explicit `[folded: ...]` metadata existed.
    static let retroLookback = 40

    /// One more piece of the live transcript: the same speaker's pieces are one turn, inserting a space when two
    /// separate sentences from the same speaker land back-to-back without whitespace (e.g. "Checking now." + "The park…").
    static func add(_ fragment: LiveTranscriptFragment, to turns: inout [Turn]) {
        guard !fragment.text.isEmpty else { return }
        let user = fragment.speaker == .user
        if let last = turns.indices.last, turns[last].user == user {
            if needsSpace(after: turns[last].text, before: fragment.text) {
                turns[last].text += " "
            }
            turns[last].text += fragment.text
        } else {
            turns.append(Turn(user: user, text: fragment.text))
        }
    }

    private static let attachingLeads: Set<Character> = [",", ".", ";", ":", "!", "?", ")", "]", "}", "'", "’", "”", "-", "—", "–", "…"]
    private static let sentenceEnds: Set<Character> = [".", "!", "?", "…"]
    private static let closingWrappers: Set<Character> = ["\"", "”", "'", "’", ")"]

    /// Whether a same-speaker fragment needs a space before it (a new sentence or bracketed cue glued onto
    /// sentence-ending punctuation, optionally after a closing quote/paren, without whitespace). Preserves decimals
    /// ("3.14", "$4.99"), multi-letter initials ("U.S."), domains ("example.com"), Markdown links ("[a](b)"), and
    /// mid-word deltas regardless of network jitter, while separating "Plan B. Then", "U.S. Army", and "done. 3 items".
    private static func needsSpace(after previous: String, before next: String) -> Bool {
        guard let prevLast = previous.last, let nextFirst = next.first else { return false }
        if prevLast.isWhitespace || nextFirst.isWhitespace { return false }
        if attachingLeads.contains(nextFirst) { return false }
        if prevLast == "]" {
            // Bracketed voice cue like "[laughs]" + "Okay", never Markdown link "[label]" + "(url)".
            return nextFirst.isUppercase || nextFirst == "\"" || nextFirst == "“"
        }
        // Peel up to two trailing closing quotes/parens so `"Done."Next` or `(Yes!)Okay` still gets a space.
        var end = previous.endIndex
        var peeled = 0
        while end > previous.startIndex && peeled < 2 {
            let before = previous.index(before: end)
            if closingWrappers.contains(previous[before]) {
                end = before
                peeled += 1
            } else {
                break
            }
        }
        guard end > previous.startIndex else { return false }
        let punctIdx = previous.index(before: end)
        let punct = previous[punctIdx]
        guard sentenceEnds.contains(punct) else { return false }
        let beforePunct: Character? = punctIdx > previous.startIndex ? previous[previous.index(before: punctIdx)] : nil
        if punct == ".", peeled == 0, endsWithSingleInitial(previous[..<end]), startsWithSingleInitial(next) {
            return false
        }
        if nextFirst.isNumber {
            // Keep decimals/prices/versions ("3.14", "$4.99", "v2.0"), but separate "done. 3 items" or "Ready! 2 left".
            if punct == "." && (beforePunct?.isNumber == true || peeled == 0 && endsWithSingleInitial(previous[..<end])) {
                return false
            }
            return true
        }
        return nextFirst.isUppercase || nextFirst == "[" || nextFirst == "(" || nextFirst == "\"" || nextFirst == "“"
    }

    /// True when `text` ends with a single-letter initial like "U." or "U.S." (not a full word like "look.").
    private static func endsWithSingleInitial(_ text: Substring) -> Bool {
        guard text.last == ".", text.count >= 2 else { return false }
        let beforeDot = text.index(before: text.endIndex)
        let letterIdx = text.index(before: beforeDot)
        guard text[letterIdx].isUppercase else { return false }
        if letterIdx == text.startIndex { return true }
        let prior = text[text.index(before: letterIdx)]
        return prior.isWhitespace || prior == "." || prior == "(" || prior == "\"" || prior == "“"
    }

    /// True when `text` starts with a continuing single-letter initial like "S." in `"U." + "S."` (not a full word
    /// like "Army" in `"U.S." + "Army"` or "Then" in `"Plan B." + "Then"`).
    private static func startsWithSingleInitial(_ text: String) -> Bool {
        guard let first = text.first, first.isUppercase else { return false }
        let secondIdx = text.index(after: text.startIndex)
        guard secondIdx < text.endIndex else { return false }
        return text[secondIdx] == "."
    }

    /// The turns with words in them, each on one line's worth of text.
    static func settled(_ turns: [Turn]) -> [Turn] {
        var out: [Turn] = []
        for turn in turns {
            let words = LiveVoiceWire.collapse(turn.text)
            guard !words.isEmpty else { continue }
            if let last = out.indices.last, out[last].user == turn.user {
                out[last].text += " " + words
            } else {
                out.append(Turn(user: turn.user, text: words))
            }
        }
        return out
    }

    /// True when `message(_:...)` would drop earlier lines to fit `maxChars`. In that rare case (> ~30 min call),
    /// callers skip folding so trimmed early turns remain readable in the chat stream.
    static func willTruncate(_ turns: [Turn]) -> Bool {
        let said = settled(turns)
        let lines = said.map { "\($0.user ? "User" : "Voice assistant"): \($0.text)" }
        if lines.count == 1, let only = lines.first { return only.count > maxChars }
        return lines.reduce(0, { $0 + $1.count + 1 }) > maxChars
    }

    /// The message a finished conversation sends, or nil when the person said nothing worth keeping (silence, or only
    /// the word that ended it).
    /// - `foldedTags`: stable content-hash turn tokens (`u:<hex8>+a:<hex8>`) of the call's heard delegated turns.
    /// - `includeExplicitMarker`: when `true` and `foldedTags` is empty (or the transcript was truncated), writes
    ///   `[folded: none]` before the `NO_REPLY` instruction so retrospective legacy matching never re-hides turns.
    static func message(_ turns: [Turn], seconds: TimeInterval, stopPhrases: TalkStopWord.Config = .standard,
                        foldedTags: [String] = [], includeExplicitMarker: Bool = false) -> String? {
        let said = settled(turns)
        let person = said.filter(\.user).map(\.text).joined(separator: " ")
        guard !person.isEmpty, !TalkStopWord.isStop(person, config: stopPhrases) else { return nil }
        var lines = said.map { "\($0.user ? "User" : "Voice assistant"): \($0.text)" }
        var cut = false
        while lines.count > 1, lines.reduce(0, { $0 + $1.count + 1 }) > maxChars {
            lines.removeFirst()
            cut = true
        }
        if let only = lines.first, lines.count == 1, only.count > maxChars { lines = [String(only.suffix(maxChars))]; cut = true }
        let head = "\(markLead) · \(TalkDockState.formatElapsed(seconds))]"
        let cleanTags = cut ? [] : foldedTags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let noteLine: String
        if !cleanTags.isEmpty {
            noteLine = notePrefix + " [folded: \(cleanTags.joined(separator: ","))]" + noteSuffix
        } else if includeExplicitMarker || cut {
            noteLine = notePrefix + " [folded: none]" + noteSuffix
        } else {
            noteLine = note
        }
        return ([head, noteLine, ""] + (cut ? [cutNote] : []) + lines).joined(separator: "\n")
    }

    struct Found: Equatable, Sendable {
        /// "4:12", when the first line carries it.
        var length: String?
        /// Call duration in seconds parsed from `length`, when present.
        var durationSeconds: TimeInterval? = nil
        /// The exchange as the chat shows it: "You: …" and "Voice: …", a blank line between turns.
        var words: String
        /// True when the hidden app note carried explicit `[folded: ...]` (including `none`), disabling retrospective
        /// text matching so deliberately unhidden turns are never folded back in.
        var hasExplicitFoldMetadata: Bool = false
        /// Stable content-hash folded turn tokens carried in `[folded: ...]`.
        var foldedTurns: [FoldedTurn] = []
        /// Each "User:" line's words, for conservative retrospective matching of historical pre-metadata records only.
        var userLines: [String] = []
        /// Each "Voice assistant:" line's words, for verifying an assistant reply was spoken in historical records.
        var assistantLines: [String] = []

        var title: String { length.map { "Voice Chat · \($0)" } ?? "Voice Chat" }
    }

    private static let head = try! NSRegularExpression(pattern: #"^\[Voice chat transcript(?: · ([0-9:]{1,9}))?\][ \t]*(?:\r?\n|$)"#)
    private static let foldedTagRx = try! NSRegularExpression(pattern: #"\[folded:\s*([^\]]+)\]"#)
    private static let tableDelimiterRx = try! NSRegularExpression(
        pattern: #"^\|?\s*:?-{2,}:?\s*(?:\|\s*:?-{2,}:?\s*)+\|?\s*$"#, options: [.anchorsMatchLines]
    )
    private static let linkRx = try! NSRegularExpression(
        pattern: #"(?:https?://|hermes://|mailto:)[^\s\)\]>]+|\[[^\]\n]+\]\([^\s)\n]+\)"#, options: [.caseInsensitive]
    )

    /// Parses "m:ss" or "h:mm:ss" into seconds.
    static func parseDuration(_ length: String?) -> TimeInterval? {
        guard let length else { return nil }
        let parts = length.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 2: return TimeInterval(parts[0] * 60 + parts[1])
        case 3: return TimeInterval(parts[0] * 3600 + parts[1] * 60 + parts[2])
        default: return nil
        }
    }

    /// A stored message that is a voice chat's record, or nil.
    static func parse(_ text: String) -> Found? {
        guard text.hasPrefix(markLead) else { return nil }
        if let cached = cache.parsed(for: text) { return cached }
        let whole = NSRange(text.startIndex..., in: text)
        guard let match = head.firstMatch(in: text, range: whole), match.range.location == 0 else { return nil }
        let length = Range(match.range(at: 1), in: text).map { String(text[$0]) }
        var rest = Substring(text)[(Range(match.range, in: text)?.upperBound ?? text.endIndex)...]
        var hasExplicit = false
        var foldedTurns: [FoldedTurn] = []
        // The note for the bot is one bracketed paragraph: never shown.
        if rest.hasPrefix("(From the app"), let close = rest.range(of: ")\n") ?? rest.range(of: ")", options: .backwards) {
            let noteText = String(rest[..<close.upperBound])
            let noteRange = NSRange(noteText.startIndex..., in: noteText)
            if let foldedMatch = foldedTagRx.firstMatch(in: noteText, range: noteRange),
               let bodyRange = Range(foldedMatch.range(at: 1), in: noteText) {
                hasExplicit = true
                let body = noteText[bodyRange].trimmingCharacters(in: .whitespacesAndNewlines)
                if body.lowercased() != "none" {
                    for raw in body.split(separator: ",") {
                        if let turn = FoldedTurn(token: String(raw)) {
                            foldedTurns.append(turn)
                        }
                    }
                }
            }
            rest = rest[close.upperBound...]
        }
        var out: [String] = []
        var userLines: [String] = []
        var assistantLines: [String] = []
        for line in rest.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("User: ") {
                let body = String(line.dropFirst("User: ".count))
                userLines.append(body)
                out.append("You: " + body)
            } else if line.hasPrefix("Voice assistant: ") {
                let body = String(line.dropFirst("Voice assistant: ".count))
                assistantLines.append(body)
                out.append("Voice: " + body)
            } else {
                out.append(line)
            }
        }
        let found = Found(length: length, durationSeconds: parseDuration(length), words: out.joined(separator: "\n\n"),
                          hasExplicitFoldMetadata: hasExplicit, foldedTurns: foldedTurns,
                          userLines: userLines, assistantLines: assistantLines)
        cache.storeParsed(found, for: text)
        return found
    }

    /// True for a stored message that is a record: previews and titles pass over it.
    static func isRecord(_ text: String) -> Bool { text.hasPrefix(markLead) && parse(text) != nil }

    // MARK: Deliverables & content-hash fold tags

    /// True when assistant bubble text holds non-spoken visual or interactive content (media directive, HTML preview
    /// card, bare image path, markdown image, fenced code block, markdown table, or clickable link) that must remain
    /// visible in chat even when the surrounding voice turn folds into its Voice Chat card.
    static func textHasDeliverable(_ raw: String) -> Bool {
        let t = ReasoningTags.strip(raw)
        guard !t.isEmpty else { return false }
        if t.contains("::preview{") || t.contains("![") || t.contains("[Preview:") { return true }
        if MediaTags.hasMediaTag(t) { return true }
        if t.contains("```") { return true }
        if MediaTags.hasBareImagePath(t) { return true }
        let range = NSRange(t.startIndex..., in: t)
        if t.contains("|"), tableDelimiterRx.firstMatch(in: t, range: range) != nil { return true }
        if linkRx.firstMatch(in: t, range: range) != nil { return true }
        return false
    }

    /// Stable 8-hex FNV-1a content tag (`u:<hex8>` / `a:<hex8>`) for normalized text, invariant across devices and
    /// SQLite row-id renumbering on rewind/edit/regenerate.
    static func foldTag(role: ChatMessage.Role, text: String) -> String? {
        let prefix: String
        switch role {
        case .user: prefix = "u"
        case .assistant: prefix = "a"
        case .system: return nil
        }
        let norm = normalizedText(text)
        guard !norm.isEmpty else { return nil }
        var h: UInt32 = 2_166_136_261
        for byte in norm.utf8 {
            h ^= UInt32(byte)
            h = h &* 16_777_619
        }
        return String(format: "%@:%08x", prefix, h)
    }

    /// Stable turn token (`u:<hex8>+a:<hex8>`) pairing a delegated turn's user prompt(s) and final non-empty
    /// assistant reply text(s).
    static func turnFoldTag(users: [ChatMessage], assistants: [ChatMessage]) -> String? {
        let uTags = users.flatMap(userFoldTags)
        guard !uTags.isEmpty else { return nil }
        let aTags = assistants.compactMap(assistantFoldTag)
        return FoldedTurn(userTags: uTags, assistantTags: aTags).token
    }

    private static func userTextJoined(_ m: ChatMessage) -> String {
        m.parts.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined(separator: " ")
    }

    /// The reply's final spoken segment (all text parts after its last tool call, or its last non-empty text part
    /// when a tool ran after prose). Staying invariant to interim/commentary parts before tools keeps live and
    /// hydrated (`Hydration.fold`) tags identical across reloads and devices.
    private static func assistantFinalText(_ m: ChatMessage) -> String {
        let lastTool = m.parts.lastIndex { if case .tool = $0 { return true } else { return false } }
        let tailStart = lastTool.map { $0 + 1 } ?? 0
        let tail = m.parts[tailStart...].compactMap { part -> String? in
            guard case .text(let t) = part else { return nil }
            let clean = ChatText.trimmed(ReasoningTags.strip(t))
            return clean.isEmpty || Hydration.isSilentWords(clean) ? nil : clean
        }.joined(separator: " ")
        if !tail.isEmpty { return tail }
        for part in m.parts.reversed() {
            guard case .text(let t) = part else { continue }
            let clean = ChatText.trimmed(ReasoningTags.strip(t))
            if !clean.isEmpty && !Hydration.isSilentWords(clean) { return clean }
        }
        return ""
    }

    private static func userFoldTags(_ m: ChatMessage) -> [String] {
        guard m.role == .user else { return [] }
        let raw = userTextJoined(m)
        if raw.contains(InflightCorrections.joinMarker) {
            return raw.components(separatedBy: InflightCorrections.joinMarker)
                .compactMap { foldTag(role: .user, text: $0) }
        }
        return foldTag(role: .user, text: raw).map { [$0] } ?? []
    }

    private static func assistantFoldTag(_ m: ChatMessage) -> String? {
        guard m.role == .assistant else { return nil }
        let finalText = assistantFinalText(m)
        guard !finalText.isEmpty else { return nil }
        return foldTag(role: .assistant, text: finalText)
    }

    // MARK: Thread-safe bounded cache (eliminates repeated per-frame record/lookback hashing)

    private final class FoldCache: @unchecked Sendable {
        private struct Entry {
            var fingerprint: Int
            var hiddenIds: Set<String>
            var hiddenRowIds: Set<Int>
            var excludedIds: Set<String>
            var result: Set<Int>
        }

        private let lock = NSLock()
        private var parsedMap: [String: Found] = [:]
        private var foldedEntries: [Entry] = []

        func parsed(for raw: String) -> Found? {
            lock.withLock { parsedMap[raw] }
        }

        func storeParsed(_ found: Found, for raw: String) {
            lock.withLock {
                if parsedMap.count >= 64 { parsedMap.removeAll(keepingCapacity: true) }
                parsedMap[raw] = found
            }
        }

        func folded(fingerprint: Int, hiddenIds: Set<String>, hiddenRowIds: Set<Int>, excludedIds: Set<String>) -> Set<Int>? {
            lock.withLock {
                for i in foldedEntries.indices.reversed() {
                    let e = foldedEntries[i]
                    if e.fingerprint == fingerprint && e.hiddenIds == hiddenIds
                        && e.hiddenRowIds == hiddenRowIds && e.excludedIds == excludedIds {
                        return e.result
                    }
                }
                return nil
            }
        }

        func storeFolded(_ result: Set<Int>, fingerprint: Int, hiddenIds: Set<String>, hiddenRowIds: Set<Int>, excludedIds: Set<String>) {
            lock.withLock {
                if foldedEntries.count >= 12 { foldedEntries.removeFirst() }
                foldedEntries.append(Entry(fingerprint: fingerprint, hiddenIds: hiddenIds, hiddenRowIds: hiddenRowIds,
                                           excludedIds: excludedIds, result: result))
            }
        }
    }

    private static let cache = FoldCache()

    private static func sampleText(_ text: String, into hasher: inout Hasher) {
        var copy = text
        let count = copy.utf8.count
        hasher.combine(count)
        copy.withUTF8 { buf in
            if count <= 256 {
                hasher.combine(bytes: UnsafeRawBufferPointer(buf))
            } else {
                hasher.combine(bytes: UnsafeRawBufferPointer(UnsafeBufferPointer(rebasing: buf.prefix(128))))
                hasher.combine(bytes: UnsafeRawBufferPointer(UnsafeBufferPointer(rebasing: buf.suffix(128))))
            }
        }
    }

    private static func hashMessage(_ m: ChatMessage, at index: Int, into hasher: inout Hasher) {
        hasher.combine(index)
        hasher.combine(m.id)
        hasher.combine(m.role)
        hasher.combine(m.revision)
        hasher.combine(m.rowId)
        hasher.combine(m.reactionRow)
        hasher.combine(m.isStreaming)
        hasher.combine(m.interrupted)
        hasher.combine(m.error != nil)
        hasher.combine(m.reactions.count)
        hasher.combine(m.sender != nil)
        hasher.combine(m.job != nil)
        hasher.combine(m.phoneResultText != nil)
        hasher.combine(m.timestamp?.timeIntervalSince1970)
        hasher.combine(m.parts.count)
        for part in m.parts {
            switch part {
            case .text(let t):
                hasher.combine(1)
                sampleText(t, into: &hasher)
            case .tool:
                hasher.combine(2)
            case .reasoning:
                hasher.combine(3)
            }
        }
    }

    private static func computeCacheFingerprint(messages: [ChatMessage], recordIndices: [Int],
                                              hiddenIds: Set<String>, hiddenRowIds: Set<Int>,
                                              excludedIds: Set<String>) -> Int {
        var hasher = Hasher()
        hasher.combine(recordIndices)
        // Hash only messages within record lookback windows (plus any active hidden/excluded hits) so streaming deltas
        // on newer messages outside old records' windows stay 100% cache-hot.
        var ranges: [ClosedRange<Int>] = []
        for r in recordIndices {
            let lo = max(0, r - maxFoldLookback)
            if let last = ranges.last, lo <= last.upperBound + 1 {
                ranges[ranges.count - 1] = last.lowerBound...max(last.upperBound, r)
            } else {
                ranges.append(lo...r)
            }
        }
        var hashedIndices = Set<Int>()
        for span in ranges {
            for i in span {
                hashedIndices.insert(i)
                hashMessage(messages[i], at: i, into: &hasher)
            }
        }
        if !hiddenIds.isEmpty || !hiddenRowIds.isEmpty || !excludedIds.isEmpty {
            for i in messages.indices where !hashedIndices.contains(i) {
                let m = messages[i]
                if hiddenIds.contains(m.id) || matchesAnyRow(m, in: hiddenRowIds) || excludedIds.contains(m.id) {
                    hashMessage(m, at: i, into: &hasher)
                }
            }
        }
        return hasher.finalize()
    }

    // MARK: Folding delegated live-voice turns into their Voice Chat card

    /// Indices of messages in `messages` whose spoken Q&A belongs inside a live voice call or a `VoiceChatRecord` pill.
    /// Includes:
    /// 1. Live in-flight delegated messages (or pending-record holds) tracked by `hiddenIds` / `hiddenRowIds`.
    /// 2. Persisted delegated turns named in each `VoiceChatRecord`'s `[folded: ...]` content-hash tokens. Never runs
    ///    retrospective text matching when explicit fold metadata is present.
    /// 3. Tightened retrospective matching ONLY for historical records written before explicit fold metadata existed.
    /// Messages in `excludedIds` (for example messages carrying an attached thread) keep their whole turn visible.
    static func foldedIndices(in messages: [ChatMessage], hiddenIds: Set<String> = [],
                              hiddenRowIds: Set<Int> = [], excludedIds: Set<String> = []) -> Set<Int> {
        var recordIndices: [Int] = []
        for i in messages.indices {
            let m = messages[i]
            if m.role == .user, m.sender == nil, m.job == nil, m.error == nil,
               let firstText = firstTextPart(m), firstText.hasPrefix(markLead) {
                recordIndices.append(i)
            }
        }
        if recordIndices.isEmpty && hiddenIds.isEmpty && hiddenRowIds.isEmpty { return [] }
        let fp = computeCacheFingerprint(messages: messages, recordIndices: recordIndices,
                                         hiddenIds: hiddenIds, hiddenRowIds: hiddenRowIds, excludedIds: excludedIds)
        if let hit = cache.folded(fingerprint: fp, hiddenIds: hiddenIds, hiddenRowIds: hiddenRowIds, excludedIds: excludedIds) {
            return hit
        }

        var folded: Set<Int> = []
        if !hiddenIds.isEmpty || !hiddenRowIds.isEmpty {
            for i in messages.indices {
                let m = messages[i]
                guard m.error == nil, m.reactions.isEmpty, !excludedIds.contains(m.id) else { continue }
                if hiddenIds.contains(m.id) || matchesAnyRow(m, in: hiddenRowIds) {
                    folded.insert(i)
                }
            }
            // If an assistant reply is excluded (e.g. carries a thread), keep its paired user prompt visible too.
            if !excludedIds.isEmpty {
                for i in messages.indices where messages[i].role == .assistant && excludedIds.contains(messages[i].id) {
                    var back = i - 1
                    while back >= 0 {
                        let prev = messages[back]
                        if prev.role == .user, prev.sender == nil, prev.job == nil, !isRecordMessage(prev) {
                            folded.remove(back)
                            break
                        }
                        back -= 1
                    }
                }
            }
        }
        for r in recordIndices {
            let recMsg = messages[r]
            guard let record = parse(recMsg.plainText) else { continue }
            if record.hasExplicitFoldMetadata {
                // 1. Explicit content-hash turn tags (immune to row-id renumbering on rewind, works across all devices,
                // and skips over interleaved records from quick redials).
                if !record.foldedTurns.isEmpty {
                    let floor = max(0, r - maxFoldLookback)
                    applyExplicitTurnFolds(record.foldedTurns, in: messages, range: floor..<r,
                                           excludedIds: excludedIds, into: &folded)
                }
                // Explicit fold metadata (including `[folded: none]`) is authoritative: never run legacy text matching.
                continue
            }
            // 2. Conservative time-window + transcript matching ONLY for historical pre-metadata records.
            guard !record.userLines.isEmpty else { continue }
            let userJoined = record.userLines.joined(separator: " ")
            let userNorm = normalizedText(userJoined)
            let userCorpus = " " + userNorm + " "
            let userTokenSet = Set(userNorm.split(separator: " ").map(String.init))
            let assistantJoined = record.assistantLines.joined(separator: " ")
            let assistantNorm = normalizedText(assistantJoined)
            let assistantCorpus = " " + assistantNorm + " "
            let assistantTokenSet = Set(assistantNorm.split(separator: " ").map(String.init)
                .filter { $0.count >= 3 && !stopWords.contains($0) })
            let callEnd = recMsg.timestamp
            let callSpan = max(record.durationSeconds ?? 0, 30) + 120
            let retroFloor = max(0, r - retroLookback)
            for u in stride(from: r - 1, through: retroFloor, by: -1) {
                let m = messages[u]
                if isRecordMessage(m) { break }
                if let callEnd, let t = m.timestamp, t < callEnd.addingTimeInterval(-callSpan) { break }
                guard !excludedIds.contains(m.id), isPlainDelegatedUserCandidate(m) else { continue }
                if let callEnd, let t = m.timestamp, t > callEnd.addingTimeInterval(5) { continue }
                guard matchesUserTurn(m.plainText, boundedCorpus: userCorpus, tokenSet: userTokenSet) else { continue }
                var assistantIndices: [Int] = []
                var scan = u + 1
                while scan < r {
                    let next = messages[scan]
                    if next.role == .user, next.sender == nil, next.job == nil { break }
                    if next.role == .assistant, next.sender == nil {
                        assistantIndices.append(scan)
                    }
                    scan += 1
                }
                // Require at least one reply (never fold an unpaired user prompt) and verify every reply was spoken.
                guard !assistantIndices.isEmpty else { continue }
                let allRepliesFoldable = assistantIndices.allSatisfy { a in
                    let reply = messages[a]
                    guard !reply.isStreaming, reply.error == nil, reply.reactions.isEmpty,
                          !excludedIds.contains(reply.id) else { return false }
                    if folded.contains(a) { return true }
                    let text = ChatText.trimmed(ReasoningTags.strip(reply.plainText))
                    if text.isEmpty || Hydration.isSilentWords(text) { return true }
                    if reply.interrupted { return false }
                    return matchesAssistantReply(text, boundedCorpus: assistantCorpus, tokenSet: assistantTokenSet)
                }
                if allRepliesFoldable {
                    folded.insert(u)
                    for a in assistantIndices { folded.insert(a) }
                }
            }
        }
        cache.storeFolded(folded, fingerprint: fp, hiddenIds: hiddenIds, hiddenRowIds: hiddenRowIds, excludedIds: excludedIds)
        return folded
    }

    private struct CandidateTurn {
        var userIndex: Int
        var assistantIndices: [Int]
        var userTags: [String]
        var assistantTags: [String]
        var eligible: Bool
    }

    /// Pairs each non-record user prompt in `range` with its following assistant replies and greedily matches
    /// newest-first against `turns`, so repeated identical questions never steal a match from an earlier turn.
    private static func applyExplicitTurnFolds(_ turns: [FoldedTurn], in messages: [ChatMessage],
                                               range: Range<Int>, excludedIds: Set<String>,
                                               into folded: inout Set<Int>) {
        var candidates: [CandidateTurn] = []
        var i = range.lowerBound
        while i < range.upperBound {
            let m = messages[i]
            if m.role == .user, m.sender == nil, m.job == nil, !isRecordMessage(m) {
                var aList: [Int] = []
                var scan = i + 1
                while scan < range.upperBound {
                    let next = messages[scan]
                    if next.role == .user, next.sender == nil, next.job == nil, !isRecordMessage(next) { break }
                    if next.role == .assistant, next.sender == nil { aList.append(scan) }
                    scan += 1
                }
                let eligible = !excludedIds.contains(m.id) && isPlainDelegatedUserCandidate(m)
                    && aList.allSatisfy { a in
                        let r = messages[a]
                        return !r.isStreaming && r.error == nil && r.reactions.isEmpty && !excludedIds.contains(r.id)
                    }
                candidates.append(CandidateTurn(userIndex: i, assistantIndices: aList,
                                                userTags: userFoldTags(m),
                                                assistantTags: aList.compactMap { assistantFoldTag(messages[$0]) },
                                                eligible: eligible))
                i = scan
            } else {
                i += 1
            }
        }
        var remaining = turns
        var idx = candidates.count - 1
        while idx >= 0 && !remaining.isEmpty {
            let cand = candidates[idx]
            guard cand.eligible, !cand.userTags.isEmpty else { idx -= 1; continue }
            // 1. Exact user + assistant tags match.
            if let hit = remaining.lastIndex(where: { $0.userTags == cand.userTags && $0.assistantTags == cand.assistantTags }) {
                remaining.remove(at: hit)
                folded.insert(cand.userIndex)
                for a in cand.assistantIndices { folded.insert(a) }
                idx -= 1
                continue
            }
            // 2. Resilient assistant-overlap match when user tags match inside the call window (handles minor
            // hydration differences such as multi-bubble folding or commentary removal on reload).
            if !cand.assistantTags.isEmpty,
               let hit = remaining.lastIndex(where: {
                   $0.userTags == cand.userTags && !$0.assistantTags.isEmpty
                       && !Set($0.assistantTags).isDisjoint(with: cand.assistantTags)
               }) {
                remaining.remove(at: hit)
                folded.insert(cand.userIndex)
                for a in cand.assistantIndices { folded.insert(a) }
                idx -= 1
                continue
            }
            // 3. A steered turn saved as separate user rows (`U1`, `[A1_p1]`, `U1_steer`, `A1_p2`) matches a single
            // multi-user `FoldedTurn(userTags: [u1, u2], assistantTags: ...)` across consecutive candidates.
            if let (spanStart, hit) = matchMultiCandidateTurn(endingAt: idx, in: candidates, remaining: remaining) {
                remaining.remove(at: hit)
                for k in spanStart...idx {
                    folded.insert(candidates[k].userIndex)
                    for a in candidates[k].assistantIndices { folded.insert(a) }
                }
                idx = spanStart - 1
                continue
            }
            // 4. Reloaded steered turns merged by Hermes via `[Additional user correction]` carry multiple user tags in
            // one stored row; match them against consecutive folded turns whose user tags match in order.
            if cand.userTags.count > 1,
               let rangeHit = matchMergedSteerRange(cand, in: remaining) {
                remaining.removeSubrange(rangeHit)
                folded.insert(cand.userIndex)
                for a in cand.assistantIndices { folded.insert(a) }
            }
            idx -= 1
        }
    }

    private static func matchMultiCandidateTurn(endingAt end: Int, in candidates: [CandidateTurn],
                                                remaining: [FoldedTurn]) -> (spanStart: Int, matchIndex: Int)? {
        guard remaining.contains(where: { $0.userTags.count > 1 }) else { return nil }
        var users = candidates[end].userTags
        var assistants = candidates[end].assistantTags
        var start = end - 1
        while start >= 0 && end - start < 6 {
            let prev = candidates[start]
            guard prev.eligible, !prev.userTags.isEmpty else { break }
            users = prev.userTags + users
            assistants = prev.assistantTags + assistants
            if let hit = remaining.lastIndex(where: {
                $0.userTags == users && ($0.assistantTags == assistants
                    || (!assistants.isEmpty && !Set($0.assistantTags).isDisjoint(with: assistants)))
            }) {
                return (start, hit)
            }
            start -= 1
        }
        return nil
    }

    private static func matchMergedSteerRange(_ cand: CandidateTurn, in remaining: [FoldedTurn]) -> ClosedRange<Int>? {
        for end in stride(from: remaining.count - 1, through: 0, by: -1) {
            var collectedUsers: [String] = []
            var collectedAssistants: [String] = []
            for start in stride(from: end, through: 0, by: -1) {
                collectedUsers = remaining[start].userTags + collectedUsers
                collectedAssistants = remaining[start].assistantTags + collectedAssistants
                if collectedUsers == cand.userTags {
                    if collectedAssistants == cand.assistantTags
                        || (!cand.assistantTags.isEmpty && !Set(collectedAssistants).isDisjoint(with: cand.assistantTags)) {
                        return start...end
                    }
                    break
                }
                if collectedUsers.count >= cand.userTags.count { break }
            }
        }
        return nil
    }

    /// The earliest message index at or above `floor` whose folded state is affected by any `VoiceChatRecord` in
    /// `lo..<messages.count`, so incremental row rebuilds fold (or unfold on error) earlier bubbles immediately.
    static func reach(from lo: Int, floor: Int, in messages: [ChatMessage]) -> Int {
        guard lo < messages.count else { return lo }
        var earliest = lo
        var hasRecord = false
        var hasErroredRecord = false
        for r in lo..<messages.count where isRecordMessage(messages[r]) {
            hasRecord = true
            earliest = min(earliest, max(floor, r - maxFoldLookback))
            if messages[r].error != nil { hasErroredRecord = true }
        }
        guard hasRecord else { return lo }
        if hasErroredRecord { return earliest }
        let folded = foldedIndices(in: messages)
        if let firstFolded = folded.filter({ $0 >= earliest && $0 < lo }).min() {
            return max(floor, firstFolded)
        }
        return lo
    }

    private static func firstTextPart(_ m: ChatMessage) -> String? {
        for part in m.parts {
            if case .text(let t) = part, !t.isEmpty { return t }
        }
        return nil
    }

    private static func matchesAnyRow(_ m: ChatMessage, in rows: Set<Int>) -> Bool {
        if let rowId = m.rowId, rows.contains(rowId) { return true }
        if let reactionRow = m.reactionRow, rows.contains(reactionRow) { return true }
        return false
    }

    private static func isRecordMessage(_ m: ChatMessage) -> Bool {
        guard m.role == .user, m.sender == nil, m.job == nil,
              let first = firstTextPart(m), first.hasPrefix(markLead) else { return false }
        return isRecord(m.plainText)
    }

    private static func isPlainDelegatedUserCandidate(_ m: ChatMessage) -> Bool {
        guard m.role == .user, m.sender == nil, m.job == nil, m.phoneResultText == nil,
              m.error == nil, m.reactions.isEmpty else { return false }
        let text = m.plainText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !isRecord(text), VoiceMemo.parse(text) == nil else { return false }
        return true
    }

    private static func matchesUserTurn(_ text: String, boundedCorpus: String, tokenSet: Set<String>) -> Bool {
        let norm = normalizedText(text)
        let words = norm.split(separator: " ").map(String.init)
        guard words.count >= 2 else { return false }
        if boundedCorpus.contains(" " + norm + " ") { return true }
        // Short prompts (≤ 4 words) require an exact word-bounded substring match so common words like "do it" never
        // match by bag-of-words overlap.
        guard words.count >= 5 else { return false }
        let sig = words.filter { $0.count >= 3 && !stopWords.contains($0) }
        guard sig.count >= 3 else { return false }
        let hits = sig.filter { tokenSet.contains($0) }.count
        return Double(hits) / Double(sig.count) >= 0.70
    }

    private static func matchesAssistantReply(_ text: String, boundedCorpus: String, tokenSet: Set<String>) -> Bool {
        guard !tokenSet.isEmpty else { return false }
        let norm = normalizedText(text)
        guard !norm.isEmpty else { return true }
        if boundedCorpus.contains(" " + norm + " ") { return true }
        let sig = significantTokens(text)
        guard sig.count >= 3 else { return false }
        let hits = sig.filter { tokenSet.contains($0) }.count
        let ratio = Double(hits) / Double(sig.count)
        if sig.count < 6 { return ratio >= 0.60 && hits >= 3 }
        return ratio >= 0.40 && hits >= 3
    }

    private static func normalizedText(_ text: String) -> String {
        let folded = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
        var out = ""
        out.reserveCapacity(folded.count)
        var lastWasSpace = true
        for ch in folded {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastWasSpace = false
            } else if ch == "'" {
                // Keep apostrophe-joined contractions consistent ("no one's" / "what's").
                continue
            } else if !lastWasSpace {
                out.append(" ")
                lastWasSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    private static func tokens(_ text: String) -> [String] {
        normalizedText(text).split(separator: " ").map(String.init)
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "that", "this", "with", "from", "are", "was", "were", "you", "your",
        "have", "has", "had", "not", "but", "they", "them", "their", "its", "about", "just",
        "into", "what", "when", "where", "which", "who", "how", "will", "would", "could", "should",
        "can", "did", "does", "been", "being", "also", "then", "than", "there", "here", "some", "more",
    ]

    private static func significantTokens(_ text: String) -> [String] {
        tokens(text).filter { $0.count >= 3 && !stopWords.contains($0) }
    }
}
