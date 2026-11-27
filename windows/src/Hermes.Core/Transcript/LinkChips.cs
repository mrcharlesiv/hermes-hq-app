using System.Text;
using System.Text.RegularExpressions;

namespace Hermes.Core.Transcripts;

/// A piece of a reply's words: Markdown to draw as it is, or a link chip in its place.
public abstract record ReplySegment;
public sealed record WordsSegment(string Markdown) : ReplySegment;
/// `Raw`: the address as written (the preview cache's key, as the Mac's `url.absoluteString`).
public sealed record ChipSegment(string Raw, Uri Url) : ReplySegment;

/// What a chip shows (App/Chat/Cells/LinkChipView.swift `configure` / `show`).
public sealed record LinkChipFace(string Title, string Host, bool HostShown, string AccessibleName, bool HasIcon);

/// Link chips (docs/spec/3x-transcript.md §3.7; App/Chat/Render/MarkdownRenderer.swift `loneWebAddress` and the
/// BlockBuilder's paragraph rule; TextLayout's `linkChips: !b.mine && !b.streaming`): a bare web address alone on its own
/// top-level paragraph of a settled reply gets a card in place of that paragraph — the line of blue text above it would
/// repeat the same address. A link inside a sentence, a list, a quote or code keeps its text (no chip).
public static partial class LinkChips
{
    public const string AutomationId = "chat.link-chip";

    /// Swift `TextLayout.rendered`: chips under a bot's settled reply only (never your own words, never while it arrives).
    public static bool Shows(bool mine, bool streaming) => !mine && !streaming;

    /// The paragraph's text is one https address and nothing else (Swift `MarkdownRenderer.loneWebAddress`).
    public static Uri? LoneWebAddress(string paragraph)
    {
        var text = paragraph.Trim();
        if (!text.StartsWith("https://", StringComparison.Ordinal) || text.Length > 2048 || text.Any(char.IsWhiteSpace)) return null;
        if (!Uri.TryCreate(text, UriKind.Absolute, out var url) || !url.Host.Contains('.')) return null;
        return url;
    }

    /// The chip's words before and after its page is read: the address in words (host and path, "…" for a query it
    /// leaves out) until a title arrives; the host under the title unless the title already starts with it.
    public static LinkChipFace Face(string raw, Uri url, LinkPreview? preview)
    {
        var host = LinkPreviewParsing.DisplayHost(url);
        var fetched = preview?.Title.Trim() ?? "";
        var title = fetched.Length > 0 ? fetched : LinkPreviewParsing.BareLinkLabel(null, raw);
        var shown = host.Length > 0 && !title.StartsWith(host, StringComparison.OrdinalIgnoreCase);
        return new LinkChipFace(title, host, shown, shown ? $"Link, {title}, {host}" : $"Link, {title}", preview?.Icon != null);
    }

    /// A reply's words as Markdown pieces and chips, in order. `settled` false (yours, or still arriving): the words as
    /// they are. Formulas are taken out first (MathText) so a `$$` block never splits; reference link definitions stay with
    /// every piece so a link still finds its target.
    public static IReadOnlyList<ReplySegment> Split(string markdown, bool settled)
    {
        if (!settled || !markdown.Contains("https://", StringComparison.Ordinal)) return [new WordsSegment(markdown)];
        var extracted = MathText.Extract(markdown.Replace("\r\n", "\n"));
        var lines = extracted.Text.Split('\n');
        var chips = ChipLines(lines);
        if (chips.Count == 0) return [new WordsSegment(markdown)];
        var definitions = lines.Where(l => RefDefinition().IsMatch(l)).ToList();
        var out_ = new List<ReplySegment>();
        var run = new List<string>();
        void Flush()
        {
            var text = string.Join("\n", run).Trim('\n');
            run.Clear();
            if (text.Trim().Length == 0) return;
            var missing = definitions.Where(d => !text.Contains(d, StringComparison.Ordinal)).ToList();
            if (missing.Count > 0) text += "\n\n" + string.Join("\n", missing);
            out_.Add(new WordsSegment(MathText.Restore(text, extracted.Formulas)));
        }
        for (var i = 0; i < lines.Length; i++)
        {
            if (chips.TryGetValue(i, out var chip)) { Flush(); out_.Add(chip); }
            else run.Add(lines[i]);
        }
        Flush();
        return out_;
    }

