using Hermes.Core.Shell;

namespace Hermes.Core.Tests;

/// Type-to-chat (App/Mac/MacTypeToChat.swift and HermesKit/Layout/KeyRules.swift `TypeToChat` at 93f984bb1; the Swift
/// tests are Tests/IPad/PaneRulesTests.swift `TypeToChatTests`): a key that types, pressed while a chat is open and no
/// text field has the keyboard, goes into that chat's message box. Windows virtual-key codes stand in for the Mac's.
public class TypeToChatTests
{
    private const int A = 0x41, H = 0x48, K = 0x4B, F = 0x46, E = 0x45, One = 0x31, NumPad1 = 0x61;
    private const int Slash = 0xBF, Period = 0xBE, Semicolon = 0xBA, Quote = 0xDE, Oem102 = 0xE2;

    private static bool Takes(int key, bool ctrl = false, bool alt = false, bool win = false) =>
        TypeToChat.Takes(key, ctrl, alt, win);

    // The Swift's lettersFiguresAndPunctuationAreTyping.
    [Fact]
    public void LettersFiguresAndPunctuationAreTyping()
    {
        Assert.True(Takes(H));
        Assert.True(Takes(One));
        Assert.True(Takes(NumPad1));
        Assert.True(Takes(Slash), "/ opens the commands there");
        Assert.True(Takes(Quote), "a dead key on an accent layout (US-International ' then e)");
        Assert.True(Takes(Oem102));
        Assert.True(Takes(TypeToChat.ImeProcessKey), "an input method's first letter starts in the box");
        Assert.True(Takes(TypeToChat.PacketKey), "a character sent as itself (the touch keyboard, a pen)");
    }

    /// The Mac's Shift and Option are typing (⌥E starts an accent). Shift carries no flag here (it is always typing);
    /// Windows' AltGr is Ctrl+Alt (€ is AltGr+E), and Alt with the number pad is an Alt code (Alt+0233 is é).
    [Fact]
    public void AltGrAndAltCodesAreTyping()
    {
        Assert.True(Takes(E, ctrl: true, alt: true), "AltGr+E");
        Assert.True(Takes(Quote, ctrl: true, alt: true));
        Assert.True(Takes(NumPad1, alt: true), "an Alt code's first figure");
        Assert.False(Takes(F, alt: true), "Alt+F: a menu's access key, not typing on Windows");
        Assert.False(Takes(One, alt: true), "Alt with the top-row figures is not an Alt code");
    }

    // The Swift's theWindowsOwnKeysAndShortcutsKeepTheirMeaning.
    [Fact]
    public void TheWindowsOwnKeysAndShortcutsKeepTheirMeaning()
    {
        // Return, Tab, Space, Backspace, Delete, Escape, Clear, Help, Insert, Home, End, Page Up/Down, the arrows.
        foreach (var key in new[] { 0x0D, 0x09, 0x20, 0x08, 0x2E, 0x1B, 0x0C, 0x2F, 0x2D, 0x24, 0x23, 0x21, 0x22, 0x25, 0x26, 0x27, 0x28 })
            Assert.False(Takes(key), $"key 0x{key:X2}");
        for (var f = 0x70; f <= 0x87; f++) Assert.False(Takes(f), $"F{f - 0x6F}");   // F1…F24
        // The modifiers themselves, Caps/Num/Scroll Lock, the Windows and menu keys, Pause, Print Screen, media keys.
        foreach (var key in new[] { 0x10, 0x11, 0x12, 0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0x14, 0x90, 0x91, 0x5B, 0x5C, 0x5D, 0x13, 0x2C, 0xAD, 0xB3 })
            Assert.False(Takes(key), $"key 0x{key:X2}");
        Assert.False(Takes(K, ctrl: true), "Ctrl+K (⌘K)");
        Assert.False(Takes(F, ctrl: true), "Ctrl+F");
        Assert.False(Takes(One, ctrl: true), "Ctrl+1 opens a sidebar row");
        Assert.False(Takes(0x26, ctrl: true, alt: true), "AltGr with an arrow types nothing");
        Assert.False(Takes(0x20, ctrl: true, alt: true));
        Assert.False(Takes(0), "no key");
    }

    // The Swift's emojiAndSymbolsOpensOnTheBox: ⌃⌘Space there, Win+. (or Win+;) here.
    [Fact]
    public void EmojiAndSymbolsOpensOnTheBox()
    {
        Assert.True(Takes(Period, win: true), "Win+.");
        Assert.True(Takes(Semicolon, win: true), "Win+;");
        Assert.False(Takes(K, win: true), "another Windows-key shortcut");
        Assert.False(Takes(A, win: true));
    }

