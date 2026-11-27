using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;

namespace Hermes.Core.Transcripts;

// Port of HermesKit/Chat/Transcript/LinkTargets.swift: where a clicked link goes (docs/spec/3x-transcript.md §7.1), file
// paths a bot names that open in the chat's Files, a CLI flag in inline code kept whole (§8.2), and what a screen
// reader says for a reply (§9.1).

public enum LinkTargetKind
{
    /// http(s) to somewhere this device can reach: opened in the app's browser view.
    Page,
    /// mailto:, tel:, sms:, facetime: — the system's own app.
    System,
    /// A `file://` link: a file on the gateway computer, by its path; opened in the app's own viewer.
    File,
    /// A page on the gateway computer itself (localhost, 127.0.0.0/8, ::1, 0.0.0.0).
    Loopback,
    Refused,
}

public sealed record LinkTarget(LinkTargetKind Kind, Uri? Url = null, string? Path = null)
{
    public static readonly LinkTarget Loopback = new(LinkTargetKind.Loopback);
    public static readonly LinkTarget Refused = new(LinkTargetKind.Refused);
}

public static class LinkTargets
{
    /// `device`: the device's name ("iPhone", "iPad"; the Mac and Windows app say "Mac" / "PC" there).
    public static string LoopbackNotice(string device) => $"This page runs on {TranscriptWords.HostPhrase}, so it can’t open on your {device}.";
    public const string RefusedNotice = "This link can’t be opened here.";

    public static bool IsLoopback(string host)
    {
        var h = host.ToLowerInvariant();
        if (h.StartsWith('[') && h.EndsWith(']')) h = h[1..^1];
        if (h.EndsWith('.')) h = h[..^1];
        if (h.IndexOf('%') is var zone and >= 0) h = h[..zone];   // an IPv6 zone ("::1%lo0")
        if (h == "localhost" || h.EndsWith(".localhost", StringComparison.Ordinal)) return true;
        // Every spelling of the gateway computer's own address: 127.0.0.0/8 and 0.0.0.0 however written ("127.1",
        // "2130706433", "0177.0.0.1", "0x7f.0.0.1"), ::1, ::, and an IPv4 address inside an IPv6 one.
        static bool Loopback4(ReadOnlySpan<byte> b) => b[0] == 127 || !b.ContainsAnyExcept((byte)0);
        if (!h.Contains(':'))
            return InetAton(h) is { } v4 && Loopback4([(byte)(v4 >> 24), (byte)(v4 >> 16), (byte)(v4 >> 8), (byte)v4]);
        if (!IPAddress.TryParse(h, out var v6) || v6.AddressFamily != AddressFamily.InterNetworkV6) return false;
        var bytes = v6.GetAddressBytes();
        if (!bytes.AsSpan(0, 15).ContainsAnyExcept((byte)0)) return bytes[15] <= 1;                       // :: and ::1
        var mapped = !bytes.AsSpan(0, 10).ContainsAnyExcept((byte)0) && bytes[10] == 0xff && bytes[11] == 0xff;   // ::ffff:a.b.c.d
        var compatible = !bytes.AsSpan(0, 12).ContainsAnyExcept((byte)0);                                  // ::a.b.c.d
        return (mapped || compatible) && Loopback4(bytes.AsSpan(12));
    }

    /// BSD `inet_aton`: one to four parts, each decimal, octal (leading 0) or hex (0x); the last fills the rest.
    internal static uint? InetAton(string text)
    {
        var parts = text.Split('.');
        if (parts.Length is < 1 or > 4) return null;
        var values = new ulong[parts.Length];
        for (var i = 0; i < parts.Length; i++)
        {
            var p = parts[i];
            if (p.Length == 0) return null;
            ulong v;
            if (p.Length > 1 && (p.StartsWith("0x", StringComparison.OrdinalIgnoreCase)))
            {
                if (p.Length == 2) v = 0;
                else if (!ulong.TryParse(p[2..], NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out v)) return null;
            }
            else if (p.Length > 1 && p[0] == '0')
            {
                v = 0;
                foreach (var c in p[1..]) { if (c is < '0' or > '7') return null; v = v * 8 + (ulong)(c - '0'); if (v > uint.MaxValue) return null; }
            }
            else if (!p.All(char.IsAsciiDigit) || !ulong.TryParse(p, NumberStyles.None, CultureInfo.InvariantCulture, out v)) return null;
            values[i] = v;
        }
        ulong result = 0;
        for (var i = 0; i < values.Length - 1; i++)
        {
            if (values[i] > 255) return null;
            result |= values[i] << (24 - 8 * i);
        }
        var lastBits = 8 * (4 - (values.Length - 1));
        var last = values[^1];
        if (lastBits < 64 && last >= 1UL << lastBits) return null;
        return (uint)(result | last);
    }

