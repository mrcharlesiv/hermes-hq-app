// [share] The sheet's state: what was shared, who it goes to, and how sending is going (docs/spec/3x-share.md §7.2,
// §7.3, §7.8, §8). Port of build 240's ShareExtension/ShareModel.swift; its decisions live in `ShareSheetState`.

import Foundation
import UIKit
import Observation

@MainActor @Observable
final class ShareModel {
    enum Phase: Equatable {
        case loading
        case ready
        case sending(ShareStep)
        case sent(String)
        /// The share can't go from here (signed out, another account…): only Cancel.
        case blocked(ShareFailure)
    }

    private(set) var phase: Phase = .loading
    private(set) var items: [SharedItem] = []
    var message = ""
    var selection: String?
    /// The last send's failure, shown at the end of the list; the share stays as it is for Try Again.
    private(set) var failure: ShareFailure?
    /// Names of items that couldn't be read.
    private(set) var unreadable: [String] = []
    /// Photos and files beyond the first ten of each, which were not read.
    private(set) var skipped = ShareSkipped()
    /// Most recently active first.
    let bots: [ShareBot]
    let limit: Int

    @ObservationIgnored var onBusyChange: ((Bool) -> Void)?
    @ObservationIgnored private var wasSending = false
    @ObservationIgnored private let store: ShareStore?
    @ObservationIgnored private let roster: ShareRoster?
    /// The gateway the bots are on, named only while several are saved (the roster says).
    var gateway: String? { roster?.gateway }
    @ObservationIgnored private let keychain: any ShareKeychainStore
    @ObservationIgnored private let finish: (Bool) -> Void
    @ObservationIgnored private let folder: URL
    @ObservationIgnored private var sending: Task<Void, Never>?
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var faces: [String: UIImage?] = [:]
    @ObservationIgnored private var release: (@Sendable () -> Void)?

    init(inputs: [NSExtensionItem], store: ShareStore? = ShareStore(), keychain: any ShareKeychainStore = SystemShareKeychain(),
         finish: @escaping (Bool) -> Void) {
        self.finish = finish
        self.store = store
        self.keychain = keychain
        let roster = store?.roster
        self.roster = roster
        bots = ShareSheetState.ordered(roster?.bots ?? [])
        limit = roster.map { $0.limitBytes > 0 ? $0.limitBytes : ShareRules.defaultLimitBytes } ?? ShareRules.defaultLimitBytes
        folder = ShareItemLoader.newFolder()
        ShareItemLoader.removeStaleFolders()
        do { _ = try ShareSender.account(keychain: keychain, roster: roster) }
        catch let failure as ShareFailure { phase = .blocked(failure) }
        catch { phase = .blocked(.signedOut) }
        // DEBUG only: screenshots of states the simulator cannot reach (spec D14).
        let forced = Self.forced(store)
        if let blocked = forced.blocked { phase = .blocked(blocked) }
        if let roster, let store {
            selection = ShareSheetState.selection(bots: bots, remembered: store.lastChoice(account: roster.account))
        }
        let limit = limit
        loading = Task { [weak self, folder] in
            let loaded = await ShareItemLoader.load(inputs, into: folder, limit: limit, picture: { SharePictures.bitmap($0) })
            // Cancel (or a swipe away) while "Preparing…": the read that was in flight finished after the folder was
            // removed and staged its copy again. `load` returns only once that last write is done, so it goes here.
            guard let self, !Task.isCancelled, !self.closed else { try? FileManager.default.removeItem(at: folder); return }
            self.items = loaded.items
            self.unreadable = loaded.failures
            self.skipped = loaded.skipped
            if self.phase == .loading {
                self.phase = .ready
                if let failure = forced.failure { self.failure = failure }
            }
        }
    }

    private static func forced(_ store: ShareStore?) -> (blocked: ShareFailure?, failure: ShareFailure?) {
        #if DEBUG
        return store?.debugForced ?? (nil, nil)
        #else
        return (nil, nil)
        #endif
    }

    /// Every change of phase after the sheet opens goes through here, so the controller hears when sending starts and ends.
    private func move(to next: Phase) {
        phase = next
        if isSending != wasSending { wasSending = isSending; onBusyChange?(isSending) }
    }

