// [goals] Step 2 (docs/goals.md "The shelf", the middle phone of the owner-approved boards): Today leads
// with a Goals shelf. The heading "Goals" with "All N ›" at its end, then one row of small cards that scrolls sideways:
// the ring, the name, a grey line ("340 · by Jan 31") and "Next: <the goal's next task>". A tap on a card opens the
// goal; a tap on "Goals" folds the shelf to its heading ("Goals 3"), kept on this device. At the accessibility text
// sizes the cards stack, two at most, then "All N ›". The rules are HermesKit's `GoalShelf`; this file only draws.
// TasksViewController puts it in one cell over Today's groups.

import SwiftUI
import UIKit

/// Folded or not, kept on this device.
enum GoalShelfFold {
    private static let key = "HQGoalShelfFolded"
    static var folded: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

struct GoalShelfView: View {
    var cards: [GoalShelfCard]
    var folded: Bool
    /// A tap on the heading.
    var toggle: () -> Void
    /// A tap on a card: its goal's id.
    var open: (String) -> Void
    /// "All N ›": the Goals view.
    var all: () -> Void
    /// [goals step 3] Your bots' names and faces (the cards' faces).
    var look = GoalTeamLook()
    @Environment(\.dynamicTypeSize) private var typeSize
    private var stacked: Bool { typeSize.isAccessibilitySize }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading
            if !folded {
                if stacked {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(GoalShelf.drawn(cards, stacked: true)) { card in
                            GoalShelfCardView(card: card, width: nil, look: look) { open(card.id) }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    // Its touch reaches 10 pt above its words: 14 keeps it off the card above.
                    allButton
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                } else if DeviceWord.isMac {
                    // [mac-tasks-calm] Owner 2026-11-22 ("this feels SO busy on Mac"): on the Mac a goal is a slim row
                    // like a task's (its ring where a task's circle is, the name, how far along), not a half-width card
                    // with its words cut. Its next task is the goal's page's.
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(cards.prefix(3)) { card in
                            GoalShelfRowView(card: card, look: look) { open(card.id) }
                        }
                    }
                    .accessibilityIdentifier("goals.shelf.cards")
                } else {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(cards) { card in
                                GoalShelfCardView(card: card, width: cardWidth, look: look) { open(card.id) }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 2)
                    }
                    .scrollIndicators(.hidden)
                    .scrollClipDisabled()
                    .padding(.top, 4)
                    .accessibilityIdentifier("goals.shelf.cards")
                }
            }
        }
        .padding(.bottom, folded ? 0 : 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("goals.shelf")
    }

    @ScaledMetric(relativeTo: .subheadline) private var textCardWidth: CGFloat = 214
    /// [ui-sizing] × UI Scale too; never wider than a phone's row of one and a half cards.
    private var cardWidth: CGFloat { min(300, HQFont.scaled(textCardWidth)) }

    /// "Goals" (a button that folds and opens the shelf; "Goals 3" folded) and "All 3 ›" at its end.
    private var heading: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(action: toggle) {
                TodoGroupHeaderView.Words(title: "Goals", detail: nil, count: GoalShelf.headingCount(cards.count, folded: folded))
                    .padding(.top, 16).padding(.bottom, 4).padding(.trailing, 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, -16).padding(.bottom, -4)
            .accessibilityLabel("Goals")
            .accessibilityValue(GoalShelf.headingValue(cards.count, folded: folded))
            .accessibilityHint(folded ? "Shows your goals" : "Folds your goals to this line")
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("goals.shelf.heading")
            Spacer(minLength: 8)
            if !stacked || folded { allButton }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    private var allButton: some View {
        Button(action: all) {
            HStack(spacing: 3) {
                Text(GoalShelf.allWords(cards.count))
                Image(systemName: "chevron.right").font(Font.hq(.caption).weight(.semibold)).accessibilityHidden(true)
            }
            .font(Font.hq(.footnote))   // board 1: smaller than the heading, as a group's date is
            .monospacedDigit()
            .foregroundStyle(Color.hqLabel2)
            .padding(.vertical, 10).padding(.leading, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, -10)
        .accessibilityLabel("All Goals")
        .accessibilityValue("\(cards.count)")
        .accessibilityHint("Opens the Goals view")
        .accessibilityIdentifier("goals.shelf.all")
    }
}

/// One small card: the ring, the name, the grey line, and what is next. One element for VoiceOver, read as the Goals
/// view's card is.
struct GoalShelfCardView: View {
    var card: GoalShelfCard
    /// nil: as wide as the shelf (the cards stacked).
    var width: CGFloat?
    var look = GoalTeamLook()
    var open: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .subheadline) private var textRing: CGFloat = 28
    @ScaledMetric(relativeTo: .subheadline) private var textFace: CGFloat = 18
    private var ringSize: CGFloat { HQFont.scaled(textRing) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.isDesktop ? DesktopRows.radius : 14, style: .continuous)
        let wraps = typeSize.isAccessibilitySize
        Button(action: open) {
            VStack(alignment: .leading, spacing: 7) {
                // At the accessibility sizes the ring stands over the words, so the name has the card's whole width.
                let layout = wraps ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(alignment: .center, spacing: 10))
                layout {
                    GoalRing(fraction: card.fraction, color: card.color, size: ringSize)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(card.title)
                            .font(Font.hq(.subheadline).weight(.semibold))
                            .foregroundStyle(Color.hqLabel)
                            .lineLimit(wraps ? nil : 1)
                            .fixedSize(horizontal: false, vertical: wraps)
                        // The line keeps its room when empty, so the cards in a row stand the same height. [goals step 4]
                        // A stalled goal says so in orange in its place.
                        Text(card.stall ?? (card.line.isEmpty ? " " : card.line))
                            .font(Font.hq(.caption))
                            .monospacedDigit()
                            .foregroundStyle(card.stall == nil ? Color.hqLabel2 : Color.hqOrange)
                            .lineLimit(wraps ? nil : 1)
                            .fixedSize(horizontal: false, vertical: wraps)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // [goals step 3] The bots on the goal at the card's end.
                    if !card.team.isEmpty {
                        GoalTeamFaces(team: card.team, look: look, waits: card.waits, size: HQFont.scaled(textFace))
                    }
                }
                next
                    .font(Font.hq(.footnote))
                    .lineLimit(wraps ? 3 : 1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: wraps)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .background {
                shape.fill(Color(uiColor: ProjectPageHeader.fill))
                    .overlay { if Theme.isDesktop { shape.strokeBorder(Color.hqStroke, lineWidth: HQShape.hairline) } }
            }
            .hqPointerFill(shape)
            .contentShape(shape)
        }
        .buttonStyle(GoalShelfPress())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(GoalCardWords.label(card.spoken, stall: card.stall,
                                                  team: look.spoken(team: card.team, led: card.led, waits: card.waits)))
        .accessibilityValue(card.fraction.map { "\(Int(($0 * 100).rounded(.down))) percent" } ?? "No plan yet")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the goal")
        .accessibilityIdentifier("goal-shelf-\(card.title)")
    }

    /// "Next: Post the build notes…" (the word grey, the task in the label's ink), "No plan yet", "Nothing next".
    private var next: Text {
        switch card.next {
        case .task(_, let title):
            return Text("\(Text("Next: ").foregroundStyle(Color.hqLabel2))\(Text(title).foregroundStyle(Color.hqLabel))")
        case .noPlan, .nothing:
            return Text(card.next.words).foregroundStyle(Color.hqLabel2)
        case .planWaits:   // [goals set-up] something to do: in the label's ink, as a next task is
            return Text(card.next.words).foregroundStyle(Color.hqLabel)
        }
    }
}

