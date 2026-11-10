// The token under a list page's bar that names the active filters and clears them ("Recently Active  ⊗",
// `S/ui-bots/filter-token.ts`), on native glass. Pairs with `PageBarCapsule`'s Filter.

import SwiftUI

struct PageFilterToken: View {
    var text: String
    /// [sessions-m9] The page's own identifier for the token (Sessions: `sessions.filter-strip`).
    var identifier = "page.filter-token"
    /// [sessions-m9] The end of the VoiceOver name (the web's Sessions strip says "Clear Filters").
    var clearWords = "Clear filters"
    var clear: () -> Void

    var body: some View {
        HStack {
            Button(action: clear) {
                HStack(spacing: 6) {
                    // [sessions-m9] At the largest text sizes a long token ("Needs Input") shrinks a little before it is cut.
                    Text(text).font(Font.hq(.subheadline).weight(.medium)).lineLimit(1).minimumScaleFactor(0.7)
                    Image(systemName: "xmark.circle.fill").font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2)
                }
            }
            .hqGlassButtonStyle()
            .accessibilityLabel("Showing \(text). \(clearWords)")
            .accessibilityIdentifier(identifier)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}
