// desktoplook: tests added after the m9 review. Each one runs in its own theme through `ThemeTable.$testSet`, so the
// table the other suites read is never changed.

import Foundation
import SwiftUI
import Testing
import UIKit
@testable import HermesHQNative

private func look(_ scale: Int = 100, skin: String = "midnight") -> ThemeSet {
    ThemeResolver.resolve(ThemeState(skinID: skin, desktopLook: true, highContrast: false, uiScalePercent: scale))
}

@Suite struct ThemeReviewTests {
    /// UI Scale is applied once: a size read back from a themed font is not multiplied again.
    @Test func uiScaleIsAppliedOnce() {
        func ratios(_ scale: Int) -> [CGFloat] {
            ThemeTable.$testSet.withValue(look(scale)) {
                let style = ChatStyle.make(category: .large)
                let body = style.body.pointSize
                return [style.headings[0].pointSize / body, style.headings[2].pointSize / body, style.code.pointSize / body,
                        style.inlineCode.pointSize / body, style.table.pointSize / body, style.tableBold.pointSize / body,
                        style.time.pointSize / body, style.timeBold.pointSize / body, style.toolMeta.pointSize / body,
                        style.day.pointSize / body, style.caption.pointSize / body]
            }
        }
        let plain = ratios(100)
        for scale in [90, 110, 125, 150] {
            for (a, b) in zip(plain, ratios(scale)) {
                #expect(abs(a - b) < 0.06, "at \(scale)% a derived size keeps its proportion to the body (\(a) vs \(b))")
            }
        }
        ThemeTable.$testSet.withValue(look(150)) {
            let style = ChatStyle.make(category: .large)
            #expect(style.body.pointSize == 22.5, "15 pt x 150%")
            #expect(style.code.pointSize == HQFont.preferred(.footnote).pointSize)
            // The tabular time is built from the final size, not the unscaled one.
            #expect(style.time.pointSize == style.timeBold.pointSize)
            let headline = HQFont.preferred(.headline).pointSize
            #expect(HQFont.face(ofSize: headline, weight: .semibold).pointSize == headline, "the chat title is not scaled twice")
            #expect(HQFont.monoFace(ofSize: 10).pointSize == 10 && HQFont.monoDigitFace(ofSize: 10).pointSize == 10)
            #expect(HQFont.system(ofSize: 10).pointSize == 15 && HQFont.mono(ofSize: 10).pointSize == 15, "literal sizes follow the scale")
        }
    }

    @Test func faceHelpersAreTheSystemFontWithTheLookOff() {
        ThemeTable.$testSet.withValue(ThemeResolver.resolve(.default)) {
            #expect(HQFont.face(ofSize: 13, weight: .medium) == UIFont.systemFont(ofSize: 13, weight: .medium))
            #expect(HQFont.monoFace(ofSize: 12) == UIFont.monospacedSystemFont(ofSize: 12, weight: .regular))
            #expect(HQFont.monoDigitFace(ofSize: 12, weight: .semibold) == UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold))
            #expect(HQShape.showsTime(mine: true) && HQShape.showsTime(mine: false))
        }
    }

    /// In the look your own message has no time, and no room is kept for one.
    @Test func anOwnMessageKeepsNoRoomForATime() throws {
        let message = ChatMessage(id: "m1", role: .user, parts: [.text("Hello there")], timestamp: Date(timeIntervalSince1970: 1_760_000_000), rowId: 1)
        let reply = ChatMessage(id: "m2", role: .assistant, parts: [.text("Hi")], timestamp: Date(timeIntervalSince1970: 1_760_000_900), rowId: 2)
        let input = ChatRowBuilder.Input(messages: [message, reply], isRunning: false, botName: "Ivy", expanded: [], scope: "test|ivy|look")
        func bubbles(_ set: ThemeSet) throws -> (mine: BubbleLayout, reply: BubbleLayout, style: ChatStyle) {
            try ThemeTable.$testSet.withValue(set) {
                let style = ChatStyle.make(category: .large)
                let rows = ChatRowBuilder.build(input).filter(\.isBubble)
                try #require(rows.count == 2)
                guard case .bubble(let mine) = TextLayout.make(rows[0], width: 402, style: style).content,
                      case .bubble(let reply) = TextLayout.make(rows[1], width: 402, style: style).content else {
                    throw CancellationError()
                }
                return (mine, reply, style)
            }
        }
        let on = try bubbles(look())
        #expect(on.mine.timeText == nil, "no time on your own message in the look")
        #expect(on.reply.timeText != nil, "replies keep theirs")
        let words = try #require(on.mine.blocks.first?.frame)
        #expect(abs(on.mine.frame.height - (words.height + 2 * ChatMetrics.bubblePadV)) <= 1, "one line of text plus the padding, no extra row")
        #expect(abs(on.mine.frame.width - (words.width + 2 * ChatMetrics.bubblePadH)) <= 1, "no gap kept for a time on the right")
        let off = try bubbles(ThemeResolver.resolve(.default))
        #expect(off.mine.timeText != nil, "the standard look is untouched")
        let text = ceil(("Hello there" as NSString).size(withAttributes: [.font: off.style.body]).width)
        #expect(off.mine.frame.width > text + 2 * ChatMetrics.bubblePadH + 10, "the standard bubble keeps the time's room")
        let lookText = ceil(("Hello there" as NSString).size(withAttributes: [.font: on.style.body]).width)
        #expect(abs(on.mine.frame.width - (lookText + 2 * ChatMetrics.bubblePadH)) <= 2, "the look's box is as wide as its words")
    }

