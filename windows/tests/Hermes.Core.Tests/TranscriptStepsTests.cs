using System.Text.Json.Nodes;
using Hermes.Core.Chat;
using Hermes.Core.Model;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Tests;

/// The step wording and the reply layout, with the Swift tests' own vectors (Tests/ChatUITests.swift wording,
/// Tests/Chat/Transcript/TranscriptPortsTests.swift ToolWordsTests, TranscriptWiringTests, TranscriptFinishTests,
/// Tests/Activity/OneLineRowsTests.swift).
public class RunSummaryTests
{
    private static ToolCall Call(string name, string args, ToolState state = ToolState.Done, string id = "x", double? seconds = null) =>
        new(id, name, null, null, state, seconds, ArgsJson: args);

    [Fact]
    public void Wording()
    {
        Assert.Equal("Ran 1 command", RunSummary.Summarize([Call("terminal", """{"command":"npm run typecheck"}""")], false));
        Assert.Equal("Running npm run typecheck", RunSummary.Summarize(
            [Call("terminal", """{"command":"cd app && npm run typecheck 2>&1 | tail -20"}""", ToolState.Running)], true));
        Assert.Equal("Explored 3 files", RunSummary.Summarize(
            [Call("read_file", """{"path":"a"}"""), Call("read_file", """{"path":"b"}"""), Call("list_files", "{}")], false));
        Assert.Equal("Searched “hermes agent”", RunSummary.Summarize([Call("web_search", """{"query":"hermes agent"}""")], false));
        Assert.Equal("Read example.com/docs", RunSummary.Summarize([Call("web_extract", """{"urls":["https://example.com/docs"]}""")], false));
        Assert.Equal("Read 3 pages", RunSummary.Summarize(
            [Call("web_extract", """{"urls":["https://a.com","https://b.com","https://c.com"]}""")], false));
        Assert.Equal("Performed 1 browser action, ran 1 command, 1 tool call failed", RunSummary.Summarize(
            [Call("browser_click", "{}"), Call("terminal", """{"command":"ls"}""", ToolState.Failed)], false));
        Assert.Equal("Loaded skill: pdf", RunSummary.Summarize([Call("skill_view", """{"name":"pdf"}""")], false));
    }

    [Fact]
    public void ConsecutiveCallsFoldAndEditsStandAlone()
    {
        Assert.Equal("Explored b.swift, ran 1 command", RunSummary.Summarize(
            [Call("read_file", """{"path":"a/b.swift"}"""), Call("terminal", """{"command":"ls"}""")], false));
        Assert.Equal("Edited y.ts", RunSummary.Summarize([Call("edit_file", """{"path":"x/y.ts"}""")], false));
    }

    [Fact]
    public void ClausesInTheOrderTheirFirstStepHappened()
    {
        // The Mac's screenshot (2026-11-14 full pass): "Checked how to use web search, explored big.txt, ran 1 command".
        var steps = new[]
        {
            Call("tool_describe", """{"names":["web_search"]}""", id: "1"),
            Call("read_file", """{"path":"/data/big.txt"}""", id: "2"),
            Call("terminal", """{"command":"cd /app\nexport CI=1\npython3 - <<'PY'\nimport json\nPY"}""", id: "3"),
        };
        Assert.Equal("Checked how to use web search, explored big.txt, ran 1 command", RunSummary.Summarize(steps, false));
    }

    [Fact]
    public void ShellCommandSummaries()
    {
        Assert.Equal("make test", RunSummary.SummarizeShellCommand("cd /x && make test"));
        Assert.Equal("npm test", RunSummary.SummarizeShellCommand("npm test 2>&1"));
        Assert.Equal("a + 2 commands", RunSummary.SummarizeShellCommand("a; b; c"));
        Assert.Equal("ls", RunSummary.SummarizeShellCommand("echo \"--- done\"; ls"));
        Assert.Equal("make + 1 command", RunSummary.SummarizeShellCommand("cd a && make && make install"));
    }

