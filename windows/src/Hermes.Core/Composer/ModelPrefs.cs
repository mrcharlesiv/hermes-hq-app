using System.Text.Json;
using System.Text.Json.Nodes;

namespace Hermes.Core.Composer;

/// Small settings kept on this PC (the Mac's UserDefaults). Values are JSON text.
public interface IKeyValueStore
{
    string? Get(string key);
    /// null removes the key.
    void Set(string key, string? value);
}

/// In memory (tests, previews).
public sealed class MemoryStore : IKeyValueStore
{
    private readonly Dictionary<string, string> _values = [];
    public string? Get(string key) { lock (_values) return _values.GetValueOrDefault(key); }
    public void Set(string key, string? value)
    {
        lock (_values) { if (value == null) _values.Remove(key); else _values[key] = value; }
    }
}

/// One JSON object in a file, written whole on each change (a few KB at most).
public sealed class JsonFileStore : IKeyValueStore
{
    private readonly string _path;
    private readonly object _lock = new();
    private Dictionary<string, string>? _values;

    public JsonFileStore(string path) => _path = path;

    private Dictionary<string, string> Values()
    {
        if (_values != null) return _values;
        try
        {
            _values = File.Exists(_path)
                ? JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(_path)) ?? []
                : [];
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { _values = []; }
        return _values;
    }

    public string? Get(string key) { lock (_lock) return Values().GetValueOrDefault(key); }

    public void Set(string key, string? value)
    {
        lock (_lock)
        {
            var values = Values();
            if (value == null) values.Remove(key); else values[key] = value;
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
                var tmp = _path + ".tmp";
                File.WriteAllText(tmp, JsonSerializer.Serialize(values));
                File.Move(tmp, _path, overwrite: true);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }
    }
}

/// Reasoning and Fast remembered per model and re-applied when it is picked again (V:store/model-presets.ts).
public sealed record ModelPreset(string? Effort = null, bool? Fast = null);

/// Favourite models, recent models and per-model presets (HermesKit/Store/ModelPrefs.swift; spec 1x §2.3): the web
/// app's three stores with the same keys and JSON formats, kept per gateway account.
public sealed class ModelPrefs
{
    public const string FavoritesKey = "hermes.desktop.favorite-models";
    public const string RecentsKey = "dispatch.chat.recentModels";
    public const string PresetsKey = "hermes.desktop.model-presets";
    public const string FoldedKey = "hq.models.folded-providers";
    public const string CommandFavoritesKey = "hq.favorite-commands";
    public const int CommandFavoritesLimit = 50;
    public const int RecentsLimit = 3;

    private readonly IKeyValueStore _store;
    public string AccountId { get; }

    public ModelPrefs(string accountId, IKeyValueStore store)
    {
        AccountId = accountId;
        _store = store;
    }

    public static string Key(string provider, string model) => $"{provider}::{model}";
    private string StorageKey(string web) => $"{web}|{AccountId}";

    private JsonNode? Read(string web) => _store.Get(StorageKey(web)) is { } text ? J.Parse(text) : null;
    private void Write(string web, JsonNode? value) => _store.Set(StorageKey(web), value?.ToJsonString());

    private List<string> Strings(string web) =>
        [.. (Read(web) as JsonArray ?? []).Select(J.AsString).OfType<string>().Where(s => s.Length > 0)];

    private void SetStrings(string web, IEnumerable<string> values)
    {
        var next = values.Distinct().ToList();
        Write(web, next.Count == 0 ? null : new JsonArray([.. next.Select(v => (JsonNode)v)]));
    }

    // ------------------------------------------------------------------ favourites

    /// Starred `provider::model` keys, in starred order.
    public IReadOnlyList<string> Favorites => Strings(FavoritesKey);

    public void SetFavorites(IEnumerable<string> keys) => SetStrings(FavoritesKey, keys);

    /// Star (it joins the end) or unstar a model.
    public void ToggleFavorite(string provider, string model)
    {
        var key = Key(provider, model);
        var current = Favorites;
        SetFavorites(current.Contains(key) ? current.Where(k => k != key) : [.. current, key]);
    }

