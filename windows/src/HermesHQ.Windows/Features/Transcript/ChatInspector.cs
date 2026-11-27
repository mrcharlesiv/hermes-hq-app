using Hermes.Core.Activity;
using Hermes.Core.Chat;
using Hermes.Core.Model;
using Hermes.Core.Transcripts;
using HermesHQ.Controls;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Features.Transcript;

/// The inspector beside a chat (App/Mac/MacInspector.swift): Info, Steps, Files and Helpers tabs across its top; the
/// tab kept across launches. Steps lists the latest turn's steps ("3 steps", then a row each) and a step opens its
/// sheet in place, with Back; Helpers lists the turn's subagents; Files shows the chat's folder when it has one.
public sealed class ChatInspector
{
    public enum Tab { Info, Steps, Files, Helpers }
    private static readonly string[] Titles = ["Info", "Steps", "Files", "Helpers"];
    private const string TabKey = "HQMacInspectorTab";

    private readonly ChatSession _session;
    private readonly Func<ChatActivity> _activity;
    private readonly Grid _root = new();
    private readonly StackPanel _tabs = new() { Orientation = Orientation.Horizontal, Spacing = 2, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly ToggleButton[] _tabButtons = new ToggleButton[Titles.Length];
    private readonly ContentControl _page = new() { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
    private Tab _tab;
    /// The step whose sheet is open (Steps tab), by message id and call id.
    private (string Message, string Call)? _step;
    private string? _lastKey;
    private string? _filesCwd;
    private FrameworkElement? _filesView;

    public FrameworkElement View => _root;

    /// [workspace] Draws the Files tab for a chat (the Workspace feature's browser of the chat's folder); null, or no
    /// hook, keeps the Mac's "No Folder" note.
    public static Func<ChatSession, FrameworkElement?>? FilesView { get; set; }

    public ChatInspector(ChatSession session, Func<ChatActivity> activity)
    {
        _session = session;
        _activity = activity;
        _tab = Enum.TryParse<Tab>(FilePreferences.Shared.Get(TabKey), out var kept) ? kept : Tab.Info;
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        foreach (var t in Enum.GetValues<Tab>())
        {
            var button = new ToggleButton
            {
                Content = Titles[(int)t], IsChecked = t == _tab, Padding = new Thickness(12, 4, 12, 4), FontSize = 12,
                CornerRadius = new CornerRadius(6), MinWidth = 64,
            };
            var tab = t;
            button.Click += (_, _) => Show(tab);
            _tabButtons[(int)t] = button;
            _tabs.Children.Add(button);
        }
        var bar = new Border
        {
            Child = _tabs, Padding = new Thickness(10, 8, 10, 8),
            BorderBrush = Res<Brush>("CardStrokeColorDefaultBrush"), BorderThickness = new Thickness(0, 0, 0, 1),
        };
        _root.Children.Add(bar);
        Grid.SetRow(_page, 1);
        _root.Children.Add(_page);
        Refresh(force: true);
    }

    public void Show(Tab tab)
    {
        _tab = tab;
        _step = null;
        FilePreferences.Shared.Set(TabKey, tab.ToString());
        Refresh(force: true);
    }

    /// A bubble asked for one of its steps: the Steps tab, that step's sheet.
    public void ShowStep(ChatMessage message, ToolCall? call)
    {
        _tab = Tab.Steps;
        _step = call == null ? null : (message.Id, call.Id);
        Refresh(force: true);
    }

    /// Redraws the open tab (the chat changed). Skips rebuilding if the shown tab's data did not change.
    public void Refresh(bool force = false)
    {
        for (var i = 0; i < _tabButtons.Length; i++)
            _tabButtons[i].IsChecked = i == (int)_tab;

        var key = ContentFingerprint();
        if (!force && key == _lastKey && _page.Content != null) return;
        _lastKey = key;

        if (_tab == Tab.Files)
        {
            if (_filesView == null || _filesCwd != _session.Cwd)
            {
                _filesCwd = _session.Cwd;
                _filesView = FilesView?.Invoke(_session);
            }
            _page.Content = _filesView ?? Note("", "No Folder", "This chat isn’t working in a folder, so there are no files to show.");
            return;
        }

        HermesHQ.Services.UiTree.DeactivateProgressRings(_page);
        _page.Content = _tab switch
        {
            Tab.Info => Info(),
            Tab.Steps => _step is { } s && Find(s) is { } call ? StepSheet(call) : Steps(),
            _ => Helpers(),
        };
    }

    private string ContentFingerprint() => _tab switch
    {
        Tab.Info => $"info|{_session.Title}|{_session.Cwd}|{_session.StoredId}|{Features.Bots.ListsHub.Current?.Client.Rpc.State}",
        Tab.Files => $"files|{_session.Cwd}",
        Tab.Steps => _step is { } s && Find(s) is { } c
            ? $"step|{c.Id}|{(int)c.State}|{StepWords.Subtitle(c)}|{StepWords.Sections(c).Sum(sec => sec.Text.Length)}"
            : $"steps|{string.Join(",", LatestSteps.Of(_session.Messages).Select(x => $"{x.Call.Id}:{(int)x.Call.State}"))}",
        _ => $"helpers|{string.Join(",", _activity().Subagents.Select(h => $"{h.Id}:{(int)h.Status}:{h.Goal}:{SubagentWords.RowLine(h)}"))}",
    };

    private ToolCall? Find((string Message, string Call) s) =>
        _session.Messages.LastOrDefault(m => m.Id == s.Message)?.Tools.FirstOrDefault(t => t.Id == s.Call)
        ?? _session.Messages.SelectMany(m => m.Tools).LastOrDefault(t => t.Id == s.Call);

    // MARK: Info

    /// [WIN-INSPECTOR-INFO-ROWS] Chat Info in the panel (ChatInfoSheet.makeContent with `panel`, ChatSheets.swift): the
    /// face and the chat's name ("This chat" when blank), Chat Info's rows (`ChatInfoPanel.Content`, the sidebar's Chat
    /// Info rows, with the bot profile's model when the stored row names none) as an inspector's label and value with a
    /// hairline between rows (InspectorLook: 16 px margins), and Copy Chat Info under them with the sheet's text. No
    /// rows: the Mac's "No Info". Not here yet: Running Commands (`process.list`) and the pull-request rows; Windows
    /// reads neither.
    private FrameworkElement Info()
    {
        var hub = Features.Bots.ListsHub.Current;
        var bot = hub?.Bots.Bot(_session.Profile);
        var botName = Hermes.Core.Sessions.SessionRules.OwnerName(_session.Profile, hub?.Sessions.BotNames ?? new Dictionary<string, string>());
        var content = Hermes.Core.Sessions.ChatInfoPanel.Content(_session.Title, _session.Profile,
            hub?.Sessions.Row(_session.Profile, _session.StoredId), _session.StoredId, bot?.Profile.Model, botName,
            hub?.Client.Session.Address.Base.Host ?? "",
            Hermes.Core.Sessions.ChatInfoPanel.GatewayNote(hub?.Client.Rpc.State ?? Hermes.Core.Rpc.ConnectionState.Offline));
        if (content == null) return Note("\uE946", Hermes.Core.Sessions.ChatInfoPanel.EmptyTitle, Hermes.Core.Sessions.ChatInfoPanel.EmptyHint);

        const double margin = 16;
        var secondary = Res<Brush>("TextFillColorSecondaryBrush");
        var stack = new StackPanel { Padding = new Thickness(0, 0, 0, 16) };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(stack, "info.list");

        // macHeader: a 36 px face and the name beside it, in a 60 px band.
        var header = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, MinHeight = 60, Padding = new Thickness(margin, 0, 20, 0) };
        var face = new BotHead { Width = 36, Height = 36, VerticalAlignment = VerticalAlignment.Center, IsHitTestVisible = false };
        if (bot?.Model is { } model) face.Bot = model; else face.DisplayName = botName;
        header.Children.Add(face);
        var title = new TextBlock
        {
            Text = content.Name, FontWeight = FontWeights.SemiBold, MaxLines = 2, TextWrapping = TextWrapping.Wrap,
            TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(title, "info.title");
        header.Children.Add(title);
        stack.Children.Add(header);

        // The rows: the label in a narrow column (as wide as the widest label needs, the Mac's 64 px at least), the
        // value and its note beside it, a hairline from margin to margin under each row.
        var grid = new Grid { ColumnSpacing = 12, Padding = new Thickness(margin, 0, margin, 0) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto, MinWidth = 64 });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var rule = Res<Brush>("CardStrokeColorDefaultBrush");
        foreach (var r in content.Rows)
        {
            var at = grid.RowDefinitions.Count;
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var label = new TextBlock { Text = r.Label, FontSize = 13, Foreground = secondary, Margin = new Thickness(0, 9, 0, 9) };
            Grid.SetRow(label, at);
            grid.Children.Add(label);
            var value = new StackPanel { Margin = new Thickness(0, 9, 0, 9) };
            var oneWord = !r.Value.Any(c => char.IsWhiteSpace(c) || c == '/');
            var text = new TextBlock
            {
                Text = r.Value, FontSize = r.Mono ? 12 : 13, IsTextSelectionEnabled = true,
                TextWrapping = oneWord ? TextWrapping.NoWrap : TextWrapping.Wrap, TextTrimming = TextTrimming.CharacterEllipsis,
                MaxLines = oneWord ? 1 : r.Mono ? 2 : 0,
            };
            if (r.Mono) text.FontFamily = Res<FontFamily>("CodeFont");
            value.Children.Add(text);
            if (r.Note != null) value.Children.Add(new TextBlock { Text = r.Note, FontSize = 12, Foreground = secondary, TextWrapping = TextWrapping.Wrap });
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(value, "info.row." + r.Label.ToLowerInvariant().Replace(' ', '-'));
            var line = Hermes.Core.Sessions.ChatInfoRows.CopyText([r], content.Profile);
            var menu = new MenuFlyout();
            var copy = new MenuFlyoutItem { Text = "Copy", Icon = new FontIcon { Glyph = "\uE8C8" } };
            copy.Click += (_, _) => MessageView.CopyText(line);
            menu.Items.Add(copy);
            value.ContextFlyout = menu;
            Grid.SetRow(value, at);
            Grid.SetColumn(value, 1);
            grid.Children.Add(value);
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var hairline = new Border { Height = 1, Background = rule };
            Grid.SetRow(hairline, at + 1);
            Grid.SetColumnSpan(hairline, 2);
            grid.Children.Add(hairline);
        }
        stack.Children.Add(grid);

        // macFooter: Copy Chat Info at the labels' edge, 14 px under the rows.
        var all = new Button { Content = Hermes.Core.Sessions.ChatInfoRows.CopyAll, Margin = new Thickness(margin, 14, 0, 0) };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(all, "info.copy-all");
        all.Click += (_, _) => MessageView.CopyText(content.CopyText);
        stack.Children.Add(all);
        return new ScrollViewer { Content = stack };
    }

    // MARK: Steps

    private FrameworkElement Steps()
    {
        // [WIN-STEPS-AFTER-REPLY] The latest turn's (LatestSteps, the Mac's `turnSteps(endingAt: nil)`): kept after the
        // reply writes, from the stored turn the turn-end read brings; the Mac's live panel's words when it ran none.
        var steps = LatestSteps.Of(_session.Messages);
        if (steps.Count == 0) return Note("", LatestSteps.EmptyTitle, LatestSteps.EmptyHint);
        var stack = new StackPanel { Spacing = 0, Padding = new Thickness(10, 10, 10, 10) };
        stack.Children.Add(new TextBlock
        {
            Text = steps.Count == 1 ? "1 step" : $"{steps.Count} steps", FontSize = 12, Margin = new Thickness(6, 0, 0, 6),
            Foreground = Res<Brush>("TextFillColorSecondaryBrush"),
        });
        foreach (var (message, call) in steps)
        {
            var m = message;
            var c = call;
            stack.Children.Add(MessageView.StepRow(null, call, () => { _step = (m.Id, c.Id); Refresh(); }));
            stack.Children.Add(new Border { Height = 1, Margin = new Thickness(6, 0, 0, 0), Background = Res<Brush>("CardStrokeColorDefaultBrush") });
        }
        return new ScrollViewer { Content = stack };
    }

    /// The step sheet (StepSheets.swift StepDetailViewController): Back, the title ("Terminal" or the step's own),
    /// the step's words under it for a command, the subtitle, its sections (Command / Tools / Input, Output or Error,
    /// Duration), and Copy.
    private FrameworkElement StepSheet(ToolCall call)
    {
        var stack = new StackPanel { Spacing = 6, Padding = new Thickness(14, 10, 14, 16) };
        var head = new Grid();
        var back = new HyperlinkButton { Content = "‹ Back", Padding = new Thickness(0) };
        back.Click += (_, _) => { _step = null; Refresh(); };
        head.Children.Add(back);
        head.Children.Add(new TextBlock
        {
            Text = StepWords.SheetTitle(call), FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(60, 0, 60, 0),
        });
        stack.Children.Add(head);
        if (StepWords.IsTerminal(call))
            stack.Children.Add(new TextBlock
            {
                Text = RunSummary.Summarize([call], call.State == ToolState.Running), FontSize = 15, FontWeight = FontWeights.SemiBold,
                Margin = new Thickness(0, 8, 0, 0),
            });
        if (StepWords.Subtitle(call) is { } sub)
            stack.Children.Add(new TextBlock
            {
                Text = sub, FontSize = 12, TextWrapping = TextWrapping.Wrap,
                Foreground = Res<Brush>(call.State == ToolState.Failed ? "SystemFillColorCriticalBrush" : "TextFillColorSecondaryBrush"),
            });
        foreach (var (name, text, mono) in StepWords.Sections(call))
        {
            stack.Children.Add(new TextBlock { Text = name, FontSize = 12, Margin = new Thickness(0, 8, 0, 0),
                Foreground = Res<Brush>("TextFillColorSecondaryBrush") });
            var body = new TextBlock
            {
                Text = text.Length > 20_000 ? text[..20_000] : text, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true,
                FontSize = mono ? 12.5 : 14,
            };
            // Only code takes the code face: a null FontFamily throws ("'Unknown' is not a valid value"), as the slash
            // drawer's did in CI run 45020434210.
            if (mono) body.FontFamily = Res<FontFamily>("CodeFont");
            stack.Children.Add(new Border
            {
                Child = body,
                Padding = new Thickness(10, 8, 10, 8), CornerRadius = new CornerRadius(6),
                Background = Res<Brush>("SubtleFillColorSecondaryBrush"),
            });
        }
        var copy = new Button { Content = "Copy", Margin = new Thickness(0, 10, 0, 0) };
        copy.Click += (_, _) => MessageView.CopyText(StepWords.CopyText(call));
        stack.Children.Add(copy);
        return new ScrollViewer { Content = stack };
    }

    // MARK: Helpers

    private FrameworkElement Helpers()
    {
        var helpers = _activity().Subagents;
        if (helpers.Count == 0) return Note("", "No Helpers", "Helpers the bot starts for this chat show here.");
        var stack = new StackPanel { Spacing = 8, Padding = new Thickness(14, 12, 14, 12) };
        stack.Children.Add(new TextBlock { Text = SubagentWords.CountLine(helpers), FontSize = 12, Foreground = Res<Brush>("TextFillColorSecondaryBrush") });
        foreach (var child in helpers) stack.Children.Add(ActivityShelf.HelperRow(_session, child, compact: false));
        return new ScrollViewer { Content = stack };
    }

    private static FrameworkElement Note(string glyph, string title, string hint)
    {
        var stack = new StackPanel { Spacing = 6, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, Padding = new Thickness(24) };
        stack.Children.Add(new FontIcon { Glyph = glyph, FontSize = 28, Foreground = Res<Brush>("TextFillColorTertiaryBrush") });
        if (title.Length > 0) stack.Children.Add(new TextBlock { Text = title, FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center });
        stack.Children.Add(new TextBlock { Text = hint, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, FontSize = 12,
            Foreground = Res<Brush>("TextFillColorSecondaryBrush") });
        return stack;
    }

    private static T Res<T>(string key) => ThemeBrushes.Res<T>(key);
}
