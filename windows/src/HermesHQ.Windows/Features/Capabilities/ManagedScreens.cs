using Hermes.Core.Capabilities;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace HermesHQ.Features.Capabilities;

/// Connectors' Managed Apps section (App/Capabilities/Managed/ManagedAppsSections.swift): the apps a bot reaches
/// through its Nous account, or why they can't show (signed out, not turned on for the account, an older Hermes).
internal static class ManagedSection
{
    /// While Nous hasn't turned the apps on for a signed-in account, the section is one quiet line under the rest.
    public static bool IsQuiet(CapabilitiesModel m)
    {
        if (m.Managed is not { Phase: ManagedPhase.Unavailable }) return false;
        var nous = CapabilitiesServices.NousFor(m.Profile);
        return NousAccount.IsQuiet(nous.State, unavailable: true, nous.DidRead);
    }

    public static void Build(ListScreen screen, StackPanel page)
    {
        var m = screen.Model;
        if (m.Managed is not { } managed) return;
        if (IsQuiet(m)) { page.Children.Add(Kit.Section(null, [], footerElement: NousBox(screen, m, managed))); return; }
        var rows = new List<UIElement>();
        string? footer = null;
        switch (managed.Phase)
        {
            case ManagedPhase.Loading: page.Children.Add(Kit.Skeletons(2, "Managed Apps")); return;
            case ManagedPhase.SignedOut or ManagedPhase.Unavailable: rows.Add(Kit.Pad(NousBox(screen, m, managed), 10)); break;
            case ManagedPhase.TooOld:
                var w = new StackPanel { Spacing = 4 };
                w.Children.Add(Kit.Text("Managed apps need a newer Hermes.", 14, bold: true));
                w.Children.Add(Kit.Text(ConnectorFailure.TooOldWords, 13, secondary: true));
                rows.Add(Kit.Pad(w, 10));
                break;
            case ManagedPhase.Failed(var reason):
                var f = new StackPanel { Spacing = 8 };
                f.Children.Add(Kit.Text("Couldn’t reach the managed apps.", 14, bold: true));
                f.Children.Add(Kit.Text($"{reason} Your other connectors are unaffected; nothing was turned off.", 13, secondary: true));
                f.Children.Add(Kit.Button("Try Again", () => _ = m.ReloadManaged()).Also(b => b.HorizontalAlignment = HorizontalAlignment.Left));
                rows.Add(Kit.Pad(f, 10));
                break;
            default:
                var apps = managed.Apps;
                var q = m.Trimmed;
                var shown = q.Length == 0 ? ManagedJoin.Mine(apps) : [.. apps.Where(a => a.Matches(q))];
                if (q.Length == 0 && shown.Count == 0) rows.Add(Kit.Plain("No apps connected yet. Connect Gmail, GitHub, Slack and more through Nous."));
                foreach (var app in shown.Take(q.Length == 0 ? 50 : 8)) rows.Add(Row(m, app, () => screen.Push(new ManagedAppScreen(m, app.Slug))));
                if (q.Length > 0 && shown.Count == 0) rows.Add(Kit.Plain($"No managed app matches “{q}”."));
                if (apps.Count > 0)
                    rows.Add(Kit.BrowseRow(q.Length > 0 && shown.Count > 8 ? $"Show All {shown.Count} Matches" : "Browse Apps", apps.Count,
                        () => screen.Push(new ManagedCatalogScreen(m, q)), $"Browse {apps.Count} apps"));
                footer = $"Connected through {m.BotName}’s Nous account, so they follow the account, not the bot.";
                break;
        }
        page.Children.Add(Kit.Section("Managed Apps", rows, footer));
    }

