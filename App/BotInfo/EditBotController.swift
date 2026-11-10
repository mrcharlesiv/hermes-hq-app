// Edit Bot (spec 1x-settings §6.2–6.3), a page inside the Bot Info sheet: the picture with Edit Head, Title and
// Description. Save waits for a change and writes both in one `profiles.configure`; a refused part keeps the page and
// what was typed, with the reason.
//
// [photoheads] The Picture section has two tabs, Head and Upload (docs/spec/3x-photoheads.md §5): Upload stages a
// photo framed in Move and Scale, Remove Picture stages its removal, and nothing reaches the gateway until Save.

import SwiftUI
import UIKit

@MainActor @Observable
final class EditBotModel {
    let botId: String
    let originalTitle: String
    let originalDescription: String
    var title: String
    var description: String
    var saving = false
    /// What the last head save from this page did (the Picture note says so).
    var headNote: HeadNote?
    // [photoheads] The staged picture, the tab shown (always Head when the page opens), and a picture an earlier Save
    // stored whose kind is still to be written (true: a photo).
    var picture: PictureDraft = .unchanged
    var pictureTab: PictureTab = .head
    var pendingKind: Bool?
    @ObservationIgnored let info: BotInfoModel

    init(info: BotInfoModel) {
        self.info = info
        botId = info.botId
        let editing = info.editing
        originalTitle = editing?.metaTitle(info.bot) ?? ""
        originalDescription = editing?.botDescription(info.bot) ?? ""
        title = originalTitle
        description = originalDescription
    }

    var bot: Bot { info.bot }
    /// The name an empty Title keeps (the bot's own name, never a custom title).
    var defaultName: String { info.editing?.defaultName(info.bot) ?? info.bot.name }
    var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedDescription: String { description.trimmingCharacters(in: .whitespacesAndNewlines) }
    var titleChanged: Bool { trimmedTitle != originalTitle.trimmingCharacters(in: .whitespacesAndNewlines) }
    var descriptionChanged: Bool { trimmedDescription != originalDescription.trimmingCharacters(in: .whitespacesAndNewlines) }
    var hasChanges: Bool { titleChanged || descriptionChanged || pictureChanged }

    // MARK: [photoheads] The picture

    var pictures: (any BotPictureEditing)? { info.editing as? BotPictureEditing }
    /// False on a gateway with no asset store: the section is the head alone, as it always was (§5.6). Read through
    /// the registry's `version`, so a page opened before the gateway's first roster answer follows it.
    var supportsPictures: Bool {
        _ = BotFaces.shared.version
        return pictures?.supportsPictures ?? false
    }
    /// Whether the bot's saved face is a photo (read through the registry, so the page follows it).
    var savedPhoto: Bool {
        _ = BotFaces.shared.version
        return BotFaces.shared.showsPhoto(botId)
    }
    /// "The face shows a photo": a staged one, or the saved one with nothing staged.
    var faceShowsPhoto: Bool {
        switch picture {
        case .photo: true
        case .removed: false
        case .unchanged: savedPhoto
        }
    }
    var pictureChanged: Bool { !picture.isUnchanged || pendingKind != nil }

    /// What Save sends for the picture, nil when there is nothing to send.
    var pictureChange: BotPictureChange? {
        switch picture {
        case .photo(_, let dataURL): return .photo(dataURL: dataURL)
        case .removed:
            // A bot with a saved head gets that head's desktop copy back in the photo's place.
            let saved = info.editing?.headState(bot).saved ?? false
            return .remove(mirror: saved ? EditHeadModel.mirrorPNG(Head.resolve(bot.head, profile: bot.id)) : nil)
        case .unchanged: return pendingKind.map { .kindOnly(photo: $0) }
        }
    }

    func stage(_ photo: FramedPhoto) {
        picture = .photo(image: photo.image, dataURL: photo.dataURL)
        headNote = nil
    }

    /// Remove Picture: a staged photo is dropped; a saved one is staged for removal. Nothing is written until Save.
    func removePicture() {
        picture = savedPhoto ? .removed : .unchanged
        headNote = nil
    }

    /// A head saved or reset from this page. A saved head replaces the photo on this phone at once.
    func headSaved(reset: Bool) {
        if !reset {
            picture = .unchanged
            pendingKind = nil
        }
        headNote = reset ? .reset : .saved
    }

    /// The picture part of a Save answer: what landed is no longer staged.
    func pictureSettled(_ outcome: EditOutcome, sent: BotPictureChange?) {
        guard let sent else { return }
        if outcome.pictureApplied == true { picture = .unchanged }
        if outcome.pictureKindApplied == true {
            pendingKind = nil
        } else if outcome.pictureApplied == true {
            pendingKind = sent.imageKind == "photo"
        }
    }

