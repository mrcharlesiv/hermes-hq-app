using System.Text.Json;
using System.Text.Json.Nodes;
using Hermes.Core.Composer;
using Hermes.Core.Notifications;

namespace Hermes.Core.Capabilities;

/// Port of App/Capabilities/PluginUpdates.swift `PluginUpdateReminder`: tracks third-party plugin updates across
/// bots, honors the per-gateway automatic check opt-out (`plugins.updateCheck.autoOff`), and runs serialized
/// one-at-a-time sweeps that stop early on gateway timeouts.
public static class PluginUpdateReminder
{
    public const string AutoCheckOffKey = "plugins.updateCheck.autoOff";

    public static string AutoCheckFooter =>
        "Checks your bots for plugin updates after launch. Turn off on slow gateways to check only when you ask or open Plugins.";

    /// How long a bot's plugin list stands before an automatic launch check queries it again.
    public static readonly TimeSpan Keep = PluginListCache.Keep;

    /// First-party add-ons managed by the dedicated Add-on Update flow rather than third-party plugin reminders.
    public static readonly IReadOnlySet<string> OwnAddOns = new HashSet<string>(StringComparer.Ordinal)
    {
        AddOnChanges.PushPluginName,
        AddOnChanges.BrowserPluginName,
        "dispatch-push",
        "dispatch-browser",
    };

    public sealed record Item(string Name, string From, string? To);

    private sealed class SavedState
    {
        public Dictionary<string, List<Item>> Items { get; set; } = new(StringComparer.Ordinal);
        public Dictionary<string, long> ReadMs { get; set; } = new(StringComparer.Ordinal);
        public Dictionary<string, string> Computer { get; set; } = new(StringComparer.Ordinal);
    }

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    private static readonly object Gate = new();
    private static IKeyValueStore? _store;
    private static Func<DateTimeOffset> _now = () => DateTimeOffset.UtcNow;
    private static string _account = "";
    private static SavedState _saved = new();
    private static bool _globalAutoOff;
    private static Dictionary<string, bool> _autoOffByAccount = new(StringComparer.Ordinal);
    private static bool _autoOffLoaded;

    public static event Action? Changed;

    /// Optional persistent key-value store backing reminder state and the automatic-check opt-out.
    public static IKeyValueStore? Store
    {
        get { lock (Gate) return _store; }
        set
        {
            lock (Gate)
            {
                _store = value;
                _autoOffLoaded = false;
                if (_account.Length > 0) _saved = LoadStateLocked(_account);
            }
        }
    }

    /// Whether automatic post-launch plugin-update checks are enabled (default `true`).
    public static bool IsAutomatic
    {
        get
        {
            lock (Gate)
            {
                EnsureAutoOffLoadedLocked();
                if (_account.Length > 0 && _autoOffByAccount.TryGetValue(_account, out var off))
                    return !off;
                return !_globalAutoOff;
            }
        }
        set
        {
            bool changed;
            lock (Gate)
            {
                EnsureAutoOffLoadedLocked();
                var was = _account.Length > 0 && _autoOffByAccount.TryGetValue(_account, out var cur) ? !cur : !_globalAutoOff;
                if (_account.Length > 0)
                {
                    if (value) _autoOffByAccount.Remove(_account);
                    else _autoOffByAccount[_account] = true;
                }
                else
                {
                    _globalAutoOff = !value;
                }
                SaveAutoOffLocked();
                changed = was != value;
            }
            if (changed) Changed?.Invoke();
        }
    }

    /// Per-account automatic check preference (defaults to `IsAutomatic` when unset for `account`).
    public static bool IsAutomaticFor(string? account)
    {
        lock (Gate)
        {
            EnsureAutoOffLoadedLocked();
            if (!string.IsNullOrEmpty(account) && _autoOffByAccount.TryGetValue(account, out var off))
                return !off;
            return !_globalAutoOff;
        }
    }

