// A meta line of pieces joined with " · " ("Connected · 6 Bots · Hermes 0.21.5") that breaks only between pieces and
// never ends a line on a dangling " · ": the fewest lines that fit, the first pieces sharing a line, the rest one each.

import SwiftUI

struct DotSeparatedText: View {
    var pieces: [String]

    /// The lines when the first `joined` pieces share one and the rest get one each.
    static func lines(_ pieces: [String], joined: Int) -> [String] {
        [pieces.prefix(joined).joined(separator: " · ")] + pieces.dropFirst(joined)
    }

    /// The first piece alone, the rest sharing the second line.
    static func twoLines(_ pieces: [String]) -> [String] {
        [pieces[0], pieces.dropFirst().joined(separator: " · ")]
    }

    var body: some View {
        // Each piece keeps its words together ("15 minutes ago" never as "15" / "minutes ago").
        let whole = pieces.map { $0.replacingOccurrences(of: " ", with: "\u{00A0}") }
        ViewThatFits(in: .horizontal) {
            ForEach(Array(stride(from: whole.count, through: 2, by: -1)), id: \.self) { joined in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(Self.lines(whole, joined: joined).enumerated()), id: \.offset) { Text($0.element).lineLimit(1) }
                }
            }
            // [mac] Stress test 2026-10-28 #12 (d57): at laptop width More's gateway card went to three lines (one
            // piece each); on the Mac the first piece alone and the rest sharing a line come first.
            if DeviceWord.isMac, whole.count >= 3 {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(Self.twoLines(whole).enumerated()), id: \.offset) { Text($0.element).lineLimit(1) }
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(Self.lines(whole, joined: 1).enumerated()), id: \.offset) { Text($0.element).lineLimit(1) }
            }
            VStack(alignment: .leading, spacing: 0) {    // a piece wider than the row wraps between its own words
                ForEach(Array(pieces.enumerated()), id: \.offset) { Text($0.element).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }
}
