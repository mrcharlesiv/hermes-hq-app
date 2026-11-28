using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Hermes.Core.Bots;

// Roster wire types: profiles.list rows, their session references and the bot meta in ui_meta['hermes-bots'].
// Port of HermesKit/Model/RosterWire.swift (spec 02 §2.1, §3 step 5, §5.1). Decoding is lenient: unknown keys are
// ignored, every documented key is optional, and fields that arrive as numbers/bools where text is expected become text.

/// JS-flavoured reads of roster JSON (RosterText in RosterWire.swift).
public static class RosterText
{
    /// JS `String(value)` for the scalars the roster can carry where text is expected; "" for anything else.
    public static string Text(JsonNode? value) => value switch
    {
        JsonValue v when v.GetValueKind() == JsonValueKind.String => v.GetValue<string>(),
        JsonValue v when v.GetValueKind() == JsonValueKind.Number => NumberText(v.GetValue<double>()),
        JsonValue v when v.GetValueKind() == JsonValueKind.True => "true",
        JsonValue v when v.GetValueKind() == JsonValueKind.False => "false",
        _ => "",
    };

    /// Trimmed text, null when blank.
    public static string? Trimmed(JsonNode? value) => NonBlank(Text(value));

    public static string? NonBlank(string? s) => s?.Trim() is { Length: > 0 } t ? t : null;

    /// JS number → string for the values YAML hands back ("2025", "1.5").
    public static string NumberText(double n) =>
        Math.Round(n) == n && Math.Abs(n) < 9.007e15
            ? ((long)n).ToString(CultureInfo.InvariantCulture)
            : n.ToString("R", CultureInfo.InvariantCulture);

    /// A strict JSON number (JS `typeof x === 'number'`), finite.
    public static double? Number(JsonNode? value)
    {
        if (value is not JsonValue v || v.GetValueKind() != JsonValueKind.Number) return null;
        if (v.TryGetValue<double>(out var d)) return double.IsFinite(d) ? d : null;
        if (v.TryGetValue<long>(out var l)) return l;
        if (v.TryGetValue<int>(out var i)) return i;
        if (v.TryGetValue<decimal>(out var dec)) return (double)dec;
        return null;
    }

    /// A strict JSON number as a count, truncated toward zero; null when it does not fit.
    public static long? Count(JsonNode? value) =>
        Number(value) is { } n && Math.Abs(n) < 9.2e18 ? (long)Math.Truncate(n) : null;

    /// A strict JSON bool.
    public static bool? Bool(JsonNode? value) => value is JsonValue v
        ? v.GetValueKind() switch { JsonValueKind.True => true, JsonValueKind.False => false, _ => null }
        : null;

    public static bool IsNull(JsonNode? value) => value is null;

    /// JS truthiness for the flags meta carries (`if (meta.pinned)`).
    public static bool Truthy(JsonNode? value) => value switch
    {
        null => false,
        JsonObject or JsonArray => true,
        JsonValue v => v.GetValueKind() switch
        {
            JsonValueKind.True => true,
            JsonValueKind.Number => v.GetValue<double>() is var d && d != 0 && !double.IsNaN(d),
            JsonValueKind.String => v.GetValue<string>().Length > 0,
            _ => false,
        },
        _ => false,
    };

    /// Spec 02 §3 step 5: text fields that arrive as numbers/bools become strings, objects/arrays are dropped; a
    /// non-object `ui_meta` is dropped. Returns a cleaned deep copy.
    public static JsonNode CleanRow(JsonNode row)
    {
        if (row is not JsonObject o) return row.DeepClone();
        var copy = (JsonObject)o.DeepClone();
        Clean(copy, ["name", "title", "display_name", "description", "connectionLabel"]);
        if (copy.TryGetPropertyValue("ui_meta", out var ui))
        {
            if (ui is JsonObject uiObject)
            {
                if (uiObject.TryGetPropertyValue("hermes-bots", out var own))
                {
                    if (own is JsonObject meta) Clean(meta, ["title", "description", "color", "shape", "image"]);
                    else if (own is not null) uiObject.Remove("hermes-bots");
                }
            }
            else copy.Remove("ui_meta");
        }
        return copy;
    }

