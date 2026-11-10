// Managed-files staging on the gateway (docs/spec/1x-attachments.md §3.2, §3.3, §3.6): read the upload root once per
// profile, send one file as multipart (built on disk) to `<root>/.dispatch-attachments/<UUID>/<name>`, and delete a
// staging folder when its copy is no longer needed. The one implementation both attachments and voice memos use
// (§13.4 seam: `stage(file:name:profile:progress:)`, `release(folder:profile:)`).

import Foundation

/// A file on the gateway: its stored path and the staging folder it sits in.
nonisolated struct StagedFile: Hashable, Sendable, Codable {
    var path: String
    var folder: String
}

/// Why a stage failed, in the words the tray and the refusal card show (spec §3.3 table, §6.3).
nonisolated struct AttachmentUploadError: Error, Equatable, Sendable, LocalizedError {
    enum Kind: Equatable, Sendable {
        /// No connection (offline, Tailscale off): the upload waits and starts by itself when it is back.
        case waiting
        /// Network, timeout, 5xx: one automatic retry after 2 s, then failed (retryable).
        case retryable
        /// The gateway refused it for good (name, size, no upload folder): not retryable.
        case final
        /// The session ended (a 401 after the refresh): the app's sign-out path takes it from here.
        case sessionEnded
    }
    var kind: Kind
    var reason: String

    var errorDescription: String? { reason }

    static func connection(_ name: String) -> AttachmentUploadError {
        AttachmentUploadError(kind: .retryable, reason: "Couldn’t upload “\(name)”. Check your connection and try again.")
    }
    static func status(_ name: String, _ status: Int) -> AttachmentUploadError {
        AttachmentUploadError(kind: .retryable, reason: "Couldn’t upload “\(name)” (gateway error \(status)).")
    }
    static let noFolder = AttachmentUploadError(kind: .final, reason: "Your gateway has no folder for uploads.")
    static func tooBig(_ name: String) -> AttachmentUploadError {
        AttachmentUploadError(kind: .final, reason: "“\(name)” is too big for your gateway.")
    }
    /// A name with a quote, backslash or line break: the phone stops before sending a byte.
    static let badName = AttachmentUploadError(kind: .final, reason: "This file’s name has characters your gateway can’t take.")
    /// A 400 from the upload: the gateway's own reason (`detail`), which is rarely the name ("Invalid Host header…").
    static func refused(_ name: String, body: String?) -> AttachmentUploadError {
        let detail = body.flatMap { try? JSONValue.parse(Data($0.utf8)) }?["detail"]?.string?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let detail, !detail.isEmpty else {
            return AttachmentUploadError(kind: .final, reason: "Your gateway refused “\(name)” (HTTP 400).")
        }
        return AttachmentUploadError(kind: .final, reason: "Your gateway refused “\(name)”: \(detail)")
    }
    /// A send's wait that Stop interrupted (never shown: the pipeline withdraws the send).
    static let stopped = AttachmentUploadError(kind: .final, reason: "Stopped before sending")
    static func notStored(_ name: String) -> AttachmentUploadError {
        AttachmentUploadError(kind: .final, reason: "Your gateway didn’t store “\(name)”.")
    }
}

