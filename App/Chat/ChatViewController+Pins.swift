import UIKit

// [pins] Pin and Unpin from a chat (tester, 2026-10-31: "pin/favorite certain artifacts in a chat"): hold a page
// card, a picture, a file row or a file path the bot named. The pin goes to the top of Artifacts and the Pinned page,
// and stays when the chat is long gone from the recent chats Artifacts reads.

extension ChatViewController {
    /// Pin or Unpin for a file on the bot's computer that this chat shows; nil outside a gateway chat.
    func pinAction(path: String, name: String, kind: ArtifactRecord.Kind? = nil, context: MediaContext? = nil) -> UIAction? {
        guard let context = context ?? mediaContext, !path.isEmpty else { return nil }
        let pins = ArtifactPins.of(accountId: context.accountId)
        let record = PinActions.record(path: path, name: name, kind: kind, context: context, sessionId: context.storedSessionId,
                                       sessionTitle: session.title)
        return PinActions.action(pinned: pins.isPinned(record)) { [weak self] in
            PinActions.toggle(record, pins: pins, from: self)
        }
    }

    /// A held page card's menu: Open, Pin, Share…, Copy Path. Any other `#media:` link keeps the message's menu.
    func pageCardMenu(_ ref: MediaRef, url: URL) -> UIMenu? {
        guard let path = ref.attachment.gatewayPath, HTMLPageSheet.opens(name: path) else { return nil }
        let open = UIAction(title: "Open", image: UIImage(systemName: "safari")) { [weak self] _ in self?.chatCellOpen(url: url) }
        open.accessibilityIdentifier = "page.open"
        let share = UIAction(title: "Share…", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
            guard let self, let context = self.mediaContext else { return }
            FilePreviewPresenter.shared.shareFile(path: path, name: ref.attachment.name, context: context, from: self, row: nil)
        }
        let copy = UIAction(title: "Copy Path", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
            UIPasteboard.general.string = path
            Haptics.play(.success)
            MenusHUD.show("Copied", in: self?.view)
        }
        let pin = pinAction(path: path, name: ref.attachment.name, kind: .file)
        // [mac-audit] Owner 2026-11-02 (Mac audit J1): Save As… on the Mac, as a file card's.
        let save: [UIMenuElement] = !FileSaver.offered ? [] : [FileSaver.action { [weak self] in
            guard let self, let context = self.mediaContext else { return }
            FilePreviewPresenter.shared.saveFile(path: path, name: ref.attachment.name, context: context, from: self, row: nil)
        }]
        return UIMenu(title: ref.attachment.name, children: [open] + (pin.map { [$0] } ?? []) + [share] + save + [copy])
    }
}
