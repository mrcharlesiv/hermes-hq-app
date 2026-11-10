// [mac] Drag and drop and Finder paste into a chat (docs/spec/1x-attachments.md §4.5). On a Mac people drag a
// screenshot or a PDF from the Finder onto the chat window, or copy a file and press ⌘V in the message field (which
// pasted the file's name as text). Both reach the same import as the + menu's Files: the provider's file is copied
// to a folder of our own (the original is never touched), then imported and that copy removed. A drag of plain text
// or a link is left to the message field, and a drag from inside the app (a bot row, a message's photo) is not taken.
// While files are over the chat, a "Drop to Attach" card says so (`AttachmentDropOverlay`).

import UIKit
import UniformTypeIdentifiers

nonisolated enum AttachmentDrop {
    /// The type to copy a provider's file out as: a file URL (the Finder), else the first data type that is not a link
    /// (a picture, a PDF, a file from Files). Nil: nothing to attach. [mac] A file dragged in from the Finder reaches
    /// a Catalyst app as its own content type alone, not a file URL (a .txt as `public.plain-text`, a .html as
    /// `public.html`): text types count as a file unless the provider is a text snippet (`isSnippet`).
    static func fileType(_ types: [String]) -> String? {
        if types.contains(UTType.fileURL.identifier) { return UTType.fileURL.identifier }
        let snippet = isSnippet(types)
        return types.first { identifier in
            guard let type = UTType(identifier) else { return false }
            return (type.conforms(to: .data) || type.conforms(to: .package))
                && !type.conforms(to: .url) && !(snippet && type.conforms(to: .text))
        }
    }

    /// Text dragged or copied from a selection: it always carries a plain-text flavour of its own (UTF-8 or UTF-16),
    /// which a file's provider never does (a dragged .txt is `public.plain-text` alone).
    static func isSnippet(_ types: [String]) -> Bool {
        types.contains { snippetTypes.contains($0) }
    }

    private static let snippetTypes: Set<String> = [UTType.utf8PlainText.identifier, UTType.utf16PlainText.identifier,
                                                    UTType.utf16ExternalPlainText.identifier]

    /// A file to attach rather than text or a picture for the message field: a file URL, or a file's own type that is
    /// not a picture (`fileType`).
    static func isFile(_ types: [String]) -> Bool {
        if types.contains(UTType.fileURL.identifier) { return true }
        guard let type = fileType(types).flatMap({ UTType($0) }) else { return false }
        return !type.conforms(to: .image)
    }

    static func attachable(_ types: [String]) -> Bool { fileType(types) != nil }

    /// The pasteboard holds files to attach: a file URL (a Finder copy also carries the name as text and the icon as a
    /// picture), or files with no text at all (a copy in Files).
    static func pastesFiles(types: [[String]], hasStrings: Bool) -> Bool {
        if types.contains(where: { $0.contains(UTType.fileURL.identifier) }) { return true }
        return !hasStrings && types.contains { list in
            attachable(list) && !list.contains { UTType($0)?.conforms(to: .image) == true }
        }
    }

    /// A copy of the provider's file in a folder of its own under the temporary directory; the caller removes the folder.
    static func copyOut(_ provider: NSItemProvider) async throws -> URL {
        guard let type = fileType(provider.registeredTypeIdentifiers) else { throw AttachmentPrepareError.unreadableFile }
        let folder = FileManager.default.temporaryDirectory.appending(path: "HQNDrop-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if type == UTType.fileURL.identifier {
            if let url = try? await loadURL(provider), let copy = try? copy(url, into: folder, name: url.lastPathComponent) { return copy }
            // No access to the file itself: its contents, when the provider has them as a type of their own.
            let others = provider.registeredTypeIdentifiers.filter { $0 != UTType.fileURL.identifier }
            guard let content = fileType(others) else { throw AttachmentPrepareError.unreadableFile }
            return try await loadFile(provider, type: content, into: folder)
        }
        return try await loadFile(provider, type: type, into: folder)
    }

    private static func loadURL(_ provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                if let url, url.isFileURL { continuation.resume(returning: url) }
                else { continuation.resume(throwing: error ?? AttachmentPrepareError.unreadableFile) }
            }
        }
    }

    private static func loadFile(_ provider: NSItemProvider, type: String, into folder: URL) async throws -> URL {
        let suggested = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                guard let url else { continuation.resume(throwing: error ?? AttachmentPrepareError.unreadableFile); return }
                // The provider's file lasts only for this callback.
                continuation.resume(with: Result { try copy(url, into: folder, name: name(suggested, file: url, type: type)) })
            }
        }
    }

    /// The suggested name with the type's extension when it has none ("Screenshot" → "Screenshot.png").
    static func name(_ suggested: String?, file: URL, type: String) -> String {
        guard let suggested, !suggested.isEmpty else { return file.lastPathComponent }
        guard (suggested as NSString).pathExtension.isEmpty else { return suggested }
        let ext = file.pathExtension.isEmpty ? UTType(type)?.preferredFilenameExtension : file.pathExtension
        return ext.map { suggested + "." + $0 } ?? suggested
    }

    private static func copy(_ url: URL, into folder: URL, name: String) throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
            throw AttachmentPrepareError.unreadableFile   // a folder is not a file to attach
        }
        let target = folder.appending(path: AttachmentStaging.safeName(name.isEmpty ? "file" : name))
        try FileManager.default.copyItem(at: url, to: target)
        return target
    }
}

