// [a11y] The accessibility kit (docs/spec/3x-a11y.md §2, §8.3): settings, fonts, announcements, field validity,
// the chat style's Bold Text weights, and the high-contrast palette's measured ratios.

import Foundation
import Testing
import UIKit
@testable import HermesHQNative

@MainActor @Suite(.serialized) struct HQAccessibilitySettingsTests {
    @Test func overridesParseFromLaunchArguments() {
        let name = "a11y-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect((HQAccessibility.Overrides.parse(defaults)) == (.init()), "nothing set: nothing forced")
        defaults.set("YES", forKey: "HQA11yReduceMotion")
        defaults.set("YES", forKey: "HQA11yBoldText")
        defaults.set("YES", forKey: "HQA11yVoiceOver")
        let parsed = HQAccessibility.Overrides.parse(defaults)
        #expect(parsed.reduceMotion && parsed.boldText && parsed.voiceOver)
        #expect(!(parsed.reduceTransparency || parsed.buttonShapes || parsed.contrast))
        let settings = HQAccessibility.settings(size: .large, overrides: parsed)
        #expect(settings.reduceMotion && settings.boldText && settings.voiceOver)
    }

    @Test func accessibilitySizeTiers() {
        #expect(!(HQAccessibility.settings(size: .extraExtraExtraLarge).isAccessibilitySize))
        let ax1 = HQAccessibility.settings(size: .accessibilityMedium)
        #expect(ax1.isAccessibilitySize)
        #expect(!(ax1.isLargeAccessibilitySize), "AX1 keeps the chat title's face")
        #expect(HQAccessibility.settings(size: .accessibilityLarge).isLargeAccessibilitySize, "AX2 drops it")
        #expect(HQAccessibility.settings(size: .accessibilityExtraExtraExtraLarge).isLargeAccessibilitySize)
    }

    @Test func didChangePostsOncePerRealChange() {
        let before = HQAccessibility.changeCount
        defer { HQAccessibility.refresh(forgetNotified: true) }
        var settings = HQAccessibility.settings(size: .large)
        HQAccessibility.consider(settings)                       // a known starting point
        let start = HQAccessibility.changeCount
        _ = before
        #expect(!(HQAccessibility.consider(settings)), "the same settings again: nothing posted")
        settings.contentSize = .accessibilityLarge
        #expect(HQAccessibility.consider(settings))
        #expect(!(HQAccessibility.consider(settings)))
        settings.boldText.toggle()
        #expect(HQAccessibility.consider(settings))
        #expect((HQAccessibility.changeCount - start) == (2), "two real changes, two posts")
    }

    @Test func theNotifiedSizeWinsOverTheApplications() {
        defer { HQAccessibility.refresh(forgetNotified: true) }
        HQAccessibility.refresh(notifiedSize: .accessibilityExtraLarge)
        #expect((HQAccessibility.current.contentSize) == (.accessibilityExtraLarge), "the size in the notification is used even while UIApplication still reads the old one")
        HQAccessibility.refresh(forgetNotified: true)
        #expect((HQAccessibility.current.contentSize) == (UIApplication.shared.preferredContentSizeCategory))
    }

    @Test func sheetsOpenLargeOnlyAtAccessibilitySizes() {
        defer { HQAccessibility.refresh(forgetNotified: true) }
        let host = UIViewController()
        host.modalPresentationStyle = .pageSheet
        let sheet = host.sheetPresentationController!
        sheet.detents = [.medium()]
        HQAccessibility.refresh(notifiedSize: .large)
        sheet.hqPreferLargeAtAccessibilitySizes()
        #expect((sheet.detents.count) == (1), "standard sizes: untouched")
        #expect((sheet.selectedDetentIdentifier) == nil)
        HQAccessibility.refresh(notifiedSize: .accessibilityLarge)
        sheet.hqPreferLargeAtAccessibilitySizes()
        #expect((sheet.detents.count) == (2), "a medium-only sheet gains the large detent")
        #expect((sheet.selectedDetentIdentifier) == (.large))
    }
}

@MainActor @Suite(.serialized) struct HQFontTests {
    private let sizes: [UIContentSizeCategory] = [.extraSmall, .small, .medium, .large, .extraLarge, .extraExtraLarge, .extraExtraExtraLarge,
                                                  .accessibilityMedium, .accessibilityLarge, .accessibilityExtraLarge,
                                                  .accessibilityExtraExtraLarge, .accessibilityExtraExtraExtraLarge]

