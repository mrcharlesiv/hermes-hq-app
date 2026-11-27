using System.Text.RegularExpressions;
using Hermes.Core.Shell;

namespace Hermes.Core.Tests;

/// Help › Keyboard Shortcuts (App/Mac/MacShortcutsSheet.swift at 93f984bb1): the Mac's sections, order and words, each
/// key mapped to the binding Windows really registers, and nothing listed that Windows does not have.
public class ShortcutsSheetTests
{
    private static readonly string[] Numbered = ["Otto", "Herald", "Sessions"];

    // The Mac's menus as `KeyShortcutsSheet.sections()` walks them at 93f984bb1 (KeyCommands.swift, ChatMenuBar.swift),
    // Catalyst branch: section, then each keyed command's title and its keys (second keys from `alternates` after it).
    private static readonly (string Section, (string Title, string Keys)[] Rows)[] MacAt93f984bb1 =
    [
        ("Hermes HQ", [("Settings…", "⌘,")]),
        ("File", [("New Chat", "⌘N"), ("New Chat Here", "⌥⌘N"), ("New Chat With…", "⇧⌘N"), ("Close Chat", "⌘W"),
                  ("Close Window", "⇧⌘W"), ("Archive Chat", "⌃⌘A")]),
        ("Edit", [("Find…", "⌘F"), ("Find Next", "⌘G"), ("Find Previous", "⇧⌘G"), ("Search Sessions", "⇧⌘F"),
                  ("Open Quickly…", "⌘K"), ("Quick Actions…", "⇧⌘K")]),
        ("View", [("Hide Sidebar", "⌃⌘S"), ("Show Inspector", "⌘I"), ("Places", "⌘1…⌘9"),
                  ("Next Chat", "⌘↓ ⌃⇥ ↓"), ("Previous Chat", "⌘↑ ⌃⇧⇥ ↑"), ("Back", "⌘["), ("Refresh", "⌘R"),
                  ("Make Text Bigger", "⌘+ ⌘="), ("Actual Size", "⌘0"), ("Make Text Smaller", "⌘-")]),
        ("Chat", [("Go to Message Field", "⌘L ↩"), ("Send", "⌘↩"), ("Stop Reply, Close or Go Back", "⎋ ⌘."),
                  ("Message Actions", "⌃↩"), ("Attach Files…", "⇧⌘A"), ("Record Voice Memo", "⇧⌘R"),
                  ("Dictate with Hermes", "⇧⌘D"), ("Talk", "⇧⌘T"), ("Mute Talk", "⇧⌘M"), ("End Talk", "⇧⌘E"),
                  ("Pin", "⇧⌘P"), ("Mark as Unread", "⇧⌘U"), ("Choose Model…", "⌃⌘M"), ("Delete Chat…", "⌘⌫")]),
        ("Window", [("New Tab", "⌘T"), ("Show Previous Tab", "⇧⌘["), ("Show Next Tab", "⇧⌘]")]),
        ("Help", [("Keyboard Shortcuts", "⌘/")]),
    ];

    [Fact]
    public void TheCatalogueIsTheMacsMenusInOrderWithTheirWordsAndKeys()
    {
        var catalogue = KeyShortcuts.MacCatalogue;
        Assert.Equal(MacAt93f984bb1.Select(s => s.Section), catalogue.Select(s => s.Title));
        foreach (var (section, rows) in MacAt93f984bb1)
        {
            var mine = catalogue.Single(s => s.Title == section).Rows;
            // Keep the older menu snapshot intact; 1250 renamed this one command without changing its keys.
            Assert.Equal(rows.Select(r => section == "Edit" && r.Keys == "⇧⌘K" ? "Favorites…" : r.Title), mine.Select(r => r.Title));
            Assert.Equal(rows.Select(r => r.Keys), mine.Select(r => string.Join(" ", r.MacKeys)));
        }
    }

