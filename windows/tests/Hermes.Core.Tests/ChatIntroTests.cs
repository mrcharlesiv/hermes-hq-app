using Hermes.Core.Chat;
using Hermes.Core.Settings;
using Xunit;

namespace Hermes.Core.Tests;

/// [WIN-CHAT-INTRO] The empty chat's intro (App/Chat/ChatPlaceholderView.swift, ChatViewController.updatePlaceholder /
/// emptyIntro, AppPreferences.swift IntroSplash, ChatMenus.isUnnamed / canName at 93f984bb1).
public class ChatIntroTests
{
    // ------------------------------------------------------------------ which placeholder (updatePlaceholder)

    [Fact]
    public void AnOpenEmptyChatShowsTheIntroWhileTheSwitchIsOn()
    {
        Assert.Equal(ChatIntroMode.Empty, ChatIntro.ModeFor(rows: 0, hiddenRows: false, room: false, ChatOpenPhase.Open, splashOn: true));
        Assert.Equal(ChatIntroMode.Blank, ChatIntro.ModeFor(rows: 0, hiddenRows: false, room: false, ChatOpenPhase.Open, splashOn: false));
    }

    [Fact]
    public void RowsLoadingFailureHiddenRowsAndRoomsNeverGetTheIntro()
    {
        foreach (var on in new[] { true, false })
        {
            // A chat with rows: nothing, whatever its phase.
            foreach (var phase in Enum.GetValues<ChatOpenPhase>())
                Assert.Equal(ChatIntroMode.None, ChatIntro.ModeFor(1, false, false, phase, on));
            // Still opening: the page's loading state, not \"No messages yet\".
            Assert.Equal(ChatIntroMode.Loading, ChatIntro.ModeFor(0, false, false, ChatOpenPhase.Opening, on));
            // Couldn't load: the failure, not the intro.
            Assert.Equal(ChatIntroMode.Failed, ChatIntro.ModeFor(0, false, false, ChatOpenPhase.Failed, on));
            // [right-open] messages exist that aren't rows yet (older pages): never the empty chat's greeting.
            Assert.Equal(ChatIntroMode.None, ChatIntro.ModeFor(0, true, false, ChatOpenPhase.Open, on));
            // [groups] a room draws its own centre.
            Assert.Equal(ChatIntroMode.None, ChatIntro.ModeFor(0, false, true, ChatOpenPhase.Open, on));
        }
        Assert.False(ChatIntroMode.Loading.ShowsIntro());
        Assert.False(ChatIntroMode.Failed.ShowsIntro());
        Assert.False(ChatIntroMode.Blank.ShowsIntro());
        Assert.True(ChatIntroMode.Empty.ShowsIntro());
    }

    // ------------------------------------------------------------------ the words (Intro.lines)

    [Fact]
    public void TheRoleShowsOnlyWhenItDiffersFromTheNameAndTheAboutOnlyWhenItDiffersFromTheRole()
    {
        Assert.Equal(("Research helper", null), ChatIntro.Lines("Ivy", "Research helper", "Research helper"));
        Assert.Equal(("Research helper", "Reads papers for you."), ChatIntro.Lines("Ivy", "Research helper", "Reads papers for you."));
        Assert.Equal((null, null), ChatIntro.Lines("Ivy", "  ivy ", null));
        Assert.Equal((null, "Reads papers."), ChatIntro.Lines("Ivy", "IVY", " Reads papers. "));
        Assert.Equal((null, null), ChatIntro.Lines("Ivy", "  ", "\n"));
        Assert.Equal(("Planner", null), ChatIntro.Lines("Otto", " Planner ", null));
    }

    [Fact]
    public void WithNoAboutTheBodySaysNoMessagesYet()
    {
        Assert.Equal("No messages yet. Say hello.", ChatIntro.Fallback);
        Assert.Equal("No messages yet. Say hello.", ChatIntro.Body(ChatIntro.Lines("Ivy", null, null)));
        Assert.Equal("Reads papers.", ChatIntro.Body(ChatIntro.Lines("Ivy", null, "Reads papers.")));
        Assert.Equal("No messages yet", ChatIntro.OffLabel);
    }

    // ------------------------------------------------------------------ whose name (botName)

