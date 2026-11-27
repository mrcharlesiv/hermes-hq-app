// [image-markup] Native iOS + Mac Catalyst image markup editor and high-resolution CoreGraphics compositor.
// Supports freehand pen, highlighter, straight arrow, box callout, numbered pin notes, undo/redo, clear,
// and an edit instruction bar so users can circle/mark what they want changed and send it to the bot.

import UIKit

nonisolated enum ImageMarkupRenderer {
    /// Draws strokes and numbered pin badges into `cg` across `bounds`.
    /// A pin badge's width where the picture's short side is `minSide` points on screen: big enough to tap and read,
    /// never so big it hides what it points at.
    static func badgeDiameter(forMinSide minSide: CGFloat) -> CGFloat { max(24, min(48, minSide * 0.062)) }

    /// How many points of a freehand stroke are stroked as one path. CoreGraphics works out every place a path's
    /// outline crosses itself before it fills it, so one long scribble back and forth over the picture (thousands of
    /// points, each sweep crossing the others) took seconds to draw, on every move of the finger. In pieces the
    /// cost stays in step with the stroke's length; round ends make the pieces meet without a seam.
    static let strokeChunk = 64

    /// A stroke's width in `bounds`' units: at least a visible line, at most a fifth of the picture, whatever the
    /// stored ratio says (a ratio that isn't a number draws the thinnest line, not nothing and not everything).
    static func lineWidth(ratio: Double, minSide: CGFloat) -> CGFloat {
        let wanted = CGFloat(ratio) * minSide
        guard wanted.isFinite else { return 2 }
        return min(max(2, wanted), max(2, minSide * 0.2))
    }

    /// `badgeDiameter`: the badges' width in `bounds`' own units; nil sizes them for a picture shown at `bounds`.
    static func draw(_ state: ImageMarkupDocument.State, activeStroke: ImageMarkupStroke? = nil, in bounds: CGRect,
                     badgeDiameter fixedBadge: CGFloat? = nil, cg: CGContext) {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let minSide = min(size.width, size.height)

        var allStrokes = state.strokes
        if let activeStroke { allStrokes.append(activeStroke) }

        for stroke in allStrokes where !stroke.points.isEmpty {
            let rgba = stroke.color.rgba
            let freehand = stroke.tool == .pen || stroke.tool == .highlighter
            // A see-through freehand stroke is drawn solid into a layer of its own, and the layer laid down
            // see-through: the pieces it is drawn in, and the places it crosses itself, come out one even tone.
            let layered = freehand && stroke.opacity < 1 && stroke.points.count > 1
            let color = UIColor(red: rgba.r, green: rgba.g, blue: rgba.b, alpha: layered ? rgba.a : rgba.a * stroke.opacity)
            let lineWidth = Self.lineWidth(ratio: stroke.widthRatio, minSide: minSide)
            let pts = stroke.points.map { p -> CGPoint in
                let pt = p.cgPoint(in: size)
                return CGPoint(x: bounds.minX + pt.x, y: bounds.minY + pt.y)
            }
            cg.saveGState()
            color.setStroke()
            color.setFill()
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            cg.setLineWidth(lineWidth)

            switch stroke.tool {
            case .pen, .highlighter:
                if pts.count == 1 {
                    let r = lineWidth / 2
                    cg.fillEllipse(in: CGRect(x: pts[0].x - r, y: pts[0].y - r, width: lineWidth, height: lineWidth))
                } else {
                    if layered {
                        var box = CGRect(origin: pts[0], size: .zero)
                        for p in pts { box = box.union(CGRect(origin: p, size: .zero)) }
                        cg.setAlpha(stroke.opacity)
                        cg.beginTransparencyLayer(in: box.insetBy(dx: -lineWidth, dy: -lineWidth).intersection(bounds.insetBy(dx: -lineWidth, dy: -lineWidth)),
                                                  auxiliaryInfo: nil)
                    }
                    var pen = pts[0]
                    var next = 1
                    while next < pts.count {
                        let end = min(pts.count, next + strokeChunk)
                        cg.move(to: pen)
                        for i in next..<end {
                            let prev = pts[i - 1], cur = pts[i]
                            pen = CGPoint(x: (prev.x + cur.x) / 2, y: (prev.y + cur.y) / 2)
                            cg.addQuadCurve(to: pen, control: prev)
                        }
                        if end == pts.count, let last = pts.last { cg.addLine(to: last) }
                        cg.strokePath()
                        next = end
                    }
                    if layered { cg.endTransparencyLayer() }
                }
            case .arrow:
                if let first = pts.first, let last = pts.last {
                    cg.move(to: first)
                    cg.addLine(to: last)
                    cg.strokePath()
                    let dx = last.x - first.x, dy = last.y - first.y
                    if hypot(dx, dy) > 4 {
                        let angle = atan2(dy, dx)
                        let headLen = max(12, lineWidth * 3.8)
                        let spread: CGFloat = .pi / 6
                        let p1 = CGPoint(x: last.x - headLen * cos(angle - spread), y: last.y - headLen * sin(angle - spread))
                        let p2 = CGPoint(x: last.x - headLen * cos(angle + spread), y: last.y - headLen * sin(angle + spread))
                        cg.move(to: last)
                        cg.addLine(to: p1)
                        cg.addLine(to: p2)
                        cg.closePath()
                        cg.fillPath()
                    }
                }
            case .box:
                if let first = pts.first, let last = pts.last {
                    let rect = CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                                      width: abs(last.x - first.x), height: abs(last.y - first.y))
                    let radius = min(10, min(rect.width, rect.height) * 0.15)
                    let path = UIBezierPath(roundedRect: rect, cornerRadius: radius)
                    path.lineWidth = lineWidth
                    path.stroke()
                }
            case .pin:
                break
            }
            cg.restoreGState()
        }

        // Numbered pin callout badges
        let badgeDiameter = fixedBadge ?? Self.badgeDiameter(forMinSide: minSide)
        let font = HQFont.face(ofSize: max(13, badgeDiameter * 0.54), weight: .bold)
        for pin in state.pins {
            let pt = pin.point.cgPoint(in: size)
            let center = CGPoint(x: bounds.minX + pt.x, y: bounds.minY + pt.y)
            let circle = CGRect(x: center.x - badgeDiameter / 2, y: center.y - badgeDiameter / 2,
                                width: badgeDiameter, height: badgeDiameter)
            let rgba = pin.color.rgba
            let fill = UIColor(red: rgba.r, green: rgba.g, blue: rgba.b, alpha: 1)
            let textColor: UIColor = (pin.color == .white || pin.color == .yellow) ? .black : .white

            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: 2), blur: 4, color: UIColor.black.withAlphaComponent(0.35).cgColor)
            fill.setFill()
            UIBezierPath(ovalIn: circle).fill()
            cg.restoreGState()

            UIColor.white.setStroke()
            let ring = UIBezierPath(ovalIn: circle)
            ring.lineWidth = max(1.5, badgeDiameter * 0.08)
            ring.stroke()

            let label = "\(pin.number)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
            let sz = label.size(withAttributes: attrs)
            label.draw(at: CGPoint(x: center.x - sz.width / 2, y: center.y - sz.height / 2), withAttributes: attrs)
        }
    }

    /// The longest side, in pixels, of a marked-up picture: a 48-megapixel photo is brought down to this before it
    /// is drawn (its bitmap alone would be ~200 MB, and the chat sends a smaller copy anyway).
    static let maxExportSide: CGFloat = 4096

    /// Composites the original image and all markup annotations into a crisp output UIImage. `displayMinSide` is
    /// the picture's short side as the editor showed it, in points: the pin badges cover the same share of the
    /// picture in the result as they did on screen (without it they are sized as for a picture shown at full size).
    static func composite(image: UIImage, document: ImageMarkupDocument, displayMinSide: CGFloat? = nil) -> UIImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        guard !document.isEmpty else { return image }
        let format = UIGraphicsImageRendererFormat()
        let longestPixels = max(size.width, size.height) * image.scale
        format.scale = longestPixels > maxExportSide ? image.scale * maxExportSide / longestPixels : image.scale
        format.opaque = false
        format.preferredRange = .standard
        let minSide = min(size.width, size.height)
        let badge = displayMinSide.flatMap { shown -> CGFloat? in
            guard shown > 1 else { return nil }
            return badgeDiameter(forMinSide: shown) / shown * minSide
        }
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            image.draw(in: CGRect(origin: .zero, size: size))
            draw(document.current, in: CGRect(origin: .zero, size: size), badgeDiameter: badge, cg: ctx.cgContext)
        }
    }
}

