// [diagnostics] The reopen check that logs a reply a chat screen never showed (HermesKit/Chat/LeftChatProbe.swift).

import Foundation
import Testing
@testable import HermesHQNative

struct LeftChatProbeTests {
    private func reply(_ text: String, at: Date?, row: Int? = nil) -> ChatMessage {
        ChatMessage(id: UUID().uuidString, role: .assistant, parts: [.text(text)], timestamp: at, rowId: row)
    }

    @Test func aReplySavedBeforeTheScreenLeftAndNeverShownCounts() {
        let left = Date()
        let shown = Set([reply("Morning. Nothing urgent.", at: left.addingTimeInterval(-600))].flatMap(LeftChatProbe.replyKeys))
        let fresh = [reply("Morning. Nothing urgent.", at: left.addingTimeInterval(-600)),
                     reply("Done: the report is in your inbox.", at: left.addingTimeInterval(-30))]
        let newest = left.addingTimeInterval(-25).timeIntervalSince1970
        #expect(LeftChatProbe.missed(fresh: fresh, shown: shown, leftAt: left, newestStored: newest) == [1])
    }

    @Test func aReplySavedAfterTheScreenLeftOrAlreadyShownDoesNot() {
        let left = Date()
        let shown = Set([reply("Done: the report is in your inbox.", at: nil)].flatMap(LeftChatProbe.replyKeys))
        let fresh = [reply("Done: the report is in your inbox.", at: left.addingTimeInterval(-30)),
                     ChatMessage(id: "u", role: .user, parts: [.text("Thanks")], timestamp: left.addingTimeInterval(-20), rowId: 2),
                     reply("A later reply.", at: left.addingTimeInterval(5))]
        let newest = left.addingTimeInterval(6).timeIntervalSince1970
        #expect(LeftChatProbe.missed(fresh: fresh, shown: shown, leftAt: left, newestStored: newest).isEmpty)
    }

    /// Build 312 (state.db, 2026-10-17 12:44 and 00:39): the screen left mid-turn and the turn finished after it left; the
    /// folded reply carries the turn's first row's time (before it left), busy or not on the screen that left.
    @Test func aTurnThatFinishedAfterTheScreenLeftIsNotAMiss() {
        let left = Date()
        let prompt = ChatMessage(id: "u", role: .user, parts: [.text("Check the logs")], timestamp: left.addingTimeInterval(-90), rowId: 3)
        let fresh = [prompt, reply("Checked: all clear.", at: left.addingTimeInterval(-80))]
        // The reopen read a row saved after the screen left: the reply's end.
        let later = left.addingTimeInterval(40).timeIntervalSince1970
        #expect(LeftChatProbe.missed(fresh: fresh, shown: [], leftAt: left, newestStored: later).isEmpty)
        // Every row read was saved before it left: the screen did miss the reply.
        let before = left.addingTimeInterval(-60).timeIntervalSince1970
        #expect(LeftChatProbe.missed(fresh: fresh, shown: [], leftAt: left, newestStored: before) == [1])
    }

    /// An older reply ends where the next message begins: one followed by a prompt sent before the screen left was
    /// finished then, however late the newest row.
    @Test func anOlderReplyEndsAtTheNextMessage() {
        let left = Date()
        let fresh = [reply("Earlier answer.", at: left.addingTimeInterval(-300)),
                     ChatMessage(id: "u", role: .user, parts: [.text("Next")], timestamp: left.addingTimeInterval(-100), rowId: 4),
                     reply("Still running.", at: left.addingTimeInterval(-90))]
        let later = left.addingTimeInterval(40).timeIntervalSince1970
        #expect(LeftChatProbe.missed(fresh: fresh, shown: [], leftAt: left, newestStored: later) == [0])
    }

    /// 2026-10-24 (row 27628): the live screen folded a long tool-heavy turn so its words started differently than the
    /// history read's fold; the same row, or the same closing words, is the same reply.
    @Test func aReplyFoldedDifferentlyIsMatchedByRowOrByItsEnd() {
        let left = Date()
        let finalWords = "Refund confirmed. The order is cancelled and the money is back on your card within five days."
        let fresh = [reply("Looking at the order first. " + finalWords, at: left.addingTimeInterval(-700), row: 27628)]
        let newest = left.addingTimeInterval(-500).timeIntervalSince1970
        let sameEnd = Set([reply("Checking. " + finalWords, at: nil)].flatMap(LeftChatProbe.replyKeys))
        #expect(LeftChatProbe.missed(fresh: fresh, shown: sameEnd, leftAt: left, newestStored: newest).isEmpty)
        let sameRow = Set([reply("Something else entirely.", at: nil, row: 27628)].flatMap(LeftChatProbe.replyKeys))
        #expect(LeftChatProbe.missed(fresh: fresh, shown: sameRow, leftAt: left, newestStored: newest).isEmpty)
        let other = Set([reply("Something else entirely.", at: nil, row: 27000)].flatMap(LeftChatProbe.replyKeys))
        #expect(LeftChatProbe.missed(fresh: fresh, shown: other, leftAt: left, newestStored: newest) == [0])
    }
}
