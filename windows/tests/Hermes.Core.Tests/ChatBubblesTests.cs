using System.Text.RegularExpressions;
using Hermes.Core.Settings;

namespace Hermes.Core.Tests;

/// [theme-pages] Settings › Appearance › Chats › Chat Bubbles (Mac 93f984bb1 App/Settings/Appearance/AppearancePage.swift
/// `chats`, `chatBubblesRow`; App/Settings/Theme/ThemeSettingsView.swift `ChatBubblesSettingsView`, `BubbleCornersRow`,
/// `BubbleStyles`; HermesKit/Theme/ThemeState.swift `BubbleStyle`, ThemeStore keys; HermesKit/Settings/SettingsSearch.swift
/// `app:chat-bubbles`). Synthetic preferences only.
public class ChatBubblesTests
{
    // ---------------------------------------------------------------- saved choices

    [Fact]
    public void TheMacsKeysRawValuesAndDefaults()
    {
        Assert.Equal("hqn.theme.bubbleStyle", ThemeStore.Key.BubbleStyle);
        Assert.Equal("hqn.theme.glassBubbles", ThemeStore.Key.GlassBubbles);
        Assert.Equal("hqn.theme.desktopComposer", ThemeStore.Key.DesktopComposer);
        Assert.Equal("hqn.theme.messageColour", ThemeStore.Key.MessageColour);
        Assert.Equal("hqn.theme.plainReplies", ThemeStore.Key.PlainReplies);
        // The Mac's `Key.all`, so Reset clears every one of them.
        foreach (var key in new[] { "hqn.theme.bubbleCorners", "hqn.theme.glassBubbles", "hqn.theme.bubbleStyle", "hqn.theme.desktopCorners",
                     "hqn.theme.desktopComposer", "hqn.theme.messageColour", "hqn.theme.plainReplies" })
            Assert.Contains(key, ThemeStore.Key.All);
        Assert.Equal(["solid", "glass", "tinted", "card"], Enum.GetValues<BubbleStyle>().Select(s => s.Raw()));
        Assert.Equal(["Solid", "Glass", "Tinted", "Card"], Enum.GetValues<BubbleStyle>().Select(s => s.Title()));
        Assert.Equal(BubbleStyle.Solid, ThemeState.Default.BubbleStyle);
        var empty = new ThemeStore(new MemoryPrefs()).Load();
        Assert.Equal(BubbleStyle.Solid, empty.BubbleStyle);
        Assert.Equal(12, empty.BubbleCorners);
        Assert.Equal(4, empty.DesktopCorners);
    }

    [Fact]
    public void SolidIsStoredAsNothingAndTheGlassSwitchStaysOffExceptForGlass()
    {
        var prefs = new MemoryPrefs();
        var store = new ThemeStore(prefs);
        store.SetBubbleStyle(BubbleStyle.Tinted);
        Assert.Equal("tinted", prefs.Values["hqn.theme.bubbleStyle"]);
        Assert.Equal("false", prefs.Values["hqn.theme.glassBubbles"]);
        Assert.Equal(BubbleStyle.Tinted, store.Load().BubbleStyle);
        store.SetBubbleStyle(BubbleStyle.Glass);
        Assert.Equal("glass", prefs.Values["hqn.theme.bubbleStyle"]);
        Assert.False(prefs.Values.ContainsKey("hqn.theme.glassBubbles"));
        store.SetBubbleStyle(BubbleStyle.Solid);
        Assert.False(prefs.Values.ContainsKey("hqn.theme.bubbleStyle"));
        Assert.Equal("false", prefs.Values["hqn.theme.glassBubbles"]);
        Assert.Equal(BubbleStyle.Solid, store.Load().BubbleStyle);
        store.Reset();
        Assert.Empty(prefs.Values);
    }

    [Fact]
    public void AStyleThisStoreDoesNotWriteReadsAsSolidAndIsKept()
    {
        var prefs = new MemoryPrefs();
        prefs.Set("hqn.theme.bubbleStyle", "Tinted");   // raw values are lower case
        Assert.Equal(BubbleStyle.Solid, new ThemeStore(prefs).Load().BubbleStyle);
        Assert.Equal("Tinted", prefs.Get("hqn.theme.bubbleStyle"));
        prefs.Set("hqn.theme.bubbleStyle", "card");
        Assert.Equal(BubbleStyle.Card, new ThemeStore(prefs).Load().BubbleStyle);
    }

