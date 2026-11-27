using Hermes.Core.Bots;
using Hermes.Core.Sessions;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace HermesHQ.Features.Bots;

/// The Mac's TextPrompt, FailureAlert and confirmations, as ContentDialogs.
public static class Prompts
{
    /// "Couldn’t Pin Ivy" with the reason; Try Again runs `retry` when given.
    public static async Task FailureAsync(XamlRoot? root, string title, string reason, Func<Task>? retry = null)
    {
        var dialog = new ContentDialog
        {
            Title = title, Content = new TextBlock { Text = reason, TextWrapping = TextWrapping.Wrap },
            CloseButtonText = "OK", DefaultButton = ContentDialogButton.Close,
        };
        if (retry != null) dialog.PrimaryButtonText = "Try Again";
        if (await HermesHQ.Services.SafeDialog.ShowAsync(root, dialog) == ContentDialogResult.Primary && retry != null) await retry();
    }

    /// Runs a write; a failure shows its alert, whose Try Again runs it again.
    public static async Task<bool> RunAsync(XamlRoot? root, string fallbackTitle, Func<Task> write, CancellationToken stop = default)
    {
        if (stop.IsCancellationRequested) return false;
        try { await write(); return true; }
        catch (OperationCanceledException) when (stop.IsCancellationRequested) { return false; }
        catch (Exception e) when (e is BotWriteException or Hermes.Core.Net.GatewayException)
        {
            if (stop.IsCancellationRequested) return false; // don't present a failure or admit a retry after close
            var title = e is BotWriteException { Title.Length: > 0 } w ? w.Title : fallbackTitle;
            var reason = e is BotWriteException b ? b.Reason : SessionStore.ReasonOf(e);
            await FailureAsync(root, title, reason, () => RunAsync(root, fallbackTitle, write, stop));
            return false;
        }
    }

    public static async Task<bool> ConfirmAsync(XamlRoot? root, string title, string? message, string action, bool destructive = true)
    {
        var dialog = new ContentDialog
        {
            Title = title, PrimaryButtonText = action, CloseButtonText = "Cancel",
            DefaultButton = destructive ? ContentDialogButton.Close : ContentDialogButton.Primary,
        };
        if (message != null) dialog.Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap };
        return await HermesHQ.Services.SafeDialog.ShowAsync(root, dialog) == ContentDialogResult.Primary;
    }

    /// One text field: New Section, Rename Section, Rename Chat. `problem` names why a value can't be taken (the button
    /// goes off and the reason shows under the field).
    public static async Task<string?> TextAsync(XamlRoot? root, string title, string text, string placeholder, string action,
        int maxLength = 0, Func<string, string?>? problem = null, bool requireChange = false)
    {
        var box = new TextBox { Text = text, PlaceholderText = placeholder, MinWidth = 300 };
        if (maxLength > 0) box.MaxLength = maxLength;
        var note = new TextBlock
        {
            TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed, FontSize = 12,
            Foreground = ThemeBrushes.Get("SystemFillColorCriticalBrush"),
        };
        var dialog = new ContentDialog
        {
            Title = title, PrimaryButtonText = action, CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary, Content = new StackPanel { Spacing = 8, Children = { box, note } },
        };
        void Check()
        {
            var clean = box.Text.Trim();
            var why = problem?.Invoke(clean);
            note.Text = why ?? "";
            note.Visibility = why == null ? Visibility.Collapsed : Visibility.Visible;
            dialog.IsPrimaryButtonEnabled = clean.Length > 0 && why == null && (!requireChange || clean != text.Trim());
        }
        box.TextChanged += (_, _) => Check();
        Check();
        box.SelectAll();
        return await HermesHQ.Services.SafeDialog.ShowAsync(root, dialog) == ContentDialogResult.Primary ? box.Text.Trim() : null;
    }
}

