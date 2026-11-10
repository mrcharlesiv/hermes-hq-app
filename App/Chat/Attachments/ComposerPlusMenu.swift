import UIKit
import UniformTypeIdentifiers

// The composer's + (docs/spec/1x-attachments.md §4.1; R:src/ui-chat/plus-menu.ts:15-39): a 40 pt native glass circle
// whose system menu opens with an inline row — Camera · Photos · Files — then Paste Image when the pasteboard holds an
// image. Other streams add their items through ordered slots (memo 10, talk 20, link 40, folder 50, snippets 60,
// more 70); this stream fills `pickers` (0) and `paste` (30).

@MainActor final class ComposerPlusMenu {
    enum Slot: Int, Comparable {
        case pickers = 0, memo = 10, talk = 20, paste = 30, link = 40, folder = 50, snippets = 60, more = 70
        static func < (a: Slot, b: Slot) -> Bool { a.rawValue < b.rawValue }
    }

    /// A slot's elements, made each time the menu opens.
    typealias Provider = () -> [UIMenuElement]
    private var providers: [Slot: [Provider]] = [:]

    /// Adds a slot's items (other streams: Voice Memo, Talk, Link…, Folder…, Prompt Snippets…).
    func register(_ slot: Slot, _ provider: @escaping Provider) {
        providers[slot, default: []].append(provider)
    }

    /// The whole menu, slots in order.
    func makeMenu() -> UIMenu {
        var children: [UIMenuElement] = []
        for slot in providers.keys.sorted() {
            for provider in providers[slot] ?? [] { children += provider() }
        }
        return UIMenu(children: children)
    }

    /// The inline row of three pickers (spec §4.1): Camera "Unavailable" without a camera; all "Up to 16 per message" at 16.
    /// [mac] A Mac with no camera (a Mac mini, a Mac Studio, a closed laptop on a display) has no Camera at all: a row
    /// that can never work is left out, not greyed. With a camera (the built-in one, or an iPhone as Continuity Camera
    /// webcam, which macOS lists as a camera) the system's picker takes the photo, as on a phone. "Take Photo" from a
    /// nearby iPhone (AppKit's Import from iPhone) is an NSResponder service with no UIKit form under Catalyst.
    static func pickers(count: Int, camera: @escaping () -> Void, photos: @escaping () -> Void, files: @escaping () -> Void,
                        hasCamera: Bool = UIImagePickerController.isSourceTypeAvailable(.camera)) -> UIMenu {
        let full = count >= AttachmentStaging.maxPerMessage
        let cameraAction = UIAction(title: "Camera", image: UIImage(systemName: "camera")) { _ in camera() }
        cameraAction.accessibilityIdentifier = "composer.plus.camera"
        let photosAction = UIAction(title: "Photos", image: UIImage(systemName: "photo.on.rectangle")) { _ in photos() }
        photosAction.accessibilityIdentifier = "composer.plus.photos"
        let filesAction = UIAction(title: "Files", image: UIImage(systemName: "doc")) { _ in files() }
        filesAction.accessibilityIdentifier = "composer.plus.files"
        if full {
            for a in [cameraAction, photosAction, filesAction] {
                a.attributes = .disabled
                a.subtitle = limitNote
            }
        } else if !hasCamera {
            cameraAction.attributes = .disabled
            cameraAction.subtitle = "Unavailable"
        }
        let shown = DeviceWord.isMac && !hasCamera ? [photosAction, filesAction] : [cameraAction, photosAction, filesAction]
        let row = UIMenu(title: "", options: .displayInline, children: shown)
        row.preferredElementSize = .medium
        return row
    }

    /// Under a source the tray is full for: the limit itself (removing a tile frees a place).
    static var limitNote: String { "Up to \(AttachmentStaging.maxPerMessage) per message" }

