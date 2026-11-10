// Build 559 crash ("I unlocked my phone", 0.7 s after a background launch): a reply measured off the main thread
// landed as a batch update while a text-size change had reached the window but no layout pass had run. The table took
// the new trait inside `performBatchUpdates`, dropped the row counts it had, and read them again from the data source,
// which `apply` had already moved to the new rows: UIKit threw "Invalid batch updates detected".

import Foundation
import Testing
import UIKit
@testable import HermesHQNative

@MainActor
@Suite struct UnlaidTableApplyTests {
    @Test func aMeasuredReplyLandingAfterATextSizeChangeDoesNotThrow() async throws {
        let spy = SpyChatSession()                       // two cached messages: rows at init
        let chat = ChatViewController(session: spy)
        // A hidden window gets no layout pass from the run loop, as a scene launched in the background.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.isHidden = false
        window.rootViewController = chat
        window.layoutIfNeeded()
        let shown = { chat.tableView(chat.tableView, numberOfRowsInSection: 0) }   // the chat's own rows
        let before = shown()
        #expect(before > 0)
        #expect(chat.tableView.numberOfRows(inSection: 0) == before)
        // A long reply: too much to measure on the main thread, so it lands from the layout queue as a batch update.
        let tag = UUID().uuidString
        let long = "Short \(tag)"
        spy.messages.append(ChatMessage(id: "b-\(tag)", role: .assistant, parts: [.text(long)], timestamp: Date(), rowId: 3))
        spy.onChange?(.appended(ids: ["b-\(tag)"]))
        // The phone unlocks and the scene's text size settles while no layout pass runs: the table takes it at its next
        // trait update, the one inside the batch.
        let current = chat.tableView.traitCollection.preferredContentSizeCategory
        chat.tableView.traitOverrides.preferredContentSizeCategory = current == .extraLarge ? .large : .extraLarge
        var landed = false
        for _ in 0..<150 where !landed {
            try await Task.sleep(for: .milliseconds(20))
            landed = shown() > before
        }
        #expect(landed, "the reply reached the table")
        chat.view.layoutIfNeeded()
        #expect(chat.tableView.numberOfRows(inSection: 0) == shown())
        withExtendedLifetime(window) {}
    }
}
