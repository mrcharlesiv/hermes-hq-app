// [onboarding] The Windows path (docs/spec/3x-onboarding.md §5.8; `W:src/connection-guide.ts:158-170`): Tailscale on
// both, then a message for Hermes to do the setup with a password.

import SwiftUI

struct WindowsTailscaleView: View {
    let go: (OnboardingStep) -> Void
    @State private var links: GuideLinkOpener
    @ScaledMetric(relativeTo: .body) private var badge: CGFloat = 28

    init(actions: GuideActions, go: @escaping (OnboardingStep) -> Void) {
        self.go = go
        _links = State(initialValue: GuideLinkOpener(actions: actions))
    }

    var body: some View {
        let copy = OnboardingCopy.Windows.self
        GuidePage(id: "onboarding.other-1", heading: copy.heading1, error: links.error) {
            GuideParagraph(copy.lead1)
            VStack(alignment: .leading, spacing: 18) {
                GuideStepRow(number: 1, badge: badge) {
                    VStack(alignment: .leading, spacing: 10) {
                        GuideParagraph(copy.steps1[0], color: .hqLabel)
                            .accessibilityLabel("1. " + GuideText.spoken(copy.steps1[0]))
                        GuideTintedButton(title: copy.getTailscale, id: "onboarding.other-1.get-tailscale") {
                            links.open(OnboardingCopy.Links.tailscaleApp)
                        }
                    }
                }
                GuideStepRow(number: 2, badge: badge) {
                    GuideParagraph(copy.steps1[1], color: .hqLabel)
                        .accessibilityLabel("2. " + GuideText.spoken(copy.steps1[1]))
                }
            }
        } footer: {
            GuideActionButton(title: copy.next, id: "onboarding.other-1.next") { go(.other2) }
        }
    }
}

struct WindowsMessageView: View {
    let go: (OnboardingStep) -> Void
    @State private var feedback: GuideFeedback

    init(actions: GuideActions, go: @escaping (OnboardingStep) -> Void) {
        self.go = go
        _feedback = State(initialValue: GuideFeedback(.prompt, actions: actions))
    }

    var body: some View {
        let copy = OnboardingCopy.Windows.self
        GuidePage(id: "onboarding.other-2", heading: copy.heading2) {
            GuideParagraph(copy.lead2)
            CommandCard(id: "onboarding.other-2", copyTitle: copy.copy, feedback: feedback) {
                GuideDisclosure(title: copy.showMessage, id: "onboarding.other-2.show-message") {
                    GuideBlock(text: OnboardingCopy.hermesSetupPrompt, id: "onboarding.other-2.message")
                }
            }
            GuideParagraph(copy.after)
            Button(copy.myself) { go(.manual) }
                .font(Font.hq(.body))
                .foregroundStyle(Color.hqTint)
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("onboarding.other-2.myself")
        } footer: {
            GuideActionButton(title: copy.signIn, id: "onboarding.other-2.next") { go(.connect) }
        }
    }
}
