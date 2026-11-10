// Regression tests for the m2/integrate verify round 3 repairs: queued messages outlive the chat screen (drained off
// screen, kept for the next open, written to disk), a fresh send resumes a parked queue, the Bots rows' "Draft:" line,
// the edit guard across stacked pages, the Kanban override against a gateway without the API, the sheet title fit, the
// HTML preview's viewport and the glides' hitch-proof clock.

import Foundation
import Synchronization
import Testing
import UIKit
@testable import HermesHQNative

@MainActor
@Suite("Verify round 3 repairs", .serialized)
struct VerifyRoundThreeRepairTests {

    // MARK: Queued messages outlive the screen

    private func harness() throws -> ChatHarness {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        QueueStash.shared.purge(accountId: h.client.account.id)
        return h
    }

    /// After the open (its resume answered from the fixture): sends stream, Stop interrupts.
    private func scriptTurns(_ h: ChatHarness) {
        h.client.onCall { method, _ in
            switch method {
            case "prompt.submit": return ["status": "streaming"]
            case "session.interrupt": return ["status": "interrupted"]
            case "session.active_list": return ["sessions": []]
            default: return [:]
            }
        }
    }

    private func submitted(_ h: ChatHarness) -> [String] {
        h.client.calls("prompt.submit").compactMap { $0.params["text"]?.string }
    }

    @Test func aQueueLeftBehindStillGoesOutWhenTheReplyEnds() async throws {
        let h = try harness()
        defer { QueueStash.shared.purge(accountId: h.client.account.id) }
        let s = h.make()
        s.keepQueue()
        s.queueDrainFallback = .milliseconds(30)
        var away: [Bool] = []
        s.onDrainingAwayChange = { away.append($0) }
        #expect(await h.open())
        scriptTurns(h)
        s.redirectUnsupported = true   // a gateway that can’t add to a reply: typed words queue
        s.send("long one")
        await h.emit([h.event("message.start"), h.event("message.delta", ["text": "Working on it"])])
        s.send("queued A")
        #expect(s.queuedMessages.map(\.text) == ["queued A"])
        s.stopObserving()                                                      // Back to the Bots list
        #expect(s.drainingAway)
        #expect(away == [true])
        await h.emit([h.event("message.complete", ["text": "Working on it", "status": "complete"]),
                      h.event("session.info", ["running": false])])
        #expect(await waitUntil { submitted(h) == ["long one", "queued A"] })  // sent off screen
        #expect(s.queuedMessages.isEmpty)
        await h.emit([h.event("message.start"), h.event("message.complete", ["text": "Reply to A", "status": "complete"])])
        s.flushChanges()
        #expect(await waitUntil { s.flushChanges(); return !s.drainingAway })
        #expect(away == [true, false])                                       // the app model lets it go
        #expect(QueueStash.shared.items(accountId: h.client.account.id, scope: s.layoutScope).isEmpty)
    }

    /// [owner-wait] A send waiting for a cron job's run to let go of the chat is held like a queue: it goes out off
    /// screen, and opening the chat meanwhile finds it still waiting (the app model returns this chat).
    @Test func aSendWaitingForTheOwnerIsHeldOffScreenUntilItGoesOut() async throws {
        let h = try harness()
        defer { QueueStash.shared.purge(accountId: h.client.account.id) }
        let s = h.make()
        s.keepQueue()
        var away: [Bool] = []
        s.onDrainingAwayChange = { away.append($0) }
        #expect(await h.open())
        let free = Mutex(false)
        h.client.onCall { method, _ in
            switch method {
            case "prompt.submit":
                if !free.withLock({ $0 }) {
                    throw RPCError(code: 4090, message: "This chat is open in another Hermes window/terminal.\n"
                                   + "Details: session 20260101_090000_aa0001 opened by cli 9m ago.", data: ["reason": "SESSION_NOT_OWNED"])
                }
                return ["status": "streaming", "user_row_id": 93]
            case "session.active_list": return ["sessions": []]
            default: return [:]
            }
        }
        s.send("waiting one")
        #expect(await waitUntil { s.ownerWaitNotice == .backgroundTask })
        s.stopObserving()                                                       // back to the Bots list
        #expect(s.drainingAway)
        #expect(away == [true])
        free.withLock { $0 = true }                                             // the job lets go
        #expect(await waitUntil { s.messages.last { $0.role == .user }?.rowId == 93 })
        #expect(submitted(h).last == "waiting one")
        #expect(s.drainingAway)                                                 // its reply still runs
        await h.emit([h.event("message.start"), h.event("message.complete", ["text": "Done", "status": "complete"]),
                      h.event("session.info", ["running": false])])
        #expect(await waitUntil { s.flushChanges(); return !s.drainingAway })
        #expect(away == [true, false])
    }

