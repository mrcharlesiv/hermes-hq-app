using Hermes.Core.Capabilities;
using HermesHQ.Services;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace HermesHQ.Features.Capabilities;

public enum ToolSort { Most, Least, Name }

/// The inline "Installing…" / "Installed" row of an official skill (CapabilitiesModel+More.swift `InstallNotice`).
internal sealed record InstallNotice(string Profile, string Identifier, string Name, string Bot, bool Done)
{
    public string Id => $"{Profile}|{Identifier}";
    public string Title => CapabilitiesWords.InstallTitle(Name, Done);
    public string Message => CapabilitiesWords.InstallMessage(Bot, Done);
}

/// Capabilities for one bot and one list (App/Capabilities/CapabilitiesModel.swift and +More): each list keeps its
/// last answer painted while it refreshes; writes are optimistic and flip back on failure. Lives on the UI thread;
/// `Changed` asks the page to draw again.
internal sealed class CapabilitiesModel
{
    public CapabilitiesTab Tab { get; }
    public string Profile { get; private set; }
    public event Action? Changed;
    /// Where dialogs show: read when one opens (the page may not be in the window yet when the model is made).
    public Func<XamlRoot?>? RootSource { get; set; }
    public XamlRoot? Root => RootSource?.Invoke();
    private readonly DispatcherQueue _ui = DispatcherQueue.GetForCurrentThread();

    public CapabilitiesApi? Api => CapabilitiesServices.Api;
    public bool ReadOnly => Api?.ReadOnly ?? false;
    public bool IsConnected => CapabilitiesServices.Client?.Rpc.State == Hermes.Core.Rpc.ConnectionState.Open;
    public string BotName => CapabilitiesServices.BotName(Profile);
    public string Query { get; set; } = "";
    public string Trimmed => Query.Trim();

    // Skills
    public List<SkillInfo>? Skills { get; private set; }
    public List<OfficialSkill>? Official { get; private set; }
    public string? SkillsError { get; private set; }
    public HashSet<string> Toggling { get; } = [];
    public HashSet<string> Running { get; } = [];
    public List<InstallNotice> Notices { get; } = [];
    public string? SkillsNotice { get; private set; }
    public (int Done, int Total)? Disabling { get; private set; }
    public bool RefreshFailed { get; set; }
    public string? HubQuery { get; private set; }
    public List<HubSkill>? HubResults { get; private set; }
    public HashSet<string> HubInstalled { get; private set; } = [];
    public bool HubSearching { get; private set; }
    public string? HubError { get; private set; }
    public bool HubUnsupported { get; private set; }

    // Tools
    public List<Toolset>? Toolsets { get; private set; }
    public string? ToolsError { get; private set; }
    public bool ToolsTooOld { get; private set; }
    public Dictionary<string, int>? ToolUsage { get; private set; }
    public HashSet<string> ToolToggling { get; private set; } = [];
    public static ToolSort SavedSort { get; set; } = ToolSort.Most;
    public ToolSort Sort { get => SavedSort; set { SavedSort = value; Notify(); } }

    // Connectors
    public List<McpServer>? Servers { get; private set; }
    public string? ServersError { get; private set; }
    public HashSet<string> McpToggling { get; } = [];
    public List<McpCatalogEntry>? Catalog { get; private set; }
    public string? ServersNotice { get; set; }
    public string? Focus { get; set; }
    public ManagedAppsState? Managed { get; private set; }
    public HashSet<string> ManagedBusy { get; } = [];
    public Dictionary<string, string> ManagedNotices { get; } = [];

    // Plugins
    public List<PluginInfo>? Plugins { get; private set; }
    public string? PluginsError { get; private set; }
    public bool PluginsUnavailable { get; private set; }
    public HashSet<string> PluginBusy { get; } = [];
    public string? PluginNotice { get; set; }
    public bool PluginNeedsKeys { get; set; }
    public Dictionary<string, IReadOnlyList<string>> PluginWarnings { get; } = [];

    private readonly Dictionary<string, DateTimeOffset> _loadedAt = [];
    private DispatcherQueueTimer? _statusTimer;

    public CapabilitiesModel(CapabilitiesTab tab, string? profile)
    {
        Tab = tab;
        Profile = profile ?? "default";
        if (tab == CapabilitiesTab.Connectors && CapabilitiesServices.Managed != null) Managed = CapabilitiesServices.ManagedFor(Profile);
    }