    public static UIElement Row(CapabilitiesModel m, ManagedApp app, Action open, bool showDescription = false, bool connectButton = false)
    {
        var connecting = m.Managed?.Waiting(app.Slug) ?? false;
        var busy = m.ManagedBusy.Contains(app.Slug);
        UIElement sub = showDescription && app.Description.Length > 0 && app.State == ManagedState.Available
            ? Kit.Text(app.Description, 12, secondary: true).Also(t => t.MaxLines = 2)
            : Kit.StatusLine(connecting ? "Connecting" : app.StateWord, app.Tone(connecting));
        UIElement? end = null;
        if (connectButton && app.State == ManagedState.Available && !m.ReadOnly)
            end = busy ? Kit.Spinner() : Kit.RowAction("Connect", () => m.ManagedConnect(app.Slug), $"Connect {app.Name}");
        else if (busy) end = Kit.Spinner();
        return Kit.Row(app.Name, leading: Kit.Logo(app.LogoUrl, app.Name), subtitleElement: sub, trailing: end, chevron: end == null || busy, click: open, boldTitle: true);
    }

    /// The box when the apps can't show: why, and the button that fixes it when it can be fixed here.
    private static UIElement NousBox(ListScreen screen, CapabilitiesModel m, ManagedAppsState managed)
    {
        var nous = CapabilitiesServices.NousFor(m.Profile);
        var unavailable = managed.Phase is ManagedPhase.Unavailable;
        var s = new StackPanel { Spacing = 8 };
        var ui = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
        void OnNousChanged() => ui?.TryEnqueue(() => { if (!HermesHQ.Services.AppShutdown.Stopping) screen.Render(); });
        if (!nous.DidRead) _ = nous.RefreshAsync(m.Profile).ContinueWith(_ => OnNousChanged());
        nous.Changed += OnNousChanged;
        s.Unloaded += (_, _) => nous.Changed -= OnNousChanged;
        void Words(string title, string detail)
        {
            s.Children.Add(Kit.Text(title, 14, bold: true));
            if (detail.Length > 0) s.Children.Add(Kit.Text(detail, 13, secondary: true));
        }
        switch (nous.State)
        {
            case NousAccount.States.SignedIn when unavailable:
                s.Children.Add(Kit.Text(NousAccount.Words.NotTurnedOn, 12, secondary: true));
                break;
            case NousAccount.States.Waiting(var code):
                Words(NousAccount.Words.Approve, NousAccount.Words.ApproveDetail(code));
                var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
                line.Children.Add(Kit.Spinner());
                line.Children.Add(Kit.Button("Cancel", nous.Cancel));
                s.Children.Add(line);
                break;
            case NousAccount.States.Unknown when unavailable:
                s.Children.Add(Kit.Text(NousAccount.Words.NotAvailable, 12, secondary: true));
                break;
            case NousAccount.States.Starting:
                Words(NousAccount.Words.Opening, "");
                s.Children.Add(Kit.Spinner());
                break;
            default:
                Words(NousAccount.Words.SignInTitle, NousAccount.Words.SignInDetail(m.BotName));
                if (nous.State is NousAccount.States.Failed(var reason)) s.Children.Add(Kit.Text(reason, 13, color: Kit.Critical));
                if (m.ReadOnly) s.Children.Add(Kit.Text(NousAccount.Words.ReadOnly, 13, secondary: true));
                else s.Children.Add(Kit.Button(NousAccount.Words.Button, nous.Start, accent: true).Also(b => b.HorizontalAlignment = HorizontalAlignment.Stretch));
                break;
        }
        return s;
    }
}

/// A managed app's page (ManagedAppController.swift): its state, the sign-in in progress, Connect / Reconnect / Try
/// Again / Stop Waiting / Turn Back On, "Hermes can use …", the account with Disconnect, and the tools it brings.
internal sealed class ManagedAppScreen(CapabilitiesModel model, string slug) : Screen
{
    private ConnectorToolsResult? _tools;
    private string? _toolsError;
    private bool _toolsRead;
    private string _search = "";
    public override string Title => App?.Name ?? ManagedWire.Title(slug);
    private ManagedApp? App => model.Managed?.App(slug);

