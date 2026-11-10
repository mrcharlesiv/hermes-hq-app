// Edit Head (spec 1x-settings §7; `S/ui-heads/edit-head-sheet.tsx`), a page in the Bot Info sheet: the draft head stays
// in view under the bar with Shuffle and Undo; below it Describe it, the themes (each a picture of this bot in it), ten
// ideas for this bot, then the theme's own parts (strips of the draft with one part changed), its colours, extras, My
// Style and Reset Head. Save is compare-and-swap; the new head shows everywhere at once and a 288 × 288 copy goes to
// desktop Hermes. Never hats; Character is not offered (owner).

import SwiftUI
import UIKit

@MainActor @Observable
final class EditHeadModel {
    let bot: Bot
    let about: String
    let opened: StoredHeadState
    let start: HeadRecord
    /// A saved Character head (a theme the owner removed): the note under the stage says saving changes it.
    let otherTheme: String?
    var draft: HeadRecord
    var undo: HeadRecord?
    /// Describe it: the words typed, and what was understood (nil before anything is typed).
    var words = ""
    var understood: [String]?
    /// The head typing started from: each keystroke lays the words over it afresh, so deleting a word takes it back.
    @ObservationIgnored private var describeBase: HeadRecord?
    var revision: Int
    var round = 0
    var notice: String?
    var saving = false
    var style: HeadRecord? = EditHeadModel.readStyle()
    @ObservationIgnored let editing: any BotEditing

    static let styleKey = "hqn.head.style"

    init(bot: Bot, editing: any BotEditing) {
        self.bot = bot
        self.editing = editing
        about = "\(bot.name) \(editing.botDescription(bot) ?? "")"
        opened = editing.headState(bot)
        if opened.saved, let record = HeadRecord.parse(opened.record) {
            otherTheme = record.theme == "persona" ? HeadLabels.themes["persona"] : nil
            start = record.forSaving
        } else {
            otherTheme = nil
            start = HeadRecord.defaultRecord(profile: bot.id)
        }
        draft = start
        revision = opened.revision
    }

    var hasChanges: Bool { draft != start }

    // MARK: Ideas (seeded per bot and round)

    @ObservationIgnored private var ideaCache: (round: Int, theme: String, ideas: [HeadRecord])?

    /// The same ten until the theme changes or Shuffle asks for more.
    var ideas: [HeadRecord] {
        if let cache = ideaCache, cache.round == round, cache.theme == draft.theme { return cache.ideas }
        let ideas = HeadRecord.ideas(profile: bot.id, about: about, round: round, theme: draft.theme).map(\.forSaving)
        ideaCache = (round, draft.theme, ideas)
        return ideas
    }

    // MARK: Changes

    func set(_ change: (inout HeadRecord) -> Void) {
        Haptics.play(.selection)
        notice = nil
        describeBase = nil
        change(&draft)
        draft.hat = "none"
    }

    /// A whole new head (an idea, Shuffle, New Blob, My Style) can be undone.
    func setWhole(_ head: HeadRecord) {
        Haptics.play(.selection)
        notice = nil
        describeBase = nil
        undo = draft
        draft = head.forSaving
    }

    func shuffle() {
        setWhole(HeadRecord.roll({ Double.random(in: 0..<1) }, theme: draft.theme))
        round += 1
    }

    /// The draft in another theme (`themed`): a Shapes head starts with no board and a dot-matrix head never has one;
    /// another theme can't go without one. A Shapes form and a dot-matrix outline carry over as the nearest one.
    static func themed(_ head: HeadRecord, _ theme: String) -> HeadRecord {
        var next = head
        next.theme = theme
        if theme == "shape" || theme == "matrix" { next.tile = "none" } else if next.tile == "none" { next.tile = "dark" }
        if theme == "matrix" {
            next.form = MatrixDesign.Silhouette(stored: head.form).rawValue
        } else if !HeadRecord.forms.contains(next.form) {
            next.form = MatrixDesign.Silhouette(stored: head.form).shapesForm
        }
        return next
    }

