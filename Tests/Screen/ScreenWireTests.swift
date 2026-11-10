// Bot Screen's wire (HermesKit/Screen/ScreenWire.swift): status and lease parsing, the exact params of the five
// calls, the viewer hash, the socket address, old names in gateway text (D27), tone, kind and the screen label.
// Tone / kind / label cases are ported from the web app's bot-screen-labels.test.ts.

import Foundation
import Testing
@testable import HermesHQNative

private func value(_ json: String) -> JSONValue { try! JSONValue.parse(Data(json.utf8)) }

@MainActor
struct ScreenWireTests {
    @Test func gatewayTextNeverCarriesTheOldNames() {
        #expect(ScreenWire.plain("Allow Screen Recording for Dispatch Screen on the Mac") == "Allow Screen Recording for Hermes HQ Screen on the Mac")
        #expect(ScreenWire.plain("  the dispatch-screen plugin is off \n") == "the hermes-hq-screen plugin is off")
        #expect(ScreenWire.plain("DISPATCH SCREEN is paused") == "Hermes HQ Screen is paused")
        #expect(ScreenWire.plain("Open Dispatch to continue") == "Open Hermes HQ to continue")
        #expect(ScreenWire.plain("Nothing to change.") == "Nothing to change.")
        #expect(!ScreenWire.message(RPCError(code: 5300, message: "Dispatch Screen is not running", data: nil)).lowercased().contains("dispatch"))
    }

