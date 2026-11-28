import UIKit
import Photos
import UniformTypeIdentifiers

// Save, Share and Copy for a chat image (docs/spec/1x-attachments.md §9.4–§9.6): Save adds the original bytes to Photos
// with add-only access; Share hands the share sheet a copy named after the image (its extension matching the bytes),
// kept until the sheet closes; Copy puts the image data on the pasteboard with its type. Each says how it went: "Saved"
// or "Copied" (the HUD Select Text uses), "Preparing…" while Share fetches the original, and an alert that can try
// again when one fails.
// Owner 2026-11-22 ("You can't click to copy or save etc an image when you open the image in HQ"): the same menu on
// the picture in every full-screen viewer (chat photos, Artifacts images, a tool card's picture), so each action works
// from a `MediaSource` (a name and a way to fetch the bytes), not only a chat attachment.

/// An image the actions can work on: its name (for the shared/saved copy) and how to get its bytes as a file.
struct MediaSource {
    let name: String
    let fetch: @MainActor () async throws -> URL
    /// What a failed fetch says; nil: the photo viewer's words.
    var explain: ((Error) -> String)?

    init(name: String, explain: ((Error) -> String)? = nil, fetch: @escaping @MainActor () async throws -> URL) {
        self.name = name
        self.explain = explain
        self.fetch = fetch
    }

    /// A chat attachment: its original, loaded or downloaded if needed.
    @MainActor static func item(_ item: MediaItem) -> MediaSource {
        MediaSource(name: item.attachment.name) { try await MediaActions.original(item) }
    }

    /// A picture already in memory (a tool card's screenshot): written as PNG to a temporary file.
    @MainActor static func image(_ image: @escaping @MainActor () -> UIImage, name: String) -> MediaSource {
        MediaSource(name: name) {
            let picture = image()
            let data = await Task.detached(priority: .userInitiated) { picture.pngData() }.value
            guard let data else { throw CocoaError(.fileWriteUnknown) }
            return try temporaryFile(data, name: name, ext: "png")
        }
    }

    /// Bytes read from somewhere (the gateway), written to a temporary file for the actions.
    static func temporaryFile(_ data: Data, name: String, ext: String? = nil) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "HQNViewer-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            var file = AttachmentStaging.safeName(name.isEmpty ? "image" : name)
            if let ext, (file as NSString).pathExtension.isEmpty { file += "." + ext }
            let url = folder.appending(path: file)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}

@MainActor enum MediaActions {
    enum SaveOutcome { case saved, denied, failed(String) }

    /// Removes a temporary `HQNViewer-*` folder created by `MediaSource.temporaryFile` once an action is done with it.
    nonisolated static func removeViewerTempIfOwned(_ url: URL) {
        let folder = url.deletingLastPathComponent()
        let tempRoot = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let parent = folder.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        guard parent == tempRoot, folder.lastPathComponent.hasPrefix("HQNViewer-") else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// The original's bytes on the phone (loaded or downloaded if needed).
    static func original(_ item: MediaItem) async throws -> URL {
        guard let context = item.context else { throw MediaLoadError.unavailable }
        return try await MediaLoader.shared.original(item.attachment, context: context)
    }

    /// What a failed fetch says (the same words as the viewer's "Couldn’t Load the Photo").
    private static func message(_ error: Error, _ source: MediaSource) -> String {
        if let explain = source.explain { return explain(error) }
        return (error as? MediaLoadError)?.fileMessage ?? MediaLoadError.unreachable.fileMessage
    }

    static func save(_ item: MediaItem) async -> SaveOutcome { await save(.item(item)) }

    static func save(_ source: MediaSource) async -> SaveOutcome {
        let url: URL
        do { url = try await source.fetch() } catch { return .failed(message(error, source)) }
        defer { removeViewerTempIfOwned(url) }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return .denied }
        let named = namedCopy(url, name: source.name)
        defer { if let named { try? FileManager.default.removeItem(at: named.deletingLastPathComponent()) } }
        do {
            // Photos runs the change block on its own queue: it must not be main-actor isolated.
            try await PHPhotoLibrary.shared().performChanges(addPhoto(named ?? url))
            return .saved
        } catch {
            return .failed("Photos couldn’t add this image.")
        }
    }

