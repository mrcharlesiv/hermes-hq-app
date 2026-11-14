// [groups] The words of a room: its Bots-list second line, "1 bot" / "N bots", typing and paused lines, and the
// Activity page's lines (docs/spec/3x-groups.md §7.1, §7.2, §7.13; `S/ui-bots/row-status.ts`, `HB/group-activity.ts`).

import Foundation

nonisolated enum GroupRowWords {
    enum Tone: Sendable { case secondary, tint, orange }

    struct Line: Equatable, Sendable {
        var text: String
        var tone: Tone
    }

    static func bots(_ count: Int) -> String { count == 1 ? "1 bot" : "\(count) bots" }

    /// `Ivy is replying…` / `Ivy and Research are replying…` / `Ivy, Research and 2 more are replying…`.
    static func replying(_ names: [String]) -> String {
        switch names.count {
        case 0: return "Replying…"
        case 1: return "\(names[0]) is replying…"
        case 2: return "\(names[0]) and \(names[1]) are replying…"
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) more are replying…"
        }
    }

    static func paused(_ names: [String]) -> String { names.count == 1 ? "\(names[0]) is paused" : "\(names.count) bots paused" }

    /// The room's title-bar line when nothing runs: the members' names, or `N bots` when that is long.
    /// An empty room's second line: every name, or `No bots yet`.
    static func membersOrNone(_ names: [String]) -> String { names.isEmpty ? "No bots yet" : names.joined(separator: ", ") }

    static func members(_ names: [String]) -> String {
        let joined = names.joined(separator: ", ")
        return joined.isEmpty ? "No bots yet" : (joined.count > 32 ? bots(names.count) : joined)
    }

    /// `You: <text>` / `Ivy: <text>`, Markdown stripped, `…` when it has no words.
    static func preview(_ entry: GroupMessage, labels: [String: String]) -> String {
        let who = entry.from.kind == .user ? "You" : (labels[entry.from.name] ?? entry.from.name)
        let said = VoiceMemo.parse(entry.text)?.transcriptLine ?? entry.text   // a voice memo: "Voice Memo: <words>"
        let flat = RosterPreview.stripMarkdown(said).split(whereSeparator: { $0.isNewline || $0.isWhitespace }).joined(separator: " ")
        let text = String(flat.prefix(160))
        return "\(who): \(text.isEmpty ? "…" : text)"
    }

    /// The row's second line, first state that applies (§7.1's table).
    static func secondLine(waitingOnUser: Bool, replying names: [String], available: Int, driven: Int, offline: Bool,
                           last: GroupMessage?, labels: [String: String], memberCount: Int) -> Line {
        if waitingOnUser { return Line(text: "Waiting for your reply", tone: .orange) }
        if !names.isEmpty { return Line(text: replying(names), tone: .tint) }
        if driven > 0, offline || available < driven { return Line(text: "\(offline ? 0 : available) of \(driven) available", tone: .orange) }
        if let last { return Line(text: preview(last, labels: labels), tone: .secondary) }
        return Line(text: bots(memberCount), tone: .secondary)
    }

    struct ActivityLine: Equatable, Sendable {
        var text: String
        var symbol: String
        var red = false
    }

    /// One Activity line (§7.2's table). `name` is the member's display name.
    static func activity(_ event: GroupActivityEvent, name: String) -> ActivityLine {
        switch event.kind {
        case .queued: return ActivityLine(text: "You sent a message", symbol: "bubble.left")
        case .working: return ActivityLine(text: "\(name) is working…", symbol: "arrow.triangle.2.circlepath")
        case .replied: return ActivityLine(text: "\(name) replied", symbol: "checkmark")
        case .passed: return ActivityLine(text: "\(name) passed", symbol: "circle")
        case .timedOut: return ActivityLine(text: "\(name) took too long", symbol: "clock", red: true)
        case .failed:
            let reason = (event.detail ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if reason == "no-slot" { return ActivityLine(text: "\(name) couldn't start — too many bots running", symbol: "exclamationmark.circle", red: true) }
            return ActivityLine(text: reason.isEmpty ? "\(name) hit an error" : "\(name) hit an error — \(reason)", symbol: "exclamationmark.circle", red: true)
        case .cancelled: return ActivityLine(text: "Turn interrupted by a newer message", symbol: "xmark")
        case .settled: return ActivityLine(text: "Turn settled", symbol: "checkmark.circle")
        case .capped: return ActivityLine(text: "Turn stopped at the round/message cap", symbol: "forward.end")
        case .delivered: return ActivityLine(text: "\(name) delivered a late reply", symbol: "envelope.open")
        case .held: return ActivityLine(text: "\(name) is held (stopped by you) — @mention it or say resume to release", symbol: "pause")
        case .stopped: return ActivityLine(text: "You stopped the room — remaining turns are held until resumed", symbol: "stop")
        }
    }

    /// VoiceOver for a room row: `Launch Room. Ivy: I can take the notes. 2 min ago. Unread. Pinned. Muted. Hidden`.
    static func accessibilityLabel(name: String, line: String, time: String, unread: Bool, pinned: Bool, muted: Bool,
                                   hidden: Bool = false) -> String {
        var parts = [name, line]
        if !time.isEmpty { parts.append(time) }
        if unread { parts.append("Unread") }
        if pinned { parts.append("Pinned") }
        if muted { parts.append("Muted") }
        if hidden { parts.append("Hidden") }   // as a hidden bot's row is read (audit 05-10)
        // A line that already ends its own sentence ("…the notes.", "Ivy is replying…") gets no second full stop.
        return parts.enumerated().map { index, part in
            index == parts.count - 1 || part.last.map { ".…?!".contains($0) } == true ? part : part + "."
        }.joined(separator: " ")
    }
}

