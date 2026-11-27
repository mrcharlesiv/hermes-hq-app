using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace Hermes.Core.Transcripts;

/// Link titles and site icons: reading the markup (HermesKit/Net/LinkPreviewParsing.swift, docs/spec/3x-transcript.md
/// §3.7), and a bare link's chip words. Only a site's own title and marks are used, never a third-party icon service.
public static class LinkPreviewParsing
{
    public const int TitleMax = 240;
    public const int HtmlLimit = 256 * 1024;
    public const int ImageLimit = 64 * 1024;

    private const RegexOptions I = RegexOptions.IgnoreCase;
    private static readonly TranscriptRx UnusableTitle = new(@"\b(access denied|attention required|captcha|error|forbidden|just a moment|request blocked|too many requests|sign[ -]?in|log[ -]?in)\b", I);
    private static readonly TranscriptRx SignInArrival = new(@"^accounts\.google\.com$|/ServiceLogin\b|/signin\b|/login\b|/o/oauth2/", I);
    private static readonly TranscriptRx Entity = new(@"&(#x[0-9a-f]+|#\d+|[a-z]+);", I);
    private static readonly TranscriptRx TitleTag = new(@"<title[^>]*>([\s\S]*?)</title>", I);
    private static readonly TranscriptRx MetaTag = new(@"<meta\b[^>]*>", I);
    private static readonly TranscriptRx LinkTag = new(@"<link\b[^>]*>", I);
    private static readonly TranscriptRx BaseTag = new(@"<base\b[^>]*>", I);
    private static readonly TranscriptRx AnyTag = new("<[^>]*>");
    private static readonly TranscriptRx Spaces = new(@"\s+");
    private static readonly TranscriptRx IconRel = new(@"\b(icon|apple-touch-icon|apple-touch-icon-precomposed|mask-icon|fluid-icon)\b");
    private static readonly TranscriptRx TitleKey = new("^(og:title|twitter:title)$", I);
    /// Characters that reorder or hide text (bidi overrides and isolates, zero-width marks): never in a title.
    private static readonly TranscriptRx Bidi = new("[\u202A-\u202E\u2066-\u2069\u200B-\u200F\uFEFF]");

    private static readonly Dictionary<string, string> Entities = new()
    {
        ["amp"] = "&", ["lt"] = "<", ["gt"] = ">", ["quot"] = "\"", ["apos"] = "'", ["nbsp"] = " ", ["ndash"] = "–", ["mdash"] = "—",
        ["hellip"] = "…", ["rsquo"] = "’", ["lsquo"] = "‘", ["rdquo"] = "”", ["ldquo"] = "“", ["middot"] = "·", ["bull"] = "•",
    };

    public static string DecodeEntities(string text)
    {
        if (!text.Contains('&')) return text;
        return Entity.Re.Replace(text, m =>
        {
            var name = m.Groups[1].Value;
            if (name.StartsWith('#'))
            {
                var digits = name[1..];
                var hex = digits.StartsWith('x') || digits.StartsWith('X');
                if (uint.TryParse(hex ? digits[1..] : digits, hex ? NumberStyles.AllowHexSpecifier : NumberStyles.None, CultureInfo.InvariantCulture, out var code)
                    && code is > 0 and <= 0x10FFFF && code is < 0xD800 or > 0xDFFF)
                    return char.ConvertFromUtf32((int)code);
                return m.Value;
            }
            return Entities.TryGetValue(name.ToLowerInvariant(), out var known) ? known : m.Value;
        });
    }

    public static string Attribute(string tag, string name)
    {
        var pattern = new TranscriptRx(@"\b" + Regex.Escape(name) + "\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s\"'>]+))", I);
        if (pattern.Groups(tag) is not { } g) return "";
        return g.Skip(2).FirstOrDefault(v => !string.IsNullOrEmpty(v)) ?? "";
    }

    /// The page's own title, or its Open Graph title when <title> is empty. "" for error and sign-in pages.
    public static string TitleFromHtml(string html)
    {
        var head = html.Length > HtmlLimit ? html[..HtmlLimit] : html;
        var title = TitleTag.Groups(head)?[1] ?? "";
        if (title.Trim().Length == 0)
            foreach (var tag in MetaTag.AllMatches(head))
            {
                var key = Attribute(tag, "property").Length == 0 ? Attribute(tag, "name") : Attribute(tag, "property");
                if (TitleKey.Test(key)) { title = Attribute(tag, "content"); break; }
            }
        var clean = DecodeEntities(AnyTag.Replace(title, ""));
        clean = Bidi.Replace(clean, "");
        clean = TxText.TrimSpaces(Spaces.Replace(clean, " "));
        if (clean.Length > TitleMax) clean = clean[..TitleMax];
        return clean.Length > 0 && !UnusableTitle.Test(clean) ? clean : "";
    }

    /// The final URL is a sign-in page: its title is not the document's.
    public static bool IsSignInArrival(Uri url) => SignInArrival.Test(url.Host) || SignInArrival.Test(url.AbsolutePath);

    private static string Absolute(string href, string baseUrl)
    {
        var clean = DecodeEntities(href.Trim());
        if (clean.Length == 0 || !Uri.TryCreate(baseUrl, UriKind.Absolute, out var b) || !Uri.TryCreate(b, clean, out var url)
            || !url.Scheme.Equals("https", StringComparison.OrdinalIgnoreCase)) return "";
        return url.AbsoluteUri;
    }

