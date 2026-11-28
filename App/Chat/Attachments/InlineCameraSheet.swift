import AVFoundation
import UIKit

// [#513] Quick inline camera sheet for iPhone (+ -> Camera): embeds a live AVFoundation preview in a fitted rounded
// Liquid Glass panel over the bottom of the chat so the conversation stays visible above. One tap shoots and drops the
// photo straight into the composer attachment tray; the Full Camera button or ••• menu jumps to UIImagePickerController
// when zoom/flash/video controls are needed.

nonisolated enum InlineCameraLogic {
    enum FlashMode: Int, CaseIterable, Equatable, Sendable {
        case auto, on, off

        var next: FlashMode {
            switch self {
            case .auto: .on
            case .on: .off
            case .off: .auto
            }
        }

        var title: String {
            switch self {
            case .auto: "Auto"
            case .on: "On"
            case .off: "Off"
            }
        }

        var symbolName: String {
            switch self {
            case .auto: "bolt.badge.automatic"
            case .on: "bolt.fill"
            case .off: "bolt.slash.fill"
            }
        }

        var avFlashMode: AVCaptureDevice.FlashMode {
            switch self {
            case .auto: .auto
            case .on: .on
            case .off: .off
            }
        }
    }

    struct ZoomPreset: Equatable, Sendable {
        /// Display multiplier (0.5, 1.0, 2.0) relative to wide-angle 1×.
        let display: CGFloat
        /// Actual `AVCaptureDevice.videoZoomFactor` to apply.
        let deviceFactor: CGFloat
        let label: String
    }

    /// Use the compact inline camera sheet on iPhone; Mac and iPad keep the standard system camera picker.
    static func shouldUseInlineCamera(isMac: Bool, isPad: Bool, hasCamera: Bool) -> Bool {
        !isMac && !isPad && hasCamera
    }

    /// Zoom pills shown inside the viewfinder. Virtual multi-cam devices report `1.0` as the ultra-wide lens and
    /// `switchOverFactor` (typically `2.0`) as the standard wide 1× lens.
    static func zoomPresets(minFactor: CGFloat, maxFactor: CGFloat, wideFactor: CGFloat, isFront: Bool) -> [ZoomPreset] {
        guard !isFront, maxFactor > minFactor else { return [] }
        let safeWide = max(minFactor, wideFactor)
        var presets: [ZoomPreset] = []
        if safeWide >= 1.8 && minFactor <= 1.05 {
            presets.append(ZoomPreset(display: 0.5, deviceFactor: minFactor, label: ".5"))
        }
        presets.append(ZoomPreset(display: 1.0, deviceFactor: min(safeWide, maxFactor), label: "1×"))
        let twoX = safeWide * 2.0
        if twoX <= maxFactor {
            presets.append(ZoomPreset(display: 2.0, deviceFactor: twoX, label: "2"))
        }
        return presets.count >= 2 ? presets : []
    }

    static func clampedZoom(_ requested: CGFloat, min minFactor: CGFloat, max maxFactor: CGFloat) -> CGFloat {
        let ceiling = Swift.min(maxFactor, max(minFactor, 8.0))
        return Swift.min(ceiling, Swift.max(minFactor, requested))
    }
}

@MainActor final class InlineCameraSheet: UIViewController, AVCapturePhotoCaptureDelegate {
    private let onCaptured: (UIImage) -> Void
    private let onOpenFullCamera: () -> Void
    private let onError: (String) -> Void

    private let sessionQueue = DispatchQueue(label: "ai.hermes.hqnative.inline-camera", qos: .userInitiated)
    nonisolated(unsafe) private let captureSession = AVCaptureSession()
    nonisolated(unsafe) private let photoOutput = AVCapturePhotoOutput()
    nonisolated(unsafe) private var activeInput: AVCaptureDeviceInput?
    nonisolated(unsafe) private var activeDevice: AVCaptureDevice?