    [Fact]
    public void BigArgumentsAreScannedNotParsed()
    {
        var big = "{\"path\":\"src/generated/schema.json\",\"content\":\"" + new string('a', 200_000) + "\"}";
        Assert.Equal("Edited schema.json", RunSummary.Summarize([Call("write_file", big)], false));
        var urls = "{\"urls\":[\"https://a.com/x\",\"https://b.com\"],\"pad\":\"" + new string('z', 9_000) + "\"}";
        Assert.Equal("Read 2 pages", RunSummary.Summarize([Call("web_extract", urls)], false));
        var escaped = "{\"command\":\"cd /x && ls -la \\\"dir\\\"\",\"pad\":\"" + new string('z', 9_000) + "\"}";
        Assert.Equal("Running ls -la \"dir\"", RunSummary.Summarize([Call("terminal", escaped, ToolState.Running)], true));
    }

    [Fact]
    public void ToolRowsInPlainWords()
    {
        Assert.Equal("Checked how to use web search",
            RunSummary.Summarize([Call("tool_describe", """{"names":["web_search"]}""")], false));
        var live = RunSummary.Summarize([Call("terminal",
            "{\"command\":\"cd /app\\nexport CI=1\\npython3 - <<'PY'\\nimport json\\nprint(1)\\nPY\"}", ToolState.Running)], true);
        Assert.Contains("python3", live);
        Assert.DoesNotContain("export", live);
        Assert.DoesNotContain("import json", live);
        Assert.Equal("Used 1 tool, 1 tool call failed", RunSummary.Summarize([Call("mystery", "{}", ToolState.Failed)], false));
    }

    [Fact]
    public void Glyphs()
    {
        Assert.Equal(StepGlyph.Terminal, RunSummary.GlyphFor("Ran 1 command"));
        Assert.Equal(StepGlyph.Explore, RunSummary.GlyphFor("Exploring big.txt"));
        Assert.Equal(StepGlyph.File, RunSummary.GlyphFor("Edited y.ts"));
        Assert.Equal(StepGlyph.Other, RunSummary.GlyphFor("Checked how to use web search"));
    }
}

public class ToolWordsTests
{
    private static IReadOnlyDictionary<string, JsonNode?> Args(string json) => ToolArgs.Parse(json);

    [Fact]
    public void SizesInWords()
    {
        Assert.Equal("850 bytes output", ToolWords.ByteCountLabel(850));
        Assert.Equal("10 KB output", ToolWords.ByteCountLabel(10_240));
        Assert.Equal("1.2 MB output", ToolWords.ByteCountLabel(1_200_000));
        Assert.Equal("5 MB output", ToolWords.ByteCountLabel(5_000_000));
        Assert.Equal("10 KB error output", ToolWords.ByteCountLabel(10_240, "error output"));
        Assert.Equal("", ToolWords.ByteCountLabel(double.NaN));
    }

    [Fact]
    public void LookedUpAndBackgroundProcesses()
    {
        Assert.Equal("Checked how to use web search", ToolWords.PlainLabel("tool_describe", Args("""{"name":"web_search"}""")));
        Assert.Equal("Checked how to use 2 tools", ToolWords.PlainLabel("tool_describe", Args("""{"names":["a","b"]}""")));
        Assert.Equal("Checked how to use a tool", ToolWords.PlainLabel("tool_describe", Args("{}")));
        Assert.Equal("Checked how to use github list issues", ToolWords.PlainLabel("tool_describe", Args("""{"name":"mcp__github__list_issues"}""")));
        Assert.Equal("Checked a background process’s log", ToolWords.PlainLabel("process", Args("""{"action":"log"}""")));
        Assert.Equal("Started a background process", ToolWords.PlainLabel("process", Args("""{"action":"spawn"}""")));
        Assert.Equal("Stopped a background process", ToolWords.PlainLabel("process_manage", Args("{}"), "kill 1234"));
        Assert.Equal("Managed a background process", ToolWords.PlainLabel("process", Args("""{"action":"dance"}""")));
        Assert.Null(ToolWords.PlainLabel("terminal", Args("{}")));
    }

    [Fact]
    public void AFailedToolSaysItOnce()
    {
        Assert.Equal("Failed: Read notes.txt", ToolWords.FailedToolTitle("Read notes.txt"));
        Assert.Equal("Couldn’t read notes.txt", ToolWords.FailedToolTitle("Couldn’t read notes.txt"));
        Assert.Equal("Check the path.", ToolWords.ToolErrorBody("No such file", "- Error: No such file\n- Success: false\nCheck the path."));
        Assert.Equal("No such file", ToolWords.FailedProse("""{"status":"error","error":"No such file"}"""));
        Assert.Equal("This step didn’t finish.", ToolWords.FailedProse("status: error\nexit_code: 1\nsuccess: false"));
        Assert.Equal("No such file", ToolWords.FailedProse("status: error\nerror: No such file"));
        Assert.Equal("This step didn’t finish.", ToolWords.FailedProse(null));
        Assert.Equal("not json {", ToolWords.FailedProse("not json {"));
    }

