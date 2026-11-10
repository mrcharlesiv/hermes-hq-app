// Session edits behind a revision fence (Hermes 0.22.3+, `hermes_cli/web_server_sessions.py` `_mutate_session_request`;
// the client is `apps/shared/src/session-http-mutations.ts`). Every rename, pin, archive, unread and delete reads
//
//     GET /api/sessions/{id}/mutation-snapshot?profile=p  → {exists, runtime_revision, runtime_generation}
//
// and sends that back with a fresh request id: in the body of `PATCH /api/sessions/{id}` (`request_id`,
// `expected_revision`, `expected_generation`), in the query of `DELETE /api/sessions/{id}`. A write with none of it is
// refused `409 client_upgrade_required`.
//
// - A write whose answer never came (timeout, lost connection) keeps its identity, so Try Again replays the same
//   request id and the gateway answers with the first attempt's receipt instead of applying it twice.
// - `revision_conflict` / `stale_generation` (another client changed the chat in between) reads again and sends once
//   more: these edits say what the row should be, not how to change it.
// - A gateway older than the fence has no snapshot route (404, or a page that isn't the snapshot): the write goes
//   as before, with no identity (those builds refuse fields they don't know).
// - `409 Exclusive maintenance refused`: a dashboard started on its own (not inside the gateway) can't write while a
//   gateway owns the profile, and builds before the owner forward (0.22.3) refuse every edit then. Archive, hide,
//   rename and delete go again as the socket's own `session.archive` / `session.set_hidden` / `session.title` /
//   `session.delete`, which write without that lock. Pin and unread have no such call: the refusal goes back to
//   SessionStore, which keeps them on this device (`SessionsDeviceState.pins`, the unread markers).
// - `409 session_busy` on a delete (tester report 2026-11-07, "Couldn't delete chat (session_busy)"): a gateway-hosted
//   Hermes deletes only an idle chat, and a reply still running, a message waiting behind it or a subagent keeps it
//   busy. The chat is stopped (its queued messages cancelled, its turn interrupted, as the Hermes desktop app stops a
//   chat before deleting it) and the delete goes again for a few seconds while the stop lands.

import Foundation

