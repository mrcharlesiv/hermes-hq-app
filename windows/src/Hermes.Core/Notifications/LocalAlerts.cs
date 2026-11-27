using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Model;
using Hermes.Core.Questions;
using Hermes.Core.Rpc;
using Hermes.Core.Settings;

namespace Hermes.Core.Notifications;

/// The small routing rules an alert follows (HermesKit/Push/NotificationPrefs.swift NotificationRules).
public static partial class NotificationRules
{
    /// A stored or runtime session id an alert may name (letters, digits, - and _; at most 160).
    public static bool Valid(string? session) => !string.IsNullOrEmpty(session) && session.Length <= 160 && IdShape().IsMatch(session);

    /// Like Messages: away, every reply alerts; in the app, everything but the chat on screen.
    public static bool ShouldPost(string session, bool active, string? viewing, string? viewingStored) =>
        !active || (session != viewing && session != viewingStored);

    /// The preference a gateway kind names (NotificationPrefs.preference).
    public static string Preference(string kind) => kind == "approval.request" ? "approval" : kind == "message.complete" ? "turnDone" : kind;

    /// Per-bot Mute quiets these kinds; approvals and failures still alert (Shared/BotMutes.swift `silenced`).
    public static bool Silenced(string kind) => kind is "message.complete" or "turnDone" or "backgroundDone";

    [GeneratedRegex("^[A-Za-z0-9_-]+$")]
    private static partial Regex IdShape();
}

/// How a turn ended, as its alert tells it (App/Notifications/AppModel+Notifications.swift notificationsTurnEnded): a
/// finished reply's text (at most 4000 characters) or why it failed, in a few words.
public sealed record TurnEnd(bool Failed, string Text)
{
    /// `message.complete` or `error` from the gateway socket; null for any other frame.
    public static TurnEnd? From(RpcEvent e)
    {
        if (e.Type is not ("message.complete" or "error")) return null;
        var p = e.Payload;
        var failed = e.Type == "error" || Str(p, "status") == "error";
        if (failed)
        {
            var surface = p?["error_surface"];
            var error = Str(p, "error") ?? Str(p, "message") ?? Str(p, "text") ?? "";
            return new(true, NotificationText.ErrorReason(error, code: Str(surface, "code"),
                provider: Str(surface, "provider_label") ?? Str(surface, "provider")));
        }
        return new(false, NotificationText.Prefix(Str(p, "text") ?? Str(p, "rendered") ?? "", 4000));
    }

    private static string? Str(JsonNode? n, string key) =>
        n is JsonObject o && o[key] is JsonValue v && v.TryGetValue(out string? s) ? s : null;
}

/// Who a chat's alerts are from (NotificationHub.Entry): the words' sender, its stored id (the thread), its bot.
public sealed record LocalAlertEntry(NotificationWho Who, string Stored, string Profile);

/// Who a chat's alerts are from (AppModel+Notifications.swift notificationEntry): a bot's own chat is from the bot
/// (titled by its name); any other chat is the chat's own title, from its bot.
public static class NotificationDirectory
{
    public static LocalAlertEntry? Entry(string profile, string stored, string title, IReadOnlyList<Bot>? bots)
    {
        if (!NotificationRules.Valid(stored)) return null;
        var bot = bots?.FirstOrDefault(b => b.Name == profile);
        var isBotChat = bot != null && (bot.Canonical is not { } c || c.Id == stored || c.OpenId == stored);
        return new(new NotificationWho(bot?.DisplayName ?? "", isBotChat ? "" : title, "", isBotChat), stored, profile);
    }
}

/// One local toast, ready for the platform to show (the Mac's UNMutableNotificationContent plus its request id).
/// `SuppressDisplay`: straight into Notification Center without a banner — the Mac's `[.list, .sound]` while the app
/// is in front and Bot Activity Banners shows its own in-app peek instead.
public sealed record LocalToast(string Id, string Kind, string Tag, string Group, string Title, string Subtitle, string Body,
    IReadOnlyList<KeyValuePair<string, string>> Arguments, bool SuppressDisplay, int Epoch)
{
    /// Its buttons (the Mac's category actions): a local approval's Approve Once and Deny, nothing otherwise.
    public IReadOnlyList<ToastButton> Buttons { get; init; } = [];

    /// [groups] The bot profile whose face the alert wears (AppModel+Notifications.swift peekFace): for a room's alert
    /// the member who spoke last (GroupsHub.alertSpeaker), else the room's mute key; empty for a chat's own alert.
    public string Face { get; init; } = "";

    /// Windows caps a toast's tag and group at 64 characters: an id that fits is kept as it is, a longer one becomes a
    /// stable digest of it (so the same chat always lands in the same group).
    public static string Key(string raw)
    {
        if (raw.Length <= 64) return raw;
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(raw));
        return "h" + Convert.ToHexStringLower(hash)[..40];
    }
}

