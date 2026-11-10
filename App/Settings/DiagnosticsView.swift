// Settings › About › Diagnostics (`src/diagnostics-sheet.tsx`, docs/spec/3x-diagnostics.md §2–§4): what went wrong on
// a phone with no console, in plain words the owner can copy into a message. The web app's sections in its order and
// wording: Copy Diagnostics and Share Logs under the intro (UX study 2026-10-21 #114), then App, Gateway (with Recent
// reconnects), Startup, Stability, Field metrics from iOS (with the kept days), Recent Errors (and what earlier
// launches kept), Reports from iOS. The page and
// the copied text are built from the same rows (`DiagnosticsReport`). What is copied is redacted line by line.

import SwiftUI
import UIKit

/// Everything the page shows, collected in one go.
struct DiagnosticsSnapshot: Sendable, Equatable {
    var sections: [DiagnosticsReport.Section] = []
    var errors: [DiagnosticsReport.ErrorGroup] = []
    var earlier: [DiagnosticsReport.ErrorGroup] = []
    var reports: [DiagnosticsReport.NativeReport] = []

    var text: String { DiagnosticsReport.text(sections: sections, errors: errors, earlier: earlier, reports: reports) }

    /// What the app already holds in memory (shown at once).
    @MainActor static func live(services: any AppServices) -> DiagnosticsSnapshot {
        let timings = StartupTimings.shared
        let entries = timings.entries, marks = timings.marks
        var gateway: [DiagnosticsReport.Row] = [.init("Address", address(services.account))]
        gateway += DiagnosticsReport.socketRows(SocketStats.shared.counts)
        gateway += DiagnosticsReport.returnRows(DiagnosticsReport.appReturns(marks))
        if let probe = (services as? AppModel)?.sessionStore?.probeStats {
            gateway += DiagnosticsReport.sidebarProbeRows(probes: probe.probes, skipped: probe.skipped, full: probe.full, top: probe.top)
        }
        let uploader = LogUploader.shared
        gateway.append(.init("Logs waiting to send", ByteCountFormatter.string(fromByteCount: Int64(uploader.pendingBytes), countStyle: .file), "pendingBytes"))
        var sent = uploader.lastUploadAt.map { DiagnosticsReport.dateTime($0) } ?? "Never"
        if let status = uploader.lastStatus, status != 0 { sent += status > 0 ? " · HTTP \(status)" : " · not reached" }
        gateway.append(.init("Logs last sent", sent, "lastUploadAt"))
        let reconnects = DiagnosticsReport.RowList(title: "Recent reconnects",
                                                  rows: DiagnosticsReport.reconnectRows(DiagnosticsReport.reconnects(entries)),
                                                  empty: "None since launch")
        var snapshot = DiagnosticsSnapshot()
        snapshot.sections = [
            .init(title: "App", rows: [.init("Version", AboutView.appVersion), .init(DeviceWord.system, UIDevice.current.systemVersion),
                                       .init("Network", services.connection.isOffline ? "Offline" : "Online")]),
            .init(title: "Gateway", rows: gateway, list: reconnects),
            .init(title: "Startup", rows: DiagnosticsReport.startupRows(marks: marks, entries: entries)),
            .init(title: "Stability, this build", rows: DiagnosticsReport.stabilityRows([:])),
            .init(title: "Smoothness, this run", rows: DiagnosticsReport.smoothnessRows(Array(FrameMeter.shared.book.totals.values))),
            DiagnosticsReport.fieldSection([], build: StabilityCounts.build),
        ]
        snapshot.errors = DiagnosticsTimeline.shared.recentErrors()
        return snapshot
    }

    /// The same, with what is kept on disk filled in (two small files and UserDefaults; called off the main thread).
    nonisolated func withStored() -> DiagnosticsSnapshot {
        var copy = self
        let build = StabilityCounts.build
        var stability = StabilityCounts.values()
        for (key, value) in PushAlertDiagnostics.counts() { stability["alerts.\(key)"] = Double(value) }
        let latest = FieldHistory.latest(build: build)
        for key in ["hangCount", "peakMemoryBytes"] { if let value = latest[key] { stability[key] = value } }
        if let index = copy.sections.firstIndex(where: { $0.title == "Stability, this build" }) {
            copy.sections[index].rows = DiagnosticsReport.stabilityRows(stability)
        }
        if let index = copy.sections.firstIndex(where: { $0.title == "Field metrics, from \(DeviceWord.system)" }) {
            copy.sections[index] = DiagnosticsReport.fieldSection(DiagnosticsReport.fieldHistory(FieldHistory.saved()), build: build)
        }
        copy.earlier = DiagnosticsTimeline.shared.earlierErrors()
        copy.reports = DiagnosticsReport.nativeReports(CrashLog.saved(build: build))
        return copy
    }

