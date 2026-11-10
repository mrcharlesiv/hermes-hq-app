// The memo's wire pipeline before `prompt.submit` (spec 1x-voice §4.2, V1): the web shell's managed-files staging, never
// a `data_url` over the socket.
//   (e) GET  /api/config?profile=P                 stt.enabled (a failed read counts as on), in parallel with (a)
//   (a) GET  /api/files?profile=P                  the files root (cached per account and profile)
//   (b) POST /api/files/upload-stream?profile=P    multipart into <root>/.dispatch-attachments/<UUID>/voice-memo.m4a
//   (c) file.attach {session_id, profile, name, path}   (the caller's closure: resume once on 4001)
//   (d) DELETE /api/files?profile=P                the staging folder, when the gateway kept its own copy elsewhere
//   (f) POST /api/audio/transcribe?profile=P       once per recording, kept by memo file
// The result is the memo's reference text; the caller rewrites the bubble and submits it.

import Foundation
import Synchronization
import UniformTypeIdentifiers

nonisolated struct MemoSendError: Error, Sendable, CustomStringConvertible, Equatable {
    var reason: String
    var description: String { reason }
}

/// What staging produced: the text to submit for the memo, and what the gateway calls it.
nonisolated struct StagedMemo: Sendable, Equatable {
    /// `MEDIA:"<path>"\n\nVoice memo transcript: …`, or the gateway's `ref_text` when the path can't be quoted.
    var reference: String
    /// The gateway's stored copy (nil when only `ref_text` came back).
    var gatewayPath: String?
    /// The transcription call failed: the gateway's reason (the memo still goes, with "(unavailable)").
    var transcriptFailure: String?
}