/// One button on a toast: the Windows equivalent of a UNNotificationAction. Windows has no notification categories, so
/// the Mac's DISPATCH_APPROVAL_LOCAL category (actions "approve" titled "Approve Once" and "deny" titled "Deny", both
/// opening the app to answer) becomes two toast buttons; a click on one brings back only its own arguments, so each
/// carries the toast's arguments plus `action`.
public sealed record ToastButton(string Title, IReadOnlyList<KeyValuePair<string, string>> Arguments);

/// What `ObserveTurnEnd` decided: a toast, or why not (for the log; never the text).
public sealed record AlertDecision(LocalToast? Toast, string Skipped)
{
    public static AlertDecision Skip(string why) => new(null, why);
}

/// Local alerts raised from the gateway socket for every chat but the one on screen (NotificationHub.observeTurnEnd,
/// post and present, Messages rules), for a finished or failed reply. The platform supplies what it knows about the
/// window and the person's switches; this decides whether a toast goes up, with which words, in which thread.
public sealed class LocalAlerts(Func<NotificationPrefs> prefs, Func<bool> banners, Func<string, bool> muted, Func<bool> inFront,
    Func<bool> active)
{
    private readonly object _gate = new();
    private readonly HashSet<string> _seen = [];
    private readonly Queue<string> _order = new();

    /// The chat on screen (null on a list), by runtime id and by stored id.
    public string? Viewing { get; private set; }
    public string? ViewingStored { get; private set; }
    public int Epoch { get; private set; }

    public void Focus(string? runtime, string? stored)
    {
        lock (_gate) { Viewing = runtime; ViewingStored = stored; }
    }

    /// Signed out or another gateway: what was seen and anything mid-post belong to the old sign-in.
    public void Clear()
    {
        lock (_gate)
        {
            Epoch++;
            _seen.Clear();
            _order.Clear();
            Viewing = ViewingStored = null;
        }
    }

    /// Codex N11: a toast decided under one sign-in posts only while it is still the current one.
    public bool MayPost(LocalToast toast) { lock (_gate) return toast.Epoch == Epoch; }

    /// A finished (`failed` false: the reply's text) or failed (the reason) turn of a chat this run opened.
    public AlertDecision ObserveTurnEnd(string runtime, long? seq, bool failed, string text, LocalAlertEntry? entry)
    {
        var kind = failed ? "turnError" : "message.complete";
        var id = $"{runtime}:{(seq is { } s ? s.ToString(System.Globalization.CultureInfo.InvariantCulture) : Stable(text))}:{kind}";
        string? viewing, viewingStored;
        int epoch;
        lock (_gate)
        {
            if (!Remember(id)) return AlertDecision.Skip("already alerted");
            viewing = Viewing;
            viewingStored = ViewingStored;
            epoch = Epoch;
        }
        var session = entry?.Stored ?? runtime;
        if (!NotificationRules.ShouldPost(session, active(), viewing ?? viewingStored, viewingStored) || runtime == viewing)
            return AlertDecision.Skip("chat on screen");
        var shown = failed ? text : NotificationText.Preview(text);

        // post(kind:…)
        var p = prefs();
        if (!p.Allows(NotificationRules.Preference(kind))) return AlertDecision.Skip("preference off");
        if (NotificationRules.Silenced(kind) && entry is { Profile.Length: > 0 } && muted(entry.Profile)) return AlertDecision.Skip("muted");
        var copy = NotificationText.Notification(kind, entry?.Who, shown, previews: p.Previews);
        var stored = entry?.Stored ?? session;
        var args = new List<KeyValuePair<string, string>>
        {
            new("session", session), new("stored", stored), new("request", ""), new("kind", kind), new("profile", entry?.Profile ?? ""),
        };

        // present(_:): only the frontmost app counts as looking; there another chat's finished reply is the app's own
        // notice (the peek) and the system keeps it in the list. A failure keeps the banner.
        var looking = inFront();
        var quiet = kind == "message.complete" && looking && banners();
        return new(new LocalToast(id, kind, LocalToast.Key(id), LocalToast.Key(stored), copy.Title, copy.Subtitle, copy.Body, args, quiet, epoch), "");
    }

    /// [groups] A room member's finished reply while its room is off screen (App/Groups/AppModel+Groups.swift
    /// GroupsHub.replied → NotificationHub.post(kind: "message.complete", session:, id:, text:, entry:)): `session` is
    /// the room's alert id (GroupsHub.alertId), `id` the request id (`room:<entry id or time>`), `text` the reply's
    /// preview, `entry` the room's who with its mute key as profile, `face` the profile whose face it wears (peekFace:
    /// the member who spoke). The room on screen is the caller's to leave out (RoomAlerts.Replied): no chat's viewing
    /// state applies, since a room alert's session is never a chat's.
    public AlertDecision ObserveRoomReply(string session, string id, string text, LocalAlertEntry entry, string face)
    {
        const string kind = "message.complete";
        int epoch;
        lock (_gate)
        {
            if (!Remember(id)) return AlertDecision.Skip("already alerted");
            epoch = Epoch;
        }
        var p = prefs();
        if (!p.Allows(NotificationRules.Preference(kind))) return AlertDecision.Skip("preference off");
        // The room's mute, not the member's: the entry's profile is the room's mute key.
        if (NotificationRules.Silenced(kind) && entry.Profile.Length > 0 && muted(entry.Profile)) return AlertDecision.Skip("muted");
        var copy = NotificationText.Notification(kind, entry.Who, text, previews: p.Previews);
        var stored = entry.Stored;
        var args = new List<KeyValuePair<string, string>>
        {
            new("session", session), new("stored", stored), new("request", ""), new("kind", kind), new("profile", entry.Profile),
        };
        // present(_:): in front with Bot Activity Banners on, the reply is the app's own notice and the system lists it.
        var quiet = inFront() && banners();
        return new(new LocalToast(id, kind, LocalToast.Key(id), LocalToast.Key(stored), copy.Title, copy.Subtitle, copy.Body, args, quiet, epoch)
            { Face = face }, "");
    }

    /// The tag of a held request's toast (the Mac's request identifier `request-<id>`): what goes once it is answered
    /// anywhere, withdrawn or expired (withdrawLocal, UX study #257).
    public static string RequestTag(string requestId) => LocalToast.Key("request-" + requestId);

    /// A request the app holds for a chat (approval, question, password; NotificationHub.observeRequest): it alerts when
    /// that chat isn't on screen. An approval whose whole command shows offers Approve Once and Deny; a question or a
    /// password only opens its chat. Per-bot Mute leaves these alone (approvals still alert).
    public AlertDecision ObserveRequest(string id, PromptKind kind, string runtime, JsonObject? parameters, LocalAlertEntry? entry)
    {
        string? viewing, viewingStored;
        int epoch;
        lock (_gate)
        {
            if (!Remember("request:" + id)) return AlertDecision.Skip("already alerted");
            viewing = Viewing;
            viewingStored = ViewingStored;
            epoch = Epoch;
        }
        var kindName = kind == PromptKind.Approval ? "approval.request" : "input";
        var session = entry?.Stored ?? runtime;
        if (!NotificationRules.ShouldPost(session, active(), viewing ?? viewingStored, viewingStored) || runtime == viewing)
            return AlertDecision.Skip("chat on screen");
        string text, about;
        switch (kind)
        {
            case PromptKind.Approval:
                text = NotificationText.CommandSummary(Str(parameters, "command") ?? "");
                about = NotificationText.Preview(Str(parameters, "description") ?? "");
                break;
            case PromptKind.Clarify:
                var first = parameters?["questions"] is JsonArray { Count: > 0 } qs ? Str(qs[0], "question") : null;
                text = NotificationText.Preview(first ?? Str(parameters, "question") ?? "");
                about = "";
                break;
            default:
                text = NotificationText.Preview(NotificationText.ValueRequestLine(kind, parameters));
                about = "";
                break;
        }
        var request = kind == PromptKind.Approval ? id : "";

        // post(kind:…)
        var p = prefs();
        if (!p.Allows(NotificationRules.Preference(kindName))) return AlertDecision.Skip("preference off");
        if (NotificationRules.Silenced(kindName) && entry is { Profile.Length: > 0 } && muted(entry.Profile)) return AlertDecision.Skip("muted");
        var copy = NotificationText.Notification(kindName, entry?.Who, text, body: about, previews: p.Previews);
        var stored = entry?.Stored ?? session;
        var args = new List<KeyValuePair<string, string>>
        {
            new("session", session), new("stored", stored), new("request", request), new("kind", kindName), new("profile", entry?.Profile ?? ""),
        };
        var command = kind == PromptKind.Approval ? NotificationText.CommandSummary(text) : "";
        IReadOnlyList<ToastButton> buttons = p.Previews && NotificationText.Approvable(command) && NotificationRules.Valid(session) && request.Length > 0
            ? [new("Approve Once", [.. args, new("action", "approve")]), new("Deny", [.. args, new("action", "deny")])]
            : [];
        var toastId = "request-" + id;
        // present(_:): a question or an approval keeps the banner even in front.
        return new(new LocalToast(toastId, kindName, LocalToast.Key(toastId), LocalToast.Key(stored), copy.Title, copy.Subtitle, copy.Body,
            args, false, epoch) { Buttons = buttons }, "");
    }

    private static string? Str(JsonNode? n, string key) =>
        n is JsonObject o && o[key] is JsonValue v && v.TryGetValue(out string? s) ? s : null;

    private bool Remember(string key)
    {
        if (!_seen.Add(key)) return false;
        _order.Enqueue(key);
        if (_order.Count > 512) _seen.Remove(_order.Dequeue());
        return true;
    }

    private static string Stable(string text) =>
        Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(text)))[..16];
}

