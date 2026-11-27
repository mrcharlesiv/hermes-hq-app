using Hermes.Core.Model;
using Hermes.Core.Shell;
using Hermes.Core.Transcripts;
using Xunit;

namespace Hermes.Core.Tests;

/// Find in a chat (HermesKit/Chat/ChatFind.swift and App/Chat/Find/ChatFindController.swift at 93f984bb1): which
/// rows are searched, case- and diacritic-folding, the count's words, ordering, wrap-around, keeping the current match
/// as messages change, and the Find keys on the Keyboard Shortcuts sheet. Synthetic messages only.
public class ChatFindTests
{
    private static ChatMessage User(string id, string text) => new(id, Role.User, [new TextPart(text)]);
    private static ChatMessage Bot(string id, params ChatPart[] parts) => new(id, Role.Assistant, parts);
    private static ChatMessage Note(string id, string text) => new(id, Role.System, [new TextPart(text)]);
    private static ToolPart Tool(string name, string summary) => new(new ToolCall("t-" + name, name, "{\"q\":\"otter\"}", summary, ToolState.Done));

    [Fact]
    public void SearchesYourWordsAndTheBotsProseNotToolStepsNotesOrThinking()
    {
        var messages = new List<ChatMessage>
        {
            User("u1", "Find the otter please"),
            Bot("a1", new ReasoningPart("an otter in my thoughts"), Tool("web_search", "otter search"), new TextPart("An otter swims."),
                new TextPart("<think>otter otter</think>\nThe OTTER sleeps.")),
            Note("s1", "Model changed to otter-1"),
            Bot("a2", new TextPart("<think>only otter thinking</think>")),
        };
        var units = ChatFind.Units(messages);
        Assert.Equal(["u1|b0", "a1|b2", "a1|b3"], units.Select(u => u.RowId));
        Assert.Equal("The OTTER sleeps.", units[2].Text);
        var matches = ChatFind.Matches("otter", messages);
        Assert.Equal([("u1|b0", 0), ("a1|b2", 0), ("a1|b3", 0)], matches.Select(m => (m.RowId, m.Occurrence)));
    }

    [Fact]
    public void ABlankUserMessageAndAVoiceMemosOwnBubbleAreNotSearched()
    {
        var memo = User("u2", "MEDIA:\"/home/me/voice-memo.m4a\"\n\nVoice memo transcript: an otter said hi\n\nand an otter typed");
        var units = ChatFind.Units([User("u1", "   \n"), memo]);
        Assert.Equal(["u2|b1"], units.Select(u => u.RowId));
        Assert.Equal("and an otter typed", units[0].Text);
        Assert.Empty(ChatFind.Units([User("u3", "MEDIA:\"/home/me/voice-memo.m4a\"\n\nVoice memo transcript: otter")]));
    }

    [Fact]
    public void AReplyIsSearchedAsItsBubbleDrawsIt()
    {
        Assert.Equal("Read the guide now", ChatFind.DrawnText("Read **the** [guide](https://example.com/otter) `now`"));
        Assert.Equal("• one\n• two\nTitle\nquoted", ChatFind.DrawnText("- one\n* two\n## Title\n> quoted"));
        Assert.Equal("code stays **as is**", ChatFind.DrawnText("```\ncode stays **as is**\n```"));
        Assert.Equal("Here it is:", ChatFind.DrawnText("Here it is:\nMEDIA:/home/me/otter.png"));
        Assert.Empty(ChatFind.Ranges("example", ChatFind.DrawnText("[guide](https://example.com)")));
    }

    [Fact]
    public void MatchesIgnoreCaseAndAccentsAndNeverOverlap()
    {
        Assert.Equal(2, ChatFind.Ranges("cafe", "Café and CAFE").Count);
        Assert.Equal(2, ChatFind.Ranges("CAFÉ", "cafe, café").Count);
        Assert.Equal([(0, 2), (2, 2)], ChatFind.Ranges("aa", "aaaaa").Select(r => (r.Start, r.Length)));
        Assert.Equal([(4, 5)], ChatFind.Ranges("  otter ", "the otter").Select(r => (r.Start, r.Length)));
        Assert.Empty(ChatFind.Ranges("   ", "anything"));
        Assert.Empty(ChatFind.Ranges("x", ""));
        Assert.Equal("otter", ChatFind.Normalized("  otter\n"));
    }

