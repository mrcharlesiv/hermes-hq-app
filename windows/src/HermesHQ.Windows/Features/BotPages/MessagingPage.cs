using Hermes.Core.BotPages;
using HermesHQ.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Features.BotPages;

/// Messaging (App/Pages/More/Messaging/MessagingPages.swift, MessagingModel.swift): one bot's messaging apps with a
/// status line each, and a platform's page (On, Keys, Test Connection, Who Can Message This Bot, Setup Guide, the
/// restart notice). Writes are sent at once; a switch is flipped first and rolled back with an alert when refused. A
/// change the gateway does not serve hot raises the restart notice. A key's value is kept nowhere.
[Microsoft.UI.Xaml.Data.Bindable]
public sealed partial class MessagingPage : PageHost
{
    protected override Screen First(object? argument) => new MessagingModel();
}

/// The list, and the state its platform pages share.
internal sealed class MessagingModel : Screen
{
    private MessagingApi Api => new(Host.Gateway!);
    private GatewayActionsApi Actions => new(Host.Gateway!);
    private GatewayActionRun? _restart;
    internal GatewayActionRun Restart => _restart ??= MakeRestart();

    private enum Phase { Loading, Loaded, Failed }
    private Phase _phase = Phase.Loading;
    private string _failure = "";
    private bool _firstRead = true;
    internal IReadOnlyList<MessagingPlatform> Platforms { get; private set; } = [];
    internal MessagingPairing Pairing { get; private set; } = MessagingPairing.Empty;
    /// Writes on their way: "platform:<id>", "person:<id>".
    internal readonly HashSet<string> Busy = [];
    internal readonly Dictionary<string, MessagingTestResult?> Tests = [];
    internal bool RestartNeeded { get; set; }
    private string? _profile;
    private int _generation;
    private readonly PageSearchBox _search = new();

    public override string Title => MessagingWords.Title;

    internal string Profile => _profile ??= PageHost.Choices.Read("messaging", Host.Account, [.. Host.BotChoices.Select(b => b.Name)]);
    internal bool CanWrite => Host.Online;
    internal bool ShowsBotPicker => Host.BotChoices.Count > 1;
    internal bool IsUnavailable => _phase == Phase.Failed && _failure == PagesRest.OlderHermes;
    internal bool ShowsRestartNotice => RestartNeeded || Restart.Current is not GatewayActionRun.Phase.Idle;
    internal MessagingPlatform? Platform(string id) => Platforms.FirstOrDefault(p => p.Id == id);

    public MessagingModel() => _search.QueryChanged += _ => Redraw();

    private GatewayActionRun MakeRestart()
    {
        var run = new GatewayActionRun(Actions);
        run.Changed += () => Host.Ui(() => Host.Top?.Redraw());
        run.Finished += ok => Host.Ui(() => { if (ok) RestartNeeded = false; Reload(); });
        return run;
    }

    // [mac-audit] #21: no search over "Not Available on This Hermes".
    public override IEnumerable<UIElement> Bar()
    {
        _search.IsAvailable = !IsUnavailable;
        return [_search];
    }

    public override void Shown()
    {
        _search.FocusOn(Host);
        Host.OnlineChanged -= Link;
        Host.OnlineChanged += Link;
        Reload();
    }

    public override void Left() => Host.OnlineChanged -= Link;
    private void Link(bool online) { if (online) Reload(); }
    public override void Refresh() => Reload();

    internal void SetProfile(string profile)
    {
        if (profile == Profile) return;
        _profile = profile;
        PageHost.Choices.Save("messaging", Host.Account, profile);
        Platforms = [];
        Pairing = MessagingPairing.Empty;
        Tests.Clear();
        Busy.Clear();   // the last bot's writes still on their way drop their answer
        RestartNeeded = false;
        Restart.Reset();
        _phase = Phase.Loading;
        Redraw();
        Reload();
    }

    internal void Reload() { if (Host.Gateway != null) _ = Read(); }

