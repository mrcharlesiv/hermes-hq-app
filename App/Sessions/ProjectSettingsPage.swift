// [project-settings] Owner 2026-11-20/21: a project's page had its choices in the ⋯, which was getting long; they are
// one page now (⋯ › Project Settings…), a sheet titled with the project's name. Every change is kept at once (no
// Save): the page behind it redraws as a switch moves. Each setting is per project and follows the owner to their
// other devices in the "sessions" document (`SessionStore+Sync.swift`).
//
//   Chats           Keep Chats in This Project [project-keep] · Pins Stay in Project [project-pins] ·
//                   Move Quiet Chats to Done [project-auto-done]
//   Notifications   All, Only When It Needs Me, Mute [project-mute]
//   New Chats       Model, Reasoning [project-new-chat-model]
//   Look            Icon, Color [project-look]; a coding project: Show Branch on Rows [project-branch-rows]
//   (last)          Icon Guide [coding-pr-review]: the marks the page draws (it was the header's ⓘ)
//
// Home (the chats in no project) has a page too: it keeps what makes sense there (its pins, Done, notifications).

import SwiftUI

struct ProjectSettingsPage: View {
    let project: String
    let store: SessionStore
    /// The bot the project's New Chat starts with (its models are the ones offered), and its name.
    var bot: (id: String, name: String)? = nil
    /// The page behind redraws.
    var onChange: () -> Void = {}
    /// Pushes the project's Repository… configuration page inside this settings sheet.
    var onRepository: (() -> Void)? = nil
    /// [coding-pr-review] Icon Guide: the sheet pushes the project's icon guide (nil: no row).
    var onIconGuide: (() -> Void)? = nil

    /// Bumped by every change: the page reads the store again.
    @State private var tick = 0
    @State private var emoji = ""
    @State private var providers: [JobModelProvider] = []
    @State private var modelsLoaded = false
    @State private var loaded = false

    private var isHome: Bool { project == SessionProjects.homeKey }
    private var coding: Bool { store.isCodingProject(project) }
    private static let botsDefault = ""
    private static let join = "\u{1F}"

    private func bound<Value>(_ get: @escaping () -> Value, _ set: @escaping (Value) -> Void) -> Binding<Value> {
        Binding(get: get, set: { value in
            Haptics.play(.selection)
            set(value)
            tick += 1
            onChange()
        })
    }

    var body: some View {
        let _ = tick
        return List { Group {
            chats
            if !isHome { codingSection }
            notifications
            if !isHome {
                newChats
                look
            }
            iconGuide
        }.hqMacSettingsRowInsets() }
        .settingsList()
        .accessibilityIdentifier("sessions.projectSettings")
        .task {
            guard !loaded else { return }
            loaded = true
            emoji = store.projectLook(project).emoji ?? ""
            guard !isHome, let bot else { modelsLoaded = true; return }
            let found = await Result.of { try await store.projectModelProviders(profile: bot.id) }
            providers = (try? found.get()) ?? []
            modelsLoaded = true
        }
    }

    // MARK: Chats

