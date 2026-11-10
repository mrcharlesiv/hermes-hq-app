import Foundation
import Testing
@testable import HermesHQNative

/// UX study 2026-10-19 #81, #86: Watch Browser and Screen use one pair of words for taking control and giving it back.
@Suite struct ControlWordsTests {
    @Test func onePairForBothViewers() {
        #expect(ControlWords.take == "Take Control" && ControlWords.give == "Give Back")
        #expect(ControlWords.take(held: false) == "Take Control")
        #expect(ControlWords.take(held: true) == "Resume Control")
        #expect(ControlWords.endOther == "End Their Control")
    }

    @Test func noOldWordsAndOneGestureVerb() {
        let all = [ControlWords.take, ControlWords.give, ControlWords.resume, ControlWords.endOther, ControlWords.heldNote,
                   ControlWords.otherNote, ControlWords.browserOther, ControlWords.browserGestures, ControlWords.screenGestures]
        for words in all {
            #expect(!words.contains("Take over") && !words.contains("Hand back") && !words.contains("(force)"), "\(words)")
            #expect(!words.contains("Swipe"), "\(words)")
        }
        #expect(ControlWords.browserGestures.hasPrefix("Drag anywhere") && ControlWords.screenGestures.hasPrefix("Drag anywhere"))
    }

    @Test func notesNameTheButtonsTheyMention() {
        #expect(ControlWords.heldNote.contains(ControlWords.resume))
        #expect(ControlWords.otherNote.contains(ControlWords.endOther))
        // Someone else holds the browser: why, and when control comes back.
        #expect(ControlWords.browserOther == "Another viewer has control. You can take control once they give it back.")
    }
}
