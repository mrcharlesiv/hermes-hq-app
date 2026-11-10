// [offline] The Bots list's notice card (docs/spec/3x-offline.md §4.1, §4.2): one list cell on the grouped-card colour
// with wrapping words and a plain tinted Try Again. List content, not a floating control, so no glass.

import SwiftUI

struct RosterNoticeCard: View {
    let text: String
    /// The retry is out: a small spinner stands where the button was.
    let busy: Bool
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(Font.hq(.subheadline))
                .foregroundStyle(Color.hqLabel2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("bots.notice.text")
            if busy {
                ProgressView()
                    .controlSize(.small)
                    .frame(minHeight: 22)
                    .accessibilityLabel(OfflineCopy.connecting)
            } else {
                Button(RosterStateCopy.tryAgain, action: retry)
                    .buttonStyle(.plain)
                    .font(Font.hq(.subheadline).weight(.semibold))
                    .foregroundStyle(Color.hqTint)
                    .frame(minHeight: 22)
                    // [ui-sizing] A 44 pt touch, 11 pt over and under the line, the card's height as it was.
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                    .padding(.vertical, -11)
                    .accessibilityIdentifier("bots.notice.retry")
            }
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 16)
        .background(Color(uiColor: HQPalette.groupedCard), in: RoundedRectangle(cornerRadius: HQShape.radius(16, .card), style: .continuous))
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }
}
