// Duplicate Bot, Delete Bot and a bot's recent chats (port of the web app's profile-ops.ts `duplicateBot` / `deleteBot`
// and src/bot-recent.ts, build 240), on the same write path as the other bot writes (BotStore+Editing.swift).
//
// Duplicate: `profiles.create {name: "<base>-N", clone_from: <base>, description}` (the first free N from 2, the base cut so
// the name stays within 64), then the original's look in one `hermes-bots` write — its meta without `chat` and `created`,
// the title "<title> (copy)" — and, best effort, its saved head. Delete: `DELETE /api/profiles/<name>` (the REST door the
// desktop's own Delete Profile uses; never the default profile), then this phone's copies of the bot go at once and stay
// gone until a roster read sent after the delete has answered.

import Foundation

extension BotStore {
    // MARK: - Duplicate

    /// The duplicate's profile name: "<base>-2", "-3", … up to 99, the first not taken. Nil when none is free.
    nonisolated static func duplicateName(of base: String, taken: Set<String>) -> String? {
        for n in 2..<100 {
            let suffix = "-\(n)"
            // Cut the base, never the suffix: a cut suffix would collide with the base for ever.
            let candidate = String(base.prefix(64 - suffix.count)) + suffix
            if !taken.contains(candidate) { return candidate }
        }
        return nil
    }

    /// The meta the duplicate starts with: the original's look and filing, not its chat or creation time; "(copy)" titled.
    nonisolated static func duplicateMeta(_ meta: PinnedSection.Meta) -> PinnedSection.Meta {
        var look = meta
        look["chat"] = nil
        look["created"] = nil
        look["image"] = nil
        look["pet"] = nil
        let title = RosterText.trimmed(meta["title"])
        look["title"] = .string(title.map { "\($0) (copy)" } ?? "")
        return look
    }

    /// Duplicates a bot. Returns the new profile's name.
    @discardableResult
    func duplicateBot(name base: String, display: String) async throws -> String {
        let failTitle = "Couldn’t Duplicate \(display)"
        if readOnlyGateway { throw BotWriteError(title: failTitle, reason: BotWriteError.readOnlyReason) }
        guard let name = Self.duplicateName(of: base, taken: Set(effectiveProfiles().map(\.name))) else {
            throw BotWriteError(title: failTitle, reason: "No free name for the duplicate.")
        }
        let original = effectiveProfiles().first { $0.name == base }
        let description = original?.description ?? ""
        let meta = Self.duplicateMeta(currentMeta(base))
        let head = headState(name: base)
        do {
            // Copies the original's config, skills, SOUL and memory on the gateway (a long handler, as New Bot's).
            _ = try await client.call("profiles.create", ["name": .string(name), "clone_from": .string(base),
                                                          "description": .string(description)], timeout: editing.createTimeout)
        } catch {
            let lost = (error as? RPCError).map { $0.isTimeout || $0.isConnectionLost } ?? false
            guard lost, await profileExists(name) else {
                throw BotWriteError(title: failTitle, reason: BotWriteOutcome.reason(error), detail: "\(error)")
            }
        }
        // The row shows at once (a stand-in until the roster lists it), with the original's look.
        editing.createdRows[name] = .object(["name": .string(name), "description": .string(description), "is_default": false,
                                             "ui_meta": [Self.botsKey: Self.sendable(meta)], "ui_meta_revisions": [:]])
        device.meta[name] = .object(meta)
        persistState()
        rebuild(force: true)
        // The look: best effort (the profile is made; a failed look doesn't undo it).
        if !meta.isEmpty { _ = try? await writeBotMeta(name, failureTitle: failTitle) { _ in meta } }
        if head.saved, let record = head.record { _ = try? await saveHead(name: name, record: record, revision: 0) }
        Task { [weak self] in await self?.refresh() }
        return name
    }

    // MARK: - Delete

    /// The primary profile can't be deleted (Hermes refuses it too).
    func isDefaultBot(_ name: String) -> Bool {
        if name.lowercased() == "default" { return true }
        return effectiveProfiles().first { $0.name == name }?.isDefault ?? false
    }

