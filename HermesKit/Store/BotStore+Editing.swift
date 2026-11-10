// Bot writes from the phone (spec 1x-settings §2, §5–8): pin, hide, sections, Edit Bot, heads and New Bot, through one
// write path so every action behaves the same. `ui_meta['hermes-bots']` is written as a whole merged object (no
// compare-and-swap, last writer wins, as the web and desktop Hermes do); `ui_meta['dispatch-head']` is compare-and-swap.
//
// The path for a `hermes-bots` write (§2.2): one write per bot at a time → patch locally at once (the row redraws in
// this frame) → a fresh slim read of the gateway's meta, merged in → the patch recomputed over it → `profiles.configure`
// → on failure the local copy goes back and one more best-effort write puts the old values back on the gateway (before
// the next write to that bot starts). A roster read sent before a write to a bot never overwrites that bot's meta (the
// write fence, §2.4: decided by order alone — when the read was sent against when the write was made and settled).

import Foundation

/// The settings stream's bookkeeping inside `BotStore` (memory only).
@MainActor final class BotEditingState {
    /// When this device last wrote each bot's meta (stamped at the local patch and again when the write settles). A stamp
    /// goes once a roster read sent after it has been applied.
    var metaWriteAt: [String: Date] = [:]
    /// When the read whose rows the store holds was sent (`.distantPast` for a cached paint).
    var rowsIssuedAt: Date = .distantPast
    /// Writes to each bot still out (from the local patch until the gateway answered, a failed write's undo included):
    /// the bot stays fenced whatever a roster read says meanwhile.
    var inFlight: [String: Int] = [:]
    /// Each bot's write queue (its last task).
    var tails: [String: Task<Void, Never>] = [:]
    /// A failed write's undo, sent after its caller heard of the failure and before the next write to that bot starts.
    var undos: [String: @MainActor () async -> Void] = [:]
    /// Deleted sections whose members' writes are still out: adoption must not bring them back.
    var pendingSectionDeletes: Set<String> = []
    /// The last full roster's `bot_mode_protocol` (New Bot's SOUL leaves out the teammate section when true).
    var botModeProtocol: Bool?
    /// Descriptions this device wrote, shown while their bot is fenced (dropped with the bot's stamp).
    var descriptions: [String: String] = [:]
    /// Rows this device created that no roster has listed yet (New Bot step 3).
    var createdRows: [String: JSONValue] = [:]
    /// Bots this device deleted, and when: a roster read sent before then may still list them, so they stay out until a
    /// read sent afterwards has answered.
    var deletedAt: [String: Date] = [:]
    /// `profiles.create` copies the default profile on the gateway (a long handler): its own timeout. Tests shrink it.
    var createTimeout: Duration = .seconds(90)
    /// Default models this device set, kept over roster reads sent before they settled (BotStore+Model.swift).
    var modelWrites: [String: BotModelWrite] = [:]

    /// Runs `work` after every earlier write to `profile` has settled, a failed one's undo included (FIFO).
    func serial<T: Sendable>(_ profile: String, _ work: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = tails[profile]
        let task = Task { @MainActor () async throws -> T in
            await previous?.value
            return try await work()
        }
        tails[profile] = Task { @MainActor [weak self] in
            _ = try? await task.value
            // The caller already has the failure (its alert shows now); the next write to this bot reads the gateway
            // only after the undo landed, so it can't be overwritten by it.
            if let undo = self?.undos.removeValue(forKey: profile) { await undo() }
        }
        return try await task.value
    }

    func begin(_ profile: String) { inFlight[profile, default: 0] += 1 }

    func end(_ profile: String) {
        let left = (inFlight[profile] ?? 1) - 1
        inFlight[profile] = left > 0 ? left : nil
    }
}

/// A section delete under way (§5.4): the record and where it stood (an Undo or a failed write puts it back there) and
/// the bots it unfiles.
@MainActor final class SectionDeletion {
    let id: String
    let record: RosterSectionRecord
    let index: Int
    let members: [String]
    /// The Undo ran: the remaining member writes are skipped and a failure is not reported.
    fileprivate(set) var undone = false

    init(id: String, record: RosterSectionRecord, index: Int, members: [String]) {
        self.id = id; self.record = record; self.index = index; self.members = members
    }
}

