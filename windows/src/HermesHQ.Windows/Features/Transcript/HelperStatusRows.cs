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

/// Consolidated helper disclosure rows and `subagent.tail` detail dialog (App/Chat/HelperStatusRows.swift,
/// App/Chat/UpdatesSheet.swift `HelperStatusSheetViewController`, and App/Chat/Activity/SubagentBodies.swift
/// `SubagentDetailView`). Replaces the minimal 1-line "Background Worker" stub with steps, files, and full output.
public static class HelperStatusRows
{
    /// Consolidated summary title for a group of helpers ("2 helpers working · 1 done", "1 helper failed").
    public static string BuildSummaryText(IReadOnlyList<SubagentProgress> helpers) =>
        HelperReport.SummarizeStatus(helpers);

    /// One compact disclosure row for a request's helpers: spinner/glyph, consolidated status summary, goal preview,
    /// and trailing chevron. Clicking opens either the single helper's `subagent.tail` detail dialog or the
    /// consolidated group sheet listing every helper in the batch.
    public static FrameworkElement BuildDisclosureRow(
        ChatSession session,
        IReadOnlyList<SubagentProgress> helpers,
        ActivityStore? store = null,
        Action? onClick = null)
    {
        var summary = BuildSummaryText(helpers);
        var anyLive = helpers.Any(h => h.IsLive);
        var anyFailed = helpers.Any(h => h.Status == SubagentStatus.Failed);
        var preview = string.Join(" · ", helpers.Select(h => h.Goal).Where(g => !string.IsNullOrWhiteSpace(g)).Take(3));

        var grid = new Grid { ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        if (anyLive)
        {
            grid.Children.Add(new ProgressRing
            {
                IsActive = true,
                Width = 14,
                Height = 14,
                VerticalAlignment = VerticalAlignment.Center,
            });
        }
        else
        {
            grid.Children.Add(new FontIcon
            {
                Glyph = anyFailed ? "\uE783" : "\uE99A",
                FontSize = 13,
                Foreground = ThemeBrushes.Get(anyFailed ? "SystemFillColorCriticalBrush" : "TextFillColorSecondaryBrush"),
                VerticalAlignment = VerticalAlignment.Center,
            });
        }

        var textCol = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        textCol.Children.Add(new TextBlock
        {
            Text = summary.Length > 0 ? summary : "Helpers",
            FontSize = 12.5,
            FontWeight = FontWeights.SemiBold,
            Foreground = ThemeBrushes.Get(anyFailed && !anyLive ? "SystemFillColorCriticalBrush" : "TextFillColorPrimaryBrush"),
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxLines = 1,
        });
        if (preview.Length > 0)
        {
            textCol.Children.Add(new TextBlock
            {
                Text = preview,
                FontSize = 11.5,
                Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
                TextTrimming = TextTrimming.CharacterEllipsis,
                MaxLines = 1,
            });
        }
        Grid.SetColumn(textCol, 1);
        grid.Children.Add(textCol);

        var chevron = new FontIcon
        {
            Glyph = "\uE76C",
            FontSize = 10,
            Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(chevron, 2);
        grid.Children.Add(chevron);

        var button = new Button
        {
            Content = grid,
            Background = ThemeBrushes.Get("SubtleFillColorSecondaryBrush"),
            BorderBrush = ThemeBrushes.Get("CardStrokeColorDefaultBrush"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(10, 6, 10, 6),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
        };
        AutomationProperties.SetAutomationId(button, "chat.helpers.disclosure");
        AutomationProperties.SetName(button, summary.Length > 0 ? summary : "Helpers");

        button.Click += async (_, _) =>
        {
            if (onClick is not null)
            {
                onClick();
                return;
            }
            if (helpers.Count == 1)
                await ShowTailDialogAsync(button.XamlRoot, session, helpers[0], store);
            else if (helpers.Count > 1)
                await ShowGroupDialogAsync(button.XamlRoot, session, helpers, store);
        };
        return button;
    }

    /// Shows the consolidated Helpers sheet for a multi-helper batch; choosing any row opens its `subagent.tail` detail.
    public static async Task ShowGroupDialogAsync(
        XamlRoot? xamlRoot,
        ChatSession session,
        IReadOnlyList<SubagentProgress> helpers,
        ActivityStore? store = null)
    {
        if (xamlRoot is null || AppShutdown.Stopping || helpers.Count == 0) return;

        SubagentProgress? drillInto = null;
        var list = new StackPanel { Spacing = 6, MinWidth = 460 };
        list.Children.Add(new TextBlock
        {
            Text = BuildSummaryText(helpers),
            FontSize = 12,
            Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
        });

        ContentDialog? dialog = null;
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;
        foreach (var child in helpers)
        {
            var item = child;
            var rowGrid = new Grid { ColumnSpacing = 8 };
            rowGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            rowGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            var left = new StackPanel { Spacing = 2 };
            left.Children.Add(new TextBlock
            {
                Text = item.Goal,
                FontSize = 13,
                FontWeight = FontWeights.SemiBold,
                TextWrapping = TextWrapping.Wrap,
                MaxLines = 2,
                TextTrimming = TextTrimming.CharacterEllipsis,
            });
            left.Children.Add(new TextBlock
            {
                Text = SubagentWords.RowLine(item),
                FontSize = 12,
                Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
                TextTrimming = TextTrimming.CharacterEllipsis,
                MaxLines = 1,
            });
            rowGrid.Children.Add(left);

            var right = new TextBlock
            {
                Text = $"{SubagentWords.Status(item.Status)} · {SubagentWords.Timer(item, now)}",
                FontSize = 11.5,
                Foreground = ThemeBrushes.Get(item.Status == SubagentStatus.Failed ? "SystemFillColorCriticalBrush" : "TextFillColorSecondaryBrush"),
                VerticalAlignment = VerticalAlignment.Center,
            };
            Grid.SetColumn(right, 1);
            rowGrid.Children.Add(right);

            var rowBtn = new Button
            {
                Content = rowGrid,
                Background = ThemeBrushes.Get("SubtleFillColorSecondaryBrush"),
                BorderThickness = new Thickness(0),
                CornerRadius = new CornerRadius(8),
                Padding = new Thickness(10, 8, 10, 8),
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Stretch,
            };
            AutomationProperties.SetAutomationId(rowBtn, "chat.helpers.group.row." + item.Id);
            rowBtn.Click += (_, _) =>
            {
                drillInto = item;
                dialog?.Hide();
            };
            list.Children.Add(rowBtn);
        }

        dialog = new ContentDialog
        {
            Title = "Helpers",
            Content = new ScrollViewer
            {
                Content = list,
                MaxHeight = 460,
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            },
            CloseButtonText = "Done",
            DefaultButton = ContentDialogButton.Close,
        };
        await SafeDialog.ShowAsync(xamlRoot, dialog);

        if (drillInto is not null)
            await ShowTailDialogAsync(xamlRoot, session, drillInto, store);
    }

    /// Shows the helper's detail dialog with steps, touched files, summary, and full `subagent.tail` output
    /// (gracefully falling back to the local snapshot when offline or when `subagent.tail` is unsupported).
    public static async Task ShowTailDialogAsync(
        XamlRoot? xamlRoot,
        ChatSession session,
        SubagentProgress child,
        ActivityStore? store = null)
    {
        if (xamlRoot is null || AppShutdown.Stopping) return;

        var ui = DispatcherQueue.GetForCurrentThread();
        var body = new StackPanel { Spacing = 10, MinWidth = 480, MaxWidth = 620 };
        var outputHost = new StackPanel { Spacing = 4 };
        var stepsHost = new StackPanel { Spacing = 4 };
        var filesHost = new StackPanel { Spacing = 4 };
        var summaryHost = new StackPanel { Spacing = 4 };
        var outputExpanded = false;

        // Full wrapping goal headline
        body.Children.Add(new TextBlock
        {
            Text = child.Goal,
            FontSize = 15,
            FontWeight = FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
        });

        // Status + stats + elapsed timer
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;
        body.Children.Add(BuildStatusLine(child, now));

        body.Children.Add(summaryHost);
        body.Children.Add(stepsHost);
        body.Children.Add(filesHost);
        body.Children.Add(outputHost);

        // Seed from any already-cached tail in ActivityStore before the RPC completes.
        HelperTailReport? initialTail = null;
        if (store is not null)
        {
            SubagentTail? cached = null;
            lock (store)
            {
                if (store.Snapshot.Tails.TryGetValue(child.Id, out var t)) cached = t;
            }
            if (cached is not null)
            {
                initialTail = new HelperTailReport(
                    child.Id,
                    cached.Available,
                    BackgroundProcess.CleanTail(cached.Text),
                    cached.Truncated,
                    ValueList<HelperTailStep>.Empty,
                    ValueList<HelperTailFile>.Empty);
            }
        }

        var currentReport = HelperTailReport.Combine(child, initialTail);
        var loading = !string.IsNullOrEmpty(session.RuntimeId) && !child.IsDelegateStandIn;
        string? fetchNote = null;

        void Render()
        {
            UiTree.DeactivateProgressRings(body);
            RenderSummary(summaryHost, child, currentReport);
            RenderSteps(stepsHost, child, currentReport);
            RenderFiles(filesHost, currentReport);
            RenderOutput(outputHost, currentReport, loading, fetchNote, outputExpanded, () =>
            {
                outputExpanded = !outputExpanded;
                Render();
            });
        }

        Render();

        using var cts = new CancellationTokenSource();
        if (loading && session.RuntimeId is { } rid)
        {
            _ = Task.Run(async () =>
            {
                HelperTailReport? fetched = null;
                string? note = null;
                try
                {
                    fetched = await BackgroundProcessesApi.ReadSubagentTailAsync(
                        session.Client, rid, child.Id, session.Profile, cts.Token).ConfigureAwait(false);
                    if (fetched is null)
                    {
                        note = "Live output isn’t supported by this gateway.";
                    }
                    else if (store is not null)
                    {
                        lock (store)
                        {
                            store.ApplyTail(child.Id, new System.Text.Json.Nodes.JsonObject
                            {
                                ["available"] = fetched.Available,
                                ["text"] = fetched.Output,
                                ["truncated"] = fetched.Truncated,
                            });
                        }
                    }
                }
                catch (OperationCanceledException)
                {
                    return;
                }
                catch (GatewayException e)
                {
                    AppLog.Note("activity", $"subagent.tail failed: {e.Code}");
                    note = "Live output unavailable while offline.";
                }
                catch (Exception e)
                {
                    AppLog.Note("activity", $"subagent.tail failed: {e.GetType().Name}");
                    note = "Live output unavailable.";
                }

                if (cts.IsCancellationRequested || AppShutdown.Stopping) return;
                ui?.TryEnqueue(() =>
                {
                    if (cts.IsCancellationRequested || AppShutdown.Stopping) return;
                    loading = false;
                    fetchNote = note;
                    if (fetched is not null) currentReport = HelperTailReport.Combine(child, fetched);
                    Render();
                });
            }, CancellationToken.None);
        }

        var scroll = new ScrollViewer
        {
            Content = body,
            MaxHeight = 520,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        };
        var dialog = new ContentDialog
        {
            Title = "Helper Details",
            Content = scroll,
            CloseButtonText = "Done",
            DefaultButton = ContentDialogButton.Close,
        };
        AutomationProperties.SetAutomationId(dialog, "chat.helpers.tail.dialog");

        try
        {
            await SafeDialog.ShowAsync(xamlRoot, dialog);
        }
        finally
        {
            cts.Cancel();
            UiTree.DeactivateProgressRings(body);
            if (child.Status == SubagentStatus.Failed && store is not null)
            {
                lock (store) store.AcknowledgeHelperFailure(child.Id);
            }
        }
    }

    private static FrameworkElement BuildStatusLine(SubagentProgress child, double now)
    {
        var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var dotBrushKey = child.Status switch
        {
            SubagentStatus.Completed => "HQGreenBrush",
            SubagentStatus.Failed => "HQRedBrush",
            SubagentStatus.Interrupted => "HQOrangeBrush",
            SubagentStatus.Running => "HQTintBrush",
            _ => "TextFillColorSecondaryBrush",
        };
        var text = new TextBlock { FontSize = 12.5, TextWrapping = TextWrapping.Wrap };
        text.Inlines.Add(new Run { Text = "● ", Foreground = ThemeBrushes.Get(dotBrushKey) });
        text.Inlines.Add(new Run { Text = SubagentWords.Status(child.Status), FontWeight = FontWeights.SemiBold });

        var details = new List<string>(3);
        if (!string.IsNullOrWhiteSpace(child.Model)) details.Add(child.Model);
        if (child.ToolCount is > 0)
            details.Add(child.ToolCount.Value == 1 ? "1 tool" : $"{ActivityJson.JsNumber(child.ToolCount.Value)} tools");
        var tokens = (child.InputTokens ?? 0) + (child.OutputTokens ?? 0);
        if (tokens > 0) details.Add($"{SubagentRules.CompactNumber(tokens)} tok");
        if (details.Count > 0)
        {
            text.Inlines.Add(new Run
            {
                Text = " · " + string.Join(" · ", details),
                Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
            });
        }
        row.Children.Add(text);

        var timer = new TextBlock
        {
            Text = SubagentWords.Timer(child, now),
            FontSize = 12,
            FontFamily = Res<FontFamily>("CodeFont"),
            Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(timer, 1);
        row.Children.Add(timer);
        return row;
    }

    private static void RenderSummary(StackPanel host, SubagentProgress child, HelperTailReport report)
    {
        host.Children.Clear();
        var summary = child.IsLive ? null : report.Summary;
        if (string.IsNullOrWhiteSpace(summary))
        {
            host.Visibility = Visibility.Collapsed;
            return;
        }
        host.Visibility = Visibility.Visible;
        host.Children.Add(new Border
        {
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(10, 8, 10, 8),
            Background = ThemeBrushes.Get("SubtleFillColorSecondaryBrush"),
            Child = new TextBlock
            {
                Text = summary,
                FontSize = 12.5,
                TextWrapping = TextWrapping.Wrap,
                IsTextSelectionEnabled = true,
            },
        });
    }

    private static void RenderSteps(StackPanel host, SubagentProgress child, HelperTailReport report)
    {
        host.Children.Clear();
        var filtered = !child.IsLive && !string.IsNullOrWhiteSpace(report.Summary)
            ? report.Steps.Where(s => s.Kind != SubagentStreamKind.Summary).ToList()
            : report.Steps.ToList();
        if (filtered.Count == 0)
        {
            host.Visibility = Visibility.Collapsed;
            return;
        }
        host.Visibility = Visibility.Visible;
        var shown = filtered.Skip(Math.Max(0, filtered.Count - SubagentWords.ShownSteps)).ToList();
        host.Children.Add(SectionHeader(SubagentWords.StepsHeader(shown.Count, filtered.Count)));

        var card = new StackPanel { Spacing = 4 };
        for (var i = 0; i < shown.Count; i++)
        {
            var entry = shown[i];
            var newest = i == shown.Count - 1 && child.IsLive;
            var row = new Grid { ColumnSpacing = 8 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            row.Children.Add(new FontIcon
            {
                Glyph = StepGlyph(entry),
                FontSize = 11,
                Foreground = ThemeBrushes.Get(entry.IsError ? "HQRedBrush" : newest ? "HQTintBrush" : "TextFillColorSecondaryBrush"),
                VerticalAlignment = VerticalAlignment.Top,
                Margin = new Thickness(0, 2, 0, 0),
            });

            var text = new TextBlock
            {
                Text = entry.Text,
                FontSize = 12,
                TextWrapping = TextWrapping.Wrap,
                Foreground = ThemeBrushes.Get(entry.IsError ? "HQRedBrush" : newest ? "TextFillColorPrimaryBrush" : "TextFillColorSecondaryBrush"),
            };
            Grid.SetColumn(text, 1);
            row.Children.Add(text);

            if (entry.At is { } at && child.StartedAt > 0)
            {
                var offset = new TextBlock
                {
                    Text = SubagentWords.FormatElapsed((int)(at - child.StartedAt)),
                    FontSize = 11,
                    FontFamily = Res<FontFamily>("CodeFont"),
                    Foreground = ThemeBrushes.Get("TextFillColorTertiaryBrush"),
                    VerticalAlignment = VerticalAlignment.Top,
                };
                Grid.SetColumn(offset, 2);
                row.Children.Add(offset);
            }
            card.Children.Add(row);
        }
        host.Children.Add(new Border
        {
            Child = card,
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(10, 8, 10, 8),
            Background = ThemeBrushes.Get("SubtleFillColorSecondaryBrush"),
        });
    }

    private static void RenderFiles(StackPanel host, HelperTailReport report)
    {
        host.Children.Clear();
        if (report.Files.Count == 0)
        {
            host.Visibility = Visibility.Collapsed;
            return;
        }
        host.Visibility = Visibility.Visible;
        var shown = report.Files.Take(SubagentWords.ShownFiles).ToList();
        host.Children.Add(SectionHeader(SubagentWords.FilesHeader(shown.Count, report.Files.Count)));

        var card = new StackPanel { Spacing = 4 };
        foreach (var file in shown)
        {
            var row = new Grid { ColumnSpacing = 8 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

            row.Children.Add(new FontIcon
            {
                Glyph = file.Written ? "\uE70F" : "\uE8A5",
                FontSize = 11,
                Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
                VerticalAlignment = VerticalAlignment.Center,
            });

            var name = Path.GetFileName(file.Path);
            var folder = Path.GetDirectoryName(file.Path) ?? "";
            var label = new TextBlock { FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis, MaxLines = 1 };
            label.Inlines.Add(new Run { Text = string.IsNullOrEmpty(name) ? file.Path : name, FontWeight = FontWeights.SemiBold });
            if (folder.Length > 0)
                label.Inlines.Add(new Run { Text = "  " + folder, Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush") });
            AutomationProperties.SetName(label, SubagentWords.FileAccessibilityLabel(file.Path, file.Written));
            Grid.SetColumn(label, 1);
            row.Children.Add(label);
            card.Children.Add(row);
        }
        host.Children.Add(new Border
        {
            Child = card,
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(10, 8, 10, 8),
            Background = ThemeBrushes.Get("SubtleFillColorSecondaryBrush"),
        });
    }

    private static void RenderOutput(
        StackPanel host,
        HelperTailReport report,
        bool loading,
        string? fetchNote,
        bool expanded,
        Action toggleExpand)
    {
        host.Children.Clear();
        var hasOutput = report.Output.Length > 0;
        if (!loading && !hasOutput && string.IsNullOrEmpty(fetchNote))
        {
            host.Visibility = Visibility.Collapsed;
            return;
        }
        host.Visibility = Visibility.Visible;

        var headerRow = new Grid { ColumnSpacing = 8 };
        headerRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        headerRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var leftHeader = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        leftHeader.Children.Add(SectionHeader("Output"));
        if (loading) leftHeader.Children.Add(new ProgressRing { IsActive = true, Width = 12, Height = 12 });
        headerRow.Children.Add(leftHeader);

        if (hasOutput)
        {
            var copy = new HyperlinkButton { Content = "Copy", FontSize = 12, Padding = new Thickness(4, 0, 4, 0) };
            AutomationProperties.SetName(copy, "Copy Output");
            copy.Click += (_, _) => SafeClipboard.TrySetText(report.Output);
            Grid.SetColumn(copy, 1);
            headerRow.Children.Add(copy);
        }
        host.Children.Add(headerRow);

        if (report.Truncated)
        {
            host.Children.Add(new TextBlock
            {
                Text = SubagentWords.TruncatedOutput,
                FontSize = 11,
                Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
            });
        }

        if (hasOutput)
        {
            var lines = report.Output.Split('\n');
            var folds = lines.Length > SubagentWords.FoldedOutputLines;
            var shown = folds && !expanded ? string.Join("\n", lines[^SubagentWords.FoldedOutputLines..]) : report.Output;

            var outputBox = new TextBox
            {
                AcceptsReturn = true,
                TextWrapping = TextWrapping.Wrap,
                IsReadOnly = true,
                FontFamily = Res<FontFamily>("CodeFont"),
                FontSize = 12,
                MaxHeight = 280,
                Text = shown,
            };
            AutomationProperties.SetAutomationId(outputBox, "chat.helpers.tail.output");
            host.Children.Add(outputBox);

            if (folds)
            {
                var toggle = new HyperlinkButton
                {
                    Content = SubagentWords.OutputToggle(expanded, lines.Length),
                    FontSize = 12,
                    Padding = new Thickness(0, 2, 0, 2),
                };
                AutomationProperties.SetAutomationId(toggle, "chat.subagent.output-toggle");
                toggle.Click += (_, _) => toggleExpand();
                host.Children.Add(toggle);
            }
        }
        else if (loading)
        {
            host.Children.Add(new TextBlock
            {
                Text = "Loading output…",
                FontSize = 12,
                Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
            });
        }
        else if (!string.IsNullOrEmpty(fetchNote))
        {
            host.Children.Add(new TextBlock
            {
                Text = fetchNote,
                FontSize = 12,
                Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
                TextWrapping = TextWrapping.Wrap,
            });
        }
    }

    private static string StepGlyph(HelperTailStep entry)
    {
        if (entry.IsError) return "\uE7BA";
        return entry.Kind switch
        {
            SubagentStreamKind.Thinking => "\uE945",
            SubagentStreamKind.Summary => "\uE73E",
            SubagentStreamKind.Progress => "\uE72A",
            _ => "\uE90F",
        };
    }

    private static TextBlock SectionHeader(string text) => new()
    {
        Text = text,
        FontSize = 12,
        FontWeight = FontWeights.SemiBold,
        Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
    };

    private static T Res<T>(string key) => ThemeBrushes.Res<T>(key);
}
