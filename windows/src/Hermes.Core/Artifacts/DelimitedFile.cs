using System.Globalization;
using System.Text;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Artifacts;

// [WIN-FILE-DELIMITED] A .csv or .tsv in the app's own table, as the Mac's file window shows it (App/Mac/SpreadsheetFile.swift
// and MacFileWindow.viewer at 93f984bb1; owner 2026-11-09: "The agent sends you an Excel file and you open it, it just
// isn't good"): the header row that stays put, sorting, search and copy (TableSheetController.filePage). Only the
// delimited text files: an .xlsx still goes to its own app here. A file this can't read (empty, over `MaxBytes`, a
// UTF-16 or UTF-8-marked file that isn't, nothing but blank rows) answers null and opens as it did before. A long
// sheet shows its first rows and says how many there are. Cells are words: one that looks like a formula ("=SUM(A1)",
// "+1", "@x") is shown and copied as it is written, never worked out.

/// One sheet of a delimited file: the rows shown (the header first, every row as wide as the widest) and the body rows
/// the file has (those shown may be fewer). SpreadsheetFile.Sheet.
public sealed record DelimitedSheet(string Name, IReadOnlyList<IReadOnlyList<string>> Rows, int TotalRows)
{
    public int ShownRows => Math.Max(0, Rows.Count - 1);
    public bool IsCut => TotalRows > ShownRows;
    public int Columns => Rows.Count == 0 ? 0 : Rows[0].Count;
}

public static class DelimitedFile
{
    public static readonly IReadOnlySet<string> Extensions = new HashSet<string>(StringComparer.Ordinal) { "csv", "tsv" };
    /// The table page makes a view a cell: a sheet is shown up to these (SpreadsheetFile.maxBytes … maxCells).
    public const int MaxBytes = 8_000_000;
    public const int MaxRows = 400;
    public const int MaxColumns = 40;
    public const int MaxCells = 6_000;

    /// "csv" or "tsv" for a name or path that ends so (any case), else null.
    public static string? Kind(string? nameOrPath)
    {
        if (string.IsNullOrEmpty(nameOrPath)) return null;
        var leaf = nameOrPath.Replace('\\', '/');
        leaf = leaf[(leaf.LastIndexOf('/') + 1)..];
        var dot = leaf.LastIndexOf('.');
        if (dot < 0) return null;
        var ext = leaf[(dot + 1)..].ToLowerInvariant();
        return Extensions.Contains(ext) ? ext : null;
    }

    public static bool Reads(string? nameOrPath) => Kind(nameOrPath) != null;

    /// Whether a file of this name and size is worth reading for the table (the size gate SpreadsheetFile.read checks
    /// before it reads a byte).
    public static bool Opens(string name, long bytes) => Reads(name) && bytes > 0 && bytes <= MaxBytes;

    /// The file at `path` as a table; null when it can't be read here. `name`: the file's own name (an attachment's),
    /// whose extension decides; the path's when the name has none of these.
    public static DelimitedSheet? Read(string path, string? name = null)
    {
        var kind = Kind(name) ?? Kind(path);
        if (kind == null) return null;
        byte[] data;
        try
        {
            var info = new FileInfo(path);
            if (!info.Exists || info.Length <= 0 || info.Length > MaxBytes) return null;
            data = File.ReadAllBytes(path);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException) { return null; }
        if (data.Length == 0 || data.Length > MaxBytes) return null;   // it changed between the look and the read
        var title = name ?? path;
        var leaf = title.Replace('\\', '/');
        leaf = leaf[(leaf.LastIndexOf('/') + 1)..];
        var dot = leaf.LastIndexOf('.');
        return Parse(data, kind == "tsv", dot > 0 ? leaf[..dot] : leaf);
    }

    /// Bytes as a sheet: decoded, split on the separator (a tab for a .tsv, else the first line's most common of comma,
    /// semicolon and tab), shaped to what the page shows.
    public static DelimitedSheet? Parse(byte[] data, bool tab, string name)
    {
        if (data.Length == 0 || data.Length > MaxBytes) return null;
        if (Decode(data) is not { } text) return null;
        return Shape(name, text, tab ? '\t' : Separator(text));
    }

    // MARK: Decoding

    private static readonly Encoding StrictUtf8 = new UTF8Encoding(false, true);
    private static readonly Encoding StrictUtf16Le = new UnicodeEncoding(false, false, true);
    private static readonly Encoding StrictUtf16Be = new UnicodeEncoding(true, false, true);

