// [groups] The app model's group-chat side (docs/spec/3x-groups.md §3, §7.15): one `GroupStore`, `GroupSync` and
// `GroupEngine` per signed-in account, the room sessions the chat screen draws, the room screen itself, focus, mute and
// the alert for a reply that lands while its room is off screen. `AppModel` holds one `GroupsHub` and calls its hooks
// from its own lifecycle (every call there is marked [groups]).

import UIKit

@MainActor final class GroupsHub {
    weak var model: AppModel?
    private(set) var store: GroupStore?
    private(set) var sync: GroupSync?
    private(set) var engine: GroupEngine?
    /// One session per room for as long as a screen holds it.
    private var sessions: [UUID: WeakBox<GroupRoomSession>] = [:]
    /// The member on turn per room (its hidden session is the one whose questions the room shows).
    private var bound: [UUID: (runtime: String, profile: String, stored: String?)] = [:]
    /// The room on screen.
    private(set) var focused: UUID?
    /// Who spoke last in each room (by the room's mute key), for the face on its alert.
    private var speakers: [String: String] = [:]
    private var observer: UUID?
    private var muteObserver: UUID?
    var onChange: (() -> Void)?

    // MARK: Lifecycle (from AppModel)

    func activated(_ model: AppModel, account: GatewayAccount, client: LiveGatewayClient, bots: BotStore) {
        tearDown()
        self.model = model
        let store = GroupStore(account: account, directory: AppModel.listsCacheDirectory, bots: bots)
        store.isOnline = { [weak model] in model?.connection == .ready }
        store.isMuted = { BotMuteCenter.shared.isMuted($0) }
        store.moveMute = { from, to in
            let center = BotMuteCenter.shared
            let mute = center.mute(of: from)
            center.set(from, nil)
            if let to, let mute { center.set(to, mute) }
        }
        let sync = GroupSync(store: store, bots: bots, client: client)
        store.sync = sync
        let engine = GroupEngine(store: store, client: client)
        engine.isFocused = { [weak self, weak store] key in
            guard let self, let focused = self.focused else { return false }
            return store?.room(key)?.uid.value == focused && UIApplication.shared.applicationState == .active
        }
        engine.onRuntime = { [weak self, weak store] key, runtime, profile, stored in
            guard let self, let uid = store?.room(key)?.uid.value else { return }
            self.bound[uid] = (runtime, profile, stored)
            self.sessions[uid]?.value?.bind(runtime: runtime, profile: profile, stored: stored)
        }
        engine.onReply = { [weak self] room, entry, seat in self?.replied(room, entry, seat) }
        store.onRoomRemoved = { [weak self, weak engine] room in
            engine?.roomRemoved(room)
            self?.bound[room.uid.value] = nil
        }
        observer = store.observe { [weak self] in self?.onChange?() }
        muteObserver = BotMuteCenter.shared.observe { [weak self] in self?.onChange?() }
        self.store = store
        self.sync = sync
        self.engine = engine
        rosterChanged()
        onChange?()
    }

    func tearDown() {
        if let observer { store?.stopObserving(observer) }
        if let muteObserver { BotMuteCenter.shared.stopObserving(muteObserver) }
        observer = nil
        muteObserver = nil
        engine?.shutdown()
        sync?.shutdown()
        store?.close()          // the last state is queued for the disk; after this the store never writes again
        store?.sync = nil
        store = nil
        sync = nil
        engine = nil
        sessions = [:]
        bound = [:]
        focused = nil
        speakers = [:]
        DeliveryRoster.set([])
    }

    func rosterChanged() {
        store?.rosterChanged()
        // Deliveries in ordinary chats name their sender from the same roster (§7.12).
        DeliveryRoster.set((model?.bots ?? []).map { DeliveryMessages.Seat(profile: $0.id, name: $0.name, head: $0.head) })
    }

    func connectionChanged(_ state: ConnectionState) {
        for box in sessions.values { box.value?.refreshState() }
        if state == .ready { engine?.wake() }
        onChange?()
    }

