using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Hermes.Core.Capabilities;

// The Hermes Marketplace (HermesKit/Plugins/PluginCatalog.swift, MarketSkill.swift; App/Capabilities/Marketplace.swift,
// PluginCatalogStore.swift, SkillCatalogStore.swift): plugins from plugins.json, skills from the Marketplace page.

public enum PluginCatalogCategory { Memory, Tools, Models, Web, Voice, Platform, Automation, General, Desktop }

public static class PluginCatalogCategories
{
    public static readonly PluginCatalogCategory[] All = Enum.GetValues<PluginCatalogCategory>();

    public static string Raw(this PluginCatalogCategory c) => c.ToString().ToLowerInvariant();

    public static PluginCatalogCategory? Parse(string? raw) =>
        All.Cast<PluginCatalogCategory?>().FirstOrDefault(c => c!.Value.Raw() == raw);

    public static string Title(this PluginCatalogCategory c) => c switch
    {
        PluginCatalogCategory.Memory => "Memory",
        PluginCatalogCategory.Tools => "Tools",
        PluginCatalogCategory.Models => "Models",
        PluginCatalogCategory.Web => "Web & Browser",
        PluginCatalogCategory.Voice => "Voice",
        PluginCatalogCategory.Platform => "Messaging",
        PluginCatalogCategory.Automation => "Automation",
        PluginCatalogCategory.General => "General",
        _ => "Hermes Desktop",
    };

    public static string Blurb(this PluginCatalogCategory c) => c switch
    {
        PluginCatalogCategory.Memory => "Long-term memory and context for your bots.",
        PluginCatalogCategory.Tools => "New tools your bots can use.",
        PluginCatalogCategory.Models => "More model and inference providers.",
        PluginCatalogCategory.Web => "Search, reading pages and browser control.",
        PluginCatalogCategory.Voice => "Speech, voices and live audio.",
        PluginCatalogCategory.Platform => "Reach your bots from more chat apps.",
        PluginCatalogCategory.Automation => "Hooks, wake-ups and work that runs on its own.",
        PluginCatalogCategory.General => "Plugins that do a bit of everything.",
        _ => "Panes and views for the Hermes desktop app. They show only in Hermes on a computer, not in Hermes HQ.",
    };
}

