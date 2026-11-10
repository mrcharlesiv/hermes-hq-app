// Pieces every gateway Settings page shares: the hosting controller, the failed-save banner (`SettingsSaveFailure`:
// the reason, Details, Copy, Try Again), the load states (`SettingsLoadError`, `GatewayWaiting`), and the value row.

import SwiftUI
import UIKit

/// A SwiftUI page on the Settings navigation stack.
final class SettingsPageController<Content: View>: UIHostingController<HQScaledRoot<Content>> {
    var onDisappear: (() -> Void)?

    init(title: String, _ content: Content) {
        super.init(rootView: HQScaledRoot(content, softEdgeOnlyScrolled: DeviceWord.isMac))
        self.title = title
        navigationItem.largeTitleDisplayMode = .never
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent || navigationController == nil { onDisappear?() }
    }
}

extension SettingsRouter {
    func push<V: View>(_ title: String, _ view: V, onDisappear: (() -> Void)? = nil) {
        let page = SettingsPageController(title: title, view)
        page.onDisappear = onDisappear
        push(page)
    }

    /// [mac] Stress test 2026-10-28 #51 (review): a chooser with many choices (a model) opened from a pop-up button. On
    /// the Mac it is a sheet over the page, with Cancel, so picking a value doesn't push a page; elsewhere a pushed page,
    /// as before. A pick closes it with `closeChooser()`.
    func openChooser<V: View>(_ title: String, _ view: V) {
        guard DeviceWord.isMac, let presenter else { push(title, view); return }
        let page = SettingsPageController(title: title, view)
        let sheet = UINavigationController(rootViewController: page)
        page.navigationItem.leftBarButtonItem = .hqClose(.cancel, action: UIAction { [weak sheet] _ in
            sheet?.dismiss(animated: true)
        })
        SheetStyle.apply(sheet, from: presenter)
        presenter.present(sheet, animated: true)
        chooserSheet = sheet
    }

    /// Closes what `openChooser` opened: the sheet on the Mac, the pushed page elsewhere.
    func closeChooser() {
        if let sheet = chooserSheet, sheet.presentingViewController != nil {
            sheet.dismiss(animated: true)
            chooserSheet = nil
        } else {
            navigation?.popViewController(animated: true)
        }
    }

    var gatewaySettings: (any GatewaySettingsServices)? { services as? GatewaySettingsServices }

    /// Several pages at once (a search result: its page, then the field's editor on top).
    func push(_ controllers: [UIViewController]) {
        guard let navigation else { return }
        for controller in controllers { controller.navigationItem.largeTitleDisplayMode = .never }
        navigation.setViewControllers(navigation.viewControllers + controllers, animated: true)
    }
}

/// "Couldn’t save your change": shown on the page of the edit, with Details, Copy and Try Again (only when the page can
/// send the change again: a Try Again that only hid the card read as a retry that never happened, UX #201).
struct SaveFailureSection: View {
    let text: String
    let detail: String?
    let retry: (() -> Void)?
    let dismiss: () -> Void
    /// The card's scroll id and accessibility identifier: a page showing two cards gives the second its own.
    var anchor = SaveFailureSection.anchor
    @State private var showDetail = false
    @State private var copied = false
    @State private var copiedTask: Task<Void, Never>?

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label("Couldn’t Save Your Change", systemImage: "exclamationmark.triangle.fill")
                    .font(Font.hq(.headline))
                    .foregroundStyle(Color.hqRed)
                Text(text)
                    .font(Font.hq(.subheadline))
                    .foregroundStyle(Color.hqLabel)
                    .fixedSize(horizontal: false, vertical: true)
                if showDetail, let detail {
                    Text(detail)
                        .font(Font.hq(.footnote).monospaced())
                        .foregroundStyle(Color.hqLabel2)
                        .textSelection(.enabled)
                }
                HStack(spacing: 18) {
                    if detail != nil, !showDetail {
                        Button("Details") { showDetail = true }
                    }
                    Button(copied ? "Copied" : "Copy") {
                        UIPasteboard.general.string = ["Couldn’t save your change", text, detail ?? ""].filter { !$0.isEmpty }
                            .joined(separator: "\n")
                        Haptics.play(.success)
                        HQAnnounce.say("Copied")
                        // "Copied" for two seconds, then "Copy" again.
                        copied = true
                        copiedTask?.cancel()
                        copiedTask = Task {
                            try? await Task.sleep(for: .seconds(2))
                            if !Task.isCancelled { copied = false }
                        }
                    }
                    Spacer()
                    Button("Dismiss", action: dismiss).foregroundStyle(Color.hqLabel2)
                    if let retry {
                        Button("Try Again", action: retry)
                            .fontWeight(.semibold)
                            .accessibilityIdentifier("\(anchor).retry")
                    }
                }
                .buttonStyle(.borderless)
                .padding(.top, 4)
            }
            .padding(.vertical, 6)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(anchor)
            .id(anchor)
        }
    }
}

extension SaveFailureSection {
    /// The card's default scroll id (`saveFailureFeedback` scrolls up to it).
    static let anchor = "settings.save-failure"
}

extension View {
    /// UX #202: the failure card is the page's first section, often above the screen on a long page by the time a save
    /// fails, so a new failure is also felt (error haptic), heard (VoiceOver) and scrolled to. On the page's List;
    /// `anchor` is the card's (see `SaveFailureSection.anchor`).
    func saveFailureFeedback(_ failure: String?, anchor: String = SaveFailureSection.anchor) -> some View {
        modifier(SaveFailureFeedback(failure: failure, anchor: anchor))
    }
}

