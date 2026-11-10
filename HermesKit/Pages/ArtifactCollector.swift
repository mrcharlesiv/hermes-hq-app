// The Artifacts collector (docs/spec/1x-pages.md §5.4): files, images and links the bots produced, found in recent
// transcripts. A port of the vendored `app/artifacts/artifact-utils.ts` with the phone's gates (`src/artifact-collect.ts`
// wired by `build/fe-pages-gates.ts:24-25,326-329`), `lib/chat-messages/parts.ts` `mediaTagValues`, `lib/media.ts`
// path tests and `lib/external-link.tsx` link labels. Pure and thread-safe: the index runs it off the main thread.

import Foundation

nonisolated enum ArtifactCollector {
    static let pageSize = 100
    /// A transcript page over this many JSON characters fails its session (`artifact-utils.ts:31-32`).
    static let maxPageJSONChars = 32_000_000
    static let safeLoadMessage = "Session transcript page exceeds the Desktop safe-load limit; use the Web Dashboard export for this session."

    // MARK: Patterns (copied from the sources)

    private static let markdownImage = RX(#"!\[([^\]]*)\]\(([^)\s]+)\)"#)
    private static let markdownLink = RX(#"\[([^\]]+)\]\(([^)\s]+)\)"#)
    /// r1-94: a URL stops at markdown punctuation (`code`, **bold**, a link's "]").
    private static let urlRE = RX(#"https?://[^\s<>"'`)\]*\\]+"#)
    private static let pathRE = RX(#"(^|[\s("'`])((?:/|~[\\/]|\.\.?[\\/]|\\\\)[^\s"'`<>]+(?:\.[a-z0-9]{1,8})?)"#, .caseInsensitive)
    private static let windowsPathRE = RX(#"(^|[\s("'`])([A-Za-z]:[\\/][^\s"'`<>]+(?:\.[a-z0-9]{1,8})?)"#, .caseInsensitive)
    static let imageExt = RX(#"\.(?:png|jpe?g|gif|webp|svg|bmp)(?:\?.*)?$"#, .caseInsensitive)
    private static let fileExt = RX(#"\.(?:png|jpe?g|gif|webp|svg|bmp|pdf|txt|json|md|csv|xlsx?|docx?|pptx?|html|zip|tar|gz|avi|flac|m4a|mkv|mp3|ogg|opus|wav|webm|mp4|mov)(?:\?.*)?$"#, .caseInsensitive)
    private static let producerTool = RX(#"(?:^|_)(?:creat(?:e|ion)|download|export|generat(?:e|ion)|render|save|speech|tts|write)(?:_|$)"#, .caseInsensitive)
    private static let strongKey = RX(#"^(?:artifact_(?:file|image|path|url)|files?_(?:created|modified|written)|generated_(?:file|image|path|url)|media_tag|output_(?:file|path|url)|result_(?:file|path|url)|saved_to|screenshot_path)$"#, .caseInsensitive)
    private static let producerKey = RX(#"^(?:artifact(?:s|_(?:file|image|path|url))?|attachment(?:s|_(?:file|image|path|url))?|download(?:s|_(?:file|path|url))?|(?:audio|image|video)(?:_(?:file|path|url))?|file_path|local_path|media(?:_(?:file|path|url))?|path)$"#, .caseInsensitive)
    private static let shellOutputKey = RX(#"^(?:output|stdout|path)$"#, .caseInsensitive)
    private static let screenshotPath = RX(#"Screenshot path:\s*([^\r\n<>]+)"#, .caseInsensitive)
    private static let pipCacheDir = RX(#"/(?:\.cache/pip|library/caches/pip|appdata/local/pip/cache)/"#)
    private static let wheel = RX(#"\.whl(?:\.metadata)?$"#)
    private static let packageIndexDist = RX(#"/packages/.+\.(?:tar\.gz|tar\.bz2|zip|egg)(?:\.metadata)?$"#)
    private static let artifactFilePath = RX(#"^(?:file:|/|[~.][\\/]|\.\.[\\/]|[a-z]:[\\/]|\\\\)"#, .caseInsensitive)

    // `MEDIA:` tags (`parts.ts:19-206`).
    private static let mediaExts = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "svg", "mp4", "mov", "avi", "mkv",
                                    "webm", "3gp", "mp3", "m2a", "wav", "ogg", "opus", "m4a", "flac", "pdf", "docx", "doc",
                                    "odt", "rtf", "txt", "md", "epub", "xlsx", "xls", "ods", "csv", "tsv", "json", "xml",
                                    "yaml", "yml", "kmz", "kml", "geojson", "gpx", "pptx", "ppt", "odp", "key", "zip",
                                    "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "apk", "ipa", "html", "htm"]
    private static let mediaTag: RX = {
        let alternation = mediaExts.sorted { $0.count > $1.count }.joined(separator: "|")
        let anchored = #"(?:~/|/|[A-Za-z]:[/\\])\S+?(?:[^\S\n]+\S+?)*?\.(?:"# + alternation + #")(?=[\s`"'*_,;:)\]}]|MEDIA:|$)"#
        let bare = #"[^\s`"]+"#
        return RX(#"[`"']?MEDIA:\s*(`[^`\n]+`|"[^"\n]+"|'[^'\n]+'|"# + anchored + "|" + bare + #")[`"']?"#)
    }()

    // MARK: Small pieces

    static func isArtifactFilePath(_ value: String) -> Bool { artifactFilePath.test(value) }

    private static func isWindowsPath(_ value: String) -> Bool {
        RX.c(#"^[A-Za-z]:[\\/]"#).test(value) || value.hasPrefix("\\\\")
    }

    private static func looksLikePathOrURL(_ value: String) -> Bool {
        value.hasPrefix("http://") || value.hasPrefix("https://") || value.hasPrefix("data:image/") || isArtifactFilePath(value)
    }

    private static func pathForFiltering(_ value: String) -> String {
        if RX.c(#"^(?:https?|file)://"#, .caseInsensitive).test(value), let url = URL(string: value) {
            return (url.path(percentEncoded: false)).lowercased()
        }
        return value.replacingOccurrences(of: "\\", with: "/").lowercased()
    }

    private static func isPythonPackageDownload(_ value: String) -> Bool {
        let path = pathForFiltering(value)
        return pipCacheDir.test(path) || wheel.test(path)
            || (RX.c(#"^https?://"#, .caseInsensitive).test(value) && packageIndexDist.test(path))
    }

    static func looksLikeArtifact(_ value: String, explicit: Bool = false) -> Bool {
        if !explicit && isPythonPackageDownload(value) { return false }
        if value.hasPrefix("http://") || value.hasPrefix("https://") || value.hasPrefix("data:image/") { return true }
        if !looksLikePathOrURL(value) { return false }
        if explicit { return true }
        return imageExt.test(value) || fileExt.test(value)
    }

    /// Strip up to 3 layers of matching quotes, trailing `` ` ``/`*`, trailing `),.;`.
    static func normalizeValue(_ value: String) -> String {
        var trimmed = value.pgTrim
        for _ in 0..<3 {
            guard let quote = trimmed.first, trimmed.count >= 2, quote == trimmed.last, "\"'`".contains(quote) else { break }
            trimmed = String(trimmed.dropFirst().dropLast()).pgTrim
        }
        trimmed = RX.c(#"[`*]+$"#).replace(trimmed, with: "", all: false)
        return RX.c(#"[),.;]+$"#).replace(trimmed, with: "", all: false)
    }

    /// `#media:<encoded path>` → the path.
    static func mediaPathFromHref(_ href: String) -> String? {
        guard href.hasPrefix("#media:") else { return nil }
        return String(href.dropFirst("#media:".count)).removingPercentEncoding
    }

    private static func decodeMediaHref(_ value: String) -> String { mediaPathFromHref(value) ?? value }

    private static func unquoteMediaValue(_ value: String) -> String {
        let trimmed = value.pgTrim
        if let quote = trimmed.first, trimmed.count >= 2, quote == trimmed.last, "\"'`".contains(quote) {
            return String(trimmed.dropFirst().dropLast())
        }
        return RX.c(#"[`"'*_]{1,3}$"#).replace(trimmed, with: "", all: false)
    }

    private static func isPlausibleMediaPath(_ value: String) -> Bool {
        value.contains("/") || value.contains("\\") || RX.c(#"\.[^.]"#).test(value)
    }

    /// Raw `MEDIA:` values in `text`, quotes intact; bare captures shed trailing sentence punctuation.
    static func mediaTagValues(_ text: String) -> [String] {
        mediaTag.all(text).compactMap { match -> String? in
            let value = match[1] ?? ""
            // unquoteMediaPath
            var path = value.pgTrim
            if let q = path.first, path.count >= 2, q == path.last, "\"'`".contains(q) {
                path = String(path.dropFirst().dropLast())
            } else if let last = path.last, last == "`" || last == "\"" {
                path = String(path.dropLast())
            }
            // splitTrailingPunctuation
            var end = path.endIndex
            while end > path.startIndex, ".,;:!?".contains(path[path.index(before: end)]) {
                guard isPlausibleMediaPath(String(path[..<path.index(before: end)])) else { break }
                end = path.index(before: end)
            }
            let punctuation = path.distance(from: end, to: path.endIndex)
            guard isPlausibleMediaPath(String(path[..<end])) else { return nil }
            return punctuation > 0 ? String(value.dropLast(punctuation)) : value
        }
    }

    // MARK: Phone fixes (src/artifact-collect.ts)

    private static let pathWord = RX(#"^(?:[a-z][a-z0-9+.-]*://|/|~[\\/]|\.\.?[\\/]|data:)"#, .caseInsensitive)
    private static let hosted = RX(#"^//(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}(?::\d+)?/"#, .caseInsensitive)
    private static let windowsPath = RX(#"^(?:[A-Za-z]:[\\/]|\\\\)"#)

    /// One value per artifact: splits literal "\n"/"\r"/"\t" and real line breaks, and whitespace only when every word
    /// is a path or URL of its own.
    static func splitArtifactValue(_ value: String) -> [String] {
        let trimmed = value.pgTrim
        if trimmed.isEmpty { return [] }
        if RX.c(#"^data:"#, .caseInsensitive).test(trimmed) { return [trimmed] }
        let lines: [String]
        if windowsPath.test(trimmed) {
            lines = [trimmed]
        } else {
            lines = RX.c(#"\\[nrt]|[\r\n]+"#).replace(trimmed, with: "\u{0}").components(separatedBy: "\u{0}")
        }
        var out: [String] = []
        for line in lines {
            let text = line.pgTrim
            if text.isEmpty { continue }
            let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
            if words.count > 1 && words.allSatisfy({ pathWord.test($0) }) { out += words } else { out.append(text) }
        }
        return out
    }

    /// "//host.tld/…" is a web URL without its scheme.
    static func hostedArtifactURL(_ value: String) -> String { hosted.test(value) ? "https:" + value : value }

    /// A path the gateway resolves against the session's working directory.
    static func relativeArtifactPath(_ value: String) -> Bool {
        !windowsPath.test(value) && !RX.c(#"^(?:[a-z][a-z0-9+.-]*:|/|~)"#, .caseInsensitive).test(value)
    }

    static func artifactCandidates(_ value: String, session: ArtifactSessionRow) -> [String] {
        let noCwd = session.lacksCwd
        return splitArtifactValue(value).map(hostedArtifactURL).filter { !(noCwd && relativeArtifactPath($0)) }
    }

    /// r2-88: a link to a file keeps the file's own name ("CHANGELOG.md"); "" when the URL does not end in one.
    static func urlFileLabel(_ href: String) -> String {
        guard let url = URL(string: href) else { return "" }
        let name = url.path(percentEncoded: false).split(separator: "/").last.map(String.init) ?? ""
        return RX.c(#"^[^\\/]+\.[A-Za-z][A-Za-z0-9]{0,7}$"#).test(name) ? name : ""
    }

    private static let ccTLDs: Set<String> = Set(("ac ad ae af ag ai al am ao aq ar as at au aw ax az ba bb bd be bf bg bh bi bj bm bn bo bq br bs bt bw by bz " +
        "ca cc cd cf cg ch ci ck cl cm cn co cr cu cv cw cx cy cz de dj dk dm do dz ec ee eg er es et eu fi fj fk fm fo fr ga gb gd ge gf gg " +
        "gh gi gl gm gn gp gq gr gs gt gu gw gy hk hm hn hr ht hu id ie il im in io iq ir is it je jm jo jp ke kg kh ki km kn kp kr kw ky kz " +
        "la lb lc li lk lr ls lt lu lv ly ma mc md me mg mh mk ml mm mn mo mp mq mr ms mt mu mv mw mx my mz na nc ne nf ng ni nl no np nr nu " +
        "nz om pa pe pf pg ph pk pl pm pn pr ps pt pw py qa re ro rs ru rw sa sb sc sd se sg sh si sk sl sm sn so sr ss st su sv sx sy sz tc " +
        "td tf tg th tj tk tl tm tn to tr tt tv tw tz ua ug uk us uy uz va vc ve vg vi vn vu wf ws ye yt za zm zw ai").split(separator: " ").map(String.init))

    /// r4-19: "..." inside a URL elides it, except a git compare range inside one path segment.
    private static func elided(_ raw: String) -> Bool {
        guard raw.contains("...") else { return false }
        guard let parts = RX.c(#"^([a-z][a-z0-9+.-]*://[^/?#]*)([^?#]*)(.*)$"#, .caseInsensitive).exec(raw) else { return true }
        let origin = parts[1] ?? "", path = parts[2] ?? "", rest = parts[3] ?? ""
        if origin.contains("...") || rest.contains("...") { return true }
        return path.split(separator: "/", omittingEmptySubsequences: false).contains { segment in
            segment.contains("...") && !RX.c(#"^[\w.-]*\w\.{3}\w[\w.-]*$"#).test(String(segment))
        }
    }

    /// r3-53: a URL the transcript cut off ("https://telnyx.po…"). `next` is the character after the match.
    static func urlCutOff(_ raw: String, next: String = "") -> Bool {
        if RX.c(#"\.{2,}$|…"#).test(raw) || next == "…" || elided(raw) { return true }
        let stripped = RX.c(#"[.,;:!?*_~`…]+$"#).replace(raw, with: "", all: false)
        guard let url = URL(string: stripped), let host = url.host(percentEncoded: false) else { return true }
        if !host.contains(".") || RX.c(#"^\d{1,3}(?:\.\d{1,3}){3}$"#).test(host) || host.hasPrefix("[") { return false }
        let tld = String(host.split(separator: ".").last ?? "")
        if tld.lowercased().hasPrefix("xn--") { return false }
        if !RX.c(#"^[a-z]+$"#, .caseInsensitive).test(tld) || tld.count < 2 { return true }
        return tld.count == 2 && !ccTLDs.contains(tld.lowercased())
    }

    // MARK: Labels

    private static func cleanSlug(_ segment: String) -> String {
        guard let decoded = segment.removingPercentEncoding else { return "" }
        var s = RX.c(#"\.a\d+\..*$"#, .caseInsensitive).replace(decoded, with: "", all: false)
        s = RX.c(#"\.(?:html?|php|aspx?)$"#, .caseInsensitive).replace(s, with: "", all: false)
        s = RX.c(#"(?:[-_.](?:[a-z]{1,3}\d{2,}|i\d{2,}))+$"#, .caseInsensitive).replace(s, with: "", all: false)
        s = RX.c(#"[_-]+"#).replace(s, with: " ")
        return RX.c(#"\s+"#).replace(s, with: " ").pgTrim
    }

    static func hostPathLabel(_ value: String) -> String {
        guard let url = URL(string: value), let host = url.host(percentEncoded: false) else { return value }
        let shortHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        var path = url.path(percentEncoded: false)
        if path == "/" { path = "" }
        if path.hasSuffix("/") { path.removeLast() }
        return shortHost + path
    }

    /// A link's title from its slug ("…/getting-started" → "Getting Started"), else host + path.
    static func urlSlugTitleLabel(_ value: String) -> String {
        guard let url = URL(string: value) else { return value }
        let segments = url.path(percentEncoded: true).split(separator: "/").map(String.init).reversed()
        for segment in segments {
            let cleaned = cleanSlug(segment)
            if cleaned.isEmpty || !RX.c(#"[a-z]"#, .caseInsensitive).test(cleaned) { continue }
            if RX.c(#"^(?:[a-z]{1,3}\d+|\d+)$"#, .caseInsensitive).test(cleaned.replacingOccurrences(of: " ", with: "")) { continue }
            let identifier = cleaned.contains(where: \.isNumber) || cleaned.contains(where: \.isUppercase) || cleaned.contains(".")
            let label = identifier && !cleaned.contains(" ") ? cleaned
                : RX.c(#"\b[a-z]"#).replace(cleaned) { $0[0]?.uppercased() ?? "" }
            if label.count >= 4 { return label }
        }
        return hostPathLabel(value)
    }

    static func label(_ value: String, kind: ArtifactRecord.Kind) -> String {
        if value.hasPrefix("data:") { return "Image" }
        if kind == .link {
            let file = urlFileLabel(value)
            return file.isEmpty ? urlSlugTitleLabel(value) : file
        }
        if value.hasPrefix("http://") || value.hasPrefix("https://") {
            let file = urlFileLabel(value)
            if !file.isEmpty { return file }
            return URL(string: value)?.path(percentEncoded: false).split(separator: "/").last.map(String.init) ?? value
        }
        var path = value
        if path.hasPrefix("file://") { path = URL(string: path)?.path(percentEncoded: false) ?? path }
        return path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? value
    }

    static func kind(_ value: String) -> ArtifactRecord.Kind {
        if value.hasPrefix("data:image/") || imageExt.test(value) { return .image }
        if isArtifactFilePath(value) { return .file }
        return .link
    }

    /// http/https/data as is; file paths → a `file://` URL string (only used to tell artifacts apart).
    static func href(_ value: String) -> String {
        if value.hasPrefix("http://") || value.hasPrefix("https://") || value.hasPrefix("data:") { return value }
        if value.hasPrefix("file://") { return value }
        if value.hasPrefix("/") || isWindowsPath(value) {
            let escaped = value.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: "#", with: "%23")
                .replacingOccurrences(of: "?", with: "%3F")
            return "file://" + escaped
        }
        return value
    }

    // MARK: Messages

    static func messageText(_ message: JSONValue) -> String {
        for key in ["content", "text", "context"] {
            if let text = message[key]?.string, !text.pgTrim.isEmpty { return text }
        }
        return ""
    }

    private static func normalizeTimestamp(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value < 10_000_000_000 ? value * 1000 : value
    }

    private static func untrustedToolPayload(_ value: String) -> String? {
        let trimmed = value.pgTrim
        guard let open = RX.c(#"^<untrusted_tool_result\b[^>]*>\s*"#).exec(trimmed)?[0] else { return nil }
        guard let close = trimmed.range(of: "</untrusted_tool_result>", options: .backwards) else { return nil }
        let openCount = open.utf16.count
        let closeOffset = trimmed.utf16.distance(from: trimmed.startIndex, to: close.lowerBound)
        guard closeOffset > openCount else { return nil }
        let wrapped = trimmed.pgSlice(openCount, closeOffset).pgTrim
        if let blank = wrapped.range(of: "\n\n") { return String(wrapped[blank.upperBound...]).pgTrim }
        return wrapped
    }

    private static func parseToolPayloads(_ text: String) -> [JSONValue] {
        var out: [JSONValue] = []
        for candidate in [text, untrustedToolPayload(text)] {
            guard let candidate, !candidate.pgTrim.isEmpty, let data = candidate.data(using: .utf8),
                  let parsed = try? JSONValue.parse(data), !parsed.isNull else { continue }
            out.append(parsed)
        }
        return out
    }

    private static func structuredPayload(_ message: JSONValue) -> JSONValue? {
        guard let content = message["content"] else { return nil }
        switch content {
        case .object(let o):
            if o["_multimodal"]?.bool == true { return o["meta"].flatMap { $0.isNull ? nil : $0 } }
            return content
        case .array: return content
        default: return nil
        }
    }

    private static func collectStrings(_ value: JSONValue, _ keyPath: String, _ collector: (String, String) -> Void) {
        switch value {
        case .string(let s): collector(s, keyPath)
        case .array(let a): for (i, entry) in a.enumerated() { collectStrings(entry, "\(keyPath).\(i)", collector) }
        case .object(let o):
            for key in o.keys.sorted() where o[key] != nil { collectStrings(o[key]!, keyPath.isEmpty ? key : "\(keyPath).\(key)", collector) }
        default: break
        }
    }

    private typealias Push = (String, Bool) -> Void

    private static func collectFromText(_ text: String, _ push: Push) {
        for value in mediaTagValues(text) { push(unquoteMediaValue(value), true) }
        // The desktop app's inline page (`::preview{file="…"}`) is a file the reply hands over too.
        for line in text.split(separator: "\n") { if let page = MediaTags.previewPath(String(line)) { push(page, true) } }
        for match in markdownImage.all(text) { push(match[2] ?? "", false) }
        let units = text as NSString
        for match in markdownLink.all(text) {
            if match.range.location > 0, units.character(at: match.range.location - 1) == 0x21 { continue }  // "!"
            let value = decodeMediaHref(match[2] ?? "")
            if looksLikeArtifact(value) { push(value, false) }
        }
        for match in urlRE.all(text) {
            let raw = match[0] ?? ""
            let end = match.range.location + match.range.length
            let next = end < units.length ? units.substring(with: NSRange(location: end, length: 1)) : ""
            if urlCutOff(raw, next: next) { continue }
            let value = RX.c(#"[.,;:!?*_~`]+$"#).replace(raw, with: "", all: false)
            if looksLikeArtifact(value) { push(value, false) }
        }
        for match in pathRE.all(text) { push(match[2] ?? "", false) }
        for match in windowsPathRE.all(text) { push(match[2] ?? "", false) }
    }

    /// The values in what a shell printed that are on the machine: every web address (and inline picture) dropped.
    static func localValues(_ raw: String) -> [String] {
        splitArtifactValue(normalizeValue(decodeMediaHref(raw))).map { hostedArtifactURL(normalizeValue($0)) }
            .filter { !RX.c(#"^(?:https?:|data:)"#, .caseInsensitive).test($0) }
    }

    // MARK: Junk (owner 2026-11-02: "You have a TON of artifacts saved from email footers and other BS")

    private struct JunkRule {
        /// Host suffixes ("sendgrid.net" also covers "u123.ct.sendgrid.net"); empty: any host.
        var hosts: [String] = []
        /// Tested on the lowercased path and query ("/p/abc?x=1"); nil: every address on `hosts`.
        var path: RX? = nil
        /// Kept anyway (one post or video on a social site).
        var keep: RX? = nil
    }

    private static let junkRules: [JunkRule] = [
        // Social profiles, pages and share buttons (an email footer's icons). One post or video is kept.
        JunkRule(hosts: ["tiktok.com", "instagram.com", "facebook.com", "linkedin.com", "x.com", "twitter.com", "youtube.com"],
                 keep: RX(#"^/(?:(?:[^/]+/)+status/\d|(?:p|reels?|tv|shorts|live|embed)/[^/?]+|watch/?\?(?:[^#]*&)?v=|playlist\?|@[^/]+/video/\d|(?:[^/]+/)?(?:posts|videos)/[^/?]+|feed/update/|pulse/|events/\d|jobs/view/|photo|permalink|story\.php|groups/[^/]+/(?:posts|permalink)/|adsmanager/|business/|ads/manager/)"#)),
        // Unsubscribe, email preferences, manage subscription.
        JunkRule(path: RX(#"unsubscribe|\bunsub\b|opt[-_]?out|(?:e-?mail|subscription)s?[-_]?(?:preferences?|prefs|cent(?:er|re))|manage[-_]?(?:subscriptions?|preferences|prefs)|preference[-_]?cent(?:er|re)"#)),
        // Mail senders' click trackers, list hosts and image hosts.
        JunkRule(hosts: ["list-manage.com", "mailchi.mp", "mcusercontent.com", "campaign-archive.com",           // Mailchimp
                         "mail.beehiiv.com", "media.beehiiv.com",                                                // beehiiv
                         "sendgrid.net",                                                                         // ct., u123.ct.
                         "klclick.com", "klclick1.com", "klclick2.com", "klclick3.com", "trk.klaviyo.com", "ctrk.klaviyo.com",
                         "klaviyomail.com",                                                                      // Klaviyo
                         "hubspotlinks.com", "hubspotemail.net", "track.hubspot.com",                            // HubSpot
                         "mandrillapp.com", "mailgun.org", "mailgun.net", "sparkmailapp.com",
                         "cdninstagram.com", "fbcdn.net"]),                                                      // social image CDNs
        // Gmail's image proxy (ci3.googleusercontent.com/meips/…); other googleusercontent pictures stay.
        JunkRule(hosts: ["googleusercontent.com"], path: RX(#"^/(?:meips|proxy)/"#)),
        // Tracking pixels and click redirects: …/open, /wf/open, /track/click, pixel.gif, 1x1.gif.
        JunkRule(path: RX(#"(?:^|/)(?:opens?|pixel|beacon)(?:\.[a-z]{2,4})?(?:/|\?|$)|(?:^|/)(?:track|trk|tracking)(?:/(?:open|click)|\.(?:gif|png|php|aspx?))|(?:^|/)ls/click|(?:^|[/_-])(?:1x1|spacer|transparent|blank)\.(?:gif|png)(?:\?|$)|/1x1(?:/|\?|$)"#)),
    ]

    /// An address that is mail plumbing or a social profile, never something a bot made or the owner wants back.
    static func isJunk(_ value: String) -> Bool {
        guard RX.c(#"^https?://"#, .caseInsensitive).test(value), let url = URL(string: value),
              var host = url.host(percentEncoded: false)?.lowercased() else { return false }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let rest = url.path(percentEncoded: false).lowercased() + (url.query(percentEncoded: true).map { "?" + $0.lowercased() } ?? "")
        return junkRules.contains { rule in
            (rule.hosts.isEmpty || rule.hosts.contains { host == $0 || host.hasSuffix("." + $0) })
                && (rule.path?.test(rest) ?? true) && !(rule.keep?.test(rest) ?? false)
        }
    }

    /// Owner 2026-11-03 ("Why am I flooded with these artifacts?"): the Inbox bot's mail check keeps every email it reads
    /// under `profiles/mail/state/attachments/<id>/part-N.png` (each inline logo, icon and pasted
    /// screenshot a file) and its shell names them, so 855 footer pictures were tiles. A file in a bot's own working
    /// folder under `.hermes` (`state`, `…_state`) is its bookkeeping, not something it made for the owner: it counts
    /// only when the bot hands it over (`MEDIA:`, `::preview`).
    private static let botStateFolder = RX(#"(?:^|/)\.hermes/(?:[^/]+/)*?(?:state|[^/]+_state)/"#, .caseInsensitive)

    static func isBotStateFile(_ value: String) -> Bool {
        guard isArtifactFilePath(value) else { return false }
        return botStateFolder.test(value.replacingOccurrences(of: "\\", with: "/"))
    }

    /// Owner 2026-11-03 ("why so many random images"): a bot's own working pictures (its computer-use and browser
    /// screenshots, its picture cache) are how it looks at things, not things it made for the owner. They count only
    /// when the bot hands one over (`MEDIA:`, `::preview`).
    private static let workingPicture = RX(#"(?:^|/)\.hermes/(?:[^/]+/)*?cache/(?:images|screenshots)/|/\.config/browser-harness/tmp/|(?:^|/)(?:computer_use|browser_screenshot)_[0-9a-f]+\.(?:png|jpe?g|webp)$"#, .caseInsensitive)

    static func isWorkingPicture(_ value: String) -> Bool {
        guard isArtifactFilePath(value) else { return false }
        return workingPicture.test(value.replacingOccurrences(of: "\\", with: "/"))
    }

    /// Owner 2026-11-03 (round 2): an email's inline pictures saved one part at a time are the mail, not something a bot
    /// made: any file in an `…email_evidence` folder, a `part-N` picture under a mail folder (`gmail_…`, `icloud_…`,
    /// `inbox…`, also outside a `…_state` folder or a `.hermes` home), and Outlook's `image001.png`. Sent, they stay.
    private static let savedEmailPart = RX(#"(?:^|/)[^/]*email[_-]?evidence[^/]*/|(?:^|/)[^/]*(?:mail|icloud|inbox|outlook|mime|eml)[^/]*/(?:[^/]+/)*part-\d+(?:\.\d+)*\.(?:png|jpe?g|gif|webp|bmp|svg)$|(?:^|/)image0\d\d\.(?:png|jpe?g|gif)$"#, .caseInsensitive)

    static func isSavedEmailPart(_ value: String) -> Bool { savedEmailPart.test(pathForFiltering(value)) }

    /// Owner 2026-11-03 (round 2): a site's own icons (favicon, apple-touch-icon) and a weather feed's sun and cloud
    /// pictures are page furniture, wherever a bot names them. Sent, they stay.
    private static let webIcon = RX(#"(?:^|/)(?:favicon|apple-touch-icon|android-chrome|mstile|safari-pinned-tab)[^/]*\.(?:png|ico|svg|jpe?g|gif|webp)$|/weather/(?:[^/]+/)*(?:\d+x\d+|icons?)/|/onebox/weather/|/img/wn?/\d+[dn](?:@\dx)?\.png$|(?:^|/)wsymbols?\d*_|(?:^|/)weather[-_]?icons?/|/icons?/weather/"#, .caseInsensitive)

    static func isWebIcon(_ value: String) -> Bool { webIcon.test(pathForFiltering(value)) }

    /// "//cdn…/icon.png" is a web address without its scheme, never a file on the machine; so is the same address with
    /// its slashes JSON-escaped (`\/\/cdn…`, `\\/\\/cdn…`), which otherwise reads as a Windows share path.
    static func isSchemelessWebAddress(_ value: String) -> Bool {
        RX.c(#"\\+/"#).replace(value, with: "/").hasPrefix("//")
    }

    /// Hermes's context-compaction handoff (`agent/context_compressor.py`: `[CONTEXT COMPACTION — REFERENCE ONLY]`,
    /// `[CONTEXT SUMMARY]:`, the merged `[PRIOR CONTEXT — …]` carrier) retells earlier turns: every picture a bot looked
    /// at and every request it was given, quoted. It hands nothing over; the turns it retells counted already.
    private static let compactionHead = RX(#"^\s*\[(?:CONTEXT COMPACTION|CONTEXT SUMMARY\]:|PRIOR CONTEXT\b)"#)

    static func isCompactionSummary(_ message: JSONValue) -> Bool {
        if message["_compressed_summary"]?.bool == true { return true }
        return compactionHead.test(String(messageText(message).prefix(300)))
    }

    /// Tools that look at a screen or a page: what they return is a working picture, never an artifact by itself.
    private static let lookingTool = RX(#"^(?:computer_use|browser_[a-z_]+|vision_analyze)$"#)

    private static func collectFromMessage(_ message: JSONValue, _ pushAny: Push) {
        let role = message["role"]?.string
        let text = messageText(message)
        if role == "assistant" {
            if !text.isEmpty { collectFromText(text, pushAny) }
            return
        }
        guard role == "tool" else { return }
        let name = (message["tool_name"]?.string ?? message["name"]?.string ?? "").pgTrim.lowercased()
        let producer = producerTool.test(name) || name.hasPrefix("bfl_flux3_")
        let terminal = name == "terminal"
        // Owner 2026-11-02 ("so many random artifacts that I never created"; "a TON of artifacts saved from email
        // footers"): a command that printed an email's HTML listed every logo and link in it. A shell's output makes
        // no web artifacts at all: only the files on the machine it names, and `MEDIA:` / `::preview` it hands over.
        // Links come from what the bot says, and from tools that make things.
        let looking = lookingTool.test(name)
        // Owner 2026-11-03 ("why so many random images"): a shell that lists a folder names every picture in it, so a
        // picture never comes from a shell; other files it names stay. Round 2: a `MEDIA:` a shell printed is not handed over either (a grep of source comments, a test's printout).
        // Hermes sends tool-output `MEDIA:` only from text_to_speech and image_generate (`gateway/run.py`
        // `_AUTO_APPEND_MEDIA_TOOL_NAMES`), so from a shell it is one more name: no picture, other files as named.
        func push(_ raw: String, _ explicit: Bool) {
            if explicit && !terminal { pushAny(raw, true); return }
            if looking { return }
            guard terminal else { pushAny(raw, false); return }
            for value in localValues(raw) where kind(value) != .image { pushAny(value, false) }
        }
        var payloads = parseToolPayloads(text)
        // Round 2: a tool that failed made nothing; image_generate's error repeats the picture it was given.
        if payloads.contains(where: { $0["success"]?.bool == false }) { return }
        if !text.isEmpty && (producer || terminal) { collectFromText(text, push) }
        if name == "browser_vision" && !text.isEmpty {
            for match in screenshotPath.all(text) { push(match[1] ?? "", false) }
        }
        if let structured = structuredPayload(message) { payloads.append(structured) }
        for parsed in payloads {
            collectStrings(parsed, "tool_result") { value, keyPath in
                let segments = keyPath.split(separator: ".").map(String.init).filter { !$0.isEmpty && Int($0) == nil }
                let shellOutput = terminal && segments.contains { shellOutputKey.test($0) }
                let explicitKey = segments.contains { strongKey.test($0) || (producer && producerKey.test($0)) }
                guard shellOutput || explicitKey else { return }
                if shellOutput {
                    if !value.isEmpty { collectFromText(value, push) }
                    return
                }
                for media in mediaTagValues(value) { push(unquoteMediaValue(media), true) }
                let normalized = normalizeValue(decodeMediaHref(value))
                if !normalized.isEmpty && looksLikeArtifact(normalized) { push(normalized, false) }
            }
        }
    }

    /// Artifacts in one page of a session's transcript, first occurrence per value.
    static func collect(session: ArtifactSessionRow, messages: [JSONValue], now: Double = Date().timeIntervalSince1970 * 1000) -> [ArtifactRecord] {
        var found: [String: Int] = [:]
        var out: [ArtifactRecord] = []
        let title = session.displayTitle
        for message in messages {
            let role = message["role"]?.string
            guard role == "assistant" || role == "tool", !isCompactionSummary(message) else { continue }
            collectFromMessage(message) { raw, explicit in
                // Owner 2026-11-03: a pasted page's `//cdn…/icon.png` (a weather icon, a footer logo) is a web address,
                // not a path on the machine, and nobody handed it over. Round 2: each value of a joined one too, and
                // the JSON-escaped `\/\/cdn…`.
                let normalized = normalizeValue(decodeMediaHref(raw))
                let parts = explicit ? [normalized] : splitArtifactValue(normalized).filter { !isSchemelessWebAddress($0) }
                for candidate in parts.flatMap({ artifactCandidates($0, session: session) }) {
                    let value = normalizeValue(candidate)
                    guard !value.isEmpty, looksLikeArtifact(value, explicit: explicit), !isJunk(value),
                          explicit || (!isBotStateFile(value) && !isWorkingPicture(value) && !isSavedEmailPart(value)
                                       && !isWebIcon(value)) else { continue }
                    // The profile is part of the id: two profiles can hold the same session id (copied homes), and the
                    // page's diffable snapshot needs every id once.
                    let key = "\(ArtifactIndex.key(profile: session.profile, id: session.id)):\(value)"
                    // [morepages] a repeat is counted on the row that is kept (3x-morepages §2)
                    if let index = found[key] { out[index].repeats += 1; continue }
                    let kind = kind(value)
                    let stamp = normalizeTimestamp(message["timestamp"]?.double) ?? normalizeTimestamp(session.lastActive)
                        ?? normalizeTimestamp(session.startedAt) ?? now
                    found[key] = out.count
                    out.append(ArtifactRecord(id: key, kind: kind, value: value, href: href(value), label: label(value, kind: kind),
                                              sessionId: session.id, profile: session.profile, sessionTitle: title, timestamp: stamp))
                }
            }
        }
        return out
    }

    /// Across sessions, one per [profile, kind, value, href], newest first (`artifacts-model.ts` keeps one per chat).
    /// [pins] Tester, 2026-10-31: a dashboard a bot rewrites in every chat (or every job run) filled the list
    /// with one row per chat. A file at a full path, or a link, is one row now: the newest chat's, counting every
    /// mention. A relative path is still one per chat (each chat's folder can hold a different file of that name).
    static func unique(_ items: [ArtifactRecord]) -> [ArtifactRecord] {
        // [morepages] The same record can arrive twice (the kept index and a fresh read of that chat): it counts once,
        // with the larger count, never the sum, so a re-read does not double it.
        var seen: [String: Int] = [:]
        var counts: [[String: Int]] = []   // per row: record id → its count
        var out: [ArtifactRecord] = []
        for item in items.sorted(by: { $0.timestamp > $1.timestamp }) {
            let chat = relativeArtifactPath(item.value) ? item.sessionId : ""
            let key = "\(item.profile ?? "")\u{1F}\(chat)\u{1F}\(item.kind.rawValue)\u{1F}\(item.value)\u{1F}\(item.href)"
            if let index = seen[key] {
                counts[index][item.id] = max(counts[index][item.id] ?? 0, item.repeats)
                out[index].repeats = counts[index].values.reduce(0, +)
                continue
            }
            seen[key] = out.count
            counts.append([item.id: item.repeats])
            out.append(item)
        }
        return out
    }

    /// Reads one session page by page (oldest first, 100 at a time), collecting as it goes. Throws the safe-load error
    /// for a page over the limit, or the page read's own error.
    @concurrent
    static func loadSession(_ session: ArtifactSessionRow, maxPageJSONChars: Int = maxPageJSONChars,
                            page: @Sendable (ArtifactSessionRow, _ limit: Int, _ offset: Int) async throws -> Data) async throws -> [ArtifactRecord] {
        var collected: [ArtifactRecord] = []
        var seen: [String: Int] = [:]   // [morepages] id → index: a repeat on a later page adds to the kept row's count
        var offset = 0
        while true {
            try Task.checkCancellation()
            let data = try await page(session, pageSize, offset)
            let json = try JSONValue.parse(data)
            let messages = json["messages"]?.array ?? json.array ?? []
            // The page's JSON size (`JSON.stringify(page.messages).length`): the answer's bytes bound it closely.
            if data.count > maxPageJSONChars, let encoded = try? JSONValue.array(messages).encoded(), encoded.count > maxPageJSONChars {
                throw ArtifactLoadError.safeLoadLimit
            }
            for artifact in collect(session: session, messages: messages) {
                if let index = seen[artifact.id] { collected[index].repeats += artifact.repeats; continue }
                seen[artifact.id] = collected.count
                collected.append(artifact)
            }
            let limit = json["pagination"]?["limit"]?.int
            guard let limit, !messages.isEmpty, messages.count >= limit else { break }
            offset += messages.count
        }
        return collected
    }
}

nonisolated enum ArtifactLoadError: Error, LocalizedError, Sendable {
    case safeLoadLimit
    var errorDescription: String? { ArtifactCollector.safeLoadMessage }
}
