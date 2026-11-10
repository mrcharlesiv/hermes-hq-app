// [groups] Keys and ids for rooms (docs/spec/3x-groups.md §3.2; `HB/group-chat.ts:222-224`, `HB/group-membership.ts`).

import Foundation

nonisolated enum GroupKeys {
    static func roomKey(roomId: String?, name: String) -> String {
        if let roomId, !roomId.isEmpty { return "id:\(roomId)" }
        return "name:\(name)"
    }

    static func memberKey(_ member: GroupMember) -> String {
        if member.sourceScoped, let connection = member.connectionId, !connection.isEmpty { return "\(connection)::\(member.name)" }
        return member.name
    }

    static func thread(_ thread: String?) -> String {
        guard let thread, !thread.isEmpty else { return "legacy" }
        return thread
    }

    static func sessionKey(thread: String, memberKey: String) -> String { "thread:\(thread)::\(memberKey)" }
    static func watermarkKey(thread: String, memberKey: String) -> String { "\(thread)::\(memberKey)" }
    static func muteKey(_ roomKey: String) -> String { "room:\(roomKey)" }
    static func pinEntry(_ roomKey: String) -> String { "group:\(roomKey)" }

    private static let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")

    static func random5() -> String { String((0..<5).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] }) }
    static func stamp(_ now: Date = Date()) -> String { String(Int(now.timeIntervalSince1970 * 1000), radix: 36) }
    static func newRoomId(now: Date = Date()) -> String { "r\(stamp(now))-\(random5())" }
    static func newThreadId(now: Date = Date()) -> String { "t\(stamp(now))-\(random5())" }
    static func newEntryId() -> String { UUID().uuidString.lowercased() }

    /// A hidden member session's title: `Group: <roomId or name> · <thread>`.
    static func sessionTitle(room: GroupRoom, thread: String) -> String { "Group: \(room.roomId ?? room.name) · \(thread)" }
    static func isPlumbingTitle(_ title: String) -> Bool { title.hasPrefix("Group: ") }

    /// A room's name as it is saved: trimmed, at most 64 characters.
    static func cleanName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(GroupLimits.nameMax)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `uniqueGroupChatName`: the name itself when free, else " 2" … " 99" appended (the base cut to fit 64).
    static func uniqueName(_ raw: String, taken: Set<String>) -> String {
        let base = cleanName(raw)
        guard taken.contains(base) else { return base }
        for n in 2...99 {
            let suffix = " \(n)"
            let candidate = String(base.prefix(GroupLimits.nameMax - suffix.count)).trimmingCharacters(in: .whitespaces) + suffix
            if !taken.contains(candidate) { return candidate }
        }
        return String(base.prefix(GroupLimits.nameMax - 6)) + " " + random5()
    }

    /// The rooms a bot's meta names: `groups`, else the older scalar `group`.
    static func groups(of meta: [String: JSONValue]) -> [String] {
        if let list = meta["groups"]?.array {
            var seen = Set<String>()
            return list.compactMap { $0.string }.filter { !$0.isEmpty && seen.insert($0).inserted }
        }
        if let one = meta["group"]?.string, !one.isEmpty { return [one] }
        return []
    }

    /// The membership patch rule (`HB/group-membership.ts:181-201`): nil when nothing changes.
    static func membership(_ meta: [String: JSONValue], adding name: String) -> [String]? {
        let current = groups(of: meta)
        return current.contains(name) ? nil : current + [name]
    }

    static func membership(_ meta: [String: JSONValue], removing name: String) -> [String]? {
        let current = groups(of: meta)
        return current.contains(name) ? current.filter { $0 != name } : nil
    }

    static func membership(_ meta: [String: JSONValue], renaming old: String, to new: String) -> [String]? {
        let current = groups(of: meta)
        guard current.contains(old) else { return nil }
        var seen = Set<String>()
        return current.map { $0 == old ? new : $0 }.filter { seen.insert($0).inserted }
    }

    /// The `ui_meta["hermes-bots"]` patch for a new `groups` list: `group` = its first, or null.
    static func patch(_ groups: [String]) -> [String: JSONValue] {
        ["groups": .array(groups.map(JSONValue.string)), "group": groups.first.map(JSONValue.string) ?? .null]
    }
}

/// Moving a room's mute and unread mark when the room map changes (`S/ui-bots/room-marks.ts:23-50`, `roomChanges`).
nonisolated enum GroupMarks {
    struct Changes: Equatable, Sendable {
        /// Old key → new key (a `name:` room renamed, or one that gained a `roomId`).
        var moved: [String: String] = [:]
        /// Keys whose marks go (a tombstone).
        var dropped: Set<String> = []
    }

    struct Snapshot: Equatable, Sendable {
        var key: String
        var name: String
        var roomId: String?
    }

    /// `renames`: explicit old-name → new-name pairs for id-less rooms (the caller knows them; two snapshots alone
    /// cannot tell a rename of a `name:` room from a delete plus a create).
    static func changes(before: [Snapshot], after: [Snapshot], tombstones: Set<String>, renames: [String: String] = [:]) -> Changes {
        var out = Changes()
        let afterKeys = Set(after.map(\.key))
        let afterByName = Dictionary(after.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for room in before where !afterKeys.contains(room.key) {
            if tombstones.contains(room.key) { out.dropped.insert(room.key); continue }
            guard room.roomId == nil else { continue }       // an `id:` room missing from one snapshot: nothing changes
            if let next = renames[room.name], let target = afterByName[next] {
                out.moved[room.key] = target.key
            } else if let target = afterByName[room.name], target.roomId != nil {
                out.moved[room.key] = target.key             // the same room gained a roomId
            }
        }
        for key in tombstones where !afterKeys.contains(key) { out.dropped.insert(key) }
        return out
    }
}
