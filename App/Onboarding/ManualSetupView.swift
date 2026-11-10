// [onboarding] "Set it up yourself." (docs/spec/3x-onboarding.md §5.9; `W:src/connection-guide.ts:171-179`): the
// commands for doing it by hand, with placeholders only. Nothing here is run or written by the app.

import SwiftUI

struct ManualSetupView: View {
    let go: (OnboardingStep) -> Void
    @State private var feedback: GuideFeedback
    @State private var links: GuideLinkOpener
    @ScaledMetric(relativeTo: .body) private var badge: CGFloat = 28

    init(actions: GuideActions, go: @escaping (OnboardingStep) -> Void) {
        self.go = go
        _feedback = State(initialValue: GuideFeedback(.steps, actions: actions))
        _links = State(initialValue: GuideLinkOpener(actions: actions))
    }

    var body: some View {
        let copy = OnboardingCopy.Manual.self, setup = OnboardingCopy.Setup.self
        GuidePage(id: "onboarding.manual", heading: copy.heading, error: links.error) {
            GuideParagraph(copy.lead) { links.open($0) }
                .accessibilityIdentifier("onboarding.manual.admin-link")
            VStack(alignment: .leading, spacing: 8) {
                GuideTintedButton(title: copy.copyAll, id: "onboarding.manual.copy-all") { feedback.copy() }
                GuideStatusLine(text: feedback.status, id: "onboarding.manual.status")
            }
            .animation(HQMotion.swiftUI(.smooth(duration: 0.2), fades: true), value: feedback.status)
            section(1, copy.title1) {
                GuideBlock(text: setup.serve, id: "onboarding.manual.serve")
                GuideParagraph(copy.text1, font: .subheadline)
                link(copy.link1, OnboardingCopy.Links.tailscaleServe, "onboarding.manual.serve-link")
            }
            section(2, copy.title2) {
                GuideParagraph(copy.secretLead, font: .subheadline)
                GuideBlock(text: setup.secret, id: "onboarding.manual.secret")
                GuideParagraph(copy.envLead, font: .subheadline)
                GuideBlock(text: setup.env, id: "onboarding.manual.env")
                GuideParagraph(copy.text2, font: .subheadline)
                link(copy.link2, OnboardingCopy.Links.dashboard, "onboarding.manual.signin-link")
            }
            section(3, copy.title3) {
                GuideParagraph(copy.text3, font: .subheadline)
                GuideBlock(text: setup.start, id: "onboarding.manual.start")
            }
            GuideActionButton(title: copy.signIn, id: "onboarding.manual.next") { go(.connect) }
                .padding(.top, 8)
        }
    }

    private func section<Content: View>(_ number: Int, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        GuideStepRow(number: number, badge: badge) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(Font.hq(.headline)).foregroundStyle(Color.hqLabel)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("\(number). \(title)")
                    .accessibilityAddTraits(.isHeader)
                content()
            }
        }
    }

    private func link(_ title: String, _ address: String, _ id: String) -> some View {
        Button(title) { links.open(address) }
            .font(Font.hq(.subheadline))
            .foregroundStyle(Color.hqTint)
            .frame(minHeight: 44, alignment: .leading)
            .accessibilityAddTraits(.isLink)
            .accessibilityIdentifier(id)
    }
}
