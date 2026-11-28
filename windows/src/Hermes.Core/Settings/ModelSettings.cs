using System.Globalization;
using System.Text.Json.Nodes;
using Hermes.Core.Composer;
using Hermes.Core.Net;

namespace Hermes.Core.Settings;

/// Raised by `POST /api/model/set` when Hermes asks for confirmation before switching to an expensive model
/// (`HermesKit/Settings/GatewaySettingsAPI.swift` `ModelSetError.confirm`).
public sealed class ModelConfirmRequiredException(string message) : Exception(message);

/// Provider row returned by `GET /api/model/options?explicit_only=1` (`ModelProviderOption`).
public sealed record ModelProviderOption(
    string Slug,
    string Name,
    IReadOnlyList<string> Models,
    bool? Authenticated = null,
    string? AuthType = null,
    string? KeyEnv = null,
    string? ApiUrl = null,
    bool IsCurrent = false)
{
    /// Signed in or has models (`isProviderReady`).
    public bool IsReady => Authenticated != false || Models.Count > 0;

    public static ModelProviderOption? Parse(JsonNode? value)
    {
        if (value.Str("slug") is not { Length: > 0 } slug) return null;
        var models = (value.Arr("models") ?? []).Select(J.AsString).OfType<string>().ToList();
        return new ModelProviderOption(
            Slug: slug,
            Name: value.Text("name") ?? slug,
            Models: models,
            Authenticated: value.Bool("authenticated"),
            AuthType: value.Str("auth_type"),
            KeyEnv: value.Text("key_env"),
            ApiUrl: value.Text("api_url"),
            IsCurrent: value.Bool("is_current") ?? false);
    }
}

/// Active default model returned by `GET /api/model/info`.
public sealed record MainModelInfo(string Provider, string Model)
{
    public static MainModelInfo Parse(JsonNode? value) =>
        new(value.Str("provider") ?? "", value.Str("model") ?? "");
}

/// One `fallback_providers` entry: `{provider, model}` or a bare `"provider:model"` string
/// (`HermesKit/Settings/ConfigSchema.swift` `FallbackModel`).
public sealed record FallbackModel(string Provider, string Model)
{
    public static IReadOnlyList<FallbackModel> ParseList(JsonNode? value)
    {
        if (value is not JsonArray arr) return [];
        var list = new List<FallbackModel>();
        foreach (var item in arr)
        {
            if (J.AsString(item) is { } text)
            {
                var idx = text.IndexOf(':');
                list.Add(idx > 0
                    ? new FallbackModel(text[..idx], text[(idx + 1)..])
                    : new FallbackModel("", text));
                continue;
            }
            if (item.Str("provider") is { } provider && item.Str("model") is { } model)
                list.Add(new FallbackModel(provider, model));
        }
        return list;
    }

    public static JsonArray ToJson(IEnumerable<FallbackModel> list)
    {
        var arr = new JsonArray();
        foreach (var entry in list)
            arr.Add(new JsonObject { ["provider"] = entry.Provider, ["model"] = entry.Model });
        return arr;
    }
}

/// One auxiliary task's model assignment (`HermesKit/Settings/GatewaySettingsAPI.swift` `AuxiliaryAssignment`).
public sealed record AuxiliaryAssignment(string Task, string Provider, string Model, string BaseUrl = "")
{
    /// `"auto"` / `"main"` / empty: follows the main model.
    public bool FollowsMain => Provider.Trim().ToLowerInvariant() is "" or "auto" or "main";

    public static readonly IReadOnlyDictionary<string, string> TaskLabels = new Dictionary<string, string>(StringComparer.Ordinal)
    {
        ["vision"] = "Vision",
        ["compression"] = "Compression",
        ["skills_hub"] = "Skills Hub",
        ["approval"] = "Approvals",
        ["mcp"] = "Connectors",
        ["title_generation"] = "Chat Titles",
        ["review"] = "Review",
        ["triage_specifier"] = "Triage",
        ["kanban_decomposer"] = "Kanban Planning",
        ["profile_describer"] = "Bot Descriptions",
        ["curator"] = "Curator",
    };

    public static string Label(string task) =>
        TaskLabels.TryGetValue(task, out var known) ? known : ModelSettingsWords.PrettyKey(task);