    [Fact]
    public void MatchesRunOldestFirstAndEachOccurrenceIsCounted()
    {
        var messages = new List<ChatMessage> { User("u1", "otter otter"), Bot("a1", new TextPart("one otter")) };
        Assert.Equal([("u1|b0", 0), ("u1|b0", 1), ("a1|b0", 0)], ChatFind.Matches("Otter", messages).Select(m => (m.RowId, m.Occurrence)));
        Assert.Empty(ChatFind.Matches(" ", messages));
    }

    [Fact]
    public void TheCountReadsAsTheMacs()
    {
        Assert.Equal("", ChatFind.CountText(null, 0, ""));
        Assert.Equal("", ChatFind.CountText(null, 3, "  "));
        Assert.Equal("No Results", ChatFind.CountText(null, 0, "otter"));
        Assert.Equal("No Results Yet", ChatFind.CountText(null, 0, "otter", hasOlder: true));
        Assert.Equal("2 of 5", ChatFind.CountText(1, 5, "otter"));
        Assert.Equal("1 of 5", ChatFind.CountText(null, 5, "otter", hasOlder: true));
    }

    [Fact]
    public void SteppingWrapsAroundBothWays()
    {
        Assert.Null(ChatFind.Step(null, 0, forward: true));
        Assert.Equal(0, ChatFind.Step(null, 3, forward: true));
        Assert.Equal(2, ChatFind.Step(null, 3, forward: false));
        Assert.Equal(0, ChatFind.Step(2, 3, forward: true));
        Assert.Equal(2, ChatFind.Step(0, 3, forward: false));
        Assert.Equal(1, ChatFind.Step(0, 3, forward: true));
    }

    [Fact]
    public void TheCurrentMatchStaysWhenStillThereElseTheNewest()
    {
        var a = new ChatFindMatch("u1|b0", "u1", 0);
        var b = new ChatFindMatch("a1|b0", "a1", 0);
        var c = new ChatFindMatch("a2|b0", "a2", 0);
        Assert.Null(ChatFind.KeepCurrent(a, []));
        Assert.Equal(0, ChatFind.KeepCurrent(a, [a, b, c]));
        Assert.Equal(2, ChatFind.KeepCurrent(new ChatFindMatch("gone|b0", "gone", 0), [a, b, c]));
        Assert.Equal(2, ChatFind.KeepCurrent(null, [a, b, c]));
    }

    [Fact]
    public void AMatchInALaterPartIsDrawnInTheBubbleItJoined()
    {
        var messages = new List<ChatMessage> { Bot("a1", new TextPart("otter one"), new TextPart("otter two otter")) };
        var units = ChatFind.Units(messages);
        var later = new ChatFindMatch("a1|b1", "a1", 1);
        Assert.Equal(("a1|b0", 2), ChatFind.DrawnPlace(later, [0], units, "otter"));
        Assert.Equal(("a1|b1", 1), ChatFind.DrawnPlace(later, [0, 1], units, "otter"));
        Assert.Equal(("a1|b1", 1), ChatFind.DrawnPlace(later, null, units, "otter"));
    }

    /// Windows draws one view per message: the occurrence to paint current, counted across the message's units.
    [Fact]
    public void TheCurrentOccurrenceIsCountedAcrossItsMessage()
    {
        var messages = new List<ChatMessage> { Bot("a1", new TextPart("otter one otter"), new ToolPart(new ToolCall("t", "terminal", null, "otter", ToolState.Done)), new TextPart("otter two")) };
        var units = ChatFind.Units(messages);
        Assert.Equal(2, ChatFind.MessageOccurrence(new ChatFindMatch("a1|b2", "a1", 0), units, "otter"));
        Assert.Equal(1, ChatFind.MessageOccurrence(new ChatFindMatch("a1|b0", "a1", 1), units, "otter"));
    }

    [Fact]
    public void TheModelFollowsTypingStepsAndNewMessages()
    {
        var find = new ChatFindModel();
        var messages = new List<ChatMessage> { User("u1", "otter"), Bot("a1", new TextPart("an otter and an otter")) };
        find.Open();
        Assert.True(find.IsActive);
        Assert.Equal("", find.CountText);
        find.Search("otter", messages, keepCurrent: false);
        Assert.Equal("3 of 3", find.CountText);   // the newest: nearest where the reader is
        Assert.True(find.CanStep);
        find.Step(forward: true);
        Assert.Equal("1 of 3", find.CountText);   // wraps to the oldest
        find.Step(forward: false);
        find.Step(forward: false);
        Assert.Equal("2 of 3", find.CountText);
        // A new message while open: the current match stays.
        messages.Add(Bot("a2", new TextPart("otter again")));
        find.Search(find.Query, messages, keepCurrent: true);
        Assert.Equal("2 of 4", find.CountText);
        // Typing a new query starts at the newest match.
        find.Search("again", messages, keepCurrent: false);
        Assert.Equal("1 of 1", find.CountText);
        find.Search("zebra", messages, keepCurrent: false);
        Assert.Equal("No Results", find.CountText);
        Assert.False(find.CanStep);
        find.Search("zebra", messages, keepCurrent: false, hasOlder: true);
        Assert.Equal("No Results Yet", find.CountText);
        find.Close();
        Assert.False(find.IsActive);
        Assert.Equal("", find.Query);
        Assert.Empty(find.Matches);
        Assert.Null(find.Current);
        Assert.Equal("", find.CountText);
    }