/// [mac-tasks-calm] The Mac's goal on the shelf: one line, read as the card is.
struct GoalShelfRowView: View {
    var card: GoalShelfCard
    var look = GoalTeamLook()
    var open: () -> Void
    @ScaledMetric(relativeTo: .callout) private var textCircle: CGFloat = 22

    var body: some View {
        let lead = min(30, HQFont.scaled(textCircle)).rounded()
        Button(action: open) {
            HStack(alignment: .center, spacing: 12) {
                GoalRing(fraction: card.fraction, color: card.color, size: (lead * 0.82).rounded())
                    .frame(width: lead, height: lead)
                // How far along shows whole beside the whole name, or not at all (in the narrow column a lone "…"
                // stood where it was cut); the name is cut only when it alone is too long.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        name.fixedSize()
                        Spacer(minLength: 0)
                        Text(card.stall ?? card.line)
                            .font(Font.hq(.footnote)).monospacedDigit()
                            .foregroundStyle(card.stall == nil ? Color.hqLabel2 : Color.hqOrange)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    name.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            #if targetEnvironment(macCatalyst)
            .padding(.horizontal, max(0, 20 - MacSelection.insets.leading))
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .hqPointerFill(RoundedRectangle(cornerRadius: MacSelection.radius, style: .continuous))
            .padding(.horizontal, MacSelection.insets.leading)
            #else
            .padding(.horizontal, 20)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            #endif
        }
        .buttonStyle(GoalShelfPress())
        .help(card.next.helpWords)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(GoalCardWords.label(card.spoken, stall: card.stall,
                                                  team: look.spoken(team: card.team, led: card.led, waits: card.waits)))
        .accessibilityValue(card.fraction.map { "\(Int(($0 * 100).rounded(.down))) percent" } ?? "No plan yet")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the goal")
        .accessibilityIdentifier("goal-shelf-\(card.title)")
    }

    private var name: some View {
        Text(card.title)
            .font(Font.hq(.callout))
            .foregroundStyle(Color.hqLabel)
            .lineLimit(1)
    }
}

private extension GoalShelfNext {
    /// What the pointer shows over the Mac's goal row: "Next: <task>".
    var helpWords: String {
        if case .task(_, let title) = self { return "Next: \(title)" }
        return words
    }
}

/// A card dims while pressed (no motion, so nothing to turn off under Reduce Motion).
private struct GoalShelfPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(PointerEffects.dim(configuration.isPressed, to: 0.6))
    }
}
