// [transcript] The table card and the Table page rebuilt 2026-10-29 (owner: the Expand glyph "meshed together with the
// text", and the expanded table "just needs to be a lot better"): numbers in a column, sorting, fitting columns to the
// screen, the CSV and Markdown copies, the caption above a table, and the page itself.

import Foundation
import Testing
import UIKit
@testable import HermesHQNative

@Suite struct TableDataTests {
    @Test func numbersAtTheStartOfACell() {
        #expect(TableData.number("20.7%") == 20.7)
        #expect(TableData.number("$1,234") == 1234)
        #expect(TableData.number("−3") == -3)
        #expect(TableData.number("-$5") == -5)
        #expect(TableData.number("1.2M") == 1_200_000)
        #expect(TableData.number("900k") == 900_000)
        #expect(TableData.number("14.3% (9 booked)") == 14.3)
        #expect(TableData.number("3 Bedrooms") == 3, "a word after the letter: no millions")
        #expect(TableData.number("Robin Vega") == nil)
        #expect(TableData.number("Q3") == nil)
        #expect(TableData.number("") == nil)
    }

    @Test func aCellThatIsOnlyANumber() {
        for yes in ["20.7%", "$5", "1,234", "3x", "10 GB", "-2", ".5", "€12.50", "14.3% (9 booked)"] { #expect(TableData.isNumber(yes), "\(yes)") }
        for no in ["14.3% (9 booked) or so", "2026-10-28", "5 seats", "v2", "Team", ""] { #expect(!TableData.isNumber(no), "\(no)") }
    }

    @Test func columnsOfNumbersReadRightAligned() {
        let rows = [["Starter", "$5", "1", "—"], ["Team", "$20", "", "n/a"], ["Studio", "$60", "40", "-"]]
        #expect(TableData.numericColumns(rows, columns: 4) == [false, true, true, false], "a column of dashes only is not one")
        #expect(TableData.numericColumns([["14.3% (9 booked)"], ["12%"]], columns: 1) == [true], "a bracketed note is fine")
        #expect(TableData.numericColumns([["14% of them"], ["12%"]], columns: 1) == [false])
    }

    @Test func sortingByNumbersAndWords() {
        let rows = [["Adele", "17.4%"], ["Jules", "20.7%"], ["Dorian", ""], ["Abel", "9.2%"], ["Item 10", "—"], ["Item 2", "3%"]]
        #expect(TableData.order(rows, column: 1, ascending: true) == [5, 3, 0, 1, 2, 4], "by value; empty last")
        #expect(TableData.order(rows, column: 1, ascending: false) == [1, 0, 3, 5, 2, 4], "empty last both ways")
        #expect(TableData.order(rows, column: 0, ascending: true) == [3, 0, 2, 5, 4, 1], "Item 2 before Item 10")
        // Equal cells keep their order.
        #expect(TableData.order([["b", "1"], ["a", "1"], ["c", "1"]], column: 1, ascending: true) == [0, 1, 2])
        #expect(TableData.order([["b", "1"], ["a", "1"], ["c", "1"]], column: 1, ascending: false) == [0, 1, 2])
    }

    @Test func csvQuotesWhatNeedsIt() {
        #expect(TableData.csv([["Name", "Note"], ["Tea, green", "said \"hi\""], ["Milk\tfresh", "a\nb"]])
                == "Name,Note\n\"Tea, green\",\"said \"\"hi\"\"\"\nMilk fresh,a b")
    }

    @Test func markdownBackWithItsAlignment() {
        #expect(TableData.markdown([["Plan", "Price"], ["Starter", "$5"], ["a|b"]], alignments: [.natural, .right])
                == "| Plan | Price |\n| --- | ---: |\n| Starter | $5 |\n| a\\|b |  |")
    }

