// The gateway's config record as every Settings config page edits it (`config-settings.tsx` ConfigSettingsInner): read
// once with its schema and defaults, edited as a local draft, autosaved 550 ms after the last change as a sparse patch
// (`diffConfig` against the record as it was read, so a key another device or the CLI changed while the page was open is
// never sent back stale; `PUT /api/config` deep-merges), saves one at a time in order. A refused save puts the saved
// value back on the page and keeps the change for Try Again (`SettingsSaveFailure`, D-04b). One store per signed-in
// gateway, shared by all pages, so a change on one page shows on every other.

import Foundation
import Observation

@MainActor @Observable
final class GatewayConfigStore {
    enum Phase: Equatable { case idle, loading, loaded, failed(String) }

    /// A save that didn't land: the words, the gateway's own detail, and the change to send again.
    struct SaveFailure: Equatable {
        var text: String
        var detail: String?
        var patch: JSONValue
    }

    private(set) var phase: Phase = .idle
    /// The record as the pages show it (the draft: saved values plus edits not yet saved).
    private(set) var config: JSONValue?
    private(set) var schema: [String: ConfigFieldSchema] = [:]
    private(set) var defaults: JSONValue?
    private(set) var failure: SaveFailure?
    /// Saves sent and not yet answered (pages show "Saving…").
    private(set) var saving = 0
    /// Bumped when an import or reset replaced the record: pages rebuild their fields.
    private(set) var epoch = 0

    @ObservationIgnored let api: GatewaySettingsAPI
    @ObservationIgnored let readOnly: Bool
    /// The record as last read or saved: what a change is diffed against.
    @ObservationIgnored private(set) var baseline: JSONValue = .object([:])
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var chain: Task<Void, Never>?
    @ObservationIgnored private var loadedAt: Date?
    /// The read on its way, which a second load waits for instead of asking again.
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    /// Edits not yet saved (keys).
    @ObservationIgnored private var dirty = false
    /// The autosave delay (tests shorten it).
    @ObservationIgnored var debounce: Duration = .milliseconds(550)
    /// Called after a save lands (e.g. the launch-restore reader's cache).
    @ObservationIgnored var onSaved: ((JSONValue) -> Void)?

    init(api: GatewaySettingsAPI, readOnly: Bool = false) {
        self.api = api
        self.readOnly = readOnly
    }

    /// [offline] §6.2: the wait before a failed read is asked once more (tests shorten it).
    @ObservationIgnored var retryDelay: Duration = QueryRetry.delay

    // MARK: Reading

    /// Reads the record, schema and defaults. A page opened again re-reads after 30 s (never over unsaved edits).
    func load(force: Bool = false) async {
        // [perf] The root, the section and the page each ask on a push: a load already on its way answers them all,
        // instead of three reads of the same record (a stale reload keeps phase .loaded, so the guard below misses it).
        if let inFlight { await inFlight.value; return }
        if phase == .loading { return }
        if !force, phase == .loaded, let loadedAt, Date().timeIntervalSince(loadedAt) < 30 { return }
        if dirty || saving > 0 { return }
        await read()
    }

    private func read() async {
        let task = Task { await self.performLoad() }
        inFlight = task
        await task.value
        if inFlight == task { inFlight = nil }
    }

    private func performLoad() async {
        if config == nil { phase = .loading }
        do {
            // [offline] §6.2: one quick retry, none after a timeout or while the gateway cannot be reached.
            let api = self.api
            // [perf] Defaults are a nicety (Reset to Default): a gateway without them still shows the page. Asked
            // alongside the record so the page waits for the slower of the two, not both in a row.
            async let defaultsRead: JSONValue? = { try? await api.defaults() }()
            let (loaded, schema) = try await QueryRetry.read(delay: retryDelay) {
                async let record = api.config()
                async let fields = api.schema()
                return try await (record, fields)
            }
            let defaults = await defaultsRead
            guard !dirty, saving == 0 else { return }
            self.schema = schema
            self.defaults = defaults ?? self.defaults
            baseline = loaded
            config = loaded
            loadedAt = Date()
            phase = .loaded
        } catch is CancellationError {
            if config == nil { phase = .idle }
        } catch {
            AppLog.note("settings", "config load failed: \(type(of: error))")
            if config == nil { phase = .failed(SettingsErrorText.load(error)) } else { phase = .loaded }
        }
    }

    func value(_ key: String) -> JSONValue? { config.flatMap { ConfigPath.get($0, key) } }

