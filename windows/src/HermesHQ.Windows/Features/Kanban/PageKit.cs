using System.Text.Json.Nodes;
using Hermes.Core;
using Hermes.Core.Kanban;
using Hermes.Core.Model;
using HermesHQ.Controls;
using HermesHQ.Services;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.ApplicationModel.DataTransfer;
using Windows.UI;

namespace HermesHQ.Features.Kanban;

/// The small pieces the Kanban and Tasks pages draw with: theme brushes, text, dialogs, a notice line, bot names and
/// faces. Code-built (no XAML), conservative controls only.
internal static class PageKit
{
    public static Brush Brush(string key) => ThemeBrushes.Get(key);
    public static Style Style(string key) => (Style)Application.Current.Resources[key];
    public static Brush Solid(Color c) => new SolidColorBrush(c);
    public static Color Rgb(byte r, byte g, byte b) => Color.FromArgb(255, r, g, b);

    public static Brush Secondary => Brush("TextFillColorSecondaryBrush");
    public static Brush Tertiary => Brush("TextFillColorTertiaryBrush");
    public static Brush Critical => Brush("SystemFillColorCriticalBrush");
    public static Brush Accent => Brush("AccentTextFillColorPrimaryBrush");

    public static TextBlock Text(string text, double size = 14, bool bold = false, Brush? color = null, bool wrap = true) => new()
    {
        Text = text, FontSize = size, FontWeight = bold ? FontWeights.SemiBold : FontWeights.Normal,
        TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap, TextTrimming = wrap ? TextTrimming.None : TextTrimming.CharacterEllipsis,
        Foreground = color ?? Brush("TextFillColorPrimaryBrush"), IsTextSelectionEnabled = false,
    };

    /// A section's small heading over its box.
    public static TextBlock Header(string text) => new()
    {
        Text = text, FontSize = 13, FontWeight = FontWeights.SemiBold, Foreground = Secondary, Margin = new Thickness(0, 14, 0, 4),
    };

    public static Border Card(UIElement child, double padding = 12) => new()
    {
        Child = child, Padding = new Thickness(padding), CornerRadius = new CornerRadius(8),
        Background = Brush("CardBackgroundFillColorDefaultBrush"), BorderBrush = Brush("CardStrokeColorDefaultBrush"),
        BorderThickness = new Thickness(1),
    };

    public static Button Quiet(string text, Action click)
    {
        var b = new Button { Content = text, Style = Style("QuietButtonStyle") };
        b.Click += (_, _) => click();
        return b;
    }

    public static Button Push(string text, Action click, bool accent = false)
    {
        var b = new Button { Content = text };
        if (accent) b.Style = Style("AccentButtonStyle");
        b.Click += (_, _) => click();
        return b;
    }

    /// The accent at an opacity: the chosen card's soft tint and its edge.
    public static Brush AccentWash(double opacity) =>
        new SolidColorBrush(Application.Current.Resources.TryGetValue("SystemAccentColor", out var c) && c is Color accent ? accent : Blue) { Opacity = opacity };

    public static Ellipse Dot(Color color, double size = 8) => new() { Width = size, Height = size, Fill = Solid(color), VerticalAlignment = VerticalAlignment.Center };

    /// A status tone (App/Pages/Kanban/KanbanRowView.swift KanbanTone).
    public static Color Tone(string status) => status switch
    {
        "blocked" => Rgb(0xFF, 0x3B, 0x30),
        "triage" => Rgb(0x8E, 0x8E, 0x93),
        "todo" => Rgb(0x6C, 0x6C, 0x70),
        "scheduled" => Rgb(0xAF, 0x52, 0xDE),
        "ready" => Rgb(0x0A, 0x84, 0xFF),
        "running" => Rgb(0x30, 0xD1, 0x58),
        "review" => Rgb(0xFF, 0x9F, 0x0A),
        _ => Rgb(0x8E, 0x8E, 0x93),
    };

    public static readonly Color Red = Rgb(0xFF, 0x3B, 0x30), Orange = Rgb(0xFF, 0x9F, 0x0A), Green = Rgb(0x30, 0xB9, 0x4D), Blue = Rgb(0x0A, 0x84, 0xFF);

    // ------------------------------------------------------------------ bots

    public static IReadOnlyList<Bot> Bots => AppState.Client?.Bots ?? [];

    /// A profile's name as the app shows it: the roster's, else its words ("default" → "Hermes"); "No One" for none
    /// (App/Pages/PagesServices.swift PagesNames.botName).
    public static string BotName(string? profile)
    {
        if (string.IsNullOrEmpty(profile)) return "No One";
        if (PageKit.Bots.FirstOrDefault(b => b.Name == profile) is { } bot) return bot.DisplayName;
        var name = profile.Trim();
        if (name.Length == 0 || name == "default") return "Hermes";
        return string.Join(" ", name.Replace('-', ' ').Replace('_', ' ').Split(' ', StringSplitOptions.RemoveEmptyEntries)
            .Select(w => char.ToUpperInvariant(w[0]) + w[1..]));
    }

