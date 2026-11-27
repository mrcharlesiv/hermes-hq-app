using System.Collections.Concurrent;
using System.Text.Json.Nodes;

namespace Hermes.Core.Composer;

/// A model as the menus show it (HermesKit `ModelChoice`, the web's `TitleModel`).
public sealed record ModelChoice(string Id, string Name, string Provider, string? ProviderName = null)
{
    /// The `provider::model` key favourites and presets use.
    public string Key => ModelPrefs.Key(Provider, Id);
}

public sealed record ModelCapabilities(bool? Fast, bool? Reasoning, bool? CanDisableReasoning);

/// One provider of the gateway's model catalog (`model.options`, spec 1x §3.1; HermesKit/Chat/ModelCatalog.swift).
public sealed record ModelProviderRow
{
    public required string Slug { get; init; }
    public string Name { get; init; } = "";
    public IReadOnlyList<string> Models { get; init; } = [];
    public IReadOnlyList<string> Aliases { get; init; } = [];
    public IReadOnlyDictionary<string, ModelCapabilities> Capabilities { get; init; } = new Dictionary<string, ModelCapabilities>();
    /// False for a provider listed but not signed in; null when the gateway says nothing.
    public bool? Authenticated { get; init; }
    /// ⋯ › Model Prices: the gateway's $/Mtok per model.
    public IReadOnlyDictionary<string, ModelPrice> Pricing { get; init; } = new Dictionary<string, ModelPrice>();
    public bool PricingPending { get; init; }
    /// ⋯ › Usage & Limits: subscription windows, a usage-window plan, a rate limit.
    public ProviderUsage? Usage { get; init; }
    public PlanUsage? Plan { get; init; }
    public ProviderLimit? Limit { get; init; }

    /// A row matches a slug by slug, display name, or alias.
    public bool Matches(string provider) =>
        provider.Length > 0 && (Slug == provider || Name == provider || Aliases.Contains(provider));
}

/// `ModelOptionsResult` (only the fields the menus read).
public sealed record ModelOptions(IReadOnlyList<ModelProviderRow> Providers, string Model = "", string Provider = "")
{
    public static ModelOptions Parse(JsonNode? json)
    {
        var providers = new List<ModelProviderRow>();
        foreach (var row in json.Arr("providers") ?? [])
        {
            if (row.Str("slug") is not { } slug) continue;
            var caps = new Dictionary<string, ModelCapabilities>();
            foreach (var (id, v) in row.Obj("capabilities") ?? [])
                caps[id] = new ModelCapabilities(v.Bool("fast"), v.Bool("reasoning"), v.Bool("can_disable_reasoning"));
            var pricing = new Dictionary<string, ModelPrice>();
            foreach (var (id, v) in row.Obj("pricing") ?? [])
                if (ModelPrice.Parse(v) is { } price) pricing[id] = price;
            providers.Add(new ModelProviderRow
            {
                Slug = slug,
                Name = row.Str("name") ?? "",
                Models = [.. (row.Arr("models") ?? []).Select(J.AsString).OfType<string>()],
                Aliases = [.. (row.Arr("aliases") ?? []).Select(J.AsString).OfType<string>()],
                Capabilities = caps,
                Authenticated = row.Bool("authenticated"),
                Pricing = pricing,
                PricingPending = row.Bool("pricing_pending") ?? false,
                Usage = ProviderUsage.Parse(row.Get("usage")),
                Plan = PlanUsage.Parse(row.Get("plan_usage")),
                Limit = ProviderLimit.Parse(row.Get("limit")),
            });
        }
        return new ModelOptions(providers, json.Str("model") ?? "", json.Str("provider") ?? "");
    }

    public ModelProviderRow? Row(string provider) => Providers.FirstOrDefault(r => r.Matches(provider));

    /// The catalog's capabilities for a pick, null while it doesn't say (callers then assume reasoning).
    public ModelCapabilities? CapabilitiesOf(string provider, string model) =>
        Row(provider) is { } r && r.Capabilities.TryGetValue(model, out var c) ? c : null;

    public ModelChoice Describe(string id, string provider) => DescribeWith(id, provider, Row(provider));

    /// A model as the menus show it (`describe`, S:ui-chat/title-menu.ts:152-156).
    public static ModelChoice DescribeWith(string id, string provider, ModelProviderRow? row)
    {
        var slug = row?.Slug ?? provider;
        var display = ModelNames.DisplayModelName(id);
        var rowName = row?.Name ?? "";
        var fallback = ModelNames.ProviderDisplayName(provider);
        var source = rowName.Length > 0 ? rowName : fallback.Length > 0 ? fallback : provider;
        return new ModelChoice(id, display.Length == 0 ? "Model" : display, slug, ModelNames.PlainProviderName(source));
    }

    /// Every catalog model, in catalog order.
    public IReadOnlyList<ModelChoice> Choices =>
        [.. Providers.SelectMany(r => r.Models.Select(m => DescribeWith(m, r.Slug, r)))];
}

/// One provider's rows in the Models list.
public sealed record ModelSection(string Provider, string Title, IReadOnlyList<ModelChoice> Models);

/// One row of the Models sheet, in words (ModelSheetViewController.swift's ModelRowCell): the model's name (its id when
/// the catalog sent no name, so a row is never blank), the tick on the current one, the star, and what a screen reader
/// says for the row and its star.
public sealed record ModelRowWords(string Title, bool Current, bool Starred, string AccessibleName, string StarName, string Tip);

public static class ModelSheetModel
{
    public const string FavoritesTitle = "Favorites";