    @Test func statusParsesWithEveryFieldOptional() throws {
        let full = try #require(ScreenStatus.parse(value("""
        {"profile_key":"default","supported":true,"installed":true,"running":true,"missing":["Xvnc"],"display":"This Mac",
         "geometry":"1920x1080","install_command":"brew install x","blocker":null,"placement":"terminal:docker",
         "lease":{"holder":"human","viewer_hash":"abcdef012345","epoch":4}}
        """)))
        #expect(full.supported && full.installed && full.running && full.isMac && !full.isBlocked)
        #expect(full.lease == ScreenLease(holder: .human, viewerHash: "abcdef012345", epoch: 4))
        #expect(full.missing == ["Xvnc"] && full.placement == "terminal:docker")
        let empty = try #require(ScreenStatus.parse(value("{}")))
        #expect(!empty.supported && !empty.installed && !empty.running && empty.lease == nil && empty.display == nil)
    }

    @Test func wrongShapesAreNoStatusNeverACrash() throws {
        for bad in ["null", "[]", "\"text\"", "7", "true"] { #expect(ScreenStatus.parse(value(bad)) == nil, "\(bad)") }
        #expect(ScreenStatus.parse(nil) == nil)
        let odd = try #require(ScreenStatus.parse(value("{\"lease\":\"x\",\"geometry\":7,\"supported\":\"yes\",\"missing\":\"all\",\"blocker\":5}")))
        #expect(odd.lease == nil && odd.geometry == nil && !odd.supported && odd.missing.isEmpty && odd.blocker == nil)
        #expect(ScreenLease.parse(value("{\"holder\":\"nobody\"}")) == nil)
        #expect(ScreenLease.parse(value("{\"holder\":\"agent\",\"epoch\":-5}"))?.epoch == 0)
        #expect(ScreenLease.parse(value("{\"holder\":\"human\",\"viewer_hash\":\"\"}"))?.viewerHash == nil)
    }

    @Test func blockerIsShownInCurrentWordsAndMarksTheScreenBlocked() throws {
        let status = try #require(ScreenStatus.parse(value("{\"supported\":true,\"installed\":true,\"running\":false,\"blocker\":\"Allow Screen Recording for Dispatch Screen on the Mac\"}")))
        #expect(status.isBlocked)
        #expect(status.blocker == "Allow Screen Recording for Hermes HQ Screen on the Mac")
        var running = status
        running.running = true
        #expect(!running.isBlocked)
    }

    @Test func anOlderLeaseIsIgnored() {
        let held = ScreenLease(holder: .human, viewerHash: "a", epoch: 5)
        #expect(ScreenLease(holder: .agent, epoch: 4).isOlder(than: held))
        #expect(!ScreenLease(holder: .agent, epoch: 5).isOlder(than: held))
        #expect(!ScreenLease(holder: .agent, epoch: 0).isOlder(than: nil))
    }

    @Test func theFiveCallsSendExactlyTheirKeys() {
        func keys(_ value: JSONValue) -> [String] { (value.object ?? [:]).keys.sorted() }
        #expect(keys(ScreenWire.profileParams("ivy")) == ["profile"])
        #expect(keys(ScreenWire.observeParams(profile: "ivy", viewerId: nil)) == ["profile"])
        #expect(keys(ScreenWire.observeParams(profile: "ivy", viewerId: "")) == ["profile"])
        #expect(keys(ScreenWire.observeParams(profile: "ivy", viewerId: "v1")) == ["profile", "viewer_id"])
        #expect(keys(ScreenWire.acquireParams(profile: "ivy", viewerId: "v1")) == ["profile", "viewer_id"])
        #expect(keys(ScreenWire.releaseParams(profile: "ivy", viewerId: "v1", force: false)) == ["profile", "viewer_id"])
        #expect(keys(ScreenWire.releaseParams(profile: "ivy", viewerId: "v1", force: true)) == ["force", "profile", "viewer_id"])
        let bare = ScreenWire.releaseParams(profile: "ivy", viewerId: nil, force: true)
        #expect(keys(bare) == ["force", "profile"] && bare["force"]?.bool == true && bare["profile"]?.string == "ivy")
    }

    @Test func olderHermesWithoutTheCallsIsUnavailable() {
        #expect(ScreenWire.isUnavailable(RPCError(code: -32601, message: "nope", data: nil)))
        #expect(ScreenWire.isUnavailable(RPCError(code: 1, message: "Method not found: display.status", data: nil)))
        #expect(ScreenWire.isUnavailable(RPCError(code: 1, message: "unknown method", data: nil)))
        #expect(!ScreenWire.isUnavailable(RPCError(code: 5300, message: "Bot Desktop is not running", data: nil)))
        #expect(!ScreenWire.isUnavailable(CancellationError()))
    }

    @Test func theViewerHashIsTheFirstTwelveHexOfSHA256() {
        #expect(ScreenWire.viewerHash("abc") == "ba7816bf8f01")
        #expect(ScreenViewer(id: "abc").hash == "ba7816bf8f01")
        let mine = ScreenViewer(id: "abc")
        #expect(ScreenWire.holds(ScreenLease(holder: .human, viewerHash: "ba7816bf8f01", epoch: 1), mine))
        #expect(!ScreenWire.holds(ScreenLease(holder: .human, viewerHash: "000000000000", epoch: 1), mine))
        #expect(!ScreenWire.holds(ScreenLease(holder: .agent, viewerHash: "ba7816bf8f01", epoch: 1), mine))
        #expect(!ScreenWire.holds(nil, mine) && !ScreenWire.holds(ScreenLease(holder: .human, viewerHash: "ba7816bf8f01"), nil))
    }

    @Test func theSocketAddressCarriesOnlyTheTicket() throws {
        let plain = try #require(ScreenWire.displaySocketURL(base: URL(string: "http://127.0.0.1:9940")!, path: "/api/display/ws", ticket: "t-1"))
        #expect(plain.absoluteString == "ws://127.0.0.1:9940/api/display/ws?display_ticket=t-1")
        let secure = try #require(ScreenWire.displaySocketURL(base: URL(string: "https://user:pw@gw.example.test/hermes/?x=1#frag")!, path: "/api/display/ws", ticket: "a b"))
        #expect(secure.scheme == "wss" && secure.path == "/hermes/api/display/ws" && secure.user == nil && secure.fragment == nil)
        #expect(URLComponents(url: secure, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "display_ticket", value: "a b")])
    }

    @Test func aPathOtherThanTheDisplayRouteIsNeverDialled() {
        let base = URL(string: "http://127.0.0.1:9940")!
        for path in ["/api/ws", "//evil.example/api/display/ws", "/api/display/ws/", "api/display/ws", "", "/api/display/ws?x=1", "https://evil.example/api/display/ws"] {
            #expect(ScreenWire.displaySocketURL(base: base, path: path, ticket: "t") == nil, "\(path)")
        }
        #expect(ScreenWire.displaySocketURL(base: base, path: "/api/display/ws", ticket: "") == nil)
        #expect(ScreenWire.displaySocketURL(base: URL(string: "ftp://x.test")!, path: "/api/display/ws", ticket: "t") == nil)
    }

    @Test func observeNeedsATicketAPathAndAViewerId() {
        let ok = ScreenObserved.parse(value("{\"supported\":true,\"installed\":true,\"running\":true,\"ticket\":\"t\",\"path\":\"/api/display/ws\",\"viewer_id\":\"v\"}"))
        #expect(ok?.viewer.id == "v" && ok?.ticket == "t" && ok?.status.running == true)
        #expect(ScreenObserved.parse(value("{\"path\":\"/api/display/ws\",\"viewer_id\":\"v\"}")) == nil)
        #expect(ScreenObserved.parse(value("{\"ticket\":\"t\",\"viewer_id\":\"v\"}")) == nil)
        #expect(ScreenObserved.parse(value("{\"ticket\":\"t\",\"path\":\"/api/display/ws\"}")) == nil)
        #expect(ScreenObserved.parse(value("{\"ticket\":7,\"path\":\"/api/display/ws\",\"viewer_id\":\"v\"}")) == nil)
    }

    @Test func aFailedCallReadsInPlainWordsWithOnePeriod() {
        #expect(ScreenWire.message(RPCError(code: 5300, message: "", data: nil)) == "The gateway refused the request.")
        #expect(ScreenWire.sentence("The screen is busy.") == "The screen is busy.")
        #expect(ScreenWire.sentence("The screen is busy") == "The screen is busy.")
        #expect(ScreenWire.sentence(" Wait... ") == "Wait.")
    }
}

@MainActor
struct ScreenToneTests {
    private func status(_ json: String) -> ScreenStatus { ScreenStatus.parse(value(json))! }

    @Test func toneFollowsTheStatus() {
        let me = ScreenViewer(id: "abc")
        #expect(ScreenWire.tone(unavailable: true, status: nil, viewer: nil) == .unavailable)
        #expect(ScreenWire.tone(unavailable: false, status: nil, viewer: nil) == .unknown)
        #expect(ScreenWire.tone(unavailable: false, status: status("{\"supported\":false}"), viewer: nil) == .unsupported)
        #expect(ScreenWire.tone(unavailable: false, status: status("{\"supported\":true,\"installed\":false}"), viewer: nil) == .missing)
        #expect(ScreenWire.tone(unavailable: false, status: status("{\"supported\":true,\"installed\":true,\"running\":false}"), viewer: nil) == .off)
        let live = "{\"supported\":true,\"installed\":true,\"running\":true"
        #expect(ScreenWire.tone(unavailable: false, status: status(live + "}"), viewer: me) == .live)
        #expect(ScreenWire.tone(unavailable: false, status: status(live + ",\"lease\":{\"holder\":\"agent\",\"epoch\":2}}"), viewer: me) == .live)
        #expect(ScreenWire.tone(unavailable: false, status: status(live + ",\"lease\":{\"holder\":\"human\",\"viewer_hash\":\"ba7816bf8f01\",\"epoch\":2}}"), viewer: me) == .human)
        #expect(ScreenWire.tone(unavailable: false, status: status(live + ",\"lease\":{\"holder\":\"human\",\"viewer_hash\":\"ffffffffffff\",\"epoch\":2}}"), viewer: me) == .other)
        #expect(ScreenWire.tone(unavailable: false, status: status(live + ",\"lease\":{\"holder\":\"human\",\"viewer_hash\":\"ba7816bf8f01\",\"epoch\":2}}"), viewer: nil) == .other)
    }

    // bot-screen-labels.test.ts: "says the neutral View screen until a gateway's answer is known, then what that gateway
    // gave, for every bot on it".
    @Test func theMenuSaysWhatTheGatewayGaveOnceKnown() {
        var remembered: [String: ScreenKind] = [:]
        func label(_ tone: ScreenTone, _ gateway: String) -> String {
            let answer = ScreenWire.kind(tone: tone, remembered: remembered[gateway])
            if let keep = answer.remember { remembered[gateway] = keep }
            return answer.kind.menuTitle
        }
        #expect(label(.unknown, "mac-1") == "View Screen")
        #expect(label(.unsupported, "mac-1") == "Latest Screenshots")
        #expect(label(.unknown, "mac-1") == "Latest Screenshots", "another bot on the same gateway, before its own answer")
        #expect(label(.unknown, "linux-1") == "View Screen")
        for tone in [ScreenTone.live, .off, .missing, .human, .other] { #expect(label(tone, "linux-1") == "Watch Screen") }
        #expect(label(.unknown, "linux-1") == "Watch Screen")
        #expect(label(.unavailable, "old-hermes") == "Latest Screenshots")
    }

    @Test func kindsHaveTheirSymbols() {
        #expect(ScreenKind.screenshots.symbol == "photo.on.rectangle")
        #expect(ScreenKind.live.symbol == "display" && ScreenKind.unknown.symbol == "display")
    }

    @Test func theScreenLabelLeavesOutAnXDisplayNumber() {
        #expect(ScreenWire.screenLabel(nil) == "")
        #expect(ScreenWire.screenLabel(status("{\"display\":\"This Mac\",\"geometry\":\"1920x1080\"}")) == "This Mac · 1920×1080")
        #expect(ScreenWire.screenLabel(status("{\"display\":\":7\",\"geometry\":\"1280x800\"}")) == "1280×800")
        #expect(ScreenWire.screenLabel(status("{\"display\":\":7.0\"}")) == "")
        #expect(ScreenWire.screenLabel(status("{\"display\":\"This Mac\"}")) == "This Mac")
        #expect(ScreenWire.screenLabel(status("{\"display\":\"This Mac\",\"geometry\":\"wide\"}")) == "This Mac · wide")
        #expect(ScreenWire.size("1920x1080")?.width == 1920 && ScreenWire.size("1920x1080")?.height == 1080)
        #expect(ScreenWire.size("0x10") == nil && ScreenWire.size("wide") == nil && ScreenWire.size(nil) == nil)
    }
}
