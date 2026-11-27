using System.Text.Json.Nodes;
using Hermes.Core.Model;
using Hermes.Core.Rpc;

namespace Hermes.Core.Groups;

// [groups] A room as the chat screen sees it (HermesKit/Groups/GroupRoomSession.swift; docs/spec/3x-groups.md §7.13,
// D7): the room log mapped to ChatMessages with their senders, the typing rows, the reply target, the paused and Stop
// state. It only reads GroupStore and asks GroupEngine: a round belongs to the account, not to this screen. Headless:
// the screen slice binds it. Not here yet: the members' questions and approvals (ChatPrompting, D6) and voice memos.

/// What changed in a room's rows (the Mac's ChatChange).
public abstract record RoomChange
{
    public sealed record Appended(IReadOnlyList<string> Ids) : RoomChange;
    public sealed record Updated(IReadOnlyList<string> Ids) : RoomChange;
    public sealed record Removed(IReadOnlyList<string> Ids) : RoomChange;
    public sealed record Reset : RoomChange;
    /// The header, the typing rows or the rows under your bubbles.
    public sealed record State : RoomChange;
}

public sealed class GroupRoomSession : IDisposable
{
    public const string EarlierNotice = "Earlier messages are on the device that sent them.";
    public const string SlashNotice = "Slash commands are not supported in group chats. Open an individual bot chat to use them.";

    private readonly GroupStore store;
    private readonly GroupEngine engine;
    private readonly Guid uid;
    private readonly string accountId;
    private string lastKey;
    private string lastName;
    private bool observing;
    private readonly Dictionary<string, int> revisions = [];
    private string chromeSignature = "";
    private bool gone;
    private List<GroupMessage> builtLog = [];
    private int builtOmitted;
    private List<GroupSeat> builtSeats = [];
    private Dictionary<string, string> builtLabels = [];
    private GroupMessage? replyTarget;

    /// Times the rows were built (tests).
    public int Rebuilds { get; private set; }
    /// The connection as the app sees it.
    public Func<ConnectionState> ConnectionProvider { get; set; } = () => ConnectionState.Open;
    /// The room came on screen or left it (focus, unread, the lists' refresh cadence).
    public Action<bool>? OnObservingChange { get; set; }
    public Action<RoomChange>? OnChange { get; set; }
    public Action<string>? OnRoomGone { get; set; }
    public Action? OnChromeChange { get; set; }

    private GroupRoomSession(GroupRoom room, GroupStore store, GroupEngine engine, string accountId)
    {
        this.store = store;
        this.engine = engine;
        this.accountId = accountId;
        uid = room.Uid;
        lastKey = room.Key;
        lastName = room.Name;
        Rebuild(room, store.Seated(room));
        chromeSignature = Signature(room, store.Seated(room));
        store.Changed += StoreChanged;
    }

    public static GroupRoomSession? Open(string key, GroupStore store, GroupEngine engine, string accountId) =>
        store.Room(key) is { } room ? new GroupRoomSession(room, store, engine, accountId) : null;

    public void Dispose() => store.Changed -= StoreChanged;

    private GroupRoom? Room => store.Room(uid);
    private List<GroupSeat> Seats => Room is { } r ? store.Seated(r) : [];

    // ---- ChatSessionModel

    public string Title => Room?.Name ?? lastName;
    /// Rooms have no bot of their own; the header draws the group avatar instead of a head.
    public string Profile => "";
    public IReadOnlyList<ChatMessage> Messages { get; private set; } = [];
    public ConnectionState Connection => ConnectionProvider();
    public string? StatusText => Connection switch
    {
        ConnectionState.Connecting => "Reconnecting…",
        ConnectionState.Offline => "Offline",
        _ => null,
    };

    public void Start()
    {
        if (observing) return;
        observing = true;
        store.SetUnread(RoomKey, false);
        OnObservingChange?.Invoke(true);
        engine.CollectLateReplies();
    }

    public void StopObserving()
    {
        if (!observing) return;
        observing = false;
        OnObservingChange?.Invoke(false);
    }

