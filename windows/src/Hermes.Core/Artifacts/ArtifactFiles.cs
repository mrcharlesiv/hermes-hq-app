using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Gateways;
using Hermes.Core.Net;

namespace Hermes.Core.Artifacts;

/// How an artifact opens (`ArtifactFiles.Opening`). Text: the native viewer (Markdown with Preview | Source, code
/// monospaced); Html: Preview (the page live) | Source; Pdf: its pages drawn (Windows.Data.Pdf; the Mac's Quick Look);
/// Other: the file's own window with Open in Default App (the Mac's file window).
public enum ArtifactOpeningKind { Link, Image, Text, Html, Pdf, Other }

public sealed record ArtifactOpening(ArtifactOpeningKind Kind, bool Markdown = false, string? Language = null)
{
    public static readonly ArtifactOpening Link = new(ArtifactOpeningKind.Link), Image = new(ArtifactOpeningKind.Image),
        Html = new(ArtifactOpeningKind.Html), Pdf = new(ArtifactOpeningKind.Pdf), Other = new(ArtifactOpeningKind.Other);
}

/// Reading an artifact's bytes from the gateway (docs/spec/1x-pages.md §5.2, §5.6; HermesKit/Pages/ArtifactFiles.swift):
/// image previews through `/api/fs/read-data-url`, files through `/api/fs/download`, both with the artifact's
/// `session_id` and profile; how each kind opens; and the failure words (`previewErrorText`).
public static class ArtifactFiles
{
    /// Text the native viewer opens (`S/bridge/fe-pages.ts:26-29`).
    public static readonly HashSet<string> TextExtensions =
    [
        "md", "markdown", "mdx", "txt", "text", "log", "json", "jsonl", "yaml", "yml", "toml", "ini", "cfg", "conf", "xml", "py",
        "js", "mjs", "cjs", "ts", "tsx", "jsx", "sh", "zsh", "bash", "swift", "rb", "go", "rs", "java", "kt", "c", "h", "cc",
        "cpp", "hpp", "css", "scss", "sql",
    ];
    public static readonly HashSet<string> MarkdownExtensions = ["md", "markdown", "mdx"];
    /// The native text viewer reads files up to 2 MiB; bigger ones open in their own window.
    public const int TextLimit = 2 << 20;
    /// The REST ceiling (D-P9).
    public const int FileLimit = 32 << 20;
    public static string TooLargeText => $"This file is too large to open on this {DeviceWord.Name}.";

    public static string FileExtension(string value)
    {
        var name = ArtifactCollector.Label(value, ArtifactKind.File);
        var q = name.IndexOf('?');
        if (q >= 0) name = name[..q];
        var dot = name.LastIndexOf('.');
        return dot <= 0 ? "" : name[(dot + 1)..].ToLowerInvariant();
    }

    public static ArtifactOpening Opening(ArtifactRecord record)
    {
        if (record.Kind == ArtifactKind.Link) return ArtifactOpening.Link;
        if (record.Kind == ArtifactKind.Image) return ArtifactOpening.Image;
        var ext = FileExtension(record.Value);
        if (ext is "html" or "htm") return ArtifactOpening.Html;
        if (TextExtensions.Contains(ext)) return new ArtifactOpening(ArtifactOpeningKind.Text, MarkdownExtensions.Contains(ext), Language(ext));
        return ext == "pdf" ? ArtifactOpening.Pdf : ArtifactOpening.Other;
    }

    /// A downloaded text file opens in the native viewer up to `TextLimit`; a bigger one (a 3 MiB log) in its own window.
    public static bool OpensAsText(ArtifactOpening opening, long bytes) => opening.Kind == ArtifactOpeningKind.Text && bytes <= TextLimit;

    /// The highlighter's language tag for a code file (null = plain).
    public static string? Language(string ext) => ext switch
    {
        "md" or "markdown" or "mdx" or "txt" or "text" or "log" => null,
        "yml" => "yaml",
        "mjs" or "cjs" => "js",
        "zsh" or "bash" => "sh",
        "cc" or "cpp" or "hpp" or "h" => "cpp",
        "jsonl" => "json",
        _ => ext,
    };

