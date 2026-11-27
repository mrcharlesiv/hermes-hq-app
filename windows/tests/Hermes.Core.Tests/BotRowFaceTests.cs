// [WIN-ROW-FACE-CORNER] A bot row's face corner follows the Mac's `BotAvatar(tile: false)`: the face reads `.idle`, so no
// standing-problem badge, waking spinner or orange waiting dot on it (the row's second line says those); the working dots
// while a turn runs (also while it waits on you, and with Working Ring off); otherwise the unread presence dot. Around
// the row: the working ring only while it works and does not wait on you, with the switch on. As the Mac at 93f984bb1:
// App/Bots/BotRowViews.swift (`BotAvatar.body`, `WorkingBadge`, `PresenceDot`, `WaitingBadge`, `BotRowView`'s
// `.rowArc(BotList.showsArc(bot, ring: true))` and its marks), App/Bots/BotListModel.swift (`rowBadge`, `showsUnread`,
// `showsArc`). Ported from Tests/Presence/PresenceRulesTests.swift (rowBadges: the working and nil cases; Windows has no
// browser or computer presence), Tests/Settings/WorkingRingTests.swift
// (offTakesTheRingFromBotsAndChatsButNotTheirWorkingWords: the bot half), Tests/ReadSync/AttentionTests.swift
// (aBotWorksAndWaitsByTheGatewaysWord: the row's rules) and Tests/BotListTests.swift (aWorkingBotHidesItsUnreadCircle).
// Synthetic data only.
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Bots;
using Hermes.Core.Settings;

namespace Hermes.Core.Tests;

public class BotRowFaceTests
{
    private static BotRow Bot(string id = "wren", bool working = false, bool unread = false, string? needs = null)
    {
        var p = RosterProfile.From(JsonNode.Parse($$"""{"name":"{{id}}"}"""))!;
        var name = char.ToUpperInvariant(id[0]) + id[1..];
        return new BotRow
        {
            Id = id, Name = name, Profile = p, Model = p.ToModel(name, new BotMeta()), IsWorking = working, Unread = unread,
            NeedsInput = needs,
        };
    }

    private static BotList.FaceBadge Row(BotRow bot, bool ringOn = true) => BotList.FaceBadgeOf(bot, tile: false, ringOn, presence: true);

    // MARK: PresenceRulesTests.swift — rowBadges (working / nil)

    [Fact]
    public void RowBadges()
    {
        Assert.Equal(BotList.RowBadge.Working, BotList.RowBadgeOf(Bot(working: true)));
        Assert.Null(BotList.RowBadgeOf(Bot()));
        // Waiting on you without a turn running: no badge; with one: the working dots (as before the presence stream).
        Assert.Null(BotList.RowBadgeOf(Bot(needs: "Waiting for your approval")));
        Assert.Equal(BotList.RowBadge.Working, BotList.RowBadgeOf(Bot(working: true, needs: "Waiting for your approval")));
    }

    // MARK: WorkingRingTests.swift — offTakesTheRingFromBotsAndChatsButNotTheirWorkingWords (bots)

    [Fact]
    public void OffTakesTheRingFromABotsRowButNotItsWorkingWordsOrDots()
    {
        var bot = Bot("otto", working: true);
        Assert.True(WorkingRing.ShowsBotRing(bot, ringOn: true));
        Assert.False(WorkingRing.ShowsBotRing(bot, ringOn: false));
        Assert.Equal("Working…", BotList.SecondLine(bot).Text);                      // the row still says it works
        Assert.Equal(BotList.RowBadge.Working, BotList.RowBadgeOf(bot));               // and the face keeps its working dots
        Assert.Equal(BotList.FaceBadge.Working, Row(bot, ringOn: false));
        Assert.Equal(BotList.FaceBadge.Working, Row(bot, ringOn: true));
        bot = bot with { IsWorking = false };
        Assert.False(WorkingRing.ShowsBotRing(bot, ringOn: true));                    // an idle bot never wears it
        Assert.Equal(BotList.FaceBadge.None, Row(bot));
    }

    // MARK: AttentionTests.swift — aBotWorksAndWaitsByTheGatewaysWord (the row's rules)

    [Fact]
    public void ABotRowWorksAndWaitsWithoutAnOrangeCorner()
    {
        var herald = Bot("herald", working: true, unread: true);
        // Its turn's steps move the chat: marked, but no unread circle while it works; the face wears the working dots.
        Assert.True(herald.Unread && !BotList.ShowsUnread(herald));
        Assert.Equal(BotList.FaceBadge.Working, Row(herald));
        Assert.True(WorkingRing.ShowsBotRing(herald, ringOn: true));

        herald = herald with { NeedsInput = "Waiting for you" };
        Assert.Equal(BotList.RowStatus.NeedsInput, BotList.StatusOf(herald));
        Assert.Equal("Waiting for you", BotList.SecondLine(herald).Text);              // the row's words say it, orange
        Assert.Equal(BotList.Tone.Attention, BotList.SecondLine(herald).Tone);
        Assert.False(WorkingRing.ShowsBotRing(herald, ringOn: true));                 // the orange cue is the louder one
        Assert.Equal(BotList.FaceBadge.Working, Row(herald));                           // the turn still runs: the dots, never orange

        herald = herald with { IsWorking = false };
        Assert.Equal(BotList.FaceBadge.Unread, Row(herald));                            // no orange dot on a row's face
        herald = herald with { NeedsInput = null };
        Assert.True(BotList.ShowsUnread(herald));                                       // the turn is over: the circle shows
        Assert.Equal(BotList.FaceBadge.Unread, Row(herald));
    }

