// Watch Browser's wire (gateway plugin hermes-hq-browser, protocol 3), C# twin of HermesKit/Browser/BrowserWire.swift.
// Pure values and parsing: no UI, no sockets. Text JSON both ways; a frame is a JPEG data URL inside a `frame` message.
// Nothing here logs: page text, typed text and addresses never reach the diagnostic log.

using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Composer;
using Hermes.Core.Gateways;
using Hermes.Core.Rpc;

namespace Hermes.Core.Browser;

public static class BrowserWire
{
    public const string Plugin = "/api/plugins/hermes-hq-browser";
    /// The same plugin under its name before Hermes HQ (dispatch-browser 3.3 and earlier): same protocol, older routes.
    public const string LegacyPlugin = "/api/plugins/dispatch-browser";
    public const int ProtocolVersion = 3;
    public const int MaxFrameImage = 4 * 1024 * 1024;
    public const int MaxMessage = MaxFrameImage + 4096;
    /// A frame is acknowledged at most this often once drawn (the plugin sends one per ack): 30 a second.
    public static readonly TimeSpan FrameInterval = TimeSpan.FromMilliseconds(33);
    /// A bot's own Chrome counts as in use this long after its last browser tool.
    public static readonly TimeSpan ActiveFor = TimeSpan.FromSeconds(90);

    public const string ViewerIdKey = "hq.browser.viewer";

    public static bool IsBrowserId(string? id) =>
        id is { Length: 24 } && id.All(c => c is (>= '0' and <= '9') or (>= 'a' and <= 'f'));

    public static string? WatchPath(string id, string @base = Plugin) =>
        IsBrowserId(id) ? $"{@base}/sessions/{id}/watch" : null;

    /// `ws(s)://<host>/<prefix>/api/plugins/…?profile=<p>&ticket=<t>` for a plugin socket: the gateway's own scheme
    /// (wss iff https), its path prefix kept, the ticket last (a fresh ticket is minted per socket, as for /api/ws).
    public static Uri? SocketUrl(Uri @base, string path, IEnumerable<KeyValuePair<string, string>> query, string ticket)
    {
        if (!@base.IsAbsoluteUri) return null;
        if (!path.StartsWith(Plugin + "/", StringComparison.Ordinal) &&
            !path.StartsWith(LegacyPlugin + "/", StringComparison.Ordinal))
            return null;
        if (path.Contains('?') || path.Contains('#') || path.Contains("..", StringComparison.Ordinal)) return null;
        var scheme = @base.Scheme.ToLowerInvariant() switch { "https" => "wss", "http" => "ws", _ => null };
        if (scheme == null) return null;
        var basePath = @base.AbsolutePath;
        var prefix = basePath.EndsWith('/') ? basePath[..^1] : basePath;
        var sb = new StringBuilder();
        foreach (var (k, v) in query)
        {
            if (string.Equals(k, "ticket", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(k, "token", StringComparison.OrdinalIgnoreCase))
                continue;
            if (sb.Length > 0) sb.Append('&');
            sb.Append(Uri.EscapeDataString(k)).Append('=').Append(Uri.EscapeDataString(v));
        }
        if (sb.Length > 0) sb.Append('&');
        sb.Append("ticket=").Append(Uri.EscapeDataString(ticket));
        var builder = new UriBuilder(@base)
        {
            Scheme = scheme,
            Port = @base.IsDefaultPort ? -1 : @base.Port,
            UserName = "",
            Password = "",
            Fragment = "",
            Path = prefix + path,
            Query = sb.ToString(),
        };
        return builder.Uri;
    }

    /// The viewer's identity: one per PC, so a device that left (or relaunched) finds a browser it still holds.
    public static string ViewerId(IKeyValueStore store)
    {
        if (store.Get(ViewerIdKey) is { Length: 32 } saved &&
            saved.All(c => c is (>= '0' and <= '9') or (>= 'a' and <= 'f') or (>= 'A' and <= 'F')))
            return saved;
        var made = Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(16));
        store.Set(ViewerIdKey, made);
        return made;
    }

    /// The stage in points times its zoom, and its pixel density, bounded (the `view` message).
    public static (int Width, int Height, double Scale) ViewSize(double width, double height, double scale)
    {
        var ratio = double.IsFinite(scale) ? Math.Min(3.0, Math.Max(1.0, scale)) : 1.0;
        static int Size(double v) => double.IsFinite(v) ? (int)Math.Max(64, Math.Min(2048, Math.Round(v, MidpointRounding.AwayFromZero))) : 64;
        return (Size(width), Size(height), ratio);
    }

    /// A gateway Nous hosts (`<name>.agents.nousresearch.com`), matching CloudGatewayFlow.isCloud.
    public static bool IsCloudHost(Uri? baseUrl) =>
        baseUrl?.Host?.EndsWith(".agents.nousresearch.com", StringComparison.OrdinalIgnoreCase) == true;
}

// ------------------------------------------------------------------ Rows (the activity list)

public enum BrowserControl { Bot, Waiting, Person }

public static class BrowserControls
{
    public static BrowserControl? Parse(string? raw) => raw switch
    {
        "bot" => BrowserControl.Bot,
        "waiting" => BrowserControl.Waiting,
        "person" => BrowserControl.Person,
        _ => null,
    };

    public static string Raw(this BrowserControl control) => control switch
    {
        BrowserControl.Waiting => "waiting",
        BrowserControl.Person => "person",
        _ => "bot",
    };
}

/// One bot browser as the gateway lists it.
public sealed record BrowserRow
{
    public string Id { get; init; }
    public string Profile { get; init; }
    public string SessionId { get; init; }
    public IReadOnlyList<string> SessionIds { get; init; }
    public string? Url { get; init; }
    public int Busy { get; init; }
    public BrowserControl Control { get; init; }
    public string? Ask { get; init; }
    public double AgentAt { get; init; }
    public bool Active { get; init; }

    public BrowserRow(
        string id,
        string profile,
        string sessionId = "",
        IReadOnlyList<string>? sessionIds = null,
        string? url = null,
        int busy = 0,
        BrowserControl control = BrowserControl.Bot,
        string? ask = null,
        double agentAt = 0,
        bool active = false)
    {
        Id = id;
        Profile = profile;
        SessionId = sessionId;
        SessionIds = sessionIds ?? [];
        Url = url;
        Busy = busy;
        Control = control;
        Ask = ask;
        AgentAt = agentAt;
        Active = active;
    }

    /// The chat that used this browser last.
    public string Driver => string.IsNullOrEmpty(SessionId) ? (SessionIds.Count > 0 ? SessionIds[^1] : "") : SessionId;

    /// A bot using it, asking for the person, or the person holding it: news. An idle bot Chrome shows nothing.
    public bool InUse => Active || Ask != null || Control != BrowserControl.Bot;