    [Fact]
    public void OneLineShellOutput()
    {
        Assert.Equal("main", ToolWords.OneLineOutput("main\n"));
        Assert.Null(ToolWords.OneLineOutput("a\nb"));
        Assert.Null(ToolWords.OneLineOutput(new string('x', 121)));
        Assert.Null(ToolWords.OneLineOutput(""));
    }

    [Fact]
    public void ABigResultSaysItsSizeAndAShortLineStays()
    {
        Assert.Equal("12 KB output", ToolWords.RowNote("read_file", null, null, null, 12_000, false));
        Assert.Equal("done", ToolWords.RowNote("terminal", "done", null, null, 4, false));
        Assert.Null(ToolWords.RowNote("terminal", "a line that is much too long for the row", null, null, 41, false));
        Assert.Null(ToolWords.RowNote("read_file", null, null, null, 12_000, true));
        Assert.Null(ToolWords.RowNote("terminal", "{\"ok\": true}", null, null, 12, false));
        Assert.Null(ToolWords.RowNote("terminal", " [1, 2]", null, null, 6, false));
    }

    [Fact]
    public void HeredocScriptsAreNamedByTheirCommand()
    {
        Assert.Equal("python3 script", ToolWords.CollapseHeredocs("python3 - <<'PY'\nimport os\nprint(1)\nPY"));
        Assert.Equal("node script\necho done", ToolWords.CollapseHeredocs("FOO=1 /usr/bin/node <<EOF\nconsole.log(1)\nEOF\necho done"));
        Assert.Equal("cat > notes.txt", ToolWords.CollapseHeredocs("cat > notes.txt <<EOF\nhello\nEOF"));
        Assert.Equal("cat\nls", ToolWords.CollapseHeredocs("cat <<-EOF\n\thello\n\tEOF\nls"));
        Assert.Equal("echo 1 << 2", ToolWords.CollapseHeredocs("echo 1 << 2"));
        Assert.Equal("ls -la", ToolWords.CollapseHeredocs("ls -la"));
        Assert.True(ToolWords.SetupSegment(["SM=/path"]));
        Assert.True(ToolWords.SetupSegment(["#", "a", "comment"]));
        Assert.False(ToolWords.SetupSegment(["SM=/path", "ls"]));
        Assert.Equal("python3 script", ToolWords.ScriptTitleSource("SM=/tmp/x\npython3 - <<'PY'\nprint(1)\nPY"));
    }
}

public class StepWordsTests
{
    private static ToolCall Call(string name, string args, ToolState state = ToolState.Done, double? seconds = null) =>
        new("x", name, null, null, state, seconds, ArgsJson: args);

    [Fact]
    public void TheMacInspectorsStepRows()
    {
        // 03-inspector-steps-after.png: "Checked how to use web search", "Ran a command" over "cd /app", "Reading big.txt".
        Assert.Equal("Checked how to use web search", StepWords.Words(Call("tool_describe", """{"names":["web_search"]}""")));
        var shell = Call("terminal", """{"command":"cd /app\nls"}""");
        Assert.Equal("Ran a command", StepWords.Words(shell));
        Assert.Equal("cd /app", StepWords.CodePreview(ToolLines.Line(shell).Code!).Lines[0]);
        Assert.Equal("Running a command", StepWords.Words(shell with { State = ToolState.Running }));
        Assert.Equal("Reading big.txt", StepWords.Words(Call("read_file", """{"path":"/x/big.txt"}""", ToolState.Running)));
        Assert.Equal("Read big.txt", StepWords.Words(Call("read_file", """{"path":"/x/big.txt"}""")));
        Assert.Equal("Searched the web for cats", StepWords.Words(Call("web_search", """{"query":"cats"}""")));
        Assert.Equal("Ran code", ToolLines.Done("Running code"));
        Assert.Equal("Read skill pdf", ToolLines.Done("Reading skill pdf"));
    }

