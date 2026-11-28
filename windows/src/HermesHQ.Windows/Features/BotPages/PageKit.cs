using Hermes.Core.BotPages;
using HermesHQ.Services;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;

namespace HermesHQ.Features.BotPages;

/// Pieces the More pages share (App/Pages/More/Kit/MorePageKit.swift): grouped cards at a readable width, fact rows,
/// the page states (loading with the slow note, error with Try Again / Copy Details, empty, "No Results"), the bot
/// picker for per-bot pages, the status dot line, the restart notice, and the app's alerts. Built in code (no XAML).
public static class Kit
{
    public static T Res<T>(string key) => ThemeBrushes.Res<T>(key);
    public static Brush Secondary => Res<Brush>("TextFillColorSecondaryBrush");
    public static Brush Tertiary => Res<Brush>("TextFillColorTertiaryBrush");
    public static Brush Accent => Res<Brush>("AccentTextFillColorPrimaryBrush");
    public static Brush Red => new SolidColorBrush(ColorHelper.FromArgb(255, 0xE5, 0x3E, 0x3E));
    public static Brush Orange => new SolidColorBrush(ColorHelper.FromArgb(255, 0xF0, 0x8A, 0x00));
    public static Brush Green => new SolidColorBrush(ColorHelper.FromArgb(255, 0x30, 0xB9, 0x4D));

    /// Desktop readable width for Windows forms and lists.
    public const double ReadableWidth = 1120;

    public static TextBlock Text(string text, double size = 14, Brush? color = null, bool bold = false, bool wrap = true,
        int maxLines = 0) => new()
    {
        Text = text,
        FontSize = size,
        FontWeight = bold ? FontWeights.SemiBold : FontWeights.Normal,
        TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap,
        TextTrimming = TextTrimming.CharacterEllipsis,
        MaxLines = maxLines,
        Foreground = color ?? Res<Brush>("HQLabelBrush"),
        IsTextSelectionEnabled = false,
    };

    public static TextBlock Mono(string text, double size = 12) => new()
    {
        Text = text, FontSize = size, FontFamily = Res<FontFamily>("CodeFont"), TextWrapping = TextWrapping.Wrap,
        IsTextSelectionEnabled = true,
    };

    /// A section's heading over its card (HQSectionLabel).
    public static TextBlock SectionLabel(string text) => new()
    {
        Text = text, FontSize = 12, FontWeight = FontWeights.SemiBold, Foreground = Secondary, Margin = new Thickness(12, 16, 0, 6),
    };

    /// A section's footnote under its card (HQSectionFooter).
    public static TextBlock Footer(string text, Brush? color = null) => new()
    {
        Text = text, FontSize = 12, Foreground = color ?? Secondary, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(12, 6, 12, 0),
    };

    /// A grouped card: rows with a hairline between them.
    public static Border Card(params UIElement[] rows)
    {
        var stack = new StackPanel();
        for (var i = 0; i < rows.Length; i++)
        {
            if (i > 0) stack.Children.Add(new Border { Height = 1, Background = Res<Brush>("DividerStrokeColorDefaultBrush"), Margin = new Thickness(14, 0, 0, 0) });
            stack.Children.Add(rows[i]);
        }
        return new Border
        {
            Child = stack, CornerRadius = new CornerRadius(8), BorderThickness = new Thickness(1),
            Background = Res<Brush>("CardBackgroundFillColorDefaultBrush"), BorderBrush = Res<Brush>("CardStrokeColorDefaultBrush"),
        };
    }

    /// A card's row: content padded as the Mac form's row (44 px tall at least).
    public static Grid Row(UIElement left, UIElement? right = null, double minHeight = 44)
    {
        var g = new Grid { Padding = new Thickness(14, 8, 14, 8), MinHeight = minHeight, ColumnSpacing = 12 };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (left is FrameworkElement fl) fl.VerticalAlignment = VerticalAlignment.Center;
        g.Children.Add(left);
        if (right != null)
        {
            if (right is FrameworkElement fr) fr.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn((FrameworkElement)right, 1);
            g.Children.Add(right);
        }
        return g;
    }

