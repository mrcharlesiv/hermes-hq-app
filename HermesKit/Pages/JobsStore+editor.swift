// [jobs] The Jobs store's editor calls (docs/spec/3x-jobs.md §3): create, edit, create from a blueprint, and the
// reads the editor makes (delivery targets, model choices, blueprints). All REST, each naming the job's own profile.
// A write waits 15 s (the pages' slow-answer rule); on success the list is read again.

import Foundation

nonisolated struct JobModelChoice: Hashable, Sendable {
    var provider: String
    var model: String
}

/// A provider row of `GET /api/model/options?explicit_only=1` the editor can offer: signed in, with models.
nonisolated struct JobModelProvider: Hashable, Sendable, Identifiable {
    var slug: String
    var name: String
    var models: [String]
    var id: String { slug }

    /// Providers with `authenticated !== false` and at least one model (vendor app/cron/index.tsx:1180-1182).
    static func list(_ json: JSONValue) -> [JobModelProvider] {
        var seen = Set<String>()
        return (json["providers"]?.array ?? []).compactMap { row -> JobModelProvider? in
            guard let slug = row["slug"]?.pgString?.pgTrim, !slug.isEmpty, seen.insert(slug).inserted else { return nil }
            if row["authenticated"]?.bool == false { return nil }
            var models = Set<String>()
            let listed = (row["models"]?.array ?? []).compactMap { $0.string?.pgTrim }.filter { !$0.isEmpty && models.insert($0).inserted }
            guard !listed.isEmpty else { return nil }
            let name = row["name"]?.pgString?.pgTrim ?? ""
            return JobModelProvider(slug: slug, name: name.isEmpty ? slug : name, models: listed)
        }
    }
}

/// How an editor write ended.
nonisolated enum JobEditResult: Equatable, Sendable {
    case done(CronJob?)
    case refused                                   // read-only gateway
    case failed(reason: String, status: Int?, slow: Bool)
}

extension JobsStore {
    nonisolated static let writeTimeout: TimeInterval = 15
    nonisolated static let slowAnswer = "The gateway is taking a while. Check the list before trying again."
    nonisolated static let noReason = "The gateway did not say why."

    /// The profile the page's blueprints are read for: the scope's bot, the default bot under All.
    var listProfile: String { scope == "all" ? "default" : scope }

    /// The page's blueprints (empty when the gateway has none, or the read failed).
    var blueprints: [Blueprint] { blueprintsByProfile[listProfile] ?? [] }

    private func profileQuery(_ profile: String) -> [URLQueryItem] { [URLQueryItem(name: "profile", value: profile)] }

    /// A gateway refusal as the editor shows it: the first line of `detail`, at most 200 characters; a refusal
    /// without words says so; a request that never arrived says the app's own can't-reach words.
    nonisolated static func editReason(_ error: Error) -> String {
        if PagesREST.isSlowAnswer(error) { return slowAnswer }
        guard let http = error as? HTTPError else { return PagesREST.reason(error) }
        let detail = PagesREST.detail(http) ?? ""
        let line = detail.split(whereSeparator: \.isNewline).first.map(String.init)?.pgTrim ?? ""
        if line.isEmpty { return noReason }
        return line.count > 200 ? String(line.prefix(199)).pgTrim + "…" : line
    }

    private func editFailure(_ error: Error) -> JobEditResult {
        .failed(reason: Self.editReason(error), status: PagesREST.status(error), slow: PagesREST.isSlowAnswer(error))
    }

    /// `POST /api/cron/jobs?profile=`.
    func create(body: JSONValue, profile: String) async -> JobEditResult {
        if readOnlyGateway {
            AppLog.note("config", "job create refused: gateway is read-only")
            return .refused
        }
        let start = ContinuousClock.now
        do {
            let json = try await PagesREST.json(client, "POST", Self.listPath, query: profileQuery(profile), json: body, timeout: Self.writeTimeout)
            var made = CronJob(json: json)
            if made != nil, made?.profile == nil { made?.profile = profile }
            await refresh()
            AppLog.trace("config", "job create ok in \(AppLog.ms(since: start)) ms: \(AppLog.tag(made?.id))")
            return .done(made)
        } catch {
            if PagesREST.isSlowAnswer(error) { Task { await refresh() } }   // it may have landed: show the truth
            let result = editFailure(error)
            AppLog.note("config", "job create failed after \(AppLog.ms(since: start)) ms: \(result)")
            return result
        }
    }

    /// `PUT /api/cron/jobs/<id>?profile=<owner>` with `{"updates": …}` (only the changed keys, D-J1).
    func update(_ job: CronJob, updates: JSONValue) async -> JobEditResult {
        if readOnlyGateway {
            AppLog.note("config", "job update \(AppLog.tag(job.id)) refused: gateway is read-only")
            return .refused
        }
        let start = ContinuousClock.now
        do {
            let json = try await PagesREST.json(client, "PUT", CronRunOnce.jobPath(job.id), query: profileQuery(job.owner),
                                                json: ["updates": updates], timeout: Self.writeTimeout)
            var fresh = CronJob(json: json)
            if fresh != nil, fresh?.profile == nil { fresh?.profile = job.profile }
            supersedeListRead()
            if let fresh { replace(fresh) }
            Task { await refresh() }
            AppLog.trace("config", "job update \(AppLog.tag(job.id)) ok in \(AppLog.ms(since: start)) ms")
            return .done(fresh)
        } catch {
            if PagesREST.status(error) == 404 {
                // Deleted elsewhere: the row goes, the open job page pops.
                AppLog.note("config", "job update \(AppLog.tag(job.id)): 404, already deleted elsewhere")
                supersedeListRead()
                remove(job.key)
                onJobRemoved?(job.key)
                Task { await refresh() }
                return .failed(reason: "This job no longer exists.", status: 404, slow: false)
            }
            if PagesREST.isSlowAnswer(error) { Task { await refresh() } }
            let result = editFailure(error)
            AppLog.note("config", "job update \(AppLog.tag(job.id)) failed after \(AppLog.ms(since: start)) ms: \(result)")
            return result
        }
    }

