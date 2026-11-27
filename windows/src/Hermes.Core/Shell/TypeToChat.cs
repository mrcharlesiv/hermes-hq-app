namespace Hermes.Core.Shell;

/// Type-to-chat (App/Mac/MacTypeToChat.swift and HermesKit/Layout/KeyRules.swift `TypeToChat` at 93f984bb1; the owner's
/// call Q1, as Messages): after a click on a bot or a chat, nothing had the keyboard and the letters typed went nowhere.
/// The first key that types something, pressed while a chat is open and no text field has the keyboard, goes into that
/// chat's message box, and the box keeps the keyboard from then on. The keys the window already uses with nothing
/// focused keep their meaning, and nothing moves while a dialog, a menu, a search field or another window has the
/// keyboard. The press itself is not typed by the app: the box takes the keyboard and the same press goes on to it, so
/// an accent's dead key and an input method's first letter start in the box.
///
/// Keys are Windows virtual-key codes (the Mac's are its own key codes). Windows has no characters on a key-down, so the
/// typing keys are named (letters, figures, the number pad, the punctuation keys) where the Mac reads the characters.
public static class TypeToChat
{
    /// VK_PROCESSKEY: a key an input method is taking (its first letter).
    public const int ImeProcessKey = 0xE5;
    /// VK_PACKET: a character sent as itself (the touch keyboard, handwriting).
    public const int PacketKey = 0xE7;
    private const int OemSemicolon = 0xBA, OemPeriod = 0xBE;

    /// A key that types: A–Z, 0–9, the number pad's figures and signs, the punctuation keys (OEM 1–8 and 102, which
    /// are the dead keys on accent layouts), an input method's key and a packet. Everything else is the window's
    /// (Return, Tab, Space, Backspace, Delete, Escape, the arrows, Home, End, Page Up/Down, Insert, F1–F24, the
    /// modifiers and locks, the media keys): the Mac's `windowKeys`, `functionKeys` and control characters.
    public static bool IsTypingKey(int key) => key switch
    {
        >= 0x30 and <= 0x39 => true,   // 0–9
        >= 0x41 and <= 0x5A => true,   // A–Z
        >= 0x60 and <= 0x6F => true,   // the number pad: 0–9, * + separator - . /
        >= 0xBA and <= 0xC0 => true,   // ; = , - . / `
        >= 0xDB and <= 0xDF => true,   // [ \ ] ' and OEM 8
        0xE2 => true,                  // the 102nd key (< > on European keyboards)
        ImeProcessKey or PacketKey => true,
        _ => false,
    };

    /// `TypeToChat.takes`: whether a press is typing. Shift always is. The Mac's Option is typing (⌥E starts an accent);
    /// on Windows the accents are AltGr (Ctrl+Alt) and Alt with the number pad (an Alt code: Alt+0233 is é), while Alt
    /// with anything else is a menu's access key. Ctrl alone is a shortcut. The Mac's ⌃⌘Space (Emoji & Symbols) counts
    /// so the picker opens on the box: Windows' Win+. and Win+; do the same; every other Windows-key press is the
    /// system's.
    public static bool Takes(int key, bool ctrl, bool alt, bool win)
    {
        if (win) return key is OemPeriod or OemSemicolon;
        if (!IsTypingKey(key)) return false;
        if (ctrl && alt) return true;   // AltGr
        if (ctrl) return false;
        if (alt) return key is >= 0x60 and <= 0x69;   // an Alt code's figures
        return true;
    }

    /// What has the keyboard in the window.
    public enum Focus
    {
        /// No element: the window itself.
        Nothing,
        /// A list, a row, a button, a link, the transcript: nothing that types.
        Other,
        /// A text field, editable or read-only: the message box itself, a search field, Find, a selectable text
        /// (the Mac's `hqTypingInput`).
        TextInput,
        /// A drop-down list, which picks its items by their first letters (Windows' own meaning for the keys).
        ChoiceBox,
        /// Inside the question or approval card over the box (the Mac's `QuestionDockView`).
        QuestionDock,
    }

    /// The window at the press. `ChatOnShow`: a chat is the page on show. `WindowActive`: the main window has the
    /// keyboard. `Covered`: a dialog, a menu or flyout, Open Quickly or the Keyboard Shortcuts sheet is open over it
    /// (the Mac's `presented(root)`, a menu being tracked, a panel's window). `BoxDocked`: a question or approval card
    /// covers the message box (`questionCard`). `BoxReady`: see `BoxReady`.
    public sealed record Scene(bool ChatOnShow, bool WindowActive, bool Covered, Focus Focused, bool BoxDocked, bool BoxReady);

    /// The box there to type in: shown, enabled and editable (`!isHidden, isEditable, isUserInteractionEnabled`).
    /// Sending may be off (offline, a reply running, the chat loading): the box stays editable, so a draft can be typed.
    public static bool BoxReady(bool shown, bool enabled, bool readOnly) => shown && enabled && !readOnly;

    /// `take` and `chatTakingKeys`: the press goes to the open chat's box.
    public static bool Forwards(int key, bool ctrl, bool alt, bool win, Scene scene) =>
        Takes(key, ctrl, alt, win)
        && scene.ChatOnShow && scene.WindowActive && !scene.Covered && !scene.BoxDocked && scene.BoxReady
        && scene.Focused is Focus.Nothing or Focus.Other;

    /// The press after the box has taken the keyboard. Normally the press's character arrives in the box by itself
    /// (focus moved before the character was handed out). Should it still reach the element that had the keyboard, the
    /// box takes it once; any later press, a dead key's letter included, is typed in the box already.
    public sealed class Relay
    {
        private bool _pending;

        /// Every key-down, forwarded or not: only the forwarded press's own character is owed to the box.
        public void KeyDown(bool forwarded) => _pending = forwarded;

        /// A character handed out. True: put it in the box (it went elsewhere). `inBox`: the box received it.
        public bool Character(bool inBox)
        {
            var owed = _pending && !inBox;
            _pending = false;
            return owed;
        }
    }
}
