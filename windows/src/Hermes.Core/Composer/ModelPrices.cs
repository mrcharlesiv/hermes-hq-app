using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Hermes.Core.Composer;

/// One model's prices as the gateway formats them (`ModelPricing`): "$3.00", "free", or "" when unknown
/// (HermesKit/Chat/ModelPrices.swift).
public sealed record ModelPrice(string Input, string Output, string? Cache = null, bool Free = false)
{
    public static ModelPrice? Parse(JsonNode? json) => json is JsonObject
        ? new ModelPrice(json.Str("input") ?? "", json.Str("output") ?? "", json.Str("cache") is { Length: > 0 } c ? c : null,
            json.Bool("free") ?? false)
        : null;

    /// Per-million prices in dollars, formatted as the gateway does (`_format_price_per_mtok`).
    public static ModelPrice FromPerMillion(double? input, double? output, double? cacheRead) => new(
        input is { } i ? Format(i) : "", output is { } o ? Format(o) : "",
        cacheRead is > 0 ? Format(cacheRead.Value) : null, input == 0 && (output ?? 0) == 0);

    /// "$3.00"; "free" at 0; below a cent, as many places as it takes to show a digit ("$0.0042").
    public static string Format(double perMillion)
    {
        if (!double.IsFinite(perMillion) || perMillion <= 0) return "free";
        if (perMillion >= 0.01) return "$" + perMillion.ToString("F2", CultureInfo.InvariantCulture);
        var places = 3;
        while (places < 12 && Math.Round(perMillion * Math.Pow(10, places)) == 0) places++;
        var text = perMillion.ToString("F" + Math.Min(places + 1, 12), CultureInfo.InvariantCulture).TrimEnd('0').TrimEnd('.');
        return "$" + text;
    }

    public bool Known => Free || Input.Length > 0 || Output.Length > 0;

    /// "$3.00 in · $15.00 out · $0.30 cached", "Free".
    public string Line
    {
        get
        {
            if (Free) return "Free";
            var parts = new List<string>();
            if (Input.Length > 0) parts.Add($"{(Input == "free" ? "Free" : Input)} in");
            if (Output.Length > 0) parts.Add($"{(Output == "free" ? "Free" : Output)} out");
            if (Cache != null) parts.Add($"{Cache} cached");
            return string.Join(" · ", parts);
        }
    }
}

public sealed record PriceRow(string Id, string Model, string Name, string Detail, bool Priced, bool Current);
public sealed record PriceSection(string Id, string Title, IReadOnlyList<PriceRow> Rows, string? Footer);

public static class ModelPricesModel
{
    public const string Title = "Model Prices";
    public const string PerMillion = "Per million tokens.";
    public const string NoPrice = "No price listed";
    public const string Included = "Included";
    public const string FallbackFailedFooter = "Couldn’t reach models.dev for list prices.";
    public const string LoadFailed = "Couldn’t load the models.";
    public const string Empty = "No signed-in provider lists models.";
    public const string Loading = "Loading models…";
    public const string LookingUp = "Looking up list prices…";
    public const string SearchPlaceholder = "Search Models";

    /// Plans paid by subscription, not by the token: their models say "Included".
    public static bool IsSubscription(string slug)
    {
        var s = slug.ToLowerInvariant();
        return s is "openai-codex" or "copilot" or "copilot-acp" or "claude-code" or "moa" || s.EndsWith("-oauth")
            || s.StartsWith("claude-subscription");
    }

