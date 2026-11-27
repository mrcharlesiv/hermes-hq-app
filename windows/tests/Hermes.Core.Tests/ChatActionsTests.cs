using System.Text.Json.Nodes;
using Hermes.Core.Chat;
using Hermes.Core.Model;
using Hermes.Core.Shell;
using Hermes.Core.Transcripts;

namespace Hermes.Core.Tests;

/// [WIN-43] Regenerate, Branch in New Chat, Rewind to Here and Edit, as the Mac's ChatMenus+Actions.swift and
/// HermesKit/Chat/LiveChatSession+ChatActions.swift / ChatActionsModel.swift.
public class ChatActionsTests
{
    private static ChatMessage User(string id, string text, long? row) => new(id, Role.User, [new TextPart(text)], RowId: row);
    private static ChatMessage Bot(string id, string text, long? row) => new(id, Role.Assistant, [new TextPart(text)], RowId: row);

    private static readonly IReadOnlyList<ChatMessage> Chat =
    [
        User("u1", "Plan a weekend", 1), Bot("a1", "Two days.", 2),
        new("s1", Role.System, [new TextPart("note")], RowId: 3),
        User("u2", "Shorter", 4), Bot("a2", "", 5), Bot("a3", "Done.", 6),
    ];

    [Fact]
    public void TheWordsAreTheMacsExactly()
    {
        Assert.Equal("Branching…", ChatActionWords.Branching);
        Assert.Equal("Branched into a new chat.", ChatActionWords.Branched);
        Assert.Equal("Couldn’t Branch Chat", ChatActionWords.BranchFailed);
        Assert.Equal("Branch of Trip planning", ChatActionWords.BranchTitle("  Trip planning "));
        Assert.Equal("Branch", ChatActionWords.BranchTitle(" "));
        Assert.Equal("Branch", ChatActionWords.BranchTitle(null));
        Assert.Equal(("Replace This Reply?", "The prompt runs again, and a new reply takes this one’s place.", "Regenerate", "Cancel"),
            (ChatActionWords.RegenerateTitle, ChatActionWords.RegenerateMessage, ChatActionWords.RegenerateButton, ChatActionWords.Cancel));
        Assert.Equal(("Rewind to Here?", "Everything after this message is removed from the chat, and it runs again from here.", "Rewind and Rerun"),
            (ChatActionWords.RewindTitle, ChatActionWords.RewindMessage, ChatActionWords.RewindButton));
        Assert.Equal(("Send Edit?", "Everything after this message is removed from the chat, and it runs again from your edit.", "Send and Rerun"),
            (ChatActionWords.EditTitle, ChatActionWords.EditMessage, ChatActionWords.EditButton));
        Assert.Equal(("Editing Message", "Later messages will be removed", "Cancel Editing"),
            (ChatActionWords.EditingTitle, ChatActionWords.EditingNote, ChatActionWords.CancelEditing));
        Assert.Equal(("Couldn’t Regenerate", "Couldn’t Rewind", "Couldn’t Edit Message"),
            (ChatActionWords.RegenerateFailed, ChatActionWords.RewindFailed, ChatActionWords.EditFailed));
        Assert.Equal(("This reply can’t be regenerated.", "This message can’t be rewound to.", "This message can’t be edited anymore."),
            (ChatActionWords.CantRegenerate, ChatActionWords.CantRewind, ChatActionWords.CantEdit));
        Assert.Equal(("chat.regenerate-reply", "chat.reply-more"), (ChatActionWords.RegenerateReplyId, ChatActionWords.ReplyMoreId));
        Assert.Equal(["reply-more.share", "reply-more.select", "reply-more.branch"],
            [ChatActionWords.ReplyMoreRowId(MessageMenuItem.Share), ChatActionWords.ReplyMoreRowId(MessageMenuItem.SelectText),
             ChatActionWords.ReplyMoreRowId(MessageMenuItem.Branch)]);
    }

    [Fact]
    public void RewindParamsNameTheRowAndEveryLoadedRowOnce()
    {
        var p = JsonNode.Parse(RewindParams.Make(4, [1, 2, 2, 3, 4]).ToJsonString())!;   // as it goes over the wire
        Assert.Equal(4, p.Num("truncate_before_row_id"));
        Assert.True(p.Bool("confirm_truncate"));
        Assert.True(p.Bool("confirm_empty_truncate"));
        Assert.Equal("[1,2,3,4]", p["rebind_survivor_row_ids"]!.ToJsonString());
    }

    [Fact]
    public void TheSurvivorMapReadsNewIdsAndRowsMappedAway()
    {
        var map = RewindParams.SurvivorMap(JsonNode.Parse("""{"survivor_row_id_map":{"1":11,"2":null,"x":3}}"""));
        Assert.Equal(2, map.Count);
        Assert.Equal(11L, map[1]);
        Assert.Null(map[2]);
        Assert.Empty(RewindParams.SurvivorMap(JsonNode.Parse("{}")));
    }

