// End-to-end tests for photos and files (docs/spec/1x-attachments.md §15.2) against the attachments fixture
// (scripts/fixtures/attachments-gateway.py). Run with scripts/e2e-attachments.sh: it starts the fixture on :9723,
// passes its credentials file (TEST_RUNNER_HQN_UI_CREDENTIALS), the test media folder (TEST_RUNNER_HQN_ATTACH_MEDIA)
// and the screenshot folder (TEST_RUNNER_HQN_UI_SHOTS), and stops the fixture afterwards. Without them every test skips.
//
// Attachments are injected with the DEBUG hook `-HQDebugAttach "<abs path>,…"`, which runs the pickers' own import
// code. Every test starts from a clean phone (`-HQDebugResetAccounts YES`) and signs in through the form.

import XCTest

final class AttachmentsEndToEndTests: XCTestCase {
    private var account: FixtureAccount!
    private var media: URL!
    private var shots: URL?
    /// The app was launched with `-HQDebugAppearance dark` (screenshot names say so).
    private var dark = false

    override func setUpWithError() throws {
        continueAfterFailure = false
        account = try FixtureAccount.load()
        guard let dir = ProcessInfo.processInfo.environment["HQN_ATTACH_MEDIA"], !dir.isEmpty else {
            throw XCTSkip("Run through scripts/e2e-attachments.sh (TEST_RUNNER_HQN_ATTACH_MEDIA).")
        }
        media = URL(fileURLWithPath: dir)
        shots = ProcessInfo.processInfo.environment["HQN_UI_SHOTS"].map { URL(fileURLWithPath: $0) }
        try account.control("/__fixture/attach-reset", [:])
    }

    /// A failure carries the screen it happened on (export with `xcresulttool export attachments --only-failures`).
    override func record(_ issue: XCTIssue) {
        var issue = issue
        if issue.isFailure, Thread.isMainThread, let png = MainActor.assumeIsolated({ XCUIScreen.main.screenshot().pngRepresentation }) as Data? {
            issue.add(XCTAttachment(data: png, uniformTypeIdentifier: "public.png"))
        }
        super.record(issue)
    }

    override func tearDownWithError() throws {
        // Check 8: no attach or submit ever went out with a key Hermes refuses (4000).
        let ledger = try state()["attachLedger"] as? [[String: Any]] ?? []
        XCTAssertFalse(ledger.contains { ($0["error"] as? Int) == 4000 }, "a strict-params refusal (4000) reached the gateway")
    }

    // MARK: 1. Send photos and a file