    nonisolated private static func addPhoto(_ url: URL) -> @Sendable () -> Void {
        {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: url, options: nil)
        }
    }

    static func showSaveDenied(on vc: UIViewController) {
        Haptics.play(.error)   // as the save's other failures
        // [mac] Mac polish #11: System Settings › Privacy & Security › Photos on the Mac (`PrivacySettingsLink`).
        let alert = UIAlertController(title: "Couldn’t Save",
                                      message: "Allow \(AppIdentity.current.displayName) to add photos in \(PrivacySettingsLink.place), then try again.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: PrivacySettingsLink.openTitle, style: .default) { _ in PrivacySettingsLink.open(.photos) })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        vc.present(alert, animated: true)
    }

    /// "Couldn’t Save" / "Couldn’t Share" / "Couldn’t Copy" with what went wrong, and Try Again.
    static func showFailure(_ title: String, message: String, on vc: UIViewController, retry: @escaping @MainActor () -> Void) {
        Haptics.play(.error)
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Try Again", style: .default) { _ in retry() })
        vc.present(alert, animated: true)
    }

    /// The share sheet with a copy named after the image (R:src/image-names.ts:5-30); the copy goes when it closes.
    /// "Preparing…" shows while the original is fetched, when that isn't instant.
    static func share(_ item: MediaItem, from vc: UIViewController, anchor: UIView?, barItem: UIBarButtonItem? = nil) async {
        await share(.item(item), from: vc, anchor: anchor, barItem: barItem)
    }

    static func share(_ source: MediaSource, from vc: UIViewController, anchor: UIView?, barItem: UIBarButtonItem? = nil) async {
        let pending = Task { @MainActor [weak vc] () -> UIView? in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return nil }
            return MenusHUD.show("Preparing…", symbol: nil, in: vc?.view, seconds: nil)
        }
        let named: URL?
        let failure: String?
        do {
            let fetched = try await source.fetch()
            defer { removeViewerTempIfOwned(fetched) }
            named = namedCopy(fetched, name: source.name)
            failure = named == nil ? "A copy of the image to share couldn’t be made." : nil
        } catch {
            named = nil
            failure = message(error, source)
        }
        pending.cancel()
        MenusHUD.hide(await pending.value)
        guard let named else {
            showFailure("Couldn’t Share", message: failure ?? MediaLoadError.unreachable.fileMessage, on: vc) { [weak vc, weak anchor] in
                guard let vc else { return }
                Task { await share(source, from: vc, anchor: anchor, barItem: barItem) }
            }
            return
        }
        let sheet = UIActivityViewController(activityItems: [named], applicationActivities: nil)
        sheet.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: named.deletingLastPathComponent()) }
        if let barItem { sheet.popoverPresentationController?.sourceItem = barItem } else { sheet.popoverPresentationController?.sourceView = anchor }
        vc.present(sheet, animated: true)
    }

    /// [mac-audit] Owner 2026-11-02 (Mac audit J1): Save As…: the original fetched as Share… fetches it ("Preparing…"
    /// when that isn't instant), named as Share names it, then the Mac's save panel; the copy goes when the panel closes.
    static func saveAs(_ item: MediaItem, from vc: UIViewController) async { await saveAs(.item(item), from: vc) }

    static func saveAs(_ source: MediaSource, from vc: UIViewController) async {
        let pending = Task { @MainActor [weak vc] () -> UIView? in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return nil }
            return MenusHUD.show("Preparing…", symbol: nil, in: vc?.view, seconds: nil)
        }
        let named: URL?
        let failure: String?
        do {
            let fetched = try await source.fetch()
            defer { removeViewerTempIfOwned(fetched) }
            named = namedCopy(fetched, name: source.name)
            failure = named == nil ? "A copy of the image to save couldn’t be made." : nil
        } catch {
            named = nil
            failure = message(error, source)
        }
        pending.cancel()
        MenusHUD.hide(await pending.value)
        guard let named else {
            showFailure("Couldn’t Save", message: failure ?? MediaLoadError.unreachable.fileMessage, on: vc) { [weak vc] in
                guard let vc else { return }
                Task { await saveAs(source, from: vc) }
            }
            return
        }
        FileSaver.present(named, from: vc, removing: named.deletingLastPathComponent())
    }

    /// Copies the image: nil when it went, otherwise what went wrong.
    static func copy(_ item: MediaItem) async -> String? { await copy(.item(item)) }

    static func copy(_ source: MediaSource) async -> String? {
        let url: URL
        do { url = try await source.fetch() } catch { return message(error, source) }
        defer { removeViewerTempIfOwned(url) }
        // The bytes keep their own type; a type many apps can't paste (WebP, HEIC) also carries a PNG (L1003).
        let payload = await Task.detached(priority: .userInitiated) { () -> (Data, String, Data?)? in
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
            let type = imageType(of: url)
            let common: [UTType] = [.png, .jpeg, .gif]
            let png = common.contains(where: { type.conforms(to: $0) }) ? nil : UIImage(data: data)?.pngData()
            return (data, type.identifier, png)
        }.value
        guard let (data, type, png) = payload else { return "The image couldn’t be read." }
        var representations: [String: Any] = [type: data]
        if let png { representations[UTType.png.identifier] = png }
        UIPasteboard.general.setItems([representations])
        return nil
    }

    /// The bytes' own image type (JPEG / PNG / GIF / HEIC…).
    nonisolated static func imageType(of url: URL) -> UTType {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source) as String?,
              let ut = UTType(type) else { return .jpeg }
        return ut
    }

    /// A temporary copy named `<name>.<ext of the bytes>` (`image.<ext>` without a name).
    static func namedCopy(_ url: URL, item: MediaItem) -> URL? { namedCopy(url, name: item.attachment.name) }

    static func namedCopy(_ url: URL, name: String) -> URL? {
        let ext = imageType(of: url).preferredFilenameExtension ?? "jpg"
        var stem = (name as NSString).deletingPathExtension
        if stem.isEmpty || stem == "Photo" || stem == "Image" { stem = "image" }
        let folder = FileManager.default.temporaryDirectory.appending(path: "HQNShare-" + UUID().uuidString, directoryHint: .isDirectory)
        let target = folder.appending(path: AttachmentStaging.safeName(stem + "." + ext))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: target)
            return target
        } catch {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
    }

    /// Menu Save to Photos: "Saved", the Settings alert, or what went wrong with Try Again.
    static func saveFromMenu(_ item: MediaItem, from vc: UIViewController) async { await saveFromMenu(.item(item), from: vc) }

    static func saveFromMenu(_ source: MediaSource, from vc: UIViewController) async {
        switch await save(source) {
        case .saved:
            Haptics.play(.success)
            MenusHUD.show("Saved", in: vc.view)
        case .denied:
            showSaveDenied(on: vc)
        case .failed(let message):
            showFailure("Couldn’t Save", message: message, on: vc) { [weak vc] in
                guard let vc else { return }
                Task { await saveFromMenu(source, from: vc) }
            }
        }
    }

    /// Menu Copy Image: "Copied", or what went wrong with Try Again.
    static func copyFromMenu(_ item: MediaItem, from vc: UIViewController) async { await copyFromMenu(.item(item), from: vc) }

    static func copyFromMenu(_ source: MediaSource, from vc: UIViewController) async {
        if let message = await copy(source) {
            showFailure("Couldn’t Copy", message: message, on: vc) { [weak vc] in
                guard let vc else { return }
                Task { await copyFromMenu(source, from: vc) }
            }
        } else {
            Haptics.play(.success)
            MenusHUD.show("Copied", in: vc.view)
        }
    }

    /// The long-press menu on a chat image (spec §9.6): Save to Photos, Share…, Copy. [mac-audit] On the Mac, Save As…
    /// after Save to Photos (Mac audit J1: a picture could only go to Photos or the share sheet).
    static func menu(for item: MediaItem, from vc: UIViewController, anchor: UIView) -> UIMenu {
        menu(for: .item(item), from: vc, anchor: anchor)
    }

    /// The same menu for any image (`MediaSource`): also the full-screen viewers' press-and-hold / right-click.
    static func menu(for source: MediaSource, from vc: UIViewController, anchor: UIView) -> UIMenu {
        let saving: [UIMenuElement] = !FileSaver.offered ? [] : [FileSaver.action { [weak vc] in
            guard let vc else { return }
            Task { @MainActor in await saveAs(source, from: vc) }
        }]
        // Beside Save As… the Photos item takes the Photos glyph (the phone keeps its own).
        let photos: [UIMenuElement] = [
            UIAction(title: "Save to Photos", image: UIImage(systemName: FileSaver.offered ? "photo.badge.plus" : "square.and.arrow.down")) { [weak vc] _ in
                guard let vc else { return }
                Task { @MainActor in await saveFromMenu(source, from: vc) }
            },
        ]
        return UIMenu(children: photos + saving + [
            UIAction(title: "Share…", image: UIImage(systemName: "square.and.arrow.up")) { [weak vc, weak anchor] _ in
                guard let vc else { return }
                Task { @MainActor in await share(source, from: vc, anchor: anchor) }
            },
            UIAction(title: "Copy Image", image: UIImage(systemName: "doc.on.doc")) { [weak vc] _ in
                guard let vc else { return }
                Task { @MainActor in await copyFromMenu(source, from: vc) }
            },
        ] as [UIMenuElement])
    }
}

/// Owner 2026-11-22: press and hold (right-click on the Mac) on a full-screen viewer's picture opens
/// `MediaActions.menu`. The viewer keeps this object (an interaction holds its delegate weakly); `menu` returns nil
/// while there is no picture yet.
@MainActor final class ViewerImageMenu: NSObject, UIContextMenuInteractionDelegate {
    private let menu: () -> UIMenu?

    init(menu: @escaping () -> UIMenu?) {
        self.menu = menu
    }

    /// Adds the menu to `view` (made to take touches; its taps still reach the scroll view's recognizers).
    func attach(to view: UIView) {
        view.isUserInteractionEnabled = true
        view.addInteraction(UIContextMenuInteraction(delegate: self))
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let menu = menu() else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
    }
}