    public void Notify()
    {
        if (_ui.HasThreadAccess) Changed?.Invoke();
        else _ui.TryEnqueue(() => Changed?.Invoke());
    }

    private void Fail(string title, Exception e, Action? retry = null) => Kit.Fail(Root, title, CapabilitiesWords.Detail(e), retry);

    public void SetProfile(string profile)
    {
        if (profile == Profile) return;
        Profile = profile;
        Skills = null; Official = null; SkillsError = null; Toolsets = null; ToolsError = null; ToolUsage = null;
        Servers = null; ServersError = null; Catalog = null; Plugins = null; PluginsError = null;
        SkillsNotice = null; ServersNotice = null; PluginNotice = null; RefreshFailed = false;
        HubQuery = null; HubResults = null; HubError = null; HubInstalled = []; HubUnsupported = false;
        _loadedAt.Clear();
        if (Tab == CapabilitiesTab.Connectors && CapabilitiesServices.Managed != null) Managed = CapabilitiesServices.ManagedFor(Profile);
        Notify();
        Load();
    }

    // ---------------------------------------------------------------- Lifecycle

    public void Appear()
    {
        Load();
        if (Tab == CapabilitiesTab.Connectors)
        {
            _statusTimer?.Stop();
            _statusTimer = _ui.CreateTimer();
            _statusTimer.Interval = TimeSpan.FromSeconds(10);
            _statusTimer.Tick += async (_, _) =>
            {
                if (AppShutdown.Stopping) { _statusTimer?.Stop(); return; }
                await RefreshStatus();
            };
            _statusTimer.Start();
            CapabilitiesServices.ManagedChanged -= OnManaged;
            CapabilitiesServices.ManagedChanged += OnManaged;
        }
    }

    public void Disappear()
    {
        _statusTimer?.Stop(); _statusTimer = null;
        CapabilitiesServices.ManagedChanged -= OnManaged;
    }

    private void OnManaged()
    {
        if (AppShutdown.Stopping) return;
        _ui.TryEnqueue(async () =>
        {
            if (AppShutdown.Stopping || Managed == null) return;
            foreach (var op in Managed.Operations.Values.Where(o => o.Settled).ToList())
                foreach (var slug in op.Connectors) ManagedBusy.Remove(slug);
            if (Managed.Phase is ManagedPhase.Ready) await Managed.ReloadAccountsAndListAsync();
            if (!AppShutdown.Stopping) Notify();
        });
    }

    /// A list read under 30 s ago is not read again by coming back to it.
    private bool Fresh(string kind) => _loadedAt.TryGetValue($"{kind}|{Profile}", out var at) && DateTimeOffset.UtcNow - at < TimeSpan.FromSeconds(30);
    private void Stamp(string kind, string profile) => _loadedAt[$"{kind}|{profile}"] = DateTimeOffset.UtcNow;

    public void Load()
    {
        switch (Tab)
        {
            case CapabilitiesTab.Skills: if (!Fresh("skills")) _ = ReloadSkills(); _ = LoadSkillCatalog(); break;
            case CapabilitiesTab.Tools: if (!Fresh("tools")) _ = ReloadTools(); break;
            case CapabilitiesTab.Connectors:
                if (!Fresh("servers")) _ = ReloadServers();
                if (!Fresh("catalog")) _ = ReloadCatalog();
                if (Managed != null && (Managed.LoadedAt is not { } at || DateTimeOffset.UtcNow - at > TimeSpan.FromSeconds(30))) _ = ReloadManaged();
                break;
            case CapabilitiesTab.Plugins:
                _ = LoadPluginCatalog();
                if (!Fresh("plugins")) _ = ReloadPlugins();
                break;
        }
    }

    private async Task LoadSkillCatalog() { await CapabilitiesServices.SkillCatalog.LoadAsync(); Notify(); }
    private async Task LoadPluginCatalog() { await CapabilitiesServices.PluginCatalog.LoadAsync(); Notify(); }

