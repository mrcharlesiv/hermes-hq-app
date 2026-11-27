// [WIN-LOST-SEND-MARKER] The chat's side of a send that may never have arrived (93f984bb1 HermesKit/Chat/LostSends.swift):
// a typed send marked "Delivery unconfirmed" is kept for its Sessions row; a history read that shows it arrived clears it;
// a voice memo is never kept (`noteLostSend`'s `guard !memo`). On the same loopback stand-in as the memo cases (the link
// really drops under prompt.submit), its history read answering the rows each case sets; synthetic data only.
//
// Ported from Tests/Sessions/LostSendsChatTests.swift: aLostSendIsKeptComesBackAndGoesWithItsBubble,
// aRestoredBubbleGoesBackWhereItWasSaid, aSendThatArrivedGoesQuietly (with the restored bubble, WIN-LOST-SEND-RESTORE),
// aChatWithoutTheStoreKeepsNothing; and Tests/Chat/StopSendRaceTests.swift
// aLostSendIsNotClearedByAnOlderMessageWithTheSameWords. checkAndSendAgainClearTheRowsWords is in
// MemoSendTests+Undelivered.cs (WIN-UNDELIVERED-ACTIONS). Added: a second read keeps the restored bubble once and in its place; a memo left
// "Delivery unconfirmed" keeps nothing (the Mac's guard).

using System.Text.Json.Nodes;
using Hermes.Core.Chat;
using Hermes.Core.Model;
using Hermes.Core.Sessions;

namespace Hermes.Core.Tests.Voice;

public sealed partial class MemoSendTests
{
    private const string LostStored = "20260929_120000_aabbcc02";

    private static JsonArray LostRows() =>
    [
        new JsonObject { ["role"] = "user", ["content"] = "first", ["row_id"] = 10, ["timestamp"] = 1_791_590_000 },
        new JsonObject { ["role"] = "assistant", ["content"] = "an answer", ["row_id"] = 11, ["timestamp"] = 1_791_590_001 },
    ];

    private static JsonArray Rows(params JsonObject[] more)
    {
        var rows = LostRows();
        foreach (var row in more) rows.Add(row);
        return rows;
    }

    private static string LostFolder() => Directory.CreateTempSubdirectory("lost-sends-chat-").FullName;

    private static void LosePrompts(Rig rig) =>
        rig.Socket.OnCall((method, p, attempt) => method == "prompt.submit" ? throw new DropLink() : Loopback.Default(method, p, attempt));

    /// The chat opened again (another screen, or the next launch): a second session on the same account reads the rows.
    private static async Task<ChatSession> Reopen(Rig rig, LostSends store, JsonArray rows)
    {
        rig.Socket.History = rows;
        var again = rig.Client.OpenChat("ivy", LostStored, "Ivy");
        again.LostSends = store;
        await again.RefreshAsync();
        return again;
    }

    [Fact]
    public async Task ALostSendIsKeptComesBackAndGoesWithItsBubble()
    {
        var store = new LostSends(LostFolder());
        var changes = 0;
        store.Changed += () => Interlocked.Increment(ref changes);
        await using var rig = new Rig(_stores);
        rig.Chat.LostSends = store;
        rig.Socket.History = LostRows();
        await rig.Ready();
        await rig.Chat.RefreshAsync();
        LosePrompts(rig);
        Assert.Equal(SendOutcome.Unconfirmed, await rig.Chat.SendAsync("  call the plumber ").WaitAsync(TimeSpan.FromSeconds(15)));
        var bubble = rig.Chat.Messages.Last(m => m.Role == Role.User);
        Assert.Equal(ChatSession.UnconfirmedMark, bubble.Error);
        var account = rig.Client.AccountId;
        var kept = store.Entries(account, "ivy", LostStored);
        Assert.Equal(["call the plumber"], kept.Select(e => e.Text));
        Assert.Equal(bubble.Id, kept[0].Id);
        Assert.Equal(11, kept[0].After);
        Assert.Equal(1, Volatile.Read(ref changes));
        // The rows read again in the same chat: the marked bubble is still there, once, so the entry stays.
        await rig.Chat.RefreshAsync();
        Assert.Single(rig.Chat.Messages, m => m.Error == ChatSession.UnconfirmedMark);
        Assert.Single(store.Entries(account, "ivy", LostStored));

        // The chat is opened again (another screen, or the next launch): the bubble is back, marked, once.
        await using var again = await Reopen(rig, store, LostRows());
        var back = again.Messages.Where(m => m.Role == Role.User && m.Error == ChatSession.UnconfirmedMark).ToList();
        Assert.Equal(["call the plumber"], back.Select(m => m.Text));
        Assert.Equal(again.Messages[^1].Id, back[0].Id);
        Assert.Matches("^local-user-lost-[0-9a-f]{8}$", back[0].Id);
        Assert.Null(back[0].RowId);
        Assert.Equal(back.Select(m => m.Id), store.Entries(account, "ivy", LostStored).Select(e => e.Id));
        Assert.Equal(1, Volatile.Read(ref changes));   // the new id is said to no one: the row's words are the same
        await again.RefreshAsync();
        Assert.Single(again.Messages, m => m.Error == ChatSession.UnconfirmedMark);   // never twice
        Assert.Equal(back[0].Id, again.Messages[^1].Id);                               // the same bubble, in its place
        Assert.Single(store.Entries(account, "ivy", LostStored));

        // Delete takes the bubble and the row's words (deleteUndelivered, WIN-UNDELIVERED-ACTIONS).
        Assert.True(again.DeleteUndelivered(back[0].Id));
        Assert.DoesNotContain(again.Messages, m => m.Error != null);
        Assert.Null(store.First(account, "ivy", LostStored));
        await using var third = await Reopen(rig, store, LostRows());
        Assert.Equal(["first", "an answer"], third.Messages.Select(m => m.Text));
    }

