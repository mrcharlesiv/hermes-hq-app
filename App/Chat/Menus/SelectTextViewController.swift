import UIKit

/// Select Text (spec 1x §9.2; S:ui-chat/select-text-sheet.tsx): a medium sheet with the message as readable text in a
/// selectable, non-editable text view, Done trailing, and Copy All in the bottom toolbar.
final class SelectTextViewController: UIViewController {
    private let text: String
    private let textView = UITextView()
    private let errorLabel = UILabel()

    init(text: String) {
        self.text = text
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    static func make(text: String) -> UINavigationController {
        let root = SelectTextViewController(text: text)
        root.title = "Select Text"
        root.navigationItem.largeTitleDisplayMode = .never
        // The ✕ leading, as every sheet's bar (ChatSheet.wrap).
        let done = UIBarButtonItem.hqClose(action: UIAction { [weak root] _ in root?.dismiss(animated: true) })
        done.accessibilityIdentifier = "select.done"
        root.navigationItem.hqPlaceClose(done)   // [mac] Stress test 2026-10-28 #55: trailing on the Mac
        let navigation = UINavigationController(rootViewController: root)
        SheetStyle.apply(navigation, from: nil)   // UX study #161: a form sheet in two panes
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.hqPreferLargeAtAccessibilitySizes()   // [a11y]
            sheet.prefersGrabberVisible = false
            // [glass] One block of selectable text across the whole page: it stays on the opaque page, not glass.
            sheet.hqOpaqueGroupedPage()   // solid-ok: one block of selectable text, no cards to hold it
        }
        return navigation
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = HQPalette.groupedPage
        textView.text = text
        textView.font = HQFont.preferred(.body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = ChatPalette.label
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.dataDetectorTypes = []
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 16, bottom: 16, right: 16)
        textView.textContainer.lineFragmentPadding = 0
        textView.accessibilityIdentifier = "select.text"
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        errorLabel.font = HQFont.preferred(.footnote)
        errorLabel.adjustsFontForContentSizeCategory = true
        errorLabel.textColor = .systemRed
        errorLabel.textAlignment = .center
        errorLabel.isHidden = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(errorLabel)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: errorLabel.topAnchor, constant: -4),
            errorLabel.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            errorLabel.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            errorLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -4),
        ])
        let copyAll = UIBarButtonItem(title: "Copy All", primaryAction: UIAction { [weak self] _ in self?.copyAll() })
        copyAll.accessibilityIdentifier = "select.copy-all"
        toolbarItems = [.flexibleSpace(), copyAll, .flexibleSpace()]
        navigationController?.isToolbarHidden = false
    }

    private func copyAll() {
        UIPasteboard.general.string = text
        guard UIPasteboard.general.hasStrings else {
            errorLabel.text = "Couldn’t copy this message."
            errorLabel.isHidden = false
            return
        }
        errorLabel.isHidden = true
        Haptics.play(.success)
        MenusHUD.show("Copied", in: view)
    }
}
