// [share] One share, start to finish, by the extension alone (docs/spec/3x-share.md §6, §7.3, §7.4, §7.9).
// Port of build 240's `ShareSender` (DispatchShareKit.swift:372-694).
//
// It talks to the gateway with its own throwaway URLSession and its own small socket: never the app's client, never
// the app's session. The app is not launched, woken or messaged. Nothing here signs in, creates a chat or keeps a
// share to send later (spec D17). Nothing is logged.

import Foundation

nonisolated struct ShareAttachment: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case image, file }
    let kind: Kind
    /// A file the extension owns (staged out of the item provider); removed by the caller after the send.
    let file: URL
    /// The name the gateway stores it under (`ShareRules.safeName`).
    let name: String
}

nonisolated struct ShareRequest: Sendable {
    let bot: ShareBot
    /// The person's own words (may be empty).
    let message: String
    /// Text and links that were shared.
    let shared: [String]
    let attachments: [ShareAttachment]
    /// The attachment limit in bytes.
    let limit: Int
    /// Ask Bot (Shortcuts): seconds to wait for the bot's reply after sending; 0 (a share) waits for nothing.
    let replyWait: Double

    init(bot: ShareBot, message: String, shared: [String] = [], attachments: [ShareAttachment] = [], limit: Int = ShareRules.defaultLimitBytes,
         replyWait: Double = 0) {
        self.bot = bot; self.message = message; self.shared = shared; self.attachments = attachments; self.limit = limit
        self.replyWait = replyWait
    }
}

nonisolated enum ShareStep: Equatable, Sendable { case connecting, uploading(Int, Int), sending }

nonisolated struct ShareResult: Equatable, Sendable {
    /// The stored id of the chat the share went to.
    let session: String
    /// What the gateway answered prompt.submit with (`streaming`, `queued`, …); any of them counts as sent.
    let status: String
    /// The session (cookies, or a Nous token pair) was renewed and written back to the Keychain for the app.
    let renewedCookies: Bool
    /// Ask Bot: how the wait for the reply ended (nil when nothing waited).
    var reply: ShareReply? = nil
}

