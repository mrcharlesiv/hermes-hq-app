// Switching the open chat's model, Reasoning and Fast (spec 1x §5): ports of `titleMenuContext.switchModel`,
// `patchOption` and `setFast` (S:ui-chat/title-menu.ts:175-262) and `requestModelSwitchWithFeedback`
// (S:model-switch-feedback.ts:22-68). The screen supplies the alerts and notices (`ModelSwitchUI`).

import Foundation

/// What a switch shows: the "Change Model?" confirm, the failure alert, and the notice under the title.
protocol ModelSwitchUI: AnyObject {
    /// "Change Model?" with the gateway's message, Cancel · Change Model. True to go ahead.
    func confirmModelChange(_ message: String) async -> Bool
    /// "Couldn't Change Model" with the reason.
    func modelChangeFailed(_ reason: String)
    /// A notice under the title; `duration` nil keeps it until replaced, `spinner` leads it with an activity indicator.
    func switchNotice(_ text: String, duration: TimeInterval?, spinner: Bool)
    func hideSwitchNotice()
}

final class ModelSwitcher {
    /// Runtime ids with a model switch in flight, app-wide (it survives leaving the chat, `$pendingModelSwitches`).
    private(set) static var pending: Set<String> = []
    /// The chats with a switch in flight. A stale runtime id resumes the chat under a new id mid-switch (spec 1x §0):
    /// the resume's `info` (the old model) must not repaint the pick, so the chat itself counts as pending too.
    private static var pendingChats: Set<ObjectIdentifier> = []
    static func isPending(_ runtimeId: String?) -> Bool { runtimeId.map { pending.contains($0) } ?? false }
    static func isPending(chat: AnyObject) -> Bool { pendingChats.contains(ObjectIdentifier(chat)) }

    static let switchTimeout: Duration = .seconds(45)
    static let optionTimeout: Duration = .seconds(15)
    static let noticeSeconds: TimeInterval = 5

    let context: ModelMenuContext
    weak var ui: (any ModelSwitchUI)?

    init(context: ModelMenuContext, ui: (any ModelSwitchUI)?) {
        self.context = context
        self.ui = ui
    }

    private var chat: any ChatModelControlling { context.chat }
    private var prefs: ModelPrefs { context.prefs }

    private func assertWritable() throws {
        if context.offline { throw MenusError.offline }
        if chat.runtimeSessionId == nil { throw MenusError.loading }
    }

    /// [phone-logs] How long a pick made while the chat is still opening waits for it (then "still loading").
    var openingWait: Duration = .seconds(15)

    /// [phone-logs] Build 910: a model picked 6 s after launch, while a slow gateway was still resuming the chat (6.2 s),
    /// failed with "This chat is still loading." The pick waits for the chat to be ready (≤ `openingWait`, a notice under
    /// the title meanwhile), then goes ahead or fails as before.
    private func untilWritable() async throws {
        guard chat.runtimeSessionId == nil, !context.offline else { return try assertWritable() }
        AppLog.trace("menus", "model change waits for the chat to finish opening")
        ui?.switchNotice("Waiting for the chat to load…", duration: nil, spinner: true)
        let until = ContinuousClock.now + openingWait
        while chat.runtimeSessionId == nil, !context.offline, ContinuousClock.now < until {
            try await Task.sleep(for: .milliseconds(100))
        }
        ui?.hideSwitchNotice()
        AppLog.trace("menus", "model change: the chat is \(chat.runtimeSessionId == nil ? "still opening" : "ready")")
        try assertWritable()
    }

    private func report(_ error: any Error) {
        if error is CancellationError { return }
        AppLog.note("menus", "model change failed in \(AppLog.tag(chat.runtimeSessionId)): \(LiveChatSession.logError(error)); shown to the user")
        ui?.modelChangeFailed(MenusError.text(error))
    }

    /// `isBusySessionModelSwitch`: a pre-deferral gateway refusing a switch while a turn runs (spec 1x §3.2).
    static func isBusySwitch(_ error: any Error) -> Bool {
        let text = MenusError.text(error)
        return text.range(of: "session busy", options: .caseInsensitive) != nil
            && text.range(of: "switching models", options: .caseInsensitive) != nil
    }

