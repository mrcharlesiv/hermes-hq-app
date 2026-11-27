using System.Globalization;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Net;

namespace Hermes.Core.Settings;

/// Dotted paths into the gateway's config record (HermesKit/Settings/ConfigSchema.swift `ConfigPath`).
public static class ConfigPath
{
    private static readonly HashSet<string> Unsafe = ["__proto__", "constructor", "prototype"];

    public static string[]? Parts(string path)
    {
        var parts = path.Split('.');
        return parts.All(p => p.Length > 0 && !Unsafe.Contains(p)) ? parts : null;
    }

    /// The value at a dotted path (null when any step is missing or not an object).
    public static JsonNode? Get(JsonNode? record, string path)
    {
        if (Parts(path) is not { } parts) return null;
        var current = record;
        foreach (var part in parts)
        {
            if (current is not JsonObject o) return null;
            current = o[part];
        }
        return current;
    }

    /// A copy of `record` with `value` at `path` (missing or non-object steps become objects).
    public static JsonObject Set(JsonNode? record, string path, JsonNode? value)
    {
        var copy = record is JsonObject o ? (JsonObject)o.DeepClone() : new JsonObject();
        if (Parts(path) is not { } parts) return copy;
        var at = copy;
        for (var i = 0; i < parts.Length - 1; i++)
        {
            if (at[parts[i]] is not JsonObject next) { next = new JsonObject(); at[parts[i]] = next; }
            at = next;
        }
        at[parts[^1]] = value?.DeepClone();
        return copy;
    }

    /// Only the branches of `next` that differ from `baseline` (objects key by key, arrays and scalars whole).
    /// `PUT /api/config` deep-merges, so a key the user never touched is never sent back with a stale value.
    public static JsonObject Diff(JsonNode? baseline, JsonNode? next)
    {
        var b = baseline as JsonObject;
        var patch = new JsonObject();
        if (next is not JsonObject n) return patch;
        foreach (var (key, nextValue) in n)
        {
            var has = b != null && b.ContainsKey(key);
            var baseValue = has ? b![key] : null;
            if (baseValue is JsonObject && nextValue is JsonObject)
            {
                var nested = Diff(baseValue, nextValue);
                if (nested.Count > 0) patch[key] = nested;
            }
            else if (!has || !JsonNode.DeepEquals(baseValue, nextValue))
            {
                if (!has && nextValue == null) continue;
                patch[key] = nextValue?.DeepClone();
            }
        }
        return patch;
    }

    /// Lays `patch` over `record` the way the gateway merges a PUT (objects merge, anything else replaces).
    public static JsonNode? Merge(JsonNode? record, JsonNode? patch)
    {
        if (record is not JsonObject r || patch is not JsonObject p) return patch?.DeepClone();
        var copy = (JsonObject)r.DeepClone();
        foreach (var (key, value) in p)
            copy[key] = copy[key] is JsonObject current && value is JsonObject ? Merge(current, value) : value?.DeepClone();
        return copy;
    }

    /// Clearing a non-empty Enabled Toolsets list (an explicit `[]`) turns off most tools: Import confirms it first.
    public static bool ClearsEnabledToolsets(JsonNode? previous, JsonNode? next) =>
        Get(previous, "toolsets") is JsonArray { Count: > 0 } && Get(next, "toolsets") is JsonArray { Count: 0 };
}

/// The gateway's answer `{ok: false}` to a save (HermesKit `SettingsSaveError.refused`).
public sealed class SettingsSaveRefused() : Exception("Your gateway didn’t accept the change.");

/// A write to a gateway this build keeps read-only (HermesKit `BotWriteError.readOnlyReason`).
public sealed class SettingsReadOnly() : Exception("Changes are turned off for this gateway in this build.");