    /// ⋯ › Refresh: the list showing, past every cache.
    public async Task Refresh()
    {
        RefreshFailed = false;
        switch (Tab)
        {
            case CapabilitiesTab.Skills: await ReloadSkills(refresh: true); break;
            case CapabilitiesTab.Tools: ToolUsage = null; await ReloadTools(); break;
            case CapabilitiesTab.Connectors: await Task.WhenAll(ReloadServers(), ReloadCatalog(), ReloadManaged()); break;
            case CapabilitiesTab.Plugins: await Task.WhenAll(ReloadPlugins(), CapabilitiesServices.PluginCatalog.LoadAsync(force: true)); break;
        }
        Notify();
    }

    /// One quick retry, none after a timeout or while the gateway cannot be reached (QueryRetry).
    private static async Task<T> Retry<T>(Func<Task<T>> read)
    {
        try { return await read(); }
        catch (Exception e) when (!CapabilitiesWords.IsTransport(e) && e is not CapabilityException)
        {
            await Task.Delay(400);
            return await read();
        }
    }

    // ---------------------------------------------------------------- Skills

    public async Task ReloadSkills(bool refresh = false)
    {
        if (Api is not { } api) return;
        var profile = Profile;
        var catalogRead = Task.Run(async () => { try { return await api.OfficialSkillsAsync(profile); } catch (Exception) { return null; } });
        try
        {
            var installed = await Retry(() => api.SkillsAsync(profile));
            if (profile != Profile) return;
            Skills = installed;
            SkillsError = null;
            Stamp("skills", profile);
            Notify();
            if (await catalogRead is { } catalog && profile == Profile) Official = catalog;
        }
        catch (Exception e)
        {
            if (profile != Profile) return;
            if (Skills == null) SkillsError = CapabilitiesWords.Detail(e);
            else if (refresh) RefreshFailed = true;
        }
        Notify();
    }

    private bool Matches(string name, string description, string? category)
    {
        var q = Trimmed;
        return q.Length == 0 || new[] { name, description, category ?? "" }.Any(s => s.Contains(q, StringComparison.CurrentCultureIgnoreCase));
    }

    /// Installed, by usage then name, matching the search.
    public List<SkillInfo> ShownSkills => [.. (Skills ?? []).Where(s => Matches(s.Name, s.Description, s.Category))
        .OrderByDescending(s => s.Usage ?? 0).ThenBy(s => s.Name, StringComparer.CurrentCultureIgnoreCase)];

    /// Official skills not installed (and with no installed skill of that name), A–Z.
    public List<OfficialSkill> Available
    {
        get
        {
            var names = (Skills ?? []).Select(s => s.Name).ToHashSet();
            return [.. (Official ?? []).Where(o => !o.Installed && !names.Contains(o.Name) && Matches(o.Name, o.Description, o.Category))
                .OrderBy(o => o.Name, StringComparer.CurrentCultureIgnoreCase)];
        }
    }

    public async void SetSkill(SkillInfo skill, bool enabled)
    {
        if (Api is not { } api || !Toggling.Add(skill.Name)) return;
        var profile = Profile;
        Flip(skill.Name, enabled);
        Notify();
        try { await api.SetSkillAsync(skill.Name, enabled, profile); }
        catch (Exception e)
        {
            if (profile == Profile) Flip(skill.Name, !enabled);
            Fail($"Couldn’t Change {DisplayName.Title(skill.Name)}", e, () => SetSkill(skill, enabled));
        }
        finally { Toggling.Remove(skill.Name); }
        if (profile == Profile) await ReloadSkills();
    }

    private void Flip(string name, bool enabled)
    {
        if (Skills?.FindIndex(s => s.Name == name) is { } i and >= 0) Skills[i] = Skills[i] with { Enabled = enabled };
    }

    /// "Get" asks first, then an inline progress row follows the action (§3.1).
    public async void Install(OfficialSkill skill)
    {
        if (Running.Contains(skill.Identifier)) return;
        if (await Kit.Confirm(Root, CapabilitiesWords.InstallAsk(skill.Name, BotName), CapabilitiesWords.InstallAskMessage(BotName), "Install"))
            await RunInstall(skill.Name, skill.Identifier);
    }

    public async void Install(HubSkill skill)
    {
        if (Running.Contains(skill.Identifier)) return;
        if (await Kit.Confirm(Root, CapabilitiesWords.InstallAsk(skill.Name, BotName), CapabilitiesWords.HubInstallAskMessage(skill, BotName), "Install"))
        {
            if (await RunInstall(skill.Name, skill.Identifier)) HubInstalled.Add(skill.Identifier);
            Notify();
        }
    }

