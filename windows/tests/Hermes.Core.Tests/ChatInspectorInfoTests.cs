using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hermes.Core.Rpc;
using Hermes.Core.Sessions;
using Xunit;

namespace Hermes.Core.Tests;

/// [WIN-INSPECTOR-INFO-ROWS] The inspector's Info tab (MacInspector `.info` → AppModel.makeInfoContent →
/// ChatInfoSheet.makeContent, a ChatInfoList with `panel` on the Mac): the face and the chat's name ("This chat" when
/// blank), the same rows Chat Info shows (`ChatInfoRows.Rows`, with the bot profile's model when the stored row names
/// none), and Copy Chat Info with the sheet's text; "No Info" / "This chat has nothing to show yet." when there are no
/// rows. Synthetic data only.
public class ChatInspectorInfoTests
{
    private static SidebarSessionRow Stored(string json) => SidebarSessionRow.From(JsonNode.Parse(json))!;

    private static readonly SidebarSessionRow Listed = Stored("""
        {"id":"s1","profile":"research","source":"telegram","model":"anthropic/claude-opus-5.5","message_count":14,"cwd":"/Users/me/reading",
         "git_branch":"main","input_tokens":14200,"output_tokens":1200,"estimated_cost_usd":0.0042}
        """);

    [Fact]
    public void TheInfoTabShowsChatInfosRowsForTheStoredRow()
    {
        var content = ChatInfoPanel.Content("Reading list", "research", Listed, "s1", "openai/gpt-9", "Research", "gateway.example.com", "Connected");
        Assert.NotNull(content);
        var expected = ChatInfoRows.Rows(Listed, "Research", "gateway.example.com", "Connected");
        Assert.Equal(expected, content!.Rows);
        Assert.Equal(["Model", "Tokens", "Cost", "Messages", "Folder", "Bot", "Source", "Gateway", "Chat ID"], content.Rows.Select(r => r.Label));
        // The stored row's model wins over the bot profile's (SessionInfoSheetSource.rows: the roster's only when none).
        Assert.Equal("claude-opus-5.5", content.Rows[0].Value);
        Assert.Equal("Reading list", content.Name);
        Assert.Equal("research", content.Profile);
        Assert.Equal(ChatInfoRows.CopyText(expected, "research"), content.CopyText);
    }

    [Fact]
    public void AChatTheListDoesNotHoldShowsTheBotProfilesModel()
    {
        // Mac: "A chat not resumed yet and not listed: the model its roster names."
        var content = ChatInfoPanel.Content("  ", "research", null, "s9", "openai/gpt-9", "Research", "gateway.example.com", "Offline")!;
        Assert.Equal("This chat", content.Name);
        Assert.Equal(["Model", "Bot", "Gateway", "Chat ID"], content.Rows.Select(r => r.Label));
        Assert.Equal("gpt-9", content.Rows[0].Value);
        Assert.Equal(new ChatInfoRow("Gateway", "gateway.example.com", "Offline"), content.Rows[2]);
        Assert.Equal(new ChatInfoRow("Chat ID", "s9", null, true), content.Rows[3]);

        // A listed row without a model takes the profile's too; a blank profile model adds no line.
        var bare = Listed with { Model = null };
        Assert.Equal("gpt-9", ChatInfoPanel.Content("t", "research", bare, "s1", "openai/gpt-9", "Research", "h", "Connected")!.Rows[0].Value);
        Assert.DoesNotContain(ChatInfoPanel.Content("t", "research", bare, "s1", "  ", "Research", "h", "Connected")!.Rows, r => r.Label == "Model");
    }

    [Fact]
    public void ABlankChatIdHasNoChatIdRow()
    {
        // SessionInfoRows.rows: Chat ID only when the id has text.
        var content = ChatInfoPanel.Content("t", "research", null, "", null, "Research", "h", "Connected")!;
        Assert.Equal(["Bot", "Gateway"], content.Rows.Select(r => r.Label));
    }

    [Fact]
    public void TheEmptyStateAndHeaderWordsAreTheMacs()
    {
        Assert.Equal("No Info", ChatInfoPanel.EmptyTitle);
        Assert.Equal("This chat has nothing to show yet.", ChatInfoPanel.EmptyHint);
        Assert.Equal("This chat", ChatInfoPanel.Name(null));
        Assert.Equal("Plans", ChatInfoPanel.Name("  Plans \n"));
        Assert.Equal("Copy Chat Info", ChatInfoRows.CopyAll);
    }

    [Fact]
    public void TheGatewayNoteIsTheMacsWords()
    {
        Assert.Equal("Connected", ChatInfoPanel.GatewayNote(ConnectionState.Open));
        Assert.Equal("Connecting…", ChatInfoPanel.GatewayNote(ConnectionState.Connecting));
        Assert.Equal("Offline", ChatInfoPanel.GatewayNote(ConnectionState.Offline));
        Assert.Equal("Signed Out", ChatInfoPanel.GatewayNote(ConnectionState.SignedOut));
    }

    [Fact]
    public void CopyNamesTheBotAsTheMacDoes()
    {
        // SessionInfoRows: `Bot: Bike Shop (bike-shop)` when the name differs from the id, else `Bot: shown`.
        var rows = new List<ChatInfoRow> { new("Bot", "Bike Shop"), new("Chat ID", "s1", null, true) };
        Assert.Equal("Bot: Bike Shop (bike-shop)\nChat ID: s1", ChatInfoRows.CopyText(rows, "bike-shop"));
        Assert.Equal("Bot: research", ChatInfoRows.CopyText([new("Bot", "research")], "research"));
    }

    // ------------------------------------------------------------------ the tab's source

    private static string WindowsDir()
    {
        var dir = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(dir, "HermesHQ.sln"))) dir = Path.GetDirectoryName(dir) ?? throw new InvalidOperationException("no windows dir");
        return dir;
    }

    private static string InfoMethod()
    {
        var text = File.ReadAllText(Path.Combine(WindowsDir(), "src", "HermesHQ.Windows", "Features", "Transcript", "ChatInspector.cs")).Replace("\r\n", "\n");
        var start = text.IndexOf("    // MARK: Info\n", StringComparison.Ordinal);
        var end = text.IndexOf("    // MARK: Steps\n", StringComparison.Ordinal);
        Assert.True(start >= 0 && end > start, "ChatInspector.cs has no MARK: Info … MARK: Steps section");
        return text[start..end];
    }

    [Fact]
    public void TheInfoTabDrawsChatInfoPanelNotItsOwnRows()
    {
        var info = InfoMethod();
        Assert.Contains("ChatInfoPanel.Content(", info);
        Assert.Contains("ChatInfoPanel.EmptyTitle", info);
        Assert.Contains("ChatInfoPanel.EmptyHint", info);
        Assert.Contains("ChatInfoRows.CopyAll", info);
        Assert.Contains(".CopyText", info);
        // The invented rows are gone.
        foreach (var invented in new[] { "\"Title\"", "\"Started\"", "\"Last Message\"", "\"Session\"" })
            Assert.DoesNotContain(invented, info);
        Assert.Matches(new Regex(@"BotHead"), info);
    }
}
