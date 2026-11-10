// Keys for a controlled screen (docs/spec/3x-screen.md §5.6), a port of the web app's keysym rules: Latin-1 maps to
// itself, anything else is 0x01000000 + code point; modifiers go down in the order shift, ctrl, alt, meta and come up
// in reverse; ⌘ is Super_L and ⌥ is Alt_L, as the Mac helper maps them.

import Foundation

nonisolated enum ScreenKeys {
    enum Modifier: Int, CaseIterable, Sendable, Hashable {
        case shift, ctrl, alt, meta

        var keysym: UInt32 {
            switch self {
            case .shift: 0xFFE1
            case .ctrl: 0xFFE3
            case .alt: 0xFFE9
            case .meta: 0xFFEB
            }
        }
    }

    /// Audit 09-18: Home, End, Page Up/Down and F1–F12 too, from a hardware keyboard (the web's list stopped at the
    /// arrows).
    enum Named: String, CaseIterable, Sendable {
        case backspace, tab, enter, escape, delete, left, up, right, down
        case home, end, pageUp, pageDown
        case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12

        /// F1 to F12, in order.
        static let function: [Named] = [.f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12]

        var keysym: UInt32 {
            if let index = Self.function.firstIndex(of: self) { return 0xFFBE + UInt32(index) }
            return switch self {
            case .backspace: 0xFF08
            case .tab: 0xFF09
            case .enter: 0xFF0D
            case .escape: 0xFF1B
            case .delete: 0xFFFF
            case .left: 0xFF51
            case .up: 0xFF52
            case .right: 0xFF53
            case .down: 0xFF54
            case .home: 0xFF50
            case .end: 0xFF57
            case .pageUp: 0xFF55
            case .pageDown: 0xFF56
            case .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12: 0xFFBE
            }
        }
    }

    static let maxCutText = RFBMessage.maxCutText
    /// Typed text goes out this many characters per turn of the run loop (DECISION D18).
    static let typingSlice = 500

    /// X11 keysym for a Unicode code point.
    static func keysym(for codePoint: UInt32) -> UInt32 {
        if (0x20...0x7E).contains(codePoint) || (0xA0...0xFF).contains(codePoint) { return codePoint }
        return 0x0100_0000 + codePoint
    }

    /// The key pressed and released under `mods`: modifiers down in order, the key, modifiers up in reverse.
    static func chord(_ keysym: UInt32, mods: Set<Modifier> = []) -> [Data] {
        let held = Modifier.allCases.filter(mods.contains)
        var out = held.map { RFBMessage.key($0.keysym, down: true) }
        out.append(RFBMessage.key(keysym, down: true))
        out.append(RFBMessage.key(keysym, down: false))
        out += held.reversed().map { RFBMessage.key($0.keysym, down: false) }
        return out
    }

    /// Typed text: one key press per code point, each under the held modifiers. A line break is Return and a tab is
    /// Tab (DECISION: the web sent their raw code points, which no desktop understands); a carriage return is dropped.
    static func text(_ text: String, mods: Set<Modifier> = []) -> [Data] {
        var out: [Data] = []
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0D: continue
            case 0x0A: out += chord(Named.enter.keysym, mods: mods)
            case 0x09: out += chord(Named.tab.keysym, mods: mods)
            default: out += chord(keysym(for: scalar.value), mods: mods)
            }
        }
        return out
    }

    /// The text as Latin-1 bytes when every code point is at most U+00FF and it fits a ClientCutText; nil otherwise
    /// (it is typed instead).
    static func latin1(_ text: String) -> [UInt8]? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            guard scalar.value <= 0xFF else { return nil }
            bytes.append(UInt8(scalar.value))
            if bytes.count > maxCutText { return nil }
        }
        return bytes
    }

    enum Paste: Equatable, Sendable {
        /// Nothing to paste: the pill "There’s no text to paste.".
        case empty
        /// A Mac host and Latin-1 text: the remote clipboard is set, then ⌘V.
        case clipboard([Data])
        /// Anything else is typed key by key.
        case typed(String)
    }

    static func paste(_ text: String?, mac: Bool) -> Paste {
        guard let text, !text.isEmpty else { return .empty }
        if mac, let bytes = latin1(text) { return .clipboard([RFBMessage.cutText(bytes)] + chord(0x76, mods: [.meta])) }
        return .typed(text)
    }

    /// What a text field change means: nothing while an input method is still composing, the text once it commits.
    static func committed(_ text: String?, composing: Bool) -> String? {
        guard !composing, let text, !text.isEmpty else { return nil }
        return text
    }
}

/// Typed text waiting to go out in slices, so a long paste never stalls the app; `cancel` drops the rest (hand back,
/// control lost, Close).
nonisolated struct ScreenTyper: Sendable {
    private var pending: [Character] = []
    private var mods: Set<ScreenKeys.Modifier> = []

    var isEmpty: Bool { pending.isEmpty }
    var count: Int { pending.count }

    mutating func add(_ text: String, mods: Set<ScreenKeys.Modifier>) {
        pending += Array(text)
        self.mods = mods
    }

    /// The next slice's key events (at most `ScreenKeys.typingSlice` characters).
    mutating func next() -> [Data] {
        guard !pending.isEmpty else { return [] }
        let slice = String(pending.prefix(ScreenKeys.typingSlice))
        pending.removeFirst(min(ScreenKeys.typingSlice, pending.count))
        return ScreenKeys.text(slice, mods: mods)
    }

    mutating func cancel() { pending = [] }
}