    public static LinkTarget Target(Uri url)
    {
        if (!url.IsAbsoluteUri) return LinkTarget.Refused;
        switch (url.Scheme.ToLowerInvariant())
        {
            case "http" or "https":
                var host = url.Host;
                if (host.Length == 0) return LinkTarget.Refused;
                return IsLoopback(host) ? LinkTarget.Loopback : new LinkTarget(LinkTargetKind.Page, url);
            case "mailto" or "tel" or "sms" or "facetime" or "facetime-audio":
                return new LinkTarget(LinkTargetKind.System, url);
            case "file":
                return FilePath(url) is { } path ? new LinkTarget(LinkTargetKind.File, Path: path) : LinkTarget.Refused;
            default:
                return LinkTarget.Refused;
        }
    }

    /// `Target` for a link's text; refused when it isn't an absolute address.
    public static LinkTarget Target(string url) =>
        Uri.TryCreate(url, UriKind.Absolute, out var u) ? Target(u) : LinkTarget.Refused;

    private static readonly Regex WindowsDrive = new(@"^[A-Za-z]:[\\/]", RegexOptions.CultureInvariant);

    /// The path a `file://` link names on the gateway computer ("file:///Users/me/report.html", "file://localhost/…",
    /// "file:///C:/Users/me/report.html" → "C:/Users/me/report.html"); null for another computer's file or no path.
    public static string? FilePath(Uri url)
    {
        if (!url.IsAbsoluteUri || !url.Scheme.Equals("file", StringComparison.OrdinalIgnoreCase)) return null;
        var host = url.Host.ToLowerInvariant();
        if (host.Length > 0 && host != "localhost") return null;
        var path = Uri.UnescapeDataString(url.AbsolutePath);
        if (path.Length >= 3 && path.StartsWith('/') && WindowsDrive.IsMatch(path[1..])) path = path[1..];
        return path.Length == 0 || path == "/" ? null : path;
    }
}

/// A bare path found in prose: the UTF-16 range it is drawn in (a line number stays inside) and the path it opens.
public readonly record struct BarePath(int Start, int Length, string Path);

/// A file path a bot names in inline code (or written out in the words) is a link that opens the file in the chat's
/// Files. Only a place on the gateway computer counts: absolute ("/…", "~/…", "C:\…"), and either a name with an
/// extension or a home or system folder at the root, so an API route ("/api/fs/list") or a command ("/new") stays code.
public static class FileLinks
{
    public const string Prefix = "#file:";

    private static readonly HashSet<string> Roots = ["Users", "home", "root", "tmp", "private", "var", "etc", "opt", "usr", "Volumes",
        "Applications", "Library", "mnt", "srv", "workspace"];
    private static readonly TranscriptRx LineNumber = new(@":\d+(?::\d+)?$");
    private static readonly TranscriptRx Drive = new(@"^[A-Za-z]:[\\/]");

    /// The path inline code names, or null when the code is something else.
    public static string? PathInCode(string code)
    {
        var path = TxText.TrimSpaces(code);
        if (path.Length < 4 || path.Length > 1024 || path.Any(TxText.IsNewline) || path.Any(c => "*?{}<>|$`\"';&".Contains(c))) return null;
        path = LineNumber.Replace(path, "");
        var windows = Drive.Test(path);
        var home = path.StartsWith("~/", StringComparison.Ordinal);
        if (!(windows || home || (path.StartsWith('/') && !path.StartsWith("//", StringComparison.Ordinal)))) return null;
        var parts = path.Split(windows ? ['/', '\\'] : ['/'], StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 0) return null;
        var named = HasExtension(parts[^1]);
        // Words after a space are a command's arguments ("/usr/bin/env python3"), unless the name ends the path.
        if (path.Any(char.IsWhiteSpace) && (!named || path.Contains(" -"))) return null;
        if (windows || home) return parts.Length >= 2 ? path : null;
        if (parts.Length < 2) return null;   // "/new", "/README.md"
        return named || Roots.Contains(parts[0]) ? path : null;
    }

