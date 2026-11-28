// Regression tests for Domain 4 stress fixes:
// C6 (external URL deep-link guard), H3 (Mac .xlsx overflow & ZIP-bomb streaming cap), H22 (GatewayConfigStore.flush
// ephemeral store retention), H23 (LiveIntentsChat.isTop in two-pane mode), H24 (TasksWidgetWriter headless cold-launch
// fallback), M9 (LiveGroupedContent.markingTurnDone side-chat isolation), M10 (ConfigFieldEditor toolsets wipe guard),
// M11 (TileWidgetWriter post-sign-out / account-switch guard), M13 (MacWorkspaceBar closingTabId guard),
// M14 (ArrivalStage tween/side-task/arc teardown & dealloc), M16 (QuickActionsViewController observer cleanup),
// and L5 (Backdrop serial IO & generation check).

import CoreGraphics
import Foundation
import Synchronization
import Testing
import UIKit
@testable import HermesHQNative

// MARK: - Helpers

nonisolated private func awaitSemaphore(_ semaphore: DispatchSemaphore) async {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            semaphore.wait()
            continuation.resume()
        }
    }
}

nonisolated private func makeStressTask(
    id: String,
    title: String = "Check flights",
    status: String = "open",
    due: String? = nil,
    rev: Int = 3
) -> TodoTask {
    var object: [String: JSONValue] = [
        "id": .string(id),
        "rev": .number(Double(rev)),
        "title": .string(title),
        "who": .string("me"),
        "status": .string(status),
        "status_note": .string(""),
        "updated_at": .string("2026-11-04T08:00:00Z"),
        "created_at": .string("2026-11-03T08:00:00Z"),
        "notes": .string(""),
        "position": .number(0),
        "steps": .array([]),
    ]
    if let due { object["due"] = .string(due) }
    return try! JSONDecoder().decode(TodoTask.self, from: JSONValue.object(object).encoded())
}

