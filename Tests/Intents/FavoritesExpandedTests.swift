// [quick-actions] Unit tests for expanded Favorites: new live widget & shortcut kinds, full size vocabulary,
// responsive 2D Bento layout (`QuickTileLayout`), multi-page spaces, collapsible sections, presets, routines,
// gateway filtering, and cross-device sync (`FavoritesSync`).

import CoreGraphics
import Foundation
import Testing
@testable import HermesHQNative

@Suite struct FavoritesExpandedModelTests {
    @Test func newKindsRoundTripThroughStore() throws {
        let box = IntentsDefaults()
        var list = QuickTileList()

        var tasks = QuickTile(id: "t-tasks", kind: .tasks, name: "Today", size: .large)
        tasks.taskView = "today"
        tasks.taskViewName = "Today"

        var goal = QuickTile(id: "t-goal", kind: .goal, name: "Ship v2", size: .wide)
        goal.goalId = "g1"
        goal.goalName = "Ship v2"

        var routine = QuickTile(id: "t-routine", kind: .routine, name: "Morning")
        routine.steps = [
            QuickRoutineStep(id: "s1", kind: .runJob, job: "otto|brief", jobName: "Brief"),
            QuickRoutineStep(id: "s2", kind: .openPage, page: "tasks", pageName: "Tasks"),
        ]

        var link = QuickTile(id: "t-link", kind: .link, name: "Docs", size: .mini)
        link.url = "https://example.com/docs"

        var sec = QuickTile(id: "t-sec", kind: .section, name: "Work")
        sec.collapsed = true

        var usage = QuickTile(id: "t-usage", kind: .usage, name: "Usage", size: .tallCard)
        usage.days = 30

        list.add(tasks)
        list.add(goal)
        list.add(routine)
        list.add(link)
        list.add(sec)
        list.add(usage)

        #expect(QuickTileStore.save(list, box.defaults))
        let back = QuickTileStore.load(box.defaults)
        #expect(back.tiles == list.tiles)
        #expect(back.tiles[0].effectiveSize == .large && back.tiles[0].wide)
        #expect(back.tiles[3].effectiveSize == .mini && !back.tiles[3].wide)
        #expect(back.tiles[4].collapsed == true)
        #expect(back.tiles[5].effectiveSize == .tallCard && back.tiles[5].days == 30)
        #expect(back.tiles[2].subtitle(botName: nil) == "2 steps")
        #expect(back.tiles[3].subtitle(botName: nil) == "example.com")
    }

    @Test func routesAndMissingRulesForNewKinds() {
        let world = QuickTileWorld(
            bots: ["otto": "Otto"],
            jobs: ["otto|brief"],
            pages: ["tasks": "Tasks"],
            pins: ["p1": "Revenue"],
            rooms: ["r1": "Design Team"],
            sessions: ["sess-1": "Sprint"],
            goals: ["g1": "Launch"],
            taskLists: ["l1": "Errands"],
            dashboardPages: ["main": "Main", "ops": "Ops"],
            boards: ["default": "Default"],
            tasksEnabled: true,
            currentGatewayId: "gw-1"
        )

        var tasksTile = QuickTile(kind: .tasks)
        tasksTile.taskView = "list:l1"
        tasksTile.taskViewName = "Errands"
        #expect(QuickTileRoute.make(tasksTile, world: world) == .tasksView(key: "list:l1"))

        tasksTile.taskView = "list:missing"
        #expect(QuickTileRules.missing(tasksTile, world: world) == "“Errands” isn’t on this gateway.")

        var goalTile = QuickTile(kind: .goal, name: "Launch")
        goalTile.goalId = "g1"
        goalTile.goalName = "Launch"
        #expect(QuickTileRoute.make(goalTile, world: world) == .goal(id: "g1"))

        var roomTile = QuickTile(kind: .groupChat, name: "Design Team")
        roomTile.roomKey = "r1"
        #expect(QuickTileRoute.make(roomTile, world: world) == .groupChat(key: "r1"))

        var cmdTile = QuickTile(kind: .slashCommand, name: "/usage")
        cmdTile.bot = "otto"
        cmdTile.command = "/usage"
        #expect(QuickTileRoute.make(cmdTile, world: world) == .slashCommand(profile: "otto", command: "/usage"))

        var linkTile = QuickTile(kind: .link, name: "Example")
        linkTile.url = "example.com/path"
        #expect(QuickTileRoute.make(linkTile, world: world) == .link(URL(string: "https://example.com/path")!))

        var folderTile = QuickTile(kind: .filesFolder, name: "Site")
        folderTile.folderPath = "/Users/me/site"
        #expect(QuickTileRoute.make(folderTile, world: world) == .filesFolder(profile: nil, path: "/Users/me/site"))

        var dashPage = QuickTile(kind: .dashboardPage, name: "Ops")
        dashPage.dashboardPageId = "ops"
        #expect(QuickTileRoute.make(dashPage, world: world) == .dashboardPage(id: "ops"))

        var bgRoutine = QuickTile(kind: .routine, name: "Daily")
        bgRoutine.steps = [QuickRoutineStep(kind: .runJob, job: "otto|brief", jobName: "Brief")]
        #expect(QuickTileRoute.make(bgRoutine, world: world).staysOnPage)

        bgRoutine.steps?.append(QuickRoutineStep(kind: .openPage, page: "tasks", pageName: "Tasks"))
        #expect(!QuickTileRoute.make(bgRoutine, world: world).staysOnPage)

        // Gateway scope filtering
        var otherGw = QuickTile(kind: .memo, name: "Memo")
        otherGw.bot = "otto"
        otherGw.gatewayId = "gw-2"
        #expect(QuickTileRules.isOtherGateway(otherGw, world: world))
        otherGw.gatewayId = "gw-1"
        #expect(!QuickTileRules.isOtherGateway(otherGw, world: world))
    }