    [Fact]
    public void TheSheetListsTheMacsSectionsInOrderLeavingOutKeysWindowsHasNot()
    {
        var sheet = KeyShortcuts.Sections(Numbered, terminal: false, new ShortcutState(NewChatBot: "Otto"));
        Assert.Equal(["Hermes HQ", "File", "Edit", "View", "Chat", "Help"], sheet.Select(s => s.Title));
        Rows(sheet, "Hermes HQ", ("Settings…", "Ctrl+,"));
        Rows(sheet, "File", ("New Chat with Otto", "Ctrl+N"), ("New Chat Here", "Ctrl+Alt+N"), ("New Chat With…", "Ctrl+Shift+N"), ("Close Chat", "Ctrl+W"), ("Archive Chat", "Ctrl+Alt+A"));
        Rows(sheet, "Edit", ("Find…", "Ctrl+F"), ("Find Next", "Ctrl+G   F3"), ("Find Previous", "Ctrl+Shift+G   Shift+F3"), ("Open Quickly…", "Ctrl+K"),
            ("Favorites…", "Ctrl+Shift+K"));
        Rows(sheet, "View", ("Hide Sidebar", "Ctrl+Shift+S"), ("Show Inspector", "Ctrl+I"), ("Otto", "Ctrl+1"),
            ("Herald", "Ctrl+2"), ("Sessions", "Ctrl+3"), ("Next Chat", "Ctrl+Down"), ("Previous Chat", "Ctrl+Up"), ("Refresh", "Ctrl+R   F5"), ("Make Text Bigger", "Ctrl+Plus"),
            ("Actual Size", "Ctrl+0"), ("Make Text Smaller", "Ctrl+-"));
        Rows(sheet, "Chat", ("Send", "Ctrl+Enter"), ("Stop Reply, Close or Go Back", "Esc"), ("Attach Files…", "Ctrl+Shift+A"));
        Rows(sheet, "Help", ("Keyboard Shortcuts", "Ctrl+/"));
        Assert.All(sheet, s => Assert.Null(s.Footer));
    }

    [Fact]
    public void ANumberWithNoSidebarRowIsLeftOutAndNineIsTheLast()
    {
        var none = KeyShortcuts.Sections([], terminal: false).Single(s => s.Title == "View").Rows.Select(r => r.Title).ToList();
        Assert.Equal(["Hide Sidebar", "Show Inspector", "Next Chat", "Previous Chat", "Refresh", "Make Text Bigger", "Actual Size", "Make Text Smaller"], none);
        var twelve = Enumerable.Range(1, 12).Select(i => $"Row {i}").ToList();
        var view = KeyShortcuts.Sections(twelve, terminal: false).Single(s => s.Title == "View").Rows.Where(r => r.Title.StartsWith("Row ")).ToList();
        Assert.Equal(Enumerable.Range(1, 9).Select(i => $"Ctrl+{i}"), view.Select(r => r.Keys[0].Display));
        // [WIN-26] As the Mac's ⌘9 (TabShortcut): past nine places Ctrl+9 picks the last, and Rows 9–11 have no number.
        Assert.Equal([.. Enumerable.Range(1, 8).Select(i => $"Row {i}"), "Row 12"], view.Select(r => r.Title));
    }

    [Fact]
    public void TheTerminalsWindowSectionComesBeforeHelpWithItsFooter()
    {
        var sheet = KeyShortcuts.Sections(Numbered, terminal: true);
        Assert.Equal(["Hermes HQ", "File", "Edit", "View", "Chat", "Window", "Help"], sheet.Select(s => s.Title));
        Rows(sheet, "Window", ("New Tab", "Ctrl+Shift+T"), ("Show Previous Tab", "Ctrl+Shift+Tab"), ("Show Next Tab", "Ctrl+Tab"));
        Assert.Equal("While the Terminal is in front, Make Text Bigger, Actual Size and Make Text Smaller (Ctrl+Plus Ctrl+0 Ctrl+-) size its text, not the app’s.",
            sheet.Single(s => s.Title == "Window").Footer);
    }

