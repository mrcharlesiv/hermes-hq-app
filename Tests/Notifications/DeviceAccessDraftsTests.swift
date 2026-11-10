// [device-access] Email & Text Drafts for Device Access: the pure plan/expiry/wording rules
// (HermesKit/Device/DeviceAccess+Drafts.swift), and a live round trip through DraftsAccess (no iOS permission is
// ever needed for this kind, so this always runs, cleaning up the draft it makes).

import Foundation
import Testing
@testable import HermesHQNative

@MainActor struct DeviceAccessDraftsTests {
    private let id = String(repeating: "a", count: 32)

    private func request(_ args: [String: JSONValue] = [:]) -> DeviceAccess.Request {
        DeviceAccess.Request(id: id, op: "drafts.create", args: args)
    }

    private func draft(_ suffix: String = "a") -> DeviceAccess.Draft {
        DeviceAccess.Draft(id: String(repeating: suffix, count: 32), kind: "email", to: ["Ann"], cc: [], subject: nil,
                          body: "hello", bot: "", createdAt: .now)
    }

    @Test func draftPlanNeedsAKnownKindSomeoneToSendToAndWords() {
        let good = DeviceAccess.draftPlan(request(["kind": "email", "to": ["Ann"], "body": "Hi there"]))
        #expect(good?.kind == "email" && good?.to == ["Ann"] && good?.body == "Hi there" && good?.cc == [])
        #expect(DeviceAccess.draftPlan(request(["kind": "fax", "to": ["Ann"], "body": "Hi"])) == nil, "bad kind")
        #expect(DeviceAccess.draftPlan(request(["kind": "email", "to": [], "body": "Hi"])) == nil, "no recipient")
        #expect(DeviceAccess.draftPlan(request(["kind": "email", "to": ["Ann"]])) == nil, "no words")
        #expect(DeviceAccess.draftPlan(request(["kind": "text", "to": ["Ann"], "body": "Hi", "subject": "Ignored"]))?.subject == nil,
                "a text draft carries no subject")
    }

    @Test func bodyIsCutTo10000Characters() {
        let plan = DeviceAccess.draftPlan(request(["kind": "email", "to": ["Ann"], "body": .string(String(repeating: "x", count: 20_000))]))
        #expect(plan?.body.count == 10_000)
    }

    @Test func liveDraftsAreNewestFirstAndCappedAtTwenty() {
        var drafts: [DeviceAccess.Draft] = []
        let now = Date()
        for i in 0..<25 {
            let one = DeviceAccess.Draft(id: "d\(i)", kind: "email", to: ["Ann"], cc: [], subject: nil, body: "x",
                                        bot: "", createdAt: now.addingTimeInterval(Double(i)))
            drafts = DeviceAccess.liveDrafts(drafts, adding: one, now: now)
        }
        #expect(drafts.count == 20)
        #expect(drafts.first?.id == "d24", "newest first")
        #expect(!drafts.contains { $0.id == "d0" }, "the oldest were dropped past the cap")
    }

    @Test func liveDraftsDropAnythingPast24Hours() {
        let now = Date()
        let old = DeviceAccess.Draft(id: "old", kind: "email", to: ["Ann"], cc: [], subject: nil, body: "x", bot: "",
                                    createdAt: now.addingTimeInterval(-25 * 3600))
        let fresh = DeviceAccess.Draft(id: "fresh", kind: "email", to: ["Ann"], cc: [], subject: nil, body: "x", bot: "", createdAt: now)
        let kept = DeviceAccess.liveDrafts([old, fresh], now: now)
        #expect(kept.map(\.id) == ["fresh"])
    }

    @Test func notificationWordsNameTheBotAndTheKind() {
        #expect(DeviceAccess.draftNotificationTitle(kind: "email", bot: "") == "Hermes wrote an email")
        #expect(DeviceAccess.draftNotificationTitle(kind: "text", bot: "Otto") == "Otto wrote a text message")
        #expect(DeviceAccess.draftNotificationBody(to: ["Ann"], body: "Can you look at the budget tonight before the call starts") ==
                "To Ann: Can you look at the budget tonight before…")
        #expect(DeviceAccess.draftNotificationBody(to: ["Ann", "Max"], body: "Hi") == "To Ann & 1 more: Hi")
    }

    // MARK: Live (no permission is ever needed for this kind)

    @Test func liveCreateAndDiscard() async {
        let answer = await DraftsAccess.answer(request(["kind": "email", "to": ["Ann"], "body": "Hi Ann"]), scopes: ["email"])
        #expect(answer.status == .done)
        #expect(answer.result["draft"]?.string == "waiting" && answer.result["kind"]?.string == "email")
        #expect(DraftsStore.find(id) != nil)
        DraftsStore.discard(id)
        #expect(DraftsStore.find(id) == nil)
    }

    @Test func liveScopeOffAndBadRequestsAreRefused() async {
        let scopeOff = await DraftsAccess.answer(request(["kind": "text", "to": ["Ann"], "body": "Hi"]), scopes: ["email"])
        #expect(scopeOff.status == .unavailable)
        let bad = await DraftsAccess.answer(request(["kind": "email", "to": [], "body": "Hi"]), scopes: ["email"])
        #expect(bad.status == .failed)
    }

    #if targetEnvironment(macCatalyst)
    @Test func liveTextIsUnavailableOnTheMac() async {
        let answer = await DraftsAccess.answer(request(["kind": "text", "to": ["Ann"], "body": "Hi"]), scopes: ["text"])
        #expect(answer.status == .unavailable)
        #expect(await DraftsAccess.requestPermission(turningOn: "text") == false)
    }
    #endif
}
