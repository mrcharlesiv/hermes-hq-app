using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using Hermes.Core.Artifacts;
using Xunit;

namespace Hermes.Core.Tests;

/// [WIN-FILE-DELIMITED] A .csv or .tsv opens in the app's own table, read as App/Mac/SpreadsheetFile.swift reads it
/// (93f984bb1). Synthetic data only; files go to a fresh folder under the test's temp dir and are removed.
public class DelimitedFileTests
{
    private static DelimitedSheet Sheet(string text, bool tab = false) =>
        DelimitedFile.Parse(Encoding.UTF8.GetBytes(text), tab, "t") ?? throw new InvalidOperationException("no sheet");

    private static string[][] Rows(DelimitedSheet sheet) => [.. sheet.Rows.Select(r => r.ToArray())];

    // MARK: Separator

    [Theory]
    [InlineData("a,b,c\n1,2,3", ',')]
    [InlineData("a;b;c\n1;2;3", ';')]
    [InlineData("a\tb\tc\n1\t2\t3", '\t')]
    [InlineData("a;b,\"c;d;e\"\n", ';')]        // counted on the raw first line, quotes and all
    [InlineData("a,b;c\n", ',')]                // a tie: comma first
    [InlineData("a;b\tc\n", ';')]               // a tie: semicolon before tab
    [InlineData("just words\n1;2;3", ',')]      // none on the first line: a comma
    [InlineData("\n\r\n\na;b\n", ';')]          // the first line with something on it
    public void TheSeparatorIsTheFirstLinesMostCommonMark(string text, char expected) =>
        Assert.Equal(expected, DelimitedFile.Separator(text));

    [Fact]
    public void ATsvIsAlwaysTabSeparated()
    {
        var sheet = Sheet("a,b\tc,d\n1,2\t3,4\n", tab: true);
        Assert.Equal(new[] { new[] { "a,b", "c,d" }, new[] { "1,2", "3,4" } }, Rows(sheet));
    }

    // MARK: Quotes and line breaks

    [Fact]
    public void QuotedFieldsHoldSeparatorsQuotesAndLineBreaks()
    {
        var sheet = Sheet("name,note\r\n\"Smith, J\",\"said \"\"hi\"\"\"\r\nx,\"two\r\nlines\"\r\ny,\"lf\nonly\"\r\n");
        Assert.Equal(new[]
        {
            new[] { "name", "note" },
            new[] { "Smith, J", "said \"hi\"" },
            new[] { "x", "two\nlines" },   // CR LF inside a cell reads as one line break
            new[] { "y", "lf\nonly" },
        }, Rows(sheet));
        Assert.Equal(3, sheet.TotalRows);
    }

    [Fact]
    public void QuotesFollowTheMacsReader()
    {
        // Text after a closing quote joins the field; a quote inside an unquoted field is a quote; an unclosed quote
        // keeps the rest; a quote only opens at a field's start.
        var sheet = Sheet("h1,h2,h3\n\"ab\"cd,e\"f,\"open\nstill");
        Assert.Equal(new[] { new[] { "h1", "h2", "h3" }, new[] { "abcd", "e\"f", "open\nstill" } }, Rows(sheet));
    }

    [Fact]
    public void EveryKindOfLineBreakEndsARow()
    {
        var sheet = Sheet("a\rb\u2028c\u0085d\ne\r\nf");
        Assert.Equal(new[] { "a", "b", "c", "d", "e", "f" }, sheet.Rows.Select(r => r[0]));
    }

    // MARK: Decoding

