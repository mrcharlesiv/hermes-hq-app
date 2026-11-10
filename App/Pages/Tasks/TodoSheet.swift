// [tasks] One task (owner-approved mockup 2-task, 2026-11-04), modelled on the Kanban task sheet: ✕ · Task · ⋯.
// Owner 2026-11-05 ("Yes" to the task's chat on the task page itself): this is the lead of the task's own chat
// (TaskPage), with the chat's own bar at the bottom. Before the bots are known it stands alone, with "Message <Bot> about
// this task" (TasksHub.ask). Owner 2026-11-07 (the Pinned Task design, step 1: "I love all of that. Go."): the details
// are a short brief that says what to do — the state line, the title once, due and who as words, the bot's words and
// what's next, what it made, the steps, notes, and one move by the task's state (TaskNow) with Done beside it. The
// status menu, where it came from and the activity are in ⋯ (Details, History).

import SwiftUI
import UIKit

@MainActor @Observable
final class TodoSheetModel {
    let taskID: String
    let store: TasksStore
    @ObservationIgnored let context: MorePages.Context
    @ObservationIgnored weak var controller: UIViewController?
    /// [tasks] On the task's chat (TaskPage): no Ask bar or pull to refresh; the chat's own bar sends.
    @ObservationIgnored var embedded = false
    @ObservationIgnored weak var chat: ChatViewController?
    /// [tasks] The pinned brief's (or bar's) drawn height; the page caps it to leave the chat room (TaskPage).
    @ObservationIgnored var onLeadHeight: ((CGFloat) -> Void)?
    /// [tasks] Something the cap depends on changed (a field in the brief took or left the keys).
    @ObservationIgnored var onBriefLayoutChange: (() -> Void)?
    /// [tasks] The task's view and the chat's swapped (TaskPage lays the panel out again).
    @ObservationIgnored var onTuckChange: (() -> Void)?
    /// [tasks] Pinned Task step 3: the brief rolled up to its bar (you took up the chat), and why.
    var tucked = false { didSet { if tucked != oldValue { onTuckChange?() } } }
    enum TuckReason { case drag, focus, send, find, alert, chat }
    @ObservationIgnored private(set) var tuckReason: TuckReason?
    /// [tasks] The brief is taller than its cap: it scrolls inside its panel.
    var briefScrolls = false
    /// [tasks] The brief gives up room before it scrolls: the bot's words keep to three lines and Next to two, and an
    /// empty "+ Add notes" leaves (⋯ › Details has it). Nothing hides behind a tap:
    /// the task's view has the screen and scrolls, its move and the chat's line staying at its foot (two states, 2026-11-08).
    var briefTight = false
    /// [tasks] A field in the brief (a step, the notes) has the keys: the chat's composer steps aside meanwhile.
    var editingBrief = false {
        didSet {
            guard editingBrief != oldValue else { return }
            if let composer = chat?.composer {
                UIView.animate(withDuration: HQMotion.reduced ? 0 : 0.2) {   // motion-ok: a fade, none under Reduce Motion
                    composer.alpha = self.editingBrief ? 0 : 1
                }
                composer.isUserInteractionEnabled = !editingBrief
            }
            onBriefLayoutChange?()
        }
    }
    /// [tasks] The task has its chat (TaskPage): read each time, so a chat its first message made counts at once.
    var hasChat: Bool { task.map { chatLink($0) != nil } ?? false }
    /// Mark Done or Delete put the task away (the sheet goes down, or the Mac's right pane empties).
    @ObservationIgnored var close: (() -> Void)?
    /// [tasks] Marked done from the page: the list offers Undo (TasksViewController).
    @ObservationIgnored var onMarkedDone: ((TodoTask) -> Void)?
    var notice: String?
    var question = ""
    var newStep = ""
    /// [tasks] The add-a-step field is open (Steps' +).
    var addingStep = false { didSet { syncEditing() } }
    var notes = ""
    var editingNotes = false { didSet { syncEditing() } }
    /// Steps whose long title is shown whole (a tap on the title).
    var openSteps: Set<String> = []
    @ObservationIgnored private var noticeWork: DispatchWorkItem?
    /// The task as it was when the sheet last saw it (a delete elsewhere keeps the sheet readable until it closes).
    @ObservationIgnored private var lastSeen: TodoTask?
    /// [tasks] The Task Page while it is open: drawn again when the task changes (a bot's prep run, another device).
    @ObservationIgnored private weak var pageSheet: HTMLPageSheet?
    @ObservationIgnored private var pageRev = 0
    var pageLoading = false
    /// [tasks] An answer you tapped (one of the bot's choices), shown on the task's view until the bot's turn ends and
    /// the task moves on (owner 2026-11-09, mockup 2: your answer, then what the bot did with it).
    var sentAnswer: (words: String, rev: Int)?

    init(taskID: String, store: TasksStore, context: MorePages.Context) {
        self.taskID = taskID
        self.store = store
        self.context = context
        lastSeen = store.task(taskID)
        notes = lastSeen?.notes ?? ""
        #if DEBUG
        Self.debugLast = self
        #endif
    }

    /// [tasks] Writing in the brief (a step, the notes) on the task's chat: the composer steps aside meanwhile.
    private func syncEditing() {
        let editing = embedded && (addingStep || editingNotes)
        if editingBrief != editing { editingBrief = editing }
    }

    /// [tasks] Rolls the brief up to its bar. A send while it is up for the keys keeps it up after the keys go.
    func tuck(_ reason: TuckReason) {
        guard embedded, !editingBrief else { return }
        if tucked {
            if reason == .send || reason == .drag { tuckReason = reason }
            return
        }
        tuckReason = reason
        HQMotion.withAnimation(.snappy) { tucked = true }
    }

    /// [tasks] The chat's newest message, for the task view's line (owner 2026-11-08, "I like A": the whole task, its
    /// chat one line above the composer; a tap on it gives the chat the screen).
    struct Glimpse: Equatable { var id: String; var mine: Bool; var words: String; var at: Date? }

    func glimpse() -> Glimpse? {
        guard let session = chat?.session else { return nil }
        guard let message = session.messages.last(where: {
            ($0.role == .user || $0.role == .assistant) && !ChatText.trimmed($0.plainText).isEmpty
        }) else { return nil }
        let text = message.role == .user ? (TodoWords.askShown(message.plainText) ?? message.plainText) : message.plainText
        let words = text.split(whereSeparator: \.isNewline).joined(separator: " ").replacingOccurrences(of: "**", with: "")
        return Glimpse(id: message.id, mine: message.role == .user, words: ChatText.trimmed(words), at: message.timestamp)
    }

    /// The newest message you've seen (the chat on show, or already there when the task opened).
    @ObservationIgnored var seenGlimpse: String?
    @ObservationIgnored let openedAt = Date()

    func isUnread(_ glimpse: Glimpse) -> Bool {
        if seenGlimpse == nil, Date().timeIntervalSince(openedAt) < 4 { seenGlimpse = glimpse.id }   // there when it opened
        return !glimpse.mine && glimpse.id != seenGlimpse
    }

    /// The task view's line, tapped: the chat takes the screen (the task as its bar).
    func showChat() {
        if let latest = glimpse() { seenGlimpse = latest.id }
        PagesHaptics.selection()
        tuck(.chat)
    }

    /// The bar's tap, or the title's: the whole brief again.
    func untuck() {
        guard tucked else { return }
        if let latest = glimpse() { seenGlimpse = latest.id }   // what the chat showed has been seen
        tuckReason = nil
        // Owner 2026-11-08: "Clicking on the task from the chat should minimize the keyboard." The task's view has
        // the screen; what you were writing stays in the field for when you go back.
        if let field = chat?.composer.textView, field.isFirstResponder { field.resignFirstResponder() }
        PagesHaptics.selection()
        HQMotion.withAnimation(.snappy) { tucked = false }
    }

    /// The brief's moves (`TaskNow`), from its foot or its bar. Answer on a page with no chat of its own is the view's.
    func perform(_ action: TaskNow.Action, task: TodoTask) {
        switch action {
        case .reopen: reopen()
        case .answer:
            // The task's chat bar takes the keys (it had set a field only the stand-alone page has, so did nothing).
            PagesHaptics.selection()
            openChat(task)
        case .share(let made): share(made)
        case .openLink(let made), .openFile(let made): open(made)
        case .call(let number): call(number)
        case .askUpdate: ask(task, TaskNow.updateQuestion)
        case .askStart: ask(task, TaskNow.startRequest)
        case .askHelp: askHelp(task)
        case .markDone: markDone()
        }
    }

    #if DEBUG
    /// The task opened last (`-HQPagesTaskPage`, PagesDebug).
    static weak var debugLast: TodoSheetModel?
    #endif

    var task: TodoTask? {
        if let found = store.task(taskID) { lastSeen = found; return found }
        return lastSeen
    }