    internal async Task Read()
    {
        var mine = ++_generation;
        var profile = Profile;
        var people = Task.Run(async () => { try { return await Api.PairingAsync(profile); } catch (Exception) { return null; } });
        try
        {
            var rows = await Api.PlatformsAsync(profile);
            var pairs = await people;
            Host.Ui(() =>
            {
                if (mine != _generation) return;
                _firstRead = false;
                Platforms = rows;
                if (pairs != null) Pairing = pairs;
                _phase = Phase.Loaded;
                if (profile == "default") MessagingRowStatus.Note(Host.Account, rows);
                Host.Top?.Redraw();
            });
        }
        catch (Exception e)
        {
            await people;
            Host.Ui(() =>
            {
                if (mine != _generation) return;
                if (_firstRead && PagesRest.IsNotAvailable(e)) { _phase = Phase.Failed; _failure = PagesRest.OlderHermes; RedrawBar(); Redraw(); return; }
                // A page that has shown data keeps showing it.
                if (Platforms.Count == 0) { _phase = Phase.Failed; _failure = PagesRest.Reason(e); Redraw(); }
            });
        }
    }

    // ------------------------------------------------------------------ writes

    internal async Task SetEnabled(string id, bool on)
    {
        if (!CanWrite || Platform(id) is not { } p || p.Enabled == on || Busy.Contains("platform:" + id)) return;
        var profile = Profile;
        Platforms = [.. Platforms.Select(x => x.Id == id ? x with { Enabled = on } : x)];
        Busy.Add("platform:" + id);
        Host.Top?.Redraw();
        try
        {
            var hot = await Api.UpdateAsync(id, MessagingBodies.Enabled(on), profile);
            Host.Ui(() => { if (profile != Profile) return; Busy.Remove("platform:" + id); if (!hot) RestartNeeded = true; Reload(); Host.Top?.Redraw(); });
        }
        catch (Exception e)
        {
            Host.Ui(() =>
            {
                if (profile != Profile) return;
                Busy.Remove("platform:" + id);
                Platforms = [.. Platforms.Select(x => x.Id == id ? x with { Enabled = !on } : x)];
                Host.Top?.Redraw();
            });
            await Kit.Failure(Root, on ? MessagingWords.TurnOnFail(p.Name) : MessagingWords.TurnOffFail(p.Name), PagesRest.Reason(e));
        }
    }

    /// `PUT {"env":{KEY:value}}`. The value is not kept: the row reads "Set" from the next read.
    internal async Task SaveKey(string platform, string key, string value)
    {
        var trimmed = value.Trim();
        if (trimmed.Length == 0) throw new PagesMessageException(MessagingWords.TypeValue);
        if (!CanWrite) throw new PagesMessageException(PagesRest.OfflineFooter);
        var hot = await Api.UpdateAsync(platform, MessagingBodies.Env(key, trimmed), Profile);
        AppLog.Note("messaging", "key saved");
        if (!hot) RestartNeeded = true;
        await Read();
    }

    /// `PUT {"clear_env":[KEY]}`.
    internal async Task RemoveKey(string platform, string key)
    {
        if (!CanWrite) throw new PagesMessageException(PagesRest.OfflineFooter);
        var hot = await Api.UpdateAsync(platform, MessagingBodies.Clear(key), Profile);
        AppLog.Note("messaging", "key removed");
        if (!hot) RestartNeeded = true;
        await Read();
    }

    internal async Task Test(string id)
    {
        if (Tests.TryGetValue(id, out var t) && t == null) return;
        Tests[id] = null;
        Host.Top?.Redraw();
        var profile = Profile;
        MessagingTestResult result;
        try { result = await Api.TestAsync(id, profile); }
        catch (Exception e) { result = new MessagingTestResult(false, PagesRest.Reason(e)); }
        Host.Ui(() => { if (profile != Profile) return; Tests[id] = result; Host.Top?.Redraw(); });
    }

