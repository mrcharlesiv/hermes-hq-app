import UIKit
import UniformTypeIdentifiers
import Synchronization

// The chat screen's photos and files (docs/spec/1x-attachments.md §4, §6): the + menu and its pickers, paste, the tray
// bound to this chat's draft (restored when the chat opens, kept when it closes), imports into the account's
// `AttachmentCenter`, and what Send takes. One per chat screen; the screen keeps it as `attachments`.

private extension AttachmentPrepareError {
    /// For logs only: the reason without the file name (`tooLarge` carries it).
    var logReason: String {
        switch self {
        case .tooLarge: return "too large"
        case .unreadablePhoto: return "unreadable photo"
        case .unreadableFile: return "unreadable file"
        case .locationNotRemoved: return "location not removed"
        case .cameraNotSaved: return "camera not saved"
        case .limitReached: return "limit reached"
        case .cancelled: return "cancelled"
        }
    }
}

@MainActor final class ChatAttachmentsController: AttachmentTrayDelegate {
    private weak var screen: ChatViewController?
    private let sender: ChatAttachmentSending
    let center: AttachmentCenter
    /// The chat's draft key, read each time: a chat opened before its stored id was known moves its draft to the
    /// resolved id (`LiveChatSession.ensureStoredId` → `AttachmentCenter.moveDraft`), and the tray follows it.
    var scope: String { sender.draftScope }
    let profile: String
    let plusMenu = ComposerPlusMenu()
    private let plusButton = ComposerPlusButton()
    private let tray = AttachmentTrayView()
    private let pickers = AttachmentPickerCoordinator()
    private var draftObservation: AttachmentCenter.Observation?
    private var itemObservation: AttachmentCenter.Observation?
    private var draftIds: Set<String> = []
    private var syncingText = false

    /// Builds the controller for a chat whose session can send attachments (nil otherwise: no + button).
    static func make(for screen: ChatViewController) -> ChatAttachmentsController? {
        guard let sender = screen.session as? ChatAttachmentSending,
              let live = screen.session as? LiveChatSession else { return nil }
        return ChatAttachmentsController(screen: screen, sender: sender, center: live.attachmentCenter)
    }

    private init(screen: ChatViewController, sender: ChatAttachmentSending, center: AttachmentCenter) {
        self.screen = screen
        self.sender = sender
        self.center = center
        profile = screen.session.profile
        install()
    }

    private var composer: ComposerView? { screen?.composer }

    /// [mac] Stress test 2026-10-28 #33: Chat › Attach Files… (⇧⌘A), the + menu's Files; false when the tray is full.
    @discardableResult
    func presentFiles() -> Bool {
        let remaining = AttachmentStaging.maxPerMessage - count
        guard remaining > 0 else { return false }
        pickers.presentFiles(remaining: remaining)
        return true
    }

    var canAttach: Bool { count < AttachmentStaging.maxPerMessage }

