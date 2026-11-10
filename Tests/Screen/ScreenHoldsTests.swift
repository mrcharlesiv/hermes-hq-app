// Who held control, remembered (docs/spec/3x-screen.md §5.8): the reclaim rule, the saved hold and its 24 hours, the
// leaving cases, the gateway's remembered kind.

import Foundation
import Testing
@testable import HermesHQNative

@MainActor struct ScreenHoldsTests {
    private final class Clock { var date = Date(timeIntervalSince1970: 1_800_000_000) }

    private func make() -> (ScreenHolds, UserDefaults, Clock) {
        let name = "screen-holds-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let clock = Clock()
        return (ScreenHolds(defaults: defaults, now: { clock.date }), defaults, clock)
    }

    private func viewer(_ id: String) -> ScreenViewer { ScreenViewer(id: id) }
    private func human(_ viewer: ScreenViewer, epoch: Int = 3) -> ScreenLease { ScreenLease(holder: .human, viewerHash: viewer.hash, epoch: epoch) }

    @Test func reclaimOnlyWhenTheLeaseNamesAnIdThisAppHeld() {
        let prior = viewer("prior"), minted = viewer("minted"), own = viewer("own"), stranger = viewer("stranger")
        #expect(ScreenHolds.shouldReclaim(prior: prior, minted: minted, lease: human(prior), own: nil))
        #expect(ScreenHolds.shouldReclaim(prior: nil, minted: minted, lease: human(own), own: own))
        #expect(!ScreenHolds.shouldReclaim(prior: prior, minted: minted, lease: human(stranger), own: own))
        #expect(!ScreenHolds.shouldReclaim(prior: prior, minted: minted, lease: human(minted), own: own))       // already ours
        #expect(!ScreenHolds.shouldReclaim(prior: prior, minted: minted, lease: ScreenLease(holder: .agent, viewerHash: nil, epoch: 4), own: own))
        #expect(!ScreenHolds.shouldReclaim(prior: prior, minted: minted, lease: ScreenLease(holder: .human, viewerHash: nil, epoch: 4), own: own))
        #expect(!ScreenHolds.shouldReclaim(prior: prior, minted: minted, lease: nil, own: own))
        #expect(!ScreenHolds.shouldReclaim(prior: nil, minted: minted, lease: human(prior), own: nil))
    }

    @Test func heldBeforeNeedsTheLeaseToStillNameTheSavedHold() {
        let old = viewer("old")
        let saved = SavedHold(id: old.id, hash: old.hash, at: 0)
        #expect(ScreenHolds.heldBefore(saved: saved, lease: human(old), viewer: viewer("new")) == saved)
        #expect(ScreenHolds.heldBefore(saved: saved, lease: human(old), viewer: nil) == saved)
        #expect(ScreenHolds.heldBefore(saved: saved, lease: human(old), viewer: old) == nil)                     // this attach holds it
        #expect(ScreenHolds.heldBefore(saved: saved, lease: human(viewer("other")), viewer: viewer("new")) == nil)
        #expect(ScreenHolds.heldBefore(saved: saved, lease: ScreenLease(holder: .agent, viewerHash: nil, epoch: 9), viewer: nil) == nil)
        #expect(ScreenHolds.heldBefore(saved: nil, lease: human(old), viewer: nil) == nil)
        #expect(ScreenHolds.heldBefore(saved: saved, lease: nil, viewer: nil) == nil)
    }

    @Test func leavingHandsBackHoweverControlIsHeld() {
        let mine = viewer("mine")
        let saved = SavedHold(id: "old", hash: ScreenWire.viewerHash("old"), at: 0)
        #expect(ScreenHolds.leave(holding: true, streamOpen: true, viewer: mine, saved: saved) == .closeHandsBack)
        #expect(ScreenHolds.leave(holding: true, streamOpen: false, viewer: mine, saved: saved) == .release(id: "mine"))
        #expect(ScreenHolds.leave(holding: false, streamOpen: true, viewer: mine, saved: saved) == .release(id: "old"))
        #expect(ScreenHolds.leave(holding: false, streamOpen: false, viewer: mine, saved: nil) == .nothing)
        #expect(ScreenHolds.leave(holding: true, streamOpen: false, viewer: nil, saved: nil) == .nothing)
    }