    private var position: AVCaptureDevice.Position = .back
    private var flashMode: InlineCameraLogic.FlashMode = .auto
    private var showGrid = false
    private var isCapturing = false
    private var zoomPresets: [InlineCameraLogic.ZoomPreset] = []
    private var currentZoomFactor: CGFloat = 1.0
    private var pinchBaseZoom: CGFloat = 1.0
    private var watchesStyle = false

    private let viewfinderBox = UIView()
    private let previewView = CameraPreviewView()
    private let gridView = CameraGridOverlayView()
    private let focusReticle = UIView()
    private let flashVeil = UIView()
    private let statusLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let flashButton = UIButton(type: .system)
    private let moreButton = UIButton(type: .system)
    private let zoomPillBar = UIStackView()
    private let fullCameraButton = UIButton(type: .system)
    private let shutterButton = ShutterControlButton()
    private let flipButton = UIButton(type: .system)

    /// Fitted sheet height: keeps ~45% of the chat visible above on iPhone.
    static let sheetHeight: CGFloat = 418

    init(onCaptured: @escaping (UIImage) -> Void,
         onOpenFullCamera: @escaping () -> Void,
         onError: @escaping (String) -> Void) {
        self.onCaptured = onCaptured
        self.onOpenFullCamera = onOpenFullCamera
        self.onError = onError
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController {
            let fitted = UISheetPresentationController.Detent.custom(identifier: .init("inline-camera-fit")) { ctx in
                min(Self.sheetHeight, ctx.maximumDetentValue)
            }
            sheet.detents = [fitted]
            sheet.prefersGrabberVisible = false
            sheet.preferredCornerRadius = 34
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = HQPalette.sheetPage
        view.accessibilityIdentifier = "inline-camera.sheet"
        buildUI()
        configureGestures()
        updateControls()
        startCameraIfAvailable()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        guard let sheet = sheetPresentationController else { return }
        sheet.hqGlassPage()
        if !watchesStyle {
            watchesStyle = true
            registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (page: InlineCameraSheet, _) in
                page.sheetPresentationController?.hqGlassPage()
                page.applyTheme()
            }
        }
        applyTheme()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopSession()
    }

    // MARK: - Layout