    [Fact]
    public void TheStepSheet()
    {
        var shell = Call("terminal", """{"command":"cd /app"}""") with { ResultText = "{\"ok\": true}", DurationSeconds = 4.2 };
        Assert.Equal("Terminal", StepWords.SheetTitle(shell));
        var sections = StepWords.Sections(shell);
        Assert.Equal(["Command", "Output", "Duration"], sections.Select(s => s.Name));
        Assert.Equal("4.2s", sections[2].Text);
        Assert.Equal("Edited y.ts", StepWords.SheetTitle(Call("patch", """{"path":"x/y.ts"}""")));
        Assert.Equal("x/y.ts", StepWords.Subtitle(Call("patch", """{"path":"x/y.ts"}""")));
        Assert.Equal(["Tools"], StepWords.Sections(Call("tool_describe", """{"names":["web_search","mcp__github__list_issues"]}"""))
            .Where(s => s.Mono).Select(s => s.Name));
        Assert.Equal("web search\ngithub list issues", StepWords.DescribedTools(Call("tool_describe", """{"names":["web_search","mcp__github__list_issues"]}""")));
        Assert.Equal("No details for this step.", StepWords.Sections(Call("patch", "{}")).Single().Text);
        Assert.Equal("+2 more lines", StepWords.MoreLines(2));
        Assert.Equal("+1 more line", StepWords.MoreLines(1));
    }

    [Theory]
    [InlineData(0.004, "4ms")]
    [InlineData(4.2, "4.2s")]
    [InlineData(42, "42s")]
    [InlineData(125, "2m 5s")]
    [InlineData(120, "2m")]
    [InlineData(3780, "1h 3m")]
    public void Durations(double seconds, string words) => Assert.Equal(words, StepWords.FormatDuration(seconds));

    [Fact]
    public void Thoughts()
    {
        Assert.Equal("Thinking", StepWords.ThoughtTitle(3, true));
        Assert.Equal("Thought for 7s", StepWords.ThoughtTitle(7.4, false));
        Assert.Equal("Thought for 1:05", StepWords.ThoughtTitle(65, false));
        Assert.Equal("Thought briefly", StepWords.ThoughtTitle(0.4, false));
        Assert.Equal("Thought", StepWords.ThoughtTitle(null, false));
    }
}

public class ReplyLayoutTests
{
    private static ToolCall Call(string id, string name, string args = "{}", ToolState state = ToolState.Done, double? seconds = null) =>
        new(id, name, null, null, state, seconds, ArgsJson: args);

    private static ChatMessage Reply(params ChatPart[] parts) => new("a", Role.Assistant, parts, DateTimeOffset.Now, 2);

    /// Text, steps, more text: a reply the way Hermes sends a busy one.
    private static readonly ChatPart[] Split =
    [
        new ReasoningPart("plan"), new TextPart("Checking."),
        new ToolPart(Call("t1", "terminal", """{"command":"npm test"}""", seconds: 40.6)),
        new ToolPart(Call("t2", "read_file", """{"path":"/a/README.md"}""", seconds: 1.2)), new TextPart("All good."),
    ];

    [Fact]
    public void OneLineFoldsAReplyIntoOneLineAboveItsWords()
    {
        var rows = ReplyLayout.Build(Reply(Split), new ReplyContext { Style = ToolCallStyle.Line });
        var line = Assert.IsType<StepsRow>(rows[0]);
        Assert.True(line.IsLine);
        Assert.Equal("Worked for 42s · 2 steps", line.Title);
        Assert.Equal(StepGlyph.Worked, line.Glyph);
        Assert.Equal("plan\n\nChecking.", line.Thought);
        Assert.Equal(["t1", "t2"], line.Steps.Select(s => s.Id));
        Assert.False(line.Live);
        Assert.Equal(["All good."], rows.OfType<WordsRow>().Select(w => w.Text));
        Assert.Empty(rows.OfType<ThoughtRow>());
    }

    [Fact]
    public void UntimedStepsSayWhatTheReplyDid()
    {
        var rows = ReplyLayout.Build(Reply(new ToolPart(Call("t1", "terminal", """{"command":"npm test"}""")), new TextPart("ok")),
            new ReplyContext { Style = ToolCallStyle.Line });
        Assert.Equal("Ran 1 command", Assert.IsType<StepsRow>(rows[0]).Title);
    }