    /// A Marketplace skill: asks first, saying where it comes from, then installs as a hub skill does.
    public async void Install(MarketSkill skill)
    {
        if (Running.Contains(skill.InstallIdentifier)) return;
        if (await Kit.Confirm(Root, $"Install {skill.Name} for {BotName}?", MarketplaceWords.SkillInstallMessage(skill, BotName), "Install"))
            await RunInstall(skill.Name, skill.InstallIdentifier);
    }

    public async Task<bool> RunInstall(string name, string identifier)
    {
        if (Api is not { } api || !Running.Add(identifier)) return false;
        var profile = Profile;
        var notice = new InstallNotice(profile, identifier, name, BotName, false);
        Notices.RemoveAll(n => n.Id == notice.Id);
        Notices.Add(notice);
        Notify();
        ActionStatus? last = null;
        try
        {
            await foreach (var status in api.InstallAsync(identifier, profile)) last = status;
        }
        catch (Exception e)
        {
            Notices.RemoveAll(n => n.Id == notice.Id);
            Running.Remove(identifier);
            Fail($"Couldn’t Install {DisplayName.Title(name)}", e);
            Notify();
            return false;
        }
        Running.Remove(identifier);
        var ok = last?.ExitCode == 0;
        if (ok)
        {
            var i = Notices.FindIndex(n => n.Id == notice.Id);
            if (i >= 0) Notices[i] = notice with { Done = true };
            _ = Seen(notice with { Done = true });
        }
        else
        {
            Notices.RemoveAll(n => n.Id == notice.Id);
            if (last != null)
            {
                string reason;
                if (CapabilitiesWords.InstallBlocked(last.Lines) is { } blocked) reason = CapabilitiesWords.BlockedMessage(blocked.Findings, blocked.Unverified);
                else
                {
                    var tail = string.Join("\n", last.Lines.Skip(Math.Max(0, last.Lines.Count - 3))).Trim();
                    reason = tail.Length == 0 ? $"The install ended with code {last.ExitCode ?? -1}." : tail;
                }
                Kit.Fail(Root, $"Couldn’t Install {DisplayName.Title(name)}", reason);
            }
        }
        Notify();
        if (profile == Profile) await ReloadSkills();
        return ok;
    }

    /// The "Installed" row leaves 4 s after it shows, or on a click.
    private async Task Seen(InstallNotice notice)
    {
        await Task.Delay(TimeSpan.FromSeconds(4));
        Notices.RemoveAll(n => n.Id == notice.Id && n.Done);
        Notify();
    }

    public void Dismiss(InstallNotice notice) { Notices.RemoveAll(n => n.Id == notice.Id); Notify(); }

    public async Task<bool> Uninstall(string name)
    {
        if (Api is not { } api || !Running.Add(name)) return false;
        var profile = Profile;
        Notify();
        ActionStatus? last = null;
        try { await foreach (var status in api.UninstallAsync(name, profile)) last = status; }
        catch (Exception e)
        {
            Running.Remove(name);
            Fail($"Couldn’t Uninstall {name}", e);
            Notify();
            return false;
        }
        Running.Remove(name);
        var ok = last?.ExitCode == 0;
        if (!ok)
        {
            var tail = string.Join("\n", (last?.Lines ?? []).TakeLast(3));
            Kit.Fail(Root, $"Couldn’t Uninstall {name}", tail.Length == 0 ? "The uninstall didn’t finish." : tail);
        }
        if (profile == Profile) await ReloadSkills();
        return ok;
    }

    // Disable Unused (§3.2): only when the rows carry use counts.
    public List<SkillInfo> UnusedSkills => [.. (Skills ?? []).Where(s => s.Enabled && s.Usage == 0)];
    public bool HasUsage => (Skills ?? []).Any(s => s.Usage != null);

