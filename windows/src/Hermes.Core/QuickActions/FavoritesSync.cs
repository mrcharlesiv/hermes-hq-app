using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Hermes.Core.Composer;
using Hermes.Core.Insights;
using Hermes.Core.Net;

namespace Hermes.Core.QuickActions;

/// Cross-device sync for the Favorites page (`HermesKit/Intents/QuickTilesSync.swift`): carries `{tiles, pages}` in
/// `ui_meta["hermes-hq-sync.favorites"]` on the default bot's profile via `profiles.list` and `profiles.configure`
/// (with `ui_meta_expected_revisions` compare-and-swap when supported), while keeping device-local view state
/// (current page, gateway filter) on each device.
public sealed class FavoritesSync : IDisposable
{
    public const string KeyPrefix = TileSync.KeyPrefix;
    public const string SyncName = "favorites";
    public const string MetaKey = KeyPrefix + SyncName;
    public const int MaxBytes = TileSync.MaxBytes;
    public const string DeviceName = TileSync.DeviceName;
    public static readonly TimeSpan DefaultDebounce = TimeSpan.FromMilliseconds(1500);

    /// Calls a JSON-RPC method on the gateway in use (`HermesClient.Rpc.RequestAsync` in the app; a fake in tests).
    public delegate Task<JsonNode> Rpc(string method, JsonObject parameters, TimeSpan timeout, CancellationToken ct);

    public sealed record SyncedFavorites(IReadOnlyList<QuickTile> Tiles, IReadOnlyList<FavoritePage> Pages);

    public sealed record Envelope(double At, string By, JsonNode Data)
    {
        public static Envelope? From(JsonNode? raw)
        {
            if (raw is not JsonObject || raw.Int("v") != 1 || raw.Num("at") is not { } at) return null;
            var data = raw.Get("data");
            if (data == null) return null;
            return new Envelope(at, raw.Str("by") ?? "", data);
        }

        public JsonObject Json => (JsonObject)Wire(new JsonObject
        {
            ["v"] = 1,
            ["at"] = At,
            ["by"] = By,
            ["data"] = Data.DeepClone(),
        });
    }

    private readonly Rpc _rpc;
    private readonly IKeyValueStore _store;
    private readonly string? _statePath;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly object _debounceLock = new();
    private CancellationTokenSource? _debounceCts;
    private JsonObject _state;
    private bool _adopting;
    private bool _disposed;

    /// The gateway can't keep synced documents (an older Hermes): nothing more is tried until the next local edit.
    public bool CantWrite { get; private set; }
    public int Writes { get; private set; }

    /// Raised after remote changes were adopted into the local `IKeyValueStore`.
    public event Action? Adopted;

    public FavoritesSync(Rpc rpc, IKeyValueStore store, string? statePath = null)
    {
        _rpc = rpc;
        _store = store;
        _statePath = statePath;
        _state = (statePath != null && File.Exists(statePath) ? J.Parse(File.ReadAllText(statePath)) as JsonObject : null) ?? [];
        if (SyncStartedEmpty) _state.Remove(SyncName);
    }

    public bool SyncStartedEmpty => _store.Get(QuickTileStore.Key) == null;

    // ------------------------------------------------------------------ pure sync document & 3-way merge helpers

    public static JsonObject SyncValue(QuickTileList list)
    {
        var tiles = new JsonArray();
        foreach (var t in list.Tiles) tiles.Add(t.ToJson());
        var pages = new JsonArray();
        foreach (var p in list.Pages) pages.Add(p.ToJson());
        return (JsonObject)Wire(new JsonObject { ["tiles"] = tiles, ["pages"] = pages });
    }

    public static SyncedFavorites? DecodeSynced(JsonNode? value)
    {
        if (value is not JsonObject) return null;
        try
        {
            using var doc = JsonDocument.Parse(value.ToJsonString(), QuickTileJson.ReadOptions);
            if (doc.RootElement.ValueKind != JsonValueKind.Object) return null;
            var fields = QuickTileJson.Fields(doc.RootElement);
            var tilesEl = fields.GetValueOrDefault("tiles");
            var pagesEl = fields.GetValueOrDefault("pages");
            if (tilesEl.ValueKind != JsonValueKind.Array) return null;
            var tiles = tilesEl.EnumerateArray()
                .Select(e => QuickTile.Read(e) ?? QuickTile.FromUnreadable(QuickTileJson.Value(e)))
                .ToList();
            var pages = new List<FavoritePage>();
            if (pagesEl.ValueKind == JsonValueKind.Array)
            {
                foreach (var p in pagesEl.EnumerateArray())
                {
                    if (FavoritePage.Read(p) is { } page) pages.Add(page);
                }
            }
            return new SyncedFavorites(tiles, pages);
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException)
        {
            return null;
        }
    }