    internal async Task Approve(PairingPerson person)
    {
        if (!CanWrite || person.RequestId is not { } request || Busy.Contains("person:" + person.Id)) return;
        Busy.Add("person:" + person.Id);
        Host.Top?.Redraw();
        var profile = Profile;
        try
        {
            await Api.ApproveAsync(person.Platform, request, profile);
            Host.Ui(() =>
            {
                if (profile != Profile) return;
                Busy.Remove("person:" + person.Id);
                // Moved at once; the next read confirms it.
                var approved = Pairing.Approved.Any(p => p.Id == person.Id) ? Pairing.Approved
                    : [.. Pairing.Approved, new PairingPerson(person.Platform, person.UserId, person.UserName)];
                Pairing = new MessagingPairing([.. Pairing.Pending.Where(p => p.Id != person.Id)], approved);
                Reload();
                Host.Top?.Redraw();
            });
        }
        catch (Exception e)
        {
            Host.Ui(() => { Busy.Remove("person:" + person.Id); Host.Top?.Redraw(); });
            await Kit.Failure(Root, MessagingWords.ApproveFail(person.Name), PagesRest.Reason(e));
            Reload();
        }
    }

    /// Remove asks first.
    internal async Task AskRemove(PairingPerson person)
    {
        if (!CanWrite) return;
        if (!await Kit.Confirm(Root, MessagingWords.RemoveTitle(person.Name), MessagingWords.RemoveMessage, MessagingWords.Remove)) return;
        if (Busy.Contains("person:" + person.Id)) return;
        Busy.Add("person:" + person.Id);
        Host.Top?.Redraw();
        var profile = Profile;
        try
        {
            await Api.RevokeAsync(person.Platform, person.UserId, profile);
            Host.Ui(() =>
            {
                if (profile != Profile) return;
                Busy.Remove("person:" + person.Id);
                Pairing = Pairing with { Approved = [.. Pairing.Approved.Where(p => p.Id != person.Id)] };
                Reload();
                Host.Top?.Redraw();
            });
        }
        catch (Exception e)
        {
            Host.Ui(() => { Busy.Remove("person:" + person.Id); Host.Top?.Redraw(); });
            await Kit.Failure(Root, MessagingWords.RemoveFail(person.Name), PagesRest.Reason(e));
        }
    }

    internal async Task AskRestart()
    {
        if (!CanWrite || Restart.IsBusy) return;
        var profile = Profile;
        if (!await Kit.ConfirmRestart(Root)) return;
        _ = Restart.Start(ct => Actions.RestartAsync(profile, ct));
    }

    internal TelegramSetup TelegramSetup()
    {
        var profile = Profile;
        var api = Api;
        return new TelegramSetup(new TelegramSetup.Calls(
            ct => api.TelegramStartAsync(null, profile, ct),
            (id, ct) => api.TelegramStatusAsync(id, profile, ct),
            (id, allowed, ct) => api.TelegramApplyAsync(id, allowed, profile, ct),
            id => api.TelegramCancelAsync(id, profile)));
    }

    internal void TelegramApplied(TelegramSetupApplied applied, string flowProfile)
    {
        if (flowProfile != Profile) return;
        if (applied.NeedsRestart && !applied.RestartStarted) RestartNeeded = true;
        Host.Hud(applied.RestartStarted ? MessagingWords.TelegramSaved : MessagingWords.TelegramConnected);
        Reload();
        if (applied.RestartStarted)
        {
            // The gateway restarts on its own: read again once it has had a moment.
            _ = Task.Delay(4000).ContinueWith(_ => Host.Ui(Reload));
        }
    }

    // ------------------------------------------------------------------ the list

    public override UIElement Build()
    {
        FrameworkElement Picker() => Kit.Card(Kit.BotPicker("Bot", Host.BotChoices, Profile, SetProfile));
        FrameworkElement UnderPicker(FrameworkElement state)
        {
            if (!ShowsBotPicker) return state;
            var s = new StackPanel { MaxWidth = Kit.ReadableWidth, Padding = new Thickness(20, 8, 20, 0) };
            s.Children.Add(Picker());
            s.Children.Add(state);
            return s;
        }
        switch (_phase)
        {
            case Phase.Loading: return Kit.Loading(MessagingWords.Loading, Reload);
            case Phase.Failed:
                var error = Kit.Error(MessagingWords.LoadFailTitle, _failure, Reload);
                // [mac-audit] #21: the state alone, with no Bot picker over it.
                return IsUnavailable ? error : UnderPicker(error);
        }
        var empty = Kit.State("", MessagingWords.EmptyTitle, MessagingWords.EmptyText);
        if (Platforms.Count == 0) return UnderPicker(empty);
        var scroll = Kit.Column(out var col);
        if (ShowsBotPicker) col.Children.Add(Picker());
        var rows = MessagingPlatform.Sorted(Platforms, _search.Query);
        if (rows.Count == 0) { col.Children.Add(Kit.SearchMiss(_search.Query)); return scroll; }
        // The scope: these are this bot's apps (Status & Maintenance lists the whole gateway's).
        col.Children.Add(Kit.SectionLabel(MessagingWords.For(Host.BotName(Profile))));
        col.Children.Add(Kit.Card([.. rows.Select(RowView)]));
        if (!Host.Online) col.Children.Add(Kit.Footer(PagesRest.OfflineFooter));
        return scroll;
    }

