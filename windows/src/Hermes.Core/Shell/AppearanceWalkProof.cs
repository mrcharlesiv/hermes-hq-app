using Hermes.Core.Settings;

namespace Hermes.Core.Shell;

/// [WIN-APPEARANCE-WALK] What the appearance-pages walk (HermesHQ.Windows Services/ProofWalks.Appearance.cs; windows.yml
/// asks for it on the settings stand-in) checks as it drives Settings › Appearance's newer pages with the app's own
/// controls: Chat Bubbles (Corners and its preview, Tinted, the notes; the Desktop Look's own Corners), Density's Compact
/// on the sidebar's and Sessions' rows, the Sidebar page (a switch turned on, Move Up, Use Default Tabs appearing and
/// used) and Capabilities › Skills' one-line rows, then that every setting it touched is as it was. Each check answers
/// null when the app shows what it should, otherwise the words of what is wrong. Kept apart from WalkProof.cs so lanes
/// don't collide.
public static class AppearanceWalkProof
{
    public const string Walk = "appearance-pages";

    /// The walk's pictures besides its own (`appearance-pages`: Settings › Appearance as it opens).
    public static readonly IReadOnlyList<string> Shots =
    [
        "appearance-chat-bubbles", "appearance-chat-bubbles-desktop", "appearance-density-compact-sidebar",
        "appearance-density-compact-sessions", "appearance-sidebar-page", "appearance-sidebar-moved", "capabilities-skills-oneline",
    ];

    /// The corner the walk drags the iOS look's Corners to: neither look's standard (12, 4), inside 0…24.
    public const int WalkCorners = 20;

    /// The preferences the walk may change (every `hqn.theme.*` key the Desktop Look, Corners, Tinted and Density write,
    /// and the Settings category it was left on), read before and put back after.
    public static IReadOnlyList<string> PreferenceKeys { get; } = [.. ThemeStore.Key.All, SettingsCategories.LastCategoryKey];

    /// The sidebar's own file in the device store (SidebarLayout.Load/Save), which the Sidebar page writes.
    public const string SidebarStoreKey = "sidebar";

    /// The settings stand-in's skills for every bot (windows/ci/fixtures/settings-gateway.py `default_skills`): the
    /// Installed rows Capabilities › Skills draws. SkillsWalkStandInTests checks the stand-in still says so.
    public static readonly IReadOnlyList<string> StandInSkills = ["web-search", "arxiv", "github-pr", "pdf-reader", "notes-helper", "calendar"];

    /// A skill row's UI Automation id on Capabilities › Skills (ListScreen).
    public static string SkillRowId(string name) => "skill-row-" + name;

    // ------------------------------------------------------------------ settings put back

    /// The values of `keys` as `read` gives them now.
    public static IReadOnlyDictionary<string, string?> Snapshot(Func<string, string?> read, IEnumerable<string> keys) =>
        keys.Distinct().ToDictionary(k => k, read);

    /// Every key read `before` reads the same `now`. Null when so, else each one that differs.
    public static string? Restored(IReadOnlyDictionary<string, string?> before, Func<string, string?> now)
    {
        var wrong = before.Where(kv => now(kv.Key) != kv.Value)
            .Select(kv => $"{kv.Key} is {Shown(now(kv.Key))}, not {Shown(kv.Value)}").ToList();
        return wrong.Count == 0 ? null : "not put back: " + string.Join("; ", wrong);
    }

    private static string Shown(string? value) => value == null ? "unset" : $"\u201C{value}\u201D";

    // ------------------------------------------------------------------ Chat Bubbles

    /// Corners as the page draws it for `expected` points: the value beside it (`ChatBubbles.CornersValue`), the preview
    /// message's corner, the slider's position and what it says (`ChatBubbles.CornersSpoken`). Null when all agree.
    public static string? CornersShown(int expected, string? pointsText, double previewRadius, double sliderValue, string? spoken)
    {
        if (pointsText != ChatBubbles.CornersValue(expected)) return $"Corners reads {pointsText ?? "nothing"}, not {ChatBubbles.CornersValue(expected)}";
        if (Math.Abs(previewRadius - expected) > 0.01) return $"the preview's message has {previewRadius:0.#} pt corners, not {expected}";
        if (Math.Abs(sliderValue - expected) > 0.01) return $"the slider sits at {sliderValue:0.#}, not {expected}";
        return spoken == ChatBubbles.CornersSpoken(expected) ? null : $"the slider says {spoken ?? "nothing"}, not {ChatBubbles.CornersSpoken(expected)}";
    }

    /// The Chat Bubbles page for `state` (no Chat Background on this PC): Tinted only in the iOS look, on when the shown
    /// style is Tinted, and the page's footer (`ChatBubbles.Footer`, paragraphs joined by a blank line) among `texts`.
    public static string? BubblesPage(ThemeState state, bool tintedShown, bool tintedOn, IReadOnlyCollection<string> texts)
    {
        var showsStyle = ChatBubbles.ShowsStyle(state);
        if (tintedShown != showsStyle)
            return showsStyle ? "the iOS look's Chat Bubbles has no Tinted switch" : "the Desktop Look's Chat Bubbles shows Tinted";
        if (showsStyle && tintedOn != (ChatBubbles.Shown(state.BubbleStyle) == BubbleStyle.Tinted))
            return $"Tinted shows {(tintedOn ? "on" : "off")} with the style {ChatBubbles.Shown(state.BubbleStyle).Title()}";
        var footer = string.Join("\n\n", ChatBubbles.Footer(state, hasChatBackground: false));
        return texts.Contains(footer) ? null : $"the page's notes don't read \u201C{footer}\u201D";
    }

