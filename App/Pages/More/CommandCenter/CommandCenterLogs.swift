// Status & Maintenance › Recent Logs (docs/spec/3x-morepages.md §15): the gateway's last 200 log lines, newest first, in a
// monospaced list; a level menu (All / Errors / Warnings → `level=ERROR` / `level=WARNING`), pull to refresh, Share.
// Also the output page of a gateway action (Run Doctor, Update Hermes): its lines as they arrive.

import SwiftUI
import UIKit

@MainActor @Observable
final class CommandCenterLogsModel {
    enum Load: Equatable { case loading, ready, failed(String) }

    @ObservationIgnored let api: CommandCenterAPI
    /// Newest first.
    private(set) var lines: [String] = []
    private(set) var load: Load = .loading
    private(set) var refreshFailed = false
    private(set) var busy = false
    /// The level the lines on screen were read with (a failed read for another level leaves them).
    private(set) var shownLevel: LogLevelFilter = .all
    var level: LogLevelFilter = .all {
        didSet { if level != oldValue { onLevelChange?(); Task { await read() } } }
    }
    @ObservationIgnored var onLevelChange: (() -> Void)?
    /// A line was copied: the page says "Copied".
    @ObservationIgnored var onCopied: (() -> Void)?
    @ObservationIgnored private var serial = 0

    init(api: CommandCenterAPI) { self.api = api }

    func read() async {
        serial += 1
        let mine = serial, asked = level
        busy = true
        defer { if mine == serial { busy = false } }
        do {
            let answer = try await api.logs(level: asked)
            guard mine == serial else { return }
            lines = answer.reversed()
            shownLevel = asked
            load = .ready
            refreshFailed = false
        } catch {
            guard mine == serial else { return }
            if load == .ready { refreshFailed = true } else { load = .failed(PagesREST.reason(error)) }
        }
    }

    func retry() {
        if load != .ready { load = .loading }
        Task { await read() }
    }

    /// Audit 863 (08d-5): the line over lines a refresh couldn't replace, naming their level when another was picked.
    var refreshFailedText: String {
        guard shownLevel != level else { return "Couldn’t refresh. Showing the last lines." }
        return "Couldn’t load \(level.title.lowercased()). Showing \(shownLevel == .all ? "every level" : shownLevel.title.lowercased() + " only")."
    }

    /// Audit 863 (08d-11): under an empty list, that there are none (not that they haven't loaded).
    var emptyText: String {
        shownLevel == .all ? "The gateway’s log is empty." : "The gateway’s recent log has no \(shownLevel.title.lowercased())."
    }

    /// The lines as the gateway wrote them (oldest first), for Share.
    var text: String { lines.reversed().joined(separator: "\n") }
}

@MainActor
enum CommandCenterLogs {
    static func make(api: CommandCenterAPI) -> UIViewController {
        let model = CommandCenterLogsModel(api: api)
        let page = MorePageController(title: "Recent Logs", identifier: "command-center.logs.page", CommandCenterLogsView(model: model))
        let bar = LogsBar(model: model, page: page)
        page.retained = [model, bar]
        bar.install()
        model.onLevelChange = { [weak bar] in bar?.install() }
        model.onCopied = { [weak page] in if let page { PagesHUD.show("Copied", symbol: "doc.on.doc", from: page) } }
        var started = false
        page.onAppear = { [weak model] in
            guard !started else { return }
            started = true
            Task { await model?.read() }
        }
        return page
    }
}

/// The bar's level menu and Share.
@MainActor
final class LogsBar: NSObject {
    private let model: CommandCenterLogsModel
    private weak var page: UIViewController?
    private let shareItem = UIBarButtonItem()

    init(model: CommandCenterLogsModel, page: UIViewController) {
        self.model = model
        self.page = page
    }

    func install() {
        let model = model
        let menu = UIMenu(title: "Level", children: LogLevelFilter.allCases.map { level in
            UIAction(title: level.title, state: level == model.level ? .on : .off) { _ in
                PagesHaptics.selection()
                model.level = level
            }
        })
        let levelItem = UIBarButtonItem(image: UIImage(systemName: model.level == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill"),
                                        menu: menu)
        levelItem.accessibilityLabel = "Level"
        levelItem.accessibilityValue = model.level.title
        levelItem.accessibilityIdentifier = "command-center.logs.level"
        shareItem.image = UIImage(systemName: "square.and.arrow.up")
        shareItem.accessibilityLabel = "Share"
        shareItem.accessibilityIdentifier = "command-center.logs.share"
        shareItem.primaryAction = UIAction(image: shareItem.image) { [weak self] _ in self?.share() }
        page?.navigationItem.rightBarButtonItems = [shareItem, levelItem]
    }

    private func share() {
        guard let page, !model.lines.isEmpty else { return }
        ActionOutput.share(text: model.text, name: "Hermes Logs", from: page, item: shareItem)
    }
}

struct CommandCenterLogsView: View {
    @Bindable var model: CommandCenterLogsModel