    var gone: Bool { store.hasList && store.task(taskID) == nil }

    func botName(_ profile: String?) -> String { PagesNames.botName(profile ?? "default", bots: context.bots) }
    func head(_ profile: String) -> JSONValue? { PagesNames.head(profile, bots: context.bots) }

    func show(_ text: String) {
        // [tasks] On the task's chat its notices are the chat's own, under the bar (drawn in the details, they scrolled
        // away with them).
        if embedded, let chat {
            chat.showNotice(text, duration: 3, spinner: false)
            HQAnnounce.say(text)
            return
        }
        notice = text
        noticeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.notice = nil }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        HQAnnounce.say(text)
    }

    private func patch(_ fields: [String: JSONValue]) {
        Task { await store.patch(taskID, fields) }
    }

    func setStatus(_ status: String) {
        PagesHaptics.selection()
        patch(["status": .string(status)])
    }

    /// The sheet goes down once the gateway took it, and the list offers Undo; a refused save keeps it up, with the
    /// reason in its notice. Status ▸ Done in ⋯ is this too.
    func markDone() {
        PagesHaptics.selection()
        let marked = task
        Task {
            if await store.setDone(taskID, true) {
                PagesHaptics.success()
                close?()
                if let marked { onMarkedDone?(marked) }
            } else {
                PagesHaptics.error()
            }
        }
    }

    /// A done task back on the list (the brief's Reopen, ⋯ › Reopen).
    func reopen() {
        PagesHaptics.selection()
        Task { if await !store.setDone(taskID, false) { PagesHaptics.error() } }
    }

    func setWho(_ who: TodoWho, bot: String?) {
        PagesHaptics.selection()
        var fields: [String: JSONValue] = ["who": .string(who.rawValue), "bot": who == .me ? .null : .string(bot ?? "default")]
        if who != .me { fields["repeat"] = .null } else { fields["prep"] = .bool(false) }
        if let steps = task.flatMap({ TodoEdits.stepsForJustMe(who, steps: $0.steps) }) { fields["steps"] = TodoWire.steps(steps) }
        patch(fields)
    }

    func setDue(_ date: Date?, hasTime: Bool) {
        PagesHaptics.selection()
        patch(["due": date.map { .string(TodoDates.wire($0, hasTime: hasTime)) } ?? .null])
    }

    func setRepeat(_ rule: String?) {
        PagesHaptics.selection()
        patch(["repeat": rule.map(JSONValue.string) ?? .null])
    }

    func setPrep(_ on: Bool) {
        PagesHaptics.selection()
        patch(["prep": .bool(on)])
    }

    func toggleStep(_ step: TodoStep) {
        PagesHaptics.selection()
        Task { await store.setStep(taskID, step: step.id, done: !step.done) }
    }

    /// Who does a step: from its menu (Give to <Bot> / Take It Myself), no longer a flip on one tap.
    func setStepWho(_ step: TodoStep, _ who: String) {
        guard let task, step.who != who else { return }
        PagesHaptics.selection()
        let steps = task.steps.map { s -> TodoStep in var s = s; if s.id == step.id { s.who = who }; return s }
        patch(["steps": TodoWire.steps(steps)])
    }

    func deleteStep(_ step: TodoStep) {
        guard let task else { return }
        PagesHaptics.selection()
        patch(["steps": TodoWire.steps(task.steps.filter { $0.id != step.id })])
    }

    /// Return adds the step; the field stays open for the next (an empty one closes when it loses the keys).
    func addStep() {
        let title = newStep.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let task, !title.isEmpty else { addingStep = false; return }
        PagesHaptics.selection()
        newStep = ""
        patch(["steps": TodoWire.steps(task.steps + [TodoStep(title: title, who: "me")])])
    }

    func saveNotes() {
        editingNotes = false
        guard let task, notes != task.notes else { return }
        patch(["notes": .string(notes)])
    }

    /// Notes read formatted until Edit; the field starts from the task's notes as they are now (a bot may have added).
    /// The page's field takes the keys (TodoSheetView watches `editingNotes`).
    func editNotes() {
        PagesHaptics.selection()
        notes = task?.notes ?? notes
        editingNotes = true
    }

    /// [tasks] The whole log, newest first (⋯ › History, or a tap on the state line): the Activity that had stood on
    /// every task, repeating its card and its chat.
    func showHistory() {
        guard let top, let task else { return }
        Haptics.play(.selection)
        let view = TodoHistoryView(task: task, origin: TodoWords.origin(task, now: Date(), botName: botName),
                                   botName: { [weak self] in self?.botName($0) ?? "" },
                                   head: { [weak self] in self?.head($0) }, open: { [weak self] in self?.openPath($0) })
        top.present(ChatSheet.wrap(UIHostingController(rootView: HQScaledRoot(view)), title: "History"), animated: true)
    }

    /// A step's long title, whole or folded to two lines.
    func toggleOpen(_ step: TodoStep) {
        PagesHaptics.selection()
        if openSteps.contains(step.id) { openSteps.remove(step.id) } else { openSteps.insert(step.id) }
    }

    func confirmDelete() {
        guard let controller, let task else { return }
        let alert = UIAlertController(title: "Delete “\(task.title)”?", message: "It goes from the list for you and your bots.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            guard let self else { return }
            PagesHaptics.selection()
            Task {
                if await self.store.delete(self.taskID) { self.close?() } else { PagesHaptics.error() }
            }
        })
        controller.present(alert, animated: true)
    }

    func open(_ made: TodoMade) {
        guard let top else { return }
        Haptics.play(.selection)
        switch made.kind {
        case "file":
            openPath(made.ref)
        case "link":
            if let url = TodoMade.linkURL(made.ref) { UIApplication.shared.open(url) } else { show("This link can’t be opened.") }
        default:
            let note = TodoNoteView(title: made.title, text: made.ref, open: { [weak self] path in self?.openPath(path) },
                                    share: { [weak self] in self?.share(made) },
                                    askChanges: embedded && chat != nil ? { [weak self] in self?.askForChanges(made) } : nil)
            top.present(ChatSheet.wrap(UIHostingController(rootView: HQScaledRoot(note)), title: "Note"), animated: true)
        }
    }

    /// [tasks] Share Draft…: what the bot made, to Mail, Messages or anywhere the share sheet sends.
    func share(_ made: TodoMade) {
        guard let top else { return }
        Haptics.play(.selection)
        let words: Any = made.kind == "link" ? (TodoMade.linkURL(made.ref).map { $0 as Any } ?? made.ref) : made.ref
        let sheet = UIActivityViewController(activityItems: [words], applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY - 120, width: 1, height: 1)
        }
        top.present(sheet, animated: true)
        AppLog.note("tasks", "made \(made.kind) shared from the task")
    }

    /// [tasks] A draft's Ask for Changes: its sheet goes down and the task's chat bar takes the keys, ready to say
    /// what to change (words already typed there stay as they are).
    func askForChanges(_ made: TodoMade) {
        guard let chat, embedded else { return }
        PagesHaptics.selection()
        let name = made.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let finish = { [weak chat] in
            guard let chat else { return }
            if chat.composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chat.composer.text = name.isEmpty ? "Changes to the draft: " : "Changes to “\(name)”: "
            }
            chat.focusComposer()
        }
        if let shown = chat.presentedViewController { shown.dismiss(animated: true, completion: finish) } else { finish() }
    }

    /// [tasks] Offered on a task a bot works on (or has written on), once the add-on draws Task Pages (0.9.38).
    func offersPage(_ task: TodoTask) -> Bool {
        store.pagesSupported && !TodoIDs.isLocal(task.id) && (task.whoKind != .me || task.pageAt != nil)
    }

    /// [tasks] The task's Task Page (owner 2026-11-05: "a page that you could bring up … so the user can very easily
    /// visualize everything that's going on with the task and where it all stands"): one HTML page the add-on draws
    /// from the task and what its bot wrote on it, live in the page sheet. Its "Ask for an Update" talks to the
    /// task's own chat (once it has one) as a hidden turn; the page is drawn again when that turn ends, and when the
    /// task changes while it is open.
    func openPage() {
        guard let task, !pageLoading else { return }
        Haptics.play(.selection)
        pageLoading = true
        let id = task.id, api = store.api
        let names = Dictionary(context.bots.map { ($0.id, botName($0.id)) }, uniquingKeysWith: { a, _ in a })
        let read: @MainActor () async throws -> URL = { [weak self] in
            let data = try await api.page(id, names: names)
            return try Self.pageFile(id: id, title: self?.task?.title ?? "", data: data)
        }
        Task { [weak self] in
            defer { self?.pageLoading = false }
            do {
                let url = try await read()
                guard let self, let top = self.top, top.view.window != nil else { return }
                let profile = self.task?.helper ?? "default"
                let chat = self.hasChat ? self.chat : nil
                let activity = chat?.session as? ChatActivityProviding
                let send: ((String) -> Void)? = activity.map { provider in { [weak provider] prompt in provider?.sendHidden(prompt, display: nil) } }
                let context = chat?.mediaContext ?? MediaContext(accountId: self.context.account.id, profile: profile)
                let source = HTMLPageSheet.Source(path: "task-page:" + id, context: context, send: send,
                                                  botName: self.botName(profile), read: read)
                self.pageRev = self.task?.rev ?? 0
                self.pageSheet = HTMLPageSheet.present(url, source: source, title: "Task Page", from: top)
                AppLog.note("tasks", "task page opened (talk-back \(send == nil ? "off" : "on"))")
            } catch {
                guard let self else { return }
                PagesHaptics.error()
                self.show("Couldn’t open the Task Page. \(PagesREST.reason(error))")
                AppLog.note("tasks", "task page not read: \(PagesREST.reason(error))")
            }
        }
    }

    /// The task moved on while its page is open: the page is drawn again.
    func taskChanged(_ rev: Int) {
        guard let page = pageSheet, page.view.window != nil, rev != pageRev else { return }
        pageRev = rev
        page.readAgain(note: nil)
    }

    /// The page as a file named for the task (Share sends "<title>.html"), in its own folder (the page reads only that).
    nonisolated static func pageFile(id: String, title: String, data: Data) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "TaskPages", directoryHint: .isDirectory)
            .appending(path: id.filter { $0.isLetter || $0.isNumber }, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var name = String(title.map { "/:\\".contains($0) ? "-" : $0 }.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.hasPrefix(".") { name = "Task Page" }
        let file = folder.appending(path: name + ".html")
        try data.write(to: file, options: .atomic)
        return file
    }

    /// A file the bot made or names: Files opens at it, over whatever this sheet shows now (a note's own sheet too).
    func openPath(_ path: String) {
        guard let top else { return }
        let workspace = ChatWorkspace(client: context.client, profile: task?.helper)
        top.present(WorkspacePage.make(path: path, workspace: workspace, media: nil), animated: true)
    }

    private var top: UIViewController? {
        var shown = controller
        while let next = shown?.presentedViewController, !next.isBeingDismissed { shown = next }
        return shown
    }

    /// [tasks] One of the bot's offered answers, tapped on the task's view: it goes into the task's chat as your message,
    /// and the task's view stays (the bot's reply lands on it). Owner 2026-11-09: "too many taps".
    func answer(_ words: String) {
        guard let task else { return }
        guard let chat, embedded else { openChat(task, question: words); return }
        Haptics.play(.light)   // as Send
        sentAnswer = (words, task.rev)
        let out = (chat.session as? LiveChatSession)?.wrapsSend?(words) ?? (text: words, display: words)
        chat.sendFromCard(out.text, display: out.display, engage: false)
        if let latest = glimpse() { seenGlimpse = latest.id }
        AppLog.note("tasks", "task answered from the page (\(words.count) chars)")
    }

    func askHelp(_ task: TodoTask) {
        Haptics.play(.light)   // as Send: it asks the bot
        openChat(task, question: TodoWords.helpQuestion)
    }

    /// [tasks] Ask for an Update, Ask <Bot> to Start: words you can see in the task's chat (the Task Page's Ask for an
    /// Update is a hidden turn, so its reply came in under no question).
    func ask(_ task: TodoTask, _ words: String) {
        Haptics.play(.light)   // as Send
        openChat(task, question: words)
    }

    /// The task's own chat: on the task's page, the words go into it here; standing alone (no bots yet), it is
    /// pushed over this page (the sheet's own navigation, or the Mac's right pane).
    func openChat(_ task: TodoTask, question: String? = nil) {
        if let chat, embedded {
            let words = question?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if words.isEmpty { chat.focusComposer(); return }
            let out = (chat.session as? LiveChatSession)?.wrapsSend?(words) ?? (text: words, display: words)
            chat.sendFromCard(out.text, display: out.display)
            AppLog.note("tasks", "task chat asked from the page (\(words.count) chars)")
            return
        }
        if question == nil { PagesHaptics.selection() }
        TasksHub.ask(question, task: task, store: store, context: context, on: controller?.navigationController)
    }

    /// The task's chat, when it has one.
    func chatLink(_ task: TodoTask) -> TodoChat? { TaskChatLinks.link(task, account: context.account) }

    /// The bot the task's chat is (or will be) with.
    func chatBot(_ task: TodoTask) -> String {
        chatLink(task)?.profile ?? TaskChatLinks.bot(for: task, bots: context.bots)?.id ?? "default"
    }

    /// The move for a ready task with nothing made: Call when the bot's line or the notes hold a phone number, one
    /// written as one (`TaskNow.callable`: the detector alone took IP addresses and device ids for numbers).
    func phoneNumber(_ task: TodoTask) -> String? {
        let text = [task.statusNote, task.notes].joined(separator: " ")
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue) else { return nil }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).lazy
            .compactMap { $0.phoneNumber }.first { TaskNow.callable($0, in: text) }
    }

    func call(_ number: String) {
        Haptics.play(.light)
        let digits = number.filter { $0.isNumber || $0 == "+" }
        if let url = URL(string: "tel:\(digits)") { UIApplication.shared.open(url) }
    }

    func sendQuestion() {
        let words = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let task, !words.isEmpty else { return }
        Haptics.play(.light)   // as the chat's Send
        question = ""
        openChat(task, question: words)
    }
}

