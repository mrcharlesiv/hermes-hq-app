// [WIN-EXTERNAL-TURN] "Herald messaged Hermes and I can't see that anything is happening" (a tester): a turn the
// messaging gateway runs in an open chat shows Working…, its steps land as they're written, and Working… ends with it
// (93f984bb1 HermesKit/Chat/LiveChatSession+External.swift, docs/spec/03-chat-history.md §4.8; ChatSession+External.cs).
// On the same loopback stand-in as the memo and owner-wait cases, synthetic data only.
//
// Ported case for case from Tests/Chat/ExternalTurnTests.swift: storedRowsShowTheGatewaysTurnUntilItsReply,
// ledgerDecidesWhenTheAddOnHasIt, aWaitingSendWatchesTheGatewaysTurn (the pure rules are in ../ExternalTurnTests.cs).
// Adapted: Windows' chat has no `sessions.changed` changed pass, so ledgerDecidesWhenTheAddOnHasIt's second start comes
// from a history read that brings new rows (RefreshAsync, the Mac's "new rows" hook), and `stopObserving` is the
// chat's DisposeAsync (the screen going away). Added: theOwnerWaitEndsWhenTheWatchSeesTheTurnEnd (`waitForOwner` waking
// on `externalEnds`), aTurnOfOursEndsTheWatch.

using System.Diagnostics;
using System.Text.Json.Nodes;
using Hermes.Core.Chat;
using Hermes.Core.Model;

namespace Hermes.Core.Tests.Voice;

public sealed partial class MemoSendTests
{
    private const string Stored = "20260929_120000_aabbcc02";

    /// Two earlier rows of an ordinary finished exchange.
    private static JsonArray BaseRows(double t) =>
    [
        new JsonObject { ["role"] = "user", ["content"] = "What's on for today?", ["row_id"] = 9001, ["timestamp"] = t - 4000 },
        new JsonObject { ["role"] = "assistant", ["content"] = "Nothing on the synthetic calendar.", ["row_id"] = 9002, ["timestamp"] = t - 3990 },
    ];

    /// The delivery prompt and the steps the gateway wrote so far (tool calls, no words yet).
    private static JsonArray DeliveryRows(double t)
    {
        var rows = BaseRows(t);
        rows.Add(new JsonObject
        {
            ["role"] = "user", ["content"] = "[From herald] Please review the brief.", ["row_id"] = 9100, ["timestamp"] = t,
            ["display_kind"] = "internal_notification",
        });
        rows.Add(new JsonObject
        {
            ["role"] = "assistant", ["content"] = "", ["row_id"] = 9101, ["timestamp"] = t + 13,
            ["tool_calls"] = new JsonArray(new JsonObject
            {
                ["id"] = "call-1", ["type"] = "function",
                ["function"] = new JsonObject { ["name"] = "search_files", ["arguments"] = """{"pattern": "brief"}""" },
            }),
        });
        rows.Add(new JsonObject { ["role"] = "tool", ["content"] = """{"matches": []}""", ["row_id"] = 9102, ["timestamp"] = t + 14, ["tool_call_id"] = "call-1" });
        rows.Add(new JsonObject
        {
            ["role"] = "assistant", ["content"] = "", ["row_id"] = 9103, ["timestamp"] = t + 16,
            ["tool_calls"] = new JsonArray(new JsonObject
            {
                ["id"] = "call-2", ["type"] = "function",
                ["function"] = new JsonObject { ["name"] = "terminal", ["arguments"] = """{"command": "ls"}""" },
            }),
        });
        return rows;
    }

    private static JsonArray FinishedRows(double t)
    {
        var rows = DeliveryRows(t);
        rows.Add(new JsonObject { ["role"] = "tool", ["content"] = """{"stdout": "brief.md", "exit_code": 0}""", ["row_id"] = 9104, ["timestamp"] = t + 40, ["tool_call_id"] = "call-2" });
        rows.Add(new JsonObject { ["role"] = "assistant", ["content"] = "Reviewed Herald's brief.", ["row_id"] = 9105, ["timestamp"] = t + 45 });
        return rows;
    }