/// The Undo pill: "Hidden · Undo", "Deleted “Work” · Undo", for a few seconds: the shell's over the pane beside the
/// sidebar (ShellPage `PillHost`, Hermes.Core.Shell.UndoPillPlacement), Sessions' at the foot of its list.
///
/// Laid out as the Mac's (App/Kit/UndoPill.swift): the words (at most two lines) with the way back under them, wrapping
/// at the width the host gives; then "·" and Undo, which keep their width. [WIN-23] A horizontal StackPanel measured
/// the words with endless width, so in the sidebar's narrow foot the way back ran off the edge and pushed Undo out of
/// sight ("Archived “Trip planning”" showed no Undo). A Grid's star column wraps them instead.
public static class UndoPill
{
    /// The pill on show (walks read its clock), and its life: the life keeps the pill's timer (WIN-44).
    public static FrameworkElement? Current { get; private set; }

    public static UndoPillLife? CurrentLife { get; private set; }

    /// Shows in `host` (a Grid cell at the list's foot) for `seconds` (the Mac's 4; at least 8 at accessibility text
    /// sizes, which on Windows is Settings › Accessibility › Text size at 150% or more: UndoPillClock). [WIN-44] Its clock
    /// stops while something holds it — the pointer resting over it, a touch on it, the keyboard inside it — and runs on
    /// with what was left after (App/Kit/UndoPill.swift `setHold`). Returns a dismiss action.
    public static Action Show(Panel host, string label, string? wayBack, Action undo, double seconds = UndoPillClock.Seconds)
    {
        host.Children.Clear();
        var undoButton = new HyperlinkButton
        {
            Content = "Undo", Padding = new Thickness(6, 2, 6, 2), VerticalAlignment = VerticalAlignment.Center,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        };
        // The Undo button says what it undoes (`undo-pill.tsx`: "<label>. <way back> Undo").
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(undoButton, "undo-pill.undo");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(undoButton,
            BotList.Spoken(new[] { label, wayBack ?? "", "Undo" }));
        var words = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Spacing = 1 };
        words.Children.Add(new TextBlock
        {
            Text = label, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap, MaxLines = 2,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        if (wayBack != null)
            words.Children.Add(new TextBlock
            {
                Text = wayBack, FontSize = 12, TextWrapping = TextWrapping.Wrap,
                Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
            });
        var dot = new TextBlock
        {
            Text = "·", VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6, 0, 0, 0),
            Foreground = ThemeBrushes.Get("TextFillColorTertiaryBrush"),
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAccessibilityView(dot, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        var row = new Grid { ColumnSpacing = 0 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(dot, 1);
        Grid.SetColumn(undoButton, 2);
        row.Children.Add(words);
        row.Children.Add(dot);
        row.Children.Add(undoButton);
        var pill = new Border
        {
            Background = ThemeBrushes.Get("AcrylicInAppFillColorDefaultBrush"),
            BorderBrush = ThemeBrushes.Get("CardStrokeColorDefaultBrush"),
            // Two lines make the capsule a rounded card (the Mac's 22 pt), with the words' own top and bottom room.
            BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(wayBack != null ? 16 : 22),
            Padding = new Thickness(14, wayBack != null ? 8 : 6, 4, wayBack != null ? 8 : 6),
            Margin = new Thickness(6), HorizontalAlignment = HorizontalAlignment.Center, MinHeight = 44,
            Child = row,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(pill, "undo-pill");
        host.Children.Add(pill);
        var gone = false;
        UndoPillLife? life = null;
        UndoPillPress? press = null;
        void Dismiss()
        {
            if (gone) return;
            gone = true;
            press?.Gone();
            life?.End();
            host.Children.Remove(pill);
            if (ReferenceEquals(Current, pill)) { Current = null; CurrentLife = null; }
        }
        // [WIN-ARCHIVE-UNDO] One press undoes (App/Kit/UndoPill.swift `undo()` clears `onUndo` first): a second click,
        // or one that lands after the pill's time ran out, does nothing. Every Click used to run `undo` again.
        press = new UndoPillPress(Dismiss, undo);
        undoButton.Click += (_, _) => press.Press();
        // [WIN-44] The timer is the life's, and the life the pill's (its Tag, and the handlers below): a timer made here
        // and kept nowhere never ticked, and the pill stayed for minutes. The text size is read as the pill is made.
        var queue = host.DispatcherQueue;
        life = new UndoPillLife(new UndoPillClock(seconds, UndoPillClock.AccessibilityTextScale(TextScale())),
            () => DateTimeOffset.UtcNow, (after, fire) => Arm(queue, after, fire), Dismiss);
        pill.Tag = life;
        Current = pill;
        CurrentLife = life;
        Hold(pill, life);
        // Taken off by the next pill (host.Children.Clear) or gone with its page: dismissed, no timer left behind.
        pill.Unloaded += (_, _) => Dismiss();
        life.Start();
        return Dismiss;
    }

    /// The holds (App/Kit/UndoPill.swift `holding`, `hovering`, `focusChanged`): the mouse or pen resting over the pill
    /// (the Mac's pointer), a touch pressed on it (the finger), the keyboard inside it (VoiceOver's focus on the Mac;
    /// Narrator follows the keyboard). Handled events too: Undo's own button marks its presses handled.
    private static void Hold(Border pill, UndoPillLife life)
    {
        static bool Touch(PointerRoutedEventArgs e) => e.Pointer.PointerDeviceType == Microsoft.UI.Input.PointerDeviceType.Touch;
        pill.AddHandler(UIElement.PointerEnteredEvent, new PointerEventHandler((_, e) =>
        {
            if (!Touch(e)) life.SetHold(UndoPillHold.Pointer, true);
        }), true);
        pill.AddHandler(UIElement.PointerExitedEvent, new PointerEventHandler((_, e) =>
        {
            life.SetHold(Touch(e) ? UndoPillHold.Finger : UndoPillHold.Pointer, false);
        }), true);
        pill.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler((_, e) =>
        {
            if (Touch(e)) life.SetHold(UndoPillHold.Finger, true);
        }), true);
        var lift = new PointerEventHandler((_, e) => { if (Touch(e)) life.SetHold(UndoPillHold.Finger, false); });
        pill.AddHandler(UIElement.PointerReleasedEvent, lift, true);
        pill.AddHandler(UIElement.PointerCanceledEvent, lift, true);
        pill.AddHandler(UIElement.PointerCaptureLostEvent, lift, true);
        pill.GotFocus += (_, _) => life.SetHold(UndoPillHold.VoiceOver, true);
        pill.LostFocus += (_, _) =>
        {
            var inside = pill.XamlRoot is { } root && Microsoft.UI.Xaml.Input.FocusManager.GetFocusedElement(root) is DependencyObject focused
                && Within(focused, pill);
            if (!inside) life.SetHold(UndoPillHold.VoiceOver, false);
        };
    }

    private static bool Within(DependencyObject element, DependencyObject ancestor)
    {
        for (var at = element; at != null; at = VisualTreeHelper.GetParent(at))
            if (ReferenceEquals(at, ancestor)) return true;
        return false;
    }

    /// Windows' text size (Settings › Accessibility › Text size, 1.0–2.25); 1 when it can't be read.
    private static double TextScale()
    {
        try { return new Windows.UI.ViewManagement.UISettings().TextScaleFactor; }
        catch (Exception) { return 1; }
    }

    /// A one-shot timer on the pill's thread; disposing it stops it. The handle keeps the timer referenced.
    private static IDisposable Arm(Microsoft.UI.Dispatching.DispatcherQueue queue, TimeSpan after, Action fire)
    {
        var timer = queue.CreateTimer();
        timer.Interval = after;
        timer.IsRepeating = false;
        timer.Tick += (t, _) => { t.Stop(); fire(); };
        timer.Start();
        return new Armed(timer);
    }

    private sealed class Armed(Microsoft.UI.Dispatching.DispatcherQueueTimer timer) : IDisposable
    {
        public Microsoft.UI.Dispatching.DispatcherQueueTimer Timer { get; } = timer;

        public void Dispose() => Timer.Stop();
    }
}
