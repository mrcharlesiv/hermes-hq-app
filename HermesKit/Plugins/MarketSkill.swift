// [marketplace] The Hermes Marketplace's skills (hermes-agent.nousresearch.com/marketplace?kind=skills): the 711 or so
// skills it lists from six sources, Hermes' own (built-in and optional) and NVIDIA, OpenAI, Hugging Face and Anthropic,
// not the hundred thousand community skills the Skills Hub searches. The site carries the whole list in its page
// (~340 KB compressed); the full published skills.json is ~65 MB (11 MB compressed), too much for a phone, so the app
// reads the page and keeps only the entries, and falls back to skills.json only when the page has none.
// A pick installs with `POST /api/skills/hub/install {identifier}`, the identifier the site's Install button sends in
// `hermes://skill/install?identifier=…` (apps/shared/src/catalog-install.ts).

import Foundation

nonisolated struct MarketSkill: Sendable, Hashable, Identifiable, Codable {
    var name: String
    var description: String
    var author: String
    /// "security"; "other" when the source gave none.
    var category: String
    /// "Security"
    var categoryLabel: String
    var tags: [String]
    /// built-in | optional | NVIDIA | OpenAI | HuggingFace | Anthropic (as the site writes them)
    var source: String
    /// The site's page: /marketplace/skills/<slug>.
    var slug: String
    /// What `POST /api/skills/hub/install` takes: "official/security/1password", "NVIDIA/skills/skills/…".
    var installIdentifier: String
    var id: String { installIdentifier }

    /// The sources the Marketplace lists, in the order its Sources menu shows them.
    static let sources = ["built-in", "optional", "NVIDIA", "OpenAI", "HuggingFace", "Anthropic"]

    /// Bundled with Hermes or published by Nous (apps/shared `OFFICIAL_SKILL_SOURCES`).
    var isOfficial: Bool { ["built-in", "bundled", "optional", "official"].contains(source) }
    /// Ships inside Hermes: every bot has it unless it was removed.
    var isBuiltIn: Bool { source == "built-in" || source == "bundled" }

    /// "Hermes", "Nous", "NVIDIA", "OpenAI", "Hugging Face", "Anthropic".
    var sourceWord: String { Self.sourceWord(source) }

    static func sourceWord(_ source: String) -> String {
        switch source {
        case "built-in", "bundled": "Built into Hermes"
        case "optional", "official": "Nous"
        case "HuggingFace": "Hugging Face"
        default: source
        }
    }

    /// The badge a card wears: "Official" for Hermes' own, else who published it.
    var badge: String { isOfficial ? "Official" : sourceWord }

    var title: String { name }

    var pageURL: URL? {
        URL(string: "https://hermes-agent.nousresearch.com/marketplace/skills/" + slug.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/"))
    }

    /// What the site shows for a terminal.
    var installCommand: String { "hermes skills install \(installIdentifier)" }

    /// The skill's SKILL.md on GitHub, read from the install identifier: `official/<cat>/<name>` is Hermes'
    /// optional-skills folder; anything else is `<owner>/<repo>/<path>`.
    var skillFileURL: URL? {
        let parts = installIdentifier.split(separator: "/").map(String.init)
        let owner: String, repo: String, path: [String]
        if parts.first == "official", parts.count >= 3 {
            (owner, repo, path) = ("NousResearch", "hermes-agent", ["optional-skills"] + parts.dropFirst())
        } else if parts.count >= 3 {
            (owner, repo, path) = (parts[0], parts[1], Array(parts.dropFirst(2)))
        } else {
            return nil
        }
        let encoded = (path + ["SKILL.md"]).map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
        return URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/HEAD/" + encoded.joined(separator: "/"))
    }

    // MARK: Search

    /// Name first, then tags and who made it, then its words; every word typed has to be somewhere.
    func score(_ query: String) -> Int {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return 1 }
        let name = self.name.lowercased(), maker = author.lowercased(), from = sourceWord.lowercased()
        let tags = self.tags.map { $0.lowercased() }
        let text = description.lowercased()
        var total = 0
        for word in words {
            if name == word { total += 100 }
            else if name.hasPrefix(word) { total += 60 }
            else if name.contains(word) { total += 40 }
            else if tags.contains(word) { total += 25 }
            else if maker.contains(word) || from.contains(word) { total += 20 }
            else if categoryLabel.lowercased().contains(word) || tags.contains(where: { $0.contains(word) }) { total += 12 }
            else if text.contains(word) { total += 5 }
            else { return 0 }
        }
        return total
    }

    static func search(_ entries: [MarketSkill], _ query: String) -> [MarketSkill] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return entries }
        return entries.enumerated()
            .compactMap { index, entry in let s = entry.score(q); return s > 0 ? (index, s, entry) : nil }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            .map(\.2)
    }

    // MARK: Reading

    /// The entries in the Marketplace page's own data: each skill is one flat object ending in `installIdentifier`.
    /// The page streams its data as `self.__next_f.push([1,"…"])` string chunks; they are joined and unescaped first.
    static func parsePage(_ html: String) -> [MarketSkill] {
        var payload = ""
        let opener = "self.__next_f.push([1,\""
        var search = html.startIndex
        while let start = html.range(of: opener, range: search..<html.endIndex) {
            guard let end = html.range(of: "\"])</script>", range: start.upperBound..<html.endIndex) else { break }
            let literal = "\"" + html[start.upperBound..<end.lowerBound] + "\""
            if let data = literal.data(using: .utf8), let chunk = try? JSONDecoder().decode(String.self, from: data) {
                payload += chunk
            }
            search = end.upperBound
        }
        return parseObjects(payload.isEmpty ? html : payload)
    }

    /// Every `{"name":…,"installIdentifier":"…"}` object in `text` (flat: tags are an array of strings).
    static func parseObjects(_ text: String) -> [MarketSkill] {
        let pattern = #"\{"name":"(?:[^"\\]|\\.)*"[^{}]*?"installIdentifier":"(?:[^"\\]|\\.)*"\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var seen = Set<String>()
        var out: [MarketSkill] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let data = ns.substring(with: match.range).data(using: .utf8),
                  let row = try? JSONDecoder().decode(Wire.self, from: data), let entry = row.entry,
                  seen.insert(entry.installIdentifier).inserted else { continue }
            out.append(entry)
        }
        return out
    }

    /// The published skills.json, kept to the Marketplace's sources (the fallback when the page reads empty).
    static func decodeFull(_ data: Data) throws -> [MarketSkill] {
        let rows = try JSONDecoder().decode([Wire].self, from: data)
        var seen = Set<String>()
        return rows.compactMap { row in
            guard let entry = row.entry, sources.contains(entry.source), seen.insert(entry.installIdentifier).inserted else { return nil }
            return entry
        }
    }

    private struct Wire: Decodable {
        var name: String?
        var description: String?
        var author: String?
        var category: String?
        var categoryLabel: String?
        var tags: [String]?
        var source: String?
        var slug: String?
        var docsPath: String?
        var installIdentifier: String?
        var identifier: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            func text(_ key: Keys) -> String? { (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil }
            name = text(.name); description = text(.description); author = text(.author); category = text(.category)
            categoryLabel = text(.categoryLabel); source = text(.source); slug = text(.slug); docsPath = text(.docsPath)
            installIdentifier = text(.installIdentifier); identifier = text(.identifier)
            tags = (try? c.decodeIfPresent([String].self, forKey: .tags)) ?? nil
        }

        enum Keys: String, CodingKey {
            case name, description, author, category, categoryLabel, tags, source, slug, docsPath, installIdentifier, identifier
        }

        var entry: MarketSkill? {
            guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  let install = (installIdentifier ?? identifier)?.trimmingCharacters(in: .whitespaces), !install.isEmpty,
                  let source, !source.isEmpty else { return nil }
            let category = (self.category ?? "").isEmpty ? "other" : self.category!
            let label = (categoryLabel ?? "").isEmpty ? category.capitalized : categoryLabel!
            return MarketSkill(name: name, description: description ?? "", author: author ?? "", category: category,
                                     categoryLabel: label, tags: tags ?? [], source: source,
                                     slug: slug ?? docsPath ?? install, installIdentifier: install)
        }
    }
}
