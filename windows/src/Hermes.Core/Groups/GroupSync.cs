using System.Diagnostics;
using System.Text.Json.Nodes;
using Hermes.Core.Bots;
using Hermes.Core.Net;

namespace Hermes.Core.Groups;

// [groups] The mirror's pull and publish (HermesKit/Groups/GroupSync.swift; docs/spec/3x-groups.md §5.3): a port of
// `flushGroupChatServerSync`. One publish in flight; compare-and-swap on gateways that have it; a retry ladder. The
// mirror rides `profiles.list` / `profiles.configure` on the default profile's `ui_meta["hermes-bots-groups"]`.
// Every call happens on the caller's synchronization context, as the Mac's runs on the main actor.
public sealed class GroupSync
{
    private readonly GroupStore store;
    private readonly IListsGateway client;
    /// The mirror key's revision as last read from the gateway.
    public int RemoteRevision { get; private set; }
    private readonly HashSet<string> pendingChanged = [];
    private readonly HashSet<string> pendingDeleted = [];
    private CancellationTokenSource? debounce;
    private bool flushing;
    /// Room keys scheduled after the publish in flight took its picture of the rooms: they stay pending when it lands.
    private HashSet<string> lateKeys = [];
    private int failures;
    private int? gaveUpRevision;
    private bool closed;
    private JsonNode? lastPulled;
    private bool pulledOnce;
    /// Test hooks: the debounce and the back-off's unit.
    public TimeSpan Debounce { get; set; } = TimeSpan.FromMilliseconds(350);
    public double BackoffUnitSeconds { get; set; } = 1;
    public TimeSpan ReadTimeout { get; set; } = TimeSpan.FromSeconds(20);
    public const int MaxTries = 8;
    /// The app's log ("groups" lines: counts and timings only, never a room's words).
    public Action<string>? Log { get; set; }
    /// Publishes made (tests read it).
    public int Publishes { get; private set; }

    public GroupSync(GroupStore store, IListsGateway client)
    {
        this.store = store;
        this.client = client;
        store.OnMirrorChange = key => Schedule(changed: key);
    }

    public void Shutdown()
    {
        closed = true;
        debounce?.Cancel();
        debounce = null;
    }

    public bool HasPending => pendingChanged.Count > 0 || pendingDeleted.Count > 0;

    /// The default profile's row from a fresh `profiles.list` (else the `is_default` one): merge its mirror into the
    /// device's rooms, then send what waits. `slim`: the roster has reached its slim phase (writes may go out).
    public void Pulled(JsonNode? defaultRow, bool slim = true)
    {
        if (closed || defaultRow == null) return;
        defaultRow = JsonNode.Parse(defaultRow.ToJsonString());   // lenient reads expect parsed numbers
        RemoteRevision = (int)(defaultRow.Obj("ui_meta_revisions").Int(GroupSnapshot.MetaKey) ?? 0);
        var raw = defaultRow.Obj("ui_meta").Get(GroupSnapshot.MetaKey);
        var first = !pulledOnce;
        pulledOnce = true;
        if (!JsonNode.DeepEquals(raw, lastPulled) || first)
        {
            lastPulled = raw?.DeepClone();
            var mirror = GroupSnapshot.Parse(raw);
            store.AdoptTombstones(mirror.Deleted);
            store.Adopt(GroupSnapshot.Apply(mirror, store.Rooms, store.Tombstones, pendingChanged));
            // A Delete Group Chat cut off by the app closing: the tombstone is on the device, the room still in the mirror.
            if (first)
            {
                foreach (var (key, revision) in store.Tombstones)
                {
                    if (mirror.Deleted.ContainsKey(key) || pendingChanged.Contains(key) || !mirror.Rooms.TryGetValue(key, out var room)) continue;
                    if (key.StartsWith("id:", StringComparison.Ordinal) || revision >= room.Revision) pendingDeleted.Add(key);
                }
            }
        }
        if (!HasPending || debounce != null || flushing || !slim) return;
        // A ladder that gave up is not started again by every refresh: only a new change does, or a mirror that moved.
        if (failures >= MaxTries)
        {
            if (RemoteRevision == gaveUpRevision) return;
            failures = 0;
        }
        gaveUpRevision = null;
        Arm(Debounce);
    }

    /// 350 ms after the last change that touches the mirror.
    public void Schedule(string? changed = null, string? deleted = null)
    {
        if (changed != null) { pendingChanged.Add(changed); pendingDeleted.Remove(changed); }
        if (deleted != null) { pendingDeleted.Add(deleted); pendingChanged.Remove(deleted); }
        if (flushing) { if (changed != null) lateKeys.Add(changed); if (deleted != null) lateKeys.Add(deleted); }
        if (closed || !HasPending) return;
        if (changed != null || deleted != null) { failures = 0; gaveUpRevision = null; }   // a new change starts a new ladder
        if (failures >= MaxTries) return;
        Arm(Debounce);
    }