    public static void SetAutomaticFor(bool on, string? account)
    {
        if (string.IsNullOrEmpty(account))
        {
            IsAutomatic = on;
            return;
        }
        bool changed;
        lock (Gate)
        {
            EnsureAutoOffLoadedLocked();
            var was = _autoOffByAccount.TryGetValue(account, out var cur) ? !cur : !_globalAutoOff;
            if (on) _autoOffByAccount.Remove(account);
            else _autoOffByAccount[account] = true;
            SaveAutoOffLocked();
            changed = was != on;
        }
        if (changed) Changed?.Invoke();
    }

    /// True when `plugin` counts toward the third-party plugin update reminder.
    public static bool Counts(PluginInfo plugin) =>
        plugin.UpdateAvailable && !OwnAddOns.Contains(plugin.Name);

    /// Distinct plugin names with actionable updates (excluding computer-only Python-package updates), A–Z.
    public static IReadOnlyList<string> Names
    {
        get { lock (Gate) return ComputeNamesLocked(_saved); }
    }

    public static int AvailableCount
    {
        get { lock (Gate) return ComputeNamesLocked(_saved).Count; }
    }

    /// "1 Update" / "N Updates" / null (used by Capabilities › Plugins row and Settings badges).
    public static string? BadgeLabel => AvailableCount switch
    {
        0 => null,
        1 => "1 Update",
        var n => $"{n} Updates",
    };

    public static string? Title => AvailableCount switch
    {
        0 => null,
        1 => "Plugin Update Available",
        var n => $"{n} Plugin Updates Available",
    };

    public static string? Footer
    {
        get
        {
            var names = Names.Select(AddOnChanges.DisplayTitle).ToList();
            if (names.Count == 0) return null;
            return names.Count == 1
                ? $"{names[0]} has a newer version."
                : $"{AddOnReminder.Names(names)} have newer versions.";
        }
    }

    public static string? Spoken => AvailableCount switch
    {
        0 => null,
        1 => "Plugin update available",
        var n => $"{n} plugin updates available",
    };

    /// Switches the active account; `""` (signed out) clears visible updates.
    public static void Use(string account)
    {
        var fire = false;
        lock (Gate)
        {
            if (account == _account) return;
            var before = ComputeNamesLocked(_saved);
            _account = account;
            _saved = account.Length == 0 ? new SavedState() : LoadStateLocked(account);
            var after = ComputeNamesLocked(_saved);
            fire = !before.SequenceEqual(after, StringComparer.Ordinal);
        }
        if (fire) Changed?.Invoke();
    }

    /// Reports one bot's freshly read plugin list, replacing its prior update entries.
    public static void Report(string account, string profile, IEnumerable<PluginInfo> list)
    {
        if (string.IsNullOrEmpty(account) || string.IsNullOrEmpty(profile)) return;
        var items = list.Where(Counts).Select(p => new Item(p.Name, p.Version, p.NewVersion)).ToList();
        var fire = false;
        lock (Gate)
        {
            if (account != _account)
            {
                _account = account;
                _saved = LoadStateLocked(account);
            }
            var before = ComputeNamesLocked(_saved);
            if (items.Count == 0) _saved.Items.Remove(profile);
            else _saved.Items[profile] = items;
            _saved.ReadMs[profile] = _now().ToUnixTimeMilliseconds();
            SaveStateLocked(account, _saved);
            var after = ComputeNamesLocked(_saved);
            fire = !before.SequenceEqual(after, StringComparer.Ordinal);
        }
        if (fire) Changed?.Invoke();
    }

