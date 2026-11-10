// A Kanban task (docs/spec/1x-pages.md §4.6): a page sheet with ✕ · Task · ⋯. At the top, standing on the page: the
// status (a menu tinted as on the board), the title and who made it; what is happening now (the bot at work with its
// latest update, or a callout for what the board needs from you carrying the one next move, Unblock / Mark Ready /
// Reopen); Assigned To and Priority as two tiles. Then Waiting On / Holding Up (with each task's status); Result;
// the description (folded, Edit); Latest Update, Last Error; Comments / Activity / Runs / Log; attachments (Quick
// Look); Details (dates, model, workspace, ID); Estimate Effort. Reads every 30 s while open.

import SwiftUI
import UIKit

@MainActor @Observable
final class KanbanTaskModel {
    enum Feed: String, CaseIterable { case comments, activity, runs, log }

    var taskId: String
    let store: KanbanStore
    @ObservationIgnored weak var services: PagesServices?
    @ObservationIgnored weak var controller: UIViewController?
    /// [mac-tools] Owner 2026-11-10 (on the board's task panel: "you can do a better job there"): beside the Mac's board
    /// the task is drawn as an inspector, as the chat's right panel is (`InspectorLook`): no cards, the panel's 16 pt
    /// margin, one text size with grey labels, hairlines, pop-up buttons and a push button in place of the sheet's
    /// tiles and its full-width capsule. The sheet on the iPhone and iPad, and the task beside a list, keep theirs.
    @ObservationIgnored var panel = false
    var detail: KanbanTaskDetail?
    var error: String?
    var log: (exists: Bool, content: String) = (false, "")
    var busy: Set<String> = []
    /// [morepages] An attachment upload's progress (0…1) for a file over 1 MB; nil = no bar.
    var uploadProgress: Double?
    var feed: Feed = .comments
    var comment = ""
    var editing: String?
    var estimate: String?
    var notice: String?
    var descriptionOpen = false
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var logTask: Task<Void, Never>?
    @ObservationIgnored private var noticeWork: DispatchWorkItem?
    /// Bumped when a linked task opens in the sheet: a write still on its way for the task before leaves this one's
    /// spinners and fields alone.
    @ObservationIgnored private var generation = 0

    init(taskId: String, store: KanbanStore, services: PagesServices) {
        self.taskId = taskId
        self.store = store
        self.services = services
    }

    var task: KanbanTask? { detail?.task }
    var running: Bool { task?.status == "running" }

    func botName(_ name: String?) -> String { PagesNames.botName(name, bots: services?.bots ?? []) }
    func head(_ name: String) -> JSONValue? { PagesNames.head(name, bots: services?.bots ?? []) }