    @Test func aHoldIsSavedAndReadBackForADayThenForgotten() {
        let (holds, defaults, clock) = make()
        let mine = viewer("abc123")
        holds.note(lease: human(mine), viewer: mine, account: "acct", profile: "default")
        #expect(holds.own("acct", "default") == mine)
        #expect(holds.saved("acct", "default") == SavedHold(id: mine.id, hash: mine.hash, at: 1_800_000_000))
        #expect(holds.saved("acct", "writer") == nil && holds.saved("other", "default") == nil)
        // Stored as {"id","hash","at"}.
        let stored = try? JSONSerialization.jsonObject(with: Data((defaults.string(forKey: "hq.screen.held.acct.default") ?? "").utf8)) as? [String: Any]
        #expect(Set(stored?.keys.map { $0 } ?? []) == ["id", "hash", "at"])
        clock.date += 23 * 3600 + 3540
        #expect(holds.saved("acct", "default") != nil)                       // 23 h 59 m
        clock.date += 120
        #expect(holds.saved("acct", "default") == nil)                       // 24 h 1 m
        #expect(defaults.object(forKey: "hq.screen.held.acct.default") == nil)
    }

    @Test func aBadSavedHoldIsIgnoredAndCleared() {
        let (holds, defaults, _) = make()
        let key = "hq.screen.held.acct.default"
        for bad in ["not json", "{}", #"{"id":"","hash":"","at":1}"#, #"{"id":"abc","hash":"zzz","at":1800000000}"#, #"{"id":1,"hash":2,"at":"x"}"#, "[1,2]"] {
            defaults.set(bad, forKey: key)
            #expect(holds.saved("acct", "default") == nil, "\(bad)")
            #expect(defaults.object(forKey: key) == nil)
        }
        defaults.set(42, forKey: key)
        #expect(holds.saved("acct", "default") == nil)
        defaults.set(Data([1, 2, 3]), forKey: key)
        #expect(holds.saved("acct", "default") == nil)
        #expect(defaults.object(forKey: key) == nil)
        // A hold dated in the future (a clock change) is not trusted either.
        let id = "future"
        defaults.set(#"{"id":"future","hash":"\#(ScreenWire.viewerHash(id))","at":1900000000}"#, forKey: key)
        #expect(holds.saved("acct", "default") == nil)
    }

    @Test func theSavedHoldEndsWhenTheLeaseIsSomeoneElses() {
        let (holds, _, _) = make()
        let mine = viewer("mine")
        holds.note(lease: human(mine), viewer: mine, account: "a", profile: "p")
        // A status with no viewer of ours yet (a relaunch): the saved hold stays while the lease names it.
        holds.note(lease: human(mine, epoch: 4), viewer: nil, account: "a", profile: "p")
        #expect(holds.saved("a", "p") != nil)
        // Another person took it.
        holds.note(lease: human(viewer("other"), epoch: 5), viewer: viewer("new"), account: "a", profile: "p")
        #expect(holds.saved("a", "p") == nil)
        #expect(holds.own("a", "p") == mine)                                 // this run still knows what it held
        // The bot has it: nothing left to reclaim.
        holds.note(lease: human(mine, epoch: 6), viewer: mine, account: "a", profile: "p")
        holds.note(lease: ScreenLease(holder: .agent, viewerHash: nil, epoch: 7), viewer: mine, account: "a", profile: "p")
        #expect(holds.saved("a", "p") == nil && holds.own("a", "p") == nil)
        holds.note(lease: nil, viewer: mine, account: "a", profile: "p")
        #expect(holds.saved("a", "p") == nil)
    }

    @Test func theNewestHoldReplacesTheOlder() {
        let (holds, _, _) = make()
        let first = viewer("first"), second = viewer("second")
        holds.note(lease: human(first), viewer: first, account: "a", profile: "p")
        holds.note(lease: human(second, epoch: 9), viewer: second, account: "a", profile: "p")
        #expect(holds.own("a", "p") == second && holds.saved("a", "p")?.id == "second")
        holds.forget("a", "p")
        #expect(holds.saved("a", "p") == nil)
    }

    @Test func theGatewaysKindAndTheRotateHintAreRemembered() {
        let (holds, defaults, _) = make()
        #expect(holds.rememberedKind("acct") == nil)
        holds.rememberKind(.unknown, "acct")
        #expect(holds.rememberedKind("acct") == nil)
        holds.rememberKind(.screenshots, "acct")
        #expect(holds.rememberedKind("acct") == .screenshots && holds.rememberedKind("other") == nil)
        holds.rememberKind(.live, "acct")
        #expect(holds.rememberedKind("acct") == .live)
        defaults.set("nonsense", forKey: "hq.screen.kind.acct")
        #expect(holds.rememberedKind("acct") == nil)
        #expect(!holds.rotateHintSeen)
        holds.rotateHintSeen = true
        #expect(holds.rotateHintSeen && defaults.bool(forKey: "hq.screen.rotateHintSeen"))
    }
}
