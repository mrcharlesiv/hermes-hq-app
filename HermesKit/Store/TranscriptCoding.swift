// Compact binary encoding for transcript cache entries. Hand-rolled (varints + length-prefixed UTF-8) so a 40-message
// entry decodes in well under a millisecond on the main thread (spec 03 §7.2.1: the read happens inside the push).

import Foundation

nonisolated struct BinaryWriter {
    private(set) var data = Data()

    init(capacity: Int = 4096) { data.reserveCapacity(capacity) }

    mutating func byte(_ v: UInt8) { data.append(v) }
    mutating func bool(_ v: Bool) { data.append(v ? 1 : 0) }

    mutating func varint(_ value: UInt64) {
        var v = value
        while v >= 0x80 { data.append(UInt8(v & 0x7F) | 0x80); v >>= 7 }
        data.append(UInt8(v))
    }

    mutating func int(_ v: Int) { varint(UInt64(bitPattern: Int64((v << 1) ^ (v >> 63)))) }   // zigzag

    mutating func double(_ v: Double) {
        var bits = v.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }

    mutating func string(_ s: String) {
        var copy = s
        copy.withUTF8 { buf in
            varint(UInt64(buf.count))
            data.append(contentsOf: buf)
        }
    }

    mutating func optionalString(_ s: String?) {
        if let s { bool(true); string(s) } else { bool(false) }
    }

    mutating func optionalInt(_ v: Int?) { if let v { bool(true); int(v) } else { bool(false) } }
    mutating func optionalDouble(_ v: Double?) { if let v { bool(true); double(v) } else { bool(false) } }

    mutating func json(_ v: JSONValue?) {
        if let v { bool(true); string(ChatJSON.stringify(v)) } else { bool(false) }
    }
}

nonisolated struct BinaryReader {
    enum Failure: Error { case truncated, malformed }
    private let bytes: [UInt8]
    private var at = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    var isAtEnd: Bool { at >= bytes.count }

    mutating func byte() throws -> UInt8 {
        guard at < bytes.count else { throw Failure.truncated }
        defer { at += 1 }
        return bytes[at]
    }

    mutating func bool() throws -> Bool { try byte() != 0 }

    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let b = try byte()
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { throw Failure.malformed }
        }
    }

    mutating func int() throws -> Int {
        let raw = try varint()
        let v = Int64(bitPattern: raw)
        return Int((v >> 1) ^ -(v & 1))
    }

    mutating func double() throws -> Double {
        guard at + 8 <= bytes.count else { throw Failure.truncated }
        var bits: UInt64 = 0
        for i in 0..<8 { bits |= UInt64(bytes[at + i]) << (8 * UInt64(i)) }
        at += 8
        return Double(bitPattern: bits)
    }

    /// A length or element count: never more than the bytes left (each element takes ≥ 1 byte), so a corrupt file can't
    /// trap on `Int` conversion, overflow `at + count`, or make us reserve a huge array.
    mutating func count() throws -> Int {
        guard let count = Int(exactly: try varint()), count <= bytes.count - at else { throw Failure.truncated }
        return count
    }

    mutating func string() throws -> String {
        let count = try count()
        defer { at += count }
        return bytes.withUnsafeBufferPointer { buf in
            String(decoding: UnsafeBufferPointer(rebasing: buf[at..<(at + count)]), as: UTF8.self)
        }
    }

    mutating func optionalString() throws -> String? { try bool() ? try string() : nil }
    mutating func optionalInt() throws -> Int? { try bool() ? try int() : nil }
    mutating func optionalDouble() throws -> Double? { try bool() ? try double() : nil }
    mutating func json() throws -> JSONValue? { try bool() ? ChatJSON.parse(string: try string()) : nil }
}