    @Test func sizesRespectKindCapabilities() {
        var list = QuickTileList(tiles: [
            QuickTile(id: "action", kind: .memo),
            QuickTile(id: "widget", kind: .tasks),
            QuickTile(id: "pic", kind: .dashboardTile),
        ], seeded: true)

        list.setSize("action", .mini)
        #expect(list.tiles[0].effectiveSize == .mini)
        list.setSize("action", .large)   // actions cannot be 2×2
        #expect(list.tiles[0].effectiveSize == .mini)

        list.setSize("widget", .mini)    // widgets cannot be mini
        #expect(list.tiles[1].effectiveSize == .small)
        list.setSize("widget", .large)
        #expect(list.tiles[1].effectiveSize == .large && list.tiles[1].wide)
        list.setShort("widget", true)    // widgets are never Short
        #expect(!list.tiles[1].short)

        list.setSize("pic", .tallCard)
        #expect(list.tiles[2].effectiveSize == .tallCard && !list.tiles[2].wide)
    }

    @Test func pagesSectionsAndDuplicateWorkCleanly() {
        var list = QuickTileList(tiles: [
            QuickTile(id: "sec1", kind: .section, name: "Morning"),
            QuickTile(id: "a", kind: .search, name: "Search"),
            QuickTile(id: "b", kind: .addTask, name: "Task"),
            QuickTile(id: "sec2", kind: .section, name: "Later"),
            QuickTile(id: "c", kind: .needsYou, name: "Needs You"),
        ], seeded: true)

        #expect(list.sectionItemCount("sec1") == 2)
        #expect(list.visibleTiles().map(\.id) == ["sec1", "a", "b", "sec2", "c"])
        list.toggleSection("sec1")
        #expect(list.visibleTiles().map(\.id) == ["sec1", "sec2", "c"])
        #expect(list.visibleTiles(includeCollapsed: true).count == 5)

        let copy = list.duplicate("a")
        #expect(copy != nil && copy?.name == "Search Copy")

        let work = list.addPage(name: "Work", symbol: "briefcase.fill")
        #expect(list.hasMultiplePages && list.allPages.map(\.name) == ["Home", "Work"])
        list.moveTile("c", toPage: work.id)
        #expect(list.tiles(on: work.id).map(\.id) == ["c"])
        #expect(!list.tiles(on: FavoritePage.mainId).contains { $0.id == "c" })

        list.renamePage(work.id, name: "Deep Work")
        #expect(list.allPages.last?.name == "Deep Work")

        list.deletePage(work.id, deleteTiles: false)
        #expect(!list.hasMultiplePages)
        #expect(list.tiles(on: FavoritePage.mainId).contains { $0.id == "c" })
    }

