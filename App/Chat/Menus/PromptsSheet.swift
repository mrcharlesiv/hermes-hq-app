// ⋯ › Prompts: the prompt library (`PromptLibrary`, on this device, shared by every bot and chat). A tap puts a prompt in
// the message box and closes the sheet; + writes a new one; Edit deletes and reorders; the message being written can be
// saved from the top row. A prompt's hold menu: Put in Message Box, Edit…, Copy, Delete.

import SwiftUI
import UIKit

@MainActor
enum PromptsSheet {
    /// `draft`: the message box's text now (offered as "Save Current Message"); `insert` puts a prompt in it.
    static func make(library: PromptLibrary = .shared, draft: String, insert: @escaping (String) -> Void) -> UINavigationController {
        let model = PromptsPageModel(library: library, draft: draft, insert: insert)
        let page = MorePageController(title: "Prompts", identifier: "prompts.page", PromptsView(model: model))
        model.host = page
        page.retained = [model]
        let add = UIBarButtonItem(systemItem: .add, primaryAction: UIAction { [weak model] _ in model?.edit(nil) })
        add.accessibilityIdentifier = "prompts.add"
        add.accessibilityLabel = "New Prompt"
        let edit = UIBarButtonItem(title: "Edit", primaryAction: UIAction(title: "Edit") { [weak model] _ in model?.editing.toggle() })
        edit.accessibilityIdentifier = "prompts.edit"
        page.navigationItem.rightBarButtonItems = [add, edit]
        followEdit(edit, model: model)
        return ChatSheet.wrap(page, title: "Prompts")
    }

    /// Edit shows only while there is something to edit, and reads Done (prominent) while editing; emptying the list in
    /// Edit ends it. Kept up to date for as long as the button and model live.
    static func followEdit(_ edit: UIBarButtonItem, model: PromptsPageModel) {
        withObservationTracking {
            model.endEditingIfEmpty()
            look(edit, model: model)
        } onChange: { [weak edit, weak model] in
            Task { @MainActor in
                guard let edit, let model else { return }
                followEdit(edit, model: model)
            }
        }
    }

    static func look(_ edit: UIBarButtonItem, model: PromptsPageModel) {
        edit.isHidden = !model.showsEdit
        edit.title = model.editing ? "Done" : "Edit"
        edit.style = model.editing ? .prominent : .plain
    }
}

@MainActor @Observable
final class PromptsPageModel {
    @ObservationIgnored let library: PromptLibrary
    @ObservationIgnored weak var host: UIViewController?
    @ObservationIgnored private let insertText: (String) -> Void
    let draft: String
    var editing = false

    init(library: PromptLibrary, draft: String, insert: @escaping (String) -> Void) {
        self.library = library
        self.draft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        self.insertText = insert
    }

    var prompts: [SavedPrompt] { library.prompts }
    var offersDraft: Bool { !draft.isEmpty && !library.contains(text: draft) }

    func use(_ prompt: SavedPrompt) {
        Haptics.play(.selection)
        let text = prompt.text
        guard let host else { insertText(text); return }
        MenusSheet.close(host) { [insertText] in insertText(text) }
    }

    func saveDraft() {
        library.add(text: draft)
        Haptics.play(.success)
        MenusHUD.show("Saved to Prompts", in: host?.view)   // the hold menu's words for the same save
    }

    /// The editor, for `prompt` or (nil) a new one.
    func edit(_ prompt: SavedPrompt?) {
        let editor = PromptEditorViewController(prompt: prompt) { [library] title, text in
            if let prompt { library.update(prompt.id, title: title, text: text) } else { library.add(title: title, text: text) }
        }
        host?.navigationController?.pushViewController(editor, animated: true)
    }

    func copy(_ prompt: SavedPrompt) {
        UIPasteboard.general.string = prompt.text
        Haptics.play(.success)
        MenusHUD.show("Copied", in: host?.view)
    }

    /// Edit is offered only while there are prompts.
    var showsEdit: Bool { !prompts.isEmpty }

    /// The last prompt deleted in Edit ends Edit (there is nothing left to edit).
    func endEditingIfEmpty() {
        if prompts.isEmpty && editing { editing = false }
    }

    func delete(_ prompt: SavedPrompt) { delete(ids: [prompt.id]) }
    func delete(at offsets: IndexSet) { delete(ids: Set(offsets.map { prompts[$0].id })) }

    /// Every delete (hold menu, swipe, Edit) goes at once and offers "Deleted “Title” · Undo" for 8 s, which puts the
    /// prompts back where they were.
    private func delete(ids: Set<UUID>) {
        let gone = library.delete(ids)
        guard !gone.isEmpty else { return }
        UndoPill.show(label: Self.deletedLabel(gone), duration: 8, in: host?.navigationController ?? host) { [library] in
            library.restore(gone)
        }
    }