/// Only the page on screen reacts: the failure sources are shared (a store, the keys model), and Settings stacks
/// several pages that watch the same one, so covered pages stay quiet (one haptic, one announcement, no hidden scroll).
private struct SaveFailureFeedback: ViewModifier {
    let failure: String?
    let anchor: String
    @State private var onScreen = false

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .onAppear { onScreen = true }
                .onDisappear { onScreen = false }
                .onChange(of: failure) { _, now in
                    guard let now, onScreen else { return }
                    Haptics.play(.error)
                    HQAnnounce.say("Couldn’t save your change. \(now)", priority: .high)
                    // Next turn: the card's row is in the list by then.
                    Task { @MainActor in HQMotion.withAnimation { proxy.scrollTo(anchor, anchor: .top) } }
                }
        }
    }
}

/// The store's failure as a section (nothing when there is none).
struct ConfigFailureSection: View {
    let store: GatewayConfigStore

    var body: some View {
        if let failure = store.failure {
            SaveFailureSection(text: failure.text, detail: failure.detail, retry: { store.retry() }, dismiss: { store.dismissFailure() })
        }
    }
}

/// A list that couldn't load: the reason and Try Again, in place of the rows (never a false empty state).
struct LoadFailureSection: View {
    let title: String
    let text: String
    let retry: () -> Void

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(Font.hq(.headline)).foregroundStyle(Color.hqLabel)
                Text(text).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).fixedSize(horizontal: false, vertical: true)
                Button("Try Again", action: retry)
                    .buttonStyle(.borderless)
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("settings.load-retry")
            }
            .padding(.vertical, 8)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.load-failure")
        }
    }
}

/// Rows on their way.
struct LoadingSection: View {
    var text = "Loading…"

    var body: some View {
        Section {
            HStack(spacing: 10) {
                ProgressView()
                Text(text).foregroundStyle(Color.hqLabel2)
            }
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings.loading")
        }
    }
}

/// A title and a value to read, the value in the grey every page's values use. [mac] Stress test 2026-10-31 (#85 on
/// the rest): `LabeledContent(_, value:)` drew Billing's and About's values in the system's own grey, a shade off the
/// Gateway page's beside them.
struct InfoRow: View {
    var title: String
    var value: String

    init(_ title: String, value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        LabeledContent {
            Text(value).foregroundStyle(Color.hqLabel2)
        } label: {
            Text(title).foregroundStyle(Color.hqLabel)
        }
    }
}

/// A row with a title, a value and a chevron that opens its editor. The title wraps; the value keeps one or two lines.
struct ValueRow: View {
    var title: String
    var value: String?
    var systemImage: String? = nil
    /// [mac] The row asks in a prompt (Rename) rather than opening a page: no › on the Mac, where › means a page, as the
    /// Gateway page's Name row has none (Mac polish #96).
    var opensPrompt = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                if let systemImage {
                    // [mac] Stress test 2026-10-28 #58: the icon column every Settings row uses (Mixture of Agents'
                    // wide glyph sat off it). Owner 2026-11-01: on the iPhone too, the root's tiles, not blue glyphs.
                    SettingsRowLabel(title: title, systemImage: systemImage).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(title).foregroundStyle(Color.hqLabel).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if let value, !value.isEmpty {
                    Text(value)
                        .foregroundStyle(Color.hqLabel2)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
                if !(opensPrompt && DeviceWord.isMac) { SettingsChevron() }  // [mac] Stress test 2026-10-28 #51: no › on the Mac
            }
            .contentShape(Rectangle())
        }
        .hqMacFormRowHeight()   // [mac] Stress test 2026-10-28 round 8: the form's one row height (a row with a symbol was taller)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// [mac] Stress test 2026-10-28 #51 (review): a value picked from a long chooser (a model). On the Mac a form row whose
/// pop-up button opens the chooser (`SettingsRouter.openChooser`, a sheet); elsewhere the value row that pushes it.
struct ChooserRow: View {
    var title: String
    var value: String?
    /// [mac] The card's only control: its pop-up at the row's end, as Name's value and Bot Info's pop-ups are, not alone
    /// in the form's control column mid-row (Mac polish #92). A card of several keeps the column.
    var alone = false
    var action: () -> Void

    var body: some View {
        if DeviceWord.isMac {
            MacFormRow(label: title, trailing: alone) {
                MacChooserButton(label: title, value: value.flatMap { $0.isEmpty ? nil : $0 } ?? ConfigUnits.none, action: action)
            }
        } else {
            ValueRow(title: title, value: value, action: action)
        }
    }
}

/// A switch with its title (and a second line when there is one).
struct SwitchRow: View {
    var title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool
    var disabled = false

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(Color.hqLabel).fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle).font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .disabled(disabled)
        .hqMacFormRowHeight(multiline: subtitle != nil)   // [mac] Stress test 2026-10-28 round 8: the form's one row height
    }
}

extension View {
    /// The page sheet's look: inset grouped, plain language rows.
    /// [mac] Stress test 2026-10-28 #8, #51: a Mac form on the Mac (`hqMacForm`, inside the grouped page so its gap wins).
    func settingsList() -> some View { listStyle(.insetGrouped).hqMacForm().hqGroupedPage() }   // [desktoplook] the page follows the skin
}
