import Foundation
import Testing
import UIKit
@testable import HermesHQNative

/// [offline] Which unexpected errors stop startup (docs/spec/3x-offline.md §3.4): `connection-startup.test.ts` 393–405.
@Suite struct StartupProblemsTests {
    struct Odd: Error {}

    @Test func endStartupOnlyWhileTheAppIsBeingStarted() {
        #expect(StartupProblems.isFatal(phase: .booting, error: Odd()))
        #expect(StartupProblems.isFatal(phase: .signingIn, error: Odd()))
        #expect(!StartupProblems.isFatal(phase: .mounted, error: Odd()))
        #expect(!StartupProblems.isFatal(phase: .offline, error: Odd()))
    }

    @Test func aStorageFailureIsAlwaysShownBeforeTheAppIsOnScreen() {
        let storage = AccountStorageError(path: "lists")
        #expect(StartupProblems.isFatal(phase: .booting, error: storage))
        #expect(StartupProblems.isFatal(phase: .signingIn, error: storage))
        #expect(StartupProblems.isFatal(phase: .offline, error: storage))
        #expect(!StartupProblems.isFatal(phase: .mounted, error: storage))
        #expect(StartupProblems.message(for: storage) == StartupProblems.storage)
        #expect(storage.errorDescription == StartupProblems.storage)
        #expect(StartupProblems.message(for: Odd()) == StartupProblems.couldNotStart)
    }

    @Test func gatewayAndSignInFailuresAndCancelsAreNeverStray() {
        let own: [any Error] = [GatewayFailure.offline, RPCError(code: -32000, message: "no"), HTTPError(status: 500, body: nil),
                                CancellationError(), URLError(.cancelled), RetryLater(failure: .offline, after: 3)]
        for error in own {
            #expect(!StartupProblems.isFatal(phase: .booting, error: error), "\(error)")
            #expect(!StartupProblems.isFatal(phase: .signingIn, error: error), "\(error)")
        }
    }

    @Test func theSentencesArePlain() {
        for text in [StartupProblems.storage, StartupProblems.couldNotStart] {
            #expect(!text.contains("Dispatch") && !text.contains("Error") && text.hasSuffix("."))
        }
    }

    @Test func theLastGatewayHintRoundTripsAndHoldsNothingSecret() throws {
        let defaults = try #require(UserDefaults(suiteName: "offline-hint-\(UUID().uuidString)"))
        #expect(LastGatewayHint.load(defaults) == nil)
        let hint = LastGatewayHint(url: "https://mac.example:8642", accountName: "ivy", label: "Studio", username: "ivy")
        hint.save(defaults)
        #expect(LastGatewayHint.load(defaults) == hint)
        let stored = String(data: defaults.data(forKey: LastGatewayHint.key) ?? Data(), encoding: .utf8) ?? ""
        #expect(!stored.lowercased().contains("password") && !stored.lowercased().contains("token") && !stored.lowercased().contains("cookie"))
        LastGatewayHint.clear(defaults)
        #expect(LastGatewayHint.load(defaults) == nil)
    }
}

/// [offline] This phone's saved app data must open for the account (§3.4).
@Suite struct AccountStorageTests {
    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "offline-storage-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test func makesTheFoldersAndLeavesNoProbeBehind() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let roots = [root.appending(path: "lists"), root.appending(path: "deep/queues")]
        var failure: AccountStorageError?
        do throws(AccountStorageError) { try AccountStorage.check(roots: roots) } catch { failure = error }
        #expect(failure == nil)
        for folder in roots {
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            #expect(names.isEmpty, "the probe file is removed: \(names)")
        }
    }

    @Test func aFolderThatCannotBeMadeIsNamed() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // A file stands where the folder should be.
        let blocked = root.appending(path: "lists")
        try Data([1]).write(to: blocked)
        var failure: AccountStorageError?
        do throws(AccountStorageError) { try AccountStorage.check(roots: [root.appending(path: "ok"), blocked]) } catch { failure = error }
        #expect(failure == AccountStorageError(path: "lists"))
        #expect(try Data(contentsOf: blocked) == Data([1]), "what was there is not touched")
    }

    @Test func aReadOnlyFolderFails() throws {
        let root = scratch()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        var failure: AccountStorageError?
        do throws(AccountStorageError) { try AccountStorage.check(roots: [root]) } catch { failure = error }
        #expect(failure != nil)
    }
}

