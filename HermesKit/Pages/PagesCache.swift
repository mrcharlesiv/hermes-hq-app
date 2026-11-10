// The pages' disk caches (docs/spec/1x-pages.md §2.5): Application Support/pages/<account key>/ — `jobs-<scope>.json`,
// `kanban-boards.json`, `kanban-board-<slug>.json`, `artifacts-index.json`. Read synchronously for the first frame,
// written off the main thread on one serial queue, all removed on sign-out.

import Foundation

nonisolated enum PagesCache {
    /// One serial queue for every page cache write (and `flush()` for tests and backgrounding).
    static let writer = DispatchQueue(label: "hermeshq.pages-cache", qos: .utility)

    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appending(path: "pages", directoryHint: .isDirectory)
    }

    /// Previews downloaded for Quick Look (Caches: the system may purge them).
    static var previewRoot: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appending(path: "pages/preview", directoryHint: .isDirectory)
    }

    static func directory(for account: GatewayAccount, root: URL = root) -> URL {
        root.appending(path: RosterDisk.accountKey(account), directoryHint: .isDirectory)
    }

    /// A file-name-safe part ("all", a profile name, a board slug).
    static func safeName(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let cleaned = String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return cleaned.isEmpty ? "_" : String(cleaned.prefix(80))
    }

    static func read<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func write<T: Encodable & Sendable>(_ value: T, to url: URL) {
        writer.async {
            guard let data = try? JSONEncoder().encode(value) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: [.atomic])
        }
    }

    /// [offline] §6.10 (review): the same write with a size limit, measured where it is encoded (once, off the main
    /// thread). Over `maxBytes` nothing is saved and the older copy goes too, so a stale file never outlives a newer
    /// answer.
    static func write<T: Encodable & Sendable>(_ value: T, to url: URL, maxBytes: Int) {
        writer.async {
            guard let data = try? JSONEncoder().encode(value), data.count <= maxBytes else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: [.atomic])
        }
    }

    static func flush() { writer.sync {} }

    /// Sign-out: this account's page caches and previews go.
    static func purge(account: GatewayAccount) {
        let dir = directory(for: account), previews = directory(for: account, root: previewRoot)
        writer.async {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: previews)
        }
    }
}

/// A cached answer with the time it was read (ms since the epoch).
nonisolated struct PagesCached<T: Codable & Sendable>: Codable, Sendable {
    var at: Double
    var value: T
}