/// A toast's arguments as one string: `key=value;key=value`, with `%`, `;` and `=` escaped (the Windows App SDK's own
/// AppNotificationBuilder.AddArgument form, which `AppNotificationActivatedEventArgs.Argument` brings back).
public static class NotificationArguments
{
    public static string Encode(IEnumerable<KeyValuePair<string, string>> pairs) =>
        string.Join(";", pairs.Select(kv => Escape(kv.Key) + "=" + Escape(kv.Value)));

    public static IReadOnlyList<KeyValuePair<string, string>> Decode(string? raw)
    {
        var list = new List<KeyValuePair<string, string>>();
        if (string.IsNullOrEmpty(raw)) return list;
        foreach (var part in raw.Split(';'))
        {
            if (part.Length == 0) continue;
            var eq = part.IndexOf('=');
            list.Add(eq < 0 ? new(Unescape(part), "") : new(Unescape(part[..eq]), Unescape(part[(eq + 1)..])));
        }
        return list;
    }

    private static string Escape(string s) => s.Replace("%", "%25").Replace(";", "%3B").Replace("=", "%3D");
    private static string Unescape(string s) => s.Replace("%3B", ";").Replace("%3b", ";").Replace("%3D", "=").Replace("%3d", "=").Replace("%25", "%");
}

