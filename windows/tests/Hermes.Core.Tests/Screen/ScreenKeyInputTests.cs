// [WIN-SCREEN-GESTURE] The key field's rules (Hermes.Core/Screen/ScreenGesture.cs, ScreenKeyInput), from the Mac's
// App/Screen/ScreenKeyField.swift at 93f984bb1. Tests/Screen/ScreenKeyFieldTests.swift's two behaviour cases are
// ported case for case over Windows' KeyDown / CharacterReceived (its third, no edit menu and no caret, is the
// page's: a WinUI control's look); the rest pin a rule each, Windows' differences included. Synthetic keys only.

using Hermes.Core.Screen;
using M = Hermes.Core.Screen.ScreenKeys.Modifier;
using N = Hermes.Core.Screen.ScreenKeys.Named;

namespace Hermes.Core.Tests.Screen;

public sealed class ScreenKeyInputTests
{
    private sealed class Rig
    {
        public List<string> Texts { get; } = [];
        public List<(N Key, HashSet<M> Mods)> Keys { get; } = [];
        public List<(string Character, HashSet<M> Mods)> Chords { get; } = [];
        public List<bool> Focus { get; } = [];
        public ScreenKeyInput Input { get; }

        public Rig(bool focused = true)
        {
            Input = new ScreenKeyInput
            {
                OnText = Texts.Add,
                OnKey = (k, m) => Keys.Add((k, m.ToHashSet())),
                OnChord = (c, m) => Chords.Add((c, m.ToHashSet())),
                OnFocusChange = Focus.Add,
            };
            if (focused) Input.FocusChanged(true);
        }

        public void Type(string text)
        {
            foreach (var unit in text) Input.CharacterReceived(unit, None);
        }
    }

    private static readonly HashSet<M> None = [];
    private const int VkLeft = 0x25, VkRight = 0x27, VkTab = 0x09, VkDelete = 0x2E, VkEscape = 0x1B, VkHome = 0x24, VkF5 = 0x74;
    private const int VkBack = 0x08, VkEnter = 0x0D, VkA = 0x41, VkC = 0x43, VkQ = 0x51, VkControl = 0x11, VkOem2 = 0xBF;

    [Fact]
    public void EveryTypedCharacterIsHandedOnOnce()
    {
        var rig = new Rig();
        Assert.Equal([true], rig.Focus);
        // Windows hands text over a UTF-16 unit at a time: 你好 is two hand-overs, 👋 one (its pair joined).
        foreach (var piece in new[] { "H", "i", " ", "é", " ", "€", "👋", "你好" }) rig.Type(piece);
        Assert.Equal(["H", "i", " ", "é", " ", "€", "👋", "你", "好"], rig.Texts);

        // Backspace and Enter are named keys (their \b and \r characters are not text).
        foreach (var vk in new[] { VkBack, VkBack, VkEnter })
            Assert.True(rig.Input.KeyDown(vk, None));
        rig.Input.CharacterReceived('\b', None);
        rig.Input.CharacterReceived('\r', None);
        Assert.Equal([N.Backspace, N.Backspace, N.Enter], rig.Keys.Select(k => k.Key));
        Assert.Equal(9, rig.Texts.Count);

        rig.Input.FocusChanged(false);
        Assert.Equal([true, false], rig.Focus);
        // Text that lands after the keyboard left goes nowhere.
        rig.Type("x");
        Assert.False(rig.Input.KeyDown(VkLeft, None));
        Assert.Equal(9, rig.Texts.Count);
        Assert.Equal(3, rig.Keys.Count);
    }