    // MARK: Reads

    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.read()
                await PowerPolls.wait(.seconds(30), floor: .zero)        // [offline] §6.9
            }
        }
        restartLog()
    }

    func stop() {
        pollTask?.cancel()
        logTask?.cancel()
    }

    /// The log is read every 3 s while its tab shows and the task runs, 15 s while it shows otherwise, else with the task.
    func restartLog() {
        logTask?.cancel()
        logTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.readLog()
                let gap: Duration = self.feed != .log ? .seconds(30) : self.running ? .seconds(3) : .seconds(15)
                await PowerPolls.wait(gap, floor: .zero)                  // [offline] §6.9
            }
        }
    }

    func read() async {
        let id = taskId
        do {
            let fresh = try await store.api.task(id, board: store.slug)
            guard id == taskId else { return }
            detail = fresh
            error = nil
        } catch {
            guard id == taskId else { return }
            if detail == nil { self.error = PagesREST.reason(error) }
        }
    }

    func readLog() async {
        let id = taskId
        if let found = try? await store.api.log(id, board: store.slug), id == taskId { log = found }
    }

    /// A linked task opens in the same sheet.
    func open(_ id: String) {
        taskId = id
        generation += 1
        detail = nil
        error = nil
        editing = nil
        estimate = nil
        // Audit 863 (08c-5): the first task's unsent comment, spinners and note stay with it.
        comment = ""
        busy = []
        notice = nil
        noticeWork?.cancel()
        feed = .comments
        log = (false, "")
        start()
    }

    // MARK: Writes (one per key at a time; the task and the board read again after each)

    func show(_ text: String) {
        notice = text
        noticeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.notice = nil }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        HQAnnounce.say(text)
    }

    private func run(_ key: String, _ write: @escaping (KanbanAPI, String) async throws -> Void, done: (() -> Void)? = nil) {
        guard !busy.contains(key) else { return }
        if store.readOnlyGateway { KanbanFeedback.readOnly(from: controller); return }   // [#134] the Jobs page's lock
        let board = store.slug, api = store.api, generation = self.generation
        busy.insert(key)
        // [weak self] gates only the UI feedback below, not the write itself: the write (and the board's re-read)
        // must finish even if the sheet that started it is gone, since archive/comment/move are fire-and-forget.
        Task { [weak self, store] in
            do {
                try await write(api, board)
                // Archive and comments stay silent (§2.6: the Undo pill / the posted note is the feedback; Send is quiet).
                if !["archive", "comment", "requeue", KanbanWriteWords.restart].contains(key) { PagesHaptics.success() }
                done?()
            } catch {
                // [#134] A write the person made here is an alert with Try Again (a typed comment or description stays
                // in its field); the rest keep the short notice.
                if let self, KanbanWriteWords.failureTitle(key) != nil, self.controller?.view.window != nil {
                    KanbanFeedback.failed(key, reason: PagesREST.reason(error), from: self.controller) { [weak self] in
                        self?.run(key, write, done: done)
                    }
                } else {
                    PagesHaptics.error()
                    self?.show(PagesREST.reason(error))
                }
            }
            if self?.generation == generation { self?.busy.remove(key) }
            await self?.read()
            await store.readBoard()
        }
    }

    func move(_ to: String) {
        guard let task, to != task.status else { return }
        if KanbanModel.isLocked(to) { show(KanbanModel.lockedReason(to)); return }
        let id = task.id
        run("move") { api, board in try await api.patch(id, ["status": .string(to)], board: board) }
    }

    /// "" unassigns (the gateway's reassign takes an empty profile as none).
    func assign(_ profile: String) {
        guard let task, profile != (task.assignee ?? "") else { return }
        let id = task.id
        run("assign") { api, board in try await api.reassign(id, profile: profile, board: board) }
    }

    func setPriority(_ value: Int) {
        guard let task, value != (task.priority ?? 0) else { return }
        let id = task.id
        run("priority") { api, board in try await api.patch(id, ["priority": .number(Double(value))], board: board) }
    }

    func saveBody() {
        guard let task, let text = editing else { return }
        let id = task.id
        run("body", { api, board in try await api.patch(id, ["body": .string(text)], board: board) }) { [weak self] in self?.editing = nil }
    }

    func sendComment(requeue: Bool) {
        let body = comment.pgTrim
        guard let task, !body.isEmpty else { return }
        let id = task.id
        // Post and Start Over is two writes, told apart (audit 863: a failed start again said the comment failed, and
        // Try Again, or Send with the words still in the box, posted the comment twice). Once the comment is posted
        // the box clears; only the start again is tried again.
        run(requeue ? "requeue" : "comment", { api, board in
            try await api.comment(id, body: body, board: board)
        }) { [weak self] in
            guard let self, self.taskId == id else { return }
            self.comment = ""
            guard requeue else { return }
            self.run(KanbanWriteWords.restart, { api, board in try await api.reclaim(id, board: board) }) { [weak self] in
                self?.show("Note posted. The task starts again with it.")
            }
        }
    }

    func reclaim() {
        guard let task else { return }
        let id = task.id
        run("reclaim") { api, board in try await api.reclaim(id, board: board) }
    }

    func runEstimate() {
        guard let task else { return }
        let id = task.id
        run("estimate") { [weak self] api, board in
            let said = try await api.estimate(id, board: board)
            if self?.taskId == id { self?.estimate = said }   // not under a linked task opened since
        }
    }

    func archive() {
        guard let task else { return }
        let id = task.id, from = task.status, board = self.store.slug, store = self.store
        run("archive", { api, board in try await api.patch(id, ["status": "archived"], board: board) }) { [weak self] in
            // [#133] The board's "Archived" pill with Undo once the sheet is down (it closed with no word before).
            (self?.controller as? KanbanTaskHostController)?.close { host in
                if let host { KanbanFeedback.archived(task, from: from, board: board, store: store, on: host) }
                else { PagesHaptics.success() }
            }
        }
    }

    func confirmDelete() {
        guard let task, let controller else { return }
        if store.readOnlyGateway { KanbanFeedback.readOnly(from: controller); return }
        let sheet = UIAlertController(title: "Delete This Task?",
                                      message: "“\(task.title)” is deleted for every bot and device. This can’t be undone.",
                                      preferredStyle: .actionSheet)
        let id = task.id
        sheet.addAction(UIAlertAction(title: "Delete Task", style: .destructive) { [weak self] _ in
            self?.run("delete", { api, board in try await api.delete(id, board: board) }) { [weak self] in
                (self?.controller as? KanbanTaskHostController)?.close()
            }
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceItem = controller.navigationItem.hqOwnRightItem   // [mac] #55: ⋯, not Done
        controller.present(sheet, animated: true)
    }

    func copy(_ text: String, _ what: String) {
        UIPasteboard.general.string = text
        PagesHaptics.success()
        show("Copied \(what)")
    }

    func askPriority() {
        guard let task, let controller else { return }
        let alert = UIAlertController(title: "Priority", message: "Higher numbers are picked up first.", preferredStyle: .alert)
        alert.addTextField { field in
            field.text = String(task.priority ?? 0)
            field.keyboardType = .numberPad
            field.placeholder = "0"
            field.addNumberPadDone()   // [diagnostics]
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        let set = UIAlertAction(title: "Set", style: .default) { [weak self, weak alert] _ in
            let text = alert?.textFields?.first?.text?.pgTrim ?? ""
            // Audit 863: a priority that isn't a whole number is said, not dropped unsaid.
            guard !text.isEmpty else { return }   // nothing typed: nothing changed
            guard let value = Int(text), value >= 0 else {
                PagesHaptics.error()
                self?.show("Priority is a whole number, 0 or more")
                return
            }
            self?.setPriority(value)
        }
        alert.addAction(set)
        alert.preferredAction = set   // [mac] audit 2026-11-02 #17: Return sets it, as every other one-field prompt
        controller.present(alert, animated: true)
    }

    func openAttachment(_ attachment: KanbanAttachment) {
        guard let controller, let account = services?.account else { return }
        let api = store.api, board = store.slug
        busy.insert("attachment-\(attachment.id)")
        Task {
            defer { busy.remove("attachment-\(attachment.id)") }
            do {
                let data = try await api.attachment(attachment.id, board: board)
                let record = ArtifactRecord(id: "kanban:\(attachment.id)", kind: .file, value: attachment.filename, href: attachment.filename,
                                            label: attachment.filename, sessionId: "kanban-\(taskId)", profile: nil, sessionTitle: "", timestamp: 0)
                let url = ArtifactFiles.previewURL(account: account, record: record)
                try await ArtifactFiles.save(data, to: url)
                // A Markdown attachment reads formatted, not as Quick Look's raw text.
                if MarkdownFileSheet.opens(url) { MarkdownFileSheet.present(url, from: controller) }
                else { QuickLookPresenter.present(url: url, from: controller) }
            } catch {
                show(ArtifactFiles.failureText(error, image: false))
            }
        }
    }
}

enum KanbanTaskSheet {
    static func make(taskId: String, store: KanbanStore, services: PagesServices) -> UIViewController {
        let model = KanbanTaskModel(taskId: taskId, store: store, services: services)
        let host = KanbanTaskHostController(model: model)
        let nav = UINavigationController(rootViewController: host)
        SheetStyle.apply(nav, from: nil)   // [m9/ipad] D6: a centred form sheet in two panes (§4.8)
        return nav
    }

    /// [mac] The task as a page of the right pane, beside the board (owner 2026-10-23: Kanban uses the right side of the
    /// window). No ✕: it stays until something else opens there, as a job's page does.
    static func page(taskId: String, store: KanbanStore, services: PagesServices, board: UIViewController) -> UIViewController {
        let model = KanbanTaskModel(taskId: taskId, store: store, services: services)
        model.panel = (board as? KanbanViewController)?.isBoard == true
        let host = KanbanTaskHostController(model: model, sheet: false)
        host.board = board
        // [mac-tools] Beside the Mac's board the task is a panel that closes (the board takes the window back); beside
        // a list it stays until something else opens, as a job's page does.
        if (board as? KanbanViewController)?.isBoard == true {
            let close = UIBarButtonItem(image: UIImage(systemName: "xmark"), primaryAction: UIAction { _ in
                MainTabController.current?.split?.closeDetail(animated: true)
            })
            close.accessibilityLabel = "Close Task"
            close.accessibilityIdentifier = "kanban.task.close"
            host.navigationItem.leftBarButtonItem = close
        }
        return host
    }
}

final class KanbanTaskHostController: UIHostingController<HQScaledRoot<KanbanTaskView>> {
    let model: KanbanTaskModel
    /// [mac] The board beside the task in the right pane: Archive's notice shows over it.
    weak var board: UIViewController?

    init(model: KanbanTaskModel, sheet: Bool = true) {
        self.model = model
        super.init(rootView: HQScaledRoot(KanbanTaskView(model: model)))
        model.controller = self
        title = "Task"
        if sheet {
            // [mac] Stress test 2026-10-28 #55: Done trailing on the Mac, after ⋯.
            navigationItem.hqPlaceClose(UIBarButtonItem.hqClose(action: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            }))
        }
        let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak model] completion in
                guard let model, let task = model.task else { completion([]); return }
                completion([
                    UIMenu(options: .displayInline, children: [
                        UIAction(title: "Copy Title", image: UIImage(systemName: "doc.on.doc")) { _ in model.copy(task.title.isEmpty ? task.id : task.title, "title") },
                        UIAction(title: "Copy Task ID", image: UIImage(systemName: "doc.on.clipboard")) { _ in model.copy(task.id, "task ID") },
                    ]),
                    UIMenu(options: .displayInline, children: [
                        UIAction(title: "Archive", image: UIImage(systemName: "archivebox")) { _ in model.archive() },
                        UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in model.confirmDelete() },
                    ]),
                ])
            },
        ]))
        more.accessibilityLabel = "More"
        navigationItem.rightBarButtonItem = more
        applyBarLook()
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: Theme.didChange, object: nil)
    }

    /// [desktoplook] As every sheet's bar in the look (ThemeChrome, UX study #122): at rest the sheet's own page colour,
    /// opaque (frosted it read as a lighter band over the sheet), frosted once rows pass under it. Never clear, so the
    /// task's text never shows through ✕ · Task · ⋯ ([desktop-frost]). With the look off the sheet keeps the system bar
    /// and its scroll edge.
    private func applyBarLook() {
        if model.panel {
            // [mac-tools] The panel's bar is the board's beside it: the page at rest, no band of its own.
            ListBarAppearance.apply(to: navigationItem)
            return
        }
        if Theme.isDesktop {
            let rest = ThemeChrome.solidBar(solid: true)
            rest.backgroundColor = HQPalette.groupedPage
            navigationItem.standardAppearance = ThemeChrome.solidBar(frosted: true)
            navigationItem.compactAppearance = ThemeChrome.solidBar(frosted: true)
            navigationItem.scrollEdgeAppearance = rest
            navigationItem.compactScrollEdgeAppearance = rest
        } else {
            navigationItem.standardAppearance = nil
            navigationItem.compactAppearance = nil
            navigationItem.scrollEdgeAppearance = nil
            navigationItem.compactScrollEdgeAppearance = nil
        }
    }

    @objc private func themeChanged() { applyBarLook() }

    /// Archive or Delete put the task away: the sheet goes down, or the right pane empties. `done` gets the screen the
    /// board's notice shows over.
    func close(_ done: @escaping (UIViewController?) -> Void = { _ in }) {
        if let presenter = navigationController?.presentingViewController {
            dismiss(animated: true) { done(presenter) }
        } else {
            AppRoot.tabs(view.window)?.leave(self, animated: true)
            done(board)
        }
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "kanban.task"
        if model.panel { view.backgroundColor = HQPalette.page }
        // The keyboard's overlap is this page's own bottom safe area (the SwiftUI list ignores the keyboard region): in
        // a page sheet SwiftUI's avoidance fell ~80 pt short, so a field scrolled "above the keyboard" sat under its
        // suggestion bar (verify round 1).
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
                                               name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    @objc private func keyboardChanged(_ note: Notification) {
        guard isViewLoaded, view.window != nil else { return }
        var overlap: CGFloat = 0
        if note.name != UIResponder.keyboardWillHideNotification,
           let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue {
            let frame = view.convert(end, from: nil)
            let base = view.safeAreaInsets.bottom - additionalSafeAreaInsets.bottom
            overlap = max(0, view.bounds.maxY - frame.minY - base)
        }
        guard abs(additionalSafeAreaInsets.bottom - overlap) > 0.5 else { return }
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        UIView.animate(withDuration: duration, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) { // motion-ok: rides the keyboard
            self.additionalSafeAreaInsets.bottom = overlap
            self.view.layoutIfNeeded()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.start()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        model.stop()
    }
}

struct KanbanTaskView: View {
    @Bindable var model: KanbanTaskModel
    /// The field being typed in: it is scrolled above the keyboard (verify round 1: the List in a page sheet left the
    /// comment field and the description editor behind the keys).
    @FocusState private var focus: Field?
    enum Field: Hashable { case comment, body }
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .subheadline) private var statusDot: CGFloat = 8
    static let commentBoxId = "kanban.task.comment-box"
    static let bodyEditorId = "kanban.task.body-editor"
    static let estimateId = "kanban.task.estimate"
    private var panel: Bool { model.panel }

    var body: some View {
        Group {
            if let detail = model.detail {
                content(detail)
            } else if let error = model.error {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Couldn’t Load This Task")
                            Text("Check your connection, then try again.").font(Font.hq(.footnote)).foregroundStyle(Color.hqRed)
                        }
                    } footer: { HQSectionFooter { Text(error) }}
                }
                .hqGroupedPage()   // [desktoplook] the page follows the skin
            } else {
                HStack(spacing: 8) { ProgressView(); Text("Loading…").foregroundStyle(Color.hqLabel2) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .top) {
            if let notice = model.notice {
                Text(notice)
                    .font(Font.hq(.footnote))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .hqGlassEffect(in: .capsule)
                    .padding(.top, 6)
                    .padding(.horizontal, 24)
                    .transition(.opacity)
                    .accessibilityIdentifier("kanban.task.notice")
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.notice)   // motion-ok: the notice fades (opacity transition)
        .onChange(of: model.feed) { model.restartLog() }
        .environment(\.kanbanTaskPanel, panel)
        .ignoresSafeArea(.keyboard)   // the host controller turns the keyboard into a bottom safe-area inset
    }

    private func content(_ detail: KanbanTaskDetail) -> some View {
        let task = detail.task
        return ScrollViewReader { proxy in List { Group {
            // The top of the page stands on it, with no box round it in either look: the status, title and who made it;
            // what is happening now (the bot at work, or what the board needs from you, with the one move that answers
            // it); then who has it and how soon it goes, as two tiles.
            Section {
                header(task).taskBareRow(top: panel ? 4 : 0, bottom: 2, side: panel ? InspectorLook.margin : 0)
                nowBlock(task).taskBareRow(top: 6, bottom: 6, side: panel ? InspectorLook.margin : 0)
                factTiles(task).taskBareRow(top: 6, bottom: panel ? 8 : 2, side: panel ? InspectorLook.margin : 0)
            }
            .listSectionSeparator(.hidden, edges: .all)

            if !detail.parents.isEmpty {
                Section { links(detail.parents, detail) } header: { HQSectionLabel { Text("Waiting On") } }
            }
            if !detail.children.isEmpty {
                Section { links(detail.children, detail) } header: { HQSectionLabel { Text("Holding Up") } }
            }

            if let result = task.result, !result.isEmpty {
                Section { FoldedMarkdown(text: result) } header: { HQSectionLabel { Label("Result", systemImage: "checkmark.seal") } }
            }

            descriptionSection(task)

            // While the task runs the latest update is in the working card at the top.
            if !model.running, let summary = Self.latestUpdate(task) {
                Section { FoldedMarkdown(text: summary) } header: { HQSectionLabel { Text("Latest Update") } }
            }
            if let failure = task.lastFailureError, !failure.isEmpty {
                Section {
                    Text(failure).font(Font.hqSystem(.caption, design: .monospaced)).foregroundStyle(Color.hqRed).textSelection(.enabled)
                } header: { HQSectionLabel { Text("Last Error") } }
            }

            historySection(detail)

            if let attachments = detail.attachments {
                Section {
                    ForEach(attachments) { attachment in
                        Button { model.openAttachment(attachment) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: Self.fileSymbol(attachment.filename))
                                    .font(Font.hq(.body)).foregroundStyle(Color.hqTint).frame(width: 28)
                                Text(attachment.filename).foregroundStyle(Color.hqLabel).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                if model.busy.contains("attachment-\(attachment.id)") { ProgressView() }
                                else { SettingsChevron() }
                            }
                        }
                    }
                    if model.canAddAttachment { KanbanAddAttachmentRow(model: model) }   // [morepages] §4
                } header: { HQSectionLabel { Text("Attachments") } } footer: { HQSectionFooter {
                    if attachments.isEmpty { Text("Files you add here go to the bot with the task.") }
                } }
            }

            detailsSection(task)

            // Its own box, so the caption sits right under the button it explains (it read as a note on Model).
            Section {
                Button {
                    model.runEstimate()
                } label: {
                    Label {
                        Text(model.estimate ?? (model.busy.contains("estimate") ? "Estimating…" : "Estimate Effort"))
                            .foregroundStyle(model.estimate == nil ? Color.hqTint : Color.hqLabel)
                    } icon: { Image(systemName: "gauge.with.dots.needle.33percent").foregroundStyle(Color.hqTint) }
                }
                .disabled(model.busy.contains("estimate") || model.estimate != nil)
                .id(Self.estimateId)
            } footer: { HQSectionFooter {
                if model.estimate == nil { Text("Asks a model for a rough size of the work.") }
            } }
        }.modifier(TaskPanelRows(panel: panel)) }
        .modifier(TaskListLook(panel: panel))
        // The status pill sits just under the sheet's bar (owner: headers sat too low), not under a first-section gap.
        // 2 pt, as its 44 pt tap area already adds 6 pt over the capsule (it sat 8 pt down before).
        .contentMargins(.top, 2, for: .scrollContent)
        .listSectionSpacing(.compact)
        .refreshable { await model.read() }
        .onChange(of: focus) { _, field in reveal(field, proxy) }
        // Once the keyboard has finished rising the list's inset is final: place the field again against it.
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
            reveal(focus, proxy, delay: 0.05)
        }
        // A posted comment adds a row above the field: keep it in sight.
        .onChange(of: detail.comments.count) { _, _ in if focus == .comment { reveal(.comment, proxy) } }
        #if DEBUG
        // -HQDebugTour task -HQDebugTourTaskScroll YES | end: the history box (or the last box) in view, for the screenshot tour.
        // -HQDebugTourTaskComment <text>: a comment already typed.
        .onAppear {
            if let text = UserDefaults.standard.string(forKey: "HQDebugTourTaskComment") { model.comment = text }
            switch UserDefaults.standard.string(forKey: "HQDebugTourTaskScroll") {
            case "end"?:
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { proxy.scrollTo(Self.estimateId, anchor: .bottom) }
            case "YES"?: reveal(.comment, proxy, delay: 0.6)
            default: break
            }
        }
        #endif
        }
    }

    /// The agent's latest summary, when it says more than the board's own bookkeeping or the result.
    private static func latestUpdate(_ task: KanbanTask) -> String? {
        guard let summary = task.latestSummary, !summary.isEmpty, !KanbanModel.isAdminSummary(summary), summary != task.result else { return nil }
        return summary
    }

    // MARK: Top of the page

    /// The status pill, the title, and who made it when.
    private func header(_ task: KanbanTask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            statusButton(task)
            Text(task.title.isEmpty ? task.id : task.title)
                .font(panel ? Font.hq(.title3).weight(.semibold) : Font.hqSystem(.title2, design: .default, weight: .bold))
                .foregroundStyle(Color.hqLabel)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("kanban.task.title")
            if let made = madeLine(task) {
                Text(made).font(panel ? Font.inspectorDetail : Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, panel ? 0 : 4)
    }

    /// "Created 3h ago by Hermes".
    private func madeLine(_ task: KanbanTask) -> String? {
        let ago = KanbanModel.ago(task.createdAt)
        let by = task.createdBy.flatMap { $0.isEmpty ? nil : model.botName($0) }
        if ago.isEmpty { return by.map { "Created by \($0)" } }
        return "Created \(ago == "Just now" ? "just now" : ago)" + (by.map { " by \($0)" } ?? "")
    }

    /// What is happening now, one block: the bot at work, what the board needs from you, or the usual next move.
    @ViewBuilder
    private func nowBlock(_ task: KanbanTask) -> some View {
        let quick = KanbanModel.quickMove(task.status).flatMap { KanbanModel.isLocked($0.to) ? nil : $0 }
        let diagnostics = task.diagnostics ?? []
        let unassignedReady = task.status == "ready" && task.assignee == nil && model.store.fallback.isEmpty
        VStack(spacing: 12) {
            if task.status == "running" {
                workingCard(task)
            }
            if diagnostics.isEmpty, task.status == "blocked" {
                // A blocked task the board says nothing more about: its reason, with Unblock in the same card.
                TaskCallout(severity: "warning", title: KanbanModel.blockReason(task.blockKind),
                            detail: "The bot stopped and is waiting. Add a comment with what it needs, then unblock it.",
                            primary: quick, model: model)
            }
            ForEach(Array(diagnostics.enumerated()), id: \.offset) { index, diagnostic in
                // The first callout carries the page's one next move (Unblock was drawn twice: a big button over a
                // second one inside the card).
                TaskCallout(diagnostic: diagnostic, primary: index == 0 ? quick : nil, model: model)
            }
            if unassignedReady {
                TaskCallout(severity: "warning", title: "Won’t Run Yet",
                            detail: "No one is assigned and this board has no default bot. Assign it to a bot below.",
                            primary: nil, model: model)
            }
            if let quick, diagnostics.isEmpty, task.status != "blocked" {
                if task.status == "done", let done = task.completedAt {
                    doneCard(done, quick: quick)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        let line = KanbanModel.statusLine(task.status, worker: nil)
                        if !line.isEmpty { Text(line).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).padding(.horizontal, panel ? 0 : 4) }
                        primaryButton(quick)
                    }
                }
            } else if quick == nil, task.status != "running", diagnostics.isEmpty, !unassignedReady {
                let line = KanbanModel.statusLine(task.status, worker: task.assignee.map(model.botName))
                if !line.isEmpty {
                    Text(line).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, panel ? 0 : 4)
                }
            }
        }
    }

    @ViewBuilder
    private func primaryButton(_ quick: (to: String, label: String)) -> some View {
        if panel {
            // A Mac push button, the default one: as wide as its words, at the panel's leading edge.
            Button { model.move(quick.to) } label: {
                Text(model.busy.contains("move") ? "Moving…" : quick.label)
                    .font(Font.hq(.subheadline).weight(.semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 14)
                    .frame(minHeight: MacForm.controlHeight)
                    .background(RoundedRectangle(cornerRadius: Theme.isDesktop ? DesktopRows.radius : MacPush.radius, style: .continuous).fill(Color.hqTint))
                    .contentShape(Rectangle())
            }
            .buttonStyle(MacPopUpButtonStyle())
            .disabled(model.busy.contains("move"))
            .opacity(model.busy.contains("move") ? 0.6 : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("kanban.task.primary")
        } else {
            sheetPrimaryButton(quick)
        }
    }

    private func sheetPrimaryButton(_ quick: (to: String, label: String)) -> some View {
        Button {
            model.move(quick.to)
        } label: {
            Text(model.busy.contains("move") ? "Moving…" : quick.label)
                .font(Font.hq(.body).weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .hqProminentButtonStyle()
        .buttonBorderShape(.capsule)
        .tint(Color.hqTint)
        .disabled(model.busy.contains("move"))
        .accessibilityIdentifier("kanban.task.primary")
    }

    /// The bot doing the task, for how long, and what it last said.
    private func workingCard(_ task: KanbanTask) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                if let who = task.assignee { HeadImage(raw: model.head(who), profile: who, size: 40) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.assignee.map { "\(model.botName($0)) is working on it" } ?? "A bot is working on it")
                        .font(Font.hq(.subheadline).weight(.semibold))
                        .foregroundStyle(Color.hqLabel)
                    TimelineView(.everyMinute) { context in
                        let running = KanbanModel.runningFor(task.currentRunStartedAt ?? task.startedAt, now: context.date)
                        Text(running.isEmpty ? "Started just now" : "\(running) so far")
                            .font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                    }
                }
                Spacer(minLength: 8)
                ProgressView().controlSize(.small)
            }
            if let summary = Self.latestUpdate(task) {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Latest Update").font(Font.hq(.footnote).weight(.semibold)).foregroundStyle(Color.hqLabel2)
                    FoldedMarkdown(text: summary, lines: 6)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .taskCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kanban.task.working")
    }

    /// A finished task: when, and Reopen beside it.
    private func doneCard(_ done: Double, quick: (to: String, label: String)) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").font(Font.hq(.title2)).foregroundStyle(Color(uiColor: .systemGreen))
            VStack(alignment: .leading, spacing: 2) {
                Text("Finished").font(Font.hq(.subheadline).weight(.semibold)).foregroundStyle(Color.hqLabel)
                Text(Self.when(done)).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
            }
            Spacer(minLength: 8)
            Button { model.move(quick.to) } label: {
                Text(model.busy.contains("move") ? "Moving…" : quick.label).font(Font.hq(.subheadline).weight(.semibold))
            }
            .hqRowActionButtonStyle()
            .disabled(model.busy.contains("move"))
            .accessibilityIdentifier("kanban.task.primary")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .taskCard()
    }

    /// Assigned To and Priority, side by side (stacked at accessibility sizes), each a menu.
    @ViewBuilder
    private func factTiles(_ task: KanbanTask) -> some View {
        if panel {
            // Two rows of an inspector: the label, and the value as a pop-up button.
            VStack(spacing: 8) {
                HStack {
                    Text("Assigned To").foregroundStyle(Color.hqLabel2)
                    Spacer(minLength: 12)
                    if model.busy.contains("assign") { ProgressView().controlSize(.mini) }
                    assignTile(task)
                }
                HStack {
                    Text("Priority").foregroundStyle(Color.hqLabel2)
                    Spacer(minLength: 12)
                    if model.busy.contains("priority") { ProgressView().controlSize(.mini) }
                    priorityTile(task)
                }
            }
            .font(Font.inspectorText)
            .buttonStyle(.borderless)
        } else {
            sheetFactTiles(task)
        }
    }

    private func sheetFactTiles(_ task: KanbanTask) -> some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(alignment: .top, spacing: 10))
        return layout {
            assignTile(task)
            priorityTile(task)
        }
        .buttonStyle(.borderless)   // each tile its own tap, not the row's
    }

    private func tile(_ label: String, busy: Bool = false, @ViewBuilder value: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(label).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                Spacer(minLength: 4)
                if busy { ProgressView().controlSize(.mini) }
                else { Image(systemName: "chevron.up.chevron.down").font(Font.hq(.caption2).weight(.semibold)).foregroundStyle(Color.hqLabel3) }
            }
            // One height for every value, so a tile with a bot's face and one with words are the same size.
            HStack(spacing: 8) { value() }
                .frame(minHeight: 24)
                .font(Font.hq(.body).weight(.semibold))
                .foregroundStyle(Color.hqLabel)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .taskCard()
        .contentShape(Rectangle())
    }

    private func assignTile(_ task: KanbanTask) -> some View {
        let nobody = KanbanModel.nobodyWords(defaultBot: model.store.fallback.isEmpty ? "" : model.botName(model.store.fallback))
        return Menu {
            Picker("Assign To", selection: Binding(get: { task.assignee ?? "" }, set: { next in PagesHaptics.selection(); model.assign(next) })) {
                ForEach(model.store.profiles, id: \.name) { profile in Text(model.botName(profile.name)).tag(profile.name) }
                // Last, as New Task lists No One Yet: unassigned (the board's default bot, if any, then runs it).
                Text(nobody).tag("")
            }
        } label: {
            if panel {
                HStack(spacing: 6) {
                    if let who = task.assignee { HeadImage(raw: model.head(who), profile: who, size: 18) }
                    MacPopUpFace(text: task.assignee.map(model.botName) ?? nobody)
                }
            } else {
            tile("Assigned To", busy: model.busy.contains("assign")) {
                if let who = task.assignee {
                    HeadImage(raw: model.head(who), profile: who, size: 24)
                    Text(model.botName(who))
                } else {
                    Image(systemName: "person.crop.circle.badge.questionmark").foregroundStyle(Color.hqLabel3)
                    Text(nobody).foregroundStyle(Color.hqLabel2)
                }
            }
            }
        }
        .accessibilityLabel("Assigned To: \(task.assignee.map(model.botName) ?? nobody). Change")
        .accessibilityIdentifier("kanban.task.assign")
    }

    private func priorityTile(_ task: KanbanTask) -> some View {
        let current = task.priority ?? 0
        let options = Array(Set([0, 1, 2, 3, 5, 10, current])).sorted()
        return Menu {
            Picker("Priority · Higher Goes First", selection: Binding(get: { current }, set: { next in PagesHaptics.selection(); model.setPriority(next) })) {
                ForEach(options, id: \.self) { value in Text(value == 0 ? "None" : String(value)).tag(value) }
            }
            Button("Other Number…") { model.askPriority() }
        } label: {
            if panel {
                MacPopUpFace(text: current == 0 ? "None" : String(current))
            } else {
            tile("Priority", busy: model.busy.contains("priority")) {
                if current == 0 {
                    Text("None").foregroundStyle(Color.hqLabel2)
                } else {
                    Image(systemName: "flag.fill").font(Font.hq(.subheadline)).foregroundStyle(current >= 3 ? Color.hqOrange : Color.hqLabel2)
                    Text(String(current))
                }
            }
            }
        }
        .accessibilityLabel("Priority: \(current == 0 ? "None" : String(current)), higher goes first. Change")
        .accessibilityIdentifier("kanban.task.priority")
    }

    /// The rest of the facts, at the foot of the page: when, who, how it went, where it works, what model.
    private func detailsSection(_ task: KanbanTask) -> some View {
        Section {
            if let created = task.createdAt { LabeledContent("Created", value: Self.when(created)) }
            if let by = task.createdBy, !by.isEmpty { LabeledContent("Created By", value: model.botName(by)) }
            if task.status == "done", let done = task.completedAt { LabeledContent("Finished", value: Self.when(done)) }
            if let failures = task.consecutiveFailures, failures > 0 { LabeledContent("Failed Runs in a Row", value: String(failures)) }
            LabeledContent("Model", value: task.modelOverride.map { ModelNames.displayModelName($0) + (task.reasoningEffort.map { " · \($0)" } ?? "") } ?? "The bot’s own")
            if let path = task.workspacePath, !path.isEmpty {
                Button { model.copy(path, "path") } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Workspace").foregroundStyle(Color.hqLabel)
                            Text(path).font(Font.hqSystem(.footnote, design: .monospaced)).foregroundStyle(Color.hqLabel2)
                                .lineLimit(2).truncationMode(.head)
                        }
                        Spacer()
                        Image(systemName: "doc.on.doc").foregroundStyle(Color.hqTint)
                    }
                }
                .accessibilityHint("Copies the path")
            }
            LabeledContent("Task ID") {
                Text(task.id).font(Font.hqSystem(.subheadline, design: .monospaced)).foregroundStyle(Color.hqLabel2).textSelection(.enabled)
            }
        } header: { HQSectionLabel { Text("Details") } }
    }

    /// An attachment's symbol, by its kind of file.
    private static func fileSymbol(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "webp": return "photo"
        case "pdf": return "doc.richtext"
        case "md", "txt", "rtf": return "doc.text"
        case "csv", "xlsx", "numbers": return "tablecells"
        case "zip", "gz", "tar": return "doc.zipper"
        case "mov", "mp4", "m4v": return "film"
        case "mp3", "m4a", "wav": return "waveform"
        default: return "doc"
        }
    }

    /// Scrolls the focused field's box (the comment field with Post and Start Over, or the description editor) to sit
    /// above the keyboard, once the keyboard has risen.
    private func reveal(_ field: Field?, _ proxy: ScrollViewProxy, animated: Bool = true, delay: Double = 0.35) {
        guard let field else { return }
        let id = field == .comment ? Self.commentBoxId : Self.bodyEditorId
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if animated { HQMotion.withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .bottom) } }
            else { proxy.scrollTo(id, anchor: .bottom) }
        }
    }

    private static func when(_ seconds: Double) -> String {
        let date = Date(timeIntervalSince1970: seconds)
        return "\(JobWords.monthDay(date, calendar: .current)), \(JobWords.clock(date, calendar: .current))"
    }

    private func statusButton(_ task: KanbanTask) -> some View {
        // Statuses only a bot sets (Running, Review, Scheduled) are left out, as on the board's Move To, unless the task
        // is in one: greyed out with no reason they read as broken.
        let columns = (model.store.board?.columns.map(\.name).filter { $0 != "archived" } ?? KanbanModel.statusOrder)
            .filter { $0 == task.status || !KanbanModel.isLocked($0) }
        let tone = KanbanTone.color(task.status)
        return Menu {
            Picker("Move To", selection: Binding(get: { task.status }, set: { next in PagesHaptics.selection(); model.move(next) })) {
                ForEach(columns, id: \.self) { name in Text(KanbanModel.label(name)).tag(name) }
            }
        } label: {
            // The capsule grows with its words (a fixed 32 pt let them spill out at accessibility sizes), and the tap
            // area is 44 pt tall even where the capsule is 32. Tinted with the status's own colour, as on the board.
            HStack(spacing: 6) {
                Circle().fill(tone).frame(width: statusDot, height: statusDot)
                Text(KanbanModel.label(task.status)).font(Font.hq(.subheadline).weight(.semibold)).foregroundStyle(Color.hqLabel)
                Image(systemName: "chevron.down").font(Font.hq(.caption).weight(.bold)).foregroundStyle(Color.hqLabel2)
            }
            .padding(.horizontal, panel ? 9 : 12)
            .padding(.vertical, panel ? 3 : 6)
            .frame(minHeight: panel ? 24 : 32)
            .background {
                // [desktoplook] the look's chips are outlined (4 pt), never filled: the faint capsule vanished on its page.
                if Theme.isDesktop {
                    RoundedRectangle(cornerRadius: DesktopRows.radius).strokeBorder(tone.opacity(0.6), lineWidth: 1)
                } else {
                    Capsule().fill(tone.opacity(0.14))
                }
            }
            .frame(minHeight: panel ? 28 : 44)
            .contentShape(Rectangle())
        }
        .disabled(model.busy.contains("move"))
        .accessibilityLabel("Status: \(KanbanModel.label(task.status)). Change")
        .accessibilityIdentifier("kanban.task.status")
    }

    /// A linked task: its status dot, title and status, opening in this sheet.
    private func links(_ ids: [String], _ detail: KanbanTaskDetail) -> some View {
        ForEach(ids, id: \.self) { id in
            let linked = model.store.board?.task(id)
            Button { model.open(id) } label: {
                HStack(spacing: 10) {
                    Circle().fill(linked.map { KanbanTone.color($0.status) } ?? Color.hqLabel3).frame(width: statusDot, height: statusDot)
                    Text(detail.linkTitles[id] ?? linked?.title ?? id).foregroundStyle(Color.hqLabel).lineLimit(2)
                    Spacer(minLength: 8)
                    if let linked { Text(KanbanModel.label(linked.status)).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2) }
                    SettingsChevron()
                }
            }
        }
    }

    private func descriptionSection(_ task: KanbanTask) -> some View {
        Section {
            if model.editing != nil {
                // Read the model at each get (verify round 1: a value captured at the last body pass fed stale text back
                // into the editor between keystrokes, dropping most of what was typed fast).
                TextEditor(text: Binding(get: { model.editing ?? "" }, set: { model.editing = $0 }))
                    // A fixed eight lines that scroll inside (it doesn't grow under the keyboard as the words run on).
                    // [ui-sizing 2026-11-09] Eight lines of its own font (it had none, so neither UI Scale nor the skin), not
                    // eight 22 pt lines: at larger text about five showed.
                    .font(Font.hq(.body))
                    .frame(height: 8 * HQFont.preferred(.body).lineHeight)
                    .focused($focus, equals: .body)
                    .id(KanbanTaskView.bodyEditorId)
                    .accessibilityLabel("Description")
            } else if let body = task.body, !body.isEmpty {
                FoldedMarkdown(text: body, lines: 12)
            } else {
                Button { model.editing = "" } label: {
                    Label("Add a Description", systemImage: "text.alignleft")
                }
            }
        } header: { HQSectionLabel {
            HStack {
                Text("Description")
                Spacer()
                if model.editing == nil {
                    if !(task.body ?? "").isEmpty { Button("Edit") { model.editing = task.body ?? "" }.textCase(nil) }
                } else {
                    Button("Cancel") { model.editing = nil }.textCase(nil)
                    Button("Save") { model.saveBody() }.textCase(nil).fontWeight(.semibold).disabled(model.busy.contains("body"))
                        .keyboardShortcut(.return, modifiers: .command)   // ⌘Return saves the description, as in New Job
                }
            }
        } }
    }

    @ViewBuilder
    private func historySection(_ detail: KanbanTaskDetail) -> some View {
        let feeds: [KanbanTaskModel.Feed] = [.comments] + (detail.events.isEmpty ? [] : [.activity]) + (detail.runs.isEmpty ? [] : [.runs])
            + (model.log.exists && !model.log.content.isEmpty ? [.log] : [])
        let shown = feeds.contains(model.feed) ? model.feed : .comments
        Section {
            switch shown {
            case .comments: comments(detail)
            case .activity:
                ForEach(detail.events.reversed()) { event in
                    let line = KanbanModel.activityLine(kind: event.kind, payload: event.payload,
                                                        line: KanbanModel.eventText(kind: event.kind, payload: event.payload), botName: model.botName)
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: Self.eventSymbol(event.kind)).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2).frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.label)
                            if let more = line.detail { Text(more).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2) }
                        }
                        Spacer(minLength: 8)
                        Text(KanbanModel.ago(event.createdAt)).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel3)
                    }
                }
            case .runs:
                ForEach(detail.runs.reversed()) { run in
                    let outcome = run.outcome ?? run.status
                    let failed = ["crashed", "failed", "timed_out", "gave_up"].contains(outcome)
                    let live = ["running", "started", "claimed"].contains(outcome)
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: failed ? "xmark.circle.fill" : live ? "circle.dotted" : "checkmark.circle.fill")
                            .font(Font.hq(.subheadline))
                            .foregroundStyle(failed ? Color.hqRed : live ? Color.hqLabel2 : Color(uiColor: .systemGreen))
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(outcome.replacingOccurrences(of: "_", with: " ").capitalized + (run.profile.map { " · \(model.botName($0))" } ?? ""))
                                .foregroundStyle(failed ? Color.hqRed : Color.hqLabel)
                            if let note = run.error ?? run.summary {
                                Text(note).font(Font.hq(.footnote)).foregroundStyle(run.error != nil ? Color.hqRed : Color.hqLabel2)
                            }
                        }
                        Spacer(minLength: 8)
                        Text(KanbanModel.ago(run.endedAt ?? run.startedAt)).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel3)
                    }
                }
            case .log:
                Text(model.log.content).font(Font.hqSystem(.caption, design: .monospaced)).textSelection(.enabled)
            }
        } header: {
            // The picker is the box's header, standing on the page above it, the box's full width. As a clear row
            // inside the box the box lost its top corners and a stray separator ran under it; as a one-row section
            // the row's rounded mask cut the ends off the look's square strip.
            if feeds.count > 1 {
                HQSegmentedPicker("Task history", options: feeds.map { feed in
                    (feed == .comments ? (detail.comments.isEmpty ? "Comments" : "Comments \(detail.comments.count)") : feed.rawValue.capitalized, feed)
                }, selection: $model.feed)   // [desktoplook3]
                .textCase(nil)
                .padding(.top, 8)
                .listRowInsets(EdgeInsets(top: 0, leading: panel ? InspectorLook.margin : 0, bottom: 10, trailing: panel ? InspectorLook.margin : 0))
            } else {
                HQSectionLabel { Text("Comments") }
            }
        } footer: { HQSectionFooter {
            if shown == .comments {
                Text(model.running ? "The bot reads new comments while it works." : "Comments are part of what the bot reads when it picks this up.")
            }
        } }
    }

    private static func eventSymbol(_ kind: String) -> String {
        switch kind {
        case "created": return "plus.circle"
        case "commented", "comment": return "text.bubble"
        case "assigned", "reassigned": return "person.crop.circle"
        case "completed", "done": return "checkmark.circle"
        case "blocked": return "exclamationmark.circle"
        case "claimed", "started", "running": return "play.circle"
        case "failed", "crashed": return "xmark.circle"
        default: return "circle"
        }
    }

    /// Who wrote a comment: you (the app posts as "desktop"), or a bot's face.
    @ViewBuilder
    private func author(_ name: String) -> some View {
        if name == "desktop" {
            Image(systemName: "person.crop.circle.fill").font(.system(size: 28)).foregroundStyle(Color.hqLabel3).frame(width: 28, height: 28)   // a11y-font-ok: a stand-in face filling its fixed 28 pt avatar frame
        } else {
            HeadImage(raw: model.head(name), profile: name, size: 28)
        }
    }

    @ViewBuilder
    private func comments(_ detail: KanbanTaskDetail) -> some View {
        ForEach(detail.comments) { comment in
            HStack(alignment: .top, spacing: 10) {
                author(comment.author).scaleEffect(panel ? 0.8 : 1, anchor: .top)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(comment.author == "desktop" ? "You" : model.botName(comment.author)).font(Font.hq(.subheadline).weight(.semibold))
                        Text(KanbanModel.ago(comment.createdAt)).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel3)
                    }
                    FoldedMarkdown(text: comment.body)
                }
            }
            .padding(.vertical, 4)
        }
        let running = model.running
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField(running ? "Message the bot working on this" : "Add a comment", text: $model.comment, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($focus, equals: .comment)
                    .modifier(TaskPanelField(panel: panel))
                    .accessibilityIdentifier("kanban.task.comment")
                Button {
                    model.sendComment(requeue: false)
                } label: {
                    Image(systemName: "arrow.up.circle.fill").hqSymbolFont(panel ? 22 : 28, cap: 40)
                }
                .disabled(model.comment.pgTrim.isEmpty || model.busy.contains("comment") || model.busy.contains("requeue"))
                .accessibilityLabel(running ? "Send" : "Comment")
                .accessibilityIdentifier("kanban.task.send")
            }
            // Only once there is a comment to post: greyed out under an empty field it read as more placeholder text.
            if running && !model.comment.pgTrim.isEmpty {
                Button { model.sendComment(requeue: true) } label: {
                    Label("Post and Start Over", systemImage: "arrow.counterclockwise")
                        .font(Font.hq(.subheadline).weight(.semibold))
                }
                .tint(Color.hqTint)
                .disabled(model.busy.contains("requeue") || model.busy.contains("comment"))
                .accessibilityIdentifier("kanban.task.requeue")
            }
        }
        .buttonStyle(.borderless)
        .id(Self.commentBoxId)
    }
}

