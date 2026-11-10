// More › Webhooks (docs/spec/3x-morepages.md §13): the receiver-off card, the subscriptions with their switches, a
// webhook's page, New Webhook and the Webhook Created sheet that shows the secret once.
// Wording: `V/i18n/en.ts` webhooks with the phone rewrites of `B/fe-pages-gates.ts`, in the app's Title Case.

import Observation
import SwiftUI
import UIKit

extension MorePages {
    static func installWebhooks() {
        factories["webhooks"] = { context in WebhooksPages.list(context) }
    }
}

// MARK: - Model

@MainActor @Observable
final class WebhooksModel {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    @ObservationIgnored let context: MorePages.Context
    @ObservationIgnored let api: WebhooksAPI
    @ObservationIgnored let actions: GatewayActionsAPI
    @ObservationIgnored weak var host: UIViewController?
    @ObservationIgnored weak var front: UIViewController?
    @ObservationIgnored var onChange: (() -> Void)?

    private(set) var phase: Phase = .loading
    private(set) var receiverOn = false
    private(set) var routes: [WebhookRoute] = []
    private(set) var online: Bool
    private(set) var busy: Set<String> = []
    private(set) var enabling = false
    private(set) var restartNeeded = false
    let restart: GatewayActionRun
    var query = ""

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var linkTask: Task<Void, Never>?
    @ObservationIgnored private var firstRead = true

    init(context: MorePages.Context) {
        self.context = context
        api = WebhooksAPI(client: context.client)
        actions = GatewayActionsAPI(client: context.client)
        restart = GatewayActionRun(api: actions)
        online = context.isOnline
        restart.onFinish = { [weak self] ok in
            guard let self else { return }
            if ok { PagesHaptics.success(); self.restartNeeded = false } else { PagesHaptics.error() }   // audit 863
            self.reload()
        }
    }

    var readOnly: Bool { context.readOnly || MessagingPages.debugReadOnly }
    var canWrite: Bool { !readOnly && online }
    /// New Webhook is offered only while the receiver is on: the gateway refuses a new route otherwise.
    var canCreate: Bool { !readOnly && receiverOn && phase == .loaded }
    var shown: [WebhookRoute] { routes.filter { $0.matches(query) } }
    func route(_ name: String) -> WebhookRoute? { routes.first { $0.name == name } }
    func isBusy(_ name: String) -> Bool { busy.contains(name) }
    var showsRestartNotice: Bool { !readOnly && (restartNeeded || restart.phase != .idle) }

    func appear() {
        if linkTask == nil {
            let client = context.client
            linkTask = Task { [weak self] in
                var wasReady: Bool?
                for await state in client.connectionStates() {
                    guard let self else { return }
                    let ready = state == .ready
                    self.online = ready
                    if ready, wasReady == false { self.reload() }
                    wasReady = ready
                }
            }
        }
        reload()
    }

    func disappear() {
        linkTask?.cancel()
        linkTask = nil
    }

