using System.Globalization;
using Hermes.Core.Groups;
using HermesHQ.Features.Bots;
using HermesHQ.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Features.Groups;

/// [WIN-57] A room's Activity sheet (App/Groups/GroupInfoSheet.swift GroupActivityController / GroupActivityView), as
/// the room's ⋯ › Activity opens it: titled "Activity", the current turn's events newest first, each its symbol, its
/// words (red for a failure or a timeout) and its time in the secondary colour; with none, "No activity in this turn
/// yet.". It follows the store while open, as the Mac's observes it. Esc closes it (the dialog's own key), as Done does.
/// The words and the order are Hermes.Core.Groups.GroupActivitySheet's. On the Mac it is a page pushed in Group Info's
/// sheet; here it is its own sheet.
public static class GroupActivityDialog
{
    /// The sheet on screen, for the automation run (Services/ProofWalks.GroupActivity.cs).
    public static ContentDialog? Current { get; private set; }
    public static string? ShownTitle => Current?.Title as string;
    public static IReadOnlyList<GroupActivitySheet.Row> ShownRows { get; private set; } = [];
    /// The empty note's words while it shows, else null.
    public static string? ShownEmpty { get; private set; }

    public static async Task ShowAsync(XamlRoot root, ListsHub hub, string key)
    {
        if (Current != null) return;
        var list = new StackPanel { Spacing = 0, MinWidth = 380 };
        AutomationProperties.SetAutomationId(list, GroupActivitySheet.ListId);
        var dialog = new ContentDialog
        {
            Title = GroupActivitySheet.Title, CloseButtonText = "Done", XamlRoot = root, DefaultButton = ContentDialogButton.Close,
            Content = new ScrollViewer { Content = list, MaxHeight = 460, HorizontalScrollMode = ScrollMode.Disabled },
        };
        void Fill() => Draw(list, hub, key);
        void Changed() => dialog.DispatcherQueue.TryEnqueue(Fill);
        Fill();
        hub.Groups.Changed += Changed;
        Current = dialog;
        try { await dialog.ShowAsync(); }
        catch (Exception x) when (x is InvalidOperationException or System.Runtime.InteropServices.COMException) { AppLog.Note("groups", "activity not shown"); }
        finally
        {
            hub.Groups.Changed -= Changed;
            if (Current == dialog) { Current = null; ShownRows = []; ShownEmpty = null; }
        }
    }

    private static void Draw(StackPanel list, ListsHub hub, string key)
    {
        var store = hub.Groups;
        var labels = store.Room(key) is { } room ? store.Labels(store.Seated(room)) : new Dictionary<string, string>();
        foreach (var e in store.Activity(key))   // a member the store doesn't label: the roster's name, as before
            if (e.Member.Length > 0 && !labels.ContainsKey(e.Member) && hub.Bots.Bot(e.Member)?.Model?.DisplayName is { } name) labels[e.Member] = name;
        var rows = GroupActivitySheet.Rows(store.Activity(key), labels, TimeZoneInfo.Local, CultureInfo.CurrentCulture);
        if (rows.SequenceEqual(ShownRows) && list.Children.Count > 0) return;
        ShownRows = rows;
        list.Children.Clear();
        if (rows.Count == 0)
        {
            ShownEmpty = GroupActivitySheet.Empty;
            var empty = new TextBlock { Text = GroupActivitySheet.Empty, Margin = new Thickness(0, 6, 0, 6), Foreground = Brush("TextFillColorSecondaryBrush"), TextWrapping = TextWrapping.Wrap };
            AutomationProperties.SetAutomationId(empty, GroupActivitySheet.EmptyId);
            list.Children.Add(empty);
            return;
        }
        ShownEmpty = null;
        for (var i = 0; i < rows.Count; i++)
        {
            var row = rows[i];
            var red = Brush("SystemFillColorCriticalBrush");
            var grid = new Grid { ColumnSpacing = 12, Padding = new Thickness(0, 6, 0, 6) };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(24) });
            grid.ColumnDefinitions.Add(new ColumnDefinition());
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var icon = new FontIcon { Glyph = row.Glyph, FontSize = 14, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 2, 0, 0), Foreground = row.Red ? red : Brush("TextFillColorSecondaryBrush") };
            AutomationProperties.SetAccessibilityView(icon, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);   // .accessibilityHidden(true)
            var words = new TextBlock { Text = row.Text, TextWrapping = TextWrapping.Wrap, Foreground = row.Red ? red : Brush("TextFillColorPrimaryBrush") };
            AutomationProperties.SetAutomationId(words, GroupActivitySheet.RowId(i) + ".text");
            var time = new TextBlock { Text = row.Time, FontSize = 12, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 2, 0, 0), Foreground = Brush("TextFillColorSecondaryBrush") };
            Microsoft.UI.Xaml.Documents.Typography.SetNumeralAlignment(time, FontNumeralAlignment.Tabular);   // .monospacedDigit()
            AutomationProperties.SetAutomationId(time, GroupActivitySheet.RowId(i) + ".time");
            grid.Children.Add(icon);
            Grid.SetColumn(words, 1);
            grid.Children.Add(words);
            Grid.SetColumn(time, 2);
            grid.Children.Add(time);
            AutomationProperties.SetAutomationId(grid, GroupActivitySheet.RowId(i));
            AutomationProperties.SetName(grid, row.AccessibleName);   // read as one (.accessibilityElement(children: .combine))
            if (i > 0) list.Children.Add(new Border { Height = 1, Margin = new Thickness(36, 0, 0, 0), Background = Brush("DividerStrokeColorDefaultBrush") });
            list.Children.Add(grid);
        }
    }

    public static void Close() => Current?.Hide();

    private static Brush Brush(string key) => ThemeBrushes.Get(key);
}
