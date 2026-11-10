// Bot Info › Browser for a bot whose browser the plugin doesn't run (hermes-hq-browser 3.6.2): `blocked` and
// `can_take_over` parse, the page says why in plain words, and "Let Hermes HQ Run <Bot>'s Browser" shows only when the
// plugin can take it over. Older plugins (no `blocked`) get a generic sentence and no button.

import Foundation
import Testing
@testable import HermesHQNative

private func choice(_ extra: [String: Any]) throws -> BrowserChoice {
    var object: [String: Any] = ["schema": "hermes-hq-browser.choice.v1", "profile": "wren", "mode": "own", "window": "hidden"]
    object.merge(extra) { $1 }
    return try #require(BrowserChoice.parse(try JSONValue.parse(try JSONSerialization.data(withJSONObject: object))))
}

@MainActor
struct BrowserTakeOverTests {
    @Test func blockedAndCanTakeOverParse() throws {
        let real = try choice(["changeable": false, "blocked": "real_profile", "can_take_over": true])
        #expect(real.blocked == "real_profile" && real.canTakeOver && !real.changeable)
        let ours = try choice(["changeable": true, "blocked": NSNull(), "can_take_over": false])
        #expect(ours.blocked == nil && !ours.canTakeOver && ours.changeable)
        let older = try choice(["changeable": false])
        #expect(older.blocked == nil && !older.canTakeOver, "3.6.1 and older send neither")
        #expect(try choice(["changeable": false, "blocked": ""]).blocked == nil)
    }

    @Test func eachReasonIsExplainedInPlainWords() throws {
        let expected: [String: String] = [
            "real_profile": "Wren is set to use your real Chrome profile through Hermes’s own setting, so Hermes HQ doesn’t run its browser.",
            "released": "Wren’s browser was turned off in its Hermes settings.",
            "no_browser": "Wren doesn’t use a browser. Its browser tools are turned off in Hermes.",
            "remote": "Wren uses a browser on another computer, so Hermes HQ leaves it alone.",
            "camofox": "Wren browses through Camofox, so Hermes HQ leaves it alone.",
        ]
        for (reason, sentence) in expected {
            #expect(BrowserChoiceModel.explanation(try choice(["changeable": false, "blocked": reason]), name: "Wren") == sentence)
        }
        for reason in ["external", "fixed", "off", "starting"] {
            let text = try #require(BrowserChoiceModel.explanation(try choice(["changeable": false, "blocked": reason]), name: "Wren"))
            #expect(text.contains("Wren"), "\(reason): \(text)")
        }
        #expect(BrowserChoiceModel.explanation(try choice(["changeable": false]), name: "Wren")
                == "Hermes HQ doesn’t run Wren’s browser, so its profile and window can’t be changed here.", "an older plugin: generic")
        #expect(BrowserChoiceModel.explanation(try choice(["changeable": true]), name: "Wren") == nil, "a changeable bot: no explanation")
    }

    @Test func theTakeOverButtonShowsOnlyWhenThePluginCanTakeOver() throws {
        let real = try choice(["changeable": false, "blocked": "real_profile", "can_take_over": true])
        #expect(BrowserChoiceModel.takeOverTitle(real, name: "Wren") == "Let Hermes HQ Run Wren’s Browser")
        #expect(BrowserChoiceModel.takeOverMessage(real, name: "Wren").contains("“use real Chrome profile” setting in Hermes is turned off"))
        #expect(BrowserChoiceModel.takeOverMessage(real, name: "Wren").contains("copy of your Chrome profile"))
        let off = try choice(["changeable": false, "blocked": "no_browser", "can_take_over": false])
        #expect(BrowserChoiceModel.takeOverTitle(off, name: "Wren") == nil, "a bot that doesn't use a browser is never offered")
        #expect(BrowserChoiceModel.takeOverTitle(try choice(["changeable": false]), name: "Wren") == nil, "an older plugin: no button")
        let ours = try choice(["changeable": true, "can_take_over": true])
        #expect(BrowserChoiceModel.takeOverTitle(ours, name: "Wren") == nil, "already Hermes HQ's")
    }

    @Test func summaryBesideProfileAndWindow() throws {
        #expect(BrowserChoiceModel.summary(try choice(["changeable": true])) == "Its Own")
        #expect(BrowserChoiceModel.summary(try choice(["changeable": false, "blocked": "real_profile"])) == "Real Chrome")
        #expect(BrowserChoiceModel.summary(try choice(["changeable": false, "blocked": "no_browser"])) == "No Browser")
        #expect(BrowserChoiceModel.summary(try choice(["changeable": false])) == "Not Set Up")
    }

    @Test func outcomeLinesCarryKindAndStatusOnly() {
        #expect(BrowserChoiceModel.outcome(.takeOver, status: nil) == "choice take over: ok")
        #expect(BrowserChoiceModel.outcome(.takeOver, status: 409) == "choice take over: failed (HTTP 409)")
        #expect(BrowserChoiceModel.outcome(.copy("Profile 2"), status: nil) == "choice copy: ok", "never the profile's name")
        #expect(BrowserChoiceModel.outcome(.window(normal: true), status: 0) == "choice normal window: failed")
    }
}
