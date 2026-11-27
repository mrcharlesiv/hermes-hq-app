using Hermes.Core.Settings;
using Hermes.Core.Shell;
using Hermes.Core.Model;
using Hermes.Core.Groups;
using Hermes.Core.Transcripts;
using Xunit;

namespace Hermes.Core.Tests;

/// Default Mac reference: main 2b547a2b0, standard look, UI Scale 100%. Expectations are
/// from Swift app points (not sampled/rounded Windows values). One Mac app point is .77 DIP.
public class ChatVisualTokensTests
{
    [Fact]
    public void FreshSidebarEndsAtTheReferenceDividerWithoutOverwritingSavedWidths()
    {
        // App/Mac/MacSidebar.swift:25–37, App/Theme/MacTypeSteps.swift:12–13.
        Assert.Equal(300 * .77, new SidebarLayout().OpenWidth);
        Assert.Equal(310, SidebarLayout.ClampOpen(310, 1100));
    }

    [Theory]
    [InlineData(false, "#FEFEFE", "#1F2328", "#0053FD", "#0053FD", "#E9E9EB", "#E8E8E9", 0.85)]
    [InlineData(true, "#0D1015", "#E6EDF3", "#4A84FE", "#3863BF", "#26282C", "#2B2F34", 0.88)]
    public void ResolvedStandardBrushesUseShippingSrgb(bool dark, string page, string ink, string accent,
        string mine, string reply, string sidebar, double timeAlpha)
    {
        // HermesKit/Theme/ThemeTokens.swift:142–149,162–164; App/Mac/MacSidebar.swift:2025–2042.
        // Test the resolved paints (including the opaque panel), not merely their declarations.
        var t = ThemeResolver.Resolve(ThemeState.Default).Tokens(dark);
        Assert.Equal(page, t.Page.HexString);
        Assert.Equal(ink, t.Label.HexString);
        Assert.Equal(0.94, t.Label.A);
        Assert.Equal(accent, t.Tint.HexString);
        Assert.Equal(reply, t.BotBubble.HexString);
        Assert.Equal(mine, t.MeBubble.HexString);
        Assert.Equal(Rgba.White, t.MeText);
        Assert.Equal(Rgba.White.Alpha(timeAlpha), t.MeTime);
        Assert.Equal(sidebar, t.SidebarPanel.HexString);
        Assert.Equal(1, t.SidebarPanel.A);
    }