    func pickTheme(_ theme: String) {
        guard theme != draft.theme else { return }
        set { $0 = Self.themed($0, theme) }
        round += 1
    }

    /// Describe it: lays the understood parts over the draft as it is typed (undoable as one change).
    func describe(_ text: String) {
        words = text
        let described = HeadDescribe.describe(text)
        understood = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : described.understood
        if describeBase == nil {
            guard !described.understood.isEmpty else { return }
            describeBase = draft
            undo = draft
        }
        guard let base = describeBase else { return }
        notice = nil
        var next = base
        next.applyDescribed(described.parts)
        if next.theme == "matrix" { next.tile = "none" } else if next.theme != "shape", next.tile == "none" { next.tile = "dark" }
        if !HeadLabels.offeredThemes.contains(next.theme) { next.theme = base.theme }
        draft = next.forSaving
    }

    /// A new seed: a new blob, creature, light or pattern.
    func remix() {
        var next = draft
        next.seed = 1 + Int((Double.random(in: 0..<1) * 1e6).rounded(.down))
        setWhole(next)
    }

    func undoLast() {
        guard let previous = undo else { return }
        Haptics.play(.selection)
        draft = previous
        undo = nil
        describeBase = nil
    }

    // MARK: My Style

    static func readStyle() -> HeadRecord? {
        guard let data = UserDefaults.standard.data(forKey: styleKey), let value = try? JSONValue.parse(data) else { return nil }
        return HeadRecord.parse(value)
    }

    func setStyle() {
        Haptics.play(.selection)
        if let data = try? draft.stored.encoded() { UserDefaults.standard.set(data, forKey: Self.styleKey) }
        style = draft
    }

    func useStyle() {
        guard let style else { return }
        setWhole(draft.applyingStyle(style))
    }

    // MARK: Save

    /// Saves the draft (or nil: Reset Head). True when saved.
    func save(_ record: HeadRecord?) async -> Bool {
        saving = true
        defer { saving = false }
        notice = nil
        do {
            revision = try await editing.saveHead(bot, record: record?.forSaving.stored, revision: revision)
            Haptics.play(.success)
            let png = record.flatMap { Self.mirrorPNG($0.forSaving.head) }
            let bot = self.bot, editing = self.editing
            Task { await editing.mirrorHead(bot, png: png) }
            return true
        } catch HeadSaveError.conflict(let actual) {
            revision = actual
            notice = HeadSaveError.conflict(actual: actual).errorDescription
        } catch {
            notice = (error as? LocalizedError)?.errorDescription ?? "The gateway didn’t answer. Check the connection and try again."
        }
        Haptics.play(.error)
        return false
    }

    /// The desktop copy: the head drawn non-compact for an unknown page, 288 × 288 px, as a PNG data URL.
    static func mirrorPNG(_ head: Head) -> String? {
        let head = head.plain
        let side = CGFloat(HeadRecord.mirrorSize)
        let image: CGImage?
        if let record = head.themed {
            image = HeadRenderer.makeImage(record, side: side, scale: 1, state: .idle)
        } else if head.theme == .matrix {
            image = MatrixHeadRenderer.makeImage(MatrixDesign(head), side: side, scale: 1, dark: false)
        } else {
            image = HeadRenderer.makeImage(HeadGeometry.layout(head, compact: false, darkPage: nil), side: side, scale: 1)
        }
        guard let image, var data = UIImage(cgImage: image, scale: 1, orientation: .up).pngData() else { return nil }
        if HeadGeometry.invertsOnDarkPage(head) { data = HeadRecord.withDarkFlipMark(data) }
        return "data:image/png;base64," + data.base64EncodedString()
    }
}

final class EditHeadController: UIHostingController<HQScaledRoot<EditHeadView>>, EditingPage {
    let model: EditHeadModel
    private var saveItem: UIBarButtonItem!
    /// After a save: `true` when it was Reset Head.
    private let onSaved: (Bool) -> Void

