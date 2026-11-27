// [WIN-SCREEN-SHOT-FEED] A bot's newest computer_use or browser screenshot, updated live (docs/spec/3x-screen.md §5.2,
// §5.14): what the Screen shows when the gateway has no live screen. The C# twin of the Mac's
// HermesKit/Screen/ScreenshotFeed.swift at 93f984bb1. The pure rules are the web's `bot-activity-model.ts`, ported one
// for one; `ScreenshotFeed` is the model of one open fallback view.
//
// The Mac's @MainActor is the SynchronizationContext the feed (and its poller) is created on (the UI thread), as for
// ScreenSession: make it there and call it only there. The gateway's events may arrive on any thread; they are posted
// to that context (the Swift `for await` on the main actor). The gateway is IScreenshotGateway; the live app hands in
// `ClientScreenGateway`. GatewayEvent is RpcEvent; HTTPError is GatewayException ("http" + Status). Swift's
// `Locale`/`TimeZone`/`DateFormatter` are CultureInfo/TimeZoneInfo (see ShotAge). No pictures are decoded here: the
// view loads `Shot.Src` and reports back with Loaded/LoadFailed, as the Swift view does.

using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using Hermes.Core.Gateways;
using Hermes.Core.Net;
using Hermes.Core.Rpc;

namespace Hermes.Core.Screen;

/// What a ScreenshotFeed asks of its gateway: REST with a query, and the gateway's events of some types.
public interface IScreenshotGateway : IScreenshotRest
{
    /// The gateway's events whose type is in `types` (the Swift `events(matching:)`), on any thread, until disposed.
    IDisposable RpcEvents(IReadOnlySet<string> types, Action<RpcEvent> handler);
}

public sealed record ScreenShot(string Id, string Src, string Caption, double? At)
{
    // `Src`: a gateway path or a `data:image/…` URL. `At`: unix seconds; null when the row carried no time.
}

public enum ScreenHostKind { Mac, Windows }

public sealed record RecentScreenSession(string Id, double Active, string? Cwd = null);

public static class ScreenshotRules
{
    private static readonly Dictionary<string, string> Actions = new(StringComparer.Ordinal)
    {
        ["capture"] = "Looked at the screen", ["screenshot"] = "Looked at the screen",
        ["click"] = "Clicked", ["left_click"] = "Clicked", ["double_click"] = "Double-clicked", ["right_click"] = "Right-clicked",
        ["middle_click"] = "Clicked", ["type"] = "Typed", ["key"] = "Pressed keys", ["hotkey"] = "Pressed keys",
        ["press_key"] = "Pressed keys", ["scroll"] = "Scrolled", ["drag"] = "Dragged", ["move"] = "Moved the pointer",
        ["mouse_move"] = "Moved the pointer", ["zoom"] = "Zoomed in", ["wait"] = "Waited",
    };

    private static readonly Dictionary<string, string> Browser = new(StringComparer.Ordinal)
    {
        ["browser_vision"] = "Looked at the page", ["browser_screenshot"] = "Looked at the page",
        ["browser_click"] = "Clicked in the browser", ["browser_type"] = "Typed in the browser",
        ["browser_scroll"] = "Scrolled the page", ["browser_snapshot"] = "Read the page", ["browser_back"] = "Went back",
    };

    /// Tool arguments arrive as an object, or as the JSON text of one.
    public static JsonObject Arguments(JsonNode? args) => args switch
    {
        JsonObject record => record,
        _ when ToolScreenshots.AsText(args) is { } text => ToolScreenshots.ParseJson(text) as JsonObject ?? [],
        _ => [],
    };

    /// What the bot did, in plain words ("Clicked in Safari", "Opened example.com").
    public static string ShotCaption(string tool, JsonNode? args)
    {
        var record = Arguments(args);
        if (tool.StartsWith("computer_use", StringComparison.Ordinal))
        {
            var action = (ToolScreenshots.AsText(record.Get("action")) ?? "").ToLowerInvariant();
            var did = Actions.GetValueOrDefault(action) ?? "Used the computer";
            if (ToolScreenshots.AsText(record.Get("app")) is { Length: > 0 } app) return $"{did} in {app}";
            return did;
        }
        if (tool == "browser_navigate")
        {
            // The web's `new URL(url).host`: the host as written, with its port when it names one.
            if (ToolScreenshots.AsText(record.Get("url")) is { } url && Host(url) is { } host) return $"Opened {host}";
            return "Opened a page";
        }
        return Browser.GetValueOrDefault(tool) ?? "Used the browser";
    }