    [Fact]
    public void CornersAreStoredOnlyWhenNotTheLooksOwnStandard()
    {
        var prefs = new MemoryPrefs();
        var store = new ThemeStore(prefs);
        // The page's slider writes the corner of the look in use (Theme.setBubbleCorners → desktop: state.desktopLook).
        ChatBubbles.SetCorners(store, ThemeState.Default, 20);
        Assert.Equal("20", prefs.Values["hqn.theme.bubbleCorners"]);
        ChatBubbles.SetCorners(store, ThemeState.Default with { DesktopLook = true }, 9);
        Assert.Equal("9", prefs.Values["hqn.theme.desktopCorners"]);
        ChatBubbles.SetCorners(store, ThemeState.Default, 12);
        ChatBubbles.SetCorners(store, ThemeState.Default with { DesktopLook = true }, 4);
        Assert.Empty(prefs.Values);
        // Outside 0…24 is clamped on the way in.
        ChatBubbles.SetCorners(store, ThemeState.Default, 40);
        Assert.Equal("24", prefs.Values["hqn.theme.bubbleCorners"]);
        Assert.Equal(0, ChatBubbles.Range.Min);
        Assert.Equal(24, ChatBubbles.Range.Max);
    }

    // ---------------------------------------------------------------- styles offered here, and what draws

    [Fact]
    public void NoLiquidGlassHereSoSolidAndTintedAsTheMacsNoGlassBranch()
    {
        Assert.False(ChatBubbles.GlassOffered);
        Assert.Equal([BubbleStyle.Solid, BubbleStyle.Tinted], ChatBubbles.Offered);
        Assert.Equal(BubbleStyle.Solid, ChatBubbles.Shown(BubbleStyle.Solid));
        Assert.Equal(BubbleStyle.Tinted, ChatBubbles.Shown(BubbleStyle.Tinted));
        // Glass (and Card, which needs it) read as Solid where they aren't offered.
        Assert.Equal(BubbleStyle.Solid, ChatBubbles.Shown(BubbleStyle.Glass));
        Assert.Equal(BubbleStyle.Solid, ChatBubbles.Shown(BubbleStyle.Card));
    }

    [Fact]
    public void TheRowSaysTheLooksCornersOrTheShownStyle()
    {
        Assert.Equal("Chat Bubbles", ChatBubbles.Label);
        Assert.Equal("settings.chat-bubbles-row", ChatBubbles.RowId);
        Assert.Equal("chat-bubbles", ChatBubbles.Target);
        Assert.Equal("settings.chat-bubbles", ChatBubbles.PageId);
        Assert.Equal("Chats", ChatBubbles.SectionTitle);
        Assert.Equal("Solid", ChatBubbles.Value(ThemeState.Default));
        Assert.Equal("Tinted", ChatBubbles.Value(ThemeState.Default with { BubbleStyle = BubbleStyle.Tinted }));
        Assert.Equal("Solid", ChatBubbles.Value(ThemeState.Default with { BubbleStyle = BubbleStyle.Glass }));
        Assert.Equal("4 pt", ChatBubbles.Value(ThemeState.Default with { DesktopLook = true, BubbleStyle = BubbleStyle.Tinted }));
        Assert.Equal("9 pt", ChatBubbles.Value(ThemeState.Default with { DesktopLook = true, DesktopCorners = 9 }));
    }

