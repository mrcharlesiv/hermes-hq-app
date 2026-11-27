using Hermes.Core.BotPages;
using HermesHQ.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Features.BotPages;

/// Import Sessions (App/Pages/More/ImportSessions/ImportSessionsPage.swift): Claude Code and Codex conversations found
/// on the gateway computer. The list (Import Into, the source segments, search over the loaded rows, Load More
/// Sessions) and the preview pushed from a row (the turns, Import / Open in Hermes).
[Microsoft.UI.Xaml.Data.Bindable]
public sealed partial class ImportSessionsPage : PageHost
{
    protected override Screen First(object? argument) => new ImportList();
}

internal sealed class ImportList : Screen
{
    internal const string Row = "import-sessions";
    internal ForeignSessionsStore Store { get; private set; } = null!;
    private readonly PageSearchBox _search = new(ForeignWords.SearchPrompt, 240);

    public override string Title => ForeignWords.PageTitle;

    public ImportList()
    {
        _search.QueryChanged += q => { Store.Query = q; Redraw(); };
    }

    public override IEnumerable<UIElement> Bar() => [_search];

    public override void Shown()
    {
        if (Store != null) return;
        _search.FocusOn(Host);
        var profile = PageHost.Choices.Read(Row, Host.Account, [.. Host.BotChoices.Select(b => b.Name)]);
        Store = new ForeignSessionsStore(Host.Gateway!, profile);
        Store.Changed += () => Host.Ui(Redraw);
        _ = Store.Reload();
    }

    public override void Refresh() => _ = Store.Reload(keeping: true);

    private void ChooseBot(string profile)
    {
        PageHost.Choices.Save(Row, Host.Account, profile);
        _ = Store.SetProfile(profile);
    }

    public override UIElement Build()
    {
        if (Store == null) return Kit.Loading(ForeignWords.Scanning);
        var scroll = Kit.Column(out var col);
        // The bot first, then the source and its list.
        if (Host.BotChoices.Count > 1)
            col.Children.Add(Kit.Card(Kit.BotPicker(ForeignWords.ImportInto, Host.BotChoices, Store.Profile, ChooseBot)));
        var intro = new StackPanel { Spacing = 6, Margin = new Thickness(12, 12, 12, 10) };
        intro.Children.Add(Kit.Text(ForeignWords.Subtitle, 13));
        var host = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        host.Children.Add(new FontIcon { Glyph = "", FontSize = 12, Foreground = Kit.Secondary });
        var reading = Kit.Text(ForeignWords.ReadingFrom(Store.Host), 12, Kit.Secondary);
        AutomationProperties.SetAutomationId(reading, "import-sessions.host");
        host.Children.Add(reading);
        intro.Children.Add(host);
        col.Children.Add(intro);

        // The segments span the card's width, as the Mac's segmented control.
        var segments = new Grid { ColumnSpacing = 2, Margin = new Thickness(0, 0, 0, 12) };
        AutomationProperties.SetName(segments, ForeignWords.Source);
        AutomationProperties.SetAutomationId(segments, "import-sessions.source");
        foreach (var s in Enum.GetValues<ForeignSessionsStore.SourceKind>())
        {
            var b = new Microsoft.UI.Xaml.Controls.Primitives.ToggleButton { Content = ForeignSessionsStore.SourceTitle(s), IsChecked = Store.Source == s,
                HorizontalAlignment = HorizontalAlignment.Stretch };
            b.Click += (_, _) => { b.IsChecked = true; _ = Store.SetSource(s); };
            segments.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            Grid.SetColumn(b, segments.Children.Count);
            segments.Children.Add(b);
        }
        col.Children.Add(segments);

        switch (Store.Current)
        {
            case ForeignSessionsStore.Phase.Loading:
                col.Children.Add(Kit.Loading(ForeignWords.Scanning, () => _ = Store.Reload()));
                return scroll;
            case ForeignSessionsStore.Phase.Failed f:
                var error = Kit.Error(ForeignWords.ScanErrorTitle, f.Help, () => _ = Store.Reload(), page: ForeignWords.PageTitle);
                AutomationProperties.SetHelpText(error, f.Reason);
                col.Children.Add(error);
                return scroll;
        }
        var rows = Store.Visible;
        if (rows.Count == 0)
            col.Children.Add(Kit.State(Store.Searching ? "" : "",
                Store.Searching ? ForeignWords.NoMatchesTitle : ForeignWords.EmptyTitle,
                Store.Searching ? ForeignWords.NoMatchesText : ForeignWords.EmptyText));
        else
        {
            col.Children.Add(Kit.Card([.. rows.Select(RowView)]));
            if (Store.Unreadable > 0) col.Children.Add(Kit.Footer(ForeignWords.Skipped));
        }
        if (Store.HasMore)
        {
            col.Children.Add(new Border { Height = 12 });
            var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
            line.Children.Add(Kit.Text(ForeignWords.LoadMore, 14, Kit.Accent));
            if (Store.LoadingMore) line.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
            var more = Kit.LinkRow(line, () => _ = Store.LoadMore(), chevron: false);
            more.IsEnabled = !Store.LoadingMore;
            AutomationProperties.SetAutomationId(more, "import-sessions.more");
            col.Children.Add(Kit.Card(more));
            col.Children.Add(Store.MoreError is { } reason
                ? Kit.Footer(ForeignWords.MoreFailed(reason), Kit.Red)
                : Kit.Footer(ForeignWords.LoadedCount(Store.Rows.Count)));
        }
        else if (Store.Rows.Count > 0) col.Children.Add(Kit.Footer(ForeignWords.Count(Store.Rows.Count)));
        return scroll;
    }

