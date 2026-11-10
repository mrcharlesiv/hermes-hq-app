// Watch Browser's wire (HermesKit/Browser): parsing the plugin's messages, what the phone sends, the card's rules, the
// keyboard slots, the socket address, typing kept through a reconnect, frame decoding off the main thread, and the
// trackpad geometry. Ported from the web app's src/browser-watch/model.test.ts and trackpad.test.ts.

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import HermesHQNative

private let id = "0123456789abcdef01234567"

private func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

private func jpeg(width: Int = 64, height: Int = 36) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, context.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    return data as Data
}

@MainActor
struct BrowserWireTests {
    // MARK: Rows

    @Test func listRowsParseAndUnknownSchemasAreIgnored() throws {
        let list = try JSONValue.parse(json(["schema": "dispatch-browser.list.v3", "browsers": [
            ["id": id, "profile": "wren", "session_id": "s1", "session_ids": ["s0", "s1"], "url": "https://www.example.test/a",
             "busy": 1, "control": "person", "ask": "  Sign in please  ", "agent_at": 100.0, "active": true],
            ["id": "not-an-id", "profile": "wren"],
            ["id": id, "profile": ""],
        ]]))
        let rows = try #require(BrowserRow.parseList(list))
        #expect(rows.count == 1)
        #expect(rows[0].control == .person && rows[0].ask == "Sign in please" && rows[0].sessionIds == ["s0", "s1"])
        #expect(BrowserRow.parseList(try JSONValue.parse(json(["schema": "other", "browsers": []]))) == nil)
    }