nonisolated final class ShareSender: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    typealias Connect = @Sendable (URLSession, URL) async throws -> any ShareRPC

    private let keychain: any ShareKeychainStore
    private let interfaces: @Sendable () -> [ShareReach.Interface]
    private let protocols: [AnyClass]
    private let connect: Connect
    private let progress: @Sendable (ShareStep) -> Void
    private var account: ShareAccount?
    /// A Nous account's live token pair: every request carries its access token and no cookies.
    private var nous: ShareNous?
    private var persisted: [[String: Any]] = []
    private var renewed = false
    private var renewedNous = false
    private var made: URLSession?
    /// Staging folders on the gateway that hold a copy this share uploaded and has not handed over or removed.
    private var uploaded: [String] = []
    /// [reliability] B16: where the cross-process Nous renewal lease lives (tests use their own folder).
    var leaseDirectory: URL? = NousRenewalLease.directory

    /// `protocols`: URLProtocol stubs (tests). `connect`: how the socket is opened (tests put a stub socket here).
    init(keychain: any ShareKeychainStore = SystemShareKeychain(),
         interfaces: @escaping @Sendable () -> [ShareReach.Interface] = ShareReach.systemInterfaces,
         protocols: [AnyClass] = [],
         connect: @escaping Connect = { try await ShareSocket.open(session: $0, url: $1) },
         progress: @escaping @Sendable (ShareStep) -> Void = { _ in }) {
        self.keychain = keychain; self.interfaces = interfaces; self.protocols = protocols
        self.connect = connect; self.progress = progress
    }

    /// Made on first use (a share refused before its first request never makes one); the session retains this sender
    /// as its delegate until `finish()` invalidates it.
    private var session: URLSession {
        if let made { return made }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 15 * 60
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        if !protocols.isEmpty { configuration.protocolClasses = protocols + (configuration.protocolClasses ?? []) }
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        made = session
        return session
    }

    /// Ends this sender's session (its cookies and connections go with it).
    func finish() { made?.invalidateAndCancel(); made = nil }

    /// The account the sheet may share for: the Keychain's current account, signed in (cookies, or a Nous pair), and
    /// the one the app's roster belongs to. The checks run in the order the blocked screen names them (§7.8).
    static func account(keychain: any ShareKeychainStore = SystemShareKeychain(), roster: ShareRoster?) throws -> ShareAccount {
        guard let data = try keychain.read() else { throw ShareFailure.signedOut }
        guard let account = ShareAccounts.current(in: data) else { throw ShareFailure.signedOut }
        if ShareAccounts.isLegacyPasswordItem(data) { throw ShareFailure.needsApp }       // build 89: the app migrates it
        guard !account.cookies.isEmpty || account.nous != nil else { throw ShareFailure.signedOut }
        guard let roster else { throw ShareFailure.noRoster }
        guard roster.account == account.key else { throw ShareFailure.otherAccount }
        return account
    }

    /// Step 0 of §6.2, the part that needs no Keychain and no network.
    static func check(_ request: ShareRequest) throws {
        guard request.bot.canReceive else { throw ShareFailure.noChat }
        let images = request.attachments.filter { $0.kind == .image }, files = request.attachments.filter { $0.kind == .file }
        guard images.count <= ShareRules.maxImages, files.count <= ShareRules.maxFiles else {
            throw ShareFailure.refused("Share at most 10 photos and 10 files at a time.")
        }
        let text = ShareRules.promptText(message: request.message, shared: request.shared, fileRefs: [], hasImages: !images.isEmpty)
        guard !text.isEmpty || !request.attachments.isEmpty else { throw ShareFailure.nothingToSend }
        for item in request.attachments {
            let bytes = (try? item.file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard bytes > 0 else { throw ShareFailure.unreadable(item.name) }
            guard ShareRules.fits(bytes: bytes, limit: request.limit) else { throw ShareFailure.tooLarge(item.name) }
        }
    }

    @concurrent
    func send(_ request: ShareRequest, roster: ShareRoster?) async throws -> ShareResult {
        defer { finish() }
        do {
            return try await run(request, roster: roster)
        } catch let failure as ShareFailure {
            throw failure
        } catch is CancellationError {
            throw ShareFailure.cancelled
        } catch {
            throw ShareFailure.transport(error)
        }
    }

    private func run(_ request: ShareRequest, roster: ShareRoster?) async throws -> ShareResult {
        try Self.check(request)
        let images = request.attachments.filter { $0.kind == .image }
        let account = try Self.account(keychain: keychain, roster: roster)
        try live()
        self.account = account
        persisted = account.cookies
        nous = account.nous
        // Nothing, a cookie or a token least of all, goes to a Tailscale-only gateway while Tailscale is off.
        guard ShareReach.reachable(url: account.url, interfaces: interfaces) else { throw ShareFailure.tailscaleOff }
        if nous == nil { install(account.cookies) }
        progress(.connecting)
        if nous?.needsRenewal() == true { try await renewNous() }
        try await verifySession()

        let profile = request.bot.profile
        let ready: (socket: any ShareRPC, runtime: String, refs: [String])
        do {
            ready = try await prepare(request, profile: profile)
        } catch {
            // Nothing was submitted: what this share uploaded is of no use to anybody, and Try Again uploads it afresh.
            let failure = ShareFailure.transport(error)
            await discardUploads(profile: profile, after: failure)
            throw failure
        }
        let socket = ready.socket, runtime = ready.runtime, refs = ready.refs
        defer { socket.close() }
        let prompt = ShareRules.promptText(message: request.message, shared: request.shared, fileRefs: refs, hasImages: !images.isEmpty)
        // Ask Bot listens before it sends: the reply's first frames may come before prompt.submit's answer.
        let watch = request.replyWait > 0 ? ShareReplyWatch(runtime: runtime) : nil
        if let watch { socket.listen(watch.take) }
        // queued: a bot in the middle of a turn holds the share for its next turn instead of being redirected by it.
        try live()
        let submitted: [String: Any]
        do {
            submitted = try await socket.call("prompt.submit", ["session_id": runtime, "text": prompt, "profile": profile,
                                                                "queued": true], timeout: 60)
        } catch {
            // It went out and its answer never came: the bot may have it. Only the gateway's own refusal, or Cancel,
            // says otherwise, whatever kind of error the socket ended with.
            switch ShareFailure.transport(error) {
            case .timedOut, .transport: throw ShareFailure.unconfirmed
            case let failure: throw failure
            }
        }
        persistRenewed()
        let status = submitted["status"] as? String ?? "sent"
        var result = ShareResult(session: request.bot.session, status: status, renewedCookies: renewed || renewedNous)
        if let watch {
            // A prompt queued behind a running turn is answered by the turn after that one.
            result.reply = await watch.wait(skip: status == "queued" ? 1 : 0, timeout: request.replyWait)
            persistRenewed()
        }
        return result
    }

    /// Everything before the prompt (§6.2 steps 2-9): the uploads, the socket, the chat, the attaches. The socket it
    /// returns is open; when it throws, the socket (if it got that far) is closed.
    private func prepare(_ request: ShareRequest, profile: String) async throws -> (socket: any ShareRPC, runtime: String, refs: [String]) {
        var staged: [(item: ShareAttachment, path: String, folder: String)] = []
        if !request.attachments.isEmpty {
            try live()
            let root = try await json("/api/files?" + ShareRules.query(["profile": profile]))
            guard let directory = root["path"] as? String, !directory.isEmpty else {
                throw ShareFailure.refused("Your gateway has no folder for uploads.")
            }
            for (index, item) in request.attachments.enumerated() {
                try live()
                progress(.uploading(index + 1, request.attachments.count))
                let folder = directory + "/" + ShareIdentity.stagingFolder + "/" + UUID().uuidString
                let path = try await upload(item, to: folder + "/" + item.name, profile: profile, limit: request.limit)
                staged.append((item, path, folder))
                uploaded.append(folder)
            }
        }

        try live()
        progress(.sending)
        let ticket = try await ticket()
        try live()
        let socket = try await connect(session, try websocketURL(ticket: ticket))
        do {
            try live()
            // [speed] Not awaited: its answer is ignored (older gateways refuse it), and waiting cost a round trip, or
            // 10 s against a gateway that never answers. Written first, so the gateway still reads it before the resume.
            socket.notify("client.capabilities", ["server_requests": true])
            try live()
            let resumed = try await socket.call("session.resume", ["session_id": request.bot.session, "source": "desktop",
                                                                    "omit_messages": true, "profile": profile], timeout: 60)
            guard let runtime = resumed["session_id"] as? String, !runtime.isEmpty else {
                throw ShareFailure.refused("Your gateway couldn’t open this bot’s chat.")
            }
            var refs: [String] = []
            for (item, path, folder) in staged {
                try live()
                let unaccepted = "Your gateway didn’t accept “\(item.name)”."
                if item.kind == .image {
                    let result = try await socket.call("image.attach", ["session_id": runtime, "path": path, "profile": profile], timeout: 60)
                    guard result["attached"] as? Bool == true else { throw ShareFailure.refused(Self.said(result["message"]) ?? unaccepted) }
                } else {
                    let result = try await socket.call("file.attach", ["session_id": runtime, "path": path, "name": item.name,
                                                                       "profile": profile], timeout: 60)
                    guard result["attached"] as? Bool != false, let ref = result["ref_text"] as? String, !ref.isEmpty else {
                        throw ShareFailure.refused(Self.said(result["message"]) ?? unaccepted)
                    }
                    refs.append(ref)
                    // The gateway kept its own copy: the staging copy goes (a file referenced in place stays). That DELETE
                    // is a step of its own (9d): Cancel during file.attach stops the share before it, rather than leaving
                    // it to URLSession to drop a request started from a cancelled task.
                    if ShareRules.stagedCopyReleased(uploaded: result["uploaded"] as? Bool, storedPath: result["path"] as? String, folder: folder) {
                        try live()
                        if await remove(folder, profile: profile) == .removed { uploaded.removeAll { $0 == folder } }
                    }
                }
            }
            return (socket, runtime, refs)
        } catch {
            socket.close()
            throw error
        }
    }

    private enum Removal { case removed, refused, unreachable }

    /// DELETE of one staging folder on the gateway. `refused`: the gateway answered and did not remove it (404: it was
    /// not there). `unreachable`: no answer, the session ended, or the share was cancelled.
    private func remove(_ folder: String, profile: String, timeout: TimeInterval = 30) async -> Removal {
        do {
            _ = try await http("/api/files?" + ShareRules.query(["profile": profile]), method: "DELETE",
                               body: try JSONSerialization.data(withJSONObject: ["path": folder, "recursive": true]), timeout: timeout)
            return .removed
        } catch let failure as ShareFailure {
            switch failure {
            case .gateway, .refused: return .refused
            default: return .unreachable
            }
        } catch {
            return .unreachable
        }
    }

    /// A share that failed before its prompt went leaves its uploads in `<files root>/.dispatch-attachments/<UUID>/`,
    /// and every Try Again uploads them again into new folders (up to ten files of the attachment limit each time).
    /// They are removed here, best effort: one short request per folder, given up at the first one the gateway does
    /// not answer, so the failure itself is never held back for long. Never after prompt.submit was written (the bot
    /// may be reading them), and never after Cancel (nothing more is sent once the person cancels), with Tailscale off,
    /// or once the session has ended (the gateway would refuse it anyway).
    private func discardUploads(profile: String, after failure: ShareFailure) async {
        switch failure {
        case .cancelled, .tailscaleOff, .sessionEnded, .signedOut: return
        default: break
        }
        let folders = uploaded
        uploaded = []
        for folder in folders {
            if await remove(folder, profile: profile, timeout: 5) == .unreachable { return }
        }
    }

    /// Cancel stops the share before its next step (an upload, an attach, the prompt); a step in flight ends with it.
    private func live() throws { if Task.isCancelled { throw ShareFailure.cancelled } }

    /// A gateway's own reason for not attaching something: one trimmed line, or nothing.
    private static func said(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.isEmpty || line.count > 200 ? nil : line
    }

    // MARK: HTTP

    /// The account's address plus a path, and nothing else: same host, same port, no user or password. The tailnet
    /// rule is asked again before every request.
    private func endpoint(_ path: String) throws -> URL {
        guard let account, let base = URL(string: account.url), let url = URL(string: account.url + path),
              let scheme = base.scheme?.lowercased(), ["http", "https"].contains(scheme), base.host != nil,
              url.scheme == base.scheme, url.host == base.host, url.port == base.port, url.user == nil, url.password == nil else {
            throw ShareFailure.signedOut
        }
        guard ShareReach.reachable(url: account.url, interfaces: interfaces) else { throw ShareFailure.tailscaleOff }
        return url
    }

    private func install(_ cookies: [[String: Any]]) {
        guard let storage = session.configuration.httpCookieStorage else { return }
        storage.cookies?.forEach(storage.deleteCookie)
        cookies.compactMap(ShareAccounts.decode).forEach(storage.setCookie)
    }

    private func jar() -> [[String: Any]] {
        guard let account, let url = URL(string: account.url) else { return [] }
        return (session.configuration.httpCookieStorage?.cookies(for: url) ?? []).map(ShareAccounts.encode)
    }

    /// The gateway renews a session on any response (Set-Cookie); the Keychain gets the renewal at once, for the app,
    /// and only while it still holds the cookies this share started from (an app that renewed, signed out or switched
    /// meanwhile wins).
    private func persistRenewed() {
        guard let account, nous == nil else { return }
        let cookies = jar()
        guard !cookies.isEmpty, !ShareAccounts.sameCookies(cookies, persisted),
              let data = try? keychain.read(),
              let updated = ShareAccounts.replacingCookies(in: data, account: account.key, expected: persisted, renewed: cookies) else { return }
        do { try keychain.update(updated); persisted = cookies; renewed = true } catch {}
    }

    /// A Nous account's requests carry its access token and no cookies.
    private func authorized(_ request: URLRequest) -> URLRequest {
        guard let nous else { return request }
        var request = request
        request.setValue("Bearer " + nous.accessToken, forHTTPHeaderField: "Authorization")
        request.httpShouldHandleCookies = false
        return request
    }

    private func data(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, raw) = try await session.data(for: authorized(request))
            guard let response = raw as? HTTPURLResponse else { throw ShareFailure.refused("") }
            if response.value(forHTTPHeaderField: "Set-Cookie") != nil { persistRenewed() }
            return (data, response)
        } catch {
            throw ShareFailure.transport(error)
        }
    }

    /// The gateway renews an expired access cookie from the refresh cookie on any request, so one /api/auth/me
    /// confirms the session. Refused, it is asked once more with the Keychain's copy when the app renewed it
    /// meanwhile; still refused, the session has ended (the app asks for the password; the share never holds one).
    /// A Nous account refused is renewed once and asked again. Never more than this one retry.
    private func verifySession() async throws {
        var request = URLRequest(url: try endpoint("/api/auth/me"))
        request.timeoutInterval = 15
        let (_, response) = try await data(request)
        if (200..<300).contains(response.statusCode) { return }
        guard [401, 403].contains(response.statusCode) else { throw ShareFailure.gateway(response.statusCode) }
        try live()
        if nous != nil {
            try await renewNous(force: true)
        } else {
            guard let data = try keychain.read(), let saved = ShareAccounts.current(in: data), saved.key == account?.key,
                  !saved.cookies.isEmpty, !ShareAccounts.sameCookies(saved.cookies, persisted) else { throw ShareFailure.sessionEnded }
            account = saved
            persisted = saved.cookies
            install(saved.cookies)
        }
        let (_, again) = try await self.data(request)
        guard (200..<300).contains(again.statusCode) else {
            throw [401, 403].contains(again.statusCode) ? ShareFailure.sessionEnded : ShareFailure.gateway(again.statusCode)
        }
    }

    /// Sign in with Nous: renews the access token with the refresh token (POST /auth/native/refresh), as the app
    /// does, at most once per share. The app may have rotated the pair since this share read it: the Keychain's newer
    /// pair is then the live one, and the spent one is never sent (Portal would revoke the whole session). The
    /// rotated pair goes to the Keychain at once, while it still holds the pair this share spent, so the app signs in
    /// with it next.
    private func renewNous(force: Bool = false) async throws {
        guard let account, var sent = nous else { throw ShareFailure.signedOut }
        if let data = try keychain.read(), let saved = ShareAccounts.current(in: data), saved.key == account.key,
           let kept = saved.nous, !kept.samePair(sent), kept.userId == sent.userId {
            nous = kept
            if !kept.needsRenewal() { return }
            sent = kept
        } else if !force, !sent.needsRenewal() {
            return
        }
        guard !renewedNous else { throw ShareFailure.sessionEnded }       // one rotation per share, never a loop
        guard !sent.refreshToken.isEmpty else { throw ShareFailure.sessionEnded }   // [own-login] nothing to renew with
        // [reliability] B16: the app may be renewing this same pair right now. Wait for its pair rather than send the
        // same refresh token a second time (NousRenewalLease.swift).
        let keychain = self.keychain, spentPair = sent
        let (lease, adoptedApps) = await NousRenewalLease.acquireOrWait(account: account.key, in: leaseDirectory) {
            Self.newerPair(than: spentPair, account: account.key, keychain: keychain) != nil
        }
        defer { lease?.release() }
        if adoptedApps, let kept = Self.newerPair(than: sent, account: account.key, keychain: keychain) {
            nous = kept
            ShareAuthTrail.record("waited for the app's renewal and used its pair")
            return
        }
        var request = URLRequest(url: try endpoint("/auth/native/refresh"))
        request.timeoutInterval = 15
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": sent.refreshToken, "provider": sent.providerName])
        let (body, raw): (Data, URLResponse)
        do { (body, raw) = try await session.data(for: request) } catch { throw ShareFailure.transport(error) }
        guard let response = raw as? HTTPURLResponse else { throw ShareFailure.refused("") }
        guard let rotated = ShareNous.renewed(status: response.statusCode, body: body, userId: sent.userId, provider: sent.provider) else {
            // [reliability] B16: refused because the app spent this pair a moment earlier (outside the lease: an older
            // app, or the lease couldn't be written)? Its successor is then in the Keychain: use it, as the app does
            // after a refusal (`GatewayAuth.refreshNous`).
            if [400, 401, 403].contains(response.statusCode), let kept = Self.newerPair(than: sent, account: account.key, keychain: keychain) {
                nous = kept
                renewedNous = true
                ShareAuthTrail.record("had its pair refused (\(response.statusCode)); the app had rotated it meanwhile, used the app's pair")
                return
            }
            ShareAuthTrail.record("had its pair refused (\(response.statusCode))")
            throw [200, 400, 401, 403].contains(response.statusCode) ? ShareFailure.sessionEnded : ShareFailure.gateway(response.statusCode)
        }
        nous = rotated
        renewedNous = true
        // The spent pair is dead on the gateway: the new one must reach the Keychain, so a failed write gets one more go.
        var saved = storeNous(rotated, spent: sent, account: account.key)
        if !saved {
            try? await Task.sleep(nanoseconds: 200_000_000)
            saved = storeNous(rotated, spent: sent, account: account.key)
        }
        ShareAuthTrail.record(saved ? "rotated the pair" : "rotated the pair but couldn't save it")
    }

    /// The Keychain's pair for `account` when it is not `spent` (same user): another process rotated it.
    static func newerPair(than spent: ShareNous, account: String, keychain: any ShareKeychainStore) -> ShareNous? {
        guard let data = try? keychain.read(), let saved = ShareAccounts.current(in: data), saved.key == account,
              let kept = saved.nous, !kept.samePair(spent), kept.userId == spent.userId else { return nil }
        return kept
    }

    /// True when there is nothing (more) to write: the pair was stored, or the Keychain no longer holds the spent one.
    private func storeNous(_ rotated: ShareNous, spent: ShareNous, account: String) -> Bool {
        guard let data = try? keychain.read() else { return false }
        guard let updated = ShareAccounts.replacingNous(in: data, account: account, expected: spent, renewed: rotated) else { return true }
        do { try keychain.update(updated); return true } catch { return false }
    }

    private func http(_ path: String, method: String = "GET", body: Data? = nil, timeout: TimeInterval = 30) async throws -> Data {
        var request = URLRequest(url: try endpoint(path))
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = timeout
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await self.data(request)
        guard (200..<300).contains(response.statusCode) else {
            if [401, 403].contains(response.statusCode) { throw ShareFailure.sessionEnded }
            if response.statusCode == 413 { throw ShareFailure.refused("Your gateway refused a file this large.") }
            throw ShareFailure.gateway(response.statusCode)
        }
        return data
    }

    private func json(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any] {
        let data = try await http(path, method: method, body: try body.map { try JSONSerialization.data(withJSONObject: $0) })
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ShareFailure.refused("Your gateway answered in a way Hermes HQ doesn’t understand.")
        }
        return object
    }

    /// One attachment to `destination` on the gateway; the body is built on disk beside the staged file and streamed.
    private func upload(_ item: ShareAttachment, to destination: String, profile: String, limit: Int) async throws -> String {
        let boundary = ShareMultipart.boundary()
        let body: URL
        do {
            body = try ShareMultipart.make(source: item.file, destination: destination, filename: item.name, boundary: boundary,
                                           in: item.file.deletingLastPathComponent(), limit: limit)
        } catch is CancellationError {
            throw ShareFailure.cancelled
        } catch ShareMultipart.Failure.tooLarge {
            throw ShareFailure.tooLarge(item.name)
        } catch {
            throw ShareFailure.unreadable(item.name)
        }
        defer { try? FileManager.default.removeItem(at: body) }
        var request = URLRequest(url: try endpoint("/api/files/upload-stream?" + ShareRules.query(["profile": profile])))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response): (Data, HTTPURLResponse)
        do {
            let (bytes, raw) = try await session.upload(for: authorized(request), fromFile: body)
            guard let http = raw as? HTTPURLResponse else { throw ShareFailure.refused("") }
            if http.value(forHTTPHeaderField: "Set-Cookie") != nil { persistRenewed() }
            (data, response) = (bytes, http)
        } catch {
            throw ShareFailure.transport(error)
        }
        guard (200..<300).contains(response.statusCode) else {
            if [401, 403].contains(response.statusCode) { throw ShareFailure.sessionEnded }
            if response.statusCode == 413 { throw ShareFailure.tooLarge(item.name) }
            throw ShareFailure.gateway(response.statusCode)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let path = object["path"] as? String, !path.isEmpty else {
            throw ShareFailure.refused("Your gateway didn’t store “\(item.name)”.")
        }
        return path
    }

    private func ticket() async throws -> String {
        let answer = try await json("/api/auth/ws-ticket", method: "POST", body: [:])
        guard let ticket = answer["ticket"] as? String, !ticket.isEmpty else {
            throw ShareFailure.refused("Your gateway didn’t open a connection.")
        }
        return ticket
    }

    private func websocketURL(ticket: String) throws -> URL {
        guard var parts = URLComponents(url: try endpoint("/api/ws"), resolvingAgainstBaseURL: false) else { throw ShareFailure.signedOut }
        parts.scheme = parts.scheme?.lowercased() == "https" ? "wss" : "ws"
        parts.queryItems = [URLQueryItem(name: "ticket", value: ticket)]
        guard let url = parts.url else { throw ShareFailure.signedOut }
        return url
    }

    /// No redirect is followed: cookies and tokens never reach another host.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
