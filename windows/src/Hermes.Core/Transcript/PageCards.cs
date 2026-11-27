using System.Text.RegularExpressions;
using Hermes.Core.Artifacts;
using Hermes.Core.Model;

namespace Hermes.Core.Transcripts;

/// [page-cards] An HTML page handed over alone on its line: drawn as a page card in its place. `Path`: as written (the
/// path on the bot's computer); `Name`: its file's name.
public sealed record PageSegment(string Path, string Name) : ReplySegment;

/// The card's two lines (PageCardView.swift `showName`) and its spoken name.
public sealed record PageCardFace(string Name, string Hint, string AccessibleName);

/// One row of a held page card's menu (ChatViewController+Pins.swift `pageCardMenu`).
public sealed record PageCardMenuItem(string Id, string Title);

/// Page cards (App/Chat/Cells/PageCardView.swift, App/Chat/Viewer/PageOrder.swift, MarkdownRenderer.swift's BlockBuilder
/// `pageCards` and ChatViewController+Pins.swift `pageCardMenu` at 93f984bb1): an HTML page a bot hands over alone on its
/// line (`::preview{file="…"}`, `MEDIA:/…/page.html`) draws as a card — a picture of the page over its name, its size
/// fixed from the start so the picture arriving never moves the chat. While the reply still arrives the card is the same
/// size with no picture yet ("Building page…"). [page-fold] An earlier card of a page a later reply hands over again folds
/// to its caption ("Updated below").
public static partial class PageCards
{
    public const string AutomationId = "chat.page-card";
    public const string AccessibleHint = "Opens the page";

    /// The Mac's (`#if targetEnvironment(macCatalyst)`): the picture's height, the widest card, the caption's padding.
    public const double PictureHeight = 260, Widest = 480, PadH = 12, PadV = 9;

    /// pictureHeight + padV + body line + 2 + time line + padV (`height(style:)`).
    public static double Height(double bodyLine, double timeLine) => PictureHeight + FoldedHeight(bodyLine, timeLine);

    /// [page-fold] The caption alone (`foldedHeight(style:)`).
    public static double FoldedHeight(double bodyLine, double timeLine) => PadV + bodyLine + 2 + timeLine + PadV;

    /// `width(maxText:)`.
    public static double Width(double maxText) => Math.Min(maxText, Widest);

    /// HTMLPageSheet.opens(name:): an .html or .htm file.
    public static bool Opens(string name)
    {
        var ext = Path.GetExtension(name.TrimEnd('/', '\\'));
        return ext.Equals(".html", StringComparison.OrdinalIgnoreCase) || ext.Equals(".htm", StringComparison.OrdinalIgnoreCase);
    }

    /// [page-fresh-read] FilePreviewPresenter.present: a page is read again each time it opens (a bot rewrites its page
    /// in place), the kept copy if that fails; any other file, or a page saved or shared, comes from the kept copy.
    public static bool ReadsFresh(string name, bool opening) => opening && Opens(name);

    /// A file's name from its path (either separator).
    public static string FileName(string path)
    {
        var trimmed = path.TrimEnd('/', '\\');
        var cut = trimmed.LastIndexOfAny(['/', '\\']);
        return cut < 0 ? trimmed : trimmed[(cut + 1)..];
    }

    /// The page a line hands over as a card: `::preview{file="…"}` or `MEDIA:<path>` (quoted or not) of a page, alone.
    public static string? CardPath(string line)
    {
        var t = line.Trim();
        if (t.Length == 0) return null;
        string? path = null;
        if (ArtifactCollector.PreviewPath(t) is { } named) path = named;
        else if (MediaLine().Match(t) is { Success: true } m) path = Unquote(m.Groups[1].Value);
        return path is { Length: > 0 } && Opens(path) ? path : null;
    }

    private static string Unquote(string v) =>
        v.Length >= 2 && v[0] == v[^1] && v[0] is '"' or '`' or '\'' ? v[1..^1].Trim() : v.Trim();

    /// PageOrder.paths(in:): the pages a reply's text hands over alone on a line (`::preview`, `MEDIA:`, a bare path),
    /// as written, each once. What folds a card.
    public static List<string> Paths(string text)
    {
        var out_ = new List<string>();
        if (!text.Contains(".htm", StringComparison.OrdinalIgnoreCase)) return out_;
        foreach (var raw in text.Replace("\r\n", "\n").Split('\n'))
        {
            var line = raw.Trim(' ', '\t');
            if (!line.Contains(".htm", StringComparison.OrdinalIgnoreCase)) continue;
            string? path = null;
            if (ArtifactCollector.PreviewPath(line) is { } named) path = named;
            else if (line.StartsWith("MEDIA:", StringComparison.Ordinal)) path = line[6..].Trim(' ', '`', '"', '\'');
            else if (line.StartsWith('/') || line.StartsWith("~/") || line.StartsWith("`/") || line.StartsWith("`~/"))
            {
                var bare = line.Trim('`');
                if (!bare.Contains(' ') || bare.EndsWith(".html", StringComparison.Ordinal) || bare.EndsWith(".htm", StringComparison.Ordinal)) path = bare;
            }
            if (path != null && Opens(path) && !out_.Contains(path)) out_.Add(path);
        }
        return out_;
    }