    init?(bot: Bot, info: BotInfoModel, onSaved: @escaping (Bool) -> Void) {
        guard let editing = info.editing else { return nil }
        let model = EditHeadModel(bot: bot, editing: editing)
        self.model = model
        self.onSaved = onSaved
        super.init(rootView: HQScaledRoot(EditHeadView(model: model, reset: {})))
        rootView = HQScaledRoot(EditHeadView(model: model, reset: { [weak self] in self?.reset() }))
        title = "Edit Head"
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.hidesBackButton = true
        navigationItem.leftBarButtonItem = UIBarButtonItem.hqClose(.cancel, action: UIAction { [weak self] _ in
            self?.confirmLeaving { self?.navigationController?.popViewController(animated: true) }
        })
        saveItem = UIBarButtonItem(title: "Save", style: .prominent, target: self, action: #selector(save))
        saveItem.accessibilityIdentifier = "edit-head.save"
        navigationItem.rightBarButtonItem = saveItem
        observe()
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var hasChanges: Bool { model.hasChanges }
    var isSaving: Bool { model.saving }

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

    override var keyCommands: [UIKeyCommand]? { (super.keyCommands ?? []) + (saveItem?.isEnabled == true ? [.save("Save", #selector(save))] : []) }
    override var canBecomeFirstResponder: Bool { true }

    @objc private func save() {
        guard model.hasChanges, !model.saving else { return }
        let draft = model.draft
        Task {
            if await model.save(draft) { finish(reset: false) }
        }
    }

    private func reset() {
        guard !model.saving else { return }
        Task {
            guard await model.save(nil) else { return }
            // Reset Head stays confirm-free (as the web); the pill on Edit Bot saves the custom head back.
            let previous = model.start, model = self.model, onSaved = self.onSaved
            let back = navigationController?.viewControllers.dropLast().last
            finish(reset: true)
            UndoPill.show(label: "Head Reset", in: back) { [weak back] in
                Task {
                    if await model.save(previous) {
                        onSaved(false)
                    } else if let back, back.view.window != nil {
                        let alert = UIAlertController(title: "Couldn’t Undo", message: model.notice, preferredStyle: .alert)
                        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
                        back.present(alert, animated: true)
                    }
                }
            }
        }
    }

    private func finish(reset: Bool) {
        onSaved(reset)
        navigationController?.isModalInPresentation = false
        navigationController?.interactivePopGestureRecognizer?.isEnabled = true
        navigationController?.popViewController(animated: true)
    }
}

struct EditHeadView: View {
    @Bindable var model: EditHeadModel
    var reset: () -> Void
    @FocusState private var typing: Bool

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let notice = model.notice {
                        Label(notice, systemImage: "exclamationmark.circle.fill")
                            .font(Font.hq(.callout))
                            .foregroundStyle(Color.hqRed)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("edit-head.notice")
                            .id(Self.noticeID)
                    }
                    describe
                    themes
                    ideas
                    parts
                    colours
                    extras
                    myStyle
                    if model.opened.saved {
                        Button("Reset Head", role: .destructive, action: reset)
                            .hqBorderedButtonStyle()
                            .accessibilityIdentifier("edit-head.reset")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
                .disabled(model.saving)
            }
            .scrollDismissesKeyboard(.interactively)
            // A failed save's words sit at the page's top: brought into view and spoken, so someone scrolled down to the
            // colours sees why the buzz came (audit 05-23).
            .onChange(of: model.notice) { _, notice in
                guard let notice else { return }
                withAnimation(HQMotion.swiftUI(.easeOut(duration: 0.25))) { scroller.scrollTo(Self.noticeID, anchor: .top) }
                HQAnnounce.say(notice, priority: .high)
            }
            .safeAreaInset(edge: .top, spacing: 0) { stage }
            .background(Color.hqGroupedPage)
            .navigationBarBackButtonHidden(true)
        }
    }

    private static let noticeID = "edit-head.notice"

    /// The draft under the bar, with Shuffle and Undo (plain buttons: Save is the only filled one).
    private var stage: some View {
        VStack(spacing: 8) {
            // [ui-sizing 2026-11-09] 96 pt (× UI Scale, at most 128): at 120 the stage took a third of a 375 pt phone
            // before the first choice.
            HeadImage(head: model.draft.head, size: min(HQFont.scaled(96), 128))
                .accessibilityElement()
                .accessibilityLabel("\(model.bot.name)’s head")
                .accessibilityValue(Self.describe(model.draft))
                .accessibilityIdentifier("edit-head.stage")
            if let theme = model.otherTheme {
                Text("This bot wears a \(theme) head, which Hermes HQ no longer draws. Saving makes it a Shapes head.")
                    .font(Font.hq(.footnote))
                    .foregroundStyle(Color.hqLabel2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 24) {
                Button("Shuffle") { model.shuffle() }.accessibilityIdentifier("edit-head.shuffle")
                Button("Undo") { model.undoLast() }.disabled(model.undo == nil).accessibilityIdentifier("edit-head.undo")
            }
            .font(Font.hq(.body).weight(.medium))
            .disabled(model.saving)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Color.hqGroupedPage)
    }

    /// What VoiceOver reads for the draft ("Cobalt Hex": every face has the same eyes); DEBUG builds add the fields UI
    /// tests compare.
    static func describe(_ head: HeadRecord) -> String {
        let colour = HeadLabels.colors[head.color] ?? head.color
        let words: String
        switch head.theme {
        case "robot":
            words = "\(colour) \(HeadLabels.shapes[head.shape] ?? head.shape) robot"
        case "dots":
            words = head.pattern == "face" ? "\(colour) dots face" : "\(colour) dots, \(HeadLabels.patterns[head.pattern] ?? head.pattern)"
        case "orb": words = "\(colour) orb"
        case "pixel": words = "\(colour) pixel creature"
        case "glyph": words = "\(head.glyph) on \(HeadLabels.tiles[head.tile] ?? head.tile)"
        case "matrix":
            words = "\(colour) \(HeadLabels.outlines[head.form] ?? head.form) dot-matrix head"
        default:
            words = "\(colour) \(HeadLabels.forms[head.form] ?? head.form)"
        }
        #if DEBUG
        return words + " [theme=\(head.theme);color=\(head.color);seed=\(head.seed);form=\(head.form);look=\(head.look);"
            + "specs=\(head.specs);mouth=\(head.mouth);shape=\(head.shape);face=\(head.face);visor=\(head.visor);"
            + "shell=\(head.shell);antenna=\(head.antenna);ears=\(head.ears);pattern=\(head.pattern);tile=\(head.tile);"
            + "eyes=\(head.eyes);blush=\(head.blush);glyph=\(head.glyph)]"
        #else
        return words
        #endif
    }

    private func heading(_ title: String, _ value: String? = nil) -> some View {
        HStack {
            Text(title).font(Font.hq(.subheadline).weight(.semibold)).foregroundStyle(Color.hqLabel2)
            Spacer()
            if let value { Text(value).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2) }
        }
        .textCase(nil)
    }

    // MARK: Describe it

    private var describe: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("Describe it")
            TextField("sleepy purple cat with goggles", text: Binding(get: { model.words }, set: { model.describe($0) }))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($typing)
                .onSubmit { typing = false }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(uiColor: HQPalette.card)))
                .accessibilityIdentifier("edit-head.describe")
            if let understood = model.understood {
                Text(understood.isEmpty ? "Try a color, an animal, a mood, or what the bot does." : "Got it: \(understood.joined(separator: ", "))")
                    .font(Font.hq(.footnote))
                    .foregroundStyle(Color.hqLabel2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("edit-head.understood")
            }
        }
    }

    // MARK: Themes

    /// Every theme in view at once, each a picture of this bot in it (seven: four to a row).
    private var themes: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("Theme")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                ForEach(HeadLabels.offeredThemes, id: \.self) { theme in
                    let selected = model.draft.theme == theme
                    Button { model.pickTheme(theme) } label: {
                        VStack(spacing: 6) {
                            StripHeadImage(head: (selected ? model.draft : EditHeadModel.themed(model.draft, theme)).head, size: 60)
                            Text(HeadLabels.themes[theme] ?? theme)
                                .font(Font.hq(.footnote).weight(.medium))
                                .foregroundStyle(selected ? Color.hqTint : Color.hqLabel)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(uiColor: HQPalette.card)))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(selected ? Color.hqTint : Color.clear, lineWidth: 2.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(HeadLabels.themes[theme] ?? theme)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("edit-head.theme-\(theme)")
                }
            }
        }
    }

    private var ideas: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("Ideas for \(model.bot.name)")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(model.ideas.enumerated()), id: \.offset) { index, idea in
                        Button { model.setWhole(idea) } label: {
                            StripHeadImage(head: idea.head, size: 56).padding(6)
                                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(uiColor: HQPalette.card)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Idea \(index + 1): \(HeadLabels.summary(idea))")
                        .accessibilityIdentifier("edit-head.idea-\(index)")
                    }
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 20)
            }
            .padding(.horizontal, -20)        // the strip scrolls to the screen's edges
        }
    }

    // MARK: The theme's own parts

    @ViewBuilder private var parts: some View {
        let draft = model.draft
        switch draft.theme {
        case "robot":
            let shapes = HeadRecord.offeredShapes.contains(draft.shape) ? HeadRecord.offeredShapes : HeadRecord.offeredShapes + [draft.shape]
            // No Eyes, Mouth or Blush on any theme: every face has its own normal eyes and nothing else (`Head.plain`).
            strip("Head", shapes, HeadLabels.shapes, \.shape)
            strip("Visor", HeadRecord.visors, HeadLabels.visors, \.visor)
            strip("Shell", HeadRecord.shells, HeadLabels.shells, \.shell)
        case "dots":
            strip("Pattern", HeadRecord.patterns, HeadLabels.patterns, \.pattern)
        case "glyph":
            VStack(alignment: .leading, spacing: 8) {
                heading("Emoji or Letters")
                GlyphField(glyph: draft.glyph) { text in model.set { $0.glyph = HeadRecord.cleanGlyph(.string(text)) } }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(uiColor: HQPalette.card)))
                    .accessibilityIdentifier("edit-head.glyph")
            }
        case "shape":
            strip("Shape", HeadRecord.forms, HeadLabels.forms, \.form)
        case "matrix":
            strip("Shape", HeadRecord.outlines, HeadLabels.outlines, \.form)
        default:
            EmptyView()
        }
    }

    private func strip(_ title: String, _ options: [String], _ names: [String: String], _ field: WritableKeyPath<HeadRecord, String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            heading(title, names[model.draft[keyPath: field]])
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(options, id: \.self) { option in
                        let selected = model.draft[keyPath: field] == option
                        Button { model.set { $0[keyPath: field] = option } } label: {
                            StripHeadImage(head: variant(field, option).head, size: 56).padding(6)
                                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(uiColor: HQPalette.card)))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(selected ? Color.hqTint : Color.clear, lineWidth: 2.5))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(names[option] ?? option)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityIdentifier("edit-head.\(title.lowercased())-\(option)")
                    }
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 20)
            }
            .padding(.horizontal, -20)        // the strip scrolls to the screen's edges
        }
    }

    private func variant(_ field: WritableKeyPath<HeadRecord, String>, _ option: String) -> HeadRecord {
        var head = model.draft
        head[keyPath: field] = option
        return head
    }

    // MARK: Colours

    /// A Shapes or dot-matrix head has 24 colours; the other themes the first eleven (plus the draft's own, carried over).
    private var palette: [String] {
        if model.draft.theme == "shape" || model.draft.theme == "matrix" { return HeadRecord.shapeColors }
        let colours = HeadRecord.themeColors
        return colours.contains(model.draft.color) ? colours : colours + [model.draft.color]
    }

    private var colours: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("Color", HeadLabels.colors[model.draft.color])
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 12) {
                ForEach(palette, id: \.self) { colour in
                    let selected = model.draft.color == colour
                    Button { model.set { $0.color = colour } } label: {
                        Circle()
                            .fill(Self.swatch(colour))
                            .frame(width: 38, height: 38)
                            .overlay(Circle().strokeBorder(Color.hqLabel3.opacity(colour == "paper" ? 0.6 : 0), lineWidth: 1))
                            .padding(4)
                            .overlay(Circle().strokeBorder(selected ? Color.hqTint : Color.clear, lineWidth: 2.5))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(HeadLabels.colors[colour] ?? colour)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("edit-head.color-\(colour)")
                }
            }
        }
    }

    /// Swatch fill: ink #0A0A0A, paper #E7E1D3, else the colour's accent tone.
    static func swatch(_ name: String) -> Color {
        if name == "ink" { return Color(red: 10 / 255, green: 10 / 255, blue: 10 / 255) }
        if name == "paper" { return Color(red: 0xE7 / 255, green: 0xE1 / 255, blue: 0xD3 / 255) }
        guard let colour = Head.ColorName(rawValue: name) else { return .gray }
        let rgb = HeadTones.accent(colour)
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    // MARK: Extras

    /// A labelled segmented choice: beside its label when it fits, under it when it doesn't.
    private func choice(_ title: String, _ options: [String], _ names: [String: String], id: String,
                        get: @escaping () -> String, set: @escaping (String) -> Void) -> some View {
        let segments = WholeLabelSegments(titles: options.map { names[$0] ?? $0 },
                                          selected: Binding(get: { options.firstIndex(of: get()) ?? 0 }, set: { set(options[$0]) }))
            .fixedSize()
            .accessibilityIdentifier("edit-head.\(id)")
        return ViewThatFits(in: .horizontal) {
            HStack {
                Text(title).foregroundStyle(Color.hqLabel)
                Spacer(minLength: 16)
                segments
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(title).foregroundStyle(Color.hqLabel)
                segments
            }
        }
    }

    private func toggle(_ title: String, id: String, _ field: WritableKeyPath<HeadRecord, Bool>) -> some View {
        choice(title, ["off", "on"], ["off": "Off", "on": "On"], id: id,
               get: { model.draft[keyPath: field] ? "on" : "off" }, set: { value in model.set { $0[keyPath: field] = value == "on" } })
    }

    private func remix(_ label: String) -> some View {
        HStack {
            Text("Remix").foregroundStyle(Color.hqLabel)
            Spacer()
            Button(label) { model.remix() }.accessibilityIdentifier("edit-head.remix")
        }
    }

    private var extras: some View {
        let draft = model.draft, theme = draft.theme
        return VStack(alignment: .leading, spacing: 12) {
            heading("Extras")
            switch theme {
            case "robot":
                choice("Antenna", HeadRecord.antennas, HeadLabels.antennas, id: "antenna", get: { model.draft.antenna }, set: { v in model.set { $0.antenna = v } })
                choice("Ears", HeadRecord.ears, HeadLabels.ears, id: "ears", get: { model.draft.ears }, set: { v in model.set { $0.ears = v } })
            case "shape":
                choice("Backdrop", ["none", "dark", "light", "color"], HeadLabels.tiles, id: "backdrop",
                       get: { model.draft.tile }, set: { v in model.set { $0.tile = v } })
                if draft.form == "blob" { remix("New Blob") }
            case "matrix":
                // Which way it turns: where the light falls and the eyes sit.
                choice("Facing", ["left", "right"], HeadLabels.facings, id: "facing",
                       get: { model.draft.facing < 0 ? "left" : "right" }, set: { v in model.set { $0.facing = v == "left" ? -1 : 1 } })
            default:
                choice("Tile", ["dark", "light", "color"], HeadLabels.tiles, id: "tile", get: { model.draft.tile }, set: { v in model.set { $0.tile = v } })
                if theme == "orb" || (theme == "dots" && (draft.pattern == "ring" || draft.pattern == "bloom")) {
                    toggle("Eyes", id: "eyes", \.eyes)
                }
                if theme == "pixel" { remix("New Creature") }
                if theme == "orb" { remix("New Light") }
                if theme == "dots" && draft.pattern != "face" { remix("New Pattern") }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(uiColor: HQPalette.card)))
    }

    private var myStyle: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("My Style")
            Text("Keep one look for all your bots. Each bot keeps its own color.")
                .font(Font.hq(.footnote))
                .foregroundStyle(Color.hqLabel2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Set as My Style") { model.setStyle() }.hqBorderedButtonStyle().accessibilityIdentifier("edit-head.set-style")
                Button("Use My Style") { model.useStyle() }.hqBorderedButtonStyle().disabled(model.style == nil)
                    .accessibilityIdentifier("edit-head.use-style")
            }
        }
    }
}

