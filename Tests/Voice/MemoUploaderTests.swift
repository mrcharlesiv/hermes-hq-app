// A-U4 (docs/spec/1x-voice.md §9): the memo's wire pipeline against a recording fake client, end to end through
// LiveChatSession (optimistic bubble → staging → rewrite → prompt.submit).

import Foundation
import Testing
@testable import HermesHQNative

@Suite("Memo uploader and send pipeline (A-U4)", .serialized)
@MainActor
struct MemoUploaderTests {
    private let stored = "20260929_120000_aabbcc02"

    private func session(_ client: VoiceFakeClient, stored: String? = nil) async -> LiveChatSession {
        let s = LiveChatSession(client: client, account: client.account, profile: "ivy", storedSessionId: stored ?? self.stored,
                                title: "Ivy", head: nil, cache: makeTempCache(), resolveSessionId: nil, frameMode: .manual)
        s.start()
        _ = await waitUntil(timeout: .seconds(5)) { s.openSettled }
        return s
    }

    private func setUp() throws -> (VoiceFakeClient, MemoFile) {
        let client = VoiceFakeClient()
        VoiceTestStores.activate(client.account.id)
        return (client, try VoiceTestStores.recording(client.account.id))
    }

    @Test func callOrderParamsAndText() async throws {
        let (client, memo) = try setUp()
        let s = await session(client)
        let before = client.log.count
        s.sendMemo(memo, text: "")
        // The optimistic bubble shows at once with the local recording; the watchdog waits for prompt.submit.
        let bubble = try #require(s.messages.last)
        #expect(bubble.isPending)
        #expect(VoiceMemo.parse(bubble.plainText)?.path == memo.path)
        #expect(s.isRunning)
        #expect(s.watchdogTask == nil)
        #expect(await waitUntil(timeout: .seconds(5)) { client.entries("rpc prompt.submit").count == 1 })
        #expect(await waitUntil(timeout: .seconds(2)) { client.entries("DELETE /api/files").count == 1 })
        let kinds = Array(client.kinds.dropFirst(before)).filter { !$0.hasPrefix("GET /api/sessions") && $0 != "rpc session.active_list" }
        let first2 = Set(kinds.prefix(2))
        #expect(first2 == ["GET /api/config", "GET /api/files"], "config ∥ files first: \(kinds)")
        func at(_ kind: String) -> Int { kinds.firstIndex(of: kind) ?? -1 }
        #expect(at("POST /api/files/upload-stream") > 1)
        #expect(at("rpc file.attach") > at("POST /api/files/upload-stream"))
        #expect(at("DELETE /api/files") > at("rpc file.attach"))
        #expect(at("POST /api/audio/transcribe") > at("rpc file.attach"))
        #expect(at("rpc prompt.submit") > at("POST /api/audio/transcribe"))
        let attach = try #require(client.entries("rpc file.attach").first?.params?.object)
        #expect(Set(attach.keys) == ["session_id", "profile", "name", "path"])
        #expect(attach["session_id"] == .string(VoiceFakeClient.rid))
        #expect(attach["profile"] == "ivy")
        #expect(attach["name"] == "voice-memo.wav")
        let staged = try #require(attach["path"]?.string)
        #expect(staged.hasPrefix("/Users/owner/.dispatch-attachments/") && staged.hasSuffix("/voice-memo.wav"))
        let delete = try #require(client.entries("DELETE /api/files").first?.body.flatMap { try? JSONValue.parse($0) })
        #expect(delete["path"]?.string == (staged as NSString).deletingLastPathComponent)
        #expect(delete["recursive"] == true)
        for entry in client.log.dropFirst(before) where entry.kind.hasPrefix("GET /api/files") || entry.kind.hasPrefix("POST") || entry.kind.hasPrefix("DELETE") {
            #expect(entry.query == [URLQueryItem(name: "profile", value: "ivy")], "\(entry.kind) names the chat's profile")
        }
        let transcribe = try #require(client.entries("POST /api/audio/transcribe").first?.body.flatMap { try? JSONValue.parse($0) })
        #expect(transcribe["mime_type"] == "audio/wav")
        #expect(transcribe["data_url"]?.string?.hasPrefix("data:audio/wav;base64,UklGR") == true)
        let submit = try #require(client.entries("rpc prompt.submit").first?.params)
        let gatewayPath = "/Users/owner/.hermes/profiles/ivy/attachments/voice-memo.wav"
        #expect(submit["text"]?.string == "MEDIA:\"\(gatewayPath)\"\n\nVoice memo transcript: Pick up milk on the way home.")
        #expect(submit["queued"] == nil)
        // Rewritten at once; on the ack the recording moves into the playback cache under its gateway path (V9).
        #expect(await waitUntil { s.messages.contains { $0.plainText.contains("Pick up milk") && !$0.isPending } })
        #expect(MemoAccountStores.shared.cache?.local(for: gatewayPath) != nil)
        #expect(!FileManager.default.fileExists(atPath: memo.path))
    }

