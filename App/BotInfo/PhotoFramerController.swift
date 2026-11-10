// [photoheads] Move and Scale (docs/spec/3x-photoheads.md §7): place a picked photo in the frame the bot will wear.
// Drag to move, pinch or use the slider to size (from the whole photo fitting inside the frame to 5×), double tap to
// start over. What is outside the frame is dimmed; when the photo does not cover the frame, a blurred copy of it fills
// the gaps. Choose hands back a 256 × 256 PNG (PhotoFramerRenderer).
//
// A full-screen cover in the dark style, on system bars: the title on the navigation bar, Cancel and Choose on the
// toolbar. The placement itself is `PhotoFrame` (HermesKit/Model), in frame sides, so a rotation or an iPad resize
// keeps it as it is.

import UIKit

final class PhotoFramerController: UIViewController, UIGestureRecognizerDelegate {
    typealias Outcome = Result<FramedPhoto, PhotoPickError>?

    /// One arrow-style move for VoiceOver and Switch Control, in frame sides.
    static let nudge = 0.05

    private let load: PhotoLoad
    private let completion: (Outcome) -> Void
    private var photo: PickedPhoto?
    private var backdrop: PickedPhoto?
    private var buildingBackdrop = false
    private(set) var placement = PhotoFrame.start
    private var rendering = false
    private var finished = false
    private var appeared = false
    private var pendingFailure: PhotoPickError?

    private let stage = PhotoStageView()
    private let canvas = UIView()
    private let backdropClip = UIView()
    private let backdropView = UIImageView()
    private let photoView = UIImageView()
    private let windowView = FramerWindowView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let zoomRow = UIView()
    private let smallGlyph = UIImageView()
    private let largeGlyph = UIImageView()
    private let slider = ZoomSlider()
    private var cancelItem: UIBarButtonItem!
    private var chooseItem: UIBarButtonItem!

    init(load: PhotoLoad, completion: @escaping (Outcome) -> Void) {
        self.load = load
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
        title = "Move and Scale"
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.hidesBackButton = true
    }

