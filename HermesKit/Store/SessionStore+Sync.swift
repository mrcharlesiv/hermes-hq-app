// [sync] The Sessions list's hand-picked parts follow the owner from device to device (owner 2026-11-03): Sort By
// Manual's chat order, the project and bot group orders, favorite projects, chat colours, and Sort By / Group By / Row
// Detail. Kept on the gateway as the document "sessions" (`GatewaySync`). The filters, folds and read markers stay on
// each device.

import Foundation

extension SessionStore: GatewaySynced {
    /// Sort By Manual's chats kept on the gateway (the top of the order; the rest stay on the device).
    static let syncedChatOrderLimit = 500

    var syncName: String { "sessions" }

    func syncValue() -> JSONValue {
        let rows = Array(view.rowDetail.map(\.rawValue).sorted())
        return [
            "chatOrder": .array(device.chatOrder.prefix(Self.syncedChatOrderLimit).map { .string($0) }),
            "projectOrder": .array(device.projectOrder.map { .string($0) }),
            "botGroupOrder": .array(device.botGroupOrder.map { .string($0) }),
            "favoriteProjects": .array(device.favoriteProjects.map { .string($0) }),
            "archivedProjects": .array(device.archivedProjects.map { .string($0) }),       // [project-pills]
            "projectBots": .object(device.projectBots.mapValues { .string($0) }),          // [project-default-bot]
            "codingProjects": .object(device.codingProjects.mapValues { .bool($0) }),
            "projectPinsLocal": .object(device.projectPinsLocal.mapValues { .bool($0) }),            // [project-pins]
            "projectPins": .object(device.projectPins.mapValues { .array($0.map { .string($0) }) }),
            "botChatShortcuts": .array(device.botChatShortcuts.map(\.json)),
            "projectSorts": .object(device.projectSorts.mapValues { .string($0) }),                 // [project-sort]
            "projectKeep": .object(device.projectKeep.mapValues { .bool($0) }),                      // [project-keep]
            "projectAutoDone": .object(device.projectAutoDone.mapValues { .string($0) }),            // [project-auto-done]
            "projectNotify": .object(device.projectNotify.mapValues { .string($0) }),                // [project-mute]
            "projectNewChat": .object(device.projectNewChat.mapValues(\.json)),                      // [project-new-chat-model]
            "projectLooks": .object(device.projectLooks.mapValues(\.json)),                          // [project-look]
            "projectBranchRows": .object(device.projectBranchRows.mapValues { .bool($0) }),          // [project-branch-rows]
            "colors": .object(device.colors.mapValues { .number(Double($0)) }),
            "sortBy": .string(view.sortBy.rawValue),
            "groupBy": .string(view.groupBy.rawValue),
            "rowDetail": .array(rows.map { .string($0) }),
            "recentPreview": .bool(view.recentPreview),
        ]
    }

