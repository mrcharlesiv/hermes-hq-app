// [shopping] Fallback photo discovery for product and hotel cards when a tool call omits `image` or its URL fails:
// reads the store/hotel page through the existing bounded, cookieless, public-IP-checked `LinkPreviewFetcher` (256 KiB
// HTML cap, 5 s timeout, no cookies/credentials), extracts JSON-LD `image` and Open Graph / Twitter Card image URLs,
// skips SVGs, favicons, logos and generic site share banners, and caches results in memory per run.

import Foundation
import Synchronization

nonisolated enum ProductPhotoParsing {
    private static let scriptLD = TRx(#"<script\b[^>]*type\s*=\s*["']application/ld\+json["'][^>]*>([\s\S]*?)</script>"#, [.caseInsensitive])
    private static let metaTag = TRx(#"<meta\b[^>]*>"#, [.caseInsensitive])
    private static let linkTag = TRx(#"<link\b[^>]*>"#, [.caseInsensitive])
    private static let baseTag = TRx(#"<base\b[^>]*>"#, [.caseInsensitive])
    private static let svgQuery = TRx(#"(?:^|[?&])(?:format|fm|f|ext|type)=svgz?(?:&|$)"#, [.caseInsensitive])
    private static let iconPath = TRx(#"(?:^|[/_.-])(?:favicon|apple-touch-icon|mask-icon|mstile)(?:[._/-]|$)"#, [.caseInsensitive])
    private static let bannerPath = TRx(
        #"(?:instacart[_-]?share[_-]?banner|share[_-]?banner|og[_-]?default|default[_-]?og|no[_-]?image|noimage|image[_-]?not[_-]?found|placeholder|spacer\.gif|blank\.gif|1x1\.)"#,
        [.caseInsensitive]
    )
    private static let logoBase = TRx(
        #"^(?:(?:site|brand|store|company|header|footer|nav)[_-])?logo(?:[_-]?(?:dark|light|white|black|color|colour|header|footer|nav|main|default|primary|small|large|sm|md|lg|icon|mark|wordmark|\d+x\d+|\d+))*(?:\.[a-z0-9]+)?$"#,
        [.caseInsensitive]
    )

    private static let ldTypes: Set<String> = [
        "product", "individualproduct", "productgroup", "productmodel", "offer",
        "hotel", "lodgingbusiness", "resort", "motel", "inn", "bedandbreakfast", "hostel",
        "vacationrental", "accommodation",
    ]
    private static let metaImageKeys = ["og:image:secure_url", "og:image", "twitter:image", "twitter:image:src"]

    /// True when `url` is obviously not a displayable product/hotel photo (page itself, SVG, favicon, logo, share banner).
    static func isBadPhotoURL(_ url: URL, pageURL: URL? = nil) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host, host.contains(".") else { return true }
        if let pageURL, normalized(url) == normalized(pageURL) { return true }
        let path = url.path.lowercased()
        let query = url.query ?? ""
        if path.hasSuffix(".svg") || path.hasSuffix(".svgz") || svgQuery.test(query) { return true }
        if iconPath.test(path) { return true }
        if bannerPath.test(path) { return true }
        let base = path.split(separator: "/").last.map(String.init) ?? ""
        if !base.isEmpty, logoBase.test(base) { return true }
        return false
    }

    private static func normalized(_ url: URL) -> String {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return url.absoluteString.lowercased() }
        comps.fragment = nil
        comps.scheme = comps.scheme?.lowercased()
        comps.host = comps.host?.lowercased()
        while comps.path.count > 1 && comps.path.hasSuffix("/") { comps.path.removeLast() }
        if comps.path.isEmpty { comps.path = "/" }
        return comps.string ?? url.absoluteString.lowercased()
    }

    private static func absoluteHTTPS(_ raw: String, base: String) -> URL? {
        let clean = LinkPreviewParsing.decodeEntities(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !clean.isEmpty, let baseURL = URL(string: base),
              let url = URL(string: clean, relativeTo: baseURL)?.absoluteURL,
              url.scheme?.lowercased() == "https", let host = url.host, host.contains(".") else { return nil }
        return url
    }

    /// Candidate photo URLs from a product/hotel HTML page, ordered by specificity (JSON-LD -> Open Graph -> Twitter Card).
    static func photoCandidates(fromHTML html: String, pageURL: String) -> [URL] {
        guard !html.isEmpty else { return [] }
        let page = URL(string: pageURL)
        let declaredBase = baseTag.allMatches(html).first.flatMap {
            absoluteHTTPS(LinkPreviewParsing.attribute($0, "href"), base: pageURL)?.absoluteString
        }
        let base = declaredBase ?? pageURL

        var ldPrimary: [String] = []
        var ldSecondary: [String] = []
        let ns = html as NSString
        for match in scriptLD.re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            guard match.numberOfRanges > 1 else { continue }
            let raw = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, let data = raw.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            walkLD(json, primary: &ldPrimary, secondary: &ldSecondary)
        }

        var metaByKey: [String: [String]] = [:]
        for tag in metaTag.allMatches(html) {
            let prop = LinkPreviewParsing.attribute(tag, "property").lowercased()
            let name = LinkPreviewParsing.attribute(tag, "name").lowercased()
            let key = prop.isEmpty ? name : prop
            guard metaImageKeys.contains(key) else { continue }
            let content = LinkPreviewParsing.attribute(tag, "content")
            if !content.isEmpty { metaByKey[key, default: []].append(content) }
        }

        var linkImages: [String] = []
        for tag in linkTag.allMatches(html) {
            if LinkPreviewParsing.attribute(tag, "rel").lowercased() == "image_src" {
                let href = LinkPreviewParsing.attribute(tag, "href")
                if !href.isEmpty { linkImages.append(href) }
            }
        }

        var ordered = ldPrimary
        for key in metaImageKeys { ordered.append(contentsOf: metaByKey[key] ?? []) }
        ordered.append(contentsOf: linkImages)
        ordered.append(contentsOf: ldSecondary)

        var seen: Set<URL> = []
        var out: [URL] = []
        for raw in ordered {
            guard let url = absoluteHTTPS(raw, base: base), !seen.contains(url), !isBadPhotoURL(url, pageURL: page) else { continue }
            seen.insert(url)
            out.append(url)
        }
        return out
    }

    private static func collectLDURLs(_ value: Any, into out: inout [String]) {
        if let s = value as? String {
            out.append(s)
        } else if let arr = value as? [Any] {
            for item in arr { collectLDURLs(item, into: &out) }
        } else if let dict = value as? [String: Any] {
            for key in ["url", "contentUrl", "@id"] {
                if let s = dict[key] as? String {
                    out.append(s)
                    break
                }
            }
        }
    }

    private static func walkLD(_ node: Any, primary: inout [String], secondary: inout [String]) {
        if let arr = node as? [Any] {
            for item in arr { walkLD(item, primary: &primary, secondary: &secondary) }
            return
        }
        guard let dict = node as? [String: Any] else { return }
        let rawTypes: [String]
        if let t = dict["@type"] as? String {
            rawTypes = [t]
        } else if let arr = dict["@type"] as? [Any] {
            rawTypes = arr.compactMap { $0 as? String }
        } else {
            rawTypes = []
        }
        let matched = rawTypes.contains { raw in
            let last = raw.split(separator: "/").last.map(String.init) ?? raw
            return ldTypes.contains(last.lowercased())
        }
        for key in ["image", "photo", "photos"] {
            guard let value = dict[key] else { continue }
            if matched { collectLDURLs(value, into: &primary) } else { collectLDURLs(value, into: &secondary) }
        }
        for value in dict.values {
            if value is [String: Any] || value is [Any] {
                walkLD(value, primary: &primary, secondary: &secondary)
            }
        }
    }
}

/// Bounded in-memory cache of product/hotel page -> candidate photo URLs (same safety/bounds as `LinkPreviews`).
actor ProductPhotoResolver {
    static let shared = ProductPhotoResolver(fetcher: LinkPreviewFetcher())
    static let maxPages = 64
    static let maxInFlight = 3
    static let maxCooling = 128

    private enum Outcome: Sendable {
        case ok([URL])
        case refused
        case transient

        var urls: [URL] { if case .ok(let urls) = self { urls } else { [] } }
    }

    private let fetcher: LinkFetching
    private let retryAfter: Duration
    private var pages: [String: [URL]] = [:]
    private var pageOrder: [String] = []
    private var failed: Set<String> = []
    private var cooling: [String: ContinuousClock.Instant] = [:]
    private var flights: [String: Task<Outcome, Never>] = [:]
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Synchronous lookup cache of page URL -> winning loaded image URL (for instant reuse and sheet opening).
    private static let resolvedLock = Mutex<[String: URL]>([:])

    nonisolated static func rememberResolved(_ imageURL: URL, for pageURLs: [URL]) {
        guard !pageURLs.isEmpty else { return }
        resolvedLock.withLock { cache in
            if cache.count > 256 { cache.removeAll() }
            for page in pageURLs { cache[page.absoluteString] = imageURL }
        }
    }

    nonisolated static func cachedResolved(for pageURLs: [URL]) -> URL? {
        resolvedLock.withLock { cache in
            for page in pageURLs {
                if let hit = cache[page.absoluteString] { return hit }
            }
            return nil
        }
    }

    init(fetcher: LinkFetching, retryAfter: Duration = .seconds(60)) {
        self.fetcher = fetcher
        self.retryAfter = retryAfter
    }

    /// Candidate photo URLs discovered across `pageURLs` (in order, deduped, capped at 6).
    func candidates(for pageURLs: [URL]) async -> [URL] {
        var seenPages: Set<String> = []
        var seenImages: Set<URL> = []
        var out: [URL] = []
        for page in pageURLs {
            let raw = page.absoluteString
            guard !seenPages.contains(raw) else { continue }
            seenPages.insert(raw)
            if seenPages.count > 4 { break }
            let found = await candidates(for: page)
            for url in found where !seenImages.contains(url) {
                seenImages.insert(url)
                out.append(url)
                if out.count >= 6 { return out }
            }
            if !out.isEmpty { return out }
        }
        return out
    }

    func candidates(for url: URL) async -> [URL] {
        let raw = url.absoluteString
        if let hit = pages[raw] { touch(raw); return hit }
        if failed.contains(raw) { return [] }
        if let flight = flights[raw] { return await flight.value.urls }
        if let until = cooling[raw] {
            if ContinuousClock.now < until { return [] }
            cooling[raw] = nil
        }
        guard PublicHostPolicy.publicHTTPS(url) else { failed.insert(raw); return [] }
        let task = Task<Outcome, Never> { await self.load(url) }
        flights[raw] = task
        let outcome = await task.value
        flights[raw] = nil
        switch outcome {
        case .ok(let urls): store(raw, urls)
        case .refused: failed.insert(raw)
        case .transient: cool(raw)
        }
        return outcome.urls
    }

    private func load(_ url: URL) async -> Outcome {
        await enter()
        defer { leave() }
        let result: LinkFetchResult
        do { result = try await fetcher.page(url) } catch { return error is LinkFetchTransient ? .transient : .refused }
        let lower = result.type.lowercased()
        guard lower.isEmpty || lower.contains("html") || lower.contains("xml") else { return .refused }
        let html = LinkPreviewParsing.decode(result.data, contentType: result.type)
        guard !LinkPreviewParsing.isSignInArrival(result.url) else { return .refused }
        let found = ProductPhotoParsing.photoCandidates(fromHTML: html, pageURL: result.url.absoluteString)
        return found.isEmpty ? .refused : .ok(found)
    }

    private func cool(_ key: String) {
        cooling[key] = ContinuousClock.now + retryAfter
        while cooling.count > Self.maxCooling, let soonest = cooling.min(by: { $0.value < $1.value })?.key {
            cooling[soonest] = nil
        }
    }

    private func touch(_ key: String) {
        guard pageOrder.last != key else { return }
        pageOrder.removeAll { $0 == key }
        pageOrder.append(key)
    }

    private func store(_ key: String, _ value: [URL]) {
        if pages[key] == nil { pageOrder.append(key) }
        pages[key] = value
        while pageOrder.count > Self.maxPages { pages[pageOrder.removeFirst()] = nil }
    }

    private func enter() async {
        if active >= Self.maxInFlight { await withCheckedContinuation { waiters.append($0) } }
        active += 1
    }

    private func leave() {
        active -= 1
        if !waiters.isEmpty { waiters.removeFirst().resume() }
    }
}