    private static readonly TranscriptRx BareWord = new(@"(?<![\w/\\:.~@%+=-])(?:~/|/(?!/)|[A-Za-z]:\\)[^\s`]+");

    /// Each path written out in prose (not in backticks): it starts a word and runs to the next space, less the sentence
    /// punctuation, quote or unopened bracket after it; the rest is `PathInCode`'s rules.
    public static List<BarePath> Bare(string text)
    {
        if (!text.Contains('/') && !text.Contains('\\')) return [];
        var out_ = new List<BarePath>();
        foreach (Match m in BareWord.Re.Matches(text))
        {
            var drawn = m.Value;
            while (drawn.Length > 0 && Trails(drawn[^1], drawn)) drawn = drawn[..^1];
            if (PathInCode(drawn) is { } path) out_.Add(new BarePath(m.Index, drawn.Length, path));
        }
        return out_;
    }

    /// The last character of a word is the sentence's, not the path's: "report.md." / "(see /a/b.md)" / "\"/a/b.md\"".
    private static bool Trails(char c, string word) => c switch
    {
        '.' or ',' or ';' or ':' or '!' or '?' or '…' or '"' or '\'' or '”' or '’' => true,
        ')' => word.Count(x => x == '(') < word.Count(x => x == ')'),
        ']' => word.Count(x => x == '[') < word.Count(x => x == ']'),
        _ => false,
    };

    /// "report.md", "data.tar.gz": a dot that isn't the first character, then 1–10 letters or digits with a letter.
    public static bool HasExtension(string name)
    {
        var dot = name.LastIndexOf('.');
        if (dot <= 0) return false;
        var ext = name[(dot + 1)..];
        return ext.Length is >= 1 and <= 10 && ext.All(char.IsAsciiLetterOrDigit) && ext.Any(char.IsAsciiLetter);
    }

    /// The link a path clicks through: "#file:" and the path with everything but letters and digits percent-encoded.
    public static string Url(string path)
    {
        var sb = new StringBuilder(Prefix);
        foreach (var b in Encoding.UTF8.GetBytes(path))
        {
            if (b < 0x80 && char.IsAsciiLetterOrDigit((char)b)) sb.Append((char)b);
            else sb.Append('%').Append(b.ToString("X2", CultureInfo.InvariantCulture));
        }
        return sb.ToString();
    }

    /// The path behind a clicked file link, if it is one.
    public static string? PathFromLink(string link)
    {
        if (!link.StartsWith(Prefix, StringComparison.Ordinal)) return null;
        var raw = link[Prefix.Length..];
        string path;
        try { path = Uri.UnescapeDataString(raw); } catch (UriFormatException) { path = raw; }
        return path.Length == 0 ? null : path;
    }

    /// The folder a path is in and the name it has there ("/a/b/c.md" → "/a/b", "c.md"); a path ending in a separator
    /// is the folder itself (no name).
    public static (string Folder, string? Name) Place(string path)
    {
        var windows = Drive.Test(path);
        bool Separator(char c) => c == '/' || (windows && c == '\\');
        if (path.Length > 0 && Separator(path[^1]))
        {
            var folder = path[..^1];
            return (folder.Length == 0 || (windows && folder.Length == 2) ? path : folder, null);
        }
        var cut = -1;
        for (var i = path.Length - 1; i >= 0; i--) if (Separator(path[i])) { cut = i; break; }
        if (cut < 0) return (path, null);
        var name = path[(cut + 1)..];
        var dir = path[..cut];
        if (dir.Length == 0 || (windows && dir.Length == 2)) dir += path[cut];   // "/" and "C:\"
        return (dir, name);
    }
}

