// [botslist] Pinned reconcile (parity §3 L147; `S/ui-bots/pinned-section.ts:23-46`, owner: "auto Pinned section,
// include desktop pins too"). The phone files a pinned bot in the "Pinned" section so desktop Hermes, which has no
// pinned area, shows what the phone's tiles do. When the *desktop* pins or unpins a bot, only its flag changes; after
// every full roster this pass writes the section that agrees with the flag: a desktop "Pin to top" moves the bot into
// Pinned (its old section kept as the home to go back to), a desktop unpin moves it home. One write per bot at a time;
// a failed write is not tried again for a minute; no alert (nobody tapped anything). The list itself already draws by
// the flag (`RosterWire`), so it is right meanwhile.

import Foundation

extension BotStore {
    static let pinnedRetryWait: TimeInterval = 60

    /// Called after every full roster apply. Skips a read-only gateway, bots with a write of their own out (fenced),
    /// bots this pass is already writing, and bots whose last reconcile write failed less than a minute ago.
    func reconcilePinned() {
        guard reconcilesPinned, !readOnlyGateway else { return }
        let now = pinnedClock()
        let fenced = fencedProfiles()
        let lookup: (String) -> String? = { [weak self] id in self?.sectionName(id) }
        for name in profiles.map(\.name) {
            guard !fenced.contains(name), editing.createdRows[name] == nil, editing.deletedAt[name] == nil,
                  !pinnedWriting.contains(name) else { continue }
            if let retry = pinnedRetryAt[name] {
                if retry > now { continue }
                pinnedRetryAt[name] = nil
            }
            guard PinnedSection.pinnedSectionPatch(currentMeta(name), sectionName: lookup) != nil else { continue }
            pinnedWriting.insert(name)
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.writeBotMeta(name, failureTitle: "Couldn’t Update Pinned") { meta in
                        PinnedSection.pinnedSectionPatch(meta, sectionName: lookup)
                    }
                } catch {
                    self.pinnedRetryAt[name] = self.pinnedClock().addingTimeInterval(Self.pinnedRetryWait)
                }
                self.pinnedWriting.remove(name)
            }
        }
    }
}
