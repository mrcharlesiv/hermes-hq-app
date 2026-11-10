// [photoheads] Contract additions for bot photos (docs/spec/3x-photoheads.md §8). Kept out of Contracts.swift and
// Contracts+settings.swift: the Edit Bot page reaches `BotPictureEditing` with `info.editing as? BotPictureEditing`.

import Foundation

/// What Edit Bot's Save does to the bot's picture.
nonisolated enum BotPictureChange: Sendable, Equatable {
    /// A photo framed in Move and Scale: a 256 × 256 PNG as a `data:` URL.
    case photo(dataURL: String)
    /// Remove Picture. `mirror` is the 288 × 288 copy of the bot's saved head that goes back in the photo's place
    /// (desktop Hermes shows it); nil for a bot with no saved head, whose picture is simply cleared.
    case remove(mirror: String?)
    /// The picture itself already landed in an earlier Save that could not write its kind: only the kind is sent.
    case kindOnly(photo: Bool)

    /// `ui_meta["hermes-bots"].imageKind` (`HB/edit-profile-dialog.tsx:96-110`).
    var imageKind: String {
        switch self {
        case .photo: "photo"
        case .remove: "shape"
        case .kindOnly(let photo): photo ? "photo" : "shape"
        }
    }
}

@MainActor protocol BotPictureEditing: AnyObject {
    /// Whether the gateway in use can store bot pictures at all (an older one has no asset store, §5.6).
    var supportsPictures: Bool { get }
    /// Whether this bot's face is a photo now (its head otherwise).
    func showsPhoto(_ bot: Bot) -> Bool
    /// Edit Bot's Save with a staged picture. The picture goes first; `EditOutcome.pictureApplied` says whether it
    /// landed, `pictureKindApplied` whether its kind was then written with the Title, and the Title and Description
    /// parts report as they always did. Throws only when nothing was sent (a read-only gateway).
    func saveEdit(_ bot: Bot, title: String?, description: String?, picture: BotPictureChange?) async throws -> EditOutcome
}

/// The words for a picture that did not save (§8.4).
nonisolated enum BotPictureWords {
    static let failureTitle = "Couldn’t Save the Picture"
    static let noAnswer = "The gateway didn’t answer. Check the connection and try again."
    static var unsupported: String { "This gateway can’t store bot pictures yet. Update Hermes on \(HostWord.updateTarget), then try again." }
    static let tooBig = "The picture is too big for the gateway. Choose another one."
    static let refused = "The gateway didn’t accept that picture. Choose another one."

    /// Why `profiles.set_asset` failed, in plain words.
    static func reason(_ error: Error) -> String {
        guard let rpc = error as? RPCError else {
            if let failure = error as? BotWriteError { return failure.reason }
            return noAnswer
        }
        if rpc.isTimeout || rpc.isConnectionLost || rpc.isNotConnected { return noAnswer }
        switch rpc.code {
        case -32601, 4000: return unsupported       // no such method, or a parameter an older gateway does not know
        case 4069: return tooBig
        case 4070: return refused
        default: return rpc.message.isEmpty ? BotWriteError.notSavedReason : rpc.message
        }
    }
}
