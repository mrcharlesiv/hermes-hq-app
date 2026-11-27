// [WIN-SCREEN-VIEWER-CORE] The seams the Bot Screen viewer's controller works through, so its state machine (the
// C# twin of the Mac's App/Screen/ScreenViewerController.swift at 93f984bb1) runs headless: the timers (Foundation
// `Timer`), the display link that paces pointer moves (`CADisplayLink`), the wall clock (`Date()`), and the view
// (UIKit: the key field, the clipboard, haptics, VoiceOver's announcements, the sheet, the dismissal). The WinUI page
// (a later slice) implements IScreenViewerHost over its controls and DispatcherQueueTimer / CompositionTarget.Rendering.

namespace Hermes.Core.Screen;

/// Foundation's `Timer.scheduledTimer` on the UI thread. Disposing the handle is `invalidate()`.
public interface IScreenViewerTimers
{
    IDisposable Schedule(TimeSpan after, bool repeats, Action fire);
}

/// The display's frame ticks (`CADisplayLink`; CompositionTarget.Rendering on Windows). The source keeps `tick` alive
/// while the link is undisposed, as a run loop keeps a display link's target: the caller passes a weak proxy.
public interface IScreenFrameTicks
{
    IScreenFrameLink Start(Action tick);
}

/// One display link: paused between moves, disposed (`invalidate()`) to take it off the run loop.
public interface IScreenFrameLink : IDisposable
{
    bool Paused { get; set; }
}

/// The haptics the viewer plays (`Haptics.play`). The Windows page may map them to nothing.
public enum ScreenHaptic { Selection, Light, Success, Warning }

/// What the viewer asks of its view. Every member has an inert default, so a page implements only what it draws.
public interface IScreenViewerHost
{
    /// The whole state to draw, after every change (`render()`).
    void Render(ScreenViewerState state) { }
    /// `keyField.isFirstResponder`: the key field that types on the bot's screen has the keyboard.
    bool KeyboardFocused => false;
    /// `becomeFirstResponder()` / `resignFirstResponder()`; the host answers with KeyboardFocusChanged.
    void RaiseKeyboard() { }
    void LowerKeyboard() { }
    void Haptic(ScreenHaptic kind) { }
    /// `HQAnnounce.say`: spoken by the screen reader.
    void Announce(string text) { }
    /// `UIPasteboard.general.string = …`.
    void CopyText(string text) { }
    /// The clipboard's text, read only when Paste is clicked; null when empty or refused.
    Task<string?> ReadClipboard() => Task.FromResult<string?>(null);
    /// The stage's local view (`stage.setView`), Fit and the zoom keys (`stage.zoom(by:)`, `stage.fit()`).
    void SetStageView(ScreenView view, bool animated) { }
    void ZoomStage(double factor) { }
    void FitStage() { }
    /// The display stays on (`isIdleTimerDisabled`, the Mac's display-sleep activity).
    void KeepAwake(bool on) { }
    /// The control-only setup sheet over the Screen; the host calls `gone` once it closes.
    void PresentControlSetup(Action gone) { gone(); }
    /// The viewer goes away (`presentingViewController?.dismiss`).
    void Dismiss() { }
    /// [mac] The viewer takes the keyboard while nothing in it types (= / - / 0, Ctrl+W and Escape find it).
    void TakeKeys() { }
}
