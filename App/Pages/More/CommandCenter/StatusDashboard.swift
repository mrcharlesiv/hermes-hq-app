// [mac-tools] Status & Maintenance on the Mac, as a dashboard across the window (owner 2026-11-09, the Tools sketch:
// "a dashboard across the window, not Settings cards in a strip"). A headline says how the gateway is, with Restart
// beside it; four tiles give the numbers; the gateway's recent log lines fill the main column and keep themselves
// fresh; the messaging apps, Hermes' update and the maintenance actions are cards down the side. Narrower than
// `StatusDashboard.wideAt` (a page open beside it) the page is the list it was. iPhone and iPad keep the list.

import SwiftUI
import UIKit

@MainActor
enum MacDash {
    /// A card's outline where the card is the page's colour (the Desktop Look, the light iOS look).
    static let edge = UIColor { traits in
        Theme.isDesktop || traits.userInterfaceStyle != .dark ? HQPalette.separator.resolvedColor(with: traits) : .clear
    }

    /// `page` is about to show beside a whole-window tool: it gets a ✕ that closes it (the tool takes the window back).
    static func closes(_ page: UIViewController) {
        #if targetEnvironment(macCatalyst)
        guard let split = MainTabController.current?.split, split.isDouble else { return }
        let close = UIBarButtonItem(image: UIImage(systemName: "xmark"), primaryAction: UIAction { _ in
            MainTabController.current?.split?.closeDetail(animated: true)
        })
        close.accessibilityLabel = "Close"
        close.accessibilityIdentifier = "dash.detail.close"
        page.navigationItem.leftBarButtonItem = close
        #endif
    }
}

/// A dashboard's card: a small grey heading (and what sits at its right), then what it holds.
struct MacDashCard<Trailing: View, Content: View>: View {
    var title: String
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(title.uppercased()).font(Font.hq(.caption).weight(.semibold)).foregroundStyle(Color.hqLabel2)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                trailing()
            }
            .frame(minHeight: 26)
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(uiColor: HQPalette.card), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(uiColor: MacDash.edge)) }
    }
}

extension MacDashCard where Trailing == EmptyView {
    init(title: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, trailing: { EmptyView() }, content: content)
    }
}

/// A dashboard's number: what it counts, the number large, a line under it.
struct MacDashTile: View {
    var title: String
    var value: String
    var dot: Color? = nil
    var note: String? = nil
    var noteColor: Color = .hqLabel2

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(Font.hq(.caption).weight(.semibold)).foregroundStyle(Color.hqLabel2)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let dot {
                    Circle().fill(dot).frame(width: 12, height: 12).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                        .accessibilityHidden(true)
                }
                Text(value).font(Font.hq(.title).weight(.semibold)).foregroundStyle(Color.hqLabel).lineLimit(1).minimumScaleFactor(0.6)
            }
            Text(note ?? " ").font(Font.hq(.footnote)).foregroundStyle(noteColor).lineLimit(1)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: HQPalette.card), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(uiColor: MacDash.edge)) }
        .accessibilityElement(children: .combine)
    }
}

/// A pop-up button's face on a dashboard: "Show  All ⌃".
struct MacDashPop: View {
    var lead: String?
    var value: String

    var body: some View {
        HStack(spacing: 6) {
            if let lead { Text(lead).foregroundStyle(Color.hqLabel2) }
            Text(value).foregroundStyle(Color.hqLabel).lineLimit(1)
            Image(systemName: "chevron.up.chevron.down").font(Font.hq(.caption2).weight(.semibold)).foregroundStyle(Color.hqLabel2)
        }
        .font(Font.hq(.subheadline))
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color(uiColor: MacPush.fill), in: RoundedRectangle(cornerRadius: MacField.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: MacField.radius, style: .continuous).strokeBorder(Color(uiColor: MacPush.stroke)))
        .contentShape(Rectangle())
    }
}

struct StatusDashboard: View {
    @Bindable var model: CommandCenterModel
    /// The gateway's recent lines, read by the dashboard itself (Recent Logs' own page has its own).
    @State private var logs: CommandCenterLogsModel
    /// The status couldn't be read: its reason stands where the headline and tiles would be.
    var failed: String?

