// [preview-tab] A bot's Browser tab (`desktop_preview` tool): pure target parsing, loopback detection,
// URL matching, site label, and windowed `preview.read` answer formatting. C# twin of App/Browser/PreviewTab.swift.

using System.Text;
using System.Text.Json;
using Hermes.Core.Gateways;

namespace Hermes.Core.Browser;

public abstract record PreviewTarget
{
    private PreviewTarget() { }

    public sealed record Page(Uri Url) : PreviewTarget;
    public sealed record File(string Path) : PreviewTarget;
    /// A page on the bot's own computer (localhost), which this PC can't reach.
    public sealed record Unreachable(string Address) : PreviewTarget;

    public static PreviewTarget Parse(string raw)
    {
        var value = raw.Trim().Trim('`').Trim();
        if (value.StartsWith('/') || value.StartsWith('~')) return new File(value);
        if (value.StartsWith("file://", StringComparison.OrdinalIgnoreCase) &&
            Uri.TryCreate(value, UriKind.Absolute, out var fileUri))
            return new File(fileUri.AbsolutePath);

        var text = value;
        if (!text.Contains("://", StringComparison.Ordinal))
            text = (IsLoopback(text) ? "http://" : "https://") + text;

        if (!Uri.TryCreate(text, UriKind.Absolute, out var url) ||
            (url.Scheme.ToLowerInvariant() is not ("http" or "https")) ||
            string.IsNullOrEmpty(url.Host))
            return new Unreachable(value);

        return IsLoopback(url.Host) ? new Unreachable(value) : new Page(url);
    }

    public static bool IsLoopback(string text)
    {
        var lower = text.ToLowerInvariant();
        var slash = lower.IndexOf('/');
        var host = slash >= 0 ? lower[..slash] : lower;
        var bare = host.StartsWith('[') ? host : (host.Split(':')[0]);
        return bare is "localhost" or "127.0.0.1" or "0.0.0.0" or "[::1]" or "::1"
            || bare.StartsWith("[::1]", StringComparison.Ordinal)
            || bare.EndsWith(".localhost", StringComparison.Ordinal);
    }

    public static string UnreachableNotice(string address, string bot) =>
        $"{bot} opened {address}, a page on its own computer. It can’t be shown on this {DeviceWord.Name}.";
}

public sealed record PreviewPage(string Url, string Title, string Text);

public static class PreviewTabRules
{
    public const int MaxChars = 24_000;

    /// Desktop's `preview.read` answer for one page, windowed by `start`/`count` (at most 24,000 characters).
    public static string Answer(PreviewPage page, int? start, int? count)
    {
        var total = page.Text.Length;
        var from = Math.Max(0, Math.Min(start ?? 0, total));
        var want = Math.Min(Math.Max(1, count ?? MaxChars), MaxChars);
        var to = Math.Max(from, Math.Min(from + want, total));
        var slice = page.Text[from..to];

        using var ms = new MemoryStream();
        using (var w = new Utf8JsonWriter(ms))
        {
            w.WriteStartObject();
            w.WriteNumber("end", to);
            w.WriteString("kind", "url");
            w.WriteNumber("start", from);
            w.WriteString("text", slice);
            w.WriteString("title", page.Title);
            w.WriteNumber("total_chars", total);
            w.WriteString("url", page.Url);
            w.WriteEndObject();
        }
        return Encoding.UTF8.GetString(ms.ToArray());
    }

    public static string Site(Uri url)
    {
        var host = string.IsNullOrEmpty(url.Host) ? url.AbsoluteUri : url.Host;
        return host.StartsWith("www.", StringComparison.OrdinalIgnoreCase) ? host[4..] : host;
    }

    public static bool SameUrl(Uri a, Uri b) =>
        string.Equals(a.Host, b.Host, StringComparison.OrdinalIgnoreCase) &&
        string.Equals(a.AbsolutePath.Trim('/'), b.AbsolutePath.Trim('/'), StringComparison.Ordinal);

    public static bool Matches(Uri current, string address) =>
        PreviewTarget.Parse(address) is PreviewTarget.Page other && SameUrl(other.Url, current);
}