    private static void Clean(JsonObject record, string[] fields)
    {
        foreach (var field in fields)
        {
            if (!record.TryGetPropertyValue(field, out var value) || value is null) continue;
            switch (value)
            {
                case JsonValue v when v.GetValueKind() == JsonValueKind.String: continue;
                case JsonValue v when v.GetValueKind() is JsonValueKind.Number or JsonValueKind.True or JsonValueKind.False:
                    record[field] = Text(v);
                    break;
                default:
                    record.Remove(field);
                    break;
            }
        }
    }
}

/// `canonical_session` / `last_session` / `worker_session` on a `profiles.list` row, or a `session.list` title-lookup
/// row (spec 02 §2.1, §2.5). Times are unix seconds.
public sealed record RosterSessionRef(string Id, string? ResolvedId = null, string? Title = null, string? RootTitle = null,
    string? Preview = null, string? Source = null, double? StartedAt = null, double? LastActive = null,
    long? MessageCount = null, long? LiveMessageCount = null)
{
    public static RosterSessionRef? From(JsonNode? json)
    {
        if (json is not JsonObject o) return null;
        return new RosterSessionRef(
            RosterText.Text(o["id"]).Trim(), RosterText.Trimmed(o["resolved_id"]),
            o["title"] is null ? null : RosterText.Text(o["title"]), RosterText.Trimmed(o["root_title"]),
            o["preview"] is null ? null : RosterText.Text(o["preview"]), RosterText.Trimmed(o["source"]),
            RosterText.Number(o["started_at"]), RosterText.Number(o["last_active"]),
            RosterText.Count(o["message_count"]), RosterText.Count(o["live_message_count"]));
    }

    /// The id that opens: the lineage tip, else the registry id.
    public string OpenId => ResolvedId ?? Id;

    /// Both ids the chat goes by, deduped, blank ones dropped.
    public IReadOnlyList<string> Ids
    {
        get
        {
            var o = new List<string>();
            foreach (var v in new[] { Id, ResolvedId ?? "" })
                if (v.Length > 0 && !o.Contains(v)) o.Add(v);
            return o;
        }
    }

    /// `root_title || title === "Bot Chat"`.
    public bool IsBotChat => RootTitle is { } root ? root == RosterRules.BotChatTitle : Title?.Trim() == RosterRules.BotChatTitle;
}

/// Where a pin moved a bot from (`pinnedFrom`, HQ only).
public abstract record PinHome
{
    /// Missing, false, or not a usable object: not in Pinned because of a pin.
    public sealed record Unrecorded : PinHome;
    /// null: came from no section.
    public sealed record NoSection : PinHome;
    public sealed record Section(string Id, string? Name) : PinHome;

    public static readonly PinHome None = new Unrecorded();

    public static PinHome From(JsonObject? meta, string key = "pinnedFrom")
    {
        if (meta == null || !meta.ContainsKey(key)) return None;
        var value = meta[key];
        if (value is null) return new NoSection();
        if (value is JsonObject o && o["id"] is JsonValue idv && idv.GetValueKind() == JsonValueKind.String
            && idv.GetValue<string>() is { Length: > 0 } id)
            return new Section(id, o["name"] is JsonValue nv && nv.GetValueKind() == JsonValueKind.String ? nv.GetValue<string>() : null);
        return None;
    }
}

/// The fields of `ui_meta['hermes-bots']` the Bots list reads (spec 02 §5.1).
public sealed record BotMeta
{
    public string? Title { get; init; }
    public string? Description { get; init; }
    public bool Pinned { get; init; }
    public bool Hidden { get; init; }
    public string? SectionId { get; init; }
    public string? SectionName { get; init; }
    public PinHome PinnedFrom { get; init; } = PinHome.None;
    public double? Created { get; init; }

