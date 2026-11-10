// [groups] @mentions in a room (docs/spec/3x-groups.md §6.3): a port of `parseGroupChatMentions`
// (`HB/group-rounds.ts:53-150`) and of the tag helpers in `HB/data.ts:1011-1075`. Pure.

import Foundation

nonisolated enum GroupMentions {
    private static let mention = try! NSRegularExpression(pattern: "@([a-z0-9][a-z0-9._-]*)", options: [.caseInsensitive])
    private static let reserved: Set<String> = ["all", "everyone", "user", "default", "hermes"]

    private static func replacing(_ text: String, _ pattern: String, with replacement: String) -> String {
        text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }

    /// `botHandle`: `hermes` for the default profile, else the row's handle or the name.
    static func handle(name: String, saved: String?) -> String {
        if name == "default" { return "hermes" }
        let saved = (saved ?? "").trimmingCharacters(in: .whitespaces)
        return saved.isEmpty || saved == "default" ? name : saved
    }

    /// `mentionNameForms`: a friendly name's slug ("research-buddy") and collapsed form ("researchbuddy"); never a
    /// reserved word, always a valid tag.
    static func nameForms(_ friendly: String) -> [String] {
        let lower = friendly.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return [] }
        var slug = replacing(lower, "[^a-z0-9_-]+", with: "-")
        while slug.hasPrefix("-") { slug.removeFirst() }
        while slug.hasSuffix("-") { slug.removeLast() }
        let collapsed = replacing(lower, "[^a-z0-9_-]+", with: "")
        var out: [String] = []
        for form in [slug, collapsed] where !out.contains(form) {
            guard form.range(of: "^[a-z0-9][a-z0-9_-]*$", options: .regularExpression) != nil, !reserved.contains(form) else { continue }
            out.append(form)
        }
        return out
    }

    /// `botMentionTag`: the first form of the member's friendly names, else its handle.
    static func tag(for seat: GroupSeat) -> String {
        for friendly in seat.friendly {
            if let form = nameForms(friendly).first { return form }
        }
        return seat.handle
    }

    /// Every form → member key, built with the web's precedence (live identities claim first; slugs and earlier
    /// names only fill gaps).
    static func handles(_ seats: [GroupSeat]) -> [String: String] {
        var handles: [String: String] = [:]
        for seat in seats {
            let name = seat.name.lowercased()
            let title = (seat.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let handle = seat.handle.trimmingCharacters(in: .whitespaces).lowercased()
            var forms: [String] = [name, replacing(name, "[\\s_-]+", with: "")]
            if !handle.isEmpty { forms += [handle, replacing(handle, "[\\s_-]+", with: "")] }
            if !title.isEmpty {
                let lower = title.lowercased()
                forms += [lower, replacing(lower, "[\\s_-]+", with: ""),
                          lower.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""]
            }
            for friendly in seat.friendly { forms += nameForms(friendly) }
            if !seat.remote { forms.append("\(name)-local") }
            for form in forms where !form.isEmpty { handles[form] = seat.key }
            for raw in [seat.name, seat.handle, title] + seat.friendly {
                for form in nameForms(raw) where handles[form] == nil { handles[form] = seat.key }
            }
        }
        for seat in seats {
            for previous in seat.previousNames {
                for form in nameForms(previous) where handles[form] == nil { handles[form] = seat.key }
            }
        }
        return handles
    }

    struct Parsed: Equatable, Sendable {
        var everyone = false
        /// Member keys, in the order first mentioned.
        var mentioned: [String] = []
    }

    static func parse(_ text: String, seats: [GroupSeat]) -> Parsed {
        var out = Parsed()
        let handles = handles(seats)
        let source = text as NSString
        for match in mention.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let handle = source.substring(with: match.range(at: 1)).lowercased()
            if handle == "everyone" || handle == "all" { out.everyone = true; continue }
            if handle == "user" { continue }
            let resolved = handles[handle] ?? handles[replacing(handle, "[._-]+", with: "")]
            if let resolved, !out.mentioned.contains(resolved) { out.mentioned.append(resolved) }
        }
        return out
    }

    /// The `@word` being typed at the end of `text` (the composer's suggestion list); nil when the caret is not in one.
    static func typingQuery(_ text: String) -> String? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        if at > text.startIndex {
            let before = text[text.index(before: at)]
            if !(before.isWhitespace || before.isNewline) { return nil }
        }
        let tail = text[text.index(after: at)...]
        if tail.contains(where: { $0.isWhitespace || $0.isNewline }) { return nil }
        return String(tail).lowercased()
    }
}