    @Test func theCaptionAboveATable() {
        #expect(TableData.caption(before: "Some words.\n\nRep by rep (minimum 40 orders):") == "Rep by rep (minimum 40 orders)")
        #expect(TableData.caption(before: "Here are the plans.") == nil, "a sentence that doesn't introduce it")
        #expect(TableData.caption(before: "Results", lastLineIsHeading: true) == "Results")
        #expect(TableData.caption(before: "• Weak at follow-up:") == "Weak at follow-up")
        #expect(TableData.caption(before: String(repeating: "word ", count: 30) + ":") == nil, "too long to be a title")
    }

    @Test func columnsFitTheScreen() {
        // Narrower than the screen: each column grows in proportion, whole points, filling it.
        #expect(TableData.fit(natural: [50, 150], minimum: [20, 20], available: 400) == [100, 300])
        // Wider: each shrinks toward its minimum in proportion to what it can give.
        let shrunk = TableData.fit(natural: [200, 100, 300], minimum: [50, 100, 100], available: 400)
        #expect(shrunk.reduce(0, +) == 400)
        #expect(shrunk[1] == 100, "a column at its minimum gives nothing")
        #expect(shrunk[0] >= 50 && shrunk[2] >= 100)
        // Even the minimums don't fit: they stay (the page scrolls sideways).
        #expect(TableData.fit(natural: [200, 300], minimum: [150, 200], available: 300) == [150, 200])
    }

    @Test func squeezingShortCellsIsWorseThanScrolling() {
        // Names that would all wrap: scroll instead.
        let names: [[CGFloat]] = [[120, 50], [110, 48], [130, 52], [100, 50]]
        #expect(TableData.squeezeBreaksShortCells(names, natural: [130, 52], fitted: [90, 52]))
        // One long name wraps: fitting is fine.
        #expect(!TableData.squeezeBreaksShortCells(names, natural: [130, 52], fitted: [125, 52]))
        // Prose longer than its column anyway (and empty cells) doesn't count.
        #expect(!TableData.squeezeBreaksShortCells([[600, 0], [500, 0]], natural: [280, 40], fitted: [200, 40]))
    }

    @Test func theRendererMarksNumbersAndTheCaption() throws {
        let style = ChatStyle.make(category: .large)
        let rendered = MarkdownRenderer.render("**Rep by rep** (minimum 40 orders):\n\n| Rep | Rate | Note |\n|---|---|---|\n| Jules | 20.7% | ok |\n| Abel | 17.3% | |",
                                               style: style)
        let table = try #require(rendered.blocks.compactMap { block -> MarkdownTable? in
            if case .table(let t) = block { return t } else { return nil }
        }.first)
        #expect(table.numeric == [false, true, false])
        #expect(table.alignment(1) == .right && table.alignment(0) == .natural)
        #expect(table.caption == "Rep by rep (minimum 40 orders)")
        // A heading names the table too; plain prose doesn't.
        let headed = MarkdownRenderer.render("## Prices\n\n| a | b |\n|---|---|\n| 1 | 2 |", style: style)
        #expect(headed.blocks.compactMap { if case .table(let t) = $0 { return t.caption } else { return nil } }.first == "Prices")
        let plain = MarkdownRenderer.render("Here you go.\n\n| a | b |\n|---|---|\n| 1 | 2 |", style: style)
        #expect(plain.blocks.compactMap { if case .table(let t) = $0 { return t.caption } else { return nil } }.first == nil)
    }
}

@Suite("Table page", .serialized)
@MainActor
struct TablePageTests {
    let style = ChatStyle.make(category: .large)

