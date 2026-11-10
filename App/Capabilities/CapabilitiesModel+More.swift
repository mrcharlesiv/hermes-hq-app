// The 3x additions to the Capabilities model (docs/spec/3x-capabilities.md §3–§5, §9): Disable Unused, the Tools tab,
// the Plugins tab and the small pieces the connector pages share. State lives on `CapabilitiesModel` itself.

import UIKit

/// The inline "Installing…" / "Installed" row of an official skill (§3.1).
struct InstallNotice: Identifiable, Hashable {
    var profile: String
    var identifier: String
    var name: String
    var bot: String
    var done: Bool
    var id: String { "\(profile)|\(identifier)" }
    var title: String { done ? "Installed \(name)" : "Installing \(name)…" }
    var message: String { done ? "\(bot) can use it in new chats." : "For \(bot). This can take a minute." }
}

enum ToolSort: String, CaseIterable, Identifiable {
    case most, least, name
    var id: String { rawValue }
    var title: String {
        switch self {
        case .most: "Most Used"
        case .least: "Least Used"
        case .name: "A–Z"
        }
    }
    static var saved: ToolSort { UserDefaults.standard.string(forKey: "capabilities.tools.sort").flatMap(ToolSort.init(rawValue:)) ?? .most }
}

extension CapabilitiesModel {
    static func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
    /// A catalog's search field: "Search 12 apps", "Search 1 app", or "Search apps" before the list has loaded.
    static func searchApps(_ n: Int) -> String { n > 0 ? "Search \(plural(n, "app", "apps"))" : "Search apps" }

    // MARK: Skills: Disable Unused (§3.2)

    /// Enabled skills with a real zero use count, in the list's order. Never the search's filter.
    var unusedSkills: [SkillInfo] { (skills ?? []).filter { $0.enabled && $0.usage == 0 } }
    /// False when no row carries a use count: the command is then not offered at all (DECISION 3.2-a).
    var hasUsage: Bool { (skills ?? []).contains { $0.usage != nil } }

    func disableUnused() {
        let unused = unusedSkills
        guard !unused.isEmpty, disabling == nil, !readOnly else { return }
        let bot = botName
        TextPrompt.confirm(title: "Turn Off \(Self.plural(unused.count, "Unused Skill", "Unused Skills")) for \(bot)?",
                           message: "These skills have never been used. You can turn any of them back on.", action: "Turn Off",
                           from: presenter) { [weak self] in self?.runDisable(unused) }
    }

    private func runDisable(_ unused: [SkillInfo]) {
        guard let service else { return }
        let profile = self.profile
        disabling = (0, unused.count)
        skillsNotice = nil
        Task {
            var done = 0
            for skill in unused {
                do {
                    try await service.setSkill(skill.name, enabled: false, profile: profile)
                    done += 1
                    if profile == self.profile { flip(skill.name, false); disabling = (done, unused.count) }
                } catch {
                    disabling = nil
                    let reason = CapabilitiesStore.detail(error)
                    AppLog.note("plugins", "disable unused: stopped after \(done) of \(unused.count), \(skill.name) failed: \(reason)")
                    FailureAlert.present(title: "Couldn’t Turn Off \(skill.name)", reason: reason, detail: "\(error)", from: presenter)
                    if profile == self.profile { await reloadSkills() }
                    return
                }
            }
            disabling = nil
            Haptics.play(.success)
            AppLog.trace("plugins", "disable unused: turned off \(done) skills")
            flash("Updated \(Self.plural(done, "item", "items")) for new chats.") { $0.skillsNotice = $1 } read: { $0.skillsNotice }
            if profile == self.profile { await reloadSkills() }
        }
    }

    /// Shows a notice for 4 s.
    func flash(_ text: String, set: @escaping (CapabilitiesModel, String?) -> Void, read: @escaping (CapabilitiesModel) -> String?) {
        set(self, text)
        HQAnnounce.say(text)
        Task {
            try? await Task.sleep(for: .seconds(4))
            if read(self) == text { set(self, nil) }
        }
    }

    // MARK: Tools (§4)