    @Test func presetsProduceValidTiles() {
        for preset in FavoritePreset.allCases {
            let tiles = preset.tiles(bot: (profile: "otto", name: "Otto"), goal: (id: "g1", title: "Ship"))
            #expect(!tiles.isEmpty, "preset \(preset.rawValue) has tiles")
        }
    }

    @Test func favoritesV2LiveCardsRoundTripAndRoute() {
        let box = IntentsDefaults()
        var list = QuickTileList()

        let approvals = QuickTile(id: "t-app", kind: .approvals, name: "Approvals", size: .wide)
        let activeRuns = QuickTile(id: "t-act", kind: .activeRuns, name: "Active Now", size: .wide)
        var inlineAsk = QuickTile(id: "t-ask", kind: .inlineAsk, name: "Ask Otto", size: .wide)
        inlineAsk.bot = "otto"
        inlineAsk.botName = "Otto"
        var peek = QuickTile(id: "t-peek", kind: .livePeek, name: "Browser & Screen", size: .wide)
        peek.bot = "otto"
        peek.botName = "Otto"

        list.add(approvals)
        list.add(activeRuns)
        list.add(inlineAsk)
        list.add(peek)

        #expect(QuickTileStore.save(list, box.defaults))
        let back = QuickTileStore.load(box.defaults)
        #expect(back.tiles == list.tiles)
        #expect(QuickTileKind.approvals.isLiveCard && QuickTileKind.activeRuns.isLiveCard)
        #expect(QuickTileKind.inlineAsk.isLiveCard && QuickTileKind.inlineAsk.needsBot)
        #expect(QuickTileKind.livePeek.isLiveCard && !QuickTileKind.livePeek.needsBot)

        let world = QuickTileWorld(bots: ["otto": "Otto"], currentGatewayId: "gw-1")
        #expect(QuickTileRoute.make(approvals, world: world) == .approvals)
        #expect(QuickTileRoute.make(activeRuns, world: world) == .activeRuns)
        #expect(QuickTileRoute.make(inlineAsk, world: world) == .inlineAsk(profile: "otto"))
        #expect(QuickTileRoute.make(peek, world: world) == .livePeek(profile: "otto"))
    }
}

@Suite struct FavoritesBentoLayoutTests {
    private func metrics(width: CGFloat, stacked: Bool = false) -> QuickTileLayout.Metrics {
        QuickTileLayout.Metrics(
            width: width, gap: 12, stacked: stacked, scale: 1,
            actionTallHeight: 120, actionShortHeight: 60, miniHeight: 74, sectionHeight: 34, dashboardNameHeight: 20
        )
    }

    @Test func compactWideHeightEliminatesEmptyHoleOnHorizontalLiveCards() {
        var bot = QuickTile(id: "b", kind: .botCard, name: "Otto", size: .wide)
        bot.bot = "otto"
        var goal = QuickTile(id: "g", kind: .goal, name: "Launch", size: .wide)
        goal.goalId = "g1"
        var singleJob = QuickTile(id: "j1", kind: .jobCard, name: "Brief", size: .wide)
        singleJob.job = "otto|brief"
        let upcomingJobs = QuickTile(id: "j2", kind: .jobCard, name: "Upcoming", size: .wide)
        let today = QuickTile(id: "t", kind: .tasks, name: "Today", size: .wide)
        let inlineAsk = QuickTile(id: "ask", kind: .inlineAsk, name: "Ask Otto", size: .wide)
        let peek = QuickTile(id: "pk", kind: .livePeek, name: "Browser", size: .wide)
        let gwSmall = QuickTile(id: "gw", kind: .gatewayStatus, name: "Gateway", size: .small)

        #expect(QuickTileLayout.usesCompactWideHeight(bot))
        #expect(QuickTileLayout.usesCompactWideHeight(goal))
        #expect(QuickTileLayout.usesCompactWideHeight(singleJob))
        #expect(QuickTileLayout.usesCompactWideHeight(inlineAsk))
        #expect(QuickTileLayout.usesCompactWideHeight(peek))
        #expect(!QuickTileLayout.usesCompactWideHeight(upcomingJobs))
        #expect(!QuickTileLayout.usesCompactWideHeight(today))
        #expect(!QuickTileLayout.usesCompactWideHeight(gwSmall))

        let layout = QuickTileLayout.compute([bot, today, inlineAsk, gwSmall], metrics: metrics(width: 370))
        let hBot = layout.placements[0].frame.height
        let hToday = layout.placements[1].frame.height
        let hAsk = layout.placements[2].frame.height
        let hGw = layout.placements[3].frame.height
        #expect(hBot == 134, "compact Wide cards sit tightly at 134pt instead of 179pt square")
        #expect(hAsk == 108, "tight single-control Wide cards (Inline Ask / Live Peek) sit at 108pt with zero dead space")
        #expect(QuickTileLayout.usesListWideHeight(today) && QuickTileLayout.usesListWideHeight(upcomingJobs))
        #expect(!QuickTileLayout.usesListWideHeight(singleJob) && !QuickTileLayout.usesListWideHeight(bot))
        #expect(hToday == 224, "multi-row Wide list cards get 224pt so 2-line rows + footer never overflow")
        #expect(hGw > hBot + 30 && hGw < hToday, "Small 1x1 square widgets stay square")
    }

