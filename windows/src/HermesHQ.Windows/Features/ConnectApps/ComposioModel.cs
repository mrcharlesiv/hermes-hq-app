using System.Text.Json;
using System.Text.Json.Nodes;
using Hermes.Core;
using Hermes.Core.Capabilities;
using Hermes.Core.Composio;
using Hermes.Core.Composer;
using Hermes.Core.Gateways;
using Hermes.Core.Model;
using Hermes.Core.Net;
using HermesHQ.Features.Capabilities;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Dispatching;
using Windows.System;

namespace HermesHQ.Features.ConnectApps;

// Port of App/ConnectApps/ComposioModel.swift (docs/spec/3x-capabilities.md §10):
// Observable state for Composio API key setup / gateway reveal, Home (Connected + Popular + Categories + Search),
// multi-account Connect Link OAuth (system browser + account polling), rename/disconnect, Try It chat prefill,
// Bots assignment, and All Bots background reconciliation.

public enum ComposioPhase { Loading, Setup, Ready, Failed }

public enum ComposioConnectPhase { Idle, Preparing, Link, SignIn, Checking }

public sealed record ComposioNotice(string Title, string Message, bool IsError);

public abstract record ComposioBotState
{
    public sealed record On : ComposioBotState;
    public sealed record Off : ComposioBotState;
    public sealed record Failed(bool IntendedOn, string Reason) : ComposioBotState;
}

public abstract record ComposioConnectOutcome
{
    public sealed record Connected : ComposioConnectOutcome;
    public sealed record Failed(string Reason) : ComposioConnectOutcome;
    public sealed record Unfinished : ComposioConnectOutcome;
    public sealed record NeedsOwnApp : ComposioConnectOutcome;
}

internal static class ComposioBotsGate
{
    public static volatile bool Applying;
}

/// Persists non-secret Connect Apps metadata (session ids, multi-account ids, identities, verified bots, catalog cache).
/// Never stores API keys.
internal static class ComposioLocalCache
{
    public static JsonFileStore Store { get; } = new(Path.Combine(AppPaths.Root, "composio-cache.json"));

    public static HashSet<string> ReadStringSet(string key)
    {
        var raw = Store.Get(key);
        if (string.IsNullOrEmpty(raw)) return [];
        if (J.Parse(raw) is not JsonArray arr) return [];
        return arr.Select(J.AsString).OfType<string>().ToHashSet(StringComparer.Ordinal);
    }

    public static void WriteStringSet(string key, IEnumerable<string> values)
    {
        var sorted = values.Distinct(StringComparer.Ordinal).OrderBy(s => s, StringComparer.Ordinal).ToList();
        if (sorted.Count == 0) { Store.Set(key, null); return; }
        var arr = new JsonArray();
        foreach (var v in sorted) arr.Add(v);
        Store.Set(key, arr.ToJsonString());
    }

    public static string VerifiedKey(string accountId) => $"connectapps.verified.{accountId}";

    public static HashSet<string> PrunedVerified(HashSet<string> verified, IReadOnlyList<string> roster) =>
        roster.Count == 0 ? verified : verified.Intersect(roster, StringComparer.Ordinal).ToHashSet(StringComparer.Ordinal);

    public static void SettleBot(string profile, string accountId)
    {
        var cur = ReadStringSet(VerifiedKey(accountId));
        cur.Add(profile);
        WriteStringSet(VerifiedKey(accountId), cur);
    }
}

/// Observable Connect Apps model bound by `ConnectAppsPage`.
internal sealed class ComposioModel : IDisposable
{
    private const string CatalogCacheKey = "connectapps.needs-own-app";
    private static readonly TimeSpan ConnectPollTimeout = TimeSpan.FromSeconds(120);

    private readonly Microsoft.UI.Dispatching.DispatcherQueue _ui = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
    private readonly IComposioKeyStore _keys;
    private readonly ComposioClient _client;
    private readonly string _accountId;

    private List<ComposioToolkit>? _allResults;
    private DateTimeOffset? _signInRulesRead;
    private int _searchGeneration;
    private readonly HashSet<string> _identityAsked = new(StringComparer.Ordinal);
    private bool _identitiesRead;
    private CancellationTokenSource? _connectCts;
    private bool _connectRunning;
    private bool _disposed;

    public event Action? Changed;

    public ComposioPhase Phase { get; private set; } = ComposioPhase.Loading;
    public string FailedReason { get; private set; } = "";
    public ComposioSession? Session { get; private set; }
    public ComposioRecord? Record { get; private set; }
    public ComposioNotice? SetupNotice { get; set; }
    public bool SettingUp { get; private set; }
    public string? GatewayKeyProfile { get; private set; }

    // Home
    public List<ComposioToolkit>? Connected { get; private set; }
    public string? ConnectedError { get; private set; }
    public List<ComposioToolkit>? Popular { get; private set; }
    public string Query { get; private set; } = "";
    public List<ComposioToolkit>? Results => Shown(_allResults);
    public string? SearchError { get; private set; }
    public HashSet<string> NeedsOwnApp { get; private set; } = new(StringComparer.Ordinal);
    public HashSet<string> OwnAuthConfigs { get; private set; } = new(StringComparer.Ordinal);

    // Multi-account & identity (§10.11, §10.12)
    public Dictionary<string, List<ComposioAccount>> AppAccounts { get; } = new(StringComparer.Ordinal);
    public Dictionary<string, ComposioIdentity> Identities { get; } = new(StringComparer.Ordinal);

