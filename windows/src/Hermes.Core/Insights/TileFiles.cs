using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Gateways;
using Hermes.Core.Net;

namespace Hermes.Core.Insights;

/// Reading a tile's bytes from the gateway (HermesKit/Pages/ArtifactFiles.swift): pictures through
/// `/api/fs/read-data-url`, files through `/api/fs/download`, both with the pin's `session_id` and profile; how each
/// kind opens; and the failure words.
public static partial class TileFiles
{
    public static readonly HashSet<string> TextExtensions =
    [
        "md", "markdown", "mdx", "txt", "text", "log", "json", "jsonl", "yaml", "yml", "toml", "ini", "cfg", "conf", "xml", "py", "js",
        "mjs", "cjs", "ts", "tsx", "jsx", "sh", "zsh", "bash", "swift", "rb", "go", "rs", "java", "kt", "c", "h", "cc", "cpp", "hpp",
        "css", "scss", "sql",
    ];
    public static readonly HashSet<string> MarkdownExtensions = ["md", "markdown", "mdx"];
    /// The text viewer reads files up to 2 MiB.
    public const int TextLimit = 2 << 20;

    public enum Opening { Link, Image, Text, Markdown, Html, Other }

    /// The last path part of a value (`ArtifactCollector.label`).
    public static string Label(string value, TileKind kind)
    {
        if (value.StartsWith("data:")) return "Image";
        if (value.StartsWith("http://") || value.StartsWith("https://"))
        {
            if (!Uri.TryCreate(value, UriKind.Absolute, out var u)) return value;
            var last = Uri.UnescapeDataString(u.AbsolutePath).Split('/').LastOrDefault(s => s.Length > 0) ?? "";
            if (FileNameRx().IsMatch(last)) return last;
            return kind == TileKind.Link ? u.Host : last.Length > 0 ? last : value;
        }
        var path = value;
        if (path.StartsWith("file://") && Uri.TryCreate(path, UriKind.Absolute, out var f)) path = Uri.UnescapeDataString(f.AbsolutePath);
        return path.Split('/', '\\').LastOrDefault(s => s.Length > 0) ?? value;
    }

    public static string Extension(string value)
    {
        var name = Label(value, TileKind.File);
        var q = name.IndexOf('?');
        if (q >= 0) name = name[..q];
        var dot = name.LastIndexOf('.');
        return dot <= 0 ? "" : name[(dot + 1)..].ToLowerInvariant();
    }

    public static Opening OpeningOf(TilePin pin)
    {
        if (pin.Kind == TileKind.Link) return Opening.Link;
        if (pin.Kind == TileKind.Image) return Opening.Image;
        var ext = Extension(pin.Value);
        if (ext is "html" or "htm") return Opening.Html;
        if (MarkdownExtensions.Contains(ext)) return Opening.Markdown;
        if (TextExtensions.Contains(ext)) return Opening.Text;
        return Opening.Other;
    }

    public static bool IsHosted(TilePin pin) => pin.Value.StartsWith("http://", StringComparison.OrdinalIgnoreCase)
        || pin.Value.StartsWith("https://", StringComparison.OrdinalIgnoreCase);

    public static bool IsGatewayFile(TilePin pin) => !(IsHosted(pin) || pin.Value.StartsWith("data:"));

    public static List<KeyValuePair<string, string>> Query(TilePin pin)
    {
        var q = new List<KeyValuePair<string, string>> { new("path", pin.Value) };
        if (pin.SessionId.Length > 0) q.Add(new("session_id", pin.SessionId));
        if (pin.Profile.Length > 0) q.Add(new("profile", pin.Profile));
        return q;
    }

    /// A page's or text file's words, whole (`/api/fs/download`; not `read-text`, which stops at 512 KB).
    public static async Task<string> TextAsync(GatewaySession session, TilePin pin, CancellationToken ct = default)
    {
        var a = await session.SendAsync(HttpMethod.Get, "/api/fs/download", Query(pin), timeout: TimeSpan.FromSeconds(120), ct: ct);
        if (!a.Ok) throw GatewayError(a);
        return a.Body;
    }