    private func install() {
        guard let composer else { return }
        pickers.presenter = screen
        pickers.onPicked = { [weak self] sources in self?.importSources(sources) }
        pickers.onError = { [weak self] reason in self?.showError(reason) }
        plusMenu.register(.pickers) { [weak self] in
            guard let self else { return [] }
            let count = self.count
            let remaining = AttachmentStaging.maxPerMessage - count
            return [ComposerPlusMenu.pickers(count: count, camera: { [weak self] in self?.pickers.presentCamera() },
                                             photos: { [weak self] in self?.pickers.presentPhotos(remaining: remaining) },
                                             files: { [weak self] in self?.pickers.presentFiles(remaining: remaining) })]
        }
        plusMenu.register(.paste) { [weak self] in
            guard let self else { return [] }
            return [ComposerPlusMenu.paste(enabled: self.count < AttachmentStaging.maxPerMessage) { [weak self] in self?.pasteFromBoard() }]
        }
        plusMenu.register(.link) { [weak self] in
            let item = UIAction(title: "Link…", image: UIImage(systemName: "link")) { [weak self] _ in self?.presentLinkDialog() }
            item.accessibilityIdentifier = "composer.plus.link"
            return [item]
        }
        plusButton.menuProvider = { [weak self] in self?.plusMenu.makeMenu() ?? UIMenu(children: []) }
        composer.leadingAccessories = [plusButton]
        tray.delegate = self
        // [glass-phone] The glass card's padding makes the tray taller off the Desktop Look: a live switch resizes it.
        tray.onLookChange = { [weak self] in self?.refreshTray(animated: false) }
        composer.topAccessory = tray
        composer.accessoryLiftBox = { [weak tray] in tray?.liftBox() }
        (composer.textView as? ComposerTextView)?.onPasteImages = { [weak self] providers in self?.paste(providers) }
        (composer.textView as? ComposerTextView)?.onPasteFiles = { [weak self] providers in self?.drop(providers) }
        // [mac] Files and pictures dragged from the Finder (or another app on the iPad) onto the chat attach.
        dropTarget.canAccept = { [weak self] in (self?.count ?? AttachmentStaging.maxPerMessage) < AttachmentStaging.maxPerMessage }
        dropTarget.onDrop = { [weak self] providers in self?.drop(providers) }
        dropTarget.host = screen?.view
        // [Mac UI check 2026-11-13] V35: the wash covers the transcript only, under the bar and above the message box,
        // which takes a drag of its own; the header's buttons and the box stay as they are.
        dropTarget.area = { [weak self] in
            guard let screen = self?.screen, let view = screen.view else { return nil }
            let top = view.safeAreaInsets.top
            let bottom = screen.composer.frame.minY
            guard bottom > top + 80 else { return nil }
            return CGRect(x: 0, y: top, width: view.bounds.width, height: bottom - top)
        }
        screen?.view.addInteraction(UIDropInteraction(delegate: dropTarget))
        composer.onTextChange = { [weak self] text in
            guard let self, !self.syncingText else { return }
            self.center.setText(text, scope: self.scope, profile: self.profile)
        }
        // The chat's saved draft comes back with it (spec §6.6).
        let draft = center.draft(scope)
        if composer.text.isEmpty, !draft.text.isEmpty {
            syncingText = true
            composer.text = draft.text
            syncingText = false
            AppLog.trace("composer", "draft restored on open \(AppLog.tag(scope: scope))")
        }
        draftObservation = center.observeDraft(scope) { [weak self] in self?.draftChanged() }
        itemObservation = center.observeItems { [weak self] id in
            guard let self, self.draftIds.contains(id) else { return }
            self.refreshTray(animated: false)
        }
        refreshTray(animated: false)
        composer.onFieldLeadingChange = { [weak self] lead in
            guard let self, lead > 0 else { return }
            self.tray.leadingInset = lead
            self.tray.layoutIfNeeded()   // inside the composer's layout pass: the tiles ride the keyboard's animation
        }
        #if DEBUG
        DebugAttach.applyIfAsked(self)
        #endif
    }

    // MARK: Link… (L390, spec §4)

    private let linkDialog = LinkDialogDelegate()

    private func presentLinkDialog() {
        guard let screen else { return }
        let alert = UIAlertController(title: "Add Link", message: LinkDialogDelegate.message, preferredStyle: .alert)
        alert.view.accessibilityIdentifier = "link.dialog"
        var attach: UIAlertAction!
        let commit: (String) -> Void = { [weak self] text in self?.attachLink(LinkText.normalised(text)) }
        alert.addTextField { field in
            field.placeholder = "https://example.com/post"
            field.keyboardType = .URL
            field.returnKeyType = .go
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.textContentType = .URL
            field.clearButtonMode = .whileEditing
            field.accessibilityIdentifier = "link.field"
        }
        attach = UIAlertAction(title: "Attach", style: .default) { [weak alert] _ in commit(alert?.textFields?.first?.text ?? "") }
        attach.isEnabled = false
        attach.accessibilityIdentifier = "link.attach"
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(attach)
        alert.preferredAction = attach
        if let field = alert.textFields?.first {
            linkDialog.bind(field: field, alert: alert, attach: attach, commit: commit)
        }
        screen.present(alert, animated: true)
    }

    /// Attach: a draft chip, no upload; the `@url:` line rides the next send (spec §4.2).
    private func attachLink(_ url: String) {
        guard LinkText.isLink(url) else { return }
        let ref = RefValue.urlRef(url)
        let id = UUID().uuidString
        // The same link twice is one chip.
        if center.draft(scope).attachments.contains(where: { $0.refText == ref }) { Haptics.play(.success); composer?.textView.becomeFirstResponder(); return }
        let draft = DraftAttachment(id: id, kind: .link, name: url, localFile: "", byteSize: 0, pixelWidth: nil, pixelHeight: nil,
                                    typeIdentifier: "public.url", upload: .uploaded(path: url, folder: ""), refText: ref)
        center.add(draft, scope: scope, profile: profile)
        Haptics.play(.success)
        composer?.textView.becomeFirstResponder()
    }