actor AttachmentStager {
    /// The staging folder under the gateway's files root (A13; R:ios/App/Shared/HermesTransportShared.swift:264).
    nonisolated static let stagingFolder = ".dispatch-attachments"

    private let client: any GatewayClient
    private let tempDirectory: URL
    private var roots: [String: String] = [:]

    init(client: any GatewayClient, tempDirectory: URL) {
        self.client = client
        self.tempDirectory = tempDirectory
    }

    /// `HermesTransportPolicy.stagedCopyReleased` (R:ios/App/Shared/HermesTransportShared.swift:265-270): a staging
    /// copy can go once the gateway stored its own copy elsewhere (`uploaded` true and the stored path outside it).
    nonisolated static func stagedCopyReleased(uploaded: Bool?, storedPath: String?, folder: String) -> Bool {
        guard uploaded == true, let storedPath, !storedPath.isEmpty else { return false }
        let stored = slashed(storedPath), folder = slashed(folder)
        return !(stored == folder || stored.hasPrefix(folder + "/"))
    }

    /// A gateway path with `/` only: a Windows gateway answers `C:\Users\…`, and the comparisons here split on `/`.
    nonisolated static func slashed(_ path: String) -> String { path.replacingOccurrences(of: "\\", with: "/") }

    nonisolated static func profileQuery(_ profile: String) -> [URLQueryItem] {
        profile.isEmpty ? [] : [URLQueryItem(name: "profile", value: profile)]
    }

    /// The upload root for `profile` (`GET /api/files`, only `path` is read; cached for the app run).
    func root(profile: String) async throws -> String {
        if let known = roots[profile] { return known }
        let data: Data
        do {
            data = try await client.rest("GET", "/api/files", query: Self.profileQuery(profile), body: nil)
        } catch {
            throw Self.map(error, name: "", reading: true)
        }
        guard let path = (try? JSONValue.parse(data))?["path"]?.string, !path.isEmpty else { throw AttachmentUploadError.noFolder }
        roots[profile] = path
        return path
    }

    func forgetRoots() { roots = [:] }

    /// Uploads `file` as `name` (already a safe name) and returns where the gateway stored it.
    func stage(file: URL, name: String, profile: String, priority: Float = 0.5,
               progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> StagedFile {
        guard let transfers = client as? GatewayFileTransfers else {
            throw AttachmentUploadError(kind: .final, reason: "This gateway connection can’t upload files.")
        }
        var folderId = UUID().uuidString
        var rootRetried = false
        var conflictRetried = false
        while true {
            try Task.checkCancellation()
            let root = try await root(profile: profile)
            let folder = root + "/" + Self.stagingFolder + "/" + folderId
            let destination = folder + "/" + name
            let boundary = MultipartBody.boundary()
            let directory = tempDirectory
            let built: MultipartBody.Built
            do {
                built = try await Task.detached(priority: .userInitiated) {
                    try MultipartBody.build(source: file, destination: destination, filename: name, boundary: boundary, in: directory)
                }.value
            } catch MultipartBody.Failure.unsafeName {
                throw AttachmentUploadError.badName
            } catch MultipartBody.Failure.tooLarge {
                throw AttachmentUploadError(kind: .final, reason: AttachmentPrepareError.tooLarge(name: name).errorDescription ?? "")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw AttachmentUploadError(kind: .final, reason: "Couldn’t read “\(name)” on this \(DeviceWord.name).")
            }
            defer { try? FileManager.default.removeItem(at: built.url) }
            let answer: Data
            do {
                answer = try await transfers.upload("/api/files/upload-stream", query: Self.profileQuery(profile),
                                                    contentType: built.contentType, bodyFile: built.url, timeout: 60,
                                                    priority: priority, progress: progress)
            } catch let error as HTTPError where (error.status == 403 || error.status == 404) && !rootRetried {
                // The cached root went stale (moved, permissions): read it again once.
                rootRetried = true
                roots[profile] = nil
                continue
            } catch let error as HTTPError where error.status == 409 && !conflictRetried {
                conflictRetried = true
                folderId = UUID().uuidString
                continue
            } catch {
                throw Self.map(error, name: name, reading: false)
            }
            guard let path = (try? JSONValue.parse(answer))?["path"]?.string, !path.isEmpty else {
                throw AttachmentUploadError.notStored(name)
            }
            let parent = (Self.slashed(path) as NSString).deletingLastPathComponent
            let stagedFolder = (parent as NSString).lastPathComponent == folderId ? parent : folder
            return StagedFile(path: path, folder: stagedFolder)
        }
    }

    /// Deletes a staging folder, best effort, once (no retry loop; spec §3.6).
    func release(folder: String, profile: String) async {
        guard folder.contains("/" + Self.stagingFolder + "/") else { return }
        let body = try? JSONValue.object(["path": .string(folder), "recursive": true]).encoded()
        _ = try? await client.rest("DELETE", "/api/files", query: Self.profileQuery(profile), body: body)
    }

    // MARK: Errors

    nonisolated static func map(_ error: any Error, name: String, reading: Bool) -> any Error {
        if error is CancellationError { return error }
        if let staged = error as? AttachmentUploadError { return staged }
        if let http = error as? HTTPError {
            // Audit 14-6: reading the upload folder, only "not there" or "not allowed" means no folder. A 502 while the
            // gateway restarts is worth another try, and a 401 is a session that ended, as for the upload itself.
            if reading {
                switch http.status {
                case 400, 403, 404: return AttachmentUploadError.noFolder
                case 401: return AttachmentUploadError(kind: .sessionEnded, reason: "Your session ended. Sign in again to send this.")
                default: return AttachmentUploadError(kind: .retryable, reason: "Couldn’t reach your gateway’s upload folder (gateway error \(http.status)). Try again.")
                }
            }
            switch http.status {
            case 400: return AttachmentUploadError.refused(name, body: http.body)
            case 401: return AttachmentUploadError(kind: .sessionEnded, reason: "Your session ended. Sign in again to send this.")
            case 403, 404: return AttachmentUploadError.noFolder
            case 413: return AttachmentUploadError.tooBig(name)
            case 500...599: return AttachmentUploadError.status(name, http.status)
            default: return AttachmentUploadError.status(name, http.status)
            }
        }
        if let failure = error as? GatewayFailure {
            switch failure {
            case .offline, .tailscaleOff: return AttachmentUploadError(kind: .waiting, reason: "Waiting for connection")
            case .sessionEnded: return AttachmentUploadError(kind: .sessionEnded, reason: "Your session ended. Sign in again to send this.")
            case .responseTooLarge: return reading ? AttachmentUploadError.noFolder : AttachmentUploadError.notStored(name)
            default: return reading ? AttachmentUploadError(kind: .retryable, reason: "Couldn’t reach your gateway. Try again.")
                                    : AttachmentUploadError.connection(name)
            }
        }
        if let url = error as? URLError {
            if url.code == .cancelled { return CancellationError() }
            if url.code == .notConnectedToInternet {
                return AttachmentUploadError(kind: .waiting, reason: "Waiting for connection")
            }
        }
        return reading ? AttachmentUploadError(kind: .retryable, reason: "Couldn’t reach your gateway. Try again.")
                       : AttachmentUploadError.connection(name)
    }
}
