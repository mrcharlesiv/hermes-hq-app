using Hermes.Core.Voice;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using Windows.System;

namespace HermesHQ.Features.Voice;

/// Port of App/Chat/Voice/MemoMicControl.swift: hold-to-record, slide-left-to-cancel,
/// slide-up-to-lock, short-click hands-free lock, and keyboard-accessible mic button.
public sealed class MemoMicControl : ContentControl
{
    public const string AutomationId = "composer.mic";

    private readonly Border _circle;
    private readonly FontIcon _icon;
    private readonly Func<MemoController?> _controller;
    private readonly Func<MemoTarget?> _target;
    private readonly Func<double> _composerWidth;
    private readonly Func<bool> _keyboardUp;

    private uint? _capturedPointerId;
    private Point _downPoint;
    private bool _holdingVisual;

    public event Action? BeforeRecordStart;

    public MemoMicControl(
        Func<MemoController?> controller,
        Func<MemoTarget?> target,
        Func<double> composerWidth,
        Func<bool> keyboardUp)
    {
        _controller = controller;
        _target = target;
        _composerWidth = composerWidth;
        _keyboardUp = keyboardUp;

        Width = 34;
        Height = 34;
        HorizontalAlignment = HorizontalAlignment.Center;
        VerticalAlignment = VerticalAlignment.Center;
        HorizontalContentAlignment = HorizontalAlignment.Stretch;
        VerticalContentAlignment = VerticalAlignment.Stretch;
        IsTabStop = true;
        UseSystemFocusVisuals = true;

        _icon = new FontIcon
        {
            Glyph = "\uE720",
            FontSize = 15,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush"),
        };
        _circle = new Border
        {
            Width = 34,
            Height = 34,
            CornerRadius = new CornerRadius(17),
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            Child = _icon,
        };
        Content = _circle;

        AutomationProperties.SetAutomationId(this, AutomationId);
        AutomationProperties.SetName(this, "Record Voice Memo");
        ToolTipService.SetToolTip(this, "Hold to record a voice memo, or click to record hands-free");

        PointerEntered += OnPointerEntered;
        PointerExited += OnPointerExited;
        PointerPressed += OnPointerPressed;
        PointerMoved += OnPointerMoved;
        PointerReleased += OnPointerReleased;
        PointerCanceled += OnPointerCanceled;
        PointerCaptureLost += OnPointerCaptureLost;
        KeyDown += OnKeyDown;
    }

    public void UpdateVisual(MemoGestureState state, bool activeHere)
    {
        _holdingVisual = activeHere && state.Phase is MemoPhase.Pressing or MemoPhase.Holding;
        if (_holdingVisual)
        {
            _circle.Background = ThemeBrushes.Get(state.CancelArmed
                ? "SystemFillColorCriticalBrush"
                : "AccentFillColorDefaultBrush");
            _icon.Foreground = ThemeBrushes.Get("TextOnAccentFillColorPrimaryBrush");
            _icon.Glyph = state.LockNear ? "\uE72E" : "\uE720";
        }
        else
        {
            _circle.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
            _icon.Foreground = ThemeBrushes.Get("TextFillColorSecondaryBrush");
            _icon.Glyph = "\uE720";
        }
    }

    private void OnPointerEntered(object sender, PointerRoutedEventArgs e)
    {
        if (!_holdingVisual) _circle.Background = ThemeBrushes.Get("SubtleFillColorSecondaryBrush");
    }

    private void OnPointerExited(object sender, PointerRoutedEventArgs e)
    {
        if (!_holdingVisual) _circle.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
    }

    private void OnPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        var props = e.GetCurrentPoint(this).Properties;
        if (!props.IsLeftButtonPressed && e.Pointer.PointerDeviceType == Microsoft.UI.Input.PointerDeviceType.Mouse) return;

        if (_controller() is not { } ctrl || _target() is not { } tgt) return;
        BeforeRecordStart?.Invoke();

        _downPoint = e.GetCurrentPoint(null).Position;
        _capturedPointerId = e.Pointer.PointerId;
        CapturePointer(e.Pointer);
        e.Handled = true;

        var width = Math.Max(220, _composerWidth());
        ctrl.MemoDown(tgt, width, a11y: false, keyboardUp: _keyboardUp());
    }

    private void OnPointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (_capturedPointerId != e.Pointer.PointerId) return;
        if (_controller() is not { } ctrl) return;
        var current = e.GetCurrentPoint(null).Position;
        var dx = current.X - _downPoint.X;
        var dy = current.Y - _downPoint.Y;
        ctrl.Input(new MemoInput.Move(dx, dy));
        e.Handled = true;
    }

    private void OnPointerReleased(object sender, PointerRoutedEventArgs e)
    {
        if (_capturedPointerId != e.Pointer.PointerId) return;
        _capturedPointerId = null;
        ReleasePointerCapture(e.Pointer);
        if (_controller() is { } ctrl) ctrl.Input(new MemoInput.Up(ctrl.Now));
        e.Handled = true;
    }

    private void OnPointerCanceled(object sender, PointerRoutedEventArgs e)
    {
        if (_capturedPointerId != e.Pointer.PointerId) return;
        _capturedPointerId = null;
        ReleasePointerCapture(e.Pointer);
        if (_controller() is { } ctrl) ctrl.Input(new MemoInput.PointerCancel());
        e.Handled = true;
    }

    private void OnPointerCaptureLost(object sender, PointerRoutedEventArgs e)
    {
        if (_capturedPointerId != e.Pointer.PointerId) return;
        _capturedPointerId = null;
        if (_controller() is { } ctrl && ctrl.State.Phase is MemoPhase.Pressing or MemoPhase.Holding)
            ctrl.Input(new MemoInput.PointerCancel());
    }

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key is not (VirtualKey.Enter or VirtualKey.Space)) return;
        if (_controller() is not { } ctrl || _target() is not { } tgt) return;
        BeforeRecordStart?.Invoke();
        ctrl.MemoDown(tgt, Math.Max(220, _composerWidth()), a11y: true, keyboardUp: _keyboardUp());
        e.Handled = true;
    }
}
