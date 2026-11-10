// [transcript] A link chip (docs/spec/3x-transcript.md §3.7; rows L312, L313, L1007): a bare web address alone on its
// own paragraph of a reply gets a card under it with the site's icon, the page's title and the host. Its height is
// fixed from the start, so a title or icon that arrives later never moves the transcript. The title and icon come
// from one bounded, cookieless https read made from the phone (`LinkPreviews`), only for chips that are on screen.

import UIKit

final class LinkChipView: UIControl {
    nonisolated static let iconSize: CGFloat = 16
    nonisolated static let padH: CGFloat = 12
    nonisolated static let padV: CGFloat = 10

    nonisolated static func height(style: ChatStyle) -> CGFloat {
        padV + style.bodyLineHeight + 2 + style.timeLineHeight + padV
    }

    /// [ui-sizing 2026-11-09] At most 300 pt × UI Scale (iPhone and iPad), as its title grows: at 150 % a fixed 300 showed
    /// about 15 characters.
    nonisolated static func width(maxText: CGFloat) -> CGFloat { min(maxText, 300 * HQFont.glyphScale) }

    var onOpen: ((URL) -> Void)?
    private(set) var url: URL?
    private let icon = UIImageView()
    private let titleLabel = UILabel()
    private let hostLabel = UILabel()
    private var load: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        icon.contentMode = .scaleAspectFit
        icon.layer.cornerRadius = 4
        icon.layer.cornerCurve = .continuous
        icon.clipsToBounds = true
        icon.tintColor = ChatPalette.label2
        titleLabel.textColor = ChatPalette.label
        titleLabel.lineBreakMode = .byTruncatingTail
        hostLabel.textColor = ChatPalette.label2
        hostLabel.lineBreakMode = .byTruncatingMiddle
        for view in [icon, titleLabel, hostLabel] as [UIView] { view.isUserInteractionEnabled = false; addSubview(view) }
        isAccessibilityElement = true
        accessibilityTraits = .link
        accessibilityIdentifier = "chat.link-chip"
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.6 : 1 } }

    func configure(_ url: URL, style: ChatStyle) {
        titleLabel.font = style.body
        hostLabel.font = style.time
        let raw = url.absoluteString
        if self.url != url {
            self.url = url
            load?.cancel()
            // Before any read: where it goes, in words (host and path; "…" for a query it leaves out).
            hostLabel.text = LinkPreviewParsing.displayHost(url)
            show(title: LinkPreviewParsing.bareLinkLabel(title: nil, target: raw), icon: nil)
            load = Task { [weak self] in
                #if DEBUG
                await LinkChipStub.installIfAsked()
                #endif
                let preview = await LinkPreviews.shared.preview(for: raw)
                guard !Task.isCancelled, let self, self.url == url, let preview else { return }
                let title = preview.title.trimmingCharacters(in: .whitespacesAndNewlines)
                self.show(title: title.isEmpty ? LinkPreviewParsing.bareLinkLabel(title: nil, target: raw) : title,
                          icon: preview.icon.flatMap { UIImage(data: $0) })
            }
        }
        setNeedsLayout()
    }

    func reset() {
        load?.cancel()
        load = nil
        url = nil
    }

    private func show(title: String, icon image: UIImage?) {
        titleLabel.text = title
        // [mac-audit] Owner 2026-11-02 (Mac audit #26): a page with no title of its own named its host twice, in the
        // address standing in for the title and again under it. A title that already starts with the host shows
        // alone, centred in the card (its height stays fixed).
        let host = hostLabel.text ?? ""
        hostLabel.isHidden = host.isEmpty || title.lowercased().hasPrefix(host.lowercased())
        if let image {
            icon.image = image
            icon.accessibilityIdentifier = "chat.link-chip.icon"
        } else {
            icon.image = UIImage(systemName: "globe", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .regular))
            icon.accessibilityIdentifier = "chat.link-chip.globe"
        }
        accessibilityLabel = hostLabel.isHidden ? "Link, \(title)" : "Link, \(title), \(hostLabel.text ?? url.map(LinkPreviewParsing.displayHost) ?? "")"
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let titleH = ceil(titleLabel.font.lineHeight), hostH = hostLabel.isHidden ? 0 : ceil(hostLabel.font.lineHeight)
        let top = ((bounds.height - titleH - (hostLabel.isHidden ? 0 : 2 + hostH)) / 2).rounded()
        let textX = Self.padH + Self.iconSize + 8
        let textW = max(0, bounds.width - textX - Self.padH)
        icon.frame = CGRect(x: Self.padH, y: top + (titleH - Self.iconSize) / 2, width: Self.iconSize, height: Self.iconSize).integral
        titleLabel.frame = CGRect(x: textX, y: top, width: textW, height: titleH)
        hostLabel.frame = CGRect(x: textX, y: top + titleH + 2, width: textW, height: hostH)
    }

    @objc private func tapped() {
        guard let url else { return }
        onOpen?(url)
    }
}

#if DEBUG
/// `-HQNLinkPreviewStub 'https://example.com/=>Example Domain;https://bad.example/=>-'`: the chips' titles come
/// from this table instead of the network (UI tests and screenshots); a listed page also gets a small drawn icon.
enum LinkChipStub {
    private static var install: Task<Void, Never>?

    /// One install for every chip: a second chip waits for the first one's, so none reads before the table is set.
    static func installIfAsked() async {
        if install == nil { install = Task { await installNow() } }
        await install?.value
    }

    private static func installNow() async {
        guard let text = UserDefaults.standard.string(forKey: "HQNLinkPreviewStub") else { return }
        // "url=>title;url=>-": a title of "-" is a page that can't be read. (A launch argument can't carry JSON.)
        var table: [String: Any] = [:]
        for entry in text.components(separatedBy: ";") {
            let parts = entry.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            table[parts[0]] = parts[1] == "-" ? NSNull() : parts[1]
        }
        let icon = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }.pngData()
        var entries: [String: LinkPreview?] = [:]
        for (url, value) in table {
            if let title = value as? String { entries[url] = LinkPreview(title: title, icon: icon) } else { entries[url] = .some(nil) }
        }
        await LinkPreviews.shared.setStub(entries)
    }
}
#endif
