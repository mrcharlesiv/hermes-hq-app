using Hermes.Core.Groups;
using Hermes.Core.Model;
using Hermes.Core.Settings;
using Hermes.Core.Transcripts;
using HermesHQ.Controls;
using HermesHQ.Features.Settings;
using HermesHQ.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Foundation;
using Xunit;
using Tail = Microsoft.UI.Xaml.Shapes.Path;

namespace HermesHQ.ChatBubbleRows.Tests;

// Nothing launches the app: real ReplyLayout, MessageRuns, MessageView drawing methods, ChatBubbleLane and palette picks.
public class ReplyRowTests
{
    private static readonly DateTimeOffset At = DateTimeOffset.UnixEpoch.AddSeconds(10);
    private static readonly string Clock = DayLines.Clock(At);
    private const double Dip = 0.77;
    private static ToolPart Tool(string name = "read_file") => new(new ToolCall("s", name, null, null, ToolState.Done));
    private static ChatMessage Msg(params ChatPart[] parts) => new("m", Role.Assistant, parts, At);
    private static ChatMessage Parts(string order) => Msg([.. order.Select<char,ChatPart>(c => c switch {
        'w' => new TextPart("Example reply"), 't' => Tool(), 'h' => Tool("todo_list"), 'c' => Tool("clarify"),
        'r' => new ReasoningPart("Example thought"), _ => throw new ArgumentOutOfRangeException(nameof(order)) })]);
    private static ChatSender Sender(string key) => new(key, key.ToUpperInvariant(), null, key, "#FF7711");
    private static readonly ReplyContext Bubbles = new() { Style = ToolCallStyle.Bubbles };
    public ReplyRowTests() { ThemeService.State = ThemeState.Default; ThemeService.SystemHighContrast = ThemeService.Dark = ThemeService.AccessibilityTextSize = false; }

    private static FrameworkElement[] Draw(ChatMessage[] history, int i = 0, ReplyContext? context = null,
        bool group = false, bool fewer = false, MessageView? view = null)
    {
        var d = new MessageDisplay(null, MessageRuns.At(history, i, fewer), context ?? Bubbles, null) {
            ShowsSender = group && GroupRoomChrome.ShowsSenderName(history, i),
        };
        return (view ?? new()).Draw(new(history[i], group ? null : new(), d));
    }
    private static Border Box(FrameworkElement row) => row.Tree().OfType<Border>().First();
    private static int[] RowsWith(FrameworkElement[] rows, Func<FrameworkElement,bool> match) =>
        [.. rows.SelectMany((r, i) => r.Tree().Where(match).Select(_ => i))]; // do not deduplicate two clocks on one row
    private static bool VisibleTime(FrameworkElement e) => e is TextBlock { Text: var s } && s == Clock || e is RichTextBlock { Trailing: var t } && t == Clock;
    private static int[] Indices(string csv) => csv.Length == 0 ? [] : csv.Split(',').Select(int.Parse).ToArray();

    [Theory]
    [InlineData("w", "0", "0")]
    [InlineData("wt", "1", "0,1")]
    [InlineData("t", "0", "0")]
    [InlineData("tw", "1", "0,1")]
    [InlineData("wtw", "2", "0,1,2")]
    [InlineData("wh", "0", "0")]
    [InlineData("h", "", "")]
    [InlineData("wct", "2", "0,2")]
    [InlineData("tcr", "0", "0")]
    public void OnlyTheLastDrawnBubbleOwnsTheClockAndTail(string order, string end, string laneIndices)
    {
        var rows = Draw([Parts(order)]);
        Assert.Equal(Indices(end), RowsWith(rows, VisibleTime));
        Assert.Equal(Indices(end), RowsWith(rows, e => e is Tail));
        Assert.Equal(Indices(laneIndices), RowsWith(rows, e => e is ChatBubbleLane));
        foreach (var i in Indices(laneIndices)) {
            var lane = Assert.IsType<ChatBubbleLane>(rows[i]);
            var near = i > 0 && rows[i - 1] is ChatBubbleLane;
            Assert.Equal((near ? 2 : 6) * Dip, lane.Margin.Top, 6);
            Assert.Equal(ThemeResolver.Resolve(ThemeState.Default).Light.BotBubble, Box(lane).Background?.Color);
        }
    }