    public async void DisableUnused()
    {
        var unused = UnusedSkills;
        if (unused.Count == 0 || Disabling != null || ReadOnly || Api is not { } api) return;
        if (!await Kit.Confirm(Root, CapabilitiesWords.DisableUnusedTitle(unused.Count, BotName), CapabilitiesWords.DisableUnusedMessage, "Turn Off")) return;
        var profile = Profile;
        Disabling = (0, unused.Count);
        SkillsNotice = null;
        Notify();
        var done = 0;
        foreach (var skill in unused)
        {
            try
            {
                await api.SetSkillAsync(skill.Name, false, profile);
                done++;
                if (profile == Profile) { Flip(skill.Name, false); Disabling = (done, unused.Count); Notify(); }
            }
            catch (Exception e)
            {
                Disabling = null;
                Fail($"Couldn’t Turn Off {skill.Name}", e);
                if (profile == Profile) await ReloadSkills();
                return;
            }
        }
        Disabling = null;
        var text = CapabilitiesWords.Updated(done);
        SkillsNotice = text;
        Notify();
        if (profile == Profile) await ReloadSkills();
        await Task.Delay(TimeSpan.FromSeconds(4));
        if (SkillsNotice == text) { SkillsNotice = null; Notify(); }
    }

    // The Skills Hub (`HubSkillsSection`)
    public List<HubSkill>? ShownHub
    {
        get
        {
            if (HubResults == null || HubQuery != Trimmed) return null;
            var offered = (Official ?? []).Select(o => o.Identifier).ToHashSet();
            return [.. HubResults.Where(h => !offered.Contains(h.Identifier))];
        }
    }

    public bool HubIsInstalled(HubSkill s) => HubInstalled.Contains(s.Identifier) || (Skills ?? []).Any(k => k.Name == s.Name);

    public async void SearchHub()
    {
        var term = Trimmed;
        if (Api is not { } api || term.Length == 0 || HubSearching) return;
        var profile = Profile;
        HubSearching = true; HubError = null;
        Notify();
        try
        {
            var found = await api.SearchHubAsync(term, profile);
            if (profile != Profile) return;
            HubResults = [.. found.Results];
            HubInstalled = [.. found.Installed];
            HubQuery = term;
        }
        catch (Exception e)
        {
            if (profile != Profile) return;
            if (e is Hermes.Core.Net.GatewayException { Code: "http", Status: 404 or 405 }) HubUnsupported = true;
            else HubError = CapabilitiesWords.Detail(e);
        }
        finally { if (profile == Profile) HubSearching = false; Notify(); }
    }

    // ---------------------------------------------------------------- Tools (§4)

    public async Task ReloadTools()
    {
        if (Api is not { } api) return;
        var profile = Profile;
        try
        {
            var list = (await Retry(() => api.ToolsetsAsync(profile))).Where(t => !Toolset.Hidden.Contains(t.Name)).ToList();
            if (profile != Profile) return;
            Toolsets = list; ToolsError = null; ToolsTooOld = false;
            Stamp("tools", profile);
        }
        catch (Exception e)
        {
            if (profile != Profile) return;
            if (CapabilitiesWords.IsNotFound(e)) { ToolsTooOld = true; Toolsets = null; Notify(); return; }
            if (Toolsets == null) ToolsError = CapabilitiesWords.Detail(e);
            Notify();
            return;
        }
        Notify();
        // Usage is best effort: a failure never shows an error; the list falls back to A–Z and "N tools".
        try { var counts = await api.ToolUsageAsync(profile); if (profile == Profile) ToolUsage = counts; }
        catch (Exception) { }
        Notify();
    }

    public ToolSort EffectiveSort => ToolUsage == null ? ToolSort.Name : Sort;

    public List<Toolset> ShownToolsets
    {
        get
        {
            var q = Trimmed;
            var list = (Toolsets ?? []).Where(t => q.Length == 0 || new[] { t.Name, t.Label, t.Description }.Concat(t.Tools)
                .Any(s => s.Contains(q, StringComparison.CurrentCultureIgnoreCase)));
            var byName = StringComparer.CurrentCultureIgnoreCase;
            long Calls(Toolset t) => CapabilitiesWords.Calls(t, ToolUsage);
            return EffectiveSort switch
            {
                ToolSort.Name => [.. list.OrderBy(t => t.Label, byName)],
                ToolSort.Most => [.. list.OrderByDescending(Calls).ThenBy(t => t.Label, byName)],
                _ => [.. list.OrderBy(Calls).ThenBy(t => t.Label, byName)],
            };
        }
    }

    public bool AllToolsOn => Toolsets is { Count: > 0 } t && t.All(x => x.Enabled);

