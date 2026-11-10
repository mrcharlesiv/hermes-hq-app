// [share] The repeatable part of the stress plan (docs/spec/3x-share.md §12): load, bad answers at every step, bad
// files, two processes on one Keychain. Everything here runs inside the test process against the stub gateway of
// ShareSenderSupport.swift, so it needs no port; the same races against a real stand-in gateway are the last two
// tests of ShareFixtureTests.

import Foundation
import Testing
import UniformTypeIdentifiers
@testable import HermesHQNative

/// The same "random" choices on every run (SplitMix64), so a failing round can be run again.
nonisolated struct ShareDice: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

/// A Sign in with Nous session as Portal keeps it: one live pair, and a spent refresh token shown again ends the
/// whole family.
nonisolated final class ShareNousFamily: @unchecked Sendable {
    private let lock = NSLock()
    private var number = 1
    private var spent: Set<String> = []
    private var ended = false
    private(set) var refreshes = 0
    private(set) var replayed = 0

    var pair: (access: String, refresh: String) { lock.withLock { ("nat_\(number)", "nrt_\(number)") } }
    var counts: (refreshes: Int, replayed: Int, ended: Bool) { lock.withLock { (refreshes, replayed, ended) } }

    /// The rotated pair, or nil when the token is not the live one (a spent one revokes everything).
    func rotate(_ refresh: String) -> (access: String, refresh: String)? {
        lock.withLock {
            refreshes += 1
            if spent.contains(refresh) { replayed += 1; ended = true; return nil }
            guard !ended, refresh == "nrt_\(number)" else { return nil }
            spent.insert(refresh)
            number += 1
            return ("nat_\(number)", "nrt_\(number)")
        }
    }

    func accepts(_ authorization: String?) -> Bool { lock.withLock { !ended && authorization == "Bearer nat_\(number)" } }

    /// The stub gateway's answers for this family: the refresh route, and a bearer check on everything else.
    func answer(_ seen: ShareStubProtocol.Seen) -> ShareStubProtocol.Reply? {
        if seen.path == "/auth/native/refresh" {
            let asked = ((try? JSONSerialization.jsonObject(with: seen.body)) as? [String: Any])?["refresh_token"] as? String ?? ""
            guard let rotated = rotate(asked) else { return .status(401, body: "{\"detail\":\"invalid_grant\"}") }
            return .json(["provider": "nous", "access_token": rotated.access, "refresh_token": rotated.refresh,
                          "expires_at": Date().timeIntervalSince1970 + 3600, "user_id": "u1"])
        }
        return accepts(seen.headers["Authorization"]) ? nil : .status(401)
    }
}

@Suite(.serialized) struct ShareStressTests {
    private func attachment(_ name: String, in folder: URL, bytes: Int? = nil) throws -> ShareAttachment {
        let home = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if let bytes { return ShareAttachment(kind: .file, file: ShareTemp.file(name, bytes: bytes, in: home), name: name) }
        return ShareAttachment(kind: .image, file: ShareTestMedia.photo(name, in: home), name: name)
    }