    public override IEnumerable<MenuFlyoutItemBase> Menu()
    {
        yield return Kit.Item("Refresh", Kit.Refresh, () => { _ = model.ReloadManaged(); _ = ReadTools(true); });
        if (App is { Connected: true } app && !model.ReadOnly) yield return Kit.Item("Disconnect…", "", () => Disconnect(app));
    }

    public override void Shown() { model.Changed += Render; if (!_toolsRead) _ = ReadTools(false); }
    public override void Hidden() => model.Changed -= Render;

    private async Task ReadTools(bool refresh)
    {
        if (model.Managed is not { } m) return;
        _toolsRead = true;
        try { _tools = await m.Api.ToolsAsync(slug, refresh, m.Profile); _toolsError = null; }
        catch (Exception e) { _toolsError = ConnectorFailure.From(e).Words("Tool list unavailable."); }
        Render();
    }

    private async void Disconnect(ManagedApp app)
    {
        if (!await Kit.Confirm(Root, $"Disconnect {app.Name}?", "Hermes stops acting as this account. You can connect again at any time.", "Disconnect", destructive: true)) return;
        foreach (var a in app.Accounts.ToList()) await model.ManagedRemove(a);
    }

    public override void Build(StackPanel page)
    {
        if (App is not { } app) { page.Children.Add(Kit.Plain("This app is no longer in the catalog.")); return; }
        var connecting = model.Managed?.Waiting(slug) ?? false;
        page.Children.Add(Kit.Header(app.Name, Kit.Logo(app.LogoUrl, app.Name, 56), (connecting ? "Connecting" : app.StateWord, app.Tone(connecting)), "Managed by Nous", app.Description));
        var op = model.Managed?.OperationFor(slug);
        var busy = model.ManagedBusy.Contains(slug);
        var rows = new List<UIElement>();
        if (connecting && op != null)
        {
            var s = new StackPanel { Spacing = 8 };
            s.Children.Add(Kit.Text("Finish the sign-in in your browser.", 14));
            var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            if (op.Link is { } link) line.Children.Add(Kit.Button("Open the Link Again", () => model.OpenManagedLink(link, slug)));
            line.Children.Add(Kit.Button("Stop Waiting", () => model.ManagedStopWaiting(slug)));
            s.Children.Add(line);
            rows.Add(Kit.Pad(s, 10));
        }
        else if (op?.Target(slug) is { State: ConnectionTargetState.Failed or ConnectionTargetState.Expired } t && op.Settled && app.State != ManagedState.Connected)
        {
            var s = new StackPanel { Spacing = 6 };
            s.Children.Add(Kit.Text(t.State == ConnectionTargetState.Expired ? "The sign-in link expired." : "The sign-in did not finish.", 14, bold: true));
            s.Children.Add(Kit.Text(t.Detail.Length == 0 ? (t.State == ConnectionTargetState.Expired ? "Links stay open for a short while. Start again to get a new one." : "Nothing was connected.") : t.Detail, 13, secondary: true));
            s.Children.Add(Kit.Button(busy ? "Starting…" : "Try Again", () => model.ManagedConnect(slug, reconnect: true), enabled: !busy).Also(b => b.HorizontalAlignment = HorizontalAlignment.Left));
            rows.Add(Kit.Pad(s, 10));
        }
        else if (app.Verb is { } verb && !model.ReadOnly && !connecting)
        {
            if (app.Reason is { } why) rows.Add(Kit.Plain(why));
            var b = new Button
            {
                Content = Kit.Text(busy && verb == ManagedVerb.Connect ? "Opening sign-in…" : ManagedApp.VerbTitle(verb), 14, bold: true),
                Style = Kit.Res<Style>("AccentButtonStyle"), HorizontalAlignment = HorizontalAlignment.Stretch, IsEnabled = !busy,
            };
            b.Click += (_, _) =>
            {
                switch (verb)
                {
                    case ManagedVerb.TurnBackOn: model.ManagedSetEnabled(slug, true); break;
                    case ManagedVerb.StopWaiting: model.ManagedStopWaiting(slug); break;
                    default: model.ManagedConnect(slug, reconnect: verb != ManagedVerb.Connect, connectionId: app.Accounts.FirstOrDefault()?.ConnectionId); break;
                }
            };
            rows.Add(Kit.Pad(b, 10));
        }
        if (model.ManagedNotices.GetValueOrDefault(slug) is { } notice) rows.Add(Kit.Notice(notice, Kit.Warning, Kit.Caution));
        if (rows.Count > 0) page.Children.Add(Kit.Section(null, rows));

        // "Hermes can use …": the member rule.
        if (app.Connected || app.State == ManagedState.Off)
        {
            var writable = !model.ReadOnly && model.Managed?.PolicyFailure == null && model.Managed?.Policy.MemberRevision != null && !app.OrgLocked;
            var footer = app.OrgLocked ? $"Your organisation turned {app.Name} off."
                : model.Managed?.PolicyFailure is { } pf ? pf.Words("Rules cannot be changed right now.")
                : model.ReadOnly ? "This gateway is read-only."
                : $"Follows the Nous account {model.BotName} is signed in with. Bots on the same account share it.";
            page.Children.Add(Kit.Section(null, [Kit.SwitchRow($"Hermes can use {app.Name}", app.Enabled && !app.OrgLocked, on => model.ManagedSetEnabled(slug, on), writable && !busy)], footer));
        }

        // The accounts.
        if (app.Accounts.Count > 0)
        {
            var acc = app.Accounts.Select(a =>
            {
                var sub = a.StatusWords is { } w ? w : a.Label != a.Name ? a.Label : null;
                UIElement? end = model.ReadOnly ? null : Kit.Button("Disconnect", async () =>
                {
                    if (await Kit.Confirm(Root, AccountWords.RemoveTitle(app.Name, a.Name), AccountWords.RemoveBody, "Remove", destructive: true)) await model.ManagedRemove(a);
                }).Also(x => x.Foreground = Kit.Critical);
                return Kit.Row(a.Name, sub, trailing: end, subtitleColor: a.NeedsReconnect ? Kit.Caution : null);
            }).ToList();
            page.Children.Add(Kit.Section(app.Accounts.Count == 1 ? "Account" : "Accounts", acc));
        }

        Tools(page, app);
    }