    public static BrowserRow? Parse(JsonNode? value, DateTimeOffset? now = null)
    {
        if (value is not JsonObject) return null;
        var id = BrowserJson.Str(value, "id");
        var profile = BrowserJson.Str(value, "profile");
        if (!BrowserWire.IsBrowserId(id) || string.IsNullOrEmpty(profile)) return null;
        var ids = (value["session_ids"] is JsonArray arr
                ? arr.Select(BrowserJson.AsString).OfType<string>().Where(s => s.Length > 0 && s.Length <= 512)
                : [])
            .TakeLast(16)
            .ToArray();
        var control = BrowserControls.Parse(BrowserJson.Str(value, "control")) ?? BrowserControl.Bot;
        var busyRaw = BrowserJson.Double(value, "busy");
        var busy = busyRaw is { } bd && bd > 0 && double.IsFinite(bd) ? (int)Math.Floor(bd) : 0;
        var agentRaw = BrowserJson.Double(value, "agent_at");
        var agentAt = agentRaw is { } ad && double.IsFinite(ad) ? ad : 0;
        var askTrimmed = BrowserJson.Str(value, "ask")?.Trim();
        var ask = string.IsNullOrEmpty(askTrimmed) ? null : BrowserJson.Prefix(askTrimmed, 200);
        var url = BrowserJson.Str(value, "url") is { } u ? BrowserJson.Prefix(u, 4096) : null;
        var sessionId = BrowserJson.Prefix(BrowserJson.Str(value, "session_id") ?? "", 512);
        var clock = now ?? DateTimeOffset.UtcNow;
        var active = BrowserJson.Bool(value, "active") ??
            (busy > 0 || (agentAt > 0 && clock.ToUnixTimeMilliseconds() / 1000.0 - agentAt < BrowserWire.ActiveFor.TotalSeconds));
        return new BrowserRow(
            id!,
            BrowserJson.Prefix(profile, 128),
            sessionId,
            ids,
            url,
            busy,
            control,
            ask,
            agentAt,
            active);
    }

    /// `dispatch-browser.list.v3` (the plugin kept its wire names under the new name).
    public static List<BrowserRow>? ParseList(JsonNode? value, DateTimeOffset? now = null)
    {
        if (value is not JsonObject || BrowserJson.Str(value, "schema") != "dispatch-browser.list.v3") return null;
        if (value["browsers"] is not JsonArray list) return null;
        var out_ = new List<BrowserRow>();
        foreach (var item in list.Take(64))
            if (Parse(item, now) is { } row) out_.Add(row);
        return out_;
    }

    public bool Equals(BrowserRow? other) =>
        other is not null && Id == other.Id && Profile == other.Profile && SessionId == other.SessionId
        && SessionIds.SequenceEqual(other.SessionIds) && Url == other.Url && Busy == other.Busy
        && Control == other.Control && Ask == other.Ask && AgentAt.Equals(other.AgentAt) && Active == other.Active;

    public override int GetHashCode() => HashCode.Combine(Id, Profile, SessionId, Url, Busy, Control, Ask, Active);
}

/// Which browser a chat or a bot shows.
public sealed record BrowserScope
{
    /// The bot (Hermes profile).
    public string Profile { get; init; }
    /// A bot's own chat shows any browser of that bot; another chat only its own (by session id).
    public IReadOnlyList<string> SessionIds { get; init; }
    /// The bot's display name.
    public string Title { get; init; }
    /// Another chat of the bot (not its own chat): only a browser of this chat's sessions, none while it has no ids yet.
    public bool ChatOnly { get; init; }
    /// A Bot Chat's sessions, this one and its earlier ones: for the card only (`DrivenRow`), so the viewer opened
    /// from a Bot Chat still finds any browser of the bot.
    public IReadOnlyList<string> OwnChats { get; init; }

    public BrowserScope(
        string profile,
        string title,
        IReadOnlyList<string>? sessionIds = null,
        bool chatOnly = false,
        IReadOnlyList<string>? ownChats = null)
    {
        Profile = profile;
        Title = title;
        SessionIds = sessionIds ?? [];
        ChatOnly = chatOnly;
        OwnChats = ownChats ?? [];
    }

    /// This bot's browser: its profile's, and when the scope names chats, one of theirs. Newest bot use first.
    public BrowserRow? Row(IEnumerable<BrowserRow> rows)
    {
        var ids = SessionIds.Where(s => !string.IsNullOrEmpty(s)).ToHashSet(StringComparer.Ordinal);
        if (ChatOnly && ids.Count == 0) return null;
        return rows.OrderByDescending(r => r.AgentAt).FirstOrDefault(row =>
            row.Profile == Profile &&
            (ids.Count == 0 || ids.Contains(row.SessionId) || row.SessionIds.Any(ids.Contains)));
    }

    /// The browser a chat's card speaks for: one this chat is driving now. Only the chat that used the browser last
    /// (`Driver`) counts. No ids: none (the viewer, not the card, shows "any browser of the bot").
    public BrowserRow? DrivenRow(IEnumerable<BrowserRow> rows)
    {
        var ids = SessionIds.Concat(OwnChats).Where(s => !string.IsNullOrEmpty(s)).ToHashSet(StringComparer.Ordinal);
        if (ids.Count == 0) return null;
        return rows.OrderByDescending(r => r.AgentAt).FirstOrDefault(row =>
            row.Profile == Profile && ids.Contains(row.Driver));
    }

    public bool Equals(BrowserScope? other) =>
        other is not null && Profile == other.Profile && Title == other.Title && ChatOnly == other.ChatOnly
        && SessionIds.SequenceEqual(other.SessionIds) && OwnChats.SequenceEqual(other.OwnChats);

    public override int GetHashCode() => HashCode.Combine(Profile, Title, ChatOnly, SessionIds.Count, OwnChats.Count);
}

public static class BrowserLastPageExtensions
{
    public static bool Fits(this BrowserLastPage page, BrowserScope scope) =>
        page.Fits(scope.ChatOnly, scope.SessionIds);
}

public static class BrowserCard
{
    /// The browser the chat's card shows: one in use, or, while the chat's turn still runs, the one it already shows.
    public static BrowserRow? Row(BrowserRow? row, BrowserRow? showing, bool turnRunning)
    {
        if (row is { InUse: true }) return row;
        if (!turnRunning || showing == null || (row != null && row.Id != showing.Id)) return null;
        return (row ?? showing) with { Active = true };
    }

    /// The card's words (the shelf chip).
    public static string Words(BrowserRow row, string name)
    {
        if (row.Ask != null && row.Control == BrowserControl.Bot) return $"{name} needs you in its browser";
        return row.Control switch
        {
            BrowserControl.Person => $"You’re using {name}’s browser",
            BrowserControl.Waiting => "Handing you the browser…",
            _ => BrowserAddress.Parse(row.Url).Host is { Length: > 0 } host && host != "New Tab"
                ? $"Browsing {host}"
                : "Using its browser",
        };
    }

    /// The browser a Bots row speaks for: one its own Bot Chat uses, or one that needs the person whichever chat it is in.
    public static BrowserRow? BotRow(IEnumerable<BrowserRow> rows, string profile, IReadOnlySet<string>? ownChats)
    {
        return rows.OrderByDescending(r => r.AgentAt).FirstOrDefault(row =>
        {
            if (row.Profile != profile) return false;
            if (row.Ask != null || row.Control != BrowserControl.Bot) return true;
            if (ownChats == null) return true;
            return ownChats.Contains(row.Driver);
        });
    }