    [Theory]
    [InlineData(ToolCallStyle.Bubbles, true, false, "0", "0")]
    [InlineData(ToolCallStyle.Bubbles, true, true, "1", "0,1")]
    [InlineData(ToolCallStyle.Header, false, false, "0", "0")]
    [InlineData(ToolCallStyle.Rows, false, false, "0", "0")]
    [InlineData(ToolCallStyle.Bottom, false, false, "1", "1")]
    public void FoldingHidingOrRevealingStepsChangesWhichRowCanOwnTime(ToolCallStyle style, bool hide, bool reveal, string end, string lanes)
    {
        var rows = Draw([Parts("wt")], context: new() { Style = style, HideSteps = hide, Revealed = reveal });
        Assert.Equal(Indices(end), RowsWith(rows, VisibleTime));
        Assert.Equal(Indices(end), RowsWith(rows, e => e is Tail));
        Assert.Equal(Indices(lanes), RowsWith(rows, e => e is ChatBubbleLane));
    }

    [Fact]
    public void DifferentAuthorsAndReactionsBreakAJoinedRunOnlyOnce()
    {
        ChatMessage From(string id, string name, string parts) => Parts(parts) with { Id = id, Sender = Sender(name) };
        ChatMessage[] history = [From("a", "ivy", "wt"), From("b", "ivy", "w"),
            From("c", "wren", "w") with { Reactions = [new("❤️", "otto")] }, From("d", "wren", "w"), Parts("w")];
        var rows = history.Select((_, i) => Draw(history, i, group: true)).ToArray();
        Assert.Equal(new[] { "IVY", "WREN", "WREN" }, rows.SelectMany(r => r).SelectMany(r => r.Tree()).OfType<TextBlock>()
            .Where(t => t.Id == MessageView.SenderNameId).Select(t => t.Text));
        Assert.Empty(RowsWith(rows[0], VisibleTime));
        Assert.Empty(RowsWith(rows[0], e => e is Tail));
        Assert.Equal(2 * Dip, Assert.IsType<ChatBubbleLane>(rows[1][0]).Margin.Top, 6);
        foreach (var i in new[] { 1, 2, 3, 4 }) Assert.Equal(new[] { 0 }, RowsWith(rows[i], VisibleTime));
        foreach (var i in new[] { 0, 2, 3 }) AssertInsideFirstLine(rows[i][0], history[i].Sender!.Name);
        Assert.Empty(RowsWith(rows[1], e => e.Id == MessageView.SenderNameId));
        Assert.Empty(RowsWith(rows[4], e => e.Id == MessageView.SenderNameId));
    }

    private static (TextBlock Name, BotHead Head) AssertInsideFirstLine(FrameworkElement row, string expected)
    {
        var b = Box(Assert.IsType<ChatBubbleLane>(row));
        var first = Assert.IsAssignableFrom<Panel>(b.Child).Children.First();
        var name = Assert.Single(first.Tree().OfType<TextBlock>(), t => t.Id == MessageView.SenderNameId);
        var head = Assert.Single(first.Tree().OfType<BotHead>());
        Assert.Equal(expected, name.Text);
        Assert.Equal("chat.sender.face", head.Id);
        return (name, head);
    }

    [Fact]
    public void FirstProseOwnsTheBylineNotAnEarlierToolOrTheSearchableMarkdown()
    {
        var view = new MessageView();
        var rows = Draw([Parts("twtw") with { Sender = Sender("ivy") }], group: true, view: view);
        Assert.Equal(new[] { 1 }, RowsWith(rows, e => e.Id == MessageView.SenderNameId));
        AssertInsideFirstLine(rows[1], "IVY");
        Assert.Equal(2, view.Findable.Count);
        Assert.DoesNotContain(view.Findable.SelectMany(e => e.Tree()), e => e.Id == MessageView.SenderNameId || e is BotHead);
    }

    [Theory]
    [InlineData("")]
    [InlineData("h")]
    public void NoPaintedRowAboveCannotConsumeAMembersFirstByline(string silent)
    {
        var member = Sender("ivy");
        ChatMessage[] history = [Parts(silent) with { Id = "silent", Sender = member }, Parts("w") with { Sender = member }];
        Assert.Empty(Draw(history, 0, group: true));
        AssertInsideFirstLine(Assert.Single(Draw(history, 1, group: true)), member.Name);
    }

