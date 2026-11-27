using System.Globalization;
using Hermes.Core.Composer;
using Hermes.Core.Gateways;
using Hermes.Core.Jobs;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Features.Jobs;

/// New Job / Edit Job (App/Pages/Jobs/JobEditorSheet.swift + JobEditorView.swift, docs/spec/3x-jobs.md §4): one sheet for
/// both, Cancel / the title / Create or Save, a discard question for a changed form. The form, top to bottom: the save
/// failure, Bot, Start From, then a template's own fields, or Prompt and Name, Schedule, Send Results To, Bot Chats and
/// Model; Run Once Now when creating. What it holds and sends is JobEditorModel (Hermes.Core/Jobs). Start From's See All
/// opens the searchable Blueprints list inside this same dialog (JobBlueprintPicker); the Model row likewise pushes the
/// Model list (JobModelPicker). Back or Escape on either list returns to the form with nothing written.
internal sealed class JobEditorDialog
{
    private readonly JobEditorModel _model;
    private readonly ContentDialog _dialog;
    private readonly DispatcherQueue _ui = DispatcherQueue.GetForCurrentThread();
    private readonly StackPanel _form = new() { Spacing = 2, Padding = new Thickness(0, 0, 12, 0) };
    private readonly StackPanel _discard = new() { Spacing = 8, Visibility = Visibility.Collapsed };
    private StackPanel? _scheduleFooter, _scheduleCard, _delivery, _slotFooters;
    private TextBox? _name;
    private Button? _modelButton;
    private TextBlock? _modelWords;
    private string _shape = "";
    private bool _discardConfirmed;
    private EditorOutcome _outcome = new(EditorOutcomeKind.Failed);
    private readonly StackPanel _body = new() { Width = 560, Spacing = 8 };
    /// The Blueprints list while it replaces the form (the Mac pushes it inside the sheet); null on the form.
    private JobBlueprintPickerSession? _picker;
    private StackPanel? _pickerRows;
    private HyperlinkButton? _seeAll;
    /// The Model list while it replaces the form (the Mac pushes it inside the sheet); null on the form.
    private JobModelPickerSession? _models;
    private StackPanel? _modelRows;
    private TextBox? _modelSearch;

    private static bool Uses24Hour => CultureInfo.CurrentCulture.DateTimeFormat.ShortTimePattern.Contains('H');

