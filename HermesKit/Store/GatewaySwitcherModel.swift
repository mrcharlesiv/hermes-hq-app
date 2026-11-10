// The news check for gateways that aren't in use (spec 1x-settings §4.7): for each other signed-in gateway, the bots its
// parked Bots list last saw have their one chat read by id with that gateway's own session. Push can't do this (only
// the gateway in use is registered). Counts live in memory. Port of `checkOtherGateways` (`S/gateway-switcher.ts`).

import Foundation
import Observation
import os


@MainActor @Observable
final class GatewaySwitcherModel {
    /// Other gateways' bots with news, by account id (absent: not checked yet, or couldn't be).
    private(set) var counts: [String: Int] = [:]
    /// Accounts whose gateway refused their saved session in a check (memory only): shown "Signed Out", and a tap signs
    /// in again first. The Keychain copy stays (a 403 from a proxy or a gateway mid-restart mustn't sign anyone out); a
    /// later check that reads fine clears the mark. A refusal after renewal has already ended the session in Keychain
    /// (`GatewayAuth`), which the store then says itself.
    private(set) var expired: Set<String> = []
    /// Accounts whose gateway didn't answer their last check (memory only): the title menu says "Can’t Reach". Only a
    /// gateway with a session and parked chats is read, so one with neither is never marked; a check that reads (or is
    /// refused) clears it.
    private(set) var unreachable: Set<String> = []
    private(set) var lastCheckEnded: Date?

    @ObservationIgnored let store: AccountStore
    @ObservationIgnored let directory: URL
    /// The account in use (its own Bots list shows its dots).
    @ObservationIgnored var currentId: () -> String? = { nil }
    /// Makes the REST-only client for a parked account (tests replace it).
    @ObservationIgnored var makeProbe: (StoredAccount) -> any ParkedAccountReading = { AccountProbe(stored: $0) }
    /// Called after counts or the saved accounts change.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private var parked: [String: [ParkedChat]] = [:]
    @ObservationIgnored private var checking: Task<Void, Never>?
    @ObservationIgnored private var schedule: Task<Void, Never>?
    @ObservationIgnored private var active = true
    /// A gateway that didn't answer is asked again after 6, 12, 24, then every 30 minutes instead of every check
    /// (owner, build 408: "the gateway timing out": a saved gateway that is off cost a 15 s sign-in renewal and a
    /// timeout every 3 minutes). Opening the title menu asks at once. Memory only.
    @ObservationIgnored private var misses: [String: Int] = [:]
    @ObservationIgnored private var nextTry: [String: Date] = [:]
    @ObservationIgnored var now: () -> Date = Date.init

    static let firstCheck: Duration = .seconds(4)
    static let every: TimeInterval = 180
    static let recheckAfter: TimeInterval = 30
    static let unreachableCap: TimeInterval = 1800

    /// How long a gateway that missed `misses` checks in a row waits before the next one.
    static func backoff(misses: Int) -> TimeInterval {
        min(unreachableCap, every * pow(2, Double(max(1, misses))))
    }

    init(store: AccountStore, directory: URL) {
        self.store = store
        self.directory = directory
    }

    /// Two or more saved gateways: the titles become switchers and the check runs.
    var isShown: Bool { store.accounts.count > 1 }

    var otherNews: Int {
        let current = currentId()
        return store.accounts.filter { $0.id != current }.reduce(0) { $0 + (counts[$1.id] ?? 0) }
    }

    // MARK: Schedule (`installGatewaySwitcher`)

    /// 4 s after launch, then every 3 minutes while the app is active (× 3 in Low Power Mode or when hot).
    func start() {
        guard schedule == nil else { return }
        schedule = Task { [weak self] in
            try? await Task.sleep(for: Self.firstCheck)
            while !Task.isCancelled {
                guard let self else { return }
                if self.active, self.isShown { await self.check(force: false) }
                await PowerPolls.wait(.seconds(Self.every), floor: .zero)   // [offline] §6.9: one rule for every poll
            }
        }
    }

    func stop() {
        schedule?.cancel(); schedule = nil
        checking?.cancel(); checking = nil
    }

    func appDidBecomeActive() {
        active = true
        checkSoon(force: false)
    }

    func appDidEnterBackground() { active = false }

    /// On return to the app and when the title menu opens: a check unless the last one ended under 30 s ago. The menu
    /// (`force`) also asks the gateways that are waiting out a backoff.
    func checkSoon(force: Bool = true) {
        guard isShown else { return }
        if let ended = lastCheckEnded, Date().timeIntervalSince(ended) <= Self.recheckAfter { return }
        Task { await check(force: force) }
    }

    /// The saved gateways changed (add, remove, rename, sign-out): parked reads are made again, removed counts go.
    func accountsChanged() {
        parked = [:]
        let ids = Set(store.accounts.map(\.id))
        counts = counts.filter { ids.contains($0.key) }
        expired = expired.filter { ids.contains($0) }
        unreachable = unreachable.filter { ids.contains($0) }
        misses = misses.filter { ids.contains($0.key) }
        nextTry = nextTry.filter { ids.contains($0.key) }
        onChange?()
    }

