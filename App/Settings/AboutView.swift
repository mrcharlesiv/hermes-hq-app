// Settings › About (spec 1x-settings §3.8, `S/about-dispatch.tsx:46-88`): this app's version, the gateway's Hermes
// version, Support, Privacy Policy (in-app Safari), the open-source licences, Diagnostics, Send Performance Logs to Your
// Computer (`perf-log.ts`, default on: it controls `LogUploader`), Detailed Logging (default on: `AppLog.trace`) and Mark a Slow Moment (the web still says "Mark a
// Janky Moment"; UX study #71 chose plain words here).

import SwiftUI
import UIKit

final class AboutController: UIHostingController<HQScaledRoot<AboutView>> {
    init(services: any AppServices, router: SettingsRouter) {
        super.init(rootView: HQScaledRoot(AboutView(services: services, router: router)))
        title = "About"
        navigationItem.largeTitleDisplayMode = .never
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

struct AboutView: View {
    let services: any AppServices
    let router: SettingsRouter
    @State private var perfLog = LogUploader.isEnabled
    @State private var detailed = AppLog.detailed
    @State private var marked = false

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        List { Group {
            Section {
                InfoRow("Version", value: Self.appVersion)
                InfoRow("Hermes on Your Gateway", value: (services as? SettingsServices)?.gatewayVersion ?? "Unavailable")
            } header: { HQSectionLabel {
                Text(AppIdentity.current.displayName)
            } } footer: { HQSectionFooter {
                Text("Your personal agent, based on Hermes Agent by Nous Research (MIT).")
            } }
            Section {
                LinkRow(title: "Support", url: URL(string: "https://gethermeshq.com/support")!)
                LinkRow(title: "Privacy Policy", url: URL(string: "https://gethermeshq.com/privacy")!)
                NavRow(title: "Open-Source Licenses") {
                    router.push("Open-Source Licenses", LicensesView(router: router))
                }
                .accessibilityIdentifier("about.licenses")
            }
            Section {
                NavRow(title: "Diagnostics") {
                    router.push("Diagnostics", DiagnosticsView(services: services, router: router))
                }
                .accessibilityIdentifier("about.diagnostics")
                Toggle(isOn: Binding(get: { perfLog }, set: { on in
                    Haptics.play(.selection)
                    perfLog = on
                    LogUploader.shared.setEnabled(on)
                    AppLog.note("settings", "performance logs \(on ? "on" : "off")")
                })) {
                    Text("Send Performance Logs to Hermes").foregroundStyle(Color.hqLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // [mac] Stress test 2026-10-28 round 8: the form's one row height (this one-line switch row was 67 pt
                // against Diagnostics' 53).
                .padding(.vertical, DeviceWord.isMac ? 0 : 4)
                .hqMacFormRowHeight()
                .accessibilityIdentifier("about.perf-log")
                // Detailed Logging writes this device's own log (Diagnostics' Share Logs), whether or not anything is sent,
                // so it is always here (it was hidden, and still on, while Send Performance Logs was off).
                Toggle(isOn: Binding(get: { detailed }, set: { on in
                    Haptics.play(.selection)
                    detailed = on
                    AppLog.setDetailed(on)
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Detailed Logging").foregroundStyle(Color.hqLabel)
                        Text("Every request, reply step and send, in this \(DeviceWord.name)’s log, so problems can be traced afterwards.")
                            .font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, DeviceWord.isMac ? 0 : 4)
                .hqMacFormRowHeight(multiline: true)   // [mac] Stress test 2026-10-28 round 8
                .accessibilityIdentifier("about.detailed-log")
                if perfLog {
                    if DeviceWord.isMac {
                        // [mac] Stress test 2026-10-28 #51 (review): a push button with its help under it, not a row
                        // drawn as a link.
                        VStack(alignment: .leading, spacing: 4) {
                            Button(marked ? "Marked" : SettingsSearch.markLabel, action: markMoment)
                                .hqMacBordered()   // [mac] Stress test 2026-10-28 #55 (round 6): the Mac push button
                                .accessibilityIdentifier("about.mark")
                                // [mac] Stress test 2026-10-28 round 9: the button's box stands into the row's room above
                                // it, as a pop-up's does on a form row, so this row is nearer a two-line row (86 pt).
                                .padding(.top, -MacForm.controlOverhang)
                            Text("Flags this moment in the log on \(HostWord.phrase).")
                                .font(MacType.footnoteFont).foregroundStyle(Color.hqLabel2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .hqRowPadding(4)   // [mac] Stress test 2026-10-28 round 9: the list's one room on the Mac
                    } else {
                        Button(action: markMoment) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(marked ? "Marked" : SettingsSearch.markLabel).foregroundStyle(Color.hqTint)
                                Text("Flags this moment in the log on \(HostWord.phrase).").font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                            }
                            .hqRowPadding(4)   // [mac] Stress test 2026-10-28 round 9: the list's one room on the Mac
                        }
                        .accessibilityIdentifier("about.mark")
                    }
                }
            } header: { HQSectionLabel {
                // Stress test 2026-10-28 round 7 (both): the header said "Diagnostics" right above the Diagnostics row.
                Text("Troubleshooting")
            } } footer: { HQSectionFooter {
                Text("Timings and connection events go only to \(HostWord.phrase), never anyone else. No message content is included.")
            } }
        }.hqMacSettingsRowInsets() }
        .hqMacForm(settings: true)   // [mac] Stress test 2026-10-28 #8, #53: the readable width, one inset, small switches
        .hqGroupedPage()   // [desktoplook] the page follows the skin
        .listStyle(.insetGrouped)
        .environment(\.openURL, LinkOpener.openURLAction)   // [links-browser]
    }

    private func markMoment() {
        AppLog.note("mark", "janky moment marked")
        LogUploader.shared.markMoment()
        Haptics.play(.success)
        marked = true
        HQAnnounce.say("Marked")   // UX study #71: the 2 s "Marked" is heard, not only seen
        Task {
            try? await Task.sleep(for: .seconds(2))
            marked = false
        }
    }
}

/// A link that opens in Safari inside the app.
struct LinkRow: View {
    var title: String
    var url: URL
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            openURL(url)
        } label: {
            HStack {
                Text(title).foregroundStyle(Color.hqLabel)
                Spacer()
                Image(systemName: "arrow.up.forward")
                    .font(Font.hq(.footnote).weight(.semibold))
                    .foregroundStyle(Color.hqLabel3)
                    .accessibilityHidden(true)
            }
            // [mac] Stress test 2026-10-28 round 7: the form's one row height on the Mac (the 4 pt made Support and
            // Privacy Policy about 52 px against Version's 45).
            .padding(.vertical, DeviceWord.isMac ? 0 : 4)
        }
        .hqMacFormRowHeight()   // [mac] Stress test 2026-10-28 round 8
        .accessibilityHint("Opens \(url.host() ?? "the page") in Safari.")
    }
}

/// Settings › About › Open-Source Licenses ([morepages] docs/spec/3x-morepages.md §7): the intro, then one row per
/// notice (name over "version · license"); a row pushes its text. The list is `licenses.json`, generated by
/// scripts/licenses.py, read when the page opens.
struct LicensesView: View {
    let router: SettingsRouter
    @State private var notices: [LicenseNotice]?
    @State private var failed = false

    static func reflow(_ text: String) -> String { LicenseNotices.reflow(text) }

    var body: some View {
        List { Group {
            Section {
                if let notices {
                    ForEach(notices) { notice in
                        Button {
                            router.push(notice.name, LicenseTextView(notice: notice))
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(notice.name).font(Font.hq(.body)).foregroundStyle(Color.hqLabel)
                                    if !notice.meta.isEmpty {
                                        Text(notice.meta).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                                    }
                                }
                                Spacer(minLength: 12)
                                SettingsChevron()  // [mac] Stress test 2026-10-28 #51: no › on the Mac
                            }
                            .hqRowPadding(4)   // [mac] Stress test 2026-10-28 round 9: the list's one room on the Mac
                            .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("license-row-\(notice.name)")
                    }
                } else if failed {
                    Text(LicenseNotices.failure).foregroundStyle(Color.hqLabel2).padding(.vertical, 12)
                        .accessibilityIdentifier("licenses.failed")
                } else {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Loading…").foregroundStyle(Color.hqLabel2)
                    }
                    .hqRowPadding(4)   // [mac] Stress test 2026-10-28 round 9: the list's one room on the Mac
                }
            } header: { HQSectionLabel {
                Text(LicenseNotices.intro)
                    .font(Font.hq(.subheadline))
                    .foregroundStyle(Color.hqLabel2)
                    .textCase(nil)
                    .padding(.bottom, 8)
                    .accessibilityIdentifier("licenses.intro")
            } }
        }.hqMacSettingsRowInsets() }
        .hqMacForm(settings: true)   // [mac] Stress test 2026-10-28 #8, #53: the readable width, one inset, small switches
        .hqGroupedPage()   // [desktoplook] the page follows the skin
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("licenses.list")
        .task {
            guard notices == nil else { return }
            if let loaded = await LicenseNotices.load() { notices = loaded } else { failed = true }
        }
    }
}

/// One notice's text, re-flowed so the system wraps it.
struct LicenseTextView: View {
    let notice: LicenseNotice
    @State private var text: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !notice.meta.isEmpty {
                    Text(notice.meta).font(Font.hq(.subheadline).weight(.semibold)).foregroundStyle(Color.hqLabel)
                }
                Text(text ?? "")
                    .font(Font.hq(.footnote))
                    .foregroundStyle(Color.hqLabel2)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("license.text")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(Color.hqGroupedPage)
        .task {
            let raw = notice.text
            text = await Task.detached { LicenseNotices.reflow(raw) }.value
        }
    }
}