// MARK: - Interactive Markup Canvas View

/// The strokes and pins, drawn over the photo. The photo itself sits in an image view under this one (the editor
/// lays both out the same), so a stroke in progress redraws a few lines, not a 12-megapixel picture, on every move.
final class ImageMarkupCanvasView: UIView {
    var image: UIImage { didSet { settled = nil; setNeedsLayout(); setNeedsDisplay() } }
    var document = ImageMarkupDocument() { didSet { settled = nil; onChange?(); setNeedsDisplay() } }
    var tool: ImageMarkupTool = .pen
    var color: ImageMarkupColor = .red
    var onChange: (() -> Void)?
    var onPinTap: ((_ point: ImageMarkupPoint, _ existing: ImageMarkupPin?) -> Void)?

    private var activeStroke: ImageMarkupStroke?
    /// Everything already drawn, as one picture at `settledSize`: a stroke in progress is drawn over it, so a move
    /// of the finger draws that one stroke, not every stroke and pin on the photo again.
    private var settled: UIImage?
    private var settledSize = CGSize.zero

    init(image: UIImage) {
        self.image = image
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isMultipleTouchEnabled = false
        accessibilityIdentifier = "markup.canvas"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Aspect-fit frame of the image inside this canvas view.
    var imageRect: CGRect {
        let s = image.size
        guard s.width > 0, s.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let fit = min(bounds.width / s.width, bounds.height / s.height)
        let w = s.width * fit, h = s.height * fit
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    override func draw(_ rect: CGRect) {
        let target = imageRect
        guard let cg = UIGraphicsGetCurrentContext(), target.width >= 1, target.height >= 1 else { return }
        if settled == nil || settledSize != target.size {
            settledSize = target.size
            if document.isEmpty {
                settled = UIImage()
            } else {
                let format = UIGraphicsImageRendererFormat.preferred()
                format.opaque = false
                format.preferredRange = .standard
                let state = document.current
                settled = UIGraphicsImageRenderer(size: target.size, format: format).image { ctx in
                    ImageMarkupRenderer.draw(state, in: CGRect(origin: .zero, size: target.size), cg: ctx.cgContext)
                }
            }
        }
        cg.saveGState()
        cg.clip(to: target)
        if let settled, settled.size.width > 0 { settled.draw(in: target) }
        if let activeStroke {
            ImageMarkupRenderer.draw(ImageMarkupDocument.State(), activeStroke: activeStroke, in: target, cg: cg)
        }
        cg.restoreGState()
    }

    private func normalizedPoint(for location: CGPoint) -> ImageMarkupPoint? {
        let target = imageRect
        guard target.width > 1, target.height > 1 else { return nil }
        let local = CGPoint(x: location.x - target.minX, y: location.y - target.minY)
        return ImageMarkupPoint(local, in: target.size)
    }

    private func existingPin(near location: CGPoint) -> ImageMarkupPin? {
        let target = imageRect
        let hitRadius: CGFloat = 24
        for pin in document.pins.reversed() {
            let pt = pin.point.cgPoint(in: target.size)
            let center = CGPoint(x: target.minX + pt.x, y: target.minY + pt.y)
            if hypot(location.x - center.x, location.y - center.y) <= hitRadius { return pin }
        }
        return nil
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let loc = touch.location(in: self)
        guard imageRect.insetBy(dx: -16, dy: -16).contains(loc), let pt = normalizedPoint(for: loc) else { return }

        if tool == .pin {
            onPinTap?(pt, existingPin(near: loc))
            return
        }
        let widthRatio: Double = switch tool {
        case .highlighter: 0.036
        case .arrow, .box: 0.011
        default: 0.010
        }
        activeStroke = ImageMarkupStroke(tool: tool, color: color, widthRatio: widthRatio, points: [pt])
        setNeedsDisplay()
    }

    /// The most points one freehand stroke keeps: a finger held down and scribbling for minutes stops adding to it.
    static let maxStrokePoints = 4_000

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard var stroke = activeStroke, let touch = touches.first,
              let pt = normalizedPoint(for: touch.location(in: self)) else { return }
        if stroke.tool == .arrow || stroke.tool == .box {
            if stroke.points.count <= 1 { stroke.points.append(pt) } else { stroke.points[1] = pt }
        } else {
            // Every sample the screen took since the last move, so a quick stroke stays a curve, not a few corners.
            let samples = event?.coalescedTouches(for: touch) ?? [touch]
            for sample in samples where stroke.points.count < Self.maxStrokePoints {
                guard let p = normalizedPoint(for: sample.location(in: self)), p != stroke.points.last else { continue }
                stroke.points.append(p)
            }
        }
        activeStroke = stroke
        setNeedsDisplay()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let stroke = activeStroke else { return }
        activeStroke = nil
        setNeedsDisplay()
        // An arrow or a box needs somewhere to go: a tap that never moved would leave an invisible mark to undo.
        if stroke.tool == .arrow || stroke.tool == .box {
            guard let first = stroke.points.first, let last = stroke.points.last, stroke.points.count > 1 else { return }
            let size = imageRect.size
            let a = first.cgPoint(in: size), b = last.cgPoint(in: size)
            guard hypot(b.x - a.x, b.y - a.y) >= 6 else { return }
        }
        document.addStroke(stroke)
        Haptics.play(.light)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        activeStroke = nil
        setNeedsDisplay()
    }
}

// MARK: - Markup Editor Controller

final class ImageMarkupController: UIViewController, UITextFieldDelegate {
    enum Mode {
        /// Opened from a chat photo: primary button says "Send to Chat" and attaches the marked-up image + note.
        case sendToChat
        /// Opened from an attachment or local/artifact photo: primary button says "Apply Markup" or "Done".
        case apply(confirmTitle: String)
    }

