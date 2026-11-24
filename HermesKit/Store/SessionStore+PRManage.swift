// [pr-manage] What the owner says about a coding project's chats from the app (add-on 0.9.70): which repository a
// project's branches live in, and that a chat's changes are closed. Owner 2026-11-19: "Should a project have a setup to
// integrate to a GitHub repo so that everything is linked that way?" and "How do I mark a PR as closed". A gateway
// without the add-on's routes answers 404 to the first read, `prRepos` stays nil and nothing of this shows.

import Foundation

/// A repository on the computer running Hermes that chats' branches are looked for in.
nonisolated struct SessionPRRepo: Hashable, Sendable {
    /// The project it was linked from (the app's project key); nil for one listed by hand on that computer.
    var project: String?
    var path: String
    var main: String
    var publicRepo: String?
    /// Its main is published to another repository (a publisher's marker is kept in it).
    var mirror: Bool

    init?(_ value: JSONValue?) {
        guard let path = value?["path"]?.string, !path.isEmpty else { return nil }
        project = value?["project"]?.string
        self.path = path
        main = value?["main"]?.string ?? "main"
        publicRepo = value?["public_repo"]?.string
        mirror = value?["mirror"]?.bool ?? false
    }
}

nonisolated enum SessionPRRepoError: Error, Equatable {
    /// The folder is not a git repository on the computer running Hermes.
    case notARepository
    /// The public repository isn't written as owner/repo.
    case invalidPublicRepo
    case invalid
}

/// Lifecycle state of `GET /sessions/pr-repos` so transient failures don't silently hide Repository… or Mark as Closed.
nonisolated enum SessionPRReposState: Equatable, Sendable {
    case unknown
    case loaded
    case unsupported
    case failed
}

extension SessionStore {
    nonisolated static let prReposPath = "/api/plugins/hermes-hq-push/sessions/pr-repos"
    nonisolated static let prMarkPath = "/api/plugins/hermes-hq-push/sessions/pr-mark"

    /// The gateway takes links and marks (its list of repositories was read).
    var prManage: Bool { prRepos != nil }

    /// Whether Repository… should be offered: true once loaded, or on a transient failure so the user can still open
    /// the page and retry instead of watching the menu item vanish.
    var prManageAvailable: Bool { prRepos != nil || prReposState == .failed }

    func prRepo(forProject key: String) -> SessionPRRepo? { prRepos?.first { $0.project == key } }

    /// Reads the linked repositories. Tracks 404 (unsupported) vs transient failure separately so UI can retry cleanly.
    @discardableResult
    func loadPRRepos() async -> SessionPRReposState {
        guard !stopped else { return prReposState }
        let previousState = prReposState
        do {
            let data = try await client.rest("GET", Self.prReposPath, query: [], body: nil)
            guard !stopped else { return prReposState }
            guard let rows = (try? JSONValue.parse(data))?["repos"]?.array else {
                // Non-JSON (e.g. gateway SPA fallback) or missing "repos" key means this gateway doesn't expose pr-repos.
                prReposState = .unsupported
                if prReposState != previousState { onChange?() }
                return prReposState
            }
            let repos = rows.compactMap { SessionPRRepo($0) }
            let changed = repos != prRepos || prReposState != .loaded
            prRepos = repos
            prReposState = .loaded
            if changed { onChange?() }
            return .loaded
        } catch let error as HTTPError where error.status == 404 {
            prReposState = .unsupported
            if prReposState != previousState { onChange?() }
            return .unsupported
        } catch {
            if prRepos == nil { prReposState = .failed }
            if prReposState != previousState { onChange?() }
            return prReposState
        }
    }

    @discardableResult
    func linkPRRepo(project: String, path: String, publicRepo: String?) async throws -> SessionPRRepo {
        let named = publicRepo?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let body: JSONValue = ["project": .string(project), "path": .string(path.trimmingCharacters(in: .whitespacesAndNewlines)),
                               "public_repo": named.isEmpty ? .null : .string(named)]
        let data: Data
        do {
            data = try await client.rest("PUT", Self.prReposPath, query: [], body: body.encoded())
        } catch let error as HTTPError where error.status == 422 {
            let detail = error.body ?? ""
            throw detail.contains("not_a_repository") ? SessionPRRepoError.notARepository
                : detail.contains("invalid_public_repo") ? SessionPRRepoError.invalidPublicRepo : SessionPRRepoError.invalid
        }
        guard let repo = SessionPRRepo(try JSONValue.parse(data)["repo"]) else { throw SessionPRRepoError.invalid }
        prRepos = (prRepos ?? []).filter { $0.project != project } + [repo]
        prReposState = .loaded
        prAutoLinkFailed.remove(project)
        codingProjectsChanged(scopeProject: project)   // revalidate this project without wiping other projects' marks
        onChange?()
        return repo
    }

    func unlinkPRRepo(project: String) async throws {
        _ = try await client.rest("DELETE", Self.prReposPath, query: [URLQueryItem(name: "project", value: project)], body: nil)
        prRepos = (prRepos ?? []).filter { $0.project != project }
        codingProjectsChanged(scopeProject: project)
        onChange?()
    }

