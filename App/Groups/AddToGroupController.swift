// [groups] Add to Group Chat… (docs/spec/3x-groups.md §7.7; the web's manage-groups dialog): one switch per room for a
// bot, Create & join for a room of its own, Remove from all groups. Its own sheet from the Bots list; a page pushed
// inside Bot Info's sheet from there.

import SwiftUI
import UIKit

/// The rules of a room's switch for one bot, apart from the screen (unit tests read them).
nonisolated enum GroupJoinRules {
    enum State: Equatable {
        case open                  // the switch works
        case full                  // not a member and the room has 6
        case floor                 // a member and the room has 2 or fewer
    }

    static func state(member: Bool, count: Int) -> State {
        if !member, count >= GroupLimits.maxMembers { return .full }
        if member, count <= GroupLimits.minMembers { return .floor }
        return .open
    }

    static func subtitle(member: Bool, count: Int) -> String {
        switch state(member: member, count: count) {
        case .open: GroupRowWords.bots(count)
        case .full: "Full (6 bots)"
        case .floor: "Needs at least 2 bots"
        }
    }

    /// Remove from all groups shows when the bot is in at least one room and leaving drops none below 2.
    static func canRemoveAll(memberCounts: [Int]) -> Bool {
        !memberCounts.isEmpty && memberCounts.allSatisfy { $0 > GroupLimits.minMembers }
    }

    static func emptyLine(bot: String, anyRooms: Bool) -> String {
        anyRooms ? "\(bot) isn’t in any of these group chats yet. Turn one on, or name a new one."
            : "\(bot) isn’t in any group chats yet. Name one below to create it."
    }
}

@MainActor @Observable
final class AddToGroupModel {
    let botId: String
    let botName: String
    var version = 0
    /// Rooms whose write is in flight (their switch shows a spinner).
    var busy: Set<String> = []
    var newName = ""
    var creating = false
    var removing = false
    /// `A group named “<name>” already exists.`
    var problem: String?
    var online = true
    @ObservationIgnored let services: any GroupServices
    @ObservationIgnored weak var host: UIViewController?

    struct Row: Identifiable, Equatable {
        var id: String
        var name: String
        var image: String?
        var faces: [GroupRowModel.Face]
        var member: Bool
        var count: Int
    }

    init(bot: Bot, services: any GroupServices) {
        botId = bot.id
        botName = bot.name
        self.services = services
        online = services.groupsWritable
    }

    var store: GroupStore? { services.groupStore }

