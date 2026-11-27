// [WIN-SCREEN-WIRE-KEYS-MATH] Who held control, remembered: the C# twin of the Mac's HermesKit/Screen/ScreenHolds.swift
// at 93f984bb1 (docs/spec/3x-screen.md §5.8, §3.3). Hermes honours a viewer id only on the /api/ws connection that
// minted it and names a lease's holder by hash, so the app keeps: this run's holds (to take the lease again with a new
// id after a reconnect) and one saved hold per bot (to offer "You were in control" after a relaunch). Also the kind of
// Screen a gateway gave (for the menu label) and the rotate hint's once-only flag.
//
// UserDefaults is Hermes.Core's IKeyValueStore (strings), under the Mac's keys: the saved hold is the same JSON text
// {"id","hash","at"}, the kind its raw value, the hint "true". The store holds ids only, never content; a viewer id can
// do nothing but release its own hold. Not ported: the Mac's DEBUG-only `HQScreenHoldAge` launch argument (stress plan
// R9) that ages a saved hold.
//
// Not thread-safe, as the Mac's @MainActor class: use it from the UI thread.

using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using Hermes.Core.Composer;

namespace Hermes.Core.Screen;

public sealed record SavedHold(string Id, string Hash, double At);

/// What leaving the Screen does with control (Swift `ScreenHolds.Leave`).
public abstract record ScreenLeave
{
    private ScreenLeave() { }

    /// Holding with the stream open: its close 1000 hands back.
    public sealed record CloseHandsBack : ScreenLeave;
    /// Release this id with force (holding with the stream down, or a hold saved by an earlier run).
    public sealed record Release(string Id) : ScreenLeave;
    public sealed record Nothing : ScreenLeave;
}

public sealed class ScreenHolds(IKeyValueStore defaults, Func<DateTimeOffset>? now = null)
{
    public static readonly TimeSpan MaxAge = TimeSpan.FromHours(24);
    public const string RotateHintKey = "hq.screen.rotateHintSeen";

    private readonly Func<DateTimeOffset> _now = now ?? (() => DateTimeOffset.UtcNow);
    private readonly Dictionary<string, ScreenViewer> _session = [];

    /// This run's newest hold per `accountId|profile`. Empty after a relaunch, so nothing is reclaimed silently.
    public IReadOnlyDictionary<string, ScreenViewer> Session => _session;

    public static string Key(string account, string profile) => $"{account}|{profile}";
    public static string HeldKey(string account, string profile) => $"hq.screen.held.{account}.{profile}";
    public static string KindKey(string account) => $"hq.screen.kind.{account}";

    // Rules (the web's shouldReclaim / heldBefore / leaveBotScreen)

    /// After a re-observe minted a new id: the lease is a person's, not the new id's, and names an id this app held.
    public static bool ShouldReclaim(ScreenViewer? prior, ScreenViewer minted, ScreenLease? lease, ScreenViewer? own)
    {
        if (lease is not { Holder: ScreenHolder.Human, ViewerHash: { } hash } || hash == minted.Hash) return false;
        return hash == prior?.Hash || hash == own?.Hash;
    }

    /// The lease still names a hold saved by an earlier run and this attach does not hold it.
    public static SavedHold? HeldBefore(SavedHold? saved, ScreenLease? lease, ScreenViewer? viewer)
    {
        if (saved == null || lease?.Holder != ScreenHolder.Human || lease.ViewerHash != saved.Hash) return null;
        return viewer?.Hash == saved.Hash ? null : saved;
    }

    public static ScreenLeave Leave(bool holding, bool streamOpen, ScreenViewer? viewer, SavedHold? saved)
    {
        if (holding && streamOpen) return new ScreenLeave.CloseHandsBack();
        if (holding && viewer != null) return new ScreenLeave.Release(viewer.Id);
        if (saved != null) return new ScreenLeave.Release(saved.Id);
        return new ScreenLeave.Nothing();
    }

    // This run

    public ScreenViewer? Own(string account, string profile) => _session.GetValueOrDefault(Key(account, profile));
    public void ClearOwn(string account, string profile) => _session.Remove(Key(account, profile));

    /// Call whenever the lease or the viewer changes.
    public void Note(ScreenLease? lease, ScreenViewer? viewer, string account, string profile)
    {
        if (lease == null) return;
        if (ScreenWire.Holds(lease, viewer) && viewer != null)
        {
            _session[Key(account, profile)] = viewer;
            if (Saved(account, profile)?.Hash != viewer.Hash) Save(viewer, account, profile);
        }
        else if (lease.Holder == ScreenHolder.Agent || (lease.ViewerHash != null && lease.ViewerHash != Saved(account, profile)?.Hash))
        {
            // Known to be someone else's (or the bot's): the saved hold is over.
            Forget(account, profile);
            if (lease.Holder == ScreenHolder.Agent) _session.Remove(Key(account, profile));
        }
    }

    // Saved

    public SavedHold? Saved(string account, string profile)
    {
        var key = HeldKey(account, profile);
        if (defaults.Get(key) is not { } text) return null;
        if (Decode(text) is not { } hold || hold.Id.Length == 0 || hold.Hash != ScreenWire.ViewerHash(hold.Id))
        {
            defaults.Set(key, null);
            return null;
        }
        var age = Seconds(_now()) - hold.At;
        if (!(age >= 0 && age < MaxAge.TotalSeconds))
        {
            defaults.Set(key, null);
            return null;
        }
        return hold;
    }

    public void Save(ScreenViewer viewer, string account, string profile)
    {
        var hold = new JsonObject { ["id"] = viewer.Id, ["hash"] = viewer.Hash, ["at"] = Seconds(_now()) };
        defaults.Set(HeldKey(account, profile), hold.ToJsonString());
    }

    public void Forget(string account, string profile) => defaults.Set(HeldKey(account, profile), null);

    // The gateway's kind and the hint

    public ScreenKind? RememberedKind(string account) =>
        ScreenKinds.FromRaw(defaults.Get(KindKey(account))) is { } kind && kind != ScreenKind.Unknown ? kind : null;

    public void RememberKind(ScreenKind kind, string account)
    {
        if (kind == ScreenKind.Unknown || RememberedKind(account) == kind) return;
        defaults.Set(KindKey(account), kind.Raw());
    }

    public bool RotateHintSeen
    {
        get => defaults.Get(RotateHintKey) == "true";
        set => defaults.Set(RotateHintKey, value ? "true" : "false");
    }

    private static double Seconds(DateTimeOffset date) => (date - DateTimeOffset.UnixEpoch).TotalSeconds;

    /// JSONDecoder for SavedHold: an object with a string id, a string hash and a number at (other keys ignored).
    private static SavedHold? Decode(string text)
    {
        JsonNode? node;
        try { node = JsonNode.Parse(text); }
        catch (JsonException) { return null; }
        if (node is not JsonObject o || ScreenJson.AsString(o["id"]) is not { } id || ScreenJson.AsString(o["hash"]) is not { } hash
            || o["at"] is not JsonValue at || at.GetValueKind() != JsonValueKind.Number) return null;
        return new SavedHold(id, hash, at.GetValue<double>());
    }
}