    /// The owner's own label on a chat (nothing in any repository changes), then the chat's status read again.
    func setPRClosed(_ session: SessionSummary, _ closed: Bool) async throws {
        let body: JSONValue = ["profile": .string(session.profile), "id": .string(session.id), "closed": .bool(closed)]
        _ = try await client.rest("PUT", Self.prMarkPath, query: [], body: body.encoded())
        await refreshPullRequests(for: [session], force: true)
    }

    /// [repo-pickers] The folders the Repository… page offers for *key* (owner 2026-11-21: "These fields need to be more
    /// than just free-type"): the git repositories Hermes found in that project (its own folder when it found none),
    /// then every other repository known here (other projects', and those linked or listed on the computer running
    /// Hermes), by name.
    func repositoryFolderChoices(forProject key: String) -> (here: [String], elsewhere: [String]) {
        var seen = Set<String>()
        func fresh(_ path: String) -> String? {
            let tidy = Self.tidyFolder(path)
            return tidy.hasPrefix("/") && seen.insert(tidy).inserted ? tidy : nil
        }
        var here: [String] = []
        var elsewhere: [String] = []
        for (profile, projects) in projectsByProfile.sorted(by: { $0.key < $1.key }) {
            for project in projects where SessionProjects.key(project, profile: profile) == key {
                here += (project.repos ?? []).compactMap(fresh)
            }
        }
        if let linked = prRepo(forProject: key)?.path, let path = fresh(linked) { here.insert(path, at: 0) }
        if here.isEmpty, let own = fresh(key) { here.append(own) }
        for projects in projectsByProfile.values {
            for project in projects { elsewhere += (project.repos ?? []).compactMap(fresh) }
        }
        elsewhere += (prRepos ?? []).map(\.path).compactMap(fresh)
        let byName: (String, String) -> Bool = { a, b in
            let order = Self.folderName(a).compare(Self.folderName(b), options: [.caseInsensitive, .numeric])
            return order == .orderedSame ? a < b : order == .orderedAscending
        }
        return (here, elsewhere.sorted(by: byName))
    }

    /// [repo-pickers] The GitHub repositories (owner/repo) the Repository… page offers as the public one: those already
    /// linked, and those chats' pull requests and branches were read against, by name.
    func publicRepoChoices() -> [String] {
        var seen = Set<String>()
        let names = (prRepos ?? []).compactMap(\.publicRepo) + pullRequestRepos
        return names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { Self.isOwnerRepo($0) && seen.insert($0.lowercased()).inserted }
            .sorted { $0.compare($1, options: [.caseInsensitive, .numeric]) == .orderedAscending }
    }

    nonisolated static func tidyFolder(_ path: String) -> String {
        var tidy = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while tidy.count > 1, tidy.hasSuffix("/") { tidy.removeLast() }
        return tidy
    }

    /// A folder's own name ("app" for /Users/me/Projects/app).
    nonisolated static func folderName(_ path: String) -> String {
        let name = (tidyFolder(path) as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    /// owner/repo as GitHub spells them (what the add-on accepts).
    nonisolated static func isOwnerRepo(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z0-9-]{1,39}/[A-Za-z0-9_.-]{1,100}$"#, options: .regularExpression) != nil
    }

    /// owner/repo out of what was typed or pasted: a GitHub web or clone address is cut down to it.
    nonisolated static func ownerRepo(from text: String) -> String {
        var tidy = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://github.com/", "http://github.com/", "github.com/", "ssh://git@github.com/", "git@github.com:"]
        where tidy.lowercased().hasPrefix(prefix) {
            tidy.removeFirst(prefix.count)
            let parts = tidy.split(separator: "/", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { return tidy }
            var repo = String(parts[1])
            if repo.hasSuffix(".git") { repo.removeLast(4) }
            return "\(parts[0])/\(repo)"
        }
        return tidy
    }

    /// Turning Coding Project on for a project whose key is a folder: awaits `loadPRRepos()` if not yet known (fixing
    /// the first-toggle race), then tries that folder as its repository. If the folder isn't a git repo, records it so
    /// the project header can offer a quiet one-tap "Link Repository…" prompt.
    func linkOwnFolderIfUnlinked(_ key: String) {
        guard key.hasPrefix("/"), prReposState != .unsupported else { return }
        Task { [weak self] in
            guard let self, !self.stopped else { return }
            if self.prReposState == .unknown || self.prReposState == .failed {
                _ = await self.loadPRRepos()
            }
            guard !self.stopped, self.prManage, self.isCodingProject(key), self.prRepo(forProject: key) == nil else { return }
            do {
                _ = try await self.linkPRRepo(project: key, path: key, publicRepo: nil)
            } catch SessionPRRepoError.notARepository {
                if self.prAutoLinkFailed.insert(key).inserted { self.onChange?() }
            } catch {
                // Transient error: leave unlinked without flagging as not-a-repo.
            }
        }
    }
}