    var rows: [Row] {
        _ = version
        guard let store else { return [] }
        let mine = Set(store.rooms(of: botId).map(\.key))
        return store.rooms.map { room in
            let seats = store.seated(room)
            return Row(id: room.key, name: room.name, image: room.image,
                       faces: seats.prefix(3).map { GroupRowModel.Face(profile: $0.name, head: $0.head) },
                       member: mine.contains(room.key), count: seats.count)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var canRemoveAll: Bool { GroupJoinRules.canRemoveAll(memberCounts: rows.filter(\.member).map(\.count)) }
    var working: Bool { creating || removing || !busy.isEmpty }

    func set(_ row: Row, member: Bool) {
        guard online, let store, !busy.contains(row.id), row.member != member,
              GroupJoinRules.state(member: row.member, count: row.count) == .open else { return }
        Haptics.play(.selection)
        busy.insert(row.id)
        let key = row.id, profile = botId, name = botName
        Task {
            defer { busy.remove(key); version += 1 }
            do {
                try await store.setMembership(profile: profile, room: key, member: member, botName: name)
            } catch {
                // The switch reads the store, so it is back where it was.
                FailureAlert.present(error, fallbackTitle: "Couldn’t Change \(name)’s Group Chats", from: host) {
                    guard let now = self.rows.first(where: { $0.id == key }) else { return }
                    self.set(now, member: member)
                }
            }
        }
    }

    func createAndJoin() {
        let name = GroupKeys.cleanName(newName)
        guard online, let store, !name.isEmpty, !creating else { return }
        problem = nil
        creating = true
        let profile = botId, bot = botName
        Task {
            defer { creating = false; version += 1 }
            do {
                _ = try await store.createSolo(name: name, profile: profile, botName: bot)
                Haptics.play(.success)
                newName = ""
            } catch let taken as GroupNameTaken {
                problem = taken.errorDescription
                Haptics.play(.warning)
            } catch {
                FailureAlert.present(error, fallbackTitle: "Couldn’t Change \(bot)’s Group Chats", from: host) { self.createAndJoin() }
            }
        }
    }

    /// Asked first: it leaves every room at once.
    func confirmRemoveAll() {
        guard online, canRemoveAll, let host else { return }
        let sheet = UIAlertController(title: "Remove \(botName) from all group chats?",
                                      message: "The group chats and their history are kept.", preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Remove from All Group Chats", style: .destructive) { [weak self] _ in self?.removeAll() })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = host.view
            popover.sourceRect = CGRect(x: host.view.bounds.midX, y: host.view.bounds.maxY - 80, width: 0, height: 0)
        }
        host.present(sheet, animated: true)
    }

    private func removeAll() {
        guard let store, !removing else { return }
        removing = true
        let keys = rows.filter(\.member).map(\.id), profile = botId, name = botName
        Task {
            defer { removing = false; version += 1 }
            do {
                for key in keys { try await store.setMembership(profile: profile, room: key, member: false, botName: name) }
                Haptics.play(.success)
            } catch {
                FailureAlert.present(error, fallbackTitle: "Couldn’t Change \(name)’s Group Chats", from: host) { self.removeAll() }
            }
        }
    }
}

final class AddToGroupController: UIHostingController<HQScaledRoot<AddToGroupView>> {
    let model: AddToGroupModel
    private var observer: UUID?
    private var timer: Timer?

    /// The sheet from a bot's row: More › Add to Group Chat…
    static func present(bot: Bot, from host: UIViewController, services: any GroupServices) {
        let page = AddToGroupController(bot: bot, services: services, inSheet: false)
        let navigation = UINavigationController(rootViewController: page)
        SheetStyle.apply(navigation, from: host)   // UX study #161: a form sheet in two panes
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        host.present(navigation, animated: true)
    }

    /// `inSheet`: pushed inside Bot Info's sheet (Back returns there); else its own sheet with Done.
    init(bot: Bot, services: any GroupServices, inSheet: Bool) {
        let model = AddToGroupModel(bot: bot, services: services)
        self.model = model
        super.init(rootView: HQScaledRoot(AddToGroupView(model: model)))
        model.host = self
        title = "\(bot.name) · Groups"
        navigationItem.largeTitleDisplayMode = .never
        if !inSheet {
            let done = UIBarButtonItem.hqClose(.done, action: UIAction { [weak self] _ in self?.dismiss(animated: true) })
            done.accessibilityIdentifier = "add-to-group.done"
            navigationItem.rightBarButtonItem = done
        }
        observer = services.groupStore?.observe { [weak self] in self?.model.version += 1 }
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit {
        if let observer { model.store?.stopObserving(observer) }
        timer?.invalidate()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
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

    private func refreshOnline() {
        let online = model.services.groupsWritable
        if model.online != online { model.online = online }
    }
}

struct AddToGroupView: View {
    @Bindable var model: AddToGroupModel

    var body: some View {
        let rows = model.rows
        let inAny = rows.contains(where: \.member)
        List {
            Section {
                Text("A bot can be in several group chats.")
                    .font(Font.hq(.subheadline))
                    .foregroundStyle(Color.hqLabel2)
                    .fixedSize(horizontal: false, vertical: true)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            }
            .listSectionSpacing(.compact)

            Section {
                ForEach(rows) { row in roomRow(row) }
            } footer: { HQSectionFooter {
                if !inAny {
                    Text(GroupJoinRules.emptyLine(bot: model.botName, anyRooms: !rows.isEmpty))
                        .accessibilityIdentifier("add-to-group.empty")
                }
            } }

            Section {
                TextField("New group chat…", text: $model.newName)
                    .textInputAutocapitalization(.words)
                    .accessibilityIdentifier("add-to-group.name")
                    .onChange(of: model.newName) { _, next in
                        if next.count > GroupLimits.nameMax { model.newName = String(next.prefix(GroupLimits.nameMax)) }
                        model.problem = nil
                    }
                Button { model.createAndJoin() } label: {
                    HStack {
                        Text("Create and Join")
                        Spacer(minLength: 0)
                        if model.creating { ProgressView() }
                    }
                }
                .disabled(GroupKeys.cleanName(model.newName).isEmpty || model.working || !model.online)
                .accessibilityIdentifier("add-to-group.create")
            } footer: { HQSectionFooter {
                if let problem = model.problem {
                    Text(problem).foregroundStyle(Color.red).accessibilityIdentifier("add-to-group.problem")
                }
            } }

            if model.canRemoveAll {
                Section {
                    Button(role: .destructive) { model.confirmRemoveAll() } label: {
                        HStack {
                            Text("Remove from All Group Chats")
                            Spacer(minLength: 0)
                            if model.removing { ProgressView() }
                        }
                    }
                    .disabled(model.working || !model.online)
                    .accessibilityIdentifier("add-to-group.remove-all")
                }
            }
        }
        .hqGroupedPage()   // [desktoplook] the page follows the skin
        .listStyle(.insetGrouped)
        .contentMargins(.top, 0, for: .scrollContent)
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("add-to-group.list")
    }

    @ViewBuilder private func roomRow(_ row: AddToGroupModel.Row) -> some View {
        let state = GroupJoinRules.state(member: row.member, count: row.count)
        let busy = model.busy.contains(row.id)
        HStack(spacing: 12) {
            GroupAvatar(image: row.image, faces: row.faces, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).foregroundStyle(Color.hqLabel)
                Text(GroupJoinRules.subtitle(member: row.member, count: row.count))
                    .font(Font.hq(.subheadline))
                    .foregroundStyle(Color.hqLabel2)
            }
            Spacer(minLength: 8)
            if busy {
                ProgressView().accessibilityIdentifier("add-to-group.busy.\(row.name)")
            } else {
                Toggle("", isOn: Binding(get: { row.member }, set: { model.set(row, member: $0) }))
                    .labelsHidden()
                    .disabled(state != .open || !model.online || model.working)
                    .accessibilityLabel(row.name)
                    .accessibilityIdentifier("add-to-group.switch.\(row.name)")
            }
        }
        .padding(.vertical, 4)
    }
}
