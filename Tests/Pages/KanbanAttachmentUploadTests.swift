// 3x-morepages §4 (U3): the multipart body of a task attachment, byte for byte; the refusals before a byte is sent;
// the words for 413 / 400 / 404; the body file is always removed.

import Foundation
import Testing
@testable import HermesHQNative

private func scratch() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "kanban-upload-tests-" + UUID().uuidString)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func file(_ dir: URL, _ name: String, _ data: Data) -> URL {
    let url = dir.appending(path: name)
    try? data.write(to: url)
    return url
}

private func leftovers(_ dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".multipart") }
}

struct KanbanAttachmentUploadTests {
    @Test func theBodyIsTheFilePartAlone() throws {
        let dir = scratch()
        let source = file(dir, "brief.pdf", Data("%PDF-1.4 hello".utf8))
        let built = try MultipartBody.buildFileOnly(source: source, filename: "brief.pdf", contentType: "application/pdf",
                                                    boundary: "hermes-TEST", in: dir, limit: 1024)
        let golden = "--hermes-TEST\r\nContent-Disposition: form-data; name=\"file\"; filename=\"brief.pdf\"\r\n"
            + "Content-Type: application/pdf\r\n\r\n%PDF-1.4 hello\r\n--hermes-TEST--\r\n"
        let body = try Data(contentsOf: built.url)
        #expect(body == Data(golden.utf8))
        #expect(built.length == Int64(body.count))
        #expect(built.contentType == "multipart/form-data; boundary=hermes-TEST")
    }

