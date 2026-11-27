using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Hermes.Core.Artifacts;

/// The Artifacts collector (docs/spec/1x-pages.md §5.4; HermesKit/Pages/ArtifactCollector.swift): files, images and
/// links the bots produced, found in recent transcripts. Pure and thread-safe: the index runs it off the UI thread.
public static class ArtifactCollector
{
    public const int PageSize = 100;
    /// A transcript page over this many JSON characters fails its session (`artifact-utils.ts:31-32`).
    public const int MaxPageJsonChars = 32_000_000;
    public const string SafeLoadMessage =
        "Session transcript page exceeds the Desktop safe-load limit; use the Web Dashboard export for this session.";

    private const RegexOptions I = RegexOptions.IgnoreCase | RegexOptions.CultureInvariant;
    private const RegexOptions N = RegexOptions.CultureInvariant;
    private static Regex Rx(string pattern, RegexOptions o = N) => new(pattern, o | RegexOptions.Compiled);

    // ---- patterns (copied from the sources)

    private static readonly Regex MarkdownImage = Rx("""!\[([^\]]*)\]\(([^)\s]+)\)""");
    private static readonly Regex MarkdownLink = Rx("""\[([^\]]+)\]\(([^)\s]+)\)""");
    /// r1-94: a URL stops at markdown punctuation (`code`, **bold**, a link's "]").
    private static readonly Regex UrlRe = Rx("""https?://[^\s<>"'`)\]*\\]+""");
    private static readonly Regex PathRe = Rx("""(^|[\s("'`])((?:/|~[\\/]|\.\.?[\\/]|\\\\)[^\s"'`<>]+(?:\.[a-z0-9]{1,8})?)""", I);
    private static readonly Regex WindowsPathRe = Rx("""(^|[\s("'`])([A-Za-z]:[\\/][^\s"'`<>]+(?:\.[a-z0-9]{1,8})?)""", I);
    public static readonly Regex ImageExt = Rx("""\.(?:png|jpe?g|gif|webp|svg|bmp)(?:\?.*)?$""", I);
    private static readonly Regex FileExt = Rx("""\.(?:png|jpe?g|gif|webp|svg|bmp|pdf|txt|json|md|csv|xlsx?|docx?|pptx?|html|zip|tar|gz|avi|flac|m4a|mkv|mp3|ogg|opus|wav|webm|mp4|mov)(?:\?.*)?$""", I);
    private static readonly Regex ProducerTool = Rx("""(?:^|_)(?:creat(?:e|ion)|download|export|generat(?:e|ion)|render|save|speech|tts|write)(?:_|$)""", I);
    private static readonly Regex StrongKey = Rx("""^(?:artifact_(?:file|image|path|url)|files?_(?:created|modified|written)|generated_(?:file|image|path|url)|media_tag|output_(?:file|path|url)|result_(?:file|path|url)|saved_to|screenshot_path)$""", I);
    private static readonly Regex ProducerKey = Rx("""^(?:artifact(?:s|_(?:file|image|path|url))?|attachment(?:s|_(?:file|image|path|url))?|download(?:s|_(?:file|path|url))?|(?:audio|image|video)(?:_(?:file|path|url))?|file_path|local_path|media(?:_(?:file|path|url))?|path)$""", I);
    private static readonly Regex ShellOutputKey = Rx("""^(?:output|stdout|path)$""", I);
    private static readonly Regex ScreenshotPath = Rx("""Screenshot path:\s*([^\r\n<>]+)""", I);
    private static readonly Regex PipCacheDir = Rx("""/(?:\.cache/pip|library/caches/pip|appdata/local/pip/cache)/""");
    private static readonly Regex Wheel = Rx("""\.whl(?:\.metadata)?$""");
    private static readonly Regex PackageIndexDist = Rx("""/packages/.+\.(?:tar\.gz|tar\.bz2|zip|egg)(?:\.metadata)?$""");
    private static readonly Regex ArtifactFilePath = Rx("""^(?:file:|/|[~.][\\/]|\.\.[\\/]|[a-z]:[\\/]|\\\\)""", I);

    // `MEDIA:` tags (`parts.ts:19-206`).
    private static readonly string[] MediaExts =
    [
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "svg", "mp4", "mov", "avi", "mkv", "webm", "3gp", "mp3", "m2a",
        "wav", "ogg", "opus", "m4a", "flac", "pdf", "docx", "doc", "odt", "rtf", "txt", "md", "epub", "xlsx", "xls", "ods",
        "csv", "tsv", "json", "xml", "yaml", "yml", "kmz", "kml", "geojson", "gpx", "pptx", "ppt", "odp", "key", "zip", "tar",
        "gz", "tgz", "bz2", "xz", "7z", "rar", "apk", "ipa", "html", "htm",
    ];

    private static readonly Regex MediaTag = BuildMediaTag();

    private static Regex BuildMediaTag()
    {
        var alternation = string.Join("|", MediaExts.OrderByDescending(e => e.Length));
        var anchored = """(?:~/|/|[A-Za-z]:[/\\])\S+?(?:[^\S\n]+\S+?)*?\.(?:""" + alternation + """)(?=[\s`"'*_,;:)\]}]|MEDIA:|$)""";
        var bare = """[^\s`"]+""";
        return Rx("""[`"']?MEDIA:\s*(`[^`\n]+`|"[^"\n]+"|'[^'\n]+'|""" + anchored + "|" + bare + """)[`"']?""");
    }

