using System.Text.Json.Nodes;
using Hermes.Core.Composer;

namespace Hermes.Core.Capabilities;

public enum IssueKind { Error, NeedsAuth }

public sealed record ServerIssue(string Profile, string Name, IssueKind Kind, DateTimeOffset SeenAt, DateTimeOffset? ConfirmedAt = null)
{
    /// What the 24 h lifetime is counted from.
    public DateTimeOffset LastSeen => ConfirmedAt is { } c && c > SeenAt ? c : SeenAt;

    /// Still there on a read at `time` (moved on at most hourly).
    public ServerIssue Confirmed(DateTimeOffset time) =>
        time - LastSeen >= ServerIssues.ConfirmStep ? this with { ConfirmedAt = time } : this;
}

/// Connectors that need the owner (HermesKit/Store/ServerIssues.swift, spec 3x §8.1): a server that keeps failing or
/// needs a new sign-in. Kept 24 h per account so the Capabilities row's count survives a relaunch; a failed read never
/// creates or clears one. Thread-safe; `Changed` is raised on the caller's thread.
public sealed class ServerIssues(IKeyValueStore store, Func<DateTimeOffset>? now = null)
{
    public static readonly TimeSpan Lifetime = TimeSpan.FromHours(24);
    public static readonly TimeSpan Debounce = TimeSpan.FromSeconds(10);
    public static readonly TimeSpan ConfirmStep = TimeSpan.FromHours(1);

    private readonly Func<DateTimeOffset> _now = now ?? (() => DateTimeOffset.UtcNow);
    private readonly object _gate = new();
    private List<ServerIssue> _stored = [];
    private readonly Dictionary<string, DateTimeOffset> _firstFailure = [];
    private string _account = "";

    public event Action? Changed;

    /// Newest first, expired ones dropped.
    public IReadOnlyList<ServerIssue> Issues
    {
        get
        {
            lock (_gate)
            {
                var cutoff = _now() - Lifetime;
                return [.. _stored.Where(i => i.LastSeen > cutoff).OrderByDescending(i => i.SeenAt)];
            }
        }
    }

    public int Count => Issues.Count;

    public string? Summary
    {
        get
        {
            var live = Issues;
            if (live.Count == 0) return null;
            if (live.Count > 1) return $"{live.Count} connectors need attention";
            var title = ConnectorTitle.Title(live[0].Name);
            return live[0].Kind == IssueKind.NeedsAuth ? $"{title} needs you to sign in again" : $"{title} is unreachable";
        }
    }

    /// "1 Issue" / "2 Issues", or null with none.
    public string? RowText => Count switch { 0 => null, 1 => "1 Issue", var n => $"{n} Issues" };

    private static string Key(string account) => $"capabilities.serverIssues.{account}";

    /// Switching gateway swaps the set; "" (signed out) shows none.
    public void Use(string account)
    {
        lock (_gate)
        {
            if (account == _account) return;
            _account = account;
            _firstFailure.Clear();
        }
        var loaded = new List<ServerIssue>();
        if (account.Length > 0 && store.Get(Key(account)) is { } raw && J.Parse(raw) is JsonArray rows)
        {
            var cutoff = _now() - Lifetime;
            foreach (var r in rows)
            {
                if (r.Text("profile") is not { } p || r.Text("name") is not { } n || r.Num("seenAt") is not { } seen) continue;
                var kind = r.Str("kind") == "needs-auth" ? IssueKind.NeedsAuth : IssueKind.Error;
                var issue = new ServerIssue(p, n, kind, DateTimeOffset.FromUnixTimeMilliseconds((long)seen),
                    r.Num("confirmedAt") is { } c ? DateTimeOffset.FromUnixTimeMilliseconds((long)c) : null);
                if (issue.LastSeen > cutoff) loaded.Add(issue);
            }
        }
        Set(loaded);
    }

