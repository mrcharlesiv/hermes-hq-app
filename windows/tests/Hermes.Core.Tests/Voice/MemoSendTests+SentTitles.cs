// [WIN-SENT-TITLES] The title in the chat itself (docs/spec/3x-presence.md §10, DECISION D29; 93f984bb1
// Tests/Presence/SentTitlesTests.swift TitledRequestChatTests): from the cache at the first paint, on every history read
// (the newest page and older pages), out again as the whole request when its title comes back to the main bot's field,
// and Check finds a titled send by the request it stands for. And the gateway's inflight prompt clears a "Delivery
// unconfirmed" mark and its kept lost send (LiveChatSession+Sync.swift graftInflightTurn, 04 §2.5).
//
// Ported: aRefusedRequestComesBackAsItsTitleAndGoesOutWholeAgain, theCachedPaintShowsTheTitle.
// aRequestPutInAChatThatIsStillOpeningGoesOut is the Mac's pre-open send queue, which Windows' send has no counterpart
// of (its send resumes on its own). Added: the newest and older pages keep the title, a title in another bot's chat
// goes as typed (the Mac's `profile == "default"`), Check finds a titled send, the Bot Screen setup request keeps its
// title, and the inflight cases (the same words clear, other words keep the mark).
// On the loopback stand-in of the memo cases; synthetic data only.

using System.Text.Json.Nodes;
using Hermes.Core.Chat;
using Hermes.Core.Model;
using Hermes.Core.Screen;
using Hermes.Core.Sessions;

namespace Hermes.Core.Tests.Voice;

public sealed partial class MemoSendTests
{
    private const string TitledPrompt = "Please install the otto add-on on this Hermes.\n\n1. Fetch it from https://example.com/otto.zip.\n2. Restart   the gateway.";
    private const string TitledTitle = "Install the otto add-on.";

    private static JsonObject UserRow(string content, long row, long at = 1_791_590_002) =>
        new() { ["role"] = "user", ["content"] = content, ["row_id"] = row, ["timestamp"] = at };

    private static JsonObject ReplyRow(string content, long row, long at = 1_791_590_003) =>
        new() { ["role"] = "assistant", ["content"] = content, ["row_id"] = row, ["timestamp"] = at };

    /// The gateway refuses the request: the field gets the title back (never the long prompt), and sending that from
    /// the main bot's field sends the whole request again, under the same title.
    [Fact]
    public async Task ARefusedRequestComesBackAsItsTitleAndGoesOutWholeAgain()
    {
        await using var rig = new Rig(_stores, profile: "default");
        await rig.Ready();
        rig.Chat.SentTitles.Note(TitledPrompt, TitledTitle);
        rig.Socket.OnCall((method, p, attempt) => method == "prompt.submit" ? throw new Refuse(5000, "Refused for the test") : Loopback.Default(method, p, attempt));
        Assert.Equal(SendOutcome.Refused, await Within(rig.Chat.SendAsync(TitledPrompt, display: TitledTitle)));
        Assert.Equal(TitledTitle, Assert.Single(rig.Drafts).Text);                 // the title comes back, not the long prompt
        Assert.Equal(TitledPrompt, rig.Socket.Calls("prompt.submit")[0].Str("text"));

        rig.Socket.OnCall(Loopback.Default);
        Assert.Equal(SendOutcome.Accepted, await Within(rig.Chat.SendAsync(TitledTitle)));   // Send on what came back
        var submits = rig.Socket.Calls("prompt.submit");
        Assert.Equal(2, submits.Count);
        Assert.Equal(TitledPrompt, submits[^1].Str("text"));                       // the title goes out as its request
        Assert.Equal(TitledTitle, rig.Chat.Messages.Last(m => m.Role == Role.User).Text);   // its bubble still shows the title
        // Anything else typed is sent as typed.
        Assert.Null(rig.Chat.SentTitles.Prompt("Install the otto add-on"));
        Assert.Equal(SendOutcome.Accepted, await Within(rig.Chat.SendAsync("Install the otto add-on")));
        Assert.Equal("Install the otto add-on", rig.Socket.Calls("prompt.submit")[^1].Str("text"));
    }

    /// The Mac maps a returned title only in the main bot's chat: in another bot's chat the words go as typed.
    [Fact]
    public async Task ATitleInAnotherBotsChatGoesAsTyped()
    {
        await using var rig = new Rig(_stores);                                   // "ivy"
        await rig.Ready();
        rig.Chat.SentTitles.Note(TitledPrompt, TitledTitle);
        Assert.Equal(SendOutcome.Accepted, await Within(rig.Chat.SendAsync(TitledTitle)));
        Assert.Equal(TitledTitle, Assert.Single(rig.Socket.Calls("prompt.submit")).Str("text"));
    }