enum TodoSheet {
    static func make(taskID: String, store: TasksStore, context: MorePages.Context) -> UINavigationController {
        let model = TodoSheetModel(taskID: taskID, store: store, context: context)
        // [tasks] The task's chat with the task above it; alone (no bots, or the task not read yet) as before.
        let root: UIViewController = TaskPage.make(model: model) ?? TodoSheetHost(model: model)
        // [tasks] Large only (Pinned Task step 2): a half-height task page was a sliver of chat under the task.
        let nav = ChatSheet.wrap(root, title: "Task", detents: [.large()])
        if root is ChatViewController { root.title = nil }   // the chat's own title (its bot and the task)
        nav.sheetPresentationController?.selectedDetentIdentifier = .large
        model.close = { [weak root] in root?.dismiss(animated: true) }
        return nav
    }

    /// [mac] Two panes: the task opens in the right pane beside the list, as a Kanban task or a job's page does.
    static func page(taskID: String, store: TasksStore, context: MorePages.Context) -> UIViewController {
        let model = TodoSheetModel(taskID: taskID, store: store, context: context)
        let page: UIViewController = TaskPage.make(model: model) ?? TodoSheetHost(model: model)
        model.close = { [weak page] in
            guard let page else { return }
            if page.navigationController?.presentingViewController != nil {
                page.dismiss(animated: true)
            } else {
                AppRoot.tabs(page.view.window)?.leave(page, animated: true)
            }
        }
        return page
    }

    /// The task's model behind a page on show (the sheet's root, or the Mac's right pane).
    static func model(of page: UIViewController?) -> TodoSheetModel? {
        if let host = page as? TodoSheetHost { return host.model }
        return ((page as? ChatViewController)?.topAccessory as? TaskBriefHost)?.model
    }
}

final class TodoSheetHost: UIHostingController<HQScaledRoot<TodoSheetView>> {
    let model: TodoSheetModel

