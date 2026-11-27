using System.Text.Json.Nodes;
using Hermes.Core.Net;

namespace Hermes.Core.Insights;

/// How a document coming from the gateway meets this device's copy (`GatewaySyncMerge`).
public enum TileSyncMerge { Replace, FirstContact, Rebase }

/// The pins, the Tiles' pages and the removed artifacts as every device signed in to the gateway sees them
/// (HermesKit/Store/GatewaySync.swift): documents `ui_meta["hermes-hq-sync.pins"]` and `["hermes-hq-sync.hidden"]` on
/// the default bot's profile, each wrapped `{"v":1,"at":<ms>,"by":"<device>","data":…}`. Read from `profiles.list`;
/// written with `profiles.configure` (compare-and-swap where the gateway keeps revisions).
///
/// The Mac runs one sync for every synced store; this is the same protocol for the two documents the Tiles page owns,
/// run while the page is shown and after each change it makes.
public sealed class TileSync
{
    public const string KeyPrefix = "hermes-hq-sync.";
    public const int MaxBytes = 60_000;
    public const string DeviceName = "Windows PC";

    /// Calls a JSON-RPC method on the gateway in use (HermesClient.Rpc.RequestAsync in the app; a fake in tests).
    public delegate Task<JsonNode> Rpc(string method, JsonObject parameters, TimeSpan timeout, CancellationToken ct);

    private readonly Rpc _rpc;
    private readonly TilePinStore _pins;
    private readonly TileHidden _hidden;
    private readonly string? _statePath;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private JsonObject _state;
    private bool _adopting;

    /// The gateway can't keep synced documents (an older Hermes): nothing more is tried until the next change.
    public bool CantWrite { get; private set; }
    public int Writes { get; private set; }

    public TileSync(Rpc rpc, TilePinStore pins, TileHidden hidden, string? statePath)
    {
        _rpc = rpc;
        _pins = pins;
        _hidden = hidden;
        _statePath = statePath;
        _state = (statePath != null && File.Exists(statePath) ? J.Parse(File.ReadAllText(statePath)) as JsonObject : null) ?? [];
        // A store with nothing of its own on disk meets the gateway's copy as a new device does.
        if (pins.StartedEmpty) _state.Remove("pins");
        _pins.Changed += () => { if (!_adopting) MarkPending("pins"); };
        _hidden.Changed += () => { if (!_adopting) MarkPending("hidden"); };
    }

    private double Base(string name) => _state.Obj(name).Num("base") ?? 0;
    private bool Pending(string name) => _state.Obj(name).Bool("pending") ?? false;
    private JsonNode? Known(string name) => _state.Obj(name)?.Get("known");

    private void Set(string name, double? baseAt = null, bool? pending = null, JsonNode? known = null)
    {
        var o = _state.Obj(name) ?? new JsonObject();
        if (baseAt != null) o["base"] = baseAt;
        if (pending != null) o["pending"] = pending;
        if (known != null) o["known"] = known.DeepClone();
        _state[name] = o;
        SaveState();
    }

    private void MarkPending(string name)
    {
        CantWrite = false;
        Set(name, pending: true);
    }