    @Test func scaledFollowsEveryTextSizeAndNeverShrinksGoingUp() {
        var last: CGFloat = 0
        for size in sizes {
            let font = HQFont.scaled(14, like: .subheadline, category: size)
            #expect((font.pointSize) >= (last), "\(size.rawValue)")
            last = font.pointSize
        }
        #expect(abs((HQFont.scaled(14, like: .subheadline, category: .large).pointSize) - (14)) <= 0.01)
        #expect((HQFont.scaled(14, like: .subheadline, category: .accessibilityExtraExtraExtraLarge).pointSize) > (25))
        #expect((HQFont.scaled(14, like: .subheadline, category: .extraSmall).pointSize) < (14))
        #expect((HQFont.scaled(12, like: .caption1, category: .extraSmall).pointSize) >= (11), "nothing under 11 pt at XS")
    }

    @Test func capsHold() {
        for size in sizes {
            #expect((HQFont.scaled(15, weight: .semibold, like: .subheadline, cap: 22, category: size).pointSize) <= (22.01))
            #expect((HQFont.mono(12.5, like: .footnote, cap: 22, category: size).pointSize) <= (22.01))
            #expect((HQFont.digits(12, weight: .semibold, like: .caption1, cap: 18, category: size).pointSize) <= (18.01))
            #expect((HQFont.style(.headline, weight: .semibold, cap: 22, category: size).pointSize) <= (22.01))
            #expect((HQFont.symbolSize(20, cap: 28, category: size)) <= (28))
        }
        #expect(abs((HQFont.scaled(15, like: .subheadline, cap: 22, category: .accessibilityExtraExtraExtraLarge).pointSize) - (22)) <= 0.01)
    }

    @Test func monoIsMonospaced() {
        #expect(HQFont.mono(13, like: .footnote, category: .large).fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
    }

    @Test func boldTextStepsEachWeightOnce() {
        #expect((HQFont.drawn(.regular, bold: false)) == (.regular))
        #expect((HQFont.drawn(.regular, bold: true)) == (.semibold))
        #expect((HQFont.drawn(.medium, bold: true)) == (.semibold))
        #expect((HQFont.drawn(.semibold, bold: true)) == (.bold))
        #expect((HQFont.drawn(.bold, bold: true)) == (.heavy))
    }
}

@MainActor @Suite(.serialized) struct ChatStyleBoldTests {
    private func weight(_ font: UIFont) -> CGFloat {
        let traits = font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
        return (traits?[.weight] as? CGFloat) ?? 0
    }

    @Test func boldStyleIsHeavierAndWider() {
        let plain = ChatStyle.make(category: .large, bold: false)
        let bold = ChatStyle.make(category: .large, bold: true)
        #expect(!(plain.bold)); #expect(bold.bold)
        #expect((plain.body.pointSize) == (bold.body.pointSize), "Bold Text changes the weight, not the size")
        for (name, a, b) in [("body", plain.body, bold.body), ("bodyBold", plain.bodyBold, bold.bodyBold), ("code", plain.code, bold.code),
                             ("time", plain.time, bold.time), ("tool", plain.tool, bold.tool), ("heading", plain.headings[0], bold.headings[0]),
                             ("table", plain.table, bold.table), ("errorTitle", plain.errorTitle, bold.errorTitle)] {
            #expect((weight(b)) > (weight(a)), "\(name) is heavier under Bold Text")
        }
        let text = "The quick brown fox jumps over the lazy dog" as NSString
        #expect((text.size(withAttributes: [.font: bold.body]).width) > (text.size(withAttributes: [.font: plain.body]).width * 1.02), "bold text is wider, so layouts are measured with it")
    }

    /// The real Bold Text setting already hands the app heavier fonts; the app steps its drawn weights only when it
    /// has not (the DEBUG switch, where the system does nothing).
    @Test func drawnWeightsStepOnlyWhenTheSystemHasNotBoldedAlready() {
        #expect(HQAccessibility.stepsDrawnWeights(boldText: true, systemBoldsFonts: false))
        #expect(!HQAccessibility.stepsDrawnWeights(boldText: true, systemBoldsFonts: true), "no double bold on a real phone")
        #expect(!HQAccessibility.stepsDrawnWeights(boldText: false, systemBoldsFonts: false))
        #expect(!HQAccessibility.fontIsAlreadyBold(UIFont.systemFont(ofSize: 17, weight: .regular)))
        #expect(HQAccessibility.fontIsAlreadyBold(UIFont.systemFont(ofSize: 17, weight: .medium)), "what Bold Text returns for a plain system font")
        #expect(HQAccessibility.fontIsAlreadyBold(UIFont.systemFont(ofSize: 17, weight: .semibold)))
    }

