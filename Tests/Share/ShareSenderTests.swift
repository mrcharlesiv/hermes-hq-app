// [share] docs/spec/3x-share.md §6, §7.3, §7.8 check 2, §7.9: one share against a stand-in inside the test process
// (ShareSenderSupport.swift): the order of the calls, their exact keys, what stops a share, and what it never does.
// Cookies over real HTTP and the real socket are the fixture tests' (ShareFixtureTests.swift).

import Foundation
import Testing
@testable import HermesHQNative

@Suite(.serialized) struct ShareSenderTests {
    private func attachments(_ folder: URL = ShareTemp.folder("sender")) -> [ShareAttachment] {
        let photo = folder.appendingPathComponent("A/p01.jpg"), note = folder.appendingPathComponent("B/note.txt")
        for file in [photo, note] { try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true) }
        try? Data(repeating: 0x4a, count: 3000).write(to: photo)
        try? Data("a note".utf8).write(to: note)
        return [ShareAttachment(kind: .image, file: photo, name: "p01.jpg"), ShareAttachment(kind: .file, file: note, name: "note.txt")]
    }

    private let full = ["GET /api/auth/me", "GET /api/files", "POST /api/files/upload-stream", "POST /api/files/upload-stream",
                        "POST /api/auth/ws-ticket", "connect", "client.capabilities", "session.resume", "image.attach", "file.attach",
                        "DELETE /api/files", "prompt.submit"]

    // MARK: The sequence

    @Test func aPhotoAFileAndAMessageInOrderWithExactKeys() async throws {
        let gateway = ShareStubGateway(), keychain = gateway.keychain(), steps = ShareSteps()
        let files = attachments()
        let request = ShareRequest(bot: ShareSamples.bot(), message: "From the test", shared: ["https://example.com/a"], attachments: files)
        let result = try await gateway.sender(keychain, progress: { steps.add($0) }).send(request, roster: gateway.roster())

        #expect(gateway.labels == full)
        #expect(result == ShareResult(session: "20260929_120000_aabbcc02", status: "streaming", renewedCookies: false))
        #expect(steps.all == [.connecting, .uploading(1, 2), .uploading(2, 2), .sending])
        // The exact keys of §6.3.
        #expect(gateway.event("client.capabilities")?.keys == ["server_requests"])
        #expect(gateway.event("session.resume")?.keys == ["omit_messages", "profile", "session_id", "source"])
        #expect(gateway.event("session.resume")?.text == "20260929_120000_aabbcc02")          // the stored id
        #expect(gateway.event("image.attach")?.keys == ["path", "profile", "session_id"])
        #expect(gateway.event("file.attach")?.keys == ["name", "path", "profile", "session_id"])
        #expect(gateway.event("prompt.submit")?.keys == ["profile", "queued", "session_id", "text"])
        #expect(gateway.event("POST /api/auth/ws-ticket")?.keys == [])
        #expect(gateway.event("DELETE /api/files")?.keys == ["path", "recursive"])
        // Every profile-scoped route names the bot's profile; the socket is opened with the ticket, on the gateway's own host.
        for label in ["GET /api/files", "POST /api/files/upload-stream", "DELETE /api/files"] {
            #expect(gateway.event(label)?.text.hasPrefix("profile=ivy\n") == true, "\(label)")
        }
        #expect(gateway.sockets.map(\.absoluteString) == ["ws://\(gateway.host):8642/api/ws?ticket=ticket-1"])
        // Uploads go to <root>/.dispatch-attachments/<UUID>/<name>, one folder each; the attach calls name those paths.
        let uploads = gateway.events.filter { $0.label == "POST /api/files/upload-stream" }
        #expect(uploads.allSatisfy { $0.headers["Content-Type"]?.hasPrefix("multipart/form-data; boundary=hermes-") == true && $0.timeout == 120 })
        let image = try #require(gateway.event("image.attach")?.text), file = try #require(gateway.event("file.attach")?.text)
        #expect(image.range(of: "^/fixture/uploads/\\.dispatch-attachments/[0-9A-F-]{36}/p01\\.jpg$", options: .regularExpression) != nil, "\(image)")
        #expect(file.range(of: "^/fixture/uploads/\\.dispatch-attachments/[0-9A-F-]{36}/note\\.txt$", options: .regularExpression) != nil, "\(file)")
        #expect((image as NSString).deletingLastPathComponent != (file as NSString).deletingLastPathComponent)
        #expect(uploads.count == 2 && uploads[0].text.contains(image) && uploads[1].text.contains(file))
        #expect(uploads[1].text.contains("a note") && uploads[0].bodyBytes > 3000)
        // The staged copy of the file the gateway stored elsewhere goes; the photo's stays for the turn.
        #expect(gateway.event("DELETE /api/files")?.text.contains((file as NSString).deletingLastPathComponent.replacingOccurrences(of: "/", with: "\\/")) == true)
        // The prompt: the file's reference, the person's words, what was shared.
        #expect(gateway.event("prompt.submit")?.text == "@file:/fixture-home/attachments/note.txt\n\nFrom the test\n\nhttps://example.com/a")
        #expect(gateway.event("GET /api/auth/me")?.timeout == 15)
        #expect(gateway.closed == 1)
        // The body files built beside the staged copies are gone; the staged copies are the caller's.
        for item in files {
            #expect(try FileManager.default.contentsOfDirectory(atPath: item.file.deletingLastPathComponent().path) == [item.file.lastPathComponent])
        }
        #expect(keychain.counts.updates == 0)
    }

    /// [authority] A gateway-hosted Hermes refused every share: `prompt.submit` without its own request id is
    /// `invalid_params` there, and a path `image.attach` answers "session not found" (tester log 2026-11-14).
    @Test func onASessionAuthorityThePhotoGoesAsBytesAndTheSendNamesItsRequest() async throws {
        let gateway = ShareStubGateway(), keychain = gateway.keychain()
        gateway.sessionAuthority = true
        let files = attachments()
        let request = ShareRequest(bot: ShareSamples.bot(), message: "From the test", shared: [], attachments: files)
        let result = try await gateway.sender(keychain).send(request, roster: gateway.roster())
        #expect(result.status == "streaming")
        #expect(gateway.count("image.attach") == 0 && gateway.count("image.attach_bytes") == 1)
        #expect(gateway.event("image.attach_bytes")?.keys == ["content_base64", "filename", "profile", "session_id"])
        #expect(gateway.event("prompt.submit")?.keys == ["attachments", "profile", "queued", "session_id", "submission_id", "text"])
        // The photo's upload was not needed: its folder goes as well as the file's.
        #expect(gateway.count("DELETE /api/files") == 2)
        #expect(gateway.event("prompt.submit")?.text == "@file:/fixture-home/attachments/note.txt\n\nFrom the test")
    }

    @Test func onASessionAuthorityAPlainTextShareStillNamesItsRequest() async throws {
        let gateway = ShareStubGateway(), keychain = gateway.keychain()
        gateway.sessionAuthority = true
        let request = ShareRequest(bot: ShareSamples.bot(), message: "Just words", shared: [], attachments: [])
        _ = try await gateway.sender(keychain).send(request, roster: gateway.roster())
        #expect(gateway.event("prompt.submit")?.keys == ["profile", "queued", "session_id", "submission_id", "text"])
    }

    @Test func aTextShareMakesNoFileCalls() async throws {
        let gateway = ShareStubGateway()
        let result = try await gateway.sender(gateway.keychain()).send(ShareRequest(bot: ShareSamples.bot(), message: "Just words"), roster: gateway.roster())
        #expect(gateway.labels == ["GET /api/auth/me", "POST /api/auth/ws-ticket", "connect", "client.capabilities", "session.resume", "prompt.submit"])
        #expect(gateway.event("prompt.submit")?.text == "Just words")
        #expect(result.status == "streaming")
    }

    @Test func theSixPromptsOfTheTable() async throws {
        let folder = ShareTemp.folder("sender-prompts")
        func photo(_ name: String) -> ShareAttachment {
            let file = folder.appendingPathComponent(UUID().uuidString + "/" + name)
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(repeating: 1, count: 64).write(to: file)
            return ShareAttachment(kind: name.hasSuffix(".jpg") ? .image : .file, file: file, name: name)
        }
        let rows: [(String, [String], [ShareAttachment], String)] = [
            ("From Safari", ["https://example.com/a"], [], "From Safari\n\nhttps://example.com/a"),
            ("", [], [photo("one.jpg")], "What do you see in this image?"),
            ("Look", [], [photo("one.jpg"), photo("two.jpg")], "Look"),
            ("From Files", [], [photo("note.txt")], "@file:/fixture-home/attachments/note.txt\n\nFrom Files"),
            ("", [], [photo("a.txt"), photo("b.txt"), photo("one.jpg")], "@file:/fixture-home/attachments/a.txt\n@file:/fixture-home/attachments/b.txt"),
            ("Same", ["Same", "Same"], [], "Same"),
        ]
        for (message, shared, files, prompt) in rows {
            let gateway = ShareStubGateway()
            _ = try await gateway.sender(gateway.keychain()).send(ShareRequest(bot: ShareSamples.bot(), message: message, shared: shared, attachments: files),
                                                                  roster: gateway.roster())
            #expect(gateway.count("prompt.submit") == 1)
            #expect(gateway.event("prompt.submit")?.text == prompt, "\(prompt)")
        }
    }

    @Test func aFileReferencedInPlaceKeepsItsStagedCopy() async throws {
        let gateway = ShareStubGateway()
        gateway.onRPC { method, params in
            // An older gateway: it references the staged file where it is.
            method == "file.attach" ? ["attached": true, "uploaded": false, "path": params["path"] ?? "", "ref_text": "@file:" + (params["path"] as? String ?? "")] : nil
        }
        _ = try await gateway.sender(gateway.keychain()).send(ShareRequest(bot: ShareSamples.bot(), message: "", attachments: [attachments()[1]]), roster: gateway.roster())
        #expect(gateway.count("DELETE /api/files") == 0)
        #expect(gateway.count("prompt.submit") == 1)
    }

    @Test func aGatewayWithoutCapabilitiesStillGetsTheShare() async throws {
        let gateway = ShareStubGateway()
        gateway.onRPC { method, _ in
            if method == "client.capabilities" { throw ShareFailure.refused("Your gateway said: method not found") }
            return nil
        }
        let result = try await gateway.sender(gateway.keychain()).send(ShareRequest(bot: ShareSamples.bot(), message: "hi"), roster: gateway.roster())
        #expect(result.status == "streaming" && gateway.count("prompt.submit") == 1)
    }

    // MARK: Before anything is sent

    @Test func localChecksSendNothing() async {
        let gateway = ShareStubGateway(), folder = ShareTemp.folder("sender-checks")
        let small = ShareAttachment(kind: .file, file: ShareTemp.file("a.bin", bytes: 10, in: folder), name: "a.bin")
        let empty = ShareAttachment(kind: .file, file: ShareTemp.file("empty.bin", bytes: 0, in: folder), name: "empty.bin")
        let gone = ShareAttachment(kind: .image, file: folder.appendingPathComponent("gone.jpg"), name: "gone.jpg")
        let big = ShareAttachment(kind: .file, file: ShareTemp.file("big.bin", bytes: 2000, in: folder), name: "big.bin")
        let eleven = (0..<11).map { ShareAttachment(kind: .image, file: small.file, name: "p\($0).jpg") }
        let cases: [(ShareRequest, ShareFailure)] = [
            (ShareRequest(bot: ShareSamples.bot("ivy", session: ""), message: "hi"), .noChat),
            (ShareRequest(bot: ShareSamples.bot("ivy", session: "a/b"), message: "hi"), .noChat),
            (ShareRequest(bot: ShareSamples.bot(), message: " \n"), .nothingToSend),
            (ShareRequest(bot: ShareSamples.bot(), message: "", shared: ["", "  "]), .nothingToSend),
            (ShareRequest(bot: ShareSamples.bot(), message: "hi", attachments: [empty]), .unreadable("empty.bin")),
            (ShareRequest(bot: ShareSamples.bot(), message: "hi", attachments: [gone]), .unreadable("gone.jpg")),
            (ShareRequest(bot: ShareSamples.bot(), message: "hi", attachments: [small, big], limit: 1999), .tooLarge("big.bin")),
            (ShareRequest(bot: ShareSamples.bot(), message: "hi", attachments: eleven), .refused("Share at most 10 photos and 10 files at a time.")),
        ]
        for (request, failure) in cases {
            let keychain = gateway.keychain()
            #expect(await shareFailure { try await gateway.sender(keychain).send(request, roster: gateway.roster()) } == failure)
            #expect(keychain.counts.reads == 0)                    // not even the Keychain
        }
        #expect(gateway.events.isEmpty)
        // Exactly at the limit passes the check.
        #expect(throws: Never.self) { try ShareSender.check(ShareRequest(bot: ShareSamples.bot(), message: "", attachments: [big], limit: 2000)) }
    }

    @Test func openingChecksSendNothing() async {
        let gateway = ShareStubGateway()
        let request = ShareRequest(bot: ShareSamples.bot(), message: "hi")
        let legacy: [String: Any] = ["url": gateway.url, "username": ShareSamples.username, "password": "never read", "cookies": ShareSamples.cookies()]
        let locked = gateway.keychain(); locked.failReads(.locked)
        let cases: [(MemoryShareKeychain, ShareRoster?, ShareFailure)] = [
            (MemoryShareKeychain(), gateway.roster(), .signedOut),
            (locked, gateway.roster(), .locked),
            (MemoryShareKeychain(json: legacy), gateway.roster(), .needsApp),
            (gateway.keychain(), nil, .noRoster),
            (gateway.keychain(), ShareSamples.roster(url: "http://other.test:8642"), .otherAccount),
        ]
        for (keychain, roster, failure) in cases {
            #expect(await shareFailure { try await gateway.sender(keychain).send(request, roster: roster) } == failure)
            #expect(failure.blocksSheet || failure == .locked)
        }
        #expect(gateway.events.isEmpty)
    }

    @Test func tailscaleOffSendsNothing() async throws {
        // A plain-http tailnet gateway while no tunnel holds a tailnet address: not one request, not one cookie.
        for host in ["100.64.0.7", "100.127.255.254"] {
            let gateway = ShareStubGateway(host: host), keychain = gateway.keychain()
            let request = ShareRequest(bot: ShareSamples.bot(), message: "hi", attachments: attachments())
            let cellular: @Sendable () -> [ShareReach.Interface] = { [ShareReach.Interface(name: "pdp_ip0", address: "100.64.3.3"), ShareReach.Interface(name: "en0", address: "192.168.1.9")] }
            let failure = await shareFailure { try await gateway.sender(keychain, interfaces: cellular).send(request, roster: gateway.roster()) }
            #expect(failure == .tailscaleOff)
            #expect(failure?.retryable == true)
            #expect(gateway.events.isEmpty, "\(gateway.labels)")
            // With the tunnel up the same share goes.
            let tunnel: @Sendable () -> [ShareReach.Interface] = { [ShareReach.Interface(name: "utun4", address: "100.64.3.3")] }
            _ = try await gateway.sender(keychain, interfaces: tunnel).send(request, roster: gateway.roster())
            #expect(gateway.labels == full)
        }
    }

    @Test func tailscaleGoingOffMidShareStopsBeforeTheNextRequest() async {
        let gateway = ShareStubGateway(host: "100.64.0.8")
        let up = ShareSteps()            // any Sendable flag will do: empty means up
        gateway.beforeAnswer { _, label in if label == "GET /api/files" { up.add(.sending) } }
        let interfaces: @Sendable () -> [ShareReach.Interface] = { up.all.isEmpty ? [ShareReach.Interface(name: "utun4", address: "100.64.3.3")] : [] }
        let request = ShareRequest(bot: ShareSamples.bot(), message: "hi", attachments: attachments())
        let failure = await shareFailure { try await gateway.sender(gateway.keychain(), interfaces: interfaces).send(request, roster: gateway.roster()) }
        #expect(failure == .tailscaleOff)
        #expect(gateway.labels == ["GET /api/auth/me", "GET /api/files"])
    }

    @Test func anAddressWithCredentialsOrAnotherSchemeIsNeverContacted() async {
        for url in ["http://user:secret@share-stub-creds.test:8642", "ftp://share-stub-creds.test:8642", "share-stub-creds.test:8642"] {
            let keychain = MemoryShareKeychain(json: ShareSamples.item(url: url))
            let sender = ShareSender(keychain: keychain, interfaces: { [] }, protocols: [ShareStubProtocol.self], connect: { _, _ in throw ShareFailure.cancelled })
            let failure = await shareFailure { try await sender.send(ShareRequest(bot: ShareSamples.bot(), message: "hi"), roster: ShareSamples.roster(url: url)) }
            #expect(failure == .signedOut, "\(url)")
        }
    }

    // MARK: Refusals

    @Test func aRedirectIsNotFollowed() async {
        let gateway = ShareStubGateway(), elsewhere = ShareStubGateway()
        gateway.onHTTP { seen in seen.path == "/api/auth/me" ? .redirect(to: elsewhere.url + "/api/auth/me") : nil }
        let failure = await shareFailure { try await gateway.sender(gateway.keychain()).send(ShareRequest(bot: ShareSamples.bot(), message: "hi"), roster: gateway.roster()) }
        #expect(failure == .gateway(302))
        #expect(failure?.message == "Your gateway had a problem with this share. Try again in a minute.")
        #expect(elsewhere.events.isEmpty)                      // the other host received nothing
        #expect(gateway.labels == ["GET /api/auth/me"])
    }

    @Test func theSenderRefusesEveryRedirectItIsOffered() async throws {
        // The URL loading system asks before it follows a redirect: the answer is always "no request".
        let sender = ShareSender(keychain: MemoryShareKeychain(), interfaces: { [] }, protocols: [ShareStubProtocol.self],
                                 connect: { _, _ in throw ShareFailure.cancelled })
        let from = try #require(URL(string: "http://share-stub-redirect.test:8642/api/auth/me"))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for (status, target) in [(301, "http://share-stub-redirect.test:8642/elsewhere"), (302, "https://example.invalid/api/auth/me"),
                                 (307, "http://100.64.0.9:8642/api/files/upload-stream"), (308, "http://share-stub-redirect.test:8642/api/auth/me?x=1")] {
            let to = try #require(URL(string: target))
            let response = try #require(HTTPURLResponse(url: from, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Location": target]))
            let followed: URLRequest? = await withCheckedContinuation { continuation in
                sender.urlSession(session, task: session.dataTask(with: from), willPerformHTTPRedirection: response,
                                  newRequest: URLRequest(url: to)) { continuation.resume(returning: $0) }
            }
            #expect(followed == nil, "\(status) to \(target)")
        }
    }

    @Test func oneRetryOnARefusedSessionAndNeverASignIn() async throws {
        // The app renewed while the share was starting: the Keychain's newer cookies are tried once.
        let gateway = ShareStubGateway(), keychain = gateway.keychain()
        gateway.onHTTP { seen in
            guard seen.path == "/api/auth/me", gateway.count("GET /api/auth/me") == 1 else { return nil }
            keychain.set(json: ShareSamples.item(url: gateway.url, cookies: ShareSamples.cookies("a2", "r2")))
            return .status(401, body: "{\"detail\":\"Unauthorized\"}")
        }
        _ = try await gateway.sender(keychain).send(ShareRequest(bot: ShareSamples.bot(), message: "hi"), roster: gateway.roster())
        #expect(gateway.count("GET /api/auth/me") == 2 && gateway.count("prompt.submit") == 1)

        // The same cookies in the Keychain: the session has ended. One request, no retry, nothing else.
        for status in [401, 403] {
            let ended = ShareStubGateway()
            ended.onHTTP { seen in seen.path == "/api/auth/me" ? .status(status) : nil }
            let failure = await shareFailure { try await ended.sender(ended.keychain()).send(ShareRequest(bot: ShareSamples.bot(), message: "hi"), roster: ended.roster()) }
            #expect(failure == .sessionEnded && failure?.blocksSheet == true)
            #expect(ended.labels == ["GET /api/auth/me"])
        }

        // Newer cookies that are refused too: two requests, never a third.
        let twice = ShareStubGateway(), moved = twice.keychain()
        twice.onHTTP { seen in
            guard seen.path == "/api/auth/me" else { return nil }
            moved.set(json: ShareSamples.item(url: twice.url, cookies: ShareSamples.cookies("a\(twice.count("GET /api/auth/me") + 1)", "r")))
            return .status(401)
        }
        #expect(await shareFailure { try await twice.sender(moved).send(ShareRequest(bot: ShareSamples.bot(), message: "hi"), roster: twice.roster()) } == .sessionEnded)
        #expect(twice.labels == ["GET /api/auth/me", "GET /api/auth/me"])
        // Nothing ever went to a sign-in route.
        for gateway in [gateway, twice] { #expect(gateway.labels.allSatisfy { !$0.contains("login") && !$0.contains("/auth/native") }) }
    }

    @Test func gatewayAnswersBecomeThePlainSentences() async {
        typealias Fault = (label: String, reply: ShareStubProtocol.Reply, failure: ShareFailure)
        let faults: [Fault] = [
            ("GET /api/auth/me", .status(500), .gateway(500)),
            ("GET /api/auth/me", .status(429), .gateway(429)),
            ("GET /api/auth/me", .fail(.cannotConnectToHost), .transport(NSURLErrorDomain, -1004)),
            ("GET /api/auth/me", .fail(.timedOut), .timedOut),
            ("GET /api/files", .status(500), .gateway(500)),
            ("GET /api/files", .status(401), .sessionEnded),
            ("GET /api/files", .json(["entries": []]), .refused("Your gateway has no folder for uploads.")),
            ("GET /api/files", .status(200, body: "<html>sign in</html>"), .refused("Your gateway answered in a way Hermes HQ doesn’t understand.")),
            ("POST /api/files/upload-stream", .status(429), .gateway(429)),
            ("POST /api/files/upload-stream", .status(413), .tooLarge("p01.jpg")),
            ("POST /api/files/upload-stream", .status(403), .sessionEnded),
            ("POST /api/files/upload-stream", .json(["ok": true]), .refused("Your gateway didn’t store “p01.jpg”.")),
            ("POST /api/files/upload-stream", .fail(.networkConnectionLost), .transport(NSURLErrorDomain, -1005)),
            ("POST /api/auth/ws-ticket", .status(500), .gateway(500)),
            ("POST /api/auth/ws-ticket", .json(["ticket": ""]), .refused("Your gateway didn’t open a connection.")),
        ]
        for fault in faults {
            let gateway = ShareStubGateway()
            gateway.onHTTP { seen in seen.method + " " + seen.path == fault.label ? fault.reply : nil }
            let failure = await shareFailure {
                try await gateway.sender(gateway.keychain()).send(ShareRequest(bot: ShareSamples.bot(), message: "hi", attachments: self.attachments()), roster: gateway.roster())
            }
            #expect(failure == fault.failure, "\(fault.label) \(fault.reply.status)")
            // The fault is the share's last step; after it comes only the removal of what was already uploaded (both
            // files, once the uploads were through; nothing when the very first upload failed).
            let ended = gateway.endedWith
            #expect(ended.steps.last == fault.label && gateway.count("prompt.submit") == 0, "\(fault.label): \(gateway.labels)")
            #expect(ended.removed == (fault.label == "POST /api/auth/ws-ticket" ? 2 : 0), "\(fault.label): \(gateway.labels)")
        }
    }

    @Test func socketRefusalsBecomeThePlainSentences() async {
        typealias Fault = (method: String, answer: Result<[String: Any], ShareFailure>, failure: ShareFailure)
        let faults: [Fault] = [
            ("connect", .success(["refuse": true]), .transport(NSURLErrorDomain, -1004)),
            ("session.resume", .failure(.refused(ShareFailure.rpcCopy(code: 4001, message: "session not found"))),
             .refused("Your gateway couldn’t find this bot’s chat. Open it in Hermes HQ, then share again.")),
            ("session.resume", .failure(.refused(ShareFailure.rpcCopy(code: 4009, message: "busy"))), .refused("This bot is busy. Try again in a moment.")),
            ("session.resume", .success(["resumed": true]), .refused("Your gateway couldn’t open this bot’s chat.")),
            ("session.resume", .failure(.timedOut), .timedOut),
            ("image.attach", .success(["attached": false, "message": "Images are turned off for this model.\nTraceback…"]), .refused("Images are turned off for this model.")),
            ("image.attach", .success(["attached": false]), .refused("Your gateway didn’t accept “p01.jpg”.")),
            ("file.attach", .success(["attached": true]), .refused("Your gateway didn’t accept “note.txt”.")),
            ("file.attach", .success(["attached": false, "ref_text": "@file:/x", "message": "Too many files."]), .refused("Too many files.")),
            ("prompt.submit", .failure(.refused("Your gateway said: invalid params")), .refused("Your gateway said: invalid params")),
        ]
        for fault in faults {
            let gateway = ShareStubGateway()
            nonisolated(unsafe) let answer = fault.answer
            let wanted = fault.method
            gateway.onRPC { method, _ in method == wanted ? try answer.get() : nil }
            let failure = await shareFailure {
                try await gateway.sender(gateway.keychain()).send(ShareRequest(bot: ShareSamples.bot(), message: "hi", attachments: self.attachments()), roster: gateway.roster())
            }
            #expect(failure == fault.failure, "\(fault.method)")
            // Refused before the prompt: both uploads are removed again. A refused prompt was written, so nothing is.
            let ended = gateway.endedWith
            #expect(ended.steps.last == fault.method, "\(fault.method): \(gateway.labels)")
            #expect(ended.removed == (fault.method == "prompt.submit" ? 0 : 2), "\(fault.method): \(gateway.labels)")
            if fault.method == "prompt.submit" { #expect(gateway.labels.last == "prompt.submit") }
            if fault.method != "connect" { #expect(gateway.closed == 1, "\(fault.method)") }      // the socket never stays open
        }
    }

    // MARK: What a failed share leaves on the gateway

    /// The staging folders the uploads went to, from the upload bodies (the destination each one names).
    private func uploadedFolders(_ gateway: ShareStubGateway) -> [String] {
        gateway.events.filter { $0.label == "POST /api/files/upload-stream" }.compactMap { event -> String? in
            guard let start = event.text.range(of: "name=\"path\"\r\n\r\n"), let end = event.text[start.upperBound...].range(of: "\r\n") else { return nil }
            return (String(event.text[start.upperBound..<end.lowerBound]) as NSString).deletingLastPathComponent
        }
    }

    /// The folders the DELETE calls named, in order.
    private func removedFolders(_ gateway: ShareStubGateway) -> [String] {
        gateway.events.filter { $0.label == "DELETE /api/files" }.compactMap { event -> String? in
            guard let brace = event.text.firstIndex(of: "{"),
                  let body = (try? JSONSerialization.jsonObject(with: Data(event.text[brace...].utf8))) as? [String: Any] else { return nil }
            return body["path"] as? String
        }
    }

    @Test func aShareThatFailsBeforeItsPromptRemovesWhatItUploaded() async throws {
        // The chat is busy (4009): both uploads are already on the gateway, and Try Again would upload them again.
        let gateway = ShareStubGateway()
        gateway.onRPC { method, _ in
            if method == "session.resume" { throw ShareFailure.refused(ShareFailure.rpcCopy(code: 4009, message: "busy")) }
            return nil
        }
        let request = ShareRequest(bot: ShareSamples.bot(), message: "hi", attachments: attachments())
        let failure = await shareFailure { try await gateway.sender(gateway.keychain()).send(request, roster: gateway.roster()) }
        #expect(failure == .refused("This bot is busy. Try again in a moment."))
        #expect(gateway.labels == ["GET /api/auth/me", "GET /api/files", "POST /api/files/upload-stream", "POST /api/files/upload-stream",
                                   "POST /api/auth/ws-ticket", "connect", "client.capabilities", "session.resume",
                                   "DELETE /api/files", "DELETE /api/files"])
        let uploaded = uploadedFolders(gateway)
        #expect(uploaded.count == 2 && Set(uploaded).count == 2)
        #expect(removedFolders(gateway) == uploaded)                              // one each, the folder and nothing wider
        #expect(uploaded.allSatisfy { $0.range(of: "^/fixture/uploads/\\.dispatch-attachments/[0-9A-F-]{36}$", options: .regularExpression) != nil })
        let removals = gateway.events.filter { $0.label == "DELETE /api/files" }
        #expect(removals.allSatisfy { $0.keys == ["path", "recursive"] && $0.text.hasPrefix("profile=ivy\n") && $0.timeout == 5 })
        #expect(gateway.closed == 1 && gateway.count("prompt.submit") == 0)

        // A second go uploads into new folders and, failing the same way, removes those too: nothing piles up.
        let again = await shareFailure { try await gateway.sender(gateway.keychain()).send(request, roster: gateway.roster()) }
        #expect(again == failure)
        #expect(uploadedFolders(gateway).count == 4 && Set(uploadedFolders(gateway)).count == 4)
        #expect(removedFolders(gateway) == uploadedFolders(gateway))
    }

    @Test func aFileTheGatewayAlreadyReleasedIsNotRemovedTwice() async {
        // The photo attaches, the file attaches (its staged copy is released at once), then a second file is refused:
        // only what is still there is removed, the released folder is not asked for again.
        let gateway = ShareStubGateway(), folder = ShareTemp.folder("sender-released")
        var files = attachments(folder)
        let second = folder.appendingPathComponent("C/second.txt")
        try? FileManager.default.createDirectory(at: second.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("another".utf8).write(to: second)
        files.append(ShareAttachment(kind: .file, file: second, name: "second.txt"))
        gateway.onRPC { method, params in
            method == "file.attach" && params["name"] as? String == "second.txt" ? ["attached": false, "message": "Too many files."] : nil
        }
        let failure = await shareFailure {
            try await gateway.sender(gateway.keychain()).send(ShareRequest(bot: ShareSamples.bot(), message: "hi", attachments: files), roster: gateway.roster())
        }
        #expect(failure == .refused("Too many files."))
        let uploaded = uploadedFolders(gateway), removed = removedFolders(gateway)
        #expect(uploaded.count == 3 && removed.count == 3)
        // note.txt's folder first (released when it attached), then the photo's and the refused file's.
        #expect(removed == [uploaded[1], uploaded[0], uploaded[2]], "\(removed)")
        #expect(gateway.count("prompt.submit") == 0)
    }

    @Test func nothingIsRemovedWhenTheGatewayCannotBeAskedOrThePromptWasWritten() async {
        // The session ended, or Tailscale went off: the gateway would refuse or cannot be reached, so it is not asked.
        let ended = ShareStubGateway()
        ended.onHTTP { seen in seen.path == "/api/auth/ws-ticket" ? .status(401) : nil }
        let request = ShareRequest(bot: ShareSamples.bot(), message: "hi", attachments: attachments())
        #expect(await shareFailure { try await ended.sender(ended.keychain()).send(request, roster: ended.roster()) } == .sessionEnded)
        #expect(ended.count("DELETE /api/files") == 0 && ended.labels.last == "POST /api/auth/ws-ticket")

        // The first removal goes unanswered: the second is not tried (the failure is never held back for long).
        let silent = ShareStubGateway()
        silent.onHTTP { seen in
            if seen.path == "/api/auth/ws-ticket" { return .status(500) }
            return seen.method == "DELETE" ? .fail(.timedOut) : nil
        }
        #expect(await shareFailure { try await silent.sender(silent.keychain()).send(request, roster: silent.roster()) } == .gateway(500))
        #expect(silent.count("DELETE /api/files") == 1)

        // A folder that is already gone (404) is no reason to stop: the next one is still removed.
        let gone = ShareStubGateway()
        gone.onHTTP { seen in
            if seen.path == "/api/auth/ws-ticket" { return .status(500) }
            return seen.method == "DELETE" && gone.count("DELETE /api/files") == 1 ? .status(404) : nil
        }
        #expect(await shareFailure { try await gone.sender(gone.keychain()).send(request, roster: gone.roster()) } == .gateway(500))
        #expect(gone.count("DELETE /api/files") == 2)

        // The prompt went out and its answer never came: the bot may be reading the photo, so it stays.
        let lost = ShareStubGateway()
        lost.onRPC { method, _ in
            if method == "prompt.submit" { throw ShareFailure.timedOut }
            return nil
        }
        #expect(await shareFailure { try await lost.sender(lost.keychain()).send(request, roster: lost.roster()) } == .unconfirmed)
        #expect(lost.count("DELETE /api/files") == 1 && lost.labels.last == "prompt.submit")      // only the released file's
    }

    @Test func aConnectionTheSystemDroppedIsNotThePersonsCancel() async {
        // -999 with nobody having pressed Cancel. Before the prompt: the spec's sentence, with Try Again.
        let early = ShareStubGateway()
        early.onHTTP { seen in seen.path == "/api/auth/ws-ticket" ? .fail(.cancelled) : nil }
        let failure = await shareFailure { try await early.sender(early.keychain()).send(ShareRequest(bot: ShareSamples.bot(), message: "hi"), roster: early.roster()) }
        #expect(failure == .transport(NSURLErrorDomain, NSURLErrorCancelled))
        #expect(failure?.message == "The connection changed before your gateway answered. Try again.")
        #expect(failure?.retryable == true && early.count("prompt.submit") == 0)

        // During the prompt: the bot may have it. Not confirmed, never "cancelled" (which would put Send back on).
        let late = ShareStubGateway()
        late.onRPC { method, _ in
            if method == "prompt.submit" { throw URLError(.cancelled) }
            return nil
        }
        let lost = await shareFailure { try await late.sender(late.keychain()).send(ShareRequest(bot: ShareSamples.bot(), message: "hi"), roster: late.roster()) }
        #expect(lost == .unconfirmed && lost?.retryable == false)
        #expect(late.count("prompt.submit") == 1)
    }

    @Test func aPromptWhoseAnswerNeverCameIsUnconfirmedNotRetried() async {
        // It went out; the gateway has no idempotency key: never a plain Try Again, never a second send by itself.
        for dropped in [ShareFailure.timedOut, .transport(NSPOSIXErrorDomain, 57), .transport(NSURLErrorDomain, -1005),
                        .transport(NSURLErrorDomain, NSURLErrorCancelled)] {
            let gateway = ShareStubGateway()
            gateway.onRPC { method, _ in
                if method == "prompt.submit" { throw dropped }
                return nil
            }
            let failure = await shareFailure { try await gateway.sender(gateway.keychain()).send(ShareRequest(bot: ShareSamples.bot(), message: "hi"), roster: gateway.roster()) }
            #expect(failure == .unconfirmed)
            #expect(failure?.retryable == false)
            #expect(gateway.count("prompt.submit") == 1)
        }
        // The same trouble one step earlier is an ordinary failure: nothing was submitted.
        let earlier = ShareStubGateway()
        earlier.onRPC { method, _ in
            if method == "session.resume" { throw ShareFailure.transport(NSPOSIXErrorDomain, 57) }
            return nil
        }
        let failure = await shareFailure { try await earlier.sender(earlier.keychain()).send(ShareRequest(bot: ShareSamples.bot(), message: "hi"), roster: earlier.roster()) }
        #expect(failure == .transport(NSPOSIXErrorDomain, 57) && failure?.retryable == true)
        #expect(earlier.count("prompt.submit") == 0)
    }

    // MARK: Cancel

    @Test func cancelBeforeEachStepSendsNothingMore() async {
        // Cancelled while step k is in flight: step k+1 never starts, and no prompt goes unless it already had.
        for k in 0..<(full.count - 1) {
            let gateway = ShareStubGateway(), box = ShareTaskBox()
            gateway.beforeAnswer { index, _ in if index == k { box.cancelNow() } }
            let sender = gateway.sender(gateway.keychain())
            let request = ShareRequest(bot: ShareSamples.bot(), message: "hi", attachments: attachments())
            let roster = gateway.roster()
            let task = Task { try await sender.send(request, roster: roster) }
            box.hold(task)
            let failure = await shareFailure { try await task.value }
            #expect(failure == .cancelled, "cancelled at \(full[k])")
            #expect(gateway.labels == Array(full.prefix(k + 1)), "cancelled at \(full[k]): \(gateway.labels)")
            #expect(gateway.count("prompt.submit") == 0)
            if k >= 5 { #expect(gateway.closed == 1) }
        }
    }

    @Test func aShareCancelledBeforeItStartsDoesNothing() async {
        let gateway = ShareStubGateway(), keychain = gateway.keychain()
        let sender = gateway.sender(keychain), roster = gateway.roster()
        let task = Task.detached { () -> ShareFailure? in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await sender.send(ShareRequest(bot: ShareSamples.bot(), message: "hi"), roster: roster); return nil }
            catch { return error as? ShareFailure }
        }
        #expect(await task.value == .cancelled)
        #expect(gateway.events.isEmpty)
    }

    // MARK: Sign in with Nous

    private func nousShare(_ gateway: ShareStubGateway, _ keychain: MemoryShareKeychain, files: [ShareAttachment] = []) async -> ShareFailure? {
        await shareFailure {
            try await gateway.sender(keychain).send(ShareRequest(bot: ShareSamples.bot(), message: "hi", attachments: files), roster: gateway.roster(username: "nous:u1"))
        }
    }


    @Test func aNousAccountSendsItsBearerAndNoCookies() async throws {
        let gateway = ShareStubGateway()
        let keychain = gateway.keychain(nous: ShareSamples.nous(user: "u1"), username: "nous:u1")
        #expect(await nousShare(gateway, keychain, files: attachments()) == nil)
        #expect(gateway.labels == full)                                   // no refresh: the pair is live
        for event in gateway.events where event.label.contains(" /") {
            #expect(event.headers["Authorization"] == "Bearer nat_1", "\(event.label)")
            #expect(event.headers["Cookie"] == nil && !event.handlesCookies, "\(event.label)")
        }
        #expect(keychain.counts.updates == 0)
    }

    @Test func aLapsingNousPairIsRotatedOnceAndWrittenBackAtOnce() async throws {
        let gateway = ShareStubGateway()
        let now = Date().timeIntervalSince1970
        let keychain = gateway.keychain(nous: ShareSamples.nous(expiresAt: now + 5, user: "u1", obtainedAt: now - 3600), username: "nous:u1")
        gateway.onHTTP { seen in seen.path == "/auth/native/refresh" ? nousRefreshAnswer() : nil }
        let result = try await gateway.sender(keychain).send(ShareRequest(bot: ShareSamples.bot(), message: "hi"), roster: gateway.roster(username: "nous:u1"))
        #expect(gateway.labels.prefix(2) == ["POST /auth/native/refresh", "GET /api/auth/me"])
        #expect(gateway.count("POST /auth/native/refresh") == 1)
        let refresh = try #require(gateway.event("POST /auth/native/refresh"))
        #expect(refresh.keys == ["provider", "refresh_token"])
        #expect(refresh.text.contains("nrt_1") && refresh.headers["Authorization"] == nil && !refresh.handlesCookies && refresh.timeout == 15)
        #expect(gateway.event("GET /api/auth/me")?.headers["Authorization"] == "Bearer nat_2")
        #expect(result.renewedCookies)
        // The Keychain holds the rotated pair, with when it arrived.
        let item = try #require(keychain.value)
        let stored = try #require(ShareAccounts.current(in: item)?.nous)
        #expect(stored.accessToken == "nat_2" && stored.refreshToken == "nrt_2" && stored.userId == "u1")
        #expect(abs((stored.obtainedAt ?? 0) - now) < 30)
        #expect(keychain.counts.updates == 1)
    }

    @Test func aPairTheAppAlreadyRotatedIsAdoptedNotReplayed() async throws {
        // The share read the old pair; by the time it would renew, the Keychain holds the app's newer one.
        let gateway = ShareStubGateway()
        let now = Date().timeIntervalSince1970
        let keychain = gateway.keychain(nous: ShareSamples.nous(expiresAt: now + 5, user: "u1", obtainedAt: now - 3600), username: "nous:u1")
        gateway.onHTTP { seen in seen.path == "/auth/native/refresh" ? .status(401) : nil }       // a replay would be fatal
        // The Keychain changes after the share's first read (the account check), before the renewal's read.
        let fresh = ShareSamples.item(url: gateway.url, username: "nous:u1", cookies: nil, nous: ShareSamples.nous(access: "nat_app", refresh: "nrt_app", user: "u1"))
        let swapping = SwappingKeychain(keychain, after: 1, with: fresh)
        let sender = ShareSender(keychain: swapping, interfaces: { [] }, protocols: [ShareStubProtocol.self], connect: gateway.connect)
        _ = try await sender.send(ShareRequest(bot: ShareSamples.bot(), message: "hi"), roster: gateway.roster(username: "nous:u1"))
        #expect(gateway.count("POST /auth/native/refresh") == 0)
        #expect(gateway.event("GET /api/auth/me")?.headers["Authorization"] == "Bearer nat_app")
        #expect(keychain.counts.updates == 0)
    }

    @Test func aRefusedNousSessionIsRenewedOnceThenEnds() async throws {
        // Refused with a pair that looked live: one renewal, one more ask.
        let gateway = ShareStubGateway()
        let keychain = gateway.keychain(nous: ShareSamples.nous(user: "u1"), username: "nous:u1")
        gateway.onHTTP { seen in
            if seen.path == "/auth/native/refresh" { return nousRefreshAnswer() }
            if seen.path == "/api/auth/me", seen.headers["Authorization"] == "Bearer nat_1" { return .status(401) }
            return nil
        }
        #expect(await nousShare(gateway, keychain) == nil)
        #expect(gateway.labels.prefix(3) == ["GET /api/auth/me", "POST /auth/native/refresh", "GET /api/auth/me"])
        #expect(gateway.count("POST /auth/native/refresh") == 1)

        // Revoked: the renewal is refused. One attempt, no second, the session has ended.
        for status in [400, 401, 403] {
            let revoked = ShareStubGateway()
            let held = revoked.keychain(nous: ShareSamples.nous(user: "u1"), username: "nous:u1")
            // The gateway refuses the session (401); the renewal is then turned down with each status Portal uses.
            revoked.onHTTP { seen in seen.path == "/api/auth/me" ? .status(401) : seen.path == "/auth/native/refresh" ? .status(status) : nil }
            #expect(await nousShare(revoked, held) == .sessionEnded)
            #expect(revoked.labels == ["GET /api/auth/me", "POST /auth/native/refresh"])
            #expect(held.counts.updates == 0)
        }
        // A renewal that works but is still refused: ended, without a second renewal.
        let stubborn = ShareStubGateway()
        let pair = stubborn.keychain(nous: ShareSamples.nous(user: "u1"), username: "nous:u1")
        stubborn.onHTTP { seen in
            if seen.path == "/auth/native/refresh" { return nousRefreshAnswer() }
            return seen.path == "/api/auth/me" ? .status(401) : nil
        }
        #expect(await nousShare(stubborn, pair) == .sessionEnded)
        #expect(stubborn.count("POST /auth/native/refresh") == 1 && stubborn.count("GET /api/auth/me") == 2)
        // Another account's pair in the answer is never taken; a busy gateway is not "ended".
        let foreign = ShareStubGateway()
        let now = Date().timeIntervalSince1970
        let lapsing = foreign.keychain(nous: ShareSamples.nous(expiresAt: now + 5, user: "u1", obtainedAt: now - 3600), username: "nous:u1")
        foreign.onHTTP { seen in seen.path == "/auth/native/refresh" ? nousRefreshAnswer(user: "someone-else") : nil }
        #expect(await nousShare(foreign, lapsing) == .sessionEnded)
        #expect(lapsing.counts.updates == 0 && foreign.labels == ["POST /auth/native/refresh"])
        let busy = ShareStubGateway()
        let waiting = busy.keychain(nous: ShareSamples.nous(expiresAt: now + 5, user: "u1", obtainedAt: now - 3600), username: "nous:u1")
        busy.onHTTP { seen in seen.path == "/auth/native/refresh" ? .status(503) : nil }
        #expect(await nousShare(busy, waiting) == .gateway(503))
    }

    @Test func aRotatedPairIsWrittenAgainWhenTheFirstWriteFails() async throws {
        let gateway = ShareStubGateway()
        let now = Date().timeIntervalSince1970
        let keychain = gateway.keychain(nous: ShareSamples.nous(expiresAt: now + 5, user: "u1", obtainedAt: now - 3600), username: "nous:u1")
        keychain.failUpdates(1)
        gateway.onHTTP { seen in seen.path == "/auth/native/refresh" ? nousRefreshAnswer() : nil }
        #expect(await nousShare(gateway, keychain) == nil)
        let kept = try #require(keychain.value)
        #expect(ShareAccounts.current(in: kept)?.nous?.refreshToken == "nrt_2")
        #expect(keychain.counts.updates == 1)
        // The app signed out while the share was renewing: nothing is written, the share still goes with its pair.
        let other = ShareStubGateway()
        let leaving = other.keychain(nous: ShareSamples.nous(expiresAt: now + 5, user: "u1", obtainedAt: now - 3600), username: "nous:u1")
        other.onHTTP { seen in
            guard seen.path == "/auth/native/refresh" else { return nil }
            leaving.set(json: ["accounts": [] as [Any]])
            return nousRefreshAnswer()
        }
        #expect(await nousShare(other, leaving) == nil)
        #expect(leaving.counts.updates == 0)
        let left = try #require(leaving.value)
        #expect(ShareAccounts.current(in: left) == nil)
    }
}

/// A Keychain whose contents change (as the app would change them) after the share's first `after` reads.
nonisolated final class SwappingKeychain: ShareKeychainStore, @unchecked Sendable {
    private let inner: MemoryShareKeychain
    private let lock = NSLock()
    private var left: Int
    private let replacement: [String: Any]

    init(_ inner: MemoryShareKeychain, after reads: Int, with replacement: [String: Any]) {
        self.inner = inner; left = reads; self.replacement = replacement
    }

    func read() throws -> Data? {
        let swap = lock.withLock { () -> Bool in
            if left == 0 { left = -1; return true }
            if left > 0 { left -= 1 }
            return false
        }
        if swap { inner.set(json: replacement) }
        return try inner.read()
    }

    func update(_ data: Data) throws { try inner.update(data) }
}

/// The gateway's answer to POST /auth/native/refresh: a rotated pair for `user`.
nonisolated func nousRefreshAnswer(_ access: String = "nat_2", _ refresh: String = "nrt_2", user: String = "u1") -> ShareStubProtocol.Reply {
    .json(["provider": "nous", "access_token": access, "refresh_token": refresh, "expires_at": Date().timeIntervalSince1970 + 3600, "user_id": user])
}
