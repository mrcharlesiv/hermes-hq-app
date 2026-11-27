using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using Hermes.Core.Net;

namespace Hermes.Core.Insights;

// Star Map (docs/spec/3x-morepages.md §17): the wire shapes of `GET /api/learning/graph` and `GET /api/learning/node`,
// decoded leniently, and the page's pure rules: the filters, the subtitle, the List's sections and the words of a row.
// Ported from HermesKit/Pages/More/StarMapWire.swift.

public enum StarMapKind { Skill, Memory }

public sealed record StarMapNode(string Id, string Label, StarMapKind Kind = StarMapKind.Skill, string Category = "general",
    int UseCount = 0, string State = "active", string? CreatedBy = null, bool Pinned = false, double? Timestamp = null,
    string? MemorySource = null)
{
    /// A missing label is the id.
    public static StarMapNode Make(string id, string? label = null, StarMapKind kind = StarMapKind.Skill, string category = "general",
        int useCount = 0, string state = "active", string? createdBy = null, bool pinned = false, double? timestamp = null,
        string? memorySource = null) => new(id, label ?? id, kind, category, useCount, state, createdBy, pinned, timestamp, memorySource);

    /// Null for a row with no id (skipped). Everything else has a default: a missing label is the id, a missing category
    /// the gateway's own fallback "general", a count written as a string still counts.
    public static StarMapNode? FromJson(JsonNode? json)
    {
        if (json is not JsonObject) return null;
        var id = StarMapJson.PgString(json.Get("id"))?.Trim();
        if (string.IsNullOrEmpty(id)) return null;
        var label = StarMapJson.PgString(json.Get("label"))?.Trim() ?? "";
        var kind = StarMapJson.String(json.Get("kind")) == "memory" ? StarMapKind.Memory : StarMapKind.Skill;
        var category = StarMapJson.PgString(json.Get("category"))?.Trim() ?? "";
        var state = StarMapJson.String(json.Get("state")) ?? "";
        var by = StarMapJson.String(json.Get("createdBy")) ?? "";
        return new StarMapNode(id, label.Length == 0 ? id : label, kind,
            category.Length == 0 ? (kind == StarMapKind.Memory ? "memory" : "general") : category,
            Math.Max(0, StarMapJson.Int(json.Get("useCount")) ?? 0), state.Length == 0 ? "active" : state,
            by.Length == 0 ? null : by, StarMapJson.Truthy(json.Get("pinned")), StarMapJson.Seconds(json.Get("timestamp")),
            StarMapJson.String(json.Get("memorySource")));
    }
}

public readonly record struct StarMapEdge(string Source, string Target);

/// Freeform memory shown as a card in the List. `Id` is its place in the answer.
public sealed record StarMapMemoryCard(int Id, string Source, string Title, string Body, double? Timestamp = null);

public sealed class StarMapGraph
{
    public List<StarMapNode> Nodes { get; } = [];
    public List<StarMapEdge> Edges { get; } = [];
    public List<StarMapMemoryCard> Memory { get; } = [];
    public bool IsEmpty => Nodes.Count == 0 && Memory.Count == 0;

    public StarMapGraph(IEnumerable<StarMapNode>? nodes = null, IEnumerable<StarMapEdge>? edges = null, IEnumerable<StarMapMemoryCard>? memory = null)
    {
        if (nodes != null) Nodes.AddRange(nodes);
        if (edges != null) Edges.AddRange(edges);
        if (memory != null) Memory.AddRange(memory);
    }