    /// One line for a Bots row (null when the browser is not news).
    public static string? StatusLine(BrowserRow? row)
    {
        if (row is not { InUse: true }) return null;
        if (row.Ask != null && row.Control == BrowserControl.Bot) return "Needs you in its browser";
        if (row.Control == BrowserControl.Person) return "You’re using its browser";
        if (row.Control == BrowserControl.Waiting) return "Handing you its browser…";
        return WebHost(row.Url ?? "") is { } host ? $"Browsing {host}" : "Using its browser";
    }

    /// The site a web address names ("example.com"). Nil for anything that is not an http(s) page with a host.
    public static string? WebHost(string url)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri)) return null;
        var scheme = uri.Scheme.ToLowerInvariant();
        if (scheme is not ("http" or "https") || string.IsNullOrEmpty(uri.Host)) return null;
        var host = BrowserAddress.Parse(url).Host;
        return string.IsNullOrEmpty(host) || host == "New Tab" ? null : host;
    }
}

// ------------------------------------------------------------------ The watch socket's messages

public sealed record BrowserTab(string Id, string Title, string Url);

public sealed record BrowserControlState(BrowserControl State, bool Mine, int? Epoch);

/// A text field in the page (plugin 3.4.4+).
public enum BrowserFieldKind { Password, Username, Code, Email, Tel, Url, Number, Search, Text, Multiline }

public static class BrowserFieldKinds
{
    public static BrowserFieldKind? Parse(string? raw) => raw switch
    {
        "password" => BrowserFieldKind.Password,
        "username" => BrowserFieldKind.Username,
        "code" => BrowserFieldKind.Code,
        "email" => BrowserFieldKind.Email,
        "tel" => BrowserFieldKind.Tel,
        "url" => BrowserFieldKind.Url,
        "number" => BrowserFieldKind.Number,
        "search" => BrowserFieldKind.Search,
        "text" => BrowserFieldKind.Text,
        "multiline" => BrowserFieldKind.Multiline,
        _ => null,
    };
}

public sealed record BrowserPageFields(BrowserFieldKind? Under, BrowserFieldKind? Focus);

public enum BrowserPageDialogKind { Alert, Confirm, Prompt, Leave, Accounts, Signin, SigninError }

public static class BrowserPageDialogKinds
{
    public static BrowserPageDialogKind? Parse(string? raw) => raw switch
    {
        "alert" => BrowserPageDialogKind.Alert,
        "confirm" => BrowserPageDialogKind.Confirm,
        "prompt" => BrowserPageDialogKind.Prompt,
        "leave" => BrowserPageDialogKind.Leave,
        "accounts" => BrowserPageDialogKind.Accounts,
        "signin" => BrowserPageDialogKind.Signin,
        "signin_error" => BrowserPageDialogKind.SigninError,
        _ => null,
    };
}

public sealed record BrowserDialogAccount(string Name, string Email);

/// Something the watched page has open that Chrome draws outside the page, so no frame shows it (plugin 3.7.0+).
public sealed record BrowserPageDialog(
    int Id,
    BrowserPageDialogKind Kind,
    string? Site,
    string Message,
    string? DefaultText,
    string? Title,
    IReadOnlyList<BrowserDialogAccount> Accounts)
{
    public bool Equals(BrowserPageDialog? other) =>
        other is not null && Id == other.Id && Kind == other.Kind && Site == other.Site && Message == other.Message
        && DefaultText == other.DefaultText && Title == other.Title && Accounts.SequenceEqual(other.Accounts);

    public override int GetHashCode() => HashCode.Combine(Id, Kind, Site, Message, DefaultText, Title, Accounts.Count);
}

public sealed record BrowserViewState(
    IReadOnlyList<BrowserTab> Tabs,
    string? Tab,
    bool Follow,
    BrowserControlState Control,
    string? Ask,
    BrowserPageFields? Field,
    BrowserPageDialog? Dialog = null)
{
    public BrowserTab? CurrentTab => Tabs.FirstOrDefault(t => t.Id == Tab);

    public bool Equals(BrowserViewState? other) =>
        other is not null && Tabs.SequenceEqual(other.Tabs) && Tab == other.Tab && Follow == other.Follow
        && Control == other.Control && Ask == other.Ask && Field == other.Field && Dialog == other.Dialog;

    public override int GetHashCode() => HashCode.Combine(Tabs.Count, Tab, Follow, Control, Ask, Field, Dialog);
}

/// A frame as the socket carried it: the page's CSS size it shows and the JPEG bytes (not yet decoded).
public sealed record BrowserFrame(int Seq, string? Tab, int? Epoch, double Width, double Height, byte[] Jpeg)
{
    public bool Equals(BrowserFrame? other) =>
        other is not null && Seq == other.Seq && Tab == other.Tab && Epoch == other.Epoch
        && Width.Equals(other.Width) && Height.Equals(other.Height) && Jpeg.AsSpan().SequenceEqual(other.Jpeg);

    public override int GetHashCode() => HashCode.Combine(Seq, Tab, Epoch, Width, Height, Jpeg.Length);
}

public abstract record BrowserServerMessage
{
    private BrowserServerMessage() { }

    public sealed record State(BrowserViewState View) : BrowserServerMessage;
    public sealed record Frame(BrowserFrame Data) : BrowserServerMessage;
    public sealed record Ended(string Reason) : BrowserServerMessage;
    public sealed record Error(string Message) : BrowserServerMessage;
    public sealed record Ping : BrowserServerMessage
    {
        public static readonly Ping Instance = new();
    }
    public sealed record Copied(string Text) : BrowserServerMessage;

    private const string JpegPrefix = "data:image/jpeg;base64,";
    private const string JpegHead = "data:image/jpeg;base64,/9j/";

    public static BrowserServerMessage? Parse(string json) => Parse(Encoding.UTF8.GetBytes(json));

    /// Parses one text message (off the main thread: a frame is up to 4 MB of base64). null for anything malformed.
    public static BrowserServerMessage? Parse(ReadOnlySpan<byte> utf8)
    {
        if (utf8.Length == 0 || utf8.Length > BrowserWire.MaxMessage) return null;
        try
        {
            using var doc = JsonDocument.Parse(utf8.ToArray());
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return null;
            if (!TryStr(root, "type", out var type)) return null;
            return type switch
            {
                "ping" => Ping.Instance,
                "ended" => new Ended(TryStr(root, "reason", out var reason) && reason.Length > 0 ? BrowserJson.Prefix(reason, 32) : "closed"),
                "error" => new Error(TryStr(root, "message", out var msg) && msg.Length > 0 ? BrowserJson.Prefix(msg, 300) : "The browser didn’t take that."),
                "copied" => new Copied(TryStr(root, "text", out var copied) ? BrowserJson.Prefix(copied, 65536) : ""),
                "state" => ParseState(root) is { } st ? new State(st) : null,
                "frame" => ParseFrame(root) is { } fr ? new Frame(fr) : null,
                _ => null,
            };
        }
        catch (JsonException) { return null; }
    }