/// A short CLI flag in inline code stays on one line (§8.2): a word joiner after each hyphen stops the line from
/// breaking inside "--user". Only the drawn text changes; what is copied, selected, read aloud and searched is the
/// message's own source, and Find's marks on the drawn text look past the joiners (`FindRanges`).
public static class InlineCodeText
{
    public const char Joiner = '\u2060';

    public static string Plain(string drawn) => drawn.Replace(Joiner.ToString(), "", StringComparison.Ordinal);

    /// Every occurrence of `query` (trimmed) in `text`, case- and accent-insensitive, never overlapping (ChatFind.ranges),
    /// as UTF-16 (start, length).
    public static List<(int Start, int Length)> Find(string query, string text)
    {
        var q = query.Trim();
        var out_ = new List<(int, int)>();
        if (q.Length == 0 || text.Length == 0) return out_;
        var compare = CultureInfo.InvariantCulture.CompareInfo;
        var from = 0;
        while (from < text.Length)
        {
            var at = compare.IndexOf(text.AsSpan(from), q.AsSpan(), CompareOptions.IgnoreCase | CompareOptions.IgnoreNonSpace, out var length);
            if (at < 0) break;
            out_.Add((from + at, length));
            from += at + Math.Max(length, 1);
        }
        return out_;
    }

    /// The UTF-16 ranges of `query` in drawn text, found as if the joiners were not there (each range covers the joiners
    /// inside the match, so the mark is drawn over the whole flag).
    public static List<(int Start, int Length)> FindRanges(string query, string drawn)
    {
        if (!drawn.Contains(Joiner)) return Find(query, drawn);
        var plain = new StringBuilder();
        var origin = new List<int>();   // plain offset → drawn offset
        for (var i = 0; i < drawn.Length; i++)
        {
            if (drawn[i] == Joiner) continue;
            plain.Append(drawn[i]);
            origin.Add(i);
        }
        var out_ = new List<(int, int)>();
        foreach (var (start, length) in Find(query, plain.ToString()))
        {
            if (length <= 0 || start < 0 || start + length > origin.Count) continue;
            var s = origin[start];
            var e = origin[start + length - 1] + 1;
            out_.Add((s, e - s));
        }
        return out_;
    }

    private static readonly TranscriptRx Flag = new(@"^--?[A-Za-z0-9][A-Za-z0-9_=.:/-]{0,38}$");

    public static bool IsFlag(string code) => Flag.Test(code);

    public static string Display(string code) => IsFlag(code) ? code.Replace("-", "-\u2060", StringComparison.Ordinal) : code;
}

/// What a screen reader reads for a reply (§9.1): the words, not the Markdown that styles them.
public static class SpokenMarkdown
{
    private const RegexOptions M = RegexOptions.Multiline;
    private static readonly TranscriptRx Fence = new(@"^[ \t]*(?:```|~~~)[^\n]*\n?", M);
    private static readonly TranscriptRx Image = new(@"!\[([^\]\n]*)\]\([^)\n]*\)");
    private static readonly TranscriptRx Link = new(@"\[([^\]\n]+)\]\([^)\n]*\)");
    private static readonly TranscriptRx Heading = new(@"^[ \t]{0,3}#{1,6}[ \t]+", M);
    private static readonly TranscriptRx Quote = new(@"^[ \t]{0,3}>[ \t]?", M);
    private static readonly TranscriptRx Bullet = new(@"^([ \t]*)[-*+][ \t]+(?:\[[ xX]\][ \t]+)?", M);
    private static readonly TranscriptRx Rule = new(@"^[ \t]*(?:-{3,}|\*{3,}|_{3,})[ \t]*$", M);
    private static readonly TranscriptRx Strong = new(@"(\*\*|__)(?=\S)([\s\S]*?\S)\1");
    private static readonly TranscriptRx Emphasis = new(@"(?<![\w*])([*_])(?=\S)([^*_\n]*?\S)\1(?![\w*])");
    private static readonly TranscriptRx Strike = new(@"~~(?=\S)([^~\n]*?\S)~~");
    private static readonly TranscriptRx Code = new(@"`+([^`\n]+)`+");
    private static readonly TranscriptRx TableRule = new(@"^[ \t]*\|?[ \t]*:?-{2,}:?[ \t]*(?:\|[ \t]*:?-{2,}:?[ \t]*)*\|?[ \t]*$\n?", M);
    private static readonly TranscriptRx Pipes = new(@"[ \t]*\|[ \t]*");

