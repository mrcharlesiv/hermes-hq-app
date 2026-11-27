// [WIN-EXTERNAL-TURN] The pure rules of a turn another Hermes process runs in this chat (93f984bb1
// HermesKit/Chat/ExternalTurn.swift, docs/spec/03-chat-history.md §4.8). Ported case for case from
// Tests/Chat/ExternalTurnTests.swift historyRules and ledgerRows; the open-chat cases (storedRowsShowTheGatewaysTurnUntilItsReply,
// ledgerDecidesWhenTheAddOnHasIt, aWaitingSendWatchesTheGatewaysTurn) are in Voice/MemoSendTests+External.cs, on the
// loopback stand-in. Synthetic data only.

using System.Text.Json.Nodes;
using Hermes.Core.Chat;
using Hermes.Core.Model;

namespace Hermes.Core.Tests;

public sealed class ExternalTurnTests
{
    private static ChatMessage Message(Role role, ChatPart[] parts, string id) => new(id, role, parts);

    private static ChatPart Tool(string name) => new ToolPart(new ToolCall($"c-{name}", name, null, null, ToolState.Done));

    [Fact]
    public void HistoryRules()
    {
        var now = DateTimeOffset.UtcNow;
        var fresh = now.AddSeconds(-30);
        var old = now.AddSeconds(-3600);
        var prompt = Message(Role.User, [new TextPart("Hermes, a brief from Herald")], "stored-row-1-user");
        var steps = Message(Role.Assistant, [Tool("skill_view"), Tool("search_files")], "stored-row-2-tools");
        var reply = Message(Role.Assistant, [Tool("search_files"), new TextPart("Done: here it is.")], "stored-row-3-assistant");
        var silent = Message(Role.System, [new TextPart("Nothing to report — this run was silent")], "stored-row-4-system");
        var mine = Message(Role.User, [new TextPart("mine")], "local-9");

        // Steps with nothing after them, written recently: still running.
        Assert.True(ExternalTurn.HistoryUnfinished([prompt, steps], fresh, now));
        // Our own waiting bubble (not stored) doesn't hide it.
        Assert.True(ExternalTurn.HistoryUnfinished([prompt, steps, mine], fresh, now));
        // A prompt nobody answered yet, seconds ago: the gateway is on it.
        Assert.True(ExternalTurn.HistoryUnfinished([prompt], fresh, now));
        // A finished reply, a [SILENT] end, or stale rows: nothing runs.
        Assert.False(ExternalTurn.HistoryUnfinished([prompt, reply], fresh, now));
        Assert.False(ExternalTurn.HistoryUnfinished([prompt, steps, silent], fresh, now));
        Assert.False(ExternalTurn.HistoryUnfinished([prompt, steps], old, now));
        Assert.False(ExternalTurn.HistoryUnfinished([prompt], now.AddSeconds(-300), now));
        Assert.False(ExternalTurn.HistoryUnfinished([prompt, steps], null, now));
        var failed = steps with { Error = "provider error" };
        Assert.False(ExternalTurn.HistoryUnfinished([prompt, failed], fresh, now));
    }

    /// Windows' own parts on top of the Mac's three: a thought with nothing after it still runs; blank words don't end
    /// it; a stopped reply has ended.
    [Fact]
    public void HistoryRulesOnWindowsParts()
    {
        var now = DateTimeOffset.UtcNow;
        var fresh = now.AddSeconds(-30);
        var prompt = Message(Role.User, [new TextPart("[From herald] Please review the brief.")], "stored-row-1-user");
        Assert.True(ExternalTurn.HistoryUnfinished([prompt, Message(Role.Assistant, [Tool("terminal"), new ReasoningPart("checking")], "r")], fresh, now));
        Assert.True(ExternalTurn.HistoryUnfinished([prompt, Message(Role.Assistant, [Tool("terminal"), new TextPart("  \n")], "r")], fresh, now));
        Assert.False(ExternalTurn.HistoryUnfinished([prompt, Message(Role.Assistant, [Tool("terminal")], "r") with { Interrupted = true }], fresh, now));
        Assert.False(ExternalTurn.HistoryUnfinished([prompt, Message(Role.Assistant, [], "r")], fresh, now));
        Assert.False(ExternalTurn.HistoryUnfinished([], fresh, now));
    }

    [Fact]
    public void LedgerRows()
    {
        var json = JsonNode.Parse("""
            {"sessions": [{"profile": "default", "id": "a", "status": "started", "kind": "admission"},
                          {"profile": "herald", "id": "b", "status": "queued", "kind": "admission"}]}
            """);
        Assert.True(ExternalTurn.LedgerNames(json, ["a"], "default"));
        Assert.True(ExternalTurn.LedgerNames(json, ["x", "a"], ""));
        Assert.False(ExternalTurn.LedgerNames(json, ["b"], "default"));
        Assert.True(ExternalTurn.LedgerNames(json, ["b"], "herald"));
        Assert.False(ExternalTurn.LedgerNames(JsonNode.Parse("""{"sessions": []}"""), ["a"], "default"));
    }

    [Fact]
    public void TheMacsWindowsAndRoute()
    {
        Assert.Equal("/api/plugins/hermes-hq-push/sessions/working", ExternalTurn.LedgerPath);
        Assert.Equal(TimeSpan.FromSeconds(600), ExternalTurn.ToolWindow);
        Assert.Equal(TimeSpan.FromSeconds(120), ExternalTurn.PromptWindow);
        Assert.Equal(TimeSpan.FromSeconds(600), ExternalTurn.MissingRecheck);
        Assert.Equal(TimeSpan.FromSeconds(3), ExternalTurn.DefaultPollInterval);
        Assert.Equal("Working…", ExternalTurn.StatusWords);
    }
}
