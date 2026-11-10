// Sessions row actions (spec 02 §9; the web's `S/ui-lists/session-menu.ts`, `session-work.ts`, `archive-undo.ts`,
// `V/api/sessions.ts`, `V/store/projects.ts`): the writes behind the row's swipes and menus, each with the owning
// profile in the body and the query as the gateway reads it, and the reads behind them (the Archived view, search,
// projects, a whole chat for Share and Export JSON).
//
//   Pin / Unpin, Archive / Unarchive, Mark as Read / Unread, Rename
//       PATCH /api/sessions/{id}?profile=p   {"pinned"|"archived"|"unread"|"title": …, "profile": p}
//   Delete Chat                 DELETE /api/sessions/{id}?profile=p
//       (both behind the revision fence: SessionWrite reads /mutation-snapshot first)
//   Archived view               GET /api/profiles/sessions?limit=200&offset=0&min_messages=0&archived=only&order=recent&profile=all
//   Search                      GET /api/sessions/search?q=…&profile=p   (one request per profile)
//   Move to Project ›           RPC projects.tree {preview_limit:3, profile} → session.workspace.move {cwd, session_key, profile}
//   New Project…                RPC projects.create {name, folders:[path], use:false, profile}, then the move
//   New Chat in a project       RPC session.create {profile, follow_profile_config, cwd: root, cwd_explicit:true}
//   Branch in New Chat          RPC session.branch_stored {cols:96, source, cwd?, profile, parent_session_id}
//   Share / Export JSON         GET /api/sessions/{id}/messages?order=oldest&limit=500&offset=n … (every page)
//
// Writes show at once (optimistic) and come back on failure; a read-only gateway refuses them all. Colours are
// device-local, as the web's.

import Foundation

/// A project a chat can move to (`SidebarProjectTree`): its id, name and working root.
nonisolated struct SessionProject: Sendable, Hashable, Identifiable, Codable {       // [sessions-m9] Codable: kept for the next launch
    var id: String
    var label: String
    /// The project's working root (`projectRootCwd`): its folder, else its first repo's.
    var root: String
    /// Every folder that belongs to it (its own, its repos', their worktree lanes): which project holds a chat.
    var paths: [String]
    /// Hermes found it by itself (`isAuto`): no saved project behind it, so there is nothing to delete.
    var isAuto: Bool? = nil

    /// The tree's projects a chat can move to: every project with a folder (not the folder-less "Home" bucket).
    static func decodeTree(_ json: JSONValue) -> [SessionProject] {
        (json["projects"]?.array ?? []).compactMap { node in
            guard let id = RosterText.trimmed(node["id"]) else { return nil }
            if node["isNoProject"]?.bool == true || node["is_no_project"]?.bool == true { return nil }
            let label = RosterText.trimmed(node["label"]) ?? RosterText.trimmed(node["name"]) ?? id
            let repos = node["repos"]?.array ?? []
            let own = RosterText.trimmed(node["path"]) ?? RosterText.trimmed(node["primary_path"])
            let repoPaths = repos.compactMap { RosterText.trimmed($0["path"]) }
            let lanes = repos.flatMap { ($0["groups"]?.array ?? []).compactMap { RosterText.trimmed($0["path"]) } }
            guard let root = own ?? repoPaths.first else { return nil }
            return SessionProject(id: id, label: label, root: root, paths: [own].compactMap { $0 } + repoPaths + lanes,
                                  isAuto: node["isAuto"]?.bool == true || node["is_auto"]?.bool == true ? true : nil)
        }
    }

    /// New Project with no folder typed: `~/Projects/<slug>` on the gateway's computer (`<slug>-2`… on later tries),
    /// the slug as Hermes makes a project's (`projects_db._slugify`).
    static let autoFolderAttempts = 5
    static func autoFolder(name: String, attempt: Int = 1) -> String {
        var slug = ""
        for scalar in name.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                slug.unicodeScalars.append(scalar)
            } else if !slug.isEmpty, !slug.hasSuffix("-") {
                slug.append("-")
            }
        }
        slug = String(slug.prefix(64))
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.isEmpty { slug = "project" }
        return "~/Projects/" + slug + (attempt > 1 ? "-\(attempt)" : "")
    }

    /// `projects.create`'s refusal when the folder is already another project's.
    static func folderTaken(_ error: RPCError) -> Bool { error.message.contains("already belongs to project") }

    /// `projectIdForCwd`: the project whose folder holds `cwd` most closely.
    static func owner(of cwd: String?, in projects: [SessionProject]) -> String? {
        guard let cwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty else { return nil }
        var best: (id: String, length: Int)?
        for project in projects {
            for path in project.paths where cwd == path || cwd.hasPrefix(path.hasSuffix("/") ? path : path + "/") {
                if path.count > (best?.length ?? -1) { best = (project.id, path.count) }
            }
        }
        return best?.id
    }
}

