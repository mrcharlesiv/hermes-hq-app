using System.Text.Json.Nodes;
using Hermes.Core.Groups;
using Xunit;

namespace Hermes.Core.Tests;

// Ports of Tests/Groups/GroupSnapshotTests.swift (93f984bb1): the gateway mirror read in every version and any damage,
// built under the size cap, merged from two writers and into this device's records; plus the store's rows and the
// mirror's publish against a scripted `profiles.list` / `profiles.configure`.
public class GroupSnapshotTests
{
    private static GroupMirror Parse(string text) => GroupSnapshot.Parse(JsonNode.Parse(text));

    [Fact]
    public void ReadsAVersionThreeEnvelope()
    {
        var mirror = Parse("""
        {"version":3,"updatedAt":1700000000000,"deleted":{"id:gone":9},
         "rooms":{"id:r1":{"name":" Launch Room ","roomId":"r1","holdDetection":false,"revision":4,"omitted":2,"color":"teal",
           "members":[{"name":"ivy","handle":"ivy","nickname":"S"},{"name":"far","sourceScoped":true,"connectionId":"c9","connectionLabel":"Studio"}],
           "image":"data:image/jpeg;base64,AAAA",
           "log":[{"id":"b","from":{"kind":"member","name":"ivy"},"text":"second","at":20,"thread":"t1"},
                  {"id":"a","from":{"kind":"user","name":"You"},"text":"first","at":10,"thread":"t1","truncated":true}]}}}
        """);
        Assert.Equal(3, mirror.Version);
        Assert.Equal(1_700_000_000_000, mirror.UpdatedAt);
        Assert.Equal(9, mirror.Deleted["id:gone"]);
        var room = mirror.Rooms["id:r1"];
        Assert.Equal("Launch Room", room.Name);
        Assert.Equal("r1", room.RoomId);
        Assert.False(room.HoldDetection);
        Assert.Equal(4, room.Revision);
        Assert.Equal(2, room.Omitted);
        Assert.Equal(["ivy", "c9::far"], room.Members.Select(m => m.Key));
        Assert.Equal("Studio", room.Members[1].ConnectionLabel);
        Assert.Equal("data:image/jpeg;base64,AAAA", room.Image);
        Assert.Equal(["first", "second"], room.Log.Select(e => e.Text));
        Assert.True(room.Log[0].Truncated);
        Assert.Null(room.Log[1].Truncated);
        Assert.Equal("""{"color":"teal"}""", room.Extra.ToJsonString());
        var back = GroupSnapshot.Json(room);
        Assert.Equal("teal", back.Str("color"));
        Assert.Equal("S", back.Arr("members")![0].Str("nickname"));
    }

    [Fact]
    public void ReadsVersionOneAndTwo()
    {
        var one = Parse("""{"rooms":{"Old Room":{"members":[{"name":"ivy"}],"log":[{"from":{"kind":"user","name":"You"},"text":"hi","at":5}]}},"deleted":["Gone"]}""");
        Assert.Equal(1, one.Version);
        Assert.Equal(["name:Old Room"], one.Rooms.Keys);
        Assert.Single(one.Rooms["name:Old Room"].Log);
        Assert.Equal(0, one.Deleted["name:Gone"]);
        var two = Parse("""{"version":2,"rooms":{"Team":{"name":"ignored","revision":3,"log":[]}},"deleted":{"Gone":6}}""");
        Assert.Equal("Team", two.Rooms["name:Team"].Name);
        Assert.Equal(3, two.Rooms["name:Team"].Revision);
        Assert.Equal(6, two.Deleted["name:Gone"]);
        var written = GroupSnapshot.Envelope(GroupSnapshot.Merge(one, new GroupMirror(), writeRevision: 1), 9).Json;
        Assert.Equal(3, JsonNode.Parse(written.ToJsonString()).Int("version"));
    }

