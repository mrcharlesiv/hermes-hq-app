using Hermes.Core.Activity;
using Hermes.Core.Chat;
using Hermes.Core.Net;
using HermesHQ.Services;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Features.Transcript;

/// Client-side timing for one running job so elapsed time and output freshness tick smoothly between 5 s polls.
/// Port of App/Chat/Activity/BackgroundTasksBody.swift `BackgroundTaskTiming`.
public sealed record BackgroundTaskTiming(DateTimeOffset ObservedAt, DateTimeOffset? OutputChangedAt);

/// The Background tasks panel in the chat's activity shelf (App/Chat/Activity/BackgroundTasksBody.swift &
/// ChatActivityController.swift `backgroundPoll`, `showBackground`, `stopBackground`, commits d79144d27 & ba08fcdd4):
/// 5 s `process.list` poll, list rows with spinner / purpose headline / detail + freshness / multi-line monospace
/// output preview / live elapsed timer / `⋯` menu, and responsive split-pane detail view at `>= 600px` with full
/// unclipped wrapping headline, Stop (`process.kill`), Watching, Output (+ Copy + Show All), Folder, and Command
/// (+ Copy + Show Full).
public sealed class BackgroundTasksPanel : UserControl
{
    public const double WideWidth = 600;
    public const int FoldedOutputLines = 12;
    public const int FoldedCommandLines = 6;
    public static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(5);

    private readonly ChatSession _session;
    private readonly ActivityStore _store;
    private readonly DispatcherQueue? _ui;
    private readonly Grid _host = new();

    private List<BackgroundProcess> _processes = [];
    private readonly Dictionary<string, BackgroundTaskTiming> _timing = new(StringComparer.Ordinal);
    private readonly Dictionary<string, string> _lastTails = new(StringComparer.Ordinal);
    private readonly HashSet<string> _stopping = new(StringComparer.Ordinal);
    private readonly HashSet<string> _expandedOutput = new(StringComparer.Ordinal);
    private readonly HashSet<string> _expandedCommand = new(StringComparer.Ordinal);
    private readonly Dictionary<string, (TextBlock Timer, TextBlock Detail)> _rowTickTargets = new(StringComparer.Ordinal);
    private TextBlock? _detailTimer;
    private TextBlock? _detailMeta;

    private string? _selectedId;
    private bool _wide;
    private double _lastWidth;
    private bool _attached;
    private bool _unsupported;
    private CancellationTokenSource? _pollCts;
    private Task? _pollTask;
    private DispatcherQueueTimer? _tickTimer;

    /// Running background processes as last observed from `process.list`.
    public IReadOnlyList<BackgroundProcess> RunningProcesses => _processes;

    /// Raised on the UI thread whenever the running process list or stopping state changes.
    public event Action? ProcessesChanged;

    public BackgroundTasksPanel(ChatSession session, ActivityStore store)
    {
        _session = session;
        _store = store;
        _ui = DispatcherQueue ?? Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
        Content = _host;
        AutomationProperties.SetAutomationId(this, "chat.background.list");
        SizeChanged += OnSizeChanged;
        Loaded += (_, _) => UpdateTicker();
        Unloaded += (_, _) => StopTicker();
    }

    /// Starts or stops the chat's 5 s `backgroundPoll` lifecycle (called by `ActivityShelf` on load/unload).
    public void SetAttached(bool on)
    {
        if (_attached == on) return;
        _attached = on;
        if (on)
        {
            _session.Changed += OnSessionStateChanged;
            _session.RuntimeBound += OnRuntimeBound;
            EnsurePolling();
        }
        else
        {
            _session.Changed -= OnSessionStateChanged;
            _session.RuntimeBound -= OnRuntimeBound;
            StopPolling();
            StopTicker();
            UiTree.DeactivateProgressRings(_host);
        }
    }

    /// Re-kicks the 5 s poll when a turn starts/ends or the runtime binds (ChatActivityController.pollBackground).
    public void EnsurePolling()
    {
        if (!_attached || _unsupported || AppShutdown.Stopping) return;
        if (_pollTask is { IsCompleted: false }) return;
        if (_session.RuntimeId is null) return;

        var cts = new CancellationTokenSource();
        _pollCts = cts;
        _pollTask = Task.Run(() => BackgroundPollLoopAsync(cts.Token), CancellationToken.None);
    }

    private void StopPolling()
    {
        var cts = _pollCts;
        _pollCts = null;
        _pollTask = null;
        if (cts is null) return;
        try { cts.Cancel(); } catch (ObjectDisposedException) { }
        try { cts.Dispose(); } catch (ObjectDisposedException) { }
    }