    public static BotMeta From(JsonNode? json)
    {
        if (json is not JsonObject o) return new BotMeta();
        return new BotMeta
        {
            Title = RosterText.Trimmed(o["title"]),
            Description = RosterText.Trimmed(o["description"]),
            Pinned = RosterText.Truthy(o["pinned"]),
            Hidden = RosterText.Truthy(o["hidden"]),
            SectionId = RosterText.Truthy(o["sectionId"]) ? RosterText.NonBlank(RosterText.Text(o["sectionId"])) : null,
            SectionName = RosterText.Trimmed(o["sectionName"]),
            PinnedFrom = PinHome.From(o),
            Created = RosterText.Number(o["created"]),
        };
    }

    /// A bot filed in Pinned by hand (no recorded home) reads as pinned (spec 02 §7.4).
    public bool EffectivePinned => Pinned || (SectionId == RosterRules.PinnedSectionId && PinnedFrom is PinHome.Unrecorded);

    /// The user section the bot belongs to when it is not shown as pinned.
    public string? HomeSectionId => SectionId != RosterRules.PinnedSectionId ? SectionId
        : PinnedFrom is PinHome.Section s ? s.Id : null;
}

/// One `profiles.list` row (spec 02 §2.1). `Raw` is the text-cleaned row as received.
public sealed class RosterProfile
{
    public string Name { get; }
    public bool IsDefault { get; }
    public string? DisplayName { get; }
    public string? Description { get; }
    public string? Title { get; }
    public string? Model { get; }
    public string? Provider { get; }
    public RosterSessionRef? LastSession { get; }
    public RosterSessionRef? WorkerSession { get; }
    public RosterSessionRef? CanonicalSession { get; }
    public JsonObject UiMeta { get; }
    public bool HasAvatar { get; }
    public JsonObject Raw { get; }

    private RosterProfile(string name, JsonObject o)
    {
        Name = name;
        Raw = o;
        IsDefault = RosterText.Bool(o["is_default"]) ?? name == "default";
        DisplayName = RosterText.Trimmed(o["display_name"]);
        Description = RosterText.Trimmed(o["description"]);
        Title = RosterText.Trimmed(o["title"]);
        Model = RosterText.Trimmed(o["model"]);
        Provider = RosterText.Trimmed(o["provider"]);
        LastSession = RosterSessionRef.From(o["last_session"]);
        WorkerSession = RosterSessionRef.From(o["worker_session"]);
        CanonicalSession = RosterSessionRef.From(o["canonical_session"]);
        UiMeta = o["ui_meta"] as JsonObject ?? [];
        HasAvatar = RosterText.Bool(o["has_avatar"]) ?? false;
    }

    public static RosterProfile? From(JsonNode? json)
    {
        if (json == null) return null;
        if (RosterText.CleanRow(json) is not JsonObject o || RosterText.Trimmed(o["name"]) is not { } name) return null;
        return new RosterProfile(name, o);
    }

    /// The server's own `ui_meta['hermes-bots']` object on this row, if any.
    public JsonObject? ServerMeta => UiMeta["hermes-bots"] as JsonObject;
    /// The raw head record (spec 02 §10; drawn by the heads feature).
    public JsonNode? Head => UiMeta["dispatch-head"];
    public IReadOnlyList<string> CanonicalIds => CanonicalSession?.Ids ?? [];
    /// @handle: the primary profile is `hermes`, never `default`.
    public string Handle => RosterRules.Handle(Name);

    /// The revision `profiles.list` reported for one ui_meta key (0 when none).
    public long Revision(string key) => RosterText.Count(Raw["ui_meta_revisions"]?[key]) is { } n && n >= 0 ? n : 0;

