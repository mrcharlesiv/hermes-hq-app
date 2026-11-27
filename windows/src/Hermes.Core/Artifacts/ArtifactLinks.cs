using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace Hermes.Core.Artifacts;

public enum ArtifactLinkKind { External, File, Hash, Inert }

/// What a link in a note is. External: a web link (only http(s) ever leaves the app). File: another file, its target
/// as written (percent-decoded) and the `#fragment` after it. Hash: a heading in the note on screen.
public sealed record ArtifactLink(ArtifactLinkKind Kind, Uri? Url = null, string? Target = null, string? Fragment = null)
{
    public static readonly ArtifactLink Inert = new(ArtifactLinkKind.Inert);
}

/// Links inside a Markdown note (docs/spec/3x-morepages.md §3; HermesKit/Pages/ArtifactLinks.swift): what a link is,
/// the path of a note linked from another note (`linkedNotePath`), and the heading a `#fragment` names.
public static class ArtifactLinks
{
    private static readonly Regex Drive = new("""^[A-Za-z]:[\\/]""", RegexOptions.CultureInvariant);
    private static readonly Regex Scheme = new("""^([A-Za-z][A-Za-z0-9+.-]*):""", RegexOptions.CultureInvariant);

    public static ArtifactLink Classify(string href)
    {
        var raw = href.Trim();
        if (raw.Length == 0) return ArtifactLink.Inert;
        if (raw.StartsWith('#'))
        {
            var fragment = Decoded(raw[1..]);
            return fragment.Length == 0 ? ArtifactLink.Inert : new ArtifactLink(ArtifactLinkKind.Hash, Fragment: fragment);
        }
        if (raw.StartsWith("//", StringComparison.Ordinal)) return Web("https:" + raw);
        if (raw.StartsWith("www.", StringComparison.OrdinalIgnoreCase)) return Web("https://" + raw);
        var isDrive = Drive.IsMatch(raw);
        if (Scheme.Match(raw) is { Success: true } m && !isDrive)
        {
            switch (m.Groups[1].Value.ToLowerInvariant())
            {
                case "http" or "https": return Web(raw);
                case "file": break;
                default: return ArtifactLink.Inert;   // javascript:, data:, mailto:, custom schemes: never followed from a note
            }
        }
        var target = raw;
        string? frag = null;
        var hash = target.IndexOf('#');
        if (hash >= 0)
        {
            var tail = Decoded(target[(hash + 1)..]);
            frag = tail.Length == 0 ? null : tail;
            target = target[..hash];
        }
        target = Decoded(target);
        if (target.Length == 0 || target.Contains('\0')) return ArtifactLink.Inert;
        return new ArtifactLink(ArtifactLinkKind.File, Target: target, Fragment: frag);
    }

    private static ArtifactLink Web(string text) =>
        Uri.TryCreate(text, UriKind.Absolute, out var url) && url.Scheme is "http" or "https" && url.Host.Length > 0
            ? new ArtifactLink(ArtifactLinkKind.External, Url: url) : ArtifactLink.Inert;

    private static string Decoded(string text) => ArtifactCollector.PercentDecode(text) ?? text;

    /// The path of a note a link in the note at `from` points to: a relative link is in that note's folder, an absolute
    /// (or "~/") path is itself. A relative note stays relative, so its session's folder resolves it on the gateway.
    public static string LinkedNotePath(string from, string target)
    {
        var link = target.Trim();
        if (link.StartsWith("file://", StringComparison.OrdinalIgnoreCase)) link = link[7..];
        if (link.StartsWith('/') || link == "~" || link.StartsWith("~/", StringComparison.Ordinal)) return Collapse(link);
        var @base = from.Trim();
        var slash = @base.LastIndexOf('/');
        var folder = slash >= 0 ? @base[..(slash + 1)] : "";
        return Collapse(folder + link);
    }

    private static string Collapse(string path)
    {
        var absolute = path.StartsWith('/');
        var out_ = new List<string>();
        foreach (var segment in path.Split('/'))
        {
            if (segment.Length == 0 || segment == ".") continue;
            if (segment == "..")
            {
                if (out_.Count > 0 && out_[^1] != ".." && out_[^1] != "~") out_.RemoveAt(out_.Count - 1);
                else if (!absolute) out_.Add("..");
                continue;
            }
            out_.Add(segment);
        }
        return (absolute ? "/" : "") + string.Join("/", out_);
    }