    /// SpreadsheetFile.decoded: a UTF-8 or UTF-16 mark decides (and a file that isn't what it's marked is not read);
    /// else UTF-8, then Windows-1252 (Excel's "CSV" on Windows), then Latin-1.
    public static string? Decode(byte[] data)
    {
        if (data.Length >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF) return Strict(StrictUtf8, data, 3);
        if (data.Length >= 2 && data[0] == 0xFF && data[1] == 0xFE) return Strict(StrictUtf16Le, data, 2);
        if (data.Length >= 2 && data[0] == 0xFE && data[1] == 0xFF) return Strict(StrictUtf16Be, data, 2);
        return Strict(StrictUtf8, data, 0) ?? Cp1252(data) ?? Encoding.Latin1.GetString(data);
    }

    private static string? Strict(Encoding encoding, byte[] data, int start)
    {
        try { return encoding.GetString(data, start, data.Length - start); }
        catch (DecoderFallbackException) { return null; }
        catch (ArgumentException) { return null; }
    }

    /// Windows-1252's 0x80…0x9F (the rest is Latin-1); its five unassigned bytes make it not Windows-1252.
    private static readonly char[] Cp1252High =
    [
        '\u20AC', '\0', '\u201A', '\u0192', '\u201E', '\u2026', '\u2020', '\u2021', '\u02C6', '\u2030', '\u0160', '\u2039', '\u0152', '\0', '\u017D', '\0',
        '\0', '\u2018', '\u2019', '\u201C', '\u201D', '\u2022', '\u2013', '\u2014', '\u02DC', '\u2122', '\u0161', '\u203A', '\u0153', '\0', '\u017E', '\u0178',
    ];

    private static string? Cp1252(byte[] data)
    {
        var chars = new char[data.Length];
        for (var i = 0; i < data.Length; i++)
        {
            var b = data[i];
            if (b is >= 0x80 and <= 0x9F)
            {
                var c = Cp1252High[b - 0x80];
                if (c == '\0') return null;
                chars[i] = c;
            }
            else chars[i] = (char)b;
        }
        return new string(chars);
    }

    // MARK: Splitting

    /// Swift's `Character.isNewline` for one UTF-16 unit (CR LF is one character; see `Next`).
    private static bool IsNewline(char c) => c is '\n' or '\r' or '\u000B' or '\u000C' or '\u0085' or '\u2028' or '\u2029';

    /// The length of the character (Swift's `Character`: a grapheme cluster, CR LF one) at `i`.
    private static int Next(string text, int i)
    {
        var c = text[i];
        if (c == '\r') return i + 1 < text.Length && text[i + 1] == '\n' ? 2 : 1;
        if (c < 0x80 && (i + 1 == text.Length || text[i + 1] < 0x80)) return 1;   // ASCII then ASCII: always a break
        return StringInfo.GetNextTextElementLength(text, i);
    }

    private static bool IsNewlineCharacter(string text, int i, int length) =>
        length == 1 ? IsNewline(text[i]) : length == 2 && text[i] == '\r' && text[i + 1] == '\n';

    /// SpreadsheetFile.separator: of comma, semicolon (as Excel writes in much of Europe) and tab, the one the first
    /// non-empty line (within the first 4,000 characters) has most of; a comma on a tie or when it has none.
    public static char Separator(string text)
    {
        int start = -1, end = -1, seen = 0, i = 0;
        while (i < text.Length && seen < 4_000)
        {
            var length = Next(text, i);
            if (IsNewlineCharacter(text, i, length))
            {
                if (start >= 0) { end = i; break; }
            }
            else if (start < 0) start = i;
            i += length;
            seen++;
        }
        if (start < 0) return ',';
        if (end < 0) end = i;
        var line = text.AsSpan(start, end - start);
        var best = ','; var most = 0;
        foreach (var mark in new[] { ',', ';', '\t' })
        {
            var count = 0;
            foreach (var c in line) if (c == mark) count++;
            if (count > most) { most = count; best = mark; }
        }
        return best;
    }

    /// SpreadsheetFile.trimmingCharacters(in: .whitespaces).isEmpty: nothing but spaces and tabs (a line break is
    /// something).
    private static bool IsBlank(string cell)
    {
        foreach (var c in cell)
            if (c != '\t' && CharUnicodeInfo.GetUnicodeCategory(c) != UnicodeCategory.SpaceSeparator) return false;
        return true;
    }

