// [a11y] Repairs after stress round 2 (docs/briefs/m9/a11y-report.md, "Repair after stress round 2").

import Foundation
import SwiftUI
import Testing
import UIKit
@testable import HermesHQNative

@MainActor @Suite struct A11yRepairRoundTwoTests {
    private func traits(_ category: UIContentSizeCategory) -> UITraitCollection {
        UITraitCollection(preferredContentSizeCategory: category)
    }

    /// The Kanban status chips: the pill was a fixed 36 pt, so the text stood taller than it at the largest size.
    @Test func theKanbanChipIsAsTallAsItsText() {
        #expect(KanbanChipView.height(for: traits(.large)) == 36)
        #expect(KanbanChipView.height(for: traits(.extraSmall)) == 36)
        for category in [UIContentSizeCategory.accessibilityMedium, .accessibilityExtraLarge, .accessibilityExtraExtraExtraLarge] {
            let line = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits(category)).lineHeight
            #expect(KanbanChipView.height(for: traits(category)) >= line + 12, "\(category.rawValue): the pill holds its text")
        }
        #expect(KanbanChipView.height(for: traits(.accessibilityExtraExtraExtraLarge)) > 50)
    }

    /// A Kanban meta bit wider than the row ("Needs your input" at the largest size) wraps instead of being cut.
    @Test func aKanbanMetaBitWiderThanTheRowWraps() {
        func height(_ bit: String) -> CGFloat {
            let row = KanbanRowModel(id: "t1", title: "Approve", assignee: nil, head: nil, bits: [.init(text: bit, alert: true)])
            let host = UIHostingController(rootView: KanbanRowView(row: row).environment(\.dynamicTypeSize, .accessibility5))
            return host.sizeThatFits(in: CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude)).height
        }
        let short = height("3h"), long = height("Needs your input from someone on the team")
        #expect(long > short + 20, "the long bit takes more lines (short \(short), long \(long))")
    }

    /// The icons under the latest reply follow the text size, inside their 44 pt circles.
    @Test func theReplyIconsGrowWithTheText() {
        #expect(ChatActionsCell.glyphPointSize(for: .large) == 17)
        #expect(ChatActionsCell.glyphPointSize(for: .extraSmall) == 17)
        #expect(ChatActionsCell.glyphPointSize(for: .accessibilityLarge) > 20)
        #expect(ChatActionsCell.glyphPointSize(for: .accessibilityExtraExtraExtraLarge) == 26)
    }

    /// "Message <name>" that would be cut ("Message Her…") shows as plain "Message"; anything that fits is untouched.
    @Test func aCutComposerPlaceholderFallsBackToMessage() {
        let big = UIFont.systemFont(ofSize: 28), normal = UIFont.systemFont(ofSize: 17)
        #expect(ComposerView.shownPlaceholder("Message Hermes", font: normal, width: 220) == "Message Hermes")
        #expect(ComposerView.shownPlaceholder("Message Hermes", font: big, width: 120) == "Message")
        #expect(ComposerView.shownPlaceholder("Message", font: big, width: 20) == "Message")
        #expect(ComposerView.shownPlaceholder("Reconnecting…", font: big, width: 20) == "Reconnecting…")
        #expect(ComposerView.shownPlaceholder("Message Hermes", font: big, width: 0) == "Message Hermes")
    }
}
