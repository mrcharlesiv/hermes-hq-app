// [quick-actions] More › Quick Actions (docs/spec/3x-morepages.md §25) against the morepages stand-in: the starter
// set, Add Action and Set Up, rename, Wide, reorder, remove, a tile whose bot isn't there, and the list kept across a
// relaunch. Run: HQN_MOREPAGES_ONLY="QuickActionsUITests" scripts/e2e-morepages.sh <udid>
// [favorites-live-tiles] And a Dashboard tile on Favorites (§25 Q15–Q21): `testQuickActions_DashboardTile`.

import XCTest

final class QuickActionsUITests: MorePagesCase {
    @MainActor private func tile(_ id: String) -> XCUIElement { app.cells["quick-tile-\(id)"] }
    @MainActor private var grid: XCUIElement { app.collectionViews["quick-actions.grid"] }

    /// The tiles top to bottom, left to right (by where they are drawn).
    @MainActor private var shownIDs: [String] {
        grid.cells.allElementsBoundByIndex.filter { $0.identifier.hasPrefix("quick-tile-") && $0.exists }
            .sorted { ($0.frame.minY.rounded(), $0.frame.minX) < ($1.frame.minY.rounded(), $1.frame.minX) }
            .map { String($0.identifier.dropFirst("quick-tile-".count)) }
    }