/// What a branch made: the new chat to open.
nonisolated struct SessionBranch: Sendable, Hashable {
    var storedId: String
    var profile: String
}

nonisolated enum SessionActionText {
    static let archivedWayBack = "Find it in Filter and Sort › Show › Archived."
    static let deleteMessage = "This chat and its history will be deleted from \(HostWord.phrase)."
    static var branchUnsupported: String { "This gateway can’t branch chats yet. Update Hermes on \(HostWord.updateTarget), then try again." }
    static var projectsUnsupported: String { "This gateway doesn’t have projects yet. Update Hermes on \(HostWord.updateTarget), then try again." }

    static let noAnswer = "Your gateway didn’t answer in time. Try again in a moment."
    static let connectionLost = "The connection dropped before your gateway answered. Check that it went through, then try again."
    /// Hermes's bare `permission_denied` on a chat edit (2026-10-24): it refuses a Nous sign-in its own chats until the
    /// Hermes HQ add-on 0.9.1 is installed and the gateway restarted (hermes-hq-push own_chats.py).
    static let refused = "Hermes says this chat belongs to another sign-in. If you made it in Hermes HQ, update Hermes’s notification add-on in Settings › Notifications, then try again."
    /// The same refusal on a chat stamped `basic:<username>` (2026-10-25): the old password sign-in made it, and Hermes
    /// lets only that sign-in change it. Add-on 0.9.3 hands such chats to the one sign-in the computer's owner names
    /// (`hermes_hq.password_chats_owner`); it never guesses, since on a shared gateway that would give them to everyone.
    /// At most 160 characters, so the alert shows it whole (FailureAlert.twoLines).
    static let refusedPasswordChat = "Only the old password sign-in can change this chat. Update the notification add-on in Settings › Notifications, then ask your bot to give these chats to you."

    /// Hermes's refusal, said for whose chat it is (`SessionSummary.owner`).
    static func refused(owner: String?) -> String {
        owner?.hasPrefix("basic:") == true ? refusedPasswordChat : refused
    }

    /// A refusal's words: Try Again can't help until the add-on is updated, so its alert offers only OK.
    static func isRefusal(_ reason: String) -> Bool { reason == refused || reason == refusedPasswordChat }

    /// The gateway's words, with Hermes's bare refusal said plainly (for the chat's `owner` when it is known).
    static func plain(_ text: String, owner: String? = nil) -> String {
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "permission_denied": refused(owner: owner)
        case "session_busy": SessionWrite.busyWords
        default: text
        }
    }

    /// What Show Details adds under the reason: the transport's own words, when the reason replaced them.
    static func detail(_ error: Error) -> String? {
        guard let rpc = error as? RPCError, rpc.isTimeout || rpc.isConnectionLost else { return nil }
        return rpc.message
    }

    /// The reason a failure alert shows: the gateway's own `detail`, else plain words. `owner`: the chat's stamped
    /// sign-in, when the failure is about one chat.
    static func reason(_ error: Error, owner: String? = nil) -> String {
        if let failure = error as? BotWriteError { return failure.reason }
        if let http = error as? HTTPError {
            if let body = http.body, let data = body.data(using: .utf8), let json = try? JSONValue.parse(data),
               let detail = RosterText.trimmed(json["detail"]) { return plain(detail, owner: owner) }
            return http.status == 404 ? "The gateway couldn’t find this chat." : http.plainWords
        }
        if let rpc = error as? RPCError {
            // Sent, but no answer: the transport's own line ("request timed out after 30s: projects.create") is for
            // Show Details (`detail`), not for the alert.
            if rpc.isTimeout { return noAnswer }
            if rpc.isConnectionLost { return connectionLost }
            return plain(rpc.plainReason, owner: owner)
        }
        if let local = error as? LocalizedError, let text = local.errorDescription { return text }
        return "\(error)"
    }

    /// `sessionExportFilename`: "<title>-<id8>.json", both cut to safe words.
    static func exportFilename(sessionId: String, title: String?) -> String {
        func clean(_ value: String) -> String {
            let lowered = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var out = ""
            var dash = false
            for scalar in lowered.unicodeScalars {
                let ok = ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "." || scalar == "_" || scalar == "-"
                if ok { out.unicodeScalars.append(scalar); dash = false } else if !dash { out.append("-"); dash = true }
            }
            while out.hasPrefix("-") { out.removeFirst() }
            while out.hasSuffix("-") { out.removeLast() }
            return String(out.prefix(48))
        }
        let titlePart = title.map(clean) ?? ""
        let idPart = String(clean(sessionId).prefix(8))
        return "\(titlePart.isEmpty ? "session" : titlePart)-\(idPart.isEmpty ? "session" : idPart).json"
    }
}

