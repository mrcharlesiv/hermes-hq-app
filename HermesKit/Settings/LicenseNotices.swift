// The notices of what ships inside the app (docs/spec/3x-morepages.md §7): `App/Resources/Licenses/licenses.json`,
// written by scripts/licenses.py from Package.resolved and extra.json. Hermes first, then by name.

import Foundation

nonisolated struct LicenseNotice: Codable, Sendable, Hashable, Identifiable {
    var name: String
    var version: String
    var license: String
    var text: String
    var id: String { name }

    /// "0.9.0 · Apache-2.0"; no leading dot when there is no version (`noticeMeta`, `S/licenses-sheet.tsx:19-20`).
    var meta: String { [version, license].filter { !$0.isEmpty }.joined(separator: " · ") }
}

nonisolated enum LicenseNotices {
    static let intro = "This app is built on Hermes Agent by Nous Research and the open-source software below. \(DeviceWord.Tap) one to read its license."
    static let failure = "The licenses couldn’t load."
    static let first = "Hermes Agent (Nous Research)"

    /// Decodes leniently: an entry without a name or text is skipped; Hermes is put first, the rest by name.
    static func decode(_ data: Data) -> [LicenseNotice]? {
        guard let items = (try? JSONValue.parse(data))?.array else { return nil }
        var seen = Set<String>()
        let notices = items.compactMap { item -> LicenseNotice? in
            guard let name = item["name"]?.string, !name.isEmpty, let text = item["text"]?.string,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, seen.insert(name).inserted else { return nil }
            return LicenseNotice(name: name, version: item["version"]?.string ?? "", license: item["license"]?.string ?? "", text: text)
        }
        guard !notices.isEmpty else { return nil }
        return notices.sorted { a, b in
            if (a.name == first) != (b.name == first) { return a.name == first }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Read off the main thread when the page opens.
    @concurrent
    static func load(bundle: Bundle = .main) async -> [LicenseNotice]? {
        guard let url = bundle.url(forResource: "licenses", withExtension: "json"), let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    /// The licence files are hard-wrapped at 80 columns; on a phone that leaves ragged half-lines. Each paragraph is
    /// joined back into one line (blank lines still separate paragraphs) and the system wraps it.
    static func reflow(_ text: String) -> String {
        var paragraphs: [String] = []
        var current: [String] = []
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if !current.isEmpty { paragraphs.append(current.joined(separator: " ")); current = [] }
            } else {
                current.append(trimmed)
            }
        }
        if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
        return paragraphs.joined(separator: "\n\n")
    }
}
