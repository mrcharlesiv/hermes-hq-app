// A job's page (docs/spec/1x-pages.md §3.5): the title and status, Run Now and Pause/Resume as glass tiles, the
// last error (folded), Schedule, Delivery, the prompt (6 lines, Show All), Run History (a session run opens its chat on
// this stack, a script run its output document read-only) and Delete Job. The title moves into the bar once the
// header scrolls under it. A job that disappears pops the page with "Job Removed".

import SwiftUI
import UIKit

@MainActor @Observable
final class JobDetailModel {
    let jobKey: String
    let store: JobsStore
    @ObservationIgnored let actions: JobActions
    @ObservationIgnored weak var controller: UIViewController?
    @ObservationIgnored weak var services: PagesServices?
    @ObservationIgnored let makeChat: (any ChatSessionModel) -> UIViewController
    var runs: [CronRun] = []
    var runsLoaded = false
    var runsFailed = false
    var errorOpen = false
    var promptOpen = false
    /// The last job seen (kept to draw while the store refreshes).
    var lastJob: CronJob?

    init(jobKey: String, store: JobsStore, actions: JobActions, services: PagesServices,
         makeChat: @escaping (any ChatSessionModel) -> UIViewController) {
        self.jobKey = jobKey
        self.store = store
        self.actions = actions
        self.services = services
        self.makeChat = makeChat
        lastJob = store.job(key: jobKey)
    }

    /// The gateway said the job is gone: the page shows Job Removed (when it can't pop, another page over it), not
    /// the copy it opened with.
    var removed = false

    var job: CronJob? {
        if removed { return nil }
        if let job = store.job(key: jobKey) { return job }
        return lastJob
    }

    /// The job left a list read that would show it (its bot's, or every bot's): gone, or only not listed this once.
    var leftTheList: Bool {
        guard !removed, let lastJob, store.hasList, store.job(key: jobKey) == nil, !store.deletedHere.contains(jobKey) else { return false }
        return store.scope == PagesScope.all || store.scope == lastJob.owner
    }

    /// [jobs] The `last_run_at` the newest runs read started with, and who to tell when it moves.
    @ObservationIgnored var runsReadFor: String??
    @ObservationIgnored var onLastRunChanged: (() -> Void)?

    func lastRunChanged() {
        guard let job else { return }
        if case .some(let seen) = runsReadFor, seen == job.lastRunAt { return }
        onLastRunChanged?()
    }

    func loadRuns() async {
        guard let job else { return }
        runsReadFor = .some(job.lastRunAt)
        do {
            runs = try await store.loadRuns(job)
            runsFailed = false
        } catch {
            runsFailed = !runsLoaded
        }
        runsLoaded = true
    }

    func run() { if let job, let controller { actions.runNow(job, from: controller) } }
    func togglePause() { if let job, let controller { actions.togglePause(job, from: controller) } }
    func delete() { if let job, let controller { actions.delete(job, from: controller, style: .alert) } }
    /// [jobs] Edit Job (the bar's Edit and the failed-run card, docs/spec/3x-jobs.md §6.3).
    func edit() { if let job, let controller { actions.edit(job, from: controller) } }