/// The chat a tapped alert opens (NotificationRules.target): its stored id when it carries a valid one, else its
/// session, and the bot profile when known.
public sealed record NotificationTarget(string Stored, string? Profile)
{
    public static NotificationTarget? From(IEnumerable<KeyValuePair<string, string>> args)
    {
        var map = new Dictionary<string, string>();
        foreach (var (k, v) in args) map[k] = v;
        var session = map.GetValueOrDefault("session");
        var stored = map.GetValueOrDefault("stored") is { } st && NotificationRules.Valid(st) ? st
            : NotificationRules.Valid(session) ? session : null;
        if (stored == null) return null;
        var profile = map.GetValueOrDefault("profile");
        return new(stored, string.IsNullOrEmpty(profile) ? null : profile);
    }
}

/// What a click on a toast asks for (NotificationHub.respond): the chat it opens, and for a local approval's Approve Once
/// or Deny the request and the choice. The Mac's local actions open the app (`.foreground`), answer, then open the chat.
public sealed record NotificationResponse(NotificationTarget? Target, string? Request, bool? Approve)
{
    public static NotificationResponse From(IEnumerable<KeyValuePair<string, string>> args)
    {
        var list = args.ToList();
        var map = new Dictionary<string, string>();
        foreach (var (k, v) in list) map[k] = v;
        var action = map.GetValueOrDefault("action");
        var request = map.GetValueOrDefault("request");
        var answers = action is "approve" or "deny" && !string.IsNullOrEmpty(request);
        return new(NotificationTarget.From(list), answers ? request : null, answers ? action == "approve" : null);
    }
}

/// An Approve Once / Deny that came before the signed-in app could answer it waits here (NotificationHub
/// `pendingAnswer`, one at a time as there), and goes as soon as there is something to answer it with.
public sealed class LocalAnswerQueue
{
    private readonly object _gate = new();
    private (string Request, bool Approve)? _pending;
    private Action<string, bool>? _answer;

