import Foundation
import Network
import Synchronization
import UIKit
import Testing
@testable import HermesHQNative

// Review round for photos and files (docs/spec/1x-attachments.md): the repros the review wrote (a slow attachment send
// and the silence watchdog, Stop while an upload runs, a draft scope that changes under the screen, more than 64
// cached attachments) and the fixes around them — the resolved path Hermes keeps, an unconfirmed submit, a failed
// import under a waiting send, background expiry, cancellable downloads, inline images folded per account, generated
// image echoes, and a 401 on an upload re-sending the same body file (spec §15.1 check 8).

@MainActor
private func reviewFile(_ center: AttachmentCenter, kind: DraftAttachment.Kind, name: String,
                        upload: DraftAttachment.Upload = .waiting) throws -> DraftAttachment {
    let id = UUID().uuidString
    _ = try center.staging.write(Data("xyz".utf8), id: id, name: name)
    return DraftAttachment(id: id, kind: kind, name: name, localFile: "\(id)/\(name)", byteSize: 3,
                           pixelWidth: kind == .image ? 30 : nil, pixelHeight: kind == .image ? 40 : nil,
                           typeIdentifier: kind == .image ? "public.jpeg" : "com.adobe.pdf", upload: upload)
}

@MainActor
private func uploadedFile(_ center: AttachmentCenter, kind: DraftAttachment.Kind, name: String, scope: String) throws -> DraftAttachment {
    var a = try reviewFile(center, kind: kind, name: name)
    a.upload = .uploaded(path: "/r/.dispatch-attachments/\(a.id)/\(name)", folder: "/r/.dispatch-attachments/\(a.id)")
    center.add(a, scope: scope, profile: "default")
    return a
}

private func reviewPNG(_ w: Int, _ h: Int) -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).pngData { ctx in
        UIColor.systemTeal.setFill()
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    }
}

/// A gateway that accepts the attaches (files copied out of staging) and admits the prompt as row 5000.
private nonisolated func reviewAnswer(_ method: String, _ params: JSONValue, resume: JSONValue,
                                      resolved: (String) -> String = { $0 }) -> JSONValue {
    switch method {
    case "session.resume", "session.activate": return resume
    case "image.attach":
        return ["attached": true, "path": .string(resolved(params["path"]?.string ?? "")), "count": 1]
    case "file.attach":
        return ["attached": true, "name": "report.pdf", "path": "/home/att/report.pdf", "ref_path": "/home/att/report.pdf",
                "ref_text": "@file:/home/att/report.pdf", "uploaded": true]
    case "image.detach": return ["detached": true, "count": 0]
    case "prompt.submit": return ["status": "streaming", "user_row_id": 5000]
    case "session.interrupt": return ["status": "interrupted"]
    case "session.active_list": return ["sessions": []]
    default: return [:]
    }
}

@Suite("Attachments review: the send pipeline", .serialized)
@MainActor
struct AttachmentReviewPipelineTests {
    struct Rig {
        let h: ChatHarness
        let s: LiveChatSession
        let center: AttachmentCenter
        let resume: JSONValue
    }

    /// An open chat with its account's attachment center registered (uploads through `uploads` when given).
    private func rig(uploads: (any GatewayClient)? = nil) async throws -> Rig {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        let center = AttachmentCenter(account: h.client.account, client: uploads ?? h.client)
        center.debugReset()
        AttachmentCenter.debugRegister(center)
        #expect(await h.open())
        return Rig(h: h, s: s, center: center, resume: try ChatFixtures.json("perf-resume.json")["result"]!)
    }

    /// Review blocker: no event arrives while a send uploads and attaches; the 45 s watchdog (150 ms here) and a
    /// `running:false` heartbeat long after the send was armed must not settle its turn.
    @Test func watchdogDuringASlowAttachmentSend() async throws {
        let r = try await rig()
        let gate = Latch()
        let resume = r.resume
        r.h.client.onCall { method, params in
            if method == "image.attach" { try await gate.wait() }
            return reviewAnswer(method, params, resume: resume)
        }
        r.s.silenceTimeout = .milliseconds(150)
        _ = try uploadedFile(r.center, kind: .image, name: "photo.jpg", scope: r.s.draftScope)
        r.s.send("look", attachments: r.center.takeForSend(r.s.draftScope).attachments)
        #expect(await waitUntil { r.h.client.calls("image.attach").count == 1 })
        #expect(r.s.turn.preparingSendId != nil)
        // A resume or reconnect during a long upload says "not running": true, and not about this send's turn.
        r.s.turn.armedAt = Date().addingTimeInterval(-30)
        await r.h.emit([r.h.event("session.info", ["running": false])])
        try? await Task.sleep(for: .milliseconds(900))
        r.s.flushChanges()
        #expect(r.s.isRunning)
        #expect(r.h.client.calls("session.active_list").isEmpty)
        #expect(!r.s.messages.contains { $0.error == "Hermes ended this turn without a reply." })
        gate.open()
        #expect(await waitUntil { r.h.client.calls("prompt.submit").count == 1 })
        // From the submit on, the turn is the gateway's: the watch (and the 15 s rule) count from now.
        #expect(r.s.turn.preparingSendId == nil)
        #expect((r.s.turn.armedAt.map { Date().timeIntervalSince($0) } ?? 0) < 5)
    }