    // Bots (§10.7)
    public Dictionary<string, ComposioBotState>? BotStates { get; private set; }
    public HashSet<string> BotBusy { get; } = new(StringComparer.Ordinal);
    public bool ApplyingAll { get; private set; }
    public ComposioNotice? BotsNotice { get; private set; }

    // Connect flow (§10.8)
    public ComposioConnectPhase ConnectPhase { get; private set; } = ComposioConnectPhase.Idle;
    public ComposioConnectOutcome? ConnectOutcome { get; private set; }
    public string? ConnectLabel => ConnectPhase switch
    {
        ComposioConnectPhase.Preparing => "Getting ready…",
        ComposioConnectPhase.Link => "Opening…",
        ComposioConnectPhase.SignIn => "Signing in…",
        ComposioConnectPhase.Checking => "Checking…",
        _ => null,
    };

    public ComposioModel(IComposioKeyStore? keys = null)
    {
        _accountId = AppState.Client?.AccountId ?? "default";
        _keys = keys ?? ConnectAppsFeature.KeyStore;
        _client = new ComposioClient(_keys, _accountId);
    }

    public IComposioKeyStore Keys => _keys;
    public ComposioClient Client => _client;
    public string AccountId => _accountId;
    public ComposioGateway? Gateway => CapabilitiesServices.Api is { } api ? new ComposioGateway(api) : null;
    public bool ReadOnly => CapabilitiesServices.Api?.ReadOnly ?? true;
    public List<Bot> Bots => CapabilitiesServices.Bots();
    public bool AllBots => Record?.AllBots ?? false;
    public List<Bot> OnBots => Bots.Where(b => BotStates?.GetValueOrDefault(b.Name) is ComposioBotState.On).ToList();

    public string UserId =>
        Record?.UserId
        ?? (!string.IsNullOrEmpty(Session?.UserId) ? Session!.UserId : CachedSession()?.UserId)
        ?? "";

    public (string Title, string Subtitle, bool Choose) BotsRowWords
    {
        get
        {
            if (BotStates == null) return ("Checking bots…", "", false);
            var total = Bots.Count;
            var on = OnBots;
            var totalWord = total == 1 ? "1 bot" : $"{total} bots";
            if (AllBots) return ("Used by all bots", $"{totalWord}, including new ones", false);
            if (on.Count == 0) return ("No bots use your apps yet", "Choose Bots", true);
            return ($"Used by {ComposioCatalog.NameList([.. on.Select(b => b.DisplayName)])}", $"{on.Count} of {totalWord}", false);
        }
    }

    public List<ComposioToolkit> PopularShown
    {
        get
        {
            var taken = (Connected ?? []).Select(c => c.Slug).ToHashSet(StringComparer.Ordinal);
            return [.. (Shown(Popular) ?? []).Where(t => !taken.Contains(t.Slug)).Take(ComposioCatalog.PopularShown)];
        }
    }

    public List<ComposioToolkit>? Shown(List<ComposioToolkit>? items) =>
        items?.Where(t => !ComposioSignIn.Hidden(t, NeedsOwnApp, OwnAuthConfigs)).ToList();

    public void Notify()
    {
        if (_disposed || AppShutdown.Stopping) return;
        if (_ui.HasThreadAccess) Changed?.Invoke();
        else _ui.TryEnqueue(() => { if (!_disposed && !AppShutdown.Stopping) Changed?.Invoke(); });
    }

    // ------------------------------------------------------------------ Local non-secret cache

    private string SessionCacheKey => $"connectapps.session.{_accountId}";
    private string MultiKey => $"connectapps.multi.{_accountId}";
    private string MovingKey => $"connectapps.moving.{_accountId}";
    private string IdentityKey => $"connectapps.identities.{_accountId}";

    private (string UserId, string SessionId)? CachedSession()
    {
        var raw = ComposioLocalCache.Store.Get(SessionCacheKey);
        if (string.IsNullOrEmpty(raw) || J.Parse(raw) is not JsonObject obj) return null;
        var user = obj.Text("userId");
        var session = obj.Text("sessionId");
        return user != null && session != null ? (user, session) : null;
    }

    private void CacheSession(ComposioSession session, string userId) =>
        ComposioLocalCache.Store.Set(SessionCacheKey, new JsonObject { ["userId"] = userId, ["sessionId"] = session.Id }.ToJsonString());

    private HashSet<string> KnownMultiAccount => ComposioLocalCache.ReadStringSet(MultiKey);

    private void NoteMultiAccount(ComposioSession made)
    {
        if (made.MultiAccount == false) return;
        var known = KnownMultiAccount;
        if (!known.Add(made.Id)) return;
        ComposioLocalCache.WriteStringSet(MultiKey, known.OrderBy(x => x, StringComparer.Ordinal).TakeLast(8));
    }

    // ------------------------------------------------------------------ Opening & Setup (§10.4)

