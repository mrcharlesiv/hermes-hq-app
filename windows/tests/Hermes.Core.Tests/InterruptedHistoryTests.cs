using System.Text.Json.Nodes;
using Hermes.Core.Chat;
using Hermes.Core.Model;
using Hermes.Core.Rpc;
using Xunit;

namespace Hermes.Core.Tests;

public class InterruptedHistoryTests
{
    private static ChatMessage Row(long id, Role role, string text) =>
        new($"stored-row-{id}-{role.ToString().ToLowerInvariant()}", role, [new TextPart(text)], RowId: id);
    private static void Delta(Transcript t, string text) => t.Apply(new RpcEvent("message.delta", "s", new JsonObject { ["text"] = text }, null));
    private static void End(Transcript t, string status, string text) => t.Apply(new RpcEvent("message.complete", "s", new JsonObject { ["status"] = status, ["text"] = text }, null));
    private static Transcript Stopped()
    {
        var t = new Transcript();
        t.ReplaceWithHistory([Row(1, Role.User, "old"), Row(2, Role.Assistant, "old answer")]);
        var prompt = t.AddLocalUser("stop me");
        t.MarkSent(prompt.Id, 3);
        Delta(t, "word0 word1");
        t.Stop();
        End(t, "complete", "unrelated stand-in");
        return t;
    }
    private static string[] Texts(Transcript t) => t.Messages.Select(m => m.Text).ToArray();

    [Fact]
    public void RefreshRetainsPartialInItsTurnAndIsIdempotent()
    {
        var t = Stopped();
        ChatMessage[] page = [Row(1, Role.User, "old"), Row(2, Role.Assistant, "old answer"), Row(3, Role.User, "stop me")];
        t.ReplaceWithHistory(page);
        t.ReplaceWithHistory(page);
        Assert.Equal(new[] { "old", "old answer", "stop me", "word0 word1" }, Texts(t));
        Assert.True(t.Messages[^1].Interrupted);
    }

    [Theory]
    [InlineData("word0 word1")]
    [InlineData("word0 word1 and more")]
    [InlineData("word0")]
    public void CompatibleStoredReplyReconcilesWithoutDuplicates(string stored)
    {
        var t = Stopped();
        t.ReplaceWithHistory([Row(1, Role.User, "old"), Row(2, Role.Assistant, "old answer"),
            Row(3, Role.User, "stop me"), Row(4, Role.Assistant, stored)]);
        Assert.Equal(4, t.Messages.Count);
        Assert.Equal(stored.Length < "word0 word1".Length ? "word0 word1" : stored, t.Messages[^1].Text);
        Assert.True(t.Messages[^1].Interrupted);
    }

    [Fact]
    public void NextTurnStaysAfterStoppedBubbleAndCannotReconcileIt()
    {
        var t = Stopped();
        var next = t.AddLocalUser("next");
        t.MarkSent(next.Id, 5);
        Delta(t, "word0 word1 next reply");
        End(t, "complete", "word0 word1 next reply");
        ChatMessage[] page = [Row(1, Role.User, "old"), Row(2, Role.Assistant, "old answer"),
            Row(3, Role.User, "stop me"), Row(5, Role.User, "next"), Row(6, Role.Assistant, "word0 word1 next reply")];
        t.ReplaceWithHistory(page);
        Assert.Equal(new[] { "old", "old answer", "stop me", "word0 word1", "next", "word0 word1 next reply" }, Texts(t));
        t.ReplaceWithHistory(page);
        Assert.Equal(6, t.Messages.Count);
    }

    [Fact]
    public void DifferentStoredReplyIsNotMistakenForPartial()
    {
        var t = Stopped();
        t.ReplaceWithHistory([Row(3, Role.User, "stop me"), Row(4, Role.Assistant, "different")]);
        Assert.Equal(new[] { "stop me", "different", "word0 word1" }, Texts(t));
    }

    [Fact]
    public void RepeatedPromptWhileNextTurnStreamsIsNotDroppedOrReanchored()
    {
        var t = Stopped();
        t.AddLocalUser("stop me");
        Delta(t, "new stream");
        t.ReplaceWithHistory([Row(1, Role.User, "old"), Row(2, Role.Assistant, "old answer"), Row(3, Role.User, "stop me")]);
        Assert.Equal(new[] { "old", "old answer", "stop me", "word0 word1", "stop me", "new stream" }, Texts(t));
    }