/// The config calls Settings makes (HermesKit/Settings/GatewaySettingsAPI.swift): `GET /api/config`,
/// `GET /api/config/defaults` (Reset to Defaults…) and `PUT /api/config {config: patch}` (sparse, deep-merged).
public interface IGatewayConfigApi
{
    Task<JsonNode> ConfigAsync(CancellationToken ct = default);
    Task<JsonNode> DefaultsAsync(CancellationToken ct = default);
    Task SaveConfigAsync(JsonObject patch, CancellationToken ct = default);
}

public sealed class GatewayConfigApi(GatewaySession session, string? profile = null) : IGatewayConfigApi
{
    private IEnumerable<KeyValuePair<string, string>>? Query =>
        string.IsNullOrEmpty(profile) ? null : [new("profile", profile)];

    public Task<JsonNode> ConfigAsync(CancellationToken ct = default) => session.GetJsonAsync("/api/config", Query, ct: ct);

    /// Hermes' defaults: the gateway's own, never a bot's (no `?profile=`, as the Mac asks).
    public async Task<JsonNode> DefaultsAsync(CancellationToken ct = default)
    {
        var a = await session.SendAsync(HttpMethod.Get, "/api/config/defaults", ct: ct);
        return a.Ok && a.Body.Length == 0 ? new JsonObject() : GatewaySession.Require(a);
    }

    /// A gateway answer with `ok: false` is a refusal.
    public async Task SaveConfigAsync(JsonObject patch, CancellationToken ct = default)
    {
        var a = await session.SendAsync(HttpMethod.Put, "/api/config", Query, new JsonObject { ["config"] = patch.DeepClone() }, ct: ct);
        var answer = a.Ok && a.Body.Length == 0 ? new JsonObject() : GatewaySession.Require(a);
        if (answer is JsonObject o && o["ok"] is JsonValue v && v.TryGetValue(out bool ok) && !ok) throw new SettingsSaveRefused();
    }
}

/// Why a Settings list didn't load / a save didn't land, in words (HermesKit `SettingsErrorText`).
public static class SettingsErrorText
{
    private static string Raw(Exception error)
    {
        if (error is GatewayException { Code: "http" } http)
        {
            if (http.Body is { } body && J.Parse(body) is JsonObject o
                && (o.Str("detail") ?? o.Str("error") ?? o.Str("message")) is { } detail) return detail;
            return $"HTTP {http.Status}";
        }
        return error.Message;
    }

    private static bool Network(string text) => Regex.IsMatch(text,
        @"not connected|not open|offline|can.t reach|could not connect|network connection|internet connection|-100[3459]\b|socket", RegexOptions.IgnoreCase);

    private static bool Timeout(string text) => Regex.IsMatch(text, @"timed?\s*out|timeout|took too long|-1001\b", RegexOptions.IgnoreCase);

    private static bool Plain(string text) => text.Length <= 180 && !Regex.IsMatch(text, "[{}<>]") && !text.StartsWith("HTTP ", StringComparison.Ordinal);

    public static string Load(Exception error)
    {
        var text = Raw(error);
        if (error is OperationCanceledException || Timeout(text)) return "Your gateway didn’t answer in time. It may be busy; try again in a moment.";
        if (error is HttpRequestException || Network(text)) return "Hermes HQ can’t reach your gateway right now. It tries again when the connection is back.";
        if (error is GatewayException { Code: "http", Status: 404 }) return Insights.InsightsWire.OlderHermes;   // Mac UX stress test #10
        return Plain(text) ? text : "Your gateway couldn’t send this list. Try again in a moment.";
    }

    public static string Save(Exception error)
    {
        var text = Raw(error);
        if (error is OperationCanceledException || Timeout(text)) return "Your gateway didn’t answer in time. Try again in a moment.";
        if (error is HttpRequestException || Network(text)) return "Hermes HQ can’t reach your gateway right now. Try again when it’s back.";
        return Plain(text) ? text : "Your gateway didn’t accept the change.";
    }