    public static AuxiliaryAssignment? Parse(JsonNode? value)
    {
        if (value.Str("task") is not { Length: > 0 } task) return null;
        return new AuxiliaryAssignment(
            Task: task,
            Provider: value.Str("provider") ?? "",
            Model: value.Str("model") ?? "",
            BaseUrl: value.Str("base_url") ?? "");
    }
}

/// Display formatting helpers shared by Settings › Models, Fallback Models, Auxiliary Models, and MoA
/// (`App/Settings/Config/ModelPages.swift` & `HermesKit/Settings/MixtureRecord.swift`).
public static class ModelSettingsWords
{
    public const string None = "None";
    public const string MainModelPlaceholder = "Main Model";

    public static string PrettyKey(string raw)
    {
        var cleaned = raw.Replace('_', ' ').Replace('-', ' ').Trim();
        return cleaned.Length == 0 ? raw : CultureInfo.InvariantCulture.TextInfo.ToTitleCase(cleaned);
    }

    public static string ProviderName(string slug, IReadOnlyList<ModelProviderOption>? providers = null)
    {
        if (string.IsNullOrWhiteSpace(slug)) return None;
        var hit = providers?.FirstOrDefault(p => p.Slug == slug)
            ?? providers?.FirstOrDefault(p => string.Equals(p.Slug, slug, StringComparison.OrdinalIgnoreCase));
        return hit != null ? hit.Name : ModelNames.PlainProviderName(slug);
    }

    /// `"Opus 4.5 · Anthropic"` or `"None"` when unset.
    public static string Describe(string provider, string model, IReadOnlyList<ModelProviderOption>? providers = null)
    {
        if (string.IsNullOrWhiteSpace(model)) return None;
        return $"{ModelNames.DisplayModelName(model)} · {ProviderName(provider, providers)}";
    }
}

/// Pure helpers for Mixture of Agents records (`HermesKit/Settings/MixtureRecord.swift`).
public static class MixtureRecord
{
    public const string ProviderId = "moa";

    private static readonly string[] FlatKeys =
    [
        "aggregator", "aggregator_temperature", "reference_models", "reference_temperature",
        "reference_timeout", "degraded_reference_policy", "fanout", "enabled",
    ];

    public static JsonObject Presets(JsonNode? record) => record.Obj("presets") ?? new JsonObject();

    public static IReadOnlyList<string> PresetNames(JsonNode? record) =>
        [.. Presets(record).Select(p => p.Key).OrderBy(k => k, StringComparer.Ordinal)];

    public static string DefaultPreset(JsonNode? record)
    {
        var names = PresetNames(record);
        if (record.Str("default_preset") is { } named && names.Contains(named)) return named;
        return names.Count > 0 ? names[0] : "";
    }

    /// Every slot of every preset has a non-empty provider and model, and every preset has at least one reference model.
    public static bool Complete(JsonNode? record)
    {
        var presets = Presets(record);
        if (presets.Count == 0) return false;
        foreach (var (_, preset) in presets)
        {
            var refs = preset.Arr("reference_models");
            if (refs == null || refs.Count == 0) return false;
            if (!refs.All(SlotDone)) return false;
            if (!SlotDone(preset.Get("aggregator"))) return false;
        }
        return true;
    }

    private static bool SlotDone(JsonNode? slot) =>
        !string.IsNullOrWhiteSpace(slot.Str("provider")) && !string.IsNullOrWhiteSpace(slot.Str("model"));

    /// Mirrors the default preset's keys onto the record's top level (`MixtureRecord.mirrored`).
    public static JsonObject Mirrored(JsonNode? record)
    {
        var copy = record is JsonObject o ? (JsonObject)o.DeepClone() : new JsonObject();
        var def = DefaultPreset(copy);
        if (copy.Obj("presets")?.Get(def) is not JsonObject preset) return copy;
        foreach (var key in FlatKeys)
            if (preset.Get(key) is { } val) copy[key] = val.DeepClone();
        return copy;
    }

    public static string AdviceLine(JsonNode? preset)
    {
        var fanout = (preset.Str("fanout") ?? "user_turn").ToLowerInvariant();
        string often;
        if (fanout == "per_iteration")
            often = "at every step";
        else if (fanout.StartsWith("every_n:", StringComparison.Ordinal)
            && int.TryParse(fanout["every_n:".Length..], NumberStyles.Integer, CultureInfo.InvariantCulture, out var steps)
            && steps >= 2)
            often = $"every {steps} steps";
        else
            often = "once per message";
        return $"The aggregator answers and uses the tools. The reference models advise it {often}.";
    }
}