    /// Prunes entries belonging to bots that no longer exist on the active account.
    public static void KeepProfiles(string account, IEnumerable<string> profiles)
    {
        if (string.IsNullOrEmpty(account)) return;
        var known = profiles.ToHashSet(StringComparer.Ordinal);
        var fire = false;
        lock (Gate)
        {
            if (account != _account) return;
            var before = ComputeNamesLocked(_saved);
            var removed = false;
            foreach (var key in _saved.Items.Keys.Where(k => !known.Contains(k)).ToList())
            {
                _saved.Items.Remove(key);
                removed = true;
            }
            foreach (var key in _saved.ReadMs.Keys.Where(k => !known.Contains(k)).ToList())
            {
                _saved.ReadMs.Remove(key);
                removed = true;
            }
            if (!removed) return;
            SaveStateLocked(account, _saved);
            var after = ComputeNamesLocked(_saved);
            fire = !before.SequenceEqual(after, StringComparer.Ordinal);
        }
        if (fire) Changed?.Invoke();
    }

    /// Marks `name`'s target version `to` as requiring Hermes's computer (Python dependencies) so it stops badging
    /// until a newer version is released.
    public static void NoteNeedsComputer(string account, string name, string? to)
    {
        if (string.IsNullOrEmpty(account) || string.IsNullOrEmpty(name)) return;
        var fire = false;
        lock (Gate)
        {
            if (account != _account)
            {
                _account = account;
                _saved = LoadStateLocked(account);
            }
            var before = ComputeNamesLocked(_saved);
            _saved.Computer[name] = to ?? "";
            SaveStateLocked(account, _saved);
            var after = ComputeNamesLocked(_saved);
            fire = !before.SequenceEqual(after, StringComparer.Ordinal);
        }
        if (fire) Changed?.Invoke();
    }

    public static bool NeedsComputer(string name, string? to)
    {
        lock (Gate)
            return _saved.Computer.TryGetValue(name, out var held) && string.Equals(held, to ?? "", StringComparison.Ordinal);
    }

    /// True if `profile` was read within `Keep` (timestamps ahead of the clock count as stale).
    public static bool IsFresh(string profile)
    {
        lock (Gate)
        {
            if (!_saved.ReadMs.TryGetValue(profile, out var atMs)) return false;
            var ageMs = _now().ToUnixTimeMilliseconds() - atMs;
            return ageMs >= 0 && ageMs < (long)Keep.TotalMilliseconds;
        }
    }

    public static IReadOnlyList<Item> ItemsFor(string profile)
    {
        lock (Gate)
            return _saved.Items.TryGetValue(profile, out var items) ? [.. items] : [];
    }

    /// Forgets persisted reminder state for `account` on sign-out.
    public static void SignOut(string account)
    {
        if (string.IsNullOrEmpty(account)) return;
        var fire = false;
        lock (Gate)
        {
            _store?.Set(StateKey(account), null);
            if (account == _account)
            {
                var before = ComputeNamesLocked(_saved);
                _saved = new SavedState();
                fire = before.Count > 0;
            }
        }
        if (fire) Changed?.Invoke();
    }

    /// On-demand manual check across `profiles`, querying bots serially one at a time and stopping early on timeout.
    public static Task CheckNowAsync(HermesClient client, IEnumerable<string> profiles, CancellationToken ct = default)
    {
        var api = new CapabilitiesApi(client.Session, client.Rpc);
        return CheckStaleAsync(api, client.AccountId, profiles, automatic: false, ct: ct);
    }

    /// On-demand check using an existing `CapabilitiesApi` (shares flight coalescing and timeout backoff).
    public static Task<int> CheckNowAsync(CapabilitiesApi api, string account, IEnumerable<string> profiles, CancellationToken ct = default) =>
        CheckStaleAsync(api, account, profiles, automatic: false, ct: ct);