    /// The gateway's own words, shown under Details when they differ from the plain ones.
    public static string? Detail(Exception error) => error switch
    {
        GatewayException { Code: "http" } http => $"HTTP {http.Status}",
        GatewayException { Code: "rpc" } rpc => rpc.Message,
        _ => null,
    };
}

/// The gateway's config record as the Settings config pages edit it (HermesKit/Settings/GatewayConfigStore.swift):
/// read once, edited as a local draft, autosaved 550 ms after the last change as a sparse patch against the record as it
/// was read, saves one at a time in order. A refused save puts the saved value back and keeps the change for Try Again.
/// Export, Import and Reset to Defaults read it fresh and write whole patches (`FreshAsync`, `WriteAsync`). Not ported:
/// the schema read (the generic config pages use it).
public sealed class GatewayConfigStore(IGatewayConfigApi api, bool readOnly = false)
{
    public enum LoadPhase { Idle, Loading, Loaded, Failed }

    public sealed record SaveFailure(string Text, string? Detail, JsonObject Patch);

    public LoadPhase Phase { get; private set; }
    public string? LoadError { get; private set; }
    /// The record as the pages show it: saved values plus edits not yet saved.
    public JsonNode? Config { get; private set; }
    public SaveFailure? Failure { get; private set; }
    public int Saving { get; private set; }
    /// The autosave delay (tests shorten it).
    public TimeSpan Debounce { get; set; } = TimeSpan.FromMilliseconds(550);
    /// Raised (on whatever thread the change happened) when Config, Phase, Failure or Saving changed.
    public event Action? Changed;

    private JsonNode _baseline = new JsonObject();
    private readonly object _lock = new();
    private readonly SemaphoreSlim _chain = new(1, 1);
    private CancellationTokenSource? _pending;
    private Task? _inFlight;
    private DateTime? _loadedAt;
    private bool _dirty;

    /// Where the store notes a load or save (the app sends it to AppLog under "settings"). Never a value.
    public static Action<string>? Log { get; set; }

    private void Notify() => Changed?.Invoke();

    public JsonNode? Value(string key) => Config is { } c ? ConfigPath.Get(c, key) : null;

    // ------------------------------------------------------------------ reading

    /// Reads the record. A page opened again re-reads after 30 s (never over unsaved edits).
    public Task LoadAsync(bool force = false)
    {
        lock (_lock)
        {
            if (_inFlight is { IsCompleted: false } running) return running;
            if (!force && Phase == LoadPhase.Loaded && _loadedAt is { } at && DateTime.UtcNow - at < TimeSpan.FromSeconds(30)) return Task.CompletedTask;
            if (_dirty || Saving > 0) return Task.CompletedTask;
            return _inFlight = ReadAsync();
        }
    }

    private async Task ReadAsync()
    {
        if (Config == null) { Phase = LoadPhase.Loading; Notify(); }
        try
        {
            var loaded = await api.ConfigAsync();
            lock (_lock)
            {
                if (_dirty || Saving > 0) return;
                _baseline = loaded.DeepClone();
                Config = loaded.DeepClone();
                _loadedAt = DateTime.UtcNow;
                Phase = LoadPhase.Loaded;
                LoadError = null;
            }
        }
        catch (Exception x) when (x is GatewayException or HttpRequestException or OperationCanceledException or System.Text.Json.JsonException)
        {
            Log?.Invoke($"config load failed: {x.GetType().Name}");
            if (Config == null) { Phase = LoadPhase.Failed; LoadError = SettingsErrorText.Load(x); }
            else Phase = LoadPhase.Loaded;
        }
        Notify();
    }

    // ------------------------------------------------------------------ editing

    /// One field changed: shown at once, saved after the debounce.
    public void Set(string key, JsonNode? value)
    {
        lock (_lock)
        {
            if (Config == null) return;
            Config = ConfigPath.Set(Config, key, value);
            _dirty = true;
            Failure = null;
            Schedule();
        }
        Notify();
    }

