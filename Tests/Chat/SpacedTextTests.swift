import Foundation
import Testing
@testable import HermesHQNative

/// [updates] A message written with its spaces gone reads with them back; normal text, names and code never change.
struct SpacedTextTests {
    /// As the inbox bot sent it to Hermes (2026-10-27), spaces lost by its model.
    private let broken = "Newrepeatvalidationalertdiagnosed/fixed locally(myownedscript): validation_pending returnedTrue despite "
        + "previouslyverifieddeliveryreceipt because its originalcronfinalpathno longeravailable. This caused testrequestreawakening. "
        + "priority_poll_tick now treats operatorverifiedone-time deliveryreceipt asdurablysettled evenafter schedulerlogretention; "
        + "no fabricateddeliverynewreceipts. Genuinepushstillnotlive; Composio research separate. Alex approved alex@example.com."

    @Test func aBrokenMessageGetsItsSpacesBack() {
        #expect(SpacedText.isBroken(broken))
        let fixed = SpacedText.repair(broken)
        for words in ["New repeat validation alert diagnosed/fixed", "previously verified delivery receipt",
                      "original cron final path", "durably settled", "even after scheduler log retention", "Genuine push still not live"] {
            #expect(fixed.contains(words), "\(words)")
        }
        // Code, names and addresses stay as written.
        for kept in ["validation_pending", "priority_poll_tick", "Composio", "Alex", "alex@example.com"] {
            #expect(fixed.contains(kept), "\(kept)")
        }
        #expect(fixed.contains("returned True"))
    }

    @Test func normalTextIsLeftExactlyAsWritten() {
        let normal = [
            "Northwind and HermesHQ shipped the Composio integration; validation_pending is False. Unfortunately the misunderstanding persisted.",
            "Alex approved the Aurinko OAuth flow at alex@example.com; see cron/output/ac980ee2885a/2026-10-27.md and priority_poll_tick.py.",
            "Internationalization, counterintuitively, is straightforward: thermoregulation and photosynthesis notwithstanding.",
            "The subagent finished: the webhook now fires from the worktree and the TestFlight build is live on iPhone and macOS.",
        ]
        for text in normal { #expect(SpacedText.repair(text) == text) }
    }

    @Test func commonWordsWinAndCompoundsStay() {
        #expect(SpacedText.segment("downloadsnow") == ["downloads", "now"])
        #expect(SpacedText.segment("thenstopped") == ["then", "stopped"])
        #expect(SpacedText.pieces("HermesHQTestFlight") == ["Hermes", "HQ", "Test", "Flight"])
        #expect(SpacedText.pieces("HQdesktopapp") == ["HQ", "desktopapp"])
        #expect(SpacedText.pieces("OAuth") == ["OAuth"] && SpacedText.pieces("UNIONIDs") == ["UNIONIDs"])
    }

    @Test func codeSpansKeepTheirWords() {
        let text = "Fixedthebrokenreceipt and markedtheloopsettled; runs `previouslyverifieddeliveryreceipt` againstthelivequeue now."
        let fixed = SpacedText.repair(text)
        #expect(fixed.contains("`previouslyverifieddeliveryreceipt`"))
        #expect(fixed.contains("Fixed the broken receipt"))
    }
}
