// glass-phone (owner 2026-10-30, "more Liquid Glass"): the question dock, the attachment tray and Swipe to Reply's
// arrow are native glass off the Desktop Look, keep today's solid look in it, and switch when the look changes live.

import Foundation
import Testing
import UIKit
@testable import HermesHQNative

private func set(look: Bool, composer: DesktopComposer = .box) -> ThemeSet {
    // [desktop-composer] Text Box › Desktop: the look's flat composer pieces (the glass default keeps the iOS look's).
    ThemeResolver.resolve(ThemeState(skinID: "midnight", desktopLook: look, highContrast: false, uiScalePercent: 100, desktopComposer: composer))
}

/// A window whose theme generation moves to `generation`: the views' trait handlers run as it lays out.
@MainActor private func host(_ view: UIView) -> UIWindow {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
    view.frame = CGRect(x: 0, y: 400, width: 402, height: 300)
    window.addSubview(view)
    window.isHidden = false
    window.layoutIfNeeded()
    return window
}

@MainActor private func bump(_ window: UIWindow) {
    window.traitOverrides[ThemeGenerationTrait.self] = window.traitCollection[ThemeGenerationTrait.self] + 1
    window.layoutIfNeeded()
    window.subviews.forEach { $0.layoutIfNeeded() }
}

private let prompt = ClarifyPrompt(id: "p", questions: [
    ClarifyQuestion(qid: "q0", question: "Which branch?", choices: ["main", "dev"], multiSelect: false),
    ClarifyQuestion(qid: "q1", question: "Anything else?", choices: nil, multiSelect: false),
])

@MainActor @Suite struct GlassPhoneTests {

    @Test func theDockIsGlassWithItsTextOnASolidCardOffTheLook() {
        ThemeTable.$testSet.withValue(set(look: false)) {
            let dock = QuestionDockView(prompt: prompt, draft: ClarifyDraft())
            #expect(dock.isGlass)
            #expect(dock.hasTextCard, "the question never sits on bare glass")
            #expect(dock.layer.shadowOpacity == 0, "the glass brings its own shadow")
        }
    }

    @Test func theDockKeepsItsSolidPanelInTheLookAndSwitchesLive() {
        ThemeTable.$testSet.withValue(set(look: true)) {
            let dock = QuestionDockView(prompt: prompt, draft: ClarifyDraft())
            #expect(!dock.isGlass)
            #expect(!dock.hasTextCard)
            #expect(dock.layer.shadowOpacity == 0.16)
            let window = host(dock)
            ThemeTable.$testSet.withValue(set(look: false)) {
                bump(window)
                #expect(dock.isGlass, "the look going off brings the glass back")
                #expect(dock.hasTextCard)
            }
            bump(window)
            #expect(!dock.isGlass, "and on again takes it away")
        }
    }

    @Test func theDocksAnswersAreOpaque() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            var alpha: CGFloat = 0
            DockFill.answers.resolvedColor(with: UITraitCollection(userInterfaceStyle: style)).getRed(nil, green: nil, blue: nil, alpha: &alpha)
            #expect(alpha == 1)
            DockFill.panel.resolvedColor(with: UITraitCollection(userInterfaceStyle: style)).getRed(nil, green: nil, blue: nil, alpha: &alpha)
            #expect(alpha == 1)
        }
    }

    @Test func theTrayIsAGlassCardOffTheLookAndTheStripInIt() {
        ThemeTable.$testSet.withValue(set(look: false)) {
            let tray = AttachmentTrayView()
            let window = host(tray)
            tray.frame = CGRect(x: 0, y: 400, width: 402, height: AttachmentTrayView.height)
            tray.layoutIfNeeded()
            #expect(tray.isGlass)
            #expect(AttachmentTrayView.height == AttachmentTrayView.topRoom + AttachmentTrayView.tileHeight
                    + AttachmentTrayView.glassPad + AttachmentTrayView.gapBelow)
            #expect(tray.panelFrame.minY == AttachmentTrayView.topRoom - AttachmentTrayView.glassPad)
            #expect(tray.panelFrame.height == AttachmentTrayView.tileHeight + 2 * AttachmentTrayView.glassPad)
            var changed = 0
            tray.onLookChange = { changed += 1 }
            ThemeTable.$testSet.withValue(set(look: true)) {
                bump(window)
                tray.layoutIfNeeded()
                #expect(!tray.isGlass)
                #expect(tray.panelFrame == tray.bounds, "the look's strip fills the band, as before")
                #expect(changed == 1, "the composer is told to resize the tray")
            }
            // [desktop-composer] The look's default text box is the glass bar: its tray stays a glass card.
            ThemeTable.$testSet.withValue(set(look: true, composer: .glass)) {
                bump(window)
                tray.layoutIfNeeded()
                #expect(tray.isGlass)
            }
        }
    }

    @Test func theReplyArrowIsGlassTintedOnceArmedAndFlatInTheLook() {
        ThemeTable.$testSet.withValue(set(look: false)) {
            let arrow = ReplyArrowView(side: 34)
            #expect(arrow.isGlass)
            #expect(arrow.glassTint == nil, "untinted while pulling")
            arrow.armed = true
            #expect(arrow.glassTint != nil, "the accent's tinted glass once armed")
            let window = host(arrow)
            ThemeTable.$testSet.withValue(set(look: true)) {
                bump(window)
                #expect(!arrow.isGlass)
                #expect(arrow.backgroundColor != nil, "today's flat circle")
            }
        }
    }
}