    @Test func multipartBodyIsByteExact() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "voice-memo-\(UUID().uuidString).m4a")
        try Data([0x00, 0x01, 0xFF]).write(to: file)
        let body = try await MemoUploader.multipartBody(file: file, destination: "/r/.dispatch-attachments/U2/voice-memo.m4a",
                                                        filename: "voice-memo.m4a", boundary: "hermes-U1")
        var expected = Data("--hermes-U1\r\nContent-Disposition: form-data; name=\"path\"\r\n\r\n/r/.dispatch-attachments/U2/voice-memo.m4a\r\n".utf8)
        expected.append(Data("--hermes-U1\r\nContent-Disposition: form-data; name=\"overwrite\"\r\n\r\nfalse\r\n".utf8))
        expected.append(Data("--hermes-U1\r\nContent-Disposition: form-data; name=\"file\"; filename=\"voice-memo.m4a\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        expected.append(Data([0x00, 0x01, 0xFF]))
        expected.append(Data("\r\n--hermes-U1--\r\n".utf8))
        #expect(body == expected)
    }

    @Test func stagingCopyStaysWhenTheGatewayKeptItInPlace() async throws {
        #expect(MemoUploader.stagedCopyReleased(uploaded: true, storedPath: "/h/.hermes/attachments/v.m4a", folder: "/h/.dispatch-attachments/U"))
        #expect(!MemoUploader.stagedCopyReleased(uploaded: false, storedPath: "/h/.hermes/attachments/v.m4a", folder: "/h/.dispatch-attachments/U"))
        #expect(!MemoUploader.stagedCopyReleased(uploaded: true, storedPath: "/h/.dispatch-attachments/U/v.m4a", folder: "/h/.dispatch-attachments/U"))
        #expect(!MemoUploader.stagedCopyReleased(uploaded: true, storedPath: "/h/.dispatch-attachments/U", folder: "/h/.dispatch-attachments/U"))
        #expect(!MemoUploader.stagedCopyReleased(uploaded: nil, storedPath: "/x.m4a", folder: "/h/.dispatch-attachments/U"))

        let (client, memo) = try setUp()
        client.onCall { method, params, attempt in
            if method == "file.attach" {
                return ["attached": true, "name": "voice-memo.wav", "path": params["path"] ?? "", "ref_text": "@file:x", "uploaded": false]
            }
            return try VoiceFakeClient.defaultCall(method, params, attempt)
        }
        let s = await session(client)
        s.sendMemo(memo, text: "")
        #expect(await waitUntil(timeout: .seconds(5)) { client.entries("rpc prompt.submit").count == 1 })
        try await Task.sleep(for: .milliseconds(150))
        #expect(client.entries("DELETE /api/files").isEmpty, "no delete when uploaded is false")
    }

    @Test func sttOffSendsTheOffWordingWithoutTranscribing() async throws {
        let (client, memo) = try setUp()
        client.onRest { method, path, body in
            if path == "/api/config" { return Data(#"{"stt":{"enabled":false}}"#.utf8) }
            return try VoiceFakeClient.defaultRest(method, path, body)
        }
        let s = await session(client)
        s.sendMemo(memo, text: "typed too")
        #expect(await waitUntil(timeout: .seconds(5)) { client.entries("rpc prompt.submit").count == 1 })
        #expect(client.entries("POST /api/audio/transcribe").isEmpty)
        let text = try #require(client.entries("rpc prompt.submit").first?.params?["text"]?.string)
        #expect(text.hasSuffix("Voice memo transcript: (unavailable: speech-to-text is off on the gateway)\n\ntyped too"))
    }

    @Test func aFailedConfigReadCountsAsOn() async throws {
        let (client, memo) = try setUp()
        client.onRest { method, path, body in
            if path == "/api/config" { throw HTTPError(status: 500, body: nil) }
            return try VoiceFakeClient.defaultRest(method, path, body)
        }
        let s = await session(client)
        s.sendMemo(memo, text: "")
        #expect(await waitUntil(timeout: .seconds(5)) { client.entries("rpc prompt.submit").count == 1 })
        #expect(client.entries("POST /api/audio/transcribe").count == 1)
    }

    @Test func transcriptionErrorSendsUnavailableWithOneNotice() async throws {
        let (client, memo) = try setUp()
        client.onRest { method, path, body in
            if path == "/api/audio/transcribe" { throw HTTPError(status: 500, body: #"{"detail":"Transcription failed"}"#) }
            return try VoiceFakeClient.defaultRest(method, path, body)
        }
        let s = await session(client)
        let notices = NoticeCounter(scope: s.memoScope)
        s.sendMemo(memo, text: "")
        #expect(await waitUntil(timeout: .seconds(5)) { client.entries("rpc prompt.submit").count == 1 })
        let text = try #require(client.entries("rpc prompt.submit").first?.params?["text"]?.string)
        #expect(text.hasSuffix("Voice memo transcript: (unavailable)"))
        #expect(notices.count == 1)
        #expect(notices.details.first?.contains("Transcription failed") == true)
    }

    @Test func anUnquotablePathSendsTheGatewaysRef() async throws {
        let (client, memo) = try setUp()
        client.onCall { method, params, attempt in
            if method == "file.attach" {
                return ["attached": true, "name": "voice\"memo.wav", "path": "/Users/owner/at\"tach/voice-memo.wav",
                        "ref_text": "@file:\"weird\"", "uploaded": true]
            }
            return try VoiceFakeClient.defaultCall(method, params, attempt)
        }
        let s = await session(client)
        s.sendMemo(memo, text: "")
        #expect(await waitUntil(timeout: .seconds(5)) { client.entries("rpc prompt.submit").count == 1 })
        #expect(client.entries("rpc prompt.submit").first?.params?["text"]?.string == "@file:\"weird\"")
        #expect(client.entries("POST /api/audio/transcribe").isEmpty)
    }

    @Test func staleRuntimeResumesOnceWithoutASecondUpload() async throws {
        let (client, memo) = try setUp()
        client.onCall { method, params, attempt in
            if method == "file.attach" && attempt == 1 { throw RPCError(code: 4001, message: "session not found", data: nil) }
            return try VoiceFakeClient.defaultCall(method, params, attempt)
        }
        let s = await session(client)
        let resumes = client.entries("rpc session.resume").count
        s.sendMemo(memo, text: "")
        #expect(await waitUntil(timeout: .seconds(5)) { client.entries("rpc prompt.submit").count == 1 })
        #expect(client.entries("rpc file.attach").count == 2)
        #expect(client.entries("rpc session.resume").count == resumes + 1)
        #expect(client.entries("POST /api/files/upload-stream").count == 1)
        let paths = client.entries("rpc file.attach").compactMap { $0.params?["path"]?.string }
        #expect(paths.count == 2 && paths[0] == paths[1], "the same uploaded path")
    }

    /// [phone-logs] Build 908: the background close came while file.attach was out, and the memo was refused ("Couldn’t
    /// Send") until the owner sent it again 11 minutes later. A link closed for the background waits for the return
    /// and attaches again: the same uploaded path, nothing refused, the memo goes out.
    @Test func aLinkClosedForTheBackgroundAttachesAgainOnTheReturn() async throws {
        let (client, memo) = try setUp()
        client.delay("rpc file.attach", .milliseconds(300))
        client.onCall { method, params, attempt in
            if method == "file.attach" && attempt == 1 { throw RPCError.connectionLost("file.attach") }
            return try VoiceFakeClient.defaultCall(method, params, attempt)
        }
        let s = await session(client)
        s.sendMemo(memo, text: "")
        #expect(await waitUntil(timeout: .seconds(5)) { client.entries("rpc file.attach").count == 1 })
        s.connection = .offline(reason: GatewayFailure.paused.code)      // the app left: the socket closed
        try await Task.sleep(for: .seconds(1.5))
        #expect(client.entries("rpc file.attach").count == 1, "nothing is tried while the app is away")
        #expect(s.sendFailure == nil && s.memoDraft == nil, "and nothing is refused")
        s.connection = .ready                                             // back
        #expect(await waitUntil(timeout: .seconds(5)) { client.entries("rpc prompt.submit").count == 1 })
        #expect(s.sendFailure == nil)
        #expect(client.entries("POST /api/files/upload-stream").count == 1)
        let paths = client.entries("rpc file.attach").compactMap { $0.params?["path"]?.string }
        #expect(paths.count == 2 && paths[0] == paths[1], "the same uploaded path")
    }

    /// A link lost with the app on screen is the gateway's trouble: refused as before (the draft comes back).
    @Test func aLinkLostOnScreenIsStillRefused() async throws {
        let (client, memo) = try setUp()
        client.onCall { method, params, attempt in
            if method == "file.attach" { throw RPCError.connectionLost("file.attach") }
            return try VoiceFakeClient.defaultCall(method, params, attempt)
        }
        let s = await session(client)
        s.sendMemo(memo, text: "")
        #expect(await waitUntil(timeout: .seconds(5)) { s.memoDraft != nil })
        #expect(s.sendFailure != nil && client.entries("rpc file.attach").count == 1)
        #expect(client.entries("rpc prompt.submit").isEmpty)
    }

    @Test func aRefusalReturnsTheDraftAndARetryPaysOnce() async throws {
        let (client, memo) = try setUp()
        client.onCall { method, params, attempt in
            if method == "prompt.submit" && attempt == 1 { throw RPCError(code: 4000, message: "Model provider is out of credits.", data: nil) }
            return try VoiceFakeClient.defaultCall(method, params, attempt)
        }
        let s = await session(client)
        var returned: [String] = []
        s.onDraftReturned = { text, _ in returned.append(text) }
        s.sendMemo(memo, text: "with words")
        #expect(await waitUntil(timeout: .seconds(5)) { s.memoDraft != nil })
        #expect(s.memoDraft?.path == memo.path, "the memo is back as this chat's draft")
        #expect(returned == ["with words"], "the typed words go back to the field")
        #expect(s.sendFailure != nil, "the Couldn’t Send card says why")
        #expect(FileManager.default.fileExists(atPath: memo.path), "the recording stays on the phone")
        // Retry into the same chat: nothing is uploaded, attached or transcribed again.
        let draft = try #require(MemoAccountStores.shared.drafts?.take(s.memoScope))
        s.sendMemo(draft, text: "with words")
        #expect(await waitUntil(timeout: .seconds(5)) { client.entries("rpc prompt.submit").count == 2 })
        #expect(client.entries("POST /api/files/upload-stream").count == 1)
        #expect(client.entries("rpc file.attach").count == 1)
        #expect(client.entries("POST /api/audio/transcribe").count == 1)
    }

    @Test func aRetryIntoAnotherChatUploadsAgain() async throws {
        let (client, memo) = try setUp()
        client.onCall { method, params, attempt in
            if method == "prompt.submit" && attempt == 1 { throw RPCError(code: 4000, message: "Refused.", data: nil) }
            return try VoiceFakeClient.defaultCall(method, params, attempt)
        }
        let first = await session(client)
        first.sendMemo(memo, text: "")
        #expect(await waitUntil(timeout: .seconds(5)) { first.memoDraft != nil })
        _ = MemoAccountStores.shared.drafts?.take(first.memoScope)
        let other = await session(client, stored: "20260929_120000_ffffff09")
        other.sendMemo(memo, text: "")
        #expect(await waitUntil(timeout: .seconds(5)) { client.entries("rpc prompt.submit").count == 2 })
        #expect(client.entries("POST /api/files/upload-stream").count == 2)
        // The transcript is kept by memo file: still one paid call.
        #expect(client.entries("POST /api/audio/transcribe").count == 1)
    }

    @Test func aFilesFailureRefusesBeforeSubmitting() async throws {
        let (client, memo) = try setUp()
        client.onRest { method, path, body in
            if path == "/api/files" { throw HTTPError(status: 500, body: #"{"detail":"Synthetic files failure"}"#) }
            return try VoiceFakeClient.defaultRest(method, path, body)
        }
        let s = await session(client)
        s.sendMemo(memo, text: "")
        #expect(await waitUntil(timeout: .seconds(5)) { s.memoDraft != nil })
        #expect(client.entries("rpc prompt.submit").isEmpty)
        #expect(client.entries("rpc file.attach").isEmpty)
        let reason = try #require(s.sendFailure?.reason)
        // The gateway's own reason, not a bare status number (audit 10-3).
        #expect(reason.contains("upload the voice memo") && reason.contains("Synthetic files failure"), "\(reason)")
        #expect(!s.isRunning)
        #expect(!s.messages.contains { $0.isPending })
    }

    @Test func aFailedAttachRemovesWhatItUploaded() async throws {
        let (client, memo) = try setUp()
        client.onCall { method, params, attempt in
            if method == "file.attach" { throw RPCError(code: 5000, message: "Attach refused.", data: nil) }
            return try VoiceFakeClient.defaultCall(method, params, attempt)
        }
        let s = await session(client)
        s.sendMemo(memo, text: "")
        #expect(await waitUntil(timeout: .seconds(5)) { s.memoDraft != nil })
        #expect(client.entries("rpc prompt.submit").isEmpty)
        // The retry uploads again (nothing was kept), so the copy this attempt staged is deleted, not left behind.
        #expect(await waitUntil(timeout: .seconds(2)) { client.entries("DELETE /api/files").count == 1 })
        let staged = try #require(client.entries("rpc file.attach").first?.params?["path"]?.string)
        let delete = try #require(client.entries("DELETE /api/files").first?.body.flatMap { try? JSONValue.parse($0) })
        #expect(delete["path"]?.string == (staged as NSString).deletingLastPathComponent)
        #expect(FileManager.default.fileExists(atPath: memo.path), "the recording stays on the phone")
    }

    @Test func aMemoQueuesWhileAReplyRuns() async throws {
        let (client, memo) = try setUp()
        let s = await session(client)
        s.send("first")
        #expect(s.isRunning)
        s.sendMemo(memo, text: "after")
        #expect(s.queuedMessages.count == 1)
        #expect(s.queuedMessages.first?.memo == memo)
        #expect(s.queuedMessages.first?.text == "after")
        // Remove: the memo returns as the draft chip, the words to the field.
        let id = try #require(s.queuedMessages.first?.id)
        #expect(s.removeQueued(id) == "after")
        #expect(s.memoDraft == memo)
    }

    @Test func deletingAQueuedMemoThrowsItAway() async throws {
        let (client, memo) = try setUp()
        let s = await session(client)
        s.send("first")
        s.sendMemo(memo, text: "after")
        let id = try #require(s.queuedMessages.first?.id)
        // Delete (audit 863 02-1): nothing comes back, neither the draft chip nor the words; the recording goes.
        s.discardQueued(id)
        #expect(s.queuedMessages.isEmpty)
        #expect(s.memoDraft == nil)
        #expect(!FileManager.default.fileExists(atPath: memo.path))
    }
}

// MARK: - Stop, leave, a new chat, another account (review round 1)

@Suite("Memo sends: Stop, leaving, new chats, account switches", .serialized)
@MainActor
struct MemoSendLifecycleTests {
    private let stored = "20260929_120000_aabbcc07"

    private func setUp() throws -> (VoiceFakeClient, MemoFile) {
        let client = VoiceFakeClient()
        VoiceTestStores.activate(client.account.id)
        return (client, try VoiceTestStores.recording(client.account.id))
    }

    private func session(_ client: VoiceFakeClient, stored: String?, resolve: (() async throws -> String)? = nil) -> LiveChatSession {
        LiveChatSession(client: client, account: client.account, profile: "ivy", storedSessionId: stored, title: "Ivy", head: nil,
                        cache: makeTempCache(), resolveSessionId: resolve, frameMode: .manual)
    }

    /// Stop while the memo uploads: it comes back as the draft at once, its bubble gone, the turn settled with no
    /// interrupt (nothing reached the gateway); the cancelled staging never attaches, transcribes or submits, and the
    /// next text send arms its silence watchdog (spec §4.3 "Stop before (g)").
    @Test func stopWhileStagingHandsTheMemoBackAtOnce() async throws {
        let (client, memo) = try setUp()
        client.delay("POST /api/files/upload-stream", .milliseconds(600))
        let s = session(client, stored: stored)
        s.start()
        _ = await waitUntil(timeout: .seconds(5)) { s.openSettled }
        var returned: [String] = []
        s.onDraftReturned = { _, reason in returned.append(reason) }
        s.sendMemo(memo, text: "")
        #expect(await waitUntil(timeout: .seconds(5)) { client.entries("POST /api/files/upload-stream").count == 1 })
        #expect(s.isRunning)
        s.stop()
        #expect(s.memoDraft == memo, "the memo is the chat's draft at once")
        #expect(!s.isRunning, "the turn settled")
        #expect(!s.messages.contains { $0.isPending || $0.interrupted || $0.plainText.contains("MEDIA:") }, "no bubble, no Stopped marker")
        #expect(s.memoSends.isEmpty)
        #expect(returned == ["Stopped before sending"])
        try await Task.sleep(for: .milliseconds(1200))
        #expect(client.entries("rpc file.attach").isEmpty)
        #expect(client.entries("POST /api/audio/transcribe").isEmpty)
        #expect(client.entries("rpc prompt.submit").isEmpty)
        #expect(client.entries("rpc session.interrupt").isEmpty, "nothing reached the gateway: no interrupt")
        #expect(returned.count == 1, "handed back once")
        #expect(FileManager.default.fileExists(atPath: memo.path))
        s.send("Next")
        #expect(s.watchdogTask != nil, "a text sent after the Stop has its watchdog")
    }

    /// [live words] An app chat (one that keeps its queue) is left while a memo waits behind a reply: the memo stays in
    /// the queue like typed words, the chat keeps listening to send it when the reply ends, and the stash holds it.
    /// (Build 573 handed it back as a draft, where it sat for 19 minutes on 2026-11-01.)
    @Test func leavingAnAppChatKeepsAQueuedMemoInTheQueue() async throws {
        let (client, memo) = try setUp()
        QueueStash.shared.purge(accountId: client.account.id)
        defer { QueueStash.shared.purge(accountId: client.account.id) }
        let s = LiveChatSession(client: client, account: client.account, profile: "ivy", storedSessionId: stored,
                                title: "Ivy", head: nil, cache: makeTempCache(), resolveSessionId: nil, frameMode: .manual)
        s.keepQueue()
        s.start()
        _ = await waitUntil(timeout: .seconds(5)) { s.openSettled }
        s.send("A slow one please")
        #expect(s.isRunning)
        s.sendMemo(memo, text: "and the eggs")
        #expect(s.queuedMessages.count == 1)
        s.stopObserving()
        #expect(s.drainingAway, "the chat keeps listening to send it")
        #expect(s.queuedMessages.first?.memo == memo)
        #expect(s.memoDraft == nil)
        let stashed = QueueStash.shared.items(accountId: client.account.id, scope: s.layoutScope)
        #expect(stashed.first?.memo == memo)
        #expect(stashed.first?.text == "and the eggs")
        #expect(FileManager.default.fileExists(atPath: memo.path))
        s.abandonAwayDrain()
    }

    /// A chat that keeps no queue (tests, previews) is left while a memo waits behind a reply: the memo comes back as the
    /// chat's draft with its words, and the chat says so when it opens next (nothing would ever drain it).
    @Test func leavingWithAQueuedMemoKeepsItAsADraft() async throws {
        let (client, memo) = try setUp()
        let controller = MemoController.shared
        let s = session(client, stored: stored)
        s.start()
        _ = await waitUntil(timeout: .seconds(5)) { s.openSettled }
        s.send("A slow one please")
        #expect(s.isRunning)
        s.sendMemo(memo, text: "and the eggs")
        #expect(s.queuedMessages.count == 1)
        s.stopObserving()
        #expect(s.queuedMessages.isEmpty)
        #expect(s.memoDraft == memo)
        #expect(MemoAccountStores.shared.drafts?.text(for: s.memoScope) == "and the eggs")
        #expect(FileManager.default.fileExists(atPath: memo.path))
        #expect(await waitUntil { controller.notice(for: s.memoScope) != nil })
        let notice = try #require(controller.notice(for: s.memoScope))
        #expect(notice.title == "Memo Saved as a Draft")
        #expect(notice.message == "It didn’t send. It’s waiting in the message field of your chat with Ivy.")
        controller.dismissNotice(scope: s.memoScope)
        #expect(client.entries("POST /api/files/upload-stream").isEmpty)
    }

    /// A brand-new chat (no stored id at touch-down): the staging is kept under the id it learns first, so a retry after a
    /// refusal reuses it and the ack forgets it.
    @Test func aBrandNewChatKeepsItsStageUnderItsStoredId() async throws {
        let (client, memo) = try setUp()
        client.onCall { method, params, attempt in
            if method == "prompt.submit" && attempt == 1 { throw RPCError(code: 5000, message: "Refused.", data: nil) }
            return try VoiceFakeClient.defaultCall(method, params, attempt)
        }
        let resolved = "20261010_090000_newchat1"
        let s = session(client, stored: nil) { resolved }
        s.start()
        s.sendMemo(memo, text: "")
        #expect(await waitUntil(timeout: .seconds(5)) { s.memoDraft != nil })
        #expect(s.memoScope.hasSuffix("|\(resolved)"))
        let draft = try #require(MemoAccountStores.shared.drafts?.take(s.memoScope))
        s.sendMemo(draft, text: "")
        #expect(await waitUntil(timeout: .seconds(5)) { client.entries("rpc prompt.submit").count == 2 })
        #expect(client.entries("POST /api/files/upload-stream").count == 1, "the retry reused the staging")
        #expect(await waitUntil { s.memoSends.isEmpty })
        #expect(MemoUploader.keptStage(memoPath: memo.path, storedId: resolved) == nil, "the ack forgot it")
    }

    /// Another account signs in while a memo is in flight: its refusal writes nothing into that account's stores (the
    /// recording is deleted instead).
    @Test func anAccountSwitchMidSendWritesNothingIntoTheOtherAccount() async throws {
        let (client, memo) = try setUp()
        client.delay("rpc prompt.submit", .milliseconds(500))
        client.onCall { method, params, attempt in
            if method == "prompt.submit" { throw RPCError(code: 5000, message: "Refused.", data: nil) }
            return try VoiceFakeClient.defaultCall(method, params, attempt)
        }
        let s = session(client, stored: stored)
        s.start()
        _ = await waitUntil(timeout: .seconds(5)) { s.openSettled }
        s.sendMemo(memo, text: "")
        #expect(await waitUntil(timeout: .seconds(5)) { client.entries("rpc prompt.submit").count == 1 })
        VoiceTestStores.activate("other-\(UUID().uuidString)")
        #expect(await waitUntil(timeout: .seconds(5)) { s.memoSends.isEmpty })
        #expect(MemoAccountStores.shared.drafts?.draft(for: s.memoScope) == nil, "nothing in the other account's drafts")
        #expect(MemoAccountStores.shared.drafts?.all.isEmpty == true)
        #expect(!FileManager.default.fileExists(atPath: memo.path), "the recording is deleted")
    }
}

/// Counts the transcription notices posted for one chat.
@MainActor final class NoticeCounter {
    private(set) var count = 0
    private(set) var details: [String] = []
    private var observer: NSObjectProtocol?

    init(scope: String) {
        observer = NotificationCenter.default.addObserver(forName: MemoSessionNotice.post, object: nil, queue: .main) { [weak self] note in
            let matches = (note.userInfo?[MemoSessionNotice.scopeKey] as? String) == scope
            let detail = note.userInfo?[MemoSessionNotice.detailKey] as? String
            MainActor.assumeIsolated {
                guard matches else { return }
                self?.count += 1
                if let detail { self?.details.append(detail) }
            }
        }
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
