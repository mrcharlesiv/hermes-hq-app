// [onboarding] "Where is your Hermes?" and "Get Hermes first." (native only; owner 2026-11-11: "so simple that anybody
// can easily figure out how to get Hermes HQ up and running"). Get Started lands on one plain question with a row per
// answer; each row leads to one short path. Someone with no Hermes gets two ways to one instead of a footnote.

import SwiftUI

struct StartView: View {
    let go: (OnboardingStep) -> Void
    /// [mac] "On this Mac": the form, with this Mac's own Hermes address filled in (the flow's `showForm`).
    let fill: (String) -> Void
    /// Hermes Cloud: opens its sheet; nil hides the row (the flow has nowhere to open it).
    let cloud: (() -> Void)?

    init(go: @escaping (OnboardingStep) -> Void, fill: @escaping (String) -> Void = { _ in }, cloud: (() -> Void)? = nil) {
        self.go = go; self.fill = fill; self.cloud = cloud
    }

    var body: some View {
        let copy = OnboardingCopy.Start.self
        GuidePage(id: "onboarding.start", heading: copy.heading) {
            GuideParagraph(copy.lead)
            VStack(spacing: 10) {
                ForEach(copy.choices, id: \.id) { choice in
                    GuideChoiceRow(symbol: choice.symbol, title: choice.title, text: choice.text, id: "onboarding.start." + choice.id) {
                        if choice.id == copy.localID { fill(copy.localAddress) } else { go(choice.step) }
                    }
                }
                if let cloud {
                    let cloudCopy = OnboardingCopy.Cloud.self
                    GuideChoiceRow(symbol: cloudCopy.symbol, title: cloudCopy.title, text: cloudCopy.text,
                                   id: "onboarding.start." + cloudCopy.id, action: cloud)
                }
                GuideChoiceRow(symbol: copy.noneSymbol, title: copy.noneTitle, text: copy.noneText, id: "onboarding.start." + copy.noneID) {
                    go(.getHermes)
                }
            }
        }
    }
}

struct GetHermesView: View {
    let go: (OnboardingStep) -> Void
    let cloud: (() -> Void)?
    @State private var links: GuideLinkOpener

    init(actions: GuideActions, go: @escaping (OnboardingStep) -> Void = { _ in }, cloud: (() -> Void)? = nil) {
        self.go = go; self.cloud = cloud
        _links = State(initialValue: GuideLinkOpener(actions: actions, failure: OnboardingCopy.couldNotOpenGuide))
    }

    var body: some View {
        let copy = OnboardingCopy.GetHermes.self
        GuidePage(id: "onboarding.get-hermes", heading: copy.heading, error: links.error) {
            GuideParagraph(copy.lead)
            VStack(spacing: 10) {
                if let cloud {
                    GuideChoiceRow(symbol: OnboardingCopy.Cloud.symbol, title: copy.cloudTitle, text: copy.cloudText,
                                   id: "onboarding.get-hermes.cloud", action: cloud)
                }
                GuideChoiceRow(symbol: copy.installSymbol, title: copy.installTitle, text: copy.installText,
                               id: "onboarding.get-hermes.install") { links.open(OnboardingCopy.Links.hermes) }
            }
            GuideParagraph(copy.after, font: .subheadline)
        } footer: {
            // Nobody is left on the docs: installed, the way on is here. [mac] Back to the question, where a Hermes on
            // this Mac has its own row.
            GuideActionButton(title: copy.installed, id: "onboarding.get-hermes.installed", prominent: false) {
                go(DeviceWord.isMac ? .start : .hermes)
            }
        }
    }
}