    [Fact]
    public void ActivityAndProseKeepTheirDistinctTimeAndAnnouncementPolicies()
    {
        // Mac ActivityRows:689–690,1361 and ActivityCells:182–191 draw the dated last tool's
        // clock directly. TextLayout:1082 suppresses a streaming text clock. The earlier prose
        // must not keep either a visible or a spoken copy when ownership moves to the tool.
        foreach (var first in new[] { Parts("wt"), Parts("wt") with { IsStreaming = true } })
        {
            var rows = Draw([first, Parts("w") with { Role = Role.User }, Parts("w")], fewer: true);
            Assert.Equal(new[] { 1 }, RowsWith(rows, VisibleTime));
            Assert.Equal(new[] { 1 }, RowsWith(rows, e => e is Tail));
            Assert.Empty(RowsWith(rows, e => e.Help == Clock));
        }
        var streamingWords = Draw([Parts("tw") with { IsStreaming = true }]);
        Assert.Empty(RowsWith(streamingWords, VisibleTime));
        Assert.Equal(new[] { 1 }, RowsWith(streamingWords, e => e is Tail));
    }

    [Theory]
    [InlineData(220, false, false)]
    [InlineData(900, false, false)]
    [InlineData(900, true, false)]
    [InlineData(900, false, true)]
    public void LastToolOwnsTheFullMacToolFrameWithItsOwnTextInsets(double slot, bool desktop, bool plain)
    {
        // ActivityRows.swift:1274–1277,1371–1378: even a short step has a full reply-width
        // frame, with a 12 × 8 point inset also when the shape behind it is unpainted.
        ThemeService.State = ThemeState.Default with { DesktopLook = desktop, PlainReplies = plain };
        var rows = Draw([Parts("wt")]);
        var lane = Assert.IsType<ChatBubbleLane>(rows[1]); var box = Box(lane);
        var cap = Math.Min(slot, 728 * Dip);
        lane.Measure(new Size(slot, 600)); lane.Arrange(new Rect(0, 0, slot, lane.DesiredSize.Height));
        Assert.Equal(cap, lane.Children[0].Frame.Width, 6);
        Assert.Equal(12 * Dip, box.Padding.Left + box.BorderThickness.Left, 6);
        Assert.Equal(8 * Dip, box.Padding.Top + box.BorderThickness.Top, 6);
        Assert.Equal(new[] { 1 }, RowsWith(rows, VisibleTime));
        Assert.Equal(!desktop && !plain, box.Background != null);
        var words = Assert.IsType<ChatBubbleLane>(rows[0]);
        words.Measure(new Size(slot, 600)); words.Arrange(new Rect(0, 0, slot, words.DesiredSize.Height));
        Assert.True(words.Children[0].Frame.Width < cap);
    }

    [Theory]
    [InlineData("t", "w", true)]   // repair crosses two separate recycled MessageViews
    [InlineData("w", "tw", true)]  // tool and final prose belong to the same message
    [InlineData("tr", "w", false)] // a thought between them breaks row adjacency
    [InlineData("tc", "w", false)] // so does an ordinary tool card
    [InlineData("w", "w", false)]
    public void ActualChatProjectionKeepsTheShippingClockWhenAQuietWordJoinsATool(string before, string end, bool visible)
    {
        // ActivityRows:671–676 reassigns the stamp when a text row *newly* joins a tool.
        var previous = ChatDisplaySettings.Store;
        try {
            ChatDisplaySettings.Store = new MemoryPrefs(); ChatDisplaySettings.Style = ToolCallStyle.Bubbles;
            ChatMessage[] history = [Parts(before) with { Id = "a" }, Parts(end) with { Id = "b" },
                Parts("w") with { Id = "c", Role = Role.User }, Parts("w") with { Id = "d" }];
            var owner = new ChatViewModel(); var display = owner.Project(history)[1];
            Assert.False(display.ShowTime); // unchanged message-level Fewer Timestamps decision
            var rows = new MessageView().Draw(new(history[1], owner, display));
            var last = Assert.Single(RowsWith(rows, e => e is Tail));
            Assert.Equal(visible ? new[] { last } : [], RowsWith(rows, VisibleTime));
            Assert.Equal(visible ? [] : new[] { last }, RowsWith(rows, e => e.Help == Clock));
        } finally { ChatDisplaySettings.Store = previous; }
    }