    /// Swift `URLComponents(string:)` with a scheme and a host: the host lowercased, then ":<port>" when the URL
    /// writes one (URLComponents keeps an explicit default port too, so the authority is read as written; System.Uri
    /// alone would drop it). A URL without a `//` authority has no host, as URLComponents has none.
    private static string? Host(string url)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) || uri.Scheme.Length == 0 || uri.Host.Length == 0) return null;
        var marker = url.IndexOf("://", StringComparison.Ordinal);
        if (marker <= 0) return null;
        var authority = url[(marker + 3)..];
        var end = authority.IndexOfAny(['/', '?', '#']);
        if (end >= 0) authority = authority[..end];
        var at = authority.LastIndexOf('@');
        if (at >= 0) authority = authority[(at + 1)..];
        var colon = authority.LastIndexOf(':');
        string? port = null;
        if (colon >= 0 && colon > authority.LastIndexOf(']') && authority[(colon + 1)..] is { Length: > 0 } digits && digits.All(char.IsAsciiDigit))
            port = int.Parse(digits, CultureInfo.InvariantCulture).ToString(CultureInfo.InvariantCulture);
        var host = uri.Host.ToLowerInvariant();
        return port == null ? host : $"{host}:{port}";
    }

    /// The arguments of each tool call in the rows, by call id (assistant rows' `tool_calls[].function.arguments`).
    public static Dictionary<string, JsonNode?> CallArgs(IReadOnlyList<JsonNode?> rows)
    {
        var found = new Dictionary<string, JsonNode?>(StringComparer.Ordinal);
        foreach (var row in rows)
        {
            foreach (var call in row.Arr("tool_calls") ?? [])
            {
                if (ToolScreenshots.AsText(call.Get("id")) is not { Length: > 0 } id) continue;
                if (call.Get("function") is not JsonObject function || !function.ContainsKey("arguments")) continue;
                // Swift `call["function"]?["arguments"]` is nil for a JSON null too.
                if (function["arguments"] is not { } args) continue;
                found[id] = args;
            }
        }
        return found;
    }

    /// The newest stored screenshot in a page of stored rows, null when there is none. The gateway pages rows in
    /// chronological order (an `order=latest` page is the newest rows, oldest of them first), so the newest is the
    /// last one that qualifies.
    public static ScreenShot? LatestShot(IReadOnlyList<JsonNode?> rows)
    {
        var args = CallArgs(rows);
        for (var index = rows.Count - 1; index >= 0; index--)
        {
            var row = rows[index];
            if (ToolScreenshots.AsText(row.Get("role")) != "tool") continue;
            var tool = ToolScreenshots.AsText(row.Get("tool_name")) is { Length: > 0 } named ? named : ToolScreenshots.AsText(row.Get("name")) ?? "";
            if (!ToolScreenshots.IsScreenshotTool(tool)) continue;
            var src = ToolScreenshots.StoredScreenshot(row.Get("content"));
            if (src.Length == 0) continue;
            var at = ToolScreenshots.AsNumber(row.Get("timestamp"));
            var callId = ToolScreenshots.AsText(row.Get("tool_call_id")) is { Length: > 0 } c ? c : null;
            var id = callId ?? $"{tool}-{(at is { } t ? Stamp(t) : index.ToString(CultureInfo.InvariantCulture))}";
            var own = row.Get("args");
            var shotArgs = own ?? (callId != null && args.TryGetValue(callId, out var a) ? a : null);
            return new ScreenShot(id, src, ShotCaption(tool, shotArgs), at);
        }
        return null;
    }

    /// The screenshot of a live `tool.complete` payload, null when it carries none.
    public static ScreenShot? LiveShot(JsonNode? payload, double now)
    {
        if (ToolScreenshots.AsText(payload.Get("name")) is not { } tool || !ToolScreenshots.IsScreenshotTool(tool)) return null;
        var src = ToolScreenshots.LiveSource(payload.Get("result"), ToolScreenshots.AsText(payload.Get("result_text")),
            ToolScreenshots.AsText(payload.Get("summary")));
        if (src.Length == 0) return null;
        var id = ToolScreenshots.AsText(payload.Get("tool_id")) is { Length: > 0 } t ? t : $"{tool}-{Stamp(now)}";
        return new ScreenShot(id, src, ShotCaption(tool, payload.Get("args")), now);
    }

    /// Swift `String(Int64(value))`, else `String(value)` (shortest round-trip, lowercase exponent).
    private static string Stamp(double value) =>
        Math.Round(value, MidpointRounding.AwayFromZero) == value && Math.Abs(value) < 9e15
            ? ((long)value).ToString(CultureInfo.InvariantCulture)
            : value.ToString("R", CultureInfo.InvariantCulture).Replace('E', 'e');

    /// "just now", "12 s ago", "3 min ago", "2 h ago", else a short date. "" without a time.
    /// Swift `DateFormatter.setLocalizedDateFormatFromTemplate("MMMd")`: the culture's month-day pattern with its month
    /// abbreviated ("MMMM d" → "MMM d", so en-US says "Oct 11"), the smallest Windows-neutral equivalent.
    public static string ShotAge(double? at, double now, CultureInfo? culture = null, TimeZoneInfo? timeZone = null)
    {
        if (at is not { } time) return "";
        var seconds = (int)Math.Round(Math.Max(0, Math.Min(now - time, 4e9)), MidpointRounding.AwayFromZero);
        if (seconds < 10) return "just now";
        if (seconds < 60) return $"{seconds} s ago";
        if (seconds < 3600) return $"{seconds / 60} min ago";
        if (seconds < 86_400) return $"{seconds / 3600} h ago";
        var format = culture ?? CultureInfo.CurrentCulture;
        var zone = timeZone ?? TimeZoneInfo.Local;
        var pattern = format.DateTimeFormat.MonthDayPattern.Replace("MMMM", "MMM", StringComparison.Ordinal);
        var date = TimeZoneInfo.ConvertTime(DateTimeOffset.FromUnixTimeMilliseconds((long)(time * 1000)), zone);
        return date.ToString(pattern, format);
    }

    private static readonly string[] MacRoots = ["/Users/", "/Volumes/", "/private/", "/Applications/", "/opt/homebrew/"];

    /// The gateway computer's kind, guessed from file paths (a screenshot's, a session's folder). null: no telling.
    public static ScreenHostKind? HostKind(IEnumerable<string?> paths)
    {
        foreach (var path in paths)
        {
            if (string.IsNullOrEmpty(path)) continue;
            if (ToolScreenshots.IsRemote(path)) continue;
            if (path.Length >= 3 && char.IsAscii(path[0]) && char.IsLetter(path[0]) && path[1] == ':' && path[2] is '\\' or '/')
                return ScreenHostKind.Windows;
            if (path.Contains('\\')) return ScreenHostKind.Windows;
            foreach (var root in MacRoots)
                if (path.StartsWith(root, StringComparison.Ordinal)) return ScreenHostKind.Mac;
        }
        return null;
    }

    /// Heading and sub-line of the latest screenshots view (§5.14).
    /// `managed`: a Hermes Cloud agent, whose Hermes Nous updates (the person can't).
    public static (string Title, string Detail) Heading(ScreenSession.Fallback reason, string name, ScreenHostKind? host, string? blocker,
        bool managed = false)
    {
        if (managed && reason == ScreenSession.Fallback.Unavailable)
            return ("Screen isn’t on this Hermes Cloud release yet",
                $"Nous updates Hermes on its agents. Meanwhile, {name}’s latest screenshot shows here.");
        switch (reason)
        {
            case ScreenSession.Fallback.Unsupported:
                return (host == ScreenHostKind.Windows ? $"Live screen sharing isn’t available on {HostWord.Phrase}"
                                                       : $"Screen sharing isn’t set up on {HostWord.Phrase}",
                    $"Instead, {name}’s latest screenshot shows here and updates while the bot works.");
            case ScreenSession.Fallback.Blocked:
                var lead = "";
                if (!string.IsNullOrEmpty(blocker)) lead = (blocker.EndsWith('.') ? blocker[..^1] : blocker) + ". ";
                return ("Screen sharing needs attention", $"{lead}Meanwhile, {name}’s latest screenshot shows here.");
            default:
                return ("Screen needs a newer Hermes",
                    $"Update Hermes on {HostWord.UpdateTarget} to watch live. Meanwhile, {name}’s latest screenshot shows here.");
        }
    }

    /// The sessions of `GET /api/profiles/sessions`, newest activity first. Throws when the answer is not JSON.
    public static List<RecentScreenSession> Sessions(string data)
    {
        var json = Parse(data);
        var found = new List<RecentScreenSession>();
        foreach (var row in json.Arr("sessions") ?? [])
        {
            if (ToolScreenshots.AsText(row.Get("id")) is not { Length: > 0 } id) continue;
            found.Add(new RecentScreenSession(id, ToolScreenshots.AsNumber(row.Get("last_active")) ?? 0, ToolScreenshots.AsText(row.Get("cwd"))));
        }
        return found.OrderByDescending(s => s.Active).ToList();
    }

    /// The rows of `GET /api/sessions/<id>/messages`. Throws when the answer is not JSON.
    public static List<JsonNode?> Rows(string data) => Parse(data).Arr("messages")?.ToList() ?? [];

    private static JsonNode? Parse(string data) =>
        ToolScreenshots.ParseJson(data) ?? (data.Trim() == "null" ? null : throw new FormatException("The gateway sent something that isn't JSON."));

    /// Swift `HistoryRequest.encodePathSegment`: `CharacterSet.urlPathAllowed` minus "/?#", the rest as UTF-8 %XX.
    public static string EncodePathSegment(string s)
    {
        const string allowed = "!$&'()*+,-.:;=@_~";
        var sb = new StringBuilder();
        foreach (var b in Encoding.UTF8.GetBytes(s))
        {
            var c = (char)b;
            if (b < 0x80 && (char.IsAsciiLetterOrDigit(c) || allowed.Contains(c))) sb.Append(c);
            else sb.Append('%').Append(b.ToString("X2", CultureInfo.InvariantCulture));
        }
        return sb.ToString();
    }
}