    @Test @MainActor func tasksCardPacksRowsToFitHeightBudgetWithoutOverflowOrVoid() {
        // 1-line tasks pack 5 rows + "+N more" inside a Wide 224pt card (no empty bottom void).
        #expect(FavoriteTasksCard.visibleRowCount(hasNotes: Array(repeating: false, count: 10), total: 22, size: .wide) == 5)
        // 2-line tasks with overflow pack 3 rows + "+N more" so the footer stays cleanly inside the card.
        #expect(FavoriteTasksCard.visibleRowCount(hasNotes: Array(repeating: true, count: 10), total: 17, size: .wide) == 3)
        // Exactly 4 two-line tasks fit all 4 rows cleanly when no "+N more" footer is needed.
        #expect(FavoriteTasksCard.visibleRowCount(hasNotes: Array(repeating: true, count: 4), total: 4, size: .wide) == 4)
        // Mixed 1-line and 2-line rows adapt dynamically.
        #expect(FavoriteTasksCard.visibleRowCount(hasNotes: [false, true, false, true, true], total: 12, size: .wide) == 4)
        // Small cards stay compact at 2 rows beneath the headline count.
        #expect(FavoriteTasksCard.visibleRowCount(hasNotes: Array(repeating: true, count: 6), total: 6, size: .small) == 2)
        // Large 2-row cards expand to 7 two-line or 10 one-line rows.
        #expect(FavoriteTasksCard.visibleRowCount(hasNotes: Array(repeating: true, count: 12), total: 17, size: .large) == 7)
        #expect(FavoriteTasksCard.visibleRowCount(hasNotes: Array(repeating: false, count: 15), total: 22, size: .large) == 10)
    }

    @Test func responsiveColumnCountsScaleAcrossDevices() {
        #expect(QuickTileLayout.columns(width: 370, gap: 12, stacked: true) == 1)
        #expect(QuickTileLayout.columns(width: 370, gap: 12, stacked: false) == 2)
        #expect(QuickTileLayout.columns(width: 720, gap: 12, stacked: false) == 3)
        #expect(QuickTileLayout.columns(width: 960, gap: 12, stacked: false) == 4)
        #expect(QuickTileLayout.columns(width: 1200, gap: 12, stacked: false) == 5)
    }

    @Test func miniStripPacksFourAcrossOnPhone() {
        let tiles = (0..<4).map { QuickTile(id: "m\($0)", kind: .memo, size: .mini) }
        let layout = QuickTileLayout.compute(tiles, metrics: metrics(width: 370))
        #expect(layout.placements.count == 4)
        #expect(Set(layout.placements.map { $0.frame.minY }).count == 1, "all 4 sit on one strip row")
        #expect(layout.placements[0].frame.height == 74)
    }