    @Test func unsafeNamesAreRefusedBeforeAnyByte() {
        let dir = scratch()
        let source = file(dir, "a.txt", Data("x".utf8))
        for name in ["a\"b.txt", "a\\b.txt", "a\rb.txt", "a\nb.txt", ""] {
            #expect(throws: MultipartBody.Failure.unsafeName) {
                try MultipartBody.buildFileOnly(source: source, filename: name, contentType: "text/plain", boundary: "b", in: dir, limit: 10)
            }
        }
        #expect(leftovers(dir).isEmpty)
    }

    @Test func aFilePastTheLimitIsRefusedAndLeavesNothing() {
        let dir = scratch()
        let source = file(dir, "big.bin", Data(count: 2049))
        #expect(throws: MultipartBody.Failure.tooLarge) {
            try MultipartBody.buildFileOnly(source: source, filename: "big.bin", contentType: "application/octet-stream", boundary: "b",
                                            in: dir, limit: 2048)
        }
        #expect(leftovers(dir).isEmpty)
        #expect(throws: MultipartBody.Failure.unreadable) {
            try MultipartBody.buildFileOnly(source: dir.appending(path: "gone"), filename: "gone", contentType: "text/plain", boundary: "b",
                                            in: dir, limit: 10)
        }
        #expect(leftovers(dir).isEmpty)
    }

    @Test func theLimitIsTheGatewaysTwentyFiveMegabytes() {
        #expect(KanbanAttachmentUpload.maxBytes == 25 * 1024 * 1024)
        #expect(KanbanAttachmentUpload.reason(MultipartBody.Failure.tooLarge).text == "This file is larger than 25 MB, the most a task can hold.")
    }

    @Test func theWordsForEachRefusal() {
        func said(_ status: Int, _ body: String?) -> (text: String, gone: Bool) { KanbanAttachmentUpload.reason(HTTPError(status: status, body: body)) }
        #expect(said(413, #"{"detail":"attachment exceeds 10 MB limit"}"#).text == "This file is larger than 10 MB, the most a task can hold.")
        #expect(said(413, nil).text == "This file is larger than 25 MB, the most a task can hold.")
        #expect(said(400, #"{"detail":"invalid attachment filename"}"#).text == "invalid attachment filename")
        #expect(said(400, nil).text == "The gateway couldn’t use this file’s name.")
        #expect(said(404, #"{"detail":"task t_1 not found"}"#).text == "This task is no longer on the board.")
        #expect(said(404, nil).gone)
        #expect(!said(413, nil).gone)
        #expect(KanbanAttachmentUpload.reason(MultipartBody.Failure.unsafeName).text == "The gateway couldn’t use this file’s name.")
        #expect(KanbanAttachmentUpload.reason(GatewayFailure.timeout).text == GatewayFailure.timeout.message)
        #expect(!said(500, #"{"detail":"failed to store attachment: disk full"}"#).text.isEmpty)
    }

    @Test func theNameSentIsTheLastComponentWithoutHeaderBreakers() {
        #expect(KanbanAttachmentUpload.sendName("brief.pdf") == "brief.pdf")
        #expect(KanbanAttachmentUpload.sendName("/a/b/brief.pdf") == "brief.pdf")
        #expect(KanbanAttachmentUpload.sendName("C:\\docs\\brief.pdf") == "brief.pdf")
        #expect(KanbanAttachmentUpload.sendName("a\"b\r\n.txt") == "a_b.txt")
        #expect(KanbanAttachmentUpload.sendName("..hidden") == "hidden")
        #expect(KanbanAttachmentUpload.sendName("...") == "")
        #expect(KanbanAttachmentUpload.contentType("a.pdf") == "application/pdf")
        #expect(KanbanAttachmentUpload.contentType("noext") == "application/octet-stream")
    }

    @Test func theUploadGoesToTheTasksAttachmentsWithItsBoardAndTheBodyIsRemoved() async throws {
        let dir = scratch()
        let source = file(dir, "brief.pdf", Data("hello".utf8))
        let client = FakeTransferClient()
        client.onUpload { _, _ in Data(#"{"attachment":{"id":7,"filename":"brief (1).pdf","size":5}}"#.utf8) }
        let api = KanbanAPI(client: client)
        let added = try await api.addAttachment("t_8f/2c", file: source, filename: "brief.pdf", board: "website", scratch: dir)
        #expect(added == KanbanAttachment(id: "7", filename: "brief (1).pdf", size: 5))
        let upload = try #require(client.uploads.first)
        #expect(client.uploads.count == 1)
        #expect(upload.path == "/api/plugins/kanban/tasks/t_8f%2F2c/attachments")
        #expect(upload.query == [URLQueryItem(name: "board", value: "website")])
        #expect(upload.contentType.hasPrefix("multipart/form-data; boundary=hermes-"))
        let text = String(decoding: upload.body, as: UTF8.self)
        #expect(text.components(separatedBy: "Content-Disposition").count == 2, "one part only")
        #expect(text.contains("name=\"file\"; filename=\"brief.pdf\"\r\nContent-Type: application/pdf\r\n\r\nhello\r\n--hermes-"))
        #expect(!text.contains("uploaded_by"))
        #expect(leftovers(dir).isEmpty)
        // The current board sends no `board`.
        _ = try await api.addAttachment("t1", file: source, filename: "brief.pdf", board: "", scratch: dir)
        #expect(client.uploads.last?.query == [])
    }

    @Test func aRefusedUploadRemovesTheBodyToo() async {
        let dir = scratch()
        let source = file(dir, "brief.pdf", Data("hello".utf8))
        let client = FakeTransferClient()
        client.onUpload { _, _ in throw HTTPError(status: 413, body: #"{"detail":"attachment exceeds 25 MB limit"}"#) }
        await #expect(throws: HTTPError.self) {
            try await KanbanAPI(client: client).addAttachment("t1", file: source, filename: "brief.pdf", board: "", scratch: dir)
        }
        #expect(leftovers(dir).isEmpty)
        // Too large for the limit: nothing is sent.
        await #expect(throws: MultipartBody.Failure.tooLarge) {
            try await KanbanAPI(client: client).addAttachment("t1", file: source, filename: "brief.pdf", board: "", scratch: dir, limit: 2)
        }
        #expect(client.uploads.count == 1)
        #expect(leftovers(dir).isEmpty)
    }
}
