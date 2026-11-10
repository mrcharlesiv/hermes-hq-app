// [share] docs/spec/3x-share.md §6.3: the upload body, byte for byte the app's own, built on disk.

import Foundation
import Testing
@testable import HermesHQNative

@Suite struct ShareMultipartTests {
    @Test func bytesEqualTheAppsBody() throws {
        let folder = ShareTemp.folder("multipart")
        var payload = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })      // more than three 64 KiB reads
        payload.append(Data("\r\n--hermes-FAKE--\r\n".utf8))                             // boundary-looking bytes inside the file
        let cases: [(name: String, data: Data)] = [("note.txt", Data("hello".utf8)), ("big name ü.bin", payload), ("one.bin", Data([0]))]
        for (index, item) in cases.enumerated() {
            let source = folder.appendingPathComponent("source-\(index)")
            try item.data.write(to: source)
            let boundary = "hermes-TEST-\(index)"
            let destination = "/fixture/uploads/.dispatch-attachments/ABC-\(index)/" + item.name
            let mine = try ShareMultipart.make(source: source, destination: destination, filename: item.name, boundary: boundary,
                                               in: folder.appendingPathComponent("mine"), limit: 1 << 30)
            let apps = try MultipartBody.build(source: source, destination: destination, filename: item.name, boundary: boundary,
                                               in: folder.appendingPathComponent("apps"))
            let bytes = try Data(contentsOf: mine)
            #expect(bytes == (try Data(contentsOf: apps.url)), "\(item.name)")
            #expect(Int64(bytes.count) == apps.length)
            #expect(bytes.suffix(ShareMultipart.tail(boundary: boundary).count) == ShareMultipart.tail(boundary: boundary))
            #expect(ShareMultipart.tail(boundary: boundary) == MultipartBody.tail(boundary: boundary))
            #expect(mine.lastPathComponent.hasPrefix("upload-") && mine.pathExtension == "multipart")
            // The three fields the gateway reads, in order.
            let head = String(decoding: bytes.prefix(400), as: UTF8.self)
            let path = try #require(head.range(of: "name=\"path\"\r\n\r\n\(destination)\r\n"))
            let overwrite = try #require(head.range(of: "name=\"overwrite\"\r\n\r\nfalse\r\n"))
            let file = try #require(head.range(of: "name=\"file\"; filename=\"\(item.name)\"\r\nContent-Type: application/octet-stream\r\n\r\n"))
            #expect(path.lowerBound < overwrite.lowerBound && overwrite.lowerBound < file.lowerBound)
        }
        #expect(ShareMultipart.boundary().hasPrefix("hermes-") && ShareMultipart.boundary() != ShareMultipart.boundary())
    }

    @Test func theLimitStopsTheBodyAndLeavesNothingBehind() throws {
        let folder = ShareTemp.folder("multipart-limit")
        let source = ShareTemp.file("exact.bin", bytes: 150_000, in: folder)
        let out = folder.appendingPathComponent("out")
        #expect(throws: ShareMultipart.Failure.tooLarge) {
            try ShareMultipart.make(source: source, destination: "/u/exact.bin", filename: "exact.bin", boundary: "b", in: out, limit: 149_999)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
        // Exactly the limit fits.
        let body = try ShareMultipart.make(source: source, destination: "/u/exact.bin", filename: "exact.bin", boundary: "b", in: out, limit: 150_000)
        let length = ShareMultipart.head(destination: "/u/exact.bin", filename: "exact.bin", boundary: "b").count + 150_000 + ShareMultipart.tail(boundary: "b").count
        #expect(ShareItemLoader.size(body) == length)
    }

    @Test func unsafeNamesBuildNoBody() throws {
        let folder = ShareTemp.folder("multipart-names")
        let source = ShareTemp.file("a.txt", bytes: 10, in: folder)
        let out = folder.appendingPathComponent("out")
        for bad in ["a\r\nX-Injected: 1.txt", "a\n.txt", "quote\".txt", "back\\slash.txt"] {
            #expect(throws: ShareMultipart.Failure.unsafeName) {
                try ShareMultipart.make(source: source, destination: "/u/a.txt", filename: bad, boundary: "b", in: out, limit: 100)
            }
            #expect(throws: ShareMultipart.Failure.unsafeName) {
                try ShareMultipart.make(source: source, destination: "/u/" + bad, filename: "a.txt", boundary: "b", in: out, limit: 100)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: out.path))
        // A file that is not there.
        #expect(throws: ShareMultipart.Failure.unreadable) {
            try ShareMultipart.make(source: folder.appendingPathComponent("gone.txt"), destination: "/u/gone.txt", filename: "gone.txt", boundary: "b", in: out, limit: 100)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
        // Every name `safeName` lets through is safe to put in the header.
        for raw in ["a\r\nb.txt", "q\"uote.txt", "back\\slash.txt", "ok name.txt", "../../etc/passwd"] {
            let name = ShareRules.safeName(raw)
            #expect((try? ShareMultipart.make(source: source, destination: "/u/" + name, filename: name, boundary: "b", in: out, limit: 100)) != nil, "\(name)")
        }
    }

    @Test func aCancelledTaskStopsAndLeavesNoBody() async throws {
        let folder = ShareTemp.folder("multipart-cancel")
        let source = ShareTemp.file("big.bin", bytes: 4 * 1024 * 1024, in: folder)
        let out = folder.appendingPathComponent("out")
        let task = Task.detached { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try ShareMultipart.make(source: source, destination: "/u/big.bin", filename: "big.bin", boundary: "b", in: out, limit: 1 << 30)
                return false
            } catch is CancellationError { return true } catch { return false }
        }
        #expect(await task.value)
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
    }
}