    private UIElement RowView(ForeignSession s)
    {
        var words = new StackPanel { Spacing = 3 };
        words.Children.Add(Kit.Text(ForeignWords.Title(s), 15, bold: true, maxLines: 3));
        var detail = ForeignWords.Detail(s, DateTimeOffset.UtcNow);
        if (Store.Source == ForeignSessionsStore.SourceKind.All && s.Label.Length > 0) detail = s.Label + " · " + detail;
        words.Children.Add(Kit.Text(detail, 13, Kit.Secondary));
        if (ForeignWords.Excerpt(s) is { } excerpt) words.Children.Add(Kit.Text(excerpt, 12, Kit.Secondary, maxLines: 2));
        var b = Kit.LinkRow(words, () => Host.Push(new ImportPreview(this, s)), name: ForeignWords.Spoken(s, DateTimeOffset.UtcNow));
        AutomationProperties.SetAutomationId(b, "import-sessions.row." + s.Id);
        return b;
    }
}

/// The preview pushed from a row (ImportPreviewModel, ImportPreviewView): the turns, and the bar's one action, Import
/// ("Importing…" while it runs) or Open in Hermes for a conversation already here.
internal sealed class ImportPreview(ImportList list, ForeignSession session) : Screen
{
    private ForeignPreview? _preview;
    private string? _failure;
    private bool _importing;
    /// The Hermes chat this conversation is (set by the preview, or by an import made here).
    private string? _importedId;
    private readonly Button _action = new() { MinWidth = 120 };
    private bool _wired;

    public override string Title => ForeignWords.Title(session);

    /// One button on the bar from the start (Import, dimmed until the preview has answered); only its words change.
    public override IEnumerable<UIElement> Bar()
    {
        if (!_wired)
        {
            _wired = true;
            _action.Style = Kit.Res<Style>("AccentButtonStyle");
            AutomationProperties.SetAutomationId(_action, "import-sessions.import");
            _action.Click += (_, _) => _ = Act();
        }
        if (_importedId != null) { _action.Content = ForeignWords.OpenInHermes; _action.IsEnabled = true; }
        else
        {
            _action.Content = _importing ? ForeignWords.Importing : ForeignWords.Import;
            _action.IsEnabled = _preview != null && !_importing && Host.Online;
        }
        return [_action];
    }

    public override void Shown() { if (_preview == null && _failure == null) _ = Load(); }
    public override void Refresh() => _ = Load();

    private async Task Load()
    {
        _failure = null;
        _preview = null;
        Redraw();
        try
        {
            var p = await list.Store.PreviewAsync(session);
            Host.Ui(() => { _importedId = p.AlreadyImported ?? _importedId; _preview = p; Redraw(); });
        }
        catch (Exception e) { Host.Ui(() => { _failure = PagesRest.Reason(e); Redraw(); }); }
    }

    private async Task Act()
    {
        var title = ForeignWords.Title(session);
        if (_importedId is { } id)
        {
            // Already in Hermes: its chat opens, with no second import.
            Navigator.Go(new ChatDestination(list.Store.Profile, id, title));
            return;
        }
        if (_importing) return;
        _importing = true;
        RedrawBar();
        try
        {
            var result = await list.Store.ImportAsync(session);
            Host.Ui(() =>
            {
                _importing = false;
                _importedId = result.SessionId;
                Redraw();
                Navigator.Go(new ChatDestination(list.Store.Profile, result.SessionId, title));
            });
        }
        catch (Exception e)
        {
            Host.Ui(() => { _importing = false; RedrawBar(); });
            await Kit.Failure(Root, ForeignWords.ImportErrorTitle, PagesRest.Reason(e), Act);
        }
    }