    private var count: Int { center.draft(scope).attachments.count }

    private func draftChanged() {
        // A refused or unqueued send gave its words back while the field was empty.
        let draft = center.draft(scope)
        if let composer, composer.text.isEmpty, !draft.text.isEmpty {
            syncingText = true
            composer.text = draft.text
            syncingText = false
            AppLog.trace("composer", "draft text given back \(AppLog.tag(scope: scope))")
        }
        refreshTray(animated: true)
    }

    private func refreshTray(animated: Bool) {
        guard let composer else { return }
        let attachments = center.draft(scope).attachments
        draftIds = Set(attachments.map(\.id))
        tray.leadingInset = composer.fieldLeading > 0 ? composer.fieldLeading : 26
        tray.update(attachments, staging: center.staging, animated: animated && screen?.view.window != nil)
        composer.attachmentCount = attachments.count
        composer.attachmentsPreparing = attachments.contains { $0.isPreparing }
        composer.topAccessoryHeight = attachments.isEmpty ? 0 : AttachmentTrayView.height
    }

    // MARK: Send

    /// Send takes the tray (spec §6.4 step 1): its attachments leave the draft in the same frame as the field clears.
    func takeForSend() -> [DraftAttachment] {
        let taken = center.takeForSend(scope)
        return taken.attachments
    }

    var hasAttachments: Bool { count > 0 }

    // MARK: Importing

    private func importSources(_ sources: [AttachmentPickerCoordinator.PickedSource]) {
        let remaining = AttachmentStaging.maxPerMessage - count
        var accepted = sources
        if sources.count > remaining {
            accepted = Array(sources.prefix(max(0, remaining)))
            showError(AttachmentPrepareError.limitReached.errorDescription ?? "")
        }
        for source in accepted { importOne(source) }
    }

