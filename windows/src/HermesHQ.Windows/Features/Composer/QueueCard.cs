using Hermes.Core.Composer;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Features.Composer;

/// Messages sent while a reply runs wait in the chat's queue, shown as a card above the message box so a send never
/// seems lost (App/Chat/ChatQueueCard.swift): the header ("Queued · Sends After This Reply", "Queue Paused") with
/// Resume while paused; each row with Send Now and a ⋯ (the same menu as a click on its words): Send Now, Stop and Send,
/// Edit, Delete. The first three rows show; Show N More opens the rest.
internal sealed class QueueCard
{
    public const int ShownRows = 3;

    private readonly ComposerQueue _queue;
    private readonly Func<bool> _running;
    private readonly StackPanel _rows = new() { Spacing = 2 };
    private readonly TextBlock _header = Ui.Text("", 13, secondary: true, bold: true, wrap: false);
    private readonly Button _resume;
    private bool _expanded;

    public Border View { get; }
    /// Edit: the screen puts the row's words in the message box with the edit strip.
    public Action<string>? OnEdit { get; set; }

    public QueueCard(ComposerQueue queue, Func<bool> running)
    {
        _queue = queue;
        _running = running;
        _resume = new Button { Content = "Resume", Padding = new Thickness(10, 3, 10, 3), Visibility = Visibility.Collapsed };
        AutomationProperties.SetName(_resume, "Resume queue");
        _resume.Click += (_, _) => _queue.Resume();
        var head = new Grid { ColumnSpacing = 8 };
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _header.VerticalAlignment = VerticalAlignment.Center;
        head.Children.Add(_header);
        Grid.SetColumn(_resume, 1);
        head.Children.Add(_resume);
        var body = new StackPanel { Spacing = 4 };
        body.Children.Add(head);
        body.Children.Add(_rows);
        View = new Border
        {
            Child = body,
            Padding = new Thickness(12, 8, 6, 8),
            CornerRadius = new CornerRadius(12),
            Background = Ui.Res<Brush>("HQPromptCardBrush"),
            BorderBrush = Ui.Res<Brush>("HQPromptEdgeBrush"),
            BorderThickness = new Thickness(1),
            Visibility = Visibility.Collapsed,
        };
    }

    /// Redraws from the queue (UI thread).
    public void Update()
    {
        var items = _queue.Items;
        var running = _running();
        View.Visibility = items.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        if (items.Count == 0) { _expanded = false; return; }
        _header.Text = QueueWords.Header(items.Count, _queue.Parked, running);
        AutomationProperties.SetName(_header, QueueWords.SpokenHeader(items.Count, _queue.Parked, running));
        _resume.Visibility = QueueWords.ShowsResume(items.Count, _queue.Parked) ? Visibility.Visible : Visibility.Collapsed;
        _rows.Children.Clear();
        if (items.Count <= ShownRows) _expanded = false;
        foreach (var item in _expanded ? items : items.Take(ShownRows)) _rows.Children.Add(Row(item, running));
        if (items.Count > ShownRows)
        {
            var toggle = new HyperlinkButton { Content = _expanded ? "Show Less" : $"Show {items.Count - ShownRows} More", Padding = new Thickness(0, 4, 0, 2) };
            toggle.Click += (_, _) => { _expanded = !_expanded; Update(); };
            _rows.Children.Add(toggle);
        }
    }

    private FrameworkElement Row(QueuedMessage item, bool running)
    {
        var sending = _queue.IsSending(item.Id);
        var editing = _queue.EditingId;
        var (words, quiet) = QueueWords.RowWords(item);
        var caption = QueueWords.Caption(sending, editing == item.Id, item.AttachedLabel);
        var column = new StackPanel { Spacing = 3, VerticalAlignment = VerticalAlignment.Center };
        var text = Ui.Text(words, 14, secondary: quiet, wrap: false);
        text.MaxLines = 1;
        column.Children.Add(text);
        if (caption != null) column.Children.Add(Ui.Text(caption, 12, secondary: true, wrap: false));

        var menu = Menu(item, running, sending, editing);
        var body = Ui.Row(column, (s, _) => menu.ShowAt((FrameworkElement)s));
        AutomationProperties.SetName(body, caption == null ? words : $"{words}, {caption}");
        ToolTipService.SetToolTip(body, item.Display ?? item.Text);

        var grid = new Grid { ColumnSpacing = 2 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(body);
        if (editing == null && !sending && _queue.CanSendNow(item))
        {
            var send = new Button { Content = "Send Now", Padding = new Thickness(10, 3, 10, 3), VerticalAlignment = VerticalAlignment.Center };
            // While a reply runs, Send Now steers: the message joins that reply.
            if (running) ToolTipService.SetToolTip(send, QueueWords.SendNowSubtitle);
            send.Click += (_, _) => _ = _queue.SendNowFromCard(item.Id);
            Grid.SetColumn(send, 1);
            grid.Children.Add(send);
        }
        var more = new Button
        {
            Content = Ui.Glyph("", 14), Style = Ui.Res<Style>("QuietButtonStyle"), Flyout = menu, VerticalAlignment = VerticalAlignment.Center,
        };
        AutomationProperties.SetName(more, QueueWords.MoreLabel(words));
        Grid.SetColumn(more, 2);
        grid.Children.Add(more);
        return grid;
    }

    /// The web's menu, shared by ⋯ and the row's words.
    private MenuFlyout Menu(QueuedMessage item, bool running, bool sending, string? editing)
    {
        var menu = new MenuFlyout();
        var steers = _queue.CanSendNow(item);
        if (steers && editing == null && !sending)
        {
            var send = new MenuFlyoutItem { Text = "Send Now", Icon = Ui.Glyph("") };
            if (running) send.KeyboardAcceleratorTextOverride = QueueWords.SendNowSubtitle;
            send.Click += (_, _) => _ = _queue.SendNowFromCard(item.Id);
            menu.Items.Add(send);
        }
        if (running && editing == null && !sending)
        {
            var stop = new MenuFlyoutItem { Text = "Stop and Send", Icon = Ui.Glyph(""), KeyboardAcceleratorTextOverride = QueueWords.StopAndSendSubtitle };
            stop.Click += (_, _) => _queue.SendNow(item.Id);
            menu.Items.Add(stop);
        }
        if (_queue.CanEdit(item.Id) && editing != item.Id)
        {
            var edit = new MenuFlyoutItem { Text = "Edit", Icon = Ui.Glyph(""), IsEnabled = editing == null && !sending };
            edit.Click += (_, _) => OnEdit?.Invoke(item.Id);
            menu.Items.Add(edit);
        }
        var delete = new MenuFlyoutItem
        {
            Text = "Delete", Icon = Ui.Glyph(""), IsEnabled = !sending,
            Foreground = Ui.Res<Brush>("SystemFillColorCriticalBrush"),
        };
        delete.Click += (_, _) => _queue.Discard(item.Id);
        menu.Items.Add(delete);
        // A photo or a slash command can't join a running reply: the menu says why Send Now isn't offered.
        if (running && !steers && editing == null)
            menu.Items.Insert(0, new MenuFlyoutItem { Text = QueueWords.CannotSteer, IsEnabled = false });
        return menu;
    }
}