    static func deletedLabel(_ gone: [DeletedPrompt]) -> String {
        gone.count == 1 ? "Deleted “\(gone[0].prompt.displayTitle)”" : "Deleted \(gone.count) Prompts"
    }
    func move(from: IndexSet, to: Int) { library.move(from: from, to: to) }
}

struct PromptsView: View {
    @Bindable var model: PromptsPageModel

    var body: some View {
        List {
            if model.offersDraft && !model.editing {
                Section {
                    Button { model.saveDraft() } label: {
                        Label("Save Current Message", systemImage: "square.and.arrow.down").foregroundStyle(Color.hqTint)
                    }
                    .accessibilityIdentifier("prompts.saveDraft")
                } footer: { HQSectionFooter {
                    Text(model.draft).lineLimit(2).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                } }
                .hqSheetRows()
            }
            if model.prompts.isEmpty {
                if !centred {   // [mac] Stress test 2026-10-28 round 9: else drawn over the List, centred (below)
                    emptyState
                    .hqMacEmptyPlacement()   // [mac] Stress test 2026-10-28 #9: the one lift, centred in the sheet, no box
                    .hqMacListedEmptyState(above: model.offersDraft && !model.editing ? 140 : 40)
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("prompts.empty")
                }
            } else {
                Section {
                    ForEach(model.prompts) { prompt in
                        Button { model.use(prompt) } label: { SavedPromptRow(prompt: prompt) }
                            .contextMenu {
                                Button { model.use(prompt) } label: { Label("Put in Message Box", systemImage: "text.insert") }
                                Button { model.edit(prompt) } label: { Label("Edit…", systemImage: "pencil") }
                                Button { model.copy(prompt) } label: { Label("Copy", systemImage: "doc.on.doc") }
                                Button(role: .destructive) { model.delete(prompt) } label: { Label("Delete", systemImage: "trash") }
                            }
                            .swipeActions(edge: .leading) {
                                Button { model.edit(prompt) } label: { Label("Edit", systemImage: "pencil") }.tint(Color.hqTint)
                            }
                            .accessibilityIdentifier("prompts.row.\(prompt.displayTitle)")
                    }
                    .onDelete { model.delete(at: $0) }
                    .onMove { model.move(from: $0, to: $1) }
                } footer: { HQSectionFooter {
                    Text("A \(DeviceWord.tap) puts the prompt in the message box. Kept on this \(DeviceWord.name), for every bot and chat.")
                        .font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                } }
                .hqSheetRows()
            }
        }
        .environment(\.editMode, Binding(get: { model.editing ? .active : .inactive },
                                         set: { model.editing = $0.isEditing }))
        // [mac] Stress test 2026-10-31: with no sections the iOS look's List drew white, where every other sheet is the
        // grouped page's grey; the page colour itself while it is empty (the closest scroll background wins).
        // [mac-audit] Owner 2026-11-02 #8: otherwise, on the Mac, nothing is said here. An `.automatic` here was the
        // closest too, so it won over `hqGroupedPage`'s hidden one: the Desktop Look's sheet (and a dark or coloured
        // page's) was iOS's grey under its bar. The iPhone keeps its `.automatic`.
        .modifier(MacEmptyPromptsPage(on: macEmptyPage))
        .hqGroupedPage()
        .listStyle(.insetGrouped)
        .overlay {
            // [mac] Stress test 2026-10-28 round 9: with nothing else in the sheet the state stands over the empty List,
            // centred in the room under the bar (as a row it sat 53 pt under the bar with 165 pt under its button).
            if centred {
                emptyState.accessibilityIdentifier("prompts.empty")
            }
        }
        .accessibilityIdentifier("prompts.list")
    }

    /// [mac] Stress test 2026-10-28 round 9: the Mac's empty state is drawn over the List, centred, when the sheet has
    /// nothing else (no Save Current Message row above it).
    /// [glass-design] The iOS look's too (`SheetEmptyState`), so it sits in the middle of the sheet as Commands' does.
    private var macEmptyPage: Bool { DeviceWord.isMac && !Theme.isDesktop && model.prompts.isEmpty }

    private var centred: Bool {
        (DeviceWord.isMac || GlassSheetKit.designed) && model.prompts.isEmpty && !(model.offersDraft && !model.editing)
    }

    private var emptyWords: String {
        // [empty-tidy] Owner 2026-11-10 (design pick 9): what the page is for, in a line; New Prompt is the button under it.
        "Keep the prompts you use often here. A \(DeviceWord.tap) puts one in the message box."
    }

