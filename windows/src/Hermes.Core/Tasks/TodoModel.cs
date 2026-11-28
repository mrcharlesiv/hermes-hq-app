using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using Hermes.Core.Kanban;

namespace Hermes.Core.Tasks;

// The shared to-do list's wire shapes (HermesKit/Pages/Tasks/TodoModel.swift; docs/tasks.md "Data"). The hermes-hq-push
// add-on serves it at /api/plugins/hermes-hq-push/tasks. Read leniently; each task keeps the JSON it came in, so an edit
// is applied to it as the gateway would apply a PATCH (TodoEdits.Applying).

public enum TodoWho { Me, Bot, Together }

public sealed record TodoStep(string Id, string Title, string Who, bool Done)
{
    public static TodoStep From(JsonNode? n) => new(n.Str("id") ?? TodoIds.Make(), n.Str("title") ?? "", n.Str("who") ?? "me", n.Bool("done") ?? false);
    public JsonObject Wire() => new() { ["id"] = Id, ["title"] = Title, ["who"] = Who, ["done"] = Done };
}

public sealed record TodoMade(string Id, string Title, string Kind, string Ref, string? By)
{
    public bool IsYours => string.Equals(By, "you", StringComparison.OrdinalIgnoreCase);
    public bool IsFile => string.Equals(Kind, "file", StringComparison.OrdinalIgnoreCase);
    public bool IsLink => string.Equals(Kind, "link", StringComparison.OrdinalIgnoreCase);

    /// Validates `Ref` as an HTTP(S) URI for link attachments; returns null otherwise.
    public string? LinkUrl => ValidLinkUrl(Ref);

    public static string? ValidLinkUrl(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return null;
        if (!Uri.TryCreate(raw.Trim(), UriKind.Absolute, out var uri)) return null;
        if (!string.Equals(uri.Scheme, Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase)
            && !string.Equals(uri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase))
            return null;
        return uri.AbsoluteUri;
    }
}

public sealed record TodoCloseOffer(string By, string Text, string? At, bool Kept);

/// Linked chat thread for a task or goal (`TodoChat` in `HermesKit/Pages/Tasks/TodoModel.swift`).
public sealed record TodoChat(string Profile, string SessionId)
{
    public static TodoChat? From(JsonNode? n)
    {
        if (n is not JsonObject) return null;
        var session = n.Text("session_id") ?? n.Text("session") ?? n.Text("id");
        if (session == null) return null;
        return new TodoChat(n.Text("profile") ?? "default", session);
    }

    public JsonObject Wire() => new() { ["profile"] = Profile, ["session_id"] = SessionId };
}

/// Short summary & next action synthesized for a Task Page (`TodoPageGist`).
public sealed record TodoPageGist(string Summary, string Next)
{
    public static TodoPageGist? From(JsonNode? n)
    {
        if (n is not JsonObject) return null;
        var summary = n.Text("summary") ?? "";
        var next = n.Text("next") ?? "";
        return summary.Length == 0 && next.Length == 0 ? null : new TodoPageGist(summary, next);
    }
}

/// External origin metadata ("Email · Ivy · Nov 13") on a task or idea (`TodoFrom`).
public sealed record TodoFrom(string? App, string? Who, string? At, string? Ref = null, string? Link = null)
{
    public static TodoFrom? From(JsonNode? n)
    {
        if (n is not JsonObject) return null;
        var app = n.Text("app") ?? n.Text("kind");
        var who = n.Text("who") ?? n.Text("from");
        var at = n.Text("at");
        var r = n.Text("ref");
        var link = TodoMade.ValidLinkUrl(n.Text("link") ?? n.Text("url"));
        return app == null && who == null && at == null && r == null && link == null ? null : new TodoFrom(app, who, at, r, link);
    }

    public JsonObject Wire()
    {
        var o = new JsonObject();
        if (App != null) o["app"] = App;
        if (Who != null) o["who"] = Who;
        if (At != null) o["at"] = At;
        if (Ref != null) o["ref"] = Ref;
        if (Link != null) o["link"] = Link;
        return o;
    }

    public string Line(DateTimeOffset now, TimeZoneInfo zone)
    {
        var parts = new List<string>();
        if (!string.IsNullOrWhiteSpace(App)) parts.Add(char.ToUpperInvariant(App![0]) + App[1..]);
        if (!string.IsNullOrWhiteSpace(Who)) parts.Add(Who!);
        if (TodoDates.Moment(At) is { } dt) parts.Add(TodoWords.MonthDay(dt, now, zone));
        return string.Join(" · ", parts);
    }
}