    private JobEditorDialog(JobEditorModel model)
    {
        _model = model;
        var scroll = new ScrollViewer { Content = _form, MaxHeight = 620, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        _body.Children.Add(_discard);
        _body.Children.Add(scroll);
        _dialog = new ContentDialog
        {
            Title = model.Title, Content = _body, PrimaryButtonText = model.ActionTitle, CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        _dialog.Resources["ContentDialogMaxWidth"] = 640.0;
        _dialog.PrimaryButtonClick += OnSave;
        _dialog.Closing += OnClosing;
        AutomationProperties.SetAutomationId(_dialog, "job.editor");
        model.Changed += () => _ui.TryEnqueue(Refresh);
        BuildDiscardBar();
        Render();
    }

    public static async Task<EditorOutcome> ShowAsync(JobEditorModel model, XamlRoot? root)
    {
        var editor = new JobEditorDialog(model);
        _ = model.LoadAsync();
        await JobActions.ShowAsync(editor._dialog, root);
        return editor._outcome;
    }

    // MARK: Save, close

    private async void OnSave(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        if (_picker != null || _models != null) { args.Cancel = true; return; }   // a list has no Create; Enter there never saves
        var deferral = args.GetDeferral();
        try
        {
            // An unchanged edit sends nothing; an incomplete form says what is missing.
            if (_model.IsEdit && _model.IsComplete && _model.Updates() == null) { args.Cancel = false; _outcome = new(EditorOutcomeKind.Failed); return; }
            var outcome = await _model.SaveAsync();
            _outcome = outcome;
            args.Cancel = outcome.Kind == EditorOutcomeKind.Failed;
            if (args.Cancel) Render();
        }
        catch (Exception ex)
        {
            args.Cancel = true;
            HermesHQ.Services.AppLog.Error("jobs", ex);
        }
        finally { deferral.Complete(); }
    }

    private void OnClosing(ContentDialog sender, ContentDialogClosingEventArgs args)
    {
        // Escape or Back on the Blueprints list goes back to the form: nothing chosen, nothing asked, the dialog stays.
        if (_picker != null) { args.Cancel = true; BackFromPicker(); return; }
        if (_models != null) { args.Cancel = true; BackFromModels(); return; }
        if (args.Result == ContentDialogResult.Primary) return;
        if (_model.Saving) { args.Cancel = true; return; }
        if (_model.IsDirty && !_discardConfirmed)
        {
            args.Cancel = true;
            _discard.Visibility = Visibility.Visible;
        }
    }

    private void BuildDiscardBar()
    {
        var card = new StackPanel { Spacing = 8 };
        card.Children.Add(JobsUi.Text("Discard Changes?", 14, bold: true));
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var discard = new Button { Content = "Discard Changes", Foreground = JobsUi.Red };
        discard.Click += (_, _) => { _discardConfirmed = true; _dialog.Hide(); };
        var keep = new Button { Content = "Keep Editing" };
        keep.Click += (_, _) => _discard.Visibility = Visibility.Collapsed;
        row.Children.Add(discard);
        row.Children.Add(keep);
        card.Children.Add(row);
        _discard.Children.Add(JobsUi.Card(card));
    }

    // MARK: Drawing

    /// What decides the form's layout; anything else is redrawn in place so a field being typed in keeps its focus.
    private string Shape() => string.Join("|", _model.Form.Profile, _model.Form.BlueprintKey, _model.Form.Frequency, _model.Failure,
        _model.FailedField, _model.Saving, _model.Blueprints.Count, _model.ScheduleRejected, _model.ScriptOnly, _model.Job?.Key);

    private void Refresh()
    {
        if (_picker != null) FillPicker();   // a blueprint load that lands while the list is open shows in it
        if (_models != null) FillModels();   // so does a model load, a Try Again or its failure
        if (Shape() != _shape) { Render(); return; }
        FillScheduleCard();
        FillScheduleFooter();
        FillDelivery();
        FillSlotFooters();
        if (_name != null) _name.PlaceholderText = _model.SuggestedName ?? "Optional";
        if (_modelWords != null) _modelWords.Text = _model.ModelWords;
        _dialog.IsPrimaryButtonEnabled = _model.CanSave;
    }

    private void Render()
    {
        _shape = Shape();
        _form.Children.Clear();
        _scheduleFooter = _scheduleCard = _delivery = _slotFooters = null;
        _name = null;
        _seeAll = null;
        _modelButton = null;
        _modelWords = null;
        _dialog.IsPrimaryButtonEnabled = _model.CanSave;
        if (_model.Failure is { } failure) _form.Children.Add(FailureCard(failure));
        if (_model.ShowsBotRow) BotSection();
        if (JobBlueprintPicker.Offered(_model)) TemplateSection();
        if (_model.Blueprint is { } blueprint)
        {
            _slotFooters = new StackPanel();
            foreach (var field in blueprint.Fields) SlotSection(field);
        }
        else
        {
            PromptSection();
            ScheduleSection();
            DeliverySections();
            if (_model.ShowsModelRow) ModelSection();
        }
        if (!_model.IsEdit) RunNowSection();
    }

    private static UIElement FailureCard(string failure)
    {
        var p = new StackPanel { Spacing = 4 };
        var title = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        title.Children.Add(JobsUi.Glyph("", 14, JobsUi.Red));
        title.Children.Add(JobsUi.Text("Couldn’t save the job", 14, JobsUi.Red, bold: true));
        p.Children.Add(title);
        p.Children.Add(JobsUi.Text(failure, 14, JobsUi.Red));
        AutomationProperties.SetAutomationId(p, "job.editor.failure");
        var card = JobsUi.Card(p);
        card.Background = JobsUi.Brush("SystemFillColorCriticalBackgroundBrush");
        return card;
    }

    private static TextBlock Footer(string text, Brush? color = null)
    {
        var t = JobsUi.Text(text, 12, color ?? JobsUi.Secondary);
        t.Margin = new Thickness(16, 4, 16, 0);
        return t;
    }

    private string BotName => _model.BotNames.GetValueOrDefault(_model.Form.Profile) is { Length: > 0 } n ? n : "the bot";

    private void BotSection()
    {
        _form.Children.Add(JobsUi.Header("Bot"));
        var wrap = new VariableSizedWrapGrid { Orientation = Orientation.Horizontal, ItemWidth = 96, ItemHeight = 76 };
        foreach (var (id, name) in _model.Bots)
        {
            var chosen = id == _model.Form.Profile;
            var p = new StackPanel { Spacing = 4, HorizontalAlignment = HorizontalAlignment.Center };
            var face = JobsUi.Face(id, 32);
            ((FrameworkElement)face).HorizontalAlignment = HorizontalAlignment.Center;
            p.Children.Add(face);
            p.Children.Add(JobsUi.Text(name, 12, chosen ? JobsUi.Accent : null, bold: chosen, wrap: false));
            var b = new ToggleButton { Content = p, IsChecked = chosen, Width = 90, Height = 72, Padding = new Thickness(4), Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
            AutomationProperties.SetName(b, name);
            var pick = id;
            b.Click += (_, _) => { _model.ChooseProfile(pick); Render(); };
            wrap.Children.Add(b);
        }
        _form.Children.Add(wrap);
    }

    private void TemplateSection()
    {
        var header = new Grid { ColumnSpacing = 8 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.Children.Add(JobsUi.Header("Start From"));
        _seeAll = new HyperlinkButton
        {
            Content = JobBlueprintPicker.SeeAll, FontSize = 13, IsEnabled = !_model.Saving,
            VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 4, 0),
        };
        AutomationProperties.SetAutomationId(_seeAll, "job.editor.start.all");
        AutomationProperties.SetHelpText(_seeAll, "Search every blueprint");
        _seeAll.Click += (_, _) => OpenPicker();
        Grid.SetColumn(_seeAll, 1);
        header.Children.Add(_seeAll);
        _form.Children.Add(header);
        var wrap = new VariableSizedWrapGrid { Orientation = Orientation.Horizontal, ItemWidth = 140, ItemHeight = 64 };
        void Add(string title, string? key, string tip)
        {
            var chosen = _model.Form.BlueprintKey == key;
            var b = new ToggleButton
            {
                Content = JobsUi.Text(title, 13, bold: chosen, maxLines: 2), IsChecked = chosen, Width = 134, Height = 58,
                HorizontalContentAlignment = HorizontalAlignment.Left, Padding = new Thickness(10, 6, 10, 6),
            };
            if (tip.Length > 0) ToolTipService.SetToolTip(b, tip);
            AutomationProperties.SetName(b, title);
            b.Click += (_, _) => { _model.ChooseBlueprint(key); Render(); };
            wrap.Children.Add(b);
        }
        Add("Write Your Own", null, "");
        foreach (var bp in _model.Blueprints) Add(bp.Title, bp.Key, bp.Description);
        _form.Children.Add(wrap);
    }

    // MARK: See All (Blueprints)

    /// See All: the list replaces the form inside this dialog (one ContentDialog can be open at a time), Back returns.
    private void OpenPicker()
    {
        if (_model.Saving || _picker != null || JobBlueprintPicker.Open(_model) is not { } session) return;
        _picker = session;
        _dialog.Title = JobBlueprintPicker.Title;
        _dialog.PrimaryButtonText = "";
        _dialog.CloseButtonText = "Back";
        _dialog.Content = PickerPage(session);
    }

    private UIElement PickerPage(JobBlueprintPickerSession session)
    {
        var page = new StackPanel { Width = 560, Spacing = 8 };
        AutomationProperties.SetAutomationId(page, "job.editor.blueprints");
        var search = new TextBox { PlaceholderText = JobBlueprintPicker.SearchPlaceholder, IsSpellCheckEnabled = false };
        AutomationProperties.SetName(search, JobBlueprintPicker.SearchPlaceholder);
        AutomationProperties.SetAutomationId(search, "job.editor.blueprints.search");
        search.TextChanged += (_, _) =>
        {
            if (_picker != session) return;
            session.Query = search.Text;
            FillPicker();
        };
        page.Children.Add(search);
        _pickerRows = new StackPanel { Spacing = 12 };
        page.Children.Add(new ScrollViewer { Content = _pickerRows, MaxHeight = 560, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        // Escape from the search field too: back to the form, the search dropped, nothing written.
        page.PreviewKeyDown += (_, e) =>
        {
            if (e.Key != Windows.System.VirtualKey.Escape || _picker != session) return;
            e.Handled = true;
            BackFromPicker();
        };
        page.Loaded += (_, _) => search.Focus(FocusState.Programmatic);
        FillPicker();
        return page;
    }

    private void FillPicker()
    {
        if (_picker is not { } session || _pickerRows == null) return;
        _pickerRows.Children.Clear();
        var list = session.List;
        if (list.NoResultsTitle is { } none)
        {
            var empty = new StackPanel { Spacing = 6, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 40, 0, 40) };
            var glass = JobsUi.Glyph("\uE721", 32, JobsUi.Secondary);
            glass.HorizontalAlignment = HorizontalAlignment.Center;
            empty.Children.Add(glass);
            var title = JobsUi.Text(none, 17, bold: true);
            title.HorizontalAlignment = HorizontalAlignment.Center;
            title.TextAlignment = TextAlignment.Center;
            empty.Children.Add(title);
            var note = JobsUi.Text(JobBlueprintPicker.NoResultsNote, 13, JobsUi.Secondary);
            note.HorizontalAlignment = HorizontalAlignment.Center;
            empty.Children.Add(note);
            AutomationProperties.SetAutomationId(empty, "job.editor.blueprints.none");
            AutomationProperties.SetLiveSetting(empty, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);
            _pickerRows.Children.Add(empty);
            return;
        }
        // Write Your Own in its own group above the blueprints, as the Mac's two sections.
        var groups = list.ShowsWriteYourOwn ? new[] { list.Rows.Take(1), list.Rows.Skip(1) } : new[] { list.Rows.AsEnumerable() };
        foreach (var group in groups)
        {
            var rows = new StackPanel();
            foreach (var row in group)
            {
                var key = row.Key;
                rows.Children.Add(PickerRow(row, () =>
                {
                    if (!session.Choose(key)) return;
                    ClosePicker();
                    Render();
                }));
            }
            if (rows.Children.Count > 0) _pickerRows.Children.Add(JobsUi.Card(rows, new Thickness(8, 2, 8, 2)));
        }
    }

    private static Button PickerRow(JobBlueprintPickerRow row, Action click) =>
        CheckRow(row.Title, row.Note, row.Checked, row.AutomationId, click, row.Key == null ? "\uE70F" : "\uE8A5");

    /// A row with an optional mark, the title and its note, and a trailing check; the whole row is the button (the
    /// Mac's JobCheckRow).
    private static Button CheckRow(string title, string? note, bool isChecked, string automationId, Action click, string? glyph = null)
    {
        var hasNote = !string.IsNullOrEmpty(note);
        var g = new Grid { ColumnSpacing = 12 };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = glyph == null ? new GridLength(0) : new GridLength(28) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (glyph != null)
        {
            var icon = JobsUi.Glyph(glyph, 18, JobsUi.Accent);
            icon.VerticalAlignment = VerticalAlignment.Center;
            g.Children.Add(icon);
        }
        var words = new StackPanel { Spacing = 2 };
        words.Children.Add(JobsUi.Text(title, 14));
        if (hasNote) words.Children.Add(JobsUi.Text(note!, 12, JobsUi.Secondary));
        Grid.SetColumn(words, 1);
        g.Children.Add(words);
        if (isChecked)
        {
            var check = JobsUi.Glyph("\uE73E", 14, JobsUi.Accent);
            check.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(check, 2);
            g.Children.Add(check);
        }
        var b = new Button
        {
            Content = g, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0),
            Padding = new Thickness(4, hasNote ? 8 : 6, 4, hasNote ? 8 : 6),
        };
        AutomationProperties.SetName(b, title);
        AutomationProperties.SetItemStatus(b, isChecked ? "selected" : note ?? "");
        AutomationProperties.SetAutomationId(b, automationId);
        b.Click += (_, _) => click();
        return b;
    }

    /// Back or Escape on the list: the session ends with nothing chosen and the form is shown as it was.
    private void BackFromPicker()
    {
        _picker?.Back();
        ClosePicker();
    }

    /// The form again, with its own title and buttons; focus back on See All.
    private void ClosePicker()
    {
        _picker = null;
        _pickerRows = null;
        _dialog.Title = _model.Title;
        _dialog.PrimaryButtonText = _model.ActionTitle;
        _dialog.CloseButtonText = "Cancel";
        _dialog.IsPrimaryButtonEnabled = _model.CanSave;
        _dialog.Content = _body;
        _ui.TryEnqueue(() => _seeAll?.Focus(FocusState.Programmatic));
    }

    private void PromptSection()
    {
        _form.Children.Add(JobsUi.Header(_model.ScriptOnly ? "Script" : "Prompt"));
        var p = new StackPanel { Spacing = 8 };
        if (_model.ScriptOnly)
            p.Children.Add(JobsUi.Text($"This job runs a script on {HostWord.Phrase}. It has no AI prompt.", 14, JobsUi.Secondary));
        else
        {
            var prompt = new TextBox
            {
                AcceptsReturn = true, Text = _model.Form.Prompt, TextWrapping = TextWrapping.Wrap, MinHeight = 88, MaxHeight = 200,
                PlaceholderText = $"What should {BotName} do? For example: summarize my unread Slack threads and email me the top 5.",
            };
            AutomationProperties.SetName(prompt, "Prompt");
            prompt.TextChanged += (_, _) => _model.SetPrompt(prompt.Text);
            p.Children.Add(prompt);
        }
        var nameRow = new Grid { ColumnSpacing = 12 };
        nameRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        nameRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var label = JobsUi.Text("Name", 14);
        label.VerticalAlignment = VerticalAlignment.Center;
        nameRow.Children.Add(label);
        _name = new TextBox { Text = _model.Form.Name, PlaceholderText = _model.SuggestedName ?? "Optional", TextAlignment = TextAlignment.Right };
        AutomationProperties.SetName(_name, "Name");
        var name = _name;
        name.TextChanged += (_, _) => _model.SetName(name.Text);
        Grid.SetColumn(name, 1);
        nameRow.Children.Add(name);
        p.Children.Add(nameRow);
        _form.Children.Add(JobsUi.Card(p));
    }

    private void ScheduleSection()
    {
        _form.Children.Add(JobsUi.Header("Schedule"));
        var chips = new StackPanel { Spacing = 6, Margin = new Thickness(0, 0, 0, 8) };
        var rows = new[] { JobFrequencies.All.Take(5), JobFrequencies.All.Skip(5) };
        foreach (var set in rows)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            foreach (var f in set)
            {
                var chip = new ToggleButton { Content = f.ChipTitle(), IsChecked = f == _model.Form.Frequency };
                AutomationProperties.SetAutomationId(chip, "job.editor.frequency." + f);
                var pick = f;
                chip.Click += (_, _) => { _model.SetFrequency(pick); Render(); };
                row.Children.Add(chip);
            }
            chips.Children.Add(row);
        }
        _form.Children.Add(chips);
        _scheduleCard = new StackPanel { Spacing = 8 };
        var card = JobsUi.Card(_scheduleCard);
        _form.Children.Add(card);
        _scheduleFooter = new StackPanel { Spacing = 2 };
        _form.Children.Add(_scheduleFooter);
        FillScheduleCard(force: true);
        FillScheduleFooter();
        card.Visibility = _scheduleCard.Children.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    private string _cardFor = "";

    private void FillScheduleCard(bool force = false)
    {
        if (_scheduleCard == null) return;
        var frequency = _model.Form.Frequency;
        var fields = _model.Fields;
        // Custom's field keeps its focus: its card is drawn once per frequency.
        var key = frequency switch
        {
            JobFrequency.Custom => "custom",
            JobFrequency.Hourly => frequency + "|" + fields.Minute,
            _ => frequency + "|" + string.Join(",", fields.Weekdays) + "|" + fields.Day,
        };
        if (!force && key == _cardFor) return;
        _cardFor = key;
        _scheduleCard.Children.Clear();
        switch (frequency)
        {
            case JobFrequency.Weekly:
                _scheduleCard.Children.Add(WeekdayPicker(fields.Weekdays));
                break;
            case JobFrequency.Monthly:
            {
                var box = new ComboBox { Header = "Day of the Month", MinWidth = 120 };
                for (var d = 1; d <= 31; d++) box.Items.Add(d.ToString(CultureInfo.InvariantCulture));
                box.SelectedIndex = fields.Day - 1;
                box.SelectionChanged += (_, _) => { if (box.SelectedIndex >= 0) _model.SetFields(_model.Fields with { Day = box.SelectedIndex + 1 }); };
                _scheduleCard.Children.Add(box);
                break;
            }
            case JobFrequency.Hourly:
            {
                var choices = JobSchedule.MinuteChoices(fields.Minute);
                var box = new ComboBox { Header = "Minutes Past the Hour", MinWidth = 120 };
                foreach (var m in choices) box.Items.Add($":{m:00}");
                box.SelectedIndex = choices.IndexOf(fields.Minute);
                box.SelectionChanged += (_, _) => { if (box.SelectedIndex >= 0) _model.SetFields(_model.Fields with { Minute = choices[box.SelectedIndex] }); };
                _scheduleCard.Children.Add(box);
                break;
            }
        }
        if (frequency.IsTimed() && frequency != JobFrequency.Hourly)
        {
            var time = new TimePicker
            {
                Header = "Time", Time = new TimeSpan(fields.Hour, fields.Minute, 0), MinuteIncrement = 1,
                ClockIdentifier = Uses24Hour ? "24HourClock" : "12HourClock",
            };
            AutomationProperties.SetAutomationId(time, "job.editor.time");
            time.TimeChanged += (_, e) => _model.SetFields(_model.Fields with { Hour = e.NewTime.Hours, Minute = e.NewTime.Minutes });
            _scheduleCard.Children.Add(time);
        }
        if (frequency == JobFrequency.Custom)
        {
            var custom = new TextBox
            {
                Header = "Custom Schedule", Text = _model.Form.Schedule, PlaceholderText = JobSchedule.CustomPlaceholder,
                FontFamily = JobsUi.Res<FontFamily>("CodeFont"), IsSpellCheckEnabled = false,
            };
            AutomationProperties.SetAutomationId(custom, "job.editor.custom");
            custom.TextChanged += (_, _) => _model.SetCustomSchedule(custom.Text);
            _scheduleCard.Children.Add(custom);
        }
        if (_scheduleCard.Parent is Border border) border.Visibility = _scheduleCard.Children.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    /// Weekly's days, in the PC's week order, as round buttons with their first letters.
    private UIElement WeekdayPicker(int[] days)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        var first = (int)CultureInfo.CurrentCulture.DateTimeFormat.FirstDayOfWeek;
        var letters = CultureInfo.CurrentCulture.DateTimeFormat.ShortestDayNames;
        for (var i = 0; i < 7; i++)
        {
            var day = (first + i) % 7;
            var b = new ToggleButton
            {
                Content = letters[day].Length > 0 ? letters[day][..1] : "?", IsChecked = days.Contains(day),
                Width = 40, Height = 40, CornerRadius = new CornerRadius(20), Padding = new Thickness(0),
            };
            AutomationProperties.SetName(b, JobWords.Days[day]);
            b.Click += (_, _) => { _model.ToggleWeekday(day); _cardFor = ""; FillScheduleCard(); };
            row.Children.Add(b);
        }
        return row;
    }

    private void FillScheduleFooter()
    {
        if (_scheduleFooter == null) return;
        _scheduleFooter.Children.Clear();
        var frequency = _model.Form.Frequency;
        if (frequency == JobFrequency.Custom)
        {
            if (_model.ScheduleRejected && _model.Failure is { } failure) _scheduleFooter.Children.Add(Footer(failure, JobsUi.Red));
            else if (JobSchedule.CustomPreview(_model.Form.Schedule) is { Length: > 0 } preview) _scheduleFooter.Children.Add(Footer(preview, null));
            if (_model.NextRunWords() is { } next) _scheduleFooter.Children.Add(Footer(next));
            _scheduleFooter.Children.Add(Footer(JobSchedule.CustomHint));
            return;
        }
        var summary = Footer(JobSchedule.Summary(frequency, _model.Form.Schedule, Uses24Hour));
        summary.ClearValue(TextBlock.ForegroundProperty);   // the theme's primary brush (a null one draws nothing)
        _scheduleFooter.Children.Add(summary);
        if (_model.NextRunWords() is { } nextRun) _scheduleFooter.Children.Add(Footer(nextRun));
        if (JobSchedule.SkipNote(frequency, _model.Fields) is { } skip) _scheduleFooter.Children.Add(Footer(skip));
        if (frequency.IsTimed() && _model.HostClockFor() is HostClock.Offset) _scheduleFooter.Children.Add(Footer(JobSchedule.ClockNote));
    }

    // MARK: Delivery

    private UIElement DeliveryIcon(string id)
    {
        if (id == JobDelivery.Fallback) return JobsUi.Glyph("", 18);
        if (id.StartsWith("bot-chat:")) return JobsUi.Face(id["bot-chat:".Length..], 24);
        if (id == "origin") return JobsUi.Glyph("", 18);
        return JobsUi.Glyph("", 18);
    }

    private string DeliveryTitle(DeliveryRow row)
    {
        if (row.Id.StartsWith("bot-chat:") && _model.BotNames.GetValueOrDefault(row.Id["bot-chat:".Length..]) is { Length: > 0 } name) return name;
        return row.Title;
    }

    private Button DeliveryRowButton(DeliveryRow row, Action click)
    {
        var g = new Grid { ColumnSpacing = 12 };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(28) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var icon = DeliveryIcon(row.Id);
        ((FrameworkElement)icon).VerticalAlignment = VerticalAlignment.Center;
        g.Children.Add(icon);
        var words = new StackPanel();
        words.Children.Add(JobsUi.Text(DeliveryTitle(row), 14));
        if (row.Note != null) words.Children.Add(JobsUi.Text(row.Note, 12, JobsUi.Secondary));
        Grid.SetColumn(words, 1);
        g.Children.Add(words);
        if (row.Checked)
        {
            var check = JobsUi.Glyph("", 14, JobsUi.Accent);
            Grid.SetColumn(check, 2);
            g.Children.Add(check);
        }
        var b = new Button
        {
            Content = g, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0),
            Padding = new Thickness(4, 8, 4, 8), IsEnabled = row.Selectable,
        };
        AutomationProperties.SetName(b, DeliveryTitle(row));
        AutomationProperties.SetAutomationId(b, "job.editor.deliver." + row.Id);
        b.Click += (_, _) => click();
        return b;
    }

    private UIElement PlacesFailed(Func<Task> retry)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Margin = new Thickness(16, 4, 16, 0) };
        row.Children.Add(JobsUi.Text("Couldn’t load the other places.", 12, JobsUi.Secondary));
        var again = new HyperlinkButton { Content = "Try Again", Padding = new Thickness(0), FontSize = 12 };
        again.Click += (_, _) => _ = retry();
        row.Children.Add(again);
        return row;
    }

