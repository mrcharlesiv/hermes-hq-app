// Mac polish 2026-11-06, batch 5 (the chat bar, chat sheets and voice): the parts that are plain rules. Each test runs
// in its own theme through `ThemeTable.$testSet`, so the table the other suites read is never changed. The Mac-only
// halves (DeviceWord.isMac) are not reachable from the iPhone simulator the tests run on.

import Testing
import UIKit
@testable import HermesHQNative

private func set(look: Bool) -> ThemeSet {
    ThemeResolver.resolve(ThemeState(skinID: "ios", desktopLook: look, highContrast: false, uiScalePercent: 100))
}

@MainActor @Suite struct MacPolish5Tests {
    /// #78: "Waking up…" sits just below the Desktop Look's solid bar, its whole outline showing; the iOS look keeps it
    /// tucked 4 pt under its glass bar.
    @Test func theStatusPillStartsBelowTheDesktopLooksBar() {
        ThemeTable.$testSet.withValue(set(look: true)) { #expect(ChatMetrics.statusPillTop == 4) }
        ThemeTable.$testSet.withValue(set(look: false)) { #expect(ChatMetrics.statusPillTop == -4) }
    }

    /// #66: a panel that took on its own look after the look made it solid (the message bar's field) is not boxed
    /// again by a later pass.
    @Test func aPanelWithItsOwnLookIsNotBoxedAgain() {
        let holder = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
        let field = UIVisualEffectView(effect: UIGlassEffect())
        field.frame = CGRect(x: 10, y: 10, width: 200, height: 44)
        holder.addSubview(field)
        ThemeTable.$testSet.withValue(set(look: true)) {
            ThemeChrome.solidify(field)
            #expect(field.layer.borderWidth == 1, "boxed the first time")
            // The bar flattens its field into its own one box.
            DesktopLayout.keepOwnLook(field)
            field.backgroundColor = .clear
            field.layer.borderWidth = 0
            ThemeChrome.solidify(field)
            #expect(field.layer.borderWidth == 0, "no second box inside the bar's")
            #expect(field.backgroundColor == .clear)
        }
    }

    /// #79: the look going off gives a panel its stashed glass back, unless its owner already gave it newer glass (the
    /// Talk disc's tinted glass stayed blue, not the stash's untinted grey).
    @Test func theOwnersNewerGlassOutlivesTheStash() {
        let holder = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
        let disc = UIVisualEffectView(effect: UIGlassEffect())
        disc.frame = CGRect(x: 10, y: 10, width: 44, height: 44)
        holder.addSubview(disc)
        ThemeTable.$testSet.withValue(set(look: true)) { ThemeChrome.solidify(disc) }
        #expect(disc.effect == nil)
        ThemeTable.$testSet.withValue(set(look: false)) {
            let blue = UIColor(red: 0, green: 0.4, blue: 1, alpha: 1)
            let tinted = UIGlassEffect()
            tinted.tintColor = blue
            disc.effect = tinted
            ThemeChrome.solidify(disc)
            #expect((disc.effect as? UIGlassEffect)?.tintColor == blue, "the owner's tint, not the stash's")
            #expect(disc.layer.borderWidth == 0, "the rest of the look is still taken off")
        }
        // Nothing set by the owner: the stashed glass comes back, as before.
        let plain = UIVisualEffectView(effect: UIGlassEffect())
        holder.addSubview(plain)
        ThemeTable.$testSet.withValue(set(look: true)) { ThemeChrome.solidify(plain) }
        ThemeTable.$testSet.withValue(set(look: false)) { ThemeChrome.solidify(plain) }
        #expect(plain.effect is UIGlassEffect)
    }

    /// #34: the voices are read once and kept; reading them off the main thread gives the same list.
    @Test func theVoicesAreReadOnceAndKept() async {
        let loaded = await PhoneVoiceList.load()
        #expect(PhoneVoiceList.now() == loaded)
        #expect(SystemPhoneSpeechRenderer.candidates() == loaded)
    }

    /// #136: the fallback banner names the bot once, in one short sentence.
    @Test func theVoiceBannerIsOneShortSentence() {
        let words = PhoneVoiceWords.notice(botName: "Hermes")
        #expect(words == "Hermes’s voice isn’t working, so the \(DeviceWord.name)’s voice is reading.")
        #expect(words.components(separatedBy: "Hermes").count == 2, "Hermes once")
    }
}