    /// The sections, the chat's provider first; `fallback` fills providers the gateway has no prices for.
    public static IReadOnlyList<PriceSection> Sections(ModelOptions options, ModelsDevPrices? fallback, bool fallbackFailed = false,
        string query = "", (string Model, string Provider)? current = null)
    {
        var words = query.ToLowerInvariant().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        var outList = new List<PriceSection>();
        foreach (var row in options.Providers)
        {
            if (row.Authenticated == false || row.Models.Count == 0) continue;
            var title = UsageLimitsModel.ProviderTitle(row);
            var subscription = IsSubscription(row.Slug) || row.Plan != null;
            var listed = !subscription && row.Pricing.Count == 0
                ? fallback?.Prices(row.Slug, row.Models) ?? new Dictionary<string, ModelPrice>()
                : new Dictionary<string, ModelPrice>();
            var twins = new Dictionary<string, int>();
            var rows = new List<PriceRow>();
            foreach (var id in row.Models)
            {
                var name = ModelNames.DisplayModelName(id);
                if (words.Length > 0)
                {
                    var text = $"{id} {name} {title} {row.Slug}".ToLowerInvariant();
                    if (!words.All(text.Contains)) continue;
                }
                var price = row.Pricing.GetValueOrDefault(id) ?? listed.GetValueOrDefault(id);
                var detail = subscription ? Included : price is { Known: true } ? price.Line : NoPrice;
                var isCurrent = current is { } c && c.Model == id && row.Matches(c.Provider);
                var priceRow = new PriceRow($"{row.Slug}::{id}", id, name.Length == 0 ? id : name, detail,
                    subscription || price?.Known == true, isCurrent);
                string[] keys = ["id:" + id, "name:" + priceRow.Name.ToLowerInvariant()];
                var twin = keys.Select(k => twins.TryGetValue(k, out var t) ? t : -1).FirstOrDefault(t => t >= 0, -1);
                if (twin >= 0)
                {
                    var held = rows[twin];
                    if ((isCurrent && !held.Current) || (!held.Current && priceRow.Priced && !held.Priced)) rows[twin] = priceRow;
                }
                else
                {
                    foreach (var k in keys) twins[k] = rows.Count;
                    rows.Add(priceRow);
                }
            }
            if (rows.Count == 0) continue;
            string? footer;
            if (subscription)
                footer = row.Plan != null ? "Included in your plan’s allowance (see Usage & Limits)." : "Included with your subscription.";
            else if (row.Pricing.Count > 0) footer = PerMillion;
            else if (listed.Count > 0) footer = $"{PerMillion} List prices from models.dev.";
            else if (row.PricingPending) footer = "Prices are still loading on the computer running Hermes.";
            else if (fallbackFailed && fallback == null && ModelsDevPrices.CatalogId(row.Slug) != null) footer = FallbackFailedFooter;
            else footer = null;
            outList.Add(new PriceSection(row.Slug, title, rows, footer));
        }
        if (current is not { } cur) return outList;
        var slug = options.Row(cur.Provider)?.Slug;
        return [.. outList.Where(s => s.Id == slug), .. outList.Where(s => s.Id != slug)];
    }

    /// Providers whose prices only models.dev knows (so the page asks it).
    public static bool NeedsFallback(ModelOptions options) => options.Providers.Any(row =>
        row.Authenticated != false && row.Models.Count > 0 && row.Pricing.Count == 0 && row.Plan == null
        && !IsSubscription(row.Slug) && ModelsDevPrices.CatalogId(row.Slug) != null);

    /// The gateway warms its prices after a read: a provider it prices with none yet is asked once more a moment later.
    public static bool WorthAskingAgain(ModelOptions options) => options.Providers.Any(row =>
        row.Authenticated != false && row.Pricing.Count == 0 && row.Plan == null
        && (row.PricingPending || row.Slug is "openrouter" or "nous" || row.Slug.StartsWith("custom")));

    /// The ⋯ row's subtitle: the chat's model's price ("$5.00 in · $25.00 out"), "Included", or null.
    public static string? MenuSubtitle(ModelOptions? options, string model, string provider, ModelsDevPrices? fallback = null)
    {
        if (options?.Row(provider) is not { } row) return null;
        if (IsSubscription(row.Slug) || row.Plan != null) return Included;
        var listed = row.Pricing.Count == 0 ? fallback?.Prices(row.Slug, [model]).GetValueOrDefault(model) : null;
        if ((row.Pricing.GetValueOrDefault(model) ?? listed) is not { Known: true } price) return null;
        if (price.Free) return "Free";
        return string.Join(" · ", new[] { price.Input.Length == 0 ? null : $"{price.Input} in",
            price.Output.Length == 0 ? null : $"{price.Output} out" }.OfType<string>());
    }
}