    /// The note under Edit Head (§5.3).
    var pictureNote: (text: String, tinted: Bool) {
        let showsPhoto = supportsPictures && faceShowsPhoto
        if let headNote, !(headNote == .reset && showsPhoto) { return (headNote.text, true) }
        if showsPhoto { return (HeadNote.photoText, false) }
        return (HeadNote.sameEverywhereText, false)
    }
}

/// [photoheads] The picture staged on Edit Bot (§5.1).
enum PictureDraft {
    case unchanged
    case photo(image: UIImage, dataURL: String)
    case removed

    var isUnchanged: Bool { if case .unchanged = self { return true } else { return false } }
}

enum PictureTab: Hashable { case head, upload }

final class EditBotController: UIHostingController<HQScaledRoot<EditBotView>>, EditingPage {
    let model: EditBotModel
    let info: BotInfoController
    private var saveItem: UIBarButtonItem!
    /// [photoheads] Opened from Bot Info's face for a photo: the picker comes up once the page is in.
    var pickOnAppear: BotPhotoPicker.Source?

    init(info: BotInfoController) {
        self.info = info
        let model = EditBotModel(info: info.model)
        self.model = model
        super.init(rootView: HQScaledRoot(EditBotView(model: model, editHead: {}, choosePhoto: { _ in })))
        rootView = HQScaledRoot(EditBotView(model: model, editHead: { [weak self] in self?.openEditHead() },
                               choosePhoto: { [weak self] source in self?.choosePhoto(source) }))       // [photoheads]
        title = "Edit Bot"
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.hidesBackButton = true
        navigationItem.leftBarButtonItem = UIBarButtonItem.hqClose(.cancel, action: UIAction { [weak self] _ in
            self?.confirmLeaving { self?.navigationController?.popViewController(animated: true) }
        })
        saveItem = UIBarButtonItem(title: "Save", style: .prominent, target: self, action: #selector(save))
        saveItem.accessibilityIdentifier = "edit-bot.save"
        navigationItem.rightBarButtonItem = saveItem
        observe()
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var hasChanges: Bool { model.hasChanges }
    var isSaving: Bool { model.saving }

    /// Save waits for a change; the sheet holds while there is one.
    private func observe() {
        withObservationTracking {
            _ = model.hasChanges
            _ = model.saving
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshBar()
                self.observe()
            }
        }
        refreshBar()
    }

    private func refreshBar() {
        saveItem.title = model.saving ? "Saving…" : "Save"
        saveItem.setProminentEnabled(model.hasChanges && !model.saving)
        navigationItem.leftBarButtonItem?.isEnabled = !model.saving
        updateModalLock()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The hosting controller re-applies SwiftUI's bar preferences: Cancel is this page's only way back.
        navigationItem.hidesBackButton = true
        updateModalLock()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let source = pickOnAppear {
            pickOnAppear = nil
            choosePhoto(source)
        }
    }

    private func openEditHead() {
        guard let page = EditHeadController(bot: model.bot, info: model.info, onSaved: { [weak self] reset in
            self?.model.headSaved(reset: reset)       // [photoheads] a saved head drops the photo here at once
        }) else { return }
        navigationController?.pushViewController(page, animated: true)
    }

    /// [photoheads] Upload › Choose an image…: the picker, then Move and Scale; the result is staged, not saved.
    private func choosePhoto(_ source: BotPhotoPicker.Source) {
        guard !model.saving, let host = navigationController ?? parent else { return }
        view.endEditing(true)
        BotPhotoPicker.pickAndFrame(from: host, source: source) { [weak self] photo in
            guard let self, let photo else { return }
            self.model.stage(photo)
            HQAnnounce.say("Photo chosen. Save to use it.")
        }
    }

    override var keyCommands: [UIKeyCommand]? { (super.keyCommands ?? []) + (saveItem?.isEnabled == true ? [.save("Save", #selector(save))] : []) }
    override var canBecomeFirstResponder: Bool { true }

    @objc private func save() {
        guard model.hasChanges, !model.saving, let editing = model.info.editing else { return }
        view.endEditing(true)
        let bot = model.bot
        let title = model.titleChanged ? model.trimmedTitle : nil
        let description = model.descriptionChanged ? model.trimmedDescription : nil
        let picture = model.pictureChange       // [photoheads]
        model.saving = true
        updateModalLock()       // held from this instant, not from the next observation pass
        let start = ContinuousClock.now
        let tag = AppLog.tag(bot.id)
        AppLog.trace("botinfo", "bot \(tag) edit save started: title=\(title != nil), description=\(description != nil), picture=\(picture != nil)")
        Task {
            defer { model.saving = false }
            do {
                let outcome: EditOutcome
                if let picture, let pictures = model.pictures {
                    outcome = try await pictures.saveEdit(bot, title: title, description: description, picture: picture)
                    model.pictureSettled(outcome, sent: picture)       // what landed is not sent again on Try Again
                } else {
                    outcome = try await editing.saveEdit(bot, title: title, description: description)
                }
                if outcome.pictureApplied == false {
                    AppLog.note("botinfo", "bot \(tag) edit save: picture refused after \(AppLog.ms(since: start)) ms: \(outcome.pictureReason ?? BotWriteError.notSavedReason)")
                    FailureAlert.present(title: BotPictureWords.failureTitle, reason: outcome.pictureReason ?? BotWriteError.notSavedReason,
                                         detail: outcome.pictureDetail, from: self) { self.save() }
                } else if outcome.titleApplied == false || outcome.pictureKindApplied == false {
                    AppLog.note("botinfo", "bot \(tag) edit save: title/kind refused after \(AppLog.ms(since: start)) ms: \(outcome.reason ?? BotWriteError.notSavedReason)")
                    FailureAlert.present(title: "Couldn’t Save Changes", reason: outcome.reason ?? BotWriteError.notSavedReason, from: self) { self.save() }
                } else if outcome.descriptionApplied == false {
                    AppLog.note("botinfo", "bot \(tag) edit save: description refused after \(AppLog.ms(since: start)) ms: \(outcome.reason ?? BotWriteError.notSavedReason)")
                    FailureAlert.present(title: "Couldn’t Save the Description", reason: outcome.reason ?? BotWriteError.notSavedReason,
                                         from: self) { self.save() }
                } else {
                    AppLog.trace("botinfo", "bot \(tag) edit save ok in \(AppLog.ms(since: start)) ms")
                    Haptics.play(.success)
                    navigationController?.isModalInPresentation = false
                    navigationController?.popViewController(animated: true)
                }
            } catch {
                AppLog.note("botinfo", "bot \(tag) edit save failed after \(AppLog.ms(since: start)) ms: \(type(of: error))")
                FailureAlert.present(error, fallbackTitle: "Couldn’t Save Changes", from: self) { self.save() }
            }
        }
    }
}

struct EditBotView: View {
    @Bindable var model: EditBotModel
    var editHead: () -> Void
    var choosePhoto: (BotPhotoPicker.Source) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let bot = model.bot
        Form {
            Section {
                Text("Appearance and role for \(bot.name).")
                    .font(Font.hq(.subheadline))
                    .foregroundStyle(Color.hqLabel2)
                    .listRowBackground(Color.clear)
                    // Item 6: on the section labels' own edge below (16 pt in from the card) in both looks, not 12
                    // pt further left, which the Desktop Look's own "4" did (it lined up only by chance in iOS).
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 4))
                    .hqDesktopBareRow()                 // [desktoplook2] a note on the page, not a field
            }
            .listSectionSpacing(.compact)
            Section {
                if model.supportsPictures {
                    picturePicker(bot)       // [photoheads] Head | Upload
                    if model.faceShowsPhoto {
                        // Only for a real photo: a saved head's desktop copy is not a picture to remove.
                        Button("Remove Picture", role: .destructive) { model.removePicture() }
                            .accessibilityIdentifier("edit-bot.remove-picture")
                    }
                } else {
                    // A gateway that cannot store pictures: the head alone, as it always was.
                    HStack(spacing: 16) {
                        HeadImage(raw: bot.head, profile: bot.id, size: 64)
                        VStack(alignment: .leading, spacing: 8) {
                            editHeadButton
                            headNote
                        }
                    }
                    .padding(.vertical, Theme.isDesktop ? 12 : 4)
                }
            } header: { HQSectionLabel {
                Text("Picture")
            } }
            Section {
                // Empty means no custom title, so the field is never filled with the name (that would save one).
                TextField(model.defaultName, text: $model.title)
                    .textInputAutocapitalization(.words)
                    .accessibilityIdentifier("edit-bot.title")
            } header: { HQSectionLabel { Text("Display Name") } } footer: { HQSectionFooter {   // UX study #184: the footer's own word
                Text(BotInfoWords.titleFooter(defaultName: model.defaultName))
            } }
            Section {
                TextField("What should this bot help with?", text: $model.description, axis: .vertical)
                    .lineLimit(Theme.isDesktop ? 3...8 : 2...8)   // [compact] iOS look: two lines empty (was three), growing as it fills
                    .accessibilityIdentifier("edit-bot.description")
            } header: { HQSectionLabel { Text("Description") } }
        }
        .hqGroupedPage()   // [desktoplook] the page follows the skin
        .contentMargins(.top, 0, for: .scrollContent)
        .disabled(model.saving)
        .navigationBarBackButtonHidden(true)
    }

    /// A bordered button pads its label by 7 pt above and below: a 30 pt label makes a 44 pt target.
    private static let borderedLabelMinHeight: CGFloat = 30

    private var editHeadButton: some View {
        // At least 44 pt tall at every text size (stress round 1: 31 pt at the smallest).
        Button(action: editHead) { Text("Edit Head").frame(minHeight: Self.borderedLabelMinHeight) }
            .hqBorderedButtonStyle()
            .accessibilityIdentifier("edit-bot.edit-head")
    }

    private var headNote: some View {
        let note = model.pictureNote
        return Text(note.text)
            .font(Font.hq(.footnote))
            .foregroundStyle(note.tinted ? Color.hqTintText : Color.hqLabel2)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("edit-bot.head-note")
    }

    // MARK: [photoheads] The picture picker (§5)

    /// The 72 pt face, the two tabs, and the tab's own control. System controls throughout.
    private func picturePicker(_ bot: Bot) -> some View {
        VStack(spacing: Theme.isDesktop ? 14 : 10) {
            face(bot)
            if Theme.isDesktop {   // [desktoplook2] the desktop's outlined strip
                DesktopSegmentStrip(options: [("Head", PictureTab.head), ("Upload", PictureTab.upload)], selection: $model.pictureTab)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("edit-bot.picture-tabs")
            } else if typeSize.isAccessibilitySize {
                // The segmented control keeps ~13 pt labels at every size: a menu row grows with the text.
                // Not "Picture" again under the card's own Picture header. The row's label is drawn only: the picker
                // says "Type" itself (it read "Picture, Type, Head").
                LabeledContent {
                    Picker("Type", selection: $model.pictureTab) {
                        Text("Head").tag(PictureTab.head)
                        Text("Upload").tag(PictureTab.upload)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .accessibilityIdentifier("edit-bot.picture-tabs")
                } label: {
                    Text("Type").accessibilityHidden(true)
                }
            } else {
                // [ui-sizing] `HQSegmentedPicker`: its titles follow UI Scale (iOS's own segments at 100 %).
                HQSegmentedPicker("Picture", options: [("Head", PictureTab.head), ("Upload", PictureTab.upload)],
                                  selection: $model.pictureTab)
                    .labelsHidden()
                    .accessibilityIdentifier("edit-bot.picture-tabs")
            }
            switch model.pictureTab {
            case .head:
                VStack(spacing: 8) {
                    editHeadButton
                    headNote.multilineTextAlignment(.center)
                }
            case .upload:
                Menu {
                    Button { choosePhoto(.library) } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
                        .accessibilityIdentifier("edit-bot.choose-library")
                    Button { choosePhoto(.file) } label: { Label("Choose File", systemImage: "folder") }
                        .accessibilityIdentifier("edit-bot.choose-file")
                } label: {
                    Label("Choose an Image…", systemImage: "photo.badge.plus")
                        .frame(maxWidth: .infinity, minHeight: Self.borderedLabelMinHeight)
                }
                .menuOrder(.fixed)
                .hqBorderedButtonStyle()
                .accessibilityIdentifier("edit-bot.choose-image")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.isDesktop ? 12 : 4)   // [compact] iOS look: the List row pads it already
        // The line above Remove Picture runs the row's whole width (not from the centred button's label).
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
    }

    /// A staged photo as an app-icon tile; a staged removal as the head; otherwise the bot's face as every list draws it.
    @ViewBuilder private func face(_ bot: Bot) -> some View {
        let side: CGFloat = 72
        Group {
            switch model.picture {
            case .photo(let image, _):
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: side * BotFaces.cornerShare, style: .continuous))
                    .accessibilityIgnoresInvertColors()
            case .removed:
                HeadImage(head: Head.resolve(bot.head, profile: bot.id), size: side)
            case .unchanged:
                HeadImage(raw: bot.head, profile: bot.id, size: side)
            }
        }
        .frame(width: side, height: side)
        .accessibilityElement()
        .accessibilityLabel(model.faceShowsPhoto ? "\(bot.name)’s photo" : "\(bot.name)’s head")
        .accessibilityAddTraits(.isImage)
        .accessibilityIdentifier("edit-bot.face")
    }
}

/// The Picture note after a head save (`MEM/head-save-ux.md`: a save with no visible result reads as "no save").
enum HeadNote: Equatable {
    case saved, reset
    var text: String {
        switch self {
        case .saved: "Head saved. It’s on every device on this gateway."
        case .reset: "Head reset. Every device on this gateway shows its default head."
        }
    }

    static let sameEverywhereText = "Your other devices and desktop Hermes show the same picture."
    /// [photoheads] While the face is a photo: said before the tap, because saving a head replaces the photo.
    static let photoText = "This bot shows a photo. Saving a head replaces it."
}