    [Fact]
    public void ByteOrderMarksDecide()
    {
        var text = "Café,Prix\nthé,3\n";
        var utf8Bom = new byte[] { 0xEF, 0xBB, 0xBF }.Concat(Encoding.UTF8.GetBytes(text)).ToArray();
        var le = new byte[] { 0xFF, 0xFE }.Concat(Encoding.Unicode.GetBytes(text)).ToArray();
        var be = new byte[] { 0xFE, 0xFF }.Concat(Encoding.BigEndianUnicode.GetBytes(text)).ToArray();
        foreach (var data in new[] { utf8Bom, le, be, Encoding.UTF8.GetBytes(text) })
        {
            var sheet = DelimitedFile.Parse(data, false, "t")!;
            Assert.Equal(new[] { "Café", "Prix" }, sheet.Rows[0]);   // no mark left in the first header
            Assert.Equal(new[] { "thé", "3" }, sheet.Rows[1]);
        }
    }

    [Fact]
    public void AFileThatIsntWhatItsMarkSaysIsNotRead()
    {
        Assert.Null(DelimitedFile.Parse([0xEF, 0xBB, 0xBF, (byte)'a', 0xFF, (byte)'\n'], false, "t"));
        Assert.Null(DelimitedFile.Parse([0xFF, 0xFE, (byte)'a', 0x00, 0x00, 0xD8], false, "t"));   // a lone surrogate
    }

    [Fact]
    public void UnmarkedNonUtf8IsWindows1252ThenLatin1()
    {
        // 0x80 is the euro sign in Windows-1252; 0xE9 é.
        var cp = DelimitedFile.Decode([(byte)'a', (byte)',', 0x80, 0xE9]);
        Assert.Equal("a,€é", cp);
        // 0x81 is unassigned in Windows-1252: the whole file reads as Latin-1.
        var latin = DelimitedFile.Decode([0x80, 0x81, 0xE9]);
        Assert.Equal("\u0080\u0081é", latin);
    }

    // MARK: Shape

    [Fact]
    public void EmptyRowsAndTheEmptyColumnsAtTheRightAreDropped()
    {
        var sheet = Sheet("\n , \t\nName,Age,,\n\nAda,36,,\nBob\n,,,\n");
        Assert.Equal(new[] { new[] { "Name", "Age" }, new[] { "Ada", "36" }, new[] { "Bob", "" } }, Rows(sheet));
        Assert.Equal(2, sheet.TotalRows);
        Assert.False(sheet.IsCut);
    }

    [Fact]
    public void ALineBreakAloneIsSomethingButSpacesAreNot()
    {
        var sheet = Sheet("h\n\"\n\"\n\"\u00a0 \"\n");
        Assert.Equal(new[] { "h", "\n" }, sheet.Rows.Select(r => r[0]));
    }

    [Fact]
    public void NothingButBlanksIsNoSheet()
    {
        Assert.Null(DelimitedFile.Parse(Encoding.UTF8.GetBytes(" , \n\t\n\n"), false, "t"));
        Assert.Null(DelimitedFile.Parse([], false, "t"));
    }

    [Fact]
    public void ALongFileShowsItsFirstRowsAndCountsThemAll()
    {
        var text = new StringBuilder("a,b,c\n");
        for (var i = 0; i < 1_000; i++) text.Append(i).Append(",x,y\n");
        var sheet = Sheet(text.ToString());
        Assert.Equal(401, sheet.Rows.Count);
        Assert.Equal(400, sheet.ShownRows);
        Assert.Equal(1_000, sheet.TotalRows);
        Assert.True(sheet.IsCut);
        Assert.Equal("399", sheet.Rows[^1][0]);
    }

    [Theory]
    [InlineData(20, 20, 300)]   // 6,000 cells / 20 columns
    [InlineData(40, 40, 150)]
    [InlineData(90, 40, 150)]   // wider than 40: the first 40 columns
    [InlineData(10, 10, 400)]
    public void WideFilesShowFewerRows(int columns, int width, int body)
    {
        var text = new StringBuilder();
        for (var r = 0; r < 1_001; r++) text.AppendLine(string.Join(",", Enumerable.Range(0, columns).Select(c => $"r{r}c{c}")));
        var sheet = Sheet(text.ToString());
        Assert.Equal(width, sheet.Columns);
        Assert.Equal(body, sheet.ShownRows);
        Assert.Equal(1_000, sheet.TotalRows);
        Assert.All(sheet.Rows, r => Assert.Equal(width, r.Count));
        Assert.True(sheet.Rows.Count * sheet.Columns <= DelimitedFile.MaxCells + DelimitedFile.MaxColumns);
    }

