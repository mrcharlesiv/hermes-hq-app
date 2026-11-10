// What happens after a shortcut asked for a voice note, run against a stand-in app (docs/spec/3x-intents.md §13 A13,
// A25–A27; the quick-action routes of §9.4; stress S1, S2, S19, S20, and S23's unanswered alert). The delivery cases
// are the web app's (W:src/action-voice-runtime.test.ts), run against the native port.

import Foundation
import Testing
@testable import HermesHQNative

private let ivyKey = "ios-direct::ivy"
private let defaultKey = "ios-direct::default"

@Suite struct VoiceNoteDeliveryTests {
    // A13
    @Test func opensTheBotsOwnChatAndStartsTheMemoThere() async {
        let rig = IntentsRig()
        let request = rig.request("ivy")
        await rig.runtime.deliver()
        #expect(rig.host.opens == ["ivy"])
        #expect(rig.host.memos == [ivyKey])
        #expect(rig.store.pending == nil, "acknowledged")
        #expect(rig.events == ["deliver begin", "open ivy", "memo started ivy", "ack " + request.id, "deliver end"])
        #expect(rig.host.notices.isEmpty && rig.runtime.started == [request.id] && !rig.runtime.busy)
    }

    // The Action Button on an app that was not running: the kick comes while the scene is in front but the app does
    // not count as active yet. The request is delivered when it does, not on some later foreground.
    @Test func aKickBeforeTheAppIsActiveWaitsForIt() async {
        let rig = IntentsRig()
        rig.host.isActive = false
        rig.host.foreground = true
        let start = rig.host.clock
        rig.host.onSleep = { [host = rig.host] in if host.clock >= start + 300 { host.isActive = true } }
        let request = rig.request("ivy")
        async let first: Void = rig.runtime.deliver()
        await rig.runtime.deliver()                                  // a second kick meanwhile does not wait as well
        await first
        await rig.settle()
        #expect(rig.host.memos == [ivyKey], "recorded once the app was active: \(rig.events)")
        #expect(rig.store.pending == nil && rig.runtime.started == [request.id])
        #expect(rig.host.clock - start < 1000, "about 300 ms later, not at the end of the wait")
        #expect(rig.runtime.deliveries == 1)
    }

    @Test func aKickInTheBackgroundDoesNotWait() async {
        let rig = IntentsRig()
        rig.host.isActive = false
        rig.host.foreground = false
        let start = rig.host.clock
        rig.request("ivy")
        await rig.runtime.deliver()
        #expect(rig.host.clock == start && rig.host.opens.isEmpty && rig.store.pending != nil, "left for the next foreground")
        // In front but never active (an alert of the system's over the app): 2 s, then left alone.
        rig.host.foreground = true
        await rig.runtime.deliver()
        #expect(rig.host.clock == start + 2000 && rig.host.opens.isEmpty && rig.store.pending != nil && !rig.runtime.busy)
    }

    // A cold launch the system ran the shortcut on after the scene connected: reopening the last chat is called off.
    @Test func aRequestCallsOffReopeningTheLastChat() async {
        let rig = IntentsRig()
        await rig.runtime.deliver()
        #expect(rig.host.restoreCancels == 0, "nothing waits: the last chat may come back")
        rig.saveNote("ivy")
        await rig.runtime.deliver()
        #expect(rig.host.restoreCancels == 0, "a saved note alone does not call it off")
        rig.host.isActive = false
        rig.host.foreground = false
        rig.request("ivy")
        await rig.runtime.deliver()
        #expect(rig.host.restoreCancels == 1, "called off as soon as the request is seen, before the app is active")
    }

    // S28: signing out while the roster is being read for a request. Nothing opens, records or is said afterwards.
    @Test func signingOutWhileARequestIsBeingDeliveredSaysNothing() async {
        let rig = IntentsRig()
        rig.host.roster = [IntentsFixture.bot("default")]
        rig.host.refreshed = [IntentsFixture.bot("default"), IntentsFixture.bot("ivy")]
        rig.host.onRefresh = { [rig] in
            rig.runtime.reset()                        // what sign-out does
            rig.host.account = nil
        }
        rig.request("ivy")
        await rig.runtime.deliver()
        await rig.settle()
        #expect(rig.host.refreshes == 1)
        #expect(rig.host.opens.isEmpty && rig.host.memos.isEmpty, "nothing opened or recorded")
        #expect(rig.host.notices.isEmpty, "and nobody was told: \(rig.host.messages)")
        #expect(rig.store.pending == nil && !rig.runtime.busy)
        // Signed in again inside the minute: the request is gone, nothing records.
        rig.host.account = IntentsFixture.account
        await rig.runtime.deliver()
        #expect(rig.host.memos.isEmpty && rig.host.notices.isEmpty)
    }

    @Test func nothingHappensWhileTheAppIsNotOnScreenAndTheRequestWaits() async {
        let rig = IntentsRig()
        rig.host.isActive = false
        let request = rig.request("ivy")
        await rig.runtime.deliver()
        #expect(rig.host.opens.isEmpty && rig.store.pending == request && rig.events.isEmpty)
        rig.host.isActive = true
        await rig.runtime.deliver()
        #expect(rig.host.memos == [ivyKey] && rig.store.pending == nil)
    }

    @Test func aColdLaunchWaitsForSignInToBeRestored() async {
        let rig = IntentsRig()
        rig.host.isReady = false
        rig.host.onSleep = { [host = rig.host] in if host.clock >= 1_002_000 { host.isReady = true } }
        rig.request("ivy")
        await rig.runtime.deliver()
        #expect(rig.host.memos == [ivyKey] && rig.host.clock >= 1_002_000)
        // The sign-in form is showing: after 10 s the delivery gives up quietly and the request keeps its minute.
        let waiting = IntentsRig()
        waiting.host.isReady = false
        let request = waiting.request("ivy")
        await waiting.runtime.deliver()
        #expect(waiting.host.opens.isEmpty && waiting.host.notices.isEmpty && waiting.store.pending == request)
        #expect(waiting.host.clock == 1_010_000 && !waiting.runtime.busy)
    }

