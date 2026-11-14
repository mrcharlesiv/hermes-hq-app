// [groups] Group Info (docs/spec/3x-groups.md §7.2; `S/ui-bots/info-state.ts:140-180`): one page sheet with its own
// navigation stack, built like Bot Info — the room's header and tiles, Members, Room, Notifications, Organize and
// Delete Group Chat. A member's Bot Info, the bots picker, Name & Photo and Activity are pages pushed inside it, never
// a sheet over a sheet.

import SwiftUI
import UIKit

@MainActor enum GroupInfoSheet {
    /// The page the sheet opens on (the room's ⋯ menu goes straight to the picker or to Activity).
    enum Start { case info, members, activity }

    static func present(roomKey: String, from presenter: UIViewController, services: any GroupServices, start: Start = .info) {
        guard let store = services.groupStore, let room = store.room(roomKey) else { return }
        let info = GroupInfoController(uid: room.uid.value, services: services)
        let navigation = UINavigationController(rootViewController: info)
        SheetStyle.apply(navigation, from: presenter)   // [m9/ipad] a centred form sheet in two panes (§4.8)
        let guardian = SheetEditGuard(navigation: navigation)
        navigation.presentationController?.delegate = guardian
        objc_setAssociatedObject(navigation, &guardKey, guardian, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        switch start {
        case .info: break
        case .members:
            if services.groupsWritable { navigation.pushViewController(GroupBotsPickerController(editing: room.uid.value, services: services), animated: false) }
        case .activity:
            navigation.pushViewController(GroupActivityController(uid: room.uid.value, services: services), animated: false)
        }
        presenter.present(navigation, animated: true)
    }

    nonisolated(unsafe) private static var guardKey: UInt8 = 0
}

@MainActor @Observable
final class GroupInfoModel {
    let uid: UUID
    /// Bumped on every change of the store or the mutes (neither is observable by itself).
    var version = 0
    var online = true
    @ObservationIgnored let services: any GroupServices
    @ObservationIgnored weak var host: UIViewController?

    init(uid: UUID, services: any GroupServices) {
        self.uid = uid
        self.services = services
        online = services.groupsWritable
    }

    var store: GroupStore? { services.groupStore }
    var room: GroupRoom? { _ = version; return store?.room(uid: uid) }
    var seats: [GroupSeat] { room.flatMap { store?.seated($0) } ?? [] }
    var faces: [GroupRowModel.Face] { seats.prefix(3).map { GroupRowModel.Face(profile: $0.name, head: $0.head) } }
    var row: GroupRowModel? {
        guard let key = room?.key else { return nil }
        return store?.rows().first { $0.id == key }
    }

    /// The room's status line while something is going on, else `1 bot` / `N bots`.
    var subtitle: String {
        if let row, row.tone != .secondary { return row.line }
        return GroupRowWords.bots(seats.count)
    }

    var unread: Bool { room.map { store?.isUnread($0.key) ?? false } ?? false }
    var mute: BotMute? { _ = version; return room.flatMap { BotMuteCenter.shared.mute(of: GroupKeys.muteKey($0.key)) } }
    var muteValue: String { BotMutes.value(mute) }
    var floor: Bool { seats.count <= GroupLimits.minMembers }
    /// [hosted] Hermes runs this room and keeps the bots it was made with.
    var fixedMembers: Bool { room?.isHosted == true }