    /// A file of `bytes` that takes no room on disk until it is read.
    private func sparse(_ name: String, bytes: Int, in folder: URL) throws -> ShareAttachment {
        let home = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let url = home.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(bytes))
        try handle.close()
        return ShareAttachment(kind: .file, file: url, name: name)
    }

    /// Where an upload said its file should be stored.
    private func destination(_ event: ShareStubEvent) -> String {
        guard let start = event.text.range(of: "name=\"path\"\r\n\r\n"), let end = event.text[start.upperBound...].range(of: "\r\n") else { return "" }
        return String(event.text[start.upperBound..<end.lowerBound])
    }

    // MARK: §12.1 Load

    @Test func tenPhotosAndTenFilesGoAsOneShare() async throws {
        let gateway = ShareStubGateway(), folder = ShareTemp.folder("stress-twenty")
        var attachments: [ShareAttachment] = []
        for index in 1...10 { attachments.append(try attachment(String(format: "p%02d.jpg", index), in: folder)) }
        for index in 1...10 { attachments.append(try attachment(String(format: "f%02d.bin", index), in: folder, bytes: 1024 * 1024)) }
        let steps = ShareSteps()
        let sender = gateway.sender(gateway.keychain(), progress: { steps.add($0) })
        let started = Date()
        let result = try await sender.send(ShareRequest(bot: ShareSamples.bot(), message: "Twenty things", attachments: attachments), roster: gateway.roster())
        let took = Date().timeIntervalSince(started)
        #expect(result.status == "streaming")
        // All twenty uploads, in the order they were shared, each into a folder of its own.
        let uploads = gateway.events.filter { $0.label == "POST /api/files/upload-stream" }.map(destination)
        #expect(uploads.count == 20)
        #expect(uploads.map { ($0 as NSString).lastPathComponent } == attachments.map(\.name))
        #expect(Set(uploads.map { ($0 as NSString).deletingLastPathComponent }).count == 20)
        #expect(uploads.allSatisfy { $0.hasPrefix("/fixture/uploads/" + ShareIdentity.stagingFolder + "/") })
        #expect(gateway.count("image.attach") == 10 && gateway.count("file.attach") == 10)
        // One prompt, with the ten file references under the message.
        #expect(gateway.count("prompt.submit") == 1)
        let prompt = try #require(gateway.event("prompt.submit"))
        #expect(prompt.text.hasPrefix("@file:") && prompt.text.hasSuffix("\n\nTwenty things"))        // references, a blank line, the words
        #expect(prompt.text.components(separatedBy: "@file:").count - 1 == 10)
        #expect(prompt.text.components(separatedBy: "\n").count == 12)
        #expect(gateway.labels.last == "prompt.submit")
        // "Uploading 1 of 20…" counts up, once each.
        let counted = steps.all.compactMap { step -> String? in
            if case .uploading = step { return ShareSheetState.label(step) }
            return nil
        }
        #expect(counted == (1...20).map { "Uploading \($0) of 20…" })
        #expect(steps.all.first == .connecting && steps.all.last == .sending)
        // Nothing of the share's own is left beside the shared files (the upload bodies are gone).
        for item in attachments {
            #expect(try FileManager.default.contentsOfDirectory(atPath: item.file.deletingLastPathComponent().path) == [item.name])
        }
        #expect(gateway.closed == 1)
        #expect(took < 20, "ten photos and ten files took \(took) s")
        // The eleventh photo, or file, is refused before anything is asked of the gateway.
        for extra in [try attachment("p11.jpg", in: folder), try attachment("f11.bin", in: folder, bytes: 16)] {
            let other = ShareStubGateway()
            let refused = await shareFailure {
                try await other.sender(other.keychain()).send(ShareRequest(bot: ShareSamples.bot(), message: "", attachments: attachments + [extra]), roster: other.roster())
            }
            #expect(refused == .refused("Share at most 10 photos and 10 files at a time."))
            #expect(other.events.isEmpty)
        }
    }

    @Test func fiftySharesInARowLeaveNothingBehind() async throws {
        let gateway = ShareStubGateway(), keychain = gateway.keychain()
        let folder = ShareTemp.folder("stress-fifty")
        let note = ShareTemp.file("note.txt", text: "A note for the bot.", in: folder)
        // The system's temporary folder gets nothing from a share either.
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? [])
        for round in 1...50 {
            let request = ShareRequest(bot: ShareSamples.bot(), message: "Share \(round)", attachments: [ShareAttachment(kind: .file, file: note, name: "note.txt")])
            let result = try await gateway.sender(keychain).send(request, roster: gateway.roster())
            #expect(result.session == ShareSamples.bot().session)
        }
        let prompts = gateway.events.filter { $0.label == "prompt.submit" }.map(\.text)
        #expect(prompts.count == 50)
        #expect(prompts.enumerated().allSatisfy { $0.element == "@file:/fixture-home/attachments/note.txt\n\nShare \($0.offset + 1)" })
        #expect(gateway.count("POST /api/files/upload-stream") == 50 && gateway.count("GET /api/auth/me") == 50)
        #expect(gateway.count("connect") == 50 && gateway.closed == 50)          // every socket was closed
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["note.txt"])
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? [])
        #expect(after.subtracting(before).filter { $0.hasPrefix("hermes-") || $0.hasSuffix(".multipart") || $0.hasPrefix("CFNetworkUpload") }.isEmpty)
        #expect(keychain.counts.updates == 0)                                   // nothing was renewed, so nothing was written
    }

    @Test func aSenderIsReleasedOnceItsShareEnds() async throws {
        // The URL session holds its delegate until it is invalidated: a share that ends any way must let go of both.
        let gateway = ShareStubGateway(), keychain = gateway.keychain()
        final class Weak: @unchecked Sendable { weak var sender: ShareSender? }
        var held: [Weak] = []
        for round in 0..<12 {
            if round % 3 == 1 { gateway.onHTTP { seen in seen.path == "/api/auth/ws-ticket" ? .status(503) : nil } }
            else if round % 3 == 2 { gateway.onHTTP { seen in seen.path == "/api/auth/me" ? .fail(.networkConnectionLost) : nil } }
            else { gateway.onHTTP { _ in nil } }
            let box = Weak()
            do {
                let sender = gateway.sender(keychain)
                box.sender = sender
                _ = await shareFailure { try await sender.send(ShareRequest(bot: ShareSamples.bot(), message: "hi"), roster: gateway.roster()) }
            }
            held.append(box)
        }
        var waited = 0
        while held.contains(where: { $0.sender != nil }), waited < 100 { try await Task.sleep(nanoseconds: 50_000_000); waited += 1 }
        #expect(held.filter { $0.sender != nil }.isEmpty, "\(held.filter { $0.sender != nil }.count) of 12 senders are still alive")
    }

    @Test func theLimitItselfIsSentAndOneByteMoreIsNot() async throws {
        #expect(ShareRules.defaultLimitBytes == 104_857_600)
        let folder = ShareTemp.folder("stress-limit")
        let exact = try sparse("exact.bin", bytes: 104_857_600, in: folder), over = try sparse("big.bin", bytes: 104_857_601, in: folder)
        let small = try attachment("note.bin", in: folder, bytes: 64)

        let gateway = ShareStubGateway()
        let sent = await shareFailure {
            try await gateway.sender(gateway.keychain()).send(ShareRequest(bot: ShareSamples.bot(), message: "", attachments: [exact]), roster: gateway.roster())
        }
        #expect(sent == nil)
        let upload = try #require(gateway.event("POST /api/files/upload-stream"))
        #expect(upload.bodyBytes > 104_857_600 && upload.bodyBytes < 104_857_600 + 2048)        // the file and its two form parts
        #expect(gateway.count("prompt.submit") == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: exact.file.deletingLastPathComponent().path) == ["exact.bin"])

        // One byte more, alone or beside a file that fits: refused before the Keychain is read or anything is sent.
        for attachments in [[over], [small, over], [over, small]] {
            let other = ShareStubGateway(), keychain = other.keychain()
            let refused = await shareFailure {
                try await other.sender(keychain).send(ShareRequest(bot: ShareSamples.bot(), message: "Too big", attachments: attachments), roster: other.roster())
            }
            #expect(refused == .tooLarge("big.bin"))
            #expect(refused?.message == "“big.bin” is larger than your attachment limit.")
            #expect(other.events.isEmpty && keychain.counts.reads == 0)
        }
        // The roster's own, smaller limit is the one that counts (a build-240 roster says 8 MB).
        let eight = ShareStubGateway()
        let limited = await shareFailure {
            try await eight.sender(eight.keychain()).send(ShareRequest(bot: ShareSamples.bot(), message: "", attachments: [exact], limit: 8 * 1024 * 1024), roster: eight.roster())
        }
        #expect(limited == .tooLarge("exact.bin") && eight.events.isEmpty)
    }

    @Test func aQuarterMillionCharactersArriveWholeAndAMillionAreCut() async throws {
        // What the sheet reads out of the share is cut at 262 144 characters…
        let million = String(repeating: "0123456789", count: 100_000)
        let staging = ShareItemLoader.newFolder(in: ShareTemp.folder("stress-text"))
        let started = Date()
        let loaded = await ShareItemLoader.load([ShareProviders.item([NSItemProvider(object: million as NSString)])], into: staging)
        let text = try #require(loaded.items.first?.sharedText)
        #expect(text.count == 262_144 && million.hasPrefix(text))
        // …and that much goes to the bot whole, under the person's own words.
        let gateway = ShareStubGateway()
        _ = try await gateway.sender(gateway.keychain()).send(ShareRequest(bot: ShareSamples.bot(), message: "Read this", shared: [text]), roster: gateway.roster())
        let prompt = try #require(gateway.event("prompt.submit"))
        #expect(prompt.text.count == "Read this\n\n".count + 262_144)
        #expect(prompt.text == "Read this\n\n" + text)
        #expect(gateway.count("POST /api/files/upload-stream") == 0 && gateway.count("GET /api/files") == 0)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    // MARK: §12.3 Bad answers, at every step

    /// One thing the gateway does wrong, at one step of a share.
    private nonisolated struct Fault: CustomStringConvertible, Sendable {
        let step: String
        let kind: Int
        var description: String { "\(step) fault \(kind)" }
    }

    private nonisolated static let httpSteps = ["GET /api/auth/me", "GET /api/files", "POST /api/files/upload-stream", "POST /api/auth/ws-ticket", "DELETE /api/files"]
    private nonisolated static let rpcSteps = ["connect", "client.capabilities", "session.resume", "image.attach", "file.attach", "prompt.submit"]
    private nonisolated static let statuses = [201, 204, 301, 302, 400, 401, 403, 404, 408, 413, 429, 500, 502, 503]

    private nonisolated static func httpReply(_ kind: Int, elsewhere: String) -> ShareStubProtocol.Reply {
        switch kind {
        case 0..<statuses.count: return .status(statuses[kind])
        case 14: return .json([:])
        case 15: return ShareStubProtocol.Reply(status: 200, headers: ["Content-Type": "text/html"], body: Data("<html><body>Sign in</body></html>".utf8))
        case 16: return ShareStubProtocol.Reply(status: 200, body: Data())
        case 17: return .json(["path": 5, "ticket": ["x"], "entries": "no"])
        case 18: return .json(["path": "", "ticket": ""])
        case 19: return .fail(.timedOut)
        case 20: return .fail(.networkConnectionLost)
        case 21: return .fail(.cannotConnectToHost)
        case 22: return .fail(.notConnectedToInternet)
        case 23: return .fail(.secureConnectionFailed)
        case 24: return .redirect(to: elsewhere + "/api/auth/me")
        case 25: return ShareStubProtocol.Reply(status: 200, body: Data([0xff, 0xfe, 0x00, 0x7b]))
        default: return .json(["detail": String(repeating: "x", count: 4000)], status: 500)
        }
    }

    private nonisolated static func rpcAnswer(_ kind: Int) throws -> [String: Any] {
        switch kind {
        case 0: throw ShareFailure.timedOut
        case 1: throw ShareFailure.transport(NSURLErrorDomain, -1005)
        case 2: throw ShareFailure.transport(NSPOSIXErrorDomain, 57)
        case 3: throw ShareFailure.refused(ShareFailure.rpcCopy(code: 4001, message: "session not found"))
        case 4: throw ShareFailure.refused(ShareFailure.rpcCopy(code: 4009, message: "session busy"))
        case 5: throw ShareFailure.refused(ShareFailure.rpcCopy(code: -32000, message: "first line\nsecond line\nthird line"))
        case 6: throw ShareFailure.refused(ShareFailure.rpcCopy(code: -32000, message: String(repeating: "y", count: 500)))
        case 7: return [:]
        case 8: return ["session_id": 7, "attached": "yes", "ref_text": 3, "status": 5]
        case 9: return ["session_id": "", "attached": false, "ref_text": ""]
        case 10: return ["attached": false, "message": "Too many attachments in this chat.\nTry a new chat."]
        case 11: return ["attached": false, "message": String(repeating: "z", count: 500)]
        case 12: throw URLError(.badServerResponse)
        case 13: throw CocoaError(.fileReadUnknown)
        default: return ["refuse": true]
        }
    }

    @Test func anAnswerGoneWrongAtAnyStepNeverCrashesAndNeverSendsTwice() async throws {
        let folder = ShareTemp.folder("stress-faults")
        let files = [try attachment("one.jpg", in: folder), try attachment("two.txt", in: folder, bytes: 2048)]
        var dice = ShareDice(seed: 2026_10_12)
        var outcomes: [String: Int] = [:]
        for round in 0..<300 {
            let http = Bool.random(using: &dice)
            let fault = http ? Fault(step: Self.httpSteps.randomElement(using: &dice) ?? "", kind: Int.random(in: 0...26, using: &dice))
                             : Fault(step: Self.rpcSteps.randomElement(using: &dice) ?? "", kind: Int.random(in: 0...14, using: &dice))
            // Sometimes the same step goes wrong every time it is asked, sometimes only the first time.
            let always = Bool.random(using: &dice)
            let gateway = ShareStubGateway(), elsewhere = ShareStubGateway(), keychain = gateway.keychain()
            let hits = LoadCounter()
            gateway.onHTTP { seen in
                guard http, seen.method + " " + seen.path == fault.step else { return nil }
                hits.hit("fault")
                return always || hits.count("fault") == 1 ? Self.httpReply(fault.kind, elsewhere: elsewhere.url) : nil
            }
            gateway.onRPC { method, _ in
                guard !http, method == fault.step else { return nil }
                hits.hit("fault")
                guard always || hits.count("fault") == 1 else { return nil }
                guard method == "connect" else { return try Self.rpcAnswer(fault.kind) }
                // The connection itself can only fail or be refused; an answer means nothing to it.
                do {
                    guard try Self.rpcAnswer(fault.kind)["refuse"] != nil else { return nil }
                } catch {
                    hits.hit("no socket")
                    throw error
                }
                hits.hit("no socket")
                return ["refuse": true]
            }
            let request = ShareRequest(bot: ShareSamples.bot(), message: "Round \(round)", shared: ["https://example.com/a?b=1"], attachments: files)
            let started = Date()
            let failure = await shareFailure { try await gateway.sender(keychain).send(request, roster: gateway.roster()) }
            let what = "round \(round), \(fault)\(always ? " (every time)" : ""): \(failure.map { "\($0)" } ?? "sent") after \(gateway.labels)"
            outcomes[failure?.name ?? "sent", default: 0] += 1

            // A sentence a person can read, whatever happened.
            if let failure {
                #expect(!failure.message.isEmpty && failure.message.count <= 240, "\(what)")
                #expect(!failure.message.lowercased().contains("dispatch") && !failure.message.contains("\n"), "\(what)")
                #expect(failure != .cancelled, "\(what)")
            }
            // Never more than one retry of the session check, never a sign-in, never another host.
            #expect(gateway.count("GET /api/auth/me") <= 2, "\(what)")
            #expect(gateway.labels.allSatisfy { !$0.contains("login") && !$0.contains("/auth/native") }, "\(what)")
            #expect(elsewhere.events.isEmpty, "\(what)")
            // At most one prompt, and nothing after it.
            let prompts = gateway.count("prompt.submit")
            #expect(prompts <= 1, "\(what)")
            if prompts == 1 { #expect(gateway.labels.last == "prompt.submit", "\(what)") }
            switch failure {
            case nil: #expect(prompts == 1, "\(what)")
            case .unconfirmed: #expect(prompts == 1 && fault.step == "prompt.submit", "\(what)")
            default: #expect(prompts == 0 || fault.step == "prompt.submit", "\(what)")       // refused by the gateway itself
            }
            // A share that fails for good is never one the sheet offers to send again blindly.
            if failure == .unconfirmed { #expect(failure?.retryable == false, "\(what)") }
            // The socket, once open, is closed; the upload bodies are gone; the Keychain was not written.
            #expect(gateway.count("connect") <= 1, "\(what)")
            let opened = gateway.count("connect") == 1 && hits.count("no socket") == 0
            #expect(gateway.closed == (opened ? 1 : 0), "\(what)")
            for item in files {
                #expect((try? FileManager.default.contentsOfDirectory(atPath: item.file.deletingLastPathComponent().path)) == [item.name], "\(what)")
            }
            #expect(keychain.counts.updates == 0, "\(what)")
            #expect(Date().timeIntervalSince(started) < 10, "\(what)")
        }
        // The rounds really covered both ends: shares that went through, and several kinds of failure.
        #expect((outcomes["sent"] ?? 0) > 20 && outcomes.count >= 5, "\(outcomes)")
    }

    // MARK: §12.4 Bad files

    @Test func junkInTheGroupFolderReadsAsNothing() throws {
        let folder = ShareTemp.folder("stress-junk"), store = ShareStore(folder: folder)
        let good = ShareSamples.roster()
        try store.save(good)
        let whole = try Data(contentsOf: store.rosterFile)
        #expect(store.roster == good)
        var junk = Data(count: 5 * 1024 * 1024)
        junk.withUnsafeMutableBytes { buffer in for index in stride(from: 0, to: buffer.count, by: 97) { buffer[index] = UInt8(index % 251) } }
        let bad: [Data] = [Data(), Data("{}".utf8), Data("[]".utf8), Data("[1,2,3]".utf8), Data("null".utf8), Data("\"roster\"".utf8),
                           whole.prefix(whole.count / 2), whole.dropFirst(3), Data(repeating: 0x7b, count: 100_000), junk,
                           Data("{\"account\":5,\"bots\":\"none\"}".utf8), Data("{\"bots\":[{}]}".utf8)]
        for (index, data) in bad.enumerated() {
            for file in [store.rosterFile, store.sentFile, store.choiceFile] { try data.write(to: file) }
            let started = Date()
            #expect(store.roster == nil, "roster \(index)")
            #expect(store.lastSent == nil, "note \(index)")
            #expect(store.lastChoice(account: good.account) == nil, "choice \(index)")
            // The app's side: an unreadable note opens nothing and is removed.
            #expect(store.takeSent(account: good.account) == nil, "note \(index)")
            #expect(!store.hasSentNote, "note \(index)")
            #expect(Date().timeIntervalSince(started) < 1, "junk \(index) took too long")
        }
    }

    @Test func aHostileRosterOffersOnlyWhatIsSafe() throws {
        let folder = ShareTemp.folder("stress-hostile"), store = ShareStore(folder: folder)
        let secret = folder.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).png")
        try Data("not for the sheet".utf8).write(to: secret)
        defer { try? FileManager.default.removeItem(at: secret) }
        var bots: [[String: Any]] = [
            ["key": "ios-direct::good", "name": "Good", "profile": "good", "session": "20260929_120000_aabbcc02", "color": "#3366ff", "avatar": "good-abc.png"],
            ["key": "ios-direct::up", "name": "Up", "profile": "up", "session": "../../etc/passwd", "color": "", "avatar": "../../" + secret.lastPathComponent],
            ["key": "ios-direct::../x", "name": "Slash", "profile": "../x", "session": "20260929_120000_aabbcc03", "color": ""],
            ["key": "ios-direct::long", "name": String(repeating: "N", count: 10_000), "profile": "long", "session": "20260929_120000_aabbcc04", "color": "red"],
            ["key": "ios-direct::empty", "name": "", "profile": "empty", "session": "", "color": ""],
            ["key": "ios-direct::abs", "name": "Abs", "profile": "abs", "session": "20260929_120000_aabbcc05", "color": "", "avatar": secret.path],
        ]
        for index in 0..<1000 {
            bots.append(["key": "ios-direct::b\(index)", "name": "Bot \(index)", "profile": "b\(index)", "session": String(format: "20260929_120000_%06x", index),
                         "color": "", "lastActive": Double(index)])
        }
        let raw: [String: Any] = ["version": 1, "account": ShareSamples.key, "url": ShareSamples.url, "username": ShareSamples.username,
                                  "limitBytes": 33_554_432, "bots": bots, "savedAt": 1]
        let data = try JSONSerialization.data(withJSONObject: raw)
        try data.write(to: store.rosterFile)
        #expect(data.count < ShareStore.maxFileBytes)
        let roster = try #require(store.roster)                         // every row has the right shape; only its contents are hostile
        #expect(roster.bots.count == 1006)
        // One row of the wrong shape (a number for a name) and the whole file reads as no roster: nobody is offered.
        var misshapen = raw
        misshapen["bots"] = bots + [["key": "ios-direct::n", "name": 7, "profile": "n", "session": "x", "color": ""]]
        try JSONSerialization.data(withJSONObject: misshapen).write(to: store.rosterFile)
        #expect(store.roster == nil)
        try data.write(to: store.rosterFile)
        let started = Date()
        let ordered = ShareSheetState.ordered(roster.bots)
        #expect(Date().timeIntervalSince(started) < 1)
        func bot(_ profile: String) -> ShareBot? { ordered.first { $0.profile == profile } }
        #expect(bot("good")?.canReceive == true)
        // A session or a profile that is not an id cannot receive, so nothing is ever sent with it.
        for profile in ["up", "../x", "empty"] { #expect(bot(profile)?.canReceive != true, "\(profile)") }
        // No picture outside avatars/ is ever opened.
        for candidate in roster.bots { if let file = store.picture(candidate.avatar) { #expect(file.path.hasPrefix(store.avatars.path + "/"), "\(candidate.profile)") } }
        #expect(store.picture("../../" + secret.lastPathComponent) == nil && store.picture(secret.path) == nil)
        #expect(!store.hasPicture("../../" + secret.lastPathComponent))
        // The first one that can receive is chosen when the remembered one is gone or cannot.
        let chosen = ShareSheetState.selection(bots: ordered, remembered: "ios-direct::gone")
        #expect(ordered.first { $0.key == chosen }?.canReceive == true)
        #expect(ShareSheetState.selection(bots: ordered, remembered: "ios-direct::up") != "ios-direct::up")
        // A share to a bot that cannot receive never leaves the phone, whatever the sheet let through.
        for profile in ["up", "../x", "empty"] {
            guard let target = bot(profile) else { continue }
            #expect(throws: ShareFailure.noChat) { try ShareSender.check(ShareRequest(bot: target, message: "hi")) }
        }
    }

    @Test func hostileSharedItemsStayInsideTheSharesFolder() async throws {
        let source = ShareTemp.folder("stress-items"), home = ShareTemp.folder("stress-items-staging")
        let staging = ShareItemLoader.newFolder(in: home)
        let outside = Set(try FileManager.default.contentsOfDirectory(atPath: home.deletingLastPathComponent().path))
        let note = ShareTemp.file("note.txt", text: "A note", in: source)
        let empty = ShareTemp.file("empty.bin", bytes: 0, in: source)
        let fakePhoto = ShareTemp.file("fake.heic", text: "This is not a photo.", in: source)
        let fakeMovie = ShareTemp.file("fake.mov", text: "This is not a movie.", in: source)
        let gone = source.appendingPathComponent("gone.pdf")
        let failing = NSItemProvider()
        failing.suggestedName = "failing.pdf"
        failing.registerFileRepresentation(forTypeIdentifier: UTType.pdf.identifier, fileOptions: [], visibility: .all) { completion in
            completion(nil, false, CocoaError(.fileReadNoPermission)); return nil
        }
        let providers: [NSItemProvider] = [
            ShareProviders.file(note, type: .plainText, name: "../../escape.txt"),
            ShareProviders.file(note, type: .data, name: String(repeating: "😀", count: 400) + ".txt"),
            ShareProviders.file(note, type: .data, name: "two\nlines\r\n.txt"),
            ShareProviders.file(note, type: .data, name: "/etc/passwd"),
            ShareProviders.file(note, type: .data, name: "quote\"back\\slash.txt"),
            ShareProviders.file(note, type: .data, name: "..."),
            ShareProviders.file(empty, type: .data, name: "empty.bin"),
            ShareProviders.file(fakePhoto, type: .heic, name: "fake.heic"),
            ShareProviders.file(fakeMovie, type: .quickTimeMovie, name: "fake.mov"),
            ShareProviders.file(gone, type: .pdf, name: "gone.pdf"),
            failing,
        ]
        let loaded = await ShareItemLoader.load(providers.map { ShareProviders.item([$0]) }, into: staging)
        // Everything is either a staged file with a safe name, text, or a named failure: eleven things in, eleven out.
        #expect(loaded.items.count + loaded.failures.count == providers.count, "\(loaded.items.map(\.name)) and \(loaded.failures)")
        #expect(loaded.failures.count >= 5, "\(loaded.failures)")                 // empty, fake photo, fake movie, gone, failing
        for item in loaded.items {
            guard let file = item.file else { continue }
            #expect(file.standardizedFileURL.path.hasPrefix(staging.standardizedFileURL.path + "/"), "\(item.name)")
            #expect(file.lastPathComponent == item.name && item.name == ShareRules.safeName(item.name), "\(item.name)")
            #expect(!ShareMultipart.unsafe(item.name) && !item.name.contains("/") && item.name != "." && item.name != ".." && item.name.utf8.count <= 255, "\(item.name)")
            #expect(item.bytes > 0, "\(item.name)")
        }
        for name in loaded.failures { #expect(!name.contains("\n") && !name.contains("/") && name.count <= 255, "\(name)") }
        // Nothing appeared beside the staging folder's home, and nothing inside it but this share's own folder.
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: home.deletingLastPathComponent().path)) == outside)
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.path) == [staging.lastPathComponent])
        // Those files then go to a gateway under the same safe names.
        let gateway = ShareStubGateway()
        let attachments = loaded.items.compactMap { item in item.file.map { ShareAttachment(kind: .file, file: $0, name: item.name) } }
        if !attachments.isEmpty {
            _ = try await gateway.sender(gateway.keychain()).send(ShareRequest(bot: ShareSamples.bot(), message: "Files", attachments: attachments), roster: gateway.roster())
            let stored = gateway.events.filter { $0.label == "POST /api/files/upload-stream" }.map(destination)
            #expect(stored.count == attachments.count)
            #expect(stored.allSatisfy { $0.hasPrefix("/fixture/uploads/" + ShareIdentity.stagingFolder + "/") }, "\(stored)")
            #expect(stored.allSatisfy { path in !path.split(separator: "/").contains { $0 == ".." || $0 == "." } }, "\(stored)")
            // Each is "<folder>/<staging>/<a new id>/<the safe name>": nothing a name held added a folder.
            #expect(stored.allSatisfy { $0.split(separator: "/").count == 5 }, "\(stored)")
        }
    }

    @Test func aLinkThatIsNotAWebAddressIsNeverALink() async {
        let staging = ShareItemLoader.newFolder(in: ShareTemp.folder("stress-links"))
        for address in ["javascript:alert(1)", "data:text/html,<b>x</b>", "tel:+15551234567", "ftp://example.com/x", "hermes://open",
                        "file:///etc/passwd"] {
            guard let url = URL(string: address) else { continue }
            let loaded = await ShareItemLoader.load([ShareProviders.item([NSItemProvider(object: url as NSURL)])], into: staging)
            for item in loaded.items {
                if case .link = item.kind { Issue.record("\(address) was offered as a link") }
                // Only a file address is a file (the app sharing it handed that file over); nothing else is staged.
                if !address.hasPrefix("file:") { #expect(item.file == nil, "\(address) was staged as a file") }
            }
        }
        // A message that looks like an attachment line is the person's own text, sent exactly as typed.
        let typed = "@file:/etc/passwd\n[attached: secrets.txt]"
        #expect(ShareRules.promptText(message: typed, shared: [], fileRefs: [], hasImages: false) == typed)
    }

    // MARK: §12.7 Two processes at once

    private func nousItem(_ gateway: ShareStubGateway, _ pair: (access: String, refresh: String), lapsing: Bool) -> [String: Any] {
        let now = Date().timeIntervalSince1970
        // Lapsing: the pair arrived an hour ago and ends within half a minute, so whoever reads it renews it.
        let entry = lapsing ? ShareSamples.nous(access: pair.access, refresh: pair.refresh, expiresAt: now + 30, user: "u1", obtainedAt: now - 3600)
                            : ShareSamples.nous(access: pair.access, refresh: pair.refresh, user: "u1")
        return ShareSamples.item(url: gateway.url, username: "nous:u1", cookies: nil, nous: entry)
    }

    /// What the app does when its token lapses: reads the Keychain's pair, rotates it, saves the new one.
    private func appRenews(_ family: ShareNousFamily, _ gateway: ShareStubGateway, _ keychain: MemoryShareKeychain) -> Bool {
        guard let item = keychain.value, let held = ShareAccounts.current(in: item)?.nous, let rotated = family.rotate(held.refreshToken) else { return false }
        keychain.set(json: nousItem(gateway, rotated, lapsing: false))
        return true
    }

    @Test func theAppAndAShareRenewingOneNousPairInTurnNeverReplayIt() async throws {
        let gateway = ShareStubGateway(), family = ShareNousFamily()
        gateway.onHTTP { family.answer($0) }
        let keychain = MemoryShareKeychain(json: nousItem(gateway, family.pair, lapsing: true))
        var dice = ShareDice(seed: 7)
        var shareRenewed = 0
        for round in 0..<100 {
            // Time passes: the pair in the Keychain is about to lapse again.
            keychain.set(json: nousItem(gateway, family.pair, lapsing: true))
            let appFirst = Bool.random(using: &dice)
            if appFirst { #expect(appRenews(family, gateway, keychain), "round \(round)") }
            let before = family.counts.refreshes
            let failure = await shareFailure {
                try await gateway.sender(keychain).send(ShareRequest(bot: ShareSamples.bot(), message: "Round \(round)"), roster: gateway.roster(username: "nous:u1"))
            }
            #expect(failure == nil, "round \(round), app first \(appFirst): \(failure.map { "\($0)" } ?? "")")
            // The share renews only a pair that needs it, once, and leaves the new one where the app reads it.
            #expect(family.counts.refreshes - before == (appFirst ? 0 : 1), "round \(round)")
            shareRenewed += family.counts.refreshes - before
            if !appFirst { #expect(appRenews(family, gateway, keychain), "round \(round): the app could not use what the share saved") }
            let held = ShareAccounts.current(in: try #require(keychain.value))?.nous
            #expect(held?.refreshToken == family.pair.refresh && held?.accessToken == family.pair.access, "round \(round)")
        }
        #expect(family.counts.replayed == 0 && !family.counts.ended)
        #expect(gateway.count("prompt.submit") == 100)
        #expect(shareRenewed > 20 && shareRenewed < 80)                          // both orders really happened
    }

    @Test func aTrulySimultaneousNousRenewalEndsTheSessionOnceAndNeverLoops() async throws {
        // The owner's known remaining risk: the app spends the pair after the share has read the Keychain for its
        // renewal and before the share's own renewal arrives. Portal then sees a spent token and ends the session.
        for round in 0..<25 {
            let gateway = ShareStubGateway(), family = ShareNousFamily()
            let keychain = MemoryShareKeychain(json: nousItem(gateway, family.pair, lapsing: true))
            let raced = LoadCounter()
            gateway.onHTTP { seen in
                // The app's renewal lands first, and it has not saved the new pair yet.
                if seen.path == "/auth/native/refresh", raced.count("app") == 0 {
                    raced.hit("app")
                    _ = family.rotate(family.pair.refresh)
                }
                return family.answer(seen)
            }
            let started = Date()
            let failure = await shareFailure {
                try await gateway.sender(keychain).send(ShareRequest(bot: ShareSamples.bot(), message: "Round \(round)"), roster: gateway.roster(username: "nous:u1"))
            }
            #expect(failure == .sessionEnded && failure?.blocksSheet == true, "round \(round)")
            #expect(failure?.message == "Your gateway ended this iPhone’s session. Open Hermes HQ to sign in again.")
            // One renewal from the share, never a second; nothing else went out; the Keychain was not touched.
            #expect(gateway.count("POST /auth/native/refresh") == 1, "round \(round): \(gateway.labels)")
            #expect(gateway.labels == ["POST /auth/native/refresh"], "round \(round): \(gateway.labels)")
            #expect(family.counts.replayed == 1 && keychain.counts.updates == 0, "round \(round)")
            #expect(Date().timeIntervalSince(started) < 5, "round \(round)")
        }
    }

    @Test func twoSharesAtOnceOnOneKeychainBothArrive() async throws {
        // Two share sheets (two host apps) sending at the same moment with the same signed-in session.
        let gateway = ShareStubGateway(), keychain = gateway.keychain()
        let folder = ShareTemp.folder("stress-pair")
        for round in 0..<40 {
            let first = try attachment("a\(round).txt", in: folder, bytes: 512), second = try attachment("b\(round).txt", in: folder, bytes: 512)
            let hermes = ShareSamples.bot("default", name: "Hermes", session: "20260929_120000_aabbcc01")
            let ended = await shareOutcomes([
                (gateway.sender(keychain), ShareRequest(bot: ShareSamples.bot(), message: "One \(round)", attachments: [first]), gateway.roster()),
                (gateway.sender(keychain), ShareRequest(bot: hermes, message: "Two \(round)", attachments: [second]), gateway.roster()),
            ])
            #expect(ended == [nil, nil], "round \(round): \(ended)")
        }
        let prompts = gateway.events.filter { $0.label == "prompt.submit" }.map(\.text)
        #expect(prompts.count == 80)
        #expect(Set(prompts.map { String($0.prefix(while: { $0 != "\n" })) }).count == 80)          // each one once
        #expect(gateway.closed == 80 && keychain.counts.updates == 0)
    }

    // MARK: §12.2 Speed, the app's side

    @Test @MainActor func theAppsSideCostsTheMainThreadAlmostNothing() async throws {
        let folder = ShareTemp.folder("stress-speed"), store = ShareStore(folder: folder)
        let account = StoredAccount(url: ShareSamples.url, username: ShareSamples.username,
                                    cookies: [SavedCookie(name: "hermes_session_at", value: "a", domain: "127.0.0.1")], label: "Fixture")
        let bots = (0..<200).map { shareTestBot("bot\($0)", name: "Bot \($0)") }
        let writer = ShareRosterWriter(store: store, current: { account }, face: { _ in Data([0x89, 0x50, 0x4e, 0x47]) })
        let id = try #require(account.gatewayAccount?.id)
        // The debounce: 200 bots change, and the roster is on disk within a second and a half (0.8 s of it is the wait).
        var best = Double.infinity, quickest = Double.infinity
        for _ in 0..<3 {
            writer.clear()
            let started = Date()
            writer.schedule(bots: bots, account: id)
            quickest = min(quickest, Date().timeIntervalSince(started))
            var waited = 0
            while store.roster == nil, waited < 400 { try await Task.sleep(nanoseconds: 10_000_000); waited += 1 }
            #expect(store.roster?.bots.count == 200)
            best = min(best, Date().timeIntervalSince(started))
            if best <= 1.5 { break }
        }
        #expect(best <= 1.5, "bots changed → roster.json took \(best) s")
        #expect(quickest < 0.008, "schedule took \(quickest * 1000) ms on the main thread")
        // With the faces already on disk, a hundred more changes cost the main thread under 8 ms each.
        let started = Date()
        for _ in 0..<100 { writer.schedule(bots: bots, account: id) }
        let each = Date().timeIntervalSince(started) / 100
        #expect(each < 0.008, "schedule costs \(each * 1000) ms")
        _ = await writer.writeNow()
        // Coming to the foreground with no note is one check for a file.
        let noted = Date()
        for _ in 0..<200 { #expect(!store.hasSentNote) }
        let check = Date().timeIntervalSince(noted) / 200
        #expect(check < 0.002, "the note check costs \(check * 1000) ms")
        #expect(writer.enabled)
    }
}
