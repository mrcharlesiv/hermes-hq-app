// The live chat's side of the menus stream (spec 1x §2, §3, §4.4–4.5): its model state from `session.resume` /
// `session.info`, session-scoped RPCs under the 4001 rule, the commands catalog, Rename, Share, and the slash output
// rows. The dispatcher itself is in SlashRunner.swift.

import Foundation

/// Menus-stream state a `LiveChatSession` carries (its one stored property for this stream).
final class ChatMenusState {
    /// What the gateway last reported, with this phone's optimistic picks.
    var modelState = ChatModelState()
    /// Opened from a Bots row (the bot's own chat): no Rename (spec 1x §4.1).
    var isBotChat = false
    var hooks = ChatSlashHooks()
    /// The Sessions row follows a rename (the app model points it at `SessionStore.applyTitle`); nil clears.
    var onTitleApplied: ((String?) -> Void)?
    /// Your message's line in the shared transcript when it isn't its text (a voice memo). Runs off the main actor.
    var transcriptUserLine: (@Sendable (String) -> String?)?
    var slashCounter = 0
    /// How long a slash command runs before its row shows "Running…" (spec 1x §8.4 ⚑ DECISION).
    var runningPlaceholderAfter: Duration = .milliseconds(250)
    /// The chat's folder from `session.resume` / `session.info` (`cwd`): Files, Changes and Branch read it.
    var cwd: String?
    /// Rewinds (Regenerate, Edit, Rewind to Here) whose send is in flight, by the send's local id.
    var rewinds: [String: RewindSend] = [:]
    /// A rewind rewrote the stored rows: the next read replaces the transcript whole.
    var wholeReloadOwed = false
    // [sessions-m9] Session Info (docs/spec/3x-sessions.md §10.3): the chat's usage as last reported (replaced whole,
    // never merged), its git branch, and the fallback model that answered (in memory, per chat).
    var usage: SessionUsage?
    var branch: String?
    var answeredBy: ModelFallback?
    // [/sessions-m9]
    /// `session.context_breakdown`'s estimate, shown while `usage` has no context of its own (ChatGatewayExtras.swift).
    var contextEstimate: SessionUsage?
    /// The gateway answered -32601 for these: not asked again on this chat (an older Hermes).
    var contextBreakdownMissing = false
    var processesMissing = false
    var reactionsMissing = false
    /// The Message Reactions switch as last written to this chat's bot (`config.set display.message_reactions`).
    var reactionsMirrored: Bool?
    /// /btw and /bg (SideTasks.swift): the tasks out by task id, the ones whose result landed, and the limit on
    /// listening off screen for them.
    var sideTasks: [String: SideTask] = [:]
    /// Tasks no longer waited for (over `SideTasks.listenLimit`): a result that still lands replaces their start rows.
    var sideOverdue: [String: SideTask] = [:]
    var sideDone: Set<String> = []
    var sideLimit: Task<Void, Never>?
    /// A `/compress` is out for this chat: a second one meanwhile is ignored (one LLM summary at a time).
    var compressing = false
}

extension LiveChatSession: ChatModelControlling {
    var modelState: ChatModelState {
        get {
            var state = menus.modelState
            // Before the first resume answers, the roster's model (spec 1x §2.1 rule 4).
            if state.model.isEmpty, let roster = modelName { state.model = roster }
            return state
        }
        set {
            guard newValue != menus.modelState else { return }
            menus.modelState = newValue
            modelStateChanged()
        }
    }

    private func modelStateChanged() {
        if !menus.modelState.model.isEmpty { modelName = ModelNames.displayModelName(menus.modelState.model, provider: menus.modelState.provider) }
        changes.markState()
        scheduleFlush()
    }

    /// Copies a `SessionLiveInfo` (`session.resume`'s `info`, a `session.info` payload) into the model state, each
    /// field only when present. While this phone's own switch is in flight (on this runtime id, or on this chat while a
    /// stale id resumes it under a new one), `model` and `provider` are left alone so an end-of-turn `session.info` or
    /// the resume's `info` can't blink the menu back (spec 1x §2.1 rule 3).
    func applyModelInfo(_ info: JSONValue?) {
        guard let info = info?.object else { return }
        // [sessions-m9] Session Info reads these (3x-sessions §10.3).
        if let usage = SessionUsage.decode(info["usage"]) { menus.usage = usage }
        if let branch = info["branch"]?.nonEmptyString { menus.branch = branch }
        var state = menus.modelState
        if !ModelSwitcher.isPending(runtimeSessionId) && !ModelSwitcher.isPending(chat: self) {
            if let model = info["model"]?.string { state.model = model }
            if let provider = info["provider"]?.string { state.provider = provider }
        }
        if let effort = info["reasoning_effort"]?.string { state.reasoningEffort = effort }
        if let fast = info["fast"]?.bool { state.fast = fast }
        if let cwd = info["cwd"]?.nonEmptyString, cwd != menus.cwd {
            menus.cwd = cwd
            // [settings] The chat's folder became known or changed: the Files bar button follows (3x-settings §12).
            NotificationCenter.default.post(name: LiveChatSession.workingDirectoryChanged, object: self)
        }
        if let yolo = info["yolo"]?.bool { state.yolo = yolo }
        if let mode = info["approval_mode"]?.nonEmptyString { state.approvalMode = mode.lowercased() }
        guard state != menus.modelState else { return }
        menus.modelState = state
        modelStateChanged()
    }