/// One cached chat tail (spec 03 §7.2): messages oldest → newest, their side data, when it was saved.
nonisolated struct TranscriptEntry: Sendable, Equatable {
    var messages: [ChatMessage]
    var meta: [String: MessageMeta]
    var savedAt: Date
    var partial = false          // bounded offline copy; only for the offline cold-launch restore
    var stale = false            // a newer tail could not be admitted; this one is older than the chat

    /// "HQT3" (m2 integration): [attachments] message attachments and generated images (docs/spec/1x-attachments.md
    /// §7.2) and [activity] a tool part's card (state bit 0x80 + JSON, docs/spec/1x-activity.md §3.4). Each stream
    /// had bumped to its own "HQT2"; neither shipped. Any older file (HQT1 from builds 1–2, either HQT2) reads as a miss
    /// (a throw the cache turns into a fresh read), never a crash or a misread.
    /// "HQT4" (polish 2026-10-24): message flag bit 2, a message's reactions and its reaction row follow its error. An
    /// HQT3 file never sets the bit and still reads; a build that knows only HQT3 reads an HQT4 file as a miss.
    /// "HQT5" (log study 2026-10-28): a message's meta ends with the highest row it covers. An HQT3/HQT4 file still
    /// reads (no last row); a build that knows only HQT4 reads an HQT5 file as a miss.
    static let magic: [UInt8] = Array("HQT5".utf8)
    static let readableMagics: [[UInt8]] = [Array("HQT3".utf8), Array("HQT4".utf8), Array("HQT5".utf8)]

    func encoded() -> Data {
        var w = BinaryWriter(capacity: 8192)
        for b in TranscriptEntry.magic { w.byte(b) }
        w.double(savedAt.timeIntervalSince1970)
        w.byte((partial ? 1 : 0) | (stale ? 2 : 0))
        w.varint(UInt64(messages.count))
        for m in messages { TranscriptEntry.write(m, meta: meta[m.id], into: &w) }
        return w.data
    }

    static func decode(_ data: Data) throws -> TranscriptEntry {
        var r = BinaryReader(data)
        var head: [UInt8] = []
        for _ in magic { head.append(try r.byte()) }
        guard readableMagics.contains(head) else { throw BinaryReader.Failure.malformed }
        let savedAt = Date(timeIntervalSince1970: try r.double())
        let flags = try r.byte()
        let count = try r.count()
        guard count <= 10_000 else { throw BinaryReader.Failure.malformed }
        var messages: [ChatMessage] = []
        messages.reserveCapacity(count)
        var meta: [String: MessageMeta] = [:]
        for _ in 0..<count {
            let (m, mm) = try read(&r, hasLastRow: head == magic)
            messages.append(m)
            if let mm { meta[m.id] = mm }
        }
        return TranscriptEntry(messages: messages, meta: meta, savedAt: savedAt, partial: flags & 1 != 0, stale: flags & 2 != 0)
    }

    /// [perf] Just the header's savedAt (magic, then the double `encoded` writes first), so a staleness check doesn't
    /// decode the whole tail. nil for a short file or an unreadable magic: those count as missing, as in `decode`.
    static func peekSavedAt(_ head: Data) -> Date? {
        var r = BinaryReader(head)
        var magicBytes: [UInt8] = []
        for _ in magic { guard let b = try? r.byte() else { return nil }; magicBytes.append(b) }
        guard readableMagics.contains(magicBytes), let seconds = try? r.double(), (try? r.byte()) != nil else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func write(_ m: ChatMessage, meta: MessageMeta?, into w: inout BinaryWriter) {
        w.string(m.id)
        w.byte(m.role == .user ? 0 : m.role == .assistant ? 1 : 2)
        w.optionalDouble(m.timestamp?.timeIntervalSince1970)
        w.optionalInt(m.rowId)
        let reacted = !m.reactions.isEmpty || m.reactionRow != nil
        w.byte((m.interrupted ? 1 : 0) | (reacted ? 2 : 0))
        w.optionalString(m.error)
        if reacted {
            w.varint(UInt64(m.reactions.count))
            for r in m.reactions { w.string(r.emoji); w.string(r.author); w.optionalDouble(r.at) }
            w.optionalInt(m.reactionRow)
        }
        w.varint(UInt64(m.parts.count))
        for part in m.parts {
            switch part {
            case .text(let t): w.byte(0); w.string(t)
            case .reasoning(let t): w.byte(1); w.string(t)
            case .tool(let call):
                w.byte(2)
                w.string(call.id); w.string(call.name); w.string(call.title)
                w.optionalString(call.argsText); w.optionalString(call.summary)
                // [activity] bit 0x80: a card's bounded result follows as JSON (docs/spec/1x-activity.md §3.4).
                w.byte((call.state == .running ? 0 : call.state == .done ? 1 : 2) | (call.card != nil ? 0x80 : 0))
                w.optionalDouble(call.durationSeconds)
                if let card = call.card { w.json(card.json) }
            }
        }
        if let meta, !meta.isDefault {
            w.bool(true)
            w.int(meta.serverRowSpan)
            w.varint(UInt64(meta.attachmentRefs.count)); meta.attachmentRefs.forEach { w.string($0) }
            w.bool(meta.systemNotice)
            w.byte(meta.durableComplete == nil ? 0 : meta.durableComplete! ? 1 : 2)
            w.optionalString(meta.asyncResult)
            w.optionalInt(meta.firstRowId)
            w.varint(UInt64(meta.tools.count))
            for key in meta.tools.keys.sorted() {
                let d = meta.tools[key]!
                w.string(key)
                w.optionalString(d.command); w.optionalString(d.input); w.optionalString(d.stdout); w.optionalString(d.stderr)
                w.optionalString(d.detail); w.optionalString(d.errorText); w.optionalInt(d.exitCode); w.optionalString(d.inlineDiff)
                // [screen] bit 4: a screenshot's gateway path follows the generated image; bit 8: it has expired;
                // bit 16: its capture time follows the path. An inline `data:` picture is never written (the cache
                // stays bounded).
                let shot = d.screenshot.flatMap { $0.isInline ? nil : $0 }
                let shotFlags: UInt8 = (shot != nil ? 4 : 0) | (shot?.expired == true ? 8 : 0) | (shot?.capturedAt != nil ? 16 : 0)
                w.json(d.payloadRef); w.byte((d.failed ? 1 : 0) | (d.isCacheCopy ? 2 : 0) | shotFlags)
                AttachmentCoding.write(d.generatedImage, into: &w)         // [attachments]
                if let shot {                                              // [screen]
                    w.string(shot.source)
                    if let at = shot.capturedAt { w.double(at) }
                }
            }
            AttachmentCoding.write(meta.attachments, into: &w)              // [attachments]
            w.optionalInt(meta.lastRowId)                                   // HQT5
        } else {
            w.bool(false)
        }
    }

    private static func read(_ r: inout BinaryReader, hasLastRow: Bool) throws -> (ChatMessage, MessageMeta?) {
        let id = try r.string()
        let roleByte = try r.byte()
        let role: ChatMessage.Role = roleByte == 0 ? .user : roleByte == 1 ? .assistant : .system
        let ts = try r.optionalDouble()
        let rowId = try r.optionalInt()
        let flags = try r.byte()
        let error = try r.optionalString()
        var reactions: [MessageReaction] = []
        var reactionRow: Int?
        if flags & 2 != 0 {
            let count = try r.count()
            guard count <= 1_000 else { throw BinaryReader.Failure.malformed }
            for _ in 0..<count { reactions.append(MessageReaction(emoji: try r.string(), author: try r.string(), at: try r.optionalDouble())) }
            reactionRow = try r.optionalInt()
        }
        let partCount = try r.count()
        guard partCount <= 100_000 else { throw BinaryReader.Failure.malformed }
        var parts: [ChatPart] = []
        parts.reserveCapacity(partCount)
        for _ in 0..<partCount {
            switch try r.byte() {
            case 0: parts.append(.text(try r.string()))
            case 1: parts.append(.reasoning(try r.string()))
            case 2:
                let id = try r.string(), name = try r.string(), title = try r.string()
                let args = try r.optionalString(), summary = try r.optionalString()
                let stateByte = try r.byte()
                let s = stateByte & 0x7F
                let duration = try r.optionalDouble()
                var call = ToolCall(id: id, name: name, title: title, argsText: args, summary: summary,
                                    state: s == 0 ? .running : s == 1 ? .done : .failed, durationSeconds: duration)
                if stateByte & 0x80 != 0 { call.card = ToolCard(json: try r.json()) }     // [activity]
                parts.append(.tool(call))
            default: throw BinaryReader.Failure.malformed
            }
        }
        var message = ChatMessage(id: id, role: role, parts: parts, timestamp: ts.map { Date(timeIntervalSince1970: $0) }, rowId: rowId)
        message.interrupted = flags & 1 != 0
        message.error = error
        message.reactions = reactions
        message.reactionRow = reactionRow
        guard try r.bool() else { return (message, nil) }
        var meta = MessageMeta()
        meta.serverRowSpan = try r.int()
        let refCount = try r.count()
        for _ in 0..<refCount { meta.attachmentRefs.append(try r.string()) }
        meta.systemNotice = try r.bool()
        let dc = try r.byte()
        meta.durableComplete = dc == 0 ? nil : dc == 1
        meta.asyncResult = try r.optionalString()
        meta.firstRowId = try r.optionalInt()
        let toolCount = try r.count()
        for _ in 0..<toolCount {
            let key = try r.string()
            var d = ToolDetail()
            d.command = try r.optionalString(); d.input = try r.optionalString(); d.stdout = try r.optionalString()
            d.stderr = try r.optionalString(); d.detail = try r.optionalString(); d.errorText = try r.optionalString()
            d.exitCode = try r.optionalInt(); d.inlineDiff = try r.optionalString(); d.payloadRef = try r.json()
            let toolFlags = try r.byte()
            d.failed = toolFlags & 1 != 0
            d.isCacheCopy = toolFlags & 2 != 0
            d.generatedImage = try AttachmentCoding.readGenerated(&r)       // [attachments]
            if toolFlags & 4 != 0 {                                         // [screen]
                var shot = ToolScreenshot(source: try r.string(), expired: toolFlags & 8 != 0)
                if toolFlags & 16 != 0 { shot.capturedAt = try r.double() }
                d.screenshot = shot
            }
            meta.tools[key] = d
        }
        meta.attachments = try AttachmentCoding.readAttachments(&r)         // [attachments]
        if hasLastRow { meta.lastRowId = try r.optionalInt() }              // HQT5
        return (message, meta)
    }
}