nonisolated final class MemoUploader: Sendable {
    static let stagingFolder = ".dispatch-attachments"
    static let attachKeys: Set<String> = ["session_id", "profile", "path", "data_url", "name"]

    let client: any GatewayClient
    /// Retries reuse what an earlier attempt staged into the same chat (up to 8, keyed by memo file and stored chat).
    static let maxKept = 8

    init(client: any GatewayClient) { self.client = client }

    // MARK: Shared state (app session)

    private static let roots = Mutex<[String: String]>([:])
    private static let sttFlights = Mutex<[String: Task<Bool, Never>]>([:])
    /// One paid transcription per recording: the words, by the memo's local path. Missing or failed ones aren't kept.
    private static let transcripts = Mutex<[String: MemoText.Said]>([:])
    private static let staged = Mutex<[(key: String, value: StagedMemo)]>([])

    static func resetCaches() {
        roots.withLock { $0 = [:] }
        sttFlights.withLock { $0 = [:] }
        transcripts.withLock { $0 = [:] }
        staged.withLock { $0 = [] }
    }

    static func stagedKey(memoPath: String, storedId: String?) -> String { "\(memoPath)|\(storedId ?? "")" }

    static func keptStage(memoPath: String, storedId: String?) -> StagedMemo? {
        let key = stagedKey(memoPath: memoPath, storedId: storedId)
        return staged.withLock { list in list.last { $0.key == key }?.value }
    }

    static func keepStage(_ value: StagedMemo, memoPath: String, storedId: String?) {
        let key = stagedKey(memoPath: memoPath, storedId: storedId)
        staged.withLock { list in
            list.removeAll { $0.key == key }
            list.append((key, value))
            if list.count > maxKept { list.removeFirst(list.count - maxKept) }
        }
    }

    static func forgetStage(memoPath: String, storedId: String?) {
        let key = stagedKey(memoPath: memoPath, storedId: storedId)
        staged.withLock { list in list.removeAll { $0.key == key } }
    }

    private var accountId: String { client.account.id }

    private static func profileQuery(_ profile: String?) -> [URLQueryItem] {
        guard let profile, !profile.isEmpty else { return [] }
        return [URLQueryItem(name: "profile", value: profile)]
    }

    // MARK: Pipeline

    /// Steps (e), (a)–(d), (f). Throws `MemoSendError` when the memo can't reach the gateway (nothing was submitted; the
    /// memo returns as a draft). A retry into the same chat reuses what an earlier attempt staged, unless that attempt
    /// went without its transcript. A cancelled task (Stop) throws `CancellationError` between steps and never pays for
    /// a transcription.
    func stage(_ memo: MemoFile, profile: String?, storedId: String?,
               attach: @escaping @Sendable (_ params: [String: JSONValue]) async throws -> JSONValue) async throws -> StagedMemo {
        try Task.checkCancellation()
        if let kept = Self.keptStage(memoPath: memo.path, storedId: storedId), !MemoText.transcriptMissing(kept.reference) {
            return kept
        }
        let file = URL(fileURLWithPath: memo.path)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw MemoSendError(reason: "The voice memo’s recording is no longer on this \(DeviceWord.name).")
        }
        // [live words] Words this phone heard while recording go as the transcript: no speech-to-text check, no paid call.
        let phoneWords = memo.words.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        // (e) in parallel with (a).
        let stt = Task { phoneWords != nil ? true : await self.sttEnabled(profile: profile) }
        let staging: (path: String, folder: String)
        do {
            let root = try await filesRoot(profile: profile)
            try Task.checkCancellation()
            staging = try await upload(file, root: root, profile: profile)
        } catch {
            stt.cancel()
            if Task.isCancelled { throw CancellationError() }
            Self.roots.withLock { $0["\(accountId)|\(profile ?? "")"] = nil }
            AppLog.note("transfer", "voice memo upload failed")
            throw MemoSendError(reason: Self.words(error, doing: "upload the voice memo"))
        }
        if Task.isCancelled {
            stt.cancel()
            Task.detached { [self] in await self.cleanup(folder: staging.folder, profile: profile) }
            throw CancellationError()
        }
        // (c)
        let name = (memo.path as NSString).lastPathComponent
        var params: [String: JSONValue] = ["name": .string(name), "path": .string(staging.path)]
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        let result: JSONValue
        do {
            result = try await attach(params)
        } catch {
            stt.cancel()
            // Nothing keeps the uploaded copy for a retry (each one uploads into a new staging folder): it goes now, or
            // every failed attach would leave one behind on the gateway.
            let folder = staging.folder
            Task.detached { [self] in await self.cleanup(folder: folder, profile: profile) }
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            AppLog.note("transfer", "voice memo attach failed")
            throw MemoSendError(reason: Self.words(error, doing: "attach the voice memo"))
        }
        let stored = result["path"]?.string
        // (d) The staged copy goes once the gateway stored its own copy elsewhere (fire-and-forget).
        if Self.stagedCopyReleased(uploaded: result["uploaded"]?.bool, storedPath: stored, folder: staging.folder) {
            let folder = staging.folder
            Task.detached { [self] in await self.cleanup(folder: folder, profile: profile) }
        }
        guard let gatewayPath = MemoText.gatewayMemoPath(stored) else {
            // The directive can't carry this path: the gateway's own ref goes, with no transcript and no STT call.
            stt.cancel()
            let ref = result["ref_text"]?.string ?? stored.map { "@file:\($0)" } ?? ""
            let value = StagedMemo(reference: ref, gatewayPath: nil, transcriptFailure: nil)
            Self.keepStage(value, memoPath: memo.path, storedId: storedId)
            return value
        }
        // (f) Never paid for once Stop cancelled the send.
        if Task.isCancelled {
            stt.cancel()
            throw CancellationError()
        }
        let said: MemoText.Said
        var failure: String?
        if let phoneWords {
            said = .text(phoneWords)
        } else if let known = Self.transcripts.withLock({ $0[memo.path] }) {
            said = known
        } else if await stt.value == false {
            said = .off
        } else if Task.isCancelled {
            throw CancellationError()
        } else {
            let answer = await transcribe(file, mime: memo.mime, profile: profile)
            if Task.isCancelled { throw CancellationError() }
            said = answer.said
            failure = answer.failure
            if case .failed = said {} else { Self.transcripts.withLock { $0[memo.path] = said } }
        }
        let value = StagedMemo(reference: MemoText.reference(path: gatewayPath, said: said), gatewayPath: gatewayPath,
                               transcriptFailure: failure)
        Self.keepStage(value, memoPath: memo.path, storedId: storedId)
        return value
    }

    /// A staged copy can go once the gateway stored its own copy elsewhere; one it references in place (uploaded false,
    /// or its path still inside the staging folder) must stay (W:ios/App/Shared/HermesTransportShared.swift:266-271).
    static func stagedCopyReleased(uploaded: Bool?, storedPath: String?, folder: String) -> Bool {
        guard uploaded == true, let storedPath, !storedPath.isEmpty else { return false }
        let stored = AttachmentStager.slashed(storedPath), folder = AttachmentStager.slashed(folder)
        return !(stored == folder || stored.hasPrefix(folder + "/"))
    }

    // MARK: (e) Speech-to-text switch

    /// `stt.enabled` from `/api/config` (`!== false` is on; any failure counts as on). Concurrent lookups for one
    /// profile share one request; nothing is kept across sends.
    func sttEnabled(profile: String?) async -> Bool {
        let key = "\(accountId)|\(profile ?? "")"
        let client = self.client
        let task: Task<Bool, Never> = Self.sttFlights.withLock { flights in
            if let running = flights[key] { return running }
            let made = Task<Bool, Never> {
                defer { _ = MemoUploader.sttFlights.withLock { $0.removeValue(forKey: key) } }
                // [load-cache] maxAge 0: shares a read in flight, keeps nothing across sends.
                guard let data = try? await client.configData(MemoUploader.profileQuery(profile), maxAge: 0),
                      let config = try? JSONValue.parse(data) else { return true }
                return config["stt"]?["enabled"]?.bool != false
            }
            flights[key] = made
            return made
        }
        return await task.value
    }

    // MARK: (a) Files root

    func filesRoot(profile: String?) async throws -> String {
        let key = "\(accountId)|\(profile ?? "")"
        if let known = Self.roots.withLock({ $0[key] }) { return known }
        let data = try await client.rest("GET", "/api/files", query: Self.profileQuery(profile), body: nil)
        guard let root = (try? JSONValue.parse(data))?["path"]?.string, !root.isEmpty else {
            throw MemoSendError(reason: "Your gateway didn’t say where to put uploads.")
        }
        Self.roots.withLock { $0[key] = root }
        return root
    }

    // MARK: (b) Upload

    func upload(_ file: URL, root: String, profile: String?) async throws -> (path: String, folder: String) {
        guard let transfers = client as? any GatewayTransfers else { throw MemoSendError(reason: "This gateway can’t take uploads.") }
        let filename = file.lastPathComponent
        let trimmedRoot = root.hasSuffix("/") ? String(root.dropLast()) : root
        let folder = "\(trimmedRoot)/\(Self.stagingFolder)/\(UUID().uuidString)"
        let destination = "\(folder)/\(filename)"
        let boundary = "hermes-" + UUID().uuidString
        let body = try await Self.multipartBody(file: file, destination: destination, filename: filename, boundary: boundary)
        let data = try await transfers.transfer("POST", "/api/files/upload-stream", query: Self.profileQuery(profile), body: body,
                                                contentType: "multipart/form-data; boundary=\(boundary)", timeout: 120)
        let answer = try? JSONValue.parse(data)
        guard let path = answer?["path"]?.string, !path.isEmpty else { throw MemoSendError(reason: "The upload didn’t finish on your gateway.") }
        return (path, folder)
    }

    /// The multipart body, byte-exact to W:ios/App/Shared/HermesTransportShared.swift:281-299 (built off the main
    /// thread; a memo is at most a few MB, the attachment limit 32 MB).
    @concurrent
    static func multipartBody(file: URL, destination: String, filename: String, boundary: String) async throws -> Data {
        let bytes = try Data(contentsOf: file)
        guard bytes.count <= MemoPolicy.defaultLimitBytes else { throw MemoSendError(reason: "The voice memo is too large to upload.") }
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"path\"\r\n\r\n\(destination)\r\n".utf8))
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"overwrite\"\r\n\r\nfalse\r\n".utf8))
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(bytes)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    // MARK: (d) Cleanup

    func cleanup(folder: String, profile: String?) async {
        guard let transfers = client as? any GatewayTransfers else { return }
        let body = try? JSONSerialization.data(withJSONObject: ["path": folder, "recursive": true])
        do {
            _ = try await transfers.transfer("DELETE", "/api/files", query: Self.profileQuery(profile), body: body,
                                             contentType: "application/json", timeout: 30)
        } catch {
            AppLog.swallowed("transfer", "clean up a voice memo's staging folder", error)
        }
    }

    // MARK: (f) Transcribe

    /// One call. `ok == false` or any error → `.failed` with the gateway's reason (the memo still goes).
    func transcribe(_ file: URL, mime: String, profile: String?) async -> (said: MemoText.Said, failure: String?) {
        guard let transfers = client as? any GatewayTransfers else { return (.failed, "This gateway can’t transcribe.") }
        do {
            let (body, length) = try await Self.transcribeBody(file: file, mime: Self.mime(for: file, fallback: mime))
            // Stop while the body was encoded: the paid call never goes out.
            if Task.isCancelled { return (.failed, nil) }
            let timeout = min(600, max(180, Double(length) * 0.0001))
            let data = try await transfers.transfer("POST", "/api/audio/transcribe", query: Self.profileQuery(profile), body: body,
                                                    contentType: "application/json", timeout: timeout)
            let answer = try JSONValue.parse(data)
            if answer["ok"]?.bool == false {
                return (.failed, answer["detail"]?.string ?? answer["error"]?.string ?? "The gateway could not transcribe the memo.")
            }
            let words = (answer["transcript"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return (words.isEmpty ? .empty : .text(words), nil)
        } catch {
            AppLog.note("voice", "memo transcribe failed")
            return (.failed, Self.words(error, doing: "transcribe the voice memo"))
        }
    }

    /// The mime as the web reads it (`UTType(filenameExtension:)?.preferredMIMEType`), else `audio/mp4`. The kinds
    /// Hermes names in its own table come first: UTType says `audio/vnd.wave` for a WAV, which Hermes would save as
    /// `.webm` before transcribing (hermes_cli/web_routers/audio.py `_AUDIO_MIME_EXTENSIONS`).
    static func mime(for file: URL, fallback: String) -> String {
        switch file.pathExtension.lowercased() {
        case "m4a": return "audio/x-m4a"
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        default: return UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? (fallback.isEmpty ? "audio/mp4" : fallback)
        }
    }

    /// `{"data_url":"data:<mime>;base64,…","mime_type":"<mime>"}`, encoded off the main thread.
    @concurrent
    static func transcribeBody(file: URL, mime: String) async throws -> (Data, Int) {
        let bytes = try Data(contentsOf: file)
        let dataURL = "data:\(mime);base64," + bytes.base64EncodedString()
        let body = try JSONSerialization.data(withJSONObject: ["data_url": dataURL, "mime_type": mime])
        return (body, dataURL.utf8.count)
    }

    // MARK: Words

    /// A failure in words the owner can read (spec §1 "Readable errors").
    static func words(_ error: any Error, doing what: String) -> String {
        if let memo = error as? MemoSendError { return memo.reason }
        if let http = error as? HTTPError {
            let detail = http.body.flatMap { try? JSONValue.parse(Data($0.utf8)) }.flatMap { $0["detail"]?.string ?? $0["error"]?.string }
            switch http.status {
            case 403: return "Couldn’t \(what): your gateway’s files folder isn’t writable\(detail.map { " (\($0))" } ?? "")."
            case 413: return "Couldn’t \(what): it’s too large for your gateway."
            default:
                if let detail { return "Couldn’t \(what): \(detail)" }
                return "Couldn’t \(what). \(http.plainWords)"
            }
        }
        if let rpc = error as? RPCError { return "Couldn’t \(what): \(rpc.message)" }
        if let localized = error as? LocalizedError, let text = localized.errorDescription { return "Couldn’t \(what): \(text)" }
        return "Couldn’t \(what). Try again."
    }
}
