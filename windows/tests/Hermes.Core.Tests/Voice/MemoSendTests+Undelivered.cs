// [WIN-UNDELIVERED-ACTIONS] Check, Send Again and Delete on your bubble marked "Delivery unconfirmed" (93f984bb1
// LiveChatSession.swift `checkDelivery`, LiveChatSession+ChatActions.swift `sendAgain`, `deleteUndelivered`), each
// clearing the kept lost send where the Mac does. On the same loopback stand-in as the lost-send cases (the link really
// drops under prompt.submit; the history read answers the rows each case sets); synthetic data only.
//
// Ported from Tests/Sessions/LostSendsChatTests.swift checkAndSendAgainClearTheRowsWords (and the Delete step of
// aLostSendIsKeptComesBackAndGoesWithItsBubble, in MemoSendTests+LostSends.cs), Tests/Menus/ChatActionsTests.swift
// ChatUndeliveredTests.deleteAndSendAgain, and the Check step of Tests/Chat/LiveChatSessionTests.swift ("Check"
// (read-only): the gateway did store it; never resent). Added: Check that finds nothing keeps the mark and the entry,
// Check of an unknown message can't tell, and the line's and notices' words.

using System.Text.Json.Nodes;
using Hermes.Core.Chat;
using Hermes.Core.Model;
using Hermes.Core.Sessions;

namespace Hermes.Core.Tests.Voice;

public sealed partial class MemoSendTests
{
    private static Task<SendOutcome> Within(Task<SendOutcome> send) => send.WaitAsync(TimeSpan.FromSeconds(15));

    [Fact]
    public async Task CheckAndSendAgainClearTheRowsWords()
    {
        var store = new LostSends(LostFolder());
        await using var rig = new Rig(_stores);
        rig.Chat.LostSends = store;
        rig.Socket.History = LostRows();
        await rig.Ready();
        await rig.Chat.RefreshAsync();
        LosePrompts(rig);
        Assert.Equal(SendOutcome.Unconfirmed, await Within(rig.Chat.SendAsync("one")));
        var account = rig.Client.AccountId;
        var id = rig.Chat.Messages.Last(m => m.Role == Role.User).Id;
        var submits = rig.Socket.Calls("prompt.submit").Count;
        // Check finds it in the stored chat: the mark and the entry go.
        rig.Socket.History = Rows(new JsonObject { ["role"] = "user", ["content"] = "one", ["row_id"] = 12, ["timestamp"] = 1_791_590_002 });
        Assert.True(await rig.Chat.CheckDeliveryAsync(id));
        Assert.Empty(store.Entries(account, "ivy", LostStored));
        Assert.DoesNotContain(rig.Chat.Messages, m => m.Error != null);
        Assert.Equal(submits, rig.Socket.Calls("prompt.submit").Count);   // Check never resends
        // The chat is read again after a found Check; let that read land before the next send.
        Assert.True(await Until(() => rig.Chat.Messages.Any(m => m.Role == Role.User && m.RowId == 12)));
        // Send Again replaces the entry with the new send's (which is lost again here).
        Assert.Equal(SendOutcome.Unconfirmed, await Within(rig.Chat.SendAsync("two")));
        var second = rig.Chat.Messages[^1];
        Assert.Equal(("two", ChatSession.UnconfirmedMark), (second.Text, second.Error));
        Assert.Equal(SendOutcome.Unconfirmed, await Within(rig.Chat.SendAgain(second.Id)!));
        var last = rig.Chat.Messages[^1];
        Assert.Equal(("two", ChatSession.UnconfirmedMark), (last.Text, last.Error));
        Assert.NotEqual(second.Id, last.Id);
        Assert.DoesNotContain(rig.Chat.Messages, m => m.Id == second.Id);
        var kept = store.Entries(account, "ivy", LostStored);
        Assert.Equal(["two"], kept.Select(e => e.Text));
        Assert.Equal(last.Id, kept[0].Id);
    }