/// Emoji or Letters: what's typed is kept as typed while the head takes one emoji or up to two letters from it.
private struct GlyphField: View {
    var glyph: String
    var onChange: (String) -> Void
    @State private var text = ""

    var body: some View {
        TextField("✨", text: $text)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .font(Font.hq(.title3))
            .onAppear { text = glyph }
            // Shuffle, Undo, an idea or Describe it changed the head: show what it wears now.
            .onChange(of: glyph) { _, value in
                if HeadRecord.cleanGlyph(.string(text)) != value { text = value }
            }
            .onChange(of: text) { _, value in
                let trimmed = String(value.prefix(16))
                if trimmed != value { text = trimmed }
                guard !trimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      HeadRecord.cleanGlyph(.string(trimmed)) != glyph else { return }
                onChange(trimmed)
            }
    }
}

/// A head in a strip or the ideas row. A pick changes up to ~30 of them at once (each strip shows the draft with one part
/// changed), so a picture not drawn yet is drawn off the main thread and the one before stays until it lands; the
/// page's first paint draws in place, as everywhere else, so nothing pops in on opening.
private struct StripHeadImage: View {
    var head: Head
    var size: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @State private var drawn: UIImage?

    var body: some View {
        let dark = colorScheme == .dark
        let key = StripHeadImages.key(head, size, displayScale, dark)
        // A Shapes head draws in place on first paint; a themed head (several times the work) arrives off the main
        // thread, with the picture before it, or a soft tile, until it lands.
        let picture = StripHeadImages.cache.object(forKey: key) ?? drawn
            ?? (head.themed == nil ? HeadImageCache.shared.image(for: head, side: size, scale: displayScale, dark: dark) : nil)
        Group {
            if let picture {
                Image(uiImage: picture).resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).fill(Color(uiColor: .tertiarySystemFill))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: key) {
            if let hit = StripHeadImages.cache.object(forKey: key) { drawn = hit; return }
            if drawn == nil, head.themed == nil {
                // First paint (drawn in place above, through the shared cache): just remember it.
                drawn = HeadImageCache.shared.image(for: head, side: size, scale: displayScale, dark: dark)
                return
            }
            guard let made = await StripHeadImages.render(head, size: size, scale: displayScale, dark: dark),
                  !Task.isCancelled else { return }
            StripHeadImages.cache.setObject(made, forKey: key)
            drawn = made
        }
    }
}

private enum StripHeadImages {
    static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 300
        return cache
    }()

    static func key(_ head: Head, _ size: CGFloat, _ scale: CGFloat, _ dark: Bool) -> NSString {
        "\(head.cacheKey)|\(size)|\(scale)|\(dark)" as NSString
    }

    /// The same picture `HeadImageCache` draws (idle, compact under 64 pt), made on a background thread.
    static func render(_ head: Head, size: CGFloat, scale: CGFloat, dark: Bool) async -> UIImage? {
        let image = await Task.detached(priority: .userInitiated) { () -> RenderedHead? in
            HeadRenderer.picture(head, side: size, scale: scale, dark: dark).map(RenderedHead.init)
        }.value
        return image.map { UIImage(cgImage: $0.image, scale: scale, orientation: .up) }
    }
}

/// A finished picture handed from the drawing thread (a `CGImage` is immutable once made).
private nonisolated struct RenderedHead: @unchecked Sendable {
    let image: CGImage
}
