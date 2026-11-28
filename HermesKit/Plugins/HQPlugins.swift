// [hq-plugins] Hermes HQ's own plugins that anyone can add: the ones in HQ's public plugins repository that are not
// part of the app's setup (hermes-hq-push and hermes-hq-browser are; the app installs and updates those itself).
// Owner 2026-11-27: Proactivity was public but listed nowhere, so nobody but the owner could find it. They show as
// "From Hermes HQ" on the Plugins tab and in the Marketplace, and install with the call Install from Git uses
// (`plugins.manage install {identifier}`): the newest version from the repository. They are not in Nous's catalog and
// the pages say so, since "Nous reviewed this exact version" is not true of them. After that they are ordinary
// plugins: Hermes's own list says when one has an update (`PluginUpdateReminder`).
// Proactivity also has its own page, Settings › Proactivity (Beta) (`ProactivityBetaPage`, build 1348), with an
// install button and its switch; this list is where someone browsing for plugins finds it, and it points there.

import Foundation

extension PluginCatalogEntry {
    static let hqRepo = "https://github.com/mrcharlesiv/hermes-hq-plugins"

    /// In the order they are shown.
    static let fromHermesHQ: [PluginCatalogEntry] = [proactivity]

    static let proactivity = hq(
        name: ProactivityBeta.pluginName, title: "Proactivity", category: .automation, beta: true, requiresHermes: ">=0.22",
        description: """
        Your bot speaks up about what you left open. It keeps track of things you said you would do, things you are \
        waiting on and dates that are coming up. When one is due, past its date or has gone quiet, the bot looks into \
        it, reading only, and sends you one message in its chat with what it found. It also writes a short brief each \
        morning. It is off until you turn it on, sends at most a few messages a day and none in quiet hours. \
        Disclosure — its checks read your bot's recent chats on the computer that runs Hermes and send what they \
        read to the model your bot already uses, and nowhere else. Nothing is booked, paid, sent or deleted without you.
        """,
        tools: ["proactive_loop_track", "proactive_loop_resolve", "proactive_loop_list", "proactive_offer", "proactive_feedback",
                "proactive_watch_add", "proactive_brief_get"],
        addsPage: true, setupNote: "It stays off until you turn it on in Settings › Proactivity (Beta).")

    private static func hq(name: String, title: String, category: PluginCatalogCategory, beta: Bool, requiresHermes: String,
                           description: String, tools: [String], addsPage: Bool, setupNote: String?) -> PluginCatalogEntry {
        PluginCatalogEntry(
            name: name, description: description, repo: hqRepo, sha: "", subdir: name, tier: hqTier, category: category,
            maintainer: "Hermes HQ", version: "", requiresHermes: requiresHermes, platforms: [], providesTools: tools, requiresEnv: [],
            docsURL: URL(string: "\(hqRepo)/tree/main/\(name)#readme"), image: nil, stars: nil, addedAt: nil, updatedAt: nil,
            readmeURL: URL(string: "https://raw.githubusercontent.com/mrcharlesiv/hermes-hq-plugins/main/\(name)/README.md"),
            shownTitle: title, beta: beta, addsPage: addsPage, setupNote: setupNote)
    }

    /// HQ's plugins that answer `query` (all of them for no words), in their own order.
    static func hermesHQ(matching query: String) -> [PluginCatalogEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? fromHermesHQ : fromHermesHQ.filter { $0.score(q) > 0 }
    }

    /// Under a list of them.
    static let hermesHQFooter = "Made by Hermes HQ. These are not in the Hermes Marketplace, so Nous has not reviewed them."
}