    [Fact]
    public void BranchCountsTextBearingUserAndAssistantMessagesThroughTheOneChosen()
    {
        Assert.Equal(2, RewindParams.BranchCount("a1", Chat));   // the note doesn't count
        Assert.Equal(3, RewindParams.BranchCount("a2", Chat));   // an empty reply doesn't either
        Assert.Equal(4, RewindParams.BranchCount("a3", Chat));
        Assert.Null(RewindParams.BranchCount("gone", Chat));
    }

    [Fact]
    public void OnlyYourStoredTextMessagesCanBeRewoundTo()
    {
        Assert.True(ChatActionRules.CanRewind(User("u", "hi", 3)));
        Assert.False(ChatActionRules.CanRewind(User("u", "hi", null)));            // not stored yet
        Assert.False(ChatActionRules.CanRewind(User("u", "  ", 3)));               // no words
        Assert.False(ChatActionRules.CanRewind(Bot("a", "hi", 3)));                // a reply
        Assert.False(ChatActionRules.CanRewind(User("u", "hi", 3) with { IsPending = true }));
        Assert.False(ChatActionRules.CanRewind(User("u", "hi", 3) with { Error = "Delivery unconfirmed" }));
    }

    [Fact]
    public void RegenerateRunsThePromptBeforeTheNewestReply()
    {
        Assert.Equal(3, ChatActionRules.RegeneratePrompt(Chat));
        Assert.Null(ChatActionRules.RegeneratePrompt([Bot("a", "hello", 1)]));
        Assert.Null(ChatActionRules.RegeneratePrompt([User("u", "hi", 1)]));
        Assert.Equal("a3", ChatActionRules.LatestReplyId(Chat));
        Assert.Equal(ChatActionWords.WaitForReply, ChatActionRules.RegenerateBlocked(running: true, offline: true));
        Assert.Equal(ChatActionWords.Offline, ChatActionRules.RegenerateBlocked(running: false, offline: true));
        Assert.Null(ChatActionRules.RegenerateBlocked(running: false, offline: false));
    }

    [Fact]
    public void AnEditOfAnEarlierMessageRemovesLaterTurnsAndAnUnchangedOneSendsNothing()
    {
        Assert.True(ChatActionRules.HasLaterMessages(Chat, "u1"));
        Assert.False(ChatActionRules.HasLaterMessages(Chat, "u2"));
        Assert.Null(ChatActionRules.EditedText(Chat[0], " Plan a weekend "));
        Assert.Null(ChatActionRules.EditedText(Chat[0], "  "));
        Assert.Equal("Plan a week", ChatActionRules.EditedText(Chat[0], " Plan a week "));
    }

    [Fact]
    public void ARewindKeepsTheTurnsBeforeAndARefusalPutsThemBack()
    {
        var t = new Transcript();
        t.ReplaceWithHistory(Chat);
        var before = t.KeepFirst(3);
        Assert.Equal(["u1", "a1", "s1"], t.Messages.Select(m => m.Id));
        t.AddLocalUser("Shorter still");
        Assert.True(t.Busy);
        t.Restore(before);
        Assert.False(t.Busy);
        Assert.Equal(Chat.Select(m => m.Id), t.Messages.Select(m => m.Id));
    }

    [Fact]
    public void TheWalkChecksTheMenuTheBranchCallAndTheBranchOpened()
    {
        Assert.Null(ChatActionsProof.MenuReads([("Trip planning · 9:00 AM", false), ("Copy", true), ("Share…", true), ("Select Text", true),
            ("Regenerate", true), ("Branch in New Chat", true)]));
        Assert.Contains("not Copy", ChatActionsProof.MenuReads([("Copy", true), ("Select Text", true)]));
        Assert.Equal("Regenerate is dimmed on a settled reply", ChatActionsProof.MenuReads([("Copy", true), ("Share…", true),
            ("Select Text", true), ("Regenerate", false), ("Branch in New Chat", true)]));

        var calls = new JsonArray(
            new JsonObject { ["method"] = "prompt.submit", ["params"] = new JsonObject(), ["at"] = 1.0 },
            new JsonObject { ["method"] = "session.branch", ["params"] = new JsonObject { ["count"] = 6.0 }, ["at"] = 3.0 });
        var state = new JsonObject { ["calls"] = calls };
        Assert.Null(ChatActionsProof.Branched(state, 2, 6));
        Assert.Equal("the branch's count was 6, not 4", ChatActionsProof.Branched(state, 2, 4));
        Assert.Equal("the stand-in took 0 branch calls, not 1", ChatActionsProof.Branched(state, 5, 6));
        Assert.Equal("the branch also sent prompt.submit", ChatActionsProof.Branched(state, 0, 6));

        Assert.Null(ChatActionsProof.BranchOpened("b1", "Branch of Trip planning", "Branched into a new chat.", "t", "Trip planning"));
        Assert.Equal("the branch didn't open in the chat's place", ChatActionsProof.BranchOpened("t", "x", null, "t", "Trip planning"));
        Assert.Equal("the notice reads nothing, not Branched into a new chat.",
            ChatActionsProof.BranchOpened("b1", "Branch of Trip planning", null, "t", "Trip planning"));
    }
}
