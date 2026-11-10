// [transcript] Link titles and site icons: reading the markup (docs/spec/3x-transcript.md §3.7, rows L312, L313,
// L1007). Ported from `S/link-preview.ts` (titleFromHtml, iconCandidates, imageMime, decodeEntities) and
// `S/fe-convo-r3.ts` (bareLinkLabel). Only a site's own title and marks are used, never a third-party icon service.

import Foundation

nonisolated enum LinkPreviewParsing {
    static let titleMax = 240
    static let htmlLimit = 256 * 1024
    static let imageLimit = 64 * 1024

    private static let unusableTitle = TRx(#"\b(access denied|attention required|captcha|error|forbidden|just a moment|request blocked|too many requests|sign[ -]?in|log[ -]?in)\b"#, [.caseInsensitive])
    private static let signInArrival = TRx(#"^accounts\.google\.com$|/ServiceLogin\b|/signin\b|/login\b|/o/oauth2/"#, [.caseInsensitive])
    private static let entity = TRx(#"&(#x[0-9a-f]+|#\d+|[a-z]+);"#, [.caseInsensitive])
    private static let titleTag = TRx(#"<title[^>]*>([\s\S]*?)</title>"#, [.caseInsensitive])
    private static let metaTag = TRx(#"<meta\b[^>]*>"#, [.caseInsensitive])
    private static let linkTag = TRx(#"<link\b[^>]*>"#, [.caseInsensitive])
    private static let baseTag = TRx(#"<base\b[^>]*>"#, [.caseInsensitive])
    private static let anyTag = TRx(#"<[^>]*>"#)
    private static let spaces = TRx(#"\s+"#)
    private static let iconRel = TRx(#"\b(icon|apple-touch-icon|apple-touch-icon-precomposed|mask-icon|fluid-icon)\b"#)
    private static let titleKey = TRx(#"^(og:title|twitter:title)$"#, [.caseInsensitive])
    /// Characters that reorder or hide text (bidi overrides and isolates, zero-width marks): never in a title.
    private static let bidi = TRx("[\u{202A}-\u{202E}\u{2066}-\u{2069}\u{200B}-\u{200F}\u{FEFF}]")

    private static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ndash": "–", "mdash": "—", "hellip": "…",
        "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“", "middot": "·", "bull": "•",
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for match in entity.re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let whole = ns.substring(with: match.range)
            let name = ns.substring(with: match.range(at: 1))
            var replacement = whole
            if name.hasPrefix("#") {
                let digits = name.dropFirst()
                let code = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits, radix: 10)
                if let code, code > 0, code <= 0x10FFFF, let scalar = Unicode.Scalar(code) { replacement = String(Character(scalar)) }
            } else if let known = entities[name.lowercased()] {
                replacement = known
            }
            out += replacement
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    static func attribute(_ tag: String, _ name: String) -> String {
        let pattern = TRx("\\b\(NSRegularExpression.escapedPattern(for: name))\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s\"'>]+))", [.caseInsensitive])
        guard let groups = pattern.groups(tag) else { return "" }
        return groups.dropFirst(2).compactMap { $0 }.first { !$0.isEmpty } ?? ""
    }

    /// The page's own title, or its Open Graph title when <title> is empty. "" for error and sign-in pages.
    static func titleFromHTML(_ html: String) -> String {
        let head = String(html.prefix(htmlLimit))
        var title = titleTag.groups(head)?[1] ?? ""
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            for tag in metaTag.allMatches(head) {
                let key = attribute(tag, "property").isEmpty ? attribute(tag, "name") : attribute(tag, "property")
                if titleKey.test(key) { title = attribute(tag, "content"); break }
            }
        }
        var clean = decodeEntities(anyTag.replace(title, with: ""))
        clean = bidi.replace(clean, with: "")
        clean = spaces.replace(clean, with: " ").trimmingCharacters(in: .whitespaces)
        clean = String(clean.prefix(titleMax))
        return !clean.isEmpty && !unusableTitle.test(clean) ? clean : ""
    }

    /// The final URL is a sign-in page: its title is not the document's.
    static func isSignInArrival(_ url: URL) -> Bool {
        signInArrival.test(url.host ?? "") || signInArrival.test(url.path)
    }

    private static func absolute(_ href: String, base: String) -> String {
        let clean = decodeEntities(href.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !clean.isEmpty, let baseURL = URL(string: base), let url = URL(string: clean, relativeTo: baseURL)?.absoluteURL,
              url.scheme?.lowercased() == "https" else { return "" }
        return url.absoluteString
    }

    /// Declared icons ranked (scalable, then larger), then the well-known paths; the top five, https only.
    static func iconCandidates(_ html: String, pageURL: String) -> [String] {
        let declaredBase = absolute(attribute(baseTag.allMatches(html).first ?? "", "href"), base: pageURL)
        let base = declaredBase.isEmpty ? pageURL : declaredBase
        var scored: [(url: String, score: Int)] = []
        for tag in linkTag.allMatches(html) {
            let rel = attribute(tag, "rel").lowercased()
            guard iconRel.test(rel) else { continue }
            let url = absolute(attribute(tag, "href"), base: base)
            guard !url.isEmpty else { continue }
            let type = attribute(tag, "type").lowercased(), sizes = attribute(tag, "sizes").lowercased()
            let declared = sizes.split(whereSeparator: \.isWhitespace).map { token -> Int in
                token == "any" ? 512 : (Int(token.split(separator: "x").first ?? "") ?? 0)
            }.max() ?? 0
            let score = type.contains("svg") || rel.contains("mask-icon") ? 1024
                : declared > 0 ? min(declared, 512) : rel.contains("apple-touch-icon") ? 180 : 96
            scored.append((url, score))
        }
        if let page = URL(string: pageURL), let host = page.host, page.scheme?.lowercased() == "https" {
            let origin = "https://\(host)\(page.port.map { ":\($0)" } ?? "")"
            scored.append(("\(origin)/apple-touch-icon.png", 50))
            scored.append(("\(origin)/favicon.ico", 48))
            scored.append(("\(origin)/favicon.png", 47))
        }
        var best: [String: Int] = [:]
        var order: [String] = []
        for (url, score) in scored {
            if best[url] == nil { order.append(url) }
            best[url] = max(best[url] ?? 0, score)
        }
        // Stable for equal scores (first declared first), as the web's sort is.
        return order.enumerated().sorted { a, b in
            let (sa, sb) = (best[a.element] ?? 0, best[b.element] ?? 0)
            return sa != sb ? sa > sb : a.offset < b.offset
        }.map(\.element).prefix(5).map { $0 }
    }

    /// Magic bytes decide, never the server's header. "" for anything that is not a picture (or is under 48 bytes).
    static func imageMime(_ bytes: Data, declared: String = "") -> String {
        guard bytes.count >= 48 else { return "" }
        let b = [UInt8](bytes.prefix(16))
        func at(_ offset: Int, _ signature: [UInt8]) -> Bool { Array(b[offset..<min(b.count, offset + signature.count)]) == signature }
        if at(0, [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if at(0, [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if at(0, [0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
        if at(0, [0x00, 0x00, 0x01, 0x00]) { return "image/x-icon" }
        if at(0, [0x52, 0x49, 0x46, 0x46]) && at(8, [0x57, 0x45, 0x42, 0x50]) { return "image/webp" }
        let head = String(decoding: bytes.prefix(1024), as: UTF8.self).lowercased()
        return head.contains("<svg") || (declared.lowercased().contains("svg") && head.contains("<")) ? "image/svg+xml" : ""
    }

    /// The page's text: the header's charset, then `<meta charset>`, then UTF-8, then Latin-1.
    static func decode(_ data: Data, contentType: String) -> String {
        let charsetRE = TRx(#"charset=([\w-]+)"#, [.caseInsensitive])
        let metaRE = TRx(#"<meta[^>]+charset=["']?([\w-]+)"#, [.caseInsensitive])
        let sniff = String(decoding: data.prefix(2048), as: UTF8.self)
        let declared = charsetRE.groups(contentType)?[1] ?? metaRE.groups(sniff)?[1] ?? "utf-8"
        let cf = CFStringConvertIANACharSetNameToEncoding(declared as CFString)
        if cf != kCFStringEncodingInvalidId,
           let text = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))) {
            return text
        }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    /// A bare URL's text: its host (without "www.", with a port that isn't the default) and path, "…" standing for a
    /// query or fragment it leaves out; or the page's title with that host once the title is known.
    static func bareLinkLabel(title: String?, target: String) -> String {
        let fetched = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let components = URLComponents(string: target), let hostname = components.host, !hostname.isEmpty else {
            return fetched.isEmpty ? target : fetched
        }
        func bare(_ host: String) -> String { host.lowercased().hasPrefix("www.") ? String(host.dropFirst(4)) : host }
        let host = bare(hostname) + (components.port.map { ":\($0)" } ?? "")
        if !fetched.isEmpty {
            return fetched.lowercased().contains(bare(hostname).lowercased()) ? fetched : "\(fetched) · \(host)"
        }
        var path = components.percentEncodedPath
        if path == "/" { path = "" }
        if path.hasSuffix("/") { path.removeLast() }
        let more = (components.percentEncodedQuery?.isEmpty == false) || (components.fragment?.isEmpty == false)
            || target.contains("?") || target.contains("#")
        return "\(host)\(path)\(more ? "…" : "")"
    }

    /// The host a chip names: without "www.".
    static func displayHost(_ url: URL) -> String {
        let host = url.host ?? ""
        return host.lowercased().hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