    /// `POST /api/cron/blueprints/instantiate?profile=`.
    func instantiate(blueprint key: String, values: [String: String], profile: String) async -> JobEditResult {
        if readOnlyGateway {
            AppLog.note("config", "job instantiate refused: gateway is read-only")
            return .refused
        }
        let start = ContinuousClock.now
        do {
            let body: JSONValue = ["blueprint": .string(key), "values": .object(values.mapValues { .string($0) })]
            let json = try await PagesREST.json(client, "POST", "/api/cron/blueprints/instantiate", query: profileQuery(profile),
                                                json: body, timeout: Self.writeTimeout)
            var made = CronJob(json: json)
            if made != nil, made?.profile == nil { made?.profile = profile }
            await refresh()
            AppLog.trace("config", "job instantiate ok in \(AppLog.ms(since: start)) ms: \(AppLog.tag(made?.id))")
            return .done(made)
        } catch {
            if PagesREST.status(error) == 404 {
                AppLog.note("config", "job instantiate: blueprint no longer available, reloading blueprints")
                Task { await loadBlueprints(profile: profile) }
                return .failed(reason: "This blueprint is no longer available.", status: 404, slow: false)
            }
            if PagesREST.isSlowAnswer(error) { Task { await refresh() } }
            let result = editFailure(error)
            AppLog.note("config", "job instantiate failed after \(AppLog.ms(since: start)) ms: \(result)")
            return result
        }
    }

    /// `GET /api/cron/delivery-targets?profile=`.
    func deliveryTargets(profile: String) async throws -> [DeliveryTarget] {
        DeliveryTarget.list(try await PagesREST.json(client, "GET", "/api/cron/delivery-targets", query: profileQuery(profile)))
    }

    /// `GET /api/model/options?explicit_only=1&profile=`.
    func modelProviders(profile: String) async throws -> [JobModelProvider] {
        JobModelProvider.list(try await PagesREST.json(client, "GET", "/api/model/options",
                                                       query: [URLQueryItem(name: "explicit_only", value: "1")] + profileQuery(profile)))
    }

    // MARK: Blueprints

    private func blueprintsURL(_ profile: String) -> URL? {
        directory?.appending(path: "blueprints-\(PagesCache.safeName(profile)).json")
    }

    func paintBlueprintsFromCache() {
        let profile = listProfile
        guard blueprintsByProfile[profile] == nil, let url = blueprintsURL(profile),
              let cached = PagesCache.read(PagesCached<[Blueprint]>.self, url) else { return }
        blueprintsByProfile[profile] = cached.value
    }

    /// With the list's reads: at most one catalog read a minute per profile.
    func loadBlueprintsIfStale(profile: String) async {
        if let at = blueprintsReadAt[profile], Date().timeIntervalSince(at) < 60 { return }
        await loadBlueprints(profile: profile)
    }

    /// `GET /api/cron/blueprints?profile=`. A failed read keeps what was known (nothing, the first time).
    @discardableResult
    func loadBlueprints(profile: String) async -> Bool {
        blueprintsReadAt[profile] = Date()
        do {
            let list = Blueprint.list(try await PagesREST.json(client, "GET", "/api/cron/blueprints", query: profileQuery(profile)))
            if blueprintsByProfile[profile] != list {
                blueprintsByProfile[profile] = list
                onChange?()
                AppLog.trace("config", "blueprints for \(profile): \(list.count), changed")
            }
            if let url = blueprintsURL(profile) { PagesCache.write(PagesCached(at: Date().timeIntervalSince1970 * 1000, value: list), to: url) }
            return true
        } catch {
            AppLog.note("config", "blueprints for \(profile) load failed: \(PagesREST.reason(error))")
            return false
        }
    }
}

// MARK: - [jobs] D-J21: the list cache keeps the longest prefix that fits

extension PagesCache {
    /// How many jobs are tried, longest first (docs/spec/3x-jobs.md §11.2 D-J21).
    nonisolated static let jobPrefixes = [500, 250, 125, 62, 31]

    /// The longest of the first 500 / 250 / 125 / 62 / 31 jobs whose saved JSON is at most `maxBytes`; nil when none fits.
    nonisolated static func fittingJobs(_ list: [CronJob], at: Double, maxBytes: Int) -> Data? {
        var tried = Set<Int>()
        for count in jobPrefixes {
            let kept = min(count, list.count)
            guard tried.insert(kept).inserted else { continue }
            if let data = try? JSONEncoder().encode(PagesCached(at: at, value: Array(list.prefix(kept)))), data.count <= maxBytes {
                return data
            }
        }
        return nil
    }

    /// Saves that prefix off the main thread; when nothing fits, the older copy is removed ([offline] §6.10).
    nonisolated static func writeJobs(_ list: [CronJob], at: Double, to url: URL, maxBytes: Int) {
        let head = Array(list.prefix(jobPrefixes[0]))
        writer.async {
            guard let data = fittingJobs(head, at: at, maxBytes: maxBytes) else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: [.atomic])
        }
    }
}
