// computer_use and browser screenshots in a tool result (docs/spec/3x-screen.md §5.3; the web's `image-zoom.ts` and
// `tool-screenshots.ts`, ported one for one). A live result is a multimodal envelope; a reloaded transcript keeps only
// the text summary, which names the capture by its gateway path. The gateway keeps only its newest 20 captures, so an
// older step's file can be gone: `ScreenshotExpiry` finds that out with one folder listing.

import Foundation

/// The capture a step shows. `source` is a gateway path, or a `data:image/…` URL (kept in memory only).
nonisolated struct ToolScreenshot: Sendable, Hashable {
    var source: String
    var expired = false
    /// When the tool finished, unix seconds (the stored row's time, or the moment the live result arrived). The
    /// expiry check needs it: a folder listing older than the capture says nothing about it.
    var capturedAt: Double? = nil

    var isInline: Bool { ToolScreenshots.isInline(source) }
    /// The file's name, for "Open image: <name>".
    var fileName: String { ToolScreenshots.fileName(source) }
}

nonisolated enum ToolScreenshots {
    static let expiredNote = "This screenshot has expired: the gateway keeps only its 20 most recent screenshots."

    static func isScreenshotTool(_ name: String?) -> Bool {
        guard let name else { return false }
        return name.hasPrefix("computer_use") || name.hasPrefix("browser_")
    }

    /// `data:`, `blob:` and `http(s):` sources are never files on the gateway.
    static func isRemote(_ source: String) -> Bool {
        let lower = source.prefix(8).lowercased()
        return lower.hasPrefix("data:") || lower.hasPrefix("blob:") || lower.hasPrefix("http:") || lower.hasPrefix("https:")
    }

    static func isInline(_ source: String) -> Bool { source.prefix(11).lowercased() == "data:image/" }

    static func fileName(_ source: String) -> String {
        if isRemote(source) { return "screenshot" }
        let cut = source.lastIndex(where: { $0 == "/" || $0 == "\\" }).map { source.index(after: $0) } ?? source.startIndex
        return String(source[cut...])
    }

    private static let saved = try? NSRegularExpression(
        pattern: #"screenshot (?:saved to|path:)\s*(\S+\.(?:png|jpe?g|webp))"#, options: [.caseInsensitive])

    /// The path a text summary names ("… screenshot saved to <path>"), "" when it names none.
    static func savedScreenshot(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = saved?.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let found = Range(match.range(at: 1), in: text) else { return "" }
        return String(text[found])
    }

    /// The image of a multimodal tool result: an inline `data:image/…`, else the path it names. "" when none.
    static func multimodalToolImage(_ result: JSONValue?) -> String {
        guard let result else { return "" }
        switch result {
        case .string(let text): return savedScreenshot(text)
        case .array(let items):
            for case .string(let text) in items {
                let path = savedScreenshot(text)
                if !path.isEmpty { return path }
            }
            return ""
        case .object(let record):
            for part in record["content"]?.array ?? [] {
                let value = part["image_url"]?.string ?? part["image_url"]?["url"]?.string
                if let value, isInline(value) { return value }
            }
            if let path = record["meta"]?["screenshot_path"]?.string { return path }
            if let path = record["screenshot_path"]?.string { return path }
            for key in record.keys.sorted() {
                guard case .string(let text)? = record[key] else { continue }
                let path = savedScreenshot(text)
                if !path.isEmpty { return path }
            }
            return ""
        default: return ""
        }
    }

    /// The screenshot a STORED tool result names: a string is read as JSON when it is one, else as the summary.
    static func storedScreenshot(_ result: JSONValue?) -> String {
        guard case .string(let text)? = result else { return multimodalToolImage(result) }
        return storedScreenshot(text: text)
    }

    static func storedScreenshot(text: String) -> String {
        let trimmed = text.drop(while: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
        if let first = trimmed.first, first == "{" || first == "[", let parsed = try? JSONValue.parse(Data(text.utf8)) {
            switch parsed {
            case .object, .array: return multimodalToolImage(parsed)
            default: break
            }
        }
        return savedScreenshot(text)
    }

    /// A live `tool.complete`: the result's own image, else the path its text or summary names.
    static func liveSource(result: JSONValue?, resultText: String?, summary: String?) -> String {
        let direct = multimodalToolImage(result)
        if !direct.isEmpty { return direct }
        if let resultText {
            let found = storedScreenshot(text: resultText)
            if !found.isEmpty { return found }
        }
        if let summary { return storedScreenshot(text: summary) }
        return ""
    }

    /// The inline picture is kept for a step only below this many characters (a data URL of about 3 MB of picture).
    static let maxInlineStep = 4 << 20

    /// The screenshot a step keeps. DECISION: the gateway path wins over the inline picture when the result carries
    /// both (a chat keeps every step's detail in memory, and a long computer_use run would otherwise hold megabytes
    /// per step); an inline picture is kept only when there is no path and it is not huge.
    static func stepScreenshot(result: JSONValue?, resultText: String?, summary: String?, at: Double? = nil) -> ToolScreenshot? {
        guard var shot = stepSource(result: result, resultText: resultText, summary: summary) else { return nil }
        shot.capturedAt = at
        return shot
    }

    private static func stepSource(result: JSONValue?, resultText: String?, summary: String?) -> ToolScreenshot? {
        var result = result
        // A stored result is often the JSON text of the envelope.
        if case .string(let text)? = result, let first = text.first(where: { !$0.isWhitespace }), first == "{",
           let parsed = try? JSONValue.parse(Data(text.utf8)), parsed.object != nil { result = parsed }
        let first = liveSource(result: result, resultText: resultText, summary: summary)
        guard !first.isEmpty else { return nil }
        guard isInline(first) else { return ToolScreenshot(source: first) }
        var path = ""
        if case .object(var record)? = result {
            record["content"] = nil
            path = multimodalToolImage(.object(record))
        }
        if path.isEmpty, let resultText { path = storedScreenshot(text: resultText) }
        if path.isEmpty, let summary { path = storedScreenshot(text: summary) }
        if !path.isEmpty, !isInline(path) { return ToolScreenshot(source: path) }
        return first.utf8.count <= maxInlineStep ? ToolScreenshot(source: first) : nil
    }

    /// The screenshot of a screen tool's result ("" for other tools).
    static func restored(tool: String?, result: JSONValue?) -> String {
        isScreenshotTool(tool) ? storedScreenshot(result) : ""
    }

    /// An expired step's Output: the note, a blank line, then what the gateway stored.
    static func expiredOutput(_ stored: String?) -> String {
        guard let stored, !stored.isEmpty else { return expiredNote }
        return expiredNote + "\n\n" + stored
    }

    /// A folder's file names from `GET /api/fs/list?path=<dir>`; nil when the answer is no listing.
    static func names(inListing data: Data) -> Set<String>? {
        guard let json = try? JSONValue.parse(data) else { return nil }
        if let error = json["error"], !error.isNull, error.bool != false, error.string != "" { return nil }
        guard let entries = json["entries"]?.array else { return nil }
        return Set(entries.map { $0["name"]?.string ?? "" })
    }
}

/// Whether the gateway still has a step's screenshot. One per account. The web's rules and numbers: a folder's listing
/// is reused for 60 s, fetched again when it predates the capture by less than a second (so a new screenshot is never
/// called expired), an unreadable or empty listing proves nothing (ask again at most every 30 s), and both tables are
/// bounded (64 listings, 2,000 settled calls).
actor ScreenshotExpiry {
    typealias Lister = @Sendable (String) async -> Set<String>?

    static let listingLife: TimeInterval = 60
    static let retryAfter: TimeInterval = 30
    static let maxListings = 64
    static let maxNoted = 2_000

    private struct Listing { var at: TimeInterval; var names: Task<Set<String>?, Never> }

    private let list: Lister
    private var listings: [String: Listing] = [:]
    private var listingOrder: [String] = []
    private var noted: [String: Bool] = [:]             // settled calls: true = the file is gone
    private var notedOrder: [String] = []
    private var asked: [String: TimeInterval] = [:]
    private var askedOrder: [String] = []

    init(list: @escaping Lister) { self.list = list }

    init(client: any GatewayClient, profile: String?) {
        list = { directory in
            var query = [URLQueryItem(name: "path", value: directory)]
            if let profile, !profile.isEmpty { query.append(URLQueryItem(name: "profile", value: profile)) }
            guard let data = try? await client.rest("GET", "/api/fs/list", query: query, body: nil) else { return nil }
            return ToolScreenshots.names(inListing: data)
        }
    }

    /// How much is held (tests: the caps).
    var held: (listings: Int, noted: Int, asked: Int) { (listings.count, noted.count, asked.count) }

    /// What an earlier check settled for this call (nil: not settled yet).
    func settled(_ toolCallId: String) -> Bool? { noted[toolCallId] }

    /// true when the gateway no longer has `path`. `completedAt`: unix seconds (a stored row) or milliseconds (live).
    func check(toolCallId: String?, path: String, completedAt: Double?, now: TimeInterval = Date().timeIntervalSince1970) async -> Bool {
        guard let toolCallId, !toolCallId.isEmpty, !path.isEmpty, !ToolScreenshots.isRemote(path) else { return false }
        if let known = noted[toolCallId] { return known }
        if let last = asked[toolCallId], now - last < Self.retryAfter { return false }
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else {
            settle(toolCallId, false)
            return false
        }
        asked[toolCallId] = now
        askedOrder.append(toolCallId)
        trimAsked()
        let directory = String(path[..<slash]), name = String(path[path.index(after: slash)...])
        let captured: TimeInterval = completedAt.map { $0 > 0 ? ($0 < 1e12 ? $0 : $0 / 1000) : now } ?? now
        let cached: Listing
        if let have = listings[directory], have.at > captured + 1, now - have.at <= Self.listingLife {
            cached = have
        } else {
            let list = self.list
            cached = Listing(at: now, names: Task { await list(directory) })
            listings[directory] = cached
            listingOrder.removeAll { $0 == directory }
            listingOrder.append(directory)
            for (key, entry) in listings where key != directory && now - entry.at > Self.listingLife {
                listings[key] = nil
                listingOrder.removeAll { $0 == key }
            }
            while listings.count > Self.maxListings, let oldest = listingOrder.first {
                listingOrder.removeFirst()
                listings[oldest] = nil
            }
        }
        let names = await cached.names.value
        guard let names, !names.isEmpty else {
            // An unreadable folder is not kept for the next step to reuse.
            if names == nil, let now = listings[directory], now.at == cached.at {
                listings[directory] = nil
                listingOrder.removeAll { $0 == directory }
            }
            return false
        }
        if let known = noted[toolCallId] { return known }          // settled while the listing was read
        asked[toolCallId] = nil
        let gone = !names.contains(name)
        settle(toolCallId, gone)
        return gone
    }

    private func settle(_ id: String, _ gone: Bool) {
        if noted[id] == nil { notedOrder.append(id) }
        noted[id] = gone
        while noted.count > Self.maxNoted, let oldest = notedOrder.first {
            notedOrder.removeFirst()
            noted[oldest] = nil
        }
    }

    private func trimAsked() {
        if askedOrder.count > Self.maxNoted * 2 { askedOrder = askedOrder.filter { asked[$0] != nil } }
        while asked.count > Self.maxNoted, let oldest = askedOrder.first {
            askedOrder.removeFirst()
            asked[oldest] = nil
        }
    }
}
