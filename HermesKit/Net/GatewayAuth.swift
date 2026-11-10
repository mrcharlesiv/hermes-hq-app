// One signed-in account's credentials and how every request carries them (spec 01 §5.2–5.3, §6.2, §7, §8.3, §14):
// password accounts send the session cookies from their own jar; Nous accounts send `Authorization: Bearer` with
// cookies off. A 401 on an /api/ route runs one single-flight refresh, then the request is retried once. A refusal
// ends the session: the Keychain keeps only the address and username, and the connection goes to `signedOut`.
// [renew-alongside] A Nous token past half its lifetime but still valid is renewed alongside the request, which goes
// out at once with it; only a token in its last minute (D6) holds the request for the renewal (spec 01 §7.1).

import Foundation

actor GatewayAuth {
    nonisolated let base: URL
    nonisolated let key: String
    nonisolated let kind: GatewayAccount.Kind
    nonisolated let transport: HTTPTransport
    private let vault: AccountVault
    private let renewals: NousRenewals
    /// False for a throw-away check (a Nous sign-in verifying a fresh pair before it is saved): such an auth never
    /// writes to, adopts from or forgets the saved account, so a refused check cannot wipe a still-valid saved session.
    nonisolated let persisted: Bool
    /// The cookies Keychain holds for this account as far as this auth knows (read and written only on the vault
    /// queue): every cookie write is a compare-and-swap against it.
    private let cookieLedger: Locked<[SavedCookie]>

    /// The credentials in memory (cookies as last persisted; the live Nous pair).
    private(set) var stored: StoredAccount
    /// Verified by a sign-in's `/api/auth/me` or, on a restore, by the first ticket minted; only a verified session is
    /// written back.
    private(set) var verified: Bool
    /// Set once the gateway refused this session; every later request fails fast with it.
    private(set) var rejection: GatewayFailure?
    /// The one refresh in flight (rule 1): requests that need it await it; a renewal alongside runs it unawaited.
    private var refreshFlight: Task<Void, Error>?
    /// [perf-returns] Refreshes a request waited for: a dial notes whether its ticket did (the phone log's connect
    /// line, "(auth refreshed)"). [renew-alongside] A renewal alongside is not counted unless a 401 joins it.
    private(set) var refreshesRun = 0
    /// [renew-alongside] Renewals started alongside a request, and when the last failed one lets the next start
    /// (a failing renewal is not retried on every request while the token still works).
    private(set) var renewalsAlongside = 0
    private var alongsideRestsUntil: ContinuousClock.Instant?
    static let alongsideRest: Duration = .seconds(30)
    /// A Nous refresh the gateway couldn't finish (Nous slow or down: 503, a timeout, 429) may still have rotated the
    /// pair upstream, and each retry with the same refresh token risks the refusal that ends the session. So the next
    /// refresh of that pair waits a while, longer after each miss, and asks in between fail at once with the same answer
    /// (log study 2026-10-28: four refreshes in 7 s while Nous was down, then 401 session_expired and a sign-out).
    private var refreshRest: (pair: NousTokens, until: ContinuousClock.Instant, misses: Int, failure: GatewayFailure)?
    static let refreshRests: [Duration] = [.seconds(5), .seconds(15), .seconds(30), .seconds(60)]
    /// A launch's restore budget (spec 01 §5.2: 7 s for the whole restore, however many requests).
    private var deadline: ContinuousClock.Instant?
    private var closed = false
    private var onRejected: (@Sendable (GatewayFailure) -> Void)?
    /// [n20 B1] Who this auth is, in its log lines when it is not the gateway in use ("another gateway": the switcher's
    /// news check, whose failed renewals otherwise read like the active session's).
    nonisolated let logContext: String?
    /// [reliability] B16: where the cross-process Nous renewal lease lives (tests use their own folder, or none).
    private(set) var leaseDirectory: URL? = NousRenewalLease.directory
    func useLeaseDirectory(_ url: URL?) { leaseDirectory = url }

    init(stored: StoredAccount, base: URL, transport: HTTPTransport, vault: AccountVault, verified: Bool,
         persisted: Bool = true, renewals: NousRenewals = .shared, logContext: String? = nil) {
        self.stored = stored
        self.persisted = persisted
        self.logContext = logContext
        self.cookieLedger = Locked(stored.cookies ?? [])
        self.base = base
        self.key = stored.key
        self.kind = stored.isNous ? .nous : .password
        self.transport = transport
        self.vault = vault
        self.verified = verified
        self.renewals = renewals
        if !stored.isNous, let cookies = stored.cookies, !cookies.isEmpty, !verified { transport.installCookies(cookies) }
    }

    func setRejectionHandler(_ handler: @escaping @Sendable (GatewayFailure) -> Void) { onRejected = handler }

    func close() {
        closed = true
        onRejected = nil
    }

    /// [renewal-cancel] Waits (up to `limit`) for a Nous refresh in flight before its transport is invalidated. Closing
    /// the transport cancels the POST, and one cut off after Portal rotated the pair loses the successor while the
    /// spent refresh token stops working 5 minutes later: the account was signed out (log 2026-11-02: the news check
    /// for a second Hermes Cloud gateway started a renewal alongside its read, finished first and closed, cancelling
    /// the renewal ~1 s in, six times; Portal then answered session_expired at the next use).
    func settleRenewal(limit: Duration = .seconds(20)) async {
        guard let flight = refreshFlight else { return }
        let began = ContinuousClock.now
        await withChildTasks(of: Void.self) { group in
            group.addTask { _ = try? await flight.value }
            group.addTask { try? await Task.sleep(for: limit) }
            _ = await group.next()
            group.cancelAll()
        }
        let what = logContext.map { ", \($0)" } ?? ""
        AppLog.note("auth", "closing\(what): waited \(ConnectSteps.ms(began.duration(to: .now))) ms for the renewal in flight")
    }

    // MARK: Sending

    /// The route under the gateway's path prefix (`/api/…`), for pool and retry decisions.
    nonisolated func route(of url: URL?) -> String {
        guard let path = url?.path(percentEncoded: true) else { return "" }
        let prefix = base.path(percentEncoded: true)
        if !prefix.isEmpty, prefix != "/", path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
        return path
    }

    /// Sends with this account's credentials. Proactive Nous renewal on first attempts (`renewIfDue`); a 401 on an
    /// `/api/` route refreshes once (single flight) and retries once. Returns any status; callers map non-2xx.
    func send(_ request: URLRequest, retryOn401: Bool = true, pool: HTTPTransport.Pool? = nil) async throws -> (Data, HTTPURLResponse) {
        try ensureUsable()
        let route = route(of: request.url)
        if retryOn401 { try await renewIfDue() }
        let sentAccess = stored.nous?.accessToken
        let (data, response) = try await transport.data(for: decorate(request),
                                                        pool: pool ?? (GatewayAddress.isControlPath(route) ? .control : .bulk),
                                                        ceiling: GatewayAddress.responseLimit(path: route))
        if closed { throw GatewayFailure.connectionChanged }
        noteCookies(response)
        if response.statusCode == 401, retryOn401, route.contains("/api/") {
            try await refresh(sentAccess: sentAccess, trigger: "401")
            var again = request
            if let left = try budgetLeft() { again.timeoutInterval = min(request.timeoutInterval, left) }
            return try await send(again, retryOn401: false, pool: pool)
        }
        return (data, response)
    }

    /// Proactive Nous renewal before a first attempt (spec 01 §7.1). In the token's last minute (D6, `needsRenewal`)
    /// the request waits for it; past half its lifetime (`renewsAlongside`) it starts one and goes out at once with
    /// the current token, which a 401 would still recover (it joins that flight). Either way, a renewal that fails
    /// without a refusal leaves the current token in use.
    private func renewIfDue() async throws {
        guard kind == .nous, let tokens = stored.nous else { return }
        if tokens.needsRenewal() {
            do { try await refresh(sentAccess: tokens.accessToken, trigger: "due") }
            catch let failure as GatewayFailure where !failure.isRejection {
                // [ticket-deadline] Already expired and no new pair landed meanwhile: the gateway can only answer 401
                // (and a second renewal). Fail now; the caller's ladder asks again. 5 s past expiry, as the phone's
                // clock can run ahead of Portal's; a token that might still be valid is sent (a 401 still recovers).
                if tokens.expiresAt > 0, Date().timeIntervalSince1970 >= tokens.expiresAt + 5,
                   stored.nous?.samePair(tokens) == true { throw failure }
                // The current token still has time left (renewal starts early): send with it rather than fail.
                AppLog.note("auth", "proactive renewal failed (\(failure.code)); sending with the current token")
            }
            try ensureUsable()
        } else if tokens.renewsAlongside() {
            renewAlongside()
        }
    }

    /// [renew-alongside] Starts the single-flight renewal without waiting for it (none when one is already in flight,
    /// or a failed one is still resting). The flight itself persists the rotated pair before it is used (rule 3) and
    /// ends the session on a refusal; this only notes the outcome for the phone's log.
    private func renewAlongside() {
        guard refreshFlight == nil, rejection == nil, !closed else { return }
        if let rest = alongsideRestsUntil, ContinuousClock.now < rest { return }
        renewalsAlongside += 1
        let began = ContinuousClock.now
        let flight = startFlight(trigger: "alongside")
        Task {
            do {
                try await flight.value
                self.alongsideRestsUntil = nil
                // Content-free: a duration and the measured lifetime (settles spec 01 §21.1 from the phone's log).
                let lifetime = self.stored.nous?.lifetime.map { ", lifetime \(Int($0)) s" } ?? ""
                AppLog.note("net", "auth renewed alongside: \(ConnectSteps.ms(began.duration(to: .now))) ms\(lifetime)")
            } catch {
                let failure = GatewayFailure.from(error)
                if !failure.isRejection { self.alongsideRestsUntil = .now + Self.alongsideRest }
                AppLog.note("net", "auth renewal alongside failed (\(failure.code)): \(ConnectSteps.ms(began.duration(to: .now))) ms")
            }
        }
    }

    private func ensureUsable() throws {
        if let rejection { throw rejection }
        if closed { throw GatewayFailure.connectionChanged }
        guard GatewayAddress.reachable(base) else { throw GatewayFailure.tailscaleOff }
    }

    /// Nous: the bearer and no cookies, applied at send time so a retry carries the renewed token.
    private func decorate(_ request: URLRequest) -> URLRequest {
        var request = request
        if request.value(forHTTPHeaderField: "Content-Type") == nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if kind == .nous {
            if let tokens = stored.nous { request.setValue("Bearer " + tokens.accessToken, forHTTPHeaderField: "Authorization") }
            request.httpShouldHandleCookies = false
        }
        return request
    }

    // MARK: Transfers ([attachments] docs/spec/1x-attachments.md §13.1: uploads and downloads run their own task)

    /// The request as this account sends it (proactive Nous renewal, then cookies or the bearer), and the bearer sent.
    func prepareTransfer(_ request: URLRequest) async throws -> (URLRequest, String?) {
        try ensureUsable()
        try await renewIfDue()
        return (decorate(request), stored.nous?.accessToken)
    }

    /// A transfer's answer: its cookies are noted; true when the caller should send it again (a first 401 on an
    /// /api/ route, after one single-flight refresh).
    func finishTransfer(_ response: HTTPURLResponse, request: URLRequest, sentAccess: String?, retried: Bool) async throws -> Bool {
        if closed { throw GatewayFailure.connectionChanged }
        noteCookies(response)
        guard response.statusCode == 401, !retried, route(of: request.url).contains("/api/") else { return false }
        try await refresh(sentAccess: sentAccess, trigger: "401 transfer")
        return true
    }

    // MARK: Refresh (single flight)

    /// 401 recovery. Password: ask `/api/auth/me` (the gateway renews from the refresh cookie), then the Keychain's copy
    /// once. Nous: rotate the pair. A caller whose bearer was already replaced since it sent just retries; one that
    /// finds a refresh in flight (a renewal alongside included) waits for that one rather than start another.
    /// `trigger` says in the phone's log what asked for it (401, due, alongside, restore), never anything secret.
    func refresh(sentAccess: String?, trigger: String = "401") async throws {
        if let rejection { throw rejection }
        if kind == .nous, let sentAccess, let current = stored.nous?.accessToken, current != sentAccess { return }
        if refreshFlight == nil, let rest = refreshRest, let pair = stored.nous, rest.pair.samePair(pair), ContinuousClock.now < rest.until {
            AppLog.trace("auth", "refresh (\(trigger)) waits: \(rest.misses) unfinished, \(ConnectSteps.ms(ContinuousClock.now.duration(to: rest.until))) ms left")
            throw rest.failure
        }
        refreshesRun += 1                                // [perf-returns] this caller waits for a refresh
        try await startFlight(trigger: trigger).value
    }

    /// Notes a Nous refresh's outcome for `refreshRest`: an unfinished one rests that pair, anything else clears it.
    /// `after`: the gateway's `Retry-After` (1 to 60 s), which takes the place of the ladder's step.
    private func noteRefresh(_ failure: GatewayFailure?, pair: NousTokens?, after: TimeInterval? = nil) {
        guard kind == .nous else { return }
        guard let failure, let pair, [.unavailable, .timeout, .rateLimited].contains(failure) else { refreshRest = nil; return }
        let misses = (refreshRest?.pair.samePair(pair) == true ? refreshRest?.misses ?? 0 : 0) + 1
        let wait = after.map { Duration.milliseconds(Int(min(max($0, 1), 60) * 1000)) }
            ?? Self.refreshRests[min(misses, Self.refreshRests.count) - 1]
        refreshRest = (pair, .now + wait, misses, failure)
        AppLog.note("auth", "refresh unfinished (\(failure.code)) \(misses)×: the same pair waits \(ConnectSteps.ms(wait)) ms")
    }

    /// The refresh in flight, or a new one. The flight clears itself and, on a refusal, ends the session before any
    /// waiter resumes, so whoever started it (a request, or a renewal alongside nobody waits for) sees the same end.
    private func startFlight(trigger: String) -> Task<Void, Error> {
        if let refreshFlight { return refreshFlight }
        // Runs on this actor, so it cannot finish before `refreshFlight` is set below; one flight at a time, so the
        // flight it clears is itself.
        let sent = stored.nous
        let flight = Task {
            do {
                try await self.performRefresh(trigger: trigger)
                self.refreshFlight = nil
                self.noteRefresh(nil, pair: sent)
            } catch {
                self.refreshFlight = nil
                let failure = GatewayFailure.from(error)
                self.noteRefresh(failure, pair: sent, after: (error as? RetryLater)?.after)
                if failure.isRejection { self.reject(.sessionEnded) }
                throw failure
            }
        }
        refreshFlight = flight
        return flight
    }

    private func performRefresh(trigger: String) async throws {
        if kind == .nous {
            // [sign-out on update, 2026-10-23] Which process rotated the pair and why, in the phone's log (content-free):
            // the Share extension's rotations since the last refresh, then this one's outcome.
            for line in ShareAuthTrail.drain() { AppLog.note("net", "auth: the Share extension \(line)") }
            // [n20 B1] A rotation Keychain couldn't take earlier (the phone locked mid-flight) is written first, so a
            // launch's very first refresh does not read a stale pair because the retry was still waiting for the next
            // unlock or background move.
            if persisted { await renewals.retryUnsaved() }
            let began = ContinuousClock.now
            let what = logContext.map { "\(trigger), \($0)" } ?? trigger
            do {
                let how = try await refreshNous()
                if persisted { AppLog.note("net", "auth refresh (\(what)): \(how) in \(ConnectSteps.ms(began.duration(to: .now))) ms") }
            } catch {
                if persisted { AppLog.note("net", "auth refresh (\(what)) failed (\(GatewayFailure.from(error).code)) in \(ConnectSteps.ms(began.duration(to: .now))) ms") }
                throw error
            }
            return
        }
        do {
            try await checkMe(retry: false, timeout: 15)
            persistCookies()
            return
        } catch let failure as GatewayFailure where failure.isRejection {
            // Refused: the Keychain's copy of the cookies, once, if it differs from the jar.
        }
        let saved = vault.peek(key)?.cookies ?? []
        guard !saved.isEmpty, !SavedCookie.same(saved, transport.cookies(for: base)) else { throw GatewayFailure.sessionEnded }
        transport.installCookies(saved)
        try await checkMe(retry: false, timeout: 15)
        persistCookies()
    }

    /// Rotates the Nous pair; returns how, for the log ("rotated", "adopted a saved pair", …).
    private func refreshNous() async throws -> String {
        guard var tokens = stored.nous else { throw GatewayFailure.signedOut }
        // [n20 B1] Sign-out after updating: a renewal while the sign-in item can't be read can't save the successor,
        // so it would live only in memory and be lost if iOS ends the app before the next unlock — spending the
        // refresh token for nothing, since Portal ends the whole session on a replay. Never post it then. This comes
        // before the B16 lease below, so a locked app never takes or waits on it. `renewIfDue`'s own margin still
        // sends an unexpired current token while this holds; an already-expired one fails here, not as a sign-out
        // (`.keychainLocked` is not a rejection).
        if persisted, vault.isLocked { throw GatewayFailure.keychainLocked }
        // Rule 6: a pair rotated elsewhere (another client of this account) is the live one: adopt it.
        var adopted = false
        if let kept = await rotatedElsewhere(than: tokens) {
            stored.nous = kept
            tokens = kept
            adopted = true
            AppLog.note("auth", "adopted a Nous pair rotated elsewhere")
            if !kept.needsRenewal() { return "adopted a pair saved by another process" }
        }
        // [reliability] B16: the Share extension may be renewing this same pair right now. Wait for its pair rather
        // than send the same refresh token a second time (a replay ends the session). Only a saved account has a
        // Keychain pair the extension can share.
        var lease: NousRenewalLease.Lease?
        if persisted {
            let spent = tokens
            let (held, waited) = await NousRenewalLease.acquireOrWait(account: key, in: leaseDirectory) {
                await self.rotatedElsewhere(than: spent) != nil
            }
            lease = held
            if waited, let kept = await rotatedElsewhere(than: tokens) {
                stored.nous = kept
                tokens = kept
                adopted = true
                AppLog.note("net", "auth: waited for the Share extension's renewal")
                if !kept.needsRenewal() { return "adopted the pair the Share extension renewed meanwhile" }
                // Already due again (unlikely): this process renews it, holding its own lease.
                lease = NousRenewalLease.acquire(account: key, in: leaseDirectory)
            }
        }
        defer { lease?.release() }
        // A refusal may be a race, not an ended session: another process (the Share extension) spent this same pair
        // and saved its successor while ours was out. That successor is read once and used (renewed if due); a second
        // refusal ends the session as before.
        for attempt in 0..<2 {
            let url = try GatewayAddress.endpoint(base: base, path: "/auth/native/refresh")
            let timeout = try budgetLeft().map { min(15, $0) } ?? 15
            let transport = self.transport, vault = self.vault, key = self.key
            let outcome = await renewals.renew(key, tokens,
                post: { sent in await GatewayAuth.postRefresh(url, sent, timeout: timeout, transport: transport) },
                keep: { sent, renewed in vault.renewNous(key, sent: sent, renewed: renewed) })
            if closed { throw GatewayFailure.connectionChanged }
            switch outcome {
            case .tokens(let renewed):
                guard renewed.userId == tokens.userId else { throw GatewayFailure.sessionEnded } // never another account's
                stored.nous = renewed
                // Persist before use (rule 3). `keep` already wrote it; this covers a save that raced the rotation.
                _ = vault.renewNous(key, sent: tokens, renewed: renewed)
                if let lifetime = renewed.lifetime { AppLog.note("auth", "nous access token lifetime \(Int(lifetime)) s (renewed)") }
                return attempt > 0 ? "rotated the pair another process saved after a refusal"
                    : adopted ? "rotated a pair saved by another process" : "rotated"
            case .refused:
                guard attempt == 0, let kept = await rotatedElsewhere(than: tokens) else { throw GatewayFailure.sessionEnded }
                stored.nous = kept
                tokens = kept
                AppLog.note("net", "auth refresh refused; another process saved a newer pair meanwhile: using it")
                if !kept.needsRenewal() { return "adopted the pair another process saved after a refusal" }
            case .unavailable(let status, let after):
                let failure = status == 429 ? GatewayFailure.rateLimited : GatewayFailure.from(status: status, body: nil)
                if let after { throw RetryLater(failure: failure, after: after) }
                throw failure
            case .failed(let failure): throw failure
            }
        }
        throw GatewayFailure.sessionEnded
    }

    /// The Keychain's pair for this account when another client or process rotated `tokens` and saved the successor
    /// (same user, not a pair this run already spent); read fresh from the Keychain each time.
    private func rotatedElsewhere(than tokens: NousTokens) async -> NousTokens? {
        guard persisted, let kept = vault.peek(key)?.nous, !kept.samePair(tokens), kept.userId == tokens.userId,
              await renewals.latest(kept).samePair(kept), await renewals.latest(tokens).samePair(tokens) else { return nil }
        return kept
    }

    /// POST /auth/native/refresh for one pair (cookies off). Another account's tokens in the answer are a refusal.
    nonisolated static func postRefresh(_ url: URL, _ tokens: NousTokens, timeout: TimeInterval, transport: HTTPTransport) async -> NousRenewals.Outcome {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["refresh_token": tokens.refreshToken, "provider": "nous"])
        do {
            let (data, response) = try await transport.data(for: request, pool: .control, ceiling: 1 << 20)
            switch NousGatewayProtocol.answer(status: response.statusCode, body: data) {
            case .tokens(let renewed): return renewed.userId == tokens.userId ? .tokens(renewed) : .refused
            case .refused: return .refused
            case .unavailable(let status):
                return .unavailable(status, retryAfter: RetryLater.parse(response.value(forHTTPHeaderField: "Retry-After")))
            }
        } catch {
            return .failed(GatewayFailure.from(error))
        }
    }

    // MARK: Verification

    /// GET /api/auth/me: verified (D4) means 2xx and a body that parses as a JSON object; nothing inside is read.
    func checkMe(retry: Bool, timeout: TimeInterval) async throws {
        let url = try GatewayAddress.endpoint(base: base, path: "/api/auth/me")
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await send(request, retryOn401: retry)
        switch response.statusCode {
        case 200..<300: try Self.requireObject(data)
        case 401, 403: throw GatewayFailure.sessionEnded
        case 429:
            // [offline] §3.6: a busy gateway's `Retry-After` is kept (as the ticket request keeps it), so the offline
            // screen's countdown never promises a dial the gateway asked us not to make.
            guard let wait = RetryLater.parse(response.value(forHTTPHeaderField: "Retry-After")) else { throw GatewayFailure.rateLimited }
            throw RetryLater(failure: .rateLimited, after: wait)
        case 404:
            // [offline] §3.5: the saved address answers, but has no session check. A Hermes from before gateway
            // sign-in still answers its public status (the sign-in form's rule, `SignInFlows.passwordSignIn`);
            // anything else there is not Hermes. One unauthenticated-safe read, only on this path.
            var probe = URLRequest(url: try GatewayAddress.endpoint(base: base, path: "/api/status"), timeoutInterval: min(timeout, 5))
            probe.setValue("application/json", forHTTPHeaderField: "Accept")
            let answer = try? await send(probe, retryOn401: false)
            let failure = Self.missingSessionCheck(status: answer?.1.statusCode, body: answer?.0)
            AppLog.trace("auth", "session check missing (404): status probe \(answer?.1.statusCode ?? -1) -> \(failure.code)")
            throw failure
        default: throw GatewayFailure.from(status: response.statusCode, body: String(decoding: data.prefix(512), as: UTF8.self))
        }
    }

    /// [offline] §3.5: what a 404 on the session check means, from the address's `/api/status` answer (nil = none).
    nonisolated static func missingSessionCheck(status: Int?, body: Data?) -> GatewayFailure {
        if status == 200, let body, (try? JSONValue.parseFast(body))?["version"]?.string != nil { return .gatewayOutdated }
        return .notHermes
    }

    /// A 2xx body must be a JSON object: non-JSON is "not Hermes"; other JSON is an invalid answer.
    nonisolated static func requireObject(_ data: Data) throws {
        guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { throw GatewayFailure.notHermes }
        guard value is [String: Any] else { throw GatewayFailure.gatewayError("invalid gateway response") }
    }

    /// Launch restore (spec 01 §5.2) or the check right after a Nous browser sign-in: renew a Nous pair first if due,
    /// then one `/api/auth/me` (password: never retried; the gateway renews from the refresh cookie on that request).
    /// A refusal ends the session (Keychain keeps url + username); a network failure leaves it for the next try.
    func verify(budget: Duration?) async throws {
        try ensureUsable()
        guard let budget else { return try await verifyNow() }
        // The budget bounds the whole check, including a control request still waiting for a network path.
        // The check is never awaited past the deadline: a Nous renewal it started (on the control pool, which may
        // wait up to 15 s for a network path) runs on and persists its rotation, but the dial goes offline on time.
        let end = ContinuousClock.now + budget
        deadline = end
        defer { deadline = nil }
        try await untilDeadline(end, late: { GatewayFailure.timeout }) { try await self.verifyNow() }
    }

    private func verifyNow() async throws {
        do {
            switch kind {
            case .nous:
                if let tokens = stored.nous, tokens.needsRenewal() { try await refresh(sentAccess: tokens.accessToken, trigger: "restore") }
                try await checkMe(retry: true, timeout: try budgetLeft() ?? 15)
            case .password:
                try await checkMe(retry: false, timeout: try budgetLeft() ?? 15)
            }
        } catch let failure as GatewayFailure where failure.isRejection {
            reject(.sessionEnded)
            throw GatewayFailure.sessionEnded
        }
        verified = true
        persistCookies()
    }

    /// Seconds left of the restore budget (nil when none); under half a second is a timeout.
    private func budgetLeft() throws -> TimeInterval? {
        guard let deadline else { return nil }
        let left = ContinuousClock.now.duration(to: deadline)
        guard left >= .milliseconds(500) else { throw GatewayFailure.timeout }
        return Double(left.components.seconds) + Double(left.components.attoseconds) / 1e18
    }

    // MARK: Tickets

    /// POST /api/auth/ws-ticket `{}` (spec 01 §9.1). 401 → refresh → retry once; still 401/403 ends the session.
    /// Sent on the pool that fails fast: the connection dials only while the network path is up, so a refused or
    /// unreachable gateway (Hermes restarting) is an answer for the back-off ladder, not a reason to wait for
    /// connectivity until the 15 s resource limit (verification round 3: every restart cost ~16 s of "Reconnecting").
    func mintTicket(timeout: Duration) async throws -> String {
        let url = try GatewayAddress.endpoint(base: base, path: "/api/auth/ws-ticket")
        var request = URLRequest(url: url, timeoutInterval: Double(timeout.components.seconds))
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await send(request, pool: .bulk)
        } catch let lost as URLError where lost.code == .networkConnectionLost && lost.onReusedConnection {
            // A pooled connection that died while the app was away answers the first request after the return with
            // -1005 in a few ms, and URLSession drops it. One retry at once dials fresh instead of waiting for the
            // back-off ladder (log study 2026-10-28: a quarter of the iPhone's returns, up to 2.5 s more to ready).
            // A fresh connection dropped at once is the gateway's answer: that one goes to the redial rules.
            AppLog.trace("net", "ticket: pooled connection lost (\(lost.code.rawValue)); retrying at once")
            (data, response) = try await send(request, pool: .bulk)
        }
        switch response.statusCode {
        case 200..<300:
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw GatewayFailure.notHermes }
            guard let ticket = object["ticket"] as? String, !ticket.isEmpty else { throw GatewayFailure.gatewayError("missing ticket") }
            // [connect-fast] A minted ticket is the session check (the desktop's way): a restored session is now
            // verified, so its cookies are written back as `verifyNow` would have.
            if !verified {
                verified = true
                persistCookies()
                AppLog.trace("auth", "ticket mint verified the restored session")
            }
            return ticket
        case 401, 403:
            reject(.sessionEnded)
            throw GatewayFailure.sessionEnded
        case 404, 405:
            // [connect-fast] The address answers but has no ticket route: not Hermes, or a Hermes from before gateway
            // sign-in (the same `/api/status` probe the session check made, `missingSessionCheck`).
            var probe = URLRequest(url: try GatewayAddress.endpoint(base: base, path: "/api/status"), timeoutInterval: 5)
            probe.setValue("application/json", forHTTPHeaderField: "Accept")
            let answer = try? await send(probe, retryOn401: false)
            let failure = Self.missingSessionCheck(status: answer?.1.statusCode, body: answer?.0)
            AppLog.trace("auth", "ticket route missing (\(response.statusCode)): status probe \(answer?.1.statusCode ?? -1) -> \(failure.code)")
            throw failure
        case 429:
            guard let wait = RetryLater.parse(response.value(forHTTPHeaderField: "Retry-After")) else { throw GatewayFailure.rateLimited }
            throw RetryLater(failure: .rateLimited, after: wait)
        default:
            throw GatewayFailure.from(status: response.statusCode, body: String(decoding: data.prefix(512), as: UTF8.self))
        }
    }

    // MARK: Persistence

    /// The gateway renews a cookie session by setting fresh cookies on whatever response it renewed on.
    private func noteCookies(_ response: HTTPURLResponse) {
        guard kind == .password, response.value(forHTTPHeaderField: "Set-Cookie") != nil else { return }
        persistCookies()
    }

    /// Writes the jar's cookies to Keychain when they changed (name + value), for a verified, unrefused session only.
    /// Written on the vault queue as a compare-and-swap against what this auth last saw in Keychain, so a write queued
    /// just before a refusal, a sign-out or a new sign-in of the same account can never bring old cookies back.
    func persistCookies() {
        guard persisted, kind == .password, verified, rejection == nil, !closed else { return }
        let cookies = transport.cookies(for: base)
        guard !cookies.isEmpty, !SavedCookie.same(cookies, stored.cookies ?? []) else { return }
        stored.cookies = cookies
        let vault = self.vault, key = self.key, ledger = cookieLedger
        vault.later {
            if vault.swapCookies(key, expected: ledger.value, new: cookies) { ledger.set(cookies) }
        }
    }

    /// Backgrounding: keep the session current in Keychain (spec 01 §13.7).
    func persistForBackground() async {
        persistCookies()
        let vault = self.vault
        await renewals.retryUnsaved { key, sent, renewed in vault.renewNous(key, sent: sent, renewed: renewed) }
    }

    /// The session ended: fail fast from now on, forget the secret (keep the prefilled form), tell the connection.
    private func reject(_ failure: GatewayFailure) {
        guard rejection == nil else { return }
        rejection = failure
        AppLog.note("auth", "session refused by the gateway (\(failure.code))")
        if kind == .password { transport.clearCookies() }
        if persisted { vault.forgetSession(key) }
        stored = stored.withoutSession
        onRejected?(failure)
    }
}
