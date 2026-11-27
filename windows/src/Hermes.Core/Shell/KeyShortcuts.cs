namespace Hermes.Core.Shell;

/// One key with its modifiers, as Windows writes it ("Ctrl+Shift+S", "F5", "Esc"). `Key` is the key's own name:
/// a letter or digit, "," "/" "-", "Plus", "Enter", "Tab", "Esc", "F5".
public sealed record KeyChord(string Key, bool Ctrl = false, bool Shift = false, bool Alt = false)
{
    public string Display => (Ctrl ? "Ctrl+" : "") + (Alt ? "Alt+" : "") + (Shift ? "Shift+" : "") + Key;

    /// In words for Narrator ("Control Shift S"), as the Mac's `spokenKey` gives VoiceOver.
    public string Spoken
    {
        get
        {
            var words = new List<string>();
            if (Ctrl) words.Add("Control");
            if (Alt) words.Add("Alt");
            if (Shift) words.Add("Shift");
            words.Add(Key switch
            {
                "," => "Comma", "/" => "Slash", "-" => "Minus", "Esc" => "Escape", "[" => "Left Bracket", "]" => "Right Bracket",
                "Down" => "Down Arrow", "Up" => "Up Arrow",
                _ => Key,
            });
            return string.Join(" ", words);
        }
    }
}

/// The keys the window's shell registers itself (Pages/ShellPage.xaml.cs registers each one of these, by name).
public static class ShellKeys
{
    public static readonly KeyChord Settings = new(",", Ctrl: true);
    public static readonly KeyChord NewChat = new("N", Ctrl: true);
    /// File › New Chat Here, the Mac's ⌥⌘N (⌥ is Alt): a new chat with the open chat's bot, in its project (ChatKeys).
    /// Ctrl+Alt is AltGr too, so the shell lets the press through while the right Alt key is down (`ChatKeys.Takes`).
    public static readonly KeyChord NewChatHere = new("N", Ctrl: true, Alt: true);
    /// File › New Chat With…, the Mac's ⇧⌘N: the one New Chat sheet, a bot and a project (Features/NewChat).
    public static readonly KeyChord NewChatWith = new("N", Ctrl: true, Shift: true);
    /// File › Close Chat, the Mac's ⌘W, and Windows' own close-the-document key.
    public static readonly KeyChord CloseChat = new("W", Ctrl: true);
    /// File › Archive Chat, the Mac's ⌃⌘A. Ctrl+Shift+A, the Hide Sidebar pattern (⌃⌘S → Ctrl+Shift+S), is Attach
    /// Files (the Mac's ⇧⌘A), so ⌃ is Alt here; the iPad's ⌘⌫ is the Mac's Delete Chat…, and Ctrl+Backspace deletes a
    /// word in the message box.
    public static readonly KeyChord ArchiveChat = new("A", Ctrl: true, Alt: true);
    public static readonly KeyChord OpenQuickly = new("K", Ctrl: true);
    /// Edit › Favorites…, the Mac's ⇧⌘K beside Open Quickly's ⌘K (KeyCommands.quickActions).
    public static readonly KeyChord QuickActions = new("K", Ctrl: true, Shift: true);
    public static readonly KeyChord HideSidebar = new("S", Ctrl: true, Shift: true);
    public static readonly KeyChord Refresh = new("R", Ctrl: true);
    public static readonly KeyChord RefreshAlt = new("F5");
    /// Help › Keyboard Shortcuts: the Mac's ⌘/ (KeyCommands.helpItems).
    public static readonly KeyChord KeyboardShortcuts = new("/", Ctrl: true);
    /// View › Next Chat / Previous Chat, the Mac's ⌘↓ / ⌘↑ (WalkKeys): the next or previous row of the list the chat on
    /// show was opened from. The Mac's second keys are not Windows': ⌃Tab / ⌃⇧Tab are the Terminal's Show Next / Previous
    /// Tab here (its ⇧⌘] / ⇧⌘[), and the plain arrows move the keyboard's focus through a list.
    public static readonly KeyChord NextChat = new("Down", Ctrl: true);
    public static readonly KeyChord PreviousChat = new("Up", Ctrl: true);
    /// Ctrl+1…9: the sidebar's places in the Mac's numbered order (the Mac's ⌘1…⌘9, PlaceKeys): Bots, the places, the
    /// Tools, Ctrl+9 the last of more than nine.
    public static KeyChord Place(int n) => new(n.ToString(System.Globalization.CultureInfo.InvariantCulture), Ctrl: true);
}

