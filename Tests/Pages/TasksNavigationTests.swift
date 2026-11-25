// Unit tests for Tasks' Grouped Overview and Mac collapsible sidebar layout rules.

import CoreGraphics
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
        #expect(TasksNavigationLayout.title(for: .bots, sections: sections) == "Bots’ Tasks")
        #expect(TasksNavigationLayout.title(for: .list("s1"), sections: sections) == "House")
        #expect(TasksNavigationLayout.title(for: .list("missing"), sections: sections) == "List")

        #expect(TasksNavigationLayout.symbol(for: .today, sections: sections) == "sun.max")
        #expect(TasksNavigationLayout.symbol(for: .upcoming, sections: sections) == "calendar")
        #expect(TasksNavigationLayout.symbol(for: .inbox, sections: sections) == "tray")
        #expect(TasksNavigationLayout.symbol(for: .goals, sections: sections) == "smallcircle.filled.circle")
        #expect(TasksNavigationLayout.symbol(for: .bots, sections: sections) == "person.2")
        #expect(TasksNavigationLayout.symbol(for: .list("s1"), sections: sections) == "house")
        #expect(TasksNavigationLayout.symbol(for: .list("s2"), sections: sections) == TodoListIcons.fallback)
    }
}
