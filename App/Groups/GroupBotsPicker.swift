// [groups] New Group Chat, and a room's Add or Remove Bots… (docs/spec/3x-groups.md §7.5; `HB/create-dialog.tsx`):
// pick 2 to 6 bots, an optional name and photo, then Create writes each bot's `groups` in roster order and opens the
// room. The same page in its edit mode is pushed inside Group Info.

import SwiftUI
import UIKit

@MainActor enum GroupBotsPicker {
    /// Compose › New Group Chat: its own sheet, opening with no field focused.
    static func presentNew(from host: UIViewController, services: any GroupServices) {
        let picker = GroupBotsPickerController(services: services)
        let navigation = UINavigationController(rootViewController: picker)
        SheetStyle.apply(navigation, from: host)   // UX study #161: a form sheet in two panes
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        let guardian = SheetEditGuard(navigation: navigation)
        navigation.presentationController?.delegate = guardian
        objc_setAssociatedObject(navigation, &guardKey, guardian, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        host.present(navigation, animated: true)
    }

    nonisolated(unsafe) private static var guardKey: UInt8 = 0
}

/// The picker's rules, apart from the screen (unit tests read them).
nonisolated enum GroupPickRules {
    static let limitFooter = "A group chat can have up to 6 bots."
    static let floorFooter = "A group chat needs at least 2 bots, so none can be removed."

    enum Tap: Equatable { case added, removed, full, locked }

    /// What a tap on a bot does to the picks. In edit mode a pick cannot be taken away while only 2 remain.
    static func tap(_ profile: String, picked: [String], editing: Bool) -> (picked: [String], result: Tap) {
        if picked.contains(profile) {
            if editing, picked.count <= GroupLimits.minMembers { return (picked, .locked) }
            return (picked.filter { $0 != profile }, .removed)
        }
        if picked.count >= GroupLimits.maxMembers { return (picked, .full) }
        return (picked + [profile], .added)
    }

    static func canCreate(_ count: Int) -> Bool { (GroupLimits.minMembers...GroupLimits.maxMembers).contains(count) }

    /// The name field's placeholder: the picked bots' names, or `Group name` with none.
    static func placeholder(_ names: [String]) -> String { names.isEmpty ? "Group name" : names.joined(separator: ", ") }

    /// The bots of the list for a search (name, role and handle, case-insensitive).
    static func matches(_ bot: Bot, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        return bot.name.lowercased().contains(needle) || bot.id.lowercased().contains(needle)
            || (bot.role?.lowercased().contains(needle) ?? false)
    }
}

@MainActor @Observable
final class GroupPickerModel {
    /// nil: a new room. Else the room being changed.
    let editing: UUID?
    let roomName: String
    let original: [String]
    var picked: [String]
    var name = ""
    var image: String?
    var query = ""
    var saving = false
    /// A seventh pick was refused (the footer says why until a pick is taken away).
    var limitHit = false
    /// A pick could not be taken away (edit mode, 2 left).
    var floorHit = false
    var version = 0
    @ObservationIgnored let services: any GroupServices

    init(editing: UUID?, services: any GroupServices) {
        self.editing = editing
        self.services = services
        let store = services.groupStore
        let room = editing.flatMap { store?.room(uid: $0) }
        roomName = room?.name ?? ""
        // Bots of this gateway only: a member on another gateway is neither listed nor touched.
        let seated = room.map { store?.seated($0) ?? [] }?.filter(\.canDrive).map(\.name) ?? []
        original = seated
        picked = seated
    }

    var roster: BotStore? { services.groupStore?.bots }
    var loading: Bool { _ = version; return (roster?.phase ?? RosterPhase.none) == RosterPhase.none && (roster?.bots.isEmpty ?? true) }

    /// The roster's bots, hidden ones left out unless they are already in the room.
    var bots: [Bot] {
        _ = version
        return (roster?.bots ?? []).filter { !$0.hidden || original.contains($0.id) }
    }

    var shown: [Bot] { bots.filter { GroupPickRules.matches($0, query: query) } }
    var pickedBots: [Bot] { picked.compactMap { id in bots.first { $0.id == id } } }
    var placeholder: String { GroupPickRules.placeholder(pickedBots.map(\.name)) }
    var faces: [GroupRowModel.Face] { pickedBots.prefix(3).map { GroupRowModel.Face(profile: $0.id, head: $0.head) } }
    var changed: Bool { editing == nil ? (!picked.isEmpty || !name.isEmpty || image != nil) : Set(picked) != Set(original) }
    var canSave: Bool {
        guard !saving, GroupPickRules.canCreate(picked.count) else { return false }
        return editing == nil || Set(picked) != Set(original)
    }

    var line: String {
        editing == nil ? "Pick 2–6 bots to talk together."
            : "Pick 2–6 bots for “\(roomName)”. The group chat and its history stay as they are."
    }

