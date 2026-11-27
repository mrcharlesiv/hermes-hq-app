using Hermes.Core;
using Hermes.Core.Capabilities;
using Hermes.Core.Composer;
using Hermes.Core.Model;
using HermesHQ.Services;
using HermesHQ.Shell;
using Microsoft.UI.Dispatching;

namespace HermesHQ.Features.Capabilities;

/// What Capabilities is opened with (Navigator.Open("capabilities", …)): a list for a bot, or the four rows.
public sealed record CapabilitiesTarget(CapabilitiesTab? Tab = null, string? Profile = null, bool BotLocked = false, string? Focus = null);

/// PARITY.md Pages: Capabilities (Skills, Tools, Connectors, Plugins, Managed Apps) and the Marketplace place.
/// App/Capabilities/*, App/ConnectApps/*, HermesKit/Connectors/*, HermesKit/Plugins/*.
public static class CapabilitiesFeature
{
    public static void Register()
    {
        Places.Register("capabilities", typeof(CapabilitiesPage));
        Places.Register("marketplace", typeof(MarketplacePage));
        AppState.ClientChanged += CapabilitiesServices.Use;
        if (AppState.Client is { } c) CapabilitiesServices.Use(c);
    }

    /// Bot Info › Capabilities: the bot's own lists, its Bot row fixed to it (UX study #187). For the lists feature.
    public static void OpenForBot(Bot bot) => Navigator.Open("capabilities", new CapabilitiesTarget(Profile: bot.Name, BotLocked: true));

    /// One of a bot's lists (Bot Info › Skills, › Connectors…).
    public static void OpenForBot(Bot bot, CapabilitiesTab tab) => Navigator.Open("capabilities", new CapabilitiesTarget(tab, bot.Name, BotLocked: true));

    /// The Marketplace, installing to `bot` (or Hermes).
    public static void OpenMarketplace(Bot? bot = null) => Navigator.Open("marketplace", bot?.Name);
}

/// What every Capabilities page shares on this PC: the gateway in use's calls, the connector issues (kept per account),
/// the Marketplace's lists, and each bot's managed apps.
internal static class CapabilitiesServices
{
    public static ServerIssues Issues { get; } = new(new JsonFileStore(Path.Combine(AppPaths.Root, "capabilities.json")));
    public static WebCatalog<PluginCatalogEntry> PluginCatalog { get; } = MarketCatalogs.Plugins(Path.Combine(AppPaths.Root, "catalogs"));
    public static WebCatalog<MarketSkill> SkillCatalog { get; } = MarketCatalogs.Skills(Path.Combine(AppPaths.Root, "catalogs"));
    public static HermesClient? Client { get; private set; }
    public static CapabilitiesApi? Api { get; private set; }
    public static ManagedConnectorsApi? Managed { get; private set; }
    private static readonly Dictionary<string, ManagedAppsState> ManagedStates = [];
    private static readonly Dictionary<string, NousAccount> NousAccounts = [];
    /// A `connection.update` moved a managed sign-in on (raised on a background thread).
    public static event Action? ManagedChanged;
    private static CancellationTokenSource? _sweep;

    /// The stand-in gateway's pages are loopback http (the e2e and the CI's screenshots).
    public static bool LoopbackGateway => Client?.Session.Address is { } a && a.Endpoint("/", null).IsLoopback;

    public static void Use(HermesClient? client)
    {
        if (Client != null) Client.Rpc.Event -= OnEvent;
        if (Client != null) Client.BotsChanged -= Sweep;
        _sweep?.Cancel();
        Client = client;
        lock (ManagedStates) { ManagedStates.Clear(); NousAccounts.Clear(); }
        Issues.Use(client?.AccountId ?? "");
        if (client == null) { Api = null; Managed = null; return; }
        Api = new CapabilitiesApi(client.Session, client.Rpc);
        Managed = new ManagedConnectorsApi(client.Rpc);
        client.Rpc.Event += OnEvent;
        client.BotsChanged += Sweep;
        if (client.Bots != null) Sweep();
    }

    public static ManagedAppsState ManagedFor(string profile)
    {
        lock (ManagedStates)
        {
            if (!ManagedStates.TryGetValue(profile, out var s)) ManagedStates[profile] = s = new ManagedAppsState(Managed!, profile);
            return s;
        }
    }

    public static NousAccount NousFor(string profile)
    {
        lock (ManagedStates)
        {
            if (!NousAccounts.TryGetValue(profile, out var n))
            {
                NousAccounts[profile] = n = new NousAccount(Client!.Session);
                n.Accepts = link => Kit.SafeLink(link) is { } u && (u.Scheme == "https" || LoopbackGateway) ? u : null;
                n.Open = url => { Kit.Open(url.ToString()); return true; };
                // Signed in: the bot's managed apps read again.
                n.SignedIn += () => _ = ManagedFor(profile).ReloadAsync().ContinueWith(_ => ManagedChanged?.Invoke());
            }
            return n;
        }
    }

    private static void OnEvent(Hermes.Core.Rpc.RpcEvent ev)
    {
        if (ev.Type != "connection.update") return;
        var moved = false;
        lock (ManagedStates) foreach (var s in ManagedStates.Values) moved |= s.Apply(ev.Payload);
        if (moved) ManagedChanged?.Invoke();
    }

    /// `ServerIssueSweep`: every bot's connectors read (two at a time, at most 30 bots) when the roster comes in and
    /// every 10 minutes after, so the Connectors row says "1 Issue" before its page is opened. A failed read never
    /// creates or clears an issue; a failure is read again after the debounce.
    private static void Sweep()
    {
        if (Client is not { Bots: { } bots } || Api is not { } api) return;
        if (_sweep is { IsCancellationRequested: false }) return;
        var cts = new CancellationTokenSource();
        _sweep = cts;
        var profiles = ServerIssues.SweepOrder(bots.Where(b => !b.Hidden).Select(b => b.Name));
        _ = Task.Run(async () =>
        {
            while (!cts.IsCancellationRequested)
            {
                var sawFailure = false;
                for (var i = 0; i < profiles.Count && !cts.IsCancellationRequested; i += 2)
                {
                    var pair = profiles.Skip(i).Take(2).ToList();
                    var reads = pair.Select(async p =>
                    {
                        try { return (p, await api.ServersWithStatusAsync(p, cts.Token)); }
                        catch (Exception) { return (p, (List<McpServer>?)null); }
                    }).ToList();
                    foreach (var (p, list) in await Task.WhenAll(reads))
                    {
                        if (list == null) continue;
                        if (list.Any(s => s.Enabled && s.Status == "failed")) sawFailure = true;
                        Issues.Report(p, list);
                    }
                }
                try { await Task.Delay(sawFailure ? ServerIssues.Debounce + TimeSpan.FromSeconds(2) : TimeSpan.FromMinutes(10), cts.Token); }
                catch (OperationCanceledException) { return; }
            }
        });
    }

    /// The bots a picker offers: visible ones, Hermes (`default`) first, then A–Z.
    public static List<Bot> Bots()
    {
        var all = Client?.Bots ?? [];
        return [.. all.Where(b => !b.Hidden).OrderBy(b => b.Name == "default" ? 0 : 1).ThenBy(b => b.DisplayName, StringComparer.CurrentCultureIgnoreCase)];
    }

    public static string BotName(string profile) =>
        Client?.Bots?.FirstOrDefault(b => b.Name == profile)?.DisplayName ?? (profile == "default" ? "Hermes" : DisplayName.Title(profile));

    public static DispatcherQueue? Ui { get; set; }
}
