// [composer] A queued row's Delete and Edit (docs/spec/3x-composer.md §15.3, §15.5; audit 863 02-1, 02-2, 02-8, 02-9).

import Foundation
import Testing
import UIKit
@testable import HermesHQNative

@MainActor @Suite("Composer · queue Delete and Edit", .serialized)
struct QueueEditTests {
    /// A chat with a reply running and "second", "third" queued behind it.
    private func busyWithTwoQueued() async throws -> (ChatHarness, LiveChatSession) {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        s.queueDrainFallback = .milliseconds(30)
        #expect(await h.open())
        h.client.onCall { method, _ in
            switch method {
            case "prompt.submit": return ["status": "streaming"]
            case "session.interrupt": return ["status": "interrupted"]
            default: return [:]
            }
        }
        s.send("first")
        await h.emit([h.event("message.start"), h.event("message.delta", ["text": "Long answer"])])
        s.redirectUnsupported = true   // typed messages wait in the queue
        s.send("second")
        s.send("third")
        return (h, s)
    }

    private func endTurn(_ h: ChatHarness) async {
        await h.emit([h.event("message.complete", ["text": "Long answer", "status": "complete"]),
                      h.event("session.info", ["running": false])])
    }

    @Test func deleteThrowsTheRowAwayAndGivesNothingBack() async throws {
        let (_, s) = try await busyWithTwoQueued()
        var returned: [String] = []
        s.onDraftReturned = { text, _ in returned.append(text) }
        let second = try #require(s.queuedMessages.first?.id)
        s.discardQueued(second)
        #expect(s.queuedMessages.map(\.text) == ["third"])
        #expect(returned.isEmpty, "Delete is not Edit: nothing comes back to the field")
    }

    @Test func aRowBeingEditedWaitsAndSaveChangesItInPlace() async throws {
        let (h, s) = try await busyWithTwoQueued()
        let second = try #require(s.queuedMessages.first?.id)
        #expect(s.canEditQueued(second))
        #expect(s.beginQueuedEdit(second) == "second")
        #expect(s.queueEditingId == second)
        #expect(s.queuedMessages.count == 2, "the row keeps its place while it is edited")
        await endTurn(h)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(h.client.calls("prompt.submit").count == 1, "the row being edited, and the rows behind it, wait")

        #expect(s.saveQueuedEdit(second, text: "second, edited"))
        #expect(s.queueEditingId == nil)
        #expect(await waitUntil { h.client.calls("prompt.submit").count == 2 })
        #expect(h.client.calls("prompt.submit").last?.params["text"] == "second, edited", "same place, new words")
        #expect(s.queuedMessages.map(\.text) == ["third"])
    }

    @Test func cancelLeavesTheRowAsItWasAndTheQueueGoesOn() async throws {
        let (h, s) = try await busyWithTwoQueued()
        let third = try #require(s.queuedMessages.last?.id)
        #expect(s.beginQueuedEdit(third) == "third")
        // Another row can't be edited meanwhile.
        #expect(s.beginQueuedEdit(try #require(s.queuedMessages.first?.id)) == nil)
        s.endQueuedEdit()
        #expect(s.queueEditingId == nil)
        #expect(s.queuedMessages.map(\.text) == ["second", "third"])
        await endTurn(h)
        #expect(await waitUntil { h.client.calls("prompt.submit").count == 2 })
        #expect(h.client.calls("prompt.submit").last?.params["text"] == "second")
    }

    @Test func onlyTypedWordsCanBeEdited() {
        #expect(LiveChatSession.editable(QueuedMessage(id: "a", text: "words")))
        #expect(!LiveChatSession.editable(QueuedMessage(id: "b", text: "goal", hidden: true, display: "/goal resume")))
        #expect(!LiveChatSession.editable(QueuedMessage(id: "c", text: "skill body", display: "/review x")))
        #expect(!LiveChatSession.editable(QueuedMessage(id: "d", text: "", memo: MemoFile(path: "/x.m4a", seconds: 2, peaks: [], mime: "audio/x-m4a"))))
    }

    @Test func theRowsWords() {
        #expect(ChatQueueCard.rowText(QueuedMessage(id: "a", text: "  ")) == ("Empty Message", true))
        #expect(ChatQueueCard.rowText(QueuedMessage(id: "b", text: "hi\nthere")) == ("hi there", false))
        #expect(QueueWords.caption(sending: true, editing: false, attached: "Photo") == "Sending…")
        #expect(QueueWords.caption(sending: false, editing: true, attached: nil) == "Editing")
        #expect(QueueWords.caption(sending: false, editing: false, attached: "2 Photos") == "2 Photos")
        #expect(QueueWords.caption(sending: false, editing: false, attached: nil) == nil)
        #expect(QueueWords.moreLabel("Fix the typo") == "More, Fix the typo")
        #expect(QueueWords.moreLabel("") == "More")
        #expect(QueueWords.moreLabel(String(repeating: "a", count: 50)) == "More, " + String(repeating: "a", count: 40) + "…")
    }