    [Fact]
    public void LateNamedInterruptedEndExtendsOnlyStoppedTurnNotLiveNextTurn()
    {
        var t = Stopped();
        var next = t.AddLocalUser("next");
        t.MarkSent(next.Id, 5);
        Delta(t, "new stream");
        var outcome = t.Apply(new RpcEvent("message.complete", "s", JsonNode.Parse(
            """{"status":"interrupted","text":"word0 word1 extended","persisted_turn":{"user_row_id":3}}"""), null));
        Assert.Equal(Transcript.Outcome.Changed, outcome);
        Assert.True(t.Busy);
        Assert.Equal(new[] { "old", "old answer", "stop me", "word0 word1 extended", "next", "new stream" }, Texts(t));
    }

    [Fact]
    public void UnnamedInterruptedEndPendingAtNextSendCannotOverwriteNextReply()
    {
        var t = new Transcript();
        var first = t.AddLocalUser("first");
        t.MarkSent(first.Id, 1);
        Delta(t, "partial");
        t.Stop();
        var next = t.AddLocalUser("next");
        t.MarkSent(next.Id, 2);
        Delta(t, "new stream");
        End(t, "interrupted", "partial more");
        Assert.True(t.Busy);
        Assert.Equal(new[] { "first", "partial more", "next", "new stream" }, Texts(t));
    }

    [Fact]
    public void StopBeforeAnyReplyCannotExtendAnEarlierStoppedTurn()
    {
        var t = Stopped();
        t.AddLocalUser("next");
        t.Stop();
        End(t, "interrupted", "word0 word1 wrong turn");
        Assert.Equal("word0 word1", t.Messages.Single(m => m.Interrupted).Text);
    }

    [Fact]
    public void SamePromptInOlderHistoryIsNotAnAnchorWithoutRowId()
    {
        var t = new Transcript();
        t.ReplaceWithHistory([Row(1, Role.User, "same"), Row(2, Role.Assistant, "old")]);
        t.AddLocalUser("same");
        Delta(t, "partial");
        t.Stop();
        t.ReplaceWithHistory([Row(1, Role.User, "same"), Row(2, Role.Assistant, "old")]);
        Assert.Equal(new[] { "same", "old", "same", "partial" }, Texts(t));
        t.ReplaceWithHistory([Row(1, Role.User, "same"), Row(2, Role.Assistant, "old"), Row(3, Role.User, "same")]);
        Assert.Equal(new[] { "same", "old", "same", "partial" }, Texts(t));
    }

    [Fact]
    public void UnknownStoppedPromptIsNotMatchedToLaterIdenticalPrompt()
    {
        var t = new Transcript();
        t.ReplaceWithHistory([Row(1, Role.User, "old"), Row(2, Role.Assistant, "old reply")]);
        t.AddLocalUser("same");
        Delta(t, "partial");
        t.Stop();
        var next = t.AddLocalUser("same");
        t.MarkSent(next.Id, 5);
        Delta(t, "next reply");
        End(t, "complete", "next reply");
        t.ReplaceWithHistory([Row(1, Role.User, "old"), Row(2, Role.Assistant, "old reply"),
            Row(5, Role.User, "same"), Row(6, Role.Assistant, "next reply")]);
        Assert.Equal(new[] { "old", "old reply", "same", "partial", "same", "next reply" }, Texts(t));
    }

