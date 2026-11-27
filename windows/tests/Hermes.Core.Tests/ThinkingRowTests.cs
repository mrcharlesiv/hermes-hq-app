// [WIN-THINKING-STEP] The chat's thinking row names the step that runs ("Ivy is running npm test…"), at the
// transcript's newest end. Ported case for case from the Mac at 93f984bb1: Tests/Chat/ToolNowTests.swift
// `thinkingRowFollowsTheStep` and Tests/ChatUITests.swift `waitWords` (the row's words and its timer). The rest state
// App/Chat/ChatRow.swift `ToolNowRows` and `waitingRow` (when the row is drawn; its long words, `doing`, `opensSteps`;
// a message to another bot named as the roster does) and App/Chat/Activity/ActivityRows.swift `suppressesWaiting`.
// Demo bots and synthetic data only.

using System.Text.Json.Nodes;
using Hermes.Core.Groups;
using Hermes.Core.Model;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Tests;

public class ThinkingRowTests
{
    private static ToolCall Call(string name, string args, ToolState state = ToolState.Running) =>
        new($"c-{name}", name, args, null, state);

    private static readonly DateTimeOffset At = DateTimeOffset.FromUnixTimeSeconds(1_790_000_000);

    private static ThinkingRow.Input Rows(IReadOnlyList<ChatPart> parts, ToolCallStyle style = ToolCallStyle.Bottom,
        bool waitsOnUser = false, IReadOnlyList<DeliveryMessages.Seat>? roster = null, bool running = true)
    {
        var you = new ChatMessage("u", Role.User, [new TextPart("go")], At, RowId: 1);
        var reply = new ChatMessage("a", Role.Assistant, parts, At.AddSeconds(1), RowId: 2, IsStreaming: true);
        return new ThinkingRow.Input([you, reply], running, "Ivy")
        {
            Style = style, WaitsOnUser = waitsOnUser, Roster = roster ?? [],
        };
    }

    private static string? Label(ThinkingRow.Input input) => ThinkingRow.Build(input)?.Label;

    private const string NpmTest = """{"command": "npm test"}""";

    // MARK: ToolNowTests.swift

    [Fact]
    public void ThinkingRowFollowsTheStep()
    {
        var running = Rows([new ToolPart(Call("terminal", NpmTest))]);
        Assert.Equal("Ivy is running npm test…", Label(running));
        // A finished step stays named through the thinking after it.
        var between = Rows([new ToolPart(Call("terminal", NpmTest, ToolState.Done))]);
        Assert.Equal("Ivy is running npm test…", Label(between));
        var thinkingAfter = Rows([new ToolPart(Call("terminal", NpmTest, ToolState.Done)), new ReasoningPart("Now the docs.")]);
        Assert.Equal("Ivy is running npm test…", Label(thinkingAfter));
        var next = Rows([new ToolPart(Call("terminal", NpmTest, ToolState.Done)),
                         new ToolPart(Call("read_file", """{"path": "/a/README.md"}"""))]);
        Assert.Equal("Ivy is reading README.md…", Label(next));
        Assert.Equal("Ivy is thinking…", Label(Rows([new ReasoningPart("Let me look.")])));   // before the first step
        var writing = Rows([new ToolPart(Call("terminal", NpmTest, ToolState.Done)), new TextPart("All green.")]);
        Assert.Null(Label(writing));
    }

    // MARK: ChatUITests.swift waitWords

    [Fact]
    public void WaitWords()
    {
        Assert.Equal("Ivy is thinking…", ThinkingRow.Words("Ivy is thinking…", elapsed: 4));
        Assert.Equal("Ivy is thinking… · 0:12", ThinkingRow.Words("Ivy is thinking…", elapsed: 12));
        // Past a minute it says the bot is still at it, with the clock, never "No reply yet" (owner, 2026-10-29).
        Assert.Equal("Ivy is still thinking… · 1:15", ThinkingRow.Words("Ivy is thinking…", "Ivy is still thinking…", 75));
        Assert.Equal("Ivy is still working… · 1:15", ThinkingRow.Words("Ivy is reading a.md…", "Ivy is still working…", 75));
        Assert.Equal("Ivy is running npm test… · 1:15",
            ThinkingRow.Words("Ivy is running npm test…", "Ivy is still working…", 75, doing: true));
        Assert.Equal("Retrying in 8s… · 1:15", ThinkingRow.Words("Retrying in 8s…", elapsed: 75));
        // The desktop's timer beside the words (`formatElapsed`).
        Assert.Equal("", ThinkingRow.Elapsed(0));
        Assert.Equal("", ThinkingRow.Elapsed(9));
        Assert.Equal("· 0:12", ThinkingRow.Elapsed(12));
        Assert.Equal("· 1:05", ThinkingRow.Elapsed(65));
    }

    // MARK: ChatRow.swift waitingRow / ToolNowRows

