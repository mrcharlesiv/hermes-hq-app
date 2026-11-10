// [share] docs/spec/3x-share.md §7.2 check 5, §7.10 check 1: the sheet's decisions.

import Foundation
import Testing
@testable import HermesHQNative

@Suite struct ShareSheetStateTests {
    private func bot(_ profile: String, active: Double? = nil, session: String = "s_1") -> ShareBot {
        ShareSamples.bot(profile, name: profile.capitalized, session: session, lastActive: active)
    }

    @Test func mostRecentlyActiveFirst() {
        let bots = [bot("a", active: 10), bot("b", active: 30), bot("c"), bot("d", active: 30), bot("e", active: 20), bot("f"), bot("g", active: 0)]
        #expect(ShareSheetState.ordered(bots).map(\.profile) == ["b", "d", "e", "a", "c", "f", "g"])       // ties and no time keep roster order
        #expect(ShareSheetState.ordered([]).isEmpty)
        let same = [bot("x"), bot("y"), bot("z")]
        #expect(ShareSheetState.ordered(same).map(\.profile) == ["x", "y", "z"])
        // Hermes last active before Ivy: Ivy is listed first (§7.2 check 1).
        #expect(ShareSheetState.ordered([bot("default", active: 100), bot("ivy", active: 200)]).map(\.profile) == ["ivy", "default"])
    }

    @Test func whoStartsChosen() {
        let ivy = bot("ivy", active: 200), hermes = bot("default", active: 100), fresh = bot("fresh", active: 300, session: "")
        let bots = ShareSheetState.ordered([hermes, ivy, fresh])
        #expect(bots.map(\.profile) == ["fresh", "ivy", "default"])
        #expect(ShareSheetState.selection(bots: bots, remembered: nil) == "ios-direct::ivy")               // the first that can receive
        #expect(ShareSheetState.selection(bots: bots, remembered: "") == "ios-direct::ivy")
        #expect(ShareSheetState.selection(bots: bots, remembered: "ios-direct::default") == "ios-direct::default")
        #expect(ShareSheetState.selection(bots: bots, remembered: "legacy::default") == "ios-direct::default")   // D6: build 240's key
        #expect(ShareSheetState.selection(bots: bots, remembered: "legacy::ivy") == "ios-direct::ivy")
        #expect(ShareSheetState.selection(bots: bots, remembered: "default") == "ios-direct::default")
        #expect(ShareSheetState.selection(bots: bots, remembered: "ios-direct::gone") == "ios-direct::ivy")
        // A remembered bot that can no longer receive is skipped (§7.10 check 1).
        #expect(ShareSheetState.selection(bots: bots, remembered: "ios-direct::fresh") == "ios-direct::ivy")
        #expect(ShareSheetState.selection(bots: [fresh], remembered: "ios-direct::fresh") == nil)
        #expect(ShareSheetState.selection(bots: [], remembered: "ios-direct::ivy") == nil)
    }

    @Test func aBotNeedsItsOwnChat() {
        #expect(bot("ivy").canReceive)
        #expect(!bot("ivy", session: "").canReceive)
        #expect(!bot("ivy", session: "a/b").canReceive)
        #expect(!bot("ivy", session: String(repeating: "a", count: 161)).canReceive)
        #expect(bot("ivy", session: String(repeating: "a", count: 160)).canReceive)
        #expect(!ShareBot(key: "ios-direct::a b", name: "A", profile: "a b", session: "s_1").canReceive)
        #expect(bot("ivy").initial == "I")
        #expect(ShareBot(key: "k", name: "  émile", profile: "e", session: "s").initial == "É")
        #expect(ShareBot(key: "k", name: "", profile: "e", session: "s").initial == "?")
    }

    @Test func whenSendIsAllowed() {
        let able = bot("ivy"), unable = bot("ivy", session: "")
        #expect(ShareSheetState.canSend(ready: true, selected: able, hasContent: true, oversized: 0))
        #expect(!ShareSheetState.canSend(ready: false, selected: able, hasContent: true, oversized: 0))      // still preparing, sending, blocked
        #expect(!ShareSheetState.canSend(ready: true, selected: nil, hasContent: true, oversized: 0))
        #expect(!ShareSheetState.canSend(ready: true, selected: unable, hasContent: true, oversized: 0))
        #expect(!ShareSheetState.canSend(ready: true, selected: able, hasContent: false, oversized: 0))
        #expect(!ShareSheetState.canSend(ready: true, selected: able, hasContent: true, oversized: 1))
        // Something to send: one typed character, or one readable item.
        #expect(!ShareSheetState.hasContent(message: "", items: 0))
        #expect(!ShareSheetState.hasContent(message: " \n\t", items: 0))
        #expect(ShareSheetState.hasContent(message: "a", items: 0))
        #expect(ShareSheetState.hasContent(message: "", items: 1))
    }

