// Links inside a Markdown note (docs/spec/3x-morepages.md §3): what a link is (`V/lib/preview-markdown-links.ts`), the
// path of a note linked from another note (`S/fe-pages-r5.ts:27-35` `linkedNotePath`, ported with its tests), and the
// heading a `#fragment` names (`previewHeadingSlug`). Pure.

import Foundation

nonisolated enum ArtifactLinks {
    enum Kind: Equatable, Sendable {
        /// A web link: the system opens it. Only http(s) ever leaves the app.
        case external(URL)
        /// Another file: its target as written (percent-decoded), and the `#fragment` after it, if any.
        case file(String, fragment: String?)
        /// A heading in the note on screen.
        case hash(String)
        case inert
    }

    static func classify(href: String) -> Kind {
        let raw = href.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return .inert }
        if raw.hasPrefix("#") {
            let fragment = decoded(String(raw.dropFirst()))
            return fragment.isEmpty ? .inert : .hash(fragment)
        }
        if raw.hasPrefix("//") { return web("https:" + raw) }
        if raw.lowercased().hasPrefix("www.") { return web("https://" + raw) }
        let isDrive = RX.c(#"^[A-Za-z]:[\\/]"#).test(raw)
        if let scheme = RX.c(#"^([A-Za-z][A-Za-z0-9+.-]*):"#).exec(raw)?[1]?.lowercased(), !isDrive {
            switch scheme {
            case "http", "https": return web(raw)
            case "file": break
            default: return .inert   // javascript:, data:, mailto:, custom schemes: never followed from a note
            }
        }
        var target = raw
        var fragment: String?
        if let hash = target.firstIndex(of: "#") {
            let tail = decoded(String(target[target.index(after: hash)...]))
            fragment = tail.isEmpty ? nil : tail
            target = String(target[..<hash])
        }
        target = decoded(target)
        if target.isEmpty || target.contains("\0") { return .inert }
        return .file(target, fragment: fragment)
    }

    private static func web(_ text: String) -> Kind {
        guard let url = URL(string: text), let host = url.host(), !host.isEmpty else { return .inert }
        return .external(url)
    }

    private static func decoded(_ text: String) -> String { text.removingPercentEncoding ?? text }

    /// The path of a note a link in the note at `from` points to: a relative link is in that note's folder, an absolute
    /// (or "~/") path is itself. A relative note stays relative, so its session's folder resolves it on the gateway.
    static func linkedNotePath(from: String, target: String) -> String {
        var link = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if link.lowercased().hasPrefix("file://") { link = String(link.dropFirst(7)) }
        if link.hasPrefix("/") || link == "~" || link.hasPrefix("~/") { return collapse(link) }
        let base = from.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = base.lastIndex(of: "/").map { String(base[...$0]) } ?? ""
        return collapse(folder + link)
    }

    private static func collapse(_ path: String) -> String {
        let absolute = path.hasPrefix("/")
        var out: [String] = []
        for segment in path.split(separator: "/", omittingEmptySubsequences: false).map(String.init) {
            if segment.isEmpty || segment == "." { continue }
            if segment == ".." {
                if let last = out.last, last != "..", last != "~" { out.removeLast() } else if !absolute { out.append("..") }
                continue
            }
            out.append(segment)
        }
        return (absolute ? "/" : "") + out.joined(separator: "/")
    }

    /// The last path component, for a page title ("notes/plan.md" → "plan.md").
    static func name(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? path
    }

    /// Back reads the previous note's name, or plain "Back" when that name is longer than 12 characters
    /// (`S/artifact-text-sheet.tsx:137`).
    static func backUsesName(_ name: String) -> Bool { name.count <= 12 }

    /// NFC, trimmed, lower-cased; everything but letters, digits, marks, "-", "_" and spaces dropped; spaces → "-".
    static func headingSlug(_ text: String) -> String {
        let folded = text.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var kept = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars {
            let p = scalar.properties
            let letter = p.isAlphabetic || p.generalCategory == .decimalNumber || p.generalCategory == .letterNumber
                || p.generalCategory == .otherNumber || p.generalCategory == .nonspacingMark || p.generalCategory == .spacingMark
                || p.generalCategory == .enclosingMark
            if letter || scalar == "-" || scalar == "_" || scalar == " " { kept.append(scalar) }
        }
        var slug = String(kept)
        slug = RX.c(" +").replace(slug, with: "-")
        slug = RX.c("-+").replace(slug, with: "-")
        return slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// The note's headings with their ids, duplicates numbered `slug`, `slug-1`, … (`rehypePreviewHeadingIds`). ATX
    /// headings only; lines inside a fenced code block are not headings.
    static func headings(in markdown: String) -> [(id: String, text: String)] {
        var out: [(String, String)] = []
        var counts: [String: Int] = [:]
        var fence: String?
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if trimmed.hasPrefix(open) { fence = nil }
                continue
            }
            if trimmed.hasPrefix("```") { fence = "```"; continue }
            if trimmed.hasPrefix("~~~") { fence = "~~~"; continue }
            guard let match = RX.c(#"^ {0,3}#{1,6}\s+(.*?)\s*#*\s*$"#).exec(line), let text = match[1], !text.isEmpty else { continue }
            // The words as they are drawn: inline marks dropped.
            let plain = RX.c(#"[*_`]|\[([^\]]*)\]\([^)]*\)"#).replace(text, with: "$1")
            let base = headingSlug(plain)
            guard !base.isEmpty else { continue }
            let seen = counts[base] ?? 0
            counts[base] = seen + 1
            out.append((seen == 0 ? base : "\(base)-\(seen)", plain))
        }
        return out
    }

    /// The scheme the viewer puts on a note link so UIKit hands the tap back (never opened by the system).
    static let scheme = "hq-note"

    static func viewerURL(destination: String) -> URL? {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = "link"
        parts.queryItems = [URLQueryItem(name: "d", value: destination)]
        return parts.url
    }

    static func destination(of url: URL) -> String? {
        guard url.scheme == scheme else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "d" }?.value
    }
}
