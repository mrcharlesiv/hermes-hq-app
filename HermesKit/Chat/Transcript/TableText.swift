// [transcript] A table as text for Numbers (docs/spec/3x-transcript.md §3.4, row L309). Ported from
// `S/ui-chat/table-model.ts`: tabs and line breaks inside cells become spaces; rows stay tab-separated.

import Foundation

nonisolated enum TableText {
    private static let breaks = TRx(#"[\t\r\n]+"#)

    static func cell(_ text: String) -> String {
        breaks.replace(text, with: " ").trimmingCharacters(in: .whitespaces)
    }

    static func text(_ rows: [[String]]) -> String {
        rows.map { $0.map(cell).joined(separator: "\t") }.joined(separator: "\n")
    }

    /// The copy failed wording (kept for parity; a pasteboard write does not fail in practice): shown when the table
    /// has nothing to copy.
    static let failure = "Couldn’t copy. Select the table text and try again."

    static func copyable(_ rows: [[String]]) -> String? {
        let out = text(rows)
        return out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : out
    }
}