private func makeSolidImage(width: Int = 32, height: Int = 24) -> CGImage {
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(red: 0.2, green: 0.5, blue: 0.85, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

#if targetEnvironment(macCatalyst)
/// Minimal ZIP builder with a caller-specified Central Directory uncompressed size so tests can verify
/// streaming inflation guards against lying headers (ZIP bombs).
nonisolated private func buildDeflatedZip(entryName: String, payload: Data, claimedUncompressedSize: UInt32) throws -> Data {
    let deflated = try (payload as NSData).compressed(using: .zlib) as Data
    let nameBytes = Data(entryName.utf8)
    var zip = Data()

    func append16(_ v: UInt16) {
        var le = v.littleEndian
        zip.append(UnsafeBufferPointer(start: &le, count: 1))
    }
    func append32(_ v: UInt32) {
        var le = v.littleEndian
        zip.append(UnsafeBufferPointer(start: &le, count: 1))
    }

    // Local file header (30 bytes + name + deflated data)
    append32(0x0403_4B50)
    append16(20) // version needed
    append16(0)  // flags
    append16(8)  // method: DEFLATE
    append16(0)  // mod time
    append16(0)  // mod date
    append32(0)  // crc-32
    append32(UInt32(deflated.count))
    append32(claimedUncompressedSize)
    append16(UInt16(nameBytes.count))
    append16(0)  // extra length
    zip.append(nameBytes)
    zip.append(deflated)

    let cdOffset = UInt32(zip.count)

    // Central Directory header (46 bytes + name)
    append32(0x0201_4B50)
    append16(20) // version made by
    append16(20) // version needed
    append16(0)  // flags
    append16(8)  // method: DEFLATE
    append16(0)  // mod time
    append16(0)  // mod date
    append32(0)  // crc-32
    append32(UInt32(deflated.count))
    append32(claimedUncompressedSize)
    append16(UInt16(nameBytes.count))
    append16(0)  // extra length
    append16(0)  // comment length
    append16(0)  // disk number
    append16(0)  // internal attrs
    append32(0)  // external attrs
    append32(0)  // local header offset
    zip.append(nameBytes)

    let cdSize = UInt32(zip.count) - cdOffset

    // End of Central Directory (22 bytes)
    append32(0x0605_4B50)
    append16(0)  // disk number
    append16(0)  // cd start disk
    append16(1)  // entries on this disk
    append16(1)  // total entries
    append32(cdSize)
    append32(cdOffset)
    append16(0)  // comment length

    return zip
}
#endif

// MARK: - Pure & Guard Regressions

@Suite("Domain 4 Deep-Link, Config, Live Activity, & Widget Guards")
struct MacIntentsWidgetsGuardTests {

    // MARK: C6 — External URL scheme guards

    @Test func externalNewChatNeverAutoSendsAndDropsUnknownProjectPaths() throws {
        let raw = try #require(URL(string: "hermes://new-chat?bot=otto&project=/Users/me/untrusted-dir&message=hello%20world&send=1"))
        let parsed = try #require(NewChatLink.parse(DeepLink.parse(raw, scheme: "hermes")))
        // Internal parse preserves Shortcuts' send=true contract.
        #expect(parsed.bot == "otto")
        #expect(parsed.project == "/Users/me/untrusted-dir")
        #expect(parsed.message == "hello world")
        #expect(parsed.send == true)

        // External URLs force send=false (prefill composer draft only).
        let external = parsed.forExternalURL
        #expect(external.send == false)
        #expect(external.message == "hello world")
        #expect(external.bot == "otto")

        let known = [
            ProjectShortcutRecord(key: "/Users/me/code/app", name: "App", account: "https://example.com\ntester"),
            ProjectShortcutRecord(key: "/Users/me/notes", name: "Notes", account: "https://example.com\ntester"),
        ]

        // Unknown arbitrary filesystem path is dropped so external URLs never silently invoke projects.create.
        let sanitizedUnknown = parsed.sanitizedForExternalURL(knownProjects: known)
        #expect(sanitizedUnknown.send == false)
        #expect(sanitizedUnknown.project == nil)
        #expect(sanitizedUnknown.message == "hello world")

        // Known saved project matches by folder (including trailing slash) or name, still with send=false.
        let knownByFolder = NewChatLink(bot: "ivy", project: "/Users/me/code/app/", message: "status", send: true)
            .sanitizedForExternalURL(knownProjects: known)
        #expect(knownByFolder.send == false)
        #expect(knownByFolder.project == "/Users/me/code/app")

        let knownByName = NewChatLink(bot: "ivy", project: "notes", message: "summarize", send: true)
            .sanitizedForExternalURL(knownProjects: known)
        #expect(knownByName.send == false)
        #expect(knownByName.project == "/Users/me/notes")
    }

    @Test @MainActor func externalTalkPromptAsksExplicitMicConfirmation() {
        let prompt = NewChatRouter.externalTalkPrompt(botName: "Otto")
        #expect(prompt.title == "Start voice conversation with Otto?")
        #expect(prompt.message.localizedCaseInsensitiveContains("microphone"))
        #expect(prompt.message.contains("Otto"))
        #expect(!prompt.action.isEmpty)
    }

    // MARK: M9 — Side-chat turnDone must not mark active main chat done

    @Test func sideChatTurnDoneDoesNotMarkActiveMainChatDone() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let t1 = t0.addingTimeInterval(45)

        let mainItem = LiveGroupedItem.from(
            subject: LiveActivitySubject(kind: .turn, id: "otto"),
            botName: "Otto",
            detail: nil,
            link: "hermes://session/main-456",
            session: "main-456",
            content: LiveActivityContent(phase: .working, startedAt: t0)
        )
        let mainOnly = LiveGroupedContent(items: [mainItem])

        // Side-chat push for a different session of the same bot must NOT clobber the active main chat.
        #expect(mainOnly.markingTurnDone(profile: "otto", session: "side-999", now: t1) == nil)

        // Matching the main chat's own session marks it done.
        let mainDone = mainOnly.markingTurnDone(profile: "otto", session: "main-456", now: t1)
        #expect(mainDone?.items.first?.phase == .done)
        #expect(mainDone?.items.first?.endedAt == t1)

        // Push with no session id still marks the main bot chat done.
        let nilSessionDone = mainOnly.markingTurnDone(profile: "otto", session: nil, now: t1)
        #expect(nilSessionDone?.items.first?.phase == .done)

        // Legacy tracked row without a recorded session id still matches by profile.
        let legacyItem = LiveGroupedItem.from(
            subject: LiveActivitySubject(kind: .turn, id: "otto"),
            botName: "Otto",
            detail: nil,
            link: nil,
            session: nil,
            content: LiveActivityContent(phase: .working, startedAt: t0)
        )
        let legacyDone = LiveGroupedContent(items: [legacyItem]).markingTurnDone(profile: "otto", session: "side-999", now: t1)
        #expect(legacyDone?.items.first?.phase == .done)

        // When both main chat and side chat are active, side-chat push ends ONLY the side chat.
        let sideItem = LiveGroupedItem.from(
            subject: LiveActivitySubject(kind: .turn, id: "otto/side-999"),
            botName: "Otto",
            detail: "Release Notes",
            link: "hermes://session/side-999",
            session: "side-999",
            content: LiveActivityContent(phase: .working, startedAt: t0)
        )
        let both = LiveGroupedContent(items: [mainItem, sideItem])
        let updated = both.markingTurnDone(profile: "otto", session: "side-999", now: t1)
        let updatedMain = updated?.items.first { $0.subject.id == "otto" }
        let updatedSide = updated?.items.first { $0.subject.id == "otto/side-999" }
        #expect(updatedMain?.phase == .working, "main chat stays working")
        #expect(updatedSide?.phase == .done, "side chat transitions to done")
    }

    @Test func liveActivitySubjectParsesSessionIdFromDeepLink() {
        #expect(LiveActivitySubject.sessionId(fromLink: "hermes://session/main-456") == "main-456")
        #expect(LiveActivitySubject.sessionId(fromLink: "hermes-dev://session/side-999") == "side-999")
        #expect(LiveActivitySubject.sessionId(fromLink: "hermes://job/otto|daily") == nil)
        #expect(LiveActivitySubject.sessionId(fromLink: "hermes://session/") == nil)
        #expect(LiveActivitySubject.sessionId(fromLink: nil) == nil)
    }

    // MARK: M10 — ConfigFieldEditor toolsets wipe confirmation guard

    @Test func toolsetsWipeConfirmationOnlyFiresForToolsetsKey() {
        let nonEmpty: JSONValue = .array([.string("web"), .string("terminal")])
        let empty: JSONValue = .array([])

        #expect(ConfigFieldEditor.needsToolsetsWipeConfirmation(key: "toolsets", previous: nonEmpty, next: empty))
        #expect(!ConfigFieldEditor.needsToolsetsWipeConfirmation(key: "toolsets", previous: empty, next: empty))
        #expect(!ConfigFieldEditor.needsToolsetsWipeConfirmation(key: "toolsets", previous: nonEmpty, next: .array([.string("web")])))

        // Non-toolsets list fields must never trigger the "Remove All Tool Groups?" confirmation.
        #expect(!ConfigFieldEditor.needsToolsetsWipeConfirmation(key: "command_allowlist", previous: nonEmpty, next: empty))
        #expect(!ConfigFieldEditor.needsToolsetsWipeConfirmation(key: "desktop.repo_scan_roots", previous: nonEmpty, next: empty))
        #expect(!ConfigFieldEditor.needsToolsetsWipeConfirmation(key: "terminal.env_passthrough", previous: nonEmpty, next: empty))
    }

    // MARK: M11 — TileWidgetWriter sign-out & account-switch guard

    @Test func tileWidgetShouldPersistBlocksSignOutSwitchAndCancel() {
        let accountA = "https://example.com|tester"
        let accountB = "https://other.example.com|ivy"

        #expect(TileWidgetWriter.shouldPersist(cancelled: false, currentAccountId: accountA, expectedAccountId: accountA))
        #expect(!TileWidgetWriter.shouldPersist(cancelled: false, currentAccountId: nil, expectedAccountId: accountA), "signed out")
        #expect(!TileWidgetWriter.shouldPersist(cancelled: false, currentAccountId: accountB, expectedAccountId: accountA), "switched account")
        #expect(!TileWidgetWriter.shouldPersist(cancelled: true, currentAccountId: accountA, expectedAccountId: accountA), "task cancelled")
    }

    // MARK: H3 — Mac .xlsx overflow & ZIP-bomb streaming inflation guard

    #if targetEnvironment(macCatalyst)
    @Test func spreadsheetColumnHandlesLimitAndOverflowSafely() {
        #expect(SpreadsheetFile.SheetCells.column(of: "A1") == 0)
        #expect(SpreadsheetFile.SheetCells.column(of: "Z1") == 25)
        #expect(SpreadsheetFile.SheetCells.column(of: "AA1") == 26)
        #expect(SpreadsheetFile.SheetCells.column(of: "AB12") == 27)
        #expect(SpreadsheetFile.SheetCells.column(of: "XFD1") == 16_383, "Excel max column XFD")
        #expect(SpreadsheetFile.SheetCells.column(of: "XFE1") == nil, "past Excel max column")
        #expect(SpreadsheetFile.SheetCells.column(of: "ZZZZZZZZZZZZZZZZ1") == nil, "64-bit overflow returns nil instead of trapping")
        #expect(SpreadsheetFile.SheetCells.column(of: String(repeating: "Z", count: 40) + "1") == nil)
        #expect(SpreadsheetFile.SheetCells.column(of: "123") == nil)
        #expect(SpreadsheetFile.SheetCells.column(of: "") == nil)
    }

    @Test func spreadsheetInflateRejectsZipBombLyingInCentralDirectory() throws {
        // Honest small entry inflates cleanly.
        let okPayload = Data("<worksheet><sheetData/></worksheet>".utf8)
        let okZip = try buildDeflatedZip(entryName: "xl/sheet1.xml", payload: okPayload, claimedUncompressedSize: UInt32(okPayload.count))
        let okArchive = try #require(SpreadsheetFile.Archive(okZip))
        #expect(okArchive.file("xl/sheet1.xml") == okPayload)

        // Direct streaming cap abort when inflated output exceeds maxBytes.
        let medium = Data(repeating: 0x41, count: 200_000)
        let mediumDeflated = try (medium as NSData).compressed(using: .zlib) as Data
        #expect(SpreadsheetFile.Archive.inflateRawDeflate(mediumDeflated, maxBytes: 4_096) == nil)
        #expect(SpreadsheetFile.Archive.inflateRawDeflate(mediumDeflated, maxBytes: 250_000) == medium)

        // ZIP bomb whose Central Directory lies (`size == 10`) while payload inflates past `maxInflatedBytes` (32 MB).
        let bombPayload = Data(repeating: 0x41, count: SpreadsheetFile.Archive.maxInflatedBytes + 128_000)
        let bombZip = try buildDeflatedZip(entryName: "xl/sheet1.xml", payload: bombPayload, claimedUncompressedSize: 10)
        let bombArchive = try #require(SpreadsheetFile.Archive(bombZip))
        #expect(bombArchive.file("xl/sheet1.xml") == nil, "lying Central Directory must not bypass streaming inflation cap")
    }

    // MARK: M13 — MacWorkspaceBar closingTabId guard

    @Test func macWorkspaceBarClosingGuardOnlyProtectsRemovedActiveTab() {
        // Closing an inactive tab must never set closingTabId.
        #expect(MacWorkspaceBar.closingGuardId(removedIds: ["bot:ivy"], activeId: "bot:otto") == nil)
        // Closing the active tab guards it during detail-pane transition.
        #expect(MacWorkspaceBar.closingGuardId(removedIds: ["bot:otto"], activeId: "bot:otto") == "bot:otto")
        // Close Others / Close Tabs to Right / Close All guard activeId iff it was among removed tabs.
        #expect(MacWorkspaceBar.closingGuardId(removedIds: ["bot:ivy", "session:otto:s1"], activeId: "session:otto:s1") == "session:otto:s1")
        #expect(MacWorkspaceBar.closingGuardId(removedIds: ["bot:ivy", "session:otto:s1"], activeId: "bot:wren") == nil)
        #expect(MacWorkspaceBar.closingGuardId(removedIds: ["bot:ivy"], activeId: nil) == nil)
    }
    #endif
}

// MARK: - Runtime, Lifecycle, & Concurrency Regressions

@MainActor
@Suite("Domain 4 Runtime, Lifecycle, & Concurrency Regressions", .serialized)
struct MacIntentsWidgetsRuntimeTests {

    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<250 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: H22 — GatewayConfigStore.flush() keeps ephemeral store alive until PATCH lands

    @Test func gatewayConfigStoreFlushPersistsEvenWhenStoreReleasesImmediately() async {
        let initial: JSONValue = [
            "approvals": ["mode": "smart", "timeout": 60],
        ]
        let client = PagesFakeClient { request in
            if request.method == "PUT" {
                try await Task.sleep(for: .milliseconds(60))
                return ["ok": true]
            }
            switch request.path {
            case "/api/config": return initial
            case "/api/config/schema": return ["fields": ["approvals.mode": ["type": "string"]]]
            case "/api/config/defaults": return ["approvals": ["mode": "manual"]]
            default: return ["ok": true]
            }
        }

        weak var weakStore: GatewayConfigStore?
        do {
            let store = GatewayConfigStore(api: GatewaySettingsAPI(client: client))
            store.debounce = .seconds(10)
            weakStore = store
            await store.load()
            #expect(store.phase == .loaded)
            store.set("approvals.mode", "off")
            store.flush()
            // Store leaves scope immediately (simulating popping an ephemeral per-bot settings page).
        }

        await waitFor { client.log.contains { $0.method == "PUT" } }
        let puts = client.log.filter { $0.method == "PUT" }
        #expect(puts.count == 1, "flushed PATCH must reach the gateway even after caller drops the store")
        #expect(puts.first?.path == "/api/config")
        #expect(puts.first?.body == ["config": ["approvals": ["mode": "off"]]])

        // Once the flushed save completes, the chain clears and the ephemeral store deallocates with no retain cycle.
        await waitFor { weakStore == nil }
        #expect(weakStore == nil, "ephemeral store must deallocate after its flushed PATCH finishes")
    }

    // MARK: H23 — LiveIntentsChat.isTop works in both two-pane (iPad/Mac) and single-pane layouts

    @Test func liveIntentsChatIsTopWorksInTwoPaneAndSinglePaneModes() throws {
        let rig = try PaneRouterTests.rig()
        defer { rig.close() }
        #expect(rig.split.isDouble)

        let (first, _) = rig.chat("Otto")
        rig.tabs.botsViewController.openDetail(first, animated: false)
        let firstHandle = LiveIntentsChat(screen: first)
        #expect(rig.tabs.chatOnShow === first)
        #expect(firstHandle.isTop, "chat shown in split.detail must report isTop == true in two-pane mode")

        let (second, _) = rig.chat("Ivy")
        rig.tabs.botsViewController.openDetail(second, animated: false)
        let secondHandle = LiveIntentsChat(screen: second)
        #expect(!firstHandle.isTop, "replaced chat is no longer top")
        #expect(secondHandle.isTop, "new chat in split.detail is top")

        rig.split.closeDetail(animated: false)
        #expect(!secondHandle.isTop, "closed detail chat is no longer top")

        // Also stays accurate in compact single-pane layout.
        rig.narrow()
        let (compact, _) = rig.chat("Wren")
        rig.bots.pushViewController(compact, animated: false)
        #expect(LiveIntentsChat(screen: compact).isTop)
    }

    // MARK: M14 — ArrivalStage teardown breaks retain cycle & bounds arcs/side tasks

    @Test func arrivalStageDrainsTweensAndSideTasksOnWindowRemovalAndHide() async {
        weak var weakStage: ArrivalStage?
        do {
            let stage = ArrivalStage(place: ArrivalWorld.Place(secondsFromGMT: 0, identifier: "Europe/London"))
            stage.sounds = false
            stage.setShown(true, animated: false)
            weakStage = stage

            stage.begin { s in
                s.spawn {
                    try await Task.sleep(for: .seconds(30))
                }
                s.spawn {
                    // Completes immediately and must self-prune from `side`.
                    try await Task.sleep(for: .milliseconds(1))
                }
                try await s.tw([(\.glow, 1.0)], 30_000)
            }

            await waitFor { stage.activeSideTaskCount >= 1 && (stage.still || stage.activeTweenCount >= 1) }
            #expect(stage.activeSideTaskCount >= 1)
            if !stage.still {
                #expect(stage.activeTweenCount == 1)
            }

            // Hiding the stage cancels scripts/side tasks and resumes suspended tween continuations.
            stage.setShown(false, animated: false)
            #expect(stage.activeTweenCount == 0)
            #expect(stage.activeSideTaskCount == 0)
            #expect(stage.activeArcCount == 0)

            // Re-showing and leaving window must likewise tear everything down cleanly.
            stage.setShown(true, animated: false)
            stage.begin { s in
                s.spawn { try await Task.sleep(for: .seconds(30)) }
                try await s.tw([(\.flash, 1.0)], 30_000)
            }
            await waitFor { stage.activeSideTaskCount == 1 && (stage.still || stage.activeTweenCount == 1) }

            stage.windowChanged(false)
            #expect(stage.activeTweenCount == 0)
            #expect(stage.activeSideTaskCount == 0)
            #expect(stage.activeArcCount == 0)
        }

        await waitFor { weakStage == nil }
        #expect(weakStage == nil, "ArrivalStage must not be retained by suspended tween continuations after stop/windowChanged(false)")
    }

    // MARK: M16 — QuickActionsViewController tracks & removes all NotificationCenter observers

    @Test func quickActionsViewControllerDeallocatesAndRemovesObservers() async {
        weak var weakVC: QuickActionsViewController?
        do {
            let vc = QuickActionsViewController(inSheet: true)
            #expect(vc.observers.isEmpty)
            vc.loadViewIfNeeded()
            #expect(vc.observers.count == 9, "all 9 NotificationCenter observer tokens must be retained for deinit removal")
            weakVC = vc
        }

        await waitFor { weakVC == nil }
        #expect(weakVC == nil)

        // Posting observed notifications after deinit must remain safe.
        let center = NotificationCenter.default
        center.post(name: QuickTileStore.didChange, object: nil)
        center.post(name: Theme.didChange, object: nil)
        center.post(name: ArtifactPins.didChange, object: nil)
        center.post(name: TileMaker.changed, object: nil)
    }

    #if targetEnvironment(macCatalyst)
    @Test func macInspectorDeallocatesAndRemovesThemeObserver() async {
        weak var weakInspector: MacInspector?
        do {
            let inspector = MacInspector()
            #expect(inspector.themeObserver == nil)
            inspector.loadViewIfNeeded()
            #expect(inspector.themeObserver != nil, "Theme.didChange observer token must be retained for deinit removal")
            weakInspector = inspector
        }

        await waitFor { weakInspector == nil }
        #expect(weakInspector == nil)
        NotificationCenter.default.post(name: Theme.didChange, object: nil)
    }
    #endif

    // MARK: L5 — Backdrop serial IO & generation check prevents stale photo adoption

    @Test func backdropStalePhotoWriteNeverOverridesNewerPresetOrClear() async throws {
        let suiteName = "hqn.backdrop.stress.\(UUID().uuidString)"
        let suite = try #require(UserDefaults(suiteName: suiteName))
        suite.removePersistentDomain(forName: suiteName)
        let folder = FileManager.default.temporaryDirectory.appending(path: suiteName, directoryHint: .isDirectory)
        defer {
            suite.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: folder)
        }

        let backdrop = Backdrop(place: .chats, defaults: suite, folder: folder)

        // Race 1: setPhoto in flight while user switches to a preset.
        let entered1 = DispatchSemaphore(value: 0)
        let release1 = DispatchSemaphore(value: 0)
        backdrop.photoWriter = { image, dir in
            entered1.signal()
            release1.wait()
            return try Backdrop.write(image, into: dir)
        }
        let photoTask1 = Task { try await backdrop.setPhoto(PickedPhoto(image: makeSolidImage())) }
        await awaitSemaphore(entered1)
        backdrop.setPreset(.ocean)
        release1.signal()
        try await photoTask1.value
        await backdrop.flushIOForTests()

        #expect(backdrop.source == .preset(.ocean), "stale photo write must not overwrite newer preset")
        let filesAfterPreset = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        #expect(filesAfterPreset.isEmpty, "stale photo file must be deleted from disk")

        // Race 2: setPhoto in flight while user clears background to None.
        let entered2 = DispatchSemaphore(value: 0)
        let release2 = DispatchSemaphore(value: 0)
        backdrop.photoWriter = { image, dir in
            entered2.signal()
            release2.wait()
            return try Backdrop.write(image, into: dir)
        }
        let photoTask2 = Task { try await backdrop.setPhoto(PickedPhoto(image: makeSolidImage(width: 24, height: 32))) }
        await awaitSemaphore(entered2)
        backdrop.clear()
        release2.signal()
        try await photoTask2.value
        await backdrop.flushIOForTests()

        #expect(backdrop.source == nil, "stale photo write must not resurrect after clear()")
        let filesAfterClear = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        #expect(filesAfterClear.isEmpty, "stale photo file must be removed after clear()")
    }
}

