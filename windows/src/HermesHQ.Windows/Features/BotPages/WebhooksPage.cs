using Hermes.Core.BotPages;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Features.BotPages;

/// Webhooks (App/Pages/More/Webhooks/WebhooksPages.swift): the receiver-off card, the subscriptions with their
/// switches, a webhook's page, New Webhook and the Webhook Created sheet that shows the secret once.
[Microsoft.UI.Xaml.Data.Bindable]
public sealed partial class WebhooksPage : PageHost
{
    protected override Screen First(object? argument) => new WebhooksModel();
}

internal sealed class WebhooksModel : Screen
{
    internal WebhooksApi Api => new(Host.Gateway!);
    private GatewayActionsApi Actions => new(Host.Gateway!);
    private GatewayActionRun? _restart;
    internal GatewayActionRun Restart => _restart ??= MakeRestart();

    private enum Phase { Loading, Loaded, Failed }
    private Phase _phase = Phase.Loading;
    private string _failure = "";
    private bool _firstRead = true;
    private int _generation;
    internal bool ReceiverOn { get; private set; }
    internal IReadOnlyList<WebhookRoute> Routes { get; private set; } = [];
    internal readonly HashSet<string> Busy = [];
    internal bool Enabling { get; private set; }
    internal bool RestartNeeded { get; private set; }
    private readonly PageSearchBox _search = new();
    private readonly Button _new = new() { Content = new FontIcon { Glyph = "", FontSize = 14 } };

    public override string Title => WebhookWords.Title;
    internal bool CanWrite => Host.Online;
    /// New Webhook is offered only while the receiver is on: the gateway refuses a new route otherwise.
    internal bool CanCreate => ReceiverOn && _phase == Phase.Loaded;
    internal bool ShowsRestartNotice => RestartNeeded || Restart.Current is not GatewayActionRun.Phase.Idle;
    internal WebhookRoute? Route(string name) => Routes.FirstOrDefault(r => r.Name == name);

    public WebhooksModel()
    {
        _search.QueryChanged += _ => Redraw();
        AutomationProperties.SetName(_new, WebhookWords.NewWebhook);
        ToolTipService.SetToolTip(_new, WebhookWords.NewWebhook);
        _new.Click += (_, _) => _ = NewWebhookDialog.ShowAsync(this);
    }

    private GatewayActionRun MakeRestart()
    {
        var run = new GatewayActionRun(Actions);
        run.Changed += () => Host.Ui(() => Host.Top?.Redraw());
        run.Finished += ok => Host.Ui(() => { if (ok) RestartNeeded = false; Reload(); });
        return run;
    }