/// [offline] The Bots list's words for slow, stale and failed (§4): `roster-states` and `roster-empty`.
@Suite struct RosterStateCopyTests {
    @Test func staleCardWords() {
        let midnight: TimeInterval = 1_759_968_000           // 2025-10-09 00:00 UTC
        let nine41 = Date(timeIntervalSince1970: midnight + 9 * 3600 + 41 * 60)
        let utc = TimeZone(identifier: "UTC")!, us = Locale(identifier: "en_US")
        let plain = RosterStateCopy.stale(waiting: false, updated: nine41, locale: us, timeZone: utc)
        #expect(plain.hasPrefix("Can’t refresh bots. Showing the list from 9:41"), "\(plain)")
        #expect(plain.hasSuffix("."))
        let waiting = RosterStateCopy.stale(waiting: true, updated: nine41, locale: us, timeZone: utc)
        #expect(waiting.hasPrefix("Waiting for your gateway. Showing the list from 9:41"))
        #expect(RosterStateCopy.stale(waiting: false, updated: nil) == "Can’t refresh bots. Showing the last list.")
        #expect(RosterStateCopy.stale(waiting: true, updated: nil) == "Waiting for your gateway. Showing the last list.")
    }

    @Test func cantLoadReasonInOrder() {
        #expect(RosterStateCopy.cantLoadReason(connected: false, busy: true, words: "x y z w") == RosterStateCopy.waitingReason)
        #expect(RosterStateCopy.cantLoadReason(connected: true, busy: true, words: "x y z w") == RosterStateCopy.busyReason)
        #expect(RosterStateCopy.cantLoadReason(connected: true, busy: false, words: "The profile store is locked.") == "The profile store is locked.")
        #expect(RosterStateCopy.cantLoadReason(connected: true, busy: false, words: nil) == "The gateway didn’t answer.")
    }

    @Test func aRawCodeIsNeverShown() {
        for raw in ["HTTP 502", "RPC -32000: boom", "Error Domain=NSURLErrorDomain Code=-1004", "Traceback (most recent call last)",
                    "{\"detail\":\"x\"}", "<html>Bad Gateway</html>", "0x7ff0 fault", "failed with 500 status", "ok", "timeout",
                    String(repeating: "long words ", count: 30)] {
            #expect(RosterStateCopy.plain(raw) == nil, "\(raw)")
        }
        #expect(RosterStateCopy.plain("  The profile store is locked.  ") == "The profile store is locked.")
    }

    @Test func wordsForErrors() {
        struct Odd: Error {}
        #expect(RosterStateCopy.words(for: Odd()) == nil)
        #expect(RosterStateCopy.words(for: HTTPError(status: 502, body: "Bad Gateway")) == nil)
        #expect(RosterStateCopy.words(for: RPCError(code: -32000, message: "The profile store is locked.")) == "The profile store is locked.")
        // Stress round 1: the gateway's own message is shown only when it is a sentence; otherwise the app's words.
        #expect(RosterStateCopy.words(for: RPCError(code: -32000, message: "KeyError: 'profiles' at 0x1")) == RosterStateCopy.answeredReason)
        #expect(RosterStateCopy.words(for: RPCError(code: -32000, message: "the stand-in was told to fail this")) == "Your gateway couldn’t load your bots.")
        #expect(RosterStateCopy.words(for: RPCError(code: -32000, message: "session not found")) == RosterStateCopy.answeredReason)
        #expect(RosterStateCopy.words(for: RPCError(code: -32000, message: "<script>alert(1)</script> Hello there.")) == RosterStateCopy.answeredReason)
        let failure = RosterStateCopy.words(for: GatewayFailure.offline)
        #expect(failure == nil || failure?.contains(" ") == true)
        #expect(RosterStateCopy.skeletonRows == 5 && RosterStateCopy.slowSkeletonRows == 3 && RosterStateCopy.slowAfter == 15)
        #expect(RosterStateCopy.slowLoad == "Still loading your bots… Your gateway is taking longer than usual.")
        #expect(RosterStateCopy.slowPage == "Still loading… Your gateway is taking longer than usual.")
        #expect(RosterStateCopy.cantLoadTitle == "Couldn’t Load Bots")
    }
}

