using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace Hermes.Core.Insights;

/// A tile's name in plain words, and what its page's head says (HermesKit/Pages/TileNames.swift).
public static partial class TileNames
{
    /// The longest name kept from a page's title.
    public const int Longest = 40;
    /// The shortest refresh a page may ask for.
    public const int ShortestRefresh = 30;

    private static readonly HashSet<string> Small = ["a", "an", "and", "as", "at", "by", "for", "in", "of", "on", "or", "the", "to", "vs", "with"];

    private static string PathExtension(string name)
    {
        var dot = name.LastIndexOf('.');
        return dot <= 0 || dot == name.Length - 1 ? "" : name[(dot + 1)..];
    }

    /// A file name as words: no extension, dashes, underscores and dots as spaces, camelCase split, each word
    /// capitalised (a word with capitals or digits of its own kept as it is).
    public static string Pretty(string fileName)
    {
        var b = fileName;
        var slash = b.LastIndexOfAny(['/', '\\']);
        if (slash >= 0) b = b[(slash + 1)..];
        var ext = PathExtension(b);
        if (ext.Length > 0 && ext.Length <= 5) b = b[..(b.Length - ext.Length - 1)];
        var spaced = new StringBuilder();
        char? previous = null;
        foreach (var ch in b)
        {
            if (ch is '-' or '_' or '.' or '+') spaced.Append(' ');
            else
            {
                if (previous is { } p && char.IsLower(p) && char.IsUpper(ch)) spaced.Append(' ');
                spaced.Append(ch);
            }
            previous = ch;
        }
        var words = spaced.ToString().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        if (words.Length == 0) return fileName;
        return string.Join(' ', words.Select((w, i) =>
        {
            if (w.Any(c => char.IsUpper(c) || char.IsDigit(c))) return w;
            if (i > 0 && Small.Contains(w)) return w;
            return char.ToUpperInvariant(w[0]) + w[1..];
        }));
    }

    /// A file name in words with its extension kept ("index.md" → "Index.md").
    public static string Pretty(string fileName, bool keepsExtension)
    {
        var words = Pretty(fileName);
        var file = fileName.Split('/', '\\').LastOrDefault(s => s.Length > 0) ?? fileName;
        var ext = PathExtension(file);
        if (!keepsExtension || ext.Length == 0 || ext.Length > 5 || words == fileName) return words;
        return words + "." + ext.ToLowerInvariant();
    }

    /// The tiles named only by their files whose name another tile's reads as too: those keep their extensions.
    public static HashSet<string> Clashing(IEnumerable<(string Id, string Name, bool ByFile)> names)
    {
        var list = names.ToList();
        var count = new Dictionary<string, int>();
        foreach (var e in list) count[e.Name.ToLowerInvariant()] = count.GetValueOrDefault(e.Name.ToLowerInvariant()) + 1;
        return [.. list.Where(e => e.ByFile && count.GetValueOrDefault(e.Name.ToLowerInvariant()) > 1).Select(e => e.Id)];
    }

    /// A page's `<title>` as a name: one line, no file extension, at most 40 characters; null when it has no words.
    public static string? CleanTitle(string? title)
    {
        if (title == null) return null;
        var text = string.Join(' ', title.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        foreach (var ext in new[] { ".html", ".htm" })
        {
            if (!text.EndsWith(ext, StringComparison.OrdinalIgnoreCase)) continue;
            text = text[..^ext.Length].Trim();
            if (!text.Contains(' ')) text = Pretty(text);
        }
        if (!text.Any(char.IsLetterOrDigit)) return null;
        var info = new StringInfo(text);
        if (info.LengthInTextElements > Longest)
        {
            var cut = info.SubstringByTextElements(0, Longest);
            var space = cut.LastIndexOf(' ');
            var atWord = space >= 0 ? cut[..space] : cut;
            text = atWord.Trim(' ', '-', '–', '—', ':', '·', '|', ',') + "…";
        }
        return text;
    }

    /// What a page's head says about it.
    public sealed record Head
    {
        public string? Title { get; init; }
        public string? JobId { get; init; }
        /// The page has buttons for its bot, asks to be read again on its own, or says so: its tile runs live.
        public bool Live { get; init; }
        /// `<meta name="hq-tile-refresh" content="300">`: read the file again this often while it shows.
        public int? RefreshSeconds { get; init; }
    }

    public static Head ReadHead(string html)
    {
        var text = html.Length > 64_000 ? html[..64_000] : html;
        string? title = null, job = null;
        int? refresh = null;
        if (TitleRx().Match(text) is { Success: true } t) title = CleanTitle(Entities(t.Groups[1].Value));
        if (JobMetaRx().Match(text) is { Success: true } jm && ContentRx().Match(jm.Value) is { Success: true } c)
        {
            var id = c.Groups[1].Value.Trim();
            job = id.Length == 0 ? null : id;
        }
        if (RefreshMetaRx().Match(text) is { Success: true } rm && RefreshContentRx().Match(rm.Value) is { Success: true } rc
            && int.TryParse(rc.Groups[1].Value, out var seconds) && seconds > 0)
            refresh = Math.Max(ShortestRefresh, seconds);
        var liveMeta = LiveMetaRx().IsMatch(text);
        return new Head
        {
            Title = title, JobId = job, RefreshSeconds = refresh,
            Live = liveMeta || refresh != null || text.Contains("data-hermes-send") || text.Contains("hermes.send("),
        };
    }

    private static string Entities(string text)
    {
        foreach (var (from, to) in new[] { ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
                     ("&nbsp;", " "), ("&middot;", "·"), ("&mdash;", "—"), ("&ndash;", "–") })
            text = text.Replace(from, to);
        return text;
    }

    [GeneratedRegex(@"<title[^>]*>([\s\S]*?)</title>", RegexOptions.IgnoreCase)]
    private static partial Regex TitleRx();
    [GeneratedRegex(@"<meta[^>]*hq-tile-job[^>]*>", RegexOptions.IgnoreCase)]
    private static partial Regex JobMetaRx();
    [GeneratedRegex(@"content\s*=\s*[""']([^""']+)[""']")]
    private static partial Regex ContentRx();
    [GeneratedRegex(@"<meta[^>]*hq-tile-refresh[^>]*>", RegexOptions.IgnoreCase)]
    private static partial Regex RefreshMetaRx();
    [GeneratedRegex(@"content\s*=\s*[""']\s*(\d+)")]
    private static partial Regex RefreshContentRx();
    [GeneratedRegex(@"<meta[^>]*name\s*=\s*[""']hq-tile[""'][^>]*content\s*=\s*[""']live[""']", RegexOptions.IgnoreCase)]
    private static partial Regex LiveMetaRx();
}