    public async Task StartAsync()
    {
        Phase = ComposioPhase.Loading;
        FailedReason = "";
        Notify();

        if (!_keys.Status(_accountId).Saved)
        {
            Phase = ComposioPhase.Setup;
            Notify();
            await FindGatewayKeyAsync();
            Notify();
            return;
        }

        try
        {
            var cached = CachedSession();
            ComposioRecord? record = null;
            try { record = Gateway != null ? await Gateway.RecordAsync() : null; }
            catch (Exception) { }
            Record = record;

            var user = record?.UserId ?? cached?.UserId ?? ComposioRecord.NewUserId();
            var known = !string.IsNullOrEmpty(record?.SessionId) ? record!.SessionId : cached?.SessionId;
            Session = await SessionForAsync(user, known);
            CacheSession(Session, user);
            Phase = ComposioPhase.Ready;
            Notify();

            await Task.WhenAll(LoadHomeAsync(), LoadBotsAsync());
        }
        catch (ComposioException ex)
        {
            if (ex.Kind is ComposioErrorKind.BadKey or ComposioErrorKind.NoKey)
            {
                Phase = ComposioPhase.Setup;
                SetupNotice = new ComposioNotice(
                    "Key Not Accepted",
                    $"Composio didn’t accept the key saved on this {DeviceWord.Name}. Paste a new one below.",
                    IsError: true);
            }
            else if (ex.Kind == ComposioErrorKind.Network)
            {
                Phase = ComposioPhase.Failed;
                FailedReason = $"{ex.Message}. Check your connection, then try again.";
            }
            else
            {
                Phase = ComposioPhase.Failed;
                FailedReason = ex.Message;
            }
            AppLog.Note("connect", $"composio start failed: {ex.Kind}");
            Notify();
        }
    }

    private async Task<ComposioSession> SessionForAsync(string userId, string? known)
    {
        if (!string.IsNullOrEmpty(known))
        {
            try { return await _client.ReadSessionAsync(known); }
            catch (ComposioException ex) when (ex.Kind == ComposioErrorKind.NotFound) { }
        }
        var made = await _client.CreateSessionAsync(userId);
        NoteMultiAccount(made);
        return made;
    }

    private async Task FindGatewayKeyAsync()
    {
        GatewayKeyProfile = null;
        if (Gateway is not { } gateway) return;
        foreach (var bot in Bots.Take(12))
        {
            try
            {
                var server = await gateway.ServerAsync(bot.Name);
                if (server != null && (server.Url != null || server.Transport == "http"))
                {
                    GatewayKeyProfile = bot.Name;
                    return;
                }
            }
            catch (Exception) { }
        }
    }

    /// Validates and saves either a pasted key or (when `typed == null`) the key revealed from the gateway.
    public async Task SetUpAsync(string? typed)
    {
        if (SettingUp) return;
        SettingUp = true;
        SetupNotice = null;
        Notify();

        try
        {
            var key = typed?.Trim() ?? "";
            if (typed == null)
            {
                try
                {
                    var profile = GatewayKeyProfile;
                    var revealed = !string.IsNullOrEmpty(profile) && Gateway != null
                        ? await Gateway.RevealKeyAsync(profile)
                        : null;
                    if (string.IsNullOrWhiteSpace(revealed))
                    {
                        SetupNotice = new ComposioNotice("Couldn’t Set Up Composio",
                            "No bot on your gateway holds a Composio key now. Paste yours instead.", IsError: true);
                        return;
                    }
                    key = revealed.Trim();
                }
                catch (GatewayException ex) when (ex.Status == 429)
                {
                    SetupNotice = new ComposioNotice("Couldn’t Set Up Composio",
                        "Your gateway is busy. Wait half a minute, then try again.", IsError: true);
                    return;
                }
                catch (Exception ex)
                {
                    SetupNotice = new ComposioNotice("Couldn’t Set Up Composio", CapabilitiesWords.Detail(ex), IsError: true);
                    return;
                }
            }

            if (!ComposioKeyRules.Plausible(key))
            {
                SetupNotice = new ComposioNotice("Key Not Accepted", "That doesn’t look like a Composio key.", IsError: true);
                return;
            }

            try
            {
                ComposioRecord? record = null;
                try { record = Gateway != null ? await Gateway.RecordAsync() : null; }
                catch (Exception) { }
                Record = record;

                var cached = CachedSession();
                var user = record?.UserId ?? cached?.UserId ?? ComposioRecord.NewUserId();
                var known = !string.IsNullOrEmpty(record?.SessionId) ? record!.SessionId : cached?.SessionId;
                var made = await _client.CheckAsync(key, user, known);
                if (made.Id != known) NoteMultiAccount(made);
                _keys.SaveKey(_accountId, key);
                ComposioReconciler.Shared.KeySaved();
                Session = made;
                CacheSession(made, user);
                Phase = ComposioPhase.Ready;
                Notify();
                await Task.WhenAll(LoadHomeAsync(), LoadBotsAsync());
            }
            catch (ComposioException ex)
            {
                SetupNotice = new ComposioNotice(
                    ex.Kind == ComposioErrorKind.BadKey ? "Key Not Accepted" : "Couldn’t Set Up Composio",
                    ex.Message, IsError: true);
                AppLog.Note("connect", $"composio setup failed: {ex.Kind}");
            }
        }
        finally
        {
            SettingUp = false;
            Notify();
        }
    }

    // ------------------------------------------------------------------ Home & Search (§10.5)

