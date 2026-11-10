// The Pinned section rules (spec 1x-settings §5.2): a pinned bot is filed in the "Pinned" section so desktop Hermes,
// which has no pinned area, shows what the phone's tiles do. Ported line for line from
// `S/ui-bots/pinned-section-model.ts`. Pure: patches are applied by `BotMetaWriter`.
//
// A meta is the bot's `ui_meta['hermes-bots']` object; a patch is the keys to set (JSON `null` is a value, sent as
// `null`, never a deletion).

import Foundation

nonisolated enum PinnedSection {
    typealias Meta = [String: JSONValue]
    typealias Patch = [String: JSONValue]

    static let id = RosterRules.pinnedSectionId          // "hermes-hq-pinned"
    static let name = RosterRules.pinnedSectionName      // "Pinned"
    static let homeKey = "pinnedFrom"

    /// The home a pin recorded: `.section` / `.noSection` (`null`), or `.unrecorded` (JS `undefined`).
    static func pinHome(_ meta: Meta?) -> PinHome { PinHome(meta?[homeKey]) }

    /// `typeof meta.sectionId === 'string' && meta.sectionId ? meta.sectionId : null`
    static func current(_ meta: Meta) -> String? {
        if case .string(let s)? = meta["sectionId"], !s.isEmpty { return s }
        return nil
    }

    /// The section menus and Bot Info show for a bot: a pinned bot's is the home it goes back to when unpinned.
    static func shownSectionId(_ meta: Meta?, sectionId: String?) -> String? {
        guard sectionId == id else { return sectionId }
        if case .section(let home, _) = pinHome(meta) { return home }
        return nil
    }

    /// Pinned is never a place a menu moves a bot to (Pin is).
    static func withoutPinned(_ sections: [RosterSectionRecord]) -> [RosterSectionRecord] { sections.filter { $0.id != id } }

    /// The write that makes a bot's section agree with its pin, or nil when they agree. `sectionName(id)` is the name of
    /// a section this device still has (nil for one that's gone).
    static func pinnedSectionPatch(_ meta: Meta?, sectionName: (String) -> String?) -> Patch? {
        guard let meta else { return nil }
        let home = pinHome(meta)
        let current = current(meta)
        let homeUndefined = home == .unrecorded
        if RosterText.truthy(meta["pinned"]) {
            if current != id {
                let name: JSONValue = meta["sectionName"]?.string.map(JSONValue.string) ?? .null
                let from: JSONValue = current.map { .object(["id": .string($0), "name": name]) } ?? .null
                return ["sectionId": .string(id), "sectionName": .string(Self.name), homeKey: from]
            }
            if meta["sectionName"] != .string(Self.name) {
                var patch: Patch = ["sectionName": .string(Self.name)]
                if homeUndefined { patch[homeKey] = .null }
                return patch
            }
            return homeUndefined ? [homeKey: .null] : nil
        }
        if current != id { return homeUndefined ? nil : [homeKey: false] }
        if homeUndefined { return ["pinned": true, "sectionName": .string(Self.name), homeKey: .null] }
        if case .section(let homeId, _) = home, let back = sectionName(homeId) {
            return ["sectionId": .string(homeId), "sectionName": .string(back), homeKey: false]
        }
        return ["sectionId": .null, "sectionName": .null, homeKey: false]
    }

    /// A pin or unpin from the phone, as one write: the flag and the section it implies.
    static func pinPatch(_ meta: Meta?, pinned: Bool, sectionName: (String) -> String?) -> Patch {
        var next = meta ?? [:]
        next["pinned"] = .bool(pinned)
        var patch: Patch = ["pinned": .bool(pinned)]
        for (key, value) in pinnedSectionPatch(next, sectionName: sectionName) ?? [:] { patch[key] = value }
        return patch
    }

    /// Moving a bot from a menu or a drop. A pinned bot stays in Pinned (the pick is where an unpin puts it); moving a
    /// bot onto Pinned pins it. Nil: an ordinary move (`{"sectionId", "sectionName"}`) applies.
    static func sectionMovePatch(_ meta: Meta?, target: String?, sectionName: (String) -> String?) -> Patch? {
        let pinned = RosterText.truthy(meta?["pinned"])
        if target == id { return pinned ? [:] : pinPatch(meta, pinned: true, sectionName: sectionName) }
        guard pinned else { return nil }
        guard let target else { return [homeKey: .null] }
        return [homeKey: .object(["id": .string(target), "name": sectionName(target).map(JSONValue.string) ?? .null])]
    }

    /// The values `patch` replaces, to put back if the gateway refuses it (`?? (pinnedFrom ? false : null)`).
    static func undoOf(_ meta: Meta?, _ patch: Patch) -> Patch {
        var undo: Patch = [:]
        for key in patch.keys {
            if let value = meta?[key], !value.isNull { undo[key] = value } else { undo[key] = key == homeKey ? false : .null }
        }
        return undo
    }

    /// `{...meta, ...patch}`.
    static func apply(_ patch: Patch?, to meta: Meta) -> Meta {
        var next = meta
        for (key, value) in patch ?? [:] { next[key] = value }
        return next
    }
}
