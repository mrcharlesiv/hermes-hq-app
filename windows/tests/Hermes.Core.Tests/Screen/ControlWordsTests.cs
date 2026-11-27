// [WIN-SCREEN-WIRE-KEYS-MATH] The words for taking control and giving it back (Hermes.Core/Screen/ControlWords.cs),
// ported case for case from the Mac's Tests/Screen/ControlWordsTests.swift at 93f984bb1 (UX study 2026-10-19 #81, #86:
// Watch Browser and Screen use one pair of words). Swift's `take(held:)` is `TakeLabel(held)` here (C# cannot name a
// constant and a method alike).

using Hermes.Core.Screen;

namespace Hermes.Core.Tests.Screen;

public class ControlWordsTests
{
    [Fact]
    public void OnePairForBothViewers()
    {
        Assert.True(ControlWords.Take == "Take Control" && ControlWords.Give == "Give Back");
        Assert.Equal("Take Control", ControlWords.TakeLabel(held: false));
        Assert.Equal("Resume Control", ControlWords.TakeLabel(held: true));
        Assert.Equal("End Their Control", ControlWords.EndOther);
    }

    [Fact]
    public void NoOldWordsAndOneGestureVerb()
    {
        string[] all = [ControlWords.Take, ControlWords.Give, ControlWords.Resume, ControlWords.EndOther, ControlWords.HeldNote,
                        ControlWords.OtherNote, ControlWords.BrowserOther, ControlWords.BrowserGestures, ControlWords.ScreenGestures,
                        ControlWords.TouchBrowserGestures, ControlWords.TouchScreenGestures];
        foreach (var words in all)
        {
            Assert.False(words.Contains("Take over") || words.Contains("Hand back") || words.Contains("(force)"), words);
            Assert.False(words.Contains("Swipe"), words);
        }
        // The Swift prefix check runs in the iOS build, whose hints are the touch ones; the Mac (Catalyst) build's
        // pointer hints, which Windows shows, are pinned word for word instead.
        Assert.True(ControlWords.TouchBrowserGestures.StartsWith("Drag anywhere", StringComparison.Ordinal)
                    && ControlWords.TouchScreenGestures.StartsWith("Drag anywhere", StringComparison.Ordinal));
        Assert.Equal("Click, drag and scroll on the page, as in any browser.", ControlWords.BrowserGestures);
        Assert.Equal("Drag anywhere to move · A click clicks at the cursor · Hold the button then move to drag · Hold it to right-click",
                     ControlWords.ScreenGestures);
    }

    [Fact]
    public void NotesNameTheButtonsTheyMention()
    {
        Assert.Contains(ControlWords.Resume, ControlWords.HeldNote);
        Assert.Contains(ControlWords.EndOther, ControlWords.OtherNote);
        // Someone else holds the browser: why, and when control comes back.
        Assert.Equal("Another viewer has control. You can take control once they give it back.", ControlWords.BrowserOther);
    }

    // Windows-only addition (no Swift twin): the rest of the strings, exactly.
    [Fact]
    public void TheOtherWordsAreTheMacs()
    {
        Assert.Equal("Show Keyboard", ControlWords.ShowKeyboard);
        Assert.Equal("Hide Keyboard", ControlWords.HideKeyboard);
        Assert.Equal("There’s no text to paste.", ControlWords.NothingToPaste);
        Assert.Equal("You were in control of this screen. Resume Control, or give it back to the bot.", ControlWords.HeldNote);
        Assert.Equal("Another viewer has control. End Their Control gives it back to the bot.", ControlWords.OtherNote);
    }
}