    [Fact]
    public void KeysAreSpokenInWordsForNarrator()
    {
        var rows = KeyShortcuts.Sections(Numbered, terminal: true).SelectMany(s => s.Rows).ToDictionary(r => r.Title);
        Assert.Equal("Control Comma", rows["Settings…"].Spoken);
        Assert.Equal("Control Shift S", rows["Hide Sidebar"].Spoken);
        Assert.Equal("Control Alt N", rows["New Chat Here"].Spoken);
        Assert.Equal("Control W", rows["Close Chat"].Spoken);
        Assert.Equal("Control R, or F5", rows["Refresh"].Spoken);
        Assert.Equal("Escape", rows["Stop Reply, Close or Go Back"].Spoken);
        Assert.Equal("Control Slash", rows["Keyboard Shortcuts"].Spoken);
        Assert.Equal("Control Minus", rows["Make Text Smaller"].Spoken);
        Assert.Equal("Control Enter", rows["Send"].Spoken);
        Assert.Equal("Control Shift Tab", rows["Show Previous Tab"].Spoken);
        Assert.Equal("Control Down Arrow", rows["Next Chat"].Spoken);
        Assert.Equal("Control Up Arrow", rows["Previous Chat"].Spoken);
        Assert.Equal("Keyboard Shortcuts, Control Slash", rows["Keyboard Shortcuts"].AccessibleName);
        Assert.Equal("Favorites…, Control Shift K", rows["Favorites…"].AccessibleName);
    }

    [Fact]
    public void EveryMacRowIsEitherListedWithARealWindowsKeyOrNamedAsAGap()
    {
        foreach (var section in KeyShortcuts.MacCatalogue)
            foreach (var row in section.Rows)
            {
                if (row.Windows.Count == 0) Assert.False(string.IsNullOrWhiteSpace(row.Gap), $"{section.Title} › {row.Title} has no key and no gap");
                else Assert.Null(row.Gap);
            }
        var gaps = KeyShortcuts.Gaps.Select(g => g.Title).ToList();
        Assert.Contains("Search Sessions", gaps);
        Assert.DoesNotContain("Find…", gaps);
        // [WIN-26] View › Next Chat / Previous Chat are Ctrl+Down / Ctrl+Up.
        Assert.DoesNotContain("Next Chat", gaps);
        Assert.DoesNotContain("Previous Chat", gaps);
        Assert.DoesNotContain("New Chat", gaps);
        // [WIN-18] File's chat keys are Windows keys now; [WIN-22] New Chat With… opens the New Chat sheet.
        Assert.DoesNotContain("New Chat Here", gaps);
        Assert.DoesNotContain("Close Chat", gaps);
        Assert.DoesNotContain("Archive Chat", gaps);
        Assert.DoesNotContain("New Chat With…", gaps);
        Assert.DoesNotContain("Favorites…", gaps);
        // A gap is never on the sheet.
        var listed = KeyShortcuts.Sections(Numbered, terminal: true).SelectMany(s => s.Rows).Select(r => r.Title).ToHashSet();
        Assert.All(gaps, g => Assert.DoesNotContain(g, listed));
    }

    /// No drift: every key the sheet lists is in the table of accelerators the app registers.
    [Fact]
    public void EveryListedKeyIsARegisteredAccelerator()
    {
        var registered = KeyShortcuts.Registered.Select(r => r.Chord).ToHashSet();
        var listed = KeyShortcuts.Sections(Enumerable.Range(1, 9).Select(i => $"Row {i}").ToList(), terminal: true)
            .SelectMany(s => s.Rows).SelectMany(r => r.Keys).ToList();
        Assert.NotEmpty(listed);
        Assert.All(listed, k => Assert.True(registered.Contains(k), $"{k.Display} is listed but not registered"));
    }

    /// And the table is the source's own: each entry's registration is in the file it names.
    [Fact]
    public void EveryRegisteredAcceleratorIsInTheSourceItNames()
    {
        var src = Path.Combine(RepoRoot(), "windows", "src", "HermesHQ.Windows");
        foreach (var r in KeyShortcuts.Registered)
        {
            var file = Path.Combine(src, r.Source);
            Assert.True(File.Exists(file), $"{r.Source} is missing");
            var text = File.ReadAllText(file);
            Assert.True(text.Contains(r.Needle, StringComparison.Ordinal), $"{r.Chord.Display}: \"{r.Needle}\" is not in {r.Source}");
        }
    }

