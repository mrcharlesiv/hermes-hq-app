// [photoheads] Choosing the picture for a photo (docs/spec/3x-photoheads.md §6): the system photo picker or the Files
// browser, then Move and Scale (PhotoFramerController). It knows nothing about bots: it hands back a 256 × 256 PNG as
// a `data:` URL, so the group "Name & Photo" page can use it too.
//
// - Photo Library is `PHPickerViewController` with no photo library object: it runs out of process and asks for no
//   permission. One image; a tap picks and closes.
// - Choose File is the Files browser for images, as a copy.
// - The file is read as an ImageIO thumbnail (1024 px at most, turned upright, never decoded whole), off the main
//   thread. Only pixels go on: location and camera details never leave the phone.
// - DEBUG: `-HQDebugBotPhoto "<abs path>[,<abs path>…]"` stands in for both pickers (each pick takes the next file),
//   and `-HQDebugBotPhotoDelay <seconds>` holds the read that long (the loading state). App/Debug/DebugHooks.swift.

import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// What Move and Scale works on: the picture upright, 1024 px at most on its long side.
nonisolated struct PickedPhoto: @unchecked Sendable {
    let image: CGImage
    var size: CGSize { CGSize(width: image.width, height: image.height) }
}

/// What Move and Scale hands back: the 256 × 256 picture to show now and the PNG to store.
struct FramedPhoto {
    let image: UIImage
    let dataURL: String
}

nonisolated enum PhotoPickError: Error, Equatable, Sendable {
    case tooBig, unreadable

    static let title = "Couldn’t Use That Picture"

    var message: String {
        switch self {
        case .tooBig: "That picture is too big. Choose one under 32 MB."
        case .unreadable: "That file isn’t a picture this app can read. Choose a photo or an image file."
        }
    }
}

/// A file a pick made for itself (the photo picker's copy, the Files browser's copy), in `tmp/bot-photo-picks`. It is
/// removed when whoever holds this lets go, however that happens: the load finished, was cancelled, or was dropped.
nonisolated final class PickedFile: Sendable {
    static let folderName = "bot-photo-picks"
    static var folder: URL { FileManager.default.temporaryDirectory.appending(path: folderName, directoryHint: .isDirectory) }

    let url: URL
    init(_ url: URL) { self.url = url }
    deinit { try? FileManager.default.removeItem(at: url) }

    /// A copy of `url` in the picks folder (the photo picker's file is gone when its callback returns).
    static func copy(of url: URL) -> URL? { place(url) { try FileManager.default.copyItem(at: $0, to: $1) } }

    /// `url` moved into the picks folder (the Files browser's copy, already this app's own).
    static func move(_ url: URL) -> URL? { place(url) { try FileManager.default.moveItem(at: $0, to: $1) } }

    private static func place(_ url: URL, _ put: (URL, URL) throws -> Void) -> URL? {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = url.pathExtension.isEmpty ? "img" : url.pathExtension
        let placed = folder.appending(path: UUID().uuidString + "." + ext)
        do { try put(url, placed) } catch { return nil }
        return placed
    }

    /// Removes what an earlier pick left behind (the app was closed while a file was being read): every file in the
    /// picks folder last touched before `before`. Up to 32 MB a file would otherwise stay until iOS clears `tmp`.
    static func removeLeftovers(before: Date = Date()) {
        let fm = FileManager.default
        guard let found = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for url in found {
            let touched = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if touched < before { try? fm.removeItem(at: url) }
        }
    }
}

/// One picked file being read. The framer opens on it at once and shows a spinner until it finishes.
@MainActor final class PhotoLoad {
    nonisolated static let maxBytes = 32 * 1024 * 1024
    nonisolated static let maxPixel = 1024

    private(set) var result: Result<PickedPhoto, PhotoPickError>?
    /// Called once, on the main actor, unless the load was cancelled first.
    var onFinish: ((Result<PickedPhoto, PhotoPickError>) -> Void)? {
        didSet { if let result, let onFinish { onFinish(result) } }
    }
    private var task: Task<Void, Never>?
    private var progress: Progress?
    private var cancelled = false
    /// The long side the picture is read at: a photo's 1024, a background's `Backdrop.maxPixel`.
    private let maxPixel: Int
    /// A copy made for this load: removed when the load is over, or when the load is let go without ending.
    private var temporary: PickedFile?