    /// The reply's read (and any later read) brings the stored row, which holds the whole request: the bubble keeps its
    /// title, once (the stored row is the local bubble's, not a second one), and so do older pages.
    [Fact]
    public async Task AReadKeepsTheTitleOnTheNewestAndOlderPages()
    {
        await using var rig = new Rig(_stores, profile: "default");
        rig.Socket.History = LostRows();
        rig.Socket.Older = [UserRow(TitledPrompt, 4, 1_791_589_000), ReplyRow("Installed.", 5, 1_791_589_001)];
        await rig.Ready();
        rig.Chat.SentTitles.Note(TitledPrompt, TitledTitle);
        await rig.Chat.RefreshAsync();
        Assert.Equal(SendOutcome.Accepted, await Within(rig.Chat.SendAsync(TitledPrompt, display: TitledTitle)));
        // The gateway stored it with its whitespace flattened (as it keeps a row), and the turn ended.
        rig.Socket.History = Rows(UserRow(SentTitles.Flat(TitledPrompt), 42), ReplyRow("On it.", 43));
        await rig.Chat.RefreshAsync();
        var users = rig.Chat.Messages.Where(m => m.Role == Role.User).Select(m => m.Text).ToList();
        Assert.Equal(["first", TitledTitle], users);
        Assert.DoesNotContain(rig.Chat.Messages, m => m.Text.Contains("example.com", StringComparison.Ordinal));
        await rig.Chat.LoadOlderAsync();
        Assert.Equal([TitledTitle, "first", TitledTitle], rig.Chat.Messages.Where(m => m.Role == Role.User).Select(m => m.Text));
    }

