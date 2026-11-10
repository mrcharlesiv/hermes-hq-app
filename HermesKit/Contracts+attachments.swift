// Contract additions for photos and files (docs/spec/1x-attachments.md §13.1). Proposed for integration:
// `HermesKit/Contracts.swift` stays untouched; these live here until the integrator folds them in.
//
// - `GatewayFileTransfers`: file-streamed uploads and downloads with the account's auth (a separate protocol, not new
//   `GatewayClient` requirements, so other streams' fakes keep compiling; `LiveGatewayClient` adopts it).
// - `ChatAttachmentSending`: a chat that sends attachments and knows each message's attachments (`LiveChatSession`).
// - `ChatMediaSnapshot`: the per-message media the row builder reads with the messages (`ChatRowBuilder.Input.media`).

import Foundation

/// Uploads and downloads that never hold the body in memory (spec §3.3, §8.2). Implemented by `LiveGatewayClient`
/// through `GatewayAuth` (same decoration and single-flight refresh as `rest`) and `HTTPTransport`'s bulk pool.
nonisolated protocol GatewayFileTransfers: GatewayClient {
    /// POSTs `bodyFile` (a multipart body built on disk) with this account's auth; a 401 refreshes once and re-sends
    /// the same file. Returns the answer body (≤ 1 MiB). Throws `HTTPError` for a non-2xx answer (body ≤ 64 KiB),
    /// `GatewayFailure` for transport and session failures.
    func upload(_ path: String, query: [URLQueryItem], contentType: String, bodyFile: URL, timeout: TimeInterval,
                priority: Float, progress: (@Sendable (_ sent: Int64, _ total: Int64) -> Void)?) async throws -> Data
    /// GETs into `file` (never into memory). Past `ceiling` bytes → `GatewayFailure.responseTooLarge` and the partial
    /// file is removed. Throws `HTTPError` for a non-2xx answer.
    func download(_ path: String, query: [URLQueryItem], to file: URL, ceiling: Int64, priority: Float,
                  progress: (@Sendable (_ received: Int64, _ expected: Int64) -> Void)?) async throws -> HTTPURLResponse
}

/// A chat that can send photos and files (spec §6.4). The live session adopts it; the screen falls back to text-only
/// `send(_:)` without it.
protocol ChatAttachmentSending: AnyObject {
    /// Sends `text` with `attachments` (tray order). Queues while a reply runs, as text sends do.
    func send(_ text: String, attachments: [DraftAttachment])
    /// The attachments shown in a message (your sends, history refs, inline parts), in order.
    func attachments(for messageId: String) -> [MessageAttachment]
    /// Everything the row builder needs about media, snapshotted with the messages.
    var mediaSnapshot: ChatMediaSnapshot { get }
    /// A history image's real pixel size, learnt by loading it (spec §8.3): written back so the next layout is exact.
    func noteMediaSize(messageId: String, index: Int, width: Int, height: Int)
    /// A reply picture's pixel size, learnt by loading it (a reply names a picture without one): kept for that message,
    /// so its next layout gives the picture (or a stack of them) the picture's own shape.
    func noteReplyMediaSize(messageId: String, key: String, width: Int, height: Int)
    /// A reply's picture the gateway can't serve (404, 403): its path and the words its row shows instead (spec §7.5).
    func noteMediaUnavailable(messageId: String, path: String, reason: String)
    /// "<account id>|<profile>|<stored session id>": the drafts store's key for this chat.
    var draftScope: String { get }
    /// Account id and profile (media keys, downloads).
    var mediaContext: MediaContext { get }
}

/// Who owns a media request: the account (its client and caches), the bot's profile and the stored session.
nonisolated struct MediaContext: Hashable, Sendable {
    var accountId: String
    var profile: String
    var storedSessionId: String? = nil
    #if DEBUG
    /// The demo chats' account (`-HQDemoPage`): its files are read from this Mac's disk.
    static let demoAccount = "demo-local-files"
    #endif
}

/// Per-message media for the row builder (`ChatRowBuilder.Input.media`): a value snapshot taken with the messages.
nonisolated struct ChatMediaSnapshot: Sendable {
    /// By message id.
    var attachments: [String: [MessageAttachment]] = [:]
    /// `image_generate` results by message id, then tool call id.
    var generated: [String: [String: GeneratedImageInfo]] = [:]
    /// The chat's media context (cache keys for gateway paths).
    var context: MediaContext?
    /// Reply pictures the gateway refused, by gateway path → the words their file row shows.
    var unavailable: [String: String] = [:]
    /// Reply pictures' pixel sizes learnt by loading them: message id → `MessageAttachment.sizeKey` → size.
    var replySizes: [String: [String: MediaPixelSize]] = [:]

    static let empty = ChatMediaSnapshot()
}

nonisolated struct MediaPixelSize: Hashable, Sendable {
    var width: Int
    var height: Int
}