    @Test func aParkedQueueWaitsForTheNextOpenOfTheChat() async throws {
        let h = try harness()
        defer { QueueStash.shared.purge(accountId: h.client.account.id) }
        let s = h.make()
        s.keepQueue()
        #expect(await h.open())
        scriptTurns(h)
        s.redirectUnsupported = true   // a gateway that can’t add to a reply: typed words queue
        s.send("long one")
        await h.emit([h.event("message.start"), h.event("message.delta", ["text": "Long"])])
        s.send("queued A")
        s.stop()                                                                 // Stop parks the queue
        #expect(s.isQueueParked)
        s.stopObserving()
        #expect(!s.drainingAway)                                                 // nothing to drain: it waits
        let scope = s.layoutScope
        #expect(QueueStash.shared.items(accountId: h.client.account.id, scope: scope).map(\.text) == ["queued A"])

        let reopened = LiveChatSession(client: h.client, account: h.client.account, profile: h.profile, storedSessionId: h.stored,
                                       title: "Hermes", head: nil, cache: h.cache, resolveSessionId: nil, frameMode: .manual)
        reopened.keepQueue()
        #expect(reopened.queuedMessages.map(\.text) == ["queued A"])            // the card shows again, on the first frame
        #expect(reopened.isQueueParked)
        // Another chat screen on the same chat while this one holds it: it never takes (or overwrites) the queue.
        let second = LiveChatSession(client: h.client, account: h.client.account, profile: h.profile, storedSessionId: h.stored,
                                     title: "Hermes", head: nil, cache: h.cache, resolveSessionId: nil, frameMode: .manual)
        second.keepQueue()
        #expect(second.queuedMessages.isEmpty)
        #expect(QueueStash.shared.items(accountId: h.client.account.id, scope: scope).map(\.text) == ["queued A"])
    }