    private static UIElement LoadingRow()
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Padding = new Thickness(4, 8, 4, 8) };
        row.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
        row.Children.Add(JobsUi.Text("Loading other places…", 14, JobsUi.Secondary));
        return row;
    }

    private void DeliverySections()
    {
        _delivery = new StackPanel();
        _form.Children.Add(_delivery);
        FillDelivery();
    }

    private void FillDelivery()
    {
        if (_delivery == null) return;
        _delivery.Children.Clear();
        var groups = _model.DeliveryGroups;
        _delivery.Children.Add(JobsUi.Header("Send Results To"));
        var places = new StackPanel();
        foreach (var row in groups.Places) { var id = row.Id; places.Children.Add(DeliveryRowButton(row, () => _model.ToggleDelivery(id))); }
        if (_model.TargetsState == EditorLoad.Loading) places.Children.Add(LoadingRow());
        _delivery.Children.Add(JobsUi.Card(places, new Thickness(8, 2, 8, 2)));
        if (_model.TargetsState == EditorLoad.Failed) _delivery.Children.Add(PlacesFailed(_model.ReloadTargetsAsync));
        if (JobDelivery.NeedsHomeNote(groups.NeedsHome) is { } note) _delivery.Children.Add(Footer(note));
        _delivery.Children.Add(Footer("Every result is also kept in the job’s Run History."));
        if (groups.Bots.Count > 0)
        {
            _delivery.Children.Add(JobsUi.Header("Bot Chats"));
            var bots = new StackPanel();
            foreach (var row in groups.Bots) { var id = row.Id; bots.Children.Add(DeliveryRowButton(row, () => _model.ToggleDelivery(id))); }
            _delivery.Children.Add(JobsUi.Card(bots, new Thickness(8, 2, 8, 2)));
            _delivery.Children.Add(Footer("The bot gets each result in its chat and can act on it."));
        }
    }

    // MARK: Model, run once

    private void ModelSection()
    {
        // The row pushes the Model list inside this dialog (the Mac's pushed picker), not a flyout.
        var g = new Grid { ColumnSpacing = 12 };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var label = JobsUi.Text("Model", 14);
        label.VerticalAlignment = VerticalAlignment.Center;
        g.Children.Add(label);
        _modelWords = JobsUi.Text(_model.ModelWords, 14, JobsUi.Secondary, wrap: false);
        _modelWords.HorizontalAlignment = HorizontalAlignment.Right;
        _modelWords.VerticalAlignment = VerticalAlignment.Center;
        _modelWords.TextTrimming = TextTrimming.CharacterEllipsis;
        Grid.SetColumn(_modelWords, 1);
        g.Children.Add(_modelWords);
        var chevron = JobsUi.Glyph("\uE76C", 12, JobsUi.Secondary);
        chevron.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(chevron, 2);
        g.Children.Add(chevron);
        _modelButton = new Button
        {
            Content = g, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0),
            Padding = new Thickness(4, 6, 4, 6), IsEnabled = !_model.Saving,
        };
        AutomationProperties.SetName(_modelButton, "Model");
        AutomationProperties.SetAutomationId(_modelButton, "job.editor.model");
        _modelButton.Click += (_, _) => OpenModels();
        _form.Children.Add(JobsUi.Header(""));
        _form.Children.Add(JobsUi.Card(_modelButton, new Thickness(8, 2, 8, 2)));
        _form.Children.Add(Footer(JobWords.ModelScope(_model.BotNames.GetValueOrDefault(_model.Form.Profile))));
    }

    // MARK: Model list

    /// The Model row: the list replaces the form inside this dialog (one ContentDialog can be open at a time).
    private void OpenModels()
    {
        if (_model.Saving || _picker != null || _models != null || JobModelPicker.Open(_model) is not { } session) return;
        _models = session;
        _dialog.Title = JobModelPicker.Title;
        _dialog.PrimaryButtonText = "";
        _dialog.CloseButtonText = "Back";
        _dialog.Content = ModelsPage(session);
    }

    private UIElement ModelsPage(JobModelPickerSession session)
    {
        var page = new StackPanel { Width = 560, Spacing = 8 };
        AutomationProperties.SetAutomationId(page, "job.editor.models");
        // Search Models, shown only above 20 models (FillModels keeps that current as loads land).
        var search = new TextBox { PlaceholderText = JobModelPicker.SearchPlaceholder, IsSpellCheckEnabled = false };
        AutomationProperties.SetName(search, JobModelPicker.SearchPlaceholder);
        AutomationProperties.SetAutomationId(search, "job.editor.models.search");
        search.TextChanged += (_, _) =>
        {
            if (_models != session) return;
            session.Query = search.Text;
            FillModels();
        };
        _modelSearch = search;
        page.Children.Add(search);
        _modelRows = new StackPanel { Spacing = 4 };
        page.Children.Add(new ScrollViewer { Content = _modelRows, MaxHeight = 560, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        // Escape from the search field too: back to the form, the search dropped, nothing written.
        page.PreviewKeyDown += (_, e) =>
        {
            if (e.Key != Windows.System.VirtualKey.Escape || _models != session) return;
            e.Handled = true;
            BackFromModels();
        };
        page.Loaded += (_, _) => { if (search.Visibility == Visibility.Visible) search.Focus(FocusState.Programmatic); };
        FillModels();
        return page;
    }

    private void FillModels()
    {
        if (_models is not { } session || _modelRows == null) return;
        if (_modelSearch != null)
        {
            var shows = session.ShowsSearch;
            _modelSearch.Visibility = shows ? Visibility.Visible : Visibility.Collapsed;
            // Hidden, the search is empty (the Mac drops its search controller and its words).
            if (!shows && session.Query.Length > 0) { session.Query = ""; _modelSearch.Text = ""; }
        }
        _modelRows.Children.Clear();
        var list = session.List;
        void Pick(JobModelChoice? choice)
        {
            if (!session.Choose(choice)) return;
            CloseModels();
        }
        if (list.ShowsDefault)
        {
            var rows = new StackPanel();
            rows.Children.Add(CheckRow(JobModelPicker.DefaultTitle, null, list.DefaultChecked, "job.editor.model.default", () => Pick(null)));
            _modelRows.Children.Add(JobsUi.Card(rows, new Thickness(8, 2, 8, 2)));
            _modelRows.Children.Add(Footer(JobModelPicker.DefaultNote));
        }
        if (list.Current is { } current)
        {
            _modelRows.Children.Add(JobsUi.Header(JobModelPicker.CurrentHeader));
            var rows = new StackPanel();
            var pinned = current.Choice;
            rows.Children.Add(CheckRow(current.Title, current.Note, current.Checked, "job.editor.model.current", () => Pick(pinned)));
            _modelRows.Children.Add(JobsUi.Card(rows, new Thickness(8, 2, 8, 2)));
        }
        switch (list.State)
        {
            case EditorLoad.Loading:
            {
                var ring = new ProgressRing { IsActive = true, Width = 20, Height = 20, Margin = new Thickness(0, 12, 0, 12), HorizontalAlignment = HorizontalAlignment.Center };
                AutomationProperties.SetName(ring, "Loading models");
                _modelRows.Children.Add(ring);
                break;
            }
            case EditorLoad.Failed:
            {
                var p = new StackPanel { Spacing = 6 };
                p.Children.Add(JobsUi.Text(JobModelPicker.LoadFailed, 14, JobsUi.Secondary));
                var again = new HyperlinkButton { Content = JobModelPicker.TryAgain, Padding = new Thickness(0) };
                AutomationProperties.SetAutomationId(again, "job.editor.models.retry");
                again.Click += (_, _) => _ = session.RetryAsync();
                p.Children.Add(again);
                var card = JobsUi.Card(p);
                AutomationProperties.SetLiveSetting(card, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);
                _modelRows.Children.Add(card);
                break;
            }
            default:
                foreach (var section in list.Sections)
                {
                    _modelRows.Children.Add(JobsUi.Header(section.Header));
                    var rows = new StackPanel();
                    foreach (var row in section.Rows)
                    {
                        var choice = row.Choice;
                        rows.Children.Add(CheckRow(row.Title, row.Note, row.Checked, row.AutomationId, () => Pick(choice)));
                    }
                    _modelRows.Children.Add(JobsUi.Card(rows, new Thickness(8, 2, 8, 2)));
                }
                break;
        }
    }

    /// Back or Escape on the Model list: the session ends with nothing chosen and the form is shown as it was.
    private void BackFromModels()
    {
        _models?.Back();
        CloseModels();
    }

    /// The form again, with its own title and buttons; focus back on the Model row.
    private void CloseModels()
    {
        _models = null;
        _modelRows = null;
        _modelSearch = null;
        _dialog.Title = _model.Title;
        _dialog.PrimaryButtonText = _model.ActionTitle;
        _dialog.CloseButtonText = "Cancel";
        _dialog.IsPrimaryButtonEnabled = _model.CanSave;
        _dialog.Content = _body;
        _ui.TryEnqueue(() => _modelButton?.Focus(FocusState.Programmatic));
    }

    private void RunNowSection()
    {
        var toggle = new ToggleSwitch { Header = null, IsOn = _model.Form.RunNow, OnContent = "", OffContent = "", MinWidth = 0 };
        AutomationProperties.SetName(toggle, "Run Once Now");
        AutomationProperties.SetAutomationId(toggle, "job.editor.run-now");
        toggle.Toggled += (_, _) => _model.SetRunNow(toggle.IsOn);
        var row = new Grid();
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var label = JobsUi.Text("Run Once Now", 14);
        label.VerticalAlignment = VerticalAlignment.Center;
        row.Children.Add(label);
        Grid.SetColumn(toggle, 1);
        row.Children.Add(toggle);
        _form.Children.Add(JobsUi.Header(""));
        _form.Children.Add(JobsUi.Card(row));
        _form.Children.Add(Footer("Runs it as soon as it’s created, so you can check the result."));
    }

    // MARK: Template fields

    private UIElement SlotHeader(BlueprintField field, BlueprintControl control)
    {
        var g = new Grid { Margin = new Thickness(16, 16, 16, 6) };
        if (control is BlueprintControl.Text or BlueprintControl.Deliver)
        {
            g.Children.Add(JobsUi.Text(field.Title, 13, bold: true));
            if (field.Optional)
            {
                var opt = JobsUi.Text("Optional", 13, JobsUi.Tertiary);
                opt.HorizontalAlignment = HorizontalAlignment.Right;
                g.Children.Add(opt);
            }
        }
        return g;
    }

    private void SlotSection(BlueprintField field)
    {
        var control = JobBlueprints.Control(field);
        var value = _model.Form.Slots.GetValueOrDefault(field.Name, "");
        _form.Children.Add(SlotHeader(field, control));
        UIElement body;
        switch (control)
        {
            case BlueprintControl.Time:
            {
                var t = JobBlueprints.Time(value) ?? (9, 0);
                var picker = new TimePicker
                {
                    Header = field.Title, Time = new TimeSpan(t.Hour, t.Minute, 0), MinuteIncrement = 1,
                    ClockIdentifier = Uses24Hour ? "24HourClock" : "12HourClock",
                };
                AutomationProperties.SetAutomationId(picker, "job.editor.slot." + field.Name);
                picker.TimeChanged += (_, e) => _model.SetSlot(field.Name, JobBlueprints.TimeValue(e.NewTime.Hours, e.NewTime.Minutes));
                body = picker;
                break;
            }
            case BlueprintControl.Choice:
            {
                var box = new ComboBox { Header = field.Title, MinWidth = 200 };
                var values = new List<string>();
                if (!field.Choices.Contains(value))
                {
                    values.Add(value);
                    box.Items.Add(value.Length == 0 ? (field.Optional ? "None" : "Choose") : JobBlueprints.OptionLabel(field, value));
                }
                else if (field.Optional) { values.Add(""); box.Items.Add("None"); }
                foreach (var o in field.Choices) { values.Add(o); box.Items.Add(JobBlueprints.OptionLabel(field, o)); }
                box.SelectedIndex = values.IndexOf(value);
                box.SelectionChanged += (_, _) => { if (box.SelectedIndex >= 0) _model.SetSlot(field.Name, values[box.SelectedIndex]); };
                AutomationProperties.SetAutomationId(box, "job.editor.slot." + field.Name);
                body = box;
                break;
            }
            case BlueprintControl.Deliver:
            {
                var rows = new StackPanel();
                foreach (var row in _model.SlotDeliveryRows(value).Where(r => r.Selectable || r.Checked))
                {
                    var id = row.Id;
                    rows.Children.Add(DeliveryRowButton(row, () => { if (!row.Checked) { _model.SetSlot(field.Name, id); Render(); } }));
                }
                if (_model.TargetsState == EditorLoad.Loading) rows.Children.Add(LoadingRow());
                body = rows;
                break;
            }
            default:
            {
                var box = new TextBox
                {
                    AcceptsReturn = true, Text = value, PlaceholderText = JobBlueprints.Placeholder(field), TextWrapping = TextWrapping.Wrap, MaxHeight = 140,
                };
                AutomationProperties.SetName(box, field.Title);
                AutomationProperties.SetAutomationId(box, "job.editor.slot." + field.Name);
                box.TextChanged += (_, _) => _model.SetSlot(field.Name, box.Text);
                body = box;
                break;
            }
        }
        _form.Children.Add(JobsUi.Card(body));
        var footer = new StackPanel { Tag = field.Name };
        _form.Children.Add(footer);
        _slotFooters?.Children.Add(new Border { Tag = footer });
        FillSlotFooter(field, footer);
    }

    private void FillSlotFooters()
    {
        if (_slotFooters == null || _model.Blueprint is not { } bp) return;
        foreach (var holder in _slotFooters.Children.OfType<Border>())
            if (holder.Tag is StackPanel footer && bp.Fields.FirstOrDefault(f => f.Name == (string)footer.Tag) is { } field) FillSlotFooter(field, footer);
    }

    private void FillSlotFooter(BlueprintField field, StackPanel footer)
    {
        footer.Children.Clear();
        var control = JobBlueprints.Control(field);
        if (_model.FailedField == field.Name && _model.Failure is { } failure) footer.Children.Add(Footer(failure, JobsUi.Red));
        else if (control == BlueprintControl.Deliver && _model.TargetsState == EditorLoad.Failed) footer.Children.Add(PlacesFailed(_model.ReloadTargetsAsync));
        else if (control == BlueprintControl.Deliver)
        {
            var value = _model.Form.Slots.GetValueOrDefault(field.Name, "");
            if (JobDelivery.NeedsHomeNote(JobDelivery.Groups(_model.SlotDeliveryRows(value)).NeedsHome) is { } note) footer.Children.Add(Footer(note));
            footer.Children.Add(Footer("Every result is also kept in the job’s Run History."));
        }
        else if (JobBlueprints.FieldHelp(field) is { } help) footer.Children.Add(Footer(help));
    }
}