    /// The shell registers its keys from `ShellKeys`, one AddShortcut per key, so the sheet and the window agree.
    [Fact]
    public void TheShellRegistersEveryShellKey()
    {
        var shell = File.ReadAllText(Path.Combine(RepoRoot(), "windows", "src", "HermesHQ.Windows", "Pages", "ShellPage.xaml.cs"));
        foreach (var name in new[] { "OpenQuickly", "QuickActions", "NewChat", "NewChatHere", "CloseChat", "ArchiveChat", "Settings", "Refresh", "RefreshAlt", "HideSidebar", "KeyboardShortcuts", "NextChat", "PreviousChat" })
            Assert.Matches(new Regex($@"AddShortcut\(ShellKeys\.{name},"), shell);
        Assert.Contains("AddShortcut(ShellKeys.Place(n),", shell);
        Assert.Equal(new KeyChord("/", Ctrl: true), ShellKeys.KeyboardShortcuts);
        Assert.Equal(new KeyChord("R", Ctrl: true), ShellKeys.Refresh);
        Assert.Equal(new KeyChord("F5"), ShellKeys.RefreshAlt);
    }

    /// The words are the Swift app's: each listed Mac title is a literal in the Swift menu sources.
    [Fact]
    public void ListedTitlesAreTheSwiftStrings()
    {
        var root = RepoRoot();
        var files = new[] { "App/Root/KeyCommands.swift", "App/Root/ChatMenuBar.swift", "App/Mac/MacShortcutsSheet.swift" }
            .Select(p => Path.Combine(root, p)).ToArray();
        // The private Windows CI mirror carries only windows/ (no Swift); this drift check runs in the full checkout,
        // where the integrator's local gate runs it. Half a Swift tree is a broken checkout, not a mirror.
        if (!Directory.Exists(Path.Combine(root, "App"))) return;
        var swift = string.Join("\n", files.Select(File.ReadAllText));
        foreach (var section in KeyShortcuts.MacCatalogue)
        {
            Assert.Contains($"\"{section.Title}\"", swift);
            // This checkout's Swift predates Favorites. Build 1250 composes this command from IntentsText.quickActions.
            foreach (var row in section.Rows.Where(r => r.Windows.Count > 0 && !r.IsPlaces && !r.Windows.Contains(ShellKeys.QuickActions)))
                Assert.Contains($"\"{row.Title}\"", swift);
        }
    }

    // The Mac names its menu items as `validate` does when the sheet reads them (KeyShortcutsSheet.sections() walks the
    // validated menu): KeyCommands.swift at 93f984bb1, lines 861-874 and 803, and ChatMenuBar.swift line 145.

    /// File › New Chat: "New Chat with <bot>" for the bot ⌘N starts with, "New Chat…" with none (KeyCommands.swift
    /// `command.title = name.map { "New Chat with \($0)\(place)" } ?? "New Chat\(place)…"`). Windows' Ctrl+N takes no
    /// project, so there is no " in <project>".
    [Fact]
    public void NewChatIsNamedForTheBotCtrlNStartsWith()
    {
        string Title(ShortcutState state) =>
            KeyShortcuts.Sections(Numbered, terminal: false, state).Single(s => s.Title == "File").Rows[0].Title;
        Assert.Equal("New Chat with Hermes", Title(new ShortcutState(NewChatBot: "Hermes")));
        Assert.Equal("New Chat with Otto", Title(new ShortcutState(NewChatBot: "Otto")));
        Assert.Equal("New Chat…", Title(new ShortcutState(NewChatBot: null)));
        var row = KeyShortcuts.Sections(Numbered, terminal: false, new ShortcutState(NewChatBot: "Hermes")).Single(s => s.Title == "File").Rows[0];
        Assert.Equal("Ctrl+N", row.KeysText);
        Assert.Equal("New Chat with Hermes, Control N", row.AccessibleName);
    }

    /// The bot's name as the Mac's ⌘N item gives it: the roster's display name, "Hermes" for `default` without one, else
    /// the profile id (`bots.first { $0.id == id }?.name ?? (id == "default" ? "Hermes" : id)`).
    [Fact]
    public void TheNewChatBotIsNamedAsTheMacNamesIt()
    {
        Assert.Equal("Otto", ShortcutState.BotName("otto", "Otto"));
        Assert.Equal("Hermes", ShortcutState.BotName("default", null));
        Assert.Equal("Chief", ShortcutState.BotName("default", "Chief"));
        Assert.Equal("wren", ShortcutState.BotName("wren", null));
        Assert.Null(ShortcutState.BotName(null, null));
    }

