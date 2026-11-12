// The step sheet's Changes box wraps a long line inside the panel (owner 2026-11-11: no scrolling sideways to read
// an edit on the phone).

import Testing
import UIKit
@testable import HermesHQNative

@MainActor
@Suite("Activity · the Changes box wraps long lines")
struct DiffPanelWrapTests {
    private func panel(_ lines: [StepRules.DiffLine], width: CGFloat) -> DiffPanel {
        let panel = DiffPanel(lines: lines)
        panel.translatesAutoresizingMaskIntoConstraints = false
        let host = UIView(frame: CGRect(x: 0, y: 0, width: width, height: 2000))
        host.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: host.topAnchor),
            panel.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            panel.widthAnchor.constraint(equalToConstant: width),
        ])
        host.layoutIfNeeded()
        return panel
    }

    private func labels(_ view: UIView) -> [UILabel] {
        view.subviews.flatMap { ($0 as? UILabel).map { [$0] } ?? labels($0) }
    }

    @Test func aLongLineTakesMoreRowsAndStaysInsideThePanel() {
        let long = "    submit --bot B --file PATH|-     validate + store one bot's report for today, then print where it went"
        let made = panel([.init(kind: .added, text: "import os"), .init(kind: .added, text: long)], width: 343)
        let rows = labels(made)
        #expect(rows.count == 2)
        #expect(made.subviews.allSatisfy { !($0 is UIScrollView) }, "nothing scrolls sideways")
        #expect(rows.allSatisfy { $0.frame.width <= 343.5 })
        #expect(rows[1].frame.height > rows[0].frame.height * 2.5, "the long line wrapped onto more rows")
    }

    @Test func wrappedRowsHangPastTheLinesOwnIndentation() {
        let font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let flat = DiffPanel.wrapping("import os", font: font, step: 16)
        let nested = DiffPanel.wrapping("        return x", font: font, step: 16)
        let deep = DiffPanel.wrapping(String(repeating: " ", count: 80) + "x", font: font, step: 16)
        func indent(_ s: NSAttributedString) -> CGFloat {
            (s.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.headIndent ?? -1
        }
        #expect(indent(flat) == 16)
        #expect(indent(nested) > indent(flat))
        #expect(indent(deep) == 120, "a deeply nested line keeps room for its words")
    }

    /// Not a check: photographs the box at phone width when HQ_DIFF_SHOT names a file.
    @Test func photograph() throws {
        guard let path = ProcessInfo.processInfo.environment["HQ_DIFF_SHOT"] else { return }
        let source = [
            "#!/usr/bin/env python3",
            "\"\"\"Morning reports: every owned bot files one report a day; this checks them in.",
            "",
            "  submit --bot B --file PATH|-     validate + store one bot's report",
            "  status [--date D] [--bot B] [--json]   which bots have filed",
            "\"\"\"",
            "import argparse",
            "",
            "ROOT = Path('/Users/someone/.hermes/workspace/daily-reports')",
            "EXPECTED = ['one', 'two', 'three', 'four', 'five', 'six', 'seven']",
            "",
            "def day_dir(date):",
            "    if not re.fullmatch(r'\\d{4}-\\d\\d-\\d\\d', date or '') or date > today():",
            "        raise SystemExit('bad date')",
            "    return ROOT / date",
        ]
        let made = panel(source.map { .init(kind: .added, text: $0) }, width: 343)
        made.overrideUserInterfaceStyle = .dark
        made.superview?.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: made.bounds).image { context in
            UIColor.black.setFill(); context.fill(made.bounds)
            made.layer.render(in: context.cgContext)
        }
        try image.pngData()?.write(to: URL(fileURLWithPath: path))
    }
}