    init(model: TodoSheetModel) {
        self.model = model
        super.init(rootView: HQScaledRoot(TodoSheetView(model: model)))
        model.controller = self
        title = "Task"
        let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak model] completion in
                MainActor.assumeIsolated {
                    guard let model, let task = model.task else { completion([]); return }
                    completion(Self.menu(task, model: model) + Self.deleteMenu(model: model))
                }
            },
        ]))
        more.accessibilityLabel = "More"
        more.accessibilityIdentifier = "task.more"
        navigationItem.rightBarButtonItem = more
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// [tasks] The task's rows in ⋯ (owner 2026-11-07, Pinned Task): headed by where it came from, Mark Done first,
    /// then the Task Page and History; what you set now and then (status, prep or repeat, notes) under Details. On the
    /// task's chat, Chat ▸ follows, then `deleteMenu`.
    static func menu(_ task: TodoTask, model: TodoSheetModel) -> [UIMenuElement] {
        var top: [UIMenuElement] = []
        if task.isDone {
            top.append(UIAction(title: "Reopen", image: UIImage(systemName: "arrow.uturn.backward")) { _ in model.reopen() })
        } else if !model.gone {
            top.append(UIAction(title: "Mark Done", image: UIImage(systemName: "checkmark.circle")) { _ in model.markDone() })
        }
        if model.offersPage(task) {
            top.append(UIAction(title: "Task Page", image: UIImage(systemName: "doc.richtext")) { _ in model.openPage() })
        }
        top.append(UIAction(title: "History", image: UIImage(systemName: "clock.arrow.circlepath")) { _ in model.showHistory() })

        // Status: the five, as the page's capsule had them; Done is Mark Done (the page goes, the list offers Undo).
        let statuses = ["open", "working", "ready", "needs_you", "done"]
        var details: [UIMenuElement] = [
            UIMenu(title: "Status", subtitle: TodoWords.statusLabel(task.status), image: UIImage(systemName: TodoSheetView.statusSymbol(task.status)),
                   children: [UIMenu(options: [.displayInline, .singleSelection], children: statuses.map { status in
                       UIAction(title: TodoWords.statusLabel(status), image: UIImage(systemName: TodoSheetView.statusSymbol(status)),
                                state: task.status == status ? .on : .off) { _ in
                           guard status != task.status else { return }
                           if status == "done" { model.markDone() } else { model.setStatus(status) }
                       }
                   })]),
        ]
        // Who does it (owner 2026-11-09, the organized task view: the top bar names the bot, so the page has no Who row).
        let bots = PagesNames.scopeChoices(model.context.bots)
        details.append(UIMenu(title: "Who", subtitle: task.whoKind == .me ? "Just Me" : TodoWords.whoWords(task, botName: model.botName),
                              image: UIImage(systemName: task.whoKind == .me ? "person" : "person.2"), children: [
            UIAction(title: "Just Me", image: UIImage(systemName: "person"), state: task.whoKind == .me ? .on : .off) { _ in model.setWho(.me, bot: nil) },
            UIMenu(title: "Together", options: .displayInline, children: bots.map { bot in
                UIAction(title: "You & \(bot.name)", state: task.whoKind == .together && task.helper == bot.id ? .on : .off) { _ in
                    model.setWho(.together, bot: bot.id)
                }
            }),
            UIMenu(title: "A Bot Does It", options: .displayInline, children: bots.map { bot in
                UIAction(title: bot.name, state: task.whoKind == .bot && task.helper == bot.id ? .on : .off) { _ in
                    model.setWho(.bot, bot: bot.id)
                }
            }),
        ]))
        if task.whoKind != .me {
            let name = model.botName(task.helper)
            details.append(UIAction(title: "\(name) Gets It Ready", image: UIImage(systemName: "sparkles"),
                                    state: task.prep ? .on : .off) { _ in model.setPrep(!task.prep) })
        } else {
            let rules: [String?] = [nil] + TodoWords.repeatRules
            details.append(UIMenu(title: "Repeat", subtitle: TodoWords.repeatLabel(task.repeatRule), image: UIImage(systemName: "repeat"),
                                  children: [UIMenu(options: [.displayInline, .singleSelection], children: rules.map { rule in
                                      UIAction(title: TodoWords.repeatLabel(rule), state: task.repeatRule == rule ? .on : .off) { _ in model.setRepeat(rule) }
                                  })]))
        }
        let noNotes = task.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        details.append(UIAction(title: noNotes ? "Add Notes" : "Edit Notes", image: UIImage(systemName: "note.text")) { _ in model.editNotes() })
        details.append(UIAction(title: "Copy Title", image: UIImage(systemName: "doc.on.doc")) { _ in
            UIPasteboard.general.string = task.title
            PagesHaptics.success()
            model.show("Copied")
        })
        return [
            UIMenu(title: TodoWords.origin(task, now: Date(), botName: model.botName), options: .displayInline, children: top),
            UIMenu(title: "Details", image: UIImage(systemName: "slider.horizontal.3"), children: details),
        ]
    }

    /// ⋯'s last row: one Delete (the chat's own Delete Chat is a different thing, under Chat ▸).
    static func deleteMenu(model: TodoSheetModel) -> [UIMenuElement] {
        [UIAction(title: "Delete Task…", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in model.confirmDelete() }]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "task.sheet"
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
                                               name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    /// The keyboard's overlap is this page's own bottom safe area, so the Ask bar rides above it (as the Kanban task's).
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
}