/// A key the app really registers: what it is, the file under `src/HermesHQ.Windows` that registers it, and the text of
/// that registration (ShortcutsSheetTests reads the file, so the table can't drift from the code).
public sealed record RegisteredKey(KeyChord Chord, string Source, string Needle);

/// One row of the Mac's menus: its title, the Mac's keys (the menu key, then `KeyCommands.alternates`' second keys),
/// the Windows keys that do the same, and, where Windows has none, why (`Gap`). `IsPlaces`: the ⌘1…⌘9 row, which the
/// sheet expands into one row per sidebar row.
public sealed record MacKeyRow(string Title, IReadOnlyList<string> MacKeys, IReadOnlyList<KeyChord> Windows, string? Gap = null, bool IsPlaces = false);

public sealed record MacKeySection(string Title, IReadOnlyList<MacKeyRow> Rows, string? Footer = null);

/// A row of the Windows sheet: the command's name and its keys.
public sealed record ShortcutRow(string Title, IReadOnlyList<KeyChord> Keys)
{
    /// The keys as the row shows them, three spaces apart (the Mac joins its keys the same way).
    public string KeysText => string.Join("   ", Keys.Select(k => k.Display));
    /// The keys in words, joined ", or " as the Mac's accessibility value is.
    public string Spoken => string.Join(", or ", Keys.Select(k => k.Spoken));
    /// What Narrator reads for the row: the name, then its keys.
    public string AccessibleName => $"{Title}, {Spoken}";
}

public sealed record ShortcutSection(string Title, IReadOnlyList<ShortcutRow> Rows, string? Footer = null);

/// What the Mac's `validate` reads when it names a menu item, and so what the sheet's titles say (KeyCommands.swift,
/// ChatMenuBar.swift at 93f984bb1). `NewChatBot`: the shown name of the bot Ctrl+N starts a chat with (null with no bot);
/// `SidebarFolded`: the sidebar is a rail; `InspectorShown`: the chat on show has its inspector open.
public sealed record ShortcutState(string? NewChatBot, bool SidebarFolded = false, bool InspectorShown = false)
{
    /// The bot's name as the Mac's ⌘N item gives it: the roster's name, "Hermes" for `default`, else the profile id
    /// (`bots.first { $0.id == id }?.name ?? (id == "default" ? "Hermes" : id)`).
    public static string? BotName(string? id, string? displayName) =>
        id == null ? null : displayName ?? (id == "default" ? "Hermes" : id);
}

/// Help › Keyboard Shortcuts (App/Mac/MacShortcutsSheet.swift): every key the menu bar offers, menu by menu, in the
/// menus' order and words (KeyCommands.swift, ChatMenuBar.swift). Windows has no menu bar; the sheet keeps the Mac's
/// menus as its sections and lists, for each command, the key Windows really registers. A command Windows has no key
/// for is left out, as the Mac leaves out what `validate` hides, so the sheet never lists a key that does nothing.
public static class KeyShortcuts
{
    private static readonly KeyChord[] None = [];
    private static MacKeyRow Row(string title, string mac, params KeyChord[] windows) => new(title, mac.Split(' '), windows);
    private static MacKeyRow Gap(string title, string mac, string why) => new(title, mac.Split(' '), None, why);

    private const string NotYet = "not on Windows yet";

