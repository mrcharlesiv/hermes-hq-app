// The hold menu of the folded rows (a delivery from another bot, a finished subagent or background task, a tool row):
// what each item takes. Folded since build 328, their words could only be copied by opening the row and selecting by
// hand (UX study 2026-10-19; collapsed-deliveries note). Pure, unit tested in Tests/Chat.

import Foundation

nonisolated enum RowHoldMenu {
    /// What Copy, Read Aloud and Share take from a folded result row: a delivery's whole message (its row title is
    /// only "<bot>: <first words>"), else the title over what the work reported.
    static func resultText(title: String, result: String, delivery: Bool) -> String {
        let body = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if delivery { return body }
        let head = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty { return head }
        return head.isEmpty ? body : head + "\n\n" + body
    }

    /// A tool row's Copy Command and Copy Output (nil: not offered): the command a shell or code step ran, and what
    /// it printed (else its result, else its error).
    static func copies(_ detail: ToolDetail?) -> (command: String?, output: String?) {
        func text(_ value: String?) -> String? {
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value
        }
        let output = text(detail?.stdout) ?? text(detail?.detail) ?? text(detail?.errorText) ?? text(detail?.stderr)
        return (text(detail?.command), output)
    }
}