    private let sourceImage: UIImage
    private let mode: Mode
    private let onComplete: (UIImage, String) -> Void

    private let canvas: ImageMarkupCanvasView
    private let photo = UIImageView()
    private let bottomBar = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let toolsStack = UIStackView()
    private let colorsStack = UIStackView()
    private let noteField = UITextField()
    private let pinsBadge = UILabel()
    private let submitButton = UIButton(type: .system)

    private var toolButtons: [ImageMarkupTool: UIButton] = [:]
    private var colorButtons: [ImageMarkupColor: UIButton] = [:]
    private var undoItem: UIBarButtonItem!
    private var redoItem: UIBarButtonItem!
    private var clearItem: UIBarButtonItem!

    init(image: UIImage, mode: Mode = .sendToChat, onComplete: @escaping (UIImage, String) -> Void) {
        self.sourceImage = image
        self.mode = mode
        self.onComplete = onComplete
        self.canvas = ImageMarkupCanvasView(image: image)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @discardableResult
    static func present(image: UIImage, mode: Mode = .sendToChat, from presenter: UIViewController,
                        onComplete: @escaping (UIImage, String) -> Void) -> ImageMarkupController {
        let editor = ImageMarkupController(image: image, mode: mode, onComplete: onComplete)
        let nav = UINavigationController(rootViewController: editor)
        nav.modalPresentationStyle = .fullScreen
        nav.overrideUserInterfaceStyle = .dark
        presenter.present(nav, animated: true)
        return editor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        overrideUserInterfaceStyle = .dark
        title = "Mark Up"
        view.accessibilityIdentifier = "markup.editor"

        let cancel = UIBarButtonItem(title: "Cancel", primaryAction: UIAction { [weak self] _ in
            self?.cancelTapped()
        })
        cancel.accessibilityIdentifier = "markup.cancel"
        navigationItem.leftBarButtonItem = cancel

        undoItem = UIBarButtonItem(image: UIImage(systemName: "arrow.uturn.backward"), primaryAction: UIAction { [weak self] _ in
            self?.canvas.document.undo()
            Haptics.play(.selection)
        })
        undoItem.accessibilityLabel = "Undo"
        undoItem.accessibilityIdentifier = "markup.undo"

        redoItem = UIBarButtonItem(image: UIImage(systemName: "arrow.uturn.forward"), primaryAction: UIAction { [weak self] _ in
            self?.canvas.document.redo()
            Haptics.play(.selection)
        })
        redoItem.accessibilityLabel = "Redo"
        redoItem.accessibilityIdentifier = "markup.redo"

        clearItem = UIBarButtonItem(image: UIImage(systemName: "trash"), primaryAction: UIAction { [weak self] _ in
            self?.canvas.document.clear()
            Haptics.play(.selection)
        })
        clearItem.accessibilityLabel = "Clear Markup"
        clearItem.accessibilityIdentifier = "markup.clear"

        navigationItem.rightBarButtonItems = [clearItem, redoItem, undoItem]

        photo.image = sourceImage
        photo.contentMode = .scaleAspectFit
        photo.translatesAutoresizingMaskIntoConstraints = false
        photo.isAccessibilityElement = true
        photo.accessibilityLabel = "Photo to mark up"
        view.addSubview(photo)
        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.onChange = { [weak self] in self?.refreshControls() }
        canvas.onPinTap = { [weak self] pt, existing in self?.handlePinTap(point: pt, existing: existing) }
        view.addSubview(canvas)

        configureBottomBar()
        view.addSubview(bottomBar)

        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            canvas.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            canvas.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            canvas.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -10),
            photo.topAnchor.constraint(equalTo: canvas.topAnchor),
            photo.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
            photo.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
            photo.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),