    /// [mac] Stress test 2026-10-28 round 8: on the Mac the state is laid out by hand. The system's state, a row in this
    /// short sheet's List, judged its room short and left its symbol out (the only state without one); with the symbol
    /// put back it left the button out instead. The Mac's has all three: symbol, title and words, and New Prompt…
    /// (as New Job…: it opens a form).
    @ViewBuilder private var emptyState: some View {
        if DeviceWord.isMac {
            VStack(spacing: 0) {
                UnavailableTitle("No Prompts Yet", systemImage: "text.book.closed", stacked: true)
                Text(emptyWords)
                    .font(MacType.emptyBodyFont)
                    .foregroundStyle(Color.hqLabel2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    // [mac] Stress test 2026-10-28 round 10: a narrower measure (about 480 pt in the Desktop Look; it
                    // follows the text in both looks), so the words wrap into even lines instead of two long ones and
                    // "Prompt." alone on the last (a 568 pt measure).
                    .frame(maxWidth: HQFont.scaled(370))
                    .padding(.top, 6)
                Button("New Prompt…") { model.edit(nil) }.hqBorderedButtonStyle()
                    .padding(.top, 16)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
        } else if GlassSheetKit.designed {
            // [glass-design] The sheets' one empty state (Commands' measures), its line readable on the glass, and New
            // Prompt as the sheets' solid action, not a tinted button on the glass.
            SheetEmptyState(symbol: "text.book.closed", title: "No Prompts Yet", text: emptyWords) {
                Button("New Prompt") { model.edit(nil) }.hqSheetActionButtonStyle()
            }
        } else {
            ContentUnavailableView {
                UnavailableTitle("No Prompts Yet", systemImage: "text.book.closed")   // [mac] Stress test 2026-10-28 #52
            } description: {
                Text(emptyWords)
            } actions: {
                Button("New Prompt") { model.edit(nil) }.hqBorderedButtonStyle()
            }
        }
    }
}

struct SavedPromptRow: View {
    var prompt: SavedPrompt

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(prompt.displayTitle).foregroundStyle(Color.hqLabel).lineLimit(1)
            if !prompt.preview.isEmpty {
                Text(prompt.preview).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// New Prompt / Edit Prompt: an optional title and the prompt's words; Save once there are words. Typed changes hold the
/// sheet open (no swipe-down or Escape), and Cancel asks before throwing them away.
final class PromptEditorViewController: UIViewController, UITextViewDelegate {
    private let prompt: SavedPrompt?
    private let onSave: (String, String) -> Void
    private let card = UIView()
    private let titleField = UITextField()
    private let textView = UITextView()
    private let placeholder = UILabel()
    private var save: UIBarButtonItem?

    init(prompt: SavedPrompt?, onSave: @escaping (_ title: String, _ text: String) -> Void) {
        self.prompt = prompt
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = prompt == nil ? "New Prompt" : "Edit Prompt"
        view.backgroundColor = HQPalette.sheetPage   // [glass-design] the glass shows around the card at half height
        navigationItem.hidesBackButton = true
        let cancel = UIBarButtonItem.hqClose(.cancel, action: UIAction { [weak self] _ in self?.cancel() })
        cancel.accessibilityIdentifier = "prompt.cancel"
        navigationItem.leftBarButtonItem = cancel
        let save = UIBarButtonItem(systemItem: .save, primaryAction: UIAction { [weak self] _ in self?.commit() })
        save.style = .prominent
        save.accessibilityIdentifier = "prompt.save"
        navigationItem.rightBarButtonItem = save
        self.save = save

        #if targetEnvironment(macCatalyst)
        // [mac] Mac polish #87: the sheets' solid card in the iOS look (white in light, as Tool Calls' rows), not the
        // grouped page's lavender-grey; the Desktop Look's outline and 4 pt corners (it had no box, only the rule).
        paintCard()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (editor: PromptEditorViewController, _) in editor.paintCard() }
        #else
        // [glass-design] The sheets' solid card in the iOS look (the grouped card it had matched the grouped page, so the
        // fields had no visible card at all); the Desktop Look keeps its card.
        card.backgroundColor = GlassSheetKit.designed ? HQPalette.sheetCard : HQPalette.groupedCard
        card.layer.cornerRadius = GlassSheetKit.designed ? GlassSheetKit.cardRadius : 12
        card.layer.cornerCurve = .continuous
        card.hqGlassEdge()
        #endif
        // [glass-design] Placeholders in the card's faintest readable ink (label 3 read 2.5:1 on the card).
        titleField.attributedPlaceholder = NSAttributedString(string: "Title (optional)", attributes: [.foregroundColor: HQPalette.cardNote])
        titleField.text = prompt?.title
        titleField.font = HQFont.preferred(.body)
        titleField.adjustsFontForContentSizeCategory = true
        titleField.textColor = HQPalette.label
        titleField.clearButtonMode = .whileEditing
        titleField.returnKeyType = .next
        titleField.accessibilityIdentifier = "prompt.title"
        titleField.addAction(UIAction { [weak self] _ in self?.textView.becomeFirstResponder() }, for: .editingDidEndOnExit)
        titleField.addAction(UIAction { [weak self] _ in self?.textChanged() }, for: .editingChanged)
        let rule = UIView()
        rule.backgroundColor = HQPalette.separator
        textView.text = prompt?.text
        textView.font = HQFont.preferred(.body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = HQPalette.label
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.delegate = self
        textView.accessibilityIdentifier = "prompt.text"
        textView.accessibilityLabel = "Prompt"
        placeholder.text = "Write the prompt…"
        placeholder.font = HQFont.preferred(.body)
        placeholder.adjustsFontForContentSizeCategory = true
        placeholder.textColor = HQPalette.cardNote
        placeholder.isAccessibilityElement = false     // the look of a placeholder; the text view says "Prompt"

        for v in [card, titleField, rule, textView, placeholder] as [UIView] { v.translatesAutoresizingMaskIntoConstraints = false }
        view.addSubview(card)
        card.addSubview(titleField)
        card.addSubview(rule)
        card.addSubview(textView)
        card.addSubview(placeholder)
        let guide = view.keyboardLayoutGuide
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            card.leadingAnchor.constraint(equalTo: view.readableContentGuide.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: view.readableContentGuide.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: guide.topAnchor, constant: -16),
            titleField.topAnchor.constraint(equalTo: card.topAnchor, constant: 6),
            titleField.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            titleField.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            titleField.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            rule.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 2),
            rule.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            rule.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1 / max(1, traitCollection.displayScale)),
            textView.topAnchor.constraint(equalTo: rule.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            textView.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            textView.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -4),
            placeholder.topAnchor.constraint(equalTo: textView.topAnchor, constant: 10),
            placeholder.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: textView.trailingAnchor),
        ])
        textChanged()
    }

    #if targetEnvironment(macCatalyst)
    private func paintCard() {
        let desktop = Theme.isDesktop
        card.backgroundColor = desktop ? .clear : HQPalette.sheetCard
        card.layer.cornerRadius = desktop ? DesktopRows.radius : GlassSheetKit.cardRadius
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = desktop ? 1 : 0
        card.layer.borderColor = desktop ? HQPalette.stroke.resolvedColor(with: traitCollection).cgColor : nil
    }
    #endif

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let sheet = navigationController?.sheetPresentationController, sheet.selectedDetentIdentifier != .large {
            sheet.animateChanges { sheet.selectedDetentIdentifier = .large }
        }
        textView.becomeFirstResponder()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent { navigationController?.isModalInPresentation = false }
    }

    func textViewDidChange(_ textView: UITextView) { textChanged() }

    /// Anything typed that the saved prompt (or an empty new one) doesn't have.
    private var edited: Bool {
        (titleField.text ?? "") != (prompt?.title ?? "") || (textView.text ?? "") != (prompt?.text ?? "")
    }

    private func textChanged() {
        let empty = textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        placeholder.isHidden = !textView.text.isEmpty
        save?.isEnabled = !empty
        navigationController?.isModalInPresentation = edited
    }

    private func cancel() {
        guard edited else { navigationController?.popViewController(animated: true); return }
        let alert = UIAlertController(title: "Discard Changes?", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Discard Changes", style: .destructive) { [weak self] _ in
            self?.navigationController?.popViewController(animated: true)
        })
        alert.addAction(UIAlertAction(title: "Keep Editing", style: .cancel))
        present(alert, animated: true)
    }

    override var keyCommands: [UIKeyCommand]? { save?.isEnabled == true ? [.save("Save", #selector(saveFromKeyboard))] : [] }
    override var canBecomeFirstResponder: Bool { true }
    @objc private func saveFromKeyboard() { commit() }

    private func commit() {
        let text = textView.text ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onSave(titleField.text ?? "", text)
        Haptics.play(.success)
        navigationController?.popViewController(animated: true)
    }
}

/// [mac] The empty iOS-look sheet's page: the List's own background hidden and the sheet's page drawn (see the call);
/// on the Mac otherwise `hqGroupedPage` decides.
private struct MacEmptyPromptsPage: ViewModifier {
    let on: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if on {
            content
                .scrollContentBackground(.hidden)
                .background { Color(uiColor: HQPalette.sheetPage).ignoresSafeArea() }
        } else if DeviceWord.isMac {
            content
        } else {
            content.scrollContentBackground(.automatic)
        }
    }
}
