using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Bots;
using Hermes.Core.Sessions;
using Hermes.Core.Settings;

namespace Hermes.Core.Tests;

/// Working Ring on shipping Mac 1240 (`AppPreferences.swift`, `AppearancePage.swift`, `WorkingRingTests.swift`): off
/// until enabled, both choices stored explicitly when changed. The working words and face mark do not need a ring.
public class WorkingRingTests
{
    private static BotRow Bot(bool working, string? needsInput = null)
    {
        var p = RosterProfile.From(JsonNode.Parse("""{"name":"otto"}"""))!;
        return new BotRow { Id = "otto", Name = "Otto", Profile = p, Model = p.ToModel("Otto", new BotMeta()), IsWorking = working, NeedsInput = needsInput };
    }

    private static SessionSummary Chat(SessionStatus status) =>
        new() { Id = "s1", Profile = "otto", Title = "Draft the plan", Status = status, IsRunning = status == SessionStatus.Working };

    [Fact]
    public void TheMacsKeyCopyAndDefault()
    {
        Assert.Equal("hqn.workingRing", WorkingRing.Key);
        Assert.Equal("Working Ring", WorkingRing.Label);
        Assert.Equal("Working Ring is the moving line around a bot or chat while it works. Off, its working dots and “Working…” still show.", WorkingRing.Note);
        Assert.Equal("Bots & Sessions", WorkingRing.SectionTitle);
        Assert.Equal("theme.workingRing", WorkingRing.AutomationId);
        Assert.Equal("row:working-ring", WorkingRing.RowTarget);
        Assert.Equal(2.23, WorkingRing.LapSeconds);
        Assert.False(WorkingRing.Read(new MemoryPrefs()));
        Assert.False(WorkingRing.Read(null));
        Assert.False(WorkingRing.Write(null, true));
    }

    [Fact]
    public void AChangeStoresEitherChoiceAndARelaunchKeepsIt()
    {
        static MemoryPrefs Relaunch(MemoryPrefs saved)
        {
            var next = new MemoryPrefs();
            foreach (var (key, value) in saved.Values) next.Set(key, value);
            return next;
        }
        var prefs = new MemoryPrefs();
        Assert.False(WorkingRing.Write(prefs, false));        // a fresh default doesn't need a migration or write
        Assert.False(prefs.Values.ContainsKey(WorkingRing.Key));
        Assert.True(WorkingRing.Write(prefs, true));
        Assert.Equal("true", prefs.Get(WorkingRing.Key));
        prefs = Relaunch(prefs);
        Assert.True(WorkingRing.Read(prefs));
        Assert.False(WorkingRing.Write(prefs, true));
        Assert.Equal("true", prefs.Get(WorkingRing.Key));
        Assert.True(WorkingRing.Write(prefs, false));
        Assert.Equal("false", prefs.Get(WorkingRing.Key));
        prefs = Relaunch(prefs);
        Assert.False(WorkingRing.Read(prefs));
        Assert.False(WorkingRing.Write(prefs, false));
        Assert.Equal("false", prefs.Get(WorkingRing.Key));
    }

    [Theory]
    [InlineData(null, false)]
    [InlineData("false", false)]
    [InlineData("true", true)]
    [InlineData("garbled", false)]
    [InlineData("", false)]
    public void ReadingAnExistingChoiceNeverRewritesIt(string? stored, bool expected)
    {
        var prefs = new MemoryPrefs();
        prefs.Set(WorkingRing.Key, stored);
        Assert.Equal(expected, WorkingRing.Read(prefs));
        Assert.False(WorkingRing.Write(prefs, expected));
        Assert.Equal(stored, prefs.Get(WorkingRing.Key));
    }

    [Fact]
    public void TheSwitchTellsListsAtOnceAndOnlyOnChange()
    {
        var prefs = new MemoryPrefs();
        var was = WorkingRing.Store;
        var heard = 0;
        void Count() => heard++;
        WorkingRing.Store = prefs;
        WorkingRing.Changed += Count;
        try
        {
            Assert.False(WorkingRing.IsOn);
            WorkingRing.IsOn = false;
            Assert.Equal(0, heard);
            WorkingRing.IsOn = true;
            Assert.Equal(1, heard);
            Assert.True(WorkingRing.IsOn);
            Assert.True(WorkingRing.ShowsBotRing(Bot(true), WorkingRing.IsOn));
            Assert.True(WorkingRing.ShowsChatRing(Chat(SessionStatus.Working), WorkingRing.IsOn));
            WorkingRing.IsOn = true;
            Assert.Equal(1, heard);
            WorkingRing.IsOn = false;
            Assert.Equal(2, heard);
            Assert.False(WorkingRing.IsOn);
            Assert.False(WorkingRing.ShowsBotRing(Bot(true), WorkingRing.IsOn));
            Assert.False(WorkingRing.ShowsChatRing(Chat(SessionStatus.Working), WorkingRing.IsOn));
            WorkingRing.IsOn = false;
            Assert.Equal(2, heard);
        }
        finally
        {
            WorkingRing.Changed -= Count;
            WorkingRing.Store = was;
        }
    }

    [Fact]
    public void ABotRingsOnlyWhileItWorksAndNotWhileItWaitsOnYou()
    {
        Assert.True(WorkingRing.ShowsBotRing(Bot(true), ringOn: true));
        Assert.False(WorkingRing.ShowsBotRing(Bot(false), ringOn: true));
        Assert.False(WorkingRing.ShowsBotRing(Bot(true, "Waiting for your reply"), ringOn: true));
        Assert.False(WorkingRing.ShowsBotRing(Bot(true), ringOn: false));
    }