struct TodoSheetView: View {
    @Bindable var model: TodoSheetModel
    @FocusState private var focus: Field?
    enum Field: Hashable { case step, notes, ask }
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if let task = model.task {
                content(task)
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
                    .accessibilityIdentifier("task.notice")
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.notice)   // motion-ok: the notice fades (opacity transition)
        .ignoresSafeArea(.keyboard)
    }

    @ViewBuilder private func content(_ task: TodoTask) -> some View {
        if model.embedded {
            // [tasks] Owner 2026-11-09: the plain task view (TaskPlainView), on the chat's own page.
            TaskPlainView(model: model, task: task)
                .environment(\.hqChatLead, true)
                .background(alignment: .bottom) { TaskPanelBacking() }
        } else {
            sections(task)
                .refreshable { await model.store.refresh(force: true) }
                .safeAreaInset(edge: .bottom, spacing: 0) { askBar(task) }
        }
    }

    /// [tasks] The brief (owner 2026-11-07, Pinned Task step 1): where it stands, the title once, due and who as one
    /// line, the bot's own words and what's next, what it made, the steps, notes, and the one move at the foot. Each
    /// thing is said once; the status menu, the origin and the activity went to ⋯ (History).
    private func sections(_ task: TodoTask) -> some View {
        let now = TaskNow.pick(task, phone: task.status == "ready" ? model.phoneNumber(task) : nil, deleted: model.gone)
        return ScrollViewReader { proxy in List {
            // Owner 2026-11-08: "this page is not anywhere near tidy enough … the hierarchy of information, placement
            // and size of every element, structure to visually define sections without feeling forced". One order and
            // one kind of section: the task's head on the page (where it stands, its title, due and who), then cards,
            // each under a heading of the same kind: what the bot said, what it made, the steps, the notes.
            Section {
                head(task).todoBareRow(top: 0, bottom: 0)
            }
            .listSectionSeparator(.hidden, edges: .all)
            if let words = TodoWords.botWords(task) {
                Section {
                    botCard(task, words, next: TodoWords.nextLine(task)).todoCardRow()
                }
                .listSectionSeparator(.hidden, edges: .all)
            } else if let next = TodoWords.nextLine(task) {
                Section {
                    nextLine(next.text, watch: next.isWatch).padding(.vertical, 12).todoCardRow()
                }
                .listSectionSeparator(.hidden, edges: .all)
            }
            // What needs you comes first: on a task that's ready, what the bot got ready; otherwise the steps.
            let madeFirst = task.status == "ready"
            if madeFirst { madeSection(task) }
            if !(task.isDone && task.steps.isEmpty) { stepsSection(task) }   // a finished task isn't offered a first step
            if !madeFirst { madeSection(task) }
            notesSection(task)
            if let now, !model.embedded {   // on the task's chat it stands at the panel's foot instead
                Section { nowRow(task, now).todoBareRow(top: 6, bottom: 2) }
                    .listSectionSeparator(.hidden, edges: .all)
            }
        }
        .hqGroupedPage()
        .listStyle(.insetGrouped)
        .contentMargins(.top, 2, for: .scrollContent)
        .listSectionSpacing(12)
        .environment(\.defaultMinListRowHeight, 0)   // the brief's lines keep their own spacing
        // A field opened in a brief that scrolls in its panel comes into sight (it is drawn, and takes the keys, there).
        .onChange(of: model.addingStep) { _, adding in
            if adding { DispatchQueue.main.async { HQMotion.withAnimation(.snappy) { proxy.scrollTo("task.add-step", anchor: .bottom) } } }
        }
        .onChange(of: model.editingNotes) { _, editing in
            if editing { DispatchQueue.main.async { HQMotion.withAnimation(.snappy) { proxy.scrollTo("task.notes", anchor: .bottom) } } }
        }
        }
    }

    // MARK: Top

    /// The task's head, on the page: where it stands (its words open History), the title, and due and who (each a
    /// menu, marked by its symbol). Page › stands here only when the bot said nothing for a card to hold.
    private func head(_ task: TodoTask) -> some View {
        let hasCard = TodoWords.botWords(task) != nil
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                stateWords(task, time: !hasCard)
                Spacer(minLength: 8)
                if !hasCard { pageLink(task) }
            }
            .padding(.horizontal, 4)
            title(task)
            facts(task).padding(.top, 4)
            if model.gone {
                Text("This task was deleted.").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                    .padding(.horizontal, 4).padding(.top, 6)
            }
        }
        .padding(.bottom, 4)
        .onChange(of: task.rev) { _, rev in model.taskChanged(rev) }
    }

    /// "📅 Tomorrow, 8:00 AM   👥 You & Hermes", on one line where it fits.
    private func facts(_ task: TodoTask) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { dueMenu(task); whoMenu(task) }
            VStack(alignment: .leading, spacing: 0) { dueMenu(task); whoMenu(task) }
        }
        .font(Font.hq(.subheadline))
        .buttonStyle(.borderless)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    private func stateWords(_ task: TodoTask, time showsTime: Bool) -> some View {
        let color = Self.statusColor(task.status)
        // A finished task says when, in the same words as its bar in the chat ("Completed today, 11:40 AM").
        let words = task.isDone ? TaskBarView.completed(task) : TodoWords.stateWords(task, botName: model.botName)
        let time = showsTime && !task.isDone ? TodoWords.stateTime(task, now: Date()) : nil
        return Button { model.showHistory() } label: {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: Self.statusSymbol(task.status))
                    .font(Font.hq(.footnote).weight(.semibold))
                Text(words).fontWeight(.semibold).lineLimit(1)
                if let time { Text("· \(time)").foregroundStyle(Color.hqLabel2).lineLimit(1) }
            }
            .foregroundStyle(color)
            .font(Font.hq(.subheadline))
            .frame(minHeight: 30, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([words, time].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Shows the task’s history")
        .accessibilityIdentifier("task.state")
    }

    /// "Page ›": the Task Page, once the bot wrote one.
    @ViewBuilder private func pageLink(_ task: TodoTask) -> some View {
        if task.pageAt != nil, model.offersPage(task) {
            Button { model.openPage() } label: {
                HStack(spacing: 3) {
                    if model.pageLoading { ProgressView().controlSize(.mini) }
                    Text("Page")
                    Image(systemName: "chevron.right").font(Font.hq(.caption).weight(.semibold))
                }
                .font(Font.hq(.subheadline))
                .foregroundStyle(Color.hqTintText)
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .accessibilityLabel("Task Page")
            .accessibilityIdentifier("task.page.open")
        }
    }

    private func title(_ task: TodoTask) -> some View {
        Text(task.title.isEmpty ? "Untitled Task" : task.title)
            .font(Font.hqSystem(.title2, design: .default, weight: .bold))
            .foregroundStyle(Color.hqLabel)
            .lineLimit(typeSize.isAccessibilitySize ? nil : 3)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("task.title")
    }

    private func factLabel(_ text: String, symbol: String, color: Color = Color.hqLabel2) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(Font.hq(.footnote)).accessibilityHidden(true)
            Text(text).lineLimit(1)
        }
        .foregroundStyle(color)
        .frame(minHeight: 30)
        .contentShape(Rectangle())
    }

    private func whoMenu(_ task: TodoTask) -> some View {
        let bots = PagesNames.scopeChoices(model.context.bots)
        let words = TodoWords.whoWords(task, botName: model.botName)
        return Menu {
            Button { model.setWho(.me, bot: nil) } label: { Label("Just Me", systemImage: task.whoKind == .me ? "checkmark" : "person") }
            Section("Together") {
                ForEach(bots, id: \.id) { bot in
                    Button { model.setWho(.together, bot: bot.id) } label: {
                        Label("You & \(bot.name)", systemImage: task.whoKind == .together && task.helper == bot.id ? "checkmark" : "person.2")
                    }
                }
            }
            Section("A Bot Does It") {
                ForEach(bots, id: \.id) { bot in
                    Button { model.setWho(.bot, bot: bot.id) } label: {
                        Label(bot.name, systemImage: task.whoKind == .bot && task.helper == bot.id ? "checkmark" : "cpu")
                    }
                }
            }
        } label: {
            factLabel(task.whoKind == .me ? "Just Me" : words, symbol: task.whoKind == .me ? "person" : "person.2")
        }
        .accessibilityLabel("Who: \(words). Change")
        .accessibilityIdentifier("task.who")
    }

    private func dueMenu(_ task: TodoTask) -> some View {
        let now = Date()
        let due = TodoDates.due(task.due)
        let color: Color = {
            guard let due, !task.isDone else { return Color.hqLabel2 }
            let today = Calendar.current.startOfDay(for: now)
            if due.hasTime ? due.date < now : Calendar.current.startOfDay(for: due.date) < today { return Color.hqRed }
            return Calendar.current.isDate(due.date, inSameDayAs: now) ? Color.hqOrange : Color.hqLabel2
        }()
        return Menu {
            Button("Today") { model.setDue(now, hasTime: false) }
            Button("Tomorrow") { model.setDue(Calendar.current.date(byAdding: .day, value: 1, to: now), hasTime: false) }
            Button("Next Week") { model.setDue(Calendar.current.date(byAdding: .day, value: 7, to: now), hasTime: false) }
            Button("Choose Date…") { pickDate(task) }
            if due != nil { Button("No Due Date", role: .destructive) { model.setDue(nil, hasTime: false) } }
        } label: {
            factLabel(due == nil ? "No due date" : TodoWords.dueTile(task, now: now), symbol: "calendar", color: color)
        }
        .accessibilityLabel("Due: \(due == nil ? "No due date" : TodoWords.dueTile(task, now: now)). Change")
        .accessibilityIdentifier("task.due")
    }

    private func pickDate(_ task: TodoTask) {
        guard let controller = model.controller else { return }
        let due = TodoDates.due(task.due)
        let picker = TodoDatePicker.make(date: due?.date, hasTime: due?.hasTime ?? false, rings: task.whoKind != .bot) { [weak model] date, hasTime in
            model?.setDue(date, hasTime: hasTime)
        }
        controller.present(picker, animated: true)
    }

    /// What the bot said, as one card: its face and name and since when, Page › where it wrote one, its words (from its
    /// Task Page, else its line), and under a hairline what's next. A question it asks is never cut; anything else
    /// folds, with "more" on its last line.
    private func botCard(_ task: TodoTask, _ words: String, next: (text: String, isWatch: Bool)?) -> some View {
        let profile = Self.speaker(task)
        let time = TodoWords.stateTime(task, now: Date())
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                HeadImage(raw: model.head(profile), profile: profile, size: 20).accessibilityHidden(true)
                Text("\(Text(model.botName(profile)).fontWeight(.semibold).foregroundStyle(Color.hqLabel))\(Text(time.map { "  ·  " + $0 } ?? "").foregroundStyle(Color.hqLabel2))")
                    .font(Font.hq(.footnote)).lineLimit(1)
                Spacer(minLength: 8)
                pageLink(task)
            }
            .frame(minHeight: 28)
            if task.status == "needs_you", !model.briefTight {
                TodoRichTextView(text: words, identifier: "task.words", open: model.openPath)
            } else {
                TodoFoldedText(text: words, lines: 3, identifier: "task.words", open: model.openPath, tapOpens: true)
            }
            if let next {
                TodoHairline().padding(.vertical, 2)
                nextLine(next.text, watch: next.isWatch)
            }
        }
        .padding(.horizontal, 4).padding(.top, 6).padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    /// "Next: you send it; I check at 9 AM." or "◎ Watching for a reply from Ivy".
    private func nextLine(_ text: String, watch: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if watch { Image(systemName: "eye").font(Font.hq(.caption).weight(.semibold)).accessibilityHidden(true) }
            Text(Self.nextWords(text)).lineLimit(model.briefTight ? 2 : nil)
        }
        .font(Font.hq(.subheadline))
        .foregroundStyle(Color.hqLabel2)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(watch ? "task.watch" : "task.next")
    }

    /// "Next: Monday 8 AM …" with its first word set off, so it reads as a label.
    static func nextWords(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        if let colon = text.firstIndex(of: ":"), text.distance(from: text.startIndex, to: colon) <= 12,
           let range = out.range(of: String(text[...colon])) {
            out[range].font = Font.hq(.subheadline).weight(.semibold)
            out[range].foregroundColor = Color.hqLabel
        }
        return out
    }

    /// Whose words the brief shows: the task's bot, else the bot that added it.
    static func speaker(_ task: TodoTask) -> String {
        task.helper ?? task.createdBy.flatMap { $0 == "you" ? nil : $0 } ?? "default"
    }

    static func statusColor(_ status: String) -> Color {
        switch status {
        case "ready": return Color(uiColor: TodoInk.ready)
        case "working": return Color.hqTintText
        case "needs_you": return Color.hqOrange
        case "done": return Color(uiColor: TodoInk.ready)
        default: return Color.hqLabel2
        }
    }

    static func statusSymbol(_ status: String) -> String {
        switch status {
        case "ready": return "sparkles"
        case "working": return "gearshape.2.fill"
        case "needs_you": return "hand.raised.fill"
        case "done": return "checkmark.circle.fill"
        default: return "circle"
        }
    }

    // MARK: What the bot made

    /// What the bot made, always on the brief, in every state.
    @ViewBuilder private func madeSection(_ task: TodoTask) -> some View {
        let made = TodoWords.shownMade(task)
        if !made.isEmpty {
            Section {
                ForEach(Array(made.enumerated()), id: \.element.id) { index, item in
                    madeRow(item)
                        .overlay(alignment: .bottom) { if index < made.count - 1 { TodoHairline().padding(.leading, 46) } }
                        .todoCardRow()
                }
            } header: {
                sectionHeader("From \(model.botName(Self.speaker(task)))") { EmptyView() }
            }
            .listSectionSeparator(.hidden, edges: .all)
        }
    }

    private func madeRow(_ made: TodoMade) -> some View {
        Button { model.open(made) } label: {
            HStack(spacing: 12) {
                let look = Self.madeLook(made)
                Image(systemName: look.symbol)
                    .font(Font.hq(.subheadline).weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(look.color))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(made.title.isEmpty ? made.ref : made.title).font(Font.hq(.body)).foregroundStyle(Color.hqLabel).lineLimit(2)
                    Text(Self.madeDetail(made)).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2).lineLimit(1)
                        .truncationMode(made.kind == "note" ? .tail : .middle)   // a note's first words, a file's name and type
                }
                Spacer(minLength: 8)
                SettingsChevron()
            }
            .padding(.horizontal, 4).padding(.vertical, 8)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("task.made.\(made.kind)")
    }

    static func madeLook(_ made: TodoMade) -> (symbol: String, color: Color) {
        switch made.kind {
        case "file":
            let blue = Color(red: 0.04, green: 0.52, blue: 1)
            switch (made.ref as NSString).pathExtension.lowercased() {
            case "png", "jpg", "jpeg", "heic", "gif", "webp": return ("photo.fill", blue)
            case "pdf": return ("doc.richtext.fill", blue)
            case "csv", "xlsx", "xls", "numbers", "tsv": return ("tablecells.fill", blue)
            default: return ("doc.text.fill", blue)
            }
        case "link": return ("link", Color(red: 0.19, green: 0.69, blue: 0.31))
        default: return ("note.text", Color(red: 1, green: 0.62, blue: 0.04))
        }
    }

    static func madeDetail(_ made: TodoMade) -> String {
        switch made.kind {
        case "file": return (made.ref as NSString).lastPathComponent
        case "link": return URL(string: made.ref)?.host() ?? made.ref
        default: return TodoReadable.preview(made.ref)
        }
    }

    // MARK: Steps

    @ViewBuilder
    private func stepsSection(_ task: TodoTask) -> some View {
        let done = task.steps.filter(\.done).count
        // Your next open step, on a task you share: "Your turn".
        let yours = task.whoKind == .me ? nil : task.steps.first { !$0.done && $0.who != "bot" }?.id
        Section {
            ForEach(Array(task.steps.enumerated()), id: \.element.id) { index, step in
                stepRow(step, after: task.steps.prefix(index).contains { !$0.done && $0.who == "me" }, yourTurn: step.id == yours,
                        last: index == task.steps.count - 1 && !(model.addingStep || task.steps.isEmpty), task: task)
                    .todoCardRow()
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { model.deleteStep(step) } label: { Label("Delete", systemImage: "trash") }
                    }
                    .modifier(TodoStepMenu(step: step, task: task, model: model))
            }
            if model.addingStep {
                HStack(spacing: 12) {
                    Image(systemName: "circle").font(Font.hq(.title3).weight(.light)).foregroundStyle(Color.hqLabel3)
                        .frame(minWidth: 28).accessibilityHidden(true)
                    TextField("Add a step", text: $model.newStep)
                        .font(Font.hq(.body))
                        .focused($focus, equals: .step)
                        .submitLabel(.done)
                        .onSubmit { model.addStep(); focus = .step }
                        .onAppear { focus = .step }   // Steps' + or "+ Add a step": the field takes the keys
                        .onChange(of: focus) { old, new in
                            if old == .step, new != .step { model.addingStep = false }   // the words wait for the next +
                        }
                        .accessibilityIdentifier("task.add-step")
                }
                .padding(.horizontal, 4)
                .frame(minHeight: 48)
                .id("task.add-step")
                .todoCardRow()
            } else if task.steps.isEmpty, !model.gone {
                quietAdd("Add a Step", identifier: "task.steps.add") { PagesHaptics.selection(); model.addingStep = true }
                    .padding(.vertical, 4)
                    .todoCardRow()
            }
        } header: {
            sectionHeader("Steps", count: task.steps.isEmpty ? nil : "\(done) of \(task.steps.count)") {
                if !task.steps.isEmpty, !model.gone {
                    Button { PagesHaptics.selection(); model.addingStep = true } label: {
                        Image(systemName: "plus").font(Font.hq(.body).weight(.semibold)).foregroundStyle(Color.hqTintText)
                            .frame(minWidth: 44, minHeight: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Add a Step")
                    .accessibilityIdentifier("task.steps.add")
                }
            }
        }
        .listSectionSeparator(.hidden, edges: .all)
    }

    /// A section's heading over its card ("Steps 1 of 3 +", "From Hermes", "Notes Edit"): one kind for all of them.
    private func sectionHeader<Trailing: View>(_ title: String, count: String? = nil,
                                               @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center) {
            briefLabel {
                if let count { Text("\(title)  \(Text(count).foregroundStyle(Color.hqLabel3))") } else { Text(title) }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .frame(minHeight: 32)
        .textCase(nil)
        .accessibilityElement(children: .contain)
    }

    /// A label on the brief ("Steps 2 of 3", "Notes"): grey in the iOS look, the look's own label in the Desktop Look.
    private func briefLabel<Label: View>(@ViewBuilder _ label: () -> Label) -> some View {
        // [ui-sizing] The font inside the label: outside it, the header's own font (at a UI Scale) won.
        HQSectionLabel {
            if Theme.isDesktop { label() } else { label().font(Font.hq(.subheadline).weight(.semibold)) }
        }
        .foregroundStyle(Color.hqLabel2)
    }

    /// "+ Add a step", "+ Add notes": a quiet link where an empty field had stood.
    private func quietAdd(_ words: String, symbol: String = "plus", identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(Font.hq(.subheadline).weight(.semibold)).accessibilityHidden(true)
                Text(words)
            }
            .font(Font.hq(.subheadline))
            .foregroundStyle(Color.hqTintText)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    private func stepRow(_ step: TodoStep, after: Bool, yourTurn: Bool, last: Bool, task: TodoTask) -> some View {
        let bot = step.who == "bot"
        let name = bot ? model.botName(task.helper) : "You"
        // The circle and who-tag sit on the title's first line, so an opened long step reads from the top.
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button { model.toggleStep(step) } label: {
                Image(systemName: step.done ? "checkmark.circle.fill" : "circle")
                    .font(Font.hq(.title3).weight(.light))
                    .foregroundStyle(step.done ? Color.hqTint : Color.hqLabel3)
                    .frame(minWidth: 28, minHeight: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + HQFont.preferred(.body).capHeight / 2 }
            .accessibilityLabel(step.done ? "Done" : "Not done")
            VStack(alignment: .leading, spacing: 2) {
                // A bot's long step (0.9.32 let it write 200 characters) folds to two lines; a tap shows it whole.
                let long = step.title.count > Self.stepFold
                Text(step.title)
                    .font(Font.hq(.body))
                    .foregroundStyle(step.done ? Color.hqLabel3 : Color.hqLabel)
                    .strikethrough(step.done, color: Color.hqLabel3)
                    .lineLimit(long && !model.openSteps.contains(step.id) ? 2 : nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
                    .onTapGesture { if long { HQMotion.withAnimation(.snappy) { model.toggleOpen(step) } } }
                    .accessibilityIdentifier("task.step.title")
                if bot, !step.done, after {
                    Text("After you").font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                } else if yourTurn {
                    Text("Your turn").font(Font.hq(.footnote).weight(.semibold)).foregroundStyle(Color.hqTintText)
                        .accessibilityIdentifier("task.step.your-turn")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Who does it: a menu now (a tap had flipped it at once, right where ↓ floats). A task of yours alone
            // shows no owner on your own steps; a bot's step left on it still says whose it is.
            if task.whoKind != .me || bot {
                Menu {
                    Button { model.setStepWho(step, "bot") } label: {
                        Label("Give to \(model.botName(task.helper))", systemImage: bot ? "checkmark" : "sparkles")
                    }
                    Button { model.setStepWho(step, "me") } label: { Label("Take It Myself", systemImage: bot ? "person" : "checkmark") }
                } label: {
                    HStack(spacing: 4) {
                        if bot, let profile = task.helper { HeadImage(raw: model.head(profile), profile: profile, size: 20) }
                        else if bot { Image(systemName: "sparkles").font(Font.hq(.caption)) }
                        else { Image(systemName: "person.fill").font(Font.hq(.caption2)); Text(name).font(Font.hq(.footnote)) }
                    }
                    .foregroundStyle(Color.hqLabel2)
                    .frame(minWidth: 32, minHeight: 32, alignment: .trailing)
                    .contentShape(Rectangle())
                }
                // A bot's face sits beside the title's first line, as the circle does (it had dropped under it on
                // the Mac); "You" keeps its own baseline.
                .alignmentGuide(.firstTextBaseline) { d in
                    bot ? d[VerticalAlignment.center] + HQFont.preferred(.body).capHeight / 2 : d[.firstTextBaseline]
                }
                .buttonStyle(.borderless)
                .disabled(task.whoKind == .me)
                .accessibilityLabel("Who does it: \(name)")
                .accessibilityHint(task.whoKind == .me ? "" : "Changes who does this step")
            }
        }
        .padding(.horizontal, 4).padding(.vertical, 4)
        .frame(minHeight: 48)
        .overlay(alignment: .bottom) { if !last { TodoHairline().padding(.leading, 44) } }
        .accessibilityElement(children: .combine)
    }

    /// A step longer than this many characters folds to two lines.
    static let stepFold = 70

    // MARK: Notes

    /// Notes read formatted (a bot's run of sentences as lines, files and phone numbers that open), two lines with
    /// More, until Edit. None: a quiet "+ Add notes" where a 100 pt empty box had stood on every task.
    @ViewBuilder
    private func notesSection(_ task: TodoTask) -> some View {
        let filled = !task.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if model.editingNotes || filled {
            Section {
                if !model.editingNotes {
                    TodoFoldedText(text: task.notes, lines: 2, identifier: "task.notes.text", open: model.openPath)
                        .padding(.horizontal, 4).padding(.vertical, 12)
                        .todoCardRow()
                } else {
                    TextField("Add notes", text: $model.notes, axis: .vertical)
                        .lineLimit(2...10)
                        .font(Font.hq(.body))
                        .foregroundStyle(Color.hqLabel)
                        .focused($focus, equals: .notes)
                        .onAppear { focus = .notes }   // Edit, "+ Add notes" or ⋯ › Details: the field takes the keys
                        .onChange(of: focus) { old, new in if old == .notes, new != .notes { model.saveNotes() } }
                        .padding(.horizontal, 4)
                        .accessibilityIdentifier("task.notes")
                        .id("task.notes")
                        .padding(.vertical, 12)
                        .todoCardRow()
                }
            } header: {
                sectionHeader("Notes") {
                    if !model.editingNotes {
                        Button("Edit") { model.editNotes() }
                            .font(Font.hq(.subheadline).weight(.semibold))
                            .foregroundStyle(Color.hqTintText)
                            .buttonStyle(.borderless)
                            .frame(minHeight: 32)
                            .accessibilityLabel("Edit Notes")
                            .accessibilityIdentifier("task.notes.edit")
                    }
                }
            }
            .listSectionSeparator(.hidden, edges: .all)
        } else if !model.gone, !model.briefTight, !model.embedded {
            // On the task's view, notes start from ⋯ › Details: a link floating under the cards was the page's one
            // loose part (owner 2026-11-08, "not anywhere near tidy enough").
            Section {
                quietAdd("Add Notes", identifier: "task.notes.add") { model.editNotes() }
                    .todoBareRow(top: 0, bottom: 0)
            }
            .listSectionSeparator(.hidden, edges: .all)
        }
    }

    // MARK: The one move

    /// The brief's foot: one move by the task's state (`TaskNow`), tinted, and Done beside it, in the same place on
    /// every task. Side by side; stacked at accessibility sizes, so no label is ever cut.
    private func nowRow(_ task: TodoTask, _ now: TaskNow) -> some View {
        ViewThatFits(in: .horizontal) {
            if !typeSize.isAccessibilitySize {
                HStack(spacing: 10) {
                    nowButton(now.primary, task: task, tinted: now.tinted, secondary: false, oneLine: true)
                    if let second = now.secondary {
                        nowButton(second, task: task, tinted: false, secondary: true, oneLine: true).fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            VStack(spacing: 10) {
                nowButton(now.primary, task: task, tinted: now.tinted, secondary: false, oneLine: false)
                if let second = now.secondary { nowButton(second, task: task, tinted: false, secondary: true, oneLine: false) }
            }
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task.now")
    }

    /// `oneLine`: side by side, a label that would need two lines doesn't fit, and the row stacks instead.
    private func nowButton(_ action: TaskNow.Action, task: TodoTask, tinted: Bool, secondary: Bool, oneLine: Bool) -> some View {
        let words = action.label(botName: model.botName(model.chatBot(task)), secondary: secondary)
        return Button { run(action, task: task) } label: {
            // Not a Label: inside .borderedProminent (the iOS look) its icon kept its room but drew nothing.
            HStack(spacing: 7) {
                Image(systemName: action.symbol).accessibilityHidden(true)
                Text(words).lineLimit(oneLine ? 1 : nil).multilineTextAlignment(.center).fixedSize(horizontal: oneLine, vertical: true)
            }
            .font(Font.hq(.body).weight(.semibold))
            .padding(.horizontal, secondary ? 8 : 0)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .modifier(NowButtonStyle(tinted: tinted))
        .accessibilityLabel(words)
        .accessibilityIdentifier(action.identifier)
    }

    private func run(_ action: TaskNow.Action, task: TodoTask) {
        if action == .answer, !model.embedded { PagesHaptics.selection(); focus = .ask; return }   // the stand-alone page's own field
        model.perform(action, task: task)
    }

    // MARK: Ask

    private func askBar(_ task: TodoTask) -> some View {
        let name = model.botName(model.chatBot(task))
        let empty = model.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Boxed like the chat's own bar in the Desktop Look; round in the iOS look.
        let box = Theme.isDesktop ? AnyShape(RoundedRectangle(cornerRadius: DesktopRows.radius, style: .continuous)) : nil
        return HStack(spacing: 8) {
            if model.chatLink(task) != nil {
                // The task's chat so far: opens over the task, as sending does.
                Button { model.openChat(task) } label: {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .font(Font.hq(.body).weight(.semibold))
                        .foregroundStyle(Color.hqTintText)
                        .frame(width: 40, height: 40)
                        .background((box ?? AnyShape(Circle())).fill(Color(uiColor: HQPalette.sheetCard)))
                        .overlay((box ?? AnyShape(Circle())).stroke(Color.hqStroke, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open Chat with \(name)")
                .accessibilityIdentifier("task.chat")
            }
            TextField("Message \(name) about this task", text: $model.question, axis: .vertical)
                .lineLimit(1...4)
                .font(Font.hq(.body))
                .focused($focus, equals: .ask)
                .submitLabel(.send)
                .onSubmit { focus = nil; model.sendQuestion() }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background((box ?? AnyShape(Capsule())).fill(Color(uiColor: HQPalette.sheetCard)))
                .overlay((box ?? AnyShape(Capsule())).stroke(Color.hqStroke, lineWidth: 1))
                .accessibilityIdentifier("task.ask")
            Button { focus = nil; model.sendQuestion() } label: {
                Image(systemName: "arrow.up")
                    .font(Font.hq(.body).weight(.bold))
                    .foregroundStyle(Color.hqOnTint)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(empty ? Color.hqLabel3 : Color.hqTint))
            }
            .buttonStyle(.plain)
            .disabled(empty)
            .accessibilityLabel("Send to \(name)")
            .accessibilityIdentifier("task.ask.send")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.bar)
    }
}

/// [tasks] The task view's panel: one fill from behind the bar to the screen's foot, the composer floating on it.
private struct TaskPanelBacking: View {
    var body: some View {
        // Two states (owner 2026-11-08): the task's view has the screen, so its panel has no foot of its own. It runs
        // on behind the composer to the screen's edge; the rounded, lit, shadowed edge it had over the chat drew a
        // harsh line across the composer's top ("What is with the harsh line here?").
        Rectangle()
            .fill(Color(uiColor: TaskPanel.fill))
            .padding(.top, -600)      // up behind the bar and the pull-down bounce
            .padding(.bottom, -600)   // down behind the composer and the home indicator
            .accessibilityHidden(true)
    }
}

/// [tasks] The tinted move, tinted rather than filled (the solid bar was the loudest thing on the task).
struct TintedCapsuleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.hqTintText)
            .padding(.horizontal, 12)
            .background(Capsule().fill(Color.hqTint.opacity(0.15)))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.55 : 1)
    }
}

/// [tasks] A move that isn't the one: the panel's card fill with a thin edge on a task's chat in the iOS look (iOS's
/// grey `.bordered` fill came out darker than the dark chat's page, a hole beside the cards, 2026-11-05).
struct PanelCapsuleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.hqLabel)
            .padding(.horizontal, 12)
            .background(Capsule().fill(Color(uiColor: TaskPanel.card)))
            .overlay(Capsule().strokeBorder(Color.hqStroke, lineWidth: 1))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.55 : 1)
    }
}

/// The brief's moves: the one tinted (tinted in the iOS look, prominent in the others), the rest bordered.
private struct NowButtonStyle: ViewModifier {
    var tinted: Bool
    @Environment(\.hqChatLead) private var chatLead
    func body(content: Content) -> some View {
        let iosLook = !Theme.isDesktop && !DeviceWord.isMac
        if tinted && iosLook {
            content.buttonStyle(TintedCapsuleStyle())
        } else if tinted {
            content.hqProminentButtonStyle().buttonBorderShape(.capsule)
        } else if chatLead && iosLook {
            content.buttonStyle(PanelCapsuleStyle())
        } else {
            content.hqBorderedButtonStyle().buttonBorderShape(.capsule)
        }
    }
}

/// A line between two steps, in the panel's edge colour on a task's chat.
private struct TodoHairline: View {
    @Environment(\.hqChatLead) private var chatLead
    @Environment(\.displayScale) private var scale
    var body: some View {
        Rectangle()
            .fill(chatLead ? Color(uiColor: TaskPanel.edge) : Color.hqStroke)
            .frame(height: 1 / max(scale, 1))
            .accessibilityHidden(true)
    }
}

/// A bot's note (made `kind: note`), on its own sheet: its title as the heading, the note as lines (`TodoRich`), and
/// what you do with a draft (owner 2026-11-07, Pinned Task): Copy, Share…, and Ask for Changes in the task's chat.
struct TodoNoteView: View {
    var title: String
    var text: String
    var open: (String) -> Void
    var share: (() -> Void)? = nil
    /// The task's chat bar takes the keys with "Changes to “…”: " (nil where the task has no chat on its page).
    var askChanges: (() -> Void)? = nil
    @State private var copied = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    if !title.isEmpty {
                        Text(title)
                            .font(Font.hqSystem(.title3, design: .default, weight: .semibold))
                            .foregroundStyle(Color.hqLabel)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .accessibilityAddTraits(.isHeader)
                    }
                    TodoRichTextView(text: text, identifier: "task.note.text", open: open)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .hqGlassCard()
                // Copy and Share… side by side; Ask for Changes, which goes to the chat, under them.
                if typeSize.isAccessibilitySize {
                    VStack(spacing: 10) { copyButton; shareButton; changesButton }
                } else {
                    VStack(spacing: 10) {
                        HStack(spacing: 10) { copyButton; shareButton }
                        changesButton
                    }
                }
            }
            .padding(16)
        }
        .background(Color(uiColor: HQPalette.sheetPage))
    }

    private var copyButton: some View {
        Button {
            UIPasteboard.general.string = text
            PagesHaptics.success()
            HQAnnounce.say("Copied")
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
        } label: { noteLabel(copied ? "Copied" : "Copy", symbol: copied ? "checkmark" : "doc.on.doc") }
            .hqBorderedButtonStyle().buttonBorderShape(.capsule)
            .accessibilityIdentifier("task.note.copy")
    }

    @ViewBuilder private var shareButton: some View {
        if let share {
            Button { share() } label: { noteLabel("Share…", symbol: "square.and.arrow.up") }
                .hqBorderedButtonStyle().buttonBorderShape(.capsule)
                .accessibilityIdentifier("task.note.share")
        }
    }

    @ViewBuilder private var changesButton: some View {
        if let askChanges {
            Button { askChanges() } label: { noteLabel("Ask for Changes", symbol: "bubble.left") }
                .hqBorderedButtonStyle().buttonBorderShape(.capsule)
                .accessibilityIdentifier("task.note.changes")
        }
    }

    private func noteLabel(_ words: String, symbol: String) -> some View {
        HStack(spacing: 6) { Image(systemName: symbol).accessibilityHidden(true); Text(words) }
            .font(Font.hq(.subheadline).weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 40)
    }
}