/// models.dev's list prices (https://models.dev/api.json, the catalog Hermes bills direct providers by), reduced to
/// per provider, per model, dollars per million tokens.
public sealed class ModelsDevPrices
{
    public sealed record Cost(double? Input, double? Output, double? CacheRead, int? Context);

    public IReadOnlyDictionary<string, IReadOnlyDictionary<string, Cost>> Costs { get; }

    public ModelsDevPrices(IReadOnlyDictionary<string, IReadOnlyDictionary<string, Cost>> costs) => Costs = costs;

    /// The catalog file as models.dev serves it; null when it isn't one.
    public static ModelsDevPrices? Parse(string json)
    {
        if (J.Parse(json) is not JsonObject providers) return null;
        var costs = new Dictionary<string, IReadOnlyDictionary<string, Cost>>();
        foreach (var (id, provider) in providers)
        {
            var models = new Dictionary<string, Cost>();
            foreach (var (model, value) in provider.Obj("models") ?? [])
            {
                var cost = value.Obj("cost");
                var context = value.Obj("limit").Num("context") is { } c && double.IsFinite(c) && c > 0 ? (int?)c : null;
                var entry = new Cost(cost.Num("input"), cost.Num("output"), cost.Num("cache_read"), context);
                if (entry.Input != null || entry.Output != null || entry.Context != null) models[model] = entry;
            }
            if (models.Count > 0) costs[id] = models;
        }
        return costs.Count == 0 ? null : new ModelsDevPrices(costs);
    }

    /// The reduced catalog as stored on this PC.
    public string Encoded() => JsonSerializer.Serialize(Costs);

    public static ModelsDevPrices? DecodeStored(string text)
    {
        try
        {
            var raw = JsonSerializer.Deserialize<Dictionary<string, Dictionary<string, Cost>>>(text);
            return raw == null ? null : new ModelsDevPrices(raw.ToDictionary(p => p.Key, p => (IReadOnlyDictionary<string, Cost>)p.Value));
        }
        catch (JsonException) { return null; }
    }

    /// Hermes's provider ids as models.dev names them (H:agent/models_dev.py PROVIDER_TO_MODELS_DEV).
    public static readonly Dictionary<string, string> CatalogIds = new()
    {
        ["openrouter"] = "openrouter", ["novita"] = "novita-ai", ["anthropic"] = "anthropic", ["openai"] = "openai",
        ["openai-api"] = "openai", ["zai"] = "zai", ["kimi"] = "kimi-for-coding", ["kimi-coding"] = "kimi-for-coding",
        ["moonshot"] = "kimi-for-coding", ["stepfun"] = "stepfun", ["kimi-coding-cn"] = "kimi-for-coding",
        ["minimax"] = "minimax", ["minimax-cn"] = "minimax-cn", ["deepseek"] = "deepseek", ["alibaba"] = "alibaba",
        ["ai-gateway"] = "vercel", ["opencode-zen"] = "opencode", ["opencode-go"] = "opencode-go", ["kilocode"] = "kilo",
        ["fireworks"] = "fireworks-ai", ["huggingface"] = "huggingface", ["gemini"] = "google", ["google"] = "google",
        ["xai"] = "xai", ["xiaomi"] = "xiaomi", ["nvidia"] = "nvidia", ["meta-ai"] = "meta", ["meta"] = "meta",
        ["groq"] = "groq", ["mistral"] = "mistral", ["togetherai"] = "togetherai", ["together"] = "togetherai",
        ["perplexity"] = "perplexity", ["cohere"] = "cohere", ["ollama-cloud"] = "ollama-cloud",
    };

    public static string? CatalogId(string slug) => CatalogIds.GetValueOrDefault(slug.ToLowerInvariant());