    [Fact]
    public void DamageNeverBreaksTheRead()
    {
        Assert.Empty(Parse("\"just a string\"").Rooms);
        Assert.Empty(GroupSnapshot.Parse(null).Rooms);
        Assert.Empty(Parse("""{"version":3,"rooms":[1,2,3]}""").Rooms);
        var mirror = Parse("""
        {"version":3,"rooms":{
          "id:bad-log":{"name":"Bad Log","roomId":"bad-log","log":"oops"},
          "id:no-name":{"roomId":"no-name","log":[]},
          "id:good":{"name":"Good Room","roomId":"good","revision":"seven","omitted":-4,
            "members":[{"handle":"x"},{"name":"  "},{"name":"inbox"},7,{"name":"notes"}],
            "image":"IMAGE",
            "log":[{"id":"n","from":{"kind":"member","name":"inbox"},"text":42,"at":1},
                   {"id":"s","from":{"kind":"member","name":"inbox"},"text":"at is a string","at":"soon"},
                   {"id":"k","from":{"kind":"robot","name":"inbox"},"text":"unknown kind","at":2},
                   {"id":"m","from":{"kind":"member"},"text":"no name","at":3},
                   {"id":"dup","from":{"kind":"user","name":"You"},"text":"once","at":4},
                   {"id":"dup","from":{"kind":"user","name":"You"},"text":"twice","at":5},
                   "nonsense",
                   {"id":"ok","from":{"kind":"member","name":"notes"},"text":"fine","at":6}]}}}
        """.Replace("IMAGE", new string('A', 30_000)));
        Assert.Equal(["id:good"], mirror.Rooms.Keys);
        var good = mirror.Rooms["id:good"];
        Assert.Equal(0, good.Revision);
        Assert.Equal(0, good.Omitted);
        Assert.Equal(["inbox", "notes"], good.Members.Select(m => m.Name));
        Assert.Null(good.Image);
        Assert.Equal(["once", "fine"], good.Log.Select(e => e.Text));
    }

    [Fact]
    public void EntryKeysAreTheIdElseTheContent()
    {
        Assert.Equal("id:abc", GroupSnapshot.EntryKey(G.You("hi", 5, "t1", "abc")));
        Assert.Equal("""[5,"user","You","","legacy","hi"]""", GroupSnapshot.EntryKey(G.You("hi", 5, null)));
        Assert.Equal("""[6.5,"member","ivy","Studio","legacy","yo"]""", GroupSnapshot.EntryKey(G.Member("ivy", "yo", 6.5, "legacy-3", source: "Studio")));
    }

    [Fact]
    public void ARoomIsCompactedForTheMirror()
    {
        var full = G.Room("Launch", "r1", entries: 20);
        full.Log[19] = full.Log[19] with { Text = new string('x', 5_000), From = full.Log[19].From with { Gateway = "http://127.0.0.1" } };
        full.Pinned = true;
        var made = GroupSnapshot.Compact(full);
        Assert.Equal(16, made.Log.Count);
        Assert.Equal(4, made.Omitted);
        Assert.Equal("Launch-4", made.Log[0].Id);
        Assert.Equal(1_200, made.Log[^1].Text.Length);
        Assert.True(made.Log[^1].Truncated);
        Assert.Null(made.Log[^1].From.Gateway);
        Assert.Equal(1, made.Revision);
        Assert.Equal(2, made.Members.Count);
        var local = GroupSnapshot.Local([full, new GroupRoom("Empty", "e"), new GroupRoom("Hosted") { Hosted = new HostedRoomRef("ivy", "h1"), Log = [G.You("x")] }],
            new Dictionary<string, int> { ["id:gone"] = 3 });
        Assert.Equal(["id:r1"], local.Rooms.Keys);
        Assert.Equal(3, local.Deleted["id:gone"]);
        Assert.Equal(["holdDetection", "log", "members", "name", "omitted", "revision", "roomId"], GroupSnapshot.Json(made).Select(kv => kv.Key).Order(StringComparer.Ordinal));
    }

    [Fact]
    public void SizeIsCountedTheWayPythonWritesIt()
    {
        Assert.Equal(8, GroupSnapshot.PythonSize(new JsonObject { ["a"] = 1 }));
        Assert.Equal("[1, true, false, null]".Length, GroupSnapshot.PythonSize(new JsonArray(1, true, false, null)));
        Assert.Equal(8, GroupSnapshot.PythonSize("é"));
        Assert.Equal(14, GroupSnapshot.PythonSize("😀"));
        Assert.Equal("\"a\\nb\\\"c\\\\\"".Length, GroupSnapshot.PythonSize("a\nb\"c\\"));
        Assert.Equal(8, GroupSnapshot.PythonSize("\u0001"));
        Assert.Equal(13, GroupSnapshot.PythonSize(JsonValue.Create(1700000000000.0)));
        Assert.True(GroupSnapshot.PythonSize("a,b: c") >= "\"a,b: c\"".Length);
    }