    func adoptSynced(_ value: JSONValue, merge: GatewaySyncMerge, base: JSONValue?) {
        let oldCodingProjects = device.codingProjects
        let oldShortcuts = device.botChatShortcuts
        if let remote = BotChatShortcut.decode(value["botChatShortcuts"]) {
            device.botChatShortcuts = BotChatShortcut.merged(local: oldShortcuts, remote: remote,
                base: BotChatShortcut.decode(base?["botChatShortcuts"]) ?? [], policy: merge)
        }
        func strings(_ key: String) -> [String] { (value[key]?.array ?? []).compactMap(\.string) }
        /// The gateway's order first; this device's chats it doesn't name keep their places after it.
        func joined(_ remote: [String], _ local: [String]) -> [String] {
            let named = Set(remote)
            return remote + local.filter { !named.contains($0) }
        }
        if merge == .rebase {
            // This device's change is the newest; only colours set elsewhere meanwhile come in.
            for (key, raw) in value["colors"]?.object ?? [:] where device.colors[key] == nil {
                if let index = raw.int { device.colors[key] = index }
            }
            for (key, raw) in value["projectBots"]?.object ?? [:] where device.projectBots[key] == nil {
                if let bot = raw.string { device.projectBots[key] = bot }
            }
            for (key, raw) in value["codingProjects"]?.object ?? [:] where device.codingProjects[key] == nil {
                if let enabled = raw.bool { device.codingProjects[key] = enabled }
            }
            for (key, raw) in value["projectPinsLocal"]?.object ?? [:] where device.projectPinsLocal[key] == nil {
                if let on = raw.bool { device.projectPinsLocal[key] = on }
            }
            for (key, raw) in value["projectSorts"]?.object ?? [:] where device.projectSorts[key] == nil {
                if let sort = raw.string { device.projectSorts[key] = sort }
            }
            for (key, raw) in value["projectPins"]?.object ?? [:] where device.projectPins[key] == nil {
                if let rows = raw.array?.compactMap(\.string), !rows.isEmpty { device.projectPins[key] = rows }
            }
            // [project-settings] As the parts above: only what this device has not set comes in.
            for (key, raw) in value["projectKeep"]?.object ?? [:] where device.projectKeep[key] == nil {
                if let on = raw.bool { device.projectKeep[key] = on }
            }
            for (key, raw) in value["projectAutoDone"]?.object ?? [:] where device.projectAutoDone[key] == nil {
                if let rule = raw.string { device.projectAutoDone[key] = rule }
            }
            for (key, raw) in value["projectNotify"]?.object ?? [:] where device.projectNotify[key] == nil {
                if let level = raw.string { device.projectNotify[key] = level }
            }
            for (key, raw) in value["projectNewChat"]?.object ?? [:] where device.projectNewChat[key] == nil {
                if raw.object != nil { device.projectNewChat[key] = ProjectNewChat(json: raw) }
            }
            for (key, raw) in value["projectLooks"]?.object ?? [:] where device.projectLooks[key] == nil {
                if raw.object != nil { device.projectLooks[key] = ProjectLook(json: raw) }
            }
            for (key, raw) in value["projectBranchRows"]?.object ?? [:] where device.projectBranchRows[key] == nil {
                if let on = raw.bool { device.projectBranchRows[key] = on }
            }
        } else {
            device.chatOrder = joined(strings("chatOrder"), device.chatOrder)
            device.projectOrder = joined(strings("projectOrder"), merge == .firstContact ? device.projectOrder : [])
            device.botGroupOrder = joined(strings("botGroupOrder"), merge == .firstContact ? device.botGroupOrder : [])
            device.favoriteProjects = joined(strings("favoriteProjects"), merge == .firstContact ? device.favoriteProjects : [])
            device.archivedProjects = joined(strings("archivedProjects"), merge == .firstContact ? device.archivedProjects : [])
            var colors = merge == .firstContact ? device.colors : [:]
            for (key, raw) in value["colors"]?.object ?? [:] { if let index = raw.int { colors[key] = index } }
            device.colors = colors
            // [project-default-bot] A gateway copy written before this had no such part: the device keeps its own.
            if let remote = value["projectBots"]?.object {
                var chosen = merge == .firstContact ? device.projectBots : [:]
                for (key, raw) in remote { if let bot = raw.string { chosen[key] = bot } }
                device.projectBots = chosen
            }
            if let remote = value["codingProjects"]?.object {
                var chosen = merge == .firstContact ? device.codingProjects : [:]
                for (key, raw) in remote { if let enabled = raw.bool { chosen[key] = enabled } }
                device.codingProjects = chosen
            }
            // [project-pins] As Coding Project: a gateway copy without these parts leaves the device's own.
            if let remote = value["projectPinsLocal"]?.object {
                var chosen = merge == .firstContact ? device.projectPinsLocal : [:]
                for (key, raw) in remote { if let on = raw.bool { chosen[key] = on } }
                device.projectPinsLocal = chosen
            }
            if let remote = value["projectPins"]?.object {
                var chosen = merge == .firstContact ? device.projectPins : [:]
                for (key, raw) in remote {
                    let rows = raw.array?.compactMap(\.string) ?? []
                    chosen[key] = rows.isEmpty ? nil : rows
                }
                device.projectPins = chosen
            }
            if let remote = value["projectSorts"]?.object {
                var chosen = merge == .firstContact ? device.projectSorts : [:]
                for (key, raw) in remote { if let sort = raw.string { chosen[key] = sort } }
                device.projectSorts = chosen
            }
            // [project-settings] As Coding Project: a gateway copy without one of these parts leaves the device's own.
            if let remote = value["projectKeep"]?.object {
                var chosen = merge == .firstContact ? device.projectKeep : [:]
                for (key, raw) in remote { if let on = raw.bool { chosen[key] = on } }
                device.projectKeep = chosen
            }
            if let remote = value["projectAutoDone"]?.object {
                var chosen = merge == .firstContact ? device.projectAutoDone : [:]
                for (key, raw) in remote { if let rule = raw.string { chosen[key] = rule } }
                device.projectAutoDone = chosen
            }
            if let remote = value["projectNotify"]?.object {
                var chosen = merge == .firstContact ? device.projectNotify : [:]
                for (key, raw) in remote { if let level = raw.string { chosen[key] = level } }
                device.projectNotify = chosen
            }
            if let remote = value["projectNewChat"]?.object {
                var chosen = merge == .firstContact ? device.projectNewChat : [:]
                for (key, raw) in remote where raw.object != nil { chosen[key] = ProjectNewChat(json: raw) }
                device.projectNewChat = chosen
            }
            if let remote = value["projectLooks"]?.object {
                var chosen = merge == .firstContact ? device.projectLooks : [:]
                for (key, raw) in remote where raw.object != nil { chosen[key] = ProjectLook(json: raw) }
                device.projectLooks = chosen
            }
            if let remote = value["projectBranchRows"]?.object {
                var chosen = merge == .firstContact ? device.projectBranchRows : [:]
                for (key, raw) in remote { if let on = raw.bool { chosen[key] = on } }
                device.projectBranchRows = chosen
            }
            var prefs = view
            if let raw = value["sortBy"]?.string, let sort = SessionSortBy(rawValue: raw) { prefs.sortBy = sort }
            if let raw = value["groupBy"]?.string, let group = SessionGroupBy(rawValue: raw) { prefs.groupBy = group }
            if let raw = value["rowDetail"]?.array {
                let detail = Set(raw.compactMap(\.string).compactMap(SessionRowDetail.init(rawValue:)))
                if !detail.isEmpty { prefs.rowDetail = detail }
            }
            if let on = value["recentPreview"]?.bool { prefs.recentPreview = on }
            view = prefs
            device.view = prefs
        }
        persistState()
        if oldCodingProjects != device.codingProjects { codingProjectsChanged() }
        let shortcutsChanged = oldShortcuts != device.botChatShortcuts
        if shortcutsChanged {
            let kept = Set(device.botChatShortcuts)
            offPageShortcuts = offPageShortcuts.filter { kept.contains($0.key) }
            shortcutCheckedAt = shortcutCheckedAt.filter { kept.contains($0.key) }
            refreshOffPageShortcuts()
        }
        rebuild(force: shortcutsChanged)
    }
}
