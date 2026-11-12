// [onboarding] "Let Hermes set it up." (docs/spec/3x-onboarding.md §5.4; `W:src/connection-guide.ts:146-155`): a
// message the person sends to their own Hermes. The app only hands the text over.

import SwiftUI

struct LetHermesView: View {
    let reach: SetupReach
    let go: (OnboardingStep) -> Void
    @State private var feedback: GuideFeedback

    init(actions: GuideActions, reach: SetupReach = SetupReach(), go: @escaping (OnboardingStep) -> Void) {
        self.reach = reach; self.go = go
        _feedback = State(initialValue: GuideFeedback(.agent, actions: actions, reach: reach))
    }

    var body: some View {
        let copy = OnboardingCopy.LetHermes.self
        // The message first, what happens next under it, the ways on pinned below. Hermes Cloud and "no Hermes yet" are
        // rows of the question before this screen; the Tailscale switch is for the few who need it, so it comes last.
        GuidePage(id: "onboarding.hermes", heading: copy.heading) {
            GuideParagraph(copy.lead)
            CommandCard(id: "onboarding.hermes", copyTitle: copy.copy, shareTitle: copy.share, feedback: feedback) {
                GuideDisclosure(title: copy.showMessage, id: "onboarding.hermes.show-message") {
                    GuideBlock(text: feedback.text, id: "onboarding.hermes.message")
                }
            }
            GuideSteps(steps: reach.tailnetOnly ? OnboardingCopy.Tailnet.letHermesSteps : copy.steps)
            GuideParagraph((reach.tailnetOnly ? OnboardingCopy.Tailnet.letHermesFootnote : copy.footnote) + " " + copy.windows, font: .subheadline)
            GuideTailnetToggle(reach: reach, id: "onboarding.hermes.tailnet")
        } footer: {
            GuideActionButton(title: copy.haveAddress, id: "onboarding.hermes.have-address") { go(.connect) }
            GuideActionButton(title: copy.myself, id: "onboarding.hermes.myself", prominent: false) { go(.where) }
        }
    }
}