            bottomBar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            bottomBar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            bottomBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
        ])

        refreshControls()
    }

    private func configureBottomBar() {
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.cornerConfiguration = .corners(radius: .fixed(22))
        let glass = UIGlassEffect(style: .regular)
        glass.tintColor = UIColor.black.withAlphaComponent(0.35)
        bottomBar.effect = glass

        let vStack = UIStackView()
        vStack.axis = .vertical
        vStack.spacing = 10
        vStack.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.contentView.addSubview(vStack)

        // Row 1: Tools
        toolsStack.axis = .horizontal
        toolsStack.alignment = .center
        toolsStack.distribution = .fillEqually
        toolsStack.spacing = 6
        for tool in ImageMarkupTool.allCases {
            let btn = UIButton(type: .system)
            var cfg = UIButton.Configuration.plain()
            cfg.image = UIImage(systemName: tool.symbol)
            cfg.cornerStyle = .capsule
            cfg.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
            cfg.background.cornerRadius = 16
            btn.configuration = cfg
            btn.accessibilityLabel = tool.title
            btn.accessibilityIdentifier = "markup.tool.\(tool.rawValue)"
            btn.addAction(UIAction { [weak self] _ in
                self?.canvas.tool = tool
                Haptics.play(.selection)
                self?.refreshControls()
            }, for: .primaryActionTriggered)
            #if targetEnvironment(macCatalyst)
            btn.toolTip = tool.title
            PointerEffects.button(btn)
            #endif
            toolButtons[tool] = btn
            toolsStack.addArrangedSubview(btn)
        }
        vStack.addArrangedSubview(toolsStack)

        // Row 2: Color palette centered cleanly so narrow iPhones never crowd controls
        colorsStack.axis = .horizontal
        colorsStack.alignment = .center
        colorsStack.spacing = 14
        for color in ImageMarkupColor.allCases {
            let btn = UIButton(type: .custom)
            btn.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                btn.widthAnchor.constraint(equalToConstant: 28),
                btn.heightAnchor.constraint(equalToConstant: 28),
            ])
            let rgba = color.rgba
            btn.backgroundColor = UIColor(red: rgba.r, green: rgba.g, blue: rgba.b, alpha: 1)
            btn.layer.cornerRadius = 14
            btn.layer.borderColor = UIColor.white.cgColor
            btn.accessibilityLabel = color.title
            btn.accessibilityIdentifier = "markup.color.\(color.rawValue)"
            btn.addAction(UIAction { [weak self] _ in
                self?.canvas.color = color
                Haptics.play(.selection)
                self?.refreshControls()
            }, for: .primaryActionTriggered)
            colorButtons[color] = btn
            colorsStack.addArrangedSubview(btn)
        }
        let colorWrap = UIStackView(arrangedSubviews: [UIView(), colorsStack, UIView()])
        colorWrap.axis = .horizontal
        colorWrap.alignment = .center
        colorWrap.distribution = .equalCentering
        vStack.addArrangedSubview(colorWrap)

        // Row 2: Edit note input + Submit button
        let noteRow = UIStackView()
        noteRow.axis = .horizontal
        noteRow.alignment = .center
        noteRow.spacing = 8

        noteField.placeholder = "Add edit note (optional)…"
        noteField.font = HQFont.preferred(.subheadline)
        noteField.adjustsFontForContentSizeCategory = true
        noteField.textColor = .white
        noteField.attributedPlaceholder = NSAttributedString(
            string: "Add edit note (optional)…",
            attributes: [.foregroundColor: UIColor.white.withAlphaComponent(0.55)]
        )
        noteField.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        noteField.layer.cornerRadius = 12
        noteField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 1))
        noteField.leftViewMode = .always
        noteField.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 1))
        noteField.rightViewMode = .always
        noteField.returnKeyType = .done
        noteField.delegate = self
        noteField.addAction(UIAction { [weak self] _ in self?.refreshControls() }, for: .editingChanged)
        noteField.accessibilityIdentifier = "markup.note"
        noteField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        noteField.heightAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true
        noteRow.addArrangedSubview(noteField)

        pinsBadge.font = HQFont.style(.caption1, weight: .semibold)
        pinsBadge.textColor = UIColor.white.withAlphaComponent(0.85)
        pinsBadge.isHidden = true
        pinsBadge.accessibilityIdentifier = "markup.pinsBadge"
        noteRow.addArrangedSubview(pinsBadge)

        let submitTitle: String = switch mode {
        case .sendToChat: "Use Markup"
        case .apply(let title): title
        }
        var subCfg = UIButton.Configuration.filled()
        subCfg.title = submitTitle
        subCfg.cornerStyle = .capsule
        subCfg.baseBackgroundColor = HQPalette.tint
        subCfg.baseForegroundColor = .white
        subCfg.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
        subCfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
            var out = a
            out.font = HQFont.style(.subheadline, weight: .semibold)
            return out
        }
        submitButton.configuration = subCfg
        submitButton.accessibilityIdentifier = "markup.submit"
        submitButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        submitButton.addAction(UIAction { [weak self] _ in self?.finishMarkup() }, for: .primaryActionTriggered)
        #if targetEnvironment(macCatalyst)
        PointerEffects.button(submitButton)
        #endif
        noteRow.addArrangedSubview(submitButton)
        vStack.addArrangedSubview(noteRow)

        NSLayoutConstraint.activate([
            vStack.topAnchor.constraint(equalTo: bottomBar.contentView.topAnchor, constant: 12),
            vStack.bottomAnchor.constraint(equalTo: bottomBar.contentView.bottomAnchor, constant: -12),
            vStack.leadingAnchor.constraint(equalTo: bottomBar.contentView.leadingAnchor, constant: 14),
            vStack.trailingAnchor.constraint(equalTo: bottomBar.contentView.trailingAnchor, constant: -14),
        ])
    }

    private func refreshControls() {
        undoItem.isEnabled = canvas.document.canUndo
        redoItem.isEnabled = canvas.document.canRedo
        clearItem.isEnabled = !canvas.document.isEmpty

        for (t, btn) in toolButtons {
            let active = (t == canvas.tool)
            var cfg = btn.configuration
            cfg?.background.backgroundColor = active ? HQPalette.tint : UIColor.white.withAlphaComponent(0.08)
            cfg?.baseForegroundColor = active ? .white : UIColor.white.withAlphaComponent(0.82)
            btn.configuration = cfg
            btn.isSelected = active
        }
        for (c, btn) in colorButtons {
            let active = (c == canvas.color)
            btn.layer.borderWidth = active ? 2.5 : 1.0
            btn.transform = active ? CGAffineTransform(scaleX: 1.15, y: 1.15) : .identity
        }
        // Nothing drawn, nothing pinned, nothing written: there is nothing to hand over yet.
        let note = (noteField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        submitButton.isEnabled = !canvas.document.isEmpty || !note.isEmpty
        let pinCount = canvas.document.pins.count
        pinsBadge.isHidden = pinCount == 0
        pinsBadge.text = pinCount == 1 ? "1 pin" : "\(pinCount) pins"
    }

    private func handlePinTap(point: ImageMarkupPoint, existing: ImageMarkupPin?) {
        let title = existing != nil ? "Edit Pin \(existing!.number)" : "Add Pin Note"
        let alert = UIAlertController(title: title, message: "Describe what should change at this spot.", preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "e.g., Remove the background lamp"
            field.text = existing?.note ?? ""
            field.accessibilityIdentifier = "markup.pin.field"
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let existing {
            alert.addAction(UIAlertAction(title: "Remove Pin", style: .destructive) { [weak self] _ in
                self?.canvas.document.removePin(id: existing.id)
                Haptics.play(.selection)
            })
        }
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            let text = alert?.textFields?.first?.text ?? ""
            if let existing {
                self.canvas.document.updatePin(id: existing.id, note: text)
            } else {
                self.canvas.document.addPin(at: point, color: self.canvas.color, note: text)
            }
            Haptics.play(.success)
        })
        present(alert, animated: true)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    /// Cancel with marks on the picture asks first: one stray tap shouldn't throw the drawing away.
    private func cancelTapped() {
        guard !canvas.document.isEmpty else { dismiss(animated: true); return }
        let sheet = UIAlertController(title: nil, message: "Discard your markup?", preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Discard Markup", style: .destructive) { [weak self] _ in self?.dismiss(animated: true) })
        sheet.addAction(UIAlertAction(title: "Keep Editing", style: .cancel))
        sheet.popoverPresentationController?.barButtonItem = navigationItem.leftBarButtonItem
        present(sheet, animated: true)
    }

    private func finishMarkup() {
        let shown = canvas.imageRect.size
        let composited = ImageMarkupRenderer.composite(image: sourceImage, document: canvas.document,
                                                       displayMinSide: min(shown.width, shown.height))
        let prompt = ImageMarkupPrompt.compose(note: noteField.text ?? "", pins: canvas.document.pins,
                                               hasMarks: !canvas.document.isEmpty)
        Haptics.play(.success)
        dismiss(animated: true) { [onComplete] in
            onComplete(composited, prompt)
        }
    }
}
