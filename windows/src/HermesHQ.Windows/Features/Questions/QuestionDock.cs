using Hermes.Core.Questions;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using VirtualKey = Windows.System.VirtualKey;
using static HermesHQ.Features.Questions.QuestionUi;

namespace HermesHQ.Features.Questions;

internal enum DockSending { None, Send, Skip }

/// The question dock in the message box's place (spec 1x §4.3; Mac: App/Questions/QuestionDockView.swift): one page per
/// question. Its head says "Question 2 of 3" (bars for 2–6 questions), with Minimize and Skip / Skip All; the page has
/// the question, the choices (a round mark for pick-one, a rounded square for pick-any, "Recommended" as a tag) and
/// "Something else…", or a field for an open question; its foot has Back and Next / Send. A pick-one tap moves on by
/// itself after 0.22 s. Enter is Next / Send, Escape leaves a field, then skips (Mac polish #7).
internal sealed class QuestionDock
{
    private readonly ContentControl _page = new() { IsTabStop = false, HorizontalContentAlignment = HorizontalAlignment.Stretch };
    private readonly TextBlock _step = new() { FontSize = 12.5, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center };
    private readonly StackPanel _bars = new() { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
    private readonly Button _skip;
    private readonly Button _minimize;
    private readonly Button _back;
    private readonly Button _primary;
    private readonly Grid _foot;
    private readonly DispatcherQueue _ui;
    private DispatcherQueueTimer? _advance;
    private TextBox? _field;
    private DockSending _sending;

    public ClarifyPrompt Prompt { get; }
    public ClarifyDraft Draft { get; private set; }
    public Border View { get; }

    public Action<QuestionDock>? OnSend, OnSkip, OnMinimize, OnDraftChanged;

    /// [questions] Answer Now's dock (a settled card's unanswered questions, or a live one kept after it ended unsent):
    /// its Skip reads Cancel, and Send puts the answers in the chat (QuestionsChat.SendLater).
    public bool Later { get; }

    public QuestionDock(ClarifyPrompt prompt, ClarifyDraft draft, DispatcherQueue ui, bool later = false)
    {
        Prompt = prompt;
        Draft = draft;
        _ui = ui;
        Later = later;
        var count = prompt.Questions.Count;

        _skip = new Button
        {
            Content = later ? "Cancel" : count > 1 ? "Skip All" : "Skip", Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0), Foreground = Brush("AccentTextFillColorPrimaryBrush"), Padding = new Thickness(12, 6, 4, 6),
        };
        if (count > 1 && !later) Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_skip, "Skip All Questions");
        _skip.Click += (_, _) => OnSkip?.Invoke(this);
        _minimize = new Button
        {
            Content = new FontIcon { Glyph = "", FontSize = 13 }, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0), Foreground = Brush("AccentTextFillColorPrimaryBrush"), Padding = new Thickness(10, 8, 10, 8),
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_minimize, "Minimize question");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetHelpText(_minimize, "Keeps your answers so you can read the conversation.");
        ToolTipService.SetToolTip(_minimize, "Minimize question");
        _minimize.Click += (_, _) => { CancelAdvance(); OnMinimize?.Invoke(this); };

        var head = new Grid { MinHeight = 36 };
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var left = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        left.Children.Add(_bars);
        left.Children.Add(_step);
        head.Children.Add(left);
        var right = new StackPanel { Orientation = Orientation.Horizontal };
        right.Children.Add(_minimize);
        right.Children.Add(_skip);
        Grid.SetColumn(right, 1);
        head.Children.Add(right);

        _back = new Button
        {
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0),
            Foreground = Brush("AccentTextFillColorPrimaryBrush"), Padding = new Thickness(0, 6, 12, 6),
        };
        var backContent = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        backContent.Children.Add(new FontIcon { Glyph = "", FontSize = 12 });
        backContent.Children.Add(new TextBlock { Text = "Back" });
        _back.Content = backContent;
        _back.Click += (_, _) => Go(-1);
        _primary = new Button
        {
            Style = Res<Style>("AccentButtonStyle"), CornerRadius = new CornerRadius(18), MinWidth = 96, MinHeight = 36,
            Padding = new Thickness(22, 6, 22, 6), FontWeight = FontWeights.SemiBold,
        };
        _primary.Click += (_, _) => PrimaryTapped();
        _foot = new Grid { Margin = new Thickness(0, 14, 0, 0) };
        _foot.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _foot.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _foot.Children.Add(_back);
        Grid.SetColumn(_primary, 1);
        _foot.Children.Add(_primary);

        var stack = new StackPanel();
        stack.Children.Add(head);
        stack.Children.Add(new ScrollViewer
        {
            Content = _page, MaxHeight = 420, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        });
        stack.Children.Add(_foot);
        View = new Border
        {
            Child = stack, CornerRadius = new CornerRadius(14), Padding = new Thickness(16, 6, 16, 12),
            Background = Brush("SolidBackgroundFillColorTertiaryBrush"), BorderBrush = Brush("CardStrokeColorDefaultBrush"),
            BorderThickness = new Thickness(1),
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(View,
            count > 1 ? $"Questions, {draft.Page + 1} of {count}" : "Question");
        View.PreviewKeyDown += OnKey;
        RenderPage();
    }

    public DockSending Sending
    {
        get => _sending;
        set { _sending = value; RenderPage(); }
    }

    public bool IsTyping => _field != null && _field.FocusState != FocusState.Unfocused;

    private ClarifyQuestion Current => Prompt.Questions[Math.Clamp(Draft.Page, 0, Prompt.Questions.Count - 1)];
    private bool IsLastPage => Draft.Page >= Prompt.Questions.Count - 1;
    private ClarifyStage Stage(string qid) => Draft.Stages.GetValueOrDefault(qid) ?? ClarifyStage.Empty;

    /// What Send sends: each question's staged answer (null = none), in order.
    public IReadOnlyList<(string Qid, string? Answer)> Answers =>
        Prompt.Questions.Select(q => (q.Qid, ClarifyStaging.StagedAnswer(q, Stage(q.Qid)))).ToList();

    public int AnsweredCount => Answers.Count(a => a.Answer != null);

    public void SetMinimized(bool minimized)
    {
        Draft = Draft with { Minimized = minimized };
        OnDraftChanged?.Invoke(this);
    }

    /// A reconnect's replay brought locks the gateway already holds: they fill the questions not touched here.
    public bool MergeReplayed(IReadOnlyDictionary<string, string?> locked)
    {
        var stages = Draft.Stages.ToDictionary(kv => kv.Key, kv => kv.Value);
        var any = false;
        foreach (var q in Prompt.Questions)
        {
            if (stages.ContainsKey(q.Qid)) continue;
            if (ClarifyStaging.Replay(q, locked.TryGetValue(q.Qid, out var a), a) is { } stage) { stages[q.Qid] = stage; any = true; }
        }
        if (!any) return false;
        Draft = Draft with { Stages = stages };
        RenderPage();
        return true;
    }

    /// Focuses the shown page's field, or the dock itself (the keys come here, as the Mac's takeKeys).
    public void TakeKeys()
    {
        _ui.TryEnqueue(DispatcherQueuePriority.Low, () =>
        {
            if (_field != null) _field.Focus(FocusState.Programmatic);
            else (_primary.Visibility == Visibility.Visible && _primary.IsEnabled ? _primary : _skip).Focus(FocusState.Programmatic);
        });
    }

    // ------------------------------------------------------------------ the page

    private void RenderPage()
    {
        var q = Current;
        var count = Prompt.Questions.Count;
        var stage = Stage(q.Qid);
        var locked = _sending != DockSending.None;
        var refocus = IsTyping;

        var page = new StackPanel();
        var question = new TextBlock
        {
            Text = q.Question, FontSize = 15, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
        };
        page.Children.Add(question);
        if (q.MultiSelect)
        {
            var hint = Text("Choose any that apply.", 12, "TextFillColorSecondaryBrush");
            hint.Margin = new Thickness(0, 4, 0, 0);
            page.Children.Add(hint);
        }
        _field = null;
        if (q.Choices is { Count: > 0 } choices)
        {
            var list = new StackPanel { Margin = new Thickness(0, 10, 0, 0) };
            foreach (var choice in choices)
            {
                list.Children.Add(Hairline());
                list.Children.Add(ChoiceRow(q, choice, stage.Choices.Contains(choice), locked));
            }
            list.Children.Add(Hairline());
            if (stage.Other)
            {
                var field = Field("Something else", stage.Draft, locked);
                field.Margin = new Thickness(0, 8, 0, 0);
                field.TextChanged += (_, _) => SetStage(q.Qid, Stage(q.Qid) with { Draft = field.Text }, rerender: false);
                list.Children.Add(field);
                _field = field;
            }
            else
            {
                var other = new Button
                {
                    Content = Text("Something else…", 14, "TextFillColorSecondaryBrush"), HorizontalAlignment = HorizontalAlignment.Stretch,
                    HorizontalContentAlignment = HorizontalAlignment.Left, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
                    BorderThickness = new Thickness(0), Padding = new Thickness(34, 12, 0, 12), IsEnabled = !locked,
                };
                other.Click += (_, _) =>
                {
                    CancelAdvance();
                    SetStage(q.Qid, ClarifyStaging.OpenOther(q, Stage(q.Qid)), rerender: true);
                    _field?.Focus(FocusState.Programmatic);
                };
                list.Children.Add(other);
            }
            page.Children.Add(list);
        }
        else
        {
            var field = Field("Type your answer…", stage.Draft, locked);
            field.Margin = new Thickness(0, 14, 0, 0);
            field.MinHeight = 44;
            field.MaxHeight = 132;
            field.TextChanged += (_, _) => SetStage(q.Qid, Stage(q.Qid) with { Draft = field.Text }, rerender: false);
            page.Children.Add(field);
            _field = field;
        }
        _page.Content = page;

        // The head: "Question 2 of 3" (bars for 2–6 questions; the words are then "2 of 3"), or "Question".
        _bars.Children.Clear();
        var bars = count is >= 2 and <= 6;
        if (bars)
            for (var i = 0; i < count; i++)
                _bars.Children.Add(new Border
                {
                    Width = 16, Height = 4, CornerRadius = new CornerRadius(2),
                    Background = Brush(i == Draft.Page ? "AccentFillColorDefaultBrush" : "ControlStrongFillColorDisabledBrush"),
                });
        _bars.Visibility = bars ? Visibility.Visible : Visibility.Collapsed;
        _step.Text = count > 1 ? (bars ? $"{Draft.Page + 1} of {count}" : $"Question {Draft.Page + 1} of {count}") : "Question";
        _step.Foreground = Brush("TextFillColorSecondaryBrush");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_step, count > 1 ? $"Question {Draft.Page + 1} of {count}" : "Question");
        _skip.IsEnabled = !locked;
        _minimize.IsEnabled = !locked;
        UpdateFoot();
        if (refocus && _field != null) _field.Focus(FocusState.Programmatic);
    }

    private void UpdateFoot()
    {
        var q = Current;
        var stage = Stage(q.Qid);
        var locked = _sending != DockSending.None;
        _back.Visibility = Draft.Page > 0 ? Visibility.Visible : Visibility.Collapsed;
        _back.IsEnabled = !locked;
        if (IsLastPage)
        {
            _primary.Content = _sending == DockSending.Send ? "Sending…" : "Send";
            _primary.IsEnabled = !locked && AnsweredCount > 0;
        }
        else
        {
            _primary.Content = "Next";
            _primary.IsEnabled = !locked;
        }
        // [question-tidy] The first page has no foot while it is pick-one, unanswered and "Something else…" is closed.
        var tapAnswers = q.Choices is { Count: > 0 } && !q.MultiSelect && !stage.Other
            && ClarifyStaging.StagedAnswer(q, stage) == null;
        _foot.Visibility = Draft.Page == 0 && tapAnswers ? Visibility.Collapsed : Visibility.Visible;
    }

    private FrameworkElement ChoiceRow(ClarifyQuestion q, string choice, bool picked, bool locked)
    {
        var grid = new Grid { ColumnSpacing = 10 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var mark = new Border
        {
            Width = 22, Height = 22, CornerRadius = new CornerRadius(q.MultiSelect ? 6 : 11), VerticalAlignment = VerticalAlignment.Top,
            BorderThickness = new Thickness(picked ? 0 : 1.5), BorderBrush = Brush("ControlStrongStrokeColorDefaultBrush"),
            Background = picked ? Brush("AccentFillColorDefaultBrush") : new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            Margin = new Thickness(0, 1, 0, 0),
        };
        if (picked)
            mark.Child = new FontIcon
            {
                Glyph = "", FontSize = 12, Foreground = Brush("TextOnAccentFillColorPrimaryBrush"),
                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
            };
        grid.Children.Add(mark);
        var label = Text(ClarifyText.BareChoice(choice), 14);
        Grid.SetColumn(label, 1);
        grid.Children.Add(label);
        if (ClarifyText.IsRecommended(choice))
        {
            var tag = new Border
            {
                CornerRadius = new CornerRadius(6), Padding = new Thickness(6, 1, 6, 2), VerticalAlignment = VerticalAlignment.Top,
                Background = Brush("SubtleFillColorSecondaryBrush"),
                Child = Text("Recommended", 11, "AccentTextFillColorPrimaryBrush", semibold: true),
            };
            Grid.SetColumn(tag, 2);
            grid.Children.Add(tag);
        }
        var row = new Button
        {
            Content = grid, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0),
            Padding = new Thickness(0, 11, 0, 11), IsEnabled = !locked, MinHeight = 44,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(row, ClarifyText.BareChoice(choice) + (picked ? ", selected" : ""));
        if (q.MultiSelect) Microsoft.UI.Xaml.Automation.AutomationProperties.SetHelpText(row, "Choose any that apply.");
        row.Click += (_, _) =>
        {
            SetStage(q.Qid, ClarifyStaging.Toggle(q, Stage(q.Qid), choice), rerender: true);
            // [question-tidy] A pick-one page that is not the last moves on by itself.
            if (!q.MultiSelect && !IsLastPage) ScheduleAdvance(Draft.Page);
        };
        return row;
    }

    private static Border Hairline() => new() { Height = 1, Background = Brush("DividerStrokeColorDefaultBrush") };

    private TextBox Field(string placeholder, string text, bool locked)
    {
        var field = new TextBox
        {
            PlaceholderText = placeholder, Text = text, TextWrapping = TextWrapping.Wrap, AcceptsReturn = false,
            IsEnabled = !locked, IsSpellCheckEnabled = true,
        };
        field.KeyDown += (_, e) =>
        {
            if (e.Key != VirtualKey.Enter) return;
            e.Handled = true;
            ReturnPressed();
        };
        return field;
    }

    private void OnKey(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Escape || _sending != DockSending.None) return;
        e.Handled = true;
        // Escape leaves the field first ("Leave Answer Field"), then skips ("Skip Question").
        if (IsTyping) _skip.Focus(FocusState.Programmatic);
        else OnSkip?.Invoke(this);
    }

    private void SetStage(string qid, ClarifyStage stage, bool rerender)
    {
        var stages = Draft.Stages.ToDictionary(kv => kv.Key, kv => kv.Value);
        stages[qid] = stage;
        Draft = Draft with { Stages = stages };
        if (rerender) RenderPage();
        else UpdateFoot();
        OnDraftChanged?.Invoke(this);
    }

    private void Go(int by)
    {
        CancelAdvance();
        var page = Math.Clamp(Draft.Page + by, 0, Prompt.Questions.Count - 1);
        if (page == Draft.Page) return;
        var typing = IsTyping;
        Draft = Draft with { Page = page };
        RenderPage();
        OnDraftChanged?.Invoke(this);
        // Next from a field to a page that is only a field keeps the keys there.
        if (typing && _field != null) _field.Focus(FocusState.Programmatic);
        else TakeKeys();
    }

    private void PrimaryTapped()
    {
        if (_sending != DockSending.None) return;
        if (!IsLastPage) Go(1);
        else if (AnsweredCount > 0) OnSend?.Invoke(this);
    }

    /// Enter in a field: Next on earlier pages, Send on the last when an answer exists.
    private void ReturnPressed()
    {
        if (!IsLastPage) Go(1);
        else if (_sending == DockSending.None && AnsweredCount > 0) OnSend?.Invoke(this);
    }

    private void ScheduleAdvance(int fromPage)
    {
        CancelAdvance();
        _advance = _ui.CreateTimer();
        _advance.Interval = TimeSpan.FromMilliseconds(220);
        _advance.IsRepeating = false;
        _advance.Tick += (_, _) =>
        {
            _advance = null;
            if (Draft.Page == fromPage && !Draft.Minimized && _sending == DockSending.None) Go(1);
        };
        _advance.Start();
    }

    public void Stop() => CancelAdvance();

    private void CancelAdvance()
    {
        _advance?.Stop();
        _advance = null;
    }
}