    /// Review major: Stop while the photo is still uploading hands the draft back at once (the upload keeps going).
    @Test func stopWhileTheUploadRunsReturnsTheDraft() async throws {
        let transfers = FakeTransferClient()
        let gate = Latch()
        transfers.onUpload { upload, _ in
            try await gate.wait()
            return Data("{\"path\":\"\(FakeTransferClient.destination(upload.body))\"}".utf8)
        }
        let r = try await rig(uploads: transfers)
        r.center.debugSetConnectionReady(true)
        let resume = r.resume
        r.h.client.onCall { method, params in reviewAnswer(method, params, resume: resume) }
        let photo = try reviewFile(r.center, kind: .image, name: "photo.jpg")
        r.center.add(photo, scope: r.s.draftScope, profile: "default")
        #expect(await waitUntil { transfers.uploads.count == 1 })
        r.s.send("look", attachments: r.center.takeForSend(r.s.draftScope).attachments)
        r.s.flushChanges()
        #expect(r.h.lastUser?.plainText == "look")
        try? await Task.sleep(for: .milliseconds(50))
        r.s.stop()
        #expect(await waitUntil(timeout: .seconds(1)) { r.h.drafts.contains { $0.1 == "Stopped before sending" } })
        #expect(r.center.draft(r.s.draftScope).attachments.map(\.id) == [photo.id])
        r.s.flushChanges()
        #expect(!r.s.messages.contains { $0.isLocal && $0.role == .user && $0.plainText == "look" })
        #expect(r.h.client.calls("image.attach").isEmpty && r.h.client.calls("prompt.submit").isEmpty)
        // The upload itself went on: it lands in the draft, so a resend skips it.
        gate.open()
        #expect(await waitUntil { r.center.items[photo.id]?.isUploaded == true })
    }