    /// View › Hide Sidebar reads "Show Sidebar" while the sidebar is folded (KeyCommands.swift
    /// `MacSidebar.isCollapsed ? "Show Sidebar" : "Hide Sidebar"`); same key either way.
    [Fact]
    public void TheSidebarRowSaysShowWhileTheSidebarIsFolded()
    {
        ShortcutRow Row(bool folded) =>
            KeyShortcuts.Sections(Numbered, terminal: false, new ShortcutState("Hermes", SidebarFolded: folded)).Single(s => s.Title == "View").Rows[0];
        Assert.Equal("Show Sidebar", Row(true).Title);
        Assert.Equal("Hide Sidebar", Row(false).Title);
        Assert.Equal("Ctrl+Shift+S", Row(true).KeysText);
        Assert.Equal("Show Sidebar, Control Shift S", Row(true).AccessibleName);
    }

    /// View › Show Inspector reads "Hide Inspector" while the inspector is shown (ChatMenuBar.swift
    /// `visible ? "Hide Inspector" : "Show Inspector"`); same key either way.
    [Fact]
    public void TheInspectorRowSaysHideWhileTheInspectorIsShown()
    {
        ShortcutRow Row(bool shown) =>
            KeyShortcuts.Sections(Numbered, terminal: false, new ShortcutState("Hermes", InspectorShown: shown)).Single(s => s.Title == "View").Rows[1];
        Assert.Equal("Hide Inspector", Row(true).Title);
        Assert.Equal("Show Inspector", Row(false).Title);
        Assert.Equal("Ctrl+I", Row(true).KeysText);
    }

    /// The state-named titles are the Swift literals too (the full checkout only, as ListedTitlesAreTheSwiftStrings).
    [Fact]
    public void TheStateNamedTitlesAreTheSwiftStrings()
    {
        var root = RepoRoot();
        if (!Directory.Exists(Path.Combine(root, "App"))) return;
        var swift = string.Join("\n", new[] { "App/Root/KeyCommands.swift", "App/Root/ChatMenuBar.swift" }.Select(p => File.ReadAllText(Path.Combine(root, p))));
        foreach (var literal in new[] { "\"Show Sidebar\"", "\"Hide Sidebar\"", "\"Hide Inspector\"", "\"Show Inspector\"", "\"New Chat with \\($0)\\(place)\"", "\"New Chat\\(place)…\"" })
            Assert.Contains(literal, swift);
    }

    /// The shell hands the sheet what the Mac's `validate` reads: the bot its own Ctrl+N would start with (the same
    /// helper `NewChat_Click` uses), the sidebar's fold and the chat's inspector.
    [Fact]
    public void TheShellPassesTheStateTheTitlesNeed()
    {
        var shell = File.ReadAllText(Path.Combine(RepoRoot(), "windows", "src", "HermesHQ.Windows", "Pages", "ShellPage.xaml.cs"));
        var show = shell[shell.IndexOf("private void ShowShortcuts()", StringComparison.Ordinal)..];
        show = show[..show.IndexOf("\n    }", StringComparison.Ordinal)];
        Assert.Contains("NewChatBotId()", show);
        Assert.Contains("SidebarFolded: Rail", show);
        Assert.Contains("InspectorShown: ChatPage.Current?.InspectorShown == true", show);
        var newChat = shell[shell.IndexOf("private void NewChat_Click(", StringComparison.Ordinal)..];
        Assert.Contains("NewChatBotId()", newChat[..newChat.IndexOf("\n    }", StringComparison.Ordinal)]);
    }

    private static void Rows(IReadOnlyList<ShortcutSection> sheet, string section, params (string Title, string Keys)[] expected)
    {
        var rows = sheet.Single(s => s.Title == section).Rows;
        Assert.Equal(expected.Select(e => e.Title), rows.Select(r => r.Title));
        Assert.Equal(expected.Select(e => e.Keys), rows.Select(r => r.KeysText));
    }

    /// The checkout holding `windows/HermesHQ.sln`: the full Mac repo here, or the Windows-only CI mirror.
    private static string RepoRoot()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir != null; dir = dir.Parent)
            if (File.Exists(Path.Combine(dir.FullName, "windows", "HermesHQ.sln")))
                return dir.FullName;
        throw new InvalidOperationException("repo root not found");
    }
}