    internal static Brush ToneBrush(MessagingStatus.Tone t) => t switch
    {
        MessagingStatus.Tone.Good => Kit.Green,
        MessagingStatus.Tone.Warn => Kit.Orange,
        MessagingStatus.Tone.Bad => Kit.Red,
        _ => Kit.Secondary,
    };

    private UIElement RowView(MessagingPlatform p)
    {
        var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        line.Children.Add(new FontIcon { Glyph = p.Glyph, FontSize = 18, Width = 30, VerticalAlignment = VerticalAlignment.Center });
        var words = new StackPanel { Spacing = 3 };
        words.Children.Add(Kit.Text(p.Name));
        words.Children.Add(Kit.StatusLine(p.Status.Text, ToneBrush(p.Status.Kind), p.Status.Kind == MessagingStatus.Tone.Bad));
        line.Children.Add(words);
        var b = Kit.LinkRow(line, () => Host.Push(new MessagingPlatformScreen(this, p.Id)), name: $"{p.Name}, {p.Status.Text}");
        AutomationProperties.SetAutomationId(b, "messaging.row." + p.Id);
        return b;
    }
}

/// What the Messaging row would say when an app is failing (MessagingIssues; More's "1 Issue"). Kept for whoever draws
/// the sidebar's row counts.
public static class MessagingRowStatus
{
    private static readonly Dictionary<string, (string Text, string Spoken)?> Issues = [];
    public static event Action? Changed;

    public static (string Text, string Spoken)? For(string account) => Issues.TryGetValue(account, out var w) ? w : null;

    public static void Note(string account, IReadOnlyList<MessagingPlatform> platforms)
    {
        var words = MessagingIssues.RowWords(platforms);
        if (Issues.TryGetValue(account, out var old) && old == words) return;
        Issues[account] = words;
        Changed?.Invoke();
    }
}

/// A platform's page (MessagingPlatformView).
internal sealed class MessagingPlatformScreen(MessagingModel model, string id) : Screen
{
    private bool _advancedOpen;

    public override string Title => model.Platform(id)?.Name ?? id;
    public override void Refresh() => model.Reload();