    public async void SetToolset(Toolset set, bool enabled)
    {
        if (Api is not { } api || !ToolToggling.Add(set.Name)) return;
        var profile = Profile;
        FlipTool(set.Name, enabled);
        Notify();
        try { await api.SetToolsetAsync(set.Name, enabled, profile); }
        catch (Exception e)
        {
            if (profile == Profile) FlipTool(set.Name, !enabled);
            Fail($"Couldn’t Update {set.Label}", e);
        }
        finally { ToolToggling.Remove(set.Name); Notify(); }
    }

    private void FlipTool(string name, bool enabled)
    {
        if (Toolsets?.FindIndex(t => t.Name == name) is { } i and >= 0) Toolsets[i] = Toolsets[i] with { Enabled = enabled };
    }

    public async void SetAllTools(bool enabled)
    {
        if (Api is not { } api || ToolToggling.Count > 0) return;
        if (!enabled && !await Kit.Confirm(Root, $"Turn Off All Tools for {BotName}?", $"{BotName} won’t be able to use any tools in new chats.", "Turn Off"))
        {
            Notify();
            return;
        }
        var profile = Profile;
        var differing = (Toolsets ?? []).Where(t => t.Enabled != enabled).ToList();
        ToolToggling = [.. differing.Select(t => t.Name)];
        Notify();
        foreach (var set in differing)
        {
            try
            {
                await api.SetToolsetAsync(set.Name, enabled, profile);
                if (profile == Profile) FlipTool(set.Name, enabled);
                ToolToggling.Remove(set.Name);
                Notify();
            }
            catch (Exception e)
            {
                ToolToggling = [];
                Fail($"Couldn’t Update {set.Label}", e);
                Notify();
                return;
            }
        }
        ToolToggling = [];
        Notify();
    }

    // ---------------------------------------------------------------- Connectors (§5)

    public async Task ReloadServers()
    {
        if (Api is not { } api) return;
        var profile = Profile;
        try
        {
            var list = await Retry(() => api.ServersWithStatusAsync(profile));
            if (profile != Profile) return;
            CapabilitiesServices.Issues.Report(profile, list);
            Servers = list; ServersError = null;
            Stamp("servers", profile);
        }
        catch (Exception e)
        {
            if (profile != Profile) return;
            if (Servers == null) ServersError = CapabilitiesWords.Detail(e);
        }
        Notify();
    }

    private async Task RefreshStatus()
    {
        if (Api is not { } api || Servers is not { } list || !IsConnected) return;
        var profile = Profile;
        try
        {
            var status = await api.McpStatusAsync(profile);
            if (profile != Profile) return;
            var next = CapabilitiesApi.Fold(list, status);
            CapabilitiesServices.Issues.Report(profile, next);
            if (!next.SequenceEqual(list)) { Servers = next; Notify(); }
        }
        catch (Exception) { }
    }

    public async Task ReloadCatalog()
    {
        if (Api is not { } api) return;
        var profile = Profile;
        try
        {
            var entries = await Retry(() => api.McpCatalogAsync(profile));
            if (profile != Profile) return;
            Catalog = entries is null ? [] : McpCatalog.Ordered(entries);
            Stamp("catalog", profile);
        }
        catch (Exception) { if (profile == Profile) Catalog ??= []; }
        Notify();
    }

    public McpCatalogEntry? CatalogEntry(McpServer s) => Catalog?.FirstOrDefault(e => e.Name == s.Name);
    public string TitleOf(McpServer s) => CatalogEntry(s)?.Title ?? DisplayName.Title(s.Name);

    /// Catalog apps not on this bot yet.
    public List<McpCatalogEntry> CatalogAvailable
    {
        get
        {
            var names = (Servers ?? []).Select(s => s.Name).ToHashSet();
            return [.. (Catalog ?? []).Where(e => !e.Installed && !names.Contains(e.Name))];
        }
    }

    public List<McpServer> ShownServers => [.. (Servers ?? []).Where(s => Matches(s.Name, s.Plugin ?? "", s.Transport))];

    public async void SetMcp(McpServer server, bool enabled)
    {
        if (Api is not { } api || server.Source == "plugin" || !McpToggling.Add(server.Name)) return;
        var profile = Profile;
        if (!enabled) CapabilitiesServices.Issues.Clear(profile, server.Name);
        SetServer(server.Name, enabled);
        Notify();
        try { await api.SetMcpAsync(server.Name, enabled, profile); }
        catch (Exception e)
        {
            if (profile == Profile) SetServer(server.Name, !enabled);
            McpToggling.Remove(server.Name);
            Fail($"Couldn’t Change {server.Name}", e, () => SetMcp(server, enabled));
            Notify();
            return;
        }
        McpToggling.Remove(server.Name);
        if (profile == Profile) await ReloadServers();
    }