    /// The Mac keeps both on the bar, dimmed while they can't be used: + while a webhook can be made, search while
    /// there is something to search.
    public override IEnumerable<UIElement> Bar()
    {
        _new.IsEnabled = CanCreate;
        _search.IsAvailable = Routes.Count > 0;
        return [_search, _new];
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

    internal void Reload() { if (Host.Gateway != null) _ = Read(); }

    internal async Task Read()
    {
        var mine = ++_generation;
        try
        {
            var answer = await Api.ListAsync();
            Host.Ui(() =>
            {
                if (mine != _generation) return;
                _firstRead = false;
                ReceiverOn = answer.Enabled;
                // A switch on its way keeps the value the user chose until its write answers.
                Routes = [.. answer.Subscriptions.Select(r => Busy.Contains(r.Name) && Route(r.Name) is { } m ? r with { Enabled = m.Enabled } : r)];
                _phase = Phase.Loaded;
                RedrawBar();
                Host.Top?.Redraw();
            });
        }
        catch (Exception e)
        {
            Host.Ui(() =>
            {
                if (mine != _generation) return;
                if (_firstRead && PagesRest.IsNotAvailable(e)) { _phase = Phase.Failed; _failure = PagesRest.OlderHermes; }
                else if (_phase != Phase.Loaded) { _phase = Phase.Failed; _failure = PagesRest.Reason(e); }
                RedrawBar();
                Redraw();
            });
        }
    }

    internal async Task TurnOn()
    {
        if (!CanWrite || Enabling) return;
        Enabling = true;
        Redraw();
        try
        {
            var result = await Api.EnableAsync();
            await Read();
            Host.Ui(() =>
            {
                // The answer says it is on even when the next read still says off (the gateway has not restarted).
                ReceiverOn = true;
                if (result.ShowsRestartNotice) RestartNeeded = true;
                else if (result.RestartStarted)
                {
                    Host.Hud(WebhookWords.AreOn);
                    _ = Task.Delay(4000).ContinueWith(_ => Host.Ui(Reload));
                }
                RedrawBar();
            });
        }
        catch (Exception e)
        {
            await Kit.Failure(Root, WebhookWords.TurnOnFail, PagesRest.Reason(e));
        }
        Host.Ui(() => { Enabling = false; Host.Top?.Redraw(); });
    }

    internal async Task AskRestart()
    {
        if (!CanWrite || Restart.IsBusy) return;
        if (!await Kit.ConfirmRestart(Root)) return;
        _ = Restart.Start(ct => Actions.RestartAsync(null, ct));
    }

    /// The switch moves at once and goes back, with an alert, when the gateway refuses.
    internal async Task SetEnabled(string name, bool on)
    {
        if (!CanWrite || Route(name) is not { } r || r.Enabled == on || Busy.Contains(name)) return;
        Routes = [.. Routes.Select(x => x.Name == name ? x with { Enabled = on } : x)];
        Busy.Add(name);
        Host.Top?.Redraw();
        try
        {
            await Api.SetEnabledAsync(name, on);
            Host.Ui(() => { Busy.Remove(name); Host.Top?.Redraw(); });
        }
        catch (Exception e)
        {
            Host.Ui(() => { Busy.Remove(name); Routes = [.. Routes.Select(x => x.Name == name ? x with { Enabled = !on } : x)]; Host.Top?.Redraw(); });
            await Kit.Failure(Root, WebhookWords.ToggleFailure(name, on), PagesRest.Reason(e));
        }
    }

    internal void CopyUrl(WebhookRoute route)
    {
        if (route.Url.Length == 0) return;
        Kit.CopyText(route.Url);
        Host.Hud(WebhookWords.Copied);
    }

    /// Delete asks first; `then` runs once the webhook is gone.
    internal async Task AskDelete(WebhookRoute route, Action? then = null)
    {
        if (!CanWrite) return;
        if (!await Kit.Confirm(Root, WebhookWords.DeleteTitle, WebhookWords.DeleteMessage(route.Name), WebhookWords.Delete)) return;
        if (Busy.Contains(route.Name)) return;
        Busy.Add(route.Name);
        Host.Top?.Redraw();
        try
        {
            await Api.DeleteAsync(route.Name);
            Host.Ui(() =>
            {
                Busy.Remove(route.Name);
                Routes = [.. Routes.Where(r => r.Name != route.Name)];
                then?.Invoke();
                Host.Hud(WebhookWords.Deleted);
                Reload();
                Host.Top?.Redraw();
            });
        }
        catch (Exception e)
        {
            Host.Ui(() => { Busy.Remove(route.Name); Host.Top?.Redraw(); });
            await Kit.Failure(Root, WebhookWords.DeleteFail(route.Name), PagesRest.Reason(e));
        }
    }

    // ------------------------------------------------------------------ the list

    public override UIElement Build()
    {
        if (_phase == Phase.Loading) return Kit.Loading(WebhookWords.Loading, Reload);
        if (_phase == Phase.Failed) return Kit.Error(WebhookWords.LoadFailTitle, _failure, Reload);
        if (ReceiverOn && Routes.Count == 0 && !ShowsRestartNotice)
        {
            var actions = new List<Button>();
            if (CanCreate)
            {
                var b = Kit.Push(WebhookWords.NewWebhookEllipsis, () => _ = NewWebhookDialog.ShowAsync(this), accent: true);
                b.IsEnabled = Host.Online;
                AutomationProperties.SetAutomationId(b, "webhooks.empty.new");
                actions.Add(b);
            }
            return Kit.State("", WebhookWords.EmptyTitle, WebhookWords.EmptyText, [.. actions]);
        }
        var scroll = Kit.Column(out var col);
        if (!ReceiverOn)
        {
            var off = new StackPanel { Spacing = 6 };
            var head = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            head.Children.Add(new FontIcon { Glyph = "", FontSize = 14, Foreground = Kit.Orange });
            head.Children.Add(Kit.Text(WebhookWords.ReceiverOffTitle, 15, bold: true));
            off.Children.Add(head);
            off.Children.Add(Kit.Text(WebhookWords.ReceiverOffText, 13, Kit.Secondary));
            AutomationProperties.SetAutomationId(off, "webhooks.receiver-off");
            var turnOn = Kit.Push(Enabling ? WebhookWords.TurningOn : WebhookWords.TurnOn, () => _ = TurnOn(), accent: true);
            turnOn.IsEnabled = CanWrite && !Enabling;
            turnOn.HorizontalAlignment = HorizontalAlignment.Left;
            turnOn.Margin = new Thickness(0, 6, 0, 0);
            AutomationProperties.SetAutomationId(turnOn, "webhooks.turn-on");
            off.Children.Add(turnOn);
            col.Children.Add(Kit.Card(Kit.Row(off)));
            if (!Host.Online) col.Children.Add(Kit.Footer(PagesRest.OfflineFooter));
            col.Children.Add(new Border { Height = 16 });
        }
        if (ShowsRestartNotice)
        {
            var onlyProgress = Restart.Current is GatewayActionRun.Phase.Finished { Ok: true } && !RestartNeeded;
            col.Children.Add(Kit.RestartNotice(WebhookWords.RestartNotice, Restart, CanWrite, () => _ = AskRestart(), onlyProgress));
            col.Children.Add(new Border { Height = 16 });
        }
        if (ReceiverOn && Routes.Count == 0)
        {
            // Under the restart notice: the page still says there is nothing here yet.
            var s = new StackPanel { Spacing = 3 };
            s.Children.Add(Kit.Text(WebhookWords.EmptyTitle));
            s.Children.Add(Kit.Text(WebhookWords.EmptyText, 13, Kit.Secondary));
            col.Children.Add(Kit.Card(Kit.Row(s)));
        }
        if (Routes.Count > 0)
        {
            var rows = Routes.Where(r => r.Matches(_search.Query)).ToList();
            if (rows.Count == 0) { col.Children.Add(Kit.SearchMiss(_search.Query)); return scroll; }
            // The count beside the name in grey, as Jobs' section headers show theirs.
            var label = Kit.SectionLabel("");
            label.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = WebhookWords.Title + " " });
            label.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = Routes.Count.ToString(System.Globalization.CultureInfo.InvariantCulture), Foreground = Kit.Secondary, FontWeight = Microsoft.UI.Text.FontWeights.Normal });
            col.Children.Add(label);
            col.Children.Add(Kit.Card([.. rows.Select(RowView)]));
            col.Children.Add(Kit.Footer(!Host.Online ? PagesRest.OfflineFooter : WebhookWords.ListFooter));
        }
        return scroll;
    }

    private UIElement RowView(WebhookRoute route)
    {
        var words = new StackPanel { Spacing = 3 };
        words.Children.Add(Kit.Text(route.Name));
        var summary = Kit.Text(route.Summary, 13, Kit.Secondary, maxLines: 2);
        AutomationProperties.SetName(summary, route.SpokenSummary);
        words.Children.Add(summary);
        if (route.Description.Length > 0) words.Children.Add(Kit.Text(route.Description, 12, Kit.Secondary, maxLines: 2));
        // The text opens the webhook's page; the switch beside it only turns it on or off.
        var open = Kit.LinkRow(words, () => Host.Push(new WebhookDetail(this, route.Name)), name: route.Name);
        open.Padding = new Thickness(14, 8, 4, 8);
        AutomationProperties.SetHelpText(open, WebhookWords.OpensHint);
        AutomationProperties.SetAutomationId(open, "webhooks.row." + route.Name);
        var toggle = new ToggleSwitch { IsOn = route.Enabled, OnContent = "", OffContent = "", MinWidth = 0, Margin = new Thickness(0, 0, 4, 0),
            IsEnabled = CanWrite && !Busy.Contains(route.Name), VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetName(toggle, route.Name);
        AutomationProperties.SetAutomationId(toggle, "webhooks.switch." + route.Name);
        toggle.Toggled += (_, _) => { if (toggle.IsOn != route.Enabled) _ = SetEnabled(route.Name, toggle.IsOn); };
        var g = new Grid();
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.Children.Add(open);
        Grid.SetColumn(toggle, 1);
        g.Children.Add(toggle);
        var menu = new MenuFlyout();
        var copy = new MenuFlyoutItem { Text = WebhookWords.CopyUrl, Icon = new FontIcon { Glyph = "" } };
        copy.Click += (_, _) => CopyUrl(route);
        menu.Items.Add(copy);
        if (CanWrite)
        {
            var delete = new MenuFlyoutItem { Text = WebhookWords.Delete, Icon = new FontIcon { Glyph = "" } };
            delete.Click += (_, _) => _ = AskDelete(route);
            menu.Items.Add(delete);
        }
        g.ContextFlyout = menu;
        return g;
    }
}

