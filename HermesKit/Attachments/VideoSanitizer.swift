// A library video leaves without where it was filmed (docs/spec/1x-attachments.md §5.3; R:ios/App/App/PickedFiles.swift
// :207-233): a passthrough re-mux (streams copied, never re-encoded) with AVFoundation's sharing metadata filter,
// in place of the copy. A video that can't be re-muxed is refused (r5-87), never sent with its location.

import Foundation
import AVFoundation

nonisolated enum VideoSanitizer {
    static func removeLocation(fromMovieAt url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw AttachmentPrepareError.locationNotRemoved
        }
        let ext = url.pathExtension.lowercased()
        let type: AVFileType = switch ext {
        case "mp4": .mp4
        case "m4v": .m4v
        default: .mov
        }
        let output = url.deletingLastPathComponent()
            .appending(path: ".sharing-" + UUID().uuidString + "." + (ext.isEmpty ? "mov" : ext))
        export.metadataItemFilter = .forSharing()
        do {
            try await export.export(to: output, as: type)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: output)
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: url.path)
        } catch {
            try? FileManager.default.removeItem(at: output)
            AppLog.swallowed("transfer", "remove a video's location metadata", error)
            throw AttachmentPrepareError.locationNotRemoved
        }
    }
}