    private func table(_ markdown: String) throws -> MarkdownTable {
        try #require(MarkdownRenderer.render(markdown, style: style).blocks.compactMap { block -> MarkdownTable? in
            if case .table(let t) = block { return t } else { return nil }
        }.first)
    }

    private func shown(_ page: TableSheetController, width: CGFloat = 390) -> TableSheetController {
        let navigation = UINavigationController(rootViewController: page)
        navigation.view.frame = CGRect(x: 0, y: 0, width: width, height: 800)
        navigation.view.layoutIfNeeded()
        page.view.layoutIfNeeded()
        return page
    }

    @Test func titledByItsCaptionWithTheBracketsUnder() throws {
        let page = TableSheetController(table: try table("Rep by rep (minimum 40 orders):\n\n| Rep | Rate |\n|---|---|\n| A | 1% |\n| B | 2% |"))
        #expect(page.titles.title == "Rep by rep")
        #expect(page.titles.subtitle == "minimum 40 orders · 2 rows · 2 columns")
        let plain = TableSheetController(table: try table("| a |\n|---|\n| 1 |"))
        #expect(plain.titles == ("Table", "1 row · 1 column"))
        #expect(TableSheetController.make(try table("| a |\n|---|\n| 1 |")).viewControllers.first?.title == "Table")
    }

    @Test func aHeaderTapSortsThenReversesThenRestores() throws {
        let page = shown(TableSheetController(table: try table("| Rep | Rate |\n|---|---|\n| Adele | 17.4% |\n| Jules | 20.7% |\n| Abel | 9.2% |")))
        #expect(page.order == [0, 1, 2])
        page.cycleSort(1)
        #expect(page.order == [2, 0, 1])
        #expect(page.shownRows.map(\.[0]) == ["Rep", "Abel", "Adele", "Jules"])
        page.cycleSort(1)
        #expect(page.order == [1, 0, 2])
        page.cycleSort(1)
        #expect(page.order == [0, 1, 2] && page.sort == nil)
        page.cycleSort(0)
        #expect(page.order == [2, 0, 1])
    }

    @Test func searchShowsMatchingRowsAndCountsThem() throws {
        let body = (1...12).map { "| Rep \($0) | \($0)% |" }.joined(separator: "\n")
        let page = shown(TableSheetController(table: try table("| Rep | Rate |\n|---|---|\n" + body)))
        let search = try #require(page.navigationItem.searchController, "a table of 8 rows or more can be searched")
        search.searchBar.text = "rep 1"
        page.updateSearchResults(for: search)
        #expect(page.order == [0, 9, 10, 11], "Rep 1, Rep 10, Rep 11, Rep 12")
        #expect(page.titles.subtitle == "4 of 12 rows · 2 columns")
        search.searchBar.text = ""
        page.updateSearchResults(for: search)
        #expect(page.order.count == 12)
        let short = shown(TableSheetController(table: try table("| a |\n|---|\n| 1 |")))
        #expect(short.navigationItem.searchController == nil)
    }

    @Test func aWideTableFitsTheScreenOrScrollsWithItsFirstColumnFrozen() throws {
        let words = String(repeating: "long words here ", count: 4)
        let page = shown(TableSheetController(table: try table("| Rep | A | B | C |\n|---|---|---|---|\n| Jules | \(words) | \(words) | \(words) |")))
        #expect(page.canFit, "the columns can share the screen, wrapping")
        #expect(page.fitted && !page.frozen, "fitted by default: nothing scrolls sideways")
        let contents = try #require(page.view.subviews.compactMap { $0 as? UIScrollView }.first)
        #expect(contents.contentSize.width <= 390.5)
        // Without Fit to Screen it scrolls sideways and the first column stays at the left.
        page.setFitted(false)
        #expect(contents.contentSize.width > 390)
        #expect(page.frozen)
    }

    @Test func aTableOfNamesAndNumbersScrollsWithItsFirstColumnPinned() throws {
        let body = (1...6).map { "| Ivy Longname \($0) | \(10 + $0).4% | Another Person \($0) | \($0).1% |" }.joined(separator: "\n")
        let page = shown(TableSheetController(table: try table("| Strong at follow-up | Reply rate | Weak at follow-up | Reply rate |\n|---|---|---|---|\n" + body)))
        #expect(page.canFit)
        #expect(!page.fitted && page.frozen, "squeezed, every name would wrap: it scrolls, the names pinned")
        page.setFitted(true)
        #expect(page.fitted && !page.frozen, "Fit to Screen still squeezes it when picked")
    }
}
