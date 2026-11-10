import UIKit

/// The screenshot inside a computer_use / browser step's sheet (docs/spec/3x-screen.md §5.3): the picture, tap to view
/// it larger, or the note that the gateway no longer has it.
final class StepScreenshotBlock: UIView {
    struct Context {
        var client: any GatewayClient
        var profile: String
        var sessionId: String?
        /// When the step's message was made (unix seconds): a folder listing older than this is read again.
        var completedAt: Double?
    }

    private let shot: ToolScreenshot
    private let context: Context
    private let frameView = UIView()
    private let picture = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let note = UILabel()
    private let link = UIButton(configuration: .plain())
    private var height: NSLayoutConstraint?
    private var task: Task<Void, Never>?
    private var image: UIImage?

    /// `onExpired`: the gateway said the file is gone (the sheet redraws with the note in its Output too).
    init(shot: ToolScreenshot, toolCallId: String, context: Context, expired: Bool, onExpired: @escaping () -> Void) {
        self.shot = shot
        self.context = context
        super.init(frame: .zero)
        let label = UILabel()
        label.text = "Screenshot"
        label.font = HQFont.preferred(.footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = HQPalette.label2
        frameView.backgroundColor = .tertiarySystemFill
        frameView.layer.cornerRadius = HQShape.radius(12, .card)
        frameView.layer.cornerCurve = .continuous
        frameView.clipsToBounds = true
        frameView.isAccessibilityElement = true
        frameView.accessibilityLabel = "Screenshot"
        frameView.accessibilityTraits = [.image, .button]
        frameView.accessibilityHint = "Double tap to view larger"
        frameView.accessibilityIdentifier = "step.screenshot"
        picture.contentMode = .scaleAspectFit
        picture.translatesAutoresizingMaskIntoConstraints = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        frameView.addSubview(picture)
        frameView.addSubview(spinner)
        note.text = ToolScreenshots.expiredNote
        note.font = HQFont.preferred(.subheadline)
        note.adjustsFontForContentSizeCategory = true
        note.numberOfLines = 0
        note.textColor = HQPalette.label2
        note.accessibilityIdentifier = "step.screenshot.expired"
        link.configuration?.title = "Open image: \(shot.fileName)"
        link.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0)
        link.contentHorizontalAlignment = .leading
        link.accessibilityIdentifier = "step.screenshot.open"
        link.addAction(UIAction { [weak self] _ in self?.load() }, for: .primaryActionTriggered)
        let stack = UIStackView(arrangedSubviews: [label, frameView, note, link])
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let tall = frameView.heightAnchor.constraint(equalToConstant: 180)
        height = tall
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            picture.leadingAnchor.constraint(equalTo: frameView.leadingAnchor), picture.trailingAnchor.constraint(equalTo: frameView.trailingAnchor),
            picture.topAnchor.constraint(equalTo: frameView.topAnchor), picture.bottomAnchor.constraint(equalTo: frameView.bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: frameView.centerXAnchor), spinner.centerYAnchor.constraint(equalTo: frameView.centerYAnchor),
            tall,
        ])
        frameView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(open)))
        note.isHidden = true
        link.isHidden = true
        if expired || shot.expired {
            showExpired()
        } else {
            load()
            if !shot.isInline, let expiry = ScreenHooks.expiry() {
                let path = shot.source, at = context.completedAt
                Task { [weak self] in
                    guard await expiry.check(toolCallId: toolCallId, path: path, completedAt: at) else { return }
                    guard self?.window != nil || self?.superview != nil else { return }
                    onExpired()
                }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit { task?.cancel() }

    private func showExpired() {
        task?.cancel()
        frameView.isHidden = true
        link.isHidden = true
        note.isHidden = false
    }

    private func load() {
        task?.cancel()
        link.isHidden = true
        frameView.isHidden = false
        spinner.startAnimating()
        let shot = self.shot, context = self.context
        let pixels = Int(max(600, (window?.bounds.width ?? 430) * 2))
        task = Task { [weak self] in
            let loaded: UIImage?
            if shot.isInline {
                loaded = await Self.decodeInline(shot.source)
            } else {
                loaded = try? await ActivityMedia.loadImage(context.client, shot.source, context.profile, context.sessionId, pixels)
            }
            guard let self, !Task.isCancelled, note.isHidden else { return }
            spinner.stopAnimating()
            guard let loaded, loaded.size.width > 0 else {
                // The listing said nothing and the picture would not load: a link that tries again.
                frameView.isHidden = true
                link.isHidden = false
                return
            }
            image = loaded
            picture.image = loaded
            let width = max(1, bounds.width > 0 ? bounds.width : (window?.bounds.width ?? 400) - 32)
            height?.constant = min(260, max(80, width * loaded.size.height / loaded.size.width))
        }
    }

    @concurrent private static func decodeInline(_ source: String) async -> UIImage? {
        guard let comma = source.firstIndex(of: ","),
              let data = Data(base64Encoded: String(source[source.index(after: comma)...]), options: .ignoreUnknownCharacters),
              let image = UIImage(data: data) else { return nil }
        return image.preparingForDisplay() ?? image
    }

    @objc private func open() {
        guard let image else { return }
        let shot = self.shot, context = self.context
        let full: (() async throws -> UIImage)? = shot.isInline ? nil : {
            try await ActivityMedia.loadFull(context.client, shot.source, context.profile, context.sessionId)
        }
        let media = MediaContext(accountId: context.client.account.id, profile: context.profile, storedSessionId: context.sessionId)
        ActivityMedia.present(from: picture, image: image, path: shot.isInline ? "screenshot.png" : shot.source,
                              context: shot.isInline ? nil : media, loadFull: full)
    }
}
