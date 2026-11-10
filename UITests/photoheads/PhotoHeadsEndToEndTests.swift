// Photo heads end to end (docs/spec/3x-photoheads.md §11.2, P1–P21, and the repeatable part of §12): the real app,
// real gestures, the stand-in gateway's `/__photoheads/state` as the wire evidence, and the screen's own pixels as the
// evidence for a face (every fixture picture is flat, known colours). Run with scripts/e2e-photoheads.sh <simulator>.

import XCTest

final class PhotoHeadsEndToEndTests: XCTestCase {
    var a: PhotoFixture!
    var media: String = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        a = try PhotoFixture.load("HQN_PHOTOHEADS_A")
        media = ProcessInfo.processInfo.environment["HQN_PHOTOHEADS_MEDIA"] ?? ""
        try a.reset()
    }

    // MARK: - P1 / P2 photos in the list, the chat title and Bot Info

    @MainActor func testP1P2_PhotosInTheListTheChatTitleAndBotInfo() throws {
        let app = launch()
        XCTAssertTrue(waitUntil(timeout: 40) { self.a.gets() >= 8 }, "every bot with a picture is asked for once: \(a.gets())")
        XCTAssertTrue(waitUntil(timeout: 15) { self.rowShows(app, "ivy", .photoA) }, "Ivy's row shows photo A")
        XCTAssertTrue(waitUntil(timeout: 10) { self.rowShows(app, "webp", .webp) }, "the WebP picture shows")
        XCTAssertTrue(waitUntil(timeout: 10) { self.rowShowsQuarters(app, "research") }, "Research's 640 × 480 JPEG shows, cropped to its middle")
        // App-icon corners, never a circle and never a bare square.
        let ivy = try XCTUnwrap(Pixels(cell(app, "ivy")))
        let face = try XCTUnwrap(ivy.box(of: .photoA), "photo A's field")
        XCTAssertEqual(face.width, face.height, accuracy: 1.5, "a square tile: \(face)")
        assertAppIconCorner(ivy, face, .photoA)
        // A saved head's own copy, desktop's copy, no picture, and a cut file: the head.
        for (id, never) in [("default", RGB.mirror), ("inbox", .backfill), ("broken", .broken)] {
            let pixels = try XCTUnwrap(Pixels(cell(app, id)))
            XCTAssertLessThan(pixels.longestRun(of: never, tolerance: 12), 8, "\(id) shows its head, not the stored picture")
        }
        XCTAssertFalse(rowShowsQuarters(app, "notes"), "Notes has no picture: its head")
        shot(app, "bots-photos")
        reveal(app, "huge")
        XCTAssertTrue(waitUntil(timeout: 10) { self.rowShowsQuarters(app, "huge") }, "the 1.9 MB photo shows")
        shot(app, "bots-photos-scrolled")

        // The wire: one read per bot that has a picture, none for the one that has none, never two at once.
        Thread.sleep(forTimeInterval: 3)
        for id in ["default", "ivy", "research", "inbox", "deploys", "webp", "broken", "huge"] {
            XCTAssertEqual(a.gets(id), 1, "one profiles.get_asset for \(id)")
        }
        XCTAssertEqual(a.gets("notes"), 0, "none for a bot without a picture")
        XCTAssertEqual(a.state()["max_get_in_flight"] as? Int, 1, "one read at a time")
        XCTAssertEqual(a.state()["contract_4000"] as? Int, 0, "the gateway refused no parameter")

        // P2: the 34 pt title face and Bot Info's 80 pt face are the same photo, as app-icon tiles.
        cell(app, "ivy").tap()
        let title = app.descendants(matching: .any)["chat.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "the chat opens")
        XCTAssertTrue(waitUntil(timeout: 5) { (Pixels(title)?.longestRun(of: .photoA) ?? 0) > 20 }, "the title face is photo A")
        let titlePixels = try XCTUnwrap(Pixels(title))
        let titleFace = try XCTUnwrap(titlePixels.box(of: .photoA))
        XCTAssertEqual(titleFace.width, 34, accuracy: 1.5, "34 pt wide: \(titleFace)")
        XCTAssertEqual(titleFace.height, 34, accuracy: 1.5, "34 pt tall: \(titleFace)")
        assertAppIconCorner(titlePixels, titleFace, .photoA)
        shot(app, "chat-title-photo")
        title.tap()
        let name = app.staticTexts["bot-info.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 8), "the title opens Bot Info")
        Thread.sleep(forTimeInterval: 0.8)
        let screen = try XCTUnwrap(screenPixels(app))
        let around = CGRect(x: name.frame.midX - 60, y: name.frame.minY - 110, width: 120, height: 110)
        let infoFace = try XCTUnwrap(screen.box(of: .photoA, in: around), "Bot Info's face is photo A")
        XCTAssertEqual(infoFace.width, 80, accuracy: 2, "80 pt wide: \(infoFace)")
        XCTAssertEqual(infoFace.height, 80, accuracy: 2, "80 pt tall: \(infoFace)")
        assertAppIconCorner(screen, infoFace, .photoA, topTrailing: true)
        shot(app, "bot-info-photo")
    }

    // MARK: - P1b the Sessions page's bot chips wear the photos too (tester, 2026-10-27: the chips drew the heads)

    @MainActor func testP1b_SessionsChipsShowThePhotos() throws {
        let app = launch()
        XCTAssertTrue(waitUntil(timeout: 40) { self.rowShows(app, "ivy", .photoA) }, "Ivy's photo arrived")
        // The Desktop Look docks its own tab bar.
        let docked = app.buttons["tab-sessions"]
        (docked.exists ? docked : app.tabBars.buttons["Sessions"]).tap()
        let ivy = app.buttons["sessions.chip.ivy"]
        XCTAssertTrue(ivy.waitForExistence(timeout: 10), "the bot chips show")
        XCTAssertTrue(waitUntil(timeout: 5) { (Pixels(ivy)?.longestRun(of: .photoA) ?? 0) > 20 }, "Ivy's chip is photo A")
        let pixels = try XCUnwrapPixels(ivy)
        let face = try XCTUnwrap(pixels.box(of: .photoA), "photo A's field")
        XCTAssertEqual(face.width, face.height, accuracy: 1.5, "a square tile: \(face)")
        assertAppIconCorner(pixels, face, .photoA)
        let notes = app.buttons["sessions.chip.notes"]
        if notes.exists, let other = Pixels(notes) {
            XCTAssertLessThan(other.longestRun(of: .photoA), 8, "Notes has no picture: its head")
        }
        // Picked, the ring is the tile's rounded square (a circle would cut the photo's corners).
        ivy.tap()
        XCTAssertTrue(waitUntil(timeout: 3) { ivy.isSelected }, "Ivy's chip is picked")
        shot(app, "sessions-chips-photo")
    }

    // MARK: - P3 relaunch offline

    @MainActor func testP3_RelaunchOfflineShowsTheKeptPhotos() throws {
        var app = launch()
        XCTAssertTrue(waitUntil(timeout: 40) { self.a.gets() >= 8 && self.rowShows(app, "ivy", .photoA) && self.rowShowsQuarters(app, "research") })
        Thread.sleep(forTimeInterval: 2.5)        // the index is written a moment after the last picture
        app.terminate()
        try a.control("/__photoheads/net", ["mode": "down"])
        defer { _ = try? a.control("/__photoheads/net", ["mode": "up"]) }
        let before = a.gets()
        let rosters = a.count("profiles.list")
        app = XCUIApplication()
        app.launchArguments = ["-HQDebugNoDrag", "YES"] + appearanceArguments
        app.launch()
        XCTAssertTrue(cell(app, "ivy").waitForExistence(timeout: 25), "the saved sign-in opens the list with no gateway")
        XCTAssertTrue(waitUntil(timeout: 6) { self.rowShows(app, "ivy", .photoA) }, "photo A from this phone's own copy")
        XCTAssertTrue(rowShowsQuarters(app, "research") && rowShows(app, "webp", .webp), "and the others")
        shot(app, "bots-photos-offline")
        try a.control("/__photoheads/net", ["mode": "up"])
        XCTAssertTrue(waitUntil(timeout: 60) { self.a.count("profiles.list") > rosters }, "the app reaches the gateway again")
        Thread.sleep(forTimeInterval: 6)
        XCTAssertEqual(a.gets(), before, "nothing changed on the gateway: no picture is read again")
        XCTAssertTrue(rowShows(app, "ivy", .photoA))
    }

    // MARK: - P4 another device changes the picture

    @MainActor func testP4_AnotherDeviceChangesThePicture() throws {
        let app = launch()
        XCTAssertTrue(waitUntil(timeout: 40) { self.rowShows(app, "ivy", .photoA) })
        // A new photo saved elsewhere (the picture, then the hermes-bots revision): seen on the next look at the roster.
        try a.control("/__photoheads/other-device", ["profile": "ivy", "avatar": "photo-b", "bump": "hermes-bots"])
        XCTAssertTrue(waitUntil(timeout: 45) { self.rowShows(app, "ivy", .photoB) }, "photo B without a relaunch")
        XCTAssertFalse(rowShows(app, "ivy", .photoA))
        shot(app, "bots-photo-changed-elsewhere")
        // A head saved elsewhere: its 288 px copy replaces the photo, so the head shows.
        try a.control("/__photoheads/other-device", ["profile": "ivy", "avatar": "mirror", "bump": "dispatch-head"])
        XCTAssertTrue(waitUntil(timeout: 45) { !self.rowShows(app, "ivy", .photoB) }, "the head again")
        XCTAssertLessThan(try XCUnwrapPixels(cell(app, "ivy")).longestRun(of: .mirror, tolerance: 12), 8, "not the stored copy either")
        // A photo again, then cleared with no revision moving at all: has_avatar going false is enough.
        try a.control("/__photoheads/other-device", ["profile": "ivy", "avatar": "photo-b", "bump": "hermes-bots"])
        pullToRefresh(app)
        XCTAssertTrue(waitUntil(timeout: 20) { self.rowShows(app, "ivy", .photoB) })
        try a.control("/__photoheads/other-device", ["profile": "ivy", "avatar": "clear"])
        pullToRefresh(app)
        XCTAssertTrue(waitUntil(timeout: 20) { !self.rowShows(app, "ivy", .photoB) }, "cleared: the head")
        XCTAssertEqual(a.state()["contract_4000"] as? Int, 0)
    }

    // MARK: - P5 two gateways keep their pictures apart

    @MainActor func testP5_GatewaySwitchAndRemoval() throws {
        let b = try PhotoFixture.load("HQN_PHOTOHEADS_B")
        try b.reset()
        let app = launch()
        XCTAssertTrue(waitUntil(timeout: 40) { self.rowShows(app, "ivy", .photoA) })
        XCTAssertEqual(AppFiles.photoFolders().count, 1, "one folder of kept photos: \(AppFiles.photoFolders())")
        // Add the second gateway (More › the gateway card › Add Gateway…); the app moves to it.
        let more = app.tabBars.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        let card = app.cells["more-row-gateway"]
        for _ in 0..<4 { more.tap(); if card.waitForExistence(timeout: 2), card.isHittable { break } }
        card.tap()
        XCTAssertTrue(app.buttons["gateway.add"].waitForExistence(timeout: 5), "the Gateway page")
        app.buttons["gateway.add"].tap()
        typeSignIn(app, b)
        let rowB = app.descendants(matching: .any)["gateway-row-\(b.hostPort)"]
        XCTAssertTrue(appears(rowB, app, "two-gateways", timeout: 20), "two gateways listed")
        dismissSavePassword(app, wait: 2)
        app.tabBars.buttons["Bots"].tap()
        XCTAssertTrue(cell(app, "ivy").waitForExistence(timeout: 15))
        XCTAssertTrue(waitUntil(timeout: 40) { self.rowShows(app, "ivy", .photoABeta) }, "Beta's Ivy wears Beta's picture")
        XCTAssertFalse(rowShows(app, "ivy", .photoA), "nothing of gateway A is drawn under Beta")
        shot(app, "bots-photos-second-gateway")
        XCTAssertEqual(AppFiles.photoFolders().count, 2, "each gateway keeps its own photos: \(AppFiles.photoFolders())")

        // Back to A from the title menu: A's picture, at once (it is on this phone).
        openTitleMenu(app)
        let menuA = app.buttons["gateway-menu-\(a.hostPort)"].firstMatch
        XCTAssertTrue(appears(menuA, app, "title-menu"), "the title menu lists both")
        menuA.tap()
        XCTAssertTrue(waitUntil(timeout: 20) { self.cell(app, "ivy").exists && self.rowShows(app, "ivy", .photoA) }, "A's picture again")
        XCTAssertFalse(rowShows(app, "ivy", .photoABeta))

        // Remove Beta: its kept photos go with it.
        for _ in 0..<4 { more.tap(); if card.waitForExistence(timeout: 2), card.isHittable { break } }
        card.tap()
        XCTAssertTrue(rowB.waitForExistence(timeout: 8))
        rowB.swipeLeft()
        app.buttons["Remove"].tap()
        let confirm = app.alerts.firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.buttons["Remove Gateway"].tap()
        XCTAssertTrue(waitUntil(timeout: 15) { !rowB.exists }, "removed")
        XCTAssertTrue(waitUntil(timeout: 10) { AppFiles.photoFolders().count == 1 }, "Beta's photo folder is gone: \(AppFiles.photoFolders())")
    }

    // MARK: - P6 / P9 / P10 the Picture section and its menu

    @MainActor func testP6P9P10_PictureTabsAndTheUploadMenu() throws {
        let app = launch()
        XCTAssertTrue(waitUntil(timeout: 40) { self.a.gets() >= 8 })
        openEditBot(app, "notes")
        let face = app.descendants(matching: .any)["edit-bot.face"]
        XCTAssertTrue(face.waitForExistence(timeout: 5), "the face")
        XCTAssertEqual(face.label, "Notes’s head")
        XCTAssertEqual(face.frame.width, 72, accuracy: 1, "72 pt")
        let tabs = app.segmentedControls["edit-bot.picture-tabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 3), "Head | Upload")
        XCTAssertTrue(tabs.buttons["Head"].isSelected && !tabs.buttons["Upload"].isSelected, "the page opens on Head")
        XCTAssertLessThan(tabs.buttons["Head"].frame.minX, tabs.buttons["Upload"].frame.minX, "Head, then Upload")
        XCTAssertTrue(app.buttons["edit-bot.edit-head"].exists, "Edit Head")
        XCTAssertEqual(app.staticTexts["edit-bot.head-note"].label, "Your other devices and desktop Hermes show the same picture.")
        XCTAssertFalse(app.buttons["edit-bot.remove-picture"].exists, "nothing to remove")
        XCTAssertFalse(app.buttons["edit-bot.save"].isEnabled, "Save waits for a change")
        XCTAssertGreaterThanOrEqual(app.buttons["edit-bot.edit-head"].frame.height, 44, "a 44 pt target: \(app.buttons["edit-bot.edit-head"].frame)")
        shot(app, "edit-bot-head-tab")

        // P10: Upload › Choose an image… is a menu of two; closing it changes nothing.
        tabs.buttons["Upload"].tap()
        let choose = app.buttons["edit-bot.choose-image"]
        XCTAssertTrue(choose.waitForExistence(timeout: 3), "Choose an image…")
        XCTAssertTrue(choose.label.hasPrefix("Choose an Image"), choose.label)
        XCTAssertFalse(app.buttons["edit-bot.edit-head"].exists, "Edit Head belongs to the Head tab")
        XCTAssertGreaterThanOrEqual(choose.frame.height, 44, "a 44 pt target: \(choose.frame)")
        shot(app, "edit-bot-upload-tab")
        let library = app.buttons["Photo Library"].firstMatch, file = app.buttons["Choose File"].firstMatch
        for _ in 0..<3 { choose.tap(); if library.waitForExistence(timeout: 3) { break } }
        XCTAssertTrue(library.exists && file.exists, "Photo Library and Choose File")
        XCTAssertLessThan(library.frame.minY, file.frame.minY, "in that order")
        shot(app, "edit-bot-upload-menu")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()      // outside the menu
        XCTAssertTrue(waitUntil(timeout: 4) { !library.exists }, "the menu closes")
        XCTAssertFalse(app.buttons["edit-bot.save"].isEnabled, "nothing changed")
        XCTAssertEqual(face.label, "Notes’s head")
        XCTAssertEqual(a.sets(), 0, "and nothing was sent")
        app.navigationBars.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["bot-info.close"].waitForExistence(timeout: 5), "no question: there was nothing to discard")
        app.buttons["bot-info.close"].tap()

        // P9: a saved head's own copy on the gateway is not a picture to remove.
        openEditBot(app, "default")
        XCTAssertTrue(face.waitForExistence(timeout: 5))
        XCTAssertTrue(face.label.hasSuffix("’s head"), face.label)
        XCTAssertFalse(app.buttons["edit-bot.remove-picture"].exists, "no Remove Picture on Head")
        tabs.buttons["Upload"].tap()
        XCTAssertTrue(choose.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["edit-bot.remove-picture"].exists, "nor on Upload")
    }

    // MARK: - P7 / P8 the Head tab

    @MainActor func testP7P8_SavingAHeadAndReplacingAPhotoWithOne() throws {
        let app = launch()
        XCTAssertTrue(waitUntil(timeout: 40) { self.rowShows(app, "ivy", .photoA) })
        // P7: a bot with no picture gets a head; its 288 px copy lands on the gateway.
        openEditBot(app, "notes")
        app.buttons["edit-bot.edit-head"].tap()
        XCTAssertTrue(app.buttons["edit-head.shuffle"].waitForExistence(timeout: 5), "Edit Head opens")
        app.buttons["edit-head.shuffle"].tap()
        shot(app, "edit-head-changed")   // Save shows once there is a change (owner 2026-10-26: none in the Desktop Look)
        app.buttons["edit-head.save"].tap()
        let note = app.staticTexts["edit-bot.head-note"]
        XCTAssertTrue(waitUntil(timeout: 10) { note.exists && note.label == "Head saved. It’s on every device on this gateway." }, "the save says so")
        XCTAssertTrue(waitUntil(timeout: 10) { equal(self.a.bot("notes")["avatar_png"], [288, 288]) }, "the head's copy: \(a.bot("notes"))")
        XCTAssertFalse(app.buttons["edit-bot.remove-picture"].exists, "a head's copy is not a picture to remove")
        shot(app, "edit-bot-head-saved")
        app.navigationBars.buttons["Cancel"].tap()
        app.buttons["bot-info.close"].tap()

        // P8: a bot wearing a photo says so before the tap; a saved head replaces the photo everywhere.
        openEditBot(app, "ivy")
        let face = app.descendants(matching: .any)["edit-bot.face"]
        XCTAssertTrue(face.waitForExistence(timeout: 5))
        XCTAssertEqual(face.label, "Ivy’s photo")
        XCTAssertEqual(note.label, "This bot shows a photo. Saving a head replaces it.")
        XCTAssertTrue(app.buttons["edit-bot.remove-picture"].exists, "Remove Picture")
        XCTAssertGreaterThan(try XCUnwrapPixels(face).longestRun(of: .photoA), 30, "the 72 pt face is photo A")
        shot(app, "edit-bot-photo")
        app.buttons["edit-bot.edit-head"].tap()
        XCTAssertTrue(app.buttons["edit-head.shuffle"].waitForExistence(timeout: 5))
        app.buttons["edit-head.shuffle"].tap()
        app.buttons["edit-head.save"].tap()
        XCTAssertTrue(waitUntil(timeout: 10) { note.exists && note.label == "Head saved. It’s on every device on this gateway." })
        XCTAssertEqual(face.label, "Ivy’s head", "the face is the head at once")
        XCTAssertLessThan(try XCUnwrapPixels(face).longestRun(of: .photoA), 8)
        XCTAssertFalse(app.buttons["edit-bot.remove-picture"].exists, "Remove Picture is gone")
        XCTAssertTrue(waitUntil(timeout: 10) { equal(self.a.bot("ivy")["avatar_png"], [288, 288]) }, "the gateway holds the head's copy")
        app.navigationBars.buttons["Cancel"].tap()
        let name = app.staticTexts["bot-info.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertLessThan(try XCTUnwrap(screenPixels(app)).longestRun(of: .photoA, in: CGRect(x: name.frame.midX - 60, y: name.frame.minY - 110, width: 120, height: 110)), 8,
                          "Bot Info shows the head")
        app.buttons["bot-info.close"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !self.rowShows(app, "ivy", .photoA) }, "and so does the list")
        let gets = a.gets("ivy")
        Thread.sleep(forTimeInterval: 4)
        XCTAssertEqual(a.gets("ivy"), gets, "this phone's own head save needs no read back")
    }

    // MARK: - P11 the system photo picker

    @MainActor func testP11_TheSystemPickerOpensMoveAndScale() throws {
        let app = launch()
        openEditBot(app, "notes")
        openUploadMenu(app)
        app.buttons["Photo Library"].firstMatch.tap()
        // The picker runs in another process; its pictures are images in a grid.
        let photo = app.images.matching(NSPredicate(format: "identifier == 'PXGGridLayout-Info' OR label BEGINSWITH[c] 'Photo, '")).firstMatch
        guard photo.waitForExistence(timeout: 20) else {
            dump(app, "photo-picker")
            throw XCTSkip("The simulator's photo library shows no picture (scripts/e2e-photoheads.sh adds one with simctl addmedia).")
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertFalse(springboard.alerts.firstMatch.exists, "no permission question: the picker needs none")
        XCTAssertFalse(app.buttons["Add"].exists, "one picture: a tap picks, there is no Add button")
        shot(app, "photo-picker")
        let stage = app.descendants(matching: .any)["photo-framer.stage"]
        photo.tap()
        if !stage.waitForExistence(timeout: 6), photo.exists { photo.press(forDuration: 0.2) }      // the simulator's picker can drop a tap
        XCTAssertTrue(stage.waitForExistence(timeout: 15), "one tap closes the picker and opens Move and Scale")
        XCTAssertTrue(waitUntil(timeout: 15) { stage.label == "Photo" }, "the picked photo loads: \(stage.label)")
        XCTAssertFalse(springboard.alerts.firstMatch.exists, "still no permission question")
        app.buttons["photo-framer.choose"].tap()
        let face = app.descendants(matching: .any)["edit-bot.face"]
        XCTAssertTrue(waitUntil(timeout: 8) { face.exists && face.label == "Notes’s photo" }, "the picked photo is staged")
        XCTAssertEqual(a.sets(), 0, "nothing is sent before Save")
    }

    // MARK: - P11b the Files browser (Choose File)

    /// The real Files browser behind Upload › Choose an image… › Choose File: a picked file opens Move and Scale the
    /// right way up, Choose stages it, and the copy iOS made for the pick is gone from this app's space afterwards.
    /// scripts/e2e-photoheads.sh puts `photoheads-pick.jpg` (the turned portrait) in the simulator's On My iPhone.
    @MainActor func testP11b_ChooseFileOpensMoveAndScale() throws {
        let app = launch()
        openEditBot(app, "notes")
        openUploadMenu(app)
        app.buttons["Choose File"].firstMatch.tap()
        let named = NSPredicate(format: "label CONTAINS[c] 'photoheads-pick'")
        func file() -> XCUIElement { app.descendants(matching: .any).matching(named).firstMatch }
        // The browser opens on Recents or where it was last; the file is in On My iPhone.
        if !file().waitForExistence(timeout: 8) {
            let browse = app.buttons["Browse"].firstMatch
            if browse.waitForExistence(timeout: 4) { browse.tap(); Thread.sleep(forTimeInterval: 1.5) }
            if !file().exists {
                let onPhone = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'On My iPhone'")).firstMatch
                if !onPhone.exists, browse.exists { browse.tap(); Thread.sleep(forTimeInterval: 1.5) }
                if onPhone.waitForExistence(timeout: 4) { onPhone.tap(); Thread.sleep(forTimeInterval: 1.5) }
            }
        }
        guard file().waitForExistence(timeout: 8) else {
            dump(app, "files-browser")
            throw XCTSkip("The Files browser does not list photoheads-pick.jpg (scripts/e2e-photoheads.sh copies it into On My iPhone).")
        }
        shot(app, "files-browser")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertFalse(springboard.alerts.firstMatch.exists, "no permission question: the browser needs none")
        let stage = app.descendants(matching: .any)["photo-framer.stage"]
        file().tap()
        if !stage.waitForExistence(timeout: 8), file().exists { file().tap() }       // the simulator's browser can drop a tap
        XCTAssertTrue(appears(stage, app, "files-after-pick", timeout: 15), "one tap closes the browser and opens Move and Scale")
        XCTAssertTrue(waitUntil(timeout: 15) { stage.label == "Photo" }, "the picked file loads: \(stage.label)")
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertEqual(try quartersInFrame(app, stage), Pixels.uprightQuarters, "the turned portrait is upright")
        shot(app, "framer-from-files")
        // The file was read: nothing of the pick is left in this app's own space, whatever happens next.
        XCTAssertTrue(waitUntil(timeout: 5) { AppFiles.pickLeftovers().isEmpty }, "the pick's copy is gone: \(AppFiles.pickLeftovers())")
        app.buttons["photo-framer.choose"].tap()
        let face = app.descendants(matching: .any)["edit-bot.face"]
        XCTAssertTrue(waitUntil(timeout: 8) { !stage.exists && face.exists && face.label == "Notes’s photo" }, "the picked file is staged")
        XCTAssertTrue(app.buttons["edit-bot.save"].isEnabled)
        XCTAssertEqual(a.sets(), 0, "nothing is sent before Save")

        // Cancelling the browser changes nothing and leaves nothing.
        openUploadMenu(app)
        app.buttons["Choose File"].firstMatch.tap()
        let browse = app.buttons["Browse"].firstMatch
        XCTAssertTrue(appears(browse, app, "files-browser-again", timeout: 10), "the browser opens again")
        // Its own Cancel is the last one in the tree (Edit Bot's is under the browser and comes first). The browser runs
        // in another process: a query sees its buttons only now and then, the whole tree's description always does.
        for _ in 0..<4 where browse.exists {
            if let cancel = lastFrameInTree(app, of: "Button", labelled: "Cancel") {
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: cancel.midX, dy: cancel.midY)).tap()
            }
            _ = waitUntil(timeout: 3) { !browse.exists }
        }
        if browse.exists { dump(app, "files-browser-still-up") }
        XCTAssertTrue(waitUntil(timeout: 8) { app.buttons["edit-bot.choose-image"].isHittable }, "back on Edit Bot")
        XCTAssertEqual(face.label, "Notes’s photo", "the staged photo is still there")
        XCTAssertFalse(stage.exists)
        XCTAssertTrue(AppFiles.pickLeftovers().isEmpty, "\(AppFiles.pickLeftovers())")
    }

    // MARK: - P12 picked files: upright, and the ones that can't be used

    @MainActor func testP12_APickedPhotoIsUprightAndBadFilesAreRefusedInWords() throws {
        let app = launch(pick: ["portrait.jpg", "corrupt.jpg", "text.png", "big.bin.jpg"])
        openEditBot(app, "notes")
        // A phone portrait stored on its side (EXIF orientation 6): upright in the frame.
        pickPhoto(app)
        let stage = waitForFramer(app)
        XCTAssertEqual(try quartersInFrame(app, stage), Pixels.uprightQuarters, "red, green / blue, yellow: upright")
        app.buttons["photo-framer.cancel"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !stage.exists })

        let unreadable = "That file isn’t a picture this app can read. Choose a photo or an image file."
        for (file, words) in [("corrupt.jpg", unreadable), ("text.png", unreadable), ("big.bin.jpg", "That picture is too big. Choose one under 32 MB.")] {
            pickPhoto(app)
            let alert = app.alerts["Couldn’t Use That Picture"]
            XCTAssertTrue(alert.waitForExistence(timeout: 12), "\(file): the alert")
            XCTAssertTrue(alert.staticTexts[words].exists, "\(file): “\(words)”")
            if file == "corrupt.jpg" { shot(app, "alert-cant-use-picture") }
            if file == "big.bin.jpg" { shot(app, "alert-picture-too-big") }
            alert.buttons["OK"].tap()
            XCTAssertTrue(waitUntil(timeout: 5) { !stage.exists && !alert.exists }, "\(file): Move and Scale is closed")
            XCTAssertTrue(app.buttons["edit-bot.choose-image"].waitForExistence(timeout: 5), "\(file): back on Edit Bot")
            XCTAssertFalse(app.buttons["edit-bot.save"].isEnabled, "\(file): nothing staged")
        }
        XCTAssertEqual(app.descendants(matching: .any)["edit-bot.face"].label, "Notes’s head")
        XCTAssertEqual(a.sets(), 0)
    }

    // MARK: - P13 Move and Scale, and its loading state

    @MainActor func testP13_MoveAndScaleAndItsLoadingState() throws {
        let app = launch(pick: ["portrait.jpg"], arguments: ["-HQDebugBotPhotoDelay", "6"])
        openEditBot(app, "notes")
        pickPhoto(app)
        let stage = app.descendants(matching: .any)["photo-framer.stage"]
        XCTAssertTrue(stage.waitForExistence(timeout: 8), "Move and Scale opens at once")
        let choose = app.buttons["photo-framer.choose"], cancel = app.buttons["photo-framer.cancel"], slider = app.sliders["photo-framer.zoom"]
        XCTAssertEqual(stage.label, "Loading photo", "a spinner while the file is read")
        XCTAssertTrue(app.navigationBars["Move and Scale"].exists, "the title")
        XCTAssertTrue(cancel.exists && choose.exists && slider.exists)
        XCTAssertFalse(choose.isEnabled, "Choose waits for the photo")
        XCTAssertFalse(slider.isEnabled, "and so does the slider")
        XCTAssertTrue(cancel.isEnabled)
        shot(app, "framer-loading")
        XCTAssertTrue(waitUntil(timeout: 15) { stage.label == "Photo" }, "the photo arrives")
        XCTAssertTrue(choose.isEnabled && slider.isEnabled)
        XCTAssertEqual(stage.value as? String, "100 percent, centered")
        // The window: an app-icon hole in a dimmed surround, the photo bright inside it.
        let screen = try XCTUnwrap(screenPixels(app))
        let hole = frameRect(stage)
        XCTAssertGreaterThanOrEqual(hole.width, 160, "a frame of at least 160 pt")
        XCTAssertEqual(screen.quarters(of: hole), Pixels.uprightQuarters)
        let inside = screen.average(in: CGRect(x: hole.minX + 20, y: hole.midY - 60, width: 12, height: 12))
        let dimmed = screen.average(in: CGRect(x: hole.minX + 20, y: hole.minY - 26, width: 12, height: 12))
        XCTAssertTrue(inside.near(.red, 30), "the photo inside the window: \(inside)")
        XCTAssertTrue(dimmed.hue == .red && dimmed.luminance < inside.luminance * 0.7, "the same photo, dimmed, outside it: \(dimmed)")
        XCTAssertFalse(screen.colour(at: CGPoint(x: hole.minX + 1.5, y: hole.minY + 1.5)).near(.red, 30), "the window's corner is cut like an app icon")
        XCTAssertGreaterThanOrEqual(slider.frame.height, 44, "the slider's row is 44 pt")
        // Cancel and Choose are the system toolbar's own buttons (a 46 pt glass capsule around the label's frame).
        XCTAssertGreaterThanOrEqual(min(cancel.frame.height, choose.frame.height), 36, "the bar's buttons: \(cancel.frame) \(choose.frame)")
        XCTAssertGreaterThanOrEqual(min(cancel.frame.width, choose.frame.width), 44)
        shot(app, "framer-ready")
        cancel.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !stage.exists })

        // Cancel while it is still loading: closed, nothing staged, no alert afterwards.
        pickPhoto(app)
        XCTAssertTrue(stage.waitForExistence(timeout: 8))
        XCTAssertEqual(stage.label, "Loading photo")
        cancel.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !stage.exists }, "Cancel works while loading")
        Thread.sleep(forTimeInterval: 7)
        XCTAssertFalse(app.alerts.firstMatch.exists, "the cancelled read says nothing later")
        XCTAssertFalse(app.buttons["edit-bot.save"].isEnabled)
    }

    // MARK: - P14 drag, pinch, slider, double tap

    @MainActor func testP14_DragPinchSliderAndDoubleTap() throws {
        let app = launch(pick: ["portrait.jpg", "wide.png"])
        openEditBot(app, "notes")
        pickPhoto(app)
        let stage = waitForFramer(app)
        let slider = app.sliders["photo-framer.zoom"]
        let centre = stage.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        // Drag: the photo follows the finger and stops at the frame's edge (a 3:4 photo has a sixth of a frame of slack).
        centre.press(forDuration: 0.1, thenDragTo: centre.withOffset(CGVector(dx: 30, dy: 30)), withVelocity: .slow, thenHoldForDuration: 0.1)
        let nudged = (stage.value as? String) ?? ""
        XCTAssertTrue(nudged.hasPrefix("100 percent, moved ") && nudged.hasSuffix(" percent down"), "it follows the finger, down only: \(nudged)")
        centre.press(forDuration: 0.1, thenDragTo: centre.withOffset(CGVector(dx: 140, dy: 260)), withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertEqual(stage.value as? String, "100 percent, moved 17 percent down", "it stops at the edge")
        var screen = try XCTUnwrap(screenPixels(app))
        var hole = frameRect(stage)
        // The top edge is sampled on its straight part (the window's corners are round: 22 % of its side).
        XCTAssertTrue(screen.average(in: CGRect(x: hole.midX - 70, y: hole.minY + 4, width: 20, height: 6)).near(.red, 34), "no gap at the top edge")
        XCTAssertTrue(screen.average(in: CGRect(x: hole.minX + 4, y: hole.midY - 60, width: 6, height: 20)).near(.red, 34), "nor at the side")
        shot(app, "framer-dragged")
        // Pinch out: the zoom grows, the slider follows, and both stop at the end.
        let before = slider.normalizedSliderPosition
        stage.pinch(withScale: 1.8, velocity: 1.2)
        XCTAssertGreaterThan(zoom(stage), 110, "pinching zooms in: \(stage.value ?? "")")
        XCTAssertGreaterThan(slider.normalizedSliderPosition, before + 0.02, "the slider follows")
        for _ in 0..<5 where zoom(stage) < 500 { stage.pinch(withScale: 3, velocity: 2) }
        XCTAssertEqual(zoom(stage), 500, "the zoom stops at five times")
        XCTAssertEqual(slider.normalizedSliderPosition, 1, accuracy: 0.02, "the slider is at its right end")
        shot(app, "framer-zoomed-in")
        // Double tap: back to the start.
        stage.doubleTap()
        XCTAssertTrue(waitUntil(timeout: 3) { (stage.value as? String) == "100 percent, centered" }, "double tap resets: \(stage.value ?? "")")
        app.buttons["photo-framer.cancel"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !stage.exists })

        // A very wide photo, slider to the left end: the whole photo is in the frame, the gaps blurred, not black.
        pickPhoto(app)
        _ = waitForFramer(app)
        slider.adjust(toNormalizedSliderPosition: 0)
        XCTAssertTrue(waitUntil(timeout: 4) { self.zoom(stage) == 25 }, "the smallest zoom fits a 4:1 photo: \(stage.value ?? "")")
        XCTAssertEqual(stage.value as? String, "25 percent, centered")
        Thread.sleep(forTimeInterval: 0.5)
        screen = try XCTUnwrap(screenPixels(app))
        hole = frameRect(stage)
        let band = CGRect(x: hole.minX, y: hole.midY - hole.height / 8, width: hole.width, height: hole.height / 4)
        XCTAssertEqual(screen.quarters(of: band), Pixels.uprightQuarters, "the whole photo, edge to edge")
        let gap = screen.average(in: CGRect(x: hole.midX - 60, y: hole.minY + hole.height * 0.12, width: 120, height: 20))
        XCTAssertGreaterThan(gap.luminance, 0.04, "the gap is the blurred photo, not black: \(gap)")
        XCTAssertGreaterThan(gap.r + gap.g + gap.b, 40, "\(gap)")
        shot(app, "framer-zoomed-out-backdrop")
        slider.adjust(toNormalizedSliderPosition: 1)
        XCTAssertTrue(waitUntil(timeout: 4) { self.zoom(stage) == 500 }, "the slider's right end: \(stage.value ?? "")")
    }

    // MARK: - P15 / P16 Choose stages; Save uploads once, then writes the kind

    @MainActor func testP15P16_ChooseStagesAndSaveUploadsThenWritesTheKind() throws {
        let app = launch(pick: ["portrait.jpg"])
        XCTAssertTrue(waitUntil(timeout: 40) { self.a.gets() >= 8 && self.rowShows(app, "ivy", .photoA) })
        let before = a.botsMeta("ivy")
        openEditBot(app, "ivy")
        let face = app.descendants(matching: .any)["edit-bot.face"], save = app.buttons["edit-bot.save"]
        // Cancel in Move and Scale: nothing changed.
        pickPhoto(app)
        var stage = waitForFramer(app)
        app.buttons["photo-framer.cancel"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !stage.exists })
        XCTAssertFalse(save.isEnabled, "Cancel stages nothing")
        XCTAssertGreaterThan(try XCUnwrapPixels(face).longestRun(of: .photoA), 30, "still photo A")
        // Choose: the framed photo is the face, Save lights up, the gateway has heard nothing.
        pickPhoto(app)
        stage = waitForFramer(app)
        app.buttons["photo-framer.choose"].tap()
        XCTAssertTrue(waitUntil(timeout: 8) { !stage.exists && save.isEnabled }, "Choose stages the photo")
        XCTAssertEqual(face.label, "Ivy’s photo")
        let staged = try XCUnwrapPixels(face)
        XCTAssertEqual(staged.quarters(of: CGRect(origin: .zero, size: face.frame.size)), Pixels.uprightQuarters, "the 72 pt face is the framed photo")
        XCTAssertTrue(app.buttons["edit-bot.remove-picture"].exists, "a staged photo can be dropped")
        XCTAssertEqual(a.sets(), 0, "nothing is sent before Save")
        shot(app, "edit-bot-photo-staged")

        // P16: Save: the picture first, then one configure with the kind and every key the bot had.
        save.tap()
        let name = app.staticTexts["bot-info.name"]
        XCTAssertTrue(waitUntil(timeout: 15) { name.exists && !app.buttons["edit-bot.save"].exists }, "saved: back on Bot Info")
        let uploads = a.calls("profiles.set_asset", "ivy")
        XCTAssertEqual(uploads.count, 1, "one upload")
        XCTAssertTrue(equal(uploads.first?["png"], [256, 256]), "a 256 × 256 PNG: \(String(describing: uploads.first))")
        XCTAssertTrue(equal(uploads.first?["keys"], ["asset", "data", "name"]), "name, asset, data and nothing else")
        let writes = a.writes().filter { $0.method == "profiles.set_asset" || $0.method == "profiles.configure" }
        XCTAssertEqual(writes.map(\.method), ["profiles.set_asset", "profiles.configure"], "the picture, then its kind")
        let sent = ((writes.last?.params["ui_meta"] as? [String: Any])?["hermes-bots"] as? [String: Any]) ?? [:]
        XCTAssertTrue(equal(sent["imageKind"], "photo") && equal(sent["custom"], true), "imageKind photo, custom true: \(sent)")
        for (key, value) in before { XCTAssertTrue(equal(sent[key], value), "\(key) is kept: \(sent)") }
        XCTAssertEqual(Set(sent.keys), Set(before.keys).union(["imageKind", "custom"]), "and nothing else is added")
        XCTAssertEqual(a.bot("ivy")["image_kind"] as? String, "photo")
        XCTAssertEqual(a.state()["contract_4000"] as? Int, 0)
        // Every face is the new photo, with no read back from the gateway.
        Thread.sleep(forTimeInterval: 0.8)
        let screen = try XCTUnwrap(screenPixels(app))
        let around = CGRect(x: name.frame.midX - 40, y: name.frame.minY - 90, width: 80, height: 80)
        XCTAssertEqual(screen.quarters(of: around), Pixels.uprightQuarters, "Bot Info")
        shot(app, "bot-info-new-photo")
        app.buttons["bot-info.close"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { self.rowShowsQuarters(app, "ivy") }, "the list row")
        cell(app, "ivy").tap()
        let title = app.descendants(matching: .any)["chat.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(timeout: 5) { (Pixels(title)?.quarters(of: CGRect(x: 5, y: 5, width: 34, height: 34)) ?? []) == Pixels.uprightQuarters }, "the chat title")
        XCTAssertEqual(a.gets("ivy"), 1, "this phone's own save is not read back")
    }

    // MARK: - P17 Remove Picture

    @MainActor func testP17_RemovePicture() throws {
        let app = launch()
        XCTAssertTrue(waitUntil(timeout: 40) { self.a.gets() >= 8 && self.rowShowsQuarters(app, "research") })
        // A bot with a saved head: the head's copy goes back in the photo's place.
        openEditBot(app, "research")
        let face = app.descendants(matching: .any)["edit-bot.face"], save = app.buttons["edit-bot.save"]
        XCTAssertEqual(face.label, "Research’s photo")
        let remove = app.buttons["edit-bot.remove-picture"]
        XCTAssertTrue(remove.exists)
        shot(app, "edit-bot-remove-picture")
        remove.tap()
        XCTAssertTrue(waitUntil(timeout: 3) { face.label == "Research’s head" && save.isEnabled }, "staged: the head shows, Save lights up")
        XCTAssertFalse(remove.exists, "nothing left to remove")
        XCTAssertEqual(a.sets(), 0, "nothing is sent before Save")
        save.tap()
        XCTAssertTrue(waitUntil(timeout: 15) { app.staticTexts["bot-info.name"].exists && !app.buttons["edit-bot.save"].exists }, "saved")
        XCTAssertTrue(equal(a.bot("research")["avatar_png"], [288, 288]), "the head's 288 px copy: \(a.bot("research"))")
        XCTAssertEqual(a.bot("research")["image_kind"] as? String, "shape")
        app.buttons["bot-info.close"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !self.rowShowsQuarters(app, "research") }, "the row shows the head")

        // A bot with no saved head: the picture is simply cleared.
        openEditBot(app, "ivy")
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        XCTAssertTrue(waitUntil(timeout: 3) { save.isEnabled })
        save.tap()
        XCTAssertTrue(waitUntil(timeout: 15) { app.staticTexts["bot-info.name"].exists && !app.buttons["edit-bot.save"].exists })
        XCTAssertTrue(equal(a.bot("ivy")["has_avatar"], false), "cleared: \(a.bot("ivy"))")
        XCTAssertTrue(equal(a.calls("profiles.set_asset", "ivy").last?["clear"], true), "with clear")
        XCTAssertEqual(a.bot("ivy")["image_kind"] as? String, "shape")
        app.buttons["bot-info.close"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !self.rowShows(app, "ivy", .photoA) })
        XCTAssertEqual(a.state()["contract_4000"] as? Int, 0)
    }

    // MARK: - P18 a refused upload

    @MainActor func testP18_ARefusedUploadKeepsThePageAndTryAgainSaves() throws {
        let app = launch(pick: ["portrait.jpg"])
        XCTAssertTrue(waitUntil(timeout: 40) { self.a.gets() >= 8 })
        openEditBot(app, "ivy")
        let face = app.descendants(matching: .any)["edit-bot.face"], save = app.buttons["edit-bot.save"]
        stagePhoto(app)
        try a.control("/__photoheads/fail", ["method": "profiles.set_asset", "mode": "error", "count": 1])
        save.tap()
        let alert = app.alerts["Couldn’t Save the Picture"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "the failure, in words")
        XCTAssertTrue(alert.buttons["Try Again"].exists && alert.buttons["OK"].exists)
        shot(app, "alert-couldnt-save-picture")
        alert.buttons["OK"].tap()
        XCTAssertTrue(app.textFields["edit-bot.title"].waitForExistence(timeout: 3), "the page stays")
        XCTAssertEqual(face.label, "Ivy’s photo")
        XCTAssertEqual(try XCUnwrapPixels(face).quarters(of: CGRect(origin: .zero, size: face.frame.size)), Pixels.uprightQuarters, "the staged photo is kept")
        XCTAssertTrue(save.isEnabled)
        XCTAssertEqual(a.writes().filter { $0.method == "profiles.configure" }.count, 0, "a refused picture writes no kind")
        XCTAssertTrue(equal(a.bot("ivy")["image_kind"], NSNull()) || a.bot("ivy")["image_kind"] == nil)
        // Again, and Try Again from the alert this time.
        try a.control("/__photoheads/fail", ["method": "profiles.set_asset", "mode": "error", "count": 1])
        save.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        alert.buttons["Try Again"].tap()
        XCTAssertTrue(waitUntil(timeout: 15) { app.staticTexts["bot-info.name"].exists && !app.buttons["edit-bot.save"].exists }, "Try Again saves")
        XCTAssertEqual(a.calls("profiles.set_asset", "ivy").filter { $0["outcome"] as? String == "ok" }.count, 1, "one stored upload")
        XCTAssertEqual(a.bot("ivy")["image_kind"] as? String, "photo")
        app.buttons["bot-info.close"].tap()

        // A gateway that does not know the method: said in plain words.
        openEditBot(app, "inbox")
        stagePhoto(app)
        try a.control("/__photoheads/fail", ["method": "profiles.set_asset", "mode": "unknown-method", "count": 1])
        save.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        XCTAssertTrue(alert.staticTexts["This gateway can’t store bot pictures yet. Update Hermes on the computer running Hermes, then try again."].exists, "the reason")
        shot(app, "alert-gateway-cant-store-pictures")
        alert.buttons["OK"].tap()
        XCTAssertTrue(save.isEnabled, "still staged")
    }

    // MARK: - P19 an older gateway

    @MainActor func testP19_AnOlderGatewayKeepsTheHeadAlone() throws {
        let old = try PhotoFixture.load("HQN_PHOTOHEADS_OLD")
        try old.reset()
        let app = launch(old)
        Thread.sleep(forTimeInterval: 4)
        openEditBot(app, "ivy")
        XCTAssertTrue(app.buttons["edit-bot.edit-head"].waitForExistence(timeout: 5), "Edit Head")
        XCTAssertFalse(app.segmentedControls["edit-bot.picture-tabs"].exists, "no tabs")
        XCTAssertFalse(app.buttons["edit-bot.choose-image"].exists, "no Upload")
        XCTAssertFalse(app.buttons["edit-bot.remove-picture"].exists)
        shot(app, "edit-bot-older-gateway")
        app.buttons["edit-bot.edit-head"].tap()
        XCTAssertTrue(app.buttons["edit-head.shuffle"].waitForExistence(timeout: 5))
        app.buttons["edit-head.shuffle"].tap()
        app.buttons["edit-head.save"].tap()
        let note = app.staticTexts["edit-bot.head-note"]
        XCTAssertTrue(waitUntil(timeout: 10) { note.exists && note.label == "Head saved. It’s on every device on this gateway." }, "Edit Head still works")
        XCTAssertEqual(old.gets(), 0, "this gateway was never asked for a picture")
    }

    // MARK: - P22 the face is the way in (owner 2026-11-08: changing a face was hard to find under Edit › Edit Head)

    @MainActor func testP22_ChangeFaceFromTheMenuAndFromBotInfosFace() throws {
        let app = launch()
        XCTAssertTrue(waitUntil(timeout: 40) { self.a.gets() >= 8 })
        // The bot's hold menu: Change Face opens the head editor at once, over Bot Info.
        let element = cell(app, "notes")
        XCTAssertTrue(element.waitForExistence(timeout: 10), "Notes is listed")
        let change = app.buttons["Change Face"].firstMatch
        for _ in 0..<3 {
            dismissSavePassword(app)
            element.press(forDuration: 1.0)
            if change.waitForExistence(timeout: 3) { break }
        }
        XCTAssertTrue(change.exists, "Change Face in the bot's menu")
        shot(app, "change-face-menu")
        change.tap()
        let shuffle = app.buttons["edit-head.shuffle"]
        XCTAssertTrue(shuffle.waitForExistence(timeout: 8), "the head editor opens")
        shot(app, "change-face-head-editor")
        app.navigationBars.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["bot-info.name"].waitForExistence(timeout: 5), "Cancel lands on Bot Info")

        // Bot Info's face: a menu of Edit Head and a photo's two sources.
        let face = app.descendants(matching: .any)["bot-info.face"]
        XCTAssertTrue(face.waitForExistence(timeout: 5), "the face")
        XCTAssertEqual(face.label, "Notes’s head")
        shot(app, "bot-info-face-pencil")
        let head = app.buttons["Edit Head"].firstMatch
        for _ in 0..<3 { face.tap(); if head.waitForExistence(timeout: 3) { break } }
        XCTAssertTrue(head.exists && app.buttons["Photo Library"].firstMatch.exists && app.buttons["Choose File"].firstMatch.exists,
                      "Edit Head, Photo Library and Choose File")
        shot(app, "bot-info-face-menu")
        head.tap()
        XCTAssertTrue(shuffle.waitForExistence(timeout: 8), "Edit Head opens the head editor")
        XCTAssertEqual(a.sets(), 0, "nothing was sent")
    }

    @MainActor func testP22b_AnOlderGatewaysFaceOpensTheHeadEditor() throws {
        let old = try PhotoFixture.load("HQN_PHOTOHEADS_OLD")
        try old.reset()
        let app = launch(old)
        Thread.sleep(forTimeInterval: 4)
        let element = cell(app, "ivy")
        XCTAssertTrue(element.waitForExistence(timeout: 10), "Ivy is listed")
        for _ in 0..<3 {
            dismissSavePassword(app)
            element.press(forDuration: 1.0)
            if app.buttons["Bot Info"].firstMatch.waitForExistence(timeout: 3) { break }
        }
        app.buttons["Bot Info"].firstMatch.tap()
        let face = app.descendants(matching: .any)["bot-info.face"]
        XCTAssertTrue(face.waitForExistence(timeout: 8), "the face")
        face.tap()
        XCTAssertTrue(app.buttons["edit-head.shuffle"].waitForExistence(timeout: 8), "no menu: the head editor at once")
        XCTAssertFalse(app.buttons["Photo Library"].exists, "no photo on a gateway that can't store one")
    }

    // MARK: - P20 leaving with a staged photo

    @MainActor func testP20_LeavingWithAStagedPhotoAsksFirst() throws {
        let app = launch(pick: ["portrait.jpg"])
        openEditBot(app, "notes")
        stagePhoto(app)
        let face = app.descendants(matching: .any)["edit-bot.face"]
        app.navigationBars.buttons["Cancel"].tap()
        let discard = app.buttons["Discard Changes"]
        XCTAssertTrue(discard.waitForExistence(timeout: 5), "the discard question")
        shot(app, "edit-bot-discard-question")
        // Keep Editing is the question's cancel action: anchored to the bar button, iOS shows it as "tap outside".
        if app.buttons["Keep Editing"].exists { app.buttons["Keep Editing"].tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)).tap() }
        XCTAssertTrue(waitUntil(timeout: 3) { !discard.exists }, "Keep Editing stays on the page")
        XCTAssertTrue(app.buttons["edit-bot.save"].isEnabled, "Keep Editing keeps the photo")
        XCTAssertEqual(face.label, "Notes’s photo")
        // Remove Picture drops a photo that was only staged.
        app.buttons["edit-bot.remove-picture"].tap()
        XCTAssertTrue(waitUntil(timeout: 3) { face.label == "Notes’s head" && !app.buttons["edit-bot.save"].isEnabled }, "back to how it was")
        stagePhoto(app)
        app.navigationBars.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Discard Changes"].waitForExistence(timeout: 5))
        app.buttons["Discard Changes"].tap()
        XCTAssertTrue(app.buttons["bot-info.close"].waitForExistence(timeout: 5), "discarded")
        XCTAssertEqual(a.sets(), 0, "and nothing was ever sent")
    }

    // MARK: - P21 the reply peek wears the photo

    @MainActor func testP21_TheReplyPeekShowsThePhoto() throws {
        try a.control("/__photoheads/reply-delay", ["seconds": 12])
        let app = launch(arguments: ["-HQDebugPeekHold", "YES"])
        XCTAssertTrue(waitUntil(timeout: 40) { self.rowShows(app, "ivy", .photoA) })
        cell(app, "ivy").tap()
        let field = app.textViews["composer.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Ivy's chat")
        field.tap()
        field.typeText("A question for Ivy")
        let asked = a.prompts(), send = app.buttons["composer.send"]
        send.tap()
        // As the chat and push e2e do: a tap the keyboard's suggestion bar swallowed is tapped again.
        if !waitUntil(timeout: 3, { self.a.prompts() > asked }) { send.tap() }
        XCTAssertTrue(waitUntil(timeout: 5) { self.a.prompts() > asked }, "the question reached the gateway")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(cell(app, "default").waitForExistence(timeout: 8))
        cell(app, "default").tap()
        let peek = app.descendants(matching: .any)["reply-peek"]
        XCTAssertTrue(appears(peek, app, "reply-peek", timeout: 30), "Ivy's reply drops in while another chat is open")
        XCTAssertTrue(peek.label.contains("Ivy"), peek.label)
        Thread.sleep(forTimeInterval: 0.8)
        let pixels = try XCUnwrapPixels(peek)
        let face = try XCTUnwrap(pixels.box(of: .photoA), "the peek's face is photo A")
        XCTAssertEqual(face.width, 40, accuracy: 2, "40 pt: \(face)")
        XCTAssertEqual(face.height, 40, accuracy: 2)
        assertAppIconCorner(pixels, face, .photoA)
        shot(app, "reply-peek-photo")
    }

    // MARK: - P21b a reply that lands while the app is away alerts as the bot

    /// L819's alert half, as far as a simulator goes (no pushed alert reaches one from a gateway): a reply that lands
    /// while the app is on the Home Screen is posted by the app itself with the bot as its sender. In the build that
    /// may send Communication Notifications (the original record's: HQ_IDENTITY=original) the sender's picture is the
    /// bot's photo; the other build has no such entitlement and iOS shows the app's icon.
    @MainActor func testP21b_AReplyWhileAwayAlertsWithThePhoto() throws {
        try a.control("/__photoheads/reply-delay", ["seconds": 10])
        let app = launch()
        dismissSetupOffer(app)
        XCTAssertTrue(waitUntil(timeout: 40) { self.rowShows(app, "ivy", .photoA) })
        allowNotifications(app)
        cell(app, "ivy").tap()
        let field = app.textViews["composer.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Ivy's chat")
        field.tap()
        field.typeText("A question for Ivy")
        let asked = a.prompts(), send = app.buttons["composer.send"]
        send.tap()
        if !waitUntil(timeout: 3, { self.a.prompts() > asked }) { send.tap() }
        XCTAssertTrue(waitUntil(timeout: 5) { self.a.prompts() > asked }, "the question reached the gateway")
        // Back on the list (a chat left open keeps its own replies quiet), then away.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(cell(app, "default").waitForExistence(timeout: 8))
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(springboard.icons.firstMatch.waitForExistence(timeout: 10), "the Home Screen")
        let banner = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'm Ivy.'")).firstMatch
        guard banner.waitForExistence(timeout: 40) else {
            dump(springboard, "no-banner")
            return XCTFail("Ivy's reply alerts while the app is away (app state \(app.state.rawValue))")
        }
        XCTAssertNotEqual(app.state, .runningForeground, "the app was away when it alerted")
        Thread.sleep(forTimeInterval: 0.7)
        let screenshot = springboard.screenshot()
        let frame = banner.frame, screen = springboard.frame.size
        XCTAssertTrue(banner.label.localizedCaseInsensitiveContains("Ivy"), "the alert is from Ivy: \(banner.label)")
        let identity = AppFiles.isOriginal ? "original" : "native"
        let mode = ProcessInfo.processInfo.environment["HQN_SHOTS_DARK"] == "1" ? "dark" : "light"
        if let dir = ProcessInfo.processInfo.environment["HQN_SHOTS"], !dir.isEmpty {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("photoheads-alert-reply-while-away-\(identity)-\(mode).png"))
        }
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "photoheads-alert-reply-while-away-\(identity)-\(mode)"
        attachment.lifetime = .keepAlways
        add(attachment)
        // The sender's picture sits at the banner's leading end: a flat field of photo A, or not there at all.
        let image = try XCTUnwrap(screenshot.image.cgImage)
        let pixels = try XCTUnwrap(Pixels(image, points: screen))
        let band = CGRect(x: 0, y: max(0, frame.minY - 40), width: screen.width, height: frame.height + 80)
        let photoRun = pixels.longestRun(of: .photoA, in: band)
        if AppFiles.isOriginal {
            XCTAssertGreaterThanOrEqual(photoRun, 14, "the sender's picture is Ivy's photo (banner \(frame))")
        } else {
            XCTAssertLessThan(photoRun, 14, "this build sends no sender picture: if it starts to, assert the photo here (banner \(frame))")
        }
        app.activate()
        XCTAssertTrue(cell(app, "ivy").waitForExistence(timeout: 10))
    }

    // MARK: - §12 STRESS PLAN, the repeatable part

    /// 12.1.6 (short form) and 12.5.11: photos saved one after another land in order, the face ends on the last one,
    /// and a double tap on Choose or Save does its work once.
    @MainActor func testS1_SavingPhotosInTurnAndDoubleTaps() throws {
        let app = launch(pick: ["portrait.jpg", "landscape.jpg", "p3.png", "square.heic"])
        XCTAssertTrue(waitUntil(timeout: 40) { self.a.gets() >= 8 })
        let folder = try XCTUnwrap(AppFiles.photoFolders().first)
        // The launch's pictures are written behind the list (a utility-priority queue): counted once they have all
        // landed, not while one is still on its way (stress round 1: 5 counted, 6 a moment later).
        func names() -> [String] { AppFiles.files(in: folder).map(\.name).sorted() }
        var filesBefore = names(), still = Date()
        XCTAssertTrue(waitUntil(timeout: 30) {
            let now = names()
            if now != filesBefore { filesBefore = now; still = Date() }
            return Date().timeIntervalSince(still) >= 3
        }, "the launch's pictures have all landed: \(filesBefore)")
        for round in 1...4 {
            openEditBot(app, "ivy")
            pickPhoto(app)
            let stage = waitForFramer(app)
            let choose = app.buttons["photo-framer.choose"]
            if round == 1 { choose.doubleTap() } else { choose.tap() }
            let save = app.buttons["edit-bot.save"]
            XCTAssertTrue(waitUntil(timeout: 8) { !stage.exists && save.isEnabled }, "round \(round): staged")
            if round == 2 { save.doubleTap() } else { save.tap() }
            XCTAssertTrue(waitUntil(timeout: 15) { app.staticTexts["bot-info.name"].exists && !save.exists }, "round \(round): saved")
            XCTAssertTrue(app.buttons["bot-info.close"].waitForExistence(timeout: 5), "round \(round): one page back, not two")
            XCTAssertEqual(a.sets("ivy"), round, "round \(round): one upload a save")
            app.buttons["bot-info.close"].tap()
            XCTAssertTrue(cell(app, "ivy").waitForExistence(timeout: 5))
        }
        let uploads = a.calls("profiles.set_asset", "ivy")
        XCTAssertEqual(Set(uploads.compactMap { $0["sha"] as? String }).count, 4, "four different pictures, in the order they were saved")
        XCTAssertEqual(a.bot("ivy")["avatar_sha"] as? String, uploads.last?["sha"] as? String, "the gateway holds the last one")
        XCTAssertTrue(rowShowsQuarters(app, "ivy"))
        XCTAssertEqual(a.gets("ivy"), 1, "none of them was read back")
        XCTAssertEqual(a.state()["contract_4000"] as? Int, 0)
        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertEqual(names(), filesBefore, "the kept photos do not pile up")
    }

    // MARK: - S8 the page holds while a photo is saving (stress round 1)

    /// A slow upload: the sheet cannot be pulled down, nothing asks to discard, and the save lands once, whole.
    @MainActor func testS8_ThePageHoldsWhileAPhotoIsSaving() throws {
        let app = launch(pick: ["portrait.jpg"])
        XCTAssertTrue(waitUntil(timeout: 40) { self.a.gets() >= 8 })
        openEditBot(app, "ivy")
        stagePhoto(app)
        let save = app.buttons["edit-bot.save"], discard = app.buttons["Discard Changes"]
        // Before Save the pull down asks, as it always did; Keep Editing stays.
        pullDown(app, from: save)
        XCTAssertTrue(appears(discard, app, "s8-question-before-save", timeout: 5), "a staged photo: the pull down asks first")
        if app.buttons["Keep Editing"].exists { app.buttons["Keep Editing"].tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)).tap() }
        XCTAssertTrue(waitUntil(timeout: 3) { !discard.exists })

        try a.control("/__photoheads/fail", ["method": "profiles.set_asset", "mode": "slow", "count": 1, "seconds": 22])
        save.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { save.label == "Saving…" }, "Saving…: \(save.label)")
        XCTAssertFalse(app.navigationBars.buttons["Cancel"].isEnabled, "Cancel waits for the save")
        func answered() -> Bool { a.calls("profiles.set_asset", "ivy").contains { $0["outcome"] as? String == "ok" } }
        var pullsWhileSaving = 0
        for pull in 1...3 {
            // Only while the gateway still holds the upload: once it has answered, the page closes by itself.
            guard !answered(), save.exists else { break }
            pullDown(app, from: save)
            XCTAssertFalse(discard.waitForExistence(timeout: 1.5), "pull \(pull): nothing asks to discard a save on its way")
            let held = save.exists && app.descendants(matching: .any)["edit-bot.face"].exists
            if !answered() {
                XCTAssertTrue(held, "pull \(pull): the page holds while the upload is still out")
                pullsWhileSaving += 1
            }
            if pull == 1 { shot(app, "edit-bot-holds-while-saving") }
        }
        XCTAssertGreaterThanOrEqual(pullsWhileSaving, 1, "at least one pull landed while the upload was still out")
        // The save lands: one upload, its kind written, the page closes by itself, this phone shows the photo.
        XCTAssertTrue(waitUntil(timeout: 30) { app.staticTexts["bot-info.name"].exists && !save.exists }, "saved, back on Bot Info")
        XCTAssertFalse(discard.exists, "no question left over Bot Info")
        XCTAssertEqual(app.alerts.count, 0, "no alert")
        XCTAssertEqual(a.calls("profiles.set_asset", "ivy").filter { $0["outcome"] as? String == "ok" }.count, 1, "one stored upload")
        XCTAssertEqual(a.writes().filter { $0.method == "profiles.configure" }.count, 1, "the kind, once")
        XCTAssertEqual(a.bot("ivy")["image_kind"] as? String, "photo")
        // Bot Info has nothing unsaved now: it closes on the first pull.
        pullDown(app, from: app.buttons["bot-info.close"])
        XCTAssertTrue(waitUntil(timeout: 5) { !app.staticTexts["bot-info.name"].exists }, "Bot Info closes freely again")
        XCTAssertFalse(discard.exists)
        XCTAssertTrue(rowShowsQuarters(app, "ivy"), "the list shows the saved photo")
    }

    /// Drags a sheet down by the middle of its bar (level with one of the bar's buttons), most of the way down the screen.
    @MainActor func pullDown(_ app: XCUIApplication, from button: XCUIElement) {
        let top = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.midX, dy: button.frame.midY))
        top.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
    }

    /// 12.3.4: the gateway goes away under a staged photo; Save says so and keeps it; Try Again stores it once.
    @MainActor func testS2_NoGatewayOnSaveThenTryAgain() throws {
        // The upload's own wait is 30 s (`BotPhotoTiming.uploadTimeout`: the unit test `theUploadWaitIsThirtySeconds`
        // pins the number and `aNewPhotoGoesUpFirstThenItsKindInOneConfigure` that the upload is sent with it). Here
        // it is 5 s (`-HQDebugUploadTimeout`), so the test can hold the alert to a narrow window instead of a wide one.
        let app = launch(pick: ["portrait.jpg"], arguments: ["-HQDebugUploadTimeout", "5"])
        XCTAssertTrue(waitUntil(timeout: 40) { self.a.gets() >= 8 })
        openEditBot(app, "ivy")
        stagePhoto(app)
        try a.control("/__photoheads/net", ["mode": "down"])
        defer { _ = try? a.control("/__photoheads/net", ["mode": "up"]) }
        Thread.sleep(forTimeInterval: 1)
        let save = app.buttons["edit-bot.save"]
        XCTAssertTrue(save.isEnabled)
        let before = Date()
        save.tap()
        let tapped = Date()
        let alert = app.alerts["Couldn’t Save the Picture"]
        XCTAssertTrue(alert.waitForExistence(timeout: 20), "the failure shows")
        let seen = Date()
        // Two clocks: the tap landed somewhere between `before` and `tapped` (the runner waits for the app to be idle
        // first), so the alert is never earlier than 5 s after `before` and, late, at most 9 s after `tapped`.
        XCTAssertGreaterThanOrEqual(seen.timeIntervalSince(before), 5, "not before the upload's own wait is over")
        XCTAssertLessThan(seen.timeIntervalSince(tapped), 9, "and no later than 4 s after it (the wait is 5 s in this run)")
        XCTAssertTrue(alert.staticTexts["The gateway didn’t answer. Check the connection and try again."].exists, "the reason")
        shot(app, "alert-gateway-didnt-answer")
        try a.control("/__photoheads/net", ["mode": "up"])
        alert.buttons["OK"].tap()
        let face = app.descendants(matching: .any)["edit-bot.face"]
        XCTAssertEqual(face.label, "Ivy’s photo", "the staged photo is still there")
        XCTAssertTrue(app.buttons["edit-bot.save"].isEnabled)
        // The app reconnects by itself; Save again once it has.
        var saved = false
        for _ in 0..<6 where !saved {
            Thread.sleep(forTimeInterval: 4)
            app.buttons["edit-bot.save"].tap()
            if alert.waitForExistence(timeout: 6) { alert.buttons["OK"].tap() } else {
                saved = waitUntil(timeout: 10) { app.staticTexts["bot-info.name"].exists && !app.buttons["edit-bot.save"].exists }
            }
        }
        XCTAssertTrue(saved, "saved once the gateway is back")
        XCTAssertEqual(a.calls("profiles.set_asset", "ivy").filter { $0["outcome"] as? String == "ok" }.count, 1, "exactly one stored upload")
        XCTAssertEqual(a.bot("ivy")["image_kind"] as? String, "photo")
    }

    /// 12.3.7: the picture lands but its kind is refused: the photo shows, the alert is the usual one, and Try Again
    /// sends the kind alone.
    @MainActor func testS3_ThePictureLandsButItsKindIsRefused() throws {
        let app = launch(pick: ["portrait.jpg"])
        XCTAssertTrue(waitUntil(timeout: 40) { self.a.gets() >= 8 })
        openEditBot(app, "ivy")
        stagePhoto(app)
        try a.control("/__settings/fail", ["method": "profiles.configure", "mode": "error", "count": 1])
        app.buttons["edit-bot.save"].tap()
        let alert = app.alerts["Couldn’t Save Changes"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "the usual alert")
        XCTAssertEqual(a.sets("ivy"), 1, "the picture is on the gateway")
        alert.buttons["Try Again"].tap()
        XCTAssertTrue(waitUntil(timeout: 15) { app.staticTexts["bot-info.name"].exists && !app.buttons["edit-bot.save"].exists }, "Try Again saves")
        XCTAssertEqual(a.sets("ivy"), 1, "the picture is not sent twice")
        XCTAssertEqual(a.bot("ivy")["image_kind"] as? String, "photo")
        app.buttons["bot-info.close"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { self.rowShowsQuarters(app, "ivy") }, "the photo shows")
    }

    /// 12.4.2 and 12.4.3: every kind of picture opens in Move and Scale the right way up, eight EXIF orientations too.
    @MainActor func testS4_EveryKindOfPictureOpensUpright() throws {
        let quartered = (1...8).map { "orient-\($0).jpg" } + ["p3.png", "square.heic", "anim.gif", "landscape.jpg", "tiny.png"]
        let others = ["cmyk.jpg", "alpha.png", "tall.png"]
        let app = launch(pick: quartered + others)
        openEditBot(app, "notes")
        let stage = app.descendants(matching: .any)["photo-framer.stage"]
        for file in quartered {
            pickPhoto(app)
            _ = waitForFramer(app)
            XCTAssertEqual(try quartersInFrame(app, stage), Pixels.uprightQuarters, "\(file) is upright")
            if file == "orient-5.jpg" { shot(app, "framer-orientation-5") }
            app.buttons["photo-framer.cancel"].tap()
            XCTAssertTrue(waitUntil(timeout: 5) { !stage.exists }, file)
        }
        for file in others {
            pickPhoto(app)
            _ = waitForFramer(app)
            XCTAssertFalse(app.alerts.firstMatch.exists, "\(file) is a picture this app reads")
            let hole = frameRect(stage)
            let middle = try XCTUnwrap(screenPixels(app)).average(in: hole.insetBy(dx: hole.width * 0.3, dy: hole.height * 0.3))
            XCTAssertGreaterThan(middle.luminance, 0.08, "\(file) is drawn: \(middle)")
            shot(app, "framer-\(file.replacingOccurrences(of: ".", with: "-"))")
            app.buttons["photo-framer.choose"].tap()
            let face = app.descendants(matching: .any)["edit-bot.face"]
            XCTAssertTrue(waitUntil(timeout: 8) { !stage.exists && face.label == "Notes’s photo" }, "\(file) can be chosen")
        }
        XCTAssertEqual(a.sets(), 0)
    }

    /// 12.5.1 (short form): Move and Scale keeps its photo and placement through a trip to the Home Screen. (12.5.3,
    /// turning the phone, cannot happen: the app is portrait only.)
    @MainActor func testS5_TheHomeScreenAndBackKeepsThePlacement() throws {
        let app = launch(pick: ["portrait.jpg"])
        openEditBot(app, "notes")
        pickPhoto(app)
        let stage = waitForFramer(app)
        let centre = stage.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        centre.press(forDuration: 0.1, thenDragTo: centre.withOffset(CGVector(dx: 0, dy: 300)), withVelocity: .slow, thenHoldForDuration: 0.1)
        stage.pinch(withScale: 1.6, velocity: 1.2)
        let placed = try XCTUnwrap(stage.value as? String)
        XCTAssertNotEqual(placed, "100 percent, centered")
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 5)
        app.activate()
        XCTAssertTrue(stage.waitForExistence(timeout: 8), "Move and Scale is still up")
        XCTAssertEqual(stage.value as? String, placed, "the same photo and placement after the Home Screen")
        XCTAssertEqual(stage.label, "Photo")
        app.buttons["photo-framer.choose"].tap()
        let face = app.descendants(matching: .any)["edit-bot.face"]
        XCTAssertTrue(waitUntil(timeout: 8) { !stage.exists && face.label == "Notes’s photo" }, "Choose still works")
        XCTAssertEqual(a.sets(), 0)
    }

    /// 12.6.1, 12.1.3 and 12.1.4: quitting with a staged photo writes nothing; what this phone keeps is small.
    @MainActor func testS6_QuittingWithAStagedPhotoAndWhatIsKept() throws {
        var app = launch(pick: ["portrait.jpg"])
        // (Huge's own row starts under the tab bar; its kept file is what is checked here.)
        XCTAssertTrue(waitUntil(timeout: 40) { self.a.gets() >= 8 && self.a.gets("huge") >= 1 && self.rowShowsQuarters(app, "research") }, "every picture was read")
        Thread.sleep(forTimeInterval: 2.5)
        let folder = try XCTUnwrap(AppFiles.photoFolders().first, "the kept photos")
        let files = AppFiles.files(in: folder)
        let pictures = files.filter { $0.name.hasSuffix(".png") }
        XCTAssertEqual(pictures.count, 5, "one file a photo (ivy, research, deploys, webp, huge): \(files)")
        for file in pictures {
            XCTAssertLessThan(file.bytes, 400_000, "\(file.name) is small")
            let size = try XCTUnwrap(AppFiles.pngSize(folder.appendingPathComponent(file.name)), "\(file.name) is a PNG")
            XCTAssertTrue(size.0 <= 256 && size.1 <= 256, "\(file.name) is 256 px at most: \(size)")
        }
        XCTAssertLessThan(files.reduce(0) { $0 + $1.bytes }, 1_500_000, "the whole folder: \(files)")
        // That this gateway stores pictures is kept with them, so the next launch knows it before the gateway answers.
        let index = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("index.json"))) as? [String: Any]
        XCTAssertEqual(index?["assets"] as? Bool, true, "index.json: \(index?.keys.sorted() ?? [])")

        openEditBot(app, "ivy")
        stagePhoto(app)
        app.terminate()
        // A pick the last run never finished reading (the app was closed under it) left its file: up to 32 MB that
        // nothing else would remove until iOS clears `tmp`.
        let picks = try XCTUnwrap(AppFiles.picksFolder(), "the app's own tmp")
        try FileManager.default.createDirectory(at: picks, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 64 * 1024).write(to: picks.appendingPathComponent("left-by-a-closed-pick.jpg"))
        XCTAssertEqual(AppFiles.pickLeftovers(), ["left-by-a-closed-pick.jpg"])
        app = XCUIApplication()
        app.launchArguments = ["-HQDebugNoDrag", "YES"] + appearanceArguments
        app.launch()
        XCTAssertTrue(cell(app, "ivy").waitForExistence(timeout: 25))
        XCTAssertTrue(waitUntil(timeout: 8) { self.rowShows(app, "ivy", .photoA) }, "Ivy still wears photo A")
        XCTAssertTrue(waitUntil(timeout: 8) { AppFiles.pickLeftovers().isEmpty }, "the next launch clears what a pick left: \(AppFiles.pickLeftovers())")
        XCTAssertEqual(a.sets(), 0, "the gateway never heard of the staged photo")
        XCTAssertEqual(a.bot("ivy")["avatar_png"].map { equal($0, [256, 256]) }, true)
        XCTAssertEqual(AppFiles.files(in: folder).filter { $0.name.hasSuffix(".png") }.count, 5, "and nothing new is kept")
    }

    /// 12.7.1: the largest text size: the Picture section and Move and Scale still fit and work.
    @MainActor func testS7_LargestTextSize() throws {
        let app = launch(pick: ["portrait.jpg"], arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertTrue(waitUntil(timeout: 40) { self.a.gets() >= 8 })
        openEditBot(app, "ivy")
        // At accessibility sizes the two tabs are a menu row ("Type"), whose words grow with the text.
        let tabs = app.buttons["edit-bot.picture-tabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 5), "the Type row")
        XCTAssertTrue(tabs.label.hasPrefix("Type") && !tabs.label.contains("Picture"), "said once: \(tabs.label)")
        let note = app.staticTexts["edit-bot.head-note"]
        XCTAssertTrue(note.exists)
        XCTAssertGreaterThan(note.frame.height, 60, "the note wraps instead of clipping: \(note.frame)")
        shot(app, "edit-bot-largest-text-head")
        tabs.tap()
        let upload = app.buttons["Upload"].firstMatch
        XCTAssertTrue(upload.waitForExistence(timeout: 3), "the menu offers Upload")
        upload.tap()
        let choose = app.buttons["edit-bot.choose-image"]
        XCTAssertTrue(choose.waitForExistence(timeout: 3))
        let remove = app.buttons["edit-bot.remove-picture"]
        for _ in 0..<3 where !remove.isHittable { app.swipeUp() }
        XCTAssertTrue(remove.isHittable, "Remove Picture can be reached")
        shot(app, "edit-bot-largest-text-upload")
        for _ in 0..<3 where !choose.isHittable { app.swipeDown() }
        pickPhoto(app)
        let stage = waitForFramer(app)
        let slider = app.sliders["photo-framer.zoom"], pick = app.buttons["photo-framer.choose"], cancel = app.buttons["photo-framer.cancel"]
        XCTAssertTrue(slider.isHittable && pick.isHittable && cancel.isHittable, "every control is on screen")
        XCTAssertGreaterThanOrEqual(frameRect(stage).width, 160)
        XCTAssertGreaterThanOrEqual(slider.frame.height, 44)
        XCTAssertGreaterThanOrEqual(min(pick.frame.height, cancel.frame.height), 36, "the bar's own buttons: \(pick.frame) \(cancel.frame)")
        shot(app, "framer-largest-text")
        pick.tap()
        XCTAssertTrue(waitUntil(timeout: 8) { !stage.exists && app.buttons["edit-bot.save"].isEnabled })
    }

    // MARK: - Helpers

    var appearanceArguments: [String] {
        let environment = ProcessInfo.processInfo.environment
        return (environment["HQN_SHOTS_DARK"] == "1" ? ["-hqn.appearance", "dark"] : [])
            + (environment["HQN_UI_DESKTOPLOOK"] == "1" ? ["-HQDebugDesktopLook", "YES"] : [])
    }

    /// A clean phone signed in to a fixture (the sign-in comes from the launch environment: no typing, no "Save
    /// Password?"). `pick`: the files Upload › Choose an image… takes in turn instead of the system picker.
    @MainActor func launch(_ fixture: PhotoFixture? = nil, pick: [String] = [], arguments: [String] = []) -> XCUIApplication {
        let gateway = fixture ?? a!
        let app = XCUIApplication()
        var all = ["-HQDebugResetAccounts", "YES", "-HQDebugNoDrag", "YES"] + appearanceArguments + arguments
        if !pick.isEmpty { all += ["-HQDebugBotPhoto", pick.map { (media as NSString).appendingPathComponent($0) }.joined(separator: ",")] }
        app.launchArguments = all
        app.launchEnvironment = ["HQN_SIGNIN_URL": gateway.url, "HQN_SIGNIN_USERNAME": gateway.username, "HQN_SIGNIN_PASSWORD": gateway.password]
        app.launch()
        let ivy = app.cells["bot-row-ivy"]
        if !ivy.waitForExistence(timeout: 30) {
            dismissSavePassword(app, wait: 2)
            XCTAssertTrue(appears(ivy, app, "launch", timeout: 15), "signed in: the Bots list shows")
        }
        return app
    }

    /// A bot's cell: a row, or a tile when it is pinned.
    @MainActor func cell(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let row = app.cells["bot-row-\(id)"]
        if row.exists { return row }
        let tile = app.cells["bot-tile-\(id)"]
        return tile.exists ? tile : row
    }

    /// Scrolls the Bots list until a bot's cell is clear of the tab bar (a cell's screenshot is what the screen shows there).
    @MainActor func reveal(_ app: XCUIApplication, _ id: String) {
        let list = app.collectionViews["bots.list"], bar = app.tabBars.firstMatch
        for _ in 0..<5 {
            let element = cell(app, id)
            let limit = (bar.exists ? bar.frame.minY : app.windows.firstMatch.frame.maxY) - 8
            if element.exists, element.frame.maxY <= limit { return }
            let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -160)), withVelocity: .slow, thenHoldForDuration: 0.2)
        }
    }

    /// The part of a row its face is in (the leading third), so a badge at the other end is not read as a face.
    @MainActor private func facePixels(_ app: XCUIApplication, _ id: String) -> (Pixels, CGRect)? {
        let element = cell(app, id)
        guard element.exists, let pixels = Pixels(element) else { return nil }
        let size = element.frame.size
        let isRow = element.identifier.hasPrefix("bot-row-")
        return (pixels, CGRect(x: 0, y: 0, width: isRow ? min(size.width * 0.3, 120) : size.width, height: size.height))
    }

    /// Whether a bot's cell shows a picture with a flat field of `colour` (at least 14 pt of it in one stretch).
    @MainActor func rowShows(_ app: XCUIApplication, _ id: String, _ colour: RGB) -> Bool {
        guard let (pixels, region) = facePixels(app, id) else { return false }
        return pixels.longestRun(of: colour, in: region) >= 14
    }

    /// Whether a bot's cell shows the four-quarter picture, the right way up.
    @MainActor func rowShowsQuarters(_ app: XCUIApplication, _ id: String) -> Bool {
        guard let (pixels, region) = facePixels(app, id), let box = pixels.colourfulBox(in: region) else { return false }
        return box.width >= 24 && abs(box.width - box.height) <= 4 && pixels.quarters(of: box) == Pixels.uprightQuarters
    }

    @MainActor func screenPixels(_ app: XCUIApplication) -> Pixels? {
        guard let image = app.screenshot().image.cgImage else { return nil }
        return Pixels(image, points: app.windows.firstMatch.frame.size)
    }

    @MainActor func XCUnwrapPixels(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) throws -> Pixels {
        try XCTUnwrap(Pixels(element), "a screenshot of \(element)", file: file, line: line)
    }

    /// A tile with app-icon corners: the picture reaches 9 % in from a corner (a circle would not) and is cut 4 % in
    /// (a bare square would not be). For a 34 pt face that brackets the corner radius between 4.6 and 10.4 pt.
    /// `topTrailing`: that corner instead (Bot Info's face wears its pencil on the bottom-right one; photo A's top-left
    /// has its black mark).
    func assertAppIconCorner(_ pixels: Pixels, _ face: CGRect, _ colour: RGB, topTrailing: Bool = false,
                             file: StaticString = #filePath, line: UInt = #line) {
        let side = face.width
        func at(_ share: CGFloat) -> CGPoint {
            topTrailing ? CGPoint(x: face.maxX - side * share, y: face.minY + side * share)
                       : CGPoint(x: face.maxX - side * share, y: face.maxY - side * share)
        }
        let inside = pixels.colour(at: at(0.09))
        let outside = pixels.colour(at: at(0.035))
        XCTAssertTrue(inside.near(colour, 30), "not a circle: the picture reaches into the corner (\(inside))", file: file, line: line)
        XCTAssertFalse(outside.near(colour, 30), "not a bare square: the corner is rounded (\(outside))", file: file, line: line)
    }

    /// Bot Info for a bot (its hold menu), then Edit.
    @MainActor func openEditBot(_ app: XCUIApplication, _ id: String) {
        let element = cell(app, id)
        XCTAssertTrue(element.waitForExistence(timeout: 10), "\(id) is listed")
        for _ in 0..<3 {
            dismissSavePassword(app)
            element.press(forDuration: 1.0)
            if app.buttons["Bot Info"].firstMatch.waitForExistence(timeout: 3) { break }
        }
        app.buttons["Bot Info"].firstMatch.tap()
        XCTAssertTrue(appears(app.staticTexts["bot-info.name"], app, "bot-info-\(id)", timeout: 8), "Bot Info opens")
        let edit = app.buttons["bot-info.edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
        // The bar's Save is the marker: at the largest text sizes the Title field starts below the fold.
        XCTAssertTrue(appears(app.buttons["edit-bot.save"], app, "edit-bot-\(id)", timeout: 8), "Edit Bot opens")
    }

    /// Upload › Choose an image…, with its menu open.
    @MainActor func openUploadMenu(_ app: XCUIApplication) {
        let upload = app.segmentedControls["edit-bot.picture-tabs"].buttons["Upload"]
        // At accessibility sizes the two tabs are a menu row ("Type") instead.
        let row = app.buttons["edit-bot.picture-tabs"]
        let choose = app.buttons["edit-bot.choose-image"]
        XCTAssertTrue(waitUntil(timeout: 5) { upload.exists || row.exists }, "the Upload tab")
        if upload.exists {
            if !upload.isSelected { upload.tap() }
        } else if !choose.exists {
            row.tap()
            let item = app.buttons["Upload"].firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 3), "the menu offers Upload")
            item.tap()
        }
        XCTAssertTrue(choose.waitForExistence(timeout: 5), "Choose an image…")
        let library = app.buttons["Photo Library"].firstMatch
        for _ in 0..<3 {
            choose.tap()
            if library.waitForExistence(timeout: 3) { return }
        }
        dump(app, "upload-menu")
        XCTFail("the Choose an image… menu did not open")
    }

    /// Upload › Choose an image… › Photo Library (the launch's `pick` files stand in for the system picker).
    @MainActor func pickPhoto(_ app: XCUIApplication) {
        openUploadMenu(app)
        app.buttons["Photo Library"].firstMatch.tap()
    }

    /// Move and Scale with its photo loaded.
    @MainActor @discardableResult func waitForFramer(_ app: XCUIApplication) -> XCUIElement {
        let stage = app.descendants(matching: .any)["photo-framer.stage"]
        XCTAssertTrue(appears(stage, app, "framer", timeout: 10), "Move and Scale opens")
        XCTAssertTrue(waitUntil(timeout: 20) { stage.label == "Photo" }, "the photo loads: \(stage.label)")
        Thread.sleep(forTimeInterval: 0.5)       // the cover's own animation
        return stage
    }

    /// Picks the next file and takes it as it opens (Choose).
    @MainActor func stagePhoto(_ app: XCUIApplication) {
        pickPhoto(app)
        let stage = waitForFramer(app)
        app.buttons["photo-framer.choose"].tap()
        XCTAssertTrue(waitUntil(timeout: 8) { !stage.exists && app.buttons["edit-bot.save"].isEnabled }, "the photo is staged")
    }

    /// The frame's window on screen: a square in the middle of the stage, 16 pt in from its nearer edges, 420 pt at most.
    @MainActor func frameRect(_ stage: XCUIElement) -> CGRect {
        let frame = stage.frame
        let side = min(frame.width - 32, frame.height - 32, 420)
        return CGRect(x: frame.midX - side / 2, y: frame.midY - side / 2, width: side, height: side)
    }

    @MainActor func quartersInFrame(_ app: XCUIApplication, _ stage: XCUIElement) throws -> [RGB.Hue] {
        try XCTUnwrap(screenPixels(app)).quarters(of: frameRect(stage))
    }

    /// The zoom the stage reports ("120 percent, …"), as a whole number of percent.
    @MainActor func zoom(_ stage: XCUIElement) -> Int {
        Int(((stage.value as? String) ?? "").split(separator: " ").first ?? "") ?? -1
    }

    @MainActor func pullToRefresh(_ app: XCUIApplication) {
        let list = app.collectionViews["bots.list"]
        let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        start.press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
    }

    @MainActor func openTitleMenu(_ app: XCUIApplication) {
        let bar = app.navigationBars.firstMatch
        for element in [app.buttons["gateway-switcher"].firstMatch, bar.buttons["Bots"], bar.staticTexts["Bots"]] where element.waitForExistence(timeout: 2) {
            element.tap()
            return
        }
        dump(app, "title")
        XCTFail("no title to tap")
    }

    /// Types a fixture's sign-in into the Add Gateway form (the fixture's own invented values, on 127.0.0.1).
    @MainActor func typeSignIn(_ app: XCUIApplication, _ fixture: PhotoFixture) {
        let address = app.textFields["sign-in-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 15), "the sign-in form shows")
        address.tap()
        if let current = address.value as? String, !current.isEmpty, current != address.placeholderValue {
            address.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        address.typeText(fixture.url)
        let username = app.textFields["sign-in-username"]
        XCTAssertTrue(username.waitForExistence(timeout: 10))
        username.tap()
        username.typeText(fixture.username)
        let password = app.secureTextFields["sign-in-password"]
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        for _ in 0..<3 {
            for _ in 0..<5 where !password.isHittable { app.swipeUp() }
            password.tap()
            password.typeText(fixture.password)
            let typed = (password.value as? String) ?? ""
            if !typed.isEmpty, typed != password.placeholderValue { break }
        }
        let button = app.buttons["sign-in-password-button"]
        for _ in 0..<5 where !button.isHittable { app.swipeUp() }
        button.tap()
        dismissSavePassword(app, wait: 3)
    }

    /// The original record's build offers to set notifications up when the gateway has no push plugin (the stand-in
    /// has none): declined, so it never takes a tap.
    @MainActor func dismissSetupOffer(_ app: XCUIApplication) {
        guard AppFiles.isOriginal else { return }
        let offer = app.alerts.firstMatch
        if offer.waitForExistence(timeout: 6), offer.buttons["Not Now"].exists { offer.buttons["Not Now"].tap() }
    }

    /// Permission for alerts (a fresh simulator asks once): Settings › Notifications › Send Test asks; then back to Bots.
    @MainActor func allowNotifications(_ app: XCUIApplication) {
        let more = app.tabBars.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        let settingsRow = app.cells["more-row-settings"]
        for _ in 0..<4 {
            more.tap()
            if settingsRow.waitForExistence(timeout: 2), settingsRow.isHittable { break }
        }
        for _ in 0..<3 {
            settingsRow.tap()
            if app.buttons["settings.gateway-card"].waitForExistence(timeout: 3) { break }
        }
        let row = app.buttons["settings.notifications"]
        XCTAssertTrue(appears(row, app, "settings", timeout: 5), "Settings")
        row.tap()
        let list = app.collectionViews["notifications.list"]
        XCTAssertTrue(appears(list, app, "settings-notifications", timeout: 5), "Settings › Notifications opens")
        let test = app.buttons["notifications.test"]
        for _ in 0..<4 where !(test.exists && test.isHittable) { list.swipeUp() }
        test.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 6) { allow.tap() }
        // The test alert itself drops in over the bar: it is gone before the next tap.
        Thread.sleep(forTimeInterval: 7)
        app.navigationBars.buttons.element(boundBy: 0).tap()                 // back to Settings
        let close = app.buttons["settings.close"]
        if close.waitForExistence(timeout: 2) { close.tap() }
        let bots = app.tabBars.buttons["Bots"]
        if bots.waitForExistence(timeout: 3) { bots.tap() }
        XCTAssertTrue(appears(cell(app, "ivy"), app, "back-on-bots", timeout: 8), "back on Bots")
    }

    /// The frame of the last element of one kind and label in the app's whole tree, read from its description. For the
    /// buttons of a view another process draws (the Files browser), which element queries find only now and then.
    @MainActor func lastFrameInTree(_ app: XCUIApplication, of kind: String, labelled label: String) -> CGRect? {
        let wanted = "label: '\(label)'"
        guard let line = app.debugDescription.split(separator: "\n").last(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix(kind + ",") && $0.contains(wanted)
        }) else { return nil }
        // "Button, 0x10916e080, {{291.3, 92.0}, {36.7, 36.0}}, label: 'Cancel'"
        guard let open = line.range(of: "{{"), let close = line.range(of: "}}") else { return nil }
        let inside = line[open.upperBound..<close.lowerBound].split(whereSeparator: { !"0123456789.".contains($0) }).compactMap { Double($0) }
        guard inside.count == 4 else { return nil }
        return CGRect(x: inside[0], y: inside[1], width: inside[2], height: inside[3])
    }

    /// iOS offers to save a typed password, sometimes seconds later: decline it so it never takes a tap.
    @MainActor func dismissSavePassword(_ app: XCUIApplication, wait: TimeInterval = 0) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(wait)
        repeat {
            for candidate in [app.buttons["Not Now"], springboard.buttons["Not Now"]] where candidate.exists {
                candidate.tap()
                return
            }
            if wait > 0 { Thread.sleep(forTimeInterval: 0.25) }
        } while Date() < deadline
    }

    /// Waits for an element; on failure saves the tree and a screenshot as debug-<name>.
    @MainActor @discardableResult
    func appears(_ element: XCUIElement, _ app: XCUIApplication, _ name: String, timeout: TimeInterval = 5) -> Bool {
        if element.waitForExistence(timeout: timeout) { return true }
        dump(app, name)
        return false
    }

    @MainActor func dump(_ app: XCUIApplication, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["HQN_SHOTS"], !dir.isEmpty else { return }
        try? app.debugDescription.write(to: URL(fileURLWithPath: dir).appendingPathComponent("debug-photoheads-\(name).txt"), atomically: true, encoding: .utf8)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("debug-photoheads-\(name).png"))
    }

    func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return condition()
    }

    /// A screenshot into build/shots (photoheads-<name>-light|dark.png) and the test's attachments.
    @MainActor func shot(_ app: XCUIApplication, _ name: String) {
        Thread.sleep(forTimeInterval: 0.6)
        let screenshot = app.screenshot()
        let mode = ProcessInfo.processInfo.environment["HQN_SHOTS_DARK"] == "1" ? "dark" : "light"
        if let dir = ProcessInfo.processInfo.environment["HQN_SHOTS"], !dir.isEmpty {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("photoheads-\(name)-\(mode).png"))
        }
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "photoheads-\(name)-\(mode)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