private extension View {
    /// A row standing on the page: no fill, no separator, no outline in the look.
    func taskBareRow(top: CGFloat, bottom: CGFloat, side: CGFloat = 0) -> some View {
        self
            .hqDesktopBareRow()
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden, edges: .all)
            .listRowInsets(EdgeInsets(top: top, leading: side, bottom: bottom, trailing: side))
    }

    /// The page's own card: the grouped card colour, outlined with 4 pt corners in the look.
    func taskCard(tint: Color? = nil) -> some View { modifier(TaskCard(tint: tint)) }
}

/// [mac-tools] In the board's panel.
private struct KanbanTaskPanelKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var kanbanTaskPanel: Bool {
        get { self[KanbanTaskPanelKey.self] }
        set { self[KanbanTaskPanelKey.self] = newValue }
    }
}

/// The list's look: the sheet's inset cards, or in the board's panel a plain list on the page colour at the
/// inspector's text size, facts as a grey label and its value.
private struct TaskListLook: ViewModifier {
    var panel: Bool
    func body(content: Content) -> some View {
        if panel {
            content
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.hqPage)
                .font(Font.inspectorText)
                .labeledContentStyle(TaskPanelFact())
                .environment(\.defaultMinListRowHeight, 30)
        } else {
            content
                .hqGroupedPage()   // [desktoplook] the page follows the skin
                .listStyle(.insetGrouped)
        }
    }
}