// MARK: - H24: Headless TasksWidgetWriter check-off (serialized with TileWidgetStoreTests on WidgetVault.testPrefix)

nonisolated private struct HeadlessRequestState: Sendable {
    var completed = false
    var requests: [(method: String, path: String, body: JSONValue?)] = []
}

private func withIsolatedWidgetVault(_ body: () async throws -> Void) async rethrows {
    let saved = WidgetVault.testPrefix
    WidgetVault.testPrefix = "ai.hermes.hq.widget-stress-\(UUID().uuidString.prefix(8))."
    defer {
        TasksWidgetStore.removeAll()
        TileWidgetStore.removeAll()
        WidgetVault.testPrefix = saved
    }
    try await body()
}

extension TileWidgetStoreTests {

    @Test @MainActor func headlessTaskCheckOffCompletesTaskAndUpdatesWidgetStore() async {
        await withIsolatedWidgetVault {
            let accountKey = TileWidgetIndex.key("https://example.com|tester")
            let todayKey = TodoViews.dayKey(Date())
            let openTask = makeStressTask(id: "t_cold", title: "Ship release", status: "open", due: todayKey, rev: 7)
            var doneTask = openTask
            doneTask.status = "done"
            doneTask.rev = 8
            doneTask.doneAt = TodoDates.now()

            let openWire = try! JSONValue.parse(JSONEncoder().encode(openTask))
            let doneWire = try! JSONValue.parse(JSONEncoder().encode(doneTask))
            let tasksBase = TasksAPI.base
            let state = Mutex(HeadlessRequestState())

            let writer = TasksWidgetWriter(
                enabled: true,
                store: { nil },
                headlessResolver: { expected in
                    guard expected == accountKey else { return (nil, false) }
                    let context = TasksWidgetWriter.HeadlessContext(
                        accountKey: accountKey,
                        bots: [ShareBot(key: "ios-direct::otto", name: "Otto", profile: "otto", session: "s-otto")],
                        send: { method, path, data in
                            let parsedBody = data.flatMap { try? JSONValue.parse($0) }
                            let isCompleted = state.withLock { s -> Bool in
                                s.requests.append((method, path, parsedBody))
                                if method == "PATCH", path == tasksBase + "/t_cold" {
                                    s.completed = true
                                }
                                return s.completed
                            }
                            if method == "PATCH" {
                                return ShareRESTAnswer(status: 200, data: try! doneWire.encoded())
                            }
                            let listPayload: JSONValue = .object([
                                "rev": .number(isCompleted ? 2 : 1),
                                "tasks": .array([isCompleted ? doneWire : openWire]),
                                "unchanged": .bool(false),
                            ])
                            return ShareRESTAnswer(status: 200, data: try! listPayload.encoded())
                        }
                    )
                    return (context, false)
                }
            )
            writer.readyWaitAttempts = 0

            let ok = await writer.checkOffFromWidget("t_cold", account: accountKey)
            #expect(ok, "cold background launch without TasksStore must complete task headlessly")

            let requests = state.withLock { $0.requests }
            #expect(requests.map(\.method) == ["GET", "PATCH", "GET"])
            #expect(requests[1].path == TasksAPI.base + "/t_cold")
            #expect(requests[1].body?["rev"] == .number(7))
            #expect(requests[1].body?["status"] == .string("done"))

            let index = TasksWidgetStore.loadIndex()
            #expect(index?.state == .live)
            #expect(index?.account == accountKey)
            let todayRows = TasksWidgetStore.loadView("today")?.frame(at: Date())?.sections.flatMap(\.rows) ?? []
            #expect(todayRows.isEmpty, "completed task leaves Today in the persisted widget snapshot")
        }
    }

