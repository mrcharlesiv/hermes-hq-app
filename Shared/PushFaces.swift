// Bot faces on pushed alerts (Communication Notifications), as Messages shows a contact's (port of the web app's
// ios/App/Shared/DispatchFaces.swift). The extension can't reach the roster: the app saves each bot's round face here as
// it learns who a chat is, in the Keychain group the two share, by gateway account (PushPolicy.owner) and profile — the
// two names a push's `dispatch` fields carry. Same service as the web app, so faces survive the update.

import Foundation
import ImageIO
import Intents
import Security
import UniformTypeIdentifiers
import UserNotifications

nonisolated enum PushFaces {
    static let service = "ai.hermes.ios.push-face"
    private static func name(_ account: String, _ profile: String) -> String { account + "\n" + profile.lowercased() }
    private static func query(_ account: String, _ profile: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: name(account, profile)]
    }

    /// A round PNG, at most 256 KB. Returns whether Keychain has it now.
    @discardableResult static func save(_ png: Data, account: String, profile: String) -> Bool {
        guard !account.isEmpty, !profile.isEmpty, !png.isEmpty, png.count <= 256 * 1024 else { return false }
        if face(account: account, profile: profile) == png { return true }
        let item = query(account, profile)
        if SecItemUpdate(item as CFDictionary, [kSecValueData as String: png] as CFDictionary) == errSecSuccess { return true }
        var add = item
        add[kSecValueData as String] = png
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func face(account: String, profile: String) -> Data? {
        guard !account.isEmpty, !profile.isEmpty else { return nil }
        var item = query(account, profile)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    /// An account removed from this phone (or signed out): its bots' faces go with its seal key.
    static func remove(account: String) {
        let all: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                  kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        guard SecItemCopyMatching(all as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]] else { return }
        for item in items {
            guard let stored = item[kSecAttrAccount as String] as? String, stored.hasPrefix(account + "\n") else { continue }
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                           kSecAttrAccount as String: stored] as CFDictionary)
        }
    }

    /// A picture shrunk by ImageIO to at most `pixels` on its longer side, as PNG, never decoded whole.
    static func thumbnail(_ data: Data, pixels: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: pixels] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    /// The alert as an incoming message from the bot, its face beside it (`face` nil: as it was). `chat` names the
    /// conversation like a Messages group, so iOS's sender line doesn't hide which chat it is. iOS draws it only when the
    /// app carries the Communication Notifications entitlement; without it `updating(from:)` throws and the alert stays.
    static func message(_ content: UNNotificationContent, sender: String, profile: String, face: Data?, chat: String,
                        conversation: String) -> UNNotificationContent {
        guard let face, !sender.isEmpty else { return content }
        let intent = sendIntent(body: content.body, sender: sender, handle: profile, face: face, chat: chat, conversation: conversation)
        return (try? content.updating(from: intent)) ?? content
    }

    /// [intents] The conversation, donated so the system can offer it (Siri Suggestions, the share sheet) and hand it
    /// back to open its chat (docs/spec/3x-intents.md §10.1; port of the web app's HermesPlatformExtras.swift:279-284):
    /// incoming, the same people and conversation id as the alert, and no message text. nil without a sender or with
    /// an id an alert may not name (letters, digits, - and _; at most 160: `NotificationRules.valid`, which this
    /// folder cannot see).
    static func donation(sender: String, handle: String, face: Data?, chat: String, conversation: String) -> INInteraction? {
        guard !sender.isEmpty, !conversation.isEmpty, conversation.count <= 160,
              conversation.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return nil }
        let interaction = INInteraction(intent: sendIntent(body: nil, sender: sender, handle: handle, face: face, chat: chat,
                                                          conversation: conversation), response: nil)
        interaction.direction = .incoming
        return interaction
    }

    static func sendIntent(body: String?, sender: String, handle: String, face: Data?, chat: String, conversation: String) -> INSendMessageIntent {
        let bot = INPerson(personHandle: INPersonHandle(value: handle, type: .unknown), nameComponents: nil, displayName: sender,
                           image: face.map { INImage(imageData: $0) }, contactIdentifier: nil, customIdentifier: handle)
        let me = INPerson(personHandle: INPersonHandle(value: "dispatch-owner", type: .unknown), nameComponents: nil, displayName: nil,
                          image: nil, contactIdentifier: nil, customIdentifier: nil, isMe: true)
        let room = chat.isEmpty ? nil : INSpeakableString(spokenPhrase: chat)
        return INSendMessageIntent(recipients: room == nil ? [me] : [me, bot], outgoingMessageType: .outgoingMessageText, content: body,
                                   speakableGroupName: room, conversationIdentifier: conversation.isEmpty ? nil : conversation,
                                   serviceName: nil, sender: bot, attachments: nil)
    }
}