    [Fact]
    public void AChatRingsOnlyWhileItWorks()
    {
        Assert.True(WorkingRing.ShowsChatRing(Chat(SessionStatus.Working), ringOn: true));
        foreach (var idle in new[] { SessionStatus.Idle, SessionStatus.NeedsInput, SessionStatus.Unread, SessionStatus.Draft })
            Assert.False(WorkingRing.ShowsChatRing(Chat(idle), ringOn: true));
        Assert.False(WorkingRing.ShowsChatRing(Chat(SessionStatus.Working), ringOn: false));
    }

    [Fact]
    public void ReducedMotionKeepsTheRingButStill()
    {
        Assert.True(WorkingRing.Travels(animationsEnabled: true));
        Assert.False(WorkingRing.Travels(animationsEnabled: false));
    }

    [Fact]
    public void OffTheRowStillSaysItWorks()
    {
        // Bots: the spoken label and the second line carry "Working…" whatever the switch.
        var bot = Bot(true);
        Assert.Contains("Working", BotList.AccessibilityLabel(bot, ""));
        Assert.Equal("Working…", BotList.SecondLine(bot).Text);
        // A sidebar chat's spoken name carries its state; an idle one is its title alone.
        Assert.Equal("Draft the plan, Working", WorkingRing.ChatSpokenName(Chat(SessionStatus.Working)));
        Assert.Equal("Draft the plan", WorkingRing.ChatSpokenName(Chat(SessionStatus.Idle)));
        Assert.Equal("Draft the plan, Reading notes",
            WorkingRing.ChatSpokenName(Chat(SessionStatus.Working) with { Step = "Reading notes…" }));
    }

    [Fact]
    public void SettingsSearchFindsTheSwitchOnAppearance()
    {
        var hit = Assert.Single(SettingsSearch.Results("working animation", SettingsSearch.Index));
        Assert.Equal("app:working-ring", hit.Id);
        Assert.Equal("Working Ring", hit.Label);
        Assert.Equal("row:working-ring", hit.Target);
        Assert.Equal(SettingsCategory.Appearance, SettingsSearch.Category(hit.Target));
    }

    // ---------------------------------------------------------------- source (WinUI can't run here)

    private static string Source(params string[] parts)
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir) ?? throw new InvalidOperationException("no windows dir");
        return File.ReadAllText(Path.Combine([dir, "src", "HermesHQ.Windows", .. parts]));
    }

    [Fact]
    public void AppearanceHasTheSwitchAfterTextSizeWithTheMacsFooter()
    {
        var panes = Source("Features", "Settings", "SettingsPanes.cs");
        var appearance = Regex.Match(panes, @"private static FrameworkElement Appearance\(SettingsPage page\)(?<b>.*?)\n    \}", RegexOptions.Singleline).Groups["b"].Value;
        // [density] The group's footer is the Mac's `listsNote` (Compact's note in the iOS look, then this one's).
        Assert.Contains("Kit.Section(WorkingRing.SectionTitle, DensityRow.ListsNote(state), DensityRow.Shown(state) ? DensityControl(state) : null, WorkingRingRow())", appearance);
        Assert.EndsWith(WorkingRing.Note, DensityRow.ListsNote(ThemeState.Default));
        var row = Regex.Match(panes, @"private static FrameworkElement WorkingRingRow\(\)(?<b>.*?)\n    \}", RegexOptions.Singleline).Groups["b"].Value;
        Assert.Matches(@"Kit\.Toggle\(\w+, WorkingRing\.Label, null, WorkingRing\.IsOn, on => WorkingRing\.IsOn = on, WorkingRing\.RowTarget\)", row);
        Assert.Contains("SetAutomationId(toggle, WorkingRing.AutomationId)", row);
        Assert.True(appearance.IndexOf("\"Text Size\"", StringComparison.Ordinal) < appearance.IndexOf("WorkingRing.SectionTitle", StringComparison.Ordinal));
        Assert.Contains("WorkingRing.Store = FilePreferences.Shared", Source("Features", "Settings", "ThemeService.cs"));
    }

    [Fact]
    public void BotAndChatRowsWearTheGatedRingAndRedrawAtOnce()
    {
        var rows = Source("Shell", "SidebarItems.cs");
        Assert.Contains("WorkingRingView.Wrap(", rows);
        Assert.Contains("WorkingRing.ShowsBotRing(bot, WorkingRing.IsOn)", rows);
        Assert.Contains("WorkingRing.ShowsChatRing(c.Chat, WorkingRing.IsOn)", rows);
        Assert.Contains("WorkingRing.ChatSpokenName(c.Chat)", rows);
        var sessions = Source("Pages", "SessionsPage.xaml.cs");
        Assert.Contains("WorkingRing.ShowsChatRing(s, WorkingRing.IsOn)", sessions);
        foreach (var page in new[] { Source("Pages", "ShellPage.xaml.cs"), sessions })
        {
            Assert.Contains("WorkingRing.Changed += OnWorkingRing", page);
            Assert.Contains("WorkingRing.Changed -= OnWorkingRing", page);
        }
    }

    [Fact]
    public void TheRingIsDecorationAndStillUnderReducedMotion()
    {
        var view = Source("Shell", "WorkingRingView.cs");
        Assert.Contains("AccessibilityView.Raw", view);          // not a second thing for a screen reader
        Assert.Contains("IsHitTestVisible = false", view);
        Assert.Contains("WorkingRing.Travels(", view);
        Assert.Contains("UISettings().AnimationsEnabled", view);  // read only: no OS setting is changed
        Assert.DoesNotContain("AnimationsEnabled =", view);
        Assert.Contains("WorkingRing.LapSeconds", view);
        Assert.Contains("Unloaded", view);                        // a row that goes stops its lap
    }
}