nonisolated enum SessionWrite {
    /// What the snapshot gave: the identity to send, or nil when the gateway predates the fence.
    struct Identity: Sendable, Equatable {
        var requestId: String
        var revision: Int
        var generation: Int?
    }

    /// `PATCH /api/sessions/{id}` with `fields` and the owner (`profile`) in the body and the query.
    @discardableResult
    static func patch(_ client: any GatewayClient, id: String, profile: String?, _ fields: [String: JSONValue]) async throws -> Data {
        var body = fields
        if let profile { body["profile"] = .string(profile) }
        do {
            return try await fencedPatch(client, id: id, profile: profile, body)
        } catch let error as HTTPError where isMaintenanceRefusal(error) {
            if fields.count == 1, case .string(let title)? = fields["title"], !title.isEmpty {
                return try await socketTitle(client, id: id, profile: profile, title, refused: error).encoded()
            }
            guard let (method, flag) = socketVerb(fields) else { throw error }
            let result = try await socket(client, method, id: id, profile: profile, [flag.key: flag.value], refused: error)
            return try result.encoded()
        }
    }

    private static func fencedPatch(_ client: any GatewayClient, id: String, profile: String?, _ body: [String: JSONValue]) async throws -> Data {
        try await fenced(client, id: id, profile: profile, method: "PATCH", payload: .object(body)) { identity in
            var sent = body
            if let identity {
                sent["request_id"] = .string(identity.requestId)
                sent["expected_revision"] = .number(Double(identity.revision))
                if let generation = identity.generation { sent["expected_generation"] = .number(Double(generation)) }
            }
            return try await client.rest("PATCH", path(id), query: query(profile), body: try JSONValue.object(sent).encoded())
        }
    }

    /// `DELETE /api/sessions/{id}?profile=p` (the identity rides in the query). A chat already gone counts as deleted;
    /// a chat still working is stopped and deleted once the stop has landed.
    @discardableResult
    static func delete(_ client: any GatewayClient, id: String, profile: String?,
                       busyWaits: [Duration] = [.milliseconds(300), .milliseconds(700), .seconds(1), .seconds(2), .seconds(3)]) async throws -> Data {
        var waits = busyWaits
        while true {
            do {
                return try await deleteOnce(client, id: id, profile: profile)
            } catch where isBusy(error) && !waits.isEmpty {
                AppLog.note("sessions", "delete \(AppLog.tag(id)): refused while the chat is working; stopping it and deleting again")
                await stopWork(client, id: id, profile: profile)
                try await Task.sleep(for: waits.removeFirst())
            }
        }
    }

    private static func deleteOnce(_ client: any GatewayClient, id: String, profile: String?) async throws -> Data {
        do {
            return try await fencedDelete(client, id: id, profile: profile)
        } catch let error as HTTPError where isMaintenanceRefusal(error) {
            do {
                return try await socket(client, "session.delete", id: id, profile: profile, [:], refused: error).encoded()
            } catch let error as RPCError where error.code == 4007 {
                return try JSONValue.object(["ok": true, "already_absent": true]).encoded()
            }
        }
    }

    private static func fencedDelete(_ client: any GatewayClient, id: String, profile: String?) async throws -> Data {
        try await fenced(client, id: id, profile: profile, method: "DELETE", payload: .null) { identity in
            var items = query(profile)
            if let identity {
                items.append(URLQueryItem(name: "request_id", value: identity.requestId))
                items.append(URLQueryItem(name: "expected_revision", value: String(identity.revision)))
                if let generation = identity.generation {
                    items.append(URLQueryItem(name: "expected_generation", value: String(generation)))
                }
            }
            return try await client.rest("DELETE", path(id), query: items, body: nil)
        }
    }

    // MARK: - A chat still working

    /// What a refusal of a chat still working says when stopping it wasn't enough.
    static let busyWords = "This chat is still working. Stop it, wait a moment, then try again."

    /// The gateway's "this chat is working" refusal, from the dashboard (`409 session_busy`) or the socket.
    static func isBusy(_ error: any Error) -> Bool {
        if let error = error as? HTTPError { return error.status == 409 && detail(error) == "session_busy" }
        if let error = error as? RPCError { return (error.data?["reason"]?.string ?? error.message) == "session_busy" }
        return false
    }

    /// Stops what keeps the stored chat `id` busy: its snapshot (`session.resume`, no transcript) names the messages
    /// waiting (`pending`, each cancelled with `prompt.cancel`) and whether a reply runs (`session.interrupt`, which
    /// on a gateway-hosted Hermes names the turn the snapshot gave). Best effort: the delete's answer says whether it
    /// was enough.
    static func stopWork(_ client: any GatewayClient, id: String, profile: String?) async {
        var resume: [String: JSONValue] = ["session_id": .string(id), "omit_messages": true]
        if let profile { resume["profile"] = .string(profile) }
        guard let snapshot = try? await client.call("session.resume", .object(resume), timeout: .seconds(20)),
              let runtime = snapshot["session_id"]?.string, !runtime.isEmpty else { return }
        var scope: [String: JSONValue] = ["session_id": .string(runtime)]
        if let profile { scope["profile"] = .string(profile) }
        let queued = (snapshot["pending"]?.array ?? []).compactMap { $0["admission_id"]?.string }
        for admission in queued {
            var params = scope
            params["admission_id"] = .string(admission)
            _ = try? await client.call("prompt.cancel", .object(params), timeout: .seconds(15))
        }
        if snapshot["running"]?.bool != false {
            _ = try? await client.call("session.interrupt", .object(scope), timeout: .seconds(15))
        }
        AppLog.trace("sessions", "stopped \(AppLog.tag(id)) to delete it: \(queued.count) queued cancelled, running=\(snapshot["running"]?.bool.map(String.init) ?? "?")")
    }

    // MARK: - A gateway that owns the profile

    /// The dashboard's refusal while a gateway it can't reach owns the profile (`gateway/runtime_ownership.py`).
    static func isMaintenanceRefusal(_ error: HTTPError) -> Bool {
        error.status == 409 && (detail(error) ?? error.body ?? "").contains("Exclusive maintenance refused")
    }

    /// The socket call for an edit that has one: a lone `archived` or `hidden`.
    private static func socketVerb(_ fields: [String: JSONValue]) -> (String, (key: String, value: JSONValue))? {
        guard fields.count == 1, let flag = fields.first, case .bool = flag.value else { return nil }
        switch flag.key {
        case "archived": return ("session.archive", flag)
        case "hidden": return ("session.set_hidden", flag)
        default: return nil
        }
    }

    /// `method` for the stored chat `id` of `profile`. A gateway without the call keeps the original refusal.
    private static func socket(_ client: any GatewayClient, _ method: String, id: String, profile: String?,
                               _ extra: [String: JSONValue], refused: HTTPError) async throws -> JSONValue {
        var params = extra
        params["session_id"] = .string(id)
        if let profile { params["profile"] = .string(profile) }
        do {
            return try await client.call(method, .object(params), timeout: .seconds(20))
        } catch let error as RPCError where error.code == -32601 {
            throw refused
        }
    }

    /// Rename: `session.title` takes a live runtime, so the chat is resumed first (as a room's Stop does; a chat
    /// already open answers with its own runtime). An empty title (clear) has no socket form.
    private static func socketTitle(_ client: any GatewayClient, id: String, profile: String?, _ title: String,
                                    refused: HTTPError) async throws -> JSONValue {
        let resumed = try await socket(client, "session.resume", id: id, profile: profile, ["omit_messages": true], refused: refused)
        guard let runtime = resumed["session_id"]?.string, !runtime.isEmpty else { throw refused }
        var params: [String: JSONValue] = ["session_id": .string(runtime), "title": .string(title)]
        if let profile { params["profile"] = .string(profile) }
        do {
            return try await client.call("session.title", .object(params), timeout: .seconds(20))
        } catch let error as RPCError where error.code == -32601 {
            throw refused
        }
    }

    // MARK: - The fence

    /// Identities whose write never got an answer, by account, owner, chat, method and payload.
    private static let pending = Locked<[String: Identity]>([:])

    private static func fenced(_ client: any GatewayClient, id: String, profile: String?, method: String, payload: JSONValue,
                               send: (Identity?) async throws -> Data) async throws -> Data {
        let owner = ownerKey(account: client.account.id, profile: profile, id: id)
        let key = owner + "\u{1F}" + method + "\u{1F}" + canonical(payload)
        for attempt in 0..<2 {
            let identity: Identity
            if let kept = pending.value[key] {
                identity = kept
            } else {
                switch try await snapshot(client, id: id, profile: profile) {
                case .unfenced:
                    return try await send(nil)
                case .absent:
                    if method == "DELETE" { return try JSONValue.object(["ok": true, "already_absent": true]).encoded() }
                    throw HTTPError(status: 404, body: #"{"detail":"not_found"}"#)
                case .identity(let fresh):
                    identity = fresh
                    pending.mutate { $0[key] = fresh }
                }
            }
            do {
                let data = try await send(identity)
                // Acknowledged: every other kept identity for this chat is built on a revision now superseded.
                pending.mutate { kept in kept = kept.filter { !$0.key.hasPrefix(owner + "\u{1F}") } }
                return data
            } catch let error as HTTPError {
                // The gateway answered: the write was refused, never half-done.
                pending.mutate { $0[key] = nil }
                if attempt == 0, error.status == 409, ["revision_conflict", "stale_generation"].contains(detail(error)) { continue }
                throw error
            }
        }
        throw HTTPError(status: 409, body: #"{"detail":"revision_conflict"}"#)
    }

    enum Snapshot: Equatable { case unfenced, absent, identity(Identity) }

    /// The chat's revision now. A gateway without the route (404/405, or an answer that isn't the snapshot) is unfenced.
    static func snapshot(_ client: any GatewayClient, id: String, profile: String?) async throws -> Snapshot {
        let data: Data
        do {
            data = try await client.rest("GET", path(id) + "/mutation-snapshot", query: query(profile), body: nil)
        } catch let error as HTTPError where error.status == 404 || error.status == 405 {
            return .unfenced
        }
        return read(data)
    }

    static func read(_ data: Data) -> Snapshot {
        guard let json = try? JSONValue.parse(data), let exists = json["exists"]?.bool,
              let revision = whole(json["runtime_revision"]) else { return .unfenced }
        guard exists else { return .absent }
        return .identity(Identity(requestId: UUID().uuidString.lowercased(), revision: revision,
                                  generation: whole(json["runtime_generation"])))
    }

    // MARK: - Helpers

    private static func whole(_ value: JSONValue?) -> Int? {
        guard case .number(let n)? = value, n >= 0, n.rounded() == n, n < 9.007e15 else { return nil }
        return Int(n)
    }

    static func detail(_ error: HTTPError) -> String? {
        error.body.flatMap { try? JSONValue.parse(Data($0.utf8)) }?["detail"]?.string
    }

    private static func path(_ id: String) -> String { "/api/sessions/" + HistoryRequest.encodePathSegment(id) }

    private static func query(_ profile: String?) -> [URLQueryItem] {
        profile.map { [URLQueryItem(name: "profile", value: $0)] } ?? []
    }

    private static func ownerKey(account: String, profile: String?, id: String) -> String {
        [account, profile ?? "", id].joined(separator: "\u{1F}")
    }

    private static func canonical(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}