    /// Deletes a bot's profile on the gateway: its memory, skills, settings and chats.
    func deleteBot(name: String, display: String) async throws {
        let failTitle = "Couldn’t Delete \(display)"
        if readOnlyGateway { throw BotWriteError(title: failTitle, reason: BotWriteError.readOnlyReason) }
        guard !isDefaultBot(name) else { throw BotWriteError(title: failTitle, reason: "The default profile cannot be deleted.") }
        let path = "/api/profiles/" + (name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? name)
        do {
            _ = try await client.rest("DELETE", path, query: [], body: nil)
        } catch let error as HTTPError where error.status == 404 {
            // Already gone (deleted elsewhere): this phone forgets it too.
        } catch let error as HTTPError {
            throw BotWriteError(title: failTitle, reason: Self.restReason(error), detail: "HTTP \(error.status)")
        } catch {
            throw BotWriteError(title: failTitle, reason: BotWriteOutcome.reason(error), detail: "\(error)")
        }
        forgetDeleted(name)
        Task { [weak self] in await self?.refresh() }
    }

    /// The gateway's `detail` for a refused REST call, else plain words.
    nonisolated static func restReason(_ error: HTTPError) -> String {
        if let body = error.body, let value = try? JSONValue.parse(Data(body.utf8)),
           let detail = RosterText.trimmed(value["detail"]) ?? RosterText.trimmed(value["error"]) {
            return String(detail.prefix(200))
        }
        return error.status == 409 ? "This bot is busy. Try again in a moment." : BotWriteError.notSavedReason
    }

    /// This phone's copies of a deleted bot: its row, meta, pin order, unread marks and minted chat.
    func forgetDeleted(_ name: String) {
        editing.deletedAt[name] = Date()
        profiles.removeAll { $0.name == name }
        rawRows.removeAll { RosterText.trimmed($0["name"]) == name }
        editing.createdRows[name] = nil
        editing.descriptions[name] = nil
        device.meta[name] = nil
        device.pinOrder.removeAll { $0 == name }
        device.unread.baselines[name] = nil
        device.unread.markers[name] = nil
        device.headOverlay?[name] = nil
        mintedChats[name] = nil
        persistState()
        rebuild(force: true)
        onDeleted?(name)
    }

    // MARK: - Recent chats (Bot Info › Conversations)

    /// The bot's own recent chats, newest first: its Bot Chat and background runs (probes, tool batches, Kanban) left out;
    /// cron runs and every chat a person had stay. The roster's last session joins them (it can be newer than the read).
    func recentChats(name: String, limit: Int = 3) async -> [SidebarSessionRow] {
        let query = [URLQueryItem(name: "limit", value: String(limit + 2)), URLQueryItem(name: "offset", value: "0"),
                     URLQueryItem(name: "min_messages", value: "1"), URLQueryItem(name: "archived", value: "exclude"),
                     URLQueryItem(name: "order", value: "recent"), URLQueryItem(name: "profile", value: name)]
        var rows: [SidebarSessionRow] = []
        if let data = try? await client.get("/api/profiles/sessions", query), let value = try? JSONValue.parse(data) {
            rows = (value["sessions"]?.array ?? value.array ?? []).compactMap(SidebarSessionRow.init(json:))
        }
        let profile = profile(named: name)
        if let last = profile?.lastSession, !last.id.isEmpty, !rows.contains(where: { $0.id == last.openId || $0.id == last.id }) {
            var row = SidebarSessionRow(id: last.openId, profile: name, title: last.title, preview: last.preview, source: last.source,
                                        lastActive: last.lastActive, messageCount: last.messageCount)
            row.startedAt = last.startedAt
            if (row.messageCount ?? 1) > 0 { rows.append(row) }
        }
        var exclude = Set(profile?.canonicalIds ?? [])
        if let minted = mintedChats[name] { exclude.insert(minted) }
        return Self.recentRows(rows, profile: name, exclude: exclude, limit: limit)
    }

    /// Pure: the rows to list (`recentRows` in src/bot-recent.ts).
    nonisolated static func recentRows(_ rows: [SidebarSessionRow], profile: String, exclude: Set<String>, limit: Int) -> [SidebarSessionRow] {
        var seen = Set<String>()
        return rows.filter { row in
            !SessionRules.isBackgroundRun(row) && row.profile.lowercased() == profile.lowercased() && !exclude.contains(row.id)
                // [groups] a room member's hidden session is not a conversation; nor is a row titled "Bot Chat" whose
                // id the roster doesn't list as the bot's own (the Sessions list's rule), so Bot Chat shows once.
                && !SessionRules.isBotChat(row)
                && seen.insert(row.id).inserted
        }
        .sorted { $0.recency > $1.recency }
        .prefix(limit).map { $0 }
    }
}
