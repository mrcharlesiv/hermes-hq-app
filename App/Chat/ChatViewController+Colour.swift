// [bot-colour] A bot's chat paints your messages in the bot's own colour: its pick in Bot Info, or its face where
// Chat Bubbles › Colour says Bot's Face (`BotMessageColour`). The colour rides a trait on this screen
// (`ChatColourTrait`), so every bubble, memo and reaction in it resolves to it. A group chat has no one bot and keeps
// the app's colour; so does the Desktop Look, which keeps its own boxes.

import UIKit

@MainActor enum BotChatColour {
    /// The colour a bot's chat paints your messages with over the app's, nil for none (and in the Desktop Look).
    static func colour(profile: String, head: JSONValue?) -> MessageColour? {
        guard !Theme.shared.state.desktopLook else { return nil }
        let bot = BotMessageColour.choice(account: DefaultProjectFolder.activeAccount, profile: profile)
        let face = Head.resolve(head, profile: profile).messageColour
        return BotMessageColour.effective(app: Theme.shared.state.messageColour, bot: bot, face: face)
    }
}

extension ChatViewController {
    /// The colour this chat paints your messages with over the app's, nil for none.
    var chatColour: MessageColour? {
        session is ChatRoomSurface ? nil : BotChatColour.colour(profile: session.profile, head: session.head)
    }

    /// Sets the trait where the colour changed, and redraws the rows (a bubble's layer keeps the colour it was given).
    func applyChatColour() {
        guard ChatColourTrait.set(chatColour, on: &traitOverrides) else { return }
        if isViewLoaded { tableView.reloadData() }
    }

    /// The bot's pick changed (Bot Info, another device's settings).
    func watchChatColour() {
        NotificationCenter.default.addObserver(self, selector: #selector(chatColourChanged), name: BotMessageColour.didChange, object: nil)
    }

    @objc private func chatColourChanged() {
        if Thread.isMainThread { applyChatColour() } else { DispatchQueue.main.async { [weak self] in self?.applyChatColour() } }
    }
}
