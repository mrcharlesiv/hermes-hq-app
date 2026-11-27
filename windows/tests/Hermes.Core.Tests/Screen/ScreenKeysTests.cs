// [WIN-SCREEN-WIRE-KEYS-MATH] Keys and paste for a controlled screen (Hermes.Core/Screen/ScreenKeys.cs), ported case for
// case from the Mac's Tests/Screen/ScreenKeysTests.swift at 93f984bb1 (docs/spec/3x-screen.md §5.6, the web app's
// cases). The Swift `ScreenKeys.Paste` enum is `ScreenPaste` here (C# cannot name a nested type and a method alike).

using Hermes.Core.Screen;
using static Hermes.Core.Screen.ScreenKeys;

namespace Hermes.Core.Tests.Screen;

public class ScreenKeysTests
{
    /// (keysym, down) pairs from key messages.
    private static List<uint[]> Keys(IEnumerable<byte[]> messages) =>
        messages.Select(bytes => bytes.Length != 8 || bytes[0] != 4
            ? new uint[] { 0xDEAD }
            : [(uint)bytes[4] << 24 | (uint)bytes[5] << 16 | (uint)bytes[6] << 8 | bytes[7], bytes[1]]).ToList();

    private static List<uint[]> Press(uint keysym) => [[keysym, 1], [keysym, 0]];

    private static void Same(IEnumerable<uint[]> expected, IEnumerable<uint[]> actual) =>
        Assert.Equal(expected.Select(p => string.Join(",", p)), actual.Select(p => string.Join(",", p)));

    [Fact]
    public void MapsTextToKeysyms()
    {
        Assert.Equal(0x61u, KeysymFor(0x61));
        Assert.Equal(0xE9u, KeysymFor(0xE9));
        Assert.Equal(0x0100_20ACu, KeysymFor(0x20AC));
        Assert.Equal(0x0100_007Fu, KeysymFor(0x7F));
        Assert.True(KeysymFor(0x20) == 0x20 && KeysymFor(0x7E) == 0x7E && KeysymFor(0xA0) == 0xA0 && KeysymFor(0xFF) == 0xFF);
        Same([.. Press(0x48), .. Press(0x69), .. Press(0x0101_F600)], Keys(Text("Hi😀")));
        Same(Press(0x0100_4F60), Keys(Text("你")));
    }

    [Fact]
    public void ModifiersGoDownInOrderAndComeUpInReverse()
    {
        Same([[0xFFE3, 1], [0x63, 1], [0x63, 0], [0xFFE3, 0]], Keys(Text("c", [Modifier.Ctrl])));
        Same([[0xFFE9, 1], [0xFFEB, 1], [0xFF51, 1], [0xFF51, 0], [0xFFEB, 0], [0xFFE9, 0]],
             Keys(Chord(Named.Left.Keysym(), [Modifier.Meta, Modifier.Alt])));
        Same([[0xFFE1, 1], [0xFFE3, 1], [0xFFE9, 1], [0xFFEB, 1], [0x61, 1], [0x61, 0], [0xFFEB, 0], [0xFFE9, 0], [0xFFE3, 0], [0xFFE1, 0]],
             Keys(Chord(0x61, [Modifier.Meta, Modifier.Shift, Modifier.Alt, Modifier.Ctrl])));
    }

    [Fact]
    public void NamedKeys()
    {
        var expected = new Dictionary<Named, uint>
        {
            [Named.Backspace] = 0xFF08, [Named.Tab] = 0xFF09, [Named.Enter] = 0xFF0D, [Named.Escape] = 0xFF1B, [Named.Delete] = 0xFFFF,
            [Named.Left] = 0xFF51, [Named.Up] = 0xFF52, [Named.Right] = 0xFF53, [Named.Down] = 0xFF54,
            [Named.Home] = 0xFF50, [Named.End] = 0xFF57, [Named.PageUp] = 0xFF55, [Named.PageDown] = 0xFF56,
            [Named.F1] = 0xFFBE, [Named.F2] = 0xFFBF, [Named.F3] = 0xFFC0, [Named.F4] = 0xFFC1, [Named.F5] = 0xFFC2, [Named.F6] = 0xFFC3,
            [Named.F7] = 0xFFC4, [Named.F8] = 0xFFC5, [Named.F9] = 0xFFC6, [Named.F10] = 0xFFC7, [Named.F11] = 0xFFC8, [Named.F12] = 0xFFC9,
        };
        foreach (var key in Enum.GetValues<Named>()) Assert.Equal(expected[key], key.Keysym());
        Assert.Equal(expected.Count, Enum.GetValues<Named>().Length);
        Assert.True(Modifier.Shift.Keysym() == 0xFFE1 && Modifier.Ctrl.Keysym() == 0xFFE3);
        Assert.True(Modifier.Alt.Keysym() == 0xFFE9 && Modifier.Meta.Keysym() == 0xFFEB);
    }