    @Test func whileEditingTheCircleIsSave() {
        func pick(hasText: Bool, running: Bool) -> ComposerView.Primary {
            ComposerView.choosePrimary(memoSend: nil, enabled: false, preparing: false, hasText: hasText, attachments: 0,
                                       memoChip: false, dictating: false, running: running, talkAvailable: true, editingQueued: true)
        }
        #expect(pick(hasText: true, running: true) == .send, "Save, even offline; Stop waits behind it")
        #expect(pick(hasText: false, running: true) == .disabled)
    }

    /// Tester 2026-11-08: the strip's Cancel and Save were squeezed to 44 pt, one or two letters a line
    /// ("Ca / nc / el"). Each keeps its word on one line at a phone's width, at every text size up to the largest.
    @Test(arguments: [UIContentSizeCategory.large, .extraExtraExtraLarge, .accessibilityExtraExtraExtraLarge], [320.0, 361.0, 402.0])
    func cancelAndSaveKeepTheirWordsOnOneLine(size: UIContentSizeCategory, width: CGFloat) throws {
        let banner = ComposerEditBanner.editingQueued()
        banner.traitOverrides.preferredContentSizeCategory = size
        // As in the composer: added with no width first, laid out narrow, then given the row's width.
        for early in [CGFloat(0), 120] {
            banner.frame = CGRect(x: 0, y: 0, width: early, height: 44)
            banner.layoutIfNeeded()
        }
        let fitted = banner.systemLayoutSizeFitting(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                                                    withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        banner.frame = CGRect(x: 0, y: 0, width: width, height: max(44, ceil(fitted.height)))
        banner.layoutIfNeeded()
        func find(_ id: String, in view: UIView) -> UIView? {
            view.accessibilityIdentifier == id ? view : view.subviews.lazy.compactMap { find(id, in: $0) }.first
        }
        for (id, word) in [("composer.editingQueued.cancel", "Cancel"), ("composer.editingQueued.save", "Save")] {
            let button = try #require(find(id, in: banner) as? UIButton)
            let label = try #require(button.titleLabel)
            let font = try #require(label.font)
            let one = ceil((word as NSString).size(withAttributes: [.font: font]).width)
            #expect(label.bounds.width >= one - 1, "\(word) at \(size.rawValue), \(width) pt: \(label.bounds.width) < \(one)")
            #expect(label.bounds.height < font.lineHeight * 1.6, "\(word) wrapped at \(size.rawValue), \(width) pt")
        }
    }

    /// The same in the composer itself, in a window, as Edit puts it there (the field's words after the strip).
    @Test(arguments: [320.0, 393.0, 440.0])
    func cancelAndSaveKeepTheirWordsInTheComposer(width: CGFloat) throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 800))
        let composer = ComposerView(frame: .zero)
        window.addSubview(composer)
        window.isHidden = false
        composer.frame = CGRect(x: 0, y: 600, width: width, height: 120)
        composer.layoutIfNeeded()
        let banner = ComposerEditBanner.editingQueued()
        composer.editBanner = banner
        composer.editingQueued = true
        composer.text = "fix the typo"
        composer.frame.size.height = composer.intrinsicContentSize.height
        window.layoutIfNeeded()
        composer.layoutIfNeeded()
        func find(_ id: String, in view: UIView) -> UIView? {
            view.accessibilityIdentifier == id ? view : view.subviews.lazy.compactMap { find(id, in: $0) }.first
        }
        for (id, word) in [("composer.editingQueued.cancel", "Cancel"), ("composer.editingQueued.save", "Save")] {
            let button = try #require(find(id, in: banner) as? UIButton)
            let label = try #require(button.titleLabel)
            let font = try #require(label.font)
            let one = ceil((word as NSString).size(withAttributes: [.font: font]).width)
            #expect(label.bounds.width >= one - 1, "\(word) at \(width) pt: \(label.bounds.width) < \(one); button \(button.frame)")
            #expect(label.bounds.height < font.lineHeight * 1.6, "\(word) wrapped at \(width) pt: \(label.frame)")
        }
    }
}
