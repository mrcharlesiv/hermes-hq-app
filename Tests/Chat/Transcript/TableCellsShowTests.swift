import Testing
import UIKit
@testable import HermesHQNative

/// Owner 2026-11-17 (Finance chat): a table in a reply showed its header band and row lines with no words in them,
/// and its Expand page showed every cell. A bubble reused from a reply taller than the screen kept that reply's
/// visible area, and the table's cells (the only text drawn in many pieces) were culled against it.
@Suite("A table's cells show in a reused bubble")
@MainActor
struct TableCellsShowTests {
    private let style = ChatStyleCache.shared.style(for: .large)
    private let width: CGFloat = 600

    private func row(_ id: String, _ markdown: String) -> (ChatRow, RowLayout) {
        var bubble = BubbleRow(mine: false, text: markdown, markdown: true, partIndex: 0, joinsAbove: false, joinsBelow: false,
                               tail: true, time: nil, pending: false, streaming: false, speaker: "Finance", expanded: true)
        bubble.senderInset = false
        let row = ChatRow(id: "\(id)|b0", messageId: id, scope: "", fingerprint: 1, kind: .bubble(bubble), gapAbove: 0, variant: 0)
        return (row, TextLayout.make(row, width: width, style: style))
    }

    private func blockViews(_ view: UIView) -> [BlockView] {
        view.subviews.flatMap { ($0 as? BlockView).map { [$0] } ?? blockViews($0) }
    }

    /// The tall reply read at its start, then at its end (the chat's table is upside down, as in the app).
    @Test(arguments: [false, true])
    func aTablesCellsDrawAfterTheBubbleHeldATallerReply(readAtFoot: Bool) throws {
        let table = UITableView(frame: CGRect(x: 0, y: 0, width: width, height: 800))
        table.transform = CGAffineTransform(scaleX: 1, y: -1)
        let cell = ChatBubbleCell(style: .default, reuseIdentifier: nil)
        table.addSubview(cell)

        // A reply taller than the screen, its second block a long table (many pieces, so it draws only near the screen).
        let long = "| Day | Spent |\n|---|---:|\n" + (1...300).map { "| Day \($0) | $\($0 * 7) |" }.joined(separator: "\n")
        let (tall, tallLayout) = row("tall", "Intro.\n\n" + long)
        #expect(tallLayout.height > 3 * table.bounds.height)
        let y = readAtFoot ? 0 : table.bounds.height - tallLayout.height
        cell.frame = CGRect(x: 0, y: y, width: width, height: tallLayout.height)
        cell.contentView.frame = cell.bounds
        cell.configure(tall, layout: tallLayout)
        cell.layoutIfNeeded()
        cell.updateWindowRect(in: table)   // what scrolling does for a cell taller than the screen
        let longTable = try #require(blockViews(cell).first { !$0.isHidden && $0.pieceTexts.count > 100 })
        #expect(longTable.drawnPieces.count < longTable.pieceTexts.count, "the long table draws only near the screen")

        // The same cell, reused for a short reply with a table (no window update: it fits the screen).
        let finance = """
        **Your plan is assembled.** I set that target before reconciling enough of your bills.

        | Major monthly costs | Amount |
        |---|---:|
        | Mortgage | $3,615 |
        | Daycare, monthly average | $1,817 |
        | Car payment | $2,035 |
        | Observed insurance | $484 |
        | Utilities and phone | $648 |
        | Swim lessons | $550 |
        | **Subtotal** | **$9,148** |

        That's before groceries.
        """
        let (short, shortLayout) = row("short", finance)
        #expect(shortLayout.height < table.bounds.height)
        cell.prepareForReuse()
        cell.frame = CGRect(x: 0, y: 0, width: width, height: shortLayout.height)
        cell.contentView.frame = cell.bounds
        cell.configure(short, layout: shortLayout)
        cell.layoutIfNeeded()

        let tableBlock = try #require(blockViews(cell).first { !$0.isHidden && $0.pieceTexts.count == 16 }, "the table's block")
        #expect(tableBlock.drawnPieces.count == 16, "every cell of the table is drawn (8 rows × 2 columns)")
        let words = tableBlock.drawnPieces.compactMap { $0.textKit?.text.string }
        #expect(words.contains("Mortgage"))
    }
}
