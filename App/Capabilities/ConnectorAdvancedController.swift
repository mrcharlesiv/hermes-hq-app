// Connector › Advanced (docs/spec/3x-capabilities.md §5.3, §6, §7): the connector's configuration read-only with every
// credential hidden, its masked logs, and Remove. The raw entry never reaches the pasteboard, a log or an
// accessibility value; only masked text is ever put in view state.

import SwiftUI
import UIKit

final class ConnectorAdvancedController: UIHostingController<HQScaledRoot<ConnectorAdvancedView>> {
    init(page: ConnectorPageModel, router: SettingsRouter) {
        super.init(rootView: HQScaledRoot(ConnectorAdvancedView(page: page, router: router)))
        title = "Advanced"
        navigationItem.largeTitleDisplayMode = .never
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

struct ConnectorAdvancedView: View {
    @Bindable var page: ConnectorPageModel
    let router: SettingsRouter
    enum Config: Equatable { case loading, shown(String), missing, failed }
    @State private var config = Config.loading
    /// The configuration is wider than its row: it keeps the scroll bar's lane under its last line (owner 2026-10-29).
    @State private var configScrolls = false

    var body: some View {
        List {
            Section {
                switch config {
                case .loading:
                    VStack(alignment: .leading, spacing: 8) { SkeletonLine(); SkeletonLine() }
                case .shown(let text):
                    ScrollView(.horizontal) {
                        Text(text).font(Font.hq(.footnote).monospaced()).foregroundStyle(Color.hqLabel).textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: true)
                            .padding(.top, 6)
                            .padding(.bottom, configScrolls ? max(6, ScrollBarLane.height) : 6)
                    }
                    .onScrollGeometryChange(for: Bool.self) { $0.contentSize.width > $0.containerSize.width + 0.5 } action: { _, now in
                        configScrolls = now
                    }
                    .accessibilityIdentifier("connector-config-text")
                    .contextMenu { Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = text } }
                    Button("Copy") {
                        UIPasteboard.general.string = text
                        Haptics.play(.success)
                    }
                    .accessibilityIdentifier("connector-config-copy")
                case .missing:
                    Text("This connector is not in your gateway’s configuration."
                         + (page.server?.plugin.map { " It comes from the \($0) plugin." } ?? ""))
                        .foregroundStyle(Color.hqLabel2).padding(.vertical, 3)
                        .accessibilityIdentifier("connector-config-missing")
                case .failed:
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Couldn’t load the configuration.").foregroundStyle(Color.hqLabel2)
                        Button("Try Again") { Task { await load() } }.hqBorderedButtonStyle()
                    }
                    .padding(.vertical, 3)
                }
            } header: { HQSectionLabel {
                Text("Configuration")
            } } footer: { HQSectionFooter {
                Text("Read-only on \(DeviceWord.name), with keys, tokens and passwords hidden. Edit this connector’s configuration on \(HostWord.phrase).")
            } }
            Section {
                Button {
                    router.push(ConnectorLogsController(page: page))
                } label: {
                    HStack {
                        Text("Logs").foregroundStyle(Color.hqLabel)
                        Spacer()
                        SettingsChevron()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("connector-logs")
            }
            if !page.isPlugin, !page.readOnly, page.server != nil {
                Section {
                    Button("Remove \(page.name)", role: .destructive) {
                        TextPrompt.confirm(title: "Remove \(page.name)?", message: "\(page.bot) stops using it. Nothing else is deleted from \(HostWord.phrase).",
                                           action: "Remove", style: .actionSheet, from: router.presenter) {
                            page.remove {
                                guard let navigation = router.navigation,
                                      let list = navigation.viewControllers.last(where: { $0 is CapabilitiesViewController }) else { return }
                                navigation.popToViewController(list, animated: true)
                            }
                        }
                    }
                    .accessibilityIdentifier("connector-remove")
                }
            }
        }
        .hqGroupedPage()   // [desktoplook] the page follows the skin
        .listStyle(.insetGrouped)
        .task { await load() }
    }

    private func load() async {
        if let lost = page.lostEntry {
            config = .shown(McpEntryMask.phone.configurationText(name: page.name, entry: lost))
            return
        }
        guard let store = page.store else { config = .failed; AppLog.note("connect", "connector advanced config load has no store"); return }
        if page.isPlugin { config = .missing; return }
        do {
            // The raw entry is masked at once; only the masked text is kept.
            if let entry = try await store.mcpEntry(page.name, profile: page.profile) {
                config = .shown(McpEntryMask.phone.configurationText(name: page.name, entry: entry))
            } else {
                config = .missing
                AppLog.trace("connect", "connector advanced config \(page.name) missing from gateway config")
            }
        } catch {
            config = .failed
            AppLog.note("connect", "connector advanced config \(page.name) load failed: \(CapabilitiesStore.detail(error))")
        }
    }
}

// MARK: - Logs

@MainActor @Observable
final class ConnectorLogsModel {
    let page: ConnectorPageModel
    enum State: Equatable { case loading, lines, empty, failed, unsupported }
    var state = State.loading
    /// Masked lines only. Raw lines never reach state.
    var lines: [String] = []
    var stale = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var failures = 0

    init(page: ConnectorPageModel) { self.page = page }

