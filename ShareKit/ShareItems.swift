// [share] What was shared into the sheet, read from the item providers (docs/spec/3x-share.md §7.6).
// Port of build 240's ShareExtension/ShareItems.swift. Foundation's `NSItemProvider` only; no UIKit.
//
// Providers are read strictly one after another (memory stays flat: the extension has about 120 MB). A photo becomes
// the app's own 3072 px JPEG with no location or camera details, a video loses its location, any other file is copied
// as it is, text and links are kept as text. Past the caps a photo or a file is not read at all.

import Foundation
import CoreGraphics
import UniformTypeIdentifiers

/// One thing shared into the sheet, ready to send: text and links go into the prompt, photos and files are staged as
/// files the extension owns (in its own temporary folder, removed when the sheet closes).
nonisolated struct SharedItem: Identifiable, Equatable, @unchecked Sendable {
    enum Kind: Equatable, Sendable { case text(String), link(URL), image, file }
    let id: UUID
    let kind: Kind
    /// Photos and files: the staged copy (for a file over the limit, where it would have been: it is never copied).
    var file: URL?
    /// The name it is sent under.
    var name: String
    var bytes: Int
    /// A small preview of a photo (immutable once made, which is what makes this type safe to send).
    var thumbnail: CGImage?

    init(kind: Kind, file: URL? = nil, name: String = "", bytes: Int = 0, thumbnail: CGImage? = nil) {
        id = UUID(); self.kind = kind; self.file = file; self.name = name; self.bytes = bytes; self.thumbnail = thumbnail
    }

    static func == (a: SharedItem, b: SharedItem) -> Bool { a.id == b.id }

    var attachment: ShareAttachment? {
        guard let file else { return nil }
        switch kind {
        case .image: return ShareAttachment(kind: .image, file: file, name: name)
        case .file: return ShareAttachment(kind: .file, file: file, name: name)
        default: return nil
        }
    }

    var sharedText: String? {
        switch kind {
        case .text(let text): return text
        case .link(let url): return url.absoluteString
        default: return nil
        }
    }
}

/// What a share held beyond the caps (ten photos, ten files) and so was never read: the sheet says so.
nonisolated struct ShareSkipped: Equatable, Sendable {
    var photos = 0
    var files = 0
}

