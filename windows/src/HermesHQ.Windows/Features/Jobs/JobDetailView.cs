using Hermes.Core.Composer;
using Hermes.Core.Jobs;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Features.Jobs;

/// A job's page beside the list (App/Pages/Jobs/JobDetailViewController.swift, docs/spec/1x-pages.md §3.5), as the Mac
/// draws it: a readable column with the title, the raw name and a status line, Run Now and Pause tiles, the last error
/// card (Edit Job, Run Again), Schedule (Repeats, Next Run, Last Run), Delivers To and Model, the prompt (6 lines, Show
/// All), Run History with its note, and Delete Job. Edit at the top. A job that disappears says "Job Removed".
internal sealed class JobDetailView : Grid
{
    private readonly JobsStore _store;
    private readonly JobActions _actions;
    private readonly Action<CronJob, CronRun> _openRun;
    private readonly DispatcherQueue _ui = DispatcherQueue.GetForCurrentThread();
    private readonly StackPanel _column = new() { MaxWidth = 720, Spacing = 4, Padding = new Thickness(24, 8, 24, 32) };
    private readonly DispatcherQueueTimer _timer;
    private CronJob? _last;
    private List<CronRun> _runs = [];
    private bool _runsLoaded, _runsFailed, _errorOpen, _promptOpen;
    private string? _runsReadFor;
    private bool _removed;

    public string JobKey { get; }