    /// Reads `url`. `owned`: the file is a copy made for this load and goes when it is done.
    init(file url: URL, owned: Bool, delay: Duration = .zero, maxPixel: Int = PhotoLoad.maxPixel) {
        self.maxPixel = maxPixel
        if owned { temporary = PickedFile(url) }
        start(url, delay: delay)
    }

    /// The photo picker's choice: its file is copied inside the load callback (it is gone when the callback returns).
    init(provider: NSItemProvider, maxPixel: Int = PhotoLoad.maxPixel) {
        self.maxPixel = maxPixel
        guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else {
            finish(.failure(.unreadable))
            return
        }
        progress = provider.loadFileRepresentation(for: .image, openInPlace: false) { [weak self] url, _, _ in
            // Held from here on: a load that was cancelled or let go meanwhile drops it, and the copy goes with it.
            let copy = url.flatMap(PickedFile.copy(of:)).map(PickedFile.init)
            Task { @MainActor [weak self] in
                guard let self, !self.cancelled else { return }
                guard let copy else { return self.finish(.failure(.unreadable)) }
                self.temporary = copy
                self.start(copy.url, delay: .zero)
            }
        }
    }

    /// Stops the load: nothing is reported after this.
    func cancel() {
        cancelled = true
        onFinish = nil
        progress?.cancel()
        task?.cancel()
        cleanUp()
    }

    private func start(_ url: URL, delay: Duration) {
        let maxPixel = maxPixel
        task = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            let result = await Task.detached(priority: .userInitiated) { Self.read(url, maxPixel: maxPixel) }.value
            guard let self, !Task.isCancelled, !self.cancelled else { return }
            self.finish(result)
        }
    }

    private func finish(_ result: Result<PickedPhoto, PhotoPickError>) {
        guard self.result == nil, !cancelled else { return }
        self.result = result
        cleanUp()
        onFinish?(result)
    }

    private func cleanUp() { temporary = nil }

    /// The read (§6.3): size first, then that the file is all there, then an upright thumbnail.
    nonisolated static func read(_ url: URL, maxPixel: Int = PhotoLoad.maxPixel) -> Result<PickedPhoto, PhotoPickError> {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else { return .failure(.unreadable) }
        if size > maxBytes { return .failure(.tooBig) }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), BotPicture.isWhole(data),
              let image = PhotoNormalizer.thumbnail(data, maxPixel: maxPixel), image.width >= 1, image.height >= 1 else {
            return .failure(.unreadable)
        }
        return .success(PickedPhoto(image: image))
    }

}

@MainActor final class BotPhotoPicker: NSObject, PHPickerViewControllerDelegate, UIDocumentPickerDelegate {
    enum Source { case library, file }

    /// The one pick under way (held so the system picker's delegate lives as long as the picker does).
    private static var current: BotPhotoPicker?

    private weak var host: UIViewController?
    private let completion: (FramedPhoto?) -> Void

    private init(host: UIViewController, completion: @escaping (FramedPhoto?) -> Void) {
        self.host = host
        self.completion = completion
    }

    /// The whole of it: the picker, then Move and Scale, then the 256 × 256 picture (nil when the user backed out or
    /// the file could not be used, which this says itself with an alert).
    static func pickAndFrame(from host: UIViewController, source: Source, completion: @escaping (FramedPhoto?) -> Void) {
        // A pick that never ended (its picker was taken down from outside) is over now, and so is whatever it left.
        current?.abandon()
        PickedFile.removeLeftovers()
        let picker = BotPhotoPicker(host: host, completion: completion)
        current = picker
        #if DEBUG
        if let load = DebugBotPhoto.nextLoad() {
            picker.frame(load)
            return
        }
        #endif
        switch source {
        case .library:
            var configuration = PHPickerConfiguration()
            configuration.selectionLimit = 1
            configuration.filter = .images
            configuration.preferredAssetRepresentationMode = .current
            let controller = PHPickerViewController(configuration: configuration)
            controller.delegate = picker
            host.present(controller, animated: true)
        case .file:
            let controller = UIDocumentPickerViewController(forOpeningContentTypes: [.image], asCopy: true)
            controller.allowsMultipleSelection = false
            controller.delegate = picker
            host.present(controller, animated: true)
        }
    }

