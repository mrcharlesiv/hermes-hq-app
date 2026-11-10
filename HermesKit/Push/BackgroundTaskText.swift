// [settings] The words of a finished background process's alert (docs/spec/3x-settings.md §15b; the web's
// `composer-status.ts`: first line of the command, " (exit N)" for any exit code, then the last lines of its output).

import Foundation

nonisolated enum BackgroundTaskText {
    static func failed(exitCode: Int?) -> Bool { (exitCode ?? 0) != 0 }

    static func line(command: String?, status: String?, exitCode: Int?, tail: String?) -> String {
        let first = (command ?? "").split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        var head = first.isEmpty ? "background process" : first
        if let exitCode { head += " (exit \(exitCode))" }
        let lines = (tail ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.suffix(3)
        let title = failed(exitCode: exitCode) ? "Background task failed" : "Background task finished"
        return String(([title + ": " + head] + lines).joined(separator: "\n").prefix(240))
    }
}
