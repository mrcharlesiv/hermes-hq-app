// [find-plugins] Hermes' plugin catalog: the plugins Nous has reviewed, each pinned to the exact commit it checked
// (hermes-agent `plugin-catalog/`, one YAML per plugin). The docs site publishes it as one JSON list,
// /docs/api/plugins.json (~900 entries, most GitHub stars first), which is what the desktop's catalog page and
// hermes-agent.nousresearch.com/docs/plugins show. No gateway call lists it, so the app reads that file itself; a
// pick is installed with `plugins.manage install {catalog_name}`, and Hermes resolves the pin and its kill list.

import Foundation

nonisolated struct PluginCatalogEntry: Sendable, Hashable, Identifiable {
    var name: String
    var description: String
    var repo: String
    var sha: String
    var subdir: String
    /// official | verified | community
    var tier: String
    var category: PluginCatalogCategory
    var maintainer: String
    var version: String
    /// ">=0.22.3"; empty = any Hermes.
    var requiresHermes: String
    /// Empty = every system.
    var platforms: [String]
    var providesTools: [String]
    var requiresEnv: [String]
    var docsURL: URL?
    var image: URL?
    var stars: Int?
    var addedAt: Date?
    var updatedAt: Date?
    /// [marketplace] 1-based curated rank (catalog-curation.json, stamped by the extractors); nil for the rest.
    var featured: Int? = nil
    /// [marketplace] The README at the reviewed commit, when the listing has one.
    var readmeURL: URL? = nil
    var id: String { name }

    /// [marketplace] What the website's Install box shows for a terminal.
    var installCommand: String { "hermes plugins install \(name)" }

    var title: String { DisplayName.title(name) }

    /// What `plugins.manage install` takes when the gateway predates `catalog_name` (with `ref` = `sha`).
    var installIdentifier: String { subdir.isEmpty ? repo : "\(repo)#\(subdir)" }

    /// The plugin's page in the Hermes Marketplace (hermes-agent.nousresearch.com/marketplace/<name>).
    var pageURL: URL? {
        URL(string: "https://hermes-agent.nousresearch.com/marketplace/\(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name)")
    }

    var isOfficial: Bool { tier == "official" }
    var isVerified: Bool { tier == "verified" }

    /// "Official" / "Certified" (the site's word for a verified partner since 2026-11); nil for community plugins (most of the list).
    var tierWord: String? { isOfficial ? "Official" : isVerified ? "Certified" : nil }

    /// What it does, without the "Disclosure — …" paragraph most entries end with.
    var about: String { Self.split(description).about }

    /// The "Disclosure — …" paragraph: what it sends where, what it runs. Nil when the entry has none.
    var disclosure: String? { Self.split(description).disclosure }

    /// The row's line: the first sentence of `about`, with the name it often starts with dropped ("Mem0 memory
    /// provider — …" keeps its words; "Spotify: play…" loses "Spotify: ").
    var summary: String {
        var text = about
        for joiner in [": ", " — ", " - "] where text.lowercased().hasPrefix((title + joiner).lowercased()) {
            let rest = String(text.dropFirst(title.count + joiner.count))
            text = rest.prefix(1).uppercased() + rest.dropFirst()
            break
        }
        return Self.firstSentence(text)
    }

    /// "0.22.3 or newer", "0.21.3 or newer, before 0.22"; nil when any Hermes will do.
    var hermesWords: String? {
        let parts = requiresHermes.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let words: [String] = parts.compactMap { part in
            if part.hasPrefix(">=") { return "\(part.dropFirst(2).trimmingCharacters(in: .whitespaces)) or newer" }
            if part.hasPrefix("<") && !part.hasPrefix("<=") { return "before \(part.dropFirst(1).trimmingCharacters(in: .whitespaces))" }
            if part.hasPrefix("==") { return "exactly \(part.dropFirst(2).trimmingCharacters(in: .whitespaces))" }
            return part
        }
        return words.isEmpty ? nil : words.joined(separator: ", ")
    }

    /// "macOS and Linux"; nil when it runs everywhere.
    var platformWords: String? {
        let names = platforms.map { ["macos": "macOS", "linux": "Linux", "windows": "Windows"][$0.lowercased()] ?? $0 }
        switch names.count {
        case 0: return nil
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }

    // MARK: Search

    /// How well the entry answers `query` (0 = not at all): its name first, then who made it, then its words. Every
    /// word typed has to be somewhere.
    func score(_ query: String) -> Int {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return 1 }
        let name = self.name.lowercased(), title = self.title.lowercased(), maker = maintainer.lowercased()
        let text = description.lowercased()
        var total = 0
        for word in words {
            if name == word || title == word { total += 100 }
            else if name.hasPrefix(word) || title.hasPrefix(word) { total += 60 }
            else if name.contains(word) || title.contains(word) { total += 40 }
            else if maker.contains(word) { total += 20 }
            else if category.title.lowercased().contains(word) || providesTools.contains(where: { $0.lowercased().contains(word) }) { total += 12 }
            else if text.contains(word) { total += 5 }
            else { return 0 }
        }
        return total
    }

    /// The entries that answer `query`, best first; equal answers keep the list's own order (most stars first).
    static func search(_ entries: [PluginCatalogEntry], _ query: String) -> [PluginCatalogEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return entries }
        return entries.enumerated()
            .compactMap { index, entry in let s = entry.score(q); return s > 0 ? (index, s, entry) : nil }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            .map(\.2)
    }

    /// `count` entries in list order (most stars first), at most `perKind` of one kind, so a short list shows a spread.
    static func picks(_ entries: [PluginCatalogEntry], count: Int, perKind: Int = 2) -> [PluginCatalogEntry] {
        var taken: [PluginCatalogCategory: Int] = [:]
        var out: [PluginCatalogEntry] = []
        for entry in entries where out.count < count && taken[entry.category, default: 0] < perKind {
            taken[entry.category, default: 0] += 1
            out.append(entry)
        }
        return out
    }

    // MARK: Text

    static func split(_ description: String) -> (about: String, disclosure: String?) {
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        for marker in ["Disclosure — ", "Disclosure - ", "Disclosure: ", "Disclosure —"] {
            if let range = text.range(of: marker) {
                let about = text[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                let rest = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !rest.isEmpty else { return (about.isEmpty ? text : about, nil) }
                return (about.isEmpty ? rest : about, rest.prefix(1).uppercased() + rest.dropFirst())
            }
        }
        return (text, nil)
    }

    /// Up to the first ". " that ends a sentence (not "e.g. " or "v1.2"), at most about 160 characters.
    static func firstSentence(_ text: String) -> String {
        var end = text.endIndex
        var search = text.startIndex
        while let range = text.range(of: ". ", range: search..<text.endIndex) {
            let before = text[..<range.lowerBound]
            let lastWord = before.split(whereSeparator: { $0 == " " || $0 == "(" }).last.map(String.init) ?? ""
            if !["e.g", "i.e", "etc", "vs", "approx", "incl"].contains(lastWord.lowercased()), lastWord.count > 1 || lastWord.first?.isNumber == false {
                end = text.index(after: range.lowerBound)
                break
            }
            search = range.upperBound
        }
        let sentence = String(text[..<end]).trimmingCharacters(in: .whitespaces)
        guard sentence.count > 180 else { return sentence }
        let cut = sentence.prefix(170)
        let trimmed = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:—-")) + "…"
    }

    // MARK: Reading

    /// The published list (camelCase, plugins.json). Anything it can't use is skipped, never fatal.
    static func decode(_ data: Data) throws -> [PluginCatalogEntry] {
        let wire = try JSONDecoder().decode([Wire].self, from: data)
        let dates = ISO8601DateFormatter()
        return wire.compactMap { row in
            guard let name = row.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  let repo = row.repo?.trimmingCharacters(in: .whitespaces), repo.hasPrefix("https://") else { return nil }
            func https(_ raw: String?) -> URL? {
                guard let raw, let url = URL(string: raw), url.scheme == "https", url.host != nil else { return nil }
                return url
            }
            return PluginCatalogEntry(
                name: name, description: row.description ?? "", repo: repo, sha: row.sha ?? "", subdir: row.subdir ?? "",
                tier: (row.tier ?? "community").lowercased(), category: PluginCatalogCategory(rawValue: row.category ?? "") ?? .general,
                maintainer: row.maintainer ?? "", version: row.version ?? "", requiresHermes: row.requiresHermes ?? "",
                platforms: row.platforms ?? [], providesTools: row.capabilities?.providesTools ?? [],
                requiresEnv: row.capabilities?.requiresEnv ?? [], docsURL: https(row.docsUrl), image: https(row.image),
                stars: row.stars, addedAt: row.addedAt.flatMap(dates.date(from:)), updatedAt: row.updatedAt.flatMap(dates.date(from:)),
                featured: row.featured.flatMap { $0 > 0 ? $0 : nil }, readmeURL: https(row.readmeUrl))
        }
    }

    private struct Wire: Decodable {
        var name: String?
        var description: String?
        var repo: String?
        var sha: String?
        var subdir: String?
        var tier: String?
        var category: String?
        var maintainer: String?
        var version: String?
        var requiresHermes: String?
        var platforms: [String]?
        var capabilities: Capabilities?
        var docsUrl: String?
        var image: String?
        var stars: Int?
        var addedAt: String?
        var updatedAt: String?
        var featured: Int?
        var readmeUrl: String?

        struct Capabilities: Decodable {
            var providesTools: [String]?
            var requiresEnv: [String]?

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: Keys.self)
                providesTools = (try? c.decodeIfPresent([String].self, forKey: .providesTools)) ?? nil
                requiresEnv = (try? c.decodeIfPresent([String].self, forKey: .requiresEnv)) ?? nil
            }

            enum Keys: String, CodingKey { case providesTools, requiresEnv }
        }

        // Lenient: a field of the wrong type is read as missing, not a failed list.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            func text(_ key: Keys) -> String? { (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil }
            func texts(_ key: Keys) -> [String]? { (try? c.decodeIfPresent([String].self, forKey: key)) ?? nil }
            name = text(.name); description = text(.description); repo = text(.repo); sha = text(.sha); subdir = text(.subdir)
            tier = text(.tier); category = text(.category); maintainer = text(.maintainer); version = text(.version)
            requiresHermes = text(.requiresHermes); platforms = texts(.platforms); docsUrl = text(.docsUrl); image = text(.image)
            addedAt = text(.addedAt); updatedAt = text(.updatedAt); readmeUrl = text(.readmeUrl)
            featured = (try? c.decodeIfPresent(Int.self, forKey: .featured)) ?? nil
            stars = (try? c.decodeIfPresent(Int.self, forKey: .stars)) ?? nil
            capabilities = (try? c.decodeIfPresent(Capabilities.self, forKey: .capabilities)) ?? nil
        }

        enum Keys: String, CodingKey {
            case name, description, repo, sha, subdir, tier, category, maintainer, version, requiresHermes, platforms, capabilities
            case docsUrl, image, stars, addedAt, updatedAt, featured, readmeUrl
        }
    }
}