    private void OnSessionStateChanged() =>
        _ui?.TryEnqueue(() =>
        {
            if (_attached && !AppShutdown.Stopping && (_session.Busy || _processes.Count > 0))
                EnsurePolling();
        });

    private void OnRuntimeBound(string _) =>
        _ui?.TryEnqueue(() =>
        {
            if (_attached && !AppShutdown.Stopping) EnsurePolling();
        });

    private async Task BackgroundPollLoopAsync(CancellationToken ct)
    {
        var first = true;
        try
        {
            while (!ct.IsCancellationRequested && _attached && !_unsupported && !AppShutdown.Stopping)
            {
                if (!first) await Task.Delay(PollInterval, ct).ConfigureAwait(false);
                first = false;
                if (ct.IsCancellationRequested || !_attached || _unsupported || AppShutdown.Stopping) break;

                var runtimeId = _session.RuntimeId;
                if (string.IsNullOrEmpty(runtimeId)) break;

                IReadOnlyList<BackgroundProcess>? fetched;
                try
                {
                    fetched = await BackgroundProcessesApi.ListProcessesAsync(_session.Client, runtimeId, _session.Profile, ct)
                        .ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (ct.IsCancellationRequested)
                {
                    break;
                }
                catch (GatewayException)
                {
                    // Transient error keeps the last known list; retry next round if still working.
                    if (_processes.Count == 0 && !_session.Busy) break;
                    continue;
                }
                catch (Exception)
                {
                    if (_processes.Count == 0 && !_session.Busy) break;
                    continue;
                }

                if (ct.IsCancellationRequested || AppShutdown.Stopping) break;

                if (fetched is null)
                {
                    _unsupported = true;
                    DispatchApply([], runtimeId);
                    break;
                }

                var running = fetched.Where(p => p.IsRunning).ToList();
                DispatchApply(running, runtimeId);

                if (running.Count == 0 && !_session.Busy) break;
            }
        }
        catch (OperationCanceledException) { }
        finally
        {
            _pollTask = null;
        }
    }

    private void DispatchApply(List<BackgroundProcess> running, string runtimeId)
    {
        if (_ui is null || AppShutdown.Stopping) return;
        _ui.TryEnqueue(() =>
        {
            if (AppShutdown.Stopping) return;
            ApplyFetched(running, runtimeId);
        });
    }

    /// Applies a freshly fetched list of running background processes, enriching headlines from the transcript
    /// and updating `ActivityStore.ProcessClaim` entries.
    public void ApplyFetched(IReadOnlyList<BackgroundProcess> fetched, string? runtimeId = null)
    {
        var allMessages = _session.Messages;
        var recent = allMessages.Count > 300 ? allMessages.Skip(allMessages.Count - 300).ToList() : allMessages;
        var now = DateTimeOffset.UtcNow;

        var enriched = new List<BackgroundProcess>(fetched.Count);
        foreach (var job in fetched) enriched.Add(job.WithTranscriptMatch(recent));

        var ids = new HashSet<string>(enriched.Select(j => j.Id), StringComparer.Ordinal);
        var freshnessChanged = false;
        foreach (var job in enriched)
        {
            _lastTails.TryGetValue(job.Id, out var priorTail);
            var priorChanged = _timing.TryGetValue(job.Id, out var priorTiming) ? priorTiming.OutputChangedAt : null;
            DateTimeOffset? changedAt;
            if (job.LastOutputAt is { } serverAt)
                changedAt = serverAt;
            else if (priorTail is not null && job.OutputTail != priorTail && !string.IsNullOrEmpty(job.OutputTail))
                changedAt = now;
            else
                changedAt = priorChanged;

            if (changedAt != priorChanged) freshnessChanged = true;
            _lastTails[job.Id] = job.OutputTail ?? "";
            _timing[job.Id] = new BackgroundTaskTiming(now, changedAt);
        }

        foreach (var key in _lastTails.Keys.Where(k => !ids.Contains(k)).ToList()) _lastTails.Remove(key);
        foreach (var key in _timing.Keys.Where(k => !ids.Contains(k)).ToList()) _timing.Remove(key);
        _stopping.IntersectWith(ids);
        _expandedOutput.IntersectWith(ids);
        _expandedCommand.IntersectWith(ids);
        if (_selectedId is not null && !ids.Contains(_selectedId)) _selectedId = null;

        var rid = runtimeId ?? _session.RuntimeId ?? _store.RuntimeId;
        if (!string.IsNullOrEmpty(rid))
        {
            lock (_store)
            {
                _store.SetProcessClaims(rid, _session.Profile, _session.StoredId,
                    enriched.Select(j => new ActivityStore.ProcessClaim(j.Id, Running: true)));
            }
        }

        var listChanged = !_processes.SequenceEqual(enriched);
        _processes = enriched;
        if (!listChanged && !freshnessChanged) return;

        Rebuild();
        UpdateTicker();
        ProcessesChanged?.Invoke();
    }

    private void OnSizeChanged(object sender, SizeChangedEventArgs e)
    {
        var width = e.NewSize.Width;
        var nextWide = width >= WideWidth;
        var widthShifted = nextWide && Math.Abs(width - _lastWidth) > 24;
        if (nextWide != _wide || widthShifted)
        {
            _wide = nextWide;
            _lastWidth = width;
            Rebuild();
        }
    }

    private void UpdateTicker()
    {
        if (!IsLoaded || _processes.Count == 0 || AppShutdown.Stopping)
        {
            StopTicker();
            return;
        }
        if (_tickTimer is not null) return;
        if (_ui is null) return;
        _tickTimer = _ui.CreateTimer();
        _tickTimer.Interval = TimeSpan.FromSeconds(1);
        _tickTimer.Tick += (_, _) => TickTimers();
        _tickTimer.Start();
    }

    private void StopTicker()
    {
        if (_tickTimer is null) return;
        _tickTimer.Stop();
        _tickTimer = null;
    }

    /// Ticks elapsed timers and freshness readouts in place without rebuilding the visual tree.
    private void TickTimers()
    {
        if (AppShutdown.Stopping || _processes.Count == 0) { StopTicker(); return; }
        var now = DateTimeOffset.UtcNow;
        foreach (var job in _processes)
        {
            _timing.TryGetValue(job.Id, out var timing);
            var elapsed = job.ElapsedSeconds(timing?.ObservedAt, now) is { } sec ? BackgroundProcess.FormatDuration(sec) : "";
            if (_rowTickTargets.TryGetValue(job.Id, out var targets))
            {
                if (targets.Timer.Text != elapsed) targets.Timer.Text = elapsed;
                var detailText = ComposeDetail(job, timing, now) ?? "";
                if (targets.Detail.Text != detailText) targets.Detail.Text = detailText;
            }
            if (job.Id == _selectedId)
            {
                if (_detailTimer is not null && _detailTimer.Text != elapsed) _detailTimer.Text = elapsed;
                if (_detailMeta is not null)
                {
                    var meta = ComposeMetaLine(job, timing, now) ?? "";
                    _detailMeta.Visibility = meta.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
                    if (_detailMeta.Text != meta) _detailMeta.Text = meta;
                }
            }
        }
    }

    /// Forces a layout refresh of the list and detail pane.
    public void Rebuild()
    {
        UiTree.DeactivateProgressRings(_host);
        _host.Children.Clear();
        _host.ColumnDefinitions.Clear();
        _host.RowDefinitions.Clear();
        _rowTickTargets.Clear();
        _detailTimer = null;
        _detailMeta = null;

        if (_processes.Count == 0) return;

        var width = ActualWidth > 0 ? ActualWidth : _lastWidth;
        var wide = width >= WideWidth;
        _wide = wide;

        if (wide && _selectedId is null) _selectedId = _processes[0].Id;
        var selectedJob = _selectedId is null ? null : _processes.FirstOrDefault(p => p.Id == _selectedId);
        if (selectedJob is null) _selectedId = null;

        var now = DateTimeOffset.UtcNow;

        if (wide)
        {
            var listWidth = Math.Clamp(Math.Round(width * 0.38), 230, 300);
            _host.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(listWidth) });
            _host.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            _host.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

            var listScroll = new ScrollViewer
            {
                Content = BuildList(wide: true, now),
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
                MaxHeight = 360,
            };
            _host.Children.Add(listScroll);

            var divider = new Border
            {
                Width = 1,
                Margin = new Thickness(8, 2, 8, 2),
                Background = ThemeBrushes.Get("CardStrokeColorDefaultBrush"),
            };
            Grid.SetColumn(divider, 1);
            _host.Children.Add(divider);

            FrameworkElement detailContent = selectedJob is not null
                ? BuildDetailView(selectedJob, now)
                : new TextBlock
                {
                    Text = "Choose a background task to see its output.",
                    FontSize = 12,
                    Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center,
                    Margin = new Thickness(12),
                };
            var detailScroll = new ScrollViewer
            {
                Content = detailContent,
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
                MaxHeight = 360,
            };
            Grid.SetColumn(detailScroll, 2);
            _host.Children.Add(detailScroll);
        }
        else if (selectedJob is not null)
        {
            var stack = new StackPanel { Spacing = 6 };
            var back = new HyperlinkButton
            {
                Content = _processes.Count == 1 ? "‹ All Background Tasks" : $"‹ All {_processes.Count} Background Tasks",
                Padding = new Thickness(4, 2, 4, 2),
                FontSize = 12,
            };
            AutomationProperties.SetAutomationId(back, "chat.background.back");
            back.Click += (_, _) => { _selectedId = null; Rebuild(); };
            stack.Children.Add(back);
            stack.Children.Add(BuildDetailView(selectedJob, now));

            _host.Children.Add(new ScrollViewer
            {
                Content = stack,
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
                MaxHeight = 360,
            });
        }
        else
        {
            _host.Children.Add(new ScrollViewer
            {
                Content = BuildList(wide: false, now),
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
                MaxHeight = 320,
            });
        }
    }

    private FrameworkElement BuildList(bool wide, DateTimeOffset now)
    {
        var list = new StackPanel { Spacing = 4 };
        foreach (var job in _processes)
            list.Children.Add(BuildRow(job, picked: wide && job.Id == _selectedId, drillIn: !wide, now));
        return list;
    }

    private FrameworkElement BuildRow(BackgroundProcess job, bool picked, bool drillIn, DateTimeOffset now)
    {
        var stopping = _stopping.Contains(job.Id);
        _timing.TryGetValue(job.Id, out var timing);
        var elapsed = job.ElapsedSeconds(timing?.ObservedAt, now) is { } sec ? BackgroundProcess.FormatDuration(sec) : "";
        var detailText = ComposeDetail(job, timing, now);

        var outer = new Border
        {
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(8, 6, 6, 6),
            Background = picked ? ThemeBrushes.Get("HQPressedBrush") : ThemeBrushes.Get("SubtleFillColorSecondaryBrush"),
        };
        AutomationProperties.SetAutomationId(outer, "chat.background.row." + job.Id);

        var outerGrid = new Grid { ColumnSpacing = 4 };
        outerGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        outerGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var root = new StackPanel { Spacing = 4 };

        // Top line: spinner · headline · elapsed · chevron
        var top = new Grid { ColumnSpacing = 6 };
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        if (!stopping)
        {
            var ring = new ProgressRing
            {
                IsActive = true,
                Width = 14,
                Height = 14,
                VerticalAlignment = VerticalAlignment.Top,
                Margin = new Thickness(0, 2, 0, 0),
            };
            top.Children.Add(ring);
        }

        var title = new TextBlock
        {
            Text = job.Headline,
            FontSize = 13,
            FontWeight = FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
            MaxLines = 2,
            TextTrimming = TextTrimming.CharacterEllipsis,
        };
        AutomationProperties.SetAutomationId(title, "chat.background.title");
        Grid.SetColumn(title, 1);
        top.Children.Add(title);

        var timer = new TextBlock
        {
            Text = elapsed,
            FontSize = 11.5,
            FontFamily = Res<FontFamily>("CodeFont"),
            Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 1, 0, 0),
        };
        Grid.SetColumn(timer, 2);
        top.Children.Add(timer);

        if (drillIn)
        {
            var chevron = new FontIcon
            {
                Glyph = "\uE76C",
                FontSize = 10,
                Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
                VerticalAlignment = VerticalAlignment.Center,
            };
            Grid.SetColumn(chevron, 3);
            top.Children.Add(chevron);
        }
        root.Children.Add(top);

        // Detail + freshness line
        var detail = new TextBlock
        {
            Text = detailText ?? "",
            FontSize = 11.5,
            Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxLines = 1,
            Margin = new Thickness(20, 0, 0, 0),
            Visibility = string.IsNullOrEmpty(detailText) ? Visibility.Collapsed : Visibility.Visible,
        };
        AutomationProperties.SetAutomationId(detail, "chat.background.detail");
        root.Children.Add(detail);
        _rowTickTargets[job.Id] = (timer, detail);

        // Output preview box or quiet line
        var hasOutput = !stopping && job.LastLine.Length > 0;
        if (hasOutput)
        {
            var previewStack = new StackPanel { Spacing = 2 };
            if (job.EarlierPreviewLines.Count > 0)
            {
                previewStack.Children.Add(new TextBlock
                {
                    Text = string.Join("\n", job.EarlierPreviewLines),
                    FontFamily = Res<FontFamily>("CodeFont"),
                    FontSize = 11,
                    Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
                    TextTrimming = TextTrimming.CharacterEllipsis,
                    MaxLines = 2,
                    TextWrapping = TextWrapping.Wrap,
                });
            }
            var newest = new TextBlock
            {
                Text = job.LastLine,
                FontFamily = Res<FontFamily>("CodeFont"),
                FontSize = 11.5,
                Foreground = ThemeBrushes.Get("TextFillColorPrimaryBrush"),
                TextTrimming = TextTrimming.CharacterEllipsis,
                MaxLines = 2,
                TextWrapping = TextWrapping.Wrap,
            };
            AutomationProperties.SetAutomationId(newest, "chat.background.output");
            previewStack.Children.Add(newest);

            root.Children.Add(new Border
            {
                Child = previewStack,
                CornerRadius = new CornerRadius(6),
                Padding = new Thickness(8, 5, 8, 5),
                Margin = new Thickness(20, 2, 2, 0),
                Background = ThemeBrushes.Get("HQPromptCardBrush"),
                BorderBrush = ThemeBrushes.Get("HQPromptEdgeBrush"),
                BorderThickness = new Thickness(1),
            });
        }
        else
        {
            var quiet = new TextBlock
            {
                Text = stopping ? "Stopping…" : job.StatusLine,
                FontSize = 11.5,
                Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
                TextTrimming = TextTrimming.CharacterEllipsis,
                MaxLines = 2,
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(20, 0, 4, 0),
            };
            AutomationProperties.SetAutomationId(quiet, "chat.background.output");
            root.Children.Add(quiet);
        }

        // Selectable row content beside the sibling ⋯ action button (avoids nested Button elements).
        var clickHost = new Button
        {
            Content = root,
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
            Padding = new Thickness(0),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
        };
        var id = job.Id;
        clickHost.Click += (_, _) => { _selectedId = id; Rebuild(); };
        AutomationProperties.SetName(clickHost, $"{job.Headline}, running" + (elapsed.Length == 0 ? "" : $" for {elapsed}"));
        outerGrid.Children.Add(clickHost);

        var moreBtn = BuildMoreButton(job, stopping);
        moreBtn.VerticalAlignment = VerticalAlignment.Top;
        Grid.SetColumn(moreBtn, 1);
        outerGrid.Children.Add(moreBtn);

        outer.Child = outerGrid;
        return outer;
    }

    private Button BuildMoreButton(BackgroundProcess job, bool stopping)
    {
        var menu = new MenuFlyout();
        var id = job.Id;

        var detailsItem = new MenuFlyoutItem { Text = "View Details", Icon = new FontIcon { Glyph = "\uE946" } };
        detailsItem.Click += (_, _) => { _selectedId = id; Rebuild(); };
        menu.Items.Add(detailsItem);

        if (job.CleanOutput.Length > 0)
        {
            var output = job.CleanOutput;
            var copyOutput = new MenuFlyoutItem { Text = "Copy Output", Icon = new FontIcon { Glyph = "\uE8C8" } };
            copyOutput.Click += (_, _) => SafeClipboard.TrySetText(output);
            menu.Items.Add(copyOutput);
        }

        var fullCommand = job.EffectiveCommand;
        var copyCommand = new MenuFlyoutItem { Text = "Copy Command", Icon = new FontIcon { Glyph = "\uE756" } };
        copyCommand.Click += (_, _) => SafeClipboard.TrySetText(fullCommand);
        menu.Items.Add(copyCommand);

        var stopItem = new MenuFlyoutItem
        {
            Text = "Stop Task",
            Icon = new FontIcon { Glyph = "\uE71A" },
            Foreground = ThemeBrushes.Get("HQRedBrush"),
        };
        stopItem.Click += (_, _) => _ = StopProcessAsync(id);
        menu.Items.Add(stopItem);

        var more = new Button
        {
            Content = new FontIcon { Glyph = "\uE712", FontSize = 12 },
            Flyout = menu,
            IsEnabled = !stopping,
            Padding = new Thickness(6, 2, 6, 2),
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
        };
        AutomationProperties.SetName(more, "Task Actions");
        AutomationProperties.SetAutomationId(more, "chat.background.more");
        return more;
    }

    /// Detail view: unclipped wrapping `FullHeadline` (ba08fcdd4), status + timer + Stop, metadata,
    /// Output (+ Copy + Show All), Watching patterns/hit, optional BotNote, Folder, and Command (+ Copy + Show Full).
    private FrameworkElement BuildDetailView(BackgroundProcess job, DateTimeOffset now)
    {
        var stopping = _stopping.Contains(job.Id);
        _timing.TryGetValue(job.Id, out var timing);
        var elapsed = job.ElapsedSeconds(timing?.ObservedAt, now) is { } sec ? BackgroundProcess.FormatDuration(sec) : "";
        var id = job.Id;

        var column = new StackPanel { Spacing = 8, Padding = new Thickness(4, 2, 4, 6) };
        AutomationProperties.SetAutomationId(column, "chat.background.detail-view");

        // Full unclipped wrapping headline (ba08fcdd4: never truncated to the list row's 80/90-char cap).
        var headline = new TextBlock
        {
            Text = job.FullHeadline,
            FontSize = 14.5,
            FontWeight = FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
        };
        AutomationProperties.SetAutomationId(headline, "chat.background.detail.title");
        column.Children.Add(headline);

        // Status + live elapsed timer + Stop button
        var statusRow = new Grid { ColumnSpacing = 8 };
        statusRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        statusRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        statusRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var statusText = new TextBlock { FontSize = 12.5, VerticalAlignment = VerticalAlignment.Center };
        statusText.Inlines.Add(new Run
        {
            Text = "● ",
            Foreground = ThemeBrushes.Get(stopping ? "HQOrangeBrush" : "HQGreenBrush"),
        });
        statusText.Inlines.Add(new Run
        {
            Text = stopping ? "Stopping…" : "Running",
            FontWeight = FontWeights.SemiBold,
        });
        statusRow.Children.Add(statusText);

        _detailTimer = new TextBlock
        {
            Text = elapsed,
            FontSize = 12,
            FontFamily = Res<FontFamily>("CodeFont"),
            Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(_detailTimer, 1);
        statusRow.Children.Add(_detailTimer);

        var stopBtn = new Button
        {
            Content = stopping ? "Stopping…" : "Stop",
            IsEnabled = !stopping,
            FontSize = 12,
            Padding = new Thickness(10, 3, 10, 3),
            CornerRadius = new CornerRadius(6),
            Foreground = ThemeBrushes.Get("HQRedBrush"),
        };
        AutomationProperties.SetName(stopBtn, "Stop Task");
        AutomationProperties.SetAutomationId(stopBtn, "chat.background.detail.stop");
        stopBtn.Click += (_, _) => _ = StopProcessAsync(id);
        Grid.SetColumn(stopBtn, 2);
        statusRow.Children.Add(stopBtn);
        column.Children.Add(statusRow);

        // Metadata line: runner/folder · Started … · Updated … · PID …
        var metaText = ComposeMetaLine(job, timing, now) ?? "";
        _detailMeta = new TextBlock
        {
            Text = metaText,
            FontSize = 11.5,
            Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
            TextWrapping = TextWrapping.Wrap,
            Visibility = metaText.Length > 0 ? Visibility.Visible : Visibility.Collapsed,
        };
        AutomationProperties.SetAutomationId(_detailMeta, "chat.background.detail.meta");
        column.Children.Add(_detailMeta);

        // Output section (right under header so live output is visible without scrolling)
        var cleaned = job.CleanOutput;
        var outSection = new StackPanel { Spacing = 4, Margin = new Thickness(0, 4, 0, 0) };
        outSection.Children.Add(BuildSectionHeader("Output", cleaned.Length > 0 ? () => SafeClipboard.TrySetText(cleaned) : null, "chat.background.copy-output", "Copy Output"));

        if (cleaned.Length == 0)
        {
            var quietOut = new TextBlock
            {
                Text = stopping ? "Stopping…" : job.StatusLine,
                FontFamily = Res<FontFamily>("CodeFont"),
                FontSize = 12,
                Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
                TextWrapping = TextWrapping.Wrap,
            };
            AutomationProperties.SetAutomationId(quietOut, "chat.background.detail.output");
            outSection.Children.Add(CodeCard(quietOut));
        }
        else
        {
            var lines = cleaned.Split('\n');
            var folds = lines.Length > FoldedOutputLines;
            var expanded = _expandedOutput.Contains(id);
            var shown = folds && !expanded ? string.Join("\n", lines[^FoldedOutputLines..]) : cleaned;
            var outText = new TextBlock
            {
                Text = shown,
                FontFamily = Res<FontFamily>("CodeFont"),
                FontSize = 12,
                TextWrapping = TextWrapping.Wrap,
                IsTextSelectionEnabled = true,
            };
            AutomationProperties.SetAutomationId(outText, "chat.background.detail.output");
            outSection.Children.Add(CodeCard(outText));
            if (folds)
            {
                var toggle = new HyperlinkButton
                {
                    Content = expanded ? "Show Less" : $"Show All {lines.Length} Lines",
                    FontSize = 12,
                    Padding = new Thickness(0, 2, 0, 2),
                };
                AutomationProperties.SetAutomationId(toggle, "chat.background.output-toggle");
                toggle.Click += (_, _) =>
                {
                    if (!_expandedOutput.Add(id)) _expandedOutput.Remove(id);
                    Rebuild();
                };
                outSection.Children.Add(toggle);
            }
        }
        column.Children.Add(outSection);

        // Watching section (patterns / matched hit)
        var watchLine = ComposeWatchLine(job);
        if (!string.IsNullOrEmpty(watchLine))
        {
            var watchSection = new StackPanel { Spacing = 2, Margin = new Thickness(0, 4, 0, 0) };
            watchSection.Children.Add(SectionTitle("Watching"));
            watchSection.Children.Add(new TextBlock
            {
                Text = watchLine,
                FontSize = 12,
                Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
                TextWrapping = TextWrapping.Wrap,
                IsTextSelectionEnabled = true,
            });
            column.Children.Add(watchSection);
        }

        // Optional bot context paragraph
        if (!string.IsNullOrEmpty(job.BotNote))
        {
            var note = new TextBlock
            {
                Text = job.BotNote,
                FontSize = 12,
                TextWrapping = TextWrapping.Wrap,
                IsTextSelectionEnabled = true,
            };
            column.Children.Add(CodeCard(note));
        }

        // Folder section
        if (!string.IsNullOrEmpty(job.Cwd))
        {
            var folderSection = new StackPanel { Spacing = 2, Margin = new Thickness(0, 4, 0, 0) };
            folderSection.Children.Add(SectionTitle("Folder"));
            folderSection.Children.Add(new TextBlock
            {
                Text = job.Cwd,
                FontFamily = Res<FontFamily>("CodeFont"),
                FontSize = 12,
                TextWrapping = TextWrapping.Wrap,
                IsTextSelectionEnabled = true,
            });
            column.Children.Add(folderSection);
        }

        // Command section
        var fullCmd = job.EffectiveCommand.Trim();
        if (fullCmd.Length > 0)
        {
            var cmdSection = new StackPanel { Spacing = 4, Margin = new Thickness(0, 4, 0, 0) };
            cmdSection.Children.Add(BuildSectionHeader("Command", () => SafeClipboard.TrySetText(fullCmd), "chat.background.copy-command", "Copy Command"));

            var cmdLines = fullCmd.Split('\n');
            var folds = cmdLines.Length > FoldedCommandLines;
            var expanded = _expandedCommand.Contains(id);
            var shown = folds && !expanded ? string.Join("\n", cmdLines[..FoldedCommandLines]) : fullCmd;
            var cmdText = new TextBlock
            {
                Text = shown,
                FontFamily = Res<FontFamily>("CodeFont"),
                FontSize = 12,
                TextWrapping = TextWrapping.Wrap,
                IsTextSelectionEnabled = true,
            };
            AutomationProperties.SetAutomationId(cmdText, "chat.background.detail.command");
            cmdSection.Children.Add(CodeCard(cmdText));
            if (folds)
            {
                var toggle = new HyperlinkButton
                {
                    Content = expanded ? "Show Less" : $"Show Full Command ({cmdLines.Length} Lines)",
                    FontSize = 12,
                    Padding = new Thickness(0, 2, 0, 2),
                };
                AutomationProperties.SetAutomationId(toggle, "chat.background.command-toggle");
                toggle.Click += (_, _) =>
                {
                    if (!_expandedCommand.Add(id)) _expandedCommand.Remove(id);
                    Rebuild();
                };
                cmdSection.Children.Add(toggle);
            }
            column.Children.Add(cmdSection);
        }

        return column;
    }

    private async Task StopProcessAsync(string processId)
    {
        var runtimeId = _session.RuntimeId;
        if (string.IsNullOrEmpty(runtimeId)) return;

        _stopping.Add(processId);
        Rebuild();
        ProcessesChanged?.Invoke();

        try
        {
            var killed = await BackgroundProcessesApi.KillProcessAsync(_session.Client, runtimeId, processId, _session.Profile);
            if (!killed)
            {
                _stopping.Remove(processId);
                await ShowStopFailureAsync("Your gateway couldn’t stop this task.");
            }
        }
        catch (GatewayException e)
        {
            _stopping.Remove(processId);
            AppLog.Note("activity", $"process.kill failed: {e.Code}");
            await ShowStopFailureAsync(e.PlainReason);
        }
        catch (Exception e)
        {
            _stopping.Remove(processId);
            AppLog.Note("activity", $"process.kill failed: {e.GetType().Name}");
            await ShowStopFailureAsync("Your gateway couldn’t stop this task.");
        }

        // Refresh the list immediately after stopping so removed processes disappear without waiting 5 s.
        try
        {
            if (_session.RuntimeId is { } rid)
            {
                var list = await BackgroundProcessesApi.ListProcessesAsync(_session.Client, rid, _session.Profile);
                if (list is not null) ApplyFetched(list.Where(p => p.IsRunning).ToList(), rid);
            }
        }
        catch (Exception) { }

        Rebuild();
        ProcessesChanged?.Invoke();
    }

    private async Task ShowStopFailureAsync(string reason)
    {
        if (XamlRoot is null) return;
        var dlg = new ContentDialog
        {
            Title = "Couldn’t Stop the Task",
            Content = new TextBlock { Text = reason, TextWrapping = TextWrapping.Wrap },
            CloseButtonText = "OK",
            DefaultButton = ContentDialogButton.Close,
        };
        await SafeDialog.ShowAsync(XamlRoot, dlg);
    }

    private static string? ComposeDetail(BackgroundProcess job, BackgroundTaskTiming? timing, DateTimeOffset now)
    {
        var parts = new List<string>(2);
        if (!string.IsNullOrEmpty(job.DetailLine)) parts.Add(job.DetailLine);
        if (timing?.OutputChangedAt is { } changed)
            parts.Add(BackgroundProcess.FormatFreshness(changed, now));
        else if (job.LastOutputAt is { } last)
            parts.Add(BackgroundProcess.FormatFreshness(last, now));
        return parts.Count == 0 ? null : string.Join(" · ", parts);
    }

    private static string? ComposeMetaLine(BackgroundProcess job, BackgroundTaskTiming? timing, DateTimeOffset now)
    {
        var parts = new List<string>(4);
        if (!string.IsNullOrEmpty(job.DetailLine)) parts.Add(job.DetailLine);
        if (job.StartDate(timing?.ObservedAt) is { } start)
        {
            var local = start.ToLocalTime();
            var formatted = local.Date == DateTimeOffset.Now.Date ? local.ToString("t") : local.ToString("g");
            parts.Add($"Started {formatted}");
        }
        if (timing?.OutputChangedAt is { } changed)
            parts.Add(BackgroundProcess.FormatFreshness(changed, now));
        else if (job.LastOutputAt is { } last)
            parts.Add(BackgroundProcess.FormatFreshness(last, now));
        if (job.Pid is { } pid) parts.Add($"PID {pid}");
        return parts.Count == 0 ? null : string.Join(" · ", parts);
    }

    private static string? ComposeWatchLine(BackgroundProcess job)
    {
        var parts = new List<string>(2);
        if (job.WatchPatterns.Count > 0) parts.Add(string.Join(" · ", job.WatchPatterns));
        if (!string.IsNullOrEmpty(job.WatchHit)) parts.Add($"Matched: {job.WatchHit}");
        return parts.Count == 0 ? null : string.Join("\n", parts);
    }

    private static Grid BuildSectionHeader(string title, Action? onCopy, string copyAutomationId, string copyLabel)
    {
        var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.Children.Add(SectionTitle(title));
        if (onCopy is not null)
        {
            var copy = new HyperlinkButton
            {
                Content = "Copy",
                FontSize = 12,
                Padding = new Thickness(4, 0, 4, 0),
            };
            AutomationProperties.SetName(copy, copyLabel);
            AutomationProperties.SetAutomationId(copy, copyAutomationId);
            copy.Click += (_, _) => onCopy();
            Grid.SetColumn(copy, 1);
            row.Children.Add(copy);
        }
        return row;
    }

    private static TextBlock SectionTitle(string text) => new()
    {
        Text = text,
        FontSize = 12,
        FontWeight = FontWeights.SemiBold,
        Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
        VerticalAlignment = VerticalAlignment.Center,
    };

    private static Border CodeCard(UIElement child) => new()
    {
        Child = child,
        CornerRadius = new CornerRadius(8),
        Padding = new Thickness(10, 8, 10, 8),
        Background = ThemeBrushes.Get("SubtleFillColorSecondaryBrush"),
    };

    private static T Res<T>(string key) => ThemeBrushes.Res<T>(key);
}