    public override UIElement Build()
    {
        if (_failure != null) return Kit.Error(ForeignWords.PreviewErrorTitle, $"{ForeignWords.PreviewErrorText}\n{_failure}", () => _ = Load());
        if (_preview is not { } preview) return Kit.Loading(ForeignWords.OpeningPreview);
        var scroll = Kit.Column(out var col, 760);
        col.Spacing = 14;
        var head = new StackPanel { Spacing = 6 };
        var t = Kit.Text(ForeignWords.Title(session), 20, bold: true);
        AutomationProperties.SetHeadingLevel(t, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level1);
        head.Children.Add(t);
        head.Children.Add(Kit.Text($"{session.Label} · {ForeignWords.Messages(Math.Max(preview.Total, session.TurnCount))}", 13, Kit.Secondary));
        if (_importedId != null) head.Children.Add(Notice(ForeignWords.AlreadyHere, "", "import-sessions.preview.already"));
        if (preview.Truncated) head.Children.Add(Notice(ForeignWords.PreviewLimit, "", "import-sessions.preview.shortened"));
        col.Children.Add(head);
        if (preview.Messages.Count == 0)
        {
            var e = Kit.Text(ForeignWords.EmptyPreview, 13, Kit.Secondary);
            e.HorizontalAlignment = HorizontalAlignment.Center;
            e.Margin = new Thickness(0, 24, 0, 24);
            AutomationProperties.SetAutomationId(e, "import-sessions.preview.empty");
            col.Children.Add(e);
        }
        foreach (var turn in preview.Messages) col.Children.Add(Bubble(turn));
        if (_importedId == null)
        {
            var foot = new StackPanel { Spacing = 6, Margin = new Thickness(0, 6, 0, 0) };
            var copy = Kit.Text(ForeignWords.CopyNotice, 12, Kit.Secondary);
            AutomationProperties.SetAutomationId(copy, "import-sessions.preview.footnote");
            foot.Children.Add(copy);
            if (Host.BotChoices.Count > 1) foot.Children.Add(Kit.Text(ForeignWords.ImportsInto(Host.BotName(list.Store.Profile)), 12, Kit.Secondary));
            if (!Host.Online) foot.Children.Add(Kit.Text(PagesRest.OfflineFooter, 12, Kit.Secondary));
            col.Children.Add(foot);
        }
        return scroll;
    }

    private static Border Notice(string text, string glyph, string id)
    {
        var s = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        s.Children.Add(new FontIcon { Glyph = glyph, FontSize = 12, Foreground = Kit.Secondary });
        s.Children.Add(Kit.Text(text, 12, Kit.Secondary));
        var b = new Border { Child = s, Padding = new Thickness(12), CornerRadius = new CornerRadius(12), Background = Kit.Res<Brush>("SubtleFillColorSecondaryBrush") };
        AutomationProperties.SetAutomationId(b, id);
        return b;
    }

    /// One turn as a plain bubble: yours trailing on the accent's wash, the assistant's leading on the card colour.
    private UIElement Bubble(ForeignTurn turn)
    {
        var mine = turn.IsUser;
        var s = new StackPanel { Spacing = 4, HorizontalAlignment = mine ? HorizontalAlignment.Right : HorizontalAlignment.Left,
            Margin = mine ? new Thickness(36, 0, 0, 0) : new Thickness(0, 0, 36, 0) };
        var who = Kit.Text(ForeignWords.Speaker(turn, session.Label), 11, Kit.Secondary, bold: true);
        who.Margin = new Thickness(6, 0, 6, 0);
        who.HorizontalAlignment = mine ? HorizontalAlignment.Right : HorizontalAlignment.Left;
        s.Children.Add(who);
        var text = Kit.Text(mine ? turn.Content : ForeignWords.PreviewText(turn.Content));
        text.IsTextSelectionEnabled = true;
        s.Children.Add(new Border
        {
            Child = text, Padding = new Thickness(14, 10, 14, 10), CornerRadius = new CornerRadius(18),
            Background = mine ? new SolidColorBrush(Kit.Res<Windows.UI.Color>("SystemAccentColor")) { Opacity = 0.16 } : Kit.Res<Brush>("CardBackgroundFillColorDefaultBrush"),
        });
        AutomationProperties.SetAutomationId(s, mine ? "import-sessions.turn.user" : "import-sessions.turn.assistant");
        return s;
    }
}