    [Fact]
    public void ARowFilledOnlyPastTheLastColumnShownIsStillARow()
    {
        var far = string.Join(",", Enumerable.Repeat("", 60)) + ",far";
        var sheet = Sheet($"a,b\n{far}\n1,2\n");
        Assert.Equal(40, sheet.Columns);   // width counts the far cell, then is held to 40
        Assert.Equal(3, sheet.Rows.Count);
        Assert.All(sheet.Rows[1], cell => Assert.Equal("", cell));
    }

    [Fact]
    public void AHugeRowOfSeparatorsKeepsOnlyTheColumnsShown()
    {
        var text = "h\n" + new string(',', 500_000) + "x\n";
        var sheet = Sheet(text);
        Assert.Equal(DelimitedFile.MaxColumns, sheet.Columns);
        Assert.Equal(2, sheet.Rows.Count);
    }

    [Fact]
    public void FormulaLookingCellsAreWordsAsWritten()
    {
        var cells = new[] { "=SUM(A1:A2)", "+1+2", "-3-4", "@cmd", "=HYPERLINK(\"http://example.com\",\"x\")" };
        var text = "a,b,c,d,e\n" + string.Join(",", cells.Select(c => "\"" + c.Replace("\"", "\"\"") + "\"")) + "\n";
        var sheet = Sheet(text);
        Assert.Equal(cells, sheet.Rows[1]);
        var table = new DelimitedTable(sheet, "f.csv");
        Assert.Equal(cells, table.ShownRows()[1]);
        Assert.Contains("=SUM(A1:A2)\t+1+2\t-3-4\t@cmd", table.CopyText());
        Assert.Contains("=SUM(A1:A2)", table.CopyCsv());
    }

    // MARK: Files