    public JobDetailView(JobsStore store, JobActions actions, string key, Action<CronJob, CronRun> openRun)
    {
        _store = store;
        _actions = actions;
        _openRun = openRun;
        JobKey = key;
        _last = store.Job(key);
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var edit = new Button { Content = "Edit", HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 8, 16, 0), Style = JobsUi.Res<Style>("QuietButtonStyle") };
        AutomationProperties.SetAutomationId(edit, "job.edit");
        edit.Click += (_, _) => { if (Job is { } j) _actions.Edit(j); };
        Children.Add(edit);
        var scroll = new ScrollViewer { Content = _column, HorizontalScrollMode = ScrollMode.Disabled };
        _column.HorizontalAlignment = HorizontalAlignment.Stretch;
        SetRow(scroll, 1);
        Children.Add(scroll);
        // Runs: again every 60 s while the page shows (8 s on a gateway without change events).
        _timer = _ui.CreateTimer();
        _timer.Interval = TimeSpan.FromSeconds(store.ChangeEvents ? 60 : 8);
        _timer.Tick += (_, _) => { if (HermesHQ.Services.AppShutdown.Stopping) { _timer.Stop(); return; } _ = LoadRunsAsync(); Render(); };
        Unloaded += (_, _) => _timer.Stop();
        Loaded += (_, _) => { if (!HermesHQ.Services.AppShutdown.Stopping) _timer.Start(); };
        Render();
        _ = LoadRunsAsync();
        if (_last is { } job) _ = _store.ReloadAsync(job);
    }

    public CronJob? Job => _removed ? null : _store.Job(JobKey) ?? _last;

    /// The job was removed (404, or deleted elsewhere).
    public void MarkRemoved()
    {
        _removed = true;
        Render();
    }

    /// The store changed: redraw, and read the runs again when the job's last run moved.
    public void StoreChanged()
    {
        if (_store.Job(JobKey) is { } fresh) _last = fresh;
        if (Job is { } job && _runsLoaded && job.LastRunAt != _runsReadFor) _ = LoadRunsAsync();
        Render();
    }

    private async Task LoadRunsAsync()
    {
        if (Job is not { } job) return;
        _runsReadFor = job.LastRunAt;
        try
        {
            var runs = await _store.LoadRunsAsync(job);
            _runs = runs;
            _runsFailed = false;
        }
        catch (Hermes.Core.Net.GatewayException) { _runsFailed = !_runsLoaded; }
        _runsLoaded = true;
        if (!HermesHQ.Services.AppShutdown.Stopping) _ui.TryEnqueue(() => { if (!HermesHQ.Services.AppShutdown.Stopping) Render(); });
    }

    private void Render()
    {
        _column.Children.Clear();
        if (Job is not { } job)
        {
            var gone = new StackPanel { Spacing = 8, Margin = new Thickness(0, 120, 0, 0), HorizontalAlignment = HorizontalAlignment.Center };
            var icon = JobsUi.Glyph("", 40, JobsUi.Secondary);
            gone.Children.Add(icon);
            var title = JobsUi.Text("Job Removed", 20, bold: true);
            title.HorizontalAlignment = HorizontalAlignment.Center;
            gone.Children.Add(title);
            var body = JobsUi.Text("This job is no longer on your gateway.", 14, JobsUi.Secondary);
            body.HorizontalAlignment = HorizontalAlignment.Center;
            gone.Children.Add(body);
            _column.Children.Add(gone);
            Children[0].Visibility = Visibility.Collapsed;
            return;
        }
        Children[0].Visibility = Visibility.Visible;
        Header(job);
        Tiles(job);
        if (!string.IsNullOrEmpty(job.LastError)) ErrorCard(job);
        Schedule(job);
        Delivery(job);
        Prompt(job);
        RunHistory(job);
        var delete = new Button
        {
            Content = JobsUi.Text("Delete Job", 14, JobsUi.Red), HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Left, Padding = new Thickness(16, 10, 16, 10), Margin = new Thickness(0, 16, 0, 0),
        };
        AutomationProperties.SetName(delete, "Delete Job");
        AutomationProperties.SetAutomationId(delete, "job.delete");
        delete.Click += (_, _) => _actions.Delete(job);
        _column.Children.Add(delete);
    }

    private void Header(CronJob job)
    {
        var title = _store.Title(job);
        var t = JobsUi.Text(title, 28, bold: true);
        t.FontWeight = FontWeights.Bold;
        t.IsTextSelectionEnabled = true;
        _column.Children.Add(t);
        var raw = JobWords.JobTitle(job);
        if (raw != title)
        {
            var r = JobsUi.Text(raw, 12, JobsUi.Secondary);
            r.IsTextSelectionEnabled = true;
            _column.Children.Add(r);
        }
        var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var status = _store.ShowsRunning(job) ? "Running" : JobWords.StatusWord(job);
        var cardSaysIt = status == "Last run failed" && !string.IsNullOrEmpty(job.LastError);
        if (!cardSaysIt)
        {
            var s = JobsUi.Text(status, 14, status == "Last run failed" ? JobsUi.Red : status == "Overdue" ? JobsUi.Orange : JobsUi.Secondary);
            AutomationProperties.SetAutomationId(s, "job.status");
            line.Children.Add(s);
        }
        if (JobWords.JobIsScriptOnly(job))
            line.Children.Add(new Border
            {
                Child = JobsUi.Text("Script", 11, JobsUi.Secondary, bold: true), Padding = new Thickness(8, 2, 8, 2),
                CornerRadius = new CornerRadius(10), Background = JobsUi.Brush("SubtleFillColorSecondaryBrush"),
            });
        if (line.Children.Count > 0) _column.Children.Add(line);
    }

    private static Button Tile(string title, string glyph, bool spinning, bool enabled)
    {
        var p = new StackPanel { Spacing = 4, HorizontalAlignment = HorizontalAlignment.Center };
        p.Children.Add(spinning ? new ProgressRing { IsActive = true, Width = 16, Height = 16 } : JobsUi.Glyph(glyph, 16));
        p.Children.Add(JobsUi.Text(title, 12, bold: true, wrap: false));
        var b = new Button
        {
            Content = p, HorizontalAlignment = HorizontalAlignment.Stretch, Height = 56, IsEnabled = enabled,
            CornerRadius = new CornerRadius(12),
        };
        AutomationProperties.SetName(b, title);
        ToolTipService.SetToolTip(b, title);
        return b;
    }

    private void Tiles(CronJob job)
    {
        var busy = _store.IsBusy(job);
        var runOut = _store.ShowsRunning(job);
        var paused = JobWords.IsPaused(job);
        var g = new Grid { ColumnSpacing = 10, Margin = new Thickness(0, 10, 0, 6) };
        g.ColumnDefinitions.Add(new ColumnDefinition());
        g.ColumnDefinitions.Add(new ColumnDefinition());
        var run = Tile("Run Now", "", runOut, !busy);
        AutomationProperties.SetAutomationId(run, "job.run");
        run.Click += (_, _) => _actions.RunNow(job);
        var pause = Tile(paused ? "Resume" : "Pause", paused ? "" : "", busy && !runOut, !busy);
        AutomationProperties.SetAutomationId(pause, "job.pause");
        pause.Click += (_, _) => _actions.TogglePause(job);
        SetColumn(pause, 1);
        g.Children.Add(run);
        g.Children.Add(pause);
        _column.Children.Add(g);
    }

    private void ErrorCard(CronJob job)
    {
        var p = new StackPanel { Spacing = 8 };
        var top = new Grid { ColumnSpacing = 8 };
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        top.Children.Add(JobsUi.Glyph("", 14, JobsUi.Red));
        var said = JobsUi.Text($"Last run failed: {JobWords.LastErrorSummary(job.LastError)}", 14, JobsUi.Red);
        SetColumn(said, 1);
        top.Children.Add(said);
        var chevron = JobsUi.Quiet(JobsUi.Glyph(_errorOpen ? "" : "", 12, JobsUi.Red), _errorOpen ? "Hide Details" : "Show Details",
            (_, _) => { _errorOpen = !_errorOpen; Render(); });
        SetColumn(chevron, 2);
        top.Children.Add(chevron);
        p.Children.Add(top);
        if (_errorOpen)
        {
            var full = JobsUi.Text(job.LastError ?? "", 12, JobsUi.Red);
            full.FontFamily = JobsUi.Res<FontFamily>("CodeFont");
            full.IsTextSelectionEnabled = true;
            p.Children.Add(full);
        }
        var buttons = new Grid { ColumnSpacing = 8 };
        buttons.ColumnDefinitions.Add(new ColumnDefinition());
        buttons.ColumnDefinitions.Add(new ColumnDefinition());
        var edit = new Button { Content = "Edit Job", HorizontalAlignment = HorizontalAlignment.Stretch, IsEnabled = !_store.IsBusy(job) };
        edit.Click += (_, _) => _actions.Edit(job);
        var again = new Button { Content = "Run Again", HorizontalAlignment = HorizontalAlignment.Stretch, Style = JobsUi.Res<Style>("AccentButtonStyle"), IsEnabled = !_store.IsBusy(job) };
        again.Click += (_, _) => _actions.RunNow(job);
        SetColumn(again, 1);
        buttons.Children.Add(edit);
        buttons.Children.Add(again);
        p.Children.Add(buttons);
        var card = JobsUi.Card(p, new Thickness(14));
        card.Background = JobsUi.Brush("SystemFillColorCriticalBackgroundBrush");
        card.BorderThickness = new Thickness(0);
        card.Margin = new Thickness(0, 4, 0, 4);
        AutomationProperties.SetAutomationId(card, "job.error");
        _column.Children.Add(card);
    }

    private void Schedule(CronJob job)
    {
        var state = JobWords.JobState(job);
        var paused = JobWords.IsPaused(job);
        var now = DateTimeOffset.Now;
        var rows = new StackPanel();
        void Add(UIElement row) { if (rows.Children.Count > 0) rows.Children.Add(JobsUi.Separator()); rows.Children.Add(row); }
        Add(JobsUi.Labeled("Repeats", JobWords.ScheduleWords(job)));
        if (state != "completed" && state != "disabled" && (paused || !string.IsNullOrEmpty(job.NextRunAt)))
        {
            if (paused) Add(JobsUi.Labeled("Next Run", "Paused"));
            else if (JobWords.NextRunOverdue(job, now) != null) Add(JobsUi.Labeled("Overdue Since", JobWords.RelativeDateTime(job.NextRunAt, now)));
            else if (!string.IsNullOrEmpty(job.NextRunAt)) Add(JobsUi.Labeled("Next Run", JobWords.RelativeDateTime(job.NextRunAt, now)));
        }
        if (!string.IsNullOrEmpty(job.LastRunAt))
        {
            var failed = !string.IsNullOrEmpty(job.LastError) || (job.LastStatus ?? "").ToLowerInvariant() is "error" or "failed" or "fail";
            Add(JobsUi.Labeled("Last Run", $"{JobWords.RelativeDateTime(job.LastRunAt)} · {(failed ? "Failed" : "OK")}"));
        }
        _column.Children.Add(JobsUi.Header("Schedule"));
        _column.Children.Add(JobsUi.Card(rows, new Thickness(16, 4, 16, 4)));
    }

    private void Delivery(CronJob job)
    {
        var p = new StackPanel { Spacing = 4 };
        p.Children.Add(JobsUi.Text("Delivers To", 14));
        var to = JobsUi.Text(JobWords.HumanDeliver(job.Deliver ?? "", job.Origin, JobDelivery.Labels, JobWords.KnownChatNames(_store.Jobs)), 13, JobsUi.Secondary);
        AutomationProperties.SetAutomationId(to, "job.delivers");
        p.Children.Add(to);
        if (!string.IsNullOrEmpty(job.Model))
        {
            p.Children.Add(JobsUi.Separator());
            p.Children.Add(JobsUi.Labeled("Model", ModelNames.DisplayModelName(job.Model)));
        }
        var card = JobsUi.Card(p);
        card.Margin = new Thickness(0, 12, 0, 0);
        _column.Children.Add(card);
    }

    private void Prompt(CronJob job)
    {
        var text = JobWords.JobDescription(job);
        if (text.Length == 0) return;
        var scriptOnly = JobWords.JobIsScriptOnly(job) && string.IsNullOrEmpty(job.Prompt);
        _column.Children.Add(JobsUi.Header(scriptOnly ? "Script" : "Prompt"));
        var p = new StackPanel { Spacing = 8 };
        var body = JobsUi.Text(text, 14, maxLines: _promptOpen ? 0 : 6);
        body.IsTextSelectionEnabled = true;
        if (scriptOnly) body.FontFamily = JobsUi.Res<FontFamily>("CodeFont");
        AutomationProperties.SetAutomationId(body, "job.prompt");
        p.Children.Add(body);
        if (!_promptOpen && (text.Split('\n').Length > 6 || text.Length > 480))
        {
            var all = new HyperlinkButton { Content = "Show All", Padding = new Thickness(0), FontWeight = FontWeights.SemiBold };
            all.Click += (_, _) => { _promptOpen = true; Render(); };
            p.Children.Add(all);
        }
        _column.Children.Add(JobsUi.Card(p));
    }

    private void RunHistory(CronJob job)
    {
        var note = JobWords.LastRunNote(job);
        var head = new StackPanel { Margin = new Thickness(16, 16, 0, 6), Spacing = 2 };
        head.Children.Add(JobsUi.Text(_runs.Count == 0 ? "Run History" : $"Run History · {_runs.Count}", 13, bold: true));
        if (note != null) head.Children.Add(JobsUi.Text(note, 12, JobsUi.Secondary));
        _column.Children.Add(head);
        var rows = new StackPanel();
        if (!_runsLoaded) rows.Children.Add(new ProgressRing { IsActive = true, Width = 20, Height = 20, Margin = new Thickness(0, 6, 0, 6) });
        else if (_runs.Count == 0)
            rows.Children.Add(JobsUi.Text(_runsFailed ? "Couldn’t load the run history." : note == null ? "No saved runs yet" : "No output saved from its runs", 14, JobsUi.Secondary));
        else
        {
            foreach (var run in _runs)
            {
                if (rows.Children.Count > 0) rows.Children.Add(JobsUi.Separator());
                var label = JobWords.CronRunLabel(run);
                var opens = run.Opens is RunOpens.Chat || (run.Opens is RunOpens.Document && !string.IsNullOrEmpty(job.HermesHome));
                var g = new Grid { Padding = new Thickness(0, 6, 0, 6) };
                g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                var words = new StackPanel { Spacing = 2 };
                words.Children.Add(JobsUi.Text(label.Title, 14));
                if (label.Detail.Length > 0) words.Children.Add(JobsUi.Text(label.Detail, 12, label.Detail.StartsWith("Failed") ? JobsUi.Red : JobsUi.Secondary));
                g.Children.Add(words);
                if (opens)
                {
                    var chevron = JobsUi.Glyph("", 12, JobsUi.Tertiary);
                    SetColumn(chevron, 1);
                    g.Children.Add(chevron);
                    var b = new Button
                    {
                        Content = g, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
                        Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0), Padding = new Thickness(0),
                    };
                    AutomationProperties.SetName(b, $"{label.Title}, {label.Detail}");
                    AutomationProperties.SetAutomationId(b, "job.run-row." + run.Id);
                    var r = run;
                    b.Click += (_, _) => _openRun(job, r);
                    rows.Children.Add(b);
                }
                else rows.Children.Add(g);
            }
        }
        _column.Children.Add(JobsUi.Card(rows, new Thickness(16, 6, 16, 6)));
    }
}