    /// The signed-in gateway's host (with its port when it has one).
    static func address(_ account: GatewayAccount?) -> String {
        guard let url = account?.baseURL, let host = url.host() else { return "Unknown" }
        return url.port.map { "\(host):\($0)" } ?? host
    }
}

private extension ConnectionState {
    var isOffline: Bool { if case .offline = self { true } else { false } }
}

struct DiagnosticsView: View {
    let services: any AppServices
    let router: SettingsRouter
    @State private var snapshot = DiagnosticsSnapshot()
    @State private var copied = false
    @State private var copiedTask: Task<Void, Never>?
    /// Share Logs' frame in the window: its sheet's popover points at it on the iPad and the Mac.
    @State private var shareFrame: CGRect = .zero
    @Environment(\.scenePhase) private var scenePhase

    static let intro = "Copy this and send it with a bug report. Passwords, tokens, cookies and web-address details are removed, but error text is included, so read it before you share it."

    var body: some View {
        List { Group {
            if DeviceWord.isMac {
                // [mac] Stress test 2026-10-28 round 10: the intro and its two buttons are one row, so the buttons read as
                // part of the paragraph above them. As two rows each took the page's one row height (round 9's 59 pt),
                // which put 47 pt between the intro and the buttons and 25 between the buttons and the crash line.
                Section {
                    VStack(alignment: .leading, spacing: 18) {
                        introText
                        // [mac] Stress test 2026-10-28 #51 (review): two push buttons side by side under the intro, not
                        // two rows drawn as links.
                        HStack(spacing: 8) {
                            Button(copied ? "Copied" : "Copy Diagnostics", action: copyDiagnostics)
                                .accessibilityIdentifier("diagnostics.copy")
                            Button("Share Logs…") { LogSharing.share(from: router.navigation, anchor: shareFrame) }
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { shareFrame = $0 }
                            Spacer(minLength: 0)
                        }
                        .hqMacBordered()   // [mac] Stress test 2026-10-28 #55 (round 6): the Mac push button
                    }
                    .padding(.bottom, 5)
                    .modifier(MacPageNote())
                } footer: { HQSectionFooter {
                    Text(LogSharing.summary())
                } }
            } else {
                Section {
                    introText
                        .hqRowPadding(4)   // [ui-sizing] the Settings rows' 4, not 12 on top of the list's own (rows were ~2× as tall)
                }
                // UX study 2026-10-21 #114: the buttons the intro asks for sit right under it, not after every section.
                Section {
                    Button(action: copyDiagnostics) {
                        Label(copied ? "Copied" : "Copy Diagnostics", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .accessibilityIdentifier("diagnostics.copy")
                    Button {
                        LogSharing.share(from: router.navigation, anchor: shareFrame)
                    } label: {
                        Label("Share Logs", systemImage: "square.and.arrow.up")
                    }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { shareFrame = $0 }
                } footer: { HQSectionFooter {
                    Text(LogSharing.summary())
                } }
            }
            ForEach(Array(snapshot.sections.enumerated()), id: \.offset) { _, section in
                Section {
                    ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in valueRow(row) }
                    if let list = section.list {
                        subheader(list.title)
                        if list.rows.isEmpty { emptyRow(list.empty + ".") }
                        ForEach(Array(list.rows.enumerated()), id: \.offset) { _, row in stackedRow(top: row.value, bottom: row.label) }
                    }
                } header: { HQSectionLabel {
                    Text(section.title)
                } }
            }
            Section {
                if snapshot.errors.isEmpty { emptyRow("None since launch.") }
                ForEach(Array(snapshot.errors.enumerated()), id: \.offset) { _, group in errorRow(group) }
                if !snapshot.earlier.isEmpty {
                    subheader("Before the last launch")
                    ForEach(Array(snapshot.earlier.enumerated()), id: \.offset) { _, group in errorRow(group) }
                }
            } header: { HQSectionLabel {
                Text("Recent errors")   // as the page's other headers ("Stability, this build") and the copied report
            } }
            if !snapshot.reports.isEmpty {
                Section {
                    ForEach(Array(snapshot.reports.enumerated()), id: \.offset) { _, report in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(report.kind) · \(DiagnosticsReport.dateTime(report.at))")
                                .font(Font.hq(.subheadline).weight(.semibold)).foregroundStyle(Color.hqLabel)
                            Text(report.text.components(separatedBy: "\n").dropFirst().joined(separator: "\n"))
                                .font(Font.hq(.caption).monospaced()).foregroundStyle(Color.hqLabel2)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .hqRowPadding(4)   // [ui-sizing] the Settings rows' 4, not 12 on top of the list's own (rows were ~2× as tall)
                    }
                } header: { HQSectionLabel {
                    Text("Reports from \(DeviceWord.system)")
                } }
            }
        }.hqMacSettingsRowInsets() }
        .settingsList().hqMacSettingsRows()
        .refreshable { await collect() }
        .task { await collect() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await collect() } }
        }
        .accessibilityIdentifier("diagnostics.list")
    }

    private var introText: some View {
        Text(Self.intro)
            .font(Font.hq(.footnote))
            .foregroundStyle(Color.hqLabel2)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("diagnostics.intro")
    }

    private func copyDiagnostics() {
        UIPasteboard.general.string = snapshot.withStored().text
        Haptics.play(.success)
        HQAnnounce.say("Copied")
        copied = true
        // "Copied" for two seconds, then the button's own name again; a second tap starts the two seconds over.
        copiedTask?.cancel()
        copiedTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { copied = false }
        }
    }

    /// The in-memory sections at once; the file-backed ones a moment later, read off the main thread.
    private func collect() async {
        let live = DiagnosticsSnapshot.live(services: services)
        if snapshot.sections.isEmpty { snapshot = live }
        let full = await Task.detached(priority: .userInitiated) { live.withStored() }.value
        snapshot = full
    }

    /// A label and its value on one line; the value wraps under the label when the two do not fit.
    private func valueRow(_ row: DiagnosticsReport.Row) -> some View {
        // [mac] Stress test 2026-10-28 round 6: Title Case on the Mac, as every other Settings row there.
        let label = DeviceWord.isMac ? DiagnosticsReport.titleCase(row.label) : row.label
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).foregroundStyle(Color.hqLabel)
                Spacer(minLength: 12)
                Text(row.value).foregroundStyle(Color.hqLabel2).multilineTextAlignment(.trailing)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(label).foregroundStyle(Color.hqLabel)
                Text(row.value).foregroundStyle(Color.hqLabel2).fixedSize(horizontal: false, vertical: true)
            }
            .hqRowPadding(4)   // [ui-sizing] as the one-line rows beside it (was 8)
        }
        .accessibilityElement(children: .combine)
    }

    private func stackedRow(top: String, bottom: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(top).foregroundStyle(Color.hqLabel).fixedSize(horizontal: false, vertical: true)
            Text(bottom).font(Font.hq(.caption)).foregroundStyle(Color.hqLabel2)
        }
        .hqRowPadding(4)   // [ui-sizing] the Settings rows' 4, not 12 on top of the list's own (rows were ~2× as tall)
        .accessibilityElement(children: .combine)
    }

    private func subheader(_ title: String) -> some View {
        Text(title).font(Font.hq(.footnote).weight(.semibold)).foregroundStyle(Color.hqLabel2)
            .accessibilityAddTraits(.isHeader)
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text).foregroundStyle(Color.hqLabel2)
    }

    private func errorRow(_ group: DiagnosticsReport.ErrorGroup) -> some View {
        let meta = DiagnosticsReport.errorMeta(group)
        return VStack(alignment: .leading, spacing: 3) {
            Text(group.message)
                .font(Font.hq(.footnote).monospaced())
                .foregroundStyle(Color.hqLabel)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !meta.isEmpty { Text(meta).font(Font.hq(.caption)).foregroundStyle(Color.hqLabel2) }
        }
        .hqRowPadding(4)   // [ui-sizing] the Settings rows' 4, not 12 on top of the list's own (rows were ~2× as tall)
    }
}

/// [mac] Stress test 2026-10-28 round 6: the page's intro as plain text on the page over the buttons, with no card of
/// its own (a card holding only footnote text read as an empty card). Elsewhere the row as it was.
private struct MacPageNote: ViewModifier {
    func body(content: Content) -> some View {
        if DeviceWord.isMac {
            content
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: MacInset.side, bottom: 0, trailing: MacInset.side))
                .hqDesktopBareRow()
        } else {
            content
        }
    }
}
