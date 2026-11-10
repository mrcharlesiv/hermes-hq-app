import Foundation
import Synchronization
import Testing
@testable import HermesHQNative

// Acceptance checks 6, 8 and 9 of docs/spec/1x-attachments.md §15.1: the upload queue against a scripted transfers
// client, and the send pipeline (attach order and exact params, stale-runtime recovery, Stop, refusal, leaving the
// chat) against the scripted gateway the chat tests use.

/// A GatewayClient with file transfers: REST and RPC through `FakeGatewayClient`, uploads scripted and recorded.
nonisolated final class FakeTransferClient: GatewayFileTransfers, Sendable {
    struct Upload: Sendable { var path: String; var query: [URLQueryItem]; var contentType: String; var body: Data }
    struct RestCall: Sendable { var method: String; var path: String; var body: Data? }
    typealias UploadResponder = @Sendable (_ upload: Upload, _ attempt: Int) async throws -> Data
    /// Writes the body to `file` (or throws); `attempt` counts downloads so far.
    typealias DownloadResponder = @Sendable (_ path: String, _ query: [URLQueryItem], _ file: URL, _ attempt: Int) async throws -> Void

    let inner = FakeGatewayClient()
    let account: GatewayAccount
    private let state = Mutex<(uploads: [Upload], rest: [RestCall], responder: UploadResponder?)>(([], [], nil))
    private let downloads = Mutex<(count: Int, responder: DownloadResponder?)>((0, nil))

    init() {
        account = GatewayAccount(id: "http://127.0.0.1:9799|uploads-\(UUID().uuidString)", baseURL: URL(string: "http://127.0.0.1:9799")!,
                                 kind: .password, username: "tester", label: "fixture")
    }

    var uploads: [Upload] { state.withLock { $0.uploads } }
    var restCalls: [RestCall] { state.withLock { $0.rest } }
    func onUpload(_ responder: @escaping UploadResponder) { state.withLock { $0.responder = responder } }
    func onDownload(_ responder: @escaping DownloadResponder) { downloads.withLock { $0.responder = responder } }
    var downloadCount: Int { downloads.withLock { $0.count } }

    /// The `path` field of a multipart body.
    static func destination(_ body: Data) -> String {
        let text = String(decoding: body.prefix(4096), as: UTF8.self)
        guard let start = text.range(of: "name=\"path\"\r\n\r\n"), let end = text.range(of: "\r\n--", range: start.upperBound..<text.endIndex) else { return "" }
        return String(text[start.upperBound..<end.lowerBound])
    }

    func upload(_ path: String, query: [URLQueryItem], contentType: String, bodyFile: URL, timeout: TimeInterval, priority: Float,
                progress: (@Sendable (Int64, Int64) -> Void)?) async throws -> Data {
        let body = (try? Data(contentsOf: bodyFile)) ?? Data()
        let upload = Upload(path: path, query: query, contentType: contentType, body: body)
        let (attempt, responder) = state.withLock { s -> (Int, UploadResponder?) in s.uploads.append(upload); return (s.uploads.count, s.responder) }
        progress?(Int64(body.count), Int64(body.count))
        if let responder { return try await responder(upload, attempt) }
        return Data("{\"path\":\"\(Self.destination(body))\"}".utf8)
    }

    func download(_ path: String, query: [URLQueryItem], to file: URL, ceiling: Int64, priority: Float,
                  progress: (@Sendable (Int64, Int64) -> Void)?) async throws -> HTTPURLResponse {
        let (attempt, responder) = downloads.withLock { d -> (Int, DownloadResponder?) in d.count += 1; return (d.count, d.responder) }
        guard let responder else { throw HTTPError(status: 404, body: "not in this fake") }
        try await responder(path, query, file, attempt)
        return HTTPURLResponse(url: URL(string: "http://127.0.0.1:9799\(path)")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }

    func rest(_ method: String, _ path: String, query: [URLQueryItem], body: Data?) async throws -> Data {
        state.withLock { $0.rest.append(RestCall(method: method, path: path, body: body)) }
        if method == "GET" && path == "/api/files" { return Data("{\"path\":\"/r\"}".utf8) }
        return Data("{}".utf8)
    }

    func call(_ method: String, _ params: JSONValue, timeout: Duration) async throws -> JSONValue {
        try await inner.call(method, params, timeout: timeout)
    }
    func events() -> AsyncStream<GatewayEvent> { inner.events() }
    func connectionStates() -> AsyncStream<ConnectionState> { inner.connectionStates() }
    var latestReady: JSONValue? { inner.latestReady }
    func appDidBecomeActive() {}
    func appDidEnterBackground() {}
    func shutdown() {}
}

/// A one-shot latch for scripted answers.
nonisolated final class Latch: Sendable {
    private let pair = AsyncStream<Void>.makeStream()
    func open() { pair.continuation.yield(); pair.continuation.finish() }
    func wait() async throws {
        for await _ in pair.stream { return }
        try Task.checkCancellation()
    }
}

@MainActor
private func makeFile(_ center: AttachmentCenter, kind: DraftAttachment.Kind, name: String, upload: DraftAttachment.Upload = .waiting) throws -> DraftAttachment {
    let id = UUID().uuidString
    _ = try center.staging.write(Data("xyz".utf8), id: id, name: name)
    return DraftAttachment(id: id, kind: kind, name: name, localFile: "\(id)/\(name)", byteSize: 3,
                           pixelWidth: kind == .image ? 30 : nil, pixelHeight: kind == .image ? 40 : nil,
                           typeIdentifier: kind == .image ? "public.jpeg" : "com.adobe.pdf", upload: upload)
}

@Suite("Attachments: upload queue (§6.3, check 8)", .serialized)
@MainActor
struct AttachmentUploadQueueTests {
    private func center() -> (AttachmentCenter, FakeTransferClient) {
        let client = FakeTransferClient()
        let center = AttachmentCenter(account: client.account, client: client)
        center.debugSetConnectionReady(true)
        return (center, client)
    }

    private func state(_ center: AttachmentCenter, _ id: String) -> DraftAttachment.Upload? { center.items[id]?.upload }

    @Test func uploadsStartAtOnceOneAtATimeOldestFirst() async throws {
        let (center, client) = center()
        let gate = Latch()
        client.onUpload { upload, _ in
            try await gate.wait()
            return Data("{\"path\":\"\(FakeTransferClient.destination(upload.body))\"}".utf8)
        }
        let a = try makeFile(center, kind: .image, name: "photo.jpg")
        let b = try makeFile(center, kind: .file, name: "report.pdf")
        center.add(a, scope: "s", profile: "default")
        center.add(b, scope: "s", profile: "default")
        #expect(await waitUntil { client.uploads.count == 1 })
        try? await Task.sleep(for: .milliseconds(150))
        #expect(client.uploads.count == 1)                                  // one at a time
        #expect(FakeTransferClient.destination(client.uploads[0].body).hasSuffix("/photo.jpg"))   // oldest first
        #expect(FakeTransferClient.destination(client.uploads[0].body).hasPrefix("/r/.dispatch-attachments/"))
        #expect(client.uploads[0].query == [URLQueryItem(name: "profile", value: "default")])
        #expect(client.uploads[0].path == "/api/files/upload-stream")
        gate.open()
        #expect(await waitUntil { center.items[b.id]?.isUploaded == true })
        #expect(center.items[a.id]?.isUploaded == true)
        #expect(client.uploads.count == 2)
        guard case .uploaded(let path, let folder)? = state(center, a.id) else { Issue.record("not uploaded"); return }
        #expect(path.hasPrefix(folder + "/"))
    }

    @Test func removingCancelsAndDeletesAnUploadedFolder() async throws {
        let (center, client) = center()
        let a = try makeFile(center, kind: .file, name: "report.pdf")
        center.add(a, scope: "s", profile: "default")
        #expect(await waitUntil { center.items[a.id]?.isUploaded == true })
        let folder = try #require(center.items[a.id]?.stagingFolder)
        center.remove(a.id, scope: "s")
        #expect(await waitUntil { client.restCalls.contains { $0.method == "DELETE" } })
        let delete = try #require(client.restCalls.first { $0.method == "DELETE" })
        #expect(delete.path == "/api/files")
        let body = try JSONValue.parse(delete.body ?? Data())
        #expect(body == ["path": .string(folder), "recursive": true])
        #expect(!FileManager.default.fileExists(atPath: center.staging.root.appending(path: a.id).path))

        // Removed while uploading: the upload is cancelled and nothing is left behind.
        let gate = Latch()
        client.onUpload { _, _ in try await gate.wait(); return Data("{\"path\":\"/r/x\"}".utf8) }
        let b = try makeFile(center, kind: .file, name: "notes.md")
        center.add(b, scope: "s", profile: "default")
        #expect(await waitUntil { if case .uploading? = center.items[b.id]?.upload { return true } else { return false } })
        center.remove(b.id, scope: "s")
        #expect(center.items[b.id] == nil)
        #expect(await waitUntil { center.debugCurrent == nil })
        #expect(center.draft("s").attachments.isEmpty)
    }

    @Test func serverErrorRetriesOnceAfterTwoSecondsThenFails() async throws {
        let (center, client) = center()
        client.onUpload { _, _ in throw HTTPError(status: 500, body: "boom") }
        let a = try makeFile(center, kind: .image, name: "photo.jpg")
        center.add(a, scope: "s", profile: "default")
        #expect(await waitUntil { client.uploads.count == 1 })
        try? await Task.sleep(for: .milliseconds(1200))
        #expect(client.uploads.count == 1)                                  // the retry waits 2 s
        #expect(await waitUntil(timeout: .seconds(4)) { center.items[a.id]?.failure != nil })
        #expect(client.uploads.count == 2)
        #expect(center.items[a.id]?.failure?.reason == "Couldn’t upload “photo.jpg” (gateway error 500).")
        #expect(center.items[a.id]?.failure?.retryable == true)
        // Try Again uploads it.
        client.onUpload { upload, _ in Data("{\"path\":\"\(FakeTransferClient.destination(upload.body))\"}".utf8) }
        center.retry(a.id)
        #expect(await waitUntil { center.items[a.id]?.isUploaded == true })
    }

    @Test func staleRootIsReadAgainOnce() async throws {
        let (center, client) = center()
        client.onUpload { upload, attempt in
            if attempt == 1 { throw HTTPError(status: 403, body: "Path outside managed files root") }
            return Data("{\"path\":\"\(FakeTransferClient.destination(upload.body))\"}".utf8)
        }
        let a = try makeFile(center, kind: .file, name: "report.pdf")
        center.add(a, scope: "s", profile: "default")
        #expect(await waitUntil { center.items[a.id]?.isUploaded == true })
        #expect(client.restCalls.filter { $0.method == "GET" && $0.path == "/api/files" }.count == 2)
        #expect(client.uploads.count == 2)
    }

    @Test func offlineWaitsAndStartsWhenReady() async throws {
        let (center, client) = center()
        client.onUpload { upload, attempt in
            if attempt == 1 { throw GatewayFailure.offline }
            return Data("{\"path\":\"\(FakeTransferClient.destination(upload.body))\"}".utf8)
        }
        let a = try makeFile(center, kind: .file, name: "report.pdf")
        center.add(a, scope: "s", profile: "default")
        #expect(await waitUntil { client.uploads.count == 1 })
        #expect(await waitUntil { if case .waiting? = center.items[a.id]?.upload { return true } else { return false } })
        try? await Task.sleep(for: .milliseconds(200))
        #expect(client.uploads.count == 1)                                  // nothing until the connection is back
        client.inner.setConnection(.ready)
        #expect(await waitUntil { center.items[a.id]?.isUploaded == true })
    }

    /// A brief path blip fails the upload "offline" while the socket stays ready: no new `ready` comes, so a timer retries.
    @Test(arguments: [GatewayFailure.offline, GatewayFailure.tailscaleOff])
    func offlineWhileTheSocketStaysReadyRetries(_ failure: GatewayFailure) async throws {
        let (center, client) = center()
        center.waitingBackoff = [.milliseconds(100)]
        client.onUpload { upload, attempt in
            if attempt == 1 { throw failure }
            return Data("{\"path\":\"\(FakeTransferClient.destination(upload.body))\"}".utf8)
        }
        let a = try makeFile(center, kind: .file, name: "report.pdf")
        center.add(a, scope: "s", profile: "default")
        #expect(await waitUntil { center.items[a.id]?.isUploaded == true })
        #expect(client.uploads.count == 2)
    }

    /// The socket really went down: no timer retry; the next `ready` starts it.
    @Test func offlineWithTheSocketDownWaitsForReady() async throws {
        let (center, client) = center()
        center.waitingBackoff = [.milliseconds(50)]
        client.onUpload { upload, attempt in
            if attempt == 1 {
                client.inner.setConnection(.offline(reason: "no network"))
                throw GatewayFailure.offline
            }
            return Data("{\"path\":\"\(FakeTransferClient.destination(upload.body))\"}".utf8)
        }
        let a = try makeFile(center, kind: .file, name: "report.pdf")
        center.add(a, scope: "s", profile: "default")
        #expect(await waitUntil { client.uploads.count == 1 })
        try? await Task.sleep(for: .milliseconds(300))
        #expect(client.uploads.count == 1)
        client.inner.setConnection(.ready)
        #expect(await waitUntil { center.items[a.id]?.isUploaded == true })
        #expect(client.uploads.count == 2)
    }

    /// Repeated failures keep retrying past the end of the schedule (its last wait repeats).
    @Test func repeatedOfflineFailuresKeepRetrying() async throws {
        let (center, client) = center()
        center.waitingBackoff = [.milliseconds(10), .milliseconds(20), .milliseconds(30), .milliseconds(40)]
        client.onUpload { upload, attempt in
            if attempt <= 5 { throw GatewayFailure.offline }
            return Data("{\"path\":\"\(FakeTransferClient.destination(upload.body))\"}".utf8)
        }
        let a = try makeFile(center, kind: .file, name: "report.pdf")
        center.add(a, scope: "s", profile: "default")
        #expect(await waitUntil { center.items[a.id]?.isUploaded == true })
        #expect(client.uploads.count == 6)
    }

    @Test func tooBigForTheGatewayIsFinal() async throws {
        let (center, client) = center()
        client.onUpload { _, _ in throw HTTPError(status: 413, body: "File is too large") }
        let a = try makeFile(center, kind: .file, name: "clip.mov")
        center.add(a, scope: "s", profile: "default")
        #expect(await waitUntil { center.items[a.id]?.failure != nil })
        #expect(center.items[a.id]?.failure?.reason == "“clip.mov” is too big for your gateway.")
        #expect(center.items[a.id]?.failure?.retryable == false)
        #expect(client.uploads.count == 1)
    }
}

@Suite("Attachments: send pipeline (§6.4, checks 6 and 9)", .serialized)
@MainActor
struct AttachmentPipelineTests {
    struct Setup {
        let h: ChatHarness
        let s: LiveChatSession
        let center: AttachmentCenter
        let photo1: DraftAttachment
        let file: DraftAttachment
        let photo2: DraftAttachment
        var scope: String { s.draftScope }
    }

    private static let attachMethods: Set<String> = ["image.attach", "file.attach", "image.detach", "prompt.submit", "session.resume"]

    private func setup() async throws -> Setup {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        let center = AttachmentCenter(account: h.client.account, client: h.client)
        center.debugReset()
        AttachmentCenter.debugRegister(center)
        #expect(await h.open())
        func uploaded(_ kind: DraftAttachment.Kind, _ name: String) throws -> DraftAttachment {
            var a = try makeFile(center, kind: kind, name: name)
            a.upload = .uploaded(path: "/r/.dispatch-attachments/\(a.id)/\(name)", folder: "/r/.dispatch-attachments/\(a.id)")
            center.add(a, scope: s.draftScope, profile: "default")
            return a
        }
        return Setup(h: h, s: s, center: center, photo1: try uploaded(.image, "photo.jpg"), file: try uploaded(.file, "report.pdf"),
                     photo2: try uploaded(.image, "chart.jpg"))
    }

    /// A gateway that accepts the attaches (files copied out of staging) and admits the prompt as row 77.
    private nonisolated static func answer(_ method: String, _ params: JSONValue, resume: JSONValue) throws -> JSONValue {
        switch method {
        case "session.resume", "session.activate": return resume
        case "image.attach": return ["attached": true, "path": params["path"] ?? .null, "count": 1]
        case "file.attach":
            return ["attached": true, "name": "report.pdf", "path": "/home/att/report.pdf", "ref_path": "/home/att/report.pdf",
                    "ref_text": "@file:/home/att/report.pdf", "uploaded": true]
        case "image.detach": return ["detached": true, "count": 0]
        case "prompt.submit": return ["status": "streaming", "user_row_id": 5000]
        case "session.interrupt": return ["status": "interrupted"]
        default: return [:]
        }
    }

    private func methods(_ h: ChatHarness) -> [String] {
        h.client.calls.map(\.method).filter { Self.attachMethods.contains($0) && $0 != "session.resume" }
    }

    @Test func attachesInTrayOrderWithExactParamsThenSubmits() async throws {
        let t = try await setup()
        let resume = try ChatFixtures.json("perf-resume.json")["result"]!
        t.h.client.onCall { method, params in try Self.answer(method, params, resume: resume) }
        let taken = t.center.takeForSend(t.scope).attachments
        #expect(taken.map(\.id) == [t.photo1.id, t.file.id, t.photo2.id])
        t.s.send("look", attachments: taken)
        t.s.flushChanges()
        // The bubble shows at once, with the phone copies.
        let bubble = try #require(t.h.lastUser)
        #expect(bubble.plainText == "look")
        #expect(t.s.attachments(for: bubble.id).map(\.source) == [.local(draftId: t.photo1.id), .local(draftId: t.file.id),
                                                                    .local(draftId: t.photo2.id)])
        #expect(await waitUntil { t.h.lastUser?.isPending == false })
        #expect(methods(t.h) == ["image.attach", "file.attach", "image.attach", "prompt.submit"])
        let allowed: [String: Set<String>] = ["image.attach": ["session_id", "path", "profile"],
                                              "file.attach": ["session_id", "path", "name", "profile"],
                                              "prompt.submit": ["session_id", "text", "profile", "queued", "submission_id"]]
        for call in t.h.client.calls where allowed[call.method] != nil {
            let keys = Set((call.params.object ?? [:]).keys)
            #expect(keys.isSubset(of: allowed[call.method]!), "\(call.method) \(call.params)")
        }
        let attaches = t.h.client.calls("image.attach").map { $0.params["path"]?.string }
        #expect(attaches == [t.photo1.gatewayPath, t.photo2.gatewayPath])
        #expect(t.h.client.calls("file.attach").first?.params["name"] == "report.pdf")
        let submit = try #require(t.h.client.calls("prompt.submit").first)
        #expect(submit.params["text"] == "@file:/home/att/report.pdf\n\nlook")
        // The file's staging copy goes (the gateway copied it out); the photos' never do.
        #expect(await waitUntil { t.h.client.restLog.filter { $0.path == "/api/files" }.count == 1 })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(t.h.client.restLog.filter { $0.path == "/api/files" }.count == 1)
        // After the ack the bubble points at the gateway copies.
        #expect(await waitUntil {
            t.s.attachments(for: bubble.id).map(\.source) == [.gateway(path: t.photo1.gatewayPath!), .gateway(path: "/home/att/report.pdf"),
                                                               .gateway(path: t.photo2.gatewayPath!)]
        })
        #expect(t.center.draft(t.scope).attachments.isEmpty)

        // Check 6: the stored row (files first, photos after) and the local bubble are one message after a refresh.
        let rows = (try ChatFixtures.json("perf-page-latest-24.json")["messages"]?.array ?? []) + [
            ["role": "user", "content": .string("@file:/home/att/report.pdf\n\nlook\n@image:\(t.photo1.gatewayPath!)\n@image:\(t.photo2.gatewayPath!)"),
             "row_id": 5000, "timestamp": 1791585100],
        ]
        t.h.setPage("24", rows: rows)
        t.h.setPage("500", rows: rows)
        t.s.startRefresh(force: true)
        try? await Task.sleep(for: .milliseconds(300))
        t.s.flushChanges()
        let users = t.s.messages.filter { $0.role == .user && Hydration.userDisplayKey($0.plainText) == "look" }
        #expect(users.count == 1)
        #expect(t.s.attachments(for: users[0].id).count == 3)
        #expect(t.s.attachments(for: users[0].id).first(where: { $0.kind == .image })?.pixelWidth == 30)   // sizes carried over
    }

    @Test func staleRuntimeOnSubmitReattachesThePhotosOnly() async throws {
        let t = try await setup()
        let resume = try ChatFixtures.json("perf-resume.json")["result"]!
        let submits = Mutex(0)
        t.h.client.onCall { method, params in
            if method == "prompt.submit", submits.withLock({ $0 += 1; return $0 }) == 1 {
                throw RPCError(code: 4001, message: "session not found", data: nil)
            }
            return try Self.answer(method, params, resume: resume)
        }
        t.s.send("look", attachments: t.center.takeForSend(t.scope).attachments)
        #expect(await waitUntil { t.h.lastUser?.isPending == false })
        let sequence = t.h.client.calls.map(\.method).filter { Self.attachMethods.contains($0) }.drop { $0 == "session.resume" }
        #expect(Array(sequence) == ["image.attach", "file.attach", "image.attach", "prompt.submit", "session.resume",
                                    "image.attach", "image.attach", "prompt.submit"])
        #expect(t.h.client.calls("file.attach").count == 1)
        #expect(t.h.drafts.isEmpty)
    }

    @Test func staleRuntimeOnAnAttachResumesAndStartsAgain() async throws {
        let t = try await setup()
        let resume = try ChatFixtures.json("perf-resume.json")["result"]!
        let attaches = Mutex(0)
        t.h.client.onCall { method, params in
            if method == "image.attach", attaches.withLock({ $0 += 1; return $0 }) == 1 {
                throw RPCError(code: 4001, message: "session not found", data: nil)
            }
            return try Self.answer(method, params, resume: resume)
        }
        let resumesBefore = t.h.client.calls("session.resume").count
        t.s.send("look", attachments: t.center.takeForSend(t.scope).attachments)
        #expect(await waitUntil { t.h.lastUser?.isPending == false })
        #expect(t.h.client.calls("session.resume").count == resumesBefore + 1)
        #expect(methods(t.h) == ["image.attach", "image.attach", "file.attach", "image.attach", "prompt.submit"])
    }

    @Test func stopDuringTheAttachesDetachesAndReturnsTheDraft() async throws {
        let t = try await setup()
        let resume = try ChatFixtures.json("perf-resume.json")["result"]!
        let gate = Latch()
        t.h.client.onCall { method, params in
            if method == "file.attach" { try await gate.wait() }
            return try Self.answer(method, params, resume: resume)
        }
        let taken = t.center.takeForSend(t.scope).attachments
        t.s.send("look", attachments: taken)
        #expect(await waitUntil { t.h.client.calls("file.attach").count == 1 })
        t.s.stop()
        gate.open()
        #expect(await waitUntil { t.h.drafts.contains { $0.1 == "Stopped before sending" } })
        #expect(t.h.client.calls("image.detach").map { $0.params["path"]?.string } == [t.photo1.gatewayPath])
        #expect(t.h.client.calls("prompt.submit").isEmpty)
        let back = t.center.draft(t.scope).attachments
        #expect(back.map(\.id) == taken.map(\.id))
        let allUploaded = back.allSatisfy { $0.isUploaded }
        #expect(allUploaded)                                                 // a resend skips the uploads
    }

    @Test func refusalReturnsUploadedAttachments() async throws {
        let t = try await setup()
        let resume = try ChatFixtures.json("perf-resume.json")["result"]!
        t.h.client.onCall { method, params in
            if method == "image.attach" { return [:] }                         // the stock fixtures' answer
            return try Self.answer(method, params, resume: resume)
        }
        let taken = t.center.takeForSend(t.scope).attachments
        t.s.send("look", attachments: taken)
        #expect(await waitUntil { t.h.drafts.count == 1 })
        #expect(t.h.drafts.first?.1 == "Your gateway didn’t accept “photo.jpg”.")
        #expect(t.s.sendFailure?.reason == "Your gateway didn’t accept “photo.jpg”.")
        #expect(t.h.client.calls("prompt.submit").isEmpty)
        let back = t.center.draft(t.scope).attachments
        #expect(back.map(\.id) == taken.map(\.id))
        let allUploaded = back.allSatisfy { $0.isUploaded }
        #expect(allUploaded)
    }

    /// Build 337: `4090 SESSION_OWNER_BUSY` with photos (the gateway unstages them with the refusal, so a later try would
    /// go without them): no wait, the words and every attachment come back at once.
    @Test func ownerBusyWithPhotosHandsThemBackAtOnce() async throws {
        let t = try await setup()
        t.s.ownerRetryInterval = .milliseconds(20)
        let resume = try ChatFixtures.json("perf-resume.json")["result"]!
        t.h.client.onCall { method, params in
            if method == "prompt.submit" {
                throw RPCError(code: 4090, message: "The gateway is running a turn in this chat and an image cannot join its queue, "
                               + "so it was removed from this message. Nothing was sent. Send it again when the current turn ends.",
                               data: ["reason": "SESSION_OWNER_BUSY"])
            }
            return try Self.answer(method, params, resume: resume)
        }
        let taken = t.center.takeForSend(t.scope).attachments
        t.s.send("look", attachments: taken)
        #expect(await waitUntil { t.h.drafts.count == 1 })
        #expect(t.h.client.calls("prompt.submit").count == 1)
        #expect(t.s.ownerWaitNotice == nil)
        #expect(t.s.sendFailure?.body.contains("Hermes is still running a reply in this chat") == true)
        let back = t.center.draft(t.scope).attachments
        #expect(back.map(\.id) == taken.map(\.id))
    }

    @Test func leavingTheChatNeverCancelsTheSend() async throws {
        let t = try await setup()
        let resume = try ChatFixtures.json("perf-resume.json")["result"]!
        let gate = Latch()
        t.h.client.onCall { method, params in
            if method == "image.attach" { try await gate.wait() }
            return try Self.answer(method, params, resume: resume)
        }
        t.s.send("look", attachments: t.center.takeForSend(t.scope).attachments)
        #expect(await waitUntil { t.h.client.calls("image.attach").count == 1 })
        t.s.stopObserving()                                                   // Back, another chat, the app away
        gate.open()
        #expect(await waitUntil { t.h.client.calls("prompt.submit").count == 1 })
        #expect(t.h.client.calls("prompt.submit").first?.params["text"] == "@file:/home/att/report.pdf\n\nlook")
    }

    @Test func photoOnlySendAsksTheDefaultQuestionAndShowsNoWords() async throws {
        let t = try await setup()
        let resume = try ChatFixtures.json("perf-resume.json")["result"]!
        t.h.client.onCall { method, params in try Self.answer(method, params, resume: resume) }
        t.center.remove(t.file.id, scope: t.scope)
        t.center.remove(t.photo2.id, scope: t.scope)
        t.s.send("", attachments: t.center.takeForSend(t.scope).attachments)
        #expect(await waitUntil { t.h.client.calls("prompt.submit").count == 1 })
        #expect(t.h.client.calls("prompt.submit").first?.params["text"] == "What do you see in this image?")
        let rows = ChatRowBuilder.build(ChatRowBuilder.Input(messages: t.s.messages, isRunning: true, botName: "Hermes", expanded: [],
                                                             media: t.s.mediaSnapshot))
        let bubble = rows.last { $0.messageId == t.h.lastUser?.id && $0.isBubble }
        guard case .bubble(let b)? = bubble?.kind else { Issue.record("no bubble"); return }
        #expect(b.text == "")
        #expect(b.media.count == 1)
    }
}