/// What a `profiles.configure` answer means for the `hermes-bots` part (§2.2 step 5).
nonisolated enum BotWriteOutcome: Sendable, Equatable {
    case persisted(revision: Int?)
    case failed(String)

    private static let olderGateway = JSRegex(#"unknown|unsupported|invalid param|method not found|-3260"#, "i")

    /// The answer to a write that carried `ui_meta`.
    static func meta(_ result: JSONValue) -> BotWriteOutcome {
        guard let applied = result["applied"]?.object else { return .failed(BotWriteError.unsupportedReason) }
        guard applied["ui_meta"] == .bool(true) else { return .failed(BotWriteError.notSavedReason) }
        return .persisted(revision: applied["ui_meta_revisions"]?["hermes-bots"]?.int)
    }

    /// Why a call failed in words: transport kinds say what happened; an older gateway's rejection is "can't save yet".
    static func reason(_ error: Error) -> String {
        if let rpc = error as? RPCError {
            // The client's own line ("request timed out after 30s: profiles.configure") stays in the details.
            if rpc.isTimeout { return NoticeWriteWords.noAnswer }
            if rpc.isConnectionLost { return NoticeWriteWords.dropped }
            if rpc.isNotConnected { return rpc.message }
            if olderGateway.test(rpc.message) { return BotWriteError.unsupportedReason }
            return rpc.message.isEmpty ? BotWriteError.notSavedReason : rpc.plainReason
        }
        if let failure = error as? BotWriteError { return failure.reason }
        return (error as? LocalizedError)?.errorDescription ?? BotWriteError.notSavedReason
    }
}

extension RosterProfile {
    /// `ui_meta_revisions[key]` (0 when absent; spec 1x-settings §7.2).
    func uiMetaRevision(_ key: String) -> Int {
        guard let value = raw["ui_meta_revisions"]?[key], case .number(let n) = value, n >= 0, n.rounded() == n else { return 0 }
        return Int(n)
    }
}

extension BotStore {
    static let headKey = "dispatch-head"
    static let botsKey = "hermes-bots"

    // MARK: - Roster hooks (called from BotStore.swift)

    func rowsArrived(issuedAt: Date, botModeProtocol: Bool? = nil) {
        editing.rowsIssuedAt = issuedAt
        // A read sent after a settled write carries it: that bot's stamp (and the description shown for it) goes.
        for (name, at) in editing.metaWriteAt where at < issuedAt && editing.inFlight[name] == nil {
            editing.metaWriteAt[name] = nil
        }
        for name in editing.descriptions.keys where editing.metaWriteAt[name] == nil && editing.inFlight[name] == nil {
            editing.descriptions[name] = nil
        }
        if let botModeProtocol { editing.botModeProtocol = botModeProtocol }
        // A created bot the roster lists now needs no stand-in row.
        for name in editing.createdRows.keys where profiles.contains(where: { $0.name == name }) { editing.createdRows[name] = nil }
        // A deleted bot: a read sent after the delete says what is true now.
        for (name, at) in editing.deletedAt where at < issuedAt { editing.deletedAt[name] = nil }
        keepModelWrites(issuedAt: issuedAt)
        // A head overlay the roster caught up with (same revision or later) goes.
        guard var overlay = device.headOverlay, !overlay.isEmpty else { return }
        for profile in profiles {
            if let entry = overlay[profile.name], profile.uiMetaRevision(Self.headKey) >= entry.revision { overlay[profile.name] = nil }
        }
        device.headOverlay = overlay.isEmpty ? nil : overlay
        persistState()
    }

    /// Bots whose meta the held rows may not carry yet: a write still out, or one made or settled after the read that
    /// gave the rows was sent. Order alone decides (a full read can take 18–107 s on a busy gateway, SP02 §2.1.1).
    func fencedProfiles() -> Set<String> {
        var fenced = Set(editing.inFlight.keys)
        for (name, at) in editing.metaWriteAt where at > editing.rowsIssuedAt { fenced.insert(name) }
        return fenced
    }

    /// Section adoption that never brings back a section being deleted.
    func adoptSections(_ local: [RosterSectionRecord], meta: [String: JSONValue], profiles rows: [RosterProfile]? = nil) -> [RosterSectionRecord] {
        let adopted = RosterBuilder.adoptSections(local, profiles: rows ?? effectiveProfiles(), meta: meta)
        let known = Set(local.map(\.id))
        return adopted.filter { known.contains($0.id) || !editing.pendingSectionDeletes.contains($0.id) }
    }

    /// The rows as drawn: a fenced bot carries this device's meta (and description), a saved head its overlay, and a bot
    /// created here waits in a stand-in row until the roster lists it.
    func effectiveProfiles() -> [RosterProfile] {
        let fenced = fencedProfiles()
        let overlay = device.headOverlay ?? [:]
        var rows = editing.deletedAt.isEmpty ? profiles : profiles.filter { editing.deletedAt[$0.name] == nil }
        if !fenced.isEmpty || !overlay.isEmpty {
            rows = rows.map { row in
                var row = row
                if fenced.contains(row.name) {
                    if let mine = device.meta[row.name], mine.object != nil { row.uiMeta[Self.botsKey] = mine }
                    if let description = editing.descriptions[row.name] { row.description = description.isEmpty ? nil : description }
                }
                if let entry = overlay[row.name], entry.revision > row.uiMetaRevision(Self.headKey) {
                    row.uiMeta[Self.headKey] = entry.head
                }
                return row
            }
        }
        for (name, raw) in editing.createdRows.sorted(by: { $0.key < $1.key }) where !rows.contains(where: { $0.name == name }) {
            if let row = RosterProfile(json: raw) { rows.append(row) }
        }
        return rows
    }

    // MARK: - Reads for the screens

    /// User sections in this device's order (Pinned is implicit and never stored).
    var sectionRecords: [RosterSectionRecord] { device.sections.filter { $0.id != RosterRules.pinnedSectionId } }

    func sectionName(_ id: String) -> String? { device.sections.first { $0.id == id }?.name }

    /// The bot's `hermes-bots` object as drawn: this device's snapshot merged with its row (`{...snapshot, ...row}`),
    /// or the snapshot alone while the bot is fenced.
    func currentMeta(_ name: String) -> [String: JSONValue] {
        let local = device.meta[name]?.object ?? [:]
        guard !fencedProfiles().contains(name), let row = profiles.first(where: { $0.name == name }), let server = row.serverMeta else {
            return local
        }
        return local.merging(server) { _, theirs in theirs }
    }

    func shownSectionId(name: String) -> String? {
        let meta = currentMeta(name)
        return PinnedSection.shownSectionId(meta, sectionId: PinnedSection.current(meta))
    }

    func rowDescription(_ name: String) -> String? {
        effectiveProfiles().first { $0.name == name }?.description
    }

    func headState(name: String) -> StoredHeadState {
        let row = profiles.first { $0.name == name }
        var record = row?.uiMeta[Self.headKey].flatMap { $0.isNull ? nil : $0 }
        var revision = row?.uiMetaRevision(Self.headKey) ?? 0
        if let entry = device.headOverlay?[name], entry.revision > revision {
            record = entry.head
            revision = entry.revision
        }
        let saved = record.flatMap { HeadRecord.parse($0) } != nil
        return StoredHeadState(record: saved ? record : nil, revision: revision, saved: saved)
    }

    // MARK: - The `hermes-bots` write (§2.2)

    /// One action's write: `patch` is worked out over the bot's current meta (and again over the gateway's fresh one);
    /// `undo` puts back what a refused patch replaced (default `undoOf`). Returns the merged meta written.
    @discardableResult
    func writeBotMeta(_ name: String, failureTitle: String,
                      patch: @escaping (PinnedSection.Meta) -> PinnedSection.Patch?,
                      undo: ((PinnedSection.Meta, PinnedSection.Patch) -> PinnedSection.Patch)? = nil) async throws -> PinnedSection.Meta? {
        if readOnlyGateway { throw BotWriteError(title: failureTitle, reason: BotWriteError.readOnlyReason) }
        return try await editing.serial(name) { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.performBotMetaWrite(name, failureTitle: failureTitle, patch: patch, undo: undo)
        }
    }

    private func performBotMetaWrite(_ name: String, failureTitle: String,
                                      patch: @escaping (PinnedSection.Meta) -> PinnedSection.Patch?,
                                      undo: ((PinnedSection.Meta, PinnedSection.Patch) -> PinnedSection.Patch)?) async throws -> PinnedSection.Meta? {
        let before = currentMeta(name)
        guard let first = patch(before), !first.isEmpty else { return nil }
        let started = ContinuousClock.now
        let fields = first.keys.sorted().joined(separator: ",")
        AppLog.trace("bots", "meta write \(name) [\(fields)]: started")
        // Fenced from the local patch until the gateway answered (a failure hands that over to its undo).
        editing.begin(name)
        var settles = true
        defer { if settles { editing.end(name) } }
        // Step 2: the change shows now.
        editing.metaWriteAt[name] = Date()
        setLocalMeta(name, PinnedSection.apply(first, to: before))

        // Step 3: the gateway's meta now (another device may have changed it).
        let base: PinnedSection.Meta
        do {
            base = try await freshMeta(name, over: before)
        } catch {
            AppLog.note("bots", "meta write \(name) [\(fields)]: failed reading fresh meta, \(BotWriteOutcome.reason(error))")
            setLocalMeta(name, before)
            throw BotWriteError(title: failureTitle, reason: BotWriteOutcome.reason(error), detail: "\(error)")
        }
        let final = patch(base) ?? [:]
        let next = PinnedSection.apply(final, to: base)
        setLocalMeta(name, next)
        if final.isEmpty { editing.metaWriteAt[name] = Date(); return next }

        // Step 4–5: send the whole merged object.
        let outcome: BotWriteOutcome
        var detail: String?
        do {
            let result = try await client.call("profiles.configure", ["name": .string(name), "ui_meta": [Self.botsKey: Self.sendable(next)]],
                                               timeout: .seconds(30))
            outcome = BotWriteOutcome.meta(result)
            detail = (try? String(decoding: result.encoded(), as: UTF8.self))
        } catch {
            outcome = .failed(BotWriteOutcome.reason(error))
            detail = "\(error)"
        }
        editing.metaWriteAt[name] = Date()
        switch outcome {
        case .persisted(let revision):
            AppLog.trace("bots", "meta write \(name) [\(fields)]: succeeded in \(AppLog.ms(since: started)) ms")
            patchRow(name) { row in
                row["ui_meta", default: .object([:])] = Self.setting(row["ui_meta"], Self.botsKey, Self.sendable(next))
                if let revision { row["ui_meta_revisions"] = Self.setting(row["ui_meta_revisions"], Self.botsKey, .number(Double(revision))) }
            }
            if let revision { photos.noteMetaWrite(name, key: Self.botsKey, revision: revision) }       // [photoheads]
            rebuild()
            return next
        case .failed(let reason):
            AppLog.note("bots", "meta write \(name) [\(fields)]: refused, \(reason)")
            // Step 6: back as it was, here at once and (best effort) on the gateway. The undo is the old object as this
            // write knew it; it goes out inside this bot's queue, before any write queued meanwhile reads the gateway
            // (a timed-out write may still have landed: a later hide must not be overwritten by it).
            let back = undo?(base, final) ?? PinnedSection.undoOf(base, final)
            let restored = PinnedSection.apply(back, to: next)
            setLocalMeta(name, restored)
            settles = false
            editing.undos[name] = { [weak self] in
                guard let self else { return }
                _ = try? await self.client.call("profiles.configure", ["name": .string(name), "ui_meta": [Self.botsKey: Self.sendable(restored)]],
                                                timeout: .seconds(10))
                self.editing.metaWriteAt[name] = Date()
                self.editing.end(name)
            }
            throw BotWriteError(title: failureTitle, reason: reason, detail: detail)
        }
    }

    /// Whether the gateway lists `name` now (a slim read). False when the read fails too.
    func profileExists(_ name: String) async -> Bool {
        guard let result = try? await client.call("profiles.list", ["include_sessions": false], timeout: timing.slimTimeout) else { return false }
        return result["profiles"]?.array?.contains { RosterText.trimmed($0["name"]) == name } ?? false
    }

    /// `profiles.list {"include_sessions": false}`, the bot's `hermes-bots` merged over `local` (spec 02 §5.2).
    private func freshMeta(_ name: String, over local: PinnedSection.Meta) async throws -> PinnedSection.Meta {
        let result = try await client.call("profiles.list", ["include_sessions": false], timeout: timing.slimTimeout)
        guard let raw = result["profiles"]?.array?.first(where: { RosterText.trimmed($0["name"]) == name }) else {
            if editing.createdRows[name] != nil { return local }
            throw BotWriteError(title: "", reason: "Your gateway no longer lists this bot.")
        }
        let row = RosterText.cleanRow(raw)
        // The row's fresh meta and revisions replace what the store held for it.
        patchRow(name) { held in
            held["ui_meta"] = row["ui_meta"] ?? .null
            held["ui_meta_revisions"] = row["ui_meta_revisions"] ?? .null
            if held["ui_meta"]?.isNull == true { held["ui_meta"] = nil }
            if held["ui_meta_revisions"]?.isNull == true { held["ui_meta_revisions"] = nil }
        }
        guard let server = row["ui_meta"]?[Self.botsKey]?.object else { return local }
        var merged = local.merging(server) { _, theirs in theirs }
        if let image = local["image"], !image.isNull, RosterText.truthy(image) { merged["image"] = image }
        merged["chat"] = nil
        if server["groups"]?.array != nil, local["group"] != nil, server["group"] == nil { merged["group"] = nil }
        device.meta[name] = .object(merged)
        persistState()
        return merged
    }

    /// The object sent: everything but the local-only `image` and `pet`.
    static func sendable(_ meta: PinnedSection.Meta) -> JSONValue {
        var out = meta
        out["image"] = nil
        out["pet"] = nil
        return .object(out)
    }

    private static func setting(_ container: JSONValue?, _ key: String, _ value: JSONValue) -> JSONValue {
        var object = container?.object ?? [:]
        object[key] = value
        return .object(object)
    }

    func setLocalMeta(_ name: String, _ meta: PinnedSection.Meta) {
        device.meta[name] = .object(meta)
        persistState()
        rebuild()
    }

    /// Changes the held row (and its raw copy) for one bot.
    func patchRow(_ name: String, _ change: (inout [String: JSONValue]) -> Void) {
        if let i = profiles.firstIndex(where: { $0.name == name }), var object = profiles[i].raw.object {
            change(&object)
            if let row = RosterProfile(json: .object(object)) { profiles[i] = row }
        }
        if let i = rawRows.firstIndex(where: { RosterText.trimmed($0["name"]) == name }), var object = rawRows[i].object {
            change(&object)
            rawRows[i] = .object(object)
            lastRosterWriteAt = nil      // [perf] the poll that confirms this matches rawRows: it must still write the cache
        }
        if var created = editing.createdRows[name]?.object {
            change(&created)
            editing.createdRows[name] = .object(created)
        }
    }

    // MARK: - Actions (§5)

    func setPinned(name: String, display: String, _ pinned: Bool) async throws {
        let title = pinned ? "Couldn’t Pin \(display)" : "Couldn’t Unpin \(display)"
        try await writeBotMeta(name, failureTitle: title) { [weak self] meta in
            PinnedSection.pinPatch(meta, pinned: pinned) { self?.sectionName($0) }
        }
    }

    func setHidden(name: String, display: String, _ hidden: Bool) async throws {
        let title = hidden ? "Couldn’t Hide \(display)" : "Couldn’t Show \(display)"
        try await writeBotMeta(name, failureTitle: title, patch: { meta in
            RosterText.truthy(meta["hidden"]) == hidden ? nil : ["hidden": .bool(hidden)]
        }, undo: { _, _ in ["hidden": .bool(!hidden)] })
    }

    /// [presence] "Alert When It Uses Its Computer" (R:src/bot-screen-phone.tsx:32, spec 3x-presence §7): on unless the
    /// stored flag is exactly false. The Mac reads the same flag raw for "open the screen automatically" (opt-in), so
    /// reading the default never writes it.
    func screenNoticeOn(_ name: String) -> Bool { currentMeta(name)["screenAutoOpen"] != .bool(false) }

    /// [presence] The switch was flipped. A refused write puts back exactly what was stored (the default undo: the old
    /// value, or no value when there was none), so a failed flip never turns the Mac's opt-in on (DECISION D18).
    func setScreenNotice(name: String, _ on: Bool) async throws {
        try await writeBotMeta(name, failureTitle: "Couldn’t Change the Alert", patch: { meta in
            (meta["screenAutoOpen"] != .bool(false)) == on ? nil : ["screenAutoOpen": .bool(on)]
        })
    }

    /// Move to Section (nil: Remove from Section). A pinned bot stays in Pinned; the pick is where an unpin puts it.
    func move(name: String, display: String, toSection target: String?) async throws {
        try await writeBotMeta(name, failureTitle: "Couldn’t Move \(display)") { [weak self] meta in
            guard let self else { return nil }
            let lookup: (String) -> String? = { self.sectionName($0) }
            if let special = PinnedSection.sectionMovePatch(meta, target: target, sectionName: lookup) { return special.isEmpty ? nil : special }
            let name: String? = target.flatMap(lookup)
            let current = PinnedSection.current(meta)
            let currentName = meta["sectionName"]?.string
            if current == target, currentName == name { return nil }
            return ["sectionId": target.map(JSONValue.string) ?? .null, "sectionName": name.map(JSONValue.string) ?? .null]
        }
    }

    /// `sec-<ms base36>-<5 random base36>` (`HB/user-sections.ts:112-114`).
    static func newSectionId(now: Date = Date()) -> String {
        let ms = Int64((now.timeIntervalSince1970 * 1000).rounded(.down))
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        let random = String((0..<5).map { _ in alphabet[Int.random(in: 0..<36)] })
        return "sec-\(String(ms, radix: 36))-\(random)"
    }

    func appendSection(named name: String) -> RosterSectionRecord {
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        let record = RosterSectionRecord(id: Self.newSectionId(), name: clean)
        device.sections.append(record)
        persistState()
        rebuild(force: true)
        return record
    }

    /// Bots whose meta files them in `id` (`botSectionId`), hidden ones included.
    func members(ofSection id: String) -> [String] {
        effectiveProfiles().map(\.name).filter { PinnedSection.current(currentMeta($0)) == id }
    }

    func renameSection(_ id: String, to name: String, displayName: (String) -> String) async throws {
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !clean.isEmpty, let index = device.sections.firstIndex(where: { $0.id == id }) else { return }
        let members = members(ofSection: id)
        AppLog.trace("bots", "rename section \(AppLog.tag(id)): \(members.count) members to re-stamp")
        // Read-only: refused before anything changes here (the members' writes are what would be refused).
        if readOnlyGateway, !members.isEmpty {
            throw BotWriteError(title: "Couldn’t Rename \(device.sections[index].name)", reason: BotWriteError.readOnlyReason)
        }
        let old = device.sections[index].name
        device.sections[index].name = clean
        persistState()
        rebuild(force: true)
        // Members carry the name with their membership: a rename re-stamps them, one write each, in order.
        var landed = 0
        for member in members {
            guard device.sections.contains(where: { $0.id == id }) else { return }
            do {
                let written = try await writeBotMeta(member, failureTitle: "Couldn’t Move \(displayName(member))") { meta in
                    PinnedSection.current(meta) == id && meta["sectionName"]?.string != clean
                        ? ["sectionId": .string(id), "sectionName": .string(clean)] : nil
                }
                if written != nil { landed += 1 }
            } catch {
                // Nothing reached the gateway: the record takes its old name back (Try Again renames again). Once a
                // member carries the new name, the record keeps it and Try Again re-stamps the rest.
                if landed == 0, let i = device.sections.firstIndex(where: { $0.id == id }), device.sections[i].name == clean {
                    device.sections[i].name = old
                    persistState()
                    rebuild(force: true)
                }
                AppLog.note("bots", "rename section \(AppLog.tag(id)): failed after \(landed) of \(members.count) members, \(SessionActionText.reason(error))")
                throw error
            }
        }
        AppLog.trace("bots", "rename section \(AppLog.tag(id)): \(landed) of \(members.count) members re-stamped")
    }

    func moveSection(_ id: String, by delta: Int) {
        var list = device.sections
        guard let from = list.firstIndex(where: { $0.id == id }) else { return }
        let to = from + delta
        guard to >= 0, to < list.count else { return }
        let moved = list.remove(at: from)
        list.insert(moved, at: to)
        device.sections = list
        persistState()
        rebuild(force: true)
    }

    /// Delete Section, the local half (§5.4): the record goes at once (its id held back from adoption) and the Undo can
    /// show now. nil when there is no such section. Read-only with members to move: refused before anything changes.
    func beginDeleteSection(_ id: String) throws -> SectionDeletion? {
        guard let index = device.sections.firstIndex(where: { $0.id == id }) else { return nil }
        let record = device.sections[index]
        let members = members(ofSection: id)
        if readOnlyGateway, !members.isEmpty {
            throw BotWriteError(title: "Couldn’t Delete “\(record.name)”", reason: BotWriteError.readOnlyReason)
        }
        editing.pendingSectionDeletes.insert(id)
        device.sections.remove(at: index)
        persistState()
        rebuild(force: true)
        AppLog.trace("bots", "delete section \(AppLog.tag(id)): \(members.count) members to unassign")
        return SectionDeletion(id: id, record: record, index: index, members: members)
    }

    /// Delete Section, the writes: each member to Unassigned, one write each, in order. A failed write puts the record
    /// back where it was (the members not yet moved show under it again) and throws; Try Again deletes it again.
    func finishDeleteSection(_ deletion: SectionDeletion, displayName: @escaping (String) -> String) async throws {
        let id = deletion.id
        do {
            for member in deletion.members {
                if deletion.undone { break }
                try await writeBotMeta(member, failureTitle: "Couldn’t Move \(displayName(member))") { [weak deletion] meta in
                    guard let deletion, !deletion.undone else { return nil }
                    return PinnedSection.current(meta) == id ? ["sectionId": .null, "sectionName": .null] : nil
                }
            }
        } catch {
            if deletion.undone { return }           // the Undo already put it back; nothing to report
            AppLog.note("bots", "delete section \(AppLog.tag(id)): failed, \(SessionActionText.reason(error)), put back")
            putBack(deletion)
            throw error
        }
        if !deletion.undone {
            editing.pendingSectionDeletes.remove(id)
            AppLog.trace("bots", "delete section \(AppLog.tag(id)): \(deletion.members.count) members unassigned")
        }
    }

    /// The Undo: the record back at its index now; members the delete moved to Unassigned are filed back (queued behind
    /// any of their writes still out). A member moved elsewhere meanwhile stays where it was put.
    func undoDeleteSection(_ deletion: SectionDeletion, displayName: @escaping (String) -> String) {
        guard !deletion.undone else { return }
        AppLog.trace("bots", "undo delete section \(AppLog.tag(deletion.id)): \(deletion.members.count) members to file back")
        deletion.undone = true
        putBack(deletion)
        let id = deletion.id, name = deletion.record.name
        for member in deletion.members {
            Task { @MainActor [weak self] in
                _ = try? await self?.writeBotMeta(member, failureTitle: "Couldn’t Move \(displayName(member))") { meta in
                    PinnedSection.current(meta) == nil ? ["sectionId": .string(id), "sectionName": .string(name)] : nil
                }
            }
        }
    }

    private func putBack(_ deletion: SectionDeletion) {
        editing.pendingSectionDeletes.remove(deletion.id)
        guard !device.sections.contains(where: { $0.id == deletion.id }) else { return }
        var list = device.sections
        list.insert(deletion.record, at: min(deletion.index, list.count))
        device.sections = list
        persistState()
        rebuild(force: true)
    }

    // MARK: - Edit Bot (§6.3)

    /// One `profiles.configure` with up to two sections: `ui_meta.hermes-bots` (+ title) and `description`. A refused
    /// part rolls back only its own field.
    func saveEdit(name: String, title: String?, description: String?) async throws -> EditOutcome {
        if readOnlyGateway { throw BotWriteError(title: "Couldn’t Save Changes", reason: BotWriteError.readOnlyReason) }
        return try await editing.serial(name) { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.performSaveEdit(name: name, title: title, description: description)
        }
    }

    /// [photoheads] `flags`: more keys for the same `hermes-bots` object (a picture's `imageKind` and `custom`,
    /// BotStore+Pictures.swift); they are written and rolled back together with the title.
    func performSaveEdit(name: String, title: String?, description: String?, flags: PinnedSection.Patch = [:]) async throws -> EditOutcome {
        let started = ContinuousClock.now
        AppLog.trace("bots", "save edit \(name): started (title=\(title != nil), description=\(description != nil))")
        var params: [String: JSONValue] = ["name": .string(name)]
        var base: PinnedSection.Meta = currentMeta(name)
        let oldDescription = rowDescription(name)
        editing.begin(name)
        defer { editing.end(name) }
        editing.metaWriteAt[name] = Date()
        var metaPatch = flags
        if let title { metaPatch["title"] = .string(title) }
        if !metaPatch.isEmpty {
            let before = base
            setLocalMeta(name, PinnedSection.apply(metaPatch, to: before))
            do { base = try await freshMeta(name, over: before) } catch {
                setLocalMeta(name, before)
                throw BotWriteError(title: "Couldn’t Save Changes", reason: BotWriteOutcome.reason(error), detail: "\(error)")
            }
            let next = PinnedSection.apply(metaPatch, to: base)
            setLocalMeta(name, next)
            params["ui_meta"] = [Self.botsKey: Self.sendable(next)]
        }
        if let description {
            editing.descriptions[name] = description
            rebuild()
            params["description"] = .string(description)
        }
        var outcome = EditOutcome(titleApplied: nil, descriptionApplied: nil, reason: nil)
        do {
            let result = try await client.call("profiles.configure", .object(params), timeout: .seconds(30))
            let applied = result["applied"]?.object
            if !metaPatch.isEmpty {
                switch BotWriteOutcome.meta(result) {
                case .persisted(let revision):
                    if title != nil { outcome.titleApplied = true }
                    if !flags.isEmpty { outcome.pictureKindApplied = true }
                    let written = device.meta[name]?.object ?? [:]
                    patchRow(name) { row in
                        row["ui_meta"] = Self.setting(row["ui_meta"], Self.botsKey, Self.sendable(written))
                        if let revision { row["ui_meta_revisions"] = Self.setting(row["ui_meta_revisions"], Self.botsKey, .number(Double(revision))) }
                    }
                    if let revision { photos.noteMetaWrite(name, key: Self.botsKey, revision: revision) }       // [photoheads]
                case .failed(let reason):
                    if title != nil { outcome.titleApplied = false }
                    if !flags.isEmpty { outcome.pictureKindApplied = false }
                    outcome.reason = reason
                }
            }
            if description != nil {
                if applied?["description"] == .bool(true) {
                    outcome.descriptionApplied = true
                    patchRow(name) { row in row["description"] = .string(description ?? "") }
                } else {
                    outcome.descriptionApplied = false
                    outcome.reason = outcome.reason ?? (applied == nil ? BotWriteError.unsupportedReason : BotWriteError.notSavedReason)
                }
            }
        } catch {
            if title != nil { outcome.titleApplied = false }
            if !flags.isEmpty { outcome.pictureKindApplied = false }
            if description != nil { outcome.descriptionApplied = false }
            outcome.reason = BotWriteOutcome.reason(error)
        }
        editing.metaWriteAt[name] = Date()
        if outcome.titleApplied == false || outcome.pictureKindApplied == false {
            let current = device.meta[name]?.object ?? [:]
            let back = PinnedSection.undoOf(base, metaPatch)
            setLocalMeta(name, PinnedSection.apply(back, to: current))
        }
        if outcome.descriptionApplied == false {
            if let oldDescription { editing.descriptions[name] = oldDescription } else { editing.descriptions[name] = nil }
        }
        if let reason = outcome.reason {
            AppLog.note("bots", "save edit \(name): refused, \(reason)")
        } else {
            AppLog.trace("bots", "save edit \(name): succeeded in \(AppLog.ms(since: started)) ms")
        }
        rebuild()
        return outcome
    }

    // MARK: - Heads (§7.5)

    func saveHead(name: String, record: JSONValue?, revision: Int) async throws -> Int {
        if readOnlyGateway { throw HeadSaveError.failed(BotWriteError.readOnlyReason) }
        return try await editing.serial(name) { [weak self] in
            guard let self else { throw CancellationError() }
            let result: JSONValue
            do {
                result = try await self.client.call("profiles.configure", [
                    "name": .string(name),
                    "ui_meta": [Self.headKey: record ?? .null],
                    "ui_meta_expected_revisions": [Self.headKey: .number(Double(revision))],
                ], timeout: .seconds(30))
            } catch {
                let message = (error as? RPCError)?.message ?? ""
                AppLog.note("bots", "save head \(name): failed, \(message.isEmpty ? "no answer" : message)")
                throw HeadSaveError.failed(message.isEmpty ? "The gateway didn’t answer. Check the connection and try again." : message)
            }
            let applied = result["applied"]?.object
            if let conflict = applied?["ui_meta_conflicts"]?[Self.headKey] {
                let actual = conflict["actual"]?.int ?? revision + 1
                AppLog.note("bots", "save head \(name): stale revision \(revision), gateway has \(actual >= 0 ? actual : revision + 1)")
                throw HeadSaveError.conflict(actual: actual >= 0 ? actual : revision + 1)
            }
            guard let applied, applied["ui_meta"] != nil else {
                throw HeadSaveError.failed("This gateway can’t save bot heads yet. Update Hermes on \(HostWord.updateTarget), then try again.")
            }
            guard applied["ui_meta"] == .bool(true) else { throw HeadSaveError.failed("The gateway didn’t save the head. Try again.") }
            let next = applied["ui_meta_revisions"]?[Self.headKey]?.int ?? 0
            let saved = next > revision ? next : revision + 1
            AppLog.trace("bots", "save head \(name): revision \(revision) -> \(saved)")
            var overlay = self.device.headOverlay ?? [:]
            overlay[name] = HeadOverlayEntry(head: record, revision: saved)
            self.device.headOverlay = overlay
            self.persistState()
            // [photoheads] This phone's own write is no reason to fetch the picture again; a saved head replaces a
            // photo here at once (its desktop copy follows in `mirrorHead`).
            self.photos.noteMetaWrite(name, key: Self.headKey, revision: saved)
            if record != nil { self.photos.headSaved(name) }
            self.rebuild(force: true)
            return saved
        }
    }

    /// The desktop copy (`mirror.ts`): a saved head's 288 × 288 PNG as the profile's avatar; after a reset, the copy
    /// this app put there is removed (a photo someone chose is left alone). Never fails anything.
    func mirrorHead(name: String, png dataURL: String?) async {
        if readOnlyGateway { return }
        if let dataURL {
            // [photoheads] What was stored is adopted (no fetch needed to know it). When the head replaced a photo the
            // upload is tried again after 2 s and 8 s: until it lands, the gateway still holds the photo.
            var retries = photos.timing.mirrorRetries[...]
            while true {
                let result = try? await client.call("profiles.set_asset", ["name": .string(name), "asset": "avatar", "data": .string(dataURL)],
                                                    timeout: photos.timing.uploadTimeout)
                if result?["ok"] == .bool(true) {
                    if photos.supportsAssets {
                        await photos.adopt(name, dataURL: dataURL)
                        patchRow(name) { $0["has_avatar"] = true }
                    }
                    return
                }
                guard photos.awaitingMirror.contains(name), let delay = retries.popFirst() else { return }
                try? await Task.sleep(for: delay)
                if Task.isCancelled { return }
            }
        }
        guard let current = try? await client.call("profiles.get_asset", ["name": .string(name), "asset": "avatar"], timeout: .seconds(30)) else { return }
        let found = current["found"] == .bool(true)
        guard found, HeadRecord.isHeadMirror(current["data"]?.string) else {
            // [photoheads] Not this app's copy (a photo someone chose, or nothing): left alone, and now known.
            if photos.supportsAssets { await photos.adopt(name, dataURL: found ? current["data"]?.string : nil) }
            return
        }
        let cleared = try? await client.call("profiles.set_asset", ["name": .string(name), "asset": "avatar", "clear": true], timeout: .seconds(30))
        if cleared?["ok"] == .bool(true), photos.supportsAssets {       // [photoheads]
            await photos.adopt(name, dataURL: nil)
            patchRow(name) { $0["has_avatar"] = false }
        }
    }

    // MARK: - New Bot (§8.2)

    func isTaken(_ slug: String) -> Bool { effectiveProfiles().contains { $0.name == slug } }

    /// Steps 1–5: create the profile, write its meta, check its runtime, mint its Bot Chat.
    func createBot(name typed: String, title typedTitle: String, description: String) async throws -> NewBotResult {
        let identity = BotIdentity.profileIdentity(name: typed, title: typedTitle)
        let slug = identity.slug
        let display = BotIdentity.displayName(name: slug, title: identity.title)
        let failTitle = "Couldn’t Create \(display)"
        if readOnlyGateway { throw BotWriteError(title: failTitle, reason: BotWriteError.readOnlyReason) }
        guard BotIdentity.isValidProfileId(slug) else { throw BotWriteError(title: failTitle, reason: "Give the bot a name with letters or numbers.") }
        let started = ContinuousClock.now
        AppLog.trace("bots", "create bot \(slug): started")
        let descriptionText = BotIdentity.descriptionText(title: identity.title, description: description)
        let teammates = profiles.map { (name: $0.name, description: $0.description) }
        let soul = BotIdentity.composeSoul(slug: slug, title: identity.title, description: description,
                                           serverInjectsProtocol: editing.botModeProtocol ?? true, teammates: teammates)
        do {
            // A long handler on the gateway (it copies the default profile): 90 s.
            _ = try await client.call("profiles.create", [
                "name": .string(slug), "description": .string(descriptionText), "clone_from": "default",
                "no_skills": false, "share_auth": true, "soul": .string(soul),
            ], timeout: editing.createTimeout)
        } catch let error as RPCError where error.code == 4062 {
            AppLog.note("bots", "create bot \(slug): refused, \(error.message)")
            throw NewBotError.inline(error.message)
        } catch {
            // The answer was lost, but the profile may have been made: a slim read says. If it is there, carry on with
            // steps 2–5 rather than leave a bot with no meta, no Bot Chat and no intro (and a Try Again that says
            // "already exists").
            let lost = (error as? RPCError).map { $0.isTimeout || $0.isConnectionLost } ?? false
            guard lost, await profileExists(slug) else {
                AppLog.note("bots", "create bot \(slug): failed, \(BotWriteOutcome.reason(error))")
                throw BotWriteError(title: failTitle, reason: BotWriteOutcome.reason(error), detail: "\(error)")
            }
            AppLog.trace("bots", "create bot \(slug): answer lost, but the gateway made it, carrying on")
        }
        // Step 3: the row shows at once; the next roster replaces it.
        let created = Date().timeIntervalSince1970 * 1000
        let meta: PinnedSection.Meta = ["shape": "blobatar", "imageKind": "shape", "title": .string(identity.title),
                                        "created": .number(created.rounded(.down))]
        editing.createdRows[slug] = .object(["name": .string(slug), "description": .string(descriptionText),
                                             "is_default": false, "ui_meta": [Self.botsKey: .object(meta)], "ui_meta_revisions": [:]])
        device.meta[slug] = .object(meta)
        persistState()
        rebuild(force: true)
        // Step 2: the meta write (best effort; a failure doesn't undo the bot).
        _ = try? await writeBotMeta(slug, failureTitle: failTitle) { _ in meta }
        // Step 4: only an explicit ok:false counts.
        let readiness = try? await client.call("setup.runtime_check", ["profile": .string(slug)], timeout: .seconds(30))
        let needsModel = readiness?["ok"] == .bool(false)
        // Step 5: the Bot Chat.
        _ = try? await mintFreshChat(profile: slug, displayName: display)
        let bot = self.bot(named: slug) ?? Bot(id: slug, name: display, role: descriptionText.isEmpty ? nil : descriptionText, preview: nil,
                                              lastActive: nil, isWorking: false, unread: false, pinned: false, pinOrder: nil,
                                              sectionName: nil, hidden: false, canonicalSessionId: mintedChats[slug], head: nil)
        AppLog.trace("bots", "create bot \(slug): succeeded in \(AppLog.ms(since: started)) ms, needsModel=\(needsModel)")
        return NewBotResult(bot: bot, needsModel: needsModel, displayName: display)
    }

    /// A brand-new profile's Bot Chat (§8.2 step 5): the registry lookup, then `session.create` + `session.title`, without
    /// waiting for a full roster to confirm (the profile is seconds old).
    @discardableResult
    func mintFreshChat(profile name: String, displayName: String) async throws -> String {
        if let minted = mintedChats[name] { return minted }
        if let found = try await registryLookup(name: name, displayName: displayName) {
            mintedChats[name] = found.openId
            rebuild()
            return found.openId
        }
        if readOnlyGateway { throw BotChatError.readOnly(bot: displayName) }
        let created: JSONValue
        do {
            created = try await SessionCreate.call(client, profile: name, ["profile": .string(name), "title": .string(RosterRules.botChatTitle),
                                                               "hidden": true, "follow_profile_config": true], timeout: .seconds(30))
        } catch {
            AppLog.note("bots", "mint fresh chat for \(name): create failed, \(RosterRules.errorText(error))")
            throw error
        }
        guard let stored = RosterText.trimmed(created["stored_session_id"]) ?? RosterText.trimmed(created["session_id"]) else {
            AppLog.note("bots", "mint fresh chat for \(name): gateway returned no session id")
            throw BotChatError.createFailed(bot: displayName, detail: "the gateway returned no session id")
        }
        if let runtime = RosterText.trimmed(created["session_id"]) {
            _ = try? await client.call("session.title", ["session_id": .string(runtime), "title": .string(RosterRules.botChatTitle),
                                                         "profile": .string(name)], timeout: .seconds(30))
        }
        AppLog.trace("bots", "mint fresh chat for \(name): created \(AppLog.tag(stored))")
        mintedChats[name] = stored
        rebuild(force: true)
        return stored
    }
}

/// `profiles.create` refused the name (4062: exists or invalid): shown under the Name field.
nonisolated enum NewBotError: Error, LocalizedError, Equatable {
    case inline(String)
    var errorDescription: String? { if case .inline(let message) = self { return message }; return nil }
}