    /// The page is drawn at 77 % on the Mac: about 740 pt of window.
    static let wideAt: CGFloat = 960

    init(model: CommandCenterModel, failed: String? = nil) {
        self.model = model
        self.failed = failed
        _logs = State(initialValue: CommandCenterLogsModel(api: model.api))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headline
                if let status = model.status { tiles(status) }
                HStack(alignment: .top, spacing: 16) {
                    logsCard
                    VStack(spacing: 16) {
                        if let status = model.status, !status.platforms.isEmpty { appsCard(status) }
                        if model.status != nil { hermesCard }
                        if !model.readOnly { maintenanceCard }
                    }
                    .frame(width: 470)
                }
            }
            .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 28)
        }
        .background(Color.hqGroupedPage)
        .refreshable { await model.refresh(); await logs.read() }
        .task {
            await logs.read()
            // A dashboard is watched, not pulled: the status and the lines are read again while it is on show.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, model.online, !model.anyActionBusy else { continue }
                await model.loadStatus()
                await logs.read()
            }
        }
        .onChange(of: model.updateRun?.end) { _, end in if end != nil { model.updateEnded() } }
        .accessibilityIdentifier("command-center.dashboard")
    }

    // MARK: The headline

    private var summary: (words: String, detail: String, color: Color, symbol: String) {
        if let failed { return ("Couldn’t Load Status", failed, .hqOrange, "exclamationmark.triangle.fill") }
        guard let status = model.status else { return ("Loading…", "", .hqLabel2, "circle.dotted") }
        if !model.online { return ("Not Connected", MorePages.offlineFooter, .hqLabel2, "wifi.slash") }
        if status.gatewayRunning == false {
            return ("Messaging Is Stopped", "Bots can’t answer in their chat apps until it runs again.", .hqRed, "xmark.octagon.fill")
        }
        let down = status.platforms.filter(\.isDown)
        if !down.isEmpty {
            let names = down.map(\.name).formatted(.list(type: .and))
            return (down.count == 1 ? "1 App Needs Attention" : "\(down.count) Apps Need Attention", "\(names) can’t connect.", .hqOrange,
                    "exclamationmark.triangle.fill")
        }
        return ("Everything Is Running", "The gateway and its messaging apps are up.", .green, "checkmark.circle.fill")
    }

    private var headline: some View {
        let summary = summary
        return HStack(alignment: .center, spacing: 14) {
            Image(systemName: summary.symbol).font(Font.hq(.largeTitle)).foregroundStyle(summary.color).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.words).font(Font.hq(.title2).weight(.bold)).foregroundStyle(Color.hqLabel)
                    .accessibilityAddTraits(.isHeader)
                if !summary.detail.isEmpty {
                    Text(summary.detail).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).lineLimit(2)
                }
                if model.statusRefreshFailed {
                    Text("Couldn’t refresh. Showing the last status.").font(Font.hq(.footnote)).foregroundStyle(Color.hqOrange)
                        .accessibilityIdentifier("command-center.refresh-failed")
                }
            }
            Spacer(minLength: 12)
            if failed != nil {
                Button("Try Again") { model.retryStatus() }.hqMacBordered().fixedSize()
                    .accessibilityIdentifier("more.page.retry")
            }
            if !model.readOnly {
                if model.restart.phase == .idle {
                    Button("Restart Gateway…") { model.askRestart() }
                        .hqMacBordered().fixedSize()
                        .disabled(!model.canStartAction)
                        .help("Restarting stops replies for a moment.")
                        .accessibilityIdentifier("command-center.restart")
                } else {
                    GatewayRestartProgress(run: model.restart)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: The tiles

    private func tiles(_ status: GatewayStatusReport) -> some View {
        let up = status.platforms.filter(\.isUp).count
        let down = status.platforms.filter(\.isDown).count
        let check = model.update
        let updateNote: (String, Color) = check.map { check in
            check.updateAvailable ? (CommandCenterSystem.updateWords(check), Color.hqTint) : (check.words, Color.hqLabel2)
        } ?? (model.updateChecked ? "Couldn’t check for updates" : "Checking for updates…", Color.hqLabel2)
        return HStack(spacing: 16) {
            MacDashTile(title: "Messaging", value: status.gatewayWords,
                        dot: status.gatewayRunning.map { $0 ? .green : Color.hqRed }, note: "The gateway’s chat-app service")
                .accessibilityIdentifier("command-center.gateway")
            MacDashTile(title: "Hermes", value: status.version ?? "—", note: updateNote.0, noteColor: updateNote.1)
                .accessibilityIdentifier("command-center.version")
            MacDashTile(title: "Active Sessions", value: status.sessionsWords, note: "Chats running right now")
                .accessibilityIdentifier("command-center.sessions")
            MacDashTile(title: "Messaging Apps", value: status.platforms.isEmpty ? "None" : "\(up) of \(status.platforms.count)",
                        note: status.platforms.isEmpty ? "Set up in Messaging" : down > 0 ? "\(down) with an error" : "connected",
                        noteColor: down > 0 ? .hqRed : .hqLabel2)
        }
    }

    // MARK: Recent logs

    private var logsCard: some View {
        MacDashCard(title: "Recent Logs") {
            if logs.busy { ProgressView().controlSize(.small) }
            Menu {
                Picker("Show", selection: $logs.level) {
                    ForEach(LogLevelFilter.allCases) { Text($0.title).tag($0) }
                }
            } label: { MacDashPop(lead: "Show", value: logs.level.title) }
            .buttonStyle(.plain).fixedSize()
            .accessibilityIdentifier("command-center.logs.level")
            Button("Open") { model.openLogs() }
                .hqMacBordered().fixedSize()
                .help("The last 200 lines on their own page, with Share")
                .accessibilityIdentifier("command-center.logs")
        } content: {
            Group {
                switch logs.load {
                case .loading:
                    Text("Reading the gateway’s log…").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                case .failed(let reason):
                    VStack(alignment: .leading, spacing: 8) {
                        Text(reason).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                        Button("Try Again") { logs.retry() }.hqMacBordered().fixedSize()
                    }
                case .ready where logs.lines.isEmpty:
                    Text(logs.emptyText).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                        .accessibilityIdentifier("command-center.logs.empty")
                case .ready:
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if logs.refreshFailed {
                                Text(logs.refreshFailedText).font(Font.hq(.footnote)).foregroundStyle(Color.hqOrange).padding(.bottom, 6)
                            }
                            ForEach(Array(logs.lines.prefix(120).enumerated()), id: \.offset) { index, line in
                                logLine(line).accessibilityIdentifier("command-center.logs.line.\(index)")
                            }
                        }
                        .padding(12)
                    }
                    .background(Color(uiColor: HQPalette.groupedPage).opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 560, maxHeight: 560, alignment: .topLeading)
        }
    }

    private func logLine(_ line: String) -> some View {
        let level = LogLines.level(of: line)
        return Text(line.isEmpty ? " " : line)
            .font(Font.hqSystem(.caption, design: .monospaced))
            .foregroundStyle(level == .error ? Color.hqRed : (level == .warning ? Color.hqOrange : Color.hqLabel))
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .contextMenu {
                Button {
                    UIPasteboard.general.string = line
                    PagesHaptics.success()
                } label: { Label("Copy", systemImage: "doc.on.doc") }
            }
    }

    // MARK: The side cards

    private func appsCard(_ status: GatewayStatusReport) -> some View {
        MacDashCard(title: "Messaging Apps") {
            if model.canOpenMessaging {
                Button("Messaging") { model.openMessaging() }.hqMacBordered().fixedSize()
                    .accessibilityIdentifier("command-center.messaging")
            }
        } content: {
            VStack(spacing: 0) {
                ForEach(Array(status.platforms.enumerated()), id: \.element.id) { index, platform in
                    if index > 0 { Rectangle().fill(Color(uiColor: HQPalette.separator)).frame(height: 1) }
                    let fix = (platform.isDown || !platform.isUp) && model.canOpenMessaging
                    Button { if fix { model.openMessaging() } } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 10) {
                                Text(platform.name).font(Font.hq(.body)).foregroundStyle(Color.hqLabel)
                                Spacer(minLength: 8)
                                MoreStatusLine(text: platform.words, color: platform.isUp ? .green : (platform.isDown ? Color.hqRed : Color.hqLabel2))
                                if fix { SettingsChevron() }
                            }
                            if let error = platform.error {
                                Text(error).font(Font.hq(.footnote)).foregroundStyle(Color.hqRed).fixedSize(horizontal: false, vertical: true)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .allowsHitTesting(fix)
                    .accessibilityElement(children: .combine)
                    .accessibilityHint(fix ? "Opens Messaging" : "")
                    .accessibilityIdentifier("command-center.platform.\(platform.id)")
                }
                Text("For the whole gateway, all bots together.").font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            }
        }
    }

    private var hermesCard: some View {
        let check = model.update
        let canUpdate = !model.readOnly && check?.updateAvailable == true
        let recheck = (check == nil || check?.couldNotCheck == true) && model.updateChecked
        return MacDashCard(title: "Hermes Update") {
            VStack(alignment: .leading, spacing: 8) {
                if let run = model.updateRun {
                    HermesUpdateRow(run: run).buttonStyle(.plain)
                } else {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(check.map(CommandCenterSystem.updateWords) ?? (model.updateChecked ? "Couldn’t Check" : "Checking…"))
                                .font(Font.hq(.body)).foregroundStyle(Color.hqLabel)
                            Text(model.status?.versionWords ?? "").font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("command-center.update")
                        if canUpdate {
                            Button("Update Hermes…") { model.askUpdate() }
                                .hqMacBordered().fixedSize()
                                .disabled(!model.canStartAction)
                                .accessibilityIdentifier("command-center.update.start")
                        } else if recheck {
                            Button("Check Again") { model.retryUpdateCheck() }
                                .hqMacBordered().fixedSize()
                                .disabled(!model.online)
                                .accessibilityIdentifier("command-center.update.retry")
                        }
                    }
                }
                if let check, !check.canUpdateNow || model.readOnly, check.behind != 0, let message = check.message, model.updateRun == nil {
                    Text(message).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var maintenanceCard: some View {
        MacDashCard(title: "Maintenance") {
            VStack(spacing: 0) {
                ForEach(Array(MaintenanceAction.allCases.enumerated()), id: \.element.id) { index, action in
                    if index > 0 { Rectangle().fill(Color(uiColor: HQPalette.separator)).frame(height: 1) }
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(action.title).font(Font.hq(.body)).foregroundStyle(Color.hqLabel)
                            Text(action.detail).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if model.maintenance.isBusy, model.maintenanceAction == action {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Run") { model.run(action) }
                                .hqMacBordered().fixedSize()
                                .disabled(!model.canStartMaintenance)
                                .accessibilityLabel(action.title)
                                .accessibilityIdentifier("command-center.maintenance.\(action.rawValue)")
                        }
                    }
                    .padding(.vertical, 9)
                }
                if let action = model.maintenanceAction, let words = ActionWords.maintenance(model.maintenance.phase) {
                    Rectangle().fill(Color(uiColor: HQPalette.separator)).frame(height: 1)
                    Button { model.openMaintenanceOutput() } label: {
                        HStack(spacing: 8) {
                            Image(systemName: words.isBusy ? "hourglass" : words.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(words.isBusy ? Color.hqLabel2 : words.isError ? Color.hqOrange : Color.green)
                            Text("\(action.outputTitle) Output").font(Font.hq(.body)).foregroundStyle(Color.hqTint)
                            Spacer(minLength: 8)
                            Text(words.text).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2).lineLimit(1)
                            SettingsChevron()
                        }
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("command-center.maintenance.output")
                }
                Text(model.online ? "These run on \(HostWord.phrase). Nothing is sent anywhere else." : MorePages.offlineFooter)
                    .font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            }
        }
    }
}