    func sessionCall(_ method: String, timeout: Duration, runtime: SessionCallRuntime,
                     params: @escaping (_ runtimeId: String?) -> [String: JSONValue]) async throws -> JSONValue {
        if runtimeSessionId == nil {
            switch runtime {
            case .required: throw MenusError.loading
            case .resumeFirst: try await resumeNow()
            case .optional: break
            }
        }
        var resumed = false
        while true {
            let runtimeId = runtimeSessionId
            var p = params(runtimeId)
            if let runtimeId { p["session_id"] = .string(runtimeId) }
            if let profileParam { p["profile"] = .string(profileParam) }
            do {
                return try await client.call(method, .object(p), timeout: timeout)
            } catch let stale as RPCError where stale.code == 4001 && !resumed && runtimeId != nil {
                // A stale runtime id is refused before anything ran: resume once, send once more (spec 1x §0).
                AppLog.trace("chat", "\(method) on \(logIds): 4001 stale runtime, resume once and send again")
                resumed = true
                runtimeSessionId = nil
                do { try await resumeNow() } catch { throw stale }
            } catch let error as RPCError where error.code == 4064 {
                onRosterStale?()
                throw error
            }
        }
    }
}

// MARK: - Commands catalog (spec 1x §3.5)

extension LiveChatSession {
    var commandsCatalogKey: CommandsCatalogCache.Key {
        CommandsCatalogCache.Key(account: account.id, scope: runtimeSessionId.map { "session:\($0)" } ?? "profile:\(profile)")
    }

    /// The newest catalog this account and profile has seen (typed commands resolve against it).
    var latestCommandsCatalog: CommandsCatalog? {
        CommandsCatalogCache.shared.cached(commandsCatalogKey) ?? CommandsCatalogCache.shared.latest(account: account.id, profile: profile)
    }

    /// `commands.catalog`, from the 1 h cache unless `fresh` (Try Again). Offline, or when the read fails, this
    /// profile's newest list answers if there is one (spec 1x §7.1: offline ☰ still opens with the cached list; a
    /// resumed chat's new runtime id or an hour-old entry doesn't empty it).
    func loadCommandsCatalog(fresh: Bool = false) async throws -> CommandsCatalog {
        if !fresh, let cached = CommandsCatalogCache.shared.fresh(commandsCatalogKey) { return cached }
        let fallback = latestCommandsCatalog
        if connection != .ready, let fallback { return fallback }
        do {
            let result = try await sessionCall("commands.catalog", timeout: .seconds(30), runtime: .optional) { _ in [:] }
            guard result.object != nil else { throw MenusError("Hermes sent its list of commands in a shape this app doesn't read.") }
            let catalog = CommandsCatalog(json: result)
            CommandsCatalogCache.shared.store(catalog, for: commandsCatalogKey, profile: profile)
            return catalog
        } catch {
            if error is CancellationError { throw error }
            if let fallback { return fallback }
            throw error
        }
    }
}

// MARK: - Rename and Share (spec 1x §4.4, §4.5)

extension LiveChatSession: ChatSessionActions {
    var isBotChat: Bool { menus.isBotChat || title == RosterRules.botChatTitle }

    /// Shows a new title in the bar and the Sessions row (nil/"" = cleared).
    func applyTitle(_ newTitle: String, rowTitle: String?) {
        if title != newTitle {
            title = newTitle
            changes.markState()
            scheduleFlush()
        }
        menus.onTitleApplied?(rowTitle)
    }

    @discardableResult
    func rename(to newTitle: String) async throws -> String {
        let typed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = title
        applyTitle(typed.isEmpty ? "Untitled Chat" : typed, rowTitle: typed)
        do {
            let stored = try await storeTitle(typed)
            applyTitle(stored.isEmpty ? "Untitled Chat" : stored, rowTitle: stored)
            return stored
        } catch {
            applyTitle(previous, rowTitle: previous)
            throw error
        }
    }

    /// The opening message's text, when the loaded page starts at the chat's start.
    var firstUserText: String? {
        guard !hasOlder else { return nil }
        return messages.first(where: { $0.role == .user })?.plainText
    }

