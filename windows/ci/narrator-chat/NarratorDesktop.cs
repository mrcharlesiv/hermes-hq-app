using System.Runtime.InteropServices;

namespace HermesHQ;

internal sealed class NarratorStop(string code) : Exception(code) { internal string Code => Message; }
internal enum ChatKey { Previous, Next, Draft, CopyPhrase }

// Only these four keyboard chords exist. No pointer, system toggle, Enter, activation, focus assignment or fallback.
internal static class NarratorDesktop
{
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(nint hwnd, out uint pid);
    [DllImport("user32.dll")] private static extern bool IsChild(nint parent, nint child);
    [StructLayout(LayoutKind.Sequential)]
    private struct GuiThreadInfo
    {
        public uint Size, Flags;
        public nint Active, Focus, Capture, MenuOwner, MoveSize, Caret;
        public int Left, Top, Right, Bottom;
    }
    [DllImport("user32.dll")] private static extern bool GetGUIThreadInfo(uint thread, ref GuiThreadInfo info);
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);

    internal static long Front(nint app)
    {
        if (app == 0 || GetForegroundWindow() != app) throw new NarratorStop("foreground-left-app");
        var thread = GetWindowThreadProcessId(app, out var pid);
        var gui = new GuiThreadInfo { Size = (uint)Marshal.SizeOf<GuiThreadInfo>() };
        if (thread == 0 || pid != Environment.ProcessId || !GetGUIThreadInfo(thread, ref gui) || gui.Active != app ||
            gui.Focus == 0 || (gui.Focus != app && !IsChild(app, gui.Focus)) ||
            GetWindowThreadProcessId(gui.Focus, out var owner) == 0 || owner != pid || gui.MenuOwner != 0 ||
            gui.Capture != 0 || gui.MoveSize != 0 || (gui.Flags & 0x1e) != 0)
            throw new NarratorStop("unknown-native-focus");
        return app.ToInt64();
    }

    // 64-bit INPUT is 40 bytes; the KEYBDINPUT union begins at byte 8. The parent only publishes win-x64.
    [StructLayout(LayoutKind.Explicit, Size = 40)]
    private struct Input
    {
        [FieldOffset(0)] public uint Type;
        [FieldOffset(8)] public ushort Vk;
        [FieldOffset(12)] public uint Flags;
    }
    [DllImport("user32.dll")] private static extern uint SendInput(uint count, Input[] keys, int size);

    internal static (long Front, uint Inserted) Press(nint app, ChatKey key, Action checkFocusedControl)
    {
        ushort[] chord = key switch
        {
            ChatKey.Previous => [0x10, 0x09], ChatKey.Next => [0x09], ChatKey.Draft => [0x51],
            ChatKey.CopyPhrase => [0x2D, 0x11, 0x58], // Insert (Narrator) + Control + X: copy last spoken phrase
            _ => throw new ArgumentOutOfRangeException(nameof(key)),
        };
        var input = chord.Select(vk => Event(vk, false)).Concat(chord.Reverse().Select(vk => Event(vk, true))).ToArray();
        // A pre-held modifier can turn Tab into a system shortcut. Never try to release a key we didn't press.
        Front(app);
        foreach (var vk in new[] { 0x10, 0x11, 0x12, 0x14, 0x2D, 0x5B, 0x5C, 0x09, 0x51, 0x58 })
            if (GetAsyncKeyState(vk) < 0) throw new NarratorStop("key-already-down");
        checkFocusedControl();
        var front = Front(app); // last check before the one atomic input batch; no restoration of stolen focus
        return (front, SendInput((uint)input.Length, input, Marshal.SizeOf<Input>()));
    }

    private static Input Event(ushort vk, bool up) => new() { Type = 1, Vk = vk, Flags = (up ? 2u : 0u) | (vk == 0x2D ? 1u : 0u) };

    [DllImport("user32.dll")] internal static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] private static extern nint GetClipboardOwner();
    [DllImport("user32.dll")] private static extern bool OpenClipboard(nint hwnd);
    [DllImport("user32.dll")] private static extern bool CloseClipboard();
    [DllImport("user32.dll")] private static extern int CountClipboardFormats();
    [DllImport("user32.dll")] private static extern nint GetClipboardData(uint format);
    [DllImport("kernel32.dll")] private static extern nuint GlobalSize(nint handle);
    [DllImport("kernel32.dll")] private static extern nint GlobalLock(nint handle);
    [DllImport("kernel32.dll")] private static extern bool GlobalUnlock(nint handle);

    private static int ClipboardOwner()
    {
        var hwnd = GetClipboardOwner();
        return hwnd != 0 && GetWindowThreadProcessId(hwnd, out var pid) != 0 ? checked((int)pid) : 0;
    }

    internal static bool MayCopy(nint app, int reader, uint? last, out uint before)
    {
        before = 0;
        if (!OpenClipboard(app)) return false;
        try
        {
            before = GetClipboardSequenceNumber();
            return last.HasValue ? last == before && ClipboardOwner() == reader
                                 : CountClipboardFormats() == 0 && ClipboardOwner() == 0;
        }
        finally { CloseClipboard(); }
    }

    internal sealed record Phrase(uint Sequence, int Owner, string? Text, string? Unavailable);
    internal static Phrase? ReadNew(nint app, int reader, uint before)
    {
        if (GetClipboardSequenceNumber() == before || !OpenClipboard(app)) return null;
        try
        {
            var seq = GetClipboardSequenceNumber();
            if (seq == before) return null;
            var owner = ClipboardOwner();
            if (owner != reader) return new(seq, 0, null, "clipboard-owner-not-launched-narrator");
            var data = GetClipboardData(13); // CF_UNICODETEXT; never enumerate formats or read an unrelated owner's data
            var size = data == 0 ? 0 : GlobalSize(data);
            if (size is < 2 or > 1024 || size % 2 != 0) return new(seq, owner, null, "no-bounded-unicode-phrase");
            var ptr = GlobalLock(data);
            if (ptr == 0) return new(seq, owner, null, "unreadable-phrase");
            try
            {
                // Read only to the first terminator, within the allocated buffer. Retain exact synthetic words or nothing.
                var chars = 0;
                while (chars < (int)size / 2 && Marshal.ReadInt16(ptr, chars * 2) != 0) chars++;
                if (chars == 0 || chars == (int)size / 2 || chars > 240) return new(seq, owner, null, "no-bounded-phrase");
                var text = Marshal.PtrToStringUni(ptr, chars)!;
                if (GetClipboardSequenceNumber() != seq || ClipboardOwner() != reader) return new(seq, 0, null, "clipboard-changed");
                return SafeWords(text) ? new(seq, owner, text, null) : new(seq, owner, null, "unexpected-words-not-retained");
            }
            finally { GlobalUnlock(data); }
        }
        finally { CloseClipboard(); }
    }

    // Do not archive ambient narration, even from the correct reader. No broad text or audio capture.
    private static bool SafeWords(string text)
    {
        const string vocabulary = "inspector message proof hermes send toggle button edit editing text box multi line multiline blank empty " +
                                  "on off checked unchecked not pressed selected unselected collapsed expanded available unavailable read only q " +
                                  "press space enter to activate type in this field can contain multiple lines of";
        var words = System.Text.RegularExpressions.Regex.Split(text.Trim().ToLowerInvariant(), @"[\s.,:;!()\-]+")
            .Where(w => w.Length > 0).ToArray();
        return words.Length > 0 && words.All(vocabulary.Split(' ').ToHashSet(StringComparer.Ordinal).Contains);
    }
}