extension SessionStore {
    // MARK: - Helpers

    private func refuseWhenReadOnly() throws {
        if readOnlyGateway { throw BotWriteError(title: "", reason: BotWriteError.readOnlyReason) }
    }

    static func path(_ id: String) -> String { "/api/sessions/" + HistoryRequest.encodePathSegment(id) }

    /// `PATCH /api/sessions/{id}` with the owner in the body and the query (`sessionWriteProfile`), behind the
    /// revision fence (`SessionWrite`).
    private func patch(_ session: SessionSummary, _ fields: [String: JSONValue]) async throws -> JSONValue? {
        let data = try await SessionWrite.patch(client, id: session.id, profile: session.profile, fields)
        return try? JSONValue.parse(data)
    }

    /// Rewrites the stored row (every list holding it), then the list.
    private func update(_ session: SessionSummary, _ change: (inout SidebarSessionRow) -> Void) {
        func apply(_ rows: inout [SidebarSessionRow]) {
            for index in rows.indices where rows[index].id == session.id && rows[index].profile == session.profile { change(&rows[index]) }
        }
        apply(&recents); apply(&cron); apply(&messaging); apply(&archivedRows)
        lastFingerprint = nil
        writeCache()
        rebuild()
    }

    private static func key(_ session: SessionSummary) -> String { writeKey(id: session.id, profile: session.profile) }

    /// The row as listed (any slice or the Archived view).
    func storedRow(_ session: SessionSummary) -> SidebarSessionRow? {
        (recents + cron + messaging + archivedRows).first { $0.id == session.id && $0.profile == session.profile }
    }

    // MARK: - Pin

    /// Pin / Unpin: the row moves to (or out of) Pinned now; a failure moves it back and throws.
    func setPinned(_ session: SessionSummary, _ pinned: Bool) async throws {
        try refuseWhenReadOnly()
        let before = storedRow(session)?.pinned
        let tag = AppLog.tag(session.id)
        let started = ContinuousClock.now
        AppLog.trace("sessions", "\(pinned ? "pin" : "unpin") \(tag): started")
        update(session) { $0.pinned = pinned }
        do {
            _ = try await patch(session, ["pinned": .bool(pinned)])
            if device.pins.removeValue(forKey: Self.key(session)) != nil { persistState() }
            AppLog.trace("sessions", "\(pinned ? "pin" : "unpin") \(tag): succeeded in \(AppLog.ms(since: started)) ms")
        } catch let error as HTTPError where SessionWrite.isMaintenanceRefusal(error) {
            // Hermes before 0.22.3 can't pin while its gateway runs, and has no other way to: this device keeps it.
            AppLog.note("sessions", "\(pinned ? "pin" : "unpin") \(tag): maintenance refusal, kept on device")
            keepPinOnDevice(pinned, id: session.id, profile: session.profile)
        } catch {
            AppLog.note("sessions", "\(pinned ? "pin" : "unpin") \(tag): failed, \(SessionActionText.reason(error))")
            update(session) { $0.pinned = before }
            throw error
        }
    }

    // MARK: - Read state

    /// Mark as Read / Mark as Unread from the row (`toggleRead`): unread sets the device marker and the server flag
    /// (`PATCH {"unread":true}`); read clears both, as opening the chat would, without selecting it.
    func setUnread(_ session: SessionSummary, _ unread: Bool) {
        guard let row = listedRow(id: session.id, profile: session.profile) else { return }
        if unread {
            var bucket = device.unread.markers[row.profile] ?? []
            if !bucket.contains(row.id) { bucket.append(row.id) }
            device.unread.markers[row.profile] = bucket
            persistState()
            if !readOnlyGateway { writeUnread(true, row: row) }
        } else {
            device.unread.opened(row, clearServerLocally: row.unread == true && readOnlyGateway)
            persistState()
            if row.unread == true && !readOnlyGateway { writeUnread(false, row: row) }
        }
        rebuild()
    }

    // MARK: - Archive