    /// The answer of `/api/learning/graph`. Throws when it is not a graph at all (not an object, or no `nodes` list);
    /// inside it a bad row is skipped: a node without an id, a second node with an id already seen (the first wins), an
    /// edge whose ends are not both nodes or that joins a node to itself, an edge seen before in either direction, a
    /// memory card with neither title nor body.
    public static StarMapGraph FromJson(JsonNode? json)
    {
        if (json is not JsonObject || json.Get("nodes") is not JsonArray rows) throw InsightsWire.Unreadable(json);
        var graph = new StarMapGraph();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var row in rows)
        {
            if (StarMapNode.FromJson(row) is not { } node || !seen.Add(node.Id)) continue;
            graph.Nodes.Add(node);
        }
        var pairs = new HashSet<(string, string)>();
        foreach (var row in json.Get("edges") as JsonArray ?? [])
        {
            var a = StarMapJson.PgString(row.Get("source"));
            var b = StarMapJson.PgString(row.Get("target"));
            if (a == null || b == null || a == b || !seen.Contains(a) || !seen.Contains(b)) continue;
            var key = string.CompareOrdinal(a, b) < 0 ? (a, b) : (b, a);
            if (!pairs.Add(key)) continue;
            graph.Edges.Add(new StarMapEdge(a, b));
        }
        foreach (var row in json.Get("memory") as JsonArray ?? [])
        {
            if (row is not JsonObject) continue;
            var title = StarMapJson.PgString(row.Get("title"))?.Trim() ?? "";
            var body = StarMapJson.PgString(row.Get("body"))?.Trim() ?? "";
            if (title.Length == 0 && body.Length == 0) continue;
            graph.Memory.Add(new StarMapMemoryCard(graph.Memory.Count, StarMapJson.String(row.Get("source")) ?? "memory", title, body,
                StarMapJson.Seconds(row.Get("timestamp"))));
        }
        return graph;
    }
}

/// What a star says (`node_detail`: `{"ok","kind","id","label","content"}`).
public sealed record StarMapNodeDetail(string? Label, string Content)
{
    public static StarMapNodeDetail FromJson(JsonNode? json)
    {
        if (json is not JsonObject) throw InsightsWire.Unreadable(json);
        return new StarMapNodeDetail(StarMapJson.PgString(json.Get("label")), (StarMapJson.PgString(json.Get("content")) ?? "").Trim());
    }

    /// A skill file's front matter ("---", "name: …", "---") is words for the bot: it goes (SkillPageModel.stripFrontMatter).
    public static string StripFrontMatter(string text)
    {
        var lines = text.Split('\n');
        if (lines.Length == 0 || lines[0].Trim(' ', '\t') != "---") return text;
        var end = -1;
        for (var i = 1; i < lines.Length; i++) if (lines[i].Trim(' ', '\t') == "---") { end = i; break; }
        if (end < 0) return text;
        return string.Join("\n", lines.Skip(end + 1)).Trim();
    }
}

public static class StarMapApi
{
    public const string GraphPath = "/api/learning/graph";
    public const string NodePath = "/api/learning/node";

    /// GET, the answer as JSON: an empty body reads as null (not available), a refusal throws.
    private static async Task<JsonNode?> GetAsync(GatewaySession session, string path, List<KeyValuePair<string, string>> query, CancellationToken ct)
    {
        var a = await session.SendAsync(HttpMethod.Get, path, query, ct: ct);
        if (!a.Ok) throw GatewaySession.HttpError(a);
        if (string.IsNullOrWhiteSpace(a.Body)) return null;
        return J.Parse(a.Body) ?? throw new PagesMessageException("The gateway’s answer couldn’t be read.");
    }

    /// `GET /api/learning/graph[?profile=]`, decoded off the caller's thread.
    public static async Task<StarMapGraph> GraphAsync(GatewaySession session, string? profile, CancellationToken ct = default)
    {
        var json = await GetAsync(session, GraphPath, InsightsWire.ProfileQuery(profile), ct);
        return await Task.Run(() => StarMapGraph.FromJson(json), ct);
    }

    public static List<KeyValuePair<string, string>> NodeQuery(string id, string? profile)
    {
        var q = new List<KeyValuePair<string, string>> { new("id", id) };
        q.AddRange(InsightsWire.ProfileQuery(profile));
        return q;
    }

    /// `GET /api/learning/node?id=…[&profile=]`. A 404 means the node is gone (`IsMissing`).
    public static async Task<StarMapNodeDetail> NodeAsync(GatewaySession session, string id, string? profile, CancellationToken ct = default) =>
        StarMapNodeDetail.FromJson(await GetAsync(session, NodePath, NodeQuery(id, profile), ct));

    public static bool IsMissing(Exception e) => e is GatewayException { Code: "http", Status: 404 };
}

// ---------------------------------------------------------------------------------------------------------------- rules

/// The filter menu: All · Used · Learned.
public enum StarMapFilter { All, Used, Learned }