    func appActive(_ active: Bool) {
        if active {
            engine?.wake()
        } else {
            store?.saveNow()
            if let sync, sync.hasPending { Task { await sync.flushNow() } }
        }
    }

    // MARK: Sessions

    func session(for key: String) -> GroupRoomSession? {
        guard let store, let engine, let model, let room = store.room(key) else { return nil }
        let uid = room.uid.value
        if let known = sessions[uid]?.value { return known }
        guard let session = GroupRoomSession(key: key, store: store, engine: engine, accountId: store.account.id) else { return nil }
        session.connectionProvider = { [weak model] in model?.connection ?? .connecting }
        session.onObservingChange = { [weak self] on in self?.setFocused(uid, on) }
        if let center = model.serverRequests { session.attachPrompts(center) }
        if let link = bound[uid] { session.bind(runtime: link.runtime, profile: link.profile, stored: link.stored) }
        sessions[uid] = WeakBox(session)
        sessions = sessions.filter { $0.value.value != nil }
        return session
    }

    private func setFocused(_ uid: UUID, _ on: Bool) {
        if on { focused = uid } else if focused == uid { focused = nil }
        // A room on screen is no chat of the notification hub's: its members' replies are told apart here.
        if on { model?.notificationsFocus(runtime: nil, stored: nil) }
    }

    // MARK: A reply while the room is off screen (§7.15)

    private func replied(_ room: GroupRoom, _ entry: GroupMessage, _ seat: GroupSeat?) {
        // The room on screen shows the reply itself: no alert and no peek over its title (as a bot's open chat).
        if room.uid.value == focused, UIApplication.shared.applicationState == .active { return }
        if let seat { speakers[GroupKeys.muteKey(room.key)] = seat.name }
        let name = seat?.display ?? entry.from.name
        let who = NotificationWho(sender: name, chat: "", group: room.name, bot: true)
        // The room's mute, not the member's: the entry's profile is the room's mute key.
        let session = GroupsHub.alertId(room)
        let alert = NotificationHub.Entry(who: who, stored: session, profile: GroupKeys.muteKey(room.key), badge: "")
        let id = "room:\(entry.id ?? String(Int(entry.at)))"
        Task { _ = await NotificationHub.shared.post(kind: "message.complete", session: session, id: id,
                                                      text: NotificationText.preview(entry.text), entry: alert) }
    }

    /// Whether a stored session id is one of the rooms' hidden member sessions (`GroupRoom.sessions`).
    func isMemberSession(_ stored: String) -> Bool {
        !stored.isEmpty && (store?.rooms.contains { $0.sessions.values.contains(stored) } ?? false)
    }

    /// The member whose face a room's alert wears: the one who spoke (`profile` is the alert's, the room's mute key).
    func alertSpeaker(_ profile: String) -> String? { speakers[profile] }

    /// An id the notification rules accept (letters, digits, `_`, `-`).
    static func alertId(_ room: GroupRoom) -> String {
        let raw = "room-" + (room.roomId ?? room.name)
        let clean = String(raw.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? Character($0) : "-" })
        return String(clean.prefix(120))
    }
}

extension AppModel: GroupServices {
    var groupStore: GroupStore? { groupsHub.store }
    var onGroupsChange: (() -> Void)? {
        get { groupsHub.onChange }
        set { groupsHub.onChange = newValue }
    }
    var groupsWritable: Bool { connection == .ready && !readOnlyGateway }

    func room(for key: String) -> (any ChatSessionModel)? { groupsHub.session(for: key) }

    /// The room pushed on the Bots tab (anything over the list closes first); its unread mark clears as it shows.
    func openRoom(_ key: String, from presenter: UIViewController?) {
        guard let root = MainTabController.current else { return }
        let open = { [weak self] in
            guard let self, let list = BotExtras.botsList(), let navigation = list.navigationController,
                  let screen = self.makeRoomScreen(key) else { return }
            _ = root
            Haptics.play(.soft)
            // Next / Previous Chat in the phone layout: the room takes the chat on show's place (`ChatViewController.push`).
            if ChatViewController.replacesTopOnNextPush, navigation.viewControllers.count > 1, let first = navigation.viewControllers.first {
                ChatViewController.replacesTopOnNextPush = false
                navigation.setViewControllers([first, screen], animated: false)
            } else {
                navigation.pushViewController(screen, animated: true)
            }
        }
        // Already showing: nothing to do.
        if let top = root.chatOnShow,
           (top.session as? ChatRoomSurface)?.roomKey == key, root.presentedViewController == nil { return }
        if let presented = root.presentedViewController { presented.dismiss(animated: true, completion: open) } else { open() }
    }