/// [offline] One sidebar refresh shared by the reconnect's callers (§6.4).
@Suite struct ReconnectShareTests {
    nonisolated final class Now: @unchecked Sendable { nonisolated(unsafe) var time: TimeInterval = 100 }

    @Test func aSecondCallerInsideThreeSecondsJoins() {
        let now = Now()
        var share = ReconnectShare(now: { now.time })
        let first = share.begin()
        now.time += 1
        let second = share.begin()
        now.time += 1.9
        let third = share.begin()
        #expect(first && !second && !third)
        now.time += 0.2            // 3.1 s after the first
        let fourth = share.begin()
        #expect(fourth, "outside the window: its own read")
    }

    @Test func aFailedReadIsNotShared() {
        let now = Now()
        var share = ReconnectShare(now: { now.time })
        _ = share.begin()
        share.failed()
        now.time += 0.5
        let retry = share.begin()
        #expect(retry, "the next caller reads for itself")
        now.time += 0.5
        let joined = share.begin()
        #expect(!joined, "and that one is shared again")
    }
}

extension ReconnectShareTests {
    /// (review) The read that covered a reconnect was one already in flight and it failed, or it was cancelled: the
    /// store hands the share back (`SessionStore.performRead` calls `failed()` on every ending that is not a list or an
    /// unchanged probe), so a socket that opens again inside the 3 s reads for itself.
    @Test func aCoveringReadThatFailsGivesTheShareBack() {
        let now = Now()
        var share = ReconnectShare(now: { now.time })
        let first = share.begin()
        now.time += 0.4            // the read in flight fails
        share.failed()
        now.time += 0.4
        let second = share.begin()
        #expect(first && second, "inside 3 s, but the first refresh never landed")
        share.failed()             // cancelled this time
        share.failed()             // told twice: no harm
        now.time += 2.9
        let third = share.begin()
        #expect(third)
    }
}

/// [offline] The second half of the stale work check (§6.6): background-process claims against `agents.list`.
@Suite struct StaleWorkTests {
    @Test func runningProcessesFromAnAnswer() {
        let answer: JSONValue = ["processes": [["session_id": "p1", "status": "running"], ["session_id": "p2", "status": "exited"],
                                               ["session_id": "", "status": "running"], ["status": "running"], "junk", 4]]
        #expect(StaleWork.runningProcesses(answer) == ["p1"])
        #expect(StaleWork.runningProcesses(["processes": []]) == [])
    }

    @Test func aMalformedAnswerDropsNothing() {
        #expect(StaleWork.runningProcesses(nil) == nil)
        #expect(StaleWork.runningProcesses([:]) == nil)
        #expect(StaleWork.runningProcesses(["processes": "nope"]) == nil)
        #expect(StaleWork.runningProcesses(["processes": nil]) == nil)
        #expect(StaleWork.runningProcesses("text") == nil)
    }

    @Test func tenThousandRowsAreRead() {
        let rows: [JSONValue] = (0..<10_000).map { ["session_id": .string("p\($0)"), "status": .string($0 % 2 == 0 ? "running" : "done")] }
        #expect(StaleWork.runningProcesses(["processes": .array(rows)])?.count == 5_000)
    }

    @Test func claimsNoLongerRunningAreDropped() {
        let claims = [ProcessClaim(id: "p1", running: true), ProcessClaim(id: "p2", running: true), ProcessClaim(id: "p3", running: false)]
        #expect(StaleWork.dropProcesses(claims: claims, running: ["p1", "p2"]) == nil, "nothing changed")
        #expect(StaleWork.dropProcesses(claims: claims, running: ["p2"]) == [ProcessClaim(id: "p2", running: true), ProcessClaim(id: "p3", running: false)])
        #expect(StaleWork.dropProcesses(claims: claims, running: []) == [ProcessClaim(id: "p3", running: false)])
        #expect(StaleWork.claimsRunning(claims))
        #expect(!StaleWork.claimsRunning([ProcessClaim(id: "p3", running: false)]))
        #expect(!StaleWork.claimsRunning([]))
    }
}