    @Test func aRequestOfAnotherAccountNeverOpensAChat() async {
        let rig = IntentsRig()
        rig.request("ivy", account: "http://other.invalid\nsomeone")
        await rig.runtime.deliver()
        #expect(rig.host.opens.isEmpty && rig.host.memos.isEmpty)
        #expect(rig.host.messages == ["This shortcut belongs to another account or to another computer running Hermes. Choose your bot again in Shortcuts."])
        #expect(rig.host.notices.first?.title == "Couldn’t Start the Voice Memo")
        #expect(rig.store.pending == nil)
        // Signed out mid-way: the same refusal, never a recording.
        let out = IntentsRig()
        out.host.account = nil
        out.request("ivy")
        await out.runtime.deliver()
        #expect(out.host.memos.isEmpty && out.store.pending == nil && out.host.messages == [IntentsText.otherAccount])
    }

    @Test func theSameAccountWrittenAnotherWayIsStillThisAccount() async {
        let rig = IntentsRig()
        rig.request("ivy", account: "https://FIXTURE.invalid/\nqa")
        await rig.runtime.deliver()
        #expect(rig.host.memos == [ivyKey] && rig.host.notices.isEmpty)
    }

    @Test func aBotThatLeftTheRosterIsLookedForOnceMoreThenRefused() async {
        let rig = IntentsRig()
        rig.host.roster = [IntentsFixture.bot("default")]
        rig.request("ivy", name: "Ivy")
        await rig.runtime.deliver()
        #expect(rig.host.refreshes == 1 && rig.host.catalogSyncs == 1)
        #expect(rig.host.opens.isEmpty && rig.host.messages == ["“Ivy” is unavailable. Reconnect to the computer running Hermes and try again."])
        #expect(rig.store.pending == nil)
        // The roster read brings the bot back (a shortcut for a bot this phone had not listed yet).
        let back = IntentsRig()
        back.host.roster = [IntentsFixture.bot("default")]
        back.host.refreshed = [IntentsFixture.bot("default"), IntentsFixture.bot("ivy")]
        back.request("ivy")
        await back.runtime.deliver()
        #expect(back.host.refreshes == 1 && back.host.memos == [ivyKey] && back.host.notices.isEmpty)
    }

    @Test func aColdLaunchWaitsForTheRoster() async {
        let rig = IntentsRig()
        rig.host.roster = []
        rig.host.rosterLoaded = false
        rig.host.onSleep = { [host = rig.host] in
            if host.clock >= 1_004_000, !host.rosterLoaded {
                host.roster = [IntentsFixture.bot("default"), IntentsFixture.bot("ivy")]
                host.rosterLoaded = true
            }
        }
        rig.request("ivy")
        await rig.runtime.deliver()
        #expect(rig.host.memos == [ivyKey] && rig.host.refreshes == 0, "the roster arrived by itself: no second read")
    }

    @Test func aChatThatDoesNotOpenIsSaidAndNothingRecords() async {
        let rig = IntentsRig()
        rig.host.failOpen = true
        rig.request("ivy")
        await rig.runtime.deliver()
        #expect(rig.host.memos.isEmpty && rig.host.messages == ["Couldn’t open the selected bot’s chat. Reconnect and try again."])
        #expect(rig.store.pending == nil)
    }

    @Test func anotherBotWinningTheOpenRaceIsNotRecordedIn() async {
        let rig = IntentsRig()
        rig.host.opensKey["ivy"] = defaultKey
        rig.request("ivy")
        await rig.runtime.deliver()
        #expect(rig.host.memos.isEmpty && rig.host.messages == ["The selected bot’s chat changed before recording could start."])
        #expect(rig.store.pending == nil)
    }

    @Test func aNewerRequestDuringTheOpenWinsAndKeepsItsAcknowledgement() async {
        let rig = IntentsRig()
        let first = rig.request("ivy")
        var second: VoiceNoteRequest?
        rig.host.openDelay = 300
        rig.host.onOpen = { [unowned rig] in
            guard second == nil else { return }
            second = rig.request("default", name: "Hermes")       // the shortcut ran again, for another bot
            rig.runtime.kick()
        }
        await rig.runtime.deliver()
        #expect(rig.host.memos.isEmpty, "the older request did not record")
        #expect(rig.store.pending == second, "and did not acknowledge the newer one away")
        await rig.settle()
        #expect(rig.host.opens == ["ivy", "default"] && rig.host.memos == [defaultKey])
        #expect(rig.store.pending == nil && rig.host.notices.isEmpty)
        #expect(rig.events.contains("ack " + first.id) && rig.events.contains("ack " + (second?.id ?? "")))
        #expect(rig.runtime.deliveries == 2 && rig.runtime.mostOverlapping == 1)
    }

    @Test func anExpiredRequestRecordsNothing() async {
        let rig = IntentsRig()
        rig.request("ivy")
        rig.host.clock += 60_000
        await rig.runtime.deliver()
        #expect(rig.host.opens.isEmpty && rig.host.notices.isEmpty && rig.store.pending == nil)
        // It expires while the chat opens: canceled, said, acknowledged.
        let slow = IntentsRig()
        slow.request("ivy")
        slow.host.openDelay = 61_000
        slow.host.onSleep = nil
        await slow.runtime.deliver()
        #expect(slow.host.memos.isEmpty && slow.store.pending == nil)
    }

    @Test func aRequestThatAlreadyStartedOnlyAcknowledges() async throws {
        let rig = IntentsRig()
        let request = rig.request("ivy")
        let stored = try #require(rig.defaults.data(forKey: VoiceNoteRequestStore.storageKey))
        await rig.runtime.deliver()
        #expect(rig.host.memos == [ivyKey])
        rig.host.take = (nil, false)                                   // that take was sent
        rig.defaults.set(stored, forKey: VoiceNoteRequestStore.storageKey)   // the same request shows up again
        await rig.runtime.deliver()
        #expect(rig.host.memos == [ivyKey] && rig.host.opens == ["ivy"], "no second recording")
        #expect(rig.store.pending == nil && rig.events.filter { $0 == "ack " + request.id }.count == 2)
    }