    // ---- small pieces

    private static readonly Regex WinDrive = Rx("""^[A-Za-z]:[\\/]""");
    private static readonly Regex HttpOrFileScheme = Rx("""^(?:https?|file)://""", I);
    private static readonly Regex HttpScheme = Rx("""^https?://""", I);

    public static bool IsArtifactFilePath(string value) => ArtifactFilePath.IsMatch(value);

    private static bool IsWindowsPath(string value) => WinDrive.IsMatch(value) || value.StartsWith(@"\\", StringComparison.Ordinal);

    private static bool LooksLikePathOrUrl(string value) =>
        value.StartsWith("http://", StringComparison.Ordinal) || value.StartsWith("https://", StringComparison.Ordinal)
        || value.StartsWith("data:image/", StringComparison.Ordinal) || IsArtifactFilePath(value);

    /// A web or file URL Swift's `URL(string:)` would make: an absolute address with a scheme of its own (.NET would
    /// also read a bare "/path" as a file URI).
    internal static Uri? WebUri(string value)
    {
        if (!Regex.IsMatch(value, "^[A-Za-z][A-Za-z0-9+.-]*:")) return null;
        return Uri.TryCreate(value, UriKind.Absolute, out var u) ? u : null;
    }

    internal static string UriPath(Uri u)
    {
        var path = u.IsFile ? u.LocalPath : u.AbsolutePath;
        try { return Uri.UnescapeDataString(path); } catch (UriFormatException) { return path; }
    }

    private static string PathForFiltering(string value)
    {
        if (HttpOrFileScheme.IsMatch(value) && WebUri(value) is { } url) return UriPath(url).ToLowerInvariant();
        return value.Replace('\\', '/').ToLowerInvariant();
    }

    private static bool IsPythonPackageDownload(string value)
    {
        var path = PathForFiltering(value);
        return PipCacheDir.IsMatch(path) || Wheel.IsMatch(path) || (HttpScheme.IsMatch(value) && PackageIndexDist.IsMatch(path));
    }

    public static bool LooksLikeArtifact(string value, bool @explicit = false)
    {
        if (!@explicit && IsPythonPackageDownload(value)) return false;
        if (value.StartsWith("http://", StringComparison.Ordinal) || value.StartsWith("https://", StringComparison.Ordinal)
            || value.StartsWith("data:image/", StringComparison.Ordinal)) return true;
        if (!LooksLikePathOrUrl(value)) return false;
        if (@explicit) return true;
        return ImageExt.IsMatch(value) || FileExt.IsMatch(value);
    }

    private static readonly Regex TrailingTicks = Rx("""[`*]+$""");
    private static readonly Regex TrailingPunct = Rx("""[),.;]+$""");

    private static bool IsQuote(char c) => c is '"' or '\'' or '`';

    /// Strip up to 3 layers of matching quotes, trailing `` ` ``/`*`, trailing `),.;`.
    public static string NormalizeValue(string value)
    {
        var trimmed = value.Trim();
        for (var i = 0; i < 3; i++)
        {
            if (trimmed.Length < 2 || !IsQuote(trimmed[0]) || trimmed[0] != trimmed[^1]) break;
            trimmed = trimmed[1..^1].Trim();
        }
        trimmed = TrailingTicks.Replace(trimmed, "", 1);
        return TrailingPunct.Replace(trimmed, "", 1);
    }

    /// `#media:&lt;encoded path&gt;` → the path.
    public static string? MediaPathFromHref(string href)
    {
        if (!href.StartsWith("#media:", StringComparison.Ordinal)) return null;
        return PercentDecode(href["#media:".Length..]);
    }

    /// Swift's `removingPercentEncoding`: null when a % sequence is malformed or the bytes aren't UTF-8.
    internal static string? PercentDecode(string s)
    {
        if (!s.Contains('%')) return s;
        var bytes = new List<byte>(s.Length);
        for (var i = 0; i < s.Length; i++)
        {
            if (s[i] == '%')
            {
                if (i + 2 >= s.Length || !Uri.IsHexDigit(s[i + 1]) || !Uri.IsHexDigit(s[i + 2])) return null;
                bytes.Add(Convert.ToByte(s.Substring(i + 1, 2), 16));
                i += 2;
            }
            else bytes.AddRange(Encoding.UTF8.GetBytes(s[i].ToString()));
        }
        try { return new UTF8Encoding(false, true).GetString(bytes.ToArray()); }
        catch (DecoderFallbackException) { return null; }
    }

    private static string DecodeMediaHref(string value) => MediaPathFromHref(value) ?? value;

    private static readonly Regex TrailingMarks = Rx("""[`"'*_]{1,3}$""");

    private static string UnquoteMediaValue(string value)
    {
        var trimmed = value.Trim();
        if (trimmed.Length >= 2 && IsQuote(trimmed[0]) && trimmed[0] == trimmed[^1]) return trimmed[1..^1];
        return TrailingMarks.Replace(trimmed, "", 1);
    }

    private static readonly Regex DotThenSomething = Rx("""\.[^.]""");

    private static bool IsPlausibleMediaPath(string value) => value.Contains('/') || value.Contains('\\') || DotThenSomething.IsMatch(value);

