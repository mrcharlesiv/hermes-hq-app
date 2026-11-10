// [presence] A request for the gateway's main bot, queued in its chat (docs/spec/3x-presence.md §10; the web app's
// askToInstall, R:src/browser-watch/setup.ts:34-51). Watch Browser's setup screen uses it for "Ask Hermes to Install
// It": the main bot's chat opens and the request is sent at once when the bot is free, or waits in the chat's queue
// behind the reply that is running. The bubble and the queue row show the short title, not the long prompt, and nothing
// is typed into the field for the person to send.

import UIKit

@MainActor enum MainBotRequest {
    struct Failure: LocalizedError, Equatable {
        let errorDescription: String?
        init(_ words: String) { errorDescription = words }
    }

    /// What the bubble and the queue row say (QUEUE_TITLE).
    nonisolated static let browserTitle = "Install the Hermes HQ browser add-on on this Hermes."
    /// The same for Watch Browser's offer to update an add-on too old for popups.
    nonisolated static let browserUpdateTitle = "Update the Hermes HQ browser add-on on this Hermes."

    // The web's words, one per way it can fail.
    nonisolated static let noMainBot = "Couldn’t find the main bot on \(HostWord.phrase). Open Bots and try again."
    nonisolated static let couldNotOpen = "Couldn’t open the bot’s chat. Try again."
    nonisolated static let notInTime = "The bot’s chat didn’t open in time. Try again."
    nonisolated static let couldNotSend = "Couldn’t send the request to the bot. Try again."
    /// Native only (DECISION D30): the bot's chat cannot be shown without throwing away what the person is editing.
    nonisolated static let editingFirst = "Save or discard what you’re editing, then try again."

    /// The gateway's main bot, or the web's words for why there is none.
    nonisolated static func mainBot(_ bots: [Bot]) throws -> Bot {
        guard let bot = bots.first(where: { $0.id == "default" }) else { throw Failure(noMainBot) }
        return bot
    }

    /// What queueing does once the chat is open: nothing when the same request already waits there (asked twice).
    enum Step: Equatable, Sendable { case alreadyQueued, send }

    nonisolated static func step(queued: [String], text: String) -> Step {
        queued.contains(text) ? .alreadyQueued : .send
    }

    /// What is presented over the tabs, bottom to top (Bot Info, a sheet the notice's Watch opened the viewer over).
    static func presented(over root: UIViewController?) -> [UIViewController] {
        var pages: [UIViewController] = []
        var next = root?.presentedViewController
        while let page = next {
            pages.append(page)
            next = page.presentedViewController
        }
        return pages
    }

    /// Whether what is over the tabs may be closed to show the main bot's chat. A sheet holding unsaved edits (it
    /// refuses a swipe down: `isModalInPresentation`) is never thrown away, and an alert is the person's to answer.
    static func leaveProblem(lockedSheet: Bool, alertOnTop: Bool) -> String? {
        if lockedSheet { return editingFirst }
        if alertOnTop { return couldNotOpen }
        return nil
    }

    static func checkCanLeave(_ root: UIViewController?) throws {
        let pages = presented(over: root)
        if let words = leaveProblem(lockedSheet: pages.contains { $0.isModalInPresentation && !($0 is UIAlertController) },
                                    alertOnTop: pages.last is UIAlertController) {
            throw Failure(words)
        }
    }

    /// Closes what is presented over the tabs, as Bot Info's own Bot Chat row does before it opens a chat. Without
    /// this the chat opened, and the request went out, underneath the sheet: nothing to see, and a second tap sent
    /// the request again.
    /// `keeping`: a sheet that stays when it's the only thing over the tabs ([addon-progress] the add-on update's, at
    /// half height: the chat opens and the request shows above it).
    private static func closeWhatIsOver(_ root: UIViewController, keeping: UIViewController? = nil) async throws {
        try checkCanLeave(root)
        guard root.presentedViewController != nil else { return }
        if let keeping, presented(over: root) == [keeping] { return }
        AppLog.note("presence", "main bot request: closing what is open")
        root.dismiss(animated: true)
        // Not the dismissal's completion: UIKit does not always call it when another dismissal is already running.
        for _ in 0..<60 where root.presentedViewController != nil { try? await Task.sleep(for: .milliseconds(50)) }
        guard root.presentedViewController == nil else { throw Failure(couldNotOpen) }
    }

    /// The web's budget for the chat and its session to open (80 × 50 ms), by the clock: a busy main thread does not
    /// stretch it.
    nonisolated static let openBudget: Duration = .seconds(4)

    /// Opens the main bot's chat and queues `text` there: sent at once when the bot is free, after its reply otherwise.
    /// The bubble and the queue row show `title`. Throws the web's words. `linkReady`: the gateway is connected now.
    /// `retryHint`: how the three "Try again." endings finish (the notification offer sends people to Settings).
    /// `keeping`: a sheet left open over the chat when nothing else is (`closeWhatIsOver`).
    static func queue(text: String, title: String, retryHint: String = "Try again.", keeping: UIViewController? = nil,
                      linkReady: () -> Bool = { true }) async throws {
        do {
            try await perform(text: text, title: title, keeping: keeping, linkReady: linkReady)
        } catch let failure as Failure where retryHint != "Try again." && failure.errorDescription?.hasSuffix(" Try again.") == true {
            throw Failure(String(failure.errorDescription!.dropLast("Try again.".count)) + retryHint)
        }
    }

    private static func perform(text: String, title: String, keeping: UIViewController?, linkReady: () -> Bool) async throws {
        guard let root = MainTabController.current else { throw Failure(couldNotOpen) }
        try await closeWhatIsOver(root, keeping: keeping)
        root.select(.bots)
        let bots = root.botsViewController
        guard let navigation = bots.navigationController else { throw Failure(couldNotOpen) }
        navigation.popToRootViewController(animated: false)
        bots.open("default")
        let deadline = ContinuousClock.now + openBudget
        var chat: ChatViewController?
        while true {
            if let top = navigation.paneChat, top.viewIfLoaded?.window != nil,
               top.session.profile == "default" {
                chat = top
                break
            }
            guard ContinuousClock.now < deadline else { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let chat else { throw Failure(notInTime) }
        guard let live = chat.session as? LiveChatSession else { throw Failure(couldNotSend) }
        // What is left of the budget goes to the chat's own open: its answer says whether a reply is running, which is
        // what decides "send now" or "wait in the queue". A chat that has not answered by then takes the request
        // anyway; its own refused-send path hands the words back with the chat's notice, so nothing is lost. With the
        // gateway away there is no answer to wait for: the request shows in the chat at once and goes out by itself
        // when the connection is back (the chat's send waits for it).
        while ContinuousClock.now < deadline, linkReady(), !(live.openSettled || live.openFinished) {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if step(queued: live.queuedMessages.map(\.text), text: text) == .alreadyQueued {
            AppLog.note("presence", "main bot request already queued")
            return
        }
        AppLog.note("presence", "main bot request queued")
        // The stored row holds the whole prompt; the bubble keeps its title when the chat reads its transcript again.
        LiveChatSession.sentTitles.note(text: text, title: title)
        live.send(text, display: title)
    }
}