    @Test func aTakeForTheSameBotIsLeftRunningAndAnotherBotsIsRefused() async {
        let rig = IntentsRig()
        rig.host.take = (ivyKey, true)
        rig.request("ivy")
        await rig.runtime.deliver()
        #expect(rig.host.opens.isEmpty && rig.host.memos.isEmpty && rig.host.notices.isEmpty && rig.store.pending == nil)
        rig.request("default")
        await rig.runtime.deliver()
        #expect(rig.host.opens.isEmpty && rig.host.memos.isEmpty && rig.store.pending == nil)
        #expect(rig.host.messages == ["Finish the current voice memo before starting another."])
        #expect(rig.host.take.key == ivyKey && rig.host.take.active, "the take was not touched")
    }

    @Test func theComposerBecomingReadyAfterThreeSecondsStillStarts() async {
        let rig = IntentsRig()
        rig.host.readyAfter = 3_000
        rig.request("ivy")
        await rig.runtime.deliver()
        #expect(rig.host.memos == [ivyKey] && rig.host.clock == 1_003_000 && rig.host.notices.isEmpty)
    }

    @Test func aComposerThatIsNeverReadyGivesUpAfterFiveSeconds() async {
        let rig = IntentsRig()
        rig.host.readyAfter = nil
        rig.request("ivy")
        await rig.runtime.deliver()
        #expect(rig.host.memos.isEmpty && rig.host.clock == 1_005_000)
        #expect(rig.host.messages == ["The message field isn’t ready, so the voice memo didn’t start. Wait for the chat to connect, then try again."])
        #expect(rig.store.pending == nil)
        // Foregrounding again does not record: the request is gone.
        rig.host.readyAfter = 0
        await rig.runtime.deliver()
        #expect(rig.host.memos.isEmpty && rig.host.opens == ["ivy"])
    }

    @Test func theChatChangingDuringTheWaitCancels() async {
        let rig = IntentsRig()
        rig.host.readyAfter = nil
        rig.host.onSleep = { [host = rig.host] in if host.clock >= 1_001_000 { host.chats.last?.isTop = false } }
        rig.request("ivy")
        await rig.runtime.deliver()
        #expect(rig.host.memos.isEmpty && rig.host.messages == ["Recording was canceled because the selected chat is no longer active."])
        #expect(rig.store.pending == nil)
        // The app left the screen while the chat opened: said with "Run the shortcut again."
        let away = IntentsRig()
        away.host.onOpen = { [host = away.host] in host.isActive = false }
        away.request("ivy")
        await away.runtime.deliver()
        #expect(away.host.memos.isEmpty && away.store.pending == nil)
        #expect(away.host.messages == ["Recording was canceled because the selected chat is no longer active. Run the shortcut again."])
    }

    // [phone-logs] Build 906, a cold launch from the shortcut: the app went inactive (in front: the shortcut's banner)
    // the moment its chat opened and was active again 5 s later; the memo was cancelled at once. It waits now.
    @Test func goingInactiveInFrontAsTheChatOpensWaitsAndStillRecords() async {
        let rig = IntentsRig()
        rig.host.onOpen = { [host = rig.host] in
            guard host.foreground == nil else { return }
            host.isActive = false
            host.foreground = true
            let back = host.clock + 5_000
            host.onSleep = { if host.clock >= back { host.isActive = true } }
        }
        let request = rig.request("ivy")
        await rig.runtime.deliver()
        #expect(rig.host.memos == [ivyKey], "\(rig.events)")
        #expect(rig.host.notices.isEmpty && rig.store.pending == nil && rig.runtime.started == [request.id])
        // In front but never active again: given up after the wait, as before.
        let stuck = IntentsRig()
        stuck.host.onOpen = { [host = stuck.host] in host.isActive = false; host.foreground = true }
        stuck.request("ivy")
        await stuck.runtime.deliver()
        #expect(stuck.host.memos.isEmpty && stuck.store.pending == nil)
        #expect(stuck.host.messages == ["Recording was canceled because the selected chat is no longer active. Run the shortcut again."])
    }

    // S26: nothing is pushed, and nothing records, once the app has left the screen.
    @Test func leavingDuringTheRosterReadOpensNothingAndEndsTheRequest() async {
        let rig = IntentsRig()
        rig.host.roster = [IntentsFixture.bot("default")]
        rig.host.refreshed = [IntentsFixture.bot("default"), IntentsFixture.bot("ivy")]
        rig.host.onRefresh = { [host = rig.host] in host.isActive = false }
        rig.request("ivy")
        await rig.runtime.deliver()
        #expect(rig.host.refreshes == 1 && rig.host.opens.isEmpty && rig.host.memos.isEmpty)
        #expect(rig.host.messages == ["Recording was canceled because the selected chat is no longer active. Run the shortcut again."])
        #expect(rig.store.pending == nil)
        // Back on screen: that request is over, so nothing records late.
        rig.host.isActive = true
        await rig.runtime.deliver()
        await rig.settle()
        #expect(rig.host.opens.isEmpty && rig.host.memos.isEmpty && rig.host.notices.count == 1)
    }

    // S26: a chat that did not come on top because the app left is the same ending, not "Couldn’t open…".
    @Test func leavingWhileTheChatOpensIsSaidAsCanceled() async {
        let rig = IntentsRig()
        rig.host.failOpen = true
        rig.host.onOpen = { [host = rig.host] in host.isActive = false }
        rig.request("ivy")
        await rig.runtime.deliver()
        #expect(rig.host.memos.isEmpty && rig.store.pending == nil)
        #expect(rig.host.messages == ["Recording was canceled because the selected chat is no longer active. Run the shortcut again."])
    }