    /// The standard app never set a window tint: a fresh theme leaves it inherited.
    @MainActor @Test func aFreshThemeLeavesTheWindowTintAlone() {
        let suite = UserDefaults(suiteName: "hqn.theme.tests.tint")!
        suite.removePersistentDomain(forName: "hqn.theme.tests.tint")
        #expect(Theme.isStandard(ThemeStore(defaults: suite).load()))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let system = window.tintColor
        // What adopt() assigns for each state.
        window.tintColor = Theme.isStandard(.default) ? nil : HQPalette.tint
        #expect(window.tintColor == system, "system blue, inherited")
        var picked = ThemeState.default
        picked.skinID = "midnight"
        #expect(!Theme.isStandard(picked))
        var lookOn = ThemeState.default
        lookOn.desktopLook = true
        #expect(!Theme.isStandard(lookOn))
        if Theme.isStandard(Theme.shared.state) {
            let live = UIWindow(frame: window.frame)
            Theme.shared.adopt(live)
            #expect(live.tintColor == system, "adopt() sets no tint in the standard state")
        }
    }

    /// One Color per token while the theme stays the same, so a body run hands SwiftUI equal colours.
    @MainActor @Test func themedColoursAreEqualWithinAGeneration() {
        #expect(Color.hqPage == Color.hqPage)
        #expect(Color.hqLabel2 == Color.hqLabel2)
        #expect(Color.hqPage != Color.hqLabel)
    }

    /// A glass panel goes solid with 4 pt corners in the look and gets its own glass and corners back after it.
    @MainActor @Test func aGlassPanelComesBackExactly() {
        let window = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        let panel = UIVisualEffectView(effect: UIGlassEffect())
        panel.frame = CGRect(x: 10, y: 10, width: 200, height: 44)
        panel.cornerConfiguration = .capsule()
        panel.layer.cornerRadius = 22
        let before = String(describing: panel.cornerConfiguration)
        window.addSubview(panel)
        ThemeTable.$testSet.withValue(look()) {
            ThemeChrome.solidify(panel)
            #expect(panel.effect == nil, "no glass in the look")
            #expect(panel.layer.cornerRadius == 4 && panel.layer.borderWidth == 1)
            #expect(String(describing: panel.cornerConfiguration) != before)
            // The owner gives it glass again while the look is on: still solid after the next pass.
            panel.effect = UIGlassEffect()
            ThemeChrome.solidify(panel)
            #expect(panel.effect == nil)
        }
        ThemeTable.$testSet.withValue(ThemeResolver.resolve(.default)) {
            ThemeChrome.solidify(panel)
            #expect(panel.effect is UIGlassEffect, "the glass is back")
            #expect(panel.layer.cornerRadius == 22 && panel.layer.borderWidth == 0)
            #expect(String(describing: panel.cornerConfiguration) == before, "and its own corners")
            ThemeChrome.solidify(panel)
            #expect(panel.effect is UIGlassEffect, "a second pass with the look off changes nothing")
        }
    }

    /// Only lists the app made are rebuilt on a theme change.
    @MainActor @Test func onlyTheAppsOwnListsAreReloaded() {
        let layout = UICollectionViewFlowLayout()
        let foreign = UICollectionView(frame: .zero, collectionViewLayout: layout)
        #expect(!ThemeChrome.isAppList(foreign, dataSource: nil, delegate: nil))
        #expect(!ThemeChrome.isAppList(foreign, dataSource: NSObject(), delegate: NSObject()), "SwiftUI's and the system's lists")
        let owner = DesktopThemeInstallerModel(services: nil)          // any object of the app's own
        #expect(ThemeChrome.isAppList(foreign, dataSource: nil, delegate: owner))
        #expect(ThemeChrome.isAppList(foreign, dataSource: owner, delegate: nil))
    }

    /// Where the Desktop Look is not offered a stored switch reads as off and cannot be turned on.
    @Test func theLookCanBeWithheld() {
        let name = "hqn.theme.tests.gate"
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        ThemeStore(defaults: suite).pick(skin: "midnight")
        ThemeStore(defaults: suite).setDesktopLook(true)
        ThemeStore(defaults: suite).setUIScale(150)
        #expect(ThemeStore(defaults: suite).load().desktopLook)
        let withheld = ThemeStore(defaults: suite, lookAllowed: false)
        #expect(!withheld.load().desktopLook)
        // [density] UI Scale is not the look's alone any more: it stays, in the iOS look.
        #expect(withheld.load().scale == 1.5 && withheld.load().skinID == "midnight", "the skin and the scale stay")
        withheld.setDesktopLook(false)
        withheld.setDesktopLook(true)
        #expect(!ThemeStore(defaults: suite).load().desktopLook, "it cannot be turned on")
    }

    /// Copy Link puts the plugin's Install from Git link on the pasteboard.
    @MainActor @Test func copyLinkCopiesTheLink() {
        let model = DesktopThemeInstallerModel(services: nil)
        UIPasteboard.general.string = "something else"
        model.copyLink()
        #expect(UIPasteboard.general.string == DesktopThemeInstall.link)
        #expect(model.copied && !model.copyFailed)
        #expect(DesktopThemeInstall.link.hasPrefix("https://"))
    }
}
