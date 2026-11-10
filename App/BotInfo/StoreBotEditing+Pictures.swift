// [photoheads] The Edit Bot page saves a staged picture through this (docs/spec/3x-photoheads.md §8): the settings
// stream's adapter gains the picture contract here, so its own file and the `BotEditing` protocol stay as they were.

import Foundation

extension StoreBotEditing: BotPictureEditing {
    var supportsPictures: Bool { store.photos.supportsAssets }

    func showsPhoto(_ bot: Bot) -> Bool { store.photos.hasPhoto(bot.id) }

    func saveEdit(_ bot: Bot, title: String?, description: String?, picture: BotPictureChange?) async throws -> EditOutcome {
        try await store.saveEdit(name: bot.id, title: title, description: description, picture: picture)
    }
}
