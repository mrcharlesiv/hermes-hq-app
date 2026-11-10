#if targetEnvironment(macCatalyst)
import UIKit

/// [mac-ui-issues] Owner 2026-11-09 ("The agent sends you an Excel file and you open it, it just isn't good"): Quick Look
/// drew a spreadsheet as a small white printed page with tiny text in the middle of the file window. The Mac's file
/// window now shows a spreadsheet (.xlsx, .csv, .tsv) in the app's own table (`TableSheetController`: a header row that
/// stays put, sorting, search, copy), read here. An .xlsx is a zip of XML: the sheets' names, the shared strings, the
/// number formats (dates, percents, money) and each sheet's cells are read with Foundation alone. A file this can't
/// read (an old .xls, a Numbers file, a zip64 or damaged workbook, one over `maxBytes`) answers nil and Quick Look
/// shows it as before. A long sheet shows its first rows and says how many there are (Open in Numbers has them all).
nonisolated enum SpreadsheetFile {
    nonisolated struct Sheet {
        var name: String
        /// The rows shown, the header first, every row as wide as the widest.
        var rows: [[String]]
        /// The body rows the sheet has (those shown may be fewer).
        var totalRows: Int

        var shownRows: Int { max(0, rows.count - 1) }
        var isCut: Bool { totalRows > shownRows }
    }

    static let extensions: Set<String> = ["xlsx", "csv", "tsv"]
    /// The table page makes a view a cell: a sheet is shown up to these.
    static let maxBytes = 8_000_000
    static let maxRows = 400
    static let maxColumns = 40
    static let maxCells = 6_000

    static func reads(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    /// The file's sheets that have something in them; nil when it can't be read here.
    static func read(_ url: URL) -> [Sheet]? {
        guard reads(url),
              let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0, size <= maxBytes,
              let data = try? Data(contentsOf: url) else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        let sheets: [Sheet]
        switch url.pathExtension.lowercased() {
        case "xlsx":
            guard let book = Workbook(data) else { return nil }
            sheets = book.sheets()
        default:
            guard let text = decoded(data) else { return nil }
            let tab = url.pathExtension.lowercased() == "tsv"
            let all = delimited(text, separator: tab ? "\t" : separator(of: text))
            sheets = [shaped(name: name, rows: all, more: 0)].compactMap { $0 }
        }
        return sheets.isEmpty ? nil : sheets
    }

    /// The table page's table for a sheet: the first row is the header.
    @MainActor static func table(_ sheet: Sheet, named title: String) -> MarkdownTable {
        let font = ChatStyleCache.shared.style(for: UITraitCollection.current.preferredContentSizeCategory).table
        func cell(_ words: String) -> NSAttributedString { NSAttributedString(string: words, attributes: [.font: font, .foregroundColor: ChatPalette.label]) }
        let header = (sheet.rows.first ?? []).map(cell)
        let body = Array(sheet.rows.dropFirst())
        let plain = TableText.text(sheet.rows)
        var made = MarkdownTable(header: header, rows: body.map { $0.map(cell) }, alignments: [], plain: plain,
                                 flat: NSAttributedString(string: plain, attributes: [.font: font]))
        made.numeric = TableData.numericColumns(body, columns: header.count)
        made.caption = title
        return made
    }

    // MARK: Shaping

    /// Empty rows and the empty columns at the right dropped, every row the same width, cut to what the page shows.
    /// `more` counts rows that were seen but not kept. Nil for a sheet with nothing in it.
    static func shaped(name: String, rows: [[String]], more: Int) -> Sheet? {
        var kept = rows.filter { row in row.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
        guard !kept.isEmpty else { return nil }
        var width = 0
        for row in kept { if let last = row.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) { width = max(width, last + 1) } }
        width = min(max(width, 1), maxColumns)
        let total = kept.count - 1 + more
        let body = min(maxRows, max(1, maxCells / width))
        if kept.count > body + 1 { kept = Array(kept.prefix(body + 1)) }
        let even = kept.map { row -> [String] in
            let cut = Array(row.prefix(width)).map { $0.replacingOccurrences(of: "\r\n", with: "\n") }
            return cut + Array(repeating: "", count: width - cut.count)
        }
        return Sheet(name: name, rows: even, totalRows: max(total, even.count - 1))
    }

    // MARK: Text files

    static func decoded(_ data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(data: data.dropFirst(3), encoding: .utf8) }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16) }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1)
    }

    /// A .csv's separator: the one its first line has most of (a comma, a semicolon as Excel writes in much of Europe,
    /// or a tab).
    static func separator(of text: String) -> Character {
        let line = text.prefix(4_000).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let counts: [(Character, Int)] = [",", ";", "\t"].map { mark in (mark, line.filter { $0 == mark }.count) }
        return counts.max { $0.1 < $1.1 }.flatMap { $0.1 > 0 ? $0.0 : nil } ?? ","
    }

    /// The rows of a delimited text: a field in quotes may hold the separator, line breaks and doubled quotes.
    static func delimited(_ text: String, separator: Character) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var characters = text.makeIterator()
        var pending: Character?
        while let character = pending ?? characters.next() {
            pending = nil
            if quoted {
                if character == "\"" {
                    if let next = characters.next() {
                        if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(character)
                }
            } else if character == "\"", field.isEmpty {
                quoted = true
            } else if character == separator {
                row.append(field); field = ""
            } else if character.isNewline {
                row.append(field); field = ""
                rows.append(row); row = []
            } else {
                field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    // MARK: A workbook (.xlsx)

    /// The files inside a zip, read from its directory at the end. Stored and deflated files only; a zip64 archive
    /// isn't read.
    nonisolated struct Archive {
        private struct Entry { let method: Int, packed: Int, size: Int, offset: Int }
        private let data: Data
        private var entries: [String: Entry] = [:]

        init?(_ data: Data) {
            self.data = data
            let count = data.count
            guard count >= 22 else { return nil }
            var end = -1
            var at = count - 22
            let stop = max(0, count - 22 - 65_535)
            while at >= stop {
                if data[at] == 0x50, data[at + 1] == 0x4B, data[at + 2] == 0x05, data[at + 3] == 0x06 { end = at; break }
                at -= 1
            }
            guard end >= 0 else { return nil }
            let files = u16(end + 10)
            var offset = u32(end + 16)
            guard files != 0xFFFF, offset != 0xFFFF_FFFF else { return nil }
            for _ in 0..<files {
                guard offset + 46 <= count, u32(offset) == 0x0201_4B50 else { return nil }
                let nameLength = u16(offset + 28), extra = u16(offset + 30), comment = u16(offset + 32)
                guard offset + 46 + nameLength <= count else { return nil }
                let name = String(decoding: data[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)
                entries[name] = Entry(method: u16(offset + 10), packed: u32(offset + 20), size: u32(offset + 24), offset: u32(offset + 42))
                offset += 46 + nameLength + extra + comment
            }
        }

        private func u16(_ at: Int) -> Int { Int(data[at]) | Int(data[at + 1]) << 8 }
        private func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }

        /// A file's bytes; nil when it isn't there, is too big to be a sheet, or is packed another way.
        func file(_ name: String) -> Data? {
            guard let entry = entries[name], entry.size <= 96_000_000, entry.offset + 30 <= data.count,
                  u32(entry.offset) == 0x0403_4B50 else { return nil }
            let start = entry.offset + 30 + u16(entry.offset + 26) + u16(entry.offset + 28)
            guard start + entry.packed <= data.count else { return nil }
            let packed = data.subdata(in: start..<(start + entry.packed))
            switch entry.method {
            case 0: return packed
            case 8: return try? (packed as NSData).decompressed(using: .zlib) as Data   // raw DEFLATE
            default: return nil
            }
        }
    }

    nonisolated struct Workbook {
        private let archive: Archive
        private var named: [(name: String, path: String)] = []
        private var strings: [String] = []
        private var formats = Formats()

        init?(_ data: Data) {
            guard let archive = Archive(data), let book = archive.file("xl/workbook.xml") else { return nil }
            self.archive = archive
            var ids: [(name: String, id: String)] = []
            var from1904 = false
            Elements.read(book) { element, attributes in
                if element == "sheet", let name = attributes["name"], let id = attributes["r:id"] ?? attributes["id"] {
                    ids.append((name, id))
                } else if element == "workbookPr", let flag = attributes["date1904"], flag == "1" || flag == "true" {
                    from1904 = true
                }
            }
            var targets: [String: String] = [:]
            if let rels = archive.file("xl/_rels/workbook.xml.rels") {
                Elements.read(rels) { element, attributes in
                    if element == "Relationship", let id = attributes["Id"], let target = attributes["Target"] { targets[id] = target }
                }
            }
            for (index, sheet) in ids.enumerated() {
                let target = targets[sheet.id] ?? "worksheets/sheet\(index + 1).xml"
                named.append((sheet.name, target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target))
            }
            guard !named.isEmpty else { return nil }
            formats.from1904 = from1904
            if let shared = archive.file("xl/sharedStrings.xml") { strings = SharedStrings.read(shared) }
            if let styles = archive.file("xl/styles.xml") { formats.read(styles) }
        }

        /// The sheets with something in them, in the workbook's order.
        func sheets() -> [Sheet] {
            named.compactMap { sheet in
                guard let xml = archive.file(sheet.path) else { return nil }
                let cells = SheetCells(strings: strings, formats: formats)
                let parser = XMLParser(data: xml)
                parser.delegate = cells
                parser.parse()
                return SpreadsheetFile.shaped(name: sheet.name, rows: cells.rows, more: cells.more)
            }
        }
    }

    /// An XML file's elements and their attributes, in order (a prefix as in "x:sheet" dropped).
    nonisolated final class Elements: NSObject, XMLParserDelegate {
        private let each: (String, [String: String]) -> Void
        private init(_ each: @escaping (String, [String: String]) -> Void) { self.each = each }

        static func read(_ data: Data, _ each: @escaping (String, [String: String]) -> Void) {
            withoutActuallyEscaping(each) { each in
                let reader = Elements(each)
                let parser = XMLParser(data: data)
                parser.delegate = reader
                parser.parse()
            }
        }

        static func plain(_ name: String) -> String { name.split(separator: ":").last.map(String.init) ?? name }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            each(Self.plain(elementName), attributeDict)
        }
    }

    /// The workbook's shared strings: a cell of text names one by its place. A string in runs (part bold) reads as
    /// one; its phonetic guide (Japanese) is left out.
    nonisolated final class SharedStrings: NSObject, XMLParserDelegate {
        private var strings: [String] = []
        private var current = ""
        private var inText = false
        private var phonetic = 0

        static func read(_ data: Data) -> [String] {
            let reader = SharedStrings()
            let parser = XMLParser(data: data)
            parser.delegate = reader
            parser.parse()
            return reader.strings
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            switch Elements.plain(elementName) {
            case "si": current = ""
            case "rPh": phonetic += 1
            case "t": inText = phonetic == 0
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { if inText { current += string } }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            switch Elements.plain(elementName) {
            case "si": strings.append(current)
            case "rPh": phonetic -= 1
            case "t": inText = false
            default: break
            }
        }
    }

    /// How a number cell reads: a cell names a style, the style a number format (a built-in number or a written code).
    nonisolated struct Formats {
        var from1904 = false
        private var codes: [Int: String] = [:]
        private var styles: [Int] = []

        mutating func read(_ data: Data) {
            var codes: [Int: String] = [:], styles: [Int] = []
            var inCells = false
            let reader = StyleReader { element, attributes, opening in
                if element == "cellXfs" { inCells = opening; return }
                guard opening else { return }
                if element == "numFmt", let id = attributes["numFmtId"].flatMap({ Int($0) }), let code = attributes["formatCode"] {
                    codes[id] = code
                } else if element == "xf", inCells {
                    styles.append(attributes["numFmtId"].flatMap { Int($0) } ?? 0)
                }
            }
            let parser = XMLParser(data: data)
            parser.delegate = reader
            parser.parse()
            self.codes = codes
            self.styles = styles
        }

        private static let builtIn: [Int: String] = [
            1: "0", 2: "0.00", 3: "#,##0", 4: "#,##0.00", 9: "0%", 10: "0.00%", 11: "0.00E+00", 37: "#,##0", 38: "#,##0",
            39: "#,##0.00", 40: "#,##0.00", 44: "$#,##0.00", 42: "$#,##0", 41: "#,##0", 43: "#,##0.00", 48: "0.0E+0",
            5: "$#,##0", 6: "$#,##0", 7: "$#,##0.00", 8: "$#,##0.00",
            14: "m/d/yyyy", 15: "d-mmm-yy", 16: "d-mmm", 17: "mmm-yy", 18: "h:mm", 19: "h:mm:ss", 20: "h:mm", 21: "h:mm:ss",
            22: "m/d/yyyy h:mm", 45: "mm:ss", 46: "h:mm:ss", 47: "mm:ss",
        ]

        /// The format code of style `style` (nil: General).
        func code(style: Int?) -> String? {
            guard let style, style >= 0, style < styles.count else { return nil }
            let id = styles[style]
            if let written = codes[id] { return written }
            if let known = Self.builtIn[id] { return known }
            return (27...36).contains(id) || (50...58).contains(id) ? "yyyy/m/d" : nil   // East Asian date formats
        }

        /// A stored number as its cell shows it.
        func text(_ raw: String, style: Int?) -> String {
            guard let number = Double(raw), number.isFinite else { return raw }
            guard let code = code(style: style) else { return Self.general(number) }
            // The first section (positive numbers), without its quoted words, colours and conditions.
            var letters = ""
            var quoted = false, bracket = false, skip = false
            var money = ""
            for character in code {
                if skip { skip = false; continue }
                if quoted { if character == "\"" { quoted = false }; continue }
                if bracket {
                    if character == "]" { bracket = false }
                    continue
                }
                switch character {
                case "\"": quoted = true
                case "\\", "_", "*": skip = true
                case "[": bracket = true
                case ";": break
                default: letters.append(character)
                }
                if character == ";" { break }
            }
            if let open = code.range(of: "[$"), let close = code[open.upperBound...].firstIndex(of: "]") {
                money = String(code[open.upperBound..<close].split(separator: "-", omittingEmptySubsequences: false).first ?? "")
            }
            let low = letters.lowercased()
            if low == "general" || low.isEmpty { return Self.general(number) }
            let dateLetters = low.contains("y") || low.contains("d") || low.contains("h") || low.contains("s")
            if dateLetters || (low.contains("m") && !low.contains("0") && !low.contains("#")) {
                return date(number, day: low.contains("y") || low.contains("d") || (low.contains("m") && !low.contains("h") && !low.contains("s")),
                            time: low.contains("h") || low.contains("s"), seconds: low.contains("s"))
            }
            if low.contains("e+") || low.contains("e-") { return Self.general(number) }
            var decimals = 0
            if let dot = letters.firstIndex(of: ".") { decimals = letters[letters.index(after: dot)...].prefix { $0 == "0" || $0 == "#" }.count }
            let percent = letters.contains("%")
            let grouped = letters.contains(",")
            if money.isEmpty, let sign = letters.first(where: { "$€£¥".contains($0) }) { money = String(sign) }
            let value = percent ? number * 100 : number
            let digits = Self.fixed(abs(value), decimals: decimals, grouped: grouped)
            return (value < 0 ? "-" : "") + money + digits + (percent ? "%" : "")
        }

        /// A number with no format: whole when it is, else its digits without a float's noise.
        static func general(_ number: Double) -> String {
            if number == number.rounded(), abs(number) < 1e15 { return String(Int64(number)) }
            return String(format: "%.10g", number)
        }

        private static func fixed(_ number: Double, decimals: Int, grouped: Bool) -> String {
            let plain = String(format: "%.\(min(decimals, 10))f", number)
            guard grouped else { return plain }
            let parts = plain.split(separator: ".", omittingEmptySubsequences: false)
            var whole = "", count = 0
            for digit in (parts.first ?? "").reversed() {
                if count > 0, count % 3 == 0 { whole.append(",") }
                whole.append(digit)
                count += 1
            }
            return String(whole.reversed()) + (parts.count > 1 ? "." + parts[1] : "")
        }

        /// A date kept as days since 1900 (or 1904): "Nov 9, 2026", "Nov 9, 2026 at 3:30 PM", "3:30 PM".
        private func date(_ serial: Double, day: Bool, time: Bool, seconds: Bool) -> String {
            let days = from1904 ? serial + 1462 : serial
            let when = Date(timeIntervalSince1970: ((days - 25569) * 86_400).rounded())
            let showDay = day && serial >= 1
            let showTime = time || !showDay
            var style = Date.FormatStyle(timeZone: .gmt)
            if showDay { style = style.year().month(.abbreviated).day() }
            if showTime { style = seconds ? style.hour().minute().second() : style.hour().minute() }
            return when.formatted(style)
        }
    }

    nonisolated final class StyleReader: NSObject, XMLParserDelegate {
        private let each: (String, [String: String], Bool) -> Void
        init(_ each: @escaping (String, [String: String], Bool) -> Void) { self.each = each }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            each(Elements.plain(elementName), attributeDict, true)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            each(Elements.plain(elementName), [:], false)
        }
    }

    /// A sheet's cells as the words they show, row by row. Past what the page shows, rows are only counted.
    nonisolated final class SheetCells: NSObject, XMLParserDelegate {
        private(set) var rows: [[String]] = []
        /// Rows with something in them that weren't kept.
        private(set) var more = 0
        private let strings: [String]
        private let formats: Formats
        private var row: [String] = []
        private var rowHasWords = false
        private var column = 0
        private var kind: String?
        private var style: Int?
        private var words = ""
        private var reading = false
        private var counting: Bool { rows.count > SpreadsheetFile.maxRows + 40 }

        init(strings: [String], formats: Formats) {
            self.strings = strings
            self.formats = formats
        }

        /// "AB12" is column 27 (from 0).
        private static func column(of reference: String) -> Int? {
            var index = 0, any = false
            for scalar in reference.unicodeScalars {
                guard scalar.value >= 65, scalar.value <= 90 else { break }
                index = index * 26 + Int(scalar.value - 64)
                any = true
            }
            return any ? index - 1 : nil
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            switch Elements.plain(elementName) {
            case "row":
                row = []; rowHasWords = false; column = 0
            case "c":
                if let at = attributeDict["r"].flatMap(Self.column(of:)) { column = at }
                kind = attributeDict["t"]
                style = attributeDict["s"].flatMap { Int($0) }
                words = ""
            case "v": reading = true
            case "t": reading = kind == "inlineStr"
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard reading else { return }
            rowHasWords = true
            if !counting { words += string }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            switch Elements.plain(elementName) {
            case "v", "t": reading = false
            case "c":
                defer { column += 1 }
                guard !counting, !words.isEmpty, column < SpreadsheetFile.maxColumns else { return }
                let shown: String
                switch kind {
                case "s": shown = Int(words).flatMap { $0 >= 0 && $0 < strings.count ? strings[$0] : nil } ?? ""
                case "b": shown = words == "1" ? "TRUE" : "FALSE"
                case "inlineStr", "str", "e", "d": shown = words
                default: shown = formats.text(words, style: style)
                }
                if row.count < column { row += Array(repeating: "", count: column - row.count) }
                if row.count == column { row.append(shown) } else { row[column] = shown }
            case "row":
                guard rowHasWords else { return }
                if counting { more += 1 } else { rows.append(row) }
            default: break
            }
        }
    }
}
#endif