    func fields(_ page: ConfigPage) -> [ConfigFieldModel] {
        guard let config else { return [] }
        return ConfigRenderer.fields(page: page, schema: schema, config: config, defaults: defaults)
    }

    func field(_ key: String) -> ConfigFieldModel? {
        guard let config else { return nil }
        let value = ConfigPath.get(config, key)
        guard let schema = schema[key] ?? value.map(ConfigFieldSchema.inferred(from:)) else { return nil }
        return ConfigRenderer.model(key: key, schema: schema, value: value, config: config, defaults: defaults)
    }

    // MARK: Editing

    /// One field changed: shown at once, saved 550 ms after the last change.
    func set(_ key: String, _ value: JSONValue) {
        guard let current = config else { return }
        config = ConfigPath.set(current, key, value)
        dirty = true
        failure = nil
        schedule()
    }

    /// Back to the gateway's default for this key.
    func reset(_ key: String) {
        guard let value = defaults.flatMap({ ConfigPath.get($0, key) }) else { return }
        set(key, value)
    }

    /// Sends what's waiting now (a page going away).
    func flush() {
        guard pending != nil else { return }
        pending?.cancel()
        pending = nil
        enqueueSave()
    }

    private func schedule() {
        pending?.cancel()
        let delay = debounce
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            self.enqueueSave()
        }
    }

    /// Chained after the save before it, so an older answer can never land after a newer one.
    private func enqueueSave() {
        let previous = chain
        chain = Task { [weak self] in
            await previous?.value
            await self?.saveDraft()
        }
    }

    private func saveDraft() async {
        guard let draft = config else { return }
        let patch = ConfigPath.diff(baseline, draft)
        dirty = pending != nil
        guard !(patch.object ?? [:]).isEmpty else { return }
        await send(patch, draft: draft)
    }

    private func send(_ patch: JSONValue, draft: JSONValue) async {
        if readOnly {
            fail(patch, text: BotWriteError.readOnlyReason, detail: nil)
            return
        }
        saving += 1
        defer { saving -= 1 }
        do {
            try await api.saveConfig(patch)
            baseline = ConfigPath.merge(baseline, patch)
            AppLog.note("settings", "config saved (\((patch.object ?? [:]).count) group\((patch.object ?? [:]).count == 1 ? "" : "s"))")
            onSaved?(baseline)
        } catch {
            AppLog.note("settings", "config save failed: \(type(of: error))")
            let text = SettingsErrorText.save(error)
            let raw = (error as? HTTPError).map { "HTTP \($0.status)" } ?? (error as? RPCError)?.message
            fail(patch, text: text, detail: raw == text ? nil : raw)
        }
    }

    /// The page shows the saved value again; Try Again sends the same change.
    private func fail(_ patch: JSONValue, text: String, detail: String?) {
        failure = SaveFailure(text: text, detail: detail, patch: patch)
        if !dirty { config = baseline }
    }

    func retry() {
        guard let failure, let current = config else { return }
        self.failure = nil
        config = ConfigPath.merge(current, failure.patch)
        dirty = true
        enqueueSave()
    }

    func dismissFailure() { failure = nil }

    // MARK: Whole-record changes (Import, Reset)

    /// Writes `patch` now (not debounced), then reads the record again so every page shows what was saved.
    func write(_ patch: JSONValue) async throws {
        if readOnly { throw BotWriteError(title: "Couldn’t Save Settings", reason: BotWriteError.readOnlyReason) }
        flush()
        await chain?.value
        guard !(patch.object ?? [:]).isEmpty else { return }
        saving += 1
        do {
            try await api.saveConfig(patch)
        } catch {
            saving -= 1
            throw error
        }
        saving -= 1
        AppLog.note("settings", "config replaced")
        dirty = false
        // [13-2] The read used to go through `load`, which returns early while a save is out (this one counted itself),
        // so the pages kept the old values and the old baseline until a reload 30 s later. What was written shows now;
        // the read brings what the gateway made of it (a read sent before the write may hold the old record: it lands
        // first, then this one).
        baseline = ConfigPath.merge(baseline, patch)
        if let config { self.config = ConfigPath.merge(config, patch) }
        if let inFlight { await inFlight.value }
        if !dirty, saving == 0 { await read() }
        epoch += 1
        if let config { onSaved?(config) }
    }

    /// The record as the gateway has it now (Export, Import), read fresh.
    func fresh() async throws -> JSONValue { try await api.config() }
}