    /// Archive (or Unarchive on an archived row): the row leaves its list now; the write follows. A failure
    /// puts it back and throws. Unarchive puts the row back in the recents at once.
    func setArchived(_ session: SessionSummary, _ archived: Bool) async throws {
        try refuseWhenReadOnly()
        let key = Self.key(session)
        let row = storedRow(session)
        let tag = AppLog.tag(session.id)
        let started = ContinuousClock.now
        AppLog.trace("sessions", "\(archived ? "archive" : "unarchive") \(tag): started")
        leaving.insert(key)
        rebuild()
        do {
            _ = try await patch(session, ["archived": .bool(archived)])
        } catch {
            AppLog.note("sessions", "\(archived ? "archive" : "unarchive") \(tag): failed, \(SessionActionText.reason(error))")
            leaving.remove(key)
            rebuild()
            throw error
        }
        AppLog.trace("sessions", "\(archived ? "archive" : "unarchive") \(tag): succeeded in \(AppLog.ms(since: started)) ms")
        leaving.remove(key)
        if archived {
            recents.removeAll { $0.id == session.id && $0.profile == session.profile }
            if var row {
                row.archived = true
                archivedRows.removeAll { $0.id == row.id && $0.profile == row.profile }
                archivedRows.insert(row, at: 0)
            }
        } else {
            archivedRows.removeAll { $0.id == session.id && $0.profile == session.profile }
            if var row, !recents.contains(where: { $0.id == row.id && $0.profile == row.profile }) {
                row.archived = false
                recents.append(row)
            }
        }
        lastFingerprint = nil
        writeCache()
        rebuild(force: true)
    }

    /// Filter › Show › Archived: the archived chats of every profile (capped at 200: a lookup, not a feed). A failed
    /// read keeps the last good set. Returns true when the read failed while archived rows were kept (UX study #205:
    /// the pull says so).
    @discardableResult
    func loadArchived() async -> Bool {
        if archivedRows.isEmpty { archivedLoadState = .loading; onChange?() }
        let query = [URLQueryItem(name: "limit", value: "200"), URLQueryItem(name: "offset", value: "0"),
                     URLQueryItem(name: "min_messages", value: "0"), URLQueryItem(name: "archived", value: "only"),
                     URLQueryItem(name: "order", value: "recent"), URLQueryItem(name: "profile", value: "all")]
        do {
            let data = try await client.rest("GET", Self.legacyPath, query: query, body: nil)
            let json = try JSONValue.parse(data)
            archivedRows = (json["sessions"]?.array ?? []).compactMap(SidebarSessionRow.init(json:))
            archivedLoadState = .ready
            AppLog.trace("sessions", "archived list: \(archivedRows.count) rows")
            rebuild(force: true)
            refreshLatest()
            return false
        } catch {
            AppLog.note("sessions", "archived list failed, kept \(archivedRows.count) rows: \(SessionsLoadWords.reason(for: error))")
            archivedLoadState = archivedRows.isEmpty
                ? .failed(message: SessionsLoadWords.reason(for: error), busy: RosterRules.isGatewayBusy(error)) : .ready
            onChange?()
            return !archivedRows.isEmpty
        }
    }

    // MARK: - Delete

    /// Delete Chat (already asked): `DELETE /api/sessions/{id}?profile=p`; the rows go when the gateway answers.
    func delete(_ session: SessionSummary) async throws {
        try refuseWhenReadOnly()
        let tag = AppLog.tag(session.id)
        let started = ContinuousClock.now
        AppLog.trace("sessions", "delete \(tag): started")
        do {
            try await SessionWrite.delete(client, id: session.id, profile: session.profile)
        } catch {
            AppLog.note("sessions", "delete \(tag): failed, \(SessionActionText.reason(error))")
            throw error
        }
        AppLog.trace("sessions", "delete \(tag): succeeded in \(AppLog.ms(since: started)) ms")
        func drop(_ rows: inout [SidebarSessionRow]) { rows.removeAll { $0.id == session.id && $0.profile == session.profile } }
        drop(&recents); drop(&cron); drop(&messaging); drop(&archivedRows)
        onDeleted?(session.profile, session.id)         // [sessions-m9] its "Not Delivered:" words go with it
        lastFingerprint = nil
        writeCache()
        rebuild(force: true)
    }

    // MARK: - Rename