    [Fact]
    public void TheEnvelopeStaysUnderTheCapAndKeepsTheNewestRooms()
    {
        var rooms = Enumerable.Range(0, 40).Select(i => G.Room($"Room {i}", $"r{i}", entries: 16, start: i * 1_000, text: string.Concat(Enumerable.Repeat("word ", 220)))).ToList();
        var made = GroupSnapshot.Envelope(GroupSnapshot.Local(rooms, new Dictionary<string, int>()), 1);
        Assert.True(made.Bytes <= 48_000);
        Assert.Equal(made.Bytes, GroupSnapshot.PythonSize(made.Json) + 2);
        Assert.True(made.Kept.Rooms.Count is < 40 and > 0);
        Assert.Contains("id:r39", made.Kept.Rooms.Keys);
        Assert.DoesNotContain("id:r0", made.Kept.Rooms.Keys);
        foreach (var cut in made.Kept.Rooms.Values.Where(r => r.Log.Count < 16))
        {
            Assert.Equal(16 - cut.Log.Count, cut.Omitted);
            Assert.EndsWith("-15", cut.Log[^1].Id);
        }
        Assert.True(System.Text.Encoding.UTF8.GetByteCount(made.Json.ToJsonString()) <= 48_000);
    }

    [Fact]
    public void ARoomGivesUpEntriesThenItsImageThenItsPlace()
    {
        var big = G.Room("Big", "big", entries: 16, start: 5_000, text: new string('y', 1_150));
        big.Image = new string('I', 20_000);
        var local = GroupSnapshot.Local([big], new Dictionary<string, int>());
        var made = GroupSnapshot.Envelope(local, 1, 24_000);
        var kept = made.Kept.Rooms["id:big"];
        Assert.NotNull(kept.Image);
        Assert.True(kept.Log.Count < 16);
        Assert.Equal(16 - kept.Log.Count, kept.Omitted);
        Assert.True(made.Bytes <= 24_000);
        Assert.Equal(made.Bytes, GroupSnapshot.PythonSize(made.Json) + 2);
        var tight = GroupSnapshot.Envelope(local, 1, 3_000);
        Assert.Null(tight.Kept.Rooms["id:big"].Image);
        Assert.Single(tight.Kept.Rooms["id:big"].Log);
        Assert.Equal(tight.Bytes, GroupSnapshot.PythonSize(tight.Json) + 2);
        var none = GroupSnapshot.Envelope(local, 1, 200);
        Assert.Empty(none.Kept.Rooms);
        Assert.True(none.Bytes <= 200);
    }

    [Fact]
    public void TombstonesAreCappedAtSixtyFour()
    {
        var mirror = new GroupMirror();
        for (var i = 0; i < 90; i++) mirror.Deleted[$"id:gone{i}"] = i;
        var made = GroupSnapshot.Envelope(mirror, 1);
        Assert.Equal(64, made.Kept.Deleted.Count);
        Assert.Equal(89, made.Kept.Deleted["id:gone89"]);
        Assert.DoesNotContain("id:gone0", made.Kept.Deleted.Keys);
    }

    [Fact]
    public void MergeUnionsLogsAndNeverDeletesByAbsence()
    {
        var none = new Dictionary<string, int>();
        var theirs = GroupSnapshot.Local([G.Room("Launch", "r1", entries: 2, revision: 4), G.Room("Theirs", "t", entries: 1)], none);
        theirs.Rooms["id:r1"].Log.Add(G.Member("ivy", "From the desktop", 5_000, id: "desk"));
        var mine = GroupSnapshot.Local([G.Room("Launch", "r1", entries: 3, revision: 4), G.Room("Mine", "m", entries: 1)], none);
        mine.Rooms["id:r1"].Log.Add(G.You("From the phone", 6_000, id: "phone"));
        var merged = GroupSnapshot.Merge(theirs, mine, new HashSet<string> { "id:r1" }, writeRevision: 5);
        Assert.Equal(["id:m", "id:r1", "id:t"], merged.Rooms.Keys.Order(StringComparer.Ordinal));
        Assert.Equal(["Launch-0", "Launch-1", "Launch-2", "desk", "phone"], merged.Rooms["id:r1"].Log.Select(e => e.Id));
        Assert.Equal(5, merged.Rooms["id:r1"].Revision);
        Assert.Equal(1, merged.Rooms["id:m"].Revision);
    }