    func open(_ run: CronRun) {
        guard let job, let controller, let navigation = controller.navigationController, let services else { return }
        switch run.opens {
        case .chat:
            let session = SessionSummary(id: run.id, profile: run.profile ?? job.owner, title: store.title(job), preview: nil,
                                         lastActive: run.lastActive.map { Date(timeIntervalSince1970: $0) }, source: "cron",
                                         unread: false, isRunning: run.isActive)
            Haptics.play(.soft)
            let chat = makeChat(services.chat(for: session))
            chat.navigationItem.largeTitleDisplayMode = .never
            ChatViewController.push(chat, on: navigation) {}
        case .document(let stem):
            guard let home = job.hermesHome, !home.isEmpty, let client = services.gateway else { return }
            let jobDir = String(job.id)
            let path = "\(home.hasSuffix("/") ? String(home.dropLast()) : home)/cron/output/\(jobDir)/\(stem).md"
            let label = JobWords.cronRunLabel(run).title
            let owner = job.owner
            let viewer = ArtifactTextViewController(title: label, backTitle: store.title(job), markdown: true, language: nil) {
                let data = try await ArtifactFiles.download(client, path: path, profile: owner)
                guard let text = String(data: data, encoding: .utf8) else { throw PagesMessageError("This file isn’t plain text.") }
                return ArtifactFiles.runDocumentFirst(text)
            }
            // A document that can't be read here (not missing) opens in Quick Look instead (§5.6).
            if let account = services.account {
                let record = ArtifactRecord(id: path, kind: .file, value: path, href: path, label: "\(stem).md", sessionId: "",
                                            profile: owner, sessionTitle: label, timestamp: 0)
                viewer.openInQuickLook = { [weak viewer] in
                    guard let viewer else { return }
                    QuickLookPresenter.open(from: viewer) {
                        let data = try await ArtifactFiles.download(client, path: path, profile: owner)
                        let url = ArtifactFiles.previewURL(account: account, record: record)
                        try await ArtifactFiles.save(data, to: url)
                        return url
                    }
                }
            }
            // Back reads the job's name (the page's own title is empty until its header scrolls under the bar).
            controller.navigationItem.backButtonTitle = store.title(job)
            navigation.pushViewController(viewer, animated: true)
        case .nothing:
            break
        }
    }
}

final class JobDetailViewController: UIHostingController<HQScaledRoot<JobDetailView>> {
    let jobKey: String
    private let model: JobDetailModel
    private var refreshTask: Task<Void, Never>?
    private var observing = false
    // [jobs] Edit, and the run history's extra reads (docs/spec/3x-jobs.md §6.4).
    private lazy var editItem: UIBarButtonItem = {
        let item = UIBarButtonItem(title: "Edit", primaryAction: UIAction { [weak self] _ in self?.model.edit() })
        item.accessibilityIdentifier = "job.edit"
        return item
    }()
    private var sceneObservers: [NSObjectProtocol] = []
    private var seenChangeTick = 0
    private var changeTask: Task<Void, Never>?
    private var changeAgain = false
    private var readingRuns = false
    private var watchingList = false

    init(jobKey: String, store: JobsStore, actions: JobActions, services: PagesServices,
         makeChat: @escaping (any ChatSessionModel) -> UIViewController) {
        self.jobKey = jobKey
        model = JobDetailModel(jobKey: jobKey, store: store, actions: actions, services: services, makeChat: makeChat)
        super.init(rootView: HQScaledRoot(JobDetailView(model: model, titleUnderBar: { _ in })))
        model.controller = self
        rootView = HQScaledRoot(JobDetailView(model: model) { [weak self] under in
            guard let self else { return }
            let title = under ? (self.model.job.map(self.model.store.title) ?? "") : ""
            if self.navigationItem.title != title { self.navigationItem.title = title }
        })
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.title = ""
        navigationItem.rightBarButtonItem = editItem
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = HQPalette.groupedPage
        view.accessibilityIdentifier = "job.detail"
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !observing { observing = true; model.store.noteAppear() }
        editItem.isEnabled = !model.store.readOnlyGateway
        startRefreshing()
        watchChanges()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if observing { observing = false; model.store.noteDisappear() }
        refreshTask?.cancel()
        refreshTask = nil
        sceneObservers.forEach(NotificationCenter.default.removeObserver)
        sceneObservers = []
        changeTask?.cancel()
        changeTask = nil
        changeAgain = false
        readingRuns = false
    }