/// The panel's rows: no card behind them, the panel's margin, a hairline between them.
private struct TaskPanelRows: ViewModifier {
    var panel: Bool
    func body(content: Content) -> some View {
        if panel {
            content
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 7, leading: InspectorLook.margin, bottom: 7, trailing: InspectorLook.margin))
                .listRowSeparatorTint(Color(uiColor: InspectorLook.rule))
                .listSectionSeparator(.hidden, edges: .top)
        } else {
            content
        }
    }
}

private struct TaskPanelFact: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline) {
            configuration.label.foregroundStyle(Color.hqLabel2)
            Spacer(minLength: 12)
            configuration.content.foregroundStyle(Color.hqLabel).multilineTextAlignment(.trailing)
        }
    }
}

/// The comment field in the panel: a Mac text field's box.
private struct TaskPanelField: ViewModifier {
    var panel: Bool
    func body(content: Content) -> some View {
        if panel {
            content
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: MacField.radius, style: .continuous).fill(MacField.fill))
                .overlay(RoundedRectangle(cornerRadius: MacField.radius, style: .continuous).strokeBorder(MacField.stroke, lineWidth: 1))
        } else {
            content
        }
    }
}

private struct TaskCard: ViewModifier {
    var tint: Color?
    @Environment(\.kanbanTaskPanel) private var panel
    func body(content: Content) -> some View {
        content.background {
            let shape = RoundedRectangle(cornerRadius: Theme.isDesktop ? DesktopRows.radius : panel ? 8 : 16, style: .continuous)
            if let tint {
                shape.fill(tint.opacity(0.1))
                    .overlay { if Theme.isDesktop { shape.strokeBorder(tint.opacity(0.35), lineWidth: 1) } }
            } else if Theme.isDesktop {
                shape.fill(Color.hqGroupedCard).overlay { shape.strokeBorder(Color.hqStroke, lineWidth: 1) }
            } else {
                // The list's own row colour, so a card sits on the page as the boxes below it do (the skin's card
                // colour is the page's own grey in the standard look).
                shape.fill(Color(uiColor: HQPalette.card))
                    .overlay { if panel { shape.strokeBorder(Color(uiColor: HQPalette.cardEdge), lineWidth: 1) } }
            }
        }
    }
}