/// One poll of a bot's stored screenshots. Messages are fetched only when its latest session moved; a failed read is
/// retried on the next poll (never a false "no screenshots"), and two failures in a row say "unreachable".
public sealed class ScreenshotPoller(Func<Task<List<RecentScreenSession>>> sessions, Func<string, int, Task<List<JsonNode?>>> messages)
{
    public enum Empty { None, Unreachable }

    public Func<Task<List<RecentScreenSession>>> Sessions { get; set; } = sessions;
    public Func<string, int, Task<List<JsonNode?>>> Messages { get; set; } = messages;
    public Action<ScreenShot> Shot { get; set; } = _ => { };
    public Action<Empty> Emptied { get; set; } = _ => { };
    public Action<List<RecentScreenSession>> SeenSessions { get; set; } = _ => { };

    private string? _seen;
    private bool _found;
    private int _failures;

    public async Task PollAsync()
    {
        try
        {
            var recent = await Sessions();
            SeenSessions(recent);
            if (recent.Count == 0)
            {
                _seen = null;
                _failures = 0;
                Emptied(Empty.None);
                return;
            }
            var latest = recent[0];
            var mark = $"{latest.Id}:{latest.Active.ToString("R", CultureInfo.InvariantCulture)}";
            if (mark == _seen) return;
            var rows = await Messages(latest.Id, _found ? 8 : 40);
            _seen = mark;
            _failures = 0;
            if (ScreenshotRules.LatestShot(rows) is { } next)
            {
                _found = true;
                Shot(next);
            }
            else
            {
                Emptied(Empty.None);
            }
        }
        catch (Exception)
        {
            _failures += 1;
            if (_failures >= 2) Emptied(Empty.Unreachable);
        }
    }
}