    [Fact]
    public void TheIntroNamesTheBotNotTheChatsTitle()
    {
        Assert.Equal("Ivy", ChatIntro.BotName("Ivy", "ivy"));
        Assert.Equal("Hermes", ChatIntro.BotName(null, "default"));
        Assert.Equal("Wren Bot", ChatIntro.BotName("  ", "wren-bot"));
        Assert.NotEqual("New Chat", ChatIntro.BotName(null, "default"));
    }

    // ------------------------------------------------------------------ Name Chat (canName)

    [Fact]
    public void NameChatShowsOnlyForAnUnnamedChatThatIsNotTheBotsOwn()
    {
        Assert.True(ChatIntro.IsUnnamed(""));
        Assert.True(ChatIntro.IsUnnamed(" New Chat "));
        Assert.True(ChatIntro.IsUnnamed("untitled chat"));
        Assert.False(ChatIntro.IsUnnamed("Trip planning"));
        Assert.True(ChatIntro.CanName("New Chat"));
        Assert.False(ChatIntro.CanName("Trip planning"));
        Assert.False(ChatIntro.CanName(Hermes.Core.Model.Bot.BotChatTitle));
    }

    // ------------------------------------------------------------------ the switch (IntroSplash)

    [Fact]
    public void TheSwitchIsOnUntilTurnedOffAndSaysSo()
    {
        var prefs = new MemoryPrefs();
        Assert.Equal("hqn.introSplash", ChatIntro.Key);
        Assert.True(ChatIntro.IsOnIn(prefs));
        Assert.True(ChatIntro.IsOnIn(null));
        var changes = 0;
        void Count() => changes++;
        ChatIntro.Changed += Count;
        try
        {
            Assert.True(ChatIntro.SetIn(prefs, false));
            Assert.Equal("false", prefs.Get(ChatIntro.Key));
            Assert.False(ChatIntro.IsOnIn(prefs));
            Assert.False(ChatIntro.SetIn(prefs, false));   // no change, no notice (the Mac's `guard newValue != isOn`)
            Assert.True(ChatIntro.SetIn(prefs, true));
            Assert.Null(prefs.Get(ChatIntro.Key));
            Assert.True(ChatIntro.IsOnIn(prefs));
        }
        finally { ChatIntro.Changed -= Count; }
        Assert.True(changes >= 2);
    }

    [Fact]
    public void SettingsSearchFindsTheGreetingRowUnderChat()
    {
        Assert.Equal("Greeting on Empty Chats", SettingsWords.IntroSplashLabel);
        var hits = SettingsSearch.Results("intro splash", SettingsSearch.Index);
        Assert.Contains(hits, h => h.Target == "row:intro-splash" && h.Label == SettingsWords.IntroSplashLabel);
        Assert.Equal(SettingsCategory.Chat, SettingsSearch.Category("row:intro-splash"));
    }

    // ------------------------------------------------------------------ the page's hook and the walk (source)

    private static string WindowsDir()
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir) ?? throw new InvalidOperationException("no windows dir");
        return dir;
    }

    [Fact]
    public void TheChatPageReportsItsPhaseAndRowsToTheIntro()
    {
        var page = File.ReadAllText(Path.Combine(WindowsDir(), "src", "HermesHQ.Windows", "Pages", "ChatPage.xaml.cs"));
        // OpenChatShutdownTests executes both outcomes and the row/phase notifications on the real ChatContext.
        Assert.Contains("AttachOpening(opening, vm, args)", page);
        Assert.Contains("await FinishOpeningAsync(opening, vm, args)", page);
        var xaml = File.ReadAllText(Path.Combine(WindowsDir(), "src", "HermesHQ.Windows", "Pages", "ChatPage.xaml"));
        Assert.Contains("x:Name=\"TranscriptEmpty\"", xaml);
        var registry = File.ReadAllText(Path.Combine(WindowsDir(), "src", "HermesHQ.Windows", "Shell", "FeatureRegistry.cs"));
        Assert.Contains("ChatIntroFeature.Register()", registry);
    }

    [Fact]
    public void TheIntroWalkRunsOnTheComposerStandInAfterBareNew()
    {
        var yml = File.ReadAllText(Path.Combine(WindowsDir(), "ci", "windows.yml"));
        var line = yml.Split('\n').Single(l => l.Contains("tag = \"composer\""));
        Assert.Contains("\"new-chat-bare\",\"chat-intro\"", line);
        Assert.Contains("\"chat-intro-off\"", line);
        Assert.Contains("\"chat-intro-sent\"", line);
    }
}