    /// After a reply, a chat still named by its opening words gets a short title (`ShortTitle`), saved to the gateway so
    /// every device shows it. Waits a moment first: the gateway's own model title, when it works, lands and wins.
    func shortenTitleIfNeeded() {
        guard !shortTitleTried, !isBotChat, let first = firstUserText, !ChatText.trimmed(first).isEmpty,
              ShortTitle.isPlaceholder(title, firstMessage: first) else { return }
        shortTitleTried = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, ShortTitle.isPlaceholder(self.title, firstMessage: first) else { return }
            let short = await ShortTitle.make(from: first)
            guard ShortTitle.isPlaceholder(self.title, firstMessage: first), short != self.title else { return }
            AppLog.note("chat", "short title on \(self.logIds): gateway left the opening words; saved \(short.count) chars")
            _ = try? await self.rename(to: short)
        }
    }

    /// `renameSessionPreferringRpc` (V:app/chat/sidebar/session-actions-menu.tsx:114-140): `session.title` when the title
    /// isn't empty and the chat is live; otherwise, or on any error from it, `PATCH /api/sessions/<id>`.
    private func storeTitle(_ typed: String) async throws -> String {
        if !typed.isEmpty, runtimeSessionId != nil {
            if let result = try? await sessionCall("session.title", timeout: .seconds(30), runtime: .required, params: { _ in
                ["title": .string(typed)]
            }) {
                return result["title"]?.nonEmptyString ?? typed
            }
        }
        guard let stored = readSessionId else { throw MenusError("This chat is still loading. Try again when it is ready.") }
        let data = try await SessionWrite.patch(client, id: stored, profile: profileParam, ["title": .string(typed)])
        let answer = try? ChatJSON.parse(data)
        return answer?["title"]?.string ?? typed
    }

    /// The whole chat as text (spec 1x §4.4): the loaded messages when they are the whole chat, else every page. The
    /// folding and formatting run off the main actor (a chat near the 32 M-character cap is tens of thousands of rows).
    func transcriptText() async throws -> String {
        let whole = !hasOlder && openPhase == .open
        let userLine = menus.transcriptUserLine
        if whole {
            return await ChatTranscript.formatText(title: title, botName: botName, messages: messages, userLine: userLine)
        }
        guard let stored = readSessionId else { throw MenusError("This chat is still loading. Try again when it is ready.") }
        return try await ChatTranscript.fetchAllText(client: client, storedSessionId: stored, profile: profileParam, title: title,
                                                     botName: botName, userLine: userLine)
    }
}

// MARK: - Slash output rows (spec 1x §8.4)

/// One command's output row: "Running…" once the command has run a moment, then its answer in place.
final class SlashOutput {
    private weak var session: LiveChatSession?
    let command: String?
    private(set) var rowId: String?
    private var placeholder: Task<Void, Never>?
    private var finished = false
    static let running = "Running…"
    /// [diagnostics] The command for log lines (its name when the catalog knows it), and when it began.
    var logLabel = "slash"
    private let began = ContinuousClock.now

    /// `running`: the placeholder's words ("Compressing context…" for /compress).
    init(session: LiveChatSession, command: String?, placeholderAfter: Duration?, running: String = SlashOutput.running) {
        self.session = session
        self.command = command
        if let placeholderAfter {
            placeholder = Task { [weak self] in
                try? await Task.sleep(for: placeholderAfter)
                guard let self, !Task.isCancelled, !self.finished, self.rowId == nil else { return }
                self.rowId = self.session?.appendSlashRow(command: self.command, output: running)
            }
        }
    }

    /// The answer: replaces the "Running…" row, or adds the row; a second answer adds another row.
    func finish(_ output: String) {
        placeholder?.cancel()
        let outcome = output.hasPrefix("error:") ? "error" : output.hasPrefix("warning:") ? "warning" : "ok"
        AppLog.trace("chat", "slash \(logLabel) finished: \(outcome), \(output.count) chars, \(AppLog.ms(since: began)) ms\(session == nil ? " (chat gone)" : "")")
        guard let session else { return }
        if let rowId, !finished {
            session.updateSlashRow(rowId, command: command, output: output)
        } else {
            rowId = session.appendSlashRow(command: command, output: output)
        }
        finished = true
    }

    /// Nothing to show (a sent skill, a prefill, an alert instead): the "Running…" row goes.
    func cancel() {
        placeholder?.cancel()
        if let rowId, !finished { session?.removeSlashRow(rowId) }
        if !finished { rowId = nil }
        finished = true
    }
}

extension LiveChatSession {
    @discardableResult
    func appendSlashRow(command: String?, output: String) -> String {
        menus.slashCounter += 1
        let id = "\(SlashOutputRow.idPrefix)\(menus.slashCounter)"
        appendMessage(ChatMessage(id: id, role: .system, parts: [.text(SlashOutputRow.text(command: command, output: output))],
                                  timestamp: Date(), rowId: nil))
        scheduleFlush()
        return id
    }

    func updateSlashRow(_ id: String, command: String?, output: String) {
        updateMessage(id) { m in m.parts = [.text(SlashOutputRow.text(command: command, output: output))] }
        scheduleFlush()
    }

    func removeSlashRow(_ id: String) {
        removeMessage(id)
        scheduleFlush()
    }
}

extension LiveChatSession {
    /// [settings] Posted (object: the session) when the chat's project folder becomes known or changes.
    static let workingDirectoryChanged = Notification.Name("hqn.chat.cwd.changed")
}
