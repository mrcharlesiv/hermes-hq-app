import UIKit

// The chat's browser card (the web app's BrowserActivity, MEM chat-dock-browser-card): while the chat's bot uses its
// browser, a chip on the chat's shelf above the composer, on the same native glass as the subagents and tasks chips,
// so the transcript's bottom and the jump button already make room for it. "Browsing example.com", "Hermes needs you
// in its browser" (orange) or "You're using Hermes's browser"; a tap opens Watch Browser. It listens only while the
// chat is on screen, and looks again when the list changes and when the chat's turn starts or ends.

final class BrowserChatCard {
    private weak var chat: ChatViewController?
    private let service: BrowserService
    /// Read on every update: a new chat gets its session ids only once its first turn starts.
    private let scope: () -> BrowserScope
    private let open: (BrowserScope, UIViewController) -> Void
    private var subscription: BrowserSubscription?
    private var showing: BrowserRow?

    @discardableResult
    static func install(on chat: ChatViewController, service: BrowserService, scope: @escaping () -> BrowserScope,
                        open: @escaping (BrowserScope, UIViewController) -> Void) -> BrowserChatCard {
        let card = BrowserChatCard(chat: chat, service: service, scope: scope, open: open)
        chat.activity.browserCard = card
        chat.activity.onAttachedChange = { [weak card] on in card?.setVisible(on) }
        chat.activity.onStateChange = { [weak card] in card?.update() }
        chat.activity.onBrowserChip = { [weak card, weak chat] in
            guard let card, let chat else { return }
            AppLog.note("browser", "chat card tapped")
            card.open(card.scope(), chat)
        }
        return card
    }

    private init(chat: ChatViewController, service: BrowserService, scope: @escaping () -> BrowserScope,
                 open: @escaping (BrowserScope, UIViewController) -> Void) {
        self.chat = chat
        self.service = service
        self.scope = scope
        self.open = open
    }

    private func setVisible(_ on: Bool) {
        if on, subscription == nil {
            subscription = service.activity.subscribe { [weak self] in self?.update() }
            update()
        } else if !on {
            subscription?.cancel()
            subscription = nil
        }
    }

    func update() {
        guard let chat, subscription != nil else { return }
        let scope = self.scope()
        let row = BrowserCard.row(scope.row(in: service.activity.rows), showing: showing, turnRunning: chat.session.isRunning)
        let changed = row?.id != showing?.id
        showing = row
        let chip = row.map { (words: BrowserCard.words($0, name: scope.title.isEmpty ? "This bot" : scope.title),
                              asking: $0.ask != nil && $0.control == .bot) }
        if chip?.words != chat.activity.browserChip?.words || chip?.asking != chat.activity.browserChip?.asking {
            if changed { AppLog.note("browser", row == nil ? "chat card gone" : "chat card shown") }
            chat.activity.browserChip = chip
        }
    }
}