    /// The catalog by provider, filtered by `query`: one row per id or display name within a provider; the chat's
    /// current model wins its name's place.
    public static IReadOnlyList<ModelSection> Sections(IEnumerable<ModelChoice> models, string query,
        (string Id, string Provider)? current)
    {
        var words = query.ToLowerInvariant().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        bool IsCurrent(ModelChoice m) => current is { } c && m.Id == c.Id && m.Provider == c.Provider;
        var order = new List<string>();
        var sections = new Dictionary<string, (string Title, List<ModelChoice> Models, Dictionary<string, int> Twins)>();
        foreach (var model in models)
        {
            if (words.Length > 0)
            {
                var text = $"{model.Id} {model.Name} {model.Provider} {model.ProviderName}".ToLowerInvariant();
                if (!words.All(text.Contains)) continue;
            }
            if (!sections.TryGetValue(model.Provider, out var section))
            {
                order.Add(model.Provider);
                var title = string.IsNullOrEmpty(model.ProviderName) ? model.Provider : model.ProviderName;
                section = (title, [], []);
                sections[model.Provider] = section;
            }
            var nameKey = "name:" + model.Name.Trim().ToLowerInvariant();
            if (section.Twins.TryGetValue("id:" + model.Id, out var twin) || section.Twins.TryGetValue(nameKey, out twin))
            {
                if (IsCurrent(model) && !IsCurrent(section.Models[twin])) section.Models[twin] = model;
            }
            else
            {
                section.Twins["id:" + model.Id] = section.Models.Count;
                section.Twins[nameKey] = section.Models.Count;
                section.Models.Add(model);
            }
        }
        return [.. order.Select(k => new ModelSection(k, sections[k].Title, sections[k].Models))];
    }

    /// The words a model's row shows: its name, marked when it is the chat's current model.
    public static ModelRowWords Row(ModelChoice model, ModelChoice current, bool starred)
    {
        var title = model.Name.Trim() is { Length: > 0 } name ? name : model.Id;
        var isCurrent = model.Id == current.Id && model.Provider == current.Provider;
        return new ModelRowWords(title, isCurrent, starred, isCurrent ? $"{title}, Current" : title, $"Favorite {title}", model.Id);
    }

    /// The catalog's rows for the starred keys, in starred order; a star the catalog lacks shows nothing.
    public static IReadOnlyList<ModelChoice> FavoriteRows(IEnumerable<ModelChoice> models, IEnumerable<string> keys)
    {
        var byKey = new Dictionary<string, ModelChoice>();
        foreach (var m in models) byKey.TryAdd(m.Key, m);
        return [.. keys.Select(k => byKey.GetValueOrDefault(k)).OfType<ModelChoice>()];
    }

    /// Favourites before a catalog is cached: each `provider::model` key described from the key alone.
    public static IReadOnlyList<ModelChoice> FavoritesFromKeys(IEnumerable<string> keys) =>
    [
        .. keys.Select(key =>
        {
            var at = key.IndexOf("::", StringComparison.Ordinal);
            return at > 0 ? ModelOptions.DescribeWith(key[(at + 2)..], key[..at], null) : null;
        }).OfType<ModelChoice>(),
    ];
}

/// The catalog cache (spec 1x §3.1: memory only, fresh for 30 s), per account, profile and runtime id.
public sealed class ModelCatalogCache
{
    public static ModelCatalogCache Shared { get; } = new();
    public static readonly TimeSpan FreshFor = TimeSpan.FromSeconds(30);

    public readonly record struct Key(string Account, string Profile, string Scope);

    private sealed record Entry(ModelOptions Options, DateTimeOffset At, bool Stale = false);

    private readonly ConcurrentDictionary<Key, Entry> _entries = new();
    private readonly ConcurrentDictionary<Key, bool> _failed = new();
    private readonly ConcurrentDictionary<(string, string), string> _profileEfforts = new();

    public ModelOptions? Cached(Key key) => _entries.TryGetValue(key, out var e) ? e.Options : null;

    /// The newest catalog cached for another chat of the same account and profile.
    public ModelOptions? Sibling(Key key) =>
        _entries.Where(p => p.Key.Account == key.Account && p.Key.Profile == key.Profile)
            .OrderByDescending(p => p.Value.At).Select(p => p.Value.Options).FirstOrDefault();

    public ModelOptions? Fresh(Key key, DateTimeOffset? now = null) =>
        _entries.TryGetValue(key, out var e) && !e.Stale && (now ?? DateTimeOffset.UtcNow) - e.At < FreshFor ? e.Options : null;

    public void Store(ModelOptions options, Key key) => _entries[key] = new Entry(options, DateTimeOffset.UtcNow);

    /// A live switch's answer: the next load asks again.
    public void MarkStale(Key key)
    {
        if (_entries.TryGetValue(key, out var e)) _entries[key] = e with { Stale = true };
    }

    /// Paints a pick into the cached answer, so `current()` reads it at once.
    public void Paint(Key key, string model, string provider)
    {
        if (_entries.TryGetValue(key, out var e)) _entries[key] = e with { Options = e.Options with { Model = model, Provider = provider } };
    }

    public bool LoadFailed(Key key) => _failed.ContainsKey(key);
    public void SetLoadFailed(bool failed, Key key)
    {
        if (failed) _failed[key] = true; else _failed.TryRemove(key, out _);
    }

    public string? ProfileEffort(string account, string profile) => _profileEfforts.GetValueOrDefault((account, profile));
    public void StoreProfileEffort(string account, string profile, string value) => _profileEfforts[(account, profile)] = value;

    public void Forget(string account)
    {
        foreach (var k in _entries.Keys.Where(k => k.Account == account)) _entries.TryRemove(k, out _);
        foreach (var k in _failed.Keys.Where(k => k.Account == account)) _failed.TryRemove(k, out _);
        foreach (var k in _profileEfforts.Keys.Where(k => k.Item1 == account)) _profileEfforts.TryRemove(k, out _);
    }
}