    /// Raw `MEDIA:` values in `text`, quotes intact; bare captures shed trailing sentence punctuation.
    public static List<string> MediaTagValues(string text)
    {
        var out_ = new List<string>();
        foreach (Match match in MediaTag.Matches(text))
        {
            var value = match.Groups[1].Value;
            var path = value.Trim();
            if (path.Length >= 2 && IsQuote(path[0]) && path[0] == path[^1]) path = path[1..^1];
            else if (path.Length > 0 && path[^1] is '`' or '"') path = path[..^1];
            var end = path.Length;
            while (end > 0 && ".,;:!?".Contains(path[end - 1]))
            {
                if (!IsPlausibleMediaPath(path[..(end - 1)])) break;
                end--;
            }
            var punctuation = path.Length - end;
            if (!IsPlausibleMediaPath(path[..end])) continue;
            out_.Add(punctuation > 0 ? value[..Math.Max(0, value.Length - punctuation)] : value);
        }
        return out_;
    }

    // ---- phone fixes (src/artifact-collect.ts)

    private static readonly Regex PathWord = Rx("""^(?:[a-z][a-z0-9+.-]*://|/|~[\\/]|\.\.?[\\/]|data:)""", I);
    private static readonly Regex Hosted = Rx("""^//(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}(?::\d+)?/""", I);
    private static readonly Regex WindowsPath = Rx("""^(?:[A-Za-z]:[\\/]|\\\\)""");
    private static readonly Regex DataScheme = Rx("""^data:""", I);
    private static readonly Regex LineSplit = Rx("""\\[nrt]|[\r\n]+""");
    private static readonly Regex SchemeOrRoot = Rx("""^(?:[a-z][a-z0-9+.-]*:|/|~)""", I);

    /// One value per artifact: splits literal "\n"/"\r"/"\t" and real line breaks, and whitespace only when every word
    /// is a path or URL of its own.
    public static List<string> SplitArtifactValue(string value)
    {
        var trimmed = value.Trim();
        if (trimmed.Length == 0) return [];
        if (DataScheme.IsMatch(trimmed)) return [trimmed];
        string[] lines = WindowsPath.IsMatch(trimmed) ? [trimmed] : LineSplit.Replace(trimmed, "\0").Split('\0');
        var out_ = new List<string>();
        foreach (var line in lines)
        {
            var text = line.Trim();
            if (text.Length == 0) continue;
            var words = text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            if (words.Length > 1 && words.All(w => PathWord.IsMatch(w))) out_.AddRange(words);
            else out_.Add(text);
        }
        return out_;
    }

    /// "//host.tld/…" is a web URL without its scheme.
    public static string HostedArtifactUrl(string value) => Hosted.IsMatch(value) ? "https:" + value : value;

    /// A path the gateway resolves against the session's working directory.
    public static bool RelativeArtifactPath(string value) => !WindowsPath.IsMatch(value) && !SchemeOrRoot.IsMatch(value);

    public static List<string> ArtifactCandidates(string value, ArtifactSessionRow session)
    {
        var noCwd = session.LacksCwd;
        return [.. SplitArtifactValue(value).Select(HostedArtifactUrl).Where(v => !(noCwd && RelativeArtifactPath(v)))];
    }

    private static readonly Regex FileName = Rx("""^[^\\/]+\.[A-Za-z][A-Za-z0-9]{0,7}$""");