    /// Normalizes a synced page list (`FavoritesSync.normalizedPages`): `main` first, deduplicated by id, empty when
    /// only default `Home` exists.
    public static List<FavoritePage> NormalizedPages(IEnumerable<FavoritePage> pages)
    {
        var list = pages.ToList();
        if (list.Count == 0) return [];
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var output = new List<FavoritePage>();
        var main = list.FirstOrDefault(p => p.Id == FavoritePage.MainId) ?? FavoritePage.Main;
        seen.Add(main.Id);
        output.Add(main);
        foreach (var page in list)
        {
            if (seen.Add(page.Id)) output.Add(page);
        }
        return output.Count <= 1 && output[0] == FavoritePage.Main ? [] : output;
    }

    /// Applies a remote synced Favorites payload onto `local` using `Replace`, `FirstContact`, or 3-way `Rebase` merge.
    public static QuickTileList? AdoptSynced(QuickTileList local, JsonNode? value, TileSyncMerge merge, JsonNode? baseValue = null)
    {
        if (DecodeSynced(value) is not { } remote) return null;
        var remotePages = NormalizedPages(remote.Pages);
        List<QuickTile> nextTiles;
        List<FavoritePage> nextPages;

        switch (merge)
        {
            case TileSyncMerge.Replace:
                nextTiles = [.. remote.Tiles];
                nextPages = remotePages;
                break;

            case TileSyncMerge.FirstContact:
                if (local.Tiles.Count == 0 || (QuickTileStore.IsUneditedStarter(local) && remote.Tiles.Count > 0))
                {
                    nextTiles = [.. remote.Tiles];
                    nextPages = remotePages;
                }
                else
                {
                    var remoteTileIds = remote.Tiles.Select(t => t.Id).ToHashSet(StringComparer.Ordinal);
                    nextTiles = [.. remote.Tiles, .. local.Tiles.Where(t => !remoteTileIds.Contains(t.Id))];
                    var remotePageIds = remotePages.Select(p => p.Id).ToHashSet(StringComparer.Ordinal);
                    nextPages = NormalizedPages([.. remotePages, .. local.Pages.Where(p => !remotePageIds.Contains(p.Id))]);
                }
                break;

            default: // TileSyncMerge.Rebase
            {
                var was = (baseValue != null ? DecodeSynced(baseValue) : null) ?? new SyncedFavorites([], []);
                nextTiles = TilePinStore.Merged([.. remote.Tiles], [.. local.Tiles], [.. was.Tiles], t => t.Id);
                nextPages = NormalizedPages(TilePinStore.Merged(remotePages, [.. local.Pages], [.. was.Pages], p => p.Id));
                break;
            }
        }

        return new QuickTileList(nextTiles, seeded: true, pages: nextPages);
    }

    // ------------------------------------------------------------------ state & debounced gateway sync

    public void MarkLocalChanged()
    {
        if (_adopting || _disposed) return;
        CantWrite = false;
        SetState(pending: true);
    }

