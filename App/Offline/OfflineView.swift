// [offline] The offline screen (docs/spec/3x-offline.md §3.5–§3.7), the web app's `showOffline` (`src/main.ts:285-388`)
// built like the sign-in screen so the icon, type and buttons match: icon, cause title, recovery words, a card naming
// the gateway, Try Again / Change Address or Sign In / Sign In Again / Switch to another saved gateway, and the status line. Centred when it fits;
// at large text sizes it scrolls from the top. Dynamic colours only (§3.3).

import SwiftUI
import UIKit

struct OfflineView: View {
    let model: OfflineScreenModel
    var onTryAgain: () -> Void = {}
    var onDifferentGateway: () -> Void = {}
    var onSignInAgain: () -> Void = {}
    var onSwitch: (String) -> Void = { _ in }
    /// DEBUG: UI tests read the visible countdown (VoiceOver never hears the number).
    var exposesStatus = false
    @ScaledMetric(relativeTo: .body) private var buttonHeight: CGFloat = 34
    @AccessibilityFocusState private var statusFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    header
                        .padding(.bottom, 24)
                    if let card = model.card {
                        cardView(card)
                            .padding(.bottom, 24)
                    }
                    buttons
                    status
                        .padding(.top, 20)
                }
                .frame(maxWidth: 440)
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Color.hqPage.ignoresSafeArea())
    }

    private var header: some View {
        VStack(spacing: 10) {
            WornAppIcon(side: 72)
                .padding(.bottom, 6)
            Text(model.screen.title)
                .font(Font.hq(.title).weight(.bold))
                .foregroundStyle(Color.hqLabel)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("offline.title")
            Text(model.screen.recovery)
                .font(Font.hq(.subheadline))
                .foregroundStyle(Color.hqLabel2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
                .textSelection(.enabled)   // a setting's exact name (HERMES_DASHBOARD_PUBLIC_URL) can be copied
                .accessibilityIdentifier("offline.recovery")
        }
    }

    private func cardView(_ card: OfflineCopy.Card) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(card.name)
                .font(Font.hq(.headline))
                .foregroundStyle(Color.hqLabel)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("offline.card.name")
            if !card.detail.isEmpty {
                Text(card.detail)
                    .font(Font.hq(.subheadline))
                    .foregroundStyle(Color.hqLabel2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("offline.card.detail")
            }
        }
        .lineSpacing(2)
        // Both lines can wrap: explicit vertical padding (13 pt), never the text's own height alone.
        .padding(.vertical, 13)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: HQPalette.groupedCard), in: RoundedRectangle(cornerRadius: HQShape.radius(20, .card), style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("offline.card")
    }

    private var buttons: some View {
        VStack(spacing: 16) {
            Button(action: onTryAgain) { buttonLabel(OfflineCopy.tryAgain) }
                .hqGlassProminentButtonStyle()
                .tint(Color.hqTint)
                .disabled(!model.tryAgainEnabled)
                .accessibilityIdentifier("offline.try-again")
            if model.showsDifferentGateway {
                Button(action: onDifferentGateway) { buttonLabel(OfflineCopy.differentGateway) }
                    .hqGlassButtonStyle()
                    .accessibilityIdentifier("offline.different-gateway")
            }
            if model.showsSignInAgain {
                Button(action: onSignInAgain) { buttonLabel(OfflineCopy.signInAgain) }
                    .hqGlassButtonStyle()
                    .accessibilityIdentifier("offline.sign-in-again")
            }
            ForEach(model.otherGateways) { other in
                Button { onSwitch(other.id) } label: { buttonLabel(OfflineCopy.switchTo(other.title)) }
                    .hqGlassButtonStyle()
                    .accessibilityIdentifier("offline.switch")
            }
        }
        .controlSize(.large)
    }

    private func buttonLabel(_ title: String) -> some View {
        Text(title)
            .font(Font.hq(.headline))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: buttonHeight)
    }

    /// The countdown is redrawn from the due date; VoiceOver gets the fixed words and never a number that would be
    /// wrong by the time it is read.
    private var status: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let words = model.statusText(now: context.date)
            HStack(spacing: 8) {
                if model.connecting, model.problem == nil { ProgressView().controlSize(.small) }
                Text(words)
                    .font(Font.hq(.footnote))
                    .monospacedDigit()
                    .foregroundStyle(Color.hqLabel2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 22)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.spokenStatus)
            .accessibilityValue(exposesStatus ? words : "")
            .accessibilityHidden(model.spokenStatus.isEmpty)
            .accessibilityIdentifier("offline.status")
            .accessibilityFocused($statusFocused)
        }
        .onChange(of: model.focusRequests) { _, _ in statusFocused = true }
    }
}