    private static double Now => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;

    /// The ledger naming (or not) this chat for ivy.
    private static JsonNode LedgerAnswer(bool working) => new JsonObject
    {
        ["sessions"] = working
            ? new JsonArray(new JsonObject { ["profile"] = "ivy", ["id"] = Stored, ["status"] = "started", ["kind"] = "admission" })
            : new JsonArray(),
    };

    private static async Task OpenChat(Rig rig)
    {
        ExternalTurn.ForgetMissingLedgers();
        rig.Chat.ExternalPollInterval = TimeSpan.FromMilliseconds(40);
        await rig.Client.Rpc.WhenReadyAsync(new CancellationTokenSource(TimeSpan.FromSeconds(15)).Token);
        await rig.Chat.OpenAsync().WaitAsync(TimeSpan.FromSeconds(15));
    }

    /// No add-on route (404): the stored rows decide. The chat opens on a turn the gateway is running: Working…, the
    /// steps drawn, and the reply when it lands, with Working… gone.
    [Fact]
    public async Task StoredRowsShowTheGatewaysTurnUntilItsReply()
    {
        await using var rig = new Rig(_stores);
        var t = Now - 20;
        rig.Socket.History = DeliveryRows(t);
        var reported = new List<bool>();
        rig.Chat.ExternalWorkChanged += on => { lock (reported) reported.Add(on); };
        await OpenChat(rig);
        Assert.True(await Until(() => rig.Chat.ExternalWorking));
        Assert.Equal("Working…", rig.Chat.Status);
        Assert.False(rig.Chat.Busy);                                  // the composer keeps Send: a send joins the gateway's queue
        Assert.Contains(rig.Chat.Messages[^1].Parts, p => p is ToolPart);
        lock (reported) Assert.Equal([true], reported);
        rig.Socket.History = FinishedRows(t);
        Assert.True(await Until(() => !rig.Chat.ExternalWorking));
        Assert.True(await Until(() => rig.Chat.Messages.Any(m => m.Text.Contains("Reviewed Herald's brief."))));
        Assert.Null(rig.Chat.Status);
        lock (reported) Assert.Equal([true, false], reported);
        Assert.True(rig.Socket.LedgerReads > 0);
    }

    /// The add-on's ledger is the word when present: Working… while it names the chat, even over rows that look done;
    /// and leaving the chat ends it.
    [Fact]
    public async Task LedgerDecidesWhenTheAddOnHasIt()
    {
        await using var rig = new Rig(_stores);
        var old = Now - 7200;                                       // rows alone would say "done long ago"
        var rows = DeliveryRows(old);
        var working = true;
        rig.Socket.Ledger = () => LedgerAnswer(Volatile.Read(ref working));
        rig.Socket.History = rows;
        await OpenChat(rig);
        Assert.True(await Until(() => rig.Chat.ExternalWork == ExternalTurn.Source.Ledger));
        Assert.Equal("Working…", rig.Chat.Status);
        Volatile.Write(ref working, false);
        Assert.True(await Until(() => !rig.Chat.ExternalWorking));
        Volatile.Write(ref working, true);
        var more = (JsonArray)rows.DeepClone();
        more.Add(new JsonObject { ["role"] = "tool", ["content"] = "{}", ["row_id"] = 9104, ["timestamp"] = old + 1, ["tool_call_id"] = "call-2" });
        rig.Socket.History = more;
        await rig.Chat.RefreshAsync();                              // a read that brings rows another process wrote
        Assert.True(await Until(() => rig.Chat.ExternalWorking));
        await rig.Chat.DisposeAsync();                              // the screen goes away
        Assert.False(rig.Chat.ExternalWorking);
        var reads = rig.Socket.LedgerReads;
        await Task.Delay(300);
        Assert.Equal(reads, rig.Socket.LedgerReads);                // nothing reads on for a chat no one sees
    }

