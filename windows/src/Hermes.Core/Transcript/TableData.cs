using System.Globalization;
using System.Text.RegularExpressions;

namespace Hermes.Core.Transcripts;

// Ports of HermesKit/Chat/Transcript/TableData.swift and TableText.swift: what the table card and the Table page work
// out from a table's words — which columns hold numbers (they read right-aligned), the order a clicked column sorts in,
// column widths fitted to a window, the CSV, Markdown and tab-separated copies, and the words above a table that name it.

public enum TableAlignment { Natural, Center, Right }

public static class TableData
{
    /// An optional sign and currency, the digits, then an optional unit; group 5 is whatever follows.
    private static readonly TranscriptRx Leading = new(@"^\s*([+\-−]?)\s*[$€£¥]?\s*([+\-−]?)(\d[\d,]*(?:\.\d+)?|\.\d+)\s?(GB|MB|KB|TB|bn|pts?|pp|ms|%|x|×|k|K|M|B|s|h)?(.*)$");
    /// Cells that stand for "no value" and don't stop a column of numbers being one.
    private static readonly HashSet<string> Blanks = ["", "-", "–", "—", "n/a", "N/A", "NA", "?"];

    /// The number a cell starts with ("20.7%" → 20.7, "$1,234" → 1234, "−3" → -3, "1.2M" → 1,200,000,
    /// "14.3% (9 booked)" → 14.3); null when it doesn't start with one.
    public static double? Number(string text)
    {
        if (Leading.Groups(text) is not { } g || g[3] is not { } digits
            || !double.TryParse(digits.Replace(",", ""), NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture, out var value)) return null;
        static bool Minus(string? s) => s is "-" or "−";
        var negative = Minus(g[1]) || Minus(g[2]);
        var rest = g[5] ?? "";
        // "1.2M" scales; "3 Bedrooms" (a word goes on after the letter) does not.
        double scale = rest.Length > 0 && char.IsLetter(rest[0]) ? 1 : g[4] switch
        {
            "k" or "K" => 1_000,
            "M" => 1_000_000,
            "B" or "bn" => 1_000_000_000,
            _ => 1,
        };
        return (negative ? -value : value) * scale;
    }

    /// A bracketed note after a number: "14.3% (9 booked)".
    private static readonly TranscriptRx Note = new(@"^\s*\([^()]*\)\s*$");

    /// A cell that is just a number (with its sign, currency or unit, and maybe a bracketed note).
    public static bool IsNumber(string text)
    {
        if (Leading.Groups(text) is not { } g || g[3] is null) return false;
        var rest = TxText.TrimSpaces(g[5] ?? "");
        return rest.Length == 0 || Note.Test(rest);
    }

    private static string Cell(IReadOnlyList<string> row, int c) => c < row.Count ? TxText.TrimSpaces(row[c]) : "";

    /// Columns whose filled body cells are all numbers (and at least one is): they read right-aligned.
    public static List<bool> NumericColumns(IReadOnlyList<IReadOnlyList<string>> rows, int columns) =>
        [.. Enumerable.Range(0, columns).Select(c =>
        {
            var any = false;
            foreach (var row in rows)
            {
                var cell = Cell(row, c);
                if (Blanks.Contains(cell)) continue;
                if (!IsNumber(cell)) return false;
                any = true;
            }
            return any;
        })];

    /// Finder's order for names (`localizedStandardCompare`): case-insensitive, runs of digits by their value
    /// ("Item 2" before "Item 10").
    public static int StandardCompare(string a, string b)
    {
        int i = 0, j = 0;
        var compare = CultureInfo.CurrentCulture.CompareInfo;
        while (i < a.Length && j < b.Length)
        {
            if (char.IsAsciiDigit(a[i]) && char.IsAsciiDigit(b[j]))
            {
                int si = i, sj = j;
                while (i < a.Length && char.IsAsciiDigit(a[i])) i++;
                while (j < b.Length && char.IsAsciiDigit(b[j])) j++;
                var na = a[si..i].TrimStart('0');
                var nb = b[sj..j].TrimStart('0');
                if (na.Length != nb.Length) return na.Length < nb.Length ? -1 : 1;
                var byDigits = string.CompareOrdinal(na, nb);
                if (byDigits != 0) return Math.Sign(byDigits);
                continue;
            }
            int ei = i, ej = j;
            while (ei < a.Length && !char.IsAsciiDigit(a[ei])) ei++;
            while (ej < b.Length && !char.IsAsciiDigit(b[ej])) ej++;
            var words = compare.Compare(a[i..ei], b[j..ej], CompareOptions.IgnoreCase | CompareOptions.IgnoreNonSpace | CompareOptions.IgnoreWidth);
            if (words != 0) return Math.Sign(words);
            i = ei; j = ej;
        }
        return (a.Length - i).CompareTo(b.Length - j) switch { < 0 => -1, > 0 => 1, _ => 0 };
    }