/// [offline] A reply cut off by a restart is completed from the saved chat (§6.3).
@MainActor @Suite struct TailRecheckTests {
    typealias Clock = ReadFlightTests.FakeClock

    private func message(_ role: ChatMessage.Role, _ text: String, _ row: Int) -> ChatMessage {
        ChatMessage(id: "stored-row-\(row)-\(role)", role: role, parts: [.text(text)], timestamp: nil, rowId: row)
    }

    private func rows(_ pairs: [(String, String)]) -> [JSONValue] {
        pairs.map { ["role": .string($0.0), "content": .string($0.1)] }
    }

    @Test func whatIsOnShowIsTheLastPromptAndTheReplyAfterIt() {
        let shown = TailRecheck.shown([message(.user, "First", 1), message(.assistant, "One", 2), message(.user, "Second", 3),
                                       message(.assistant, "Half a re", 4)])
        #expect(shown == TailRecheck.Shown(prompt: "Second", reply: 9))
        #expect(TailRecheck.shown([]) == TailRecheck.Shown(prompt: "", reply: 0))
        #expect(TailRecheck.shown([message(.user, "Only a prompt", 1)]) == TailRecheck.Shown(prompt: "Only a prompt", reply: 0))
    }

    @Test func theSavedReplyMustBeForTheSamePromptAndAtLeastAsLong() {
        let shown = TailRecheck.Shown(prompt: "Tell me  more", reply: 9)
        #expect(TailRecheck.savedReplyCovers(rows([("user", "Tell me more"), ("assistant", "Half a reply, now whole.")]), shown))
        #expect(TailRecheck.savedReplyCovers(rows([("user", "Tell me\nmore"), ("assistant", "123456789")]), shown), "equal length counts")
        #expect(!TailRecheck.savedReplyCovers(rows([("user", "Tell me more"), ("assistant", "Shorter")]), shown), "never something shorter")
        #expect(!TailRecheck.savedReplyCovers(rows([("user", "Another prompt"), ("assistant", "A long reply to something else.")]), shown),
                "never another turn's reply")
        #expect(!TailRecheck.savedReplyCovers(rows([("user", "Tell me more")]), TailRecheck.Shown(prompt: "Tell me more", reply: 1)))
        #expect(!TailRecheck.savedReplyCovers([], shown))
        #expect(!TailRecheck.savedReplyCovers(rows([("assistant", "No prompt at all, but long enough.")]), shown))
    }

    @Test func rowsInAWrongOrderDoNotCount() {
        // The reply saved before its prompt (a broken order) is not "after the prompt".
        let shown = TailRecheck.Shown(prompt: "Tell me more", reply: 9)
        #expect(!TailRecheck.savedReplyCovers(rows([("assistant", "A long reply that is whole."), ("user", "Tell me more")]), shown))
    }

    @Test func contentPartsAreRead() {
        let row: JSONValue = ["role": "assistant", "content": [["type": "text", "text": "Half "], ["type": "text", "text": "and half"]]]
        #expect(TailRecheck.rowText(row) == "Half and half")
        #expect(TailRecheck.rowText(["role": "assistant"]) == "")
        #expect(TailRecheck.rowText(["content": 4]) == "")
    }

    final class Probe {
        var owed = true
        var saved: [JSONValue] = []
        var fails = false
        var resumes = 0
    }

    private func series(_ probe: Probe, clock: Clock) -> TailRecheckSeries {
        TailRecheckSeries(clock: clock, owed: { probe.owed }, read: {
            if probe.fails { throw URLError(.timedOut) }
            return probe.saved
        }, resume: { probe.resumes += 1 })
    }

    @Test func readsOnTheLadderUntilTheSavedReplyCoversThenResumesOnce() async {
        let clock = Clock(), probe = Probe()
        let recheck = series(probe, clock: clock)
        let shown = TailRecheck.Shown(prompt: "Tell me more", reply: 200)
        recheck.settled(partial: true, running: false, shown: shown)
        #expect(recheck.isActive && recheck.reads == 0)
        await clock.advance(1.9)
        #expect(recheck.reads == 0)
        await clock.advance(0.2)                      // 2 s
        #expect(recheck.reads == 1 && probe.resumes == 0)
        await clock.advance(5)                        // + 5 s
        #expect(recheck.reads == 2)
        probe.saved = rows([("user", "Tell me more"), ("assistant", String(repeating: "x", count: 600))])
        await clock.advance(10)                       // + 10 s
        #expect(recheck.reads == 3 && probe.resumes == 1)
        // The resume shows the whole reply: the series ends.
        recheck.settled(partial: false, running: false, shown: TailRecheck.Shown(prompt: "Tell me more", reply: 600))
        #expect(!recheck.isActive)
        await clock.advance(600)
        #expect(recheck.reads == 3 && probe.resumes == 1, "no loop")
    }

    /// [perf] Only a series that just started over has its 2 s read pending (the reconnect then skips its own probe).
    @Test func theFirstStepIsPendingOnlyRightAfterAStart() async {
        let clock = Clock(), probe = Probe()
        let recheck = series(probe, clock: clock)
        #expect(!recheck.firstStepPending)
        let shown = TailRecheck.Shown(prompt: "Tell me more", reply: 200)
        recheck.settled(partial: true, running: false, shown: shown)
        #expect(recheck.firstStepPending)
        await clock.advance(2)
        #expect(recheck.reads == 1 && !recheck.firstStepPending, "the 5 s step is next")
        recheck.settled(partial: true, running: false, shown: shown)            // another reconnect starts it over
        #expect(recheck.firstStepPending)
        recheck.cancel()
        #expect(!recheck.firstStepPending)
    }

    /// (review) A prompt the gateway saves with more around it than the phone shows, and a reply whose saved form lost
    /// its trailing white space, still match.
    @Test func aPromptWithAnAttachmentNoteAndAReplyWithTrailingWhiteSpaceMatch() {
        let reply = "Here is what the picture shows.   \n\n"
        let shown = TailRecheck.shown([message(.user, "What is in this picture?", 1),
                                       ChatMessage(id: "local", role: .assistant, parts: [.text(reply)], timestamp: nil, rowId: nil)])
        #expect(shown.reply == "Here is what the picture shows.".count, "white space is evened out before counting")
        let saved = rows([("user", "[The user attached an image: photo.jpg]\n\nWhat is in this picture?"),
                          ("assistant", "Here is what the picture shows.")])
        #expect(TailRecheck.savedReply(saved, shown) == .covers)
        // The other way round: the phone shows a note the gateway does not keep.
        #expect(TailRecheck.samePrompt(saved: "What is in this picture?", shown: "photo.jpg What is in this picture?"))
        #expect(!TailRecheck.samePrompt(saved: "Another question", shown: "What is in this picture?"))
        #expect(!TailRecheck.samePrompt(saved: "", shown: "What is in this picture?"), "an empty row is not every prompt")
        // Up to 2% shorter counts (text kept in a part that is not text); clearly shorter does not.
        let long = TailRecheck.Shown(prompt: "p", reply: 1_000)
        #expect(TailRecheck.savedReply(rows([("user", "p"), ("assistant", String(repeating: "x", count: 981))]), long) == .covers)
        #expect(TailRecheck.savedReply(rows([("user", "p"), ("assistant", String(repeating: "x", count: 900))]), long) == .shorter)
        #expect(TailRecheck.savedReply(rows([("user", "p")]), long) == .nothing)
    }

    /// (review) A saved reply that stays shorter than the one shown ends the reading after two looks, and resumes that
    /// settle on the same turn again start nothing.
    @Test func aSavedReplyThatStaysShorterEndsTheSeriesAfterTwoReads() async {
        let clock = Clock(), probe = Probe()
        let recheck = series(probe, clock: clock)
        let shown = TailRecheck.Shown(prompt: "Tell me more", reply: 400)
        probe.saved = rows([("user", "Tell me more"), ("assistant", String(repeating: "x", count: 120))])
        recheck.settled(partial: true, running: false, shown: shown)
        await clock.advance(2)
        #expect(recheck.reads == 1 && recheck.isActive)
        await clock.advance(5)
        #expect(recheck.reads == 2 && !recheck.isActive && probe.resumes == 0, "two looks, then what is shown stays")
        await clock.advance(1_000)
        #expect(recheck.reads == 2)
        // Reconnects and reopenings of that chat settle on the same turn: no new series.
        for _ in 0..<5 { recheck.settled(partial: true, running: false, shown: shown) }
        await clock.advance(1_000)
        #expect(recheck.reads == 2 && !recheck.isActive)
        // More of the reply on show than before (a later reconnect brought more): worth reading again.
        recheck.settled(partial: true, running: false, shown: TailRecheck.Shown(prompt: "Tell me more", reply: 900))
        #expect(recheck.isActive)
        recheck.cancel()
        // Another turn: a series of its own.
        recheck.settled(partial: true, running: false, shown: TailRecheck.Shown(prompt: "Next question", reply: 10))
        #expect(recheck.isActive)
    }

    /// Nothing saved for the turn yet on one look, shorter on the next, nothing again: never two in a row, so the
    /// ladder runs on.
    @Test func shorterReadsMustBeConsecutive() async {
        let clock = Clock(), probe = Probe()
        let recheck = series(probe, clock: clock)
        let short = rows([("user", "p"), ("assistant", "x")])
        recheck.settled(partial: true, running: false, shown: TailRecheck.Shown(prompt: "p", reply: 50))
        probe.saved = short
        await clock.advance(2)
        probe.saved = rows([("user", "p")])
        await clock.advance(5)
        probe.saved = short
        await clock.advance(10)
        #expect(recheck.reads == 3 && recheck.isActive)
        await clock.advance(20)
        #expect(recheck.reads == 4 && !recheck.isActive)
    }

    @Test func stopsAfterTheLadderWithoutAResume() async {
        let clock = Clock(), probe = Probe()
        let recheck = series(probe, clock: clock)
        recheck.settled(partial: true, running: false, shown: TailRecheck.Shown(prompt: "p", reply: 50))
        await clock.advance(TailRecheck.ladder.reduce(0, +) + 1)
        #expect(recheck.reads == TailRecheck.ladder.count)
        #expect(!recheck.isActive && probe.resumes == 0)
        await clock.advance(1_000)
        #expect(recheck.reads == TailRecheck.ladder.count)
    }

    @Test func aFailedReadIsJustTheNextRung() async {
        let clock = Clock(), probe = Probe()
        let recheck = series(probe, clock: clock)
        probe.fails = true
        recheck.settled(partial: true, running: false, shown: TailRecheck.Shown(prompt: "p", reply: 5))
        await clock.advance(2)
        #expect(recheck.reads == 1 && recheck.isActive)
        probe.fails = false
        probe.saved = rows([("user", "p"), ("assistant", "whole reply")])
        await clock.advance(5)
        #expect(recheck.reads == 2 && probe.resumes == 1)
    }

    @Test func aRunningTurnOrALeftChatCancels() async {
        let clock = Clock(), probe = Probe()
        let recheck = series(probe, clock: clock)
        recheck.settled(partial: true, running: false, shown: TailRecheck.Shown(prompt: "p", reply: 5))
        recheck.settled(partial: true, running: true, shown: TailRecheck.Shown(prompt: "p", reply: 5))
        #expect(!recheck.isActive)
        await clock.advance(200)
        #expect(recheck.reads == 0, "the turn is live again: events finish it")
        recheck.settled(partial: true, running: false, shown: TailRecheck.Shown(prompt: "p", reply: 5))
        probe.owed = false                            // the chat was left, or a newer turn began
        await clock.advance(2)
        #expect(recheck.reads == 0 && !recheck.isActive)
    }

    @Test func aResumeThatStillShowsThePartialKeepsItsPlaceOnTheLadder() async {
        let clock = Clock(), probe = Probe()
        let recheck = series(probe, clock: clock)
        let shown = TailRecheck.Shown(prompt: "p", reply: 5)
        probe.saved = rows([("user", "p"), ("assistant", "whole reply")])
        recheck.settled(partial: true, running: false, shown: shown)
        await clock.advance(2)
        #expect(probe.resumes == 1)
        // The resume came back partial again (the gateway had not caught up): the next read is the next rung, not rung one.
        probe.saved = []
        recheck.settled(partial: true, running: false, shown: shown)
        await clock.advance(4.9)
        #expect(recheck.reads == 1)
        await clock.advance(0.2)
        #expect(recheck.reads == 2)
    }

    @Test func theLongestPartialSeenIsTheBar() async {
        let clock = Clock(), probe = Probe()
        let recheck = series(probe, clock: clock)
        recheck.settled(partial: true, running: false, shown: TailRecheck.Shown(prompt: "p", reply: 40))
        recheck.settled(partial: true, running: false, shown: TailRecheck.Shown(prompt: "p", reply: 10))   // a shorter snapshot
        probe.saved = rows([("user", "p"), ("assistant", String(repeating: "x", count: 20))])
        await clock.advance(2)
        #expect(probe.resumes == 0, "20 saved characters do not replace 40 seen")
        probe.saved = rows([("user", "p"), ("assistant", String(repeating: "x", count: 40))])
        await clock.advance(5)
        #expect(probe.resumes == 1)
    }
}

