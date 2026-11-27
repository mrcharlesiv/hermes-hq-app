// [mermaid] Inline Mermaid diagram card inside a chat bubble: crisp vector preview, header with kind label,
// Copy Image (PNG) button, Expand button, tap to open MermaidSheetController, and right-click/long-press Copy Image.

import UIKit

final class MermaidCardView: UIView, UIContextMenuInteractionDelegate {
    static let headerHeight: CGFloat = 34

    var onExpand: ((MermaidDiagram) -> Void)?
    private var diagram: MermaidDiagram?
    private let header = UIView()
    private let titleLabel = UILabel()
    private let copyButton = UIButton(type: .system)
    private let expandButton = UIButton(type: .system)
    private let imageView = UIImageView()
    private let tapControl = UIControl()

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        layer.cornerRadius = ChatMetrics.codeRadius
        layer.cornerCurve = .continuous
        backgroundColor = ChatPalette.codeFill

        addSubview(header)
        titleLabel.font = HQFont.scaled(12, weight: .semibold, like: .caption1, cap: 20)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = ChatPalette.label2
        header.addSubview(titleLabel)

        var copyCfg = UIButton.Configuration.plain()
        copyCfg.image = UIImage(systemName: "doc.on.doc", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        copyCfg.baseForegroundColor = ChatPalette.label2
        copyButton.configuration = copyCfg
        copyButton.accessibilityLabel = "Copy Image"
        copyButton.accessibilityIdentifier = "mermaid.card.copy"
        copyButton.addAction(UIAction { [weak self] _ in self?.copyPNG() }, for: .primaryActionTriggered)
        header.addSubview(copyButton)

        var expCfg = UIButton.Configuration.plain()
        expCfg.image = UIImage(systemName: "arrow.up.left.and.arrow.down.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        expCfg.baseForegroundColor = ChatPalette.label2
        expandButton.configuration = expCfg
        expandButton.accessibilityLabel = "Expand Diagram"
        expandButton.accessibilityIdentifier = "mermaid.card.expand"
        expandButton.addAction(UIAction { [weak self] _ in
            guard let self, let diagram = self.diagram else { return }
            self.onExpand?(diagram)
        }, for: .primaryActionTriggered)
        header.addSubview(expandButton)

        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = false
        addSubview(imageView)

        tapControl.isAccessibilityElement = true
        tapControl.accessibilityTraits = .button
        tapControl.accessibilityIdentifier = "mermaid.card"
        tapControl.addTarget(self, action: #selector(cardTapped), for: .touchUpInside)
        tapControl.addInteraction(UIContextMenuInteraction(delegate: self))
        addSubview(tapControl)

        #if targetEnvironment(macCatalyst)
        PointerEffects.button(copyButton)
        PointerEffects.button(expandButton)
        PointerEffects.surface(tapControl)
        copyButton.toolTip = "Copy Image"
        expandButton.toolTip = "Expand Diagram"
        #endif

        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (view: MermaidCardView, _) in
            view.redraw()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ diagram: MermaidDiagram, size: CGSize) {
        self.diagram = diagram
        titleLabel.text = "Mermaid · \(diagram.kindLabel)"
        tapControl.accessibilityLabel = "Open \(diagram.kindLabel)"
        let w = size.width
        let h = size.height
        header.frame = CGRect(x: 0, y: 0, width: w, height: Self.headerHeight)
        expandButton.frame = CGRect(x: w - 38, y: 0, width: 34, height: Self.headerHeight)
        copyButton.frame = CGRect(x: w - 74, y: 0, width: 34, height: Self.headerHeight)
        titleLabel.frame = CGRect(x: 12, y: 0, width: max(40, w - 90), height: Self.headerHeight)
        let imgFrame = CGRect(x: 8, y: Self.headerHeight, width: max(40, w - 16), height: max(40, h - Self.headerHeight - 8))
        imageView.frame = imgFrame
        tapControl.frame = imgFrame
        redraw()
    }

    func reset() {
        diagram = nil
        imageView.image = nil
    }

    private func redraw() {
        guard let diagram, imageView.bounds.width > 10, imageView.bounds.height > 10 else { return }
        imageView.image = MermaidRenderer.renderImage(
            diagram: diagram,
            size: imageView.bounds.size,
            traits: traitCollection,
            scale: max(2, traitCollection.displayScale)
        )
    }

    @objc private func cardTapped() {
        guard let diagram else { return }
        Haptics.play(.selection)
        onExpand?(diagram)
    }

    private func copyPNG() {
        guard let diagram, let png = MermaidRenderer.pngData(for: diagram, traits: traitCollection, scale: 3),
              UIImage(data: png) != nil else { return }
        UIPasteboard.general.setData(png, forPasteboardType: "public.png")
        Haptics.play(.success)
        HQAnnounce.say("Diagram image copied")
        var cfg = copyButton.configuration
        cfg?.image = UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        copyButton.configuration = cfg
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            var reset = self?.copyButton.configuration
            reset?.image = UIImage(systemName: "doc.on.doc", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .regular))
            self?.copyButton.configuration = reset
        }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let diagram else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let expand = UIAction(title: "Expand Diagram", image: UIImage(systemName: "arrow.up.left.and.arrow.down.right")) { _ in
                self?.onExpand?(diagram)
            }
            let copyImg = UIAction(title: "Copy Image", image: UIImage(systemName: "doc.on.doc")) { _ in
                self?.copyPNG()
            }
            let copySrc = UIAction(title: "Copy Mermaid Source", image: UIImage(systemName: "chevron.left.forwardslash.chevron.right")) { _ in
                UIPasteboard.general.string = diagram.source
                Haptics.play(.success)
                HQAnnounce.say("Mermaid source copied")
            }
            return UIMenu(children: [expand, copyImg, copySrc])
        }
    }
}