    /// [jobs] The run history is read again when the gateway says a job changed and when the app comes back to the
    /// front; nothing is read while the app is in the background or the page is not showing. Every read goes through
    /// `JobsStore.loadRuns` (`SharedReads`), so triggers that land together make one request.
    private func watchChanges() {
        seenChangeTick = model.store.changeTick
        model.onLastRunChanged = { [weak self] in
            guard let self, self.observing, self.refreshTask != nil else { return }
            self.readAfterChange()
        }
        observeChangeTick()
        if !watchingList { observeList() }
        guard sceneObservers.isEmpty else { return }
        let center = NotificationCenter.default
        sceneObservers = [
            center.addObserver(forName: UIScene.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshTask?.cancel()
                    self?.refreshTask = nil
                }
            },
            center.addObserver(forName: UIScene.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.observing else { return }
                    self.startRefreshing()
                }
            },
        ]
    }

    /// Audit 863 (08c-11): a job that a list read no longer has (deleted elsewhere) is asked after at once, not at the
    /// next 60 s check; gone, the page pops with "Job Removed".
    private func observeList() {
        watchingList = true
        withObservationTracking {
            _ = model.store.listReads
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard self.observing else { self.watchingList = false; return }
                if self.model.leftTheList, let job = self.model.lastJob {
                    if case .some(.none) = await self.model.store.reload(job) { self.jobRemoved() }
                }
                if self.observing { self.observeList() } else { self.watchingList = false }
            }
        }
    }

    private func observeChangeTick() {
        withObservationTracking {
            _ = model.store.changeTick
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.observing else { return }
                let tick = self.model.store.changeTick
                if tick != self.seenChangeTick, self.refreshTask != nil {
                    self.seenChangeTick = tick
                    self.readAfterChange()
                }
                self.observeChangeTick()
            }
        }
    }

    /// One read per burst of change events: the job first (so a new `last_run_at` lands with this read, not after
    /// it), then its runs. Events that arrive meanwhile make one more round, never one each.
    private func readAfterChange() {
        if changeTask != nil {
            // A round that has not started its runs read yet covers this event too.
            if readingRuns { changeAgain = true }
            return
        }
        changeTask = Task { [weak self] in
            repeat {
                guard let self, self.observing, let job = self.model.job else { break }
                self.changeAgain = false
                self.readingRuns = false
                try? await Task.sleep(for: .milliseconds(150))
                if Task.isCancelled { break }
                if case .some(.none) = await self.model.store.reload(job) { break }
                self.readingRuns = true
                await self.model.loadRuns()
            } while self?.changeAgain == true && !Task.isCancelled
            self?.readingRuns = false
            self?.changeTask = nil
        }
    }

    /// Runs on open, then every 60 s (8 s without change events) while shown; the job itself again each time. A job
    /// the gateway no longer has pops the page.
    private func startRefreshing() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let job = self.model.job {
                    if case .some(.none) = await self.model.store.reload(job) {
                        self.jobRemoved()
                        return
                    }
                    await self.model.loadRuns()
                }
                let gap: Duration = self.model.store.changeEvents ? .seconds(60) : .seconds(8)
                await PowerPolls.wait(gap, floor: .zero)                  // [offline] §6.9
            }
        }
    }

    private func jobRemoved() {
        model.removed = true
        guard let navigation = navigationController, navigation.topViewController === self else { return }
        // [m9/ipad] In two panes this page is the right pane's first screen: the pane empties instead of a pop.
        let root = MainTabController.current
        let host: UIViewController? = root?.split ?? navigation.viewControllers.first
        if let root { root.leave(self, animated: true) } else { navigation.popViewController(animated: true) }
        if let host, host !== self { PagesHUD.show("Job Removed", symbol: "trash", from: host) }
    }
}