    /// Sends what's waiting now (a page going away). The returned task ends when that save has been answered.
    public Task Flush()
    {
        lock (_lock)
        {
            if (_pending == null) return Task.CompletedTask;
            _pending.Cancel();
            _pending = null;
        }
        return EnqueueSave();
    }

    private void Schedule()
    {
        _pending?.Cancel();
        var cts = new CancellationTokenSource();
        _pending = cts;
        var delay = Debounce;
        _ = Task.Run(async () =>
        {
            try { await Task.Delay(delay, cts.Token); } catch (OperationCanceledException) { return; }
            lock (_lock)
            {
                if (cts.IsCancellationRequested || _pending != cts) return;
                _pending = null;
            }
            await EnqueueSave();
        });
    }

    /// One save at a time, in order, so an older answer never lands after a newer one.
    private async Task EnqueueSave()
    {
        await _chain.WaitAsync();
        try { await SaveDraft(); }
        finally { _chain.Release(); }
    }

    private async Task SaveDraft()
    {
        JsonObject patch;
        lock (_lock)
        {
            if (Config == null) return;
            patch = ConfigPath.Diff(_baseline, Config);
            _dirty = _pending != null;
            if (patch.Count == 0) return;
        }
        if (readOnly) { Fail(patch, "Changes are turned off for this gateway in this build.", null); return; }
        lock (_lock) Saving++;
        Notify();
        try
        {
            await api.SaveConfigAsync(patch);
            lock (_lock) _baseline = ConfigPath.Merge(_baseline, patch)!;
            Log?.Invoke($"config saved ({patch.Count} group{(patch.Count == 1 ? "" : "s")})");
        }
        catch (Exception x) when (x is GatewayException or HttpRequestException or OperationCanceledException or SettingsSaveRefused or System.Text.Json.JsonException)
        {
            Log?.Invoke($"config save failed: {x.GetType().Name}");
            var text = SettingsErrorText.Save(x);
            var detail = SettingsErrorText.Detail(x);
            Fail(patch, text, detail == text ? null : detail);
        }
        finally
        {
            lock (_lock) Saving--;
            Notify();
        }
    }

    /// The page shows the saved value again; Try Again sends the same change.
    private void Fail(JsonObject patch, string text, string? detail)
    {
        lock (_lock)
        {
            Failure = new SaveFailure(text, detail, patch);
            if (!_dirty) Config = _baseline.DeepClone();
        }
        Notify();
    }

    public Task Retry()
    {
        lock (_lock)
        {
            if (Failure is not { } failure || Config == null) return Task.CompletedTask;
            Failure = null;
            Config = ConfigPath.Merge(Config, failure.Patch);
            _dirty = true;
        }
        Notify();
        return EnqueueSave();
    }

    public void DismissFailure() { Failure = null; Notify(); }

    // ------------------------------------------------------------------ Export, Import, Reset to Defaults

    /// The record as the gateway has it now (Export, Import), read fresh.
    public Task<JsonNode> FreshAsync() => api.ConfigAsync();

    /// Hermes' defaults (Reset to Defaults…).
    public Task<JsonNode> DefaultsAsync() => api.DefaultsAsync();

    /// Writes a whole patch now (Import's changes, Reset's defaults), after any edit still waiting, and throws when the
    /// gateway refuses. What was written shows at once; then the record is read again for what the gateway made of it.
    public async Task WriteAsync(JsonObject patch)
    {
        if (readOnly) throw new SettingsReadOnly();
        await Flush();
        await _chain.WaitAsync();
        try
        {
            if (patch.Count == 0) return;
            lock (_lock) Saving++;
            Notify();
            try { await api.SaveConfigAsync(patch); }
            finally
            {
                lock (_lock) Saving--;
                Notify();
            }
            Log?.Invoke("config replaced");
            lock (_lock)
            {
                _dirty = _pending != null;
                _baseline = ConfigPath.Merge(_baseline, patch)!;
                if (Config != null) Config = ConfigPath.Merge(Config, patch);
            }
        }
        finally { _chain.Release(); }
        Notify();
        Task? reading;
        lock (_lock) reading = _inFlight is { IsCompleted: false } running ? running : null;
        if (reading != null) await reading;
        lock (_lock) reading = !_dirty && Saving == 0 ? _inFlight = ReadAsync() : null;
        if (reading != null) await reading;
    }
}

