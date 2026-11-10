// [sync] The Bots list's hand-picked orders follow the owner from device to device (owner 2026-11-03): the pinned
// tiles' order and Sort By › Manual's rows. Who is pinned already lives on the gateway (`hermes-bots`); these are the
// document "bots" (`GatewaySync`). Unread marks stay on each device.

import Foundation

extension BotStore: GatewaySynced {
    var syncName: String { "bots" }

    func syncValue() -> JSONValue {
        [
            "pinOrder": .array(device.pinOrder.map { .string($0) }),
            "rowOrder": device.rowOrder.map { .array($0.map { .string($0) }) } ?? .null,
        ]
    }

    func adoptSynced(_ value: JSONValue, merge: GatewaySyncMerge, base: JSONValue?) {
        guard merge != .rebase else { return }        // this device's order is the newest word
        let pins = (value["pinOrder"]?.array ?? []).compactMap(\.string)
        if !(merge == .firstContact && pins.isEmpty) { device.pinOrder = Array(pins.prefix(PinOrder.limit)) }
        if let rows = value["rowOrder"]?.array {
            device.rowOrder = rows.compactMap(\.string)
        } else if merge == .replace {
            device.rowOrder = nil
        }
        persistState()
        rebuild()
    }
}
