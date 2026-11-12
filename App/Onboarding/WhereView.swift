// [onboarding] "Which computer runs Hermes?" (docs/spec/3x-onboarding.md §5.3; `W:src/connection-onboarding.ts:58-71`):
// behind Set It Up Myself, so only the computers. Hermes Cloud, "no Hermes yet" and (on a Mac) this Mac are the rows of
// "Where is your Hermes?" (StartView.swift); an address someone gave you is the welcome's second button.

import SwiftUI

struct WhereView: View {
    let go: (OnboardingStep) -> Void

    var body: some View {
        GuidePage(id: "onboarding.where", heading: OnboardingCopy.Where.heading) {
            GuideParagraph(OnboardingCopy.Where.lead)
            VStack(spacing: 10) {
                ForEach(OnboardingCopy.Where.choices, id: \.id) { choice in
                    GuideChoiceRow(symbol: choice.symbol, title: choice.title, text: choice.text, id: "onboarding.where." + choice.id) {
                        go(choice.step)
                    }
                }
            }
        }
    }
}