    /// The chat opens from its cache before the gateway answers: a cached row that holds the stored prompt paints as
    /// its title (after a relaunch, or when another device sent it).
    [Fact]
    public async Task TheCachedPaintShowsTheTitle()
    {
        var cache = new FileTranscriptCache(Directory.CreateTempSubdirectory("sent-titles-cache-").FullName);
        await using var rig = new Rig(_stores, profile: "default", cache: cache);
        rig.Chat.SentTitles.Note(TitledPrompt, TitledTitle);
        cache.Write(rig.Client.AccountId, "default", LostStored,
        [
            new ChatMessage("row-1", Role.User, [new TextPart(TitledPrompt)], DateTimeOffset.FromUnixTimeSeconds(10), RowId: 1),
            new ChatMessage("row-2", Role.Assistant, [new TextPart("Installed.")], DateTimeOffset.FromUnixTimeSeconds(11), RowId: 2),
        ]);
        // The first change that shows rows is the cache paint (the read starts after it); other changes (the socket
        // coming up) show none.
        IReadOnlyList<ChatMessage>? painted = null;
        rig.Chat.Changed += () =>
        {
            var now = rig.Chat.Messages;
            if (now.Count > 0) Interlocked.CompareExchange(ref painted, now, null);
        };
        rig.Socket.History = [UserRow(TitledPrompt, 1, 10), ReplyRow("Installed.", 2, 11)];
        await rig.Client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(15)).Token);
        await rig.Chat.OpenAsync();
        Assert.NotNull(painted);
        Assert.Equal(TitledTitle, painted!.First(m => m.Role == Role.User).Text);   // the first paint
        Assert.Equal(TitledTitle, rig.Chat.Messages.First(m => m.Role == Role.User).Text);   // and the read after it
    }

    /// Check looks for a titled send by the request it stands for (the stored row holds that, not the bubble's words).
    [Fact]
    public async Task CheckFindsATitledSend()
    {
        await using var rig = new Rig(_stores, profile: "default");
        rig.Socket.History = LostRows();
        await rig.Ready();
        await rig.Chat.RefreshAsync();
        rig.Chat.SentTitles.Note(TitledPrompt, TitledTitle);
        LosePrompts(rig);
        Assert.Equal(SendOutcome.Unconfirmed, await Within(rig.Chat.SendAsync(TitledPrompt, display: TitledTitle)));
        var bubble = rig.Chat.Messages.Last(m => m.Role == Role.User);
        Assert.Equal((TitledTitle, ChatSession.UnconfirmedMark), (bubble.Text, bubble.Error));
        rig.Socket.History = Rows(UserRow(SentTitles.Flat(TitledPrompt), 12));
        Assert.True(await rig.Chat.CheckDeliveryAsync(bubble.Id));
        Assert.DoesNotContain(rig.Chat.Messages, m => m.Error != null);
    }

    /// Windows' titled request today, the Bot Screen setup request (ChatComposer.SendScreenSetup), goes through the
    /// chat's SentTitles: the read after it keeps the short title rather than the long installer prompt.
    [Fact]
    public async Task TheScreenSetupRequestKeepsItsTitle()
    {
        await using var rig = new Rig(_stores);
        rig.Socket.History = LostRows();
        await rig.Ready();
        await rig.Chat.RefreshAsync();
        var bundle = new ScreenSetupBundle(ScreenSetupBundle.Filename, "data:application/zip;base64,AA==", "abc123", ScreenSetupBundle.HelperAppPath);
        rig.Composer.SendScreenSetup("@file:/Users/me/.hermes/uploads/setup.zip", bundle);
        var sent = await Until(() => rig.Socket.Calls("prompt.submit").Count == 1);
        Assert.True(sent);
        var text = rig.Socket.Calls("prompt.submit")[0].Str("text")!;
        Assert.StartsWith(ScreenSetupPrompt.Text, text, StringComparison.Ordinal);
        Assert.Equal(text, rig.Chat.SentTitles.Prompt(ScreenSetupPrompt.QueueTitle));
        rig.Socket.History = Rows(UserRow(text, 42), ReplyRow("Set up.", 43));
        await rig.Chat.RefreshAsync();
        Assert.Equal(["first", ScreenSetupPrompt.QueueTitle], rig.Chat.Messages.Where(m => m.Role == Role.User).Select(m => m.Text));
    }

    /// An answer to `session.resume` / `session.activate` naming a running turn's prompt.
    private static JsonObject InflightAnswer(string user) => new()
    {
        ["session_id"] = VoiceFakeClient.Rid, ["running"] = true,
        ["inflight"] = new JsonObject { ["user"] = user, ["assistant"] = "" },
    };

    /// A send whose ack was lost with the link: when the chat binds again, the gateway's inflight prompt is that send,
    /// so it was delivered after all — the mark and the kept lost send go (graftInflightTurn).
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task TheGatewaysInflightPromptClearsALostSend(bool titled)
    {
        var store = new LostSends(LostFolder());
        await using var rig = new Rig(_stores, profile: "default");
        rig.Chat.LostSends = store;
        rig.Socket.History = LostRows();
        await rig.Ready();
        await rig.Chat.RefreshAsync();
        if (titled) rig.Chat.SentTitles.Note(TitledPrompt, TitledTitle);
        var sentText = titled ? TitledPrompt : "  call the plumber ";
        rig.Socket.OnCall((method, p, attempt) => method switch
        {
            "prompt.submit" => throw new DropLink(),
            "session.resume" or "session.activate" => InflightAnswer(titled ? SentTitles.Flat(TitledPrompt) : "call the plumber"),
            _ => Loopback.Default(method, p, attempt),
        });
        var outcome = await Within(titled ? rig.Chat.SendAsync(sentText, display: TitledTitle) : rig.Chat.SendAsync(sentText));
        Assert.Equal(SendOutcome.Unconfirmed, outcome);
        var account = rig.Client.AccountId;
        Assert.Single(store.Entries(account, "default", LostStored));
        Assert.True(await Until(() => rig.Chat.Messages.All(m => m.Error == null), 15));
        Assert.Empty(store.Entries(account, "default", LostStored));
        Assert.Single(rig.Socket.Calls("prompt.submit"));                           // never resent
    }

    /// The running turn is another prompt: the send may still be lost, so its mark and entry stay.
    [Fact]
    public async Task AnotherInflightPromptKeepsTheMark()
    {
        var store = new LostSends(LostFolder());
        await using var rig = new Rig(_stores, profile: "default");
        rig.Chat.LostSends = store;
        rig.Socket.History = LostRows();
        await rig.Ready();
        await rig.Chat.RefreshAsync();
        rig.Socket.OnCall((method, p, attempt) => method switch
        {
            "prompt.submit" => throw new DropLink(),
            "session.resume" or "session.activate" => InflightAnswer("something else"),
            _ => Loopback.Default(method, p, attempt),
        });
        Assert.Equal(SendOutcome.Unconfirmed, await Within(rig.Chat.SendAsync("call the plumber")));
        var binds = rig.Socket.Calls("session.resume").Count + rig.Socket.Calls("session.activate").Count;
        Assert.True(await Until(() => rig.Socket.Calls("session.resume").Count + rig.Socket.Calls("session.activate").Count > binds, 15));
        await Task.Delay(300);
        Assert.Equal(ChatSession.UnconfirmedMark, rig.Chat.Messages.Single(m => m.Text == "call the plumber").Error);
        // [WIN-INFLIGHT-GRAFT] and the running turn's prompt shows under it (the Mac's "local-user-inflight-" bubble)
        Assert.StartsWith("local-user-inflight-", rig.Chat.Messages.Last(m => m.Role == Role.User).Id, StringComparison.Ordinal);
        Assert.Single(store.Entries(rig.Client.AccountId, "default", LostStored));
    }
}