    nonisolated static let marker = JSRegex(#"^=+ starting MCP server '(.+)' =+$"#)

    /// The web's rule: the lines after the last marker for this name, up to the next marker for any server. nil when
    /// the file has no marker for it.
    nonisolated static func section(_ lines: [String], name: String) -> [String]? {
        var start: Int?
        for (index, line) in lines.enumerated() {
            if let match = marker.exec(line.trimmingCharacters(in: .whitespaces)), match.groups[1] == name { start = index }
        }
        guard let start else { return nil }
        var out: [String] = []
        for line in lines[(start + 1)...] {
            if marker.test(line.trimmingCharacters(in: .whitespaces)) { break }
            out.append(line)
        }
        return out
    }

    nonisolated static func clean(_ lines: [String]) -> [String] {
        lines.suffix(500).map { line in
            let masked = McpEntryMask.phone.text(line.count > 2000 ? String(line.prefix(2000)) : line)
            return line.count > 2000 ? masked + "…" : masked
        }
    }

    func start() {
        guard task == nil, state != .unsupported else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if Self.onScreen { await self.tick() }
                if self.state == .unsupported { break }
                try? await Task.sleep(for: .seconds(self.failures >= 5 ? 10 : 2))
            }
        }
    }

    func stop() { task?.cancel(); task = nil }

    /// The log is read while the app is in front; [mac] on the Mac while it is in view, frontmost or not (Mac polish
    /// #84: beside another app the log stopped adding lines). Hidden or minimized it waits.
    private static var onScreen: Bool {
        #if targetEnvironment(macCatalyst)
        UIApplication.shared.applicationState != .background
        #else
        UIApplication.shared.applicationState == .active
        #endif
    }

    private func tick() async {
        guard let store = page.store else { return }
        let name = page.name, profile = page.profile
        let stdio = page.server?.command != nil || page.server?.transport == "stdio"
        do {
            var raw: [String]?
            if stdio { raw = Self.section(try await store.logs(file: "mcp", lines: 500, search: nil, profile: profile), name: name) }
            if raw == nil { raw = try await store.logs(file: "agent", lines: 300, search: name, profile: profile) }
            guard !Task.isCancelled else { return }
            let masked = Self.clean(raw ?? [])
            if masked != lines { lines = masked }
            if state != .lines, masked.isEmpty { AppLog.trace("connect", "connector logs \(name) empty") }
            state = masked.isEmpty ? .empty : .lines
            if failures > 0 { AppLog.trace("connect", "connector logs \(name) recovered after \(failures) failed poll(s)") }
            stale = false
            failures = 0
        } catch {
            guard !Task.isCancelled else { return }
            if let http = error as? HTTPError, http.status == 400 || http.status == 404 {
                if state != .unsupported { AppLog.note("connect", "connector logs \(name) unsupported by this gateway") }
                state = .unsupported
                return
            }
            failures += 1
            if lines.isEmpty { state = .failed } else { stale = true }
            if failures == 1 { AppLog.note("connect", "connector logs \(name) poll failed: \(CapabilitiesStore.detail(error))") }
        }
    }

    func retry() { failures = 0; state = .loading; stop(); start() }
    var text: String { lines.joined(separator: "\n") }
}

final class ConnectorLogsController: UIHostingController<HQScaledRoot<ConnectorLogsView>> {
    let logs: ConnectorLogsModel

    init(page: ConnectorPageModel) {
        logs = ConnectorLogsModel(page: page)
        super.init(rootView: HQScaledRoot(ConnectorLogsView(logs: logs)))
        title = "Logs"
        navigationItem.largeTitleDisplayMode = .never
        let copy = UIBarButtonItem(title: "Copy", primaryAction: UIAction { [weak self] _ in
            guard let self, !self.logs.lines.isEmpty else { return }
            UIPasteboard.general.string = self.logs.text
            Haptics.play(.success)
        })
        copy.accessibilityIdentifier = "connector-logs-copy"
        navigationItem.rightBarButtonItem = copy
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); logs.start() }
    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); logs.stop() }
}

struct ConnectorLogsView: View {
    @Bindable var logs: ConnectorLogsModel
    @State private var following = true

    var body: some View {
        Group {
            switch logs.state {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty:
                message("No output yet.")
            case .unsupported:
                message("This gateway doesn’t keep logs for connectors.")
            case .failed:
                VStack(spacing: 12) {
                    Text("Couldn’t load the logs.").foregroundStyle(Color.hqLabel2)
                    Button("Try Again") { logs.retry() }.hqBorderedButtonStyle()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .lines:
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(logs.lines.enumerated()), id: \.offset) { _, line in
                                Text(line).font(Font.hq(.caption).monospaced()).foregroundStyle(Color.hqLabel).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if logs.stale {
                                Text("Not updating. Trying again…").font(Font.hq(.caption)).foregroundStyle(Color.hqLabel2).padding(.top, 6)
                            }
                            Color.clear.frame(height: 1).id("end")
                                .onAppear { following = true }
                                .onDisappear { following = false }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("connector-logs-text")
                    }
                    .onChange(of: logs.lines) { if following { proxy.scrollTo("end", anchor: .bottom) } }
                    .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                    .overlay(alignment: .bottom) {
                        if !following {
                            Button("Latest") {
                                if HQMotion.reduced { proxy.scrollTo("end", anchor: .bottom) } else { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                            }
                                .hqGlassButtonStyle()
                                .padding(.bottom, 12)
                                .accessibilityIdentifier("connector-logs-latest")
                        }
                    }
                }
            }
        }
        .background(Color.hqGroupedPage)
    }

    private func message(_ text: String) -> some View {
        Text(text).foregroundStyle(Color.hqLabel2).multilineTextAlignment(.center).padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("connector-logs-message")
    }
}
