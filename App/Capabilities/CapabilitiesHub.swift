// [cap-pages] More › Capabilities (owner 2026-11-03: one home per page; tabs only to flip between lists of one kind).
// Four rows, Skills, Tools, Connectors and Plugins, each opening that list as its own page (`CapabilitiesViewController`)
// with its own Bot row, search and ⋯. Settings › Bots & Tools › Capabilities opens this same page. A connector issue is
// on its row ("1 Issue", red), and the row then opens Connectors for the bot of the newest one, scrolled to it (3x §8.5).

import SwiftUI
import UIKit

final class CapabilitiesHubController: UIHostingController<HQScaledRoot<CapabilitiesHubView>> {
    /// `settingsPage`: opened under Settings, so on the Mac its rows (and its pages' rows) are Settings' rows.
    init(services: any AppServices, settingsPage: Bool = false) {
        let router = SettingsRouter(services: services, navigation: nil)
        super.init(rootView: HQScaledRoot(CapabilitiesHubView(services: services, router: router, settingsPage: settingsPage)))
        title = "Capabilities"
        navigationItem.largeTitleDisplayMode = .never
        view.accessibilityIdentifier = "capabilities.hub"
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        rootView.router.navigation = navigationController
    }
}

@MainActor enum CapabilitiesPages {
    /// The page for one list: Connectors with an issue is the newest issue's bot, scrolled to it; otherwise Hermes'.
    static func page(_ tab: CapabilitiesTab, services: any AppServices, settingsPage: Bool = false) -> UIViewController {
        if tab == .connectors, let newest = ServerIssues.shared.issues.first {
            return CapabilitiesViewController(services: services, profile: newest.profile, tab: .connectors, focus: newest.name,
                                              settingsPage: settingsPage)
        }
        return CapabilitiesViewController(services: services, profile: nil, tab: tab, settingsPage: settingsPage)
    }

    /// A link to one list (Settings' search): its page over Capabilities, so Back goes to the four rows.
    static func pages(_ tab: CapabilitiesTab, services: any AppServices, settingsPage: Bool = false) -> [UIViewController] {
        [CapabilitiesHubController(services: services, settingsPage: settingsPage), page(tab, services: services, settingsPage: settingsPage)]
    }
}

extension CapabilitiesTab {
    /// The row's symbol, as Settings draws its rows (a tile in the iOS look).
    var symbol: String {
        switch self {
        case .skills: "sparkles"
        case .tools: "hammer"
        case .connectors: "powerplug"   // Mac polish #90: the plug, as in More and Tabs (the dotted triangle is Spawn Tree's)
        case .plugins: "puzzlepiece.extension"
        }
    }
}

struct CapabilitiesHubView: View {
    let services: any AppServices
    let router: SettingsRouter
    var settingsPage = false

    static let footer = "Each bot has its own. Choose the bot at the top of each page."
    /// [composio-row] Under the Mac's Composio row: why it is apart from the four lists.
    static let composioFooter = "Apps through your own Composio API key, shared by the bots you choose."
    /// [composio-row] Owner 2026-11-12 ("get it right"): on the Mac, where More dissolves and Connectors lives on this
    /// page, Composio is here too, right under the four lists and in a group of its own (it is one account for all
    /// bots, not a list each bot has). The iPhone has its row in More, under Connectors, so not a second one here.
    static var showsComposio: Bool { DeviceWord.isMac && ConnectAppsFeature.isOn }

    var body: some View {
        let status = CapabilitiesIssues.moreStatus()
        List { Group {
            Section {
                ForEach(CapabilitiesTab.allCases) { tab in
                    let issue = tab == .connectors ? status : nil
                    // [plugin-updates] Plugins says how many have an update ("2 Updates").
                    let updates = tab == .plugins ? PluginUpdateReminder.shared.hubValue : nil
                    NavRow(title: tab.title, systemImage: tab.symbol, value: issue?.text ?? updates, valueIsIssue: issue != nil) {
                        router.push(CapabilitiesPages.page(tab, services: services, settingsPage: settingsPage))
                    }
                    .accessibilityLabel(tab.title)
                    .accessibilityValue(issue?.spoken ?? updates ?? "")
                    .accessibilityIdentifier("capabilities.row.\(tab.rawValue)")
                }
            } footer: { HQSectionFooter {
                Text(Self.footer)
            } }
            if Self.showsComposio {
                Section {
                    NavRow(title: ComposioRow.title, systemImage: ComposioRow.symbol) {
                        router.push(ConnectAppsScreens.makeRoot(services: services))
                    }
                    .accessibilityIdentifier("capabilities.row.composio")
                } footer: { HQSectionFooter {
                    Text(Self.composioFooter)
                } }
            }
        }.hqMacSettingsRowInsets() }
        .hqMacForm(settings: settingsPage)   // [mac] as the lists: Settings' rows when opened there
        .hqGroupedPage()   // [desktoplook] the page follows the skin
        .listStyle(.insetGrouped)
        .contentMargins(.top, MacInset.top(otherwise: 0), for: .scrollContent)   // [mac] Stress test 2026-10-28 #53
    }
}