    /// Marks local changes pending and schedules a debounced `SyncAsync`.
    public void SchedulePush(TimeSpan? delay = null)
    {
        if (_adopting || _disposed) return;
        MarkLocalChanged();
        CancellationToken token;
        lock (_debounceLock)
        {
            _debounceCts?.Cancel();
            _debounceCts?.Dispose();
            _debounceCts = new CancellationTokenSource();
            token = _debounceCts.Token;
        }
        var wait = delay ?? DefaultDebounce;
        _ = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(wait, token).ConfigureAwait(false);
                if (!token.IsCancellationRequested && !_disposed)
                    await SyncAsync(token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) { }
            catch (GatewayException) { }
        }, token);
    }

    /// Pulls what another device wrote, then publishes what waits locally. Returns true when local Favorites changed
    /// from the gateway's copy.
    public async Task<bool> SyncAsync(CancellationToken ct = default)
    {
        await _gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            var row = await ReadDefaultRowAsync(ct).ConfigureAwait(false);
            if (row == null) return false;
            var changed = Pull(row);
            if (Pending && !CantWrite) await PublishAsync(row, ct).ConfigureAwait(false);
            if (changed) Adopted?.Invoke();
            return changed;
        }
        finally
        {
            _gate.Release();
        }
    }

    private double Base => _state.Obj(SyncName).Num("base") ?? 0;
    private bool Pending => _state.Obj(SyncName).Bool("pending") ?? false;
    private JsonNode? Known => _state.Obj(SyncName)?.Get("known");

    private void SetState(double? baseAt = null, bool? pending = null, JsonNode? known = null)
    {
        var o = _state.Obj(SyncName) ?? new JsonObject();
        if (baseAt != null) o["base"] = baseAt;
        if (pending != null) o["pending"] = pending;
        if (known != null) o["known"] = known.DeepClone();
        _state[SyncName] = o;
        SaveState();
    }

    private void SaveState()
    {
        if (_statePath == null) return;
        try
        {
            var dir = Path.GetDirectoryName(_statePath);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            File.WriteAllText(_statePath, _state.ToJsonString());
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private JsonObject CurrentValue() => SyncValue(QuickTileStore.Load(_store));

    private bool ApplyAdoption(JsonNode data, TileSyncMerge merge)
    {
        var local = QuickTileStore.Load(_store);
        if (AdoptSynced(local, data, merge, Known) is not { } merged) return false;
        _adopting = true;
        bool saved;
        try { saved = QuickTileStore.Save(merged, _store, notifySync: false); }
        finally { _adopting = false; }
        SetState(known: merge == TileSyncMerge.Replace ? CurrentValue() : data);
        return saved;
    }

    private bool Pull(JsonNode row)
    {
        var envelope = Envelope.From(row.Obj("ui_meta")?.Get(MetaKey));
        if (envelope == null)
        {
            if (!Pending) SetState(pending: true); // nothing on gateway yet: upload local copy
            return false;
        }
        if (envelope.At <= Base || Pending) return false; // pending local edits settle via rebase during publish
        var merge = Base == 0 ? TileSyncMerge.FirstContact : TileSyncMerge.Replace;
        var changed = ApplyAdoption(envelope.Data, merge);
        var now = CurrentValue();
        SetState(baseAt: envelope.At, pending: !JsonNode.DeepEquals(now, envelope.Data));
        return changed;
    }

    private async Task PublishAsync(JsonNode row, CancellationToken ct)
    {
        var profileName = row.Str("name") ?? "default";
        var supportsSwap = row.Obj("ui_meta_revisions") != null;
        var remote = Envelope.From(row.Obj("ui_meta")?.Get(MetaKey));
        if (remote != null && remote.At > Base)
        {
            ApplyAdoption(remote.Data, Base == 0 ? TileSyncMerge.FirstContact : TileSyncMerge.Rebase);
            SetState(baseAt: remote.At);
        }
        var value = CurrentValue();
        if (remote != null && JsonNode.DeepEquals(remote.Data, value))
        {
            SetState(baseAt: remote.At, pending: false, known: value);
            return;
        }
        var at = Math.Max(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), Math.Max((remote?.At ?? 0) + 1, Base + 1));
        var envelopeJson = new Envelope(at, DeviceName, value).Json;
        var bytes = Encoding.UTF8.GetByteCount(envelopeJson.ToJsonString());
        if (bytes > MaxBytes)
        {
            SetState(pending: false, known: value);
            return;
        }
        var meta = new JsonObject { [MetaKey] = envelopeJson };
        var p = new JsonObject { ["name"] = profileName, ["ui_meta"] = meta };
        if (supportsSwap)
        {
            p["ui_meta_expected_revisions"] = new JsonObject
            {
                [MetaKey] = row.Obj("ui_meta_revisions")?.Int(MetaKey) ?? 0,
            };
        }
        JsonNode answer;
        try { answer = await _rpc("profiles.configure", p, TimeSpan.FromSeconds(20), ct).ConfigureAwait(false); }
        catch (GatewayException e) when (e.Code == "rpc" && e.RpcCode is -32601 or 4000)
        {
            CantWrite = true;
            return;
        }
        Writes++;
        if (answer.Obj("applied")?.Bool("ui_meta") is not { } applied)
        {
            CantWrite = true;
            return;
        }
        if (!applied) return; // CAS conflict: next sync pulls & rebases
        SetState(baseAt: at, pending: !JsonNode.DeepEquals(CurrentValue(), value), known: value);
    }

    private async Task<JsonNode?> ReadDefaultRowAsync(CancellationToken ct)
    {
        var list = await _rpc("profiles.list", new JsonObject { ["include_sessions"] = false }, TimeSpan.FromSeconds(20), ct).ConfigureAwait(false);
        var rows = list.Arr("profiles")?.OfType<JsonNode>().ToList() ?? [];
        return rows.FirstOrDefault(r => r.Str("name") == "default") ?? rows.FirstOrDefault(r => r.Bool("is_default") == true);
    }

    private static JsonNode Wire(JsonNode node) => JsonNode.Parse(node.ToJsonString())!;

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        lock (_debounceLock)
        {
            _debounceCts?.Cancel();
            _debounceCts?.Dispose();
            _debounceCts = null;
        }
        _gate.Dispose();
    }
}
