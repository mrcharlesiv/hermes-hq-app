// Where an older build's saved voice note really is (docs/spec/3x-intents.md §8.1; the rule of build 240's
// `PickedFiles.resolvedFile`, W:ios/App/App/PickedFiles.swift:36-65). The stored path was written by builds 26–28 and
// iOS may have moved the app's container since: only what follows the app's own `HermesAttachments` folder is trusted,
// and it is looked for under this install's folders. Anything that is not a file of ours answers nil: it is never
// read and never deleted.

import Foundation

nonisolated enum LegacyNoteFile {
    static let folder = "HermesAttachments"
    static let markers = ["/Library/Application Support/" + folder + "/", "/Library/Caches/" + folder + "/"]
    static let maxBytes = 32 * 1024 * 1024

    /// This install's two folders: Application Support's, then Caches'.
    static var roots: [URL] {
        let files = FileManager.default
        let support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let caches = files.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return [support.appending(path: folder, directoryHint: .isDirectory), caches.appending(path: folder, directoryHint: .isDirectory)]
    }

    static func resolve(_ path: String, roots: [URL] = LegacyNoteFile.roots) -> URL? {
        guard path.hasPrefix("/"), path.utf8.count <= 4096, !path.contains("\0"),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains("..") else { return nil }
        for (index, marker) in markers.enumerated() {
            guard let range = path.range(of: marker, options: .backwards) else { continue }
            let rest = String(path[range.upperBound...])
            guard !rest.isEmpty, !rest.hasPrefix("/"), !rest.hasSuffix("/") else { continue }
            // The folder of the same kind first, then the other.
            let order = index < roots.count ? [roots[index]] + roots.enumerated().filter { $0.offset != index }.map(\.element) : roots
            for root in order {
                if let file = owned(root.appending(path: rest, directoryHint: .notDirectory), roots: roots) { return file }
            }
        }
        return nil
    }

    /// Deletes a recording `resolve` answered, and its folder (one per recording) when nothing else is in it. A file
    /// outside the app's own folders is left alone.
    static func remove(_ file: URL, roots: [URL] = LegacyNoteFile.roots) {
        let resolved = file.resolvingSymlinksInPath()
        guard roots.contains(where: { resolved.path.hasPrefix($0.resolvingSymlinksInPath().path + "/") }) else { return }
        let files = FileManager.default
        try? files.removeItem(at: resolved)
        let folder = resolved.deletingLastPathComponent()
        if UUID(uuidString: folder.lastPathComponent) != nil, (try? files.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
            try? files.removeItem(at: folder)
        }
    }

    /// `candidate` when, with every symlink followed, it is a file of 1 byte to 32 MiB inside one of `roots`.
    private static func owned(_ candidate: URL, roots: [URL]) -> URL? {
        let file = candidate.resolvingSymlinksInPath()
        guard roots.contains(where: { file.path.hasPrefix($0.resolvingSymlinksInPath().path + "/") }) else { return nil }
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true,
              let size = values.fileSize, size >= 1, size <= maxBytes else { return nil }
        return file
    }
}
