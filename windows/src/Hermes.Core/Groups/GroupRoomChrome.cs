using Hermes.Core.Model;

namespace Hermes.Core.Groups;

// [groups] What an open room's screen shows around the transcript (App/Groups/GroupRoomChrome.swift,
// AppModel+Groups.swift `makeRoomScreen`; docs/spec/3x-groups.md §7.12–7.13): the group avatar's faces beside the title,
// the composer's Stop square while a round runs, the sender line over a member's reply (ChatRow.swift
// `showsSenderName`, TextLayout.swift `senderBubble`) in its name colour (ChatSenderPalette.swift). Headless: the
// Windows room page (Pages/GroupRoomPage.cs) draws it.
public static class GroupRoomChrome
{
    /// The composer's words before you type, as a bot chat's (`Message <title>`).
    public static string Placeholder(string room) => $"Message {room}";

    /// The title's group avatar: the room's first three seated members (`store.seated(room).prefix(3)`).
    public static IReadOnlyList<GroupRowModel.Face> Faces(GroupStore store, GroupRoom room) =>
        [.. store.Seated(room).Take(3).Select(s => new GroupRowModel.Face(s.Name, s.Head))];

    /// The room comes on screen: it is read (its sidebar row loses the bold and the dot) and its late replies are
    /// collected (`GroupRoomSession.start` from the chat's `viewWillAppear`).
    public static void Open(GroupRoomSession session) => session.Start();

    /// A run's longest pause between two of its messages (ChatPalette.swift `ChatMetrics.runSeconds`).
    public const double RunSeconds = Settings.ChatVisualTokens.RunSeconds;

    /// Two messages join a run (ChatRow.swift `joins`): both of the same role (never a system row), the same sender (a
    /// run is one sender's), no badges under the first (its Tapbacks end the run), and the second within 300 s of the
    /// first; an untimed pair joins.
    public static bool Joins(ChatMessage a, ChatMessage b) => Transcripts.MessageRuns.Joins(a, b);

    /// A member's name over its reply on the first bubble of its run (ChatRow.swift `applyRunsAndGaps`:
    /// `bubble.showsSenderName = bubble.sender != nil && !bubble.joinsAbove`). A bubble joins the one above when that is
    /// a bubble on the same side and the two messages join (`joins`); a day line between them is a row of its own, so
    /// the bubble under it joins nothing (`dayLineAbove`). Your own bubbles carry no name.
    public static bool ShowsSenderName(IReadOnlyList<ChatMessage> messages, int index, bool dayLineAbove = false)
    {
        if (index < 0 || index >= messages.Count || messages[index] is not { Role: not Role.User and not Role.System, Sender: not null } m) return false;
        if (dayLineAbove || index == 0) return true;
        var above = messages[index - 1];
        // The room log projects each member's entry as text. A blank/step-only entry had no
        // prose bubble to carry its name: don't consume the first painted byline on its behalf.
        return !Joins(above, m) || !above.Parts.OfType<TextPart>().Any(p => !string.IsNullOrWhiteSpace(p.Text));
    }

    /// The title's group avatar side (AppModel+Groups.swift `makeRoomScreen`: `GroupAvatarView(side: 34)`).
    public const double TitleAvatarSide = 34;

    // ------------------------------------------------------------------ the typing row

    /// A room's typing row at the transcript's newest end, one per member answering (ChatRow.swift: `.waiting(…, plain:
    /// true)`), the chat's waiting cell's id for a plain row (ChatCells.swift).
    public const string TypingId = "chat.typing";

    /// The counter beside a waiting row's words (WaitingCell `elapsed` / `tick`): nothing for the first 10 s, then
    /// "· 0:12", "· 1:05". A room's typing row is plain: it never shows one.
    public static string TypingTimer(int seconds, bool plain) =>
        plain || seconds < 10 ? "" : $"· {seconds / 60}:{seconds % 60:00}";

    // ------------------------------------------------------------------ the empty room

    /// RoomEmptyView's hint under the name and the members.
    public const string EmptyHint = "Everyone here sees what you send. Type @ to ask one bot.";

    /// The room draws no rows: no messages and no one typing (the chat's `setEmpty`).
    public static bool IsEmpty(IReadOnlyList<ChatMessage> messages, IReadOnlyList<RoomTyping> typing) => messages.Count == 0 && typing.Count == 0;

    // ------------------------------------------------------------------ ⋯

    /// One of the room's ⋯ items (`moreItems`): its id ("room.more.<id>"), title, and whether it is red.
    public sealed record MoreItem(string Id, string Title, bool Destructive = false)
    {
        public string AutomationId => "room.more." + Id;
    }

    /// The room's ⋯ menu in the Mac's sections (GroupRoomChrome.swift `moreItems`): Find in Chat, Group Info, Add Bots…
    /// (online, members not fixed), Prompts (the saved prompts go into this room's field as in a bot's chat), Activity;
    /// then Stop All while the room runs and Resume All while a bot is paused; then Delete Group Chat (online).
    public static IReadOnlyList<IReadOnlyList<MoreItem>> MoreItems(bool online, bool fixedMembers, bool running, bool paused)
    {
        var top = new List<MoreItem> { new("find", "Find in Chat"), new("info", "Group Info") };
        if (online && !fixedMembers) top.Add(new("add", "Add Bots…"));
        top.Add(new("prompts", "Prompts"));
        top.Add(new("activity", "Activity"));
        var out_ = new List<IReadOnlyList<MoreItem>> { top };
        var run = new List<MoreItem>();
        if (running) run.Add(new("stop", "Stop All"));
        if (paused) run.Add(new("resume", "Resume All"));
        if (run.Count > 0) out_.Add(run);
        if (online) out_.Add([new("delete", "Delete Group Chat", Destructive: true)]);
        return out_;
    }

    /// A send into a room with no members (GroupRoomChrome.swift `explain(.noMembers)`): the alert's title and words.
    public const string CantSendTitle = "Can’t Send";

    public static string CantSendMessage(string room) =>
        $"{room} has no members to send to — add a bot, or reopen the group chat if members are still loading.";

    /// The alert's buttons in order: Add Bots… while online and the members are not fixed, then OK.
    public static IReadOnlyList<string> CantSendButtons(bool online, bool fixedMembers) =>
        online && !fixedMembers ? ["Add Bots…", "OK"] : ["OK"];

    /// The name's colour on the light and the dark look (ChatSenderPalette.nameColor): the light look's is taken toward
    /// black until it reads 6:1 on the light bubble (Mac UI check L15), the dark look's is NameColor's 4.5:1 toward white.
    /// null: the label colour.
    public static (NameColor.Rgb Light, NameColor.Rgb Dark)? NameColor(string? hex)
    {
        if (hex == null || Groups.NameColor.Readable(hex) is not { } pair || Groups.NameColor.Parse(hex) is not { } raw) return null;
        var light = Groups.NameColor.Readable(raw, Groups.NameColor.LightBubble, new Groups.NameColor.Rgb(0, 0, 0), 6);
        return (light, pair.Dark);
    }

    /// The composer's button: the Stop square while the room runs (`chat.composer.isRunning = room.roomRunning`), else
    /// Send, with the Windows chat's glyphs and tips (Pages/ChatPage.xaml.cs `UpdateComposer`).
    public static (string Glyph, string Tip) SendButton(bool running) => running ? ("\uE71A", "Stop (Esc)") : ("\uE74A", "Send (Enter)");
}
