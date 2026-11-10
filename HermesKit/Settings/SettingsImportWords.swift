// What Settings › Import says before and after it writes a settings file (UX study 2026-10-19 #65: the file was written
// at once, with only a quiet footer line after). Pure, so the count and the words are unit-tested without a screen.

import Foundation

nonisolated enum SettingsImportWords {
    static let confirmTitle = "Import Settings?"
    static let confirmAction = "Import"
    static let doneTitle = "Settings Imported"
    static let unchanged = "The file matches your settings; nothing changed."

    /// How many settings a patch from `ConfigPath.diff` changes: each leaf (a value that isn't an object) is one.
    static func changeCount(_ patch: JSONValue) -> Int {
        guard let object = patch.object else { return 1 }
        return object.values.reduce(0) { $0 + changeCount($1) }
    }

    /// "3 settings", "1 setting".
    static func settings(_ count: Int) -> String { count == 1 ? "1 setting" : "\(count) settings" }

    static func confirmMessage(changes: Int) -> String {
        "\(settings(changes)) on your gateway will change to the file’s values. Keys, tokens and passwords already there stay."
    }

    /// The footer line (and the HUD's detail) after the write.
    static func done(changes: Int) -> String {
        changes == 0 ? unchanged : "Settings imported. \(settings(changes)) changed."
    }
}