/// A webhook's page (WebhookDetailView).
internal sealed class WebhookDetail(WebhooksModel model, string name) : Screen
{
    public override string Title => name;
    public override void Refresh() => model.Reload();

    public override UIElement Build()
    {
        if (model.Route(name) is not { } route) return Kit.State("", WebhookWords.RemovedTitle, WebhookWords.RemovedText);
        var scroll = Kit.Column(out var col);
        var on = new ToggleSwitch { IsOn = route.Enabled, OnContent = "", OffContent = "", MinWidth = 0, IsEnabled = model.CanWrite && !model.Busy.Contains(name) };
        AutomationProperties.SetName(on, "On");
        AutomationProperties.SetAutomationId(on, "webhooks.detail.on");
        on.Toggled += (_, _) => { if (on.IsOn != route.Enabled) _ = model.SetEnabled(name, on.IsOn); };
        col.Children.Add(Kit.Card(Kit.Row(Kit.Text("On"), on)));
        col.Children.Add(Kit.Footer(!model.CanWrite ? PagesRest.OfflineFooter : WebhookWords.OffRejects));

        col.Children.Add(Kit.SectionLabel(WebhookWords.Url));
        var url = Kit.Mono(route.Url.Length == 0 ? WebhookWords.NotKnown : route.Url);
        AutomationProperties.SetAutomationId(url, "webhooks.detail.url");
        Button? copy = null;
        if (route.Url.Length > 0)
        {
            copy = Kit.Push(WebhookWords.Copy, () => model.CopyUrl(route));
            AutomationProperties.SetName(copy, WebhookWords.CopyUrl);
            AutomationProperties.SetAutomationId(copy, "webhooks.detail.copy");
        }
        col.Children.Add(Kit.Card(Kit.Row(url, copy)));

        col.Children.Add(new Border { Height = 16 });
        var facts = new List<UIElement>
        {
            Kit.Fact("Events", route.EventList.Count == 0 ? "All Events" : string.Join(", ", route.EventList)),
            Kit.Fact("Deliver To", WebhookDeliver.Label(route.Deliver)),
        };
        if (route.DeliverOnly) facts.Add(Kit.Fact("Deliver Payload Only", "Yes"));
        if (route.SkillList.Count > 0) facts.Add(Kit.Fact("Skills", string.Join(", ", route.SkillList)));
        facts.Add(Kit.Fact("Secret", route.SecretSet ? "Set" : "Not Set"));
        if (route.CreatedAt is { } created) facts.Add(Kit.Fact("Created", created.ToLocalTime().ToString("MMM d, yyyy 'at' h:mm tt", System.Globalization.CultureInfo.CurrentCulture)));
        col.Children.Add(Kit.Card([.. facts]));

        if (route.Description.Length > 0)
        {
            col.Children.Add(Kit.SectionLabel("Description"));
            col.Children.Add(Kit.Card(Kit.Row(Kit.Text(route.Description))));
        }
        if (route.Prompt.Length > 0)
        {
            col.Children.Add(Kit.SectionLabel("Prompt"));
            var p = Kit.Text(route.Prompt);
            p.IsTextSelectionEnabled = true;
            col.Children.Add(Kit.Card(Kit.Row(p)));
        }
        col.Children.Add(new Border { Height = 20 });
        var busy = model.Busy.Contains(name);
        var delete = Kit.Push(busy ? WebhookWords.Deleting : WebhookWords.DeleteWebhook,
            () => _ = model.AskDelete(route, () => Host.PopTo(model)), destructive: true);
        delete.IsEnabled = model.CanWrite && !busy;
        AutomationProperties.SetAutomationId(delete, "webhooks.detail.delete");
        col.Children.Add(delete);
        return scroll;
    }
}