    public async Task LoadSignInRulesAsync()
    {
        if (_signInRulesRead is { } read && DateTimeOffset.UtcNow - read < TimeSpan.FromMinutes(10)) return;
        _signInRulesRead = DateTimeOffset.UtcNow;

        var configsTask = Task.Run<HashSet<string>?>(async () =>
        {
            try { return await _client.AppsWithOwnAuthConfigAsync().ConfigureAwait(false); }
            catch (Exception) { return null; }
        });

        HashSet<string>? catalog = null;
        if (ComposioLocalCache.Store.Get(CatalogCacheKey) is { } raw && J.Parse(raw) is JsonObject saved
            && saved.Num("at") is { } atMs
            && DateTimeOffset.UtcNow - DateTimeOffset.FromUnixTimeMilliseconds((long)atMs) < TimeSpan.FromHours(24)
            && saved.Arr("slugs") is { } slugsArr)
        {
            catalog = slugsArr.Select(J.AsString).OfType<string>().ToHashSet(StringComparer.Ordinal);
        }
        else
        {
            try
            {
                var fresh = await _client.AppsNeedingOwnSignInAsync();
                var arr = new JsonArray();
                foreach (var s in fresh.OrderBy(x => x, StringComparer.Ordinal)) arr.Add(s);
                ComposioLocalCache.Store.Set(CatalogCacheKey, new JsonObject
                {
                    ["at"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
                    ["slugs"] = arr,
                }.ToJsonString());
                catalog = fresh;
            }
            catch (Exception) { }
        }

        var own = await configsTask;
        if (catalog != null && own != null)
        {
            NeedsOwnApp = catalog;
            OwnAuthConfigs = own;
            Notify();
        }
        else
        {
            _signInRulesRead = null;
        }
    }

    public async Task LoadHomeAsync()
    {
        if (Session is not { } session) return;
        _ = LoadSignInRulesAsync();
        ConnectedError = null;
        try
        {
            var all = new List<ComposioToolkit>();
            var seen = new HashSet<string>(StringComparer.Ordinal);
            var cursor = "";
            for (var i = 0; i < 10; i++)
            {
                var page = await _client.ToolkitsAsync(session.Id, cursor: cursor, limit: 50, connectedOnly: true);
                foreach (var item in page.Items)
                {
                    if (item.Connected && seen.Add(item.Slug)) all.Add(item);
                }
                cursor = page.Next;
                if (cursor.Length == 0) break;
            }
            all.Sort((a, b) => StringComparer.CurrentCultureIgnoreCase.Compare(a.Name, b.Name));
            Connected = all;
        }
        catch (ComposioException ex)
        {
            ConnectedError = ex.Message;
            Connected ??= [];
        }
        Notify();

        try
        {
            var page = await _client.ToolkitsAsync(session.Id, slugs: ComposioCatalog.Popular, limit: 30);
            var order = ComposioCatalog.Popular.Select((slug, idx) => (slug, idx))
                .ToDictionary(x => x.slug, x => x.idx, StringComparer.Ordinal);
            Popular = [.. page.Items.OrderBy(t => order.GetValueOrDefault(t.Slug, 99))];
        }
        catch (Exception)
        {
            Popular ??= [];
        }
        Notify();
    }

    public void SetQuery(string query)
    {
        if (Query == query) return;
        Query = query;
        _searchGeneration++;
        var gen = _searchGeneration;
        var q = query.Trim();
        SearchError = null;
        if (q.Length == 0 || Session is not { } session)
        {
            _allResults = null;
            Notify();
            return;
        }
        _allResults = null;
        Notify();
        _ = RunSearchAsync(q, session.Id, gen);
    }

    private async Task RunSearchAsync(string q, string sessionId, int gen)
    {
        await Task.Delay(300);
        if (gen != _searchGeneration || _disposed) return;
        try
        {
            var page = await _client.ToolkitsAsync(sessionId, search: q, limit: 30);
            if (gen != _searchGeneration || _disposed) return;
            _allResults = [.. page.Items];
        }
        catch (ComposioException ex)
        {
            if (gen != _searchGeneration || _disposed) return;
            SearchError = ex.Message;
            _allResults = [];
        }
        Notify();
    }

    // ------------------------------------------------------------------ Bots (§10.7)

    public async Task LoadBotsAsync()
    {
        if (Gateway is not { } gateway)
        {
            BotStates = [];
            Notify();
            return;
        }
        try { if (await gateway.RecordAsync() is { } fresh) Record = fresh; }
        catch (Exception) { }

        var states = BotStates != null
            ? new Dictionary<string, ComposioBotState>(BotStates, StringComparer.Ordinal)
            : new Dictionary<string, ComposioBotState>(StringComparer.Ordinal);

        var ids = Bots.Select(b => b.Name).ToList();
        for (var i = 0; i < ids.Count; i += 3)
        {
            var slice = ids.Skip(i).Take(3).ToList();
            var tasks = slice.Select(async id =>
            {
                try { return (id, (bool?)(await gateway.ServerAsync(id) != null)); }
                catch (Exception) { return (id, (bool?)null); }
            }).ToList();
            foreach (var (id, on) in await Task.WhenAll(tasks))
            {
                if (on is not { } isOn) continue;
                if (!isOn && states.TryGetValue(id, out var prev) && prev is ComposioBotState.Failed) continue;
                states[id] = isOn ? new ComposioBotState.On() : new ComposioBotState.Off();
            }
        }
        BotStates = states;
        Notify();
    }

    public async Task SetBotAsync(Bot bot, bool on)
    {
        if (BotBusy.Contains(bot.Name) || ReadOnly) return;
        BotBusy.Add(bot.Name);
        Notify();
        try { await ApplyBotAsync(bot.Name, on); }
        finally
        {
            BotBusy.Remove(bot.Name);
            Notify();
        }
    }

    private async Task ApplyBotAsync(string profile, bool on)
    {
        if (Gateway is not { } gateway || Session is not { } session) return;
        BotStates ??= new Dictionary<string, ComposioBotState>(StringComparer.Ordinal);
        try
        {
            if (on)
            {
                var key = _keys.ReadKey(_accountId) ?? throw ComposioException.NoKey;
                await gateway.TurnOnAsync(profile, key, session.McpUrl);
                if (Record == null)
                {
                    var fresh = new ComposioRecord(
                        !string.IsNullOrEmpty(session.UserId) ? session.UserId : (CachedSession()?.UserId ?? ComposioRecord.NewUserId()),
                        session.Id,
                        AllBots: false);
                    await gateway.WriteAsync(fresh);
                    Record = fresh;
                }
            }
            else
            {
                await gateway.TurnOffAsync(profile);
                ComposioLocalCache.SettleBot(profile, _accountId);
            }
            BotStates[profile] = on ? new ComposioBotState.On() : new ComposioBotState.Off();
        }
        catch (Exception ex)
        {
            var reason = ex is ComposioException ce ? ce.Message
                : ex is CapabilityException cap ? cap.Reason
                : McpEntryMask.Phone.Text(CapabilitiesWords.Detail(ex));
            BotStates[profile] = new ComposioBotState.Failed(on, reason);
        }
        Notify();
    }

    public async Task SetAllBotsAsync(bool on)
    {
        if (Gateway is not { } gateway || Session is not { } session || ApplyingAll || ReadOnly) return;
        ApplyingAll = true;
        ComposioBotsGate.Applying = true;
        BotsNotice = null;
        Notify();

        try
        {
            var next = (Record ?? new ComposioRecord(
                !string.IsNullOrEmpty(session.UserId) ? session.UserId : (CachedSession()?.UserId ?? ComposioRecord.NewUserId()),
                session.Id,
                AllBots: false)) with { AllBots = on, SessionId = session.Id };

            try
            {
                await gateway.WriteAsync(next);
            }
            catch (Exception ex)
            {
                BotsNotice = new ComposioNotice("Couldn’t Change All Bots", CapabilitiesWords.Detail(ex), IsError: true);
                return;
            }
            Record = next;
            Notify();
            if (!on) return;

            var pending = Bots.Select(b => b.Name).Where(id => BotStates?.GetValueOrDefault(id) is not ComposioBotState.On).ToList();
            for (var i = 0; i < pending.Count; i += 3)
            {
                var slice = pending.Skip(i).Take(3).ToList();
                foreach (var id in slice) BotBusy.Add(id);
                Notify();
                await Task.WhenAll(slice.Select(id => ApplyBotAsync(id, on: true)));
                foreach (var id in slice) BotBusy.Remove(id);
                Notify();
            }

            var failed = pending.Count(id => BotStates?.GetValueOrDefault(id) is ComposioBotState.Failed);
            if (failed > 0)
            {
                BotsNotice = new ComposioNotice(
                    failed == 1 ? "1 Bot Not Updated Yet" : $"{failed} Bots Not Updated Yet",
                    "Hermes HQ tries them again the next time it opens. Each one says why below.",
                    IsError: false);
            }
        }
        finally
        {
            ApplyingAll = false;
            ComposioBotsGate.Applying = false;
            Notify();
        }
    }

    // ------------------------------------------------------------------ Multi-account & Identity (§10.11, §10.12)

    public void ReadIdentities()
    {
        if (_identitiesRead) return;
        _identitiesRead = true;
        var raw = ComposioLocalCache.Store.Get(IdentityKey);
        if (string.IsNullOrEmpty(raw)) return;
        try
        {
            var saved = JsonSerializer.Deserialize<Dictionary<string, ComposioIdentity>>(raw);
            if (saved == null) return;
            foreach (var (k, v) in saved) Identities.TryAdd(k, v);
        }
        catch (JsonException) { }
    }

    private void SaveIdentities()
    {
        try { ComposioLocalCache.Store.Set(IdentityKey, JsonSerializer.Serialize(Identities)); }
        catch (Exception) { }
    }

    public async Task<List<ComposioAccount>> LoadAccountsAsync(string slug)
    {
        ReadIdentities();
        if (string.IsNullOrEmpty(UserId)) throw ComposioException.Problem;
        var list = await _client.AccountsAsync(UserId, slug);
        SetAccounts(slug, list);
        _ = LoadIdentitiesAsync(slug, list);
        return list;
    }

    public void SetAccounts(string slug, List<ComposioAccount>? list)
    {
        ReadIdentities();
        if (list != null)
        {
            var ids = list.Select(a => a.Id).ToHashSet(StringComparer.Ordinal);
            var gone = (AppAccounts.GetValueOrDefault(slug) ?? []).Select(a => a.Id)
                .Where(id => !ids.Contains(id) && Identities.ContainsKey(id)).ToList();
            foreach (var id in gone) Identities.Remove(id);
            if (gone.Count > 0) SaveIdentities();
            AppAccounts[slug] = list;
        }
        else
        {
            AppAccounts.Remove(slug);
        }
        Notify();
    }

    public async Task LoadIdentitiesAsync(string slug, IReadOnlyList<ComposioAccount> accounts, bool again = false)
    {
        ReadIdentities();
        if (ComposioWhoAmI.ForToolkit(slug) == null || string.IsNullOrEmpty(UserId)) return;
        var ask = accounts.Where(a => a.IsActive && (again || !_identityAsked.Contains(a.Id))).ToList();
        if (ask.Count == 0) return;
        foreach (var a in ask) _identityAsked.Add(a.Id);

        var user = UserId;
        var tasks = ask.Select(async a =>
        {
            try { return (a.Id, Identity: await _client.IdentityAsync(a.Id, slug, user), Failed: false); }
            catch (ComposioException) { return (a.Id, Identity: (ComposioIdentity?)null, Failed: true); }
        }).ToList();

        var found = 0;
        foreach (var (id, identity, failed) in await Task.WhenAll(tasks))
        {
            if (identity != null) { Identities[id] = identity; found++; }
            else if (failed) _identityAsked.Remove(id);
        }
        if (found > 0) { SaveIdentities(); Notify(); }
    }

    public static List<string> BotsToMove(IEnumerable<(string Profile, string? Url)> servers, string targetSessionId) =>
        servers.Where(s => ComposioSession.IdFromMcpUrl(s.Url) != targetSessionId).Select(s => s.Profile).ToList();

    /// Upgrades a legacy single-account session to multi-account, migrating all bots with Composio before updating the record.
    public async Task<ComposioSession> MultiAccountSessionAsync()
    {
        if (Session is not { } current) throw ComposioException.Problem;
        if (ComposioSession.IsMultiAccount(current, KnownMultiAccount)) return current;

        ComposioBotsGate.Applying = true;
        try
        {
            var gateway = Gateway;
            ComposioRecord? record = null;
            if (gateway != null)
            {
                record = await gateway.RecordAsync();
                if (record != null) Record = record;
            }
            var user = record?.UserId ?? (!string.IsNullOrEmpty(current.UserId) ? current.UserId : CachedSession()?.UserId ?? "");
            if (string.IsNullOrEmpty(user)) throw ComposioException.Problem;
            if (record != null && ReadOnly)
                throw new ComposioException(ComposioErrorKind.Rejected, "This gateway is read-only. Add another account from a gateway you can change.");

            ComposioSession? next = null;
            if (ComposioLocalCache.Store.Get(MovingKey) is { } movingRaw && J.Parse(movingRaw) is JsonObject kept
                && kept.Text("userId") == user && kept.Text("sessionId") is { } keptId)
            {
                try
                {
                    var found = await _client.ReadSessionAsync(keptId);
                    if (ComposioSession.IsMultiAccount(found, KnownMultiAccount)) next = found;
                }
                catch (Exception) { }
            }

            if (next == null)
            {
                var made = await _client.CreateSessionAsync(user);
                NoteMultiAccount(made);
                if (!ComposioSession.IsMultiAccount(made, KnownMultiAccount))
                    throw new ComposioException(ComposioErrorKind.Rejected, "Composio didn’t allow more than one account per app.");
                ComposioLocalCache.Store.Set(MovingKey, new JsonObject { ["userId"] = user, ["sessionId"] = made.Id }.ToJsonString());
                next = made;
            }

            if (gateway != null)
            {
                var allBots = (AppState.Client?.Bots ?? []).Select(b => b.Name).ToList();
                var servers = new List<(string Profile, string? Url)>();
                for (var i = 0; i < allBots.Count; i += 3)
                {
                    var slice = allBots.Skip(i).Take(3).ToList();
                    var read = await Task.WhenAll(slice.Select(async id => (id, Server: await gateway.ServerAsync(id))));
                    foreach (var (id, server) in read)
                        if (server != null) servers.Add((id, server.Url));
                }

                var pending = BotsToMove(servers, next.Id);
                if (pending.Count > 0)
                {
                    var key = _keys.ReadKey(_accountId) ?? throw ComposioException.NoKey;
                    var failures = new List<string>();
                    for (var i = 0; i < pending.Count; i += 3)
                    {
                        var slice = pending.Skip(i).Take(3).ToList();
                        var res = await Task.WhenAll(slice.Select(async id =>
                        {
                            try { await gateway.TurnOnAsync(id, key, next.McpUrl); return (string?)null; }
                            catch (Exception ex) { return McpEntryMask.Phone.Text(CapabilitiesWords.Detail(ex)); }
                        }));
                        foreach (var f in res) if (f != null) failures.Add(f);
                    }
                    if (failures.Count > 0)
                    {
                        var reason = failures[0];
                        throw new ComposioException(ComposioErrorKind.Rejected,
                            failures.Count == 1 ? $"1 bot couldn’t be updated ({reason}). Try again." : $"{failures.Count} bots couldn’t be updated ({reason}). Try again.");
                    }
                }

                if (record != null || servers.Count > 0)
                {
                    var fresh = (record ?? new ComposioRecord(user, next.Id, AllBots: false)) with { SessionId = next.Id };
                    await gateway.WriteAsync(fresh);
                    Record = fresh;
                }
            }

            Session = next;
            CacheSession(next, user);
            ComposioLocalCache.Store.Set(MovingKey, null);
            Notify();
            return next;
        }
        finally
        {
            ComposioBotsGate.Applying = false;
        }
    }

    // ------------------------------------------------------------------ Connect Link OAuth (§10.8)

    public void CancelConnect()
    {
        _connectCts?.Cancel();
        _connectCts = null;
    }

    /// Creates a single-use Connect Link, opens the system browser, and polls `GET /api/v3/connected_accounts/<id>` until settled.
    public async Task ConnectAppAsync(string slug, string? alias = null, Func<Task<string>>? prepare = null)
    {
        if (_connectRunning || Session is not { } currentSession) return;
        _connectRunning = true;
        _connectCts?.Cancel();
        var cts = new CancellationTokenSource();
        _connectCts = cts;
        ConnectOutcome = null;
        Notify();

        try
        {
            var sessionId = currentSession.Id;
            if (prepare != null)
            {
                ConnectPhase = ComposioConnectPhase.Preparing;
                Notify();
                try { sessionId = await prepare(); }
                catch (Exception ex)
                {
                    ConnectOutcome = new ComposioConnectOutcome.Failed(
                        ex is ComposioException ce ? ce.Message : McpEntryMask.Phone.Text(CapabilitiesWords.Detail(ex)));
                    return;
                }
                if (cts.IsCancellationRequested) { ConnectOutcome = new ComposioConnectOutcome.Unfinished(); return; }
            }

            ConnectPhase = ComposioConnectPhase.Link;
            Notify();
            ConnectLink link;
            try
            {
                link = await _client.LinkAsync(sessionId, slug, alias: alias, callback: null, ct: cts.Token);
            }
            catch (ComposioException ex)
            {
                ConnectOutcome = ComposioSignIn.IsOwnAppRefusal(ex)
                    ? new ComposioConnectOutcome.NeedsOwnApp()
                    : new ComposioConnectOutcome.Failed(ex.Message);
                return;
            }

            var url = ComposioClient.ConnectLinkUrl(link.RedirectUrl);
            if (url == null)
            {
                ConnectOutcome = new ComposioConnectOutcome.Failed(ComposioException.Problem.Message);
                return;
            }
            if (string.IsNullOrEmpty(link.AccountId))
            {
                ConnectOutcome = new ComposioConnectOutcome.Failed("Composio lost this sign-in. Try again.");
                return;
            }

            ConnectPhase = ComposioConnectPhase.SignIn;
            Notify();
            var launched = await Launcher.LaunchUriAsync(url);
            if (!launched)
            {
                ConnectOutcome = new ComposioConnectOutcome.Failed("Couldn’t open your browser to sign in.");
                return;
            }

            ConnectPhase = ComposioConnectPhase.Checking;
            Notify();
            var deadline = DateTimeOffset.UtcNow + ConnectPollTimeout;
            while (DateTimeOffset.UtcNow < deadline && !cts.IsCancellationRequested)
            {
                try
                {
                    var account = await _client.AccountAsync(link.AccountId, cts.Token);
                    if (account.IsActive)
                    {
                        ConnectOutcome = new ComposioConnectOutcome.Connected();
                        return;
                    }
                    if (account.Status is "FAILED" or "EXPIRED")
                    {
                        ConnectOutcome = new ComposioConnectOutcome.Failed(
                            string.IsNullOrEmpty(account.Reason) ? "The sign-in didn’t finish. Try again." : account.Reason);
                        return;
                    }
                }
                catch (ComposioException ex) when (ex.Kind == ComposioErrorKind.NotFound)
                {
                    ConnectOutcome = new ComposioConnectOutcome.Failed("Composio lost this sign-in. Try again.");
                    return;
                }
                catch (OperationCanceledException)
                {
                    ConnectOutcome = new ComposioConnectOutcome.Unfinished();
                    return;
                }
                catch (Exception) { /* retry next tick */ }

                try { await Task.Delay(TimeSpan.FromMilliseconds(1500), cts.Token); }
                catch (OperationCanceledException)
                {
                    ConnectOutcome = new ComposioConnectOutcome.Unfinished();
                    return;
                }
            }

            ConnectOutcome = cts.IsCancellationRequested
                ? new ComposioConnectOutcome.Unfinished()
                : new ComposioConnectOutcome.Failed("Composio is still finishing this sign-in. Check again in a moment.");
        }
        finally
        {
            _connectRunning = false;
            ConnectPhase = ComposioConnectPhase.Idle;
            Notify();
        }
    }

    public async Task RenameAccountAsync(string slug, string accountId, string alias)
    {
        await _client.RenameAsync(accountId, alias);
        try { await LoadAccountsAsync(slug); } catch (Exception) { }
    }

    public async Task DisconnectAccountAsync(string slug, string accountId)
    {
        await _client.DisconnectAsync(accountId);
        try { await LoadAccountsAsync(slug); } catch (Exception) { }
        await LoadHomeAsync();
    }

    /// Opens `bot`'s chat with `prompt` placed in the composer without sending (`ConnectAppsChat.open`).
    public static async Task<string?> OpenTryItAsync(Bot bot, string prompt)
    {
        if (AppState.Client is not { } client) return $"Couldn’t open {bot.DisplayName}’s chat.";
        try
        {
            var chatId = await client.BotChatIdAsync(bot);
            Navigator.Go(new ChatDestination(bot.Name, chatId, bot.DisplayName, Draft: prompt));
            return null;
        }
        catch (Exception ex)
        {
            return CapabilitiesWords.Detail(ex);
        }
    }

    // ------------------------------------------------------------------ Remove (§10.9)

    public async Task<string?> RemoveAsync()
    {
        string? reason = null;
        if (Gateway is { } gateway && !ReadOnly)
        {
            if (BotStates == null) await LoadBotsAsync();
            var on = Bots.Select(b => b.Name).Where(id => BotStates?.GetValueOrDefault(id) is not ComposioBotState.Off).ToList();
            for (var i = 0; i < on.Count; i += 3)
            {
                var slice = on.Skip(i).Take(3).ToList();
                var failures = await Task.WhenAll(slice.Select(async id =>
                {
                    try { await gateway.TurnOffAsync(id); return (string?)null; }
                    catch (Exception ex) { return McpEntryMask.Phone.Text(CapabilitiesWords.Detail(ex)); }
                }));
                foreach (var f in failures) if (f != null) reason = f;
            }
            try { await gateway.WriteAsync(null); }
            catch (Exception ex) { reason ??= CapabilitiesWords.Detail(ex); }
        }
        else
        {
            reason = "this gateway is read-only";
        }

        _keys.DeleteKey(_accountId);
        ComposioLocalCache.Store.Set(SessionCacheKey, null);
        ComposioLocalCache.Store.Set(ComposioLocalCache.VerifiedKey(_accountId), null);
        ComposioLocalCache.Store.Set(MultiKey, null);
        ComposioLocalCache.Store.Set(IdentityKey, null);
        ComposioLocalCache.Store.Set(MovingKey, null);
        Identities.Clear();
        AppAccounts.Clear();
        ComposioReconciler.Shared.Stop();

        Session = null;
        Record = null;
        Connected = null;
        Popular = null;
        BotStates = null;
        _allResults = null;
        Phase = ComposioPhase.Setup;
        SetupNotice = reason != null
            ? new ComposioNotice($"Removed From This {DeviceWord.Name} Only",
                $"Hermes HQ couldn’t update every bot ({reason}). If Capabilities › Connectors still lists “composio” on a bot, remove it there.",
                IsError: false)
            : null;
        Notify();
        return reason;
    }

    public void Dispose()
    {
        _disposed = true;
        _connectCts?.Cancel();
        _client.Dispose();
    }
}

/// Background reconciler for "All Bots": automatically gives newly created bots the `composio` MCP server
/// when `ui_meta["dispatch-composio"].allBots == true` (`ComposioReconciler` in `ComposioModel.swift`).
internal sealed class ComposioReconciler
{
    public static ComposioReconciler Shared { get; } = new();

