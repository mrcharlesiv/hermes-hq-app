// The words of the audio preview sheet (docs/spec/3x-talk.md §11): which attachments it opens, and how the size, the
// kind and the times read. Pure; the sheet is App/Chat/Attachments/AudioPreviewSheet.swift.

import Foundation
import UniformTypeIdentifiers

nonisolated enum AudioPreviewText {
    static let loading = "Loading…"
    static let failed = "Couldn’t load this recording."

    /// Audio by its type, or by its name when the type is not known.
    static func isAudio(typeIdentifier: String?, name: String) -> Bool {
        if let typeIdentifier, let type = UTType(typeIdentifier), type.conforms(to: .audio) { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .audio)
    }

    /// "M4A audio", "MP3 audio"; "Audio" when the name has no usable extension.
    static func kind(name: String) -> String {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, ext.count <= 5, ext.allSatisfy({ $0.isLetter || $0.isNumber }) else { return "Audio" }
        return "\(ext.uppercased()) audio"
    }

    /// "128 KB", "1.2 MB", "900 bytes".
    static func size(_ bytes: Int64) -> String {
        if bytes < 1000 { return bytes == 1 ? "1 byte" : "\(max(0, bytes)) bytes" }
        if bytes < 1_000_000 { return "\(Int((Double(bytes) / 1000).rounded())) KB" }
        let megabytes = Double(bytes) / 1_000_000
        return megabytes < 100 ? String(format: "%.1f MB", megabytes) : "\(Int(megabytes.rounded())) MB"
    }

    /// "128 KB · M4A audio".
    static func detail(bytes: Int64?, name: String) -> String {
        guard let bytes, bytes > 0 else { return kind(name: name) }
        return "\(size(bytes)) · \(kind(name: name))"
    }

    /// "0:04", "12:30".
    static func clock(_ seconds: Double) -> String {
        let whole = max(0, Int((seconds.isFinite ? seconds : 0).rounded(.down)))
        return "\(whole / 60):" + String(format: "%02d", whole % 60)
    }

    /// What VoiceOver reads for the scrubber: "4 seconds of 12 seconds".
    static func spokenPosition(elapsed: Double, total: Double) -> String {
        "\(spoken(elapsed)) of \(spoken(total))"
    }

    static func spoken(_ seconds: Double) -> String {
        let whole = max(0, Int((seconds.isFinite ? seconds : 0).rounded(.down)))
        let minutes = whole / 60, rest = whole % 60
        func unit(_ count: Int, _ name: String) -> String { count == 1 ? "1 \(name)" : "\(count) \(name)s" }
        if minutes == 0 { return unit(rest, "second") }
        return rest == 0 ? unit(minutes, "minute") : "\(unit(minutes, "minute")) \(unit(rest, "second"))"
    }
}