    private void Tools(StackPanel page, ManagedApp app)
    {
        var rows = new List<UIElement>();
        if (_tools is { } result)
        {
            var toolRowsHost = new StackPanel();
            var off = app.DisabledTools.ToHashSet();
            var locked = model.Managed?.Policy.OrgLockedTools(slug, result.Tools) ?? [];
            void FillToolRows()
            {
                toolRowsHost.Children.Clear();
                var q = _search.Trim();
                var shown = result.Tools.Where(t => !t.Deprecated && (q.Length == 0 || t.Name.Contains(q, StringComparison.OrdinalIgnoreCase) || t.Description.Contains(q, StringComparison.OrdinalIgnoreCase))).ToList();
                if (shown.Count == 0) toolRowsHost.Children.Add(Kit.Plain(result.Tools.Count == 0 ? $"{app.Name} brings no tools." : "No tool matches these filters."));
                foreach (var t in shown)
                {
                    var facet = Kit.Text(ManagedToolWords.Facet(t.Facet), 11, bold: true, color: t.Facet == "destructive" ? Kit.Critical : Kit.Secondary, wrap: false);
                    ToolTipService.SetToolTip(facet, ManagedToolWords.FacetLong(t.Facet));
                    var end = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
                    end.Children.Add(facet);
                    if (off.Contains(t.Slug) || locked.Contains(t.Slug)) end.Children.Add(Kit.Text("Off", 13, secondary: true));
                    toolRowsHost.Children.Add(Kit.Row(t.Name, t.Description, trailing: end));
                }
            }
            if (locked.Count > 0)
                rows.Add(Kit.Row($"Your organisation turned {locked.Count} tool{(locked.Count == 1 ? "" : "s")} off.", trailing: Kit.Button("Open the Connectors Admin", () => Kit.Open("https://portal.nousresearch.com/connectors"))));
            if (result.Tools.Count > 8)
            {
                var box = new TextBox { PlaceholderText = $"Search {result.Tools.Count} tools", Text = _search };
                box.TextChanged += (_, _) => { if (_search != box.Text) { _search = box.Text; FillToolRows(); } };
                rows.Add(Kit.Pad(box, 8));
            }
            FillToolRows();
            rows.Add(toolRowsHost);
        }
        else if (_toolsError is { } e) rows.Add(Kit.Plain(e));
        else rows.Add(Kit.Busy("Reading the tool list"));
        string? footer = app.State == ManagedState.Off && app.Connected ? $"Turn {app.Name} on to change its tools."
            : _tools?.Stale == true ? "Sign in to read the latest tool list." : "Nous apps follow your account, not the bot.";
        page.Children.Add(Kit.Section(app.Connected ? $"What Hermes May Do with {app.Name}" : "What Hermes Could Do Once You Connect", rows, footer));
    }
}