    /// Review major: a bot chat opened before its stored id was known. The draft moves with the scope, so a refused
    /// send returns to the tray the screen watches (and what was typed early is found on the next open).
    @Test func refusedSendReturnsToTheScopeTheScreenWatches() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let stored = h.stored
        let s = LiveChatSession(client: h.client, account: h.client.account, profile: "default", storedSessionId: nil, title: "Hermes",
                                head: nil, cache: h.cache, resolveSessionId: { stored }, frameMode: .manual)
        s.onDraftReturned = { [weak h] text, reason in h?.drafts.append((text, reason)) }
        h.session = s
        let center = AttachmentCenter(account: h.client.account, client: h.client)
        center.debugReset()
        AttachmentCenter.debugRegister(center)
        let early = s.draftScope
        #expect(early.hasSuffix("|default|"))
        final class Heard { var count = 0 }
        let heard = Heard()
        let watch = center.observeDraft(early) { heard.count += 1 }
        let photo = try uploadedFile(center, kind: .image, name: "photo.jpg", scope: early)
        let resume = try ChatFixtures.json("perf-resume.json")["result"]!
        h.client.onCall { method, params in
            if method == "image.attach" { return [:] }                         // refused: "didn't accept"
            return reviewAnswer(method, params, resume: resume)
        }
        s.send("look", attachments: center.takeForSend(early).attachments)
        #expect(await waitUntil { h.drafts.count == 1 })
        #expect(s.draftScope == early + stored)
        #expect(center.draft(s.draftScope).attachments.map(\.id) == [photo.id])
        #expect(center.draft(early).attachments.isEmpty)
        let before = heard.count
        center.setText("again", scope: s.draftScope, profile: "default")
        center.remove(photo.id, scope: s.draftScope)
        #expect(heard.count > before)                                          // the screen's watch moved with it
        withExtendedLifetime(watch) {}
    }

    @Test func wordsTypedBeforeTheIdResolvesMoveWithTheChat() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let stored = h.stored
        let s = LiveChatSession(client: h.client, account: h.client.account, profile: "default", storedSessionId: nil, title: "Hermes",
                                head: nil, cache: h.cache, resolveSessionId: { stored }, frameMode: .manual)
        h.session = s
        let center = AttachmentCenter(account: h.client.account, client: h.client)
        center.debugReset()
        AttachmentCenter.debugRegister(center)
        let early = s.draftScope
        center.setText("half a thought", scope: early, profile: "default")
        let photo = try uploadedFile(center, kind: .image, name: "photo.jpg", scope: early)
        #expect(await h.open())
        #expect(center.draft(s.draftScope).text == "half a thought")
        #expect(center.draft(s.draftScope).attachments.map(\.id) == [photo.id])
        #expect(center.draft(early).text.isEmpty)
    }

    /// 2026-11-08: Home's row said "Draft: This is done" and its chat opened empty. Words left under the bot's blank
    /// scope by an open whose id never resolved come into the chat when it next opens with its id; its own words win.
    @Test func aLeftoverDraftComesIntoTheBotChat() throws {
        let h = try ChatHarness()
        let center = AttachmentCenter(account: h.client.account, client: h.client)
        center.debugReset()
        AttachmentCenter.debugRegister(center)
        let blank = "\(h.client.account.id)|default|"
        center.setText("This is done", scope: blank, profile: "default")
        let s = LiveChatSession(client: h.client, account: h.client.account, profile: "default", storedSessionId: h.stored,
                                title: "Hermes", head: nil, cache: h.cache, resolveSessionId: nil, frameMode: .manual)
        s.adoptEarlierDraft()
        #expect(center.draft(s.draftScope).text == "This is done")
        #expect(center.draft(blank).text.isEmpty)

        center.setText("older", scope: blank, profile: "default")
        center.setText("mine", scope: s.draftScope, profile: "default")
        s.adoptEarlierDraft()
        #expect(center.draft(s.draftScope).text == "mine")
        #expect(center.draft(blank).text.isEmpty)
    }

    /// Hermes keeps `Path.resolve()` of the staged path: the bubble, `image.detach` and the media cache use its answer.
    @Test func theResolvedPathIsTheOneKept() async throws {
        let r = try await rig()
        let resume = r.resume
        r.h.client.onCall { method, params in reviewAnswer(method, params, resume: resume, resolved: { "/private" + $0 }) }
        let photo = try uploadedFile(r.center, kind: .image, name: "photo.jpg", scope: r.s.draftScope)
        r.s.send("look", attachments: r.center.takeForSend(r.s.draftScope).attachments)
        r.s.flushChanges()
        let bubble = try #require(r.h.lastUser)
        let resolved = "/private" + photo.gatewayPath!
        #expect(await waitUntil { r.s.attachments(for: bubble.id).first?.source == .gateway(path: resolved) })
        #expect(r.s.knownMediaSizes[resolved]?.0 == 30)
    }

    @Test func stopDetachesTheResolvedPath() async throws {
        let r = try await rig()
        let resume = r.resume
        let gate = Latch()
        r.h.client.onCall { method, params in
            if method == "file.attach" { try await gate.wait() }
            return reviewAnswer(method, params, resume: resume, resolved: { "/private" + $0 })
        }
        let photo = try uploadedFile(r.center, kind: .image, name: "photo.jpg", scope: r.s.draftScope)
        _ = try uploadedFile(r.center, kind: .file, name: "report.pdf", scope: r.s.draftScope)
        r.s.send("look", attachments: r.center.takeForSend(r.s.draftScope).attachments)
        #expect(await waitUntil { r.h.client.calls("file.attach").count == 1 })
        r.s.stop()
        gate.open()
        #expect(await waitUntil { r.h.drafts.contains { $0.1 == "Stopped before sending" } })
        #expect(r.h.client.calls("image.detach").map { $0.params["path"]?.string } == ["/private" + photo.gatewayPath!])
    }

    /// A failed import under a send that was already waiting for it (a hardware Return, the debug hook) refuses the
    /// send instead of leaving it "Sending…" for good.
    @Test func aFailedImportWakesTheWaitingSend() async throws {
        let r = try await rig()
        let resume = r.resume
        r.h.client.onCall { method, params in reviewAnswer(method, params, resume: resume) }
        let placeholder = AttachmentImporter.placeholder(id: UUID().uuidString, kind: .image, name: "photo.jpg")
        r.center.add(placeholder, scope: r.s.draftScope, profile: "default")
        r.s.send("look", attachments: r.center.takeForSend(r.s.draftScope).attachments)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(r.s.isRunning)
        r.center.failPreparing(placeholder.id)
        #expect(await waitUntil { r.h.drafts.count == 1 })
        r.s.flushChanges()
        #expect(!r.s.isRunning)
        #expect(r.h.client.calls("prompt.submit").isEmpty)
    }

    /// An unconfirmed `prompt.submit` (timeout) still lets the phone copies go and points the bubble at the gateway.
    @Test func unconfirmedSubmitStillFinishesTheAttachments() async throws {
        let r = try await rig()
        let resume = r.resume
        r.h.client.onCall { method, params in
            if method == "prompt.submit" { throw RPCError(code: RPCError.timeoutCode, message: "timed out", data: nil) }
            return reviewAnswer(method, params, resume: resume)
        }
        let photo = try uploadedFile(r.center, kind: .image, name: "photo.jpg", scope: r.s.draftScope)
        _ = try uploadedFile(r.center, kind: .file, name: "report.pdf", scope: r.s.draftScope)
        r.s.send("look", attachments: r.center.takeForSend(r.s.draftScope).attachments)
        r.s.flushChanges()
        let bubble = try #require(r.h.lastUser)
        #expect(await waitUntil { r.s.messages.first { $0.id == bubble.id }?.error == LiveChatSession.unconfirmedMark })
        #expect(await waitUntil {
            r.s.attachments(for: bubble.id).map(\.source) == [.gateway(path: photo.gatewayPath!), .gateway(path: "/home/att/report.pdf")]
        })
        #expect(await waitUntil { r.center.items[photo.id] == nil })
        #expect(await waitUntil { r.h.client.restLog.filter { $0.path == "/api/files" }.count == 1 })
    }

    /// The row builder's media snapshot is rebuilt only after the message side data changed.
    @Test func mediaSnapshotIsCachedUntilMetaChanges() async throws {
        let r = try await rig()
        let first = r.s.mediaSnapshot
        let revision = r.s.mediaRevision
        _ = r.s.mediaSnapshot
        #expect(r.s.mediaRevision == revision)
        #expect(r.s.mediaSnapshotCache?.revision == revision)
        r.s.metaById["probe"] = MessageMeta(attachments: [MessageAttachment(kind: .image, source: .gateway(path: "/x.png"), name: "x.png")])
        #expect(r.s.mediaRevision != revision)
        #expect(r.s.mediaSnapshot.attachments["probe"]?.count == 1)
        #expect(first.attachments["probe"] == nil)
    }
}