    /// Rename Chat: the row shows the title now; `PATCH {"title":…}`; the old title comes back on failure.
    @discardableResult
    func rename(_ session: SessionSummary, to title: String) async throws -> String {
        try refuseWhenReadOnly()
        let typed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let before = storedRow(session)?.title
        let tag = AppLog.tag(session.id)
        let started = ContinuousClock.now
        AppLog.trace("sessions", "rename \(tag): started")
        update(session) { $0.title = typed.isEmpty ? nil : typed }
        do {
            let answer = try await patch(session, ["title": .string(typed)])
            let stored = answer?["title"]?.string ?? typed
            update(session) { $0.title = stored.isEmpty ? nil : stored }
            AppLog.trace("sessions", "rename \(tag): succeeded in \(AppLog.ms(since: started)) ms")
            return stored
        } catch {
            AppLog.note("sessions", "rename \(tag): failed, \(SessionActionText.reason(error))")
            update(session) { $0.title = before }
            throw error
        }
    }

    // MARK: - Colour (device-local)

    /// More › Color: the swatch (nil = No Color), kept under the chat's durable id.
    func setColor(_ session: SessionSummary, _ color: Int?) {
        let row = storedRow(session)
        let key = row.map(Self.durableId) ?? session.id
        if let color, SessionColors.names.indices.contains(color) { device.colors[key] = color } else { device.colors[key] = nil }
        persistState()
        rebuild(force: true)
    }

    // MARK: - Projects

    /// The projects a chat of `profile` can move to (`projects.tree`), cached per profile.
    func projects(for profile: String, refresh: Bool = true) async throws -> [SessionProject] {
        if !refresh, let cached = projectsByProfile[profile] { return cached }
        do {
            let answer = try await client.call("projects.tree", ["preview_limit": 3, "profile": .string(profile)], timeout: .seconds(20))
            let projects = SessionProject.decodeTree(answer)
            projectsByProfile[profile] = projects
            return projects
        } catch let error as RPCError where error.code == -32601 {
            projectsByProfile[profile] = []
            throw BotWriteError(title: "", reason: SessionActionText.projectsUnsupported)
        } catch let error as RPCError where error.code == 4064 {
            dropGoneBot(profile)
            throw error
        }
    }

    /// `4064 Profile '<name>' does not exist.`: the bot was deleted; its projects (kept across launches) go too.
    private func dropGoneBot(_ profile: String) {
        guard projectsByProfile[profile] != nil else { return }
        AppLog.note("sessions", "projects: bot \(profile) is gone, its projects dropped")
        projectsByProfile[profile] = nil
    }

    /// The bots holding a project as the gateway has them now: each one's projects are read again first (the kept
    /// copy can be days old, or name a bot since deleted). A read that fails for another reason keeps the kept copy.
    private func freshProjectHolders(key: String) async -> [(profile: String, project: SessionProject)] {
        for (profile, _) in projectHolders(key: key) {
            _ = try? await projects(for: profile, refresh: true)
        }
        return projectHolders(key: key)
    }

    /// Where the menu may move a chat: every project but the one that holds it now.
    func moveTargets(for session: SessionSummary) -> [SessionProject]? {
        guard let projects = projectsByProfile[session.profile] else { return nil }
        let current = SessionProject.owner(of: storedRow(session)?.cwd, in: projects)
        return projects.filter { $0.id != current }
    }

    /// The project that holds a chat now: nil for Home, or before its bot's projects are read.
    func project(of session: SessionSummary) -> SessionProject? {
        guard let projects = projectsByProfile[session.profile],
              let id = SessionProject.owner(of: storedRow(session)?.cwd, in: projects) else { return nil }
        return projects.first { $0.id == id }
    }

    /// A project's New Chat: each bot with a project under `key` (`SessionProjects.key`), with that bot's project.
    func projectHolders(key: String) -> [(profile: String, project: SessionProject)] {
        projectsByProfile.keys.sorted().compactMap { profile in
            projectsByProfile[profile]?.first { SessionProjects.key($0, profile: profile) == key }.map { (profile, $0) }
        }
    }

    /// Rename Project…: `projects.update {id, name, profile}` for every bot that holds the project's folder. A project
    /// Hermes found by itself (an auto project, no id of its own: 5062) becomes a real one with that name and folder.
    func renameProject(key: String, to name: String) async throws {
        try refuseWhenReadOnly()
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let holders = await freshProjectHolders(key: key)
        AppLog.trace("sessions", "rename project: \(holders.count) bots hold it")
        guard !clean.isEmpty, !holders.isEmpty else { return }
        for (profile, project) in holders {
            let tag = AppLog.tag(project.id)
            do {
                _ = try await client.call("projects.update", ["id": .string(project.id), "name": .string(clean), "profile": .string(profile)],
                                          timeout: .seconds(30))
            } catch let error as RPCError where error.code == -32601 {
                AppLog.note("sessions", "rename project \(tag): gateway lacks projects")
                throw BotWriteError(title: "", reason: SessionActionText.projectsUnsupported)
            } catch let error as RPCError where error.code == 5062 {
                AppLog.trace("sessions", "rename project \(tag): not a saved project, creating it")
                _ = try await createProject(clean: clean, path: project.root, profile: profile)
                projectsByProfile[profile]?.removeAll { $0.id == project.id }
                continue
            } catch let error as RPCError where error.code == 4064 {
                dropGoneBot(profile)
                continue
            } catch {
                AppLog.note("sessions", "rename project \(tag): failed, \(SessionActionText.reason(error))")
                throw error
            }
            if let index = projectsByProfile[profile]?.firstIndex(where: { $0.id == project.id }) {
                projectsByProfile[profile]?[index].label = clean
            }
            AppLog.trace("sessions", "rename project \(tag): renamed")
        }
    }