    /// Declared icons ranked (scalable, then larger), then the well-known paths; the top five, https only.
    public static List<string> IconCandidates(string html, string pageUrl)
    {
        var declaredBase = Absolute(Attribute(BaseTag.AllMatches(html).FirstOrDefault() ?? "", "href"), pageUrl);
        var baseUrl = declaredBase.Length == 0 ? pageUrl : declaredBase;
        var scored = new List<(string Url, int Score)>();
        foreach (var tag in LinkTag.AllMatches(html))
        {
            var rel = Attribute(tag, "rel").ToLowerInvariant();
            if (!IconRel.Test(rel)) continue;
            var url = Absolute(Attribute(tag, "href"), baseUrl);
            if (url.Length == 0) continue;
            var type = Attribute(tag, "type").ToLowerInvariant();
            var sizes = Attribute(tag, "sizes").ToLowerInvariant();
            var declared = sizes.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)
                .Select(t => t == "any" ? 512 : int.TryParse(t.Split('x')[0], NumberStyles.None, CultureInfo.InvariantCulture, out var n) ? n : 0)
                .DefaultIfEmpty(0).Max();
            var score = type.Contains("svg") || rel.Contains("mask-icon") ? 1024
                : declared > 0 ? Math.Min(declared, 512) : rel.Contains("apple-touch-icon") ? 180 : 96;
            scored.Add((url, score));
        }
        if (Uri.TryCreate(pageUrl, UriKind.Absolute, out var page) && page.Host.Length > 0 && page.Scheme == "https")
        {
            var origin = $"https://{page.Host}{(page.IsDefaultPort ? "" : $":{page.Port}")}";
            scored.Add(($"{origin}/apple-touch-icon.png", 50));
            scored.Add(($"{origin}/favicon.ico", 48));
            scored.Add(($"{origin}/favicon.png", 47));
        }
        var best = new Dictionary<string, int>();
        var order = new List<string>();
        foreach (var (url, score) in scored)
        {
            if (!best.ContainsKey(url)) order.Add(url);
            best[url] = Math.Max(best.GetValueOrDefault(url), score);
        }
        // Stable for equal scores (first declared first), as the web's sort is.
        return [.. order.Select((u, i) => (u, i)).OrderByDescending(x => best[x.u]).ThenBy(x => x.i).Select(x => x.u).Take(5)];
    }

    /// Magic bytes decide, never the server's header. "" for anything that is not a picture (or is under 48 bytes).
    public static string ImageMime(ReadOnlySpan<byte> bytes, string declared = "")
    {
        if (bytes.Length < 48) return "";
        bool At(ReadOnlySpan<byte> b, int offset, ReadOnlySpan<byte> sig) => b.Slice(offset, sig.Length).SequenceEqual(sig);
        if (At(bytes, 0, [0x89, 0x50, 0x4E, 0x47])) return "image/png";
        if (At(bytes, 0, [0xFF, 0xD8, 0xFF])) return "image/jpeg";
        if (At(bytes, 0, [0x47, 0x49, 0x46, 0x38])) return "image/gif";
        if (At(bytes, 0, [0x00, 0x00, 0x01, 0x00])) return "image/x-icon";
        if (At(bytes, 0, [0x52, 0x49, 0x46, 0x46]) && At(bytes, 8, [0x57, 0x45, 0x42, 0x50])) return "image/webp";
        var head = Encoding.UTF8.GetString(bytes[..Math.Min(bytes.Length, 1024)]).ToLowerInvariant();
        return head.Contains("<svg") || (declared.ToLowerInvariant().Contains("svg") && head.Contains('<')) ? "image/svg+xml" : "";
    }

    private static readonly TranscriptRx CharsetRe = new(@"charset=([\w-]+)", I);
    private static readonly TranscriptRx MetaCharsetRe = new("""<meta[^>]+charset=["']?([\w-]+)""", I);

    /// The page's text: the header's charset, then `<meta charset>`, then UTF-8.
    public static string Decode(byte[] data, string contentType)
    {
        var sniff = Encoding.UTF8.GetString(data, 0, Math.Min(data.Length, 2048));
        var declared = CharsetRe.Groups(contentType)?[1] ?? MetaCharsetRe.Groups(sniff)?[1] ?? "utf-8";
        try
        {
            var encoding = CodePagesEncodingProvider.Instance.GetEncoding(declared) ?? Encoding.GetEncoding(declared);
            return encoding.GetString(data);
        }
        catch (ArgumentException) { return Encoding.UTF8.GetString(data); }
    }

    private static string Bare(string host) => host.StartsWith("www.", StringComparison.OrdinalIgnoreCase) ? host[4..] : host;

    /// A bare URL's text: its host (without "www.", with a port that isn't the default) and path, "…" standing for a query
    /// or fragment it leaves out; or the page's title with that host once the title is known.
    public static string BareLinkLabel(string? title, string target)
    {
        var fetched = title?.Trim() ?? "";
        if (!Uri.TryCreate(target, UriKind.Absolute, out var url) || url.Host.Length == 0) return fetched.Length == 0 ? target : fetched;
        var host = Bare(url.Host) + (url.IsDefaultPort ? "" : $":{url.Port}");
        if (fetched.Length > 0)
            return fetched.Contains(Bare(url.Host), StringComparison.OrdinalIgnoreCase) ? fetched : $"{fetched} · {host}";
        var path = url.AbsolutePath;
        if (path == "/") path = "";
        if (path.EndsWith('/')) path = path[..^1];
        var more = url.Query.Length > 1 || url.Fragment.Length > 1 || target.Contains('?') || target.Contains('#');
        return $"{host}{path}{(more ? "…" : "")}";
    }

    /// The host a chip names: without "www.".
    public static string DisplayHost(Uri url) => Bare(url.Host);
}