    [Theory]
    [InlineData("nous", false)]
    [InlineData("paper", true)]
    [InlineData("rose-pine", false)]
    [InlineData("rose-pine", true)]
    public void BoxAndTailUseTheSkinsOwnPaintWithoutRetintingTheSender(string skin, bool dark)
    {
        ThemeService.Dark = dark;
        ThemeService.State = ThemeState.Default with { SkinId = skin, BubbleCorners = 21, UiScalePercent = 150 };
        var t = ThemeResolver.Resolve(ThemeService.State).Tokens(dark);
        var sender = Sender("ivy");
        var rows = Draw([Parts("wt") with { Sender = sender }], group: true);
        var name = AssertInsideFirstLine(rows[0], sender.Name).Name;
        var colors = GroupRoomChrome.NameColor(sender.ColorHex)!.Value;
        var c = dark ? colors.Dark : colors.Light;
        Assert.Equal(Rgba.C((byte)c.R, (byte)c.G, (byte)c.B), name.Foreground?.Color);
        foreach (var row in rows) {
            var b = Box(row); Assert.Equal(t.BotBubble, b.Background?.Color);
            Assert.Equal(t.OwnLook?.ReplyEdge ?? Rgba.Clear, b.BorderBrush?.Color ?? Rgba.Clear);
            Assert.Equal(21 * Dip, b.CornerRadius.TopLeft, 6);
        }
        var tail = Assert.Single(rows[1].Tree().OfType<Tail>());
        Assert.Same(Box(rows[1]).Background, tail.Fill);
        Assert.Equal(Box(rows[1]).BorderBrush?.Color, tail.Stroke?.Color);
    }

    [Theory]
    [InlineData(10, 20)]
    [InlineData(23.2, 24)]
    [InlineData(50, 28)]
    public void FaceFollowsTheMeasuredSingleLineAndStopsAtTheMacLimit(double linePoints, double facePoints)
    {
        var rows = Draw([Parts("w") with { Sender = Sender("ivy") }], group: true);
        var (name, head) = AssertInsideFirstLine(Assert.Single(rows), "IVY");
        name.Arrange(new Rect(0, 0, 60, linePoints * Dip));
        Assert.Equal(facePoints * Dip, head.Width, 6); Assert.Equal(head.Width, head.Height);
    }