    private CancellationTokenSource? _loopCts;
    private string _account = "";
    private volatile bool _hasKey;
    private int _tries;
    private DateTimeOffset? _retryAt;
    private int _rosterCount = -1;
    private DateTimeOffset? _changedAt;

    public void Start(HermesClient? client)
    {
        Stop();
        if (client == null) return;
        _account = client.AccountId;
        _hasKey = ConnectAppsFeature.KeyStore.Status(_account).Saved;
        _tries = 0;
        _retryAt = null;
        _rosterCount = -1;
        _changedAt = DateTimeOffset.UtcNow;

        var cts = new CancellationTokenSource();
        _loopCts = cts;
        _ = RunLoopAsync(client, cts.Token);
    }

    public void Stop()
    {
        _loopCts?.Cancel();
        _loopCts = null;
    }

    public void KeySaved()
    {
        _hasKey = true;
        _retryAt = null;
        _tries = 0;
    }

    private async Task RunLoopAsync(HermesClient client, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try { await Task.Delay(TimeSpan.FromSeconds(2), ct).ConfigureAwait(false); }
            catch (OperationCanceledException) { return; }

            if (AppShutdown.Stopping || ComposioBotsGate.Applying) continue;
            if (client.Rpc.State != Hermes.Core.Rpc.ConnectionState.Open) continue;
            if (CapabilitiesServices.Api is not { } api || api.ReadOnly) continue;

            var bots = client.Bots;
            if (bots == null || bots.Count == 0) continue;
            if (bots.Count != _rosterCount) { _rosterCount = bots.Count; _changedAt = DateTimeOffset.UtcNow; }

            var rosterIds = bots.Select(b => b.Name).ToList();
            var verified = ComposioLocalCache.PrunedVerified(ComposioLocalCache.ReadStringSet(ComposioLocalCache.VerifiedKey(_account)), rosterIds);
            ComposioLocalCache.WriteStringSet(ComposioLocalCache.VerifiedKey(_account), verified);

            var missing = rosterIds.Where(id => !verified.Contains(id)).ToList();
            if (missing.Count == 0) continue;
            if (_changedAt is { } changedAt && DateTimeOffset.UtcNow - changedAt < TimeSpan.FromSeconds(2)) continue;
            if (_retryAt is { } retryAt && DateTimeOffset.UtcNow < retryAt) continue;
            if (_tries >= 6 || !_hasKey) continue;

            try
            {
                var gateway = new ComposioGateway(api);
                var record = await gateway.RecordAsync(ct).ConfigureAwait(false);
                if (record == null || !record.AllBots || string.IsNullOrEmpty(record.SessionId))
                {
                    _changedAt = null;
                    _retryAt = DateTimeOffset.UtcNow.AddSeconds(60);
                    continue;
                }

                var secret = ConnectAppsFeature.KeyStore.ReadKey(_account);
                if (string.IsNullOrEmpty(secret))
                {
                    BackOff();
                    continue;
                }

                using var composio = new ComposioClient(ConnectAppsFeature.KeyStore, _account);
                var session = await composio.ReadSessionAsync(record.SessionId, ct).ConfigureAwait(false);
                var done = new HashSet<string>(verified, StringComparer.Ordinal);
                var failed = false;

                for (var i = 0; i < missing.Count && !ct.IsCancellationRequested; i += 2)
                {
                    foreach (var profile in missing.Skip(i).Take(2))
                    {
                        try
                        {
                            if (await gateway.ServerAsync(profile, ct).ConfigureAwait(false) == null)
                                await gateway.TurnOnAsync(profile, secret, session.McpUrl, ct).ConfigureAwait(false);
                            done.Add(profile);
                        }
                        catch (Exception) { failed = true; }
                    }
                }

                var merged = ComposioLocalCache.ReadStringSet(ComposioLocalCache.VerifiedKey(_account));
                merged.UnionWith(done);
                ComposioLocalCache.WriteStringSet(ComposioLocalCache.VerifiedKey(_account), merged);

                if (failed) BackOff();
                else { _tries = 0; _retryAt = null; }
            }
            catch (OperationCanceledException) { return; }
            catch (Exception) { BackOff(); }
        }
    }

    private void BackOff()
    {
        _tries++;
        _retryAt = DateTimeOffset.UtcNow.AddSeconds(30 * Math.Pow(2, _tries - 1));
    }
}
