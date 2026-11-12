// [onboarding] The welcome a first run opens on (docs/spec/3x-onboarding.md §5.1; `W:src/connection-onboarding.ts:47-57`).

import SwiftUI

struct WelcomeView: View {
    let go: (OnboardingStep) -> Void
    @ScaledMetric(relativeTo: .body) private var symbol: CGFloat = 30

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // UX study #80: the icon, heading and lead are centred, as on the sign-in screen that follows, so they
                // don't jump sideways; the feature rows below stay leading-aligned.
                VStack(spacing: 0) {
                    WornAppIcon(side: 72)
                        .padding(.top, 12)
                    Text(OnboardingCopy.Welcome.headingLine1 + "\n" + OnboardingCopy.Welcome.headingLine2)
                        .font(Font.hq(.largeTitle).weight(.bold))
                        .foregroundStyle(Color.hqLabel)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(OnboardingCopy.Welcome.headingLine1 + " " + OnboardingCopy.Welcome.headingLine2)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("onboarding.welcome")
                        .padding(.top, 20)
                    Text(OnboardingCopy.Welcome.lead)
                        .font(Font.hq(.body))
                        .foregroundStyle(Color.hqLabel2)
                        .lineSpacing(3)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(OnboardingCopy.Welcome.points.enumerated()), id: \.offset) { _, point in
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: point.symbol)
                                .font(Font.hq(.title3))
                                .foregroundStyle(Color.hqTint)
                                .frame(width: min(symbol, 52))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(point.title).font(Font.hq(.headline)).foregroundStyle(Color.hqLabel)
                                Text(point.text).font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.top, 28)
            }
            .frame(maxWidth: 440, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        // UX study #123: the two ways on are pinned under the words, on the page colour, as the system's own setup
        // screens do: at the largest text sizes the words fill several screens, and the buttons must not hide below them.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 12) {
                GuideActionButton(title: OnboardingCopy.Welcome.start, id: "onboarding.welcome.start") { go(.start) }
                GuideActionButton(title: OnboardingCopy.Welcome.haveAddress, id: "onboarding.welcome.address", prominent: false) { go(.connect) }
            }
            .frame(maxWidth: 440)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(Color.hqPage.ignoresSafeArea(edges: .bottom))
        }
        .background(Color.hqPage.ignoresSafeArea())
    }
}