nonisolated enum ShareItemLoader {
    struct Failure: Error { let name: String }

    /// The name an item that could not be read goes by when it has none of its own.
    static let namelessItem = "an item"

    /// Reads every provider of `inputs` into `folder` (`tmp/dispatch-share-<UUID>`), each staged file in its own
    /// `<UUID>/` folder. `limit`: the attachment limit; a file over it is measured and named, never copied (and a video
    /// never re-muxed). `failures` are the names of what could not be read.
    /// `picture`: what the sheet's side makes of a picture that arrives as an object instead of a file or bytes (a
    /// UIImage: ShareKit itself has no UIKit): a bitmap the right way up, on white, no larger than a shared photo.
    /// `skipped`: how many photos and files came after the tenth (iOS can offer the sheet for more than its rule
    /// allows) and were not read at all.
    /// A cancelled load leaves nothing staged: the read in flight at the moment of Cancel still finishes (a provider
    /// cannot be stopped half way) and writes its copy, so the whole folder is removed once it has, and nothing is
    /// returned.
    static func load(_ inputs: [NSExtensionItem], into folder: URL, limit: Int = .max,
                     picture: PictureReader? = nil) async -> (items: [SharedItem], failures: [String], skipped: ShareSkipped) {
        let loaded = await read(inputs, into: folder, limit: limit, picture: picture)
        guard Task.isCancelled else { return loaded }
        try? FileManager.default.removeItem(at: folder)
        return ([], [], ShareSkipped())
    }

    private static func read(_ inputs: [NSExtensionItem], into folder: URL, limit: Int,
                             picture: PictureReader?) async -> (items: [SharedItem], failures: [String], skipped: ShareSkipped) {
        var items: [SharedItem] = [], failures: [String] = []
        var images = 0, files = 0
        var skipped = ShareSkipped()
        for input in inputs {
            let providers = input.attachments ?? []
            for provider in providers {
                if Task.isCancelled { return (items, failures, skipped) }      // Cancel reads nothing more
                // Past the cap, a photo or a file is not read at all (no decode, no copy): it is only counted.
                switch slot(of: provider) {
                case .image? where images >= ShareRules.maxImages: skipped.photos += 1; continue
                case .file? where files >= ShareRules.maxFiles: skipped.files += 1; continue
                default: break
                }
                do {
                    guard let item = try await load(provider, folder: folder, limit: limit, picture: picture) else { continue }
                    if item.kind == .image { images += 1 }
                    if item.kind == .file { files += 1 }
                    // Safari shares a page's link more than once (URL and text): keep one.
                    if let text = item.sharedText, items.contains(where: { $0.sharedText == text }) { continue }
                    items.append(item)
                } catch let failure as Failure {
                    failures.append(failure.name)
                } catch {
                    failures.append(provider.suggestedName.map(ShareRules.safeName) ?? namelessItem)
                }
            }
            // A share with no attachment but a caption (some apps) still has words to send.
            if providers.isEmpty, let text = input.attributedContentText?.string.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty, !items.contains(where: { $0.sharedText == text }) {
                items.append(SharedItem(kind: .text(String(text.prefix(ShareRules.maxSharedText)))))
            }
        }
        return (items, failures, skipped)
    }

    /// What a provider loads as, by its type alone (the order `load` checks in): a photo, a file (a video too), or
    /// neither (a link or text, which no cap limits).
    static func slot(of provider: NSItemProvider) -> SharedItem.Kind? {
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) { return .image }
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) { return .file }
        if isWebLink(provider) { return nil }
        if isFile(provider) { return .file }
        return nil
    }

    private static func isWebLink(_ provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
            && !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
    }

    private static func isFile(_ provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) || provider.registeredTypeIdentifiers.contains {
            UTType($0).map { $0.conforms(to: .data) && !$0.conforms(to: .plainText) && !$0.conforms(to: .url) } ?? false
        }
    }

    private static func load(_ provider: NSItemProvider, folder: URL, limit: Int, picture: PictureReader?) async throws -> SharedItem? {
        let suggested = provider.suggestedName
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            return try await image(provider, folder: folder, reader: picture)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            var item = try await file(provider, type: .movie, folder: folder, limit: limit)
            if let staged = item.file, item.bytes <= limit {
                do { try await ShareMedia.removeLocation(fromMovieAt: staged) } catch {
                    try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
                    throw Failure(name: item.name)
                }
                item.bytes = size(staged)
            }
            return item
        }
        if isWebLink(provider) {
            // Only http and https are links; anything else a provider calls a URL falls through to text or is unreadable.
            if let url = await loadURL(provider), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
                return SharedItem(kind: .link(url))
            }
        }
        if isFile(provider) {
            return try await file(provider, type: .data, folder: folder, limit: limit)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) || provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
            guard let text = await loadText(provider)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            if let url = link(text) { return SharedItem(kind: .link(url)) }
            return SharedItem(kind: .text(text))
        }
        throw Failure(name: suggested.map(ShareRules.safeName) ?? namelessItem)
    }

    /// A lone http(s) address without spaces is a link.
    static func link(_ text: String) -> URL? {
        guard !text.contains(where: \.isWhitespace), let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host() != nil else { return nil }
        return url
    }

    private struct Staged: @unchecked Sendable {
        let file: URL
        let bytes: Int
        let copied: Bool
        var thumbnail: CGImage? = nil
    }

    /// Turns a picture that arrived as an object into a bitmap (see `load`). Nil: not a picture it knows.
    typealias PictureReader = @Sendable (Any) -> CGImage?

    /// One picture's outcome on one way of reading it: staged, no good (unreadable), or not offered this way.
    private enum Picture: Sendable {
        case staged(Staged)
        case unreadable
        case notThisWay
    }

    /// A photo arrives in one of three ways, tried in this order:
    /// 1. with a file behind it (Photos, Files): converted from the file, so the full picture is never decoded;
    /// 2. as bytes of a picture format (an app handing over a PNG or JPEG it holds), when there is no file;
    /// 3. as itself, an object (a screenshot or a drawing handed over as a UIImage): `reader` draws it. Also tried
    ///    when the "file" of the first way was not a picture (the system writes such an object out as an archive).
    /// Only when every way fails is the photo unreadable. Build 240 read only the first way.
    private static func image(_ provider: NSItemProvider, folder: URL, reader: PictureReader?) async throws -> SharedItem {
        let name = ShareRules.safeName(ShareRules.stem(ShareRules.safeName(provider.suggestedName ?? "photo")) + ".jpg")
        let directory = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let target = directory.appendingPathComponent(name)
        @Sendable func stage(_ make: () throws -> Data) -> Picture {
            do {
                let jpeg = try make()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try jpeg.write(to: target, options: [.atomic, .completeFileProtectionUnlessOpen])
                return .staged(Staged(file: target, bytes: size(target), copied: true, thumbnail: ShareMedia.thumbnail(at: target)))
            } catch {
                try? FileManager.default.removeItem(at: directory)
                return .unreadable
            }
        }
        var picture: Picture = await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
                // The provider's file exists only during this callback.
                autoreleasepool {
                    guard let url else { return continuation.resume(returning: .notThisWay) }
                    continuation.resume(returning: stage { try ShareMedia.jpeg(at: url) })
                }
            }
        }
        if case .notThisWay = picture,
           let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) ?? false }) {
            picture = await withCheckedContinuation { continuation in
                _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                    autoreleasepool {
                        guard let data, !data.isEmpty else { return continuation.resume(returning: .notThisWay) }
                        // Bytes that are not a picture after all (an object's archive) are no verdict: the next way is tried.
                        let staged = stage { try ShareMedia.jpeg(data: data) }
                        if case .staged = staged { continuation.resume(returning: staged) } else { continuation.resume(returning: .notThisWay) }
                    }
                }
            }
        }
        if case .staged = picture {} else {
            picture = await withCheckedContinuation { continuation in
                provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { value, _ in
                    autoreleasepool {
                        if let url = value as? URL, url.isFileURL {
                            continuation.resume(returning: stage { try ShareMedia.jpeg(at: url) })
                        } else if let data = value as? Data {
                            continuation.resume(returning: stage { try ShareMedia.jpeg(data: data) })
                        } else if let value, let bitmap = reader?(value) {
                            continuation.resume(returning: stage { try ShareMedia.jpeg(of: bitmap) })
                        } else {
                            continuation.resume(returning: .notThisWay)
                        }
                    }
                }
            }
        }
        guard case .staged(let staged) = picture else { throw Failure(name: name) }
        return SharedItem(kind: .image, file: staged.file, name: name, bytes: staged.bytes, thumbnail: staged.thumbnail)
    }

    private static func file(_ provider: NSItemProvider, type: UTType, folder: URL, limit: Int) async throws -> SharedItem {
        let identifier = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: type) ?? false }
            ?? (provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) ? UTType.item.identifier : type.identifier)
        let suggested = provider.suggestedName
        let fallback = suggested.map(ShareRules.safeName) ?? "attachment"
        let directory = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let staged: Staged = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, _ in
                var name = fallback
                do {
                    guard let url else { throw Failure(name: fallback) }
                    // A name without an extension takes the provider file's own.
                    name = ShareRules.safeName(suggested ?? url.lastPathComponent, fallbackExtension: url.pathExtension)
                    let target = directory.appendingPathComponent(name)
                    let bytes = size(url)
                    guard bytes > 0 else { throw Failure(name: name) }      // nothing in it: nothing to send
                    // Too large to send: named and measured for the sheet's "larger than" line, never copied.
                    guard bytes <= limit else { return continuation.resume(returning: Staged(file: target, bytes: bytes, copied: false)) }
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: target)
                    try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: target.path)
                    continuation.resume(returning: Staged(file: target, bytes: size(target), copied: true))
                } catch {
                    try? FileManager.default.removeItem(at: directory)
                    continuation.resume(throwing: Failure(name: name))
                }
            }
        }
        return SharedItem(kind: .file, file: staged.file, name: staged.file.lastPathComponent, bytes: staged.bytes)
    }

    /// A link arrives as a URL, as text, or (when the sharing app registered an object) in the system's own
    /// serialised form, which only NSURL itself reads back.
    private static func loadURL(_ provider: NSItemProvider) async -> URL? {
        let loaded: URL? = await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { value, _ in
                if let url = value as? URL { continuation.resume(returning: url) }
                else if let data = value as? Data {
                    let object = try? NSURL.object(withItemProviderData: data, typeIdentifier: UTType.url.identifier)
                    continuation.resume(returning: (object as URL?) ?? URL(dataRepresentation: data, relativeTo: nil))
                }
                else if let text = value as? String { continuation.resume(returning: URL(string: text)) }
                else { continuation.resume(returning: nil) }
            }
        }
        if let loaded, loaded.scheme != nil { return loaded }
        guard provider.canLoadObject(ofClass: NSURL.self) else { return loaded }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in continuation.resume(returning: (object as? NSURL) as URL?) }
        }
    }

    /// At most `ShareRules.maxSharedText` characters (a text file is read only that far): the prompt is no place for more.
    private static func loadText(_ provider: NSItemProvider) async -> String? {
        let type = provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) ? UTType.plainText : UTType.text
        let limit = ShareRules.maxSharedText
        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { value, _ in
                var text: String?
                if let value = value as? String { text = value }
                else if let value = value as? NSAttributedString { text = value.string }
                else if let data = value as? Data { text = String(decoding: data.prefix(limit * 4), as: UTF8.self) }
                else if let url = value as? URL, url.isFileURL, let handle = try? FileHandle(forReadingFrom: url) {
                    text = (try? handle.read(upToCount: limit * 4)).map { String(decoding: $0, as: UTF8.self) }
                    try? handle.close()
                }
                continuation.resume(returning: text.map { $0.count > limit ? String($0.prefix(limit)) : $0 })
            }
        }
    }

    static func size(_ file: URL) -> Int { (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }

    // MARK: Temporary folders

    /// A new folder name for one sheet's staged copies: `tmp/dispatch-share-<UUID>`.
    static func newFolder(in temporary: URL = FileManager.default.temporaryDirectory) -> URL {
        temporary.appendingPathComponent(ShareIdentity.temporaryPrefix + UUID().uuidString, isDirectory: true)
    }

    /// A sheet the system ended without Cancel or Send leaves its copies behind: an hour on, they go.
    static func removeStaleFolders(in temporary: URL = FileManager.default.temporaryDirectory, now: Date = Date(), olderThan age: TimeInterval = 3600) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? []
        for name in names where name.hasPrefix(ShareIdentity.temporaryPrefix) {
            let url = temporary.appendingPathComponent(name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified < now.addingTimeInterval(-age) { try? FileManager.default.removeItem(at: url) }
        }
    }
}