    @MainActor required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The cover: full screen, dark, with the toolbar that holds Cancel and Choose.
    static func wrapped(_ framer: PhotoFramerController) -> UINavigationController {
        let navigation = UINavigationController(rootViewController: framer)
        navigation.modalPresentationStyle = .fullScreen
        navigation.overrideUserInterfaceStyle = .dark
        navigation.isToolbarHidden = false
        navigation.view.backgroundColor = .black
        return navigation
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        stage.backgroundColor = .black
        stage.clipsToBounds = true
        stage.accessibilityIdentifier = "photo-framer.stage"
        stage.actions = { [weak self] in self?.stageActions() ?? [] }
        view.addSubview(stage)

        canvas.isUserInteractionEnabled = false
        stage.addSubview(canvas)
        backdropClip.clipsToBounds = true
        backdropClip.layer.cornerCurve = .continuous
        backdropClip.isHidden = true
        backdropView.contentMode = .scaleToFill
        backdropView.accessibilityIgnoresInvertColors = true
        backdropClip.addSubview(backdropView)
        canvas.addSubview(backdropClip)
        photoView.contentMode = .scaleToFill
        photoView.accessibilityIgnoresInvertColors = true
        photoView.layer.minificationFilter = .trilinear
        canvas.addSubview(photoView)

        windowView.isUserInteractionEnabled = false
        stage.addSubview(windowView)
        spinner.color = .white
        spinner.hidesWhenStopped = true
        stage.addSubview(spinner)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 2
        pan.delegate = self
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.delegate = self
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped))
        doubleTap.numberOfTapsRequired = 2
        for recognizer in [pan, pinch, doubleTap] { stage.addGestureRecognizer(recognizer) }

        for (glyph, size) in [(smallGlyph, 16.0), (largeGlyph, 24.0)] {
            glyph.image = UIImage(systemName: "photo", withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .regular))
            glyph.tintColor = UIColor.white.withAlphaComponent(0.75)
            glyph.contentMode = .center
            glyph.isAccessibilityElement = false
            zoomRow.addSubview(glyph)
        }
        slider.accessibilityIdentifier = "photo-framer.zoom"
        slider.accessibilityLabel = "Zoom"
        slider.isContinuous = true
        slider.minimumValue = 1
        slider.maximumValue = Float(PhotoFrame.maxZoom)
        slider.value = 1
        slider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)
        zoomRow.addSubview(slider)
        view.addSubview(zoomRow)

        cancelItem = UIBarButtonItem(title: "Cancel", style: .plain, target: self, action: #selector(cancel))
        cancelItem.accessibilityIdentifier = "photo-framer.cancel"
        chooseItem = UIBarButtonItem(title: "Choose", style: .prominent, target: self, action: #selector(choose))
        chooseItem.accessibilityIdentifier = "photo-framer.choose"
        toolbarItems = [cancelItem, UIBarButtonItem(systemItem: .flexibleSpace), chooseItem]

        refreshControls()
        load.onFinish = { [weak self] result in self?.loaded(result) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        appeared = true
        if let pendingFailure { close(.failure(pendingFailure)) }
    }

    /// Taken down from outside (sign-out or a gateway switch closing every sheet, not Cancel or Choose): the same as
    /// Cancel, so the pick ends, its file goes and whoever waits for the photo is answered.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard !finished else { return }
        let cover = navigationController ?? self
        guard cover.isBeingDismissed || isBeingDismissed || cover.presentingViewController == nil else { return }
        finished = true
        load.cancel()
        completion(nil)
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // The photo stays (about 4 MB); the blurred copy is made again when a gap next shows.
        guard !backdropIsShowing else { return }
        backdrop = nil
        backdropView.image = nil
    }

    // MARK: - Layout

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        let safe = view.safeAreaInsets
        let rowWidth = max(120, min(bounds.width - safe.left - safe.right - 32, 420))
        let rowHeight: CGFloat = 44
        zoomRow.frame = CGRect(x: (bounds.width - rowWidth) / 2, y: bounds.height - safe.bottom - 4 - rowHeight, width: rowWidth, height: rowHeight)
        smallGlyph.frame = CGRect(x: 0, y: 0, width: 28, height: rowHeight)
        largeGlyph.frame = CGRect(x: rowWidth - 36, y: 0, width: 36, height: rowHeight)
        slider.frame = CGRect(x: 28 + 8, y: 0, width: max(40, rowWidth - 28 - 36 - 16), height: rowHeight)

        let stageTop = safe.top
        stage.frame = CGRect(x: 0, y: stageTop, width: bounds.width, height: max(1, zoomRow.frame.minY - 14 - stageTop))
        let side = max(1, min(stage.bounds.width - 32, stage.bounds.height - 32, 420))
        canvas.frame = CGRect(x: (stage.bounds.width - side) / 2, y: (stage.bounds.height - side) / 2, width: side, height: side)
        windowView.frame = stage.bounds
        windowView.hole = canvas.frame
        spinner.center = CGPoint(x: canvas.frame.midX, y: canvas.frame.midY)
        applyPlacement()
    }

    private var side: CGFloat { max(1, canvas.bounds.width) }

    private var backdropIsShowing: Bool { !backdropClip.isHidden }

    /// Puts the photo where the placement says, in this frame, with no animation or rubber band (the model clamps).
    private func applyPlacement() {
        guard let photo else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        photoView.frame = placement.rect(photo.size, edge: Double(side))
        let gaps = placement.leavesGaps(photo.size)
        backdropClip.isHidden = !gaps
        if gaps {
            backdropClip.frame = canvas.bounds
            backdropClip.layer.cornerRadius = side * BotFaces.cornerShare
            backdropView.frame = backdropClip.bounds
            ensureBackdrop()
        }
        CATransaction.commit()
        if !slider.isTracking { slider.value = Float(placement.zoom) }
        stage.accessibilityValue = Self.describe(placement)
    }

    /// The blurred copy, made off the main thread once per photo (and again after a memory warning).
    private func ensureBackdrop() {
        if let backdrop {
            if backdropView.image == nil { backdropView.image = UIImage(cgImage: backdrop.image) }
            return
        }
        guard !buildingBackdrop, let photo else { return }
        buildingBackdrop = true
        Task { [weak self] in
            let made = await Task.detached(priority: .userInitiated) {
                PhotoFramerRenderer.backdrop(photo: photo.image).map { PickedPhoto(image: $0) }
            }.value
            guard let self else { return }
            self.buildingBackdrop = false
            self.backdrop = made
            if let made { self.backdropView.image = UIImage(cgImage: made.image) }
        }
    }

    // MARK: - Loading

    private func loaded(_ result: Result<PickedPhoto, PhotoPickError>) {
        guard !finished else { return }
        switch result {
        case .success(let photo):
            self.photo = photo
            placement = PhotoFrame.start.clamped(photo.size)
            photoView.image = UIImage(cgImage: photo.image)
            slider.minimumValue = Float(PhotoFrame.minZoom(photo.size))
            slider.maximumValue = Float(PhotoFrame.maxZoom)
            ensureBackdrop()
            refreshControls()
            view.setNeedsLayout()
            UIAccessibility.post(notification: .layoutChanged, argument: stage)
        case .failure(let error):
            // Closing while the cover is still coming up would be dropped: wait for it to be up.
            if appeared { close(.failure(error)) } else { pendingFailure = error }
        }
    }

    private func refreshControls() {
        let ready = photo != nil && !rendering
        if photo == nil { spinner.startAnimating() } else { spinner.stopAnimating() }
        slider.isEnabled = ready
        chooseItem?.setProminentEnabled(ready)
        cancelItem?.isEnabled = !rendering
        for recognizer in stage.gestureRecognizers ?? [] { recognizer.isEnabled = ready }
        stage.accessibilityLabel = photo == nil ? "Loading photo" : "Photo"
        stage.accessibilityHint = photo == nil ? nil : "Pinch or use the zoom slider to size the photo, and drag it to place it in the frame."
    }

    // MARK: - Moving and sizing

    /// Every change comes through here: applied in the same frame, with a light tick when the zoom reaches an end.
    private func set(_ next: PhotoFrame, animated: Bool = false) {
        guard let photo, next != placement else { return }
        let low = PhotoFrame.minZoom(photo.size), high = PhotoFrame.maxZoom
        let atEnd = next.zoom <= low + 1e-9 || next.zoom >= high - 1e-9
        if atEnd, next.zoom != placement.zoom { Haptics.play(.selection) }
        placement = next
        if animated, !HQMotion.reduced {
            UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut]) { self.applyPlacement() }
        } else {
            applyPlacement()
        }
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        guard let photo, pan.state == .changed || pan.state == .ended else { return }
        let moved = pan.translation(in: stage)
        pan.setTranslation(.zero, in: stage)
        set(placement.panned(photo.size, dx: Double(moved.x / side), dy: Double(moved.y / side)))
    }

    @objc private func pinched(_ pinch: UIPinchGestureRecognizer) {
        guard let photo, pinch.state == .changed || pinch.state == .ended else { return }
        let ratio = Double(pinch.scale)
        pinch.scale = 1
        let at = pinch.location(in: canvas)
        set(placement.zoomed(photo.size, ratio: ratio, focusX: Double((at.x - side / 2) / side), focusY: Double((at.y - side / 2) / side)))
    }

    @objc private func doubleTapped() {
        guard let photo else { return }
        set(PhotoFrame.start.clamped(photo.size), animated: true)
    }

    @objc private func sliderChanged() {
        guard let photo else { return }
        // The ends exactly (a Float slider's end is not the Double it was set from).
        let value: Double
        if slider.value <= slider.minimumValue { value = PhotoFrame.minZoom(photo.size) }
        else if slider.value >= slider.maximumValue { value = PhotoFrame.maxZoom }
        else { value = Double(slider.value) }
        guard placement.zoom > 0 else { return }
        set(placement.zoomed(photo.size, ratio: value / placement.zoom))
    }

    /// The pan and the pinch work together (two fingers moving also move the photo).
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (gestureRecognizer is UIPanGestureRecognizer && other is UIPinchGestureRecognizer)
            || (gestureRecognizer is UIPinchGestureRecognizer && other is UIPanGestureRecognizer)
    }

    // MARK: - Accessibility

    /// "120 percent, moved 10 percent left and 5 percent up": what VoiceOver says for the photo's place.
    static func describe(_ view: PhotoFrame) -> String {
        let zoom = "\(Int((view.zoom * 100).rounded())) percent"
        let x = Int((view.x * 100).rounded()), y = Int((view.y * 100).rounded())
        if x == 0, y == 0 { return zoom + ", centered" }
        var parts: [String] = []
        if x != 0 { parts.append("\(abs(x)) percent \(x < 0 ? "left" : "right")") }
        if y != 0 { parts.append("\(abs(y)) percent \(y < 0 ? "up" : "down")") }
        return zoom + ", moved " + parts.joined(separator: " and ")
    }

    /// Someone who cannot drag moves the photo a twentieth of the frame at a time.
    private func stageActions() -> [UIAccessibilityCustomAction] {
        guard photo != nil, !rendering else { return [] }
        let moves: [(String, Double, Double)] = [("Move Left", -Self.nudge, 0), ("Move Right", Self.nudge, 0),
                                                 ("Move Up", 0, -Self.nudge), ("Move Down", 0, Self.nudge)]
        var actions = moves.map { name, dx, dy in
            UIAccessibilityCustomAction(name: name) { [weak self] _ in
                guard let self, let photo = self.photo else { return false }
                let next = self.placement.panned(photo.size, dx: dx, dy: dy)
                let moved = next != self.placement
                self.set(next)
                HQAnnounce.say(moved ? "Moved" : "At the edge")
                return true
            }
        }
        actions.append(UIAccessibilityCustomAction(name: "Reset") { [weak self] _ in
            self?.doubleTapped()
            return true
        })
        return actions
    }

    override func accessibilityPerformEscape() -> Bool {
        cancel()
        return true
    }

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancel))]
    }

    // MARK: - Leaving

    @objc private func cancel() {
        guard !rendering else { return }
        close(nil)
    }

    @objc private func choose() {
        guard let photo, !rendering, !finished else { return }
        rendering = true
        refreshControls()
        let view = placement, ready = backdrop
        Task { [weak self] in
            let made = await Task.detached(priority: .userInitiated) { () -> (PickedPhoto, Data)? in
                guard let framed = PhotoFramerRenderer.image(photo: photo.image, view: view, backdrop: ready?.image),
                      let png = PhotoFramerRenderer.png(framed) else { return nil }
                return (PickedPhoto(image: framed), png)
            }.value
            guard let self, !self.finished else { return }
            self.rendering = false
            guard let made else { return self.close(.failure(.unreadable)) }
            let image = UIImage(cgImage: made.0.image, scale: 1, orientation: .up)
            self.close(.success(FramedPhoto(image: image, dataURL: PhotoFramerRenderer.dataURL(png: made.1))))
        }
    }

    private func close(_ outcome: Outcome) {
        guard !finished else { return }
        finished = true
        load.cancel()
        let completion = self.completion
        let host = presentingViewController
        if let host {
            host.dismiss(animated: true) { completion(outcome) }
        } else {
            completion(outcome)
        }
    }
}