    /// "Label ……… value": the value in grey; right-click copies it.
    public static Grid Fact(string label, string value, bool copyable = true)
    {
        var v = Text(value, 14, Secondary, wrap: true);
        v.TextAlignment = TextAlignment.Right;
        v.HorizontalAlignment = HorizontalAlignment.Right;
        var row = Row(Text(label), v);
        AutomationProperties.SetName(row, $"{label}, {value}");
        if (copyable) row.ContextFlyout = CopyMenu(value);
        return row;
    }

    public static MenuFlyout CopyMenu(string value)
    {
        var copy = new MenuFlyoutItem { Text = "Copy", Icon = new FontIcon { Glyph = "" } };
        copy.Click += (_, _) => CopyText(value);
        var m = new MenuFlyout();
        m.Items.Add(copy);
        return m;
    }

    public static void CopyText(string value) => SafeClipboard.TrySetText(value);

    /// The Mac's quiet chevron at a row's end.
    public static FontIcon Chevron() => new() { Glyph = "", FontSize = 11, Foreground = Tertiary };

    /// A row that opens something: the whole row clicks, a chevron at its end.
    public static Button LinkRow(UIElement content, Action open, bool chevron = true, string? name = null)
    {
        var inner = Row(content, chevron ? Chevron() : null);
        inner.Padding = new Thickness(0);
        var b = new Button
        {
            Content = inner, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Background = new SolidColorBrush(Colors.Transparent), BorderThickness = new Thickness(0),
            Padding = new Thickness(14, 8, 14, 8), MinHeight = 44, CornerRadius = new CornerRadius(8),
        };
        if (name != null) AutomationProperties.SetName(b, name);
        b.Click += (_, _) => open();
        return b;
    }

    public static Button Push(string title, Action click, bool accent = false, bool destructive = false)
    {
        var b = new Button { Content = title };
        if (accent) b.Style = Res<Style>("AccentButtonStyle");
        if (destructive) b.Foreground = Red;
        b.Click += (_, _) => click();
        return b;
    }

    /// A status dot and its words; an error is written in red (MessagingStatusLine, MoreStatusLine).
    public static StackPanel StatusLine(string text, Brush dot, bool error = false, int lines = 2)
    {
        var s = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        s.Children.Add(new Microsoft.UI.Xaml.Shapes.Ellipse { Width = 8, Height = 8, Fill = dot, VerticalAlignment = VerticalAlignment.Center });
        s.Children.Add(Text(text, 13, error ? Red : Secondary, maxLines: lines));
        return s;
    }

    /// The page body: a scrolling column that tracks the ScrollViewer's live ViewportWidth so resizing sideways never offsets or clips cards.
    public static ScrollViewer Column(out StackPanel content, double width = ReadableWidth)
    {
        var panel = new StackPanel { Padding = new Thickness(24, 8, 24, 28), HorizontalAlignment = HorizontalAlignment.Stretch };
        content = panel;
        var scroll = new ScrollViewer
        {
            Content = panel,
            HorizontalScrollMode = ScrollMode.Disabled,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
        };
        scroll.SizeChanged += (_, _) =>
        {
            if (scroll.ViewportWidth > 0)
                panel.Width = scroll.ViewportWidth;
        };
        return scroll;
    }

    // ------------------------------------------------------------------ page states