    [Fact]
    public void AnEntryDeletedHereStaysOutOfTheMergeAndTheDevice()
    {
        var none = new Dictionary<string, int>();
        var published = GroupSnapshot.Local([G.Room("Launch", "r1", entries: 3, revision: 4)], none);
        var mine = G.Room("Launch", "r1", entries: 3, revision: 4);
        var gone = GroupSnapshot.EntryKey(mine.Log[1]);
        mine.Log.RemoveAt(1);
        mine.Removed = [gone];
        var applied = GroupSnapshot.Apply(published, [mine]);
        Assert.Equal(["Launch-0", "Launch-2"], applied.Rooms[0].Log.Select(e => e.Id));
        Assert.False(applied.Changed);
        var merged = GroupSnapshot.Merge(published, GroupSnapshot.Local([mine], none), new HashSet<string> { "id:r1" },
            removed: new Dictionary<string, HashSet<string>> { ["id:r1"] = [gone] }, writeRevision: 5);
        Assert.Equal(["Launch-0", "Launch-2"], merged.Rooms["id:r1"].Log.Select(e => e.Id));
    }

    [Fact]
    public void TombstonesDeleteAndAnOlderWriteCannotRevive()
    {
        var none = new Dictionary<string, int>();
        var remote = GroupSnapshot.Local([G.Room("Named", entries: 1, revision: 2)], new Dictionary<string, int> { ["id:r1"] = 7 });
        var local = GroupSnapshot.Local([G.Room("Launch", "r1", entries: 1, revision: 9)], none);
        var merged = GroupSnapshot.Merge(remote, local, deleted: new HashSet<string> { "name:Named" }, writeRevision: 3);
        Assert.Empty(merged.Rooms);
        Assert.Equal(7, merged.Deleted["id:r1"]);
        Assert.Equal(3, merged.Deleted["name:Named"]);
        // A name room written later than its tombstone lives, and the tombstone goes.
        var revived = GroupSnapshot.Merge(new GroupMirror { Deleted = new() { ["name:Named"] = 1 } }, GroupSnapshot.Local([G.Room("Named", entries: 1, revision: 4)], none), writeRevision: 5);
        Assert.Contains("name:Named", revived.Rooms.Keys);
        Assert.Empty(revived.Deleted);
    }

    [Fact]
    public void ApplyAdoptsNewRoomsRekeysAndFollowsARenameOnlyFromAHigherRevision()
    {
        var mirror = GroupSnapshot.Local([G.Room("Launch", "r1", entries: 4, revision: 3), G.Room("Fresh", "f", entries: 1, revision: 1)], new Dictionary<string, int>());
        var mine = G.Room("Launch", entries: 2, revision: 1);   // a `name:` room that gained its id elsewhere
        mine.Watermarks["t1::ivy"] = 2;
        var applied = GroupSnapshot.Apply(mirror, [mine]);
        Assert.True(applied.Changed);
        Assert.Equal("id:r1", applied.Rekeyed["name:Launch"]);
        var launch = applied.Rooms.Single(r => r.Key == "id:r1");
        Assert.Equal(3, launch.SyncRevision);
        // A higher revision renames; a lower one never does.
        mirror.Rooms["id:r1"].Name = "Release";
        Assert.Equal("Release", GroupSnapshot.Apply(mirror, [new GroupRoom("Mine", "r1") { SyncRevision = 1 }]).Rooms.Single(r => r.Key == "id:r1").Name);
        Assert.Equal("Mine", GroupSnapshot.Apply(mirror, [new GroupRoom("Mine", "r1") { SyncRevision = 5 }]).Rooms.Single(r => r.Key == "id:r1").Name);
        Assert.Equal(4, launch.Log.Count);
        Assert.Equal(2, launch.Watermarks["t1::ivy"]);
        Assert.Contains(applied.Rooms, r => r.Key == "id:f");
        // A lower revision never renames; a protected room keeps its identity.
        var held = GroupSnapshot.Apply(mirror, [new GroupRoom("Mine", "r1") { SyncRevision = 1 }], protect: new HashSet<string> { "id:r1" });
        Assert.Equal("Mine", held.Rooms.Single(r => r.Key == "id:r1").Name);
        // A tombstone removes the device's copy.
        var removed = GroupSnapshot.Apply(new GroupMirror { Deleted = new() { ["id:r1"] = 1 } }, [G.Room("Launch", "r1")]);
        Assert.Empty(removed.Rooms);
        Assert.Equal("id:r1", removed.Removed.Single().Key);
    }