@Suite("Attachments review: uploads, downloads, background", .serialized)
@MainActor
struct AttachmentReviewTransferTests {
    @Test func backgroundExpiryWaitsForTheForeground() async throws {
        let client = FakeTransferClient()
        let center = AttachmentCenter(account: client.account, client: client)
        center.debugSetConnectionReady(true)
        let gate = Latch()
        client.onUpload { upload, attempt in
            if attempt == 1 { try await gate.wait() }
            return Data("{\"path\":\"\(FakeTransferClient.destination(upload.body))\"}".utf8)
        }
        let a = try reviewFile(center, kind: .image, name: "photo.jpg")
        center.add(a, scope: "s", profile: "default")
        #expect(await waitUntil { client.uploads.count == 1 })
        center.debugExpireBackgroundTime()
        #expect(await waitUntil { center.debugCurrent == nil })
        try? await Task.sleep(for: .milliseconds(250))
        #expect(client.uploads.count == 1)                        // no restart while iOS keeps the app in the background
        #expect(center.items[a.id]?.upload == .waiting)
        #expect(center.debugPausedForBackground)
        center.resumeAfterBackground()
        #expect(await waitUntil { center.items[a.id]?.isUploaded == true })
        #expect(client.uploads.count == 2)
    }

    @Test func leftoverUploadBodiesAreSwept() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hqn-review-bodies-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = dir.appending(path: "a.multipart"), young = dir.appending(path: "b.multipart")
        try Data("x".utf8).write(to: old)
        try Data("y".utf8).write(to: young)
        let hourAgo = Date().addingTimeInterval(-3600)
        try FileManager.default.setAttributes([.modificationDate: hourAgo, .creationDate: hourAgo], ofItemAtPath: old.path)
        #expect(AttachmentCenter.sweepUploadBodies(in: dir) == 1)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: young.path))
    }

    /// A tile that stops waiting (reused, scrolled away) cancels a download nobody else wants, once its grace period
    /// is over; a second waiter keeps it.
    @Test func downloadsStopWhenNobodyWaits() async throws {
        let grace = MediaLoader.orphanGrace
        MediaLoader.orphanGrace = .milliseconds(200)
        defer { MediaLoader.orphanGrace = grace }
        let client = FakeTransferClient()
        let center = AttachmentCenter(account: client.account, client: client)
        AttachmentCenter.debugRegister(center)
        let cancelled = Mutex(0)
        let latches = [Latch(), Latch()]                             // one per download (a latch has one waiter)
        let png = reviewPNG(20, 10)
        client.onDownload { _, _, file, attempt in
            do { try await latches[min(attempt, 2) - 1].wait() } catch { cancelled.withLock { $0 += 1 }; throw error }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: file)
        }
        let release = latches[1]
        let context = MediaContext(accountId: client.account.id, profile: "default")
        let lonely = MessageAttachment(kind: .image, source: .gateway(path: "/x/\(UUID().uuidString).png"), name: "p.png")
        let alone = Task { try await MediaLoader.shared.image(lonely, context: context, maxPixel: 256) }
        #expect(await waitUntil { client.downloadCount == 1 })
        alone.cancel()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(cancelled.withLock { $0 } == 0)                    // still within its grace period
        #expect(await waitUntil { cancelled.withLock { $0 } == 1 })

        let shared = MessageAttachment(kind: .image, source: .gateway(path: "/x/\(UUID().uuidString).png"), name: "q.png")
        let first = Task { try await MediaLoader.shared.image(shared, context: context, maxPixel: 256) }
        let second = Task { try await MediaLoader.shared.image(shared, context: context, maxPixel: 256) }
        #expect(await waitUntil { client.downloadCount == 2 })
        first.cancel()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(cancelled.withLock { $0 } == 1)                    // the other tile still waits: it goes on
        release.open()
        let loaded = try await second.value
        #expect(loaded.pixelWidth == 20 && loaded.pixelHeight == 10)
        #expect(client.downloadCount == 2)                         // one download for both
    }

    /// Owner, Mac, 2026-10-30: three 1.7 MB screenshots restarted every few seconds (a scroll, the viewer covering the
    /// chat) and never arrived. A tile back within the grace period picks up the same download.
    @Test func aTileThatComesBackPicksUpItsDownload() async throws {
        let grace = MediaLoader.orphanGrace
        MediaLoader.orphanGrace = .seconds(5)
        defer { MediaLoader.orphanGrace = grace }
        let client = FakeTransferClient()
        AttachmentCenter.debugRegister(AttachmentCenter(account: client.account, client: client))
        let cancelled = Mutex(0)
        let latch = Latch()
        let png = reviewPNG(20, 10)
        client.onDownload { _, _, file, _ in
            do { try await latch.wait() } catch { cancelled.withLock { $0 += 1 }; throw error }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: file)
        }
        let context = MediaContext(accountId: client.account.id, profile: "default")
        let a = MessageAttachment(kind: .image, source: .gateway(path: "/x/\(UUID().uuidString).png"), name: "p.png")
        let shown = Task { try await MediaLoader.shared.image(a, context: context, maxPixel: 256) }
        #expect(await waitUntil { client.downloadCount == 1 })
        shown.cancel()                                             // scrolled away
        try? await Task.sleep(for: .milliseconds(100))
        let back = Task { try await MediaLoader.shared.image(a, context: context, maxPixel: 256) }
        try? await Task.sleep(for: .milliseconds(100))
        latch.open()
        let loaded = try await back.value
        #expect(loaded.pixelWidth == 20)
        #expect(client.downloadCount == 1)                         // not started over
        #expect(cancelled.withLock { $0 } == 0)
    }

    /// Right after app-active the network may not be up: one "not connected" failure retries once and the photo loads.
    @Test func aNotConnectedDownloadRetriesOnce() async throws {
        let client = FakeTransferClient()
        AttachmentCenter.debugRegister(AttachmentCenter(account: client.account, client: client))
        let png = reviewPNG(20, 10)
        client.onDownload { _, _, file, attempt in
            if attempt == 1 { throw URLError(.notConnectedToInternet) }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: file)
        }
        let context = MediaContext(accountId: client.account.id, profile: "default")
        let a = MessageAttachment(kind: .image, source: .gateway(path: "/x/\(UUID().uuidString).png"), name: "p.png")
        let loaded = try await MediaLoader.shared.image(a, context: context, maxPixel: 256)
        #expect(loaded.pixelWidth == 20)
        #expect(client.downloadCount == 2)
    }

    /// A server error is not a "network not up yet": no second request.
    @Test func aServerErrorDownloadDoesNotRetry() async throws {
        let client = FakeTransferClient()
        AttachmentCenter.debugRegister(AttachmentCenter(account: client.account, client: client))
        client.onDownload { _, _, _, _ in throw HTTPError(status: 503, body: nil) }
        let context = MediaContext(accountId: client.account.id, profile: "default")
        let a = MessageAttachment(kind: .image, source: .gateway(path: "/x/\(UUID().uuidString).png"), name: "p.png")
        await #expect(throws: MediaLoadError.unreachable) { try await MediaLoader.shared.image(a, context: context, maxPixel: 256) }
        try? await Task.sleep(for: .milliseconds(500))
        #expect(client.downloadCount == 1)
    }

    /// Cancelled during the retry's wait: no second download.
    @Test func aCancelledRetryWaitDownloadsNothingMore() async throws {
        let grace = MediaLoader.orphanGrace
        MediaLoader.orphanGrace = .zero
        defer { MediaLoader.orphanGrace = grace }
        let client = FakeTransferClient()
        AttachmentCenter.debugRegister(AttachmentCenter(account: client.account, client: client))
        client.onDownload { _, _, _, _ in throw URLError(.networkConnectionLost) }
        let context = MediaContext(accountId: client.account.id, profile: "default")
        let a = MessageAttachment(kind: .image, source: .gateway(path: "/x/\(UUID().uuidString).png"), name: "p.png")
        let load = Task { try await MediaLoader.shared.image(a, context: context, maxPixel: 256) }
        #expect(await waitUntil { client.downloadCount == 1 })
        load.cancel()
        _ = try? await load.value
        try? await Task.sleep(for: .milliseconds(600))
        #expect(client.downloadCount == 1)
    }

    /// The viewer's big decode stays out of the shared thumbnail cache; a tile's decode goes in.
    @Test func viewerDecodesSkipTheMemoryCache() async throws {
        let client = FakeTransferClient()
        AttachmentCenter.debugRegister(AttachmentCenter(account: client.account, client: client))
        let png = reviewPNG(20, 10)
        client.onDownload { _, _, file, _ in
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: file)
        }
        let context = MediaContext(accountId: client.account.id, profile: "default")
        let a = MessageAttachment(kind: .image, source: .gateway(path: "/x/\(UUID().uuidString).png"), name: "p.png")
        let key = try #require(MediaLoader.shared.key(a, context))
        _ = try await MediaLoader.shared.image(a, context: context, maxPixel: 4096, cache: false)
        #expect(MediaMemoryCache.shared.exact(key, bucket: MediaMemoryCache.bucket(4096)) == nil)
        _ = try await MediaLoader.shared.image(a, context: context, maxPixel: 256)
        #expect(MediaMemoryCache.shared.exact(key, bucket: MediaMemoryCache.bucket(256)) != nil)
    }

    @Test func theLimiterServesTheNewestAndForgetsTheCancelled() async throws {
        let limiter = AsyncLimiter(limit: 1)
        try await limiter.acquire()
        let order = Mutex<[String]>([])
        func waiter(_ name: String) -> Task<Void, Error> {
            Task {
                try await limiter.acquire()
                order.withLock { $0.append(name) }
            }
        }
        let b = waiter("b")
        try? await Task.sleep(for: .milliseconds(40))
        let c = waiter("c")
        try? await Task.sleep(for: .milliseconds(40))
        let d = waiter("d")
        try? await Task.sleep(for: .milliseconds(40))
        d.cancel()
        await #expect(throws: CancellationError.self) { try await d.value }
        #expect(await limiter.debugWaiting == 2)
        await limiter.release()
        #expect(await waitUntil { order.withLock { $0 } == ["c"] })
        await limiter.release()
        #expect(await waitUntil { order.withLock { $0 } == ["c", "b"] })
        _ = try await (b.value, c.value)
    }
}

