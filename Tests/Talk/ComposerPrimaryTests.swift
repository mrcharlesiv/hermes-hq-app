// The composer's primary circle (docs/spec/3x-talk.md §5.1): which of Send, Stop, Stop Dictation and Talk shows.
// First match wins, in the table's order.

import Testing
import UIKit
@testable import HermesHQNative

@Suite("Composer primary circle")
struct ComposerPrimaryTests {
    private func pick(memoSend: Bool? = nil, enabled: Bool = true, preparing: Bool = false, hasText: Bool = false, attachments: Int = 0,
                      memoChip: Bool = false, dictating: Bool = false, running: Bool = false, talk: Bool = true) -> ComposerView.Primary {
        ComposerView.choosePrimary(memoSend: memoSend, enabled: enabled, preparing: preparing, hasText: hasText, attachments: attachments,
                                   memoChip: memoChip, dictating: dictating, running: running, talkAvailable: talk)
    }

    @Test func talkShowsOnlyWithNothingToSendAndNothingRunning() {
        #expect(pick() == .talk)
        #expect(pick(talk: false) == .disabled)
        #expect(pick(hasText: true) == .send)
        #expect(pick(attachments: 1) == .send)
        #expect(pick(memoChip: true) == .send)
        #expect(pick(running: true) == .stop)
    }

    @Test func aMemoTakeDecidesFirst() {
        #expect(pick(memoSend: true) == .send)
        #expect(pick(memoSend: false) == .disabled)
        #expect(pick(memoSend: false, hasText: true, running: true) == .disabled)
    }

    @Test func aDisabledComposerShowsNoTalk() {
        #expect(pick(enabled: false) == .disabled)
        #expect(pick(enabled: false, hasText: true) == .disabled)
    }

    @Test func attachmentsStillPreparingHoldTheSend() {
        #expect(pick(preparing: true, attachments: 2) == .disabled)
        #expect(pick(preparing: true, hasText: true) == .disabled)
        // Nothing to send yet: the preparing flag alone does not hide Talk.
        #expect(pick(preparing: true) == .talk)
    }

    // Owner 2026-11-01: a picture in the tray, then Dictate: the circle was Send, and Send took the picture alone (the
    // words weren't in the field yet). While a dictation runs, nothing in the field or the tray makes the circle Send.
    @Test func dictationBeatsEverythingButAMemoTake() {
        #expect(pick(attachments: 1, dictating: true) == .stopDictation)
        #expect(pick(hasText: true, dictating: true, running: true) == .stopDictation)
        #expect(pick(hasText: true, attachments: 2, memoChip: true, dictating: true) == .stopDictation)
        #expect(pick(preparing: true, attachments: 1, dictating: true) == .stopDictation)
        #expect(pick(dictating: true, running: true) == .stopDictation)
        #expect(pick(dictating: true) == .stopDictation)
        // The words typed in, the circle sends them with the picture.
        #expect(pick(hasText: true, attachments: 1) == .send)
    }

    @Test func aRunningReplyBeatsTalk() {
        #expect(pick(running: true, talk: true) == .stop)
    }

    // Stress round 1: a double tap on End ended the conversation and its second tap started a hands-free memo, because
    // the mic came back under the same finger.

    @MainActor @Test func aTouchRightAfterACardLeavesReachesNeitherTheMicNorTheCircle() {
        let composer = ComposerView(frame: CGRect(x: 0, y: 0, width: 390, height: 60))
        let field = composer.textView, circle = composer.primaryView
        #expect(composer.target(for: composer.mic, touchTime: 100) === composer.mic, "nothing is quiet until a card leaves")
        composer.quietActions(now: 100)
        #expect(composer.quietUntil == 100 + ComposerView.quietAfterDock)
        // The second tap of a double tap (its timestamp is the finger's, however late the app gets to it).
        #expect(composer.target(for: composer.mic, touchTime: 100.2) === composer, "the mic records nothing")
        #expect(composer.target(for: circle, touchTime: 100.2) === composer, "the circle starts or sends nothing")
        #expect(composer.target(for: field, touchTime: 100.2) === field, "the field is not affected")
        #expect(composer.target(for: composer.commandsButton, touchTime: 100.2) === composer.commandsButton)
        #expect(composer.target(for: nil, touchTime: 100.2) == nil)
        // A moment later everything works again: no control is left dead.
        let after = 100 + ComposerView.quietAfterDock
        #expect(composer.target(for: composer.mic, touchTime: after) === composer.mic)
        #expect(composer.target(for: circle, touchTime: after + 0.01) === circle)
        // A shorter request never cuts a running one short.
        composer.quietActions(for: 0.1, now: 100.1)
        #expect(composer.quietUntil == 100 + ComposerView.quietAfterDock)
        #expect(ComposerView.quietAfterDock >= 0.5 && ComposerView.quietAfterDock <= 1, "longer than a double tap, short enough not to be felt")
    }

    @MainActor @Test func theCircleTellsAccessibilityItsTouchSize() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let composer = ComposerView(frame: CGRect(x: 0, y: 300, width: 390, height: 60))
        window.addSubview(composer)
        composer.talkAvailable = true
        composer.layoutIfNeeded()
        let frame = composer.primaryView.accessibilityFrame
        #expect(composer.primaryView.bounds.width == 44, "the circle's slot is the bar's height (the circle is drawn 36 in it)")
        #expect(frame.width >= 44 && frame.height >= 44, "\(frame)")
    }

    /// The wiring on a real chat screen: any card leaving the composer's place (the voice dock on End, a notice on
    /// Done, an answered question) makes the mic and the circle quiet for a moment, and only for a moment.
    @MainActor @Test func aCardLeavingTheChatScreenQuietsTheMicAndTheCircle() {
        let chat = ChatViewController(session: SpyChatSession())
        chat.loadViewIfNeeded()
        let composer = chat.composer, mic = composer.mic, circle = composer.primaryView
        func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
        #expect(composer.target(for: mic, touchTime: now()) === mic, "a chat that never had a card is not quiet")
        let dock = TalkBarView(name: "Ivy")
        chat.setDock(dock, for: .voice, animated: false)
        #expect(composer.quietUntil == 0, "a card arriving quiets nothing")
        let before = now()
        chat.setDock(nil, for: .voice, animated: false)   // what End does
        let after = now()
        #expect(composer.quietUntil >= before + ComposerView.quietAfterDock && composer.quietUntil <= after + ComposerView.quietAfterDock)
        // The second tap of a double tap on End: a touch that began a fifth of a second after the first.
        #expect(composer.target(for: mic, touchTime: after + 0.2) === composer, "the mic under End takes no touch")
        #expect(composer.target(for: circle, touchTime: after + 0.2) === composer, "nor does the circle")
        #expect(composer.target(for: composer.textView, touchTime: after + 0.2) === composer.textView)
        #expect(composer.target(for: mic, touchTime: after + ComposerView.quietAfterDock + 0.01) === mic, "and it works again right after")
    }
}