    /// PageOrder.latest: for each page the bot's messages hand over, the id of the newest message that does.
    public static Dictionary<string, string> Latest(IEnumerable<ChatMessage> messages)
    {
        var out_ = new Dictionary<string, string>();
        foreach (var m in messages)
        {
            if (m.Role != Role.Assistant) continue;
            foreach (var path in Paths(m.Text)) out_[path] = m.Id;
        }
        return out_;
    }

    /// [page-fold] PageOrder.updatedBelow: the pages `text` (part of message `id`) hands over that a later message hands
    /// over again; their cards fold.
    public static HashSet<string> UpdatedBelow(string text, string id, IReadOnlyDictionary<string, string> latest)
    {
        if (latest.Count == 0) return [];
        return [.. Paths(text).Where(p => latest.TryGetValue(p, out var newest) && newest != id)];
    }

    /// PageCardView.showName: the page's own title over its file once the page has been read (the file's name until
    /// then, and for a page with no title or one that is only its file's name); the second line says what the card is.
    public static PageCardFace Face(string file, string? title, bool folded, bool building, bool pictured)
    {
        var named = !string.IsNullOrEmpty(title) && !string.Equals(title, file, StringComparison.OrdinalIgnoreCase);
        var kind = folded ? "Updated below" : building && !pictured ? "Building page…" : "Interactive page";
        var hint = named && !folded ? $"{kind} · {file}" : kind;
        var spoken = "Page, " + (named ? $"{title}, {file}" : file) + (folded ? ", updated below" : "");
        return new PageCardFace(named ? title! : file, hint, spoken);
    }

    /// pageCardMenu: Open, Pin as Tile / Unpin (in a gateway chat), Share…, Save As… (the Mac's FileSaver), Copy Path.
    public static IReadOnlyList<PageCardMenuItem> Menu(bool canPin, bool pinned)
    {
        var items = new List<PageCardMenuItem> { new("page.open", "Open") };
        if (canPin) items.Add(new("page.pin", pinned ? "Unpin" : "Pin as Tile"));
        items.Add(new("page.share", "Share…"));
        items.Add(new("page.save", "Save As…"));
        items.Add(new("page.copy-path", "Copy Path"));
        return items;
    }

    /// A reply's words as Markdown pieces and page cards, in order (MarkdownRenderer's BlockBuilder; Windows reads
    /// "alone" per line, as AttachmentHydration.ReplyParts lifts a lone `MEDIA:` line). Pages inside a sentence, a
    /// list, a quote, an indented block or code stay words.
    public static IReadOnlyList<ReplySegment> Split(string markdown)
    {
        if (!markdown.Contains(".htm", StringComparison.OrdinalIgnoreCase)) return [new WordsSegment(markdown)];
        var lines = markdown.Replace("\r\n", "\n").Split('\n');
        var cards = new Dictionary<int, PageSegment>();
        string? fence = null;
        for (var i = 0; i < lines.Length; i++)
        {
            var body = lines[i].TrimStart();
            if (fence != null)
            {
                if (body.StartsWith(fence, StringComparison.Ordinal)) fence = null;
                continue;
            }
            if (FenceOpen().Match(body) is { Success: true } f) { fence = f.Groups[1].Value; continue; }
            if (Indent(lines[i]) > 3 || CardPath(lines[i]) is not { } path) continue;
            cards[i] = new PageSegment(path, FileName(path));
        }
        if (cards.Count == 0) return [new WordsSegment(markdown)];
        var out_ = new List<ReplySegment>();
        var run = new List<string>();
        void Flush()
        {
            var text = string.Join("\n", run).Trim('\n');
            run.Clear();
            if (text.Trim().Length > 0) out_.Add(new WordsSegment(text));
        }
        for (var i = 0; i < lines.Length; i++)
        {
            if (cards.TryGetValue(i, out var page)) { Flush(); out_.Add(page); }
            else run.Add(lines[i]);
        }
        Flush();
        return out_;
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

    [GeneratedRegex(@"^MEDIA:\s*(""[^""\n]+""|`[^`\n]+`|'[^'\n]+'|\S+)$")]
    private static partial Regex MediaLine();
    [GeneratedRegex(@"^(`{3,}|~{3,})")]
    private static partial Regex FenceOpen();
}