/// New Webhook, then Webhook Created (WebhookFormView, WebhookCreatedView). The secret is held by the second dialog
/// alone: not stored, not logged.
internal static class NewWebhookDialog
{
    private static bool _open;

    public static async Task ShowAsync(WebhooksModel model)
    {
        if (_open || !model.CanCreate) return;
        _open = true;
        try { await Run(model); }
        finally { _open = false; }
    }

    private static async Task Run(WebhooksModel model)
    {
        var root = model.Host.XamlRoot;
        var name = new TextBox { PlaceholderText = WebhookWords.NamePlaceholder, IsSpellCheckEnabled = false };
        var description = new TextBox { PlaceholderText = WebhookWords.DescriptionPlaceholder, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 100 };
        var events = new TextBox { PlaceholderText = WebhookWords.EventsPlaceholder, IsSpellCheckEnabled = false };
        var skills = new TextBox { PlaceholderText = WebhookWords.SkillsPlaceholder, IsSpellCheckEnabled = false };
        var deliver = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch };
        foreach (var o in WebhookDeliver.Options) deliver.Items.Add(new ComboBoxItem { Content = WebhookDeliver.Label(o), Tag = o });
        deliver.SelectedIndex = 0;
        var chatId = new TextBox { PlaceholderText = WebhookWords.ChatId, IsSpellCheckEnabled = false };
        var deliverOnly = new ToggleSwitch { OnContent = "", OffContent = "", MinWidth = 0 };
        AutomationProperties.SetName(deliverOnly, WebhookWords.DeliverOnly);
        var prompt = new TextBox { PlaceholderText = WebhookWords.PromptPlaceholder, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 72, MaxHeight = 200 };
        AutomationProperties.SetAutomationId(name, "webhooks.new.name");
        AutomationProperties.SetAutomationId(deliver, "webhooks.new.deliver");
        var nameRule = Kit.Footer(WebhookWords.NameRule, Kit.Red);
        var deliverFooter = Kit.Footer("");
        var failure = Kit.Text("", 13, Kit.Red);
        var failureCard = Kit.Card(Kit.Row(failure));
        AutomationProperties.SetAutomationId(failureCard, "webhooks.new.failure");
        var chatRow = Kit.Row(chatId);

