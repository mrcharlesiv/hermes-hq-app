// [project-look] New Project sheet: Name, Folder (with inline Choose Folder… browser pushed inside the sheet), and
// optional Icon & Color (quick color swatches + full visual Emoji/Symbol picker) with a live badge and pill preview.

import SwiftUI
import UIKit

@MainActor @Observable final class NewProjectDraft {
    var name: String
    var folder: String
    var look: ProjectLook

    init(name: String = "", folder: String = "", look: ProjectLook = ProjectLook()) {
        self.name = name
        self.folder = folder
        self.look = look
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var canCreate: Bool { !trimmedName.isEmpty }

    var folderPlaceholder: String {
        trimmedName.isEmpty ? "Folder (optional)" : SessionProject.autoFolder(name: trimmedName)
    }
}

@MainActor enum NewProjectSheet {
    static func present(from presenter: UIViewController, store: SessionStore, profile: String,
                        name: String = "", folder: String = "", look: ProjectLook = ProjectLook(),
                        onCreate: @escaping (_ name: String, _ folder: String, _ look: ProjectLook) -> Void) {
        let draft = NewProjectDraft(name: name, folder: folder, look: look)
        let controller = NewProjectSheetController(draft: draft, store: store, profile: profile, onCreate: onCreate)
        let navigation = UINavigationController(rootViewController: controller)
        SheetStyle.apply(navigation, from: presenter, detents: [.large()])
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = false
            sheet.hqGlassPage()
        }
        presenter.present(navigation, animated: true)
    }
}

final class NewProjectSheetController: UIHostingController<NewProjectSheetView> {
    private let draft: NewProjectDraft
    private let store: SessionStore
    private let profile: String
    private let onCreate: (_ name: String, _ folder: String, _ look: ProjectLook) -> Void
    private var createItem: UIBarButtonItem?
    private var delivered = false

    init(draft: NewProjectDraft, store: SessionStore, profile: String,
         onCreate: @escaping (_ name: String, _ folder: String, _ look: ProjectLook) -> Void) {
        self.draft = draft
        self.store = store
        self.profile = profile
        self.onCreate = onCreate
        weak var weakSelf: NewProjectSheetController?
        let view = NewProjectSheetView(
            draft: draft,
            onChooseFolder: { weakSelf?.pushFolderPicker() },
            onChooseLook: { weakSelf?.pushLookPicker() },
            onCanCreateChange: { canCreate in weakSelf?.createItem?.isEnabled = canCreate },
            onSubmit: { weakSelf?.submit() })
        super.init(rootView: view)
        weakSelf = self
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "New Project"
        navigationItem.largeTitleDisplayMode = .never
        let cancel = UIBarButtonItem(title: "Cancel", primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        cancel.accessibilityIdentifier = "project.cancel"
        let create = UIBarButtonItem(title: "Create", primaryAction: UIAction { [weak self] _ in
            self?.submit()
        })
        create.style = .done
        create.isEnabled = draft.canCreate
        create.accessibilityIdentifier = "project.create"
        createItem = create
        navigationItem.leftBarButtonItem = cancel
        navigationItem.rightBarButtonItem = create
    }

    private func submit() {
        guard !delivered, draft.canCreate else { return }
        delivered = true
        let name = draft.name, folder = draft.folder, look = draft.look
        let complete = { [onCreate] in onCreate(name, folder, look) }
        if presentingViewController != nil {
            dismiss(animated: true) { complete() }
        } else {
            complete()
        }
    }

    private func pushFolderPicker() {
        let workspace = ChatWorkspace(client: store.client, profile: profile.isEmpty || profile == "default" ? nil : profile)
        let picker = ProjectFolderPickerView(browser: ProjectFolderBrowser(workspace: workspace, typed: draft.folder)) { [weak self] picked in
            guard let self else { return }
            Haptics.play(.selection)
            self.draft.folder = picked
            if self.draft.trimmedName.isEmpty {
                self.draft.name = ProjectFolderWords.suggestedName(folder: picked)
                self.createItem?.isEnabled = self.draft.canCreate
            }
            self.navigationController?.popViewController(animated: true)
        }
        let host = UIHostingController(rootView: picker)
        host.title = "Choose Folder"
        host.navigationItem.largeTitleDisplayMode = .never
        navigationController?.pushViewController(host, animated: true)
    }

    private func pushLookPicker() {
        let binding = Binding<ProjectLook>(get: { [draft] in draft.look }, set: { [draft] in draft.look = $0 })
        let picker = UIHostingController(rootView: ProjectLookPickerView(projectName: draft.name, look: binding))
        picker.title = "Icon & Color"
        picker.navigationItem.largeTitleDisplayMode = .never
        navigationController?.pushViewController(picker, animated: true)
    }
}

struct NewProjectSheetView: View {
    @Bindable var draft: NewProjectDraft
    var onChooseFolder: () -> Void
    var onChooseLook: () -> Void
    var onCanCreateChange: (Bool) -> Void
    var onSubmit: () -> Void

    @FocusState private var focused: Field?
    private enum Field { case name, folder }

    var body: some View {
        let colour = draft.look.color.map { Color(uiColor: SessionsOrganizer.uiColor($0)) }
        List { Group {
            Section {
                ProjectLookPreview(name: draft.name, look: draft.look)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .listRowBackground(Color.clear)
                    .hqDesktopBareRow()
            }

            Section {
                TextField("Name", text: $draft.name)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.next)
                    .focused($focused, equals: .name)
                    .onSubmit { focused = .folder }
                    .accessibilityIdentifier("project.name")

                TextField(draft.folderPlaceholder, text: $draft.folder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($focused, equals: .folder)
                    .onSubmit { if draft.canCreate { onSubmit() } }
                    .accessibilityIdentifier("project.folder")

                Button(action: onChooseFolder) {
                    HStack(spacing: 10) {
                        Image(systemName: "folder")
                            .foregroundStyle(Color.hqTintText)
                        Text("Choose Folder…")
                            .foregroundStyle(Color.hqTintText)
                        Spacer(minLength: 8)
                        SettingsChevron()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("project.choose-folder")
            } header: {
                HQSectionLabel { Text("Project") }
            } footer: {
                HQSectionFooter {
                    Text("A project holds the chats in its folder on \(HostWord.phrase). Leave Folder empty to make a new one.")
                }
            }

            Section {
                Button(action: onChooseLook) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: HQShape.radius(10, .control), style: .continuous)
                                .fill(colour.map { $0.opacity(draft.look.emoji != nil ? 0.24 : 0.16) } ?? Color.hqFill3)
                                .frame(width: HQFont.scaled(36), height: HQFont.scaled(36))
                            ProjectLookMark(look: draft.look, size: 19, defaultFilled: false)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Icon & Color")
                                .font(Font.hq(.body).weight(.medium))
                                .foregroundStyle(Color.hqLabel)
                            Text(draft.look.summaryLabel)
                                .font(Font.hq(.footnote))
                                .foregroundStyle(Color.hqLabel2)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        SettingsChevron()
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("project.new.look")

                ProjectLookColorSwatches(color: $draft.look.color, identifierPrefix: "project.new.color")
                    .padding(.vertical, 2)
            } header: {
                HQSectionLabel { Text("Look (Optional)") }
            }
        }.hqMacSettingsRowInsets() }
        .settingsList()
        .listSectionSpacing(.compact)
        .accessibilityIdentifier("project.newSheet")
        .onChange(of: draft.canCreate) { _, canCreate in onCanCreateChange(canCreate) }
        .onAppear {
            onCanCreateChange(draft.canCreate)
            if draft.name.isEmpty { focused = .name }
        }
    }
}