    private func importOne(_ source: AttachmentPickerCoordinator.PickedSource) {
        let id = UUID().uuidString
        let staging = center.staging
        let placeholder: DraftAttachment
        switch source {
        case .library(_, let movie): placeholder = AttachmentImporter.placeholder(id: id, kind: movie ? .file : .image, name: movie ? "video.mov" : "photo.jpg")
        case .camera: placeholder = AttachmentImporter.placeholder(id: id, kind: .image, name: "camera.jpg")
        case .file(let url): placeholder = AttachmentImporter.placeholder(id: id, kind: .file, name: AttachmentStaging.safeName(url.lastPathComponent))
        case .pasted: placeholder = AttachmentImporter.placeholder(id: id, kind: .image, name: "clipboard.jpg")
        case .dropped(let provider):
            placeholder = AttachmentImporter.placeholder(id: id, kind: .file, name: AttachmentStaging.safeName(provider.suggestedName ?? "file"))
        }
        let center = self.center
        let task = Task { [weak self] in
            do {
                let prepared: DraftAttachment
                switch source {
                case .camera(let image):
                    prepared = try await Self.prepareDetached(.camera(image), id: id, staging: staging)
                case .file(let url):
                    prepared = try await Self.prepareDetached(.file(url, name: url.lastPathComponent), id: id, staging: staging)
                    try? FileManager.default.removeItem(at: url)       // the picker's copy
                case .library(let provider, let movie):
                    prepared = try await LibraryImport.load(provider, movie: movie, id: id, staging: staging) { fraction in
                        center.setPreparing(id, fraction: fraction)
                    }
                case .pasted(let provider):
                    prepared = try await LibraryImport.loadPasted(provider, id: id, staging: staging)
                case .dropped(let provider):
                    let copy = try await AttachmentDrop.copyOut(provider)
                    defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }   // our copy
                    prepared = try await Self.prepareDetached(.file(copy, name: copy.lastPathComponent), id: id, staging: staging)
                }
                try Task.checkCancellation()
                await Self.seedThumbnail(prepared, staging: staging)
                center.finishPreparing(prepared)
                AppLog.trace("attach", "import finished: \(prepared.kind.rawValue), \(prepared.byteSize) bytes")
            } catch is CancellationError {
                center.failPreparing(id)
            } catch {
                center.failPreparing(id)
                let known = error as? AttachmentPrepareError
                AppLog.note("attach", "import failed: \(known?.logReason ?? "\(type(of: error))")")
                // A dropped or pasted item the system wouldn't hand over (or whose copy failed) says so too, instead
                // of its placeholder just vanishing.
                let fallback: AttachmentPrepareError? = switch source {
                case .dropped: .unreadableFile
                case .pasted: .unreadablePhoto
                default: nil
                }
                if let reason = (known ?? fallback)?.errorDescription { self?.showError(reason) }
            }
        }
        center.add(placeholder, scope: scope, profile: profile, preparation: task)
    }

    nonisolated private static func prepareDetached(_ source: AttachmentImporter.Source, id: String, staging: AttachmentStaging) async throws -> DraftAttachment {
        try await Task.detached(priority: .userInitiated) { try await AttachmentImporter.prepare(source, id: id, staging: staging) }.value
    }

    /// The tray thumbnail, made once off the main thread (spec §5.2).
    private static func seedThumbnail(_ a: DraftAttachment, staging: AttachmentStaging) async {
        guard a.kind == .image else { return }
        let scale = UITraitCollection.current.displayScale
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            AttachmentImporter.thumbnail(a, staging: staging, scale: scale).map { UIImage(cgImage: $0) }
        }.value
        if let image { MediaMemoryCache.shared.set(image, key: "l|" + a.id, bucket: 256) }
    }

    /// Imports files by path (the DEBUG attach hook; the same code as the pickers).
    func importFiles(_ urls: [URL]) {
        importSources(urls.map { .file($0) })
    }

    // MARK: Paste

    private func pasteFromBoard() {
        let board = UIPasteboard.general, providers = board.itemProviders
        // [mac] A file copied in the Finder (or Files) attaches as that file, not as its icon.
        if AttachmentDrop.pastesFiles(types: providers.map(\.registeredTypeIdentifiers), hasStrings: board.hasStrings) {
            return drop(providers.filter { AttachmentDrop.attachable($0.registeredTypeIdentifiers) })
        }
        paste(providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) })
    }

    private let dropTarget = AttachmentDropTarget()

    /// Dropped or pasted files: each is copied out of its provider by its own import.
    private func drop(_ providers: [NSItemProvider]) {
        guard !providers.isEmpty else { return }
        importSources(providers.map { .dropped($0) })
        composer?.textView.becomeFirstResponder()
    }

    #if DEBUG
    /// MacShots: the drop overlay as a drag of `count` files shows it (nil: gone), and a drop of these providers.
    func debugDropOverlay(count: Int?) { dropTarget.debugOverlay(count: count) }
    func debugDrop(_ providers: [NSItemProvider]) { drop(providers) }
    #endif

    private func paste(_ providers: [NSItemProvider]) {
        guard !providers.isEmpty else { return }
        importSources(providers.map { .pasted($0) })
    }

    // MARK: Alerts

    private func showError(_ reason: String) {
        guard let screen, !reason.isEmpty else { return }
        // Over whatever the chat shows on top (a sheet), never lost: with an alert already up, or something still
        // coming or going, the chat's notice card says it instead.
        var top: UIViewController = screen
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        if let leaving = top.presentedViewController, let coordinator = leaving.transitionCoordinator {
            // A picker on its way down: the alert comes once it is gone.
            coordinator.animate(alongsideTransition: nil) { [weak self] _ in self?.showError(reason) }
            return
        }
        Haptics.play(.error)   // alert or notice, as `FailureAlert`
        guard !(top is UIAlertController), top.presentedViewController == nil, !top.isBeingPresented else {
            // A reason that already says what failed ("Couldn’t upload …") stands alone.
            screen.showNotice(reason.hasPrefix("Couldn") ? reason : "Couldn’t attach: \(reason)")
            return
        }
        let alert = UIAlertController(title: "Couldn’t Attach", message: reason, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        top.present(alert, animated: true)
    }

    // MARK: AttachmentTrayDelegate

    func trayRemove(_ id: String) {
        center.remove(id, scope: scope)
    }

    func trayRetry(_ id: String) {
        center.retry(id)
    }

    func trayOpen(_ id: String, from view: UIView) {
        guard let screen, let item = center.items[id] else { return }
        if item.kind == .image {
            let media = MediaItem(attachment: MessageAttachment(kind: .image, source: .local(draftId: id), name: item.name,
                                                                pixelWidth: item.pixelWidth, pixelHeight: item.pixelHeight),
                                  index: -1, context: sender.mediaContext, label: "Photo, \(item.name)")
            MediaViewerController.present(from: screen, items: [media], index: 0) { [weak view] _ in view }
        } else if let url = center.staging.url(for: item) {
            // [talk] Audio plays in the preview sheet (docs/spec/3x-talk.md §11, row L411); the rest goes to Quick Look.
            if AudioPreviewText.isAudio(typeIdentifier: item.typeIdentifier, name: item.name) {
                AudioPreview.present(.local(url, title: item.name, bytes: item.byteSize > 0 ? item.byteSize : nil), from: screen)
            } else {
                FilePreviewPresenter.shared.openLocal(url, from: screen, anchor: view)
            }
        }
    }
}