/// [mac] Mac polish #43: a mouse has no swipe, so a step's right-click has its Delete (docs/mac.md, mouse-only paths),
/// with the circle's and the who-tag's choices beside it. The iPhone and iPad keep the swipe alone.
private struct TodoStepMenu: ViewModifier {
    var step: TodoStep
    var task: TodoTask
    var model: TodoSheetModel

    @ViewBuilder func body(content: Content) -> some View {
        if DeviceWord.isMac {
            content.contextMenu {
                Button(step.done ? "Mark Not Done" : "Mark Done", systemImage: step.done ? "circle" : "checkmark.circle") {
                    model.toggleStep(step)
                }
                if task.whoKind != .me {   // the step's own who menu's words (Give to <Bot> / Take It Myself)
                    if step.who == "bot" {
                        Button("Take It Myself", systemImage: "person") { model.setStepWho(step, "me") }
                    } else {
                        Button("Give to \(model.botName(task.helper))", systemImage: "sparkles") { model.setStepWho(step, "bot") }
                    }
                }
                Divider()
                Button("Delete Step", systemImage: "trash", role: .destructive) { model.deleteStep(step) }
            }
        } else {
            content
        }
    }
}

extension View {
    /// A row standing on the page: no fill, no separator.
    /// A row on one of the brief's cards: the card's fill in the iOS look (the list rounds the section's ends), the
    /// look's own outlined section in the Desktop Look.
    func todoCardRow() -> some View { modifier(TodoCardRow()) }