/// One activity log entry on a task or goal.
public sealed record TodoLogEntry(string At, string By, string Text, string? Kind = null)
{
    public static TodoLogEntry? From(JsonNode? n)
    {
        if (n is not JsonObject) return null;
        var text = n.Text("text") ?? n.Text("note");
        if (text == null) return null;
        return new TodoLogEntry(n.Text("at") ?? "", n.Text("by") ?? "default", text, n.Text("kind"));
    }
}

public sealed record TodoTask(string Id)
{
    public int Rev { get; init; }
    public string Title { get; init; } = "";
    public string Notes { get; init; } = "";
    public string Who { get; init; } = "me";
    public string? Bot { get; init; }
    public string Status { get; init; } = "open";
    public string StatusNote { get; init; } = "";
    public string? Due { get; init; }
    public string? RepeatRule { get; init; }
    public bool Prep { get; init; }
    public IReadOnlyList<TodoStep> Steps { get; init; } = [];
    public IReadOnlyList<TodoMade> Made { get; init; } = [];
    public string? SourceKind { get; init; }
    public string? SourceProfile { get; init; }
    public string? SourceSessionId { get; init; }
    public TodoFrom? SourceFrom { get; init; }
    public string? CreatedAt { get; init; }
    public string? UpdatedAt { get; init; }
    public string? DoneAt { get; init; }
    public string? CreatedBy { get; init; }
    public string? Section { get; init; }
    public double Position { get; init; }
    public string Watch { get; init; } = "";
    public IReadOnlyList<string> Choices { get; init; } = [];
    /// 0 none, 1 high, 2 medium, 3 low.
    public int Priority { get; init; }
    public IReadOnlyList<string> Tags { get; init; } = [];
    public string? Starts { get; init; }
    public TodoCloseOffer? Offer { get; init; }
    public string? Goal { get; init; }
    /// [goals] The goal's milestone it sits under (docs/goals.md "Task gains"), or null.
    public string? Milestone { get; init; }
    /// [tasks-v2] Task-linked chat thread, Task Page gist, alerts, and history log.
    public TodoChat? Chat { get; init; }
    public bool ChatKnown { get; init; }
    public string? PageAt { get; init; }
    public TodoPageGist? Page { get; init; }
    public string? NextCheck { get; init; }
    public string? Alert { get; init; }
    public string? SuggestedTitle { get; init; }
    public string? SuggestedForTitle { get; init; }
    public IReadOnlyList<TodoLogEntry> Log { get; init; } = [];
    /// The task as the gateway sent it (unknown keys kept).
    public JsonObject Raw { get; init; } = [];

    private static string? NonEmpty(JsonNode? n, string key) => n.Str(key) is { Length: > 0 } s ? s : null;