@Suite("Attachments review: history and cache")
struct AttachmentReviewHistoryTests {
    @Test func moreThan64AttachmentsStillCache() throws {
        var meta = MessageMeta()
        meta.attachments = (0..<65).map { MessageAttachment(kind: .file, source: .gateway(path: "/x/f\($0).txt"), name: "f\($0).txt") }
        let message = ChatMessage(id: "stored-row-1-user", role: .user, parts: [.text("many")], timestamp: Date(), rowId: 1)
        let entry = TranscriptEntry(messages: [message], meta: [message.id: meta], savedAt: Date())
        let back = try TranscriptEntry.decode(entry.encoded())
        #expect(back.meta[message.id]?.attachments.count == AttachmentCoding.maxCached)
        #expect(back.messages.first?.plainText == "many")
    }

    /// A reply's `![alt](data:image/…)` is decoded during the fold into the account's own media folder; the text keeps
    /// only its key, the renderer never decodes, and sign-out takes the pictures with the account.
    @Test @MainActor func inlineReplyImagesAreFoldedPerAccount() throws {
        let png = reviewPNG(40, 30)
        let account = "http://127.0.0.1:9799|review-\(UUID().uuidString)"
        let row: JSONValue = ["role": "assistant", "content": .string("Here:\n\n![chart](data:image/png;base64,\(png.base64EncodedString()))\n\nDone."),
                              "row_id": 7, "timestamp": 1791640000]
        let page = InlineMediaStore.$accountId.withValue(account) { Hydration.fold([row], pageSeq: 1) }
        let text = try #require(page.messages.first?.plainText)
        #expect(!text.contains("data:image"))
        let marker = try #require(text.range(of: "#media-inline:"))
        let encoded = String(text[marker.upperBound...].prefix { $0 != ")" })
        let key = try #require(encoded.removingPercentEncoding)
        #expect(key.hasPrefix("i|"))
        let store = InlineMediaStore.forAccount(account)
        #expect(store.root.path.contains("/HQNMedia/\(AttachmentStaging.accountKey(account))/inline"))
        #expect(store.cachedURL(forKey: key) != nil)
        let ref = try #require(MarkdownMedia.ref(destination: "#media-inline:" + encoded, title: "chart", image: true))
        #expect(ref.attachment.source == .inline(mediaKey: key))
        #expect(MarkdownMedia.ref(destination: "data:image/png;base64," + png.base64EncodedString(), title: "x", image: true) == nil)
        MediaLoader.shared.purge(accountId: account)
        #expect(store.cachedURL(forKey: key) == nil)
    }