    [Fact]
    public void TheHighlightNamesTheCurrentOccurrenceOnlyInItsMessage()
    {
        var find = new ChatFindModel();
        var messages = new List<ChatMessage> { User("u1", "otter"), Bot("a1", new TextPart("otter otter")) };
        Assert.Null(find.Highlight("u1"));   // closed
        find.Open();
        find.Search("otter", messages, keepCurrent: false);
        Assert.Equal(new ChatFindHighlight("otter", 1), find.Highlight("a1"));
        Assert.Equal(new ChatFindHighlight("otter", null), find.Highlight("u1"));
        find.Search("zebra", messages, keepCurrent: false);
        Assert.Null(find.Highlight("a1"));
    }

    [Fact]
    public void TheBarsWordsAreTheMacs()
    {
        Assert.Equal("Find in Chat", ChatFindWords.Placeholder);
        Assert.Equal("Previous Match", ChatFindWords.Previous);
        Assert.Equal("Next Match", ChatFindWords.Next);
        Assert.Equal("Done", ChatFindWords.Done);
        Assert.Equal("Search Earlier Messages", ChatFindWords.Earlier);
        Assert.Equal("Loading Earlier Messages…", ChatFindWords.EarlierLoading);
    }

    [Fact]
    public void FindNextAndPreviousAreOnTheShortcutsSheetWithTheirWindowsKeys()
    {
        var edit = KeyShortcuts.Sections(["Otto"], terminal: false).Single(s => s.Title == "Edit").Rows;
        Assert.Equal(["Find…", "Find Next", "Find Previous", "Open Quickly…", "Favorites…"], edit.Select(r => r.Title));
        Assert.Equal(["Ctrl+F", "Ctrl+G   F3", "Ctrl+Shift+G   Shift+F3", "Ctrl+K", "Ctrl+Shift+K"], edit.Select(r => r.KeysText));
        Assert.Equal("Find Previous, Control Shift G, or Shift F3", edit[2].AccessibleName);
        Assert.DoesNotContain(KeyShortcuts.Gaps, g => g.Title.StartsWith("Find"));
    }
    /// The bar is wired in: registered once, with its UIA ids and Narrator names, and every message view reports its
    /// searched words and redraws to Find.
    [Fact]
    public void TheBarIsRegisteredWithItsAutomationIdsAndNames()
    {
        var app = Path.Combine(RepoRoot(), "windows", "src", "HermesHQ.Windows");
        Assert.Contains("HermesHQ.Features.ChatFind.ChatFindFeature.Register();", File.ReadAllText(Path.Combine(app, "Shell", "FeatureRegistry.cs")));
        var bar = File.ReadAllText(Path.Combine(app, "Features", "ChatFind", "ChatFindFeature.cs"));
        foreach (var id in new[] { "chatfind.bar", "chatfind.field", "chatfind.count", "chatfind.previous", "chatfind.next", "chatfind.done", "chatfind.earlier" })
            Assert.Contains($"\"{id}\"", bar);
        foreach (var named in new[] { "AutomationProperties.SetName(_field, ChatFindWords.Placeholder);",
                     "Arrow(_previous, \"\\uE70E\", ChatFindWords.Previous, \"chatfind.previous\"",
                     "Arrow(_next, \"\\uE70D\", ChatFindWords.Next, \"chatfind.next\"",
                     "AutomationProperties.SetName(_done, ChatFindWords.Done);", "AutomationProperties.SetName(_earlier, ChatFindWords.Earlier);" })
            Assert.Contains(named, bar);
        Assert.Contains("AutomationProperties.SetName(b, name);", bar);
        Assert.Contains("AutomationProperties.SetLiveSetting(_count, AutomationLiveSetting.Polite);", bar);
        var view = File.ReadAllText(Path.Combine(app, "Controls", "MessageView.cs"));
        Assert.Contains("Drawn?.Invoke(this);", view);
        Assert.Contains("_findable.Add(body);", view);
        Assert.Contains("if (words != null) findable.Add(words);", view);
    }