    public static TodoTask? From(JsonNode? n)
    {
        if (n is not JsonObject o || NonEmpty(n, "id") is not { } id) return null;
        var level = (int)(n.Int("priority") ?? 0);
        var offer = n.Obj("offer") is { } off
            ? new TodoCloseOffer(off.Str("by") ?? "default", off.Str("text") ?? "", off.Str("at"), off.Bool("kept") ?? false) : null;
        var src = n.Obj("source");
        return new TodoTask(id)
        {
            Rev = (int)(n.Int("rev") ?? 0),
            Title = n.Str("title") ?? "",
            Notes = n.Str("notes") ?? "",
            Who = n.Str("who") ?? "me",
            Bot = NonEmpty(n, "bot"),
            Status = n.Str("status") ?? "open",
            StatusNote = n.Str("status_note") ?? "",
            Due = NonEmpty(n, "due"),
            RepeatRule = NonEmpty(n, "repeat"),
            Prep = n.Bool("prep") ?? false,
            Steps = [.. (n.Arr("steps") ?? []).Select(TodoStep.From)],
            Made = [.. (n.Arr("made") ?? []).Select(m => new TodoMade(m.Str("id") ?? "", m.Str("title") ?? "", m.Str("kind") ?? "note", m.Str("ref") ?? "", m.Str("by")))],
            SourceKind = src.Str("kind"),
            SourceProfile = src.Str("profile"),
            SourceSessionId = src.Text("session_id") ?? src.Text("session"),
            SourceFrom = TodoFrom.From(n.Get("from") ?? src.Get("from")),
            CreatedAt = n.Str("created_at"),
            UpdatedAt = n.Str("updated_at"),
            DoneAt = n.Str("done_at"),
            CreatedBy = n.Str("created_by"),
            Section = NonEmpty(n, "section"),
            Position = n.Num("position") ?? 0,
            Watch = n.Str("watch") ?? "",
            Choices = [.. (n.Arr("choices") ?? []).Select(J.AsString).OfType<string>().Select(s => s.Trim()).Where(s => s.Length > 0)],
            Priority = level is >= 0 and <= 3 ? level : 0,
            Tags = [.. (n.Arr("tags") ?? []).Select(J.AsString).OfType<string>().Select(s => s.Trim()).Where(s => s.Length > 0)],
            Starts = NonEmpty(n, "starts"),
            Offer = offer,
            Goal = NonEmpty(n, "goal"),
            Milestone = NonEmpty(n, "milestone"),
            Chat = TodoChat.From(n.Get("chat")),
            ChatKnown = o.ContainsKey("chat"),
            PageAt = NonEmpty(n, "page_at"),
            Page = TodoPageGist.From(n.Get("page")),
            NextCheck = NonEmpty(n, "next_check"),
            Alert = NonEmpty(n, "alert"),
            SuggestedTitle = NonEmpty(n, "suggested_title"),
            SuggestedForTitle = NonEmpty(n, "suggested_for_title"),
            Log = [.. (n.Arr("log") ?? []).Select(TodoLogEntry.From).OfType<TodoLogEntry>()],
            Raw = (JsonObject)o.DeepClone(),
        };
    }

    /// Where it sits in its list: its position, or when it was added on an older add-on.
    public double Order => Position != 0 ? Position : TodoDates.Moment(CreatedAt)?.ToUnixTimeMilliseconds() / 1000.0 ?? 0;
    public bool IsDone => Status == "done";
    public TodoWho WhoKind => Who switch { "bot" => TodoWho.Bot, "together" => TodoWho.Together, _ => TodoWho.Me };
    /// The bot on a bot or together task (a together task with none named reads as the root bot's).
    public string? Helper => WhoKind == TodoWho.Me ? null : Bot ?? "default";
}

/// One of your own lists (the sections of 0.9.36).
public sealed record TodoUserSection(string Id, string Name)
{
    public string? Color { get; init; }
    public string? Icon { get; init; }
    public string? Bot { get; init; }
    public bool InToday { get; init; } = true;
    /// Its bot asks before adding a task to it (`adds: "ask"`); false: "Add Without Asking" (`"auto"`).
    public bool AsksFirst { get; init; }
    /// When its bot last looked at the list (the gateway's own; never sent back).
    public string? CheckedAt { get; init; }

    public static TodoUserSection? From(JsonNode? n) =>
        n.Str("id") is { } id && n.Str("name") is { } name
            ? new TodoUserSection(id, name)
            {
                Color = n.Str("color") is { Length: > 0 } c ? c : null,
                Icon = n.Str("icon") is { Length: > 0 } i ? i : null,
                Bot = n.Str("bot") is { Length: > 0 } b ? b : null,
                InToday = n.Bool("today") ?? true,
                AsksFirst = n.Str("adds") == "ask",
                CheckedAt = n.Str("checked_at") is { Length: > 0 } at ? at : null,
            }
            : null;

    /// As `PUT /tasks/sections` takes it (TodoModel.swift `encode(to:)` and TasksAPI.saveSections): every field, an
    /// unset one sent empty so the gateway clears it; a list not saved yet goes with an empty id; no `checked_at`.
    public JsonObject Wire() => new()
    {
        ["id"] = TodoIds.IsLocal(Id) ? "" : Id, ["name"] = Name, ["color"] = Color ?? "", ["icon"] = Icon ?? "", ["bot"] = Bot ?? "",
        ["adds"] = AsksFirst ? "ask" : "auto", ["today"] = InToday,
    };
}