    // MARK: Model

    /// Picks a model for the chat's next reply (spec 1x §5). False when it didn't happen (cancelled, failed, or a switch
    /// already in flight).
    @discardableResult
    func switchModel(_ picked: ModelChoice, restorePreset: Bool = true) async -> Bool {
        do { return try await performSwitch(picked, restorePreset: restorePreset) } catch {
            report(error)
            return false
        }
    }

    private func performSwitch(_ picked: ModelChoice, restorePreset: Bool) async throws -> Bool {
        try await untilWritable()
        guard let runtimeId = chat.runtimeSessionId else { throw MenusError.loading }
        if Self.isPending(runtimeId) { AppLog.trace("menus", "model switch on rt \(AppLog.tag(runtimeId)) skipped: one already in flight"); return false }
        let switchStart = ContinuousClock.now
        let before = context.current()
        let preset = prefs.preset(provider: picked.provider, model: picked.id)
        let caps = context.capabilities(picked)
        let providerModels = context.options?.row(matching: picked.provider)?.models ?? []
        let target = restorePreset && caps?.fast != true && preset.fast == true && providerModels.contains("\(picked.id)-fast")
            ? context.describe(id: "\(picked.id)-fast", provider: picked.provider) : picked
        let key = context.key
        func paint(_ model: ModelChoice) {
            chat.modelState.model = model.id
            chat.modelState.provider = model.provider
            context.cache.paint(context.key, model: model.id, provider: model.provider)
        }
        let rollback = { paint(before) }
        paint(target)
        let value = "\(target.id) --provider \(target.provider)" + (target.provider.lowercased() == "moa" ? " --session" : "")
        do {
            var result = try await sendSwitch(runtimeId: runtimeId, model: target.id, provider: target.provider, value: value, confirmed: false)
            if result["confirm_required"]?.bool == true {
                rollback()
                let message = ModelSwitchWording.plain(result["confirm_message"]?.string ?? "")
                AppLog.trace("menus", "model switch to \(target.provider)/\(target.id) needs confirmation")
                guard await ui?.confirmModelChange(message) == true else { AppLog.trace("menus", "model switch declined at the confirmation"); return false }
                try assertWritable()
                let now = context.current()
                if now.id != before.id || now.provider != before.provider { throw MenusError("The model changed. Choose it again.") }
                result = try await sendSwitch(runtimeId: chat.runtimeSessionId ?? runtimeId, model: target.id, provider: target.provider,
                                              value: value, confirmed: true)
                if result["confirm_required"]?.bool == true {
                    let text = result["confirm_message"]?.string ?? ""
                    throw MenusError(text.isEmpty ? "The model switch still requires confirmation." : text)
                }
            }
            // The gateway took it (live or deferred): paint again, so nothing that arrived meanwhile (a stale id's
            // resume answering with the old model) is left showing.
            paint(target)
            AppLog.trace("menus", "model switch on rt \(AppLog.tag(runtimeId)): \(before.provider)/\(before.id) → \(target.provider)/\(target.id), \(result["deferred"]?.bool == true ? "deferred to the next turn" : "live"), \(AppLog.ms(since: switchStart)) ms")
            if result["deferred"]?.bool != true {
                context.cache.markStale(key)
                context.cache.markStale(context.key)
            }
        } catch {
            if !Self.isBusySwitch(error) {
                AppLog.trace("menus", "model switch to \(target.provider)/\(target.id) failed, rolled back to \(before.provider)/\(before.id)")
                rollback()
                throw error
            }
            AppLog.trace("menus", "model switch to \(target.provider)/\(target.id): old gateway refused while busy; shown as picked")
            paint(target)
        }
        prefs.remember(before)
        prefs.remember(target)
        (chat as? LiveChatSession)?.dismissSessionProblem()   // [transcript] §6.2: a new model answers the problem
        if restorePreset {
            if caps?.reasoning != false {
                // The model's saved effort, else the profile's own default (never Hermes' medium over the owner's
                // config, `$defaultReasoningEffort`); unknown, the session's reasoning is left as it is.
                var effort = preset.effort ?? context.profileDefaultEffort
                if effort == nil { effort = await context.loadProfileDefault() }
                if let effort { try await patchOption(effort: effort, model: target) }
            }
            if caps?.fast == true { try await patchOption(fast: preset.fast ?? false, model: target) }
        }
        return true
    }