    @Test func generatedImageEchoesAreDroppedIncludingTheAgentsPath() throws {
        let info = try #require(GeneratedImageInfo.from(args: ["aspect_ratio": "square"], result: [
            "success": true, "host_image": "/home/u/.hermes/cache/fox.png", "image": "/home/u/.hermes/cache/fox.png",
            "agent_visible_image": "/root/.hermes/cache/fox.png"], running: false))
        #expect(info.echoes == ["/home/u/.hermes/cache/fox.png", "/root/.hermes/cache/fox.png"])
        let text = "Here's the fox:\nMEDIA:/root/.hermes/cache/fox.png\nSaved to /root/.hermes/cache/fox.png. Data: MEDIA:/root/data.csv\n"
            + "![fox](https://cdn.example.com/fox.png)"
        let out = ChatMediaRows.droppingEchoes(text, generated: ["gen": info])
        #expect(!out.contains("fox.png"))
        #expect(out.contains("Here's the fox:"))
        #expect(out.contains("MEDIA:/root/data.csv"))                // another file the reply sends still shows
        // Still rendering: nothing is an echo yet.
        let live = GeneratedImageInfo(source: nil, aspect: .square, success: true)
        #expect(ChatMediaRows.droppingEchoes(text, generated: ["gen": live]) == text)
        // The cache keeps them.
        var w = BinaryWriter()
        AttachmentCoding.write(info, into: &w)
        var r = BinaryReader(w.data)
        #expect(try AttachmentCoding.readGenerated(&r)?.echoes == info.echoes)
    }

    @Test @MainActor func aResumedTurnsPromptShowsItsFilesNotTheirPaths() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        var resume = try ChatFixtures.json("perf-resume.json")["result"]!.object ?? [:]
        resume["running"] = true
        resume["inflight"] = ["user": "@file:/home/att/report.pdf\n\nsummarise please", "assistant": ""]
        let snapshot = JSONValue.object(resume)
        h.client.onCall { method, _ in
            switch method {
            case "session.resume", "session.activate": return snapshot
            case "session.active_list": return ["sessions": []]
            default: return [:]
            }
        }
        h.make()
        #expect(await h.open())
        let prompt = try #require(h.session.messages.last { $0.role == .user && $0.isLocal })
        #expect(prompt.plainText == "summarise please")
        #expect(h.session.attachments(for: prompt.id).map(\.source) == [.gateway(path: "/home/att/report.pdf")])
    }
}

