using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using Hermes.Core.Gateways;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Settings;

/// Settings › About › Detailed Logging (App/Settings/AboutView.swift; HermesKit/Diagnostics/DiagnosticLog.swift
/// `AppLog.detailed`, `setDetailed`, `trace`). Default on, kept on this PC under the Mac's key, no auto-off. On, the
/// app log gains a line for every gateway request (route, answer, size, time; a failure's own words, redacted). Off,
/// those lines are not even built. Never in a line: a token, cookie, password, message text, gateway host or raw id.
public static class DetailedLogging
{
    public const string Key = "hqn.log.detailed";
    public const string Title = "Detailed Logging";
    public static string Note => $"Every request, reply step and send, in this {DeviceWord.Name}’s log, so problems can be traced afterwards.";

    private static volatile bool _enabled = true;
    private static Action<string, string>? _sink;

    /// Whether trace lines are written. Read once from the preferences at launch (`Start`), then kept here: `Trace` runs
    /// on every request.
    public static bool Enabled => _enabled;

    /// The stored choice (default on: no value, or anything but "false").
    public static bool Load(IPreferences prefs) => prefs.Get(Key) != "false";

    /// At launch: reads the switch and sends trace lines to `sink` (the app log). Returns the launch line that says
    /// whether this log is whole ("logging: detailed on").
    public static string Start(IPreferences prefs, Action<string, string> sink)
    {
        _sink = sink;
        _enabled = Load(prefs);
        return $"logging: detailed {(_enabled ? "on" : "off")}";
    }

    /// The switch: saved, applied at once, and noted (always, as the Mac notes it: "detailed logging off").
    public static void Set(IPreferences prefs, bool on, Action<string, string>? note = null)
    {
        prefs.Set(Key, on ? "true" : "false");
        _enabled = on;
        (note ?? _sink)?.Invoke("settings", $"detailed logging {(on ? "on" : "off")}");
    }

    /// A detailed line: written only while Detailed Logging is on, and the message is not even built otherwise. The
    /// line is passed through `Logged` (hosts and ids tagged) on its way out.
    public static void Trace(string category, Func<string> message)
    {
        if (!_enabled || _sink is not { } sink) return;
        string line;
        try { line = Logged(message()); }
        catch (Exception) { return; }   // a log line never breaks the work it describes
        try { sink(category, line); } catch (Exception) { }
    }

    /// Tests: no sink, back to the default.
    internal static void Reset() { _sink = null; _enabled = true; }

    // ---------------------------------------------------------------- the request line (HTTPTransport.swift `data`)

    /// "GET /api/sessions/#3fa9b2/messages?… → 200, 512 B, 41 ms"; an error status adds the body's first 300
    /// characters, redacted.
    public static string RequestLine(string method, Uri url, bool control, int status, long bytes, long ms, string? errorBody)
    {
        var line = $"{Route(method, url, control)} → {status}, {bytes} B, {ms} ms";
        if (status >= 400 && errorBody != null) line += ": " + Scrub(errorBody.Length > 300 ? errorBody[..300] : errorBody);
        return line;
    }

    /// "POST /api/chat (control) → failed after 15003 ms: <the failure's own words, redacted>".
    public static string FailureLine(string method, Uri url, bool control, long ms, string failure) =>
        $"{Route(method, url, control)} → failed after {ms} ms: {Scrub(failure)}";

    private static string Route(string method, Uri url, bool control) => $"{method} {Path(url)}{(control ? " (control)" : "")}";

    // ---------------------------------------------------------------- redaction (DiagnosticLog.swift `AppLog`)

    /// A short stable tag for an id (chat, session, message, job): `#` + 6 hex of its SHA-256, never the id itself.
    /// Null or empty reads `#-`. The same id gives the same tag as on the Mac and the gateway's computer.
    public static string Tag(string? id)
    {
        if (string.IsNullOrEmpty(id)) return "#-";
        var digest = SHA256.HashData(Encoding.UTF8.GetBytes(id));
        return "#" + Convert.ToHexString(digest, 0, 3).ToLowerInvariant();
    }

    /// A URL path with ids swapped for tags and the query dropped: `/api/sessions/#3fa9b2/messages?…`.
    public static string Path(Uri? url)
    {
        if (url == null) return "?";
        var parts = url.AbsolutePath.Split('/').Select(s => LooksLikeId(s) ? Tag(Uri.UnescapeDataString(s)) : s);
        return string.Join('/', parts) + (url.Query.Length > 0 ? "?…" : "");
    }

    /// A path part that is an id or a user-chosen name rather than a fixed route word.
    public static bool LooksLikeId(string s)
    {
        if (s.Length == 0 || s.Length > 40) return s.Length > 0;
        if (s.Contains('%') || s.Contains('.') && s.Length > 12) return true;
        var digits = s.Count(char.IsDigit);
        if (digits >= 3) return true;
        if (s.Length >= 16 && (digits > 0 || s.Contains('_'))) return true;
        return s.Any(char.IsUpper) && s.Length >= 8;
    }

    /// Gateway or error words made safe for the log: the redactor, then every URL's host and every id-like word tagged.
    public static string Scrub(string text) => TagIds(TagHosts(DiagnosticRedactor.Redact(text)));

    /// A line as the log keeps it: every URL's host tagged and every id-like word.
    public static string Logged(string message) => TagIds(TagHosts(message));

    private static readonly Regex UrlHost = new(
        @"\b([a-z][a-z0-9+.-]{0,31}://)(?:[^\s/?#@""'<>]*@)?(\[[0-9a-f:.]+\]|[^\s/?#:""'<>,;)\]}]+)(:\d+)?",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    /// Every `scheme://host[:port]` written `scheme://#tag`, port (and any user info) dropped.
    public static string TagHosts(string text)
    {
        if (!text.Contains("://")) return text;
        return UrlHost.Replace(text, m =>
        {
            var host = m.Groups[2].Value;
            return host.StartsWith('#') ? m.Value : m.Groups[1].Value + Tag(host.ToLowerInvariant());
        });
    }

    private static readonly Regex IdWord = new(
        @"\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b|(?<![#\w])[A-Za-z0-9_]{8,}",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    /// Every id-like word (a UUID, or 8+ letters/digits/underscores with 3+ digits: "20251027_101010_ab12cd") swapped for
    /// its tag. Model names ("gpt-4o-2024-08-06") and counts survive.
    public static string TagIds(string text)
    {
        if (Encoding.UTF8.GetByteCount(text) < 8) return text;
        return IdWord.Replace(text, m =>
        {
            var word = m.Value;
            var digits = word.Count(char.IsDigit);
            var isId = word.Contains('-') || digits >= 3 && (word.Any(char.IsLetter) || word.Length >= 14);
            return isId ? Tag(word) : word;
        });
    }
}