    private static BrowserViewState? ParseState(JsonElement obj)
    {
        if (!obj.TryGetProperty("tabs", out var tabsEl) || tabsEl.ValueKind != JsonValueKind.Array) return null;
        if (!obj.TryGetProperty("control", out var ctrlEl) || ctrlEl.ValueKind != JsonValueKind.Object) return null;
        if (!TryStr(ctrlEl, "state", out var stateRaw) || BrowserControls.Parse(stateRaw) is not { } state) return null;

        var parsedTabs = new List<BrowserTab>();
        var count = 0;
        foreach (var item in tabsEl.EnumerateArray())
        {
            if (count++ >= 64) break;
            if (item.ValueKind != JsonValueKind.Object) continue;
            if (!TryStr(item, "id", out var id) || id.Length == 0 || id.Length > 256) continue;
            var title = TryStr(item, "title", out var t) ? BrowserJson.Prefix(t, 300) : "";
            var url = TryStr(item, "url", out var u) ? BrowserJson.Prefix(u, 4096) : "";
            parsedTabs.Add(new BrowserTab(id, title, url));
        }

        string? ask = null;
        if (TryStr(obj, "ask", out var rawAsk))
        {
            var trimmed = rawAsk.Trim();
            if (trimmed.Length > 0) ask = BrowserJson.Prefix(trimmed, 200);
        }

        BrowserPageFields? field = null;
        if (obj.TryGetProperty("field", out var fEl) && fEl.ValueKind == JsonValueKind.Object)
        {
            var under = TryStr(fEl, "under", out var uRaw) ? BrowserFieldKinds.Parse(uRaw) : null;
            var focus = TryStr(fEl, "focus", out var foRaw) ? BrowserFieldKinds.Parse(foRaw) : null;
            field = new BrowserPageFields(under, focus);
        }

        var follow = !obj.TryGetProperty("follow", out var followEl) || followEl.ValueKind != JsonValueKind.False;
        var mine = ctrlEl.TryGetProperty("mine", out var mineEl) && mineEl.ValueKind == JsonValueKind.True;
        var epoch = TryInt(ctrlEl, "epoch");
        var tab = TryStr(obj, "tab", out var tabId) ? tabId : null;
        BrowserPageDialog? dialog = obj.TryGetProperty("dialog", out var dEl) && dEl.ValueKind == JsonValueKind.Object
            ? ParseDialog(dEl)
            : null;

        return new BrowserViewState(
            parsedTabs,
            tab,
            follow,
            new BrowserControlState(state, mine, epoch),
            ask,
            field,
            dialog);
    }

    private static BrowserPageDialog? ParseDialog(JsonElement d)
    {
        if (TryInt(d, "id") is not { } id) return null;
        if (!TryStr(d, "kind", out var kindRaw) || BrowserPageDialogKinds.Parse(kindRaw) is not { } kind) return null;

        string? Trimmed(string key, int limit)
        {
            if (!TryStr(d, key, out var raw)) return null;
            var t = raw.Trim();
            return t.Length == 0 ? null : BrowserJson.Prefix(t, limit);
        }

        var accounts = new List<BrowserDialogAccount>();
        if (d.TryGetProperty("accounts", out var accEl) && accEl.ValueKind == JsonValueKind.Array)
        {
            var n = 0;
            foreach (var item in accEl.EnumerateArray())
            {
                if (n++ >= 20) break;
                if (item.ValueKind != JsonValueKind.Object) continue;
                var name = TryStr(item, "name", out var nm) ? BrowserJson.Prefix(nm, 200) : "";
                var email = TryStr(item, "email", out var em) ? BrowserJson.Prefix(em, 200) : "";
                if (name.Length == 0 && email.Length == 0) continue;
                accounts.Add(new BrowserDialogAccount(name, email));
            }
        }
        if (kind == BrowserPageDialogKind.Accounts && accounts.Count == 0) return null;

        string? defaultText = kind == BrowserPageDialogKind.Prompt && TryStr(d, "default", out var def)
            ? BrowserJson.Prefix(def, 2000)
            : null;

        return new BrowserPageDialog(
            id,
            kind,
            Trimmed("site", 253),
            Trimmed("message", 2000) ?? "",
            defaultText,
            Trimmed("title", 300),
            accounts);
    }

    private static BrowserFrame? ParseFrame(JsonElement obj)
    {
        if (TryInt(obj, "seq") is not { } seq || seq < 1) return null;
        if (TryDouble(obj, "width") is not { } width || !double.IsFinite(width) || width <= 0 || width > 8192) return null;
        if (TryDouble(obj, "height") is not { } height || !double.IsFinite(height) || height <= 0 || height > 8192) return null;
        if (!TryStr(obj, "image", out var image)) return null;
        if (Encoding.UTF8.GetByteCount(image) > BrowserWire.MaxFrameImage || !image.StartsWith(JpegHead, StringComparison.Ordinal))
            return null;
        byte[] jpeg;
        try { jpeg = Convert.FromBase64String(image[JpegPrefix.Length..]); }
        catch (FormatException) { return null; }
        if (jpeg.Length <= 4) return null;
        var tab = TryStr(obj, "tab", out var t) ? t : null;
        var epoch = TryInt(obj, "epoch");
        return new BrowserFrame(seq, tab, epoch, width, height, jpeg);
    }

    private static bool TryStr(JsonElement obj, string key, out string value)
    {
        if (obj.TryGetProperty(key, out var prop) && prop.ValueKind == JsonValueKind.String)
        {
            value = prop.GetString() ?? "";
            return true;
        }
        value = "";
        return false;
    }

    private static double? TryDouble(JsonElement obj, string key) =>
        obj.TryGetProperty(key, out var prop) && prop.ValueKind == JsonValueKind.Number && prop.TryGetDouble(out var d) ? d : null;

    private static int? TryInt(JsonElement obj, string key)
    {
        if (TryDouble(obj, key) is not { } d || !double.IsFinite(d) || Math.Abs(d) >= 9e15) return null;
        if (d is < int.MinValue or > int.MaxValue) return null;
        return (int)d;
    }
}

/// Input while this device holds the browser (`epoch` added when sent).
public abstract record BrowserInput
{
    private BrowserInput() { }

    public sealed record Move(double X, double Y) : BrowserInput;
    public sealed record Tap(double X, double Y) : BrowserInput;
    public sealed record Down(double X, double Y) : BrowserInput;
    public sealed record Up(double X, double Y) : BrowserInput;
    public sealed record Scroll(double X, double Y, int Dx, int Dy) : BrowserInput;
    public sealed record Text(string Value) : BrowserInput;
    public sealed record Key(string Name) : BrowserInput;
    public sealed record Go(string Url) : BrowserInput;
    /// `back`, `forward`, `reload`.
    public sealed record Nav(string Action) : BrowserInput;
    public sealed record Copy : BrowserInput
    {
        public static readonly Copy Instance = new();
    }
    public sealed record SelectAll : BrowserInput
    {
        public static readonly SelectAll Instance = new();
    }
    /// The person's answer to the page's open `BrowserPageDialog`: OK/Cancel, a prompt's text, the account picked.
    public sealed record Answer(int Id, bool Accept, string? Text = null, int? Account = null) : BrowserInput
    {
        public new string? Text { get; init; } = Text;
    }

