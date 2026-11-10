// The chat's folder as ⋯ › More › Files and Changes show it (parity 240 §8; S:phone-chat-menu.tsx `openPane`,
// S:fe-convo-r5-ui.ts `openPhoneChanges`). On iOS the web reads everything over REST with the chat's profile:
//   Files    GET /api/fs/list?path=<dir>                     → {entries:[{name, path, isDirectory}], error?}
//            GET /api/fs/read-text?path=<file>               → {path, text, binary?, truncated?, byteSize?}
//   Changes  GET /api/git/review/list?path=<cwd>&scope=uncommitted → {files:[{path, added, removed, status, staged}]}
//            GET /api/git/review/diff?path=<cwd>&file=<f>&scope=uncommitted&staged=<bool> → {diff}
// (V:lib/desktop-fs.ts, V:lib/desktop-git.ts, V:store/review.ts:127-229.)

import Foundation

nonisolated struct WorkspaceEntry: Hashable, Sendable {
    var name: String
    var path: String
    var isDirectory: Bool
}

nonisolated struct WorkspaceFileText: Hashable, Sendable {
    var path: String
    var text: String
    var binary: Bool
    var truncated: Bool
    var byteSize: Int? = nil   // [morepages] the whole file's size, for "Showing the first 512 KB of 2.5 MB."
}

nonisolated struct WorkspaceChange: Hashable, Sendable {
    var path: String
    var added: Int
    var removed: Int
    /// "M", "A", "D", "R", "C", "U" or "?".
    var status: String
    var staged: Bool

    /// The status in words ("Changed", "Added", "New file", …): plain words, not git's (UX study #116).
    var statusName: String {
        switch status.uppercased() {
        case "A": return "Added"
        case "D": return "Deleted"
        case "R": return "Renamed"
        case "C": return "Copied"
        case "U": return "Conflict"
        case "?": return "New file"
        default: return "Changed"
        }
    }
}

nonisolated struct ChatWorkspace: Sendable {
    let client: any GatewayClient
    let profile: String?

    /// Paths the web leaves out of Changes (dependency, build and cache folders, OS noise).
    static let excludedChangeParts: Set<String> = ["node_modules", ".git", "dist", "build", ".next", ".cache", "__pycache__",
                                                    ".venv", "venv", ".DS_Store", "Pods", "DerivedData", ".turbo", "coverage"]

    private func query(_ items: [(String, String)]) -> [URLQueryItem] {
        items.map { URLQueryItem(name: $0.0, value: $0.1) } + (profile.map { [URLQueryItem(name: "profile", value: $0)] } ?? [])
    }

    private func read(_ path: String, _ items: [(String, String)]) async throws -> JSONValue {
        let data = try await client.rest("GET", path, query: query(items), body: nil)
        return try ChatJSON.parse(data)
    }

    /// A folder's entries, folders first, then by name.
    func list(_ directory: String) async throws -> [WorkspaceEntry] {
        let json = try await read("/api/fs/list", [("path", directory)])
        if let error = json["error"]?.nonEmptyString { throw MenusError(error) }
        let entries = (json["entries"]?.array ?? []).compactMap { e -> WorkspaceEntry? in
            guard let name = e["name"]?.nonEmptyString else { return nil }
            let path = e["path"]?.nonEmptyString ?? (directory as NSString).appendingPathComponent(name)
            return WorkspaceEntry(name: name, path: path, isDirectory: e["isDirectory"]?.bool ?? e["is_directory"]?.bool ?? false)
        }
        return Self.sorted(entries)
    }

    static func sorted(_ entries: [WorkspaceEntry]) -> [WorkspaceEntry] {
        entries.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    func readText(_ path: String) async throws -> WorkspaceFileText {
        let json = try await read("/api/fs/read-text", [("path", path)])
        return WorkspaceFileText(path: json["path"]?.nonEmptyString ?? path, text: json["text"]?.string ?? "",
                                 binary: json["binary"]?.bool ?? false, truncated: json["truncated"]?.bool ?? false,
                                 byteSize: json["byteSize"]?.int ?? json["byte_size"]?.int)   // [morepages]
    }

    /// Uncommitted changes in the chat's folder.
    func changes(in directory: String) async throws -> [WorkspaceChange] {
        let json = try await read("/api/git/review/list", [("path", directory), ("scope", "uncommitted")])
        if let error = json["error"]?.nonEmptyString { throw MenusError(error) }
        return (json["files"]?.array ?? []).compactMap { f -> WorkspaceChange? in
            guard let path = f["path"]?.nonEmptyString else { return nil }
            return WorkspaceChange(path: path, added: f["added"]?.int ?? 0, removed: f["removed"]?.int ?? 0,
                                   status: f["status"]?.string ?? "M", staged: f["staged"]?.bool ?? false)
        }.filter { !Self.excluded($0.path) }
    }

    static func excluded(_ path: String) -> Bool {
        path.split(separator: "/").contains { excludedChangeParts.contains(String($0)) }
    }

    func diff(in directory: String, file: WorkspaceChange) async throws -> String {
        let json = try await read("/api/git/review/diff", [("path", directory), ("file", file.path), ("scope", "uncommitted"),
                                                          ("staged", file.staged ? "true" : "false")])
        return json["diff"]?.string ?? ""
    }
}