/// A sender's name in its bot's colour, made readable at 4.5:1 on the bubble (row L301; `S/ui-chat/name-color.ts`).
nonisolated enum NameColor {
    struct RGB: Equatable, Sendable {
        var r: Double, g: Double, b: Double
        init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
    }

    /// The web's bubbles (its own examples are measured on these).
    static let webLightBubble = RGB(242, 242, 247), webDarkBubble = RGB(44, 44, 46)
    /// The surfaces a name sits on in this app, the harder case each way: the native light bubble (#E9E9EB, darker
    /// than the web's) and the web's dark bubble (lighter than the native #26282C).
    static let lightBubble = RGB(233, 233, 235), darkBubble = RGB(44, 44, 46)

    private static func groups(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let source = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: source.length)) else { return nil }
        return (1..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : source.substring(with: match.range(at: $0)) }
    }

    /// `parseColor`: `#rgb`, `#rrggbb`, `rgb()`, `hsl()`; nil for anything else.
    static func parse(_ color: String) -> RGB? {
        let value = color.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hex = groups("^#([0-9a-f]{3}|[0-9a-f]{6})$", value)?.first {
            let digits = hex.count == 3 ? hex.map { "\($0)\($0)" }.joined() : hex
            guard let n = UInt32(digits, radix: 16) else { return nil }
            return RGB(Double((n >> 16) & 0xFF), Double((n >> 8) & 0xFF), Double(n & 0xFF))
        }
        if let rgb = groups("^rgba?\\(\\s*([\\d.]+)[\\s,]+([\\d.]+)[\\s,]+([\\d.]+)", value),
           let r = Double(rgb[0]), let g = Double(rgb[1]), let b = Double(rgb[2]) { return RGB(r, g, b) }
        if let hsl = groups("^hsla?\\(\\s*([\\d.]+)(?:deg)?[\\s,]+([\\d.]+)%[\\s,]+([\\d.]+)%", value),
           let hue = Double(hsl[0]), let sat = Double(hsl[1]), let light = Double(hsl[2]) {
            let h = hue.truncatingRemainder(dividingBy: 360) / 360, s = sat / 100, l = light / 100
            let q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q
            func channel(_ raw: Double) -> Double {
                var t = raw
                if t < 0 { t += 1 }
                if t > 1 { t -= 1 }
                let c = t < 1.0 / 6 ? p + (q - p) * 6 * t : t < 0.5 ? q : t < 2.0 / 3 ? p + (q - p) * (2.0 / 3 - t) * 6 : p
                return (c * 255).rounded()
            }
            return RGB(channel(h + 1.0 / 3), channel(h), channel(h - 1.0 / 3))
        }
        return nil
    }

    static func luminance(_ c: RGB) -> Double {
        func f(_ raw: Double) -> Double {
            let v = raw / 255
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b)
    }

    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// The colour mixed toward `toward` in steps of 5% until it holds `ratio` (4.5:1) on `surface`.
    static func readable(_ color: RGB, surface: RGB, toward: RGB, ratio: Double = 4.5) -> RGB {
        for step in 0...20 {
            let amount = Double(step) / 20
            let candidate = RGB((color.r + (toward.r - color.r) * amount).rounded(), (color.g + (toward.g - color.g) * amount).rounded(),
                                (color.b + (toward.b - color.b) * amount).rounded())
            if contrast(candidate, surface) >= ratio { return candidate }
        }
        return toward
    }

    /// The name's colour on the light and the dark bubble; nil when the colour cannot be read (the label colour then).
    static func readable(_ color: String?, light: RGB = lightBubble, dark: RGB = darkBubble) -> (light: RGB, dark: RGB)? {
        guard let color, let rgb = parse(color) else { return nil }
        return (readable(rgb, surface: light, toward: RGB(0, 0, 0)), readable(rgb, surface: dark, toward: RGB(255, 255, 255)))
    }
}

/// A message another bot delivered into a chat (row L301; `S/ui-chat/run.ts:36, 78-83`). Cron prefixes are another
/// stream's (parity L302).
nonisolated enum DeliverySender {
    private static let pattern = try! NSRegularExpression(
        pattern: "^(?:Message from (?:🤖\\s*)?([^:\\n(]{1,64}?)(?:\\s*\\(@([a-z0-9][a-z0-9_-]{0,63})(?:@[a-zA-Z0-9][a-zA-Z0-9_-]{0,63})?\\))?:\\s*|\\[Message from agent '([^']{1,64})'\\]\\s*)")

    struct Parsed: Equatable, Sendable {
        var name: String
        var handle: String
        var body: String
    }

    static func parse(_ text: String) -> Parsed? {
        let source = text as NSString
        guard let match = pattern.firstMatch(in: text, range: NSRange(location: 0, length: source.length)) else { return nil }
        func group(_ index: Int) -> String? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : source.substring(with: range)
        }
        let agent = group(3)
        let name = (group(1) ?? agent ?? "agent").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let handle = (group(2) ?? agent ?? name).trimmingCharacters(in: .whitespaces).lowercased()
        let body = source.substring(from: match.range.location + match.range.length).trimmingCharacters(in: .whitespacesAndNewlines)
        return Parsed(name: name, handle: handle, body: body)
    }
}