    func reload() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in await self?.read() }
    }

    func refresh() async {
        loadTask?.cancel()
        let task = Task { [weak self] in await self?.read() ?? () }
        loadTask = task
        await task.value
    }

    private func read() async {
        generation += 1
        let mine = generation
        do {
            let answer = try await api.list()
            guard mine == generation, !Task.isCancelled else { return }
            if firstRead { firstRead = false; MorePages.noteRead("webhooks", error: nil) }
            receiverOn = answer.enabled
            // A switch on its way keeps the value the user chose until its write answers.
            routes = answer.subscriptions.map { route in
                var route = route
                if busy.contains(route.name), let mine = routes.first(where: { $0.name == route.name }) { route.enabled = mine.enabled }
                return route
            }
            phase = .loaded
        } catch {
            guard mine == generation, !Task.isCancelled else { return }
            if firstRead, MorePages.noteRead("webhooks", error: error) {
                phase = .failed(MoreWire.olderHermes)
            } else if phase != .loaded {
                phase = .failed(PagesREST.reason(error))
            }
        }
        onChange?()
    }

    // MARK: Receiver

    func turnOn() {
        guard canWrite, !enabling else { return }
        enabling = true
        Task {
            defer { enabling = false }
            do {
                let result = try await api.enable()
                await refresh()
                // The answer says it is on even when the next read still says off (the gateway has not restarted).
                receiverOn = true
                onChange?()
                if result.showsRestartNotice {
                    restartNeeded = true
                } else if result.restartStarted, let host = front ?? host {
                    PagesHUD.show("Webhooks Are On", detail: "Your gateway is restarting.", symbol: "checkmark", from: host)
                    Task {
                        try? await Task.sleep(for: .seconds(4))
                        reload()
                    }
                }
                PagesHaptics.success()
            } catch {
                FailureAlert.present(title: "Couldn’t Turn On Webhooks", reason: PagesREST.reason(error), from: front ?? host)
            }
        }
    }

    func askRestart() {
        guard canWrite, !restart.isBusy else { return }
        let actions = actions
        GatewayRestart.confirm(from: front ?? host) { [weak self] in
            self?.restart.start { try await actions.restart() }
        }
    }

    // MARK: A webhook

    /// The switch moves at once and goes back, with an alert, when the gateway refuses.
    func setEnabled(_ name: String, _ on: Bool) {
        guard canWrite, let index = routes.firstIndex(where: { $0.name == name }), routes[index].enabled != on,
              !busy.contains(name) else { return }
        routes[index].enabled = on
        busy.insert(name)
        PagesHaptics.selection()
        Task {
            do {
                try await api.setEnabled(name, on)
                busy.remove(name)
            } catch {
                busy.remove(name)
                if let index = routes.firstIndex(where: { $0.name == name }) { routes[index].enabled = !on }
                FailureAlert.present(title: WebhookWords.toggleFailure(name, on: on), reason: PagesREST.reason(error), from: front ?? host)
            }
        }
    }

    func copyURL(_ route: WebhookRoute) {
        guard !route.url.isEmpty else { return }
        UIPasteboard.general.string = route.url
        PagesHaptics.success()
        if let host = front ?? host { PagesHUD.show("Copied", symbol: "doc.on.doc", from: host) }
    }

    /// Delete asks first; `then` runs once the webhook is gone.
    func askDelete(_ route: WebhookRoute, then: (() -> Void)? = nil) {
        guard canWrite else { return }
        TextPrompt.confirm(title: "Delete Webhook?", message: "This will permanently remove \(route.name). This can’t be undone.",
                           action: "Delete", from: front ?? host) { [weak self] in self?.delete(route, then: then) }
    }

    private func delete(_ route: WebhookRoute, then: (() -> Void)?) {
        guard canWrite, !busy.contains(route.name) else { return }
        busy.insert(route.name)
        Task {
            do {
                try await api.delete(route.name)
                busy.remove(route.name)
                routes.removeAll { $0.name == route.name }
                PagesHaptics.success()
                then?()
                if let host { PagesHUD.show("Webhook Deleted", symbol: "trash", from: host) }
                reload()
            } catch {
                busy.remove(route.name)
                FailureAlert.present(title: "Couldn’t Delete “\(route.name)”", reason: PagesREST.reason(error), from: front ?? host)
            }
        }
    }
}

// MARK: - Pages

@MainActor
enum WebhooksPages {
    static func list(_ context: MorePages.Context) -> UIViewController {
        let model = WebhooksModel(context: context)
        let page = MorePageController(title: "Webhooks", identifier: "webhooks.page", WebhooksListView(model: model))
        model.host = page
        let search = MessagingPageSearch(page: "webhooks", placeholder: "Search") { [weak model] in model?.query = $0 }
        let capsule = PageBarCapsule(host: page, configuration: .init(
            page: "webhooks", search: search.controller,
            compose: .action({ [weak model] in if let model { newWebhook(model) } }),
            composeLabel: "New Webhook", composeSymbol: "plus"))
        capsule.install()
        search.capsule = capsule
        capsule.composeItem?.isHidden = true
        capsule.searchItem?.isHidden = true
        model.onChange = { [weak model, weak capsule] in
            // "+" shows only when a webhook can be made: a writable gateway with the receiver on.
            capsule?.composeItem?.isHidden = !(model?.canCreate ?? false)
            // Search shows when there is something to search.
            capsule?.searchItem?.isHidden = (model?.routes.isEmpty ?? true)
        }
        page.retained = [model, search, capsule]
        page.onAppear = { [weak model] in model?.front = nil; model?.appear() }
        page.onDisappear = { [weak model, weak page] in
            if page?.navigationController == nil { model?.disappear() }
        }
        return page
    }

