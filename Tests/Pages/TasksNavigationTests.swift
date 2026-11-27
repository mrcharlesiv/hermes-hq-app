// Unit tests for Tasks' Grouped Overview and Mac collapsible sidebar layout rules.

import CoreGraphics
import Foundation
import Testing
@testable import HermesHQNative

struct TasksNavigationTests {
    @Test func macSidebarShowsWhenWideAndLoaded() {
        #expect(TasksNavigationLayout.shouldShowMacSidebar(isMac: true, paneWidth: 900, userCollapsed: false, hasList: true, needsAddOn: false))
        #expect(TasksNavigationLayout.shouldShowMacSidebar(isMac: true, paneWidth: TasksNavigationLayout.sidebarMinPaneWidth, userCollapsed: false, hasList: true, needsAddOn: false))
    }

    @Test func macSidebarAutoCollapsesWhenPaneNarrowsBesideOpenTask() {
        // When a task opens in Mac detail pane, the Tasks column shrinks (~320–440 pt) and auto-collapses the sidebar.
        #expect(!TasksNavigationLayout.shouldShowMacSidebar(isMac: true, paneWidth: 440, userCollapsed: false, hasList: true, needsAddOn: false))
        #expect(!TasksNavigationLayout.shouldShowMacSidebar(isMac: true, paneWidth: 639, userCollapsed: false, hasList: true, needsAddOn: false))
    }

    @Test func macSidebarRespectsUserCollapseAndGuards() {
        #expect(!TasksNavigationLayout.shouldShowMacSidebar(isMac: true, paneWidth: 1000, userCollapsed: true, hasList: true, needsAddOn: false))
        #expect(!TasksNavigationLayout.shouldShowMacSidebar(isMac: true, paneWidth: 1000, userCollapsed: false, hasList: false, needsAddOn: false))
        #expect(!TasksNavigationLayout.shouldShowMacSidebar(isMac: true, paneWidth: 1000, userCollapsed: false, hasList: true, needsAddOn: true))
        #expect(!TasksNavigationLayout.shouldShowMacSidebar(isMac: false, paneWidth: 1000, userCollapsed: false, hasList: true, needsAddOn: false))
    }

    @Test func macTableUsesContentWidthNotWindowWidth() {
        #expect(TasksNavigationLayout.shouldUseMacTable(isMac: true, contentWidth: TasksNavigationLayout.tableMinContentWidth))
        #expect(!TasksNavigationLayout.shouldUseMacTable(isMac: true, contentWidth: TasksNavigationLayout.tableMinContentWidth - 1))
        #expect(!TasksNavigationLayout.shouldUseMacTable(isMac: false, contentWidth: 1200))
    }

    @Test func viewTitlesAndSymbolsResolveBuiltInsAndLists() {
        let sections = [
            TodoUserSection(id: "s1", name: "House", color: "green", icon: "house"),
            TodoUserSection(id: "s2", name: "Plain"),
        ]
        #expect(TasksNavigationLayout.title(for: .today, sections: sections) == "Today")
        #expect(TasksNavigationLayout.title(for: .upcoming, sections: sections) == "Upcoming")
        #expect(TasksNavigationLayout.title(for: .inbox, sections: sections) == "Inbox")
        #expect(TasksNavigationLayout.title(for: .goals, sections: sections) == "Goals")
        #expect(TasksNavigationLayout.title(for: .suggested, sections: sections) == "Suggested")
        #expect(TasksNavigationLayout.title(for: .bots, sections: sections) == "Bots’ Tasks")
        #expect(TasksNavigationLayout.title(for: .list("s1"), sections: sections) == "House")
        #expect(TasksNavigationLayout.title(for: .list("missing"), sections: sections) == "List")

        #expect(TasksNavigationLayout.symbol(for: .today, sections: sections) == "sun.max")
        #expect(TasksNavigationLayout.symbol(for: .upcoming, sections: sections) == "calendar")
        #expect(TasksNavigationLayout.symbol(for: .inbox, sections: sections) == "tray")
        #expect(TasksNavigationLayout.symbol(for: .goals, sections: sections) == "smallcircle.filled.circle")
        #expect(TasksNavigationLayout.symbol(for: .suggested, sections: sections) == "sparkle")
        #expect(TasksNavigationLayout.symbol(for: .bots, sections: sections) == "person.2")
        #expect(TasksNavigationLayout.symbol(for: .list("s1"), sections: sections) == "house")
        #expect(TasksNavigationLayout.symbol(for: .list("s2"), sections: sections) == TodoListIcons.fallback)
    }

    @Test func overviewAgentsModelHandlesSuggestedAndBotsIndependently() {
        #expect(TasksOverviewAgentsModel(suggested: nil, botsCount: nil).isEmpty)
        let suggestedOnly = TasksOverviewAgentsModel(
            suggested: TasksOverviewSuggestedRowModel(count: 3, isOn: true, looking: false),
            botsCount: nil
        )
        #expect(!suggestedOnly.isEmpty)
        #expect(suggestedOnly.suggested?.subtitle == nil)
        #expect(suggestedOnly.suggested?.spoken == "Suggested, 3 ideas")

        let off = TasksOverviewSuggestedRowModel(count: 0, isOn: false, looking: false)
        #expect(off.subtitle == "Off")
        #expect(off.spoken == "Suggested, off")

        let looking = TasksOverviewSuggestedRowModel(count: 1, isOn: true, looking: true)
        #expect(looking.subtitle == "Looking for ideas…")
        #expect(looking.spoken == "Suggested, looking for ideas")

        let botsOnly = TasksOverviewAgentsModel(suggested: nil, botsCount: 2)
        #expect(!botsOnly.isEmpty)
        #expect(botsOnly.botsSpoken == "Bots’ Tasks, 2 tasks")
    }