    /// The Mac's sections at the reference build (93f984bb1), Catalyst branch: Hermes HQ, File, Edit, View, Chat, then
    /// Window (only while the Terminal is in the sidebar) before Help.
    public static readonly IReadOnlyList<MacKeySection> MacCatalogue =
    [
        new("Hermes HQ", [Row("Settings…", "⌘,", ShellKeys.Settings)]),
        new("File",
        [
            Row("New Chat", "⌘N", ShellKeys.NewChat),
            Row("New Chat Here", "⌥⌘N", ShellKeys.NewChatHere),
            // The Mac's ⇧⌘N opens the one New Chat sheet (bots as pills, projects, New Project…): Features/NewChat.
            Row("New Chat With…", "⇧⌘N", ShellKeys.NewChatWith),
            Row("Close Chat", "⌘W", ShellKeys.CloseChat),
            Gap("Close Window", "⇧⌘W", "one window on Windows; closing it quits the app"),
            Row("Archive Chat", "⌃⌘A", ShellKeys.ArchiveChat),
        ]),
        new("Edit",
        [
            // [chat find] Ctrl+F opens the open chat's Find bar (other pages' Ctrl+F still focuses their own search).
            // Find Next / Previous: the Mac's ⌘G / ⇧⌘G as Ctrl+G / Ctrl+Shift+G, and F3 / Shift+F3, Windows' own.
            Row("Find…", "⌘F", Keys.Find),
            Row("Find Next", "⌘G", Keys.FindNext, Keys.FindNextAlt),
            Row("Find Previous", "⇧⌘G", Keys.FindPrevious, Keys.FindPreviousAlt),
            Gap("Search Sessions", "⇧⌘F", NotYet),
            Row("Open Quickly…", "⌘K", ShellKeys.OpenQuickly),
            Row("Favorites…", "⇧⌘K", ShellKeys.QuickActions),
        ]),
        new("View",
        [
            Row("Hide Sidebar", "⌃⌘S", ShellKeys.HideSidebar),
            Row("Show Inspector", "⌘I", Keys.Inspector),
            new("Places", ["⌘1…⌘9"], [ShellKeys.Place(1)], IsPlaces: true),
            // ⌘↓ / ⌘↑ are Ctrl+Down / Ctrl+Up; ⌃Tab / ⌃⇧Tab are the Terminal's tab keys on Windows and plain ↓ / ↑ move
            // a list's focus (ShellKeys.NextChat).
            new("Next Chat", ["⌘↓", "⌃⇥", "↓"], [ShellKeys.NextChat]),
            new("Previous Chat", ["⌘↑", "⌃⇧⇥", "↑"], [ShellKeys.PreviousChat]),
            Gap("Back", "⌘[", "Alt+Left goes back only inside some pages; no app-wide Back yet"),
            Row("Refresh", "⌘R", ShellKeys.Refresh, ShellKeys.RefreshAlt),
            Row("Make Text Bigger", "⌘+ ⌘=", Keys.TextBigger),
            Row("Actual Size", "⌘0", Keys.TextActual),
            Row("Make Text Smaller", "⌘-", Keys.TextSmaller),
        ]),
        new("Chat",
        [
            Gap("Go to Message Field", "⌘L ↩", NotYet),
            Row("Send", "⌘↩", Keys.Send),
            new("Stop Reply, Close or Go Back", ["⎋", "⌘."], [Keys.Escape]),   // ⌘. has no Windows meaning
            Gap("Message Actions", "⌃↩", NotYet),
            Row("Attach Files…", "⇧⌘A", Keys.AttachFiles),
            Gap("Record Voice Memo", "⇧⌘R", NotYet),
            Gap("Dictate with Hermes", "⇧⌘D", NotYet),
            Gap("Talk", "⇧⌘T", NotYet),
            Gap("Mute Talk", "⇧⌘M", NotYet),
            Gap("End Talk", "⇧⌘E", NotYet),
            Gap("Pin", "⇧⌘P", NotYet),
            Gap("Mark as Unread", "⇧⌘U", NotYet),
            Gap("Choose Model…", "⌃⌘M", NotYet),
            Gap("Delete Chat…", "⌘⌫", NotYet),
        ]),
        new("Window",
        [
            Row("New Tab", "⌘T", Keys.TerminalNewTab),
            Row("Show Previous Tab", "⇧⌘[", Keys.TerminalPreviousTab),
            Row("Show Next Tab", "⇧⌘]", Keys.TerminalNextTab),
        ],
        // The Mac's: "In the Window menu while the Terminal is open. While it is in front, Make Text Bigger, Actual Size
        // and Make Text Smaller (⌘+ ⌘0 ⌘-) size its text, not the app’s." Windows has no Window menu, and the
        // Terminal's keys act while it is in front (TerminalPage.OnKey).
        Footer: "While the Terminal is in front, Make Text Bigger, Actual Size and Make Text Smaller (Ctrl+Plus Ctrl+0 Ctrl+-) size its text, not the app’s."),
        new("Help", [Row("Keyboard Shortcuts", "⌘/", ShellKeys.KeyboardShortcuts)]),
    ];