/// Library and pasteboard imports: the provider's file exists only inside its callback, so the read/copy happens there;
/// an iCloud download's progress reaches the tile (spec §4.2).
nonisolated enum LibraryImport {
    static func load(_ provider: NSItemProvider, movie: Bool, id: String, staging: AttachmentStaging,
                     progress: @escaping @MainActor (Double?) -> Void) async throws -> DraftAttachment {
        let box = ProgressBox()
        let copied: Result<DraftAttachment, AttachmentPrepareError> = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result<DraftAttachment, AttachmentPrepareError>, Error>) in
                let p = provider.loadFileRepresentation(for: movie ? .movie : .image, openInPlace: false) { url, _, _ in
                    guard let url else {
                        continuation.resume(returning: .failure(.unreadablePhoto))
                        return
                    }
                    do {
                        if movie {
                            let name = AttachmentStaging.safeName(url.lastPathComponent.isEmpty ? "video.mov" : url.lastPathComponent)
                            let target = try staging.copyIn(url, id: id, name: name)
                            let size = Int64((try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                            continuation.resume(returning: .success(DraftAttachment(
                                id: id, kind: .file, name: name, localFile: "\(id)/\(name)", byteSize: size, pixelWidth: nil, pixelHeight: nil,
                                typeIdentifier: UTType(filenameExtension: (name as NSString).pathExtension)?.identifier ?? UTType.movie.identifier,
                                upload: .waiting)))
                        } else {
                            // Gated: the provider callback is a GCD thread, and the file stays valid while it waits.
                            // iCloud downloads (before this callback) still run side by side; a removed tile skips the work.
                            let out = try PhotoPrepGate.run {
                                if box.isCancelled { throw AttachmentPrepareError.unreadablePhoto }
                                return try PhotoNormalizer.normalize(url, stem: "photo", into: staging.makeFolder(id))
                            }
                            continuation.resume(returning: .success(DraftAttachment(
                                id: id, kind: .image, name: out.name, localFile: "\(id)/\(out.name)", byteSize: out.byteSize,
                                pixelWidth: out.pixelWidth, pixelHeight: out.pixelHeight, typeIdentifier: out.typeIdentifier, upload: .waiting)))
                        }
                    } catch let error as AttachmentPrepareError {
                        staging.remove(id)
                        continuation.resume(returning: .failure(error))
                    } catch {
                        staging.remove(id)
                        continuation.resume(returning: .failure(.unreadablePhoto))
                    }
                }
                box.set(p)
                box.observe { fraction in Task { @MainActor in progress(fraction) } }
            }
        } onCancel: {
            box.cancel()
        }
        switch copied {
        case .failure(let error):
            throw error
        case .success(let attachment):
            guard movie else { return attachment }
            // A library video leaves without its location (spec §5.3).
            guard let url = staging.url(for: attachment) else { throw AttachmentPrepareError.unreadablePhoto }
            do {
                try await VideoSanitizer.removeLocation(fromMovieAt: url)
            } catch {
                staging.remove(id)
                throw AttachmentPrepareError.locationNotRemoved
            }
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            guard size <= AttachmentStaging.maxItemBytes else {
                staging.remove(id)
                throw AttachmentPrepareError.tooLarge(name: attachment.name)
            }
            var done = attachment
            done.byteSize = size
            return done
        }
    }

    /// A pasted image: its data, normalised as `clipboard.jpg|png` (spec §4.5).
    static func loadPasted(_ provider: NSItemProvider, id: String, staging: AttachmentStaging) async throws -> DraftAttachment {
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(for: .image) { data, _ in
                if let data { continuation.resume(returning: data) } else { continuation.resume(throwing: AttachmentPrepareError.unreadablePhoto) }
            }
        }
        // [perf] Off the main actor (this ran there: a nonisolated async func takes its caller's actor), on a GCD
        // thread so the gate's wait never blocks the concurrency pool.
        let result: Result<DraftAttachment, AttachmentPrepareError> = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: pastedImage(data, id: id, staging: staging))
            }
        }
        return try result.get()
    }

    private static func pastedImage(_ data: Data, id: String, staging: AttachmentStaging) -> Result<DraftAttachment, AttachmentPrepareError> {
        #if DEBUG
        debugPasteOnMain.withLock { $0 = Thread.isMainThread }
        #endif
        let temp = FileManager.default.temporaryDirectory.appending(path: "HQNPaste-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            try data.write(to: temp)
            let folder = try staging.makeFolder(id)
            let out = try PhotoPrepGate.run { try PhotoNormalizer.normalize(temp, stem: "clipboard", into: folder) }
            return .success(DraftAttachment(id: id, kind: .image, name: out.name, localFile: "\(id)/\(out.name)", byteSize: out.byteSize,
                                            pixelWidth: out.pixelWidth, pixelHeight: out.pixelHeight, typeIdentifier: out.typeIdentifier,
                                            upload: .waiting))
        } catch {
            staging.remove(id)
            return .failure((error as? AttachmentPrepareError) ?? .unreadablePhoto)
        }
    }

    #if DEBUG
    /// Tests: whether the last pasted image was written and normalised on the main thread.
    static let debugPasteOnMain = Mutex<Bool?>(nil)
    #endif

    /// Holds a provider's `Progress` (cancel on removal; fraction to the tile).
    final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var progress: Progress?
        private var observation: NSKeyValueObservation?
        private var cancelled = false

        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

        func set(_ p: Progress) { lock.lock(); progress = p; lock.unlock() }

        func observe(_ report: @escaping @Sendable (Double?) -> Void) {
            lock.lock(); defer { lock.unlock() }
            observation = progress?.observe(\.fractionCompleted, options: [.new]) { p, _ in
                report(p.fractionCompleted > 0 && p.fractionCompleted < 1 ? p.fractionCompleted : nil)
            }
        }

        func cancel() {
            lock.lock(); let p = progress; cancelled = true; lock.unlock()
            p?.cancel()
        }
    }
}