    [Fact]
    public void ThePageShowsTheLooksOwnRowsAndTheMacsWords()
    {
        var ios = ThemeState.Default;
        var desktop = ThemeState.Default with { DesktopLook = true };
        Assert.Equal(12, ChatBubbles.Corners(ios));
        Assert.Equal(4, ChatBubbles.Corners(desktop));
        Assert.True(ChatBubbles.ShowsStyle(ios));
        Assert.False(ChatBubbles.ShowsStyle(desktop));
        // [mac] This desktop keeps its own message box, as the Mac: no Text Box choice in the Desktop Look.
        Assert.True(ChatBubbles.TextBoxIsFixed);
        Assert.Equal("Corners", ChatBubbles.CornersLabel);
        Assert.Equal("Bubble Corners", ChatBubbles.CornersName);
        Assert.Equal("theme.bubbleCorners", ChatBubbles.CornersId);
        Assert.Equal("17 pt", ChatBubbles.CornersValue(17));
        Assert.Equal("17 points", ChatBubbles.CornersSpoken(17));
        Assert.Equal("Tinted", ChatBubbles.TintedLabel);
        Assert.Equal("theme.tintedBubbles", ChatBubbles.TintedId);
        Assert.Equal("How round the corners of messages in chats are, and whether they’re Tinted with the colors of your Chat Background. 12 pt is the standard. With Reduce Transparency on, messages stay solid. The Hermes Look has its own Corners, here once it is on. Set on this PC only.",
            ChatBubbles.Note);
        Assert.Equal("Tinted takes its colors from your Chat Background. Choose one in Appearance › Backgrounds; until then, messages are solid.",
            ChatBubbles.TintedNeedsBackground);
        Assert.Equal("How round your messages and the text box are. Follows Hermes Look’s Corners (4 pt) unless changed here. Native Look has its own Corners, Style and Color, here once Hermes Look is off.",
            ChatBubbles.DesktopNote);
        // The footer: the note, then Tinted's when it is picked with no Chat Background (there is none on this PC yet).
        Assert.Equal([ChatBubbles.Note], ChatBubbles.Footer(ios, hasChatBackground: false));
        var tinted = ios with { BubbleStyle = BubbleStyle.Tinted };
        Assert.Equal([ChatBubbles.Note, ChatBubbles.TintedNeedsBackground], ChatBubbles.Footer(tinted, hasChatBackground: false));
        Assert.Equal([ChatBubbles.Note], ChatBubbles.Footer(tinted, hasChatBackground: true));
        Assert.Equal([ChatBubbles.DesktopNote], ChatBubbles.Footer(desktop with { BubbleStyle = BubbleStyle.Tinted }, hasChatBackground: false));
    }

    [Fact]
    public void TheChatDrawsTheLooksCornerAndSolidWithoutAChatBackground()
    {
        var ios = ThemeState.Default with { BubbleCorners = 20, DesktopCorners = 2 };
        Assert.Equal(20 * 0.77, ChatBubbles.MessageCorner(ios));
        Assert.Equal(2 * 0.77, ChatBubbles.MessageCorner(ios with { DesktopLook = true }));
        // `appliedBubbleStyle`: the Desktop Look keeps its own boxes.
        Assert.Equal(BubbleStyle.Tinted, (ios with { BubbleStyle = BubbleStyle.Tinted }).AppliedBubbleStyle);
        Assert.Equal(BubbleStyle.Solid, (ios with { BubbleStyle = BubbleStyle.Tinted, DesktopLook = true }).AppliedBubbleStyle);
        // Tinted with no Chat Background has no colours to take: solid.
        Assert.Equal(BubbleStyle.Solid, ChatBubbles.Drawn(ios with { BubbleStyle = BubbleStyle.Tinted }, hasChatBackground: false));
        Assert.Equal(BubbleStyle.Tinted, ChatBubbles.Drawn(ios with { BubbleStyle = BubbleStyle.Tinted }, hasChatBackground: true));
        Assert.Equal(BubbleStyle.Solid, ChatBubbles.Drawn(ios with { BubbleStyle = BubbleStyle.Glass }, hasChatBackground: true));
    }

    [Fact]
    public void OpenChatsRedrawOnlyWhenWhatTheyDrawChanges()
    {
        var heard = 0;
        void Count() => heard++;
        ChatBubbles.Changed += Count;
        try
        {
            var s = ThemeState.Default;
            Assert.False(ChatBubbles.Notify(s, s with { UiScalePercent = 110 }));
            Assert.True(ChatBubbles.Notify(s, s with { BubbleCorners = 16 }));
            // The Desktop Look's corner moved while the iOS look draws: nothing to redraw.
            Assert.False(ChatBubbles.Notify(s, s with { DesktopCorners = 8 }));
            Assert.True(ChatBubbles.Notify(s, s with { DesktopLook = true }));
            Assert.True(ChatBubbles.Notify(s, s with { BubbleStyle = BubbleStyle.Tinted }));
            Assert.Equal(3, heard);
        }
        finally { ChatBubbles.Changed -= Count; }
    }

    // ---------------------------------------------------------------- Settings search

