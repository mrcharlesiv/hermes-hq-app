// [onboarding] "Let Hermes set it up." (docs/spec/3x-onboarding.md §5.4; `W:src/connection-guide.ts:146-155`): a
// message the person sends to their own Hermes. The app only hands the text over.

import SwiftUI

struct LetHermesView: View {
    let reach: SetupReach
    let go: (OnboardingStep) -> Void
    /// Hermes Cloud: opens its sheet; nil hides the row.
    let cloud: (() -> Void)?
    @State private var feedback: GuideFeedback
    @State private var links: GuideLinkOpener

    init(actions: GuideActions, reach: SetupReach = SetupReach(), go: @escaping (OnboardingStep) -> Void, cloud: (() -> Void)? = nil) {
        self.reach = reach; self.go = go; self.cloud = cloud
        _feedback = State(initialValue: GuideFeedback(.agent, actions: actions, reach: reach))
        _links = State(initialValue: GuideLinkOpener(actions: actions, failure: OnboardingCopy.couldNotOpenGuide))
    }

    var body: some View {
        let copy = OnboardingCopy.LetHermes.self
        GuidePage(id: "onboarding.hermes", heading: copy.heading, error: links.error) {
            GuideParagraph(copy.lead)
            // A Hermes that Nous hosts can't run the message (tester 2026-11-07: it kept saying so): its own way in, first.
            if let cloud {
                let cloudCopy = OnboardingCopy.Cloud.self
                GuideChoiceRow(symbol: cloudCopy.symbol, title: cloudCopy.letHermesTitle, text: cloudCopy.letHermesText,
                               id: "onboarding.hermes." + cloudCopy.id, action: cloud)
            }
            GuideTailnetToggle(reach: reach, id: "onboarding.hermes.tailnet")
            CommandCard(id: "onboarding.hermes", copyTitle: copy.copy, shareTitle: copy.share, feedback: feedback) {
                GuideDisclosure(title: copy.showMessage, id: "onboarding.hermes.show-message") {
                    GuideBlock(text: feedback.text, id: "onboarding.hermes.message")
                }
            }
            GuideSteps(steps: reach.tailnetOnly ? OnboardingCopy.Tailnet.letHermesSteps : copy.steps)
            GuideParagraph(reach.tailnetOnly ? OnboardingCopy.Tailnet.letHermesFootnote : copy.footnote, font: .subheadline)
            VStack(spacing: 12) {
                GuideActionButton(title: copy.haveAddress, id: "onboarding.hermes.have-address") { go(.connect) }
                GuideActionButton(title: copy.myself, id: "onboarding.hermes.myself", prominent: false) { go(.where) }
            }
            .padding(.top, 8)
            // UX study #131: Get Started lands here, so someone without Hermes learns here to install it first.
            GuideParagraph(OnboardingCopy.Where.footnote, font: .subheadline) { links.open($0) }
                .accessibilityIdentifier("onboarding.hermes.install-link")
        }
    }
}