    static func open(_ route: WebhookRoute, model: WebhooksModel) {
        guard let navigation = model.host?.navigationController else { return }
        let page = MorePageController(title: route.name, identifier: "webhooks.detail.page", WebhookDetailView(model: model, name: route.name))
        page.onAppear = { [weak model, weak page] in model?.front = page }
        navigation.pushViewController(page, animated: true)
    }

    static func newWebhook(_ model: WebhooksModel) {
        guard model.canCreate, let host = model.front ?? model.host else { return }
        let sheet = UINavigationController()
        let form = MorePageController(title: "New Webhook", identifier: "webhooks.new.sheet", WebhookFormView(
            model: model,
            cancel: { [weak sheet] in sheet?.dismiss(animated: true) },
            created: { [weak sheet, weak model] created in
                guard let sheet else { return }
                // The secret lives in this page alone; the sheet can no longer be swiped away by accident.
                sheet.isModalInPresentation = true
                let page = MorePageController(title: "Webhook Created", identifier: "webhooks.created.sheet",
                                              WebhookCreatedView(created: created) { [weak sheet] in sheet?.dismiss(animated: true) })
                page.navigationItem.hidesBackButton = true
                sheet.setViewControllers([page], animated: true)
                model?.reload()
            }))
        sheet.setViewControllers([form], animated: false)
        SheetStyle.apply(sheet, from: host)   // UX study #161: a form sheet in two panes
        if let presentation = sheet.sheetPresentationController {
            presentation.detents = [.large()]
            presentation.prefersGrabberVisible = false
            presentation.hqOpaqueGroupedPage()   // solid-ok: a long form at full height only
        }
        host.present(sheet, animated: true)
    }
}

// MARK: - List

