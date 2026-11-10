// [groups] Deliveries from another bot in an ordinary chat (docs/spec/3x-groups.md §7.12, row L301): a user-role
// message that starts with a delivery prefix becomes an incoming message with its sender, the prefix removed. The
// sender is found in the roster by handle, then display name, then `hermes` → the default bot
// (`S/ui-chat/chat-identity.ts:100-112`); an unknown sender keeps the prefix's name and the default head.

import Foundation

nonisolated enum DeliveryMessages {
    /// What the lookup needs of a bot.
    struct Seat: Hashable, Sendable {
        var profile: String
        var name: String
        var head: JSONValue?
    }

    /// Cheap test before the regular expression: only a text that starts like a delivery is parsed.
    static func mayBeDelivery(_ text: String) -> Bool {
        text.hasPrefix("Message from ") || text.hasPrefix("[Message from agent '")
    }

    static func sender(for parsed: DeliverySender.Parsed, roster: [Seat]) -> ChatSender {
        let handle = parsed.handle.lowercased()
        let name = parsed.name.trimmingCharacters(in: .whitespaces).lowercased()
        let found = roster.first { RosterRules.handle(forProfile: $0.profile) == handle }
            ?? roster.first { $0.name.trimmingCharacters(in: .whitespaces).lowercased() == name }
            ?? (handle == "hermes" || name == "hermes" ? roster.first { $0.profile == "default" } : nil)
        if let found {
            return ChatSender(key: "delivery:" + found.profile, name: found.name, head: found.head, profile: found.profile,
                              colorHex: ChatSenderColors.hex(head: found.head, profile: found.profile))
        }
        // Unknown: the name as written, the default head, the label colour.
        return ChatSender(key: "delivery:?" + handle, name: parsed.name, head: nil, profile: "default", colorHex: nil)
    }

    /// `messages` with every delivery turned into its sender's message. The same array comes back when there is none.
    static func resolve(_ messages: [ChatMessage], roster: [Seat]) -> (messages: [ChatMessage], found: Bool) {
        var out: [ChatMessage]?
        for index in messages.indices {
            let message = messages[index]
            guard message.role == .user, message.sender == nil, case .text(let text)? = message.parts.first, mayBeDelivery(text),
                  let parsed = DeliverySender.parse(text) else { continue }
            if out == nil { out = messages }
            out![index].sender = sender(for: parsed, roster: roster)
            out![index].parts[0] = .text(parsed.body)
        }
        return (out ?? messages, out != nil)
    }

    static func hasDelivery(_ messages: [ChatMessage]) -> Bool {
        messages.contains { message in
            guard message.role == .user, case .text(let text)? = message.parts.first else { return false }
            return mayBeDelivery(text) && DeliverySender.parse(text) != nil
        }
    }
}

/// The roster the chat screens resolve deliveries against, and who to tell when it changes (set up by the app model).
@MainActor enum DeliveryRoster {
    static var seats: [DeliveryMessages.Seat] = []
    private static var listeners: [UUID: () -> Void] = [:]

    static func set(_ next: [DeliveryMessages.Seat]) {
        guard next != seats else { return }
        seats = next
        for listener in listeners.values { listener() }
    }

    @discardableResult static func observe(_ change: @escaping () -> Void) -> UUID {
        let id = UUID()
        listeners[id] = change
        return id
    }

    static func stopObserving(_ id: UUID) { listeners[id] = nil }
}
