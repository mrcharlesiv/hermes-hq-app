import UIKit

/// How a queued message with attachments reads on the queue card (docs/spec/1x-attachments.md §6.4 step 1).
enum QueuedAttachmentSummary {
    static func words(_ attachments: [DraftAttachment]) -> String {
        let photos = attachments.filter { $0.kind == .image }.count
        if attachments.count == 1 { return photos == 1 ? "Photo" : (attachments[0].kind == .link ? LinkText.display(attachments[0].name) : attachments[0].name) }
        if photos == attachments.count { return "\(photos) Photos" }
        return "\(attachments.count) Attachments"
    }

    /// A 28 pt thumbnail of the first photo (from the tray's cache).
    static func thumbnail(_ attachments: [DraftAttachment]) -> UIView? {
        guard let first = attachments.first(where: { $0.kind == .image }),
              let image = MediaMemoryCache.shared.image("l|" + first.id, bucket: 256) else { return nil }
        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.layer.cornerRadius = 6
        view.layer.cornerCurve = .continuous
        view.widthAnchor.constraint(equalToConstant: 28).isActive = true
        view.heightAnchor.constraint(equalToConstant: 28).isActive = true
        view.isAccessibilityElement = false
        return view
    }
}
