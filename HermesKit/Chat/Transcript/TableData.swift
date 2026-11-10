// [transcript] What the table card and the Table page work out from a table's words: which columns hold numbers (they
// read right-aligned), the order a tapped column sorts in, column widths fitted to a screen, the CSV and Markdown
// copies, and the words above a table that name it.

import CoreGraphics
import Foundation

nonisolated enum TableData {
    /// An optional sign and currency, the digits, then an optional unit; `rest` is whatever follows.
    private static let leading = TRx(#"^\s*([+\-−]?)\s*[$€£¥]?\s*([+\-−]?)(\d[\d,]*(?:\.\d+)?|\.\d+)\s?(GB|MB|KB|TB|bn|pts?|pp|ms|%|x|×|k|K|M|B|s|h)?(.*)$"#)
    /// Cells that stand for "no value" and don't stop a column of numbers being one.
    private static let blanks: Set<String> = ["", "-", "–", "—", "n/a", "N/A", "NA", "?"]

    /// The number a cell starts with ("20.7%" → 20.7, "$1,234" → 1234, "−3" → -3, "1.2M" → 1,200,000,
    /// "14.3% (9 booked)" → 14.3); nil when it doesn't start with one.
    static func number(_ text: String) -> Double? {
        guard let g = leading.groups(text), let digits = g[3], let value = Double(digits.replacingOccurrences(of: ",", with: "")) else {
            return nil
        }
        let minus: Set<String> = ["-", "−"]
        let negative = minus.contains(g[1] ?? "") || minus.contains(g[2] ?? "")
        let rest = g[5] ?? ""
        // "1.2M" scales; "3 Bedrooms" (a word goes on after the letter) does not.
        let scale: Double
        if rest.first?.isLetter == true { scale = 1 } else {
            switch g[4] {
            case "k"?, "K"?: scale = 1_000
            case "M"?: scale = 1_000_000
            case "B"?, "bn"?: scale = 1_000_000_000
            default: scale = 1
            }
        }
        return (negative ? -value : value) * scale
    }

    /// A bracketed note after a number: "14.3% (9 booked)".
    private static let note = TRx(#"^\s*\([^()]*\)\s*$"#)

    /// A cell that is just a number (with its sign, currency or unit, and maybe a bracketed note): "20.7%", "$5",
    /// "1,234", "3x", "14.3% (9 booked)".
    static func isNumber(_ text: String) -> Bool {
        guard let g = leading.groups(text), g[3] != nil else { return false }
        let rest = (g[5] ?? "").trimmingCharacters(in: .whitespaces)
        return rest.isEmpty || note.test(rest)
    }

    /// Columns whose filled body cells are all numbers (and at least one is): they read right-aligned, like a
    /// spreadsheet's.
    static func numericColumns(_ rows: [[String]], columns: Int) -> [Bool] {
        (0..<columns).map { c in
            var any = false
            for row in rows {
                let cell = c < row.count ? row[c].trimmingCharacters(in: .whitespaces) : ""
                if blanks.contains(cell) { continue }
                guard isNumber(cell) else { return false }
                any = true
            }
            return any
        }
    }

    /// The body rows' order sorted by `column`: by value when most of its filled cells start with a number, else by
    /// their words as Finder sorts names ("Item 2" before "Item 10"). Empty cells go last either way; equal cells keep
    /// their order.
    static func order(_ rows: [[String]], column: Int, ascending: Bool) -> [Int] {
        let cells = rows.map { column < $0.count ? $0[column].trimmingCharacters(in: .whitespaces) : "" }
        let numbers = cells.map(number)
        let filled = cells.filter { !blanks.contains($0) }.count
        let byNumber = filled > 0 && numbers.compactMap { $0 }.count * 2 >= filled
        return cells.indices.sorted { a, b in
            let emptyA = blanks.contains(cells[a]), emptyB = blanks.contains(cells[b])
            if emptyA != emptyB { return emptyB }
            if emptyA { return a < b }
            let result: ComparisonResult
            if byNumber, let x = numbers[a], let y = numbers[b] {
                result = x < y ? .orderedAscending : x > y ? .orderedDescending : cells[a].localizedStandardCompare(cells[b])
            } else if byNumber, (numbers[a] == nil) != (numbers[b] == nil) {
                return numbers[a] != nil   // numbers before words, both ways
            } else {
                result = cells[a].localizedStandardCompare(cells[b])
            }
            if result == .orderedSame { return a < b }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    /// Comma-separated rows (RFC 4180: a cell with a comma, quote or line break is quoted, its quotes doubled), what
    /// Numbers and Excel open as a sheet.
    static func csv(_ rows: [[String]]) -> String {
        rows.map { row in
            row.map { raw in
                let cell = TableText.cell(raw)
                guard cell.contains(where: { $0 == "," || $0 == "\"" }) else { return cell }
                return "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }.joined(separator: ",")
        }.joined(separator: "\n")
    }

    nonisolated enum Alignment: Sendable { case natural, center, right }

    /// The table back as Markdown (header, its alignment row, the body), every row as wide as the widest.
    static func markdown(_ rows: [[String]], alignments: [Alignment]) -> String {
        guard let header = rows.first else { return "" }
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        guard columns > 0 else { return "" }
        func line(_ cells: [String]) -> String {
            "| " + (0..<columns).map { c in
                TableText.cell(c < cells.count ? cells[c] : "").replacingOccurrences(of: "|", with: "\\|")
            }.joined(separator: " | ") + " |"
        }
        let rule = "|" + (0..<columns).map { c -> String in
            switch c < alignments.count ? alignments[c] : .natural {
            case .natural: return " --- "
            case .center: return " :---: "
            case .right: return " ---: "
            }
        }.joined(separator: "|") + "|"
        return ([line(header), rule] + rows.dropFirst().map(line)).joined(separator: "\n")
    }

    /// The words above a table that name it: the last line of the prose before it when that line introduces it
    /// ("Rep by rep (minimum 40 orders):") or is a heading, without the colon. Nil otherwise, or when too long to
    /// be a title.
    static func caption(before prose: String, lastLineIsHeading: Bool = false) -> String? {
        guard let last = prose.split(whereSeparator: \.isNewline).last else { return nil }
        var line = last.trimmingCharacters(in: .whitespaces)
        let introduces = line.hasSuffix(":")
        guard introduces || lastLineIsHeading else { return nil }
        while line.hasSuffix(":") { line.removeLast() }
        line = line.trimmingCharacters(in: .whitespaces)
        // A list item's marker isn't part of the name.
        if let first = line.first, ["•", "◦", "▪", "▪\u{FE0E}", "–", "-", "*", "☐", "☑", "☑\u{FE0E}"].contains(first) { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
        // An ordered item's number too: "3." and its tab ("3.\tSales by region:" names "Sales by region").
        if let number = line.range(of: #"^\d{1,9}[.)]\s+"#, options: .regularExpression) {
            line = String(line[number.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        guard line.count >= 2, line.count <= 80 else { return nil }
        return line
    }

    /// Whether fitting columns to `fitted` widths would break more than a quarter of the short cells (one line at their
    /// column's `natural` width) onto more lines: names and numbers that read better on one line, scrolling sideways.
    /// Cells too long for one line anyway (prose) don't count. `cells`: each body cell's one-line width, 0 when empty.
    static func squeezeBreaksShortCells(_ cells: [[CGFloat]], natural: [CGFloat], fitted: [CGFloat]) -> Bool {
        var short = 0, broken = 0
        for row in cells {
            for (c, w) in row.enumerated() where c < natural.count && c < fitted.count && w > 0 && w <= natural[c] + 0.5 {
                short += 1
                if w > fitted[c] + 0.5 { broken += 1 }
            }
        }
        return short > 0 && broken * 4 > short
    }

    /// Column widths that fill `available`: a table narrower than it grows each column in proportion; a wider one
    /// shrinks each toward its `minimum` (where its words start to wrap) in proportion to how much it can give, and
    /// stays at the minimums when even those don't fit (it scrolls). Whole points; the last column takes the rest.
    static func fit(natural: [CGFloat], minimum: [CGFloat], available: CGFloat) -> [CGFloat] {
        guard !natural.isEmpty, available > 0 else { return natural }
        let total = natural.reduce(0, +)
        var out: [CGFloat]
        if total <= available {
            guard total > 0 else { return natural }
            out = natural.map { $0 + (available - total) * $0 / total }
        } else {
            let floors = zip(natural, minimum).map { min($0, $1) }
            let floor = floors.reduce(0, +)
            guard floor < available else { return floors.map { $0.rounded(.up) } }
            let slack = zip(natural, floors).map { $0 - $1 }
            let slackTotal = slack.reduce(0, +)
            out = zip(floors, slack).map { $0 + $1 * (available - floor) / slackTotal }
        }
        out = out.map { $0.rounded(.down) }
        out[out.count - 1] += max(0, available - out.reduce(0, +)).rounded(.down)
        return out
    }
}