    private static Dictionary<int, ChipSegment> ChipLines(string[] lines)
    {
        var found = new Dictionary<int, ChipSegment>();
        string? fence = null;
        var opensParagraph = true;   // a blank line, the start, or a block that ends where it is (heading, fence, rule)
        var inList = false;
        for (var i = 0; i < lines.Length; i++)
        {
            var line = lines[i];
            var indent = Indent(line);
            var body = line.TrimStart();
            if (fence != null)
            {
                if (indent <= 3 && body.StartsWith(fence, StringComparison.Ordinal) && body.TrimEnd().Trim(fence[0]).Length == 0)
                {
                    fence = null;
                    opensParagraph = true;
                }
                continue;
            }
            if (body.Length == 0) { opensParagraph = true; continue; }
            if (indent <= 3 && FenceOpen().Match(body) is { Success: true } f)
            {
                fence = f.Groups[1].Value;
                inList = inList && indent > 0;
                continue;
            }
            var wasOpen = opensParagraph;
            opensParagraph = false;
            if (indent <= 3 && (AtxHeading().IsMatch(body) || ThematicBreak().IsMatch(body)))
            {
                opensParagraph = true;
                if (indent == 0) inList = false;
                continue;
            }
            if (indent <= 3 && ListItem().IsMatch(body)) { inList = true; continue; }
            if (indent > 3 || body.StartsWith('>') || body.StartsWith('|')) continue;
            if (inList && (indent > 0 || !wasOpen)) continue;   // a list item's own paragraph, or its lazy continuation
            inList = false;
            if (!wasOpen) continue;                             // the rest of the paragraph above
            if (i + 1 < lines.Length && !EndsParagraph(lines[i + 1])) continue;   // the paragraph goes on below
            var plain = PlainText(body.TrimEnd());
            if (MathText.BlockToken(plain) != null) continue;
            if (LoneWebAddress(plain) is { } url) found[i] = new ChipSegment(plain.Trim(), url);
        }
        return found;
    }

    private static int Indent(string line)
    {
        var n = 0;
        foreach (var c in line)
        {
            if (c == ' ') n++;
            else if (c == '\t') n += 4 - n % 4;
            else break;
        }
        return n;
    }

    /// The next line ends a one-line paragraph: blank, or a block that interrupts one (fence, heading, quote, a list
    /// item with words, a rule that is not a setext underline).
    private static bool EndsParagraph(string next)
    {
        var body = next.TrimStart();
        if (body.Length == 0) return true;
        if (Indent(next) > 3) return false;
        if (FenceOpen().IsMatch(body) || AtxHeading().IsMatch(body) || body.StartsWith('>')) return true;
        if (BulletWithWords().IsMatch(body) || OrderedOne().IsMatch(body)) return true;
        return ThematicBreak().IsMatch(body) && !SetextUnderline().IsMatch(body.TrimEnd());
    }

    /// The paragraph's plain text as the Mac's `Paragraph.plainText` reads it: a link's words, an autolink's address,
    /// inline code's code, emphasis's words; backslash escapes and entities resolved.
    internal static string PlainText(string text)
    {
        var s = text.Trim();
        for (var guard = 0; guard < 8; guard++)
        {
            if (s.Length > 2 && s[0] == '<' && s[^1] == '>' && Autolink().IsMatch(s)) return s[1..^1];
            if (InlineLink().Match(s) is { Success: true } link) { s = link.Groups[1].Value.Trim(); continue; }
            if (s.StartsWith('`'))
            {
                var n = s.TakeWhile(c => c == '`').Count();
                var ticks = new string('`', n);
                if (s.Length > 2 * n && s.EndsWith(ticks, StringComparison.Ordinal) && s[^(n + 1)] != '`')
                {
                    var code = s[n..^n];
                    if (code.Length >= 2 && code[0] == ' ' && code[^1] == ' ' && code.Trim().Length > 0) code = code[1..^1];
                    return code;
                }
                break;
            }
            if (s[0] is '*' or '_')
            {
                var mark = s[0];
                var n = Math.Min(3, s.TakeWhile(c => c == mark).Count());
                var run = new string(mark, n);
                if (s.Length > 2 * n && s.EndsWith(run, StringComparison.Ordinal)) { s = s[n..^n]; continue; }
            }
            break;
        }
        return LinkPreviewParsing.DecodeEntities(Escape().Replace(s, "$1"));
    }

    [GeneratedRegex(@"^(`{3,}|~{3,})")]
    private static partial Regex FenceOpen();
    [GeneratedRegex(@"^#{1,6}(\s|$)")]
    private static partial Regex AtxHeading();
    [GeneratedRegex(@"^([-*_])[ \t]*(\1[ \t]*){2,}$")]
    private static partial Regex ThematicBreak();
    [GeneratedRegex(@"^(-+|=+)$")]
    private static partial Regex SetextUnderline();
    [GeneratedRegex(@"^([-+*]|\d{1,9}[.)])([ \t]|$)")]
    private static partial Regex ListItem();
    [GeneratedRegex(@"^[-+*][ \t]+\S")]
    private static partial Regex BulletWithWords();
    [GeneratedRegex(@"^1[.)][ \t]+\S")]
    private static partial Regex OrderedOne();
    [GeneratedRegex(@"^<[A-Za-z][A-Za-z0-9+.\-]{1,31}:[^<>\s]*>$")]
    private static partial Regex Autolink();
    [GeneratedRegex(@"^\[((?:[^\[\]\\]|\\.)*)\]\(\s*<?[^\s()<>]*>?(?:\s+(?:""[^""]*""|'[^']*'|\([^)]*\)))?\s*\)$")]
    private static partial Regex InlineLink();
    [GeneratedRegex(@"^ {0,3}\[[^\]]+\]:\s*\S")]
    private static partial Regex RefDefinition();
    [GeneratedRegex(@"\\([!-/:-@\[-`{-~])")]
    private static partial Regex Escape();
}