/// REST client for Settings › Models (`HermesKit/Settings/GatewaySettingsAPI.swift` Models section):
/// `GET /api/model/info`, `GET /api/model/options?explicit_only=1`, `GET /api/model/auxiliary`,
/// `POST /api/model/set` (`main` / `auxiliary`), `GET /api/model/moa`, `PUT /api/model/moa`.
public sealed class ModelSettingsApi(GatewaySession session, string? profile = null)
{
    private IReadOnlyList<KeyValuePair<string, string>> ProfileQuery =>
        string.IsNullOrWhiteSpace(profile) || profile == "default" ? [] : [new("profile", profile.Trim())];

    public async Task<MainModelInfo> GetModelInfoAsync(CancellationToken ct = default)
    {
        var a = await session.SendAsync(HttpMethod.Get, "/api/model/info", ProfileQuery, ct: ct);
        return MainModelInfo.Parse(GatewaySession.Require(a));
    }

    public async Task<IReadOnlyList<ModelProviderOption>> GetModelOptionsAsync(CancellationToken ct = default)
    {
        var query = new List<KeyValuePair<string, string>> { new("explicit_only", "1") };
        query.AddRange(ProfileQuery);
        var a = await session.SendAsync(HttpMethod.Get, "/api/model/options", query, ct: ct);
        var root = GatewaySession.Require(a);
        return [.. (root.Arr("providers") ?? []).Select(ModelProviderOption.Parse).OfType<ModelProviderOption>()];
    }

    public async Task<IReadOnlyList<AuxiliaryAssignment>> GetAuxiliaryModelsAsync(CancellationToken ct = default)
    {
        var a = await session.SendAsync(HttpMethod.Get, "/api/model/auxiliary", ProfileQuery, ct: ct);
        var root = GatewaySession.Require(a);
        return [.. (root.Arr("tasks") ?? []).Select(AuxiliaryAssignment.Parse).OfType<AuxiliaryAssignment>()];
    }

    /// `POST /api/model/set` for `main` or `auxiliary` scope. Throws `ModelConfirmRequiredException` if Hermes returns
    /// `confirm_required: true`, and `SettingsSaveRefused` if `ok: false`.
    public async Task<JsonNode> SetModelAsync(string scope, string provider, string model, string? task = null,
        string? baseUrl = null, bool confirmExpensive = false, CancellationToken ct = default)
    {
        var body = new JsonObject
        {
            ["scope"] = scope,
            ["provider"] = provider,
            ["model"] = model,
        };
        if (!string.IsNullOrEmpty(task)) body["task"] = task;
        if (!string.IsNullOrEmpty(baseUrl)) body["base_url"] = baseUrl;
        if (confirmExpensive) body["confirm_expensive_model"] = true;

        var a = await session.SendAsync(HttpMethod.Post, "/api/model/set", ProfileQuery, body, ct: ct);
        var answer = a.Ok && a.Body.Length == 0 ? new JsonObject() : GatewaySession.Require(a);
        if (answer.Bool("confirm_required") == true)
            throw new ModelConfirmRequiredException(answer.Text("confirm_message") ?? "This model costs more than most. Use it anyway?");
        if (answer.Bool("ok") == false) throw new SettingsSaveRefused();
        return answer;
    }

    public async Task<JsonNode> GetMoaAsync(CancellationToken ct = default)
    {
        var a = await session.SendAsync(HttpMethod.Get, "/api/model/moa", ProfileQuery, ct: ct);
        return GatewaySession.Require(a);
    }

    public async Task<JsonNode> SetMoaAsync(JsonNode body, CancellationToken ct = default)
    {
        var a = await session.SendAsync(HttpMethod.Put, "/api/model/moa", ProfileQuery, body.DeepClone(), ct: ct);
        var answer = a.Ok && a.Body.Length == 0 ? new JsonObject() : GatewaySession.Require(a);
        if (answer.Bool("ok") == false) throw new SettingsSaveRefused();
        return answer;
    }
}