    public void Send(string text)
    {
        if (Refusal(text) != null) return;
        if (engine.Send(text, RoomKey, replyTarget?.Thread) is GroupSendOutcome.Sent) ReplyTarget = null;
    }

    // ---- ChatSessionDetails

    public string LayoutScope => $"{accountId}|room|{uid.ToString().ToUpperInvariant()}";
    /// The member whose question shows, else the room.
    public string BotName => Room?.Turn is { WaitingOnUser: true } turn && Seats.FirstOrDefault(s => s.Key == turn.Name) is { } seat ? seat.Display : Title;
    public DateTimeOffset? SeenThrough => Room is { Log.Count: > 0 } r ? DateTimeOffset.FromUnixTimeMilliseconds((long)r.Log[^1].At) : null;

    // ---- ChatRoomSurface

    public string RoomKey => Room?.Key ?? lastKey;
    public string RoomName => Title;
    public GroupMessage? ReplyTarget
    {
        get => replyTarget;
        set { if (replyTarget != value) { replyTarget = value; OnChromeChange?.Invoke(); } }
    }
    public bool IsEmptyRoom => Room?.Log.Count is null or 0;
    public IReadOnlyList<string> MemberNames => [.. Seats.Select(s => s.Display)];
    public bool RoomRunning => Room?.Running ?? false;
    public IReadOnlyDictionary<string, string> Undelivered =>
        (Room?.Undelivered ?? []).ToDictionary(kv => MessageId(kv.Key), kv => kv.Value);
    public IReadOnlySet<string> Retrying => engine.AllRetrying.Select(MessageId).ToHashSet();

    public IReadOnlyList<string> Paused => Room is { } room ? [.. Seats.Where(s => room.Holds.ContainsKey(s.Key)).Select(s => s.Display)] : [];

    public IReadOnlyList<RoomTyping> Typing
    {
        get
        {
            if (Room is not { Running: true } room) return [];
            if (room.Turn is not { } turn || Seats.FirstOrDefault(s => s.Key == turn.Name) is not { } seat) return [new RoomTyping(null, "Replying…")];
            return [new RoomTyping(Sender(seat), turn.WaitingOnUser ? "Waiting for your answer" : $"{seat.Display} is replying…")];
        }
    }

    public string RoomStatusLine
    {
        get
        {
            if (Connection is ConnectionState.Offline or ConnectionState.SignedOut) return "Offline";
            if (Room is { Running: true, Turn: { } turn })
            {
                if (turn.WaitingOnUser) return "Waiting for your reply";
                if (Seats.FirstOrDefault(s => s.Key == turn.Name) is { } seat) return GroupRowWords.Replying([seat.Display]);
            }
            return GroupRowWords.Members(MemberNames);
        }
    }

    public IReadOnlyList<(string Tag, string Name, ChatSender? Sender)> MentionChoices =>
        [.. Seats.Select(s => (GroupMentions.TagFor(s), s.Display, (ChatSender?)Sender(s)))];

    public RoomSendRefusal? Refusal(string text)
    {
        var trimmed = text.Trim();
        if (trimmed.Length == 0) return null;
        if (GroupPrompt.IsSlashCommand(trimmed)) return new RoomSendRefusal.SlashCommand();
        if (!Seats.Any(s => s.CanDrive)) return new RoomSendRefusal.NoMembers(Title);
        return null;
    }

    public Task<bool> StopRoomAsync() => engine.StopAsync(RoomKey);
    public void ResumeAll() => engine.ResumeAll(RoomKey);

    public void Retry(string messageId)
    {
        if (Entry(messageId)?.Id is not { } id) return;
        engine.Retry(id, RoomKey);
        OnChange?.Invoke(new RoomChange.Updated([messageId]));
    }

    public void DeleteUndelivered(string messageId)
    {
        if (Entry(messageId)?.Id is { } id) engine.DeleteEntry(id, RoomKey);
    }

    public string? MentionTag(string messageId) =>
        Entry(messageId) is { From.Kind: GroupAuthorKind.Member } entry && Seats.FirstOrDefault(s => s.Name == entry.From.Name) is { } seat
            ? GroupMentions.TagFor(seat) : null;