/// [task-ideas 0.9.86] Which built-in sources and opt-in connected apps the Task ideas run may check
/// (`TodoIdeasSources` in `HermesKit/Pages/Tasks/TodoModel.swift`).
public sealed record TodoIdeasSources
{
    public bool Chats { get; init; } = true;
    /// Empty = all bots; non-empty = only these bot profile IDs have their recent chats included.
    public IReadOnlyList<string> ChatBots { get; init; } = [];
    public bool Memory { get; init; } = true;
    public bool Files { get; init; } = false;
    public bool Web { get; init; } = false;
    /// Opt-in list of enabled connector IDs (`"mcp:<name>"` or `"composio:<slug>"`). Newly connected apps start off.
    public IReadOnlyList<string> Connectors { get; init; } = [];

    public TodoIdeasSources(
        bool chats = true,
        IReadOnlyList<string>? chatBots = null,
        bool memory = true,
        bool files = false,
        bool web = false,
        IReadOnlyList<string>? connectors = null)
    {
        Chats = chats;
        ChatBots = chatBots ?? [];
        Memory = memory;
        Files = files;
        Web = web;
        Connectors = connectors ?? [];
    }

    public static TodoIdeasSources From(JsonNode? n)
    {
        if (n is not JsonObject) return new TodoIdeasSources();
        return new TodoIdeasSources(
            chats: n.Bool("chats") ?? true,
            chatBots: [.. (n.Arr("chat_bots") ?? []).Select(J.AsString).OfType<string>().Where(s => s.Length > 0)],
            memory: n.Bool("memory") ?? true,
            files: n.Bool("files") ?? false,
            web: n.Bool("web") ?? false,
            connectors: [.. (n.Arr("connectors") ?? []).Select(J.AsString).OfType<string>().Where(s => s.Length > 0)]);
    }

    public JsonObject Wire() => new()
    {
        ["chats"] = Chats,
        ["chat_bots"] = new JsonArray([.. ChatBots.Select(b => (JsonNode)b)]),
        ["memory"] = Memory,
        ["files"] = Files,
        ["web"] = Web,
        ["connectors"] = new JsonArray([.. Connectors.Select(c => (JsonNode)c)]),
    };

    public bool Equals(TodoIdeasSources? other) =>
        other != null
        && Chats == other.Chats
        && Memory == other.Memory
        && Files == other.Files
        && Web == other.Web
        && ChatBots.SequenceEqual(other.ChatBots, StringComparer.Ordinal)
        && Connectors.SequenceEqual(other.Connectors, StringComparer.Ordinal);

    public override int GetHashCode()
    {
        var h = new HashCode();
        h.Add(Chats);
        h.Add(Memory);
        h.Add(Files);
        h.Add(Web);
        foreach (var b in ChatBots) h.Add(b, StringComparer.Ordinal);
        foreach (var c in Connectors) h.Add(c, StringComparer.Ordinal);
        return h.ToHashCode();
    }
}

/// `GET/PUT /tasks/settings` (HermesKit TodoModel.swift TodoSettings). `Sort` is a list's order: "smart" (My Order, your
/// drag order; the default) | "due" | "added" | "priority" (hermes-hq-push 0.9.53). `Group` is kept as the gateway sends
/// it for an older app; nothing here reads it.
public sealed record TodoSettings(bool Enabled = true, string Capture = "ask", string Sort = "smart")
{
    public int PrepPerDay { get; init; } = 6;
    public string QuietStart { get; init; } = "22:00";
    public string QuietEnd { get; init; } = "08:00";
    public int PrepEveryHours { get; init; } = 3;
    public string Group { get; init; } = "smart";
    /// nil from an add-on before Ideas (0.9.39), and then never sent back.
    public bool? Ideas { get; init; }
    public string? IdeasBot { get; init; }
    /// [task-ideas 0.9.86] Participating bots for multi-bot Task ideas sweeps. null from an older add-on.
    public IReadOnlyList<string>? IdeasBots { get; init; }
    public string? IdeasAt { get; init; }
    public int? IdeasMax { get; init; }
    /// [task-ideas 0.9.86] Built-in source toggles and opt-in connected apps. null from an older add-on.
    public TodoIdeasSources? IdeasSources { get; init; }
    /// [task-ideas 0.9.86] Optional plain-English Focus & Skip instructions. null from an older add-on.
    public string? IdeasNote { get; init; }

    public IReadOnlyList<string> ActiveIdeasBots =>
        IdeasBots is { Count: > 0 } bots ? bots : [IdeasBot ?? "default"];

