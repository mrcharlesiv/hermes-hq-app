using Hermes.Core.Groups;
using Hermes.Core.Notifications;
using Hermes.Core.Settings;
using Xunit;

namespace Hermes.Core.Tests;

/// [groups] A member's reply in a room not on screen (App/Groups/AppModel+Groups.swift GroupsHub.replied, alertId,
/// alertSpeaker, setFocused at 93f984bb1; App/Notifications/NotificationHub.swift post + present; AppModel+Notifications
/// .swift peekFace). The Mac has no unit tests for these: each case reads one line of that Swift. Toasts are only
/// decided and recorded here; nothing reaches Windows.
public class RoomAlertsTests
{
    private const string Key = "id:rfixture-launch";

    /// The decisions the app would show, in order (a recording sink in place of NotificationsFeature.Show).
    private sealed class Sink
    {
        public readonly List<LocalToast> Toasts = [];
        public readonly List<string> Skipped = [];
        public void Take(AlertDecision d)
        {
            lock (Toasts)
            {
                if (d.Toast is { } t) Toasts.Add(t); else Skipped.Add(d.Skipped);
            }
        }
    }

    private sealed class World
    {
        public NotificationPrefs Prefs = NotificationPrefs.Default;
        public bool Banners = true, InFront, Active = true;
        public HashSet<string> Muted = [];
        public LocalAlerts Alerts = null!;
        public RoomAlerts Rooms = null!;

        public World()
        {
            Alerts = new LocalAlerts(() => Prefs, () => Banners, p => Muted.Contains(p), () => InFront, () => Active);
            Rooms = new RoomAlerts(Alerts, () => Active);
        }
    }

    private static GroupRoom Room(string name = "Launch Room", string? id = "rfixture-launch") =>
        new(name, id) { Members = [new GroupMember("ivy", "ivy"), new GroupMember("research", "research")] };

    private static GroupSeat Seat(string name, string display) => new(name, name, display, name, new GroupMember(name, name));

    private static GroupMessage Reply(string? id, string from, string text, double at = 1_700_000_000_123) =>
        new(id, at, new GroupAuthor(GroupAuthorKind.Member, from), text, "t1");

    [Fact]
    public void AMembersReplyInARoomNotOnScreenPostsOneMessageCompleteFromTheMemberInTheRoom()
    {
        var w = new World();
        var room = Room();
        var d = w.Rooms.Replied(room, Reply("m1", "ivy", "**Done**: the notes are in [the doc](https://example.com/notes)."), Seat("ivy", "Ivy"));
        var toast = Assert.IsType<LocalToast>(d.Toast);
        Assert.Equal("message.complete", toast.Kind);
        Assert.Equal("room:m1", toast.Id);
        Assert.Equal(LocalToast.Key("room:m1"), toast.Tag);
        // NotificationWho(sender: member, chat: "", group: room name, bot: true): "<member> · <room>", no subtitle.
        Assert.Equal("Ivy · Launch Room", toast.Title);
        Assert.Equal("", toast.Subtitle);
        Assert.Equal(NotificationText.Preview("**Done**: the notes are in [the doc](https://example.com/notes)."), toast.Body);
        Assert.Equal("Done: the notes are in the doc.", toast.Body);
        // The room's alert id is the session and the thread; the room's mute key is the profile.
        Assert.Equal("room-rfixture-launch", RoomAlerts.AlertId(room));
        Assert.Equal(LocalToast.Key("room-rfixture-launch"), toast.Group);
        Assert.Equal([new("session", "room-rfixture-launch"), new("stored", "room-rfixture-launch"), new("request", ""),
            new("kind", "message.complete"), new("profile", "room:" + Key)], toast.Arguments);
        Assert.Empty(toast.Buttons);
        Assert.Equal("", d.Skipped);
        // A tap opens the room's alert id (its thread), with the room's mute key as profile.
        Assert.Equal(new NotificationTarget("room-rfixture-launch", "room:" + Key), NotificationTarget.From(toast.Arguments));
    }

    [Fact]
    public void ATappedRoomAlertOpensTheRoomNotAMembersChat()
    {
        var w = new World();
        var toast = w.Rooms.Replied(Room(), Reply("m1", "ivy", "hi"), Seat("ivy", "Ivy")).Toast!;
        var target = NotificationResponse.From(toast.Arguments).Target!;
        // openNotifiedChat: `profile.hasPrefix("room:")` → openRoom(String(profile.dropFirst(5))).
        Assert.Equal(Key, NotificationOpen.RoomKey(target));
        Assert.Null(NotificationOpen.RoomKey(new NotificationTarget("st-otto", "otto")));
        Assert.Null(NotificationOpen.RoomKey(new NotificationTarget("st-otto", null)));
    }

