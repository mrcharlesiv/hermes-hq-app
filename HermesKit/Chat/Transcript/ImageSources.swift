// [transcript] Where a reply's Markdown image comes from (docs/spec/3x-transcript.md §3.8, row L317). Ported from
// `S/fe-convo-r6.ts` (relativeImageSrc, blockedImageText): a relative path is read from the chat's folder; an image
// that cannot be shown says why, in words.

import Foundation

nonisolated enum ImageSource: Equatable, Sendable {
    /// A public https picture.
    case remote(URL)
    /// A file on the gateway computer (absolute path).
    case gateway(String)
    case blocked(ImageBlock)
}

nonisolated enum ImageBlock: Equatable, Sendable {
    case relative, embedded, other, notSent
}

nonisolated enum ImageSources {
    private static let scheme = TRx(#"^[a-z][a-z\d+.-]*:"#, [.caseInsensitive])

    /// A relative image path against the chat's folder; nil for anything else (a URL, an absolute path, no folder).
    static func relative(_ src: String, base: String?) -> String? {
        let path = src.trimmingCharacters(in: .whitespacesAndNewlines)
        var folder = (base ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        while folder.hasSuffix("/") && folder.count > 1 { folder.removeLast() }
        guard !path.isEmpty, folder.hasPrefix("/"), !scheme.test(path), let first = path.first, !"/#~?".contains(first) else { return nil }
        var parts = folder.split(separator: "/").map(String.init)
        let bare = path.split(whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init) ?? ""
        for piece in bare.split(separator: "/", omittingEmptySubsequences: false).map(String.init) {
            if piece.isEmpty || piece == "." { continue }
            if piece == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(piece.removingPercentEncoding ?? piece)
        }
        return "/" + parts.joined(separator: "/")
    }

    static func fileName(_ src: String) -> String {
        let bare = src.split(whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init) ?? ""
        return bare.split(separator: "/").last.map(String.init) ?? ""
    }

    static func resolve(src: String, folder: String?) -> ImageSource {
        let path = src.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty { return .blocked(.other) }
        if path.lowercased().hasPrefix("data:") { return .blocked(.embedded) }
        if scheme.test(path) {
            guard let url = URL(string: path), PublicHostPolicy.publicHTTPS(url) else { return .blocked(.other) }
            return .remote(url)
        }
        if path.hasPrefix("/") { return .gateway(path) }
        if path.hasPrefix("#") || path.hasPrefix("~") || path.hasPrefix("?") { return .blocked(.other) }
        guard let resolved = relative(path, base: folder) else { return .blocked(.relative) }
        return .gateway(resolved)
    }

    /// The words drawn in a blocked image's place. `alt`: its alt text ("" = none).
    static func blockedText(alt: String, reason: ImageBlock) -> String {
        let trimmed = alt.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "this image" : "“\(trimmed)”"
        switch reason {
        case .relative: return "Couldn’t show \(name): its path is relative, and this chat has no folder to find it in."
        case .embedded: return "Couldn’t show \(name): an image embedded in a reply can’t be shown here."
        case .notSent: return "Couldn’t show \(name): your gateway didn’t send it."
        case .other: return "Couldn’t show \(name)."
        }
    }

    /// The name a blocked relative image goes by when it has no alt text: its file name (the web's `fileName(src)`).
    static func altOrFile(alt: String, src: String, reason: ImageBlock) -> String {
        let trimmed = alt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return reason == .relative ? fileName(src) : ""
    }
}
