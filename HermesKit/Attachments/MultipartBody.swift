// The upload-stream body, built on disk (docs/spec/1x-attachments.md §3.3), byte for byte as the web's native layer
// (R:ios/App/Shared/HermesTransportShared.swift:279-306): fields `path`, `overwrite=false`, `file`, the file streamed
// in 64 KiB reads with a byte ceiling. Never in memory. Pure; call it off the main thread.

import Foundation

nonisolated enum MultipartBody {
    struct Built: Sendable {
        var url: URL
        var boundary: String
        var contentType: String { "multipart/form-data; boundary=\(boundary)" }
        var length: Int64
    }

    enum Failure: Error, Equatable {
        /// The name holds CR, LF, `"` or `\`, or the destination a line break (R:src/bridge/upload.ts:4): no body is built.
        case unsafeName
        case tooLarge
        case unreadable
    }

    static func boundary() -> String { "hermes-" + UUID().uuidString }

    /// The header bytes before the file.
    static func head(destination: String, filename: String, boundary: String) -> Data {
        Data(("--\(boundary)\r\nContent-Disposition: form-data; name=\"path\"\r\n\r\n\(destination)\r\n"
              + "--\(boundary)\r\nContent-Disposition: form-data; name=\"overwrite\"\r\n\r\nfalse\r\n"
              + "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n"
              + "Content-Type: application/octet-stream\r\n\r\n").utf8)
    }

    static func tail(boundary: String) -> Data { Data("\r\n--\(boundary)--\r\n".utf8) }

    /// Builds the body for `source` (sent as `filename`, to `destination` on the gateway) in `directory`. Stops with
    /// `.tooLarge` past `limit` bytes of file and leaves no body file behind on any failure.
    static func build(source: URL, destination: String, filename: String, boundary: String, in directory: URL,
                      limit: Int64 = AttachmentStaging.maxItemBytes) throws -> Built {
        // The filename sits in a quoted header, so quotes and backslashes break it. The destination is a field's value
        // in the body: a Windows gateway's folder (C:\Users\…) has backslashes and is fine; only a line break is not.
        // Scalars, not Characters: "\r\n" is one Character, so `contains("\r")` misses it.
        if filename.unicodeScalars.contains(where: { "\r\n\"\\".unicodeScalars.contains($0) }) { throw Failure.unsafeName }
        if destination.unicodeScalars.contains(where: { "\r\n".unicodeScalars.contains($0) }) { throw Failure.unsafeName }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appending(path: "upload-" + UUID().uuidString + ".multipart")
        guard FileManager.default.createFile(atPath: output.path, contents: nil,
                                             attributes: [.protectionKey: FileProtectionType.completeUnlessOpen]) else {
            throw Failure.unreadable
        }
        do {
            let out = try FileHandle(forWritingTo: output)
            defer { try? out.close() }
            var length: Int64 = 0
            let head = head(destination: destination, filename: filename, boundary: boundary)
            try out.write(contentsOf: head)
            length += Int64(head.count)
            guard let input = try? FileHandle(forReadingFrom: source) else { throw Failure.unreadable }
            defer { try? input.close() }
            var count: Int64 = 0
            while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                count += Int64(chunk.count)
                guard count <= limit else { throw Failure.tooLarge }
                try out.write(contentsOf: chunk)
            }
            length += count
            let tail = tail(boundary: boundary)
            try out.write(contentsOf: tail)
            length += Int64(tail.count)
            return Built(url: output, boundary: boundary, length: length)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }
}