    [Fact]
    public void LineBreaksAndTabsInTypedTextAreKeys()
    {
        Same([.. Press(0x61), .. Press(0xFF0D), .. Press(0x62), .. Press(0xFF09), .. Press(0x63)], Keys(Text("a\r\nb\tc")));
    }

    [Fact]
    public void PasteChoosesTheClipboardOnlyForLatin1OnAMac()
    {
        Assert.Equal(new ScreenPaste.Empty(), Paste(null, mac: true));
        Assert.Equal(new ScreenPaste.Empty(), Paste("", mac: false));
        var clipboard = Assert.IsType<ScreenPaste.Clipboard>(Paste("héllo", mac: true));
        // ClientCutText: type 6, three padding bytes, length, Latin-1 bytes; then ⌘V.
        Assert.Equal(new byte[] { 6, 0, 0, 0, 0, 0, 0, 5, 0x68, 0xE9, 0x6C, 0x6C, 0x6F }, clipboard.Messages[0]);
        Same([[0xFFEB, 1], [0x76, 1], [0x76, 0], [0xFFEB, 0]], Keys(clipboard.Messages.Skip(1)));
        // The same text on a Linux screen is typed.
        Assert.Equal(new ScreenPaste.Typed("héllo"), Paste("héllo", mac: false));
        // Anything beyond Latin-1 is typed, on a Mac too.
        Assert.Equal(new ScreenPaste.Typed("price €5"), Paste("price €5", mac: true));
        Assert.Equal(new ScreenPaste.Typed("😀"), Paste("😀", mac: true));
    }

    [Fact]
    public void AClipboardOverTheCapIsTyped()
    {
        var atCap = new string('a', MaxCutText);
        var clipboard = Assert.IsType<ScreenPaste.Clipboard>(Paste(atCap, mac: true));     // 262,144 bytes fit a ClientCutText
        Assert.Equal(8 + MaxCutText, clipboard.Messages[0].Length);
        Assert.Equal(new ScreenPaste.Typed(atCap + "a"), Paste(atCap + "a", mac: true));
        Assert.Null(Latin1(atCap + "a"));
        Assert.Equal(new byte[] { 0xFF }, Latin1("ÿ"));
        Assert.Null(Latin1("Ā"));
    }

    [Fact]
    public void NothingIsSentWhileAnInputMethodIsComposing()
    {
        Assert.Null(Committed("ni", composing: true));
        Assert.Equal("你", Committed("你", composing: false));
        Assert.Null(Committed("", composing: false));
        Assert.Null(Committed(null, composing: false));
    }

    [Fact]
    public void LongTextGoesOutInSlicesAndCanBeCancelled()
    {
        var typer = new ScreenTyper();
        Assert.True(typer.IsEmpty && typer.Next().Count == 0);
        typer.Add(new string('x', 1_200), []);
        Assert.Equal(1_200, typer.Count);
        Assert.Equal(1_000, typer.Next().Count);            // 500 characters, a press and a release each
        Assert.Equal(700, typer.Count);
        Assert.Equal(1_000, typer.Next().Count);
        typer.Cancel();
        Assert.True(typer.IsEmpty && typer.Next().Count == 0);
        typer.Add("ab", [Modifier.Shift]);
        Same([[0xFFE1, 1], [0x61, 1], [0x61, 0], [0xFFE1, 0], [0xFFE1, 1], [0x62, 1], [0x62, 0], [0xFFE1, 0]], Keys(typer.Next()));
        Assert.True(typer.IsEmpty);
    }

    [Fact]
    public void AHundredThousandCharactersTakeTwoHundredTurns()
    {
        var typer = new ScreenTyper();
        typer.Add(new string('é', 100_000), []);
        int turns = 0, messages = 0;
        while (!typer.IsEmpty)
        {
            messages += typer.Next().Count;
            turns += 1;
        }
        Assert.True(turns == 200 && messages == 200_000);
    }

    // Windows-only addition (no Swift twin): the typer counts characters as Swift does (grapheme clusters), so an emoji
    // with a skin tone or a family is one character and never split across two slices.
    [Fact]
    public void ATyperCountsCharactersNotUtf16Units()
    {
        var typer = new ScreenTyper();
        typer.Add("e\u0301👍🏽", []);
        Assert.Equal(2, typer.Count);
        Same([.. Press(0x65), .. Press(0x0100_0301), .. Press(0x0101_F44D), .. Press(0x0101_F3FD)], Keys(typer.Next()));
    }
}