    /// Whether Delete Project… is offered: some bot holds the folder as a saved project (not one Hermes found itself).
    func canDeleteProject(key: String) -> Bool {
        projectHolders(key: key).contains { $0.project.isAuto != true }
    }

    /// Delete Project…: `projects.delete {id, profile}` for every bot that saved the project. Its chats and folder stay
    /// on the gateway computer; chats still in the folder list under the folder's name (Hermes's own auto project).
    func deleteProject(key: String) async throws {
        try refuseWhenReadOnly()
        for (profile, project) in await freshProjectHolders(key: key) where project.isAuto != true {
            let tag = AppLog.tag(project.id)
            do {
                _ = try await client.call("projects.delete", ["id": .string(project.id), "profile": .string(profile)], timeout: .seconds(30))
            } catch let error as RPCError where error.code == -32601 {
                AppLog.note("sessions", "delete project \(tag): gateway lacks projects")
                throw BotWriteError(title: "", reason: SessionActionText.projectsUnsupported)
            } catch let error as RPCError where error.code == 5062 {
                AppLog.trace("sessions", "delete project \(tag): already gone")
            } catch let error as RPCError where error.code == 4064 {
                dropGoneBot(profile)
                continue
            } catch {
                AppLog.note("sessions", "delete project \(tag): failed, \(SessionActionText.reason(error))")
                throw error
            }
            projectsByProfile[profile]?.removeAll { $0.id == project.id }
            AppLog.trace("sessions", "delete project \(tag): deleted")
        }
    }

    /// Move to Project: `session.workspace.move {cwd, session_key, profile}`; the row takes the new folder.
    func move(_ session: SessionSummary, to project: SessionProject) async throws {
        try refuseWhenReadOnly()
        let tag = AppLog.tag(session.id)
        let started = ContinuousClock.now
        AppLog.trace("sessions", "move \(tag) to project \(AppLog.tag(project.id)): started")
        let answer: JSONValue
        do {
            answer = try await client.call("session.workspace.move", ["cwd": .string(project.root), "session_key": .string(session.id),
                                                                      "profile": .string(session.profile)], timeout: .seconds(30))
        } catch {
            AppLog.note("sessions", "move \(tag): failed, \(SessionActionText.reason(error))")
            throw error
        }
        let moved = RosterText.trimmed(answer["cwd"]) ?? project.root
        update(session) { $0.cwd = moved }
        AppLog.trace("sessions", "move \(tag): succeeded in \(AppLog.ms(since: started)) ms")
    }

    /// New Project… then the move (`projects.create`; a project owns chats by folder, so it needs one).
    /// No folder typed: the app makes one named after the project (`~/Projects/<slug>`, `POST /api/files/mkdir`), and
    /// when that folder already belongs to another project, the next free `<slug>-2`, `-3`…
    func createProject(name: String, folder: String, profile: String) async throws -> SessionProject {
        try refuseWhenReadOnly()
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.isEmpty else { return try await createProject(clean: clean, path: path, profile: profile) }
        for attempt in 1...SessionProject.autoFolderAttempts {
            let made = try await makeFolder(SessionProject.autoFolder(name: clean, attempt: attempt))
            do {
                return try await createProject(clean: clean, path: made, profile: profile)
            } catch let error as RPCError where SessionProject.folderTaken(error) && attempt < SessionProject.autoFolderAttempts {
                AppLog.note("sessions", "new project: folder \(attempt) taken, trying the next")
            }
        }
        throw CancellationError()   // not reached: the last attempt returns or throws
    }