    [Fact]
    public void AnEntryMergedInEarlierMovesTheMarksPastIt()
    {
        var mine = G.Room("Launch", "r1", entries: 3, revision: 1, start: 10);
        mine.Watermarks["t1::ivy"] = 3;
        var mirror = GroupSnapshot.Local([new GroupRoom("Launch", "r1") { SyncRevision = 1, Log = [G.Member("ivy", "early", 5, id: "early")] }], new Dictionary<string, int>());
        var applied = GroupSnapshot.Apply(mirror, [mine]);
        Assert.Equal(["early", "Launch-0", "Launch-1", "Launch-2"], applied.Rooms[0].Log.Select(e => e.Id));
        Assert.Equal(4, applied.Rooms[0].Watermarks["t1::ivy"]);
    }

    private sealed class Roster(bool loaded, params GroupRosterProfile[] profiles) : IGroupRoster
    {
        public bool Loaded => loaded;
        public IReadOnlyList<GroupRosterProfile> Profiles => profiles;
    }

    [Fact]
    public void StoreRowsSeatTheRosterAndReadTheRoom()
    {
        var room = G.Room("Launch Room", "r1", entries: 1, start: 1_700_000_000_000);
        room.Members.Add(new GroupMember("far") { SourceScoped = true, ConnectionId = "c9", ConnectionLabel = "Studio", Title = "Far" });
        var store = new GroupStore([room]) { IsMuted = key => key == "room:id:r1" };
        // Before the roster loads, saved members are shown and never driven.
        var before = store.Rows().Single();
        Assert.Equal("0 of 2 available", before.Line);   // saved members, missing until the roster loads
        Assert.Equal(3, before.MemberCount);
        store.Roster = new Roster(true, new GroupRosterProfile("ivy") { Meta = G.Meta("""{"groups":["Launch Room"],"title":"Ivy"}"""), BotName = "Ivy" },
            new GroupRosterProfile("research") { Meta = G.Meta("""{"groups":["Other"]}""") });
        var row = store.Rows().Single();
        Assert.Equal("id:r1", row.Id);
        Assert.Equal(2, row.MemberCount);   // ivy (seated) and the remote member; research left the room
        Assert.Equal(["ivy", "far"], row.Faces.Select(f => f.Profile));
        Assert.Equal("launch room ivy far", row.Search);
        Assert.True(row.Muted);
        Assert.Equal(DateTimeOffset.FromUnixTimeMilliseconds(1_700_000_000_000), row.Time);
        store.SetUnread("id:r1", true);
        store.SetPinned("id:r1", true);
        Assert.True(store.Rows()[0].Unread);
        Assert.True(store.Rows()[0].Pinned);
        store.SetHidden("id:r1", true);
        Assert.False(store.Rows()[0].Pinned);
        Assert.True(store.Rows()[0].Hidden);
        // Running with a member on turn: its name replying, then waiting on you.
        store.Update("id:r1", r => { r.Running = true; r.Turn = new GroupTurnState("ivy", "t1"); }, sync: false);
        Assert.Equal("Ivy is replying…", store.Rows()[0].Line);
        store.Update("id:r1", r => r.Turn = new GroupTurnState("ivy", "t1", WaitingOnUser: true), sync: false);
        Assert.Equal("Waiting for your reply", store.Rows()[0].Line);
        store.IsOnline = () => false;
        store.Update("id:r1", r => { r.Running = false; r.Turn = null; }, sync: false);
        Assert.Equal("0 of 1 available", store.Rows()[0].Line);
        Assert.Equal(["Launch Room"], store.RoomsOf("ivy").Select(r => r.Name));
    }