    public GroupMessage? Entry(string messageId) => Room?.Log.FirstOrDefault(e => MessageId(e) == messageId);

    public string ReplyHeader(GroupMessage entry)
    {
        var who = entry.From.Kind == GroupAuthorKind.User ? "You" : store.Labels(Seats).GetValueOrDefault(entry.From.Name) ?? entry.From.Name;
        return $"Replying in thread · {who}";
    }

    // ---- Messages

    public static string MessageId(string entryId) => $"room-{entryId}";

    public static string MessageId(GroupMessage entry)
    {
        if (!string.IsNullOrEmpty(entry.Id)) return MessageId(entry.Id);
        // A stable hash (FNV-1a 64 over the UTF-8 entry key), base 36, as the Mac's.
        var value = 0xcbf29ce484222325UL;
        foreach (var b in System.Text.Encoding.UTF8.GetBytes(GroupSnapshot.EntryKey(entry))) value = (value ^ b) * 0x100000001b3UL;
        return $"room-k{Base36(value)}";
    }

    private static string Base36(ulong value)
    {
        if (value == 0) return "0";
        const string digits = "0123456789abcdefghijklmnopqrstuvwxyz";
        var chars = new Stack<char>();
        while (value > 0) { chars.Push(digits[(int)(value % 36)]); value /= 36; }
        return new string([.. chars]);
    }

    public static ChatSender Sender(GroupSeat seat) => new(seat.Key, seat.Display, seat.Head, seat.Name, ChatSenderColors.Hex(seat.Head, seat.Name));

    private void Rebuild(GroupRoom room, List<GroupSeat> seats)
    {
        Rebuilds++;
        builtLog = [.. room.Log];
        builtOmitted = room.Omitted;
        builtSeats = seats;
        var bySeat = new Dictionary<string, GroupSeat>();
        foreach (var s in seats) bySeat.TryAdd(s.Name, s);
        var labels = store.Labels(seats);
        builtLabels = labels;
        var o = new List<ChatMessage>(room.Log.Count + 1);
        if (room.Omitted > 0) o.Add(new ChatMessage("room-notice-earlier", Role.System, [new TextPart(EarlierNotice)]));
        var seen = new HashSet<string>();
        foreach (var entry in room.Log)
        {
            var id = MessageId(entry);
            if (!seen.Add(id)) continue;
            var at = DateTimeOffset.FromUnixTimeMilliseconds((long)entry.At);
            if (entry.From.Kind == GroupAuthorKind.User)
            {
                o.Add(new ChatMessage(id, Role.User, [new TextPart(entry.Text)], at));
                continue;
            }
            ChatSender sender;
            if (bySeat.TryGetValue(entry.From.Name, out var seat) && string.IsNullOrEmpty(entry.From.Source)) sender = Sender(seat);
            else
            {
                // A member that left, or one on another gateway: its name as written, the default head.
                var name = labels.GetValueOrDefault(entry.From.Name) ?? entry.From.Name;
                var label = string.IsNullOrEmpty(entry.From.Source) ? name : $"{name} · {entry.From.Source}";
                sender = new ChatSender($"{entry.From.Source ?? ""}::{entry.From.Name}", label, null, entry.From.Name, ChatSenderColors.Hex(null, entry.From.Name));
            }
            o.Add(new ChatMessage(id, Role.Assistant, [new TextPart(entry.Text)], at) { Sender = sender });
        }
        // Revisions: a message whose content changed (a fuller twin from the mirror, a renamed member) draws again.
        var old = new Dictionary<string, ChatMessage>();
        foreach (var m in Messages) old.TryAdd(m.Id, m);
        for (var i = 0; i < o.Count; i++)
        {
            var id = o[i].Id;
            var revision = revisions.GetValueOrDefault(id);
            if (old.TryGetValue(id, out var before) && !Same(before with { Revision = 0 }, o[i])) revision++;
            revisions[id] = revision;
            o[i] = o[i] with { Revision = revision };
        }
        if (revisions.Count > o.Count * 2 + 64)
            foreach (var k in revisions.Keys.Where(k => !seen.Contains(k) && k != "room-notice-earlier").ToList()) revisions.Remove(k);
        Messages = o;
    }