    /// What the iOS look's page saved: Corners at `corners`, the style `style`, the Desktop Look off. Null when so.
    public static string? BubblesSaved(ThemeState state, int corners, BubbleStyle style)
    {
        if (state.DesktopLook) return "the Desktop Look is on";
        if (state.BubbleCorners != corners) return $"the iOS look's Corners is {state.BubbleCorners}, not {corners}";
        if (state.AppliedBubbleCorners != corners) return $"messages draw at {state.AppliedBubbleCorners} pt, not {corners}";
        return state.BubbleStyle == style ? null : $"the bubble style is {state.BubbleStyle.Title()}, not {style.Title()}";
    }

    /// The Chat Bubbles row on Appearance (`ChatBubbles.RowId`): read aloud as its title and value.
    public static string? BubblesRowReads(ThemeState state, string? name)
    {
        var expected = $"{ChatBubbles.Label}, {ChatBubbles.Value(state)}";
        return name == expected ? null : $"the Chat Bubbles row reads \u201C{name ?? "nothing"}\u201D, not \u201C{expected}\u201D";
    }

    // ------------------------------------------------------------------ Density

    public enum SidebarRow { Bot, Room, Chat, Place, Other }

    /// The open sidebar's rows at `z` (`DensitySizes.Sidebar`): bots and rooms `BotRow` tall, chats under a bot
    /// `ChatRow`, places `PlaceRow`; at least one bot and one place. Null when so.
    public static string? SidebarRowsAt(IReadOnlyList<(SidebarRow Kind, double MinHeight)> rows, DensitySizes.SidebarSizes z)
    {
        if (!rows.Any(r => r.Kind == SidebarRow.Bot)) return "the sidebar shows no bot";
        if (!rows.Any(r => r.Kind == SidebarRow.Place)) return "the sidebar shows no place";
        foreach (var (kind, height) in rows)
        {
            double? expected = kind switch
            {
                SidebarRow.Bot or SidebarRow.Room => z.BotRow,
                SidebarRow.Chat => z.ChatRow,
                SidebarRow.Place => z.PlaceRow,
                _ => null,
            };
            if (expected is { } e && Math.Abs(height - e) > 0.01) return $"a {kind.ToString().ToLowerInvariant()} row is {height:0.#} tall, not {e:0.#}";
        }
        return null;
    }

    /// Sessions' chat rows at `z` (`DensitySizes.Sessions`): each `Row` tall with `Pad` over and under; at least one.
    public static string? SessionRowsAt(IReadOnlyList<(double MinHeight, double Pad)> rows, DensitySizes.SessionSizes z)
    {
        if (rows.Count == 0) return "Sessions shows no chat";
        foreach (var (height, pad) in rows)
        {
            if (Math.Abs(height - z.Row) > 0.01) return $"a chat row is {height:0.#} tall, not {z.Row:0.#}";
            if (Math.Abs(pad - z.Pad) > 0.01) return $"a chat row has {pad:0.#} over its words, not {z.Pad:0.#}";
        }
        return null;
    }

    // ------------------------------------------------------------------ the Sidebar page

    /// A place turned on under Add to Sidebar joins the places at the end (`SidebarLayout.Add`). Null when so.
    public static string? Added(IReadOnlyList<string> before, IReadOnlyList<string> after, string id) =>
        before.Contains(id) ? $"{id} was in the sidebar already" : WalkProof.Order(after, [.. before, id], $"the sidebar after turning {id} on");

    /// Move Up on `id`: it swaps with the place above it, the rest as they were (`SidebarLayout.Move`). Null when so.
    public static string? MovedUp(IReadOnlyList<string> before, IReadOnlyList<string> after, string id)
    {
        var at = before.ToList().IndexOf(id);
        if (at <= 0) return $"{id} can't move up from {(at < 0 ? "outside the sidebar" : "the top")}";
        var expected = before.ToList();
        expected.RemoveAt(at);
        expected.Insert(at - 1, id);
        return WalkProof.Order(after, expected, $"the sidebar after Move Up on {id}");
    }

    /// Use Default Tabs shows exactly while the places aren't the default (`SidebarLayout.IsDefault`).
    public static string? UseDefaultShown(bool isDefault, bool shown) => shown == !isDefault ? null
        : shown ? $"{SidebarPage.UseDefault} shows with the default places" : $"no {SidebarPage.UseDefault} with the places changed";

    // ------------------------------------------------------------------ Capabilities › Skills

    /// Installed skill rows on Capabilities › Skills: one for each of `expected`, each subtitle `lines` lines at most
    /// (`CapabilitiesWords.SkillLineLines`; 0 = no limit) and cut at its tail. Null when so.
    public static string? SkillRowsOneLine(IReadOnlyList<(string Name, int MaxLines, bool TailCut)> rows, IReadOnlyList<string> expected, int lines)
    {
        var missing = expected.Where(n => rows.All(r => r.Name != n)).ToList();
        if (missing.Count > 0) return $"Skills has no row for {string.Join(", ", missing)}";
        foreach (var (name, max, cut) in rows)
        {
            if (max != lines) return $"{name}'s line takes {(max == 0 ? "any number of" : max.ToString())} lines, not {(lines == 0 ? "any number" : lines.ToString())}";
            if (!cut) return $"{name}'s line isn't cut at its tail";
        }
        return null;
    }
}
