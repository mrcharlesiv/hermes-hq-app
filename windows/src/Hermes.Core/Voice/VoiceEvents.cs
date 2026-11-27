using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace Hermes.Core.Voice;

// Port of HermesKit/Voice/VoiceEvents.swift: bounded diagnostic ring buffer for voice sessions
// (memos, dictation, talk) with strict secret/PII scrubbing before anything reaches Copy Details.

public sealed record VoiceEvent(double At, string Line);

public static class VoiceReport
{
    public const string Header = "Voice log";

    private static readonly Regex BearerRe = new(@"(?i)\b(bearer\s+)[A-Za-z0-9._\-~+/]+=*", RegexOptions.CultureInvariant);
    private static readonly Regex QuerySecretRe = new(@"(?i)([?&](?:ticket|token|access_token|api_key|key|secret|auth|session)=)[^&\s""']+", RegexOptions.CultureInvariant);
    private static readonly Regex JsonSecretRe = new(@"(?i)(""(?:token|access_token|refresh_token|api_key|secret|authorization|cookie|ticket|client_secret)""\s*:\s*"")[^""]*("")", RegexOptions.CultureInvariant);
    private static readonly Regex KeyPrefixRe = new(@"\b(?:sk|xai|pk|rk|ghp|gho|pat)-[A-Za-z0-9_\-]{12,}\b", RegexOptions.CultureInvariant);
    private static readonly Regex DataUrlRe = new(@"data:[a-zA-Z0-9/+.\-]+;base64,[A-Za-z0-9+/=\s]{24,}", RegexOptions.CultureInvariant);
    private static readonly Regex EmailRe = new(@"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b", RegexOptions.CultureInvariant);
    private static readonly Regex CookieHeaderRe = new(@"(?i)(cookie\s*:\s*)[^\r\n]+", RegexOptions.CultureInvariant);

    /// Redacts tokens, query tickets, base64 audio payloads, cookies, and emails before logging or copying.
    public static string Scrub(string text)
    {
        if (string.IsNullOrEmpty(text)) return "";
        var s = BearerRe.Replace(text, "$1[redacted]");
        s = QuerySecretRe.Replace(s, "$1[redacted]");
        s = JsonSecretRe.Replace(s, "$1[redacted]$2");
        s = KeyPrefixRe.Replace(s, "[redacted-key]");
        s = DataUrlRe.Replace(s, "data:[redacted]");
        s = CookieHeaderRe.Replace(s, "$1[redacted]");
        s = EmailRe.Replace(s, "[redacted-email]");
        return s.Replace('\r', ' ').Replace('\n', ' ').Trim();
    }

    public static string Line(double atSeconds, string line)
    {
        var stamp = DateTimeOffset.FromUnixTimeMilliseconds((long)(atSeconds * 1000))
            .ToUniversalTime()
            .ToString("HH:mm:ss.fff", CultureInfo.InvariantCulture);
        return $"{stamp} {Scrub(line)}";
    }

    public static string Text(IReadOnlyList<VoiceEvent> events)
    {
        if (events.Count == 0) return "";
        var sb = new StringBuilder();
        sb.AppendLine(Header);
        foreach (var e in events) sb.AppendLine(Line(e.At, e.Line));
        return sb.ToString().TrimEnd();
    }

    public static bool Holds(string? text) =>
        !string.IsNullOrEmpty(text) && text.Contains(Header, StringComparison.Ordinal);

    public static int Size(string? text) => string.IsNullOrEmpty(text) ? 0 : Encoding.UTF8.GetByteCount(text);
}

public sealed class VoiceEvents
{
    public static readonly VoiceEvents Shared = new();

    public const int DefaultCapacity = 200;

    private readonly object _gate = new();
    private readonly List<VoiceEvent> _items = [];
    private readonly int _capacity;
    private readonly Func<double> _nowSeconds;

    public VoiceEvents(int capacity = DefaultCapacity, Func<double>? nowSeconds = null)
    {
        _capacity = Math.Max(1, capacity);
        _nowSeconds = nowSeconds ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0);
    }

    public void Record(string line)
    {
        var clean = VoiceReport.Scrub(line);
        if (clean.Length == 0) return;
        var item = new VoiceEvent(_nowSeconds(), clean);
        lock (_gate)
        {
            _items.Add(item);
            if (_items.Count > _capacity) _items.RemoveRange(0, _items.Count - _capacity);
        }
    }

    public IReadOnlyList<VoiceEvent> Snapshot()
    {
        lock (_gate) return [.. _items];
    }

    public void Clear()
    {
        lock (_gate) _items.Clear();
    }

    public string Text => VoiceReport.Text(Snapshot());
}
