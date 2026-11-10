// Contract additions for voice memos (docs/spec/1x-voice.md §2.2). Proposed for integration: `HermesKit/Contracts.swift`
// stays untouched; these live here until the integrator folds them in.

import Foundation

/// A finished recording on this phone. `path` is absolute, under Application Support/memos/<account key>/…, or (once
/// the gateway accepted it) the gateway's own path, which the playback cache maps back to a local file.
nonisolated struct MemoFile: Codable, Hashable, Sendable {
    var path: String
    /// Two decimals.
    var seconds: Double
    /// 48 values in 0…1, three decimals (`MemoPolicy.peaks`).
    var peaks: [Double]
    /// "audio/x-m4a" (recorder) or "audio/wav" (the simulator's fixture recorder).
    var mime: String
    /// [live words] What this phone heard as the memo was recorded (docs/spec/3x-live-words.md): sent as its transcript,
    /// so the gateway never transcribes it. Nil: nothing heard it (the gateway transcribes as before).
    var words: String? = nil
}

/// A chat that can send voice memos and keep one memo draft (adopted by `LiveChatSession`).
protocol ChatVoiceMemos: AnyObject {
    /// Sends `memo` (with `text` typed beside it, possibly "") through the upload pipeline (spec §4.2); queues while a
    /// reply runs (V13).
    func sendMemo(_ memo: MemoFile, text: String)
    /// The memo waiting in this chat's composer (a draft chip), persisted per chat (spec §3.6).
    var memoDraft: MemoFile? { get }
    func setMemoDraft(_ memo: MemoFile?)
    /// The chat's cache scope ("<account id>|<profile>|<stored session id>"): the draft store's key.
    var memoScope: String { get }
}

/// REST with an explicit body type and a longer ceiling than `GatewayClient.rest` (multipart uploads, transcription:
/// spec §2.2 R5). `LiveGatewayClient` adopts it; test fakes can too.
nonisolated protocol GatewayTransfers: GatewayClient {
    /// Like `rest`, with `contentType` for the body and `timeout` in seconds (clamped to 1…600).
    func transfer(_ method: String, _ path: String, query: [URLQueryItem], body: Data?, contentType: String,
                  timeout: TimeInterval) async throws -> Data
}
