// [groups] Contract additions for stream "groups" (docs/spec/3x-groups.md §3.4): group chats ("rooms") and the sender
// decoration deliveries share with them. Kept out of Contracts.swift; the only edit there is `ChatMessage.sender`.

import UIKit

/// A sender other than you or the chat's own bot, drawn on a bubble (rooms, and deliveries: row L301).
nonisolated struct ChatSender: Hashable, Sendable {
    /// Member key, or a delivering bot's handle.
    var key: String
    /// "Ivy".
    var name: String
    /// Its head record; nil draws the default head for `profile`.
    var head: JSONValue?
    /// The profile the default head is made for.
    var profile: String
    /// Its colour before the 4.5:1 adjustment ("#RRGGBB"); nil = the label colour.
    var colorHex: String?
}

/// One member answering now (a typing row).
nonisolated struct RoomTyping: Hashable, Sendable {
    var sender: ChatSender?
    /// `Ivy is replying…` / `Waiting for your answer` / `Replying…`.
    var label: String
}

/// What a room adds to the chat screen. `ChatViewController` checks for it the way it checks `ChatQueueing`.
@MainActor protocol ChatRoomSurface: AnyObject {
    var roomKey: String { get }
    var roomName: String { get }
    var typing: [RoomTyping] { get }
    /// Display names of held members.
    var paused: [String] { get }
    /// A round is in flight (the composer shows Stop).
    var roomRunning: Bool { get }
    /// The bubble the next send answers (D4).
    var replyTarget: GroupMessage? { get set }
    var isEmptyRoom: Bool { get }
    var memberNames: [String] { get }
    /// `Ivy is replying…` / `Waiting for your reply` / the members' names.
    var roomStatusLine: String { get }
    /// Your sends no member took: message id → the last failure's reason.
    var undelivered: [String: String] { get }
    var retrying: Set<String> { get }
    /// The members a `@` suggestion offers: tag, name, sender (face).
    var mentionChoices: [(tag: String, name: String, sender: ChatSender?)] { get }
    /// The member whose question or approval the room shows now (its display name), nil when none is on turn.
    var promptAsker: String? { get }
    /// The room was deleted (here or elsewhere) while open: the screen pops.
    var onRoomGone: ((String) -> Void)? { get set }
    /// The reply chip, paused capsule or running state changed.
    var onChromeChange: (() -> Void)? { get set }
    /// A send was refused: nil = handled silently, else what to tell the user.
    func refusal(for text: String) -> RoomSendRefusal?
    /// false: stopped here, the gateway did not confirm (row L467).
    func stopRoom() async -> Bool
    func resumeAll()
    func retry(_ messageId: String)
    func deleteUndelivered(_ messageId: String)
    func mentionTag(for messageId: String) -> String?
    func entry(for messageId: String) -> GroupMessage?
    func replyHeader(_ entry: GroupMessage) -> String
}

nonisolated enum RoomSendRefusal: Equatable, Sendable {
    /// `Slash commands are not supported in group chats. …` as a notice in the list.
    case slashCommand
    /// The "Can’t Send" alert (no member on this gateway).
    case noMembers(room: String)
}

@MainActor protocol GroupServices: AnyObject {
    var groupStore: GroupStore? { get }
    /// The rooms changed (the Bots list redraws; one listener, like `onBotsChange`).
    var onGroupsChange: (() -> Void)? { get set }
    /// The gateway is connected and takes writes (membership, rename, delete).
    var groupsWritable: Bool { get }
    /// Built from disk at once, like `chat(for:)`.
    func room(for key: String) -> (any ChatSessionModel)?
    /// Pushes the room on the Bots tab and clears its unread mark.
    func openRoom(_ key: String, from: UIViewController?)
}

nonisolated struct GroupNameTaken: LocalizedError, Sendable {
    var name: String
    var errorDescription: String? { "A group named “\(name)” already exists." }
}
