using System.Text.Json.Nodes;

namespace Hermes.Core.Jobs;

/// One of `GET /api/cron/delivery-targets` (HermesKit/Pages/JobDelivery.swift, docs/spec/3x-jobs.md §6.8).
public sealed record DeliveryTarget(string Id, string Name, bool HomeTargetSet = true, string? HomeEnvVar = null)
{
    /// Lenient: an entry without an id is dropped, a missing name is "", `home_target_set` may be a bool, a number or a
    /// string; absent means set.
    public static DeliveryTarget? Parse(JsonNode? json)
    {
        if (json is not JsonObject || JobJson.PgString(json.Get("id"))?.Trim() is not { Length: > 0 } id) return null;
        var set = json.Get("home_target_set") switch
        {
            JsonValue v when v.TryGetValue(out bool b) => b,
            JsonValue v when v.TryGetValue(out double n) => n != 0,
            JsonValue v when v.TryGetValue(out string? s) => !(new[] { "false", "0", "no", "" }.Contains(s.ToLowerInvariant())),
            _ => true,
        };
        return new DeliveryTarget(id, JobJson.PgString(json.Get("name"))?.Trim() ?? "", set, JobJson.StrictString(json.Get("home_env_var")));
    }

    /// `{"targets":[…]}` (or a bare list), duplicates by id dropped.
    public static List<DeliveryTarget> List(JsonNode? json)
    {
        var seen = new HashSet<string>();
        var rows = json.Arr("targets") ?? json as JsonArray ?? [];
        return [.. rows.Select(Parse).OfType<DeliveryTarget>().Where(t => seen.Add(t.Id))];
    }
}

/// One row of "Send Results To".
public sealed record DeliveryRow(string Id, string Title, string? Note, bool Selectable, bool Checked);

public static class JobDelivery
{
    public const string Fallback = "local";
    public const string LocalLabel = "Run History Only";
    public const string NeedsHomeChannel = "Set a home channel first";
    /// The words the job page and the editor share.
    public static readonly IReadOnlyDictionary<string, string> Labels = new Dictionary<string, string> { ["local"] = LocalLabel };

    /// The chosen targets, in order, without repeats; nothing chosen means local.
    public static List<string> Parse(string value)
    {
        var seen = new HashSet<string>();
        var targets = value.Split(',').Select(t => t.Trim()).Where(t => t.Length > 0 && seen.Add(t)).ToList();
        return targets.Count == 0 ? [Fallback] : targets;
    }

    /// Checks or unchecks one target. The last checked one cannot be unchecked.
    public static string Toggle(string value, string target, bool @checked)
    {
        var targets = Parse(value);
        if (@checked) return string.Join(",", targets.Contains(target) ? targets : [.. targets, target]);
        if (!targets.Contains(target) || targets.Count == 1) return string.Join(",", targets);
        return string.Join(",", targets.Where(t => t != target));
    }

    /// The editor's click on a row: Run History Only is a choice of its own; any other row is checked or unchecked
    /// beside the other places, and unchecking the last one leaves Run History Only.
    public static string Pick(string value, string target)
    {
        if (target == Fallback) return Fallback;
        var places = Parse(value).Where(t => t != Fallback).ToList();
        var i = places.IndexOf(target);
        if (i >= 0) places.RemoveAt(i); else places.Add(target);
        return places.Count == 0 ? Fallback : string.Join(",", places);
    }

    /// Places, the bots' chats, and the platforms that cannot be chosen until they have a home channel.
    public static (List<DeliveryRow> Places, List<DeliveryRow> Bots, List<string> NeedsHome) Groups(IEnumerable<DeliveryRow> rows)
    {
        List<DeliveryRow> places = [], bots = [];
        List<string> needsHome = [];
        foreach (var row in rows)
        {
            if (!row.Selectable && !row.Checked) needsHome.Add(row.Title);
            else if (row.Id.StartsWith("bot-chat:")) bots.Add(row);
            else places.Add(row);
        }
        return (places, bots, needsHome);
    }