    /// A hosted image (named by its http(s) URL rather than a gateway path).
    public static bool IsHosted(ArtifactRecord record)
    {
        var value = record.Value.ToLowerInvariant();
        return value.StartsWith("http://", StringComparison.Ordinal) || value.StartsWith("https://", StringComparison.Ordinal);
    }

    /// The gateway can serve it (http(s) and data URLs are not gateway files).
    public static bool IsGatewayFile(ArtifactRecord record) => !(IsHosted(record) || record.Value.StartsWith("data:", StringComparison.Ordinal));

    public static List<KeyValuePair<string, string>> Query(ArtifactRecord record)
    {
        var items = new List<KeyValuePair<string, string>> { new("path", record.Value), new("session_id", record.SessionId) };
        if (!string.IsNullOrEmpty(record.Profile)) items.Add(new("profile", record.Profile));
        return items;
    }

    public static byte[] DecodeDataUrl(string value)
    {
        var comma = value.IndexOf(',');
        if (comma < 0) throw new ArtifactReadException("This image could not be read.");
        var header = value[..comma];
        var payload = value[(comma + 1)..];
        if (header.EndsWith(";base64", StringComparison.Ordinal))
        {
            try { return Convert.FromBase64String(Regex.Replace(payload, "[^A-Za-z0-9+/=]", "")); }
            catch (FormatException) { throw new ArtifactReadException("This image could not be read."); }
        }
        return Encoding.UTF8.GetBytes(ArtifactCollector.PercentDecode(payload) ?? payload);
    }

    /// The HTML Preview's copy of a page with no viewport tag gets one (`width=device-width`); null when the page has its
    /// own (or isn't UTF-8): the file itself is previewed then.
    public static byte[]? PreviewHtml(byte[] data)
    {
        string html;
        try { html = new UTF8Encoding(false, true).GetString(data); } catch (DecoderFallbackException) { return null; }
        if (Regex.IsMatch(html, """<meta[^>]*name\s*=\s*["']?viewport""", RegexOptions.IgnoreCase)) return null;
        const string meta = """<meta name="viewport" content="width=device-width, initial-scale=1">""";
        string out_;
        if (Regex.Match(html, """<head(\s[^>]*)?>""", RegexOptions.IgnoreCase) is { Success: true } head)
            out_ = html.Insert(head.Index + head.Length, meta);
        else if (Regex.Match(html, """<html(\s[^>]*)?>""", RegexOptions.IgnoreCase) is { Success: true } root)
            out_ = html.Insert(root.Index + root.Length, $"<head>{meta}</head>");
        else
            out_ = meta + html;
        return Encoding.UTF8.GetBytes(out_);
    }

