using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;

namespace Hermes.Core.Artifacts;

/// Removed artifacts (HermesKit/Pages/ArtifactHidden.swift; owner 2026-11-02: "You have a TON of artifacts saved from
/// email footers and other BS. Remove them."). Remove hides that file, picture or link from Artifacts in every chat that
/// names it, keyed as a pin is: the bot and the value. Nothing on the bot's computer changes. Kept on this PC per
/// account (&lt;root&gt;/hidden/&lt;account hash&gt;.json), across sign-outs. Not yet shared with the gateway (the Mac's
/// GatewaySync "hidden" document).
public sealed class ArtifactHidden
{
    /// The most kept; the oldest go first past it.
    public const int Limit = 5000;

    private static readonly Dictionary<string, ArtifactHidden> Stores = [];
    private readonly object _gate = new();
    private readonly List<string> _order;
    private readonly HashSet<string> _keys;

    public string? FilePath { get; }
    /// Raised after any change (on the thread that made it).
    public event Action? Changed;

    /// The removed artifacts of the account with this id under `root` (one store per account, made on first use).
    public static ArtifactHidden Of(string accountId, string root)
    {
        lock (Stores)
        {
            var path = FileOf(accountId, root);
            if (Stores.TryGetValue(path, out var store)) return store;
            return Stores[path] = new ArtifactHidden(path);
        }
    }

    public static string FileOf(string accountId, string root)
    {
        var hash = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(accountId)))[..16];
        return Path.Combine(root, "hidden", hash + ".json");
    }

    public ArtifactHidden(string? filePath)
    {
        FilePath = filePath;
        _order = [];
        if (filePath != null && File.Exists(filePath))
        {
            try
            {
                if (J.Parse(File.ReadAllText(filePath)) is JsonArray a)
                    _order.AddRange(a.Select(ArtifactSessionRow.Str).OfType<string>());
            }
            catch (IOException) { }
        }
        _keys = [.. _order];
    }

    /// The key a pin and a removal share: the bot ("default" when unset) and the value (`ArtifactPin.key`).
    public static string Key(string? profile, string value)
    {
        var p = (profile ?? "").Trim();
        return (p.Length == 0 ? "default" : p) + "\u001F" + value;
    }

    public bool IsEmpty { get { lock (_gate) return _keys.Count == 0; } }

    public bool IsHidden(string? profile, string value) { lock (_gate) return _keys.Contains(Key(profile, value)); }
    public bool IsHidden(ArtifactRecord record) => IsHidden(record.Profile, record.Value);

    /// Hides it everywhere.
    public void Hide(string? profile, string value)
    {
        var key = Key(profile, value);
        string[] snapshot;
        lock (_gate)
        {
            if (!_keys.Add(key)) return;
            _order.Add(key);
            if (_order.Count > Limit)
            {
                foreach (var gone in _order.Take(_order.Count - Limit)) _keys.Remove(gone);
                _order.RemoveRange(0, _order.Count - Limit);
            }
            snapshot = [.. _order];
        }
        if (FilePath != null)
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
                File.WriteAllText(FilePath, new JsonArray([.. snapshot.Select(k => (JsonNode)k)]).ToJsonString());
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
        Changed?.Invoke();
    }

    public void Hide(ArtifactRecord record) => Hide(record.Profile, record.Value);

    public List<ArtifactRecord> Visible(IEnumerable<ArtifactRecord> records)
    {
        lock (_gate) return _keys.Count == 0 ? [.. records] : [.. records.Where(r => !_keys.Contains(Key(r.Profile, r.Value)))];
    }
}
