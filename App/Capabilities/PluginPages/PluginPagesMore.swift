// [plugin-pages-more] More › Plugin Pages: one row for each page your bots' plugins add (Memory Wiki…), so a page is a
// place you go to, as it is in the Hermes dashboard's own menu, not a group three pages down in Capabilities › Plugins.
// Owner 2026-11-05: "I couldn't find it unless I opened the marketplace."
// - One home per page: this section is the list. A plugin's row in Plugins and its Marketplace card keep an Open button
//   as a shortcut, as the Plugins and Skills pages kept their Marketplace links.
// - The section shows only while some bot has a page (More never lists a row that does nothing).
// - The pages are read for every bot on attach and on each `gateway.ready`, and again when Capabilities reads a bot's
//   list (a plugin just installed or turned on/off shows at once).

import UIKit

@MainActor
enum PluginPagesMore {
    static let section = "plugins"
    static let header = "Plugin Pages"
    /// One tile colour for every plugin page (Settings icons' rule: colours from a table); each keeps its own symbol.
    static let tile: UInt32 = 0x00C7BE

    /// A page and the bots that have it, default bot first, then roster order.
    nonisolated struct Listed: Equatable, Sendable {
        var page: PluginDashboardPage
        var profiles: [String]
    }

    /// Per account: each bot's pages, as last read.
    private static var pagesByAccount: [String: [String: [PluginDashboardPage]]] = [:]
    private static var task: Task<Void, Never>?
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        PagesTabs.appendMoreRows(key: "pluginpages", section: section, header: header, order: 10) { rows() }
    }

    /// Every page any bot has, in name order, with its bots.
    static func listed() -> [Listed] {
        guard let context = MorePages.context, let byBot = pagesByAccount[context.account.id] else { return [] }
        return merge(byBot, bots: context.botChoices.filter { !$0.hidden }.map(\.id))
    }

    /// Each bot's pages as one list: a page once, with the bots that have it in `bots`' order; sorted by label.
    nonisolated static func merge(_ byBot: [String: [PluginDashboardPage]], bots: [String]) -> [Listed] {
        var out: [String: Listed] = [:]
        for bot in bots {
            for page in byBot[bot] ?? [] {
                if out[page.name] == nil { out[page.name] = Listed(page: page, profiles: []) }
                out[page.name]?.profiles.append(bot)
            }
        }
        return out.values.sorted { $0.page.label.localizedStandardCompare($1.page.label) == .orderedAscending }
    }

    static func rowID(_ name: String) -> String { "plugin-page.\(name)" }

    private static func rows() -> [MoreRow] {
        guard let context = MorePages.context else { return [] }
        let manyBots = context.botChoices.filter { !$0.hidden }.count > 1
        return listed().map { item in
            var row = MoreRow(id: rowID(item.page.name), title: item.page.label, symbol: item.page.symbol, image: nil,
                              tile: MorePages.color(tile)) {
                open(item.page.name, profile: nil)
            }
            // Whose page it is, at the row's end: the bot's name when only one has it, else how many do.
            if manyBots {
                let words = item.profiles.count == 1 ? context.botName(item.profiles[0]) : "\(item.profiles.count) Bots"
                row.status = { MoreRowStatus(text: words, isIssue: false, spoken: words) }
            }
            return row
        }
    }

    /// The page `name` for `profile` (nil: the first bot that has it), with a switch to the other bots that have it.
    static func open(_ name: String, profile: String?) -> UIViewController? {
        guard let context = MorePages.context, let item = listed().first(where: { $0.page.name == name }),
              let chosen = profile.flatMap({ item.profiles.contains($0) ? $0 : nil }) ?? item.profiles.first else { return nil }
        AppLog.trace("plugin-pages", "open \(name) for \(AppLog.tag(chosen)) from More (\(item.profiles.count) bot(s))")
        let page = byBotPage(name, profile: chosen, account: context.account.id) ?? item.page
        let controller = PluginWebPageController(page: page, profile: chosen, botName: context.botName(chosen),
                                                 client: context.client, services: context.services as? AppModel)
        controller.otherBots = item.profiles.count > 1 ? item.profiles.map { ($0, context.botName($0)) } : []
        controller.navigationItem.largeTitleDisplayMode = .never
        return controller
    }

    private static func byBotPage(_ name: String, profile: String, account: String) -> PluginDashboardPage? {
        pagesByAccount[account]?[profile]?.first { $0.name == name }
    }

    // MARK: Reading

    /// Reads every bot's pages (attach, `gateway.ready`).
    static func refresh() {
        guard let context = MorePages.context else { return }
        let client = context.client, account = context.account.id
        let profiles = context.botChoices.filter { !$0.hidden }.map(\.id)
        guard !profiles.isEmpty else { return }
        task?.cancel()
        let started = ContinuousClock.now
        task = Task {
            var read: [String: [PluginDashboardPage]] = pagesByAccount[account] ?? [:]
            // Not `withTaskGroup`: optimized builds abort when a child finishes into a destroyed group (ChildTasks.swift).
            await withChildTasks(of: (String, [PluginDashboardPage]?).self) { group in
                for profile in profiles {
                    // The read before the tuple: `(key, try await f())` can lose `key` in -O builds (Swift tuple bug).
                    group.addTask { let pages = try? await DashboardPagesAPI.list(client, profile: profile); return (profile, pages) }
                }
                while let (profile, pages) = await group.next() { if let pages { read[profile] = pages } }
            }
            guard !Task.isCancelled, MorePages.context?.account.id == account else { return }
            let total = read.values.reduce(0) { $0 + $1.count }
            AppLog.trace("plugin-pages", "More read \(profiles.count) bot(s) in \(AppLog.ms(since: started)) ms: \(total) page(s), \(Set(read.values.flatMap { $0.map(\.name) }).sorted().joined(separator: ", "))")
            store(read, account: account)
        }
    }

    /// Capabilities read one bot's pages (Plugins opened, a plugin installed or turned on/off): More follows at once.
    static func note(_ pages: [PluginDashboardPage], profile: String) {
        guard let account = MorePages.context?.account.id else { return }
        var read = pagesByAccount[account] ?? [:]
        read[profile] = pages
        store(read, account: account)
    }

    private static func store(_ read: [String: [PluginDashboardPage]], account: String) {
        guard pagesByAccount[account] != read else { return }
        pagesByAccount[account] = read
        PagesTabs.moreRowsChanged()
    }
}