    /// The chat screen for a room: the group avatar in the title, Group Info on a tap, the room's own ⋯ and hold menus.
    func makeRoomScreen(_ key: String) -> UIViewController? {
        guard let session = groupsHub.session(for: key) else { return nil }
        let screen = ChatViewController(session: session)
        screen.promptSheets = promptSheets
        screen.hidesBottomBarWhenPushed = true
        screen.navigationItem.largeTitleDisplayMode = .never
        let avatar = GroupAvatarView(side: 34)
        screen.titleAccessoryView = avatar
        let faces = { [weak self, weak session] () -> (image: String?, faces: [GroupRowModel.Face]) in
            guard let self, let session, let store = self.groupStore, let room = store.room(session.roomKey) else { return (nil, []) }
            return (room.image, store.seated(room).prefix(3).map { GroupRowModel.Face(profile: $0.name, head: $0.head) })
        }
        let look = faces()
        avatar.configure(image: look.image, faces: look.faces)
        screen.onTitleTap = { [weak self, weak screen, weak session] in
            guard let self, let screen, let session else { return }
            GroupInfoSheet.present(roomKey: session.roomKey, from: screen, services: self)
        }
        screen.loadViewIfNeeded()
        var actions = GroupRoomActions()
        actions.isOnline = { [weak self] in self?.groupsWritable ?? false }
        actions.avatar = { [weak avatar] in
            let look = faces()
            avatar?.configure(image: look.image, faces: look.faces)
            return look
        }
        actions.info = { [weak self, weak screen, weak session] in
            guard let self, let screen, let session else { return }
            GroupInfoSheet.present(roomKey: session.roomKey, from: screen, services: self)
        }
        actions.addBots = { [weak self, weak screen, weak session] in
            guard let self, let screen, let session else { return }
            GroupInfoSheet.present(roomKey: session.roomKey, from: screen, services: self, start: .members)
        }
        actions.activity = { [weak self, weak screen, weak session] in
            guard let self, let screen, let session else { return }
            GroupInfoSheet.present(roomKey: session.roomKey, from: screen, services: self, start: .activity)
        }
        actions.delete = { [weak self, weak screen, weak session] in
            guard let self, let screen, let session else { return }
            // On iPad the question points at the room's ⋯, where Delete Group Chat was picked (audit 05-17).
            let more = screen.navigationItem.rightBarButtonItems?.first { $0.accessibilityIdentifier == "chat.more" }
            GroupActions.confirmDelete(session.roomKey, services: self, from: screen, source: nil, sourceItem: more)
        }
        screen.roomChrome?.actions = actions
        // Deleted here or on another device while open: back to the list, which says so.
        session.onRoomGone = { [weak screen] name in
            guard let screen, let navigation = screen.navigationController else { return }
            let pop = {
                var host = navigation.viewControllers.first
                if let root = MainTabController.current, let split = root.split, split.isDouble, navigation === split.detail {
                    // [m9/ipad] Mac polish #9: two panes give the right pane back to its placeholder, as a deleted chat
                    // does; the room's own stack had nothing under it to pop to, so it stayed open with the note over it.
                    root.leave(screen, animated: true)
                    host = split.detail
                } else if navigation.viewControllers.contains(screen) {
                    navigation.popToRootViewController(animated: true)
                }
                if !GroupActions.deletingHere.contains(name) {
                    _ = UndoPill.show(label: "“\(name)” was deleted.", in: host, showsUndo: false) {}
                }
            }
            if let presented = screen.presentedViewController { presented.dismiss(animated: true, completion: pop) } else { pop() }
        }
        return screen
    }
}