// MARK: - A 401 on an upload (spec §3.3, §15.1 check 8)

/// A tiny HTTP/1.1 server on 127.0.0.1 (an OS-assigned port, this process only) that records every request.
nonisolated final class LoopbackHTTP: @unchecked Sendable {
    struct Request: Sendable {
        var method: String; var path: String; var body: Data; var authorization: String? = nil
        /// Every request header, names lower-cased.
        var headers: [String: String] = [:]
    }
    typealias Responder = @Sendable (Request) -> (status: Int, body: Data)

    private let listener: NWListener
    private let queue = DispatchQueue(label: "hqn.tests.loopback-http")
    private let lock = NSLock()
    private var log: [Request] = []
    private var started = false
    private let responder: Responder
    /// Seconds to hold a request's answer (others are answered meanwhile): a slow route beside a fast one.
    private let delay: (@Sendable (Request) -> Double)?
    /// Extra response headers for a request (a 503's `Retry-After`).
    private let headers: (@Sendable (Request) -> [String: String])?

    init(delay: (@Sendable (Request) -> Double)? = nil, headers: (@Sendable (Request) -> [String: String])? = nil,
         _ responder: @escaping Responder) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        self.responder = responder
        self.delay = delay
        self.headers = headers
    }

    var requests: [Request] { lock.lock(); defer { lock.unlock() }; return log }

    func start() async throws -> UInt16 {
        // Never wait for ever on a listener that doesn't come up.
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let up = self.started
            self.lock.unlock()
            if !up { self.listener.cancel() }
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            listener.stateUpdateHandler = { [weak self, listener] state in
                guard let self else { return }
                self.lock.lock()
                let first = !self.started
                switch state {
                case .ready, .failed, .cancelled: self.started = true
                default: break
                }
                self.lock.unlock()
                guard first else { return }
                switch state {
                case .ready: continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error): continuation.resume(throwing: error)
                case .cancelled: continuation.resume(throwing: CancellationError())
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, [])
    }

    private func receive(_ connection: NWConnection, _ buffer: [UInt8]) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var bytes = buffer
            if let data { bytes += [UInt8](data) }
            while let (request, used) = Self.parse(bytes) {
                bytes.removeFirst(used)
                self.lock.lock(); self.log.append(request); self.lock.unlock()
                let (status, body) = self.responder(request)
                let extra = (self.headers?(request) ?? [:]).map { "\($0.key): \($0.value)\r\n" }.joined()
                let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: application/json\r\n"
                    + extra + "Content-Length: \(body.count)\r\n\r\n"
                let answer = Data(head.utf8) + body
                let hold = self.delay?(request) ?? 0
                if hold > 0 {
                    self.queue.asyncAfter(deadline: .now() + hold) { connection.send(content: answer, completion: .contentProcessed { _ in }) }
                } else {
                    connection.send(content: answer, completion: .contentProcessed { _ in })
                }
            }
            if done || error != nil { connection.cancel(); return }
            self.receive(connection, bytes)
        }
    }

    /// One whole request at the front of `bytes`, and how many bytes it took.
    static func parse(_ bytes: [UInt8]) -> (Request, Int)? {
        let separator: [UInt8] = [13, 10, 13, 10]
        guard bytes.count >= 4, let end = (0...(bytes.count - 4)).first(where: { Array(bytes[$0..<($0 + 4)]) == separator }) else { return nil }
        let head = String(decoding: bytes[..<end], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let first = lines.first?.split(separator: " ") ?? []
        guard first.count >= 2 else { return nil }
        var length = 0
        var authorization: String?
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            if pair.count == 2 { headers[pair[0].lowercased()] = pair[1].trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, pair[0].lowercased() == "content-length" { length = Int(pair[1].trimmingCharacters(in: .whitespaces)) ?? 0 }
            if pair.count == 2, pair[0].lowercased() == "authorization" { authorization = pair[1].trimmingCharacters(in: .whitespaces) }
        }
        let bodyStart = end + 4
        guard bytes.count >= bodyStart + length else { return nil }
        let target = String(first[1])
        let path = String(target.split(separator: "?", maxSplits: 1).first ?? Substring(target))
        return (Request(method: String(first[0]), path: path, body: Data(bytes[bodyStart..<(bodyStart + length)]),
                        authorization: authorization, headers: headers), bodyStart + length)
    }
}