    /// Review finding: a restored bubble goes back where it was said. The chat went on from another device after the
    /// send was lost (rows 12 and 13): the bubble sits after the rows the chat knew (10, 11), before the later ones.
    [Fact]
    public async Task ARestoredBubbleGoesBackWhereItWasSaid()
    {
        var store = new LostSends(LostFolder());
        await using var rig = new Rig(_stores);
        rig.Chat.LostSends = store;
        rig.Socket.History = LostRows();
        await rig.Ready();
        await rig.Chat.RefreshAsync();
        LosePrompts(rig);
        Assert.Equal(SendOutcome.Unconfirmed, await rig.Chat.SendAsync("call the plumber").WaitAsync(TimeSpan.FromSeconds(15)));
        await using var later = await Reopen(rig, store, Rows(
            new JsonObject { ["role"] = "user", ["content"] = "something else", ["row_id"] = 12, ["timestamp"] = 1_791_590_900 },
            new JsonObject { ["role"] = "assistant", ["content"] = "a later answer", ["row_id"] = 13, ["timestamp"] = 1_791_590_901 }));
        Assert.Equal(["first", "an answer", "call the plumber", "something else", "a later answer"], later.Messages.Select(m => m.Text));
        Assert.Equal(ChatSession.UnconfirmedMark, later.Messages[2].Error);
        // Read again: it stays where it was said, not moved to the end.
        await later.RefreshAsync();
        Assert.Equal(["first", "an answer", "call the plumber", "something else", "a later answer"], later.Messages.Select(m => m.Text));
        // Without the row number (an older entry), the saved time places it; with neither, the end.
        var old = new LostSends.Entry("x", "t", DateTimeOffset.FromUnixTimeMilliseconds(1_791_590_000_500));
        Assert.Equal(1, later.LostSendPlace(old));
        Assert.Equal(later.Messages.Count, later.LostSendPlace(new LostSends.Entry("y", "t", DateTimeOffset.FromUnixTimeSeconds(1_800_000_000))));
    }

    [Fact]
    public async Task ASendThatArrivedGoesQuietly()
    {
        var store = new LostSends(LostFolder());
        await using var rig = new Rig(_stores);
        rig.Chat.LostSends = store;
        rig.Socket.History = LostRows();
        await rig.Ready();
        await rig.Chat.RefreshAsync();
        LosePrompts(rig);
        Assert.Equal(SendOutcome.Unconfirmed, await rig.Chat.SendAsync("did this arrive").WaitAsync(TimeSpan.FromSeconds(15)));
        Assert.Single(store.Entries(rig.Client.AccountId, "ivy", LostStored));
        // The gateway did store it (its clock an hour behind the PC's): the next open shows the stored row, no marked twin.
        await using (var arrived = await Reopen(rig, store, Rows(
            new JsonObject { ["role"] = "user", ["content"] = "did this arrive", ["row_id"] = 12, ["timestamp"] = 1_791_590_002 },
            new JsonObject { ["role"] = "assistant", ["content"] = "It did.", ["row_id"] = 13, ["timestamp"] = 1_791_590_003 })))
        {
            Assert.Equal(["first", "an answer", "did this arrive", "It did."], arrived.Messages.Select(m => m.Text));
            Assert.DoesNotContain(arrived.Messages, m => m.Error != null);
        }
        Assert.Empty(store.Entries(rig.Client.AccountId, "ivy", LostStored));
        // The same words from before the send are not proof: the bubble returns.
        rig.Socket.History = LostRows();
        Assert.Equal(SendOutcome.Unconfirmed, await rig.Chat.SendAsync("first").WaitAsync(TimeSpan.FromSeconds(15)));
        await using var again = await Reopen(rig, store, LostRows());
        Assert.Equal(["first", "an answer", "first"], again.Messages.Select(m => m.Text));
        Assert.Equal(ChatSession.UnconfirmedMark, again.Messages[^1].Error);
        Assert.Equal(["first"], store.Entries(rig.Client.AccountId, "ivy", LostStored).Select(e => e.Text));
    }

