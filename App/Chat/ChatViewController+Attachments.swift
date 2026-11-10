import UIKit
import UniformTypeIdentifiers

// The chat screen's side of photos and files (docs/spec/1x-attachments.md §7–§10): opening the viewer and file
// previews from cells, long-press menus, `#media:` links in replies, and writing learnt image sizes back to the session.

extension ChatViewController: ChatMediaCellDelegate {
    var mediaContext: MediaContext? {
        #if DEBUG
        if let demo = ChatDemo.pageContext { return demo }
        #endif
        return (session as? ChatAttachmentSending)?.mediaContext
    }

    func chatCellOpenMedia(messageId: String, items: [MediaItem], index: Int, source: @escaping (Int) -> UIView?) {
        MediaViewerController.present(from: self, items: items, index: index, source: source)
    }

    func chatCellOpenMediaAsFile(messageId: String, item: MediaItem) {
        guard let context = item.context ?? mediaContext, let path = item.attachment.gatewayPath else { return }
        FilePreviewPresenter.shared.open(path: path, name: item.attachment.name, context: context, from: self, row: nil)
    }

    func chatCellOpenFile(messageId: String, row: FileRowView) {
        guard let item = row.item, item.attachment.kind != .folder else { return }
        if item.attachment.kind == .link {
            if let text = item.attachment.gatewayPath, let url = URL(string: text) { LinkOpener.open(url, from: self) }
            return
        }
        // Your just-sent file: its phone copy, while it still has one.
        if case .local(let draftId) = item.attachment.source, let center = attachments?.center, let draft = center.items[draftId],
           let url = center.staging.url(for: draft), FileManager.default.fileExists(atPath: url.path) {
            FilePreviewPresenter.shared.openLocal(url, from: self, anchor: row)
            return
        }
        guard let context = item.context ?? mediaContext, let path = item.attachment.gatewayPath else { return }
        FilePreviewPresenter.shared.open(path: path, name: item.attachment.name, context: context, from: self, row: row)
    }

    func chatCellMediaMenu(messageId: String, item: MediaItem, tile: MediaTileView) -> UIMenu? {
        let menu = MediaActions.menu(for: item, from: self, anchor: tile)
        // [pins] A picture on the bot's computer can be pinned to Artifacts.
        guard let path = item.attachment.gatewayPath,
              let pin = pinAction(path: path, name: item.attachment.name, kind: .image, context: item.context) else { return menu }
        return UIMenu(children: menu.children + [UIMenu(options: .displayInline, children: [pin])])
    }

    func chatCellFileMenu(messageId: String, row: FileRowView) -> UIMenu? {
        guard let item = row.item else { return nil }
        let copyPath = UIAction(title: "Copy Path", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
            UIPasteboard.general.string = item.attachment.gatewayPath ?? item.attachment.name
            Haptics.play(.success)
            MenusHUD.show("Copied", in: self?.view)
        }
        if item.attachment.kind == .folder { return UIMenu(children: [copyPath]) }
        // [pins] A file or link on the bot's side can be pinned to Artifacts (not your own just-sent file's phone copy).
        let pin: UIAction? = {
            guard let path = item.attachment.gatewayPath else { return nil }
            if case .local = item.attachment.source { return nil }
            return pinAction(path: path, name: item.attachment.name, kind: item.attachment.kind == .link ? .link : nil, context: item.context)
        }()
        if item.attachment.kind == .link {
            let copy = UIAction(title: "Copy Link", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                UIPasteboard.general.string = item.attachment.gatewayPath ?? item.attachment.name
                Haptics.play(.success)
                MenusHUD.show("Copied", in: self?.view)
            }
            return UIMenu(children: [copy] + (pin.map { [$0] } ?? []))
        }
        let open = UIAction(title: "Open", image: UIImage(systemName: "eye")) { [weak self, weak row] _ in
            guard let self, let row else { return }
            self.chatCellOpenFile(messageId: messageId, row: row)
        }
        let share = UIAction(title: "Share…", image: UIImage(systemName: "square.and.arrow.up")) { [weak self, weak row] _ in
            guard let self, let context = item.context ?? self.mediaContext, let path = item.attachment.gatewayPath else { return }
            // The same download as Open: the row shows its progress and a second tap cancels it.
            FilePreviewPresenter.shared.shareFile(path: path, name: item.attachment.name, context: context, from: self, row: row)
        }
        // [mac-audit] Owner 2026-11-02 (Mac audit J1): Save As… on the Mac, the same download as Share… (your just-sent
        // file's own copy while it has one).
        let save: [UIMenuElement] = !FileSaver.offered ? [] : [FileSaver.action { [weak self, weak row] in
            guard let self else { return }
            if case .local(let draftId) = item.attachment.source, let center = self.attachments?.center, let draft = center.items[draftId],
               let url = center.staging.url(for: draft), FileManager.default.fileExists(atPath: url.path) {
                FileSaver.present(url, from: self)
                return
            }
            guard let context = item.context ?? self.mediaContext, let path = item.attachment.gatewayPath else { return }
            FilePreviewPresenter.shared.saveFile(path: path, name: item.attachment.name, context: context, from: self, row: row)
        }]
        return UIMenu(children: [open] + (pin.map { [$0] } ?? []) + [share] + save + [copyPath])
    }