    @Test func aSecondDeliverDuringADeliveryRunsOnceMoreAndNoMore() async {
        let rig = IntentsRig()
        rig.request("ivy")
        rig.host.openDelay = 500
        var kicked = false
        rig.host.onOpen = { [unowned rig] in
            guard !kicked else { return }
            kicked = true
            for _ in 0..<5 { rig.runtime.kick() }                   // five foreground events and intent runs at once
        }
        await rig.runtime.deliver()
        await rig.settle()
        #expect(rig.host.memos == [ivyKey] && rig.host.opens == ["ivy"])
        #expect(rig.runtime.deliveries == 1, "the follow-up found nothing waiting")
        #expect(rig.runtime.mostOverlapping == 1 && !rig.runtime.busy)
    }

    // S1: fifty triggers for one bot.
    @Test func fiftyTriggersGiveOneTake() async {
        let rig = IntentsRig()
        rig.host.openDelay = 10_000                                    // the chat takes longer to open than the burst lasts
        for _ in 0..<50 {
            rig.request("ivy")
            rig.runtime.kick()
            await Task.yield()
        }
        await rig.settle()
        #expect(rig.host.memos == [ivyKey], "exactly one take")
        #expect(rig.store.pending == nil && rig.host.notices.isEmpty)
        #expect(rig.runtime.mostOverlapping == 1 && rig.runtime.deliveries <= 3, "\(rig.runtime.deliveries) deliveries")
    }

    // S2: alternating bots.
    @Test func alternatingBotsGiveOneTakeAndTheRestAreRefused() async {
        let rig = IntentsRig()
        for index in 0..<20 {
            rig.request(index % 2 == 0 ? "ivy" : "default")
            await rig.runtime.deliver()
        }
        #expect(rig.host.memos == [ivyKey])
        #expect(rig.host.messages == Array(repeating: IntentsText.finishCurrent, count: 10), "every trigger for the other bot is refused")
        #expect(rig.store.pending == nil)
    }

    // S2 under load: a request for the other bot is written during the take's last wait, and its own delivery has not
    // begun (an intent writes its request, then kicks). The take starts, and that request is refused just after it:
    // one take, one sentence, nothing recorded for the other bot.
    @Test func aRequestWrittenJustBeforeTheTakeStartsIsRefusedJustAfterIt() async {
        let rig = IntentsRig()
        rig.host.readyAfter = 200
        var second: VoiceNoteRequest?
        rig.host.onSleep = { [unowned rig] in
            guard second == nil, rig.host.clock >= 1_000_200 else { return }       // the last wait before the composer is ready
            second = rig.request("default", name: "Hermes")
        }
        let first = rig.request("ivy")
        await rig.runtime.deliver()
        #expect(rig.host.memos == [ivyKey] && rig.host.notices.isEmpty, "the take started")
        #expect(second != nil && rig.store.pending == second, "the newer request waits for its own delivery")
        #expect(rig.events.contains("ack " + first.id))
        await rig.runtime.deliver()                                                  // the intent's kick
        #expect(rig.host.memos == [ivyKey] && rig.host.messages == [IntentsText.finishCurrent], "one take, one refusal")
        #expect(rig.store.pending == nil && rig.host.take.key == ivyKey && rig.host.take.active, "the take was not touched")
        #expect(rig.runtime.deliveries == 2 && rig.runtime.mostOverlapping == 1)
    }
}

@Suite struct SavedNoteTests {
    // The app left the screen while the note's chat opened: nothing is said, and the note waits for the next foreground.
    @Test func leavingWhileTheNotesChatOpensKeepsTheNoteQuietly() async {
        let rig = IntentsRig()
        rig.saveNote("ivy")
        rig.host.failOpen = true
        rig.host.onOpen = { [host = rig.host] in host.isActive = false }
        await rig.runtime.deliver()
        #expect(rig.host.notices.isEmpty && rig.host.drafts.isEmpty && rig.host.deleted.isEmpty)
        #expect(VoiceBotCatalog.pendingNote(rig.defaults) != nil)
        rig.host.failOpen = false
        rig.host.onOpen = nil
        rig.host.isActive = true
        await rig.runtime.deliver()
        #expect(rig.host.drafts.count == 1 && VoiceBotCatalog.pendingNote(rig.defaults) == nil)
    }

    // A25
    @Test func theNoteBecomesItsBotChatsDraftAndIsNeverSent() async {
        let rig = IntentsRig()
        let file = URL(fileURLWithPath: "/notes/a.wav")
        rig.saveNote("ivy", file: file)
        await rig.runtime.deliver()
        #expect(rig.host.opens == ["ivy"])
        #expect(rig.host.drafts == ["scope:" + ivyKey: MemoFile(path: "/memo/imported.wav", seconds: 4, peaks: [], mime: "audio/wav")])
        #expect(VoiceBotCatalog.pendingNote(rig.defaults) == nil && rig.host.deleted == [file])
        #expect(rig.host.memos.isEmpty && rig.host.notices.isEmpty && rig.events.contains("saved note recovered ivy"))
    }

    @Test func anotherAccountsNoteIsSaidOnceAndLeftAlone() async {
        let rig = IntentsRig()
        let note = rig.saveNote("ivy", account: "https://elsewhere.invalid\nqa")
        await rig.runtime.deliver()
        #expect(rig.host.messages == ["A saved voice memo belongs to another account or to another computer running Hermes. Sign back in to recover it."])
        #expect(rig.host.notices.first?.buttons.map(\.title) == ["OK"])
        #expect(rig.host.opens.isEmpty && rig.host.deleted.isEmpty && VoiceBotCatalog.pendingNote(rig.defaults) == note)
        await rig.runtime.deliver()
        await rig.runtime.deliver()
        #expect(rig.host.notices.count == 1, "not again in this run")
        // Nor in the next run of the app: once per note.
        let next = IntentsRuntime(store: rig.store, defaults: rig.defaults, host: rig.host)
        await next.deliver()
        #expect(rig.host.notices.count == 1, "not again for the same note: \(rig.host.messages)")
        // Another note of another account's is a new thing to say.
        rig.saveNote("ivy", account: "https://elsewhere.invalid\nqa")
        let later = IntentsRuntime(store: rig.store, defaults: rig.defaults, host: rig.host)
        await later.deliver()
        #expect(rig.host.notices.count == 2)
    }