    private func buildUI() {
        let padding: CGFloat = 12

        viewfinderBox.translatesAutoresizingMaskIntoConstraints = false
        viewfinderBox.backgroundColor = .black
        viewfinderBox.layer.cornerRadius = 26
        viewfinderBox.layer.cornerCurve = .continuous
        viewfinderBox.clipsToBounds = true
        viewfinderBox.layer.borderWidth = 0.5
        viewfinderBox.layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
        viewfinderBox.accessibilityIdentifier = "inline-camera.viewfinder"
        view.addSubview(viewfinderBox)

        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewView.previewLayer.session = captureSession
        previewView.previewLayer.videoGravity = .resizeAspectFill
        viewfinderBox.addSubview(previewView)

        gridView.translatesAutoresizingMaskIntoConstraints = false
        gridView.isHidden = true
        gridView.isUserInteractionEnabled = false
        viewfinderBox.addSubview(gridView)

        focusReticle.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
        focusReticle.layer.borderWidth = 1.5
        focusReticle.layer.borderColor = UIColor.systemYellow.withAlphaComponent(0.9).cgColor
        focusReticle.layer.cornerRadius = 10
        focusReticle.layer.cornerCurve = .continuous
        focusReticle.alpha = 0
        focusReticle.isUserInteractionEnabled = false
        viewfinderBox.addSubview(focusReticle)

        flashVeil.translatesAutoresizingMaskIntoConstraints = false
        flashVeil.backgroundColor = .white
        flashVeil.alpha = 0
        flashVeil.isUserInteractionEnabled = false
        viewfinderBox.addSubview(flashVeil)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = HQFont.style(.footnote, weight: .medium)
        statusLabel.textColor = UIColor.white.withAlphaComponent(0.75)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        statusLabel.isHidden = true
        viewfinderBox.addSubview(statusLabel)

        // Top floating glass controls inside viewfinder
        configureGlassPill(closeButton, symbol: "xmark", title: nil)
        closeButton.accessibilityLabel = "Close camera"
        closeButton.accessibilityIdentifier = "inline-camera.close"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        viewfinderBox.addSubview(closeButton)

        configureGlassPill(flashButton, symbol: flashMode.symbolName, title: flashMode.title)
        flashButton.accessibilityLabel = "Flash"
        flashButton.accessibilityIdentifier = "inline-camera.flash"
        flashButton.addTarget(self, action: #selector(flashTapped), for: .touchUpInside)
        viewfinderBox.addSubview(flashButton)

        configureGlassPill(moreButton, symbol: "ellipsis", title: nil)
        moreButton.accessibilityLabel = "More camera options"
        moreButton.accessibilityIdentifier = "inline-camera.more"
        moreButton.showsMenuAsPrimaryAction = true
        viewfinderBox.addSubview(moreButton)

        // Zoom pill strip at bottom of viewfinder
        let zoomBackdrop = UIView()
        zoomBackdrop.translatesAutoresizingMaskIntoConstraints = false
        zoomBackdrop.backgroundColor = UIColor.black.withAlphaComponent(0.48)
        zoomBackdrop.layer.cornerRadius = 15
        zoomBackdrop.layer.borderWidth = 0.5
        zoomBackdrop.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
        zoomBackdrop.tag = 901
        viewfinderBox.addSubview(zoomBackdrop)

        zoomPillBar.translatesAutoresizingMaskIntoConstraints = false
        zoomPillBar.axis = .horizontal
        zoomPillBar.spacing = 4
        zoomPillBar.alignment = .center
        zoomBackdrop.addSubview(zoomPillBar)

        // Bottom control row (Full Camera, Shutter, Flip)
        let controls = UIView()
        controls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controls)

        configureBottomDisc(fullCameraButton, symbol: "arrow.up.left.and.arrow.down.right")
        fullCameraButton.accessibilityLabel = "Open full camera"
        fullCameraButton.accessibilityIdentifier = "inline-camera.full"
        fullCameraButton.addTarget(self, action: #selector(fullCameraTapped), for: .touchUpInside)
        controls.addSubview(fullCameraButton)

        shutterButton.translatesAutoresizingMaskIntoConstraints = false
        shutterButton.accessibilityLabel = "Take photo"
        shutterButton.accessibilityIdentifier = "inline-camera.shutter"
        shutterButton.addTarget(self, action: #selector(shutterTapped), for: .touchUpInside)
        controls.addSubview(shutterButton)

        configureBottomDisc(flipButton, symbol: "arrow.triangle.2.circlepath")
        flipButton.accessibilityLabel = "Switch camera"
        flipButton.accessibilityIdentifier = "inline-camera.flip"
        flipButton.addTarget(self, action: #selector(flipTapped), for: .touchUpInside)
        controls.addSubview(flipButton)

        NSLayoutConstraint.activate([
            viewfinderBox.topAnchor.constraint(equalTo: view.topAnchor, constant: padding),
            viewfinderBox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: padding),
            viewfinderBox.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -padding),
            viewfinderBox.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -10),

            previewView.topAnchor.constraint(equalTo: viewfinderBox.topAnchor),
            previewView.leadingAnchor.constraint(equalTo: viewfinderBox.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: viewfinderBox.trailingAnchor),
            previewView.bottomAnchor.constraint(equalTo: viewfinderBox.bottomAnchor),

            gridView.topAnchor.constraint(equalTo: viewfinderBox.topAnchor),
            gridView.leadingAnchor.constraint(equalTo: viewfinderBox.leadingAnchor),
            gridView.trailingAnchor.constraint(equalTo: viewfinderBox.trailingAnchor),
            gridView.bottomAnchor.constraint(equalTo: viewfinderBox.bottomAnchor),

            flashVeil.topAnchor.constraint(equalTo: viewfinderBox.topAnchor),
            flashVeil.leadingAnchor.constraint(equalTo: viewfinderBox.leadingAnchor),
            flashVeil.trailingAnchor.constraint(equalTo: viewfinderBox.trailingAnchor),
            flashVeil.bottomAnchor.constraint(equalTo: viewfinderBox.bottomAnchor),

            statusLabel.centerXAnchor.constraint(equalTo: viewfinderBox.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: viewfinderBox.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: viewfinderBox.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: viewfinderBox.trailingAnchor, constant: -24),

            closeButton.topAnchor.constraint(equalTo: viewfinderBox.topAnchor, constant: 12),
            closeButton.leadingAnchor.constraint(equalTo: viewfinderBox.leadingAnchor, constant: 12),
            closeButton.heightAnchor.constraint(equalToConstant: 34),
            closeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 34),

            moreButton.topAnchor.constraint(equalTo: viewfinderBox.topAnchor, constant: 12),
            moreButton.trailingAnchor.constraint(equalTo: viewfinderBox.trailingAnchor, constant: -12),
            moreButton.heightAnchor.constraint(equalToConstant: 34),
            moreButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 34),

            flashButton.centerYAnchor.constraint(equalTo: moreButton.centerYAnchor),
            flashButton.trailingAnchor.constraint(equalTo: moreButton.leadingAnchor, constant: -8),
            flashButton.heightAnchor.constraint(equalToConstant: 34),

            zoomBackdrop.centerXAnchor.constraint(equalTo: viewfinderBox.centerXAnchor),
            zoomBackdrop.bottomAnchor.constraint(equalTo: viewfinderBox.bottomAnchor, constant: -12),
            zoomBackdrop.heightAnchor.constraint(equalToConstant: 30),

            zoomPillBar.topAnchor.constraint(equalTo: zoomBackdrop.topAnchor, constant: 3),
            zoomPillBar.bottomAnchor.constraint(equalTo: zoomBackdrop.bottomAnchor, constant: -3),
            zoomPillBar.leadingAnchor.constraint(equalTo: zoomBackdrop.leadingAnchor, constant: 4),
            zoomPillBar.trailingAnchor.constraint(equalTo: zoomBackdrop.trailingAnchor, constant: -4),

            controls.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            controls.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            controls.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
            controls.heightAnchor.constraint(equalToConstant: 66),

            shutterButton.centerXAnchor.constraint(equalTo: controls.centerXAnchor),
            shutterButton.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            shutterButton.widthAnchor.constraint(equalToConstant: 64),
            shutterButton.heightAnchor.constraint(equalToConstant: 64),

            fullCameraButton.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
            fullCameraButton.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            fullCameraButton.widthAnchor.constraint(equalToConstant: 44),
            fullCameraButton.heightAnchor.constraint(equalToConstant: 44),

            flipButton.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
            flipButton.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            flipButton.widthAnchor.constraint(equalToConstant: 44),
            flipButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    private func configureGlassPill(_ button: UIButton, symbol: String, title: String?) {
        button.translatesAutoresizingMaskIntoConstraints = false
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        config.title = title
        config.imagePadding = title == nil ? 0 : 5
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: title == nil ? 9 : 11, bottom: 0, trailing: title == nil ? 9 : 11)
        config.baseForegroundColor = .white
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = HQFont.style(.caption1, weight: .semibold)
            return out
        }
        button.configuration = config
        button.backgroundColor = UIColor.black.withAlphaComponent(0.50)
        button.layer.cornerRadius = 17
        button.layer.borderWidth = 0.5
        button.layer.borderColor = UIColor.white.withAlphaComponent(0.22).cgColor
    }

    private func configureBottomDisc(_ button: UIButton, symbol: String) {
        button.translatesAutoresizingMaskIntoConstraints = false
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium))
        button.configuration = config
        button.layer.cornerRadius = 22
        button.layer.borderWidth = 0.5
    }

    private func applyTheme() {
        let dark = traitCollection.userInterfaceStyle == .dark
        let discBg = dark ? UIColor.white.withAlphaComponent(0.12) : UIColor.black.withAlphaComponent(0.07)
        let discFg: UIColor = dark ? .white : .label
        let discEdge = dark ? UIColor.white.withAlphaComponent(0.16) : UIColor.black.withAlphaComponent(0.10)
        for button in [fullCameraButton, flipButton] {
            button.backgroundColor = discBg
            button.tintColor = discFg
            button.configuration?.baseForegroundColor = discFg
            button.layer.borderColor = discEdge.cgColor
        }
        shutterButton.applyAppearance(dark: dark)
    }

    private func configureGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(viewfinderTapped(_:)))
        previewView.addGestureRecognizer(tap)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(viewfinderPinched(_:)))
        previewView.addGestureRecognizer(pinch)
    }

    // MARK: - Camera Lifecycle

    private func startCameraIfAvailable() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            statusLabel.text = "Camera preview unavailable"
            statusLabel.isHidden = false
            shutterButton.isEnabled = false
            return
        }
        let targetPosition = position
        sessionQueue.async { [weak self] in
            self?.configureSession(position: targetPosition)
        }
    }

    nonisolated private func configureSession(position: AVCaptureDevice.Position) {
        guard let device = Self.bestCamera(for: position),
              let input = try? AVCaptureDeviceInput(device: device) else {
            Task { @MainActor [weak self] in
                self?.statusLabel.text = "Couldn’t start the camera."
                self?.statusLabel.isHidden = false
                self?.shutterButton.isEnabled = false
            }
            return
        }
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .photo
        if let existing = activeInput {
            captureSession.removeInput(existing)
            activeInput = nil
        }
        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
            activeInput = input
            activeDevice = device
        }
        if !captureSession.outputs.contains(photoOutput), captureSession.canAddOutput(photoOutput) {
            captureSession.addOutput(photoOutput)
        }
        captureSession.commitConfiguration()

        let minFactor = device.minAvailableVideoZoomFactor
        let maxFactor = device.maxAvailableVideoZoomFactor
        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) }
        let wideFactor: CGFloat = (position == .back && device.constituentDevices.count > 1 && switchOvers.first != nil)
            ? switchOvers[0]
            : minFactor
        if wideFactor > minFactor, (try? device.lockForConfiguration()) != nil {
            device.videoZoomFactor = wideFactor
            device.unlockForConfiguration()
        }
        let hasFlash = device.hasFlash
        if !captureSession.isRunning { captureSession.startRunning() }
        let presets = InlineCameraLogic.zoomPresets(minFactor: minFactor, maxFactor: maxFactor,
                                                    wideFactor: wideFactor, isFront: position == .front)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.statusLabel.isHidden = true
            self.shutterButton.isEnabled = true
            self.flashButton.isHidden = !hasFlash
            self.currentZoomFactor = wideFactor
            self.zoomPresets = presets
            self.rebuildZoomPills()
            self.updateControls()
        }
    }

    nonisolated private static func bestCamera(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        if position == .back {
            let types: [AVCaptureDevice.DeviceType] = [
                .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera,
            ]
            return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .back).devices.first
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
    }

    private func stopSession() {
        let session = captureSession
        sessionQueue.async {
            if session.isRunning { session.stopRunning() }
        }
    }

    // MARK: - Controls & Menu

    private func updateControls() {
        var flashConfig = flashButton.configuration
        flashConfig?.image = UIImage(systemName: flashMode.symbolName,
                                     withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        flashConfig?.title = flashMode.title
        flashConfig?.baseForegroundColor = flashMode == .on ? .systemYellow : .white
        flashButton.configuration = flashConfig
        flashButton.backgroundColor = flashMode == .on
            ? UIColor.systemYellow.withAlphaComponent(0.24)
            : UIColor.black.withAlphaComponent(0.50)
        flashButton.layer.borderColor = (flashMode == .on
            ? UIColor.systemYellow.withAlphaComponent(0.65)
            : UIColor.white.withAlphaComponent(0.22)).cgColor
        flashButton.accessibilityValue = flashMode.title

        gridView.isHidden = !showGrid
        moreButton.menu = UIMenu(children: [
            UIAction(title: "Full Camera…", image: UIImage(systemName: "arrow.up.left.and.arrow.down.right")) { [weak self] _ in
                self?.fullCameraTapped()
            },
            UIAction(title: "Grid Overlay", image: UIImage(systemName: "grid"), state: showGrid ? .on : .off) { [weak self] _ in
                guard let self else { return }
                Haptics.play(.selection)
                self.showGrid.toggle()
                self.updateControls()
            },
            UIAction(title: "Switch Camera", image: UIImage(systemName: "arrow.triangle.2.circlepath.camera")) { [weak self] _ in
                self?.flipTapped()
            },
        ])
    }

    private func rebuildZoomPills() {
        zoomPillBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let backdrop = viewfinderBox.viewWithTag(901)
        backdrop?.isHidden = zoomPresets.isEmpty
        for (index, preset) in zoomPresets.enumerated() {
            let button = UIButton(type: .system)
            button.tag = index
            button.setTitle(preset.label, for: .normal)
            button.titleLabel?.font = HQFont.style(.caption2, weight: .semibold)
            button.layer.cornerRadius = 12
            button.contentEdgeInsets = UIEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
            button.addTarget(self, action: #selector(zoomPillTapped(_:)), for: .touchUpInside)
            zoomPillBar.addArrangedSubview(button)
        }
        highlightClosestZoomPill()
    }

    private func highlightClosestZoomPill() {
        guard !zoomPresets.isEmpty else { return }
        let bestIndex = zoomPresets.enumerated().min {
            abs($0.element.deviceFactor - currentZoomFactor) < abs($1.element.deviceFactor - currentZoomFactor)
        }?.offset ?? 0
        for case let button as UIButton in zoomPillBar.arrangedSubviews {
            let active = button.tag == bestIndex
            button.backgroundColor = active ? UIColor.white.withAlphaComponent(0.24) : .clear
            button.setTitleColor(active ? .systemYellow : UIColor.white.withAlphaComponent(0.85), for: .normal)
        }
    }

    // MARK: - Actions

    @objc private func closeTapped() {
        Haptics.play(.light)
        dismiss(animated: true)
    }

    @objc private func flashTapped() {
        Haptics.play(.selection)
        flashMode = flashMode.next
        updateControls()
    }

    @objc private func flipTapped() {
        Haptics.play(.selection)
        position = (position == .back) ? .front : .back
        let next = position
        sessionQueue.async { [weak self] in
            self?.configureSession(position: next)
        }
    }

    @objc private func fullCameraTapped() {
        Haptics.play(.light)
        let openFull = onOpenFullCamera
        stopSession()
        dismiss(animated: true) {
            openFull()
        }
    }

    @objc private func zoomPillTapped(_ sender: UIButton) {
        guard sender.tag >= 0, sender.tag < zoomPresets.count else { return }
        Haptics.play(.selection)
        applyZoom(zoomPresets[sender.tag].deviceFactor)
    }

    @objc private func viewfinderTapped(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: previewView)
        let devicePoint = previewView.previewLayer.captureDevicePointConverted(fromLayerPoint: point)
        focusReticle.center = point
        focusReticle.transform = CGAffineTransform(scaleX: 1.25, y: 1.25)
        focusReticle.alpha = 1
        UIView.animate(withDuration: 0.22, delay: 0, options: .curveEaseOut) {
            self.focusReticle.transform = .identity
        } completion: { _ in
            UIView.animate(withDuration: 0.25, delay: 0.55) { self.focusReticle.alpha = 0 }
        }
        sessionQueue.async { [weak self] in
            guard let device = self?.activeDevice, (try? device.lockForConfiguration()) != nil else { return }
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = devicePoint
                if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = devicePoint
                if device.isExposureModeSupported(.autoExpose) { device.exposureMode = .autoExpose }
            }
            device.unlockForConfiguration()
        }
    }

    @objc private func viewfinderPinched(_ recognizer: UIPinchGestureRecognizer) {
        if recognizer.state == .began { pinchBaseZoom = currentZoomFactor }
        guard recognizer.state == .changed else { return }
        applyZoom(pinchBaseZoom * recognizer.scale)
    }

    private func applyZoom(_ requested: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let device = self?.activeDevice else { return }
            let clamped = InlineCameraLogic.clampedZoom(requested, min: device.minAvailableVideoZoomFactor,
                                                        max: device.maxAvailableVideoZoomFactor)
            guard (try? device.lockForConfiguration()) != nil else { return }
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
            Task { @MainActor [weak self] in
                self?.currentZoomFactor = clamped
                self?.highlightClosestZoomPill()
            }
        }
    }

    @objc private func shutterTapped() {
        guard !isCapturing else { return }
        isCapturing = true
        shutterButton.isEnabled = false
        Haptics.play(.medium)

        // Crisp shutter flash feedback
        flashVeil.alpha = 0.85
        UIView.animate(withDuration: 0.20) { self.flashVeil.alpha = 0 }

        let desiredFlash = flashMode.avFlashMode
        let rotationAngle: CGFloat = 90
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let settings = AVCapturePhotoSettings()
            if let device = self.activeDevice, device.hasFlash,
               self.photoOutput.supportedFlashModes.contains(desiredFlash) {
                settings.flashMode = desiredFlash
            }
            if let connection = self.photoOutput.connection(with: .video),
               connection.isVideoRotationAngleSupported(rotationAngle) {
                connection.videoRotationAngle = rotationAngle
            }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    // MARK: - AVCapturePhotoCaptureDelegate

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: (any Error)?) {
        let data = error == nil ? photo.fileDataRepresentation() : nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isCapturing = false
            guard let data, let image = UIImage(data: data) else {
                self.shutterButton.isEnabled = true
                AppLog.note("attach", "inline camera capture failed")
                self.onError(AttachmentPrepareError.cameraNotSaved.errorDescription ?? "Couldn’t save the camera photo.")
                return
            }
            AppLog.trace("attach", "inline camera photo captured")
            let captured = self.onCaptured
            self.stopSession()
            self.dismiss(animated: true) {
                captured(image)
            }
        }
    }
}