@Suite("Attachments review: a 401 on a transfer", .serialized)
struct AttachmentTransferAuthTests {
    private func auth(_ base: URL, _ transport: HTTPTransport, _ vault: AccountVault) -> GatewayAuth {
        GatewayAuth(stored: StoredAccount(url: base.absoluteString, username: "tester"), base: base, transport: transport, vault: vault,
                    verified: false, persisted: false, renewals: NousRenewals())
    }

    @Test func a401RefreshesOnceAndSendsTheSameBodyFileAgain() async throws {
        let posts = Mutex(0)
        let server = try LoopbackHTTP { request in
            switch (request.method, request.path) {
            case ("POST", "/api/files/upload-stream"):
                let n = posts.withLock { $0 += 1; return $0 }
                return n == 1 ? (401, Data(#"{"detail":"Not authenticated"}"#.utf8)) : (200, Data(#"{"path":"/r/x.pdf"}"#.utf8))
            case ("GET", "/api/auth/me"): return (200, Data(#"{"user":"tester"}"#.utf8))
            default: return (404, Data(#"{"detail":"Not Found"}"#.utf8))
            }
        }
        let port = try await server.start()
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        let transport = HTTPTransport()
        defer { transport.invalidate() }
        let vault = Fixtures.testVault("transfer-401")
        defer { vault.removeAll() }
        let body = FileManager.default.temporaryDirectory.appending(path: "hqn-review-body-\(UUID().uuidString).multipart")
        try Data("BODY-BYTES-1234".utf8).write(to: body)
        defer { try? FileManager.default.removeItem(at: body) }
        let answer = try await GatewayTransfer.upload(auth: auth(base, transport, vault), transport: transport, base: base,
                                                      path: "/api/files/upload-stream", query: [URLQueryItem(name: "profile", value: "default")],
                                                      contentType: "multipart/form-data; boundary=hermes-B", bodyFile: body, timeout: 10,
                                                      priority: 0.5, progress: nil)
        #expect(String(decoding: answer, as: UTF8.self).contains("/r/x.pdf"))
        let uploads = server.requests.filter { $0.method == "POST" }
        #expect(uploads.count == 2)
        #expect(uploads.allSatisfy { $0.body == Data("BODY-BYTES-1234".utf8) })
        #expect(server.requests.filter { $0.path == "/api/auth/me" }.count == 1)
    }

    @Test func aSecond401IsTheAnswerAndADownloadPastItsCeilingLeavesNoFile() async throws {
        let server = try LoopbackHTTP { request in
            switch (request.method, request.path) {
            case ("POST", _): return (401, Data(#"{"detail":"Not authenticated"}"#.utf8))
            case ("GET", "/api/auth/me"): return (200, Data("{}".utf8))
            case ("GET", "/api/fs/download"): return (200, Data(repeating: 7, count: 4096))
            default: return (404, Data("{}".utf8))
            }
        }
        let port = try await server.start()
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        let transport = HTTPTransport()
        defer { transport.invalidate() }
        let vault = Fixtures.testVault("transfer-401b")
        defer { vault.removeAll() }
        let gateway = auth(base, transport, vault)
        let body = FileManager.default.temporaryDirectory.appending(path: "hqn-review-body-\(UUID().uuidString).multipart")
        try Data("B".utf8).write(to: body)
        defer { try? FileManager.default.removeItem(at: body) }
        await #expect(throws: HTTPError.self) {
            _ = try await GatewayTransfer.upload(auth: gateway, transport: transport, base: base, path: "/api/files/upload-stream",
                                                 query: [], contentType: "multipart/form-data; boundary=hermes-B", bodyFile: body,
                                                 timeout: 10, priority: 0.5, progress: nil)
        }
        #expect(server.requests.filter { $0.method == "POST" }.count == 2)          // sent again once, never a third time
        let target = FileManager.default.temporaryDirectory.appending(path: "hqn-review-dl-\(UUID().uuidString)")
        await #expect(throws: GatewayFailure.responseTooLarge) {
            _ = try await GatewayTransfer.download(auth: gateway, transport: transport, base: base, path: "/api/fs/download",
                                                   query: [URLQueryItem(name: "path", value: "/x.png")], to: target, ceiling: 1024,
                                                   priority: 0.5, progress: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }
}