    public override UIElement Build()
    {
        if (model.Platform(id) is not { } p) return Kit.State("", MessagingWords.NoLongerTitle, MessagingWords.NoLongerText);
        var scroll = Kit.Column(out var col);

        var about = new StackPanel { Spacing = 8 };
        if (p.Description.Length > 0) about.Children.Add(Kit.Text(p.Description, 13, Kit.Secondary));
        var status = Kit.StatusLine(p.Status.Text, MessagingModel.ToneBrush(p.Status.Kind), p.Status.Kind == MessagingStatus.Tone.Bad, 6);
        AutomationProperties.SetAutomationId(status, "messaging.platform.status");
        about.Children.Add(status);
        col.Children.Add(Kit.Card(Kit.Row(about)));

        if (p.Id == "telegram" && !p.Configured)
        {
            col.Children.Add(new Border { Height = 16 });
            var setup = Kit.Push(MessagingWords.SetUpTelegram, () => _ = TelegramSetupDialog.ShowAsync(model), accent: true);
            setup.IsEnabled = model.CanWrite;
            AutomationProperties.SetAutomationId(setup, "messaging.telegram.setup");
            col.Children.Add(setup);
            col.Children.Add(Kit.Footer(MessagingWords.SetUpTelegramFooter));
        }

        if (model.ShowsRestartNotice)
        {
            col.Children.Add(new Border { Height = 16 });
            var onlyProgress = model.Restart.Current is GatewayActionRun.Phase.Finished { Ok: true } && !model.RestartNeeded;
            col.Children.Add(Kit.RestartNotice(GatewayRestartWords.Notice, model.Restart, model.CanWrite, () => _ = model.AskRestart(), onlyProgress));
        }

        col.Children.Add(new Border { Height = 16 });
        var on = new ToggleSwitch { IsOn = p.Enabled, OnContent = "", OffContent = "", MinWidth = 0,
            IsEnabled = model.CanWrite && !model.Busy.Contains("platform:" + p.Id) };
        AutomationProperties.SetName(on, MessagingWords.On);
        AutomationProperties.SetAutomationId(on, "messaging.platform.on");
        on.Toggled += (_, _) => { if (on.IsOn != p.Enabled) _ = model.SetEnabled(p.Id, on.IsOn); };
        col.Children.Add(Kit.Card(Kit.Row(Kit.Text(MessagingWords.On), on)));
        if (!model.CanWrite) col.Children.Add(Kit.Footer(PagesRest.OfflineFooter));

        col.Children.Add(Kit.SectionLabel(MessagingWords.Keys));
        var keys = new List<UIElement>();
        if (p.Vars.Count == 0) keys.Add(Kit.Row(Kit.Text(MessagingWords.NoKeys, 14, Kit.Secondary)));
        else if (p.Keys.Count == 0) keys.Add(Kit.Row(Kit.Text(MessagingWords.AllAdvanced, 14, Kit.Secondary)));
        keys.AddRange(p.Keys.Select(k => KeyRow(k, p)));
        col.Children.Add(Kit.Card([.. keys]));
        if (p.AdvancedKeys.Count > 0)
        {
            col.Children.Add(new Border { Height = 12 });
            var expander = new Expander { Header = MessagingWords.Advanced, IsExpanded = _advancedOpen, HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Stretch };
            var inner = new StackPanel();
            foreach (var k in p.AdvancedKeys) inner.Children.Add(KeyRow(k, p));
            expander.Content = inner;
            expander.Expanding += (_, _) => _advancedOpen = true;
            expander.Collapsed += (_, _) => _advancedOpen = false;
            AutomationProperties.SetAutomationId(expander, "messaging.advanced");
            col.Children.Add(expander);
        }

        col.Children.Add(new Border { Height = 16 });
        var running = model.Tests.TryGetValue(p.Id, out var test) && test == null;
        var testRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var testButton = Kit.Push(running ? MessagingWords.Testing : MessagingWords.TestConnection, () => _ = model.Test(p.Id));
        testButton.IsEnabled = Host.Online && !running;
        AutomationProperties.SetAutomationId(testButton, "messaging.test");
        testRow.Children.Add(testButton);
        if (running) testRow.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
        col.Children.Add(testRow);
        if (test is { } result)
        {
            var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 8, 0, 0) };
            line.Children.Add(new FontIcon { Glyph = result.Ok ? "" : "", FontSize = 14, Foreground = result.Ok ? Kit.Green : Kit.Red });
            line.Children.Add(Kit.Text(result.Message, 13, result.Ok ? Kit.Green : Kit.Red));
            AutomationProperties.SetAutomationId(line, "messaging.test.result");
            col.Children.Add(line);
        }

        People(col, p);

        if (p.Guide is { } guide)
        {
            col.Children.Add(new Border { Height = 16 });
            var link = new HyperlinkButton { Content = MessagingWords.SetupGuide, NavigateUri = guide };
            AutomationProperties.SetAutomationId(link, "messaging.guide");
            col.Children.Add(Kit.Card(Kit.Row(link)));
        }
        return scroll;
    }

    private UIElement KeyRow(MessagingEnvVar key, MessagingPlatform p)
    {
        var words = new StackPanel { Spacing = 3 };
        words.Children.Add(Kit.Text(key.Label));
        if (key.Description.Length > 0) words.Children.Add(Kit.Text(key.Description, 12, Kit.Secondary));
        var g = new Grid { ColumnSpacing = 8 };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.Children.Add(words);
        var value = Kit.Text(key.Value, 13, Kit.Secondary, wrap: false);
        value.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(value, 1);
        g.Children.Add(value);
        var row = Kit.LinkRow(g, () => Host.Push(new MessagingKeyScreen(model, p.Id, key.Key)), name: $"{key.Label}, {key.Value}");
        AutomationProperties.SetAutomationId(row, "messaging.key." + key.Key);
        return row;
    }

    private void People(StackPanel col, MessagingPlatform p)
    {
        var waiting = model.Pairing.PendingFor(p.Id);
        var approved = model.Pairing.ApprovedFor(p.Id);
        col.Children.Add(Kit.SectionLabel(MessagingWords.WhoCanMessage));
        var rows = new List<UIElement>();
        if (waiting.Count == 0 && approved.Count == 0) rows.Add(Kit.Row(Kit.Text(MessagingWords.NoOne, 14, Kit.Secondary)));
        foreach (var person in waiting)
        {
            var words = new StackPanel { Spacing = 3 };
            words.Children.Add(Kit.Text(person.Name));
            words.Children.Add(Kit.Text(string.Join(" · ", new[] { MessagingWords.Waiting, person.Age }.OfType<string>()), 12, Kit.Secondary));
            var busy = model.Busy.Contains("person:" + person.Id);
            var approve = Kit.Push(busy ? MessagingWords.Approving : MessagingWords.Approve, () => _ = model.Approve(person));
            approve.IsEnabled = model.CanWrite && !busy;
            AutomationProperties.SetAutomationId(approve, "messaging.approve." + person.UserId);
            var r = Kit.Row(words, approve);
            AutomationProperties.SetAutomationId(r, "messaging.waiting." + person.UserId);
            rows.Add(r);
        }
        foreach (var person in approved)
        {
            var words = new StackPanel { Spacing = 3 };
            words.Children.Add(Kit.Text(person.Name));
            words.Children.Add(Kit.Text(MessagingWords.Approved, 12, Kit.Secondary));
            var r = Kit.Row(words, model.Busy.Contains("person:" + person.Id) ? new ProgressRing { IsActive = true, Width = 16, Height = 16 } : null);
            AutomationProperties.SetAutomationId(r, "messaging.approved." + person.UserId);
            if (model.CanWrite)
            {
                var menu = new MenuFlyout();
                var remove = new MenuFlyoutItem { Text = MessagingWords.Remove, Icon = new FontIcon { Glyph = "" } };
                remove.Click += (_, _) => _ = model.AskRemove(person);
                menu.Items.Add(remove);
                r.ContextFlyout = menu;
            }
            rows.Add(r);
        }
        col.Children.Add(Kit.Card([.. rows]));
        if (approved.Count > 0 && model.CanWrite) col.Children.Add(Kit.Footer(MessagingWords.RemoveHint));
    }
}