public sealed record PluginCatalogEntry(string Name, string Description, string Repo, string Sha, string Subdir, string Tier,
    PluginCatalogCategory Category, string Maintainer, string Version, string RequiresHermes, IReadOnlyList<string> Platforms,
    IReadOnlyList<string> ProvidesTools, IReadOnlyList<string> RequiresEnv, Uri? DocsUrl, Uri? Image, int? Stars,
    DateTimeOffset? AddedAt, DateTimeOffset? UpdatedAt, int? Featured, Uri? ReadmeUrl)
{
    public string Title => DisplayName.Title(Name);
    public string InstallIdentifier => Subdir.Length == 0 ? Repo : $"{Repo}#{Subdir}";
    public Uri? PageUrl => new($"https://hermes-agent.nousresearch.com/marketplace/{Uri.EscapeDataString(Name)}");
    public bool IsOfficial => Tier == "official";
    public bool IsVerified => Tier == "verified";
    public string? TierWord => IsOfficial ? "Official" : IsVerified ? "Certified" : null;
    public string About => Split(Description).About;
    public string? Disclosure => Split(Description).Disclosure;

    public string Summary
    {
        get
        {
            var text = About;
            foreach (var joiner in new[] { ": ", " — ", " - " })
            {
                if (!text.StartsWith(Title + joiner, StringComparison.OrdinalIgnoreCase)) continue;
                var rest = text[(Title.Length + joiner.Length)..];
                text = rest.Length == 0 ? rest : char.ToUpperInvariant(rest[0]) + rest[1..];
                break;
            }
            return FirstSentence(text);
        }
    }

    public string? HermesWords
    {
        get
        {
            var words = RequiresHermes.Split(',').Select(p => p.Trim()).Where(p => p.Length > 0).Select(p =>
                p.StartsWith(">=") ? $"{p[2..].Trim()} or newer"
                : p.StartsWith('<') && !p.StartsWith("<=") ? $"before {p[1..].Trim()}"
                : p.StartsWith("==") ? $"exactly {p[2..].Trim()}"
                : p).ToList();
            return words.Count == 0 ? null : string.Join(", ", words);
        }
    }

    public string? PlatformWords
    {
        get
        {
            var names = Platforms.Select(p => p.ToLowerInvariant() switch { "macos" => "macOS", "linux" => "Linux", "windows" => "Windows", _ => p }).ToList();
            return names.Count switch
            {
                0 => null,
                1 => names[0],
                _ => string.Join(", ", names.Take(names.Count - 1)) + " and " + names[^1],
            };
        }
    }

    public int Score(string query)
    {
        var words = query.ToLowerInvariant().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        if (words.Length == 0) return 1;
        var name = Name.ToLowerInvariant(); var title = Title.ToLowerInvariant(); var maker = Maintainer.ToLowerInvariant();
        var text = Description.ToLowerInvariant();
        var total = 0;
        foreach (var w in words)
        {
            if (name == w || title == w) total += 100;
            else if (name.StartsWith(w) || title.StartsWith(w)) total += 60;
            else if (name.Contains(w) || title.Contains(w)) total += 40;
            else if (maker.Contains(w)) total += 20;
            else if (Category.Title().ToLowerInvariant().Contains(w) || ProvidesTools.Any(t => t.ToLowerInvariant().Contains(w))) total += 12;
            else if (text.Contains(w)) total += 5;
            else return 0;
        }
        return total;
    }

    public static List<PluginCatalogEntry> Search(IEnumerable<PluginCatalogEntry> entries, string query)
    {
        var q = query.Trim();
        if (q.Length == 0) return [.. entries];
        return [.. entries.Select((e, i) => (e, i, s: e.Score(q))).Where(t => t.s > 0).OrderByDescending(t => t.s).ThenBy(t => t.i).Select(t => t.e)];
    }

    /// The tab's few picks: most stars first, at most two of a kind.
    public static List<PluginCatalogEntry> Picks(IEnumerable<PluginCatalogEntry> entries, int count, int perKind = 2)
    {
        var taken = new Dictionary<PluginCatalogCategory, int>();
        var o = new List<PluginCatalogEntry>();
        foreach (var e in entries)
        {
            if (o.Count >= count) break;
            if (taken.GetValueOrDefault(e.Category) >= perKind) continue;
            taken[e.Category] = taken.GetValueOrDefault(e.Category) + 1;
            o.Add(e);
        }
        return o;
    }

    public static (string About, string? Disclosure) Split(string description)
    {
        var text = description.Trim();
        foreach (var marker in new[] { "Disclosure — ", "Disclosure - ", "Disclosure: ", "Disclosure —" })
        {
            var at = text.IndexOf(marker, StringComparison.Ordinal);
            if (at < 0) continue;
            var about = text[..at].Trim();
            var rest = text[(at + marker.Length)..].Trim();
            if (rest.Length == 0) return (about.Length == 0 ? text : about, null);
            return (about.Length == 0 ? rest : about, char.ToUpperInvariant(rest[0]) + rest[1..]);
        }
        return (text, null);
    }

    public static string FirstSentence(string text)
    {
        var end = text.Length;
        var search = 0;
        while (search < text.Length && text.IndexOf(". ", search, StringComparison.Ordinal) is var at and >= 0)
        {
            var before = text[..at];
            var last = before.Split([' ', '('], StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? "";
            if (!new[] { "e.g", "i.e", "etc", "vs", "approx", "incl" }.Contains(last.ToLowerInvariant()) && (last.Length > 1 || (last.Length == 1 && !char.IsDigit(last[0]))))
            {
                end = at + 1;
                break;
            }
            search = at + 2;
        }
        var sentence = text[..end].Trim();
        if (sentence.Length <= 180) return sentence;
        var cut = sentence[..170];
        var trimmed = cut.LastIndexOf(' ') is var sp and >= 0 ? cut[..sp] : cut;
        return trimmed.TrimEnd(' ', ',', ';', ':', '—', '-') + "…";
    }

    public static List<PluginCatalogEntry> Decode(string json)
    {
        if (J.Parse(json) is not JsonArray rows) throw new FormatException("not a list");
        var o = new List<PluginCatalogEntry>();
        static Uri? Https(string? raw) => raw != null && Uri.TryCreate(raw, UriKind.Absolute, out var u) && u.Scheme == "https" ? u : null;
        static DateTimeOffset? Date(string? raw) => raw != null && DateTimeOffset.TryParse(raw, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var d) ? d : null;
        static List<string> Strings(JsonNode? v) => [.. (v as JsonArray ?? []).Select(J.AsString).OfType<string>()];
        foreach (var r in rows)
        {
            if (r.Str("name")?.Trim() is not { Length: > 0 } name || r.Str("repo")?.Trim() is not { } repo || !repo.StartsWith("https://")) continue;
            var caps = r.Obj("capabilities");
            o.Add(new(name, r.Str("description") ?? "", repo, r.Str("sha") ?? "", r.Str("subdir") ?? "", (r.Str("tier") ?? "community").ToLowerInvariant(),
                PluginCatalogCategories.Parse(r.Str("category")) ?? PluginCatalogCategory.General, r.Str("maintainer") ?? "", r.Str("version") ?? "",
                r.Str("requiresHermes") ?? "", Strings(r.Get("platforms")), Strings(caps.Get("providesTools")), Strings(caps.Get("requiresEnv")),
                Https(r.Str("docsUrl")), Https(r.Str("image")), r.Int("stars") is { } s ? (int)s : null, Date(r.Str("addedAt")), Date(r.Str("updatedAt")),
                r.Int("featured") is { } f && f > 0 ? (int)f : null, Https(r.Str("readmeUrl"))));
        }
        return o;
    }
}

public sealed record MarketSkill(string Name, string Description, string Author, string Category, string CategoryLabel,
    IReadOnlyList<string> Tags, string Source, string Slug, string InstallIdentifier)
{
    public static readonly string[] Sources = ["built-in", "optional", "NVIDIA", "OpenAI", "HuggingFace", "Anthropic"];

    public bool IsOfficial => Source is "built-in" or "bundled" or "optional" or "official";
    public bool IsBuiltIn => Source is "built-in" or "bundled";
    public string SourceWord => SourceWordOf(Source);

    public static string SourceWordOf(string source) => source switch
    {
        "built-in" or "bundled" => "Built into Hermes",
        "optional" or "official" => "Nous",
        "HuggingFace" => "Hugging Face",
        _ => source,
    };

    public string Badge => IsOfficial ? "Official" : SourceWord;

    public Uri? PageUrl => new("https://hermes-agent.nousresearch.com/marketplace/skills/" +
        string.Join("/", Slug.Split('/', StringSplitOptions.RemoveEmptyEntries).Select(Uri.EscapeDataString)));

    public int Score(string query)
    {
        var words = query.ToLowerInvariant().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        if (words.Length == 0) return 1;
        var name = Name.ToLowerInvariant(); var maker = Author.ToLowerInvariant(); var from = SourceWord.ToLowerInvariant();
        var tags = Tags.Select(t => t.ToLowerInvariant()).ToList();
        var text = Description.ToLowerInvariant();
        var total = 0;
        foreach (var w in words)
        {
            if (name == w) total += 100;
            else if (name.StartsWith(w)) total += 60;
            else if (name.Contains(w)) total += 40;
            else if (tags.Contains(w)) total += 25;
            else if (maker.Contains(w) || from.Contains(w)) total += 20;
            else if (CategoryLabel.ToLowerInvariant().Contains(w) || tags.Any(t => t.Contains(w))) total += 12;
            else if (text.Contains(w)) total += 5;
            else return 0;
        }
        return total;
    }

    public static MarketSkill? Read(JsonNode? row)
    {
        if (row.Str("name")?.Trim() is not { Length: > 0 } name) return null;
        if ((row.Str("installIdentifier") ?? row.Str("identifier"))?.Trim() is not { Length: > 0 } install) return null;
        if (row.Str("source") is not { Length: > 0 } source) return null;
        var category = row.Str("category") is { Length: > 0 } c ? c : "other";
        var label = row.Str("categoryLabel") is { Length: > 0 } l ? l : CultureInfo.InvariantCulture.TextInfo.ToTitleCase(category);
        return new(name, row.Str("description") ?? "", row.Str("author") ?? "", category, label,
            [.. (row.Arr("tags") ?? []).Select(J.AsString).OfType<string>()], source, row.Str("slug") ?? row.Str("docsPath") ?? install, install);
    }

    /// The skills in the Marketplace page's streamed payload (`self.__next_f.push([1,"…"])` chunks).
    public static List<MarketSkill> ParsePage(string html)
    {
        var payload = new System.Text.StringBuilder();
        const string opener = "self.__next_f.push([1,\"";
        var search = 0;
        while (html.IndexOf(opener, search, StringComparison.Ordinal) is var start and >= 0)
        {
            var from = start + opener.Length;
            var end = html.IndexOf("\"])</script>", from, StringComparison.Ordinal);
            if (end < 0) break;
            try { payload.Append(JsonSerializer.Deserialize<string>("\"" + html[from..end] + "\"")); } catch (JsonException) { }
            search = end + 1;
        }
        return ParseObjects(payload.Length == 0 ? html : payload.ToString());
    }

    private static readonly Regex Objects = new(@"\{""name"":""(?:[^""\\]|\\.)*""[^{}]*?""installIdentifier"":""(?:[^""\\]|\\.)*""\}");

    public static List<MarketSkill> ParseObjects(string text)
    {
        var seen = new HashSet<string>();
        var o = new List<MarketSkill>();
        foreach (Match m in Objects.Matches(text))
            if (Read(J.Parse(m.Value)) is { } e && seen.Add(e.InstallIdentifier)) o.Add(e);
        return o;
    }

    /// The published skills.json, kept to the Marketplace's sources.
    public static List<MarketSkill> DecodeFull(string json)
    {
        var seen = new HashSet<string>();
        return [.. (J.Parse(json) as JsonArray ?? []).Select(Read).OfType<MarketSkill>().Where(e => Sources.Contains(e.Source) && seen.Add(e.InstallIdentifier))];
    }

    public JsonObject ToJson() => new()
    {
        ["name"] = Name, ["description"] = Description, ["author"] = Author, ["category"] = Category, ["categoryLabel"] = CategoryLabel,
        ["tags"] = new JsonArray([.. Tags.Select(t => (JsonNode)t)]), ["source"] = Source, ["slug"] = Slug, ["installIdentifier"] = InstallIdentifier,
    };
}

public enum MarketplaceKind { All, Plugins, Skills }
public enum MarketplaceSort { Stars, Newest, Updated, Name }
public enum MarketplaceTier { Official, Verified, Community }

public static class MarketplaceWords
{
    public static string Title(this MarketplaceKind k) => k switch { MarketplaceKind.All => "All", MarketplaceKind.Plugins => "Plugins", _ => "Skills" };
    public static string Title(this MarketplaceSort s) => s switch
    {
        MarketplaceSort.Stars => "Stars", MarketplaceSort.Newest => "Newest", MarketplaceSort.Updated => "Updated", _ => "Name",
    };
    public static string Title(this MarketplaceTier t) => t switch
    {
        MarketplaceTier.Official => "Official", MarketplaceTier.Verified => "Certified", _ => "Community",
    };

    public const string SearchPrompt = "Search Marketplace";
    public const string SkillsFooter = "Skills from Hermes, Nous, NVIDIA, OpenAI, Hugging Face and Anthropic. Search the Skills Hub on the Skills page for community skills.";
    public const string PluginsFooter = "Nous reviews every plugin before it is listed, and Hermes installs the exact version it checked.";
    public const string SkillsBlurb = "Ready-made know-how your bots load when a task needs it.";
    public const string QualityBlurb = "The most-starred desktop and tool plugins in the catalog.";
    public const string NothingMatches = "Nothing here matches these filters.";
    public static string NothingFor(string q) => $"Nothing in the Marketplace matches “{q}”.";

    public static string PluginInstallMessage(PluginCatalogEntry e) =>
        (e.IsOfficial ? "It comes from Nous. " : $"It comes from {e.Maintainer}, listed in the Hermes Marketplace. ") + "Hermes installs the exact version Nous checked.";

    public static string SkillInstallMessage(MarketSkill e, string bot) =>
        (e.IsOfficial ? "It comes from Nous. " : $"It comes from {e.SourceWord}, listed in the Hermes Marketplace. ")
        + $"The gateway downloads it and checks it before it is installed. {bot} can use it in new chats.";

    public static string TrustNote(PluginCatalogEntry e) =>
        e.IsOfficial ? "An official plugin, made by Nous. Hermes installs the exact version listed here."
        : e.IsVerified ? "Certified: made by the company behind the service, checked by Nous. Hermes installs the exact version Nous reviewed."
        : "Made by the Hermes community. Nous reviewed this exact version before listing it, and Hermes installs only that version.";
}

/// One card in a result list: a plugin or a skill.
public sealed record MarketplaceItem(PluginCatalogEntry? Plugin, MarketSkill? Skill)
{
    public string Id => Plugin != null ? "plugin:" + Plugin.Name : "skill:" + Skill!.InstallIdentifier;
    public MarketplaceTier Tier => Plugin is { } p ? (p.IsOfficial ? MarketplaceTier.Official : p.IsVerified ? MarketplaceTier.Verified : MarketplaceTier.Community)
        : Skill!.IsOfficial ? MarketplaceTier.Official : MarketplaceTier.Community;
    public string Name => Plugin?.Title ?? Skill!.Name;
    public string Category => Plugin?.Category.Raw() ?? Skill!.Category;
    public IReadOnlyList<string> Tags => Skill?.Tags ?? [];
    public int? Stars => Plugin?.Stars;
    public DateTimeOffset? AddedAt => Plugin?.AddedAt;
    public DateTimeOffset? UpdatedAt => Plugin is { } p ? p.UpdatedAt ?? p.AddedAt : null;
    public int Score(string q) => Plugin?.Score(q) ?? Skill!.Score(q);
}

/// The Marketplace's choices and the lists they make (Marketplace.swift `MarketplaceState`).
public sealed class MarketplaceState(MarketplaceKind kind = MarketplaceKind.Plugins, string query = "")
{
    public MarketplaceKind Kind { get; set; } = kind;
    public string Query { get; set; } = query;
    public HashSet<MarketplaceTier> Tiers { get; } = [];
    public HashSet<string> Categories { get; } = [];
    public MarketplaceSort Sort { get; set; } = MarketplaceSort.Stars;
    public int Limit { get; set; } = PageSize;
    public const int PageSize = 24;

    public string Trimmed => Query.Trim();
    public bool Browsing => Kind == MarketplaceKind.All && Trimmed.Length == 0 && Tiers.Count == 0 && Categories.Count == 0 && Sort == MarketplaceSort.Stars;

    public void Choose(MarketplaceKind kind)
    {
        Kind = kind;
        Categories.Clear();
        if (kind == MarketplaceKind.Skills) Tiers.Clear();
        Limit = PageSize;
    }

    public List<MarketplaceItem> Scoped(IEnumerable<PluginCatalogEntry> plugins, IEnumerable<MarketSkill> skills)
    {
        var items = new List<MarketplaceItem>();
        if (Kind != MarketplaceKind.Skills) items.AddRange(plugins.Select(p => new MarketplaceItem(p, null)));
        if (Kind != MarketplaceKind.Plugins) items.AddRange(skills.Select(s => new MarketplaceItem(null, s)));
        return items;
    }

    public List<MarketplaceItem> Filter(IEnumerable<MarketplaceItem> items, bool exceptTier = false, bool exceptCategory = false)
    {
        var q = Trimmed;
        return [.. items.Where(i => (exceptTier || Tiers.Count == 0 || Tiers.Contains(i.Tier))
            && (exceptCategory || Categories.Count == 0 || Categories.Contains(i.Category))
            && (q.Length == 0 || i.Score(q) > 0))];
    }

    /// The results in the chosen order; only a plugin or skill named exactly what was typed goes first.
    public List<MarketplaceItem> Ordered(IEnumerable<MarketplaceItem> items)
    {
        var sorted = Sorted(items, Sort);
        var q = Trimmed.ToLowerInvariant();
        if (q.Length == 0) return sorted;
        bool Exact(MarketplaceItem i) => i.Plugin is { } p ? p.Name.ToLowerInvariant() == q || p.Title.ToLowerInvariant() == q : i.Skill!.Name.ToLowerInvariant() == q;
        return [.. sorted.Where(Exact), .. sorted.Where(i => !Exact(i))];
    }

    public static List<MarketplaceItem> Sorted(IEnumerable<MarketplaceItem> items, MarketplaceSort sort)
    {
        var byName = StringComparer.CurrentCultureIgnoreCase;
        return sort switch
        {
            MarketplaceSort.Name => [.. items.OrderBy(i => i.Name, byName)],
            MarketplaceSort.Stars => [.. items.OrderByDescending(i => i.Stars ?? -1).ThenBy(i => i.Name, byName)],
            _ => [.. items.OrderByDescending(i => (sort == MarketplaceSort.Newest ? i.AddedAt : i.UpdatedAt) ?? DateTimeOffset.MinValue).ThenBy(i => i.Name, byName)],
        };
    }

    /// Official · Certified · Community with their counts; none on Skills unless one is still chosen.
    public List<(MarketplaceTier Tier, int Count)> TierRows(IEnumerable<MarketplaceItem> items)
    {
        if (Kind == MarketplaceKind.Skills && Tiers.Count == 0) return [];
        var counts = Filter(items, exceptTier: true).GroupBy(i => i.Tier).ToDictionary(g => g.Key, g => g.Count());
        return [.. Enum.GetValues<MarketplaceTier>().Select(t => (t, counts.GetValueOrDefault(t))).Where(r => r.Item2 > 0 || Tiers.Contains(r.t))];
    }

    /// The categories with their counts, A to Z with "Other" last; none under All unless one is still chosen.
    public List<(string Key, string Title, int Count)> CategoryRows(IEnumerable<MarketplaceItem> items)
    {
        if (Kind == MarketplaceKind.All && Categories.Count == 0) return [];
        var labels = new Dictionary<string, string>();
        var counts = new Dictionary<string, int>();
        foreach (var i in Filter(items, exceptCategory: true))
        {
            labels[i.Category] = i.Plugin?.Category.Title() ?? i.Skill!.CategoryLabel;
            counts[i.Category] = counts.GetValueOrDefault(i.Category) + 1;
        }
        foreach (var k in Categories.Where(k => !labels.ContainsKey(k)))
            labels[k] = PluginCatalogCategories.Parse(k)?.Title() ?? CultureInfo.InvariantCulture.TextInfo.ToTitleCase(k);
        return [.. labels.Keys.OrderBy(k => k == "other" ? 1 : 0).ThenBy(k => labels[k], StringComparer.CurrentCultureIgnoreCase)
            .Select(k => (k, labels[k], counts.GetValueOrDefault(k)))];
    }
}

/// A list read from the web with a copy kept on disk for 6 h (PluginCatalogStore / SkillCatalogStore).
public sealed class WebCatalog<T>(string file, Func<HttpClient, Task<(List<T> List, string Keep)>> fetch, Func<string, List<T>> readKept, string failureWords)
{
    public static readonly TimeSpan FreshFor = TimeSpan.FromHours(6);
    public IReadOnlyList<T>? Entries { get; private set; }
    public string? Error { get; private set; }
    public bool Loading { get; private set; }
    private DateTimeOffset? _readAt;
    private Task? _running;
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(30) };

    public Task LoadAsync(bool force = false)
    {
        if (_running is { IsCompleted: false } r && !force) return r;
        if (!force && _readAt is { } at && DateTimeOffset.UtcNow - at < FreshFor && Entries != null) return Task.CompletedTask;
        return _running = ReadAsync(force);
    }

    private async Task ReadAsync(bool force)
    {
        if (Entries == null && File.Exists(file))
        {
            try
            {
                var kept = readKept(await File.ReadAllTextAsync(file));
                if (kept.Count > 0)
                {
                    Entries = kept;
                    _readAt = File.GetLastWriteTimeUtc(file);
                    if (!force && DateTimeOffset.UtcNow - _readAt < FreshFor) return;
                }
            }
            catch (Exception) { }
        }
        Loading = true;
        try
        {
            var (list, keep) = await fetch(Http);
            if (list.Count == 0) throw new FormatException("empty");
            Entries = list;
            _readAt = DateTimeOffset.UtcNow;
            Error = null;
            try { Directory.CreateDirectory(Path.GetDirectoryName(file)!); await File.WriteAllTextAsync(file, keep); } catch (Exception) { }
        }
        catch (Exception)
        {
            if (Entries == null) Error = failureWords;
        }
        finally { Loading = false; }
    }
}

