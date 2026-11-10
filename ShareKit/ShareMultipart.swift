// [share] The upload-stream body, built on disk and never in memory (docs/spec/3x-share.md §6.3): fields `path`,
// `overwrite=false`, `file`, the file streamed in 64 KiB reads with a byte ceiling. Byte for byte what HermesKit's
// `MultipartBody.build` writes (parity: Tests/Share/ShareMultipartTests.swift).

import Foundation

nonisolated enum ShareMultipart {
    enum Failure: Error, Equatable {
        /// The name or the destination holds a control character (CR and LF among them), `"` or `\`: no body is built.
        case unsafeName
        case tooLarge
        case unreadable
    }

    static func boundary() -> String { "hermes-" + UUID().uuidString }

    static func head(destination: String, filename: String, boundary: String) -> Data {
        Data(("--\(boundary)\r\nContent-Disposition: form-data; name=\"path\"\r\n\r\n\(destination)\r\n"
              + "--\(boundary)\r\nContent-Disposition: form-data; name=\"overwrite\"\r\n\r\nfalse\r\n"
              + "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n"
              + "Content-Type: application/octet-stream\r\n\r\n").utf8)
    }

    static func tail(boundary: String) -> Data { Data("\r\n--\(boundary)--\r\n".utf8) }

    /// A control character, a double quote or a backslash would end the header line or the quoted name. Asked of the
    /// scalars: to Swift a CR followed by an LF is one character, so a search for either alone never finds a CRLF.
    static func unsafe(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f || $0 == "\"" || $0 == "\\" }
    }

    /// Builds the body for `source` (sent as `filename`, to `destination` on the gateway) in `directory`. Stops with
    /// `.tooLarge` past `limit` bytes of file, with `CancellationError` when the task is cancelled, and leaves no body
    /// file behind on any failure.
    static func make(source: URL, destination: String, filename: String, boundary: String, in directory: URL, limit: Int) throws -> URL {
        guard !unsafe(filename), !unsafe(destination) else { throw Failure.unsafeName }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("upload-" + UUID().uuidString + ".multipart")
        guard FileManager.default.createFile(atPath: output.path, contents: nil,
                                             attributes: [.protectionKey: FileProtectionType.completeUnlessOpen]) else {
            throw Failure.unreadable
        }
        do {
            let out = try FileHandle(forWritingTo: output)
            defer { try? out.close() }
            try out.write(contentsOf: head(destination: destination, filename: filename, boundary: boundary))
            guard let input = try? FileHandle(forReadingFrom: source) else { throw Failure.unreadable }
            defer { try? input.close() }
            var count = 0
            while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                count += chunk.count
                guard count <= limit else { throw Failure.tooLarge }
                try out.write(contentsOf: chunk)
            }
            try Task.checkCancellation()
            try out.write(contentsOf: tail(boundary: boundary))
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }
}