    /// One `config.set key=model` with its notices (`requestModelSwitchWithFeedback`). [authority] A gateway-hosted
    /// Hermes refuses that write by name (`use_session_mutation_model`): the pick is its `session.mutate` there
    /// (`ModelMutation`), sent at once when the socket named the authority, else after the refusal.
    private func sendSwitch(runtimeId: String, model: String, provider: String, value: String, confirmed: Bool) async throws -> JSONValue {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = trimmed.isEmpty ? "the selected model" : ModelNames.formatModelPillLabel(trimmed)
        let chatId = ObjectIdentifier(chat)
        Self.pending.insert(runtimeId)
        Self.pendingChats.insert(chatId)
        defer {
            Self.pending.remove(runtimeId)
            Self.pendingChats.remove(chatId)
        }
        ui?.switchNotice("Switching to \(label)…", duration: nil, spinner: true)
        let chat = chat
        func mutate() async throws -> JSONValue {
            try await ModelMutation.send(chat.client, session: chat.runtimeSessionId ?? runtimeId, profile: chat.profileParam,
                                         model: model, provider: provider, confirmed: confirmed, timeout: Self.switchTimeout)
        }
        do {
            let result: JSONValue
            if ModelMutation.isAuthority(chat.client) {
                result = try await mutate()
            } else {
                do {
                    result = try await chat.sessionCall("config.set", timeout: Self.switchTimeout, runtime: .required) { _ in
                        var p: [String: JSONValue] = ["key": "model", "value": .string(value)]
                        if confirmed { p["confirm_expensive_model"] = true }
                        return p
                    }
                } catch where ModelMutation.isRefusal(error) {
                    AppLog.trace("menus", "model switch on rt \(AppLog.tag(runtimeId)): config.set refused, sent as session.mutate")
                    result = try await mutate()
                }
            }
            if result["confirm_required"]?.bool == true {
                ui?.hideSwitchNotice()
            } else if result["deferred"]?.bool == true {
                ui?.switchNotice("\(label) will be used for your next message.", duration: Self.noticeSeconds, spinner: false)
            } else {
                ui?.switchNotice("Model changed to \(label).", duration: Self.noticeSeconds, spinner: false)
            }
            return result
        } catch {
            if Self.isBusySwitch(error) {
                ui?.switchNotice("\(label) will be used for your next message.", duration: Self.noticeSeconds, spinner: false)
            } else {
                ui?.hideSwitchNotice()
            }
            throw error
        }
    }

    // MARK: Reasoning and Fast

    /// Saves the preset, paints the value, then `config.set` (spec 1x §5.1, §5.2); a failure restores both.
    private func patchOption(effort: String? = nil, fast: Bool? = nil, model: ModelChoice? = nil) async throws {
        try await untilWritable()
        let model = model ?? context.current()
        let previous = (effort: chat.modelState.reasoningEffort, fast: chat.modelState.fast)
        let oldPreset = prefs.preset(provider: model.provider, model: model.id)
        prefs.setPreset(provider: model.provider, model: model.id, ModelPreset(effort: effort, fast: fast))
        if let effort { chat.modelState.reasoningEffort = effort }
        if let fast { chat.modelState.fast = fast }
        do {
            if let effort {
                _ = try await chat.sessionCall("config.set", timeout: Self.optionTimeout, runtime: .required) { _ in
                    ["key": "reasoning", "value": .string(effort)]
                }
            }
            if let fast {
                _ = try await chat.sessionCall("config.set", timeout: Self.optionTimeout, runtime: .required) { _ in
                    ["key": "fast", "value": .string(fast ? "fast" : "normal")]
                }
            }
        } catch {
            var restored = prefs.preset(provider: model.provider, model: model.id)
            if effort != nil { restored.effort = oldPreset.effort ?? previous.effort }
            if fast != nil { restored.fast = oldPreset.fast ?? previous.fast }
            prefs.replacePreset(provider: model.provider, model: model.id, restored)
            if effort != nil { chat.modelState.reasoningEffort = previous.effort }
            if fast != nil { chat.modelState.fast = previous.fast }
            throw error
        }
    }