    @Test func progressWords() {
        #expect(ShareSheetState.label(.connecting) == "Connecting…")
        #expect(ShareSheetState.label(.uploading(1, 1)) == "Uploading…")
        #expect(ShareSheetState.label(.uploading(2, 5)) == "Uploading 2 of 5…")
        #expect(ShareSheetState.label(.sending) == "Sending…")
        #expect(ShareSheetState.sent(to: "Ivy") == "Sent to Ivy")
        #expect(ShareSheetState.preparing == "Preparing…")
        #expect(ShareSheetState.title == "Hermes HQ" && ShareSheetState.placeholder == "Add a message" && ShareSheetState.sendTo == "Send to")
        #expect(ShareSheetState.messagePlaceholder(imagesOnly: true) == ShareRules.defaultQuestion, "photos alone: the question they go with")
        #expect(ShareSheetState.messagePlaceholder(imagesOnly: false) == "Add a message")
        #expect(ShareSheetState.botsHeader(gateway: nil) == "Send to" && ShareSheetState.botsHeader(gateway: "  ") == "Send to")
        #expect(ShareSheetState.botsHeader(gateway: "Office Mac") == "Send to · Office Mac")
        #expect(ShareSheetState.photoPrivacy == "Sent without location or camera details")
        #expect(ShareSheetState.blockedTitle == "Can’t Share Yet" && ShareSheetState.tryAgain == "Try Again")
        #expect(ShareSheetState.noBots == "Open Hermes HQ once so your bots appear here.")
        #expect(ShareSheetState.unreadable("broken.mov") == "Hermes HQ couldn’t read “broken.mov”.")
        #expect(ShareSheetState.oversized("big.bin", limit: 33_554_432) == "“big.bin” is larger than 32 MB, your attachment limit.")
        #expect(ShareSheetState.oversized("big.bin", limit: 8 * 1024 * 1024) == "“big.bin” is larger than 8 MB, your attachment limit.")
    }

    @Test func moreThanAShareTakesSaysWhatWasKept() {
        #expect(ShareSheetState.overCap(ShareSkipped()) == nil)
        #expect(ShareSheetState.overCap(ShareSkipped(photos: 1, files: 0)) == "Only the first 10 photos are sent.")
        #expect(ShareSheetState.overCap(ShareSkipped(photos: 0, files: 3)) == "Only the first 10 files are sent.")
        #expect(ShareSheetState.overCap(ShareSkipped(photos: 2, files: 2)) == "Only the first 10 photos and 10 files are sent.")
    }

    @Test func aBotsSecondLine() {
        let now = Date(timeIntervalSince1970: 1_800_000_000), english = Locale(identifier: "en_US")
        #expect(ShareSheetState.subtitle(bot("ivy", session: ""), now: now, locale: english) == "Open this bot in Hermes HQ first")
        #expect(ShareSheetState.subtitle(bot("ivy"), now: now, locale: english) == "Bot Chat")
        #expect(ShareSheetState.subtitle(bot("ivy", active: 0), now: now, locale: english) == "Bot Chat")
        #expect(ShareSheetState.subtitle(bot("ivy", active: 1_800_000_000 - 300), now: now, locale: english) == "Active 5 min. ago")
        #expect(ShareSheetState.subtitle(bot("ivy", active: 1_800_000_000 - 7200), now: now, locale: english) == "Active 2 hr. ago")
        #expect(ShareSheetState.subtitle(bot("ivy", active: 1_800_000_000 - 3 * 86_400), now: now, locale: english) == "Active 3 days ago")
        // A chat stamped a little ahead of this phone's clock is never "in 3 sec.".
        let ahead = ShareSheetState.subtitle(bot("ivy", active: 1_800_000_000 + 3), now: now, locale: english)
        #expect(ahead.hasPrefix("Active ") && !ahead.contains("in 3"))
        // A bot that cannot receive says why, whatever its time.
        #expect(ShareSheetState.subtitle(bot("ivy", active: 1_799_999_000, session: ""), now: now, locale: english) == ShareSheetState.noChat)
        #expect(ShareSheetState.spoken(bot("ivy", session: ""), now: now) == "Ivy, Open this bot in Hermes HQ first")
    }
}