    @Test func ideasSourcesSummaryAndMultiBotConnectorAutoInclude() throws {
        let connectors = [
            TaskIdeasConnector(id: "composio:gmail", name: "Gmail", kind: "composio", bots: ["default"]),
            TaskIdeasConnector(id: "mcp:notion", name: "Notion", kind: "mcp", bots: ["work"]),
            TaskIdeasConnector(id: "composio:slack", name: "Slack", kind: "composio", bots: ["work"]),
        ]
        var sources = TodoIdeasSources()
        #expect(sources.chats && sources.memory && !sources.files && !sources.web && sources.connectors.isEmpty)
        #expect(TaskIdeasSummary.activeSourcesLabel(sources: sources, available: connectors) == "Chats, Memory")

        // Turning on Notion (owned by "work") automatically includes "work" in activeBots for multi-bot sweeps.
        var activeBots = ["default"]
        TaskIdeasSummary.toggleConnector("mcp:notion", on: true, connector: connectors[1], sources: &sources, activeBots: &activeBots)
        #expect(sources.connectors == ["mcp:notion"])
        #expect(activeBots == ["default", "work"])
        #expect(TaskIdeasSummary.activeSourcesLabel(sources: sources, available: connectors) == "Chats, Memory, Notion")

        // Turning on Gmail (owned by "default", already active) keeps activeBots deduplicated.
        TaskIdeasSummary.toggleConnector("composio:gmail", on: true, connector: connectors[0], sources: &sources, activeBots: &activeBots)
        #expect(activeBots == ["default", "work"])
        #expect(TaskIdeasSummary.activeSourcesLabel(sources: sources, available: connectors) == "Chats, Memory, Notion, Gmail")

        // Turning off Notion removes it cleanly.
        TaskIdeasSummary.toggleConnector("mcp:notion", on: false, connector: connectors[1], sources: &sources, activeBots: &activeBots)
        #expect(sources.connectors == ["composio:gmail"])

        // Bot and chat-bot summary formatting.
        let roster = [(id: "default", name: "Hermes"), (id: "work", name: "Work"), (id: "research", name: "Research")]
        #expect(TaskIdeasSummary.activeBotsLabel(active: ["default"], bots: roster) == "Hermes")
        #expect(TaskIdeasSummary.activeBotsLabel(active: ["default", "work"], bots: roster) == "Hermes & Work")
        #expect(TaskIdeasSummary.activeBotsLabel(active: ["default", "work", "research"], bots: roster) == "Hermes, Work +1")
        #expect(TaskIdeasSummary.chatBotsSubtitle(sources: sources, bots: roster) == "All bots")
        sources.chatBots = ["default", "work"]
        #expect(TaskIdeasSummary.chatBotsSubtitle(sources: sources, bots: roster) == "Hermes, Work · 1 bot excluded")
        sources.chats = false
        #expect(TaskIdeasSummary.chatBotsSubtitle(sources: sources, bots: roster) == "Off · blocked during runs")

        // JSON round-trip for TodoSettings with ideas_bots, ideas_sources, and ideas_note.
        var settings = TodoSettings()
        settings.ideas = true
        settings.ideasBot = "default"
        settings.ideasBots = ["default", "work"]
        settings.ideasSources = sources
        settings.ideasNote = "Check Notion Inbox. Skip newsletters."
        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(TodoSettings.self, from: encoded)
        #expect(decoded == settings)
        #expect(decoded.activeIdeasBots == ["default", "work"])
    }

    @Test func scrollEdgeFadeSkipsMaskOnLiveLiquidGlassRails() {
        // Native Liquid Glass pill rails must not wrap GlassEffectContainer in .mask(...), which flattens untinted glass.
        #expect(!ScrollEdgeFadeRule.appliesMask(width: 20, preservesGlass: true, desktop: false, flatPicks: false, flatPills: false))
        // Desktop look, flat picks, and non-glass horizontal strips keep the fade mask.
        #expect(ScrollEdgeFadeRule.appliesMask(width: 20, preservesGlass: true, desktop: true, flatPicks: false, flatPills: false))
        #expect(ScrollEdgeFadeRule.appliesMask(width: 20, preservesGlass: true, desktop: false, flatPicks: true, flatPills: false))
        #expect(ScrollEdgeFadeRule.appliesMask(width: 20, preservesGlass: true, desktop: false, flatPicks: false, flatPills: true))
        #expect(ScrollEdgeFadeRule.appliesMask(width: 20, preservesGlass: false, desktop: false, flatPicks: false, flatPills: false))
        #expect(!ScrollEdgeFadeRule.appliesMask(width: 0, preservesGlass: false, desktop: true, flatPicks: false, flatPills: false))
    }

    @Test func sessionsPillsSwitchUsesRecessedGlassTrackInNativeLiquidGlass() {
        #expect(SessionsPillsSwitch.usesRecessedGlassTrack(desktop: false, flatPicks: false, flatPills: false))
        #expect(!SessionsPillsSwitch.usesRecessedGlassTrack(desktop: true, flatPicks: false, flatPills: false))
        #expect(!SessionsPillsSwitch.usesRecessedGlassTrack(desktop: false, flatPicks: true, flatPills: false))
        #expect(!SessionsPillsSwitch.usesRecessedGlassTrack(desktop: false, flatPicks: false, flatPills: true))
    }
}