    /// Review finding: a named key held with two or more modifiers reached nothing (one command per single modifier).
    [Fact]
    public void NamedKeysCarryEveryHeldModifier()
    {
        var rig = new Rig();
        Assert.True(rig.Input.KeyDown(VkLeft, ScreenKeyInput.Mods(meta: true, shift: true)));             // Win+Shift+←
        Assert.True(rig.Input.KeyDown(VkTab, ScreenKeyInput.Mods(ctrl: true, shift: true)));              // Ctrl+Shift+Tab
        Assert.True(rig.Input.KeyDown(VkRight, ScreenKeyInput.Mods(alt: true, shift: true)));             // Alt+Shift+→
        Assert.True(rig.Input.KeyDown(VkDelete, ScreenKeyInput.Mods(true, true, true, true)));
        Assert.True(rig.Input.KeyDown(VkEscape, None));
        Assert.True(rig.Input.KeyDown(VkHome, ScreenKeyInput.Mods(shift: true)));
        Assert.True(rig.Input.KeyDown(VkF5, None));
        Assert.Equal(7, rig.Keys.Count);
        Assert.True(rig.Keys[5].Key == N.Home && rig.Keys[5].Mods.SetEquals([M.Shift]));
        Assert.True(rig.Keys[6].Key == N.F5 && rig.Keys[6].Mods.Count == 0);
        Assert.True(rig.Keys[0].Key == N.Left && rig.Keys[0].Mods.SetEquals([M.Meta, M.Shift]));
        Assert.True(rig.Keys[1].Key == N.Tab && rig.Keys[1].Mods.SetEquals([M.Ctrl, M.Shift]));
        Assert.True(rig.Keys[2].Key == N.Right && rig.Keys[2].Mods.SetEquals([M.Alt, M.Shift]));
        Assert.True(rig.Keys[3].Key == N.Delete && rig.Keys[3].Mods.SetEquals([M.Ctrl, M.Alt, M.Meta, M.Shift]));
        Assert.True(rig.Keys[4].Key == N.Escape && rig.Keys[4].Mods.Count == 0);
    }

    [Fact]
    public void EveryNamedKeyHasAVirtualKeyAndTakesAllSixteenModifierSets()
    {
        var vks = Enumerable.Range(0, 256).Where(vk => ScreenKeyInput.Named(vk) != null).ToList();
        Assert.Equal(Enum.GetValues<N>().Order(), vks.Select(vk => ScreenKeyInput.Named(vk)!.Value).Order());
        var rig = new Rig();
        foreach (var vk in vks)
            for (var bits = 0; bits < 16; bits++)
                Assert.True(rig.Input.KeyDown(vk, ScreenKeyInput.Mods((bits & 1) != 0, (bits & 2) != 0, (bits & 4) != 0, (bits & 8) != 0)));
        Assert.Equal(25 * 16, rig.Keys.Count);
        Assert.Empty(rig.Texts);
        Assert.Empty(rig.Chords);
    }

    [Fact]
    public void AKeyWithCtrlAltOrWindowsIsAChordNotText()
    {
        var rig = new Rig();
        Assert.True(rig.Input.KeyDown(VkC, ScreenKeyInput.Mods(ctrl: true)));
        rig.Input.CharacterReceived('\u0003', ScreenKeyInput.Mods(ctrl: true));                       // Ctrl+C's control character
        Assert.True(rig.Input.KeyDown(VkA, ScreenKeyInput.Mods(ctrl: true, shift: true)));
        Assert.True(rig.Input.KeyDown(VkA, ScreenKeyInput.Mods(alt: true)));                           // left Alt: a chord
        rig.Input.CharacterReceived('a', ScreenKeyInput.Mods(alt: true));
        Assert.True(rig.Input.KeyDown(0x32, ScreenKeyInput.Mods(meta: true)));                         // Win+2
        Assert.True(rig.Input.KeyDown(VkOem2, ScreenKeyInput.Mods(ctrl: true), character: "/"));      // Ctrl+/ from the layout
        Assert.True(rig.Input.KeyDown(0x20, ScreenKeyInput.Mods(ctrl: true)));                         // Ctrl+Space
        Assert.Equal(["c", "a", "a", "2", "/", " "], rig.Chords.Select(c => c.Character));
        Assert.True(rig.Chords[1].Mods.SetEquals([M.Ctrl, M.Shift]));
        Assert.True(rig.Chords[2].Mods.SetEquals([M.Alt]));
        Assert.Empty(rig.Texts);
        // A layout key with no character given, a modifier alone, or a plain letter: not taken (text comes after).
        Assert.False(rig.Input.KeyDown(VkOem2, ScreenKeyInput.Mods(ctrl: true)));
        Assert.False(rig.Input.KeyDown(VkControl, ScreenKeyInput.Mods(ctrl: true)));
        Assert.False(rig.Input.KeyDown(VkA, ScreenKeyInput.Mods(shift: true)));
        Assert.Equal(6, rig.Chords.Count);
    }

