using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Hermes.Core.Auth;
using Hermes.Core.Model;
using Hermes.Core.Net;

namespace Hermes.Core.Gateways;

/// One saved gateway as the switcher and Manage Gateways show it (HermesKit `GatewayAccountRow`, spec 1x-settings §4.2).
public sealed record GatewayRow(string Key, Uri Url, string Title, string Subtitle, string? Label, string HostAndPort,
    string AccountName, bool IsCurrent, bool HasSession, int News, bool Unreachable)
{
    /// The title menu's line under a row: "In Use", "Signed Out", "Can’t Reach" or "N New", after the address when two
    /// rows share a name (App/Gateways/GatewayTitleSwitcher.swift `gatewayItems`).
    public string MenuStatus(IReadOnlyList<GatewayRow> all)
    {
        var status = IsCurrent ? "In Use" : !HasSession ? "Signed Out" : Unreachable ? GatewayHub.CantReach
            : GatewayNews.NewsLabel(News);
        var twin = all.Any(r => r.Key != Key && r.Title == Title);
        return string.Join(" · ", new[] { twin ? HostAndPort : "", status ?? "" }.Where(s => s.Length > 0));
    }
}

/// The gateway's session ended: sign in again (prefilled) before switching to it.
public sealed class GatewayNeedsSignInException(StoredAccount account)
    : Exception("Sign in to this gateway again to switch to it.")
{
    public StoredAccount Account { get; } = account;
}

/// Any other switch failure, in the same words wherever it is said.
public static class GatewaySwitchWords
{
    public static string Reason(string name) => $"Hermes HQ couldn’t switch to {name}. Nothing changed. Try again.";
    public static string CouldNotSwitch(string name) => $"Couldn’t Switch to {name}";
    public static string Switching(string name) => $"Switching to {name}…";
    public const string Gateways = "Gateways";
    public const string AddGateway = "Add Gateway…";
    public const string ManageGateways = "Manage Gateways…";
}

/// Reads one parked chat with a parked account's own session (HermesKit `AccountProbe.session`).
public interface IParkedReader : IDisposable
{
    /// `GET /api/sessions/<id>[?profile=]`, 8 s. Throws GatewayException only when the gateway can't be reached.
    Task<ParkedAnswer> ReadAsync(string id, string? profile, CancellationToken ct);
}

public abstract record ParkedAnswer
{
    public sealed record Session(System.Text.Json.Nodes.JsonNode Json) : ParkedAnswer;
    public sealed record Refused : ParkedAnswer;
    public sealed record Missing : ParkedAnswer;
}

/// The bots each gateway's sidebar last showed, kept on this PC so a gateway not in use can still tell what's new.
public interface IParkedRosters
{
    IReadOnlyList<ParkedChat>? Read(string accountKey);
    void Write(string accountKey, IReadOnlyList<ParkedChat> chats);
    void Forget(string accountKey);
}

