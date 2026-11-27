namespace Hermes.Core.Insights;

/// One read of the whole tree (SpawnTreeModel.readOnce): every bot's `delegation.status` at once, the chats the app
/// knows for titles, and what the page shows next. A failed refresh keeps the last tree; a gateway without the method
/// is "older"; every bot failing on the first read is a failure with the first reason.
public sealed class SpawnTreeLoader
{
    public enum Load { Loading, Ready, Failed, Older }

    public Load State { get; private set; } = Load.Loading;
    public string Reason { get; private set; } = "";
    public SpawnTree Tree { get; private set; } = new();
    public bool RefreshFailed { get; private set; }
    /// The last read failed (the next one waits the longer interval).
    public bool LastFailed { get; private set; }
    /// When the tree was read, in Unix seconds (durations are counted from it).
    public double Now { get; private set; } = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;

    public void Reset() { State = Load.Loading; RefreshFailed = false; }

    /// Folds one round of answers in. Returns true when what the page draws changed.
    public bool Apply(IReadOnlyList<string> profiles, IReadOnlyDictionary<string, (DelegationStatus? Status, Exception? Error)> answers,
        IReadOnlyDictionary<string, SpawnTree.Session> sessions, double now)
    {
        var good = profiles.Where(p => answers.TryGetValue(p, out var a) && a.Status != null)
            .Select(p => (p, answers[p].Status!)).ToList();
        if (good.Count == 0)
        {
            var error = profiles.Select(p => answers.TryGetValue(p, out var a) ? a.Error : null).FirstOrDefault(e => e != null);
            LastFailed = true;
            if (error != null && InsightsWire.IsMissingRoute(error))
            {
                State = Load.Older;
                Tree = new SpawnTree();
                return true;
            }
            if (State == Load.Ready)
            {
                var changed = !RefreshFailed;
                RefreshFailed = true;
                return changed;
            }
            State = Load.Failed;
            Reason = error != null ? InsightsWire.Reason(error) : InsightsWire.CouldntDoThat;
            return true;
        }
        LastFailed = false;
        var wasState = State;
        var wasRefresh = RefreshFailed;
        RefreshFailed = false;
        var built = SpawnTree.Build(good, sessions);
        var differs = built.Signature != Tree.Signature;
        Tree = built;
        Now = now;
        State = Load.Ready;
        return differs || wasState != Load.Ready || wasRefresh || built.Records.Any(r => r.Status == SpawnStatus.Running);
    }

    /// Reads every bot at once and folds the answers in.
    public async Task<bool> ReadAsync(HermesClient client, IReadOnlyList<string> profiles,
        IReadOnlyDictionary<string, SpawnTree.Session> sessions, CancellationToken ct)
    {
        if (profiles.Count == 0) profiles = ["default"];
        var tasks = profiles.Select(async p =>
        {
            try { return (p, (Status: (DelegationStatus?)await SpawnTreeApi.StatusAsync(client, p, ct), Error: (Exception?)null)); }
            catch (Exception e) when (e is not OperationCanceledException || !ct.IsCancellationRequested) { return (p, (Status: (DelegationStatus?)null, Error: (Exception?)e)); }
        }).ToList();
        var results = await Task.WhenAll(tasks);
        ct.ThrowIfCancellationRequested();
        var answers = results.ToDictionary(r => r.p, r => r.Item2);
        return Apply(profiles, answers, sessions, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0);
    }

    /// The chats the app knows, by session id (every slice of the sidebar).
    public static Dictionary<string, SpawnTree.Session> Sessions(Model.Sidebar sidebar)
    {
        var map = new Dictionary<string, SpawnTree.Session>();
        foreach (var row in sidebar.Recents.Rows.Concat(sidebar.Cron.Rows).Concat(sidebar.Messaging.Rows))
            map.TryAdd(row.Id, new SpawnTree.Session(row.Profile, row.Title));
        return map;
    }
}
