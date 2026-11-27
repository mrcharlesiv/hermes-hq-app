// [mermaid] Expanded Mermaid diagram sheet: pinch/double-tap zoom, Preview | Source switch, Copy Image (PNG) on bar
// and via right-click / long-press context menu, and Share PNG.

import UIKit

final class MermaidSheetController: UIViewController, UIScrollViewDelegate, UIContextMenuInteractionDelegate {
    private let diagram: MermaidDiagram
    private let scroll = UIScrollView()
    private let imageView = UIImageView()
    private var sourceView: UITextView?
    private var showsSource = false
    private var copyItem: UIBarButtonItem?
    private var shareItem: UIBarButtonItem?
    private var toggleItem: UIBarButtonItem?

    init(diagram: MermaidDiagram) {
        self.diagram = diagram
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @discardableResult
    static func open(_ diagram: MermaidDiagram, from vc: UIViewController) -> MermaidSheetController {
        let page = MermaidSheetController(diagram: diagram)
        let sheet = ChatSheet.wrap(page, title: diagram.kindLabel, detents: [.large()])
        #if targetEnvironment(macCatalyst)
        SheetStyle.macPage(sheet, width: 900, from: vc)
        #else
        SheetStyle.widen(sheet, to: 900, from: vc)
        #endif
        vc.present(sheet, animated: true)
        return page
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = HQPalette.sheetPage
        view.accessibilityIdentifier = "mermaid.sheet"

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.delegate = self
        scroll.minimumZoomScale = 0.5
        scroll.maximumZoomScale = 5.0
        scroll.showsHorizontalScrollIndicator = true
        scroll.showsVerticalScrollIndicator = true
        view.addSubview(scroll)

        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = diagram.kindLabel
        imageView.accessibilityIdentifier = "mermaid.sheet.image"
        imageView.addInteraction(UIContextMenuInteraction(delegate: self))
        scroll.addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        let copy = UIBarButtonItem(title: "Copy Image", image: UIImage(systemName: "doc.on.doc"), primaryAction: UIAction { [weak self] _ in
            self?.copyPNG()
        })
        copy.accessibilityLabel = "Copy Image"
        copy.accessibilityIdentifier = "mermaid.copyImage"
        copyItem = copy

        let share = UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.up"), primaryAction: UIAction { [weak self] _ in
            self?.sharePNG()
        })
        share.accessibilityLabel = "Share Diagram"
        share.accessibilityIdentifier = "mermaid.share"
        shareItem = share

        let toggle = UIBarButtonItem(image: UIImage(systemName: "chevron.left.forwardslash.chevron.right"), primaryAction: UIAction { [weak self] _ in
            self?.toggleSource()
        })
        toggle.accessibilityLabel = "Toggle Source"
        toggle.accessibilityIdentifier = "mermaid.toggleSource"
        toggleItem = toggle

        navigationItem.rightBarButtonItems = [share, copy, toggle]

        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (page: MermaidSheetController, _) in
            page.renderDiagram()
        }
        renderDiagram()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutDiagram()
    }

    private func renderDiagram() {
        let natural = MermaidRenderer.naturalSize(for: diagram)
        let img = MermaidRenderer.renderImage(diagram: diagram, size: natural, traits: traitCollection, scale: max(2, traitCollection.displayScale))
        imageView.image = img
        layoutDiagram()
    }

    private func layoutDiagram() {
        guard let img = imageView.image, img.size.width > 0, img.size.height > 0 else { return }
        let bounds = scroll.bounds.size
        guard bounds.width > 0, bounds.height > 0 else { return }
        let fit = min(1.5, min((bounds.width - 32) / img.size.width, (bounds.height - 32) / img.size.height))
        let drawn = CGSize(width: max(120, img.size.width * fit), height: max(80, img.size.height * fit))
        if scroll.zoomScale == 1 {
            imageView.frame = CGRect(origin: .zero, size: drawn)
            scroll.contentSize = drawn
        }
        centerImage()
    }

    private func centerImage() {
        let b = scroll.bounds.size
        let c = imageView.frame.size
        scroll.contentInset = UIEdgeInsets(
            top: max(16, (b.height - c.height) / 2),
            left: max(16, (b.width - c.width) / 2),
            bottom: 16,
            right: 16
        )
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }

    @objc private func doubleTapped(_ tap: UITapGestureRecognizer) {
        if scroll.zoomScale > 1.05 {
            scroll.setZoomScale(1, animated: !HQMotion.reduced)
        } else {
            let pt = tap.location(in: imageView)
            let w = scroll.bounds.width / 2.2
            let h = scroll.bounds.height / 2.2
            scroll.zoom(to: CGRect(x: pt.x - w / 2, y: pt.y - h / 2, width: w, height: h), animated: !HQMotion.reduced)
        }
    }

    private func toggleSource() {
        showsSource.toggle()
        if showsSource {
            if sourceView == nil {
                let tv = UITextView()
                tv.translatesAutoresizingMaskIntoConstraints = false
                tv.isEditable = false
                tv.font = HQFont.mono(ofSize: 13)
                tv.textColor = HQPalette.label
                tv.backgroundColor = HQPalette.sheetPage
                tv.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
                tv.text = diagram.source
                tv.accessibilityIdentifier = "mermaid.source"
                view.addSubview(tv)
                NSLayoutConstraint.activate([
                    tv.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                    tv.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
                    tv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                    tv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                ])
                sourceView = tv
            }
            sourceView?.isHidden = false
            scroll.isHidden = true
            toggleItem?.image = UIImage(systemName: "eye")
            toggleItem?.accessibilityLabel = "Show Diagram"
        } else {
            sourceView?.isHidden = true
            scroll.isHidden = false
            toggleItem?.image = UIImage(systemName: "chevron.left.forwardslash.chevron.right")
            toggleItem?.accessibilityLabel = "Toggle Source"
        }
    }

    /// Copies the diagram rendered as a crisp PNG image to the system clipboard.
    @discardableResult
    func copyPNG() -> Bool {
        guard let png = MermaidRenderer.pngData(for: diagram, traits: traitCollection, scale: 3),
              UIImage(data: png) != nil else { return false }
        UIPasteboard.general.setData(png, forPasteboardType: "public.png")
        Haptics.play(.success)
        HQAnnounce.say("Diagram image copied")
        copyItem?.image = UIImage(systemName: "checkmark")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            self?.copyItem?.image = UIImage(systemName: "doc.on.doc")
        }
        return true
    }

    private func sharePNG() {
        guard let png = MermaidRenderer.pngData(for: diagram, traits: traitCollection, scale: 3) else { return }
        let file = FileManager.default.temporaryDirectory.appending(path: "mermaid-diagram.png")
        try? png.write(to: file)
        let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        sheet.popoverPresentationController?.barButtonItem = shareItem
        present(sheet, animated: true)
    }

    // MARK: Right-click / long-press context menu (Copy Image as PNG)

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let copyImg = UIAction(title: "Copy Image", image: UIImage(systemName: "doc.on.doc")) { _ in
                _ = self?.copyPNG()
            }
            let copySrc = UIAction(title: "Copy Mermaid Source", image: UIImage(systemName: "chevron.left.forwardslash.chevron.right")) { _ in
                UIPasteboard.general.string = self?.diagram.source
                Haptics.play(.success)
                HQAnnounce.say("Mermaid source copied")
            }
            let shareImg = UIAction(title: "Share PNG…", image: UIImage(systemName: "square.and.arrow.up")) { _ in
                self?.sharePNG()
            }
            return UIMenu(children: [copyImg, copySrc, shareImg])
        }
    }
}
