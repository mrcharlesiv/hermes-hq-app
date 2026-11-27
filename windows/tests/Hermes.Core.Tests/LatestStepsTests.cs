// [WIN-STEPS-AFTER-REPLY] The inspector's Steps (Hermes.Core/Transcript/LatestSteps.cs): the latest turn's steps, as the
// Mac's ChatActivityController `turnSteps(endingAt: nil)` feeds MacInspector at 93f984bb1. A finished reply keeps them
// from its messages: the live turn's sealed parts until the turn-end read, then the stored turn, which wins over the live
// one there as in HermesKit's TranscriptMerge.graft (the stored copy's parts; the live words only when it has none).
// So a gateway that stores the turn's tool rows keeps the steps; one that stores the words alone (the chat-thinking
// walk's stand-in before this card) leaves none, on the Mac as here. Synthetic only.

using System.Text.Json.Nodes;
using Hermes.Core.Chat;
using Hermes.Core.Model;
using Hermes.Core.Rpc;
using Hermes.Core.Transcripts;
using Proof = Hermes.Core.Shell.ThinkingWalkProof;

namespace Hermes.Core.Tests;

public sealed class LatestStepsTests
{
    private static RpcEvent Ev(string type, string json = "{}") => new(type, "s", JsonNode.Parse(json), null);

    /// The chat-thinking walk's turn over the wire: the prompt, the held `npm test` step, the reply.
    private static Transcript HeldTurnFinished()
    {
        var t = new Transcript();
        t.AddLocalUser(Proof.Text);
        t.Apply(Ev("message.start"));
        t.Apply(Ev("tool.start", """{"name":"terminal","tool_id":"call_hold_1","args":{"command":"cd /Users/me/app && npm test"}}"""));
        Assert.Equal(ToolState.Running, Assert.Single(LatestSteps.Of(t.Messages)).Call.State);
        t.Apply(Ev("tool.complete", """{"name":"terminal","tool_id":"call_hold_1","result":"ok"}"""));
        t.Apply(Ev("message.delta", """{"text":"Hi! I'm Ivy."}"""));
        Assert.Equal(Transcript.Outcome.TurnEnded, t.Apply(Ev("message.complete", """{"text":"Hi! I'm Ivy.","status":"complete","row_id":4}""")));
        return t;
    }

    [Fact]
    public void TheFinishedReplyKeepsItsStepFromTheStoredTurn()
    {
        var t = HeldTurnFinished();
        // Sealed on the live reply until the read.
        Assert.Equal("Ran a command", StepWords.Words(Assert.Single(LatestSteps.Of(t.Messages)).Call));
        // The turn-end read of a gateway that stores the turn's steps (as Hermes does, and the stand-in now does).
        t.ReplaceWithHistory(HistoryFold.Fold(Proof.StoredTurn(1)));
        var (message, call) = Assert.Single(LatestSteps.Of(t.Messages));
        Assert.Equal("Hi! I'm Ivy.", message.Text);
        Assert.Equal(ToolState.Done, call.State);
        Assert.Equal("Ran a command", StepWords.Words(call));
        Assert.Equal((call.Id, call.Name, call.State), Proof.StoredStep() is { } stored ? (stored.Id, stored.Name, stored.State) : default);
    }

    [Fact]
    public void AStoredTurnWithOnlyTheWordsLeavesNoStepsAsOnTheMac()
    {
        // The stand-in before this card stored {role: assistant, content} alone: its stored reply replaces the live one
        // (TranscriptMerge.graft `m = f`), so the inspector said it ran none, on the Mac too.
        var t = HeldTurnFinished();
        t.ReplaceWithHistory(HistoryFold.Fold([
            JsonNode.Parse($$"""{"role":"user","content":"{{Proof.Text}}","row_id":1}"""),
            JsonNode.Parse("""{"role":"assistant","content":"Hi! I'm Ivy.","row_id":2}""")]));
        Assert.Empty(LatestSteps.Of(t.Messages));
    }

    [Fact]
    public void OnlyTheLatestTurnAndNoQuietSteps()
    {
        var rows = new JsonArray(
            JsonNode.Parse("""{"role":"user","content":"first","row_id":1}"""),
            JsonNode.Parse("""{"role":"assistant","content":"","row_id":2,"tool_calls":[{"id":"a","function":{"name":"read_file","arguments":"{\"path\":\"/fixture/a.txt\"}"}}]}"""),
            JsonNode.Parse("""{"role":"tool","tool_call_id":"a","content":"ok","row_id":3}"""),
            JsonNode.Parse("""{"role":"assistant","content":"Read it.","row_id":4}"""),
            JsonNode.Parse("""{"role":"user","content":"second","row_id":5}"""),
            JsonNode.Parse("""{"role":"assistant","content":"","row_id":6,"tool_calls":[{"id":"b","function":{"name":"todo","arguments":"{}"}},{"id":"c","function":{"name":"terminal","arguments":"{\"command\":\"ls\"}"}}]}"""),
            JsonNode.Parse("""{"role":"tool","tool_call_id":"b","content":"ok","row_id":7}"""),
            JsonNode.Parse("""{"role":"tool","tool_call_id":"c","content":"ok","row_id":8}"""),
            JsonNode.Parse("""{"role":"assistant","content":"Done.","row_id":9}"""));
        var steps = LatestSteps.Of(HistoryFold.Fold(rows));
        Assert.Equal(["c"], steps.Select(s => s.Call.Id));   // the earlier turn's stays with it; the quiet to-do isn't listed
        Assert.Empty(LatestSteps.Of([]));
        // A prompt with no reply yet: the Mac's walk starts at the newest message and steps back over every non-prompt
        // before it, so the turn before the prompt still shows until the reply's own rows arrive. Kept as the Mac has it.
        var waiting = HistoryFold.Fold(rows.Select(r => r?.DeepClone()).Append(JsonNode.Parse("""{"role":"user","content":"third","row_id":10}""")));
        Assert.Equal(Role.User, waiting[^1].Role);
        Assert.Equal(["c"], LatestSteps.Of(waiting).Select(s => s.Call.Id));
    }

    [Fact]
    public void TheEmptyPanelSaysWhoseStepsTheseAreAsTheMac()
    {
        // StepSheets.swift updateEmptyLine (the inspector's live panel).
        Assert.Equal("No Steps in the Latest Reply", LatestSteps.EmptyTitle);
        Assert.Equal("The tools a bot runs for its latest reply are listed here as it works. An earlier reply’s steps stay with that reply in the chat.",
            LatestSteps.EmptyHint);
    }
}