/// Something that needs you (§4.6.3): the board's diagnostic (title ×N, detail folded at 180 characters, its fixes), or
/// a blocked task's reason. The first carries the page's next move (Unblock) as its prominent button.
private struct TaskCallout: View {
    var severity: String
    var title: String
    var detail: String
    var actions: [KanbanDiagnosticAction] = []
    var primary: (to: String, label: String)?
    var model: KanbanTaskModel
    @State private var open = false
    @Environment(\.dynamicTypeSize) private var typeSize

    init(severity: String, title: String, detail: String, primary: (to: String, label: String)?, model: KanbanTaskModel) {
        self.severity = severity; self.title = title; self.detail = detail; self.primary = primary; self.model = model
    }

    init(diagnostic: KanbanDiagnostic, primary: (to: String, label: String)?, model: KanbanTaskModel) {
        severity = diagnostic.severity
        title = diagnostic.title + (diagnostic.count > 1 ? " ×\(diagnostic.count)" : "")
        detail = diagnostic.detail
        // The board's own Unblock is the primary button when that is the page's next move.
        actions = diagnostic.actions.filter { ["reclaim", "unblock", "cli_hint"].contains($0.kind) && !($0.kind == "unblock" && primary?.to == "ready") }
        self.primary = primary
        self.model = model
    }