    var footer: String? {
        if limitHit { return GroupPickRules.limitFooter }
        if editing != nil, floorHit || picked.count <= GroupLimits.minMembers { return GroupPickRules.floorFooter }
        return nil
    }

    func tap(_ profile: String) {
        let next = GroupPickRules.tap(profile, picked: picked, editing: editing != nil)
        picked = next.picked
        switch next.result {
        case .added, .removed:
            Haptics.play(.selection)
            limitHit = false
            floorHit = false
        case .full:
            Haptics.play(.light)
            limitHit = true
        case .locked:
            Haptics.play(.light)
            floorHit = true
        }
    }

    /// A pick is locked in edit mode while only 2 remain.
    func locked(_ profile: String) -> Bool { editing != nil && picked.contains(profile) && picked.count <= GroupLimits.minMembers }
}

final class GroupBotsPickerController: UIHostingController<HQScaledRoot<GroupBotsPickerView>>, EditingPage {
    let model: GroupPickerModel
    private var saveItem: UIBarButtonItem!
    private let spinner = UIActivityIndicatorView(style: .medium)
    private lazy var spinnerItem = UIBarButtonItem(customView: spinner)

    /// A new room.
    convenience init(services: any GroupServices) { self.init(editing: nil, services: services) }

    /// `editing`: the room whose bots are changed (pushed inside Group Info), nil for a new room.
    init(editing: UUID?, services: any GroupServices) {
        let model = GroupPickerModel(editing: editing, services: services)
        self.model = model
        super.init(rootView: HQScaledRoot(GroupBotsPickerView(model: model, choose: {})))
        rootView = HQScaledRoot(GroupBotsPickerView(model: model, choose: { [weak self] in self?.choosePhoto() }))
        title = editing == nil ? "New Group Chat" : model.roomName
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.hidesBackButton = true
        navigationItem.leftBarButtonItem = UIBarButtonItem.hqClose(.cancel, action: UIAction { [weak self] _ in
            self?.confirmLeaving { self?.leave() }
        })
        navigationItem.leftBarButtonItem?.accessibilityIdentifier = "group-picker.cancel"
        saveItem = UIBarButtonItem(title: editing == nil ? "Create" : "Save", style: .prominent, target: self, action: #selector(save))
        saveItem.accessibilityIdentifier = "group-picker.save"
        navigationItem.rightBarButtonItem = saveItem
        observe()
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var hasChanges: Bool { model.changed }

    private func leave() {
        if model.editing == nil { dismiss(animated: true) } else { navigationController?.popViewController(animated: true) }
    }

    private func observe() {
        withObservationTracking {
            _ = model.canSave
            _ = model.changed
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

    /// A spinner stands in for Create / Save while the writes run.
    private func refreshBar() {
        if model.saving {
            spinner.startAnimating()
            if navigationItem.rightBarButtonItem !== spinnerItem { navigationItem.rightBarButtonItem = spinnerItem }
        } else {
            spinner.stopAnimating()
            if navigationItem.rightBarButtonItem !== saveItem { navigationItem.rightBarButtonItem = saveItem }
            saveItem.setProminentEnabled(model.canSave)
        }
        navigationItem.leftBarButtonItem?.isEnabled = !model.saving
        updateModalLock()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationItem.hidesBackButton = true
        model.version += 1
        updateModalLock()
    }

    private func choosePhoto() {
        view.endEditing(true)
        GroupPhotoPicker.present(from: self) { [weak self] url in
            guard let self else { return }
            if let url { self.model.image = url } else { GroupPhotoPicker.failed(from: self) }
        }
    }

    @objc private func save() {
        guard model.canSave, let store = model.services.groupStore else { return }
        view.endEditing(true)
        let picked = model.picked
        model.saving = true
        if let uid = model.editing {
            guard let key = store.key(uid) else { model.saving = false; return }
            let name = model.roomName
            Task {
                defer { model.saving = false }
                do {
                    try await store.setMembers(key, picked)
                    Haptics.play(.success)
                    navigationController?.isModalInPresentation = false
                    navigationController?.popViewController(animated: true)
                } catch {
                    FailureAlert.present(error, fallbackTitle: "Couldn’t Change \(name)’s Bots", from: self) { self.save() }
                }
            }
            return
        }
        let typed = GroupKeys.cleanName(model.name)
        let name = typed.isEmpty ? GroupKeys.cleanName(model.placeholder) : typed
        let image = model.image
        let services = model.services
        Task {
            do {
                let key = try await store.create(name: name, members: picked, image: image)
                Haptics.play(.success)
                model.saving = false
                // The sheet closes and the new room opens: its empty state names it and its members.
                navigationController?.isModalInPresentation = false
                services.openRoom(key, from: nil)
            } catch {
                model.saving = false
                FailureAlert.present(error, fallbackTitle: "Couldn’t Create \(name)", from: self) { self.save() }
            }
        }
    }
}

struct GroupBotsPickerView: View {
    @Bindable var model: GroupPickerModel
    var choose: () -> Void

    var body: some View {
        let shown = model.shown
        List {
            Section {
                Text(model.line)
                    .font(Font.hq(.subheadline))
                    .foregroundStyle(Color.hqLabel2)
                    .fixedSize(horizontal: false, vertical: true)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                    .accessibilityIdentifier("group-picker.line")
            }
            .listSectionSpacing(.compact)

            if model.editing == nil {
                Section {
                    HStack(spacing: 16) {
                        GroupAvatar(image: model.image, faces: model.faces, size: 64)
                        Button(model.image == nil ? "Add Group Photo" : "Change Photo", action: choose)
                            .hqBorderedButtonStyle()
                            .accessibilityIdentifier("group-picker.photo")
                    }
                    .padding(.vertical, 8)
                    TextField(model.placeholder, text: $model.name)
                        .textInputAutocapitalization(.words)
                        .accessibilityLabel("Group name")
                        .accessibilityIdentifier("group-picker.name")
                        .onChange(of: model.name) { _, next in
                            if next.count > GroupLimits.nameMax { model.name = String(next.prefix(GroupLimits.nameMax)) }
                        }
                }
            }

            if !model.pickedBots.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(model.pickedBots, id: \.id) { bot in chip(bot) }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 2)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("group-picker.chips")
                }
                .listSectionSpacing(.compact)
            }

            Section {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Color.hqLabel2).accessibilityHidden(true)
                    TextField("Search bots to add…", text: $model.query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("group-picker.search")
                    if !model.query.isEmpty {
                        Button { model.query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Color.hqLabel3)
                                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())   // [ui-sizing] was ~20 pt
                        }
                            .buttonStyle(.plain)
                            .padding(.vertical, -10)
                            .accessibilityLabel("Clear search")
                    }
                }
                if model.loading {
                    ForEach(0..<3, id: \.self) { _ in
                        HStack(spacing: 12) {
                            Circle().fill(Color.hqLabel3.opacity(0.3)).frame(width: 40, height: 40)
                            Text("Loading bot name").redacted(reason: .placeholder)
                        }
                        .padding(.vertical, 4)
                        .accessibilityHidden(true)
                    }
                } else if shown.isEmpty {
                    Text(model.query.isEmpty ? "No bots yet." : "No bots match “\(model.query.trimmingCharacters(in: .whitespacesAndNewlines))”.")
                        .foregroundStyle(Color.hqLabel2)
                        .padding(.vertical, 6)
                        .accessibilityIdentifier("group-picker.none")
                } else {
                    ForEach(shown, id: \.id) { bot in row(bot) }
                }
            } footer: { HQSectionFooter {
                if let footer = model.footer {
                    Text(footer).accessibilityIdentifier("group-picker.footer")
                }
            } }
        }
        .hqGroupedPage()   // [desktoplook] the page follows the skin
        .listStyle(.insetGrouped)
        .contentMargins(.top, 0, for: .scrollContent)
        .scrollDismissesKeyboard(.interactively)
        .disabled(model.saving)
        .navigationBarBackButtonHidden(true)
        .accessibilityIdentifier("group-picker.list")
    }

    private func chip(_ bot: Bot) -> some View {
        let locked = model.locked(bot.id)
        return Button { model.tap(bot.id) } label: {
            HStack(spacing: 6) {
                HeadImage(raw: bot.head, profile: bot.id, size: 22)
                Text(bot.name).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel).lineLimit(1)
                if !locked {
                    Image(systemName: "xmark").font(Font.hq(.caption2).weight(.bold)).foregroundStyle(Color.hqLabel2)
                }
            }
            .padding(.leading, 6)
            .padding(.trailing, 10)
            .padding(.vertical, 6)
            .background(Color.hqLabel3.opacity(0.18), in: Capsule())
            .contentShape(Capsule().inset(by: -5))   // [ui-sizing] the chip as drawn, a 44 pt touch (was ~34)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(locked ? bot.name : "Remove \(bot.name) from selection")
        .accessibilityIdentifier("group-picker.chip.\(bot.id)")
    }

    private func row(_ bot: Bot) -> some View {
        let on = model.picked.contains(bot.id)
        let locked = model.locked(bot.id)
        return Button { model.tap(bot.id) } label: {
            HStack(spacing: 12) {
                HeadImage(raw: bot.head, profile: bot.id, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bot.name).foregroundStyle(Color.hqLabel)
                    if let role = bot.role, !role.isEmpty {
                        Text(role).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: locked ? "lock.fill" : (on ? "checkmark.circle.fill" : "circle"))
                    .font(locked ? .body : .title3)
                    .foregroundStyle(on && !locked ? Color.hqTint : Color.hqLabel3)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(bot.name)
        .accessibilityValue(locked ? "Selected, can’t be removed" : (on ? "Selected" : "Not selected"))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("group-picker.bot.\(bot.id)")
    }
}
