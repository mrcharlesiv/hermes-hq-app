using Hermes.Core;
using Hermes.Core.Capabilities;
using HermesHQ.Services;
using HermesHQ.Shell;

namespace HermesHQ.Features.Capabilities;

/// Navigation argument for `PluginWebPage` (either a `PluginPageTarget` or a bare `PluginDashboardPage`).
public sealed record PluginPageTarget(
    PluginDashboardPage Page,
    string Profile,
    string BotName,
    IReadOnlyList<(string Profile, string Name)> OtherBots);

/// Discovers Hermes dashboard plugin pages per gateway across visible bots and registers the `"plugin-page"` place
/// (`App/Capabilities/PluginPages/PluginPagesMore.swift`).
public static class PluginPagesService
{
    public const string PlaceId = "plugin-page";

    /// Teal tile colour shared by all plugin page rows (`PluginPagesMore.tile = 0x00C7BE`).
    public const uint TileRgb = 0x00C7BE;

    private static readonly object Gate = new();
    private static readonly Dictionary<string, Dictionary<string, IReadOnlyList<PluginDashboardPage>>> PagesByAccount = new(StringComparer.Ordinal);
    private static readonly Dictionary<string, DateTimeOffset> LastRead = new(StringComparer.Ordinal);
    private static CancellationTokenSource? _refreshCts;
    private static HermesClient? _client;
    private static bool _registered;

    /// Raised when the discovered plugin page list changes for the active gateway.
    public static event Action? Changed;

    /// Claims the `"plugin-page"` place and hooks gateway lifecycle events. Safe to call multiple times.
    public static void Register()
    {
        if (_registered) return;
        _registered = true;

        if (Places.All.All(p => p.Id != PlaceId))
        {
            Places.All.Add(new Place(PlaceId, "Plugin Page", "\uF0E2", Places.Tools, typeof(PluginWebPage),
                ["plugin", "page", "dashboard", "wiki"]));
        }
        Places.Register(PlaceId, typeof(PluginWebPage));

        AppState.ClientChanged += Use;
        if (AppState.Client is { } client) Use(client);
    }

    private static void Use(HermesClient? client)
    {
        if (_client != null)
        {
            _client.BotsChanged -= OnBotsChanged;
            _client.Rpc.Reconnected -= OnReconnected;
        }
        _refreshCts?.Cancel();
        _refreshCts = null;
        _client = client;
        if (client != null)
        {
            client.BotsChanged += OnBotsChanged;
            client.Rpc.Reconnected += OnReconnected;
            if (client.Bots != null) Refresh(reconnect: false);
        }
        Changed?.Invoke();
    }

    private static void OnBotsChanged() => Refresh(reconnect: false);
    private static void OnReconnected(bool _) => Refresh(reconnect: true);

    /// Every discovered plugin page for the active gateway, deduplicated and sorted by label with its bots in roster order.
    public static IReadOnlyList<PluginPageListed> Listed()
    {
        var client = AppState.Client;
        if (client == null) return [];
        var bots = CapabilitiesServices.Bots().Select(b => b.Name).ToList();
        if (bots.Count == 0) bots = ["default"];

        Dictionary<string, IReadOnlyList<PluginDashboardPage>> snapshot;
        lock (Gate)
        {
            if (!PagesByAccount.TryGetValue(client.AccountId, out var byBot)) return [];
            snapshot = new Dictionary<string, IReadOnlyList<PluginDashboardPage>>(byBot, StringComparer.Ordinal);
        }
        return DashboardPagesMerge.Merge(snapshot, bots);
    }

    /// Returns the bot-specific `PluginDashboardPage` if cached for `(name, profile)`.
    public static PluginDashboardPage? PageFor(string name, string profile)
    {
        var account = AppState.Client?.AccountId;
        if (string.IsNullOrEmpty(account)) return null;
        lock (Gate)
        {
            return PagesByAccount.TryGetValue(account, out var byBot)
                && byBot.TryGetValue(profile, out var pages)
                ? pages.FirstOrDefault(p => p.Name == name)
                : null;
        }
    }

