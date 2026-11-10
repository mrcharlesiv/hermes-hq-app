// [share] End-to-end tests for the Share extension (docs/spec/3x-share.md §7, §10.3) against this stream's stand-in
// gateway (scripts/fixtures/share-gateway.py). Run with scripts/e2e-share.sh: it starts the gateway on :9910 and a
// second one on :9914, builds the Hermes HQ identity (only that build embeds the extension), installs the app and the
// test-only host app HQShareProbe, and passes the credentials file (TEST_RUNNER_HQN_UI_CREDENTIALS), the second
// gateway's (TEST_RUNNER_HQN_SHARE_B), the invented media (TEST_RUNNER_HQN_SHARE_MEDIA), the simulator's App Group
// container (TEST_RUNNER_HQN_SHARE_GROUP) and the screenshot folder (TEST_RUNNER_HQN_UI_SHOTS). Without them every
// test skips.
//
// Every test starts from a clean phone (`-HQDebugResetAccounts YES`) and signs in through the form once. A share is
// made the way a person makes one: HQShareProbe presents the real system share sheet with the items the test names,
// "Hermes HQ" is tapped among its apps, and the extension's own sheet is driven by its accessibility identifiers.
// What reached the gateway is read back from the fixture's ledger; what the app and the sheet leave for each other is
// read from the App Group folder.
//
// Screenshots go to the shots folder as `<name>-light.png`; `HQN_SHARE_DARK=1 scripts/e2e-share.sh …` runs the same
// tests in dark appearance and writes `<name>-dark.png` (the appearance is set before anything is on screen: a share
// sheet that is already up does not follow a change). A file is named by what the screenshot measures, never by what
// the run asked for.

import ImageIO
import XCTest

final class ShareEndToEndTests: XCTestCase {
    private var account: FixtureAccount!
    private var media: URL!
    /// The App Group's share folder (roster.json, avatars/, choice.json, last-sent.json, debug.json).
    private var folder: URL!
    private var shots: URL?
    /// A test changed the simulator's type size (put back in tearDown).
    private var resized = false
    private var app: XCUIApplication!
    /// The app whose share sheet is up: HQShareProbe, or Safari / Photos in the opt-in tests.
    private var host: XCUIApplication!
    private var hostIsProbe = true

    private static let probeId = "com.charlesmcdowell.hqshareprobe"
    private static let ivyStored = "20260929_120000_aabbcc02", hermesStored = "20260929_120000_aabbcc01"
    private static let link = "https://example.com/articles/quiet-mornings?id=7"

    private enum Words {
        static let signedOut = "Open Hermes HQ and sign in to your gateway, then share again."
        static let needsApp = "Open Hermes HQ once to finish updating, then share again."
        static let noRoster = "Open Hermes HQ once so your bots appear here, then share again."
        static let sessionEnded = "Your gateway ended this iPhone’s session. Open Hermes HQ to sign in again."
        static let otherAccount = "Hermes HQ switched gateways. Open Hermes HQ so your bots appear here, then share again."
        static let locked = "Unlock your iPhone to share."
        static let keychain = "Hermes HQ couldn’t read your sign-in. Open Hermes HQ, then share again."
        static let tailscaleOff = "Turn on Tailscale to reach the computer running Hermes."
        static let busy = "Your gateway is busy. Try again in a minute."
        static let unconfirmed = "Hermes HQ couldn’t confirm the share arrived. Check the chat before sending again."
        static let privacy = "Sent without location or camera details"
        static let question = "What do you see in this image?"
        static let noChat = "Open this bot in Hermes HQ first"
        static let firstTenPhotos = "Only the first 10 photos are sent."
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        account = try FixtureAccount.load()
        let environment = ProcessInfo.processInfo.environment
        guard let mediaPath = environment["HQN_SHARE_MEDIA"], !mediaPath.isEmpty,
              let groupPath = environment["HQN_SHARE_GROUP"], !groupPath.isEmpty else {
            throw XCTSkip("Run through scripts/e2e-share.sh (TEST_RUNNER_HQN_SHARE_MEDIA, TEST_RUNNER_HQN_SHARE_GROUP).")
        }
        media = URL(fileURLWithPath: mediaPath)
        folder = URL(fileURLWithPath: groupPath).appendingPathComponent("Library/Application Support/Dispatch Share", isDirectory: true)
        shots = environment["HQN_UI_SHOTS"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        try account.control("/__fixture/share-reset", [:])
        // Every test starts at the usual type size in the run's appearance (light, or dark with HQN_SHARE_DARK=1),
        // whatever an earlier one left. The appearance is set before anything is on screen: a share sheet that is
        // already up does not follow a change (seen with both XCUIDevice and `simctl ui`).
        let appearance = Self.darkRun ? "dark" : "light"
        try? account.control("/__fixture/share-sim", ["appearance": appearance])
        MainActor.assumeIsolated { XCUIDevice.shared.appearance = Self.darkRun ? .dark : .light }
        remove("debug.json")
    }

    override func tearDownWithError() throws {
        remove("debug.json")
        if resized { try? account.control("/__fixture/share-sim", ["content_size": "large"]) }
        // Nothing the extension sent was ever refused as malformed (4000): its key sets are the gateway's.
        let refused = extensionLedger().filter { ($0["error"] as? Int) == 4000 }
        XCTAssertTrue(refused.isEmpty, "a strict-params refusal (4000) reached the gateway: \(refused.map(label))")
    }

    /// A failure carries the screen it happened on.
    override func record(_ issue: XCTIssue) {
        var issue = issue
        if issue.isFailure, Thread.isMainThread, let png = MainActor.assumeIsolated({ XCUIScreen.main.screenshot().pngRepresentation }) as Data? {
            issue.add(XCTAttachment(data: png, uniformTypeIdentifier: "public.png"))
            if let shots {
                let test = name.replacingOccurrences(of: "[^A-Za-z0-9_]+", with: "-", options: .regularExpression)
                try? png.write(to: shots.appendingPathComponent("zz-failed-\(test).png"))
            }
        }
        super.record(issue)
    }

    // MARK: §7.1 The target is offered for what it takes, and not for more

    @MainActor func testS01_TargetIsOffered() throws {
        signInFresh()
        app.terminate()

        openSheet([["text": "A sentence worth keeping."]])
        XCTAssertTrue(el("share.text").waitForExistence(timeout: 30), "shared text has its row")
        XCTAssertTrue(el("share.text").label.contains("A sentence worth keeping."))
        XCTAssertTrue(host.navigationBars["Hermes HQ"].exists || host.staticTexts["Hermes HQ"].exists, "the sheet is titled Hermes HQ")
        XCTAssertTrue(el("share.bot.ivy").exists && el("share.bot.default").exists, "both bots are offered")
        shot("share-01-text")
        cancelSheet()
        XCTAssertTrue(waitUntil(timeout: 10) { ["cancelled", "dismissed", "sharing"].contains(self.probeResult()) }, "Cancel sends nothing: \(probeResult())")

        openSheet([["url": Self.link]])
        XCTAssertTrue(el("share.link").waitForExistence(timeout: 30), "a link has its row")
        XCTAssertTrue(el("share.link").label.contains("example.com"), el("share.link").label)
        shot("share-01-link")
        cancelSheet()

        openSheet([file("p01.jpg")])
        XCTAssertTrue(waitUntil(timeout: 40) { self.count("share.photo") == 1 }, "one photo, one thumbnail")
        XCTAssertEqual(el("share.photo-privacy").label, Words.privacy)
        cancelSheet()

        openSheet((1...10).map { file(String(format: "p%02d.jpg", $0)) })
        XCTAssertTrue(waitUntil(timeout: 90) { self.count("share.photo") == 10 }, "ten photos, ten thumbnails (\(count("share.photo")))")
        shot("share-01-ten-photos")
        cancelSheet()

        openSheet([file("clip-plain.mov")])
        XCTAssertTrue(el("share.file").waitForExistence(timeout: 60), "a video has its row")
        XCTAssertTrue(el("share.file").label.contains("clip-plain"), el("share.file").label)
        cancelSheet()

        openSheet([file("report.pdf")])
        XCTAssertTrue(el("share.file").waitForExistence(timeout: 40), "a file has its row")
        XCTAssertTrue(el("share.file").label.contains("report.pdf"), el("share.file").label)
        shot("share-01-file")
        cancelSheet()

        // Ten photos handed over as pictures (the way an app shares photos it holds) are offered and all read…
        func pictures(_ count: Int) -> [[String: Any]] {
            (1...count).map { ["image": media.appendingPathComponent(String(format: "p%02d.jpg", $0)).path] }
        }
        openSheet(pictures(10))
        XCTAssertTrue(waitUntil(timeout: 90) { self.count("share.photo") == 10 }, "ten pictures, ten thumbnails (\(count("share.photo")))")
        cancelSheet()

        // A selection handed over as ONE item with many attachments (the way Photos does it): ten are offered and read…
        func selection(_ count: Int) -> [[String: Any]] {
            [["group": (1...count).map { file(String(format: "p%02d.jpg", $0)) }]]
        }
        present(selection(10))
        guard let choice = target(wait: 12) else { return XCTFail("a selection of ten photos is offered Hermes HQ") }
        choice.tap()
        XCTAssertTrue(el("share.cancel").waitForExistence(timeout: 40), "the Hermes HQ sheet opens")
        XCTAssertTrue(waitUntil(timeout: 90) { self.count("share.photo") == 10 }, "a selection of ten, ten thumbnails (\(count("share.photo")))")
        cancelSheet()

        // …and eleven are one too many. The activation rule says so (§7.1 check 4), and what the iOS 27 simulator does
        // with it changes from run to run of the same build: in some runs Hermes HQ is left out of the list (the
        // rule kept), in others it is offered all the same, for a selection, for separate photo files and for pictures
        // (build 240 carries the same rule). Either answer is safe, so either passes: left out is what the rule asks
        // for; and when the sheet does open, it reads ten, never the eleventh, and says so.
        present(selection(11))
        if let choice = target(wait: 12, beforeMore: { self.shot("share-01-eleven-photos-share-sheet") }) {
            note("iOS offers Hermes HQ for a selection of eleven photos")
            choice.tap()
            XCTAssertTrue(el("share.cancel").waitForExistence(timeout: 40), "the Hermes HQ sheet opens")
            XCTAssertTrue(waitUntil(timeout: 90) { self.count("share.photo") == 10 }, "ten thumbnails (\(count("share.photo")))")
            XCTAssertEqual(el("share.over-cap").label, Words.firstTenPhotos)
            shot("share-01-eleven-photos-selection-read-as-ten")
            cancelSheet()
        } else {
            note("iOS does not offer Hermes HQ for a selection of eleven photos")
            // No app is named here that the rule itself may filter out (Reminders is not offered for eleven photos
            // either): the system sheet is up and has filled in, so not finding Hermes HQ in it is a real answer.
            XCTAssertTrue(systemSheetFilledIn(), "the system share sheet had filled in\n" + String(host.debugDescription.prefix(4000)))
            shot("share-01-eleven-photos-not-offered")
        }
        XCTAssertTrue(extensionLedger().isEmpty, "nothing was sent by looking")
    }

