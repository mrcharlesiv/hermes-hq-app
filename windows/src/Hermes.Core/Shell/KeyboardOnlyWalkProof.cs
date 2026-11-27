namespace Hermes.Core.Shell;

/// One stop in the Mac's key loop the "keyboard-only" walk (HermesHQ.Windows Services/ProofWalks.KeyboardOnly.cs) must
/// reach, in order: the Windows key it is found by (automation id, else x:Name; a trailing "*" matches a prefix), what a
/// person sees there, and the Swift the Mac's place for it comes from.
public sealed record KeyStop(string Key, string What, string Swift);

/// [WIN-58] Keyboard-only use of the main window, judged against the Mac's key loop. The Mac app is Catalyst: its Tab
/// moves the system focus (UIFocusSystem) through the window in reading order, the sidebar first, then the pane beside
/// it top to bottom and leading to trailing; a list takes the focus once and its arrows walk it. On Windows the same
/// stops are reached with FocusManager.TryMoveFocus Next/Previous. Kept apart from WalkProof.cs.
public static class KeyboardOnlyWalkProof
{
    /// The sidebar's chat row (a bot's row: the walk keys a ListViewItem whose item is a bot by this).
    public const string SidebarChat = "sidebar.chat";
    /// Any stop in the sidebar (its tools, rows and foot): Shift+Tab out of the chat must come back to one.
    public const string SidebarAny = "sidebar*";
    public const string ChatActions = "MoreButton";
    public const string Inspector = "InspectorToggle";
    public const string Composer = "chat.composer";
    public const string TasksSearch = "tasks.search";
    /// A task row's keyboard stop (Features/Tasks/TasksPage.cs KeyRow), "tasks.key." + the task's id.
    public const string TaskRowPrefix = "tasks.key.";

    /// Tab from the sidebar's chat row, the chat open: the header's buttons, then the message box.
    public static readonly KeyStop[] ChatForward =
    [
        // App/Mac/MacSidebar.swift: the sidebar is the window's first pane (MacSelection.Pane .sidebar, the focus it
        // starts with: `private(set) static var focus: Pane = .sidebar`), its chats one list the arrows walk
        // (App/Root/KeyCommands.swift alternates: `UIKeyCommand(action: nextChat, input: UIKeyCommand.inputDownArrow`).
        new(SidebarChat, "a chat's row in the sidebar", "App/Mac/MacSelection.swift `static var focus: Pane = .sidebar`"),
        // App/Chat/ChatViewController.swift updateMoreButton: `navigationItem.rightBarButtonItems = [makeInspectorButton()]
        // + items + …` — the first item is the trailing one, so left to right the ⋯ ("Chat Actions") comes before
        // "Inspector".
        new(ChatActions, "Chat Actions", "App/Chat/ChatViewController.swift `item.accessibilityLabel = … \"Chat Actions\"`"),
        new(Inspector, "Inspector", "App/Chat/ChatViewController.swift `item.accessibilityLabel = \"Inspector\"`"),
        // The transcript's bubbles take no keyboard focus (ChatViewController.swift: \"bubbles take no keyboard focus
        // here\"), so the next stop under the header is the message box.
        new(Composer, "the message box", "App/Chat/ChatViewController.swift `/// … bubbles take no keyboard focus here`"),
    ];

    /// Shift+Tab from the message box: the same stops backwards, and out of the chat to the sidebar (not trapped).
    public static readonly KeyStop[] ChatBackward =
    [
        new(Inspector, "Inspector", "App/Chat/ChatViewController.swift `[makeInspectorButton()] + items`"),
        new(ChatActions, "Chat Actions", "App/Chat/ChatViewController.swift `item.accessibilityIdentifier = \"chat.more\"`"),
        new(SidebarAny, "back in the sidebar", "App/Mac/MacSelection.swift `enum Pane { case sidebar, list, detail }`"),
    ];

    /// Tab on Tasks from its page bar: the search field at the bar's trailing edge, then the list's rows.
    public static readonly KeyStop[] TasksForward =
    [
        new(TasksSearch, "Search Tasks", "App/Pages/Tasks/TasksViewController.swift `PageBarCapsule.search(on: self, page: \"tasks\", placeholder: \"Search Tasks\"`"),
        new(TaskRowPrefix + "*", "a task's row", "App/Pages/Tasks/TasksViewController.swift `walkOrder`: \"the system's focus used to start on it\""),
    ];

    /// The Mac's Settings key: App/Root/KeyCommands.swift `command(\"Settings…\", settings, \",\", .command)` (Ctrl+,).
    public const string SettingsKey = "Ctrl+,";

    /// Does `key` stand for `stop`'s key (a trailing "*" is a prefix)?
    public static bool Matches(string stopKey, string key) =>
        stopKey.EndsWith('*') ? key.StartsWith(stopKey[..^1], StringComparison.Ordinal) : key == stopKey;

    /// Null when the focus `visited` (in the order the moves reached them) passes every stop of `expected` in its order,
    /// else what is missing or out of order.
    public static string? Order(IReadOnlyList<string> visited, IReadOnlyList<KeyStop> expected)
    {
        var at = 0;
        foreach (var stop in expected)
        {
            var found = -1;
            for (var i = at; i < visited.Count; i++)
                if (Matches(stop.Key, visited[i])) { found = i; break; }
            if (found < 0)
            {
                var earlier = visited.Take(at).Any(v => Matches(stop.Key, v));
                return $"{stop.What} ({stop.Key}) {(earlier ? "came before the stop it follows on the Mac" : "was never reached")}; "
                    + $"the focus went: {string.Join(" → ", visited)}";
            }
            at = found + 1;
        }
        return null;
    }

    /// Null when a focused element is drawn inside the window: it has a size and its box lies inside the window's
    /// (a pixel's slack for rounding), else what is wrong.
    public static string? OnScreen(string key, double width, double height, double left, double top, double windowWidth, double windowHeight)
    {
        if (width <= 0 || height <= 0) return $"{key} has the focus but no size ({width}×{height})";
        if (left < -1 || top < -1 || left + width > windowWidth + 1 || top + height > windowHeight + 1)
            return $"{key} has the focus off screen (at {left:0},{top:0} size {width:0}×{height:0} in a {windowWidth:0}×{windowHeight:0} window)";
        return null;
    }

    /// Does the focused control draw a focus visual: the system's ring (UseSystemFocusVisuals), or a text box's own
    /// focused border, which only shows with a border to draw?
    public static bool DrawsFocus(bool useSystemFocusVisuals, bool isTextBox, double borderThickness) =>
        useSystemFocusVisuals || (isTextBox && borderThickness > 0);
}
