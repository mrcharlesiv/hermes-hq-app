import UIKit

/// [threads] What a bot's own chat screen asks the app for its threads (docs/spec/3x-threads.md): the list, a new one,
/// and a thread's own chat. `AppModel.makeChatScreen` gives one to a bot's chat; any other chat has none, and so no
/// thread button and no thread rows.
@MainActor protocol ChatThreadsHost: AnyObject {
    /// The chat's threads, oldest first.
    func threads() -> [ChatThread]
    /// Starts one with `text` (and optional voice `memo`) as its first message, hung under `anchor`; its key, nil when it could not start.
    @discardableResult func start(text: String, under anchor: ChatMessage?) -> String?
    @discardableResult func start(text: String, memo: MemoFile?, under anchor: ChatMessage?) -> String?
    /// Opens the thread's own chat (pushed on the iPhone, beside the chat on the Mac).
    func open(_ key: String, from screen: ChatViewController)
    /// A thread changed (a reply arrived, it got its title, one was started on another device).
    var onChange: (() -> Void)? { get set }
    /// The colour of the line beside an open thread: the bot's own.
    var tint: ThreadTint { get }
    /// These threads stand open in the chat on screen: what they hold has been read there.
    func markSeen(_ keys: [String])
    /// §9: calm routing strip shown over the composer while sends go straight into a thread.
    func busyRoutingBanner() -> ThreadBusyBanner?
    /// §9: user tapped "Wait in Main" on the proactive busy-thread strip.
    func optOutBusyRouting()
}

extension ChatThreadsHost {
    @discardableResult func start(text: String, memo: MemoFile?, under anchor: ChatMessage?) -> String? {
        start(text: text, under: anchor)
    }
    func busyRoutingBanner() -> ThreadBusyBanner? { nil }
    func optOutBusyRouting() {}
}

/// Where a thread was last drawn: under which message, open or folded.
struct ThreadPlacement: Equatable {
    var anchor: String
    var open: Bool
}

extension ChatViewController {
    func threadsHostChanged() {
        threadsHost?.onChange = { [weak self] in self?.threadsChanged() }
        if isViewLoaded, threadsHost != nil { threadsChanged() }
    }

    /// The row builder's threads: each under the message it hangs under, open or folded (plus empty-chat threads).
    func addThreads(to input: inout ChatRowBuilder.Input) {
        guard let host = threadsHost else { return }
        let threads = host.threads()
        guard !threads.isEmpty else { return }
        let messages = input.messages
        for (index, hung) in ThreadRules.byAnchor(threads, in: messages) {
            input.threads[messages[index].id] = hung.map {
                ThreadRowInput(thread: $0, open: ThreadRules.isOpen($0, anchor: index, in: messages))
            }
        }
        let unanchored = ThreadRules.unanchored(threads, in: messages)
        if !unanchored.isEmpty {
            input.threads[ThreadRows.emptyAnchorId] = unanchored.map { ThreadRowInput(thread: $0, open: true) }
        }
        input.threadTint = host.tint
    }

    private func threadPlacements() -> [String: ThreadPlacement] {
        guard let host = threadsHost else { return [:] }
        let threads = host.threads()
        guard !threads.isEmpty else { return [:] }
        let messages = session.messages
        var out: [String: ThreadPlacement] = [:]
        for (index, hung) in ThreadRules.byAnchor(threads, in: messages) {
            for thread in hung {
                out[thread.id] = ThreadPlacement(anchor: messages[index].id, open: ThreadRules.isOpen(thread, anchor: index, in: messages))
            }
        }
        for thread in ThreadRules.unanchored(threads, in: messages) {
            out[thread.id] = ThreadPlacement(anchor: ThreadRows.emptyAnchorId, open: true)
        }
        return out
    }

    /// The chat changed: a thread that moved or folded because of it (the main reply finished under an open thread)
    /// is drawn again. Returns the messages to rebuild.
    func threadMessagesToRebuild() -> [String] {
        guard threadsHost != nil else { return [] }
        let now = threadPlacements()
        guard now != threadsDrawn else { return [] }
        var touched = Set<String>()
        for key in Set(now.keys).union(threadsDrawn.keys) where now[key] != threadsDrawn[key] {
            if let was = threadsDrawn[key] { touched.insert(was.anchor) }
            if let next = now[key] { touched.insert(next.anchor) }
        }
        threadsDrawn = now
        threadsSeen()
        return Array(touched)
    }

    /// A thread changed by itself: the messages it hangs under (now and before) are rebuilt in place.
    func threadsChanged() {
        guard isViewLoaded, threadsHost != nil else { return }
        updateBusyThreadBanner()
        let before = threadsDrawn
        let now = threadPlacements()
        threadsDrawn = now
        threadsSeen()
        let anchors = Set(before.values.map(\.anchor)).union(now.values.map(\.anchor))
        guard !anchors.isEmpty else { return }
        if anchors.contains(ThreadRows.emptyAnchorId) {
            activityRebuildAll()
        } else {
            activityRebuild(messageIds: Array(anchors))
        }
    }