    /// ⋯ › Model › Reasoning › a level.
    @discardableResult
    func setReasoning(_ level: String) async -> Bool {
        do { try await patchOption(effort: level); return true } catch { report(error); return false }
    }

    // MARK: Approvals (owner 2026-10-31: "The pop-up for the model needs to also have your approval settings on it")

    /// The bot's approval mode: `approvals.mode` in its config, so every chat with it (and its jobs) follows; Hermes
    /// answers with the mode it kept (V:store/approval-mode.ts:85-112). Shown at once; put back if the write fails.
    func setApprovalMode(_ mode: String) async throws {
        if context.offline { throw MenusError.offline }
        let previous = chat.modelState.approvalMode
        chat.modelState.approvalMode = mode
        do {
            let result = try await chat.sessionCall("config.set", timeout: Self.optionTimeout, runtime: .optional) { _ in
                ["key": "approvals.mode", "value": .string(mode)]
            }
            if let kept = result["value"]?.nonEmptyString { chat.modelState.approvalMode = kept.lowercased() }
        } catch {
            chat.modelState.approvalMode = previous
            throw error
        }
    }

    /// An older Hermes leaves the mode out of the chat's info: read it once (`config.get approvals.mode`).
    func loadApprovalMode() async {
        guard chat.modelState.approvalMode.isEmpty, !context.offline else { return }
        let result = try? await chat.sessionCall("config.get", timeout: Self.optionTimeout, runtime: .optional) { _ in
            ["key": "approvals.mode"]
        }
        if let mode = result?["value"]?.nonEmptyString, chat.modelState.approvalMode.isEmpty { chat.modelState.approvalMode = mode.lowercased() }
    }

    /// This chat's approval bypass, as `/yolo` sets it (V:lib/yolo-session.ts:11-27).
    func setYolo(_ on: Bool) async throws {
        if context.offline { throw MenusError.offline }
        let result = try await chat.sessionCall("config.set", timeout: Self.optionTimeout, runtime: .resumeFirst) { _ in
            ["key": "yolo", "value": .string(on ? "1" : "0")]
        }
        chat.modelState.yolo = result["value"]?.string == "1"
    }

    /// ⋯ › Model › Fast (spec 1x §5.2).
    @discardableResult
    func setFast(_ on: Bool) async -> Bool {
        do {
            try await untilWritable()
            let control = context.fastControl()
            let model = context.current()
            guard control.supported else { throw MenusError("Fast is unavailable for this model.") }
            if let variant = control.variant {
                let ok = await switchModel(context.describe(id: on ? variant.sibling : variant.base, provider: model.provider),
                                           restorePreset: false)
                if ok { prefs.setPreset(provider: model.provider, model: variant.base, ModelPreset(fast: on)) }
                return ok
            }
            try await patchOption(fast: on)
            return true
        } catch {
            report(error)
            return false
        }
    }
}

/// [phone-logs] Hermes writes its switch warnings for a terminal: "!!! LARGE CONTEXT MODEL SWITCH !!!", then the config
/// key that sets the threshold. On a phone the alert's title already says what it is, so the banner and the settings
/// lines go, and the rest reads as a sentence about this chat. A message in any other shape passes through unchanged.
nonisolated enum ModelSwitchWording {
    static func plain(_ message: String) -> String {
        let lines = message.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let kept = lines.filter { line in
            !(line.hasPrefix("!!!") && line.hasSuffix("!!!")) && !line.hasPrefix("Threshold:") && !line.hasPrefix("Confirm only if")
        }
        guard kept.count != lines.count else { return message }
        var text = kept.joined(separator: "\n")
        while text.contains("\n\n\n") { text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        text = text.replacingOccurrences(of: "This session holds", with: "This chat holds")
            .replacingOccurrences(of: " (providers key prompt caches per model)", with: "")
            .replacingOccurrences(of: "re-read all of it uncached", with: "read all of it again without the cache")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