    // A note that cannot be brought in is not tried again on every foreground of this run; the owner can retry, or
    // discard it and never be asked again.
    @Test func aNoteThatFailedIsNotRetriedByItselfAndCanBeDiscarded() async {
        let rig = IntentsRig()
        let file = URL(fileURLWithPath: "/notes/gone-bot.wav")
        let note = rig.saveNote("ghost", file: file)                 // its bot has left the roster
        await rig.runtime.deliver()
        #expect(rig.host.messages == [IntentsText.botUnavailable("Ghost")])
        #expect(rig.host.notices.first?.buttons.map(\.title) == ["Recover Recording", "Discard Recording", "Cancel"])
        #expect(rig.host.notices.first?.buttons.map(\.role) == [.preferred, .destructive, .cancel])
        let reads = rig.host.refreshes
        rig.host.dismissNotice()
        await rig.runtime.deliver()                                  // the next foreground
        await rig.runtime.deliver()
        #expect(rig.host.notices.count == 1 && rig.host.refreshes == reads, "no second alert, no second roster read")
        #expect(VoiceBotCatalog.pendingNote(rig.defaults) == note, "the recording is kept")
        rig.runtime.choose(.recover, from: rig.host.notices[0])      // the owner asks: it is tried
        await rig.settle()
        #expect(rig.host.notices.count == 2 && rig.host.refreshes == reads + 1)
        rig.runtime.choose(.discard, from: rig.host.notices[1])
        #expect(rig.host.deleted == [file] && VoiceBotCatalog.pendingNote(rig.defaults) == nil)
        #expect(rig.events.contains("saved note discarded"))
        await rig.runtime.deliver()
        #expect(rig.host.notices.count == 2 && rig.host.opens.isEmpty)
    }

    @Test func theChatChangingWhileTheNoteIsCopiedKeepsTheNote() async {
        let rig = IntentsRig()
        let note = rig.saveNote("ivy")
        rig.host.onImport = { [host = rig.host] in host.chats.last?.isTop = false }
        await rig.runtime.deliver()
        #expect(rig.host.messages == ["Your earlier recording is saved. Open its bot chat and tap Recover Recording to attach it."])
        #expect(rig.host.notices.first?.buttons.map(\.title) == ["Recover Recording", "Discard Recording", "Cancel"])
        #expect(rig.host.drafts.isEmpty && rig.host.deleted.isEmpty && rig.host.discarded.count == 1)
        #expect(VoiceBotCatalog.pendingNote(rig.defaults) == note)
    }

    @Test func aCopyOrADraftThatFailsKeepsTheFileAndTheKey() async {
        let copy = IntentsRig()
        let note = copy.saveNote("ivy")
        copy.host.importResult = nil
        await copy.runtime.deliver()
        #expect(copy.host.messages == ["Your earlier recording could not be saved to the draft. Tap Recover Recording to retry."])
        #expect(copy.host.deleted.isEmpty && VoiceBotCatalog.pendingNote(copy.defaults) == note)

        let draft = IntentsRig()
        let kept = draft.saveNote("ivy")
        draft.host.draftFails = true
        await draft.runtime.deliver()
        #expect(draft.host.messages == [IntentsText.noteNotSaved] && draft.host.discarded.count == 1)
        #expect(draft.host.deleted.isEmpty && VoiceBotCatalog.pendingNote(draft.defaults) == kept)
        // "Recover Recording" tries again, and this time it works.
        draft.host.draftFails = false
        draft.runtime.choose(.recover, from: draft.host.notices[0])
        await draft.settle()
        #expect(draft.host.drafts.count == 1 && VoiceBotCatalog.pendingNote(draft.defaults) == nil && draft.host.showing == nil)
    }

    // S19
    @Test func aNoteWhoseRecordingIsNotAFileOfOursIsForgottenQuietly() async {
        for path in ["/etc/passwd", "../../x", "/var/mobile/Containers/Data/Application/OTHER/Documents/a.m4a", "/"] {
            let rig = IntentsRig()
            let note = PendingVoiceNote(id: "N", bot: IntentsFixture.record("ivy"), path: path)
            rig.defaults.set(try? JSONEncoder().encode(note), forKey: VoiceBotCatalog.pendingKey)
            await rig.runtime.deliver()
            #expect(VoiceBotCatalog.pendingNote(rig.defaults) == nil, "cleared: \(path)")
            #expect(rig.host.notices.isEmpty && rig.host.opens.isEmpty && rig.host.deleted.isEmpty)
            #expect(LegacyNoteFile.resolve(path) == nil)
        }
    }

    // A26
    @Test func aRequestAndASameAccountNoteAsk() async {
        let rig = IntentsRig()
        rig.saveNote("ivy")
        let request = rig.request("default", name: "Hermes")
        await rig.runtime.deliver()
        #expect(rig.host.notices == [.savedNote(bot: "Ivy")])
        #expect(rig.host.opens.isEmpty && rig.host.memos.isEmpty)
        #expect(rig.store.pending == request, "the answer decides")
        #expect(!rig.runtime.busy, "nothing is held while the question is up")
        // A foreground while the question is up asks nothing new and recovers nothing behind it.
        await rig.runtime.deliver()
        #expect(rig.host.notices.count == 1 && rig.host.opens.isEmpty)
    }

    @Test func aRequestIsNotHeldUpByAnotherAccountsNote() async {
        let rig = IntentsRig()
        let note = rig.saveNote("ivy", account: "https://elsewhere.invalid\nqa")
        rig.request("default")
        await rig.runtime.deliver()
        #expect(rig.host.memos == [defaultKey] && rig.host.notices.isEmpty)
        #expect(VoiceBotCatalog.pendingNote(rig.defaults) == note)
    }

    @Test func aNoteIsNotRecoveredOverATakeAShortcutStartedInThisRun() async {
        let rig = IntentsRig()
        rig.request("default")
        await rig.runtime.deliver()
        #expect(rig.host.memos == [defaultKey])
        rig.saveNote("ivy")
        await rig.runtime.deliver()
        #expect(rig.host.opens == ["default"], "the take's chat stays on top")
        rig.host.take = (nil, false)                                   // sent
        await rig.runtime.deliver()
        #expect(rig.host.opens == ["default"], "and stays for the rest of this run")
        await rig.runtime.deliver(explicitRecovery: true)
        #expect(rig.host.opens == ["default", "ivy"] && rig.host.drafts.count == 1)
    }