    private void SaveState()
    {
        if (_statePath == null) return;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_statePath)!);
            File.WriteAllText(_statePath, _state.ToJsonString());
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    /// A document as the wire carries it (parsed again, so its numbers read as the gateway's do).
    private JsonNode Value(string name) => Wire(name == "pins" ? _pins.SyncValue() : _hidden.SyncValue());

    private static JsonNode Wire(JsonNode node) => JsonNode.Parse(node.ToJsonString())!;

    private void Adopt(string name, JsonNode data, TileSyncMerge merge)
    {
        _adopting = true;
        try
        {
            if (name == "pins") _pins.AdoptSynced(data, merge, Known(name));
            else _hidden.AdoptSynced(data);
        }
        finally { _adopting = false; }
        Set(name, known: merge == TileSyncMerge.Replace ? Value(name) : data);
    }

    public sealed record Envelope(double At, string By, JsonNode Data)
    {
        public static Envelope? From(JsonNode? raw)
        {
            if (raw is not JsonObject || raw.Int("v") != 1 || raw.Num("at") is not { } at) return null;
            var data = raw.Get("data");
            if (data == null) return null;
            return new Envelope(at, raw.Str("by") ?? "", data);
        }

        public JsonObject Json => (JsonObject)Wire(new JsonObject { ["v"] = 1, ["at"] = At, ["by"] = By, ["data"] = Data.DeepClone() });
    }

    /// The default bot's row of `profiles.list`.
    private static JsonNode? DefaultRow(JsonNode list)
    {
        var rows = list.Arr("profiles")?.OfType<JsonNode>().ToList() ?? [];
        return rows.FirstOrDefault(r => r.Str("name") == "default") ?? rows.FirstOrDefault(r => r.Bool("is_default") == true);
    }

    private async Task<JsonNode?> ReadRowAsync(CancellationToken ct)
    {
        var list = await _rpc("profiles.list", new JsonObject { ["include_sessions"] = false }, TimeSpan.FromSeconds(20), ct);
        return DefaultRow(list);
    }

    /// Takes in what another device wrote, then writes what waits here. Returns true when the pins changed from the
    /// gateway's copy. Never throws for a gateway that can't keep the documents.
    public async Task<bool> SyncAsync(CancellationToken ct = default)
    {
        await _gate.WaitAsync(ct);
        try
        {
            var row = await ReadRowAsync(ct);
            if (row == null) return false;
            var changed = Pull(row);
            if ((Pending("pins") || Pending("hidden")) && !CantWrite) await PublishAsync(row, ct);
            return changed;
        }
        finally { _gate.Release(); }
    }

    private bool Pull(JsonNode row)
    {
        var changed = false;
        foreach (var name in new[] { "hidden", "pins" })
        {
            var envelope = Envelope.From(row.Obj("ui_meta")?.Get(KeyPrefix + name));
            if (envelope == null)
            {
                if (!Pending(name)) Set(name, pending: true);   // none on the gateway yet: this device's copy goes up
                continue;
            }
            if (envelope.At <= Base(name) || Pending(name)) continue;   // a write settles a pending change (rebase)
            Adopt(name, envelope.Data, Base(name) == 0 ? TileSyncMerge.FirstContact : TileSyncMerge.Replace);
            Set(name, baseAt: envelope.At, pending: !JsonNode.DeepEquals(Value(name), envelope.Data));
            changed |= name == "pins";
        }
        return changed;
    }

    private async Task PublishAsync(JsonNode row, CancellationToken ct)
    {
        var profileName = row.Str("name") ?? "default";
        var supportsSwap = row.Obj("ui_meta_revisions") != null;
        var meta = new JsonObject();
        var expected = new JsonObject();
        var written = new Dictionary<string, (double At, JsonNode Value)>();
        var total = 0;
        foreach (var name in new[] { "pins", "hidden" })
        {
            if (!Pending(name)) continue;
            var key = KeyPrefix + name;
            var remote = Envelope.From(row.Obj("ui_meta")?.Get(key));
            if (remote != null && remote.At > Base(name))
            {
                Adopt(name, remote.Data, Base(name) == 0 ? TileSyncMerge.FirstContact : TileSyncMerge.Rebase);
                Set(name, baseAt: remote.At);
            }
            var value = Value(name);
            if (remote != null && JsonNode.DeepEquals(remote.Data, value))
            {
                Set(name, baseAt: remote.At, pending: false, known: value);
                continue;
            }
            var at = Math.Max(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), Math.Max((remote?.At ?? 0) + 1, Base(name) + 1));
            var json = new Envelope(at, DeviceName, value).Json;
            var size = System.Text.Encoding.UTF8.GetByteCount(json.ToJsonString());
            if (size > MaxBytes) { Set(name, pending: false, known: value); continue; }
            if (total + size > MaxBytes) continue;
            total += size;
            meta[key] = json;
            expected[key] = row.Obj("ui_meta_revisions")?.Int(key) ?? 0;
            written[name] = (at, value);
        }
        if (meta.Count == 0) return;
        var p = new JsonObject { ["name"] = profileName, ["ui_meta"] = meta };
        if (supportsSwap) p["ui_meta_expected_revisions"] = expected;
        JsonNode answer;
        try { answer = await _rpc("profiles.configure", p, TimeSpan.FromSeconds(20), ct); }
        catch (GatewayException e) when (e.Code == "rpc" && e.RpcCode is -32601 or 4000)
        {
            CantWrite = true;
            return;
        }
        Writes++;
        if (answer.Obj("applied")?.Bool("ui_meta") is not { } applied) { CantWrite = true; return; }
        if (!applied) return;   // a conflict: the next sync reads again
        foreach (var (name, w) in written)
            Set(name, baseAt: w.At, pending: !JsonNode.DeepEquals(Value(name), w.Value), known: w.Value);
    }
}