    /// A send refused because the gateway runs a turn here (`SESSION_OWNER_BUSY`) waits, and the gateway's steps keep
    /// landing above it; the header keeps the wait's words.
    [Fact]
    public async Task AWaitingSendWatchesTheGatewaysTurn()
    {
        await using var rig = new Rig(_stores);
        var t = Now - 20;
        rig.Socket.History = DeliveryRows(t);
        await OpenChat(rig);
        Assert.True(await Until(() => rig.Chat.ExternalWorking));
        rig.Socket.OnCall((method, p, attempt) => method == "prompt.submit" ? throw OwnerBusyRefusal() : Loopback.Default(method, p, attempt));
        var sending = rig.Chat.SendAsync("mine");
        Assert.True(await Until(() => rig.Chat.OwnerWaitNotice == OwnerWait.RunningReply));
        Assert.Equal(OwnerWait.RunningReply.Status, rig.Chat.Status);
        Assert.True(await Until(() => rig.Chat.ExternalWorking));    // still watched while ours waits
        rig.Socket.History = FinishedRows(t);
        Assert.True(await Until(() => rig.Chat.Messages.Any(m => m.Text.Contains("Reviewed Herald's brief."))));
        var messages = rig.Chat.Messages;
        var reply = messages.ToList().FindLastIndex(m => m.Text.Contains("Reviewed Herald's brief."));
        var mine = messages.ToList().FindLastIndex(m => m.Role == Role.User && m.Text == "mine");
        Assert.True(mine >= 0);
        Assert.True(reply < mine);
        await rig.Chat.CancelOwnerWaitAsync();
        Assert.Equal(SendOutcome.Refused, await sending.WaitAsync(TimeSpan.FromSeconds(10)));
    }

    /// The owner wait's pause ends as soon as the watch sees the other run end (`waitForOwner` on `externalEnds`), not
    /// after the whole pause.
    [Fact]
    public async Task TheOwnerWaitEndsWhenTheWatchSeesTheTurnEnd()
    {
        await using var rig = new Rig(_stores);
        var working = true;
        rig.Socket.Ledger = () => LedgerAnswer(Volatile.Read(ref working));
        rig.Socket.History = DeliveryRows(Now - 20);
        await OpenChat(rig);
        Assert.True(await Until(() => rig.Chat.ExternalWork == ExternalTurn.Source.Ledger));
        rig.Chat.OwnerRetryInterval = TimeSpan.FromSeconds(30);     // a pause far longer than the test waits
        rig.Socket.OnCall((method, p, attempt) => method == "prompt.submit"
            ? Volatile.Read(ref working) ? throw OwnerBusyRefusal() : new JsonObject { ["user_row_id"] = 9200 }
            : Loopback.Default(method, p, attempt));
        var sending = rig.Chat.SendAsync("mine");
        Assert.True(await Until(() => rig.Chat.WaitingForOwner == OwnerWait.RunningReply));
        Assert.Single(rig.Socket.Calls("prompt.submit"));
        var clock = Stopwatch.StartNew();
        Volatile.Write(ref working, false);
        Assert.Equal(SendOutcome.Accepted, await sending.WaitAsync(TimeSpan.FromSeconds(15)));
        Assert.True(clock.Elapsed < TimeSpan.FromSeconds(15), $"sent after {clock.Elapsed}");
        Assert.Equal(2, rig.Socket.Calls("prompt.submit").Count);
        Assert.Null(rig.Chat.WaitingForOwner);
    }

    /// A turn of ours starting ends the watch: that turn's own state says what runs from here.
    [Fact]
    public async Task ATurnOfOursEndsTheWatch()
    {
        await using var rig = new Rig(_stores);
        rig.Socket.History = DeliveryRows(Now - 20);
        await OpenChat(rig);
        Assert.True(await Until(() => rig.Chat.ExternalWorking));
        Assert.Equal(SendOutcome.Accepted, await rig.Chat.SendAsync("mine").WaitAsync(TimeSpan.FromSeconds(10)));
        Assert.True(rig.Chat.Busy);
        Assert.False(rig.Chat.ExternalWorking);
        Assert.NotEqual("Working…", rig.Chat.Status);
    }
}