    private func finish(_ photo: FramedPhoto?) {
        guard !finished else { return }
        finished = true
        loading = nil
        if Self.current === self { Self.current = nil }
        completion(photo)
    }

    /// Whether a pick is under way (tests).
    static var isPicking: Bool { current != nil }

    /// Once a run, when the app is up: files an earlier run's pick left behind go (off the main thread; a pick made
    /// from now on is newer than `before` and stays).
    static func removeLeftoversAtLaunch() {
        guard !sweptAtLaunch else { return }
        sweptAtLaunch = true
        let before = Date()
        DispatchQueue.global(qos: .utility).async { PickedFile.removeLeftovers(before: before) }
    }

    private static var sweptAtLaunch = false

    private var finished = false
    private var loading: PhotoLoad?

    /// Ends a pick nobody will answer any more: nothing is reported, its file goes.
    private func abandon() {
        finished = true
        loading?.cancel()
        loading = nil
        if Self.current === self { Self.current = nil }
    }

    /// Move and Scale goes up once `leaving` (a system picker on its way out) has gone: a cover presented while
    /// another is still leaving is dropped by UIKit.
    private func frame(_ load: PhotoLoad, after leaving: UIViewController) {
        loading = load
        if let coordinator = leaving.transitionCoordinator {
            coordinator.animate(alongsideTransition: nil) { [self] _ in frame(load) }
        } else if leaving.presentingViewController != nil, !leaving.isBeingDismissed {
            leaving.dismiss(animated: true) { [self] in frame(load) }
        } else {
            frame(load)
        }
    }

    /// Move and Scale opens at once (a spinner while the file is read); a file that can't be used closes it and says why.
    private func frame(_ load: PhotoLoad) {
        guard !finished else { return load.cancel() }
        loading = load
        guard let host else {
            load.cancel()
            return finish(nil)
        }
        let framer = PhotoFramerController(load: load) { [weak self, weak host] outcome in
            guard let self else { return }
            switch outcome {
            case .success(let photo): self.finish(photo)
            case .failure(let error):
                self.finish(nil)
                Self.explain(error, from: host)
            case nil: self.finish(nil)
            }
        }
        host.present(PhotoFramerController.wrapped(framer), animated: true)
    }

    static func explain(_ error: PhotoPickError, from host: UIViewController?) {
        AppLog.trace("botinfo", "photo pick failed: \(error)")
        guard let top = FailureAlert.topmost(host) else { return }
        Haptics.play(.error)
        let alert = UIAlertController(title: PhotoPickError.title, message: error.message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        top.present(alert, animated: true)
    }

    // MARK: Photo Library

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        // The load starts now; the framer goes up once the picker has gone.
        let load = results.first.map { PhotoLoad(provider: $0.itemProvider) }
        loading = load
        picker.dismiss(animated: true) { [self] in
            if let load { frame(load) } else { finish(nil) }
        }
    }

    // MARK: Choose File

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return finish(nil) }
        // `asCopy`: the file is a copy in this app's own space, and it is this load's to remove. It is moved in with
        // the photo picker's copies first, so one folder holds everything a pick can leave behind.
        let load = PhotoLoad(file: PickedFile.move(url) ?? url, owned: true)
        frame(load, after: controller)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(nil) }
}

#if DEBUG
/// `-HQDebugBotPhoto` and `-HQDebugBotPhotoDelay`: the pickers' stand-in for UI tests and screenshots (the system
/// pickers run in another process). The file goes through the same read as a picked one.
@MainActor enum DebugBotPhoto {
    private static var next = 0

    static func nextLoad() -> PhotoLoad? {
        let defaults = UserDefaults.standard
        let paths = (defaults.string(forKey: "HQDebugBotPhoto") ?? "").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !paths.isEmpty else { return nil }
        let path = paths[next % paths.count]
        next += 1
        let seconds = defaults.double(forKey: "HQDebugBotPhotoDelay")
        return PhotoLoad(file: URL(fileURLWithPath: path), owned: false, delay: seconds > 0 ? .milliseconds(Int(seconds * 1000)) : .zero)
    }
}
#endif