    [Fact]
    public void TheRoomOnScreenPostsNothingAndKeepsItsLastSpeaker()
    {
        var w = new World();
        var room = Room();
        w.Rooms.Replied(room, Reply("m1", "ivy", "first"), Seat("ivy", "Ivy"));
        w.Rooms.SetFocused(room.Uid, true);
        var d = w.Rooms.Replied(room, Reply("m2", "research", "second"), Seat("research", "Research"));
        Assert.Null(d.Toast);
        Assert.Equal("room on screen", d.Skipped);
        // `replied` returns before `speakers[...] = seat.name`.
        Assert.Equal("ivy", w.Rooms.AlertSpeaker("room:" + Key));
    }

    [Fact]
    public void TheRoomOnScreenAlertsWhileTheAppIsNotActive()
    {
        // `room.uid.value == focused, UIApplication.shared.applicationState == .active`: both, or the alert goes up.
        var w = new World { Active = false };
        var room = Room();
        w.Rooms.SetFocused(room.Uid, true);
        Assert.NotNull(w.Rooms.Replied(room, Reply("m1", "ivy", "hi"), Seat("ivy", "Ivy")).Toast);
    }

    [Fact]
    public void AnotherRoomOnScreenLeavesThisRoomsAlert()
    {
        var w = new World();
        var other = Room("Ops Desk", "rfixture-ops");
        var room = Room();
        w.Rooms.SetFocused(other.Uid, true);
        Assert.NotNull(w.Rooms.Replied(room, Reply("m1", "ivy", "hi"), Seat("ivy", "Ivy")).Toast);
        Assert.Null(w.Rooms.Replied(other, Reply("m2", "ivy", "hi"), Seat("ivy", "Ivy")).Toast);
    }

    [Fact]
    public void AMutedRoomsReplyIsSilencedButAMutedMemberDoesNotQuietTheRoom()
    {
        var w = new World();
        var room = Room();
        w.Muted.Add("ivy");   // the member's own mute: not the room's
        Assert.NotNull(w.Rooms.Replied(room, Reply("m1", "ivy", "one"), Seat("ivy", "Ivy")).Toast);
        w.Muted.Add(GroupKeys.MuteKey(room.Key));
        var d = w.Rooms.Replied(room, Reply("m2", "ivy", "two"), Seat("ivy", "Ivy"));
        Assert.Null(d.Toast);
        Assert.Equal("muted", d.Skipped);
        Assert.True(NotificationRules.Silenced("message.complete"));
        // The speaker is still noted before the post's mute (as on the Mac).
        Assert.Equal("ivy", w.Rooms.AlertSpeaker(GroupKeys.MuteKey(room.Key)));
    }

    [Fact]
    public void ResponseReadyOffPostsNothingAndPreviewsOffNameTheMemberAndRoom()
    {
        var w = new World { Prefs = NotificationPrefs.Default with { Kinds = new Dictionary<string, bool> { ["turnDone"] = false } } };
        var room = Room();
        Assert.Equal("preference off", w.Rooms.Replied(room, Reply("m1", "ivy", "hi"), Seat("ivy", "Ivy")).Skipped);
        w.Prefs = NotificationPrefs.Default with { Previews = false };
        var toast = w.Rooms.Replied(room, Reply("m2", "ivy", "secret plan"), Seat("ivy", "Ivy")).Toast!;
        Assert.Equal(("", "", "New reply from Ivy in Launch Room"), (toast.Title, toast.Subtitle, toast.Body));
    }

    [Fact]
    public void TheAlertWearsTheFaceOfTheMemberWhoSpokeLast()
    {
        var w = new World();
        var room = Room();
        var mute = GroupKeys.MuteKey(room.Key);
        Assert.Null(w.Rooms.AlertSpeaker(mute));
        Assert.Equal(mute, w.Rooms.Face(mute));   // peekFace: alertSpeaker(profile) ?? profile
        Assert.Equal("ivy", w.Rooms.Replied(room, Reply("m1", "ivy", "one"), Seat("ivy", "Ivy")).Toast!.Face);
        var second = w.Rooms.Replied(room, Reply("m2", "research", "two"), Seat("research", "Research")).Toast!;
        Assert.Equal("research", second.Face);
        Assert.Equal("Research · Launch Room", second.Title);
        Assert.Equal("research", w.Rooms.AlertSpeaker(mute));
        // No seat (a member no longer seated): the entry's own name speaks, and the last face stays.
        var unseated = w.Rooms.Replied(room, Reply("m3", "wren", "three"), null).Toast!;
        Assert.Equal("wren · Launch Room", unseated.Title);
        Assert.Equal("research", unseated.Face);
        // Each room keeps its own speaker, by its mute key; a chat's alert wears none.
        var ops = Room("Ops Desk", "rfixture-ops");
        w.Rooms.Replied(ops, Reply("o1", "juno", "hi"), Seat("juno", "Juno"));
        Assert.Equal("research", w.Rooms.AlertSpeaker(mute));
        Assert.Equal("juno", w.Rooms.AlertSpeaker(GroupKeys.MuteKey(ops.Key)));
        Assert.Equal("", w.Alerts.ObserveTurnEnd("run-otto", 1, false, "hi", null).Toast!.Face);
    }