    /// Where a downloaded file is kept: &lt;root&gt;/&lt;hash&gt;/&lt;file name&gt; (`previewURL`).
    public static string PreviewPath(string root, ArtifactRecord record)
    {
        var digest = System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes($"{record.Profile ?? ""}|{record.SessionId}|{record.Value}"));
        var hash = Convert.ToHexStringLower(digest.AsSpan(0, 10));
        var name = record.Label.Length == 0 ? "file" : record.Label;
        foreach (var bad in Path.GetInvalidFileNameChars().Concat(['/', '\\', ':', '*', '?', '"', '<', '>', '|'])) name = name.Replace(bad, '_');
        return Path.Combine(root, hash, name);
    }

    /// Where the HTML Preview's copy goes: beside the file, so its relative links and images still resolve.
    public static string PreviewCopyPath(string path) => Path.Combine(Path.GetDirectoryName(path) ?? "", "preview-" + Path.GetFileName(path));

    // ---- failure words

    public static int? Status(Exception error) => error is GatewayException { Code: "http" } g ? g.Status : null;

    /// `detail` of an HTTP error body (a string, or an object's `message`); null when there is none (PagesREST.detail).
    public static string? Detail(string? body)
    {
        if (J.Parse(body ?? "") is not { } value)
        {
            var text = body?.Trim() ?? "";
            return text.Length == 0 || text.StartsWith('<') || text.Length > 300 ? null : text;
        }
        if (value.Get("detail") is { } detail)
        {
            if (ArtifactSessionRow.Str(detail) is { Length: > 0 } t) return t;
            if (detail.Str("message") is { Length: > 0 } m) return m;
            return null;
        }
        return value.Str("error") is { Length: > 0 } e ? e : null;
    }

    /// The file is gone or can't be placed (it goes to Unavailable): 404, a relative path without a folder, a bad path.
    public static bool IsMissing(Exception error) => Status(error) is 404 or 400;

    /// The link, not the file: no network, the gateway not answering, a 429 or 5xx. A tile that failed this way is
    /// asked again when the page shows again; a refusal or a bad file is not.
    public static bool IsTransient(Exception error)
    {
        if (error is OperationCanceledException) return true;
        if (error is GatewayException g)
        {
            if (g.Code is "timeout" or "offline" or "rate-limited") return true;
            if (g.Code == "http") return g.Status is 429 or >= 500 and <= 599;
        }
        return error is HttpRequestException;
    }

    private static string TookTooLong => $"{HostWord.Sentence} took too long to answer. Try again in a moment.";
    public static string CantReach => $"Can’t reach {HostWord.Phrase}. Check that it’s on, and that Tailscale is on here too if you use it.";

    /// Why a file couldn't open, in words.
    public static string FailureText(Exception error, bool image)
    {
        if (error is RemoteImageRefusedException refused) return refused.Message;
        if (error is GatewayException g)
        {
            switch (g.Code)
            {
                case "too-large": return image ? "This image is too large to preview." : TooLargeText;
                case "timeout": return TookTooLong;
                case "offline": return CantReach;
                case "http":
                    var detail = Detail(g.Body) ?? "";
                    return g.Status switch
                    {
                        404 => $"This file is no longer on {HostWord.Phrase}. It may have been moved or deleted.",
                        403 => $"{HostWord.Sentence} does not allow reading this file.",
                        413 => image ? "This image is too large to preview." : TooLargeText,
                        400 => detail.Contains("working directory is unavailable", StringComparison.OrdinalIgnoreCase)
                            ? "From an older session whose folder is unknown." : "The gateway can't open this file path.",
                        502 or 503 or 504 or 524 => TookTooLong,
                        _ => detail.Length == 0 ? "This file could not be read." : detail,
                    };
                default: return g.Message;
            }
        }
        if (error is TimeoutException or TaskCanceledException) return TookTooLong;
        if (error is HttpRequestException) return CantReach;
        return error.Message;
    }

    /// A page's whole failure (PagesREST.reason): an unknown route is an older Hermes, else the gateway's own words.
    public static string Reason(Exception error)
    {
        if (error is GatewayException { Code: "http" } http)
        {
            var detail = Detail(http.Body);
            if (http.Status is 404 or 405 && (detail == null || detail.Trim().ToLowerInvariant() is "not found" or "method not allowed"))
                return "Not available on this Hermes. Updating Hermes may add it.";
            return detail ?? "The gateway couldn’t do that.";
        }
        if (error is GatewayException { Code: "timeout" or "offline" }) return CantReach;
        if (error is OperationCanceledException) return "Cancelled.";
        return error.Message.Length > 0 ? error.Message : "The gateway couldn’t do that.";
    }
}

/// A picture on another site that wasn't fetched (http, a private host, not an image, too large): the tile offers Open.
public sealed class RemoteImageRefusedException(string reason)
    : Exception($"This image is on another site and couldn’t be shown here. {DeviceWord.TapCap} Open to view it.")
{
    public string Reason { get; } = reason;
}