/// A messaging key's page (Settings › Keys' EnvKeyEditor over this platform's keys): its status, Replace / Add, Get a
/// Key, Remove Key. The typed value goes in the PUT body only and is cleared from the field once saved.
internal sealed class MessagingKeyScreen(MessagingModel model, string platformId, string keyName) : Screen
{
    private readonly TextBox _plain = new() { IsSpellCheckEnabled = false, IsTextPredictionEnabled = false };
    private readonly PasswordBox _secret = new();
    private bool _saved, _busy;
    private string? _failure;

    private MessagingEnvVar Key => model.Platform(platformId)?.Vars.FirstOrDefault(v => v.Key == keyName) ?? new MessagingEnvVar(keyName);
    private string PlatformName => model.Platform(platformId)?.Name ?? platformId;
    public override string Title => Key.Label;
    private string Typed => Key.IsPassword ? _secret.Password : _plain.Text;

    public override void Shown()
    {
        _plain.TextChanged -= OnPlainChanged;
        _plain.TextChanged += OnPlainChanged;
        _secret.PasswordChanged -= OnSecretChanged;
        _secret.PasswordChanged += OnSecretChanged;
        AutomationProperties.SetAutomationId(_plain, "env-editor.field");
        AutomationProperties.SetAutomationId(_secret, "env-editor.field");
    }

    public override void Left()
    {
        _plain.TextChanged -= OnPlainChanged;
        _secret.PasswordChanged -= OnSecretChanged;
        _plain.Text = "";
        _secret.Password = "";
    }