    private void SetServer(string name, bool enabled)
    {
        if (Servers?.FindIndex(s => s.Name == name) is { } i and >= 0) Servers[i] = Servers[i] with { Enabled = enabled };
    }

    // Managed apps (`ManagedAppsModel`)
    public async Task ReloadManaged()
    {
        if (Managed is not { } m) return;
        await m.ReloadAsync();
        Notify();
    }

    public async void ManagedConnect(string slug, bool reconnect = false, string? alias = null, string? connectionId = null)
    {
        if (Managed is not { } m || ReadOnly || !ManagedBusy.Add(slug)) return;
        var name = m.App(slug)?.Name ?? ManagedWire.Title(slug);
        ManagedNotices.Remove(slug);
        Notify();
        try
        {
            var op = await m.Api.ConnectAsync(slug, reconnect, m.Profile, alias, connectionId);
            lock (m) m.Remember(op, slug);
            if (op.Settled || op.Target(slug)?.State == ConnectionTargetState.Connected)
            {
                ManagedBusy.Remove(slug);
                await m.ReloadAccountsAndListAsync();
                Notify();
                return;
            }
            if ((op.Target(slug)?.ConnectUrl ?? op.Link) is { } link) OpenManagedLink(link, slug);
        }
        catch (Exception e)
        {
            ManagedBusy.Remove(slug);
            var failure = ConnectorFailure.From(e);
            // The link already minted is still good: open it again rather than refuse.
            if (failure.Reason == ConnectorErrorReason.LinkStillValid && m.OperationFor(slug)?.Link is { } held) { OpenManagedLink(held, slug); Notify(); return; }
            Kit.Fail(Root, $"Couldn’t Connect {name}", failure.Words($"Couldn’t start authorization for {name}."), () => ManagedConnect(slug, reconnect, alias, connectionId));
        }
        Notify();
    }

    public void OpenManagedLink(string link, string slug)
    {
        if (Kit.SafeLink(link) is not { } url || (url.Scheme != "https" && !CapabilitiesServices.LoopbackGateway))
        {
            ManagedNotices[slug] = "The sign-in link isn’t a secure web address, so it wasn’t opened.";
            return;
        }
        Kit.Open(url.ToString());
    }

    /// "Stop Waiting": the sign-in is given up on (`connection.respond {settled_by: continue}`).
    public async void ManagedStopWaiting(string slug)
    {
        if (Managed is not { } m || m.OperationFor(slug) is not { } op) return;
        m.Abandoned.Add(slug);
        ManagedBusy.Remove(slug);
        Notify();
        try { await m.Api.GiveUpAsync(op.OpId, m.Profile); } catch (Exception) { }
        await m.ReloadAccountsAndListAsync();
        Notify();
    }

    public async void ManagedSetEnabled(string slug, bool enabled)
    {
        if (Managed is not { } m || m.Policy.MemberRevision is not { } revision || !ManagedBusy.Add(slug)) return;
        var name = m.App(slug)?.Name ?? ManagedWire.Title(slug);
        Notify();
        try { await m.Api.SetEnabledAsync(slug, enabled, revision, m.Profile); }
        catch (Exception e) { Kit.Fail(Root, $"Couldn’t Change {name}", ConnectorFailure.From(e).Words("Rules cannot be changed right now.")); }
        ManagedBusy.Remove(slug);
        await m.ReloadPolicyAsync();
        await m.ReloadAccountsAndListAsync();
        Notify();
    }

    public async Task ManagedRemove(ConnectorAccountRow account)
    {
        if (Managed is not { } m || ReadOnly) return;
        var name = m.App(account.Connector)?.Name ?? ManagedWire.Title(account.Connector);
        ManagedBusy.Add(account.Connector);
        Notify();
        try { await m.Api.RemoveAsync(account.ConnectionId, m.Profile); }
        catch (Exception e)
        {
            var f = ConnectorFailure.From(e);
            if (f.Reason != ConnectorErrorReason.ConnectionNotFound)
                Kit.Fail(Root, $"Couldn’t Remove the {account.Name} Account", f.Words("That change was not saved."));
        }
        ManagedBusy.Remove(account.Connector);
        await m.ReloadAccountsAndListAsync();
        Notify();
        _ = name;
    }