    public bool IsFavorite(ModelChoice model) => Favorites.Contains(model.Key);

    /// The provider sections folded to their heading in the Models list.
    public IReadOnlySet<string> FoldedProviders => Strings(FoldedKey).ToHashSet();
    public void SetFoldedProviders(IEnumerable<string> providers) => SetStrings(FoldedKey, providers.Order());

    /// [favorite-commands] Starred commands ("/name", in starred order) leading the ☰ list and the slash drawer.
    public IReadOnlyList<string> FavoriteCommands => Strings(CommandFavoritesKey);

    public void ToggleFavoriteCommand(string command)
    {
        var key = SlashCatalog.Normalize(command);
        if (key.Length <= 1) return;
        var current = FavoriteCommands;
        var next = (current.Contains(key) ? current.Where(k => k != key) : [.. current, key]).Distinct().ToList();
        SetStrings(CommandFavoritesKey, next.Skip(Math.Max(0, next.Count - CommandFavoritesLimit)));
    }

    public void ClearFavoritesAndRecents()
    {
        Write(FavoritesKey, null);
        Write(RecentsKey, null);
    }

    // ------------------------------------------------------------------ recents

    /// Newest first, at most three; malformed rows are dropped.
    public IReadOnlyList<ModelChoice> Recents =>
    [
        .. (Read(RecentsKey) as JsonArray ?? []).Select(row =>
        {
            if (row is not JsonObject o || o.Str("id") is not { } id || o.Str("name") is not { } name
                || o.Str("provider") is not { } provider) return null;
            return new ModelChoice(id, name, provider, o.Str("providerName"));
        }).OfType<ModelChoice>().Take(RecentsLimit),
    ];

    /// Newest first, the same id+provider once, three at most.
    public void Remember(ModelChoice model)
    {
        var next = new[] { model }.Concat(Recents.Where(m => m.Id != model.Id || m.Provider != model.Provider)).Take(RecentsLimit);
        var rows = new JsonArray();
        foreach (var m in next)
        {
            var o = new JsonObject { ["id"] = m.Id, ["name"] = m.Name, ["provider"] = m.Provider };
            if (m.ProviderName != null) o["providerName"] = m.ProviderName;
            rows.Add(o);
        }
        Write(RecentsKey, rows);
    }

    // ------------------------------------------------------------------ presets

    private Dictionary<string, ModelPreset> AllPresets()
    {
        var out_ = new Dictionary<string, ModelPreset>();
        foreach (var (key, value) in Read(PresetsKey) as JsonObject ?? [])
            if (value is JsonObject o) out_[key] = new ModelPreset(o.Str("effort"), o.Bool("fast"));
        return out_;
    }

    public ModelPreset Preset(string provider, string model) => AllPresets().GetValueOrDefault(Key(provider, model)) ?? new();

    /// Merge-patch one model's preset (null fields leave the stored value).
    public void SetPreset(string provider, string model, ModelPreset patch)
    {
        var all = AllPresets();
        var key = Key(provider, model);
        var merged = all.GetValueOrDefault(key) ?? new();
        all[key] = new ModelPreset(patch.Effort ?? merged.Effort, patch.Fast ?? merged.Fast);
        WritePresets(all);
    }

    /// Replaces one model's preset as a whole (a rollback).
    public void ReplacePreset(string provider, string model, ModelPreset preset)
    {
        var all = AllPresets();
        all[Key(provider, model)] = preset;
        WritePresets(all);
    }

    private void WritePresets(Dictionary<string, ModelPreset> all)
    {
        var o = new JsonObject();
        foreach (var (key, preset) in all)
        {
            var p = new JsonObject();
            if (preset.Effort != null) p["effort"] = preset.Effort;
            if (preset.Fast != null) p["fast"] = preset.Fast;
            o[key] = p;
        }
        Write(PresetsKey, o);
    }
}
