// [attachments] How a reply names a file it hands over (docs/spec/1x-attachments.md §7.5): `MEDIA:` tags, ported from
// the web's `renderMediaTags` (`V:lib/chat-messages/parts.ts:13-187`: quoted values, unquoted paths with spaces up to a
// known extension, Windows paths, relative paths, sentence punctuation left outside), and, beyond the web, a bare
// picture path in the prose. Hermes tells an agent on the terminal surfaces to "state its absolute path in plain text"
// (`H:agent/prompt_builder.py` PLATFORM_HINTS["tui"]), and chats HQ started before it sent `source: "desktop"` ran as that surface, so
// their pictures arrive as paths (tester ivy, 2026-10-26). Pure; one line at a time, fenced code already left out.

import Foundation

nonisolated enum MediaTags {
    /// `V:lib/chat-messages/parts.ts:19-77` (Hermes' `MEDIA_DELIVERY_EXTS`).
    static let deliveryExts = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "svg", "mp4", "mov", "avi", "mkv",
                               "webm", "3gp", "mp3", "m2a", "wav", "ogg", "opus", "m4a", "flac", "pdf", "docx", "doc",
                               "odt", "rtf", "txt", "md", "epub", "xlsx", "xls", "ods", "csv", "tsv", "json", "xml",
                               "yaml", "yml", "kmz", "kml", "geojson", "gpx", "pptx", "ppt", "odp", "key", "zip",
                               "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "apk", "ipa", "html", "htm"]
    /// Picture extensions a bare path must end in (the kind table's images, spec §7.5).
    static let imageExts = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "heif", "tif", "tiff"]

    // swiftlint:disable force_try
    private static let tag: NSRegularExpression = {
        let alternation = deliveryExts.sorted { $0.count > $1.count }.joined(separator: "|")
        let anchored = #"(?:~/|/|[A-Za-z]:[/\\])\S+?(?:[^\S\n]+\S+?)*?\.(?:"# + alternation + #")(?=[\s`"'*_,;:)\]}]|MEDIA:|$)"#
        let bare = #"[^\s`"]+"#
        return try! NSRegularExpression(pattern: #"[`"']?MEDIA:\s*(`[^`\n]+`|"[^"\n]+"|'[^'\n]+'|"# + anchored + "|" + bare + #")[`"']?"#,
                                        options: [.caseInsensitive])
    }()
    /// An absolute picture path in prose: `/…`, `~/…` or `C:\…`, no spaces, not part of a URL or a link target.
    private static let barePath: NSRegularExpression = {
        let ext = imageExts.sorted { $0.count > $1.count }.joined(separator: "|")
        let path = #"(?:~/|/(?!/)|[A-Za-z]:\\)[^\s`"'<>()\[\]|]*\.(?:"# + ext + ")"
        return try! NSRegularExpression(pattern: #"(?<![\w/\\:(\[<.~-])"# + path + #"(?=$|[\s"'*_,;:.!?)\]}])"#, options: [.caseInsensitive])
    }()
    private static let quotedPath: NSRegularExpression = {
        let ext = imageExts.sorted { $0.count > $1.count }.joined(separator: "|")
        return try! NSRegularExpression(pattern: #"^(?:~/|/(?!/)|[A-Za-z]:\\)[^`\n]*\.(?:"# + ext + ")$", options: [.caseInsensitive])
    }()
    private static let codeSpan = try! NSRegularExpression(pattern: "(`+)([^`\\n]+?)\\1")
    private static let blockLead = try! NSRegularExpression(pattern: #"^\s*(?:[-*+]\s|\d+[.)]\s|>|\||#)"#)
    private static let listLead = try! NSRegularExpression(pattern: #"^\s*(?:[-*+]|\d+[.)])\s+"#)
    /// `::preview{file="…"}` alone on a line: the desktop app's inline page (`H:agent/prompt_builder.py` "desktop" hint,
    /// `V:components/assistant-ui/inline-preview-directive.tsx`). Attributes in any order, quoted either way.
    private static let previewDirective = try! NSRegularExpression(pattern: #"^\s*::preview\{([^}\n]*)\}\s*$"#)
    private static let previewFile = try! NSRegularExpression(pattern: #"(?:^|\s)(?:file|src|path)\s*=\s*(?:"([^"\n]+)"|'([^'\n]+)'|(\S+))"#)
    // swiftlint:enable force_try

    /// The markdown link a delivered file becomes: `[Image: chart.png](#media:<percent-encoded>)`.
    static func link(_ path: String) -> String {
        let name = displayName(path)
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? path
        return "[\(kindWord(path)): \(name)](#media:\(encoded))"
    }

    static func displayName(_ path: String) -> String {
        if path.lowercased().hasPrefix("https://"), let url = URL(string: path), !url.lastPathComponent.isEmpty, url.lastPathComponent != "/" {
            return url.lastPathComponent
        }
        let parts = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        return parts.last.map(String.init) ?? path
    }

    static func kindWord(_ path: String) -> String {
        switch MediaKinds.refKind(ofName: path) {
        case .image: return "Image"
        case .video: return "Video"
        case .audio: return "Audio"
        case .file: return "File"
        }
    }

    /// `isPlausibleMediaPath`: a separator, or a dot with something after it. A bare word stays prose.
    static func isPlausible(_ value: String) -> Bool {
        value.contains("/") || value.contains("\\") || value.range(of: #"\.[^.]"#, options: .regularExpression) != nil
    }

    /// One `MEDIA:` capture → its path and the sentence punctuation that trailed it (`mediaLink`, parts.ts:160-174).
    static func value(_ capture: String) -> (path: String, trailing: String)? {
        let raw = capture.trimmingCharacters(in: .whitespaces)
        if let q = raw.first, raw.count >= 2, q == raw.last, "\"'`".contains(q) {
            let inner = String(raw.dropFirst().dropLast())
            return isPlausible(inner) ? (inner, "") : nil
        }
        var path = raw
        if let last = path.last, last == "`" || last == "\"" { path.removeLast() }
        var trailing = ""
        while let last = path.last, ".,;:!?".contains(last), isPlausible(String(path.dropLast())) {
            trailing = String(last) + trailing
            path.removeLast()
        }
        return isPlausible(path) ? (path, trailing) : nil
    }

    /// A line with its `MEDIA:` tags as links; `mediaOnly` when nothing but those links (and blanks) is left.
    static func renderTags(_ line: String) -> (text: String, mediaOnly: Bool) {
        // The desktop app draws the page live in the reply; here it's the file's card, opened like any other file.
        if let page = previewPath(line) { return (link(page), true) }
        guard line.range(of: "MEDIA:", options: .caseInsensitive) != nil else { return (line, false) }
        let ns = line as NSString
        var out = "", rest = "", cursor = 0, links = 0
        for m in tag.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            let before = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            out += before
            rest += before
            let whole = ns.substring(with: m.range)
            if let v = value(ns.substring(with: m.range(at: 1))) {
                out += link(v.path) + v.trailing
                rest += v.trailing
                links += 1
            } else {
                out += whole
                rest += whole
            }
            cursor = m.range.location + m.range.length
        }
        let tail = ns.substring(from: cursor)
        out += tail
        rest += tail
        return (out, links > 0 && rest.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// The file a `::preview{file="…"}` line names, or nil when the line is anything else.
    static func previewPath(_ line: String) -> String? {
        guard line.contains("::preview{") else { return nil }
        let ns = line as NSString
        guard let m = previewDirective.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let attrs = ns.substring(with: m.range(at: 1))
        let ans = attrs as NSString
        guard let f = previewFile.firstMatch(in: attrs, range: NSRange(location: 0, length: ans.length)) else { return nil }
        for i in 1...3 where f.range(at: i).location != NSNotFound {
            let path = ans.substring(with: f.range(at: i)).trimmingCharacters(in: .whitespaces)
            return isPlausible(path) ? path : nil
        }
        return nil
    }

    /// Bare picture paths in a prose line. A line that is only a path (or a path in backticks), or a list item that
    /// is only one, is a picture (`mediaOnly`). A path inside a sentence becomes a tappable name and its picture
    /// follows on its own: `images`. On a list item, quote, table row or heading (`inBlock`) a following line would
    /// break the block, so the caller holds those pictures until the block ends. Code spans holding anything more than
    /// one path stay code.
    static func renderBarePaths(_ line: String) -> (text: String, mediaOnly: Bool, images: [String], inBlock: Bool) {
        guard line.contains("/") || line.contains("\\"), line.range(of: #"\.(?:png|jpe?g|gif|webp|bmp|heic|heif|tiff?)"#,
                                                                     options: [.regularExpression, .caseInsensitive]) != nil else {
            return (line, false, [], false)
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let only = alone(trimmed) { return (link(only), true, [], false) }
        // "- /…/01-roster.png" or "  - `…/01-roster.png`": a list of screenshots (owner, Mac, 2026-10-30).
        let tns = trimmed as NSString
        if let lead = listLead.firstMatch(in: trimmed, range: NSRange(location: 0, length: tns.length)),
           let only = alone(tns.substring(from: lead.range.length).trimmingCharacters(in: .whitespaces)) {
            return (link(only), true, [], false)
        }
        let ns = line as NSString
        var out = "", cursor = 0
        var found: [String] = []
        func prose(_ text: String) -> String {
            let pns = text as NSString
            var piece = "", c = 0
            for m in barePath.matches(in: text, range: NSRange(location: 0, length: pns.length)) {
                piece += pns.substring(with: NSRange(location: c, length: m.range.location - c))
                let path = pns.substring(with: m.range)
                piece += "[\(displayName(path))](#media:\(path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? path))"
                found.append(path)
                c = m.range.location + m.range.length
            }
            return piece + pns.substring(from: c)
        }
        for m in codeSpan.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            out += prose(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)))
            let inner = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
            if quoted(inner) {
                out += "[\(displayName(inner))](#media:\(inner.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? inner))"
                found.append(inner)
            } else {
                out += ns.substring(with: m.range)
            }
            cursor = m.range.location + m.range.length
        }
        out += prose(ns.substring(from: cursor))
        guard !found.isEmpty else { return (line, false, [], false) }
        let block = blockLead.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil
        var seen = Set<String>()
        return (out, false, found.filter { seen.insert($0).inserted }, block)
    }

    /// A reply's words for VoiceOver: each delivered file by its name ("Image: chart.png"), never its path. The
    /// result is still markdown (`SpokenMarkdown.plain` reads the links as their words).
    static func forSpeech(_ text: String) -> String {
        guard text.contains("/") || text.contains("\\") else { return text }
        return text.components(separatedBy: "\n").map { line -> String in
            let tags = renderTags(line)
            if tags.mediaOnly { return tags.text }
            let bare = renderBarePaths(tags.text)
            return bare.mediaOnly || bare.inBlock ? bare.text : bare.text + bare.images.map { " " + link($0) }.joined()
        }.joined(separator: "\n")
    }

    /// The path a line holds and nothing else (bare, or in one code span).
    private static func alone(_ trimmed: String) -> String? {
        var inner = trimmed
        if inner.hasPrefix("`") && inner.hasSuffix("`") && inner.count > 2 {
            inner = inner.trimmingCharacters(in: CharacterSet(charactersIn: "`")).trimmingCharacters(in: .whitespaces)
            return quoted(inner) ? inner : nil
        }
        while let last = inner.last, ".,;:!".contains(last) { inner.removeLast() }
        let ns = inner as NSString
        guard let m = barePath.firstMatch(in: inner, range: NSRange(location: 0, length: ns.length)),
              m.range.location == 0, m.range.length == ns.length else { return nil }
        return inner
    }

    /// A code span's words are one picture path (spaces allowed inside the backticks).
    private static func quoted(_ inner: String) -> Bool {
        quotedPath.firstMatch(in: inner, range: NSRange(location: 0, length: (inner as NSString).length)) != nil
    }
}