    // ---------------------------------------------------------------- Plugins (§9)

    public async Task ReloadPlugins()
    {
        if (Api is not { } api) return;
        var profile = Profile;
        try
        {
            var list = await Retry(() => api.PluginsAsync(profile));
            if (profile != Profile) return;
            Plugins = list; PluginsError = null; PluginsUnavailable = false;
            Stamp("plugins", profile);
        }
        catch (Exception e)
        {
            if (profile != Profile) return;
            if (CapabilitiesWords.IsUnknownMethod(e)) { PluginsUnavailable = true; Plugins = null; }
            else if (Plugins == null) PluginsError = CapabilitiesWords.Detail(e);
        }
        Notify();
    }

    public List<PluginInfo> ShownPlugins => [.. (Plugins ?? []).Where(p => Matches(p.Name, p.Description, null))];

    public async void SetPlugin(PluginInfo plugin, bool enabled)
    {
        if (Api is not { } api || plugin.Key is not { } key || !PluginBusy.Add(plugin.Name)) return;
        var profile = Profile;
        FlipPlugin(plugin.Name, enabled);
        Notify();
        try
        {
            var result = await api.PluginAsync(new PluginAction.Toggle(key, enabled), profile);
            if (profile == Profile)
            {
                if (result.MissingEnv.Count > 0)
                {
                    PluginNotice = $"{plugin.Name} needs {string.Join(", ", result.MissingEnv)} before it can run. Add it under Settings › Keys.";
                    PluginNeedsKeys = true;
                }
                else if (result.NeedsRestart) { PluginNotice = "Restart your gateway to finish."; PluginNeedsKeys = false; }
                PluginWarnings[plugin.Name] = result.Warnings;
            }
        }
        catch (Exception e)
        {
            if (profile == Profile) FlipPlugin(plugin.Name, !enabled);
            Fail(enabled ? $"Couldn’t Turn On {plugin.Name}" : $"Couldn’t Turn Off {plugin.Name}", e);
        }
        finally { PluginBusy.Remove(plugin.Name); Notify(); }
    }

    private void FlipPlugin(string name, bool enabled)
    {
        if (Plugins?.FindIndex(p => p.Name == name) is { } i and >= 0) Plugins[i] = Plugins[i] with { Enabled = enabled };
    }

    /// The bot's plugin installed from a catalog entry (by its catalog name, else a plugin of the same name).
    public PluginInfo? InstalledPlugin(PluginCatalogEntry e) =>
        Plugins?.FirstOrDefault(p => p.CatalogName == e.Name) ?? Plugins?.FirstOrDefault(p => p.Name == e.Name);

    public List<PluginCatalogEntry> PluginCatalogAvailable
    {
        get
        {
            var installed = (Plugins ?? []).SelectMany(p => new[] { p.Name, p.CatalogName }).OfType<string>().ToHashSet();
            return [.. (CapabilitiesServices.PluginCatalog.Entries ?? []).Where(e => !installed.Contains(e.Name)).OrderByDescending(e => e.Stars ?? -1)];
        }
    }

    /// The notice on the Plugins list after an install (Install from Git and Find Plugins say the same).
    public void NoteInstalled(PluginResult result, string name)
    {
        var text = result.MissingEnv.Count > 0
            ? $"{name} is installed but needs a key before it can work: {string.Join(", ", result.MissingEnv)}. Add it now, or the plugin’s tools will fail."
            : $"Installed “{name}”." + (result.NeedsRestart ? " Restart your gateway to finish." : "");
        if (result.Warnings.Count > 0)
        {
            var lines = result.Warnings.Take(5).Select(McpEntryMask.Phone.Text).ToList();
            if (result.Warnings.Count > 5) lines.Add($"and {result.Warnings.Count - 5} more");
            text += "\n" + string.Join("\n", lines);
        }
        PluginNeedsKeys = result.MissingEnv.Count > 0;
        PluginNotice = text;
        Notify();
    }

    public void Log(string what) => AppLog.Note("capabilities", what);
}