    [Fact]
    public void AltGrTypesTheLayoutsCharacter()
    {
        var rig = new Rig();
        // AltGr+Q on a German layout is @: Windows reports Ctrl+Alt, the right Alt down.
        var altGr = ScreenKeyInput.Mods(ctrl: true, alt: true, altGr: true);
        Assert.Empty(altGr);
        Assert.False(rig.Input.KeyDown(VkQ, altGr));
        rig.Input.CharacterReceived('@', altGr);
        Assert.Equal(["@"], rig.Texts);
        Assert.Empty(rig.Chords);
        // Shift stays with AltGr; named keys still take it.
        Assert.True(ScreenKeyInput.Mods(shift: true, ctrl: true, alt: true, altGr: true).SetEquals([M.Shift]));
    }

    [Fact]
    public void WindowsRepeatsNamedKeysAndTextButAHeldChordDoesNot()
    {
        var rig = new Rig();
        Assert.True(rig.Input.KeyDown(VkLeft, None));
        Assert.True(rig.Input.KeyDown(VkLeft, None, repeat: true));
        Assert.True(rig.Input.KeyDown(VkC, ScreenKeyInput.Mods(ctrl: true)));
        Assert.True(rig.Input.KeyDown(VkC, ScreenKeyInput.Mods(ctrl: true), repeat: true));            // taken, not sent
        rig.Type("aa");
        Assert.Equal(2, rig.Keys.Count);
        Assert.Single(rig.Chords);
        Assert.Equal(["a", "a"], rig.Texts);
    }

    [Fact]
    public void HalfASurrogatePairOrAControlCharacterIsNothing()
    {
        var rig = new Rig();
        rig.Input.CharacterReceived('\uDC4B', None);                                                     // a lone low half
        rig.Input.CharacterReceived('\uD83D', None);                                                     // a high half, then not its low
        rig.Input.CharacterReceived('x', None);
        rig.Input.CharacterReceived('\uD83D', None);
        rig.Input.FocusChanged(false);
        rig.Input.FocusChanged(true);
        rig.Input.CharacterReceived('\uDC4B', None);                                                     // focus between halves
        foreach (var c in new[] { '\t', '\u001B', '\u007F', '\uF704' }) rig.Input.CharacterReceived(c, None);
        Assert.Equal(["x"], rig.Texts);
        Assert.True(ScreenKeyInput.Printable(' ') && !ScreenKeyInput.Printable(0x1F) && !ScreenKeyInput.Printable(0xF8FF));
        Assert.Equal([true, false, true], rig.Focus);
    }

    [Fact]
    public void UnfocusedNothingIsTaken()
    {
        var rig = new Rig(focused: false);
        Assert.False(rig.Input.KeyDown(VkEnter, None));
        Assert.False(rig.Input.KeyDown(VkC, ScreenKeyInput.Mods(ctrl: true)));
        rig.Type("hi");
        Assert.Empty(rig.Texts);
        Assert.Empty(rig.Keys);
        Assert.Empty(rig.Chords);
        rig.Input.FocusChanged(false);
        Assert.Empty(rig.Focus);                                                                          // no change, no call
    }

    [Fact]
    public void UnmodifiedCharactersOfTheKeysEveryLayoutShares()
    {
        Assert.Equal("a", ScreenKeyInput.Unmodified(VkA));
        Assert.Equal("z", ScreenKeyInput.Unmodified(0x5A));
        Assert.Equal("0", ScreenKeyInput.Unmodified(0x30));
        Assert.Equal("7", ScreenKeyInput.Unmodified(0x67));                                             // keypad 7
        Assert.Equal(" ", ScreenKeyInput.Unmodified(0x20));
        Assert.Null(ScreenKeyInput.Unmodified(VkOem2));
    }
}
