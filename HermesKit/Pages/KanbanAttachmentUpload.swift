// Adding a file to a Kanban task (docs/spec/3x-morepages.md §4): `POST /api/plugins/kanban/tasks/{id}/attachments`,
// multipart/form-data with the one part `file` (the web sends only that; `AG/plugins/kanban/dashboard/plugin_api.py:471-501`).
// The body is built on disk and removed afterwards, success or not. The gateway's limit is 25 MB
// (`KANBAN_ATTACHMENT_MAX_BYTES`, `AG/hermes_cli/kanban_db.py:135`).

import Foundation
import UniformTypeIdentifiers

nonisolated extension MultipartBody {
    /// The header bytes before the file when the file is the only part.
    static func fileOnlyHead(filename: String, contentType: String, boundary: String) -> Data {
        Data(("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n"
              + "Content-Type: \(contentType)\r\n\r\n").utf8)
    }

    /// A body holding only the `file` part, built in `directory`. `.tooLarge` past `limit` bytes of file; no body file is
    /// left behind on any failure. A name with CR, LF, `"` or `\` is refused before a byte is written.
    static func buildFileOnly(source: URL, filename: String, contentType: String, boundary: String, in directory: URL,
                              limit: Int64) throws -> Built {
        for bad in ["\r", "\n", "\"", "\\"] where filename.contains(bad) || contentType.contains(bad) { throw Failure.unsafeName }
        if filename.isEmpty { throw Failure.unsafeName }
        if let size = (try? FileManager.default.attributesOfItem(atPath: source.path))?[.size] as? NSNumber, size.int64Value > limit {
            throw Failure.tooLarge
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appending(path: "upload-" + UUID().uuidString + ".multipart")
        guard FileManager.default.createFile(atPath: output.path, contents: nil,
                                             attributes: [.protectionKey: FileProtectionType.completeUnlessOpen]) else {
            throw Failure.unreadable
        }
        do {
            let out = try FileHandle(forWritingTo: output)
            defer { try? out.close() }
            let head = fileOnlyHead(filename: filename, contentType: contentType, boundary: boundary)
            try out.write(contentsOf: head)
            guard let input = try? FileHandle(forReadingFrom: source) else { throw Failure.unreadable }
            defer { try? input.close() }
            var count: Int64 = 0
            while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                count += Int64(chunk.count)
                guard count <= limit else { throw Failure.tooLarge }
                try out.write(contentsOf: chunk)
            }
            let tail = tail(boundary: boundary)
            try out.write(contentsOf: tail)
            return Built(url: output, boundary: boundary, length: Int64(head.count) + count + Int64(tail.count))
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }
}

nonisolated enum KanbanAttachmentUpload {
    /// The gateway's limit for one attachment.
    static let maxBytes: Int64 = 25 * 1024 * 1024
    static let failureTitle = "Couldn’t Add Attachment"
    /// A row shows a progress bar past this size.
    static let progressFloor: Int64 = 1024 * 1024

    static func contentType(_ filename: String) -> String {
        let ext = (filename as NSString).pathExtension
        return (ext.isEmpty ? nil : UTType(filenameExtension: ext)?.preferredMIMEType) ?? "application/octet-stream"
    }

    static func tooLarge(megabytes: Int) -> String { "This file is larger than \(megabytes) MB, the most a task can hold." }

    /// The name sent: the last path component, with the characters a multipart header can't hold replaced.
    static func sendName(_ name: String) -> String {
        var out = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
        // By scalar: "\r\n" is one Character, and what a string replace does with it differs between Foundations.
        var scalars = String.UnicodeScalarView()
        for scalar in out.unicodeScalars where !CharacterSet.controlCharacters.contains(scalar) {
            scalars.append(scalar == "\"" ? "_" : scalar)
        }
        out = String(scalars)
        out = out.trimmingCharacters(in: .whitespaces)
        while out.hasPrefix(".") { out.removeFirst() }
        return out
    }

    /// Why the attachment was not added, in words. `gone` = the task is no longer on the board.
    static func reason(_ error: Error) -> (text: String, gone: Bool) {
        if let failure = error as? MultipartBody.Failure {
            switch failure {
            case .tooLarge: return (tooLarge(megabytes: Int(maxBytes / (1024 * 1024))), false)
            case .unsafeName: return ("The gateway couldn’t use this file’s name.", false)
            case .unreadable: return ("This file could not be read.", false)
            }
        }
        if let http = error as? HTTPError {
            let detail = PagesREST.detail(http) ?? ""
            switch http.status {
            case 413:
                let said = RX.c(#"(\d+)\s*MB"#, [.caseInsensitive]).exec(detail)?[1].flatMap(Int.init)
                return (tooLarge(megabytes: said ?? Int(maxBytes / (1024 * 1024))), false)
            case 400: return (detail.isEmpty ? "The gateway couldn’t use this file’s name." : detail, false)
            case 404: return ("This task is no longer on the board.", true)
            default: break
            }
        }
        if let failure = error as? GatewayFailure { return (failure.message, false) }
        return (PagesREST.reason(error), false)
    }
}

nonisolated extension KanbanAPI {
    /// Uploads `file` as `filename` to the task. The multipart body is built in `scratch` and always removed.
    @concurrent @discardableResult
    func addAttachment(_ id: String, file: URL, filename: String, board: String, scratch: URL = FileManager.default.temporaryDirectory,
                       limit: Int64 = KanbanAttachmentUpload.maxBytes,
                       progress: (@Sendable (_ sent: Int64, _ total: Int64) -> Void)? = nil) async throws -> KanbanAttachment? {
        guard let transfers = client as? any GatewayFileTransfers else { throw PagesMessageError("This connection can’t send files.") }
        let ext = (filename as NSString).pathExtension
        let start = ContinuousClock.now
        do {
            let built = try MultipartBody.buildFileOnly(source: file, filename: filename, contentType: KanbanAttachmentUpload.contentType(filename),
                                                        boundary: MultipartBody.boundary(), in: scratch, limit: limit)
            defer { try? FileManager.default.removeItem(at: built.url) }
            var query: [URLQueryItem] = []
            if !board.isEmpty { query.append(URLQueryItem(name: "board", value: board)) }
            let answer = try await transfers.upload(Self.base + "/tasks/" + PagesREST.segment(id) + "/attachments", query: query,
                                                    contentType: built.contentType, bodyFile: built.url, timeout: 300, priority: 0.5,
                                                    progress: progress)
            guard let item = (try? JSONValue.parseFast(answer))?["attachment"], let aid = item["id"]?.pgString, !aid.isEmpty else {
                AppLog.note("config", "kanban attachment \(AppLog.tag(id)) (.\(ext), \(built.length) bytes): no attachment id in answer")
                return nil
            }
            AppLog.trace("config", "kanban attachment \(AppLog.tag(id)) (.\(ext), \(built.length) bytes) uploaded in \(AppLog.ms(since: start)) ms")
            return KanbanAttachment(id: aid, filename: item["filename"]?.string ?? filename, size: item["size"]?.int)
        } catch {
            let (text, _) = KanbanAttachmentUpload.reason(error)
            AppLog.note("config", "kanban attachment \(AppLog.tag(id)) (.\(ext)) failed after \(AppLog.ms(since: start)) ms: \(text)")
            throw error
        }
    }
}
