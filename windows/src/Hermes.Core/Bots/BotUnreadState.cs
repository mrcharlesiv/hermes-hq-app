namespace Hermes.Core.Bots;

/// Bot unread dots (spec 02 §6.6–6.7): device-local activity baselines and unread markers, persisted per gateway
/// account. Port of HermesKit/Model/RosterUnread.swift (the activity tracker and the marker half of the runtime).
/// Read-sharing through the gateway's watermark ([read-sync]) is not ported yet.
public sealed class BotUnreadState
{
    /// Activity owner (profile name) → the newest canonical `last_active` this device has seen.
    public Dictionary<string, double> Baselines { get; set; } = [];
    /// Profile → unread canonical ids, ≤200 per profile.
    public Dictionary<string, List<string>> Markers { get; set; } = [];
    /// [botunread] (#612) Profile → the baseline passed while awaiting a BotSaid tail check to confirm the activity is for you.
    public Dictionary<string, double> Held { get; set; } = [];

    public const int MaxBaselines = 2000;
    public const int MaxMarkersPerProfile = 200;

    public bool IsMarked(RosterProfile profile) =>
        Markers.TryGetValue(profile.Name, out var bucket) && bucket.Count > 0 && profile.CanonicalIds.Any(bucket.Contains);

    /// The baseline a bot's dot is waiting on, or null when not held.
    public double? HeldSince(string profile) => Held.TryGetValue(profile, out var since) ? since : null;

    /// The row's dot: marked, and the chat is not empty (`message_count === 0` reads "untouched").
    public bool IsUnread(RosterProfile profile) => IsMarked(profile) && profile.CanonicalSession?.MessageCount != 0;

    /// One full roster: a bot whose chat is on screen is acknowledged; one whose canonical `last_active` passed its
    /// baseline (and a non-empty chat) is marked immediately (or held when `holdForCheck` is true so `BotSaidRules.NewsForYou`
    /// can suppress false unread dots after bot-to-bot tool calls, #612); first sight only records the baseline.
    public void Reconcile(IEnumerable<RosterProfile> roster, Func<RosterProfile, bool> isVisible, bool holdForCheck = false)
    {
        var list = roster.ToList();
        var next = new Dictionary<string, double>(Baselines);
        foreach (var profile in list)
        {
            if (profile.CanonicalSession is not { } canonical || profile.CanonicalIds.Count == 0
                || canonical.LastActive is not { } stamp || stamp < 0) continue;
            var had = Baselines.TryGetValue(profile.Name, out var before);
            if (isVisible(profile))
            {
                Held.Remove(profile.Name);
                AcknowledgeMarkers(profile);
            }
            else if (had && stamp > before && canonical.MessageCount != 0)
            {
                if (holdForCheck && !IsMarked(profile)) Hold(profile, before);
                else Mark(profile);
            }
            next[profile.Name] = Math.Max(had ? before : 0, stamp);
        }
        if (next.Count > MaxBaselines)
        {
            var current = list.Select(p => p.Name).ToHashSet();
            foreach (var key in next.Keys.ToList())
                if (!current.Contains(key) && next.Count > MaxBaselines) next.Remove(key);
        }
        Baselines = next;
    }

    /// Holds a moved bot's unread decision at `baseline` until its tail is checked (#612).
    public void Hold(RosterProfile profile, double baseline)
    {
        if (!Held.TryGetValue(profile.Name, out var existing) || baseline < existing)
            Held[profile.Name] = baseline;
    }

    /// Settles a held bot once its chat tail was checked: marks unread only when `forYou` is true (#612).
    public void Settle(RosterProfile profile, bool forYou)
    {
        if (!Held.Remove(profile.Name)) return;
        if (forYou && profile.CanonicalSession?.MessageCount != 0) Mark(profile);
    }

    /// Mark as Read / an open that applied fresh history: drop both ids' markers and advance the baseline.
    public void Acknowledge(RosterProfile profile)
    {
        Held.Remove(profile.Name);
        if (profile.CanonicalSession?.LastActive is { } stamp && stamp >= 0
            && stamp > (Baselines.TryGetValue(profile.Name, out var b) ? b : -1))
            Baselines[profile.Name] = stamp;
        AcknowledgeMarkers(profile);
    }

    /// The user left the bot's chat having seen it through `seenThrough` (server seconds).
    public void Left(string profile, double seenThrough, double tolerance = 2)
    {
        Held.Remove(profile);
        if (!double.IsFinite(seenThrough) || seenThrough <= 0) return;
        Baselines[profile] = Math.Max(Baselines.TryGetValue(profile, out var b) ? b : 0, seenThrough + tolerance);
    }

    /// Mark as Unread / newer activity: one durable marker on the registry id (`id || resolved_id`).
    public void Mark(RosterProfile profile)
    {
        Held.Remove(profile.Name);
        if (profile.CanonicalSession is not { } c) return;
        var id = c.Id.Length == 0 ? c.ResolvedId ?? "" : c.Id;
        if (id.Length == 0) return;
        if (!Markers.TryGetValue(profile.Name, out var bucket)) Markers[profile.Name] = bucket = [];
        if (!bucket.Contains(id)) bucket.Add(id);
        if (bucket.Count > MaxMarkersPerProfile) bucket.RemoveRange(0, bucket.Count - MaxMarkersPerProfile);
    }

    private void AcknowledgeMarkers(RosterProfile profile)
    {
        if (!Markers.TryGetValue(profile.Name, out var bucket)) return;
        var ids = profile.CanonicalIds.ToHashSet();
        bucket.RemoveAll(ids.Contains);
        if (bucket.Count == 0) Markers.Remove(profile.Name);
    }
}