    private static TypeToChat.Scene Open(TypeToChat.Focus focus = TypeToChat.Focus.Other) =>
        new(ChatOnShow: true, WindowActive: true, Covered: false, Focused: focus, BoxDocked: false, BoxReady: true);

    /// chatTakingKeys: a chat on show in the window, which has the keyboard, with nothing over it, nothing in it holding
    /// the keyboard, and its box there to type in.
    [Fact]
    public void ItGoesToTheOpenChatWhenNothingTypingHasTheKeyboard()
    {
        Assert.True(TypeToChat.Forwards(H, false, false, false, Open(TypeToChat.Focus.Nothing)));
        Assert.True(TypeToChat.Forwards(H, false, false, false, Open(TypeToChat.Focus.Other)),
            "a click on a sidebar row, a chat in a list, a button: the letters go to the box");
        Assert.False(TypeToChat.Forwards(0x28, false, false, false, Open()), "↓ keeps the list's meaning");
        Assert.False(TypeToChat.Forwards(K, true, false, false, Open()), "Ctrl+K is Open Quickly's");
    }

    [Fact]
    public void NothingMovesWhileSomethingElseHasTheKeyboard()
    {
        Assert.False(TypeToChat.Forwards(H, false, false, false, Open(TypeToChat.Focus.TextInput)),
            "a text field (the composer itself, a search field, Find, a read-only text) keeps its keys");
        Assert.False(TypeToChat.Forwards(H, false, false, false, Open(TypeToChat.Focus.ChoiceBox)),
            "a drop-down list picks its items by their letters");
        Assert.False(TypeToChat.Forwards(H, false, false, false, Open(TypeToChat.Focus.QuestionDock)),
            "the question card has the keyboard");
        Assert.False(TypeToChat.Forwards(H, false, false, false, Open() with { Covered = true }),
            "a dialog, a menu, Open Quickly, the Keyboard Shortcuts sheet");
        Assert.False(TypeToChat.Forwards(H, false, false, false, Open() with { WindowActive = false }),
            "another window has the keyboard");
        Assert.False(TypeToChat.Forwards(H, false, false, false, Open() with { ChatOnShow = false }),
            "no chat open: Settings, Kanban, a bot page");
        Assert.False(TypeToChat.Forwards(H, false, false, false, Open() with { BoxDocked = true }),
            "a question or approval covers the box");
        Assert.False(TypeToChat.Forwards(H, false, false, false, Open() with { BoxReady = false }),
            "the box hidden, disabled or read-only");
    }

    /// The box is ready when it is shown, enabled and editable. Sending off (offline, a reply running, the chat
    /// loading) leaves it editable, so a draft can be typed then.
    [Fact]
    public void TheBoxIsReadyWhenShownEnabledAndEditable()
    {
        Assert.True(TypeToChat.BoxReady(shown: true, enabled: true, readOnly: false));
        Assert.False(TypeToChat.BoxReady(shown: false, enabled: true, readOnly: false));
        Assert.False(TypeToChat.BoxReady(shown: true, enabled: false, readOnly: false));
        Assert.False(TypeToChat.BoxReady(shown: true, enabled: true, readOnly: true));
    }

    /// The press itself is not typed by the app: the box takes the keyboard and the same press goes on to it, so a dead
    /// key's accent and an input method's letter start there. Should the character still reach the element that had
    /// the keyboard, it is put in the box once, and only the press's own character.
    [Fact]
    public void ThePressReachesTheBoxOnce()
    {
        var relay = new TypeToChat.Relay();
        relay.KeyDown(forwarded: true);
        Assert.False(relay.Character(inBox: true), "the box had it: nothing to add");
        Assert.False(relay.Character(inBox: false), "the press was spent");

        relay.KeyDown(forwarded: true);
        Assert.True(relay.Character(inBox: false), "it went where the keyboard was: the box takes it");
        Assert.False(relay.Character(inBox: false), "once");

        relay.KeyDown(forwarded: true);
        relay.KeyDown(forwarded: false);   // a dead key's press, then the letter, typed in the box by then
        Assert.False(relay.Character(inBox: false));

        relay.KeyDown(forwarded: false);
        Assert.False(relay.Character(inBox: false), "a press not forwarded is left alone");
    }
}