    @MainActor private func edit(_ word: String) {
        let button = app.buttons.matching(identifier: "quick-actions.edit").matching(NSPredicate(format: "label == %@", word)).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "the bar's \(word)")
        button.tap()
    }

    /// A debug hook word on the running app (App/Intents/IntentsDebugHooks.swift), as the intents tests send them.
    @MainActor private func hook(_ word: String) {
        let scheme = ProcessInfo.processInfo.environment["HQN_UI_SCHEME"] ?? "hermeshq-native"
        XCUIDevice.shared.system.open(URL(string: "\(scheme)://debug-intent/\(word)")!)
        let open = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"]
        if open.waitForExistence(timeout: 4) { open.tap() }
        Thread.sleep(forTimeInterval: 0.8)
    }

    @MainActor func testQuickActions_AddRenameWideReorderRemoveKeep() throws {
        launchSignedIn(["-HQDebugResetQuickActions", "YES"])
        tab("More")
        XCTAssertTrue(revealMore("quick-actions").exists, "Quick Actions is in More")
        openMore("quick-actions")
        XCTAssertTrue(app.navigationBars["Favorites"].waitForExistence(timeout: 10), "More › Quick Actions opens its page")
        // The starter set, from the roster's first bot.
        XCTAssertTrue(tile("starter-memo").waitForExistence(timeout: 10), "the starter set")
        XCTAssertEqual(shownIDs, ["starter-memo", "starter-talk", "starter-new-chat", "starter-add-task", "starter-search"])
        XCTAssertEqual(tile("starter-memo").label, "Memo, to Hermes")
        XCTAssertEqual(tile("starter-new-chat").label, "New Chat, with Hermes")
        XCTAssertGreaterThan(tile("starter-new-chat").frame.width, tile("starter-memo").frame.width * 1.6, "New Chat is Wide")
        shot("quick-actions-seeded")

        // Edit: the + tile, then Add Action › Open a Chat › Set Up, renamed and recoloured.
        edit("Edit")
        let add = app.cells["quick-actions.add-tile"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), "Edit shows ＋ Add Action")
        shot("quick-actions-editing")
        reach(add)
        add.tap()
        XCTAssertTrue(app.navigationBars["Add Action"].waitForExistence(timeout: 5), "＋ opens Add Action")
        for id in ["new-chat", "memo", "talk", "send", "open-chat", "add-task", "run-job"] {
            XCTAssertTrue(app.buttons["quick.add.\(id)"].waitForExistence(timeout: 2), "Add Action lists \(id)")
        }
        shot("quick-actions-add-action")
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 3), "a search field")
        XCTAssertEqual(search.placeholderValue, "Search actions and pages")
        search.tap()
        search.typeText("open a")
        let openChat = app.buttons["quick.add.open-chat"]
        XCTAssertTrue(openChat.waitForExistence(timeout: 5), "the search finds Open a Chat")
        XCTAssertFalse(app.buttons["quick.add.memo"].exists, "and only what matches")
        openChat.tap()
        XCTAssertTrue(app.navigationBars["Set Up"].waitForExistence(timeout: 5), "a choice opens Set Up")
        let name = app.textFields["quick.setup.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "Hermes", "the name starts as the bot's")
        shot("quick-actions-setup")
        name.tap()
        name.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        name.typeText(XCUIKeyboardKey.delete.rawValue)
        name.typeText("Ping Hermes")
        let purple = app.buttons["quick.setup.color.indigo"]
        for _ in 0..<5 where !purple.isHittable { app.swipeUp(velocity: .slow) }
        purple.tap()
        app.buttons["quick.setup.save"].tap()
        XCTAssertTrue(waitUntil(6) { self.shownIDs.count == 6 }, "the tile is added: \(shownIDs)")
        let added = shownIDs.last ?? ""
        XCTAssertEqual(tile(added).label, "Ping Hermes, chat with Hermes")

        // Rename: a tap on a tile while editing reopens Set Up with Save.
        tile("starter-talk").tap()
        XCTAssertTrue(app.navigationBars["Edit Action"].waitForExistence(timeout: 5), "Edit Action")
        let rename = app.textFields["quick.setup.name"]
        rename.tap()
        rename.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        rename.typeText(XCUIKeyboardKey.delete.rawValue)
        rename.typeText("Talk Now")
        // Size (owner 2026-11-21: "There isn't a way to change the size of the card."): Set Up's Size picks Wide.
        let size = app.segmentedControls["quick.setup.size"]
        for _ in 0..<5 where !size.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(size.isHittable, "Set Up shows Size")
        XCTAssertTrue(app.segmentedControls["quick.setup.height"].exists, "and Height (Tall / Short)")
        size.buttons["Wide"].tap()
        shot("quick-actions-setup-size")
        app.buttons["quick.setup.save"].tap()
        XCTAssertTrue(waitUntil(5) { self.tile("starter-talk").label == "Talk Now, with Hermes" }, tile("starter-talk").label)
        XCTAssertTrue(waitUntil(5) { self.tile("starter-talk").frame.width > self.tile("starter-memo").frame.width * 1.6 },
                      "Size › Wide makes Talk Wide")
        shot("quick-actions-editing-resize")
        // Edit's corner handle (bottom right) drags (owner 2026-11-21: "click and drag from the corner to resize"):
        // left makes Talk Small, up makes it Short, down Tall again.
        func handle() -> XCUICoordinate {
            tile("starter-talk").coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -6, dy: -6))
        }
        let wideWidth = tile("starter-talk").frame.width
        handle().press(forDuration: 0.05, thenDragTo: handle().withOffset(CGVector(dx: -wideWidth * 0.45, dy: 0)))
        XCTAssertTrue(waitUntil(5) { abs(self.tile("starter-talk").frame.width - self.tile("starter-memo").frame.width) < 2 },
                      "dragging the corner left makes Talk Small")
        let tall = tile("starter-talk").frame.height
        handle().press(forDuration: 0.05, thenDragTo: handle().withOffset(CGVector(dx: 0, dy: -tall * 0.6)))
        XCTAssertTrue(waitUntil(5) { self.tile("starter-talk").frame.height < tall * 0.75 }, "dragging the corner up makes Talk Short")
        shot("quick-actions-drag-short")
        handle().press(forDuration: 0.05, thenDragTo: handle().withOffset(CGVector(dx: 0, dy: tall * 0.6)))
        XCTAssertTrue(waitUntil(5) { self.tile("starter-talk").frame.height > tall * 0.9 }, "and down makes it Tall again")

        // Reorder: Search Chats dragged to the front.
        tile("starter-search").press(forDuration: 0.9, thenDragTo: tile("starter-memo"))
        XCTAssertTrue(waitUntil(5) { self.shownIDs.first == "starter-search" }, "dragged first: \(shownIDs)")
        XCTAssertTrue(waitUntil(3) { self.tile("starter-new-chat").frame.width > self.tile("starter-talk").frame.width * 1.6 },
                      "New Chat stays Wide after the drag (the widths follow their tiles)")

        // Remove: the − badge.
        let task = tile("starter-add-task")
        task.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 6, dy: 6)).tap()
        XCTAssertTrue(waitUntil(5) { !task.exists }, "− removes Add Task")
        edit("Done")
        XCTAssertFalse(add.exists, "Done ends editing")

        // Wide: holding a tile offers Small, Wide, Edit… and Remove.
        tile("starter-memo").press(forDuration: 1.2)
        for word in ["Small", "Wide", "Tall", "Short", "Edit…", "Remove"] {
            XCTAssertTrue(app.buttons[word].waitForExistence(timeout: 3), "the hold menu offers \(word)")
        }
        shot("quick-actions-hold-menu")
        app.buttons["Wide"].tap()
        XCTAssertTrue(waitUntil(5) { self.tile("starter-memo").frame.width > self.tile("starter-talk").frame.width * 1.6 }, "Memo is Wide")

        // Short (owner 2026-11-21: "I also want to be able to change the height to make them shorter."): Talk sits
        // alone in its row (New Chat after it is Wide), so its own height shows.
        let tallHeight = tile("starter-talk").frame.height
        tile("starter-talk").press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Short"].waitForExistence(timeout: 3))
        app.buttons["Short"].tap()
        XCTAssertTrue(waitUntil(5) { self.tile("starter-talk").frame.height < tallHeight * 0.75 },
                      "Short makes Talk shorter: \(tile("starter-talk").frame.height) vs \(tallHeight)")
        shot("quick-actions-short-tile")

        // A tile whose bot isn't on this gateway: drawn switched off, and a tap says why.
        hook("quick-tile-add:talk:juno")
        let missing = tile("debug-talk-juno")
        XCTAssertTrue(missing.waitForExistence(timeout: 8), "the tile is on the page")
        XCTAssertEqual(missing.value as? String, "Unavailable")
        reach(missing)
        shot("quick-actions-disabled-tile")
        missing.tap()
        let notice = app.descendants(matching: .any)["pages.notice"]
        XCTAssertTrue(waitUntil(5) { notice.exists && notice.label.contains("Juno isn’t on this gateway.") }, "one sentence")
        XCTAssertTrue(grid.exists, "and the page stays")

        let order = shownIDs
        relaunch()
        openMore("quick-actions")
        XCTAssertTrue(tile("starter-search").waitForExistence(timeout: 10), "the list survives a relaunch")
        XCTAssertEqual(shownIDs, order, "in its order, never seeded again")
        XCTAssertEqual(tile("starter-talk").label, "Talk Now, with Hermes")
        XCTAssertTrue(tile("starter-memo").frame.width > tile("starter-talk").frame.width * 1.6, "Memo stays Wide")
        XCTAssertLessThan(tile("starter-talk").frame.height, tile("starter-memo").frame.height * 0.75, "Talk stays Short")
        XCTAssertFalse(app.cells["quick-tile-starter-add-task"].exists, "Add Task stays removed")
    }

    /// The page's looks for the report: as the shortcut opens it (a sheet over the top), the setup form, and under
    /// Desktop Look. Run alone with HQN_TEXT_SIZE for the largest text (one column, icons beside the words).
    @MainActor func testQuickActions_Looks() throws {
        launchSignedIn(["-HQDebugResetQuickActions", "YES", "-HQDebugDesktopLook", "NO"])
        hook("quick-actions-intent")
        XCTAssertTrue(app.otherElements["quick-actions.sheet"].waitForExistence(timeout: 10) || grid.waitForExistence(timeout: 2),
                      "the intent opens the page as a sheet")
        XCTAssertTrue(tile("starter-memo").waitForExistence(timeout: 10), "the starter set")
        shot("quick-actions-sheet")
        tile("starter-search").tap()
        XCTAssertTrue(grid.waitForNonExistence(timeout: 8), "a foreground tile closes the page and goes")

        // Desktop Look has no tab bar for `launchSignedIn` to wait on: the same sign-in, relaunched, and the shortcut.
        // `relaunch` drops HQN_TEXT_SIZE, so it is passed again here.
        let size = ProcessInfo.processInfo.environment["HQN_TEXT_SIZE"].flatMap { $0.isEmpty ? nil : $0 }
        relaunch(["-HQDebugDesktopLook", "YES"] + (size.map { ["-UIPreferredContentSizeCategoryName", $0] } ?? []))
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        hook("quick-actions-intent")
        XCTAssertTrue(tile("starter-memo").waitForExistence(timeout: 15), "the page under Desktop Look")
        shot("quick-actions-desktop-look")
        edit("Edit")
        XCTAssertTrue(app.cells["quick-actions.add-tile"].waitForExistence(timeout: 5))
        shot("quick-actions-desktop-look-editing")
        edit("Done")
        relaunch(["-HQDebugDesktopLook", "NO"])
    }

    /// [favorites-live-tiles] The share of the element's pixels within `tolerance` of `rgb` (its screenshot).
    @MainActor private func share(of rgb: (Int, Int, Int), in element: XCUIElement, tolerance: Int = 5) -> Double {
        guard let image = element.screenshot().image.cgImage else { return 0 }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var hits = 0
        for i in stride(from: 0, to: pixels.count, by: 4)
        where abs(Int(pixels[i]) - rgb.0) <= tolerance && abs(Int(pixels[i + 1]) - rgb.1) <= tolerance && abs(Int(pixels[i + 2]) - rgb.2) <= tolerance {
            hits += 1
        }
        return Double(hits) / Double(max(1, width * height))
    }

    /// [favorites-live-tiles] The stand-in's tile.html pictured in the cell: mostly its #f4f4f4 page (within 2, so the
    /// light page's #f2f2f7 behind a spinner doesn't count: 0 % there, 88 % drawn) and its dark headline (every channel
    /// 80 or under: 7 % of a Small tile; the words come out near (43, 47, 52) in the picture).
    @MainActor private func drawsPicture(_ cell: XCUIElement) -> Bool {
        share(of: (244, 244, 244), in: cell, tolerance: 2) > 0.25 && share(of: (0, 0, 0), in: cell, tolerance: 80) > 0.02
    }

    /// [favorites-live-tiles] A tester (2026-11-22): "it would be cool if for the new Favourites feature that you could
    /// add actual tiles instead of just a link to tiles." A pinned page (the stand-in's site/tile.html, its picture
    /// #f4f4f4 with "Revenue $12K") is added from Add Action's Dashboard Tiles, draws its picture on Favorites, goes
    /// Wide, opens as the Dashboard opens it, goes 40 % while unpinned, and Remove from Favorites leaves it pinned.
    @MainActor func testQuickActions_DashboardTile() throws {
        launchSignedIn(["-HQDebugResetQuickActions", "YES", "-HQDebugResetPins", "YES"])
        hook("pin-tile:/home/hermes/site/tile.html")
        tab("More")
        openMore("quick-actions")
        XCTAssertTrue(tile("starter-memo").waitForExistence(timeout: 10), "the starter set")

        // Add Action › Dashboard Tiles › the pinned page › Set Up (Name and Size only).
        edit("Edit")
        let add = app.cells["quick-actions.add-tile"]
        reach(add)
        add.tap()
        let choice = app.buttons["quick.add.tile.tile.html"]
        XCTAssertTrue(choice.waitForExistence(timeout: 8), "Add Action lists the Dashboard's tile")
        XCTAssertTrue(app.staticTexts["Dashboard Tiles"].exists || app.otherElements["Dashboard Tiles"].exists
                      || app.descendants(matching: .any).matching(NSPredicate(format: "label ==[c] %@", "Dashboard Tiles")).firstMatch.exists,
                      "under its own heading")
        Thread.sleep(forTimeInterval: 2)   // its small picture
        shot("favorites-tile-add-action")
        choice.tap()
        XCTAssertTrue(app.navigationBars["Set Up"].waitForExistence(timeout: 5), "a Dashboard tile opens Set Up")
        let name = app.textFields["quick.setup.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        let pinName = name.value as? String ?? ""
        XCTAssertFalse(pinName.isEmpty, "the name starts as the pin's")
        XCTAssertTrue(app.segmentedControls["quick.setup.size"].exists, "Size (Small / Wide)")
        XCTAssertFalse(app.segmentedControls["quick.setup.height"].exists, "no Height: a picture is never Short")
        XCTAssertFalse(app.buttons["quick.setup.symbol.star.fill"].exists, "no icon grid")
        XCTAssertFalse(app.buttons["quick.setup.color.indigo"].exists, "no colours")
        XCTAssertTrue(app.descendants(matching: .any)["quick.setup.preview"].exists, "the real tile, previewed")
        Thread.sleep(forTimeInterval: 2)
        shot("favorites-tile-setup")
        app.buttons["quick.setup.save"].tap()

        // On Favorites: the tile itself, its picture drawn (the page's own #f4f4f4).
        let dashboardTiles = grid.cells.matching(NSPredicate(format: "label ENDSWITH %@", ", Dashboard tile"))
        let added = dashboardTiles.firstMatch
        XCTAssertTrue(added.waitForExistence(timeout: 8), "the Dashboard tile is on Favorites")
        let id = added.identifier
        let cell = app.cells[id]
        XCTAssertEqual(cell.label, "\(pinName), Dashboard tile")
        edit("Done")
        reach(cell)
        let drawn = waitUntil(25) { self.drawsPicture(cell) }
        shot("favorites-tile-small")
        XCTAssertTrue(drawn, "the tile shows its page's picture: \(share(of: (244, 244, 244), in: cell, tolerance: 2)) page, \(share(of: (0, 0, 0), in: cell, tolerance: 80)) words")
        XCTAssertLessThan(abs(cell.frame.width - tile("starter-memo").frame.width), 2, "Small: one column")
        XCTAssertLessThan(abs(cell.frame.height - cell.frame.width), cell.frame.width * 0.2, "square-ish, as a Dashboard Small tile")

        // Wide, from the hold menu (Open, Small, Wide, Edit…, Remove from Favorites; no Tall / Short).
        cell.press(forDuration: 1.2)
        for word in ["Open", "Small", "Wide", "Edit…", "Remove from Favorites"] {
            XCTAssertTrue(app.buttons[word].waitForExistence(timeout: 3), "the hold menu offers \(word)")
        }
        XCTAssertFalse(app.buttons["Short"].exists || app.buttons["Tall"].exists, "no Tall / Short for a picture")
        shot("favorites-tile-hold-menu")
        app.buttons["Wide"].tap()
        XCTAssertTrue(waitUntil(5) { cell.frame.width > self.tile("starter-memo").frame.width * 1.6 }, "Wide: both columns")
        XCTAssertTrue(waitUntil(25) { self.drawsPicture(cell) }, "its picture, Wide")
        reach(cell)
        shot("favorites-tile-wide")

        // A tap opens it as the Dashboard does: the page itself, with the opened tile's Updates button.
        cell.tap()
        let headline = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Revenue $12K")).firstMatch
        XCTAssertTrue(headline.waitForExistence(timeout: 15), "the tile's page opens")
        XCTAssertTrue(app.buttons["tile.updates.button"].firstMatch.waitForExistence(timeout: 5), "opened as a tile (its Updates)")
        shot("favorites-tile-opened")
        app.buttons["sheet.close"].firstMatch.tap()
        XCTAssertTrue(app.collectionViews["pinned.list"].waitForExistence(timeout: 5), "over the Dashboard, on Favorites' stack")
        back()
        XCTAssertTrue(grid.waitForExistence(timeout: 5), "Back comes to Favorites")

        // Unpinned on the Dashboard: kept at 40 %, a tap says why; pinned again, it is back.
        hook("unpin-tile:/home/hermes/site/tile.html")
        XCTAssertTrue(waitUntil(8) { cell.value as? String == "Unavailable" }, "unpinned: switched off")
        reach(cell)
        shot("favorites-tile-unpinned")
        cell.tap()
        let notice = app.descendants(matching: .any)["pages.notice"]
        XCTAssertTrue(waitUntil(5) { notice.exists && notice.label.contains("isn’t on your Dashboard any more.") }, "one sentence")
        hook("pin-tile:/home/hermes/site/tile.html")
        XCTAssertTrue(waitUntil(8) { (cell.value as? String) != "Unavailable" }, "pinned again: on again")

        // Remove from Favorites: gone here, still pinned on the Dashboard.
        cell.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Remove from Favorites"].waitForExistence(timeout: 3))
        app.buttons["Remove from Favorites"].tap()
        XCTAssertTrue(waitUntil(5) { !cell.exists }, "removed from Favorites")
        back()
        openMore("pinned")
        XCTAssertTrue(app.collectionViews["pinned.list"].cells["pin-card-tile.html"].waitForExistence(timeout: 10),
                      "still pinned on the Dashboard")
    }

    /// Settings › Tabs can make Quick Actions a tab of its own; it then leaves More.
    @MainActor func testQuickActions_AsATab() throws {
        launchSignedIn(["-HQDebugResetQuickActions", "YES", "-hqn.tabOrder", "(bots, sessions, \"page.quick-actions\")"])
        tab("Favorites")
        XCTAssertTrue(tile("starter-memo").waitForExistence(timeout: 10), "the tab shows the page")
        tab("More")
        XCTAssertFalse(app.cells["more-row-quick-actions"].waitForExistence(timeout: 2), "as a tab it leaves More")
    }

    /// [favorites-retired] Owner 2026-11-22: Quick Actions replaces Favorites. More has no Favorites row; the pages a
    /// person chose there are page tiles after the starter set; and a Favorites tab is the Quick Actions tab. (The
    /// launch arguments seed what a build with Favorites stored.)
    @MainActor func testQuickActions_ReplacesFavorites() throws {
        launchSignedIn(["-HQDebugResetQuickActions", "YES", "-hqn.favorites", "(review, webhooks)",
                        "-hqn.tabOrder", "(bots, sessions, \"page.favorites\")"])
        tab("Favorites")
        XCTAssertTrue(tile("starter-memo").waitForExistence(timeout: 10), "the Favorites tab is the Quick Actions tab")
        XCTAssertTrue(tile("favorite-review").waitForExistence(timeout: 10), "a chosen page is a tile")
        XCTAssertTrue(tile("favorite-webhooks").exists, "every chosen page is a tile")
        XCTAssertEqual(Array(shownIDs.suffix(2)), ["favorite-review", "favorite-webhooks"], "after the starter set, in Favorites' order")
        shot("quick-actions-took-in-favorites")
        tile("favorite-review").tap()
        XCTAssertTrue(app.navigationBars["Changes"].waitForExistence(timeout: 10), "the page tile opens its page")
        tab("More")
        XCTAssertFalse(revealMore("favorites", timeout: 3).exists, "More has no Favorites row")
    }

    /// Favorites 2.0: tapping `⋯` must never raise the software keyboard on iPhone; Starter Layouts opens large with
    /// visual wireframe previews; nav bar `+` opens the visual Add to Favorites gallery with Build Custom Tile hero and
    /// live widget previews; adding a live card automatically dismisses the unedited-starter Explore banner.
    @MainActor func testQuickActions_GalleryPresetsAndMoreMenuNoKeyboard() throws {
        launchSignedIn(["-HQDebugResetQuickActions", "YES", "-hqn.quickActions.dismissedExplore", "NO"])
        tab("More")
        openMore("quick-actions")
        XCTAssertTrue(tile("starter-memo").waitForExistence(timeout: 10), "the starter set loads")

        // Unedited starter shows the calm dismissible Explore banner without polluting `shownIDs`.
        let exploreBtn = app.buttons["favorites.banner.explore"]
        XCTAssertTrue(exploreBtn.waitForExistence(timeout: 5), "unedited starter shows Explore banner")
        XCTAssertEqual(shownIDs, ["starter-memo", "starter-talk", "starter-new-chat", "starter-add-task", "starter-search"])
        shot("favorites-v2-starter-banner")

        // Tapping `⋯` opens Favorites Options menu WITHOUT popping up the software keyboard.
        let moreBtn = app.buttons["quick-actions.more"]
        XCTAssertTrue(moreBtn.waitForExistence(timeout: 5), "nav bar has ⋯ options button")
        moreBtn.tap()
        let layoutsItem = app.buttons["Starter Layouts…"]
        XCTAssertTrue(layoutsItem.waitForExistence(timeout: 5), "⋯ menu lists Starter Layouts…")
        XCTAssertTrue(app.buttons["Build Custom Tile…"].exists, "⋯ menu lists Build Custom Tile…")
        XCTAssertEqual(app.keyboards.count, 0, "tapping ⋯ on iPhone must never raise the software keyboard")
        shot("favorites-v2-more-menu")
        layoutsItem.tap()

        // Visual Starter Layouts sheet opens at large detent with all 4 presets.
        XCTAssertTrue(app.navigationBars["Starter Layouts"].waitForExistence(timeout: 5), "Starter Layouts sheet opens")
        for preset in ["commandCenter", "dailyFocus", "voiceFirst", "builderOps"] {
            XCTAssertTrue(app.buttons["favorites.preset.\(preset)"].waitForExistence(timeout: 3), "preset \(preset) visible")
        }
        shot("favorites-v2-starter-layouts")
        app.navigationBars["Starter Layouts"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Favorites"].waitForExistence(timeout: 5))

        // Nav bar `+` opens the visual Add to Favorites Gallery.
        let addBtn = app.buttons["quick-actions.add"]
        XCTAssertTrue(addBtn.waitForExistence(timeout: 5), "nav bar has + button")
        addBtn.tap()
        XCTAssertTrue(app.navigationBars["Add to Favorites"].waitForExistence(timeout: 5), "+ opens Add to Favorites gallery")
        XCTAssertTrue(app.buttons["favorites.gallery.create-custom-tile"].waitForExistence(timeout: 5), "hero Build Custom Tile CTA exists")
        XCTAssertTrue(app.buttons["favorites.gallery.widget.needs-you"].waitForExistence(timeout: 5), "live widget carousel exists")
        shot("favorites-v2-add-gallery")

        // Tap a live widget preview -> Set Up -> Add -> returns to Favorites and auto-hides starter Explore banner.
        app.buttons["favorites.gallery.widget.needs-you"].tap()
        XCTAssertTrue(app.navigationBars["Set Up"].waitForExistence(timeout: 5), "tapping gallery preview opens Set Up")
        app.buttons["quick.setup.save"].tap()
        XCTAssertTrue(waitUntil(6) { self.shownIDs.count == 6 }, "added Needs You card from gallery")
        XCTAssertTrue(waitUntil(4) { !exploreBtn.exists }, "Explore banner disappears automatically after customizing")
    }
}