    /// Value equality (the record's own compares the parts lists by reference).
    private static bool Same(ChatMessage a, ChatMessage b) =>
        a.Id == b.Id && a.Role == b.Role && a.Timestamp == b.Timestamp && a.Revision == b.Revision && a.Sender == b.Sender
        && a.Parts.SequenceEqual(b.Parts);

    private static bool SameSeat(GroupSeat a, GroupSeat b) =>
        a.Key == b.Key && a.Name == b.Name && a.Display == b.Display && a.Handle == b.Handle && a.Title == b.Title && a.Remote == b.Remote
        && a.RemoteLabel == b.RemoteLabel && a.Missing == b.Missing && a.Friendly.SequenceEqual(b.Friendly) && a.PreviousNames.SequenceEqual(b.PreviousNames)
        && JsonNode.DeepEquals(a.Head, b.Head) && a.Descriptor.Same(b.Descriptor);

    private string Signature(GroupRoom room, List<GroupSeat> seats)
    {
        var turn = room.Turn is { } t ? $"{t.Name}|{t.Thread}|{t.WaitingOnUser}" : "-";
        return $"{room.Name}|{room.Running}|{turn}|{string.Join(",", room.Holds.Keys.Order(StringComparer.Ordinal))}|{string.Join(",", seats.Select(s => s.Display))}"
            + $"|{string.Join(",", room.Undelivered.Keys.Order(StringComparer.Ordinal))}|{string.Join(",", engine.AllRetrying.Order(StringComparer.Ordinal))}";
    }

    private void Emit(RoomChange change) => OnChange?.Invoke(change);

    private void StoreChanged()
    {
        if (gone) return;
        if (Room is not { } room)
        {
            gone = true;
            OnRoomGone?.Invoke(lastName);
            return;
        }
        lastKey = room.Key;
        lastName = room.Name;
        if (observing && store.IsUnread(room.Key)) store.SetUnread(room.Key, false);
        var seats = store.Seated(room);
        // The store tells every room's session about every change of the account (several a second during a round).
        var labels = store.Labels(seats);
        if (!room.Log.SequenceEqual(builtLog) || room.Omitted != builtOmitted || seats.Count != builtSeats.Count || !seats.Zip(builtSeats).All(p => SameSeat(p.First, p.Second))
            || labels.Count != builtLabels.Count || labels.Any(kv => builtLabels.GetValueOrDefault(kv.Key) != kv.Value))
        {
            var before = Messages;
            Rebuild(room, seats);
            var after = Messages;
            var oldIds = before.Select(m => m.Id).ToList();
            var newIds = after.Select(m => m.Id).ToList();
            List<string> Changed() => [.. before.Zip(after).Where(p => !Same(p.First, p.Second)).Select(p => p.Second.Id)];
            if (oldIds.SequenceEqual(newIds))
            {
                if (Changed() is { Count: > 0 } changed) Emit(new RoomChange.Updated(changed));
            }
            else if (newIds.Count > oldIds.Count && newIds.Take(oldIds.Count).SequenceEqual(oldIds))
            {
                if (Changed() is { Count: > 0 } changed) Emit(new RoomChange.Updated(changed));
                Emit(new RoomChange.Appended([.. newIds.Skip(oldIds.Count)]));
            }
            else Emit(new RoomChange.Reset());   // merged in place (another device's messages) or one removed
        }
        var signature = Signature(room, seats);
        if (signature != chromeSignature)
        {
            chromeSignature = signature;
            Emit(new RoomChange.State());
            OnChromeChange?.Invoke();
        }
    }

    /// The connection changed, or a retry started or ended: the header and the rows under your bubbles follow.
    public void RefreshState()
    {
        if (Room is not { } room) return;
        chromeSignature = Signature(room, Seats);
        Emit(new RoomChange.State());
        OnChromeChange?.Invoke();
    }
}
