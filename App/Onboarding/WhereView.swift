// [onboarding] "Where does Hermes run?" (docs/spec/3x-onboarding.md §5.3; `W:src/connection-onboarding.ts:58-71`).

import SwiftUI

struct WhereView: View {
    let go: (OnboardingStep) -> Void
    /// [mac] "On this Mac": the form, with this Mac's own Hermes address filled in (the flow's `showForm`).
    let fill: (String) -> Void
    /// Hermes Cloud: opens its sheet; nil hides the row (the flow has nowhere to open it).
    let cloud: (() -> Void)?
    @State private var links: GuideLinkOpener

    init(actions: GuideActions, go: @escaping (OnboardingStep) -> Void, fill: @escaping (String) -> Void = { _ in },
         cloud: (() -> Void)? = nil) {
        self.go = go; self.fill = fill; self.cloud = cloud
        _links = State(initialValue: GuideLinkOpener(actions: actions, failure: OnboardingCopy.couldNotOpenGuide))
    }

    var body: some View {
        GuidePage(id: "onboarding.where", heading: OnboardingCopy.Where.heading, error: links.error) {
            GuideParagraph(OnboardingCopy.Where.lead)
            VStack(spacing: 10) {
                ForEach(OnboardingCopy.Where.choices, id: \.id) { choice in
                    GuideChoiceRow(symbol: choice.symbol, title: choice.title, text: choice.text, id: "onboarding.where." + choice.id) {
                        if choice.id == OnboardingCopy.Where.localID { fill(OnboardingCopy.Where.localAddress) } else { go(choice.step) }
                    }
                }
                if let cloud {
                    let copy = OnboardingCopy.Cloud.self
                    GuideChoiceRow(symbol: copy.symbol, title: copy.title, text: copy.text, id: "onboarding.where." + copy.id, action: cloud)
                }
            }
            GuideParagraph(OnboardingCopy.Where.footnote, font: .subheadline) { links.open($0) }
                .accessibilityIdentifier("onboarding.where.install-link")
        }
    }
}