    /// The keys other parts of the app register (not the shell's own).
    private static class Keys
    {
        public static readonly KeyChord Inspector = new("I", Ctrl: true);
        public static readonly KeyChord TextBigger = new("Plus", Ctrl: true);
        public static readonly KeyChord TextActual = new("0", Ctrl: true);
        public static readonly KeyChord TextSmaller = new("-", Ctrl: true);
        public static readonly KeyChord Send = new("Enter", Ctrl: true);
        public static readonly KeyChord Escape = new("Esc");
        public static readonly KeyChord AttachFiles = new("A", Ctrl: true, Shift: true);
        public static readonly KeyChord TerminalNewTab = new("T", Ctrl: true, Shift: true);
        public static readonly KeyChord TerminalPreviousTab = new("Tab", Ctrl: true, Shift: true);
        public static readonly KeyChord TerminalNextTab = new("Tab", Ctrl: true);
        public static readonly KeyChord Find = new("F", Ctrl: true);
        public static readonly KeyChord FindNext = new("G", Ctrl: true);
        public static readonly KeyChord FindNextAlt = new("F3");
        public static readonly KeyChord FindPrevious = new("G", Ctrl: true, Shift: true);
        public static readonly KeyChord FindPreviousAlt = new("F3", Shift: true);
    }

    /// Every accelerator the sheet may list, with where the app registers it (paths under src/HermesHQ.Windows).
    public static readonly IReadOnlyList<RegisteredKey> Registered =
    [
        new(ShellKeys.Settings, "Pages/ShellPage.xaml.cs", "AddShortcut(ShellKeys.Settings,"),
        new(ShellKeys.NewChat, "Pages/ShellPage.xaml.cs", "AddShortcut(ShellKeys.NewChat,"),
        new(ShellKeys.NewChatHere, "Pages/ShellPage.xaml.cs", "AddShortcut(ShellKeys.NewChatHere,"),
        new(ShellKeys.NewChatWith, "Pages/ShellPage.xaml.cs", "AddShortcut(ShellKeys.NewChatWith,"),
        new(ShellKeys.CloseChat, "Pages/ShellPage.xaml.cs", "AddShortcut(ShellKeys.CloseChat,"),
        new(ShellKeys.ArchiveChat, "Pages/ShellPage.xaml.cs", "AddShortcut(ShellKeys.ArchiveChat,"),
        new(ShellKeys.OpenQuickly, "Pages/ShellPage.xaml.cs", "AddShortcut(ShellKeys.OpenQuickly, ShowOpenQuickly);"),   // the panel (Features/OpenQuickly)
        new(ShellKeys.QuickActions, "Pages/ShellPage.xaml.cs", "AddShortcut(ShellKeys.QuickActions,"),   // the page (Features/QuickActions)
        new(ShellKeys.HideSidebar, "Pages/ShellPage.xaml.cs", "AddShortcut(ShellKeys.HideSidebar,"),
        new(ShellKeys.NextChat, "Pages/ShellPage.xaml.cs", "AddShortcut(ShellKeys.NextChat,"),
        new(ShellKeys.PreviousChat, "Pages/ShellPage.xaml.cs", "AddShortcut(ShellKeys.PreviousChat,"),
        new(ShellKeys.Refresh, "Pages/ShellPage.xaml.cs", "AddShortcut(ShellKeys.Refresh,"),
        new(ShellKeys.RefreshAlt, "Pages/ShellPage.xaml.cs", "AddShortcut(ShellKeys.RefreshAlt,"),
        new(ShellKeys.KeyboardShortcuts, "Pages/ShellPage.xaml.cs", "AddShortcut(ShellKeys.KeyboardShortcuts,"),
        .. Enumerable.Range(1, 9).Select(n => new RegisteredKey(ShellKeys.Place(n), "Pages/ShellPage.xaml.cs", "AddShortcut(ShellKeys.Place(n),")),
        new(Keys.Inspector, "Pages/ChatPage.xaml", "<KeyboardAccelerator Key=\"I\" Modifiers=\"Control\" />"),
        new(Keys.TextBigger, "Features/Settings/ThemeService.cs", "AddKey(root, (VirtualKey)187, +1);"),
        new(Keys.TextActual, "Features/Settings/ThemeService.cs", "AddKey(root, VirtualKey.Number0, 0);"),
        new(Keys.TextSmaller, "Features/Settings/ThemeService.cs", "AddKey(root, (VirtualKey)189, -1);"),
        new(Keys.Send, "Features/Composer/ComposerController.cs", "if (e.Key == VirtualKey.Enter && Down(VirtualKey.Control) && _editingId == null)"),
        new(Keys.Escape, "Pages/ChatPage.xaml.cs", "else if (e.Key == VirtualKey.Escape && _vm?.Busy == true)"),
        new(Keys.AttachFiles, "Features/Attachments/ChatAttachments.cs", "new KeyboardAccelerator { Key = VirtualKey.A, Modifiers = VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift }"),
        new(Keys.TerminalNewTab, "Features/Workspace/TerminalPage.cs", "case VirtualKey.T when shift: NewTab();"),
        new(Keys.TerminalPreviousTab, "Features/Workspace/TerminalPage.cs", "case VirtualKey.Tab: Cycle(shift ? -1 : 1);"),
        new(Keys.TerminalNextTab, "Features/Workspace/TerminalPage.cs", "case VirtualKey.Tab: Cycle(shift ? -1 : 1);"),
        new(Keys.Find, "Features/ChatFind/ChatFindFeature.cs", "Accelerator(page, VirtualKey.F, VirtualKeyModifiers.Control, bar.Open);"),
        new(Keys.FindNext, "Features/ChatFind/ChatFindFeature.cs", "Accelerator(page, VirtualKey.G, VirtualKeyModifiers.Control, () => bar.Step(forward: true));"),
        new(Keys.FindNextAlt, "Features/ChatFind/ChatFindFeature.cs", "Accelerator(page, VirtualKey.F3, VirtualKeyModifiers.None, () => bar.Step(forward: true));"),
        new(Keys.FindPrevious, "Features/ChatFind/ChatFindFeature.cs", "Accelerator(page, VirtualKey.G, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, () => bar.Step(forward: false));"),
        new(Keys.FindPreviousAlt, "Features/ChatFind/ChatFindFeature.cs", "Accelerator(page, VirtualKey.F3, VirtualKeyModifiers.Shift, () => bar.Step(forward: false));"),
    ];