/// [offline] §3.3: the system launch screen's colour is the page colour in both appearances, so the first app frame
/// lands on the same pixels.
@MainActor @Suite struct LaunchAppearanceTests {
    private func rgb(_ color: UIColor, _ style: UIUserInterfaceStyle) -> [Int] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style)).getRed(&r, green: &g, blue: &b, alpha: &a)
        return [Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()), Int((a * 255).rounded())]
    }

    @Test func theLaunchBackgroundAssetIsThePageColour() throws {
        let asset = try #require(UIColor(named: "LaunchBackground", in: Bundle(for: AppModel.self), compatibleWith: nil))
        #expect(rgb(asset, .light) == rgb(HQPalette.page, .light))
        #expect(rgb(asset, .dark) == rgb(HQPalette.page, .dark))
        #expect(rgb(asset, .light) == [0xFE, 0xFE, 0xFE, 255])
        #expect(rgb(asset, .dark) == [0x0D, 0x10, 0x15, 255])
    }

    @Test func theLaunchScreenIsDeclaredWithTheAssets() throws {
        let bundle = Bundle(for: AppModel.self)
        let launch = try #require(bundle.object(forInfoDictionaryKey: "UILaunchScreen") as? [String: Any])
        #expect(launch["UIColorName"] as? String == "LaunchBackground")
        // No picture: it couldn't follow the icon picked in Settings › App Icon (LaunchViewController draws that).
        #expect(launch["UIImageName"] == nil)
        #expect(UIImage(named: "LaunchIcon", in: bundle, compatibleWith: nil) != nil)
    }

    @Test func theLaunchScreenDrawsTheIconWhereTheSystemDrewIt() {
        let screen = LaunchViewController()
        screen.loadViewIfNeeded()
        screen.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        screen.view.layoutIfNeeded()
        #expect(screen.view.backgroundColor == HQPalette.page)
        #expect(LaunchViewController.iconSide == 96)
        #if DEBUG
        let icon = screen.iconFrame
        #expect(abs(icon.midX - 201) < 0.6 && abs(icon.midY - 437) < 0.6, "centred in the bounds, not the safe area: \(icon)")
        #expect(abs(icon.width - 96) < 0.6 && abs(icon.height - 96) < 0.6)
        #endif
    }
}