    public static string Plain(string markdown)
    {
        // Formulas read "Formula: " + their source; code blocks and tables read as their summaries (§1.1).
        markdown = SummarizingBlocks(MathText.Spoken(markdown));
        if (!markdown.Any(c => "*_`#[>~|-".Contains(c))) return markdown;
        var text = Fence.Replace(markdown, "");
        text = Image.Replace(text, "$1");
        text = Link.Replace(text, "$1");
        text = TableRule.Replace(text, "");
        text = Rule.Replace(text, "");
        text = Heading.Replace(text, "");
        text = Quote.Replace(text, "");
        text = Bullet.Replace(text, "$1");
        text = Strong.Replace(text, "$2");
        text = Emphasis.Replace(text, "$2");
        text = Strike.Replace(text, "$1");
        text = Code.Replace(text, "$1");
        if (text.Contains('|'))
        {
            text = string.Join("\n", text.Split('\n').Select(line =>
            {
                var t = TxText.TrimSpaces(line);
                if (!t.StartsWith('|') && !t.EndsWith('|')) return line;
                return Pipes.Replace(t.Trim('|', ' ', '\t'), ", ");
            }));
        }
        return text.Trim();
    }

    /// The characters of a code block read after its summary.
    public const int CodePreview = 300;

    /// Code blocks and tables as docs/spec/3x-transcript.md §1.1 reads them: a fence is "Code, Python, 12 lines: " and its
    /// first 300 characters (on one line), a table "Table, 3 rows, 2 columns. " and its header cells.
    public static string SummarizingBlocks(string markdown)
    {
        if (!markdown.Contains("```") && !markdown.Contains("~~~") && !markdown.Contains('|')) return markdown;
        var lines = markdown.Split('\n');
        var out_ = new List<string>();
        var i = 0;
        static string Plural(int n, string word) => $"{n} {word}{(n == 1 ? "" : "s")}";
        static string[] Cells(string line) =>
            [.. TxText.TrimSpaces(line).Trim('|').Split('|').Select(TxText.TrimSpaces)];
        while (i < lines.Length)
        {
            var line = lines[i];
            var trimmed = TxText.TrimSpaces(line);
            if (trimmed.StartsWith("```", StringComparison.Ordinal) || trimmed.StartsWith("~~~", StringComparison.Ordinal))
            {
                var mark = new string(trimmed[0], trimmed.TakeWhile(c => c == trimmed[0]).Count());
                var language = CodeLanguage.Label(trimmed[mark.Length..]);
                var body = new List<string>();
                i++;
                while (i < lines.Length)
                {
                    var t = TxText.TrimSpaces(lines[i]);
                    if (t.StartsWith(mark, StringComparison.Ordinal) && t.Trim(mark[0]).Length == 0) break;
                    body.Add(lines[i]);
                    i++;
                }
                i++;   // the closing fence
                while (body.Count > 0 && TxText.TrimSpaces(body[^1]).Length == 0) body.RemoveAt(body.Count - 1);
                if (body.Count == 0) continue;
                var head = "Code, " + (language is null ? "" : language + ", ") + Plural(body.Count, "line");
                var code = string.Join(" ", string.Join(" ", body).Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
                out_.Add(head + ": " + (code.Length > CodePreview ? code[..CodePreview] : code));
                continue;
            }
            if (trimmed.Contains('|') && i + 1 < lines.Length && TableRule.Test(lines[i + 1]) && lines[i + 1].Contains('|'))
            {
                var header = Cells(line);
                var rows = 0;
                var j = i + 2;
                while (j < lines.Length && lines[j].Contains('|') && TxText.TrimSpaces(lines[j]).Length > 0) { rows++; j++; }
                var named = header.Where(h => h.Length > 0).ToList();
                out_.Add("Table, " + Plural(rows, "row") + ", " + Plural(header.Length, "column")
                    + (named.Count == 0 ? "" : ". " + string.Join(", ", named)));
                i = j;
                continue;
            }
            out_.Add(line);
            i++;
        }
        return string.Join("\n", out_);
    }
}