    /// SpreadsheetFile.delimited then shaped, in one pass that never holds more than the page can show: a field in
    /// quotes may hold the separator, line breaks and doubled quotes; empty rows and the empty columns at the right are
    /// dropped; every row is as wide as the widest (at most `MaxColumns`); the body is cut to `MaxRows` and to
    /// `MaxCells` cells; the rows the file has are counted. Null for a file with nothing in it.
    public static DelimitedSheet? Shape(string name, string text, char separator)
    {
        // At most MaxRows + 1 rows of at most MaxColumns cells are kept while reading: whatever the final width, the
        // page never shows more (min(MaxRows, MaxCells / width) body rows).
        var kept = new List<List<string>>();
        var keptRows = 0;   // non-empty rows seen
        var width = 0;      // the widest non-empty row's last filled cell + 1
        var row = new List<string>();
        var rowCells = 0;   // cells the current row has had (kept or not)
        var rowLast = -1;   // its last filled cell
        var field = new StringBuilder();
        var quoted = false;

        void EndField()
        {
            var value = field.ToString();
            field.Clear();
            if (!IsBlank(value)) rowLast = rowCells;
            if (rowCells < MaxColumns) row.Add(value);
            rowCells++;
        }

        void EndRow()
        {
            if (rowLast >= 0)
            {
                keptRows++;
                width = Math.Max(width, rowLast + 1);
                if (kept.Count <= MaxRows) kept.Add(row);
            }
            row = [];
            rowCells = 0;
            rowLast = -1;
        }

        var i = 0;
        var pending = -1;   // a character's start, read past a closing quote, still to be handled outside the quotes
        while (true)
        {
            int at, length;
            if (pending >= 0) { at = pending; pending = -1; }
            else if (i < text.Length) at = i;
            else break;
            length = Next(text, at);
            i = at + length;
            var isQuote = length == 1 && text[at] == '"';
            if (quoted)
            {
                if (isQuote)
                {
                    if (i < text.Length)
                    {
                        var nextLength = Next(text, i);
                        if (nextLength == 1 && text[i] == '"') { field.Append('"'); i += 1; }
                        else { quoted = false; pending = i; }
                    }
                    else quoted = false;
                }
                else field.Append(text, at, length);
            }
            else if (isQuote && field.Length == 0) quoted = true;
            else if (length == 1 && text[at] == separator) EndField();
            else if (IsNewlineCharacter(text, at, length)) { EndField(); EndRow(); }
            else field.Append(text, at, length);
        }
        if (field.Length > 0 || rowCells > 0) { EndField(); EndRow(); }

        if (keptRows == 0) return null;
        width = Math.Min(Math.Max(width, 1), MaxColumns);
        var body = Math.Min(MaxRows, Math.Max(1, MaxCells / width));
        var shown = kept.Take(body + 1).Select(r =>
        {
            var cells = new string[width];
            for (var c = 0; c < width; c++) cells[c] = c < r.Count ? r[c].Replace("\r\n", "\n") : "";
            return (IReadOnlyList<string>)cells;
        }).ToList();
        return new DelimitedSheet(name, shown, Math.Max(keptRows - 1, shown.Count - 1));
    }
}

/// The table page's state for a file's sheet (TableSheetController with `fileRows`): a header click sorts ascending,
/// then descending, then back to the file's order; search keeps the rows with a cell holding the words (case and
/// accents aside); the copies are the rows as shown. No WinUI: the page (Features/Artifacts/DelimitedTableView.cs)
/// draws what this decides.
public sealed class DelimitedTable
{
    public const string CopyTitle = TableText.CopyTitle;
    public const string CopyCsvTitle = "Copy as CSV";
    public const string CopyMarkdownTitle = "Copy as Markdown";
    public const string PageId = TableText.SheetId;
    public const string SearchId = "table.sheet.search";
    /// Search shows from this many body rows (TableSheetController.searchFrom).
    public const int SearchFrom = 8;

    public DelimitedTable(DelimitedSheet sheet, string title)
    {
        Title = title;
        Header = sheet.Rows.Count > 0 ? sheet.Rows[0] : [];
        Body = [.. sheet.Rows.Skip(1)];
        Columns = Header.Count;
        FileRows = sheet.IsCut ? sheet.TotalRows : null;
        Numeric = TableData.NumericColumns(Body, Columns);
        Order = [.. Enumerable.Range(0, Body.Count)];
    }