    private void OnPlainChanged(object sender, TextChangedEventArgs e) { if (_saved) { _saved = false; Redraw(); } }
    private void OnSecretChanged(object sender, RoutedEventArgs e) { if (_saved) { _saved = false; Redraw(); } }

    public override UIElement Build()
    {
        var key = Key;
        var scroll = Kit.Column(out var col);
        if (_failure != null)
        {
            var f = Kit.Text(_failure, 13, Kit.Red);
            col.Children.Add(Kit.Card(Kit.Row(f)));
            col.Children.Add(new Border { Height = 12 });
        }
        var head = Kit.SectionLabel(key.Key);
        head.FontFamily = Kit.Res<FontFamily>("CodeFont");
        col.Children.Add(head);
        var facts = new List<UIElement> { Kit.Fact(MessagingWords.Status, key.IsSet ? MessagingWords.SetOnGateway : MessagingWords.NotSet, copyable: false) };
        if (key.IsSet && MessagingEnvVar.Preview(key.RedactedValue) is { } preview) facts.Add(Kit.Fact(MessagingWords.Saved, preview, copyable: false));
        col.Children.Add(Kit.Card([.. facts]));

        col.Children.Add(Kit.SectionLabel(key.IsSet ? MessagingWords.Replace : MessagingWords.Add));
        Control field = key.IsPassword ? _secret : _plain;
        UiTree.DetachFromParent(field);
        if (key.IsPassword) _secret.PlaceholderText = key.IsSet ? MessagingWords.NewValue : MessagingWords.ValuePlaceholder;
        else _plain.PlaceholderText = key.IsSet ? MessagingWords.NewValue : MessagingWords.ValuePlaceholder;
        var save = Kit.Push(_saved ? MessagingWords.Saved : MessagingWords.Save, () => _ = Save());
        save.IsEnabled = !_busy && Host.Online;
        AutomationProperties.SetAutomationId(save, "env-editor.save");
        var entry = new StackPanel { Spacing = 8 };
        entry.Children.Add(field);
        entry.Children.Add(save);
        col.Children.Add(Kit.Card(Kit.Row(entry)));
        if (key.Description.Length > 0) col.Children.Add(Kit.Footer(key.Description));

        if (Uri.TryCreate(key.Url, UriKind.Absolute, out var url) && url.Scheme == "https")
        {
            col.Children.Add(new Border { Height = 12 });
            col.Children.Add(Kit.Card(Kit.Row(new HyperlinkButton { Content = MessagingWords.GetAKey, NavigateUri = url })));
        }
        if (key.IsSet)
        {
            col.Children.Add(new Border { Height = 16 });
            var remove = Kit.Push(MessagingWords.RemoveKey, () => _ = Remove(), destructive: true);
            remove.IsEnabled = !_busy && Host.Online;
            AutomationProperties.SetAutomationId(remove, "env-editor.remove");
            col.Children.Add(remove);
            col.Children.Add(Kit.Footer(MessagingWords.RemoveKeyFooter(key.Key, PlatformName)));
        }
        return scroll;
    }

    private async Task Save()
    {
        if (_busy) return;
        var value = Typed;
        if (value.Length == 0) return;
        _busy = true;
        _failure = null;
        Redraw();
        try
        {
            await model.SaveKey(platformId, keyName, value);
            Host.Ui(() => { _plain.Text = ""; _secret.Password = ""; _saved = true; });
        }
        catch (Exception e) { Host.Ui(() => _failure = PagesRest.Reason(e)); }
        Host.Ui(() => { _busy = false; Redraw(); });
    }

    private async Task Remove()
    {
        if (_busy) return;
        if (!await Kit.Confirm(Root, $"Remove {Key.Label}?", MessagingWords.RemoveKeyFooter(Key.Key, PlatformName), MessagingWords.RemoveKey)) return;
        _busy = true;
        _failure = null;
        Redraw();
        try { await model.RemoveKey(platformId, keyName); }
        catch (Exception e) { Host.Ui(() => _failure = PagesRest.Reason(e)); }
        Host.Ui(() => { _busy = false; Redraw(); });
    }
}
