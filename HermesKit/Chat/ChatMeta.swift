// Side data for a ChatMessage that the shared contract (`ChatMessage`, `ToolCall`) has no field for yet
// (spec 03 §6.1): backend row span for paging, lifted attachment refs, notice flag, and per-tool-call details for the
// step sheet. Kept next to the messages by `LiveChatSession` and in the transcript cache.

import Foundation

/// What a step sheet needs for one tool call (spec 03 §8.8). Bounded: never holds a full tool output.
nonisolated struct ToolDetail: Hashable, Sendable {
    var command: String?          // terminal / execute_code
    var input: String?            // args JSON (≤4096 chars)
    var stdout: String?           // ≤8192 chars
    var stderr: String?
    var detail: String?           // non-stdout results, pretty JSON or text (≤8192 chars)
    var errorText: String?
    var exitCode: Int?
    var inlineDiff: String?       // file edits (≤20,000 chars)
    var payloadRef: JSONValue?    // display_payload_ref {schema,row_id,profile,session_id,bytes} → full output on tap (§2.4)
    var failed = false
    /// A transcript-cache copy: output fields are short heads (`slimmedForCache`). The fresh page that replaces the
    /// cached paint on open brings the full detail; until then the step sheet shows the heads.
    var isCacheCopy = false
    /// [attachments] An `image_generate` call's image (docs/spec/1x-attachments.md §7.7); kept in the cache copy.
    var generatedImage: GeneratedImageInfo? = nil
    /// [screen] A computer_use / browser tool's screenshot (docs/spec/3x-screen.md §5.3): a gateway path, or an inline
    /// `data:` picture that lives in memory only (never in the cache copy).
    var screenshot: ToolScreenshot? = nil
}

nonisolated extension ToolDetail {
    /// Byte caps for the cached copy (spec 03 §7.2.1: the cache keeps a bounded projection, never full outputs).
    static let cacheHeadBytes = 1024
    static let cacheDiffBytes = 8192

    /// The copy the transcript cache keeps: command/input/stdout/detail/error heads of ≤1 KB (UTF-8 bytes), stderr
    /// ≤512 B, exit code, failure flag and the payload ref. The inline diff survives (≤8 KB) only when `keepDiff`
    /// (a file edit in the newest turn).
    func slimmedForCache(keepDiff: Bool) -> ToolDetail {
        var d = ToolDetail()
        let head = ToolDetail.cacheHeadBytes
        d.command = command.map { ChatText.clip($0, max: head) }
        d.input = input.map { ChatText.clip($0, max: head) }
        d.stdout = stdout.map { ChatText.clip($0, max: head) }
        d.stderr = stderr.map { ChatText.clip($0, max: head / 2) }
        d.detail = detail.map { ChatText.clip($0, max: head) }
        d.errorText = errorText.map { ChatText.clip($0, max: head) }
        d.exitCode = exitCode
        d.inlineDiff = keepDiff ? inlineDiff.map { ChatText.clip($0, max: ToolDetail.cacheDiffBytes) } : nil
        d.payloadRef = payloadRef
        d.failed = failed
        d.isCacheCopy = true
        d.generatedImage = generatedImage      // [attachments] small; keeps the card's frame exact on a cached paint
        d.screenshot = screenshot.flatMap { $0.isInline ? nil : $0 }     // [screen] the path form only
        return d
    }
}

nonisolated struct MessageMeta: Hashable, Sendable {
    /// Backend rows folded into this message (paging offsets count rows, spec 03 §5.1). 0 for synthetic rows.
    var serverRowSpan: Int = 1
    /// `@image:…`, `@file:…` refs lifted out of user text (spec 03 §6.3, §6.6).
    var attachmentRefs: [String] = []
    /// Machine timeline notice (model changed, background work finished, failed turn) — centered, no bubble.
    var systemNotice = false
    /// Assistant reached a final text row (false while tool rounds trail).
    var durableComplete: Bool?
    /// Body of a process / delegation completion (behind a disclosure).
    var asyncResult: String?
    /// Lowest backend row id this message covers (the paging join).
    var firstRowId: Int?
    /// Highest backend row id this message covers: a turn folded into one reply keeps its first text row as `rowId`,
    /// while the live turn names its last (`final_assistant_row_id`).
    var lastRowId: Int?
    /// Tool details by `ToolCall.id`.
    var tools: [String: ToolDetail] = [:]
    /// [attachments] Photos and files the message shows (docs/spec/1x-attachments.md §7.2).
    var attachments: [MessageAttachment] = []

    var isDefault: Bool { self == MessageMeta() }
}

nonisolated extension ChatMessage {
    /// Same content ignoring `revision` (used to keep row identity stable across refreshes).
    func sameContent(as other: ChatMessage) -> Bool {
        id == other.id && role == other.role && parts == other.parts && timestamp == other.timestamp && rowId == other.rowId
            && isStreaming == other.isStreaming && isPending == other.isPending && interrupted == other.interrupted
            && error == other.error && reactions == other.reactions && reactionRow == other.reactionRow
    }

    /// All prose text joined (no reasoning).
    var plainText: String {
        parts.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
    }

    var hasVisibleContent: Bool {
        parts.contains { part in
            switch part {
            case .text(let t), .reasoning(let t): return !ChatText.trimmed(t).isEmpty
            case .tool: return true
            }
        }
    }

    var isLocal: Bool { id.hasPrefix("local-") }
}