    var body: some View {
        let tone: Color = severity == "error" ? .hqRed : .hqOrange
        let long = detail.count > 180
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: severity == "error" ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(tone)
                Text(title).font(Font.hq(.subheadline).weight(.semibold)).foregroundStyle(tone)
            }
            if !detail.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(long && !open ? String(detail.prefix(180)) + "…" : detail)
                        .font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel)
                    if long {
                        Button(open ? "Show Less" : "Show More") { open.toggle() }
                            .font(Font.hq(.footnote).weight(.semibold)).tint(tone).buttonStyle(.borderless)
                    }
                }
            }
            if primary != nil || !actions.isEmpty {
                let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
                layout {
                    if let primary {
                        Button { model.move(primary.to) } label: {
                            Text(model.busy.contains("move") ? "Moving…" : primary.label)
                                .font(Font.hq(.subheadline).weight(.semibold))
                                .frame(maxWidth: actions.isEmpty ? .infinity : nil, minHeight: 30)
                                .padding(.horizontal, actions.isEmpty ? 0 : 6)
                        }
                        .hqProminentButtonStyle()
                        .buttonBorderShape(.capsule)
                        .tint(Color.hqTint)
                        .disabled(model.busy.contains("move"))
                        .accessibilityIdentifier("kanban.task.primary")
                    }
                    ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                        Button {
                            switch action.kind {
                            case "reclaim": model.reclaim()
                            case "unblock": model.move("ready")
                            default: model.copy(action.command ?? action.label, "command")
                            }
                        } label: {
                            if action.kind == "cli_hint", let command = action.command {
                                Label { VStack(alignment: .leading) { Text(action.label); Text("Copies \(command)").font(Font.hq(.caption)) } } icon: { Image(systemName: "doc.on.doc") }
                            } else {
                                Text(action.label).font(Font.hq(.subheadline).weight(.semibold)).frame(minHeight: 30)
                            }
                        }
                        .hqBorderedButtonStyle()
                        .buttonBorderShape(.capsule)
                        .tint(tone)
                    }
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .taskCard(tint: tone)
        .accessibilityElement(children: .contain)
    }
}

/// Agent-written Markdown folded to about twelve lines, with Show More / Show Less.
struct FoldedMarkdown: View {
    var text: String
    var lines: Int = 12
    @State private var open = false
    @State private var width: CGFloat = 0
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let attributed = PagesMarkdown.attributed(text, category: UIContentSizeCategory(typeSize))
        VStack(alignment: .leading, spacing: 6) {
            AttributedTextView(text: attributed, maxLines: open ? 0 : lines)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            if open || AttributedTextView.exceeds(attributed, lines: lines, width: width) {
                Button(open ? "Show Less" : "Show More") { HQMotion.withAnimation(.snappy) { open.toggle() } }
                    .font(Font.hq(.footnote).weight(.semibold))
                    .buttonStyle(.borderless)
            }
        }
    }
}