    @Test func aNoteIsNotRecoveredWhileAnyTakeRuns() async {
        let rig = IntentsRig()
        rig.host.take = (defaultKey, true)
        rig.saveNote("ivy")
        await rig.runtime.deliver()
        #expect(rig.host.opens.isEmpty && VoiceBotCatalog.pendingNote(rig.defaults) != nil)
    }

    // A27
    @Test func cancelKeepsTheNoteAndDropsTheRequest() async {
        let rig = IntentsRig()
        let note = rig.saveNote("ivy")
        let request = rig.request("default")
        await rig.runtime.deliver()
        rig.host.dismissNotice()                                       // the alert went with the tap
        rig.runtime.choose(.cancel, from: .savedNote(bot: "Ivy"))
        await rig.settle()
        #expect(rig.store.pending == nil && rig.events.contains("ack " + request.id))
        #expect(VoiceBotCatalog.pendingNote(rig.defaults) == note && rig.host.opens.isEmpty && rig.host.memos.isEmpty)
        // The next foreground brings the note into its chat quietly.
        await rig.runtime.deliver()
        #expect(rig.host.opens == ["ivy"] && rig.host.drafts.count == 1 && VoiceBotCatalog.pendingNote(rig.defaults) == nil)
    }

    @Test func openChatBringsTheNoteToItsChatAndRecordsNothing() async {
        let rig = IntentsRig()
        rig.saveNote("ivy")
        rig.request("default")
        await rig.runtime.deliver()
        rig.host.dismissNotice()
        rig.runtime.choose(.openChat, from: .savedNote(bot: "Ivy"))
        await rig.settle()
        #expect(rig.store.pending == nil)
        #expect(rig.host.opens == ["ivy"] && rig.host.drafts.keys.sorted() == ["scope:" + ivyKey])
        #expect(rig.host.memos.isEmpty && VoiceBotCatalog.pendingNote(rig.defaults) == nil)
    }

    @Test func discardAndRecordDeletesTheNoteAndRecordsForTheRequest() async {
        let rig = IntentsRig()
        let file = URL(fileURLWithPath: "/notes/a.wav")
        rig.saveNote("ivy", file: file)
        let request = rig.request("default")
        await rig.runtime.deliver()
        rig.host.clock += 45_000                                       // the owner took a while to decide
        rig.host.dismissNotice()
        rig.runtime.choose(.discardAndRecord, from: .savedNote(bot: "Ivy"))
        await rig.settle()
        #expect(rig.host.deleted == [file] && VoiceBotCatalog.pendingNote(rig.defaults) == nil)
        #expect(rig.host.opens == ["default"] && rig.host.memos == [defaultKey])
        #expect(rig.store.pending == nil && rig.host.drafts.isEmpty)
        #expect(!rig.runtime.started.contains(request.id), "the tap made a new request with a new minute")
    }

    // S30: a second shortcut while the question is up: one alert, and the newest request is the one answered.
    @Test func aSecondShortcutWhileAskedAnswersForTheNewestRequest() async {
        let rig = IntentsRig()
        rig.host.roster.append(IntentsFixture.bot("ops"))
        rig.saveNote("ivy")
        rig.request("default")
        await rig.runtime.deliver()
        let newest = rig.request("ops")
        await rig.runtime.deliver()
        #expect(rig.host.notices.count == 1, "the same question is not stacked")
        #expect(rig.store.pending == newest)
        rig.host.dismissNotice()
        rig.runtime.choose(.discardAndRecord, from: .savedNote(bot: "Ivy"))
        await rig.settle()
        #expect(rig.host.memos == ["ios-direct::ops"] && rig.store.pending == nil)
    }

    @Test func aButtonOfAnAlertThatIsNoLongerTheQuestionDoesNothing() async {
        let rig = IntentsRig()
        rig.runtime.choose(.discardAndRecord, from: .savedNote(bot: "Ivy"))
        rig.runtime.choose(.openChat, from: .savedNote(bot: "Ivy"))
        rig.runtime.choose(.cancel, from: .savedNote(bot: "Ivy"))
        rig.runtime.choose(.ok, from: .voiceNote("x"))
        await rig.settle()
        #expect(rig.host.opens.isEmpty && rig.host.deleted.isEmpty && rig.events.isEmpty)
    }

    @Test func signingOutForgetsWhatWaited() async {
        let rig = IntentsRig()
        rig.saveNote("ivy")
        rig.request("default")
        await rig.runtime.deliver()
        #expect(rig.host.showing != nil)
        rig.runtime.reset()
        #expect(rig.store.pending == nil && rig.host.showing == nil && rig.runtime.started.isEmpty)
        // S28: nothing records after signing back in.
        await rig.runtime.deliver()
        #expect(rig.host.memos.isEmpty)
    }
}

@Suite struct QuickActionRouteTests {
    private func make(_ rows: [ShortcutTarget] = [
        ShortcutTarget(id: "bot:" + ivyKey, name: "Ivy", kind: "bot", botKey: ivyKey),
        ShortcutTarget(id: "session:s1", name: "Trip plan", kind: "session", sessionId: "s1"),
        ShortcutTarget(id: "room:ops", name: "Ops", kind: "room", group: "ops"),
    ]) -> (IntentsRig, String) {
        let rig = IntentsRig()
        ShortcutPolicy.activate(url: IntentsFixture.url, username: IntentsFixture.username, rig.defaults)
        let epoch = ShortcutPolicy.epoch(rig.defaults) ?? ""
        let safe = ShortcutPolicy.catalog(rows, epoch: epoch, validSession: NotificationRules.valid)
        rig.defaults.set(ShortcutPolicy.encoded(safe, rig.defaults), forKey: ShortcutPolicy.catalogKey)
        rig.host.sessions = ["s1": "default"]
        return (rig, epoch)
    }