        var form = new StackPanel { Width = 440 };
        form.Children.Add(failureCard);
        form.Children.Add(Kit.SectionLabel(WebhookWords.NameHeader)); form.Children.Add(name); form.Children.Add(nameRule);
        form.Children.Add(Kit.SectionLabel(WebhookWords.DescriptionHeader)); form.Children.Add(description);
        form.Children.Add(Kit.SectionLabel(WebhookWords.EventsHeader)); form.Children.Add(events);
        form.Children.Add(Kit.SectionLabel(WebhookWords.SkillsHeader)); form.Children.Add(skills);
        form.Children.Add(new Border { Height = 12 });
        form.Children.Add(Kit.Card(Kit.Row(Kit.Text(WebhookWords.DeliverTo), deliver), chatRow, Kit.Row(Kit.Text(WebhookWords.DeliverOnly), deliverOnly)));
        form.Children.Add(deliverFooter);
        form.Children.Add(Kit.SectionLabel(WebhookWords.PromptHeader)); form.Children.Add(prompt);

        var dialog = new ContentDialog
        {
            Title = WebhookWords.NewWebhook, Content = new ScrollViewer { Content = form, MaxHeight = 560 },
            PrimaryButtonText = WebhookWords.Create, CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary,
        };
        var creating = false;
        string? failed = null;

        WebhookForm Form() => new()
        {
            Name = name.Text, Description = description.Text, Events = events.Text, Skills = skills.Text,
            Deliver = (deliver.SelectedItem as ComboBoxItem)?.Tag as string ?? "log", DeliverChatId = chatId.Text,
            DeliverOnly = deliverOnly.IsOn, Prompt = prompt.Text,
        };