    /// [threads] §9: shows or clears the calm proactive-routing banner when sends go straight into a thread.
    /// Never displaces an explicit edit, reply, queue-edit, or Reply in Thread banner, and never stacks under an
    /// active "Your message is waiting" hold card.
    func updateBusyThreadBanner() {
        guard isViewLoaded else { return }
        let waitingForOwner = (session as? ChatComposerNotices)?.ownerWaitKind != nil
        let wanted = waitingForOwner ? nil : threadsHost?.busyRoutingBanner()
        let current = composer.editBanner as? ComposerEditBanner
        let isOurs = current?.accessibilityIdentifier == ComposerEditBanner.busyThreadIdentifier
        if let wanted {
            guard composer.editBanner == nil || isOurs else { return }
            if isOurs, current?.busyBannerContent == wanted { return }
            let banner = ComposerEditBanner.busyThread(wanted)
            banner.onCancel = { [weak self] in
                Haptics.play(.selection)
                self?.threadsHost?.optOutBusyRouting()
                self?.updateBusyThreadBanner()
            }
            composer.editBanner = banner
        } else if isOurs {
            composer.editBanner = nil
        }
    }

    /// The threads standing open in this chat are read once the chat is in front of the person: their own rows show
    /// no dot for a reply already read here. A folded thread keeps its dot (its line may be far up the chat).
    func threadsSeen() {
        guard let host = threadsHost, viewIfLoaded?.window != nil, UIApplication.shared.applicationState == .active else { return }
        let open = threadsDrawn.filter(\.value.open).map(\.key)
        if !open.isEmpty { host.markSeen(open) }
    }

    /// Starts a thread with `text` under the newest finished message (used by debug/demo hooks).
    func startThread(_ text: String) {
        guard let host = threadsHost else { return }
        menus?.closeModelPanel()
        let messages = session.messages
        // Under the newest finished message (the request the bot is answering while its first reply streams, or the
        // finished reply before a later background/tool turn — never trapped above an already-finished assistant reply).
        let anchor = ThreadRules.composerAnchor(in: messages, running: session.isRunning)
        AppLog.trace("composer", "thread started \(logTag): under \(AppLog.tag(anchor?.id)), main chat \(session.isRunning ? "working" : "idle")")
        followNewestEnd()
        host.start(text: text, under: anchor)
    }

    // MARK: Reply in Thread

    /// A message a thread can hang under: yours or the bot's, with words, in a chat that has threads.
    func canThread(under message: ChatMessage) -> Bool {
        guard threadsHost != nil, message.role != .system, message.sender == nil, !message.isStreaming, !message.isPending,
              message.error == nil else { return false }
        return !ChatTranscript.blocks(message).isEmpty
    }

    /// Reply in Thread on `messageId`: a banner over the field; the next message sent starts the thread under it.
    func beginThreadReply(_ messageId: String) {
        guard let message = session.messages.last(where: { $0.id == messageId }), canThread(under: message) else { return }
        if sendOverride != nil { (composer.editBanner as? ComposerEditBanner)?.onCancel?() }
        replyQuote = nil
        let excerpt = ChatTranscript.readableText(ChatTranscript.blocks(message))
            .split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let banner = ComposerEditBanner.threading(excerpt: excerpt)
        banner.onCancel = { [weak self] in
            self?.threadAnchorId = nil
            self?.composer.editBanner = nil
        }
        composer.editBanner = banner
        threadAnchorId = messageId
        Haptics.play(.selection)
        focusComposer()
    }

    /// The send while Reply in Thread's banner is up: a thread under that message. False when none is up.
    func sendAsThreadReply(_ text: String) -> Bool {
        guard let anchorId = threadAnchorId, let host = threadsHost else { return false }
        threadAnchorId = nil
        composer.editBanner = nil
        guard !ChatText.trimmed(text).isEmpty else { return true }
        let anchor = session.messages.last(where: { $0.id == anchorId })
        AppLog.trace("composer", "thread reply sent \(logTag): under \(AppLog.tag(anchorId))")
        // Replying in a thread is going into it: its own chat opens (the message it hangs under may be far up).
        if let key = host.start(text: text, under: anchor) { openThread(key: key) }
        return true
    }

    /// A voice memo sent while Reply in Thread's banner is up: starts the thread under that message. False when none is up.
    func sendAsThreadReply(memo: MemoFile, text: String) -> Bool {
        guard let anchorId = threadAnchorId, let host = threadsHost else { return false }
        threadAnchorId = nil
        composer.editBanner = nil
        let anchor = session.messages.last(where: { $0.id == anchorId })
        AppLog.trace("composer", "thread memo reply sent \(logTag): under \(AppLog.tag(anchorId))")
        if let key = host.start(text: text, memo: memo, under: anchor) { openThread(key: key) }
        return true
    }

    /// A thread's row was tapped (open or folded).
    func openThread(key: String) {
        threadsHost?.open(key, from: self)
    }

    func chatCellOpenThread(key: String) { openThread(key: key) }
}
