// [groups] Stop / resume directives in your own room messages (docs/spec/3x-groups.md §6.4): a port of
// `classifyGroupHoldDirective`, `maskQuotedAndCodeSpans`, `stopWordPlacement` and `applyGroupHoldDirective`
// (`HB/group-rounds.ts:240-415`). Pure.

import Foundation

nonisolated enum GroupHolds {
    enum Placement: Equatable, Sendable { case adjacent, distant }

    struct Action: Equatable, Sendable {
        var hold: [String] = []
        var holdAll = false
        var release: [String] = []
        var releaseAll = false
    }

    private static let mentionToken = try! NSRegularExpression(pattern: "@[\\p{L}\\p{N}._-]+")
    private static let token = try! NSRegularExpression(pattern: "@[\\p{L}\\p{N}._-]+|[\\p{L}\\p{N}_-]+")
    private static let fenceOpen = try! NSRegularExpression(pattern: "^\\s*(`{3,}|~{3,})")
    private static let inlineCode = try! NSRegularExpression(pattern: "`[^`\\n]*`")
    private static let quoted = try! NSRegularExpression(pattern: "[\"“”][^\"“”\\n]*[\"“”]")

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> [String] {
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).map { source.substring(with: $0.range) }
    }

    private static func mentionsOnly(_ span: String) -> String {
        let found = matches(mentionToken, span)
        return found.isEmpty ? "quoted" : found.joined(separator: " ")
    }

    private static func replacingMatches(_ regex: NSRegularExpression, in text: String) -> String {
        let source = text as NSString
        var out = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            out += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            out += mentionsOnly(source.substring(with: match.range))
            cursor = match.range.location + match.range.length
        }
        out += source.substring(from: cursor)
        return out
    }

    /// Fenced code, `>` quotes, inline code and quoted strings reduced to their @mentions (so a quoted "stop" is not
    /// a command).
    static func masked(_ value: String) -> String {
        var kept: [String] = []
        var fence = ""
        for line in value.components(separatedBy: "\n") {
            if !fence.isEmpty {
                let closing = line.trimmingCharacters(in: .whitespaces).hasPrefix(fence)
                kept.append(closing ? "" : mentionsOnly(line))
                if closing { fence = "" }
                continue
            }
            let source = line as NSString
            if let opened = fenceOpen.firstMatch(in: line, range: NSRange(location: 0, length: source.length)) {
                fence = source.substring(with: opened.range(at: 1))
                continue
            }
            if line.range(of: "^\\s*>", options: .regularExpression) != nil {
                kept.append(mentionsOnly(line))
                continue
            }
            kept.append(replacingMatches(quoted, in: replacingMatches(inlineCode, in: line)))
        }
        return kept.joined(separator: "\n")
    }

    static func stopWordPlacement(_ value: String) -> Placement? {
        let tokens = matches(token, masked(value).lowercased())
        var mentionAt: [Int] = []
        var stopAt: [Int] = []
        for (index, token) in tokens.enumerated() {
            if token.hasPrefix("@") { mentionAt.append(index) }
            else if token == "stop" || token == "halt" || token == "pause" { stopAt.append(index) }
        }
        if stopAt.contains(where: { stop in mentionAt.contains { abs(stop - $0) <= 2 } }) { return .adjacent }
        return stopAt.isEmpty ? nil : .distant
    }

    static func classify(_ text: String, mentioned: [String], everyone: Bool) -> Action {
        let stop = stopWordPlacement(text)
        if stop == .adjacent { return Action(hold: mentioned, holdAll: everyone) }
        return Action(release: stop == .distant ? [] : mentioned, releaseAll: stop == nil && everyone)
    }

    static func apply(_ holds: [String: GroupHold], mentions: GroupMentions.Parsed, text: String, stamp: GroupHold,
                      allMemberKeys: [String]) -> [String: GroupHold] {
        let action = classify(text, mentioned: mentions.mentioned, everyone: mentions.everyone)
        if action.releaseAll { return [:] }
        var next = holds
        for key in action.holdAll ? allMemberKeys : action.hold { next[key] = stamp }
        for key in action.release { next[key] = nil }
        return next
    }
}
