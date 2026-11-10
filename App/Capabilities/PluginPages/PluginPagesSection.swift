// [plugin-pages] Opening a plugin's page from Capabilities › Plugins (a plugin's Open button, its Marketplace card's
// Open <Label>): the page in Hermes HQ (PluginWebPage.swift).

import SwiftUI
import UIKit

/// [plugin-pages-more] The Pages group that stood at the top of this list moved to More › Plugin Pages (one home per
/// page, PluginPagesMore.swift). What stays here is the shortcut a plugin's row and its Marketplace card open.
enum PluginPagesSection {
    static func open(_ page: PluginDashboardPage, model: CapabilitiesModel, router: SettingsRouter) {
        guard let controller = PluginWebPageController.make(page: page, model: model) else { return }
        Haptics.play(.light)
        AppLog.trace("plugin-pages", "open \(page.name) for \(AppLog.tag(model.profile))")
        router.push(controller)
    }
}

extension PluginCatalogEntry {
    /// [plugin-pages] Whether the listing says it adds a page to the Hermes dashboard (the catalog has no field for
    /// it, so its words decide: "dashboard tab", "Dashboard and Desktop plugin", "from the Hermes dashboard"…).
    var addsDashboardPage: Bool {
        let words = description.lowercased()
        let phrases = ["dashboard tab", "dashboard page", "dashboard-only", "dashboard only", "dashboard plugin", "dashboard and desktop plugin",
                       "from the hermes dashboard", "for the hermes dashboard", "in the hermes dashboard", "hermes dashboard and desktop"]
        return phrases.contains { words.contains($0) }
    }
}