    [Fact]
    public void TheMacsDefaultLine()
    {
        // At the Bottom, done, no time known: the summary is the title, the count apart (03-inspector-steps-after.png).
        var reply = Reply(
            new ToolPart(Call("1", "tool_describe", """{"names":["web_search"]}""")), new TextPart("I looked up how to search first."),
            new ToolPart(Call("2", "read_file", """{"path":"big.txt"}""")), new TextPart("The script ran."),
            new ToolPart(Call("3", "terminal", """{"command":"cd /app"}""")), new TextPart("I read the big file."));
        var rows = ReplyLayout.Build(reply, new ReplyContext());
        var line = Assert.IsType<StepsRow>(rows[0]);
        Assert.Equal("Checked how to use web search, explored big.txt, ran 1 command", line.Title);
        Assert.Equal("3 steps", line.Meta);
        Assert.Equal("3 steps", line.Short);
        // The two short notes before later steps join the line; only the last words stay.
        Assert.Equal(["I read the big file."], rows.OfType<WordsRow>().Select(w => w.Text));
        Assert.Equal("I looked up how to search first.\n\nThe script ran.", line.Thought);
    }

    [Fact]
    public void AtTheBottomHoldsTheLineWhileTheTurnRuns()
    {
        var running = Reply(new ToolPart(Call("1", "terminal", """{"command":"npm test"}""", ToolState.Running))) with { IsStreaming = true };
        var rows = ReplyLayout.Build(running, new ReplyContext { RunningTail = true, Working = true });
        Assert.Empty(rows.OfType<StepsRow>());
        var line = ReplyLayout.Build(running, new ReplyContext { Style = ToolCallStyle.Line, Working = true }).OfType<StepsRow>().Single();
        Assert.Equal("Running npm test", line.Title);
        Assert.True(line.Live);
    }

    [Fact]
    public void RowsStyleDrawsEachRunAndThought()
    {
        var rows = ReplyLayout.Build(Reply(Split), new ReplyContext { Style = ToolCallStyle.Rows, ReasoningSeconds = new Dictionary<int, double> { [0] = 7 } });
        Assert.Equal("Thought for 7s", Assert.IsType<ThoughtRow>(rows[0]).Title);
        Assert.Equal("Checking.", Assert.IsType<WordsRow>(rows[1]).Text);
        Assert.Equal("Ran 1 command, explored README.md", Assert.IsType<StepsRow>(rows[2]).Title);
        Assert.Equal("All good.", Assert.IsType<WordsRow>(rows[3]).Text);
    }

    [Fact]
    public void BubblesAndInHeader()
    {
        var bubbles = ReplyLayout.Build(Reply(Split), new ReplyContext { Style = ToolCallStyle.Bubbles });
        var bubble = bubbles.OfType<ToolBubbleRow>().Single();
        Assert.Equal("💻", bubble.Lines[0].Emoji);
        Assert.Equal("npm test", bubble.Lines[0].Code);
        Assert.Equal("Reading README.md", bubble.Lines[1].Text);
        var header = ReplyLayout.Build(Reply(Split), new ReplyContext { Style = ToolCallStyle.Header });
        Assert.Empty(header.OfType<StepsRow>());
        Assert.Empty(header.OfType<ThoughtRow>());
        Assert.Equal(["Checking.", "All good."], header.OfType<WordsRow>().Select(w => w.Text));
    }

    [Fact]
    public void HideAfterReplyAndShowSteps()
    {
        var hidden = ReplyLayout.Build(Reply(Split), new ReplyContext { Style = ToolCallStyle.Rows, HideSteps = true });
        Assert.Empty(hidden.OfType<StepsRow>());
        var shown = ReplyLayout.Build(Reply(Split), new ReplyContext { Style = ToolCallStyle.Rows, HideSteps = true, Revealed = true });
        Assert.Single(shown.OfType<StepsRow>());
        // A failure no words account for keeps its steps.
        var failed = Reply(new TextPart("Trying."), new ToolPart(Call("1", "terminal", """{"command":"x"}""", ToolState.Failed)));
        Assert.Single(ReplyLayout.Build(failed, new ReplyContext { Style = ToolCallStyle.Rows, HideSteps = true }).OfType<StepsRow>());
    }

    [Fact]
    public void SilentToolsDrawNothingAndWordsJoin()
    {
        var rows = ReplyLayout.Build(Reply(new TextPart("One."), new ToolPart(Call("1", "todo")), new TextPart("Two.")),
            new ReplyContext { Style = ToolCallStyle.Rows });
        Assert.Equal("One.\n\nTwo.", Assert.IsType<WordsRow>(Assert.Single(rows)).Text);
    }