    @Test func theStashReachesTheDiskWithItsMemosAndGoesWithTheAccount() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "queue-stash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let stash = QueueStash(base: base)
        let owner = NSObject()
        let account = "http://127.0.0.1:9717|stash-\(UUID().uuidString)"
        let scope = "\(account)|default|20260929_120000_aabbcc01"
        #expect(stash.claim(accountId: account, scope: scope, owner: owner) == nil)
        // [live words] A queued memo is written with the queue; one whose recording is gone is dropped when read back.
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let recording = base.appending(path: "voice-memo.m4a")
        try Data([1, 2, 3]).write(to: recording)
        var memo = MemoFile(path: recording.path, seconds: 2, peaks: [], mime: "audio/x-m4a")
        memo.words = "and the eggs"
        let gone = MemoFile(path: "memos/a.m4a", seconds: 2, peaks: [], mime: "audio/x-m4a")
        stash.update(accountId: account, scope: scope, profile: "default", owner: owner,
                     items: [QueuedMessage(id: "q1", text: "words"), QueuedMessage(id: "q2", text: "", memo: memo),
                             QueuedMessage(id: "q4", text: "", memo: gone),
                             QueuedMessage(id: "q3", text: "continue", hidden: true, display: "Continue toward goal")],
                     parked: true)
        stash.flush()
        let stored = QueueStash.load(accountId: account, base: base)
        #expect(stored[scope]?.items.map(\.id) == ["q1", "q2", "q3"])
        #expect(stored[scope]?.items[1].memo == memo)
        #expect(stored[scope]?.items.last?.hidden == true)
        #expect(QueueStash.memoPaths(accountId: account, base: base) == [recording.path])   // the memo sweep keeps it
        // A new run: the queue is there for the chat's first open, paused with Resume ([m9/composer] 3x-composer §16.2:
        // nothing is sent after a relaunch that the person did not just ask for).
        let next = QueueStash(base: base)
        let found = next.claim(accountId: account, scope: scope, owner: NSObject())
        #expect(found?.items.map(\.text) == ["words", "", "continue"])
        #expect(found?.parked == true)
        next.purge(accountId: account)
        next.flush()
        #expect(QueueStash.load(accountId: account, base: base).isEmpty)
    }

    @Test func aFreshSendResumesAParkedQueue() async throws {
        let h = try harness()
        let s = h.make()
        s.queueDrainFallback = .milliseconds(30)
        #expect(await h.open())
        scriptTurns(h)
        s.redirectUnsupported = true   // a gateway that can’t add to a reply: typed words queue
        s.send("long one")
        await h.emit([h.event("message.start"), h.event("message.delta", ["text": "Long"])])
        s.send("queued A")
        s.stop()
        await h.emit([h.event("message.complete", ["text": "Long", "status": "interrupted"]), h.event("session.info", ["running": false])])
        #expect(await waitUntil { !s.isRunning })
        #expect(s.isQueueParked)
        s.send("fresh B")                                                        // idle: B goes first, the park lifts
        #expect(!s.isQueueParked)
        #expect(await waitUntil { submitted(h) == ["long one", "fresh B"] })
        await h.emit([h.event("message.start")])
        s.send("queued C")
        await h.emit([h.event("message.complete", ["text": "B done", "status": "complete"]), h.event("session.info", ["running": false])])
        #expect(await waitUntil { submitted(h) == ["long one", "fresh B", "queued A"] })
        await h.emit([h.event("message.start"), h.event("message.complete", ["text": "A done", "status": "complete"]),
                      h.event("session.info", ["running": false])])
        #expect(await waitUntil { submitted(h) == ["long one", "fresh B", "queued A", "queued C"] })
    }

    // MARK: Bots rows: "Draft:"

    @Test func aBotWithAnUnsentDraftSaysDraft() {
        let ivy = RosterProfile(json: BotsTest.row("ivy", canonical: BotsTest.session("s1", preview: "Synthetic voice QA", lastActive: 100)))!
        let hermes = RosterProfile(json: BotsTest.row("default", canonical: BotsTest.session("d1", preview: "Build 47 chat.", lastActive: 90)))!
        var input = RosterBuilder.Input(profiles: [ivy, hermes])
        input.drafts = ["ivy": "draft B words"]
        let out = RosterBuilder.build(input)
        #expect(out.details["ivy"]?.preview.prefix == "Draft:")
        #expect(out.details["ivy"]?.preview.text == "draft B words")
        #expect(out.layout.flat.first { $0.id == "ivy" }?.preview == "Draft: draft B words")
        #expect(out.details["default"]?.preview.prefix == nil)
        #expect(out.details["default"]?.preview.text == "Build 47 chat.")
    }

    // MARK: Bot Info: the edit guard asks for every dirty page on the stack

    private final class Page: UIViewController, EditingPage {
        var dirty = false
        var hasChanges: Bool { dirty }
    }

    @Test func anUntouchedEditHeadKeepsTheDirtyEditBotsLock() {
        let info = UIViewController()
        let editBot = Page()
        let editHead = Page()
        let navigation = UINavigationController(rootViewController: info)
        navigation.setViewControllers([info, editBot], animated: false)
        editBot.dirty = true
        editBot.updateModalLock()
        #expect(navigation.isModalInPresentation)
        navigation.setViewControllers([info, editBot, editHead], animated: false)
        editHead.updateModalLock()                                            // Edit Head appears with nothing changed
        #expect(navigation.isModalInPresentation)                              // the swipe down still asks
        #expect(EditingGuard.dirtyPage(in: navigation) === editBot)
        #expect(navigation.interactivePopGestureRecognizer?.isEnabled != false) // back to Edit Bot keeps its typing
        navigation.setViewControllers([info], animated: false)                  // discarded, back on Bot Info
        EditingGuard.refreshLock(navigation)
        #expect(!navigation.isModalInPresentation)
    }

    // MARK: Pages: the Kanban override meets a gateway without the API

    @Test func theOnOverrideNeverShowsABoardTheGatewayDoesntHave() {
        let account = GatewayAccount(id: "http://127.0.0.1:9735|override-\(UUID().uuidString)", baseURL: URL(string: "http://127.0.0.1:9735")!,
                                     kind: .password, username: "pages", label: "t")
        let defaults = UserDefaults.standard
        defer { for key in [PagesTabs.overrideKey(account), PagesTabs.availabilityKey(account)] { defaults.removeObject(forKey: key) } }
        defaults.set("on", forKey: PagesTabs.overrideKey(account))
        defaults.set(KanbanAvailability.unused.rawValue, forKey: PagesTabs.availabilityKey(account))
        #expect(PagesTabs.decision(account) == .on)                              // present but unused: On shows it
        defaults.set(KanbanAvailability.absent.rawValue, forKey: PagesTabs.availabilityKey(account))
        #expect(PagesTabs.decision(account) == .absent)                          // the API is gone: no dead tab
        defaults.removeObject(forKey: PagesTabs.availabilityKey(account))
        #expect(PagesTabs.decision(account) == .on)                              // not probed yet: the override holds
    }

    // MARK: Sheet titles keep their words whole

    @Test func aLongTokenShrinksToOneLineInsteadOfBreaking() {
        let font = UIFont.systemFont(ofSize: 22, weight: .semibold)
        #expect(!SheetTitleLabel.fits("OPENWEATHER_API_KEY", font: font, width: 200, lines: 1))
        #expect(SheetTitleLabel.fits("OPENWEATHER_API_KEY", font: font.withSize(13.5), width: 200, lines: 1))
        #expect(!SheetTitleLabel.fits("Save your Example Shop login?", font: font, width: 160, lines: 2))
        let label = SheetTitleLabel(frame: CGRect(x: 0, y: 0, width: 190, height: 52))
        label.text = "OPENWEATHER_API_KEY"
        #expect(label.numberOfLines == 1)
        label.layoutIfNeeded()
        label.setNeedsLayout()
        label.layoutIfNeeded()
        let width = ("OPENWEATHER_API_KEY" as NSString).size(withAttributes: [.font: label.font!]).width
        let floor = max(12, SheetTitleLabel.baseFont(for: label.traitCollection).pointSize * 0.6)
        #expect(width <= 190 || label.font.pointSize <= floor + 0.01)            // whole on one line (or at its floor)
        #expect(label.font.pointSize < SheetTitleLabel.baseFont(for: label.traitCollection).pointSize)
        label.text = "Save your Example Shop login?"
        #expect(label.numberOfLines == 2)
    }

    // MARK: HTML Preview

    @Test func aPageWithoutAViewportPreviewsAtThePhonesWidth() throws {
        let page = Data("<html><head><title>Notes</title></head><body><h1>2.4</h1></body></html>".utf8)
        let fitted = try #require(ArtifactFiles.previewHTML(page))
        let html = String(decoding: fitted, as: UTF8.self)
        #expect(html.contains(#"<head><meta name="viewport" content="width=device-width, initial-scale=1"><title>"#))
        #expect(ArtifactFiles.previewHTML(Data(#"<html><head><meta name="viewport" content="width=600"></head></html>"#.utf8)) == nil)
        let bare = try #require(ArtifactFiles.previewHTML(Data("<p>Export, faster sync.</p>".utf8)))
        #expect(String(decoding: bare, as: UTF8.self).hasPrefix(#"<meta name="viewport""#))
        let url = URL(fileURLWithPath: "/tmp/previews/abc/index.html")
        #expect(ArtifactFiles.previewCopyURL(for: url).path == "/tmp/previews/abc/preview-index.html")
    }

    // MARK: Glides pause through a hitch instead of jumping

    @Test func aGlideClockPausesThroughAHitchInsteadOfSkipping() {
        var clock = GlideClock.started(10)
        #expect(abs(clock.tick(10.016) - 0.016) < 1e-9)
        #expect(abs(clock.tick(10.056) - 0.056) < 1e-9)                          // a long (40 ms) frame counts in full
        #expect(abs(clock.tick(10.300) - (0.056 + GlideClock.pausedFrame)) < 1e-9) // a 244 ms hitch counts as one frame
        #expect(abs(clock.peek(10.310) - (0.056 + GlideClock.pausedFrame + 0.010)) < 1e-9)
    }
}