    /// A switch landed on `id`: its news is now its own Bots list's dots (and its session was good enough to switch).
    func switched(to id: String) {
        counts[id] = nil
        expired.remove(id)
        unreachable.remove(id)
        misses[id] = nil
        nextTry[id] = nil
        parked = [:]
        onChange?()
    }

    /// Whether `id`'s saved session can be used without signing in again first.
    func hasUsableSession(_ account: GatewayAccount) -> Bool {
        (store.stored(account)?.hasSession ?? false) && !expired.contains(account.id)
    }

    // MARK: The check

    /// One gateway at a time, one check at a time. A gateway that can't be reached keeps its last count; one whose session
    /// was refused (or that has none) shows none.
    func check(force: Bool = true) async {
        if let checking { return await checking.value }
        let task = Task { [weak self] () -> Void in await self?.performCheck(force: force) }
        checking = task
        await task.value
        checking = nil
    }

    private func performCheck(force: Bool) async {
        let current = currentId()
        for account in store.accounts where account.id != current {
            if Task.isCancelled { return }
            guard let stored = store.stored(account) else { continue }
            if !force, let next = nextTry[account.id], now() < next {
                AppLog.trace("gateways", "news check \(AppLog.tag(Self.host(account))): can't reach, next try in \(Int(next.timeIntervalSince(now()) / 60) + 1) min")
                continue
            }
            var count: Int?
            if !stored.hasSession {
                count = 0
                unreachable.remove(account.id)
            } else {
                let chats = parkedChats(account)
                AppLog.trace("gateways", "parked chats \(chats.count) for \(AppLog.tag(Self.host(account)))")
                if chats.isEmpty {
                    count = 0
                    unreachable.remove(account.id)
                } else {
                    let probe = makeProbe(stored)
                    var live: [ParkedChatLive] = []
                    var refused = false, unreachable = false
                    for chat in chats {
                        do {
                            switch try await probe.read(id: chat.id, profile: chat.profile) {
                            // Keyed by the id asked for: the gateway resolves prefixes and lineage, so its answer's
                            // own `id` may differ (`AG/hermes_cli/web_routers/sessions.py:562-582`).
                            case .session(let json): if let row = ParkedChatLive(json: json, id: chat.id) { live.append(row) }
                            case .refused: refused = true
                            case .missing: break
                            }
                        } catch {
                            AppLog.swallowed("gateways", "news read", error)
                            unreachable = true
                        }
                        if refused || unreachable { break }
                    }
                    probe.finish()
                    if unreachable {
                        let missed = (misses[account.id] ?? 0) + 1
                        misses[account.id] = missed
                        nextTry[account.id] = now().addingTimeInterval(Self.backoff(misses: missed))
                        AppLog.note("gateways", "news check \(AppLog.tag(Self.host(account))): can't reach (\(missed) in a row), "
                                    + "next try in \(Int(Self.backoff(misses: missed) / 60)) min")
                    } else {
                        misses[account.id] = nil
                        nextTry[account.id] = nil
                    }
                    if unreachable != self.unreachable.contains(account.id) {
                        if unreachable { self.unreachable.insert(account.id) } else { self.unreachable.remove(account.id) }
                        onChange?()
                    }
                    if refused {
                        count = 0
                        if expired.insert(account.id).inserted { onChange?() }
                        // A refusal after renewal ended the session in Keychain itself (`GatewayAuth`): read it back.
                        _ = try? await store.reloadOffMain()
                    } else if !unreachable {
                        count = GatewayNews.unreadCount(chats, live: live)
                        if expired.remove(account.id) != nil { onChange?() }
                    }
                }
            }
            AppLog.trace("gateways", "news check \(AppLog.tag(Self.host(account))): \(count.map(String.init) ?? "kept")")
            guard let count, store.accounts.contains(where: { $0.id == account.id }) else { continue }
            if counts[account.id] != count {
                counts[account.id] = count
                onChange?()
            }
        }
        lastCheckEnded = Date()
        onChange?()
    }

    /// For logs only, and only as private data (a Tailscale host name says whose machine it is).
    private static func host(_ account: GatewayAccount) -> String { account.baseURL.host() ?? "" }

    /// The parked roster and unread state of an account, read once until the saved accounts change.
    private func parkedChats(_ account: GatewayAccount) -> [ParkedChat] {
        if let known = parked[account.id] { return known }
        let roster = RosterDisk.read(RosterCacheFile.self, from: RosterDisk.url(directory, RosterDisk.rosterKind, account))
        let state = RosterDisk.read(BotDeviceState.self, from: RosterDisk.url(directory, RosterDisk.botStateKind, account))
        let chats = GatewayNews.parkedChats(roster: roster?.profiles ?? [], state: state)
        parked[account.id] = chats
        return chats
    }
}

/// What the news check needs from a parked account's client (tests fake it).
nonisolated protocol ParkedAccountReading: Sendable {
    func read(id: String, profile: String?) async throws -> AccountProbe.Answer
    func finish()
}

extension AccountProbe: ParkedAccountReading {
    nonisolated func read(id: String, profile: String?) async throws -> Answer { try await session(id: id, profile: profile) }
    nonisolated func finish() { close() }
}