    func reloadTools() async {
        guard let store else { return }
        guard isConnected else { waitForLink(); return }
        let profile = self.profile
        do {
            let list = try await QueryRetry.read { try await store.toolsets(profile) }.filter { !Toolset.hidden.contains($0.name) }
            guard profile == self.profile else { return }
            toolsets = list
            toolCache[profile] = list
            toolsError = nil
            toolsTooOld = false
            stamp("tools", profile)
            AppLog.trace("plugins", "toolsets load \(AppLog.tag(profile)): \(list.count)")
        } catch {
            guard profile == self.profile else { return }
            if CapabilitiesStore.isNotFound(error) { toolsTooOld = true; toolsets = nil; return }
            if toolsets == nil { toolsError = CapabilitiesStore.detail(error) }
            AppLog.note("plugins", "toolsets load \(AppLog.tag(profile)) failed: \(CapabilitiesStore.detail(error))")
            if !isConnected { waitForLink() }
            return
        }
        // Usage is best effort: a failure never shows an error; the list falls back to A–Z and "N tools".
        if let cached = usageCache[profile], Date().timeIntervalSince(cached.at) < 600 { toolUsage = cached.counts; return }
        let counts = try? await QueryRetry.read { try await store.toolUsage(profile) }
        guard profile == self.profile else { return }
        toolUsage = counts
        if let counts { usageCache[profile] = (Date(), counts) }
    }

    func calls(_ toolset: Toolset) -> Int { toolset.tools.reduce(0) { $0 + (toolUsage?[$1] ?? 0) } }

    /// "1.2K uses" when its tools have calls, else "3 tools".
    func toolMeta(_ toolset: Toolset) -> String {
        let used = calls(toolset)
        return used > 0 ? "\(Toolset.compact(used)) \(used == 1 ? "use" : "uses")" : Self.plural(toolset.tools.count, "tool", "tools")
    }

    var effectiveSort: ToolSort { toolUsage == nil ? .name : toolSort }