    var body: some View {
        switch model.load {
        case .loading:
            MoreSkeleton(rows: 10, label: "Loading logs…") { model.retry() }
        case .failed(let reason):
            MoreErrorState(title: "Couldn’t Load Logs", reason: reason) { model.retry() }
        case .ready:
            List { Group {
                if model.refreshFailed {
                    HStack(spacing: 12) {
                        Text(model.refreshFailedText).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Try Again") { model.retry() }.hqBorderedButtonStyle()
                    }
                    .padding(.vertical, 3)
                    .listRowBackground(Color.clear)
                }
                if model.lines.isEmpty {
                    ContentUnavailableView {
                        UnavailableTitle(model.shownLevel == .all ? "No Logs" : "No \(model.shownLevel.title)", systemImage: "doc.text")   // [mac] Stress test 2026-10-28 #52
                    } description: {
                        Text(model.emptyText).hqMacFont(MacType.emptyBodyFont)
                    }
                        .padding(.vertical, 40)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .accessibilityIdentifier("command-center.logs.empty")
                } else {
                    ForEach(Array(model.lines.enumerated()), id: \.offset) { index, line in
                        LogLineRow(line: line) { model.onCopied?() }
                            .accessibilityIdentifier("command-center.logs.line.\(index)")
                    }
                }
            }.hqMacSettingsRowInsets() }
            .hqGroupedPage()   // [desktoplook] the page follows the skin
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.hqGroupedPage)
            .refreshable { await model.read() }
            .accessibilityIdentifier("command-center.logs.list")
        }
    }
}

/// One log line: monospaced, six lines at rest (a 4,000-character line would otherwise fill screens), whole on a tap.
struct LogLineRow: View {
    var line: String
    var copied: () -> Void = {}
    @State private var whole = false

    var body: some View {
        let level = LogLines.level(of: line)
        Text(line.isEmpty ? " " : line)
            .font(Font.hqSystem(.caption, design: .monospaced))
            .foregroundStyle(level == .error ? Color.hqRed : (level == .warning ? Color.hqOrange : Color.hqLabel))
            .lineLimit(whole ? nil : 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onTapGesture { if line.count > 120 { whole.toggle() } }
            // A long line is a button to VoiceOver too (UX study #170).
            .accessibilityAddTraits(line.count > 120 ? .isButton : [])
            .accessibilityHint(line.count > 120 ? (whole ? "Shows the first lines" : "Shows the whole line") : "")
            .accessibilityAction { if line.count > 120 { whole.toggle() } }
            .contextMenu {
                Button {
                    UIPasteboard.general.string = line
                    PagesHaptics.success()
                    copied()
                } label: { Label("Copy", systemImage: "doc.on.doc") }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
    }
}

// MARK: - An action's output

@MainActor
enum ActionOutput {
    /// The page with a running (or finished) action's output: a status line, then the lines.
    static func make(title: String, run: GatewayActionRun, words: @escaping @MainActor (GatewayActionRun.Phase) -> ActionWords?) -> UIViewController {
        let page = MorePageController(title: title, identifier: "action-output.page", ActionOutputView(run: run, words: words))
        let share = UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.up"))
        share.accessibilityLabel = "Share"
        share.accessibilityIdentifier = "action-output.share"
        share.primaryAction = UIAction(image: share.image) { [weak page, weak run, weak share] _ in
            guard let page, let run, !run.lines.isEmpty else { return }
            ActionOutput.share(text: run.lines.joined(separator: "\n"), name: title, from: page, item: share)
        }
        page.navigationItem.rightBarButtonItem = share
        return page
    }

    /// Shares `text` as a text file (a long log travels better as a file than as a message body).
    static func share(text: String, name: String, from page: UIViewController, item: UIBarButtonItem?) {
        Task {
            let url = await write(text: text, name: name)
            let sheet = UIActivityViewController(activityItems: [url as Any? ?? text], applicationActivities: nil)
            sheet.popoverPresentationController?.barButtonItem = item
            if item == nil { sheet.popoverPresentationController?.sourceView = page.view }
            page.present(sheet, animated: true)
        }
    }

    @concurrent
    private static func write(text: String, name: String) async -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("command-center-share", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name + ".txt")
        do { try Data(text.utf8).write(to: url, options: .atomic); return url } catch { return nil }
    }
}

struct ActionOutputView: View {
    var run: GatewayActionRun
    var words: @MainActor (GatewayActionRun.Phase) -> ActionWords?

    var body: some View {
        List { Group {
            if let words = words(run.phase) {
                Section {
                    HStack(spacing: 10) {
                        if words.isBusy {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: words.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(words.isError ? Color.hqOrange : Color.green)
                                .accessibilityHidden(true)
                        }
                        Text(words.text).foregroundStyle(Color.hqLabel).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("action-output.status")
                }
            }
            Section {
                if run.lines.isEmpty {
                    Text(run.isBusy ? "Waiting for output…" : "No output.")
                        .foregroundStyle(Color.hqLabel2)
                        .padding(.vertical, 6)
                } else {
                    Text(run.lines.suffix(400).joined(separator: "\n"))
                        .font(Font.hqSystem(.caption, design: .monospaced))
                        .foregroundStyle(Color.hqLabel)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                        .accessibilityIdentifier("action-output.lines")
                }
            } header: { HQSectionLabel {
                Text("Output")
            } }
        }.hqMacSettingsRowInsets() }
        .hqMacForm()   // [mac] Stress test 2026-10-28 #8, #53: the readable width, one inset, small switches
        .hqGroupedPage()
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("action-output.list")
    }
}