    public string Title { get; }
    public IReadOnlyList<string> Header { get; }
    public IReadOnlyList<IReadOnlyList<string>> Body { get; }
    public int Columns { get; }
    /// The body rows the whole file has, when only its first are shown.
    public int? FileRows { get; }
    /// Columns of numbers: they read right-aligned.
    public IReadOnlyList<bool> Numeric { get; }
    public (int Column, bool Ascending)? Sort { get; private set; }
    public string Query { get; private set; } = "";
    /// The body rows shown, in the order shown (indexes into `Body`).
    public IReadOnlyList<int> Order { get; private set; }

    public bool ShowsSearch => Body.Count >= SearchFrom;
    public string SearchPlaceholder => $"Search {Body.Count} Rows";

    /// A header click: ascending, then descending, then the file's order. Answers what is read aloud.
    public string CycleSort(int column)
    {
        if (column < 0 || column >= Columns) return "";
        Sort = Sort is { } s && s.Column == column ? (s.Ascending ? (column, false) : null) : (column, true);
        Apply();
        var name = Header[column].Length > 0 ? Header[column] : $"column {column + 1}";
        return Sort is { } now ? $"Sorted by {name}, {(now.Ascending ? "ascending" : "descending")}" : "Original order";
    }

    public void Search(string text)
    {
        if (text == Query) return;
        Query = text;
        Apply();
    }

    private void Apply()
    {
        List<int> next = Sort is { } s ? TableData.Order(Body, s.Column, s.Ascending) : [.. Enumerable.Range(0, Body.Count)];
        var needle = Query.Trim(' ', '\t');
        if (needle.Length > 0)
        {
            var compare = CultureInfo.CurrentCulture.CompareInfo;
            next = [.. next.Where(r => Body[r].Any(cell => compare.IndexOf(cell, needle, CompareOptions.IgnoreCase | CompareOptions.IgnoreNonSpace) >= 0))];
        }
        Order = next;
    }

    /// The header's sort mark for a column: an arrow up or down when it sorts, else nothing.
    public string SortMark(int column) => Sort is { } s && s.Column == column ? (s.Ascending ? "\u2191" : "\u2193") : "";

    /// The line under the title: "12 rows · 3 columns", "2 of 12 rows · 3 columns" while searching, "first 400 of
    /// 1,000 rows · 3 columns" for a long file (TableSheetController.titles).
    public string Subtitle(IFormatProvider? format = null)
    {
        var total = Body.Count;
        var rows = Query.Length == 0
            ? $"{total} {(total == 1 ? "row" : "rows")}"
            : $"{Order.Count} of {total} rows";
        if (FileRows is { } all && all > total && Query.Length == 0)
            rows = string.Format(format ?? CultureInfo.CurrentCulture, "first {0:N0} of {1:N0} rows", total, all);
        return $"{rows} \u00b7 {Columns} {(Columns == 1 ? "column" : "columns")}";
    }

    /// The rows as shown (sorted and searched), the header first: what the copies take.
    public IReadOnlyList<IReadOnlyList<string>> ShownRows() => [Header, .. Order.Select(r => Body[r])];

    /// Copy as Text: tab-separated (what a spreadsheet pastes as cells); null when there is nothing to copy.
    public string? CopyText() => TableText.Copyable(ShownRows());
    public string CopyCsv() => TableData.Csv(ShownRows());
    public string CopyMarkdown() =>
        TableData.Markdown(ShownRows(), [.. Numeric.Select(n => n ? TableAlignment.Right : TableAlignment.Natural)]);

    /// A column's width in the page: its longest line, in characters, at about `perChar` each, with room for the
    /// padding and the sort mark; never under 64 or over 360.
    public double ColumnWidth(int column, double perChar = 7.5)
    {
        var longest = Header.Count > column ? Longest(Header[column]) : 0;
        foreach (var row in Body) if (column < row.Count) longest = Math.Max(longest, Longest(row[column]));
        return Math.Clamp(Math.Ceiling(longest * perChar + 40), 64, 360);
    }

    private static int Longest(string cell)
    {
        var most = 0;
        foreach (var line in cell.Split('\n')) most = Math.Max(most, line.Length);
        return most;
    }
}