public sealed class FileParkedRosters(string root) : IParkedRosters
{
    private string PathFor(string key) =>
        System.IO.Path.Combine(root, "parked-" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(key)))[..24] + ".json");

    public IReadOnlyList<ParkedChat>? Read(string accountKey)
    {
        try { return JsonSerializer.Deserialize<List<ParkedChat>>(File.ReadAllText(PathFor(accountKey))); }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { return null; }
    }

    public void Write(string accountKey, IReadOnlyList<ParkedChat> chats)
    {
        try
        {
            Directory.CreateDirectory(root);
            File.WriteAllText(PathFor(accountKey), JsonSerializer.Serialize(chats));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    public void Forget(string accountKey)
    {
        try { File.Delete(PathFor(accountKey)); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }
}

public sealed class MemoryParkedRosters : IParkedRosters
{
    private readonly Dictionary<string, IReadOnlyList<ParkedChat>> _all = [];
    public IReadOnlyList<ParkedChat>? Read(string accountKey) => _all.GetValueOrDefault(accountKey);
    public void Write(string accountKey, IReadOnlyList<ParkedChat> chats) => _all[accountKey] = chats;
    public void Forget(string accountKey) => _all.Remove(accountKey);
}

/// The saved gateways: rows, rename, remove, the switch's bookkeeping, and the news check on the ones not in use
/// (App/Settings/AppModel+Settings.swift `SettingsHub`, HermesKit/Store/GatewaySwitcherModel.swift). The app swaps its
/// client; this keeps the list and the counts. Not thread-safe: call it from the UI thread.
public sealed class GatewayHub
{
    public const string CantReach = "Can’t Reach";
    public static readonly TimeSpan FirstCheck = TimeSpan.FromSeconds(4);
    public static readonly TimeSpan Every = TimeSpan.FromSeconds(180);
    public static readonly TimeSpan RecheckAfter = TimeSpan.FromSeconds(30);
    public static readonly TimeSpan UnreachableCap = TimeSpan.FromSeconds(1800);

    private readonly ITokenStore _store;
    private readonly IParkedRosters _parked;
    private readonly Dictionary<string, int> _counts = [];
    private readonly HashSet<string> _expired = [];
    private readonly HashSet<string> _unreachable = [];
    private readonly Dictionary<string, int> _misses = [];
    private readonly Dictionary<string, DateTimeOffset> _nextTry = [];
    private readonly HashSet<string> _removing = [];
    private Task? _checking;
    private CancellationTokenSource? _newsRead;
    private bool _newsStopped;

    /// Makes the reader for a parked account (tests replace it).
    public Func<StoredAccount, IParkedReader?> MakeReader { get; set; }
    public Func<DateTimeOffset> Now { get; set; } = () => DateTimeOffset.UtcNow;
    public DateTimeOffset? LastCheckEnded { get; private set; }
    /// The account in use (its own sidebar shows its news).
    public string? CurrentKey { get; set; }
    /// The row being switched to, while the switch runs.
    public string? SwitchingTo { get; private set; }
    /// Raised after rows, counts or the switch state change.
    public event Action? Changed;

    public GatewayHub(ITokenStore store, IParkedRosters parked, Func<StoredAccount, IParkedReader?>? makeReader = null)
    {
        _store = store;
        _parked = parked;
        MakeReader = makeReader ?? (a => SessionParkedReader.For(a, store));
    }

    private SavedAccounts? _cached;
    private long _cachedAt;

    /// The saved list. A read of the Credential Locker is kept for a second, so drawing the rows doesn't read it again
    /// and again; the hub's own writes and AccountsChanged() read afresh.
    public SavedAccounts Saved()
    {
        var now = Environment.TickCount64;
        if (_cached == null || now - _cachedAt > 1000)
        {
            _cached = SavedAccounts.FromJson(_store.Read());
            _cachedAt = now;
        }
        return SavedAccounts.FromJson(_cached.ToJson()); // a copy: callers change it
    }

    private void Write(SavedAccounts saved)
    {
        _store.Write(saved.ToJson());
        _cached = null;
    }

    /// Two or more saved gateways: the foot becomes a switcher and the news check runs.
    public bool IsShown => Saved().Accounts.Count > 1;

    public bool IsRemoving(string key) => _removing.Contains(key);

    public bool HasUsableSession(StoredAccount account) => account.IsSignedIn && !_expired.Contains(account.Key);

    public IReadOnlyList<GatewayRow> Rows
    {
        get
        {
            var saved = Saved();
            var current = CurrentKey ?? saved.Current;
            return [.. saved.Accounts.Select(a =>
            {
                var url = new Uri(a.Url.TrimEnd('/') + "/");
                var label = a.Label?.Trim() is { Length: > 0 } l ? l : null;
                var name = GatewayNaming.AccountName(a.Username);
                var hasSession = HasUsableSession(a);
                var (title, subtitle) = GatewayNaming.Row(url, label, name, hasSession);
                var unreachable = a.Key != current && hasSession && _unreachable.Contains(a.Key);
                if (unreachable) subtitle = string.Join(" · ", new[] { subtitle, CantReach }.Where(s => s.Length > 0));
                return new GatewayRow(a.Key, url, title, subtitle, label, GatewayNaming.Host(url, port: true), name,
                    a.Key == current, hasSession, a.Key == current ? 0 : _counts.GetValueOrDefault(a.Key), unreachable);
            })];
        }
    }

    public int OtherNews => Saved().Accounts.Where(a => a.Key != CurrentKey).Sum(a => _counts.GetValueOrDefault(a.Key));

    public string CurrentTitle => Rows.FirstOrDefault(r => r.IsCurrent)?.Title ?? "";

    // ------------------------------------------------------------------ switch

    /// Before a switch: the account to switch to (throws GatewayNeedsSignInException without a usable session). Marks
    /// the switch as running until EndSwitch.
    public StoredAccount BeginSwitch(string key)
    {
        if (SwitchingTo != null) throw new InvalidOperationException("A switch is already running.");
        var account = Saved().Find(key) ?? throw new GatewayException("account-missing", "That gateway isn't saved any more.");
        if (!HasUsableSession(account)) throw new GatewayNeedsSignInException(account);
        SwitchingTo = key;
        Changed?.Invoke();
        return account;
    }

    /// The switch landed (`switched`: it is current now) or failed (nothing changed).
    public void EndSwitch(bool switched)
    {
        var key = SwitchingTo;
        SwitchingTo = null;
        if (switched && key != null)
        {
            var saved = Saved();
            if (saved.Select(key)) Write(saved);
            CurrentKey = key;
            _counts.Remove(key);
            _expired.Remove(key);
            _unreachable.Remove(key);
            _misses.Remove(key);
            _nextTry.Remove(key);
        }
        Changed?.Invoke();
    }

    // ------------------------------------------------------------------ rename, remove

    /// The name given on this PC; null or blank goes back to the computer's name.
    public void Rename(string key, string? label)
    {
        var saved = Saved();
        var trimmed = label?.Trim() is { Length: > 0 } t ? t : null;
        if (trimmed?.Length > 60) trimmed = trimmed[..60];
        if (!saved.Update(key, a => a with { Label = trimmed }))
            throw new GatewayException("account-missing", "That gateway isn't saved any more.");
        Write(saved);
        Changed?.Invoke();
    }

    /// Removes a gateway that isn't in use: its own logout (at most 6 s), the saved entry, then this PC's copies of its
    /// data (`purge`). The one in use, or being switched to, is refused.
    public async Task RemoveAsync(string key, Action<string>? purge = null)
    {
        var account = Saved().Find(key) ?? throw new GatewayException("account-missing", "That gateway isn't saved any more.");
        if (key == CurrentKey || key == SwitchingTo || _removing.Contains(key))
            throw new GatewayException("account-current", "The gateway in use can't be removed.");
        _removing.Add(key);
        Changed?.Invoke();
        try
        {
            if (account.IsSignedIn && SessionParkedReader.Open(account, _store) is { } s)
            {
                using (s) await s.LogoutAsync(TimeSpan.FromSeconds(6));
            }
            var saved = Saved();
            saved.Remove(key);
            if (CurrentKey != null && saved.Find(CurrentKey) != null) saved.Current = CurrentKey;
            Write(saved);
            _parked.Forget(key);
            purge?.Invoke(key);
            AccountsChanged();
        }
        finally
        {
            _removing.Remove(key);
            Changed?.Invoke();
        }
    }

    /// The saved accounts changed outside the hub (a sign-in, a sign-out): counts for removed accounts go.
    public void AccountsChanged()
    {
        _cached = null;
        var keys = Saved().Accounts.Select(a => a.Key).ToHashSet();
        foreach (var k in _counts.Keys.Where(k => !keys.Contains(k)).ToList()) _counts.Remove(k);
        _expired.RemoveWhere(k => !keys.Contains(k));
        _unreachable.RemoveWhere(k => !keys.Contains(k));
        foreach (var k in _misses.Keys.Where(k => !keys.Contains(k)).ToList()) { _misses.Remove(k); _nextTry.Remove(k); }
        Changed?.Invoke();
    }

    // ------------------------------------------------------------------ news

    /// The gateway in use showed these bots: what a later news check compares against.
    public void Park(string accountKey, IEnumerable<Bot> roster) => _parked.Write(accountKey, GatewayNews.Parked(roster));

    /// How long a gateway that missed `misses` checks in a row waits before the next one: 6, 12, 24, then 30 minutes.
    public static TimeSpan Backoff(int misses) =>
        TimeSpan.FromSeconds(Math.Min(UnreachableCap.TotalSeconds, Every.TotalSeconds * Math.Pow(2, Math.Max(1, misses))));

    /// On return to the app and when the menu opens: a check unless the last one ended under 30 s ago. The menu
    /// (`force`) also asks the gateways waiting out a backoff.
    public void CheckSoon(bool force = true)
    {
        if (_newsStopped || !IsShown) return;
        if (LastCheckEnded is { } ended && Now() - ended <= RecheckAfter) return;
        _ = CheckAsync(force);
    }

    /// One gateway at a time, one check at a time. A gateway that can't be reached keeps its last count; one whose
    /// session was refused (or that has none) shows none.
    public Task CheckAsync(bool force = true)
    {
        if (_newsStopped) return Task.CompletedTask;
        if (_checking is { IsCompleted: false } running) return running;
        _checking = PerformCheckAsync(force);
        return _checking;
    }

    /// GatewaySwitcherModel.stop: cancel the current read, then let its reader dispose. The quit plan bounds
    /// this wait; even a late reply to an uncooperative read may neither notify the UI nor start another read.
    public async Task StopNewsForQuitAsync()
    {
        _newsStopped = true;
        var pending = _checking is { IsCompleted: false } task ? task : null;
        try { _newsRead?.Cancel(); }
        finally { if (pending != null) await pending; }
    }

    private async Task PerformCheckAsync(bool force)
    {
        foreach (var account in Saved().Accounts.Where(a => a.Key != CurrentKey).ToList())
        {
            if (_newsStopped) return;
            var key = account.Key;
            if (!force && _nextTry.TryGetValue(key, out var next) && Now() < next) continue;
            int? count = null;
            if (!account.IsSignedIn)
            {
                count = 0;
                SetUnreachable(key, false);
            }
            else if (_parked.Read(key) is not { Count: > 0 } chats)
            {
                count = 0;
                SetUnreachable(key, false);
            }
            else
            {
                var live = new List<ParkedChatLive>();
                bool refused = false, unreachable = false;
                using (var reader = MakeReader(account))
                {
                    if (reader == null) unreachable = true;
                    else foreach (var chat in chats)
                    {
                        if (_newsStopped) return;
                        if (!GatewayNews.SessionIdPattern().IsMatch(chat.Id)) continue;
                        using var t = new CancellationTokenSource(TimeSpan.FromSeconds(8));
                        _newsRead = t;
                        try
                        {
                            var answer = await reader.ReadAsync(chat.Id, chat.Profile, t.Token);
                            if (_newsStopped) return;
                            switch (answer)
                            {
                                case ParkedAnswer.Session s:
                                    if (ParkedChatLive.From(s.Json, chat.Id) is { } row) live.Add(row);
                                    break;
                                case ParkedAnswer.Refused: refused = true; break;
                            }
                        }
                        catch (Exception e) when (e is GatewayException or OperationCanceledException or HttpRequestException)
                        {
                            if (_newsStopped) return;
                            unreachable = true;
                        }
                        finally { _newsRead = null; }
                        if (refused || unreachable) break;
                    }
                }
                if (unreachable)
                {
                    var missed = _misses.GetValueOrDefault(key) + 1;
                    _misses[key] = missed;
                    _nextTry[key] = Now() + Backoff(missed);
                }
                else
                {
                    _misses.Remove(key);
                    _nextTry.Remove(key);
                }
                SetUnreachable(key, unreachable);
                if (refused)
                {
                    count = 0;
                    if (_expired.Add(key)) Changed?.Invoke();
                }
                else if (!unreachable)
                {
                    count = GatewayNews.UnreadCount(chats, live);
                    if (_expired.Remove(key)) Changed?.Invoke();
                }
            }
            if (_newsStopped) return;
            if (count is not { } c || Saved().Find(key) == null) continue;
            if (_counts.GetValueOrDefault(key, -1) != c)
            {
                _counts[key] = c;
                Changed?.Invoke();
            }
        }
        if (_newsStopped) return;
        LastCheckEnded = Now();
        Changed?.Invoke();
    }

    private void SetUnreachable(string key, bool on)
    {
        if (on ? _unreachable.Add(key) : _unreachable.Remove(key)) Changed?.Invoke();
    }
}

/// The news check's reader over a parked account's own session (a GatewaySession, no socket).
public sealed class SessionParkedReader(GatewaySession session) : IParkedReader
{
    public static GatewaySession? Open(StoredAccount account, ITokenStore store)
    {
        if (!account.IsSignedIn) return null;
        try { return new GatewaySession(GatewayAddress.Validated(account.Url), account, store); }
        catch (GatewayException) { return null; }
    }

    public static IParkedReader? For(StoredAccount account, ITokenStore store) =>
        Open(account, store) is { } s ? new SessionParkedReader(s) : null;

    public async Task<ParkedAnswer> ReadAsync(string id, string? profile, CancellationToken ct)
    {
        var query = profile is { } p && p != "default" ? new[] { new KeyValuePair<string, string>("profile", p) } : null;
        var a = await session.SendAsync(HttpMethod.Get, "/api/sessions/" + id, query, timeout: TimeSpan.FromSeconds(8), ct: ct);
        if (a.Ok) return a.Json is { } j ? new ParkedAnswer.Session(j) : new ParkedAnswer.Missing();
        if (a.Status is 401 or 403) return new ParkedAnswer.Refused();
        return new ParkedAnswer.Missing();
    }

    public void Dispose() => session.Dispose();
}