    [Fact]
    public void ErrorsAndStops()
    {
        var failed = Reply(new TextPart("Half")) with { Error = "boom" };
        Assert.Equal(new ErrorRow("boom", true), ReplyLayout.Build(failed, new ReplyContext { CanRetry = true })[^1]);
        var stopped = Reply(new TextPart("Half")) with { Interrupted = true };
        Assert.Equal(new CaptionRow("Stopped"), ReplyLayout.Build(stopped, new ReplyContext())[^1]);
        var early = Reply() with { Interrupted = true };
        Assert.Equal(new StoppedEarlyRow("Stopped before Ivy replied", false), ReplyLayout.Build(early, new ReplyContext { BotName = "Ivy" })[^1]);
    }

    [Fact]
    public void AStoredTurnFromTheFixture()
    {
        var messages = HistoryFold.Fold(Fixture.Load("chat/plaid-page-after-turn.json")["messages"]!.AsArray());
        var reply = messages.Last(m => m.Role == Role.Assistant);
        var line = ReplyLayout.Build(reply, new ReplyContext()).OfType<StepsRow>().First();
        Assert.True(line.IsLine);
        Assert.Equal(reply.Tools.Count(t => !RunSummary.Hidden(t)), line.Steps.Count);
        Assert.False(string.IsNullOrEmpty(line.Title));
        // Every stored call keeps its whole arguments for the wording.
        Assert.All(reply.Tools, t => Assert.NotNull(t.ArgsJson));
    }

    [Fact]
    public void DayLineWords()
    {
        var now = new DateTimeOffset(2026, 11, 21, 15, 0, 0, TimeSpan.Zero).ToLocalTime();
        Assert.StartsWith("Today ", DayLines.Label(now.AddHours(-1), now));
        Assert.StartsWith("Yesterday ", DayLines.Label(now.AddDays(-1), now));
        Assert.True(DayLines.NeedsBreak(null, now, true));
        Assert.False(DayLines.NeedsBreak(now.AddMinutes(-40), now, datesOnly: true));
        Assert.True(DayLines.NeedsBreak(now.AddMinutes(-40), now, datesOnly: false));
    }
}

public class ReactionsAndMenuTests
{
    [Fact]
    public void Tapbacks()
    {
        var list = MessageReactions.Decode(JsonNode.Parse("""[{"emoji":"❤️","author":"user","at":1},{"emoji":"👍","author":"agent"},{"emoji":"❤️","author":"user","at":2},{"bad":1}]"""));
        Assert.Equal(2, list.Count);
        Assert.Equal("❤️", list[0].Emoji);
        Assert.Equal(2, list[0].At);
        Assert.Equal("Reactions: Heart from you, Thumbs Up from Ivy", MessageReactions.Spoken(list, "Ivy"));
        Assert.Empty(MessageReactions.Applying(list.Where(r => r.IsMine).ToList(), "❤️"));
        Assert.Equal("😂", MessageReactions.Applying(list, "😂").Last().Emoji);
        var chips = MessageReactions.Chips([new("👍", "user"), new("👍", "agent")]);
        Assert.Equal("👍 2", Assert.Single(chips).Text);
        Assert.True(chips[0].Mine);
        var row = (JsonObject)JsonNode.Parse("""{"display_metadata":"{\"reactions\":[{\"emoji\":\"👍\",\"author\":\"agent\"}]}"}""")!;
        Assert.Equal("👍", MessageReactions.FromRow(row).Single().Emoji);
    }

    [Fact]
    public void TheMessageMenu()
    {
        Assert.Equal(["Copy", "Share…"], MessageMenu.Tiles(true, new()).Select(r => r.Title));
        Assert.Equal(["Select Text", "Regenerate", "Branch in New Chat", "Hide Steps"],
            MessageMenu.Rows(true, new(Latest: true, ShowSteps: false)).Select(r => r.Title));
        var streaming = MessageMenu.Rows(true, new(Streaming: true, Latest: true));
        Assert.False(streaming[0].Disabled);
        Assert.Equal(MessageMenu.StillReplying, streaming[1].Subtitle);
        Assert.Equal(["Copy"], MessageMenu.Tiles(false, new()).Select(r => r.Title));
        Assert.Equal("Ivy · 9:14 AM", MessageMenu.Title("Ivy", "m", "m", "9:14 AM"));
    }
}