    @Test func codeLabelFollowsTheTextSizeUpToItsCap() {
        #expect(abs((ChatStyle.make(category: .large, bold: false).codeLabel.pointSize) - (12)) <= 0.01)
        #expect(abs((ChatStyle.make(category: .accessibilityExtraExtraExtraLarge, bold: false).codeLabel.pointSize) - (20)) <= 0.01)
    }
}

@MainActor @Suite(.serialized) struct HQAnnounceTests {
    init() { HQAnnounce.resetForTests(); HQAnnounce.alwaysLog = true }
    private func done() { HQAnnounce.resetForTests(); HQAnnounce.alwaysLog = false }

    @Test func coalescedWordsInsideTwoSecondsAreSaidOnce() {
        defer { done() }
        var clock = Date(timeIntervalSince1970: 1_000)
        HQAnnounce.now = { clock }
        #expect(HQAnnounce.say("Trying again automatically", coalesce: true))
        clock.addTimeInterval(1)
        #expect(!(HQAnnounce.say("Trying again automatically", coalesce: true)), "a repeat 1 s later is dropped")
        #expect(HQAnnounce.say("Connected", coalesce: true), "other words are not")
        clock.addTimeInterval(1.5)
        #expect(HQAnnounce.say("Trying again automatically", coalesce: true), "2.5 s after the first, it is said again")
        #expect((HQAnnounce.log) == (["Trying again automatically", "Connected", "Trying again automatically"]))
    }

    /// "Copied" on two messages in a row, "No results" for two searches: each is its own event and is spoken.
    @Test func ordinaryRepeatsAreSpokenEveryTime() {
        defer { done() }
        var clock = Date(timeIntervalSince1970: 1_000)
        HQAnnounce.now = { clock }
        #expect(HQAnnounce.say("Copied"))
        clock.addTimeInterval(0.5)
        #expect(HQAnnounce.say("Copied"), "a second copy half a second later is spoken too")
        #expect(HQAnnounce.say("Copied", coalesce: true) == false, "only a caller that asks is coalesced")
        #expect(HQAnnounce.log == ["Copied", "Copied"])
    }

    @Test func aFocusMoveIsLoggedNotAnnounced() {
        defer { done() }
        HQAnnounce.noteFocusSpoke("Wrong password")
        #expect(HQAnnounce.log == ["focus: Wrong password"])
    }

    @Test func emptyAndMissingWordsAreNotSaid() {
        defer { done() }
        #expect(!(HQAnnounce.say(nil)))
        #expect(!(HQAnnounce.say("")))
        #expect(HQAnnounce.log.isEmpty)
    }

    @Test func aFloodKeepsTheLastTwenty() {
        defer { done() }
        for index in 0..<50 { HQAnnounce.say("Reply \(index)", priority: .low) }
        #expect((HQAnnounce.log.count) == (20))
        #expect((HQAnnounce.log.last) == ("Reply 49"))
        #expect((HQAnnounce.log.first) == ("Reply 30"))
    }

    @Test func nothingIsSaidWithoutVoiceOver() {
        defer { done() }
        guard !HQAccessibility.voiceOver else { return }   // VoiceOver (or its override) is on in this run
        HQAnnounce.alwaysLog = false
        #expect(!(HQAnnounce.say("Copied")))
        #expect(HQAnnounce.log.isEmpty)
    }
}

@MainActor @Suite(.serialized) struct SignInValidityTests {
    @Test func theHintNamesTheFault() {
        #expect((HQFieldValidity.hint(invalid: false, message: "anything")) == nil)
        #expect((HQFieldValidity.hint(invalid: true, message: "Enter the address, then tap Sign in with Nous.")) == ("Invalid. Enter the address, then tap Sign in with Nous."))
        #expect((HQFieldValidity.hint(invalid: true, message: nil)) == ("Invalid"))
    }

    @Test func anEmptyAddressMarksTheAddressSpeaksTheMessageAndClearsOnTyping() {
        HQAnnounce.resetForTests(); HQAnnounce.alwaysLog = true
        defer { HQAnnounce.resetForTests(); HQAnnounce.alwaysLog = false }
        let model = SignInModel(driver: FakeSignInDriver(), address: "") {}
        model.signInWithNous()
        #expect(model.addressInvalid)
        #expect(!(model.passwordInvalid))
        #expect((model.error) == ("Enter the address, then tap Sign in with Nous."))
        #expect((HQAnnounce.log) == (["Enter the address, then tap Sign in with Nous."]), "spoken once, when it appears")
        model.address = "m"
        #expect(!(model.addressInvalid), "typing clears the mark")
    }