private final class CameraPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

private final class CameraGridOverlayView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.32).cgColor)
        ctx.setLineWidth(0.75)
        for i in 1...2 {
            let x = rect.width * CGFloat(i) / 3
            ctx.move(to: CGPoint(x: x, y: 0))
            ctx.addLine(to: CGPoint(x: x, y: rect.height))
            let y = rect.height * CGFloat(i) / 3
            ctx.move(to: CGPoint(x: 0, y: y))
            ctx.addLine(to: CGPoint(x: rect.width, y: y))
        }
        ctx.strokePath()
    }
}

private final class ShutterControlButton: UIControl {
    private let ring = UIView()
    private let inner = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        ring.isUserInteractionEnabled = false
        ring.layer.borderWidth = 3.5
        ring.layer.cornerRadius = 32
        addSubview(ring)

        inner.isUserInteractionEnabled = false
        inner.layer.cornerRadius = 26
        addSubview(inner)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        ring.frame = bounds
        ring.layer.cornerRadius = bounds.width / 2
        let inset: CGFloat = 6
        inner.frame = bounds.insetBy(dx: inset, dy: inset)
        inner.layer.cornerRadius = inner.bounds.width / 2
    }

    func applyAppearance(dark: Bool) {
        let color: UIColor = dark ? .white : .label
        ring.layer.borderColor = color.cgColor
        inner.backgroundColor = color
    }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.1) {
                self.inner.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.88, y: 0.88) : .identity
            }
        }
    }
}