    public void Answered(string request, bool approve)
    {
        Action<string, bool>? answer;
        lock (_gate)
        {
            answer = _answer;
            if (answer == null) _pending = (request, approve);
        }
        answer?.Invoke(request, approve);
    }

    /// The app can answer now (null: it can't any more, e.g. signed out).
    public void Ready(Action<string, bool>? answer)
    {
        (string Request, bool Approve)? waiting;
        lock (_gate)
        {
            _answer = answer;
            waiting = answer != null ? _pending : null;
            if (waiting != null) _pending = null;
        }
        if (waiting is { } w) answer!(w.Request, w.Approve);
    }

    public (string Request, bool Approve)? TakePending()
    {
        lock (_gate)
        {
            var p = _pending;
            _pending = null;
            return p;
        }
    }
}

/// What the app says after Approve Once / Deny on a local alert (HermesKit/Model/LocalApprovalWords.swift, UX study
/// #138, #256, #259): sent, gone, or not sent (the card in the chat is open again, so the words point there).
public static class LocalApprovalWords
{
    /// The card's own buttons (UX study #259: it has Run and Reject, not the alert's Approve and Deny).
    public static readonly string NotSent = $"Your answer didn’t reach Hermes. {Hermes.Core.Transcripts.TranscriptWords.Tap} Run or Reject on the card in the chat to try again.";
    /// [#256] The request wasn't there to answer: the push plugin's own words for a resolved request.
    public const string Gone = "That request was already answered or had expired.";
    public static string Sent(bool approve) => approve ? "Approved" : "Denied";
    public static string Title(bool approve) => approve ? "Couldn’t Approve" : "Couldn’t Deny";

    /// Offline: the center's own sentence (it already says to reconnect and send again); anything else: NotSent.
    public static string Reason(Exception error) => error is PromptAnswerException { Offline: true } a ? a.Message : NotSent;
}

/// A chat the Sessions list shows: whose it is and its title.
public sealed record ListedChat(string Profile, string Title);

/// Where a tap goes: a bot (`Bot` set: its own chat) or a chat by profile and stored id.
public sealed record ChatRoute(string Profile, string StoredId, string Title, string? Bot);

/// App/Notifications/AppModel+Notifications.swift openNotifiedChat: the bot's own chat from Bots, another chat from
/// Sessions (a bot with no chat of its own yet opens as that bot); nothing when no bot can open it.
public static class NotificationOpen
{
    /// [groups] A room's alert names the room in its profile (`room:<room key>`): the room opens, not a member's chat
    /// (openNotifiedChat). The room's key, or null for any other alert.
    public static string? RoomKey(NotificationTarget target) =>
        target.Profile is { } profile && profile.StartsWith("room:", StringComparison.Ordinal) ? profile[5..] : null;

    public static ChatRoute? Route(NotificationTarget target, IReadOnlyList<Bot> bots, Func<string, ListedChat?> listed)
    {
        var stored = target.Stored;
        var own = bots.FirstOrDefault(b => b.Canonical is { } c && (c.Id == stored || c.OpenId == stored));
        var bot = own ?? (target.Profile is { } name ? bots.FirstOrDefault(b => b.Name == name && b.Canonical == null) : null);
        if (bot != null) return new(bot.Name, stored, bot.DisplayName, bot.Name);
        var session = listed(stored);
        var profile = session?.Profile ?? target.Profile;
        return profile == null ? null : new(profile, stored, session?.Title ?? "", null);
    }
}

/// A tap that came before the signed-in app was up waits here (NotificationHub `pending`), and goes as soon as there is
/// something to open it with.
public sealed class NotificationOpener
{
    private readonly object _gate = new();
    private NotificationTarget? _pending;
    private Action<NotificationTarget>? _open;

    public void Tapped(NotificationTarget target)
    {
        Action<NotificationTarget>? open;
        lock (_gate)
        {
            open = _open;
            if (open == null) _pending = target;
        }
        open?.Invoke(target);
    }

    /// The app can open chats now (null: it can't any more, e.g. signed out).
    public void Ready(Action<NotificationTarget>? open)
    {
        NotificationTarget? waiting;
        lock (_gate)
        {
            _open = open;
            waiting = open != null ? _pending : null;
            if (waiting != null) _pending = null;
        }
        if (waiting != null) open!(waiting);
    }

    public NotificationTarget? TakePending()
    {
        lock (_gate)
        {
            var p = _pending;
            _pending = null;
            return p;
        }
    }
}