    /// The legacy model the rest of the app uses (BotHead, BotChatDestination): parsed from the same raw row, so a
    /// field another feature adds to `Model.Bot.From` is read here too.
    public Hermes.Core.Model.Bot ToModel(string displayName, BotMeta meta)
    {
        var b = Hermes.Core.Model.Bot.From(Raw) ?? new Hermes.Core.Model.Bot(Name, displayName, null, Model, IsDefault, false, false, null, HasAvatar, null, null);
        return b with { DisplayName = displayName, Pinned = meta.EffectivePinned, Hidden = meta.Hidden, SectionName = meta.SectionName };
    }
}

/// A decoded `profiles.list` answer.
public sealed record RosterSnapshot(IReadOnlyList<RosterProfile> Profiles, bool? BotModeProtocol = null, string? InstallId = null)
{
    /// Rows without a name are dropped; a duplicate name keeps its first row.
    public static RosterSnapshot Decode(JsonNode? result)
    {
        if (result?["profiles"] is not JsonArray rows)
            throw new Net.GatewayException("not-hermes", "The gateway's bot list was not readable.");
        var seen = new HashSet<string>();
        var profiles = new List<RosterProfile>();
        foreach (var row in rows)
            if (RosterProfile.From(row) is { } p && seen.Add(p.Name)) profiles.Add(p);
        return new RosterSnapshot(profiles, RosterText.Bool(result["bot_mode_protocol"]),
            result["install_id"] is JsonValue v && v.GetValueKind() == JsonValueKind.String ? v.GetValue<string>() : null);
    }

    /// The slim answer's rows, keeping each bot's last known session fields until the full answer lands: a field the
    /// slim row lacks is copied from the previous row of that name.
    public static List<JsonNode> MergeSlim(IEnumerable<JsonNode> slim, IEnumerable<JsonNode> previous)
    {
        var known = new Dictionary<string, JsonObject>();
        foreach (var row in previous)
            if (row is JsonObject o && RosterText.Trimmed(o["name"]) is { } n && !known.ContainsKey(n)) known[n] = o;
        string[] fields = ["last_session", "worker_session", "canonical_session"];
        return slim.Select(row =>
        {
            if (row is not JsonObject o || RosterText.Trimmed(o["name"]) is not { } n || !known.TryGetValue(n, out var before))
                return row.DeepClone();
            var copy = (JsonObject)o.DeepClone();
            foreach (var f in fields)
                if (!copy.ContainsKey(f) && before.TryGetPropertyValue(f, out var v)) copy[f] = v?.DeepClone();
            return (JsonNode)copy;
        }).ToList();
    }
}

/// The local meta snapshot's read rule (spec 02 §5.2, `BotMetaMerge`): for each row with a server `hermes-bots` object,
/// `merged = {...local, ...server}`, local `image` kept, `chat` dropped, and a local `group` scalar dropped when the server
/// has `groups` but no `group`. Rows without server meta keep the local meta.
public static class BotMetaMerge
{
    public static Dictionary<string, JsonObject> Merge(IReadOnlyDictionary<string, JsonObject> local, IEnumerable<RosterProfile> roster,
        Func<string, bool>? fenced = null)
    {
        var next = local.ToDictionary(kv => kv.Key, kv => kv.Value);
        foreach (var profile in roster)
        {
            if (profile.ServerMeta is not { } server || fenced?.Invoke(profile.Name) == true) continue;
            var mine = next.TryGetValue(profile.Name, out var m) ? m : [];
            var merged = (JsonObject)mine.DeepClone();
            foreach (var (k, v) in server) merged[k] = v?.DeepClone();
            if (mine["image"] is { } image && RosterText.Truthy(image)) merged["image"] = image.DeepClone();
            merged.Remove("chat");
            if (server["groups"] is JsonArray && mine.ContainsKey("group") && !server.ContainsKey("group")) merged.Remove("group");
            next[profile.Name] = merged;
        }
        return next;
    }
}