    /// Typing (kept while the socket reconnects, in order); a tap or a scroll at a stale spot is not worth replaying.
    public bool IsTyping => this is Text or Key;

    internal SortedDictionary<string, object?> WireFields()
    {
        static double Round4(double v) => Math.Round(Math.Clamp(v, 0.0, 1.0) * 10_000.0, MidpointRounding.AwayFromZero) / 10_000.0;
        SortedDictionary<string, object?> Point(string type, double x, double y) => new(StringComparer.Ordinal)
        {
            ["type"] = type, ["x"] = Round4(x), ["y"] = Round4(y),
        };
        return this switch
        {
            Move m => Point("move", m.X, m.Y),
            Tap t => Point("tap", t.X, t.Y),
            Down d => Point("down", d.X, d.Y),
            Up u => Point("up", u.X, u.Y),
            Scroll s => new(StringComparer.Ordinal) { ["dx"] = s.Dx, ["dy"] = s.Dy, ["type"] = "scroll", ["x"] = Round4(s.X), ["y"] = Round4(s.Y) },
            Text t => new(StringComparer.Ordinal) { ["text"] = t.Value, ["type"] = "text" },
            Key k => new(StringComparer.Ordinal) { ["key"] = k.Name, ["type"] = "key" },
            Go g => new(StringComparer.Ordinal) { ["type"] = "go", ["url"] = g.Url },
            Nav n => new(StringComparer.Ordinal) { ["action"] = n.Action, ["type"] = "nav" },
            Copy => new(StringComparer.Ordinal) { ["type"] = "copy" },
            SelectAll => new(StringComparer.Ordinal) { ["type"] = "select_all" },
            Answer a => BuildAnswer(a),
            _ => new(StringComparer.Ordinal),
        };

        static SortedDictionary<string, object?> BuildAnswer(Answer a)
        {
            var dict = new SortedDictionary<string, object?>(StringComparer.Ordinal)
            {
                ["accept"] = a.Accept,
                ["id"] = a.Id,
                ["type"] = "answer",
            };
            if (a.Text != null) dict["text"] = a.Text;
            if (a.Account is { } acc) dict["account"] = acc;
            return dict;
        }
    }
}

/// What the client sends over the watch socket.
public abstract record BrowserClientMessage
{
    private BrowserClientMessage() { }

    public sealed record Hello(string Viewer) : BrowserClientMessage;
    public sealed record View(int Width, int Height, double Scale) : BrowserClientMessage;
    public sealed record Ack(int Seq) : BrowserClientMessage;
    public sealed record Pong : BrowserClientMessage { public static readonly Pong Instance = new(); }
    public sealed record Take : BrowserClientMessage { public static readonly Take Instance = new(); }
    public sealed record Give : BrowserClientMessage { public static readonly Give Instance = new(); }
    public sealed record Follow : BrowserClientMessage { public static readonly Follow Instance = new(); }
    public sealed record Tab(string Id) : BrowserClientMessage;
    public sealed record Input(BrowserInput Data) : BrowserClientMessage;

    public string ToJson(int? epoch = null)
    {
        SortedDictionary<string, object?> fields = this switch
        {
            Hello h => new(StringComparer.Ordinal) { ["type"] = "hello", ["viewer"] = h.Viewer },
            View v => new(StringComparer.Ordinal) { ["height"] = v.Height, ["scale"] = v.Scale, ["type"] = "view", ["width"] = v.Width },
            Ack a => new(StringComparer.Ordinal) { ["seq"] = a.Seq, ["type"] = "ack" },
            Pong => new(StringComparer.Ordinal) { ["type"] = "pong" },
            Take => new(StringComparer.Ordinal) { ["type"] = "take" },
            Give => new(StringComparer.Ordinal) { ["type"] = "give" },
            Follow => new(StringComparer.Ordinal) { ["type"] = "follow" },
            Tab t => new(StringComparer.Ordinal) { ["id"] = t.Id, ["type"] = "tab" },
            Input i => WithEpoch(i.Data.WireFields(), epoch),
            _ => new(StringComparer.Ordinal),
        };
        using var ms = new MemoryStream();
        using (var w = new Utf8JsonWriter(ms))
        {
            w.WriteStartObject();
            foreach (var (k, v) in fields)
            {
                switch (v)
                {
                    case string s: w.WriteString(k, s); break;
                    case int n: w.WriteNumber(k, n); break;
                    case double d: w.WriteNumber(k, d); break;
                    case bool b: w.WriteBoolean(k, b); break;
                }
            }
            w.WriteEndObject();
        }
        return Encoding.UTF8.GetString(ms.ToArray());

        static SortedDictionary<string, object?> WithEpoch(SortedDictionary<string, object?> f, int? e)
        {
            if (e is { } ep) f["epoch"] = ep;
            return f;
        }
    }

    public byte[] ToUtf8(int? epoch = null) => Encoding.UTF8.GetBytes(ToJson(epoch));
}

// ------------------------------------------------------------------ Helpers

public enum BrowserKeyboardSlot { Text, Username, Password, Code }

public enum BrowserKeyboardKind { Text, Email, Tel, Url, Decimal, Search }

public static class BrowserKeyboard
{
    public static (BrowserKeyboardSlot Slot, BrowserKeyboardKind Keyboard) Slot(BrowserFieldKind? kind) => kind switch
    {
        BrowserFieldKind.Password => (BrowserKeyboardSlot.Password, BrowserKeyboardKind.Text),
        BrowserFieldKind.Username => (BrowserKeyboardSlot.Username, BrowserKeyboardKind.Text),
        BrowserFieldKind.Email => (BrowserKeyboardSlot.Username, BrowserKeyboardKind.Email),
        BrowserFieldKind.Code => (BrowserKeyboardSlot.Code, BrowserKeyboardKind.Text),
        BrowserFieldKind.Tel => (BrowserKeyboardSlot.Text, BrowserKeyboardKind.Tel),
        BrowserFieldKind.Url => (BrowserKeyboardSlot.Text, BrowserKeyboardKind.Url),
        BrowserFieldKind.Number => (BrowserKeyboardSlot.Text, BrowserKeyboardKind.Decimal),
        BrowserFieldKind.Search => (BrowserKeyboardSlot.Text, BrowserKeyboardKind.Search),
        _ => (BrowserKeyboardSlot.Text, BrowserKeyboardKind.Text),
    };

    /// Clipboard text as `text` messages the plugin takes (at most 2000 Unicode scalars a chunk), at most 50 of them,
    /// never splitting a grapheme cluster (an emoji with its modifiers stays in one chunk).
    public static List<string> PasteChunks(string text, int size = 2000)
    {
        var normalized = text.Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n');
        var chunks = new List<string>();
        var current = new StringBuilder();
        var scalars = 0;
        var enumerator = StringInfo.GetTextElementEnumerator(normalized);
        while (enumerator.MoveNext())
        {
            var cluster = enumerator.GetTextElement();
            var count = 0;
            foreach (var _ in cluster.EnumerateRunes()) count++;
            if (scalars + count > size && current.Length > 0)
            {
                chunks.Add(current.ToString());
                if (chunks.Count == 50) return chunks;
                current.Clear();
                scalars = 0;
            }
            current.Append(cluster);
            scalars += count;
        }
        if (current.Length > 0 && chunks.Count < 50) chunks.Add(current.ToString());
        return chunks;
    }
}