    private void Arm(TimeSpan after)
    {
        debounce?.Cancel();
        var cts = new CancellationTokenSource();
        debounce = cts;
        _ = Fire(cts, after);
    }

    private async Task Fire(CancellationTokenSource cts, TimeSpan after)
    {
        try { await Task.Delay(after, cts.Token); } catch (TaskCanceledException) { return; }
        if (cts.IsCancellationRequested || debounce != cts) return;
        debounce = null;
        await Flush();
    }

    /// Runs the pending publish now (tests; the app goes to the background).
    public async Task FlushNow()
    {
        debounce?.Cancel();
        debounce = null;
        await Flush();
    }

    private async Task Flush()
    {
        if (closed || flushing || !HasPending) return;
        flushing = true;
        lateKeys = [];
        var changed = pendingChanged.ToHashSet();
        var deleted = pendingDeleted.ToHashSet();
        var started = Stopwatch.StartNew();
        var done = false;
        var offline = false;
        try { done = await Publish(changed, deleted); }
        catch (GatewayException e) when (e.Code == "offline") { offline = true; }
        catch (Exception) { done = false; }
        flushing = false;
        var late = lateKeys;
        lateKeys = [];
        if (closed) return;
        if (done)
        {
            Log?.Invoke($"mirror publish: {changed.Count} changed, {deleted.Count} deleted, in {started.ElapsedMilliseconds} ms");
            // Only what this write carried is settled: a key scheduled after its picture was taken goes out next.
            pendingChanged.ExceptWith(changed.Except(late));
            pendingDeleted.ExceptWith(deleted.Except(late));
            failures = 0;
            gaveUpRevision = null;
            if (HasPending) Arm(Debounce);
        }
        else if (offline)
        {
            Log?.Invoke("mirror publish: offline, kept for the next pull");
        }
        else
        {
            failures += 1;
            if (failures >= MaxTries)
            {
                Log?.Invoke($"mirror publish: gave up after {failures} tries at revision {RemoteRevision}");
                gaveUpRevision = RemoteRevision;
                return;
            }
            Log?.Invoke($"mirror publish: attempt {failures} failed, retrying");
            var wait = Math.Min(30, BackoffUnitSeconds * Math.Pow(2, Math.Min(failures - 1, 5)));
            Arm(TimeSpan.FromSeconds(wait));
        }
    }

    /// Read, merge, write with compare-and-swap. false = conflict or a refused write (try again).
    private async Task<bool> Publish(HashSet<string> changed, HashSet<string> deleted)
    {
        var read = await client.CallAsync("profiles.list", new JsonObject { ["include_sessions"] = false }, ReadTimeout);
        if (closed) return false;
        var row = (read.Arr("profiles") ?? []).FirstOrDefault(p => p.Str("name") == "default");
        if (row == null) return false;
        var supportsSwap = row.Obj("ui_meta_revisions") != null;
        var revision = (int)Math.Max(0, row.Obj("ui_meta_revisions").Int(GroupSnapshot.MetaKey) ?? 0);
        RemoteRevision = revision;
        var remote = GroupSnapshot.Parse(row.Obj("ui_meta").Get(GroupSnapshot.MetaKey));
        store.AdoptTombstones(remote.Deleted);
        // What another device wrote since the last pull comes in first, so the write below never drops it.
        store.Adopt(GroupSnapshot.Apply(remote, store.Rooms, store.Tombstones, changed));
        lateKeys = [];
        var local = GroupSnapshot.Local(store.Rooms, store.Tombstones);
        var writeRevision = revision + 1;
        var removed = new Dictionary<string, HashSet<string>>();
        foreach (var r in store.Rooms.Where(r => r.Removed.Count > 0)) removed[r.Key] = [.. r.Removed];
        var merged = GroupSnapshot.Merge(remote, local, changed, deleted, removed, writeRevision);
        var made = GroupSnapshot.Envelope(merged, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
        // Never an envelope with no rooms, unless this write deletes the last one.
        if (made.Kept.Rooms.Count == 0 && deleted.Count == 0 && remote.Rooms.Count > 0) return true;
        if (made.Kept.SameRooms(remote) && made.Kept.SameDeleted(remote) && remote.Version >= 3) return true;
        var parameters = new JsonObject { ["name"] = "default", ["ui_meta"] = new JsonObject { [GroupSnapshot.MetaKey] = made.Json } };
        if (supportsSwap) parameters["ui_meta_expected_revisions"] = new JsonObject { [GroupSnapshot.MetaKey] = revision };
        var answer = await client.CallAsync("profiles.configure", parameters, ReadTimeout);
        Publishes += 1;
        if (closed) return true;
        if (answer.Obj("applied").Bool("ui_meta") != true) return false;
        if (supportsSwap && answer.Obj("applied").Obj("ui_meta_revisions").Int(GroupSnapshot.MetaKey) != writeRevision) return false;
        RemoteRevision = supportsSwap ? writeRevision : revision;
        lastPulled = null;
        store.Stamp(writeRevision, changed);
        store.AdoptTombstones(made.Kept.Deleted);
        return true;
    }
}