    [Fact]
    public void TheLeadingMagnifierDecoratesTheNativeEditWithoutTakingInput()
    {
        var dir = Path.Combine(RepoRoot(), "windows", "src", "HermesHQ.Windows", "Features", "ChatFind");
        var rows = File.ReadAllText(Path.Combine(dir, "ChatFindRows.cs"));
        var mark = System.Text.RegularExpressions.Regex.Match(rows, @"FontIcon _magnifier = new\(\)\s*\{([^}]+)\}");
        Assert.True(mark.Success, "Find has no leading FontIcon");
        foreach (var property in new[] { "Glyph = \"\\uE721\"", "Margin = new Thickness(8, 0, 6, 0)",
                     "IsHitTestVisible = false", "IsTabStop = false", "IsTextScaleFactorEnabled = true" })
            Assert.Contains(property, mark.Groups[1].Value);
        Assert.Contains("SetAccessibilityView(_magnifier, AccessibilityView.Raw)", rows);
        Assert.Matches(@"_rows\.Children\.Add\(field\);\s*_rows\.Children\.Add\(_magnifier\);", rows);
        Assert.Contains("nameof(TextBox.Foreground)", rows);
        Assert.Contains("Math.Round(_field.FontSize * 0.82, MidpointRounding.AwayFromZero)", rows);

        var feature = File.ReadAllText(Path.Combine(dir, "ChatFindFeature.cs"));
        Assert.Contains("readonly TextBox _field = new()", feature);
        Assert.Contains("_field.Focus(FocusState.Keyboard)", feature);
        Assert.Contains("_field.SelectAll()", feature);
        // Reflow moves grid cells, never the edit, its selection or keyboard focus.
        var layout = rows[rows.IndexOf("private void Place(", StringComparison.Ordinal)..];
        foreach (var element in new[] { "_field", "_magnifier" })
            Assert.Contains($"Grid.SetColumnSpan({element}, stacked ? 2 : 1)", layout);
        foreach (var mutation in new[] { ".Children.", ".Focus(", ".Select(", ".SelectAll(", ".Text =" })
            Assert.DoesNotContain(mutation, layout);
    }

    [Fact]
    public void TheRowDecisionExcludesBothTheMeasuredIconInsetAndTheNativeClearAction()
    {
        var rows = File.ReadAllText(Path.Combine(RepoRoot(), "windows", "src", "HermesHQ.Windows", "Features", "ChatFind", "ChatFindRows.cs"));
        Assert.Matches(@"_magnifier\.Measure\(free\);\s*var leading = _magnifier\.DesiredSize\.Width;", rows);
        Assert.Contains("_field.Padding = new Thickness(leading, padding.Top, padding.Right, padding.Bottom)", rows);
        Assert.Contains("const double ClearButtonWidth = 30;", rows); // the pinned WinUI DeleteButton when visible
        Assert.Contains("availableSize.Width - leading - padding.Right - ClearButtonWidth", rows);
        Assert.Matches(@"ChatFindLayout\.Stacked\(usable,\s*_reserve\.DesiredSize\.Width,\s*_naturalCount\.DesiredSize\.Width,", rows);
        Assert.Matches(@"_count\.Text = _naturalCount\.Text = text;\s*InvalidateMeasure\(\);", rows);
    }

    /// The words are the Swift app's (full checkout only; the Windows-only CI mirror has no Swift).
    [Fact]
    public void TheWordsAreTheSwiftStrings()
    {
        var root = RepoRoot();
        var controller = Path.Combine(root, "App", "Chat", "Find", "ChatFindController.swift");
        var kit = Path.Combine(root, "HermesKit", "Chat", "ChatFind.swift");
        if (!Directory.Exists(Path.Combine(root, "App"))) return;
        var swift = File.ReadAllText(controller) + File.ReadAllText(kit);
        foreach (var words in new[] { ChatFindWords.Placeholder, ChatFindWords.Previous, ChatFindWords.Next, ChatFindWords.Done,
                     ChatFindWords.Earlier, ChatFindWords.EarlierLoading, "No Results Yet", "No Results", " of " })
            Assert.Contains($"{words}", swift);
    }

    private static string RepoRoot()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir != null; dir = dir.Parent)
            if (File.Exists(Path.Combine(dir.FullName, "windows", "HermesHQ.sln")))
                return dir.FullName;
        throw new InvalidOperationException("repo root not found");
    }
}