    /// r2-88: a link to a file keeps the file's own name ("CHANGELOG.md"); "" when the URL does not end in one.
    public static string UrlFileLabel(string href)
    {
        if (WebUri(href) is not { } url) return "";
        var name = UriPath(url).Split('/', StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? "";
        return FileName.IsMatch(name) ? name : "";
    }

    private static readonly HashSet<string> CcTlds = [.. (
        "ac ad ae af ag ai al am ao aq ar as at au aw ax az ba bb bd be bf bg bh bi bj bm bn bo bq br bs bt bw by bz " +
        "ca cc cd cf cg ch ci ck cl cm cn co cr cu cv cw cx cy cz de dj dk dm do dz ec ee eg er es et eu fi fj fk fm fo fr ga gb gd ge gf gg " +
        "gh gi gl gm gn gp gq gr gs gt gu gw gy hk hm hn hr ht hu id ie il im in io iq ir is it je jm jo jp ke kg kh ki km kn kp kr kw ky kz " +
        "la lb lc li lk lr ls lt lu lv ly ma mc md me mg mh mk ml mm mn mo mp mq mr ms mt mu mv mw mx my mz na nc ne nf ng ni nl no np nr nu " +
        "nz om pa pe pf pg ph pk pl pm pn pr ps pt pw py qa re ro rs ru rw sa sb sc sd se sg sh si sk sl sm sn so sr ss st su sv sx sy sz tc " +
        "td tf tg th tj tk tl tm tn to tr tt tv tw tz ua ug uk us uy uz va vc ve vg vi vn vu wf ws ye yt za zm zw ai").Split(' ')];

    private static readonly Regex UrlParts = Rx("""^([a-z][a-z0-9+.-]*://[^/?#]*)([^?#]*)(.*)$""", I);
    private static readonly Regex CompareRange = Rx("""^[\w.-]*\w\.{3}\w[\w.-]*$""");

    /// r4-19: "..." inside a URL elides it, except a git compare range inside one path segment.
    private static bool Elided(string raw)
    {
        if (!raw.Contains("...")) return false;
        var parts = UrlParts.Match(raw);
        if (!parts.Success) return true;
        string origin = parts.Groups[1].Value, path = parts.Groups[2].Value, rest = parts.Groups[3].Value;
        if (origin.Contains("...") || rest.Contains("...")) return true;
        return path.Split('/').Any(segment => segment.Contains("...") && !CompareRange.IsMatch(segment));
    }

    private static readonly Regex CutEnd = Rx("""\.{2,}$|…""");
    private static readonly Regex TrailingUrlPunct = Rx("""[.,;:!?*_~`…]+$""");
    private static readonly Regex Ipv4 = Rx("""^\d{1,3}(?:\.\d{1,3}){3}$""");
    private static readonly Regex Letters = Rx("""^[a-z]+$""", I);

    /// r3-53: a URL the transcript cut off ("https://example.co…"). `next` is the character after the match.
    public static bool UrlCutOff(string raw, string next = "")
    {
        if (CutEnd.IsMatch(raw) || next == "…" || Elided(raw)) return true;
        var stripped = TrailingUrlPunct.Replace(raw, "", 1);
        if (WebUri(stripped) is not { } url || url.Host.Length == 0) return true;
        var host = url.Host;
        if (!host.Contains('.') || Ipv4.IsMatch(host) || host.StartsWith('[')) return false;
        var tld = host.Split('.').Last();
        if (tld.StartsWith("xn--", StringComparison.OrdinalIgnoreCase)) return false;
        if (!Letters.IsMatch(tld) || tld.Length < 2) return true;
        return tld.Length == 2 && !CcTlds.Contains(tld.ToLowerInvariant());
    }

    // ---- labels

    private static readonly Regex SlugA = Rx("""\.a\d+\..*$""", I);
    private static readonly Regex SlugExt = Rx("""\.(?:html?|php|aspx?)$""", I);
    private static readonly Regex SlugTail = Rx("""(?:[-_.](?:[a-z]{1,3}\d{2,}|i\d{2,}))+$""", I);
    private static readonly Regex Dashes = Rx("""[_-]+""");
    private static readonly Regex Spaces = Rx("""\s+""");
    private static readonly Regex AnyLetter = Rx("""[a-z]""", I);
    private static readonly Regex CodeLike = Rx("""^(?:[a-z]{1,3}\d+|\d+)$""", I);
    private static readonly Regex WordStart = Rx("""\b[a-z]""");

    private static string CleanSlug(string segment)
    {
        if (PercentDecode(segment) is not { } decoded) return "";
        var s = SlugA.Replace(decoded, "", 1);
        s = SlugExt.Replace(s, "", 1);
        s = SlugTail.Replace(s, "", 1);
        s = Dashes.Replace(s, " ");
        return Spaces.Replace(s, " ").Trim();
    }

    public static string HostPathLabel(string value)
    {
        if (WebUri(value) is not { } url || url.Host.Length == 0) return value;
        var host = url.Host;
        var shortHost = host.StartsWith("www.", StringComparison.Ordinal) ? host[4..] : host;
        var path = UriPath(url);
        if (path == "/") path = "";
        if (path.EndsWith('/')) path = path[..^1];
        return shortHost + path;
    }

    /// A link's title from its slug ("…/getting-started" → "Getting Started"), else host + path.
    public static string UrlSlugTitleLabel(string value)
    {
        if (WebUri(value) is not { } url) return value;
        var segments = Enumerable.Reverse(url.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries));
        foreach (var segment in segments)
        {
            var cleaned = CleanSlug(segment);
            if (cleaned.Length == 0 || !AnyLetter.IsMatch(cleaned)) continue;
            if (CodeLike.IsMatch(cleaned.Replace(" ", ""))) continue;
            var identifier = cleaned.Any(char.IsDigit) || cleaned.Any(char.IsUpper) || cleaned.Contains('.');
            var label = identifier && !cleaned.Contains(' ') ? cleaned : WordStart.Replace(cleaned, m => m.Value.ToUpperInvariant());
            if (label.Length >= 4) return label;
        }
        return HostPathLabel(value);
    }