    /// The last path component, for a page title ("notes/plan.md" → "plan.md").
    public static string Name(string path)
    {
        var trimmed = path.EndsWith('/') ? path[..^1] : path;
        return trimmed.Split('/', StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? path;
    }

    /// Back reads the previous note's name, or plain "Back" when that name is longer than 12 characters.
    public static bool BackUsesName(string name) => new StringInfo(name).LengthInTextElements <= 12;

    /// NFC, trimmed, lower-cased; everything but letters, digits, marks, "-", "_" and spaces dropped; spaces → "-".
    public static string HeadingSlug(string text)
    {
        var folded = text.Normalize(NormalizationForm.FormC).Trim().ToLowerInvariant();
        var kept = new StringBuilder();
        foreach (var rune in folded.EnumerateRunes())
        {
            var category = Rune.GetUnicodeCategory(rune);
            var letter = Rune.IsLetter(rune) || category is UnicodeCategory.DecimalDigitNumber or UnicodeCategory.LetterNumber
                or UnicodeCategory.OtherNumber or UnicodeCategory.NonSpacingMark or UnicodeCategory.SpacingCombiningMark
                or UnicodeCategory.EnclosingMark;
            if (letter || rune.Value is '-' or '_' or ' ') kept.Append(rune.ToString());
        }
        var slug = Regex.Replace(kept.ToString(), " +", "-");
        slug = Regex.Replace(slug, "-+", "-");
        return slug.Trim('-');
    }

    private static readonly Regex FactLine = new("""^([A-Za-z_][\w-]*):\s*(.*)$""", RegexOptions.CultureInvariant);

    /// "---\nkey: value\n---" at the top of a note → its facts ("Title", "Morning reading") and the rest
    /// (ArtifactTextViewController.swift `frontMatter`): a list's items join with ", ", other lines with "; ".
    public static (List<(string Key, string Value)> Facts, string Body) FrontMatter(string text)
    {
        if (!text.StartsWith("---\n", StringComparison.Ordinal)) return ([], text);
        var end = text.IndexOf("\n---", 4, StringComparison.Ordinal);
        if (end < 0) return ([], text);
        var head = text[4..end];
        var facts = new List<(string, string)>();
        string? key = null;
        var lines = new List<string>();
        void Flush()
        {
            if (key == null) return;
            var values = lines.Select(l => l.Trim()).Where(l => l.Length > 0).ToList();
            var said = values.Count > 0 && values.All(v => v.StartsWith("- ", StringComparison.Ordinal))
                ? string.Join(", ", values.Select(v => v[2..])) : string.Join("; ", values);
            if (said.Length > 0) facts.Add((TitleCase(key), said.Trim('"', '\'')));
        }
        foreach (var line in head.Split('\n'))
        {
            var m = FactLine.Match(line);
            if (m.Success)
            {
                Flush();
                key = m.Groups[1].Value;
                lines = [m.Groups[2].Value];
            }
            else lines.Add(line);
        }
        Flush();
        var rest = text[(end + 4)..];
        if (rest.StartsWith('\n')) rest = rest[1..];
        return (facts, rest);
    }

    /// "created_at" → "Created At" (JobWords.titleCase).
    public static string TitleCase(string key) =>
        string.Join(" ", key.Replace('_', ' ').Replace('-', ' ').Split(' ', StringSplitOptions.RemoveEmptyEntries)
            .Select(w => char.ToUpperInvariant(w[0]) + w[1..]));

    private static readonly Regex Heading =new("""^ {0,3}#{1,6}\s+(.*?)\s*#*\s*$""", RegexOptions.CultureInvariant);
    private static readonly Regex InlineMarks = new("""[*_`]|\[([^\]]*)\]\([^)]*\)""", RegexOptions.CultureInvariant);

    /// The note's headings with their ids, duplicates numbered `slug`, `slug-1`, … ATX headings only; lines inside a
    /// fenced code block are not headings.
    public static List<(string Id, string Text)> Headings(string markdown)
    {
        var out_ = new List<(string, string)>();
        var counts = new Dictionary<string, int>();
        string? fence = null;
        foreach (var line in markdown.Split('\n'))
        {
            var trimmed = line.Trim(' ', '\t');
            if (fence != null)
            {
                if (trimmed.StartsWith(fence, StringComparison.Ordinal)) fence = null;
                continue;
            }
            if (trimmed.StartsWith("```", StringComparison.Ordinal)) { fence = "```"; continue; }
            if (trimmed.StartsWith("~~~", StringComparison.Ordinal)) { fence = "~~~"; continue; }
            var m = Heading.Match(line);
            if (!m.Success || m.Groups[1].Value.Length == 0) continue;
            // The words as they are drawn: inline marks dropped.
            var plain = InlineMarks.Replace(m.Groups[1].Value, "$1");
            var @base = HeadingSlug(plain);
            if (@base.Length == 0) continue;
            var seen = counts.GetValueOrDefault(@base);
            counts[@base] = seen + 1;
            out_.Add((seen == 0 ? @base : $"{@base}-{seen}", plain));
        }
        return out_;
    }
}
