// [marketplace] The Marketplace's skills (`MarketSkill`), read from the Marketplace page and kept on disk as the
// app's own small list: a visit shows the kept copy at once and reads a fresh one when it is over six hours old, as the
// plugin list does (`PluginCatalogStore`). The same for every gateway and bot.

import Foundation

@MainActor @Observable
final class SkillCatalogStore {
    static let shared = SkillCatalogStore()

    static let pageURL = URL(string: "https://hermes-agent.nousresearch.com/marketplace?kind=skills")!
    static let fullURL = URL(string: "https://hermes-agent.nousresearch.com/docs/api/skills.json")!
    static let freshFor: TimeInterval = 6 * 60 * 60

    private(set) var entries: [MarketSkill]?
    private(set) var loading = false
    private(set) var error: String?
    @ObservationIgnored private var readAt: Date?
    @ObservationIgnored private var running: Task<Void, Never>?

    private var url: URL {
        #if DEBUG
        // UI tests and tours point it at a stand-in page (`-HQDebugSkillCatalogURL http://127.0.0.1:…/skills.html`).
        if let raw = UserDefaults.standard.string(forKey: "HQDebugSkillCatalogURL"), let url = URL(string: raw) { return url }
        #endif
        return Self.pageURL
    }

    private var file: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("skill-catalog.json")
    }

    func load(force: Bool = false) async {
        if let running { await running.value; if !force { return } }
        if !force, let readAt, Date().timeIntervalSince(readAt) < Self.freshFor, entries != nil { return }
        let task = Task { await read(force: force) }
        running = task
        await task.value
        running = nil
    }

    private func read(force: Bool) async {
        let start = ContinuousClock.now
        var keptAt: Date?
        if entries == nil, let file {
            let kept = await Task.detached(priority: .userInitiated) { () -> ([MarketSkill], Date)? in
                guard let data = try? Data(contentsOf: file),
                      let date = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date,
                      let list = try? JSONDecoder().decode([MarketSkill].self, from: data), !list.isEmpty else { return nil }
                return (list, date)
            }.value
            if let kept {
                entries = kept.0
                keptAt = kept.1
                readAt = kept.1
                AppLog.trace("plugins", "skill catalog: kept copy \(kept.0.count) skill(s), \(Int(Date().timeIntervalSince(kept.1) / 60)) min old")
            }
        }
        if !force, let keptAt, Date().timeIntervalSince(keptAt) < Self.freshFor { return }
        loading = true
        defer { loading = false }
        do {
            var list = try await fetch(url, limit: 8 * 1024 * 1024) { data in
                MarketSkill.parsePage(String(decoding: data, as: UTF8.self))
            }
            if list.count < 20 {
                // The page changed shape: the published list, kept to the same sources.
                AppLog.note("plugins", "skill catalog: page had \(list.count) skill(s), reading skills.json")
                list = try await fetch(Self.fullURL, limit: 96 * 1024 * 1024) { try MarketSkill.decodeFull($0) }
            }
            guard !list.isEmpty else { throw URLError(.cannotParseResponse) }
            entries = list
            readAt = Date()
            error = nil
            if let file, let data = try? JSONEncoder().encode(list) { try? data.write(to: file, options: .atomic) }
            AppLog.trace("plugins", "skill catalog: read \(list.count) skill(s) in \(AppLog.ms(since: start)) ms")
        } catch {
            if entries == nil { self.error = "Couldn’t load the Marketplace’s skills. Check your internet connection and try again." }
            AppLog.note("plugins", "skill catalog read failed after \(AppLog.ms(since: start)) ms: \(error.localizedDescription)")
        }
    }

    private func fetch(_ url: URL, limit: Int, parse: @escaping @Sendable (Data) throws -> [MarketSkill]) async throws -> [MarketSkill] {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "The skill list answered \((response as? HTTPURLResponse)?.statusCode ?? 0)."])
        }
        guard data.count < limit else { throw URLError(.dataLengthExceedsMaximum) }
        return try await Task.detached(priority: .userInitiated) { try parse(data) }.value
    }
}