    private sealed class Folder : IDisposable
    {
        public string Path { get; } = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "delimited-tests-" + Guid.NewGuid().ToString("N"));
        public Folder() => Directory.CreateDirectory(Path);
        public string Write(string name, byte[] data)
        {
            var file = System.IO.Path.Combine(Path, name);
            File.WriteAllBytes(file, data);
            return file;
        }
        public void Dispose() { try { Directory.Delete(Path, true); } catch (IOException) { } }
    }

    [Fact]
    public void FilesAreReadWithinTheLimits()
    {
        using var folder = new Folder();
        var ok = folder.Write("budget.csv", Encoding.UTF8.GetBytes("Month;Rent\nJan;1200\n"));
        var sheet = DelimitedFile.Read(ok)!;
        Assert.Equal("budget", sheet.Name);
        Assert.Equal(new[] { "Month", "Rent" }, sheet.Rows[0]);

        Assert.Null(DelimitedFile.Read(folder.Write("empty.csv", [])));
        Assert.Null(DelimitedFile.Read(Path.Combine(folder.Path, "missing.csv")));
        Assert.Null(DelimitedFile.Read(folder.Write("notes.txt", Encoding.UTF8.GetBytes("a,b\n1,2\n"))));
        Assert.Null(DelimitedFile.Read(folder.Write("book.xlsx", Encoding.UTF8.GetBytes("a,b\n1,2\n"))));

        var big = new byte[DelimitedFile.MaxBytes + 1];
        Array.Fill(big, (byte)'a');
        big[1] = (byte)',';
        big[3] = (byte)'\n';
        Assert.Null(DelimitedFile.Read(folder.Write("big.csv", big)));
        var limit = folder.Write("limit.tsv", big[..DelimitedFile.MaxBytes]);
        var atLimit = DelimitedFile.Read(limit)!;
        Assert.Equal(new[] { "a,a" }, atLimit.Rows[0]);   // a .tsv splits on tabs only
    }

    [Fact]
    public void TheAttachmentsNameDecidesOverItsCachedPath()
    {
        using var folder = new Folder();
        var cached = folder.Write("a1b2c3", Encoding.UTF8.GetBytes("x\ty\n1\t2\n"));
        var sheet = DelimitedFile.Read(cached, "Report.TSV")!;
        Assert.Equal("Report", sheet.Name);
        Assert.Equal(new[] { "x", "y" }, sheet.Rows[0]);
        Assert.Null(DelimitedFile.Read(cached));   // the path alone has no extension
    }

    // MARK: The table page

    private static DelimitedTable Table(int body = 3)
    {
        var text = new StringBuilder("Name,Amount\n");
        var names = new[] { "Émile", "bob", "Ada", "Zoë", "Carl", "dan", "Eve", "Fay", "Gus" };
        var amounts = new[] { "10", "2", "", "7", "1,000", "3", "5", "8", "4" };
        for (var i = 0; i < body; i++) text.Append(names[i]).Append(",\"").Append(amounts[i]).Append("\"\n");
        return new DelimitedTable(Sheet(text.ToString()), "money.csv");
    }

    [Fact]
    public void AHeaderClickSortsUpThenDownThenBack()
    {
        var table = Table();
        Assert.Equal(new[] { 0, 1, 2 }, table.Order);
        Assert.Equal("Sorted by Amount, ascending", table.CycleSort(1));
        Assert.Equal(new[] { 1, 0, 2 }, table.Order);   // 2, 10, then the empty cell last
        Assert.Equal("\u2191", table.SortMark(1));
        Assert.Equal("Sorted by Amount, descending", table.CycleSort(1));
        Assert.Equal(new[] { 0, 1, 2 }, table.Order);
        Assert.Equal("Original order", table.CycleSort(1));
        Assert.Null(table.Sort);
        Assert.Equal("", table.SortMark(1));
        Assert.Equal(new[] { true }, new[] { table.Numeric[1] });
    }

    [Fact]
    public void SearchKeepsMatchingRowsCaseAndAccentsAside()
    {
        var table = Table(9);
        Assert.True(table.ShowsSearch);
        Assert.Equal("Search 9 Rows", table.SearchPlaceholder);
        table.Search("  emile ");
        Assert.Equal(new[] { 0 }, table.Order);
        Assert.Equal("1 of 9 rows \u00b7 2 columns", table.Subtitle(CultureInfo.InvariantCulture));
        table.Search("");
        Assert.Equal(9, table.Order.Count);
        Assert.False(Table(7).ShowsSearch);
    }

    [Fact]
    public void TheSubtitleCountsRowsAndSaysWhenTheFileIsLonger()
    {
        Assert.Equal("3 rows \u00b7 2 columns", Table().Subtitle());
        Assert.Equal("1 row \u00b7 2 columns", Table(1).Subtitle());
        var text = new StringBuilder("only\n");
        for (var i = 0; i < 1_234; i++) text.Append(i).Append('\n');
        var long_ = new DelimitedTable(Sheet(text.ToString()), "long.csv");
        Assert.Equal(1_234, long_.FileRows);
        Assert.Equal("first 400 of 1,234 rows \u00b7 1 column", long_.Subtitle(CultureInfo.InvariantCulture));
        Assert.Null(Table().FileRows);
    }

    [Fact]
    public void CopiesAreTheRowsAsShown()
    {
        var table = Table();
        table.CycleSort(1);
        Assert.Equal("Name\tAmount\nbob\t2\nÉmile\t10\nAda\t", table.CopyText());
        Assert.Equal("Name,Amount\nbob,2\nÉmile,10\nAda,", table.CopyCsv());
        Assert.StartsWith("| Name | Amount |\n| --- | ---: |", table.CopyMarkdown());
    }

    // MARK: Routing (every file-window entry point)

    [Theory]
    [InlineData("budget.csv", 10, FileWindowShows.Table)]
    [InlineData("DATA.TSV", 10, FileWindowShows.Table)]
    [InlineData("limit.csv", DelimitedFile.MaxBytes, FileWindowShows.Table)]
    [InlineData("big.csv", DelimitedFile.MaxBytes + 1, FileWindowShows.OwnApp)]
    [InlineData("empty.csv", 0, FileWindowShows.OwnApp)]
    [InlineData("budget.xlsx", 10, FileWindowShows.OwnApp)]
    public void ADelimitedFileRoutesToTheTable(string name, long bytes, FileWindowShows expected) =>
        Assert.Equal(expected, FileWindowRoute.For(name, bytes));

    private static string Source(params string[] parts)
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir) ?? throw new InvalidOperationException("no windows dir");
        return File.ReadAllText(Path.Combine([dir, "src", "HermesHQ.Windows", .. parts]));
    }

    /// Source proof only (the WinUI windows can't run here): a chat's, a tile's, a task's or the files list's file
    /// (MediaActions.OpenAsync → FileWindows.Open → ArtifactFileWindow.OpenRouted) takes the table when it reads and
    /// its own app when it doesn't; the Artifacts page's two Show routes take it through the file window's body.
    [Fact]
    public void EveryFileWindowEntryPointReachesTheTable()
    {
        var windows = Source("Features", "Artifacts", "ArtifactWindows.cs");
        var table = Regex.Match(windows, @"case FileWindowShows\.Table:(?<b>.*?)return true;", RegexOptions.Singleline);
        Assert.True(table.Success, "OpenRouted has no Table case");
        Assert.Contains("DelimitedFile.Read(path, name) is not { } sheet", table.Groups["b"].Value);
        Assert.Contains("return false;", table.Groups["b"].Value);   // unread: its own app, as before
        Assert.Contains("ShowTable(path, name, sheet)", table.Groups["b"].Value);
        var body = Regex.Match(windows, @"private static UIElement FileBody\((?<b>.*?)\n    \};", RegexOptions.Singleline).Groups["b"].Value;
        Assert.Matches(@"_ when DelimitedFile\.Read\(path, name\) is \{ \} sheet => new DelimitedTableView\(sheet, name\),\s*\n\s*_ => Look\.State\(", body);
        Assert.Contains("FileWindowWords.OpenIn(DefaultApp(path))", body);   // the normal fallback stays

        Assert.Contains("FileWindows.Open = ArtifactFileWindow.OpenRouted;", Source("Features", "Artifacts", "ArtifactsFeature.cs"));
        Assert.Contains("FileWindows.Open?.Invoke(path, name, null) == true", Source("Features", "Attachments", "MediaActions.cs"));
        var page = Source("Features", "Artifacts", "ArtifactsPage.cs");
        Assert.Contains("ArtifactFileWindow.Show(file, record.Label, opening.Kind == ArtifactOpeningKind.Text ? ArtifactOpeningKind.Other : opening.Kind);", page);
        Assert.Contains("ArtifactFileWindow.Show(file, record.Label, opening.Kind);", page);
        Assert.Equal(ArtifactOpeningKind.Other, ArtifactFiles.Opening(new ArtifactRecord { Id = "otto\u001Fs1:budget.csv", Kind = ArtifactKind.File, Value = "/Users/me/out/budget.csv", Href = "", Label = "budget.csv", SessionId = "s1", SessionTitle = "Budget", Timestamp = 0 }).Kind);
    }

    [Fact]
    public void TheTablePageShowsWordsNotFormulas()
    {
        var view = Source("Features", "Artifacts", "DelimitedTableView.cs");
        Assert.Contains("DelimitedTable.PageId", view);
        Assert.Contains("DelimitedTable.SearchId", view);
        Assert.DoesNotContain("RichTextBlock", view);   // cells are TextBlock.Text: nothing is parsed or worked out
        Assert.DoesNotContain("Hyperlink", view);
    }
}