    [Fact]
    public void AlertIdFollowsTheNotificationRules()
    {
        Assert.Equal("room-rfixture-launch", RoomAlerts.AlertId(Room()));
        // No room id: the name, with anything but letters, digits, - and _ turned to -.
        Assert.Equal("room-Launch-Room--Q4-", RoomAlerts.AlertId(Room("Launch Room (Q4)", null)));
        Assert.Equal("room-ops_desk-2", RoomAlerts.AlertId(Room("x", "ops_desk-2")));
        // At most 120 characters, the prefix included.
        var longId = RoomAlerts.AlertId(Room("x", new string('a', 200)));
        Assert.Equal(120, longId.Length);
        Assert.Equal("room-" + new string('a', 115), longId);
        Assert.True(NotificationRules.Valid(longId));
        // Foundation's alphanumerics are Unicode's letters and digits: kept as they are (and then not a valid alert id,
        // as on the Mac).
        Assert.Equal("room-Café", RoomAlerts.AlertId(Room("Café", null)));
        Assert.Equal("room-x-y", RoomAlerts.AlertId(Room("x\U0001F600y", null)));   // an emoji is one character, one -
    }

    [Fact]
    public void AnEntryWithNoIdIsNamedByItsTime()
    {
        Assert.Equal("room:m1", RoomAlerts.MessageId(Reply("m1", "ivy", "hi")));
        // `String(Int(entry.at))`: whole milliseconds, toward zero.
        Assert.Equal("room:1700000000123", RoomAlerts.MessageId(Reply(null, "ivy", "hi", 1_700_000_000_123.9)));
        var w = new World();
        Assert.Equal("room:1700000000123", w.Rooms.Replied(Room(), Reply(null, "ivy", "hi", 1_700_000_000_123.9), Seat("ivy", "Ivy")).Toast!.Id);
    }

    [Fact]
    public void TheSameReplyAlertsOnce()
    {
        var w = new World();
        var room = Room();
        Assert.NotNull(w.Rooms.Replied(room, Reply("m1", "ivy", "hi"), Seat("ivy", "Ivy")).Toast);
        Assert.Equal("already alerted", w.Rooms.Replied(room, Reply("m1", "ivy", "hi"), Seat("ivy", "Ivy")).Skipped);
    }

    [Fact]
    public void InFrontWithBannersTheReplyGoesToTheListOnly()
    {
        var w = new World { InFront = true };
        Assert.True(w.Rooms.Replied(Room(), Reply("m1", "ivy", "hi"), Seat("ivy", "Ivy")).Toast!.SuppressDisplay);
        w.Banners = false;
        Assert.False(w.Rooms.Replied(Room(), Reply("m2", "ivy", "hi"), Seat("ivy", "Ivy")).Toast!.SuppressDisplay);
        w.Banners = true;
        w.InFront = false;
        Assert.False(w.Rooms.Replied(Room(), Reply("m3", "ivy", "hi"), Seat("ivy", "Ivy")).Toast!.SuppressDisplay);
    }

    [Fact]
    public void ARoomComingOnScreenIsNoChatsAndGoingOffClearsOnlyItself()
    {
        var w = new World();
        w.Alerts.Focus("run-otto", "st-otto");
        var room = Room();
        var other = Room("Ops Desk", "rfixture-ops");
        w.Rooms.SetFocused(room.Uid, true);
        // notificationsFocus(runtime: nil, stored: nil)
        Assert.Null(w.Alerts.Viewing);
        Assert.Null(w.Alerts.ViewingStored);
        Assert.Equal(room.Uid, w.Rooms.Focused);
        w.Rooms.SetFocused(other.Uid, false);
        Assert.Equal(room.Uid, w.Rooms.Focused);
        w.Alerts.Focus("run-otto", "st-otto");
        w.Rooms.SetFocused(room.Uid, false);
        Assert.Null(w.Rooms.Focused);
        Assert.Equal("run-otto", w.Alerts.Viewing);   // going off screen leaves the hub's focus alone
    }