    /// iOS sometimes lets eleven photo *documents* (file URLs, as Files hands them over) through the activation rule;
    /// then the sheet itself keeps to ten and the eleventh is never read (§7.6 caps). When iOS keeps to the rule and
    /// leaves Hermes HQ out, there is no sheet to look at: the test is skipped, not failed (the cap itself is covered
    /// without the system's help by ShareItemLoaderTests.theEleventhPhotoIsNeverRead).
    @MainActor func testS01b_ElevenPhotoFilesAreReadAsTen() throws {
        signInFresh()
        app.terminate()
        present((1...11).map { file(String(format: "p%02d.jpg", $0)) })
        guard let choice = target(wait: 12) else {
            note("iOS does not offer Hermes HQ for eleven photo files")
            XCTAssertTrue(systemSheetFilledIn(), "the system share sheet had filled in\n" + String(host.debugDescription.prefix(4000)))
            XCTAssertTrue(extensionLedger().isEmpty, "nothing was sent by looking")
            throw XCTSkip("iOS kept to the activation rule (ten photos) and did not offer Hermes HQ for eleven; the read-as-ten cap is covered by ShareItemLoaderTests.theEleventhPhotoIsNeverRead")
        }
        note("iOS offers Hermes HQ for eleven photo files")
        choice.tap()
        XCTAssertTrue(el("share.cancel").waitForExistence(timeout: 40), "the Hermes HQ sheet opens")
        XCTAssertTrue(waitUntil(timeout: 90) { self.count("share.photo") == 10 }, "ten thumbnails (\(count("share.photo")))")
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        XCTAssertEqual(count("share.photo"), 10, "the eleventh photo is not read")
        XCTAssertFalse(el("share.unreadable").exists, "and it is not called unreadable either")
        XCTAssertEqual(el("share.over-cap").label, Words.firstTenPhotos, "the sheet says which were kept")
        shot("share-01-eleven-photo-files-read-as-ten")
        cancelSheet()
        XCTAssertTrue(extensionLedger().isEmpty, "nothing was sent by looking")
    }

    // MARK: §7.2 A link with a message goes to the chosen bot

    @MainActor func testS02_LinkAndMessageToSam() throws {
        signInFresh()
        app.terminate()
        openSheet([["url": Self.link]])
        XCTAssertTrue(el("share.link").waitForExistence(timeout: 30))
        // A link alone is something to send: Send is on before a word is typed.
        XCTAssertTrue(waitUntil(timeout: 10) { self.el("share.send").isEnabled }, "Send is on with a link and a bot")
        choose("ivy")
        type("Read this for me")
        shot("share-02-ready")
        // Hold the gateway's answer so the progress card can be looked at.
        try account.control("/__fixture/share-hold", ["target": "prompt.submit", "seconds": 4])
        tapSend()
        if waitUntil(timeout: 6, { self.el("share.progress").exists }) { shot("share-02-progress") }
        let sawCard = expectSent(to: "Ivy", shotName: "share-02-sent")
        if !sawCard { note("the Sent card was gone before a poll saw it") }

        let sent = prompts()
        XCTAssertEqual(sent.count, 1, "exactly one prompt")
        XCTAssertEqual(sent.first?["profile"] as? String, "ivy")
        XCTAssertEqual(sent.first?["text"] as? String, "Read this for me\n\n" + Self.link)
        XCTAssertEqual(sent.first?["queued"] as? Bool, true, "it waits its turn if the bot is busy")
        XCTAssertTrue(uploads().isEmpty)
        // What the sheet leaves behind: the bot to offer next time, and the chat for the app to open.
        let key = account.url + "\n" + account.username
        XCTAssertEqual((json("choice.json") as? [String: String])?[key], botKey("ivy"))
        let note = json("last-sent.json")
        XCTAssertEqual(note?["session"] as? String, Self.ivyStored)
        XCTAssertEqual(note?["profile"] as? String, "ivy")
        XCTAssertEqual(note?["account"] as? String, key)
    }

    // MARK: §7.6 A photo goes as a JPEG without its location or camera

    @MainActor func testS03_PhotoLosesItsLocation() throws {
        signInFresh()
        app.terminate()
        openSheet([file("photo-gps.heic")])
        XCTAssertTrue(waitUntil(timeout: 40) { self.count("share.photo") == 1 })
        XCTAssertEqual(el("share.photo-privacy").label, Words.privacy)
        choose("default")
        shot("share-03-photo")
        tapSend()
        expectSent(to: "Hermes")
        var sent = uploads()
        XCTAssertEqual(sent.count, 1, "one upload")
        XCTAssertEqual(sent.first?["jpeg"] as? Bool, true, "it goes as a JPEG")
        XCTAssertEqual(sent.first?["gps"] as? Bool, false, "without where it was taken")
        XCTAssertEqual(sent.first?["camera"] as? Bool, false, "and without the camera's details")
        XCTAssertLessThanOrEqual((sent.first?["pixels"] as? [Int])?.max() ?? .max, 3072, "no larger than 3072 px")
        XCTAssertEqual(prompts().first?["text"] as? String, Words.question, "a photo alone asks the question")
        XCTAssertEqual((prompts().first?["images"] as? [Any])?.count, 1)

        // A 48-megapixel photo, in the extension's own process.
        openSheet([file("huge.jpg")])
        XCTAssertTrue(waitUntil(timeout: 90) { self.count("share.photo") == 1 }, "the large photo is read")
        choose("default")
        type("And this one")
        tapSend()
        expectSent(to: "Hermes", timeout: 180)
        sent = uploads()
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent.last?["jpeg"] as? Bool, true)
        XCTAssertEqual(sent.last?["gps"] as? Bool, false)
        XCTAssertEqual(sent.last?["camera"] as? Bool, false)
        XCTAssertEqual((sent.last?["pixels"] as? [Int])?.max(), 3072, "8064 px wide becomes 3072: \(String(describing: sent.last?["pixels"]))")
        XCTAssertEqual(prompts().last?["text"] as? String, "And this one")

        // A picture an app hands over as itself (no file behind it: a screenshot, a drawing) goes the same way.
        openSheet([["image": media.appendingPathComponent("photo-gps.jpg").path]])      // 4032 x 3024
        XCTAssertTrue(waitUntil(timeout: 120) { self.count("share.photo") == 1 }, "a picture without a file is read")
        XCTAssertFalse(el("share.unreadable").exists, "and is not called unreadable")
        choose("default")
        tapSend()
        expectSent(to: "Hermes", timeout: 180)
        sent = uploads()
        XCTAssertEqual(sent.count, 3)
        XCTAssertEqual(sent.last?["jpeg"] as? Bool, true)
        XCTAssertEqual(sent.last?["gps"] as? Bool, false)
        XCTAssertEqual(sent.last?["camera"] as? Bool, false)
        XCTAssertEqual((sent.last?["pixels"] as? [Int])?.max(), 3072, "\(String(describing: sent.last?["pixels"]))")
        XCTAssertEqual(prompts().last?["text"] as? String, Words.question)
    }