/// What a page address shows.
public readonly record struct BrowserAddress(string Host, bool Secure)
{
    private static readonly Regex HttpScheme = new(@"^https?://", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    private static readonly Regex BareHost = new(@"^[a-z0-9-]+(\.[a-z0-9-]+)+(:\d+)?(/\S*)?$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    public static BrowserAddress Parse(string? url)
    {
        if (string.IsNullOrEmpty(url)) return new BrowserAddress("", false);
        var host = BrowserLastPageAddress.Host(url);
        var colon = url.IndexOf(':');
        var secure = colon > 0 && url[..colon].Equals("https", StringComparison.OrdinalIgnoreCase)
            && Uri.TryCreate(url, UriKind.Absolute, out var uri) && !string.IsNullOrEmpty(uri.IdnHost);
        return new BrowserAddress(host, secure);
    }

    /// What a typed address means: a URL as is, a bare host as https, anything else a web search.
    public static string? UrlFrom(string input)
    {
        var value = input.Trim();
        if (value.Length == 0) return null;
        if (HttpScheme.IsMatch(value)) return BrowserJson.Prefix(value, 2048);
        if (BareHost.IsMatch(value)) return BrowserJson.Prefix("https://" + value, 2048);
        var query = EscapeAlphanumerics(value);
        return BrowserJson.Prefix("https://duckduckgo.com/?q=" + query, 2048);
    }

    /// Matches Swift `addingPercentEncoding(withAllowedCharacters: .alphanumerics)`: ASCII letters/digits stay, UTF-8 bytes of anything else are %XX.
    private static string EscapeAlphanumerics(string value)
    {
        var sb = new StringBuilder(value.Length);
        Span<byte> buf = stackalloc byte[4];
        foreach (var rune in value.EnumerateRunes())
        {
            if (Rune.IsLetterOrDigit(rune)) sb.Append(rune);
            else
            {
                var len = rune.EncodeToUtf8(buf);
                for (var i = 0; i < len; i++) sb.Append('%').Append(buf[i].ToString("X2", CultureInfo.InvariantCulture));
            }
        }
        return sb.ToString();
    }

    /// An empty tab (nothing to show).
    public static bool IsBlank(string url) =>
        string.IsNullOrEmpty(url) || url == "about:blank" || url.StartsWith("chrome://newtab", StringComparison.Ordinal);
}

/// What the gateway's plugin can do: watch and take over (protocol 3), an older plugin that needs replacing, none, or
/// a current one that switched itself off because Hermes changed under it (`Drift`: reinstalling it can't help).
public enum BrowserSetup { Ready, Missing, Update, Drift }

public static class BrowserHealth
{
    private static readonly Regex ErrorName = new(
        @"\s*\((?:[A-Za-z_][\w.]*)?(?:Error|Exception|Warning)\b[^()]*\)",
        RegexOptions.CultureInvariant);

    public const string PopupsOfferKey = "browser.popupsUpdateOffered";

    public static BrowserSetup Setup(JsonNode? health)
    {
        var current = BrowserJson.Int(health, "protocol") == BrowserWire.ProtocolVersion;
        if (BrowserJson.Bool(health, "installed") == true)
            return current && BrowserJson.Bool(health?.Get("features"), "control") == true ? BrowserSetup.Ready : BrowserSetup.Update;
        if (current && !HasMissing(health) && health?.Get("drift") is JsonArray { Count: > 0 })
            return BrowserSetup.Drift;
        return BrowserJson.Double(health, "protocol") != null ? BrowserSetup.Update : BrowserSetup.Missing;
    }

    private static bool HasMissing(JsonNode? health)
    {
        if (health is not JsonObject o || !o.TryGetPropertyValue("missing", out var v) || v == null) return false;
        return v switch
        {
            JsonValue jv when jv.GetValueKind() == JsonValueKind.Null => false,
            JsonValue jv when jv.GetValueKind() == JsonValueKind.String => !string.IsNullOrWhiteSpace(jv.GetValue<string>()),
            JsonArray arr => arr.Count > 0,
            _ => true,
        };
    }

    /// The add-on's own words for what Hermes changed: trimmed, joined and capped, without Python error names in brackets.
    public static string? DriftWords(JsonNode? health, int limit = 240)
    {
        if (health?.Get("drift") is not JsonArray list) return null;
        var items = new List<string>();
        foreach (var item in list)
        {
            if (BrowserJson.AsString(item) is not { } said) continue;
            var words = ErrorName.Replace(said, "").Trim();
            if (words.Length > 0) items.Add(words);
        }
        var joined = string.Join("; ", items);
        while (joined.EndsWith('.')) joined = joined[..^1];
        if (joined.Length > limit) joined = joined[..(limit - 1)].TrimEnd() + "\u2026";
        return joined.Length == 0 ? null : joined;
    }

    public static bool OffersChoice(JsonNode? health) => BrowserJson.Bool(health?.Get("features"), "choice") == true;
    public static bool OffersCloud(JsonNode? health) => BrowserJson.Bool(health?.Get("features"), "cloud") == true;
    public static bool KnowsHosted(JsonNode? health) => BrowserJson.Bool(health?.Get("features"), "hosted") == true;
    public static bool Hosted(JsonNode? health) => BrowserJson.Bool(health, "hosted") == true;
    public static bool OffersCloudForAll(JsonNode? health) =>
        OffersCloud(health) && BrowserJson.Bool(health?.Get("features"), "cloud_all") == true;
    public static bool RelaysPopups(JsonNode? health) => BrowserJson.Bool(health?.Get("features"), "dialogs") == true;

    /// The version to offer an update for: a working add-on that can't send popups, not offered already. Else null.
    public static string? PopupsUpdate(JsonNode? health, string? offered)
    {
        if (Setup(health) != BrowserSetup.Ready || RelaysPopups(health)) return null;
        var version = BrowserJson.Prefix(BrowserJson.Str(health, "version") ?? "older", 40);
        return version == offered ? null : version;
    }
}

public enum BrowserAddOnNeed { Outdated, Off }

public static class BrowserAddOn
{
    public const string WantedVersion = "3.10.0";

    /// "3.10.0" >= "3.9.0" (numbers, not text); a missing part counts as 0 and an unreadable version as too old.
    public static bool VersionAtLeast(string version, string minimum)
    {
        static int[]? Parts(string text)
        {
            var trimmed = text.Trim();
            if (trimmed.Length == 0) return null;
            var pieces = trimmed.Split('.');
            var out_ = new int[pieces.Length];
            for (var i = 0; i < pieces.Length; i++)
            {
                if (!int.TryParse(pieces[i], NumberStyles.None, CultureInfo.InvariantCulture, out var n)) return null;
                out_[i] = n;
            }
            return out_;
        }
        var have = Parts(version);
        var need = Parts(minimum);
        if (have == null || need == null) return false;
        var max = Math.Max(have.Length, need.Length);
        for (var i = 0; i < max; i++)
        {
            var a = i < have.Length ? have[i] : 0;
            var b = i < need.Length ? need[i] : 0;
            if (a != b) return a > b;
        }
        return true;
    }

    public static BrowserAddOnNeed? Need(JsonNode? health)
    {
        if (BrowserJson.Int(health, "protocol") != BrowserWire.ProtocolVersion) return null;
        if (VersionAtLeast(Version(health), WantedVersion)) return null;
        return BrowserHealth.Setup(health) == BrowserSetup.Drift ? BrowserAddOnNeed.Off : BrowserAddOnNeed.Outdated;
    }

    public static string Version(JsonNode? health) =>
        BrowserJson.Prefix((BrowserJson.Str(health, "version") ?? "").Trim(), 40);

    public static bool IsOn(JsonNode? health) =>
        VersionAtLeast(Version(health), WantedVersion)
        && BrowserJson.Bool(health, "installed") == true
        && (health?.Get("drift") is not JsonArray { Count: > 0 });

    public static bool Restarted(JsonNode? health) => VersionAtLeast(Version(health), WantedVersion);
}

/// A bot's own Chrome as `/bots` lists it (plugin 3.3+).
public sealed record OwnBrowser(string Status, string? Error = null)
{
    public static OwnBrowser? Parse(JsonNode? value, string profile)
    {
        if (value is not JsonObject || BrowserJson.Str(value, "schema") != "dispatch-browser.bots.v1") return null;
        if (value["bots"] is not JsonArray bots) return null;
        var bot = bots.FirstOrDefault(b => BrowserJson.Str(b, "profile") == profile);
        var status = BrowserJson.Prefix(BrowserJson.Str(bot, "status") ?? "unknown", 40);
        var error = BrowserJson.Str(bot, "error") is { Length: > 0 } err ? BrowserJson.Prefix(err, 300) : null;
        return new OwnBrowser(status, error);
    }
}

public enum BrowserEmptyAction { Plugins, Update }

/// What the viewer says while a bot has no browser to show.
public sealed record BrowserEmptyCopy(string Title, string Body, bool Waiting = false, BrowserEmptyAction? Action = null)
{
    public const string UpdateButton = "Update the Add\u2011on";

    /// `known`: false = not asked yet (loading); `own == null` when `known` is true = older plugin (no `/bots`).
    public static BrowserEmptyCopy NoBrowser(bool known, OwnBrowser? own, string name)
    {
        var status = !known ? "loading" : own == null ? "older" : own.Status;
        var error = known ? own?.Error : null;
        return status switch
        {
            "ready" or "starting" or "external" or "unknown" or "loading" =>
                new($"Opening {name}’s Browser", "It shows here in a moment.", Waiting: true),
            "not_responding" =>
                new($"{name}’s Browser Isn’t Responding", "It restarts on its own within a minute.", Waiting: true),
            "no_chrome" =>
                new("Chrome Isn’t Installed",
                    $"{name} needs Google Chrome on {HostWord.Phrase} for a browser you can watch. On that computer, download it from google.com/chrome; once it’s installed, {name}’s browser starts by itself."),
            "port_taken" or "no_port" =>
                new($"{name}’s Browser Can’t Start",
                    error != null
                        ? $"Another app on {HostWord.Phrase} is using what {name}’s browser needs. Once it’s free, the browser starts by itself.\n\n{error}"
                        : $"Another app on {HostWord.Phrase} is using what {name}’s browser needs. Once it’s free, the browser starts by itself."),
            "config_error" =>
                new($"{name}’s Browser Can’t Start",
                    $"{name}’s settings file on {HostWord.Phrase} has a mistake in it. Once it’s fixed, the browser starts by itself."),
            "camofox" =>
                new("Browser Can’t Be Shown", $"{name} uses Camofox, a browser Hermes HQ can’t show."),
            "remote" or "fixed" =>
                new("Browser Can’t Be Shown", $"{name} is connected to a browser Hermes HQ can’t reach."),
            "real_profile" =>
                new("No Browser Open",
                    $"{name} browses with a copy of your browser profile that Hermes opens for each task. When it opens a page, you’ll see it here."),
            "released" =>
                new("No Browser of Its Own",
                    $"{name}’s browser was set up by hand, so Hermes HQ leaves it alone. When it opens a page Hermes HQ can show, you’ll see it here."),
            "off" =>
                new("Browser Watching Is Off",
                    $"The browser add-on is turned off in {name}’s plugins. Turn it on there to watch {name}’s browser here.",
                    Action: BrowserEmptyAction.Plugins),
            "older" =>
                new("No Browser Open",
                    $"When {name} opens a web page, you’ll see it here live. Update the browser add-on and every bot keeps a browser of its own, ready to watch any time."),
            _ =>
                new("No Browser Open", $"When {name} opens a web page, you’ll see it here live."),
        };
    }

    public static BrowserEmptyCopy AddOnOff(JsonNode? health)
    {
        const string lead = "This version of Hermes changed something the browser add\u2011on needs";
        var what = BrowserHealth.DriftWords(health) is { } words ? $"{lead}: {words}." : $"{lead}.";
        if (BrowserAddOn.Need(health) != BrowserAddOnNeed.Off)
        {
            return new("Browser Add\u2011on Is Off",
                $"{what} Reinstalling won’t help \u2014 an add\u2011on update for this Hermes is on the way.");
        }
        return new("Browser Add\u2011on Is Off",
            $"{what} Add\u2011on {BrowserAddOn.WantedVersion} fixes this. Update it to watch your bots’ browsers again.",
            Action: BrowserEmptyAction.Update);
    }
}

public enum PendingTypingOutcome { First, Kept, Full, Ignored }

/// Typing the person entered while the watch socket was away, in order, sent once it is back.
public sealed class PendingTyping
{
    private readonly List<BrowserInput> _items = [];
    public int Limit { get; }

    public PendingTyping(int limit = 400) => Limit = limit;

    public bool IsEmpty => _items.Count == 0;
    public IReadOnlyList<BrowserInput> Items => _items;

    public PendingTypingOutcome Add(BrowserInput input)
    {
        if (!input.IsTyping) return PendingTypingOutcome.Ignored;
        if (_items.Count >= Limit) return PendingTypingOutcome.Full;
        _items.Add(input);
        return _items.Count == 1 ? PendingTypingOutcome.First : PendingTypingOutcome.Kept;
    }

    public List<BrowserInput> Take()
    {
        var out_ = new List<BrowserInput>(_items);
        _items.Clear();
        return out_;
    }

    public void Clear() => _items.Clear();
}

public static class BrowserReconnect
{
    /// 1, 2, 4, 8, 10, 10… seconds.
    public static double Delay(int attempt) => Math.Min(10.0, Math.Pow(2.0, Math.Max(0, attempt - 1)));
}

public static class BrowserLinkRule
{
    /// The gateway link came back: left Offline, or the main socket is open again after any drop.
    public static bool Restored(ConnectionState old, ConnectionState @new) => @new switch
    {
        ConnectionState.SignedOut or ConnectionState.Offline => false,
        ConnectionState.Open => old != ConnectionState.Open,
        ConnectionState.Connecting => old == ConnectionState.Offline,
        _ => false,
    };

    /// A viewer's socket dials now only while it waits to retry: one that is live, or a dial already asking for its
    /// address (no socket yet and no retry pending), is left alone, so two sockets never race.
    public static bool WatchDialsNow(bool shown, bool stopped, bool ended, bool hasSocket, bool retrying) =>
        shown && !stopped && !ended && !hasSocket && retrying;
}

public static class BrowserMenuRule
{
    public const string Title = "Watch Browser";

    public static (string? Subtitle, bool Disabled) ChatItem(bool offline) =>
        offline ? ("Offline", true) : (null, false);
}

/// What asking for a viewer does while one is already up (App/Mac/MacPaneViewer.swift `ViewerReopen`).
public enum BrowserViewerReopen { Open, Ignore, Front, Replace }

public static class BrowserViewerReopenRule
{
    public static BrowserViewerReopen Decide(string? shown, bool leaving, string asked, bool ownWindow)
    {
        if (shown == null) return BrowserViewerReopen.Open;
        if (!ownWindow || leaving) return BrowserViewerReopen.Ignore;
        return shown == asked ? BrowserViewerReopen.Front : BrowserViewerReopen.Replace;
    }
}

/// The request the main bot gets to install or update the browser plugin (BrowserSetupPrompt + MainBotRequest).
public static class BrowserSetupPrompt
{
    public const string Source = "mrcharlesiv/hermes-hq-plugins/hermes-hq-browser";
    public const string InstallTitle = "Install the Hermes HQ browser add-on on this Hermes.";
    public const string UpdateTitle = "Update the Hermes HQ browser add-on on this Hermes.";

    public static string NoMainBot => $"Couldn’t find the main bot on {HostWord.Phrase}. Open Bots and try again.";
    public const string CouldNotSend = "Couldn’t send the request to the bot. Try again.";

    public const string Text = """
        Please install Hermes HQ's browser plugin on this Hermes, so I can watch a bot's browser from this PC and take it over when it needs me. Do it yourself with your terminal tools; ask me only for what you can't do.

        1. This plugin used to be called dispatch-browser. If hermes plugins list shows dispatch-browser for the main profile, remove it first so two copies never both run: note which platform_toolsets lists in the main config.yaml include browser, run hermes plugins remove dispatch-browser, and if that took browser out of any of those lists, put it back. Leave its copies in other profiles alone: the new plugin switches them off itself and keeps each bot's browser.

        2. Install it once, for the main profile: run hermes plugins install mrcharlesiv/hermes-hq-plugins/hermes-hq-browser --enable. Once the server restarts, the plugin adds itself to every other bot profile (and to bots made later) and gives each bot a Chrome of its own, so don't install it per profile. If it says hermes-hq-browser is already installed, run the same command again with --force added, to replace the older copy. If Hermes's security scan blocks the install, stop and show me what it found. Don't work around the scan.

        3. An older test version of this plugin replaced the bots' browser tools with a Chrome extension. If any config.yaml on this computer (the main one and each profile's) has plugins.entries.dispatch-browser.granted_capabilities, remove that entry, and if its browser.backend is 'off', ask me what it was before changing it. Leave everything else in those files alone.

        4. Check it: hermes plugins list --enabled must list hermes-hq-browser, version 3.4 or newer, and not dispatch-browser. Each bot's browser is a headless Google Chrome (or Chromium): if neither is installed on this computer, tell me.

        5. Hermes loads a plugin's web routes only when its web server starts, and its hooks when a gateway starts, so restart the server Hermes HQ connects to (hermes dashboard or hermes serve) and the messaging gateway if one runs. Find how each runs first (whether a launchd, systemd or other service manages it), then restart it the same way, keeping its arguments and profile. Restarting ends this chat's connection for a moment, so tell me before you do it, and schedule the restart in the background to start about 15 seconds after your reply, so it survives this chat (for example nohup sh -c 'sleep 15; <restart command>' >/dev/null 2>&1 &). It must run exactly once: never schedule it with launchctl submit, a LaunchAgent, cron, a systemd timer or anything else that starts it again, because a restart that repeats keeps Hermes down and locks me out. Don't restart anything else.

        When you're done, tell me in a sentence or two what you did.
        """;

    public const string Update = """
        Please update Hermes HQ's browser plugin (hermes-hq-browser) on this Hermes to version 3.10.0 or newer, so popups, sign-in windows and boxes a page shows reach this PC when I take over a bot's browser. Do it yourself with your terminal tools; ask me only for what you can't do.

        1. Update it for the main profile only: run hermes plugins update hermes-hq-browser. If that can't update it, run hermes plugins install mrcharlesiv/hermes-hq-plugins/hermes-hq-browser --enable --force instead. Once the server restarts, the plugin copies itself to every other bot profile, so don't update it per profile. If Hermes's security scan blocks it, stop and show me what it found. Don't work around the scan.

        2. Check it: hermes plugins list --enabled must list hermes-hq-browser, version 3.10.0 or newer.

        3. Hermes loads a plugin's web routes only when its web server starts, so restart the server Hermes HQ connects to (hermes dashboard or hermes serve). Find how it runs first (whether a launchd, systemd or other service manages it), then restart it the same way, keeping its arguments and profile. Restarting ends this chat's connection for a moment, so tell me before you do it, and schedule the restart in the background to start about 15 seconds after your reply, so it survives this chat (for example nohup sh -c 'sleep 15; <restart command>' >/dev/null 2>&1 &). It must run exactly once: never schedule it with launchctl submit, a LaunchAgent, cron, a systemd timer or anything else that starts it again, because a restart that repeats keeps Hermes down and locks me out. Don't restart anything else.

        When you're done, tell me in a sentence or two what you did.
        """;
}

/// Strict JSON reads, matching HermesKit's JSONValue accessors.
internal static class BrowserJson
{
    public static string? AsString(JsonNode? node) =>
        node is JsonValue v && v.GetValueKind() == JsonValueKind.String ? v.GetValue<string>() : null;

    public static string? Str(JsonNode? node, string key) =>
        node is JsonObject o && o.TryGetPropertyValue(key, out var v) ? AsString(v) : null;

    public static bool? Bool(JsonNode? node, string key) =>
        node is JsonObject o && o.TryGetPropertyValue(key, out var v) && v is JsonValue jv
            ? jv.GetValueKind() switch { JsonValueKind.True => true, JsonValueKind.False => false, _ => null }
            : null;

    public static double? Double(JsonNode? node, string key)
    {
        if (node is not JsonObject o || !o.TryGetPropertyValue(key, out var v) || v is not JsonValue jv) return null;
        return jv.GetValueKind() switch
        {
            JsonValueKind.Number => jv.GetValue<double>(),
            JsonValueKind.String when double.TryParse(jv.GetValue<string>(), NumberStyles.Float, CultureInfo.InvariantCulture, out var d) => d,
            _ => null,
        };
    }

    public static int? Int(JsonNode? node, string key) =>
        Double(node, key) is { } d && double.IsFinite(d) && d is >= int.MinValue and <= int.MaxValue ? (int)d : null;

    public static string Prefix(string text, int max) => text.Length <= max ? text : text[..max];
}