/// Archiving & Project Folder's Auto-Archive Stale Chats (App/Settings/Config/VaultBillingPages.swift
/// `SessionsSettingsView`): `sessions.auto_archive` and `sessions.auto_archive_days` in the gateway's config, always
/// written together, as the web writes them.
public static class AutoArchive
{
    public const string EnabledKey = "sessions.auto_archive";
    public const string DaysKey = "sessions.auto_archive_days";

    public const string Title = "Auto-Archive Stale Chats";
    public const string DaysLabel = "Archive After";
    public const string DaysUnit = "days";
    public const string DaysPlaceholder = "30";
    public const string Footer = "Pinned chats are never archived, and nothing is deleted.";
    public const string LoadFailedTitle = "Couldn’t Load Settings";
    public const string SaveFailedTitle = "Couldn’t Save Your Change";

    /// Swift's `JSONValue.bool`: only a real boolean.
    public static bool Enabled(GatewayConfigStore store) => store.Value(EnabledKey) is JsonValue v && v.TryGetValue(out bool b) && b;

    /// `max(1, auto_archive_days ?? 30)`, a number truncated toward zero as Swift's `JSONValue.int`.
    public static long StoredDays(GatewayConfigStore store)
    {
        long? days = null;
        if (Number(store.Value(DaysKey)) is { } d && double.IsFinite(d) && Math.Abs(d) < 9.2e18)
            days = (long)Math.Truncate(d);
        return Math.Max(1, days ?? 30);
    }

    /// Swift's `JSONValue.double`: a number, or a string that reads as one.
    private static double? Number(JsonNode? node) => node switch
    {
        // Whatever backs the node (parsed JSON or a value set on this PC), its JSON text is the number.
        JsonValue v when v.GetValueKind() == System.Text.Json.JsonValueKind.Number
            && double.TryParse(v.ToJsonString(), NumberStyles.Float, CultureInfo.InvariantCulture, out var d) => d,
        JsonValue v when v.TryGetValue(out string? s) && double.TryParse(s,
            NumberStyles.AllowLeadingSign | NumberStyles.AllowDecimalPoint | NumberStyles.AllowExponent, CultureInfo.InvariantCulture, out var d) => d,
        _ => null,
    };

    /// The switch: both keys, sparse (the days as they are kept, 30 when unset).
    public static void Toggle(GatewayConfigStore store, bool on)
    {
        var days = StoredDays(store);
        store.Set(EnabledKey, JsonValue.Create(on));
        store.Set(DaysKey, JsonValue.Create(days));
    }

    /// Swift's `Int(String)` (64-bit): optional sign, digits only, nil on overflow.
    private static long? SwiftInt(string text) =>
        Regex.IsMatch(text, @"^[+-]?[0-9]+$") && long.TryParse(text, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var n) ? n : null;

    /// Archive After's field left or Return pressed (`commitDays`): a whole number of 1 or more, different from the kept
    /// one, is saved with the switch on; anything else that isn't a number of 1 or more puts the kept number back.
    /// Returns what the field shows afterwards.
    public static string CommitDays(GatewayConfigStore store, string text)
    {
        var stored = StoredDays(store);
        var value = SwiftInt(text.Trim());
        if (!Enabled(store) || value is not { } v || v < 1 || v == stored)
        {
            if (text.Length > 0 && (SwiftInt(text) is not { } raw || raw < 1)) return stored.ToString(CultureInfo.InvariantCulture);
            return text;
        }
        store.Set(EnabledKey, JsonValue.Create(true));
        store.Set(DaysKey, JsonValue.Create(v));
        return text;
    }
}