    public static TodoSettings From(JsonNode? n) => new(n.Bool("enabled") ?? true, n.Str("capture") ?? "ask", n.Str("sort") ?? "smart")
    {
        PrepPerDay = (int)(n.Int("prep_per_day") ?? 6),
        QuietStart = n.Str("quiet_start") ?? "22:00",
        QuietEnd = n.Str("quiet_end") ?? "08:00",
        PrepEveryHours = (int)(n.Int("prep_every_hours") ?? 3),
        Group = n.Str("group") ?? "smart",
        Ideas = n.Bool("ideas"),
        IdeasBot = n.Str("ideas_bot"),
        IdeasBots = n.Arr("ideas_bots") is { } bots ? [.. bots.Select(J.AsString).OfType<string>().Where(s => s.Length > 0)] : null,
        IdeasAt = n.Str("ideas_at"),
        IdeasMax = n.Int("ideas_max") is { } m ? (int)m : null,
        IdeasSources = n.Obj("ideas_sources") is { } src ? TodoIdeasSources.From(src) : null,
        IdeasNote = n.Str("ideas_note"),
    };

    /// The whole settings, as the Mac's JSONEncoder writes them for `PUT /tasks/settings` (the optional ones only when set).
    public JsonObject Wire()
    {
        var o = new JsonObject
        {
            ["enabled"] = Enabled, ["capture"] = Capture, ["prep_per_day"] = PrepPerDay, ["quiet_start"] = QuietStart, ["quiet_end"] = QuietEnd,
            ["prep_every_hours"] = PrepEveryHours, ["group"] = Group, ["sort"] = Sort,
        };
        if (Ideas is { } ideas) o["ideas"] = ideas;
        if (IdeasBot is { } bot) o["ideas_bot"] = bot;
        if (IdeasBots is { } ideasBots) o["ideas_bots"] = new JsonArray([.. ideasBots.Select(b => (JsonNode)b)]);
        if (IdeasAt is { } at) o["ideas_at"] = at;
        if (IdeasMax is { } max) o["ideas_max"] = max;
        if (IdeasSources is { } sources) o["ideas_sources"] = sources.Wire();
        if (IdeasNote is { } note) o["ideas_note"] = note;
        return o;
    }

    public bool Equals(TodoSettings? other) =>
        other != null
        && Enabled == other.Enabled
        && string.Equals(Capture, other.Capture, StringComparison.Ordinal)
        && string.Equals(Sort, other.Sort, StringComparison.Ordinal)
        && PrepPerDay == other.PrepPerDay
        && string.Equals(QuietStart, other.QuietStart, StringComparison.Ordinal)
        && string.Equals(QuietEnd, other.QuietEnd, StringComparison.Ordinal)
        && PrepEveryHours == other.PrepEveryHours
        && string.Equals(Group, other.Group, StringComparison.Ordinal)
        && Ideas == other.Ideas
        && string.Equals(IdeasBot, other.IdeasBot, StringComparison.Ordinal)
        && (IdeasBots == null && other.IdeasBots == null
            || IdeasBots != null && other.IdeasBots != null && IdeasBots.SequenceEqual(other.IdeasBots, StringComparer.Ordinal))
        && string.Equals(IdeasAt, other.IdeasAt, StringComparison.Ordinal)
        && IdeasMax == other.IdeasMax
        && Equals(IdeasSources, other.IdeasSources)
        && string.Equals(IdeasNote, other.IdeasNote, StringComparison.Ordinal);

    public override int GetHashCode()
    {
        var h = new HashCode();
        h.Add(Enabled);
        h.Add(Capture, StringComparer.Ordinal);
        h.Add(Sort, StringComparer.Ordinal);
        h.Add(PrepPerDay);
        h.Add(QuietStart, StringComparer.Ordinal);
        h.Add(QuietEnd, StringComparer.Ordinal);
        h.Add(PrepEveryHours);
        h.Add(Group, StringComparer.Ordinal);
        h.Add(Ideas);
        if (IdeasBot != null) h.Add(IdeasBot, StringComparer.Ordinal);
        if (IdeasBots != null) foreach (var b in IdeasBots) h.Add(b, StringComparer.Ordinal);
        if (IdeasAt != null) h.Add(IdeasAt, StringComparer.Ordinal);
        h.Add(IdeasMax);
        h.Add(IdeasSources);
        if (IdeasNote != null) h.Add(IdeasNote, StringComparer.Ordinal);
        return h.ToHashCode();
    }
}