    // MARK: BotListTests.swift — aWorkingBotHidesItsUnreadCircle

    [Fact]
    public void AWorkingBotHidesItsUnreadCircle()
    {
        var working = Bot(unread: true, working: true);
        Assert.False(BotList.ShowsUnread(working));
        Assert.DoesNotContain("Unread", BotList.AccessibilityLabel(working, "9:05 AM"));
        Assert.True(BotList.ShowsUnread(Bot(unread: true)));                            // the mark shows once the turn ends
        Assert.False(BotList.ShowsUnread(Bot(working: true)));
    }

    // MARK: BotRowViews.swift — the corner's badges, drawn

    [Fact]
    public void TheBadgesKeepTheMacsSizes()
    {
        // `WorkingBadge(height: badgeSize(size))`: three dots of max(2, round(0.15 × h)), max(1, round(0.1 × h)) apart.
        Assert.Equal(14, BotList.BadgeSize(32));
        Assert.Equal((2.0, 1.0), BotList.WorkingDots(14));
        Assert.Equal((3.0, 2.0), BotList.WorkingDots(20));
        Assert.Equal((3.0, 2.0), BotList.WorkingDots(22));
        // `PresenceDot(height: presenceSize(size))`, `WaitingBadge(height: presenceSize(size) + 2)`.
        Assert.Equal(8, BotList.PresenceSize(32));
        Assert.Equal(10, BotList.WaitingSize(32));
        Assert.Equal(14, BotList.WaitingSize(50));
    }

    // MARK: The Windows rows draw it

    private static string Source(params string[] parts)
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir) ?? throw new InvalidOperationException("no windows dir");
        return File.ReadAllText(Path.Combine([dir, "src", "HermesHQ.Windows", .. parts]));
    }

    [Fact]
    public void TheSidebarRowsFaceIsDrivenByTheRowRuleNotAdHocDots()
    {
        var items = Source("Shell", "SidebarItems.cs");
        var face = Regex.Match(items, @"private static Grid Face\(BotRow bot, double size, bool tile = false\)(?<b>.*?)\n    \}", RegexOptions.Singleline).Groups["b"].Value;
        Assert.NotEmpty(face);
        // One rule for a row and a tile: `BotAvatar`'s, with `tile` passed through.
        Assert.Contains("BotList.FaceBadgeOf(bot, tile, WorkingRing.IsOn, presence: true)", face);
        Assert.DoesNotContain("NeedsInput", face);                                       // no orange dot of its own
        Assert.DoesNotContain("IsWorking", face);
        Assert.DoesNotContain("CornerDot", items);                                       // no ad hoc dots left
        // Each badge as the Mac draws it.
        Assert.Contains("BotList.FaceBadge.Working: face.Children.Add(WorkingBadge(BotList.BadgeSize(size)))", face);
        Assert.Contains("BotList.FaceBadge.Unread: face.Children.Add(PresenceDot(BotList.PresenceSize(size)))", face);
        Assert.Contains("BotList.FaceBadge.Waiting: face.Children.Add(WaitingBadge(BotList.WaitingSize(size)))", face);
        // The bot row: its face as a row's, the ring round the whole row.
        var row = Regex.Match(items, @"private static UIElement BotRowView\(SidebarBot b, ListViewItem row\)(?<b>.*?)\n    \}", RegexOptions.Singleline).Groups["b"].Value;
        Assert.Contains("g.Children.Add(Face(bot, z.Face));", row);
        Assert.Contains("WorkingRing.ShowsBotRing(bot, WorkingRing.IsOn)", row);
        // The unread presence dot is the label colour (`Color.hqLabel`), not the accent; the working dots sit on the accent.
        var presence = Regex.Match(items, @"private static Grid PresenceDot\(double dot\)(?<b>.*?)\n    \}", RegexOptions.Singleline).Groups["b"].Value;
        Assert.Contains("TextFillColorPrimaryBrush", presence);
        var working = Regex.Match(items, @"private static Grid WorkingBadge\(double badge\)(?<b>.*?)\n    \}", RegexOptions.Singleline).Groups["b"].Value;
        Assert.Contains("BotList.WorkingDots(badge)", working);
        Assert.Contains("AccentFillColorDefaultBrush", working);
        Assert.Contains("TypingDots.Count", working);
    }
}
