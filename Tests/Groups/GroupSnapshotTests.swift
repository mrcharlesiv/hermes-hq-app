import Foundation
import Testing
@testable import HermesHQNative

/// The gateway mirror of rooms (docs/spec/3x-groups.md §5): reading every version and any damage, building under the
/// size cap, merging two writers, and merging the mirror into this device's records.
@Suite struct GroupSnapshotTests {
    private func parse(_ text: String) -> GroupMirror { GroupSnapshot.parse(BotsFixture.parse(text)) }

    private func room(_ name: String, id: String? = nil, entries: Int = 3, revision: Int = 1, start: Double = 1_000, text: String = "hello") -> GroupRoom {
        var room = GroupRoom(name: name, roomId: id)
        room.members = [GroupMember(name: "ivy", handle: "ivy"), GroupMember(name: "research", handle: "research")]
        room.log = (0..<entries).map { GroupsTest.you("\(text) \($0)", at: start + Double($0), id: "\(name)-\($0)") }
        room.syncRevision = revision
        return room
    }

    // MARK: Reading

    @Test func readsAVersionThreeEnvelope() {
        let mirror = parse(#"""
        {"version":3,"updatedAt":1700000000000,"deleted":{"id:gone":9},
         "rooms":{"id:r1":{"name":" Launch Room ","roomId":"r1","holdDetection":false,"revision":4,"omitted":2,"color":"teal",
           "members":[{"name":"ivy","handle":"ivy","nickname":"S"},{"name":"far","sourceScoped":true,"connectionId":"c9","connectionLabel":"Studio"}],
           "image":"data:image/jpeg;base64,AAAA",
           "log":[{"id":"b","from":{"kind":"member","name":"ivy"},"text":"second","at":20,"thread":"t1"},
                  {"id":"a","from":{"kind":"user","name":"You"},"text":"first","at":10,"thread":"t1","truncated":true}]}}}
        """#)
        #expect(mirror.version == 3 && mirror.updatedAt == 1_700_000_000_000 && mirror.deleted == ["id:gone": 9])
        let room = try! #require(mirror.rooms["id:r1"])
        #expect(room.name == "Launch Room" && room.roomId == "r1" && !room.holdDetection && room.revision == 4 && room.omitted == 2)
        #expect(room.members.map(\.key) == ["ivy", "c9::far"] && room.members[1].connectionLabel == "Studio")
        #expect(room.image == "data:image/jpeg;base64,AAAA")
        #expect(room.log.map(\.text) == ["first", "second"], "the log is read oldest first")
        #expect(room.log[0].truncated == true && room.log[1].truncated == nil)
        #expect(room.extra == ["color": "teal"], "a key this app does not know is kept")
        // …and written back untouched, member keys included.
        let back = GroupSnapshot.json(room).object ?? [:]
        #expect(back["color"] == "teal")
        #expect(back["members"]?.array?.first?.object?["nickname"] == "S")
    }

    @Test func readsVersionOneAndTwo() {
        let one = parse(#"{"rooms":{"Old Room":{"members":[{"name":"ivy"}],"log":[{"from":{"kind":"user","name":"You"},"text":"hi","at":5}]}},"deleted":["Gone"]}"#)
        #expect(one.version == 1)
        #expect(one.rooms.keys.sorted() == ["name:Old Room"] && one.rooms["name:Old Room"]?.log.count == 1)
        #expect(one.deleted == ["name:Gone": 0])
        let two = parse(#"{"version":2,"rooms":{"Team":{"name":"ignored","revision":3,"log":[]}},"deleted":{"Gone":6}}"#)
        #expect(two.version == 2 && two.rooms["name:Team"]?.name == "Team" && two.rooms["name:Team"]?.revision == 3)
        #expect(two.deleted == ["name:Gone": 6])
        // The next write is always version 3.
        let written = GroupSnapshot.envelope(GroupSnapshot.merge(remote: one, local: GroupMirror(), writeRevision: 1), now: 9).json
        #expect(written.object?["version"] == 3)
    }

    @Test func damageNeverBreaksTheRead() {
        #expect(parse(#""just a string""#) == GroupMirror())
        #expect(GroupSnapshot.parse(nil) == GroupMirror())
        #expect(parse(#"{"version":3,"rooms":[1,2,3]}"#).rooms.isEmpty)
        let mirror = parse(#"""
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
        """#.replacingOccurrences(of: "IMAGE", with: String(repeating: "A", count: 30_000)))
        #expect(mirror.rooms.keys.sorted() == ["id:good"], "a broken room is skipped whole; the others still read")
        let good = try! #require(mirror.rooms["id:good"])
        #expect(good.revision == 0 && good.omitted == 0)
        #expect(good.members.map(\.name) == ["inbox", "notes"])
        #expect(good.image == nil, "an image past 24,000 characters is not read")
        #expect(good.log.map(\.text) == ["once", "fine"], "bad entries are skipped and a repeated id is read once")
    }

    @Test func entryKeysAreTheIdElseTheContent() {
        #expect(GroupSnapshot.entryKey(GroupsTest.you("hi", at: 5, thread: "t1", id: "abc")) == "id:abc")
        #expect(GroupSnapshot.entryKey(GroupsTest.you("hi", at: 5, thread: nil)) == #"[5,"user","You","","legacy","hi"]"#)
        #expect(GroupSnapshot.entryKey(GroupsTest.member("ivy", "yo", at: 6.5, thread: "legacy-3", source: "Studio")) == #"[6.5,"member","ivy","Studio","legacy","yo"]"#)
    }

    // MARK: Building

    @Test func aRoomIsCompactedForTheMirror() {
        var full = room("Launch", id: "r1", entries: 20)
        full.log[19].text = String(repeating: "x", count: 5_000)
        full.log[19].from.gateway = "http://127.0.0.1"
        full.pinned = true
        let made = GroupSnapshot.compact(full)
        #expect(made.log.count == 16 && made.omitted == 4 && made.log.first?.id == "Launch-4")
        #expect(made.log.last?.text.utf16.count == 1_200 && made.log.last?.truncated == true && made.log.last?.from.gateway == nil)
        #expect(made.revision == 1 && made.members.count == 2)
        // Rooms with nothing said stay on the device.
        let local = GroupSnapshot.local(rooms: [full, GroupRoom(name: "Empty", roomId: "e")], tombstones: ["id:gone": 3])
        #expect(local.rooms.keys.sorted() == ["id:r1"] && local.deleted == ["id:gone": 3])
        // This iPhone's own fields never travel.
        let keys = Set((GroupSnapshot.json(made).object ?? [:]).keys)
        #expect(keys == ["name", "roomId", "holdDetection", "revision", "members", "log", "omitted"])
    }

    @Test func sizeIsCountedTheWayPythonWritesIt() {
        // json.dumps({"a": 1}) → 8 bytes; non-ASCII is \uXXXX; an emoji is a surrogate pair.
        #expect(GroupSnapshot.pythonSize(["a": 1]) == 8)
        #expect(GroupSnapshot.pythonSize([1, true, false, nil]) == "[1, true, false, null]".utf8.count)
        #expect(GroupSnapshot.pythonSize("é") == 8 && GroupSnapshot.pythonSize("😀") == 14)
        #expect(GroupSnapshot.pythonSize("a\nb\"c\\") == #""a\nb\"c\\""#.utf8.count)
        #expect(GroupSnapshot.pythonSize("\u{01}") == 8)
        #expect(GroupSnapshot.pythonSize(1700000000000.0) == 13)
        // Never lower than Python's own count (commas and colons inside a text are counted double, as the web does).
        #expect(GroupSnapshot.pythonSize("a,b: c") >= #""a,b: c""#.utf8.count)
    }

    @Test func theEnvelopeStaysUnderTheCapAndKeepsTheNewestRooms() {
        let rooms = (0..<40).map { index in
            room("Room \(index)", id: "r\(index)", entries: 16, start: Double(index) * 1_000, text: String(repeating: "word ", count: 220))
        }
        let local = GroupSnapshot.local(rooms: rooms, tombstones: [:])
        let made = GroupSnapshot.envelope(local, now: 1)
        // Every room is counted with a separator, the first one too: the count is 2 over the envelope's own size, never under.
        #expect(made.bytes <= 48_000 && GroupSnapshot.pythonSize(made.json) + 2 == made.bytes, "the count follows the envelope's size")
        #expect(made.kept.rooms.count < 40 && !made.kept.rooms.isEmpty)
        #expect(made.kept.rooms["id:r39"] != nil, "the newest room is in")
        #expect(made.kept.rooms["id:r0"] == nil, "the oldest gave way")
        // A room that does not fit whole loses its oldest entries and says how many.
        let cut = made.kept.rooms.values.filter { $0.log.count < 16 }
        for one in cut { #expect(one.omitted == 16 - one.log.count && one.log.last?.id?.hasSuffix("-15") == true) }
        // What Python would write is never larger than what was counted.
        let data = try! JSONSerialization.data(withJSONObject: made.json.foundation, options: [])
        #expect(data.count <= 48_000)
    }

    @Test func aRoomGivesUpEntriesThenItsImageThenItsPlace() {
        var big = room("Big", id: "big", entries: 16, start: 5_000, text: String(repeating: "y", count: 1_150))
        big.image = String(repeating: "I", count: 20_000)
        let made = GroupSnapshot.envelope(GroupSnapshot.local(rooms: [big], tombstones: [:]), now: 1, limit: 24_000)
        let kept = try! #require(made.kept.rooms["id:big"])
        #expect(kept.image != nil && kept.log.count < 16 && kept.omitted == 16 - kept.log.count && made.bytes <= 24_000)
        #expect(GroupSnapshot.pythonSize(made.json) + 2 == made.bytes, "counted entry by entry, the size is still the envelope's")
        let tight = GroupSnapshot.envelope(GroupSnapshot.local(rooms: [big], tombstones: [:]), now: 1, limit: 3_000)
        #expect(tight.kept.rooms["id:big"]?.image == nil && tight.kept.rooms["id:big"]?.log.count == 1)
        #expect(GroupSnapshot.pythonSize(tight.json) + 2 == tight.bytes)
        let none = GroupSnapshot.envelope(GroupSnapshot.local(rooms: [big], tombstones: [:]), now: 1, limit: 200)
        #expect(none.kept.rooms.isEmpty && none.bytes <= 200)
    }

    @Test func tombstonesAreCappedAtSixtyFour() {
        var mirror = GroupMirror()
        for index in 0..<90 { mirror.deleted["id:gone\(index)"] = index }
        let made = GroupSnapshot.envelope(mirror, now: 1)
        #expect(made.kept.deleted.count == 64 && made.kept.deleted["id:gone89"] == 89 && made.kept.deleted["id:gone0"] == nil)
    }

    @Test func buildSpeed() {
        // 40 rooms of 16 entries build well inside a frame's budget (§9, P4): the best of five on a busy Mac.
        let rooms = (0..<40).map { room("Room \($0)", id: "r\($0)", entries: 16, start: Double($0) * 100, text: String(repeating: "word ", count: 30)) }
        var best = Duration.seconds(10)
        for _ in 0..<5 {
            let clock = ContinuousClock()
            let took = clock.measure { _ = GroupSnapshot.envelope(GroupSnapshot.local(rooms: rooms, tombstones: [:]), now: 1) }
            best = min(best, took)
        }
        #expect(best < .milliseconds(20), "took \(best)")
    }

    // MARK: Merging two writers

    @Test func mergeUnionsLogsAndNeverDeletesByAbsence() {
        var theirs = GroupSnapshot.local(rooms: [room("Launch", id: "r1", entries: 2, revision: 4), room("Theirs", id: "t", entries: 1)], tombstones: [:])
        theirs.rooms["id:r1"]?.log.append(GroupsTest.member("ivy", "From the desktop", at: 5_000, id: "desk"))
        var mine = GroupSnapshot.local(rooms: [room("Launch", id: "r1", entries: 3, revision: 4), room("Mine", id: "m", entries: 1)], tombstones: [:])
        mine.rooms["id:r1"]?.log.append(GroupsTest.you("From the phone", at: 6_000, id: "phone"))
        let merged = GroupSnapshot.merge(remote: theirs, local: mine, changed: ["id:r1"], writeRevision: 5)
        #expect(merged.rooms.keys.sorted() == ["id:m", "id:r1", "id:t"], "a room one side lacks is kept")
        let launch = try! #require(merged.rooms["id:r1"])
        #expect(launch.log.map { $0.id ?? "" } == ["Launch-0", "Launch-1", "Launch-2", "desk", "phone"])
        #expect(launch.revision == 5)
        #expect(merged.rooms["id:m"]?.revision == 1, "a room this write did not change keeps its revision")
    }

    @Test func anEntryDeletedHereStaysOutOfTheMergeAndTheDevice() {
        // The mirror still has the send this device deleted (it was published when it was sent).
        let published = GroupSnapshot.local(rooms: [room("Launch", id: "r1", entries: 3, revision: 4)], tombstones: [:])
        var mine = room("Launch", id: "r1", entries: 3, revision: 4)
        let gone = GroupSnapshot.entryKey(mine.log[1])
        mine.log.remove(at: 1)
        mine.removed = [gone]
        // Read back: the mirror's copy is not taken in again.
        let applied = GroupSnapshot.apply(published, to: [mine])
        #expect(applied.rooms[0].log.map { $0.id ?? "" } == ["Launch-0", "Launch-2"] && !applied.changed)
        // Written: the merge leaves it out, and keeps everything else of both sides.
        var theirs = published
        theirs.rooms["id:r1"]?.log.append(GroupsTest.member("ivy", "From the desktop", at: 5_000, id: "desk"))
        let local = GroupSnapshot.local(rooms: [mine], tombstones: [:])
        let merged = GroupSnapshot.merge(remote: theirs, local: local, changed: ["id:r1"], removed: ["id:r1": [gone]], writeRevision: 5)
        #expect(merged.rooms["id:r1"]?.log.map { $0.id ?? "" } == ["Launch-0", "Launch-2", "desk"])
        // Without the note of the delete, a union of logs would bring it back (never delete by absence).
        let union = GroupSnapshot.merge(remote: theirs, local: local, changed: ["id:r1"], writeRevision: 5)
        #expect(union.rooms["id:r1"]?.log.count == 4)
        // The note is saved with the room and read from a record written before it existed.
        let data = try! JSONEncoder().encode(mine)
        #expect((try? JSONDecoder().decode(GroupRoom.self, from: data))?.removed == [gone])
        #expect((try? JSONDecoder().decode(GroupRoom.self, from: Data(#"{"name":"Old"}"#.utf8)))?.removed == [])
    }

    @Test func mergeKeepsTheWholeTwinOfACutEntry() {
        var theirs = GroupSnapshot.local(rooms: [room("Launch", id: "r1", entries: 1)], tombstones: [:])
        var mine = theirs
        theirs.rooms["id:r1"]?.log[0].text = "whole text"
        mine.rooms["id:r1"]?.log[0].text = "whole… [truncated]"
        mine.rooms["id:r1"]?.log[0].truncated = true
        #expect(GroupSnapshot.merge(remote: theirs, local: mine, writeRevision: 2).rooms["id:r1"]?.log[0].text == "whole text")
        #expect(GroupSnapshot.merge(remote: mine, local: theirs, writeRevision: 2).rooms["id:r1"]?.log[0].text == "whole text")
    }

    @Test func identityFollowsTheHigherRevision() {
        var theirs = GroupSnapshot.local(rooms: [room("Release", id: "r1", entries: 1, revision: 7)], tombstones: [:])
        theirs.rooms["id:r1"]?.members = [GroupMember(name: "ivy"), GroupMember(name: "ops")]
        let mine = GroupSnapshot.local(rooms: [room("Launch", id: "r1", entries: 1, revision: 4)], tombstones: [:])
        let behind = GroupSnapshot.merge(remote: theirs, local: mine, writeRevision: 8)
        #expect(behind.rooms["id:r1"]?.name == "Release" && behind.rooms["id:r1"]?.members.map(\.name) == ["ivy", "ops"])
        #expect(behind.rooms["id:r1"]?.revision == 7)
        // This write changes the room: its own identity wins and is stamped.
        let ahead = GroupSnapshot.merge(remote: theirs, local: mine, changed: ["id:r1"], writeRevision: 8)
        #expect(ahead.rooms["id:r1"]?.name == "Launch" && ahead.rooms["id:r1"]?.revision == 8)
        // Equal revisions: the members of both.
        var level = theirs
        level.rooms["id:r1"]?.revision = 4
        #expect(GroupSnapshot.merge(remote: level, local: mine, writeRevision: 9).rooms["id:r1"]?.members.map(\.name) == ["ivy", "research", "ops"])
    }

    @Test func tombstonesDeleteAndAnOlderWriteCannotRevive() {
        let live = GroupSnapshot.local(rooms: [room("Launch", id: "r1", entries: 2, revision: 9)], tombstones: [:])
        // Deleting here: the room goes and the tombstone carries this write's revision.
        let deleted = GroupSnapshot.merge(remote: live, local: GroupMirror(), deleted: ["id:r1"], writeRevision: 10)
        #expect(deleted.rooms.isEmpty && deleted.deleted == ["id:r1": 10])
        // An `id:` room stays deleted whatever revision the other side still holds.
        let revived = GroupSnapshot.merge(remote: live, local: GroupMirror(rooms: [:], deleted: ["id:r1": 2]), writeRevision: 11)
        #expect(revived.rooms.isEmpty && revived.deleted == ["id:r1": 2])
        // A `name:` room made again after its tombstone outlives it.
        let named = GroupSnapshot.local(rooms: [room("Team", entries: 1, revision: 6)], tombstones: [:])
        let again = GroupSnapshot.merge(remote: named, local: GroupMirror(rooms: [:], deleted: ["name:Team": 3]), writeRevision: 7)
        #expect(again.rooms["name:Team"] != nil && again.deleted.isEmpty)
        let gone = GroupSnapshot.merge(remote: named, local: GroupMirror(rooms: [:], deleted: ["name:Team": 6]), writeRevision: 7)
        #expect(gone.rooms.isEmpty && gone.deleted == ["name:Team": 6])
    }

    // MARK: Into this device's rooms

    @Test func applyAdoptsNewRoomsAndNewEntriesInPlace() {
        let local = [room("Launch", id: "r1", entries: 3, revision: 4)]
        var mirror = GroupSnapshot.local(rooms: local + [room("Elsewhere", id: "e1", entries: 2, revision: 2)], tombstones: [:])
        mirror.rooms["id:r1"]?.log.append(GroupsTest.member("ivy", "From the desktop", at: 9_000, id: "desk"))
        mirror.rooms["id:e1"]?.omitted = 5
        let applied = GroupSnapshot.apply(mirror, to: local)
        #expect(applied.changed && applied.rooms.map(\.name) == ["Launch", "Elsewhere"])
        #expect(applied.rooms[0].log.map { $0.id ?? "" } == ["Launch-0", "Launch-1", "Launch-2", "desk"])
        #expect(applied.rooms[1].omitted == 5 && applied.rooms[1].syncRevision == 2 && applied.rooms[1].members.count == 2)
        // The same mirror again changes nothing (an entry is never shown twice).
        let again = GroupSnapshot.apply(mirror, to: applied.rooms)
        #expect(!again.changed && again.rooms == applied.rooms)
    }

    @Test func applyKeepsTheWholeLocalEntryOverItsCutTwin() {
        var mine = room("Launch", id: "r1", entries: 1)
        mine.log = [GroupMessage(id: nil, at: 10, from: .you, text: String(repeating: "long ", count: 400), thread: "t1", truncated: nil)]
        let mirror = GroupSnapshot.local(rooms: [mine], tombstones: [:])
        #expect(mirror.rooms["id:r1"]?.log[0].truncated == true)
        let applied = GroupSnapshot.apply(mirror, to: [mine])
        #expect(applied.rooms[0].log.count == 1 && applied.rooms[0].log[0].text.count == 2_000, "the cut copy is the same message")
    }

    @Test func applyFollowsARenameOnlyFromAHigherRevision() {
        let mine = room("Launch", id: "r1", entries: 1, revision: 4)
        var renamed = GroupSnapshot.local(rooms: [mine], tombstones: [:])
        renamed.rooms["id:r1"]?.name = "Release"
        renamed.rooms["id:r1"]?.members = [GroupMember(name: "ivy"), GroupMember(name: "ops")]
        #expect(GroupSnapshot.apply(renamed, to: [mine]).rooms[0].name == "Launch", "the same revision changes nothing")
        renamed.rooms["id:r1"]?.revision = 5
        let followed = GroupSnapshot.apply(renamed, to: [mine])
        #expect(followed.rooms[0].name == "Release" && followed.rooms[0].members.map(\.name) == ["ivy", "ops"] && followed.rooms[0].syncRevision == 5)
        // A room with its own change waiting to be published keeps its identity until that write.
        #expect(GroupSnapshot.apply(renamed, to: [mine], protect: ["id:r1"]).rooms[0].name == "Launch")
    }

    @Test func applyRekeysARoomThatGainedItsId() {
        var mine = room("Team", entries: 1)
        mine.pinned = true
        var mirror = GroupMirror()
        var theirs = GroupSnapshot.compact(mine)
        theirs.roomId = "r77"
        mirror.rooms["id:r77"] = theirs
        let applied = GroupSnapshot.apply(mirror, to: [mine])
        #expect(applied.rooms.count == 1 && applied.rooms[0].key == "id:r77" && applied.rooms[0].pinned)
        #expect(applied.rekeyed == ["name:Team": "id:r77"])
    }

    @Test func applyRemovesTombstonedRoomsAndIgnoresTheirStaleCopies() {
        let mine = [room("Launch", id: "r1", entries: 1, revision: 9), room("Team", entries: 1, revision: 6), room("Keep", id: "k", entries: 1)]
        var mirror = GroupMirror()
        mirror.deleted = ["id:r1": 2, "name:Team": 6]
        let applied = GroupSnapshot.apply(mirror, to: mine)
        #expect(applied.rooms.map(\.name) == ["Keep"] && applied.removed.map(\.name).sorted() == ["Launch", "Team"])
        // A stale copy of a room this device deleted is not adopted again.
        var stale = GroupMirror()
        stale.rooms["id:r1"] = GroupSnapshot.compact(mine[0])
        let held = GroupSnapshot.apply(stale, to: [mine[2]], tombstones: ["id:r1": 10])
        #expect(held.rooms.map(\.name) == ["Keep"] && !held.changed)
        // A `name:` room made again with a higher revision than its tombstone lives.
        var again = GroupMirror()
        again.rooms["name:Team"] = GroupSnapshot.compact(room("Team", entries: 1, revision: 8))
        #expect(GroupSnapshot.apply(again, to: [], tombstones: ["name:Team": 6]).rooms.map(\.name) == ["Team"])
    }

    @Test func anEntryMergedInEarlierMovesTheMarksPastIt() {
        var mine = room("Launch", id: "r1", entries: 0)
        mine.log = [GroupsTest.you("one", at: 10, id: "a"), GroupsTest.member("ivy", "three", at: 30, id: "c")]
        mine.watermarks = ["t1::ivy": 2, "t1::research": 1]
        var mirror = GroupSnapshot.local(rooms: [mine], tombstones: [:])
        mirror.rooms["id:r1"]?.log.insert(GroupsTest.member("research", "two", at: 20, id: "b"), at: 1)
        let applied = GroupSnapshot.apply(mirror, to: [mine])
        #expect(applied.rooms[0].log.map { $0.id ?? "" } == ["a", "b", "c"])
        #expect(applied.rooms[0].watermarks == ["t1::ivy": 3, "t1::research": 1])
    }
}

private extension JSONValue {
    /// Foundation objects, for `JSONSerialization`'s byte count.
    nonisolated var foundation: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let a): return a.map(\.foundation)
        case .object(let o): return o.mapValues(\.foundation)
        }
    }
}