    /// Signing out of an account forgets its issues.
    public void SignOut(string account)
    {
        store.Set(Key(account), null);
        bool mine;
        lock (_gate) { mine = account == _account; if (mine) _firstFailure.Clear(); }
        if (mine) Set([]);
    }

    public static IssueKind? KindOf(McpServer server)
    {
        if (!server.Enabled) return null;
        if (server.Auth == "oauth" && server.OauthTokensPresent == false) return IssueKind.NeedsAuth;
        if (server.Status == "failed") return IssueKind.Error;
        return null;
    }

    /// One successful read of a bot's servers: replaces that bot's issues.
    public void Report(string profile, IEnumerable<McpServer> servers)
    {
        var time = _now();
        List<ServerIssue> next;
        lock (_gate)
        {
            var cutoff = time - Lifetime;
            next = [.. _stored.Where(i => i.LastSeen > cutoff && i.Profile != profile)];
            var old = _stored.Where(i => i.Profile == profile).GroupBy(i => i.Name).ToDictionary(g => g.Key, g => g.First());
            var failing = new HashSet<string>();
            foreach (var server in servers)
            {
                if (KindOf(server) is not { } kind) continue;
                var id = $"{profile}::{server.Name}";
                if (kind == IssueKind.Error)
                {
                    failing.Add(id);
                    if (old.TryGetValue(server.Name, out var was) && was.Kind == IssueKind.Error) { next.Add(was.Confirmed(time)); continue; }
                    if (!_firstFailure.TryGetValue(id, out var first)) { _firstFailure[id] = time; continue; }
                    // A gateway that has just restarted reports everything failed for a moment.
                    if (time - first < Debounce) continue;
                }
                if (old.TryGetValue(server.Name, out var prior) && prior.Kind == kind) next.Add(prior.Confirmed(time));
                else next.Add(new ServerIssue(profile, server.Name, kind, time));
            }
            foreach (var id in _firstFailure.Keys.Where(k => k.StartsWith(profile + "::") && !failing.Contains(k)).ToList())
                _firstFailure.Remove(id);
        }
        Set(next);
    }

    public void Clear(string profile, string name)
    {
        lock (_gate) _firstFailure.Remove($"{profile}::{name}");
        Set([.. Issues.Where(i => !(i.Profile == profile && i.Name == name))]);
    }

    /// The bot was deleted.
    public void Forget(string profile)
    {
        lock (_gate) foreach (var id in _firstFailure.Keys.Where(k => k.StartsWith(profile + "::")).ToList()) _firstFailure.Remove(id);
        Set([.. Issues.Where(i => i.Profile != profile)]);
    }

    private void Set(List<ServerIssue> next)
    {
        var sorted = next.OrderByDescending(i => i.SeenAt).ToList();
        string account;
        lock (_gate)
        {
            if (sorted.SequenceEqual(_stored)) return;
            _stored = sorted;
            account = _account;
        }
        if (account.Length > 0)
        {
            if (sorted.Count == 0) store.Set(Key(account), null);
            else
            {
                var rows = new JsonArray();
                foreach (var i in sorted)
                {
                    var o = new JsonObject
                    {
                        ["profile"] = i.Profile, ["name"] = i.Name, ["kind"] = i.Kind == IssueKind.NeedsAuth ? "needs-auth" : "error",
                        ["seenAt"] = i.SeenAt.ToUnixTimeMilliseconds(),
                    };
                    if (i.ConfirmedAt is { } c) o["confirmedAt"] = c.ToUnixTimeMilliseconds();
                    rows.Add(o);
                }
                store.Set(Key(account), rows.ToJsonString());
            }
        }
        Changed?.Invoke();
    }

    /// DECISION 8.2-a: at most 30 bots per sweep, Hermes (`default`) first.
    public const int SweepLimit = 30;

    public static List<string> SweepOrder(IEnumerable<string> profiles)
    {
        var ids = profiles.ToList();
        if (ids.Remove("default")) ids.Insert(0, "default");
        return [.. ids.Take(SweepLimit)];
    }
}
