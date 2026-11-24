import UIKit

/// What the chat shelf says for the active call.
nonisolated func phoneChipWords(_ calls: [PhoneCallRecord], now: Date = Date()) -> (words: String, asking: Bool)? {
    guard let call = calls.last(where: \.active) else { return nil }
    if call.question != nil { return ("Call needs you", true) }
    let who = call.name ?? phoneShown(call.to)
    switch call.state {
    case .calling: return ("Calling \(who)", false)
    case .ending: return ("Ending the call", false)
    default:
        let timer = PhoneCallPresentation.timer(from: call.answeredAt ?? call.liveAt ?? call.placedAt, to: now)
        return ((call.voicemail ? "Voicemail answered" : "On a call") + " · " + timer, false)
    }
}

@MainActor final class PhoneChatChip {
    private weak var chat: ChatViewController?
    private weak var live: LiveChatSession?
    private let controller: PhoneCallController
    private var timer: Task<Void, Never>?

    static func install(on chat: ChatViewController, live: LiveChatSession) {
        let chip = PhoneChatChip(chat: chat, live: live)
        chat.activity.phoneCard = chip
        chat.activity.onPhoneChip = { [weak chip] in chip?.open() }
        chip.watch()
    }

    private init(chat: ChatViewController, live: LiveChatSession) {
        self.chat = chat
        self.live = live
        controller = .shared(for: live.client.account.id)
    }

    deinit { timer?.cancel() }

    private var activeCall: PhoneCallRecord? {
        guard let live else { return nil }
        return controller.calls.last { $0.active && PhoneCallChat.matches(live, $0.sessionID) }
    }

    private func watch() {
        let call = withObservationTracking {
            activeCall
        } onChange: { [weak self] in
            Task { @MainActor in self?.watch() }
        }
        update(call)
        let ticks = call?.state == .live && call?.question == nil
        if !ticks {
            timer?.cancel()
            timer = nil
        } else if timer == nil {
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled, let self else { return }
                    self.update(self.activeCall)
                }
            }
        }
    }

    private func update(_ call: PhoneCallRecord?) {
        guard let chat else { return }
        let chip = phoneChipWords(call.map { [$0] } ?? [])
        let old = chat.activity.phoneChip
        if (chip == nil) != (old == nil) || chip?.asking != old?.asking {
            AppLog.note("phone", chip == nil ? "chat chip gone" : chip?.asking == true ? "chat chip asks" : "chat chip shown")
        }
        if chip?.words != old?.words || chip?.asking != old?.asking { chat.activity.phoneChip = chip }
    }

    private func open() {
        guard let chat, let live, let call = activeCall, chat.presentedViewController == nil else { return }
        AppLog.note("phone", "chat chip tapped")
        PhoneCallChat.present(account: live.client.account.id, session: call.sessionID, profile: live.profile,
                              callID: call.id, from: chat)
    }
}