    [Fact]
    public void BubbleWidthsCornerAndInsetsAreConvertedOnce()
    {
        // App/Chat/ChatPalette.swift:105–125; HermesKit/Layout/PaneLayout.swift:85–98;
        // App/Chat/Render/TextLayout.swift:925–927,949–958; HermesKit/Theme/ThemeState.swift:53–57.
        Assert.Equal(16 * .77, ChatVisualTokens.Side);
        Assert.Equal(16 * .77, ChatVisualTokens.PadH);
        Assert.Equal(9 * .77, ChatVisualTokens.PadV);
        Assert.Equal(12 * .77, ChatBubbles.MessageCorner(ThemeState.Default));
        Assert.Equal(4 * .77, ChatBubbles.MessageCorner(ThemeState.Default with { DesktopLook = true }));
        Assert.Equal(1280 * .77, ChatVisualTokens.Column);
        Assert.Equal(728 * .77, ChatVisualTokens.BubbleWidth(900, false, false));
        Assert.Equal(728 * .77, ChatVisualTokens.BubbleWidth(900, true, false));
        Assert.Equal(240, ChatVisualTokens.BubbleWidth(300, true, false));
        Assert.Equal(300, ChatVisualTokens.BubbleWidth(300, false, false));
        Assert.Equal(900, ChatVisualTokens.BubbleWidth(900, false, false, table: true));
        Assert.Equal(810, ChatVisualTokens.BubbleWidth(900, true, true));
        Assert.Equal(2 * .77, ChatVisualTokens.RunGap);
        Assert.Equal(6 * .77, ChatVisualTokens.TurnGap);
        Assert.Equal(8 * .77, ChatVisualTokens.TailWidth);
        Assert.Equal(17 * .77, ChatVisualTokens.TailHeight);
        Assert.Equal(10 * .77, ChatVisualTokens.TimeTrailing);
        Assert.Equal(5 * .77, ChatVisualTokens.TimeBottom);
        Assert.Equal(12 * .77, ChatVisualTokens.TimeGap);
        Assert.Equal(4 * .77, ChatVisualTokens.ClockInset(24, false));
        Assert.Equal(0, ChatVisualTokens.ClockInset(24, true));
        Assert.Equal(0, ChatVisualTokens.ClockInset(12, false));
        Assert.Equal("HighlightText", HighContrastWalkProof.SystemColourFor("HQMeTimeBrush"));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void DefaultContentSizeUsesTheMacFontForEachRole(bool desktop)
    {
        // ThemeFonts.swift:13–26,49–68,96–109; ThemeState.swift:69–75,81–105; MacTypeSteps.swift:12–13,27–34.
        // UIFont preferred sizes at .large (captions become footnote), or desktopSpec; half-pt rounding before .77.
        var t = ChatVisualTokens.Type(desktop);
        ChatVisualTokens.Face[] faces = [t.LargeTitle, t.Title1, t.Title2, t.Title3, t.Headline, t.Body, t.Callout,
            t.Subhead, t.Footnote, t.Caption1, t.Caption2];
        double[] pt = desktop ? [28.5, 26, 23.5, 21, 19.5, 19.5, 18, 17.5, 16.5, 15.5, 15]
            : [39, 32, 25.5, 23, 19.5, 19.5, 18.5, 17.5, 15, 15, 15];
        for (var i = 0; i < pt.Length; i++)
        {
            Assert.Equal(pt[i] * .77, faces[i].Size, 6);
            Assert.Equal((ushort)(i == 4 || desktop && i < 4 ? 600 : 400), faces[i].Weight);
        }
        // ChatStyle.swift:98–113,123 (the default chat factor is 1).
        Assert.Equal(29 * .77, t.BodyLine, 6);
        Assert.Equal(18 * .77, t.InlineCode, 6);
        Assert.Equal((desktop ? 25 : 23) * .77, t.CodeLine, 6);
        Assert.Equal((desktop ? 24 : 21) * .77, t.TableLine, 6);
        Assert.Equal(13 * .77, t.ParagraphGap, 6);
        Assert.Equal(new[] { 24, 22, 21, 21 }.Select(n => new ChatVisualTokens.Face(n * .77, 600)),
            Enumerable.Range(1, 4).Select(t.Heading));
    }

    [Fact]
    public void PlainRepliesIsAPreferenceNotAConsequenceOfThePlatform()
    {
        // ThemeState.swift:49,60,145,347. A stored preference survives switching to and from the Desktop Look.
        var prefs = new MemoryPrefs();
        var store = new ThemeStore(prefs);
        Assert.False(store.Load().AppliedPlainReplies);
        prefs.Set(ThemeStore.Key.PlainReplies, "true");
        var plain = store.Load();
        Assert.True(plain.AppliedPlainReplies);
        Assert.True(ChatBubbles.Notify(ThemeState.Default, plain));
        Assert.True((ThemeState.Default with { DesktopLook = true }).AppliedPlainReplies);
        Assert.False((plain with { DesktopLook = true, HighContrast = true }).AppliedPlainReplies);
    }

    private static ChatMessage Msg(int seconds, Role role = Role.Assistant) =>
        new($"{role}:{seconds}", role, [new TextPart("words")], DateTimeOffset.UnixEpoch.AddSeconds(seconds));

    [Fact]
    public void ClocksMoveToTheNewRunEndAndBreakAtTheSwiftBoundaries()
    {
        // ChatRow.swift:1207–1214,1244–1255. Adjacent pairs compare, not elapsed time since the start.
        var a = Msg(10); var b = Msg(310); var c = Msg(610);
        Assert.Equal(new MessageRuns.Run(false, true, true), MessageRuns.At([a], 0, false));
        ChatMessage[] joined = [a, b, c];
        Assert.Equal(new MessageRuns.Run(false, false, false), MessageRuns.At(joined, 0, false));
        Assert.Equal(new MessageRuns.Run(true, false, false), MessageRuns.At(joined, 1, false));
        Assert.Equal(new MessageRuns.Run(true, true, true), MessageRuns.At(joined, 2, false));
        Assert.False(MessageRuns.At(joined, 2, false, dayAbove: true).JoinedAbove);
        Assert.True(MessageRuns.At([a, Msg(311)], 0, false).ShowTime);
        Assert.True(MessageRuns.At([a, Msg(20, Role.User)], 0, false).ShowTime);
        Assert.True(MessageRuns.At([a with { Reactions = [new("👍", "ivy")] }, b], 0, false).ShowTime);
        var member = new ChatSender("ivy", "Ivy", null, "ivy", null);
        Assert.True(MessageRuns.At([a, b with { Sender = member }], 0, false).ShowTime);
        Assert.False(MessageRuns.At([a with { Sender = member }, b with { Sender = member }], 0, false).ShowTime);
        Assert.False(MessageRuns.At([a with { Timestamp = null }], 0, false).ShowTime);
        Assert.False(MessageRuns.At([a with { IsStreaming = true }], 0, false).ShowTime);
        Assert.False(MessageRuns.At([Msg(10, Role.System)], 0, false).ShowTime);
    }

    [Fact]
    public void FewerTimesShowsOnlyTheLastOwnReplyOfTheMinuteEvenAcrossSpeakers()
    {
        // ToolCallSettings.swift:90–98; ChatRow.swift:1317–1335: up to eight messages ahead.
        ChatMessage[] history = [Msg(10), Msg(15, Role.User), Msg(20), Msg(40, Role.User), Msg(60)];
        Assert.Equal(new[] { 2, 4 }, Enumerable.Range(0, history.Length).Where(i => MessageRuns.At(history, i, true).ShowTime));
        Assert.All(Enumerable.Range(0, history.Length), i => Assert.True(MessageRuns.At(history, i, false).ShowTime));
        var unusable = new[] { Msg(20) with { Error = "failed" }, Msg(20) with { Interrupted = true },
            Msg(20) with { Parts = [new TextPart(" \n\u200B ")] }, Msg(20) with { Sender = new("ivy", "Ivy", null, "ivy", null) } };
        foreach (var m in unusable) Assert.True(MessageRuns.At([Msg(10), Msg(15, Role.User), m], 0, true).ShowTime);
        foreach (var distance in new[] { 8, 9 })
        {
            ChatMessage[] sparse = [Msg(10), .. Enumerable.Range(1, distance - 1).Select(i => Msg(10 + i, Role.System)), Msg(20)];
            Assert.Equal(distance == 9, MessageRuns.At(sparse, 0, true).ShowTime);
        }
    }

    [Fact]
    public void FortyAlternatingSeedRowsInOneMinuteHaveOneVisibleClockAtTheNewestReply()
    {
        // 02-chat's performance fixture alternates roles (performance-fixture-gateway.py:121–124).
        var messages = Enumerable.Range(0, 40).Select(i => Msg(i, i % 2 == 0 ? Role.User : Role.Assistant)).ToArray();
        Assert.Equal(new[] { 39 }, Enumerable.Range(0, messages.Length).Where(i => MessageRuns.At(messages, i, true).ShowTime));
        Assert.Equal(40, Enumerable.Range(0, messages.Length).Count(i => MessageRuns.At(messages, i, false).ShowTime));
    }

    [Fact]
    public void TheViewsUseTheResolvedGroundsAndTheSameRunDecisions()
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir) ?? throw new DirectoryNotFoundException();
        string FileAt(string path) => File.ReadAllText(Path.Combine(dir, "src", "HermesHQ.Windows", path));
        var shell = System.Xml.Linq.XDocument.Parse(FileAt("Pages/ShellPage.xaml"));
        var panel = shell.Descendants().Single(e => e.Attributes().Any(a => a.Name.LocalName == "Name" && a.Value == "SidebarPane"));
        Assert.Equal("{ThemeResource HQSidebarPanelBrush}", (string?)panel.Attribute("Background"));
        var chat = System.Xml.Linq.XDocument.Parse(FileAt("Pages/ChatPage.xaml"));
        Assert.Equal("{ThemeResource HQPageBrush}", (string?)chat.Root!.Attribute("Background"));
        var view = FileAt("Controls/MessageView.cs");
        // ChatBubbleRows.Tests checks actual incoming fill, stroke and thickness across looks.
        Assert.Contains("Background = Res<Brush>(\"HQMeBubbleBrush\")", view);
        foreach (var path in new[] { "ViewModels/ChatViewModel.cs", "Pages/GroupRoomPage.cs" })
            Assert.Contains("MessageRuns.At(messages, i, fewer, day != null)", FileAt(path));
    }

    [Theory]
    [InlineData(false, 43.5, 37, 36, 34, 19.5, 17)]
    [InlineData(true, 38, 32, 32, 28, 18, 15.5)]
    public void OpenRowsUseMacPitchFaceAndType(bool compact, double bot, double place, double chat,
        double face, double name, double chatTitle)
    {
        // App/Mac/SidebarType.swift:60–66,79–82; MacBotsRail.swift:33–40,1028–1032;
        // MacSidebar.swift:148–151,202–205. Two app points between bots/places, none between chats.
        var s = DensitySizes.Sidebar(compact);
        Assert.Equal((bot + 2) * .77, s.BotRow, 6);
        Assert.Equal((place + 2) * .77, s.PlaceRow, 6);
        Assert.Equal(chat * .77, s.ChatRow, 6);
        Assert.Equal(face * .77, s.Face, 6);
        Assert.Equal(name * .77, s.Name, 6);
        Assert.Equal(chatTitle * .77, s.ChatTitle, 6);
    }
}