public static class MarketCatalogs
{
    public const string PluginsUrl = "https://hermes-agent.nousresearch.com/docs/api/plugins.json";
    public const string SkillsPageUrl = "https://hermes-agent.nousresearch.com/marketplace?kind=skills";
    public const string SkillsFullUrl = "https://hermes-agent.nousresearch.com/docs/api/skills.json";

    public static WebCatalog<PluginCatalogEntry> Plugins(string folder, string? url = null) => new(
        Path.Combine(folder, "plugin-catalog.json"),
        async http =>
        {
            var text = await http.GetStringAsync(url ?? PluginsUrl);
            return (PluginCatalogEntry.Decode(text), text);
        },
        PluginCatalogEntry.Decode,
        "Couldn’t load the Hermes plugin list. Check your internet connection and try again.");

    public static WebCatalog<MarketSkill> Skills(string folder, string? url = null) => new(
        Path.Combine(folder, "skill-catalog.json"),
        async http =>
        {
            var list = MarketSkill.ParsePage(await http.GetStringAsync(url ?? SkillsPageUrl));
            if (list.Count < 20 && url == null) list = MarketSkill.DecodeFull(await http.GetStringAsync(SkillsFullUrl));
            return (list, new JsonArray([.. list.Select(s => (JsonNode)s.ToJson())]).ToJsonString());
        },
        text => [.. (J.Parse(text) as JsonArray ?? []).Select(MarketSkill.Read).OfType<MarketSkill>()],
        "Couldn’t load the Marketplace’s skills. Check your internet connection and try again.");
}