    @Test func searchOpensTheSearch() async {
        let (rig, epoch) = make()
        await rig.runtime.route("search", id: "", epoch: epoch)
        #expect(rig.host.searches == 1 && rig.host.notices.isEmpty && rig.events == ["search", "routed search"])
    }

    @Test func openGoesToTheBotsChatAndMemoStartsTheRecorderThere() async {
        let (rig, epoch) = make()
        await rig.runtime.route("open", id: epoch + ":bot:" + ivyKey, epoch: epoch)
        #expect(rig.host.opens == ["ivy"] && rig.host.memos.isEmpty)
        await rig.runtime.route("memo", id: epoch + ":bot:" + ivyKey, epoch: epoch)
        #expect(rig.host.opens == ["ivy", "ivy"] && rig.host.memos == [ivyKey] && rig.host.notices.isEmpty)
        // Again while that take runs: left alone. For another bot's item it would be refused.
        await rig.runtime.route("memo", id: epoch + ":bot:" + ivyKey, epoch: epoch)
        #expect(rig.host.memos == [ivyKey] && rig.host.notices.isEmpty)
    }

    @Test func memoWhileAnotherBotsTakeRunsIsRefused() async {
        let (rig, epoch) = make()
        rig.host.take = (defaultKey, true)
        await rig.runtime.route("memo", id: epoch + ":bot:" + ivyKey, epoch: epoch)
        #expect(rig.host.opens.isEmpty && rig.host.messages == [IntentsText.finishCurrent])
        #expect(rig.host.notices.first?.title == "Shortcut Unavailable")
    }

    @Test func aListedChatOpensAndOneThatDoesNotIsSaid() async {
        let (rig, epoch) = make()
        await rig.runtime.route("open", id: epoch + ":session:s1", epoch: epoch)
        #expect(rig.host.sessionOpens == ["s1"] && rig.host.notices.isEmpty)
        rig.host.sessionOpen = .failed
        await rig.runtime.route("open", id: epoch + ":session:s1", epoch: epoch)
        #expect(rig.host.messages == ["That chat didn’t open."])
        // The list no longer holds it: ten seconds of waiting, then the same sentence, never a blank chat.
        rig.host.sessions = [:]
        let before = rig.host.clock
        await rig.runtime.route("open", id: epoch + ":session:s1", epoch: epoch)
        #expect(rig.host.messages == ["That chat didn’t open.", "That chat didn’t open."] && rig.host.sessionOpens.count == 2)
        #expect(rig.host.clock - before >= 10_000)
    }

    // A41: the gateway no longer has the chat (it was deleted on another device after the list was read).
    @Test func aListedChatTheGatewayNoLongerHasIsSaidAsGone() async {
        let (rig, epoch) = make()
        rig.host.sessionOpen = .gone
        await rig.runtime.route("open", id: epoch + ":session:s1", epoch: epoch)
        #expect(rig.host.sessionOpens == ["s1"])
        #expect(rig.host.messages == ["That chat is no longer available. Open " + IntentsText.app + " and choose it again."])
        #expect(rig.host.notices.first?.title == "Shortcut Unavailable")
    }