    @Test func tallCardPacksTwoSmallTilesBesideIt() {
        let tiles = [
            QuickTile(id: "tall", kind: .tasks, size: .tallCard),
            QuickTile(id: "s1", kind: .gatewayStatus, size: .small),
            QuickTile(id: "s2", kind: .usage, size: .small),
        ]
        let layout = QuickTileLayout.compute(tiles, metrics: metrics(width: 370))
        let fTall = layout.placements[0].frame
        let f1 = layout.placements[1].frame
        let f2 = layout.placements[2].frame
        #expect(fTall.minX == 0 && f1.minX > fTall.maxX && f2.minX > fTall.maxX)
        #expect(f1.minY == fTall.minY)
        #expect(f2.minY > f1.maxY && abs(f2.maxY - fTall.maxY) < 2)
    }

    @Test func standardShortTileRowPreservesExactOrderAndShortHeight() {
        var memo = QuickTile(id: "m", kind: .memo, wide: true)
        var talk = QuickTile(id: "t", kind: .talk)
        talk.short = true
        let chat = QuickTile(id: "c", kind: .newChat, wide: true)
        let search = QuickTile(id: "s", kind: .search)
        memo.wide = true
        let layout = QuickTileLayout.compute([memo, talk, chat, search], metrics: metrics(width: 370))
        // talk sits alone before chat (Wide) and keeps its Short height (60), never stretched by search below it.
        #expect(layout.placements[1].frame.height == 60)
        #expect(layout.placements[1].frame.minY < layout.placements[2].frame.minY)
        #expect(layout.placements[2].frame.minY < layout.placements[3].frame.minY)
    }

    @Test func shortTileSharingRowWithTallNeighborKeepsShortHeight() {
        let memo = QuickTile(id: "m", kind: .memo)
        var talk = QuickTile(id: "t", kind: .talk)
        talk.short = true
        let layout = QuickTileLayout.compute([memo, talk], metrics: metrics(width: 370))
        #expect(layout.placements[0].frame.minY == layout.placements[1].frame.minY)
        #expect(layout.placements[0].frame.height == 120)
        #expect(layout.placements[1].frame.height == 60)
    }
}

@MainActor @Suite struct FavoritesSyncTests {
    @Test func firstContactReplacesUneditedStarterAndRebaseMergesThreeWay() {
        let box = IntentsDefaults()
        let sync = FavoritesSync(defaults: box.defaults)

        // Unedited starter locally
        let starter = QuickTileList(tiles: QuickTileStore.starter(bot: "otto", name: "Otto"), seeded: true)
        QuickTileStore.save(starter, box.defaults, notifySync: false)

        // Remote has custom tiles + a Work page
        let remoteBox = IntentsDefaults()
        var remoteList = QuickTileList()
        let work = remoteList.addPage(name: "Work")
        var t1 = QuickTile(id: "custom-1", kind: .needsYou, name: "Needs You", wide: true)
        t1.pageId = work.id
        remoteList.add(t1)
        QuickTileStore.save(remoteList, remoteBox.defaults, notifySync: false)
        let remoteValue = FavoritesSync(defaults: remoteBox.defaults).syncValue()

        sync.adoptSynced(remoteValue, merge: .firstContact, base: nil)
        let afterFirst = QuickTileStore.load(box.defaults)
        #expect(afterFirst.tiles.map(\.id) == ["custom-1"])
        #expect(afterFirst.pages.map(\.name) == ["Home", "Work"])

        // Three-way rebase: local adds local-2, remote adds remote-2
        let baseValue = sync.syncValue()
        var localEdit = afterFirst
        localEdit.add(QuickTile(id: "local-2", kind: .usage, name: "Usage"))
        QuickTileStore.save(localEdit, box.defaults, notifySync: false)

        remoteList.add(QuickTile(id: "remote-2", kind: .gatewayStatus, name: "Status"))
        QuickTileStore.save(remoteList, remoteBox.defaults, notifySync: false)
        let nextRemote = FavoritesSync(defaults: remoteBox.defaults).syncValue()

        sync.adoptSynced(nextRemote, merge: .rebase, base: baseValue)
        let merged = QuickTileStore.load(box.defaults)
        #expect(Set(merged.tiles.map(\.id)) == Set(["custom-1", "local-2", "remote-2"]))
    }
}