    public static string Label(string value, ArtifactKind kind)
    {
        if (value.StartsWith("data:", StringComparison.Ordinal)) return "Image";
        if (kind == ArtifactKind.Link)
        {
            var file = UrlFileLabel(value);
            return file.Length == 0 ? UrlSlugTitleLabel(value) : file;
        }
        if (value.StartsWith("http://", StringComparison.Ordinal) || value.StartsWith("https://", StringComparison.Ordinal))
        {
            var file = UrlFileLabel(value);
            if (file.Length > 0) return file;
            return WebUri(value) is { } u ? UriPath(u).Split('/', StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? value : value;
        }
        var path = value;
        if (path.StartsWith("file://", StringComparison.Ordinal)) path = WebUri(path) is { } f ? Uri.UnescapeDataString(f.AbsolutePath) : path;
        return path.Split(['/', '\\'], StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? value;
    }

    public static ArtifactKind Kind(string value)
    {
        if (value.StartsWith("data:image/", StringComparison.Ordinal) || ImageExt.IsMatch(value)) return ArtifactKind.Image;
        if (IsArtifactFilePath(value)) return ArtifactKind.File;
        return ArtifactKind.Link;
    }

    /// http/https/data as is; file paths → a `file://` URL string (only used to tell artifacts apart).
    public static string Href(string value)
    {
        if (value.StartsWith("http://", StringComparison.Ordinal) || value.StartsWith("https://", StringComparison.Ordinal)
            || value.StartsWith("data:", StringComparison.Ordinal)) return value;
        if (value.StartsWith("file://", StringComparison.Ordinal)) return value;
        if (value.StartsWith('/') || IsWindowsPath(value))
            return "file://" + value.Replace("%", "%25").Replace("#", "%23").Replace("?", "%3F");
        return value;
    }

    // ---- messages

    internal static string? S(JsonNode? node) => ArtifactSessionRow.Str(node);

    public static string MessageText(JsonNode? message)
    {
        foreach (var key in new[] { "content", "text", "context" })
            if (S(message.Get(key)) is { } text && text.Trim().Length > 0) return text;
        return "";
    }

    private static double? NormalizeTimestamp(double? value)
    {
        if (value is not { } v || !double.IsFinite(v) || v <= 0) return null;
        return v < 10_000_000_000 ? v * 1000 : v;
    }

    private static readonly Regex UntrustedOpen = Rx("""^<untrusted_tool_result\b[^>]*>\s*""");

    private static string? UntrustedToolPayload(string value)
    {
        var trimmed = value.Trim();
        var open = UntrustedOpen.Match(trimmed);
        if (!open.Success) return null;
        var close = trimmed.LastIndexOf("</untrusted_tool_result>", StringComparison.Ordinal);
        if (close < 0 || close <= open.Length) return null;
        var wrapped = trimmed[open.Length..close].Trim();
        var blank = wrapped.IndexOf("\n\n", StringComparison.Ordinal);
        return blank >= 0 ? wrapped[(blank + 2)..].Trim() : wrapped;
    }

    private static List<JsonNode> ParseToolPayloads(string text)
    {
        var out_ = new List<JsonNode>();
        foreach (var candidate in new[] { text, UntrustedToolPayload(text) })
        {
            if (candidate == null || candidate.Trim().Length == 0) continue;
            JsonNode? parsed;
            try { parsed = JsonNode.Parse(candidate); } catch (JsonException) { continue; }
            if (parsed != null) out_.Add(parsed);
        }
        return out_;
    }

    private static JsonNode? StructuredPayload(JsonNode? message)
    {
        switch (message.Get("content"))
        {
            case JsonObject o:
                if (o["_multimodal"] is JsonValue mv && mv.GetValueKind() == JsonValueKind.True) return o["meta"];
                return o;
            case JsonArray a: return a;
            default: return null;
        }
    }

    private static void CollectStrings(JsonNode? value, string keyPath, Action<string, string> collector)
    {
        switch (value)
        {
            case JsonValue v when v.TryGetValue(out string? s): collector(s, keyPath); break;
            case JsonArray a:
                for (var i = 0; i < a.Count; i++) CollectStrings(a[i], $"{keyPath}.{i}", collector);
                break;
            case JsonObject o:
                foreach (var key in o.Select(p => p.Key).OrderBy(k => k, StringComparer.Ordinal))
                    if (o[key] != null) CollectStrings(o[key], keyPath.Length == 0 ? key : $"{keyPath}.{key}", collector);
                break;
        }
    }

    private delegate void Push(string raw, bool @explicit);

    private static void CollectFromText(string text, Push push)
    {
        foreach (var value in MediaTagValues(text)) push(UnquoteMediaValue(value), true);
        // The desktop app's inline page (`::preview{file="…"}`) is a file the reply hands over too.
        foreach (var line in text.Split('\n')) if (PreviewPath(line) is { } page) push(page, true);
        foreach (Match m in MarkdownImage.Matches(text)) push(m.Groups[2].Value, false);
        foreach (Match m in MarkdownLink.Matches(text))
        {
            if (m.Index > 0 && text[m.Index - 1] == '!') continue;
            var value = DecodeMediaHref(m.Groups[2].Value);
            if (LooksLikeArtifact(value)) push(value, false);
        }
        foreach (Match m in UrlRe.Matches(text))
        {
            var raw = m.Value;
            var end = m.Index + m.Length;
            var next = end < text.Length ? text.Substring(end, 1) : "";
            if (UrlCutOff(raw, next)) continue;
            var value = TrailingUrlMarks.Replace(raw, "", 1);
            if (LooksLikeArtifact(value)) push(value, false);
        }
        foreach (Match m in PathRe.Matches(text)) push(m.Groups[2].Value, false);
        foreach (Match m in WindowsPathRe.Matches(text)) push(m.Groups[2].Value, false);
    }

    private static readonly Regex TrailingUrlMarks = Rx("""[.,;:!?*_~`]+$""");

    // `::preview{file="…"}` (HermesKit/Chat/Transcript/MediaTags.swift `previewPath`): the file a reply's inline page names.
    private static readonly Regex PreviewDirective = Rx("""^\s*::preview\{([^}\n]*)\}\s*$""");
    private static readonly Regex PreviewFile = Rx("""(?:^|\s)(?:file|src|path)\s*=\s*(?:"([^"\n]+)"|'([^'\n]+)'|(\S+))""");

    public static string? PreviewPath(string line)
    {
        if (!line.Contains("::preview{")) return null;
        var m = PreviewDirective.Match(line);
        if (!m.Success) return null;
        var f = PreviewFile.Match(m.Groups[1].Value);
        if (!f.Success) return null;
        for (var i = 1; i <= 3; i++)
        {
            if (!f.Groups[i].Success) continue;
            var path = f.Groups[i].Value.Trim(' ', '\t');
            return IsPlausibleMediaPath(path) ? path : null;
        }
        return null;
    }

    private static readonly Regex WebOrData = Rx("""^(?:https?:|data:)""", I);

    /// The values in what a shell printed that are on the machine: every web address (and inline picture) dropped.
    public static List<string> LocalValues(string raw) =>
        [.. SplitArtifactValue(NormalizeValue(DecodeMediaHref(raw))).Select(v => HostedArtifactUrl(NormalizeValue(v)))
            .Where(v => !WebOrData.IsMatch(v))];

    // ---- junk (owner 2026-11-02: "You have a TON of artifacts saved from email footers and other BS")

    private sealed record JunkRule(string[] Hosts, Regex? Path = null, Regex? Keep = null);

    private static readonly JunkRule[] JunkRules =
    [
        // Social profiles, pages and share buttons (an email footer's icons). One post or video is kept.
        new(["tiktok.com", "instagram.com", "facebook.com", "linkedin.com", "x.com", "twitter.com", "youtube.com"],
            Keep: Rx("""^/(?:(?:[^/]+/)+status/\d|(?:p|reels?|tv|shorts|live|embed)/[^/?]+|watch/?\?(?:[^#]*&)?v=|playlist\?|@[^/]+/video/\d|(?:[^/]+/)?(?:posts|videos)/[^/?]+|feed/update/|pulse/|events/\d|jobs/view/|photo|permalink|story\.php|groups/[^/]+/(?:posts|permalink)/|adsmanager/|business/|ads/manager/)""")),
        // Unsubscribe, email preferences, manage subscription.
        new([], Path: Rx("""unsubscribe|\bunsub\b|opt[-_]?out|(?:e-?mail|subscription)s?[-_]?(?:preferences?|prefs|cent(?:er|re))|manage[-_]?(?:subscriptions?|preferences|prefs)|preference[-_]?cent(?:er|re)""")),
        // Mail senders' click trackers, list hosts and image hosts.
        new(["list-manage.com", "mailchi.mp", "mcusercontent.com", "campaign-archive.com", "mail.beehiiv.com", "media.beehiiv.com",
             "sendgrid.net", "klclick.com", "klclick1.com", "klclick2.com", "klclick3.com", "trk.klaviyo.com", "ctrk.klaviyo.com",
             "klaviyomail.com", "hubspotlinks.com", "hubspotemail.net", "track.hubspot.com", "mandrillapp.com", "mailgun.org",
             "mailgun.net", "sparkmailapp.com", "cdninstagram.com", "fbcdn.net"]),
        // Gmail's image proxy (ci3.googleusercontent.com/meips/…); other googleusercontent pictures stay.
        new(["googleusercontent.com"], Path: Rx("""^/(?:meips|proxy)/""")),
        // Tracking pixels and click redirects: …/open, /wf/open, /track/click, pixel.gif, 1x1.gif.
        new([], Path: Rx("""(?:^|/)(?:opens?|pixel|beacon)(?:\.[a-z]{2,4})?(?:/|\?|$)|(?:^|/)(?:track|trk|tracking)(?:/(?:open|click)|\.(?:gif|png|php|aspx?))|(?:^|/)ls/click|(?:^|[/_-])(?:1x1|spacer|transparent|blank)\.(?:gif|png)(?:\?|$)|/1x1(?:/|\?|$)""")),
    ];

    /// An address that is mail plumbing or a social profile, never something a bot made or the owner wants back.
    public static bool IsJunk(string value)
    {
        if (!HttpScheme.IsMatch(value) || WebUri(value) is not { } url || url.Host.Length == 0) return false;
        var host = url.Host.ToLowerInvariant();
        if (host.StartsWith("www.", StringComparison.Ordinal)) host = host[4..];
        var rest = UriPath(url).ToLowerInvariant() + (url.Query.Length > 1 ? "?" + url.Query[1..].ToLowerInvariant() : "");
        return JunkRules.Any(rule =>
            (rule.Hosts.Length == 0 || rule.Hosts.Any(h => host == h || host.EndsWith("." + h, StringComparison.Ordinal)))
            && (rule.Path?.IsMatch(rest) ?? true) && !(rule.Keep?.IsMatch(rest) ?? false));
    }

    /// Owner 2026-11-03: a file in a bot's own working folder under `.hermes` (`state`, `…_state`) is its bookkeeping;
    /// it counts only when the bot hands it over (`MEDIA:`, `::preview`).
    private static readonly Regex BotStateFolder = Rx("""(?:^|/)\.hermes/(?:[^/]+/)*?(?:state|[^/]+_state)/""", I);

    public static bool IsBotStateFile(string value) =>
        IsArtifactFilePath(value) && BotStateFolder.IsMatch(value.Replace('\\', '/'));

    /// Owner 2026-11-03 ("why so many random images"): a bot's own working pictures count only when handed over.
    private static readonly Regex WorkingPicture = Rx("""(?:^|/)\.hermes/(?:[^/]+/)*?cache/(?:images|screenshots)/|/\.config/browser-harness/tmp/|(?:^|/)(?:computer_use|browser_screenshot)_[0-9a-f]+\.(?:png|jpe?g|webp)$""", I);

    public static bool IsWorkingPicture(string value) =>
        IsArtifactFilePath(value) && WorkingPicture.IsMatch(value.Replace('\\', '/'));

    /// Owner 2026-11-03 (round 2): an email's inline pictures saved one part at a time are the mail. Sent, they stay.
    private static readonly Regex SavedEmailPart = Rx("""(?:^|/)[^/]*email[_-]?evidence[^/]*/|(?:^|/)[^/]*(?:mail|icloud|inbox|outlook|mime|eml)[^/]*/(?:[^/]+/)*part-\d+(?:\.\d+)*\.(?:png|jpe?g|gif|webp|bmp|svg)$|(?:^|/)image0\d\d\.(?:png|jpe?g|gif)$""", I);

    public static bool IsSavedEmailPart(string value) => SavedEmailPart.IsMatch(PathForFiltering(value));

    /// Owner 2026-11-03 (round 2): a site's own icons and a weather feed's pictures are page furniture. Sent, they stay.
    private static readonly Regex WebIcon = Rx("""(?:^|/)(?:favicon|apple-touch-icon|android-chrome|mstile|safari-pinned-tab)[^/]*\.(?:png|ico|svg|jpe?g|gif|webp)$|/weather/(?:[^/]+/)*(?:\d+x\d+|icons?)/|/onebox/weather/|/img/wn?/\d+[dn](?:@\dx)?\.png$|(?:^|/)wsymbols?\d*_|(?:^|/)weather[-_]?icons?/|/icons?/weather/""", I);

    public static bool IsWebIcon(string value) => WebIcon.IsMatch(PathForFiltering(value));

    private static readonly Regex EscapedSlashes = Rx("""\\+/""");

    /// "//cdn…/icon.png" is a web address without its scheme, never a file on the machine; so is the same address with
    /// its slashes JSON-escaped.
    public static bool IsSchemelessWebAddress(string value) =>
        EscapedSlashes.Replace(value, "/").StartsWith("//", StringComparison.Ordinal);

    /// Hermes's context-compaction handoff retells earlier turns; it hands nothing over.
    private static readonly Regex CompactionHead = Rx("""^\s*\[(?:CONTEXT COMPACTION|CONTEXT SUMMARY\]:|PRIOR CONTEXT\b)""");

    public static bool IsCompactionSummary(JsonNode? message)
    {
        if (message.Get("_compressed_summary") is JsonValue v && v.GetValueKind() == JsonValueKind.True) return true;
        var text = MessageText(message);
        return CompactionHead.IsMatch(text.Length > 300 ? text[..300] : text);
    }

    /// Tools that look at a screen or a page: what they return is a working picture, never an artifact by itself.
    private static readonly Regex LookingTool = Rx("""^(?:computer_use|browser_[a-z_]+|vision_analyze)$""");

    private static void CollectFromMessage(JsonNode? message, Push pushAny)
    {
        var role = S(message.Get("role"));
        var text = MessageText(message);
        if (role == "assistant")
        {
            if (text.Length > 0) CollectFromText(text, pushAny);
            return;
        }
        if (role != "tool") return;
        var name = (S(message.Get("tool_name")) ?? S(message.Get("name")) ?? "").Trim().ToLowerInvariant();
        var producer = ProducerTool.IsMatch(name) || name.StartsWith("bfl_flux3_", StringComparison.Ordinal);
        var terminal = name == "terminal";
        var looking = LookingTool.IsMatch(name);
        void push(string raw, bool @explicit)
        {
            if (@explicit && !terminal) { pushAny(raw, true); return; }
            if (looking) return;
            if (!terminal) { pushAny(raw, false); return; }
            foreach (var value in LocalValues(raw)) if (Kind(value) != ArtifactKind.Image) pushAny(value, false);
        }
        var payloads = ParseToolPayloads(text);
        // Round 2: a tool that failed made nothing.
        if (payloads.Any(p => p.Get("success") is JsonValue sv && sv.GetValueKind() == JsonValueKind.False)) return;
        if (text.Length > 0 && (producer || terminal)) CollectFromText(text, push);
        if (name == "browser_vision" && text.Length > 0)
            foreach (Match m in ScreenshotPath.Matches(text)) push(m.Groups[1].Value, false);
        if (StructuredPayload(message) is { } structured) payloads.Add(structured);
        foreach (var parsed in payloads)
        {
            CollectStrings(parsed, "tool_result", (value, keyPath) =>
            {
                var segments = keyPath.Split('.').Where(s => s.Length > 0 && !int.TryParse(s, out _)).ToList();
                var shellOutput = terminal && segments.Any(s => ShellOutputKey.IsMatch(s));
                var explicitKey = segments.Any(s => StrongKey.IsMatch(s) || (producer && ProducerKey.IsMatch(s)));
                if (!shellOutput && !explicitKey) return;
                if (shellOutput)
                {
                    if (value.Length > 0) CollectFromText(value, push);
                    return;
                }
                foreach (var media in MediaTagValues(value)) push(UnquoteMediaValue(media), true);
                var normalized = NormalizeValue(DecodeMediaHref(value));
                if (normalized.Length > 0 && LooksLikeArtifact(normalized)) push(normalized, false);
            });
        }
    }

    /// Artifacts in one page of a session's transcript, first occurrence per value.
    public static List<ArtifactRecord> Collect(ArtifactSessionRow session, IEnumerable<JsonNode?> messages, double? now = null)
    {
        var nowMs = now ?? DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var found = new Dictionary<string, int>();
        var out_ = new List<ArtifactRecord>();
        var title = session.DisplayTitle;
        foreach (var message in messages)
        {
            var role = S(message.Get("role"));
            if (role is not ("assistant" or "tool") || IsCompactionSummary(message)) continue;
            CollectFromMessage(message, (raw, @explicit) =>
            {
                var normalized = NormalizeValue(DecodeMediaHref(raw));
                List<string> parts = @explicit ? [normalized] : SplitArtifactValue(normalized).Where(p => !IsSchemelessWebAddress(p)).ToList();
                foreach (var candidate in parts.SelectMany(p => ArtifactCandidates(p, session)))
                {
                    var value = NormalizeValue(candidate);
                    if (value.Length == 0 || !LooksLikeArtifact(value, @explicit) || IsJunk(value)) continue;
                    if (!@explicit && (IsBotStateFile(value) || IsWorkingPicture(value) || IsSavedEmailPart(value) || IsWebIcon(value))) continue;
                    // The profile is part of the id: two profiles can hold the same session id (copied homes).
                    var key = $"{ArtifactIndex.Key(session.Profile, session.Id)}:{value}";
                    // [morepages] a repeat is counted on the row that is kept (3x-morepages §2)
                    if (found.TryGetValue(key, out var index)) { out_[index] = out_[index] with { Repeats = out_[index].Repeats + 1 }; continue; }
                    var kind = Kind(value);
                    var stamp = NormalizeTimestamp(ArtifactSessionRow.Number(message.Get("timestamp")))
                        ?? NormalizeTimestamp(session.LastActive) ?? NormalizeTimestamp(session.StartedAt) ?? nowMs;
                    found[key] = out_.Count;
                    out_.Add(new ArtifactRecord
                    {
                        Id = key, Kind = kind, Value = value, Href = Href(value), Label = Label(value, kind), SessionId = session.Id,
                        Profile = session.Profile, SessionTitle = title, Timestamp = stamp,
                    });
                }
            });
        }
        return out_;
    }

    /// Across sessions, one per [profile, kind, value, href], newest first. A file at a full path, or a link, is one
    /// row: the newest chat's, counting every mention. A relative path is still one per chat.
    public static List<ArtifactRecord> Unique(IEnumerable<ArtifactRecord> items)
    {
        var seen = new Dictionary<string, int>();
        var counts = new List<Dictionary<string, int>>();
        var out_ = new List<ArtifactRecord>();
        // A stable sort, newest first (Swift's sort is stable for equal stamps too).
        foreach (var item in items.Select((r, i) => (r, i)).OrderByDescending(x => x.r.Timestamp).ThenBy(x => x.i).Select(x => x.r))
        {
            var chat = RelativeArtifactPath(item.Value) ? item.SessionId : "";
            var key = $"{item.Profile ?? ""}\u001F{chat}\u001F{item.Kind.Raw()}\u001F{item.Value}\u001F{item.Href}";
            if (seen.TryGetValue(key, out var index))
            {
                counts[index][item.Id] = Math.Max(counts[index].GetValueOrDefault(item.Id), item.Repeats);
                out_[index] = out_[index] with { Repeats = counts[index].Values.Sum() };
                continue;
            }
            seen[key] = out_.Count;
            counts.Add(new Dictionary<string, int> { [item.Id] = item.Repeats });
            out_.Add(item);
        }
        return out_;
    }

    /// One page of a session's transcript: the answer's text.
    public delegate Task<string> PageReader(ArtifactSessionRow session, int limit, int offset, CancellationToken ct);

    /// Reads one session page by page (oldest first, 100 at a time), collecting as it goes. Throws the safe-load error
    /// for a page over the limit, or the page read's own error.
    public static async Task<List<ArtifactRecord>> LoadSessionAsync(ArtifactSessionRow session, PageReader page,
        int maxPageJsonChars = MaxPageJsonChars, CancellationToken ct = default)
    {
        var collected = new List<ArtifactRecord>();
        var seen = new Dictionary<string, int>();
        var offset = 0;
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            var text = await page(session, PageSize, offset, ct).ConfigureAwait(false);
            var json = J.Parse(text) ?? throw new ArtifactReadException("The gateway’s answer couldn’t be read.");
            var messages = json.Arr("messages") ?? json as JsonArray ?? new JsonArray();
            // The page's JSON size (`JSON.stringify(page.messages).length`): the answer's length bounds it closely.
            if (text.Length > maxPageJsonChars && messages.ToJsonString().Length > maxPageJsonChars) throw new ArtifactSafeLoadException();
            foreach (var artifact in Collect(session, messages))
            {
                if (seen.TryGetValue(artifact.Id, out var index))
                {
                    collected[index] = collected[index] with { Repeats = collected[index].Repeats + artifact.Repeats };
                    continue;
                }
                seen[artifact.Id] = collected.Count;
                collected.Add(artifact);
            }
            var limit = json.Get("pagination").Int("limit");
            if (limit is not { } l || messages.Count == 0 || messages.Count < l) break;
            offset += messages.Count;
        }
        return collected;
    }
}

/// A transcript page over the Desktop safe-load limit (`ArtifactLoadError.safeLoadLimit`).
public sealed class ArtifactSafeLoadException() : Exception(ArtifactCollector.SafeLoadMessage);

/// A read whose answer had the wrong shape, or a file that couldn't be read, in words.
public sealed class ArtifactReadException(string message) : Exception(message);
