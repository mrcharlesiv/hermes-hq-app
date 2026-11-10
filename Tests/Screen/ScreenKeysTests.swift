// Keys and paste for a controlled screen (docs/spec/3x-screen.md §5.6), with the web app's cases.

import Foundation
import Testing
@testable import HermesHQNative

@MainActor struct ScreenKeysTests {
    /// (keysym, down) pairs from key messages.
    private func keys(_ messages: [Data]) -> [[UInt32]] {
        messages.map { data in
            let bytes = [UInt8](data)
            guard bytes.count == 8, bytes[0] == 4 else { return [0xDEAD] }
            return [UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7]), UInt32(bytes[1])]
        }
    }

    private func press(_ keysym: UInt32) -> [[UInt32]] { [[keysym, 1], [keysym, 0]] }

    @Test func mapsTextToKeysyms() {
        #expect(ScreenKeys.keysym(for: 0x61) == 0x61)
        #expect(ScreenKeys.keysym(for: 0xE9) == 0xE9)
        #expect(ScreenKeys.keysym(for: 0x20AC) == 0x0100_20AC)
        #expect(ScreenKeys.keysym(for: 0x7F) == 0x0100_007F)
        #expect(ScreenKeys.keysym(for: 0x20) == 0x20 && ScreenKeys.keysym(for: 0x7E) == 0x7E && ScreenKeys.keysym(for: 0xA0) == 0xA0 && ScreenKeys.keysym(for: 0xFF) == 0xFF)
        #expect(keys(ScreenKeys.text("Hi😀")) == press(0x48) + press(0x69) + press(0x0101_F600))
        #expect(keys(ScreenKeys.text("你")) == press(0x0100_4F60))
    }

    @Test func modifiersGoDownInOrderAndComeUpInReverse() {
        #expect(keys(ScreenKeys.text("c", mods: [.ctrl])) == [[0xFFE3, 1], [0x63, 1], [0x63, 0], [0xFFE3, 0]])
        #expect(keys(ScreenKeys.chord(ScreenKeys.Named.left.keysym, mods: [.meta, .alt]))
            == [[0xFFE9, 1], [0xFFEB, 1], [0xFF51, 1], [0xFF51, 0], [0xFFEB, 0], [0xFFE9, 0]])
        #expect(keys(ScreenKeys.chord(0x61, mods: [.meta, .shift, .alt, .ctrl]))
            == [[0xFFE1, 1], [0xFFE3, 1], [0xFFE9, 1], [0xFFEB, 1], [0x61, 1], [0x61, 0], [0xFFEB, 0], [0xFFE9, 0], [0xFFE3, 0], [0xFFE1, 0]])
    }

    @Test func namedKeys() {
        let expected: [ScreenKeys.Named: UInt32] = [.backspace: 0xFF08, .tab: 0xFF09, .enter: 0xFF0D, .escape: 0xFF1B, .delete: 0xFFFF,
                                                    .left: 0xFF51, .up: 0xFF52, .right: 0xFF53, .down: 0xFF54,
                                                    .home: 0xFF50, .end: 0xFF57, .pageUp: 0xFF55, .pageDown: 0xFF56,
                                                    .f1: 0xFFBE, .f2: 0xFFBF, .f3: 0xFFC0, .f4: 0xFFC1, .f5: 0xFFC2, .f6: 0xFFC3,
                                                    .f7: 0xFFC4, .f8: 0xFFC5, .f9: 0xFFC6, .f10: 0xFFC7, .f11: 0xFFC8, .f12: 0xFFC9]
        for key in ScreenKeys.Named.allCases { #expect(key.keysym == expected[key]) }
        #expect(ScreenKeys.Modifier.shift.keysym == 0xFFE1 && ScreenKeys.Modifier.ctrl.keysym == 0xFFE3)
        #expect(ScreenKeys.Modifier.alt.keysym == 0xFFE9 && ScreenKeys.Modifier.meta.keysym == 0xFFEB)
    }

    @Test func lineBreaksAndTabsInTypedTextAreKeys() {
        #expect(keys(ScreenKeys.text("a\r\nb\tc")) == press(0x61) + press(0xFF0D) + press(0x62) + press(0xFF09) + press(0x63))
    }

    @Test func pasteChoosesTheClipboardOnlyForLatin1OnAMac() throws {
        #expect(ScreenKeys.paste(nil, mac: true) == .empty)
        #expect(ScreenKeys.paste("", mac: false) == .empty)
        guard case .clipboard(let messages) = ScreenKeys.paste("héllo", mac: true) else {
            Issue.record("expected the clipboard path")
            return
        }
        // ClientCutText: type 6, three padding bytes, length, Latin-1 bytes; then ⌘V.
        #expect([UInt8](try #require(messages.first)) == [6, 0, 0, 0, 0, 0, 0, 5, 0x68, 0xE9, 0x6C, 0x6C, 0x6F])
        #expect(keys(Array(messages.dropFirst())) == [[0xFFEB, 1], [0x76, 1], [0x76, 0], [0xFFEB, 0]])
        // The same text on a Linux screen is typed.
        #expect(ScreenKeys.paste("héllo", mac: false) == .typed("héllo"))
        // Anything beyond Latin-1 is typed, on a Mac too.
        #expect(ScreenKeys.paste("price €5", mac: true) == .typed("price €5"))
        #expect(ScreenKeys.paste("😀", mac: true) == .typed("😀"))
    }

    @Test func aClipboardOverTheCapIsTyped() {
        let atCap = String(repeating: "a", count: ScreenKeys.maxCutText)
        guard case .clipboard(let messages) = ScreenKeys.paste(atCap, mac: true) else {
            Issue.record("262,144 bytes fit a ClientCutText")
            return
        }
        #expect(messages.first?.count == 8 + ScreenKeys.maxCutText)
        #expect(ScreenKeys.paste(atCap + "a", mac: true) == .typed(atCap + "a"))
        #expect(ScreenKeys.latin1(atCap + "a") == nil)
        #expect(ScreenKeys.latin1("ÿ") == [0xFF])
        #expect(ScreenKeys.latin1("Ā") == nil)
    }

    @Test func nothingIsSentWhileAnInputMethodIsComposing() {
        #expect(ScreenKeys.committed("ni", composing: true) == nil)
        #expect(ScreenKeys.committed("你", composing: false) == "你")
        #expect(ScreenKeys.committed("", composing: false) == nil)
        #expect(ScreenKeys.committed(nil, composing: false) == nil)
    }

    @Test func longTextGoesOutInSlicesAndCanBeCancelled() {
        var typer = ScreenTyper()
        #expect(typer.isEmpty && typer.next().isEmpty)
        typer.add(String(repeating: "x", count: 1_200), mods: [])
        #expect(typer.count == 1_200)
        #expect(typer.next().count == 1_000)            // 500 characters, a press and a release each
        #expect(typer.count == 700)
        #expect(typer.next().count == 1_000)
        typer.cancel()
        #expect(typer.isEmpty && typer.next().isEmpty)
        typer.add("ab", mods: [.shift])
        #expect(keys(typer.next()) == [[0xFFE1, 1], [0x61, 1], [0x61, 0], [0xFFE1, 0], [0xFFE1, 1], [0x62, 1], [0x62, 0], [0xFFE1, 0]])
        #expect(typer.isEmpty)
    }

    @Test func aHundredThousandCharactersTakeTwoHundredTurns() {
        var typer = ScreenTyper()
        typer.add(String(repeating: "é", count: 100_000), mods: [])
        var turns = 0, messages = 0
        while !typer.isEmpty {
            messages += typer.next().count
            turns += 1
        }
        #expect(turns == 200 && messages == 200_000)
    }
}