    // MARK: §7.6 A video loses its location; one that cannot be read is named and the rest still goes

    @MainActor func testS04_VideoAndBrokenVideo() throws {
        signInFresh()
        app.terminate()
        openSheet([file("clip-gps.mov"), file("broken.mov")])
        XCTAssertTrue(waitUntil(timeout: 90) { self.el("share.file").exists && self.el("share.unreadable").exists }, "one row each")
        XCTAssertTrue(el("share.file").label.contains("clip-gps"), el("share.file").label)
        XCTAssertEqual(el("share.unreadable").label, "Hermes HQ couldn’t read “broken.mov”.")
        choose("ivy")
        type("A clip for you")
        shot("share-04-video-and-unreadable")
        tapSend()
        expectSent(to: "Ivy", timeout: 150)
        let sent = uploads()
        XCTAssertEqual(sent.count, 1, "only the readable one is uploaded")
        XCTAssertEqual(sent.first?["movie"] as? Bool, true)
        XCTAssertEqual(sent.first?["location"] as? Bool, false, "the video no longer says where it was filmed")
        let text = prompts().first?["text"] as? String ?? ""
        XCTAssertTrue(text.hasPrefix("@file:") && text.hasSuffix("\n\nA clip for you"), text)

        // Nothing readable: Send waits for a message, and comes on with its first character.
        openSheet([file("broken.mov")])
        XCTAssertTrue(el("share.unreadable").waitForExistence(timeout: 60))
        XCTAssertFalse(el("share.file").exists)
        choose("ivy")
        XCTAssertFalse(el("share.send").isEnabled, "nothing to send yet")
        shot("share-04-unreadable-only")
        let field = el("share.message")
        field.tap()
        field.typeText("J")
        XCTAssertTrue(waitUntil(timeout: 10) { self.el("share.send").isEnabled }, "Send comes on with the first character")
        field.typeText("ust a note")
        tapSend()
        expectSent(to: "Ivy")
        XCTAssertEqual(prompts().last?["text"] as? String, "Just a note")
        XCTAssertEqual(uploads().count, 1, "nothing more was uploaded")
    }

    // MARK: §7.6 A file over the limit is named and never sent; the limit itself goes

    @MainActor func testS05_FileOverTheLimit() throws {
        signInFresh()
        app.terminate()
        openSheet([file("big.bin")])
        let line = el("share.oversized")
        XCTAssertTrue(line.waitForExistence(timeout: 90), "the file over the limit is named")
        XCTAssertTrue(line.label.contains("“big.bin” is larger than") && line.label.contains("100") && line.label.contains("your attachment limit"), line.label)
        choose("ivy")
        type("Too big")
        XCTAssertFalse(el("share.send").isEnabled, "Send stays off while a file is over the limit")
        shot("share-05-oversized")
        cancelSheet()
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        XCTAssertTrue(extensionLedger().isEmpty, "not one request went out: \(extensionLedger().map(label))")

        openSheet([file("exact.bin")])
        XCTAssertTrue(el("share.file").waitForExistence(timeout: 90))
        XCTAssertFalse(el("share.oversized").exists, "exactly 100 MiB is within the limit")
        choose("ivy")
        tapSend()
        expectSent(to: "Ivy", timeout: 240)
        XCTAssertEqual(uploads().first?["bytes"] as? Int, 104_857_600, "the whole file arrived")
        XCTAssertEqual(prompts().count, 1)
    }

    // MARK: §7.2 The most recently active bot first, the remembered one chosen, one without a chat not choosable