    /// The body rows' order sorted by `column`: by value when most of its filled cells start with a number, else by
    /// their words as Finder sorts names. Empty cells go last either way; equal cells keep their order.
    public static List<int> Order(IReadOnlyList<IReadOnlyList<string>> rows, int column, bool ascending)
    {
        var cells = rows.Select(r => Cell(r, column)).ToList();
        var numbers = cells.Select(Number).ToList();
        var filled = cells.Count(c => !Blanks.Contains(c));
        var byNumber = filled > 0 && numbers.Count(n => n is not null) * 2 >= filled;
        bool Less(int a, int b)
        {
            bool emptyA = Blanks.Contains(cells[a]), emptyB = Blanks.Contains(cells[b]);
            if (emptyA != emptyB) return emptyB;
            if (emptyA) return a < b;
            int result;
            if (byNumber && numbers[a] is { } x && numbers[b] is { } y)
                result = x < y ? -1 : x > y ? 1 : StandardCompare(cells[a], cells[b]);
            else if (byNumber && (numbers[a] is null) != (numbers[b] is null))
                return numbers[a] is not null;   // numbers before words, both ways
            else
                result = StandardCompare(cells[a], cells[b]);
            if (result == 0) return a < b;
            return ascending ? result < 0 : result > 0;
        }
        var order = Enumerable.Range(0, cells.Count).ToList();
        order.Sort((a, b) => a == b ? 0 : Less(a, b) ? -1 : Less(b, a) ? 1 : 0);
        return order;
    }

    /// Comma-separated rows (RFC 4180: a cell with a comma or quote is quoted, its quotes doubled), what Excel opens as a sheet.
    public static string Csv(IEnumerable<IEnumerable<string>> rows) =>
        string.Join("\n", rows.Select(row => string.Join(",", row.Select(raw =>
        {
            var cell = TableText.Cell(raw);
            return cell.Contains(',') || cell.Contains('"') ? "\"" + cell.Replace("\"", "\"\"") + "\"" : cell;
        }))));

    /// The table back as Markdown (header, its alignment row, the body), every row as wide as the widest.
    public static string Markdown(IReadOnlyList<IReadOnlyList<string>> rows, IReadOnlyList<TableAlignment> alignments)
    {
        if (rows.Count == 0) return "";
        var columns = Math.Max(rows[0].Count, rows.Max(r => r.Count));
        if (columns <= 0) return "";
        string Line(IReadOnlyList<string> cells) =>
            "| " + string.Join(" | ", Enumerable.Range(0, columns).Select(c => TableText.Cell(c < cells.Count ? cells[c] : "").Replace("|", "\\|"))) + " |";
        var rule = "|" + string.Join("|", Enumerable.Range(0, columns).Select(c => (c < alignments.Count ? alignments[c] : TableAlignment.Natural) switch
        {
            TableAlignment.Center => " :---: ",
            TableAlignment.Right => " ---: ",
            _ => " --- ",
        })) + "|";
        return string.Join("\n", new[] { Line(rows[0]), rule }.Concat(rows.Skip(1).Select(Line)));
    }

    private static readonly string[] ListMarkers = ["▪︎", "☑︎", "•", "◦", "▪", "–", "-", "*", "☐", "☑"];
    private static readonly Regex OrderedNumber = new(@"^\d{1,9}[.)]\s+", RegexOptions.CultureInvariant);

    /// The words above a table that name it: the last line of the prose before it when that line introduces it
    /// ("Rep by rep (minimum 40 orders):") or is a heading, without the colon. Null otherwise, or when too long.
    public static string? Caption(string prose, bool lastLineIsHeading = false)
    {
        var lines = TxText.NonEmptyLines(prose);
        if (lines.Count == 0) return null;
        var line = TxText.TrimSpaces(lines[^1]);
        var introduces = line.EndsWith(':');
        if (!introduces && !lastLineIsHeading) return null;
        line = TxText.TrimSpaces(line.TrimEnd(':'));
        // A list item's marker isn't part of the name.
        if (ListMarkers.FirstOrDefault(m => line.StartsWith(m, StringComparison.Ordinal)) is { } marker)
            line = TxText.TrimSpaces(line[marker.Length..]);
        // An ordered item's number too: "3." and its tab ("3.\tSales by region:" names "Sales by region").
        if (OrderedNumber.Match(line) is { Success: true } number) line = TxText.TrimSpaces(line[number.Length..]);
        if (line.Length < 2 || line.Length > 80) return null;
        return line;
    }