/// The model of one open latest-screenshots view. Make it on the UI thread and call it only there.
public sealed class ScreenshotFeed
{
    /// `Unloadable`: the screenshot is known but its picture could not be fetched (a dropped connection, a timeout, a
    /// 5xx). Not `Expired`: only "the file is not there" (404/410) says the gateway let it go (review finding 5).
    public enum FeedState { Searching, None, Unreachable, Loading, Expired, Shown, Unloadable }

    /// Tried again on each of the next polls this many times, then on every tenth poll (about every 30 s).
    public const int QuickLoadTries = 5;

    public static readonly TimeSpan PollEvery = TimeSpan.FromSeconds(3);

    /// The events the feed reads.
    public static readonly IReadOnlySet<string> EventTypes = new HashSet<string>(StringComparer.Ordinal) { "tool.start", "tool.complete" };

    public string Profile { get; }
    public string Name { get; }
    public ScreenShot? Shot { get; private set; }
    public FeedState State { get; private set; } = FeedState.Searching;
    public string Working { get; private set; } = "";
    /// Goes up each time the picture should be fetched again; the view loads when it differs from what it tried.
    public int LoadAttempt { get; private set; }
    public ScreenHostKind? SessionHost { get; private set; }
    public IReadOnlySet<string> RecentSessions { get; private set; } = new HashSet<string>(StringComparer.Ordinal);