    [Theory]
    [InlineData(false, "nous")]
    [InlineData(true, "nous")]
    [InlineData(false, "rose-pine")]
    [InlineData(true, "rose-pine")]
    public void DesktopContrastBoxesTheReplyWithTheResolvedSoftPaint(bool dark, string skin)
    {
        ThemeService.Dark = dark;
        ThemeService.State = ThemeState.Default with { DesktopLook = true, HighContrast = true, SkinId = skin };
        var t = ThemeResolver.Resolve(ThemeService.State).Tokens(dark);
        var b = Box(Assert.Single(Draw([Parts("w")])));
        Assert.Equal(t.BotBubble.Alpha(t.BotBubble.A * .5), b.Background?.Color);
        Assert.Equal(t.Label.Alpha(t.Label.A * .12), b.BorderBrush?.Color);
        Assert.Equal(new Thickness(Dip), b.BorderThickness);
        Assert.Equal(16 * Dip, b.Padding.Left + b.BorderThickness.Left, 6);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void DesktopBoxesProseButDoesNotInventAToolShapeWhenContrastChanges(bool system)
    {
        ThemeService.SystemHighContrast = system;
        ThemeService.State = ThemeState.Default with { DesktopLook = true, HighContrast = true };
        var rows = Draw([Parts("wt")]);
        Assert.NotNull(Box(rows[0]).BorderBrush);
        Assert.Null(Box(rows[1]).Background); Assert.Null(Box(rows[1]).BorderBrush);
        Assert.Equal(new[] { 1 }, RowsWith(rows, VisibleTime));
    }

    [Theory]
    [InlineData(false, false)]
    [InlineData(false, true)]
    [InlineData(true, false)]
    [InlineData(true, true)]
    public void SystemContrastUsesOpaqueWindowInkEvenOverAppContrast(bool dark, bool desktop)
    {
        ThemeService.SystemHighContrast = true; ThemeService.Dark = dark;
        ThemeService.State = ThemeState.Default with { DesktopLook = desktop, HighContrast = true, SkinId = "rose-pine" };
        var rows = Draw([Parts("w") with { Sender = Sender("ivy") }], group: true);
        var b = Box(rows.Last());
        Assert.Equal("Window", b.Background?.SystemElement);
        Assert.Equal(ThemeService.Resolve("HQPageBrush").Color, b.Background?.Color);
        Assert.Equal("WindowText", b.BorderBrush?.SystemElement);
        Assert.NotEqual(b.Background!.Color, b.BorderBrush!.Color);
        Assert.Equal(1, b.BorderBrush.Color.A);
        Assert.True(b.BorderThickness.Top > 0);
        if (!desktop) {
            var tail = Assert.Single(rows.Last().Tree().OfType<Tail>());
            Assert.Equal("WindowText", tail.Stroke?.SystemElement); Assert.True(tail.StrokeThickness > 0);
        }
        var (name, _) = AssertInsideFirstLine(Assert.Single(rows), "IVY");
        Assert.Equal("WindowText", name.Foreground?.SystemElement);
        var mine = Draw([Parts("w") with { Role = Role.User }]).Single();
        Assert.Equal("Highlight", Box(mine).Background?.SystemElement);
        var words = Assert.IsType<TextBlock>(Box(mine).Child);
        Assert.Equal("HighlightText", words.Foreground?.SystemElement); Assert.True(words.BackplateDisabled);
        if (!desktop) Assert.Equal("HighlightText", Assert.Single(mine.Tree().OfType<TextBlock>(), x => x.Text == Clock).Foreground?.SystemElement);
    }

    [Theory]
    [InlineData(false, false)]
    [InlineData(true, false)]
    [InlineData(false, true)]
    public void PlainRepliesHaveOneInlineTimeAndNoPaintedBoxOrTail(bool desktop, bool system)
    {
        ThemeService.State = ThemeState.Default with { DesktopLook = desktop, PlainReplies = true };
        ThemeService.SystemHighContrast = system;
        var rows = Draw([Parts("tw") with { Sender = Sender("ivy") }], group: true);
        var words = rows.Last();
        var b = Box(words); Assert.Null(b.Background); Assert.Null(b.BorderBrush); Assert.Equal(0, b.BorderThickness.Top);
        Assert.Equal(new[] { 1 }, RowsWith(rows, VisibleTime)); Assert.Empty(RowsWith(rows, e => e is Tail));
        Assert.Equal(Clock, Assert.Single(words.Tree().OfType<RichTextBlock>()).Trailing);
        AssertInsideFirstLine(words, "IVY");
        var toolEnd = Draw([Parts("wt")]);
        Assert.Equal(new[] { 1 }, RowsWith(toolEnd, VisibleTime)); Assert.Empty(RowsWith(toolEnd, e => e is Tail));
        Assert.Null(Box(toolEnd[1]).Background);
    }

    [Fact]
    public void EmptyLoadingAndQuietWordsDoNotAcquireAVisibleClock()
    {
        Assert.Empty(Draw([Msg()]));
        Assert.IsType<ProgressRing>(Assert.Single(Draw([Msg() with { IsStreaming = true }], group: true)));
        var streaming = Draw([Parts("w") with { IsStreaming = true }]);
        Assert.Empty(RowsWith(streaming, VisibleTime)); Assert.Empty(RowsWith(streaming, e => e.Help != ""));
        Assert.Contains(streaming[0].Tree(), e => e.Id == "streaming-words");
        var quiet = Draw([Parts("w"), Parts("w") with { Role = Role.User }, Parts("w")], fewer: true);
        Assert.Empty(RowsWith(quiet, VisibleTime)); Assert.Equal(new[] { 0 }, RowsWith(quiet, e => e.Help == Clock));
        Assert.Equal(new[] { 0 }, RowsWith(quiet, e => e is Tail));
        var undated = Draw([Parts("t") with { Timestamp = null }]);
        Assert.Empty(RowsWith(undated, VisibleTime)); Assert.Equal(new[] { 0 }, RowsWith(undated, e => e is Tail));
    }

    [Fact]
    public void TableLaneKeepsItsWideSlotWhileNonTableWordsKeepTheirOwnCap()
    {
        ThemeService.AccessibilityTextSize = true;
        var view = new MessageView();
        var rows = Draw([Msg(new TextPart("| A | B |"), Tool())], view: view);
        var lane = Assert.IsType<ChatBubbleLane>(rows[0]); lane.Measure(new Size(900, 400));
        Assert.Equal(900, lane.Children[0].LastConstraint.Width);
        var body = Assert.Single(view.Findable);
        Assert.Contains(body.Tree(), e => Equals(e.Tag, MarkdownRenderer.InlineTableTag));
        Assert.Equal(728 * Dip - 2 * 16 * Dip, Assert.Single(body.Tree().OfType<RichTextBlock>()).MaxWidth, 6);
    }
}