    func todoBareRow(top: CGFloat, bottom: CGFloat) -> some View {
        self
            .hqDesktopBareRow()
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden, edges: .all)
            .listRowInsets(EdgeInsets(top: top, leading: 0, bottom: bottom, trailing: 0))
    }
}

private struct TodoCardRow: ViewModifier {
    @Environment(\.hqChatLead) private var chatLead
    func body(content: Content) -> some View {
        content
            .listRowBackground(Theme.isDesktop ? nil : Color(uiColor: chatLead ? TaskPanel.card : HQPalette.groupedCard))
            .listRowSeparator(.hidden, edges: .all)
            .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
    }
}

// MARK: - Choose Date…

enum TodoDatePicker {
    /// `rings`: this phone alerts at the due time (your own task, or one you share with a bot).
    static func make(date: Date?, hasTime: Bool, rings: Bool = true, done: @escaping (Date, Bool) -> Void) -> UINavigationController {
        let model = TodoDateModel(date: date ?? Date(), hasTime: hasTime)
        model.rings = rings
        let host = TodoDateHost(model: model, done: done)
        let nav = ChatSheet.wrap(host, title: "Due", detents: [.large()])
        let set = UIBarButtonItem(title: "Set", primaryAction: UIAction { [weak host] _ in host?.set() })
        set.style = .prominent
        set.accessibilityIdentifier = "task.due.set"
        host.navigationItem.rightBarButtonItem = set
        #if targetEnvironment(macCatalyst)
        // [mac] Mac polish #42: the frame's bold Done stood at the trailing edge, where a Mac keeps its default button,
        // and closed without saving. As New Task: Cancel leading, Set trailing, ⌘Return sets.
        let cancel = UIBarButtonItem.hqClose(.cancel, action: UIAction { [weak host] _ in host?.dismiss(animated: true) })
        cancel.accessibilityIdentifier = "sheet.close"
        host.navigationItem.hqPlaceFormClose(cancel)
        #endif
        return nav
    }
}

