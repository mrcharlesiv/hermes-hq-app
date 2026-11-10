// [working-ledger] Which chats run a turn right now, by the gateway's own word, for the Sessions list (tester,
// 2026-11-09: "The session is running and adding a skill from the marketplace but it isn't showing as running in the
// session list"). The list only knew the turns this app's sockets heard: a turn the messaging gateway runs (another
// bot's message, Telegram, Discord, a job's hand-off) said Working… only while its chat was open, and stopped saying it
// the moment you went back to the list; one started on the desktop, another phone, or before the app was relaunched
// never said it at all. The Hermes HQ add-on names them all: `GET sessions/working` (0.9.6+, the gateway's durable
// ledger) and `GET serve/working` (0.9.20+, the turns `hermes serve` runs in memory). While a list is on screen and the
// app is in front, both are read every few seconds; a route the add-on lacks is left alone for a while.

import Foundation

@MainActor final class WorkingLedgerWatch {
    nonisolated static let ledgerPath = ExternalTurn.ledgerPath
    nonisolated static let servePath = "/api/plugins/hermes-hq-push/serve/working"

    private let client: any GatewayClient
    /// How often the routes are read while wanted (tests shorten it).
    var interval: Duration = .seconds(5)
    /// A route that answered 404 (an older add-on) or 503 (`serve/working` outside the serving process) is asked again
    /// after this long.
    var missingRecheck: TimeInterval = 600
    var now: () -> Date = { Date() }
    /// The stored ids changed (the Sessions rows' Working… follows).
    var onChange: (() -> Void)?

    /// Stored ids the gateway runs a turn in, as last read.
    private(set) var storedIds: Set<String> = []
    private var wanted = false
    private var loop: Task<Void, Never>?
    private var missingSince: [String: Date] = [:]
    /// Ids whose turn this app saw end, with when: a read that went out before then still names them, and is not believed.
    private var endedAt: [String: Date] = [:]

    init(client: any GatewayClient) { self.client = client }

    isolated deinit { loop?.cancel() }

    /// A list is on screen with the app in front (true), or not: the reads start at once, or stop. What was read is
    /// kept meanwhile and read again as soon as it is wanted again.
    func setWanted(_ on: Bool) {
        guard wanted != on else { return }
        wanted = on
        loop?.cancel()
        loop = nil
        guard on else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.wanted else { return }
                await self.readOnce()
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: self.interval)
            }
        }
    }

    /// A turn of this app's ended in this chat (its own events said so): the row stops saying Working… now, not at the
    /// next read, and a read already in the air doesn't bring it back.
    func turnEnded(_ storedId: String) {
        endedAt[storedId] = now()
        if storedIds.remove(storedId) != nil { onChange?() }
    }

    func stop() {
        wanted = false
        loop?.cancel()
        loop = nil
        if !storedIds.isEmpty { storedIds = []; onChange?() }
    }

    /// One read of both routes. Nil from a route means it wasn't read (missing, or failed): what it said last stays.
    func readOnce() async {
        let started = now()
        async let ledger = read(Self.ledgerPath)
        async let serve = read(Self.servePath)
        let (fromLedger, fromServe) = await (ledger, serve)
        guard !Task.isCancelled else { return }
        if fromLedger == nil && fromServe == nil { return }
        var next = (fromLedger ?? lastBy[Self.ledgerPath] ?? []).union(fromServe ?? lastBy[Self.servePath] ?? [])
        if let fromLedger { lastBy[Self.ledgerPath] = fromLedger }
        if let fromServe { lastBy[Self.servePath] = fromServe }
        // An end this app heard after the read went out outranks the read.
        endedAt = endedAt.filter { now().timeIntervalSince($0.value) < 60 }
        next = next.filter { id in endedAt[id].map { $0 < started } ?? true }
        guard next != storedIds else { return }
        AppLog.trace("sessions", "working ledger: \(next.count) chat(s) running")
        storedIds = next
        onChange?()
    }

    private var lastBy: [String: Set<String>] = [:]

    private func read(_ path: String) async -> Set<String>? {
        if let since = missingSince[path], now().timeIntervalSince(since) < missingRecheck { return nil }
        do {
            let json = try await PagesREST.json(client, "GET", path, timeout: 10)
            missingSince[path] = nil
            return Self.ids(json)
        } catch {
            let status = PagesREST.status(error)
            if status == 404 || status == 503 {
                if missingSince[path] == nil { AppLog.trace("sessions", "working ledger: \(path) answered \(status ?? 0), asked again later") }
                missingSince[path] = now()
                lastBy[path] = nil
                return []
            }
            return nil
        }
    }

    /// The stored ids a `{"sessions": [{"id": …}]}` answer names.
    nonisolated static func ids(_ json: JSONValue) -> Set<String> {
        Set((json["sessions"]?.array ?? []).compactMap { row in row["id"]?.string.flatMap { $0.isEmpty ? nil : $0 } })
    }
}
