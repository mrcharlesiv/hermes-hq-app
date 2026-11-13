// [tasks-first] One task (owner 2026-11-12: "every task is pure task management first, agent stuff second"; mockups 3
// and 4). Its view is `TaskPlainView` everywhere. A task of your own stands alone here (`TodoSheetHost`): the bar
// names its list, ⋯ has its rows, and there is no bot and no message box. A task with a bot on it (or a conversation it
// already had) is that chat's page with the same view pinned over it (`TaskPage`). This file holds the task's model
// (what the view's rows do), the two ways a page is made, ⋯'s rows, the note a bot made, and Choose Date….
//
// History: the owner-approved mockup 2-task (2026-11-04), the chat on the task's page (11-05), the Pinned Task brief
// with its one move (11-07), the plain organized view (11-09). The brief's cards, its one move and the stand-alone
// page's Ask bar were removed with this change; nothing drew them any more.

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
    var tucked = false { didSet { if tucked != oldValue { syncComposer(); onTuckChange?() } } }
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
            syncComposer()
            onBriefLayoutChange?()
        }
    }

    /// [tasks-first] The chat's own message box shows with the chat only. Over the task's view it stands aside (the
    /// view has a one-line message box of its own at its foot, owner 2026-11-12 mockup 4: "One-line message box … It
    /// grows into the full box when you tap it"), and while a field in the brief has the keys.
    func syncComposer(animated: Bool = true) {
        guard embedded, let composer = chat?.composer else { return }
        let hidden = !tucked || editingBrief
        composer.isUserInteractionEnabled = !hidden
        composer.accessibilityElementsHidden = hidden
        guard (composer.alpha < 0.5) != hidden else { return }
        UIView.animate(withDuration: animated && !HQMotion.reduced ? 0.2 : 0) {   // motion-ok: a fade, none under Reduce Motion
            composer.alpha = hidden ? 0 : 1
        }
    }

    /// What is waiting in the chat's own message box (words typed and not sent), for the task view's one line.
    var draft: String? {
        let words = chat?.composer.textView.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return words.isEmpty ? nil : words.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    /// The task view's one-line message box, tapped: the chat takes the screen with its own box and the keys up.
    func writeMessage() {
        PagesHaptics.selection()
        if let latest = glimpse() { seenGlimpse = latest.id }
        chat?.focusComposer()   // the field taking the keys rolls the task up to its bar (`TaskBriefHost.fieldBegan`)
    }
    /// [tasks] The task has its chat (TaskPage): read each time, so a chat its first message made counts at once.
    var hasChat: Bool { task.map { chatLink($0) != nil } ?? false }
    /// Mark Done or Delete put the task away (the sheet goes down, or the Mac's right pane empties).
    @ObservationIgnored var close: (() -> Void)?
    /// [tasks] Marked done from the page: the list offers Undo (TasksViewController).
    @ObservationIgnored var onMarkedDone: ((TodoTask) -> Void)?
    /// [tasks-first] A bot was given the task from its who row: the page opens again as the task with that bot's
    /// conversation, asking it the words (TasksViewController.openTask).
    @ObservationIgnored var onAssigned: ((String) -> Void)?
    var notice: String?
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
    /// [tasks-first] A file or photo of yours is on its way to the task (TaskFields).
    var attaching = false

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

    #if DEBUG
    /// The task opened last (`-HQPagesTaskPage`, PagesDebug).
    static weak var debugLast: TodoSheetModel?
    #endif

    var task: TodoTask? {
        if let found = store.task(taskID) { lastSeen = found; return found }
        return lastSeen
    }

    var gone: Bool { store.hasList && store.task(taskID) == nil }

    /// [tasks-first] Step 5, the Mac: the task's chat is in the pane beside this page (`chat`), not under it.
    var split = false
    /// The pane's chat, kept by the page (`chat` is weak: under the task, the chat is the page itself).
    @ObservationIgnored var keptChat: ChatViewController?
    /// The page has the task's chat at hand: under it (`embedded`) or beside it (`split`).
    var chatAtHand: Bool { embedded || split }

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

    /// A refused edit gets the error tap with its notice (the change's own tap played as it was made).
    private func patch(_ fields: [String: JSONValue]) {
        Task { if await !store.patch(taskID, fields) { PagesHaptics.error() } }
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

    /// [tasks-first] The who row's choice (owner 2026-11-12, mockup 3: "The one way a bot comes in is Assign on the who
    /// row"). A bot new to a task with no conversation yet hears about it at once: the page opens again with its chat
    /// and asks which part it should take (you and it), or asks it to start (the bot by itself), as New Task with a
    /// bot does. A task that already has its chat keeps it; that bot reads the change on its next turn.
    func assign(_ who: TodoWho, bot: String?) {
        guard let task else { return }
        let helper = who == .me ? nil : (bot ?? "default")
        guard task.whoKind != who || task.helper != helper else { return }
        PagesHaptics.selection()
        var fields: [String: JSONValue] = ["who": .string(who.rawValue), "bot": helper.map(JSONValue.string) ?? .null]
        // A bot's own task never repeats (that stays a Job); one you share can, on an add-on that keeps it.
        if who == .bot || (who == .together && !store.fieldsSupported) { fields["repeat"] = .null }
        if who == .me { fields["prep"] = .bool(false) }
        if let steps = TodoEdits.stepsForJustMe(who, steps: task.steps) { fields["steps"] = TodoWire.steps(steps) }
        let asks = helper != nil && task.helper != helper && chatLink(task) == nil
        let words = who == .together ? TodoWords.helpQuestion : TaskNow.startRequest
        Task {
            guard await store.patch(taskID, fields) else { PagesHaptics.error(); return }
            if asks { onAssigned?(words) }
        }
    }

    /// [tasks-first] The bar's title on the task's view: the list it is in.
    var listTitle: String { task.map { TodoViews.listTitle($0, sections: store.sections) } ?? "Task" }

    /// The title's menu: No List, each of your lists (a tick on where it is), to move the task. None with no lists.
    var listMenu: UIMenu? {
        guard !store.sections.isEmpty else { return nil }
        return UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            MainActor.assumeIsolated {
                guard let self, let task = self.task, !self.gone else { done([]); return }
                let known = Set(self.store.sections.map(\.id))
                let now = task.section.flatMap { known.contains($0) ? $0 : nil }
                let places: [(String?, String)] = [(nil, "No List")] + self.store.sections.map { ($0.id, $0.name) }
                done([UIMenu(title: "Move To", options: .displayInline, children: places.map { id, name in
                    UIAction(title: name, state: now == id ? .on : .off) { [weak self] _ in self?.move(to: id) }
                })])
            }
        }])
    }

    func move(to list: String?) {
        guard task?.section != list else { return }
        PagesHaptics.selection()
        Task { if await !store.move([taskID], to: list) { PagesHaptics.error() } }
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
        Task { if await !store.setStep(taskID, step: step.id, done: !step.done) { PagesHaptics.error() } }
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
            Task {
                if await self.store.delete(self.taskID) { PagesHaptics.success(); self.close?() } else { PagesHaptics.error() }
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
        guard let chat, chatAtHand else { openChat(task, question: words); return }
        Haptics.play(.light)   // as Send
        sentAnswer = (words, task.rev)
        let out = (chat.session as? LiveChatSession)?.wrapsSend?(words) ?? (text: words, display: words)
        chat.sendFromCard(out.text, display: out.display, engage: false)
        if let latest = glimpse() { seenGlimpse = latest.id }
        AppLog.note("tasks", "task answered from the page (\(words.count) chars)")
    }

    /// The task's own chat: on the task's page, the words go into it here; standing alone (no bots yet), it is
    /// pushed over this page (the sheet's own navigation, or the Mac's right pane).
    func openChat(_ task: TodoTask, question: String? = nil) {
        if let chat, chatAtHand {
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
    /// `beside`: the Mac's two panes with room for a third ([tasks-first] step 5, mockup 6-mac: "The task takes the
    /// centre … the bot's conversation is the right-hand pane"): a task with a bot is the plain task's page, and its
    /// chat goes in the window's right pane (`MacInspector.followTask`), not under the task.
    static func page(taskID: String, store: TasksStore, context: MorePages.Context, beside: Bool = false) -> UIViewController {
        let model = TodoSheetModel(taskID: taskID, store: store, context: context)
        let page: UIViewController
        if beside, TaskPage.makeBeside(model: model) != nil {
            page = TodoSheetHost(model: model)
        } else {
            page = TaskPage.make(model: model) ?? TodoSheetHost(model: model)
        }
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

    /// [tasks-first] The bar's title: the list the task is in, a menu to move it (as on a shared task's page).
    private let listTitle = ChatTitleView()

    init(model: TodoSheetModel) {
        self.model = model
        super.init(rootView: HQScaledRoot(TodoSheetView(model: model)))
        model.controller = self
        title = "Task"
        listTitle.accessibilityIdentifier = "task.list"
        navigationItem.titleView = listTitle
        watchList()
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
        #if targetEnvironment(macCatalyst)
        // [tasks-first] Step 5: the bot's conversation is the pane beside the task; ◨ closes it and brings it back,
        // as beside a chat (⌘I).
        if model.split {
            let pane = UIBarButtonItem(image: UIImage(systemName: "sidebar.trailing"), primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                MacInspector.beside(self)?.toggle()
            })
            pane.accessibilityLabel = "Conversation"
            pane.accessibilityIdentifier = "task.pane"
            navigationItem.rightBarButtonItems = [pane, more]
        }
        #endif
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The title follows the task's list and its name (a move here or on another device, a rename).
    private func watchList() {
        let words = withObservationTracking { model.listTitle } onChange: { [weak self] in
            DispatchQueue.main.async { self?.watchList() }
        }
        listTitle.title = words
        listTitle.menu = model.gone ? nil : model.listMenu
        listTitle.frame.size = listTitle.intrinsicContentSize
        if navigationItem.titleView === listTitle { navigationItem.titleView = listTitle }   // the bar measures it again
    }

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
        // [tasks-first] Who does it, Repeat and the notes have their own rows on the page (one place for each).
        if task.whoKind != .me {
            let name = model.botName(task.helper)
            details.append(UIAction(title: "\(name) Gets It Ready", image: UIImage(systemName: "sparkles"),
                                    state: task.prep ? .on : .off) { _ in model.setPrep(!task.prep) })
        }
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
            // [tasks-first] A task of your own: the same view, standing alone. Nobody to message, so no message box.
            TaskPlainView(model: model, task: task)
                .refreshable { await model.store.refresh(force: true) }
                .background(Color(uiColor: TaskPanel.fill).ignoresSafeArea())
        }
    }

    // MARK: Shared words and looks (the task's view, its bar and its History use them)

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

    /// A step longer than this many characters folds to two lines.
    static let stepFold = 70
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

// MARK: - Choose Date…

enum TodoDatePicker {
    /// `rings`: this phone alerts at the due time (your own task, or one you share with a bot).
    /// `dayOnly`: a day with no time and no alert (the day a task starts).
    static func make(date: Date?, hasTime: Bool, rings: Bool = true, dayOnly: Bool = false, done: @escaping (Date, Bool) -> Void) -> UINavigationController {
        let model = TodoDateModel(date: date ?? Date(), hasTime: hasTime && !dayOnly)
        model.rings = rings && !dayOnly
        model.dayOnly = dayOnly
        let host = TodoDateHost(model: model, done: done)
        let nav = ChatSheet.wrap(host, title: dayOnly ? "Starts" : "Due", detents: [.large()])
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
    var dayOnly = false
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
                if !model.dayOnly {
                    Toggle("Time", isOn: Binding(get: { model.hasTime }, set: { PagesHaptics.selection(); model.hasTime = $0 }))
                        .tint(Color.hqTint)
                    if model.hasTime {
                        HQDatePicker("At", selection: $model.date)
                    }
                }
            } footer: {
                HQSectionFooter {
                    if model.dayOnly {
                        Text("The task joins Today on this day and stays there until it’s due.")
                    } else if model.rings {
                        Text(TodoWords.alertNote(hasTime: model.hasTime))
                    }
                }
            }
            .hqSheetRows()
        }
        .hqGroupedPage()
    }
}