    /// Anything above changed.
    public Action? OnChange { get; set; }
    /// A new picture is to be shown (not the first one): the view announces it.
    public Action? OnNewShot { get; set; }
    /// Whether a live event belongs to this bot (the app knows which chats it has live); stored ids the last poll
    /// listed always count.
    public Func<RpcEvent, bool> IsMine { get; set; } = _ => false;
    public Func<double> Now { get; set; } = () => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;
    /// Swift `ScreenPower.slow` (DECISION D9, `PowerState.shared.saving`). Windows: battery saver, handed in by the app
    /// (ScreenService.Slow); Core reads no power state of its own.
    public Func<bool> Slow { get; set; } = () => false;

    private int _loadFailures;
    private int _ticksSinceFailure;
    private readonly IScreenshotGateway _client;
    private readonly ScreenshotPoller _poller;
    private readonly SynchronizationContext? _main;
    private CancellationTokenSource? _pollTask;
    private IDisposable? _eventTask;
    private bool _visible;
    private bool _busy;

    public ScreenshotFeed(IScreenshotGateway client, string profile, string name)
    {
        _client = client;
        Profile = profile;
        Name = name;
        _main = SynchronizationContext.Current;
        _poller = new ScreenshotPoller(
            sessions: async () =>
            {
                List<KeyValuePair<string, string>> query =
                [
                    new("limit", "3"), new("offset", "0"), new("min_messages", "1"), new("archived", "exclude"),
                    new("order", "recent"), new("profile", profile),
                ];
                return ScreenshotRules.Sessions(await client.RestAsync("GET", "/api/profiles/sessions", query));
            },
            messages: async (id, limit) =>
            {
                List<KeyValuePair<string, string>> query =
                [
                    new("limit", limit.ToString(CultureInfo.InvariantCulture)), new("order", "latest"), new("profile", profile),
                ];
                var path = $"/api/sessions/{ScreenshotRules.EncodePathSegment(id)}/messages";
                return ScreenshotRules.Rows(await client.RestAsync("GET", path, query));
            })
        {
            Shot = Offer,
            Emptied = next =>
            {
                if (State != FeedState.Searching && State != FeedState.Unreachable) return;
                Set(next == ScreenshotPoller.Empty.None ? FeedState.None : FeedState.Unreachable);
            },
            SeenSessions = sessions =>
            {
                RecentSessions = sessions.Select(s => s.Id).ToHashSet(StringComparer.Ordinal);
                if (SessionHost == null && ScreenshotRules.HostKind(sessions.Select(s => s.Cwd)) is { } kind)
                {
                    SessionHost = kind;
                    OnChange?.Invoke();
                }
            },
        };
    }

    /// The gateway computer's kind: the shown screenshot's path decides, else a session's folder.
    public ScreenHostKind? HostKind => ScreenshotRules.HostKind([Shot?.Src]) ?? SessionHost;

    /// "<caption> · <age>", or "<working>…" in place of the caption while a tool runs.
    public string Caption(double? now = null)
    {
        var lead = Working.Length == 0 ? Shot?.Caption ?? "" : $"{Working}…";
        if (Shot is not { } shot) return lead;
        return string.Join(" · ", new[] { lead, ScreenshotRules.ShotAge(shot.At, now ?? Now()) }.Where(s => s.Length > 0));
    }

    /// The line the picture frame holds when there is no picture.
    public string EmptyLine => State switch
    {
        FeedState.Searching => "Looking for screenshots…",
        FeedState.None => $"No screenshots yet. When {Name} uses its computer or browser, the newest one appears here.",
        FeedState.Unreachable => "Can’t reach the gateway to look for screenshots. Trying again…",
        FeedState.Loading => "Loading the screenshot…",
        FeedState.Unloadable => "Can’t load the screenshot. Trying again…",
        FeedState.Expired => ToolScreenshots.ExpiredNote,
        _ => "",
    };