    /// List prices for a provider's models: the id as is, then without a vendor prefix, then without a context suffix.
    public IReadOnlyDictionary<string, ModelPrice> Prices(string slug, IEnumerable<string> models)
    {
        var result = new Dictionary<string, ModelPrice>();
        if (Table(slug) is not { } table) return result;
        foreach (var model in models)
        {
            if (Entry(table, model) is not { } cost) continue;
            var price = ModelPrice.FromPerMillion(cost.Input, cost.Output, cost.CacheRead);
            if (price.Known) result[model] = price;
        }
        return result;
    }

    /// The model's context window in tokens; a provider models.dev doesn't name reads the first maker that lists it.
    public int? ContextWindow(string slug, string model)
    {
        if (Table(slug) is { } own && Entry(own, model)?.Context is { } c) return c;
        foreach (var id in new[] { "anthropic", "openai", "google", "xai", "deepseek", "mistral", "openrouter" })
            if (Costs.TryGetValue(id, out var t) && Entry(Lower(t), model)?.Context is { } found) return found;
        return null;
    }

    private Dictionary<string, Cost>? Table(string slug) =>
        CatalogId(slug) is { } id && Costs.TryGetValue(id, out var table) ? Lower(table) : null;

    private static Dictionary<string, Cost> Lower(IReadOnlyDictionary<string, Cost> table)
    {
        var d = new Dictionary<string, Cost>();
        foreach (var (k, v) in table) d.TryAdd(k.ToLowerInvariant(), v);
        return d;
    }

    private static readonly Regex Suffix = new(@"\[[^\]]*\]$");

    private static Cost? Entry(Dictionary<string, Cost> lower, string model)
    {
        var bare = model.Split('/').Last();
        var noSuffix = Suffix.Replace(bare, "");
        foreach (var key in new[] { model, bare, noSuffix })
            if (lower.TryGetValue(key.ToLowerInvariant(), out var c)) return c;
        return null;
    }
}

/// This PC's copy of models.dev's prices: kept a day in a file (reduced), fetched when missing or old; an old copy
/// answers when a fetch fails.
public sealed class ModelsDevCache
{
    public static readonly Uri Url = new("https://models.dev/api.json");
    public static readonly TimeSpan FreshFor = TimeSpan.FromHours(24);
    private readonly string _file;
    private readonly HttpClient _http;
    private (ModelsDevPrices Prices, DateTimeOffset At)? _memory;
    private Task<ModelsDevPrices?>? _inFlight;

    public ModelsDevCache(string file, HttpClient? http = null)
    {
        _file = file;
        _http = http ?? new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
    }

    /// What this PC has now (memory, else the file), with no network.
    public ModelsDevPrices? Stored()
    {
        if (_memory is { } m) return m.Prices;
        try
        {
            if (!File.Exists(_file) || ModelsDevPrices.DecodeStored(File.ReadAllText(_file)) is not { } prices) return null;
            _memory = (prices, File.GetLastWriteTimeUtc(_file));
            return prices;
        }
        catch (IOException) { return null; }
    }

    /// The prices, fetched when there are none or they are a day old.
    public async Task<ModelsDevPrices?> LoadAsync()
    {
        var old = Stored();
        if (_memory is { } m && DateTimeOffset.UtcNow - m.At < FreshFor) return m.Prices;
        _inFlight ??= Fetch();
        var fresh = await _inFlight;
        _inFlight = null;
        if (fresh != null) _memory = (fresh, DateTimeOffset.UtcNow);
        return fresh ?? old;
    }

    private async Task<ModelsDevPrices?> Fetch()
    {
        try
        {
            var text = await _http.GetStringAsync(Url);
            if (ModelsDevPrices.Parse(text) is not { } prices) return null;
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(_file)!);
                await File.WriteAllTextAsync(_file, prices.Encoded());
            }
            catch (IOException) { }
            return prices;
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException) { return null; }
    }
}