    /// [mac] Stress test 2026-10-28 #19: a file row dragged out of the chat (to the Finder, Mail, another app): your
    /// just-sent file's own copy while it has one, else the gateway file, downloaded when the drop asks for it (the
    /// cache first, as Open does). Nil for folders and links.
    func chatCellFileDragProvider(messageId: String, row: FileRowView) -> NSItemProvider? {
        guard let item = row.item, item.attachment.kind != .folder, item.attachment.kind != .link else { return nil }
        if case .local(let draftId) = item.attachment.source, let center = attachments?.center, let draft = center.items[draftId],
           let url = center.staging.url(for: draft), FileManager.default.fileExists(atPath: url.path) {
            let provider = NSItemProvider(contentsOf: url)
            provider?.suggestedName = item.attachment.name
            return provider
        }
        guard let context = item.context ?? mediaContext, let path = item.attachment.gatewayPath else { return nil }
        let name = item.attachment.name
        let uti = UTType(filenameExtension: (name as NSString).pathExtension)?.identifier ?? UTType.data.identifier
        let provider = NSItemProvider()
        provider.suggestedName = name
        provider.registerFileRepresentation(forTypeIdentifier: uti, fileOptions: [], visibility: .all) { done in
            let progress = Progress(totalUnitCount: 1)
            Task { @MainActor in
                do {
                    let url = try await MediaLoader.shared.file(path: path, name: name, context: context,
                                                                progressKey: FilePreviewPresenter.progressKey(path))
                    done(url, false, nil)
                } catch {
                    AppLog.note("chatui", "file drag: download failed (\(type(of: error)))")
                    done(nil, false, error)
                }
                progress.completedUnitCount = 1
            }
            return progress
        }
        AppLog.trace("chatui", "file drag started")
        return provider
    }

    func chatCellLearnedMediaSize(messageId: String, index: Int, width: Int, height: Int) {
        (session as? ChatAttachmentSending)?.noteMediaSize(messageId: messageId, index: index, width: width, height: height)
    }

    func chatCellLearnedReplyMediaSize(messageId: String, key: String, width: Int, height: Int) {
        (session as? ChatAttachmentSending)?.noteReplyMediaSize(messageId: messageId, key: key, width: width, height: height)
    }

    func chatCellMediaUnavailable(messageId: String, path: String, reason: String) {
        (session as? ChatAttachmentSending)?.noteMediaUnavailable(messageId: messageId, path: path, reason: reason)
    }

    /// A tapped `#media:` link (a reply's inline media, spec §7.5): photos open the viewer, everything else the file
    /// preview. False when the link isn't media.
    func openMediaLink(_ url: URL) -> Bool {
        guard let ref = MarkdownMedia.ref(fromLink: url) else { return false }
        let context = mediaContext
        if ref.kind == .image {
            let item = MediaItem(attachment: ref.attachment, index: -1, context: context, label: ref.label)
            MediaViewerController.present(from: self, items: [item], index: 0) { _ in nil }
        } else if let context, let path = ref.attachment.gatewayPath {
            FilePreviewPresenter.shared.open(path: path, name: ref.attachment.name, context: context, from: self, row: nil)
        }
        return true
    }

    /// A path a bot names in its reply (`FileLinks`): Files opens at it, the file on top of its folder. A photo,
    /// PDF or other file that isn't text opens in Quick Look, as a file row does. False when the link isn't a file.
    func openFileLink(_ url: URL) -> Bool {
        guard let path = FileLinks.path(fromLink: url) else { return false }
        view.endEditing(true)
        let name = FileLinks.place(path).name ?? ""
        if WorkspacePage.opensElsewhere(name) || !(session is ChatSessionMoreActions), let context = mediaContext, !name.isEmpty {
            FilePreviewPresenter.shared.open(path: path, name: name, context: context, from: self, row: nil)
        } else if let actions = session as? ChatSessionMoreActions {
            let sheet = WorkspacePage.make(path: path, workspace: actions.workspace, media: mediaContext)
            MenusSheet.top(self)?.present(sheet, animated: true)
        }
        return true
    }
}