// MARK: - Stress round 1 repairs

@MainActor @Suite(.serialized) struct StressRoundOneRepairTests {
    /// A roster load that failed while the gateway was away is out of date once the socket opens, until the read
    /// that follows the open has answered: the launch screen covers that read (no "Couldn’t Load Bots" flash).
    @Test func aFailureFromBeforeTheSocketOpenedIsOutOfDate() async throws {
        let client = BotsFakeGatewayClient()
        client.on("profiles.list") { _ in throw RPCError(code: 5061, message: "boom", data: nil) }
        let store = BotStore(client: client, account: .botsTestAccount, cacheDirectory: BotsTest.tempDirectory(), timing: .fast, autoStart: true)
        #expect(await BotsTest.waitUntil { if case .failed = store.loadState { return true } else { return false } })
        client.setState(.offline(reason: GatewayFailure.unreachable.code))
        try await Task.sleep(for: .milliseconds(150))
        #expect(store.failurePredatesOpen, "no socket: the failure says nothing about the next one")
        let reads = client.calls("profiles.list").count
        client.setState(.ready)
        #expect(store.failurePredatesOpen, "the socket has just opened: still the old failure")
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.failurePredatesOpen, "seen by the store: still the old failure")
        // The read that follows the open fails too: that failure is this gateway's own answer and is shown.
        client.emit("gateway.ready")
        // (While that read is out the store says "loading", which the launch screen covers by its own rule.)
        #expect(await BotsTest.waitUntil {
            guard case .failed = store.loadState else { return false }
            return client.calls("profiles.list").count > reads && !store.failurePredatesOpen
        }, "the new failure is shown: \(store.loadState)")
        // And a load that worked is never "out of date".
        let fine = BotsFakeGatewayClient()
        let full = try BotsFixture.json("demo-profiles-list")
        fine.on("profiles.list") { _ in full }
        let good = BotStore(client: fine, account: .botsTestAccount, cacheDirectory: BotsTest.tempDirectory(), timing: .fast, autoStart: true)
        #expect(await BotsTest.waitUntil { good.phase == .full })
        #expect(!good.failurePredatesOpen)
        store.stop(); good.stop()
    }

    /// The reconnect notice's type stops growing at the first accessibility size and its sentence is never cut.
    @Test func theNoticeIsNeverCutAndStopsGrowing() {
        let largest = ConnectionBanner.BannerView.font(at: .accessibilityExtraExtraExtraLarge)
        let cap = ConnectionBanner.BannerView.font(at: .accessibilityMedium)
        #expect(largest.pointSize == cap.pointSize)
        #expect(ConnectionBanner.BannerView.font(at: .large).pointSize < cap.pointSize, "below the cap it follows the text size")
        let banner = ConnectionBanner.BannerView()
        let longest = "Can’t reach the computer running Hermes. Check your network or VPN connection. Hermes HQ keeps trying."
        banner.fill(longest)
        let width: CGFloat = 378
        let height = banner.height(for: width)
        banner.frame = CGRect(x: 0, y: 0, width: width, height: height)
        banner.layoutIfNeeded()
        let label = banner.subviews.flatMap { all($0) }.compactMap { $0 as? UILabel }.first
        #expect(label?.numberOfLines == 0, "no line limit")
        if let label {
            let needed = label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude)).height
            #expect(label.bounds.height >= needed - 0.5, "the whole sentence fits: \(label.bounds.height) of \(needed)")
        }
        #expect(height < 220, "a notice, not a wall: \(height)")
    }

    /// Mac stress #45: the ✕ is the Mac's alone. On a phone the notice has none and takes no touch at all (the bar's
    /// buttons under it work through it).
    @Test func theNoticeHasNoCloseButtonOnAPhone() {
        let banner = ConnectionBanner.BannerView()
        banner.fill("Reconnecting…")
        #expect(banner.close == nil)
        #expect(!banner.isUserInteractionEnabled)
        banner.frame = CGRect(x: 0, y: 0, width: 378, height: banner.height(for: 378))
        #expect(banner.hitTest(CGPoint(x: 360, y: 20), with: nil) == nil)
    }

    private func all(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap { all($0) } }

    /// A `Retry-After` holds a reconnect for two minutes at most, before and after the first ready.
    @Test func retryAfterIsCappedAtTwoMinutesEverywhere() {
        #expect(RetryLater.ceiling == 120 && RetryLater.ceiling == RetryLadder.ceiling)
    }

    /// Try Again is off while an attempt runs; the model never turns the other buttons off.
    @Test func onlyTryAgainWaitsForAnAttempt() {
        let model = OfflineScreenModel()
        model.url = URL(string: "http://gateway.test:9119")
        model.setStatus(due: nil, connecting: true)
        #expect(!model.tryAgainEnabled && model.showsDifferentGateway)
    }
}