    @ViewBuilder private var chats: some View {
        if !isHome {
            Section {
                Toggle("Keep Chats in This Project", isOn: bound({ store.isProjectKept(project) }) { store.setProjectKept(project, $0) })
                    .accessibilityIdentifier("sessions.projectSettings.keep")
            } header: { HQSectionLabel { Text("Chats") } } footer: { HQSectionFooter {
                Text("Its chats leave Recent and Pinned. Chats that need you still show in New for You. To keep a shortcut under a bot, choose Show Under in the chat’s menu.")
            } }
        }
        Section {
            Toggle("Pins Stay in Project", isOn: bound({ store.isProjectPinsLocal(project) }) { store.setProjectPinsLocal(project, $0) })
                .accessibilityHint("Pinning a chat here pins it in this project only, not in your other lists")
                .accessibilityIdentifier("sessions.projectPage.localPins")
        } header: { if isHome { HQSectionLabel { Text("Chats") } } } footer: { HQSectionFooter {
            Text("Pinning a chat on this page pins it here only.")
        } }
        Section {
            Picker("Move Quiet Chats to Done", selection: bound({ store.projectAutoDone(project).days ?? 0 }) { days in
                var rule = store.projectAutoDone(project)
                rule.days = days == 0 ? nil : days
                store.setProjectAutoDone(project, rule)
            }) {
                Text(ProjectAutoDone.title(days: nil)).tag(0)
                ForEach(ProjectAutoDone.dayChoices, id: \.self) { Text(ProjectAutoDone.title(days: $0)).tag($0) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("sessions.projectSettings.autoDone")
            if coding {
                Toggle("When the Pull Request Merges", isOn: bound({ store.projectAutoDone(project).onMerge }) { on in
                    var rule = store.projectAutoDone(project)
                    rule.onMerge = on
                    store.setProjectAutoDone(project, rule)
                })
                .accessibilityIdentifier("sessions.projectSettings.autoDoneMerged")
            }
        } footer: { HQSectionFooter { Text("Only on this page. Nothing is archived.") } }
    }

    // MARK: Coding

    @ViewBuilder private var codingSection: some View {
        Section {
            Toggle("Coding Project", isOn: bound({ store.isCodingProject(project) }) { store.setCodingProject(project, $0) })
                .accessibilityIdentifier("sessions.projectSettings.coding")
            if coding, let onRepository {
                let repo = store.prRepo(forProject: project)
                let needsLink = repo == nil && store.prAutoLinkFailed.contains(project)
                Button(action: onRepository) {
                    HStack(spacing: 8) {
                        Text("Repository").foregroundStyle(Color.hqLabel)
                        Spacer(minLength: 12)
                        Text(repo.map { SessionStore.folderName($0.path) } ?? "Not Linked")
                            .foregroundStyle(needsLink ? Color.hqOrange : Color.hqLabel2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        SettingsChevron()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("sessions.projectSettings.repository")
            }
        } header: { HQSectionLabel { Text("Coding") } } footer: { HQSectionFooter {
            Text("Shows pull request status, checks, and diff size on this project’s chats.")
        } }
    }

    // MARK: Notifications

    private var notifications: some View {
        Section {
            Picker("Notifications", selection: bound({ store.projectNotify(project) }) { store.setProjectNotify(project, $0) }) {
                ForEach(ProjectNotify.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("sessions.projectSettings.notify")
        } header: { HQSectionLabel { Text("Notifications") } } footer: { HQSectionFooter {
            Text("Approval requests and questions always notify you. New chats are included once this \(DeviceWord.name) has seen them.")
        } }
    }

    // MARK: New Chats

    /// The picker's tag for a model: its provider and id; "" for the bot's own.
    private static func tag(_ provider: String?, _ model: String?) -> String {
        guard let model, !model.isEmpty else { return botsDefault }
        return (provider ?? "") + join + model
    }

    private var chosenModel: String {
        let choice = store.projectNewChat(project)
        return Self.tag(choice.provider, choice.model)
    }

    /// The chosen model when the list doesn't name it (not loaded yet, or the bot no longer has it): still shown.
    private var strayModel: ProjectNewChat? {
        let choice = store.projectNewChat(project)
        guard let model = choice.model else { return nil }
        let listed = providers.contains { $0.slug == choice.provider && $0.models.contains(model) }
        return listed ? nil : choice
    }

    private var newChats: some View {
        Section {
            Picker("Model", selection: bound({ chosenModel }) { tag in
                var choice = store.projectNewChat(project)
                let parts = tag.components(separatedBy: Self.join)
                if tag == Self.botsDefault || parts.count != 2 {
                    choice.provider = nil
                    choice.model = nil
                } else {
                    choice.provider = parts[0].isEmpty ? nil : parts[0]
                    choice.model = parts[1]
                }
                store.setProjectNewChat(project, choice)
            }) {
                Text("Bot’s Default").tag(Self.botsDefault)
                if let stray = strayModel, let model = stray.model {
                    Text(ModelNames.displayModelName(model, provider: stray.provider ?? "")).tag(Self.tag(stray.provider, model))
                }
                ForEach(providers) { provider in
                    Section(provider.name) {
                        ForEach(provider.models, id: \.self) { model in
                            Text(ModelNames.displayModelName(model, provider: provider.slug)).tag(Self.tag(provider.slug, model))
                        }
                    }
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("sessions.projectSettings.model")
            Picker("Reasoning", selection: bound({ store.projectNewChat(project).reasoning ?? Self.botsDefault }) { level in
                var choice = store.projectNewChat(project)
                choice.reasoning = level == Self.botsDefault ? nil : level
                store.setProjectNewChat(project, choice)
            }) {
                Text("Bot’s Default").tag(Self.botsDefault)
                ForEach(ConfigCopy.reasoningEfforts, id: \.self) { level in
                    Text(Self.reasoningTitle(level)).tag(level)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("sessions.projectSettings.reasoning")
        } header: { HQSectionLabel { Text("New Chats") } } footer: { HQSectionFooter {
            Text(Self.newChatsFooter(bot: bot?.name, loaded: modelsLoaded, any: !providers.isEmpty))
        } }
    }

    /// A reasoning level as Settings › Models names it ("Off", "Extra High", "Medium").
    nonisolated static func reasoningTitle(_ level: String) -> String {
        ConfigCopy.optionLabels["agent.reasoning_effort"]?[level] ?? level.prefix(1).uppercased() + level.dropFirst()
    }

    nonisolated static func newChatsFooter(bot: String?, loaded: Bool, any: Bool) -> String {
        let start = "New chats you start in this project use these."
        guard let bot else { return start }
        if loaded, !any { return start + " \(bot)’s models couldn’t be listed." }
        return start + " The models are \(bot)’s."
    }

    // MARK: Icon Guide

    /// [coding-pr-review] Owner 2026-11-21 (option B): the page's marks explained, one row in a last section (Home's
    /// page too). It was the project header's ⓘ.
    @ViewBuilder private var iconGuide: some View {
        if let onIconGuide {
            Section {
                NavRow(title: "Icon Guide", action: onIconGuide)
                    .accessibilityIdentifier("sessions.projectSettings.iconGuide")
            }
        }
    }

    // MARK: Look

    private var look: some View {
        Section {
            HStack {
                Text("Icon").foregroundStyle(Color.hqLabel)
                Spacer(minLength: 12)
                TextField("Emoji", text: $emoji, prompt: Text("None"))
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .frame(maxWidth: 120)
                    .accessibilityIdentifier("sessions.projectSettings.emoji")
                    .onChange(of: emoji) { was, typed in
                        // One character: the one just typed stands, wherever the caret was.
                        let one = ProjectLook.oneEmoji(typed, replacing: was) ?? ""
                        if one != typed { emoji = one; return }
                        var look = store.projectLook(project)
                        guard look.emoji != (one.isEmpty ? nil : one) else { return }
                        look.emoji = one.isEmpty ? nil : one
                        store.setProjectLook(project, look)
                        tick += 1
                        onChange()
                    }
                if !emoji.isEmpty {
                    // The way back to no icon, whatever side of the character the caret is on.
                    Button { emoji = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(Font.hq(.body)).foregroundStyle(Color.hqLabel3)
                            .frame(width: 30, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Clear Icon")
                    .accessibilityIdentifier("sessions.projectSettings.emojiClear")
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Color").foregroundStyle(Color.hqLabel)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 0)], alignment: .leading, spacing: 0) {
                    swatch(nil)
                    ForEach(SessionColors.names.indices, id: \.self) { swatch($0) }
                }
            }
            if coding {
                Toggle("Show Branch on Rows", isOn: bound({ store.isProjectBranchRows(project) }) { store.setProjectBranchRows(project, $0) })
                    .accessibilityIdentifier("sessions.projectSettings.branchRows")
            }
        } header: { HQSectionLabel { Text("Look") } }
    }

    /// One colour (nil: None): a 28 pt disc in a 44 pt touch, ringed while it is the project's.
    private func swatch(_ index: Int?) -> some View {
        let picked = store.projectLook(project).color == index
        let name = index.flatMap { SessionColors.name($0) } ?? "None"
        return Button {
            Haptics.play(.selection)
            var look = store.projectLook(project)
            look.color = index
            store.setProjectLook(project, look)
            tick += 1
            onChange()
        } label: {
            ZStack {
                if let index {
                    Circle().fill(Color(uiColor: SessionsOrganizer.uiColor(index))).frame(width: 28, height: 28)
                } else {
                    Circle().strokeBorder(Color.hqLabel3, lineWidth: 1.5).frame(width: 28, height: 28)
                    Image(systemName: "slash.circle").font(Font.hq(.body)).foregroundStyle(Color.hqLabel2)
                }
                if picked { Circle().strokeBorder(Color.hqTint, lineWidth: 2).frame(width: 36, height: 36) }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(name)
        .accessibilityAddTraits(picked ? .isSelected : [])
        .accessibilityIdentifier("sessions.projectSettings.color.\(index.map(String.init) ?? "none")")
    }
}

/// [project-look] A project's own mark: its emoji (on a disc of its colour, when it has both), or a folder in its colour.
/// `ink`: the colour a mark without a colour of its own takes (a picked pill's is the pill's ink).
struct ProjectLookMark: View {
    var look: ProjectLook
    var size: CGFloat = 16
    var ink: Color? = nil

    var body: some View {
        let colour = look.color.map { Color(uiColor: SessionsOrganizer.uiColor($0)) }
        Group {
            if let emoji = look.emoji {
                Text(emoji)
                    .font(Font.hqSystem(size: HQFont.scaled(size * 0.82)))
                    .frame(width: HQFont.scaled(size + 4), height: HQFont.scaled(size + 4))
                    .background { if let colour { Circle().fill(colour.opacity(0.32)) } }
            } else {
                Image(systemName: "folder.fill")
                    .font(Font.hqSystem(size: HQFont.scaled(size * 0.86), weight: .medium))
                    .foregroundStyle(ink ?? colour ?? Color.hqLabel2)
            }
        }
        .accessibilityHidden(true)
    }
}