    var isSending: Bool { if case .sending = phase { return true }; return false }
    var isBlocked: Bool { if case .blocked = phase { return true }; return false }
    /// A file or video over the limit: named, never copied, and Send stays off until it is removed or the share is
    /// cancelled.
    var oversized: [SharedItem] { items.filter { $0.file != nil && $0.bytes > limit } }
    var selectedBot: ShareBot? { bots.first { $0.key == selection } }
    var hasContent: Bool { ShareSheetState.hasContent(message: message, items: items.count) }
    var canSend: Bool {
        ShareSheetState.canSend(ready: phase == .ready, selected: selectedBot, hasContent: hasContent, oversized: oversized.count)
    }

    /// Leaves an oversized item out of this share (its row's ✕ or swipe); Send comes back once none is left. Nothing
    /// was copied for it, so there is nothing to clean up.
    func remove(_ item: SharedItem) {
        guard !isSending else { return }
        items.removeAll { $0.id == item.id }
    }

    func choose(_ bot: ShareBot) {
        guard bot.canReceive, !isSending else { return }
        if selection != bot.key { ShareHaptics.selection() }
        selection = bot.key
    }

    /// Each bot's face is read and decoded once: the list re-renders on every keystroke in the message field.
    func face(_ bot: ShareBot) -> UIImage? {
        guard let avatar = bot.avatar else { return nil }
        if let known = faces[avatar] { return known }
        let image = store?.picture(avatar).flatMap { UIImage(contentsOfFile: $0.path) }
        faces[avatar] = image
        return image
    }

    func send() {
        guard canSend, let bot = selectedBot, let roster else { return }
        failure = nil
        move(to: .sending(.connecting))
        let request = ShareRequest(bot: bot, message: message, shared: items.compactMap(\.sharedText),
                                   attachments: items.compactMap(\.attachment), limit: limit)
        let keychain = keychain
        hold()
        sending = Task { [weak self] in
            let sender = ShareSender(keychain: keychain, progress: { step in
                Task { @MainActor in if self?.isSending == true { self?.move(to: .sending(step)) } }
            })
            do {
                let result = try await sender.send(request, roster: roster)
                guard let self, !Task.isCancelled, !self.closed else { return }
                self.letGo()
                self.store?.remember(choice: bot.key, account: roster.account)
                self.store?.record(ShareSent(id: UUID().uuidString, account: roster.account, session: result.session,
                                             profile: bot.profile, botName: bot.name, at: Date().timeIntervalSince1970))
                ShareHaptics.finished(true)
                UIAccessibility.post(notification: .announcement, argument: ShareSheetState.sent(to: bot.name))
                self.move(to: .sent(bot.name))
                try? await Task.sleep(nanoseconds: 900_000_000)
                self.close(sent: true)
            } catch {
                guard let self else { return }
                self.letGo()
                guard !Task.isCancelled, !self.closed else { return }
                let failure = error as? ShareFailure ?? .refused("")
                if failure == .cancelled { self.move(to: .ready); return }
                ShareHaptics.finished(false)
                UIAccessibility.post(notification: .announcement, argument: failure.message)
                // The bot may have it: the app opens that chat next, to look before sending again.
                if failure == .unconfirmed {
                    self.store?.record(ShareSent(id: UUID().uuidString, account: roster.account, session: bot.session,
                                                 profile: bot.profile, botName: bot.name, at: Date().timeIntervalSince1970))
                }
                if failure.blocksSheet { self.move(to: .blocked(failure)); return }
                self.failure = failure
                self.move(to: .ready)
            }
        }
    }

    func cancel() {
        loading?.cancel()
        sending?.cancel()
        letGo()
        close(sent: false)
    }

    /// The sheet went away without Cancel or Send finishing it: stop, clean up, tell nobody.
    func abandon() {
        guard !closed else { return }
        closed = true
        loading?.cancel()
        sending?.cancel()
        letGo()
        try? FileManager.default.removeItem(at: folder)
    }

    private func close(sent: Bool) {
        guard !closed else { return }
        closed = true
        try? FileManager.default.removeItem(at: folder)
        finish(sent)
    }

    // MARK: A share in flight survives the person leaving the host app for a few seconds (spec D15)

    private func hold() {
        letGo()
        let done = DispatchSemaphore(value: 0)
        ProcessInfo.processInfo.performExpiringActivity(withReason: "Sending a share") { expired in
            // Granted: keep the process running until the send ends. Expiring: let go at once.
            if expired { done.signal() } else { done.wait() }
        }
        release = { done.signal() }
    }

    private func letGo() {
        release?()
        release = nil
    }
}
