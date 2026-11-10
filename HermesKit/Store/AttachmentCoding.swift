// The transcript cache's encoding of attachments and generated images (HQT2, docs/spec/1x-attachments.md §7.2): no
// bytes, no data URIs and no phone paths — a `.local` attachment is written as the gateway path it was uploaded to,
// or skipped when its upload never finished.

import Foundation

nonisolated enum AttachmentCoding {
    /// The most attachments one cached message keeps (the reader refuses more as malformed; the writer never writes
    /// more, so a row with dozens of `@file:` refs still caches: its first 64 show on a cached paint, all after a read).
    static let maxCached = 64

    static func write(_ attachments: [MessageAttachment], into w: inout BinaryWriter) {
        let kept = attachments.compactMap(\.cacheable).prefix(maxCached)
        w.varint(UInt64(kept.count))
        for a in kept {
            w.byte(a.kind.rawValue)
            switch a.source {
            case .gateway(let path): w.byte(0); w.string(path)
            case .inline(let key): w.byte(1); w.string(key)
            case .remote(let url): w.byte(2); w.string(url.absoluteString)
            case .tooLarge: w.byte(3)
            case .local: w.byte(3)        // unreachable: `cacheable` maps or drops it
            }
            w.string(a.name)
            w.optionalInt(a.pixelWidth)
            w.optionalInt(a.pixelHeight)
            w.optionalInt(a.byteSize.map { Int($0) })
        }
    }

    static func readAttachments(_ r: inout BinaryReader) throws -> [MessageAttachment] {
        let count = try r.count()
        guard count <= maxCached else { throw BinaryReader.Failure.malformed }
        var out: [MessageAttachment] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            guard let kind = MessageAttachment.Kind(rawValue: try r.byte()) else { throw BinaryReader.Failure.malformed }
            let source: MessageAttachment.Source
            switch try r.byte() {
            case 0: source = .gateway(path: try r.string())
            case 1: source = .inline(mediaKey: try r.string())
            case 2:
                guard let url = URL(string: try r.string()) else { throw BinaryReader.Failure.malformed }
                source = .remote(url)
            case 3: source = .tooLarge
            default: throw BinaryReader.Failure.malformed
            }
            let name = try r.string()
            let w = try r.optionalInt(), h = try r.optionalInt(), size = try r.optionalInt()
            out.append(MessageAttachment(kind: kind, source: source, name: name, pixelWidth: w, pixelHeight: h, byteSize: size.map { Int64($0) }))
        }
        return out
    }

    static func write(_ info: GeneratedImageInfo?, into w: inout BinaryWriter) {
        guard let info else { w.bool(false); return }
        w.bool(true)
        w.optionalString(info.source)
        w.optionalInt(info.pixelWidth)
        w.optionalInt(info.pixelHeight)
        w.byte(info.aspect == .landscape ? 0 : info.aspect == .square ? 1 : 2)
        w.bool(info.success)
        let echoes = info.echoes.sorted().prefix(maxEchoes)
        w.varint(UInt64(echoes.count))
        for e in echoes { w.string(e) }
    }

    /// At most three keys name an echo (`host_image`, `image`, `agent_visible_image`).
    static let maxEchoes = 3

    static func readGenerated(_ r: inout BinaryReader) throws -> GeneratedImageInfo? {
        guard try r.bool() else { return nil }
        let source = try r.optionalString()
        let w = try r.optionalInt(), h = try r.optionalInt()
        let aspect: GeneratedImageInfo.Aspect = switch try r.byte() { case 0: .landscape; case 1: .square; default: .portrait }
        let success = try r.bool()
        let echoCount = try r.count()
        guard echoCount <= maxEchoes else { throw BinaryReader.Failure.malformed }
        var echoes = Set<String>()
        for _ in 0..<echoCount { echoes.insert(try r.string()) }
        return GeneratedImageInfo(source: source, pixelWidth: w, pixelHeight: h, aspect: aspect, success: success, echoes: echoes)
    }
}