    /// The Mac's commands Windows has no key for yet, with why.
    public static IEnumerable<MacKeyRow> Gaps => MacCatalogue.SelectMany(s => s.Rows).Where(r => r.Windows.Count == 0);

    /// A row's title as the Mac's `validate` names its menu item now: File › New Chat for the bot Ctrl+N starts with
    /// (KeyCommands.swift `name.map { "New Chat with \($0)\(place)" } ?? "New Chat\(place)…"`; Windows' Ctrl+N takes no
    /// project, so no place), View's sidebar and inspector rows for what they would do (`MacSidebar.isCollapsed ?
    /// "Show Sidebar" : "Hide Sidebar"`, ChatMenuBar.swift `visible ? "Hide Inspector" : "Show Inspector"`).
    private static string Titled(string title, ShortcutState state) => title switch
    {
        "New Chat" => state.NewChatBot is { } bot ? $"New Chat with {bot}" : "New Chat…",
        "Hide Sidebar" => state.SidebarFolded ? "Show Sidebar" : "Hide Sidebar",
        "Show Inspector" => state.InspectorShown ? "Hide Inspector" : "Show Inspector",
        _ => title,
    };

    /// The sheet as it reads now. `numbered`: the places' names in the Mac's numbered order (`PlaceKeys.Numbered`: Bots,
    /// the places, the Tools); Ctrl+1 opens the first, Ctrl+9 the last of more than nine, and a number with no place is
    /// left out, as the Mac hides a ⌘6 with no sixth place. `terminal`: the Terminal is in the
    /// sidebar (the Mac lists Window only then). `state`: what the state-named titles read (no bot, sidebar open,
    /// inspector hidden when not given). A section left with no rows is not shown.
    public static IReadOnlyList<ShortcutSection> Sections(IReadOnlyList<string> numbered, bool terminal, ShortcutState? state = null)
    {
        state ??= new ShortcutState(NewChatBot: null);
        var out_ = new List<ShortcutSection>();
        foreach (var section in MacCatalogue)
        {
            if (section.Title == "Window" && !terminal) continue;
            var rows = new List<ShortcutRow>();
            foreach (var row in section.Rows)
            {
                if (row.IsPlaces)
                    rows.AddRange(Enumerable.Range(0, PlaceKeys.Keys).Select(n => (n, at: PlaceKeys.Place(n, numbered.Count)))
                        .Where(p => p.at != null).Select(p => new ShortcutRow(numbered[p.at!.Value], [ShellKeys.Place(p.n + 1)])));
                else if (row.Windows.Count > 0)
                    rows.Add(new ShortcutRow(Titled(row.Title, state), row.Windows));
            }
            if (rows.Count > 0) out_.Add(new ShortcutSection(section.Title, rows, section.Footer));
        }
        return out_;
    }
}
