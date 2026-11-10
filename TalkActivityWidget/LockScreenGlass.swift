// [glass] Both Lock Screen cards — a long reply's or a job's (ReplyActivityWidget.swift) and Talk's
// (TalkActivityWidget.swift) — sit on Liquid Glass (owner, 2026-10-31: "The lock screen live widget needs to be Liquid
// Glass not black"). The system's own background is cleared and a glass layer is drawn behind the words: glass applied to
// the words themselves showed the glass and dropped the words (iOS 27). The Lock Screen draws a Live Activity in its dark
// style whatever the phone's appearance, so the words are white; a light dark wash over the glass keeps them readable
// over a bright wallpaper (text on glass passes 4.5:1, docs/spec/06 §8 rule 5). A wash, not the glass's own tint: the
// Lock Screen drew `.regular.tint(…)` exactly as plain `.regular`.

import ActivityKit
import SwiftUI
import WidgetKit

enum LockScreenGlass {
    static let wash = Color.black.opacity(0.22)
}

extension View {
    /// The card on glass, in the card's own (system) shape, with dark-style words.
    func lockScreenGlass() -> some View {
        background {
            ZStack {
                Color.clear.glassEffect(.regular, in: ContainerRelativeShape())
                ContainerRelativeShape().fill(LockScreenGlass.wash)
            }
        }
        .activityBackgroundTint(.clear)
        .environment(\.colorScheme, .dark)
    }
}