    @Test func whatCannotBeOpenedSaysWhy() async {
        let (rig, epoch) = make()
        await rig.runtime.route("open", id: epoch + ":bot:" + ivyKey, epoch: "ANOTHER")
        await rig.runtime.route("open", id: epoch + ":bot:ios-direct::gone", epoch: epoch)
        await rig.runtime.route("memo", id: epoch + ":session:s1", epoch: epoch)
        await rig.runtime.route("open", id: epoch + ":room:ops", epoch: epoch)
        #expect(rig.host.messages == ["This shortcut belongs to a previous sign-in.",
                                      "That chat is no longer available. Open \(IntentsText.app) and choose it again.",
                                      "Voice memos need a bot chat.", "That group chat is no longer available."])
        #expect(rig.host.opens.isEmpty && rig.host.sessionOpens.isEmpty && rig.host.memos.isEmpty)
        #expect(rig.host.notices.allSatisfy { $0.title == "Shortcut Unavailable" && $0.buttons.map(\.title) == ["OK"] })
    }

    @Test func aBotThatIsNotOnTheRosterIsWaitedForThenSaid() async {
        let (rig, epoch) = make()
        rig.host.roster = []
        await rig.runtime.route("open", id: epoch + ":bot:" + ivyKey, epoch: epoch)
        #expect(rig.host.messages == ["That bot is unavailable. Open its chat and try again."] && rig.host.opens.isEmpty)
        // It arrives while waited for (a cold launch): the chat opens.
        let (cold, coldEpoch) = make()
        cold.host.roster = []
        cold.host.onSleep = { [host = cold.host] in if host.clock >= 1_002_000 { host.roster = [IntentsFixture.bot("ivy")] } }
        await cold.runtime.route("open", id: coldEpoch + ":bot:" + ivyKey, epoch: coldEpoch)
        #expect(cold.host.opens == ["ivy"] && cold.host.notices.isEmpty)
    }

    @Test func aChatThatDidNotOpenIsSaid() async {
        let (rig, epoch) = make()
        rig.host.failOpen = true
        await rig.runtime.route("open", id: epoch + ":bot:" + ivyKey, epoch: epoch)
        #expect(rig.host.messages == ["That chat didn’t open."])
    }

    @Test func signedOutOrNotOnScreenSaysToOpenTheAppAfterTenSeconds() async {
        let (rig, epoch) = make()
        rig.host.isReady = false
        rig.host.account = nil
        await rig.runtime.route("search", id: "", epoch: epoch)
        #expect(rig.host.messages == ["Open \(IntentsText.app) to use this shortcut."] && rig.host.searches == 0)
    }

    // UX study #264: in front and signed in, but the tabs never came up: not "open the app", which is open.
    @Test func signedInButNotReadySaysTheGatewayIsNotConnectedYet() async {
        let (rig, epoch) = make()
        rig.host.isReady = false
        await rig.runtime.route("search", id: "", epoch: epoch)
        #expect(rig.host.messages == [IntentsText.notReady()] && rig.host.searches == 0)
        #expect(IntentsText.notReady(app: "Hermes HQ")
                == "Hermes HQ isn’t connected to the computer running Hermes yet. This shortcut runs if it connects in the next few seconds; if not, try again once it’s connected.")
    }

    // UX study #264: held after the notice, the shortcut runs once the tabs come up within the cap.
    @Test func aHeldShortcutRunsWhenTheTabsComeUp() async {
        let (rig, epoch) = make()
        rig.host.isReady = false
        let start = rig.host.now()
        rig.host.onSleep = { [weak host = rig.host] in
            guard let host, host.now() - start > 14_000 else { return }
            host.isReady = true                                       // 4 s after the notice
        }
        await rig.runtime.route("search", id: "", epoch: epoch)
        #expect(rig.host.messages == [IntentsText.notReady()] && rig.host.searches == 1)
        #expect(rig.host.showing == nil, "the notice goes when the shortcut runs")
    }

    // And not after the cap: the notice stays the last word.
    @Test func aHeldShortcutIsDroppedAfterTheCap() async {
        let (rig, epoch) = make()
        rig.host.isReady = false
        let start = rig.host.now()
        rig.host.onSleep = { [weak host = rig.host] in
            guard let host, host.now() - start > 21_000 else { return }
            host.isReady = true
        }
        await rig.runtime.route("search", id: "", epoch: epoch)
        #expect(rig.host.messages == [IntentsText.notReady()] && rig.host.searches == 0)
    }

    // UX study #265: a group chat's item opens that group chat.
    @Test func aGroupChatItemOpensTheGroupChat() async {
        let (rig, epoch) = make()
        rig.host.rooms = ["ops"]
        await rig.runtime.route("open", id: epoch + ":room:ops", epoch: epoch)
        #expect(rig.host.roomOpens == ["ops"] && rig.host.notices.isEmpty)
        await rig.runtime.route("memo", id: epoch + ":room:ops", epoch: epoch)
        #expect(rig.host.roomOpens == ["ops"] && rig.host.messages == ["Voice memos need a bot chat."])
    }

    // UX study #263: a sheet holding unsaved edits asked first and the owner kept it. Their own choice: no failure is said.
    @Test func aKeptSheetSaysNothing() async {
        let (rig, epoch) = make()
        rig.host.rooms = ["ops"]
        rig.host.keepSheet = true
        rig.host.sessionOpen = .kept
        await rig.runtime.route("open", id: epoch + ":room:ops", epoch: epoch)
        await rig.runtime.route("open", id: epoch + ":bot:" + ivyKey, epoch: epoch)
        await rig.runtime.route("open", id: epoch + ":session:s1", epoch: epoch)
        #expect(rig.host.roomOpens.isEmpty && rig.host.memos.isEmpty && rig.host.notices.isEmpty)
    }

    @Test func openBotFallsBackToThePickersCatalog() async {
        // "Open Bot" for a bot the quick-action catalog does not hold yet: the route takes the target it was handed.
        let (rig, epoch) = make([])
        let target = ShortcutTarget(id: epoch + ":bot:" + ivyKey, name: "Ivy", kind: "bot", botKey: ivyKey)
        await rig.runtime.route("open", id: target.id, epoch: epoch, fallback: target)
        #expect(rig.host.opens == ["ivy"] && rig.host.memos.isEmpty && rig.host.notices.isEmpty)
    }

    @Test func aRouteWaitsForADeliveryInFlight() async {
        let (rig, epoch) = make()
        rig.host.openDelay = 300
        rig.request("default")
        async let delivery: Void = rig.runtime.deliver()
        for _ in 0..<1000 where !rig.runtime.busy { await Task.yield() }   // a busy machine can take more than one turn to start it
        await rig.runtime.route("search", id: "", epoch: epoch)
        await delivery
        #expect(rig.host.log.first == "open default" && rig.host.searches == 1)
        #expect(rig.events.firstIndex(of: "deliver end") ?? 99 < rig.events.firstIndex(of: "search") ?? -1, "one thing at a time")
    }

    // One delivery can hold the gate for close to half a minute. An item chosen meanwhile waits 30 s, then says so.
    @Test func aRouteThatNeverGetsItsTurnSaysSo() async {
        let (rig, epoch) = make()
        rig.host.openDelay = 45_000
        rig.request("default")
        async let delivery: Void = rig.runtime.deliver()
        for _ in 0..<1000 where !rig.runtime.busy { await Task.yield() }   // a busy machine can take more than one turn to start it
        await rig.runtime.route("search", id: "", epoch: epoch)
        #expect(rig.host.searches == 0, "it did not run beside the delivery")
        #expect(rig.host.notices.last == .shortcut("HQ was busy. Try again.".replacingOccurrences(of: "HQ", with: IntentsText.app)))
        await delivery
    }
}

/// S23: a shortcut or a quick action dismisses whatever alert is up. Code that awaits that alert's button must still
/// get an answer (`AlertAnswer`), or it waits for ever.
@Suite struct AlertAnswerTests {
    @Test func aButtonAnswersAndOnlyOnce() async {
        let value: Bool = await withCheckedContinuation { continuation in
            let answer = AlertAnswer(continuation, unanswered: false)
            answer.answer(true)
            answer.answer(false)                 // a second tap changes nothing
        }
        #expect(value)
    }

    @Test func anAlertThatWentAwayUnansweredIsAnsweredAsUnanswered() async {
        let value: Bool? = await withCheckedContinuation { continuation in
            var buttons: [() -> Void] = []
            do {
                let answer = AlertAnswer<Bool?>(continuation, unanswered: nil)
                buttons.append { answer.answer(true) }
            }
            buttons.removeAll()                  // the alert is released with no button tapped
        }
        #expect(value == nil)
    }

    @Test func anAlertThatNeverShowedIsAnsweredToo() async {
        let value: Bool = await withCheckedContinuation { continuation in
            _ = AlertAnswer(continuation, unanswered: false)
        }
        #expect(value == false)
    }
}