/// Settings › About › Share Logs: the Logs folder (app log, crash records, iOS crash reports) as one zip.
enum LogSharing {
    static func summary() -> String {
        let records = DiagnosticLog.shared.crashRecords()
        guard let last = records.first else {
            return "The app keeps a log of what it did and any crashes, on this \(DeviceWord.name) only. No messages or passwords are in it."
        }
        let date = (try? last.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            .map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "recently"
        return "\(records.count) crash record\(records.count == 1 ? "" : "s"); latest \(date). Share them with the developer. No messages or passwords are in the log."
    }

    /// A zip still being made: a second tap waits for it rather than making another.
    @MainActor private static var making = false

    /// `anchor`: the tapped button's frame in window coordinates, where the iPad's and the Mac's popover points (the
    /// middle of the page when it isn't known; it had sat in the page's top-left corner).
    @MainActor static func share(from presenter: UIViewController?, anchor: CGRect = .zero) {
        guard let presenter, !making else { return }
        AppLog.note("screen", "share logs")
        making = true
        let folder = DiagnosticLog.shared.directory
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(AppIdentity.current.displayName) Logs \(DiagnosticLog.fileStamp(Date())).zip")
        Task { @MainActor [weak presenter] in
            // Zipped off the main thread (the folder holds a few megabytes; the app froze while it was made).
            let zip = await Task.detached(priority: .userInitiated) { () -> URL? in
                DiagnosticLog.shared.flush()
                return zipped(folder, to: out)
            }.value
            making = false
            guard let presenter, presenter.view.window != nil else { return }
            let items: [Any] = zip.map { [$0] } ?? [DiagnosticLog.shared.tail()]
            let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
            if let popover = sheet.popoverPresentationController, let view = presenter.view {
                popover.sourceView = view
                let button = anchor.isEmpty ? .null : view.convert(anchor, from: nil)
                if button.isNull || !view.bounds.intersects(button) {
                    popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
                    popover.permittedArrowDirections = []
                } else {
                    popover.sourceRect = button
                }
            }
            presenter.present(sheet, animated: true)
        }
    }

    /// The Logs folder as one zip at `out`, or nil when it couldn't be made.
    nonisolated private static func zipped(_ folder: URL, to out: URL) -> URL? {
        var zip: URL?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &error) { url in
            try? FileManager.default.removeItem(at: out)
            if (try? FileManager.default.copyItem(at: url, to: out)) != nil { zip = out }
        }
        return zip
    }
}