    /// On screen and the app active: the poll and the live events run only then.
    public void SetVisible(bool on)
    {
        if (on == _visible) return;
        _visible = on;
        _pollTask?.Cancel();
        _pollTask = null;
        if (_eventTask == null) Listen();
        if (!on) return;
        var task = new CancellationTokenSource();
        _pollTask = task;
        // Swift `Task { … }` on the main actor: starts after this call returns.
        Post(() => _ = PollLoop(task.Token));
    }

    private async Task PollLoop(CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            await Tick();
            var wait = PollEvery * (Slow() ? 2 : 1);
            try { await Task.Delay(wait, token); }
            catch (OperationCanceledException) { return; }
        }
    }

    public void Stop()
    {
        _visible = false;
        _pollTask?.Cancel();
        _pollTask = null;
        _eventTask?.Dispose();
        _eventTask = null;
    }

    /// One poll (one at a time; skipped while hidden).
    public async Task Tick()
    {
        if (!_visible || _busy) return;
        _busy = true;
        await _poller.PollAsync();
        _busy = false;
        RetryDue();
    }

    /// After each poll: a picture that could not be fetched is asked for again (the view loads on `LoadAttempt`).
    public void RetryDue()
    {
        if (State != FeedState.Unloadable) return;
        _ticksSinceFailure += 1;
        if (_loadFailures <= QuickLoadTries || _ticksSinceFailure % 10 == 0)
        {
            LoadAttempt += 1;
            OnChange?.Invoke();
        }
    }

    /// The view loaded (or could not load) the picture of `id`.
    public void Loaded(string id, bool ok)
    {
        if (Shot?.Id != id) return;
        _loadFailures = 0;
        Set(ok ? FeedState.Shown : FeedState.Expired);
    }

    /// The picture of `id` could not be fetched, and nothing says its file is gone: it is tried again.
    public void LoadFailed(string id)
    {
        if (Shot?.Id != id) return;
        _loadFailures += 1;
        _ticksSinceFailure = 0;
        Set(FeedState.Unloadable);
    }

    /// Only the gateway saying the file is not there makes a capture expired.
    public static bool IsGone(Exception error) => error is GatewayException { Code: "http", Status: 404 or 410 };

    public void Handle(RpcEvent e)
    {
        if (e.Type != "tool.complete" && e.Type != "tool.start") return;
        var stored = ToolScreenshots.AsText(e.Payload.Get("stored_session_id"));
        if (!IsMine(e) && !(stored != null && RecentSessions.Contains(stored))) return;
        if (e.Type == "tool.complete")
        {
            if (ScreenshotRules.LiveShot(e.Payload, Now()) is { } next) Offer(next);
            if (Working.Length > 0)
            {
                Working = "";
                OnChange?.Invoke();
            }
        }
        else if (ToolScreenshots.AsText(e.Payload.Get("name")) is { } tool && ToolScreenshots.IsScreenshotTool(tool))
        {
            Working = ScreenshotRules.ShotCaption(tool, e.Payload.Get("args"));
            OnChange?.Invoke();
        }
    }

    private void Listen()
    {
        IDisposable? subscription = null;
        subscription = _client.RpcEvents(EventTypes, e => Post(() =>
        {
            if (ReferenceEquals(_eventTask, subscription)) Handle(e);       // a stopped feed reads nothing more
        }));
        _eventTask = subscription;
    }

    /// A newer capture replaces the shown one; the same capture arriving by REST after its live event does not.
    private void Offer(ScreenShot next)
    {
        if (Shot is { } shot && (shot.Id == next.Id || (next.At ?? 0) < (shot.At ?? 0))) return;
        var first = Shot == null;
        Shot = next;
        // The previous picture stays up while the next one loads.
        _loadFailures = 0;
        if (ToolScreenshots.IsInline(next.Src)) State = FeedState.Shown;
        else if (State != FeedState.Shown) State = FeedState.Loading;
        if (!first) OnNewShot?.Invoke();
        OnChange?.Invoke();
    }

    private void Set(FeedState next)
    {
        if (State == next) return;
        State = next;
        OnChange?.Invoke();
    }

    private void Post(Action work)
    {
        if (_main == null) work();
        else _main.Post(_ => work(), null);
    }
}