    /// `POST /api/files/mkdir {path}` (parents too; an existing folder is fine): the gateway's absolute path for it.
    private func makeFolder(_ path: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["path": path])
        do {
            let data = try await client.rest("POST", "/api/files/mkdir", query: [], body: body)
            return RosterText.trimmed((try? JSONValue.parse(data))?["path"]) ?? path
        } catch let http as HTTPError {
            AppLog.note("sessions", "new project: couldn’t make its folder, HTTP \(http.status)")
            // Not "couldn’t find this chat" for a 404 (a Hermes without the route): the folder, and the way round it.
            let why = http.status == 404 ? nil : SessionActionText.reason(http).trimmingCharacters(in: .whitespaces)
            let said = why.map { $0.hasSuffix(".") || $0.hasSuffix("!") || $0.hasSuffix("?") ? $0 : $0 + "." }
            throw BotWriteError(title: "", reason: ["Couldn’t make the folder \(path).", said, "Type a folder to use instead."]
                .compactMap { $0 }.joined(separator: " "))
        }
    }

    private func createProject(clean: String, path: String, profile: String) async throws -> SessionProject {
        let answer: JSONValue
        do {
            answer = try await client.call("projects.create", ["name": .string(clean), "folders": [.string(path)], "use": false,
                                                               "profile": .string(profile)], timeout: .seconds(30))
        } catch let error as RPCError where error.code == -32601 {
            AppLog.note("sessions", "new project: gateway lacks projects")
            throw BotWriteError(title: "", reason: SessionActionText.projectsUnsupported)
        } catch {
            AppLog.note("sessions", "new project: failed, \(SessionActionText.reason(error))")
            throw error
        }
        let made = answer["project"] ?? answer
        let id = RosterText.trimmed(made["id"]) ?? clean
        let root = RosterText.trimmed(made["primary_path"]) ?? RosterText.trimmed(made["folders"]?[0]?["path"])
            ?? RosterText.trimmed(made["folders"]?[0]) ?? path
        let project = SessionProject(id: id, label: RosterText.trimmed(made["name"]) ?? clean, root: root, paths: [root])
        projectsByProfile[profile, default: []].append(project)
        AppLog.trace("sessions", "new project \(AppLog.tag(id)): created")
        return project
    }

    // MARK: - Branch

    /// Branch in New Chat (`branchStoredSession`): the gateway copies the stored transcript into a new chat
    /// (`session.branch_stored`); the new chat's stored id (else its runtime id) to open.
    func branch(_ session: SessionSummary) async throws -> SessionBranch {
        try refuseWhenReadOnly()
        let parentTag = AppLog.tag(session.id)
        var params: [String: JSONValue] = ["cols": 96, "source": "desktop", "profile": .string(session.profile),
                                           "parent_session_id": .string(session.id)]
        if let cwd = storedRow(session)?.cwd { params["cwd"] = .string(cwd) }
        let answer: JSONValue
        do {
            answer = try await client.call("session.branch_stored", .object(params), timeout: .seconds(60))
        } catch let error as RPCError where error.code == -32601 {
            AppLog.note("sessions", "branch \(parentTag): gateway lacks branching")
            throw BotWriteError(title: "", reason: SessionActionText.branchUnsupported)
        } catch {
            AppLog.note("sessions", "branch \(parentTag): failed, \(SessionActionText.reason(error))")
            throw error
        }
        guard let id = RosterText.trimmed(answer["stored_session_id"]) ?? RosterText.trimmed(answer["session_id"]) else {
            AppLog.note("sessions", "branch \(parentTag): gateway made no new chat")
            throw BotWriteError(title: "", reason: "The gateway didn’t make the new chat.")
        }
        AppLog.trace("sessions", "branch \(parentTag): new chat \(AppLog.tag(id))")
        Task { [weak self] in await self?.refresh() }
        return SessionBranch(storedId: id, profile: session.profile)
    }

    // MARK: - New chat

    /// Compose: a new chat in `profile` (`session.create`, the profile's own model settings); its stored id, else its
    /// runtime id, to open.
    func newChat(profile: String, folder: String? = nil) async throws -> SessionBranch {
        try refuseWhenReadOnly()
        let made: JSONValue
        do {
            made = try await SessionCreate.call(client, profile: profile, ["profile": .string(profile), "follow_profile_config": true],
                                         folder: folder, timeout: .seconds(30))
        } catch {
            AppLog.note("sessions", "new chat (\(profile)): failed, \(SessionActionText.reason(error))")
            throw error
        }
        guard let id = RosterText.trimmed(made["stored_session_id"]) ?? RosterText.trimmed(made["session_id"]) else {
            AppLog.note("sessions", "new chat (\(profile)): gateway made no new chat")
            throw BotWriteError(title: "", reason: "The gateway didn’t make the new chat.")
        }
        AppLog.trace("sessions", "new chat (\(profile)): \(AppLog.tag(id))")
        return SessionBranch(storedId: id, profile: profile)
    }

    // MARK: - Whole chat (Share, Export JSON)

    /// The chat as text for the share sheet (title, then "You:" / "<Bot>:" blocks), every page read.
    func transcriptText(_ session: SessionSummary, botName: String) async throws -> String {
        try await ChatTranscript.fetchAllText(client: client, storedSessionId: session.id, profile: session.profile,
                                              title: session.title, botName: botName, userLine: nil)
    }

    /// Export JSON (`exportSession`): `{exported_at, session_id, title, session, message_count, messages}` with the
    /// stored rows as the gateway sends them, pretty-printed.
    func exportJSON(_ session: SessionSummary) async throws -> Data {
        let rows = try await Self.fetchAllRows(client: client, storedSessionId: session.id, profile: session.profile)
        let stamp = ISO8601DateFormatter().string(from: Date())
        var sessionJSON: JSONValue = .null
        if let row = storedRow(session), let data = try? JSONEncoder().encode(row), let json = try? JSONValue.parse(data) { sessionJSON = json }
        let payload: JSONValue = ["exported_at": .string(stamp), "session_id": .string(session.id), "title": .string(session.title),
                                  "session": sessionJSON, "message_count": .number(Double(rows.count)), "messages": .array(rows)]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(payload)
    }

    /// Every stored row, oldest first, unfolded (`getAllSessionMessages`), with the same 32 M-character cap.
    @concurrent
    nonisolated static func fetchAllRows(client: any GatewayClient, storedSessionId: String, profile: String) async throws -> [JSONValue] {
        var rows: [JSONValue] = []
        var offset = 0
        var characters = 0
        while true {
            try Task.checkCancellation()
            let request = HistoryRequest(storedSessionId: storedSessionId, profile: profile, limit: ChatTranscript.pageLimit,
                                         offset: offset, order: "oldest")
            let query = [URLQueryItem(name: "profile", value: profile), URLQueryItem(name: "limit", value: String(ChatTranscript.pageLimit)),
                         URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "order", value: "oldest"),
                         URLQueryItem(name: "include_compacted", value: "true")]
            let data = try await client.rest("GET", request.core().path, query: query, body: nil)
            characters += data.count
            if characters > ChatTranscript.characterCap { throw MenusError("This chat is too long to export from \(DeviceWord.subject).") }
            let page = try HistoryAPI.decodePage(data, request: request)
            rows += page.rows
            if page.rows.isEmpty || page.pagination == nil || page.rows.count < ChatTranscript.pageLimit { break }
            offset += page.rows.count
        }
        return rows
    }

    // MARK: - Search

    /// One profile's full-text hits (`GET /api/sessions/search?q=…&profile=p`).
    nonisolated static func searchHits(client: any GatewayClient, query: String, profile: String) async throws -> [SessionSearchHit] {
        let data = try await client.rest("GET", "/api/sessions/search",
                                         query: [URLQueryItem(name: "q", value: query), URLQueryItem(name: "profile", value: profile)], body: nil)
        return try SessionSearchHit.decode(data, profile: profile)
    }

    /// Every profile's hits for `query`, merged round-robin, hidden chats left out, ranked by fit. A profile whose
    /// request failed is skipped (its local rows still show).
    func search(_ query: String, profiles: [String]) async -> [SessionSearchHit] {
        await searchReporting(query, profiles: profiles).hits
    }

    /// `search`, and whether any profile's request failed (UX study 2026-10-19 #28: an empty result after a failure
    /// is not "No Results").
    func searchReporting(_ query: String, profiles: [String]) async -> (hits: [SessionSearchHit], failed: Bool) {
        let owners = Array(Set(profiles.isEmpty ? ["default"] : profiles)).sorted()
        var lists = [[SessionSearchHit]](repeating: [], count: owners.count)
        var failed = false
        let client = self.client
        await withChildTasks(of: (Int, [SessionSearchHit]?).self) { group in
            for (index, profile) in owners.enumerated() {
                group.addTask { (index, try? await Self.searchHits(client: client, query: query, profile: profile)) }
            }
            while let (index, hits) = await group.next() {
                if let hits { lists[index] = hits } else { failed = true }
            }
        }
        let ranked = SessionSearch.rank(SessionSearch.merge(lists).filter { !SessionSearch.isHidden($0) }, query: query)
        AppLog.trace("sessions", "search: \(owners.count) profiles, \(ranked.count) hits, failed=\(failed)")
        return (ranked, failed)
    }
}