    [Fact]
    public async Task ThePublishReadsMergesAndWritesWithCompareAndSwap()
    {
        // The gateway's default profile already carries a room another device wrote.
        JsonNode mirror = GroupSnapshot.Envelope(GroupSnapshot.Local([G.Room("Desk", "d1", entries: 1, revision: 2)], new Dictionary<string, int>()), 1).Json;
        var revision = 4;
        var gw = new FakeGateway
        {
            OnCall = (method, p) => method switch
            {
                "profiles.list" => JsonNode.Parse($$$"""{"profiles":[{"name":"default","ui_meta":{"hermes-bots-groups":{{{mirror.ToJsonString()}}}},"ui_meta_revisions":{"hermes-bots-groups":{{{revision}}}}}]}"""),
                "profiles.configure" => Configure(p),
                _ => null,
            },
        };
        JsonNode Configure(JsonObject p)
        {
            Assert.Equal(revision, JsonNode.Parse(p.ToJsonString()).Obj("ui_meta_expected_revisions").Int(GroupSnapshot.MetaKey));
            mirror = p.Obj("ui_meta")!.Get(GroupSnapshot.MetaKey)!.DeepClone();
            revision += 1;
            return JsonNode.Parse("""{"applied":{"ui_meta":true,"ui_meta_revisions":{"hermes-bots-groups":""" + revision + "}}}")!;
        }
        var store = new GroupStore([G.Room("Launch", "r1", entries: 2, revision: 0)]);
        var sync = new GroupSync(store, gw) { Debounce = TimeSpan.FromSeconds(30) };
        store.Append(G.You("new words", 9_000), "id:r1");
        Assert.True(sync.HasPending);
        await sync.FlushNow();
        Assert.False(sync.HasPending);
        Assert.Equal(1, sync.Publishes);
        Assert.Equal(5, sync.RemoteRevision);
        Assert.Equal(["profiles.list", "profiles.configure"], gw.Calls.Select(c => c.Method));
        Assert.Equal(["id:d1", "id:r1"], store.Rooms.Select(r => r.Key).Order(StringComparer.Ordinal));   // the other device's room came in
        Assert.Equal(5, store.Room("id:r1")!.SyncRevision);
        var written = GroupSnapshot.Parse(mirror);
        Assert.Equal(["id:d1", "id:r1"], written.Rooms.Keys.Order(StringComparer.Ordinal));
        Assert.Equal("new words", written.Rooms["id:r1"].Log[^1].Text);
        Assert.Equal(5, written.Rooms["id:r1"].Revision);
        // Nothing pending: no second write.
        await sync.FlushNow();
        Assert.Equal(1, sync.Publishes);
        // A delete goes out as a tombstone.
        sync.Schedule(deleted: "id:none");
        await sync.FlushNow();
        Assert.Equal(2, sync.Publishes);
        Assert.Equal(6, JsonNode.Parse(mirror.ToJsonString()).Obj("deleted").Int("id:none"));   // the tombstone carries the write's revision
        // Pulled: a delete written elsewhere removes the room here.
        var removed = new List<string>();
        store.OnRoomRemoved = r => removed.Add(r.Key);
        var row = JsonNode.Parse("""{"name":"default","ui_meta":{"hermes-bots-groups":{"version":3,"rooms":{},"deleted":{"id:d1":6}}},"ui_meta_revisions":{"hermes-bots-groups":6}}""");
        sync.Pulled(row);
        Assert.Equal(["id:d1"], removed);
        Assert.Equal(6, store.Tombstones["id:d1"]);
        sync.Shutdown();
    }

    [Fact]
    public async Task ARefusedWriteStaysPendingAndOfflineWaitsForThePull()
    {
        var gw = new FakeGateway
        {
            OnCall = (method, _) => method == "profiles.list"
                ? JsonNode.Parse("""{"profiles":[{"name":"default","ui_meta":{},"ui_meta_revisions":{}}]}""")
                : JsonNode.Parse("""{"applied":{"ui_meta":false}}"""),
        };
        var store = new GroupStore([G.Room("Launch", "r1", entries: 1)]);
        var sync = new GroupSync(store, gw) { Debounce = TimeSpan.FromSeconds(30), BackoffUnitSeconds = 30 };
        sync.Schedule(changed: "id:r1");
        await sync.FlushNow();
        Assert.True(sync.HasPending);
        Assert.Equal(1, sync.Publishes);
        var offline = new FakeGateway { OnCall = (_, _) => throw new Hermes.Core.Net.GatewayException("offline", "offline") };
        var sync2 = new GroupSync(store, offline) { Debounce = TimeSpan.FromSeconds(30) };
        sync2.Schedule(changed: "id:r1");
        await sync2.FlushNow();
        Assert.True(sync2.HasPending);
        Assert.Equal(0, sync2.Publishes);
        sync.Shutdown();
        sync2.Shutdown();
    }
}
