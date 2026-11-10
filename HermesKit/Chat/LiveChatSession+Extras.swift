// The live chat's side of ChatGatewayExtras.swift: the context estimate before a turn, the chat's running commands,
// and Tapback reactions. Each asks a Hermes 0.22.5 method; -32601 (an older Hermes) hides the feature on this chat.

import Foundation

extension LiveChatSession {
    /// Usage as Session Info and Usage & Limits show it: the reported usage, with the estimate's context while the
    /// report has none.
    var shownUsage: SessionUsage? { SessionUsage.shown(menus.usage, estimate: menus.contextEstimate) }

    /// When the reported usage has no context yet (a chat resumed in this gateway process before its first turn), asks
    /// `session.context_breakdown` once per open sheet. Errors leave the row out.
    func refreshContextEstimate() async {
        guard runtimeSessionId != nil, !menus.contextBreakdownMissing, (menus.usage?.contextMax ?? 0) <= 0 else { return }
        do {
            let answer = try await sessionCall("session.context_breakdown", timeout: .seconds(5), runtime: .required) { _ in [:] }
            menus.contextEstimate = ContextEstimate.decode(answer)
        } catch {
            if SlashResults.isMissingMethod(error) { menus.contextBreakdownMissing = true }
        }
    }

    // MARK: Running commands

    /// The chat's running background commands, newest last; nil when the gateway can't say (no runtime yet, an older
    /// Hermes, offline), so the list keeps what it showed.
    func runningCommands() async -> [BackgroundProcess]? {
        guard runtimeSessionId != nil, !menus.processesMissing else { return nil }
        do {
            let answer = try await sessionCall("process.list", timeout: .seconds(5), runtime: .required) { _ in [:] }
            return BackgroundProcess.list(answer).filter(\.isRunning)
        } catch {
            if SlashResults.isMissingMethod(error) { menus.processesMissing = true; return [] }
            return nil
        }
    }

    /// Whether this chat may offer the list at all (false once the gateway said it has no `process.list`).
    var offersRunningCommands: Bool { !menus.processesMissing }

    /// Stops one background command (`process.kill`), leaving the turn and every other command running.
    func stopCommand(_ id: String) async throws {
        _ = try await sessionCall("process.kill", timeout: .seconds(10), runtime: .required) { _ in ["process_id": .string(id)] }
    }

    // MARK: Reactions

    enum ReactError: Error { case unsupported, failed(String) }

    /// The message can take a Tapback from you now: the switch is on, the gateway has `message.react`, the link is up,
    /// and the message is stored (or the newest of its role, which the gateway resolves itself).
    func canReact(to messageId: String) -> Bool {
        guard MessageReactionsPref.isOn, !menus.reactionsMissing, connection == .ready,
              let m = messages.last(where: { $0.id == messageId }), m.role != .system, !m.isStreaming, !m.isPending,
              m.error == nil else { return false }
        return m.reactionTarget != nil || messages.last(where: { $0.role == m.role })?.id == messageId
    }

    /// Your Tapback on a message: `emoji` replaces your previous one; your current one (or nil) removes it. Drawn at
    /// once; the gateway's list wins when it answers, and a refusal puts the old list back.
    func react(to messageId: String, emoji: String?) async throws {
        guard let m = messages.last(where: { $0.id == messageId }) else { return }
        let before = m.reactions
        let mine = before.first(where: \.isMine)?.emoji
        let sent: String? = emoji == mine ? nil : emoji          // retract with null, never by sending the same one again
        let target = m.reactionTarget
        let role = m.role == .user ? "user" : "assistant"
        updateMessage(messageId) { $0.reactions = MessageReactions.applying(before, emoji: sent) }
        scheduleFlush()
        mirrorReactionsSwitch()
        do {
            let answer = try await sessionCall("message.react", timeout: .seconds(10), runtime: .resumeFirst) { _ in
                var p: [String: JSONValue] = ["emoji": sent.map(JSONValue.string) ?? .null, "author": .string("user")]
                if let target { p["row_id"] = .number(Double(target)) } else { p["newest_role"] = .string(role) }
                return p
            }
            let row = answer["row_id"]?.positiveInt
            let reactions = MessageReactions.decode(answer["reactions"])
            updateMessage(messageId) { m in
                m.reactions = reactions
                if let row, row != m.rowId { m.reactionRow = row }
            }
            scheduleFlush()
        } catch {
            updateMessage(messageId) { $0.reactions = before }
            scheduleFlush()
            if SlashResults.isMissingMethod(error) {
                menus.reactionsMissing = true
                throw ReactError.unsupported
            }
            throw ReactError.failed(MenusError.text(error))
        }
    }

    /// Writes the Message Reactions switch to this chat's bot (`display.message_reactions`, which lets the bot react
    /// to yours) once per bot and value, and only after the person has used the switch. Errors are left for the next
    /// time (it is this device's preference; the switch never flips back).
    func mirrorReactionsSwitch() {
        guard MessageReactionsPref.touched, runtimeSessionId != nil else { return }
        let on = MessageReactionsPref.isOn
        let bot = "\(account.baseURL.absoluteString)|\(profile)"
        guard menus.reactionsMirrored != on, MessageReactionsPref.written(bot) != on else { return }
        menus.reactionsMirrored = on
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.sessionCall("config.set", timeout: .seconds(10), runtime: .required) { _ in
                    ["key": .string(MessageReactionsPref.configKey), "value": .string(on ? "true" : "false")]
                }
                MessageReactionsPref.noteWritten(bot, on)
            } catch {
                if self.menus.reactionsMirrored == on { self.menus.reactionsMirrored = nil }
            }
        }
    }
}