    @MainActor func testS06_BotOrderChoiceAndNoChat() throws {
        try account.control("/__fixture/share-roster", ["noChat": ["ivy"], "extra": 3, "lastActive": ["default": 1_790_000_000]])
        signInFresh(bots: 5)
        app.terminate()
        let key = account.url + "\n" + account.username

        openSheet([["text": "Who gets this?"]])
        XCTAssertTrue(el("share.bot.ivy").waitForExistence(timeout: 30))
        let rows = host.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'share.bot.'"))
        XCTAssertEqual(rows.allElementsBoundByIndex.map(\.identifier),
                       ["share.bot.load-001", "share.bot.load-002", "share.bot.load-003", "share.bot.default", "share.bot.ivy"],
                       "most recently active first, the one without a chat last")
        XCTAssertTrue(el("share.bot.load-001").isSelected, "the first that can receive is chosen")
        let ivy = el("share.bot.ivy")
        XCTAssertFalse(ivy.isEnabled, "a bot without a Bot Chat cannot be chosen")
        XCTAssertEqual(ivy.label, "Ivy, " + Words.noChat)
        XCTAssertTrue(el("share.bot.default").label.hasPrefix("Hermes, Active "), el("share.bot.default").label)
        shot("share-06-bots")
        // A bot's row is its 36 pt face and two lines with 13 pt above and below: about 64 pt, never the 94 pt it was
        // when the list's own insets were added on top. Measured as the distance from one row to the next (what the
        // eye sees between separators) and as the height of the row's own element.
        let first = el("share.bot.load-001"), second = el("share.bot.load-002"), third = el("share.bot.load-003")
        let pitch = second.frame.minY - first.frame.minY
        XCTAssertTrue((56...70).contains(pitch), "one bot row to the next is \(pitch) pt")
        XCTAssertEqual(third.frame.minY - second.frame.minY, pitch, accuracy: 1, "every row the same")
        XCTAssertLessThanOrEqual(el("share.bot.default").frame.height, 70)
        XCTAssertGreaterThanOrEqual(first.frame.height, pitch - 1.5, "the whole row, padding included, is the bot's element (\(first.frame.height) of \(pitch) pt)")
        // The whole row chooses the bot: a tap just inside its top edge, then one just inside the bottom edge of another.
        second.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: second.frame.width / 2, dy: 6)).tap()
        XCTAssertTrue(waitUntil(timeout: 5) { second.isSelected && !first.isSelected }, "a tap 6 pt inside a row's top edge chooses that bot")
        third.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: third.frame.width / 2, dy: third.frame.height - 6)).tap()
        XCTAssertTrue(waitUntil(timeout: 5) { third.isSelected && !second.isSelected }, "a tap 6 pt inside a row's bottom edge chooses that bot")
        // The message field's row follows the same rule (12 pt around one line: about 46 pt, not 60).
        let row = host.cells.containing(.any, identifier: "share.message").firstMatch
        if row.exists { XCTAssertLessThanOrEqual(row.frame.height, 52, "the message row is \(row.frame.height) pt") }
        else { note("the message field's row is not a cell in this tree: its height was looked at in the screenshot") }
        shot("share-06-bots-tapped-at-the-edge")
        cancelSheet()

        // What build 240 remembered ("legacy::default") still chooses that bot.
        try write(["\(key)": "legacy::default"], to: "choice.json")
        openSheet([["text": "Who gets this?"]])
        XCTAssertTrue(waitUntil(timeout: 30) { self.el("share.bot.default").exists && self.el("share.bot.default").isSelected }, "the remembered bot is chosen")
        tapSend()
        expectSent(to: "Hermes")
        XCTAssertEqual((json("choice.json") as? [String: String])?[key], botKey("default"), "the choice is remembered under the bot's own key")
        XCTAssertEqual(prompts().first?["profile"] as? String, "default")

        // A remembered bot that can no longer receive falls back to the first that can.
        try write(["\(key)": "legacy::ivy"], to: "choice.json")
        openSheet([["text": "Who gets this?"]])
        XCTAssertTrue(waitUntil(timeout: 30) { self.el("share.bot.load-001").exists && self.el("share.bot.load-001").isSelected })
        XCTAssertFalse(el("share.bot.ivy").isSelected)
        cancelSheet()
    }

    // MARK: §7.3, §7.11 The extension sends by itself; the app then opens that chat, once

    @MainActor func testS07_SendsWithoutTheAppThenAppOpensTheChat() throws {
        signInFresh()
        app.terminate()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let mark = ledger().compactMap { $0["n"] as? Int }.max() ?? 0
        let words = "Shared while the app was closed"
        openSheet([["text": words]])
        XCTAssertTrue(el("share.text").waitForExistence(timeout: 30))
        choose("ivy")
        tapSend()
        expectSent(to: "Ivy")

        // Hermes HQ is not running: every request since is the extension's own.
        XCTAssertEqual(app.state, .notRunning)
        let since = ledger().filter { ($0["n"] as? Int ?? 0) > mark }
        XCTAssertEqual(since.map(label), ["GET /api/auth/me", "POST /api/auth/ws-ticket", "UPGRADE /api/ws", "client.capabilities",
                                         "session.resume", "prompt.submit"])
        let agents = Set(since.compactMap { $0["ua"] as? String })
        XCTAssertTrue(!agents.isEmpty && agents.allSatisfy { $0.hasPrefix("HermesHQShare/") }, "the extension's own user agent: \(agents)")
        XCTAssertTrue(since.allSatisfy { $0["error"] == nil || $0["error"] is NSNull }, "no call was refused")
        let key = account.url + "\n" + account.username
        let note = json("last-sent.json")
        XCTAssertEqual(note?["session"] as? String, Self.ivyStored)
        XCTAssertEqual(note?["account"] as? String, key)
        XCTAssertEqual(note?["botName"] as? String, "Ivy")

        // Hermes HQ opens on the chat the share went to, with the share in it.
        relaunch()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 40), "the app opens the chat the share went to")
        XCTAssertTrue(waitUntil(timeout: 15) { self.chatTitle().contains("Ivy") }, "it is Ivy's chat: \(chatTitle())")
        XCTAssertTrue(message(words).waitForExistence(timeout: 20), "the shared text is in the chat")
        XCTAssertNil(json("last-sent.json"), "the note is taken once")
        declineSavePassword()
        shot("share-07-app-opened-the-chat")

        // The next launch opens nothing by itself.
        app.terminate()
        relaunch()
        XCTAssertTrue(app.collectionViews["bots.list"].waitForExistence(timeout: 30))
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        XCTAssertFalse(app.tables["chat.table"].exists, "no chat opens the second time")
        XCTAssertEqual(prompts().count, 1, "and nothing was sent again")
    }

    // MARK: §7.5 The roster follows the app: signed in, a hidden bot, Sign Out, another gateway

    @MainActor func testS08_RosterFollowsTheApp() throws {
        launch(reset: true)
        XCTAssertTrue(app.textFields["sign-in-address"].waitForExistence(timeout: 30))
        XCTAssertTrue(waitUntil(timeout: 10) { self.json("roster.json") == nil }, "nobody signed in: no roster")
        signIn(account)
        XCTAssertTrue(app.collectionViews["bots.list"].waitForExistence(timeout: 60), "signed in")
        let listed = Date()
        let roster = try XCTUnwrap(waitRoster(for: account), "the roster is written once the bots are known")
        note("roster on disk \(String(format: "%.1f", Date().timeIntervalSince(listed))) s after the Bots list showed")
        XCTAssertEqual(roster["url"] as? String, account.url)
        XCTAssertEqual(roster["username"] as? String, account.username)
        XCTAssertEqual(roster["limitBytes"] as? Int, 104_857_600)
        XCTAssertEqual(roster["version"] as? Int, 1)
        let bots = roster["bots"] as? [[String: Any]] ?? []
        XCTAssertEqual(Set(bots.compactMap { $0["profile"] as? String }), ["default", "ivy"])
        XCTAssertEqual(bots.first { $0["profile"] as? String == "ivy" }?["session"] as? String, Self.ivyStored)
        XCTAssertEqual(bots.first { $0["profile"] as? String == "default" }?["session"] as? String, Self.hermesStored)
        // Names and routing ids only: nothing in the folder is a message, a cookie or a token.
        let allowed: Set<String> = ["key", "name", "profile", "session", "color", "avatar", "lastActive"]
        XCTAssertTrue(bots.allSatisfy { Set($0.keys).isSubset(of: allowed) }, "a bot row holds only \(allowed.sorted())")
        let raw = (try? String(contentsOf: folder.appendingPathComponent("roster.json"), encoding: .utf8)) ?? ""
        XCTAssertFalse(raw.contains(account.password) || raw.lowercased().contains("cookie") || raw.lowercased().contains("token"))
        for bot in bots {
            let name = try XCTUnwrap(bot["avatar"] as? String, "every bot has a face: \(bot["profile"] ?? "")")
            let face = folder.appendingPathComponent("avatars").appendingPathComponent(name)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(face as CFURL, nil), "the face \(name) is on disk")
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
            XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.png")
            XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 120)
            XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 120)
        }
        declineSavePassword()

        // A bot hidden on the gateway leaves the sheet.
        try account.control("/__fixture/share-roster", ["hidden": ["ivy"]])
        refreshBots()
        let without: ([[String: Any]]) -> Bool = { rows in !rows.isEmpty && !rows.contains { $0["profile"] as? String == "ivy" } }
        if waitRoster(for: account, timeout: 20, without) == nil {
            app.collectionViews["bots.list"].swipeDown()
        }
        XCTAssertNotNil(waitRoster(for: account, timeout: 30, without), "the hidden bot leaves the roster")
        openSheet([["text": "Still here?"]])
        XCTAssertTrue(el("share.bot.default").waitForExistence(timeout: 30))
        XCTAssertFalse(el("share.bot.ivy").exists, "the hidden bot is not offered")
        cancelSheet()

        // Sign Out empties the shared folder, and the sheet says to sign in.
        try write(["\(account.url)\n\(account.username)": botKey("default")], to: "choice.json")
        app.activate()
        signOut()
        XCTAssertTrue(waitUntil(timeout: 15) { self.json("roster.json") == nil }, "the roster goes with the session")
        XCTAssertTrue(faces().isEmpty, "and the faces: \(faces())")
        XCTAssertNil(json("choice.json"), "and the remembered bot")
        openSheet([["text": "Anyone?"]])
        XCTAssertTrue(el("share.blocked").waitForExistence(timeout: 30))
        XCTAssertEqual(el("share.blocked").label, Words.signedOut)
        cancelSheet()

        // Another gateway: the roster is that gateway's, never a mix.
        let other = try second()
        app.activate()
        signIn(other)
        XCTAssertTrue(app.collectionViews["bots.list"].waitForExistence(timeout: 60), "signed in to the second gateway")
        let theirs = try XCTUnwrap(waitRoster(for: other), "the second gateway's roster")
        XCTAssertEqual(theirs["url"] as? String, other.url)
        declineSavePassword()

        // Adding the first gateway again switches to it: the roster is replaced, whole.
        openSettings()
        app.buttons["settings.gateway-card"].tap()
        XCTAssertTrue(app.buttons["gateway.add"].waitForExistence(timeout: 10))
        app.buttons["gateway.add"].tap()
        signIn(account)
        let back = try XCTUnwrap(waitRoster(for: account, timeout: 40, without), "the first gateway's roster again")
        XCTAssertEqual(back["url"] as? String, account.url)
    }

    // MARK: §7.8 Why the sheet cannot share yet

    @MainActor func testS09_BlockedScreens() throws {
        // Nobody is signed in.
        launch(reset: true)
        XCTAssertTrue(app.textFields["sign-in-address"].waitForExistence(timeout: 30))
        openSheet([["text": "Blocked?"]])
        XCTAssertTrue(el("share.blocked").waitForExistence(timeout: 30))
        XCTAssertEqual(el("share.blocked").label, Words.signedOut)
        XCTAssertTrue(host.staticTexts["Can’t Share Yet"].exists, "the blocked screen's title")
        XCTAssertFalse(el("share.send").exists, "no Send on a blocked sheet")
        XCTAssertFalse(el("share.message").exists)
        shot("share-09-blocked-signed-out")
        cancelSheet()

        // Signed in, but the app has not written the roster.
        app.activate()
        signIn(account)
        XCTAssertTrue(app.collectionViews["bots.list"].waitForExistence(timeout: 60))
        XCTAssertNotNil(waitRoster(for: account))
        declineSavePassword()
        app.terminate()
        let saved = try Data(contentsOf: folder.appendingPathComponent("roster.json"))
        remove("roster.json")
        blocked(says: Words.noRoster, shot: "share-09-blocked-no-roster")

        // The roster is another account's.
        var foreign = try XCTUnwrap(try JSONSerialization.jsonObject(with: saved) as? [String: Any])
        foreign["account"] = "http://127.0.0.1:9914\nsomeone-else"
        try write(foreign, to: "roster.json")
        blocked(says: Words.otherAccount, shot: "share-09-blocked-other-account")
        try saved.write(to: folder.appendingPathComponent("roster.json"))

        // States the simulator cannot reach, forced in DEBUG builds only (debug.json).
        try write(["blocked": "needsApp"], to: "debug.json")
        blocked(says: Words.needsApp, shot: "share-09-blocked-needs-update")
        try write(["blocked": "locked"], to: "debug.json")
        blocked(says: Words.locked, shot: "share-09-blocked-locked")
        try write(["blocked": "keychain"], to: "debug.json")
        blocked(says: Words.keychain, shot: "share-09-blocked-keychain")
        try write(["failure": "tailscaleOff"], to: "debug.json")
        openSheet([["text": "Blocked?"]])
        XCTAssertTrue(el("share.failure").waitForExistence(timeout: 30))
        XCTAssertEqual(el("share.failure").label, Words.tailscaleOff)
        XCTAssertTrue(el("share.try-again").exists, "Tailscale off can be tried again")
        shot("share-09-failure-tailscale-off")
        cancelSheet()
        remove("debug.json")

        // The gateway ended the session: found out on Send, and nothing is sent.
        try account.control("/__fixture/revoke", [:])
        openSheet([["text": "Blocked?"]])
        choose("ivy")
        tapSend()
        XCTAssertTrue(el("share.blocked").waitForExistence(timeout: 60), "the sheet turns into the blocked screen")
        XCTAssertEqual(el("share.blocked").label, Words.sessionEnded)
        shot("share-09-blocked-session-ended")
        cancelSheet()
        XCTAssertTrue(prompts().isEmpty, "nothing was sent")
    }

    // MARK: §7.8, §7.9 A failure keeps the share; Try Again sends once; an unconfirmed share is never sent twice

    @MainActor func testS10_FailuresAndTryAgain() throws {
        signInFresh()
        app.terminate()

        try account.control("/__fixture/share-fail", ["target": "me", "status": 429, "times": 1])
        openSheet([["text": "Second time lucky"]])
        choose("ivy")
        tapSend()
        XCTAssertTrue(el("share.failure").waitForExistence(timeout: 60))
        XCTAssertEqual(el("share.failure").label, Words.busy)
        XCTAssertTrue(el("share.try-again").exists)
        XCTAssertTrue(el("share.text").exists, "the share is still there")
        XCTAssertTrue(prompts().isEmpty)
        shot("share-10-failure-try-again")
        el("share.try-again").tap()
        expectSent(to: "Ivy")
        XCTAssertEqual(prompts().map { $0["text"] as? String }, ["Second time lucky"], "sent exactly once")

        // A failure, then Cancel: nothing goes later.
        try account.control("/__fixture/share-fail", ["target": "ticket", "status": 500, "times": 1])
        openSheet([["text": "Never sent"]])
        choose("ivy")
        tapSend()
        XCTAssertTrue(el("share.failure").waitForExistence(timeout: 60))
        XCTAssertEqual(el("share.failure").label, "Your gateway had a problem with this share. Try again in a minute.")
        cancelSheet()
        RunLoop.current.run(until: Date().addingTimeInterval(6))
        XCTAssertEqual(prompts().count, 1, "a cancelled share never goes")

        // The gateway took the prompt and its answer went missing.
        try account.control("/__fixture/share-hold", ["target": "prompt.submit", "drop": true])
        openSheet([["text": "Maybe sent"]])
        choose("ivy")
        tapSend()
        XCTAssertTrue(el("share.failure").waitForExistence(timeout: 90))
        XCTAssertEqual(el("share.failure").label, Words.unconfirmed)
        XCTAssertFalse(el("share.try-again").exists, "no Try Again: the bot may already have it")
        shot("share-10-unconfirmed")
        XCTAssertEqual(json("last-sent.json")?["session"] as? String, Self.ivyStored, "the app is told which chat to look at")
        cancelSheet()
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        XCTAssertEqual(prompts().compactMap { $0["text"] as? String }, ["Second time lucky", "Maybe sent"], "never sent a second time")
        relaunch()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 40), "the app opens the chat to look")
        XCTAssertTrue(message("Maybe sent").waitForExistence(timeout: 20))
        XCTAssertEqual(prompts().count, 2, "the gateway has it exactly once")
    }

    // MARK: §6.4 A lapsed session is renewed by the share and the app keeps it

    @MainActor func testS11_SessionRenewedByTheShare() throws {
        signInFresh()
        declineSavePassword()
        app.terminate()
        let before = try account.control("/__fixture/auth")
        try account.control("/__fixture/expire-access", [:])
        openSheet([["text": "After the session lapsed"]])
        choose("ivy")
        tapSend()
        expectSent(to: "Ivy")
        let shared = try account.control("/__fixture/auth")
        XCTAssertEqual(shared["refreshes"] as? Int, (before["refreshes"] as? Int ?? -9) + 1, "the share renewed the session once")
        XCTAssertEqual(shared["passwordPosts"] as? Int, before["passwordPosts"] as? Int)

        // The app starts with the cookies the share saved: still signed in, no renewal of its own, no password asked.
        relaunch()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 40), "signed in, and on the shared chat")
        XCTAssertFalse(app.textFields["sign-in-address"].exists, "not asked to sign in again")
        XCTAssertTrue(message("After the session lapsed").waitForExistence(timeout: 20))
        let after = try account.control("/__fixture/auth")
        XCTAssertEqual(after["passwordPosts"] as? Int, before["passwordPosts"] as? Int, "no password sign-in happened")
        XCTAssertEqual(after["logins"] as? Int, before["logins"] as? Int)
        XCTAssertEqual(after["refreshes"] as? Int, shared["refreshes"] as? Int, "the app used the renewed cookies as they were")
    }

    // MARK: §7.11 A note that is old, another account's or unreadable opens nothing and is removed

    @MainActor func testS12_OldAndForeignNotes() throws {
        signInFresh()
        declineSavePassword()
        app.terminate()
        let key = account.url + "\n" + account.username
        func note(account: String, age: TimeInterval) -> [String: Any] {
            ["id": UUID().uuidString, "account": account, "session": Self.ivyStored, "profile": "ivy", "botName": "Ivy",
             "at": Date().timeIntervalSince1970 - age]
        }
        // 301 seconds old.
        try write(note(account: key, age: 301), to: "last-sent.json")
        opensNothing("a note older than five minutes")
        // Another account's.
        try write(note(account: "http://127.0.0.1:9914\nsomeone-else", age: 1), to: "last-sent.json")
        opensNothing("another account's note")
        // Not a note at all.
        try Data("{\"id\": 7, \"at\": \"soon\"".utf8).write(to: folder.appendingPathComponent("last-sent.json"))
        opensNothing("an unreadable note")
        // A fresh one for this account opens its chat.
        try write(note(account: key, age: 2), to: "last-sent.json")
        relaunch()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 40), "a fresh note opens the chat")
        XCTAssertTrue(waitUntil(timeout: 15) { self.chatTitle().contains("Ivy") }, chatTitle())
        XCTAssertNil(json("last-sent.json"))
    }

    // MARK: §7.11 A sheet that is up is never thrown away for a share's chat; with nothing up, the chat opens

    @MainActor func testS15_AnOpenFormIsKeptWhenAShareWasMade() throws {
        signInFresh()
        declineSavePassword()
        // The person starts a New Bot form and types a name…
        let compose = app.buttons["bots.compose"]
        XCTAssertTrue(compose.waitForExistence(timeout: 20), "the Bots bar's +")
        let newBot = app.buttons["New Bot"].firstMatch
        for _ in 0..<3 where !newBot.exists {
            declineSavePassword()
            compose.tap()
            _ = newBot.waitForExistence(timeout: 6)
        }
        XCTAssertTrue(newBot.exists, "the + menu offers New Bot")
        newBot.tap()
        let name = app.textFields["new-bot.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 15), "the New Bot form is up")
        func focused() -> Bool { (name.value(forKey: "hasKeyboardFocus") as? Bool) ?? false }
        if !waitUntil(timeout: 5, focused) { name.tap() }
        name.typeText("Notes 7")
        XCTAssertEqual(name.value as? String, "Notes 7")

        // …leaves Hermes HQ as it is, shares to Ivy from another app, and comes back.
        openSheet([["text": "Shared with a form open"]])
        choose("ivy")
        tapSend()
        expectSent(to: "Ivy")
        XCTAssertEqual(json("last-sent.json")?["session"] as? String, Self.ivyStored, "the share left its note")
        app.activate()
        XCTAssertTrue(waitUntil(timeout: 20) { self.json("last-sent.json") == nil }, "the note is taken when Hermes HQ comes forward")
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        XCTAssertTrue(name.exists, "the form is still up")
        XCTAssertEqual(name.value as? String, "Notes 7", "with what was typed in it")
        XCTAssertFalse(app.tables["chat.table"].exists, "no chat was opened over it")
        shot("share-15-form-kept")

        // The form is closed: nothing opens later either (the note was taken once).
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !name.exists }, "the form closes")
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        XCTAssertFalse(app.tables["chat.table"].exists, "no chat opens after the form is closed")

        // With nothing up, the next share opens its chat when Hermes HQ comes forward (the app was never closed).
        openSheet([["text": "Shared with nothing in the way"]])
        choose("ivy")
        tapSend()
        expectSent(to: "Ivy")
        app.activate()
        XCTAssertTrue(app.tables["chat.table"].waitForExistence(timeout: 40), "the app opens the chat the share went to")
        XCTAssertTrue(waitUntil(timeout: 15) { self.chatTitle().contains("Ivy") }, "it is Ivy's chat: \(chatTitle())")
        XCTAssertTrue(message("Shared with nothing in the way").waitForExistence(timeout: 20), "the shared text is in the chat")
        XCTAssertNil(json("last-sent.json"), "the note is taken once")
        XCTAssertEqual(prompts().compactMap { $0["text"] as? String }, ["Shared with a form open", "Shared with nothing in the way"])
    }

    // MARK: §8 Largest type size

    @MainActor func testS13_LargestType() throws {
        signInFresh()
        declineSavePassword()
        app.terminate()
        resized = true
        try account.control("/__fixture/share-sim", ["content_size": "accessibility-extra-extra-extra-large"])
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        openSheet([file("photo-gps.jpg"), ["url": Self.link]])
        XCTAssertTrue(waitUntil(timeout: 60) { self.count("share.photo") == 1 && self.el("share.link").exists }, "a photo and a link in one share")
        XCTAssertTrue(el("share.send").isHittable && el("share.cancel").isHittable, "Cancel and Send stay on the bar")
        shot("share-13-large-type-top")
        let ivy = el("share.bot.ivy")
        // Scrolled until the row is really on the screen (a row below the fold can still answer "hittable").
        let height = host.frame.height
        for _ in 0..<8 where !(ivy.exists && ivy.frame.minY > 0 && ivy.frame.maxY < height - 20) { host.swipeUp() }
        XCTAssertTrue(ivy.exists && ivy.isHittable && ivy.frame.maxY < height, "the bots are reachable by scrolling")
        shot("share-13-large-type-bots")
        ivy.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { ivy.isSelected })
        try account.control("/__fixture/share-hold", ["target": "prompt.submit", "seconds": 9])
        tapSend()
        if waitUntil(timeout: 20, { self.el("share.progress").exists }) { shot("share-13-large-type-progress") }
        expectSent(to: "Ivy", timeout: 150, shotName: "share-13-large-type-sent")
        XCTAssertEqual(prompts().first?["text"] as? String, Self.link)
        XCTAssertEqual(uploads().count, 1)
        try account.control("/__fixture/share-sim", ["content_size": "large"])
        resized = false
    }

    // MARK: §6.5 A Sign in with Nous account shares after its bearer lapsed

    @MainActor func testS14_NousAccountShares() throws {
        guard let path = ProcessInfo.processInfo.environment["HQN_SHARE_NOUS"], !path.isEmpty,
              let object = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))) as? [String: Any],
              let address = object["url"] as? String else {
            throw XCTSkip("Run with HQN_SHARE_NOUS=1 scripts/e2e-share.sh (starts the reference Nous fixture).")
        }
        let nous = FixtureAccount(url: address, username: "", password: "")
        launch(reset: true)
        let field = app.textFields["sign-in-address"]
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        field.tap()
        field.typeText(address)
        let button = app.buttons["sign-in-nous"]
        XCTAssertTrue(button.waitForExistence(timeout: 15), "the gateway offers Sign in with Nous")
        button.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let consent = springboard.buttons["Continue"]
        if consent.waitForExistence(timeout: 10) { consent.tap() }
        var owner: XCUIElement?
        for root in [app!, XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")] {
            let link = root.links["Continue as owner"].firstMatch
            if link.waitForExistence(timeout: 10) { owner = link; break }
        }
        try XCTUnwrap(owner, "the stand-in Portal's page").tap()
        XCTAssertTrue(app.collectionViews["bots.list"].waitForExistence(timeout: 60), "signed in with Nous")
        var roster: [String: Any]?
        XCTAssertTrue(waitUntil(timeout: 30) {
            roster = self.json("roster.json")
            return roster?["url"] as? String == address && !((roster?["bots"] as? [[String: Any]]) ?? []).isEmpty
        }, "the Nous account's roster")
        let able = (roster?["bots"] as? [[String: Any]] ?? []).filter { !(($0["session"] as? String) ?? "").isEmpty }
        let bot = try XCTUnwrap(able.first, "a bot with a Bot Chat")
        app.terminate()
        // The 30-second bearer lapses while the app is closed.
        RunLoop.current.run(until: Date().addingTimeInterval(33))
        let before = (try nous.control("/__fixture/nous")["counts"] as? [String: Any]) ?? [:]
        openSheet([["text": "From a Nous account"]])
        XCTAssertFalse(el("share.blocked").exists, "a Nous account is not blocked")
        choose(bot["profile"] as? String ?? "default")
        tapSend()
        expectSent(to: bot["name"] as? String ?? "", timeout: 150, shotName: "share-14-nous-sent")
        let after = (try nous.control("/__fixture/nous")["counts"] as? [String: Any]) ?? [:]
        XCTAssertEqual(after["refresh"] as? Int, (before["refresh"] as? Int ?? -9) + 1, "the share rotated the pair exactly once")
        XCTAssertEqual(after["refreshReplayed"] as? Int, 0, "no refresh token was ever replayed")
        // The app starts with the pair the share saved.
        relaunch()
        XCTAssertTrue(waitUntil(timeout: 40) { self.app.tables["chat.table"].exists || self.app.collectionViews["bots.list"].exists }, "still signed in")
        XCTAssertFalse(app.textFields["sign-in-address"].exists)
        RunLoop.current.run(until: Date().addingTimeInterval(5))
        let later = (try nous.control("/__fixture/nous")["counts"] as? [String: Any]) ?? [:]
        XCTAssertEqual(later["refreshReplayed"] as? Int, 0, "and the app never replays the old one")
    }

    // MARK: Opt-in: other apps' own share buttons (HQN_SHARE_REAL_HOSTS=1)

    @MainActor func testH1_LinkFromSafari() throws {
        guard ProcessInfo.processInfo.environment["HQN_SHARE_REAL_HOSTS"]?.isEmpty == false else { throw XCTSkip("HQN_SHARE_REAL_HOSTS=1 runs this.") }
        signInFresh()
        app.terminate()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.launch()
        let page = account.url + "/__fixture/page"
        safari.open(URL(string: page)!)
        let onboarding = safari.buttons["Continue"]
        if onboarding.waitForExistence(timeout: 4), onboarding.isHittable { onboarding.tap() }
        let menu = safari.buttons["MoreMenuButton"]
        XCTAssertTrue(menu.waitForExistence(timeout: 30), "Safari's page menu")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        menu.tap()
        let share = safari.descendants(matching: .any).matching(NSPredicate(format: "label == 'Share' OR identifier == 'ShareButton'")).firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 15), "Safari's Share")
        share.tap()
        host = safari
        hostIsProbe = false
        let choice = try XCTUnwrap(target(wait: 12), "Safari's share sheet offers Hermes HQ")
        choice.tap()
        XCTAssertTrue(el("share.link").waitForExistence(timeout: 40), "the page arrives as a link")
        choose("ivy")
        shot("share-h1-safari")
        tapSend()
        expectSent(to: "Ivy")
        XCTAssertEqual(prompts().first?["text"] as? String, page)
    }

    @MainActor func testH2_PhotoFromPhotos() throws {
        guard ProcessInfo.processInfo.environment["HQN_SHARE_REAL_HOSTS"]?.isEmpty == false else { throw XCTSkip("HQN_SHARE_REAL_HOSTS=1 runs this.") }
        signInFresh()
        app.terminate()
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.launch()
        for title in ["Continue", "Not Now", "OK"] {
            let button = photos.buttons[title]
            if button.waitForExistence(timeout: 3), button.isHittable { button.tap() }
        }
        let first = photos.images.firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 30), "the library has a photo (scripts/e2e-share.sh adds one)")
        first.tap()
        let share = photos.buttons.matching(NSPredicate(format: "label == 'Share' OR identifier == 'PXOneUpShareButton'")).firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 15), "Photos' Share")
        share.tap()
        host = photos
        hostIsProbe = false
        let choice = try XCTUnwrap(target(wait: 12), "Photos' share sheet offers Hermes HQ")
        choice.tap()
        XCTAssertTrue(waitUntil(timeout: 60) { self.count("share.photo") == 1 }, "the photo arrives")
        choose("ivy")
        shot("share-h2-photos")
        tapSend()
        expectSent(to: "Ivy", timeout: 150)
        XCTAssertEqual(uploads().first?["gps"] as? Bool, false)
        XCTAssertEqual(uploads().first?["jpeg"] as? Bool, true)
    }

    // MARK: Helpers: the fixture and the shared folder

    private func path(_ name: String) -> String { media.appendingPathComponent(name).path }
    private func file(_ name: String) -> [String: Any] { ["file": path(name)] }

    private func state() -> [String: Any] { (try? account.control("/__fixture/state")) ?? [:] }
    private func list(_ key: String) -> [[String: Any]] { (state()[key] as? [[String: Any]]) ?? [] }
    private func prompts() -> [[String: Any]] { list("prompts") }
    private func uploads() -> [[String: Any]] { list("uploads").filter { ($0["status"] as? Int) == 200 } }
    private func ledger() -> [[String: Any]] { list("shareLedger") }

    /// What the extension itself sent: its HTTP calls and upgrades (by user agent) and the calls on its sockets.
    private func extensionLedger() -> [[String: Any]] {
        let all = ledger()
        let own = all.filter { ($0["ua"] as? String)?.hasPrefix("HermesHQShare/") == true }
        let sockets = Set(own.compactMap { $0["socket"] as? Int })
        return all.filter { entry in
            if let agent = entry["ua"] as? String { return agent.hasPrefix("HermesHQShare/") }
            return (entry["socket"] as? Int).map(sockets.contains) ?? false
        }
    }

    private func label(_ entry: [String: Any]) -> String {
        switch entry["kind"] as? String {
        case "http": return (entry["method"] as? String ?? "") + " " + (entry["path"] as? String ?? "")
        case "upgrade": return "UPGRADE " + (entry["path"] as? String ?? "")
        case "rpc": return entry["rpc"] as? String ?? ""
        default: return "REPLY"
        }
    }

    private func json(_ name: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func write(_ object: [String: Any], to name: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: folder.appendingPathComponent(name), options: .atomic)
    }

    private func remove(_ name: String) { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }

    private func faces() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("avatars").path)) ?? []).filter { !$0.hasPrefix(".") }
    }

    /// The roster key the app wrote for a profile.
    private func botKey(_ profile: String) -> String? {
        ((json("roster.json")?["bots"] as? [[String: Any]]) ?? []).first { $0["profile"] as? String == profile }?["key"] as? String
    }

    /// The roster the app wrote for `who`, once `accept` likes its bots.
    private func waitRoster(for who: FixtureAccount, timeout: TimeInterval = 30,
                            _ accept: ([[String: Any]]) -> Bool = { $0.count >= 2 }) -> [String: Any]? {
        let key = who.url + "\n" + who.username
        var found: [String: Any]?
        _ = waitUntil(timeout: timeout) {
            guard let roster = self.json("roster.json"), roster["account"] as? String == key,
                  accept((roster["bots"] as? [[String: Any]]) ?? []) else { return false }
            found = roster
            return true
        }
        return found
    }

    private func second() throws -> FixtureAccount {
        guard let path = ProcessInfo.processInfo.environment["HQN_SHARE_B"], !path.isEmpty,
              let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any],
              let url = object["url"] as? String, let username = object["username"] as? String, let password = object["password"] as? String else {
            throw XCTSkip("TEST_RUNNER_HQN_SHARE_B names the second gateway's credentials (scripts/e2e-share.sh sets it).")
        }
        return FixtureAccount(url: url, username: username, password: password)
    }

    // MARK: Helpers: Hermes HQ

    @MainActor private func launch(reset: Bool) {
        let app = XCUIApplication()
        app.launchArguments = reset ? ["-HQDebugResetAccounts", "YES"] : []
        app.launch()
        self.app = app
    }

    /// Hermes HQ again, as the person left it (signed in).
    @MainActor private func relaunch() { launch(reset: false) }

    /// A clean phone, signed in through the form, with the sheet's roster written.
    @MainActor private func signInFresh(bots: Int = 2) {
        launch(reset: true)
        signIn(account)
        XCTAssertTrue(app.collectionViews["bots.list"].waitForExistence(timeout: 60), "signed in: the Bots list shows")
        XCTAssertNotNil(waitRoster(for: account, timeout: 40) { $0.count >= bots }, "the app wrote the sheet's roster (\(bots) bots)")
        declineSavePassword()
    }

    /// One attempt, as a person types it.
    @MainActor private func signIn(_ who: FixtureAccount) {
        let address = app.textFields["sign-in-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 40), "the sign-in form shows")
        address.tap()
        if let current = address.value as? String, !current.isEmpty, current != address.placeholderValue, current != "my-mac.tail1234.ts.net" {
            address.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        address.typeText(who.url)
        let username = app.textFields["sign-in-username"]
        XCTAssertTrue(username.waitForExistence(timeout: 20))
        username.tap()
        if let current = username.value as? String, !current.isEmpty, current != username.placeholderValue, current != "Username" {
            username.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        username.typeText(who.username)
        let password = app.secureTextFields["sign-in-password"]
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        for _ in 0..<5 where !password.isHittable { app.swipeUp() }
        password.tap()
        password.typeText(who.password)
        let button = app.buttons["sign-in-password-button"]
        for _ in 0..<5 where !button.isHittable { app.swipeUp() }
        button.tap()
        declineSavePassword(wait: 3)
    }

    /// iOS's "Save Password?" can come up seconds after the sign-in, over whatever comes next: decline it.
    @MainActor private func declineSavePassword(wait: TimeInterval = 0) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for candidate in [app.buttons["Not Now"].firstMatch, springboard.buttons["Not Now"].firstMatch] {
            if wait > 0 ? candidate.waitForExistence(timeout: wait) : candidate.exists {
                candidate.tap()
                RunLoop.current.run(until: Date().addingTimeInterval(0.8))
                break
            }
        }
    }

    @MainActor private func openSettings() {
        let more = app.tabBars.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 15))
        let row = app.cells["more-row-settings"]
        for _ in 0..<4 {
            declineSavePassword()
            more.tap()
            if row.waitForExistence(timeout: 3), row.isHittable { break }
        }
        for _ in 0..<3 {
            row.tap()
            if app.buttons["settings.gateway-card"].waitForExistence(timeout: 4) { return }
        }
        XCTFail("Settings opens")
    }

    /// More › Settings › Gateway › Sign Out, confirmed.
    @MainActor private func signOut() {
        openSettings()
        app.buttons["settings.gateway-card"].tap()
        let signOut = app.buttons["gateway.sign-out"].firstMatch
        XCTAssertTrue(signOut.waitForExistence(timeout: 10), "the Gateway page shows Sign Out")
        for _ in 0..<4 where !signOut.isHittable { app.swipeUp() }
        signOut.tap()
        let sheetButton = app.sheets.buttons["Sign Out"]
        if sheetButton.waitForExistence(timeout: 4) {
            sheetButton.tap()
        } else {
            let all = app.buttons.matching(NSPredicate(format: "label == 'Sign Out'"))
            XCTAssertTrue(waitUntil(timeout: 4) { all.count >= 2 }, "the confirmation shows")
            all.element(boundBy: all.count - 1).tap()
        }
        XCTAssertTrue(app.textFields["sign-in-address"].waitForExistence(timeout: 20), "back to the sign-in form")
    }

    /// Leaves the app and comes back, as a person would: the Bots list asks the gateway again.
    @MainActor private func refreshBots() {
        XCUIDevice.shared.press(.home)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        app.activate()
        XCTAssertTrue(app.collectionViews["bots.list"].waitForExistence(timeout: 20))
    }

    @MainActor private func chatTitle() -> String {
        let title = app.descendants(matching: .any).matching(identifier: "chat.title").firstMatch
        return title.exists ? title.label : ""
    }

    @MainActor private func message(_ text: String) -> XCUIElement {
        app.tables["chat.table"].descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// Launches the app as it was left with a note waiting: the Bots list shows, no chat opens, the note is gone.
    @MainActor private func opensNothing(_ what: String) {
        relaunch()
        XCTAssertTrue(app.collectionViews["bots.list"].waitForExistence(timeout: 40), "\(what): the Bots list shows")
        XCTAssertTrue(waitUntil(timeout: 15) { self.json("last-sent.json") == nil && !FileManager.default.fileExists(atPath: self.folder.appendingPathComponent("last-sent.json").path) },
                      "\(what) is removed")
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        XCTAssertFalse(app.tables["chat.table"].exists, "\(what) opens no chat")
        app.terminate()
    }

    // MARK: Helpers: the share sheet

    /// An element of the extension's sheet (it is hosted inside the app that shares).
    @MainActor private func el(_ identifier: String) -> XCUIElement {
        host.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor private func count(_ identifier: String) -> Int {
        host.descendants(matching: .any).matching(identifier: identifier).count
    }

    @MainActor private func probeResult() -> String {
        guard hostIsProbe else { return "" }
        return ((try? host.staticTexts["probe.result"].snapshot())?.label) ?? ""
    }

    /// Launches the host app with `items` and opens the system share sheet.
    @MainActor private func present(_ items: [[String: Any]]) {
        let probe = XCUIApplication(bundleIdentifier: Self.probeId)
        let data = (try? JSONSerialization.data(withJSONObject: items)) ?? Data()
        probe.launchEnvironment = ["HQ_PROBE_ITEMS": String(decoding: data, as: UTF8.self)]
        probe.launch()
        host = probe
        hostIsProbe = true
        let share = probe.buttons["probe.share"]
        XCTAssertTrue(share.waitForExistence(timeout: 40), "the host app is up")
        XCTAssertEqual(probe.staticTexts["probe.count"].label, "\(items.count) item(s)", "every item was handed over")
        XCTAssertFalse(probe.staticTexts["probe.problems"].exists, "a test file is missing")
        share.tap()
    }

    /// "Hermes HQ" among the share sheet's apps: in the row (scrolled if need be), else under More. nil: not offered.
    @MainActor private func target(wait: TimeInterval, beforeMore: (() -> Void)? = nil) -> XCUIElement? {
        let named = NSPredicate(format: "label == 'Hermes HQ'")
        let cell = host.cells.matching(named).firstMatch
        let any = host.descendants(matching: .any).matching(named).firstMatch
        // The system sheet is up once it shows cells.
        guard host.cells.firstMatch.waitForExistence(timeout: 30) else { return nil }
        // The row of apps is dragged along by a point on it: at the largest type sizes it shows two apps at a time,
        // and the collection view itself is not always something a swipe can land on.
        let reminders = host.cells.matching(NSPredicate(format: "label == 'Reminders'")).firstMatch
        let anchor = reminders.exists ? reminders : host.cells.firstMatch
        let rowY = anchor.frame.midY, width = host.frame.width
        func swipeRow() {
            guard rowY > 0, rowY < host.frame.height else { return }
            let origin = host.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: width * 0.85, dy: rowY))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: width * 0.2, dy: rowY)))
        }
        if !any.waitForExistence(timeout: wait) {
            for _ in 0..<5 where !any.exists { swipeRow() }
        }
        if !any.exists {
            let more = host.descendants(matching: .any).matching(NSPredicate(format: "label == 'More'")).firstMatch
            guard more.exists else { return nil }
            for _ in 0..<5 where !more.isHittable { swipeRow() }
            guard more.isHittable else { return nil }
            beforeMore?()
            more.tap()
            // The full list fills in a moment after it opens: an empty list is no answer yet. Hermes HQ itself, or any
            // app iOS offers for this kind of share, says it has (Reminders for text and links, Preview for pictures).
            let filled = host.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["Hermes HQ", "Reminders", "Preview"])).firstMatch
            _ = filled.waitForExistence(timeout: 20)
            guard any.waitForExistence(timeout: 8) else { return nil }
        }
        for _ in 0..<6 where !any.isHittable { swipeRow() }
        return cell.exists && cell.isHittable ? cell : any
    }

    /// The system's own share sheet (or its "Apps" list under More) is up and has filled in: it shows something iOS
    /// offers for a share of pictures whatever the activation rules of other apps say (its "Save to Files" action,
    /// the Preview app, the Apps list's own title or one of its cells).
    @MainActor private func systemSheetFilledIn() -> Bool {
        let signs = NSPredicate(format: "label IN %@ OR identifier == 'shareCell'", ["Save to Files", "Preview", "Apps", "More"])
        return host.descendants(matching: .any).matching(signs).firstMatch.waitForExistence(timeout: 10)
    }

    /// Shares `items` to Hermes HQ: the extension's sheet is up when this returns.
    @MainActor private func openSheet(_ items: [[String: Any]], file: StaticString = #filePath, line: UInt = #line) {
        present(items)
        guard let choice = target(wait: 12) else {
            shot("zz-not-offered-\(items.count)")
            XCTFail("the share sheet offers Hermes HQ\n" + String(host.debugDescription.prefix(6000)), file: file, line: line)
            return
        }
        choice.tap()
        XCTAssertTrue(el("share.cancel").waitForExistence(timeout: 40), "the Hermes HQ sheet opens", file: file, line: line)
    }

    @MainActor private func cancelSheet() {
        let cancel = el("share.cancel")
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        cancel.tap()
        XCTAssertTrue(waitUntil(timeout: 20) { !cancel.exists }, "Cancel closes the sheet")
    }

    @MainActor private func choose(_ profile: String, file: StaticString = #filePath, line: UInt = #line) {
        let row = el("share.bot." + profile)
        XCTAssertTrue(row.waitForExistence(timeout: 40), "the sheet lists \(profile)", file: file, line: line)
        for _ in 0..<6 where !row.isHittable { host.swipeUp() }
        if !row.isSelected { row.tap() }
        XCTAssertTrue(waitUntil(timeout: 8) { row.isSelected }, "\(profile) is chosen", file: file, line: line)
    }

    @MainActor private func type(_ text: String) {
        let field = el("share.message")
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        for _ in 0..<6 where !field.isHittable { host.swipeDown() }
        field.tap()
        field.typeText(text)
    }

    @MainActor private func tapSend(file: StaticString = #filePath, line: UInt = #line) {
        let send = el("share.send")
        XCTAssertTrue(waitUntil(timeout: 30) { send.exists && send.isEnabled }, "Send is on", file: file, line: line)
        send.tap()
    }

    /// Waits for the share to end well. The "Sent to …" card stays 0.9 s, so on a busy Mac a poll can miss it: then the
    /// host's own word that the share completed, with the note the sheet left for the app, says the same thing.
    /// Returns whether the card itself was seen.
    @MainActor @discardableResult
    private func expectSent(to name: String, timeout: TimeInterval = 120, shotName: String? = nil,
                            file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let ends = host.descendants(matching: .any).matching(NSPredicate(format: "identifier IN %@", ["share.sent", "share.failure", "share.blocked"])).firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        var card: String?
        var completed = false
        while Date() < deadline {
            if let seen = try? ends.snapshot() {
                if seen.identifier == "share.sent" {
                    card = seen.label
                    if let shotName { shot(shotName) }
                    break
                }
                shot("zz-not-sent-\(name)")
                XCTFail("the share did not go: \(seen.label)", file: file, line: line)
                return false
            }
            if probeResult() == "completed" { completed = true; break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if let card {
            XCTAssertEqual(card, "Sent to \(name)", file: file, line: line)
        } else {
            if hostIsProbe {
                XCTAssertTrue(completed || waitUntil(timeout: 5) { self.probeResult() == "completed" }, "the share completed (\(probeResult()))", file: file, line: line)
            }
            XCTAssertEqual(json("last-sent.json")?["botName"] as? String, name, "the share went to \(name)", file: file, line: line)
        }
        XCTAssertTrue(waitUntil(timeout: 30) { !self.el("share.cancel").exists }, "the sheet closes by itself after sending", file: file, line: line)
        return card != nil
    }

    /// Opens the sheet on a share that cannot go yet and checks the sentence it shows.
    @MainActor private func blocked(says sentence: String, shot name: String, file: StaticString = #filePath, line: UInt = #line) {
        openSheet([["text": "Blocked?"]], file: file, line: line)
        let text = el("share.blocked")
        XCTAssertTrue(text.waitForExistence(timeout: 30), "the blocked screen shows", file: file, line: line)
        XCTAssertEqual(text.label, sentence, file: file, line: line)
        XCTAssertFalse(el("share.send").exists, "no Send on a blocked sheet", file: file, line: line)
        shot(name)
        cancelSheet()
    }

    // MARK: Helpers: screenshots

    /// `HQN_UI_DARK=1` (scripts/e2e-share.sh with HQN_SHARE_DARK=1) runs every test in dark appearance.
    static var darkRun: Bool { ProcessInfo.processInfo.environment["HQN_UI_DARK"] == "1" }

    /// Mean brightness of a screenshot, 0 (black) … 255 (white), from a small copy of it.
    private func brightness(_ screenshot: XCUIScreenshot) -> Double {
        guard let image = screenshot.image.cgImage else { return 255 }
        let width = 24, height = 52
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 255 }
        var sum = 0
        for index in stride(from: 0, to: pixels.count, by: 4) { sum += Int(pixels[index]) + Int(pixels[index + 1]) + Int(pixels[index + 2]) }
        return Double(sum) / Double(width * height * 3)
    }

    /// The whole screen, to the shots folder and to the test report. The file is named by what the screen shows
    /// (`<name>-light.png` / `<name>-dark.png`), never by what the run asked for.
    /// What the system or the timing answered in this run, where a test accepts more than one answer: printed, and kept
    /// beside the screenshots (`share-notes.txt`) so a report can quote it.
    private func note(_ line: String) {
        print("share: " + line)
        guard let shots else { return }
        let file = shots.appendingPathComponent("share-notes.txt")
        let entry = "\(Self.darkRun ? "dark" : "light") · \(name) · \(line)\n"
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(entry.utf8))
        } else {
            try? Data(entry.utf8).write(to: file)
        }
    }

    @MainActor private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let shots else { return }
        let looksDark = brightness(screenshot) < 120
        if looksDark != Self.darkRun { note("\(name) looks \(looksDark ? "dark" : "light") in a \(Self.darkRun ? "dark" : "light") run") }
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: shots.appendingPathComponent("\(name)-\(looksDark ? "dark" : "light").png"))
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