    /// Serial one-at-a-time plugin-list sweep across `profiles`.
    /// When `automatic` is true: honors `IsAutomaticFor(account)`, read-only gateways, `PluginListTimedOutRecently()`,
    /// and 6-hour per-profile freshness (`IsFresh`). Always stops early on a timeout so slow gateways are not saturated.
    /// Returns how many profiles were queried.
    public static async Task<int> CheckStaleAsync(
        CapabilitiesApi api,
        string account,
        IEnumerable<string> profiles,
        bool automatic = true,
        Func<bool>? isConnected = null,
        CancellationToken ct = default)
    {
        if (string.IsNullOrEmpty(account) || api.ReadOnly) return 0;
        if (automatic && !IsAutomaticFor(account)) return 0;

        var list = PluginUpdateWords.Distinct(profiles.Where(p => !string.IsNullOrWhiteSpace(p)));
        Use(account);
        KeepProfiles(account, list);

        if (automatic && api.PluginListTimedOutRecently()) return 0;

        var targets = automatic ? list.Where(p => !IsFresh(p)).ToList() : list;
        if (targets.Count == 0) return 0;

        var checkedCount = 0;
        foreach (var profile in targets)
        {
            if (ct.IsCancellationRequested) return checkedCount;
            if (isConnected != null && !isConnected()) return checkedCount;
            if (automatic && !IsAutomaticFor(account)) return checkedCount;

            checkedCount++;
            try
            {
                await api.PluginsAsync(profile, ct).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                return checkedCount;
            }
            catch (Exception ex)
            {
                if (CapabilitiesApi.IsTimeout(ex)) return checkedCount;
            }
        }
        return checkedCount;
    }

    /// Resets static state for unit tests.
    internal static void ResetForTests(IKeyValueStore? store = null, Func<DateTimeOffset>? now = null)
    {
        lock (Gate)
        {
            _store = store;
            _now = now ?? (() => DateTimeOffset.UtcNow);
            _account = "";
            _saved = new SavedState();
            _globalAutoOff = false;
            _autoOffByAccount = new Dictionary<string, bool>(StringComparer.Ordinal);
            _autoOffLoaded = false;
        }
    }

    // ---------------------------------------------------------------- Persistence helpers

    private static string StateKey(string account) => $"plugins.updateReminder.{account}";

    private static List<string> ComputeNamesLocked(SavedState state)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var items in state.Items.Values)
        {
            foreach (var item in items)
            {
                if (state.Computer.TryGetValue(item.Name, out var held) && string.Equals(held, item.To ?? "", StringComparison.Ordinal))
                    continue;
                seen.Add(item.Name);
            }
        }
        return [.. seen.OrderBy(n => n, StringComparer.OrdinalIgnoreCase)];
    }

    private static SavedState LoadStateLocked(string account)
    {
        if (_store?.Get(StateKey(account)) is not { Length: > 0 } raw) return new SavedState();
        try
        {
            var loaded = JsonSerializer.Deserialize<SavedState>(raw, JsonOptions);
            if (loaded != null)
            {
                loaded.Items ??= new Dictionary<string, List<Item>>(StringComparer.Ordinal);
                loaded.ReadMs ??= new Dictionary<string, long>(StringComparer.Ordinal);
                loaded.Computer ??= new Dictionary<string, string>(StringComparer.Ordinal);
                return loaded;
            }
        }
        catch (Exception) { }
        return new SavedState();
    }

    private static void SaveStateLocked(string account, SavedState state)
    {
        if (_store == null) return;
        try { _store.Set(StateKey(account), JsonSerializer.Serialize(state, JsonOptions)); }
        catch (Exception) { }
    }

    private static void EnsureAutoOffLoadedLocked()
    {
        if (_autoOffLoaded) return;
        _autoOffLoaded = true;
        if (_store?.Get(AutoCheckOffKey) is not { Length: > 0 } raw) return;
        if (J.Parse(raw) is JsonObject obj)
        {
            foreach (var (k, v) in obj)
            {
                if (v is JsonValue jv && jv.TryGetValue(out bool b) && b)
                {
                    if (k == "*") _globalAutoOff = true;
                    else _autoOffByAccount[k] = true;
                }
            }
        }
    }

    private static void SaveAutoOffLocked()
    {
        if (_store == null) return;
        var obj = new JsonObject();
        if (_globalAutoOff) obj["*"] = true;
        foreach (var (k, v) in _autoOffByAccount)
        {
            if (v) obj[k] = true;
        }
        _store.Set(AutoCheckOffKey, obj.Count == 0 ? null : obj.ToJsonString());
    }
}