    var shownToolsets: [Toolset] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let list = (toolsets ?? []).filter { set in
            q.isEmpty || ([set.name, set.label, set.description] + set.tools).contains { $0.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        func byName(_ a: Toolset, _ b: Toolset) -> Bool { a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending }
        switch effectiveSort {
        case .name: return list.sorted(by: byName)
        case .most: return list.sorted { calls($0) != calls($1) ? calls($0) > calls($1) : byName($0, $1) }
        case .least: return list.sorted { calls($0) != calls($1) ? calls($0) < calls($1) : byName($0, $1) }
        }
    }

    var allToolsOn: Bool { !(toolsets ?? []).isEmpty && (toolsets ?? []).allSatisfy(\.enabled) }

    func setToolset(_ toolset: Toolset, enabled: Bool) {
        guard let store, !toolToggling.contains(toolset.name) else { return }
        Haptics.play(.selection)
        flipTool(toolset.name, enabled)
        toolToggling.insert(toolset.name)
        let profile = self.profile
        Task {
            defer { toolToggling.remove(toolset.name) }
            do {
                try await store.setToolset(toolset.name, enabled: enabled, profile: profile)
                AppLog.trace("plugins", "toolset \(toolset.name) set enabled \(enabled)")
            } catch {
                if profile == self.profile { flipTool(toolset.name, !enabled) }
                let reason = CapabilitiesStore.detail(error)
                AppLog.note("plugins", "toolset \(toolset.name) set enabled \(enabled) failed: \(reason)")
                FailureAlert.present(title: "Couldn’t Update \(toolset.label)", reason: reason, detail: "\(error)", from: presenter)
            }
        }
    }

    func flipTool(_ name: String, _ enabled: Bool) {
        guard let index = toolsets?.firstIndex(where: { $0.name == name }) else { return }
        toolsets?[index].enabled = enabled
        toolCache[profile] = toolsets
    }

    func setAllTools(_ enabled: Bool) {
        let bot = botName
        if enabled { runAllTools(true); return }
        TextPrompt.confirm(title: "Turn Off All Tools for \(bot)?", message: "\(bot) won’t be able to use any tools in new chats.",
                           action: "Turn Off", from: presenter) { [weak self] in self?.runAllTools(false) }
    }

    private func runAllTools(_ enabled: Bool) {
        guard let store, toolToggling.isEmpty else { return }
        let differing = (toolsets ?? []).filter { $0.enabled != enabled }
        let profile = self.profile
        toolToggling = Set(differing.map(\.name))
        Task {
            for toolset in differing {
                do {
                    try await store.setToolset(toolset.name, enabled: enabled, profile: profile)
                    if profile == self.profile { flipTool(toolset.name, enabled) }
                    toolToggling.remove(toolset.name)
                } catch {
                    toolToggling = []
                    FailureAlert.present(title: "Couldn’t Update \(toolset.label)", reason: CapabilitiesStore.detail(error), detail: "\(error)", from: presenter)
                    return
                }
            }
            toolToggling = []
        }
    }

    // MARK: Plugins (§9)

    func reloadPlugins() async {
        guard let store else { return }
        guard isConnected else { waitForLink(); return }
        let profile = self.profile
        do {
            let list = try await QueryRetry.read { try await store.plugins(profile) }
            guard profile == self.profile else { return }
            plugins = list
            pluginCache[profile] = list
            pluginsError = nil
            pluginsUnavailable = false
            stamp("plugins", profile)
            AppLog.trace("plugins", "plugins load \(AppLog.tag(profile)): \(list.count)")
            Task { await reloadPages() }   // [plugin-pages] beside the list, not before it
        } catch {
            guard profile == self.profile else { return }
            if CapabilitiesStore.isUnknownMethod(error) { pluginsUnavailable = true; plugins = nil; return }
            if plugins == nil { pluginsError = CapabilitiesStore.detail(error) }
            AppLog.note("plugins", "plugins load \(AppLog.tag(profile)) failed: \(CapabilitiesStore.detail(error))")
            if !isConnected { waitForLink() }
        }
    }

    // MARK: [plugin-pages] Pages the bot's plugins add

    func reloadPages() async {
        guard let client = store?.client else { return }
        let profile = self.profile
        let enabled = Set((plugins ?? []).filter(\.enabled).map(\.name))
        var rescanned = pagesRescanned[profile] ?? []
        do {
            let pages = try await DashboardPagesAPI.pages(client, profile: profile, installed: enabled, rescanned: &rescanned)
            pagesRescanned[profile] = rescanned
            guard profile == self.profile else { return }
            dashboardPages = pages
            PluginPagesMore.note(pages, profile: profile)   // [plugin-pages-more]
            AppLog.trace("plugins", "plugin pages \(AppLog.tag(profile)): \(pages.count)")
        } catch {
            pagesRescanned[profile] = rescanned
            guard profile == self.profile else { return }
            AppLog.note("plugins", "plugin pages \(AppLog.tag(profile)) failed: \(CapabilitiesStore.detail(error))")
        }
    }

    /// The page a plugin of this bot adds, if it adds one (the dashboard manifest's name is the plugin's).
    func dashboardPage(for plugin: PluginInfo) -> PluginDashboardPage? {
        guard plugin.enabled else { return nil }
        return dashboardPages?.first { $0.name == plugin.name || $0.name == plugin.key }
    }

    var shownPlugins: [PluginInfo] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return (plugins ?? []).filter { plugin in
            q.isEmpty || [plugin.name, plugin.description].contains { $0.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    func setPlugin(_ plugin: PluginInfo, enabled: Bool) {
        guard let store, let key = plugin.key, !pluginBusy.contains(plugin.name) else { return }
        Haptics.play(.selection)
        flipPlugin(plugin.name, enabled)
        pluginBusy.insert(plugin.name)
        let profile = self.profile
        Task {
            defer { pluginBusy.remove(plugin.name) }
            do {
                let result = try await store.plugin(.toggle(key: key, enable: enabled), profile: profile)
                guard profile == self.profile else { return }
                if !result.missingEnv.isEmpty {
                    pluginNotice = "\(plugin.name) needs \(result.missingEnv.joined(separator: ", ")) before it can run. Add it under Settings › Keys."
                    pluginNeedsKeys = true
                } else if result.needsRestart {
                    pluginNotice = "Restart your gateway to finish."
                    pluginNeedsKeys = false
                }
                pluginWarnings[plugin.name] = result.warnings
                AppLog.trace("plugins", "plugin \(plugin.name) set enabled \(enabled), needs restart \(result.needsRestart), missing env \(result.missingEnv.count)")
            } catch {
                if profile == self.profile { flipPlugin(plugin.name, !enabled) }
                let reason = CapabilitiesStore.detail(error)
                AppLog.note("plugins", "plugin \(plugin.name) set enabled \(enabled) failed: \(reason)")
                FailureAlert.present(title: enabled ? "Couldn’t Turn On \(plugin.name)" : "Couldn’t Turn Off \(plugin.name)",
                                     reason: reason, detail: "\(error)", from: presenter)
            }
        }
    }

    func flipPlugin(_ name: String, _ enabled: Bool) {
        guard let index = plugins?.firstIndex(where: { $0.name == name }) else { return }
        plugins?[index].enabled = enabled
        pluginCache[profile] = plugins
    }

    // MARK: Kanban "Show in Hermes HQ" (§9): the same device setting as Settings › Appearance › Tabs › Kanban Tab

    var kanbanShown: Bool {
        guard let account = services.account else { return false }
        switch KanbanTabOverride.value(for: account) {
        case .on: return true
        case .off: return false
        case .auto: return PagesTabs.decision(account) == .on
        }
    }

    func setKanbanShown(_ on: Bool) {
        guard let account = services.account else { return }
        Haptics.play(.selection)
        KanbanTabOverride.set(on ? .on : .off, for: account)
        kanbanTick += 1
    }
}

enum PluginNoticeAction: Hashable {
    case openKeys
    case setUp(plugin: String)
}
