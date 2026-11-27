using System.Globalization;

namespace Hermes.Core.Settings;

/// What Settings › About › Diagnostics shows and what Copy Diagnostics copies, as pure functions over plain values (a
/// port of the parts of HermesKit/Diagnostics/DiagnosticsReport.swift the Windows app has). The page and the copied
/// text are built from the same sections, so they can never disagree; every copied line is redacted.
public static class DiagnosticsReport
{
    /// A row: what the user reads, its value, and the raw metric name the copied report keeps for debugging.
    public sealed record Row(string Label, string Value, string? Raw = null);

    /// A titled run of rows under a section (the Gateway's reconnects).
    public sealed record RowList(string Title, IReadOnlyList<Row> Rows, string Empty);

    public sealed record Section(string Title, IReadOnlyList<Row> Rows, RowList? List = null);

    /// One error message and how often it happened; `At` is its latest time.
    public sealed record ErrorGroup(string Message, int Count, DateTimeOffset? At);

    public const string Intro = "Copy this and send it with a bug report. Passwords, tokens, cookies and web-address details are removed, but error text is included, so read it before you share it.";

    /// Recent errors, newest first, one bounded line each, repeats folded into one row. `entries` is oldest first.
    public static IReadOnlyList<ErrorGroup> RecentErrors(IEnumerable<(string Message, DateTimeOffset? At)> entries, int limit = 20)
    {
        var groups = new List<ErrorGroup>();
        var index = new Dictionary<string, int>();
        foreach (var entry in Enumerable.Reverse(entries.TakeLast(100).ToList()))
        {
            var message = OneLine(DiagnosticRedactor.Redact(entry.Message), 300);
            if (message.Length == 0) continue;
            if (index.TryGetValue(message, out var at)) groups[at] = groups[at] with { Count = groups[at].Count + 1 };
            else
            {
                index[message] = groups.Count;
                groups.Add(new ErrorGroup(message, 1, entry.At));
            }
        }
        return groups.Take(limit).ToList();
    }

    /// Runs of white space become one space, the ends are trimmed, and the line is cut to `limit` UTF-16 units.
    public static string OneLine(string text, int limit)
    {
        var joined = string.Join(' ', text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        return joined.Length > limit ? joined[..limit] : joined;
    }

    /// "×5 · last 4:03 AM": how often, and when last, if either is worth saying.
    public static string ErrorMeta(ErrorGroup group, Func<DateTimeOffset, string>? time = null)
    {
        time ??= Clock;
        return string.Join(" · ", new[] { group.Count > 1 ? $"×{group.Count}" : "", group.At is { } at ? $"last {time(at)}" : "" }
            .Where(s => s.Length > 0));
    }

    public static string Clock(DateTimeOffset date) => date.ToLocalTime().ToString("t", CultureInfo.CurrentCulture);

    public static string Iso(DateTimeOffset date) => date.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);

    private static readonly HashSet<string> SmallWords =
        ["a", "an", "and", "as", "at", "by", "for", "from", "in", "of", "on", "or", "per", "the", "to", "vs", "with"];

    /// A row's label in Title Case, as every Settings row on the Mac reads ("Open connections" → "Open Connections").
    /// Short joining words stay lower case unless they lead; a word that already has a capital after its first letter
    /// or a digit is left as it is; each part of a hyphenated word is capitalised. The copied report keeps its own words.
    public static string TitleCase(string label)
    {
        var first = true;
        return string.Join(' ', label.Split(' ').Select(word =>
        {
            var wasFirst = first;
            if (word.Length > 0) first = false;
            if (word.Skip(1).Any(char.IsUpper) || word.Any(char.IsDigit)) return word;
            var bare = word.Trim(',', '.', ';', ':', '!', '?', '(', ')', '"', '\'').ToLowerInvariant();
            if (!wasFirst && SmallWords.Contains(bare)) return word;
            return string.Join('-', word.Split('-').Select(p => p.Length == 0 ? p : char.ToUpperInvariant(p[0]) + p[1..]));
        }));
    }

    /// The copied report: a header, each section, then the errors; every line redacted.
    public static string Text(IReadOnlyList<Section> sections, IReadOnlyList<ErrorGroup> errors, DateTimeOffset? now = null)
    {
        var lines = new List<string> { "Hermes HQ diagnostics", Iso(now ?? DateTimeOffset.UtcNow), "" };
        foreach (var section in sections)
        {
            lines.Add(section.Title);
            foreach (var row in section.Rows)
                lines.Add($"  {row.Label}{(row.Raw != null && row.Raw != row.Label ? $" [{row.Raw}]" : "")}: {row.Value}");
            if (section.List is { } list)
            {
                lines.Add($"  {list.Title}:");
                if (list.Rows.Count == 0) lines.Add($"    {list.Empty}");
                else lines.AddRange(list.Rows.Select(r => $"    {r.Raw ?? r.Label}: {r.Value}"));
            }
            lines.Add("");
        }
        lines.Add($"Recent errors ({errors.Sum(e => e.Count)})");
        if (errors.Count == 0) lines.Add("  None since launch");
        else lines.AddRange(errors.Select(g =>
        {
            var meta = ErrorMeta(g, Iso);
            return $"  {g.Message}{(meta.Length == 0 ? "" : $" ({meta})")}";
        }));
        return string.Join("\n", lines.Select(DiagnosticRedactor.Redact));
    }
}