    @Test func activeFallsBackToBusyOrARecentBotCall() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let recent = try #require(BrowserRow.parse(try JSONValue.parse(json(["id": id, "profile": "p", "agent_at": 950.0])), now: now))
        let old = try #require(BrowserRow.parse(try JSONValue.parse(json(["id": id, "profile": "p", "agent_at": 800.0])), now: now))
        #expect(recent.active && !old.active)
        #expect(!old.inUse)
        #expect(BrowserCard.statusLine(old) == nil, "an idle bot Chrome is not news")
    }

    @Test func scopeFindsTheBotsNewestBrowserOrOneOfTheChatsOwn() {
        let a = BrowserRow(id: id, profile: "wren", sessionId: "s1", agentAt: 10)
        let b = BrowserRow(id: "abcdefabcdefabcdefabcdef", profile: "wren", sessionId: "s2", sessionIds: ["s3"], agentAt: 20)
        let other = BrowserRow(id: "111111111111111111111111", profile: "ivy", agentAt: 30)
        #expect(BrowserScope(profile: "wren", title: "Wren").row(in: [a, b, other])?.id == b.id)
        #expect(BrowserScope(profile: "wren", sessionIds: ["s1"], title: "Wren").row(in: [a, b, other])?.id == a.id)
        #expect(BrowserScope(profile: "wren", sessionIds: ["s3"], title: "Wren").row(in: [a, b])?.id == b.id)
        #expect(BrowserScope(profile: "wren", sessionIds: ["zz"], title: "Wren").row(in: [a, b]) == nil)
    }

    @Test func theCardStaysForTheRunningTurnAndSaysWhatItNeeds() {
        var idle = BrowserRow(id: id, profile: "wren", url: "https://www.example.test/x")
        let showing = BrowserRow(id: id, profile: "wren", active: true)
        #expect(BrowserCard.row(idle, showing: showing, turnRunning: true)?.active == true, "kept while the turn runs")
        #expect(BrowserCard.row(idle, showing: showing, turnRunning: false) == nil, "gone once the turn ended")
        #expect(BrowserCard.row(nil, showing: nil, turnRunning: true) == nil)
        idle.active = true
        #expect(BrowserCard.words(idle, name: "Wren") == "Browsing example.test")
        idle.ask = "Code please"
        #expect(BrowserCard.words(idle, name: "Wren") == "Wren needs you in its browser")
        idle.control = .person
        #expect(BrowserCard.words(idle, name: "Wren") == "You’re using Wren’s browser")
        idle.url = "about:blank"; idle.ask = nil; idle.control = .bot
        #expect(BrowserCard.words(idle, name: "Wren") == "Using its browser")
    }

    // MARK: The watch socket

    @Test func stateMessagesParseControlTabsAskAndFields() throws {
        let message = try #require(BrowserServerMessage.parse(json([
            "type": "state", "tabs": [["id": "t1", "title": "Example", "url": "https://example.test"], ["id": ""]],
            "tab": "t1", "follow": false, "control": ["state": "person", "mine": true, "epoch": 7], "ask": " ",
            "field": ["under": "password", "focus": "nonsense"],
        ])))
        guard case .state(let state) = message else { Issue.record("not a state"); return }
        #expect(state.tabs.count == 1 && state.currentTab?.title == "Example" && !state.follow)
        #expect(state.control == BrowserControlState(state: .person, mine: true, epoch: 7))
        #expect(state.ask == nil)
        #expect(state.field == BrowserPageFields(under: .password, focus: nil))
        #expect(BrowserServerMessage.parse(json(["type": "state", "tabs": [], "control": ["state": "robot"]])) == nil)
    }

    @Test func boxesThePageOpenedParse() throws {
        func dialog(_ d: Any?) -> BrowserPageDialog? {
            guard case .state(let state)? = BrowserServerMessage.parse(json([
                "type": "state", "tabs": [], "control": ["state": "person", "mine": true, "epoch": 1], "dialog": d ?? NSNull(),
            ])) else { return nil }
            return state.dialog
        }
        let prompt = try #require(dialog(["id": 2, "kind": "prompt", "site": "example.test", "message": " Your name? ", "default": "def",
                                          "title": nil as String? as Any, "accounts": nil as [Any]? as Any]))
        #expect(prompt == BrowserPageDialog(id: 2, kind: .prompt, site: "example.test", message: "Your name?", defaultText: "def",
                                            title: nil, accounts: []))
        #expect(try #require(dialog(["id": 3, "kind": "confirm", "message": "Sure?", "default": "x"])).defaultText == nil)
        let chooser = try #require(dialog(["id": 4, "kind": "accounts", "title": "Sign in to example.test with google.com",
                                           "accounts": [["name": "Alex", "email": "c@example.test"], ["name": "", "email": ""]]]))
        #expect(chooser.accounts == [.init(name: "Alex", email: "c@example.test")])
        #expect(dialog(["id": 5, "kind": "accounts", "accounts": []]) == nil, "a chooser with nobody to pick")
        #expect(try #require(dialog(["id": 6, "kind": "signin_error"])).kind == .signinError)
        #expect(dialog(["id": 7, "kind": "file_picker"]) == nil)
        #expect(dialog(nil) == nil)
    }

    @Test func framesNeedAJpegDataURLAndSaneSizes() throws {
        let image = jpeg()
        let good = "data:image/jpeg;base64," + image.base64EncodedString()
        let message = try #require(BrowserServerMessage.parse(json(["type": "frame", "seq": 3, "tab": "t1", "epoch": 2,
                                                                     "width": 1280, "height": 720, "image": good])))
        guard case .frame(let frame) = message else { Issue.record("not a frame"); return }
        #expect(frame.seq == 3 && frame.width == 1280 && frame.jpeg == image)
        for bad: [String: Any] in [["seq": 0], ["width": 0], ["height": 9000], ["image": "data:image/png;base64,iVBOR"]] {
            var object: [String: Any] = ["type": "frame", "seq": 1, "width": 10, "height": 10, "image": good]
            object.merge(bad) { $1 }
            #expect(BrowserServerMessage.parse(json(object)) == nil)
        }
    }

    @Test func otherServerMessages() {
        if case .ended(let reason)? = BrowserServerMessage.parse(json(["type": "ended"])) { #expect(reason == "closed") } else { Issue.record("ended") }
        if case .copied(let text)? = BrowserServerMessage.parse(json(["type": "copied", "text": "hi"])) { #expect(text == "hi") } else { Issue.record("copied") }
        if case .ping? = BrowserServerMessage.parse(json(["type": "ping"])) {} else { Issue.record("ping") }
        #expect(BrowserServerMessage.parse(Data("not json".utf8)) == nil)
        #expect(BrowserServerMessage.parse(Data(count: BrowserWire.maxMessage + 1)) == nil, "oversized messages are refused")
    }

    @Test func whatThePhoneSendsMatchesThePlugin() throws {
        func object(_ message: BrowserClientMessage, epoch: Int? = nil) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: message.json(epoch: epoch)) as! [String: Any]
        }
        #expect(try object(.hello(viewer: "abc"))["viewer"] as? String == "abc")
        #expect(try object(.view(width: 400, height: 300, scale: 3)) as NSDictionary == ["type": "view", "width": 400, "height": 300, "scale": 3] as NSDictionary)
        #expect(try object(.input(.tap(x: 0.123456, y: 1.5)), epoch: 4) as NSDictionary == ["type": "tap", "x": 0.1235, "y": 1, "epoch": 4] as NSDictionary)
        #expect(try object(.input(.scroll(x: 0.5, y: 0.5, dx: 0, dy: 120)), epoch: 1)["dy"] as? Int == 120)
        #expect(try object(.input(.selectAll), epoch: 1)["type"] as? String == "select_all")
        #expect(try object(.input(.answer(id: 3, accept: true, text: "zed")), epoch: 5) as NSDictionary
                == ["type": "answer", "id": 3, "accept": true, "text": "zed", "epoch": 5] as NSDictionary)
        #expect(try object(.input(.answer(id: 4, accept: true, account: 1)), epoch: 5)["account"] as? Int == 1)
        #expect(try object(.input(.key("Enter")), epoch: 2) as NSDictionary == ["type": "key", "key": "Enter", "epoch": 2] as NSDictionary)
        #expect(try object(.input(.text("secret")), epoch: 2)["text"] as? String == "secret", "typed text goes only to the page")
    }

    @Test func pluginSocketAddressKeepsThePrefixAndPutsTheTicketLast() throws {
        let base = URL(string: "https://mac.example.test/hermes")!
        let url = try #require(BrowserWire.socketURL(base: base, path: "\(BrowserWire.plugin)/sessions/\(id)/watch",
                                                     query: [URLQueryItem(name: "profile", value: "wren"), URLQueryItem(name: "ticket", value: "evil")],
                                                     ticket: "T1"))
        #expect(url.absoluteString == "wss://mac.example.test/hermes/api/plugins/hermes-hq-browser/sessions/\(id)/watch?profile=wren&ticket=T1")
        #expect(BrowserWire.socketURL(base: URL(string: "http://127.0.0.1:9800")!, path: "\(BrowserWire.legacyPlugin)/activity", query: [], ticket: "t")?
            .absoluteString == "ws://127.0.0.1:9800/api/plugins/dispatch-browser/activity?ticket=t")
        #expect(BrowserWire.socketURL(base: base, path: "/api/ws", query: [], ticket: "t") == nil, "only the plugin's routes")
        #expect(BrowserWire.watchPath("../x") == nil)
    }

    @Test func viewerIdIsKeptPerPhone() {
        let defaults = UserDefaults(suiteName: "browser-viewer-test")!
        defaults.removePersistentDomain(forName: "browser-viewer-test")
        let first = BrowserWire.viewerId(defaults: defaults)
        #expect(first.count == 32 && BrowserWire.viewerId(defaults: defaults) == first)
    }

    // MARK: Helpers

    @Test func keyboardSlotsFollowThePageField() {
        #expect(BrowserKeyboard.slot(for: .password).slot == .password)
        #expect(BrowserKeyboard.slot(for: .email) == (.username, .email))
        #expect(BrowserKeyboard.slot(for: .code).slot == .code)
        #expect(BrowserKeyboard.slot(for: .tel) == (.text, .tel))
        #expect(BrowserKeyboard.slot(for: nil) == (.text, .text))
    }

    @Test func pasteIsChunkedAndLineEndingsNormalized() {
        #expect(BrowserKeyboard.pasteChunks("a\r\nb\rc", size: 2) == ["a\n", "b\n", "c"])
        #expect(BrowserKeyboard.pasteChunks(String(repeating: "x", count: 200_000)).count == 50)
        #expect(BrowserKeyboard.pasteChunks("").isEmpty)
    }

    @Test func addresses() {
        let site = BrowserAddress("https://www.example.test/a")
        #expect(site.host == "example.test" && site.secure)
        #expect(!BrowserAddress("http://example.test:8080/").secure && BrowserAddress("http://example.test:8080/").host == "example.test:8080")
        #expect(BrowserAddress("about:blank").host == "New Tab")
        #expect(BrowserAddress("data:text/html,x").host == "Local page")
        #expect(BrowserAddress.url(from: "example.test/path") == "https://example.test/path")
        #expect(BrowserAddress.url(from: "HTTP://x.test") == "HTTP://x.test")
        #expect(BrowserAddress.url(from: "best pizza")?.hasPrefix("https://duckduckgo.com/?q=best%20pizza") == true)
        #expect(BrowserAddress.url(from: "  ") == nil)
    }

    @Test func setupFromHealth() throws {
        let ready = try JSONValue.parse(json(["installed": true, "protocol": 3, "features": ["control": true, "choice": true]]))
        #expect(BrowserHealth.setup(ready) == .ready && BrowserHealth.offersChoice(ready))
        let older = try JSONValue.parse(json(["installed": true, "protocol": 3, "features": ["control": true]]))
        #expect(BrowserHealth.setup(older) == .ready && !BrowserHealth.offersChoice(older), "3.5 and older: no choice shown")
        #expect(BrowserHealth.setup(try JSONValue.parse(json(["installed": false, "protocol": 2]))) == .update)
        #expect(BrowserHealth.setup(try JSONValue.parse(json(["ok": true]))) == .missing)
    }

    /// Tester report 2026-11-05: 3.7.0 switches itself off on Hermes 0.22.6+; reinstalling can't fix that, but
    /// [browser-update] 3.8.0 does: the page says so and offers the update.
    @Test func driftedAddOnIsOffNotOutOfDate() throws {
        let drifted = try JSONValue.parse(#"""
            {"installed": false, "protocol": 3, "missing": null, "drift": ["browser tools unavailable (ImportError)"], "version": "3.7.0"}
            """#.data(using: .utf8)!)
        #expect(BrowserHealth.setup(drifted) == .drift)
        #expect(BrowserHealth.driftWords(drifted) == "browser tools unavailable", "Mac polish #145: no Python error name")
        #expect(BrowserHealth.popupsUpdate(drifted, offered: nil) == nil, "no update offer for an add-on that is off")
        let copy = BrowserEmptyCopy.addOnOff(drifted)
        #expect(copy.title == "Browser Add\u{2011}on Is Off")
        #expect(copy.body == "This version of Hermes changed something the browser add\u{2011}on needs: browser tools unavailable. Add\u{2011}on 3.8.1 fixes this. Update it to watch your bots’ browsers again.")
        #expect(copy.action == .update)
        #expect(BrowserEmptyCopy.updateButton == "Update the Add\u{2011}on")

        // 3.8.1 off all the same: no update to offer, the old words stand.
        let currentOff = try JSONValue.parse(json(["installed": false, "protocol": 3, "drift": ["x changed"], "version": "3.8.1"]))
        #expect(BrowserHealth.setup(currentOff) == .drift)
        #expect(BrowserEmptyCopy.addOnOff(currentOff).body == "This version of Hermes changed something the browser add\u{2011}on needs: x changed. Reinstalling won’t help \u{2014} an add\u{2011}on update for this Hermes is on the way.")
        #expect(BrowserEmptyCopy.addOnOff(currentOff).action == nil)

        // A missing package is still something an install fixes: today's update page.
        let missing = try JSONValue.parse(json(["installed": false, "protocol": 3, "missing": "websockets", "drift": ["browser tools unavailable (ImportError)"]]))
        #expect(BrowserHealth.setup(missing) == .update)
        // An empty drift list, or one from an older protocol, is not drift.
        #expect(BrowserHealth.setup(try JSONValue.parse(json(["installed": false, "protocol": 3, "drift": [String]()]))) == .update)
        #expect(BrowserHealth.setup(try JSONValue.parse(json(["installed": false, "protocol": 2, "drift": ["x"]]))) == .update)
        // A working add-on that notes drift keeps working.
        #expect(BrowserHealth.setup(try JSONValue.parse(json(["installed": true, "protocol": 3, "features": ["control": true], "drift": ["x"]]))) == .ready)
    }

    @Test func driftWordsAreTrimmedJoinedAndCapped() throws {
        let several = try JSONValue.parse(json(["installed": false, "protocol": 3, "drift": ["  first thing.  ", "", "second thing."]]))
        #expect(BrowserHealth.driftWords(several) == "first thing.; second thing")
        let long = try JSONValue.parse(json(["installed": false, "protocol": 3, "drift": [String(repeating: "a", count: 500)]]))
        let words = try #require(BrowserHealth.driftWords(long))
        #expect(words.count == 240 && words.hasSuffix("\u{2026}"))
        // No words as text: still off, and the sentence stands without them.
        let quiet = try JSONValue.parse(json(["installed": false, "protocol": 3, "drift": [1]]))
        #expect(BrowserHealth.setup(quiet) == .drift && BrowserHealth.driftWords(quiet) == nil)
        #expect(BrowserEmptyCopy.addOnOff(quiet).body.hasPrefix("This version of Hermes changed something the browser add\u{2011}on needs. Add\u{2011}on 3.8.1 fixes this."),
                "no version: older than 3.8.1, so the update is offered")
    }

    /// [browser-update] Which browser add-ons the update sheet offers to update, and what counts as on afterwards.
    @Test func browserAddOnNeedFromHealth() throws {
        func health(_ object: [String: Any]) throws -> JSONValue { try JSONValue.parse(json(object)) }
        #expect(BrowserAddOn.wantedVersion == "3.8.1")
        let older = try health(["installed": true, "protocol": 3, "version": "3.7.0", "features": ["control": true]])
        #expect(BrowserAddOn.need(older) == .outdated)
        #expect(BrowserAddOn.need(try health(["installed": true, "protocol": 3, "version": "3.6.10"])) == .outdated)
        #expect(BrowserAddOn.need(try health(["installed": true, "protocol": 3, "version": "3.8.0"])) == .outdated, "3.8.1 fixes the chip's site")
        #expect(BrowserAddOn.need(try health(["installed": true, "protocol": 3, "version": "3.8.1"])) == nil)
        #expect(BrowserAddOn.need(try health(["installed": true, "protocol": 3, "version": "3.10.0"])) == nil, "numeric, not text, compare")
        #expect(BrowserAddOn.need(try health(["installed": true, "protocol": 3, "version": " 3.8.2 "])) == nil)
        #expect(BrowserAddOn.need(try health(["installed": true, "protocol": 3, "version": "4.0"])) == nil)
        // Drift on an older add-on: off, and the update turns it back on.
        let off = try health(["installed": false, "protocol": 3, "version": "3.7.0", "drift": ["browser tools unavailable"]])
        #expect(BrowserAddOn.need(off) == .off)
        // Drift on a current one: nothing an update can do.
        #expect(BrowserAddOn.need(try health(["installed": false, "protocol": 3, "version": "3.8.1", "drift": ["x"]])) == nil)
        // Not this add-on's protocol (the old test plugin): Watch Browser's own page, not this update.
        #expect(BrowserAddOn.need(try health(["installed": false, "protocol": 2, "version": "1.0.0"])) == nil)
        #expect(BrowserAddOn.need(try health(["ok": true])) == nil)
        // A missing package on an older add-on: out of date (the update brings it).
        #expect(BrowserAddOn.need(try health(["installed": false, "protocol": 3, "version": "3.7.0", "missing": "websockets"])) == .outdated)

        // On: this version or newer, installed, no drift.
        #expect(BrowserAddOn.isOn(try health(["installed": true, "protocol": 3, "version": "3.8.1", "drift": [String]()])))
        #expect(BrowserAddOn.isOn(try health(["installed": true, "protocol": 3, "version": "3.8.2"])))
        #expect(!BrowserAddOn.isOn(try health(["installed": true, "protocol": 3, "version": "3.7.0"])), "still the old one")
        #expect(!BrowserAddOn.isOn(try health(["installed": false, "protocol": 3, "version": "3.8.1"])), "not installed")
        #expect(!BrowserAddOn.isOn(try health(["installed": true, "protocol": 3, "version": "3.8.1", "drift": ["x"]])), "drifted")
        #expect(!BrowserAddOn.isOn(try health(["installed": true, "protocol": 3])), "no version")
        // Restarted onto the new add-on: answering at 3.8.1, whatever else it says.
        #expect(BrowserAddOn.restarted(try health(["installed": false, "protocol": 3, "version": "3.8.1", "drift": ["x"]])))
        #expect(!BrowserAddOn.restarted(older))
        #expect(BrowserAddOn.version(try health(["version": "  3.8.1 "])) == "3.8.1")
        #expect(BrowserAddOn.version(try health([:])) == "")
    }

    @Test func popupsUpdateIsOfferedOncePerOlderAddOn() throws {
        let current = try JSONValue.parse(json(["installed": true, "protocol": 3, "version": "3.7.0",
                                                "features": ["control": true, "dialogs": true]]))
        #expect(BrowserHealth.relaysPopups(current))
        #expect(BrowserHealth.popupsUpdate(current, offered: nil) == nil, "3.7 sends popups: nothing to offer")
        let older = try JSONValue.parse(json(["installed": true, "protocol": 3, "version": "3.6.2", "features": ["control": true]]))
        #expect(!BrowserHealth.relaysPopups(older))
        #expect(BrowserHealth.popupsUpdate(older, offered: nil) == "3.6.2")
        #expect(BrowserHealth.popupsUpdate(older, offered: "3.6.2") == nil, "offered already")
        #expect(BrowserHealth.popupsUpdate(older, offered: "3.6.0") == "3.6.2", "a different older version is offered again")
        #expect(BrowserHealth.popupsUpdate(try JSONValue.parse(json(["installed": false, "protocol": 2])), offered: nil) == nil,
                "a plugin that needs replacing has its own screen")
    }

    @Test func emptyCopyExplainsWhy() {
        #expect(BrowserEmptyCopy.noBrowser(.none, name: "Wren").waiting)
        #expect(BrowserEmptyCopy.noBrowser(.some(nil), name: "Wren").body.contains("Update the browser add-on"))
        #expect(BrowserEmptyCopy.noBrowser(.some(OwnBrowser(status: "no_chrome")), name: "Wren").title == "Chrome Isn’t Installed")
        let port = BrowserEmptyCopy.noBrowser(.some(OwnBrowser(status: "port_taken", error: "Port 9222 is busy.")), name: "Wren").body
        #expect(port.hasPrefix("Another app on the computer running Hermes") && port.hasSuffix("\n\nPort 9222 is busy."),
                "plain words first, the plugin's detail under them")
        #expect(!BrowserEmptyCopy.noBrowser(.some(OwnBrowser(status: "config_error")), name: "Wren").body.contains("config.yaml"))
        let off = BrowserEmptyCopy.noBrowser(.some(OwnBrowser(status: "off")), name: "Wren")
        #expect(off.action == .plugins, "switched off: the next step is the bot's Plugins")
        #expect(BrowserEmptyCopy.noBrowser(.some(OwnBrowser(status: "no_chrome")), name: "Wren").action == nil)
    }

    @Test func choiceParsing() throws {
        let value = try JSONValue.parse(json(["schema": "hermes-hq-browser.choice.v1", "profile": "wren", "mode": "copy",
                                              "source": ["dir": "Profile 2", "name": "Work", "account": NSNull()],
                                              "copied_at": 1000.0, "window": "normal", "changeable": true]))
        let choice = try #require(BrowserChoice.parse(value))
        #expect(choice.copy == ChromeProfile(dir: "Profile 2", name: "Work", account: nil))
        #expect(choice.normalWindow && choice.changeable && choice.copiedAt == Date(timeIntervalSince1970: 1000))
        let own = try JSONValue.parse(json(["schema": "hermes-hq-browser.choice.v1", "profile": "wren", "mode": "own", "window": "hidden"]))
        #expect(BrowserChoice.parse(own)?.copy == nil)
        #expect(BrowserChoiceModel.detail(#"{"detail":"That Chrome profile isn't on this computer."}"#) == "That Chrome profile isn't on this computer.")
    }

    @Test func typingIsKeptInOrderWhileReconnectingAndTapsAreNot() {
        var pending = PendingTyping(limit: 2)
        #expect(pending.add(.tap(x: 0, y: 0)) == .ignored)
        #expect(pending.add(.text("a")) == .first)
        #expect(pending.add(.key("Enter")) == .kept)
        #expect(pending.add(.text("b")) == .full)
        #expect(pending.take() == [.text("a"), .key("Enter")])
        #expect(pending.isEmpty)
        #expect(BrowserReconnect.delay(attempt: 1) == 1 && BrowserReconnect.delay(attempt: 4) == 8 && BrowserReconnect.delay(attempt: 9) == 10)
    }

    // MARK: Frames

    @Test func framesDecodeOffTheMainThreadNewestWinsAndStaleOnesDrop() async throws {
        let image = jpeg()
        let decoded = Mutex2<[Int]>([])
        let skipped = Mutex2<[Int]>([])
        let decoder = BrowserFrameDecoder(decoded: { frame, cg in
            #expect(!Thread.isMainThread)
            #expect(cg.width == 64)
            Thread.sleep(forTimeInterval: 0.05)
            decoded.mutate { $0.append(frame.seq) }
        }, skipped: { seq in skipped.mutate { $0.append(seq) } }, failed: {})
        for seq in 1...4 { decoder.push(BrowserFrame(seq: seq, tab: nil, epoch: nil, width: 64, height: 36, jpeg: image)) }
        #expect(!decoder.push(BrowserFrame(seq: 2, tab: nil, epoch: nil, width: 64, height: 36, jpeg: image)), "an older frame drops")
        try await Task.sleep(for: .milliseconds(400))
        #expect(decoded.value == [1, 4], "one decoding, one waiting: 2 and 3 were replaced")
        #expect(skipped.value == [2, 3], "replaced frames are acknowledged unseen")
        #expect(decoder.stats.mainThreadDecodes == 0)
    }

    @Test func anUndecodableFrameEndsTheStream() async throws {
        let failed = Mutex2(false)
        let decoder = BrowserFrameDecoder(decoded: { _, _ in }, skipped: { _ in }, failed: { failed.mutate { $0 = true } })
        decoder.push(BrowserFrame(seq: 1, tab: nil, epoch: nil, width: 1, height: 1, jpeg: Data([0xff, 0xd8, 0, 1, 2])))
        try await Task.sleep(for: .milliseconds(200))
        #expect(failed.value)
        #expect(!decoder.push(BrowserFrame(seq: 2, tab: nil, epoch: nil, width: 1, height: 1, jpeg: Data())), "closed after a failure")
    }

    @Test func pacingSummary() {
        let pacing = BrowserPacing.from(intervals: [0.033, 0.034, 0.033, 0.050], frames: 5, mainThreadDecodes: 0)
        #expect(pacing.summary == "frames=5 p50=34 p95=34 mainDecodes=0" || pacing.summary == "frames=5 p50=33 p95=34 mainDecodes=0")
    }

    // MARK: Trackpad geometry

    @Test func thePageFitsZoomsAboutAPointAndStaysCovering() {
        typealias M = BrowserTrackpadMath
        let stage = CGSize(width: 400, height: 600), page = CGSize(width: 1280, height: 720)
        let fit = M.place(stage: stage, page: page, zoom: 1, x: 0, y: 0)
        #expect(fit.width == 400 && abs(fit.height - 225) < 0.01 && abs(fit.y - 187.5) < 0.01 && fit.x == 0)
        let zoomed = M.zoom(fit, by: 2, about: CGPoint(x: 200, y: 300), stage: stage, page: page)
        #expect(zoomed.zoom == 2 && zoomed.x == -200, "the point under the fingers stays put")
        #expect(M.zoom(fit, by: 10, about: .zero, stage: stage, page: page).zoom == M.maxZoom)
        let panned = M.place(stage: stage, page: page, zoom: 2, x: 500, y: 0)
        #expect(panned.x == 0, "a zoomed page never shows past its edge")
        #expect(M.fraction(CGPoint(x: 200, y: 300), in: fit) == CGPoint(x: 0.5, y: 0.5))
        #expect(M.fraction(CGPoint(x: 10, y: 10), in: fit) == nil)
    }

    @Test func thePointerMovesOneToOneAndScrollFollowsTheFingers() {
        typealias M = BrowserTrackpadMath
        let drawn = CGSize(width: 400, height: 225)
        #expect(M.move(CGPoint(x: 0.5, y: 0.5), dx: 40, dy: -45, drawn: drawn) == CGPoint(x: 0.6, y: 0.3))
        #expect(M.move(CGPoint(x: 0.95, y: 0.5), dx: 400, dy: 0, drawn: drawn).x == 1)
        let scroll = M.scrollDelta(dx: 0, dy: -10, drawn: drawn, page: CGSize(width: 1280, height: 720))
        #expect(scroll.dx == 0 && abs(scroll.dy - 32) < 0.01, "fingers up scroll the page down, in page pixels")
        let view = M.View(zoom: 2, x: -100, y: 0, width: 400, height: 225)
        #expect(M.follow(pointer: CGPoint(x: 0.05, y: 0.5), view: view, stage: CGSize(width: 400, height: 600)).dx > 0)
    }

    @Test func viewSizeIsBounded() {
        #expect(browserViewSize(width: 10, height: 5000, scale: 9) == (64, 2048, 3))
        #expect(browserViewSize(width: .nan, height: 300.4, scale: .infinity) == (64, 300, 1))
    }
}

/// A tiny lock box for test callbacks that run on the decoder's queue.
nonisolated final class Mutex2<Value>: @unchecked Sendable {
    private var stored: Value
    private let lock = NSLock()
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ change: (inout Value) -> Void) { lock.lock(); change(&stored); lock.unlock() }
}
