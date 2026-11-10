// Reading an artifact's bytes from the gateway (docs/spec/1x-pages.md §5.2, §5.6): image previews through
// `/api/fs/read-data-url`, files through `/api/fs/download`, both with the artifact's `session_id` and profile; how
// each kind opens; and the failure words (`previewErrorText`, `src/artifact-preview.ts:271-306`).

import CryptoKit
import Foundation

nonisolated enum ArtifactFiles {
    /// Text the native viewer opens (`S/bridge/fe-pages.ts:26-29`).
    static let textExtensions: Set<String> = ["md", "markdown", "mdx", "txt", "text", "log", "json", "jsonl", "yaml", "yml",
                                              "toml", "ini", "cfg", "conf", "xml", "py", "js", "mjs", "cjs", "ts", "tsx",
                                              "jsx", "sh", "zsh", "bash", "swift", "rb", "go", "rs", "java", "kt", "c", "h",
                                              "cc", "cpp", "hpp", "css", "scss", "sql"]
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdx"]
    /// The native text viewer reads files up to 2 MiB; bigger ones open in Quick Look.
    static let textLimit = 2 << 20
    /// The REST ceiling (D-P9).
    static let fileLimit = 32 << 20
    /// Mac polish #143: the device by name, as GatewayFailure's words ("…on this Mac"; it said "your phone" everywhere).
    static var tooLargeText: String { "This file is too large to open on this \(DeviceWord.name)." }

    enum Opening: Equatable, Sendable {
        case link
        case image
        case text(markdown: Bool, language: String?)
        case html
        case quickLook
    }

    static func fileExtension(_ value: String) -> String {
        var name = ArtifactCollector.label(value, kind: .file)
        if let q = name.firstIndex(of: "?") { name = String(name[..<q]) }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }

    static func opening(_ record: ArtifactRecord) -> Opening {
        if record.kind == .link { return .link }
        if record.kind == .image { return .image }
        let ext = fileExtension(record.value)
        if ext == "html" || ext == "htm" { return .html }
        if textExtensions.contains(ext) { return .text(markdown: markdownExtensions.contains(ext), language: language(ext)) }
        return .quickLook
    }

    /// A downloaded text file opens in the native viewer up to `textLimit`; a bigger one (a 3 MiB log) in Quick Look.
    static func opensAsText(_ opening: Opening, bytes: Int) -> Bool {
        if case .text = opening { return bytes <= textLimit }
        return false
    }

    /// The highlighter's language tag for a code file (nil = plain).
    static func language(_ ext: String) -> String? {
        switch ext {
        case "md", "markdown", "mdx", "txt", "text", "log": return nil
        case "yml": return "yaml"
        case "mjs", "cjs": return "js"
        case "zsh", "bash": return "sh"
        case "cc", "cpp", "hpp", "h": return "cpp"
        case "jsonl": return "json"
        default: return ext
        }
    }

    /// The gateway can serve it (http(s) and data URLs are not gateway files).
    static func isGatewayFile(_ record: ArtifactRecord) -> Bool {
        !(isHosted(record) || record.value.hasPrefix("data:"))
    }

    static func query(_ record: ArtifactRecord) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "path", value: record.value), URLQueryItem(name: "session_id", value: record.sessionId)]
        if let profile = record.profile, !profile.isEmpty { items.append(URLQueryItem(name: "profile", value: profile)) }
        return items
    }

    /// A hosted image (named by its http(s) URL rather than a gateway path).
    static func isHosted(_ record: ArtifactRecord) -> Bool {
        let value = record.value.lowercased()
        return value.hasPrefix("http://") || value.hasPrefix("https://")
    }

    /// The image is on another site and was not fetched (the tile offers Open).
    static func isHostedElsewhere(_ error: Error) -> Bool { error is RemoteImageFetch.Refused }

    /// An image's bytes: a data URL as is; a gateway file through `read-data-url`; a hosted image only over https from a
    /// public host, without gateway credentials (`RemoteImageFetch`; an http one is refused). Off the main thread: a
    /// `read-data-url` answer can be ~22 MB of JSON holding 16 MiB of base64.
    @concurrent
    static func imageData(_ client: any GatewayClient, _ record: ArtifactRecord) async throws -> Data {
        let began = ContinuousClock.now
        let source = record.value.hasPrefix("data:") ? "inline" : isHosted(record) ? "hosted" : "gateway"
        do {
            let data = try await readImage(client, record)
            AppLog.trace("artifacts", "image \(AppLog.tag(record.sessionId)) (\(source)): \(data.count) B, \(AppLog.ms(since: began)) ms")
            return data
        } catch {
            AppLog.note("artifacts", "image \(AppLog.tag(record.sessionId)) (\(source)) failed after \(AppLog.ms(since: began)) ms: \(AppLog.scrub(String(describing: error)))")
            throw error
        }
    }

    private static func readImage(_ client: any GatewayClient, _ record: ArtifactRecord) async throws -> Data {
        if record.value.hasPrefix("data:") { return try decodeDataURL(record.value) }
        if isHosted(record) { return try await RemoteImageFetch.fetch(record.value) }
        let json = try await PagesREST.json(client, "GET", "/api/fs/read-data-url", query: query(record), timeout: 60)
        guard let dataURL = json["dataUrl"]?.string ?? json["data_url"]?.string else {
            throw PagesMessageError("This image could not be read.")
        }
        return try decodeDataURL(dataURL)
    }

    static func decodeDataURL(_ value: String) throws -> Data {
        guard let comma = value.firstIndex(of: ",") else { throw PagesMessageError("This image could not be read.") }
        let header = value[..<comma], payload = String(value[value.index(after: comma)...])
        if header.hasSuffix(";base64") {
            guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) else {
                throw PagesMessageError("This image could not be read.")
            }
            return data
        }
        return Data((payload.removingPercentEncoding ?? payload).utf8)
    }

    /// A gateway file's bytes (`/api/fs/download`).
    static func download(_ client: any GatewayClient, _ record: ArtifactRecord) async throws -> Data {
        let began = ContinuousClock.now
        do {
            let data = try await PagesREST.send(client, "GET", "/api/fs/download", query: query(record), timeout: 120)
            AppLog.trace("artifacts", "file \(AppLog.tag(record.sessionId)) .\((record.label as NSString).pathExtension): \(data.count) B, \(AppLog.ms(since: began)) ms")
            return data
        } catch {
            AppLog.note("artifacts", "file \(AppLog.tag(record.sessionId)) .\((record.label as NSString).pathExtension) failed after \(AppLog.ms(since: began)) ms: \(AppLog.scrub(String(describing: error)))")
            throw error
        }
    }

    /// A gateway file by path for a profile (a job's run document, no session).
    static func download(_ client: any GatewayClient, path: String, profile: String) async throws -> Data {
        try await PagesREST.send(client, "GET", "/api/fs/download",
                                 query: [URLQueryItem(name: "path", value: path), URLQueryItem(name: "profile", value: profile)], timeout: 120)
    }

    /// Where a downloaded preview is kept for Quick Look: Caches/pages/preview/<account>/<hash>/<file name>.
    static func previewURL(account: GatewayAccount, record: ArtifactRecord) -> URL {
        let digest = SHA256.hash(data: Data("\(record.profile ?? "")|\(record.sessionId)|\(record.value)".utf8))
        let hash = digest.prefix(10).map { String(format: "%02x", $0) }.joined()
        var name = record.label.isEmpty ? "file" : record.label
        name = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return PagesCache.directory(for: account, root: PagesCache.previewRoot).appending(path: hash).appending(path: name)
    }

    /// Verify round 3: the HTML Preview's copy of a page with no viewport tag gets one (`width=device-width`). Quick Look
    /// lays such a page out 980 px wide, so a bot's report read at about 6 pt. nil when the page has its own (or isn't
    /// UTF-8): the file itself is previewed then.
    static func previewHTML(_ data: Data) -> Data? {
        guard let html = String(data: data, encoding: .utf8) else { return nil }
        if html.range(of: #"<meta[^>]*name\s*=\s*["']?viewport"#, options: [.regularExpression, .caseInsensitive]) != nil { return nil }
        let meta = #"<meta name="viewport" content="width=device-width, initial-scale=1">"#
        var out = html
        if let head = html.range(of: #"<head(\s[^>]*)?>"#, options: [.regularExpression, .caseInsensitive]) {
            out.insert(contentsOf: meta, at: head.upperBound)
        } else if let root = html.range(of: #"<html(\s[^>]*)?>"#, options: [.regularExpression, .caseInsensitive]) {
            out.insert(contentsOf: "<head>\(meta)</head>", at: root.upperBound)
        } else {
            out = meta + html
        }
        return Data(out.utf8)
    }

    /// Where the HTML Preview's copy goes: beside the file, so its relative links and images still resolve.
    static func previewCopyURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appending(path: "preview-" + url.lastPathComponent)
    }

    @concurrent
    static func save(_ data: Data, to url: URL) async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    // MARK: Failure words

    /// The file is gone or can't be placed (it goes to Unavailable): 404, a relative path without a folder, a bad path.
    static func isMissing(_ error: Error) -> Bool {
        guard let status = PagesREST.status(error) else { return false }
        return status == 404 || status == 400
    }

    /// The link, not the file: no network, the gateway held back or not answering, a 429 or 5xx. A tile that failed
    /// this way is asked again when the gateway is back or the page shows again; a refusal or a bad file is not.
    static func isTransient(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let failure = error as? GatewayFailure { return failure != .responseTooLarge }
        if let status = PagesREST.status(error) { return status == 429 || (500...599).contains(status) }
        if PagesREST.transportReason(error) != nil { return (error as NSError).code != NSURLErrorCancelled }
        return false
    }

    /// Why a file couldn't open, in words.
    static func failureText(_ error: Error, image: Bool) -> String {
        if let refused = error as? RemoteImageFetch.Refused { return refused.errorDescription ?? "" }
        if let failure = error as? GatewayFailure {
            switch failure {
            case .responseTooLarge: return image ? "This image is too large to preview." : tooLargeText
            case .timeout, .unavailable: return "\(HostWord.sentence) took too long to answer. Try again in a moment."
            default: return failure.message
            }
        }
        if let status = PagesREST.status(error) {
            let detail = (error as? HTTPError).flatMap(PagesREST.detail) ?? ""
            switch status {
            case 404: return "This file is no longer on \(HostWord.phrase). It may have been moved or deleted."
            case 403: return "\(HostWord.sentence) does not allow reading this file."
            case 413: return image ? "This image is too large to preview." : tooLargeText
            case 400:
                if detail.range(of: "working directory is unavailable", options: .caseInsensitive) != nil {
                    return "From an older session whose folder is unknown."
                }
                return "The gateway can't open this file path."
            case 502, 503, 504, 524: return "\(HostWord.sentence) took too long to answer. Try again in a moment."
            default: return detail.isEmpty ? "This file could not be read." : detail
            }
        }
        if let url = error as? URLError, url.code == .timedOut { return "\(HostWord.sentence) took too long to answer. Try again in a moment." }
        return PagesREST.reason(error)
    }

    /// A job's run document with its answer first: "## Response" / "## Error" / "## Script Error" sections move above
    /// the prompt (`promptLast`, `S/stress-c.tsx:25-35`).
    static func runDocumentFirst(_ text: String) -> String {
        // `text.split(/^(?=## )/m)`: cut before every line that starts with "## " (never at offset 0).
        let ns = text as NSString
        let cuts = RX.c(#"^(?=## )"#, .anchorsMatchLines).all(text).map(\.range.location).filter { $0 > 0 }
        var pieces: [String] = []
        var from = 0
        for cut in cuts {
            pieces.append(ns.substring(with: NSRange(location: from, length: cut - from)))
            from = cut
        }
        pieces.append(ns.substring(from: from))
        let head = pieces[0]
        let sections = Array(pieces.dropFirst())
        let result = RX.c(#"^## (?:Response|Error|Script Error)[ \t]*$"#)
        let first = sections.indices.filter { result.test(sections[$0].components(separatedBy: "\n")[0]) }
        if first.isEmpty || first == [0] { return text }
        func ended(_ section: String) -> String { RX.c(#"\n*$"#).replace(section, with: "\n\n", all: false) }
        let ordered = first.map { sections[$0] } + sections.indices.filter { !first.contains($0) }.map { sections[$0] }
        return RX.c(#"\n+$"#).replace(head + ordered.map(ended).joined(), with: "\n", all: false)
    }
}
