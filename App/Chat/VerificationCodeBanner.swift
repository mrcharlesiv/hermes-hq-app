import UIKit

// Inline verification-code AutoFill bar shown above the chat composer when an agent's latest message asks for an email,
// SMS, or authenticator one-time code. A real `UITextField` with `textContentType = .oneTimeCode` and default
// autocorrection reliably surfaces iOS and macOS "From Messages" / "From Mail" AutoFill suggestions above the keyboard
// (or at the cursor on Mac) and sends the code directly into the chat on Send / Return.

@MainActor final class VerificationCodeBanner: UIView, UITextFieldDelegate {
    static let identifier = "composer.verificationCode"

    /// The assistant message this bar is answering (kept so refreshes don't disturb focus or typed input).
    let messageId: String
    var onSend: ((String) -> Void)?
    var onDismiss: (() -> Void)?

    let codeField = UITextField()
    private let sendButton: UIButton
    private let dismissButton: UIButton
    private let glass: UIVisualEffectView = {
        let view = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        view.cornerConfiguration = .capsule()
        return view
    }()
    private let veil = UIView()

    init(messageId: String) {
        self.messageId = messageId

        var sendConfig = UIButton.Configuration.plain()
        sendConfig.title = "Send"
        sendConfig.titleLineBreakMode = .byClipping
        sendConfig.baseForegroundColor = ChatPalette.tintText
        sendConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = .menusFont(.footnote, weight: .semibold)
            return out
        }
        sendButton = UIButton(configuration: sendConfig)

        var dismissConfig = UIButton.Configuration.plain()
        dismissConfig.image = UIImage(systemName: "xmark",
                                      withConfiguration: UIImage.SymbolConfiguration(textStyle: .footnote, scale: .medium))
        dismissConfig.baseForegroundColor = ChatPalette.label2
        dismissButton = UIButton(configuration: dismissConfig)

        super.init(frame: .zero)
        accessibilityIdentifier = Self.identifier

        if DeviceWord.isMac {
            veil.isUserInteractionEnabled = false
            veil.backgroundColor = ChatPalette.page
            veil.cornerConfiguration = .capsule()
            veil.translatesAutoresizingMaskIntoConstraints = false
            addSubview(veil)
            NSLayoutConstraint.activate([
                veil.topAnchor.constraint(equalTo: topAnchor, constant: 1),
                veil.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
                veil.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
                veil.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            ])
        }

        addSubview(glass)
        glass.translatesAutoresizingMaskIntoConstraints = false

        let icon = UIImageView(image: UIImage(systemName: "key.fill",
                                              withConfiguration: UIImage.SymbolConfiguration(textStyle: .footnote, scale: .medium)))
        icon.tintColor = ChatPalette.tintText
        icon.contentMode = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)

        codeField.font = HQFont.preferred(.subheadline)
        codeField.adjustsFontForContentSizeCategory = true
        codeField.textColor = ChatPalette.label
        codeField.tintColor = ChatPalette.caret
        codeField.textContentType = .oneTimeCode
        codeField.autocorrectionType = .default      // keep QuickType AutoFill bar enabled for Messages / Mail codes
        codeField.autocapitalizationType = .none
        codeField.smartQuotesType = .no
        codeField.smartDashesType = .no
        codeField.spellCheckingType = .no
        codeField.keyboardType = .asciiCapable
        codeField.returnKeyType = .send
        codeField.clearButtonMode = .never
        codeField.attributedPlaceholder = NSAttributedString(
            string: "Verification code",
            attributes: [.foregroundColor: ChatPalette.label2]
        )
        codeField.accessibilityLabel = "Verification code"
        codeField.accessibilityIdentifier = "\(Self.identifier).field"
        codeField.delegate = self
        codeField.addTarget(self, action: #selector(editingChanged), for: .editingChanged)
        codeField.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        codeField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        sendButton.accessibilityLabel = "Send Verification Code"
        sendButton.accessibilityIdentifier = "\(Self.identifier).send"
        sendButton.isEnabled = false
        sendButton.setContentHuggingPriority(.required, for: .horizontal)
        sendButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        sendButton.addAction(UIAction { [weak self] _ in self?.submit() }, for: .primaryActionTriggered)

        dismissButton.accessibilityLabel = "Dismiss Verification Code"
        dismissButton.accessibilityIdentifier = "\(Self.identifier).dismiss"
        dismissButton.setContentHuggingPriority(.required, for: .horizontal)
        dismissButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        dismissButton.addAction(UIAction { [weak self] _ in
            Haptics.play(.selection)
            self?.codeField.resignFirstResponder()
            self?.onDismiss?()
        }, for: .primaryActionTriggered)

        let row = UIStackView(arrangedSubviews: [icon, codeField, sendButton, dismissButton])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(row)

        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            row.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -4),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            codeField.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
            sendButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            dismissButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            dismissButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])

        #if targetEnvironment(macCatalyst)
        PointerEffects.button(sendButton)
        PointerEffects.button(dismissButton)
        #endif
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var trimmedCode: String? {
        let cleaned = VerificationCodePrompt.normalize(codeField.text ?? "")
        return cleaned.isEmpty ? nil : cleaned
    }

    var isSendEnabled: Bool { sendButton.isEnabled }

    func submit() {
        guard let code = trimmedCode else { return }
        Haptics.play(.selection)
        codeField.text = nil
        updateSendState()
        codeField.resignFirstResponder()
        onSend?(code)
    }

    @objc private func editingChanged() {
        updateSendState()
    }

    private func updateSendState() {
        sendButton.isEnabled = trimmedCode != nil
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        submit()
        return false
    }
}
