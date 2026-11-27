// [WIN-SCREEN-WIRE-KEYS-MATH] The words for taking over a bot's browser or screen and giving it back, the C# twin of
// the Mac's HermesKit/Screen/ControlWords.swift at 93f984bb1. Watch Browser and Screen are reached from the same
// Computer group, so they say the same thing (UX study 2026-10-19 #81; the owner's own phrase is "watch and take
// control", docs/spec/3x-screen.md).
//
// Windows is driven with a mouse, as the Mac (Catalyst) build is, so BrowserGestures / ScreenGestures are that build's
// words. The iOS build's touch words are kept as TouchBrowserGestures / TouchScreenGestures for a touch-only Windows
// device. Swift's `take(held:)` is TakeLabel(held) (C# cannot name a constant and a method alike).

namespace Hermes.Core.Screen;

public static class ControlWords
{
    public const string Take = "Take Control";
    public const string Give = "Give Back";
    /// Screen only: a hold this device lost track of (docs/spec/3x-screen.md §5.8).
    public const string Resume = "Resume Control";
    /// Screen only: another viewer's control ends and the bot has it again (was "Hand back (force)").
    public const string EndOther = "End Their Control";

    /// The Take button's words: Resume Control while an earlier hold of this device's is still on the screen.
    public static string TakeLabel(bool held) => held ? Resume : Take;

    /// Both bars' keyboard button (its accessible name) and an empty clipboard's note.
    public const string ShowKeyboard = "Show Keyboard";
    public const string HideKeyboard = "Hide Keyboard";
    public const string NothingToPaste = "There’s no text to paste.";

    /// [mac] The Screen: a click is a tap there ("Click to click" said nothing), and a hold is the mouse button held
    /// down. A Mac's scroll goes to the page; a pinch brings no touches, so it doesn't zoom. The Browser's page takes the
    /// mouse as a browser's own page does (2026-11-16): the click and the drag land under the cursor.
    public const string BrowserGestures = "Click, drag and scroll on the page, as in any browser.";
    public const string ScreenGestures = "Drag anywhere to move · A click clicks at the cursor · Hold the button then move to drag · Hold it to right-click";

    /// [touch] The drag is said too (a tester, 2026-11-16, didn't find it): a still hold, then the finger drags what is
    /// under the pointer.
    public const string TouchBrowserGestures = "Drag anywhere to move the pointer. Tap to click. Hold, then drag, to drag something. Two fingers scroll; pinch to zoom.";
    /// [touch] Audit 09-22: the two-finger scroll and the pinch too, as the Browser's hint says.
    public const string TouchScreenGestures = "Drag anywhere to move · Tap to click at the cursor · Hold then move to drag · Hold to right-click · Two fingers scroll · Pinch to zoom";

    /// Screen's notes under the picture.
    public const string HeldNote = "You were in control of this screen. " + Resume + ", or give it back to the bot.";
    public const string OtherNote = "Another viewer has control. " + EndOther + " gives it back to the bot.";
    /// Watch Browser while another viewer holds the browser: why there is no Take Control, and when it comes back.
    public const string BrowserOther = "Another viewer has control. You can take control once they give it back.";
}
