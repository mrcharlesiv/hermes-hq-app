// [find-plugins] The Hermes plugin catalog as the docs site publishes it (`PluginCatalogEntry`), read once and kept on
// disk: a visit shows the kept copy at once and reads a fresh one when it is over six hours old (Hermes' own live
// catalog refreshes on the same clock). It is the same for every gateway and bot, so one copy serves them all.

import Foundation

@MainActor @Observable
final class PluginCatalogStore {
    static let shared = PluginCatalogStore()

    static let productionURL = URL(string: "https://hermes-agent.nousresearch.com/docs/api/plugins.json")!
    static let freshFor: TimeInterval = 6 * 60 * 60

    /// Nil until a copy (kept or fresh) has been read.
    private(set) var entries: [PluginCatalogEntry]?
    private(set) var loading = false
    /// Why the last read failed, shown only while there is no copy at all.
    private(set) var error: String?
    @ObservationIgnored private var readAt: Date?
    @ObservationIgnored private var running: Task<Void, Never>?

    private var url: URL {
        #if DEBUG
        // UI tests and tours point it at a stand-in (`-HQDebugPluginCatalogURL http://127.0.0.1:…/plugins.json`).
        if let raw = UserDefaults.standard.string(forKey: "HQDebugPluginCatalogURL"), let url = URL(string: raw) { return url }
        #endif
        return Self.productionURL
    }

    private var file: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("plugin-catalog.json")
    }

    /// Reads the kept copy, then the published one when the copy is missing or stale (or `force`). Concurrent callers
    /// share one read.
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
            let kept = await Task.detached(priority: .userInitiated) { () -> ([PluginCatalogEntry], Date)? in
                guard let data = try? Data(contentsOf: file),
                      let date = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date,
                      let list = try? PluginCatalogEntry.decode(data), !list.isEmpty else { return nil }
                return (list, date)
            }.value
            if let kept {
                entries = kept.0
                keptAt = kept.1
                readAt = kept.1
                AppLog.trace("plugins", "catalog: kept copy \(kept.0.count) plugin(s), \(Int(Date().timeIntervalSince(kept.1) / 60)) min old")
            }
        }
        if !force, let keptAt, Date().timeIntervalSince(keptAt) < Self.freshFor { return }
        loading = true
        defer { loading = false }
        let url = self.url
        do {
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "The plugin list answered \((response as? HTTPURLResponse)?.statusCode ?? 0)."])
            }
            guard data.count < 16 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
            let list = try await Task.detached(priority: .userInitiated) { try PluginCatalogEntry.decode(data) }.value
            guard !list.isEmpty else { throw URLError(.cannotParseResponse) }
            entries = list
            readAt = Date()
            error = nil
            if let file { try? data.write(to: file, options: .atomic) }
            AppLog.trace("plugins", "catalog: read \(list.count) plugin(s), \(data.count / 1024) KB in \(AppLog.ms(since: start)) ms")
        } catch {
            if entries == nil { self.error = "Couldn’t load the Hermes plugin list. Check your internet connection and try again." }
            AppLog.note("plugins", "catalog read failed after \(AppLog.ms(since: start)) ms: \(error.localizedDescription)")
        }
    }
}