    /// Whether fitting columns to `fitted` widths would break more than a quarter of the short cells (one line at their
    /// column's `natural` width) onto more lines. `cells`: each body cell's one-line width, 0 when empty.
    public static bool SqueezeBreaksShortCells(IReadOnlyList<IReadOnlyList<double>> cells, IReadOnlyList<double> natural, IReadOnlyList<double> fitted)
    {
        int shortCells = 0, broken = 0;
        foreach (var row in cells)
            for (var c = 0; c < row.Count; c++)
            {
                var w = row[c];
                if (c >= natural.Count || c >= fitted.Count || w <= 0 || w > natural[c] + 0.5) continue;
                shortCells++;
                if (w > fitted[c] + 0.5) broken++;
            }
        return shortCells > 0 && broken * 4 > shortCells;
    }

    /// Column widths that fill `available`: a table narrower than it grows each column in proportion; a wider one shrinks
    /// each toward its `minimum` in proportion to how much it can give, and stays at the minimums when even those don't
    /// fit (it scrolls). Whole points; the last column takes the rest.
    public static List<double> Fit(IReadOnlyList<double> natural, IReadOnlyList<double> minimum, double available)
    {
        if (natural.Count == 0 || available <= 0) return [.. natural];
        var total = natural.Sum();
        List<double> out_;
        if (total <= available)
        {
            if (total <= 0) return [.. natural];
            out_ = [.. natural.Select(n => n + (available - total) * n / total)];
        }
        else
        {
            var floors = natural.Zip(minimum, Math.Min).ToList();
            var floor = floors.Sum();
            if (floor >= available) return [.. floors.Select(Math.Ceiling)];
            var slack = natural.Zip(floors, (n, f) => n - f).ToList();
            var slackTotal = slack.Sum();
            out_ = [.. floors.Zip(slack, (f, s) => f + s * (available - floor) / slackTotal)];
        }
        out_ = [.. out_.Select(Math.Floor)];
        out_[^1] += Math.Floor(Math.Max(0, available - out_.Sum()));
        return out_;
    }
}

/// A table as text for a spreadsheet (docs/spec/3x-transcript.md §3.4): tabs and line breaks inside cells become spaces;
/// rows stay tab-separated.
public static class TableText
{
    private static readonly TranscriptRx Breaks = new(@"[\t\r\n]+");

    public static string Cell(string text) => TxText.TrimSpaces(Breaks.Replace(text, " "));

    public static string Text(IEnumerable<IEnumerable<string>> rows) =>
        string.Join("\n", rows.Select(r => string.Join("\t", r.Select(Cell))));

    /// [WIN-36] The footer under a table in a reply (App/Chat/Cells/ChatTextViews.swift `TableFooterControl`): the
    /// counts on the left, “Expand” on the right; the button's name and id as the Mac's.
    public const string ExpandWord = "Expand";
    public const string ExpandName = "Expand table";
    public const string ExpandId = "chat.table.expand";

    /// “3 rows · 7 columns”: the table's body rows (the header row isn't counted) and columns.
    public static string FooterCounts(int rows, int columns) =>
        $"{rows} {(rows == 1 ? "row" : "rows")} \u00b7 {columns} {(columns == 1 ? "column" : "columns")}";

    /// The Table sheet (App/Chat/Sheets/TableSheetController.swift): titled “Table” (a reply's table has no caption
    /// here), its copy button “Copy as Text”, its view's id `table.sheet`.
    public const string SheetTitle = "Table";
    public const string CopyTitle = "Copy as Text";
    public const string SheetId = "table.sheet";

    /// The copy failed wording: shown when the table has nothing to copy.
    public const string Failure = "Couldn’t copy. Select the table text and try again.";

    public static string? Copyable(IEnumerable<IEnumerable<string>> rows)
    {
        var out_ = Text(rows);
        return out_.Trim().Length == 0 ? null : out_;
    }
}