public static class StarMapFilters
{
    public static readonly StarMapFilter[] AllCases = [StarMapFilter.All, StarMapFilter.Used, StarMapFilter.Learned];

    public static string Title(this StarMapFilter f) => f switch
    {
        StarMapFilter.Used => "Used",
        StarMapFilter.Learned => "Learned",
        _ => "All",
    };

    /// Used: the skill ran at least once. Learned: a skill Hermes wrote itself (`createdBy == "agent"`) or was taught
    /// with /learn (`"learn"`). Memories are neither.
    public static bool Matches(this StarMapFilter f, StarMapNode n) => f switch
    {
        StarMapFilter.Used => n.UseCount > 0,
        StarMapFilter.Learned => n.Kind == StarMapKind.Skill && (n.CreatedBy is "agent" or "learn"),
        _ => true,
    };
}

/// One category of the List ("Coding · 12").
public sealed record StarMapSection(string Category, string Title, IReadOnlyList<StarMapNode> Nodes)
{
    public string Header => $"{Title} · {Nodes.Count}";
}

public static class StarMapRules
{
    /// The skills a filter keeps, grouped by category: larger categories first (then by name), inside each the most used
    /// first (then by name). Memory nodes are not rows here: the List shows them as the Memory cards.
    public static List<StarMapSection> Sections(IEnumerable<StarMapNode> nodes, StarMapFilter filter)
    {
        var groups = new Dictionary<string, List<StarMapNode>>(StringComparer.Ordinal);
        foreach (var n in nodes)
        {
            if (n.Kind != StarMapKind.Skill || !filter.Matches(n)) continue;
            if (!groups.TryGetValue(n.Category, out var list)) groups[n.Category] = list = [];
            list.Add(n);
        }
        var sections = groups.Select(g =>
        {
            var rows = g.Value.ToList();
            rows.Sort((a, b) =>
            {
                if (a.UseCount != b.UseCount) return b.UseCount.CompareTo(a.UseCount);
                var order = string.Compare(a.Label, b.Label, CultureInfo.InvariantCulture, CompareOptions.IgnoreCase);
                return order != 0 ? order : string.CompareOrdinal(a.Id, b.Id);
            });
            return new StarMapSection(g.Key, CategoryTitle(g.Key), rows);
        }).ToList();
        sections.Sort((a, b) => a.Nodes.Count != b.Nodes.Count ? b.Nodes.Count.CompareTo(a.Nodes.Count) : string.CompareOrdinal(a.Category, b.Category));
        return sections;
    }

    /// The nodes the Map draws under a filter (memories are stars too, in their own "Memory" cluster).
    public static List<StarMapNode> Stars(IEnumerable<StarMapNode> nodes, StarMapFilter filter) => [.. nodes.Where(n => filter.Matches(n))];

    /// "N skills across M categories".
    public static string Subtitle(int skills, int categories) =>
        $"{skills} {(skills == 1 ? "skill" : "skills")} across {categories} {(categories == 1 ? "category" : "categories")}";

    public static string Subtitle(IReadOnlyList<StarMapSection> sections) => Subtitle(sections.Sum(s => s.Nodes.Count), sections.Count);

    public static string UsedLine(int count) => count <= 0 ? "Not used yet" : count == 1 ? "Used 1 time" : $"Used {count} times";

    /// "software-development" → "Software Development"; a word that already has capitals is kept.
    public static string CategoryTitle(string raw)
    {
        var words = raw.Split(['-', '_', ' ', '/'], StringSplitOptions.RemoveEmptyEntries);
        if (words.Length == 0) return "General";
        return string.Join(" ", words.Select(w => w.Any(char.IsUpper) ? w : char.ToUpperInvariant(w[0]) + w[1..]));
    }

    public static string KindWord(StarMapNode n) =>
        n.Kind == StarMapKind.Memory ? (n.MemorySource == "profile" ? "Profile Memory" : "Memory") : "Skill";

    public static string StateWord(string state) => CategoryTitle(state);

    /// Who made it, null when the gateway does not say.
    public static string? CreatedByWord(string? createdBy) => createdBy switch
    {
        null or "" => null,
        "agent" => "Hermes",
        "learn" => "Taught by You",
        "user" => "You",
        "memory" => "Memory",
        var other => CategoryTitle(other),
    };

