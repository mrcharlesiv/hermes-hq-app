// [quick-actions] One-tap "Add to Favorites" / "Remove from Favorites" helper wired into context menus across the app
// (Bots, Group Chats, Sessions, Dashboard Tiles, Goals, Jobs, and Task Lists).

import UIKit

@MainActor enum FavoritesPinAction {
    // MARK: Lookup & toggle

    static func contains(where match: (QuickTile) -> Bool) -> Bool {
        QuickTileStore.load().tiles.contains(where: match)
    }

    @discardableResult
    static func toggle(matching match: (QuickTile) -> Bool, make: () -> QuickTile, from host: UIViewController?) -> Bool {
        var list = QuickTileStore.load()
        // If the user has never opened Favorites yet, seed the starter set first so adding one item doesn't skip it.
        if list.tiles.isEmpty, !list.seeded, let firstBot = MainTabController.current?.services.bots.first {
            list = QuickTileStore.listToShow(list, firstBot: (profile: firstBot.id, name: firstBot.name)).list
        }
        let added: Bool
        if let idx = list.tiles.firstIndex(where: match) {
            list.tiles.remove(at: idx)
            added = false
        } else {
            var tile = make()
            let current = QuickTileStore.currentPage()
            if current != FavoritePage.mainId, list.allPages.contains(where: { $0.id == current }) {
                tile.pageId = current
            }
            if let gw = MorePages.context?.account.id, !gw.isEmpty { tile.gatewayId = gw }
            list.add(tile)
            added = true
        }
        QuickTileStore.save(list)
        PagesHaptics.selection()
        if let host {
            PagesHUD.show(added ? "Added to Favorites" : "Removed from Favorites",
                          symbol: added ? "star.fill" : "star.slash", from: host)
        }
        HQAnnounce.say(added ? "Added to Favorites" : "Removed from Favorites")
        return added
    }

    // MARK: Specific menu builders

    static func botNode(_ bot: Bot, from host: UIViewController?) -> BotMenuNode {
        let on = contains { ($0.known == .botCard || $0.known == .openChat) && $0.bot == bot.id }
        return .action(on ? "Remove from Favorites" : "Add to Favorites", on ? "star.slash" : "star") { [weak host] in
            toggle(matching: { ($0.known == .botCard || $0.known == .openChat) && $0.bot == bot.id }, make: {
                var tile = QuickTile(kind: .botCard, name: bot.name, wide: true)
                tile.bot = bot.id
                tile.botName = bot.name
                return tile
            }, from: host)
        }
    }

    static func roomNode(_ room: GroupRowModel, from host: UIViewController?) -> BotMenuNode {
        let on = contains { $0.known == .groupChat && $0.roomKey == room.id }
        return .action(on ? "Remove from Favorites" : "Add to Favorites", on ? "star.slash" : "star") { [weak host] in
            toggle(matching: { $0.known == .groupChat && $0.roomKey == room.id }, make: {
                var tile = QuickTile(kind: .groupChat, name: room.name)
                tile.roomKey = room.id
                tile.roomName = room.name
                return tile
            }, from: host)
        }
    }

    static func sessionNode(_ session: SessionSummary, from host: UIViewController?) -> BotMenuNode {
        let on = contains { $0.known == .chatSession && $0.sessionId == session.id }
        return .action(on ? "Remove from Favorites" : "Add to Favorites", on ? "star.slash" : "star") { [weak host] in
            toggle(matching: { $0.known == .chatSession && $0.sessionId == session.id }, make: {
                let title = SessionRowView.title(session)
                var tile = QuickTile(kind: .chatSession, name: title)
                tile.sessionId = session.id
                tile.sessionTitle = title
                tile.bot = session.profile
                tile.botName = QuickActionsRouter.botName(session.profile) ?? session.profile
                return tile
            }, from: host)
        }
    }

    static func dashboardTileAction(_ pin: ArtifactPin, displayName: String, from host: UIViewController?) -> UIAction {
        let on = contains { $0.known == .dashboardTile && $0.pin == pin.id }
        return UIAction(title: on ? "Remove from Favorites" : "Add to Favorites",
                        image: UIImage(systemName: on ? "star.slash" : "star")) { [weak host] _ in
            toggle(matching: { $0.known == .dashboardTile && $0.pin == pin.id }, make: {
                var tile = QuickTile(kind: .dashboardTile, name: displayName)
                tile.pin = pin.id
                tile.pinName = displayName
                return tile
            }, from: host)
        }
    }

    static func goalAction(_ goal: Goal, from host: UIViewController?) -> UIAction {
        let on = contains { $0.known == .goal && $0.goalId == goal.id }
        return UIAction(title: on ? "Remove from Favorites" : "Add to Favorites",
                        image: UIImage(systemName: on ? "star.slash" : "star")) { [weak host] _ in
            toggle(matching: { $0.known == .goal && $0.goalId == goal.id }, make: {
                let title = goal.title.isEmpty ? "Untitled Goal" : goal.title
                var tile = QuickTile(kind: .goal, name: title, wide: true)
                tile.goalId = goal.id
                tile.goalName = title
                return tile
            }, from: host)
        }
    }

    static func jobAction(_ job: CronJob, title: String, from host: UIViewController?) -> UIAction {
        let on = contains { ($0.known == .jobCard || $0.known == .runJob) && $0.job == job.key }
        return UIAction(title: on ? "Remove from Favorites" : "Add to Favorites",
                        image: UIImage(systemName: on ? "star.slash" : "star")) { [weak host] _ in
            toggle(matching: { ($0.known == .jobCard || $0.known == .runJob) && $0.job == job.key }, make: {
                var tile = QuickTile(kind: .jobCard, name: title, wide: true)
                tile.job = job.key
                tile.jobName = title
                return tile
            }, from: host)
        }
    }

    static func taskViewAction(viewKey: String, name: String, from host: UIViewController?) -> UIAction {
        let on = contains { $0.known == .tasks && ($0.taskView ?? "today") == viewKey }
        return UIAction(title: on ? "Remove from Favorites" : "Add to Favorites",
                        image: UIImage(systemName: on ? "star.slash" : "star")) { [weak host] _ in
            toggle(matching: { $0.known == .tasks && ($0.taskView ?? "today") == viewKey }, make: {
                var tile = QuickTile(kind: .tasks, name: name, wide: true)
                tile.taskView = viewKey
                tile.taskViewName = name
                return tile
            }, from: host)
        }
    }
}