    @Test func aRefusedPasswordMarksThePasswordNotTheAddress() async {
        HQAnnounce.resetForTests(); HQAnnounce.alwaysLog = true
        defer { HQAnnounce.resetForTests(); HQAnnounce.alwaysLog = false }
        let model = SignInModel(driver: FakeSignInDriver(), address: "fleet.example") {}
        model.username = "fleet"; model.password = "wrong"
        model.signInWithPassword()
        await model.attemptTask?.value
        #expect(model.passwordInvalid)
        #expect(!(model.addressInvalid))
        #expect(HQAnnounce.log.contains(model.error ?? "-"), "the refusal is spoken")
        model.password = "wrong2"
        #expect(!(model.passwordInvalid))
    }
}

/// C1: every text / background pair of the Nous skin meets its ratio in light, dark and both under Increase Contrast.
@MainActor @Suite(.serialized) struct HQPaletteContrastTests {
    private func traits(dark: Bool, high: Bool) -> UITraitCollection {
        UITraitCollection { mutable in
            mutable.userInterfaceStyle = dark ? .dark : .light
            mutable.accessibilityContrast = high ? .high : .normal
        }
    }

    private func components(_ color: UIColor, _ traits: UITraitCollection) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b, a)
    }

    private func luminance(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGFloat {
        func lin(_ c: CGFloat) -> CGFloat { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// `color` drawn over the opaque `background`.
    private func ratio(_ color: UIColor, on background: UIColor, _ traits: UITraitCollection) -> CGFloat {
        let fg = components(color, traits), bg = components(background, traits)
        let r = fg.r * fg.a + bg.r * (1 - fg.a), g = fg.g * fg.a + bg.g * (1 - fg.a), b = fg.b * fg.a + bg.b * (1 - fg.a)
        let l1 = luminance(r, g, b), l2 = luminance(bg.r, bg.g, bg.b)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    @Test func highContrastPairsMeetTheirRatios() {
        let pairs: [(String, UIColor, CGFloat)] = [
            ("label", HQPalette.label, 7), ("label2", HQPalette.label2, 4.5), ("label3", HQPalette.label3, 3),
            ("separator", HQPalette.separator, 3), ("tint", HQPalette.tint, 4.5), ("tintText", HQPalette.tintText, 4.5),
            ("red", HQPalette.red, 4.5), ("orange", HQPalette.orange, 4.5),
            ("chat label", ChatPalette.label, 7), ("chat label2", ChatPalette.label2, 4.5), ("chat label3", ChatPalette.label3, 3),
            ("chat separator", ChatPalette.separator, 3), ("chat tintText", ChatPalette.tintText, 4.5),
        ]
        for dark in [false, true] {
            let t = traits(dark: dark, high: true)
            for (name, color, need) in pairs {
                for (place, background) in [("page", HQPalette.page), ("card", HQPalette.groupedCard)] {
                    let measured = ratio(color, on: background, t)
                    #expect((measured) >= (need), "\(name) on the \(place), \(dark ? "dark" : "light"), high contrast: \(measured)")
                }
            }
        }
    }

    @Test func highContrastIsNeverWeakerThanStandard() {
        for dark in [false, true] {
            for (name, color) in [("label", HQPalette.label), ("label2", HQPalette.label2), ("label3", HQPalette.label3),
                                  ("separator", HQPalette.separator), ("tint", HQPalette.tint), ("red", HQPalette.red),
                                  ("orange", HQPalette.orange), ("tintText", HQPalette.tintText)] {
                let standard = ratio(color, on: HQPalette.page, traits(dark: dark, high: false))
                let high = ratio(color, on: HQPalette.page, traits(dark: dark, high: true))
                #expect((high) >= (standard), "\(name), \(dark ? "dark" : "light")")
            }
        }
    }

    @Test func standardBodyTextStaysReadable() {
        for dark in [false, true] {
            #expect((ratio(HQPalette.label, on: HQPalette.page, traits(dark: dark, high: false))) >= (7))
            #expect((ratio(HQPalette.label2, on: HQPalette.page, traits(dark: dark, high: false))) >= (4.5))
        }
    }

    @Test func theMyBubbleTimeTakesTheBubbleTextColourUnderHighContrast() {
        let t = traits(dark: false, high: true)
        #expect(abs((components(ChatPalette.meTime, t).a) - (1)) <= 0.001)
    }
}