    [Fact]
    public void BeforeTheReplyStartsTheBotIsThinking()
    {
        var you = new ChatMessage("u", Role.User, [new TextPart("go")], At, RowId: 1);
        var row = ThinkingRow.Build(new ThinkingRow.Input([you], true, "Ivy"));
        Assert.NotNull(row);
        Assert.Equal("Ivy is thinking…", row.Label);
        Assert.Equal("Ivy is still thinking…", row.LongLabel);
        Assert.False(row.Doing);
        Assert.False(row.OpensSteps);
        Assert.Equal("u", row.Turn);
        // An empty reply streaming draws nothing yet: the row stays.
        Assert.Equal("Ivy is thinking…", Label(Rows([])));
    }

    [Fact]
    public void OnlyARunningStepKeepsItsWordsPastAMinute()
    {
        var running = ThinkingRow.Build(Rows([new ToolPart(Call("terminal", NpmTest))]))!;
        Assert.True(running.Doing);
        Assert.Equal("Ivy is still working…", running.LongLabel);
        Assert.True(running.OpensSteps);
        var held = ThinkingRow.Build(Rows([new ToolPart(Call("terminal", NpmTest, ToolState.Done)), new ReasoningPart("Hm.")]))!;
        Assert.False(held.Doing);
        Assert.Equal("Ivy is still working…", held.LongLabel);
        Assert.Equal("Ivy is still working… · 1:15", ThinkingRow.Words(held.Label, held.LongLabel, 75, held.Doing));
        Assert.Equal("Ivy is running npm test… · 1:15", ThinkingRow.Words(running.Label, running.LongLabel, 75, running.Doing));
    }

    [Fact]
    public void SilentStepsLeaveTheOneBeforeNamed()
    {
        var row = ThinkingRow.Build(Rows([new ToolPart(Call("terminal", NpmTest, ToolState.Done)),
                                          new ToolPart(Call("todo", """{"todos": []}"""))]))!;
        Assert.Equal("Ivy is running npm test…", row.Label);
        // A turn of only silent steps hasn't run any: "is thinking…", and nothing to open.
        var silent = ThinkingRow.Build(Rows([new ToolPart(Call("todo", """{"todos": []}""")), new ReasoningPart("Plan.")]))!;
        Assert.Equal("Ivy is thinking…", silent.Label);
        Assert.False(silent.OpensSteps);
        Assert.Equal("Ivy is still thinking…", silent.LongLabel);
    }

    [Fact]
    public void AMessageToAnotherBotNamesItAsTheRosterDoes()
    {
        var roster = new List<DeliveryMessages.Seat> { new("ivy", "Ivy", null), new("wren", "Wren", null) };
        var input = Rows([new ToolPart(Call("message_agent", """{"target": "@wren", "message": "hi"}"""))], roster: roster) with { BotName = "Otto" };
        Assert.Equal("Otto is messaging Wren…", Label(input));
    }

    [Fact]
    public void NoRowWhenNothingRunsOrTheTurnWaitsOnYouOrInHeader()
    {
        var parts = new List<ChatPart> { new ToolPart(Call("terminal", NpmTest)) };
        Assert.Null(Label(Rows(parts, running: false)));
        // [questions] An open question or approval: the header says "Waiting for your reply".
        Assert.Null(Label(Rows(parts, waitsOnUser: true)));
        // In Header: the status line under the name says what runs (§10.4); not before the reply has a part, though.
        Assert.Null(Label(Rows(parts, style: ToolCallStyle.Header)));
        Assert.Equal("Ivy is thinking…", Label(Rows([], style: ToolCallStyle.Header)));
        // Every other style keeps it under a working reply.
        foreach (var style in new[] { ToolCallStyle.Rows, ToolCallStyle.Line, ToolCallStyle.Bottom, ToolCallStyle.Bubbles })
            Assert.Equal("Ivy is running npm test…", Label(Rows(parts, style: style)));
    }

    [Fact]
    public void ToolNowRowsWorkingAndLatest()
    {
        var reply = new ChatMessage("a", Role.Assistant,
            [new ToolPart(Call("terminal", NpmTest, ToolState.Done)), new TextPart("  \n"), new ReasoningPart("x")]);
        Assert.True(ToolNowRows.Working(reply));
        Assert.Equal("terminal", ToolNowRows.Latest(reply)?.Name);
        Assert.False(ToolNowRows.Working(reply with { Parts = [new TextPart("Done.")] }));
        Assert.Null(ToolNowRows.Latest(reply with { Parts = [new ToolPart(Call("terminal", NpmTest)), new TextPart("Done.")] }));
        Assert.False(ToolNowRows.Working(new ChatMessage("u", Role.User, [new ReasoningPart("x")])));
        // A failed silent step counts: it draws.
        Assert.True(ToolNowRows.Working(reply with { Parts = [new ToolPart(Call("todo", "{}", ToolState.Failed))] }));
        Assert.False(ToolNowRows.Working(reply with { Parts = [new ToolPart(Call("todo", "{}", ToolState.Done))] }));
    }
}