    /// ChatUndeliveredTests.deleteAndSendAgain: only an unconfirmed send can be deleted; Send Again is a plain send of
    /// the bubble's words (no `truncate_before_row_id`), and the old bubble goes.
    [Fact]
    public async Task DeleteAndSendAgain()
    {
        await using var rig = new Rig(_stores);
        await rig.Ready();
        Assert.Equal(SendOutcome.Accepted, await Within(rig.Chat.SendAsync("Fine")));
        var fine = rig.Chat.Messages.Single(m => m.Text == "Fine");
        LosePrompts(rig);
        Assert.Equal(SendOutcome.Unconfirmed, await Within(rig.Chat.SendAsync("Lost on the way")));
        var lost = rig.Chat.Messages.Single(m => m.Text == "Lost on the way");
        Assert.False(ChatSession.IsUndelivered(fine));
        Assert.True(ChatSession.IsUndelivered(lost));
        Assert.False(rig.Chat.DeleteUndelivered(fine.Id));
        Assert.Equal(2, rig.Chat.Messages.Count(m => m.Role == Role.User));   // only an unconfirmed send can be deleted
        Assert.Null(rig.Chat.SendAgain(fine.Id));
        Assert.True(rig.Chat.DeleteUndelivered(lost.Id));
        Assert.Equal([fine.Id], rig.Chat.Messages.Where(m => m.Role == Role.User).Select(m => m.Id));

        Assert.Equal(SendOutcome.Unconfirmed, await Within(rig.Chat.SendAsync("Lost on the way")));
        var again = rig.Chat.Messages.Last(m => m.Role == Role.User);
        rig.Socket.OnCall((method, p, attempt) => method == "prompt.submit"
            ? new JsonObject { ["status"] = "streaming", ["user_row_id"] = 40 }
            : Loopback.Default(method, p, attempt));
        var before = rig.Socket.Calls("prompt.submit").Count;
        var send = rig.Chat.SendAgain(again.Id);
        Assert.NotNull(send);
        Assert.DoesNotContain(rig.Chat.Messages, m => m.Id == again.Id);
        Assert.Equal("Lost on the way", rig.Chat.Messages[^1].Text);
        Assert.Equal(SendOutcome.Accepted, await Within(send!));
        var submit = rig.Socket.Calls("prompt.submit")[before];
        Assert.Equal("Lost on the way", submit.Str("text"));
        Assert.Null(submit["truncate_before_row_id"]);   // a plain send
        Assert.Equal(40, rig.Chat.Messages[^1].RowId);
    }

    /// Check is read-only and says what it saw: not in the newest rows (false) keeps the mark and the kept entry; a
    /// message the chat doesn't hold can't be told (null).
    [Fact]
    public async Task CheckThatFindsNothingKeepsTheMark()
    {
        var store = new LostSends(LostFolder());
        await using var rig = new Rig(_stores);
        rig.Chat.LostSends = store;
        rig.Socket.History = LostRows();
        await rig.Ready();
        await rig.Chat.RefreshAsync();
        LosePrompts(rig);
        Assert.Equal(SendOutcome.Unconfirmed, await Within(rig.Chat.SendAsync("first")));
        var id = rig.Chat.Messages[^1].Id;
        var submits = rig.Socket.Calls("prompt.submit").Count;
        // The same words stored before the send (row 10, at or under the rows known) are not this message.
        Assert.False(await rig.Chat.CheckDeliveryAsync(id));
        Assert.Equal(ChatSession.UnconfirmedMark, rig.Chat.Messages[^1].Error);
        Assert.Single(store.Entries(rig.Client.AccountId, "ivy", LostStored));
        Assert.Null(await rig.Chat.CheckDeliveryAsync("local-user-404"));
        Assert.Equal(submits, rig.Socket.Calls("prompt.submit").Count);
        // A restored lost send's bubble offers the same: Delete takes it and the row's words.
        await using var reopened = await Reopen(rig, store, LostRows());
        var back = reopened.Messages.Single(m => m.Error == ChatSession.UnconfirmedMark);
        Assert.True(ChatSession.IsUndelivered(back));
        Assert.True(reopened.DeleteUndelivered(back.Id));
        Assert.Empty(store.Entries(rig.Client.AccountId, "ivy", LostStored));
    }

    /// The Mac's words: the line under the bubble (App/Chat/ChatRow.swift), its id and hint (ChatCells.swift), and
    /// Check's notices (ChatViewController `chatCellCheckDelivery`).
    [Fact]
    public void TheCheckLineSpeaksTheMacsWords()
    {
        Assert.Equal("Delivery Unconfirmed · Check", ChatSession.CheckDeliveryWords);
        Assert.Equal("Checking Delivery…", ChatSession.CheckingDeliveryWords);
        Assert.Equal("chat.delivery-check", ChatSession.CheckDeliveryId);
        Assert.Equal("Checks whether the computer running Hermes got this message", ChatSession.CheckDeliveryHint);
        Assert.Equal("The computer running Hermes doesn’t have this message yet.", ChatSession.NotThereYetNotice);
        Assert.Equal("Couldn’t check right now. Try again in a moment.", ChatSession.CouldntCheckNotice);
    }
}