/// The stage: one element for VoiceOver ("Photo"), with the moves someone who cannot drag needs.
private final class PhotoStageView: UIView {
    var actions: () -> [UIAccessibilityCustomAction] = { [] }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .image
    }

    @MainActor required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get { actions() }
        set {}
    }
}

/// Everything but the frame dimmed, and a hairline round the frame: what stays bright is what the bot will wear.
private final class FramerWindowView: UIView {
    var hole: CGRect = .zero { didSet { if hole != oldValue { setNeedsLayout() } } }
    private let dim = CAShapeLayer()
    private let line = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        dim.fillRule = .evenOdd
        dim.fillColor = UIColor.black.withAlphaComponent(0.6).cgColor
        line.fillColor = nil
        line.strokeColor = UIColor.white.withAlphaComponent(0.55).cgColor
        for shape in [dim, line] {
            shape.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull(), "lineWidth": NSNull()]
            layer.addSublayer(shape)
        }
    }

    @MainActor required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        dim.frame = bounds
        line.frame = bounds
        // The app-icon shape: 22.37 % of the side, continuous corners.
        let shape = UIBezierPath(roundedRect: hole, cornerRadius: hole.width * BotFaces.cornerShare)
        let path = UIBezierPath(rect: bounds)
        path.append(shape)
        dim.path = path.cgPath
        line.path = shape.cgPath
        line.lineWidth = 1 / max(1, traitCollection.displayScale)
    }
}

/// The zoom slider: says "120 percent", and steps a tenth of its range for VoiceOver.
private final class ZoomSlider: UISlider {
    override var accessibilityValue: String? {
        get { "\(Int((Double(value) * 100).rounded())) percent" }
        set {}
    }

    override func accessibilityIncrement() { step(1) }
    override func accessibilityDecrement() { step(-1) }

    private func step(_ direction: Float) {
        let next = min(max(value + direction * (maximumValue - minimumValue) / 10, minimumValue), maximumValue)
        guard next != value else { return }
        value = next
        sendActions(for: .valueChanged)
    }
}
