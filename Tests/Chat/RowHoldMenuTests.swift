import Foundation
import Testing
@testable import HermesHQNative

@Suite("Chat · folded rows' hold menu")
struct RowHoldMenuTests {
    @Test func aDeliveryCopiesItsWholeMessage() {
        #expect(RowHoldMenu.resultText(title: "Ivy: The report is…", result: "The report is ready.\nThree items.", delivery: true)
                == "The report is ready.\nThree items.")
    }

    @Test func aResultCopiesItsTitleOverItsReport() {
        #expect(RowHoldMenu.resultText(title: "Background task finished: npm test", result: "12 passed\n", delivery: false)
                == "Background task finished: npm test\n\n12 passed")
        #expect(RowHoldMenu.resultText(title: "Subagent done", result: "  ", delivery: false) == "Subagent done")
    }

    @Test func aToolRowCopiesItsCommandAndOutput() {
        var detail = ToolDetail()
        detail.command = "ls -la"
        detail.stdout = "total 0\n"
        let both = RowHoldMenu.copies(detail)
        #expect(both.command == "ls -la")
        #expect(both.output == "total 0\n")
        var read = ToolDetail()
        read.detail = "{\"lines\": 3}"
        #expect(RowHoldMenu.copies(read).command == nil, "no command: no Copy Command")
        #expect(RowHoldMenu.copies(read).output == "{\"lines\": 3}")
        #expect(RowHoldMenu.copies(nil).command == nil && RowHoldMenu.copies(nil).output == nil)
    }
}