#if DEBUG
/// `-HQDebugAttach "<abs path>,<abs path>"`: attaches those files once the chat opens, through the pickers' own import
/// code (images go the photo path, others as files). Once per launch. UI tests and screenshots only.
@MainActor enum DebugAttach {
    private static var used = false

    static func applyIfAsked(_ controller: ChatAttachmentsController) {
        guard !used, let raw = UserDefaults.standard.string(forKey: "HQDebugAttach"), !raw.isEmpty else { return }
        used = true
        let delay = UserDefaults.standard.double(forKey: "HQDebugAttachDelay")
        let urls = raw.split(separator: ",").map { URL(fileURLWithPath: String($0).trimmingCharacters(in: .whitespaces)) }
        DispatchQueue.main.asyncAfter(deadline: .now() + (delay > 0 ? delay : 0.8)) { [weak controller] in
            // The pickers hand over copies; so does this (the import deletes the copy it was given).
            let copies = urls.compactMap { url -> URL? in
                let folder = FileManager.default.temporaryDirectory.appending(path: "HQNDebugAttach-" + UUID().uuidString, directoryHint: .isDirectory)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let copy = folder.appending(path: url.lastPathComponent)
                return (try? FileManager.default.copyItem(at: url, to: copy)) != nil ? copy : nil
            }
            controller?.importFiles(copies)
        }
    }
}
#endif


/// The Link… alert's field: Attach follows whether the text is a link; Return (Go) attaches a link and does nothing
/// for anything else; a hint replaces the message while the text is not a link.
@MainActor final class LinkDialogDelegate: NSObject, UITextFieldDelegate {
    static let message = "The page is fetched and included with your next message."
    static let hint = "Include the full URL, e.g. https://…"
    private weak var alert: UIAlertController?
    private weak var attach: UIAlertAction?
    private var commit: ((String) -> Void)?

    func bind(field: UITextField, alert: UIAlertController, attach: UIAlertAction, commit: @escaping (String) -> Void) {
        self.alert = alert
        self.attach = attach
        self.commit = commit
        field.delegate = self
        field.addTarget(self, action: #selector(changed(_:)), for: .editingChanged)
    }

    @objc private func changed(_ field: UITextField) {
        let text = field.text ?? ""
        let ok = LinkText.isLink(LinkText.normalised(text))
        attach?.isEnabled = ok
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        alert?.message = (ok || empty) ? Self.message : Self.hint
    }

    func textFieldShouldReturn(_ field: UITextField) -> Bool {
        let text = field.text ?? ""
        guard LinkText.isLink(LinkText.normalised(text)) else { return false }
        let commit = self.commit
        alert?.dismiss(animated: true) { commit?(text) }
        return false
    }
}
