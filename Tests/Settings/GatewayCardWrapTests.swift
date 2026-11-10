import Testing
@testable import HermesHQNative

/// The gateway card on More and Settings: the address wraps between its parts and the status line never ends a line
/// on a dangling " · " (UI hunt 2026-10-15: "127.0.0.1:995" / "1" and "Connected · 6 Bots ·" at large text).
struct GatewayCardWrapTests {
    @Test func numberAddressBreaksOnlyAfterColonsAndSlashes() {
        // UX study 2026-10-19: "127.0.0." / "1:10067" at AX5 read as a different address.
        let wrapped = SettingsRootModel.wrappable("127.0.0.1:9951")
        #expect(wrapped == "127.0.0.1:\u{200B}9951")
        #expect(wrapped.replacingOccurrences(of: "\u{200B}", with: "") == "127.0.0.1:9951")
        #expect(SettingsRootModel.wrappable("http://10.0.0.2:8642/") == "http:\u{200B}/\u{200B}/\u{200B}10.0.0.2:\u{200B}8642/\u{200B}")
        #expect(SettingsRootModel.wrappable("studio") == "studio")
    }

    @Test func hostnamesKeepTheirDotBreaks() {
        #expect(SettingsRootModel.wrappable("mac.tail1234.ts.net:9951")
                == "mac.\u{200B}tail1234.\u{200B}ts.\u{200B}net:\u{200B}9951")
        // Word by word: a name beside a number address breaks each its own way.
        #expect(SettingsRootModel.wrappable("alex · 10.0.0.2:8642") == "alex · 10.0.0.2:\u{200B}8642")
    }

    @Test func statusLinesBreakOnlyBetweenPieces() {
        let pieces = ["Connected", "6\u{00A0}Bots", "Hermes\u{00A0}0.21.5"]
        #expect(DotSeparatedText.lines(pieces, joined: 3) == ["Connected · 6\u{00A0}Bots · Hermes\u{00A0}0.21.5"])
        #expect(DotSeparatedText.lines(pieces, joined: 2) == ["Connected · 6\u{00A0}Bots", "Hermes\u{00A0}0.21.5"])
        #expect(DotSeparatedText.lines(pieces, joined: 1) == ["Connected", "6\u{00A0}Bots", "Hermes\u{00A0}0.21.5"])
        for joined in 1...3 { #expect(!DotSeparatedText.lines(pieces, joined: joined).contains { $0.hasSuffix("·") }) }
    }
}