/// The catalog's shelves (hermes-agent `CATALOG_CATEGORIES`, apps/shared catalog-browse.ts), in the order this app
/// shows them: what changes a bot first, the desktop's own panes last, since they show only in Hermes on a computer.
nonisolated enum PluginCatalogCategory: String, Sendable, Hashable, CaseIterable, Identifiable {
    case memory, tools, models, web, voice, platform, automation, general, desktop
    var id: String { rawValue }

    var title: String {
        switch self {
        case .memory: "Memory"
        case .tools: "Tools"
        case .models: "Models"
        case .web: "Web & Browser"
        case .voice: "Voice"
        case .platform: "Messaging"
        case .automation: "Automation"
        case .general: "General"
        case .desktop: "Hermes Desktop"
        }
    }

    var blurb: String {
        switch self {
        case .memory: "Long-term memory and context for your bots."
        case .tools: "New tools your bots can use."
        case .models: "More model and inference providers."
        case .web: "Search, reading pages and browser control."
        case .voice: "Speech, voices and live audio."
        case .platform: "Reach your bots from more chat apps."
        case .automation: "Hooks, wake-ups and work that runs on its own."
        case .general: "Plugins that do a bit of everything."
        case .desktop: "Panes and views for the Hermes desktop app. They show only in Hermes on a computer, not in Hermes HQ."
        }
    }

    var symbol: String {
        switch self {
        case .memory: "brain"
        case .tools: "wrench.and.screwdriver"
        case .models: "cpu"
        case .web: "globe"
        case .voice: "waveform"
        case .platform: "bubble.left.and.bubble.right"
        case .automation: "clock.arrow.2.circlepath"
        case .general: "shippingbox"
        case .desktop: "macwindow"
        }
    }
}

extension Int {
    /// 68262 → "68k", 1799 → "1.8k", 412 → "412".
    nonisolated var starWords: String {
        if self >= 10_000 { return "\(self / 1000)k" }
        if self >= 1000 {
            let tenths = (self + 50) / 100
            return tenths % 10 == 0 ? "\(tenths / 10)k" : "\(tenths / 10).\(tenths % 10)k"
        }
        return "\(self)"
    }
}