/// Browse Apps (ManagedCatalogController.swift): every managed app with a search and a category, connected first.
internal sealed class ManagedCatalogScreen : Screen
{
    private readonly CapabilitiesModel _m;
    private string? _category;
    public ManagedCatalogScreen(CapabilitiesModel m, string query) { _m = m; Query = query; }
    public override string Title => "Apps";
    public override string? SearchPrompt => CapabilitiesWords.SearchApps(_m.Managed?.Apps.Count ?? 0);
    public override void Shown() => _m.Changed += Render;
    public override void Hidden() => _m.Changed -= Render;

    public override IEnumerable<MenuFlyoutItemBase> Menu()
    {
        yield return Kit.CheckItem("All Categories", _category == null, () => { _category = null; Render(); });
        foreach (var c in ManagedJoin.Categories(_m.Managed?.Apps ?? []))
            yield return Kit.CheckItem(c, _category == c, () => { _category = c; Render(); });
        yield return new MenuFlyoutSeparator();
        yield return Kit.Item("Refresh", Kit.Refresh, () => _ = _m.ReloadManaged());
    }

    public override void Build(StackPanel page)
    {
        if (_m.Managed is not { } managed) return;
        if (managed.CatalogFailure is { } failure)
            page.Children.Add(Kit.Section(null, [Kit.Notice(failure.Words("The app catalog is unavailable right now. Try again later."), Kit.Warning, Kit.Caution, "Try Again", () => _ = _m.ReloadManaged())]));
        var apps = managed.Apps.Where(a => a.Matches(Query) && (_category == null || a.Category == _category)).ToList();
        if (apps.Count == 0)
        {
            page.Children.Add(Kit.Section(null, [Kit.Plain("No matching apps", secondary: false), Kit.Pad(Kit.Button("Clear the Search", () => { Query = ""; _category = null; Host.Render(this); }))]));
            return;
        }
        var mine = ManagedJoin.Mine(apps.Where(a => a.Connected));
        var available = apps.Where(a => a.State == ManagedState.Available).OrderBy(a => a.Name, StringComparer.CurrentCultureIgnoreCase).ToList();
        var off = apps.Where(a => a.State == ManagedState.Off && !a.Connected).ToList();
        if (mine.Count > 0) page.Children.Add(Kit.Section("Connected", mine.Select(a => ManagedSection.Row(_m, a, () => Push(new ManagedAppScreen(_m, a.Slug)))), "Broken connections first."));
        if (available.Count > 0) page.Children.Add(Kit.Section("Available", available.Select(a => ManagedSection.Row(_m, a, () => Push(new ManagedAppScreen(_m, a.Slug)), showDescription: true, connectButton: true))));
        if (off.Count > 0) page.Children.Add(Kit.Section("Turned Off", off.Select(a => ManagedSection.Row(_m, a, () => Push(new ManagedAppScreen(_m, a.Slug)))), "Sign-ins are kept."));
    }
}