    public static FrameworkElement Face(string? profile, double size)
    {
        if (profile == null)
        {
            return new Rectangle
            {
                Width = size, Height = size, RadiusX = size * 0.28, RadiusY = size * 0.28, Stroke = Tertiary, StrokeThickness = 1,
                StrokeDashArray = [2, 2], VerticalAlignment = VerticalAlignment.Top,
            };
        }
        var head = new BotHead { Width = size, Height = size, VerticalAlignment = VerticalAlignment.Top };
        if (PageKit.Bots.FirstOrDefault(b => b.Name == profile) is { } bot) head.Bot = bot; else head.DisplayName = BotName(profile);
        return head;
    }

    // ------------------------------------------------------------------ dialogs

    public static async Task<ContentDialogResult> ShowAsync(XamlRoot? root, ContentDialog dialog)
    {
        if (root == null) return ContentDialogResult.None;
        dialog.XamlRoot = root;
        try { return await dialog.ShowAsync(); }
        catch (Exception x) when (x is InvalidOperationException or System.Runtime.InteropServices.COMException) { return ContentDialogResult.None; }
    }

    /// "Delete This Task?" and its kin: the destructive choice and Cancel.
    public static async Task<bool> ConfirmAsync(XamlRoot? root, string title, string message, string action, string cancel = "Cancel") =>
        await ShowAsync(root, new ContentDialog
        {
            Title = title, Content = Text(message), PrimaryButtonText = action, CloseButtonText = cancel, DefaultButton = ContentDialogButton.Close,
        }) == ContentDialogResult.Primary;

    /// A deliberate write failed: the gateway's reason with Try Again (KanbanFeedback.failed).
    public static async Task FailedAsync(XamlRoot? root, string title, string reason, Func<Task>? retry)
    {
        var dialog = new ContentDialog { Title = title, Content = Text(reason), CloseButtonText = "OK", DefaultButton = ContentDialogButton.Close };
        if (retry != null) { dialog.PrimaryButtonText = KanbanCopy.TryAgain; dialog.DefaultButton = ContentDialogButton.Primary; }
        if (await ShowAsync(root, dialog) == ContentDialogResult.Primary && retry != null) await retry();
    }

    /// One field and Set (the priority's Other Number…).
    public static async Task<string?> PromptAsync(XamlRoot? root, string title, string message, string value, string action, string placeholder = "")
    {
        var box = new TextBox { Text = value, PlaceholderText = placeholder };
        var panel = new StackPanel { Spacing = 8 };
        panel.Children.Add(Text(message, 13, color: Secondary));
        panel.Children.Add(box);
        var dialog = new ContentDialog
        {
            Title = title, Content = panel, PrimaryButtonText = action, CloseButtonText = KanbanCopy.Cancel, DefaultButton = ContentDialogButton.Primary,
        };
        box.Loaded += (_, _) => { box.Focus(FocusState.Programmatic); box.SelectAll(); };
        return await ShowAsync(root, dialog) == ContentDialogResult.Primary ? box.Text : null;
    }

    public static void Copy(string text) => HermesHQ.Services.SafeClipboard.TrySetText(text);

    public static IntPtr WindowHandle() => WinRT.Interop.WindowNative.GetWindowHandle(App.Window!);
}

/// A short line over the page that fades after a few seconds, with an optional action (Archived · Undo).
internal sealed class NoticeLine
{
    public InfoBar Bar { get; } = new()
    {
        IsOpen = false, IsClosable = true, Severity = InfoBarSeverity.Informational, Margin = new Thickness(16, 0, 16, 12),
        VerticalAlignment = VerticalAlignment.Bottom, HorizontalAlignment = HorizontalAlignment.Center, MaxWidth = 520,
    };
    private int _shown;

    public void Show(string text, int seconds = 3, string? title = null, string? action = null, Action? onAction = null)
    {
        var shown = ++_shown;
        Bar.Title = title ?? "";
        Bar.Message = text;
        if (action != null && onAction != null)
        {
            var button = new Button { Content = action };
            button.Click += (_, _) => { Bar.IsOpen = false; onAction(); };
            Bar.ActionButton = button;
        }
        else Bar.ActionButton = null;
        Bar.IsOpen = true;
        _ = HideLater(shown, seconds);
    }

    /// Takes the notice down now, and its pending hide with it (a task panel moving to another task: the first task's
    /// word stays with it).
    public void Clear()
    {
        _shown++;
        Bar.IsOpen = false;
        Bar.ActionButton = null;
    }

    private async Task HideLater(int shown, int seconds)
    {
        await Task.Delay(TimeSpan.FromSeconds(seconds));
        if (shown == _shown) Bar.IsOpen = false;
    }
}

/// The chosen board, kept per gateway between launches.
internal sealed class FileKanbanPrefs : IKanbanPrefs
{
    private static readonly string FilePath = System.IO.Path.Combine(AppPaths.Root, "kanban-prefs.json");
    private static readonly Lock Gate = new();

    public string? Get(string key)
    {
        lock (Gate)
        {
            try { return File.Exists(FilePath) ? J.Parse(File.ReadAllText(FilePath)).Str(key) : null; }
            catch (IOException) { return null; }
        }
    }

    public void Set(string key, string? value)
    {
        lock (Gate)
        {
            try
            {
                var o = (File.Exists(FilePath) ? J.Parse(File.ReadAllText(FilePath)) as JsonObject : null) ?? [];
                o[key] = value;
                Directory.CreateDirectory(AppPaths.Root);
                File.WriteAllText(FilePath, o.ToJsonString());
            }
            catch (IOException e) { AppLog.Note("kanban", $"couldn't keep the board: {e.GetType().Name}"); }
        }
    }
}