    /// A member's second line: what it is doing, where it lives, else its role.
    func line(for seat: GroupSeat) -> String? {
        if seat.remote { return seat.remoteLabel.flatMap { $0.isEmpty ? nil : "On \($0)" } ?? "On another gateway" }
        if let room, room.running, room.turn?.name == seat.name { return "Replying…" }
        if seat.missing { return "Can’t reach this bot" }
        return store?.bots?.bot(named: seat.name)?.role.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Bot Info of a member opens only for a bot of this gateway that the roster still has.
    func canOpen(_ seat: GroupSeat) -> Bool {
        seat.canDrive && store?.bots?.bot(named: seat.name) != nil && (services as? SettingsServices)?.botEditing != nil
    }

    // MARK: Picks

    func open(_ seat: GroupSeat) {
        guard canOpen(seat), let bot = store?.bots?.bot(named: seat.name), let app = services as? AppServices,
              let navigation = host?.navigationController else { return }
        let info = BotInfoController(botId: bot.id, fallback: bot, services: app)
        // Pushed inside this sheet: Back returns to Group Info (the page's own ✕ would close the whole sheet).
        info.navigationItem.hqRemoveClose()   // [mac] #55: on the Mac it sits trailing
        navigation.pushViewController(info, animated: true)
    }

    func editMembers() {
        guard online, let navigation = host?.navigationController else { return }
        navigation.pushViewController(GroupBotsPickerController(editing: uid, services: services), animated: true)
    }

    func nameAndPhoto() {
        guard online, let navigation = host?.navigationController else { return }
        navigation.pushViewController(GroupNamePhotoController(uid: uid, services: services), animated: true)
    }

    func activity() {
        host?.navigationController?.pushViewController(GroupActivityController(uid: uid, services: services), animated: true)
    }

    func toggleUnread() {
        guard let key = room?.key else { return }
        GroupActions.toggleUnread(key, services: services)
    }

    func toggleMute() {
        guard let key = room?.key else { return }
        Haptics.play(.selection)
        if BotMuteCenter.shared.toggle(GroupKeys.muteKey(key)) { BotMuteCenter.shared.markTipSeen() }
    }

    func setMute(_ choice: MuteChoice) {
        guard let key = room?.key else { return }
        GroupActions.setMute(key, choice)
    }

    func setPinned(_ on: Bool) {
        guard let key = room?.key, room?.pinned != on else { return }
        Haptics.play(.selection)
        store?.setPinned(key, on)
    }

    /// Show in Bots (UX study #254's Hide, this iPhone only); the list's own menu offers the same (audit 05-15).
    func setShown(_ shown: Bool) {
        guard let key = room?.key, room?.hidden == shown else { return }
        Haptics.play(.selection)
        store?.setHidden(key, !shown)
    }

    /// The user sections this device knows (Section is offered only when there are some).
    var sectionRecords: [RosterSectionRecord] {
        ((services as? SettingsServices)?.botEditing?.sectionRecords ?? []).filter { $0.id != RosterRules.pinnedSectionId }
    }

    /// The room's section as the list files it: a section this device no longer has is none.
    var sectionId: String? { room?.sectionId.flatMap { id in sectionRecords.contains { $0.id == id } ? id : nil } }

    var sectionName: String { sectionId.flatMap { id in sectionRecords.first { $0.id == id }?.name } ?? BotListLayout.unassignedName }

    func move(to section: String?) {
        guard let key = room?.key, sectionId != section else { return }
        Haptics.play(.light)   // as the list's Move to Section for a room
        store?.setSection(key, section)
    }

    /// The question of §7.1; the sheet closes when the room is gone.
    func delete() {
        guard online, let key = room?.key, let host else { return }
        GroupActions.confirmDelete(key, services: services, from: host, source: nil)
    }
}

final class GroupInfoController: UIHostingController<HQScaledRoot<GroupInfoView>> {
    let model: GroupInfoModel
    private var timer: Timer?
    private var observer: UUID?
    private var muteObserver: UUID?