struct JobDetailView: View {
    @Bindable var model: JobDetailModel
    var titleUnderBar: (Bool) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if let job = model.job {
                content(job)
            } else {
                ContentUnavailableView {
                    UnavailableTitle("Job Removed", systemImage: "trash")   // [mac] Stress test 2026-10-28 #52
                } description: {
                    Text("This job is no longer on your gateway.").hqMacFont(MacType.emptyBodyFont)
                }
                .hqMacEmptyPlacement()
            }
        }
    }

    private func content(_ job: CronJob) -> some View {
        let store = model.store
        let title = store.title(job)
        let busy = store.isBusy(job)
        let paused = JobActions.isPaused(job)
        let state = JobWords.jobState(job)
        return List {
            Section {
                // [desktoplook] The title, tiles and error card stand on the page: no outline round them (it boxed the
                // title with the tiles and cut the tiles' sides, owner 2026-10-30).
                header(job, title: title)
                    .hqDesktopBareRow()
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 6, trailing: 4))
                tiles(job, busy: busy, paused: paused)
                    .hqDesktopBareRow()
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                if let error = job.lastError, !error.isEmpty {
                    errorCard(error, busy: busy)
                        .hqDesktopBareRow()
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                }
            }
            .listSectionSeparator(.hidden)

            Section {
                LabeledContent("Repeats", value: JobWords.scheduleWords(job))
                // Verify round 3: only when there is a next run (or a pause) to say: an active job without
                // `next_run_at` drew an empty row (a List gives even an empty TimelineView a row).
                if state != "completed" && state != "disabled" && (paused || !(job.nextRunAt ?? "").isEmpty) {
                    TimelineView(.everyMinute) { context in
                        if paused {
                            LabeledContent("Next Run", value: "Paused")
                        } else if JobWords.nextRunOverdue(job, now: context.date) != nil {
                            LabeledContent("Overdue Since", value: JobWords.relativeDateTime(job.nextRunAt, now: context.date))
                        } else if let next = job.nextRunAt, !next.isEmpty {
                            LabeledContent("Next Run", value: JobWords.relativeDateTime(next, now: context.date))
                        }
                    }
                }
                if let last = job.lastRunAt, !last.isEmpty {
                    let failed = !(job.lastError ?? "").isEmpty || ["error", "failed", "fail"].contains((job.lastStatus ?? "").lowercased())
                    LabeledContent("Last Run", value: "\(JobWords.relativeDateTime(last)) · \(failed ? "Failed" : "OK")")
                }
            } header: { HQSectionLabel { Text("Schedule") } }

            // UX study #90: no "Delivery" header over its one "Delivers To" row; the model, not a schedule fact, sits
            // with it.
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Delivers To").foregroundStyle(Color.hqLabel)
                    // [jobs] D-J8: the same words as the editor's row ("Run History Only").
                    Text(JobWords.humanDeliver(job.deliver ?? "", origin: job.origin, labels: JobDelivery.labels,
                                               names: JobWords.knownChatNames(store.jobs)))
                        .accessibilityIdentifier("job.delivers")
                        .font(Font.hq(.subheadline))
                        .foregroundStyle(Color.hqLabel2)
                }
                .padding(.vertical, 4)
                if let model = job.model, !model.isEmpty { LabeledContent("Model", value: ModelNames.displayModelName(model, provider: job.provider ?? "")) }
            }

            promptSection(job)

            runHistory(job)

            Section {
                Button(role: .destructive) { model.delete() } label: {
                    Text("Delete Job").frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("job.delete")
            }
            .padding(.top, 8)
        }
        .hqGroupedPage()   // [desktoplook] the page follows the skin
        .listStyle(.insetGrouped)
        .hqMacReadableColumn()   // [mac-ten] the readable column, not the iPhone's page stretched across the pane
        // The title starts just under the bar (owner 2026-10-10: headers sat too low), not under a first-section gap.
        .contentMargins(.top, 8, for: .scrollContent)
        .listSectionSpacing(16)
        .refreshable {
            _ = await store.reload(job)
            await model.loadRuns()
        }
        .onChange(of: job.lastRunAt) { model.lastRunChanged() }
    }

    private func header(_ job: CronJob, title: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Font.hqSystem(.title, design: .default, weight: .bold))
                .foregroundStyle(Color.hqLabel)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("job.title")
                .onScrollVisibilityChange(threshold: 0.2) { visible in titleUnderBar(!visible) }
            let raw = JobWords.jobTitle(job)
            if raw != title {
                // Mac polish #68: a line of words in the second grey (`cardNote`), not the faintest (2.2:1 in the iOS look).
                Text(raw).font(Font.hq(.footnote)).foregroundStyle(Color(uiColor: HQPalette.cardNote)).textSelection(.enabled)
            }
            HStack(spacing: 8) {
                let status = model.store.showsRunning(job) ? "Running" : JobWords.statusWord(job)
                Text(status)
                    .font(Font.hq(.subheadline))
                    .foregroundStyle(status == "Last run failed" ? Color.hqRed : Color.hqLabel2)
                    .accessibilityIdentifier("job.status")
                if JobWords.jobIsScriptOnly(job) {
                    Text("Script")
                        .font(Font.hq(.caption).weight(.semibold))
                        .foregroundStyle(Color.hqLabel2)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Capsule().fill(Color.hqFill3))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tiles(_ job: CronJob, busy: Bool, paused: Bool) -> some View {
        // `runOut`: the busy work is a Run Now; `running` also covers a run the gateway has out, or a bot still on its output.
        let runOut = model.store.showsRunning(job)
        let running = runOut || JobWords.isRunning(job)
        return HStack(spacing: 12) {
            Button { model.run() } label: {
                tileLabel(title: "Run Now", symbol: "bolt", spinning: running)
            }
            .hqGlassButtonStyle()
            .buttonBorderShape(.roundedRectangle(radius: 18))
            // Audit 863 (08c-7): a run already out can't be run again (it ended in "already running"); a bot still on
            // the last run's output can.
            .disabled(busy || runOut || JobWords.runIsOut(job))
            .accessibilityIdentifier("job.run")
            Button { model.togglePause() } label: {
                tileLabel(title: paused ? "Resume" : "Pause", symbol: paused ? "play" : "pause", spinning: busy && !runOut)
            }
            .hqGlassButtonStyle()
            .buttonBorderShape(.roundedRectangle(radius: 18))
            .disabled(busy)
            .accessibilityIdentifier("job.pause")
        }
    }

    private func tileLabel(title: String, symbol: String, spinning: Bool) -> some View {
        VStack(spacing: 4) {
            // One slot the height of the tallest glyph (the bolt) for every icon and the spinner, so Run Now's and
            // Pause's words sit on one line (2026-10-30: the bolt pushed "Run Now" 2 pt below "Pause").
            Image(systemName: "bolt").hqSymbolFont(18, weight: .semibold, cap: 28).hidden()
                .overlay {
                    if spinning { ProgressView().controlSize(.small) }
                    else { Image(systemName: symbol).hqSymbolFont(18, weight: .semibold, cap: 28) }
                }
                .frame(minHeight: 20)
            Text(title).font(Font.hq(.footnote).weight(.semibold))
        }
        .frame(maxWidth: .infinity, minHeight: 48)
    }

    private func errorCard(_ error: String, busy: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                Haptics.play(.selection)   // a fold, as Jobs' Completed fold
                HQMotion.withAnimation(.snappy) { model.errorOpen.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("Last run failed: \(JobWords.lastErrorSummary(error))")
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.down")
                        .font(Font.hq(.footnote).weight(.semibold))
                        .rotationEffect(.degrees(model.errorOpen ? 180 : 0))
                }
                .font(Font.hq(.subheadline))
                .foregroundStyle(Color.hqRed)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("job.error")
            if model.errorOpen {
                Text(error)
                    .font(Font.hqSystem(.caption, design: .monospaced))
                    .foregroundStyle(Color.hqRed)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // [jobs] Edit Job beside Run Again (docs/spec/3x-jobs.md §6.3); stacked at accessibility sizes.
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
            layout {
                Button { model.edit() } label: {
                    Text("Edit Job").font(Font.hq(.subheadline).weight(.semibold)).frame(maxWidth: .infinity, minHeight: 28)
                }
                .hqBorderedButtonStyle()
                .accessibilityIdentifier("job.error.edit")
                Button { model.run() } label: {
                    Text("Run Again").font(Font.hq(.subheadline).weight(.semibold)).frame(maxWidth: .infinity, minHeight: 28)
                }
                .hqProminentButtonStyle()
                .accessibilityIdentifier("job.error.run")
            }
            .tint(Color.hqRed)
            .disabled(busy)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Theme.isDesktop ? DesktopRows.radius : 14, style: .continuous)
            .fill(Color.hqRed.opacity(0.1)))
    }

    @ViewBuilder
    private func promptSection(_ job: CronJob) -> some View {
        let text = JobWords.jobDescription(job)
        if !text.isEmpty {
            let scriptOnly = JobWords.jobIsScriptOnly(job) && (job.prompt ?? "").isEmpty
            Section {
                PromptBlock(text: scriptOnly ? text : PagesMarkdown.promptMarkdown(text), markdown: !scriptOnly, open: $model.promptOpen)
            } header: { HQSectionLabel { Text(scriptOnly ? "Script" : "Prompt") } }
        }
    }

    @ViewBuilder
    private func runHistory(_ job: CronJob) -> some View {
        let note = JobWords.lastRunNote(job)
        Section {
            if !model.runsLoaded {
                HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 6)
            } else if model.runs.isEmpty {
                // [mac] Stress test 2026-10-31: under "Last ran yesterday at 6:00 AM · Failed", "No saved runs yet" read as
                // the job never having run. It ran; Hermes kept nothing from it.
                Text(model.runsFailed ? "Couldn’t load the run history." : note == nil ? "No saved runs yet" : "No output saved from its runs")
                    .foregroundStyle(Color.hqLabel2)
            } else {
                ForEach(model.runs) { run in
                    let label = JobWords.cronRunLabel(run)
                    let opens = run.opens != .nothing && (run.opens == .chat || !(job.hermesHome ?? "").isEmpty)
                    Button { model.open(run) } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(label.title).foregroundStyle(Color.hqLabel)
                                if !label.detail.isEmpty {
                                    Text(label.detail).font(Font.hq(.footnote))
                                        .foregroundStyle(label.detail.hasPrefix("Failed") ? Color.hqRed : Color.hqLabel2)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            if opens { SettingsChevron() }
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!opens)
                    .accessibilityIdentifier("job.run-row.\(run.id)")
                }
            }
        } header: { HQSectionLabel {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.runs.isEmpty ? "Run History" : "Run History · \(model.runs.count)")
                if let note { Text(note).textCase(nil).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2) }
            }
        } }
    }
}

/// A prompt or script: 6 lines, then Show All in place.
private struct PromptBlock: View {
    var text: String
    var markdown: Bool
    @Binding var open: Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var width: CGFloat = 0

    var body: some View {
        let attributed = render()
        VStack(alignment: .leading, spacing: 8) {
            AttributedTextView(text: attributed, maxLines: open ? 0 : 6, identifier: "job.prompt")
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            if !open && AttributedTextView.exceeds(attributed, lines: 6, width: width) {
                Button("Show All") { Haptics.play(.selection); HQMotion.withAnimation(.snappy) { open = true } }
                    .font(Font.hq(.subheadline).weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.hqTint)
            }
        }
        .padding(.vertical, 4)
    }

    private func render() -> NSAttributedString {
        let category = UIContentSizeCategory(typeSize)
        if markdown { return PagesMarkdown.attributed(text, category: category) }
        let font = HQFont.mono(13, like: .footnote, category: category)
        return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: HQPalette.label])
    }
}