    [Fact]
    public async Task AChatWithoutTheStoreKeepsNothing()
    {
        var store = new LostSends(LostFolder());
        await using var rig = new Rig(_stores);
        rig.Socket.History = LostRows();
        await rig.Ready();
        await rig.Chat.RefreshAsync();
        LosePrompts(rig);
        Assert.Equal(SendOutcome.Unconfirmed, await rig.Chat.SendAsync("nobody is told").WaitAsync(TimeSpan.FromSeconds(15)));
        Assert.Null(rig.Chat.LostSends);
        Assert.Equal(0, store.Count(rig.Client.AccountId));
    }

    /// StopSendRaceTests: a lost send in a chat whose earlier messages have no stored row numbers yet is not taken as
    /// arrived by an older message with the same words; in a new chat (nothing before it) row 0 still holds.
    [Fact]
    public async Task ALostSendIsNotClearedByAnOlderMessageWithTheSameWords()
    {
        var store = new LostSends(LostFolder());
        var hourAgo = DateTimeOffset.Now.AddHours(-1).ToUnixTimeSeconds();
        await using var rig = new Rig(_stores);
        rig.Chat.LostSends = store;
        rig.Socket.History = [new JsonObject { ["role"] = "user", ["content"] = "yes", ["timestamp"] = hourAgo }];
        await rig.Ready();
        await rig.Chat.RefreshAsync();
        Assert.Null(rig.Chat.Messages[0].RowId);
        LosePrompts(rig);
        Assert.Equal(SendOutcome.Unconfirmed, await rig.Chat.SendAsync("yes").WaitAsync(TimeSpan.FromSeconds(15)));
        var entry = Assert.Single(store.Entries(rig.Client.AccountId, "ivy", LostStored));
        Assert.Null(entry.After);   // judged by its time, not "after row 0"
        // A read numbers the earlier "yes" (an hour old); the marked bubble is not on this screen.
        await using (var numbered = await Reopen(rig, store,
            [new JsonObject { ["role"] = "user", ["content"] = "yes", ["row_id"] = 41, ["timestamp"] = hourAgo }]))
            Assert.Single(store.Entries(rig.Client.AccountId, "ivy", LostStored));
        // In a new chat (nothing before it) row 0 holds.
        await using var rig2 = new Rig(_stores, stored: "new-chat");
        rig2.Chat.LostSends = store;
        await rig2.Ready();
        await rig2.Chat.RefreshAsync();
        LosePrompts(rig2);
        Assert.Equal(SendOutcome.Unconfirmed, await rig2.Chat.SendAsync("yes").WaitAsync(TimeSpan.FromSeconds(15)));
        Assert.Equal(0, store.First(rig2.Client.AccountId, "ivy", "new-chat")?.After);
    }

    /// `markUnconfirmed` calls `noteLostSend(localId, memo: true)`, which keeps nothing: a memo keeps its own draft.
    [Fact]
    public async Task AMemoLeftUnconfirmedKeepsNothing()
    {
        var store = new LostSends(LostFolder());
        await using var rig = new Rig(_stores);
        rig.Chat.LostSends = store;
        LosePrompts(rig);
        await rig.Ready();
        var memo = _stores.Recording(rig.Client.AccountId);
        Assert.Equal(SendOutcome.Unconfirmed, await rig.Chat.SendMemoAsync(memo, "beside it").WaitAsync(TimeSpan.FromSeconds(15)));
        Assert.Equal(ChatSession.UnconfirmedMark, rig.Chat.Messages.Last(m => m.Role == Role.User).Error);
        Assert.Equal(0, store.Count(rig.Client.AccountId));
    }
}