    /// Run History Only is checked only when nothing else is (what is shown only).
    public static List<DeliveryRow> HistoryOnlyBeside(List<DeliveryRow> rows)
    {
        if (!rows.Any(r => r.Checked && r.Id != Fallback)) return rows;
        return [.. rows.Select(r => r.Id == Fallback ? r with { Checked = false } : r)];
    }

    /// "Discord needs a home channel first: …" / "Discord and Slack need…": null when every platform has one.
    public static string? NeedsHomeNote(IReadOnlyList<string> names)
    {
        if (names.Count == 0) return null;
        var list = names.Count == 1 ? names[0] : string.Join(", ", names.Take(names.Count - 1)) + " and " + names[^1];
        return $"{list} {(names.Count == 1 ? "needs" : "need")} a home channel first: send /sethome in the chat that should get results.";
    }

    /// Two values that deliver to the same places (order and repeats aside).
    public static bool Same(string a, string b) => Parse(a).SequenceEqual(Parse(b));

    /// The name of one listed target.
    public static string Title(DeliveryTarget target, IReadOnlyDictionary<string, string> botNames)
    {
        if (target.Id == "local") return LocalLabel;
        if (target.Id.StartsWith("bot-chat:"))
        {
            var profile = target.Id["bot-chat:".Length..];
            if (botNames.TryGetValue(profile, out var name) && name.Length > 0) return $"Bot Chat ({name})";
            return JobWords.ReadableTargetName(target.Name.Length == 0 ? $"Bot Chat ({profile})" : target.Name);
        }
        if (JobWords.PlatformNames.TryGetValue(target.Id, out var known)) return known;
        return target.Name.Length == 0 ? JobWords.TitleCase(target.Id) : target.Name;
    }

    /// The rows: the gateway's targets in its order (local first), minus a platform without a home channel when one of
    /// its chats, or the chat the job came from on it, is already chosen; then every chosen value the gateway no longer
    /// lists, kept so an edit never drops a saved route.
    public static List<DeliveryRow> Rows(IReadOnlyList<DeliveryTarget> targets, string value, CronOrigin? origin = null,
        IReadOnlyDictionary<string, string>? chatNames = null, IReadOnlyDictionary<string, string>? botNames = null)
    {
        botNames ??= new Dictionary<string, string>();
        var selected = Parse(value);
        var listed = targets.ToList();
        var li = listed.FindIndex(t => t.Id == "local");
        if (li < 0) listed.Insert(0, new DeliveryTarget("local", "Local"));
        else if (li != 0) { var l = listed[li]; listed.RemoveAt(li); listed.Insert(0, l); }
        var originPlatform = JobWords.Known(origin?.Platform);
        var shown = listed.Where(t => t.HomeTargetSet || selected.Contains(t.Id)
            || !selected.Any(o => o.StartsWith(t.Id + ":") || (o == "origin" && originPlatform == t.Id)));
        var rows = shown.Select(t =>
        {
            var isChecked = selected.Contains(t.Id);
            var needsHome = t.Id != "local" && !t.HomeTargetSet;
            return new DeliveryRow(t.Id, Title(t, botNames), needsHome ? NeedsHomeChannel : null, !needsHome || isChecked, isChecked);
        }).ToList();
        var known = listed.Select(t => t.Id).ToHashSet();
        var names = new Dictionary<string, string>(chatNames ?? new Dictionary<string, string>());
        foreach (var (profile, name) in botNames) names[$"bot-chat:{profile}"] = name;
        foreach (var target in selected.Where(t => !known.Contains(t)))
        {
            var title = JobWords.HumanDeliverTarget(target, origin, Labels, false, names);
            rows.Add(new DeliveryRow(target, title.Length == 0 ? target : title, null, true, true));
        }
        return rows;
    }
}