    /// Paste Image, present only when the pasteboard holds an image (checked without a paste prompt).
    static func paste(enabled: Bool, action: @escaping () -> Void) -> UIMenuElement {
        UIDeferredMenuElement.uncached { completion in
            guard UIPasteboard.general.hasImages else { completion([]); return }
            let paste = UIAction(title: "Paste Image", image: UIImage(systemName: "doc.on.clipboard")) { _ in action() }
            paste.accessibilityIdentifier = "composer.plus.paste"
            if !enabled { paste.attributes = .disabled; paste.subtitle = limitNote }
            completion([paste])
        }
    }
}

/// The + button: a system button with its menu as the primary action (a long press is the same menu). [composer-bar]
/// The composer takes its glass away (a plain glyph on the bar); a press shows the mic's soft circle behind it.
final class ComposerPlusButton: UIView {
    let button = UIButton(type: .system)
    private let pressedCircle = ComposerGlassButton.makePressedCircle()
    private let glass: UIVisualEffectView = {
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = true
        let view = UIVisualEffectView(effect: effect)
        view.cornerConfiguration = .capsule()
        return view
    }()

    /// Asked each time the menu opens (the count, the pasteboard).
    var menuProvider: (() -> UIMenu)?

    /// [composer-plus] In the iOS look the + stands on a 36 pt disc (owner 2026-10-31: the thin + "looks cheap"), its
    /// glyph 17 pt semibold in label; the Desktop Look keeps the plain glyph. [composer-glass] The disc is Liquid Glass.
    private let disc = ComposerGlassDisc()
    private var usesDisc: Bool { !ComposerView.oneBox }   // [mac] the box's plain glyph on the Mac

    private var glyphImage: UIImage? {
        UIImage(systemName: "plus", withConfiguration: usesDisc ? ComposerGlassButton.discConfiguration : ComposerGlassButton.glyphConfiguration)
    }
    private var glyphColor: UIColor { usesDisc ? ChatPalette.label : ChatPalette.composerGlyph }

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: ChatMetrics.control, height: ChatMetrics.control))
        addSubview(glass)
        glass.contentView.addSubview(pressedCircle)
        glass.contentView.addSubview(disc)
        var config = UIButton.Configuration.plain()
        config.image = glyphImage
        config.baseForegroundColor = glyphColor
        config.contentInsets = .zero
        button.configuration = config
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = "Attach"
        button.accessibilityIdentifier = "composer.plus"
        // [a11y] A hold at the accessibility text sizes shows the + large, named (the menu opens on a tap).
        button.showsLargeContentViewer = true
        button.largeContentTitle = "Attach"
        button.largeContentImage = UIImage(systemName: "plus")
        button.scalesLargeContentImage = true
        button.addInteraction(UILargeContentViewerInteraction())
        glass.contentView.addSubview(button)
        let deferred = UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.menuProvider?().children ?? [])
        }
        button.menu = UIMenu(children: [deferred])
        button.configurationUpdateHandler = { [weak self] button in
            guard let self else { return }
            if self.usesDisc {
                self.disc.press(button.isHighlighted)
            } else {
                ComposerGlassButton.showPress(self.pressedCircle, button.isHighlighted)
            }
        }
        registerForTraitChanges([ThemeGenerationTrait.self]) { (view: ComposerPlusButton, _) in
            view.pressedCircle.backgroundColor = ChatPalette.fill3
            view.button.configuration?.image = view.glyphImage
            view.button.configuration?.baseForegroundColor = view.glyphColor
            view.setNeedsLayout()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        button.frame = glass.contentView.bounds
        pressedCircle.frame = glass.contentView.bounds.insetBy(dx: 4, dy: 4)
        pressedCircle.layer.cornerRadius = pressedCircle.bounds.width / 2
        disc.isHidden = !usesDisc
        let discSide: CGFloat = 36
        disc.bounds = CGRect(x: 0, y: 0, width: discSide, height: discSide)   // (the press scales it: no frame)
        disc.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    /// A 48 pt hit box around the 44 pt slot.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -2, dy: -2).contains(point)
    }

    var isEnabledForAttaching: Bool {
        get { button.isEnabled }
        set { button.isEnabled = newValue; alpha = newValue ? 1 : 0.4 }
    }
}