    /// Updates cached pages for one bot immediately when Capabilities reads its plugin list (`PluginPagesMore.note`).
    public static void Note(IReadOnlyList<PluginDashboardPage> pages, string profile)
    {
        var account = AppState.Client?.AccountId;
        if (string.IsNullOrEmpty(account)) return;
        var changed = false;
        lock (Gate)
        {
            if (!PagesByAccount.TryGetValue(account, out var byBot))
                PagesByAccount[account] = byBot = new Dictionary<string, IReadOnlyList<PluginDashboardPage>>(StringComparer.Ordinal);
            if (!byBot.TryGetValue(profile, out var existing) || !existing.SequenceEqual(pages))
            {
                byBot[profile] = [.. pages];
                changed = true;
            }
        }
        if (changed) Changed?.Invoke();
    }

    /// Refreshes plugin pages across visible bots with bounded concurrency (throttled to 10 min on reconnects).
    public static void Refresh(bool reconnect = false)
    {
        var client = AppState.Client;
        if (client == null) return;
        var account = client.AccountId;
        var profiles = CapabilitiesServices.Bots().Select(b => b.Name).ToList();
        if (profiles.Count == 0) return;

        var now = DateTimeOffset.UtcNow;
        lock (Gate)
        {
            if (reconnect && LastRead.TryGetValue(account, out var prev) && !DashboardPagesMerge.IsDue(prev, now))
                return;
            LastRead[account] = now;
        }

        _refreshCts?.Cancel();
        var cts = new CancellationTokenSource();
        _refreshCts = cts;
        var api = new DashboardPagesApi(client.Session);

        _ = Task.Run(async () =>
        {
            try
            {
                var fetched = await DashboardPagesMerge.ReadPagesAsync(
                    profiles,
                    async profile =>
                    {
                        try { return await api.ListAsync(profile, cts.Token).ConfigureAwait(false); }
                        catch (Exception) { return null; }
                    },
                    DashboardPagesMerge.ReadWidth,
                    cts.Token).ConfigureAwait(false);

                if (cts.IsCancellationRequested || AppState.Client?.AccountId != account) return;
                if (fetched.Count == 0)
                {
                    lock (Gate) LastRead.Remove(account);
                    return;
                }

                var changed = false;
                lock (Gate)
                {
                    if (!PagesByAccount.TryGetValue(account, out var byBot))
                        PagesByAccount[account] = byBot = new Dictionary<string, IReadOnlyList<PluginDashboardPage>>(StringComparer.Ordinal);
                    foreach (var (profile, pages) in fetched)
                    {
                        if (!byBot.TryGetValue(profile, out var existing) || !existing.SequenceEqual(pages))
                        {
                            byBot[profile] = pages;
                            changed = true;
                        }
                    }
                }
                if (changed) Changed?.Invoke();
            }
            catch (OperationCanceledException) { }
            catch (Exception ex)
            {
                AppLog.Note("plugin-pages", $"discovery failed: {ex.GetType().Name}");
            }
        }, cts.Token);
    }

    /// Opens `page` in `PluginWebPage`, resolving the target bot and sibling bots that also expose the page.
    public static void Open(PluginDashboardPage page, string? profile = null)
    {
        Register();
        var target = BuildTarget(page, profile);
        Navigator.Open(PlaceId, target);
    }

    /// Resolves either a `PluginPageTarget` or a bare `PluginDashboardPage` passed to `Navigator.Open("plugin-page", arg)`.
    public static PluginPageTarget? ResolveTarget(object? argument) => argument switch
    {
        PluginPageTarget target => target,
        PluginDashboardPage page => BuildTarget(page, null),
        _ => null,
    };

    private static PluginPageTarget BuildTarget(PluginDashboardPage page, string? requestedProfile)
    {
        var listed = Listed().FirstOrDefault(x => x.Page.Name == page.Name);
        var profiles = listed?.Profiles ?? (requestedProfile != null ? [requestedProfile] : ["default"]);
        var chosen = !string.IsNullOrEmpty(requestedProfile) && profiles.Contains(requestedProfile)
            ? requestedProfile
            : (requestedProfile ?? profiles.FirstOrDefault() ?? "default");
        var botPage = PageFor(page.Name, chosen) ?? page;
        var otherBots = profiles.Count > 1
            ? profiles.Select(p => (p, CapabilitiesServices.BotName(p))).ToList()
            : new List<(string, string)>();
        return new PluginPageTarget(botPage, chosen, CapabilitiesServices.BotName(chosen), otherBots);
    }
}