    /// "Coding, 42 skills" (the Map's one Narrator element per cluster).
    public static string ClusterSpoken(string title, int count, bool memory) =>
        memory ? $"{title}, {count} {(count == 1 ? "memory" : "memories")}" : $"{title}, {count} {(count == 1 ? "skill" : "skills")}";

    /// A memory card's body is folded at 4 lines; Show More is offered only when that can hide something.
    public static bool Folds(string body) => body.Length > 140 || body.Count(c => c == '\n') >= 4;

    /// The sheet's tags under the title: kind, category, state, and Pinned.
    public static List<string> Tags(StarMapNode n) =>
        [.. new[] { KindWord(n), CategoryTitle(n.Category), StateWord(n.State), n.Pinned ? "Pinned" : "" }.Where(t => t.Length > 0)];

    /// "Used 14 times · Created by Hermes"
    public static string QuietLine(StarMapNode n) => string.Join(" · ",
        new[] { n.Kind == StarMapKind.Skill ? UsedLine(n.UseCount) : null, CreatedByWord(n.CreatedBy) is { } by ? $"Created by {by}" : null }
            .Where(s => s != null));
}

/// What is on show: the filter's sections, the Map's layout and the subtitle, made together (StarMapModel.Shown).
public sealed class StarMapShown
{
    public IReadOnlyList<StarMapSection> Sections { get; init; } = [];
    public IReadOnlyList<StarMapMemoryCard> Memory { get; init; } = [];
    public StarMapLayout Layout { get; init; } = new();
    public string Subtitle { get; init; } = "";
    public int Skills { get; init; }
    public int Generation { get; init; }

    public static StarMapShown Make(StarMapGraph graph, StarMapFilter filter, int generation)
    {
        var sections = StarMapRules.Sections(graph.Nodes, filter);
        var stars = StarMapRules.Stars(graph.Nodes, filter);
        var kept = new HashSet<string>(stars.Select(s => s.Id), StringComparer.Ordinal);
        var layout = new StarMapLayout(stars, graph.Edges.Where(e => kept.Contains(e.Source) && kept.Contains(e.Target)),
            StarMapLayout.Colors(graph.Nodes.Select(n => n.Category)));
        return new StarMapShown
        {
            Sections = sections, Memory = filter == StarMapFilter.All ? graph.Memory : [], Layout = layout,
            Subtitle = StarMapRules.Subtitle(sections), Skills = sections.Sum(s => s.Nodes.Count), Generation = generation,
        };
    }
}

/// HermesKit's JSONValue reads the Star Map uses: `pgString` (a string, or a number's text), `string` (strings only),
/// `int`, `pgSeconds` (a positive number, or one written as text).
internal static class StarMapJson
{
    public static string? String(JsonNode? v) => v is JsonValue jv && jv.TryGetValue(out string? s) ? s : null;

    public static string? PgString(JsonNode? v) => v is JsonValue jv && jv.GetValueKind() is JsonValueKind.String or JsonValueKind.Number
        ? J.AsString(v) : null;

    public static int? Int(JsonNode? v)
    {
        var d = Number(v);
        return d is { } x && double.IsFinite(x) ? (int)Math.Clamp(Math.Truncate(x), int.MinValue, int.MaxValue) : null;
    }

    public static double? Number(JsonNode? v) => v switch
    {
        JsonValue jv when jv.GetValueKind() == JsonValueKind.Number && jv.TryGetValue(out double d) => d,
        JsonValue jv when jv.TryGetValue(out string? s) && double.TryParse(s.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var d) => d,
        _ => null,
    };

    public static double? Seconds(JsonNode? v) => Number(v) is { } d && double.IsFinite(d) && d > 0 ? d : null;

    public static bool Truthy(JsonNode? v) => v switch
    {
        JsonValue jv when jv.GetValueKind() is JsonValueKind.True => true,
        JsonValue jv when jv.GetValueKind() is JsonValueKind.False => false,
        JsonValue jv when jv.GetValueKind() is JsonValueKind.Number && jv.TryGetValue(out double d) => d != 0,
        JsonValue jv when jv.TryGetValue(out string? s) => s.ToLowerInvariant() is "true" or "1" or "yes",
        _ => false,
    };
}