    [Fact]
    public void SearchFindsChatBubblesAsTheMacsIndexDoes()
    {
        var entry = Assert.Single(SettingsSearch.Index, e => e.Id == "app:chat-bubbles");
        Assert.Equal("Chat Bubbles", entry.Label);
        Assert.Equal("Appearance", entry.Context);
        Assert.Equal(["bubble corners", "rounded corners", "message corners", "glass bubbles", "tinted bubbles"], entry.Keywords);
        Assert.Equal("chat-bubbles", entry.Target);
        Assert.Equal(SettingsCategory.Appearance, SettingsSearch.Category("chat-bubbles"));
        // After UI Scale, as the Mac's index ([theme-pages] rows of their own beside Theme).
        var ids = SettingsSearch.Index.Select(e => e.Id).ToList();
        Assert.Equal(ids.IndexOf("app:ui-scale") + 1, ids.IndexOf("app:chat-bubbles"));
        Assert.Equal("app:chat-bubbles", SettingsSearch.Results("message corners", SettingsSearch.Index)[0].Id);
        Assert.Contains(SettingsSearch.Results("tinted", SettingsSearch.Index), e => e.Id == "app:chat-bubbles");
    }

    // ---------------------------------------------------------------- source (WinUI can't run here)

    private static string Source(params string[] parts)
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir) ?? throw new InvalidOperationException("no windows dir");
        return File.ReadAllText(Path.Combine([dir, "src", "HermesHQ.Windows", .. parts])).Replace("\r\n", "\n");
    }

    private static string Body(string source, string signature) =>
        Regex.Match(source, Regex.Escape(signature) + @"(?<b>.*?)\n    \}", RegexOptions.Singleline).Groups["b"].Value;

    [Fact]
    public void AppearanceHasAChatsGroupWithTheChatBubblesRowBetweenTextSizeAndBotsAndSessions()
    {
        var panes = Source("Features", "Settings", "SettingsPanes.cs");
        var appearance = Body(panes, "private static FrameworkElement Appearance(SettingsPage page)");
        var size = appearance.IndexOf("Kit.Section(\"Text Size\"", StringComparison.Ordinal);
        var chats = appearance.IndexOf("Kit.Section(ChatBubbles.SectionTitle, null,", StringComparison.Ordinal);
        var lists = appearance.IndexOf("Kit.Section(WorkingRing.SectionTitle", StringComparison.Ordinal);
        Assert.True(size >= 0 && chats > size && lists > chats, "Look, Text Size, Chats, Bots & Sessions");
        Assert.Contains("Kit.Nav(GBubbles, ChatBubbles.Label, ChatBubbles.Value(state), () => Go(page, ChatBubbles.Target), ChatBubbles.RowId)", appearance);
        Assert.Contains("ChatBubbles.Target => (ChatBubbles.Label, () => ChatBubblesPage())", panes);
        var page = Body(panes, "private static FrameworkElement ChatBubblesPage()");
        Assert.Contains("ChatBubbles.ShowsStyle(state)", page);
        Assert.Contains("ChatBubbles.Footer(state, hasChatBackground", page);
        Assert.Contains("ChatBubbles.TintedLabel", page);
        Assert.Contains("ThemeService.SetBubbleStyle(", page);
        Assert.Contains("ChatBubbles.PageId", page);
        var corners = Body(panes, "private static FrameworkElement BubbleCornersRow(ThemeState state)");
        Assert.Contains("ChatBubbles.Range.Min", corners);
        Assert.Contains("ChatBubbles.CornersId", corners);
        Assert.Contains("ThemeService.SetBubbleCorners(", corners);
        var service = Source("Features", "Settings", "ThemeService.cs");
        Assert.Contains("public static void SetBubbleCorners(int points)", service);
        Assert.Contains("public static void SetBubbleStyle(BubbleStyle style)", service);
        Assert.Contains("ChatBubbles.Notify(was, State)", service);
    }

    [Fact]
    public void YourMessagesTakeTheLooksCornerAndOpenChatsRedraw()
    {
        var view = Source("Controls", "MessageView.cs");
        var bubble = Body(view, "private static FrameworkElement UserBubble(MessageItem item, List<FrameworkElement> findable)");
        Assert.Contains("CornerRadius = new CornerRadius(ChatBubbles.MessageCorner(ThemeService.State))", bubble);
        Assert.DoesNotContain("CornerRadius = new CornerRadius(8)", bubble);
        Assert.Contains("ChatBubbles.Changed += OnBubbles", view);
        Assert.Contains("ChatBubbles.Changed -= OnBubbles", view);
    }
}