final class TodoDateHost: UIHostingController<HQScaledRoot<TodoDateView>> {
    let model: TodoDateModel
    private let done: (Date, Bool) -> Void

    init(model: TodoDateModel, done: @escaping (Date, Bool) -> Void) {
        self.model = model
        self.done = done
        super.init(rootView: HQScaledRoot(TodoDateView(model: model)))
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func set() {
        done(model.date, model.hasTime)
        dismiss(animated: true)
    }

    override var keyCommands: [UIKeyCommand]? { (super.keyCommands ?? []) + (DeviceWord.isMac ? [.save("Set", #selector(setFromKeyboard))] : []) }
    override var canBecomeFirstResponder: Bool { DeviceWord.isMac }
    @objc private func setFromKeyboard() { set() }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // [mac] Mac polish #42: no field takes the keyboard here, so the page does, and ⌘Return reaches it.
        if DeviceWord.isMac { becomeFirstResponder() }
    }
}

@MainActor @Observable
final class TodoDateModel {
    var date: Date
    var hasTime: Bool
    var rings = true
    init(date: Date, hasTime: Bool) { self.date = date; self.hasTime = hasTime }
}

struct TodoDateView: View {
    @Bindable var model: TodoDateModel
    var body: some View {
        Form {
            Section {
                DatePicker("Day", selection: $model.date, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .tint(Color.hqTint)
                Toggle("Time", isOn: Binding(get: { model.hasTime }, set: { PagesHaptics.selection(); model.hasTime = $0 }))
                    .tint(Color.hqTint)
                if model.hasTime {
                    HQDatePicker("At", selection: $model.date)
                }
            } footer: { HQSectionFooter { if model.rings { Text(TodoWords.alertNote(hasTime: model.hasTime)) } } }
            .hqSheetRows()
        }
        .hqGroupedPage()
    }
}