/// `GET /tasks`: the list, or `unchanged` when `?since=` matched the list's rev.
public sealed record TodoListAnswer(int Rev, IReadOnlyList<TodoTask>? Tasks, TodoSettings? Settings, IReadOnlyList<TodoUserSection>? Sections,
    bool Unchanged, bool Fields, bool Files, bool Lists)
{
    /// [goals] Every goal, any status (hermes-hq-push 0.9.65). null: the add-on keeps no goals (the key is left out).
    public IReadOnlyList<Goal>? Goals { get; init; }
    /// [tasks-v2] Task & Goal pages supported by add-on.
    public bool Pages { get; init; }
    /// [tasks-v2] Waiting Ideas count.
    public int IdeasCount { get; init; }
    /// [tasks-v2] Pending list/goal offers waiting on you.
    public IReadOnlyList<TodoOffer>? Offers { get; init; }
    /// [goals-v2] Add-on supports bots assigned to goals (0.9.66+).
    public bool GoalBots { get; init; }
    /// Custom interval / after-completion recurrence (`custom_repeat: true` when an add-on supports it).
    public bool CustomRepeat { get; init; }

    public static TodoListAnswer From(JsonNode? n) => new(
        (int)(n.Int("rev") ?? 0),
        // One bad task never loses the list: each is read on its own.
        n.Arr("tasks") is { } tasks ? [.. tasks.Select(TodoTask.From).OfType<TodoTask>()] : null,
        n.Get("settings") is JsonObject s ? TodoSettings.From(s) : null,
        n.Arr("sections") is { } sections ? [.. sections.Select(TodoUserSection.From).OfType<TodoUserSection>()] : null,
        n.Bool("unchanged") ?? false, n.Bool("fields") ?? false, n.Bool("files") ?? false, n.Bool("lists") ?? false)
    {
        // One bad goal never loses the list either.
        Goals = n.Arr("goals") is { } goals ? [.. goals.Select(Goal.From).OfType<Goal>()] : null,
        Pages = n.Bool("pages") ?? false,
        IdeasCount = (int)Math.Max(0, n.Int("ideas_count") ?? n.Int("ideas") ?? 0),
        Offers = n.Arr("offers") is { } offers ? [.. offers.Select(TodoOffer.From).OfType<TodoOffer>()] : null,
        GoalBots = n.Bool("goal_bots") ?? false,
        CustomRepeat = n.Bool("custom_repeat") ?? false,
    };
}

public static class TodoIds
{
    /// uuid4 hex, as the add-on makes them.
    public static string Make() => Guid.NewGuid().ToString("N");
    public static string Local() => "local-" + Make();
    public static bool IsLocal(string id) => id.StartsWith("local-", StringComparison.Ordinal);
}

/// A task's due: a day, or a moment.
public readonly record struct TodoDue(DateTimeOffset Date, bool HasTime);

public static class TodoDates
{
    /// "2026-11-05" (the day's start in `zone`) or an ISO 8601 moment; null for anything else.
    public static TodoDue? Due(string? raw, TimeZoneInfo? zone = null)
    {
        raw = raw?.Trim();
        if (string.IsNullOrEmpty(raw)) return null;
        if (raw.Length == 10 && Day(raw, zone) is { } day) return new TodoDue(day, false);
        return Moment(raw) is { } m ? new TodoDue(m, true) : null;
    }

    /// "2026-11-05" as that day's start in `zone`.
    public static DateTimeOffset? Day(string raw, TimeZoneInfo? zone = null)
    {
        var parts = raw.Split('-');
        if (parts.Length != 3 || !int.TryParse(parts[0], out var y) || !int.TryParse(parts[1], out var m) || !int.TryParse(parts[2], out var d)) return null;
        if (m is < 1 or > 12 || d < 1 || d > DateTime.DaysInMonth(y, m)) return null;
        return StartOfDay(new DateTime(y, m, d), zone ?? TimeZoneInfo.Local);
    }

    public static DateTimeOffset StartOfDay(DateTime localDay, TimeZoneInfo zone) =>
        new(localDay.Date, zone.GetUtcOffset(localDay.Date));

