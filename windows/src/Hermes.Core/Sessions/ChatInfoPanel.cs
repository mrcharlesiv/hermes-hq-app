using Hermes.Core.Rpc;

namespace Hermes.Core.Sessions;

/// What the inspector's Info tab shows for a chat: its name, its bot's profile (the face), Chat Info's rows and the
/// text Copy Chat Info gives.
public sealed record ChatInfoPanelContent(string Name, string Profile, IReadOnlyList<ChatInfoRow> Rows, string CopyText);

/// [WIN-INSPECTOR-INFO-ROWS] The inspector's Info tab (App/Mac/MacInspector.swift `.info` → AppModel.makeInfoContent →
/// ChatInfoSheet.makeContent, App/Chat/ChatSheets.swift): the same rows as Chat Info (`ChatInfoRows.Rows`, which the
/// sidebar's Chat Info dialog also draws) for the chat's stored row, under the face and the chat's name ("This chat"
/// when blank), and Copy Chat Info with the same text. When the list does not hold the chat, or its row names no model,
/// the model line is the bot profile's (SessionInfoSheetSource.rows: "A chat not resumed yet and not listed: the model
/// its roster names"). The live half (Answered By, Reasoning, Context, Cache, Speed) waits for the chat's own state.
public static class ChatInfoPanel
{
    public const string EmptyTitle = "No Info";
    public const string EmptyHint = "This chat has nothing to show yet.";
    public const string Untitled = "This chat";

    public static string Name(string? title) => string.IsNullOrWhiteSpace(title) ? Untitled : title.Trim();

    /// The link's words as the Mac's Gateway note says them (SessionInfoRows.gatewayNote).
    public static string GatewayNote(ConnectionState state) => state switch
    {
        ConnectionState.Open => "Connected",
        ConnectionState.Offline => "Offline",
        ConnectionState.SignedOut => "Signed Out",
        _ => "Connecting…",
    };

    /// `listed`: the Sessions store's row for the chat, or null. `profileModel`: the bot profile's model id.
    public static ChatInfoPanelContent? Content(string? title, string profile, SidebarSessionRow? listed, string? storedId,
                                                string? profileModel, string botName, string gatewayHost, string gatewayState)
    {
        var row = listed ?? new SidebarSessionRow { Id = storedId?.Trim() ?? "", Profile = profile };
        if (string.IsNullOrWhiteSpace(row.Model) && !string.IsNullOrWhiteSpace(profileModel)) row = row with { Model = profileModel.Trim() };
        else if (string.IsNullOrWhiteSpace(row.Model) && row.Model != null) row = row with { Model = null };
        var rows = ChatInfoRows.Rows(row, botName, gatewayHost, gatewayState);
        if (rows.Count == 0) return null;
        return new ChatInfoPanelContent(Name(title), profile, rows, ChatInfoRows.CopyText(rows, profile));
    }
}