    @Test @MainActor func headlessTaskCheckOffRejectsWrongAccountAndHandlesSignOut() async {
        await withIsolatedWidgetVault {
            let validKey = TileWidgetIndex.key("https://example.com|tester")
            let called = Mutex(0)

            // Wrong account: refused without sending any network request.
            let wrongAccountWriter = TasksWidgetWriter(
                enabled: true,
                store: { nil },
                headlessResolver: { expected in
                    guard expected == validKey else { return (nil, false) }
                    let context = TasksWidgetWriter.HeadlessContext(
                        accountKey: validKey,
                        bots: [],
                        send: { _, _, _ in
                            called.withLock { $0 += 1 }
                            return ShareRESTAnswer(status: 200, data: Data())
                        }
                    )
                    return (context, false)
                }
            )
            wrongAccountWriter.readyWaitAttempts = 0
            #expect(await wrongAccountWriter.checkOff("t_cold", account: "0000000000000000") == false)
            #expect(called.withLock { $0 } == 0)

            // Signed out: refuses and marks widget store signed out.
            let signedOutWriter = TasksWidgetWriter(
                enabled: true,
                store: { nil },
                headlessResolver: { _ in (nil, true) }
            )
            signedOutWriter.readyWaitAttempts = 0
            #expect(await signedOutWriter.checkOff("t_cold", account: validKey) == false)
            #expect(TasksWidgetStore.loadIndex()?.state == .signedOut)
        }
    }
}
