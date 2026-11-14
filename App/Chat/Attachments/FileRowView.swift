import UIKit

// One file in a bubble or a reply (docs/spec/1x-attachments.md §7.3, §10): a 40 pt circle with the kind's glyph
// (white 22 % in your bubble, tint 15 % in a bot's), the name (up to 2 lines, middle-truncated) and a detail line
// ("PDF · 2.4 MB", "Downloading… 40 %", "Cancelled", "Uploading… 40 %"), 12 pt above and below (owner: wrapping rows
// get real padding). A tap opens it (download, then Quick Look); a second tap while it downloads cancels.

@MainActor protocol FileRowHost: AnyObject {
    func fileRowTapped(_ row: FileRowView)
    func fileRowMenu(_ row: FileRowView) -> UIMenu?
}

final class FileRowView: UIControl {
    weak var host: FileRowHost?
    private(set) var item: FileItem?
    private(set) var layout: FileRowLayout?

    private let circle = UIView()
    private let glyph = UIImageView()
    private let name = UILabel()
    private let detail = UILabel()
    private var progressToken: TransferProgressCenter.Token?
    private var downloadToken: TransferProgressCenter.Token?
    private var itemObservation: AttachmentCenter.Observation?
    private var resetWork: DispatchWorkItem?
    /// "Downloading… 40 %" (set by the preview presenter) or "Cancelled".
    private var override: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        circle.isUserInteractionEnabled = false
        circle.layer.cornerCurve = .continuous
        addSubview(circle)
        glyph.contentMode = .center
        glyph.isUserInteractionEnabled = false
        addSubview(glyph)
        name.numberOfLines = 2
        name.lineBreakMode = .byTruncatingMiddle
        name.isUserInteractionEnabled = false
        addSubview(name)
        detail.numberOfLines = 1
        detail.lineBreakMode = .byTruncatingTail
        detail.isUserInteractionEnabled = false
        addSubview(detail)
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
        PointerEffects.surface(self, radius: 8)   // [mac] Feel list B: lit under the pointer, deeper while pressed
        isContextMenuInteractionEnabled = true
        isAccessibilityElement = true
        accessibilityTraits = .button
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (view: FileRowView, _) in view.recolor() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isHighlighted: Bool {
        didSet { UIView.animate(withDuration: isHighlighted ? 0 : 0.15) { /* motion-ok: opacity only */ self.alpha = PointerEffects.dim(self.isHighlighted, to: 0.55) } }
    }

    func configure(_ row: FileRowLayout, style: ChatStyle, frame: CGRect) {
        self.frame = frame
        let changed = item?.attachment != row.item.attachment
        item = row.item
        layout = row
        if changed { override = nil; resetWork?.cancel() }
        circle.frame = row.circle
        circle.layer.cornerRadius = row.circle.height / 2
        glyph.frame = row.circle
        let linkRow = row.item.attachment.kind == .link
        let kind: MediaKinds.Kind = row.item.attachment.kind == .folder ? .folder : MediaKinds.kind(ofName: row.item.attachment.name)
        glyph.image = UIImage(systemName: linkRow ? "link" : MediaKinds.glyph(kind), withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium))
        name.font = MediaLayout.nameFont(style)
        name.text = row.item.attachment.name
        name.numberOfLines = row.nameLines
        name.frame = row.name
        detail.font = MediaLayout.detailFont(style)
        detail.frame = row.detail
        isEnabled = row.item.attachment.kind != .folder
        recolor()
        observeUpload(row.item)
        observeDownload(row.item, changed: changed)
        refreshDetail()
        accessibilityIdentifier = nil
    }

    func prepareForReuse() {
        progressToken = nil
        downloadToken = nil
        itemObservation = nil
        resetWork?.cancel()
        override = nil
        item = nil
    }

    private func recolor() {
        guard let layout else { return }
        if layout.mine {
            circle.backgroundColor = UIColor(white: 1, alpha: 0.22)
            glyph.tintColor = .white
            name.textColor = ChatPalette.meText
            detail.textColor = ChatPalette.meTime
        } else {
            circle.backgroundColor = ChatPalette.tint.withAlphaComponent(0.15)
            glyph.tintColor = ChatPalette.tintText
            name.textColor = ChatPalette.label
            detail.textColor = ChatPalette.label2
        }
    }

    private var baseDetail: String { item?.detail ?? "" }

    private func refreshDetail() {
        let text = override ?? baseDetail
        detail.text = text
        guard let item else { return }
        let link = item.attachment.kind == .link
        let kind = link ? "Link" : (item.attachment.kind == .folder ? "Folder" : "File")
        accessibilityLabel = link ? "Link, \(item.attachment.gatewayPath ?? item.attachment.name)" : "\(kind), \(item.attachment.name), \(text)"
        accessibilityHint = link ? "Opens the page" : (item.attachment.kind == .folder ? nil : "Opens the file")
    }

    // MARK: Download / upload words

    /// "Downloading… 40 %" while a preview downloads (nil fraction ends it).
    func showDownload(_ fraction: Double?) {
        resetWork?.cancel()
        override = fraction.map { "Downloading… \(Int($0 * 100)) %" }
        refreshDetail()
    }

    /// "Cancelled" for 1.5 s, then the normal detail.
    func showCancelled() {
        override = "Cancelled"
        refreshDetail()
        let work = DispatchWorkItem { [weak self] in
            self?.override = nil
            self?.refreshDetail()
        }
        resetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    var isDownloading: Bool { override?.hasPrefix("Downloading") == true }

    private func observeUpload(_ item: FileItem) {
        guard case .local(let draftId) = item.attachment.source, let context = item.context,
              let center = AttachmentCenter.existing(context.accountId) else {
            progressToken = nil
            itemObservation = nil
            return
        }
        let update: () -> Void = { [weak self, weak center] in
            guard let self, let center else { return }
            switch center.items[draftId]?.upload {
            case .uploading?:
                let f = TransferProgressCenter.shared.fraction(draftId) ?? 0
                self.override = "Uploading… \(Int(f * 100)) %"
            case .waiting?:
                // Not started yet: offline, or behind another upload (spec §6.3 one at a time); no "0 %" that never moves.
                self.override = "Waiting to upload"
            default:
                if self.override.map({ $0.hasPrefix("Uploading") || $0 == "Waiting to upload" }) == true { self.override = nil }
            }
            self.refreshDetail()
        }
        itemObservation = center.observeItems { id in if id == draftId { update() } }
        progressToken = TransferProgressCenter.shared.observe(draftId) { _ in update() }
        update()
    }

    /// A preview download of this file (keyed by its gateway path) shows here whichever row draws the file now, so a
    /// row reused for another file never shows this one's progress, and scrolling back finds it again.
    private func observeDownload(_ item: FileItem, changed: Bool) {
        guard let path = item.attachment.gatewayPath else { downloadToken = nil; return }
        guard changed || downloadToken == nil else { return }
        downloadToken = TransferProgressCenter.shared.observe(FilePreviewPresenter.progressKey(path)) { [weak self] fraction in
            guard let self, self.item?.attachment.gatewayPath == path else { return }
            if let fraction {
                self.showDownload(fraction)
            } else if self.isDownloading {
                self.showDownload(nil)
            }
        }
    }

    @objc private func tapped() { host?.fileRowTapped(self) }

    // MARK: Menu

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let menu = host?.fileRowMenu(self) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
    }
}