        void Refresh()
        {
            var f = Form();
            nameRule.Visibility = name.Text.Trim().Length > 0 && !f.NameIsValid ? Visibility.Visible : Visibility.Collapsed;
            chatRow.Visibility = WebhookDeliver.IsChat(f.Deliver) ? Visibility.Visible : Visibility.Collapsed;
            if (!f.CanDeliverOnly && deliverOnly.IsOn) deliverOnly.IsOn = false;
            deliverOnly.IsEnabled = f.CanDeliverOnly;
            deliverFooter.Text = f.CanDeliverOnly ? WebhookWords.DeliverOnlyOn : WebhookWords.DeliverOnlyOff;
            failure.Text = failed ?? "";
            failureCard.Visibility = failed != null ? Visibility.Visible : Visibility.Collapsed;
            dialog.IsPrimaryButtonEnabled = !creating && f.CanCreate && model.Host.Online;
            dialog.PrimaryButtonText = creating ? WebhookWords.Creating : WebhookWords.Create;
        }
        void Changed() { failed = null; Refresh(); }
        foreach (var t in new[] { name, description, events, skills, chatId, prompt }) t.TextChanged += (_, _) => Changed();
        deliver.SelectionChanged += (_, _) => Changed();
        deliverOnly.Toggled += (_, _) => Changed();
        name.Loaded += (_, _) => name.Focus(FocusState.Programmatic);
        Refresh();

        WebhookCreated? created = null;
        dialog.PrimaryButtonClick += async (_, e) =>
        {
            var deferral = e.GetDeferral();
            e.Cancel = true;
            creating = true;
            failed = null;
            form.IsHitTestVisible = false;
            Refresh();
            try
            {
                created = await model.Api.CreateAsync(Form());
                e.Cancel = false;
            }
            catch (Exception x) { failed = WebhookWords.CreateFailure(x); }
            creating = false;
            form.IsHitTestVisible = true;
            Refresh();
            deferral.Complete();
        };
        dialog.Closing += (_, e) => { if (creating && e.Result != ContentDialogResult.Primary) e.Cancel = true; };
        await Kit.Show(root, dialog);
        if (created is not { } made) return;
        model.Reload();
        await ShowCreated(root, made);
    }

    /// The one time the secret is shown.
    private static async Task ShowCreated(XamlRoot? root, WebhookCreated created)
    {
        var body = new StackPanel { Width = 440 };
        var hint = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        hint.Children.Add(new FontIcon { Glyph = "", FontSize = 14, Foreground = Kit.Orange });
        hint.Children.Add(Kit.Text(WebhookWords.CopyNow));
        AutomationProperties.SetAutomationId(hint, "webhooks.created.hint");
        body.Children.Add(Kit.Card(Kit.Row(hint)));
        UIElement Copyable(string value, string what)
        {
            var text = Kit.Mono(value);
            AutomationProperties.SetAutomationId(text, "webhooks.created." + what);
            var button = new Button { Content = WebhookWords.Copy };
            AutomationProperties.SetName(button, what == "url" ? "Copy URL" : "Copy Secret");
            AutomationProperties.SetAutomationId(button, "webhooks.created.copy-" + what);
            button.Click += (_, _) => { Kit.CopyText(value); button.Content = WebhookWords.Copied; };
            return Kit.Card(Kit.Row(text, button));
        }
        if (created.Url.Length > 0)
        {
            body.Children.Add(Kit.SectionLabel(WebhookWords.Url));
            body.Children.Add(Copyable(created.Url, "url"));
        }
        body.Children.Add(Kit.SectionLabel(WebhookWords.Secret));
        body.Children.Add(created.Secret.Length == 0 ? Kit.Card(Kit.Row(Kit.Text(WebhookWords.NoSecret, 14, Kit.Secondary))) : Copyable(created.Secret, "secret"));
        var done = new ContentDialog
        {
            Title = WebhookWords.CreatedTitle, Content = body, PrimaryButtonText = WebhookWords.Done, DefaultButton = ContentDialogButton.Primary,
        };
        // The secret lives in this dialog alone: it can't be dismissed by accident (Esc), only with Done.
        done.Closing += (_, e) => { if (e.Result != ContentDialogResult.Primary) e.Cancel = true; };
        await Kit.Show(root, done);
    }
}
