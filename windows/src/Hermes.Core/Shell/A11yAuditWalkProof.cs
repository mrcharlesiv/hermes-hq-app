using System.Text;
using System.Text.RegularExpressions;

namespace Hermes.Core.Shell;

/// One control the "a11y-audit" walk (HermesHQ.Windows Services/ProofWalks.A11yAudit.cs) found with no name Narrator
/// can read: the page it was on, its control type and its x:Name or automation id (empty when it has neither).
public sealed record A11yFinding(string Page, string Type, string Id);

/// [WIN-55] The accessibility audit's rules. On the Mac every control VoiceOver lands on has a label
/// (`accessibilityLabel`, AppKit's `setAccessibilityLabel`, a toolbar item's `accessibilityTitle`); on Windows the same
/// words go in AutomationProperties.Name. The walk asks each control's automation peer for its Name, and these decide
/// whether that Name is one a person can hear. Null when so, else what is wrong. Kept apart from WalkProof.cs.
public static partial class A11yAuditWalkProof
{
    /// The pages the walk visits, in its order: a populated chat with the composer, then the main pages, the Settings
    /// window and a bot's Bot Info.
    public static readonly string[] Pages = ["Chats", "Sessions", "Tasks", "Jobs", "Kanban", "Files", "Settings", "Bot Info"];

    /// The control types the audit holds to the rule: everything the keyboard reaches or a click invokes. A subclass
    /// (DropDownButton, RadioMenuFlyoutItem, AppBarToggleButton…) is held to its base's rule by the walk.
    public static readonly string[] AuditedTypes =
        ["Button", "ToggleButton", "MenuFlyoutItem", "TextBox", "ListViewItem", "HyperlinkButton", "AppBarButton"];

    /// A Name Narrator can't read as words: empty, white space, an icon font's private-use code (Segoe Fluent / MDL2,
    /// U+E000–U+F8FF), symbols and punctuation alone ("⋯", "+", "×", "›"), or a glyph code written out ("&#xE712;",
    /// "\uE712", "U+E712", "0xE712").
    public static bool IsUnreadable(string? name)
    {
        if (string.IsNullOrWhiteSpace(name)) return true;
        var trimmed = name.Trim();
        if (GlyphCode().IsMatch(trimmed)) return true;
        foreach (var rune in trimmed.EnumerateRunes())
        {
            if (Rune.IsLetterOrDigit(rune)) return false;
        }
        return true;   // no letter or digit anywhere: a glyph, a symbol or punctuation
    }

    [GeneratedRegex(@"^(?:(?:&#x|\\u|U\+|0x)[0-9A-Fa-f]{4,5};?\s*)+$")]
    private static partial Regex GlyphCode();

    /// The type name the audit files a control under: itself when audited, else the nearest audited base in `bases`
    /// (the control's own type first, then its base types outward). Null when none is audited.
    public static string? AuditedAs(IEnumerable<string> typeAndBases) =>
        typeAndBases.FirstOrDefault(t => AuditedTypes.Contains(t, StringComparer.Ordinal));

    /// How many unnamed controls each page had, every visited page listed (0 where none).
    public static IReadOnlyDictionary<string, int> Counts(IEnumerable<A11yFinding> findings, IEnumerable<string> visited)
    {
        var counts = visited.Distinct().ToDictionary(p => p, _ => 0);
        foreach (var f in findings) counts[f.Page] = counts.GetValueOrDefault(f.Page) + 1;
        return counts;
    }

    /// The walk's verdict: null when every audited control on every page has a readable name, else each one listed
    /// (page, type, id), one to a line, after the per-page counts.
    public static string? Report(IReadOnlyList<A11yFinding> findings, IEnumerable<string> visited)
    {
        if (findings.Count == 0) return null;
        var counts = Counts(findings, visited);
        var head = $"{findings.Count} controls have no name Narrator can read ("
            + string.Join(", ", counts.Select(c => $"{c.Key} {c.Value}")) + ")";
        return head + ":\n" + string.Join("\n", findings.Select(f => $"  {f.Page} · {f.Type} · {(f.Id.Length == 0 ? "(no id)" : f.Id)}"));
    }

    /// The Mac's label for a Windows control, by its automation id (or x:Name), copied from the Swift each cites. Null
    /// when the Mac's label isn't recorded here; the control's own words are its name then.
    public static string? MacLabel(string id) => MacLabels.TryGetValue(id, out var label) ? label : null;

    /// Windows id → the Mac's VoiceOver label (git grep -n 'accessibilityLabel' 93f984bb1 -- App).
    public static readonly IReadOnlyDictionary<string, string> MacLabels = new Dictionary<string, string>(StringComparer.Ordinal)
    {
        // App/Chat/ComposerView.swift: `case .send, .disabled: accessibilityLabel = "Send"`; `.stop: "Stop"`.
        ["chat.send"] = "Send",
        ["chat.stop"] = "Stop",
        // App/Chat/Attachments/ComposerPlusMenu.swift: `button.accessibilityLabel = "Attach"`.
        ["composer.attach"] = "Attach",
        // App/Chat/ChatViewController.swift: the header's ⋯ `item.accessibilityLabel = … "Chat Actions"`, and
        // `item.accessibilityLabel = "Inspector"`.
        ["chat.more"] = "Chat Actions",
        ["chat.inspector"] = "Inspector",
        // App/Sessions/SessionsViewController.swift `filterLabel: "Filter and Sort"`; App/Kit/PageBarCapsule.swift
        // `item.accessibilityLabel = "Search"`; App/Chat/SessionStrip.swift `newChat.accessibilityLabel = "New Chat"`.
        ["sessions.filter"] = "Filter and Sort",
        ["sessions.compose"] = "New Chat",
        ["sessions.search"] = "Search",
        // App/Mac/MacSidebar.swift: `toggle.accessibilityLabel = folded ? "Show Sidebar" : "Hide Sidebar"`,
        // `settingsButton.accessibilityLabel = "Settings"`, `addButton.accessibilityLabel = "Add to Sidebar"`;
        // App/Bots/BotsViewController.swift `account.accessibilityLabel = "Account"`.
        ["shell.fold"] = "Hide Sidebar",
        ["shell.settings"] = "Settings",
        ["shell.add"] = "Add to Sidebar",
        ["shell.account"] = "Account",
        // App/Chat/Activity/ActivityShelfView.swift: `more.accessibilityLabel = "Goal Actions"`.
        ["shelf.goal.more"] = "Goal Actions",
        // App/Pages/Jobs/JobsViewController.swift "New Job"; App/Pages/Kanban/KanbanViewController.swift "New Task".
        ["jobs.new"] = "New Job",
        ["kanban.new"] = "New Task",
    };
}