struct WebhooksListView: View {
    let model: WebhooksModel
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        switch model.phase {
        case .loading:
            MoreSkeleton(label: "Loading webhooks…") { model.reload() }
        case .failed(let reason):
            MoreErrorState(title: "Couldn’t Load Webhooks", reason: reason) { model.reload() }
        case .loaded:
            if model.receiverOn, model.routes.isEmpty, !model.showsRestartNotice {
                MoreEmptyState(symbol: "arrow.triangle.turn.up.right.diamond", title: "No Webhooks Yet",
                               text: "A webhook lets another service start a bot.") {
                    if model.canCreate {
                        Button("New Webhook…") { WebhooksPages.newWebhook(model) }
                            .hqEmptyActionButtonStyle(glass: true)   // [mac] Stress test 2026-10-28 #55 (round 6)
                            .buttonBorderShape(.capsule)
                            .disabled(!model.online)
                            .accessibilityIdentifier("webhooks.empty.new")
                    }
                }
            } else {
                list
            }
        }
    }

    private var list: some View {
        let rows = model.shown
        return List { Group {
            if !model.receiverOn {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label {
                            Text("Webhook Receiver Is Off").font(Font.hq(.headline)).foregroundStyle(Color.hqLabel)
                        } icon: {
                            Image(systemName: "bolt.slash.fill").foregroundStyle(Color.hqOrange)
                        }
                        Text("Turn it on to let other services send events to your bots.")
                            .font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("webhooks.receiver-off")
                    if !model.readOnly {
                        Button(model.enabling ? "Turning On…" : "Turn On Webhooks") { model.turnOn() }
                            .fontWeight(.semibold)
                            .disabled(!model.canWrite || model.enabling)
                            .accessibilityIdentifier("webhooks.turn-on")
                    }
                } footer: { HQSectionFooter {
                    if !model.online, !model.readOnly { Text(MorePages.offlineFooter) }
                } }
            }
            if model.showsRestartNotice {
                if case .finished(ok: true, _) = model.restart.phase, !model.restartNeeded {
                    Section { GatewayRestartProgress(run: model.restart).padding(.vertical, 6) }
                } else {
                    GatewayRestartNotice(text: "Webhooks are enabled, but the gateway still needs a restart before the receiver can come online.",
                                         run: model.restart, canWrite: model.canWrite) { model.askRestart() }
                }
            }
            if model.receiverOn, model.routes.isEmpty {
                // Under the restart notice: the page still says there is nothing here yet.
                Section {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("No Webhooks Yet").foregroundStyle(Color.hqLabel)
                        Text("A webhook lets another service start a bot.").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                }
            }
            if !model.routes.isEmpty {
                if rows.isEmpty {
                    Section {
                        ContentUnavailableView.search(text: model.query).frame(minHeight: 280).listRowBackground(Color.clear)
                    }
                } else {
                    Section {
                        ForEach(rows) { route in row(route) }
                    } header: { HQSectionLabel {
                        // The count beside the name in grey, as Jobs' section headers show theirs. One Text, so at the
                        // large sizes the count follows the word (UX study #167); the page's own word, not a second
                        // name for the same thing (#105).
                        Text("Webhooks \(Text("\(model.routes.count)").monospacedDigit().foregroundStyle(Color.hqLabel2))")
                    } } footer: { HQSectionFooter {
                        Text(!model.online && !model.readOnly ? MorePages.offlineFooter
                             : "Changes take effect right away once the receiver is running. A webhook that is off rejects incoming events.")
                    } }
                }
            }
        }.hqMacSettingsRowInsets() }
        .settingsList()
        .refreshable { await model.refresh() }
        .accessibilityIdentifier("webhooks.list")
    }

    private func row(_ route: WebhookRoute) -> some View {
        // At the accessibility sizes the switch goes under the words, which keep the card's width and every line
        // (UX study #97: beside the chevron and switch they were cut to "push, pull_req…"); the chevron stays at the top.
        let large = typeSize.isAccessibilitySize
        let layout = large ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Button { WebhooksPages.open(route, model: model) } label: {
                HStack(alignment: large ? .top : .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(route.name).font(Font.hq(.body)).foregroundStyle(Color.hqLabel).fixedSize(horizontal: false, vertical: true)
                        Text(route.summary).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).lineLimit(large ? nil : 2)
                            .multilineTextAlignment(.leading)
                            .accessibilityLabel(route.spokenSummary)
                        if !route.description.isEmpty {
                            Text(route.description).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2).lineLimit(large ? nil : 2)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    Spacer(minLength: 4)
                    // The text opens the webhook's page; the switch beside it only turns it on or off.
                    SettingsChevron()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens the webhook")
            .accessibilityIdentifier("webhooks.row.\(route.name)")
            if model.readOnly {
                Text(route.enabled ? "On" : "Off").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
            } else {
                Toggle(route.name, isOn: Binding(get: { route.enabled }, set: { model.setEnabled(route.name, $0) }))
                    .labelsHidden()
                    .disabled(!model.canWrite || model.isBusy(route.name))
                    .accessibilityLabel(route.name)
                    .accessibilityIdentifier("webhooks.switch.\(route.name)")
            }
        }
        .padding(.vertical, 6)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if model.canWrite {
                Button("Delete") { model.askDelete(route) }
                    .tint(.red)
                    .accessibilityIdentifier("webhooks.swipe.delete")
            }
            Button("Copy URL") { model.copyURL(route) }
                .tint(.blue)
                .accessibilityIdentifier("webhooks.swipe.copy")
        }
        .contextMenu {
            Button("Copy URL", systemImage: "doc.on.doc") { model.copyURL(route) }
            if model.canWrite {
                Button("Delete", systemImage: "trash", role: .destructive) { model.askDelete(route) }
            }
        }
    }
}

// MARK: - Detail

struct WebhookDetailView: View {
    let model: WebhooksModel
    let name: String