    @MainActor func test01_SendPhotosAndFile() throws {
        let app = launch(attach: [path("photo-gps.heic"), path("chart.png"), path("report.pdf")])
        XCTAssertTrue(app.buttons["composer.tray.tile.2"].waitForExistence(timeout: 20), "three tray tiles")
        XCTAssertTrue(waitUntil(timeout: 20) { self.uploads().count == 3 }, "three uploads")
        let ups = uploads()
        for u in ups {
            let path = u["path"] as? String ?? ""
            XCTAssertNotNil(path.range(of: #"^/fixture/uploads/\.dispatch-attachments/[0-9A-F-]{36}/[^/]+$"#, options: .regularExpression), path)
        }
        let photo = try XCTUnwrap(ups.first { ($0["path"] as? String)?.hasSuffix("/photo-gps.jpg") == true }, "the HEIC arrives as photo-gps.jpg")
        XCTAssertEqual(photo["jpeg"] as? Bool, true)
        XCTAssertEqual(photo["gps"] as? Bool, false, "no location reaches the gateway")
        XCTAssertEqual(photo["camera"] as? Bool, false, "no camera metadata reaches the gateway")
        shot(app, "a01-tray-uploaded")

        type(app, "hello")
        tapSend(app)
        XCTAssertTrue(waitUntil(timeout: 20) { self.prompts().count == 1 }, "the prompt went out")
        let ledger = attachLedger()
        let attaches = ledger.filter { ["image.attach", "file.attach"].contains($0["method"] as? String) }
        XCTAssertEqual(attaches.compactMap { $0["method"] as? String }.sorted(), ["file.attach", "image.attach", "image.attach"])
        for entry in attaches {
            let keys = Set((entry["params"] as? [String: Any] ?? [:]).keys)
            XCTAssertEqual(keys, entry["method"] as? String == "file.attach" ? ["session_id", "path", "name", "profile"]
                                                                              : ["session_id", "path", "profile"])
        }
        let prompt = try XCTUnwrap(prompts().last)
        XCTAssertEqual(prompt["text"] as? String, "@file:/fixture-home/attachments/report.pdf\n\nhello")
        XCTAssertEqual((prompt["images"] as? [String])?.count, 2)
        XCTAssertTrue(waitUntil(timeout: 5) { self.deletes().count == 1 }, "the file's staging folder is deleted, the photos' never")
        let pdfFolder = ((ups.first { ($0["path"] as? String)?.hasSuffix("/report.pdf") == true })?["path"] as? String)
            .map { ($0 as NSString).deletingLastPathComponent }
        XCTAssertEqual(deletes().first?["path"] as? String, pdfFolder)

        // The bubble: a 2-photo album, a file row and the words.
        XCTAssertTrue(media(app).element(boundBy: 1).waitForExistence(timeout: 5))
        XCTAssertTrue(files(app).firstMatch.exists)
        XCTAssertTrue(message(app, "hello").exists)
        let album = media(app).element(boundBy: 0).frame
        let hellos = app.tables["chat.table"].descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'hello'"))
        let helloCount = hellos.count
        shot(app, "a02-sent-album")
        // The reply and the history read after it: one bubble, the same frames.
        XCTAssertTrue(message(app, "Received 2 image(s) and 1 file(s).").waitForExistence(timeout: 15))
        sleep(3)
        XCTAssertEqual(hellos.count, helloCount, "still one bubble after the stored row arrives")
        XCTAssertEqual(media(app).count, 2)
        XCTAssertEqual(media(app).element(boundBy: 0).frame.size, album.size, "the album keeps its frame after the stored row arrives")
        shot(app, "a03-after-refresh")
    }

    // MARK: 2. Photo only

    @MainActor func test02_PhotoOnlySendShowsJustThePhoto() throws {
        let app = launch(attach: [path("chart.png")])
        XCTAssertTrue(waitUntil(timeout: 20) { self.uploads().count == 1 })
        tapSend(app)
        XCTAssertTrue(waitUntil(timeout: 20) { self.prompts().count == 1 })
        XCTAssertEqual(prompts().last?["text"] as? String, "What do you see in this image?")
        XCTAssertTrue(media(app).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(message(app, "What do you see").exists, "a photo-only bubble draws no words")
        XCTAssertTrue(message(app, "Received 1 image(s)").waitForExistence(timeout: 15))
        shot(app, "a04-photo-only")
        // Reopened: still the photo and no words.
        app.terminate()
        let again = launch(reset: false)
        XCTAssertTrue(media(again).firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(message(again, "What do you see").exists)
    }

    // MARK: 3. Remove while uploading

    @MainActor func test03_RemoveWhileUploading() throws {
        try account.control("/__fixture/attach-control", ["uploadDelay": 3])
        let app = launch(attach: [path("chart.png"), path("badge.png")])
        let remove = app.buttons["composer.tray.remove.1"]
        XCTAssertTrue(remove.waitForExistence(timeout: 15))
        remove.tap()
        XCTAssertFalse(app.buttons["composer.tray.tile.1"].waitForExistence(timeout: 1))
        tapSend(app)
        XCTAssertTrue(waitUntil(timeout: 25) { self.prompts().count == 1 })
        XCTAssertEqual((prompts().last?["images"] as? [String])?.count, 1)
        XCTAssertEqual(attachLedger().filter { $0["method"] as? String == "image.attach" }.count, 1)
        let badge = uploads().filter { ($0["path"] as? String)?.hasSuffix("/badge.png") == true }
        let badgeFolders = Set(badge.compactMap { ($0["path"] as? String).map { ($0 as NSString).deletingLastPathComponent } })
        XCTAssertTrue(badge.isEmpty || badgeFolders.isSubset(of: Set(deletes().compactMap { $0["path"] as? String })),
                      "the removed photo never finished uploading, or its folder was deleted")
    }

    // MARK: 4. Upload failure, refusal, Try Again

    @MainActor func test04_UploadFailureRefusesThenTryAgainSends() throws {
        try account.control("/__fixture/attach-control", ["uploadFailures": 3])
        let app = launch(attach: [path("chart.png")])
        let tile = app.buttons["composer.tray.tile.0"]
        XCTAssertTrue(tile.waitForExistence(timeout: 15))
        XCTAssertTrue(waitUntil(timeout: 15) { (tile.value as? String) == "Couldn’t upload" }, "the tile shows the failure")
        shot(app, "a05-tray-failed")
        tapSend(app)
        // The refusal is the "Couldn’t Send" card docked above the composer (3x-transcript §6.3), not a transcript row.
        let body = app.staticTexts["chat.sendFailure.body"]
        // The photo goes up as "chart.jpg" (the importer re-encodes photos), so only the stem is checked.
        let refused = waitUntil(timeout: 20) { body.exists && body.label.contains("upload “chart.") }
        if !refused { shot(app, "zz-04-no-refusal") }
        XCTAssertTrue(refused, "the refusal card says why (prompts: \(prompts().count), uploads: \(list("uploads").count))")
        XCTAssertEqual(app.staticTexts["chat.sendFailure.title"].label, "Couldn’t Send")
        XCTAssertTrue(app.buttons["composer.tray.tile.0"].waitForExistence(timeout: 5), "the photo is back in the tray")
        XCTAssertTrue(prompts().isEmpty)
        shot(app, "a06-refused")
        try account.control("/__fixture/attach-control", ["uploadFailures": 0])
        app.buttons["composer.tray.tile.0"].tap()
        // The tile's menu item, not the card's own Try Again (which would send again at once).
        let again = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Try Again", "chat.sendFailure.action")).firstMatch
        XCTAssertTrue(again.waitForExistence(timeout: 5))
        again.tap()
        XCTAssertTrue(waitUntil(timeout: 15) { self.uploads().contains { ($0["status"] as? Int) == 200 } })
        tapSend(app)
        XCTAssertTrue(waitUntil(timeout: 20) { self.prompts().count == 1 })
        sleep(2)
        XCTAssertEqual(prompts().count, 1, "delivered once")
    }

    // MARK: 5. Busy: the send waits in the queue

    @MainActor func test05_BusyQueuesWithItsPhoto() throws {
        try account.control("/__fixture/plan", ["plans": [["replyText": NSNull()]]])
        let app = launch(attach: [path("chart.png")], extra: ["-HQDebugSend", "first", "-HQDebugAttachDelay", "5"])
        // The reply runs (the composer shows Stop until the photo's tile lands, then Send, which queues).
        XCTAssertTrue(waitUntil(timeout: 20) { ((try? self.state())?["running"] as? [String: Any])?["default"] as? Bool == true },
                      "the first reply runs")
        XCTAssertTrue(waitUntil(timeout: 20) { self.uploads().count == 1 })
        tapSend(app)
        let queued = app.descendants(matching: .any)["chat.queue.item"]
        XCTAssertTrue(queued.waitForExistence(timeout: 5), "the queue card shows it")
        XCTAssertTrue(app.buttons["queue.words"].label == "Photo", "the row reads Photo (its words open its menu)")
        shot(app, "a07-queued-photo")
        XCTAssertTrue(attachLedger().filter { $0["method"] as? String == "image.attach" }.isEmpty, "nothing attaches while a reply runs")
        try account.control("/__fixture/finish", ["profile": "default"])
        XCTAssertTrue(waitUntil(timeout: 20) { self.prompts().count == 2 })
        XCTAssertEqual(prompts().last?["queued"] as? Bool, true)
        let methods = attachLedger().compactMap { $0["method"] as? String }.filter { $0 != "session.resume" }
        let firstSubmit = try XCTUnwrap(methods.firstIndex(of: "prompt.submit"))
        let attach = try XCTUnwrap(methods.firstIndex(of: "image.attach"))
        XCTAssertGreaterThan(attach, firstSubmit, "the photo attaches after the first turn")
    }

    // MARK: 6. Leaving mid-send

    @MainActor func test06_LeavingMidSendStillSendsToItsChat() throws {
        try account.control("/__fixture/attach-control", ["uploadDelay": 3])
        let app = launch(attach: [path("chart.png")])
        XCTAssertTrue(app.buttons["composer.tray.tile.0"].waitForExistence(timeout: 15))
        sleep(1)
        tapSend(app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let ivy = app.cells["bot-row-ivy"]
        XCTAssertTrue(ivy.waitForExistence(timeout: 10))
        ivy.tap()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(timeout: 25) { self.prompts().count == 1 }, "the send finished after leaving")
        XCTAssertEqual(prompts().last?["profile"] as? String, "default")
        XCTAssertEqual((prompts().last?["images"] as? [String])?.count, 1)
        let ivy_rows = (((try? state())?["messages"] as? [String: Any])?["ivy"] as? [[String: Any]]) ?? []
        XCTAssertFalse(ivy_rows.contains { ($0["role"] as? String) == "user" }, "nothing went to Ivy")
    }

    // MARK: 7. Stale runtime on submit

    @MainActor func test07_StaleRuntimeReattachesAndSubmitsOnce() throws {
        try account.control("/__fixture/attach-control", ["submitStaleOnce": true])
        let app = launch(attach: [path("chart.png")])
        XCTAssertTrue(waitUntil(timeout: 20) { self.uploads().count == 1 })
        tapSend(app)
        XCTAssertTrue(waitUntil(timeout: 20) { self.prompts().count == 1 })
        let sequence = attachLedger().compactMap { entry -> String? in
            guard let m = entry["method"] as? String else { return nil }
            return entry["error"] != nil ? "\(m)(\(entry["error"]!))" : m
        }
        let start = try XCTUnwrap(sequence.firstIndex(of: "image.attach"))
        XCTAssertEqual(Array(sequence[start...]), ["image.attach", "prompt.submit(4001)", "session.resume", "image.attach", "prompt.submit"])
        let rows = (((try? state())?["messages"] as? [String: Any])?["default"] as? [[String: Any]]) ?? []
        XCTAssertEqual(rows.filter { ($0["content"] as? String)?.contains("@image:") == true }.count, 1, "one stored user row")
    }

    // MARK: 9. History shapes (light and dark)

    @MainActor func test09_HistoryShapesRenderAndRetry() throws {
        try account.control("/__fixture/attachments-history", ["profile": "default"])
        let app = launch()
        let table = app.tables["chat.table"]
        XCTAssertTrue(media(app).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Couldn’t load missing.png. Tap to try again."))
                        .firstMatch.waitForExistence(timeout: 10), "row 14 shows the retry tile")
        sleep(2)
        shot(app, "a08-history-bottom")
        var frames: [String: CGRect] = [:]
        for e in media(app).allElementsBoundByIndex where e.exists { frames[e.identifier] = e.frame }
        // Check 9: the next download fails once (`downloadFailures: 1`, set once the first screen has loaded, so it
        // lands on a photo further up rather than the generated card): that photo shows the retry tile; a tap loads it.
        try account.control("/__fixture/attach-control", ["downloadFailures": 1])
        let failed = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Couldn' AND NOT (label CONTAINS 'missing.png') AND NOT (label CONTAINS 'Open image')"))
        var retried = false
        for step in 1...3 {
            clearSavePassword(app)                  // iOS's "Save Password?" sheet would swallow the swipe
            table.swipeDown(velocity: .slow)
            sleep(2)
            shot(app, "a09-history-\(step)")
            let tile = failed.firstMatch
            guard !retried, tile.waitForExistence(timeout: 2) else { continue }
            let label = tile.label
            for _ in 0..<4 where !tile.isHittable { table.swipeDown(velocity: .slow); sleep(1) }
            XCTAssertTrue(tile.isHittable, "the retry tile can be tapped (\(label))")
            shot(app, "a09b-retry-tile")
            tile.tap()
            XCTAssertTrue(waitUntil(timeout: 10) { !app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch.exists },
                          "a tap loads it (\(label))")
            retried = true
        }
        if !retried { shot(app, "zz-09-no-retry-tile") }
        XCTAssertTrue(retried, "downloadFailures:1 shows a retry tile (downloads: \(list("downloads").map { "\($0["path"] ?? "") \($0["status"] ?? "")" }))")
        // Reopened from the cache (in dark): every image keeps its frame (sizes learnt and cached).
        app.terminate()
        let again = launch(extra: ["-HQDebugAppearance", "dark"], reset: false)
        dark = true
        XCTAssertTrue(media(again).firstMatch.waitForExistence(timeout: 10))
        sleep(2)
        for e in media(again).allElementsBoundByIndex where e.exists {
            if let before = frames[e.identifier] { XCTAssertEqual(e.frame.size, before.size, e.identifier) }
        }
        shot(again, "a10-history-bottom")
        let darkTable = again.tables["chat.table"]
        for step in 1...3 {
            darkTable.swipeDown(velocity: .slow)
            sleep(2)
            shot(again, "a11-history-\(step)")
        }
    }

    // MARK: 10. Viewer

    @MainActor func test10_ViewerPagesZoomsSavesAndShares() throws {
        try account.control("/__fixture/attachments-history", ["profile": "default"])
        let app = launch()
        let table = app.tables["chat.table"]
        // Row 5's two photos are a stack: a swipe brings the second one to the top, and a tap opens it.
        let second = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'chat.media.' AND identifier CONTAINS '.stack.'")).firstMatch
        for _ in 0..<10 where !(second.exists && second.isHittable) { table.swipeDown(velocity: .slow); sleep(1) }
        XCTAssertTrue(second.exists, "row 5's photos")
        clearSavePassword(app)
        second.swipeLeft()
        XCTAssertTrue(waitUntil(timeout: 3) { (second.value as? String)?.hasPrefix("2 of 2") == true }, "the second photo on top: \(second.value ?? "")")
        second.tap()
        XCTAssertTrue(app.buttons["viewer.close"].waitForExistence(timeout: 5), "the viewer opens")
        XCTAssertTrue(app.navigationBars["2 of 2"].exists || app.staticTexts["2 of 2"].exists, "paging over the message's photos")
        sleep(1)
        shot(app, "a12-viewer")
        let save = app.buttons["viewer.save"]
        save.tap()
        // "Saved" shows for 1.8 s; the add-only Photos prompt (if the grant didn't take) comes first.
        var saved = waitUntil(timeout: 3) { save.label == "Saved" }
        if !saved {
            let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons.matching(NSPredicate(format: "label CONTAINS 'Allow'")).firstMatch
            if allow.exists { allow.tap(); saved = waitUntil(timeout: 5) { save.label == "Saved" } }
        }
        if !saved { shot(app, "zz-10-save") }
        XCTAssertTrue(saved, "Save says Saved (\(save.label))")
        app.buttons["viewer.share"].tap()
        let sheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 5) || app.navigationBars["UIActivityContentView"].waitForExistence(timeout: 2), "the share sheet")
        shot(app, "a13-viewer-share")
        if sheet.exists { sheet.swipeDown(velocity: .fast) }
        XCTAssertTrue(waitUntil(timeout: 5) { !sheet.exists })
        XCTAssertTrue(app.buttons["viewer.close"].exists, "still in the viewer")
        // Double-tap zooms in; a swipe down then pans the picture and never dismisses (check 10).
        let viewer = app.otherElements["viewer"]
        let center = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.doubleTap()
        sleep(1)
        shot(app, "a13b-viewer-zoomed")
        let from = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        from.press(forDuration: 0.05, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
        sleep(1)
        XCTAssertTrue(viewer.exists, "a swipe down while zoomed doesn't dismiss the viewer")
        // Double-tap back to the fitted picture, then a swipe down goes back to the chat.
        center.doubleTap()
        sleep(1)
        from.press(forDuration: 0.05, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        if !waitUntil(timeout: 5, { !viewer.exists }) {
            shot(app, "zz-10-swipe-dismiss")
            if app.buttons["viewer.close"].exists { app.buttons["viewer.close"].tap() }
            XCTFail("a swipe down at the fitted size dismisses the viewer")
        }
        XCTAssertTrue(waitUntil(timeout: 5) { !viewer.exists && !app.buttons["viewer.close"].exists }, "back in the chat")
        // Long-press a photo: Save to Photos, Share…, Copy.
        second.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Save to Photos"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Share…"].exists)
        XCTAssertTrue(app.buttons["Copy Image"].exists)
        shot(app, "a14-photo-menu")
    }

    // MARK: 11. Files

    @MainActor func test11_FilesOpenInQuickLookOrShare() throws {
        try account.control("/__fixture/attachments-history", ["profile": "default"])
        let app = launch()
        let table = app.tables["chat.table"]
        let clip = files(app).matching(NSPredicate(format: "label CONTAINS 'clip.mov'")).firstMatch
        XCTAssertTrue(clip.waitForExistence(timeout: 10))
        clearSavePassword(app)
        clip.tap()
        let sheet = app.otherElements["ActivityListView"]
        let shown = sheet.waitForExistence(timeout: 10)
        if !shown { shot(app, "zz-11-clip") }
        XCTAssertTrue(shown, "a file Quick Look can't show opens the share sheet (downloads: \(list("downloads").map { "\($0["path"] ?? "") \($0["status"] ?? "")" }), hittable \(clip.isHittable) \(clip.frame))")
        shot(app, "a15-file-share")
        app.swipeDown(velocity: .fast)
        sleep(1)
        let report = files(app).matching(NSPredicate(format: "label CONTAINS 'report.pdf'")).firstMatch
        for _ in 0..<10 where !(report.exists && report.isHittable) { table.swipeDown(velocity: .slow); sleep(1) }
        XCTAssertTrue(report.exists)
        report.tap()
        let ql = app.navigationBars["report.pdf"].waitForExistence(timeout: 10) || app.staticTexts["report.pdf"].waitForExistence(timeout: 2)
            || app.otherElements["QLPreviewControllerView"].exists
        if !ql { shot(app, "zz-11-quicklook") }
        XCTAssertTrue(ql, "Quick Look shows the PDF (downloads: \(list("downloads").suffix(3).map { "\($0["path"] ?? "") \($0["status"] ?? "")" }))")
        sleep(1)
        shot(app, "a16-quick-look")
        let downloads = (try? state())?["downloads"] as? [[String: Any]] ?? []
        XCTAssertFalse(downloads.isEmpty)
        for d in downloads where (d["path"] as? String)?.hasPrefix("/") == true {
            XCTAssertTrue(d["session_id"] == nil || d["session_id"] is NSNull, "no session_id with an absolute path")
        }
    }

    // MARK: 12. Live media

    @MainActor func test12_GeneratedImageAndMediaReply() throws {
        try account.control("/__fixture/plan", ["plans": [
            ["imageGenerate": ["aspect_ratio": "portrait", "delay": 8, "image": "/fixture/media/portrait.png", "pixel_size": "576x1024"]],
            ["mediaReply": "/fixture/media/result.png"],
            ["imageGenerate": ["aspect_ratio": "square", "delay": 0.5, "image": "/fixture/media/lost.png", "text": "Done."]],
        ]])
        let app = launch(extra: ["-HQDebugSend", "draw a fox"])
        let rendering = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Rendering image'")).firstMatch
        XCTAssertTrue(rendering.waitForExistence(timeout: 15), "the card shows while it renders (prompts \(prompts().count))")
        let frame = rendering.frame
        XCTAssertEqual(frame.height / frame.width, 16.0 / 9.0, accuracy: 0.05, "9:16 before any pixel")
        shot(app, "a17-generating")
        let image = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Image, portrait.png'")).firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 15))
        XCTAssertEqual(image.frame.size, frame.size, "the frame doesn't change when the picture arrives")
        sleep(1)
        shot(app, "a18-generated")
        type(app, "and the result?")
        tapSend(app)
        let reply = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'result.png'")).firstMatch
        let replied = reply.waitForExistence(timeout: 15)
        if !replied { shot(app, "a19-fail") }
        XCTAssertTrue(replied, "an image block in the reply (prompts \(prompts().map { $0["text"] ?? "" }))")
        sleep(2)
        shot(app, "a19-media-reply")
        // A generated image that can't load offers "Open image: <name>"; a tap tries the file preview.
        type(app, "draw a moon")
        tapSend(app)
        let link = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Couldn’t load lost.png. Tap to open.")).firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 20), "the unloadable generated image offers a link")
        sleep(1)
        shot(app, "a19b-generated-unloadable")
        link.tap()
        XCTAssertTrue(app.alerts["Couldn’t Open File"].waitForExistence(timeout: 10), "a missing file says so")
        app.alerts["Couldn’t Open File"].buttons["OK"].tap()
    }

    // MARK: 13, 15. Limits and the + menu

    @MainActor func test13_LimitsAndThePlusMenu() throws {
        let app = launch(attach: [path("big.bin")])
        let alert = app.alerts["Couldn’t Attach"]
        if !alert.waitForExistence(timeout: 15) { clearSavePassword(app) }
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS 'larger than 100 MB'")).firstMatch.exists)
        shot(app, "a20-too-large")
        alert.buttons["OK"].tap()
        XCTAssertFalse(app.buttons["composer.tray.tile.0"].exists, "no tile for it")
        // The + menu: Camera is unavailable on the Simulator.
        clearSavePassword(app)
        app.buttons["composer.plus"].tap()
        XCTAssertTrue(app.buttons["Photos"].waitForExistence(timeout: 5) || app.staticTexts["Photos"].exists)
        XCTAssertTrue(app.staticTexts["Unavailable"].exists || app.buttons.matching(NSPredicate(format: "label CONTAINS 'Unavailable'")).firstMatch.exists)
        shot(app, "a21-plus-menu")
        app.tap()
        app.terminate()

        let notes = (1...17).map { path(String(format: "note-%02d.txt", $0)) }
        let full = launch(attach: notes)
        let limit = full.alerts["Couldn’t Attach"]
        if !limit.waitForExistence(timeout: 15) { clearSavePassword(full) }
        XCTAssertTrue(limit.waitForExistence(timeout: 5))
        XCTAssertTrue(limit.staticTexts["You can attach up to 16 items to one message."].exists)
        limit.buttons["OK"].tap()
        XCTAssertTrue(waitUntil(timeout: 15) { full.buttons["composer.tray.tile.15"].exists })
        XCTAssertFalse(full.buttons["composer.tray.tile.16"].exists)
        shot(full, "a22-sixteen")
        clearSavePassword(full)
        full.buttons["composer.plus"].tap()
        XCTAssertTrue(full.staticTexts["Up to 16 per message"].waitForExistence(timeout: 5)
                      || full.buttons.matching(NSPredicate(format: "label CONTAINS 'Up to 16 per message'")).firstMatch.exists)
        shot(full, "a23-plus-limit")
    }

    // MARK: Screens in dark mode

    @MainActor func test14_TrayAndBubbleInDark() throws {
        dark = true
        let app = launch(attach: [path("photo-gps.heic"), path("badge.png"), path("report.pdf")], extra: ["-HQDebugAppearance", "dark"])
        XCTAssertTrue(waitUntil(timeout: 20) { self.uploads().count == 3 })
        sleep(1)
        shot(app, "a24-tray-dark")
        type(app, "dark mode")
        tapSend(app)
        let replied = message(app, "Received 2 image(s) and 1 file(s).").waitForExistence(timeout: 20)
        sleep(2)
        shot(app, "a25-sent-dark")
        XCTAssertTrue(replied, "the reply (prompts \(prompts().map { $0["text"] ?? "" }), ledger \(attachLedger().compactMap { $0["method"] }))")
    }

    // MARK: 16. A pasted phone screenshot with a caption

    /// A tall screenshot with a long caption is a normal-width bubble (not a 150 pt sliver), and the browser plugin's
    /// steer Hermes stored after the caption never shows.
    @MainActor func test16_CaptionedScreenshotIsFullWidthWithoutPluginSteer() throws {
        try account.control("/__fixture/screenshot-history", ["profile": "default"])
        let app = launch()
        let tile = media(app).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        sleep(2)
        shot(app, "a16-captioned-screenshot")
        XCTAssertGreaterThan(tile.frame.width, 200, "the photo spans the bubble's normal width (\(tile.frame))")
        let steer = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Hermes HQ:'"))
        XCTAssertFalse(steer.firstMatch.exists, "the plugin's steer stays hidden")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'remote control setup page'"))
                        .firstMatch.exists, "the caption shows")
        app.terminate()
        let darkApp = launch(extra: ["-HQDebugAppearance", "dark"], reset: false)
        dark = true
        XCTAssertTrue(media(darkApp).firstMatch.waitForExistence(timeout: 10))
        sleep(2)
        shot(darkApp, "a16-captioned-screenshot")
    }

    // MARK: Tester reports 2026-10-26 (docs/briefs/agent-images-markdown.md)

    /// Pictures an agent names as bare paths or quoted `MEDIA:` show as pictures, never as path text; a path the
    /// gateway can't serve is a named file row that says so; your messages draw inline markdown and code fences.
    @MainActor func test17_AgentImagesAndYourMarkdown() throws {
        try account.control("/__fixture/agent-images-history", ["profile": "default"])
        for mode in ["light", "dark"] {
            dark = mode == "dark"
            let app = launch(extra: dark ? ["-HQDebugAppearance", "dark"] : [], reset: !dark)
            let table = app.tables["chat.table"]
            XCTAssertTrue(waitUntil(timeout: 20) { media(app).count >= 2 }, "the bare and quoted paths are pictures")
            let refused = files(app).matching(NSPredicate(format: "label CONTAINS 'gone-shot.png'")).firstMatch
            XCTAssertTrue(refused.waitForExistence(timeout: 20), "the missing picture is a named file row")
            XCTAssertTrue(waitUntil(timeout: 10) { refused.label.contains("not on your gateway") }, "it says why: \(refused.label)")
            sleep(2)
            shot(app, "ai1-agent-images-bottom")
            let rawPath = table.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '/fixture/media/'"))
            XCTAssertFalse(rawPath.firstMatch.exists, "no raw path text: \(rawPath.firstMatch.label)")
            XCTAssertTrue(message(app, "print(").exists, "your code fence shows its code")
            XCTAssertTrue(message(app, "- keep this dash").exists, "your typed dash stays a dash")
            table.swipeDown(velocity: .slow)
            table.swipeDown(velocity: .slow)
            sleep(2)
            shot(app, "ai2-agent-images-top")
            let yours = message(app, "Take a")
            XCTAssertTrue(yours.waitForExistence(timeout: 5))
            XCTAssertFalse(yours.label.contains("**"), "your bold draws without its stars: \(yours.label)")
            app.terminate()
        }
    }

    // MARK: Photo stacks (owner 2026-10-30)

    /// Several photos in one message are a stack you swipe through: one element that says which photo is on top, a
    /// swipe either way flips it and it goes round, the row keeps its height, the viewer opens on the top photo, and
    /// closing the viewer on another photo leaves that one on top.
    @MainActor func test19_PhotoStacksSwipeAndOpen() throws {
        try account.control("/__fixture/photo-stack-history", ["profile": "default"])
        // HQN_ATTACH_LOOK=desktop-dark: the Desktop Look too, light and dark ("dl-" shots; check every look).
        let desktop = ProcessInfo.processInfo.environment["HQN_ATTACH_LOOK"] == "desktop-dark"
        for mode in desktop ? ["light", "dark", "dl-light", "dl-dark"] : ["light", "dark"] {
            dark = mode.hasSuffix("dark")
            let tag = mode.hasPrefix("dl-") ? "dl-" : ""
            var extra = dark ? ["-HQDebugAppearance", "dark"] : []
            if !tag.isEmpty { extra += ["-HQDebugDesktopLook", "YES"] }
            let app = launch(extra: extra, reset: mode == "light")
            let table = app.tables["chat.table"]
            let stacks = table.descendants(matching: .any).matching(NSPredicate(format: "identifier CONTAINS '.stack.'"))
            let pair = stacks.matching(NSPredicate(format: "label == '2 photos'")).firstMatch
            XCTAssertTrue(pair.waitForExistence(timeout: 20), "the photo-only reply's two pictures are one stack")
            sleep(3)
            shot(app, tag + "ps1-stacks-bottom")
            func value(_ e: XCUIElement) -> String { e.value as? String ?? "" }
            XCTAssertTrue(value(pair).hasPrefix("1 of 2"), value(pair))
            let height = pair.frame.height
            pair.swipeLeft()
            XCTAssertTrue(waitUntil(timeout: 3) { value(pair).hasPrefix("2 of 2") }, "a swipe left flips to the next: \(value(pair))")
            sleep(1)
            shot(app, tag + "ps2-pair-flipped")
            XCTAssertEqual(pair.frame.height, height, "the row keeps its height as it flips")
            pair.swipeLeft()
            XCTAssertTrue(waitUntil(timeout: 3) { value(pair).hasPrefix("1 of 2") }, "past the last it goes round: \(value(pair))")
            pair.swipeRight()
            XCTAssertTrue(waitUntil(timeout: 3) { value(pair).hasPrefix("2 of 2") }, "a swipe right brings the bottom one up: \(value(pair))")
            // The viewer opens on the top photo; closing it on the other leaves that one on top.
            pair.tap()
            XCTAssertTrue(app.buttons["viewer.close"].waitForExistence(timeout: 5), "the viewer opens")
            XCTAssertTrue(app.navigationBars["2 of 2"].exists || app.staticTexts["2 of 2"].exists, "on the top photo")
            sleep(1)
            // A sideways swipe pages (it never closes the viewer, even from the edge).
            app.windows.firstMatch.swipeRight()
            if !waitUntil(timeout: 3, { app.navigationBars["1 of 2"].exists || app.staticTexts["1 of 2"].exists }) {
                shot(app, "zz-19-page")
                XCTFail("pages back")
            }
            app.buttons["viewer.close"].tap()
            XCTAssertTrue(waitUntil(timeout: 5) { !app.buttons["viewer.close"].exists }, "back in the chat")
            XCTAssertTrue(waitUntil(timeout: 3) { value(pair).hasPrefix("1 of 2") }, "the viewer's last photo is on top: \(value(pair))")
            // The reply's three screenshots (listed as bullets) and your sets further up.
            let listed = stacks.matching(NSPredicate(format: "value CONTAINS 'shot-1.png'")).firstMatch
            XCTAssertTrue(listed.waitForExistence(timeout: 5), "the listed screenshots are one stack")
            // By its identifier from here: the value names the top photo, so it changes with each flip.
            let screenshots = stacks.matching(identifier: listed.identifier).firstMatch
            screenshots.swipeLeft()
            XCTAssertTrue(waitUntil(timeout: 3) { value(screenshots).hasPrefix("2 of 3") }, value(screenshots))
            sleep(1)
            shot(app, tag + "ps3-screenshots-flipped")
            let four = stacks.matching(NSPredicate(format: "label == '4 photos'")).firstMatch
            for _ in 0..<6 where !(four.exists && four.isHittable) { table.swipeDown(velocity: .slow); sleep(1) }
            XCTAssertTrue(four.exists, "your four photos are one stack")
            sleep(2)
            shot(app, tag + "ps4-yours")
            let captioned = stacks.matching(NSPredicate(format: "label == '3 photos' AND NOT (value CONTAINS 'shot-')")).firstMatch
            XCTAssertTrue(captioned.exists, "your three photos with a caption are one stack")
            XCTAssertTrue(message(app, "Which of these three").exists, "the caption under them")
            app.terminate()
        }
    }

    /// Five pictures the bot made one after another are one stack you swipe through, and the answer after them is its
    /// own bubble, formatted (owner 2026-10-31: twenty cards in a column, then "None of that message formatted").
    @MainActor func test19b_MadePicturesStackAndTheAnswerFormats() throws {
        try account.control("/__fixture/photo-stack-history", ["profile": "default"])
        let desktop = ProcessInfo.processInfo.environment["HQN_ATTACH_LOOK"] == "desktop-dark"
        for mode in desktop ? ["light", "dark", "dl-light", "dl-dark"] : ["light", "dark"] {
            dark = mode.hasSuffix("dark")
            let tag = mode.hasPrefix("dl-") ? "dl-" : ""
            var extra = dark ? ["-HQDebugAppearance", "dark"] : []
            if !tag.isEmpty { extra += ["-HQDebugDesktopLook", "YES"] }
            let app = launch(extra: extra, reset: mode == "light")
            let table = app.tables["chat.table"]
            let stacks = table.descendants(matching: .any).matching(NSPredicate(format: "identifier CONTAINS '.stack.'"))
            func value(_ e: XCUIElement) -> String { e.value as? String ?? "" }
            XCTAssertTrue(stacks.firstMatch.waitForExistence(timeout: 20), "the chat opened")
            let made = stacks.matching(NSPredicate(format: "label == '5 photos'")).firstMatch
            for _ in 0..<10 where !(made.exists && made.isHittable) { table.swipeDown(velocity: .slow); sleep(1) }
            XCTAssertTrue(made.exists, "the five made pictures are one stack")
            XCTAssertTrue(value(made).hasPrefix("1 of 5"), value(made))
            sleep(2)
            shot(app, tag + "ps5-made-pictures")
            let madeStack = stacks.matching(identifier: made.identifier).firstMatch
            madeStack.swipeLeft()
            XCTAssertTrue(waitUntil(timeout: 3) { value(madeStack).hasPrefix("2 of 5") }, value(madeStack))
            let answer = message(app, "Five ideas, best first")
            XCTAssertTrue(answer.exists, "the answer under the pictures")
            XCTAssertFalse(answer.label.contains("**") || answer.label.contains("|---"), "drawn, not raw: \(answer.label)")
            for _ in 0..<3 where !(answer.isHittable) { table.swipeUp(velocity: .slow); sleep(1) }
            sleep(1)
            shot(app, tag + "ps6-answer-formatted")
            madeStack.tap()
            XCTAssertTrue(app.buttons["viewer.close"].waitForExistence(timeout: 5), "the viewer opens")
            XCTAssertTrue(app.navigationBars["2 of 5"].exists || app.staticTexts["2 of 5"].exists, "on the top picture, paging all five")
            sleep(1)
            shot(app, tag + "ps7-made-viewer")
            app.buttons["viewer.close"].tap()
            app.terminate()
        }
    }

    // MARK: Markdown files (owner 2026-10-29: "pretty, not raw")

    /// A Markdown file opened from a chat reads formatted in the text viewer (Preview | Source), not as Quick Look's raw
    /// text; Source still shows the marks.
    @MainActor func test18_MarkdownFileOpensFormatted() throws {
        try account.control("/__fixture/attachments-history", ["profile": "default"])
        // HQN_ATTACH_LOOK=desktop-dark: the same walk in the Desktop Look, in dark (check every look).
        let desktop = ProcessInfo.processInfo.environment["HQN_ATTACH_LOOK"] == "desktop-dark"
        dark = desktop
        let app = launch(extra: desktop ? ["-HQDebugDesktopLook", "YES", "-HQDebugAppearance", "dark"] : [])
        let table = app.tables["chat.table"]
        let notes = files(app).matching(NSPredicate(format: "label CONTAINS 'My Notes.md'")).firstMatch
        XCTAssertTrue(notes.waitForExistence(timeout: 10))
        clearSavePassword(app)
        for _ in 0..<10 where !(notes.exists && notes.isHittable) { table.swipeDown(velocity: .slow); sleep(1) }
        notes.tap()
        let body = app.textViews["artifact.text.body"]
        XCTAssertTrue(body.waitForExistence(timeout: 10), "a Markdown file opens in the text viewer, not Quick Look")
        XCTAssertTrue(waitUntil(timeout: 10) { (body.value as? String ?? "").contains("Checklist") }, "the note shows")
        let preview = body.value as? String ?? ""
        XCTAssertFalse(preview.contains("# My Notes"), "the heading is drawn, not its #")
        XCTAssertFalse(preview.contains("**"), "bold draws without its stars")
        XCTAssertFalse(app.otherElements["QLPreviewControllerView"].exists)
        sleep(1)
        shot(app, "a18-markdown-preview")
        // The iOS look's segmented control, or the Desktop Look's strip of two buttons.
        let source = desktop ? app.buttons["Source"] : app.segmentedControls["artifact.text.mode"].buttons["Source"]
        XCTAssertTrue(source.waitForExistence(timeout: 3), "Preview | Source")
        source.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { (body.value as? String ?? "").contains("# My Notes") }, "Source shows the marks")
        shot(app, "a18-markdown-source")
        app.buttons["sheet.close"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !body.exists }, "the sheet closes")
    }

    // MARK: 20. The chat keeps its place under the viewer

    /// Owner 2026-11-01: closing a photo opened from higher up the chat moved the chat to a later part. Close by the
    /// button and by a swipe down; every row is where it was both times.
    @MainActor func test20_ViewerCloseKeepsPlace() throws {
        try account.control("/__fixture/attachments-history", ["profile": "default"])
        let app = launch()
        let table = app.tables["chat.table"]
        sleep(4)
        table.swipeDown(velocity: .slow)
        sleep(2)
        let window = app.windows.firstMatch
        // Where the rows sit: each cell on screen by its label, top edge rounded.
        func place() -> [String] {
            table.cells.allElementsBoundByIndex.filter { $0.exists && $0.frame.intersects(window.frame) }
                .map { "\($0.label.prefix(40))@\(Int($0.frame.minY.rounded()))" }.sorted()
        }
        let before = place()
        XCTAssertFalse(before.isEmpty)
        shot(app, "a20-before")
        for (route, close) in [("button", { self.closeButton(app).tap() }),
                               ("swipe", { window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
                                   .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))) })] {
            // The fox, mid-screen after the scroll (a20-before).
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)).tap()
            sleep(2)
            shot(app, "a20-open-\(route)")
            XCTAssertTrue(closeButton(app).exists, "the viewer opens (\(route))")
            close()
            sleep(2)
            if closeButton(app).exists { closeButton(app).tap(); sleep(2) }   // a viewer a swipe doesn't close
            sleep(1)
            shot(app, "a20-after-\(route)")
            XCTAssertTrue(table.isHittable, "back in the chat (\(route))")
            XCTAssertEqual(place(), before, "the chat kept its place (\(route))")
        }
        // The scroll bar at the newest end reaches down behind the composer (owner 2026-11-01): a shot while it shows.
        for _ in 0..<3 { table.swipeUp(velocity: .fast) }
        sleep(2)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42)))
        shot(app, "a20-scroll-bar-bottom")
    }

    // MARK: Helpers

    private func closeButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == 'viewer.close' OR label IN %@", ["Close", "Done"])).firstMatch
    }

    private func path(_ name: String) -> String { media.appending(path: name).path }

    private func state() throws -> [String: Any] { try account.control("/__fixture/state") }
    private func list(_ key: String) -> [[String: Any]] { ((try? state())?[key] as? [[String: Any]]) ?? [] }
    private func uploads() -> [[String: Any]] { list("uploads").filter { ($0["status"] as? Int) == 200 } }
    private func deletes() -> [[String: Any]] { list("deletes") }
    private func prompts() -> [[String: Any]] { list("prompts") }
    private func attachLedger() -> [[String: Any]] { list("attachLedger") }

    @MainActor private func launch(attach: [String] = [], extra: [String] = [], reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["-HQDebugOpenBot", "default"]
        if reset { args += ["-HQDebugResetAccounts", "YES"] }
        if !attach.isEmpty { args += ["-HQDebugAttach", attach.joined(separator: ",")] }
        app.launchArguments = args + extra
        app.launch()
        let table = app.tables["chat.table"]
        let form = app.textFields["sign-in-address"]
        _ = waitUntil(timeout: 15) { table.exists || form.exists }
        if !table.exists && form.exists { signIn(app) }
        if !table.waitForExistence(timeout: 20) {
            // The launch hook opens the chat once the list has it; on a busy Mac that can lag: open it by hand.
            let row = app.cells["bot-row-default"]
            if row.waitForExistence(timeout: 10) { row.tap() }
        }
        if !table.waitForExistence(timeout: 15) { shot(app, "zz-failed-open-\(name)") }
        XCTAssertTrue(table.exists, "the chat opens")
        return app
    }

    @MainActor private func signIn(_ app: XCUIApplication) {
        let address = app.textFields["sign-in-address"]
        address.tap()
        if let current = address.value as? String, !current.isEmpty, current != "my-mac.tail1234.ts.net" {
            address.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        address.typeText(account.url)
        let username = app.textFields["sign-in-username"]
        XCTAssertTrue(username.waitForExistence(timeout: 10))
        username.tap()
        if let current = username.value as? String, !current.isEmpty, current != "Username" {
            username.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        username.typeText(account.username)
        let password = app.secureTextFields["sign-in-password"]
        password.tap()
        password.typeText(account.password)
        app.buttons["sign-in-password-button"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for candidate in [app.buttons["Not Now"], springboard.buttons["Not Now"]] where candidate.waitForExistence(timeout: 2) {
            candidate.tap()
            break
        }
    }

    /// iOS's "Save Password?" can come up seconds after the sign-in, over whatever the test does next: decline it.
    @MainActor private func clearSavePassword(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for candidate in [app.buttons["Not Now"], springboard.buttons["Not Now"]] where candidate.exists {
            candidate.tap()
            sleep(1)
        }
    }

    @MainActor private func type(_ app: XCUIApplication, _ text: String) {
        clearSavePassword(app)
        let field = app.textViews["composer.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(text)
    }

    @MainActor private func tapSend(_ app: XCUIApplication) {
        clearSavePassword(app)
        let send = app.buttons["composer.send"]
        XCTAssertTrue(waitUntil(timeout: 15) { send.exists && send.isEnabled }, "Send is enabled")
        send.tap()
        // Under a loaded Mac a tap during the keyboard's motion can be lost: the field still holding its text after
        // 5 s means the send never happened, so tap once more.
        let field = app.textViews["composer.text"]
        let typed = { ((field.value as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        if !typed().isEmpty, !waitUntil(timeout: 5, { typed().isEmpty || !send.exists }), send.exists, send.isEnabled {
            send.tap()
        }
    }

    @MainActor private func media(_ app: XCUIApplication) -> XCUIElementQuery {
        app.tables["chat.table"].descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'chat.media.'"))
    }

    @MainActor private func files(_ app: XCUIApplication) -> XCUIElementQuery {
        app.tables["chat.table"].descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'chat.file.'"))
    }

    @MainActor private func message(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.tables["chat.table"].descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// Saves a screenshot to the shots folder (`<name>-light.png` / `-dark.png`) and to the test report.
    @MainActor private func shot(_ app: XCUIApplication, _ name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let shots else { return }
        let mode = dark ? "dark" : "light"
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: shots.appending(path: "\(name)-\(mode).png"))
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }
}