/// The Marketplace home's picks (Marketplace.swift `MarketplaceFeatured`, the website's catalog-featured.ts).
public static class MarketplaceFeatured
{
    /// The curated ranks, starting at this week's; with none, the newest pictured official plugin of the last 30 days,
    /// else the official one with a picture and the most stars.
    public static List<PluginCatalogEntry> Picks(IReadOnlyList<PluginCatalogEntry> entries, DateTimeOffset? now = null)
    {
        var at = now ?? DateTimeOffset.UtcNow;
        var curated = entries.Where(e => e.Featured != null).OrderBy(e => e.Featured).ToList();
        if (curated.Count > 0)
        {
            var start = (int)(at.ToUnixTimeSeconds() / (7 * 24 * 3600) % curated.Count);
            return [.. curated.Skip(start), .. curated.Take(start)];
        }
        var official = entries.Where(e => e.IsOfficial).ToList();
        var fresh = official.Where(e => e.Image != null && (e.AddedAt ?? DateTimeOffset.MinValue) > at.AddDays(-30)).OrderByDescending(e => e.AddedAt).FirstOrDefault();
        var pick = fresh ?? official.OrderByDescending(e => e.Image != null).ThenByDescending(e => e.Stars ?? 0).FirstOrDefault();
        return pick == null ? [] : [pick];
    }