    /// A state centred in the page: a glyph, a title, a line, and its buttons (MoreEmptyState / ContentUnavailableView).
    public static FrameworkElement State(string glyph, string title, string text, params Button[] actions)
    {
        var s = new StackPanel { Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
            MaxWidth = 440, Margin = new Thickness(20, 40, 20, 60) };
        s.Children.Add(new FontIcon { Glyph = glyph, FontSize = 36, Foreground = Tertiary, Margin = new Thickness(0, 0, 0, 4) });
        var t = Text(title, 18, bold: true);
        t.TextAlignment = TextAlignment.Center;
        s.Children.Add(t);
        if (text.Length > 0)
        {
            var b = Text(text, 14, Secondary);
            b.TextAlignment = TextAlignment.Center;
            s.Children.Add(b);
        }
        if (actions.Length > 0)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center,
                Margin = new Thickness(0, 8, 0, 0) };
            foreach (var a in actions) row.Children.Add(a);
            s.Children.Add(row);
        }
        return s;
    }

    /// A first read that failed with nothing to show: the reason, Try Again and Copy Details. A page this Hermes doesn't
    /// have isn't a failure: its own line under "Not Available on This Hermes", and no buttons (MoreErrorState).
    public static FrameworkElement Error(string title, string reason, Action retry, string? page = null, string? glyph = null)
    {
        if (reason == PagesRest.OlderHermes)
            return State(glyph ?? "", PagesRest.NotAvailableTitle, PagesRest.NotAvailableBody(page ?? PagesRest.PageName(title)));
        var copy = new Button { Content = "Copy Details" };
        copy.Click += async (_, _) =>
        {
            CopyText($"{title}\n{reason}");
            copy.Content = "Copied";
            await Task.Delay(2000);
            copy.Content = "Copy Details";
        };
        return State("", title, reason, Push("Try Again", retry), copy);
    }

    /// "No Results for “words”" (PageStates.searchMiss).
    public static FrameworkElement SearchMiss(string words) => State("", ListSearch.MissTitle(words), ListSearch.MissText);

    public const string SlowPage = "Still loading… Your gateway is taking longer than usual.";

    /// Skeleton rows while a first read is on its way; still there after 15 s it says the gateway is slow, with Try Again.
    public static FrameworkElement Loading(string label, Action? retry = null)
    {
        var s = new StackPanel { Spacing = 10, MaxWidth = ReadableWidth, Padding = new Thickness(20, 16, 20, 0), HorizontalAlignment = HorizontalAlignment.Stretch };
        AutomationProperties.SetName(s, label);
        var slow = new StackPanel { Spacing = 6, Visibility = Visibility.Collapsed };
        slow.Children.Add(Text(SlowPage, 13, Secondary));
        if (retry != null) slow.Children.Add(Push("Try Again", retry));
        s.Children.Add(slow);
        s.Children.Add(new ProgressRing { IsActive = true, Width = 24, Height = 24, HorizontalAlignment = HorizontalAlignment.Left });
        for (var i = 0; i < 6; i++)
            s.Children.Add(new Border { Height = 40, CornerRadius = new CornerRadius(6), Background = Res<Brush>("SubtleFillColorSecondaryBrush") });
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(15) };
        timer.Tick += (_, _) => { timer.Stop(); slow.Visibility = Visibility.Visible; };
        s.Loaded += (_, _) => timer.Start();
        s.Unloaded += (_, _) => timer.Stop();
        return s;
    }

    // ------------------------------------------------------------------ the bot picker

    /// The bot a per-bot page reads (MoreBotPicker): "Bot" and a pop-up of the bots, shown only with more than one bot.
    public static Grid BotPicker(string title, IReadOnlyList<Hermes.Core.Model.Bot> bots, string selected, Action<string> changed)
    {
        var box = new ComboBox { MinWidth = 180 };
        foreach (var b in bots) box.Items.Add(new ComboBoxItem { Content = b.DisplayName, Tag = b.Name });
        box.SelectedIndex = Math.Max(0, bots.ToList().FindIndex(b => b.Name == selected));
        AutomationProperties.SetName(box, title);
        box.SelectionChanged += (_, _) => { if (box.SelectedItem is ComboBoxItem { Tag: string id }) changed(id); };
        var left = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        if (bots.FirstOrDefault(b => b.Name == selected) is { } bot)
            left.Children.Add(new Controls.BotHead { Bot = bot, DisplayName = bot.DisplayName, Width = 28, Height = 28 });
        left.Children.Add(new TextBlock { Text = title, VerticalAlignment = VerticalAlignment.Center });
        return Row(left, box);
    }

    // ------------------------------------------------------------------ dialogs

    public static async Task<ContentDialogResult> Show(XamlRoot? root, ContentDialog dialog)
    {
        if (root == null) return ContentDialogResult.None;
        dialog.XamlRoot = root;
        try { return await dialog.ShowAsync(); }
        catch (Exception x) when (x is InvalidOperationException or System.Runtime.InteropServices.COMException)
        {
            AppLog.Note("pages", "a dialog was already open");
            return ContentDialogResult.None;
        }
    }

    /// "Title?" · message · Action / Cancel (TextPrompt.confirm).
    public static async Task<bool> Confirm(XamlRoot? root, string title, string message, string action, bool destructive = true) =>
        await Show(root, new ContentDialog
        {
            Title = title, Content = Text(message), PrimaryButtonText = action, CloseButtonText = "Cancel",
            DefaultButton = destructive ? ContentDialogButton.Close : ContentDialogButton.Primary,
        }) == ContentDialogResult.Primary;

    /// A refused write's alert: its title, the reason, and Try Again when it can be (FailureAlert.present).
    public static async Task Failure(XamlRoot? root, string title, string reason, Func<Task>? retry = null)
    {
        var d = new ContentDialog { Title = title, Content = Text(reason), CloseButtonText = "OK", DefaultButton = ContentDialogButton.Close };
        if (retry != null) d.PrimaryButtonText = "Try Again";
        if (await Show(root, d) == ContentDialogResult.Primary && retry != null) await retry();
    }

    /// The Mac's HUD: a short line that shows for a moment ("Copied", "Instructions Saved").
    public static void Hud(Panel? host, string text)
    {
        if (host == null || AppShutdown.Stopping) return;
        var tip = new TeachingTip { Title = text, IsLightDismissEnabled = true, PreferredPlacement = TeachingTipPlacementMode.Bottom };
        host.Children.Add(tip);
        tip.IsOpen = true;
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1.6) };
        void Cleanup(object? s, object e)
        {
            timer.Stop();
            host.Unloaded -= Cleanup;
            tip.IsOpen = false;
            host.Children.Remove(tip);
        }
        host.Unloaded += Cleanup;
        timer.Tick += Cleanup;
        timer.Start();
    }

    /// The restart notice with its Restart Gateway… button and progress (GatewayRestartNotice, GatewayRestartProgress).
    public static FrameworkElement RestartNotice(string text, GatewayActionRun run, bool canWrite, Action restart, bool onlyProgress = false)
    {
        var col = new StackPanel { Spacing = 8 };
        if (!onlyProgress)
        {
            var head = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            head.Children.Add(new FontIcon { Glyph = "", FontSize = 14, Foreground = Orange });
            head.Children.Add(Text(text));
            col.Children.Add(head);
        }
        if (GatewayRestartWords.Words(run.Current) is { } w)
        {
            var p = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            if (w.IsBusy) p.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
            p.Children.Add(Text(w.Text, 13, w.IsError ? Red : w.IsBusy || run.Current is GatewayActionRun.Phase.Untracked ? Secondary : Green));
            col.Children.Add(p);
        }
        if (!onlyProgress && canWrite && !run.IsBusy)
        {
            var b = Push(GatewayRestartWords.Button, restart);
            b.HorizontalAlignment = HorizontalAlignment.Left;
            col.Children.Add(b);
        }
        var g = Row(col);
        return Card(g);
    }

    /// Restart Your Gateway? · Restart / Cancel.
    public static Task<bool> ConfirmRestart(XamlRoot? root) =>
        Confirm(root, GatewayRestartWords.ConfirmTitle, GatewayRestartWords.ConfirmMessage, GatewayRestartWords.ConfirmAction, destructive: false);

    public static void OnEnter(Control c, Action run)
    {
        c.KeyDown += (_, e) => { if (e.Key == VirtualKey.Enter) { e.Handled = true; run(); } };
    }
}