    init(uid: UUID, services: any GroupServices) {
        let model = GroupInfoModel(uid: uid, services: services)
        self.model = model
        super.init(rootView: HQScaledRoot(GroupInfoView(model: model)))
        model.host = self
        title = "Group Info"
        navigationItem.largeTitleDisplayMode = .never
        let close = UIBarButtonItem.hqClose(action: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        close.accessibilityIdentifier = "group-info.close"
        navigationItem.hqPlaceClose(close)   // [mac] Stress test 2026-10-28 #55: trailing on the Mac
        observer = services.groupStore?.observe { [weak self] in self?.changed() }
        muteObserver = BotMuteCenter.shared.observe { [weak self] in self?.model.version += 1 }
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit {
        if let observer { model.store?.stopObserving(observer) }
        if let muteObserver { BotMuteCenter.shared.stopObserving(muteObserver) }
        timer?.invalidate()
    }

    /// The store changed: the page redraws; a room deleted here or on another device closes the sheet.
    private func changed() {
        model.version += 1
        guard model.store?.room(uid: model.uid) == nil else { return }
        // After the room screen's own handler (it dismisses what it presents, then pops): never two dismissals at once.
        DispatchQueue.main.async { [weak self] in
            guard let self, let navigation = self.navigationController, navigation.presentingViewController != nil,
                  !navigation.isBeingDismissed else { return }
            navigation.dismiss(animated: true)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if let navigationController {
            EditingGuard.refreshLock(navigationController)
            navigationController.interactivePopGestureRecognizer?.isEnabled = true
        }
        model.version += 1
        refreshOnline()
        timer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refreshOnline() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        timer?.invalidate()
        timer = nil
    }

    /// Writes are off (rows dimmed) while the gateway link is not ready; a timed mute's value follows the clock.
    private func refreshOnline() {
        let online = model.services.groupsWritable
        if model.online != online { model.online = online }
    }
}

struct GroupInfoView: View {
    @Bindable var model: GroupInfoModel

    var body: some View {
        if let room = model.room {
            content(room)
        } else {
            Color.clear
        }
    }

    @ViewBuilder private func content(_ room: GroupRoom) -> some View {
        let seats = model.seats
        List {
            Section {
                VStack(spacing: 10) {
                    GroupAvatar(image: room.image, faces: model.faces, size: 80)
                    Text(room.name)
                        .font(Font.hq(.title2).weight(.semibold))
                        .foregroundStyle(Color.hqLabel)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("group-info.name")
                    Text(model.subtitle)
                        .font(Font.hq(.subheadline))
                        .foregroundStyle(Color.hqLabel2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("group-info.subtitle")
                    tiles.padding(.top, 6)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 4)
                .listRowBackground(Color.clear)
            }
            .listSectionSpacing(.compact)

            Section {
                // [Mac UI check 2026-11-13] Edit Bots and Activity are the tiles above; their rows here were a second way
                // to each (V12, the owner's one place per action).
                ForEach(seats, id: \.key) { seat in memberRow(seat) }
            } header: { HQSectionLabel {
                Text("Members")
            } } footer: { HQSectionFooter {
                if model.floor {
                    Text("A group chat needs at least 2 bots, so none can be removed.").accessibilityIdentifier("group-info.floor")
                }
            } }

            Section {
                Button { model.nameAndPhoto() } label: {
                    HStack {
                        Text("Name & Photo").foregroundStyle(model.online ? Color.hqLabel : Color.hqLabel3)
                        Spacer(minLength: 0)
                        chevron
                    }
                }
                .disabled(!model.online)
                .accessibilityIdentifier("group-info.name-photo")
                Button(model.unread ? "Mark as Read" : "Mark as Unread") { model.toggleUnread() }
                    .accessibilityIdentifier("group-info.unread")
            } header: { HQSectionLabel { Text("Group Chat") } }

            Section {
                Menu {
                    // A timed mute checks no choice: its end time shows checked above them, so the pick reads as taken.
                    if model.mute != nil, BotMutes.choice(model.mute) == nil {
                        Section {
                            Button {} label: { Label(model.muteValue, systemImage: "checkmark") }
                                .disabled(true)
                        }
                    }
                    ForEach(MuteChoice.allCases, id: \.self) { choice in
                        Button { model.setMute(choice) } label: {
                            if BotMutes.choice(model.mute) == choice { Label(choice.title, systemImage: "checkmark") } else { Text(choice.title) }
                        }
                    }
                } label: {
                    HStack {
                        Text("Mute Notifications").foregroundStyle(Color.hqLabel)
                        Spacer()
                        Text(model.muteValue).foregroundStyle(Color.hqLabel2)
                        Image(systemName: "chevron.up.chevron.down").font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel3)
                    }
                }
                .accessibilityIdentifier("group-info.mute")
                .accessibilityValue(model.muteValue)
            } header: { HQSectionLabel {
                Text("Notifications")
            } } footer: { HQSectionFooter {
                Text(BotMutes.scope)
            } }

            Section {
                Toggle("Pinned", isOn: Binding(get: { model.room?.pinned ?? false }, set: { model.setPinned($0) }))
                    .accessibilityIdentifier("group-info.pinned")
                // As Bot Info's Organize: Show in Bots and, with sections, the room's section (audit 05-15).
                Toggle("Show in Bots", isOn: Binding(get: { !(model.room?.hidden ?? false) }, set: { model.setShown($0) }))
                    .accessibilityIdentifier("group-info.shown")
                if !model.sectionRecords.isEmpty {
                    Menu {
                        Button { model.move(to: nil) } label: {
                            if model.sectionId == nil { Label(BotListLayout.unassignedName, systemImage: "checkmark") } else { Text(BotListLayout.unassignedName) }
                        }
                        ForEach(model.sectionRecords, id: \.id) { record in
                            Button { model.move(to: record.id) } label: {
                                if model.sectionId == record.id { Label(record.name, systemImage: "checkmark") } else { Text(record.name) }
                            }
                        }
                    } label: {
                        HStack {
                            Text("Section").foregroundStyle(Color.hqLabel)
                            Spacer()
                            Text(model.sectionName).foregroundStyle(Color.hqLabel2)
                            Image(systemName: "chevron.up.chevron.down").font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel3)
                        }
                    }
                    .accessibilityIdentifier("group-info.section")
                    .accessibilityValue(model.sectionName)
                }
            } header: { HQSectionLabel {
                Text("Organize")
            } } footer: { HQSectionFooter {
                if !model.online {
                    Text("You can change this group chat again once your gateway is back.").accessibilityIdentifier("group-info.offline")
                }
            } }
            .disabled(!model.online)
            .opacity(model.online ? 1 : 0.5)

            Section {
                Button("Delete Group Chat", role: .destructive) { model.delete() }
                    .accessibilityIdentifier("group-info.delete")
            }
            .disabled(!model.online)
        }
        .hqGroupedPage()   // [desktoplook] the page follows the skin
        .listStyle(.insetGrouped)
        .contentMargins(.top, 0, for: .scrollContent)
        .accessibilityIdentifier("group-info.list")
    }

    private var chevron: some View {
        SettingsChevron()
    }

    @ViewBuilder private func memberRow(_ seat: GroupSeat) -> some View {
        let opens = model.canOpen(seat)
        let line = model.line(for: seat)
        Button { model.open(seat) } label: {
            HStack(spacing: 12) {
                HeadImage(raw: seat.head, profile: seat.name, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(seat.display).foregroundStyle(Color.hqLabel)
                    if let line {
                        Text(line)
                            .font(Font.hq(.subheadline))
                            .foregroundStyle(line == "Replying…" ? Color.hqTint : Color.hqLabel2)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                if opens { chevron }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .disabled(!opens)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("group-info.member.\(seat.name)")
    }

    /// Add (or Edit) Bots · Activity · Mute, one row of three as Bot Info's: the same shared tiles, filling the sheet's
    /// width (Mac polish #88: a 340 pt cap left them a narrow cluster in the middle).
    private var tiles: some View {
        let muted = model.mute != nil
        return QuickActionTiles(actions: [
            QuickAction(id: "add", label: model.floor ? "Add Bots" : "Edit Bots", symbol: "person.badge.plus",   // the Members row's words
                        disabled: !model.online || model.fixedMembers, identifier: "group-info.tile.add") { model.editMembers() },
            QuickAction(id: "activity", label: "Activity", symbol: "clock.arrow.circlepath",
                        identifier: "group-info.tile.activity") { model.activity() },
            // The glyph is the state, as the row's muted bell (UX study #249); the label stays the action.
            QuickAction(id: "mute", label: muted ? "Unmute" : "Mute", symbol: muted ? "bell.slash.fill" : "bell.fill",
                        identifier: "group-info.tile.mute", value: muted ? "Muted" : "Not Muted") { model.toggleMute() },
        ])
    }
}

// MARK: - Name & Photo

@MainActor @Observable
final class GroupNamePhotoModel {
    let uid: UUID
    let originalName: String
    let originalImage: String?
    var name: String
    var image: String?
    var saving = false
    /// `A group named “<name>” already exists.`
    var problem: String?
    @ObservationIgnored let services: any GroupServices

    init(uid: UUID, services: any GroupServices) {
        self.uid = uid
        self.services = services
        let room = services.groupStore?.room(uid: uid)
        originalName = room?.name ?? ""
        originalImage = room?.image
        name = originalName
        image = originalImage
    }

    var cleanName: String { GroupKeys.cleanName(name) }
    var nameChanged: Bool { !cleanName.isEmpty && cleanName != originalName }
    var imageChanged: Bool { image != originalImage }
    var hasChanges: Bool { nameChanged || imageChanged }
    var faces: [GroupRowModel.Face] {
        guard let store = services.groupStore, let room = store.room(uid: uid) else { return [] }
        return store.seated(room).prefix(3).map { GroupRowModel.Face(profile: $0.name, head: $0.head) }
    }
}

final class GroupNamePhotoController: UIHostingController<HQScaledRoot<GroupNamePhotoView>>, EditingPage {
    let model: GroupNamePhotoModel
    private var saveItem: UIBarButtonItem!

    init(uid: UUID, services: any GroupServices) {
        let model = GroupNamePhotoModel(uid: uid, services: services)
        self.model = model
        super.init(rootView: HQScaledRoot(GroupNamePhotoView(model: model, choose: {})))
        rootView = HQScaledRoot(GroupNamePhotoView(model: model, choose: { [weak self] in self?.choosePhoto() }))
        title = "Name & Photo"   // the row that opens it
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.hidesBackButton = true
        navigationItem.leftBarButtonItem = UIBarButtonItem.hqClose(.cancel, action: UIAction { [weak self] _ in
            self?.confirmLeaving { self?.navigationController?.popViewController(animated: true) }
        })
        navigationItem.leftBarButtonItem?.accessibilityIdentifier = "group-settings.cancel"
        saveItem = UIBarButtonItem(title: "Save", style: .prominent, target: self, action: #selector(save))
        saveItem.accessibilityIdentifier = "group-settings.save"
        navigationItem.rightBarButtonItem = saveItem
        observe()
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var hasChanges: Bool { model.hasChanges }

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
        navigationItem.hidesBackButton = true
        updateModalLock()
    }

    private func choosePhoto() {
        view.endEditing(true)
        GroupPhotoPicker.present(from: self) { [weak self] url in
            guard let self else { return }
            if let url { self.model.image = url } else { GroupPhotoPicker.failed(from: self) }
        }
    }

    override var keyCommands: [UIKeyCommand]? { (super.keyCommands ?? []) + (saveItem?.isEnabled == true ? [.save("Save", #selector(save))] : []) }
    override var canBecomeFirstResponder: Bool { true }

    @objc private func save() {
        guard model.hasChanges, !model.saving, let store = model.services.groupStore, let key = store.key(model.uid) else { return }
        view.endEditing(true)
        model.problem = nil
        let name = model.nameChanged ? model.cleanName : nil
        let image = model.image, imageChanged = model.imageChanged, uid = model.uid, old = model.originalName
        model.saving = true
        Task {
            defer { model.saving = false }
            do {
                if let name { try await store.rename(key, to: name) }
                // The room may have a new key after its rename (one that had no id).
                if imageChanged, let now = store.key(uid) { store.setImage(now, image) }
                Haptics.play(.success)
                navigationController?.isModalInPresentation = false
                navigationController?.popViewController(animated: true)
            } catch let taken as GroupNameTaken {
                model.problem = taken.errorDescription
                Haptics.play(.warning)
            } catch {
                FailureAlert.present(error, fallbackTitle: "Couldn’t Rename \(old)", from: self) { self.save() }
            }
        }
    }
}

struct GroupNamePhotoView: View {
    @Bindable var model: GroupNamePhotoModel
    var choose: () -> Void

    var body: some View {
        Form {
            Section {
                Text("Rename the group chat or change its group photo. Members and history are kept.")
                    .font(Font.hq(.subheadline))
                    .foregroundStyle(Color.hqLabel2)
                    .fixedSize(horizontal: false, vertical: true)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            }
            .listSectionSpacing(.compact)
            Section {
                HStack(spacing: 16) {
                    GroupAvatar(image: model.image, faces: model.faces, size: 64)
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Choose Photo", action: choose)
                            .hqBorderedButtonStyle()
                            .accessibilityIdentifier("group-settings.choose-photo")
                        if model.image != nil {
                            Button("Remove Photo", role: .destructive) { model.image = nil }
                                .hqBorderedButtonStyle()
                                .accessibilityIdentifier("group-settings.remove-photo")
                        }
                    }
                }
                .padding(.vertical, 12)
            } header: { HQSectionLabel {
                Text("Photo")
            } }
            Section {
                TextField("Group name", text: $model.name)
                    .textInputAutocapitalization(.words)
                    .accessibilityLabel("Group name")
                    .accessibilityIdentifier("group-settings.name")
                    .onChange(of: model.name) { _, next in
                        if next.count > GroupLimits.nameMax { model.name = String(next.prefix(GroupLimits.nameMax)) }
                        model.problem = nil
                    }
            } header: { HQSectionLabel {
                Text("Group name")
            } } footer: { HQSectionFooter {
                if let problem = model.problem {
                    Text(problem).foregroundStyle(Color.red).accessibilityIdentifier("group-settings.problem")
                }
            } }
        }
        .hqGroupedPage()   // [desktoplook] the page follows the skin
        .contentMargins(.top, 0, for: .scrollContent)
        .disabled(model.saving)
        .navigationBarBackButtonHidden(true)
    }
}

// MARK: - Activity

final class GroupActivityController: UIHostingController<HQScaledRoot<GroupActivityView>> {
    private let model: GroupInfoModel
    private var observer: UUID?

    init(uid: UUID, services: any GroupServices) {
        let model = GroupInfoModel(uid: uid, services: services)
        self.model = model
        super.init(rootView: HQScaledRoot(GroupActivityView(model: model)))
        model.host = self
        title = "Activity"
        navigationItem.largeTitleDisplayMode = .never
        observer = services.groupStore?.observe { [weak self] in self?.model.version += 1 }
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit {
        if let observer { model.store?.stopObserving(observer) }
    }
}

/// The current run's events, newest first, each with its symbol and time.
struct GroupActivityView: View {
    @Bindable var model: GroupInfoModel
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let room = model.room
        let events = Array((room.flatMap { model.store?.activity(for: $0.key) } ?? []).reversed())
        let labels = model.store?.labels(model.seats) ?? [:]
        List {
            if events.isEmpty {
                Text("No activity in this turn yet.")
                    .foregroundStyle(Color.hqLabel2)
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("group-activity.empty")
            } else {
                ForEach(Array(events.enumerated()), id: \.offset) { index, event in
                    let line = GroupRowWords.activity(event, name: labels[event.member] ?? event.member)
                    let words = Text(line.text)
                        .foregroundStyle(line.red ? Color.red : Color.hqLabel)
                        .fixedSize(horizontal: false, vertical: true)
                    let time = Text(Date(timeIntervalSince1970: event.at / 1000).formatted(date: .omitted, time: .shortened))
                        .font(Font.hq(.footnote))
                        .monospacedDigit()
                        .foregroundStyle(Color.hqLabel2)
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Image(systemName: line.symbol)
                            .foregroundStyle(line.red ? Color.red : Color.hqLabel2)
                            .frame(minWidth: 24)
                            .accessibilityHidden(true)
                        if typeSize.isAccessibilitySize {
                            // The largest text sizes: the time goes under the words, which keep the row's width.
                            VStack(alignment: .leading, spacing: 4) { words; time }
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            words.frame(maxWidth: .infinity, alignment: .leading)
                            time
                        }
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("group-activity.row.\(index)")
                }
            }
        }
        .hqGroupedPage()   // [desktoplook] the page follows the skin
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("group-activity.list")
    }
}