/// The chat view's drop target: files and pictures from outside the app, while the tray has room. While such a drag is
/// over the chat, `AttachmentDropOverlay` says what letting go does (a tester 2026-11-07 asked for drag and drop:
/// nothing showed it was there).
@MainActor final class AttachmentDropTarget: NSObject, UIDropInteractionDelegate {
    var canAccept: () -> Bool = { true }
    var onDrop: ([NSItemProvider]) -> Void = { _ in }
    /// The view the overlay covers (the chat screen's).
    weak var host: UIView?
    private var overlay: AttachmentDropOverlay?

    private func providers(_ session: UIDropSession) -> [NSItemProvider] {
        guard session.localDragSession == nil else { return [] }
        return session.items.map(\.itemProvider).filter { AttachmentDrop.attachable($0.registeredTypeIdentifiers) }
    }

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        let count = providers(session).count
        if count > 0 {
            AppLog.trace("attach", "drop over chat: \(count) of \(session.items.count) attach (\(session.items.map(\.itemProvider.registeredTypeIdentifiers)))")
        }
        return count > 0
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        let count = providers(session).count
        showOverlay(count: count)
        return UIDropProposal(operation: canAccept() && count > 0 ? .copy : .forbidden)
    }

    // Over the message field the field takes the drag (`ComposerTextView.paste(itemProviders:)` attaches a file).
    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) { hideOverlay() }
    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) { hideOverlay() }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        hideOverlay()
        let dropped = providers(session)
        AppLog.note("attach", "drop: \(dropped.count) of \(session.items.count)")
        onDrop(dropped)
    }

    // MARK: Overlay

    private func showOverlay(count: Int) {
        guard let host, count > 0 else { return hideOverlay() }
        let shown = overlay ?? AttachmentDropOverlay()
        if shown.superview !== host {
            shown.frame = host.bounds
            shown.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            host.addSubview(shown)
            shown.alpha = 0
            UIView.animate(withDuration: 0.15) { shown.alpha = 1 }   // motion-ok: opacity only
            overlay = shown
        }
        host.bringSubviewToFront(shown)
        shown.update(count: count, full: !canAccept())
    }

    private func hideOverlay() {
        guard let shown = overlay else { return }
        overlay = nil
        UIView.animate(withDuration: 0.15, animations: { shown.alpha = 0 }, completion: { _ in shown.removeFromSuperview() })   // motion-ok: opacity only
    }

    #if DEBUG
    /// MacShots: the overlay as a drag of `count` files shows it (nil: gone).
    func debugOverlay(count: Int?) {
        if let count { showOverlay(count: count) } else { overlay?.removeFromSuperview(); overlay = nil }
    }
    #endif
}

/// [mac] What a drag of files over the chat shows: the chat dimmed inside a dashed tinted outline and, in the middle, a
/// glass card "Drop to Attach" with the number of files (or, with the tray full, that no more fit). Touches pass through.
final class AttachmentDropOverlay: UIView {
    private let outline = CAShapeLayer()
    private let card = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let icon = UIImageView()
    private let title = UILabel()
    private let detail = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityIdentifier = "chat.dropOverlay"
        backgroundColor = UIColor.systemBackground.withAlphaComponent(0.55)
        outline.lineWidth = 2
        outline.lineDashPattern = [8, 6]
        layer.addSublayer(outline)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (self: Self, _: UITraitCollection) in self.apply() }

        card.cornerConfiguration = .corners(radius: .fixed(22))
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 30, weight: .medium)
        title.font = HQFont.preferred(.headline)
        title.textAlignment = .center
        detail.font = HQFont.preferred(.subheadline)
        detail.textColor = HQPalette.label2
        detail.textAlignment = .center
        detail.numberOfLines = 0
        let stack = UIStackView(arrangedSubviews: [icon, title, detail])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(stack)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.contentView.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor, constant: -28),
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
            card.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = bounds.insetBy(dx: 10, dy: 10)
        outline.path = UIBezierPath(roundedRect: inset, cornerRadius: 18).cgPath
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        apply()
    }

    private var count = 0, full = false

    func update(count: Int, full: Bool) {
        guard count != self.count || full != self.full || title.text == nil else { return }
        self.count = count
        self.full = full
        apply()
    }

    private func apply() {
        let color = (full ? HQPalette.label2 : tintColor!).resolvedColor(with: traitCollection)
        outline.strokeColor = color.cgColor
        outline.fillColor = color.withAlphaComponent(0.06).cgColor
        icon.image = UIImage(systemName: full ? "nosign" : "paperclip")
        icon.tintColor = color
        title.text = full ? "No Room for More Files" : "Drop to Attach"
        detail.text = full ? "A message takes up to \(AttachmentStaging.maxPerMessage) files."
                           : count == 1 ? "1 file" : "\(count) files"
        accessibilityLabel = [title.text, detail.text].compactMap { $0 }.joined(separator: ", ")
    }
}