    /// Any file's bytes, through `read-data-url` (the shared session reads answers as text, which a binary download
    /// would not survive).
    public static async Task<byte[]> BytesAsync(GatewaySession session, TilePin pin, CancellationToken ct = default)
    {
        var json = await session.GetJsonAsync("/api/fs/read-data-url", Query(pin), TimeSpan.FromSeconds(120), ct);
        var url = json.Str("dataUrl") ?? json.Str("data_url") ?? throw new PagesMessageException("This file could not be read.");
        return DecodeDataUrl(url);
    }

    /// An image's bytes: a data URL as is; a gateway file through `read-data-url`. A hosted image is not fetched with
    /// the gateway's credentials (the caller loads it from its own address).
    public static async Task<byte[]> ImageAsync(GatewaySession session, TilePin pin, CancellationToken ct = default)
    {
        if (pin.Value.StartsWith("data:")) return DecodeDataUrl(pin.Value);
        var json = await session.GetJsonAsync("/api/fs/read-data-url", Query(pin), TimeSpan.FromSeconds(60), ct);
        var url = json.Str("dataUrl") ?? json.Str("data_url") ?? throw new PagesMessageException("This image could not be read.");
        return DecodeDataUrl(url);
    }

    public static byte[] DecodeDataUrl(string value)
    {
        var comma = value.IndexOf(',');
        if (comma < 0) throw new PagesMessageException("This image could not be read.");
        var header = value[..comma];
        var payload = value[(comma + 1)..];
        if (header.EndsWith(";base64"))
        {
            try { return Convert.FromBase64String(Regex.Replace(payload, @"[^A-Za-z0-9+/=]", "")); }
            catch (FormatException) { throw new PagesMessageException("This image could not be read."); }
        }
        return Encoding.UTF8.GetBytes(Uri.UnescapeDataString(payload));
    }

    private static GatewayException GatewayError(HttpAnswer a) =>
        new("http", $"The gateway answered {a.Status}.", a.Status, a.Body.Length > 65536 ? a.Body[..65536] : a.Body);

    /// A page with no viewport tag gets one (`previewHTML`); null when it has its own.
    public static string? WithViewport(string html)
    {
        if (ViewportRx().IsMatch(html)) return null;
        const string meta = "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">";
        if (HeadRx().Match(html) is { Success: true } head) return html.Insert(head.Index + head.Length, meta);
        if (HtmlRx().Match(html) is { Success: true } root) return html.Insert(root.Index + root.Length, "<head>" + meta + "</head>");
        return meta + html;
    }

    /// The file is gone or can't be placed: 404, a relative path without a folder, a bad path.
    public static bool IsMissing(Exception e) => e is GatewayException { Code: "http", Status: 404 or 400 };

    /// Why a file couldn't open, in words (`failureText`).
    public static string FailureText(Exception e, bool image)
    {
        var device = "PC";
        var tooLarge = $"This file is too large to open on this {device}.";
        var slow = $"{HostWord.Sentence} took too long to answer. Try again in a moment.";
        switch (e)
        {
            case PagesMessageException m: return m.Message;
            case GatewayException { Code: "timeout" }: return slow;
            case GatewayException { Code: "http" } h:
                var detail = InsightsWire.Detail(h.Body) ?? "";
                return h.Status switch
                {
                    404 => $"This file is no longer on {HostWord.Phrase}. It may have been moved or deleted.",
                    403 => $"{HostWord.Sentence} does not allow reading this file.",
                    413 => image ? "This image is too large to preview." : tooLarge,
                    400 when detail.Contains("working directory is unavailable", StringComparison.OrdinalIgnoreCase) => "From an older session whose folder is unknown.",
                    400 => "The gateway can't open this file path.",
                    502 or 503 or 504 or 524 => slow,
                    _ => detail.Length == 0 ? "This file could not be read." : detail,
                };
            default: return InsightsWire.Reason(e);
        }
    }

    [GeneratedRegex(@"^[^\\/]+\.[A-Za-z][A-Za-z0-9]{0,7}$")]
    private static partial Regex FileNameRx();
    [GeneratedRegex(@"<meta[^>]*name\s*=\s*[""']?viewport", RegexOptions.IgnoreCase)]
    private static partial Regex ViewportRx();
    [GeneratedRegex(@"<head(\s[^>]*)?>", RegexOptions.IgnoreCase)]
    private static partial Regex HeadRx();
    [GeneratedRegex(@"<html(\s[^>]*)?>", RegexOptions.IgnoreCase)]
    private static partial Regex HtmlRx();
}
