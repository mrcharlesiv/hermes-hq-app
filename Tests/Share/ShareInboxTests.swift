// [share] docs/spec/3x-share.md §7.11: the chat a share just went to is opened once, for the account it was made for.

import Foundation
import Testing
@testable import HermesHQNative

@Suite struct ShareInboxTests {
    private func store() -> ShareStore { ShareStore(folder: ShareTemp.folder("inbox")) }
    private func note(account: String = ShareSamples.key, age: Double = 2, session: String = "20260929_120000_aabbcc02") -> ShareSent {
        ShareSent(id: UUID().uuidString, account: account, session: session, profile: "ivy", botName: "Ivy", at: Date().timeIntervalSince1970 - age)
    }

    @Test func opensOnce() {
        let store = store()
        store.record(note())
        var opened: [ShareSent] = []
        ShareInbox.openIfAny(store: store, account: { ShareSamples.key }) { opened.append($0) }
        #expect(opened.map(\.session) == ["20260929_120000_aabbcc02"] && opened.first?.profile == "ivy")
        #expect(!store.hasSentNote)
        ShareInbox.openIfAny(store: store, account: { ShareSamples.key }) { opened.append($0) }
        #expect(opened.count == 1)
    }

    @Test func neverForAnotherAccountOrAnOldNote() {
        var opened = 0
        for stale in [note(account: "http://other\nme"), note(age: 301), note(age: -6), note(session: "a/b")] {
            let store = store()
            store.record(stale)
            ShareInbox.openIfAny(store: store, account: { ShareSamples.key }) { _ in opened += 1 }
            #expect(!store.hasSentNote)                             // gone all the same
        }
        #expect(opened == 0)
    }

    @Test func signedOutKeepsTheNoteForLater() {
        let store = store()
        store.record(note())
        var opened = 0
        ShareInbox.openIfAny(store: store, account: { nil }) { _ in opened += 1 }
        #expect(opened == 0 && store.hasSentNote)
        // Signed in a moment later (a cold launch became active before the account was restored): it opens.
        ShareInbox.openIfAny(store: store, account: { ShareSamples.key }) { _ in opened += 1 }
        #expect(opened == 1 && !store.hasSentNote)
    }

    @Test func noNoteCostsNothing() {
        var asked = 0, opened = 0
        ShareInbox.openIfAny(store: store(), account: { asked += 1; return ShareSamples.key }) { _ in opened += 1 }
        ShareInbox.openIfAny(store: nil, account: { asked += 1; return ShareSamples.key }) { _ in opened += 1 }
        #expect(asked == 0 && opened == 0)                          // the Keychain is not even read
    }

    @Test func anUnreadableNoteIsRemovedAndOpensNothing() throws {
        let store = store()
        try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.sentFile)
        var opened = 0
        ShareInbox.openIfAny(store: store, account: { ShareSamples.key }) { _ in opened += 1 }
        #expect(opened == 0 && !store.hasSentNote)
    }

    @Test func theAppsKeyIsTheRostersKey() {
        // The note's account is the roster's (`ShareRules.accountKey`); the app asks with `StoredAccount.key`.
        let stored = StoredAccount(url: "HTTP://127.0.0.1:9911/", username: "share-fixture")
        #expect(stored.key == ShareSamples.key)
        let store = store()
        store.record(note())
        var opened = 0
        ShareInbox.openIfAny(store: store, account: { stored.key }) { _ in opened += 1 }
        #expect(opened == 1)
    }

    // MARK: Giving way: a sheet that is up, a chat the person asked for

    @Test func aSheetThatIsUpIsNeverThrownAwayAndTheNoteIsStillTaken() {
        let store = store()
        store.record(note())
        var steps: [ShareInbox.Step] = []
        // The app comes forward with a New Bot form open: the note is taken, as always…
        ShareInbox.openIfAny(store: store, account: { ShareSamples.key }) { _ in
            steps.append(ShareInbox.step(taken: Date(), asked: nil, ready: true, sheetUp: true, attempt: 0))
        }
        #expect(!store.hasSentNote)
        // …and nothing opens: neither now nor when the sheet has gone (there is no note left to open).
        #expect(steps == [.drop])
        ShareInbox.openIfAny(store: store, account: { ShareSamples.key }) { _ in steps.append(.open) }
        #expect(steps == [.drop])
        // With nothing presented, the same share opens its chat.
        #expect(ShareInbox.step(taken: Date(), asked: nil, ready: true, sheetUp: false, attempt: 0) == .open)
    }

    @Test func aChatThePersonAskedForWins() {
        let taken = Date()
        // They tapped an alert (or a link) to come forward: asked a moment before the note was taken, or since.
        for asked in [taken.addingTimeInterval(-0.2), taken, taken.addingTimeInterval(1.5), taken.addingTimeInterval(-ShareInbox.givesWay)] {
            #expect(ShareInbox.step(taken: taken, asked: asked, ready: true, sheetUp: false, attempt: 0) == .drop)
            #expect(ShareInbox.step(taken: taken, asked: asked, ready: false, sheetUp: false, attempt: 3) == .drop)   // also while it waits
        }
        // An alert they tapped well before this share is no reason to keep its chat shut.
        let earlier = taken.addingTimeInterval(-ShareInbox.givesWay - 1)
        #expect(ShareInbox.step(taken: taken, asked: earlier, ready: true, sheetUp: false, attempt: 0) == .open)
        // The stamp itself.
        let before = Date()
        ShareInbox.personAsked()
        #expect((ShareInbox.askedAt ?? .distantPast) >= before)
        ShareInbox.personAsked(now: .distantPast)                  // left as it was found: no other test gives way
        #expect(ShareInbox.askedAt == .distantPast)
    }

    @Test func aColdLaunchWaitsForTheTabsAndTheListsThenGivesUp() {
        let taken = Date()
        #expect(ShareInbox.step(taken: taken, asked: nil, ready: false, sheetUp: false, attempt: 0) == .wait)
        #expect(ShareInbox.step(taken: taken, asked: nil, ready: false, sheetUp: false, attempt: ShareInbox.attempts - 1) == .wait)
        #expect(ShareInbox.step(taken: taken, asked: nil, ready: false, sheetUp: false, attempt: ShareInbox.attempts) == .drop)   // ten seconds on
        #expect(Double(ShareInbox.attempts) * 0.25 == ShareInbox.givesWay)
        // Not ready with a sheet up: it waits (the sheet may be gone by then), and decides once the lists are there.
        #expect(ShareInbox.step(taken: taken, asked: nil, ready: false, sheetUp: true, attempt: 1) == .wait)
        #expect(ShareInbox.step(taken: taken, asked: nil, ready: true, sheetUp: true, attempt: 2) == .drop)
    }

    @Test func theHooksAreSafeInABuildWithoutAnAppGroup() {
        // The native identity: no group, so no store, and every hook returns at once.
        if AppIdentity.current.appGroup == nil {
            #expect(ShareInbox.store == nil && !ShareRosterWriter.shared.enabled)
        } else {
            #expect(ShareInbox.store != nil)
        }
    }
}