    /// Quality of Life: the four most-starred desktop and tool plugins that aren't featured.
    public static List<PluginCatalogEntry> QualityOfLife(IEnumerable<PluginCatalogEntry> entries) =>
        [.. entries.Where(e => e.Category is PluginCatalogCategory.Tools or PluginCatalogCategory.Desktop && e.Featured == null)
            .Select((e, i) => (e, i)).OrderByDescending(p => p.e.Stars ?? -1).ThenBy(p => p.i).Select(p => p.e).Take(4)];

    /// The community maintainer with the most plugins, and their four most-starred.
    public static (string Maker, List<PluginCatalogEntry> Picks)? Spotlight(IEnumerable<PluginCatalogEntry> entries)
    {
        var community = entries.Where(e => !e.IsOfficial && !e.IsVerified && e.Maintainer.Length > 0).ToList();
        var best = community.GroupBy(e => e.Maintainer).OrderByDescending(g => g.Count()).ThenBy(g => g.Key, StringComparer.Ordinal).FirstOrDefault();
        if (best == null || best.Count() < 2) return null;
        return (best.Key, [.. best.OrderByDescending(e => e.Stars ?? 0).Take(4)]);
    }

    public const string DeveloperUrl = "https://hermes-agent.nousresearch.com/docs/developer-guide/plugins";
    public const string WebsiteUrl = "https://hermes-agent.nousresearch.com/marketplace";

    /// "Talk to Hermes Anywhere": the chat apps a bot can answer in, each opening Messaging.
    public static readonly (string Name, string Words)[] Anywhere =
    [
        ("Telegram", "Chat with Hermes through a Telegram bot."),
        ("Discord", "Bring Hermes into servers and direct messages."),
        ("Slack", "Connect Hermes to your Slack workspace."),
        ("WhatsApp", "Message your bot through WhatsApp."),
        ("Signal", "Reach Hermes through private Signal chats."),
        ("Matrix", "Connect rooms and direct messages to Hermes."),
    ];
}