    [Fact]
    public void StoredReplyKeepsItsIdentityWhenTheGatewayRewritesItsWords()
    {
        var t = Stopped();
        var prompt = Row(3, Role.User, "stop me");
        t.ReplaceWithHistory([prompt, Row(4, Role.Assistant, "word0 word1")]);
        var shownId = t.Messages[^1].Id;
        for (var i = 0; i < 2; i++)
        {
            t.ReplaceWithHistory([prompt, Row(4, Role.Assistant, "revised")]);
            var reply = Assert.Single(t.Messages, m => m.Role == Role.Assistant);
            Assert.Equal(shownId, reply.Id);
            Assert.Equal("revised", reply.Text);
            Assert.True(reply.Interrupted);
        }
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void StoredReplyWithoutWordsKeepsTheShownPartialOnce(bool withTool)
    {
        var t = Stopped();
        var stored = Row(4, Role.Assistant, "") with { Parts = withTool
            ? [new ToolPart(new ToolCall("t1", "read", null, null, ToolState.Done))] : [] };
        for (var i = 0; i < 2; i++)
        {
            t.ReplaceWithHistory([Row(3, Role.User, "stop me"), stored]);
            var reply = Assert.Single(t.Messages, m => m.Role == Role.Assistant);
            Assert.Equal(4L, reply.RowId);
            Assert.Equal("word0 word1", reply.Text);
            Assert.True(reply.Interrupted);
        }
    }

    [Fact]
    public void StoredToolResultWinsWhenThereWereNoLocalWordsToKeep()
    {
        var t = new Transcript();
        var user = t.AddLocalUser("run tool");
        t.MarkSent(user.Id, 1);
        t.Apply(new RpcEvent("tool.start", "s", new JsonObject { ["tool_id"] = "t", ["name"] = "read" }, null));
        t.Stop();
        var result = new ToolCall("t", "read", null, "finished", ToolState.Done);
        t.ReplaceWithHistory([Row(1, Role.User, "run tool"), Row(2, Role.Assistant, "") with { Parts = [new ToolPart(result)] }]);
        var reply = Assert.Single(t.Messages, m => m.Role == Role.Assistant);
        Assert.Equal(result, Assert.Single(reply.Tools));
    }

    [Fact]
    public void NamedEndAfterStopBeforeFirstDeltaCannotSettleTheNextSend()
    {
        var t = new Transcript();
        var first = t.AddLocalUser("first");
        t.Stop();
        t.MarkSent(first.Id, 1); // the prompt ack can itself arrive after Stop
        var second = t.AddLocalUser("second");
        t.MarkSent(second.Id, 2);
        Delta(t, "new stream");
        var outcome = t.Apply(new RpcEvent("message.complete", "s", JsonNode.Parse(
            """{"status":"interrupted","text":"old answer","persisted_turn":{"user_row_id":1}}"""), null));
        Assert.NotEqual(Transcript.Outcome.TurnEnded, outcome);
        Assert.True(t.Busy);
        Assert.Equal(new[] { "first", "second", "new stream" }, Texts(t));
    }

    [Fact]
    public void SealedAndLiveBubblesKeepOrderWhileStoredRowsCatchUp()
    {
        var t = new Transcript();
        var prompt = t.AddLocalUser("go");
        t.MarkSent(prompt.Id, 1);
        Delta(t, "before tool");
        t.Apply(new RpcEvent("message.interim", "s", new JsonObject(), null));
        Delta(t, "after tool");
        t.Stop();
        var user = Row(1, Role.User, "go");
        var first = Row(2, Role.Assistant, "before tool");
        var second = Row(3, Role.Assistant, "after tool");
        foreach (ChatMessage[] page in new ChatMessage[][] { [user], [user, second], [user, first, second], [user, first, second] })
        {
            t.ReplaceWithHistory(page);
            Assert.Equal(new[] { "go", "before tool", "after tool" }, Texts(t));
            Assert.True(t.Messages[^1].Interrupted);
            Assert.False(t.Messages[1].Interrupted);
        }
    }

    [Fact]
    public void WithdrawnUnsentPromptCannotReturnOnHistoryRefresh()
    {
        var t = new Transcript();
        var unsent = t.AddLocalUser("still uploading");
        t.Stop();
        t.Withdraw(unsent.Id);
        t.ReplaceWithHistory([]);
        Assert.Empty(t.Messages);
    }

    [Fact]
    public void MissingPromptDoesNotAttachPartialToAnotherTurn()
    {
        var t = Stopped();
        t.ReplaceWithHistory([Row(1, Role.User, "old"), Row(2, Role.Assistant, "old answer")]);
        Assert.Equal(new[] { "old", "old answer", "stop me", "word0 word1" }, Texts(t));
        t.ReplaceWithHistory([Row(1, Role.User, "old"), Row(2, Role.Assistant, "old answer"), Row(3, Role.User, "stop me")]);
        Assert.Equal(new[] { "old", "old answer", "stop me", "word0 word1" }, Texts(t));
    }
}