    [Fact]
    public void ClearForgetsTheRoomOnScreenAndWhoSpoke()
    {
        var w = new World();
        var room = Room();
        w.Rooms.Replied(room, Reply("m1", "ivy", "hi"), Seat("ivy", "Ivy"));
        w.Rooms.SetFocused(room.Uid, true);
        w.Rooms.Clear();
        Assert.Null(w.Rooms.Focused);
        Assert.Null(w.Rooms.AlertSpeaker(GroupKeys.MuteKey(room.Key)));
        Assert.NotNull(w.Rooms.Replied(room, Reply("m2", "ivy", "hi"), Seat("ivy", "Ivy")).Toast);
    }

    [Fact]
    public void ASignOutBetweenTheDecisionAndThePostDropsTheToast()
    {
        var w = new World();
        var toast = w.Rooms.Replied(Room(), Reply("m1", "ivy", "hi"), Seat("ivy", "Ivy")).Toast!;
        Assert.True(w.Alerts.MayPost(toast));
        w.Alerts.Clear();
        Assert.False(w.Alerts.MayPost(toast));
    }

    // ------------------------------------------------------------------ a round over the fake gateway

    private static (GroupStore Store, FakeRoomGateway Gateway, GroupEngine Engine) Make()
    {
        var store = new GroupStore([Room()]) { Roster = FakeRoster.Launch() };
        var gateway = new FakeRoomGateway();
        var engine = new GroupEngine(store, gateway.Client, new GroupTiming { Poll = TimeSpan.FromSeconds(1), Settle = TimeSpan.FromMilliseconds(20) });
        return (store, gateway, engine);
    }

    [Fact]
    public async Task ARoundInARoomNotOnScreenAlertsEachMembersReplyAndTheRoomOnScreenNone()
    {
        using var loop = new GroupLoop();
        var (store, gateway, engine) = await loop.Run(() => Make());
        var w = new World();
        var sink = new Sink();
        // The host's wiring (GroupRooms.Engine): the engine's onReply goes to the room alerts, focus to IsFocused.
        engine.IsFocused = key => store.Room(key)?.Uid == w.Rooms.Focused;
        engine.OnReply = (room, entry, seat) => sink.Take(w.Rooms.Replied(room, entry, seat));
        gateway.Reply = (profile, prompt) => prompt.Contains("(user): Who takes the notes?", StringComparison.Ordinal) ? $"{profile} here: on it." : "(pass)";
        await loop.Run(() => engine.Send("Who takes the notes?", Key));
        await loop.Until(() => store.Activity(Key).Any(e => e.Kind == GroupActivityKind.Settled) && !engine.IsDriving(Key), "the round settles");
        var room = await loop.Run(() => store.Room(Key)!.Clone());
        var replies = room.Log.Where(e => e.From.Kind == GroupAuthorKind.Member).ToList();
        lock (sink.Toasts)
        {
            Assert.Equal(["Ivy · Launch Room", "Research · Launch Room"], sink.Toasts.Select(t => t.Title));
            Assert.Equal(["ivy here: on it.", "research here: on it."], sink.Toasts.Select(t => t.Body));
            Assert.Equal(replies.Select(e => RoomAlerts.MessageId(e)), sink.Toasts.Select(t => t.Id));
            Assert.Equal(["ivy", "research"], sink.Toasts.Select(t => t.Face));
            Assert.All(sink.Toasts, t => Assert.Equal(LocalToast.Key("room-rfixture-launch"), t.Group));
            Assert.All(sink.Toasts, t => Assert.Contains(new KeyValuePair<string, string>("profile", "room:" + Key), t.Arguments));
            Assert.Empty(sink.Skipped);
        }
        Assert.Equal("research", w.Rooms.AlertSpeaker("room:" + Key));

        // The room on screen: the next round's replies post nothing.
        w.Rooms.SetFocused(room.Uid, true);
        gateway.Reply = (profile, prompt) => prompt.Contains("(user): And the agenda?", StringComparison.Ordinal) ? $"{profile}: agenda next." : "(pass)";
        var before = room.Log.Count;
        await loop.Run(() => engine.Send("And the agenda?", Key));
        await loop.Until(() => store.Room(Key)!.Log.Count(e => e.Text.EndsWith(": agenda next.", StringComparison.Ordinal)) == 2
            && !store.Room(Key)!.Running && !engine.IsDriving(Key), "the second round settles");
        lock (sink.Toasts)
        {
            Assert.Equal(2, sink.Toasts.Count);
            Assert.Equal(["room on screen", "room on screen"], sink.Skipped);
        }
        Assert.True(await loop.Run(() => store.Room(Key)!.Log.Count) > before);
        await loop.Run(() => { engine.Shutdown(); return true; });
    }
}