    var body: some View {
        if let route = model.route(name) {
            List { Group {
                Section {
                    if model.readOnly {
                        LabeledContent("On", value: route.enabled ? "Yes" : "No")
                    } else {
                        Toggle("On", isOn: Binding(get: { route.enabled }, set: { model.setEnabled(route.name, $0) }))
                            .disabled(!model.canWrite || model.isBusy(route.name))
                            .accessibilityIdentifier("webhooks.detail.on")
                    }
                } footer: { HQSectionFooter {
                    Text(!model.online && !model.readOnly ? MorePages.offlineFooter : "A webhook that is off rejects incoming events.")
                } }
                Section {
                    Text(route.url.isEmpty ? "Not Known" : route.url)
                        .font(Font.hq(.footnote).monospaced())
                        .foregroundStyle(Color.hqLabel)
                        .textSelection(.enabled)
                        .padding(.vertical, 6)
                        .accessibilityIdentifier("webhooks.detail.url")
                    if !route.url.isEmpty {
                        Button("Copy URL") { model.copyURL(route) }.accessibilityIdentifier("webhooks.detail.copy")
                    }
                } header: { HQSectionLabel { Text("Webhook URL") } }
                Section {
                    fact("Events", route.events.isEmpty ? "All Events" : route.events.joined(separator: ", "))
                    fact("Deliver To", WebhookDeliver.label(route.deliver))
                    if route.deliverOnly { fact("Deliver Payload Only", "Yes") }
                    if !route.skills.isEmpty { fact("Skills", route.skills.joined(separator: ", ")) }
                    fact("Secret", route.secretSet ? "Set" : "Not Set")
                    if let created = route.createdAt {
                        fact("Created", created.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                if !route.description.isEmpty {
                    Section {
                        Text(route.description).foregroundStyle(Color.hqLabel).fixedSize(horizontal: false, vertical: true).padding(.vertical, 6)
                    } header: { HQSectionLabel { Text("Description") } }
                }
                if !route.prompt.isEmpty {
                    Section {
                        Text(route.prompt).foregroundStyle(Color.hqLabel).fixedSize(horizontal: false, vertical: true).padding(.vertical, 6)
                            .textSelection(.enabled)
                    } header: { HQSectionLabel { Text("Prompt") } }
                }
                if !model.readOnly {
                    Section {
                        Button(model.isBusy(route.name) ? "Deleting…" : "Delete Webhook", role: .destructive) {
                            model.askDelete(route) {
                                guard let navigation = model.host?.navigationController, let host = model.host else { return }
                                navigation.popToViewController(host, animated: true)
                            }
                        }
                        .disabled(!model.canWrite || model.isBusy(route.name))
                        .accessibilityIdentifier("webhooks.detail.delete")
                    }
                }
            }.hqMacSettingsRowInsets() }
            .settingsList()
            .accessibilityIdentifier("webhooks.detail.list")
        } else {
            MoreEmptyState(symbol: "arrow.triangle.turn.up.right.diamond", title: "Webhook Removed",
                           text: "This webhook is no longer on your gateway.")
        }
    }

    private func fact(_ title: String, _ value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).foregroundStyle(Color.hqLabel)
                Spacer(minLength: 12)
                Text(value).foregroundStyle(Color.hqLabel2).multilineTextAlignment(.trailing)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).foregroundStyle(Color.hqLabel)
                Text(value).foregroundStyle(Color.hqLabel2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - New Webhook

struct WebhookFormView: View {
    let model: WebhooksModel
    var cancel: () -> Void
    var created: (WebhookCreated) -> Void
    @State private var form = WebhookForm()
    @State private var creating = false
    @State private var failure: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            fields.onChange(of: failure) { _, now in
                // The reason is at the top of the form: bring it into view.
                if now != nil { proxy.scrollTo("webhooks.new.failure", anchor: .top) }
            }
        }
    }

    private var fields: some View {
        Form {
            if let failure {
                Section {
                    Label {
                        Text(failure).foregroundStyle(Color.hqLabel).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.hqRed)
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("webhooks.new.failure")
                }
                .id("webhooks.new.failure")
            }
            Section {
                TextField("e.g. github-push", text: $form.name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($nameFocused)
                    .accessibilityIdentifier("webhooks.new.name")
            } header: { HQSectionLabel {
                Text("Name")
            } } footer: { HQSectionFooter {
                if !form.name.trimmingCharacters(in: .whitespaces).isEmpty, !form.nameIsValid {
                    Text("Use lowercase letters, numbers, hyphens and underscores, starting with a letter or number.")
                        .foregroundStyle(Color.hqRed)
                }
            } }
            Section {
                TextField("What this webhook does (optional)", text: $form.description, axis: .vertical)
                    .lineLimit(1...4)
                    .accessibilityIdentifier("webhooks.new.description")
            } header: { HQSectionLabel { Text("Description") } }
            Section {
                TextField("comma-separated, leave empty for all", text: $form.events)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("webhooks.new.events")
            } header: { HQSectionLabel { Text("Events") } }
            Section {
                TextField("comma-separated skill names (optional)", text: $form.skills)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("webhooks.new.skills")
            } header: { HQSectionLabel { Text("Skills") } }
            Section {
                Picker("Deliver To", selection: $form.deliver) {
                    ForEach(WebhookDeliver.options, id: \.self) { Text(WebhookDeliver.label($0)).tag($0) }
                }
                .accessibilityIdentifier("webhooks.new.deliver")
                if WebhookDeliver.isChat(form.deliver) {
                    TextField("Chat ID (optional)", text: $form.deliverChatId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("webhooks.new.chat-id")
                }
                Toggle("Deliver Payload Only", isOn: $form.deliverOnly)
                    .disabled(!form.canDeliverOnly)
                    .accessibilityIdentifier("webhooks.new.deliver-only")
            } footer: { HQSectionFooter {
                Text(form.canDeliverOnly ? "Payload only sends the event as it came, without a bot’s reply."
                     : "Payload only needs somewhere to deliver to other than Log Only.")
            } }
            Section {
                TextField("Instructions for the agent when this webhook fires (optional)", text: $form.prompt, axis: .vertical)
                    .lineLimit(3...10)
                    .accessibilityIdentifier("webhooks.new.prompt")
            } header: { HQSectionLabel { Text("Prompt") } }
        }
        .hqMacForm()   // [mac] Stress test 2026-10-28 #8, #53: the readable width, one inset, small switches
        .hqGroupedPage()
        .scrollDismissesKeyboard(.interactively)
        .disabled(creating)
        .onChange(of: form.deliver) { _, _ in if !form.canDeliverOnly { form.deliverOnly = false } }
        .onChange(of: form) { _, _ in failure = nil }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: cancel).disabled(creating).accessibilityIdentifier("webhooks.new.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(creating ? "Creating…" : "Create", action: create)
                    .keyboardShortcut(.return, modifiers: .command)   // ⌘Return, as Save in New Job
                    .fontWeight(.semibold)
                    .disabled(creating || !form.canCreate || !model.online)
                    .accessibilityIdentifier("webhooks.new.create")
            }
        }
        .onAppear { nameFocused = true }
    }

    private func create() {
        guard !creating, form.canCreate else { return }
        creating = true
        failure = nil
        let api = model.api, form = form
        Task {
            do {
                let answer = try await api.create(form)
                creating = false
                PagesHaptics.success()
                created(answer)
            } catch {
                creating = false
                failure = WebhookWords.createFailure(error)
                PagesHaptics.error()
            }
        }
    }
}

// MARK: - Webhook Created

/// The one time the secret is shown. It is held by this view only: not stored, not logged.
struct WebhookCreatedView: View {
    let created: WebhookCreated
    var done: () -> Void
    @State private var copied: String?

    var body: some View {
        List { Group {
            Section {
                Label {
                    Text("Copy the secret now. It is only shown once.").foregroundStyle(Color.hqLabel)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "key.fill").foregroundStyle(Color.hqOrange)
                }
                .padding(.vertical, 6)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("webhooks.created.hint")
            }
            if !created.url.isEmpty {
                Section {
                    Text(created.url).font(Font.hq(.footnote).monospaced()).foregroundStyle(Color.hqLabel).textSelection(.enabled)
                        .padding(.vertical, 6)
                        .accessibilityIdentifier("webhooks.created.url")
                    Button(copied == "url" ? "Copied" : "Copy") { copy(created.url, "url") }
                        .accessibilityIdentifier("webhooks.created.copy-url")
                } header: { HQSectionLabel { Text("Webhook URL") } }
            }
            Section {
                if created.secret.isEmpty {
                    Text("Your gateway didn’t send a secret for this webhook.").foregroundStyle(Color.hqLabel2).padding(.vertical, 6)
                } else {
                    Text(created.secret).font(Font.hq(.footnote).monospaced()).foregroundStyle(Color.hqLabel).textSelection(.enabled)
                        .padding(.vertical, 6)
                        .accessibilityIdentifier("webhooks.created.secret")
                    Button(copied == "secret" ? "Copied" : "Copy") { copy(created.secret, "secret") }
                        .accessibilityIdentifier("webhooks.created.copy-secret")
                }
            } header: { HQSectionLabel { Text("Secret") } }
        }.hqMacSettingsRowInsets() }
        .settingsList()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: done).keyboardShortcut(.return, modifiers: .command).fontWeight(.semibold).accessibilityIdentifier("webhooks.created.done")
            }
        }
    }

    private func copy(_ text: String, _ what: String) {
        UIPasteboard.general.string = text
        PagesHaptics.success()
        copied = what
        HQAnnounce.say("Copied")
    }
}