    /// An ISO 8601 moment, with or without fractional seconds; Python's isoformat() with no zone reads as local time.
    public static DateTimeOffset? Moment(string? raw)
    {
        if (string.IsNullOrEmpty(raw)) return null;
        if (DateTimeOffset.TryParse(raw, CultureInfo.InvariantCulture, DateTimeStyles.AssumeLocal, out var d)) return d;
        return null;
    }

    /// The local calendar day of a moment.
    public static DateTime LocalDay(DateTimeOffset moment, TimeZoneInfo zone) => TimeZoneInfo.ConvertTime(moment, zone).Date;

    /// The wire form of a due: "2026-11-05" for a day, "2026-11-05T17:00:00-06:00" for a time.
    public static string Wire(DateTimeOffset date, bool hasTime, TimeZoneInfo? zone = null)
    {
        var local = TimeZoneInfo.ConvertTime(date, zone ?? TimeZoneInfo.Local);
        var day = local.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        if (!hasTime) return day;
        var off = local.Offset;
        return day + local.ToString("'T'HH:mm':00'", CultureInfo.InvariantCulture) + (off < TimeSpan.Zero ? "-" : "+") + off.ToString(@"hh\:mm");
    }

    /// Now as the routes write times.
    public static string Now(DateTimeOffset? at = null) => (at ?? DateTimeOffset.Now).ToString("yyyy-MM-dd'T'HH:mm:sszzz", CultureInfo.InvariantCulture);
}

/// Fields as the routes take them, and edits applied as the gateway applies them.
public static class TodoWire
{
    public static JsonArray Steps(IEnumerable<TodoStep> steps) => [.. steps.Select(s => (JsonNode)s.Wire())];

    /// A new task's body (`TodoWire.newTask` in `HermesKit/Pages/Tasks/TasksStore.swift`).
    /// Shared (`together`) tasks preserve `repeat` when `fieldsSupported` is true (hermes-hq-push 0.9.53+);
    /// bot-only (`bot`) tasks never repeat.
    public static JsonObject NewTask(string title, TodoWho who, string? bot, string? due, string? repeatRule, bool prep, string notes = "",
        IEnumerable<TodoStep>? steps = null, string sourceKind = "app", bool fieldsSupported = false, string? goal = null, string? milestone = null)
    {
        var whoWord = who switch { TodoWho.Bot => "bot", TodoWho.Together => "together", _ => "me" };
        var keepRepeat = who == TodoWho.Me || (who == TodoWho.Together && fieldsSupported);
        var body = new JsonObject
        {
            ["title"] = title,
            ["who"] = whoWord,
            ["notes"] = notes,
            ["prep"] = prep && who != TodoWho.Me,
            ["steps"] = Steps(steps ?? []),
            ["due"] = due,
            ["repeat"] = keepRepeat ? repeatRule : null,
            ["bot"] = who == TodoWho.Me ? null : bot ?? "default",
            ["source"] = new JsonObject { ["kind"] = sourceKind },
        };
        if (goal != null)
        {
            body["goal"] = goal;
            if (milestone != null) body["milestone"] = milestone;
        }
        return body;
    }
}

public static class TodoEdits
{
    /// Built JSON read back as the gateway's would be (a number made in C# reads as a number only once it is text).
    public static JsonNode? Reparse(JsonNode node) => JsonNode.Parse(node.ToJsonString());

    /// `task` with `fields` (wire names) applied, as the gateway would apply a PATCH; null when it doesn't read.
    public static TodoTask? Applying(JsonObject fields, TodoTask task)
    {
        var o = (JsonObject)task.Raw.DeepClone();
        if (o.Count == 0) { o["id"] = task.Id; o["rev"] = task.Rev; o["title"] = task.Title; o["status"] = task.Status; o["who"] = task.Who; }
        foreach (var (key, value) in fields) o[key] = value?.DeepClone();
        return TodoTask.From(Reparse(o));
    }

    /// One wire field's value on `task` (null when absent).
    public static string ValueOf(string key, TodoTask task) => task.Raw.Get(key)?.ToJsonString() ?? "null";

    /// A PATCH came back 409 with the `current` task: when every field the change sets still holds what it held in
    /// `base`, the change is sent again on the current rev (Resend); otherwise the other edit wins (null).
    public static int? Resolve(TodoTask @base, TodoTask current, JsonObject fields)
    {
        foreach (var (key, _) in fields)
            if (key != "rev" && ValueOf(key, @base) != ValueOf(key, current)) return null;
        return current.Rev;
    }
}
