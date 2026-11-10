// [botslist] The parts of a row's status that are display only and never saved (docs/spec/3x-botslist.md §8, §9):
// "Waking up…" once a bot's chat has been opening for a second (parity §3 L184), and a standing problem's words in
// orange (L185).

import Foundation

extension BotStore {
    // MARK: Waking up (L184; `S/ui-bots/bot-row.tsx:198`, `S/status-grace.ts:7,28-39`)

    /// A bot's chat began opening (true) or its open ended — bound, failed, or the chat was left (false). The row says
    /// "Waking up…" only once the open has lasted `wakingGrace` (1 s), and stops saying it the moment the open ends.
    func noteBotOpening(_ profile: String, _ opening: Bool) {
        if opening {
            guard wakingTasks[profile] == nil, !wakingBots.contains(profile) else { return }
            let grace = wakingGrace
            wakingTasks[profile] = Task { [weak self] in
                try? await Task.sleep(for: grace)
                guard !Task.isCancelled, let self else { return }
                self.wakingTasks[profile] = nil
                if self.wakingBots.insert(profile).inserted { self.rebuild() }
            }
        } else {
            wakingTasks.removeValue(forKey: profile)?.cancel()
            if wakingBots.remove(profile) != nil { rebuild() }
        }
    }

    /// The transcript's header can say "Waking up…" too.
    func isWaking(_ profile: String) -> Bool { wakingBots.contains(profile) }

    // MARK: Standing problem (L185; `V/plugins/hermes-bots/data.ts:54-166`)

    /// A turn in a bot's chat ended in an error. A standing problem (sign-in, quota, no provider, blocked) becomes the
    /// row's status; a passing one (rate limit, 5xx, timeout) leaves the row as it was.
    func noteTurnFailed(profile: String, message: String?, reason: String? = nil) {
        guard let kind = Attention.reason(from: message, reason: reason) else { return }
        guard attention[profile] != kind else { return }
        attention[profile] = kind
        rebuild()
    }

    /// The bot answered: whatever stood in its way is over.
    func noteTurnSucceeded(profile: String) {
        if attention.removeValue(forKey: profile) != nil { rebuild() }
    }
}
