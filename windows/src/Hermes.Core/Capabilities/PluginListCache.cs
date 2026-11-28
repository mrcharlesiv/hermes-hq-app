using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Hermes.Core.Capabilities;

/// Port of HermesKit/Store/PluginListCache.swift: 6-hour per-account `plugin-lists.json` disk cache so repeated
/// launch checks and background sweeps do not re-query every bot on slow gateways.
public sealed class PluginListCache
{
    public static PluginListCache Shared { get; } = new();

    /// How long a bot's cached plugin list stands in for asking again.
    public static readonly TimeSpan Keep = TimeSpan.FromHours(6);
    public const string FileName = "plugin-lists.json";

    public sealed record CachedPlugin(string Name, string Version, bool Enabled);

    public sealed record Entry(long AtMs, IReadOnlyList<CachedPlugin> Plugins);

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    private readonly string _root;
    private readonly Func<DateTimeOffset> _now;
    private readonly object _gate = new();
    private readonly Dictionary<string, Dictionary<string, Entry>> _accounts = new(StringComparer.Ordinal);

    public PluginListCache(string? root = null, Func<DateTimeOffset>? now = null)
    {
        _root = string.IsNullOrWhiteSpace(root)
            ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "HermesHQ", "pages")
            : root;
        _now = now ?? (() => DateTimeOffset.UtcNow);
    }

    public static string AccountFolderKey(string account)
    {
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(account));
        return Convert.ToHexString(hash)[..32].ToLowerInvariant();
    }

    public string FilePath(string account) => Path.Combine(_root, AccountFolderKey(account), FileName);

    private Dictionary<string, Entry> EntriesLocked(string account)
    {
        var key = AccountFolderKey(account);
        if (_accounts.TryGetValue(key, out var loaded)) return loaded;
        var path = Path.Combine(_root, key, FileName);
        Dictionary<string, Entry>? read = null;
        try
        {
            if (File.Exists(path))
                read = JsonSerializer.Deserialize<Dictionary<string, Entry>>(File.ReadAllText(path), JsonOptions);
        }
        catch (Exception) { }
        read ??= new Dictionary<string, Entry>(StringComparer.Ordinal);
        _accounts[key] = read;
        return read;
    }

    private void SaveLocked(Dictionary<string, Entry> entries, string account)
    {
        var key = AccountFolderKey(account);
        _accounts[key] = entries;
        var dir = Path.Combine(_root, key);
        var path = Path.Combine(dir, FileName);
        var tmp = path + ".tmp";
        try
        {
            Directory.CreateDirectory(dir);
            var json = JsonSerializer.Serialize(entries, JsonOptions);
            File.WriteAllText(tmp, json);
            File.Move(tmp, path, overwrite: true);
        }
        catch (Exception)
        {
            try { if (File.Exists(tmp)) File.Delete(tmp); } catch (Exception) { }
        }
    }

    /// Returns the bot's cached entry if read within `Keep`; timestamps ahead of the clock count as stale.
    public Entry? GetEntry(string account, string profile)
    {
        if (string.IsNullOrEmpty(account) || string.IsNullOrEmpty(profile)) return null;
        lock (_gate)
        {
            if (!EntriesLocked(account).TryGetValue(profile, out var entry)) return null;
            var ageMs = _now().ToUnixTimeMilliseconds() - entry.AtMs;
            return ageMs >= 0 && ageMs < (long)Keep.TotalMilliseconds ? entry : null;
        }
    }

    public void Store(IEnumerable<PluginInfo> plugins, string account, string profile)
    {
        if (string.IsNullOrEmpty(account) || string.IsNullOrEmpty(profile)) return;
        var cached = plugins.Select(p => new CachedPlugin(p.Name, p.Version, p.Enabled)).ToList();
        lock (_gate)
        {
            var all = EntriesLocked(account);
            // Whole milliseconds (truncated down) so an immediate read-back never looks ahead of the clock.
            all[profile] = new Entry(_now().ToUnixTimeMilliseconds(), cached);
            SaveLocked(all, account);
        }
    }

    /// Forgets one bot's cached list after a plugin mutation so the next check queries the gateway.
    public void Forget(string account, string profile)
    {
        if (string.IsNullOrEmpty(account) || string.IsNullOrEmpty(profile)) return;
        lock (_gate)
        {
            var all = EntriesLocked(account);
            if (!all.Remove(profile)) return;
            SaveLocked(all, account);
        }
    }

    /// Drops an account's cached entries (e.g. on sign-out or gateway removal).
    public void ForgetAccount(string account, bool deleteFile = false)
    {
        if (string.IsNullOrEmpty(account)) return;
        var key = AccountFolderKey(account);
        lock (_gate)
        {
            _accounts.Remove(key);
            if (deleteFile)
            {
                var path = Path.Combine(_root, key, FileName);
                try { if (File.Exists(path)) File.Delete(path); } catch (Exception) { }
            }
        }
    }

    /// Releases in-memory entries whose `plugin-lists.json` is already persisted on disk.
    public void TrimMemory()
    {
        lock (_gate)
        {
            var drop = _accounts.Keys.Where(key => File.Exists(Path.Combine(_root, key, FileName))).ToList();
            foreach (var key in drop) _accounts.Remove(key);
        }
    }
}
